<#
.SYNOPSIS
    Run-FullTest.ps1 - one command that measures everything and produces ONE report to paste back.

.DESCRIPTION
    Run it after Optimize-ComfyUI.ps1, with ComfyUI closed. It:
      1. runs the GPU kernel probe (bench\kernel_probe.py)
      2. starts ComfyUI with STOCK flags on a private port, benchmarks the Wan 2.2 4-step workflow, stops it
      3. starts ComfyUI with the flags from run_optimized.bat, benchmarks the same workflow + seeds, then
         (unless -SkipExperimental) each experimental A/B variant on the same warm server, stops it
      4. writes optimizer\full-test-<stamp>.txt (probe, comparison table, relevant console lines, system
         info) and copies it to the clipboard.

    Nothing is installed or changed. Expect ~20-40 minutes. Output videos land in ComfyUI\output\bench\
    with the configuration name in the file name, so you can compare quality side by side.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Run-FullTest.ps1 -InstallDir "C:\AI\ComfyUI_windows_portable"
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Run-FullTest.ps1 -Kind t2v -Runs 3 -SkipExperimental
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "C:\AI\ComfyUI_windows_portable",
    # i2v | t2v | auto (auto = whichever Wan 2.2 14B experts are installed, i2v preferred)
    [ValidateSet("auto", "i2v", "t2v")]
    [string]$Kind = "auto",
    [int]$Runs = 2,
    [switch]$SkipExperimental,
    [switch]$SkipBaseline,
    [int]$Port = 8189,
    # seconds to wait for ComfyUI to come up
    [int]$StartTimeout = 300,
    # testing hooks: override the workflow file and add server args (e.g. --cpu)
    [string]$Workflow = "",
    [string]$ExtraServerArgs = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Kit = $PSScriptRoot

function Write-Step([string]$m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
    }
    finally { $ErrorActionPreference = $old }
}

# ---- locate install and kit
if (-not ((Test-Path -LiteralPath (Join-Path $InstallDir "python_embeded")) -and (Test-Path -LiteralPath (Join-Path (Join-Path $InstallDir "ComfyUI") "main.py")))) {
    throw "-InstallDir '$InstallDir' is not a ComfyUI portable root (needs python_embeded\ and ComfyUI\main.py)."
}
$Root = (Resolve-Path -LiteralPath $InstallDir).Path
$Py = Join-Path (Join-Path $Root "python_embeded") "python.exe"
if (-not (Test-Path -LiteralPath $Py)) { $Py = Join-Path (Join-Path $Root "python_embeded") "python" }
$ComfyDir = Join-Path $Root "ComfyUI"
$OptDir = Join-Path $Root "optimizer"
New-Item -ItemType Directory -Force -Path $OptDir | Out-Null
$BenchPy = Join-Path (Join-Path $Kit "bench") "comfy_bench.py"
$ProbePy = Join-Path (Join-Path $Kit "bench") "kernel_probe.py"
$WfDir = Join-Path $Kit "workflows"
$ExpDir = Join-Path $WfDir "experimental"
$Csv = Join-Path $OptDir "full-test-$Stamp.csv"
$Report = Join-Path $OptDir "full-test-$Stamp.txt"
$LogDir = Join-Path $OptDir "full-test-logs-$Stamp"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$pyDir = Join-Path $Root "python_embeded"
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($pyDir, [StringComparison]::OrdinalIgnoreCase) } catch { $false } })
if ($running.Count -gt 0) { throw "ComfyUI is running from this install (PID $($running.Id -join ', ')). Close it first; this test starts its own servers." }

