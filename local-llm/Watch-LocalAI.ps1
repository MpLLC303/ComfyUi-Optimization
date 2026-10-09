#Requires -Version 5.1

<#
.SYNOPSIS
    Lightweight health watch for the local AI stack, meant to run every 15 minutes as a scheduled task.

.DESCRIPTION
    Checks, in about a second and without loading any model or signing in:
      Ollama API, Docker engine, Open WebUI /health, SearXNG /healthz, the render-guard container,
      whether Open WebUI reaches Ollama (the path chats take), the newest backup (younger than 50 h
      and not quarantined as -CORRUPT) and what the nightly backup recorded about itself (deep
      research's backup failing for two nights; an Open WebUI found without chats, which is told on
      the first run that sees it), and free disk space on the drives holding the models, backups
      and Docker's data (at least -MinFreeGB).
    Self-heals what is safe to heal (starts a stopped container, relaunches the Ollama tray app) unless
    -NoHeal. Docker Desktop is never started by the watch (you may have quit it on purpose to free
    RAM); a stopped engine is reported once instead, and so is one that stopped answering (every
    docker call has a time limit). Shows a Windows notification once when a check has failed on two
    runs in a row (and once when it recovers), so neither a slow Docker start nor a lasting outage
    spams you. Only a check that ran and passed counts as recovered: one that could not run (Docker
    is down, Open WebUI is stopped for a backup) keeps what was reported about it, with no
    notification either way. Open WebUI or deep research found down while the volume lock is held (a
    backup, restore or update at work) is left alone and not judged for 45 minutes, longer than any
    of them normally takes. Found so on every run after that, it is reported as not working like
    any other check, and is still never started while the lock is held. The 45 minutes are counted
    over runs that follow one another: after more than 35 minutes in which the watch did not look
    (the PC off or asleep, the watch paused, Docker stopped) they start over.
    Log: <AIRoot>\Logs\watch.log.
    When Ollama has updated itself since the presets were tuned, the nightly LocalAI-Recheck-Models task
    (Update-Models.ps1 -RecheckOnly -Scheduled) measures them again; the watch notifies only when a
    preset could not be put back fully on the GPU, or the re-check could not run for 3 days (once per
    new version without that task).
    About once an hour it also compares the installed scripts (<AIRoot>\Scripts), the Stack folder, the
    LocalAI-* scheduled tasks and the programs that listen for network connections with the record
    the last successful install or update left (<AIRoot>\integrity-baseline.json), and notifies
    once, naming what changed, when a second look still finds the difference. Of Stack\.env only
    the settings that say where chats and searches are sent (names ending in _URL, _URLS or
    _UPSTREAM) are compared, by name; the rest of it (versions, ports, keys, extra origins), logs
    and everything under a Secrets folder are not watched. Changes you made yourself:
    -AcceptBaseline records the current state as the new baseline, and the next scheduled run
    confirms that with a notification, so an acceptance you did not make is seen. That record sits
    in a folder you can write yourself, so this notices accidents, other software and clumsy
    tampering, not an attacker who already runs as you and rewrites the record too.

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
    [switch]$AcceptBaseline,
    # Test only (tests/Invoke-WatchTest.ps1; the scheduled task passes none of the four): act as if
    # Windows' notification switch for PowerShell had this value, e.g. DisabledForUser.
    [string]$TestToastSetting = '',
    # Test only: every notification fails, as with a broken notification service.
    [switch]$TestToastFail,
    # Test only: end the run where the comparison with the integrity baseline starts, with its mark
    # written and nothing compared.
    [switch]$TestIntegrityEnd,
    # Test only: seconds a docker command may take before Docker Desktop counts as not responding
    # (0 = the 30 s of every scheduled run).
    [int]$TestDockerTimeout = 0
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$webPort = 3000; if ($config.ContainsKey('WebUIPort')) { $webPort = [int]$config['WebUIPort'] }
$searxPort = 8888; if ($config.ContainsKey('SearxngPort')) { $searxPort = [int]$config['SearxngPort'] }
# The optional research agent (Install-LocalAI.ps1 -DeepResearch); 0 = not installed.
$researchPort = 0; if ($config.ContainsKey('DeepResearchPort')) { $researchPort = [int]$config['DeepResearchPort'] }
$ollamaUrl = 'http://127.0.0.1:11434'; if ($config.ContainsKey('OllamaUrl') -and $config['OllamaUrl']) { $ollamaUrl = $config['OllamaUrl'] }
$logDir = Join-Path $AIRoot 'Logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir 'watch.log'
$statePath = Join-Path $AIRoot 'watch-state.json'
# Asked of .NET, not of the OS variable: a per-user variable of that name replaces the system's one
# in this user's processes, and every notification would then go to watch.log only.
$onWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
$notify = $onWindows -and -not $NoNotify
# The test hooks, as Send-Notification and the integrity comparison read them. They are parameters of
# this run and nothing else. None is read from the environment: a variable there can be set for good
# by any program running as this user, and silenced every scheduled run from then on.
$hookToastSetting = $TestToastSetting
$hookToastFail = [bool]$TestToastFail
$hookIntegrityEnd = [bool]$TestIntegrityEnd
$healAllowed = -not $NoHeal
# A problem that persists is announced again after this many hours (a single toast is easy to miss:
# Focus Assist during a game, a busy morning), until it is fixed.
$remindHours = 24
# Open WebUI or deep research found down while the volume lock is held is left alone for this many
# minutes, longer than a backup, restore or update normally takes. After that it counts as failed on
# every run, and is still never started under the lock: any program of this user can hold that lock
# and stop the container, and the watch would otherwise stay quiet about it for good. Since when is
# a stamp for each of the two in watch-state.json (webuiLockedSince, researchLockedSince), written
# by the first run that sees it and removed by the first one that finds the lock free or the service
# answering. A stamp that is no time, or lies in the future, counts as overdue. Next to each stamp
# stands the time of the last run that saw it so (webuiLockedSeen, researchLockedSeen; see
# $lockGapMinutes), written and removed with it.
# Both are UTC, written with a Z, and only a time that is printed is turned into local time. Local
# time is an hour off on the two nights a year the clocks change: an honest stamp would read as 75
# minutes old after 15 in spring, and as lying in the future, which counts as overdue, in autumn.
# Not closed, and it ships open: that file is one any program of this user can write as well. One
# that, before each run, removes the stamp, sets it to a time less than this many minutes ago, or
# sets the time of the last sighting more than $lockGapMinutes minutes back keeps the watch quiet
# as before.
$lockBoundMinutes = 45
# The count is of runs that found it so one after the other. A last sighting more than this many
# minutes back (two of the 15-minute runs, and what a run does before it gets here) says that the
# watch did not look in between: the PC was off or asleep, nobody was signed in, the watch was
# paused, or Docker was down. What holds the lock now may be another program than the one seen then
# (the backup that is caught up after sign-in, hours after an update the evening before), and two
# looks hours apart do not show a lock held for longer than a backup takes. The count starts over,
# as on a first sighting.
# This ships open as well: on a PC that is never up, signed in and unpaused for $lockBoundMinutes
# minutes at a stretch the count never gets there, and the watch does not report a lock that stays
# held (the health check still fails Open WebUI in the lock's words).
$lockGapMinutes = 35
# The integrity comparison (hash every installed file, read the tasks and the listeners) runs when
# the last one is this old: on every 15-minute run it would be the slowest thing the watch does.
$integrityMinutes = 60
# A comparison that could not run for this long (an install or model update holds the setup lock, or
# it keeps failing) is announced once: until then only watch.log and the health check say so.
$integritySkipHours = 6
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
function ConvertTo-WatchCount($Value) {
    # A count from a state file as a whole number from 0 up, or $null when it is none: the file is
    # one any program of this user can write, and a notice must not print what it holds as a number.
    if ($null -eq $Value) { return $null }
    $n = 0
    if ([int]::TryParse([string]$Value, [ref]$n) -and $n -ge 0) { return $n }
    return $null
}
function Get-WatchStamp($Value) {
    # One spelling of a recorded time, to compare two of them by ('' = none): a state file hands the
    # same value back as a date under PowerShell 7 and as the string under 5.1.
    $d = ConvertTo-WatchDate $Value
    if ($d) { return $d.ToString('s') }
    return ([string]$Value -replace '\s+', ' ').Trim()
}
function ConvertTo-WatchUtc($Value) {
    # One of the times the watch keeps for a service found down under a held volume lock (see
    # $lockBoundMinutes), in UTC, or $null when the value is none. The watch writes them as text
    # that ends in Z: Windows PowerShell 5.1 reads that back as the text, so this is the path of
    # every real run, and PowerShell 7 reads it back as a date. Both are taken and nothing else is
    # (a list, a table, a number, a switch). The text is read as UTC at once, not by way of local
    # time. A time that names no zone is not in the watch's spelling and is taken as local time,
    # as every other time in the state file is.
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if (-not ($Value -is [string]) -or $Value -eq '') { return $null }
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeLocal
    try { return [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, $styles) } catch { return $null }
}
function Get-WatchLockSeen {
    # What the watch has on record for a service found down under a held volume lock (see
    # $lockBoundMinutes), from the two times it keeps for it: the stamp, since when (-Key), and the
    # last run that saw it so (-SeenKey). Every time here is UTC.
    #   First    this run starts the count: there is no stamp, or the last sighting is more than
    #            -GapMinutes back, so the watch did not look in between (see $lockGapMinutes).
    #   Since    the stamp, when it is a time not after -Now and the count goes on.
    #   Overdue  that time is -BoundMinutes or more ago, or the stamp is there and is anything else
    #            (empty, no text, not a time, a time in the future).
    # The state file is one any program of this user can write, and a stamp the watch cannot read
    # must not keep it quiet: such a stamp is overdue whatever the last sighting says. Asked with
    # ContainsKey, never by the value: an empty stamp is a stamp. The count starts over only on a
    # last sighting that reads as a time that has passed: one that is missing, cannot be read or
    # lies in the future shows no break, and the stamp is judged by its age. Only Since, the parsed
    # time, is ever printed; what the file held is not.
    param([hashtable]$State, [string]$Key, [string]$SeenKey, [datetime]$Now, [int]$BoundMinutes, [int]$GapMinutes)
    $start = @{ First = $true; Overdue = $false; Since = $null }
    if (-not $State.ContainsKey($Key)) { return $start }
    $nowUtc = $Now.ToUniversalTime()
    $since = ConvertTo-WatchUtc $State[$Key]
    if ($null -eq $since -or $since -gt $nowUtc) { return @{ First = $false; Overdue = $true; Since = $null } }
    $seen = ConvertTo-WatchUtc $State[$SeenKey]
    if ($null -ne $seen -and $seen -le $nowUtc -and ($nowUtc - $seen).TotalMinutes -gt $GapMinutes) { return $start }
    return @{ First = $false; Overdue = (($nowUtc - $since).TotalMinutes -ge $BoundMinutes); Since = $since }
}

