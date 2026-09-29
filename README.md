# ComfyUI Optimization Kit for an RTX 3090 (Wan 2.2 14B)

This kit speeds up ComfyUI Windows Portable on an RTX 3090 (24 GB, Ampere sm_86) running Wan 2.2 14B video. It is built against ComfyUI 0.37.0 master as of 2026-09-28. The optimizer updates to the stable channel, and stable **v0.37.4** has identical CLI flags, the same cu130 gating, and the same comfy-kitchen INT8 attention (0.2.35 ships the same sm_75/80/89/120 kernels as 0.2.36).

It contains one idempotent PowerShell script, a benchmark harness, and an on-GPU probe. The probe measures each speed flag on **your** card before the flag is turned on.

```
powershell -ExecutionPolicy Bypass -File .\Optimize-ComfyUI.ps1 -InstallDir "C:\AI\ComfyUI_windows_portable"
```

Close ComfyUI first. The script refuses to change anything while ComfyUI is running, because Windows locks the torch DLLs. `-ReportOnly` audits without changing anything and is safe to run while ComfyUI is up.

---

## What moves the needle, ranked

Numbers marked **measured** come from ComfyUI's official template notes, on an RTX 4090D at 640x640, 81 frames. Numbers marked **est.** are my estimates for a 3090, derived from tensor-core throughput. Confirm them with `run_bench.bat` (below).

| # | Lever | What it does | Expected gain on 3090 | Risk |
|---|---|---|---|---|
| 1 | **lightx2v 4-step LoRAs** | Cuts Wan 2.2 from 20 steps / CFG 3.5 to 4 steps / CFG 1. **The official template ships with this OFF.** | **~7x** warm (measured on 4090D: 513 s -> 71 s) | Slightly less motion variety / prompt adherence than 20 steps. The 20-step path remains available as reference mode. |
| 2 | **torch cu130 build** | ComfyUI disables comfy-kitchen's CUDA kernels (RoPE, quantization, INT8 attention) on torch builds below CUDA 13. ComfyUI's README calls cu130 "required on Nvidia 20 series and above". | Unlocks #4; est. 3-10% on its own | Needs NVIDIA driver >= 580. The script verifies the result and rolls back automatically on failure. |
| 3 | **`--fast fp16_accumulation`** | On a 3090, Wan's fp8_scaled weights are dequantized and run in **fp16** (the card has no FP8 tensor cores). GeForce Ampere does fp16 matmul with fp16 accumulate at **2x** the rate of fp32 accumulate (142 vs 71 dense TFLOPS). | est. **1.2-1.4x** on sampling (linear layers are ~45-50% of DiT FLOPs at 33.6k tokens) | Small numerical drift. ComfyUI ships an official launcher with this flag. The probe checks cosine similarity. |
| 4 | **`--use-ck-attention`** | comfy-kitchen's INT8 Sage-style attention, with a Hadamard rotation that reduces quantization outliers. It replaces the separate SageAttention wheel, as the SageAttention Windows maintainer now recommends. | est. **1.3-1.5x** on sampling (attention is the other ~50% of FLOPs; INT8 is 284 TOPS on a 3090) | Can produce black, noisy, or washed-out frames on some prompts. Fallback: `run_optimized_no_int8attn.bat`. |
| 5 | **Keep ComfyUI running between renders** | The first run loads about 37 GB of weights; later runs reuse them. | measured 97-108 s -> 71 s (4-step, 4090D) | None |
| 6 | **Resolution / length** | Cost scales with tokens = (W/16)(H/16)((F-1)/4+1). Attention scales with tokens squared. | 480x480 drafts cost ~0.45x of 640x640. 1280x720 costs ~3.6x. | Quality. Draft small, then render finals at 640x640 or 832x480. |
| 7 | **64 GB RAM + NVMe for models** | The two 14.3 GB experts plus the 6.7 GB text encoder cannot all stay in 24 GB of VRAM. Expert swaps come from RAM (under 1 s) or from disk (NVMe 2-5 s, SATA ~30 s, HDD minutes). | 0 to "minutes per clip", depending on your current hardware | The script reports your RAM, pagefile, and disk bus. |

Stacked est. for a warm 640x640x81 I2V clip on a 3090:
- 20-step template default: **~12-20 min**
- 4-step LoRA: **~2-3 min**
- 4-step + fp16-acc + CK attention: **~1.2-2 min**

The uncertainty is about ±35% until you run the benchmark.

### What the kit deliberately does not do (and why)

These are verified in ComfyUI source at `56c5005`:

