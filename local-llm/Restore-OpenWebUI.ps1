#Requires -Version 5.1

<#
.SYNOPSIS
    Restores an Open WebUI backup archive (made by Backup-OpenWebUI.ps1) into the open-webui volume.

.DESCRIPTION
    Built so that a failed restore can never leave you with an empty or half-written volume:
      1. Picks the archive (newest daily backup unless -Archive is given), copies it into
         <AIRoot>\Backups\restore-staging (also makes NAS/UNC archives usable by Docker), and checks
         that webui.db sits at the top level.
      2. Takes a verified safety backup of the current volume (tag "pre-restore"; never pruned or
         mirrored during the restore).
      3. Stops every container using the volume, extracts the archive into a staging folder *inside*
         the volume, and only after webui.db is confirmed there swaps it in.
      4. If anything fails after the old data was touched, it puts the safety backup back. If even that
         fails, the container is left stopped and the exact recovery command is printed.
    A machine-wide lock stops the scheduled backup from running at the same time.

.EXAMPLE
    .\Restore-OpenWebUI.ps1                                   # newest daily backup
.EXAMPLE
    .\Restore-OpenWebUI.ps1 -Archive \\nas\backups\open-webui-20261002-175511.tar.gz
.EXAMPLE
    .\Restore-OpenWebUI.ps1 -DeepResearch                    # deep research's newest backup instead
#>
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    [string]$Archive = '',
    # Do not archive the current data first (no automatic rollback if the restore fails).
    [switch]$SkipSafetyBackup,
    # Docker volume to restore into.
    [string]$Volume = 'open-webui',
    # Container that uses the volume; stopped during the restore.
    [string]$Container = 'open-webui',
    # Small local image that runs tar on the volume.
    [string]$HelperImage = 'alpine:3.20',
    # Skip the "type YES" confirmation (scripts, automation).
    [switch]$Force,
    # Restore deep research's data (accounts, history, reports) instead of Open WebUI's, from a
    # deep-research-*.tar.gz (the newest daily one unless -Archive is given).
    [switch]$DeepResearch,
    # Deep research's volume (tests use throwaway ones).
    [string]$ResearchVolume = 'localai-deep-research',
    # Deep research's container; stopped during its restore.
    [string]$ResearchContainer = 'deep-research'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force
$img = $HelperImage

function Invoke-Docker {
    param([string[]]$Arguments, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& docker @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0 -and -not $AllowFail) { throw "docker $($Arguments -join ' ') failed ($code): $($out -join ' ')" }
    return [pscustomobject]@{ ExitCode = $code; Text = ($out -join "`n") }
}

# The archive is always mounted as /restore.tar.gz, so its file name never reaches the shell.
# No double quotes anywhere in this script: Windows PowerShell 5.1 mangles them in native arguments.
$swapScript = 'set -e; rm -rf /data/.restore-staging; mkdir /data/.restore-staging; ' +
    'tar xzf /restore.tar.gz -C /data/.restore-staging; test -f /data/.restore-staging/webui.db; ' +
    'find /data -mindepth 1 -maxdepth 1 ! -name .restore-staging -exec rm -rf {} +; ' +
    'cd /data/.restore-staging; find . -mindepth 1 -maxdepth 1 -exec mv {} /data/ \; ; ' +
    'cd /; rmdir /data/.restore-staging'

function Invoke-Swap {
    param([string]$ArchivePath)
    if ($env:LOCALAI_TEST_FAIL_SWAP) { throw 'Test hook: swap failed' }
    if ($env:LOCALAI_TEST_KILL_IN_SWAP) { [Environment]::Exit(9) }   # test hook: killed mid-swap (no catch/finally)
    if ($env:LOCALAI_TEST_FAIL_SWAP_ONCE) { $env:LOCALAI_TEST_FAIL_SWAP_ONCE = ''; throw 'Test hook: first swap failed' }
    Invoke-Docker -Arguments @('run', '--rm', '-v', "${Volume}:/data", '-v', "${ArchivePath}:/restore.tar.gz:ro", $img, 'sh', '-c', $swapScript) | Out-Null
}