# Every docker call has a time limit: a Docker Desktop that stopped answering (it can after sleep)
# would otherwise hang this run until Task Scheduler ends it, with no log line and no notification.
# The limit is a constant here, or the test's parameter, so that no variable reaches it: the
# library's Get-LaiDockerTimeout reads LOCALAI_DOCKER_TIMEOUT. Until batch 4 it cast that value to a
# number, and a value that is none ended every run on this line, before any check, log line or
# notification.
$dockerLimit = 30; if ($TestDockerTimeout -gt 0) { $dockerLimit = $TestDockerTimeout }

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
    # Test hooks (-TestToastSetting and -TestToastFail, which only tests/Invoke-WatchTest.ps1 passes):
    # Windows' notification switch for PowerShell turned off (the toast is dropped silently), and a
    # toast that fails, as with a broken notification service.
    if ($hookToastSetting) { $script:toastSetting = $hookToastSetting; Write-WatchLog ('{0} NOTIFY (toast not shown, notifications are off: {1}) {2}: {3}' -f (Get-Date -Format 's'), $hookToastSetting, $Title, $Text); return $true }
    if ($hookToastFail) { Write-WatchLog ('{0} NOTIFY (toast failed) {1}: {2}' -f (Get-Date -Format 's'), $Title, $Text); return $false }
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
    # The new baseline lists what it took in (everything that differed from the one before, and what
    # an update had kept: accepting is what settles that). By name here the first 50; an entry that
    # stands for what the baseline does not name ('more|...') is part of the count.
    $new = Save-LaiIntegrityBaseline -AIRoot $AIRoot -Reason 'accepted by the owner'
    $took = @($new['accepted'] | Where-Object { $_ -is [hashtable] -and [string]$_['Id'] -notlike 'more|*' } | ForEach-Object { [string]$_['Text'] })
    $tookCount = $took.Count; if ([int]$new['acceptedCount'] -gt $tookCount) { $tookCount = [int]$new['acceptedCount'] }
    $tookShown = @($took | Select-Object -First 50)
    foreach ($t in $tookShown) { Write-LaiLog INFO "accepted: $t" }
    if ($tookCount -gt $tookShown.Count) { Write-LaiLog INFO ('accepted: and {0} more' -f ($tookCount - $tookShown.Count)) }
    # The watch starts over with the new baseline: what it found against the old one is settled.
    # Whether the owner knows of this acceptance is not: nothing is marked as said or tried here, so
    # the next scheduled run names what was accepted in a notification. Anything running as this user
    # can start this script; the notification is what makes an acceptance the owner did not make
    # visible. Running it again, or an update, before that run does not empty the list: what this
    # acceptance settled stays in it until the watch has had its turn (Save-LaiIntegrityBaseline).
    $st = Read-LaiState -Path $statePath
    $st['integrity'] = @{ baseline = [string]$new['id'] }
    Save-LaiState -State $st -Path $statePath
    $msg = 'integrity baseline accepted: {0}; {1} change(s) now count as normal' -f (Get-LaiIntegritySummary -Baseline $new), $tookCount
    $logLine = $msg; if ($took.Count) { $logLine += ': ' + (Format-LaiIntegrityList -Items $took -Max 20) }
    Write-WatchLog ('{0} INTEGRITY {1}' -f (Get-Date -Format 's'), $logLine)
    Write-LaiLog OK $msg
    if ($tookCount) { Write-LaiLog INFO 'The health watch confirms this with a notification on its next run.' }
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
# Open WebUI and deep research down under a held volume lock ($lockBoundMinutes): which of them this
# run left alone and did not judge, which it counts as failed because that has lasted too long, and
# what becomes of the two times each has in watch-state.json when this run is saved (no entry: it
# stays as it is, '': it is removed, else the time to keep).
$leftAlone = @()
$lockOverdue = @()
$lockStamps = @{}

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
    # The engine answered: a result of its own, or a Docker that was reported could never be reported
    # as working again (only a check that ran and passed is; see the report below). Without a docker
    # CLI ('missing') it was not looked at, and nothing is recorded.
    if ($engine -eq 'ok') { $results['Docker'] = $true }
    # LockKey: the two that a backup, restore or update stops (or pauses) under the volume lock, and
    # the name of the stamp each has in watch-state.json for it. SeenKey: the name of the time of
    # the last run that saw it so.
    $watched = @(@{ Name = 'open-webui'; Url = "http://127.0.0.1:$webPort/health"; Key = 'Open WebUI'; LockKey = 'webuiLockedSince'; SeenKey = 'webuiLockedSeen' },
                 @{ Name = 'searxng'; Url = "http://127.0.0.1:$searxPort/healthz"; Key = 'SearXNG' })
    # The optional research agent, healed like the others. Where it is no part of this install, a
    # stamp it once left is owed nothing: it would count against a later install of it.
    $research = @{ Name = 'deep-research'; Url = "http://127.0.0.1:$researchPort/api/v1/health"; Key = 'Deep research'; LockKey = 'researchLockedSince'; SeenKey = 'researchLockedSeen' }
    if ($researchPort -gt 0) { $watched += $research } else { $lockStamps[$research.LockKey] = ''; $lockStamps[$research.SeenKey] = '' }
    # The stamps as the run before this one left them. Read once, here: nothing above needs the file.
    $lockState = Read-LaiState -Path $statePath
    foreach ($c in $watched) {
        $ok = Test-Url $c.Url
        $hold = $null; if ($c.Name -eq 'open-webui') { $hold = Get-LaiWebUIHold -AIRoot $AIRoot }
        if (-not $ok -and $c.ContainsKey('LockKey') -and (Test-LaiVolumeLockBusy)) {
            # A backup, restore or update is running and stopped (or paused) it on purpose (checked
            # before the hold: a restore in progress has written its hold already, but has not failed).
            # That is 'not checked', not 'working': no result is recorded, so nothing is reported as
            # failed and nothing as recovered, and what was reported before stays as it was.
            # For $lockBoundMinutes, counted from the first of the runs that saw it so one after the
            # other ($lockGapMinutes). Found so on every run after that, it is a failure like any
            # other, with two differences: it is still not started (whatever holds the lock may be
            # at work on the volume), and no docker command is run for it. In either case this is
            # maintenance for the rest of the run: the chat path is not tried and the banner is not
            # written.
            $maintenance = $true
            # In UTC, as the two times on record are (see $lockBoundMinutes).
            $lookedAt = [datetime]::UtcNow
            $lockSeen = Get-WatchLockSeen -State $lockState -Key $c.LockKey -SeenKey $c.SeenKey -Now $lookedAt -BoundMinutes $lockBoundMinutes -GapMinutes $lockGapMinutes
            # What to save. The stamp: this run's time where the count starts (a first sighting, or
            # the first one after the watch did not look for more than $lockGapMinutes minutes), the
            # time on record (in the watch's own spelling) while that reads as one. The last
            # sighting: this run's time in both cases. A stamp that does not read as a time is left
            # as it is, with what stands next to it, so that it counts as overdue on the next run too.
            $lookedStamp = $lookedAt.ToString('s') + 'Z'
            if ($lockSeen.First) { $lockStamps[$c.LockKey] = $lookedStamp; $lockStamps[$c.SeenKey] = $lookedStamp }
            elseif ($null -ne $lockSeen.Since) { $lockStamps[$c.LockKey] = $lockSeen.Since.ToString('s') + 'Z'; $lockStamps[$c.SeenKey] = $lookedStamp }
            if ($lockSeen.Overdue) {
                # The words claim what the watch has on record and no more. Who holds the lock is not
                # known, and the watch looks every 15 minutes: held each time it looked, not held
                # throughout. 'By the watch's record', because the stamp is in a file another program
                # can write, and a run that is ended early leaves it as it was. The time printed is
                # the parsed one, in local time, never what the file held.
                $results[$c.Key] = $false
                $lockOverdue += $c.Key
                if ($null -ne $lockSeen.Since) {
                    $details[$c.Key] = "down, and by the watch's record the volume lock was held each time it looked since $($lockSeen.Since.ToLocalTime().ToString('yyyy-MM-dd HH:mm')), longer than a backup, restore or update normally takes; not started while the lock is held"
                } else {
                    $details[$c.Key] = "down with the volume lock held, and the watch's record of since when cannot be read as a time that has passed, which counts as longer than a backup, restore or update normally takes; not started while the lock is held"
                }
            } else {
                $leftAlone += $c.Key
            }
            continue
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
        # Looked at, and it answers or the lock is free: the count of $lockBoundMinutes starts over.
        if ($c.ContainsKey('LockKey')) { $lockStamps[$c.LockKey] = ''; $lockStamps[$c.SeenKey] = '' }
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
$bstate = Read-LaiState -Path (Join-Path $AIRoot 'backup-state.json')
# While the nightly backup has Open WebUI's data marked as wiped ('emptied', told below) it names
# its archives -EMPTY. Those are then what shows that the nightly task still runs, and what goes to
# the mirror: while the mark stands they count as nightly ones for freshness and for the mirror
# row. Left out, a mark that stood for more than two nights added 'no nightly backup in the last
# 50 h' to every notice although the task ran each night, and a mirror that had stopped still passed.
$nightly = $daily
if ($bstate['emptied'] -is [hashtable]) { $nightly = @($all | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}(-EMPTY)?\.tar\.gz$' }) }
$backupBase = @()
if ($all.Count -gt 0 -and $all[0].Name -like '*-CORRUPT.tar.gz') { $backupBase += 'the newest backup failed its database check' }
if ($nightly.Count -eq 0 -or ((Get-Date) - $nightly[0].LastWriteTime).TotalHours -gt 50) { $backupBase += 'no nightly backup in the last 50 h' }
$results['Backups'] = ($backupBase.Count -eq 0)
$backupLog = Join-Path $logDir 'backup.log'
# What else makes the backups something not to rely on, the gravest first. Any one fails the check.
$backupWhy = @()
# The nightly backup found Open WebUI's data wiped where earlier backups have it, and recorded it
# ('emptied': at, archive, lastGood, users, chats, hadUsers, hadChats). The owner may have cleared
# it, or it is lost. Told on the first run that sees it (the report below): every night that
# passes is one more backup of the wiped state.
$emptiedKey = ''
if ($bstate['emptied'] -is [hashtable]) {
    $emptied = $bstate['emptied']
    $emptiedKey = Get-WatchStamp $emptied['at']; if (-not $emptiedKey) { $emptiedKey = 'undated' }
    $emptiedAt = ConvertTo-WatchDate $emptied['at']
    # What the record says, in the health check's words. Not 'no chats': the backup also sets the
    # mark while chats are left (under a tenth of 20 or more) and keeps it until half are back, and
    # 'no chats' next to an Open WebUI that shows three reads like a false alarm. 'at' is the first
    # night; the counts are those of the last backup. A record without all four numbers gets none.
    $emptiedSays = "Open WebUI's data looked wiped at the last nightly backup"
    if ($emptiedAt) { $emptiedSays = "Open WebUI's data has looked wiped since the nightly backup of " + $emptiedAt.ToString('yyyy-MM-dd') }
    $nowUsers = ConvertTo-WatchCount $emptied['users']
    $nowChats = ConvertTo-WatchCount $emptied['chats']
    $goodUsers = ConvertTo-WatchCount $emptied['hadUsers']
    $goodChats = ConvertTo-WatchCount $emptied['hadChats']
    if ($null -ne $nowUsers -and $null -ne $nowChats -and $null -ne $goodUsers -and $null -ne $goodChats) {
        $emptiedSays += '; at the last backup {0} user(s) and {1} chat(s), {2} and {3} at the last good one' -f $nowUsers, $nowChats, $goodUsers, $goodChats
    }
    $lastGood = ([string]$emptied['lastGood'] -replace '\s+', ' ').Trim()
    # The record is a file any program of this user can write, and a backup can have been moved or
    # removed since: a restore command is given only for a file that is in the backup folder now (by
    # its name or its full path), never for one in another folder, on another drive or on a share.
    $lastGoodPath = ''
    if ($lastGood.Length -gt 300) { $lastGood = $lastGood.Substring(0, 300) + '...' }
    elseif ($lastGood) {
        try {
            $lastGoodFull = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($backupDir, $lastGood))
            $inBackupDir = Join-Path $backupDir ([System.IO.Path]::GetFileName($lastGoodFull))
            if ($lastGoodFull -eq [System.IO.Path]::GetFullPath($inBackupDir) -and (Test-Path -LiteralPath $inBackupDir -PathType Leaf)) { $lastGoodPath = $inBackupDir }
        } catch { Write-Verbose "the recorded last good backup is no usable path: $($_.Exception.Message)" }
    }
    # The backup command. With its last switch it is the second way out, for an owner who emptied it
    # on purpose: one run that takes the data as it is now for this install's own. The backup's own
    # log names both ways as well.
    $backupCmd = '& {0} -AIRoot {1}' -f (ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Backup-OpenWebUI.ps1')), (ConvertTo-LaiPsQuoted $AIRoot)
    $ifMeant = "if you emptied it yourself, run once: $backupCmd -AcceptEmpty"
    # The mark goes when a backup counts the data again, not when a restore ends. Said here, or an
    # owner who restored as told reads the same notice once more, and restores a second time or
    # takes the other command for the way out.
    $afterRestore = 'after a restore this notice stays until the next nightly backup has counted the data again (the same command without -AcceptEmpty does that at once)'
    if ($lastGoodPath) {
        $restoreCmd = '& {0} -AIRoot {1} -Archive {2}' -f (ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')), (ConvertTo-LaiPsQuoted $AIRoot), (ConvertTo-LaiPsQuoted $lastGoodPath)
        $backupWhy += "$emptiedSays; the last good backup is $lastGood, put back with: $restoreCmd (no older backup is deleted meanwhile); $ifMeant; $afterRestore"
    } elseif ($lastGood) {
        $backupWhy += "$emptiedSays; the backup on record as the last good one, $lastGood, is not in $backupDir (no older backup is deleted meanwhile); $ifMeant; $afterRestore"
    } else {
        $backupWhy += "$emptiedSays, and no earlier good backup is on record (no older backup is deleted meanwhile); $ifMeant; $afterRestore"
    }
} elseif ($all.Count -gt 0 -and $all[0].Name -like '*-EMPTY.tar.gz') {
    # The newest archive is an -EMPTY one and its record is gone (a backup-state.json that was
    # damaged or deleted starts empty, or from its earlier copy). The old backups may be held back by
    # nothing any more: a next nightly backup that finds no counts to compare with takes the data as
    # it is for normal and prunes by age again. A reason of its own, so it lands in the detail: among
    # the plain reasons above it showed alone as a bare 'Backups', and the next step then named a log
    # that does not say the record is gone.
    $orphanWay = "no nightly backup from before it is in $backupDir"
    if ($daily.Count -gt 0) {
        $orphanWay = 'if you did not empty it yourself, first put back the newest nightly backup from before it: & {0} -AIRoot {1} -Archive {2}' -f (ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')), (ConvertTo-LaiPsQuoted $AIRoot), (ConvertTo-LaiPsQuoted ($daily[0].FullName))
    }
    $backupWhy += "the newest backup, $($all[0].Name), was made when Open WebUI's data looked wiped, and the record of it is gone from backup-state.json: without it the next nightly backup can take the data as it is now for normal and delete old backups by age again; $orphanWay"
}
# The plain reasons from above (no nightly backup, the newest one damaged) come next. Alone they stay
# the bare 'Backups' whose hint is backup.log. Next to another reason they are named too: Backups is
# reported already then, so nothing else would ever say that no backup is being made any more.
$backupWhy += $backupBase
if ($futureDaily.Count) {
    $backupWhy += "$($futureDaily[0].Name) is dated $($futureDaily[0].LastWriteTime.ToString('s')), in the future (the PC clock was wrong when it was made): delete it"
}
if ($bstate['deepCheckSkips'] -and [int]$bstate['deepCheckSkips'] -ge 3) {
    # Backups exist, but their database check has not run for 3 nights: an empty or damaged webui.db
    # would not be noticed.
    $backupWhy += "the database check of the nightly backup could not run for $([int]$bstate['deepCheckSkips']) nights (see backup.log)"
}
# Deep research's data goes into its own archive in the same nightly run, and a failure there is a
# warning that leaves the Open WebUI backup good. One bad night is the health check's to mention;
# with no good one for 50 h (or none on record) nothing current would be there to restore.
if ($researchPort -gt 0 -and $bstate['researchError']) {
    $researchOkAt = ConvertTo-WatchDate $bstate['researchOkAt']
    if (-not $researchOkAt -or ((Get-Date) - $researchOkAt).TotalHours -gt 50) {
        $lastOk = 'none on record'; if ($researchOkAt) { $lastOk = $researchOkAt.ToString('yyyy-MM-dd HH:mm') }
        $researchWhy = ([string]$bstate['researchError'] -replace '\s+', ' ').Trim()
        if ($researchWhy.Length -gt 300) { $researchWhy = $researchWhy.Substring(0, 300) + '...' }
        $backupWhy += "deep research's backup fails (last good one: $lastOk): $researchWhy (see $backupLog)"
    }
}
if ($backupWhy.Count -gt $backupBase.Count) {
    $results['Backups'] = $false
    $details['Backups'] = $backupWhy -join '; '
}
# The second copy (NAS, other drive): a mirror that stopped working is otherwise only a line in backup.log.
$mirrorTarget = ''
if ($config.ContainsKey('BackupMirror') -and $config['BackupMirror']) { $mirrorTarget = [string]$config['BackupMirror'] }
if ($mirrorTarget -and $nightly.Count -gt 0) {
    $okAt = $null
    if ([string]$bstate['mirrorTarget'] -eq $mirrorTarget) { $okAt = ConvertTo-WatchDate $bstate['mirrorOkAt'] }
    if ($okAt -or $bstate['mirrorError']) {
        # The newest nightly archive must have been mirrored (within its own run). While Open WebUI's
        # data is marked as wiped that is the newest -EMPTY one ($nightly above): it is copied too.
        $results['Backup mirror'] = [bool]($okAt -and $okAt -ge $nightly[0].LastWriteTime.AddHours(-2))
    } else {
        # No record yet (made by a version before this check, or a newly set mirror): look for the file.
        $results['Backup mirror'] = Test-Path -LiteralPath (Join-Path $mirrorTarget $nightly[0].Name)
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

# ---- integrity: files, settings, tasks and listeners against the baseline ---------------------
# The last successful install or update (or the owner, with -AcceptBaseline) recorded what the
# installed scripts, the Stack folder (of its .env: where chats and searches are sent), the
# LocalAI-* scheduled tasks and the network listeners looked like. Every $integrityMinutes the PC
# is compared with that record. Two strikes, as for the checks above: a difference is announced
# when a second look, on the next run, still finds it, so a file being saved or a port a program
# opens for a minute raises nothing; each difference is announced once, and once more (at most
# daily) when the same thing was changed again. Not a failed check (nothing is broken): no
# reminders, no exit code. Announced differences that are still there also go on the Open WebUI
# banner below, which carries the news when Windows drops the toast. Nothing happens here without
# a baseline (an install from before this existed gets one from its next Update toolkit).
# The limit, plainly: the record sits in $AIRoot, which this user can write. This notices accidents,
# other software and clumsy tampering, not someone who runs as this user and rewrites the record.
# What the watch keeps about it (watch-state.json, 'integrity'):
#   baseline      the id of the baseline all of this belongs to (another id: start over)
#   announced     the id of the baseline whose own additions the owner was told about
#   tried         the id of the baseline whose own additions were written to watch.log and put in a
#                 notification, whether or not that went out (Save-LaiIntegrityBaseline reads both)
#   checkedAt     the last finished comparison
#   startedAt     set while one runs; still there afterwards when it was ended before it finished
#   found         the differences of the last comparison (Id, Key, Text; the first 300 and one line
#                 for the rest): the health check lists them
#   pending       Ids seen once, waiting for the second look
#   told          what was announced (Id, Key, At)
#   notRead       what could not be read, and so was not compared, although the baseline has it
#   skippedSince, skippedWhy, skippedTold   a comparison that is due and does not run
# $null = leave the saved findings as they are.
# Why a comparison is kept from running while the setup lock is held. The advice in the notice below
# (close an installer window, restart the PC) fits only this reason.
$setupLockWhy = 'an install or a model update is running (or another program holds its lock)'
function Update-IntegritySkip {
    # A comparison that is due and does not run (the setup lock is held, which any program can do; it
    # was ended before it finished; it failed). Nothing else would say so: the health check would go
    # on showing the last result as today's. So it is recorded for the health check, written to
    # watch.log once, and announced once when it has lasted $integritySkipHours hours.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Why, [switch]$Logged)
    if (-not $State['skippedSince']) {
        $State['skippedSince'] = (Get-Date).ToString('s')
        if (-not $Logged) { Write-WatchLog ('{0} INTEGRITY not compared: {1}' -f (Get-Date -Format 's'), $Why) }
    }
    $State['skippedWhy'] = $Why
    $skipSince = ConvertTo-WatchDate $State['skippedSince']
    if (-not $State['skippedTold'] -and $skipSince -and ((Get-Date) - $skipSince).TotalHours -ge $integritySkipHours) {
        $advice = ''
        if ($Why -eq $setupLockWhy) { $advice = ' If nothing of the kind is running, close an installer window that is still open or restart the PC.' }
        $skipText = "The installed scripts, tasks and listeners have not been compared with the baseline since $($skipSince.ToString('yyyy-MM-dd HH:mm')): $Why. Changes made meanwhile are not reported.$advice The details are in $logFile."
        if (Send-Notification 'Local AI: changes are not being checked' $skipText) { $State['skippedTold'] = $true }
    }
}
$integrityState = $null
$integrityShown = @()
try {
    $ig = @{}; if ($previous['integrity'] -is [hashtable]) { $ig = $previous['integrity'] }
    $baseline = Read-LaiIntegrityBaseline -AIRoot $AIRoot
    $knownId = [string]$ig['baseline']
    if ($baseline -or $knownId) {
        $baseId = $knownId; if ($baseline) { $baseId = [string]$baseline['id'] }
        # A new baseline (install, update, -AcceptBaseline): what was found against the old one is settled.
        $next = @{}
        if ($baseId -eq $knownId) { foreach ($k in @($ig.Keys)) { $next[$k] = $ig[$k] } }
        $next['baseline'] = $baseId

        # A baseline takes in whatever is there when it is recorded. What it took in beyond the
        # toolkit's own (an install), or at all (-AcceptBaseline, which any program running as this
        # user can start), is said once: the baseline lists it, and the run that first sees the
        # baseline tells. Without this an addition would be gone from every report the moment an
        # update, or one pasted command, made it 'normal'.
        if ($baseline -and [string]$next['announced'] -ne $baseId) {
            $taken = @($baseline['accepted'] | Where-Object { $_ -is [hashtable] })
            if ($taken.Count -eq 0) { $next['announced'] = $baseId }
            else {
                $takenCount = $taken.Count; if ([int]$baseline['acceptedCount'] -gt $takenCount) { $takenCount = [int]$baseline['acceptedCount'] }
                $takenText = @($taken | ForEach-Object { [string]$_['Text'] })
                # By name the first three. An entry that stands for what the baseline does not name
                # ('more|...') is no name: it is part of the count, and of the advice below.
                $takenShown = @($taken | Where-Object { [string]$_['Id'] -notlike 'more|*' } | ForEach-Object { [string]$_['Text'] } | Select-Object -First 3)
                $list = $takenShown -join '; '
                if ($takenShown.Count -eq 0) { $list = 'none of them is listed by name any more' }
                elseif ($takenCount -gt $takenShown.Count) { $list += ' and {0} more' -f ($takenCount - $takenShown.Count) }
                $recorded = ConvertTo-WatchDate $baseline['recordedAt']
                $of = ''; if ($recorded) { $of = ' of ' + $recorded.ToString('yyyy-MM-dd HH:mm') }
                $advice = Get-LaiIntegrityAdvice -Ids @($taken | ForEach-Object { [string]$_['Id'] }) -AIRoot $AIRoot -Brief
                if ([string]$baseline['reason'] -eq 'install') {
                    $title = 'Local AI: the update kept changes it did not make'
                    $text = "The install or update$of put the toolkit's own files and tasks back, but $takenCount thing(s) it did not install were there and now count as normal: $list. If you did not add them, $advice"
                } else {
                    $title = 'Local AI: integrity baseline accepted'
                    $text = "The baseline$of was recorded by hand (Watch-LocalAI.ps1 -AcceptBaseline), so $takenCount change(s) now count as normal: $list. If that was not you, $advice"
                }
                Write-WatchLog ('{0} INTEGRITY the baseline{1} took in {2}: {3}' -f (Get-Date -Format 's'), $of, $takenCount, (Format-LaiIntegrityList -Items $takenText -Max 20))
                # The watch has had its turn with this baseline, whether or not the toast goes out:
                # the next baseline no longer lists what an acceptance had settled (it waits for
                # that, and must not wait for good on a PC where no toast ever goes out).
                $next['tried'] = $baseId
                # A toast that failed is tried again on the next run.
                if (Send-Notification $title $text) { $next['announced'] = $baseId }
            }
        }

        $told = @($next['told'] | Where-Object { $_ -is [hashtable] })
        $pending = @($next['pending'] | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $igLast = ConvertTo-WatchDate $next['checkedAt']
        # Also due right away for the second look at something seen once, and after the clock was set back.
        $igDue = (-not $igLast) -or $pending.Count -gt 0 -or [math]::Abs(((Get-Date) - $igLast).TotalMinutes) -ge $integrityMinutes
        # Why a comparison that is due does not run ('' = it runs, or none is due).
        $skipWhy = ''; $skipLogged = $false
        # One that was started and did not finish (Task Scheduler ends this task after ten minutes) is
        # not started again on every run: a comparison that cannot finish would otherwise end every
        # run before the checks above are reported and saved.
        $igStarted = ConvertTo-WatchDate $next['startedAt']
        if ($igDue -and $igStarted -and [math]::Abs(((Get-Date) - $igStarted).TotalMinutes) -lt $integrityMinutes) {
            $igDue = $false
            $skipWhy = [string]$next['skippedWhy']
            if (-not $skipWhy) { $skipWhy = 'the comparison started at ' + $igStarted.ToString('HH:mm') + ' did not finish' }
        }
        # An installer run or a model update in progress is replacing files right now: next run. Any
        # program can hold that lock, so a comparison kept from running is recorded and, when it
        # lasts, announced (below).
        if ($igDue -and (Test-LaiSetupLockBusy)) {
            $igDue = $false
            $skipWhy = $setupLockWhy
        }
        if ($igDue) {
            try {
                # Left behind if this run is ended in the middle of the comparison (see above).
                $startedNow = (Get-Date).ToString('s')
                $next['startedAt'] = $startedNow
                $mark = Read-LaiState -Path $statePath
                $markIg = @{}; if ($mark['integrity'] -is [hashtable]) { $markIg = $mark['integrity'] }
                # Under the baseline this run compares with: a mark left in the record of the one before
                # it (the first comparison after an install, an update or -AcceptBaseline) would be
                # dropped by the next run together with that record, and the comparison started again.
                if ([string]$markIg['baseline'] -ne $baseId) { $markIg = @{ baseline = $baseId } }
                # What this run has just said about that baseline, or tried to, goes into the mark in
                # either case. After -AcceptBaseline the record on disk already carries the new id and
                # nothing else: a run ended here would otherwise leave no word of its notification,
                # and the next run would send the same one again.
                foreach ($k in @('announced', 'tried')) { if ($next[$k]) { $markIg[$k] = $next[$k] } }
                $markIg['startedAt'] = $startedNow
                # Test hook (-TestIntegrityEnd, which only tests/Invoke-WatchTest.ps1 passes): the run
                # ends here, with the mark written and nothing compared yet, as when Task Scheduler ends
                # it in the middle of a comparison. It was an environment variable once, meant to work
                # only while its value was the id of the baseline being compared. That was a switch all
                # the same: the id is in a file this user can read, so any program running as the owner
                # could set the variable to it for good, and from then on no comparison ran, across
                # restarts, while the health check passed. A parameter ends the one run it is passed
                # to, and the scheduled task passes none. The mark still says what ended the run, for
                # watch.log, the health check and the notice after $integritySkipHours hours.
                $hookWhy = 'the test parameter -TestIntegrityEnd was passed when the comparison started and ended it before anything was compared; the scheduled task never passes it, so something else started this run'
                $endHere = $hookIntegrityEnd
                if ($endHere) { $markIg['skippedWhy'] = $hookWhy }
                elseif ([string]$markIg['skippedWhy'] -eq $hookWhy) { $markIg.Remove('skippedWhy') }
                $mark['integrity'] = $markIg
                Save-LaiState -State $mark -Path $statePath
                if ($endHere) { exit 0 }

                $since = $null; $notRead = @()
                if ($baseline) {
                    $snapshot = Get-LaiIntegritySnapshot -AIRoot $AIRoot
                    # No more of them than the state file can carry (Limit-LaiIntegrityFound).
                    $diffs = @(Limit-LaiIntegrityFound -Diffs @(Compare-LaiIntegrity -Baseline $baseline -Current $snapshot -WatchedPorts (Get-LaiIntegrityPorts -AIRoot $AIRoot)))
                    $since = ConvertTo-WatchDate $baseline['recordedAt']
                    # In the baseline, but not readable now: skipped by the comparison, and said so
                    # (a clean result that left the tasks out is not the same clean result).
                    if ($baseline['tasks'] -is [hashtable] -and -not ($snapshot['tasks'] -is [hashtable])) { $notRead += 'the scheduled tasks' }
                    if ($null -ne $baseline['listeners'] -and $null -eq $snapshot['listeners']) { $notRead += 'the listening programs' }
                    if ($baseline['env'] -is [hashtable] -and -not ($snapshot['env'] -is [hashtable])) { $notRead += 'the settings in Stack\.env' }
                } else {
                    # A baseline was there on an earlier run and is not now: that is a change too.
                    $diffs = @([pscustomobject]@{ Id = 'baseline|gone'; Key = 'baseline|gone'; Text = 'the baseline itself ("' + (Get-LaiIntegrityPath -AIRoot $AIRoot) + '") is gone or cannot be read' })
                }
                $texts = @($diffs | ForEach-Object { [string]$_.Text }) + @($notRead | ForEach-Object { 'not read: ' + $_ })
                $wasTexts = @($next['found'] | Where-Object { $_ -is [hashtable] } | ForEach-Object { [string]$_['Text'] }) + @($next['notRead'] | Where-Object { $_ } | ForEach-Object { 'not read: ' + $_ })
                if (($texts -join "`n") -ne ($wasTexts -join "`n")) {
                    # The whole list goes to the log (a notification has room for three).
                    if ($texts.Count) { Write-WatchLog ('{0} INTEGRITY {1} difference(s) from the baseline: {2}' -f (Get-Date -Format 's'), $diffs.Count, (Format-LaiIntegrityList -Items $texts -Max 20)) }
                    else { Write-WatchLog ('{0} INTEGRITY matches the baseline again' -f (Get-Date -Format 's')) }
                }
                # Two strikes by what a difference is about, not by its content; told once, and again (at
                # most once in $remindHours h) when the same thing was changed once more: Select-LaiIntegrityNews.
                $announce = @(Select-LaiIntegrityNews -Diffs $diffs -Told $told -Pending $pending -QuietHours $remindHours)
                $sent = @()
                if ($announce.Count) {
                    $ids = @($announce | ForEach-Object { [string]$_.Id })
                    $list = Format-LaiIntegrityList -Items @($announce | ForEach-Object { [string]$_.Text }) -Max 3
                    $when = ''; if ($since) { $when = ' (' + $since.ToString('yyyy-MM-dd HH:mm') + ')' }
                    # The next step depends on what changed: a shortcut is not named when the scripts it
                    # would start are among the changes (Get-LaiIntegrityAdvice).
                    $text = "Changed since the last install or update${when}: $list. If you did not do this, " + (Get-LaiIntegrityAdvice -Ids $ids -AIRoot $AIRoot -Brief)
                    # An install or update that got somewhere after the baseline and did not finish: changed
                    # files may be its half-done work. One added sentence, for file and setting differences
                    # only; the title and the 'if you did not do this' above stay as they are.
                    if ($since -and @($ids | Where-Object { $_ -match '^(files?[+-]?|env[+-]?)\|' }).Count) {
                        $unfinished = Get-LaiUnfinishedInstall -AIRoot $AIRoot -Since $since
                        if ($unfinished) { $text += " (An install or update was still working at $($unfinished.ToString('yyyy-MM-dd HH:mm')) and has not finished: if these are its changes, running the installer again finishes it.)" }
                    }
                    # A toast that failed is not counted as told: the difference stays pending and the next run tries again.
                    if (Send-Notification 'Local AI: changed outside an update' $text) { $sent = $announce }
                }
                $told = @(Update-LaiIntegrityTold -Told $told -Announced $sent -Diffs $diffs)
                $toldIds = @{}; foreach ($t in $told) { $toldIds[[string]$t['Id']] = $true }
                $next['checkedAt'] = (Get-Date).ToString('s')
                $next['told'] = $told
                $next['pending'] = @($diffs | ForEach-Object { [string]$_.Id } | Where-Object { -not $toldIds.ContainsKey($_) })
                $next['found'] = @($diffs | ForEach-Object { @{ Id = [string]$_.Id; Key = [string]$_.Key; Text = [string]$_.Text } })
                $next['notRead'] = $notRead
                foreach ($k in @('startedAt', 'skippedSince', 'skippedWhy', 'skippedTold')) { $next.Remove($k) }
            } catch {
                # 'startedAt' stays, so a comparison that fails is tried again in an hour, not on every run.
                $skipWhy = 'it failed: ' + ($_.Exception.Message -replace '\s+', ' ')
                Write-WatchLog ('{0} INTEGRITY not compared: {1}' -f (Get-Date -Format 's'), $skipWhy)
                $skipLogged = $true
            }
        }
        if ($skipWhy) { Update-IntegritySkip -State $next -Why $skipWhy -Logged:$skipLogged }
        $integrityState = $next
        $toldNow = @{}; foreach ($t in @($next['told'] | Where-Object { $_ -is [hashtable] })) { $toldNow[[string]$t['Id']] = $true }
        $integrityShown = @($next['found'] | Where-Object { $_ -is [hashtable] -and $toldNow.ContainsKey([string]$_['Id']) })
    }
} catch {
    # The integrity comparison must never take the health checks down with it. With a baseline in use,
    # what went wrong is kept like any other comparison that did not run (nothing to keep otherwise).
    $igWhy = 'it failed: ' + ($_.Exception.Message -replace '\s+', ' ')
    Write-WatchLog ('{0} INTEGRITY not compared: {1}' -f (Get-Date -Format 's'), $igWhy)
    if ($previous['integrity'] -is [hashtable] -and $previous['integrity']['baseline']) {
        $integrityState = @{}
        foreach ($k in @($previous['integrity'].Keys)) { $integrityState[$k] = $previous['integrity'][$k] }
        try { Update-IntegritySkip -State $integrityState -Why $igWhy -Logged } catch { Write-Verbose "integrity: $($_.Exception.Message)" }
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
# An emptied Open WebUI does not wait for a second run (nothing about it passes by itself), and is
# told also when Backups was reported for another reason already. Once for each emptying: $emptiedTold
# is saved when the notification went out ($null = leave the record as it is).
$emptiedNews = ($emptiedKey -and (Get-WatchStamp $previous['emptiedTold']) -ne $emptiedKey)
$emptiedTold = $null
if ($emptiedNews -and $toNotify -notcontains 'Backups') { $toNotify += 'Backups' }
$stillReported = @($failed | Where-Object { $prevNotified -contains $_ })
$reminder = ($toNotify.Count -eq 0 -and $stillReported.Count -gt 0 -and (-not $lastToast -or ((Get-Date) - $lastToast).TotalHours -ge $remindHours))
if ($reminder) { $toNotify = $stillReported }
$notifiedAt = $previous['notifiedAt']
# A 'back to normal' that could not be shown is retried (else the last word stays 'problem detected').
$pendingRecovered = @()
if ($previous.ContainsKey('pendingRecovered') -and $previous['pendingRecovered']) { $pendingRecovered = @($previous['pendingRecovered']) }
# Recovered is only what was looked at on this run and passed. A check that did not run says nothing
# either way: with Docker down none of the containers is looked at, Open WebUI stopped for a backup
# is left alone, and the chat path is not tried without Open WebUI. Counting those as recovered sent
# 'recovered Open WebUI' the moment Docker stopped. What was reported and did not run stays reported,
# with no notification, until its check runs again.
# Left alone under the volume lock is 'did not run' for $lockBoundMinutes minutes only. Found so on
# every run after that, Open WebUI (or deep research) has a result, failed, and goes the way of every
# failed check: a notification when a second run in a row finds it, and the reminders.
# What is no longer part of this install is owed nothing: deep research removed, or a mirror no longer
# configured, would stay 'not checked' for good, and no later notice could say 'back to normal'.
$retired = @()
if ($researchPort -le 0) { $retired += 'Deep research' }
if (-not $mirrorTarget) { $retired += 'Backup mirror' }
$owed = @(@(@($prevNotified) + @($pendingRecovered | Where-Object { $prevNotified -notcontains $_ })) | Where-Object { $retired -notcontains $_ })
$recovered = @($owed | Where-Object { $results.Contains($_) -and $results[$_] })
$notChecked = @($owed | Where-Object { -not $results.Contains($_) })
$notified = @(@($failed | Where-Object { ($prevNotified -contains $_) -or ($toNotify -contains $_) }) + $notChecked)
$recoveryFailed = $false

$failedText = @($failed | ForEach-Object { if ($details.ContainsKey($_)) { '{0} ({1})' -f $_, $details[$_] } else { $_ } }) -join ', '
$line = '{0} {1}{2}' -f (Get-Date -Format 's'), $(if ($failed.Count) { 'FAIL ' + $failedText } else { 'OK' }), $(if ($healed.Count) { ' (restarted: ' + ($healed -join ', ') + ')' } else { '' })
# Said of what this run left alone and did not judge, by name. One that has been down under the lock
# for too long stands in the FAIL part with its own words, and is not called left alone.
if ($leftAlone.Count) { $line += ' (' + ($leftAlone -join ', ') + ' stopped for a backup/restore/update; left alone)' }
Write-WatchLog $line
Write-Verbose $line

function Get-WatchHint([string[]]$Failed) {
    # One concrete next step, using the Start-menu shortcuts (typed commands may be blocked by policy).
    $hint = 'Start menu > Local AI - Health check shows details.'
    $heldNow = Get-LaiWebUIHold -AIRoot $AIRoot
    if (@($failed | Where-Object { $lockOverdue -contains $_ }).Count) {
        # Down under a volume lock that stays held ($lockBoundMinutes). The shortcut that starts the
        # stack waits for the same lock, and the Recover line of a hold is not the step either: a
        # restore that is still running has written its hold already. The step is the health check's
        # (Get-WebUIStopReason in Test-LocalAI.ps1): a window that is still working is left to finish,
        # and the PC is restarted only when there is none (a restore cut off by a restart leaves the
        # volume half-swapped).
        $hint = 'If a Local AI window is still at work on a backup, restore or update, let it finish. If none is, restart the PC, which ends whatever holds the lock.'
    } elseif ($heldNow -and $failed -contains 'Open WebUI') {
        # Start again would refuse; the only fix is the recovery restore (the command is in the details).
        $hint = 'Open WebUI is stopped on purpose after a failed restore. The fix is the Recover line in ' + (Join-Path $AIRoot 'open-webui-hold.json') + ': paste it into PowerShell.'
    } elseif ($engine -eq 'hung' -and $failed -contains 'Docker') {
        # Docker Desktop is running and does not answer: Start again would get no answer either, so
        # restarting it comes first.
        $hint = 'Restart Docker Desktop (whale icon > Restart). If the stack is not back a few minutes later, use Start menu > Local AI - Start again.'
    } elseif ($failed -contains 'Docker' -or $failed -contains 'Open WebUI' -or $failed -contains 'SearXNG' -or $failed -contains 'Render guard' -or $failed -contains 'Ollama' -or $failed -contains 'Chats reach Ollama') {
        $hint = 'Use Start menu > Local AI - Start again. If that does not help, restart Docker Desktop (whale icon > Restart) and use Start again once more.'
    } elseif ($failed -contains 'Disk space') {
        $hint = 'Free some disk space (old backups in ' + $backupDir + ', unused models).'
        # With an emptied Open WebUI on record an old backup is the only copy of the chats, and this
        # hint stands in the notice that says so: it must not offer the backups for deletion.
        if ($emptiedKey) { $hint = 'Free some disk space (unused models). Keep every backup in ' + $backupDir + ' until the chats are back.' }
    } elseif ($failed -contains 'Backups') {
        $hint = 'The reason is at the end of ' + $backupLog + '.'
    } elseif ($failed -contains 'Backup mirror') {
        $hint = 'Check that the backup mirror drive or NAS share is reachable and has free space.'
    }
    return $hint
}

if ($toNotify.Count -gt 0) {
    $hint = Get-WatchHint $failed
    $title = 'Local AI: problem detected'; if ($reminder) { $title = 'Local AI: still not working' }
    $prefix = ''; if ($recovered.Count) { $prefix = 'Working again: ' + ($recovered -join ', ') + '. ' }
    if (Send-Notification $title ("{0}Not working: {1}. {2}" -f $prefix, $failedText, $hint)) {
        $notifiedAt = (Get-Date).ToString('s')
        if ($emptiedNews) { $emptiedTold = $emptiedKey }
    } else {
        # Not shown: keep them unreported so the next run tries again (and any recovery news too).
        $notified = @($notified | Where-Object { $toNotify -notcontains $_ -or $stillReported -contains $_ })
        if ($recovered.Count) { $recoveryFailed = $true }
    }
} elseif ($recovered.Count -gt 0 -or ($healed.Count -gt 0 -and $failed.Count -eq 0)) {
    $parts = @()
    if ($healed.Count -gt 0) { $parts += 'restarted ' + ($healed -join ', ') }
    $other = @($recovered | Where-Object { $healed -notcontains $_ })
    if ($other.Count -gt 0) { $parts += 'recovered ' + ($other -join ', ') }
    # 'Back to normal' only when nothing reported is left: neither failing nor left unchecked on this
    # run (an Open WebUI stopped for a backup may be as broken afterwards as it was reported before).
    $title = 'Local AI: back to normal'; if ($failed.Count -or $notChecked.Count) { $title = 'Local AI: partly recovered' }
    $text = ($parts -join '; ') + '.'
    if ($failed.Count) { $text += ' Still not working: ' + $failedText + '.' }
    if ($notChecked.Count) { $text += ' Not checked on this run: ' + ($notChecked -join ', ') + '.' }
    $sent = Send-Notification $title $text
    if (-not $sent -and $recovered.Count) { $recoveryFailed = $true }
}

# ---- banner in Open WebUI -------------------------------------------------------------------
# The same two strikes as the toast: a problem seen on two runs in a row is also shown at the top of
# every Open WebUI page (phone included) until it is fixed, so it is seen even when the toast was
# missed or Windows drops it. Signs in only when the set of problems changes.
$failedKeys = (@($failed | Where-Object { $prevFailed -contains $_ } | Sort-Object) -join ', ')
# Announced integrity differences that are still there share the banner (and change its key, so it is
# rewritten when they change and removed when they are accepted or undone). The key follows what the
# banner says, not the content of a file: one that is rewritten every hour is the same line each time.
$bannerKeys = $failedKeys
if ($integrityShown.Count) {
    $bannerKeys = 'changed ' + (Get-LaiIntegrityTag -Text (@($integrityShown | ForEach-Object { [string]$_['Text'] }) -join "`n"))
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
                $changed = 'changed since the last install or update: {0}. If you did not do this, {1}' -f (Format-LaiIntegrityList -Items @($integrityShown | ForEach-Object { [string]$_['Text'] }) -Max 3),
                    (Get-LaiIntegrityAdvice -Ids @($integrityShown | ForEach-Object { [string]$_['Id'] }) -AIRoot $AIRoot -Brief)
                # Open WebUI renders a banner as Markdown, for everyone who uses it, and the names in it
                # were chosen by whoever made the change. In these texts names and paths stand in double
                # quotes and nothing else does (Compare-LaiIntegrity, Get-LaiIntegrityAdvice): shown as
                # code they cannot become a link, and their backslashes are not eaten.
                $parts += $changed.Replace('"', '`')
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
if ($emptiedTold) { $final['emptiedTold'] = $emptiedTold } elseif (-not $emptiedKey) { $final.Remove('emptiedTold') }
if ($null -ne $bannerDone) { if ($bannerDone) { $final['banner'] = $bannerDone } else { $final.Remove('banner') } }
if ($script:toastSetting) { if ($script:toastSetting -ne 'Enabled') { $final['toastSetting'] = $script:toastSetting } else { $final.Remove('toastSetting') } }
if ($null -ne $ollamaNotice) { if ($ollamaNotice) { $final['ollamaNotifiedFor'] = $ollamaNotice } else { $final.Remove('ollamaNotifiedFor') } }
if ($null -ne $driftSince) { if ($driftSince) { $final['ollamaDriftSince'] = $driftSince } else { $final.Remove('ollamaDriftSince') } }
if ($recheckNotice) { $final['recheckNotifiedFor'] = $recheckNotice }
# Since when Open WebUI and deep research have been seen down under a held volume lock, and when
# last ($lockBoundMinutes): written and removed here and nowhere else. A time without an entry stays
# as it is: its service was not looked at (Docker down), or the stamp is one this run could not read.
foreach ($k in @($lockStamps.Keys)) { if ($lockStamps[$k]) { $final[$k] = $lockStamps[$k] } else { $final.Remove($k) } }
# (A baseline accepted while this run was busy has another id: the next run starts over with it.)
if ($null -ne $integrityState) { $final['integrity'] = $integrityState }
Save-LaiState -State $final -Path $statePath
exit $failed.Count
