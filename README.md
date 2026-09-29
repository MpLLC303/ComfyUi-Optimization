# ComfyUI Optimization Kit for an RTX 3090 (Wan 2.2 14B)

This kit speeds up ComfyUI Windows Portable on an RTX 3090 (24 GB, Ampere sm_86) running Wan 2.2 14B video. It contains one idempotent PowerShell optimizer, an on-GPU probe, a benchmark harness, and API workflows (baseline, prompt-cache, and experimental A/B variants).

Every flag and node setting was checked against ComfyUI source: master 0.37.0 (`56c5005`, 2026-09-28) and stable **v0.37.4**, which have identical CLI flags and the same comfy-kitchen INT8 kernels. Every workflow passes ComfyUI's own `/prompt` validation.

```
powershell -ExecutionPolicy Bypass -File .\Optimize-ComfyUI.ps1 -InstallDir "C:\AI\ComfyUI_windows_portable"
```

Close ComfyUI first. The script refuses to change anything while ComfyUI is running, because Windows locks the torch DLLs. `-ReportOnly` audits without changing anything and is safe to run while ComfyUI is up.

---

## Tier 1: applied by the optimizer (ranked)

Numbers marked **measured** come from ComfyUI's official template notes (RTX 4090D, 640x640, 81 frames). Numbers marked **est.** are my estimates for a 3090, derived from tensor-core throughput and FLOP counts. `run_bench.bat` gives you the real numbers.

| # | Lever | Why it works on a 3090 | Expected gain | Risk |
|---|---|---|---|---|
| 1 | **lightx2v 4-step LoRAs** | Wan 2.2 goes from 20 steps / CFG 3.5 to 4 steps / CFG 1. **The official template ships with this OFF.** | **~7x** warm (measured 4090D: 513 s -> 71 s) | Slightly less motion variety and prompt adherence than 20 steps |
| 2 | **torch cu130** | ComfyUI turns off comfy-kitchen's CUDA backend below CUDA 13. The extension also links `cublasLt64_13.dll`, so INT8 attention cannot load on cu12x. ComfyUI's README calls cu130 "required on Nvidia 20 series and above". | Prerequisite for #4; est. 3-10% on its own | Needs driver >= 580. The script verifies the result and restores the exact previous versions if it fails. |
| 3 | **`--fast fp16_accumulation`** | Wan's fp8_scaled weights are dequantized per layer and run as **fp16** GEMMs (the 3090 has no FP8 tensor cores). GeForce Ampere does fp16 with fp16 accumulate at **2x** the fp32-accumulate rate (142 vs 71 dense TFLOPS). | est. **1.2-1.4x** on sampling (linears ≈ 46% of FLOPs at 33.6k tokens) | Wan has no fp16 overflow clamp. If you see NaN or black frames, this flag is the first suspect. |
| 4 | **`--use-ck-attention`** | comfy-kitchen INT8 attention (sm_80 cubins run on sm_86): Hadamard-rotated INT8 Q/K, and **also INT8 V and P**. That is more aggressive than SageAttention 2's FP16 PV. It replaces the SageAttention wheel, as that wheel's Windows maintainer now recommends. | est. **1.3-1.5x** on sampling (attention ≈ 54% of FLOPs) | Black, noisy, or washed-out frames on some prompts. The probe gates it on a random case **and** a hard case (peaky softmax, outlier V tokens). Fallbacks below. |
| 5 | **Prompt-cache I2V graph** (`wan22_i2v_4step_promptcache_api.json`) | Stock `WanImageToVideo` takes the prompt as input, so **every prompt edit re-runs the 81-frame VAE encode**. This graph takes the prompt out of the encode's ancestry. | est. **4-15 s saved per prompt edit**; output bitwise identical (verified on master and v0.37.4) | Prompts must stay ≤ 511 UMT5 tokens. Leave the splice node's strength at **0.00**. |
| 6 | **Keep ComfyUI running and iterate within one workflow** | Loader, text-encode and encode results are cached, **but only for the immediately preceding prompt**. The default RAM-pressure cache evicts everything the current prompt doesn't use, so switching I2V↔T2V reloads the experts. | measured 97-108 s -> 71 s (2nd run, 4090D) | None |
| 7 | **64 GB RAM + NVMe** | Two 14.3 GB experts plus the 6.7 GB text encoder can't all fit in 24 GB. With `fast_disk=True`, each generation re-streams roughly 7-13 GB per expert switch from the Windows file cache or the disk. | 0 s to "minutes per clip", depending on current hardware | The script reports RAM, pagefile and disk bus |

