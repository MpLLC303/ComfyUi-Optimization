<#
.SYNOPSIS
    Tests Update-OpenWebUI.ps1 on a throwaway stack: update with a rollback point, a failed pull that
    must change nothing, -Rollback (old image + pre-update data), retention of the rollback archive.

.DESCRIPTION
    The stand-in compose file runs alpine:${OPEN_WEBUI_VERSION} as "open-webui" on the open-webui
    volume, so switching "versions" is real (3.19 <-> 3.20) and cheap. The end-of-update health wait
    and quick test talk to the sandbox's real Open WebUI on port 3000. A data marker in the volume
    shows which data is live. A sandbox container named searxng is not touched (separate project).
#>
param([string]$Work = (Join-Path ([System.IO.Path]::GetTempPath()) 'lai-updatetest'))
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
function Get-Marker { return (Invoke-DockerText @('run', '--rm', '-v', 'open-webui:/d', 'alpine:3.20', 'cat', '/d/marker')) }
function Set-Marker([string]$Value) { Invoke-DockerText @('run', '--rm', '-v', 'open-webui:/d', 'alpine:3.20', 'sh', '-c', "echo $Value > /d/marker") | Out-Null }
function Get-Image { return (Invoke-DockerText @('inspect', '-f', '{{.Config.Image}}', 'open-webui')) }
function New-DockerShim([string]$Name, [string]$Body) {
    # A 'docker' first on PATH that does something special, then hands everything else to the real
    # one. REALDOCKER in $Body is replaced by the real docker's path.
    $dir = Join-Path $Work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $real = (Get-Command docker -CommandType Application | Select-Object -First 1).Source
    Set-Content -LiteralPath (Join-Path $dir 'docker') -Value ($Body.Replace("`r", '').Replace('REALDOCKER', $real))
    & chmod +x (Join-Path $dir 'docker')
    return $dir
}
function Invoke-WithPath([string]$Dir, [scriptblock]$Body) {
    $saved = $env:PATH
    $env:PATH = $Dir + [System.IO.Path]::PathSeparator + $saved
    try { return (& $Body) } finally { $env:PATH = $saved }
}
function Invoke-Update([string[]]$Arguments) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & pwsh -NoProfile -File (Join-Path $src 'Update-OpenWebUI.ps1') -AIRoot $aiRoot @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $out | Where-Object { $_ -match 'OK|WARN|FAIL|roll|pull' } | Select-Object -Last 3 | ForEach-Object { Write-Host "    | $_" }
    return [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}

# ---- throwaway stack -------------------------------------------------------------------------------
if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
$aiRoot = Join-Path $Work 'AI'
$stack = Join-Path $aiRoot 'Stack'
foreach ($d in $stack, (Join-Path $aiRoot 'Backups'), (Join-Path $aiRoot 'Secrets'), (Join-Path $aiRoot 'Logs')) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
@'
name: lai-update-test
services:
  open-webui:
    image: alpine:${OPEN_WEBUI_VERSION}
    container_name: open-webui
    restart: always
    command: ["sleep", "3600"]
    volumes: ["open-webui:/app/backend/data"]
volumes:
  open-webui:
    name: open-webui
'@ | Set-Content -LiteralPath (Join-Path $stack 'docker-compose.yml')
Set-Content -LiteralPath (Join-Path $stack '.env') -Value @('OPEN_WEBUI_VERSION=3.19', 'SEARXNG_VERSION=x1', 'RENDER_GUARD_MODE=cpu')
# WebUIOllamaUrl: restores re-apply it to the (real, shared) sandbox Open WebUI, so keep it pointing at Ollama.
ConvertTo-Json @{ WebUIPort = 3000; OllamaUrl = 'http://127.0.0.1:11434'; WebUIOllamaUrl = 'http://127.0.0.1:11434' } | Set-Content -LiteralPath (Join-Path $aiRoot 'localai-config.json')
ConvertTo-Json @{ email = 'admin@localhost'; password = 'Test-Password-123' } | Set-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Secrets') 'openwebui-admin.json')
Invoke-DockerText @('rm', '-f', 'open-webui') | Out-Null
Invoke-DockerText @('volume', 'rm', 'open-webui') | Out-Null
Invoke-DockerText @('compose', '--project-directory', $stack, '-f', (Join-Path $stack 'docker-compose.yml'), 'up', '-d') | Out-Null
Invoke-DockerText @('run', '--rm', '-v', 'open-webui:/d', 'alpine:3.20', 'sh', '-c', 'head -c 4096 /dev/urandom > /d/webui.db') | Out-Null
Set-Marker 'DATA-v1'
if (-not $env:LOCALAI_TEST_CATALOG) { $env:LOCALAI_TEST_CATALOG = Join-Path $PSScriptRoot 'models.test.psd1' }

try {
    Write-Host "`n=== 1. update 3.19 -> 3.20 ===" -ForegroundColor Cyan
    # An image from an even older update (a second tag of the same image: no download needed).
    Invoke-DockerText @('tag', 'alpine:3.20', 'alpine:lai-old-test') | Out-Null
    $r = Invoke-Update @('-Version', '3.20')
    $cfg = Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json')
    Assert-That ((Get-Image) -eq 'alpine:3.20') 'new image running'
    Assert-That ($cfg['PreviousOpenWebUIVersion'] -eq '3.19' -and (Test-Path -LiteralPath ([string]$cfg['RollbackArchive']))) 'rollback point recorded'
    Assert-That ($r.Text -match 'Rollback') 'prints how to roll back'
    $tagsNow = @((Invoke-DockerText @('images', '--format', '{{.Repository}}:{{.Tag}}', 'alpine')) -split "`n")
    Assert-That ($tagsNow -notcontains 'alpine:lai-old-test' -and $tagsNow -contains 'alpine:3.20' -and $tagsNow -contains 'alpine:3.19') "after a good update, older images go; the running one and the rollback one stay ($($tagsNow -join ', '))"
    $rollbackArchive = [string]$cfg['RollbackArchive']

    Write-Host "`n=== 2. failed pull changes nothing ===" -ForegroundColor Cyan
    $envBefore = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $stack '.env') -Raw
    $r = Invoke-Update @('-Version', '0.0.0-does-not-exist', '-SkipBackup')
    $cfg = Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json')
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'nothing was changed') "exits with 'nothing was changed' (exit $($r.Code))"
    Assert-That ((Get-Content -Encoding UTF8 -LiteralPath (Join-Path $stack '.env') -Raw) -eq $envBefore) '.env still names the working version'
    Assert-That ($cfg['RollbackArchive'] -eq $rollbackArchive) 'rollback point kept'
    Assert-That ((Get-Image) -eq 'alpine:3.20') 'running container untouched'

    Write-Host "`n=== 2b. SearXNG-only update keeps the Open WebUI rollback point ===" -ForegroundColor Cyan
    $r = Invoke-Update @('-Version', '3.20', '-SearxngVersion', 'x2', '-SkipBackup')
    $cfg = Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json')
    Assert-That ($cfg['RollbackArchive'] -eq $rollbackArchive -and $cfg['PreviousOpenWebUIVersion'] -eq '3.19') 'rollback point untouched'
    Assert-That ((Get-Content -Encoding UTF8 -LiteralPath (Join-Path $stack '.env')) -contains 'SEARXNG_VERSION=x2') 'SearXNG version changed'
    # SearXNG keeps no data: the way back is re-pinning the old tag, so that tag must be kept and said.
    Assert-That ($cfg['PreviousSearxngVersion'] -eq 'x1' -and $cfg['SearxngVersion'] -eq 'x2') "the SearXNG tag it replaced is recorded ($($cfg['PreviousSearxngVersion']) -> $($cfg['SearxngVersion']))"
    $ulog = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path (Join-Path $aiRoot 'Logs') 'update.log')
    Assert-That ($ulog -match 'SearXNG x1 -> x2' -and $ulog -match 'Update-OpenWebUI\.ps1 -SearxngVersion x1' -and $r.Text -match 'Update-OpenWebUI\.ps1 -SearxngVersion x1') 'update.log and the output name the SearXNG change and the way back'
    $r = Invoke-Update @()
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Nothing to do') 'no arguments: explains instead of re-pulling'

    Write-Host "`n=== 2c. an update cut off during the download (window closed, power cut) changes nothing ===" -ForegroundColor Cyan
    # This docker kills the update's own process as the pull starts: no catch or finally runs.
    $shimBody = @'
