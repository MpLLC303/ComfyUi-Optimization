#!/usr/bin/env python3
"""
kernel_probe.py - 30-second capability + micro-benchmark probe for ComfyUI speed flags.

Run it with the ComfyUI portable interpreter BEFORE enabling a flag, so each
flag is justified by a number measured on your GPU:

    python_embeded\\python.exe bench\\kernel_probe.py            (human-readable)
    python_embeded\\python.exe bench\\kernel_probe.py --json     (for Optimize-ComfyUI.ps1)

What it measures, at Wan 2.2 14B shapes (hidden 5120, 40 heads x 128, 640x640x81
-> 21 latent frames x 40 x 40 = 33,600 tokens):

  * fp16 GEMM with fp32 vs fp16 accumulation  -> justifies --fast fp16_accumulation
  * attention: PyTorch SDPA vs comfy-kitchen INT8 (Sage-style) vs sageattention
    (if installed), with output error vs SDPA  -> justifies --use-ck-attention
  * prerequisites for dynamic VRAM (torch >= 2.8, comfy_aimdo) and the
    comfy-kitchen CUDA backend (torch built for CUDA >= 13)
"""

import argparse
import json
import platform
import sys
import time

RESULT = {"ok": True, "notes": []}
DEVICE = "cuda"


def note(msg):
    RESULT["notes"].append(msg)


def version_tuple(v):
    out = []
    for part in v.split("+")[0].split("."):
        digits = "".join(ch for ch in part if ch.isdigit())
        out.append(int(digits) if digits else 0)
    return tuple(out)


def pkg_version(mod, name):
    try:
        from importlib.metadata import version
        return version(name)
    except Exception:
        return getattr(mod, "__version__", "installed")


def cuda_time(fn, iters, warmup=2):
    import torch
    for _ in range(warmup):
        fn()
    torch.cuda.synchronize()
    start = torch.cuda.Event(enable_timing=True)
    end = torch.cuda.Event(enable_timing=True)
    start.record()
    for _ in range(iters):
        fn()
    end.record()
    torch.cuda.synchronize()
    return start.elapsed_time(end) / iters  # ms


def rel_err(out, ref):
    import torch
    out = out.float()
    ref = ref.float()
    cos = torch.nn.functional.cosine_similarity(out.flatten(), ref.flatten(), dim=0).item()
    rel = ((out - ref).norm() / ref.norm().clamp_min(1e-12)).item()
    return {"cosine": round(cos, 6), "rel_l2": round(rel, 5)}


def probe_env():
    import torch
    env = {
        "python": platform.python_version(),
        "os": platform.platform(),
        "torch": torch.__version__,
        "torch_cuda": torch.version.cuda,
        "cuda_available": torch.cuda.is_available(),
    }
    tv = version_tuple(torch.__version__)
    env["dynamic_vram_torch_ok"] = tv >= (2, 8)
    if not env["dynamic_vram_torch_ok"]:
        note("torch < 2.8: ComfyUI falls back to legacy (non-dynamic) VRAM management. Update the portable build.")
    cuda_major = version_tuple(torch.version.cuda)[0] if torch.version.cuda else 0
    env["cu130_or_newer"] = cuda_major >= 13
    if torch.version.cuda and not env["cu130_or_newer"]:
        note("torch is built for CUDA %s: ComfyUI disables the comfy-kitchen CUDA kernels below CUDA 13 "
             "(slower RoPE/quant ops). Move to the cu130 portable build (needs NVIDIA driver >= 580)."
             % torch.version.cuda)
    try:
        __import__("comfy_aimdo")
        env["comfy_aimdo"] = True
    except Exception as e:  # pragma: no cover - depends on install
        env["comfy_aimdo"] = False
        note("comfy_aimdo not importable (%s): dynamic VRAM unavailable. Run update\\update_comfyui.bat." % e)
    try:
        import comfy_kitchen
        env["comfy_kitchen"] = pkg_version(comfy_kitchen, "comfy-kitchen")
    except Exception as e:
        env["comfy_kitchen"] = None
        note("comfy_kitchen not importable (%s)." % e)
    for mod, dist in (("sageattention", "sageattention"), ("triton", "triton-windows"),
                      ("xformers", "xformers"), ("flash_attn", "flash-attn")):
        try:
            m = __import__(mod)
            env[mod] = pkg_version(m, dist) if mod != "triton" else getattr(m, "__version__", "installed")
        except Exception:
            env[mod] = None
    if env.get("xformers"):
        note("xformers is installed; ComfyUI prefers it over PyTorch SDPA unless --disable-xformers is passed.")

    if torch.cuda.is_available():
        props = torch.cuda.get_device_properties(0)
        env["gpu"] = props.name
        env["sm"] = "%d%d" % (props.major, props.minor)
        env["vram_gb"] = round(props.total_memory / 2**30, 2)
        env["fp8_compute"] = (props.major, props.minor) >= (8, 9)
        if not env["fp8_compute"]:
            note("GPU has no FP8 tensor cores (sm %s): fp8_scaled weights are dequantized and run in fp16, "
                 "so --fast fp8_matrix_mult does nothing here; fp16_accumulation is the relevant flag." % env["sm"])
    return env


