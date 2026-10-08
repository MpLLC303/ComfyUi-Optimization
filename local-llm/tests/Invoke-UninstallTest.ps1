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
      5. -RemoveData while the Docker engine is down refuses.
      6. Phone access on (a fake tailscale on PATH reports the mapping): the Tailscale step runs
         before the containers are removed and brings nothing back; Enable-TailscaleAccess.ps1
         -Disable on its own recreates nothing when the containers are gone, leaves Open WebUI
         stopped under a failed restore's hold, and waits for the volume lock.
      7. -ResetOllamaSettings keeps the firewall block while something listens on 11434 beyond
         loopback, and removes it once that is loopback only (stand-in firewall and listener cmdlets).
      8. Docker closed and Ollama not answering: named in the plan, 'Not finished', exit 2.
    A sandbox container named searxng is renamed out of the way for the duration and restored.
#>
param([string]$Work = '/home/user/lai-test/uninstall-test')
$ErrorActionPreference = 'Stop'
# Refuses to run anywhere but a throwaway test machine (it would delete a real install's data).
if (-not (& (Join-Path $PSScriptRoot 'Assert-LaiSandbox.ps1'))) { exit 99 }
$src = Split-Path -Parent $PSScriptRoot
$failures = 0
function Assert-That([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  ASSERT OK   $Message" -ForegroundColor Green }
    else { Write-Host "  ASSERT FAIL $Message" -ForegroundColor Red; $script:failures++ }
}
function Invoke-DockerQuiet([string[]]$DockerArgs) { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; & /usr/bin/docker @DockerArgs 2>&1 | Out-Null; $ErrorActionPreference = $prev; return $LASTEXITCODE }
function Test-Container([string]$Name) { (Invoke-DockerQuiet -DockerArgs @('container', 'inspect', $Name)) -eq 0 }
function Test-Volume([string]$Name) { (Invoke-DockerQuiet -DockerArgs @('volume', 'inspect', $Name)) -eq 0 }
function Test-Running([string]$Name) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $running = (& /usr/bin/docker inspect -f '{{.State.Running}}' $Name 2>$null) -join ''
    $ErrorActionPreference = $prev
    return ($running.Trim() -eq 'true')
}
function Get-OutLine([string]$Pattern) {
    # Index of the first line of the last run's output that matches, -1 when none does.
    for ($i = 0; $i -lt $script:lastOut.Count; $i++) { if ($script:lastOut[$i] -match $Pattern) { return $i } }
    return -1
}

$aiRoot = Join-Path $Work 'AI'
$fakePort = 11499
$deletes = Join-Path $Work 'ollama-deletes.txt'
$tasksLog = Join-Path $Work 'tasks.txt'
$firewallLog = Join-Path $Work 'firewall-removed.txt'
$tsLog = Join-Path $Work 'tailscale-calls.txt'
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
    foreach ($f in $deletes, $tasksLog, $firewallLog, $tsLog) { if (Test-Path $f) { Remove-Item $f } }
}

