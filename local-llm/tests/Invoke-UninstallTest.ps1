<#
.SYNOPSIS
    End-to-end test of Uninstall-LocalAI.ps1 on the Linux sandbox (real Docker, fake Ollama).

.DESCRIPTION
    Builds a throwaway stack (alpine containers named like the real ones, the open-webui volume
    with a webui.db), points the script at a tiny fake Ollama (records deletes, so the sandbox's
    real models are untouched) and mocks the scheduled-task cmdlets. Scenarios:
      1. -WhatIf changes nothing.
      2. Default: verified pre-uninstall backup, containers + aliases + tasks removed, data kept.
      3. -RemoveData -RemoveModels: volume, stack files and catalog models removed, Backups kept.
      4. A failing final backup aborts before anything is removed.
    A sandbox container named searxng is renamed out of the way for the duration and restored.
#>
param([string]$Work = '/home/user/lai-test/uninstall-test')
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $PSScriptRoot
$failures = 0
function Assert-That([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  ASSERT OK   $Message" -ForegroundColor Green }
    else { Write-Host "  ASSERT FAIL $Message" -ForegroundColor Red; $script:failures++ }
}
function Invoke-DockerQuiet([string[]]$DockerArgs) { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; & /usr/bin/docker @DockerArgs 2>&1 | Out-Null; $ErrorActionPreference = $prev; return $LASTEXITCODE }
function Test-Container([string]$Name) { (Invoke-DockerQuiet -DockerArgs @('container', 'inspect', $Name)) -eq 0 }
function Test-Volume([string]$Name) { (Invoke-DockerQuiet -DockerArgs @('volume', 'inspect', $Name)) -eq 0 }

$aiRoot = Join-Path $Work 'AI'
$fakePort = 11499
$deletes = Join-Path $Work 'ollama-deletes.txt'
$tasksLog = Join-Path $Work 'tasks.txt'
$catalog = Import-PowerShellDataFile (Join-Path $src 'config/models.psd1')
$sourceModel = @($catalog.Models)[0].Source

function New-Stack {
    param([switch]$NoDb)
    foreach ($c in 'open-webui', 'render-guard') { Invoke-DockerQuiet -DockerArgs @('rm', '-f', $c) | Out-Null }
    Invoke-DockerQuiet -DockerArgs @('volume', 'rm', 'open-webui') | Out-Null
    if (Test-Path $aiRoot) { Remove-Item -Recurse -Force $aiRoot }
    foreach ($d in 'Stack', 'Backups', 'Logs', 'Secrets', 'Scripts') { New-Item -ItemType Directory -Force -Path (Join-Path $aiRoot $d) | Out-Null }
    @'
name: lai-uninstall-test
services:
  open-webui:
    image: alpine:3.20
    container_name: open-webui
    command: ["sleep", "3600"]
    volumes: ["open-webui:/app/backend/data"]
  render-guard:
    image: alpine:3.20
    container_name: render-guard
    command: ["sleep", "3600"]
volumes:
  open-webui:
    name: open-webui
'@ | Set-Content (Join-Path $aiRoot 'Stack/docker-compose.yml')
    'OPEN_WEBUI_VERSION=v0.11.4' | Set-Content (Join-Path $aiRoot 'Stack/.env')
    ConvertTo-Json @{ OllamaUrl = "http://127.0.0.1:$fakePort"; WebUIPort = 3000 } | Set-Content (Join-Path $aiRoot 'localai-config.json')
    '{}' | Set-Content (Join-Path $aiRoot 'install-state.json')
    'x' | Set-Content (Join-Path $aiRoot 'Secrets/openwebui-admin.json')
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & /usr/bin/docker compose --project-directory (Join-Path $aiRoot 'Stack') -f (Join-Path $aiRoot 'Stack/docker-compose.yml') up -d 2>&1 | Out-Null
    $ErrorActionPreference = $prev
    if (-not $NoDb) { Invoke-DockerQuiet -DockerArgs @('run', '--rm', '-v', 'open-webui:/d', 'alpine:3.20', 'sh', '-c', 'head -c 4096 /dev/urandom > /d/webui.db') | Out-Null }
    foreach ($f in $deletes, $tasksLog) { if (Test-Path $f) { Remove-Item $f } }
}

function Invoke-Uninstall {
    # Child process so the script's 'exit' does not end this harness; scheduled-task cmdlets mocked.
    param([string[]]$Arguments)
    $mock = @"
function global:Get-ScheduledTask { param(`$TaskName, `$ErrorAction) [pscustomobject]@{ TaskName = `$TaskName } }
function global:Unregister-ScheduledTask { param(`$TaskName, `$Confirm) Add-Content -LiteralPath '$tasksLog' -Value `$TaskName }
& '$src/Uninstall-LocalAI.ps1' -AIRoot '$aiRoot' $($Arguments -join ' ')
exit `$LASTEXITCODE
"@
    $file = Join-Path $Work 'run-uninstall.ps1'
    Set-Content -LiteralPath $file -Value $mock
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & pwsh -NoProfile -File $file 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $out | Select-Object -Last 4 | ForEach-Object { Write-Host "    | $_" }
    return $code
}

# ---- setup -----------------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$fakeOllama = Join-Path $Work 'fake_ollama.py'
@"
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
TAGS = ['localai-main:latest', 'localai-fast:latest', '$sourceModel', 'other/model:latest']
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _j(self, o):
        d = json.dumps(o).encode(); self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(d))); self.end_headers(); self.wfile.write(d)
    def do_GET(self):
        if self.path == '/api/tags': self._j({'models': [{'name': n} for n in TAGS]})
        else: self._j({'version': 'fake'})
    def do_DELETE(self):
        n = int(self.headers.get('Content-Length') or 0); b = json.loads(self.rfile.read(n) or b'{}')
        with open('$deletes', 'a') as f: f.write(b.get('model', '') + '\n')
        self._j({})
ThreadingHTTPServer(('127.0.0.1', $fakePort), H).serve_forever()
"@ | Set-Content $fakeOllama
$fake = Start-Process -FilePath python3 -ArgumentList $fakeOllama -PassThru
Start-Sleep -Seconds 1
$renamed = $false
if (Test-Container 'searxng') { Invoke-DockerQuiet -DockerArgs @('rename', 'searxng', 'searxng-uninstall-test-keep') | Out-Null; $renamed = $true }

try {
    Write-Host "`n=== 1. -WhatIf ===" -ForegroundColor Cyan
    New-Stack
    $code = Invoke-Uninstall @('-WhatIf')
    Assert-That ($code -eq 0) "WhatIf exits 0 (got $code)"
    Assert-That ((Test-Container 'open-webui') -and (Test-Container 'render-guard')) 'WhatIf: containers still there'
    Assert-That (-not (Test-Path $deletes)) 'WhatIf: no Ollama deletes'
    Assert-That (-not (Test-Path $tasksLog)) 'WhatIf: no tasks removed'
    Assert-That (@(Get-ChildItem (Join-Path $aiRoot 'Backups')).Count -eq 0) 'WhatIf: no backup taken'

    Write-Host "`n=== 2. default removal ===" -ForegroundColor Cyan
    $code = Invoke-Uninstall @('-Force')
    Assert-That ($code -eq 0) "default exits 0 (got $code)"
    $bk = @(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter '*-pre-uninstall.tar.gz')
    Assert-That ($bk.Count -eq 1) 'pre-uninstall backup created'
    if ($bk.Count -eq 1) { Assert-That (@(& tar tzf $bk[0].FullName) -contains './webui.db') 'backup contains webui.db' }
    Assert-That (-not (Test-Container 'open-webui') -and -not (Test-Container 'render-guard')) 'containers removed'
    Assert-That (Test-Volume 'open-webui') 'data volume kept'
    $del = @(); if (Test-Path $deletes) { $del = @(Get-Content $deletes) }
    Assert-That (($del -contains 'localai-main:latest') -and ($del -contains 'localai-fast:latest')) 'tuned aliases deleted'
    Assert-That (($del -notcontains $sourceModel) -and ($del -notcontains 'other/model:latest')) 'source and unrelated models kept'
    $t = @(); if (Test-Path $tasksLog) { $t = @(Get-Content $tasksLog) }
    Assert-That (($t -contains 'LocalAI-Watch') -and ($t -contains 'LocalAI-Backup-OpenWebUI')) 'scheduled tasks unregistered'
    Assert-That ((Test-Path (Join-Path $aiRoot 'Stack')) -and (Test-Path (Join-Path $aiRoot 'Secrets'))) 'files kept without -RemoveData'

    Write-Host "`n=== 3. -RemoveData -RemoveModels ===" -ForegroundColor Cyan
    New-Stack
    $code = Invoke-Uninstall @('-Force', '-RemoveData', '-RemoveModels')
    Assert-That ($code -eq 0) "full removal exits 0 (got $code)"
    Assert-That (-not (Test-Volume 'open-webui')) 'data volume deleted'
    $del = @(); if (Test-Path $deletes) { $del = @(Get-Content $deletes) }
    Assert-That ($del -contains $sourceModel) 'catalog source model deleted'
    Assert-That ($del -notcontains 'other/model:latest') 'unrelated model kept'
    Assert-That (-not (Test-Path (Join-Path $aiRoot 'Stack')) -and -not (Test-Path (Join-Path $aiRoot 'Secrets')) -and -not (Test-Path (Join-Path $aiRoot 'localai-config.json'))) 'stack, secrets and config deleted'
    Assert-That (@(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter '*-pre-uninstall.tar.gz').Count -eq 1) 'Backups folder kept with the final backup'

    Write-Host "`n=== 4. failing backup aborts ===" -ForegroundColor Cyan
    New-Stack -NoDb
    $code = Invoke-Uninstall @('-Force', '-RemoveData')
    Assert-That ($code -ne 0) "exits non-zero (got $code)"
    Assert-That ((Test-Container 'open-webui') -and (Test-Volume 'open-webui')) 'nothing removed'
    Assert-That (-not (Test-Path $deletes) -and -not (Test-Path $tasksLog)) 'no aliases or tasks removed'
} finally {
    foreach ($c in 'open-webui', 'render-guard') { Invoke-DockerQuiet -DockerArgs @('rm', '-f', $c) | Out-Null }
    Invoke-DockerQuiet -DockerArgs @('volume', 'rm', 'open-webui') | Out-Null
    if ($renamed) { Invoke-DockerQuiet -DockerArgs @('rename', 'searxng-uninstall-test-keep', 'searxng') | Out-Null }
    if ($fake -and -not $fake.HasExited) { Stop-Process -Id $fake.Id -Force }
}

if ($failures -eq 0) { Write-Host "`nUNINSTALL TEST PASSED" -ForegroundColor Green } else { Write-Host "`nUNINSTALL TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
