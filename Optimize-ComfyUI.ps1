<#
.SYNOPSIS
    Optimize-ComfyUI.ps1 - idempotent, resume-safe performance tuner for ComfyUI Windows Portable
    on an RTX 3090 (24 GB, Ampere sm_86) running Wan 2.2 14B video workflows.

.DESCRIPTION
    Safe to re-run at any time. Every phase checks current state first and only changes what is
    missing or out of date. Nothing is deleted: replaced files are kept as .bak-<stamp>, and every
    change is logged to <InstallDir>\optimizer\ (report, pip snapshot, rollback scripts).

    Phases
      1. Preflight   GPU / driver / VRAM / RAM / pagefile / disk / torch / ComfyUI audit, plus a scan
                     of your existing .bat launchers for flags that are now harmful.
      2. Update      ComfyUI on the channel you already use (stable tag or latest master) + its pinned
                     python deps (comfy-kitchen = kernels, comfy-aimdo = dynamic VRAM manager).
      3. Torch       Moves torch to the CUDA 13.0 build if it is older and the driver supports it.
                     ComfyUI disables the comfy-kitchen CUDA backend below cu130, and comfy-kitchen's
                     extension links cublasLt64_13 (so INT8 attention needs cu130). Verified after
                     install; rolled back to the exact previous versions if anything is wrong.
      4. Models      lightx2v 4-step LoRAs for Wan 2.2 (the single largest speedup: 20 -> 4 steps).
      5. Probe       bench\kernel_probe.py on YOUR GPU: fp16-accumulation GEMM and INT8 attention
                     speed + error vs PyTorch SDPA decide the launcher flags.
      6. Launchers   run_optimized.bat, run_optimized_no_int8attn.bat, run_remote_tailscale.bat,
                     run_probe.bat, run_bench.bat in the portable root (old versions backed up).
      7. Windows     (opt-in, admin) power plan, Defender exclusion for safetensors-only model folders,
                     optional GPU power limit. Reports the NVIDIA sysmem-fallback setting.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-ComfyUI.ps1 -InstallDir "D:\AI\ComfyUI_windows_portable"
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-ComfyUI.ps1 -ReportOnly
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-ComfyUI.ps1 -UpdateChannel none -UpgradeTorch off
#>
[CmdletBinding()]
param(
    # ============================ CONFIG ============================
    # Portable root (the folder that contains python_embeded\ and ComfyUI\). If you do not pass it
    # and the default is wrong, the script searches local drives and refuses to guess between several.
    [string]$InstallDir = "C:\AI\ComfyUI_windows_portable",

    # auto = keep the channel you are on (tracking master -> latest, otherwise -> stable tag); none = skip.
    [ValidateSet("auto", "stable", "latest", "none")]
    [string]$UpdateChannel = "auto",

    # auto = move torch to cu130 only if it is older AND the driver is >= 580. off = never touch torch.
    [ValidateSet("auto", "off")]
    [string]$UpgradeTorch = "auto",

    # lightx2v 4-step distill LoRAs (same file names the official templates use).
    [switch]$SkipT2V,
    [switch]$SkipI2V,

    # Flag selection. auto = decided by the on-GPU probe. on/off (or ck/sage/off) = force.
    [ValidateSet("auto", "on", "off")]
    [string]$Fp16Accumulation = "auto",
    [ValidateSet("auto", "ck", "sage", "off")]
    [string]$FastAttention = "auto",

    # VRAM (GB) that ComfyUI's dynamic VRAM manager keeps completely free, counting other apps'
    # usage (--vram-headroom). 0 = ComfyUI default. 1.5-2 if you game/stream on the GPU meanwhile.
    [double]$VramHeadroomGB = 0,

    [int]$Port = 8188,

    # Admin-only system tweaks (power plan, Defender exclusion for safetensors-only model folders).
    [switch]$ApplyWindowsTweaks,
    # GPU board power limit in watts (0 = leave alone). 3090 FE default is 350 W; 280-300 W typically
    # costs <5% speed and runs the GDDR6X much cooler on long batches. Resets on reboot.
    [int]$PowerLimitW = 0,

    # Audit only: no updates, installs, downloads or launcher changes. Writes only the report.
    [switch]$ReportOnly
    # ================================================================
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$script:Findings = New-Object System.Collections.Generic.List[string]
$script:Actions = New-Object System.Collections.Generic.List[string]
$script:Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Kit = $PSScriptRoot
$IsWin = ($env:OS -eq "Windows_NT")

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

# StrictMode-safe property read for objects from ConvertFrom-Json (missing -> $null).
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Test-IsAdmin {
    if (-not $IsWin) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Run a native command without tripping $ErrorActionPreference=Stop on stderr output.
# -Passthru streams output to the console instead of capturing it (never leaks into return values).
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory = $null, [switch]$Passthru)
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        if ($Passthru) {
            & $Exe @Arguments | Out-Host
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = "" }
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
    # -1/0/1 comparing dotted numeric versions, ignoring local tags like +cu130
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
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Content = $Content -replace "`r?`n", "`r`n"
    if ($Ascii) { $enc = New-Object System.Text.ASCIIEncoding }
    else { $enc = New-Object System.Text.UTF8Encoding($false) }
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Test-Portable([string]$Path) {
    if (-not $Path) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path "python_embeded")) -and
    (Test-Path -LiteralPath (Join-Path (Join-Path $Path "ComfyUI") "main.py"))
}