#!/bin/sh
case " $* " in *' pull '*) kill -9 $PPID; exit 1;; esac
exec 'REALDOCKER' "$@"
'@
    $killDir = New-DockerShim 'kill-on-pull' $shimBody
    $envFile = Join-Path $stack '.env'; $cfgFile = Join-Path $aiRoot 'localai-config.json'
    $envText = [System.IO.File]::ReadAllText($envFile); $cfgText2 = [System.IO.File]::ReadAllText($cfgFile)
    $r = Invoke-WithPath $killDir { Invoke-Update @('-Version', '3.19', '-SkipBackup') }
    Assert-That ($r.Code -ne 0 -and [System.IO.File]::ReadAllText($envFile) -eq $envText) "killed mid-download (exit $($r.Code)): .env still names the version that is running"
    Assert-That ([System.IO.File]::ReadAllText($cfgFile) -eq $cfgText2 -and (Get-Image) -eq 'alpine:3.20') 'rollback point and running container untouched'
    $r = Invoke-Update @('-Version', '3.19', '-SkipBackup')
    Assert-That ($r.Code -eq 0 -and $r.Text -notmatch 'Already on' -and (Get-Image) -eq 'alpine:3.19') "running it again updates instead of saying 'Already on' (exit $($r.Code))"
    # Back to what step 1 left: the steps below roll back from 3.20 with its rollback point.
    [System.IO.File]::WriteAllText($envFile, $envText); [System.IO.File]::WriteAllText($cfgFile, $cfgText2)
    Invoke-DockerText @('compose', '--project-directory', $stack, '-f', (Join-Path $stack 'docker-compose.yml'), 'up', '-d') | Out-Null
    Assert-That ((Get-Image) -eq 'alpine:3.20') 'setup for the next steps: 3.20 runs again'

    Write-Host "`n=== 2d. an install left behind by the old order (.env names a version that never ran) is repaired first ===" -ForegroundColor Cyan
    # What an older Update-OpenWebUI.ps1 cut off mid-download left: .env on 3.19 while 3.20 runs.
    $badEnv = $envText -replace 'OPEN_WEBUI_VERSION=[^\r\n]*', 'OPEN_WEBUI_VERSION=3.19'
    [System.IO.File]::WriteAllText($envFile, $badEnv)
    $r = Invoke-Update @('-SearxngVersion', 'x3', '-SkipBackup')
    $envNow = @(Get-Content -Encoding UTF8 -LiteralPath $envFile)
    Assert-That ($r.Text -match 'names Open WebUI 3\.19, but 3\.20 is running' -and (Get-Image) -eq 'alpine:3.20' -and $envNow -contains 'OPEN_WEBUI_VERSION=3.20' -and $envNow -contains 'SEARXNG_VERSION=x3') "a SearXNG-only update sets .env back to 3.20 and does not start 3.19 on the data (exit $($r.Code), $(Get-Image))"
    [System.IO.File]::WriteAllText($envFile, $badEnv)
    $r = Invoke-Update @('-Version', '3.19', '-SkipBackup')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'names Open WebUI 3\.19, but 3\.20 is running' -and $r.Text -notmatch 'Already on' -and (Get-Image) -eq 'alpine:3.19') "-Version 3.19 updates instead of saying 'Already on' (exit $($r.Code), $(Get-Image))"
    [System.IO.File]::WriteAllText($envFile, $envText); [System.IO.File]::WriteAllText($cfgFile, $cfgText2)
    Invoke-DockerText @('compose', '--project-directory', $stack, '-f', (Join-Path $stack 'docker-compose.yml'), 'up', '-d') | Out-Null
    Assert-That ((Get-Image) -eq 'alpine:3.20') 'setup for the next steps: 3.20 runs again'

    Write-Host "`n=== 3. retention keeps the rollback archive ===" -ForegroundColor Cyan
    # Age it through a container: on Linux the archive is owned by root (Docker wrote it), so a
    # non-root test user cannot change its timestamp directly.
    $old = (Get-Date).AddDays(-60).ToString('yyyy-MM-dd HH:mm:ss')
    Invoke-DockerText @('run', '--rm', '-v', "$(Split-Path -Parent $rollbackArchive):/b", 'alpine:3.20', 'touch', '-d', $old, "/b/$(Split-Path -Leaf $rollbackArchive)") | Out-Null
    Assert-That (((Get-Date) - (Get-Item -LiteralPath $rollbackArchive).LastWriteTime).TotalDays -gt 50) 'rollback archive aged to 60 days'
    # An uninstall's final backup (the only copy of the old chats after a reinstall) and an ordinary
    # tagged one, both 60 days old: only the ordinary one may go.
    $bdir = Split-Path -Parent $rollbackArchive
    Invoke-DockerText @('run', '--rm', '-v', "${bdir}:/b", 'alpine:3.20', 'sh', '-c', "echo x > /b/open-webui-20200101-000000-pre-uninstall.tar.gz; echo x > /b/open-webui-20200101-000000-pre-restore.tar.gz; touch -d '$old' /b/open-webui-20200101-000000-pre-uninstall.tar.gz /b/open-webui-20200101-000000-pre-restore.tar.gz") | Out-Null
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & pwsh -NoProfile -File (Join-Path $src 'Backup-OpenWebUI.ps1') -AIRoot $aiRoot -RetentionDays 1 -SkipDeepVerify 2>&1 | Out-Null
    $ErrorActionPreference = $prevPref
    Assert-That (Test-Path -LiteralPath $rollbackArchive) '60-day-old rollback archive survives pruning'
    Assert-That (Test-Path -LiteralPath (Join-Path $bdir 'open-webui-20200101-000000-pre-uninstall.tar.gz')) '60-day-old pre-uninstall archive survives pruning'
    Assert-That (-not (Test-Path -LiteralPath (Join-Path $bdir 'open-webui-20200101-000000-pre-restore.tar.gz'))) '60-day-old ordinary tagged archive is pruned'
    # The stand-in is not a real archive: later steps pick archives from this folder.
    Invoke-DockerText @('run', '--rm', '-v', "${bdir}:/b", 'alpine:3.20', 'rm', '-f', '/b/open-webui-20200101-000000-pre-uninstall.tar.gz') | Out-Null

    Write-Host "`n=== 3a. mirror: copied whole, and pruned like the local folder ===" -ForegroundColor Cyan
    $mirrorDir = Join-Path $Work 'nas'
    New-Item -ItemType Directory -Force -Path $mirrorDir | Out-Null
    foreach ($d in 1..4) {
        $f = Join-Path $mirrorDir ('open-webui-2020010{0}-000000.tar.gz' -f $d)
        Set-Content -LiteralPath $f -Value 'old'
        (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddDays(-60 + $d)
    }
    Set-Content -LiteralPath (Join-Path $mirrorDir 'incomplete-open-webui-20200101-000000.tar.gz') -Value 'cut off'
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & pwsh -NoProfile -File (Join-Path $src 'Backup-OpenWebUI.ps1') -AIRoot $aiRoot -RetentionDays 1 -SkipDeepVerify -Mirror $mirrorDir 2>&1 | Out-Null
    $ErrorActionPreference = $prevPref
    $m = @(Get-ChildItem -LiteralPath $mirrorDir -Filter 'open-webui-*.tar.gz' | Sort-Object LastWriteTime -Descending)  # lai-ok: objects
    Assert-That ($m.Count -eq 3 -and $m[0].Name -notlike 'open-webui-2020*' -and $m[0].Length -gt 100) "mirror: new archive plus the 2 newest old ones, 2 oldest pruned ($($m.Count) left)"
    Assert-That (@(Get-ChildItem -LiteralPath $mirrorDir -Filter 'incomplete-*').Count -eq 0) 'mirror: no partial copies left'
    $bsPath = Join-Path $aiRoot 'backup-state.json'
    Assert-That ([string](Read-LaiState -Path $bsPath)['mirrorTarget'] -eq $mirrorDir -and (Read-LaiState -Path $bsPath)['mirrorOkAt']) 'the backup records which mirror got the copy and when (the watch checks it)'
    # A mirror that cannot be written: the backup still succeeds, and the reason is recorded.
    $notADir = Join-Path $Work 'mirror-is-a-file'; Set-Content -LiteralPath $notADir -Value 'x'
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & pwsh -NoProfile -File (Join-Path $src 'Backup-OpenWebUI.ps1') -AIRoot $aiRoot -RetentionDays 1 -SkipDeepVerify -NoPrune -Mirror (Join-Path $notADir 'sub') 2>&1 | Out-Null
    $mcode = $LASTEXITCODE; $ErrorActionPreference = $prevPref
    Assert-That ($mcode -eq 0 -and (Read-LaiState -Path $bsPath)['mirrorError']) "a failed mirror copy does not fail the backup but is recorded (exit $mcode)"

    Write-Host "`n=== 3b. a failed backup leaves no archive that looks fresh ===" -ForegroundColor Cyan
    $bdir = Join-Path $aiRoot 'Backups'
    $countBefore = @(Get-ChildItem -LiteralPath $bdir -Filter 'open-webui-*.tar.gz').Count
    Set-Content -LiteralPath (Join-Path $bdir 'incomplete-open-webui-20200101-000000.tar.gz') -Value 'left by a crash'
    Invoke-DockerText @('volume', 'create', 'lai-empty-test') | Out-Null
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & pwsh -NoProfile -File (Join-Path $src 'Backup-OpenWebUI.ps1') -AIRoot $aiRoot -Volume 'lai-empty-test' -Container 'lai-no-such-container' -SkipDeepVerify -NoPrune 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    Invoke-DockerText @('volume', 'rm', 'lai-empty-test') | Out-Null
    Assert-That ($code -ne 0) "backup of a volume without webui.db fails (exit $code)"
    Assert-That (@(Get-ChildItem -LiteralPath $bdir -Filter 'open-webui-*.tar.gz').Count -eq $countBefore) 'no new archive counted as a backup'
    Assert-That (@(Get-ChildItem -LiteralPath $bdir -Filter 'incomplete-*').Count -eq 0) 'the half-written file and an older leftover are removed'

    Write-Host "`n=== 3c. a scheduled run waits for a chat answer being written; the sign-in run skips a night already done ===" -ForegroundColor Cyan
    # 'docker exec render-guard ...' answers the in-flight count from a list, one line per call.
    $answers = Join-Path $Work 'inflight.txt'
    $shimBody = @'
#!/bin/sh
if [ "$1" = exec ] && [ "$2" = render-guard ]; then
  n=$(head -n 1 'ANSWERS'); sed -i 1d 'ANSWERS'; echo "${n:-0}"; exit 0
fi
exec 'REALDOCKER' "$@"
'@
    $chatDir = New-DockerShim 'chat-shim' ($shimBody.Replace('ANSWERS', $answers))
    $runBackup = {
        param([string[]]$More)
        $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $o = & pwsh -NoProfile -File (Join-Path $src 'Backup-OpenWebUI.ps1') -AIRoot $aiRoot -SkipDeepVerify -NoPrune -NoMirror @More 2>&1 | ForEach-Object { "$_" }
        $c = $LASTEXITCODE; $ErrorActionPreference = $prevPref
        return [pscustomobject]@{ Code = $c; Text = ($o -join "`n") }
    }
    $env:LOCALAI_TEST_CHAT_POLL_SEC = '1'
    try {
        Set-Content -LiteralPath $answers -Value @('1', '1', '0')
        $b = Invoke-WithPath $chatDir { & $runBackup @('-WaitForChatsSec', '60') }
        Assert-That ($b.Code -eq 0 -and $b.Text -match 'Waited \d+ s for a chat answer to finish') "Open WebUI is stopped only after the answer being written is done (exit $($b.Code))"
        Set-Content -LiteralPath $answers -Value @('1', '1', '1', '1', '1', '1', '1', '1', '1', '1')
        $b = Invoke-WithPath $chatDir { & $runBackup @('-WaitForChatsSec', '2') }
        Assert-That ($b.Code -eq 0 -and $b.Text -match 'still being written after \d+ s; stopping Open WebUI anyway') "the wait has a limit, then the backup goes ahead (exit $($b.Code))"
    } finally { $env:LOCALAI_TEST_CHAT_POLL_SEC = '' }
    $nightly = { @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*.tar.gz' | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' }).Count }
    $n0 = & $nightly
    $b = & $runBackup @('-DailyAt', (Get-Date).AddMinutes(1).ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture))
    Assert-That ($b.Code -eq 0 -and (& $nightly) -eq $n0 -and $b.Text -match 'Nothing to do: the backup due at') "the sign-in run does nothing when the night's backup is already there (exit $($b.Code))"
    # A missed night: the due time is later than every nightly archive, so the sign-in run backs up.
    $newest = Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*.tar.gz' | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
    $t = (Get-Date); if ($newest) { $t = $newest.LastWriteTime }
    $dueAt = $t.Date.AddHours($t.Hour).AddMinutes($t.Minute + 1)
    while ((Get-Date) -lt $dueAt) { Start-Sleep -Milliseconds 500 }   # at most a minute
    $b = & $runBackup @('-DailyAt', $dueAt.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture))
    Assert-That ($b.Code -eq 0 -and $b.Text -notmatch 'Nothing to do' -and (& $nightly) -eq $n0 + 1) "the sign-in run catches up a missed night: due $($dueAt.ToString('HH:mm')), after the newest backup (exit $($b.Code))"

    Write-Host "`n=== 4. -Rollback ===" -ForegroundColor Cyan
    Set-Marker 'DATA-v2'
    $r = Invoke-Update @('-Rollback', '-Force')
    $cfg = Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Rolled back') "rollback ran (exit $($r.Code))"
    Assert-That ((Get-Image) -eq 'alpine:3.19') 'old image running again'
    Assert-That ((Get-Marker) -eq 'DATA-v1') 'pre-update data restored'
    Assert-That (-not $cfg.ContainsKey('RollbackArchive') -and $cfg['OpenWebUIVersion'] -eq '3.19') 'rollback point consumed, version recorded'
    $r = Invoke-Update @('-Rollback', '-Force')
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'Nothing to roll back') 'second rollback refuses clearly'
    Assert-That ((Get-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Logs') 'update.log') -Raw) -match 'Rolled back') 'update.log has the history'

    Write-Host "`n=== 5. a failed restore keeps Open WebUI down until a good restore ===" -ForegroundColor Cyan
    # The newest real archive (a stand-in or a corrupt one would make every restore below fail early).
    $good = Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*.tar.gz' | Where-Object { $_.Name -notlike '*CORRUPT*' -and $_.Length -gt 1KB } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
    $holdFile = Join-Path $aiRoot 'open-webui-hold.json'
    $runScript = {
        param([string]$Name, [string[]]$Arguments)
        $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $o = & pwsh -NoProfile -File (Join-Path $src $Name) -AIRoot $aiRoot @Arguments 2>&1 | ForEach-Object { "$_" }
        $c = $LASTEXITCODE; $ErrorActionPreference = $prevPref
        return [pscustomobject]@{ Code = $c; Text = ($o -join "`n") }
    }
    # The swap fails, and so does the rollback to the safety backup (same hook): the worst case.
    $env:LOCALAI_TEST_FAIL_SWAP = '1'
    $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force')
    $h1 = Read-LaiState -Path $holdFile
    Assert-That ($r.Code -ne 0 -and [string]$h1['Archive'] -like '*pre-restore*') "failed restore and rollback record a hold naming the safety backup (exit $($r.Code))"
    # Following the recovery command fails again (no safety backup of its own): the pointer must survive.
    $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', [string]$h1['Archive'], '-Force', '-SkipSafetyBackup')
    $env:LOCALAI_TEST_FAIL_SWAP = ''
    $h2 = Read-LaiState -Path $holdFile
    Assert-That ($r.Code -ne 0 -and $h2['Archive'] -eq $h1['Archive'] -and $r.Text -match 'earlier recovery command still applies') 'a failed recovery keeps the pointer to the newest safety backup'
    Assert-That ((Invoke-DockerText @('inspect', '-f', '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}', 'open-webui')) -eq 'exited no') 'container left stopped, restart policy off'
    # The watch must not start it (point it at a dead port so the shared sandbox Open WebUI does not answer for it).
    $cfgPath = Join-Path $aiRoot 'localai-config.json'
    $cfgText = Get-Content -LiteralPath $cfgPath -Raw
    $cfgTmp = Read-LaiState -Path $cfgPath; $cfgTmp['WebUIPort'] = 3999; Save-LaiState -State $cfgTmp -Path $cfgPath
    & $runScript 'Watch-LocalAI.ps1' @() | Out-Null
    Set-Content -LiteralPath $cfgPath -Value $cfgText -NoNewline
    Assert-That ((Invoke-DockerText @('inspect', '-f', '{{.State.Status}}', 'open-webui')) -eq 'exited') 'health watch leaves the held container stopped'
    Assert-That ((Get-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Logs') 'watch.log') -Raw) -match 'kept stopped after a failed restore') 'watch reports why it is down'
    $st = & $runScript 'Start-LocalAI.ps1' @()
    Assert-That ($st.Code -ne 0 -and $st.Text -match 'kept stopped after a failed restore' -and (Invoke-DockerText @('inspect', '-f', '{{.State.Status}}', 'open-webui')) -eq 'exited') 'Start-LocalAI refuses and says how to recover'
    $dailyBefore = @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*.tar.gz').Count
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-SkipDeepVerify')
    Assert-That ($b.Code -eq 0 -and $b.Text -match 'Skipped' -and @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*.tar.gz').Count -eq $dailyBefore) 'nightly backup skips possibly damaged data while held'
    $u = & $runScript 'Update-OpenWebUI.ps1' @('-Version', '3.20', '-SkipBackup')
    Assert-That ($u.Code -ne 0 -and $u.Text -match 'kept stopped after a failed restore' -and (Invoke-DockerText @('inspect', '-f', '{{.State.Status}}', 'open-webui')) -eq 'exited') 'Update-OpenWebUI refuses while held'
    $hj = Read-LaiState -Path $holdFile
    Assert-That ([string]$hj['Recover'] -match [regex]::Escape((Join-Path $src 'Restore-OpenWebUI.ps1'))) 'recovery command has the full script path'
    # The printed command itself, pasted as is (plus -Force for the YES prompt): it must name this
    # install's folder (not the default C:\AI) and survive quotes in paths.
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $ro = & pwsh -NoProfile -Command ([string]$hj['Recover'] + ' -Force') 2>&1 | ForEach-Object { "$_" }
    $r = [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($ro -join "`n") }; $ErrorActionPreference = $prevPref
    Assert-That ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $holdFile)) "the printed recovery command, pasted as is, restores and clears the hold (exit $($r.Code))"
    Assert-That ((Invoke-DockerText @('inspect', '-f', '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}', 'open-webui')) -eq 'running always') 'container running again with its original restart policy'

    Write-Host "`n=== 5b. a restore killed mid-swap (window closed, power cut) ===" -ForegroundColor Cyan
    $env:LOCALAI_TEST_KILL_IN_SWAP = '1'
    $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force', '-SkipSafetyBackup')
    $env:LOCALAI_TEST_KILL_IN_SWAP = ''
    $hk = Read-LaiState -Path $holdFile
    Assert-That ($r.Code -eq 9 -and [string]$hk['Reason'] -match 'interrupted') "killed with no catch/finally: the hold was already there (exit $($r.Code))"
    Assert-That ((Invoke-DockerText @('inspect', '-f', '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}', 'open-webui')) -eq 'exited no') 'Open WebUI stays down with auto-restart off'
    $cfgTmp = Read-LaiState -Path $cfgPath; $cfgTmp['WebUIPort'] = 3999; Save-LaiState -State $cfgTmp -Path $cfgPath
    & $runScript 'Watch-LocalAI.ps1' @() | Out-Null
    Set-Content -LiteralPath $cfgPath -Value $cfgText -NoNewline
    Assert-That ((Invoke-DockerText @('inspect', '-f', '{{.State.Status}}', 'open-webui')) -eq 'exited') 'the health watch does not start it on a half-swapped volume'
    $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force', '-SkipSafetyBackup')
    Assert-That ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $holdFile) -and (Invoke-DockerText @('inspect', '-f', '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}', 'open-webui')) -eq 'running always') 'running the restore again finishes it: hold cleared, auto-restart back'

    Write-Host "`n=== 5c. a failed swap rolled back from the safety backup leaves no hold ===" -ForegroundColor Cyan
    $env:LOCALAI_TEST_FAIL_SWAP_ONCE = '1'
    $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force')
    $env:LOCALAI_TEST_FAIL_SWAP_ONCE = ''
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'Rollback complete' -and -not (Test-Path -LiteralPath $holdFile)) "failed swap, good rollback: no hold left behind (exit $($r.Code))"
    Assert-That ((Invoke-DockerText @('inspect', '-f', '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}', 'open-webui')) -eq 'running always') 'and Open WebUI runs again as before'

    Write-Host "`n=== 5d. no safety backup: a recovery command that works; Docker down said as such ===" -ForegroundColor Cyan
    $bdir5 = Join-Path $aiRoot 'Backups'
    $future5 = Join-Path $bdir5 ('open-webui-{0}.tar.gz' -f (Get-Date).AddDays(400).ToString('yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $good.FullName -Destination $future5; (Get-Item -LiteralPath $future5).LastWriteTime = (Get-Date).AddDays(400)
    $env:LOCALAI_TEST_FAIL_SWAP = '1'
    $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force', '-SkipSafetyBackup')
    $env:LOCALAI_TEST_FAIL_SWAP = ''
    $h5 = Read-LaiState -Path $holdFile
    $rec5 = [string]$h5['Recover']
    Assert-That ($r.Code -ne 0 -and $rec5 -match '-Archive ' -and $rec5 -notmatch 'YYYYMMDD' -and $rec5 -notmatch [regex]::Escape($good.Name) -and $rec5 -notmatch [regex]::Escape((Split-Path -Leaf $future5))) "the recovery command names another real nightly backup ($rec5)"
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & pwsh -NoProfile -Command ($rec5 + ' -Force') 2>&1 | Out-Null
    $c5 = $LASTEXITCODE; $ErrorActionPreference = $prevPref
    Assert-That ($c5 -eq 0 -and -not (Test-Path -LiteralPath $holdFile)) "pasted as printed, it restores and clears the hold (exit $c5)"
    Remove-Item -LiteralPath $future5 -Force
    $savedDockerHost = $env:DOCKER_HOST; $env:DOCKER_HOST = 'unix:///nonexistent/lai-docker.sock'
    try { $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force') } finally { $env:DOCKER_HOST = $savedDockerHost }
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'Docker Desktop is not running' -and $r.Text -notmatch 'not a valid Open WebUI backup') 'with Docker down the restore says so (it used to call a good backup invalid)'

    Write-Host "`n=== 5e. a restore cut off right after it turned auto-restart off ===" -ForegroundColor Cyan
    # This docker kills the restore's own process right after 'update --restart no' (window closed,
    # power cut): no catch or finally runs.
    $shimBody = @'
#!/bin/sh
'REALDOCKER' "$@"; rc=$?
case " $* " in *' update --restart no '*) kill -9 $PPID;; esac
exit $rc
'@
    $offDir = New-DockerShim 'kill-after-restart-off' $shimBody
    $r = Invoke-WithPath $offDir { & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force', '-SkipSafetyBackup') }
    $hk = Read-LaiState -Path $holdFile
    $pol = Invoke-DockerText @('inspect', '-f', '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}', 'open-webui')
    $kept = @(@($hk['Containers']) | Where-Object { $_ -and $_['Policy'] -eq 'always' }).Count -gt 0
    Assert-That ($r.Code -ne 0 -and ($pol -eq 'running always' -or $kept)) "cut off with auto-restart off ($pol): a hold already records the original policy (hold: $($hk['Reason']))"
    $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force', '-SkipSafetyBackup')
    Assert-That ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $holdFile) -and (Invoke-DockerText @('inspect', '-f', '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}', 'open-webui')) -eq 'running always') "running the restore again finishes it, auto-restart back on (exit $($r.Code))"

    Write-Host "`n=== 5f. a restore whose 'docker stop' fails puts the container back and leaves no hold ===" -ForegroundColor Cyan
    # The data is never touched: the container must end running with its policy, and no hold may
    # keep Start again, backups and updates refusing.
    $shimBody = @'
