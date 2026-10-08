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

    A backup leaves out the document-search and speech models Open WebUI downloaded (about 7 GB).
    The ones in the volume are kept through the swap, so Open WebUI does not fetch them again; only
    a volume that had none (a new PC, a wiped volume) downloads them at the first start, which can
    take longer than the 5 minutes this script waits for an answer.

    A backup carries the settings of its day, so once Open WebUI is back this install's own are
    applied again: its Ollama connection, sign-up off, and on the toolkit's presets no past-chat
    search, no code execution and (uncensored ones) no web search without being asked. An archive
    the nightly backup marked -EMPTY (made after the data was wiped) is never picked by itself, and
    until that mark is settled the pick is the last good backup, not the newest; naming an -EMPTY
    one with -Archive asks first.

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
# The 'for' line: a backup leaves out the document-search and speech models Open WebUI downloaded
# (cache/embedding/models and cache/whisper/models, about 7 GB), and the delete after it takes all
# the volume holds. So the two folders move into the staging tree first and come back with it,
# unless the archive brings its own. Every restore, and every rollback to a safety backup, used to
# end with Open WebUI downloading them again.
$swapScript = 'set -e; rm -rf /data/.restore-staging; mkdir /data/.restore-staging; ' +
    'tar xzf /restore.tar.gz -C /data/.restore-staging; test -f /data/.restore-staging/webui.db; ' +
    'for m in cache/embedding/models cache/whisper/models; do if [ -d /data/$m ]; then if [ ! -e /data/.restore-staging/$m ]; then ' +
    'mkdir -p /data/.restore-staging/${m%/*}; mv /data/$m /data/.restore-staging/$m; fi; fi; done; ' +
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
    $daily = @(Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.LastWriteTime -le (Get-Date).AddHours(1) } | Sort-Object LastWriteTime -Descending)  # lai-ok: objects (never one dated in the future)
    # While the nightly backup has the data marked as wiped (backup-state.json: emptied), a nightly
    # name proves nothing: a night whose database check did not run keeps one although it holds the
    # wiped data. So the last good archive is taken, or else the newest one made before the mark.
    $mark = $null
    try { $mark = (Read-LaiState -Path (Join-Path $AIRoot 'backup-state.json'))['emptied'] } catch { Write-Verbose 'backup state not read' }
    if ($mark -is [hashtable]) {
        $lastGood = ''; if ($mark['lastGood']) { $lastGood = Split-Path -Leaf ([string]$mark['lastGood']) }
        # (PowerShell 7 reads the saved time back as a date, Windows PowerShell 5.1 as text.)
        $at = $null; try { $at = [datetime]$mark['at'] } catch { Write-Verbose 'the mark has no usable date' }
        $when = 'an earlier night'; if ($at) { $when = $at.ToString('yyyy-MM-dd HH:mm') }
        $fromBefore = @($daily | Where-Object { $_.Name -eq $lastGood })
        if ($fromBefore.Count -eq 0 -and $at) {
            $stamp = $at.ToString('yyyyMMdd-HHmmss')
            $fromBefore = @($daily | Where-Object { [string]::CompareOrdinal($_.Name.Substring(11, 15), $stamp) -lt 0 })
        }
        if ($fromBefore.Count -eq 0) { throw "The nightly backup marked Open WebUI's data as wiped on $when, and no nightly backup from before that is in $backupDir. Pass -Archive <file> (one from your backup mirror, if you have one)." }
        Write-LaiLog INFO "The nightly backup marked Open WebUI's data as wiped on ${when}: taking $($fromBefore[0].Name), made before that."
        $daily = $fromBefore
    }
    if ($daily.Count -eq 0) { throw "No daily backups found in $backupDir. Pass -Archive <file>." }
    $Archive = $daily[0].FullName
}
if (-not (Test-Path -LiteralPath $Archive)) { throw "Archive not found: $Archive" }
# An archive the nightly backup set aside because the database had lost its users or chats (a wiped
# volume). It is never picked above; named on purpose, it gets a question of its own first.
$leaf = Split-Path -Leaf $Archive
if ($leaf -like '*-EMPTY.tar.gz') {
    Write-LaiLog WARN "$leaf was set aside by the nightly backup: Open WebUI's data was already wiped when it was made, so restoring it brings back an (almost) empty Open WebUI. Without -Archive the newest backup that still has the data is used."
    if (-not $Force -and (Read-Host 'Type YES to restore this emptied backup all the same') -cne 'YES') { Write-LaiLog INFO 'Nothing changed.'; exit 1 }
}
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
    $back = @((Invoke-Docker -Arguments @('ps', '--filter', "volume=$Volume", '--format', '{{.Names}} ({{.Image}}, {{.Status}})')).Text -split "`n" | Where-Object { $_.Trim() })
    if ($back.Count -gt 0) {
        throw "Something restarted a container on volume '$Volume' ($($back -join '; ')); aborting before any change."
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
# Why step 5 did not put this install's safety settings back; '' once it has.
$notReapplied = 'Open WebUI was not running, so its settings could not be reached'
if ($stoppedContainers.Count -gt 0) {
    $config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
    $port = 3000
    if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
    $up = $false
    # LOCALAI_TEST_WEBUI_WAIT_SEC: test hook, a shorter wait. It counts only as a positive whole
    # number: anything else keeps the 5 minutes.
    $waitSec = 300; $askedWait = 0
    if ($env:LOCALAI_TEST_WEBUI_WAIT_SEC -and [int]::TryParse([string]$env:LOCALAI_TEST_WEBUI_WAIT_SEC, [ref]$askedWait) -and $askedWait -gt 0) { $waitSec = $askedWait }
    try { Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec $waitSec; Write-LaiLog OK "Open WebUI is back on http://localhost:$port"; $up = $true }
    catch {
        # The models a backup leaves out came along in the swap if the volume had them. A volume that
        # had none (a new one, or the models were deleted) makes Open WebUI download them at this start.
        Write-LaiLog WARN "Data restored, but Open WebUI did not answer within $([math]::Round($waitSec / 60, 1)) minutes. It may still be fetching its document-search models (several GB, when the volume had none): give it some minutes, and check 'docker logs --tail 100 $Container'."
        if ($safety) {
            Write-LaiLog INFO "If it does not come up, the data from before this restore is in $($safety.Name). To go back to it: & $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive $(ConvertTo-LaiPsQuoted $safety.FullName)"
        }
        $notReapplied = 'Open WebUI did not answer'
    }

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
            # A try of its own: an error here is not a failed sign-in, and must not keep the safety
            # settings below from being put back.
            try {
                if ($env:LOCALAI_TEST_FAIL_OLLAMA_URL) { throw 'Test hook: the Ollama connection could not be set' }
                if (Set-LaiWebUIOllamaUrl -BaseUrl "http://127.0.0.1:$port" -Token $token -OllamaUrl $expected) {
                    Write-LaiLog OK "Re-applied this install's Ollama connection ($expected) to the restored settings"
                }
            } catch {
                Write-LaiLog WARN "Could not re-apply this install's Ollama connection ($expected) to the restored settings: $($_.Exception.Message). If chats get no answer, run Start menu > Local AI - Update toolkit"
            }
            # The same goes for what keeps your chats on this PC. A backup from before the toolkit
            # turned them off brings back sign-up for anyone who reaches the page, presets whose model
            # can search and read every past chat or run code, and uncensored presets that search the
            # web without being asked. A try of its own: an error here is not a failed sign-in.
            try {
                $base = "http://127.0.0.1:$port"
                Set-LaiWebUIAdminConfig -BaseUrl $base -Token $token -Changes @{ ENABLE_SIGNUP = $false } | Out-Null
                if ((Invoke-LaiApi -Uri "$base/api/v1/auths/admin/config" -Token $token).ENABLE_SIGNUP -ne $false) { throw "Open WebUI did not keep 'sign-up off'" }
                $catalogPath = Join-Path (Join-Path $PSScriptRoot 'config') 'models.psd1'
                if ($env:LOCALAI_TEST_CATALOG) { $catalogPath = $env:LOCALAI_TEST_CATALOG }
                $changed = @()
                $found = 0
                foreach ($m in (Get-LaiCatalog -Path $catalogPath -IncludeTrials).Models) {
                    $existing = Get-LaiWebUIModel -BaseUrl $base -Token $token -Id $m.Preset
                    # Not in the restored data (never set up, or deleted): nothing to make safe, and
                    # Set-LaiWebUIModel would create it.
                    if (-not $existing) { continue }
                    $found++
                    # The whole preset as Open WebUI returned it, so everything else on it is kept.
                    $form = ConvertTo-LaiHashtable $existing
                    if ($form['meta'] -isnot [hashtable]) { $form['meta'] = @{} }
                    $meta = $form['meta']
                    # Open WebUI takes a missing switch as ON, so a missing set of them is made.
                    foreach ($set in 'builtinTools', 'capabilities') { if ($meta[$set] -isnot [hashtable]) { $meta[$set] = @{} } }
                    $was = @()
                    if ($meta['builtinTools']['chats'] -ne $false) { $was += 'past-chat search' }
                    if ($meta['builtinTools']['code_interpreter'] -ne $false -or $meta['capabilities']['code_interpreter'] -ne $false) { $was += 'code execution' }
                    # The official presets search by default (the installer sets that); the others only when asked.
                    $auto = @($meta['defaultFeatureIds'] | Where-Object { $_ })
                    if (-not $m.Official -and $auto.Count -gt 0) { $was += 'on by default: ' + ($auto -join ', ') }
                    if ($was.Count -eq 0) { continue }
                    $meta['builtinTools']['chats'] = $false
                    $meta['builtinTools']['code_interpreter'] = $false
                    $meta['capabilities']['code_interpreter'] = $false
                    if (-not $m.Official) { $meta['defaultFeatureIds'] = @() }
                    $form['id'] = $m.Preset
                    if ($null -eq $form['params']) { $form['params'] = @{} }
                    Set-LaiWebUIModel -BaseUrl $base -Token $token -Model $form | Out-Null
                    $changed += "$($m.Display) ($($was -join ', '))"
                }
                # None of them there (a backup of another install, presets since retired): no preset was
                # looked at, so nothing may say the presets are fine. The warning below gives the way.
                if ($found -eq 0) { throw "sign-up is off again, but none of the toolkit's presets is in the restored data, so no preset was checked" }
                $what = 'all had past-chat search and code execution off already'
                if ($changed.Count -gt 0) { $what = 'turned off on the restored presets: ' + ($changed -join '; ') }
                Write-LaiLog OK "Re-applied this install's safety settings to the restored data: sign-up off; $found toolkit preset(s) checked, $what"
                $notReapplied = ''
            } catch { $notReapplied = $_.Exception.Message }
        } catch {
            Write-LaiLog WARN (("Could not sign in with {0}: the restored data has the admin password from when the backup was taken. " -f $credFile) +
                'Run Set-OpenWebUIPassword.ps1 -PromptCurrent (type that old password), then re-run Install-LocalAI.ps1 to re-apply presets and the render guard.')
            $notReapplied = 'the sign-in failed (set the password right first, as said above)'
        }
    }
}
if ($notReapplied) {
    Write-LaiLog WARN ("The restored data has the settings from when the backup was taken, and this install's safety settings (sign-up off; past-chat search, code execution and unasked web search off on the presets) were not put back: $notReapplied. " +
        'To put them back, run Start menu > Local AI - Update toolkit')
}
exit 0