function Find-InstallDir {
    if (Test-Portable $InstallDir) { return (Resolve-Path -LiteralPath $InstallDir).Path }
    if ($PSBoundParameters.ContainsKey("InstallDir") -or $script:InstallDirPassed) {
        throw "-InstallDir '$InstallDir' is not a ComfyUI portable root (needs python_embeded\ and ComfyUI\main.py)."
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    $here = $Kit
    while ($here) {
        $candidates.Add($here)
        $parent = Split-Path -Parent $here
        if (-not $parent -or $parent -eq $here) { break }
        $here = $parent
    }
    if ($IsWin) {
        # local fixed disks only (DriveType 3): never touch network or removable drives
        foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)) {
            $root = "$($d.DeviceID)\"
            foreach ($pattern in @("ComfyUI_windows_portable*", "AI\ComfyUI_windows_portable*", "ComfyUI\ComfyUI_windows_portable*")) {
                Get-ChildItem -Path (Join-Path $root $pattern) -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { $candidates.Add($_.FullName) }
            }
        }
        foreach ($sub in @("ComfyUI_windows_portable", "Desktop\ComfyUI_windows_portable", "Downloads\ComfyUI_windows_portable")) {
            $candidates.Add((Join-Path $env:USERPROFILE $sub))
        }
    }
    $found = @($candidates | Where-Object { Test-Portable $_ } | ForEach-Object { (Resolve-Path -LiteralPath $_).Path } | Select-Object -Unique)
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -gt 1) { throw "Found several ComfyUI portable installs; pass -InstallDir with the one to optimize:`n  $($found -join "`n  ")" }
    throw "Could not find ComfyUI portable (a folder with python_embeded\ and ComfyUI\main.py). Pass -InstallDir."
}

function Invoke-KitPython([string]$Script, [string[]]$Arguments = @()) {
    # Runs a helper .py by path (never `python -c`: PS 5.1 mangles embedded quotes). Returns parsed JSON or $null.
    $path = Join-Path (Join-Path $Kit "bench") $Script
    $r = Invoke-Native -Exe $Py -Arguments (@("-s", $path) + $Arguments)
    $line = @(($r.Output -split "`n") | Where-Object { $_ -like "JSON:*" -or $_.TrimStart().StartsWith("{") }) | Select-Object -Last 1
    if (-not $line) { return [pscustomobject]@{ Parsed = $null; Raw = $r.Output; ExitCode = $r.ExitCode } }
    if ($line -like "JSON:*") { $line = $line.Substring(5) }
    try { $obj = $line | ConvertFrom-Json } catch { $obj = $null }
    return [pscustomobject]@{ Parsed = $obj; Raw = $r.Output; ExitCode = $r.ExitCode }
}

function Get-PyInfo { return (Invoke-KitPython "env_info.py" @($ComfyDir)).Parsed }

function Get-CudaMajor($info) {
    $c = Get-Prop $info "cuda"
    if (-not $c) { return 0 }
    return [int](($c -split "\.")[0])
}

function Get-RemoteSize([string]$Url) {
    # Size of the file behind $Url (HF -> CDN redirects). -1 if unknown. Never trusts an error page.
    $r = Invoke-Native -Exe $script:Curl -Arguments @("-sSIL", "--fail", "--max-time", "60", $Url)
    if ($r.ExitCode -ne 0) { return -1 }
    $linked = -1; $status = 0; $len = -1
    foreach ($line in ($r.Output -split "`n")) {
        if ($line -match "^HTTP/\S+\s+(\d{3})") { $status = [int]$Matches[1]; $len = -1 }
        elseif ($line -match "^(?i)x-linked-size:\s*(\d+)") { $linked = [int64]$Matches[1] }
        elseif ($line -match "^(?i)content-length:\s*(\d+)") { $len = [int64]$Matches[1] }
    }
    if ($linked -gt 0) { return $linked }
    if ($status -eq 200 -and $len -gt 0) { return $len }
    return -1
}

function Save-File([string]$Url, [string]$Dest) {
    $name = Split-Path -Leaf $Dest
    $part = "$Dest.part"
    $expected = Get-RemoteSize $Url
    $have = -1
    if (Test-Path -LiteralPath $Dest) {
        $have = (Get-Item -LiteralPath $Dest).Length
        if (($expected -gt 0 -and $have -eq $expected) -or ($expected -le 0 -and $have -gt 1MB)) {
            Write-Ok ("{0} present ({1:N0} MB)" -f $name, ($have / 1MB))
            return $true
        }
    }
    if ($ReportOnly) {
        if ($have -ge 0) { Write-Warn2 "$name is $have bytes, expected $expected; a normal run would re-download it" }
        else { Add-Finding "missing: models\loras\$name (a normal run downloads it)" }
        return $false
    }
    if ($expected -le 0 -and $have -ge 0) {
        Write-Warn2 "$name is only $have bytes and its remote size cannot be checked right now; left untouched, re-run later"
        return $false
    }
    $dir = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ($have -ge 0 -and $expected -gt 0 -and $have -lt $expected -and -not (Test-Path -LiteralPath $part)) {
        Move-Item -LiteralPath $Dest -Destination $part   # incomplete copy: resume from it
        $have = -1
    }
    if ((Test-Path -LiteralPath $part) -and $expected -gt 0 -and (Get-Item -LiteralPath $part).Length -gt $expected) {
        Remove-Item -LiteralPath $part -Force             # stale/oversized partial: start over
    }
    if (-not ((Test-Path -LiteralPath $part) -and $expected -gt 0 -and (Get-Item -LiteralPath $part).Length -eq $expected)) {
        Write-Info "downloading $name (resume-safe) ..."
        $curlArgs = @("-L", "--fail", "--retry", "5", "--retry-delay", "5", "-o", $part, $Url)
        $r = Invoke-Native -Exe $script:Curl -Passthru -Arguments (@("-C", "-") + $curlArgs)
        if ($r.ExitCode -eq 33) {
            # server refused a byte-range resume: start this file over
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            $r = Invoke-Native -Exe $script:Curl -Passthru -Arguments $curlArgs
        }
        if ($r.ExitCode -ne 0) {
            Write-Warn2 "download of $name failed (curl exit $($r.ExitCode)); partial kept as .part, re-run to resume"
            return $false
        }
    }
    $got = (Get-Item -LiteralPath $part).Length
    if (($expected -gt 0 -and $got -ne $expected) -or ($expected -le 0 -and $got -lt 1MB)) {
        Write-Warn2 "$name downloaded $got bytes, expected $expected; kept as .part, re-run to resume"
        return $false
    }
    if (Test-Path -LiteralPath $Dest) {
        Move-Item -LiteralPath $Dest -Destination "$Dest.bak-$($script:Stamp)"
        Write-Warn2 "previous $name ($have bytes) kept as $name.bak-$($script:Stamp)"
    }
    Move-Item -LiteralPath $part -Destination $Dest
    Add-Action ("downloaded {0} ({1:N0} MB)" -f $name, ($got / 1MB))
    return $true
}

# --------------------------------------------------------------------------------------------- #
# 1. Preflight
# --------------------------------------------------------------------------------------------- #
Write-Step "Preflight"
$script:InstallDirPassed = $PSBoundParameters.ContainsKey("InstallDir")
$Root = Find-InstallDir
if ($Root -ne $InstallDir) { Write-Info "InstallDir auto-detected: $Root" }
$Py = $null
foreach ($name in @("python.exe", "python")) {
    $p = Join-Path (Join-Path $Root "python_embeded") $name
    if (Test-Path -LiteralPath $p) { $Py = $p; break }
}
if (-not $Py) { throw "python_embeded\python.exe not found under $Root" }
$ComfyDir = Join-Path $Root "ComfyUI"
$OptDir = Join-Path $Root "optimizer"
$Models = Join-Path $ComfyDir "models"
New-Item -ItemType Directory -Force -Path $OptDir | Out-Null   # report goes here, even with -ReportOnly
Write-Ok "portable root: $Root"

# Windows locks torch's DLLs while ComfyUI runs; pip-upgrading underneath it leaves a half-installed torch.
$pyDir = Join-Path $Root "python_embeded"
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($pyDir, [StringComparison]::OrdinalIgnoreCase) } catch { $false } })
if ($running.Count -gt 0) {
    if (-not $ReportOnly) {
        throw "ComfyUI is running from this install (PID $($running.Id -join ', ')). Close it, then re-run. (-ReportOnly works while it runs.)"
    }
    Write-Info "ComfyUI is running (PID $($running.Id -join ', ')); the GPU probe will be skipped"
}

