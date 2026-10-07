#Requires -Version 5.1

<#
.SYNOPSIS
    Lightweight health watch for the local AI stack, meant to run every 15 minutes as a scheduled task.

.DESCRIPTION
    Checks, in about a second and without loading any model or signing in:
      Ollama API, Docker engine, Open WebUI /health, SearXNG /healthz, the render-guard container,
      whether Open WebUI reaches Ollama (the path chats take), the newest backup (younger than 50 h
      and not quarantined as -CORRUPT), and free disk space on the drives holding the models, backups
      and Docker's data (at least -MinFreeGB).
    Self-heals what is safe to heal (starts a stopped container, relaunches the Ollama tray app) unless
    -NoHeal. Docker Desktop is never started by the watch (you may have quit it on purpose to free
    RAM); a stopped engine is reported once instead, and so is one that stopped answering (every
    docker call has a time limit). Shows a Windows notification once when a check has failed on two
    runs in a row (and once when it recovers), so neither a slow Docker start nor a lasting outage
    spams you. Log: <AIRoot>\Logs\watch.log.
    Also notifies once when Ollama has updated itself since the presets were tuned (Update-Models.ps1
    re-checks them on the GPU).

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
# A problem that persists is announced again after this many hours (a single toast is easy to miss:
# Focus Assist during a game, a busy morning), until it is fixed.
$remindHours = 24
# Windows' notification switch for PowerShell, as last seen by a toast ('' = no toast tried this run).
$script:toastSetting = ''

function Write-WatchLog([string]$Text) {
    # A full disk must not end the watch before it can tell anyone (the toast needs no disk space).
    try { Add-Content -LiteralPath $logFile -Value $Text -Encoding UTF8 -ErrorAction Stop } catch { Write-Verbose "watch.log not writable: $($_.Exception.Message)" }
}
function ConvertTo-WatchDate($Value) {
    # PowerShell 7's ConvertFrom-Json already turns ISO strings into dates; 5.1 leaves strings.
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value }
    try { return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

# Every docker call has a time limit: a Docker Desktop that stopped answering (it can after sleep)
# would otherwise hang this run until Task Scheduler ends it, with no log line and no notification.
$dockerLimit = Get-LaiDockerTimeout

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
    if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) { return 'no-docker' }
    $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('inspect', '-f', '{{.State.Status}}', $Name) -TimeoutSec $dockerLimit
    if ($r.TimedOut) { return 'no answer' }
    if ($r.ExitCode -ne 0) { return 'missing' }
    return ([string]$r.Out).Trim()
}

function Start-Container {
    param([string]$Name)
    Invoke-LaiTimedNative -File 'docker' -Arguments @('start', $Name) -TimeoutSec (2 * $dockerLimit) | Out-Null
}