| Common advice | Why it is wrong now |
|---|---|
| `--highvram` / `--gpu-only` for 24 GB cards | Either flag **disables dynamic VRAM** (comfy-aimdo), ComfyUI's new on-demand weight manager (`comfy/cli_args.py:318`). |
| bare `--fast` | It enables `autotune`, which **turns off cudaMallocAsync** (`cuda_malloc.py:93`). Use `--fast fp16_accumulation` only. |
| `--fast fp8_matrix_mult` | A no-op on sm_86. FP8 compute requires sm_89 or newer (`model_management.py:2011`). |
| TorchCompileModel node | `model.clone(disable_dynamic=True)` **drops dynamic VRAM** for that model. It also needs triton. |
| TeaCache / MagCache | Not in core ComfyUI. Core has `EasyCache`, but at 4 steps there are no steps to skip. It is only worth trying in 20-step reference mode (reuse_threshold 0.2, applied to both experts). |
| WanBlockSwap | Turned into a no-op by ComfyUI (`nodes_nop.py`): "placebo at best". |
| Comfy model compiler / CUDA graphs | Already on by default, but Wan never calls into it. Only Qwen-Image 2.1, LTX-AV, MiniMax, and autoregressive text encoders use it. |
| Installing the SageAttention wheel + triton-windows | comfy-kitchen bundles an equivalent INT8 kernel with sm_80 cubins, which run on sm_86. There is no torch/wheel version matrix to keep in sync. |

> **Correction to earlier guidance:** the earlier advice order was "TeaCache first, SageAttention second". Wan 2.2 changed that. The 4-step distill LoRA outranks both by roughly 5x, and TeaCache doesn't exist in core. SageAttention is now reached through `--use-ck-attention` rather than a separate wheel.

---

## First run

1. `git clone` this repo anywhere, or download it as a zip.
2. Close ComfyUI.
3. From a normal PowerShell, run:
   ```
   powershell -ExecutionPolicy Bypass -File .\Optimize-ComfyUI.ps1 -InstallDir "<your ComfyUI_windows_portable>"
   ```
   If `-InstallDir` is wrong, the script searches drive roots and the repo's parent folders for the portable install.
4. Optional, from an **elevated** PowerShell:
   ```
   .\Optimize-ComfyUI.ps1 -ApplyWindowsTweaks -PowerLimitW 300
   ```
   This sets the High performance power plan, adds a Defender exclusion for `ComfyUI\models`, and applies a 300 W board limit (resets on reboot). The power limit trades under 5% speed for much cooler GDDR6X on long batches.
5. One manual setting that no script can change: open **NVIDIA Control Panel > Manage 3D settings > Program Settings**, add `python_embeded\python.exe`, and set **CUDA - Sysmem Fallback Policy = Prefer No Sysmem Fallback**.
   - With fallback allowed, the driver silently spills VRAM into shared system RAM, and a render crawls 5-10x slower instead of letting ComfyUI offload properly.
   - This is my judgment call; ComfyUI's docs don't cover it. If you see no difference in `run_bench.bat`, either setting is fine.
6. In the UI, go to **Workflow > Browse Templates > Video > Wan 2.2 14B Image to Video** (or Text to Video). Set **"Enable 4steps LoRA?"** (I2V) or **"Enable Lightning LoRA"** (T2V) to **true**.

### Configuration (top of the script, or as parameters)