# curl.exe ships with Windows 10 1803+ (bare 'curl' is an alias for Invoke-WebRequest in PS 5.1)
$script:Curl = $null
$c = @(Get-Command "curl.exe", "curl" -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
if ($c) { $script:Curl = $c.Source } else { Write-Warn2 "curl.exe not found; model downloads and index checks will be skipped" }

# ---- GPU / driver
$gpu = $null
$nvsmi = @(Get-Command "nvidia-smi" -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
if ($nvsmi) {
    $q = "name,driver_version,memory.total,memory.used,pcie.link.gen.max,pcie.link.width.max,power.limit,power.default_limit,power.max_limit,temperature.gpu"
    $r = Invoke-Native -Exe $nvsmi.Source -Arguments @("--query-gpu=$q", "--format=csv,noheader,nounits", "-i", "0")
    $f = @((($r.Output -split "`n")[0]) -split ",\s*")
    if ($r.ExitCode -eq 0 -and $f.Count -ge 10) {
        $gpu = [pscustomobject]@{
            Name = $f[0]; Driver = $f[1]; VramMiB = $f[2]; UsedMiB = $f[3]
            PcieGen = $f[4]; PcieWidth = $f[5]; PowerLimit = $f[6]; PowerDefault = $f[7]; PowerMax = $f[8]; TempC = $f[9]
        }
        Write-Ok ("GPU {0} | driver {1} | {2} MiB VRAM ({3} MiB in use now) | PCIe gen{4} x{5} | {6} W limit" -f `
                $gpu.Name, $gpu.Driver, $gpu.VramMiB, $gpu.UsedMiB, $gpu.PcieGen, $gpu.PcieWidth, $gpu.PowerLimit)
        if ($gpu.UsedMiB -match "^\d+$" -and [int]$gpu.UsedMiB -gt 1500) {
            Write-Warn2 "$($gpu.UsedMiB) MiB VRAM already in use before ComfyUI starts (browser/Discord/games/desktop). Close GPU apps or pass -VramHeadroomGB."
        }
        if ($gpu.PcieWidth -match "^\d+$" -and [int]$gpu.PcieWidth -lt 16) {
            Write-Warn2 "GPU max link width is x$($gpu.PcieWidth). Expert swaps between the high/low-noise Wan models cross PCIe; use the x16 slot."
        }
    }
    else { Write-Warn2 "nvidia-smi query failed: $($r.Output)" }
}
else { Write-Warn2 "nvidia-smi not found; NVIDIA driver missing or not on PATH" }

# ---- RAM / pagefile / disk
$ramGB = 0
if ($IsWin) {
    $cs = Get-CimInstance Win32_ComputerSystem
    $ramGB = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    Write-Ok "system RAM: $ramGB GB"
    # Wan 2.2 14B fp8: two experts (~14.3 GB each) + umt5 fp8 (~6.7 GB) + LoRAs + VAE ~= 37 GB of weights
    if ($ramGB -lt 48) {
        Write-Warn2 "RAM $ramGB GB < 48 GB: the two Wan 2.2 14B experts + text encoder (~37 GB) cannot all stay cached; expect disk re-reads on expert swaps. 64 GB is the practical floor for Wan 2.2 14B."
    }
    $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    $pfGB = 0
    if ($pf.Count -gt 0) { $pfGB = [Math]::Round((($pf | Measure-Object AllocatedBaseSize -Sum).Sum) / 1024, 1) }
    Write-Info "pagefile: $pfGB GB allocated (system-managed: $($cs.AutomaticManagedPagefile))"
    if (-not $cs.AutomaticManagedPagefile -and $pfGB -lt 32) {
        Write-Warn2 "pagefile is fixed at $pfGB GB. Windows does not overcommit; loading 14B models with a small pagefile causes 'paging file too small' crashes. Set system-managed or >= 32 GB on an NVMe drive."
    }
    try {
        $letter = (Split-Path -Qualifier $Models).TrimEnd(":")
        $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.DeviceId)" -eq "$($part.DiskNumber)" } | Select-Object -First 1
        $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
        $freeGB = [Math]::Round($vol.SizeRemaining / 1GB, 0)
        if ($disk) {
            Write-Ok "models drive ${letter}: $($disk.FriendlyName) | bus $($disk.BusType) | media $($disk.MediaType) | $freeGB GB free"
            if ("$($disk.MediaType)" -eq "HDD") {
                Write-Warn2 "models are on a spinning HDD. Loading/swapping the 14 GB Wan experts will dominate run time. Move ComfyUI\models to NVMe."
            }
            elseif ("$($disk.BusType)" -ne "NVMe") {
                Add-Finding "models drive is $($disk.BusType) (not NVMe); expert loads from disk are several times slower than NVMe"
            }
        }
        if ($freeGB -lt 25) { Write-Warn2 "only $freeGB GB free on the models drive" }
    }
    catch { Write-Info "could not query disk type for the models folder ($($_.Exception.Message))" }
}

# ---- Python / torch / ComfyUI
$pyInfo = Get-PyInfo
if (-not $pyInfo) { Write-Warn2 "could not query the embedded Python" }
elseif (Get-Prop $pyInfo "torch_error") {
    Write-Warn2 "torch failed to import in the embedded Python: $(Get-Prop $pyInfo 'torch_error'). Install the VC++ runtime (https://aka.ms/vc14/vc_redist.x64.exe) or run update\update_comfyui_and_python_dependencies.bat, then re-run."
}
else {
    Write-Ok ("Python {0} | torch {1} (CUDA {2}, cuda_available={3}) | ComfyUI {4}" -f `
        (Get-Prop $pyInfo "python"), (Get-Prop $pyInfo "torch"), (Get-Prop $pyInfo "cuda"), (Get-Prop $pyInfo "cuda_ok"), (Get-Prop $pyInfo "comfyui"))
    Write-Info ("comfy-kitchen {0} | comfy-aimdo {1} | frontend {2} | xformers {3} | sageattention {4} | CK INT8 attention available: {5}" -f `
        (Get-Prop $pyInfo "pkg_comfy-kitchen"), (Get-Prop $pyInfo "pkg_comfy-aimdo"), (Get-Prop $pyInfo "pkg_comfyui-frontend-package"),
        (Get-Prop $pyInfo "pkg_xformers"), (Get-Prop $pyInfo "pkg_sageattention"), (Get-Prop $pyInfo "ck_int8_attention"))
}

# ---- existing (hand-made) launchers: flags that are now counter-productive
Get-ChildItem -LiteralPath $Root -Filter "*.bat" -ErrorAction SilentlyContinue | ForEach-Object {
    $txt = [string](Get-Content -Raw -LiteralPath $_.FullName)
    if ($txt -match "Generated by Optimize-ComfyUI\.ps1") { return }
    if ($txt -match "--highvram|--gpu-only") {
        Write-Warn2 "$($_.Name) uses --highvram/--gpu-only: this DISABLES ComfyUI's dynamic VRAM manager (comfy-aimdo). Remove it."
    }
    if ($txt -match "--fast(\s*$|\s+--|\s+%|\s*\r?\n)") {
        Write-Warn2 "$($_.Name) uses bare --fast: that also enables 'autotune', which turns OFF cudaMallocAsync. Use '--fast fp16_accumulation' instead."
    }
    if ($txt -match "--lowvram|--novram") {
        Write-Warn2 "$($_.Name) uses --lowvram/--novram: unnecessary on 24 GB, and --novram disables dynamic VRAM."
    }
    if ($txt -match "--disable-smart-memory") {
        Write-Warn2 "$($_.Name) uses --disable-smart-memory: forces models out of VRAM after every run (slower 2nd+ generations)."
    }
    if ($txt -match "--use-sage-attention") {
        Add-Finding "$($_.Name) uses --use-sage-attention: comfy-kitchen ships an equivalent INT8 attention (--use-ck-attention) with no separate wheel to keep in sync with torch."
    }
}

# --------------------------------------------------------------------------------------------- #
# 2. Update ComfyUI + pinned deps
# --------------------------------------------------------------------------------------------- #
Write-Step "ComfyUI update"
$updDir = Join-Path $Root "update"
$updPy = Join-Path $updDir "update.py"
$channel = $UpdateChannel
if ($channel -eq "auto") {
    $headFile = Join-Path (Join-Path $ComfyDir ".git") "HEAD"
    if (Test-Path -LiteralPath $headFile) {
        $head = ([string](Get-Content -Raw -LiteralPath $headFile)).Trim()
        if ($head -eq "ref: refs/heads/master") { $channel = "latest" } else { $channel = "stable" }
        Write-Info "current checkout: $(if ($channel -eq 'latest') { 'master branch' } else { 'release tag / detached' }) -> '$channel' channel"
    }
    else { $channel = "none"; Write-Warn2 "ComfyUI\.git not found (not a git checkout); skipping the update" }
}
if ($channel -eq "none") { Write-Info "skipped" }
elseif ($ReportOnly) { Write-Info "report-only: would update ComfyUI ($channel channel) and pin comfy-kitchen / comfy-aimdo" }
elseif (-not (Test-Path -LiteralPath $updPy)) { Write-Warn2 "update\update.py not found; update ComfyUI manually" }
else {
    $freeze = Invoke-Native -Exe $Py -Arguments @("-s", "-m", "pip", "freeze")
    Write-TextFile -Path (Join-Path $OptDir "pip-freeze-before-$($script:Stamp).txt") -Content $freeze.Output
    Write-Info "the updater stashes local edits to ComfyUI's own files and creates a backup_branch_* first (custom_nodes are untouched)"
    $uargs = @($updPy, $ComfyDir)
    if ($channel -eq "stable") { $uargs += "--stable" }
    $r = Invoke-Native -Exe $Py -Arguments $uargs -WorkingDirectory $updDir -Passthru
    if (Test-Path -LiteralPath (Join-Path $updDir "update_new.py")) {
        # update.py updated itself; run the new one once (same as update_comfyui*.bat)
        Move-Item -Force -LiteralPath (Join-Path $updDir "update_new.py") -Destination $updPy
        $r = Invoke-Native -Exe $Py -Arguments ($uargs + "--skip_self_update") -WorkingDirectory $updDir -Passthru
    }
    if ($r.ExitCode -eq 0) { Add-Action "ComfyUI updated ($channel channel; requirements.txt deps installed if changed)" }
    else { Write-Warn2 "updater exited with $($r.ExitCode); check the output above" }
    # update.py reinstalls requirements only when requirements.txt changed; make sure the two packages
    # that carry the memory manager + kernels are at the pinned versions regardless.
    $req = Join-Path $ComfyDir "requirements.txt"
    if (Test-Path -LiteralPath $req) {
        $pins = @(Select-String -LiteralPath $req -Pattern "^(comfy-kitchen|comfy-aimdo)==" | ForEach-Object { $_.Line.Trim() })
        if ($pins.Count -gt 0) {
            $r = Invoke-Native -Exe $Py -Arguments (@("-s", "-m", "pip", "install", "--disable-pip-version-check", "-q") + $pins)
            if ($r.ExitCode -eq 0) { Write-Ok "pinned: $($pins -join ', ')" } else { Write-Warn2 "pip install $($pins -join ' ') failed:`n$($r.Output)" }
        }
    }
    $pyInfo = Get-PyInfo
}

# --------------------------------------------------------------------------------------------- #
# 3. Torch -> cu130
# --------------------------------------------------------------------------------------------- #
Write-Step "PyTorch CUDA build"
$cudaMajor = Get-CudaMajor $pyInfo
$oldTorch = Get-Prop $pyInfo "pkg_torch"
if (-not $pyInfo -or -not (Get-Prop $pyInfo "cuda")) { Write-Info "torch CUDA version unknown; skipped" }
elseif ($cudaMajor -ge 13) { Write-Ok "torch $(Get-Prop $pyInfo 'torch') is a CUDA $(Get-Prop $pyInfo 'cuda') build (comfy-kitchen CUDA kernels + INT8 attention enabled)" }
else {
    Write-Warn2 "torch is built for CUDA $(Get-Prop $pyInfo 'cuda'). ComfyUI disables the comfy-kitchen CUDA backend below cu130 and its INT8 attention needs cuBLASLt 13; ComfyUI's README calls cu130 required on RTX 20-series and newer."
    $driverOk = $gpu -and ((Compare-Version $gpu.Driver "580.0") -ge 0)
    $sysDrive = "?"
    $freeGB = 999
    if ($IsWin) {
        try {
            $sysDrive = (Split-Path -Qualifier $Root).TrimEnd(":")
            $freeGB = [Math]::Round((Get-Volume -DriveLetter $sysDrive -ErrorAction Stop).SizeRemaining / 1GB, 0)
        }
        catch { Write-Info "could not read free space for the install drive" }
    }
    if ($UpgradeTorch -eq "off") { Write-Info "skipped (-UpgradeTorch off)" }
    elseif (-not $gpu) { Write-Warn2 "GPU/driver unknown (nvidia-smi failed); not touching torch" }
    elseif (-not $driverOk) { Write-Warn2 "NVIDIA driver $($gpu.Driver) < 580: cu130 torch needs driver >= 580. Update the driver (Studio driver is fine), then re-run." }
    elseif (-not $oldTorch) { Write-Warn2 "cannot read the installed torch version from pip metadata; not upgrading (no safe rollback target)" }
    elseif ($freeGB -lt 10) { Write-Warn2 "only $freeGB GB free on ${sysDrive}: (need ~10 GB for the torch upgrade); skipped" }
    elseif ($ReportOnly) { Write-Info "report-only: would install torch/torchvision/torchaudio from https://download.pytorch.org/whl/cu130" }
    elseif (-not $script:Curl -or (Invoke-Native -Exe $script:Curl -Arguments @("-sSfI", "--max-time", "30", "https://download.pytorch.org/whl/cu130/torch/")).ExitCode -ne 0) {
        Write-Warn2 "cannot reach https://download.pytorch.org/whl/cu130 right now; not touching torch (re-run later)"
    }
    else {
        $oldCu = "cu" + ((Get-Prop $pyInfo "cuda") -replace "\.", "")
        $oldTv = Get-Prop $pyInfo "pkg_torchvision"
        $oldTa = Get-Prop $pyInfo "pkg_torchaudio"
        $oldXf = Get-Prop $pyInfo "pkg_xformers"
        $pinsOld = @("torch==$oldTorch")
        if ($oldTv) { $pinsOld += "torchvision==$oldTv" }
        if ($oldTa) { $pinsOld += "torchaudio==$oldTa" }
        $idx = "https://download.pytorch.org/whl/$oldCu"
        $rbName = "rollback-torch-$($script:Stamp).bat"
        $rb = "@echo off`r`nREM Restores the exact torch stack from before $($script:Stamp).`r`ncd /d `"%~dp0..`"`r`n" +
        ".\python_embeded\python.exe -s -m pip install --force-reinstall --no-deps $($pinsOld -join ' ') --index-url $idx`r`n"
        if ($oldXf) { $rb += ".\python_embeded\python.exe -s -m pip install --no-deps xformers==$oldXf --index-url $idx`r`n" }
        $rb += "pause`r`n"
        Write-TextFile -Path (Join-Path $OptDir $rbName) -Content $rb -Ascii
        $ok = $false
        try {
            if ($oldXf) {
                # built against the old torch: on the new one it fails to load but still shadows PyTorch attention
                [void](Invoke-Native -Exe $Py -Arguments @("-s", "-m", "pip", "uninstall", "-y", "xformers"))
                Add-Action "uninstalled xformers $oldXf (built for the old torch; restored by optimizer\$rbName if you roll back)"
            }
            Write-Info "installing torch cu130 from download.pytorch.org (~3 GB) ..."
            # --index-url (not --extra-index-url): if the CUDA index is unreachable this FAILS instead of
            # silently taking PyPI's torch, which on Windows is a CPU-only build.
            $r = Invoke-Native -Exe $Py -Passthru -Arguments @("-s", "-m", "pip", "install", "--upgrade", "--disable-pip-version-check",
                "torch", "torchvision", "torchaudio", "--index-url", "https://download.pytorch.org/whl/cu130")
            $after = Get-PyInfo
            $ok = ($r.ExitCode -eq 0) -and (-not (Get-Prop $after "torch_error")) -and ((Get-CudaMajor $after) -ge 13) -and (Get-Prop $after "cuda_ok")
            if ($ok) {
                Add-Action "torch $oldTorch -> $(Get-Prop $after 'torch') (CUDA $(Get-Prop $after 'cuda')); rollback: optimizer\$rbName"
                $pyInfo = $after
            }
            else {
                Write-Warn2 ("torch upgrade did not produce a working CUDA 13 build (pip exit {0}; torch={1} cuda={2} cuda_available={3} error={4})" -f `
                        $r.ExitCode, (Get-Prop $after "torch"), (Get-Prop $after "cuda"), (Get-Prop $after "cuda_ok"), (Get-Prop $after "torch_error"))
            }
        }
        catch { Write-Warn2 "torch upgrade threw: $($_.Exception.Message)" }
        if (-not $ok) {
            Write-Info "rolling back to $($pinsOld -join ', ') ..."
            $rr = Invoke-Native -Exe $Py -Passthru -Arguments (@("-s", "-m", "pip", "install", "--force-reinstall", "--no-deps", "--disable-pip-version-check") + $pinsOld + @("--index-url", $idx))
            if ($oldXf) { [void](Invoke-Native -Exe $Py -Passthru -Arguments @("-s", "-m", "pip", "install", "--no-deps", "--disable-pip-version-check", "xformers==$oldXf", "--index-url", $idx)) }
            $back = Get-PyInfo
            if ($rr.ExitCode -eq 0 -and (Get-Prop $back "pkg_torch") -eq $oldTorch -and (Get-Prop $back "cuda_ok")) {
                Write-Ok "rolled back to torch $oldTorch (CUDA working)"
            }
            else { Write-Warn2 "automatic rollback could not be verified; run optimizer\$rbName (needs download.pytorch.org)" }
            $pyInfo = $back
        }
    }
}

