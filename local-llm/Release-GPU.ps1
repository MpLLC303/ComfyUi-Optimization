#Requires -Version 5.1

<#
.SYNOPSIS
    Unloads every Ollama model from VRAM so ComfyUI / Forge get the whole RTX 3090.

.DESCRIPTION
    Ollama keeps the last model resident for OLLAMA_KEEP_ALIVE (15 min by default here). A resident
    19 GB model plus a Wan 2.2 / SDXL workflow does not fit in 24 GB, and on Windows the driver then
    silently spills into shared system memory instead of failing, which makes renders crawl.
    Run this before a ComfyUI/Forge session. The next chat reloads the model automatically (~5-10 s).

    Note: with the render guard on (the default), chats during a ComfyUI render run on the CPU and do
    not take VRAM back. With -RenderGuard off, a chat during a render loads a model on the GPU again.
#>
param([string]$OllamaUrl = 'http://127.0.0.1:11434')
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$before = Get-LaiGpuInfo
$loaded = $null
try { $loaded = @(Get-LaiOllamaLoaded -BaseUrl $OllamaUrl) } catch { Write-Verbose "Ollama not answering: $($_.Exception.Message)" }
if ($null -eq $loaded) {
    Write-LaiLog OK 'Ollama is not running, so no model holds VRAM.'
} elseif ($loaded.Count -eq 0) {
    Write-LaiLog OK 'No Ollama models are loaded.'
} else {
    Write-LaiLog INFO "Unloading: $(($loaded | ForEach-Object { $_.name }) -join ', ')"
    Stop-LaiOllamaModels -BaseUrl $OllamaUrl
}
Start-Sleep -Seconds 2
$after = Get-LaiGpuInfo
if ($before -and $after) {
    Write-LaiLog OK ("VRAM free: {0} MiB -> {1} MiB of {2} MiB" -f $before.FreeMiB, $after.FreeMiB, $after.TotalMiB)
}