def probe_gemm(iters, m=33600, k=5120, n=13824):
    import torch
    res = {}
    if not hasattr(torch.backends.cuda.matmul, "allow_fp16_accumulation"):
        note("torch has no allow_fp16_accumulation (needs torch >= 2.7): --fast fp16_accumulation is a no-op.")
        return res
    # default: Wan 2.2 14B FFN up-projection for 33,600 tokens: [33600 x 5120] @ [5120 x 13824]
    a = torch.randn(m, k, device=DEVICE, dtype=torch.float16)
    b = torch.randn(k, n, device=DEVICE, dtype=torch.float16) / k ** 0.5
    flops = 2.0 * m * k * n
    prev = torch.backends.cuda.matmul.allow_fp16_accumulation
    try:
        torch.backends.cuda.matmul.allow_fp16_accumulation = False
        ref = a @ b
        t32 = cuda_time(lambda: a @ b, iters)
        torch.backends.cuda.matmul.allow_fp16_accumulation = True
        out = a @ b
        t16 = cuda_time(lambda: a @ b, iters)
    finally:
        torch.backends.cuda.matmul.allow_fp16_accumulation = prev
    res = {
        "shape": [m, k, n],
        "fp32_accum_ms": round(t32, 2),
        "fp16_accum_ms": round(t16, 2),
        "fp32_accum_tflops": round(flops / t32 / 1e9, 1),
        "fp16_accum_tflops": round(flops / t16 / 1e9, 1),
        "speedup": round(t32 / t16, 2),
        "error": rel_err(out, ref),
    }
    return res


def probe_attention(iters, tokens, heads=40, dim=128):
    import torch
    import torch.nn.functional as F
    res = {}
    g = torch.Generator(device=DEVICE).manual_seed(0)
    shape = (1, heads, tokens, dim)
    q = torch.randn(shape, device=DEVICE, dtype=torch.float16, generator=g)
    k = torch.randn(shape, device=DEVICE, dtype=torch.float16, generator=g)
    v = torch.randn(shape, device=DEVICE, dtype=torch.float16, generator=g)
    flops = 4.0 * heads * tokens * tokens * dim
    ref = F.scaled_dot_product_attention(q, k, v)
    t = cuda_time(lambda: F.scaled_dot_product_attention(q, k, v), iters)
    res["pytorch_sdpa"] = {"ms": round(t, 2), "tflops": round(flops / t / 1e9, 1)}

    try:
        import comfy_kitchen
        if comfy_kitchen.int8_attention_is_available(q.device):
            out = comfy_kitchen.int8_attention(q, k, v)
            tc = cuda_time(lambda: comfy_kitchen.int8_attention(q, k, v), iters)
            res["comfy_kitchen_int8"] = {"ms": round(tc, 2), "tflops": round(flops / tc / 1e9, 1),
                                         "speedup_vs_sdpa": round(t / tc, 2), "error": rel_err(out, ref)}
        else:
            res["comfy_kitchen_int8"] = {"available": False}
            note("comfy-kitchen INT8 attention unavailable on this GPU/torch: do NOT pass --use-ck-attention "
                 "(ComfyUI exits at startup if it is unavailable).")
    except Exception as e:
        res["comfy_kitchen_int8"] = {"available": False, "error_msg": str(e)[:300]}

    try:
        from sageattention import sageattn
        out = sageattn(q, k, v, tensor_layout="HND")
        ts = cuda_time(lambda: sageattn(q, k, v, tensor_layout="HND"), iters)
        res["sageattention"] = {"ms": round(ts, 2), "tflops": round(flops / ts / 1e9, 1),
                                "speedup_vs_sdpa": round(t / ts, 2), "error": rel_err(out, ref)}
    except ImportError:
        pass
    except Exception as e:
        res["sageattention"] = {"available": False, "error_msg": str(e)[:300]}
    return res