# --------------------------------------------------------------------------------------------- #
# 4. Models: lightx2v 4-step LoRAs
# --------------------------------------------------------------------------------------------- #
Write-Step "Wan 2.2 lightx2v 4-step LoRAs (20 -> 4 steps)"
$hf = "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras"
$loras = @()
if (-not $SkipI2V) { $loras += "wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors", "wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" }
if (-not $SkipT2V) { $loras += "wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors", "wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors" }
if (-not $script:Curl) { Write-Warn2 "curl.exe missing; skipping LoRA downloads" }
else {
    foreach ($l in $loras) { [void](Save-File "$hf/$l" (Join-Path (Join-Path $Models "loras") $l)) }
}
# the base models the benchmark workflows expect (installed by install-comfyui-wan22.ps1)
foreach ($m in @(
        @("diffusion_models", "wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"), @("diffusion_models", "wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"),
        @("diffusion_models", "wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"), @("diffusion_models", "wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"),
        @("text_encoders", "umt5_xxl_fp8_e4m3fn_scaled.safetensors"), @("vae", "wan_2.1_vae.safetensors"))) {
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $Models $m[0]) $m[1]))) {
        Add-Finding "not found: models\$($m[0])\$($m[1]) (benchmark workflows that use it will fail validation)"
    }
}

