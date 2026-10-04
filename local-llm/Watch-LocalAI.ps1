#Requires -Version 5.1

<#
.SYNOPSIS
    Lightweight health watch for the local AI stack, meant to run every 15 minutes as a scheduled task.

.DESCRIPTION
    Checks, in about a second and without loading any model or signing in:
      Ollama API, Docker engine, Open WebUI /health, SearXNG /healthz, the render-guard container,
      the newest backup (younger than 50 h and not quarantined as -CORRUPT), and free disk space on
      the drives holding the models, backups and Docker's data (at least -MinFreeGB).
    Self-heals what is safe to heal (starts a stopped container, relaunches the Ollama tray app) unless
    -NoHeal. Docker Desktop is never started by the watch (you may have quit it on purpose to free
    RAM); a stopped engine is reported once instead. Shows a Windows notification once when a check has failed on two runs in a row (and once
    when it recovers), so neither a slow Docker start nor a lasting outage spams you. Log: <AIRoot>\Logs\watch.log.

.EXAMPLE
    .\Watch-LocalAI.ps1              # one check, as the scheduled task runs it
.EXAMPLE
    .\Watch-LocalAI.ps1 -NoHeal -Verbose
.EXAMPLE
    .\Watch-LocalAI.ps1 -PauseMinutes 240   # quiet for 4 hours (gaming, stack stopped on purpose)
.EXAMPLE
    .\Watch-LocalAI.ps1 -Unpause
#>
[CmdletBinding()]
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    [switch]$NoHeal,
    # Log only; no Windows notification.
    [switch]$NoNotify,
    # Warn when the drive with the models, backups or Docker's data has less than this free.
    [int]$MinFreeGB = 10,
    # Silence the watch (no checks, restarts or notifications) for this many minutes, then exit.
    [int]$PauseMinutes = 0,
    [switch]$Unpause
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$webPort = 3000; if ($config.ContainsKey('WebUIPort')) { $webPort = [int]$config['WebUIPort'] }
$searxPort = 8888; if ($config.ContainsKey('SearxngPort')) { $searxPort = [int]$config['SearxngPort'] }
$ollamaUrl = 'http://127.0.0.1:11434'; if ($config.ContainsKey('OllamaUrl') -and $config['OllamaUrl']) { $ollamaUrl = $config['OllamaUrl'] }
$logDir = Join-Path $AIRoot 'Logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir 'watch.log'
$statePath = Join-Path $AIRoot 'watch-state.json'
$onWindows = ($env:OS -eq 'Windows_NT')
$notify = $onWindows -and -not $NoNotify
$healAllowed = -not $NoHeal

function Test-DockerEngine {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $null }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & docker version --format '{{.Server.Version}}' 2>$null | Out-Null; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    return ($code -eq 0)
}

function Get-FreeSpaceProblem {
    # Returns '' when every relevant drive has room, else e.g. 'C:\ 7.2 GB free'.
    param([string[]]$Paths, [int]$MinGB)
    $seen = @{}; $low = @()
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        $root = $null
        try { $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($p)) } catch { continue }
        if (-not $root -or $seen.ContainsKey($root)) { continue }
        $seen[$root] = $true
        try { $d = New-Object System.IO.DriveInfo($root) } catch { continue }
        if (-not $d.IsReady) { continue }
        $gb = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
        if ($gb -lt $MinGB) { $low += ('{0} {1} GB free' -f $root, $gb) }
    }
    return ($low -join ', ')
}

function Test-Url {
    param([string]$Uri)
    try { Invoke-LaiApi -Uri $Uri -TimeoutSec 5 | Out-Null; return $true } catch { return $false }
}

function Get-ContainerState {
    param([string]$Name)
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return 'no-docker' }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $s = (& docker inspect -f '{{.State.Status}}' $Name 2>$null); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { return 'missing' }
    return ([string]$s).Trim()
}

function Start-Container {
    param([string]$Name)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & docker start $Name 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
}

function Send-Notification {
    param([string]$Title, [string]$Text)
    Add-Content -LiteralPath $logFile -Value ('{0} NOTIFY {1}: {2}' -f (Get-Date -Format 's'), $Title, $Text)
    if (-not $notify) { return }
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $xml.GetElementsByTagName('text')
        [void]$nodes.Item(0).AppendChild($xml.CreateTextNode($Title))
        [void]$nodes.Item(1).AppendChild($xml.CreateTextNode($Text))
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch {
        Write-Verbose "toast failed: $($_.Exception.Message)"
    }
}

