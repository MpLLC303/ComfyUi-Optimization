#Requires -Version 5.1
<#
.SYNOPSIS
    Brings the local AI stack back after Stop-LocalAI.ps1 (or after quitting Docker/Ollama by hand).

.DESCRIPTION
    Starts Ollama and Docker Desktop if they are not running, starts the containers, waits until
    Open WebUI answers, and resumes the health watch. Models load on the first chat as usual.

.EXAMPLE
    .\Start-LocalAI.ps1
#>
param(
    [string]$AIRoot = 'C:\AI',
    [int]$TimeoutSec = 300
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$onWindows = ($env:OS -eq 'Windows_NT')
$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$ollamaUrl = 'http://127.0.0.1:11434'
if ($config.ContainsKey('OllamaUrl') -and $config['OllamaUrl']) { $ollamaUrl = [string]$config['OllamaUrl'] }
$webPort = 3000; if ($config.ContainsKey('WebUIPort')) { $webPort = [int]$config['WebUIPort'] }
$stackDir = Join-Path $AIRoot 'Stack'
$compose = Join-Path $stackDir 'docker-compose.yml'

function Invoke-Docker {
    param([string[]]$Arguments)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& docker @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ ExitCode = $code; Text = ($out -join "`n") }
}
function Test-Engine { return ((Invoke-Docker @('version', '--format', '{{.Server.Version}}')).ExitCode -eq 0) }

# The health watch comes back on even when a step below fails: the user asked for the stack, so an
# outage should be reported, not silenced by the pause from Stop-LocalAI.
try {
    # 1. Ollama.
    $ollamaOk = $true
    try { Get-LaiOllamaVersion -BaseUrl $ollamaUrl | Out-Null } catch { $ollamaOk = $false }
    if (-not $ollamaOk) {
        $app = ''
        if ($env:LOCALAPPDATA) { $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe' }
        if ($onWindows -and (Test-Path -LiteralPath $app)) {
            Start-Process -FilePath $app
            Wait-LaiHttp -Uri "$ollamaUrl/api/version" -TimeoutSec 90 | Out-Null
            Write-LaiLog OK 'Ollama started'
        } else {
            throw "Ollama is not answering at $ollamaUrl. Start it from the Start menu, then re-run."
        }
    } else { Write-LaiLog OK 'Ollama is running' }

    # 2. Docker engine.
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker CLI not found. Is Docker Desktop installed?' }
    if (-not (Test-Engine)) {
        if (-not $onWindows) { throw 'Docker engine is not running.' }
        Write-LaiLog INFO 'Starting Docker Desktop (takes a minute or two)'
        $r = Invoke-Docker @('desktop', 'start')
        if ($r.ExitCode -ne 0) {
            $exe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
            if (-not (Test-Path -LiteralPath $exe)) { throw "Docker Desktop not found at $exe" }
            Start-Process -FilePath $exe
        }
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (-not (Test-Engine)) {
            if ((Get-Date) -ge $deadline) { throw "Docker engine did not start within $TimeoutSec s. Open Docker Desktop and check for errors." }
            Start-Sleep -Seconds 5
        }
    }
    Write-LaiLog OK 'Docker engine is running'

    # 3. Containers.
    if (-not (Test-Path -LiteralPath $compose)) { throw "Missing $compose. Re-run Install-LocalAI.ps1." }
    $r = Invoke-Docker @('compose', '--project-directory', $stackDir, '-f', $compose, 'up', '-d')
    if ($r.ExitCode -ne 0) { throw "docker compose up failed: $($r.Text)" }
    Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$webPort" -TimeoutSec $TimeoutSec
    Write-LaiLog OK "Open WebUI is up on http://localhost:$webPort"

} finally {
    # 4. Watch back on.
    & (Join-Path $PSScriptRoot 'Watch-LocalAI.ps1') -AIRoot $AIRoot -Unpause | Out-Null
    Write-LaiLog OK 'Health watch resumed'
}
