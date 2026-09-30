#!/usr/bin/env python3
"""
env_info.py - print one JSON line describing the ComfyUI portable Python environment.

Used by Optimize-ComfyUI.ps1 (run as a file, never via `python -c`, because Windows
PowerShell 5.1 mangles embedded double quotes in native-command arguments).
Every key is always present; values are null when unknown. Never raises.

    python_embeded\\python.exe -s bench\\env_info.py <path-to-ComfyUI>
"""

import json
import platform
import sys

PACKAGES = (
    "torch", "torchvision", "torchaudio", "xformers", "comfy-kitchen", "comfy-aimdo",
    "comfyui-frontend-package", "comfyui-workflow-templates", "sageattention", "triton-windows",
    "comfyui_manager", "pillow",
)


def main():
    d = {"python": platform.python_version(), "torch": None, "cuda": None, "cuda_ok": False,
         "torch_error": None, "comfyui": None, "gpu": None, "sm": None, "ck_int8_attention": None}
    try:
        from importlib.metadata import version, PackageNotFoundError
        for n in PACKAGES:
            try:
                d["pkg_" + n] = version(n)
            except PackageNotFoundError:
                d["pkg_" + n] = None
            except Exception:
                d["pkg_" + n] = None
    except Exception:
        for n in PACKAGES:
            d["pkg_" + n] = None
    try:
        import torch
        d["torch"] = torch.__version__
        d["cuda"] = torch.version.cuda
        d["cuda_ok"] = bool(torch.cuda.is_available())
        if d["cuda_ok"]:
            p = torch.cuda.get_device_properties(0)
            d["gpu"] = p.name
            d["sm"] = "%d%d" % (p.major, p.minor)
            try:
                import comfy_kitchen
                d["ck_int8_attention"] = bool(comfy_kitchen.int8_attention_is_available(torch.device("cuda")))
            except Exception as e:  # extension missing / wrong CUDA runtime (needs cublasLt64_13)
                d["ck_int8_attention"] = False
                d["ck_error"] = str(e)[:300]
    except BaseException as e:  # c10.dll / VC++ runtime errors surface as OSError
        d["torch_error"] = ("%s: %s" % (type(e).__name__, e))[:500]
    if len(sys.argv) > 1:
        try:
            sys.path.insert(0, sys.argv[1])
            import comfyui_version
            d["comfyui"] = comfyui_version.__version__
        except Exception:
            pass
    print("JSON:" + json.dumps(d))


if __name__ == "__main__":
    main()
