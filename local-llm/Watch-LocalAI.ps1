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
    When Ollama has updated itself since the presets were tuned, the nightly LocalAI-Recheck-Models task
    (Update-Models.ps1 -RecheckOnly -Scheduled) measures them again; the watch notifies only when a
    preset could not be put back fully on the GPU, or the re-check could not run for 3 days (once per
    new version without that task).
    About once an hour it also compares the installed scripts (<AIRoot>\Scripts), the Stack folder, the
    LocalAI-* scheduled tasks and the programs that listen for network connections with the record
    the last successful install or update left (<AIRoot>\integrity-baseline.json), and notifies
    once, naming what changed, when a second look still finds the difference. Changes you made
    yourself: -AcceptBaseline records the current state as the new baseline. That record sits in a
    folder you can write yourself, so this notices accidents, other software and clumsy tampering,
    not an attacker who already runs as you and rewrites the record too.

.EXAMPLE
    .\Watch-LocalAI.ps1              # one check, as the scheduled task runs it
.EXAMPLE
    .\Watch-LocalAI.ps1 -NoHeal -Verbose
.EXAMPLE
    .\Watch-LocalAI.ps1 -PauseMinutes 240   # quiet for 4 hours (gaming, stack stopped on purpose)
.EXAMPLE
    .\Watch-LocalAI.ps1 -Unpause
.EXAMPLE
    .\Watch-LocalAI.ps1 -AcceptBaseline     # the reported changes are yours: make them the new baseline
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
    [switch]$Unpause,
    # Record the installed scripts, the Stack folder, the LocalAI-* tasks and the listeners as they
    # are now as the integrity baseline (after changes you made yourself), then exit.
    [switch]$AcceptBaseline
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
# The integrity comparison (hash every installed file, read the tasks and the listeners) runs when
# the last one is this old: on every 15-minute run it would be the slowest thing the watch does.
$integrityMinutes = 60
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
        # Only a value that says so counts as off: Windows PowerShell 5.1 can read the setting as empty
        # (seen on the Windows CI runner), and that is not known to be off.
        $setting = ''
        try { $setting = [string]$notifier.Setting } catch { Write-Verbose "toast setting unknown: $($_.Exception.Message)" }
        $notifier.Show([Windows.UI.Notifications.ToastNotification]::new($xml))
        if ($setting -like 'Disabled*') { $why = "notifications are off: $setting"; $script:toastSetting = $setting }
        else { $shown = $true; if ($setting -eq 'Enabled') { $script:toastSetting = $setting } }
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