Stacked est. for a warm 640x640x81 I2V clip on a 3090:
- 20-step template default: **~12-20 min**
- 4-step: **~2-3 min**
- 4-step + fp16-acc + CK attention: **~1.2-2 min**

The uncertainty is about ±35% until you benchmark. At 4 steps, the Wan VAE decode (est. 10-25 s) becomes 10-20% of the total.

## Tier 2: A/B-test these (workflows included, not enabled by default)

Each lever has a ready workflow in `optimizer\workflows\experimental\`. Every one was validated against ComfyUI's `/prompt` and uses the same node ids, prompts and seeds as the baseline. Run the baseline and the variant on the same warm server and **watch both videos**:

```
run_bench.bat base --workflow optimizer\workflows\wan22_t2v_4step_api.json
run_bench.bat cascade --workflow optimizer\workflows\experimental\wan22_t2v_4step_cascade480_api.json
```

| Lever | Workflow suffix | Est. gain (3090) | What can go wrong |
|---|---|---|---|
| **T1 Resolution cascade**: high-noise expert at 480x480, x0 handed over, bilinear upscale, low-noise expert re-noised at 640. The lightx2v distillation was trained on exactly this "x0 + fresh noise" transition. | `_4step_cascade480` | **-15 to -20% end-to-end** (the two high steps cost ~0.45x) | Softer detail, weaker motion or I2V identity. Seeds don't match native 640. |
| **T2 Tiny Wan VAE decode** (`lighttaew2_1`) | `_4step_taedecode` | **-8 to -22 s per clip** (decode ~1-3 s instead of ~10-25 s) | Softer texture, possible flicker or colour shift. Best as a draft decoder; re-decode keepers with the full VAE (the latent is cached, so it costs only the decode). |
| **T3 3-step lightx2v** (2 high + 1 low) | `_4step_3step` | **-18 to -22% end-to-end** | Moderate to high quality risk (the LoRA was distilled for 4 steps) |
| **T4 Model Sparse Attention** (core node, `sol-attn`, tau 1.3, step 0 dense) | `_4step_sparse` | 1.1-1.2x end-to-end | Training-free sparsity on a 4-step distilled model has no quality evidence. Check the log for `BlockSparseAttention: sparse (1, 33600, 40, 128)`. |
| **T5 INT8 W8A8 weights** (`int8_convrot` checkpoints, run natively on sm_86) | none: needs converted models | 1.05-1.2x end-to-end, **only if** `run_probe.bat` reports "int8_convrot WORTH an A/B test" (≥ 1.3x on both FFN shapes) | There is no official Wan 2.2 int8 file. Convert with `python_embeded\python.exe -m pip install convert_to_quant==1.3.4`, then `python_embeded\python.exe -m convert_to_quant.convert_to_quant -i <fp16 expert> -o <out> --wan --comfy_quant --save-quant-metadata --int8 --scaling-mode row --convrot --convrot-group-size 256 --simple --low-memory --output-dtype float16` (it also needs `prodigy-plus-schedule-free`). The kernel heuristics were tuned on Ada, so GA102 may underperform. |
| **T6 Per-expert attention backend** (core `ModelAttentionBackend`) | `_4step_perexpert_attn` | 0% on clean prompts | This is a quality switch, not a speed one. If one prompt artifacts, set node 18 (high) or 19 (low) to `pytorch attention`, keeping INT8 on the other expert, without restarting ComfyUI. |
| **T7 20-step reference only**: CFG 1 on the low-noise half, or EasyCache | `_20step_lowcfg1`, `_20step_easycache` | ~1.25x / 1.1-1.5x on the 20-step path | Changes the "reference" output. EasyCache does **nothing** at 4 steps. |

Regenerate the variants after editing a baseline with `python workflows\make_variants.py`.

## Tier 3: don't (verified in source)

| Common advice | Why not |
|---|---|
| `--highvram` / `--gpu-only` | Either flag **disables dynamic VRAM** (comfy-aimdo), ComfyUI's on-demand weight manager (`cli_args.py:318`). |
| bare `--fast` | It enables `autotune`, which **turns off cudaMallocAsync** (`cuda_malloc.py:93`). Use `--fast fp16_accumulation`. |
| `--fast fp8_matrix_mult`, UNETLoader `fp8_e4m3fn(_fast)` | No FP8 compute on sm_86 (`model_management.py:2011`). Keep `weight_dtype = default`. |
| `ModelComputeDtype` bf16, `--bf16-unet` | Drops the linears to the 71 TFLOPS fp32-accumulate tier: est. **25-50% slower**. |
| fp16 Wan weights | 28.6 GB per expert, which doesn't fit. The fp8 dequant costs only ~0.2-0.5% of a forward pass. |
| W4A4 / W4A8 weights | About 24% output error per linear (W4A4) or no speed gain over INT8 (W4A8). |
| `TorchCompileModel` | `clone(disable_dynamic=True)` drops dynamic VRAM for that model. |
| **Core `NAGuidance` at cfg 1** | Turns off the cfg=1 shortcut (**~2x slower**), and Wan never applies the patch. |
| `*_cfg_pp` samplers, `heun`, `dpm_2`, `dpmpp_sde`, `dpmpp_2s_ancestral`, `seeds_2` | Two model calls per step: **~2x slower**. |
| EasyCache / LazyCache / OptimalSteps / APG / CFG-Zero at 4 steps | Nothing to skip in 2-step segments. APG even adds ~1.7% drift. |
| CLIPLoader `device=cpu` | Each changed prompt goes from ~1 s to ~4-20 s. |
| `--high-ram`, `--cache-*`, `--async-offload N`, `--reserve-vram`, `--lowvram`, `--disable-mmap` | No gain under dynamic VRAM on 24 GB; some are slower. |
| WanBlockSwap | ComfyUI turns it into a no-op (`nodes_nop.py`). |
| Pixel upscalers (render 480, then upscale) instead of T1 | The upscaler's cost roughly cancels the saving and adds its own artifacts. |

> **Correction to earlier guidance:** the earlier order was "TeaCache first, SageAttention second". For Wan 2.2 that order is wrong:
> - The 4-step distill LoRA outranks both by about 5x.
> - TeaCache isn't in core, and its core counterpart EasyCache can't skip anything at 4 steps.
> - SageAttention is now reached through `--use-ck-attention` rather than a separate wheel.

---

## First run

1. `git clone` this repo (or download the zip) anywhere, and close ComfyUI.
2. Run:
   ```
   powershell -ExecutionPolicy Bypass -File .\Optimize-ComfyUI.ps1 -InstallDir "<your ComfyUI_windows_portable>"
   ```
3. Optional, from an **elevated** PowerShell:
   ```
   .\Optimize-ComfyUI.ps1 -ApplyWindowsTweaks -PowerLimitW 300
   ```
   This applies:
   - the High performance power plan;
   - Defender exclusions for `models\diffusion_models`, `text_encoders` and `vae` only (safetensors-only folders; `loras` and `checkpoints` can hold pickle formats and stay scanned);
   - a 300 W board limit that resets on reboot. It trades under 5% speed for much cooler GDDR6X on long batches.
4. Manual setting (no script can change it): **NVIDIA Control Panel > Manage 3D settings > Program Settings**, add `python_embeded\python.exe`, then set **CUDA - Sysmem Fallback Policy = Prefer No Sysmem Fallback**.
   - aimdo already evicts ahead of every allocation. A spill needs *another* app to grab VRAM between its 2-second polls, for example a game or a 4K browser video on the same GPU.
   - With this setting, such contention becomes a clean eviction or OOM instead of a silent several-fold slowdown.
   - It also makes ComfyUI's OOM-triggered tiled-VAE fallback reliable.
   - It gains 0% on an uncontended run.
5. In the UI, go to **Workflow > Browse Templates > Video > Wan 2.2 14B Image to Video** (or Text to Video). Set **"Enable 4steps LoRA?"** (I2V) or **"Enable Lightning LoRA"** (T2V) to **true**.
6. For I2V prompt iteration, load `optimizer\workflows\wan22_i2v_4step_promptcache_api.json` (drag the file onto the canvas), or apply the same rewiring to the template:
   - Feed the **negative** CLIPTextEncode into both conditioning inputs of WanImageToVideo.
   - Add `ConditioningAverage` (to = WanImageToVideo positive out, from = your positive prompt, **strength 0.00**).
   - Feed the splice output to both samplers' `positive`, and WanImageToVideo's `negative` output to both samplers' `negative`.

### Verify in the ComfyUI console

After starting `run_optimized.bat`, look for these lines:
- `DynamicVRAM support detected and enabled` and `comfy-aimdo WDDM adapter match: NVIDIA GeForce RTX 3090`. If they're missing, ComfyUI silently fell back to the legacy memory manager.
- `Enabled fp16 accumulation.` and `Using Comfy Kitchen attention`.
- At model load:
  - `Using mixed precision operations`, with float8 listed as *emulated*;
  - `model weight dtype torch.float16, manual cast: torch.float16`;
  - `Model storage policy: fast_disk=True` (if models are on NVMe).
- Nothing mentioning `You need pytorch with cu130`.

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-InstallDir` | `C:\AI\ComfyUI_windows_portable` | Portable root. If you don't pass it and the default is wrong, the script searches local disks and refuses to guess between several installs. |
| `-UpdateChannel` | `auto` | `auto` keeps your channel (master branch -> latest, tag -> stable). Also `stable`, `latest`, `none`. The updater stashes local edits to ComfyUI's own files into a `backup_branch_*` first. |
| `-UpgradeTorch` | `auto` | cu130 only if torch is older **and** the driver is >= 580, the PyTorch index is reachable, and ≥ 10 GB is free. It uses `--index-url`, so it can never fall back to PyPI's CPU-only torch. It verifies CUDA works afterwards and otherwise restores the exact previous torch/torchvision/torchaudio/xformers. |
| `-SkipT2V` / `-SkipI2V` | off | Skip that pair of lightx2v LoRAs. Downloads are resume-safe; an existing file is only replaced after the new one is size-verified, and the old copy is kept as `.bak-<stamp>`. |
| `-Fp16Accumulation` | `auto` | `auto` = on if the probe measures ≥ 1.15x at cosine > 0.999. |
| `-FastAttention` | `auto` | `auto`/`ck`/`sage`/`off`. `auto` = CK if ≥ 1.2x, random-case cosine > 0.995 and relL2 < 0.05, and hard-case cosine > 0.99. |
| `-VramHeadroomGB` | `0` | `--vram-headroom`: VRAM that dynamic VRAM keeps free, counting other apps. Use 1.5-2 if you game or stream on the same GPU. |
| `-ApplyWindowsTweaks`, `-PowerLimitW` | off | Admin-only system tweaks (First run, step 3). Every applied change logs its undo command. |
| `-ReportOnly` | off | Audit only. Writes just `optimizer\report-*.md`. |