# ---- pause ----------------------------------------------------------------------------------
if ($PauseMinutes -gt 0 -or $Unpause) {
    $st = Read-LaiState -Path $statePath
    if ($Unpause) {
        $st.Remove('pausedUntil')
        $msg = 'watch resumed'
    } else {
        $st['pausedUntil'] = (Get-Date).AddMinutes($PauseMinutes).ToString('s')
        $msg = "watch paused until $($st['pausedUntil'])"
    }
    Save-LaiState -State $st -Path $statePath
    Add-Content -LiteralPath $logFile -Value ('{0} {1}' -f (Get-Date -Format 's'), $msg)
    Write-LaiLog OK $msg
    exit 0
}
function Test-WatchPaused {
    # Re-read every time: Stop-LocalAI.ps1 may pause the watch while this run is still going.
    $st = Read-LaiState -Path $statePath
    if (-not ($st.ContainsKey('pausedUntil') -and $st['pausedUntil'])) { return $false }
    # PowerShell 7's ConvertFrom-Json already turns ISO strings into dates; 5.1 leaves strings.
    $until = $st['pausedUntil']
    if ($until -isnot [datetime]) { $until = [datetime]::Parse([string]$until, [Globalization.CultureInfo]::InvariantCulture) }
    return ((Get-Date) -lt $until)
}
function Test-CanHeal { return ($healAllowed -and -not (Test-WatchPaused)) }
if (Test-WatchPaused) { Write-Verbose 'paused'; exit 0 }

# ---- checks ---------------------------------------------------------------------------------
$results = [ordered]@{}
$details = @{}
$healed = @()
$maintenance = $false

$results['Ollama'] = Test-Url "$ollamaUrl/api/version"
if (-not $results['Ollama'] -and $onWindows -and (Test-CanHeal)) {
    $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
    if (Test-Path -LiteralPath $app) {
        Start-Process -FilePath $app
        try { Wait-LaiHttp -Uri "$ollamaUrl/api/version" -TimeoutSec 60 | Out-Null; $results['Ollama'] = $true; $healed += 'Ollama' } catch { Write-Verbose 'Ollama did not come back' }
    }
}

$engine = Test-DockerEngine
if ($engine -eq $false) {
    # Everything in the stack is down with it; report the cause once instead of three symptoms.
    $results['Docker'] = $false
    $details['Docker'] = 'engine not running - start Docker Desktop'
} else {
    foreach ($c in @(@{ Name = 'open-webui'; Url = "http://127.0.0.1:$webPort/health"; Key = 'Open WebUI' },
                     @{ Name = 'searxng'; Url = "http://127.0.0.1:$searxPort/healthz"; Key = 'SearXNG' })) {
        $ok = Test-Url $c.Url
        $hold = $null; if ($c.Name -eq 'open-webui') { $hold = Get-LaiWebUIHold -AIRoot $AIRoot }
        if (-not $ok -and $c.Name -eq 'open-webui' -and (Test-LaiVolumeLockBusy)) {
            # A backup, restore or update is running and stopped it on purpose (checked before the
            # hold: a restore in progress has written its hold already, but has not failed).
            $ok = $true
            $maintenance = $true
        } elseif (-not $ok -and $hold) {
            # Left stopped on purpose by a failed or interrupted restore: starting it could run on a damaged volume.
            $details[$c.Key] = "kept stopped after a failed restore - $($hold['Recover'])"
        } elseif (-not $ok -and (Test-CanHeal)) {
            $state = Get-ContainerState $c.Name
            if ($state -eq 'exited' -or $state -eq 'created') {
                Start-Container $c.Name
                try { Wait-LaiHttp -Uri $c.Url -TimeoutSec 180 | Out-Null; $ok = $true; $healed += $c.Key } catch { Write-Verbose "$($c.Key) did not come back" }
            }
        }
        $results[$c.Key] = $ok
    }

    # The render guard has no host port (only Open WebUI talks to it); if it is down, chats fail.
    $rgState = Get-ContainerState 'render-guard'
    if ($rgState -ne 'no-docker' -and $rgState -ne 'missing') {
        $rgOk = ($rgState -eq 'running')
        if (-not $rgOk -and ($rgState -eq 'exited' -or $rgState -eq 'created') -and (Test-CanHeal)) {
            Start-Container 'render-guard'
            Start-Sleep -Seconds 3
            $rgOk = ((Get-ContainerState 'render-guard') -eq 'running')
            if ($rgOk) { $healed += 'Render guard' }
        }
        $results['Render guard'] = $rgOk
    }
}