function Send-Notification {
    # Returns $true when the message went out (or notifications are off, by this script's -NoNotify or
    # by Windows' own switch, and the log and banner are the channel), $false when the toast failed:
    # the caller then tries again on the next run.
    param([string]$Title, [string]$Text)
    # Test hooks (tests/Invoke-WatchTest.ps1): Windows' notification switch for PowerShell turned off
    # (the toast is dropped silently), and a toast that fails, as with a broken notification service.
    if ($env:LOCALAI_TEST_TOAST_SETTING) { $script:toastSetting = $env:LOCALAI_TEST_TOAST_SETTING; Write-WatchLog ('{0} NOTIFY (toast not shown, notifications are off: {1}) {2}: {3}' -f (Get-Date -Format 's'), $env:LOCALAI_TEST_TOAST_SETTING, $Title, $Text); return $true }
    if ($env:LOCALAI_TEST_TOAST_FAIL) { Write-WatchLog ('{0} NOTIFY (toast failed) {1}: {2}' -f (Get-Date -Format 's'), $Title, $Text); return $false }
    if (-not $notify) { Write-WatchLog ('{0} NOTIFY {1}: {2}' -f (Get-Date -Format 's'), $Title, $Text); return $true }
    $shown = $false; $why = ''
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $xml.GetElementsByTagName('text')
        [void]$nodes.Item(0).AppendChild($xml.CreateTextNode($Title))
        [void]$nodes.Item(1).AppendChild($xml.CreateTextNode($Text))
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
        # Show() does not fail when Windows has notifications off for PowerShell (or all apps, or by
        # policy): the toast is dropped silently. It is still shown (should the switch be misread,
        # nothing is lost), but retrying would not help until the switch is turned back on, so the
        # run goes on as if told; the Open WebUI banner below and the health check (which reports
        # the switch) carry the news instead.
        $setting = 'Enabled'
        try { $setting = [string]$notifier.Setting } catch { Write-Verbose "toast setting unknown: $($_.Exception.Message)" }
        $script:toastSetting = $setting
        $notifier.Show([Windows.UI.Notifications.ToastNotification]::new($xml))
        if ($setting -ne 'Enabled') { $why = "notifications are off: $setting" } else { $shown = $true }
    } catch {
        $why = $_.Exception.Message
        Write-Verbose "toast failed: $why"
    }
    $off = ($why -like 'notifications are off*')
    $tag = ''
    if ($off) { $tag = " (toast not shown, $why)" } elseif (-not $shown) { $tag = ' (toast failed)' }
    Write-WatchLog ('{0} NOTIFY{1} {2}: {3}' -f (Get-Date -Format 's'), $tag, $Title, $Text)
    return ($shown -or $off)
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
    Write-WatchLog ('{0} {1}' -f (Get-Date -Format 's'), $msg)
    Write-LaiLog OK $msg
    exit 0
}
function Test-WatchPaused {
    # Re-read every time: Stop-LocalAI.ps1 may pause the watch while this run is still going.
    $st = Read-LaiState -Path $statePath
    if (-not ($st.ContainsKey('pausedUntil') -and $st['pausedUntil'])) { return $false }
    # PowerShell 7's ConvertFrom-Json already turns ISO strings into dates; 5.1 leaves strings.
    $until = ConvertTo-WatchDate $st['pausedUntil']
    return ($until -and (Get-Date) -lt $until)
}
function Test-CanHeal { return ($healAllowed -and -not (Test-WatchPaused)) }
if (Test-WatchPaused) { Write-Verbose 'paused'; exit 0 }

# ---- checks ---------------------------------------------------------------------------------
$results = [ordered]@{}
$details = @{}
$healed = @()
$maintenance = $false

$ollamaVer = ''
try { $ollamaVer = [string](Invoke-LaiApi -Uri "$ollamaUrl/api/version" -TimeoutSec 5).version; $results['Ollama'] = $true } catch { $results['Ollama'] = $false }
if (-not $results['Ollama'] -and $onWindows -and (Test-CanHeal)) {
    $app = Get-LaiOllamaAppPath
    if ($app -and (Test-Path -LiteralPath $app)) {
        Start-LaiOllamaApp -Path $app
        try { $ollamaVer = [string](Wait-LaiHttp -Uri "$ollamaUrl/api/version" -TimeoutSec 60).version; $results['Ollama'] = $true; $healed += 'Ollama' } catch { Write-Verbose 'Ollama did not come back' }
    }
}