def recommend(r):
    rec = []
    gemm = r.get("gemm") or {}
    if gemm.get("speedup", 0) >= 1.15 and gemm.get("error", {}).get("cosine", 0) > 0.999:
        rec.append("--fast fp16_accumulation")
    attn = r.get("attention") or {}
    ck = attn.get("comfy_kitchen_int8") or {}
    if ck.get("speedup_vs_sdpa", 0) >= 1.2 and ck.get("error", {}).get("cosine", 0) > 0.995:
        rec.append("--use-ck-attention")
    else:
        sa = attn.get("sageattention") or {}
        if sa.get("speedup_vs_sdpa", 0) >= 1.2 and sa.get("error", {}).get("cosine", 0) > 0.995:
            rec.append("--use-sage-attention")
    return rec


def human(r):
    env = r["env"]
    print("=" * 72)
    print("GPU    : %s  sm_%s  %.1f GB" % (env.get("gpu", "none"), env.get("sm", "?"), env.get("vram_gb", 0)))
    print("Torch  : %s (CUDA %s)  Python %s" % (env["torch"], env["torch_cuda"], env["python"]))
    print("Stack  : comfy_kitchen=%s comfy_aimdo=%s sageattention=%s triton=%s xformers=%s" % (
        env.get("comfy_kitchen"), env.get("comfy_aimdo"), env.get("sageattention"), env.get("triton"), env.get("xformers")))
    print("Checks : dynamic-VRAM torch>=2.8: %s | cu130+: %s" % (env.get("dynamic_vram_torch_ok"), env.get("cu130_or_newer")))
    g = r.get("gemm")
    if g:
        print("-" * 72)
        print("FP16 GEMM %s  fp32-acc %.1f TFLOPS | fp16-acc %.1f TFLOPS | %.2fx | cos %.6f"
              % ("x".join(map(str, g["shape"])), g["fp32_accum_tflops"], g["fp16_accum_tflops"], g["speedup"], g["error"]["cosine"]))
    a = r.get("attention")
    if a:
        print("-" * 72)
        print("Attention 1x40x%dx128 fp16:" % r["tokens"])
        for name, v in a.items():
            if "ms" in v:
                extra = ""
                if "speedup_vs_sdpa" in v:
                    extra = " | %.2fx vs SDPA | cos %.6f relL2 %.4f" % (v["speedup_vs_sdpa"], v["error"]["cosine"], v["error"]["rel_l2"])
                print("  %-20s %8.2f ms  %6.1f TFLOPS%s" % (name, v["ms"], v["tflops"], extra))
            else:
                print("  %-20s unavailable %s" % (name, v.get("error_msg", "")))
    print("-" * 72)
    for n in r["notes"]:
        print("NOTE: " + n)
    print("RECOMMENDED FLAGS: %s" % (" ".join(r["recommended_flags"]) or "(none beyond defaults)"))
    print("Kernel speedups are upper bounds; confirm end-to-end with comfy_bench.py and eyeball the output.")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--json", action="store_true", help="print machine-readable JSON only")
    p.add_argument("--iters", type=int, default=10)
    p.add_argument("--tokens", type=int, default=33600, help="attention sequence length (default: Wan 640x640x81)")
    a = p.parse_args()

    try:
        import torch
    except ImportError:
        print(json.dumps({"ok": False, "error": "torch not importable"}) if a.json else "torch not importable")
        sys.exit(1)

    RESULT["env"] = probe_env()
    RESULT["tokens"] = a.tokens
    if torch.cuda.is_available():
        t0 = time.time()
        try:
            RESULT["gemm"] = probe_gemm(a.iters)
        except Exception as e:
            RESULT["gemm"] = {}
            note("GEMM probe failed: %s" % e)
        torch.cuda.empty_cache()
        try:
            RESULT["attention"] = probe_attention(a.iters, a.tokens)
        except Exception as e:
            RESULT["attention"] = {}
            note("attention probe failed: %s" % e)
        RESULT["probe_seconds"] = round(time.time() - t0, 1)
    else:
        RESULT["ok"] = False
        note("CUDA not available to torch: check the NVIDIA driver, or you are running a CPU-only torch.")
    RESULT["recommended_flags"] = recommend(RESULT)

    if a.json:
        print(json.dumps(RESULT))
    else:
        human(RESULT)


if __name__ == "__main__":
    main()
