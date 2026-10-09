<#
.SYNOPSIS
    Watch-LocalAI.ps1 against real containers: it heals a stopped SearXNG, leaves Open WebUI alone
    while another process holds the volume lock (a backup/restore/update), reports it once that has
    lasted 45 minutes (and still does not start it), and does nothing while paused.

.DESCRIPTION
    Uses the sandbox's real `searxng` container (always started again at the end) and a throwaway
    alpine container named `open-webui`. Open WebUI's port points at a dead one (3999), so the real
    sandbox Open WebUI never answers for the stand-in.
#>
param([string]$Work = (Join-Path ([System.IO.Path]::GetTempPath()) 'lai-watchtest'))
$ErrorActionPreference = 'Stop'
# Refuses to run anywhere but a throwaway test machine (it would delete a real install's data).
if (-not (& (Join-Path $PSScriptRoot 'Assert-LaiSandbox.ps1'))) { exit 99 }
$src = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
$failures = 0
function Assert-That([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  ASSERT OK   $Message" -ForegroundColor Green }
    else { Write-Host "  ASSERT FAIL $Message" -ForegroundColor Red; $script:failures++ }
}
function Invoke-DockerText([string[]]$DockerArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return ((& docker @DockerArgs 2>&1 | ForEach-Object { "$_" }) -join "`n").Trim() } finally { $ErrorActionPreference = $prev }
}
function Get-State([string]$Name) { return (Invoke-DockerText @('inspect', '-f', '{{.State.Status}}', $Name)) }
function Invoke-Watch([string[]]$Arguments = @()) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & pwsh -NoProfile -File (Join-Path $src 'Watch-LocalAI.ps1') -AIRoot $aiRoot @Arguments 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = $prev
    return ($out -join "`n")
}
function Get-WatchLog { $f = Join-Path (Join-Path $aiRoot 'Logs') 'watch.log'; if (Test-Path -LiteralPath $f) { return (Get-Content -Raw -LiteralPath $f) } return '' }
# A time the watch keeps in its state file, as the text that was written ('' when it is not there):
# PowerShell 7 hands an ISO time in a JSON file back as a date.
function Get-WatchStateTime([string]$Key) {
    $st = Read-LaiState -Path (Join-Path $aiRoot 'watch-state.json')
    if (-not $st.ContainsKey($Key)) { return '' }
    if ($st[$Key] -is [datetime]) { return $st[$Key].ToString('s') }
    return [string]$st[$Key]
}
# One of the toolkit's scripts in a child process, as a Start-menu shortcut runs it: what it printed
# (errors included), its exit code and how long it took.
function Invoke-Script([string]$Name, [string[]]$Arguments = @()) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = (& pwsh -NoProfile -File (Join-Path $src $Name) -AIRoot $aiRoot @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $code = $LASTEXITCODE; $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Text = $out; Sec = $sw.Elapsed.TotalSeconds }
}
# The last line of a script's output that matches a pattern ('' when none does).
function Get-LastLine([string]$Text, [string]$Pattern) {
    return [string]@($Text -split "`n" | Where-Object { $_ -match $Pattern } | Select-Object -Last 1)
}
# The row a health check printed for one check.
function Get-CheckRow([string]$Text, [string]$Check) {
    return (Get-LastLine $Text (' (PASS|WARN|FAIL|SKIP) ' + [regex]::Escape($Check) + ': '))
}
# What Start again, Gaming mode and the health check say about a Docker Desktop that does not
# answer, word for word (as a pattern).
$hungSaid = [regex]::Escape('Docker Desktop is not responding. Restart it (whale icon > Restart), wait for Engine running, then run this again.')

if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
$aiRoot = Join-Path $Work 'AI'
foreach ($d in 'Logs', 'Backups', 'Stack') { New-Item -ItemType Directory -Force -Path (Join-Path $aiRoot $d) | Out-Null }
ConvertTo-Json @{ WebUIPort = 3999; SearxngPort = 8888; OllamaUrl = 'http://127.0.0.1:11434' } | Set-Content -LiteralPath (Join-Path $aiRoot 'localai-config.json')
if ((Get-State 'searxng') -notmatch 'running|exited') { Write-Host 'No sandbox searxng container; this test needs it.' -ForegroundColor Red; exit 1 }
$holder = $null