# ---- accept the current state as the integrity baseline ---------------------------------------
if ($AcceptBaseline) {
    $old = Read-LaiIntegrityBaseline -AIRoot $AIRoot
    $new = Save-LaiIntegrityBaseline -AIRoot $AIRoot -Reason 'accepted by the owner'
    if ($old) { foreach ($d in @(Compare-LaiIntegrity -Baseline $old -Current $new)) { Write-LaiLog INFO "accepted: $($d.Text)" } }
    # The watch starts over with the new baseline: what it found against the old one is settled.
    $st = Read-LaiState -Path $statePath
    $st['integrity'] = @{ baseline = [string]$new['id'] }
    Save-LaiState -State $st -Path $statePath
    $msg = 'integrity baseline accepted: ' + (Get-LaiIntegritySummary -Baseline $new)
    Write-WatchLog ('{0} INTEGRITY {1}' -f (Get-Date -Format 's'), $msg)
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
# preset may now spill to the CPU. Not a failure (everything still answers), so outside the
# two-strike/reminder logic. With the nightly re-check set up (the installer's LocalAI-Recheck-Models
# task; ModelRecheckAt in the config) this only notes it in watch.log: the task measures the presets
# again without downloading anything, and a notification follows only when one could not be put
# back fully on the GPU, or when the re-check could not run for 3 days. Without it (an install that
# has not run Update toolkit since): one notice per new version. $null = leave the record as it is.
$ollamaNotice = $null
$driftSince = $null
$recheckNotice = $null
$prevNotice = ''; if ($previous.ContainsKey('ollamaNotifiedFor')) { $prevNotice = [string]$previous['ollamaNotifiedFor'] }
$recheckAt = ''; if ($config.ContainsKey('ModelRecheckAt') -and $config['ModelRecheckAt']) { $recheckAt = [string]$config['ModelRecheckAt'] }
# What the last re-check found (Update-Models.ps1 writes it). 'Told once' is keyed on what it found,
# not on its time: a preset that keeps failing is re-checked (and recorded) again every night.
$recheck = Read-LaiState -Path (Join-Path $AIRoot 'model-recheck.json')
$recheckKey = ''
if ($recheck['result']) { $recheckKey = '{0}|{1}|{2}' -f $recheck['ollamaVersion'], $recheck['result'], (@($recheck['presets'] | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object) -join ', ') }
# The newest skip and its reason, for the 3-day notice: a skip is its own record, or noted on an
# off-GPU/failed record it must not replace.
$skipWhy = ''; $skipWhen = $null
if ([string]$recheck['result'] -eq 'skipped') { $skipWhy = [string]$recheck['reason']; $skipWhen = ConvertTo-WatchDate $recheck['at'] }
elseif ($recheck['lastSkip']) { $skipWhy = [string]$recheck['lastSkip']; $skipWhen = ConvertTo-WatchDate $recheck['lastSkipAt'] }
$recheckShortcut = 'Close ComfyUI and games, then Start menu > Local AI - Re-check models.'
if ($ollamaVer) {
    $inst = Read-LaiState -Path (Join-Path $AIRoot 'install-state.json')
    $tun = @{}; if ($inst['tuning'] -is [hashtable]) { $tun = $inst['tuning'] }
    $sel = @(); if ($config.ContainsKey('SelectedModels') -and $config['SelectedModels']) { $sel = @($config['SelectedModels']) }
    $drift = @(Get-LaiTuningDrift -Tuning $tun -OllamaVersion $ollamaVer -Keys $sel)
    if ($drift.Count -eq 0) { $ollamaNotice = ''; $driftSince = '' }
    else {
        $was = @($drift | ForEach-Object { $_.Was } | Select-Object -Unique) -join ', '
        $which = @($drift | ForEach-Object { $_.Key }) -join ', '
        if ($recheckAt) {
            $since = $previous['ollamaDriftSince']
            if (-not ($since -is [hashtable]) -or [string]$since['version'] -ne $ollamaVer) {
                $driftSince = @{ version = $ollamaVer; time = (Get-Date).ToString('s') }
                Write-WatchLog ('{0} Ollama updated itself to {1}; {2} measured on {3}: re-check scheduled tonight at {4} (no downloads, only while the GPU is idle)' -f (Get-Date -Format 's'), $ollamaVer, $which, $was, $recheckAt)
            } else {
                $t0 = ConvertTo-WatchDate $since['time']
                # A re-check that ran on this version and failed has its own notice (below).
                $ranHere = ([string]$recheck['ollamaVersion'] -eq $ollamaVer -and @('failed', 'off-gpu') -contains [string]$recheck['result'])
                if ($t0 -and ((Get-Date) - $t0).TotalHours -ge 72 -and $prevNotice -ne $ollamaVer -and -not $ranHere) {
                    $why = " (the PC was off or asleep at $recheckAt)"
                    if ($skipWhy -and $skipWhen -and $skipWhen -ge $t0) { $why = " (last attempt skipped: $skipWhy)" }
                    $text = "Ollama updated itself to $ollamaVer 3 days ago, and the nightly re-check of $which (measured on $was) could not run since$why. $recheckShortcut"
                    if (Send-Notification 'Local AI: presets not re-checked' $text) { $ollamaNotice = $ollamaVer }
                }
            }
        } elseif ($prevNotice -ne $ollamaVer) {
            $text = "Ollama updated itself to $ollamaVer; $which were measured on $was and may now run slower. $recheckShortcut It checks them on the GPU again (no downloads, about a minute each)."
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
}
# The re-check ran on this Ollama and a preset stayed (partly) off the GPU, or could not be set up:
# the one case that needs the owner. Once per re-check result.
$toldKey = ''; if ($previous.ContainsKey('recheckNotifiedFor')) { $toldKey = [string]$previous['recheckNotifiedFor'] }
if ($ollamaVer -and $recheckKey -and [string]$recheck['ollamaVersion'] -eq $ollamaVer -and @('off-gpu', 'failed') -contains [string]$recheck['result'] -and $recheckKey -ne $toldKey) {
    $presets = @($recheck['presets'] | Where-Object { $_ }) -join ', '
    $why = ''; if ($recheck['reason']) { $why = " ($($recheck['reason']))" }
    $text = "After Ollama updated itself to {0}: {1}{2}. {3} Details: {4}." -f $ollamaVer, $presets, $why, $recheckShortcut, (Join-Path $logDir 'model-recheck.log')
    if (Send-Notification 'Local AI: a preset is off the GPU' $text) { $recheckNotice = $recheckKey }
}

# ---- integrity: files, tasks and listeners against the baseline -------------------------------
# The last successful install or update (or the owner, with -AcceptBaseline) recorded what the
# installed scripts, the Stack folder, the LocalAI-* scheduled tasks and the network listeners looked
# like. Every $integrityMinutes the PC is compared with that record. Two strikes, as for the checks
# above: a difference is announced when a second look, on the next run, still finds it, so a file
# being saved or a port a program opens for a minute raises nothing; each difference is announced
# once. Not a failed check (nothing is broken): no reminders, no exit code. Announced differences
# that are still there also go on the Open WebUI banner below, which carries the news when Windows
# drops the toast. Nothing happens here without a baseline (an install from before this existed
# gets one from its next Update toolkit).
# The limit, plainly: the record sits in $AIRoot, which this user can write. This notices accidents,
# other software and clumsy tampering, not someone who runs as this user and rewrites the record.
# $null = leave the saved findings as they are.
$integrityState = $null
$integrityShown = @()
try {
    $ig = @{}; if ($previous['integrity'] -is [hashtable]) { $ig = $previous['integrity'] }
    $baseline = Read-LaiIntegrityBaseline -AIRoot $AIRoot
    $knownId = [string]$ig['baseline']
    if ($baseline -or $knownId) {
        $baseId = $knownId; if ($baseline) { $baseId = [string]$baseline['id'] }
        # A new baseline (install, update, -AcceptBaseline): what was found against the old one is settled.
        if ($baseId -ne $knownId) { $ig = @{} }
        $told = @($ig['told'] | Where-Object { $_ })
        $pending = @($ig['pending'] | Where-Object { $_ })
        $igLast = ConvertTo-WatchDate $ig['checkedAt']
        # Also due right away for the second look at something seen once, and after the clock was set back.
        $igDue = (-not $igLast) -or $pending.Count -gt 0 -or [math]::Abs(((Get-Date) - $igLast).TotalMinutes) -ge $integrityMinutes
        # An installer run or a model update in progress is replacing files right now: next run.
        if ($igDue -and -not (Test-LaiSetupLockBusy)) {
            $since = $null
            if ($baseline) {
                # The stack's own ports: another program holding one of them is news even on loopback.
                $igPorts = @($webPort, $searxPort)
                try { $igPorts += ([uri]$ollamaUrl).Port } catch { $igPorts += 11434 }
                if ($config.ContainsKey('DeepResearchPort') -and [int]$config['DeepResearchPort'] -gt 0) { $igPorts += [int]$config['DeepResearchPort'] }
                $diffs = @(Compare-LaiIntegrity -Baseline $baseline -Current (Get-LaiIntegritySnapshot -AIRoot $AIRoot) -WatchedPorts $igPorts)
                $since = ConvertTo-WatchDate $baseline['recordedAt']
            } else {
                # A baseline was there on an earlier run and is not now: that is a change too.
                $diffs = @([pscustomobject]@{ Key = 'baseline|gone'; Text = 'the baseline itself (' + (Get-LaiIntegrityPath -AIRoot $AIRoot) + ') is gone or cannot be read' })
            }
            $keys = @($diffs | ForEach-Object { [string]$_.Key })
            $wasKeys = @($ig['found'] | Where-Object { $_ -is [hashtable] } | ForEach-Object { [string]$_['Key'] })
            if (($keys -join "`n") -ne ($wasKeys -join "`n")) {
                # The whole list goes to the log (a notification has room for three).
                if ($diffs.Count) { Write-WatchLog ('{0} INTEGRITY {1} difference(s) from the baseline: {2}' -f (Get-Date -Format 's'), $diffs.Count, (Format-LaiIntegrityList -Items @($diffs | ForEach-Object { $_.Text }) -Max 20)) }
                else { Write-WatchLog ('{0} INTEGRITY matches the baseline again' -f (Get-Date -Format 's')) }
            }
            $announce = @($diffs | Where-Object { $pending -contains $_.Key -and $told -notcontains $_.Key })
            if ($announce.Count) {
                $list = Format-LaiIntegrityList -Items @($announce | ForEach-Object { $_.Text }) -Max 3
                $when = ''; if ($since) { $when = ' (' + $since.ToString('yyyy-MM-dd HH:mm') + ')' }
                $title = 'Local AI: changed outside an update'
                $text = "Changed since the last install or update${when}: $list. If you did not do this, open Start menu > Local AI - Health check: it lists every change and what to do about it."
                # An installer run that started after the baseline and never recorded a new one: these
                # are the changes of an update that is waiting for a restart or failed, and are named so.
                $unfinished = $null; if ($since) { $unfinished = Get-LaiUnfinishedInstall -AIRoot $AIRoot -Since $since }
                if ($unfinished) {
                    $title = 'Local AI: update not finished'
                    $text = "An install or update started $($unfinished.ToString('yyyy-MM-dd HH:mm')) and has not finished. Different from the last finished one: $list. Start menu > Local AI - Update toolkit finishes it."
                }
                # A toast that failed is not counted as told: the difference stays pending and the next run tries again.
                if (Send-Notification $title $text) { $told = @($told + @($announce | ForEach-Object { [string]$_.Key }) | Select-Object -Last 200) }
            }
            $integrityState = @{
                baseline  = $baseId
                checkedAt = (Get-Date).ToString('s')
                told      = $told
                pending   = @($keys | Where-Object { $told -notcontains $_ })
                found     = @($diffs | ForEach-Object { @{ Key = [string]$_.Key; Text = [string]$_.Text } })
            }
        }
        $igView = $ig; if ($null -ne $integrityState) { $igView = $integrityState }
        $integrityShown = @($igView['found'] | Where-Object { $_ -is [hashtable] -and @($igView['told']) -contains [string]$_['Key'] })
    }
} catch {
    # The integrity comparison must never take the health checks down with it.
    Write-WatchLog ('{0} INTEGRITY not compared: {1}' -f (Get-Date -Format 's'), ($_.Exception.Message -replace '\s+', ' '))
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
$failedKeys = (@($failed | Where-Object { $prevFailed -contains $_ } | Sort-Object) -join ', ')
# Announced integrity differences that are still there share the banner (and change its key, so it is
# rewritten when they change and removed when they are accepted or undone).
$bannerKeys = $failedKeys
if ($integrityShown.Count) {
    $bannerKeys = 'changed ' + (Get-LaiIntegrityTag -Text (@($integrityShown | ForEach-Object { [string]$_['Key'] }) -join "`n"))
    if ($failedKeys) { $bannerKeys = $failedKeys + ' | ' + $bannerKeys }
}
$prevBanner = ''; if ($previous.ContainsKey('banner')) { $prevBanner = [string]$previous['banner'] }
$bannerDone = $null
$credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
if ($bannerKeys -ne $prevBanner -and -not $NoNotify -and $results['Open WebUI'] -and -not $maintenance -and (Test-Path -LiteralPath $credFile)) {
    try {
        $cred = Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json
        $webUrl = "http://127.0.0.1:$webPort"
        $tok = Connect-LaiWebUI -BaseUrl $webUrl -Email $cred.email -Password $cred.password
        if ($bannerKeys) {
            $parts = @()
            if ($failedKeys) {
                $shownKeys = @($failedKeys -split ', ')
                $what = @($shownKeys | ForEach-Object { if ($details.ContainsKey($_)) { '{0} ({1})' -f $_, $details[$_] } else { $_ } }) -join ', '
                $parts += ('not working: {0}. {1}' -f $what, (Get-WatchHint $shownKeys))
            }
            if ($integrityShown.Count) {
                $parts += ('changed since the last install or update: {0}. Start menu > Local AI - Health check lists every change and what to do about it.' -f (Format-LaiIntegrityList -Items @($integrityShown | ForEach-Object { [string]$_['Text'] }) -Max 3))
            }
            $text = 'Health watch ({0}): {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), ($parts -join ' Also ')
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
if ($null -ne $driftSince) { if ($driftSince) { $final['ollamaDriftSince'] = $driftSince } else { $final.Remove('ollamaDriftSince') } }
if ($recheckNotice) { $final['recheckNotifiedFor'] = $recheckNotice }
# (A baseline accepted while this run was busy has another id: the next run starts over with it.)
if ($null -ne $integrityState) { $final['integrity'] = $integrityState }
Save-LaiState -State $final -Path $statePath
exit $failed.Count