### Files written into the portable root

| File | Purpose |
|---|---|
| `run_optimized.bat` | ComfyUI with the measured flags. Extra args pass through. |
| `run_optimized_no_int8attn.bat` | The same minus INT8 attention, for artifacts. If this still artifacts, use the stock `run_nvidia_gpu.bat`; fp16 accumulation is then the cause. |
| `run_remote_tailscale.bat` | Binds `127.0.0.1` + your Tailscale IP only, never `0.0.0.0`. Fails closed if Tailscale is down. |
| `run_probe.bat` | GPU probe (~30 s, ~3 GB VRAM; refuses to run while ComfyUI is serving). |
| `run_bench.bat LABEL [--workflow F] [--set NODE.input=value]` | Benchmarks a running server and prints the comparison table. |
| `optimizer\` | Report, `probe-*.json`, `pip-freeze-before-*.txt`, `rollback-torch-*.bat`, `launcher-backups\`, `bench\`, `workflows\` (+ `experimental\`) |

---

## Measure, don't trust

**One command (recommended):** close ComfyUI, then run

```
powershell -ExecutionPolicy Bypass -File .\Run-FullTest.ps1 -InstallDir "<your ComfyUI_windows_portable>"
```

It runs the probe, then starts ComfyUI itself on port 8189: first with stock flags, then with `run_optimized.bat`'s flags plus every experimental variant, all on the same seeds. It stops each server afterwards and writes `optimizer\full-test-<stamp>.txt`, which is also copied to your clipboard; paste it back into the chat for analysis.
- It takes about 20-40 minutes and installs or changes nothing.
- Videos land in `ComfyUI\output\bench\`, named by configuration, so you can compare quality side by side.
- Options: `-Kind t2v`, `-Runs 3`, `-SkipExperimental`, `-SkipBaseline`.

Manual version:

```
run_probe.bat                     :: kernel level: fp16-acc GEMM, CK/Sage attention (random + hard case), INT8 weight GEMM
run_nvidia_gpu.bat                :: stock launcher. In a 2nd window:
run_bench.bat baseline            :: 1 warmup + 3 timed runs, fixed seeds, peak VRAM/power/temp -> optimizer\bench_results.csv
:: close ComfyUI, then
run_optimized.bat
run_bench.bat optimized           :: prints the table with speedup vs "baseline"
```

- `--set WanImageToVideo.width=832 --set WanImageToVideo.height=480` changes resolution (it survives cmd's `=` splitting).
- `--cold` unloads models before each run, which measures load time and therefore RAM and disk speed.
- The benchmark varies only seeds, so text encode and I2V encode stay cached. Real prompt-editing sessions are 4-15 s slower per edit unless you use the prompt-cache graph.

| Baseline workflow | Settings |
|---|---|
| `wan22_{i2v,t2v}_4step_api.json` | Same as the official templates: 640x640x81, 4 steps (2+2), CFG 1, shift 5, euler/simple, lightx2v LoRAs at 1.0 |
| `wan22_{i2v,t2v}_20step_reference_api.json` | Template "LoRA off" mode: 20 steps (10+10), CFG 3.5, shift 5 |
| `wan22_i2v_4step_promptcache_api.json` | The 4-step I2V graph with the encode decoupled from the prompt (Tier 1 #5) |
| `smoke_test_api.json` | No models; checks the API plumbing only |

## Cost model (resolution and length)

tokens = (W/16) x (H/16) x ((frames-1)/4 + 1). Linear layers scale with tokens; attention scales with tokens squared.

| Setting | Tokens | Est. time vs 640x640x81 |
|---|---|---|
| 480x480x81 | 18,900 | ~0.45x (draft) |
| 640x640x81 / 832x480x81 | 33,600 / 32,760 | 1.0x |
| 640x640x121 | 49,600 | ~1.8x (Wan 2.2 is trained at 81 frames / 16 fps; longer clips drift) |
| 1280x720x81 | 75,600 | ~3.6x |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| ComfyUI exits at start: "Comfy Kitchen attention is unavailable" | torch older than cu130, or the comfy-kitchen extension failed to load | Re-run the optimizer, or use `run_optimized_no_int8attn.bat` |
| Log shows "You need pytorch with cu130 or higher" | Old torch build | Update the driver to >= 580, then re-run the optimizer |
| Black, noisy, or washed-out frames | INT8 attention overflow, or fp16 overflow | Try `run_optimized_no_int8attn.bat`, then the stock `run_nvidia_gpu.bat`. For one-off prompts, use the `perexpert_attn` workflow with one expert on `pytorch attention`. |
| Render suddenly several times slower | Another app took VRAM and the driver spilled into system RAM | Set the Sysmem Fallback Policy (First run, step 4), close GPU apps, or use `-VramHeadroomGB 1.5`. Don't judge this from Task Manager's "Shared GPU memory": ComfyUI legitimately pins up to 40% of RAM as host buffers. Compare s/it instead. |
| OOM at VAE decode even after ComfyUI's automatic tiled retry | Very high resolution or length | Use `VAEDecodeTiled` with tile 256, overlap 64, **temporal_size 128**, temporal_overlap 8. Keep the temporal tile ≥ the clip's latent length: a smaller one saves no VRAM for Wan's causal decoder and adds seams. |
| "The paging file is too small" | Fixed pagefile; Windows does not overcommit, and pinned buffers are committed memory | Set the pagefile to system-managed or ≥ 32 GB on NVMe. Never disable it. |
| Switching I2V↔T2V is slow | The cache evicts the other workflow's experts | Expected. Batch your work per workflow. |
| Custom node broke after the torch upgrade | Compiled extension built for the old torch | Update it via Manager, or run `optimizer\rollback-torch-*.bat` |
| Flags do nothing in a Kijai WanVideoWrapper workflow | The wrapper has its own attention and block-swap stack | Use the native templates or the kit workflows |
| Remote collaborator can't connect | Tailscale down, or they are using a LAN IP | `tailscale status` on both machines; use the URL in `run_remote_tailscale.bat`'s banner |

## Rollback

- **Torch:** `optimizer\rollback-torch-<stamp>.bat` (exact versions, `--no-deps`, xformers included).
- **Launchers:** previous copies are in `optimizer\launcher-backups\`.
- **LoRAs:** replaced copies are kept as `.bak-<stamp>`.
- **Windows tweaks:** each one logs its undo command in the report.
- **Packages:** `optimizer\pip-freeze-before-<stamp>.txt` records every prior version.

## Repo layout

```
Run-FullTest.ps1            one-command probe + stock vs optimized vs experimental benchmark -> one pasteable report
Optimize-ComfyUI.ps1        idempotent optimizer (Windows PowerShell 5.1 + 7; PSScriptAnalyzer-clean for 5.1 syntax)
bench/kernel_probe.py       on-GPU probe (fp16-acc GEMM, INT8 attention random + hard case, INT8 weight GEMM)
bench/comfy_bench.py        API benchmark harness (stdlib only): run / quick / compare
bench/env_info.py           environment JSON for the optimizer (never raises)
bench/make_start_image.py   start frame for the I2V benchmark
workflows/*.json            baseline + prompt-cache API workflows
workflows/experimental/     Tier 2 A/B variants (generated by workflows/make_variants.py)
```
