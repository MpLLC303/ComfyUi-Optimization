#!/usr/bin/env python3
"""
wan_int8_convert.py - convert a Wan 2.2 14B expert to ComfyUI's native INT8 W8A8 format
(int8_tensorwise + ConvRot, per-channel), optionally baking LoRAs (e.g. lightx2v 4-step) in fp32
before quantizing.

On an RTX 3090 (sm_86, no FP8 tensor cores) ComfyUI runs INT8 weights on the INT8 tensor cores
(284 TOPS) instead of dequantizing fp8 to fp16 (142 TFLOPS with fp16 accumulation). Measure the
kernel gain first: bench/kernel_probe.py reports "INT8 W8A8 ... speedup".

Uses ComfyUI's own quantized-tensor classes, so the output is exactly the format ComfyUI loads
(detected from the per-layer ".comfy_quant" entries). Only the transformer-block linears are
quantized: blocks.N.{self_attn,cross_attn}.{q,k,v,o} and blocks.N.ffn.{0,2}. Embeddings, head,
modulation, norms and biases stay bf16.

Run from the portable root with the embedded Python, ComfyUI stopped:
  python_embeded\\python.exe -s optimizer\\bench\\wan_int8_convert.py --comfy ComfyUI ^
      --src ComfyUI\\models\\diffusion_models\\wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors ^
      --lora ComfyUI\\models\\loras\\wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors:1.0 ^
      --out ComfyUI\\models\\diffusion_models\\wan2.2_t2v_high_noise_14B_int8convrot_lx2v.safetensors

Sources: fp16/bf16 (best) or fp8_scaled (dequantized with its per-tensor scale first; INT8 per-row
has more precision than FP8 e4m3, so re-quantizing adds little on top of the existing fp8 error).
Peak RAM is about the output size (~15 GB) plus one layer.
"""
import argparse
import json
import os
import re
import sys
import time

QUANT_RE = re.compile(r"^(?P<pfx>.*?)(?P<layer>blocks\.\d+\.(?:self_attn|cross_attn)\.(?:q|k|v|o)|blocks\.\d+\.ffn\.(?:0|2))\.weight$")
LAYER_FMT = {"format": "int8_tensorwise", "convrot": True, "convrot_groupsize": 256}


def comfy_quant_tensor(torch, conf):
    return torch.tensor(list(json.dumps(conf).encode("utf-8")), dtype=torch.uint8)


def load_loras(torch, safe_open, specs):
    """{layer_name: [(kind, tensors, strength)]}, layer names like 'blocks.0.self_attn.q'."""
    out, unused = {}, []
    for spec in specs:
        m = re.match(r"^(.*?)(?::([-+0-9.]+))?$", spec)
        path, strength = m.group(1), float(m.group(2) or 1.0)
        with safe_open(path, "pt", device="cpu") as f:
            keys = list(f.keys())
            tens = {k: f.get_tensor(k) for k in keys}
        consumed = set()
        for k in keys:
            mm = re.match(r"^(?:diffusion_model\.|model\.diffusion_model\.|transformer\.)?(.*)\.(lora_down|lora_A)\.weight$", k)
            if mm:
                base, kind = mm.group(1), mm.group(2)
                up_k = k.replace(kind + ".weight", "lora_up.weight" if kind == "lora_down" else "lora_B.weight")
                a_k = k.replace("." + kind + ".weight", ".alpha")
                down, up = tens[k].float(), tens[up_k].float()
                rank = down.shape[0]
                alpha = float(tens[a_k].item()) if a_k in tens else float(rank)
                out.setdefault(base, []).append(("lowrank", (up, down, alpha / rank), strength))
                consumed |= {k, up_k, a_k}
                continue
            mm = re.match(r"^(?:diffusion_model\.|model\.diffusion_model\.|transformer\.)?(.*)\.(diff|diff_b)$", k)
            if mm:
                out.setdefault(mm.group(1), []).append((mm.group(2), (tens[k].float(),), strength))
                consumed.add(k)
        unused += ["%s:%s" % (path, k) for k in keys if k not in consumed]
    return out, unused


