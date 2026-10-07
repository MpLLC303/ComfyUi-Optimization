<#
.SYNOPSIS
    Watch-LocalAI.ps1 against real containers: it heals a stopped SearXNG, leaves Open WebUI alone
    while another process holds the volume lock (a backup/restore/update), and does nothing while
    paused.

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
    Set-Content -LiteralPath $holdScript -Value ("Import-Module '{0}' -Force; `$l = Enter-LaiVolumeLock; Start-Sleep -Seconds 120; Exit-LaiVolumeLock `$l" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'))
    $holder = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $holdScript) -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-LaiVolumeLockBusy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    Assert-That (Test-LaiVolumeLockBusy) 'setup: another process holds the volume lock'
    # A restore in progress has already written its hold: still maintenance, not a failure.
    ConvertTo-Json @{ Reason = 'a restore was interrupted (or is still running)'; Recover = 'x' } | Set-Content -LiteralPath (Join-Path $aiRoot 'open-webui-hold.json')
    Invoke-Watch | Out-Null
    $lastLine = @((Get-WatchLog) -split "`n" | Where-Object { $_ -and $_ -notmatch ' NOTIFY ' })[-1]
    Remove-Item -LiteralPath (Join-Path $aiRoot 'open-webui-hold.json') -Force
    Assert-That ($lastLine -match 'left alone' -and $lastLine -notmatch 'failed restore') "a restore still running is not reported as failed ($lastLine)"
    Assert-That ((Get-State 'open-webui') -eq 'created') 'Open WebUI is not started mid-backup/restore'
    Assert-That ((Get-WatchLog) -match 'left alone') 'watch.log says it was left alone on purpose'

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
        if ($holder -and -not $holder.HasExited) { $holder.Kill() }
        $deadline = (Get-Date).AddSeconds(30)
        while ((Test-LaiVolumeLockBusy) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        Invoke-DockerText @('rm', '-f', 'open-webui') | Out-Null   # the stand-in from 3. would be started and waited for
        Invoke-Watch | Out-Null
        Assert-That ((Get-State 'deep-research') -eq 'running' -and (Get-WatchLog) -match 'restarted: [^)]*Deep research') 'a deep research container left paused (a backup killed mid-copy) is woken once the lock is free'
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
        if (-not $holder.HasExited) { $holder.WaitForExit(15000) | Out-Null }
    }

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
    Assert-That ((& $lastFail) -match 'Backups \(open-webui-\S+ is dated \S+, in the future .*: delete it\)') "a backup dated in the future fails the check and says to delete it ($(& $lastFail))"
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
    $env:LOCALAI_TEST_TOAST_FAIL = '1'
    try { Invoke-Watch @('-NoHeal') | Out-Null } finally { $env:LOCALAI_TEST_TOAST_FAIL = '' }
    Assert-That (@((Read-LaiState -Path $statePath)['pendingRecovered']) -contains 'Backups') 'a recovery toast that failed is kept for the next run'
    Invoke-Watch @('-NoHeal') | Out-Null
    Assert-That ((Get-WatchLog) -match 'NOTIFY Local AI: [^\n]*(recovered Backups|Working again: Backups)' -and -not (Read-LaiState -Path $statePath).ContainsKey('pendingRecovered')) 'and is sent on the next run'
    # A 'problem detected' toast that fails is not marked as delivered: the next run tries again.
    Get-ChildItem -LiteralPath $bdir -File | Remove-Item -Force
    Save-LaiState -State @{ failed = @('Backups'); notified = @() } -Path $statePath
    $env:LOCALAI_TEST_TOAST_FAIL = '1'
    try { Invoke-Watch @('-NoHeal') | Out-Null } finally { $env:LOCALAI_TEST_TOAST_FAIL = '' }
    Assert-That (@((Read-LaiState -Path $statePath)['notified']) -notcontains 'Backups') 'a problem toast that failed is not counted as delivered'
    $before = @((Get-WatchLog) -split "`n" | Where-Object { $_ -match 'NOTIFY Local AI: problem detected' }).Count
    Invoke-Watch @('-NoHeal') | Out-Null
    $after = @((Get-WatchLog) -split "`n" | Where-Object { $_ -match 'NOTIFY Local AI: problem detected' }).Count
    Assert-That ($after -eq $before + 1 -and @((Read-LaiState -Path $statePath)['notified']) -contains 'Backups') 'and is sent on the next run'
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
    $env:LOCALAI_DOCKER_TIMEOUT = '3'
    try {
        Save-LaiState -State @{ failed = @() } -Path $statePath
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-Watch @('-NoHeal') | Out-Null
        $watchSec = $sw.Elapsed.TotalSeconds
        $hangLine = & $lastFail
        Assert-That ($watchSec -lt 90 -and $hangLine -match 'FAIL .*Docker \(not responding' -and @((Read-LaiState -Path $statePath)['failed']) -contains 'Docker') ("the watch reports Docker as not responding, and logs and saves its state instead of hanging ({0:N0} s: {1})" -f $watchSec, $hangLine)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & pwsh -NoProfile -File (Join-Path $src 'Backup-OpenWebUI.ps1') -AIRoot $aiRoot -EngineWaitSec 20 2>&1 | Out-Null
        $bcode = $LASTEXITCODE; $ErrorActionPreference = $prev
        $backupSec = $sw.Elapsed.TotalSeconds
        $bl = Join-Path (Join-Path $aiRoot 'Logs') 'backup.log'
        $blog = ''; if (Test-Path -LiteralPath $bl) { $blog = Get-Content -Raw -LiteralPath $bl }
        Assert-That ($bcode -eq 1 -and $backupSec -lt 120 -and $blog -match '\[FAIL\] Docker Desktop is not responding') ("the nightly backup writes a FAIL line to backup.log and exits 1 instead of hanging (exit {0}, {1:N0} s)" -f $bcode, $backupSec)
    } finally { $env:PATH = $savedPATH; $env:LOCALAI_DOCKER_TIMEOUT = '' }
    $pids = @(Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d+$' })
    # Still running = /proc entry that is not a zombie.
    $alive = @($pids | Where-Object { (Test-Path -LiteralPath "/proc/$_/stat") -and ((Get-Content -Raw -LiteralPath "/proc/$_/stat" -ErrorAction SilentlyContinue) -notmatch '^\d+ \(.*\) Z') })
    Assert-That ($pids.Count -ge 2 -and $alive.Count -eq 0) "every docker call that hung was stopped ($($pids.Count) started, $($alive.Count) still running)"

    Write-Host "`n=== 8. Open WebUI up, but unable to reach Ollama (the path chats take) ===" -ForegroundColor Cyan
    # A stand-in Open WebUI on the host network that answers /health on port 3998 and has python3
    # (SearXNG's image), so the watch probes Ollama from inside it as it would from the real one.
    $pyImage = Invoke-DockerText @('inspect', '-f', '{{.Config.Image}}', 'searxng')
    Invoke-DockerText @('rm', '-f', 'open-webui') | Out-Null
    $srv = "import http.server as h;C=type('C',(h.BaseHTTPRequestHandler,),{'do_GET':lambda s:(s.send_response(200),s.end_headers(),s.wfile.write(b'{}'))});h.HTTPServer(('127.0.0.1',3998),C).serve_forever()"
    # Labelled as a test container: if this suite is killed before 'finally', Reset-Sandbox removes it.
    Invoke-DockerText @('run', '-d', '--name', 'open-webui', '--label', 'lai-test=1', '--network', 'host', '--entrypoint', 'python3', $pyImage, '-c', $srv) | Out-Null
    $c7 = Read-LaiState -Path $cfgFile; $c7['WebUIPort'] = 3998; $c7['WebUIOllamaUrl'] = 'http://127.0.0.1:9'; Save-LaiState -State $c7 -Path $cfgFile
    $up = $false
    for ($i = 0; $i -lt 30 -and -not $up; $i++) { try { Invoke-LaiApi -Uri 'http://127.0.0.1:3998/health' -TimeoutSec 2 | Out-Null; $up = $true } catch { Start-Sleep -Seconds 1 } }
    Assert-That $up "setup: the stand-in Open WebUI answers on port 3998 ($(Get-State 'open-webui'))"
    Invoke-Watch @('-NoHeal') | Out-Null
    $l7 = & $lastFail
    Assert-That ($l7 -match 'Chats reach Ollama \(Open WebUI cannot reach Ollama at http://127\.0\.0\.1:9 ') "Open WebUI answering but unable to reach Ollama is a failed check that names the URL ($l7)"
    $c7['WebUIOllamaUrl'] = 'http://127.0.0.1:11434'; Save-LaiState -State $c7 -Path $cfgFile
    Invoke-Watch @('-NoHeal') | Out-Null
    $l7 = & $lastFail
    Assert-That ($l7 -notmatch 'Chats reach Ollama') "and passes once Ollama answers at that URL ($l7)"

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
        $env:LOCALAI_TEST_TOAST_SETTING = 'DisabledForUser'
        try { Invoke-Watch $w9 | Out-Null } finally { $env:LOCALAI_TEST_TOAST_SETTING = '' }
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
    # Files only: Linux has no Task Scheduler and no Get-NetTCPConnection, so tasks and listeners are
    # skipped here (the Windows unit tests run the watch against real ones). The sandbox's real Open
    # WebUI (port 3000, as in 9.) shows the banner.
    $igScripts = Join-Path $aiRoot 'Scripts'; $igStack = Join-Path $aiRoot 'Stack'
    foreach ($d in (Join-Path $igScripts 'lib'), (Join-Path $igScripts 'Secrets')) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $igTool = Join-Path $igScripts 'tool.ps1'; $igHelper = Join-Path (Join-Path $igScripts 'lib') 'helper.psm1'
    Set-Content -LiteralPath $igTool -Value 'original'
    Set-Content -LiteralPath $igHelper -Value 'original'
    Set-Content -LiteralPath (Join-Path (Join-Path $igScripts 'Secrets') 'token.txt') -Value 'secret-1'
    Set-Content -LiteralPath (Join-Path $igStack '.env') -Value 'OPEN_WEBUI_VERSION=v1'
    Set-Content -LiteralPath (Join-Path $igStack 'compose.log') -Value 'line 1'
    $igView = { $s = (Read-LaiState -Path $statePath)['integrity']; if ($s -is [hashtable]) { $s } else { @{} } }
    $igFound = { @((& $igView)['found'] | Where-Object { $_ -is [hashtable] } | ForEach-Object { [string]$_['Text'] }) }
    $igLog = { @((Get-WatchLog) -split "`n" | Where-Object { $_ -cmatch ' INTEGRITY ' }) }
    # Only notifications that went out (a failed toast is logged as 'NOTIFY (toast failed) ...').
    $igNotices = { param($Title) @((Get-WatchLog) -split "`n" | Where-Object { $_ -match (' NOTIFY Local AI: ' + $Title) }) }
    $igHourLater = { $s = Read-LaiState -Path $statePath; $s['integrity']['checkedAt'] = (Get-Date).AddMinutes(-61).ToString('s'); Save-LaiState -State $s -Path $statePath }
    $tok10 = Connect-LaiWebUI -BaseUrl $wu -Email 'admin@localhost' -Password 'Test-Password-123'
    $igBanner = { @(Invoke-LaiApi -Uri "$wu/api/v1/configs/banners" -Token $tok10 | Where-Object { $null -ne $_ } | Where-Object { $_.id -eq 'localai-health-watch' -and $_.content -match 'changed since the last install or update' }) }
    try {
        Invoke-Watch $w9 | Out-Null
        Assert-That (-not (Read-LaiState -Path $statePath).ContainsKey('integrity') -and @(& $igLog).Count -eq 0) 'without a baseline nothing is compared, recorded or logged'
        $ig0 = Save-LaiIntegrityBaseline -AIRoot $aiRoot -Reason 'test'
        $igNames = @($ig0['files'].Keys)
        Assert-That ($igNames -contains 'Scripts\tool.ps1' -and $igNames -contains 'Scripts\lib\helper.psm1' -and $igNames -contains 'Stack\docker-compose.yml') "the baseline lists the files of Scripts and Stack ($(($igNames | Sort-Object) -join ', '))"
        Assert-That (@($igNames | Where-Object { $_ -match 'Secrets|\.env$|\.log$' }).Count -eq 0) 'but not .env, not logs, and nothing under a Secrets folder'
        Invoke-Watch $w9 | Out-Null
        Assert-That ([string](& $igView)['baseline'] -eq [string]$ig0['id'] -and @(& $igFound).Count -eq 0 -and @(& $igNotices 'changed outside an update').Count -eq 0) 'the first look after the baseline: nothing differs, nothing is announced'
        # What changes in normal use is left alone.
        Set-Content -LiteralPath (Join-Path $igStack '.env') -Value 'OPEN_WEBUI_VERSION=v2'
        Add-Content -LiteralPath (Join-Path $igStack 'compose.log') -Value 'line 2'
        Set-Content -LiteralPath (Join-Path (Join-Path $igScripts 'Secrets') 'token.txt') -Value 'secret-2'
        & $igHourLater
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $igFound).Count -eq 0 -and @(& $igLog).Count -eq 0) "an hour later: a rewritten .env, a grown log and a changed file under Secrets are not differences ($(@(& $igFound) -join '; '))"
        # A script changed outside an update: not hashed on every run, then two strikes, then told once.
        Set-Content -LiteralPath $igTool -Value 'changed outside an update'
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $igFound).Count -eq 0) 'a changed script is not looked for on the very next run (files are hashed about once an hour, not every 15 minutes)'
        & $igHourLater
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $igFound) -contains 'Scripts\tool.ps1 was changed' -and @((& $igView)['pending'] | Where-Object { $_ }).Count -eq 1 -and @(& $igNotices 'changed outside an update').Count -eq 0) "an hour later it is seen and recorded, not announced yet ($(@(& $igFound) -join '; '))"
        Assert-That (@(& $igLog | Where-Object { $_ -match '1 difference\(s\) from the baseline: Scripts\\tool\.ps1 was changed' }).Count -eq 1) 'and watch.log names it'
        $env:LOCALAI_TEST_TOAST_FAIL = '1'
        try { Invoke-Watch $w9 | Out-Null } finally { $env:LOCALAI_TEST_TOAST_FAIL = '' }
        Assert-That (@((& $igView)['told'] | Where-Object { $_ }).Count -eq 0 -and @((& $igView)['pending'] | Where-Object { $_ }).Count -eq 1 -and @(& $igBanner).Count -eq 0) 'seen again, but the notification failed: not counted as told, kept for the next run'
        Invoke-Watch $w9 | Out-Null
        $n10 = @(& $igNotices 'changed outside an update')
        Assert-That ($n10.Count -eq 1 -and $n10[0] -match 'Scripts\\tool\.ps1 was changed' -and $n10[0] -match 'Local AI - Health check') "the next run announces it once, naming the file and the next step ($($n10 -join ' | '))"
        $b10 = @(& $igBanner)
        Assert-That ($b10.Count -eq 1 -and $b10[0].content -match 'changed since the last install or update: Scripts\\tool\.ps1 was changed') "and it is on the Open WebUI banner ($(@($b10 | ForEach-Object { $_.content }) -join ' | '))"
        $hc10 = (& pwsh -NoProfile -File (Join-Path $src 'Test-LocalAI.ps1') -AIRoot $aiRoot -Quick 2>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-That ($hc10 -match 'WARN Integrity watch: 1 change\(s\) since the baseline of [^\n]*Scripts\\tool\.ps1 was changed[^\n]*-AcceptBaseline') 'the health check lists the change and how to accept it'
        # More changes: told together, without repeating the one already told.
        Set-Content -LiteralPath (Join-Path $igStack 'extra.yml') -Value 'services: {}'
        Remove-Item -LiteralPath $igHelper -Force
        & $igHourLater
        Invoke-Watch $w9 | Out-Null
        Invoke-Watch $w9 | Out-Null
        $n10 = @(& $igNotices 'changed outside an update')
        Assert-That ($n10.Count -eq 2 -and $n10[-1] -match 'Stack\\extra\.yml is new' -and $n10[-1] -match 'Scripts\\lib\\helper\.psm1 is gone' -and $n10[-1] -notmatch 'tool\.ps1') "a new and a deleted file are announced together, once; what was told is not repeated ($($n10[-1]))"
        # An installer run that started after the baseline and recorded none (waiting for a restart, or
        # failed): its changes are named as an unfinished update, with Update toolkit as the fix.
        Set-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Logs') ('install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Value 'an installer run that did not finish'
        Set-Content -LiteralPath $igTool -Value 'half of an update'
        & $igHourLater
        Invoke-Watch $w9 | Out-Null
        Invoke-Watch $w9 | Out-Null
        $u10 = @(& $igNotices 'update not finished')
        Assert-That ($u10.Count -eq 1 -and $u10[0] -match 'has not finished' -and $u10[0] -match 'Scripts\\tool\.ps1 was changed' -and $u10[0] -match 'Local AI - Update toolkit' -and @(& $igNotices 'changed outside an update').Count -eq 2) "after an installer run that did not finish, the changes are an unfinished update, not changes nobody asked for ($($u10 -join ' | '))"
        # The owner accepts the current state.
        $acc10 = Invoke-Watch @('-AcceptBaseline')
        Assert-That ($acc10 -match 'integrity baseline accepted' -and $acc10 -match 'accepted: Stack\\extra\.yml is new' -and [string](Read-LaiIntegrityBaseline -AIRoot $aiRoot)['id'] -ne [string]$ig0['id']) "-AcceptBaseline records the current state as the new baseline and lists what it accepted ($(($acc10 -split "`n" | Select-Object -Last 1)))"
        Invoke-Watch $w9 | Out-Null
        Assert-That (@(& $igFound).Count -eq 0 -and [string](& $igView)['checkedAt'] -and @(& $igBanner).Count -eq 0) 'after that nothing differs any more, and the banner is gone'
        # The baseline itself removed: that is a change, too.
        Remove-Item -LiteralPath (Get-LaiIntegrityPath -AIRoot $aiRoot) -Force
        & $igHourLater
        Invoke-Watch $w9 | Out-Null
        Invoke-Watch $w9 | Out-Null
        $n10 = @(& $igNotices 'changed outside an update')
        Assert-That ($n10.Count -eq 3 -and $n10[-1] -match 'the baseline itself \([^)]*integrity-baseline\.json\) is gone') "a baseline that disappears is announced ($($n10[-1]))"
    } finally {
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