# --------------------------------------------------------------------------------------------- #
# 5. Copy bench kit + probe the GPU
# --------------------------------------------------------------------------------------------- #
Write-Step "On-GPU kernel probe"
if (-not $ReportOnly) {
    foreach ($sub in @("bench", "workflows", (Join-Path "workflows" "experimental"))) {
        $src = Join-Path $Kit $sub
        $dst = Join-Path $OptDir $sub
        if (Test-Path -LiteralPath $src) {
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            Get-ChildItem -LiteralPath $src -File | Where-Object { $_.Extension -in @(".py", ".json") } |
                ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dst $_.Name) -Force }
        }
    }
    [void](Invoke-Native -Exe $Py -Arguments @("-s", (Join-Path (Join-Path $Kit "bench") "make_start_image.py"),
            (Join-Path (Join-Path $ComfyDir "input") "bench_start.png")))
}
$probe = $null
if ($running.Count -gt 0) { Write-Info "skipped: ComfyUI is running" }
else {
    $pr = Invoke-KitPython "kernel_probe.py" @("--json", "--comfy-port", "$Port")
    $probe = $pr.Parsed
    if ($probe) {
        if (-not $ReportOnly) { Write-TextFile -Path (Join-Path $OptDir "probe-$($script:Stamp).json") -Content ($probe | ConvertTo-Json -Depth 8) }
        $g = Get-Prop $probe "gemm"
        if (Get-Prop $g "speedup") {
            Write-Ok ("fp16 GEMM: fp32-accum {0} TFLOPS -> fp16-accum {1} TFLOPS ({2}x, cosine {3})" -f `
                (Get-Prop $g "fp32_accum_tflops"), (Get-Prop $g "fp16_accum_tflops"), (Get-Prop $g "speedup"), (Get-Prop (Get-Prop $g "error") "cosine"))
        }
        $att = Get-Prop $probe "attention"
        if ($att) {
            foreach ($p in $att.PSObject.Properties) {
                $v = $p.Value
                if (Get-Prop $v "ms") {
                    $extra = ""
                    if (Get-Prop $v "speedup_vs_sdpa") { $extra = " | {0}x vs SDPA | cosine {1}" -f (Get-Prop $v "speedup_vs_sdpa"), (Get-Prop (Get-Prop $v "error") "cosine") }
                    Write-Ok ("attention {0,-20} {1,8} ms  {2,6} TFLOPS{3}" -f $p.Name, (Get-Prop $v "ms"), (Get-Prop $v "tflops"), $extra)
                }
                else { Write-Info "attention $($p.Name): unavailable $(Get-Prop $v 'error_msg')" }
            }
        }
        foreach ($n in @(Get-Prop $probe "notes")) { if ($n) { Add-Finding $n } }
    }
    else { Write-Warn2 "kernel probe produced no result:`n$($pr.Raw)" }
}

# ---- decide flags
$probeOk = [bool](Get-Prop $probe "ok") -and [bool](Get-Prop (Get-Prop $probe "gemm") "speedup") -and
[bool](Get-Prop (Get-Prop $probe "attention") "pytorch_sdpa")
$rec = @(Get-Prop $probe "recommended_flags")
$flags = New-Object System.Collections.Generic.List[string]
$useFp16 = ($Fp16Accumulation -eq "on") -or ($Fp16Accumulation -eq "auto" -and ($rec -contains "--fast fp16_accumulation"))
$attn = "off"
if ($FastAttention -eq "ck" -or $FastAttention -eq "sage") { $attn = $FastAttention }
elseif ($FastAttention -eq "auto") {
    if ($rec -contains "--use-ck-attention") { $attn = "ck" }
    elseif ($rec -contains "--use-sage-attention") { $attn = "sage" }
}
if ($attn -eq "ck" -and (Get-Prop $pyInfo "ck_int8_attention") -eq $false) {
    Write-Warn2 "--use-ck-attention requested but comfy-kitchen INT8 attention is unavailable in this environment (ComfyUI would exit at startup); not adding it"
    $attn = "off"
}
if ($useFp16) { $flags.Add("--fast fp16_accumulation") }
if ($attn -eq "ck") { $flags.Add("--use-ck-attention") }
if ($attn -eq "sage") { $flags.Add("--use-sage-attention") }
if ($VramHeadroomGB -gt 0) { $flags.Add(("--vram-headroom {0}" -f $VramHeadroomGB.ToString([Globalization.CultureInfo]::InvariantCulture))) }
$flagStr = ($flags -join " ")
if ($flagStr) { Write-Ok "selected flags: $flagStr" } else { Write-Ok "selected flags: (none beyond ComfyUI defaults)" }

# --------------------------------------------------------------------------------------------- #
# 6. Launchers
# --------------------------------------------------------------------------------------------- #
Write-Step "Launchers"
$hdr = "@echo off`r`nREM Generated by Optimize-ComfyUI.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Re-run the optimizer to regenerate.`r`n" +
"REM Deliberately not used: high-VRAM/GPU-only modes (disable dynamic VRAM), bare fast mode (turns off`r`n" +
"REM cudaMallocAsync), fp8 matrix mult (no FP8 tensor cores on a 3090), TorchCompileModel (drops dynamic VRAM).`r`n" +
"cd /d `"%~dp0`"`r`nset PYTHONUTF8=1`r`n"
$main = ".\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build --port $Port"
$noInt8 = (@($flags | Where-Object { $_ -notmatch "attention" })) -join " "
$launchers = [ordered]@{
    "run_optimized.bat"             = $hdr + "$main $flagStr %*`r`npause`r`n"
    "run_optimized_no_int8attn.bat" = $hdr + "REM Fallback if run_optimized.bat gives black/noisy/washed-out frames. If this one still does,`r`nREM use the stock run_nvidia_gpu.bat (then fp16 accumulation is the cause).`r`n$main $noInt8 %*`r`npause`r`n"
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
    "run_probe.bat"                 = $hdr + ".\python_embeded\python.exe -s optimizer\bench\kernel_probe.py --comfy-port $Port %*`r`npause`r`n"
    "run_bench.bat"                 = $hdr + @"
REM Usage: start ComfyUI with the launcher you want to measure, then in a second window:
REM   run_bench.bat LABEL [--workflow optimizer\workflows\X.json] [--set NODE.input=value ...]
REM e.g. run_bench.bat baseline   (while run_nvidia_gpu.bat is running)
REM      run_bench.bat optimized  (while run_optimized.bat is running)
.\python_embeded\python.exe -s optimizer\bench\comfy_bench.py quick --host 127.0.0.1:$Port %*
pause
"@
}
$autoMode = ($Fp16Accumulation -eq "auto") -or ($FastAttention -eq "auto")
if ($ReportOnly) { Write-Info "report-only: would write $(@($launchers.Keys) -join ', ')" }
else {
    foreach ($k in @($launchers.Keys)) {
        $path = Join-Path $Root $k
        $content = ($launchers[$k] -replace "`r?`n", "`r`n")
        $flagged = $k -in @("run_optimized.bat", "run_optimized_no_int8attn.bat", "run_remote_tailscale.bat")
        $exists = Test-Path -LiteralPath $path
        if ($flagged -and $autoMode -and -not $probeOk -and $exists) {
            Write-Warn2 "GPU probe did not complete; keeping the existing $k instead of regenerating it without measured flags"
            continue
        }
        if ($exists) {
            $old = [string](Get-Content -Raw -LiteralPath $path)
            if (($old -replace "REM Generated by [^\r\n]*", "") -eq ($content -replace "REM Generated by [^\r\n]*", "")) { Write-Ok "$k unchanged"; continue }
            $bk = Join-Path (Join-Path $OptDir "launcher-backups") "$k.$($script:Stamp)"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bk) | Out-Null
            Copy-Item -LiteralPath $path -Destination $bk -Force
        }
        Write-TextFile -Path $path -Content $content -Ascii
        if ($exists) { Add-Action "updated $k (previous copy in optimizer\launcher-backups)" } else { Add-Action "wrote $k" }
    }
}

# --------------------------------------------------------------------------------------------- #
# 7. Windows / driver
# --------------------------------------------------------------------------------------------- #
Write-Step "Windows / driver"
if ($IsWin) {
    try {
        $hags = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -ErrorAction Stop).HwSchMode
        Write-Info "Hardware-accelerated GPU scheduling: $(if ($hags -eq 2) { 'ON' } else { 'OFF' }) (no known effect on CUDA throughput; leave as is)"
    }
    catch { Write-Info "HAGS setting not readable (default)" }
    Add-Finding ("Manual step: NVIDIA Control Panel > Manage 3D settings > Program Settings > add '$Py' > " +
        "'CUDA - Sysmem Fallback Policy' = 'Prefer No Sysmem Fallback'. Otherwise the driver can silently spill VRAM " +
        "into shared system RAM and a render runs several times slower instead of ComfyUI offloading properly.")
    $isAdmin = Test-IsAdmin
    if ($ApplyWindowsTweaks -and -not $ReportOnly) {
        if (-not $isAdmin) { Write-Warn2 "-ApplyWindowsTweaks needs an elevated PowerShell; skipped" }
        else {
            $hp = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
            $active = (Invoke-Native -Exe "powercfg" -Arguments @("/getactivescheme")).Output
            if ($active -match $hp) { Write-Ok "High performance power plan already active" }
            else {
                $prev = ""
                if ($active -match "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})") { $prev = $Matches[1] }
                $r = Invoke-Native -Exe "powercfg" -Arguments @("/setactive", $hp)
                if ($r.ExitCode -eq 0) { Add-Action "power plan -> High performance (undo: powercfg /setactive $prev)" }
                else { Write-Warn2 "could not activate the High performance plan (it may be hidden on this edition): $($r.Output)" }
            }
            try {
                # safetensors-only folders from Comfy-Org; loras/checkpoints can hold pickle formats and stay scanned
                $ex = @((Get-MpPreference).ExclusionPath)
                foreach ($sub in @("diffusion_models", "text_encoders", "vae")) {
                    $dirPath = Join-Path $Models $sub
                    if (-not (Test-Path -LiteralPath $dirPath)) { continue }
                    if ($ex -contains $dirPath) { Write-Ok "Defender exclusion present: $dirPath"; continue }
                    Add-MpPreference -ExclusionPath $dirPath
                    Add-Action "Defender real-time scan exclusion: $dirPath (undo: Remove-MpPreference -ExclusionPath '$dirPath')"
                }
            }
            catch { Write-Warn2 "could not set Defender exclusions: $($_.Exception.Message)" }
        }
    }
    elseif (-not $ApplyWindowsTweaks) { Write-Info "system tweaks skipped (pass -ApplyWindowsTweaks from an elevated PowerShell to apply)" }
    if ($PowerLimitW -gt 0 -and $nvsmi -and -not $ReportOnly) {
        if (-not $isAdmin) { Write-Warn2 "-PowerLimitW needs an elevated PowerShell; skipped" }
        else {
            $r = Invoke-Native -Exe $nvsmi.Source -Arguments @("-i", "0", "-pl", "$PowerLimitW")
            if ($r.ExitCode -eq 0) { Add-Action "GPU power limit -> $PowerLimitW W until reboot (was $(if ($gpu) { $gpu.PowerLimit } else { '?' }) W)" }
            else { Write-Warn2 "nvidia-smi -pl failed: $($r.Output)" }
        }
    }
}

# --------------------------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------------------------- #
Write-Step "Summary"
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# ComfyUI optimizer report $($script:Stamp)$(if ($ReportOnly) { ' (report only)' })")
$lines.Add("")
$lines.Add("Install: $Root")
if ($gpu) { $lines.Add("GPU: $($gpu.Name), driver $($gpu.Driver), $($gpu.VramMiB) MiB") }
if ($pyInfo) { $lines.Add("torch $(Get-Prop $pyInfo 'torch') (CUDA $(Get-Prop $pyInfo 'cuda')), Python $(Get-Prop $pyInfo 'python'), ComfyUI $(Get-Prop $pyInfo 'comfyui')") }
$lines.Add("RAM: $ramGB GB")
$lines.Add("Launcher flags: $(if ($flagStr) { $flagStr } else { '(defaults)' })")
$lines.Add("")
$lines.Add("## Actions")
foreach ($a in $script:Actions) { $lines.Add("- $a") }
if ($script:Actions.Count -eq 0) { $lines.Add("- (none; already optimized or report-only)") }
$lines.Add("")
$lines.Add("## Findings")
foreach ($f in $script:Findings) { $lines.Add("- $f") }
$lines.Add("")
$lines.Add("## Next")
$lines.Add("1. In the Wan 2.2 14B template, set 'Enable 4steps LoRA?' (I2V) / 'Enable Lightning LoRA' (T2V) to true (off by default: 20 steps).")
$lines.Add("2. Measure everything in one go: powershell -ExecutionPolicy Bypass -File .\Run-FullTest.ps1 -InstallDir `"$Root`" (ComfyUI closed, ~20-40 min).")
$lines.Add("3. Paste the report it copies to the clipboard back into the chat, and watch the videos in ComfyUI\output\bench for artifacts.")
$report = $lines -join "`r`n"
$rp = Join-Path $OptDir "report-$($script:Stamp).md"
Write-TextFile -Path $rp -Content $report
Write-Ok "report: $rp"
Write-Host ""
Write-Host $report