function Test-Archive {
    param([string]$ArchivePath)
    $r = Invoke-Docker -Arguments @('run', '--rm', '-v', "${ArchivePath}:/restore.tar.gz:ro", $img, 'tar', 'tzf', '/restore.tar.gz') -AllowFail
    return ($r.ExitCode -eq 0 -and $r.Text -match '(?m)^(\./)?webui\.db\s*$')
}

$backupDir = Join-Path $AIRoot 'Backups'
$stagingDir = Join-Path $backupDir 'restore-staging'
$lock = $null
$stoppedContainers = @()
$volumeTouched = $false
$safety = $null
$holdPath = Join-Path $AIRoot 'open-webui-hold.json'
$script:holdArchive = ''
$script:recoverCmd = ''
$script:holdWritten = $false
function Clear-Hold([string]$Note) {
    # Never throws: a hold that cannot be deleted right now (antivirus, a sync client) is a warning,
    # not a reason to abandon a restore that worked. Retries briefly first.
    for ($i = 1; $i -le 5; $i++) {
        if (-not (Test-Path -LiteralPath $holdPath)) { return }
        try { Remove-Item -LiteralPath $holdPath -Force -ErrorAction Stop; if ($Note) { Write-LaiLog OK $Note }; return }
        catch { Start-Sleep -Milliseconds (300 * $i) }
    }
    Write-LaiLog WARN "Could not delete $holdPath; delete it by hand, or Start again, backups and updates keep refusing."
}
function Set-Hold([string]$Why, [object[]]$Held) {
    # Keep Open WebUI down until a restore succeeds: the watch, Start-LocalAI and the installer
    # check this file. The original restart policies are kept here so the recovery can put them back.
    $list = @($Held | ForEach-Object { @{ Id = $_.Id; Policy = $_.Policy } })
    $ids = @($list | ForEach-Object { $_['Id'] })
    $old = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($old -and $old['Containers']) { foreach ($c in @($old['Containers'])) { if ($ids -notcontains $c['Id']) { $list += $c } } }
    $recover = $script:recoverCmd; $archive = [string]$script:holdArchive
    # A failed recovery run (no safety backup of its own) must not replace the earlier hold's pointer
    # to the safety archive: that one holds the newest data.
    if (-not $archive -and $old -and $old['Archive']) { $archive = [string]$old['Archive']; $recover = [string]$old['Recover'] }
    Save-LaiState -State @{ Reason = $Why; Recover = $recover; Archive = $archive; Containers = $list; Since = (Get-Date).ToString('s') } -Path $holdPath
    if ($recover -ne $script:recoverCmd) { Write-LaiLog FAIL "The earlier recovery command still applies: $recover" }
}