$backupDir = Join-Path $AIRoot 'Backups'
$all = @(Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)  # lai-ok: objects
# Freshness counts only the nightly archives: a tagged one (pre-restore, before-update, ...) must not
# hide a nightly task that stopped working.
$daily = @($all | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' })
$results['Backups'] = ($all.Count -gt 0) -and ($all[0].Name -notlike '*-CORRUPT.tar.gz') -and ($daily.Count -gt 0) -and (((Get-Date) - $daily[0].LastWriteTime).TotalHours -le 50)

$modelDir = ''
if ($config.ContainsKey('ModelDir') -and $config['ModelDir']) { $modelDir = [string]$config['ModelDir'] }
elseif ($env:USERPROFILE) { $modelDir = Join-Path $env:USERPROFILE '.ollama' }
$dockerData = ''
if ($onWindows -and $env:LOCALAPPDATA) { $dockerData = Join-Path $env:LOCALAPPDATA 'Docker' }
$diskProblem = Get-FreeSpaceProblem -Paths @($AIRoot, $modelDir, $dockerData) -MinGB $MinFreeGB
$results['Disk space'] = (-not $diskProblem)
if ($diskProblem) { $details['Disk space'] = $diskProblem }

# ---- report ---------------------------------------------------------------------------------
# Two strikes before a notification: right after sign-in Docker Desktop needs a minute or two, and
# one failed check would otherwise toast every morning. A failure is reported once, when it has
# been seen on two consecutive runs; "back to normal" follows only for failures that were reported.
$failed = @($results.Keys | Where-Object { -not $results[$_] })
$previous = Read-LaiState -Path $statePath
$prevFailed = @(); $prevNotified = @()
if ($previous.ContainsKey('failed') -and $previous['failed']) { $prevFailed = @($previous['failed']) }
if ($previous.ContainsKey('notified') -and $previous['notified']) { $prevNotified = @($previous['notified']) }
$toNotify = @($failed | Where-Object { ($prevFailed -contains $_) -and ($prevNotified -notcontains $_) })
$notified = @($failed | Where-Object { ($prevNotified -contains $_) -or ($toNotify -contains $_) })
$recovered = @($prevNotified | Where-Object { $failed -notcontains $_ })

$failedText = @($failed | ForEach-Object { if ($details.ContainsKey($_)) { '{0} ({1})' -f $_, $details[$_] } else { $_ } }) -join ', '
$line = '{0} {1}{2}' -f (Get-Date -Format 's'), $(if ($failed.Count) { 'FAIL ' + $failedText } else { 'OK' }), $(if ($healed.Count) { ' (restarted: ' + ($healed -join ', ') + ')' } else { '' })
if ($maintenance) { $line += ' (Open WebUI stopped for a backup/restore/update; left alone)' }
Add-Content -LiteralPath $logFile -Value $line
Write-Verbose $line

if ($toNotify.Count -gt 0) {
    # One concrete next step, using the Start-menu shortcuts (typed commands may be blocked by policy).
    $hint = 'Start menu > Local AI > Health check for details.'
    $heldNow = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($heldNow -and $failed -contains 'Open WebUI') {
        # Start again would refuse; the only fix is the recovery restore (the command is in the details).
        $hint = 'Open WebUI was kept stopped after a failed restore. Run the recovery command above in PowerShell as Administrator.'
    } elseif ($failed -contains 'Docker' -or $failed -contains 'Open WebUI' -or $failed -contains 'SearXNG' -or $failed -contains 'Render guard' -or $failed -contains 'Ollama') {
        $hint = 'Try Start menu > Local AI > Start again.'
    } elseif ($failed -contains 'Disk space') {
        $hint = 'Free some disk space (old backups in ' + (Join-Path $AIRoot 'Backups') + ', unused models).'
    } elseif ($failed -contains 'Backups') {
        $hint = 'Run Start menu > Local AI > Diagnostics and check backup.log.'
    }
    Send-Notification 'Local AI: problem detected' ("Not working: {0}. {1}" -f $failedText, $hint)
} elseif ($recovered.Count -gt 0 -or ($healed.Count -gt 0 -and $failed.Count -eq 0)) {
    $parts = @()
    if ($healed.Count -gt 0) { $parts += 'restarted ' + ($healed -join ', ') }
    $other = @($recovered | Where-Object { $healed -notcontains $_ })
    if ($other.Count -gt 0) { $parts += 'recovered ' + ($other -join ', ') }
    if ($failed.Count -eq 0) { Send-Notification 'Local AI: back to normal' (($parts -join '; ') + '.') }
    else { Send-Notification 'Local AI: partly recovered' ((($parts -join '; ') + '. Still not working: ' + $failedText + '.')) }
}

# Merge into the current file so a pause set while this run was busy survives.
$final = Read-LaiState -Path $statePath
$final['failed'] = $failed; $final['notified'] = $notified; $final['checked'] = (Get-Date).ToString('s')
Save-LaiState -State $final -Path $statePath
exit $failed.Count