# ---- choose workflow
$dm = Join-Path (Join-Path $ComfyDir "models") "diffusion_models"
function Test-Experts([string]$k) {
    (Test-Path -LiteralPath (Join-Path $dm "wan2.2_${k}_high_noise_14B_fp8_scaled.safetensors")) -and
    (Test-Path -LiteralPath (Join-Path $dm "wan2.2_${k}_low_noise_14B_fp8_scaled.safetensors"))
}
if (-not $Workflow) {
    if ($Kind -eq "auto") {
        if (Test-Experts "i2v") { $Kind = "i2v" } elseif (Test-Experts "t2v") { $Kind = "t2v" }
        else { throw "No Wan 2.2 14B fp8_scaled experts found in $dm (run install-comfyui-wan22.ps1 first)." }
    }
    $Workflow = Join-Path $WfDir "wan22_${Kind}_4step_api.json"
    if ($Kind -eq "i2v") {
        [void](Invoke-Native $Py @("-s", (Join-Path (Join-Path $Kit "bench") "make_start_image.py"), (Join-Path (Join-Path $ComfyDir "input") "bench_start.png")))
    }
}
$variants = @()
if (-not $SkipExperimental -and $Kind -ne "auto") {
    foreach ($v in @("cascade480", "3step", "sparse", "cascade480_sparse", "taedecode", "int8", "int8_cascade480_sparse")) {
        $f = Join-Path $ExpDir "wan22_${Kind}_4step_${v}_api.json"
        if (-not (Test-Path -LiteralPath $f)) { continue }
        if ($v -like "int8*") {
            $i8 = Join-Path $dm "wan2.2_${Kind}_high_noise_14B_int8convrot_lx2v.safetensors"
            if (-not (Test-Path -LiteralPath $i8)) {
                if ($v -eq "int8") { Write-Host "    [info] skipping int8 variants: run Convert-WanInt8.ps1 first to create the INT8 experts" }
                continue
            }
        }
        if ($v -eq "taedecode") {
            $va = Join-Path (Join-Path $ComfyDir "models") "vae_approx"
            if (-not (Get-ChildItem -LiteralPath $va -Filter "lighttaew2_1.*" -ErrorAction SilentlyContinue)) {
                Write-Host "    [info] skipping taedecode: models\vae_approx\lighttaew2_1.* not installed"
                continue
            }
        }
        $variants += , @($v, $f)
    }
    if ($Kind -eq "i2v") { $variants += , @("promptcache", (Join-Path $WfDir "wan22_i2v_4step_promptcache_api.json")) }
}

# ---- optimized flags from run_optimized.bat
$optFlags = @()
$ro = Join-Path $Root "run_optimized.bat"
if (Test-Path -LiteralPath $ro) {
    $line = @(Get-Content -LiteralPath $ro | Where-Object { $_ -match "ComfyUI\\main\.py" }) | Select-Object -First 1
    if ($line) {
        $after = ($line -split "main\.py", 2)[1]
        $toks = @($after -split "\s+" | Where-Object { $_ })
        for ($i = 0; $i -lt $toks.Count; $i++) {
            $t = $toks[$i]
            if ($t -eq "%*" -or $t -eq "--windows-standalone-build") { continue }
            if ($t -eq "--port") { $i++; continue }
            $optFlags += $t
        }
    }
}
if (-not $optFlags) { Write-Host "    [warn] run_optimized.bat not found or has no extra flags; the 'optimized' run will equal stock. Run Optimize-ComfyUI.ps1 first." -ForegroundColor Yellow }

function Start-Comfy([string]$Label, [string[]]$Flags) {
    $argList = @("-s", (Join-Path $ComfyDir "main.py"), "--port", "$Port", "--disable-auto-launch") + $Flags
    if ($ExtraServerArgs) { $argList += @($ExtraServerArgs -split "\s+" | Where-Object { $_ }) }
    $quoted = ($argList | ForEach-Object { if ($_ -match "\s") { '"' + $_ + '"' } else { $_ } }) -join " "
    $out = Join-Path $LogDir "$Label.out.log"
    $err = Join-Path $LogDir "$Label.err.log"
    Write-Host "    starting ComfyUI ($Label): $($Flags -join ' ')"
    $p = Start-Process -FilePath $Py -ArgumentList $quoted -WorkingDirectory $Root -PassThru -NoNewWindow `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $deadline = (Get-Date).AddSeconds($StartTimeout)
    while ((Get-Date) -lt $deadline) {
        if ($p.HasExited) { throw "ComfyUI ($Label) exited during startup (code $($p.ExitCode)). See $err" }
        try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/system_stats" -TimeoutSec 3 | Out-Null; return $p } catch { Start-Sleep -Seconds 2 }
    }
    Stop-Comfy $p
    throw "ComfyUI ($Label) did not answer within $StartTimeout s. See $err"
}

function Stop-Comfy($p) {
    if ($p -and -not $p.HasExited) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
        try { $p.WaitForExit(30000) | Out-Null } catch { }
    }
    Start-Sleep -Seconds 3   # let the driver release VRAM
}

function Invoke-Bench([string]$Label, [string]$Wf, [int]$Warmup, [int]$N) {
    Write-Host "    bench $Label ($([IO.Path]::GetFileName($Wf))): $Warmup warmup + $N timed"
    $args2 = @("-s", $BenchPy, "run", $Wf, "--host", "127.0.0.1:$Port", "--label", $Label, "--runs", "$N",
        "--warmup", "$Warmup", "--seed", "1234", "--csv", $Csv, "--keep-going",
        "--set", "SaveVideo.filename_prefix=bench/$Label")
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & $Py @args2 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath (Join-Path $LogDir "bench-$Label.txt") | Out-Host }
    finally { $ErrorActionPreference = $old }
}

# ---- 1. probe
Write-Step "1/3 GPU kernel probe"
$probe = Invoke-Native $Py @("-s", $ProbePy, "--comfy-port", "$Port")
$probe.Output | Out-Host
if (-not $optFlags) {
    # run_optimized.bat has no measured flags (e.g. the optimizer's probe was skipped): use what the
    # probe just measured, so the "optimized" run is not a second copy of stock
    $recLine = @(($probe.Output -split "`n") | Where-Object { $_ -like "RECOMMENDED FLAGS:*" }) | Select-Object -Last 1
    if ($recLine -and $recLine -notmatch "\(none") {
        $optFlags = @(($recLine -replace "^RECOMMENDED FLAGS:\s*", "").Trim() -split "\s+" | Where-Object { $_ })
        Write-Host "    [info] using the probe's recommended flags for the optimized run: $($optFlags -join ' ')" -ForegroundColor Yellow
        Write-Host "    [info] re-run Optimize-ComfyUI.ps1 (ComfyUI closed) to write them into run_optimized.bat" -ForegroundColor Yellow
    }
}