if ($DeepResearch) {
    # Deep research is much simpler than Open WebUI: one container, no hold. The current data is
    # archived first and put back if the swap fails; its database stays readable only with the
    # password in Secrets\deep-research.json, which a restore does not change.
    if (-not $Archive) {
        $newest = Get-ChildItem -LiteralPath $backupDir -Filter 'deep-research-*.tar.gz' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^deep-research-\d{8}-\d{6}(-pre-uninstall)?\.tar\.gz$' -and $_.LastWriteTime -le (Get-Date).AddHours(1) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
        if (-not $newest) { throw "No deep research backups found in $backupDir. Pass -Archive <file>." }
        $Archive = $newest.FullName
    }
    if (-not (Test-Path -LiteralPath $Archive)) { throw "Archive not found: $Archive" }
    $source = Get-Item -LiteralPath $Archive
    if (-not $Force) {
        Write-LaiLog WARN ("This replaces ALL current deep research data (accounts, research history, reports) with {0} from {1}." -f $source.Name, $source.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
        if ((Read-Host 'Type YES to restore') -cne 'YES') { Write-LaiLog INFO 'Nothing changed.'; exit 1 }
    }
    $rSwap = $swapScript.Replace('test -f /data/.restore-staging/webui.db', 'test -d /data/.restore-staging/encrypted_databases')
    # Putting the earlier data back: whatever it held (it may have been a fresh, empty install).
    $rBack = $swapScript.Replace('test -f /data/.restore-staging/webui.db', 'true')
    if ($rSwap -eq $swapScript -or $rBack -eq $swapScript) { throw 'Internal error: the swap script changed; nothing was done.' }
    $wasRunning = $false
    $policy = ''
    $rSafety = $null
    $rTouched = $false
    $keepStopped = $false
    $code = 0
    try {
        $lock = Enter-LaiVolumeLock
        if ((Invoke-Docker -Arguments @('version', '--format', '{{.Server.Version}}') -AllowFail).ExitCode -ne 0) {
            throw 'Docker Desktop is not running. Start it (Start menu > Local AI - Start again), then run the restore again. Nothing was changed.'
        }
        if (-not (Test-Path -LiteralPath $stagingDir)) { New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null }
        $staged = Join-Path $stagingDir 'restore-deep-research.tar.gz'
        Copy-Item -LiteralPath $source.FullName -Destination $staged -Force
        $list = Invoke-Docker -Arguments @('run', '--rm', '-v', "${staged}:/restore.tar.gz:ro", $img, 'tar', 'tzf', '/restore.tar.gz') -AllowFail
        if ($list.ExitCode -ne 0 -or $list.Text -notmatch '(?m)^(\./)?encrypted_databases/?\s*$') { throw "$($source.Name) is not a deep research backup (unreadable, or no encrypted_databases folder). Nothing was changed." }
        # Stopped first, so the safety copy is consistent and nothing writes during the swap; its
        # restart policy is off meanwhile, so a Docker Desktop restart cannot start it mid-swap (the
        # health watch leaves it alone while this holds the volume lock).
        $insp = Invoke-Docker -Arguments @('inspect', '-f', '{{.State.Running}}|{{.HostConfig.RestartPolicy.Name}}', $ResearchContainer) -AllowFail
        if ($insp.ExitCode -eq 0) {
            $wasRunning = ($insp.Text.Trim() -split '\|')[0] -eq 'true'
            $policy = ($insp.Text.Trim() -split '\|')[1]
            if ($policy -and $policy -ne 'no') { Invoke-Docker -Arguments @('update', '--restart', 'no', $ResearchContainer) | Out-Null }
            if ($wasRunning) { Invoke-Docker -Arguments @('stop', '-t', '30', $ResearchContainer) | Out-Null }
        }
        if ((Invoke-Docker -Arguments @('volume', 'inspect', $ResearchVolume) -AllowFail).ExitCode -ne 0) {
            Invoke-Docker -Arguments @('volume', 'create', $ResearchVolume) | Out-Null
        } elseif (-not $SkipSafetyBackup) {
            # Written under a temporary name and checked before it counts as the safety copy.
            $rSafety = Join-Path $backupDir ('deep-research-{0}-pre-restore.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $tmp = 'incomplete-' + (Split-Path -Leaf $rSafety)
            Invoke-Docker -Arguments @('run', '--rm', '-v', "${ResearchVolume}:/data:ro", '-v', "${backupDir}:/backup", $img, 'tar', 'czf', "/backup/$tmp", '-C', '/data', '.') | Out-Null
            Invoke-Docker -Arguments @('run', '--rm', '-v', "${backupDir}:/backup:ro", $img, 'tar', 'tzf', "/backup/$tmp") | Out-Null
            Move-Item -LiteralPath (Join-Path $backupDir $tmp) -Destination $rSafety -Force -ErrorAction Stop
            Write-LaiLog OK "Current deep research data saved as $rSafety"
        }
        $rTouched = $true
        Invoke-Docker -Arguments @('run', '--rm', '-v', "${ResearchVolume}:/data", '-v', "${staged}:/restore.tar.gz:ro", $img, 'sh', '-c', $rSwap) | Out-Null
        if ($env:LOCALAI_TEST_FAIL_RESEARCH_SWAP) { throw 'Test hook: deep research swap failed' }
        Write-LaiLog OK "Deep research data restored from $($source.Name)"
    } catch {
        $code = 1
        Write-LaiLog FAIL $_.Exception.Message
        Get-ChildItem -LiteralPath $backupDir -Filter 'incomplete-deep-research-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        if ($rTouched) {
            if ($rSafety -and (Test-Path -LiteralPath $rSafety)) {
                try {
                    Invoke-Docker -Arguments @('run', '--rm', '-v', "${ResearchVolume}:/data", '-v', "${rSafety}:/restore.tar.gz:ro", $img, 'sh', '-c', $rBack) | Out-Null
                    Write-LaiLog OK 'The data from before the restore was put back.'
                } catch {
                    $keepStopped = $true
                    Write-LaiLog FAIL "Putting the earlier data back failed too ($($_.Exception.Message)). Deep research is kept stopped; the earlier data is in ${rSafety}: run this again with -DeepResearch -Archive '$rSafety'."
                }
            } else {
                # No safety copy (-SkipSafetyBackup, or a new volume): the volume may be half written.
                $keepStopped = $true
                Write-LaiLog FAIL "Deep research is kept stopped (its data may be incomplete): run this again with -DeepResearch -Archive '$($source.FullName)'."
            }
        }
    } finally {
        if ($policy -and $policy -ne 'no' -and -not $keepStopped) { Invoke-Docker -Arguments @('update', '--restart', $policy, $ResearchContainer) -AllowFail | Out-Null }
        if ($wasRunning -and -not $keepStopped) {
            if ((Invoke-Docker -Arguments @('start', $ResearchContainer) -AllowFail).ExitCode -ne 0) { Write-LaiLog WARN 'Deep research did not start again: Start menu > Local AI > Start again.' }
        }
        Remove-Item -LiteralPath (Join-Path $stagingDir 'restore-deep-research.tar.gz') -Force -ErrorAction SilentlyContinue
        Exit-LaiVolumeLock $lock
    }
    exit $code
}

# Pick and confirm the archive before taking the lock, so an unanswered prompt never blocks the
# nightly backup.
if (-not $Archive) {
    $newest = Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.LastWriteTime -le (Get-Date).AddHours(1) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects (never one dated in the future)
    if (-not $newest) { throw "No daily backups found in $backupDir. Pass -Archive <file>." }
    $Archive = $newest.FullName
}
if (-not (Test-Path -LiteralPath $Archive)) { throw "Archive not found: $Archive" }
if (-not $Force) {
    $info = Get-Item -LiteralPath $Archive
    Write-LaiLog WARN ("This replaces ALL current Open WebUI data (chats, memories, knowledge, settings) with {0} from {1}." -f $info.Name, $info.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    Write-LaiLog INFO 'A verified safety backup of the current data is taken first, and the swap rolls back if anything fails.'
    if ((Read-Host 'Type YES to restore') -cne 'YES') { Write-LaiLog INFO 'Nothing changed.'; exit 1 }
}

try {
    $lock = Enter-LaiVolumeLock

    # 1. Archive selection and staging copy.
    if (-not $Archive) {
        $newest = Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.LastWriteTime -le (Get-Date).AddHours(1) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects (never one dated in the future)
        if (-not $newest) { throw "No daily backups found in $backupDir. Pass -Archive <file>." }
        $Archive = $newest.FullName
    }
    $source = Get-Item -LiteralPath $Archive
    # Without the engine every archive would look unreadable below: say what is actually wrong.
    if ((Invoke-Docker -Arguments @('version', '--format', '{{.Server.Version}}') -AllowFail).ExitCode -ne 0) {
        throw 'Docker Desktop is not running, so the backup could not be opened. Start it (Start menu > Local AI - Start again), wait until it says Engine running, then run the restore again. Nothing was checked or changed.'
    }
    if (-not (Test-Path -LiteralPath $stagingDir)) { New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null }
    $staged = Join-Path $stagingDir 'restore.tar.gz'
    Copy-Item -LiteralPath $source.FullName -Destination $staged -Force
    if (-not (Test-Archive $staged)) { throw "$($source.Name) is not a valid Open WebUI backup (unreadable, or no top-level webui.db)." }
    Write-LaiLog INFO ("Restoring {0} ({1:N1} MB, {2})" -f $source.Name, ($source.Length / 1MB), $source.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))

    # The named container, if it exists, must actually use this volume for its data.
    $mounts = Invoke-Docker -Arguments @('inspect', '--type', 'container', '--format', '{{range .Mounts}}{{.Name}}|{{.Destination}}{{println}}{{end}}', $Container) -AllowFail
    if ($mounts.ExitCode -eq 0 -and $mounts.Text -notmatch ('(?m)^' + [regex]::Escape($Volume) + '\|/app/backend/data\s*$')) {
        throw "Container '$Container' does not keep its data in volume '$Volume'; refusing to restore into the wrong place."
    }

    # 2. Safety backup (verified, never pruned or mirrored here).
    $volumeExists = (Invoke-Docker -Arguments @('volume', 'inspect', $Volume) -AllowFail).ExitCode -eq 0
    if (-not $volumeExists) {
        Write-LaiLog INFO "Volume '$Volume' does not exist yet; creating it (nothing to back up)."
        Invoke-Docker -Arguments @('volume', 'create', $Volume) | Out-Null
    } elseif ($SkipSafetyBackup) {
        Write-LaiLog WARN 'No safety backup (-SkipSafetyBackup): the current data cannot be recovered if this restore is wrong.'
    } else {
        $before = @(Get-ChildItem -LiteralPath $backupDir -Filter '*-pre-restore.tar.gz' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        # No SQLite deep check here: when the live database is the thing that is broken, that check
        # would quarantine the safety copy and block the very restore meant to fix it.
        & (Join-Path $PSScriptRoot 'Backup-OpenWebUI.ps1') -AIRoot $AIRoot -Volume $Volume -Container $Container -Tag 'pre-restore' -NoPrune -NoMirror -SkipDeepVerify
        $safety = Get-ChildItem -LiteralPath $backupDir -Filter '*-pre-restore.tar.gz' | Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
        if ($LASTEXITCODE -ne 0 -or -not $safety -or -not (Test-Archive $safety.FullName)) {
            throw "The safety backup of your current data failed, so nothing was changed. The reason is in $(Join-Path (Join-Path $AIRoot 'Logs') 'backup.log') (most often: the disk is full). Fix that, then run the restore again."
        }
    }

    # 3. Stop everything that uses the volume, then swap.
    $users = @((Invoke-Docker -Arguments @('ps', '-q', '--filter', "volume=$Volume")).Text -split "`n" | Where-Object { $_ })
    # A run cut off after turning a policy off (below) left the container running with policy 'no'
    # and the original in its hold: take it from there, or the recovery would keep 'no' for good.
    $earlier = Get-LaiWebUIHold -AIRoot $AIRoot
    $toStop = @()
    foreach ($id in $users) {
        $policy = (Invoke-Docker -Arguments @('inspect', '-f', '{{.HostConfig.RestartPolicy.Name}}', $id) -AllowFail).Text.Trim()
        if (-not $policy) { $policy = 'no' }
        if ($policy -eq 'no' -and $earlier -and $earlier['Containers']) {
            foreach ($h in @($earlier['Containers'])) { if ([string]$h['Id'] -eq $id -and $h['Policy']) { $policy = [string]$h['Policy'] } }
        }
        $toStop += [pscustomobject]@{ Id = $id; Policy = $policy }
    }
    # Recorded BEFORE any container is touched: if this window is closed or the PC loses power from
    # here on, no catch or finally runs. Once the swap has started the volume may be half replaced;
    # even before it, a container may be left with its restart policy off (it would then stay down
    # after every reboot, with nothing saying why). The hold keeps the watch, Start again and the
    # installer from starting Open WebUI, says how to finish, and holds the original policies the
    # recovery puts back. Cleared on success, and on a failure before the swap.
    $priorHold = Test-Path -LiteralPath $holdPath
    if (-not $priorHold) {
        $script:recoverCmd = "& $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive $(ConvertTo-LaiPsQuoted (Get-Item -LiteralPath $Archive).FullName) -SkipSafetyBackup"
        if ($safety) { $script:holdArchive = $safety.FullName }
        Set-Hold 'a restore was interrupted (or is still running)' $toStop
        $script:holdWritten = $true
    }
    foreach ($c in $toStop) {
        # Listed before its policy is turned off: if that or the stop fails (or Ctrl+C), 'finally'
        # still puts the policy back and starts it.
        $stoppedContainers += $c
        Invoke-Docker -Arguments @('update', '--restart', 'no', $c.Id) -AllowFail | Out-Null   # keep it down even across a reboot
        Invoke-Docker -Arguments @('stop', '-t', '30', $c.Id) | Out-Null
    }
    if (@((Invoke-Docker -Arguments @('ps', '-q', '--filter', "volume=$Volume")).Text -split "`n" | Where-Object { $_ }).Count -gt 0) {
        throw "Something restarted a container on volume '$Volume'; aborting before any change."
    }
    $volumeTouched = $true
    Invoke-Swap $staged
    Write-LaiLog OK "Volume '$Volume' now holds $($source.Name)"
    # Recovering from an earlier failed restore: its containers are already stopped (so not listed
    # above) and their policy is 'no'. Only now that the data is good, bring them back with the
    # policy they had (adding them before the swap would start them on the damaged volume on failure).
    $hold = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($hold -and $hold['Containers']) {
        foreach ($h in @($hold['Containers'])) {
            if (@($stoppedContainers | ForEach-Object { $_.Id }) -notcontains $h['Id'] -and
                (Invoke-Docker -Arguments @('inspect', '--type', 'container', $h['Id']) -AllowFail).ExitCode -eq 0) {
                $stoppedContainers += [pscustomobject]@{ Id = [string]$h['Id']; Policy = [string]$h['Policy'] }
            }
        }
    }
    # The data is in place: clear the hold while still holding the lock, so nothing (Start again, a
    # waiting update, the nightly backup) sees a stale "interrupted" hold after a restore that worked.
    Clear-Hold 'Restore complete: Open WebUI may run again'
} catch {
    $failure = $_.Exception.Message
    Write-LaiLog FAIL $failure
    if ($volumeTouched) {
        if ($safety) {
            Write-LaiLog WARN "Rolling back to the safety backup $($safety.Name)"
            $rolledBack = $false
            try {
                Invoke-Swap $safety.FullName
                Write-LaiLog OK 'Rollback complete: the volume is as it was before the restore.'
                $rolledBack = $true
            }
            catch {
                Write-LaiLog FAIL "Rollback failed too: $($_.Exception.Message)"
                $script:recoverCmd = "& $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive $(ConvertTo-LaiPsQuoted $safety.FullName) -SkipSafetyBackup"
                $script:holdArchive = $safety.FullName
                Write-LaiLog FAIL "Open WebUI is left STOPPED (the health watch will not start it). Recover with: $script:recoverCmd"
                # Hold the list first, clear it, then record: if writing the hold fails (full disk), the
                # 'finally' below must still not start Open WebUI on the damaged volume.
                $held = $stoppedContainers
                $stoppedContainers = @()
                try { Set-Hold 'restore and its rollback failed' $held } catch { Write-LaiLog FAIL "Could not record the hold ($($_.Exception.Message)): do NOT start Open WebUI until the restore succeeds." }
            }
            # The data is good again: drop the in-progress hold this run wrote (not an older one).
            # Outside the rollback's try, so a failed delete is not mistaken for a failed rollback.
            if ($rolledBack -and -not $priorHold) { Clear-Hold '' }
        } else {
            # A command that works when pasted: the newest other nightly backup (not the one that just
            # failed, not one dated in the future). Without one, say where to pick a file.
            $other = Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.FullName -ne $source.FullName -and $_.LastWriteTime -le (Get-Date).AddHours(1) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
            if ($other) {
                $script:recoverCmd = "& $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive $(ConvertTo-LaiPsQuoted $other.FullName) -SkipSafetyBackup"
            } else {
                $script:recoverCmd = "no other nightly backup in $backupDir; copy one from your backup mirror there, then run: & $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive <that file> -SkipSafetyBackup"
            }
            Write-LaiLog FAIL "No safety backup exists; Open WebUI is left STOPPED so it cannot start on a damaged volume (the health watch will not start it). Recover with: $script:recoverCmd"
            # Hold the list first, clear it, then record: if writing the hold fails (full disk), the
            # 'finally' below must still not start Open WebUI on the damaged volume.
            $held = $stoppedContainers
            $stoppedContainers = @()
            try { Set-Hold 'restore failed without a safety backup' $held } catch { Write-LaiLog FAIL "Could not record the hold ($($_.Exception.Message)): do NOT start Open WebUI until the restore succeeds." }
        }
    }
    $script:restoreFailed = $true
} finally {
    foreach ($c in $stoppedContainers) {
        try {
            Invoke-Docker -Arguments @('update', '--restart', $c.Policy, $c.Id) -AllowFail | Out-Null
            Invoke-Docker -Arguments @('start', $c.Id) | Out-Null
        } catch { Write-LaiLog WARN "Could not restart container $($c.Id): $($_.Exception.Message)" }
    }
    # Stopped before the swap (an error, or Ctrl+C, which skips 'catch' but not 'finally'): the data
    # was never touched and the containers are back, so drop the in-progress hold this run wrote.
    # After a good restore it is already gone; after a failed swap volumeTouched keeps it.
    if ($script:holdWritten -and -not $volumeTouched) { Clear-Hold '' }
    if ($staged -and (Test-Path -LiteralPath $staged)) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
    Exit-LaiVolumeLock $lock
}
if ($script:restoreFailed) { exit 1 }
# Normally cleared under the lock already (above); a last try that never throws.
Clear-Hold 'Earlier failed restore cleared: Open WebUI may run again'

# 4. Wait for Open WebUI.
if ($stoppedContainers.Count -gt 0) {
    $config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
    $port = 3000
    if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
    $up = $false
    try { Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec 300; Write-LaiLog OK "Open WebUI is back on http://localhost:$port"; $up = $true }
    catch { Write-LaiLog WARN "Data restored, but Open WebUI did not answer within 5 minutes: check 'docker logs --tail 100 $Container'." }

    # 5. The restored database carries the settings from when the backup was taken, including the
    # Ollama connection: a backup from before the render guard points straight at Ollama. Put the
    # connection this install uses back (the installer recorded it).
    if ($up) {
        $expected = 'http://render-guard:11434'
        if ($config.ContainsKey('WebUIOllamaUrl') -and $config['WebUIOllamaUrl']) { $expected = [string]$config['WebUIOllamaUrl'] }
        $credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
        try {
            try { Resolve-LaiPendingPassword -AIRoot $AIRoot -BaseUrl "http://127.0.0.1:$port" | Out-Null } catch { Write-Verbose 'pending password check failed' }
            $cred = Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json
            $token = Connect-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -Email $cred.email -Password $cred.password
            if (Set-LaiWebUIOllamaUrl -BaseUrl "http://127.0.0.1:$port" -Token $token -OllamaUrl $expected) {
                Write-LaiLog OK "Re-applied this install's Ollama connection ($expected) to the restored settings"
            }
        } catch {
            Write-LaiLog WARN (("Could not sign in with {0}: the restored data has the admin password from when the backup was taken. " -f $credFile) +
                'Run Set-OpenWebUIPassword.ps1 -PromptCurrent (type that old password), then re-run Install-LocalAI.ps1 to re-apply presets and the render guard.')
        }
    }
}
exit 0
