#Requires -Version 5.1

<#
.SYNOPSIS
    Puts the local AI stack to sleep (for gaming or a long render): frees VRAM and RAM, silences the
    health watch. Start-LocalAI.ps1 brings everything back.

.DESCRIPTION
    1. Pauses the 15-minute health watch for -PauseHours (default 12), so it neither restarts the
       containers nor notifies you. Start-LocalAI.ps1 ends the pause early.
    2. Stops the containers (Open WebUI, SearXNG, render guard) without removing them; data stays.
    3. Unloads every Ollama model (frees up to ~21 GB of VRAM). After the containers, so that a chat
       still being answered cannot load one again; then it looks once more and unloads again. A
       model that is still loaded after that is named in a warning.
    Before any of that Docker Desktop is asked whether it answers. If it does not (it can stop
    answering after sleep), nothing is paused or stopped: the models are unloaded, and the run ends
    with what to do about Docker Desktop.
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

# Every docker call has a time limit. After sleep Docker Desktop can stop answering while its
# commands still start: without a limit this window would wait on the first of them without a word.
$dockerLimit = Get-LaiDockerTimeout
$hungMsg = 'Docker Desktop is not responding. Restart it (whale icon > Restart), wait for Engine running, then run this again.'

function Invoke-Docker {
    param([string[]]$Arguments, [int]$TimeoutSec = $dockerLimit)
    return (Invoke-LaiTimedNative -File 'docker' -Arguments $Arguments -TimeoutSec $TimeoutSec)
}
function Resume-Watch {
    # For a docker call that got no answer after the watch was paused: back on, so that it reports a
    # Docker Desktop that does not answer. Left paused it would say nothing for hours.
    & (Join-Path $PSScriptRoot 'Watch-LocalAI.ps1') -AIRoot $AIRoot -Unpause | Out-Null
}

$before = Get-LaiGpuInfo

# 1. Does Docker answer? Asked before anything is changed: with a Docker Desktop that does not
# answer no container can be stopped, and a watch paused first would keep quiet about it for hours.
$engine = Test-LaiDockerEngine -TimeoutSec $dockerLimit
$hung = ($engine -eq 'hung')
# What went wrong with the containers, said at the very end: the models are unloaded all the same.
$failed = ''

if (-not $hung) {
    # 2. Pause the watch first, so it cannot restart what we stop next.
    & (Join-Path $PSScriptRoot 'Watch-LocalAI.ps1') -AIRoot $AIRoot -PauseMinutes ([Math]::Max(1, $PauseHours * 60)) | Out-Null

    # 3. Containers.
    if ($engine -eq 'ok' -and (Test-Path -LiteralPath $compose)) {
        # Not in the middle of a backup/restore/update: its 'finally' would start Open WebUI again.
        if (Test-LaiVolumeLockBusy) { Write-LaiLog INFO 'Waiting for a backup/restore/update to finish first' }
        $lock = $null
        try { $lock = Enter-LaiVolumeLock -TimeoutSec 1800 } catch { $failed = $_.Exception.Message }
        if ($lock) {
            try { $r = Invoke-Docker @('compose', '--project-directory', $stackDir, '-f', $compose, 'stop') -TimeoutSec 300 }
            finally { Exit-LaiVolumeLock $lock }
            if ($r.TimedOut) { $hung = $true; Resume-Watch }
            elseif ($r.ExitCode -ne 0) { $failed = "docker compose stop failed: $($r.Text)" }
            else { Write-LaiLog OK 'Containers stopped (data kept)' }
        }
    } elseif ($engine -ne 'ok') {
        Write-LaiLog INFO 'Docker is not running; no containers to stop'
    }
}

# 4. Models out of VRAM. After the containers: a chat that was still being answered, or the research
# agent, loads its model again right behind an unload. Also when Docker did not answer: the GPU
# memory is what this was started for.
$stillLoaded = @()
try {
    $loaded = @(Get-LaiOllamaLoaded -BaseUrl $ollamaUrl)
    if ($loaded.Count -gt 0) {
        Stop-LaiOllamaModels -BaseUrl $ollamaUrl
        # Looked at again: what is listed now (not gone yet, or loaded again meanwhile) gets one
        # more unload, and what is listed after that is said.
        $stillLoaded = @(Get-LaiOllamaLoaded -BaseUrl $ollamaUrl)
        if ($stillLoaded.Count -gt 0) {
            Stop-LaiOllamaModels -BaseUrl $ollamaUrl -TimeoutSec 20
            $stillLoaded = @(Get-LaiOllamaLoaded -BaseUrl $ollamaUrl)
        }
        if ($stillLoaded.Count -gt 0) {
            Write-LaiLog WARN "Still loaded after two unloads: $(($stillLoaded | ForEach-Object { $_.name }) -join ', '). Something keeps using Ollama, so the GPU memory is not all free. To free it, quit Ollama from its tray icon."
        } else { Write-LaiLog OK "Unloaded $(($loaded | ForEach-Object { $_.name }) -join ', ')" }
    } else { Write-LaiLog INFO 'No model loaded' }
} catch { if (Test-LaiConnectionRefused $_) { Write-LaiLog INFO 'Ollama is not running; nothing to unload.' } else { Write-LaiLog WARN "Could not reach Ollama to unload its models ($($_.Exception.Message)). If Ollama is running and the GPU memory stays full, quit Ollama from its tray icon." } }

# The two optional steps only when the containers step went through, as before: quitting Docker
# Desktop under a backup that still holds the lock would cut that backup off.
$goOn = -not ($hung -or $failed)

# 5. Optional: Ollama itself.
if ($QuitOllama -and $onWindows -and $goOn) {
    Get-Process -Name 'ollama app', 'ollama', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # With Ollama gone nothing is loaded any more, whatever the list said a moment ago.
    $stillLoaded = @()
    Write-LaiLog OK 'Ollama quit'
}

# 6. Optional: Docker Desktop and its WSL VM.
if ($QuitDocker -and $onWindows -and $engine -eq 'ok' -and $goOn) {
    $r = Invoke-Docker @('desktop', 'stop') -TimeoutSec 300
    if ($r.TimedOut) { $hung = $true; Resume-Watch }
    else {
        if ($r.ExitCode -ne 0) {
            # Older Docker Desktop without the 'docker desktop' CLI plugin.
            Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { & wsl.exe --shutdown 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
        }
        Write-LaiLog OK 'Docker Desktop quit (WSL VM memory released)'
    }
}

$after = Get-LaiGpuInfo
if ($after) {
    $msg = 'VRAM free: {0} of {1} MiB' -f $after.FreeMiB, $after.TotalMiB
    if ($before) { $msg += ' (was {0} MiB)' -f $before.FreeMiB }
    # With a model that would not unload this is not a line to read as done.
    $level = 'OK'; if ($stillLoaded.Count -gt 0) { $level = 'WARN' }
    Write-LaiLog $level $msg
}
if ($hung) {
    # Printed as a line of its own (an error's text can be wrapped), then the run ends as failed.
    Write-LaiLog FAIL "Gaming mode did not finish, and the health watch stays on: $hungMsg"
    throw $hungMsg
}
if ($failed) { throw $failed }
Write-LaiLog INFO ("Health watch paused for {0} h. Bring everything back with: {1}" -f $PauseHours, (Join-Path $PSScriptRoot 'Start-LocalAI.ps1'))
