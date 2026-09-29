<#
.SYNOPSIS
    Optimize-ComfyUI.ps1 - idempotent, resume-safe performance tuner for ComfyUI Windows Portable
    on an RTX 3090 (24 GB, Ampere sm_86) running Wan 2.2 14B video workflows.

.DESCRIPTION
    Safe to re-run at any time. Every phase checks current state first and only changes what is
    missing or out of date. Nothing is deleted; everything it changes is logged to
    <InstallDir>\optimizer\ (report, pip snapshot, rollback commands).

    Phases
      1. Preflight   GPU / driver / VRAM / RAM / pagefile / disk / torch / ComfyUI audit, plus a scan
                     of your existing .bat launchers for flags that are now harmful.
      2. Update      ComfyUI (stable channel) + its pinned python deps (comfy-kitchen, comfy-aimdo).
      3. Torch       Moves torch to the CUDA 13.0 build if you are on an older one and your driver
                     supports it. ComfyUI disables its comfy-kitchen CUDA kernels below cu130.
      4. Models      Downloads the lightx2v 4-step LoRAs for Wan 2.2 (the single largest speedup:
                     20 -> 4 steps, ~5-7x) into models\loras, resume-safe.
      5. Probe       Runs bench\kernel_probe.py on YOUR GPU to measure fp16-accumulation GEMM and
                     INT8 (Sage-style) attention speed + error vs PyTorch SDPA, then picks flags.
      6. Launchers   Writes run_optimized.bat, run_optimized_no_int8attn.bat, run_remote_tailscale.bat,
                     run_probe.bat, run_bench.bat into the portable root.
      7. Windows     (opt-in, admin) High-performance power plan, Defender exclusion for the models
                     folder, optional GPU power limit. Reports HAGS and the NVIDIA sysmem-fallback
                     setting, which cannot be changed from a script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-ComfyUI.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-ComfyUI.ps1 -InstallDir "D:\AI\ComfyUI_windows_portable" -ApplyWindowsTweaks
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-ComfyUI.ps1 -ReportOnly
#>
[CmdletBinding()]
param(
    # ============================ CONFIG ============================
    # Portable root (the folder that contains python_embeded\ and ComfyUI\). Auto-detected if wrong.
    [string]$InstallDir = "C:\AI\ComfyUI_windows_portable",

    # Update ComfyUI + pinned deps via the portable updater (stable channel).
    [bool]$UpdateComfyUI = $true,

    # "auto": move torch to cu130 only if it is older AND the driver is >= 580. "off": never touch torch.
    [ValidateSet("auto", "off")]
    [string]$UpgradeTorch = "auto",

    # lightx2v 4-step distill LoRAs (same file names the official templates use).
    [bool]$DownloadT2V = $true,
    [bool]$DownloadI2V = $true,

    # Flag selection. "auto" = decided by the on-GPU probe. "on"/"off" = force.
    [ValidateSet("auto", "on", "off")]
    [string]$Fp16Accumulation = "auto",
    [ValidateSet("auto", "ck", "sage", "off")]
    [string]$FastAttention = "auto",

    # Extra VRAM (GB) to keep free for Windows/browser/other apps. 0 = ComfyUI default (0.7 GB on
    # Windows with a >15 GB card). Raise to 1.5-2 if you game/stream on the same GPU while rendering.
    [double]$ReserveVramGB = 0,

    [int]$Port = 8188,

    # Admin-only system tweaks (power plan, Defender exclusion for models folder).
    [switch]$ApplyWindowsTweaks,
    # GPU board power limit in watts (0 = leave alone). 3090 FE default is 350 W; 280-300 W typically
    # costs <5% speed and runs the GDDR6X much cooler on long batches. Resets on reboot.
    [int]$PowerLimitW = 0,

    # Audit only: no downloads, no installs, no file writes except the report.
    [switch]$ReportOnly
    # ================================================================
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$script:Findings = New-Object System.Collections.Generic.List[string]
$script:Actions = New-Object System.Collections.Generic.List[string]
$script:Stamp = Get-Date -Format "yyyyMMdd-HHmmss"

# --------------------------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------------------------- #
function Write-Step([string]$msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "    [ok]   $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "    [info] $msg" }
function Write-Warn2([string]$msg) {
    Write-Host "    [warn] $msg" -ForegroundColor Yellow
    $script:Findings.Add("WARN: $msg")
}
function Add-Action([string]$msg) {
    Write-Host "    [done] $msg" -ForegroundColor Green
    $script:Actions.Add($msg)
}
function Add-Finding([string]$msg) {
    Write-Info $msg
    $script:Findings.Add($msg)
}

function Test-IsAdmin {
    if ($env:OS -ne "Windows_NT") { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Run a native command, capture stdout (+stderr) without tripping $ErrorActionPreference=Stop.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory = $null, [switch]$Passthru)
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    if ($WorkingDirectory) { Push-Location $WorkingDirectory }
    try {
        if ($Passthru) {
            & $Exe @Arguments | Out-Host
            $code = $LASTEXITCODE
            return [pscustomobject]@{ ExitCode = $code; Output = "" }
        }
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
        $ErrorActionPreference = $old
    }
}

function Compare-Version([string]$a, [string]$b) {
    # returns -1/0/1 comparing dotted numeric versions, ignoring local tags like +cu130
    $pa = @(($a -split "\+")[0] -split "\." | ForEach-Object { if ($_ -match "^\d+") { [int]$Matches[0] } else { 0 } })
    $pb = @(($b -split "\+")[0] -split "\." | ForEach-Object { if ($_ -match "^\d+") { [int]$Matches[0] } else { 0 } })
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { $x = $pa[$i] }
        if ($i -lt $pb.Count) { $y = $pb[$i] }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

function Write-TextFile([string]$Path, [string]$Content, [switch]$Ascii) {
    # .bat files must be written WITHOUT a UTF-8 BOM or cmd.exe mangles the first line.
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Content = $Content -replace "`r?`n", "`r`n"
    if ($Ascii) { $enc = New-Object System.Text.ASCIIEncoding }
    else { $enc = New-Object System.Text.UTF8Encoding($false) }
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Find-InstallDir([string]$Preferred) {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Preferred) { $candidates.Add($Preferred) }
    # repo cloned inside (or next to) the portable folder
    $here = $PSScriptRoot
    while ($here) {
        $candidates.Add($here)
        $parent = Split-Path -Parent $here
        if ($parent -eq $here) { break }
        $here = $parent
    }
    if ($env:OS -eq "Windows_NT") {
        foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $root = $drive.Root
            foreach ($pattern in @("ComfyUI_windows_portable*", "AI\ComfyUI_windows_portable*", "ComfyUI\ComfyUI_windows_portable*")) {
                Get-ChildItem -Path (Join-Path $root $pattern) -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { $candidates.Add($_.FullName) }
            }
        }
        $candidates.Add((Join-Path $env:USERPROFILE "ComfyUI_windows_portable"))
        $candidates.Add((Join-Path $env:USERPROFILE "Desktop\ComfyUI_windows_portable"))
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c "python_embeded")) -and (Test-Path (Join-Path $c "ComfyUI\main.py"))) {
            return (Resolve-Path $c).Path
        }
    }
    return $null
}

