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
#>
[CmdletBinding()]
param(
    [string]$AIRoot = 'C:\AI',
    [switch]$NoHeal,
    [switch]$NoNotify,
    # Warn when the drive with the models, backups or Docker's data has less than this free.
    [int]$MinFreeGB = 10
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

# ---- checks ---------------------------------------------------------------------------------
$results = [ordered]@{}
$details = @{}
$healed = @()

$results['Ollama'] = Test-Url "$ollamaUrl/api/version"
if (-not $results['Ollama'] -and -not $NoHeal -and $onWindows) {
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
        if (-not $ok -and -not $NoHeal) {
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
        if (-not $rgOk -and -not $NoHeal -and ($rgState -eq 'exited' -or $rgState -eq 'created')) {
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
$results['Backups'] = ($all.Count -gt 0) -and ($all[0].Name -notlike '*-CORRUPT.tar.gz') -and (((Get-Date) - $all[0].LastWriteTime).TotalHours -le 50)

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
Add-Content -LiteralPath $logFile -Value $line
Write-Verbose $line

if ($toNotify.Count -gt 0) {
    Send-Notification 'Local AI: problem detected' ("Not working: {0}. Run {1} for details." -f $failedText, (Join-Path $AIRoot 'Scripts\Test-LocalAI.ps1'))
} elseif ($recovered.Count -gt 0 -or ($healed.Count -gt 0 -and $failed.Count -eq 0)) {
    $parts = @()
    if ($healed.Count -gt 0) { $parts += 'restarted ' + ($healed -join ', ') }
    $other = @($recovered | Where-Object { $healed -notcontains $_ })
    if ($other.Count -gt 0) { $parts += 'recovered ' + ($other -join ', ') }
    if ($failed.Count -eq 0) { Send-Notification 'Local AI: back to normal' (($parts -join '; ') + '.') }
    else { Send-Notification 'Local AI: partly recovered' ((($parts -join '; ') + '. Still not working: ' + $failedText + '.')) }
}

Save-LaiState -State @{ failed = $failed; notified = $notified; checked = (Get-Date).ToString('s') } -Path $statePath
exit $failed.Count