def dequant_source(torch, f, key, keys):
    w = f.get_tensor(key)
    if w.dtype in (torch.float8_e4m3fn, torch.float8_e5m2):
        base = key[: -len(".weight")]
        for sk in (base + ".weight_scale", base + ".scale_weight"):
            if sk in keys:
                return w.float() * f.get_tensor(sk).float(), {sk}
        return w.float(), set()
    return w.float(), set()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--comfy", default="ComfyUI", help="path to the ComfyUI folder (for its quantization classes)")
    ap.add_argument("--lora", action="append", default=[], help="path[:strength] to bake in, repeatable")
    ap.add_argument("--device", default=None, help="cuda (default when available) or cpu")
    a = ap.parse_args()

    sys.path.insert(0, os.path.abspath(a.comfy))
    import torch
    from safetensors import safe_open
    from safetensors.torch import save_file
    import comfy.cli_args
    if not torch.cuda.is_available():
        comfy.cli_args.args.cpu = True
    import comfy.quant_ops  # noqa: F401  (registers ComfyUI's layout classes)
    from comfy_kitchen.tensor import QuantizedTensor

    device = a.device or ("cuda" if torch.cuda.is_available() else "cpu")
    if os.path.exists(a.out):
        sys.exit("refusing to overwrite existing %s" % a.out)
    tmp = a.out + ".part"

    loras, unused = load_loras(torch, safe_open, a.lora)
    used = set()
    out = {}
    nq = 0
    t0 = time.time()
    with safe_open(a.src, "pt", device="cpu") as f:
        keys = list(f.keys())
        skip = set()
        for i, key in enumerate(keys):
            if key in skip or key == "scaled_fp8" or key.endswith(
                    (".scale_weight", ".weight_scale", ".scale_input", ".input_scale", ".comfy_quant")):
                continue
            w, used_scale = dequant_source(torch, f, key, keys)
            skip |= used_scale
            name = key[: -len(".weight")] if key.endswith(".weight") else key[: -len(".bias")] if key.endswith(".bias") else key
            stripped = re.sub(r"^(model\.diffusion_model\.|diffusion_model\.)", "", name)
            for kind, t, s in loras.get(stripped, []):
                if kind == "lowrank" and key.endswith(".weight"):
                    up, down, scale = t
                    w = w.to(device) + (s * scale) * (up.to(device) @ down.to(device)).reshape(w.shape)
                elif kind == "diff" and key.endswith(".weight"):
                    w = w.to(device) + s * t[0].to(device).reshape(w.shape)
                elif kind == "diff_b" and key.endswith(".bias"):
                    w = w.to(device) + s * t[0].to(device).reshape(w.shape)
                else:
                    continue
                used.add((stripped, kind))
            if QUANT_RE.match(key):
                qt = QuantizedTensor.from_float(w.to(device, torch.bfloat16), "TensorWiseINT8Layout",
                                                per_channel=True, convrot=True, convrot_groupsize=256)
                for k2, v in qt.state_dict(key).items():
                    out[k2] = v.detach().contiguous().cpu()
                out[key[: -len(".weight")] + ".comfy_quant"] = comfy_quant_tensor(torch, LAYER_FMT)
                nq += 1
            else:
                out[key] = (w.to(torch.bfloat16) if w.is_floating_point() else w).contiguous().cpu()
            if i % 100 == 0:
                print("  %d/%d tensors, %d quantized, %.0fs" % (i, len(keys), nq, time.time() - t0), flush=True)
    missing = [(l, k) for l, v in loras.items() for (k, _, _) in v if (l, k) not in used]
    if a.lora and (unused or missing):
        print("WARNING: %d unrecognised LoRA keys, %d LoRA entries matched no model key" % (len(unused), len(missing)))
        for x in (unused + [str(m) for m in missing])[:20]:
            print("   ", x)
        if len(missing) > 0 and not used:
            sys.exit("ERROR: no LoRA entry matched the model; wrong LoRA for this expert?")
    if nq == 0:
        sys.exit("ERROR: no Wan transformer-block linears found in %s (not a Wan 2.x diffusion model?)" % a.src)
    save_file(out, tmp, metadata={"converted_by": "wan_int8_convert.py", "source": os.path.basename(a.src),
                                  "loras": ";".join(os.path.basename(x) for x in a.lora)})
    os.replace(tmp, a.out)
    size = sum(v.numel() * v.element_size() for v in out.values()) / 1e9
    print("wrote %s: %.2f GB, %d linears int8, %d LoRA layers baked, %.0fs" % (a.out, size, nq, len(used), time.time() - t0))


if __name__ == "__main__":
    main()