function Get-PythonExe([string]$Root) {
    foreach ($name in @("python.exe", "python")) {
        $p = Join-Path $Root "python_embeded\$name"
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-RemoteSize([string]$Url) {
    # Final Content-Length after redirects (HF -> CDN). Returns -1 if unknown.
    $r = Invoke-Native -Exe $script:Curl -Arguments @("-sIL", "--max-time", "60", $Url)
    if ($r.ExitCode -ne 0) { return -1 }
    $size = -1
    foreach ($line in ($r.Output -split "`n")) {
        if ($line -match "^(?i)content-length:\s*(\d+)") { $size = [int64]$Matches[1] }
    }
    return $size
}

function Save-File([string]$Url, [string]$Dest) {
    $name = Split-Path -Leaf $Dest
    $expected = Get-RemoteSize $Url
    if (Test-Path $Dest) {
        $have = (Get-Item $Dest).Length
        if (($expected -gt 0 -and $have -eq $expected) -or ($expected -le 0 -and $have -gt 1MB)) {
            Write-Ok ("{0} already present ({1:N0} MB)" -f $name, ($have / 1MB))
            return $true
        }
        if ($ReportOnly) { Write-Warn2 "$name is $have bytes, expected $expected; would re-download"; return $false }
        if ($expected -gt 0 -and $have -lt $expected) {
            Write-Warn2 "$name is incomplete ($have of $expected bytes); resuming"
            Move-Item -Force $Dest "$Dest.part"
        }
        else {
            # never resume on top of a file that is larger / unrelated; keep it aside instead of deleting
            Write-Warn2 "$name has unexpected size $have (expected $expected); kept as $name.bak-$($script:Stamp)"
            Move-Item -Force $Dest "$Dest.bak-$($script:Stamp)"
        }
    }
    if ($ReportOnly) { Add-Finding "would download $name"; return $false }
    $dir = Split-Path -Parent $Dest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Write-Info "downloading $name (resume-safe) ..."
    $curlArgs = @("-L", "--fail", "--retry", "5", "--retry-delay", "5", "-o", "$Dest.part", $Url)
    $r = Invoke-Native -Exe $script:Curl -Passthru -Arguments (@("-C", "-") + $curlArgs)
    if ($r.ExitCode -eq 33) {
        # server refused a byte-range resume: start this file over
        Remove-Item -Force "$Dest.part" -ErrorAction SilentlyContinue
        $r = Invoke-Native -Exe $script:Curl -Passthru -Arguments $curlArgs
    }
    if ($r.ExitCode -ne 0) {
        Write-Warn2 "download of $name failed (curl exit $($r.ExitCode)); re-run to resume"
        return $false
    }
    $have = (Get-Item "$Dest.part").Length
    if ($expected -gt 0 -and $have -ne $expected) {
        Write-Warn2 "$name size $have != expected $expected; kept as .part, re-run to resume"
        return $false
    }
    Move-Item -Force "$Dest.part" $Dest
    Add-Action ("downloaded {0} ({1:N0} MB)" -f $name, ($have / 1MB))
    return $true
}

# --------------------------------------------------------------------------------------------- #
# 1. Preflight
# --------------------------------------------------------------------------------------------- #
Write-Step "Preflight"
$Root = Find-InstallDir $InstallDir
if (-not $Root) {
    throw "Could not find ComfyUI portable (a folder with python_embeded\ and ComfyUI\main.py). Pass -InstallDir."
}
if ($Root -ne $InstallDir) { Write-Info "InstallDir auto-detected: $Root" }
$Py = Get-PythonExe $Root
$ComfyDir = Join-Path $Root "ComfyUI"
$OptDir = Join-Path $Root "optimizer"
$Models = Join-Path $ComfyDir "models"
if (-not $ReportOnly) { New-Item -ItemType Directory -Force -Path $OptDir | Out-Null }
Write-Ok "portable root: $Root"

# Windows locks torch's DLLs while ComfyUI runs; pip-upgrading underneath it leaves a half-installed torch.
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith((Join-Path $Root "python_embeded"), [StringComparison]::OrdinalIgnoreCase) } catch { $false } })
if ($running.Count -gt 0 -and -not $ReportOnly) {
    throw "ComfyUI is running from this install (PID $($running.Id -join ', ')). Close it, then re-run. (-ReportOnly works while it runs.)"
}

