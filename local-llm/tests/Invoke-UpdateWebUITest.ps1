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
Set-Content -LiteralPath (Join-Path $stack '.env') -Value @('OPEN_WEBUI_VERSION=3.19', 'SEARXNG_VERSION=x', 'RENDER_GUARD_MODE=cpu')
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
    $r = Invoke-Update @('-Version', '3.20')
    $cfg = Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json')
    Assert-That ((Get-Image) -eq 'alpine:3.20') 'new image running'
    Assert-That ($cfg['PreviousOpenWebUIVersion'] -eq '3.19' -and (Test-Path -LiteralPath ([string]$cfg['RollbackArchive']))) 'rollback point recorded'
    Assert-That ($r.Text -match 'Rollback') 'prints how to roll back'
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
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & pwsh -NoProfile -File (Join-Path $src 'Backup-OpenWebUI.ps1') -AIRoot $aiRoot -RetentionDays 1 -SkipDeepVerify 2>&1 | Out-Null
    $ErrorActionPreference = $prevPref
    Assert-That (Test-Path -LiteralPath $rollbackArchive) '60-day-old rollback archive survives pruning'

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
    Assert-That ($r.Code -eq 0 -or $r.Text -match 'Rolled back') "rollback ran (exit $($r.Code))"
    Assert-That ((Get-Image) -eq 'alpine:3.19') 'old image running again'
    Assert-That ((Get-Marker) -eq 'DATA-v1') 'pre-update data restored'
    Assert-That (-not $cfg.ContainsKey('RollbackArchive') -and $cfg['OpenWebUIVersion'] -eq '3.19') 'rollback point consumed, version recorded'
    $r = Invoke-Update @('-Rollback', '-Force')
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'Nothing to roll back') 'second rollback refuses clearly'
    Assert-That ((Get-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Logs') 'update.log') -Raw) -match 'Rolled back') 'update.log has the history'

    Write-Host "`n=== 5. a failed restore keeps Open WebUI down until a good restore ===" -ForegroundColor Cyan
    $good = Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*.tar.gz' | Where-Object { $_.Name -notlike '*CORRUPT*' } | Select-Object -First 1
    $holdFile = Join-Path $aiRoot 'open-webui-hold.json'
    $runScript = {
        param([string]$Name, [string[]]$Arguments)
        $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $o = & pwsh -NoProfile -File (Join-Path $src $Name) -AIRoot $aiRoot @Arguments 2>&1 | ForEach-Object { "$_" }
        $c = $LASTEXITCODE; $ErrorActionPreference = $prevPref
        return [pscustomobject]@{ Code = $c; Text = ($o -join "`n") }
    }
    $env:LOCALAI_TEST_FAIL_SWAP = '1'
    $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force', '-SkipSafetyBackup')
    $env:LOCALAI_TEST_FAIL_SWAP = ''
    Assert-That ($r.Code -ne 0 -and (Test-Path -LiteralPath $holdFile)) "failed restore without a safety backup records a hold (exit $($r.Code))"
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
    $r = & $runScript 'Restore-OpenWebUI.ps1' @('-Archive', $good.FullName, '-Force', '-SkipSafetyBackup')
    Assert-That ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $holdFile)) "recovery restore clears the hold (exit $($r.Code))"
    Assert-That ((Invoke-DockerText @('inspect', '-f', '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}', 'open-webui')) -eq 'running always') 'container running again with its original restart policy'

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
