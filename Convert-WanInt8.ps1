<#
.SYNOPSIS
    Convert-WanInt8.ps1 - make INT8 (W8A8 ConvRot) copies of your Wan 2.2 14B experts with the lightx2v
    4-step LoRA baked in, for the RTX 3090's INT8 tensor cores.

.DESCRIPTION
    Only worth it if bench\kernel_probe.py reports "int8_convrot Wan checkpoints WORTH an A/B test"
    (>= 1.3x on the FFN shapes). Your originals are never modified; new files are written next to them:
      models\diffusion_models\wan2.2_<kind>_<high|low>_noise_14B_int8convrot_lx2v.safetensors  (~15 GB each)
    Use them with workflows\experimental\wan22_<kind>_4step_int8_api.json (no LoRA nodes: already baked).
    Close ComfyUI first. About 5-15 minutes per expert; needs ~16 GB free disk per expert.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Convert-WanInt8.ps1 -InstallDir "C:\ComfyUI\ComfyUI_windows_portable"
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "C:\ComfyUI\ComfyUI_windows_portable",
    [ValidateSet("auto", "t2v", "i2v", "both")]
    [string]$Kind = "auto",
    # quantize without baking the LoRA (then use the normal LoRA nodes at runtime)
    [switch]$NoLoraBake
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$Kit = $PSScriptRoot

if (-not ((Test-Path -LiteralPath (Join-Path $InstallDir "python_embeded")) -and (Test-Path -LiteralPath (Join-Path (Join-Path $InstallDir "ComfyUI") "main.py")))) {
    throw "-InstallDir '$InstallDir' is not a ComfyUI portable root (needs python_embeded\ and ComfyUI\main.py)."
}
$Root = (Resolve-Path -LiteralPath $InstallDir).Path
$Py = Join-Path (Join-Path $Root "python_embeded") "python.exe"
if (-not (Test-Path -LiteralPath $Py)) { $Py = Join-Path (Join-Path $Root "python_embeded") "python" }
$ComfyDir = Join-Path $Root "ComfyUI"
$Dm = Join-Path (Join-Path $ComfyDir "models") "diffusion_models"
$Lo = Join-Path (Join-Path $ComfyDir "models") "loras"
$Conv = Join-Path (Join-Path $Kit "bench") "wan_int8_convert.py"

$pyDir = Join-Path $Root "python_embeded"
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($pyDir, [StringComparison]::OrdinalIgnoreCase) } catch { $false } })
if ($running.Count -gt 0) { throw "ComfyUI is running from this install (PID $($running.Id -join ', ')). Close it first." }

$lora = @{
    "t2v" = @{ "high" = "wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"; "low" = "wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors" }
    "i2v" = @{ "high" = "wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors"; "low" = "wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" }
}
$kinds = @()
foreach ($k in @("t2v", "i2v")) {
    $have = (Test-Path -LiteralPath (Join-Path $Dm "wan2.2_${k}_high_noise_14B_fp8_scaled.safetensors")) -and
    (Test-Path -LiteralPath (Join-Path $Dm "wan2.2_${k}_low_noise_14B_fp8_scaled.safetensors"))
    if (($Kind -eq "auto" -and $have) -or $Kind -eq $k -or $Kind -eq "both") {
        if (-not $have) { throw "Wan 2.2 $k fp8_scaled experts not found in $Dm" }
        $kinds += $k
    }
}
if (-not $kinds) { throw "No Wan 2.2 14B fp8_scaled experts found in $Dm" }

$drive = $null
try { $drive = Get-PSDrive -Name ((Split-Path -Qualifier $Dm).TrimEnd(":")) -ErrorAction Stop } catch { }

$done = 0
foreach ($k in $kinds) {
    foreach ($stage in @("high", "low")) {
        $src = Join-Path $Dm "wan2.2_${k}_${stage}_noise_14B_fp8_scaled.safetensors"
        $suffix = if ($NoLoraBake) { "int8convrot" } else { "int8convrot_lx2v" }
        $out = Join-Path $Dm "wan2.2_${k}_${stage}_noise_14B_${suffix}.safetensors"
        if (Test-Path -LiteralPath $out) { Write-Host "    [ok]   exists: $([IO.Path]::GetFileName($out))" -ForegroundColor Green; continue }
        if ($drive -and $drive.Free -lt 16GB) { throw "Less than 16 GB free on $($drive.Name): for $([IO.Path]::GetFileName($out))" }
        $cargs = @("-s", $Conv, "--comfy", $ComfyDir, "--src", $src, "--out", $out)
        if (-not $NoLoraBake) {
            $lp = Join-Path $Lo $lora[$k][$stage]
            if (-not (Test-Path -LiteralPath $lp)) { throw "LoRA not found: $lp (run Optimize-ComfyUI.ps1 first, or pass -NoLoraBake)" }
            $cargs += @("--lora", "${lp}:1.0")
        }
        Write-Host ""
        Write-Host "==> $k $stage-noise expert -> $([IO.Path]::GetFileName($out))" -ForegroundColor Cyan
        $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { & $Py @cargs 2>&1 | ForEach-Object { "$_" } | Out-Host; $rc = $LASTEXITCODE }
        finally { $ErrorActionPreference = $old }
        if ($rc -ne 0) {
            Remove-Item -LiteralPath "$out.part" -Force -ErrorAction SilentlyContinue
            throw "conversion failed (exit $rc) for $src"
        }
        $done++
    }
}
Write-Host ""
Write-Host "Done ($done converted). Test them with:" -ForegroundColor Green
Write-Host "  powershell -ExecutionPolicy Bypass -File .\Run-FullTest.ps1 -InstallDir `"$Root`" -SkipBaseline"
Write-Host "Run-FullTest picks up the int8 workflows automatically once these files exist."