$engine = Test-LaiDockerEngine -TimeoutSec $dockerLimit
if ($engine -eq 'down' -or $engine -eq 'hung') {
    # Everything in the stack is down with it; report the cause once instead of three symptoms.
    $results['Docker'] = $false
    if ($engine -eq 'hung') { $details['Docker'] = "not responding (no answer within $dockerLimit s) - restart Docker Desktop (whale icon > Restart)" }
    else { $details['Docker'] = 'engine not running - start Docker Desktop' }
} else {
    $watched = @(@{ Name = 'open-webui'; Url = "http://127.0.0.1:$webPort/health"; Key = 'Open WebUI' },
                 @{ Name = 'searxng'; Url = "http://127.0.0.1:$searxPort/healthz"; Key = 'SearXNG' })
    # The optional research agent (Install-LocalAI.ps1 -DeepResearch), healed like the others.
    if ($config.ContainsKey('DeepResearchPort') -and [int]$config['DeepResearchPort'] -gt 0) {
        $watched += @{ Name = 'deep-research'; Url = "http://127.0.0.1:$([int]$config['DeepResearchPort'])/api/v1/health"; Key = 'Deep research' }
    }
    foreach ($c in $watched) {
        $ok = Test-Url $c.Url
        $hold = $null; if ($c.Name -eq 'open-webui') { $hold = Get-LaiWebUIHold -AIRoot $AIRoot }
        if (-not $ok -and @('open-webui', 'deep-research') -contains $c.Name -and (Test-LaiVolumeLockBusy)) {
            # A backup, restore or update is running and stopped (or paused) it on purpose (checked
            # before the hold: a restore in progress has written its hold already, but has not failed).
            $ok = $true
            $maintenance = $true
        } elseif (-not $ok -and $hold) {
            # Left stopped on purpose by a failed or interrupted restore: starting it could run on a damaged volume.
            $details[$c.Key] = "kept stopped after a failed restore - $($hold['Recover'])"
        } elseif (-not $ok -and (Test-CanHeal)) {
            $state = Get-ContainerState $c.Name
            if ($state -eq 'paused') {
                # Only a backup pauses deep research, under the volume lock (free now): one killed
                # mid-copy left it frozen, and 'docker start' does not wake a paused container.
                Invoke-LaiTimedNative -File 'docker' -Arguments @('unpause', $c.Name) -TimeoutSec (2 * $dockerLimit) | Out-Null
                try { Wait-LaiHttp -Uri $c.Url -TimeoutSec 180 | Out-Null; $ok = $true; $healed += $c.Key } catch { Write-Verbose "$($c.Key) did not come back" }
            } elseif ($state -eq 'exited' -or $state -eq 'created') {
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
        if ($rgState -eq 'no answer') { $details['Render guard'] = "docker did not answer within $dockerLimit s - restart Docker Desktop (whale icon > Restart)" }
    }

    # The path chats actually take: from inside the Open WebUI container to the Ollama URL it was
    # given (normally the render guard, which forwards to Ollama on this PC). A firewall rule that no
    # longer matches Docker's network after a reboot, or Docker's host networking broken after
    # sleep, makes every chat fail while each part above still looks fine on its own.
    if ($results['Ollama'] -and $results['Open WebUI'] -and -not $maintenance -and (Get-ContainerState 'open-webui') -eq 'running') {
        $chatUrl = 'http://render-guard:11434'
        if ($config.ContainsKey('WebUIOllamaUrl') -and $config['WebUIOllamaUrl']) { $chatUrl = [string]$config['WebUIOllamaUrl'] }
        $probe = "import sys,urllib.request as u;u.urlopen(sys.argv[1].rstrip('/')+'/api/version',timeout=10)"
        $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('exec', 'open-webui', 'python3', '-c', $probe, $chatUrl) -TimeoutSec $dockerLimit
        $results['Chats reach Ollama'] = ($r.ExitCode -eq 0)
        if (-not $results['Chats reach Ollama']) {
            $details['Chats reach Ollama'] = "Open WebUI cannot reach Ollama at $chatUrl - restart Docker Desktop; if that does not help, run Start menu > Local AI - Update toolkit"
        }
    }
}

$backupDir = Join-Path $AIRoot 'Backups'
$all = @(Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)  # lai-ok: objects
# Freshness counts only the nightly archives: a tagged one (pre-restore, before-update, ...) must not
# hide a nightly task that stopped working.
# An archive dated in the future (written while the clock was wrong) must not count as fresh (it would
# hide a dead nightly task for months) and never ages out by itself: judge freshness on the others
# and ask for it to be deleted.
$soon = (Get-Date).AddHours(1)
$futureDaily = @($all | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.LastWriteTime -gt $soon })
$all = @($all | Where-Object { $_.LastWriteTime -le $soon })
$daily = @($all | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' })
$results['Backups'] = ($all.Count -gt 0) -and ($all[0].Name -notlike '*-CORRUPT.tar.gz') -and ($daily.Count -gt 0) -and (((Get-Date) - $daily[0].LastWriteTime).TotalHours -le 50)
$bstate = Read-LaiState -Path (Join-Path $AIRoot 'backup-state.json')
if ($futureDaily.Count) {
    $results['Backups'] = $false
    $details['Backups'] = "$($futureDaily[0].Name) is dated $($futureDaily[0].LastWriteTime.ToString('s')), in the future (the PC clock was wrong when it was made): delete it"
} elseif ($bstate['deepCheckSkips'] -and [int]$bstate['deepCheckSkips'] -ge 3) {
    # Backups exist, but their database check has not run for 3 nights: an empty or damaged webui.db
    # would not be noticed.
    $results['Backups'] = $false
    $details['Backups'] = "the database check of the nightly backup could not run for $([int]$bstate['deepCheckSkips']) nights (see backup.log)"
}
# The second copy (NAS, other drive): a mirror that stopped working is otherwise only a line in backup.log.
$mirrorTarget = ''
if ($config.ContainsKey('BackupMirror') -and $config['BackupMirror']) { $mirrorTarget = [string]$config['BackupMirror'] }
if ($mirrorTarget -and $daily.Count -gt 0) {
    $okAt = $null
    if ([string]$bstate['mirrorTarget'] -eq $mirrorTarget) { $okAt = ConvertTo-WatchDate $bstate['mirrorOkAt'] }
    if ($okAt -or $bstate['mirrorError']) {
        # The newest nightly archive must have been mirrored (within its own run).
        $results['Backup mirror'] = [bool]($okAt -and $okAt -ge $daily[0].LastWriteTime.AddHours(-2))
    } else {
        # No record yet (made by a version before this check, or a newly set mirror): look for the file.
        $results['Backup mirror'] = Test-Path -LiteralPath (Join-Path $mirrorTarget $daily[0].Name)
    }
    if (-not $results['Backup mirror']) {
        $why = 'newest backup not copied to ' + $mirrorTarget
        if ($bstate['mirrorError']) { $why += ': ' + [string]$bstate['mirrorError'] }
        $details['Backup mirror'] = $why
    }
}

$modelDir = ''
if ($config.ContainsKey('ModelDir') -and $config['ModelDir']) { $modelDir = [string]$config['ModelDir'] }
elseif ($env:USERPROFILE) { $modelDir = Join-Path $env:USERPROFILE '.ollama' }
$dockerData = ''
if ($onWindows -and $env:LOCALAPPDATA) { $dockerData = Join-Path $env:LOCALAPPDATA 'Docker' }
# Hysteresis: once low, the drive counts as fixed only with 2 GB more than the limit, so free space
# hovering around the limit (pagefile, temp files) does not toast 'problem'/'back to normal' all day.
$previous = Read-LaiState -Path $statePath
$diskLimit = $MinFreeGB
if ($previous.ContainsKey('failed') -and @($previous['failed']) -contains 'Disk space') { $diskLimit = $MinFreeGB + 2 }
$diskProblem = Get-FreeSpaceProblem -Paths @($AIRoot, $modelDir, $dockerData) -MinGB $diskLimit
$results['Disk space'] = (-not $diskProblem)
if ($diskProblem) { $details['Disk space'] = $diskProblem }

# ---- Ollama replaced by its own updater -------------------------------------------------------
# The Ollama app downloads updates by itself and installs them at the next sign-in (on by default).
# The presets' contexts were measured on one version; a new one can place layers differently, so a
# preset may now spill to the CPU. Not a failure (everything still answers): one notice per new
# version, outside the two-strike/reminder logic. $null = leave the record as it is.
$ollamaNotice = $null
$prevNotice = ''; if ($previous.ContainsKey('ollamaNotifiedFor')) { $prevNotice = [string]$previous['ollamaNotifiedFor'] }
if ($ollamaVer) {
    $inst = Read-LaiState -Path (Join-Path $AIRoot 'install-state.json')
    $tun = @{}; if ($inst['tuning'] -is [hashtable]) { $tun = $inst['tuning'] }
    $sel = @(); if ($config.ContainsKey('SelectedModels') -and $config['SelectedModels']) { $sel = @($config['SelectedModels']) }
    $drift = @(Get-LaiTuningDrift -Tuning $tun -OllamaVersion $ollamaVer -Keys $sel)
    if ($drift.Count -eq 0) { $ollamaNotice = '' }
    elseif ($prevNotice -ne $ollamaVer) {
        $was = @($drift | ForEach-Object { $_.Was } | Select-Object -Unique) -join ', '
        $which = @($drift | ForEach-Object { $_.Key }) -join ', '
        $updScript = Join-Path (Join-Path $AIRoot 'Scripts') 'Update-Models.ps1'
        $text = "Ollama updated itself to $ollamaVer; $which were measured on $was and may now run slower. Run $updScript to check them on the GPU again (about a minute each)."
        # Its settings too (a file read, no model load): a new version may no longer apply them.
        if ($onWindows -and $env:LOCALAPPDATA) {
            $kv = 'q8_0'
            foreach ($t in $tun.Values) { if ($t -is [hashtable] -and [string]$t['Fingerprint'] -match '(^|;)kv=([^;]+)') { $kv = $Matches[2]; break } }
            $srvLog = Join-Path $env:LOCALAPPDATA 'Ollama\server.log'
            $cfgLine = $null
            try { $cfgLine = Select-String -LiteralPath $srvLog -Pattern 'msg="server config"' -Encoding UTF8 -ErrorAction Stop | Select-Object -Last 1 } catch { Write-Verbose 'no server.log' }
            if ($cfgLine) {
                $chk = Test-LaiOllamaServerSettings -Line $cfgLine.Line -KvCacheType $kv
                if ($chk.Status -eq 'wrong') { $text += ' Its log also shows ' + ($chk.Wrong -join ', ') + ': Start menu > Local AI - Update toolkit applies the settings again.' }
            }
        }
        if (Send-Notification 'Local AI: Ollama was updated' $text) { $ollamaNotice = $ollamaVer }
    }
}

# ---- report ---------------------------------------------------------------------------------
# Two strikes before a notification: right after sign-in Docker Desktop needs a minute or two, and
# one failed check would otherwise toast every morning. A failure is reported when it has been seen
# on two consecutive runs, and again every $remindHours h while it lasts; "back to normal" follows
# only for failures that were reported.
$failed = @($results.Keys | Where-Object { -not $results[$_] })
$prevFailed = @(); $prevNotified = @()
if ($previous.ContainsKey('failed') -and $previous['failed']) { $prevFailed = @($previous['failed']) }
if ($previous.ContainsKey('notified') -and $previous['notified']) { $prevNotified = @($previous['notified']) }
$lastToast = ConvertTo-WatchDate $previous['notifiedAt']
$toNotify = @($failed | Where-Object { ($prevFailed -contains $_) -and ($prevNotified -notcontains $_) })
$stillReported = @($failed | Where-Object { $prevNotified -contains $_ })
$reminder = ($toNotify.Count -eq 0 -and $stillReported.Count -gt 0 -and (-not $lastToast -or ((Get-Date) - $lastToast).TotalHours -ge $remindHours))
if ($reminder) { $toNotify = $stillReported }
$notified = @($failed | Where-Object { ($prevNotified -contains $_) -or ($toNotify -contains $_) })
$recovered = @($prevNotified | Where-Object { $failed -notcontains $_ })
$notifiedAt = $previous['notifiedAt']
# A 'back to normal' that could not be shown is retried (else the last word stays 'problem detected').
$pendingRecovered = @()
if ($previous.ContainsKey('pendingRecovered') -and $previous['pendingRecovered']) { $pendingRecovered = @($previous['pendingRecovered'] | Where-Object { $failed -notcontains $_ }) }
$recovered = @(@($recovered) + @($pendingRecovered | Where-Object { $recovered -notcontains $_ }))
$recoveryFailed = $false

$failedText = @($failed | ForEach-Object { if ($details.ContainsKey($_)) { '{0} ({1})' -f $_, $details[$_] } else { $_ } }) -join ', '
$line = '{0} {1}{2}' -f (Get-Date -Format 's'), $(if ($failed.Count) { 'FAIL ' + $failedText } else { 'OK' }), $(if ($healed.Count) { ' (restarted: ' + ($healed -join ', ') + ')' } else { '' })
if ($maintenance) { $line += ' (Open WebUI stopped for a backup/restore/update; left alone)' }
Write-WatchLog $line
Write-Verbose $line

function Get-WatchHint([string[]]$Failed) {
    # One concrete next step, using the Start-menu shortcuts (typed commands may be blocked by policy).
    $hint = 'Start menu > Local AI - Health check shows details.'
    $heldNow = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($heldNow -and $failed -contains 'Open WebUI') {
        # Start again would refuse; the only fix is the recovery restore (the command is in the details).
        $hint = 'Open WebUI is stopped on purpose after a failed restore. The fix is the Recover line in ' + (Join-Path $AIRoot 'open-webui-hold.json') + ': paste it into PowerShell.'
    } elseif ($failed -contains 'Docker' -or $failed -contains 'Open WebUI' -or $failed -contains 'SearXNG' -or $failed -contains 'Render guard' -or $failed -contains 'Ollama' -or $failed -contains 'Chats reach Ollama') {
        $hint = 'Use Start menu > Local AI - Start again. If that does not help, restart Docker Desktop (whale icon > Restart) and use Start again once more.'
    } elseif ($failed -contains 'Disk space') {
        $hint = 'Free some disk space (old backups in ' + (Join-Path $AIRoot 'Backups') + ', unused models).'
    } elseif ($failed -contains 'Backups') {
        $hint = 'The reason is at the end of ' + (Join-Path (Join-Path $AIRoot 'Logs') 'backup.log') + '.'
    } elseif ($failed -contains 'Backup mirror') {
        $hint = 'Check that the backup mirror drive or NAS share is reachable and has free space.'
    }
    return $hint
}

if ($toNotify.Count -gt 0) {
    $hint = Get-WatchHint $failed
    $title = 'Local AI: problem detected'; if ($reminder) { $title = 'Local AI: still not working' }
    $prefix = ''; if ($recovered.Count) { $prefix = 'Working again: ' + ($recovered -join ', ') + '. ' }
    if (Send-Notification $title ("{0}Not working: {1}. {2}" -f $prefix, $failedText, $hint)) { $notifiedAt = (Get-Date).ToString('s') }
    else {
        # Not shown: keep them unreported so the next run tries again (and any recovery news too).
        $notified = @($notified | Where-Object { $toNotify -notcontains $_ -or $stillReported -contains $_ })
        if ($recovered.Count) { $recoveryFailed = $true }
    }
} elseif ($recovered.Count -gt 0 -or ($healed.Count -gt 0 -and $failed.Count -eq 0)) {
    $parts = @()
    if ($healed.Count -gt 0) { $parts += 'restarted ' + ($healed -join ', ') }
    $other = @($recovered | Where-Object { $healed -notcontains $_ })
    if ($other.Count -gt 0) { $parts += 'recovered ' + ($other -join ', ') }
    if ($failed.Count -eq 0) { $sent = Send-Notification 'Local AI: back to normal' (($parts -join '; ') + '.') }
    else { $sent = Send-Notification 'Local AI: partly recovered' ((($parts -join '; ') + '. Still not working: ' + $failedText + '.')) }
    if (-not $sent -and $recovered.Count) { $recoveryFailed = $true }
}

# ---- banner in Open WebUI -------------------------------------------------------------------
# The same two strikes as the toast: a problem seen on two runs in a row is also shown at the top of
# every Open WebUI page (phone included) until it is fixed, so it is seen even when the toast was
# missed or Windows drops it. Signs in only when the set of problems changes.
$bannerKeys = (@($failed | Where-Object { $prevFailed -contains $_ } | Sort-Object) -join ', ')
$prevBanner = ''; if ($previous.ContainsKey('banner')) { $prevBanner = [string]$previous['banner'] }
$bannerDone = $null
$credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
if ($bannerKeys -ne $prevBanner -and -not $NoNotify -and $results['Open WebUI'] -and -not $maintenance -and (Test-Path -LiteralPath $credFile)) {
    try {
        $cred = Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json
        $webUrl = "http://127.0.0.1:$webPort"
        $tok = Connect-LaiWebUI -BaseUrl $webUrl -Email $cred.email -Password $cred.password
        if ($bannerKeys) {
            $shownKeys = @($bannerKeys -split ', ')
            $what = @($shownKeys | ForEach-Object { if ($details.ContainsKey($_)) { '{0} ({1})' -f $_, $details[$_] } else { $_ } }) -join ', '
            $text = "Health watch ({0}): not working: {1}. {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $what, (Get-WatchHint $shownKeys)
            Set-LaiWebUIBanner -BaseUrl $webUrl -Token $tok -Text $text | Out-Null
            Write-WatchLog ('{0} BANNER {1}' -f (Get-Date -Format 's'), $text)
        } else {
            Set-LaiWebUIBanner -BaseUrl $webUrl -Token $tok -Clear | Out-Null
            Write-WatchLog ('{0} BANNER cleared' -f (Get-Date -Format 's'))
        }
        $bannerDone = $bannerKeys
    } catch {
        # Next run tries again; the toast and watch.log still carry the news.
        Write-WatchLog ('{0} BANNER not updated: {1}' -f (Get-Date -Format 's'), ($_.Exception.Message -replace '\s+', ' '))
    }
}

# Merge into the current file so a pause set while this run was busy survives.
$final = Read-LaiState -Path $statePath
$final['failed'] = $failed; $final['notified'] = $notified; $final['checked'] = (Get-Date).ToString('s')
if ($notified.Count -and $notifiedAt) { $final['notifiedAt'] = [string]$notifiedAt } else { $final.Remove('notifiedAt') }
if ($recoveryFailed) { $final['pendingRecovered'] = @($recovered) } else { $final.Remove('pendingRecovered') }
if ($null -ne $bannerDone) { if ($bannerDone) { $final['banner'] = $bannerDone } else { $final.Remove('banner') } }
if ($script:toastSetting) { if ($script:toastSetting -ne 'Enabled') { $final['toastSetting'] = $script:toastSetting } else { $final.Remove('toastSetting') } }
if ($null -ne $ollamaNotice) { if ($ollamaNotice) { $final['ollamaNotifiedFor'] = $ollamaNotice } else { $final.Remove('ollamaNotifiedFor') } }
Save-LaiState -State $final -Path $statePath
exit $failed.Count
