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
    $r = Invoke-Update @()
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Nothing to do') 'no arguments: explains instead of re-pulling'

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
    foreach ($i in 1..3) { Set-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Backups') ("open-webui-2020010$i-000000-old-CORRUPT.tar.gz")) -Value 'x'; (Get-Item -LiteralPath (Join-Path (Join-Path $aiRoot 'Backups') ("open-webui-2020010$i-000000-old-CORRUPT.tar.gz"))).LastWriteTime = (Get-Date).AddDays(-30 + $i) }
    Start-Sleep -Seconds 1
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-deep-test', '-Container', 'lai-no-such-container', '-Tag', 'deeptest', '-NoPrune', '-VerifyImage', $verifyImage)
    $corNow = @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-CORRUPT.tar.gz' | ForEach-Object { $_.Name })
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
    $b = & $runScript 'Backup-OpenWebUI.ps1' @('-Volume', 'lai-ok-test', '-Container', 'lai-no-such-container', '-Tag', 'nocheck', '-NoPrune', '-VerifyImage', 'alpine:3.20')
    Assert-That ($b.Code -eq 0 -and $b.Text -match 'Deep check could not run' -and @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-nocheck.tar.gz').Count -eq 1 -and @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter '*-nocheck-CORRUPT.tar.gz').Count -eq 0) "a deep check that cannot run is a warning, not a CORRUPT archive (exit $($b.Code))"
    Assert-That ((Invoke-DockerText @('volume', 'ls', '-q', '--filter', 'name=localai-verify-')) -eq '') 'scratch volumes left by a killed deep check are swept'
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
