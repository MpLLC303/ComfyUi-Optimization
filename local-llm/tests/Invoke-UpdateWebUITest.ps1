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
    command: ["sleep", "3600"]
    volumes: ["open-webui:/app/backend/data"]
volumes:
  open-webui:
    name: open-webui
'@ | Set-Content -LiteralPath (Join-Path $stack 'docker-compose.yml')
Set-Content -LiteralPath (Join-Path $stack '.env') -Value @('OPEN_WEBUI_VERSION=3.19', 'SEARXNG_VERSION=x', 'RENDER_GUARD_MODE=cpu')
ConvertTo-Json @{ WebUIPort = 3000; OllamaUrl = 'http://127.0.0.1:11434' } | Set-Content -LiteralPath (Join-Path $aiRoot 'localai-config.json')
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
    $envBefore = Get-Content -LiteralPath (Join-Path $stack '.env') -Raw
    $r = Invoke-Update @('-Version', '0.0.0-does-not-exist', '-SkipBackup')
    $cfg = Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json')
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'nothing was changed') "exits with 'nothing was changed' (exit $($r.Code))"
    Assert-That ((Get-Content -LiteralPath (Join-Path $stack '.env') -Raw) -eq $envBefore) '.env still names the working version'
    Assert-That ($cfg['RollbackArchive'] -eq $rollbackArchive) 'rollback point kept'
    Assert-That ((Get-Image) -eq 'alpine:3.20') 'running container untouched'

    Write-Host "`n=== 2b. SearXNG-only update keeps the Open WebUI rollback point ===" -ForegroundColor Cyan
    $r = Invoke-Update @('-Version', '3.20', '-SearxngVersion', 'x2', '-SkipBackup')
    $cfg = Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json')
    Assert-That ($cfg['RollbackArchive'] -eq $rollbackArchive -and $cfg['PreviousOpenWebUIVersion'] -eq '3.19') 'rollback point untouched'
    Assert-That ((Get-Content -LiteralPath (Join-Path $stack '.env')) -contains 'SEARXNG_VERSION=x2') 'SearXNG version changed'
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
} finally {
    Invoke-DockerText @('compose', '--project-directory', $stack, '-f', (Join-Path $stack 'docker-compose.yml'), 'down') | Out-Null
    Invoke-DockerText @('volume', 'rm', 'open-webui') | Out-Null
}

if ($failures -eq 0) { Write-Host "`nUPDATE WEBUI TEST PASSED" -ForegroundColor Green } else { Write-Host "`nUPDATE WEBUI TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