#!/bin/sh
case " $* " in *' stop '*) exit 1;; esac
exec 'REALDOCKER' "$@"
'@
    $stopDir = New-DockerShim 'fail-stop' $shimBody
    $r = Invoke-WithPath $stopDir { & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force', '-SkipSafetyBackup') }
    $pol = Invoke-DockerText @('inspect', '-f', '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}', 'open-webui')
    Assert-That ($r.Code -ne 0 -and -not (Test-Path -LiteralPath $holdFile) -and $pol -eq 'running always') "failed stop: exit $($r.Code), container '$pol', hold left: $(Test-Path -LiteralPath $holdFile)"

    Write-Host "`n=== 5g. a restore puts this install's safety settings back on the restored data ===" -ForegroundColor Cyan
    # An old backup brings back the presets and admin settings of its day. The stand-in for that: the
    # sandbox's Open WebUI (the one step 5 of the restore talks to) has them switched on first.
    # One sign-in for the whole step: Open WebUI rate-limits them.
    $sb = 'http://127.0.0.1:3000'
    $tok = Connect-LaiWebUI -BaseUrl $sb -Email 'admin@localhost' -Password 'Test-Password-123'
    $presetRaw = Get-LaiWebUIModel -BaseUrl $sb -Token $tok -Id 'local-main'
    Assert-That ([bool]$presetRaw) 'setup: the sandbox Open WebUI has the local-main preset'
    if ($presetRaw) {
        $getPreset = { Get-LaiWebUIModel -BaseUrl $sb -Token $tok -Id 'local-main' }
        $getSignup = { (Invoke-LaiApi -Uri "$sb/api/v1/auths/admin/config" -Token $tok).ENABLE_SIGNUP }
        $presetWas = ConvertTo-LaiHashtable $presetRaw
        $signupWas = [bool](& $getSignup)
        $otherWas = [bool](Get-LaiWebUIModel -BaseUrl $sb -Token $tok -Id 'official-standin')
        try {
            $old = ConvertTo-LaiHashtable $presetRaw
            foreach ($set in 'builtinTools', 'capabilities') { if ($old['meta'][$set] -isnot [hashtable]) { $old['meta'][$set] = @{} } }
            $old['meta']['builtinTools']['chats'] = $true
            $old['meta']['builtinTools']['code_interpreter'] = $true
            $old['meta']['capabilities']['code_interpreter'] = $true
            $old['meta']['defaultFeatureIds'] = @('web_search')
            foreach ($form in $old, $presetWas) { if ($null -eq $form['params']) { $form['params'] = @{} } }
            Set-LaiWebUIModel -BaseUrl $sb -Token $tok -Model $old | Out-Null
            Set-LaiWebUIAdminConfig -BaseUrl $sb -Token $tok -Changes @{ ENABLE_SIGNUP = $true } | Out-Null
            $pm = (& $getPreset).meta
            Assert-That ($pm.builtinTools.chats -eq $true -and $pm.builtinTools.code_interpreter -eq $true -and $pm.capabilities.code_interpreter -eq $true -and @($pm.defaultFeatureIds) -contains 'web_search' -and (& $getSignup) -eq $true) 'setup: as in an old backup, the preset has past-chat search, code execution and unasked web search on, and sign-up is on'
            # On this run the Ollama connection cannot be set (in real life: an error from Open WebUI
            # after a good sign-in). That is no reason to leave the safety settings as they came.
            $env:LOCALAI_TEST_FAIL_OLLAMA_URL = '1'
            try { $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force', '-SkipSafetyBackup') } finally { $env:LOCALAI_TEST_FAIL_OLLAMA_URL = '' }
            $after = & $getPreset
            $pm = $after.meta
            Assert-That ($r.Code -eq 0 -and $pm.builtinTools.chats -eq $false) "after a restore the preset's model can no longer search and read past chats (exit $($r.Code), chats '$($pm.builtinTools.chats)')"
            Assert-That ($pm.builtinTools.code_interpreter -eq $false -and $pm.capabilities.code_interpreter -eq $false) "code execution is off again on the preset (tool '$($pm.builtinTools.code_interpreter)', capability '$($pm.capabilities.code_interpreter)')"
            Assert-That (@($pm.defaultFeatureIds | Where-Object { $_ }).Count -eq 0) "an uncensored preset searches the web only when asked again (on by default: '$(@($pm.defaultFeatureIds) -join ',')')"
            Assert-That ((& $getSignup) -eq $false) 'sign-up is off again'
            Assert-That ($r.Text -match "Re-applied this install's safety settings.*sign-up off; \d+ toolkit preset\(s\) checked.*Local Main \(past-chat search, code execution, on by default: web_search\)" -and $r.Text -notmatch 'were not put back') 'the restore says what it re-applied, preset by preset, and how many presets it checked'
            Assert-That ($r.Text -match "Could not re-apply this install's Ollama connection .*Test hook" -and $r.Text -notmatch 'Could not sign in') 'an Ollama connection that could not be set is reported as that, not as a failed sign-in (and the safety settings above were still put back)'
            Assert-That ([string]$after.name -eq [string]$presetWas['name'] -and [string]$pm.description -eq [string]$presetWas['meta']['description'] -and [string]$after.params.system -eq [string]$presetWas['params']['system']) 'everything else on the preset is kept (name, description, system prompt)'
            Assert-That ([bool](Get-LaiWebUIModel -BaseUrl $sb -Token $tok -Id 'official-standin') -eq $otherWas) 'a catalog preset the restored data does not have is not created'
            # None of the toolkit's presets in the restored data (here: a catalog of one preset this
            # Open WebUI does not have). No preset was looked at, so nothing may say they are fine.
            $goneCatalog = Join-Path $aiRoot 'gone-catalog.psd1'
            Set-Content -LiteralPath $goneCatalog -Encoding UTF8 -Value "@{ DefaultPreset = 'lai-gone'; ContextCandidates = @(8192); Models = @(@{ Key = 'gone'; Display = 'Gone'; Preset = 'lai-gone' }) }"
            $catalogWas = $env:LOCALAI_TEST_CATALOG; $env:LOCALAI_TEST_CATALOG = $goneCatalog
            try { $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force', '-SkipSafetyBackup') } finally { $env:LOCALAI_TEST_CATALOG = $catalogWas; Remove-Item -LiteralPath $goneCatalog -Force -ErrorAction SilentlyContinue }
            Assert-That ($r.Code -eq 0 -and $r.Text -match "were not put back: sign-up is off again, but none of the toolkit's presets is in the restored data.*run Start menu > Local AI - Update toolkit" -and $r.Text -notmatch "Re-applied this install's safety settings") "restored data with none of the toolkit's presets: the restore says no preset was checked and how to set them up, not that all is well (exit $($r.Code))"
        } finally {
            # Never leave the shared sandbox Open WebUI with these on.
            try {
                Set-LaiWebUIModel -BaseUrl $sb -Token $tok -Model $presetWas | Out-Null
                Set-LaiWebUIAdminConfig -BaseUrl $sb -Token $tok -Changes @{ ENABLE_SIGNUP = $signupWas } | Out-Null
            } catch { Write-Host "  could not put the sandbox preset and sign-up back: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }

    Write-Host "`n=== 6. admin password rotation (real Open WebUI) ===" -ForegroundColor Cyan
    $credPath = Join-Path (Join-Path $aiRoot 'Secrets') 'openwebui-admin.json'
    $r = & $runScript 'Set-OpenWebUIPassword.ps1' @('-NewPassword', 'Rotated-Password-456', '-Quiet')
    $stored = (Get-Content -Encoding UTF8 -LiteralPath $credPath -Raw | ConvertFrom-Json).password
    Assert-That ($r.Code -eq 0 -and $stored -eq 'Rotated-Password-456') "rotation stores the new password (exit $($r.Code))"
    Assert-That (-not (Test-Path -LiteralPath (Join-Path (Join-Path $aiRoot 'Secrets') 'openwebui-admin.pending.json'))) 'no pending copy left after success'
    Assert-That ([bool](Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email 'admin@localhost' -Password 'Rotated-Password-456')) 'Open WebUI accepts the new password'
    $r = & $runScript 'Set-OpenWebUIPassword.ps1' @('-NewPassword', 'Test-Password-123', '-Quiet')
    Assert-That ($r.Code -eq 0) 'rotated back for the other suites'
    # An earlier run was cut off after Open WebUI applied the change: only the pending file knows it.
    $pendingPath = Join-Path (Join-Path $aiRoot 'Secrets') 'openwebui-admin.pending.json'
    $t = Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email 'admin@localhost' -Password 'Test-Password-123'
    Invoke-LaiApi -Method POST -Uri 'http://127.0.0.1:3000/api/v1/auths/update/password' -Token $t -Body @{ password = 'Test-Password-123'; new_password = 'Rotated-Password-789' } | Out-Null
    ConvertTo-Json @{ email = 'admin@localhost'; password = 'Rotated-Password-789' } | Set-Content -LiteralPath $pendingPath -Encoding UTF8
    $r = & $runScript 'Set-OpenWebUIPassword.ps1' @('-NewPassword', 'Test-Password-123', '-Quiet')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'had gone through' -and -not (Test-Path -LiteralPath $pendingPath)) "interrupted change found via the pending file, then rotated (exit $($r.Code))"
    # ...and one where the change never happened: the pending file is just dropped.
    ConvertTo-Json @{ email = 'admin@localhost'; password = 'Never-Applied-000' } | Set-Content -LiteralPath $pendingPath -Encoding UTF8
    $r = & $runScript 'Set-OpenWebUIPassword.ps1' @('-NewPassword', 'Test-Password-123', '-Quiet')
    Assert-That ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $pendingPath) -and (Get-Content -Encoding UTF8 -LiteralPath $credPath -Raw | ConvertFrom-Json).password -eq 'Test-Password-123') 'a pending password that never applied is dropped'

    Write-Host "`n=== 7. backup deep check: a real SQLite database, then a corrupted one ===" -ForegroundColor Cyan
    # Any local image with python3 + sqlite3 can do the check; SearXNG's is in the sandbox and in CI.
    $composeText = Get-Content -Encoding UTF8 -Raw (Join-Path (Join-Path $src 'stack') 'docker-compose.yml')
    $verifyImage = 'searxng/searxng:' + [regex]::Match($composeText, 'searxng/searxng:\$\{SEARXNG_VERSION:-([^}]+)\}').Groups[1].Value
    $dbDir = Join-Path $Work 'deepdb'
    New-Item -ItemType Directory -Force -Path $dbDir | Out-Null
    & python3 -c "import sqlite3;c=sqlite3.connect('$dbDir/webui.db');c.execute('create table user(id text)');c.execute('create table chat(id text, body text)');c.executemany('insert into user values(?)',[(str(i),) for i in range(3)]);c.executemany('insert into chat values(?,?)',[(str(i),'x'*3000) for i in range(40)]);c.commit();c.close()"
    Invoke-DockerText @('volume', 'create', 'lai-deep-test') | Out-Null
    Invoke-DockerText @('run', '--rm', '-v', 'lai-deep-test:/d', '-v', "${dbDir}:/src:ro", 'alpine:3.20', 'cp', '/src/webui.db', '/d/webui.db') | Out-Null
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-deep-test', '-Container', 'lai-no-such-container', '-Tag', 'deeptest', '-NoPrune', '-VerifyImage', $verifyImage)
    Assert-That ($b.Code -eq 0 -and (Get-Content -Encoding UTF8 -Raw (Join-Path (Join-Path $aiRoot 'Logs') 'backup.log')) -match 'database OK \(3 users, 40 chats\)') "deep check opens the archived database: 3 users, 40 chats (exit $($b.Code))"
    # Overwrite part of a data page in the middle: the file still opens, the integrity check fails.
    Invoke-DockerText @('run', '--rm', '-v', 'lai-deep-test:/d', 'alpine:3.20', 'sh', '-c', 'dd if=/dev/urandom of=/d/webui.db bs=1 seek=40000 count=3000 conv=notrunc 2>/dev/null') | Out-Null
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-deep-test', '-Container', 'lai-no-such-container', '-Tag', 'deeptest', '-NoPrune', '-VerifyImage', $verifyImage)
    $bad = @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-deeptest-CORRUPT.tar.gz')
    Assert-That ($b.Code -ne 0 -and $bad.Count -eq 1 -and $b.Text -match 'failed the SQLite check') "a damaged database is caught and kept as -CORRUPT (exit $($b.Code))"
    Assert-That (@(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-deeptest.tar.gz').Count -eq 1) 'only the good archive keeps a normal name'
    # Corrupt archives pile up night after night: two are kept for inspection, older ones go.
    # An uninstall's final backup is kept even when quarantined.
    Set-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Backups') 'open-webui-20190101-000000-pre-uninstall-CORRUPT.tar.gz') -Value 'x'
    (Get-Item -LiteralPath (Join-Path (Join-Path $aiRoot 'Backups') 'open-webui-20190101-000000-pre-uninstall-CORRUPT.tar.gz')).LastWriteTime = (Get-Date).AddDays(-60)
    foreach ($i in 1..3) { Set-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Backups') ("open-webui-2020010$i-000000-old-CORRUPT.tar.gz")) -Value 'x'; (Get-Item -LiteralPath (Join-Path (Join-Path $aiRoot 'Backups') ("open-webui-2020010$i-000000-old-CORRUPT.tar.gz"))).LastWriteTime = (Get-Date).AddDays(-30 + $i) }
    Start-Sleep -Seconds 1
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-deep-test', '-Container', 'lai-no-such-container', '-Tag', 'deeptest', '-NoPrune', '-VerifyImage', $verifyImage)
    $corNow = @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-CORRUPT.tar.gz' | ForEach-Object { $_.Name })
    Assert-That (Test-Path -LiteralPath (Join-Path (Join-Path $aiRoot 'Backups') 'open-webui-20190101-000000-pre-uninstall-CORRUPT.tar.gz')) "an uninstall's quarantined final backup is never deleted by the cap"
    $corNow = @($corNow | Where-Object { $_ -notlike '*-pre-uninstall-CORRUPT*' })
    Assert-That ($b.Code -ne 0 -and $corNow.Count -eq 2 -and $corNow -contains 'open-webui-20200101-000000-old-CORRUPT.tar.gz') "two quarantined archives are kept: the oldest (closest to the last good state) and the newest ($($corNow -join ', '))"
    # An empty webui.db (0 bytes: integrity_check says ok, but there are no tables) is not a backup.
    Invoke-DockerText @('volume', 'create', 'lai-ok-test') | Out-Null
    Invoke-DockerText @('run', '--rm', '-v', 'lai-ok-test:/d', 'alpine:3.20', 'sh', '-c', ': > /d/webui.db') | Out-Null
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-ok-test', '-Container', 'lai-no-such-container', '-Tag', 'emptydb', '-NoPrune', '-VerifyImage', $verifyImage)
    Assert-That ($b.Code -ne 0 -and @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-emptydb-CORRUPT.tar.gz').Count -eq 1 -and @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-emptydb.tar.gz').Count -eq 0) "an empty database is quarantined, never kept as a normal backup (exit $($b.Code))"
    Invoke-DockerText @('volume', 'rm', 'lai-ok-test') | Out-Null
    # A deep check that cannot run at all (here: an image without python3) says nothing about the data.
    Invoke-DockerText @('volume', 'create', 'localai-verify-20200101000000') | Out-Null
    Invoke-DockerText @('volume', 'create', 'lai-ok-test') | Out-Null
    Invoke-DockerText @('run', '--rm', '-v', 'lai-ok-test:/d', '-v', "${dbDir}:/src:ro", 'alpine:3.20', 'cp', '/src/webui.db', '/d/webui.db') | Out-Null
    # Downloaded document-search and speech models in the volume: left out of the archive.
    Invoke-DockerText @('run', '--rm', '-v', 'lai-ok-test:/d', 'alpine:3.20', 'sh', '-c', 'mkdir -p /d/cache/embedding/models/BAAI /d/cache/whisper/models /d/uploads && echo m > /d/cache/embedding/models/BAAI/weights && echo w > /d/cache/whisper/models/small && echo u > /d/uploads/notes.pdf') | Out-Null
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-ok-test', '-Container', 'lai-no-such-container', '-Tag', 'nocheck', '-NoPrune', '-VerifyImage', 'alpine:3.20')
    $nc = Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-nocheck.tar.gz' | Select-Object -First 1
    $ncList = if ($nc) { Invoke-DockerText @('run', '--rm', '-v', "$($nc.DirectoryName):/b:ro", 'alpine:3.20', 'tar', 'tzf', "/b/$($nc.Name)") } else { '' }
    Assert-That ($ncList -match 'uploads/notes\.pdf' -and $ncList -notmatch 'cache/embedding/models/BAAI' -and $ncList -notmatch 'cache/whisper/models/small') 'the archive keeps uploads but not the downloaded models (re-fetched after a restore)'
    Assert-That ($b.Code -eq 0 -and $b.Text -match 'Deep check could not run' -and @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-nocheck.tar.gz').Count -eq 1 -and @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-nocheck-CORRUPT.tar.gz').Count -eq 0) "a deep check that cannot run is a warning, not a CORRUPT archive (exit $($b.Code))"
    Assert-That ((Invoke-DockerText @('volume', 'ls', '-q', '--filter', 'name=localai-verify-')) -eq '') 'scratch volumes left by a killed deep check are swept'
    # The backup counts nights whose check could not run (the watch fails after 3) and resets on a good one.
    $bsPath = Join-Path $aiRoot 'backup-state.json'
    $bs1 = Read-LaiState -Path $bsPath
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-ok-test', '-Container', 'lai-no-such-container', '-Tag', 'nocheck', '-NoPrune', '-VerifyImage', 'alpine:3.20')
    $bs2 = Read-LaiState -Path $bsPath
    Assert-That ($bs1['deepCheck'] -eq 'could-not-run' -and [int]$bs2['deepCheckSkips'] -eq [int]$bs1['deepCheckSkips'] + 1) "nights without a database check are counted ($($bs1['deepCheckSkips']) -> $($bs2['deepCheckSkips']))"
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-ok-test', '-Container', 'lai-no-such-container', '-Tag', 'nocheck', '-NoPrune', '-VerifyImage', $verifyImage)
    $bs3 = Read-LaiState -Path $bsPath
    Assert-That ($bs3['deepCheck'] -eq 'ok' -and [int]$bs3['deepCheckSkips'] -eq 0) 'and the count resets after a check that ran'
    # A check image that is not on this PC is counted too (it was skipped silently, night after night).
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-ok-test', '-Container', 'lai-no-such-container', '-Tag', 'noimage', '-NoPrune', '-VerifyImage', 'lai-no-such-image:0')
    $bs4 = Read-LaiState -Path $bsPath
    Assert-That ($b.Code -eq 0 -and $b.Text -match 'Deep check skipped' -and [int]$bs4['deepCheckSkips'] -eq 1) "a missing check image counts toward the watch's 3-night alarm (exit $($b.Code), count $($bs4['deepCheckSkips']))"
    # .env names a version that was never downloaded (an update cut off mid-download): the image
    # Open WebUI runs does the check instead.
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-ok-test', '-Container', 'open-webui', '-NoStop', '-Tag', 'noimage', '-NoPrune')
    Assert-That ($b.Code -eq 0 -and $b.Text -match 'using the image Open WebUI runs \(alpine:') "with the .env image missing, the check uses the image Open WebUI runs (exit $($b.Code))"

    Write-Host "`n=== 7b. a wiped Open WebUI (tables, no rows) is not a good backup ===" -ForegroundColor Cyan
    # What Docker Desktop's 'Purge data' leaves: Open WebUI starts over on a new, empty volume. Kept as
    # normal backups, three such nights became the protected newest three and the prune deleted every
    # real archive. An install folder of its own here: its own Backups and backup-state.json.
    $wipeRoot = Join-Path $Work 'wipe'
    $wipeBk = Join-Path $wipeRoot 'Backups'
    $wipeMirror = Join-Path $Work 'wipe-mirror'
    $noRowsDir = Join-Path $Work 'norowsdb'
    $fewRowsDir = Join-Path $Work 'fewrowsdb'
    foreach ($d in $wipeBk, $wipeMirror, $noRowsDir, $fewRowsDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    & python3 -c "import sqlite3;c=sqlite3.connect('$noRowsDir/webui.db');c.execute('create table user(id text)');c.execute('create table chat(id text, body text)');c.commit();c.close()"
    # The wiped install used again: its one user and 4 chats (a tenth of the 40, so not 'under a tenth').
    & python3 -c "import sqlite3;c=sqlite3.connect('$fewRowsDir/webui.db');c.execute('create table user(id text)');c.execute('create table chat(id text, body text)');c.execute('insert into user values(?)',('0',));c.executemany('insert into chat values(?,?)',[(str(i),'x') for i in range(4)]);c.commit();c.close()"
    $rowsSize = [string](Get-Item -LiteralPath (Join-Path $dbDir 'webui.db')).Length
    $wipeState = Join-Path $wipeRoot 'backup-state.json'
    # The volume doubles as deep research's on one night (its archive only asks for that folder).
    $putDb = { param([string]$Dir) Invoke-DockerText @('run', '--rm', '-v', 'lai-wipe-test:/d', '-v', "${Dir}:/src:ro", 'alpine:3.20', 'sh', '-c', 'cp /src/webui.db /d/webui.db && mkdir -p /d/encrypted_databases') | Out-Null }
    $liveSize = { Invoke-DockerText @('run', '--rm', '-v', 'lai-wipe-test:/d', 'alpine:3.20', 'stat', '-c', '%s', '/d/webui.db') }
    $plant = { param([string]$Path, [int]$DaysOld) Set-Content -LiteralPath $Path -Value 'old'; (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$DaysOld) }
    $oldLeft = { param([string]$Dir, [string]$Kind) @(Get-ChildItem -LiteralPath $Dir -Filter "$Kind-2020010*-000000.tar.gz").Count }
    $researchSince = { param([string]$Dir) @(Get-ChildItem -LiteralPath $Dir -Filter 'deep-research-*.tar.gz' | Where-Object { $_.Name -notlike 'deep-research-2020010*' }).Count }
    $researchOk = 'Deep research backup .*deep-research-\d{8}-\d{6}\.tar\.gz \('
    # '' and $false for a value that is not there: a missing key is then a failed assertion, not an error.
    $leafOf = { param($Path) if ($Path) { Split-Path -Leaf ([string]$Path) } else { '' } }
    $isFile = { param($Path) [bool]$Path -and (Test-Path -LiteralPath ([string]$Path)) }
    $runWipe = {
        # Nothing on standard input: a question (Read-Host) gets no answer instead of waiting for one.
        param([string]$Name, [string[]]$Arguments)
        $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $o = $null | & pwsh -NoProfile -File (Join-Path $src $Name) -AIRoot $wipeRoot -Volume 'lai-wipe-test' -Container 'lai-no-such-container' @Arguments 2>&1 | ForEach-Object { "$_" }
        $c = $LASTEXITCODE; $ErrorActionPreference = $prevPref
        return [pscustomobject]@{ Code = $c; Text = ($o -join "`n") }
    }
    $night = @('-VerifyImage', $verifyImage, '-RetentionDays', '1', '-Mirror', $wipeMirror)
    $noResearch = @('-ResearchVolume', 'lai-no-such-volume')
    $withResearch = @('-ResearchVolume', 'lai-wipe-test', '-ResearchContainer', 'lai-no-such-container')
    try {
        Invoke-DockerText @('volume', 'rm', '-f', 'lai-wipe-test') | Out-Null
        Invoke-DockerText @('volume', 'create', 'lai-wipe-test') | Out-Null
        & $putDb $dbDir
        $b = & $runWipe 'Backup-OpenWebUI.ps1' ($night + $noResearch)
        $ws = Read-LaiState -Path $wipeState
        $rows = @(Get-ChildItem -LiteralPath $wipeBk -Filter 'open-webui-*.tar.gz')
        $rowsName = 'none'; if ($rows.Count -eq 1) { $rowsName = $rows[0].Name }
        Assert-That ($b.Code -eq 0 -and $rows.Count -eq 1 -and [int]$ws['goodUsers'] -eq 3 -and [int]$ws['goodChats'] -eq 40 -and (& $leafOf $ws['goodArchive']) -eq $rowsName -and -not $ws.ContainsKey('emptied')) "a night with rows records what a good backup looks like: 3 users, 40 chats and its archive (exit $($b.Code), $($ws['goodUsers']) users, $($ws['goodChats']) chats)"
        # Old nightly archives here and in the mirror, and old deep research ones: a prune takes all but
        # the newest three. And an -EMPTY archive left by an earlier wipe (only two of those are kept).
        foreach ($d in 1..4) {
            foreach ($dir in $wipeBk, $wipeMirror) { & $plant (Join-Path $dir ('open-webui-2020010{0}-000000.tar.gz' -f $d)) (60 - $d) }
            & $plant (Join-Path $wipeBk ('deep-research-2020010{0}-000000.tar.gz' -f $d)) (60 - $d)
        }
        $oldEmpty = Join-Path $wipeBk 'open-webui-20200105-000000-EMPTY.tar.gz'
        & $plant $oldEmpty 50

        & $putDb $noRowsDir
        $b = & $runWipe 'Backup-OpenWebUI.ps1' ($night + $noResearch)
        $e1 = (Read-LaiState -Path $wipeState)['emptied']; if ($e1 -isnot [hashtable]) { $e1 = @{} }
        Assert-That ($b.Code -eq 0 -and $b.Text -match 'looks wiped: 0 users and 0 chats now, 3 and 40 at the last good backup' -and $b.Text -match '-AcceptEmpty' -and $b.Text -notmatch 'database OK') "the night after a wipe: a plain warning with the counts before and now and the way to accept them, and no 'database OK' (exit $($b.Code))"
        Assert-That ($e1['at'] -and $e1.ContainsKey('users') -and [int]$e1['users'] -eq 0 -and [int]$e1['chats'] -eq 0 -and [int]$e1['hadUsers'] -eq 3 -and [int]$e1['hadChats'] -eq 40) "backup-state.json: emptied is set, with the counts now (0 users, 0 chats) and before (3 and 40) and when it was first seen ($($e1['at']))"
        Assert-That ((& $leafOf $e1['lastGood']) -eq $rowsName -and (& $isFile $e1['lastGood']) -and (& $leafOf $e1['archive']) -like '*-EMPTY.tar.gz' -and (& $isFile $e1['archive'])) "emptied names the last good archive and this night's -EMPTY one, by full path ($(& $leafOf $e1['archive']))"

        # A tagged run meanwhile (the rollback point of an update is found by its name): it judges
        # nothing and keeps its name. It cannot tell the data is wiped, so only the mark in
        # backup-state.json keeps it from pruning.
        $b = & $runWipe 'Backup-OpenWebUI.ps1' ($night + $noResearch + @('-Tag', 'x'))
        $ws = Read-LaiState -Path $wipeState
        $ex = $ws['emptied']; if ($ex -isnot [hashtable]) { $ex = @{} }
        Assert-That ($b.Code -eq 0 -and @(Get-ChildItem -LiteralPath $wipeBk -Filter 'open-webui-*-x.tar.gz').Count -eq 1 -and @(Get-ChildItem -LiteralPath $wipeBk -Filter '*-x-EMPTY*').Count -eq 0 -and (& $leafOf $ex['archive']) -eq (& $leafOf $e1['archive']) -and [int]$ws['goodUsers'] -eq 3 -and [int]$ws['goodChats'] -eq 40 -and (& $leafOf $ws['goodArchive']) -eq $rowsName) "a tagged run while the data looks wiped keeps its name (never -EMPTY) and changes neither the mark nor the good counts (exit $($b.Code))"
        Assert-That ($b.Text -match 'Old backups are not pruned' -and (& $oldLeft $wipeBk 'open-webui') -eq 4 -and (& $oldLeft $wipeMirror 'open-webui') -eq 4) "and it prunes nothing, here or in the mirror, and says why ($(& $oldLeft $wipeBk 'open-webui') and $(& $oldLeft $wipeMirror 'open-webui') of 4 old)"
        # The run at sign-in: this night's backup was made, as an -EMPTY one, so there is nothing to
        # catch up. (The archive with the rows is dated before the due time, so only that one counts.)
        # Dated through a container, like the rollback archive in part 3: Docker wrote the archive,
        # so on Linux it belongs to root and this test may not set its time itself (the attempt
        # ended the suite here). The time is given in UTC, which is the clock of the container.
        if ($rows.Count -eq 1) {
            $rowsDated = (Get-Date).ToUniversalTime().AddHours(-3).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            Invoke-DockerText @('run', '--rm', '-v', "${wipeBk}:/b", 'alpine:3.20', 'touch', '-d', $rowsDated, "/b/$rowsName") | Out-Null
        }
        $rowsNow = @(Get-ChildItem -LiteralPath $wipeBk -Filter $rowsName)
        $rowsHours = -1
        if ($rowsNow.Count -eq 1) { $rowsHours = [math]::Round(((Get-Date).ToUniversalTime() - $rowsNow[0].LastWriteTimeUtc).TotalHours, 1) }
        $b = & $runWipe 'Backup-OpenWebUI.ps1' ($night + $noResearch + @('-DailyAt', (Get-Date).AddHours(-1).ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)))
        Assert-That ($b.Code -eq 0 -and $rowsHours -gt 2 -and $b.Text -match 'Nothing to do: the backup due at .*-EMPTY\.tar\.gz') "the sign-in run does nothing when the night's backup is there as an -EMPTY one (exit $($b.Code); the archive with the rows is dated $rowsHours h back)"

        # The second night: deep research is archived too (the purge that emptied Open WebUI emptied it).
        $b = & $runWipe 'Backup-OpenWebUI.ps1' ($night + $withResearch)
        $ws = Read-LaiState -Path $wipeState
        $e2 = $ws['emptied']; if ($e2 -isnot [hashtable]) { $e2 = @{} }
        $empties = @(Get-ChildItem -LiteralPath $wipeBk -Filter 'open-webui-*-EMPTY.tar.gz' | Sort-Object LastWriteTime | ForEach-Object { $_.Name })  # lai-ok: objects
        Assert-That ($b.Code -eq 0 -and (& $oldLeft $wipeBk 'open-webui') -eq 4 -and (Test-Path -LiteralPath (Join-Path $wipeBk $rowsName))) "two empty nights: nothing pruned in Backups, the four old archives and the one with the rows are all there (exit $($b.Code), $(& $oldLeft $wipeBk 'open-webui') of 4 old)"
        $mirrorEmpties = @(Get-ChildItem -LiteralPath $wipeMirror -Filter 'open-webui-*-EMPTY.tar.gz' | ForEach-Object { $_.Name })
        Assert-That ((& $oldLeft $wipeMirror 'open-webui') -eq 4 -and (Test-Path -LiteralPath (Join-Path $wipeMirror $rowsName)) -and $mirrorEmpties.Count -eq 2 -and $mirrorEmpties -contains (& $leafOf $e2['archive'])) "two empty nights: nothing pruned in the mirror, and each -EMPTY archive is copied there (what the data is now has a copy off this PC; $(& $oldLeft $wipeMirror 'open-webui') of 4 old, $($mirrorEmpties.Count) -EMPTY)"
        Assert-That ($b.Text -match $researchOk -and (& $oldLeft $wipeBk 'deep-research') -eq 4) "old deep research archives are not pruned either while the data looks wiped ($(& $oldLeft $wipeBk 'deep-research') of 4 old)"
        Assert-That ($e2['at'] -and [string]$e2['at'] -eq [string]$e1['at'] -and (& $leafOf $e2['archive']) -ne (& $leafOf $e1['archive']) -and [int]$e2['hadChats'] -eq 40 -and [int]$ws['goodUsers'] -eq 3 -and [int]$ws['goodChats'] -eq 40 -and (& $leafOf $ws['goodArchive']) -eq $rowsName) "the second empty night keeps emptied (first seen $($e2['at']), the new archive) and the good counts: an empty database never becomes the normal one"
        Assert-That ($empties.Count -eq 2 -and $empties[0] -eq (Split-Path -Leaf $oldEmpty) -and $empties[1] -eq (& $leafOf $e2['archive']) -and $empties -notcontains (& $leafOf $e1['archive'])) "two -EMPTY archives are kept, the oldest and the newest ($($empties -join ', '))"

        # The third night: the wiped install is used again. One user and 4 chats are over the bar that
        # set the mark, but they are not the 3 and 40 being back.
        & $putDb $fewRowsDir
        $b = & $runWipe 'Backup-OpenWebUI.ps1' ($night + $withResearch)
        $ws = Read-LaiState -Path $wipeState
        $e3 = $ws['emptied']; if ($e3 -isnot [hashtable]) { $e3 = @{} }
        Assert-That ($b.Code -eq 0 -and $b.Text -match 'looks wiped: 1 users and 4 chats now, 3 and 40 at the last good backup' -and $b.Text -notmatch 'data is back' -and $e3['at'] -and [string]$e3['at'] -eq [string]$e1['at'] -and [int]$e3['chats'] -eq 4 -and (& $leafOf $e3['archive']) -like '*-EMPTY.tar.gz' -and (& $isFile $e3['archive'])) "a wiped install that is used again (1 user, 4 chats) is not the data being back: an -EMPTY night again, the mark stays (exit $($b.Code))"
        Assert-That ([int]$ws['goodUsers'] -eq 3 -and [int]$ws['goodChats'] -eq 40 -and (& $leafOf $ws['goodArchive']) -eq $rowsName -and (& $oldLeft $wipeBk 'open-webui') -eq 4 -and (& $oldLeft $wipeMirror 'open-webui') -eq 4) "and its counts do not become the good ones, nothing is pruned ($($ws['goodUsers']) users, $($ws['goodChats']) chats; $(& $oldLeft $wipeBk 'open-webui') and $(& $oldLeft $wipeMirror 'open-webui') of 4 old)"
        $mirrorEmpties = @(Get-ChildItem -LiteralPath $wipeMirror -Filter 'open-webui-*-EMPTY.tar.gz' | ForEach-Object { $_.Name })
        Assert-That ($mirrorEmpties.Count -eq 2 -and $mirrorEmpties -contains (& $leafOf $e1['archive']) -and $mirrorEmpties -contains (& $leafOf $e3['archive'])) "the mirror keeps two -EMPTY archives too, the oldest and the newest ($($mirrorEmpties -join ', '))"
        $research3 = $b.Text -match $researchOk

        # A night that cannot tell (no database check): its archive keeps a nightly name although it
        # holds the wiped data, nothing is pruned, and -AcceptEmpty has no counts to accept.
        $b = & $runWipe 'Backup-OpenWebUI.ps1' ($night + $withResearch + @('-SkipDeepVerify', '-AcceptEmpty'))
        $ws = Read-LaiState -Path $wipeState
        $blind = @(Get-ChildItem -LiteralPath $wipeBk -Filter 'open-webui-*.tar.gz' | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.Name -ne $rowsName -and $_.Name -notlike 'open-webui-2020010*' })
        Assert-That ($b.Code -eq 0 -and $blind.Count -eq 1 -and $ws.ContainsKey('emptied') -and [int]$ws['goodChats'] -eq 40 -and $b.Text -match '-AcceptEmpty was not applied' -and $b.Text -match 'Old backups are not pruned' -and (& $oldLeft $wipeBk 'open-webui') -eq 4 -and (& $oldLeft $wipeMirror 'open-webui') -eq 4) "a night without the database check while the data looks wiped: nothing pruned, the mark stays, and -AcceptEmpty says it was not applied (exit $($b.Code))"
        # Three nights of deep research archives since the mark: the newest two are kept, the old ones all stay.
        Assert-That ($research3 -and $b.Text -match $researchOk -and (& $researchSince $wipeBk) -eq 2 -and (& $researchSince $wipeMirror) -eq 2 -and (& $oldLeft $wipeBk 'deep-research') -eq 4) "deep research archives made since the data looked wiped are capped at the newest two, here and in the mirror; none from before goes ($(& $researchSince $wipeBk) and $(& $researchSince $wipeMirror) since, $(& $oldLeft $wipeBk 'deep-research') of 4 old)"

        $r = & $runWipe 'Restore-OpenWebUI.ps1' @('-Force', '-SkipSafetyBackup')
        $live = & $liveSize
        Assert-That ($r.Code -eq 0 -and $r.Text -match ('Restoring ' + [regex]::Escape($rowsName)) -and $live -eq $rowsSize) "a restore without -Archive takes the last good backup, the one with the rows: never an -EMPTY one, and not the newer night that could not tell (exit $($r.Code), webui.db $live bytes, with rows $rowsSize)"
        Assert-That ($r.Text -match 'were not put back: Open WebUI was not running.*run Start menu > Local AI - Update toolkit') 'a restore that could not reach Open WebUI says the safety settings were not re-applied, and how to'
        # (Out of the way: it would be one of the newest three when pruning is on again below.)
        foreach ($dir in $wipeBk, $wipeMirror) { $blind | ForEach-Object { Remove-Item -LiteralPath (Join-Path $dir $_.Name) -Force -ErrorAction SilentlyContinue } }
        $emptyArchive = Join-Path $wipeBk 'none-EMPTY.tar.gz'; if ($e3['archive']) { $emptyArchive = [string]$e3['archive'] }
        $r = & $runWipe 'Restore-OpenWebUI.ps1' @('-Archive', $emptyArchive, '-SkipSafetyBackup')
        Assert-That ($r.Code -ne 0 -and $r.Text -match 'was set aside by the nightly backup' -and $r.Text -notmatch 'Restoring open-webui-' -and (& $liveSize) -eq $rowsSize) "naming an -EMPTY archive warns and asks; with no answer nothing changes (exit $($r.Code))"

        # The restore brought the rows back: the next night clears the mark, and old archives go again.
        $b = & $runWipe 'Backup-OpenWebUI.ps1' ($night + $noResearch)
        $ws = Read-LaiState -Path $wipeState
        Assert-That ($b.Code -eq 0 -and -not $ws.ContainsKey('emptied') -and $b.Text -match 'database OK \(3 users, 40 chats\)' -and (& $leafOf $ws['goodArchive']) -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and (& $leafOf $ws['goodArchive']) -ne $rowsName) "with the rows back, the next backup clears emptied and is the good one (exit $($b.Code))"
        Assert-That ((& $oldLeft $wipeBk 'open-webui') -eq 1 -and (& $oldLeft $wipeMirror 'open-webui') -eq 1 -and -not (Test-Path -LiteralPath $oldEmpty)) "and old archives are pruned again, here and in the mirror ($(& $oldLeft $wipeBk 'open-webui') and $(& $oldLeft $wipeMirror 'open-webui') of 4 old left)"

        # Emptied on purpose: -AcceptEmpty takes the smaller database as the normal one.
        $emptyCount = @(Get-ChildItem -LiteralPath $wipeBk -Filter 'open-webui-*-EMPTY.tar.gz').Count
        & $putDb $noRowsDir
        $b = & $runWipe 'Backup-OpenWebUI.ps1' ($night + $noResearch + @('-AcceptEmpty'))
        $ws = Read-LaiState -Path $wipeState
        Assert-That ($b.Code -eq 0 -and -not $ws.ContainsKey('emptied') -and $ws.ContainsKey('goodUsers') -and [int]$ws['goodUsers'] -eq 0 -and [int]$ws['goodChats'] -eq 0 -and $b.Text -match '-AcceptEmpty: 0 users and 0 chats') "-AcceptEmpty: the empty database counts as the normal one, emptied is not set (exit $($b.Code))"
        Assert-That ((& $leafOf $ws['goodArchive']) -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and (& $isFile $ws['goodArchive']) -and @(Get-ChildItem -LiteralPath $wipeBk -Filter 'open-webui-*-EMPTY.tar.gz').Count -eq $emptyCount) "-AcceptEmpty: the archive keeps a nightly name ($(& $leafOf $ws['goodArchive']))"
    } finally {
        Invoke-DockerText @('volume', 'rm', '-f', 'lai-wipe-test') | Out-Null
    }

    Write-Host "`n=== deep research: nightly archive (paused, not stopped), retention, mirror, restore ===" -ForegroundColor Cyan
    $bk = Join-Path $aiRoot 'Backups'
    $rMirror = Join-Path $aiRoot 'research-mirror'
    $rData = { (Invoke-DockerText @('run', '--rm', '-v', 'lai-research-test:/d', 'alpine:3.20', 'cat', '/d/encrypted_databases/u.db')) }
    try {
        Invoke-DockerText @('rm', '-f', 'lai-research-ct') | Out-Null
        foreach ($v in 'lai-research-test', 'lai-research-bad') { Invoke-DockerText @('volume', 'rm', '-f', $v) | Out-Null; Invoke-DockerText @('volume', 'create', $v) | Out-Null }
        Invoke-DockerText @('run', '--rm', '-v', 'lai-research-test:/d', 'alpine:3.20', 'sh', '-c', 'mkdir /d/encrypted_databases; echo v1 > /d/encrypted_databases/u.db; echo k > /d/.secret_key') | Out-Null
        Invoke-DockerText @('run', '-d', '--name', 'lai-research-ct', '--label', 'lai-test=1', '--restart', 'always', '-v', 'lai-research-test:/data', 'alpine:3.20', 'sleep', '3600') | Out-Null
        $started0 = Invoke-DockerText @('inspect', '-f', '{{.State.StartedAt}}', 'lai-research-ct')
        # Old daily research archives (dated 30 days back): beyond the newest three they go; a
        # pre-uninstall one never does.
        foreach ($i in 1..4) {
            $f = Join-Path $bk ('deep-research-2026010{0}-030000.tar.gz' -f $i)
            Set-Content -LiteralPath $f -Value 'old'; (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddDays(-30 - $i)
        }
        $pu = Join-Path $bk 'deep-research-20260101-020000-pre-uninstall.tar.gz'
        Set-Content -LiteralPath $pu -Value 'old'; (Get-Item -LiteralPath $pu).LastWriteTime = (Get-Date).AddDays(-60)
        $before = @(Get-ChildItem -LiteralPath $bk -Filter 'deep-research-*.tar.gz' | ForEach-Object { $_.Name })
        $rArgs = @('-Volume', 'lai-ok-test', '-Container', 'lai-no-such-container', '-SkipDeepVerify', '-RetentionDays', '7', '-ResearchVolume', 'lai-research-test', '-ResearchContainer', 'lai-research-ct')
        $b = & $runScript 'Backup-OpenWebUI.ps1' ($rArgs + @('-Mirror', $rMirror))
        $made = @(Get-ChildItem -LiteralPath $bk -Filter 'deep-research-*.tar.gz' | Where-Object { $before -notcontains $_.Name })
        $status = Invoke-DockerText @('inspect', '-f', '{{.State.Status}}', 'lai-research-ct')
        $listing = if ($made.Count -eq 1) { Invoke-DockerText @('run', '--rm', '-v', "${bk}:/b:ro", 'alpine:3.20', 'tar', 'tzf', "/b/$($made[0].Name)") } else { '' }
        Assert-That ($b.Code -eq 0 -and $made.Count -eq 1 -and $made[0].Name -match '^deep-research-\d{8}-\d{6}\.tar\.gz$' -and $listing -match 'encrypted_databases/u\.db') "a daily run archives deep research next to Open WebUI (exit $($b.Code), made $($made.Name -join ','))"
        $started1 = Invoke-DockerText @('inspect', '-f', '{{.State.StartedAt}}', 'lai-research-ct')
        Assert-That ($status -eq 'running' -and $started1 -eq $started0 -and $b.Text -notmatch 'left paused') "the research container runs on afterwards: paused, never stopped or restarted (status $status, started $started0 -> $started1)"
        $left = @(Get-ChildItem -LiteralPath $bk -Filter 'deep-research-2026010*-030000.tar.gz' | ForEach-Object { $_.Name })
        Assert-That ($left.Count -eq 2 -and (Test-Path -LiteralPath $pu)) "old research archives beyond the newest three are pruned, the pre-uninstall one kept (left: $($left -join ', '))"
        Assert-That ($made.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $rMirror $made[0].Name))) 'the research archive is mirrored too'
        $bs = Read-LaiState -Path (Join-Path $aiRoot 'backup-state.json')
        Assert-That ($bs['researchOkAt'] -and -not $bs['researchError']) 'backup-state records the research backup'
        # A container an earlier, killed run left paused is woken (docker start would not).
        Invoke-DockerText @('pause', 'lai-research-ct') | Out-Null
        $b = & $runScript 'Backup-OpenWebUI.ps1' ($rArgs + @('-NoMirror'))
        Assert-That ($b.Code -eq 0 -and $b.Text -match 'left paused' -and (Invoke-DockerText @('inspect', '-f', '{{.State.Status}}', 'lai-research-ct')) -eq 'running') "a research container left paused is woken by the next backup (exit $($b.Code))"
        Assert-That (@((Invoke-DockerText @('volume', 'ls', '-q', '--filter', 'name=localai-research-copy-')) -split "`n" | Where-Object { $_ }).Count -eq 0) 'no scratch copy volume is left behind'
        # An uninstall's final backup holds deep research too, and fails when it could not save it
        # (the uninstaller then deletes nothing).
        $b = & $runScript 'Backup-OpenWebUI.ps1' ($rArgs + @('-Tag', 'pre-uninstall', '-NoPrune', '-NoMirror'))
        Assert-That ($b.Code -eq 0 -and @(Get-ChildItem -LiteralPath $bk -Filter 'deep-research-*-pre-uninstall.tar.gz' | Where-Object { $_.FullName -ne $pu }).Count -eq 1) "an uninstall's final backup includes deep research (exit $($b.Code))"
        $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-ok-test', '-Container', 'lai-no-such-container', '-SkipDeepVerify', '-Tag', 'pre-uninstall', '-NoPrune', '-NoMirror', '-ResearchVolume', 'lai-research-bad', '-ResearchContainer', 'lai-no-such-container')
        Assert-That ($b.Code -ne 0 -and $b.Text -match 'must not delete it') "an uninstall's final backup fails when deep research could not be saved (exit $($b.Code))"
        # Tagged runs (a restore's safety copy, before an update) leave deep research alone.
        $n = @(Get-ChildItem -LiteralPath $bk -Filter 'deep-research-*.tar.gz').Count
        $b = & $runScript 'Backup-OpenWebUI.ps1' ($rArgs + @('-Tag', 'before-x', '-NoPrune', '-NoMirror'))
        Assert-That ($b.Code -eq 0 -and @(Get-ChildItem -LiteralPath $bk -Filter 'deep-research-*.tar.gz').Count -eq $n) 'a tagged run makes no research archive'
        # A volume that is not Local Deep Research's: a warning and a recorded error, Open WebUI's backup fine.
        $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-ok-test', '-Container', 'lai-no-such-container', '-SkipDeepVerify', '-NoMirror', '-ResearchVolume', 'lai-research-bad', '-ResearchContainer', 'lai-no-such-container')
        $bs = Read-LaiState -Path (Join-Path $aiRoot 'backup-state.json')
        Assert-That ($b.Code -eq 0 -and $b.Text -match 'Deep research backup failed' -and [string]$bs['researchError'] -match 'encrypted_databases' -and @(Get-ChildItem -LiteralPath $bk -Filter 'incomplete-deep-research-*').Count -eq 0) "a failed research archive is a recorded warning, not a failed backup, and leaves no partial file (exit $($b.Code))"
        # Restore: changed data goes back to the archive; the replaced data is kept as a safety copy.
        Invoke-DockerText @('run', '--rm', '-v', 'lai-research-test:/d', 'alpine:3.20', 'sh', '-c', 'echo v2 > /d/encrypted_databases/u.db') | Out-Null
        $rr = @('-DeepResearch', '-Force', '-ResearchVolume', 'lai-research-test', '-ResearchContainer', 'lai-research-ct')
        $r = & $runScript 'Restore-OpenWebUI.ps1' ($rr + @('-Archive', $made[0].FullName))
        $safetyR = Get-ChildItem -LiteralPath $bk -Filter 'deep-research-*-pre-restore.tar.gz' | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
        $sList = if ($safetyR) { Invoke-DockerText @('run', '--rm', '-v', "${bk}:/b:ro", 'alpine:3.20', 'sh', '-c', "tar xzOf /b/$($safetyR.Name) ./encrypted_databases/u.db") } else { '' }
        Assert-That ($r.Code -eq 0 -and (& $rData) -eq 'v1' -and $sList -eq 'v2') "restore -DeepResearch puts the archive back and keeps the replaced data (exit $($r.Code), now $(& $rData), safety $sList)"
        Assert-That ((Invoke-DockerText @('inspect', '-f', '{{.State.Status}}', 'lai-research-ct')) -eq 'running') 'the research container runs again after the restore'
        Assert-That ((Invoke-DockerText @('inspect', '-f', '{{.HostConfig.RestartPolicy.Name}}', 'lai-research-ct')) -eq 'always') 'its restart policy is back after the restore (off during it)'
        # The swap fails after the old data was replaced: the safety copy goes back.
        Invoke-DockerText @('run', '--rm', '-v', 'lai-research-test:/d', 'alpine:3.20', 'sh', '-c', 'echo v3 > /d/encrypted_databases/u.db') | Out-Null
        $env:LOCALAI_TEST_FAIL_RESEARCH_SWAP = '1'
        try { $r = & $runScript 'Restore-OpenWebUI.ps1' ($rr + @('-Archive', $made[0].FullName)) } finally { $env:LOCALAI_TEST_FAIL_RESEARCH_SWAP = '' }
        Assert-That ($r.Code -ne 0 -and $r.Text -match 'put back' -and (& $rData) -eq 'v3' -and (Invoke-DockerText @('inspect', '-f', '{{.State.Status}}', 'lai-research-ct')) -eq 'running') "a failed swap puts the earlier data back and starts deep research again (exit $($r.Code), data $(& $rData))"
        # Without a safety copy there is nothing to go back to: deep research is kept stopped.
        $env:LOCALAI_TEST_FAIL_RESEARCH_SWAP = '1'
        try { $r = & $runScript 'Restore-OpenWebUI.ps1' ($rr + @('-Archive', $made[0].FullName, '-SkipSafetyBackup')) } finally { $env:LOCALAI_TEST_FAIL_RESEARCH_SWAP = '' }
        Assert-That ($r.Code -ne 0 -and $r.Text -match 'kept stopped' -and (Invoke-DockerText @('inspect', '-f', '{{.State.Status}}', 'lai-research-ct')) -eq 'exited') "with no safety copy a failed swap keeps deep research stopped and says how to finish (exit $($r.Code))"
        Invoke-DockerText @('update', '--restart', 'always', 'lai-research-ct') | Out-Null
        Invoke-DockerText @('start', 'lai-research-ct') | Out-Null
        # An Open WebUI archive is refused before anything changes.
        $r = & $runScript 'Restore-OpenWebUI.ps1' ($rr + @('-Archive', $good.FullName))
        Assert-That ($r.Code -ne 0 -and $r.Text -match 'not a deep research backup' -and (& $rData) -eq 'v1') "an Open WebUI archive is refused, nothing changed (exit $($r.Code))"
        # With no -Archive: the newest daily (or pre-uninstall) research archive.
        $expect = Get-ChildItem -LiteralPath $bk -Filter 'deep-research-*.tar.gz' | Where-Object { $_.Name -match '^deep-research-\d{8}-\d{6}(-pre-uninstall)?\.tar\.gz$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
        $r = & $runScript 'Restore-OpenWebUI.ps1' $rr
        Assert-That ($r.Code -eq 0 -and $expect -and $expect.Name -match 'pre-uninstall' -and $r.Text -match [regex]::Escape($expect.Name)) "without -Archive the newest research archive (daily or an uninstall's) is used: $($expect.Name) (exit $($r.Code))"
    } finally {
        Invoke-DockerText @('rm', '-f', 'lai-research-ct') | Out-Null
        foreach ($v in 'lai-research-test', 'lai-research-bad') { Invoke-DockerText @('volume', 'rm', '-f', $v) | Out-Null }
        Get-ChildItem -LiteralPath $bk -Filter 'deep-research-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $rMirror -Recurse -Force -ErrorAction SilentlyContinue
    }
    Invoke-DockerText @('volume', 'rm', 'lai-ok-test') | Out-Null
    Invoke-DockerText @('volume', 'rm', 'lai-deep-test') | Out-Null
} finally {
    # Never leave the shared sandbox Open WebUI with a changed admin password.
    try {
        $sb = 'http://127.0.0.1:3000'
        try { Connect-LaiWebUI -BaseUrl $sb -Email 'admin@localhost' -Password 'Test-Password-123' | Out-Null }
        catch {
            foreach ($pw in 'Rotated-Password-456', 'Rotated-Password-789') {
                try {
                    $t = Connect-LaiWebUI -BaseUrl $sb -Email 'admin@localhost' -Password $pw
                    Invoke-LaiApi -Method POST -Uri "$sb/api/v1/auths/update/password" -Token $t -Body @{ password = $pw; new_password = 'Test-Password-123' } | Out-Null
                    break
                } catch { Write-Verbose "not $pw" }
            }
            Write-Host '  (sandbox admin password restored)'
        }
    } catch { Write-Host "  could not verify the sandbox admin password: $($_.Exception.Message)" -ForegroundColor Yellow }
    Invoke-DockerText @('compose', '--project-directory', $stack, '-f', (Join-Path $stack 'docker-compose.yml'), 'down') | Out-Null
    Invoke-DockerText @('volume', 'rm', 'open-webui') | Out-Null
}

if ($failures -eq 0) { Write-Host "`nUPDATE WEBUI TEST PASSED" -ForegroundColor Green } else { Write-Host "`nUPDATE WEBUI TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