# curl.exe ships with Windows 10 1803+ (note: bare 'curl' is an alias for Invoke-WebRequest in PS 5.1)
$script:Curl = $null
$c = @(Get-Command "curl.exe", "curl" -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
if ($c) { $script:Curl = $c.Source } else { Write-Warn2 "curl.exe not found; model downloads will be skipped" }

# ---- GPU / driver
$gpu = $null
$nvsmi = @(Get-Command "nvidia-smi" -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
if ($nvsmi) {
    $q = "name,driver_version,memory.total,memory.used,pcie.link.gen.max,pcie.link.width.max,power.limit,power.default_limit,power.max_limit,temperature.gpu"
    $r = Invoke-Native -Exe $nvsmi.Source -Arguments @("--query-gpu=$q", "--format=csv,noheader,nounits", "-i", "0")
    if ($r.ExitCode -eq 0 -and $r.Output) {
        $f = ($r.Output -split "`n")[0] -split ",\s*"
        $gpu = [pscustomobject]@{
            Name = $f[0]; Driver = $f[1]; VramMiB = [int]$f[2]; UsedMiB = [int]$f[3]
            PcieGen = $f[4]; PcieWidth = $f[5]; PowerLimit = $f[6]; PowerDefault = $f[7]; PowerMax = $f[8]; TempC = $f[9]
        }
        Write-Ok ("GPU {0} | driver {1} | {2} MiB VRAM ({3} MiB in use now) | PCIe gen{4} x{5} | {6} W limit" -f `
                $gpu.Name, $gpu.Driver, $gpu.VramMiB, $gpu.UsedMiB, $gpu.PcieGen, $gpu.PcieWidth, $gpu.PowerLimit)
        if ($gpu.UsedMiB -gt 1500) {
            Write-Warn2 "$($gpu.UsedMiB) MiB VRAM already in use before ComfyUI starts (browser/Discord/games/desktop). Close GPU apps or set -ReserveVramGB."
        }
        if ($gpu.PcieWidth -match "^\d+$" -and [int]$gpu.PcieWidth -lt 16) {
            Write-Warn2 "GPU max link width is x$($gpu.PcieWidth). Expert swaps between the high/low-noise Wan models cross PCIe; use the x16 slot."
        }
    }
}
else { Write-Warn2 "nvidia-smi not found; NVIDIA driver missing or not on PATH" }

# ---- RAM / pagefile / disk
$ramGB = 0
if ($env:OS -eq "Windows_NT") {
    $cs = Get-CimInstance Win32_ComputerSystem
    $ramGB = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    Write-Ok "system RAM: $ramGB GB"
    # Wan 2.2 14B fp8: two experts (~14.3 GB each) + umt5 fp8 (~6.7 GB) + LoRAs + VAE ~= 37 GB of weights
    if ($ramGB -lt 48) {
        Write-Warn2 "RAM $ramGB GB < 48 GB: the two Wan 2.2 14B experts + text encoder (~37 GB) cannot all stay cached; expect disk re-reads on every expert swap. 64 GB is the practical floor for Wan 2.2 14B."
    }
    $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    $auto = (Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile
    $pfGB = 0
    if ($pf) { $pfGB = [Math]::Round((($pf | Measure-Object AllocatedBaseSize -Sum).Sum) / 1024, 1) }
    Write-Info "pagefile: $pfGB GB allocated (system-managed: $auto)"
    if (-not $auto -and $pfGB -lt 32) {
        Write-Warn2 "pagefile is fixed at $pfGB GB. Windows does not overcommit; loading 14B models with a small pagefile causes 'paging file too small' crashes. Set system-managed or >= 32 GB on an NVMe drive."
    }
    try {
        $letter = (Split-Path -Qualifier $Models).TrimEnd(":")
        $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$($part.DiskNumber)" } | Select-Object -First 1
        $vol = Get-Volume -DriveLetter $letter
        $freeGB = [Math]::Round($vol.SizeRemaining / 1GB, 0)
        Write-Ok "models drive ${letter}: $($disk.FriendlyName) | bus $($disk.BusType) | media $($disk.MediaType) | $freeGB GB free"
        if ($disk.MediaType -eq "HDD") {
            Write-Warn2 "models are on a spinning HDD. Loading/swapping the 14 GB Wan experts will dominate run time. Move ComfyUI\models to NVMe."
        }
        elseif ($disk.BusType -ne "NVMe") {
            Add-Finding "models drive is $($disk.BusType) (not NVMe); expert swaps from disk are ~3-5x slower than NVMe"
        }
        if ($freeGB -lt 25) { Write-Warn2 "only $freeGB GB free on the models drive" }
    }
    catch { Write-Info "could not query disk type for models folder ($($_.Exception.Message))" }
}

# ---- Python / torch / ComfyUI
$pyCode = @'
import json, platform, sys
d = {"python": platform.python_version()}
try:
    import torch
    d["torch"] = torch.__version__; d["cuda"] = torch.version.cuda; d["cuda_ok"] = torch.cuda.is_available()
except Exception as e:
    d["torch_error"] = str(e)
try:
    sys.path.insert(0, sys.argv[1]); import comfyui_version; d["comfyui"] = comfyui_version.__version__
except Exception:
    d["comfyui"] = None
from importlib.metadata import version, PackageNotFoundError
for n in ("comfy-kitchen", "comfy-aimdo", "comfyui-frontend-package", "sageattention", "triton-windows", "xformers", "comfyui_manager"):
    try: d[n] = version(n)
    except PackageNotFoundError: d[n] = None
print("JSON:" + json.dumps(d))
'@
function Get-PyInfo {
    if (-not $Py) { return $null }
    $r = Invoke-Native -Exe $Py -Arguments @("-s", "-c", $pyCode, $ComfyDir)
    $line = ($r.Output -split "`n") | Where-Object { $_ -like "JSON:*" } | Select-Object -Last 1
    if ($line) { return ($line.Substring(5) | ConvertFrom-Json) }
    return $null
}
$pyInfo = Get-PyInfo
if ($pyInfo -and $pyInfo.PSObject.Properties["torch_error"]) {
    Write-Warn2 "torch failed to import in the embedded Python: $($pyInfo.torch_error). Run update\update_comfyui_and_python_dependencies.bat, then re-run."
    $pyInfo | Add-Member -NotePropertyName torch -NotePropertyValue $null -Force
    $pyInfo | Add-Member -NotePropertyName cuda -NotePropertyValue $null -Force
    $pyInfo | Add-Member -NotePropertyName cuda_ok -NotePropertyValue $false -Force
}
if ($pyInfo) {
    Write-Ok ("Python {0} | torch {1} (CUDA {2}, cuda_available={3}) | ComfyUI {4}" -f `
            $pyInfo.python, $pyInfo.torch, $pyInfo.cuda, $pyInfo.cuda_ok, $pyInfo.comfyui)
    Write-Info ("comfy-kitchen {0} | comfy-aimdo {1} | frontend {2} | sageattention {3} | triton-windows {4} | xformers {5}" -f `
            $pyInfo.'comfy-kitchen', $pyInfo.'comfy-aimdo', $pyInfo.'comfyui-frontend-package', $pyInfo.sageattention, $pyInfo.'triton-windows', $pyInfo.xformers)
}
else { Write-Warn2 "could not query the embedded Python" }

# ---- existing launchers: flags that are now counter-productive
Get-ChildItem -Path $Root -Filter "*.bat" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "run_optimized*" -and $_.Name -notlike "run_remote_tailscale*" } | ForEach-Object {
    $txt = Get-Content -Raw $_.FullName
    if ($txt -match "--highvram|--gpu-only") {
        Write-Warn2 "$($_.Name) uses --highvram/--gpu-only: this DISABLES ComfyUI's dynamic VRAM manager (comfy-aimdo). Remove it."
    }
    if ($txt -match "--fast(\s*$|\s+--|\s*`r?`n)") {
        Write-Warn2 "$($_.Name) uses bare --fast: that also enables 'autotune', which turns OFF cudaMallocAsync. Use '--fast fp16_accumulation' instead."
    }
    if ($txt -match "--lowvram|--novram") {
        Write-Warn2 "$($_.Name) uses --lowvram/--novram: unnecessary on 24 GB and --novram disables dynamic VRAM."
    }
    if ($txt -match "--disable-smart-memory") {
        Write-Warn2 "$($_.Name) uses --disable-smart-memory: forces models out of VRAM after every run (slower 2nd+ generations)."
    }
    if ($txt -match "--use-sage-attention") {
        Add-Finding "$($_.Name) uses --use-sage-attention: comfy-kitchen now ships the same INT8 attention (--use-ck-attention) with no separate wheel to keep in sync with torch."
    }
}

# --------------------------------------------------------------------------------------------- #
# 2. Update ComfyUI (stable) + pinned deps
# --------------------------------------------------------------------------------------------- #
Write-Step "ComfyUI update (stable channel)"
$updDir = Join-Path $Root "update"
if (-not $UpdateComfyUI) { Write-Info "skipped (-UpdateComfyUI `$false)" }
elseif ($ReportOnly) { Write-Info "report-only: would run update\update_comfyui_stable.bat" }
elseif (-not (Test-Path (Join-Path $updDir "update.py"))) { Write-Warn2 "update\update.py not found; update ComfyUI manually" }
else {
    $freeze = Invoke-Native -Exe $Py -Arguments @("-s", "-m", "pip", "freeze")
    Write-TextFile -Path (Join-Path $OptDir "pip-freeze-before-$($script:Stamp).txt") -Content $freeze.Output
    # Same logic as update_comfyui_stable.bat, minus the 'pause'. update.py self-updates once.
    $updPy = Join-Path $updDir "update.py"
    $r = Invoke-Native -Exe $Py -Arguments @($updPy, $ComfyDir, "--stable") -WorkingDirectory $updDir -Passthru
    if (Test-Path (Join-Path $updDir "update_new.py")) {
        Move-Item -Force (Join-Path $updDir "update_new.py") $updPy
        $r = Invoke-Native -Exe $Py -Arguments @($updPy, $ComfyDir, "--skip_self_update", "--stable") -WorkingDirectory $updDir -Passthru
    }
    if ($r.ExitCode -eq 0) { Add-Action "ComfyUI updated to latest stable (+ requirements.txt deps)" }
    else { Write-Warn2 "updater exited with $($r.ExitCode); check output above" }
    # requirements are only reinstalled by update.py when requirements.txt changed; make sure the two
    # packages that carry the new memory manager + kernels are at the pinned versions regardless.
    $req = Join-Path $ComfyDir "requirements.txt"
    if (Test-Path $req) {
        $pins = Select-String -Path $req -Pattern "^(comfy-kitchen|comfy-aimdo)==" | ForEach-Object { $_.Line.Trim() }
        if ($pins) {
            $r = Invoke-Native -Exe $Py -Arguments (@("-s", "-m", "pip", "install", "--disable-pip-version-check", "-q") + $pins)
            if ($r.ExitCode -eq 0) { Write-Ok "pinned: $($pins -join ', ')" } else { Write-Warn2 "pip install $($pins -join ' ') failed:`n$($r.Output)" }
        }
    }
}

# --------------------------------------------------------------------------------------------- #
# 3. Torch -> cu130
# --------------------------------------------------------------------------------------------- #
Write-Step "PyTorch CUDA build"
if ($pyInfo -and $pyInfo.cuda) {
    $cudaMajor = [int](($pyInfo.cuda -split "\.")[0])
    if ($cudaMajor -ge 13) { Write-Ok "torch $($pyInfo.torch) is a CUDA $($pyInfo.cuda) build (comfy-kitchen CUDA kernels enabled)" }
    else {
        $driverOk = $gpu -and ((Compare-Version $gpu.Driver "580.0") -ge 0)
        Write-Warn2 "torch is built for CUDA $($pyInfo.cuda). ComfyUI disables the comfy-kitchen CUDA backend below cu130 (slower RoPE/quant kernels, no INT8 attention)."
        if ($UpgradeTorch -eq "off") { Write-Info "skipped (-UpgradeTorch off)" }
        elseif (-not $driverOk) { Write-Warn2 "NVIDIA driver $($gpu.Driver) < 580: cu130 torch needs driver >= 580. Update the driver (Studio driver is fine), then re-run." }
        elseif ($ReportOnly) { Write-Info "report-only: would install torch/torchvision/torchaudio from the cu130 index" }
        else {
            $old = $pyInfo.torch
            $rb = "REM Roll back torch to the build you had before $($script:Stamp):`r`n" +
            "cd /d `"$Root`"`r`n" +
            ".\python_embeded\python.exe -s -m pip install --force-reinstall torch==$(($old -split '\+')[0]) torchvision torchaudio --index-url https://download.pytorch.org/whl/cu$(($pyInfo.cuda -replace '\.', ''))`r`n"
            Write-TextFile -Path (Join-Path $OptDir "rollback-torch-$($script:Stamp).bat") -Content $rb -Ascii
            if ($pyInfo.xformers) {
                Write-Info "uninstalling xformers $($pyInfo.xformers) (built against the old torch; it would shadow PyTorch attention and break on the new build)"
                Invoke-Native -Exe $Py -Arguments @("-s", "-m", "pip", "uninstall", "-y", "xformers") | Out-Null
            }
            Write-Info "installing torch cu130 (~3 GB download) ..."
            $r = Invoke-Native -Exe $Py -Passthru -Arguments @("-s", "-m", "pip", "install", "--upgrade", "--disable-pip-version-check",
                "torch", "torchvision", "torchaudio", "--extra-index-url", "https://download.pytorch.org/whl/cu130")
            # Verify. If download.pytorch.org was unreachable pip silently takes PyPI's torch, which on
            # Windows is a CPU-only build: that would turn ComfyUI into CPU mode. Never leave that behind.
            $after = Get-PyInfo
            $good = $after -and $after.PSObject.Properties["cuda"] -and $after.cuda -and
                    ([int](($after.cuda -split "\.")[0]) -ge 13) -and $after.cuda_ok
            if ($r.ExitCode -eq 0 -and $good) {
                Add-Action "torch moved from $old to $($after.torch) (CUDA $($after.cuda)); rollback: optimizer\rollback-torch-$($script:Stamp).bat"
            }
            else {
                $got = if ($after) { "$($after.torch) (CUDA $($after.cuda), cuda_available=$($after.cuda_ok))" } else { "unknown" }
                Write-Warn2 "torch upgrade did not produce a working CUDA 13 build (pip exit $($r.ExitCode), got $got). Rolling back to $old."
                $rbArgs = @("-s", "-m", "pip", "install", "--force-reinstall", "--disable-pip-version-check",
                    "torch==$(($old -split '\+')[0])", "torchvision", "torchaudio",
                    "--index-url", "https://download.pytorch.org/whl/cu$(($pyInfo.cuda -replace '\.', ''))")
                $rr = Invoke-Native -Exe $Py -Passthru -Arguments $rbArgs
                if ($rr.ExitCode -eq 0) { Write-Ok "rolled back to torch $old" }
                else { Write-Warn2 "automatic rollback failed; run optimizer\rollback-torch-$($script:Stamp).bat" }
            }
            if ($pyInfo.sageattention) {
                Write-Warn2 "sageattention $($pyInfo.sageattention) was built for the old torch and may fail to import now. --use-ck-attention replaces it; uninstall with: python_embeded\python.exe -m pip uninstall sageattention"
            }
        }
    }
}
else { Write-Info "torch CUDA version unknown; skipped" }
if (-not $ReportOnly -and $script:Actions.Count -gt 0) { $pyInfo = Get-PyInfo }   # refresh after update/torch changes

# --------------------------------------------------------------------------------------------- #
# 4. Models: lightx2v 4-step LoRAs
# --------------------------------------------------------------------------------------------- #
Write-Step "Wan 2.2 lightx2v 4-step LoRAs (20 -> 4 steps)"
$hf = "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras"
$loras = @()
if ($DownloadI2V) { $loras += "wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors", "wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" }
if ($DownloadT2V) { $loras += "wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors", "wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors" }
if (-not $script:Curl) { Write-Warn2 "curl missing; skipping LoRA downloads" }
else {
    foreach ($l in $loras) { [void](Save-File "$hf/$l" (Join-Path $Models "loras\$l")) }
}
# the base models the benchmark workflows expect (installed by install-comfyui-wan22.ps1)
foreach ($m in @(
        "diffusion_models\wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors", "diffusion_models\wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors",
        "diffusion_models\wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors", "diffusion_models\wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors",
        "text_encoders\umt5_xxl_fp8_e4m3fn_scaled.safetensors", "vae\wan_2.1_vae.safetensors")) {
    if (-not (Test-Path (Join-Path $Models $m))) { Add-Finding "not found: models\$m (benchmark workflows that use it will fail validation)" }
}

# --------------------------------------------------------------------------------------------- #
# 5. Copy bench kit + probe the GPU
# --------------------------------------------------------------------------------------------- #
Write-Step "On-GPU kernel probe"
if (-not $ReportOnly) {
    foreach ($sub in @("bench", "workflows")) {
        $src = Join-Path $PSScriptRoot $sub
        if (Test-Path $src) {
            Copy-Item -Recurse -Force $src (Join-Path $OptDir ".") -ErrorAction Stop
        }
    }
    # start frame for the I2V benchmark workflow
    $startPng = Join-Path $ComfyDir "input\bench_start.png"
    if (-not (Test-Path $startPng)) {
        $mk = "from PIL import Image, ImageDraw; im = Image.new('RGB', (640, 640)); d = ImageDraw.Draw(im)`n" +
        "for y in range(640): d.line([(0, y), (639, y)], fill=(40 + y // 4, 90, 200 - y // 4))`n" +
        "d.ellipse([220, 160, 420, 360], fill=(230, 190, 150)); d.rectangle([250, 360, 390, 600], fill=(60, 60, 110))`n" +
        "im.save(r'$startPng')"
        [void](Invoke-Native -Exe $Py -Arguments @("-s", "-c", $mk))
    }
}
$probe = $null
$probePy = Join-Path $PSScriptRoot "bench\kernel_probe.py"
if ($Py -and (Test-Path $probePy)) {
    $r = Invoke-Native -Exe $Py -Arguments @("-s", $probePy, "--json")
    $jl = ($r.Output -split "`n") | Where-Object { $_.TrimStart().StartsWith("{") } | Select-Object -Last 1
    if ($jl) {
        $probe = $jl | ConvertFrom-Json
        if (-not $ReportOnly) { Write-TextFile -Path (Join-Path $OptDir "probe-$($script:Stamp).json") -Content $jl }
        if ($probe.PSObject.Properties["gemm"] -and $probe.gemm -and $probe.gemm.PSObject.Properties["speedup"]) {
            Write-Ok ("fp16 GEMM: fp32-accum {0} TFLOPS -> fp16-accum {1} TFLOPS ({2}x, cosine {3})" -f `
                    $probe.gemm.fp32_accum_tflops, $probe.gemm.fp16_accum_tflops, $probe.gemm.speedup, $probe.gemm.error.cosine)
        }
        if ($probe.PSObject.Properties["attention"] -and $probe.attention) {
            foreach ($p in $probe.attention.PSObject.Properties) {
                $v = $p.Value
                if ($v.PSObject.Properties["ms"]) {
                    $extra = ""
                    if ($v.PSObject.Properties["speedup_vs_sdpa"]) { $extra = " | {0}x vs SDPA | cosine {1}" -f $v.speedup_vs_sdpa, $v.error.cosine }
                    Write-Ok ("attention {0,-20} {1,8} ms  {2,6} TFLOPS{3}" -f $p.Name, $v.ms, $v.tflops, $extra)
                }
                else { Write-Info "attention $($p.Name): unavailable" }
            }
        }
        foreach ($n in $probe.notes) { Add-Finding $n }
    }
    else { Write-Warn2 "kernel probe produced no result:`n$($r.Output)" }
}

# ---- decide flags
$probeOk = $probe -and $probe.ok -and $probe.PSObject.Properties["gemm"] -and $probe.PSObject.Properties["attention"]
$flags = New-Object System.Collections.Generic.List[string]
$rec = @()
if ($probe -and $probe.PSObject.Properties["recommended_flags"]) { $rec = @($probe.recommended_flags) }
$useFp16 = ($Fp16Accumulation -eq "on") -or ($Fp16Accumulation -eq "auto" -and ($rec -contains "--fast fp16_accumulation"))
$attn = "off"
if ($FastAttention -eq "ck" -or $FastAttention -eq "sage") { $attn = $FastAttention }
elseif ($FastAttention -eq "auto") {
    if ($rec -contains "--use-ck-attention") { $attn = "ck" }
    elseif ($rec -contains "--use-sage-attention") { $attn = "sage" }
}
if ($useFp16) { $flags.Add("--fast fp16_accumulation") }
if ($attn -eq "ck") { $flags.Add("--use-ck-attention") }
if ($attn -eq "sage") { $flags.Add("--use-sage-attention") }
if ($ReserveVramGB -gt 0) { $flags.Add(("--reserve-vram {0}" -f $ReserveVramGB.ToString([Globalization.CultureInfo]::InvariantCulture))) }
$flagStr = ($flags -join " ")
Write-Ok "selected flags: $(if ($flagStr) { $flagStr } else { '(ComfyUI defaults are already optimal on this setup)' })"

# --------------------------------------------------------------------------------------------- #
# 6. Launchers
# --------------------------------------------------------------------------------------------- #
Write-Step "Launchers"
$hdr = "@echo off`r`nREM Generated by Optimize-ComfyUI.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Re-run the optimizer to regenerate.`r`n" +
"REM Deliberately NOT used: --highvram/--gpu-only (disable dynamic VRAM), bare --fast (turns off cudaMallocAsync),`r`n" +
"REM --fast fp8_matrix_mult (no FP8 tensor cores on a 3090), TorchCompileModel (drops dynamic VRAM).`r`n" +
"cd /d `"%~dp0`"`r`nset PYTHONUTF8=1`r`n"
$main = ".\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build --port $Port"
$noInt8 = ($flags | Where-Object { $_ -notmatch "attention" }) -join " "
$launchers = [ordered]@{
    "run_optimized.bat"             = $hdr + "$main $flagStr %*`r`npause`r`n"
    "run_optimized_no_int8attn.bat" = $hdr + "REM Fallback if run_optimized.bat gives black/noisy/washed-out frames (INT8 attention overflow).`r`n$main $noInt8 %*`r`npause`r`n"
    "run_remote_tailscale.bat"      = $hdr + @"
REM Binds ONLY to localhost + this machine's Tailscale IP (not 0.0.0.0), so the LAN/Internet cannot reach it.
set "TSIP="
set "TS=tailscale"
where tailscale >nul 2>nul || set "TS=%ProgramFiles%\Tailscale\tailscale.exe"
for /f "usebackq delims=" %%i in (``call "%TS%" ip -4 2^>nul``) do if not defined TSIP set "TSIP=%%i"
if not defined TSIP (
  echo Tailscale is not running or not logged in. Start Tailscale and try again.
  pause
  exit /b 1
)
echo Serving on http://%TSIP%:$Port  ^(tailnet only^)
$main --disable-auto-launch --listen 127.0.0.1,%TSIP% $flagStr %*
pause
"@
    "run_probe.bat"                 = $hdr + ".\python_embeded\python.exe -s optimizer\bench\kernel_probe.py %*`r`npause`r`n"
    "run_bench.bat"                 = $hdr + @"
REM Usage: start ComfyUI with the launcher you want to measure, then:
REM   run_bench.bat LABEL [workflow.json] [extra comfy_bench args]
REM e.g. run_bench.bat baseline   (with run_nvidia_gpu.bat running)
REM      run_bench.bat optimized  (with run_optimized.bat running)
set "LABEL=%~1"
if "%LABEL%"=="" set "LABEL=run"
set "WF=%~2"
if "%WF%"=="" set "WF=optimizer\workflows\wan22_i2v_4step_api.json"
.\python_embeded\python.exe -s optimizer\bench\comfy_bench.py run "%WF%" --host 127.0.0.1:$Port --label "%LABEL%" --runs 3 --seed 1234 --csv optimizer\bench_results.csv %3 %4 %5 %6 %7 %8 %9
.\python_embeded\python.exe -s optimizer\bench\comfy_bench.py compare optimizer\bench_results.csv --baseline baseline
pause
"@
}
$autoMode = ($Fp16Accumulation -eq "auto") -or ($FastAttention -eq "auto")
if ($ReportOnly) { Write-Info "report-only: would write $($launchers.Keys -join ', ')" }
else {
    foreach ($k in $launchers.Keys) {
        $path = Join-Path $Root $k
        $flagged = $k -in @("run_optimized.bat", "run_optimized_no_int8attn.bat", "run_remote_tailscale.bat")
        if ($flagged -and $autoMode -and -not $probeOk -and (Test-Path $path)) {
            Write-Warn2 "GPU probe did not complete, keeping the existing $k instead of regenerating it without measured flags"
            continue
        }
        $content = ($launchers[$k] -replace "`r?`n", "`r`n")
        $same = (Test-Path $path) -and ((Get-Content -Raw $path) -replace "REM Generated by .*", "") -eq ($content -replace "REM Generated by .*", "")
        if ($same) { Write-Ok "$k unchanged" }
        else { Write-TextFile -Path $path -Content $content -Ascii; Add-Action "wrote $k" }
    }
}

# --------------------------------------------------------------------------------------------- #
# 7. Windows / driver
# --------------------------------------------------------------------------------------------- #
Write-Step "Windows / driver"
if ($env:OS -eq "Windows_NT") {
    try {
        $hags = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -ErrorAction Stop).HwSchMode
        Write-Info "Hardware-accelerated GPU scheduling: $(if ($hags -eq 2) { 'ON' } else { 'OFF' }) (no measurable effect on CUDA throughput; leave as is)"
    }
    catch { Write-Info "HAGS setting not readable (default)" }
    Add-Finding ("NVIDIA Control Panel > Manage 3D settings > Program Settings > add '$Py' > " +
        "'CUDA - Sysmem Fallback Policy' = 'Prefer No Sysmem Fallback'. Otherwise the driver silently spills VRAM " +
        "into shared system RAM and a render runs 5-10x slower instead of letting ComfyUI offload properly.")
    $isAdmin = Test-IsAdmin
    if ($ApplyWindowsTweaks -and -not $ReportOnly) {
        if (-not $isAdmin) { Write-Warn2 "-ApplyWindowsTweaks needs an elevated PowerShell; skipped" }
        else {
            $active = (Invoke-Native -Exe "powercfg" -Arguments @("/getactivescheme")).Output
            if ($active -notmatch "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c") {
                [void](Invoke-Native -Exe "powercfg" -Arguments @("/setactive", "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"))
                Add-Action "power plan -> High performance (faster model load / CPU-side sampling overhead)"
            }
            else { Write-Ok "High performance power plan already active" }
            try {
                $ex = (Get-MpPreference).ExclusionPath
                if (-not ($ex -contains $Models)) {
                    Add-MpPreference -ExclusionPath $Models
                    Add-Action "Defender real-time scan exclusion for $Models (safetensors are data; avoids scanning 14 GB files on every load)"
                }
                else { Write-Ok "Defender exclusion for models already present" }
            }
            catch { Write-Warn2 "could not set Defender exclusion: $($_.Exception.Message)" }
        }
    }
    elseif (-not $ApplyWindowsTweaks) { Write-Info "system tweaks skipped (pass -ApplyWindowsTweaks from an elevated PowerShell to apply)" }
    if ($PowerLimitW -gt 0 -and $nvsmi -and -not $ReportOnly) {
        if (-not $isAdmin) { Write-Warn2 "-PowerLimitW needs an elevated PowerShell; skipped" }
        else {
            $r = Invoke-Native -Exe $nvsmi.Source -Arguments @("-i", "0", "-pl", "$PowerLimitW")
            if ($r.ExitCode -eq 0) { Add-Action "GPU power limit -> $PowerLimitW W (until reboot)" } else { Write-Warn2 "nvidia-smi -pl failed: $($r.Output)" }
        }
    }
}

# --------------------------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------------------------- #
Write-Step "Summary"
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# ComfyUI optimizer report $($script:Stamp)")
$lines.Add("")
$lines.Add("Install: $Root")
if ($gpu) { $lines.Add("GPU: $($gpu.Name), driver $($gpu.Driver), $($gpu.VramMiB) MiB") }
if ($pyInfo) { $lines.Add("torch $($pyInfo.torch) (CUDA $($pyInfo.cuda)), Python $($pyInfo.python), ComfyUI $($pyInfo.comfyui)") }
$lines.Add("RAM: $ramGB GB")
$lines.Add("Launcher flags: $flagStr")
$lines.Add("")
$lines.Add("## Actions")
foreach ($a in $script:Actions) { $lines.Add("- $a") }
if ($script:Actions.Count -eq 0) { $lines.Add("- (none; already optimized or report-only)") }
$lines.Add("")
$lines.Add("## Findings")
foreach ($f in $script:Findings) { $lines.Add("- $f") }
$lines.Add("")
$lines.Add("## Next")
$lines.Add("1. In the Wan 2.2 14B template, set 'Enable 4steps LoRA?' / 'Enable Lightning LoRA' to true (off by default: 20 steps).")
$lines.Add("2. Baseline: run_nvidia_gpu.bat, then run_bench.bat baseline. Close ComfyUI.")
$lines.Add("3. Optimized: run_optimized.bat, then run_bench.bat optimized. Compare the table + watch the video for artifacts.")
$report = $lines -join "`r`n"
if (-not $ReportOnly) {
    $rp = Join-Path $OptDir "report-$($script:Stamp).md"
    Write-TextFile -Path $rp -Content $report
    Write-Ok "report: $rp"
}
Write-Host ""
Write-Host $report
