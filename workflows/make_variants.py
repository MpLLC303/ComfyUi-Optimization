#!/usr/bin/env python3
"""
make_variants.py - derive the prompt-cache and experimental A/B workflows from the baseline
API workflows in this folder, so every variant shares the baseline's node ids, prompts and
seeds (apples-to-apples with `run_bench.bat LABEL --workflow <file>`).

    python make_variants.py          (rewrites wan22_i2v_4step_promptcache_api.json + experimental/*.json)

Baseline node ids (all four baseline files): 1/2 UNETLoader high/low, 3/4 lightx2v LoRA (4-step
files only), 5 CLIPLoader, 6 VAELoader, 7/8 positive/negative CLIPTextEncode, 9/10 ModelSamplingSD3
high/low, 11 EmptyHunyuanLatentVideo (t2v) or WanImageToVideo (i2v), 12 LoadImage (i2v),
13/14 KSamplerAdvanced high/low, 15 VAEDecode, 16 CreateVideo, 17 SaveVideo.
"""

import copy
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.join(HERE, "experimental")


def load(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return json.load(f)


def save(path, wf):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(dict(sorted(wf.items(), key=lambda kv: int(kv[0]))), f, indent=2, ensure_ascii=False)
        f.write("\n")


def prefix(wf, tag):
    wf["17"]["inputs"]["filename_prefix"] += "_" + tag
    return wf


def prompt_cache(wf):
    """I2V: take the prompt out of WanImageToVideo's ancestry so editing the positive prompt no
    longer re-runs the 81-frame VAE encode. Bitwise identical output for prompts <= 511 UMT5 tokens:
    WanImageToVideo is fed the negative on both inputs, and ConditioningAverage at strength 0.0
    swaps the real positive text embedding back in while keeping the i2v concat latent/mask."""
    wf["11"]["inputs"]["positive"] = ["8", 0]
    wf["11"]["inputs"]["negative"] = ["8", 0]
    wf["18"] = {"class_type": "ConditioningAverage",
                "_meta": {"title": "Prompt splice - KEEP strength 0.00"},
                "inputs": {"conditioning_to": ["11", 0], "conditioning_from": ["7", 0], "conditioning_to_strength": 0.0}}
    for s in ("13", "14"):
        wf[s]["inputs"]["positive"] = ["18", 0]
        wf[s]["inputs"]["negative"] = ["11", 1]
    return wf


def three_step(wf):
    """lightx2v at 3 steps: 2 high-noise + 1 low-noise (-25% DiT forwards; quality risk)."""
    for s in ("13", "14"):
        wf[s]["inputs"]["steps"] = 3
    return wf


def tae_decode(wf):
    """Decode with lighttaew2_1 (tiny Wan VAE, ~1-3 s instead of ~10-25 s; softer detail).
    File must be ComfyUI/models/vae_approx/lighttaew2_1.safetensors (or .pth -> --set 18.vae_name=...).
    The i2v start-image encode stays on the full Wan VAE (node 6)."""
    wf["18"] = {"class_type": "VAELoader", "_meta": {"title": "Tiny Wan VAE (decode only)"},
                "inputs": {"vae_name": "lighttaew2_1.safetensors"}}
    wf["15"]["inputs"]["vae"] = ["18", 0]
    return wf


def sparse_attention(wf):
    """Core 'Model Sparse Attention' (sol-attn, training-free) on both experts, after ModelSamplingSD3.
    Step 0 stays dense (start_percent 0.2). Dense fallback is the launcher's CK INT8 attention."""
    for nid, src in (("18", "9"), ("19", "10")):
        wf[nid] = {"class_type": "BlockSparseAttention", "_meta": {"title": "Model Sparse Attention"},
                   "inputs": {"model": [src, 0], "selection": "sol-attn", "selection.tau": 1.3,
                              "start_percent": 0.2, "end_percent": 1.0, "dense_blocks": "",
                              "min_tokens": 12288, "extra_tokens": 256, "sink_conditioning": "off",
                              "verbose": True}}
    wf["13"]["inputs"]["model"] = ["18", 0]
    wf["14"]["inputs"]["model"] = ["19", 0]
    return wf


def per_expert_attention(wf):
    """Per-expert attention backend (core ModelAttentionBackend). Set either node to
    'pytorch attention' to drop INT8 attention for just that expert, without restarting ComfyUI."""
    for nid, src in (("18", "9"), ("19", "10")):
        wf[nid] = {"class_type": "ModelAttentionBackend",
                   "_meta": {"title": "Attention backend (%s)" % ("high" if src == "9" else "low")},
                   "inputs": {"model": [src, 0], "attention": "comfy kitchen attention"}}
    wf["13"]["inputs"]["model"] = ["18", 0]
    wf["14"]["inputs"]["model"] = ["19", 0]
    return wf


def cascade(wf, kind, low=480, high=640):
    """High-noise expert at 480x480, x0 -> bilinear upscale -> low-noise expert re-noised at 640x640.
    Same number of model calls, but the two high-noise steps cost ~0.45x. Seed-for-seed output differs
    from native 640 (noise is drawn at 480)."""
    if kind == "t2v":
        wf["11"]["inputs"]["width"] = low
        wf["11"]["inputs"]["height"] = low
    else:
        # conditioning stays at 640 (WAN21.concat_cond resizes the concat latent to the noise size)
        wf["19"] = {"class_type": "EmptyHunyuanLatentVideo", "_meta": {"title": "Low-res latent for high-noise stage"},
                    "inputs": {"width": low, "height": low, "length": wf["11"]["inputs"]["length"], "batch_size": 1}}
        wf["13"]["inputs"]["latent_image"] = ["19", 0]
    wf["13"]["inputs"]["return_with_leftover_noise"] = "disable"  # hand over the x0 prediction
    wf["18"] = {"class_type": "LatentUpscale", "inputs": {"samples": ["13", 0], "upscale_method": "bilinear",
                                                          "width": high, "height": high, "crop": "disabled"}}
    wf["14"]["inputs"]["latent_image"] = ["18", 0]
    wf["14"]["inputs"]["add_noise"] = "enable"
    return wf


def easycache(wf):
    """20-step reference only: EasyCache on both experts (skips near-duplicate steps; no effect at 4 steps)."""
    for nid, src in (("18", "9"), ("19", "10")):
        wf[nid] = {"class_type": "EasyCache", "inputs": {"model": [src, 0], "reuse_threshold": 0.2,
                                                          "start_percent": 0.15, "end_percent": 0.95, "verbose": True}}
    wf["13"]["inputs"]["model"] = ["18", 0]
    wf["14"]["inputs"]["model"] = ["19", 0]
    return wf


def low_cfg1(wf):
    """20-step reference only: CFG 1 on the low-noise half (40 -> 30 DiT forwards)."""
    wf["14"]["inputs"]["cfg"] = 1.0
    return wf


def main():
    out = {}
    i2v4 = load("wan22_i2v_4step_api.json")
    out[os.path.join(HERE, "wan22_i2v_4step_promptcache_api.json")] = prefix(prompt_cache(copy.deepcopy(i2v4)), "promptcache")
    for kind in ("t2v", "i2v"):
        base4 = load("wan22_%s_4step_api.json" % kind)
        for tag, fn in (("3step", three_step), ("taedecode", tae_decode), ("sparse", sparse_attention),
                        ("perexpert_attn", per_expert_attention)):
            out[os.path.join(EXP, "wan22_%s_4step_%s_api.json" % (kind, tag))] = prefix(fn(copy.deepcopy(base4)), tag)
        out[os.path.join(EXP, "wan22_%s_4step_cascade480_api.json" % kind)] = prefix(cascade(copy.deepcopy(base4), kind), "cascade480")
    t2v20 = load("wan22_t2v_20step_reference_api.json")
    out[os.path.join(EXP, "wan22_t2v_20step_easycache_api.json")] = prefix(easycache(copy.deepcopy(t2v20)), "easycache")
    out[os.path.join(EXP, "wan22_t2v_20step_lowcfg1_api.json")] = prefix(low_cfg1(copy.deepcopy(t2v20)), "lowcfg1")
    for path, wf in out.items():
        save(path, wf)
        print("wrote", os.path.relpath(path, HERE))


if __name__ == "__main__":
    main()
