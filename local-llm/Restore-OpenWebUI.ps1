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
#>
param(
    [string]$AIRoot = 'C:\AI',
    [string]$Archive = '',
    [switch]$SkipSafetyBackup,
    [string]$Volume = 'open-webui',
    [string]$Container = 'open-webui',
    [string]$HelperImage = 'alpine:3.20',
    # Skip the "type YES" confirmation (scripts, automation).
    [switch]$Force
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
function Set-Hold([string]$Why) {
    # Keep Open WebUI down until a restore succeeds: the watch, Start-LocalAI and the installer
    # check this file. The original restart policies are kept here so the recovery can put them back.
    $list = @($stoppedContainers | ForEach-Object { @{ Id = $_.Id; Policy = $_.Policy } })
    $ids = @($list | ForEach-Object { $_['Id'] })
    $old = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($old -and $old['Containers']) { foreach ($c in @($old['Containers'])) { if ($ids -notcontains $c['Id']) { $list += $c } } }
    Save-LaiState -State @{ Reason = $Why; Recover = $script:recoverCmd; Containers = $list; Since = (Get-Date).ToString('s') } -Path $holdPath
}

# Pick and confirm the archive before taking the lock, so an unanswered prompt never blocks the
# nightly backup.
if (-not $Archive) {
    $newest = Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
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
            Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
        if (-not $newest) { throw "No daily backups found in $backupDir. Pass -Archive <file>." }
        $Archive = $newest.FullName
    }
    $source = Get-Item -LiteralPath $Archive
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
            throw 'Safety backup failed; nothing was changed. Fix the error above (or use -SkipSafetyBackup).'
        }
    }

    # 3. Stop everything that uses the volume, then swap.
    $users = @((Invoke-Docker -Arguments @('ps', '-q', '--filter', "volume=$Volume")).Text -split "`n" | Where-Object { $_ })
    foreach ($id in $users) {
        $policy = (Invoke-Docker -Arguments @('inspect', '-f', '{{.HostConfig.RestartPolicy.Name}}', $id) -AllowFail).Text.Trim()
        if (-not $policy) { $policy = 'no' }
        Invoke-Docker -Arguments @('update', '--restart', 'no', $id) -AllowFail | Out-Null   # keep it down even across a reboot
        Invoke-Docker -Arguments @('stop', '-t', '30', $id) | Out-Null
        $stoppedContainers += [pscustomobject]@{ Id = $id; Policy = $policy }
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
} catch {
    $failure = $_.Exception.Message
    Write-LaiLog FAIL $failure
    if ($volumeTouched) {
        if ($safety) {
            Write-LaiLog WARN "Rolling back to the safety backup $($safety.Name)"
            try { Invoke-Swap $safety.FullName; Write-LaiLog OK 'Rollback complete: the volume is as it was before the restore.' }
            catch {
                Write-LaiLog FAIL "Rollback failed too: $($_.Exception.Message)"
                $script:recoverCmd = ".\Restore-OpenWebUI.ps1 -Archive '$($safety.FullName)' -SkipSafetyBackup"
                Write-LaiLog FAIL "Open WebUI is left STOPPED (the health watch will not start it). Recover with: $script:recoverCmd"
                Set-Hold 'restore and its rollback failed'
                $stoppedContainers = @()
            }
        } else {
            $script:recoverCmd = '.\Restore-OpenWebUI.ps1 -Archive <a good backup> -SkipSafetyBackup'
            Write-LaiLog FAIL "No safety backup exists; Open WebUI is left STOPPED so it cannot start on a damaged volume (the health watch will not start it). Recover with: $script:recoverCmd"
            Set-Hold 'restore failed without a safety backup'
            $stoppedContainers = @()
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
    if ($staged -and (Test-Path -LiteralPath $staged)) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
    Exit-LaiVolumeLock $lock
}
if ($script:restoreFailed) { exit 1 }
if (Test-Path -LiteralPath $holdPath) { Remove-Item -LiteralPath $holdPath -Force; Write-LaiLog OK 'Earlier failed restore cleared: Open WebUI may run again' }

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
            $cred = Get-Content -LiteralPath $credFile -Raw | ConvertFrom-Json
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
