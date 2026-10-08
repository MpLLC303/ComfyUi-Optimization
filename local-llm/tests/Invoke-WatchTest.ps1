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
        $env:LOCALAI_TEST_TOAST_FAIL = '1'
        try { Invoke-Watch $w9 | Out-Null } finally { $env:LOCALAI_TEST_TOAST_FAIL = '' }
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
        # The hook that ends the run is an environment variable, which any program running as the
        # owner could set for good: it works only with the id of the baseline being compared, and
        # the mark names it as what ended the run.
        $igOldId = [string](& $igView)['baseline']
        $env:LOCALAI_TEST_INTEGRITY_END = [string]$ig2['id']
        try { Invoke-Watch $w9 | Out-Null } finally { $env:LOCALAI_TEST_INTEGRITY_END = '' }
        $igEnded = & $igView
        Assert-That ($igOldId -and $igOldId -ne [string]$ig2['id'] -and [string]$igEnded['baseline'] -eq [string]$ig2['id'] -and [string]$igEnded['startedAt'] -and [string]$igEnded['announced'] -eq [string]$ig2['id'] -and -not $igEnded['checkedAt']) "a run ended in the middle of the first comparison with a new baseline leaves its mark under that baseline, with what it had announced (baseline $([string]$igEnded['baseline']), started $([string]$igEnded['startedAt']))"
        Assert-That ([string]$igEnded['tried'] -eq [string]$ig2['id']) "and with the word that the watch has had its turn with that baseline's list (tried $([string]$igEnded['tried']))"
        Invoke-Watch $w9 | Out-Null
        Invoke-Watch $w9 | Out-Null
        $igAfterEnd = & $igView
        $igEndLines = @(& $igLog | Where-Object { $_ -match 'INTEGRITY not compared: [^\n]*LOCALAI_TEST_INTEGRITY_END' })
        Assert-That (-not $igAfterEnd['checkedAt'] -and [string]$igAfterEnd['startedAt'] -eq [string]$igEnded['startedAt'] -and [string]$igAfterEnd['announced'] -eq [string]$ig2['id'] -and @(& $igNotices 'the update kept changes it did not make').Count -eq 1) "the two runs after it do not start that comparison again and do not announce again what the update kept ($(@(& $igNotices 'the update kept changes it did not make').Count) notice(s))"
        Assert-That ([string]$igAfterEnd['skippedWhy'] -match 'LOCALAI_TEST_INTEGRITY_END' -and [string]$igAfterEnd['skippedWhy'] -match 'remove that variable' -and $igEndLines.Count -eq 1) "what ended it is named, for the health check and the notice after hours, and once in watch.log over two runs: the variable, not an installer window ($($igEndLines.Count) line(s): $([string]$igAfterEnd['skippedWhy']))"
        # Now the watch's record carries the new baseline's own id, and no comparison has finished
        # under it: the health check gives the reason instead of 'on its next run'.
        $hc10 = & $igHealth
        Assert-That ($hc10 -match 'WARN Integrity watch: [^\n]*has not compared the PC with it yet: the comparison is not running \([^\n]*LOCALAI_TEST_INTEGRITY_END[^\n]*kept 1 thing\(s\) it did not install' -and $hc10 -notmatch 'on its next run') "a comparison that never finished under the new baseline: the health check says why ($hc10)"
        # Hours later the notice names the variable and gives no advice made for the setup lock: closing
        # an installer window or restarting the PC changes nothing for a variable that was set for good.
        $s10 = Read-LaiState -Path $statePath; $s10['integrity']['skippedSince'] = (Get-Date).AddHours(-7).ToString('s'); Save-LaiState -State $s10 -Path $statePath
        Invoke-Watch $w9 | Out-Null
        $igHookNotices = @(& $igNotices 'changes are not being checked')
        $igHookNotice = ''; if ($igHookNotices.Count) { $igHookNotice = [string]$igHookNotices[-1] }
        Assert-That ($igHookNotices.Count -eq $igUnchecked.Count + 1 -and $igHookNotice -match 'LOCALAI_TEST_INTEGRITY_END' -and $igHookNotice -notmatch 'installer window|restart the PC') "the notice for a comparison ended by the test hook names the variable and does not send the owner to an installer window or a restart ($igHookNotice)"
        Assert-That ($igUnchecked[0] -match 'close an installer window that is still open or restart the PC') "while the setup lock is held the notice does carry that advice ($($igUnchecked -join ' | '))"
        # An hour after it was started the comparison is tried again, and this time it finishes: also
        # with the variable still set to the id of the baseline before, as one set for good would be
        # after the next update. A value that is not the id of the baseline in use ends nothing.
        $s10 = Read-LaiState -Path $statePath; $s10['integrity']['startedAt'] = (Get-Date).AddMinutes(-61).ToString('s'); Save-LaiState -State $s10 -Path $statePath
        $env:LOCALAI_TEST_INTEGRITY_END = $igOldId
        try { Invoke-Watch $w9 | Out-Null } finally { $env:LOCALAI_TEST_INTEGRITY_END = '' }
        Assert-That ([string](& $igView)['checkedAt'] -and -not (& $igView)['startedAt'] -and -not (& $igView)['skippedWhy']) 'an hour later it is started again, and finishes; the variable left at the id of the baseline before does not end it'
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
        $env:LOCALAI_TEST_INTEGRITY_END = $ig3Id
        try { Invoke-Watch $w9 | Out-Null } finally { $env:LOCALAI_TEST_INTEGRITY_END = '' }
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
        $env:LOCALAI_TEST_TOAST_FAIL = '1'
        try { Invoke-Watch $w9 | Out-Null } finally { $env:LOCALAI_TEST_TOAST_FAIL = '' }
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
