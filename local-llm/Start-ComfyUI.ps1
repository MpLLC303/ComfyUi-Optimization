#Requires -Version 5.1

<#
.SYNOPSIS
    Frees the GPU from Ollama, then starts ComfyUI (Comfy Desktop or the portable build).

.DESCRIPTION
    A resident 19 GB chat model plus a Wan 2.2 / SDXL workflow does not fit in 24 GB, and Windows then
    spills into system RAM instead of failing, so renders slow to a crawl. This launcher unloads every
    Ollama model first (same as Release-GPU.ps1), reports free VRAM, and starts ComfyUI.

    ComfyUI is found in this order: -Path, the path remembered from the last run, Comfy Desktop's
    usual install folders, C:\ComfyUI\ComfyUI_windows_portable\run_nvidia_gpu.bat, Start-menu shortcuts.
    -CreateShortcut puts a "ComfyUI (free GPU first)" icon on the desktop that runs this script.

.EXAMPLE
    .\Start-ComfyUI.ps1
.EXAMPLE
    .\Start-ComfyUI.ps1 -Path 'D:\ComfyUI_windows_portable\run_nvidia_gpu.bat' -CreateShortcut
#>
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    [string]$Path = '',
    [switch]$CreateShortcut,
    # Only free the GPU (and remember -Path); do not start ComfyUI.
    [switch]$NoLaunch,
    # Ollama to ask to unload its models.
    [string]$OllamaUrl = 'http://127.0.0.1:11434'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

function Test-LaunchTarget {
    # $false for this toolkit's own shortcuts ("ComfyUI (free GPU first)" runs this script, so
    # launching it would start this launcher again, endlessly) and anything that runs PowerShell.
    param([string]$Candidate)
    if (-not $Candidate) { return $false }
    if ($Candidate -like '*\Start Menu\Programs\Local AI\*' -or (Split-Path -Leaf $Candidate) -like '*free GPU first*') { return $false }
    if ($Candidate -like '*.lnk') {
        try {
            $target = (New-Object -ComObject WScript.Shell).CreateShortcut($Candidate).TargetPath
            if ($target -match '(?i)\\(powershell|pwsh)\.exe$') { return $false }
        } catch { Write-Verbose 'could not read shortcut target' }
    }
    return $true
}

function Find-ComfyUI {
    param([string]$Remembered)
    $candidates = @()
    if ($Remembered -and (Test-LaunchTarget $Remembered)) { $candidates += $Remembered }
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles)) {
        if (-not $base) { continue }
        $candidates += Join-Path $base 'Programs\Comfy Desktop\Comfy Desktop.exe'
        $candidates += Join-Path $base 'Programs\@comfyorgcomfyui-electron\ComfyUI.exe'
        $candidates += Join-Path $base 'Comfy Desktop\Comfy Desktop.exe'
    }
    $candidates += 'C:\ComfyUI\ComfyUI_windows_portable\run_nvidia_gpu.bat'
    $candidates += 'C:\ComfyUI_windows_portable\run_nvidia_gpu.bat'
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $menus = @()
    if ($env:APPDATA) { $menus += Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
    if ($env:ProgramData) { $menus += Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs' }
    foreach ($m in $menus) {
        if (-not (Test-Path -LiteralPath $m)) { continue }
        foreach ($lnk in @(Get-ChildItem -LiteralPath $m -Recurse -Filter '*Comfy*.lnk' -ErrorAction SilentlyContinue)) {
            if (-not (Test-LaunchTarget $lnk.FullName)) { continue }
            return $lnk.FullName
        }
    }
    return $null
}

$configPath = Join-Path $AIRoot 'localai-config.json'
$config = Read-LaiState -Path $configPath
$remembered = ''
if ($config.ContainsKey('ComfyUIPath')) { $remembered = [string]$config['ComfyUIPath'] }
if (-not $Path) { $Path = Find-ComfyUI -Remembered $remembered }
if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
    throw ('ComfyUI was not found in the usual folders. Run this once in PowerShell (the path is remembered, then the shortcut works): ' +
        '& ' + (ConvertTo-LaiPsQuoted $PSCommandPath) + ' -Path ''<full path to Comfy Desktop.exe or run_nvidia_gpu.bat>''')
}
# Remember a full path: the Start-menu shortcut runs from AI\Scripts, where a relative one breaks.
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath
if (-not (Test-LaunchTarget $Path)) { throw "$Path is this toolkit's own launcher, not ComfyUI. Pass -Path <Comfy Desktop.exe | run_nvidia_gpu.bat>." }
if ($Path -ne $remembered -and (Test-Path -LiteralPath $AIRoot)) {
    $config['ComfyUIPath'] = $Path
    Save-LaiState -State $config -Path $configPath
}

# 1. Hand the GPU over.
$before = Get-LaiGpuInfo
try {
    $loaded = @(Get-LaiOllamaLoaded -BaseUrl $OllamaUrl)
    if ($loaded.Count -gt 0) {
        Write-LaiLog INFO "Unloading Ollama: $(($loaded | ForEach-Object { $_.name }) -join ', ')"
        Stop-LaiOllamaModels -BaseUrl $OllamaUrl
    }
} catch {
    if (Test-LaiConnectionRefused $_) { Write-LaiLog INFO 'Ollama is not running; nothing to unload.' } else { Write-LaiLog WARN "Could not reach Ollama to unload its models ($($_.Exception.Message)). If Ollama is running and the GPU memory stays full, quit Ollama from its tray icon." }
}
Start-Sleep -Seconds 1
$after = Get-LaiGpuInfo
if ($after) {
    $msg = "VRAM free for ComfyUI: {0} of {1} MiB" -f $after.FreeMiB, $after.TotalMiB
    if ($before) { $msg += " (was {0} MiB)" -f $before.FreeMiB }
    if ($after.FreeMiB -lt 20000) { Write-LaiLog WARN "$msg - other apps still hold VRAM: $((Get-LaiGpuApps) -join ', ')" } else { Write-LaiLog OK $msg }
}
Write-LaiLog INFO 'Chats in Open WebUI run on the CPU while ComfyUI has a job queued (render guard), so renders keep the GPU.'

# 2. Optional desktop shortcut that runs this launcher.
if ($CreateShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop 'ComfyUI (free GPU first).lnk'
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($lnkPath)
    $s.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments = Get-LaiScriptCommandLine -ScriptPath $PSCommandPath -AIRoot $AIRoot -Hidden
    $s.WorkingDirectory = Split-Path -Parent $Path
    if ($Path -like '*.exe') { $s.IconLocation = "$Path,0" }
    $s.Save()
    Write-LaiLog OK "Shortcut created: $lnkPath"
}

# 3. Launch.
if (-not $NoLaunch) {
    if ($Path -like '*.bat' -or $Path -like '*.cmd') {
        Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path)
    } else {
        Start-Process -FilePath $Path
    }
    Write-LaiLog OK "Started $Path"
}
