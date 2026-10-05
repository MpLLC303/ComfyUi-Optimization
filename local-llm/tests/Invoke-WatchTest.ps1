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
    if ($holder -and -not $holder.HasExited) { $holder.Kill() }

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
    $freeGB = [Math]::Floor([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($aiRoot)).AvailableFreeSpace / 1GB)
    $limit = [int]$freeGB - 1
    Save-LaiState -State @{ failed = @() } -Path $statePath
    Invoke-Watch @('-NoHeal', '-MinFreeGB', "$limit") | Out-Null
    Assert-That ((& $lastFail) -notmatch 'Disk space') "free space 1 GB above the limit passes when it was fine before ($freeGB GB free, limit $limit)"
    Save-LaiState -State @{ failed = @('Disk space') } -Path $statePath
    Invoke-Watch @('-NoHeal', '-MinFreeGB', "$limit") | Out-Null
    Assert-That ((& $lastFail) -match 'Disk space') 'but after a low-space failure it needs 2 GB more before it counts as fixed (no toast flapping)'
    $c5 = Read-LaiState -Path $cfgFile; $c5.Remove('BackupMirror'); Save-LaiState -State $c5 -Path $cfgFile
} finally {
    if ($holder -and -not $holder.HasExited) { $holder.Kill() }
    $tc = Join-Path (Join-Path $aiRoot 'Stack') 'docker-compose.yml'
    if (Test-Path -LiteralPath $tc) { Invoke-DockerText @('compose', '--project-directory', (Join-Path $aiRoot 'Stack'), '-f', $tc, 'down') | Out-Null }
    Invoke-DockerText @('rm', '-f', 'open-webui') | Out-Null
    if ((Get-State 'searxng') -ne 'running') { Invoke-DockerText @('start', 'searxng') | Out-Null }
}

if ($failures -eq 0) { Write-Host "`nWATCH TEST PASSED" -ForegroundColor Green } else { Write-Host "`nWATCH TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