| Parameter | Default | Meaning |
|---|---|---|
| `-InstallDir` | `C:\AI\ComfyUI_windows_portable` | Portable root (contains `python_embeded\` and `ComfyUI\`). |
| `-UpdateComfyUI` | `$true` | Stable-channel update plus the pinned `comfy-kitchen` / `comfy-aimdo`. |
| `-UpgradeTorch` | `auto` | Moves to cu130 only if torch is older **and** the driver is >= 580. The result is verified; a CPU-only or broken result triggers automatic rollback. |
| `-DownloadT2V` / `-DownloadI2V` | `$true` | Downloads the lightx2v 4-step LoRAs (resume-safe; a mismatched file is kept as `.bak`, never overwritten). |
| `-Fp16Accumulation` | `auto` | `auto` = enable if the probe measures at least 1.15x at cosine above 0.999. |
| `-FastAttention` | `auto` | `auto`, `ck`, `sage`, or `off`. `auto` = CK INT8 if it measures at least 1.2x at cosine above 0.995. |
| `-ReserveVramGB` | `0` | Extra VRAM to keep free (default 0.7 GB on Windows). Set 1.5-2 if you game or stream on the same GPU. |
| `-ApplyWindowsTweaks`, `-PowerLimitW` | off | Admin-only system tweaks, as described in step 4 above. |
| `-ReportOnly` | off | Audit only. |

### What gets written into the portable root

| File | Purpose |
|---|---|
| `run_optimized.bat` | ComfyUI with the measured flags. Extra args pass through (`%*`). |
| `run_optimized_no_int8attn.bat` | Same, minus INT8 attention. Use it if frames come out black, noisy, or washed out. |
| `run_remote_tailscale.bat` | Binds to `127.0.0.1` + your Tailscale IP only, not `0.0.0.0`, so the LAN and the internet can't reach port 8188. Fails closed if Tailscale is down. |
| `run_probe.bat` | Re-runs the GPU probe (about 30 s). |
| `run_bench.bat LABEL [workflow]` | Benchmarks a running server and prints the comparison table. |
| `optimizer\report-*.md`, `probe-*.json`, `pip-freeze-before-*.txt`, `rollback-torch-*.bat` | Audit trail and rollback. |

---

## Verify (measure, don't trust)

```
run_probe.bat                     :: kernel-level: fp16-acc GEMM + attention speed/error on your 3090
run_nvidia_gpu.bat                :: stock launcher (baseline). In a 2nd window:
run_bench.bat baseline            :: 1 warmup + 3 timed runs, fixed seeds, peak VRAM/power/temp
:: close ComfyUI, then
run_optimized.bat
run_bench.bat optimized           :: prints the table with speedup vs baseline
```

Benchmark workflows live in `workflows/` (API format, validated against ComfyUI 0.37.0's `/prompt` endpoint):

| File | Settings |
|---|---|
| `wan22_i2v_4step_api.json` / `wan22_t2v_4step_api.json` | Identical to the official templates: 640x640x81, 4 steps (2+2 split), CFG 1, shift 5, euler/simple, lightx2v LoRAs at 1.0 |
| `wan22_*_20step_reference_api.json` | Template "LoRA off" mode: 20 steps (10+10), CFG 3.5, shift 5 |
| `smoke_test_api.json` | No models. Checks the API plumbing only. |

Handy overrides:
- `run_bench.bat test832 optimizer\workflows\wan22_i2v_4step_api.json --set WanImageToVideo.width=832 --set WanImageToVideo.height=480`
- `--cold` unloads models before each run, which measures load time and therefore RAM and disk speed.

Always **watch the output video** from the optimized run. A speedup that produces artifacts is not a speedup.

---

## Cost model for choosing resolution and length

tokens = (W/16) x (H/16) x ((frames-1)/4 + 1). Linear layers scale with tokens; attention scales with tokens squared.

| Setting | Tokens | Est. time vs 640x640x81 |
|---|---|---|
| 480x480x81 | 18,900 | ~0.45x (draft) |
| 640x640x81 / 832x480x81 | 33,600 / 32,760 | 1.0x |
| 640x640x121 | 49,600 | ~1.8x (Wan 2.2 is trained at 81 frames / 16 fps; longer clips drift) |
| 1280x720x81 | 75,600 | ~3.6x, and VAE decode is more likely to need tiling |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| ComfyUI exits at start: "Comfy Kitchen attention is unavailable" | torch is older than cu130, or comfy-kitchen is older than the pinned version | Re-run the optimizer, or use `run_optimized_no_int8attn.bat` |
| Log shows "You need pytorch with cu130 or higher" | Old torch build | Update the driver to >= 580, then re-run the optimizer (`-UpgradeTorch auto`) |
| Black, noisy, or washed-out frames | INT8 attention overflow on that prompt/seed | `run_optimized_no_int8attn.bat` |
| Render suddenly 5-10x slower; Task Manager shows "Shared GPU memory" climbing | Driver sysmem fallback (VRAM spilling into system RAM) | Set Sysmem Fallback Policy (First run, step 5), close other GPU apps, or use `-ReserveVramGB 1.5` |
| OOM at VAE decode | Text encoder + VAE + latents at high resolution | ComfyUI already retries with tiling automatically. If it still fails, swap in `VAEDecodeTiled` (tile 256, overlap 64, temporal 32, temporal_overlap 8). |
| "The paging file is too small" | Fixed pagefile; Windows does not overcommit | Set the pagefile to system-managed, or >= 32 GB on NVMe |
| First render slow, later ones fast | Model load | Normal. Keep ComfyUI open and queue jobs. |
| Custom node broke after the torch upgrade | Compiled extension built for the old torch | Update it via Manager, or run `optimizer\rollback-torch-*.bat` |
| Flags seem to do nothing in a Kijai WanVideoWrapper workflow | The wrapper has its own attention (`attention_mode`) and block-swap stack, which bypasses ComfyUI's attention flags and dynamic VRAM | Use the native templates. On 24 GB with dynamic VRAM they are now the faster path (judgment, not measured). |
| Remote collaborator can't connect | Tailscale down, or they are using a LAN IP | `tailscale status` on both machines. Use `http://<tailscale-ip>:8188` from `run_remote_tailscale.bat`'s banner. |

## Rollback

- **Torch:** `optimizer\rollback-torch-<timestamp>.bat`.
- **Everything else:** the script is additive. Delete the generated `run_*.bat` files. `optimizer\pip-freeze-before-<timestamp>.txt` records every prior package version. Reinstall any non-torch package from it with `python_embeded\python.exe -m pip install <name>==<version>`; torch builds carry a `+cuXXX` tag, so use the torch rollback script for those.
- **LoRAs:** they are plain files in `ComfyUI\models\loras`.

## Repo layout

```
Optimize-ComfyUI.ps1     idempotent optimizer (PS 5.1 compatible; PSScriptAnalyzer-clean for 5.1 syntax)
bench/kernel_probe.py    on-GPU flag probe (stdlib + torch; run with python_embeded)
bench/comfy_bench.py     API benchmark harness (stdlib only)
workflows/*.json         API-format benchmark workflows (Wan 2.2 14B T2V/I2V, 4-step and 20-step)
```