function Invoke-Uninstall {
    # Child process so the script's 'exit' does not end this harness; scheduled-task cmdlets mocked.
    # The Windows firewall and listener cmdlets are stand-ins too (only -ResetOllamaSettings reaches
    # them): the block rule exists, a removal is logged, and one listener holds Ollama's port at
    # -ListenAddress. No real listener is opened: CI's real Ollama owns 11434.
    param([string[]]$Arguments, [string]$ListenAddress = '127.0.0.1')
    $mock = @"
function global:Get-ScheduledTask { param(`$TaskName, `$ErrorAction) [pscustomobject]@{ TaskName = `$TaskName } }
function global:Unregister-ScheduledTask { param(`$TaskName, `$Confirm) Add-Content -LiteralPath '$tasksLog' -Value `$TaskName }
function global:Get-NetFirewallRule { param(`$DisplayName, `$ErrorAction) [pscustomobject]@{ DisplayName = `$DisplayName } }
function global:Remove-NetFirewallRule { param(`$DisplayName) Add-Content -LiteralPath '$firewallLog' -Value `$DisplayName }
function global:Get-NetTCPConnection { param(`$State, `$LocalPort, `$ErrorAction) [pscustomobject]@{ LocalAddress = '$ListenAddress'; LocalPort = `$LocalPort; OwningProcess = 4 } }
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
    # The whole output for the asserts that read it; never emitted, so the function still returns one exit code.
    $script:lastOut = @($out)
    return $code
}

function Invoke-TailscaleOff {
    # Enable-TailscaleAccess.ps1 -Disable on its own, as its help says to run it (real docker, the
    # fake tailscale on PATH).
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & pwsh -NoProfile -File (Join-Path $src 'Enable-TailscaleAccess.ps1') -AIRoot $aiRoot -Disable 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $out | Select-Object -Last 4 | ForEach-Object { Write-Host "    | $_" }
    $script:lastOut = @($out)
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
# A fake left by a killed run would hold the port, the new one would die on bind, and the "no
# deletes recorded" checks would then pass against a dead server.
& /bin/sh -c "pkill -f 'fake_ollama[.]py' ; true"
$fake = Start-Process -FilePath python3 -ArgumentList $fakeOllama -PassThru
$fakeUp = $false
for ($i = 0; $i -lt 50 -and -not $fakeUp -and -not $fake.HasExited; $i++) {
    try { Invoke-RestMethod "http://127.0.0.1:$fakePort/api/tags" -TimeoutSec 2 | Out-Null; $fakeUp = $true } catch { Start-Sleep -Milliseconds 200 }
}
if (-not $fakeUp) { Write-Host "fake Ollama on :$fakePort did not start" -ForegroundColor Red; exit 1 }
$env:ProgramData = Join-Path $Work 'ProgramData'
$menuDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Local AI'
$renamed = $false
# The uninstaller removes any container named searxng: park the sandbox's real one under another
# name. A run killed before the rename back leaves it parked; undo that first.
if (-not (Test-Container 'searxng') -and (Test-Container 'searxng-uninstall-test-keep')) {
    Invoke-DockerQuiet -DockerArgs @('rename', 'searxng-uninstall-test-keep', 'searxng') | Out-Null
}
if (Test-Container 'searxng') {
    if ((Invoke-DockerQuiet -DockerArgs @('rename', 'searxng', 'searxng-uninstall-test-keep')) -ne 0) {
        Write-Host 'Could not move the sandbox searxng aside; stopping before the uninstaller can delete it.' -ForegroundColor Red
        Stop-Process -Id $fake.Id -Force; exit 1
    }
    $renamed = $true
}

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
    New-Item -ItemType Directory -Force -Path $menuDir | Out-Null
    'x' | Set-Content (Join-Path $menuDir 'Local AI (Open WebUI).url')
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
    Assert-That (($t -contains 'LocalAI-Watch') -and ($t -contains 'LocalAI-Backup-OpenWebUI') -and ($t -contains 'LocalAI-Recheck-Models')) "scheduled tasks unregistered, the nightly model re-check too ($($t -join ', '))"
    Assert-That ((Test-Path (Join-Path $aiRoot 'Stack')) -and (Test-Path (Join-Path $aiRoot 'Secrets'))) 'files kept without -RemoveData'
    Assert-That (-not (Test-Path $menuDir)) 'Start-menu folder removed'
    Assert-That (@($script:lastOut | Where-Object { $_ -match 'CLAUDE\.md' }).Count -eq 0) 'no CLAUDE.md in the install folder: no output line names one'

    Write-Host "`n=== 3. -RemoveData -RemoveModels ===" -ForegroundColor Cyan
    New-Stack
    'x' | Set-Content (Join-Path $aiRoot 'localai-config.json.bak')
    # The rules file for an AI coding agent, which the owner may have edited: not on the deletion list.
    $claudePath = Join-Path $aiRoot 'CLAUDE.md'
    $claudeText = "# Rules for an AI agent`nThe owner added this line by hand.`n"
    [IO.File]::WriteAllText($claudePath, $claudeText)
    $code = Invoke-Uninstall @('-Force', '-RemoveData', '-RemoveModels')
    Assert-That ($code -eq 0) "full removal exits 0 (got $code)"
    Assert-That (-not (Test-Volume 'open-webui')) 'data volume deleted'
    $del = @(); if (Test-Path $deletes) { $del = @(Get-Content $deletes) }
    Assert-That ($del -contains $sourceModel) 'catalog source model deleted'
    Assert-That ($del -notcontains 'other/model:latest') 'unrelated model kept'
    Assert-That (-not (Test-Path (Join-Path $aiRoot 'Stack')) -and -not (Test-Path (Join-Path $aiRoot 'Secrets')) -and -not (Test-Path (Join-Path $aiRoot 'localai-config.json')) -and -not (Test-Path (Join-Path $aiRoot 'localai-config.json.bak'))) 'stack, secrets and config (with its .bak) deleted'
    Assert-That (@(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter '*-pre-uninstall.tar.gz').Count -eq 1) 'Backups folder kept with the final backup'
    Assert-That ((Test-Path -LiteralPath $claudePath -PathType Leaf) -and ([IO.File]::ReadAllText($claudePath) -ceq $claudeText)) 'CLAUDE.md in the install folder is still there after -RemoveData, its content unchanged'
    $claudeKept = @($script:lastOut | Where-Object { $_ -match 'kept: .*CLAUDE\.md' })
    Assert-That ($claudeKept.Count -eq 1) "the closing message lists CLAUDE.md as kept, once ($($claudeKept.Count) line(s))"

    Write-Host "`n=== 3b. deep research data: in the final backup, deleted only once saved ===" -ForegroundColor Cyan
    $rv = 'localai-deep-research'
    if (Test-Volume $rv) { Write-Host "  (skipped: this machine has a real $rv volume)" -ForegroundColor Yellow }
    else {
        try {
            New-Stack
            Invoke-DockerQuiet -DockerArgs @('volume', 'create', $rv) | Out-Null
            Invoke-DockerQuiet -DockerArgs @('run', '--rm', '-v', "${rv}:/d", 'alpine:3.20', 'sh', '-c', 'mkdir /d/encrypted_databases; echo x > /d/encrypted_databases/u.db') | Out-Null
            $code = Invoke-Uninstall @('-Force', '-RemoveData')
            Assert-That ($code -eq 0 -and -not (Test-Volume $rv) -and @(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter 'deep-research-*-pre-uninstall.tar.gz').Count -eq 1) "deep research is in the final backup, then its volume is deleted (exit $code)"
            # Not Local Deep Research's data, so it cannot be saved: the final backup fails, nothing is removed.
            New-Stack
            Invoke-DockerQuiet -DockerArgs @('volume', 'create', $rv) | Out-Null
            $code = Invoke-Uninstall @('-Force', '-RemoveData')
            Assert-That ($code -ne 0 -and (Test-Volume 'open-webui') -and (Test-Volume $rv)) "a deep research volume that could not be saved stops the uninstall, nothing removed (exit $code)"
            # No Open WebUI volume, so no final backup runs at all: the research volume is kept.
            New-Stack
            foreach ($c in 'open-webui', 'render-guard') { Invoke-DockerQuiet -DockerArgs @('rm', '-f', $c) | Out-Null }
            Invoke-DockerQuiet -DockerArgs @('volume', 'rm', 'open-webui') | Out-Null
            Invoke-DockerQuiet -DockerArgs @('run', '--rm', '-v', "${rv}:/d", 'alpine:3.20', 'sh', '-c', 'mkdir -p /d/encrypted_databases') | Out-Null
            $code = Invoke-Uninstall @('-Force', '-RemoveData')
            Assert-That ((Test-Volume $rv)) "without a final backup the deep research volume is kept (exit $code)"
        } finally { Invoke-DockerQuiet -DockerArgs @('volume', 'rm', '-f', $rv) | Out-Null }
    }

    Write-Host "`n=== 4. failing backup aborts ===" -ForegroundColor Cyan
    New-Stack -NoDb
    $code = Invoke-Uninstall @('-Force', '-RemoveData')
    Assert-That ($code -ne 0) "exits non-zero (got $code)"
    Assert-That ((Test-Container 'open-webui') -and (Test-Volume 'open-webui')) 'nothing removed'
    Assert-That (-not (Test-Path $deletes) -and -not (Test-Path $tasksLog)) 'no aliases or tasks removed'

    Write-Host "`n=== 5. -RemoveData while the Docker engine is down refuses ===" -ForegroundColor Cyan
    New-Stack
    Set-Content -LiteralPath (Join-Path $aiRoot 'Secrets/openwebui-admin.json') -Value '{"email":"a","password":"b"}'
    $savedDockerHost = $env:DOCKER_HOST
    $env:DOCKER_HOST = 'unix:///nonexistent/lai-docker.sock'
    try { $code = Invoke-Uninstall @('-Force', '-RemoveData') } finally { $env:DOCKER_HOST = $savedDockerHost }
    Assert-That ($code -ne 0) "exits non-zero (got $code)"
    Assert-That (Test-Path -LiteralPath (Join-Path $aiRoot 'Secrets/openwebui-admin.json')) 'the stored admin password is kept (its data volume is still there)'
    Assert-That ((Test-Container 'open-webui') -and (Test-Volume 'open-webui') -and -not (Test-Path $tasksLog)) 'nothing removed'

    Write-Host "`n=== 6. phone access on: the Tailscale step brings no container back ===" -ForegroundColor Cyan
    # A fake tailscale that is signed in and reports the HTTPS mapping to Open WebUI. Written with LF
    # line ends whatever this file has: a CR after '#!/bin/sh' names an interpreter that does not exist.
    $shimDir = Join-Path $Work 'tsshim'
    New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
    $shim = Join-Path $shimDir 'tailscale'
    $shimLines = @(
        '#!/bin/sh',
        ('echo "$*" >> ''{0}''' -f $tsLog),
        'case "$*" in',
        '  ''status --json'') echo ''{"BackendState":"Running","Self":{"DNSName":"pc.tail.ts.net."}}'' ;;',
        '  ''serve status --json'') echo ''{"Web":{"pc.tail.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}'' ;;',
        '  ''serve --https=443 off'') ;;',
        '  *) exit 2 ;;',
        'esac',
        'exit 0'
    )
    [IO.File]::WriteAllText($shim, (($shimLines -join "`n") + "`n"))
    & chmod +x $shim
    $envFile = Join-Path $aiRoot 'Stack/.env'
    $phoneOrigin = 'WEBUI_EXTRA_ORIGINS=;https://pc.tail.ts.net'
    $holdFile = Join-Path $aiRoot 'open-webui-hold.json'
    $holder = $null
    $savedPath = $env:PATH
    $env:PATH = $shimDir + [IO.Path]::PathSeparator + $savedPath
    try {
        # 6a. The uninstaller, with the data: before the fix it removed the containers and the volume,
        # then its Tailscale step ran 'compose up' and both were back (an empty Open WebUI, no account).
        New-Stack
        $code = Invoke-Uninstall @('-Force', '-RemoveData')
        Assert-That ($code -eq 0) "phone access on, -RemoveData: exits 0 (got $code)"
        $calls = @(); if (Test-Path $tsLog) { $calls = @(Get-Content $tsLog) }
        Assert-That ($calls -contains 'serve --https=443 off') "phone access on: the Tailscale mapping is taken off ($($calls -join ' | '))"
        Assert-That (-not (Test-Container 'open-webui') -and -not (Test-Container 'render-guard')) 'phone access on: no open-webui or render-guard container is left after the uninstall'
        Assert-That (-not (Test-Volume 'open-webui')) 'phone access on, -RemoveData: no open-webui volume is left (no empty one for a first visitor to claim)'
        $tsAt = Get-OutLine 'Tailscale access to Open WebUI removed'
        $rmAt = Get-OutLine 'Containers removed'
        Assert-That ($tsAt -ge 0 -and $rmAt -gt $tsAt) "the Tailscale step runs before the containers are removed (output lines $tsAt and $rmAt)"

        # 6b. The same script on its own once the stack is gone: only .env changes.
        New-Stack
        Add-Content -LiteralPath $envFile -Value $phoneOrigin
        foreach ($c in 'open-webui', 'render-guard') { Invoke-DockerQuiet -DockerArgs @('rm', '-f', $c) | Out-Null }
        Invoke-DockerQuiet -DockerArgs @('volume', 'rm', 'open-webui') | Out-Null
        $code = Invoke-TailscaleOff
        Assert-That ($code -eq 0 -and -not (Test-Container 'open-webui') -and -not (Test-Container 'render-guard') -and -not (Test-Volume 'open-webui')) "Enable-TailscaleAccess.ps1 -Disable with the containers gone recreates nothing: no open-webui or render-guard container, no open-webui volume (exit $code)"
        $envNow = @(Get-Content -LiteralPath $envFile -Encoding UTF8)
        Assert-That (@($envNow | Where-Object { $_ -like 'WEBUI_EXTRA_ORIGINS=*' }).Count -eq 0 -and $envNow -contains 'OPEN_WEBUI_VERSION=v0.11.4') "-Disable with the containers gone still takes the phone's address out of .env ($($envNow -join ' | '))"

        # 6c. A failed restore keeps Open WebUI stopped on purpose (the hold): -Disable must not start it.
        New-Stack
        Add-Content -LiteralPath $envFile -Value $phoneOrigin
        Invoke-DockerQuiet -DockerArgs @('stop', '-t', '0', 'open-webui') | Out-Null
        ConvertTo-Json @{ Reason = 'the test restore failed'; Recover = 'run the test restore again' } | Set-Content -LiteralPath $holdFile
        $code = Invoke-TailscaleOff
        Assert-That ($code -eq 0 -and (Test-Container 'open-webui') -and -not (Test-Running 'open-webui')) "a failed restore's hold: -Disable leaves Open WebUI stopped (exit $code)"
        Assert-That ((Get-OutLine 'the test restore failed.*run the test restore again') -ge 0) "a failed restore's hold: -Disable says why and how to recover"
        $envNow = @(Get-Content -LiteralPath $envFile -Encoding UTF8)
        Assert-That (@($envNow | Where-Object { $_ -like 'WEBUI_EXTRA_ORIGINS=*' }).Count -eq 0) "a failed restore's hold: the phone's address is out of .env all the same"

        # 6d. The same stopped container without the hold, while a backup, restore or update works
        # on the volume (another process holds the lock): -Disable waits, then starts it as before.
        Remove-Item -LiteralPath $holdFile -Force
        $heldFlag = Join-Path $Work 'lock-held.txt'
        if (Test-Path $heldFlag) { Remove-Item $heldFlag }
        $holdScript = Join-Path $Work 'hold-lock.ps1'
        Set-Content -LiteralPath $holdScript -Value ("Import-Module '{0}' -Force; `$l = Enter-LaiVolumeLock; Set-Content -LiteralPath '{1}' -Value held; Start-Sleep -Seconds 15; Exit-LaiVolumeLock `$l" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'), $heldFlag)
        $holder = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $holdScript) -PassThru
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path $heldFlag) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        Assert-That (Test-Path $heldFlag) 'setup: another process holds the volume lock'
        $code = Invoke-TailscaleOff
        Assert-That ((Get-OutLine 'Waiting for a backup/restore/update to finish first') -ge 0) 'the volume lock is taken: -Disable waits for it instead of recreating Open WebUI under a backup or restore'
        Assert-That ($code -eq 0 -and (Test-Running 'open-webui')) "once the lock is free, -Disable starts the existing Open WebUI container again (exit $code)"
    } finally {
        $env:PATH = $savedPath
        if ($holder -and -not $holder.HasExited) { Stop-Process -Id $holder.Id -Force }
    }

    Write-Host "`n=== 7. -ResetOllamaSettings: the firewall block stays while Ollama listens beyond loopback ===" -ForegroundColor Cyan
    # First run: the running Ollama still listens on every adapter. Second run, 'once more' as the
    # message asks: Ollama was restarted and listens on loopback only.
    New-Stack
    $code = Invoke-Uninstall @('-Force', '-NoBackup', '-ResetOllamaSettings') -ListenAddress '0.0.0.0'
    Assert-That ($code -eq 0 -and -not (Test-Path $firewallLog)) "a listener on 0.0.0.0:11434: the firewall rule is not removed (exit $code)"
    Assert-That ((Get-OutLine 'LocalAI - Block Ollama from LAN.*Quit Ollama from its tray icon, start it again, then run this once more') -ge 0) 'a listener on 0.0.0.0:11434: the message names the rule and the three steps (quit Ollama, start it again, run this once more)'
    Assert-That ((Get-OutLine 'kept: firewall rule') -ge 0) 'a listener on 0.0.0.0:11434: the closing list names the firewall rule as kept'
    $code = Invoke-Uninstall @('-Force', '-NoBackup', '-ResetOllamaSettings') -ListenAddress '127.0.0.1'
    $fw = @(); if (Test-Path $firewallLog) { $fw = @(Get-Content $firewallLog) }
    Assert-That ($code -eq 0 -and $fw.Count -eq 1 -and $fw[0] -eq 'LocalAI - Block Ollama from LAN') "a listener on 127.0.0.1 only: the firewall rule is removed (exit $code; removed: $($fw -join ', '))"
    Assert-That ((Get-OutLine 'once more') -lt 0) 'a listener on 127.0.0.1 only: nothing asks for another run'

    Write-Host "`n=== 8. Docker closed and Ollama not answering: 'Not finished', exit 2 ===" -ForegroundColor Cyan
    New-Stack
    $deadOllama = @('-RemoveModels', '-OllamaUrl', 'http://127.0.0.1:1')
    $savedDockerHost = $env:DOCKER_HOST
    $env:DOCKER_HOST = 'unix:///nonexistent/lai-docker.sock'
    try {
        $code = Invoke-Uninstall (@('-WhatIf') + $deadOllama)
        Assert-That ($code -eq 0) "engine down, -WhatIf: exits 0 (got $code)"
        Assert-That ((Get-OutLine 'cannot remove in this run: containers .*Docker is not running') -ge 0 -and (Get-OutLine 'cannot remove in this run: downloaded models .*Ollama is not answering') -ge 0) 'engine down, -WhatIf: the plan names the containers and the models as what cannot be removed'
        Assert-That ((Get-OutLine 'remove: containers') -lt 0 -and (Get-OutLine 'remove: downloaded models') -lt 0) 'engine down, -WhatIf: the plan does not also promise to remove them'
        Assert-That ((Get-OutLine 'Not finished') -lt 0 -and (Get-OutLine 'Uninstall finished\.') -lt 0) "engine down, -WhatIf: neither 'Not finished' nor 'Uninstall finished.'"
        $code = Invoke-Uninstall (@('-Force') + $deadOllama)
    } finally { $env:DOCKER_HOST = $savedDockerHost }
    Assert-That ($code -eq 2) "engine down: exits 2 (got $code)"
    $notFinished = @($script:lastOut | Where-Object { $_ -match 'Not finished: ' })
    Assert-That ($notFinished.Count -eq 1 -and $notFinished[0] -match 'containers open-webui' -and $notFinished[0] -match 'downloaded models' -and $notFinished[0] -match 'Start Docker Desktop and Ollama, then run the uninstaller again') "engine down: one 'Not finished' line names the containers, the models and what to start ($($notFinished -join ' | '))"
    Assert-That ((Get-OutLine 'Uninstall finished\.') -lt 0 -and (Get-OutLine 'Finished with') -lt 0) "engine down: no 'Uninstall finished.', and no step is reported as failed"
    Assert-That ((Test-Container 'open-webui') -and (Test-Container 'render-guard') -and -not (Test-Path $deletes)) 'engine down: the containers are still there and no model was deleted'
} finally {
    foreach ($c in 'open-webui', 'render-guard') { Invoke-DockerQuiet -DockerArgs @('rm', '-f', $c) | Out-Null }
    Invoke-DockerQuiet -DockerArgs @('volume', 'rm', 'open-webui') | Out-Null
    Invoke-DockerQuiet -DockerArgs @('network', 'rm', 'lai-uninstall-test_default') | Out-Null
    if ($renamed) {
        if ((Invoke-DockerQuiet -DockerArgs @('rename', 'searxng-uninstall-test-keep', 'searxng')) -ne 0) { Write-Host '  ASSERT FAIL sandbox searxng could not be renamed back' -ForegroundColor Red; $failures++ }
    }
    if ($fake -and -not $fake.HasExited) { Stop-Process -Id $fake.Id -Force }
}

if ($failures -eq 0) { Write-Host "`nUNINSTALL TEST PASSED" -ForegroundColor Green } else { Write-Host "`nUNINSTALL TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