try {
    Write-Host "`n=== 1. a stopped SearXNG is started again ===" -ForegroundColor Cyan
    Invoke-DockerText @('stop', 'searxng') | Out-Null
    Invoke-Watch | Out-Null
    Assert-That ((Get-State 'searxng') -eq 'running') 'SearXNG running again'
    Assert-That ((Get-WatchLog) -match 'restarted: [^)]*SearXNG') "watch.log records the restart"

    Write-Host "`n=== 2. paused: nothing is healed ===" -ForegroundColor Cyan
    Invoke-Watch @('-PauseMinutes', '5') | Out-Null
    Invoke-DockerText @('stop', 'searxng') | Out-Null
    Invoke-Watch | Out-Null
    Assert-That ((Get-State 'searxng') -eq 'exited') 'paused watch leaves the stopped container alone'
    Invoke-Watch @('-Unpause') | Out-Null
    Invoke-Watch | Out-Null
    Assert-That ((Get-State 'searxng') -eq 'running') 'after -Unpause it heals again'

    Write-Host "`n=== 3. Open WebUI stopped while a backup/restore holds the volume lock ===" -ForegroundColor Cyan
    Invoke-DockerText @('rm', '-f', 'open-webui') | Out-Null
    Invoke-DockerText @('create', '--name', 'open-webui', 'alpine:3.20', 'sleep', '3600') | Out-Null
    $holdScript = Join-Path $Work 'hold-lock.ps1'
    Set-Content -LiteralPath $holdScript -Value ("Import-Module '{0}' -Force; `$l = Enter-LaiVolumeLock; Start-Sleep -Seconds 600; Exit-LaiVolumeLock `$l" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'))
    $holder = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $holdScript) -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-LaiVolumeLockBusy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    Assert-That (Test-LaiVolumeLockBusy) 'setup: another process holds the volume lock'
    # A restore in progress has already written its hold: still maintenance, not a failure.
    ConvertTo-Json @{ Reason = 'a restore was interrupted (or is still running)'; Recover = 'x' } | Set-Content -LiteralPath (Join-Path $aiRoot 'open-webui-hold.json')
    # Open WebUI was reported as not working before the backup or restore began. Left alone means not
    # checked, and not checked is not 'working again': nothing is announced and it stays reported.
    $state3 = Join-Path $aiRoot 'watch-state.json'
    Save-LaiState -State @{ failed = @('Open WebUI'); notified = @('Open WebUI'); notifiedAt = (Get-Date).ToString('s') } -Path $state3
    # A notice that counts Open WebUI among what works again (the names end at the first full stop).
    $webuiBack = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -match ' NOTIFY [^\n]*(recovered|Working again:) [^.\n]*Open WebUI' }).Count }
    $back3 = & $webuiBack
    Invoke-Watch | Out-Null
    $lastLine = @((Get-WatchLog) -split "`n" | Where-Object { $_ -and $_ -notmatch ' NOTIFY ' })[-1]
    Remove-Item -LiteralPath (Join-Path $aiRoot 'open-webui-hold.json') -Force
    Assert-That ($lastLine -match 'left alone' -and $lastLine -notmatch 'failed restore') "a restore still running is not reported as failed ($lastLine)"
    Assert-That ((& $webuiBack) -eq $back3 -and @((Read-LaiState -Path $state3)['notified']) -contains 'Open WebUI') "an Open WebUI that was reported and is now left alone for a backup or restore is not announced as recovered, and stays reported ($((& $webuiBack) - $back3) notice(s); reported: $(@((Read-LaiState -Path $state3)['notified']) -join ', '))"
    Assert-That ((Get-State 'open-webui') -eq 'created') 'Open WebUI is not started mid-backup/restore'
    Assert-That ((Get-WatchLog) -match 'left alone') 'watch.log says it was left alone on purpose'
    # Left alone is counted from the first run that finds it so: that run writes down when, one stamp
    # for Open WebUI (webuiLockedSince) and one for deep research (3b), in the watch's state file.
    $seen3 = Get-WatchStateTime 'webuiLockedSince'
    $seenAge = -1
    if ($seen3 -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$') { $seenAge = ((Get-Date) - [datetime]::ParseExact($seen3, 's', [Globalization.CultureInfo]::InvariantCulture)).TotalMinutes }
    Assert-That ($seenAge -ge 0 -and $seenAge -lt 10) "the first run that finds Open WebUI down under the lock records since when (webuiLockedSince: '$seen3', $([math]::Round($seenAge, 1)) min ago)"
    # Two were reported. SearXNG answers again while Open WebUI is still left alone: that is not 'back
    # to normal', which would be the last word although Open WebUI has not been looked at. The notice
    # says what recovered and what was not checked. (A fresh backup and no disk limit, so that nothing
    # else is expected to fail; the assertion holds either way.)
    $fresh3 = Join-Path (Join-Path $aiRoot 'Backups') ('open-webui-{0}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $fresh3 -Value 'x'
    Save-LaiState -State @{ failed = @('Open WebUI', 'SearXNG'); notified = @('Open WebUI', 'SearXNG'); notifiedAt = (Get-Date).ToString('s') } -Path $state3
    $normal3 = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -match ' NOTIFY Local AI: back to normal' }).Count }
    $normalBefore = & $normal3
    Invoke-Watch @('-MinFreeGB', '0') | Out-Null
    $part3 = [string]@((Get-WatchLog) -split "`n" | Where-Object { $_ -match ' NOTIFY ' })[-1]
    Remove-Item -LiteralPath $fresh3 -Force
    Assert-That ((& $normal3) -eq $normalBefore -and $part3 -match 'NOTIFY Local AI: partly recovered: recovered SearXNG\.[^\n]* Not checked on this run: Open WebUI\.' -and @((Read-LaiState -Path $state3)['notified']) -contains 'Open WebUI') "one of two reported recovers while the other is left alone: 'partly recovered' naming what was not checked, no 'back to normal', and Open WebUI stays reported ($((& $normal3) - $normalBefore) 'back to normal'; $part3)"
    # Left alone has an end. Any program of the owner's can hold that lock and stop the container, and
    # the watch then said nothing, run after run. Once the stamp is 45 minutes old Open WebUI counts as
    # failed on every run, in words that name the lock, and is still not started under it. The stamp
    # is written into the state file as the times above are (nothing else makes it old). The fresh
    # backup is gone again, so Backups fails next to it: the FAIL line is searched for Open WebUI.
    $lockSaid = 'Open WebUI \(down[^)\n]*the volume lock [^)\n]*longer than a backup, restore or update normally takes; not started while the lock is held\)'
    $noTimeSaid = ' FAIL [^\n]*Open WebUI \(down with the volume lock held, and the watch''s record of since when cannot be read as a time that has passed, which counts as longer than '
    $statusLine = { [string]@((Get-WatchLog) -split "`n" | Where-Object { $_ -and $_ -notmatch ' NOTIFY ' })[-1] }
    $problems3 = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -match ' NOTIFY Local AI: problem detected: ' }) }
    $old3 = (Get-Date).AddMinutes(-50)
    Save-LaiState -State @{ webuiLockedSince = $old3.ToString('s') } -Path $state3
    $toldBefore = @(& $problems3).Count
    Invoke-Watch | Out-Null
    $line3 = & $statusLine
    Assert-That ($line3 -match (' FAIL [^\n]*Open WebUI \(down, and by the watch''s record the volume lock was held each time it looked since ' + [regex]::Escape($old3.ToString('yyyy-MM-dd HH:mm')) + ', longer than ') -and $line3 -match $lockSaid -and $line3 -notmatch 'left alone' -and @((Read-LaiState -Path $state3)['failed']) -contains 'Open WebUI') "an Open WebUI found down under the lock for 50 minutes is failed, naming the lock and since when, and is not called left alone ($line3)"
    Assert-That ((Get-State 'open-webui') -eq 'created' -and (Get-WatchStateTime 'webuiLockedSince') -eq $old3.ToString('s') -and @(& $problems3).Count -eq $toldBefore) "it is still not started under the lock, its stamp keeps its time, and one such run sends no notice (the container is $(Get-State 'open-webui'); stamp '$(Get-WatchStateTime 'webuiLockedSince')', written '$($old3.ToString('s'))'; $(@(& $problems3).Count - $toldBefore) notice(s))"
    # The second such run in a row tells, as for every failed check. The next step is the health
    # check's (let a window that is still at work finish, else restart the PC), not Start again, which
    # waits for the same lock.
    Invoke-Watch | Out-Null
    $told3 = @(& $problems3)
    $note3 = [string]$told3[-1]
    Assert-That ($told3.Count -eq $toldBefore + 1 -and $note3 -match ('Not working: [^\n]*' + $lockSaid) -and $note3 -match 'If a Local AI window is still at work on a backup, restore or update, let it finish\. If none is, restart the PC, which ends whatever holds the lock\.' -and $note3 -notmatch 'Start again' -and (Get-State 'open-webui') -eq 'created') "the second run in a row sends one notice that names Open WebUI with the lock, gives the health check's step and not Start again, and the container is still not started ($($told3.Count - $toldBefore) notice(s), the container is $(Get-State 'open-webui'): $note3)"
    # A stamp in the future (written while the clock was wrong, or by another program: the state file
    # is one any program of the owner's can write) must not buy quiet until that day. It counts as
    # overdue at once, no time is printed for it, and it is left as it is.
    $ahead3 = (Get-Date).AddDays(400)
    Save-LaiState -State @{ webuiLockedSince = $ahead3.ToString('s') } -Path $state3
    Invoke-Watch | Out-Null
    $line3 = & $statusLine
    Assert-That ($line3 -match $noTimeSaid -and $line3 -match $lockSaid -and $line3 -notmatch 'left alone' -and $line3 -notmatch [regex]::Escape($ahead3.ToString('yyyy-MM-dd')) -and (Get-State 'open-webui') -eq 'created' -and (Get-WatchStateTime 'webuiLockedSince') -like ($ahead3.ToString('yyyy-MM-dd') + '*')) "a stamp 400 days ahead counts as overdue: Open WebUI is failed without a time, not started, and the stamp stays ($line3; stamp '$(Get-WatchStateTime 'webuiLockedSince')')"
    # And so does one that is no time at all. What the file held is never printed.
    $junk3 = 'no-time-planted-by-the-test'
    Save-LaiState -State @{ webuiLockedSince = $junk3 } -Path $state3
    Invoke-Watch | Out-Null
    $line3 = & $statusLine
    Assert-That ($line3 -match $noTimeSaid -and $line3 -match $lockSaid -and $line3 -notmatch 'left alone' -and $line3 -notmatch [regex]::Escape($junk3) -and (Get-State 'open-webui') -eq 'created' -and (Get-WatchStateTime 'webuiLockedSince') -eq $junk3) "a stamp that is no time counts as overdue: Open WebUI is failed and not started, the stamp's text is not printed, and the stamp stays ($line3; stamp '$(Get-WatchStateTime 'webuiLockedSince')')"
    # 3b starts without a stamp, so that its first run is the first sighting for both.
    Save-LaiState -State @{ failed = @() } -Path $state3

    Write-Host "`n=== 3b. deep research paused by a backup: left alone under the lock, woken after ===" -ForegroundColor Cyan
    # A stand-in answering on its health URL, under deep research's container name: Python's http.server
    # from the SearXNG image the sandbox already has (alpine's busybox has no httpd).
    Invoke-DockerText @('rm', '-f', 'deep-research') | Out-Null
    $pyImage = Invoke-DockerText @('inspect', '-f', '{{.Config.Image}}', 'searxng')
    Invoke-DockerText @('run', '-d', '--name', 'deep-research', '--label', 'lai-test=1', '--network', 'host', '--entrypoint', 'sh', $pyImage, '-c',
        'mkdir -p /tmp/www/api/v1 && echo ok > /tmp/www/api/v1/health && exec python3 -m http.server 5061 --bind 127.0.0.1 --directory /tmp/www') | Out-Null
    $cfgPath = Join-Path $aiRoot 'localai-config.json'
    $cfg = Read-LaiState -Path $cfgPath; $cfg['DeepResearchPort'] = 5061; Save-LaiState -State $cfg -Path $cfgPath
    try {
        $deadline = (Get-Date).AddSeconds(20)
        $up = $false
        while (-not $up -and (Get-Date) -lt $deadline) { try { Wait-LaiHttp -Uri 'http://127.0.0.1:5061/api/v1/health' -TimeoutSec 2 | Out-Null; $up = $true } catch { Start-Sleep -Milliseconds 300 } }
        Assert-That $up "setup: the stand-in answers on its health URL ($pyImage)"
        Invoke-DockerText @('pause', 'deep-research') | Out-Null
        Invoke-Watch | Out-Null
        Assert-That ((Get-State 'deep-research') -eq 'paused') 'deep research paused while a backup holds the volume lock is left alone'
        # Deep research has a stamp of its own (researchLockedSince) next to Open WebUI's: that run was
        # the first to find both down under the lock. With its stamp 50 minutes old deep research is
        # failed in the lock's words and stays paused (nothing wakes it under the lock), while Open
        # WebUI, found so two minutes ago, is still left alone and named as that.
        $st3b = Read-LaiState -Path $state3
        Assert-That ($st3b.ContainsKey('webuiLockedSince') -and $st3b.ContainsKey('researchLockedSince')) "the first run that finds both down under the lock records a stamp for each (in the state file: $(@($st3b.Keys | Sort-Object) -join ', '))"
        $old3b = (Get-Date).AddMinutes(-50); $new3b = (Get-Date).AddMinutes(-2)
        Save-LaiState -State @{ webuiLockedSince = $new3b.ToString('s'); researchLockedSince = $old3b.ToString('s') } -Path $state3
        Invoke-Watch | Out-Null
        $line3b = & $statusLine
        $failed3b = @((Read-LaiState -Path $state3)['failed'])
        Assert-That ($line3b -match (' FAIL [^\n]*Deep research \(down, and by the watch''s record the volume lock was held each time it looked since ' + [regex]::Escape($old3b.ToString('yyyy-MM-dd HH:mm')) + ', longer than a backup, restore or update normally takes; not started while the lock is held\)') -and $line3b -match '\(Open WebUI stopped for a backup/restore/update; left alone\)' -and $failed3b -contains 'Deep research' -and $failed3b -notcontains 'Open WebUI' -and (Get-State 'deep-research') -eq 'paused') "deep research found paused under the lock for 50 minutes is failed, naming the lock, and stays paused; Open WebUI, found so 2 minutes ago, is left alone (deep research is $(Get-State 'deep-research'); failed: $($failed3b -join ', '); $line3b)"
        Assert-That ((Get-WatchStateTime 'webuiLockedSince') -eq $new3b.ToString('s') -and (Get-WatchStateTime 'researchLockedSince') -eq $old3b.ToString('s')) "while the lock stays held a run keeps both stamps at their times: the count does not start over (Open WebUI '$(Get-WatchStateTime 'webuiLockedSince')', written '$($new3b.ToString('s'))'; deep research '$(Get-WatchStateTime 'researchLockedSince')', written '$($old3b.ToString('s'))')"
        if ($holder -and -not $holder.HasExited) { $holder.Kill() }
        $deadline = (Get-Date).AddSeconds(30)
        while ((Test-LaiVolumeLockBusy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        Invoke-DockerText @('rm', '-f', 'open-webui') | Out-Null   # the stand-in from 3. would be started and waited for
        Invoke-Watch | Out-Null
        Assert-That ((Get-State 'deep-research') -eq 'running' -and (Get-WatchLog) -match 'restarted: [^)]*Deep research') 'a deep research container left paused (a backup killed mid-copy) is woken once the lock is free'
        # The lock is free: the run that finds it so removes both stamps (deep research answers again,
        # and Open WebUI, whose stand-in is gone, is down with nothing held over it).
        $st3b = Read-LaiState -Path $state3
        Assert-That (-not $st3b.ContainsKey('webuiLockedSince') -and -not $st3b.ContainsKey('researchLockedSince')) "once the lock is let go the next run removes both stamps (in the state file: $(@($st3b.Keys | Sort-Object) -join ', '))"
    } finally {
        Invoke-DockerText @('rm', '-f', 'deep-research') | Out-Null
        $cfg = Read-LaiState -Path $cfgPath; $cfg.Remove('DeepResearchPort'); Save-LaiState -State $cfg -Path $cfgPath
    }

    Write-Host "`n=== 4. gaming mode Stop/Start wait for a running backup instead of racing it ===" -ForegroundColor Cyan
    # A throwaway compose project, so the sandbox's real containers are not touched.
    $stack = Join-Path $aiRoot 'Stack'
    @'
name: lai-stopstart-test
services:
  probe:
    image: alpine:3.20
    container_name: lai-stopstart-probe
    command: ["sleep", "3600"]
'@ | Set-Content -LiteralPath (Join-Path $stack 'docker-compose.yml')
    Invoke-DockerText @('compose', '--project-directory', $stack, '-f', (Join-Path $stack 'docker-compose.yml'), 'up', '-d') | Out-Null
    $cfg = Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json'); $cfg['WebUIPort'] = 3000; Save-LaiState -State $cfg -Path (Join-Path $aiRoot 'localai-config.json')
    foreach ($step in @(@{ Script = 'Stop-LocalAI.ps1'; Want = 'exited' }, @{ Script = 'Start-LocalAI.ps1'; Want = 'exited'; HoldDuringWait = $true }, @{ Script = 'Start-LocalAI.ps1'; Want = 'running' })) {
        $holdBody = ''
        if ($step.HoldDuringWait) {
            # The restore holding the lock fails while Start waits: Start must see the hold it leaves.
            $holdBody = "; Set-Content -LiteralPath '{0}' -Value '{{`"Reason`":`"restore and its rollback failed`",`"Recover`":`"x`"}}'" -f (Join-Path $aiRoot 'open-webui-hold.json')
        }
        Set-Content -LiteralPath $holdScript -Value ("Import-Module '{0}' -Force; `$l = Enter-LaiVolumeLock; Start-Sleep -Seconds 8{1}; Exit-LaiVolumeLock `$l" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'), $holdBody)
        $holder = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $holdScript) -PassThru
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-LaiVolumeLockBusy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        $t0 = Get-Date
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $out = (& pwsh -NoProfile -File (Join-Path $src $step.Script) -AIRoot $aiRoot 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $code = $LASTEXITCODE; $ErrorActionPreference = $prev
        $waited = ((Get-Date) - $t0).TotalSeconds
        if ($step.HoldDuringWait) {
            Assert-That ($code -ne 0 -and $out -match 'kept stopped after a failed restore' -and (Get-State 'lai-stopstart-probe') -eq 'exited') ("Start-LocalAI re-checks after the wait: refuses on the hold the restore left (exit {0})" -f $code)
            Remove-Item -LiteralPath (Join-Path $aiRoot 'open-webui-hold.json') -Force -ErrorAction SilentlyContinue
        } else {
            Assert-That ($code -eq 0 -and $out -match 'Waiting for a backup' -and $waited -ge 4 -and (Get-State 'lai-stopstart-probe') -eq $step.Want) ("{0} waited {1:N0} s for the lock, then the container is {2} (exit {3})" -f $step.Script, $waited, (Get-State 'lai-stopstart-probe'), $code)
        }
        if ($step.Script -eq 'Stop-LocalAI.ps1') {
            # Gaming mode stops the containers first and unloads the models after that: a chat that was
            # still being answered would load its model again right behind an unload.
            $stoppedAt = $out.IndexOf('Containers stopped')
            $unloadLine = [regex]::Match($out, '\] (No model loaded|Unloaded |Still loaded after two unloads)')
            Assert-That ($stoppedAt -ge 0 -and $unloadLine.Success -and $unloadLine.Index -gt $stoppedAt) ("Stop-LocalAI stops the containers before it unloads the models ('Containers stopped' at {0}, the unload line '{1}' at {2})" -f $stoppedAt, $unloadLine.Value, $unloadLine.Index)
        }
        if (-not $holder.HasExited) { $holder.WaitForExit(15000) | Out-Null }
    }

    Write-Host "`n=== 4b. Open WebUI stopped on purpose in the health check; a model that will not unload in gaming mode ===" -ForegroundColor Cyan
    # Port 3999 answers nothing and there is no open-webui container: for the health check Open WebUI
    # is down. With the hold a failed restore leaves, that is a failure with the hold's reason and its
    # way out, not 'not found - re-run the installer' and not 'no answer - Start again' (Start again
    # refuses on a hold). The container row says it and the row for the page skips.
    $cfg4 = Read-LaiState -Path $cfgPath; $cfg4['WebUIPort'] = 3999; Save-LaiState -State $cfg4 -Path $cfgPath
    $holdFile = Join-Path $aiRoot 'open-webui-hold.json'
    ConvertTo-Json @{ Reason = 'restore and its rollback failed (4b)'; Recover = 'run the recovery command of 4b' } | Set-Content -LiteralPath $holdFile
    $holdSaid = 'kept stopped after a failed restore \(restore and its rollback failed \(4b\)\)\. Recover first: run the recovery command of 4b'
    $busySaid = 'Open WebUI is down and the volume lock was still held after the 3 s this check was told to wait \(-LockWaitSec\)'
    try {
        $hc4 = Invoke-Script 'Test-LocalAI.ps1' @('-Quick')
        $rowC = Get-CheckRow $hc4.Text 'Container open-webui'; $rowP = Get-CheckRow $hc4.Text 'Open WebUI reachable'
        Assert-That ($rowC -match (' FAIL Container open-webui: ' + $holdSaid) -and $rowP -match ' SKIP Open WebUI reachable: ') "with a hold the health check fails the Open WebUI container with the hold's reason and its Recover line, once: the row for the page skips ($rowC / $rowP)"
        # Without the container rows the row for the page says it itself.
        $hc4 = Invoke-Script 'Test-LocalAI.ps1' @('-Quick', '-NoContainers')
        $rowP = Get-CheckRow $hc4.Text 'Open WebUI reachable'
        Assert-That ($rowP -match (' FAIL Open WebUI reachable: ' + $holdSaid)) "with a hold 'Open WebUI reachable' fails with the hold's reason and its Recover line, not with Start again ($rowP)"
        # A backup, restore or update at work holds the volume lock and has stopped Open WebUI for a
        # few minutes. The health check waits for a held lock (-LockWaitSec, 3 s here) and then
        # fails with the lock's words, never a warning: a run with Open WebUI stopped must not end
        # with 0 failures. Also with the hold file there (a restore writes it before it has
        # failed): the lock is still asked before the hold file, so the words are the lock's, not
        # the hold's. The holder is ended below, long before its 600 s.
        Set-Content -LiteralPath $holdScript -Value ("Import-Module '{0}' -Force; `$l = Enter-LaiVolumeLock; Start-Sleep -Seconds 600; Exit-LaiVolumeLock `$l" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'))
        $holder = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $holdScript) -PassThru
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-LaiVolumeLockBusy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        Assert-That (Test-LaiVolumeLockBusy) 'setup: another process holds the volume lock (4b)'
        $hc4 = Invoke-Script 'Test-LocalAI.ps1' @('-Quick', '-LockWaitSec', '3')
        $rowC = Get-CheckRow $hc4.Text 'Container open-webui'; $rowP = Get-CheckRow $hc4.Text 'Open WebUI reachable'
        Assert-That ($rowC -match (' FAIL Container open-webui: ' + $busySaid) -and $rowP -match ' SKIP Open WebUI reachable: ') "under a held volume lock the health check waits the 3 s it was told to and then fails the Open WebUI container with the lock's words, also with the hold file a running restore has written, once: the row for the page skips ($rowC / $rowP)"
        $hc4 = Invoke-Script 'Test-LocalAI.ps1' @('-Quick', '-NoContainers', '-LockWaitSec', '3')
        $rowP = Get-CheckRow $hc4.Text 'Open WebUI reachable'
        Assert-That ($rowP -match (' FAIL Open WebUI reachable: ' + $busySaid)) "and 'Open WebUI reachable' fails the same way, after the same wait, when it is the row that meets it ($rowP)"
    } finally {
        if ($holder -and -not $holder.HasExited) { $holder.Kill() }
        $deadline = (Get-Date).AddSeconds(30)
        while ((Test-LaiVolumeLockBusy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        Remove-Item -LiteralPath $holdFile -Force -ErrorAction SilentlyContinue
    }
    # Gaming mode with containers it cannot stop: docker compose rejects the compose file, and the
    # container of 4. goes on running. The run used to end on that error with the watch left paused
    # for 12 hours over containers that still ran, and no line said so. The pause is now taken back,
    # and the last line before the error says that the watch stays on.
    $composeFile = Join-Path $stack 'docker-compose.yml'
    $composeText = Get-Content -Raw -LiteralPath $composeFile
    Set-Content -LiteralPath $composeFile -Value 'services: not-a-mapping'
    try {
        $stopF = Invoke-Script 'Stop-LocalAI.ps1'
        $pausedF = (Read-LaiState -Path $state3).ContainsKey('pausedUntil')
        $failF = Get-LastLine $stopF.Text '\[FAIL\] '
        Assert-That ($stopF.Code -ne 0 -and $failF -match 'Gaming mode did not finish, and the health watch stays on: docker compose stop failed: ' -and -not $pausedF -and (Get-State 'lai-stopstart-probe') -eq 'running') ("Gaming mode that cannot stop the containers ends as failed, says that the health watch stays on, and has taken its pause back (exit {0}, paused: {1}, the container is {2}: {3})" -f $stopF.Code, $pausedF, (Get-State 'lai-stopstart-probe'), $failF)
    } finally {
        Set-Content -LiteralPath $composeFile -Value $composeText -NoNewline
        Invoke-Watch @('-Unpause') | Out-Null
    }
    # Gaming mode against an Ollama that keeps its model listed whatever it is told (a stand-in:
    # /api/ps always names one model, an unload is answered and changes nothing). After the second
    # unload the model is named in a warning, and no line says it was unloaded.
    # Its port is asked of the system (a TcpListener on port 0, closed again at once), as
    # Start-TestListener in the unit tests does: a fixed number can be a port that is taken.
    $fakeAsk = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $fakeAsk.Start(); $fakePort = $fakeAsk.LocalEndpoint.Port; $fakeAsk.Stop()
    $fakeOllama = Join-Path $Work 'fake_ollama.py'
    @"
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _j(self, o):
        d = json.dumps(o).encode(); self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(d))); self.end_headers(); self.wfile.write(d)
    def do_GET(self):
        if self.path == '/api/ps': self._j({'models': [{'name': 'stuck-model:latest'}]})
        else: self._j({'version': 'fake'})
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length') or 0)); self._j({})
ThreadingHTTPServer(('127.0.0.1', $fakePort), H).serve_forever()
"@ | Set-Content -LiteralPath $fakeOllama
    $realOllama = [string]$cfg4['OllamaUrl']
    $fake = Start-Process -FilePath 'python3' -ArgumentList $fakeOllama -PassThru
    try {
        $fakeUp = $false
        for ($i = 0; $i -lt 50 -and -not $fakeUp -and -not $fake.HasExited; $i++) {
            try { Invoke-LaiApi -Uri "http://127.0.0.1:$fakePort/api/ps" -TimeoutSec 2 | Out-Null; $fakeUp = $true } catch { Start-Sleep -Milliseconds 200 }
        }
        Assert-That $fakeUp "setup: the stand-in Ollama answers on port $fakePort"
        $cfg4['OllamaUrl'] = "http://127.0.0.1:$fakePort"; Save-LaiState -State $cfg4 -Path $cfgPath
        $stop4 = Invoke-Script 'Stop-LocalAI.ps1'
        $stuckLine = Get-LastLine $stop4.Text 'Still loaded after two unloads'
        Assert-That ($stop4.Code -eq 0 -and $stuckLine -match '\[WARN\] Still loaded after two unloads: stuck-model:latest\. ' -and $stop4.Text -notmatch '\] Unloaded ' -and $stop4.Text.IndexOf('Containers stopped') -ge 0 -and $stop4.Text.IndexOf('Containers stopped') -lt $stop4.Text.IndexOf('Still loaded after two unloads')) ("a model that is still listed after the second unload is named in a warning, after the containers were stopped, and is not reported as unloaded (exit {0}, {1:N0} s: {2})" -f $stop4.Code, $stop4.Sec, $stuckLine)
    } finally {
        if (-not $fake.HasExited) { $fake.Kill() }
        # That run paused the watch, and the sections below need it running.
        Invoke-Watch @('-Unpause') | Out-Null
        $cfg4['OllamaUrl'] = $realOllama; $cfg4['WebUIPort'] = 3000; Save-LaiState -State $cfg4 -Path $cfgPath
    }

    Write-Host "`n=== 4c. the diagnostics keep a container's log in the order it was written ===" -ForegroundColor Cyan
    # A stand-in under deep research's container name that writes to stdout and to stderr in turn, a
    # second apart. 'docker logs' hands the two over separately, and the bundle held all of the first
    # followed by all of the second: which request led to which error could not be read from it. The
    # diagnostics now ask for the time of every line and put the lines back in that order.
    $said4c = 'first-on-stdout second-on-stderr third-on-stdout fourth-on-stderr'
    Invoke-DockerText @('rm', '-f', 'deep-research') | Out-Null
    Invoke-DockerText @('run', '-d', '--name', 'deep-research', '--label', 'lai-test=1', 'alpine:3.20', 'sh', '-c',
        'echo first-on-stdout; sleep 1; echo second-on-stderr >&2; sleep 1; echo third-on-stdout; sleep 1; echo fourth-on-stderr >&2') | Out-Null
    try {
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-State 'deep-research') -ne 'exited' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        Assert-That ((Get-State 'deep-research') -eq 'exited') "setup: the stand-in has written its four lines and ended ($(Get-State 'deep-research'))"
        $diagOut4 = Join-Path $Work 'diag-out-4c'
        $diag4 = Invoke-Script 'Get-LocalAIDiagnostics.ps1' @('-OutDir', $diagOut4)
        $zip4 = @(Get-ChildItem -LiteralPath $diagOut4 -Filter 'diagnostics-*.zip' -ErrorAction SilentlyContinue)
        $logTxt = ''
        if ($zip4.Count -eq 1) {
            Expand-Archive -LiteralPath $zip4[0].FullName -DestinationPath (Join-Path $Work 'diag-x-4c') -Force
            $logPart = Join-Path (Join-Path $Work 'diag-x-4c') 'logs-deep-research.txt'
            if (Test-Path -LiteralPath $logPart) { $logTxt = Get-Content -Raw -LiteralPath $logPart }
        }
        # Each of the four lines with its time in front, in the order they come in the file.
        $order4c = @([regex]::Matches($logTxt, '(?m)^\d{4}-\d\d-\d\dT[0-9:.]+Z (first-on-stdout|second-on-stderr|third-on-stdout|fourth-on-stderr)\s*$') | ForEach-Object { $_.Groups[1].Value }) -join ' '
        Assert-That ($diag4.Code -eq 0 -and $order4c -eq $said4c) ("the bundle's container log has stdout and stderr in the order they were written, each line with its time (exit {0}, {1} zip(s): '{2}')" -f $diag4.Code, $zip4.Count, $order4c)
    } finally { Invoke-DockerText @('rm', '-f', 'deep-research') | Out-Null }

    Write-Host "`n=== 5. long-term: reminders, clock skew, backup mirror, disk hysteresis ===" -ForegroundColor Cyan
    $cfgFile = Join-Path $aiRoot 'localai-config.json'
    $statePath = Join-Path $aiRoot 'watch-state.json'
    $bdir = Join-Path $aiRoot 'Backups'
    $lastFail = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -match ' (FAIL|OK)( |$)' -and $_ -notmatch ' NOTIFY' })[-1] }
    $notifyCount = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -match ' NOTIFY' }).Count }
    Get-ChildItem -LiteralPath $bdir -File | Remove-Item -Force
    # (a) A problem reported 25 h ago and still there is announced again; an hour later it is not.
    Save-LaiState -State @{ failed = @('Backups'); notified = @('Backups'); notifiedAt = (Get-Date).AddHours(-25).ToString('s') } -Path $statePath
    $n0 = & $notifyCount
    Invoke-Watch @('-NoHeal') | Out-Null
    $n1 = & $notifyCount
    Assert-That ($n1 -eq $n0 + 1 -and (Get-WatchLog) -match 'NOTIFY Local AI: still not working: Not working: [^\n]*Backups') 'a problem that lasts is announced again after 24 h (not once a year)'
    $remindCount = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -match 'NOTIFY Local AI: still not working' }).Count }
    $r1 = & $remindCount
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((& $remindCount) -eq $r1) 'but not again on the next run'
    # (b) An archive dated a year ahead must not look fresh.
    $future = Join-Path $bdir ('open-webui-{0}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $future -Value 'x'; (Get-Item -LiteralPath $future).LastWriteTime = (Get-Date).AddDays(365)
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((& $lastFail) -match 'Backups \(no nightly backup in the last 50 h; open-webui-\S+ is dated \S+, in the future .*: delete it\)') "a backup dated in the future fails the check and says to delete it, next to the plain reason that no other backup is there ($(& $lastFail))"
    # ...also next to a fresh one (clock fixed since): it would otherwise block pruning and restores for a year.
    Set-Content -LiteralPath (Join-Path $bdir ('open-webui-{0}.tar.gz' -f (Get-Date).AddHours(-1).ToString('yyyyMMdd-HHmmss'))) -Value 'x'
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((& $lastFail) -match 'Backups \(open-webui-[^)]*in the future') 'a future-dated archive is reported even when a fresh backup exists'
    Remove-Item -LiteralPath $future -Force
    Get-ChildItem -LiteralPath $bdir -File | Remove-Item -Force
    # (c) A configured mirror that did not get the newest backup.
    Set-Content -LiteralPath (Join-Path $bdir ('open-webui-{0}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Value 'x'
    $c5 = Read-LaiState -Path $cfgFile; $c5['BackupMirror'] = '\\nas\gone'; Save-LaiState -State $c5 -Path $cfgFile
    Save-LaiState -State @{ mirrorError = 'The network path was not found' } -Path (Join-Path $aiRoot 'backup-state.json')
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((& $lastFail) -match 'Backup mirror \(newest backup not copied to [^)]*network path was not found\)' -and (& $lastFail) -notmatch 'Backups \(') "a mirror that stopped is a failed check with its reason ($(& $lastFail))"
    Save-LaiState -State @{ mirrorOkAt = (Get-Date).ToString('s'); mirrorTarget = '\\nas\other' } -Path (Join-Path $aiRoot 'backup-state.json')
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((& $lastFail) -match 'Backup mirror') 'a success recorded for a different mirror target does not count'
    Save-LaiState -State @{ mirrorOkAt = (Get-Date).ToString('s'); mirrorTarget = '\\nas\gone' } -Path (Join-Path $aiRoot 'backup-state.json')
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((& $lastFail) -notmatch 'Backup mirror') 'and passes once the newest backup was mirrored'
    # No record yet (an update installed this check hours before its first backup): look at the mirror itself.
    $mdir = Join-Path $Work 'mirror-folder'; New-Item -ItemType Directory -Force -Path $mdir | Out-Null
    $c5 = Read-LaiState -Path $cfgFile; $c5['BackupMirror'] = $mdir; Save-LaiState -State $c5 -Path $cfgFile
    Remove-Item -LiteralPath (Join-Path $aiRoot 'backup-state.json') -Force
    Copy-Item -LiteralPath @(Get-ChildItem -LiteralPath $bdir -Filter 'open-webui-*.tar.gz')[0].FullName -Destination $mdir
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((& $lastFail) -notmatch 'Backup mirror') 'without a record, a newest backup present in the mirror passes (no false alarm after an update)'
    Get-ChildItem -LiteralPath $mdir -File | Remove-Item -Force
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((& $lastFail) -match 'Backup mirror') 'and missing from the mirror fails'
    # The database check of the nightly backups has not run for 3 nights.
    Save-LaiState -State @{ deepCheckSkips = 3 } -Path (Join-Path $aiRoot 'backup-state.json')
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((& $lastFail) -match 'Backups \(the database check of the nightly backup could not run for 3 nights') "a database check that keeps failing to run is a failed check ($(& $lastFail))"
    Remove-Item -LiteralPath (Join-Path $aiRoot 'backup-state.json') -Force
    # A 'back to normal' toast that fails is retried on the next run.
    Save-LaiState -State @{ failed = @('Backups'); notified = @('Backups'); notifiedAt = (Get-Date).ToString('s') } -Path $statePath
    Invoke-Watch @('-NoHeal', '-TestToastFail') | Out-Null
    Assert-That (@((Read-LaiState -Path $statePath)['pendingRecovered']) -contains 'Backups') 'a recovery toast that failed is kept for the next run'
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((Get-WatchLog) -match 'NOTIFY Local AI: [^\n]*(recovered Backups|Working again: Backups)' -and -not (Read-LaiState -Path $statePath).ContainsKey('pendingRecovered')) 'and is sent on the next run'
    # A 'problem detected' toast that fails is not marked as delivered: the next run tries again.
    Get-ChildItem -LiteralPath $bdir -File | Remove-Item -Force
    Save-LaiState -State @{ failed = @('Backups'); notified = @() } -Path $statePath
    Invoke-Watch @('-NoHeal', '-TestToastFail') | Out-Null
    Assert-That (@((Read-LaiState -Path $statePath)['notified']) -notcontains 'Backups') 'a problem toast that failed is not counted as delivered'
    # The next run sends it, with the variable set that used to make every toast fail. No hook of the
    # watch is read from the environment any more: a program running as the owner could leave such a
    # variable set for good, and no notification would have gone out since.
    $before = @((Get-WatchLog) -split "`n" | Where-Object { $_ -match 'NOTIFY Local AI: problem detected' }).Count
    $env:LOCALAI_TEST_TOAST_FAIL = '1'
    try { Invoke-Watch @('-NoHeal') | Out-Null } finally { $env:LOCALAI_TEST_TOAST_FAIL = '' }
    $after = @((Get-WatchLog) -split "`n" | Where-Object { $_ -match 'NOTIFY Local AI: problem detected' }).Count
    Assert-That ($after -eq $before + 1 -and @((Read-LaiState -Path $statePath)['notified']) -contains 'Backups') 'and is sent on the next run, also with LOCALAI_TEST_TOAST_FAIL set: that variable alone makes no toast fail'
    # (d) Disk hysteresis: 'low' clears only with 2 GB to spare above the limit.
    # The free space sits near the middle of [limit, limit + 2) (at least 0.5 GB from either edge):
    # with limit = floor(free) - 1 it could be a few MB under limit + 2, and a file written or deleted
    # during the run flipped the result.
    $freeExact = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($aiRoot)).AvailableFreeSpace / 1GB
    $freeGB = [Math]::Round($freeExact, 1)
    $limit = [int][Math]::Round($freeExact - 1)
    Save-LaiState -State @{ failed = @() } -Path $statePath
    Invoke-Watch @('-NoHeal', '-MinFreeGB', "$limit") | Out-Null
    Assert-That ((& $lastFail) -notmatch 'Disk space') "free space 1 GB above the limit passes when it was fine before ($freeGB GB free, limit $limit)"
    Save-LaiState -State @{ failed = @('Disk space') } -Path $statePath
    Invoke-Watch @('-NoHeal', '-MinFreeGB', "$limit") | Out-Null
    Assert-That ((& $lastFail) -match 'Disk space') 'but after a low-space failure it needs 2 GB more before it counts as fixed (no toast flapping)'
    $c5 = Read-LaiState -Path $cfgFile; $c5.Remove('BackupMirror'); Save-LaiState -State $c5 -Path $cfgFile
    # (e) Deep research's own nightly archive keeps failing while the Open WebUI backup is fine: one
    # bad night is a warning in the health check, no good one for 50 h fails Backups with the reason.
    # Port 5062 answers nothing, so 'Deep research' fails next to it; only Backups is looked at.
    $bstatePath = Join-Path $aiRoot 'backup-state.json'
    $w5 = @('-NoHeal', '-MinFreeGB', '0')
    Set-Content -LiteralPath (Join-Path $bdir ('open-webui-{0}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Value 'x'
    $c5 = Read-LaiState -Path $cfgFile; $c5['DeepResearchPort'] = 5062; Save-LaiState -State $c5 -Path $cfgFile
    $researchError = "tar: short read`n   on the volume"
    $researchSaid = [regex]::Escape('tar: short read on the volume (see ' + (Join-Path (Join-Path $aiRoot 'Logs') 'backup.log') + ')')
    Save-LaiState -State @{ researchError = $researchError; researchErrorAt = (Get-Date).ToString('s') } -Path $bstatePath
    Invoke-Watch $w5 | Out-Null
    Assert-That ((& $lastFail) -match ('Backups \([^\n]*last good one: none on record[^\n]*' + $researchSaid)) "a deep research backup that fails with no good one on record fails Backups, with the recorded reason on one line and the path of backup.log ($(& $lastFail))"
    Save-LaiState -State @{ researchError = $researchError; researchOkAt = (Get-Date).AddHours(-51).ToString('s') } -Path $bstatePath
    Invoke-Watch $w5 | Out-Null
    Assert-That ((& $lastFail) -match ('Backups \([^\n]*' + $researchSaid)) "and so does one whose last good backup is 51 h old ($(& $lastFail))"
    Save-LaiState -State @{ researchError = $researchError; researchOkAt = (Get-Date).AddHours(-1).ToString('s') } -Path $bstatePath
    Invoke-Watch $w5 | Out-Null
    Assert-That ((& $lastFail) -notmatch 'Backups') "a failure an hour after a good backup does not fail the check ($(& $lastFail))"
    $drReported = @((Read-LaiState -Path $statePath)['notified']) -contains 'Deep research'
    $c5 = Read-LaiState -Path $cfgFile; $c5.Remove('DeepResearchPort'); Save-LaiState -State $c5 -Path $cfgFile
    Save-LaiState -State @{ researchError = $researchError } -Path $bstatePath
    Invoke-Watch $w5 | Out-Null
    Assert-That ((& $lastFail) -notmatch 'Backups') "and an old record does not either once deep research is not installed ($(& $lastFail))"
    # Deep research was reported (its port answered nothing on three runs) and is now removed. That is
    # not 'not checked': kept as reported it would stand in every later notice as left unchecked, and
    # none could say 'back to normal' again.
    Assert-That ($drReported -and @((Read-LaiState -Path $statePath)['notified']) -notcontains 'Deep research') "a reported check that is no longer part of the install is dropped, not carried as not checked (reported before: $drReported; now: $(@((Read-LaiState -Path $statePath)['notified']) -join ', '))"
    # The newest archive is an -EMPTY one (the nightly backup found Open WebUI without its users or
    # chats) and backup-state.json holds no record of it. The run above passed Backups on the fresh
    # nightly archive; with the -EMPTY one next to it, newer, the name alone fails the check. The
    # reason stands in the log line (it was a bare 'Backups' once, which sent the owner to a log that
    # does not say the record is gone), with the restore of the nightly backup from before it.
    $emOrphan = Join-Path $bdir ('open-webui-{0}-EMPTY.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $emOrphan -Value 'x'
    Invoke-Watch $w5 | Out-Null
    $orphanFail = [string](& $lastFail)
    Assert-That ($orphanFail -match ('Backups \(the newest backup, ' + [regex]::Escape((Split-Path -Leaf $emOrphan)) + ', was made when Open WebUI''s data looked wiped, and the record of it is gone from backup-state\.json') -and
        $orphanFail -match 'Restore-OpenWebUI\.ps1[^\n]* -Archive ''[^'']*open-webui-\d{8}-\d{6}\.tar\.gz''' -and $orphanFail -notmatch 'no nightly backup in the last 50 h') "a newest archive named -EMPTY fails Backups also without its record in backup-state.json, with the reason in the log line and the restore of the nightly backup from before it ($orphanFail)"
    Remove-Item -LiteralPath $emOrphan -Force
    # (f) The nightly backup found Open WebUI's data wiped and recorded it ('emptied'). From a state
    # with no failures the very first run tells: the first night, the counts of the last backup and of
    # the last good one, that backup, the command that puts it back, that no older backup is deleted,
    # the command for an owner who emptied it on purpose, and that the notice stays after a restore
    # until a backup has counted the data again. Once: the second run sends nothing.
    # This record has chats left (3 of 40): the backup sets the mark under a tenth as well, and a
    # notice that said 'no chats' then read like a false alarm.
    # LOCALAI_TEST_TOAST_SETTING is set for the first run. It used to make the watch act as if Windows
    # had notifications off (and record that for the health check); alone it changes nothing now.
    $emAt = (Get-Date).AddDays(-1)
    $emGood = 'open-webui-20260101-030000.tar.gz'
    # The restore command is only given for a file that is in the backup folder: this one is.
    Set-Content -LiteralPath (Join-Path $bdir $emGood) -Value 'x'
    # The words every notice for a recorded emptying begins with.
    $emLead = 'Open WebUI''s data has looked wiped since the nightly backup of '
    $emNotices = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -match (' NOTIFY Local AI: problem detected: [^\n]*' + $emLead) }) }
    Save-LaiState -State @{ emptied = @{ at = $emAt.ToString('s'); archive = 'open-webui-emptied.tar.gz'; lastGood = $emGood; users = 1; chats = 3; hadUsers = 1; hadChats = 40 } } -Path $bstatePath
    Save-LaiState -State @{ failed = @() } -Path $statePath
    $em0 = @(& $emNotices).Count
    $env:LOCALAI_TEST_TOAST_SETTING = 'DisabledForUser'
    try { Invoke-Watch $w5 | Out-Null } finally { $env:LOCALAI_TEST_TOAST_SETTING = '' }
    $em = @(& $emNotices)
    $emLine = ''; if ($em.Count) { $emLine = [string]$em[-1] }
    $emSays = $emLine -match [regex]::Escape($emLead + $emAt.ToString('yyyy-MM-dd') + '; at the last backup 1 user(s) and 3 chat(s), 1 and 40 at the last good one; the last good backup is ' + $emGood) -and
        $emLine -match ('Restore-OpenWebUI\.ps1[^\n]* -Archive ' + [regex]::Escape("'" + (Join-Path $bdir $emGood) + "'")) -and $emLine -match 'no older backup is deleted meanwhile' -and
        $emLine -match 'if you emptied it yourself, run once: [^\n]*Backup-OpenWebUI\.ps1[^\n]* -AcceptEmpty; after a restore this notice stays until the next nightly backup has counted the data again \(the same command without -AcceptEmpty does that at once\)'
    Assert-That ($em.Count -eq $em0 + 1 -and $emSays) "an emptied Open WebUI is announced by the first run that sees it: the first night, the counts of the last backup (3 chats, not 'no chats') and of the last good one, that backup, the restore command with that file, that no older backup is deleted, the -AcceptEmpty command for an owner who emptied it, and that the notice stays after a restore until a backup has counted the data ($($em.Count - $em0) notice(s): $emLine)"
    $ws5 = Read-LaiState -Path $statePath
    $emTold = [string]$ws5['emptiedTold']
    Assert-That ($emTold -and @($ws5['notified']) -contains 'Backups' -and -not $ws5.ContainsKey('toastSetting')) "it is recorded as told, and LOCALAI_TEST_TOAST_SETTING alone neither drops the toast nor records a notification switch (toastSetting '$([string]$ws5['toastSetting'])')"
    Invoke-Watch $w5 | Out-Null
    Assert-That (@(& $emNotices).Count -eq $em0 + 1) 'the second run does not announce it again'
    # Emptied once more on a later night (this record names the last good backup by its full path),
    # and the notification fails: not counted as told, so the next run tells.
    $emGood2 = Join-Path $bdir 'open-webui-20260102-030000.tar.gz'
    Set-Content -LiteralPath $emGood2 -Value 'x'
    Save-LaiState -State @{ emptied = @{ at = (Get-Date).ToString('s'); lastGood = $emGood2; chats = 0; hadChats = 3 } } -Path $bstatePath
    Invoke-Watch ($w5 + @('-TestToastFail')) | Out-Null
    $emTried = @((Get-WatchLog) -split "`n" | Where-Object { $_ -match ('NOTIFY \(toast failed\) Local AI: problem detected: [^\n]*' + $emLead) }).Count
    Assert-That ($emTried -eq 1 -and [string](Read-LaiState -Path $statePath)['emptiedTold'] -eq $emTold) "a new emptying is announced although Backups was reported already; that notification failed, so it is not recorded as told ($emTried tried)"
    # OS is set for this run as Windows sets it. The watch took that variable for 'this is Windows':
    # here it then tried a real toast (which fails on Linux), and on a PC any other value in the
    # owner's own variables sent every notice to watch.log only. It asks .NET for the platform now.
    $savedOS = $env:OS
    $env:OS = 'Windows_NT'
    try { Invoke-Watch $w5 | Out-Null } finally { $env:OS = $savedOS }
    $em = @(& $emNotices)
    Assert-That ($em.Count -eq $em0 + 2 -and [string]$em[-1] -match (' -Archive ' + [regex]::Escape("'" + $emGood2 + "'")) -and [string](Read-LaiState -Path $statePath)['emptiedTold'] -ne $emTold) "and the next run sends it, with the full path of a file in the backup folder ($([string]$em[-1]))"
    # That record holds two of the four counts (no users). A number is printed only from a record
    # that has all four: the file is one any program of the owner can write.
    Assert-That ([string]$em[-1] -match ($emLead + '\d{4}-\d\d-\d\d; the last good backup is ') -and [string]$em[-1] -notmatch 'user\(s\)|chat\(s\)') "a record without all four counts is announced without numbers ($([string]$em[-1]))"
    $osNotice = [string]@((Get-WatchLog) -split "`n" | Where-Object { $_ -match ' NOTIFY' })[-1]
    Assert-That ($osNotice -match ' NOTIFY Local AI: problem detected: ' -and $osNotice -notmatch 'toast failed') "with OS set to Windows_NT alone it is still the plain notice of a run off Windows: the platform is not read from that variable ($osNotice)"
    # The record names a file that exists, but outside the backup folder (as one on another drive or a
    # share would be), and the nightly backups stopped three days ago. No restore command for a file
    # that is not in the backup folder, and the missing nightly backup is named next to the emptying:
    # Backups is reported already, so nothing else would say that no backup is being made.
    # While the mark stands the nightly archives are the -EMPTY ones, so they count for this too: one
    # of them is in the folder, as old as the rest.
    $emElsewhere = Join-Path $Work 'open-webui-20260103-030000.tar.gz'
    Set-Content -LiteralPath $emElsewhere -Value 'x'
    Set-Content -LiteralPath (Join-Path $bdir 'open-webui-20260104-030000-EMPTY.tar.gz') -Value 'x'
    Get-ChildItem -LiteralPath $bdir -File | ForEach-Object { $_.LastWriteTime = (Get-Date).AddDays(-3) }
    Save-LaiState -State @{ emptied = @{ at = (Get-Date).AddHours(-2).ToString('s'); lastGood = $emElsewhere; chats = 0; hadChats = 3 } } -Path $bstatePath
    Invoke-Watch $w5 | Out-Null
    $emFail = [string](& $lastFail)
    Assert-That ($emFail -match ($emLead + '\d{4}-\d\d-\d\d; the backup on record as the last good one, ' + [regex]::Escape($emElsewhere) + ', is not in ' + [regex]::Escape($bdir) + ' ') -and $emFail -notmatch 'Restore-OpenWebUI|-Archive ') "a recorded backup outside the backup folder is named as not being there, with no restore command ($emFail)"
    Assert-That ($emFail -match ('Backups \([^\n]*' + $emLead + '[^\n]*; no nightly backup in the last 50 h')) "and nightly backups that stopped meanwhile are named next to the emptying, an -EMPTY archive of three days ago being no fresh one either ($emFail)"
    # The nightly task that still runs under the mark makes an -EMPTY archive each night. A fresh one
    # is the nightly backup of that night: the emptying is still told, and the notice no longer adds
    # that no nightly backup was made (it did after the second night, with the task at work).
    $emFresh = Join-Path $bdir ('open-webui-{0}-EMPTY.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $emFresh -Value 'x'
    Invoke-Watch $w5 | Out-Null
    $emFreshFail = [string](& $lastFail)
    Assert-That ($emFreshFail -match ('Backups \([^\n]*' + $emLead) -and $emFreshFail -notmatch 'no nightly backup in the last 50 h') "a fresh -EMPTY archive under the mark counts as the nightly backup of that night: no 'no nightly backup in the last 50 h' ($emFreshFail)"
    # The mirror row under the mark: what must be in the mirror is that fresh -EMPTY archive (the
    # backup copies it too), not the newest archive with a nightly name, which is from before. With
    # only those older ones in the mirror the row fails; with the -EMPTY one copied it passes.
    $c5 = Read-LaiState -Path $cfgFile; $c5['BackupMirror'] = $mdir; Save-LaiState -State $c5 -Path $cfgFile
    Get-ChildItem -LiteralPath $bdir -File | Where-Object { $_.Name -notlike '*-EMPTY.tar.gz' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $mdir }
    Invoke-Watch $w5 | Out-Null
    $emMirrorMissing = [string](& $lastFail)
    Copy-Item -LiteralPath $emFresh -Destination $mdir
    Invoke-Watch $w5 | Out-Null
    $emMirrorThere = [string](& $lastFail)
    $c5 = Read-LaiState -Path $cfgFile; $c5.Remove('BackupMirror'); Save-LaiState -State $c5 -Path $cfgFile
    Get-ChildItem -LiteralPath $mdir -File | Remove-Item -Force
    Assert-That ($emMirrorMissing -match 'Backup mirror \(newest backup not copied to ' -and $emMirrorThere -match 'Backups \(' -and $emMirrorThere -notmatch 'Backup mirror') "under the mark the mirror must hold the newest -EMPTY archive: with only the older nightly archives there the mirror row fails, with that archive copied it passes ($emMirrorMissing / $emMirrorThere)"
    Remove-Item -LiteralPath $emElsewhere -Force
    Remove-Item -LiteralPath $bstatePath -Force
    Get-ChildItem -LiteralPath $bdir -File | Remove-Item -Force

    Write-Host "`n=== 6. Ollama updated itself since the presets were tuned: one notice, then quiet ===" -ForegroundColor Cyan
    # The sandbox's real Ollama stands in for one the tray app replaced; the tuning says 0.0.1.
    $realVer = [string](Invoke-LaiApi -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 10).version
    $instPath = Join-Path $aiRoot 'install-state.json'
    Save-LaiState -State @{ tuning = @{ main = @{ Alias = 'localai-main'; OllamaVersion = '0.0.1'; Fingerprint = 'driver=1;kv=q8_0' }; old = @{ Alias = 'localai-old' } } } -Path $instPath
    $updLines = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -match 'NOTIFY Local AI: Ollama was updated' }) }
    $u0 = @(& $updLines).Count
    Invoke-Watch @('-NoHeal') | Out-Null
    Invoke-Watch @('-NoHeal') | Out-Null
    $upd = @(& $updLines)
    Assert-That ($upd.Count -eq $u0 + 1) "two runs, exactly one notice ($($upd.Count - $u0))"
    $updLine = ''; if ($upd.Count) { $updLine = [string]$upd[-1] }
    Assert-That ($updLine -match [regex]::Escape("Ollama updated itself to $realVer; main were measured on 0.0.1") -and $updLine -match 'Start menu > Local AI - Re-check models' -and $updLine -notmatch 'Update-Models\.ps1') "it names the new and the measured version, only the preset with a recorded version, and the Re-check models shortcut, not a command to type ($updLine)"
    $ws = Read-LaiState -Path $statePath
    Assert-That ([string]$ws['ollamaNotifiedFor'] -eq $realVer -and @(@($ws['failed']) | Where-Object { "$_" -match 'Ollama|tuning|preset' }).Count -eq 0) 'recorded as told for this version, never as a failed check (no reminders, no exit code)'
    # Update-Models re-checked them: the tuning now records the running version.
    $st6 = Read-LaiState -Path $instPath; $st6['tuning']['main']['OllamaVersion'] = $realVer; Save-LaiState -State $st6 -Path $instPath
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That (@(& $updLines).Count -eq $u0 + 1 -and -not (Read-LaiState -Path $statePath).ContainsKey('ollamaNotifiedFor')) 'after the re-check: no further notice, and a later update is announced again'

    Write-Host "`n=== 6b. the nightly re-check is set up: the watch waits for it and tells only what needs the owner ===" -ForegroundColor Cyan
    $c6 = Read-LaiState -Path $cfgFile; $c6['ModelRecheckAt'] = '04:30'; Save-LaiState -State $c6 -Path $cfgFile
    $recheckFile = Join-Path $aiRoot 'model-recheck.json'
    # Only the notices about Ollama and the presets (other checks fail here too and notify on their own).
    $presetNotices = { param($Title) @((Get-WatchLog) -split "`n" | Where-Object { $_ -match (' NOTIFY [^\n]*Local AI: ' + $Title) }) }
    $anyPreset = 'Ollama was updated|a preset is off the GPU|presets not re-checked'
    $st6 = Read-LaiState -Path $instPath; $st6['tuning']['main']['OllamaVersion'] = '0.0.1'; Save-LaiState -State $st6 -Path $instPath
    $p0 = @(& $presetNotices $anyPreset).Count
    Invoke-Watch @('-NoHeal') | Out-Null
    Invoke-Watch @('-NoHeal') | Out-Null
    $sched = @((Get-WatchLog) -split "`n" | Where-Object { $_ -match [regex]::Escape("Ollama updated itself to $realVer; main measured on 0.0.1: re-check scheduled tonight at 04:30") })
    Assert-That (@(& $presetNotices $anyPreset).Count -eq $p0 -and $sched.Count -eq 1) "Ollama updated itself: two runs, no notification, one watch.log line that the re-check is scheduled ($($sched.Count))"
    $ws6 = Read-LaiState -Path $statePath
    Assert-That ($ws6['ollamaDriftSince'] -is [hashtable] -and [string]$ws6['ollamaDriftSince']['version'] -eq $realVer -and -not $ws6.ContainsKey('ollamaNotifiedFor')) 'the time this version was first seen is kept, nothing counts as told'
    # The re-check ran on this Ollama and could not set a preset up: exactly one notice, naming it.
    Save-LaiState -State @{ ollamaVersion = $realVer; at = (Get-Date).AddMinutes(-5).ToString('s'); result = 'failed'; presets = @('Uncensored Main (could not be set up)'); reason = 'this model may be incompatible with your version of Ollama (test)' } -Path $recheckFile
    Invoke-Watch @('-NoHeal') | Out-Null
    Invoke-Watch @('-NoHeal') | Out-Null
    $offGpu = @(& $presetNotices 'a preset is off the GPU')
    $offLine = ''; if ($offGpu.Count) { $offLine = [string]$offGpu[-1] }
    Assert-That ($offGpu.Count -eq 1 -and $offLine -match 'Uncensored Main' -and $offLine -match 'Re-check models' -and $offLine -match 'model-recheck\.log') "a failed re-check: exactly one notice over two runs, naming the preset and the Re-check models shortcut ($offLine)"
    Assert-That (@(& $presetNotices 'presets not re-checked').Count -eq 0) "and no 'could not run' notice for a re-check that did run"
    # The preset keeps failing: the next night records the same result again, at a new time. No new notice.
    Save-LaiState -State @{ ollamaVersion = $realVer; at = (Get-Date).AddMinutes(-1).ToString('s'); result = 'failed'; presets = @('Uncensored Main (could not be set up)'); reason = 'this model may be incompatible with your version of Ollama (test)' } -Path $recheckFile
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That (@(& $presetNotices 'a preset is off the GPU').Count -eq 1) 'the same failure found again the next night: no second notice'
    # Something new (another preset) is told.
    Save-LaiState -State @{ ollamaVersion = $realVer; at = (Get-Date).ToString('s'); result = 'failed'; presets = @('Uncensored Main (could not be set up)', 'Uncensored Fast (could not be set up)'); reason = 'x' } -Path $recheckFile
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That (@(& $presetNotices 'a preset is off the GPU').Count -eq 2) 'a different result (another preset) is a new notice'
    # Still waiting 3 days after the new version was first seen (the PC was busy every night): one notice.
    Save-LaiState -State @{ ollamaVersion = $realVer; at = (Get-Date).AddHours(-2).ToString('s'); result = 'skipped'; reason = 'GPU in use by python.exe' } -Path $recheckFile
    $ws6 = Read-LaiState -Path $statePath; $ws6['ollamaDriftSince'] = @{ version = $realVer; time = (Get-Date).AddHours(-73).ToString('s') }; Save-LaiState -State $ws6 -Path $statePath
    Invoke-Watch @('-NoHeal') | Out-Null
    Invoke-Watch @('-NoHeal') | Out-Null
    $late = @(& $presetNotices 'presets not re-checked')
    $lateLine = ''; if ($late.Count) { $lateLine = [string]$late[-1] }
    Assert-That ($late.Count -eq 1 -and $lateLine -match 'could not run' -and $lateLine -match 'python\.exe' -and $lateLine -match 'Re-check models') "73 h without a re-check: exactly one notice with the last skip reason and the shortcut ($lateLine)"
    $c6 = Read-LaiState -Path $cfgFile; $c6.Remove('ModelRecheckAt'); Save-LaiState -State $c6 -Path $cfgFile
    Remove-Item -LiteralPath $recheckFile -Force
    Remove-Item -LiteralPath $instPath -Force

    Write-Host "`n=== 7. a Docker Desktop that stopped answering (after sleep): reported, not a silent hang ===" -ForegroundColor Cyan
    # A docker CLI that never answers. Its process id (kept by exec) must be gone afterwards.
    $hangDir = Join-Path $Work 'hang-shim'
    New-Item -ItemType Directory -Force -Path $hangDir | Out-Null
    $pidFile = Join-Path $hangDir 'pids.txt'
    Set-Content -LiteralPath (Join-Path $hangDir 'docker') -Value ("#!/bin/sh`necho `$`$ >> '{0}'`nexec sleep 617" -f $pidFile)
    & chmod +x (Join-Path $hangDir 'docker')
    $savedPATH = $env:PATH
    $env:PATH = $hangDir + [System.IO.Path]::PathSeparator + $savedPATH
    # The 3 s limit is a parameter for the watch, which reads no hook from the environment. The backup
    # script still takes it from LOCALAI_DOCKER_TIMEOUT, set below for its run only.
    $w7 = @('-NoHeal', '-TestDockerTimeout', '3')
    try {
        Save-LaiState -State @{ failed = @() } -Path $statePath
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-Watch $w7 | Out-Null
        $watchSec = $sw.Elapsed.TotalSeconds
        $hangLine = & $lastFail
        Assert-That ($watchSec -lt 90 -and $hangLine -match 'FAIL .*Docker \(not responding \(no answer within 3 s\)' -and @((Read-LaiState -Path $statePath)['failed']) -contains 'Docker') ("the watch reports Docker as not responding, and logs and saves its state instead of hanging ({0:N0} s: {1})" -f $watchSec, $hangLine)
        # Seen on a second run it is announced, and the next step leads with restarting Docker
        # Desktop: Start again gets no answer from a Docker that does not answer. Case matters here:
        # the detail in the parentheses says 'restart Docker Desktop' too, in lower case.
        Invoke-Watch $w7 | Out-Null
        $hungNotice = [string]@((Get-WatchLog) -split "`n" | Where-Object { $_ -match ' NOTIFY Local AI: problem detected: ' })[-1]
        Assert-That ($hungNotice -cmatch 'Docker \(not responding[^\n]*\. Restart Docker Desktop \(whale icon > Restart\)\. ' -and $hungNotice -cnotmatch '\. Use Start menu > Local AI - Start again\. ') "for a Docker Desktop that does not answer, the notice's next step starts with restarting it, not with Start again ($hungNotice)"
        $env:LOCALAI_DOCKER_TIMEOUT = '3'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & pwsh -NoProfile -File (Join-Path $src 'Backup-OpenWebUI.ps1') -AIRoot $aiRoot -EngineWaitSec 20 2>&1 | Out-Null
        $bcode = $LASTEXITCODE; $ErrorActionPreference = $prev
        $backupSec = $sw.Elapsed.TotalSeconds
        $bl = Join-Path (Join-Path $aiRoot 'Logs') 'backup.log'
        $blog = ''; if (Test-Path -LiteralPath $bl) { $blog = Get-Content -Raw -LiteralPath $bl }
        Assert-That ($bcode -eq 1 -and $backupSec -lt 120 -and $blog -match '\[FAIL\] Docker Desktop is not responding') ("the nightly backup writes a FAIL line to backup.log and exits 1 instead of hanging (exit {0}, {1:N0} s)" -f $bcode, $backupSec)
        # The four scripts the owner starts by hand, against the same docker that never answers. They
        # used to wait on it without a word. Each takes the 3 s limit from LOCALAI_DOCKER_TIMEOUT, as
        # the backup above, and must end by itself and say what to do.
        $start7 = Invoke-Script 'Start-LocalAI.ps1'
        Assert-That ($start7.Code -ne 0 -and $start7.Sec -lt 120 -and $start7.Text -match ('\[FAIL\] Local AI did not start: ' + $hungSaid)) ("Start again ends with FAIL and the step for a Docker Desktop that does not answer, instead of hanging (exit {0}, {1:N0} s)" -f $start7.Code, $start7.Sec)
        # Gaming mode asks Docker before it changes anything: no pause is written for a stack it
        # could not stop (the watch would say nothing about this Docker for 12 hours).
        $stop7 = Invoke-Script 'Stop-LocalAI.ps1'
        $paused7 = (Read-LaiState -Path $statePath).ContainsKey('pausedUntil')
        Invoke-Watch @('-Unpause') | Out-Null
        Assert-That ($stop7.Code -ne 0 -and $stop7.Sec -lt 120 -and $stop7.Text -match ('\[FAIL\] [^\n]*' + $hungSaid) -and -not $paused7) ("Gaming mode ends as failed with that step, instead of hanging, and has not paused the health watch (exit {0}, {1:N0} s, paused: {2})" -f $stop7.Code, $stop7.Sec, $paused7)
        $hc7 = Invoke-Script 'Test-LocalAI.ps1' @('-Quick')
        $rowE = Get-CheckRow $hc7.Text 'Docker engine'; $rowC = Get-CheckRow $hc7.Text 'Container open-webui'
        Assert-That ($hc7.Sec -lt 180 -and $rowE -match (' FAIL Docker engine: ' + $hungSaid) -and $rowC -match ' SKIP Container open-webui: ') ("the health check fails the Docker engine check with that step and skips the container checks, instead of hanging ({0:N0} s: {1} / {2})" -f $hc7.Sec, $rowE, $rowC)
        $diagOut = Join-Path $Work 'diag-out'
        $diag7 = Invoke-Script 'Get-LocalAIDiagnostics.ps1' @('-OutDir', $diagOut)
        $zip7 = @(Get-ChildItem -LiteralPath $diagOut -Filter 'diagnostics-*.zip' -ErrorAction SilentlyContinue)
        $dockerTxt = ''
        if ($zip7.Count -eq 1) {
            Expand-Archive -LiteralPath $zip7[0].FullName -DestinationPath (Join-Path $Work 'diag-x') -Force
            $dockerPart = Join-Path (Join-Path $Work 'diag-x') 'docker.txt'
            if (Test-Path -LiteralPath $dockerPart) { $dockerTxt = Get-Content -Raw -LiteralPath $dockerPart }
        }
        Assert-That ($diag7.Code -eq 0 -and $diag7.Sec -lt 120 -and $zip7.Count -eq 1 -and $dockerTxt -match [regex]::Escape('(docker did not answer within 3 s)')) ("the diagnostics still make their zip, with '(docker did not answer within 3 s)' where the Docker parts would be, instead of hanging (exit {0}, {1:N0} s, {2} zip(s))" -f $diag7.Code, $diag7.Sec, $zip7.Count)
    } finally { $env:PATH = $savedPATH; $env:LOCALAI_DOCKER_TIMEOUT = '' }
    $pids = @(Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d+$' })
    # Still running = /proc entry that is not a zombie.
    $alive = @($pids | Where-Object { (Test-Path -LiteralPath "/proc/$_/stat") -and ((Get-Content -Raw -LiteralPath "/proc/$_/stat" -ErrorAction SilentlyContinue) -notmatch '^\d+ \(.*\) Z') })
    Assert-That ($pids.Count -ge 6 -and $alive.Count -eq 0) "every docker call that hung was stopped, those of Start again, Gaming mode, the health check and the diagnostics among them ($($pids.Count) started, $($alive.Count) still running)"

    Write-Host "`n=== 7b. Docker answers the first question and nothing after it: the command with work to do runs out of its time ===" -ForegroundColor Cyan
    # A docker CLI that answers the engine probe and never anything else. With LOCALAI_DOCKER_TIMEOUT
    # at 2, a quick call has 2 s, 'compose stop' ten times that and 'compose up' twenty times.
    $halfDir = Join-Path $Work 'half-shim'
    New-Item -ItemType Directory -Force -Path $halfDir | Out-Null
    $halfPids = Join-Path $halfDir 'pids.txt'
    Set-Content -LiteralPath (Join-Path $halfDir 'docker') -Value ("#!/bin/sh`nif [ `"`$1`" = version ]; then echo 27.0.0; exit 0; fi`necho `$`$ >> '{0}'`nexec sleep 617" -f $halfPids)
    & chmod +x (Join-Path $halfDir 'docker')
    $savedPATH = $env:PATH
    $env:PATH = $halfDir + [System.IO.Path]::PathSeparator + $savedPATH
    $env:LOCALAI_DOCKER_TIMEOUT = '2'
    try {
        # Gaming mode has paused the watch by the time 'compose stop' gets no answer: the pause is
        # taken back, or the watch would say nothing about this Docker for 12 hours.
        $stop7b = Invoke-Script 'Stop-LocalAI.ps1'
        $paused7b = (Read-LaiState -Path $statePath).ContainsKey('pausedUntil')
        Invoke-Watch @('-Unpause') | Out-Null
        Assert-That ($stop7b.Code -ne 0 -and $stop7b.Sec -lt 120 -and $stop7b.Text -match ('\[FAIL\] Gaming mode did not finish, and the health watch stays on: ' + $hungSaid) -and -not $paused7b) ("Gaming mode whose 'compose stop' gets no answer ends as failed with the step for Docker Desktop, and has taken its pause of the health watch back (exit {0}, {1:N0} s, paused: {2})" -f $stop7b.Code, $stop7b.Sec, $paused7b)
        # Start again: 'compose up' may be downloading images, so running out of its time is said as
        # that, with the next step, and not as a Docker Desktop that does not answer.
        $start7b = Invoke-Script 'Start-LocalAI.ps1' @('-TimeoutSec', '5')
        $fail7b = Get-LastLine $start7b.Text '\[FAIL\] '
        Assert-That ($start7b.Code -ne 0 -and $start7b.Sec -lt 150 -and $fail7b -match 'Local AI did not start: docker compose up did not finish within 40 s\. Restart Docker Desktop ' -and $start7b.Text -notmatch $hungSaid) ("Start again whose 'compose up' does not finish says so with its time limit and the next step, not that Docker Desktop is not responding (exit {0}, {1:N0} s: {2})" -f $start7b.Code, $start7b.Sec, $fail7b)
    } finally { $env:PATH = $savedPATH; $env:LOCALAI_DOCKER_TIMEOUT = '' }
    $pids7b = @(Get-Content -LiteralPath $halfPids -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d+$' })
    $alive7b = @($pids7b | Where-Object { (Test-Path -LiteralPath "/proc/$_/stat") -and ((Get-Content -Raw -LiteralPath "/proc/$_/stat" -ErrorAction SilentlyContinue) -notmatch '^\d+ \(.*\) Z') })
    Assert-That ($pids7b.Count -ge 2 -and $alive7b.Count -eq 0) "both commands that got no answer were stopped ($($pids7b.Count) started, $($alive7b.Count) still running)"

    Write-Host "`n=== 8. Open WebUI up, but unable to reach Ollama (the path chats take) ===" -ForegroundColor Cyan
    # A stand-in Open WebUI on the host network that answers /health on port 3998 and has python3
    # (SearXNG's image), so the watch probes Ollama from inside it as it would from the real one.
    $pyImage = Invoke-DockerText @('inspect', '-f', '{{.Config.Image}}', 'searxng')
    Invoke-DockerText @('rm', '-f', 'open-webui') | Out-Null
    # It answers {"status":true}, which is what Start again waits for from Open WebUI's /health. The
    # two quotes are written as \x22 for Python: no literal double quote goes to a native program.
    $srv = "import http.server as h;C=type('C',(h.BaseHTTPRequestHandler,),{'do_GET':lambda s:(s.send_response(200),s.end_headers(),s.wfile.write(b'{\x22status\x22:true}'))});h.HTTPServer(('127.0.0.1',3998),C).serve_forever()"
    # Labelled as a test container: if this suite is killed before 'finally', Reset-Sandbox removes it.
    Invoke-DockerText @('run', '-d', '--name', 'open-webui', '--label', 'lai-test=1', '--network', 'host', '--entrypoint', 'python3', $pyImage, '-c', $srv) | Out-Null
    $c7 = Read-LaiState -Path $cfgFile; $c7['WebUIPort'] = 3998; $c7['WebUIOllamaUrl'] = 'http://127.0.0.1:9'; Save-LaiState -State $c7 -Path $cfgFile
    $up = $false
    for ($i = 0; $i -lt 30 -and -not $up; $i++) { try { Invoke-LaiApi -Uri 'http://127.0.0.1:3998/health' -TimeoutSec 2 | Out-Null; $up = $true } catch { Start-Sleep -Seconds 1 } }
    Assert-That $up "setup: the stand-in Open WebUI answers on port 3998 ($(Get-State 'open-webui'))"
    # LOCALAI_DOCKER_TIMEOUT holds something that is no number for this run. The watch read it on every
    # run and stopped on the cast, before any check, log line or notification: one variable among the
    # owner's own, and no scheduled run did anything from then on. It does not read it any more.
    $ranCount = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -match ' (FAIL|OK)( |$)' -and $_ -notmatch ' NOTIFY' }).Count }
    $ran0 = & $ranCount
    $env:LOCALAI_DOCKER_TIMEOUT = 'x'
    try { $out7 = Invoke-Watch @('-NoHeal') } finally { $env:LOCALAI_DOCKER_TIMEOUT = '' }
    Assert-That ((& $ranCount) -eq $ran0 + 1) "with LOCALAI_DOCKER_TIMEOUT set to 'x' alone the run still does its checks and writes its line: that variable ends no run ($((& $ranCount) - $ran0) line(s); $(($out7 -split "`n")[0]))"
    $l7 = & $lastFail
    Assert-That ($l7 -match 'Chats reach Ollama \(Open WebUI cannot reach Ollama at http://127\.0\.0\.1:9 ') "Open WebUI answering but unable to reach Ollama is a failed check that names the URL ($l7)"
    $c7['WebUIOllamaUrl'] = 'http://127.0.0.1:11434'; Save-LaiState -State $c7 -Path $cfgFile
    Invoke-Watch @('-NoHeal') | Out-Null
    $l7 = & $lastFail
    Assert-That ($l7 -notmatch 'Chats reach Ollama') "and passes once Ollama answers at that URL ($l7)"
    # Start again against the same stand-in. It used to print OK as soon as /health answered. It now
    # runs the watch's probe itself and ends as failed, naming the address and the next step, when a
    # chat could not reach Ollama; the 'Open WebUI is up' line is not printed then.
    $upSaid = '\[OK\s*\] Open WebUI is up on '
    $c7['WebUIOllamaUrl'] = 'http://127.0.0.1:9'; Save-LaiState -State $c7 -Path $cfgFile
    $start8 = Invoke-Script 'Start-LocalAI.ps1' @('-TimeoutSec', '60')
    $fail8 = Get-LastLine $start8.Text '\[FAIL\] '
    Assert-That ($start8.Code -ne 0 -and $fail8 -match 'Local AI did not start: Open WebUI answers, but it cannot reach Ollama at http://127\.0\.0\.1:9, so chats would fail\. Restart Docker Desktop ' -and $start8.Text -notmatch $upSaid) ("Start again with an Open WebUI that cannot reach Ollama ends as failed, naming the address and restarting Docker Desktop, and does not say Open WebUI is up (exit {0}: {1})" -f $start8.Code, $fail8)
    $c7['WebUIOllamaUrl'] = 'http://127.0.0.1:11434'; Save-LaiState -State $c7 -Path $cfgFile
    $start8 = Invoke-Script 'Start-LocalAI.ps1' @('-TimeoutSec', '60')
    $fail8 = Get-LastLine $start8.Text '\[FAIL\] '
    Assert-That ($start8.Code -eq 0 -and $start8.Text -match 'Chats reach Ollama \(Open WebUI gets an answer from http://127\.0\.0\.1:11434\)' -and $start8.Text -match $upSaid) ("and ends well, saying that chats reach Ollama, once Ollama answers at that address (exit {0}; {1})" -f $start8.Code, $fail8)
    # The render guard is on the chat path unless Open WebUI was pointed past it. One that exists and
    # does not run (created only, here) fails Start again while the guard is in use (no address of
    # its own in the config), and is not looked at when Open WebUI talks to Ollama directly.
    Invoke-DockerText @('rm', '-f', 'render-guard') | Out-Null
    Invoke-DockerText @('create', '--name', 'render-guard', '--label', 'lai-test=1', 'alpine:3.20', 'sleep', '3600') | Out-Null
    try {
        Assert-That ((Get-State 'render-guard') -eq 'created') "setup: a render-guard container that exists and does not run ($(Get-State 'render-guard'))"
        $c7.Remove('WebUIOllamaUrl'); Save-LaiState -State $c7 -Path $cfgFile
        $start8 = Invoke-Script 'Start-LocalAI.ps1' @('-TimeoutSec', '60')
        $fail8 = Get-LastLine $start8.Text '\[FAIL\] '
        Assert-That ($start8.Code -ne 0 -and $fail8 -match 'Local AI did not start: Open WebUI answers, but the render guard, [^\n]* is not running \(Docker says: created\)[^\n]* Restart Docker Desktop ' -and $start8.Text -notmatch $upSaid) ("with the render guard in use and not running, Start again ends as failed and says so (exit {0}: {1})" -f $start8.Code, $fail8)
        $c7['WebUIOllamaUrl'] = 'http://127.0.0.1:11434'; Save-LaiState -State $c7 -Path $cfgFile
        $start8 = Invoke-Script 'Start-LocalAI.ps1' @('-TimeoutSec', '60')
        $fail8 = Get-LastLine $start8.Text '\[FAIL\] '
        Assert-That ($start8.Code -eq 0 -and $start8.Text -match $upSaid) ("with Open WebUI pointed past the render guard, the same container does not fail Start again (exit {0}; {1})" -f $start8.Code, $fail8)
    } finally {
        # 8b. below wants no render guard to judge and Ollama's own address for the chat path.
        Invoke-DockerText @('rm', '-f', 'render-guard') | Out-Null
        $c7['WebUIOllamaUrl'] = 'http://127.0.0.1:11434'; Save-LaiState -State $c7 -Path $cfgFile
    }

    Write-Host "`n=== 8b. Docker stops while Open WebUI is reported: nothing 'recovered' until its check ran and passed ===" -ForegroundColor Cyan
    # A docker CLI that answers at once that the engine is not running. With it nothing behind Docker
    # is looked at, and a check that did not run is not a check that passed: the Open WebUI reported
    # before must not be announced as recovered the moment Docker stops. The stand-in from 8. answers
    # again as soon as Docker does; a fresh backup and no disk limit leave nothing else to fail.
    $downDir = Join-Path $Work 'down-shim'
    New-Item -ItemType Directory -Force -Path $downDir | Out-Null
    Set-Content -LiteralPath (Join-Path $downDir 'docker') -Value "#!/bin/sh`nexit 1"
    & chmod +x (Join-Path $downDir 'docker')
    Set-Content -LiteralPath (Join-Path $bdir ('open-webui-{0}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Value 'x'
    $w8 = @('-NoHeal', '-MinFreeGB', '0')
    $notices8 = { param($Rx) @((Get-WatchLog) -split "`n" | Where-Object { $_ -match (' NOTIFY [^\n]*' + $Rx) }) }
    # Any notice that names something as working again ('partly recovered: recovered X', 'Working again: X').
    $againRx = '(recovered|Working again:) '
    Save-LaiState -State @{ failed = @('Open WebUI'); notified = @('Open WebUI'); notifiedAt = (Get-Date).ToString('s') } -Path $statePath
    $again0 = @(& $notices8 $againRx).Count
    $savedPATH = $env:PATH
    $env:PATH = $downDir + [System.IO.Path]::PathSeparator + $savedPATH
    try {
        Invoke-Watch $w8 | Out-Null
        $down1 = & $lastFail
        Invoke-Watch $w8 | Out-Null
    } finally { $env:PATH = $savedPATH }
    $ws8 = Read-LaiState -Path $statePath
    Assert-That ($down1 -match 'FAIL [^\n]*Docker \(engine not running' -and @(& $notices8 $againRx).Count -eq $again0) "Docker down for two runs: no notice calls anything recovered ($(@(& $notices8 $againRx).Count - $again0) such notice(s); first run: $down1)"
    Assert-That (@($ws8['notified']) -contains 'Docker' -and @($ws8['notified']) -contains 'Open WebUI') "Docker is reported on the second run, and Open WebUI, which could not be checked, stays reported (reported: $(@($ws8['notified']) -join ', '))"
    $downNotice = [string]@(& $notices8 'Local AI: problem detected: ')[-1]
    Assert-That ($downNotice -cmatch 'Docker \(engine not running - start Docker Desktop\)[^\n]*\. Use Start menu > Local AI - Start again\. If that does not help, restart Docker Desktop \(whale icon > Restart\) and use Start again once more\.') "for a Docker engine that is not running the next step is still Start again first ($downNotice)"
    $back0 = @(& $notices8 'Local AI: back to normal: ').Count
    Invoke-Watch $w8 | Out-Null
    $back = @(& $notices8 'Local AI: back to normal: ')
    $backLine = ''; if ($back.Count) { $backLine = [string]$back[-1] }
    $ws8 = Read-LaiState -Path $statePath
    Assert-That ($back.Count -eq $back0 + 1 -and $backLine -match 'recovered [^\n]*Docker' -and $backLine -match 'recovered [^\n]*Open WebUI') "Docker back and everything healthy: exactly one 'back to normal', naming Docker and Open WebUI ($($back.Count - $back0) notice(s): $backLine / $(& $lastFail))"
    Assert-That (@(@($ws8['notified']) | Where-Object { $_ }).Count -eq 0) "and nothing is left as reported ($(@($ws8['notified']) -join ', '))"
    # Everything is healthy here, so a disk without room and an emptied Open WebUI are the only two
    # problems and the next step is the one for the disk. It must not offer the old backups for
    # deletion in the very notice that says one of them holds the chats. The recorded backup is not
    # in the folder (pruned or moved since): the notice says so, with no restore command for it.
    $gone8 = 'open-webui-20251231-030000.tar.gz'
    $hadState8 = Test-Path -LiteralPath $bstatePath
    $bs8 = Read-LaiState -Path $bstatePath
    $bs8['emptied'] = @{ at = (Get-Date).ToString('s'); lastGood = $gone8; chats = 0; hadChats = 5 }
    Save-LaiState -State $bs8 -Path $bstatePath
    Invoke-Watch @('-NoHeal', '-MinFreeGB', '1000000') | Out-Null
    $full8 = [string]@(& $notices8 ('Local AI: problem detected: [^\n]*' + $emLead))[-1]
    if ($hadState8) { $bs8.Remove('emptied'); Save-LaiState -State $bs8 -Path $bstatePath } else { Remove-Item -LiteralPath $bstatePath -Force }
    Assert-That ($full8 -match 'Disk space \([^\n]*\. Free some disk space \(unused models\)\. Keep every backup in ' -and $full8 -notmatch 'old backups') "a disk without room next to an emptied Open WebUI: the next step frees space elsewhere and says to keep every backup ($full8)"
    Assert-That ($full8 -match ([regex]::Escape($gone8) + ', is not in ') -and $full8 -notmatch 'Restore-OpenWebUI|-Archive ') "and a recorded backup that is no longer in the backup folder gets no restore command ($full8)"
    Get-ChildItem -LiteralPath $bdir -File | Remove-Item -Force

    Write-Host "`n=== 9. a lasting problem is also a banner in Open WebUI; Windows' notification switch off ===" -ForegroundColor Cyan
    # The sandbox's real Open WebUI (port 3000). A banner the owner made must survive.
    Invoke-DockerText @('rm', '-f', 'open-webui') | Out-Null
    $c9 = Read-LaiState -Path $cfgFile; $c9['WebUIPort'] = 3000; $c9.Remove('WebUIOllamaUrl'); Save-LaiState -State $c9 -Path $cfgFile
    New-Item -ItemType Directory -Force -Path (Join-Path $aiRoot 'Secrets') | Out-Null
    ConvertTo-Json @{ email = 'admin@localhost'; password = 'Test-Password-123' } | Set-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Secrets') 'openwebui-admin.json')
    $wu = 'http://127.0.0.1:3000'
    # Backups is the one problem here: the sandbox's own free space must not add a second.
    $w9 = @('-NoHeal', '-MinFreeGB', '0')
    $tok9 = Connect-LaiWebUI -BaseUrl $wu -Email 'admin@localhost' -Password 'Test-Password-123'
    $bannersBefore = @(Invoke-LaiApi -Uri "$wu/api/v1/configs/banners" -Token $tok9 | Where-Object { $null -ne $_ })
    $own = [ordered]@{ id = 'owner-note'; type = 'info'; title = ''; content = 'my own banner'; dismissible = $true; timestamp = 1 }
    Invoke-LaiApi -Method POST -Uri "$wu/api/v1/configs/banners" -Token $tok9 -Body @{ banners = @($own) } | Out-Null
    $getBanners = { @(Invoke-LaiApi -Uri "$wu/api/v1/configs/banners" -Token $tok9 | Where-Object { $null -ne $_ }) }
    $bannerLines = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -match ' BANNER ' }).Count }
    try {
        Get-ChildItem -LiteralPath $bdir -File | Remove-Item -Force
        Save-LaiState -State @{ failed = @() } -Path $statePath
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $getBanners | Where-Object { $_.id -eq 'localai-health-watch' }).Count -eq 0) 'a problem seen once is not a banner yet (two strikes, as for the toast)'
        Invoke-Watch $w9 | Out-Null
        $b = @(& $getBanners)
        $mine = @($b | Where-Object { $_.id -eq 'localai-health-watch' })
        Assert-That ($mine.Count -eq 1 -and $mine[0].content -match 'not working: Backups' -and $mine[0].content -match 'backup\.log' -and $mine[0].type -eq 'warning') "seen twice: a warning banner names the problem and the next step ($(@($mine | ForEach-Object { $_.content }) -join ' | '))"
        Assert-That (@($b | Where-Object { $_.id -eq 'owner-note' -and $_.content -eq 'my own banner' }).Count -eq 1) 'the banner the owner made is kept'
        $n9 = & $bannerLines
        Invoke-Watch $w9 | Out-Null
        Assert-That ((& $bannerLines) -eq $n9) 'the same problems again: no new sign-in, no banner rewrite'
        # Windows has notifications off for PowerShell: recorded for the health check, not retried every run.
        Save-LaiState -State @{ failed = @('Backups'); notified = @(); banner = 'Backups' } -Path $statePath
        Invoke-Watch ($w9 + @('-TestToastSetting', 'DisabledForUser')) | Out-Null
        $ws9 = Read-LaiState -Path $statePath
        Assert-That ([string]$ws9['toastSetting'] -eq 'DisabledForUser' -and @($ws9['notified']) -contains 'Backups' -and (Get-WatchLog) -match 'toast not shown, notifications are off: DisabledForUser') 'a toast Windows drops (notifications off) is logged as such, counted as told (no retry every 15 minutes), and the switch is recorded'
        $hc = (& pwsh -NoProfile -File (Join-Path $src 'Test-LocalAI.ps1') -AIRoot $aiRoot -Quick 2>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-That ($hc -match 'Health watch[^\n]*notifications switched off for PowerShell \(DisabledForUser\)') 'the health check reports the switch'
        # Fixed: the banner goes, the owner's stays.
        Set-Content -LiteralPath (Join-Path $bdir ('open-webui-{0}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Value 'x'
        Invoke-Watch $w9 | Out-Null
        $b = @(& $getBanners)
        Assert-That (@($b | Where-Object { $_.id -eq 'localai-health-watch' }).Count -eq 0 -and @($b | Where-Object { $_.id -eq 'owner-note' }).Count -eq 1 -and -not (Read-LaiState -Path $statePath).ContainsKey('banner')) "fixed: the watch's banner is removed and the owner's kept ($(@($b | ForEach-Object { $_.id }) -join ', '))"
        # The health check: a watch that has not run for hours.
        $ws9 = Read-LaiState -Path $statePath; $ws9['checked'] = (Get-Date).AddHours(-5).ToString('s'); $ws9.Remove('toastSetting'); Save-LaiState -State $ws9 -Path $statePath
        $hc = (& pwsh -NoProfile -File (Join-Path $src 'Test-LocalAI.ps1') -AIRoot $aiRoot -Quick 2>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-That ($hc -match 'Health watch[^\n]*last check 5\.0 h ago') 'the health check notices a watch that stopped running'
    } finally {
        Invoke-LaiApi -Method POST -Uri "$wu/api/v1/configs/banners" -Token $tok9 -Body @{ banners = @($bannersBefore) } | Out-Null
    }

    Write-Host "`n=== 10. integrity watch: a change outside an install or update is named once; your own can be accepted ===" -ForegroundColor Cyan
    # Files and the routing settings of Stack\.env only: Linux has no Task Scheduler and no
    # Get-NetTCPConnection, so tasks and listeners are skipped here (the Windows unit tests run the
    # watch against real ones). The sandbox's real Open WebUI (port 3000, as in 9.) shows the banner.
    $igScripts = Join-Path $aiRoot 'Scripts'; $igStack = Join-Path $aiRoot 'Stack'
    foreach ($d in (Join-Path $igScripts 'lib'), (Join-Path $igScripts 'Secrets')) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $igTool = Join-Path $igScripts 'tool.ps1'; $igHelper = Join-Path (Join-Path $igScripts 'lib') 'helper.psm1'
    $igEnv = Join-Path $igStack '.env'
    Set-Content -LiteralPath $igTool -Value 'original'
    Set-Content -LiteralPath $igHelper -Value 'original'
    Set-Content -LiteralPath (Join-Path (Join-Path $igScripts 'Secrets') 'token.txt') -Value 'secret-1'
    Set-Content -LiteralPath $igEnv -Value @('OPEN_WEBUI_VERSION=v1', 'OLLAMA_UPSTREAM=http://host.docker.internal:11434')
    Set-Content -LiteralPath (Join-Path $igStack 'compose.log') -Value 'line 1'
    $igView = { $s = (Read-LaiState -Path $statePath)['integrity']; if ($s -is [hashtable]) { $s } else { @{} } }
    $igFound = { @((& $igView)['found'] | Where-Object { $_ -is [hashtable] } | ForEach-Object { [string]$_['Text'] }) }
    $igLog = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -cmatch ' INTEGRITY ' }) }
    # Only notifications that went out (a failed toast is logged as 'NOTIFY (toast failed) ...').
    $igNotices = { param($Title) @((Get-WatchLog) -split "`n" | Where-Object { $_ -match (' NOTIFY Local AI: ' + $Title) }) }
    $igChanged = { @(& $igNotices 'changed outside an update') }
    $igHourLater = { $s = Read-LaiState -Path $statePath; $s['integrity']['checkedAt'] = (Get-Date).AddMinutes(-61).ToString('s'); Save-LaiState -State $s -Path $statePath }
    # An hour later, then the run after it: the two looks a difference needs before it is announced.
    $igTwoLooks = { & $igHourLater; Invoke-Watch $w9 | Out-Null; Invoke-Watch $w9 | Out-Null }
    $igHealth = { @((& pwsh -NoProfile -File (Join-Path $src 'Test-LocalAI.ps1') -AIRoot $aiRoot -Quick 2>&1 | ForEach-Object { "$_" }) | Where-Object { $_ -match 'Integrity watch' }) -join "`n" }
    $tok10 = Connect-LaiWebUI -BaseUrl $wu -Email 'admin@localhost' -Password 'Test-Password-123'
    $igBanner = { @(Invoke-LaiApi -Uri "$wu/api/v1/configs/banners" -Token $tok10 | Where-Object { $null -ne $_ } | Where-Object { $_.id -eq 'localai-health-watch' -and $_.content -match 'changed since the last install or update' }) }
    try {
        Invoke-Watch $w9 | Out-Null
        Assert-That (-not (Read-LaiState -Path $statePath).ContainsKey('integrity') -and @(& $igLog).Count -eq 0) 'without a baseline nothing is compared, recorded or logged'
        $ig0 = Save-LaiIntegrityBaseline -AIRoot $aiRoot -Reason 'test'
        $igNames = @($ig0['files'].Keys)
        Assert-That ($igNames -contains 'Scripts\tool.ps1' -and $igNames -contains 'Scripts\lib\helper.psm1' -and $igNames -contains 'Stack\docker-compose.yml') "the baseline lists the files of Scripts and Stack ($(($igNames | Sort-Object) -join ', '))"
        Assert-That (@($igNames | Where-Object { $_ -match 'Secrets|\.env$|\.log$' }).Count -eq 0) 'but not .env, not logs, and nothing under a Secrets folder'
        Assert-That ($ig0['env'] -is [hashtable] -and @($ig0['env'].Keys).Count -eq 1 -and [string]$ig0['env']['OLLAMA_UPSTREAM'] -match '^[0-9A-F]{12}$' -and @($ig0['accepted']).Count -eq 0) "of .env only the setting that says where chats are sent is recorded, as a fingerprint and not as its value ($(@($ig0['env'].Keys) -join ', '))"
        Invoke-Watch $w9 | Out-Null
        Assert-That ([string](& $igView)['baseline'] -eq [string]$ig0['id'] -and @(& $igFound).Count -eq 0 -and @(& $igChanged).Count -eq 0 -and @(& $igNotices 'integrity baseline accepted').Count -eq 0) 'the first look after the baseline: nothing differs, nothing is announced'
        # What changes in normal use is left alone.
        Set-Content -LiteralPath $igEnv -Value @('OPEN_WEBUI_VERSION=v2', 'OLLAMA_UPSTREAM=http://host.docker.internal:11434', 'WEBUI_EXTRA_ORIGINS=;https://pc.tail.ts.net')
        Add-Content -LiteralPath (Join-Path $igStack 'compose.log') -Value 'line 2'
        Set-Content -LiteralPath (Join-Path (Join-Path $igScripts 'Secrets') 'token.txt') -Value 'secret-2'
        & $igHourLater
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $igFound).Count -eq 0 -and @(& $igLog).Count -eq 0) "an hour later: another Open WebUI version and the Tailscale origin in .env, a grown log and a changed file under Secrets are not differences ($(@(& $igFound) -join '; '))"
        # A script changed outside an update: not hashed on every run, then two strikes, then told once.
        Set-Content -LiteralPath $igTool -Value 'changed outside an update'
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $igFound).Count -eq 0) 'a changed script is not looked for on the very next run (files are hashed about once an hour, not every 15 minutes)'
        & $igHourLater
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $igFound) -contains '"Scripts\tool.ps1" was changed' -and @((& $igView)['pending'] | Where-Object { $_ }).Count -eq 1 -and @(& $igChanged).Count -eq 0) "an hour later it is seen and recorded, not announced yet ($(@(& $igFound) -join '; '))"
        Assert-That (@(& $igLog | Where-Object { $_ -match '1 difference\(s\) from the baseline: "Scripts\\tool\.ps1" was changed' }).Count -eq 1) 'and watch.log names it'
        # The file is rewritten between the two looks (an editor that saves again, a program that keeps
        # writing it): still the same difference, so the second look announces it. Here that
        # notification fails once, and is tried again.
        Set-Content -LiteralPath $igTool -Value 'rewritten before the second look'
        Invoke-Watch ($w9 + @('-TestToastFail')) | Out-Null
        $igFailed = @((Get-WatchLog) -split "`n" | Where-Object { $_ -match 'NOTIFY \(toast failed\) Local AI: changed outside an update' })
        Assert-That ($igFailed.Count -eq 1 -and @((& $igView)['told'] | Where-Object { $_ }).Count -eq 0 -and @((& $igView)['pending'] | Where-Object { $_ }).Count -eq 1 -and @(& $igBanner).Count -eq 0) "seen again with other content: announced all the same; that notification failed, so it is not counted as told and kept for the next run ($($igFailed.Count) tried)"
        Set-Content -LiteralPath $igTool -Value 'and rewritten once more'
        Invoke-Watch $w9 | Out-Null
        $n10 = @(& $igChanged)
        Assert-That ($n10.Count -eq 1 -and $n10[0] -match '"Scripts\\tool\.ps1" was changed' -and $n10[0] -match 'If you did not do this') "the next run announces it once, although the file was rewritten before every look ($($n10 -join ' | '))"
        # At that moment the advice must not send the owner to the scripts that were just reported.
        Assert-That ($n10.Count -eq 1 -and $n10[0] -notmatch 'Start menu|Health check|Update toolkit' -and $n10[0] -match 'do not use the Local AI shortcuts' -and $n10[0] -match 'Logs\\watch\.log' -and $n10[0] -match 'fresh copy of the toolkit') 'for a changed script no shortcut is named (each starts a script from that folder, Update toolkit then asks for administrator rights): watch.log and a fresh copy are'
        $b10 = @(& $igBanner)
        Assert-That ($b10.Count -eq 1 -and $b10[0].content -match 'changed since the last install or update: `Scripts\\tool\.ps1` was changed' -and $b10[0].content -notmatch 'Health check|Update toolkit') "and it is on the Open WebUI banner, the name shown as code, with the same advice ($(@($b10 | ForEach-Object { $_.content }) -join ' | '))"
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'WARN Integrity watch: 1 change\(s\) since the baseline of [^\n]*"Scripts\\tool\.ps1" was changed[^\n]*do not repair this with Update toolkit[^\n]*fresh copy[^\n]*-AcceptBaseline' -and $hc10 -notmatch 'Start menu > Local AI - Update toolkit') 'the health check lists the change, does not offer Update toolkit for a changed script, and says how to accept it'
        # The installer runs the health check itself, before it records its new baseline, holding the
        # setup lock in that same process (where the lock reads as free: a mutex lets its owner in
        # again). It must not tell the owner to accept a change the update is just undoing.
        $igInScript = Join-Path $Work 'health-in-installer.ps1'
        Set-Content -LiteralPath $igInScript -Value ("Import-Module '{0}' -Force; `$SetupLock = Enter-LaiSetupLock; & '{1}' -AIRoot '{2}' -Quick" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'), (Join-Path $src 'Test-LocalAI.ps1'), $aiRoot)
        $hcIn = @((& pwsh -NoProfile -File $igInScript 2>&1 | ForEach-Object { "$_" }) | Where-Object { $_ -match 'Integrity watch' }) -join "`n"
        Assert-That ($hcIn -match 'SKIP Integrity watch: an install, update or model update is running' -and $hcIn -notmatch 'AcceptBaseline|tool\.ps1') "called by the installer (which holds the setup lock itself), the health check lists no old findings and offers no -AcceptBaseline ($hcIn)"
        # Told, and rewritten again the same day: no second notice, and nothing waits for a second look,
        # so the files are not hashed on every run.
        Set-Content -LiteralPath $igTool -Value 'a script that keeps being rewritten'
        & $igHourLater
        Invoke-Watch $w9 | Out-Null
        $igAt = [string](& $igView)['checkedAt']
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $igChanged).Count -eq 1 -and @((& $igView)['pending'] | Where-Object { $_ }).Count -eq 0 -and [string](& $igView)['checkedAt'] -eq $igAt) 'rewritten again after it was told: no second notice the same day, and the run after it does not compare again'
        # More changes: told together, without repeating the one already told. One new file has a name
        # made to look like a link.
        Set-Content -LiteralPath (Join-Path $igStack 'extra.yml') -Value 'services: {}'
        Set-Content -LiteralPath (Join-Path $igStack 'x [open](www.example.org).yml') -Value 'x'
        Remove-Item -LiteralPath $igHelper -Force
        & $igTwoLooks
        $n10 = @(& $igChanged)
        Assert-That ($n10.Count -eq 2 -and $n10[-1] -match '"Stack\\extra\.yml" is new' -and $n10[-1] -match '"Scripts\\lib\\helper\.psm1" is gone' -and $n10[-1] -notmatch 'tool\.ps1') "new and deleted files are announced together, once; what was told is not repeated ($($n10[-1]))"
        $b10 = @(& $igBanner)
        Assert-That ($b10.Count -eq 1 -and $b10[0].content -match '`Stack\\x \?open\?\?www\.example\.org\?\.yml` is new' -and $b10[0].content -notmatch '\]\(') "a file name cannot put a link on the banner every Open WebUI user sees: it is cleaned and shown as code ($(@($b10 | ForEach-Object { $_.content }) -join ' | '))"
        # Where chats are sent is one line in .env: watched by its name, its value never shown.
        Set-Content -LiteralPath $igEnv -Value @('OPEN_WEBUI_VERSION=v2', 'OLLAMA_UPSTREAM=http://elsewhere.example:11434')
        & $igTwoLooks
        $n10 = @(& $igChanged)
        Assert-That ($n10.Count -eq 3 -and $n10[-1] -match 'the setting "OLLAMA_UPSTREAM" in Stack\\\.env was changed' -and $n10[-1] -notmatch 'elsewhere' -and $n10[-1] -match 'Start menu > Local AI - Health check') "a changed Ollama address in .env is announced by the name of the setting, without its value; no script is part of this notice, so the shortcut is named ($($n10[-1]))"
        # An archive unpacked into the wrong folder: 210 new files in 21 new folders, and 25 in one more.
        foreach ($i in 1..21) {
            $bulk = Join-Path $igStack ('bulk{0:D2}' -f $i)
            New-Item -ItemType Directory -Force -Path $bulk | Out-Null
            foreach ($j in 1..10) { Set-Content -LiteralPath (Join-Path $bulk "f$j.txt") -Value "$i-$j" }
        }
        $igUnpacked = Join-Path $igStack 'unpacked'
        New-Item -ItemType Directory -Force -Path $igUnpacked | Out-Null
        foreach ($j in 1..25) { Set-Content -LiteralPath (Join-Path $igUnpacked "u$j.txt") -Value "$j" }
        & $igTwoLooks
        Invoke-Watch $w9 | Out-Null
        $n10 = @(& $igChanged)
        $igToldNow = @((& $igView)['told'] | Where-Object { $_ -is [hashtable] })
        Assert-That ($n10.Count -eq 4 -and $igToldNow.Count -ge 211 -and @((& $igView)['pending'] | Where-Object { $_ }).Count -eq 0) "more than 200 differences at once: one notice over three runs, and none of them is announced again by the run after it ($($n10.Count) notices, $($igToldNow.Count) told)"
        Assert-That (@(& $igFound) -contains '25 new files in "Stack\unpacked"' -and @(& $igFound | Where-Object { $_ -like '*unpacked\u*' }).Count -eq 0) 'more than 20 new files in one new folder are one line with a count'
        # An installer log proves no work (every run writes one, also a run that was refused because
        # another one was going): it does not change the notice.
        Set-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Logs') ('install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Value 'a run that was refused'
        Set-Content -LiteralPath (Join-Path $igStack 'more1.yml') -Value 'x'
        & $igTwoLooks
        $n10 = @(& $igChanged)
        Assert-That ($n10.Count -eq 5 -and $n10[-1] -match '"Stack\\more1\.yml" is new' -and $n10[-1] -notmatch 'not finished') "an installer log dated after the baseline does not turn a change into an unfinished update ($($n10[-1]))"
        # The installer finished a stage after the baseline and recorded no new one (it failed, or waits
        # for a restart): one added sentence. The title and the warning stay as they are.
        Save-LaiState -State @{ stages = @{ Stack = (Get-Date).ToString('s') } } -Path $instPath
        Set-Content -LiteralPath (Join-Path $igStack 'more2.yml') -Value 'x'
        & $igTwoLooks
        Remove-Item -LiteralPath $instPath -Force
        $n10 = @(& $igChanged)
        Assert-That ($n10.Count -eq 6 -and $n10[-1] -match '"Stack\\more2\.yml" is new' -and $n10[-1] -match 'If you did not do this' -and $n10[-1] -match 'has not finished: if these are its changes' -and @(& $igNotices 'update not finished').Count -eq 0) "an install that got somewhere after the baseline and did not finish is one added sentence; it replaces neither the title nor the warning ($($n10[-1]))"
        # While an installer run or a model update holds the setup lock, files are being replaced:
        # nothing is compared and the last result is kept. That is said: once in watch.log, in the
        # health check, and with one notification when it lasts for hours.
        Set-Content -LiteralPath $holdScript -Value ("Import-Module '{0}' -Force; `$l = Enter-LaiSetupLock; Start-Sleep -Seconds 600; Exit-LaiVolumeLock `$l" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'))
        $holder = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $holdScript) -PassThru
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-LaiSetupLockBusy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        Assert-That (Test-LaiSetupLockBusy) 'setup: another process holds the setup lock'
        Set-Content -LiteralPath (Join-Path $igStack 'more3.yml') -Value 'x'
        & $igHourLater
        $igBefore = & $igView
        Invoke-Watch $w9 | Out-Null
        Invoke-Watch $w9 | Out-Null
        $igDuring = & $igView
        $igSkipLines = @(& $igLog | Where-Object { $_ -match 'INTEGRITY not compared: an install or a model update is running' })
        Assert-That ([string]$igDuring['checkedAt'] -eq [string]$igBefore['checkedAt'] -and @($igDuring['found']).Count -eq @($igBefore['found']).Count -and @(& $igFound) -notcontains '"Stack\more3.yml" is new' -and [string]$igDuring['skippedWhy'] -match 'an install or a model update is running' -and $igSkipLines.Count -eq 1) "while the setup lock is held nothing is compared: the last result stays as it was, and watch.log says so once over two runs ($($igSkipLines.Count) line(s))"
        # During an install the watch's findings against the old baseline are no advice to act on.
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'SKIP Integrity watch: an install, update or model update is running' -and $hc10 -notmatch 'AcceptBaseline|change\(s\) since') "while the lock is held the health check does not list old findings or offer to accept them ($hc10)"
        $s10 = Read-LaiState -Path $statePath; $s10['integrity']['skippedSince'] = (Get-Date).AddHours(-7).ToString('s'); Save-LaiState -State $s10 -Path $statePath
        Invoke-Watch $w9 | Out-Null
        Invoke-Watch $w9 | Out-Null
        # Any program can hold that lock: held for hours, it no longer hides the result.
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'WARN Integrity watch: [^\n]*the comparison is not running \(an install or a model update is running') 'a lock held for hours: the health check shows the result again and says that it is an old one'
        $igUnchecked = @(& $igNotices 'changes are not being checked')
        Assert-That ($igUnchecked.Count -eq 1 -and $igUnchecked[0] -match 'have not been compared with the baseline since') "a comparison kept from running for hours is announced, once over two runs ($($igUnchecked -join ' | '))"
        if (-not $holder.HasExited) { $holder.Kill() }
        $deadline = (Get-Date).AddSeconds(30)
        while ((Test-LaiSetupLockBusy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        Invoke-Watch $w9 | Out-Null
        $igAfter = & $igView
        Assert-That (@(& $igFound) -contains '"Stack\more3.yml" is new' -and -not $igAfter['skippedWhy'] -and -not $igAfter['skippedSince'] -and [string]$igAfter['checkedAt'] -ne [string]$igBefore['checkedAt']) 'once the lock is free the next run compares again and sees the change made meanwhile'
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $igChanged).Count -eq 7) 'and announces it on the run after'
        # The owner accepts the current state.
        $acc10 = Invoke-Watch @('-AcceptBaseline')
        Assert-That ($acc10 -match 'integrity baseline accepted' -and $acc10 -match 'accepted: "Stack\\extra\.yml" is new' -and $acc10 -match 'confirms this with a notification' -and [string](Read-LaiIntegrityBaseline -AIRoot $aiRoot)['id'] -ne [string]$ig0['id']) "-AcceptBaseline records the current state as the new baseline and lists what it accepted ($(($acc10 -split "`n" | Select-Object -Last 2) -join ' / '))"
        # More than 200 changes at once: the command prints the first 50 and counts the rest, while
        # the baseline keeps every name (the next baseline carries on what nobody has settled, and
        # cannot carry what was cut from the list).
        $igAccLines = @($acc10 -split "`n" | Where-Object { $_ -match 'accepted: "' })
        $igAccKept = @((Read-LaiIntegrityBaseline -AIRoot $aiRoot)['accepted'] | Where-Object { $_ -is [hashtable] }).Count
        Assert-That ($igAccLines.Count -eq 50 -and $acc10 -match 'accepted: and \d+ more' -and $igAccKept -gt 200) "it prints 50 of them by name and says how many more; the baseline lists them all ($($igAccLines.Count) printed, $igAccKept listed)"
        Invoke-Watch $w9 | Out-Null
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $igFound).Count -eq 0 -and [string](& $igView)['checkedAt'] -and @(& $igBanner).Count -eq 0 -and @(& $igChanged).Count -eq 7) 'after that nothing differs any more, and the banner is gone'
        # Anything running as the owner can paste that command. So the acceptance itself is news, once.
        $igAcc = @(& $igNotices 'integrity baseline accepted')
        Assert-That ($igAcc.Count -eq 1 -and $igAcc[0] -match 'recorded by hand \(Watch-LocalAI\.ps1 -AcceptBaseline\), so \d+ change\(s\) now count as normal: "Scripts\\tool\.ps1" was changed' -and $igAcc[0] -match 'If that was not you') "the next scheduled run names what was accepted in a notification, once over two runs: an acceptance the owner did not make is seen ($($igAcc -join ' | '))"
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'PASS Integrity watch: nothing changed since the baseline of [^\n]*recorded by hand \(-AcceptBaseline\), which made \d+ change\(s\) count as normal: "Scripts\\tool\.ps1" was changed') 'and the health check keeps showing how that baseline came about'
        # A comparison that was started and did not finish (Task Scheduler ends the run after ten
        # minutes) leaves its mark, and the next runs do not start it again for an hour.
        & $igHourLater
        $s10 = Read-LaiState -Path $statePath; $s10['integrity']['startedAt'] = (Get-Date).AddMinutes(-5).ToString('s'); Save-LaiState -State $s10 -Path $statePath
        $igBeforeStuck = & $igView
        Invoke-Watch $w9 | Out-Null
        Invoke-Watch $w9 | Out-Null
        $igStuck = & $igView
        $igStuckLines = @(& $igLog | Where-Object { $_ -match 'INTEGRITY not compared: the comparison started at \d\d:\d\d did not finish' })
        Assert-That ([string]$igStuck['checkedAt'] -eq [string]$igBeforeStuck['checkedAt'] -and [string]$igStuck['startedAt'] -and [string]$igStuck['skippedWhy'] -match 'did not finish' -and $igStuckLines.Count -eq 1) "a comparison that was started minutes ago and did not finish is not started again on every run, and watch.log says so once over two runs ($($igStuckLines.Count) line(s))"
        # An update records a new baseline too, and with it whatever else is there. What the installer
        # did not put there itself is named: its own copy of tool.ps1 is not, a file next to it is.
        $igSource = Join-Path $Work 'ig-source'
        New-Item -ItemType Directory -Force -Path $igSource | Out-Null
        Set-Content -LiteralPath (Join-Path $igSource 'tool.ps1') -Value 'the new version'
        Copy-Item -LiteralPath (Join-Path $igSource 'tool.ps1') -Destination $igTool -Force
        Set-Content -LiteralPath (Join-Path $igStack 'planted.yml') -Value 'x'
        $ig2 = Save-LaiIntegrityBaseline -AIRoot $aiRoot -Reason 'install' -SourceRoot $igSource
        $igKept = @($ig2['accepted'] | ForEach-Object { [string]$_['Text'] })
        Assert-That ($igKept.Count -eq 1 -and $igKept[0] -eq '"Stack\planted.yml" is new') "a baseline recorded by an install lists what it took in that the installer did not put there, and none of the installer's own files ($($igKept -join '; '))"
        # The watch's record still belongs to the baseline before (the one recorded by hand) and
        # holds its reason, 'the comparison started at ... did not finish'. That reason says nothing
        # about the new baseline, so the health check must not show it.
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'WARN Integrity watch: [^\n]*on its next run' -and $hc10 -notmatch 'the comparison is not running|did not finish') "the stale-reason case: right after an install the health check does not show the reason the watch recorded under the baseline before ($hc10)"
        # The first run that sees the new baseline says what it kept, starts the comparison, and is
        # ended in the middle of it (Task Scheduler ends the task after ten minutes). The mark it
        # leaves has to sit in the record of the baseline it compares with, together with what was
        # just announced: left in the record of the baseline before, the next run would drop it with
        # that record, announce the same things again and start the same comparison again.
        # The hook that ends the run is a parameter of that one run (-TestIntegrityEnd), which the
        # scheduled task never passes; the mark names it as what ended the run. It used to be an
        # environment variable, which any program running as the owner could set for good.
        $igOldId = [string](& $igView)['baseline']
        Invoke-Watch ($w9 + @('-TestIntegrityEnd')) | Out-Null
        $igEnded = & $igView
        Assert-That ($igOldId -and $igOldId -ne [string]$ig2['id'] -and [string]$igEnded['baseline'] -eq [string]$ig2['id'] -and [string]$igEnded['startedAt'] -and [string]$igEnded['announced'] -eq [string]$ig2['id'] -and -not $igEnded['checkedAt']) "a run ended in the middle of the first comparison with a new baseline leaves its mark under that baseline, with what it had announced (baseline $([string]$igEnded['baseline']), started $([string]$igEnded['startedAt']))"
        Assert-That ([string]$igEnded['tried'] -eq [string]$ig2['id']) "and with the word that the watch has had its turn with that baseline's list (tried $([string]$igEnded['tried']))"
        Invoke-Watch $w9 | Out-Null
        Invoke-Watch $w9 | Out-Null
        $igAfterEnd = & $igView
        $igEndLines = @(& $igLog | Where-Object { $_ -match 'INTEGRITY not compared: [^\n]*-TestIntegrityEnd' })
        Assert-That (-not $igAfterEnd['checkedAt'] -and [string]$igAfterEnd['startedAt'] -eq [string]$igEnded['startedAt'] -and [string]$igAfterEnd['announced'] -eq [string]$ig2['id'] -and @(& $igNotices 'the update kept changes it did not make').Count -eq 1) "the two runs after it do not start that comparison again and do not announce again what the update kept ($(@(& $igNotices 'the update kept changes it did not make').Count) notice(s))"
        Assert-That ([string]$igAfterEnd['skippedWhy'] -match '-TestIntegrityEnd' -and [string]$igAfterEnd['skippedWhy'] -match 'the scheduled task never passes it' -and $igEndLines.Count -eq 1) "what ended it is named, for the health check and the notice after hours, and once in watch.log over two runs: the test parameter, not an installer window ($($igEndLines.Count) line(s): $([string]$igAfterEnd['skippedWhy']))"
        # Now the watch's record carries the new baseline's own id, and no comparison has finished
        # under it: the health check gives the reason instead of 'on its next run'.
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'WARN Integrity watch: [^\n]*has not compared the PC with it yet: the comparison is not running \([^\n]*-TestIntegrityEnd[^\n]*kept 1 thing\(s\) it did not install' -and $hc10 -notmatch 'on its next run') "a comparison that never finished under the new baseline: the health check says why ($hc10)"
        # Hours later the notice names the parameter and gives no advice made for the setup lock: closing
        # an installer window or restarting the PC changes nothing about what starts the watch with it.
        $s10 = Read-LaiState -Path $statePath; $s10['integrity']['skippedSince'] = (Get-Date).AddHours(-7).ToString('s'); Save-LaiState -State $s10 -Path $statePath
        Invoke-Watch $w9 | Out-Null
        $igHookNotices = @(& $igNotices 'changes are not being checked')
        $igHookNotice = ''; if ($igHookNotices.Count) { $igHookNotice = [string]$igHookNotices[-1] }
        Assert-That ($igHookNotices.Count -eq $igUnchecked.Count + 1 -and $igHookNotice -match '-TestIntegrityEnd' -and $igHookNotice -notmatch 'installer window|restart the PC') "the notice for a comparison ended by the test hook names the parameter and does not send the owner to an installer window or a restart ($igHookNotice)"
        Assert-That ($igUnchecked[0] -match 'close an installer window that is still open or restart the PC') "while the setup lock is held the notice does carry that advice ($($igUnchecked -join ' | '))"
        # An hour after it was started the comparison is tried again, and this time it finishes. The
        # variable that used to end it is set for this run, to the id of the baseline in use: what a
        # program running as the owner could read from the baseline file and leave set for good, so
        # that no comparison ran again. Alone it ends nothing any more.
        $s10 = Read-LaiState -Path $statePath; $s10['integrity']['startedAt'] = (Get-Date).AddMinutes(-61).ToString('s'); Save-LaiState -State $s10 -Path $statePath
        $igInUse = [string](Read-LaiIntegrityBaseline -AIRoot $aiRoot)['id']
        $env:LOCALAI_TEST_INTEGRITY_END = $igInUse
        try { Invoke-Watch $w9 | Out-Null } finally { $env:LOCALAI_TEST_INTEGRITY_END = '' }
        Assert-That ($igInUse -and $igInUse -eq [string](& $igView)['baseline'] -and [string](& $igView)['checkedAt'] -and -not (& $igView)['startedAt'] -and -not (& $igView)['skippedWhy']) "an hour later it is started again, and finishes, also with LOCALAI_TEST_INTEGRITY_END set to the id of the baseline in use: that variable alone ends no comparison (baseline $igInUse)"
        Invoke-Watch $w9 | Out-Null
        $igKeptNotice = @(& $igNotices 'the update kept changes it did not make')
        Assert-That ($igKeptNotice.Count -eq 1 -and $igKeptNotice[0] -match '"Stack\\planted\.yml" is new' -and $igKeptNotice[0] -match 'If you did not add them' -and @(& $igFound).Count -eq 0) "the watch says so once: an addition does not drop out of every report because an update ran ($($igKeptNotice -join ' | '))"
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'WARN Integrity watch: [^\n]*kept 1 thing\(s\) it did not install, which now count as normal: "Stack\\planted\.yml" is new[^\n]*first remove what was added') 'and the health check keeps warning, with the order that works: remove it first, because Update toolkit keeps what it finds'
        # The mark of an ended run once more, for a baseline recorded by hand. -AcceptBaseline itself
        # puts the new baseline's id into the watch's record, so the first run after it writes its
        # mark into a record that already carries that id. What the run had just announced has to go
        # into the mark there as well, or the next run sends the same notification a second time.
        Set-Content -LiteralPath (Join-Path $igStack 'mine.yml') -Value 'x'
        Invoke-Watch @('-AcceptBaseline') | Out-Null
        $ig3Id = [string](Read-LaiIntegrityBaseline -AIRoot $aiRoot)['id']
        $igAccBefore = @(& $igNotices 'integrity baseline accepted').Count
        Invoke-Watch ($w9 + @('-TestIntegrityEnd')) | Out-Null
        $igEndedHand = & $igView
        Invoke-Watch $w9 | Out-Null
        $igAccNow = @(& $igNotices 'integrity baseline accepted')
        Assert-That ($ig3Id -and [string]$igEndedHand['baseline'] -eq $ig3Id -and [string]$igEndedHand['startedAt'] -and -not $igEndedHand['checkedAt'] -and [string]$igEndedHand['announced'] -eq $ig3Id) "the first run after -AcceptBaseline, ended in the middle of its comparison, leaves what it had announced in its mark (announced $([string]$igEndedHand['announced']))"
        Assert-That ($igAccNow.Count -eq $igAccBefore + 1 -and $igAccNow[-1] -match '"Stack\\mine\.yml" is new') "so the run after it does not send 'integrity baseline accepted' a second time ($($igAccNow.Count - $igAccBefore) notice(s))"
        # An update keeps another planted file, and before the watch's next run the acceptance command
        # runs twice (anything running as the owner can paste it). The first acceptance settles what
        # the update had kept; the second must still list it, or it records an empty list, the watch
        # has nothing to announce, and the file has left every report without being in a notice.
        Set-Content -LiteralPath (Join-Path $igStack 'planted2.yml') -Value 'x'
        $ig4 = Save-LaiIntegrityBaseline -AIRoot $aiRoot -Reason 'install' -SourceRoot $igSource
        $igTwice1 = Invoke-Watch @('-AcceptBaseline')
        $igTwice2 = Invoke-Watch @('-AcceptBaseline')
        $ig5 = Read-LaiIntegrityBaseline -AIRoot $aiRoot
        $igTwiceKept = @($ig5['accepted'] | Where-Object { $_ -is [hashtable] -and [string]$_['Id'] -eq 'file+|Stack\planted2.yml' })
        Assert-That (@($ig4['accepted']).Count -eq 1 -and $igTwice1 -match 'accepted: "Stack\\planted2\.yml" is new' -and $igTwice2 -match 'accepted: "Stack\\planted2\.yml" is new' -and $igTwiceKept.Count -eq 1 -and $igTwiceKept[0]['Settled']) "-AcceptBaseline run twice before the watch's next run: the second baseline still lists what the update had kept, marked as settled ($(@($ig5['accepted'] | ForEach-Object { [string]$_['Text'] }) -join '; '))"
        # The watch has its turn with that baseline: the list goes to watch.log and into a
        # notification. Here the notification fails, as on a PC where none ever goes out.
        Invoke-Watch ($w9 + @('-TestToastFail')) | Out-Null
        $igTurn = & $igView
        $igTurnFailed = @((Get-WatchLog) -split "`n" | Where-Object { $_ -match 'NOTIFY \(toast failed\) Local AI: integrity baseline accepted' })
        $igTurnLog = @(& $igLog | Where-Object { $_ -match 'INTEGRITY the baseline[^\n]* took in 1: "Stack\\planted2\.yml" is new' })
        Assert-That ($igTurnFailed.Count -eq 1 -and $igTurnFailed[0] -match '"Stack\\planted2\.yml" is new' -and $igTurnLog.Count -eq 1) "the watch's notice of that baseline names the planted file, and so does watch.log ($($igTurnFailed.Count) notice(s) tried, $($igTurnLog.Count) line(s))"
        Assert-That ([string]$igTurn['tried'] -eq [string]$ig5['id'] -and [string]$igTurn['announced'] -ne [string]$ig5['id'] -and [string]$igTurn['checkedAt']) "the notification failed: the watch records that it has had its turn with that baseline, not that the owner was told (tried $([string]$igTurn['tried']), announced '$([string]$igTurn['announced'])')"
        # After that turn the settled entry is done with: a PC where no notification ever goes out
        # does not list it at every acceptance and every update for good.
        $igThrice = Invoke-Watch @('-AcceptBaseline')
        $ig6 = Read-LaiIntegrityBaseline -AIRoot $aiRoot
        Assert-That ([string]$ig6['id'] -ne [string]$ig5['id'] -and @($ig6['accepted'] | Where-Object { $_ -is [hashtable] }).Count -eq 0 -and $igThrice -notmatch 'accepted: "') "the next acceptance does not list it again, although no notification went out ($(@($ig6['accepted'] | ForEach-Object { [string]$_['Text'] }) -join '; '))"
        # An update keeps a planted file, the owner accepts it by hand, and another update follows
        # before the watch's next run. That update carries on what the acceptance settled: the
        # health check must not call it kept by the update, and must end in the command to paste.
        Set-Content -LiteralPath (Join-Path $igStack 'planted3.yml') -Value 'x'
        Save-LaiIntegrityBaseline -AIRoot $aiRoot -Reason 'install' -SourceRoot $igSource | Out-Null
        Invoke-Watch @('-AcceptBaseline') | Out-Null
        $ig7 = Save-LaiIntegrityBaseline -AIRoot $aiRoot -Reason 'install' -SourceRoot $igSource
        $ig7Taken = @($ig7['accepted'] | Where-Object { $_ -is [hashtable] })
        Assert-That ($ig7Taken.Count -eq 1 -and $ig7Taken[0]['Settled'] -and [string]$ig7Taken[0]['Id'] -eq 'file+|Stack\planted3.yml') 'setup: an update right after an acceptance carries on what that settled, marked as settled'
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'WARN Integrity watch: [^\n]*on its next run\. That install or update carried on 1 thing\(s\) already accepted by hand \(-AcceptBaseline\), which still count as normal: "Stack\\planted3\.yml" is new\. If that acceptance was not yours, first remove what was added[^\n]*If it was, this goes away with: [^\n]*-AcceptBaseline' -and $hc10 -notmatch 'kept \d+ thing\(s\) it did not install') "what an acceptance settled and an update carried on is not called kept by the update, and the line says what ends it ($hc10)"
        # One more planted file and one more update: both kinds in one baseline.
        Set-Content -LiteralPath (Join-Path $igStack 'planted4.yml') -Value 'x'
        Save-LaiIntegrityBaseline -AIRoot $aiRoot -Reason 'install' -SourceRoot $igSource | Out-Null
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'carried on 1 thing\(s\) already accepted by hand \(-AcceptBaseline\), which still count as normal: "Stack\\planted3\.yml" is new\. It also kept 1 thing\(s\) it did not install, which now count as normal: "Stack\\planted4\.yml" is new\. That is 2 in all\. If that acceptance was not yours, or you did not add what was kept, first remove what was added[^\n]*If both were you, this goes away with: ' -and [regex]::Matches($hc10, 'first remove what was added').Count -eq 1 -and [regex]::Matches($hc10, 'this goes away with: ').Count -eq 1) "both kinds in one baseline: a sentence each, the number in all, the advice and the command once ($hc10)"
        # The baseline itself removed: that is a change, too.
        Remove-Item -LiteralPath (Get-LaiIntegrityPath -AIRoot $aiRoot) -Force
        & $igTwoLooks
        $n10 = @(& $igChanged)
        Assert-That ($n10.Count -eq 8 -and $n10[-1] -match 'the baseline itself \("[^"]*integrity-baseline\.json"\) is gone' -and $n10[-1] -notmatch 'Start menu|Health check') "a baseline that disappears is announced, without sending the owner to the installed scripts ($($n10[-1]))"
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'WARN Integrity watch: the baseline [^\n]*is gone or cannot be read') 'and the health check does not call that "no baseline yet"'
    } finally {
        if ($holder -and -not $holder.HasExited) { $holder.Kill() }
        Set-LaiWebUIBanner -BaseUrl $wu -Token $tok10 -Clear | Out-Null
    }
} finally {
    if ($holder -and -not $holder.HasExited) { $holder.Kill() }
    $tc = Join-Path (Join-Path $aiRoot 'Stack') 'docker-compose.yml'
    if (Test-Path -LiteralPath $tc) { Invoke-DockerText @('compose', '--project-directory', (Join-Path $aiRoot 'Stack'), '-f', $tc, 'down') | Out-Null }
    Invoke-DockerText @('rm', '-f', 'open-webui') | Out-Null
    Invoke-DockerText @('rm', '-f', 'deep-research') | Out-Null
    if ((Get-State 'searxng') -ne 'running') { Invoke-DockerText @('start', 'searxng') | Out-Null }
}

if ($failures -eq 0) { Write-Host "`nWATCH TEST PASSED" -ForegroundColor Green } else { Write-Host "`nWATCH TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
