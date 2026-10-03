#Requires -Version 5.1
<#
.SYNOPSIS
    Lightweight health watch for the local AI stack, meant to run every 15 minutes as a scheduled task.

.DESCRIPTION
    Checks, in about a second and without loading any model or signing in:
      Ollama API, Open WebUI /health, SearXNG /healthz, the two containers, and the newest backup
      (younger than 50 h and not quarantined as -CORRUPT).
    Self-heals what is safe to heal (starts a stopped container, relaunches the Ollama tray app) unless
    -NoHeal. Shows a Windows notification once when a check has failed on two runs in a row (and once
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
    [switch]$NoNotify
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
$healed = @()

$results['Ollama'] = Test-Url "$ollamaUrl/api/version"
if (-not $results['Ollama'] -and -not $NoHeal -and $onWindows) {
    $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
    if (Test-Path -LiteralPath $app) {
        Start-Process -FilePath $app
        try { Wait-LaiHttp -Uri "$ollamaUrl/api/version" -TimeoutSec 60 | Out-Null; $results['Ollama'] = $true; $healed += 'Ollama' } catch { Write-Verbose 'Ollama did not come back' }
    }
}

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

$backupDir = Join-Path $AIRoot 'Backups'
$all = @(Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)  # lai-ok: objects
$results['Backups'] = ($all.Count -gt 0) -and ($all[0].Name -notlike '*-CORRUPT.tar.gz') -and (((Get-Date) - $all[0].LastWriteTime).TotalHours -le 50)

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

$line = '{0} {1}{2}' -f (Get-Date -Format 's'), $(if ($failed.Count) { 'FAIL ' + ($failed -join ', ') } else { 'OK' }), $(if ($healed.Count) { ' (restarted: ' + ($healed -join ', ') + ')' } else { '' })
Add-Content -LiteralPath $logFile -Value $line
Write-Verbose $line

if ($toNotify.Count -gt 0) {
    Send-Notification 'Local AI: problem detected' ("Not working: {0}. Run {1} for details." -f ($failed -join ', '), (Join-Path $AIRoot 'Scripts\Test-LocalAI.ps1'))
} elseif ($failed.Count -eq 0 -and ($recovered.Count -gt 0 -or $healed.Count -gt 0)) {
    $parts = @()
    if ($healed.Count -gt 0) { $parts += 'restarted ' + ($healed -join ', ') }
    $other = @($recovered | Where-Object { $healed -notcontains $_ })
    if ($other.Count -gt 0) { $parts += 'recovered ' + ($other -join ', ') }
    Send-Notification 'Local AI: back to normal' (($parts -join '; ') + '.')
}

Save-LaiState -State @{ failed = $failed; notified = $notified; checked = (Get-Date).ToString('s') } -Path $statePath
exit $failed.Count