# ---- 2. baseline
$srv = $null
try {
    if (-not $SkipBaseline) {
        Write-Step "2/3 stock ComfyUI (baseline)"
        $srv = Start-Comfy "baseline" @()
        Invoke-Bench "baseline" $Workflow 1 $Runs
        Stop-Comfy $srv; $srv = $null
    }
    # ---- 3. optimized + variants
    Write-Step "3/3 optimized ComfyUI$(if ($variants.Count) { ' + experimental variants' })"
    $srv = Start-Comfy "optimized" $optFlags
    Invoke-Bench "optimized" $Workflow 1 $Runs
    foreach ($v in $variants) { Invoke-Bench "opt+$($v[0])" $v[1] 0 1 }
}
finally { Stop-Comfy $srv }

# ---- report
Write-Step "Report"
$cmp = Invoke-Native $Py @("-s", $BenchPy, "compare", $Csv, "--baseline", "baseline", "--any-workflow")
$cmpOpt = Invoke-Native $Py @("-s", $BenchPy, "compare", $Csv, "--baseline", "optimized", "--any-workflow")
$patterns = "DynamicVRAM|aimdo|fp16 accumulation|Comfy Kitchen|cu130|mixed precision|manual cast|storage policy|pinned memory|BlockSparseAttention|EasyCache|out of memory|OutOfMemory|Traceback|Error|WARNING|Prompt executed"
$logLines = New-Object System.Collections.Generic.List[string]
foreach ($f in @(Get-ChildItem -LiteralPath $LogDir -Filter "bench-*.txt" | Sort-Object Name)) {
    $bad = @(Select-String -LiteralPath $f.FullName -Pattern "FAILED|execution failed|warning|ERROR" | Select-Object -First 10)
    if ($bad.Count) { $logLines.Add("--- $($f.Name)"); $bad | ForEach-Object { $logLines.Add($_.Line.Trim()) } }
}
foreach ($f in @(Get-ChildItem -LiteralPath $LogDir -Filter "*.log" | Sort-Object Name)) {
    $logLines.Add("--- $($f.Name)")
    @(Select-String -LiteralPath $f.FullName -Pattern $patterns | Select-Object -First 60) | ForEach-Object { $logLines.Add($_.Line.Trim()) }
}
$sys = @()
$nv = @(Get-Command "nvidia-smi" -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
if ($nv) { $sys += (Invoke-Native $nv.Source @("--query-gpu=name,driver_version,memory.total,pcie.link.gen.max,pcie.link.width.max,power.limit", "--format=csv,noheader")).Output }
if ($env:OS -eq "Windows_NT") {
    try { $sys += "RAM GB: " + [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) } catch { }
    try { $sys += "CPU: " + (Get-CimInstance Win32_Processor | Select-Object -First 1).Name } catch { }
}
$body = @(
    "# ComfyUI full test $Stamp",
    "Workflow: $([IO.Path]::GetFileName($Workflow))  runs=$Runs  optimized flags: $($optFlags -join ' ')",
    ($sys -join "`n"),
    "",
    "## Speed vs stock (baseline)", $cmp.Output,
    "",
    "## Speed vs optimized (experimental variants)", $cmpOpt.Output,
    "",
    "## Kernel probe", $probe.Output,
    "",
    "## Console lines of interest", ($logLines -join "`n"),
    "",
    "Videos: ComfyUI\output\bench\ (file names start with the configuration label)"
) -join "`r`n"
[IO.File]::WriteAllText($Report, $body, (New-Object System.Text.UTF8Encoding($false)))
try { Set-Clipboard -Value $body; $clip = " (also copied to the clipboard: just paste it into the chat)" } catch { $clip = "" }
Write-Host ""
Write-Host $cmp.Output
Write-Host ""
Write-Host "Report: $Report$clip" -ForegroundColor Green
