#Requires -Version 5.1

<#
.SYNOPSIS
    Puts the local AI stack to sleep (for gaming or a long render): frees VRAM and RAM, silences the
    health watch. Start-LocalAI.ps1 brings everything back.

.DESCRIPTION
    1. Unloads every Ollama model (frees up to ~21 GB of VRAM).
    2. Pauses the 15-minute health watch for -PauseHours (default 12), so it neither restarts the
       containers nor notifies you. Start-LocalAI.ps1 ends the pause early.
    3. Stops the containers (Open WebUI, SearXNG, render guard) without removing them; data stays.
    Optional, for the most free RAM:
      -QuitOllama   quit the Ollama tray app and server.
      -QuitDocker   quit Docker Desktop and its WSL VM (gives back up to the 16 GB the VM may hold).
                    This also stops any other containers and WSL distributions you run.
    Containers use restart: always, so after a reboot they come back on their own.

.EXAMPLE
    .\Stop-LocalAI.ps1
.EXAMPLE
    .\Stop-LocalAI.ps1 -QuitDocker -QuitOllama -PauseHours 4
#>
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    [int]$PauseHours = 12,
    [switch]$QuitOllama,
    [switch]$QuitDocker
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$onWindows = ($env:OS -eq 'Windows_NT')
$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$ollamaUrl = 'http://127.0.0.1:11434'
if ($config.ContainsKey('OllamaUrl') -and $config['OllamaUrl']) { $ollamaUrl = [string]$config['OllamaUrl'] }
$stackDir = Join-Path $AIRoot 'Stack'
$compose = Join-Path $stackDir 'docker-compose.yml'

function Invoke-Docker {
    param([string[]]$Arguments)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& docker @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ ExitCode = $code; Text = ($out -join "`n") }
}

$before = Get-LaiGpuInfo

# 1. Models out of VRAM.
try {
    $loaded = @(Get-LaiOllamaLoaded -BaseUrl $ollamaUrl)
    if ($loaded.Count -gt 0) {
        Stop-LaiOllamaModels -BaseUrl $ollamaUrl
        Write-LaiLog OK "Unloaded $(($loaded | ForEach-Object { $_.name }) -join ', ')"
    } else { Write-LaiLog INFO 'No model loaded' }
} catch { if (Test-LaiConnectionRefused $_) { Write-LaiLog INFO 'Ollama is not running; nothing to unload.' } else { Write-LaiLog WARN "Could not reach Ollama to unload its models ($($_.Exception.Message)). If Ollama is running and the GPU memory stays full, quit Ollama from its tray icon." } }

# 2. Pause the watch first, so it cannot restart what we stop next.
& (Join-Path $PSScriptRoot 'Watch-LocalAI.ps1') -AIRoot $AIRoot -PauseMinutes ([Math]::Max(1, $PauseHours * 60)) | Out-Null

# 3. Containers.
$dockerUp = (Get-Command docker -ErrorAction SilentlyContinue) -and ((Invoke-Docker @('version', '--format', '{{.Server.Version}}')).ExitCode -eq 0)
if ($dockerUp -and (Test-Path -LiteralPath $compose)) {
    # Not in the middle of a backup/restore/update: its 'finally' would start Open WebUI again.
    if (Test-LaiVolumeLockBusy) { Write-LaiLog INFO 'Waiting for a backup/restore/update to finish first' }
    $lock = Enter-LaiVolumeLock -TimeoutSec 1800
    try {
        $r = Invoke-Docker @('compose', '--project-directory', $stackDir, '-f', $compose, 'stop')
        if ($r.ExitCode -ne 0) { throw "docker compose stop failed: $($r.Text)" }
    } finally { Exit-LaiVolumeLock $lock }
    Write-LaiLog OK 'Containers stopped (data kept)'
} elseif (-not $dockerUp) {
    Write-LaiLog INFO 'Docker is not running; no containers to stop'
}

# 4. Optional: Ollama itself.
if ($QuitOllama -and $onWindows) {
    Get-Process -Name 'ollama app', 'ollama', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-LaiLog OK 'Ollama quit'
}

# 5. Optional: Docker Desktop and its WSL VM.
if ($QuitDocker -and $onWindows -and $dockerUp) {
    $r = Invoke-Docker @('desktop', 'stop')
    if ($r.ExitCode -ne 0) {
        # Older Docker Desktop without the 'docker desktop' CLI plugin.
        Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & wsl.exe --shutdown 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
    }
    Write-LaiLog OK 'Docker Desktop quit (WSL VM memory released)'
}

$after = Get-LaiGpuInfo
if ($after) {
    $msg = 'VRAM free: {0} of {1} MiB' -f $after.FreeMiB, $after.TotalMiB
    if ($before) { $msg += ' (was {0} MiB)' -f $before.FreeMiB }
    Write-LaiLog OK $msg
}
Write-LaiLog INFO ("Health watch paused for {0} h. Bring everything back with: {1}" -f $PauseHours, (Join-Path $PSScriptRoot 'Start-LocalAI.ps1'))
