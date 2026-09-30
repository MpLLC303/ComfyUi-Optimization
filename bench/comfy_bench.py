#!/usr/bin/env python3
"""
comfy_bench.py - reproducible ComfyUI benchmark harness (stdlib only).

Runs an API-format workflow against a running ComfyUI server N times and
records wall time, ComfyUI execution time, and GPU telemetry (peak VRAM,
utilization, power, temperature via nvidia-smi) to a CSV. Use it to measure
a baseline launcher against an optimized one, so every "speedup" is a
number instead of a feeling.

Runs on the ComfyUI portable interpreter; no pip installs needed:

    python_embeded\\python.exe bench\\comfy_bench.py run workflows\\wan22_t2v_4step_api.json ^
        --label baseline --runs 3

    python_embeded\\python.exe bench\\comfy_bench.py compare bench_results.csv

    python_embeded\\python.exe bench\\comfy_bench.py quick optimized --set WanImageToVideo.width=832

Workflow file: File > Export (API) from the ComfyUI menu, or one of the files
in ../workflows. Both the raw prompt dict and {"prompt": {...}} are accepted.
"""

import argparse
import csv
import json
import os
import random
import shutil
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime

SEED_INPUTS = ("noise_seed", "seed")


# --------------------------------------------------------------------------- #
# HTTP helpers
# --------------------------------------------------------------------------- #
def http_json(url, payload=None, timeout=30):
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()
    return json.loads(body) if body else {}


def server_up(base):
    try:
        http_json(base + "/system_stats", timeout=5)
        return True
    except Exception:
        return False


# --------------------------------------------------------------------------- #
# GPU telemetry (nvidia-smi sampler thread)
# --------------------------------------------------------------------------- #
class GpuSampler:
    FIELDS = "memory.used,utilization.gpu,power.draw,temperature.gpu,clocks.sm"

    def __init__(self, gpu_index=0, interval_ms=250):
        self.gpu_index = gpu_index
        self.interval_ms = interval_ms
        self.samples = []
        self._proc = None
        self._thread = None
        self.available = shutil.which("nvidia-smi") is not None

    def start(self):
        if not self.available:
            return
        cmd = [
            "nvidia-smi",
            "-i", str(self.gpu_index),
            "--query-gpu=" + self.FIELDS,
            "--format=csv,noheader,nounits",
            "-lms", str(self.interval_ms),
        ]
        try:
            self._proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
            )
        except OSError:
            self.available = False
            return
        self._thread = threading.Thread(target=self._read, daemon=True)
        self._thread.start()

    def _read(self):
        for line in self._proc.stdout:
            parts = [p.strip() for p in line.split(",")]
            if len(parts) != 5:
                continue
            try:
                self.samples.append(tuple(float(p) for p in parts))
            except ValueError:
                # "[N/A]" on some fields for some boards
                continue

    def stop(self):
        if self._proc:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        if self._thread:
            self._thread.join(timeout=5)

    def summary(self):
        if not self.samples:
            return {}
        mem = [s[0] for s in self.samples]
        util = [s[1] for s in self.samples]
        power = [s[2] for s in self.samples]
        temp = [s[3] for s in self.samples]
        clk = [s[4] for s in self.samples]
        return {
            "peak_vram_mib": int(max(mem)),
            "mean_gpu_util_pct": round(statistics.mean(util), 1),
            "mean_power_w": round(statistics.mean(power), 1),
            "max_temp_c": int(max(temp)),
            "mean_sm_clock_mhz": int(statistics.mean(clk)),
        }


# --------------------------------------------------------------------------- #
# Workflow handling
# --------------------------------------------------------------------------- #
def load_workflow(path):
    with open(path, "r", encoding="utf-8") as f:
        wf = json.load(f)
    if "prompt" in wf and isinstance(wf["prompt"], dict):
        wf = wf["prompt"]
    if "nodes" in wf and "links" in wf:
        sys.exit(
            "ERROR: this is a UI-format workflow. In ComfyUI use "
            "Workflow > Export (API) and benchmark that file instead."
        )
    # strip non-node keys some exporters add
    return {k: v for k, v in wf.items() if isinstance(v, dict) and "class_type" in v}


def coerce(value):
    for cast in (int, float):
        try:
            return cast(value)
        except ValueError:
            pass
    if value.lower() in ("true", "false"):
        return value.lower() == "true"
    return value


def apply_overrides(wf, overrides):
    """--set 12.steps=4  or  --set KSamplerAdvanced.cfg=1 (all nodes of a class)."""
    for ov in overrides or []:
        target, _, value = ov.partition("=")
        node_ref, _, key = target.rpartition(".")
        if not node_ref or not key or not _:
            sys.exit("ERROR: bad --set '%s', expected NODE.input=value" % ov)
        hits = [nid for nid, n in wf.items() if nid == node_ref or n["class_type"] == node_ref]
        if not hits:
            sys.exit("ERROR: --set '%s' matched no node id or class_type" % ov)
        for nid in hits:
            wf[nid]["inputs"][key] = coerce(value)


def set_seeds(wf, seed):
    touched = 0
    for node in wf.values():
        for key in SEED_INPUTS:
            if key in node["inputs"] and not isinstance(node["inputs"][key], list):
                node["inputs"][key] = seed
                touched += 1
    return touched


# --------------------------------------------------------------------------- #
# One benchmark run
# --------------------------------------------------------------------------- #
def run_once(base, wf, timeout_s, sampler):
    client_id = str(uuid.uuid4())
    sampler.start()
    t0 = time.perf_counter()
    try:
        resp = http_json(base + "/prompt", {"prompt": wf, "client_id": client_id})
    except urllib.error.HTTPError as e:
        sampler.stop()
        detail = e.read().decode("utf-8", "replace")
        raise RuntimeError("server rejected workflow (HTTP %d): %s" % (e.code, detail[:2000]))
    if resp.get("node_errors"):
        # HTTP 200 + node_errors: some outputs failed validation but the rest of the prompt is queued
        print("\n  warning: partial prompt, some outputs failed validation: " + json.dumps(resp["node_errors"])[:500])
    prompt_id = resp["prompt_id"]

    entry = None
    while time.perf_counter() - t0 < timeout_s:
        try:
            hist = http_json(base + "/history/" + prompt_id)
        except Exception:
            hist = {}
        # ComfyUI only writes a history entry once the prompt has finished (ok or error)
        if prompt_id in hist:
            entry = hist[prompt_id]
            break
        time.sleep(0.25)
    wall = time.perf_counter() - t0
    sampler.stop()

    if entry is None:
        # don't leave a runaway job on the GPU: dequeue it if pending, interrupt it if running
        for path, payload in (("/queue", {"delete": [prompt_id]}), ("/interrupt", {"prompt_id": prompt_id})):
            try:
                http_json(base + path, payload)
            except Exception:
                pass
        raise RuntimeError("timed out after %ds waiting for prompt %s (interrupted)" % (timeout_s, prompt_id))

    status = entry.get("status", {})
    msgs = {m[0]: m[1] for m in status.get("messages", []) if isinstance(m, list) and len(m) == 2}
    if status.get("status_str") != "success":
        err = msgs.get("execution_error", {})
        raise RuntimeError(
            "execution failed in node %s (%s): %s"
            % (err.get("node_id"), err.get("node_type"), (err.get("exception_message") or "").strip()[:1500])
        )

    exec_s = None
    start, end = msgs.get("execution_start", {}), msgs.get("execution_success", {})
    if "timestamp" in start and "timestamp" in end:
        exec_s = (end["timestamp"] - start["timestamp"]) / 1000.0
    cached = len(msgs.get("execution_cached", {}).get("nodes", []))
    return {
        "wall_s": round(wall, 2),
        "exec_s": round(exec_s, 2) if exec_s is not None else "",
        "cached_nodes": cached,
        "fully_cached": cached >= len(wf),
    }


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
def cmd_run(a):
    base = "http://" + a.host.replace("http://", "").rstrip("/")
    if not server_up(base):
        sys.exit("ERROR: no ComfyUI server at %s. Start a launcher first." % base)

    wf_template = load_workflow(a.workflow)
    apply_overrides(wf_template, a.set)
    stats = http_json(base + "/system_stats")
    dev = (stats.get("devices") or [{}])[0]
    sysinfo = stats.get("system", {})
    print("Server : %s" % base)
    print("Device : %s | VRAM %.1f GB" % (dev.get("name", "?"), dev.get("vram_total", 0) / 2**30))
    print("Torch  : %s | ComfyUI %s" % (sysinfo.get("pytorch_version", "?"), sysinfo.get("comfyui_version", "?")))
    print("Args   : %s" % " ".join(sysinfo.get("argv", [])[1:]))

    base_seed = a.seed if a.seed is not None else random.randint(0, 2**31)
    rows = []
    total = a.warmup + a.runs
    for i in range(total):
        phase = "warmup" if i < a.warmup else "timed"
        if a.cold:
            http_json(base + "/free", {"unload_models": True, "free_memory": True})
            time.sleep(2)
        wf = json.loads(json.dumps(wf_template))
        seed = base_seed + i
        seeded = set_seeds(wf, seed)
        sampler = GpuSampler(a.gpu)
        if a.no_gpu_stats:
            sampler.available = False
        print("[%d/%d] %s seed=%d ..." % (i + 1, total, phase, seed), end="", flush=True)
        try:
            res = run_once(base, wf, a.timeout, sampler)
        except RuntimeError as e:
            print(" FAILED\n  " + str(e))
            if a.keep_going:
                continue
            write_csv(a.csv, rows)  # keep the runs that did complete
            sys.exit(2)
        res.update(sampler.summary())
        print(" wall %.1fs exec %ss %s%s" % (
            res["wall_s"], res["exec_s"],
            ("peakVRAM %d MiB" % res["peak_vram_mib"]) if "peak_vram_mib" in res else "",
            "  [FULLY CACHED - not a real measurement%s]" % ("" if seeded else "; workflow has no seed input")
            if res["fully_cached"] else ""))
        row = {
            "timestamp": datetime.now().isoformat(timespec="seconds"),
            "label": a.label,
            "workflow": os.path.basename(a.workflow),
            "phase": phase,
            "run": i + 1,
            "seed": seed,
            "cold": a.cold,
            "overrides": " ".join(a.set or []),
            "server_args": " ".join(sysinfo.get("argv", [])[1:]),
            "torch": sysinfo.get("pytorch_version", ""),
            "gpu": dev.get("name", ""),
        }
        row.update(res)
        rows.append(row)

    write_csv(a.csv, rows)
    timed = [r["wall_s"] for r in rows if r["phase"] == "timed" and not r["fully_cached"]]
    if timed:
        print("\n%s: median %.1fs over %d timed runs (min %.1f, max %.1f) -> %s"
              % (a.label, statistics.median(timed), len(timed), min(timed), max(timed), a.csv))
    return rows


FIELDNAMES = [
    "timestamp", "label", "workflow", "phase", "run", "seed", "cold", "wall_s", "exec_s",
    "cached_nodes", "fully_cached", "peak_vram_mib", "mean_gpu_util_pct", "mean_power_w", "max_temp_c",
    "mean_sm_clock_mhz", "overrides", "server_args", "torch", "gpu",
]


def write_csv(path, rows):
    if not rows:
        return
    new = not os.path.exists(path)
    with open(path, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDNAMES, extrasaction="ignore")
        if new:
            w.writeheader()
        w.writerows(rows)


def cmd_compare(a):
    if not os.path.exists(a.csv):
        sys.exit("no results in %s (every run failed or none ran; see the FAILED lines above)" % a.csv)
    with open(a.csv, newline="", encoding="utf-8") as f:
        rows = [r for r in csv.DictReader(f)
                if r["phase"] == "timed" and r.get("fully_cached", "False") != "True"]
    if not rows:
        sys.exit("no timed rows in %s" % a.csv)
    groups = {}
    for r in rows:
        groups.setdefault((r["label"], r["workflow"]), []).append(r)

    baseline = {}
    for (label, wf), rs in groups.items():
        if label == a.baseline:
            baseline[wf] = statistics.median(float(r["wall_s"]) for r in rs)
    # --any-workflow: compare every label against the baseline label even when the workflow file
    # differs (experimental variants are separate files derived from the same baseline graph)
    any_base = None
    if getattr(a, "any_workflow", False) and baseline:
        any_base = statistics.median(
            float(r["wall_s"]) for (label, wf), rs in groups.items() if label == a.baseline for r in rs)

    print("%-24s %-36s %3s %9s %9s %9s %10s %8s" % (
        "label", "workflow", "n", "median_s", "best_s", "exec_med", "peakVRAM", "speedup"))
    for (label, wf), rs in sorted(groups.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        walls = [float(r["wall_s"]) for r in rs]
        execs = [float(r["exec_s"]) for r in rs if r.get("exec_s")]
        vram = [int(float(r["peak_vram_mib"])) for r in rs if r.get("peak_vram_mib")]
        med = statistics.median(walls)
        ref = baseline.get(wf, any_base)
        speed = ("%.2fx" % (ref / med)) if ref and med else "-"
        print("%-24s %-36s %3d %9.1f %9.1f %9s %10s %8s" % (
            label[:24], wf[:36], len(walls), med, min(walls),
            ("%.1f" % statistics.median(execs)) if execs else "-",
            ("%d MiB" % max(vram)) if vram else "-", speed))
    if not baseline:
        print("\n(no rows labelled '%s'; pass --baseline LABEL to compute speedups)" % a.baseline)


def cmd_quick(a):
    """run + compare with kit defaults; what run_bench.bat calls (all args pass through %*)."""
    here = os.path.dirname(os.path.abspath(__file__))
    kit = os.path.dirname(here)
    a.workflow = a.workflow or os.path.join(kit, "workflows", "wan22_i2v_4step_api.json")
    a.csv = a.csv or os.path.join(kit, "bench_results.csv")
    if a.seed is None:
        a.seed = 1234  # same seeds for every label -> apples-to-apples comparison
    try:
        cmd_run(a)
    finally:
        if os.path.exists(a.csv):
            print()
            a.baseline = "baseline"
            cmd_compare(a)


def add_run_args(r, quick=False):
    if quick:
        r.add_argument("label", nargs="?", default="run", help="name for this configuration, e.g. baseline, optimized")
        r.add_argument("--workflow", default=None, help="API-format workflow JSON (default: kit's wan22_i2v_4step_api.json)")
        r.add_argument("--csv", default=None, help="results CSV (default: <kit>/bench_results.csv)")
    else:
        r.add_argument("workflow", help="API-format workflow JSON")
        r.add_argument("--label", default="run", help="name for this configuration, e.g. baseline, sage")
        r.add_argument("--csv", default="bench_results.csv")
    r.add_argument("--host", default="127.0.0.1:8188")
    r.add_argument("--runs", type=int, default=3, help="timed runs (default 3)")
    r.add_argument("--warmup", type=int, default=1, help="untimed warmup runs (default 1; loads models)")
    r.add_argument("--cold", action="store_true", help="unload models before every run (measures load time)")
    r.add_argument("--seed", type=int, default=None, help="base seed; run i uses seed+i (default random)")
    r.add_argument("--set", action="append", metavar="NODE.input=value",
                   help="override an input by node id or class_type, repeatable")
    r.add_argument("--gpu", type=int, default=0, help="nvidia-smi GPU index")
    r.add_argument("--no-gpu-stats", action="store_true")
    r.add_argument("--timeout", type=int, default=3600, help="seconds per run")
    r.add_argument("--keep-going", action="store_true", help="continue after a failed run")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("run", help="benchmark a workflow")
    add_run_args(r)
    r.set_defaults(func=cmd_run)

    q = sub.add_parser("quick", help="run with kit defaults, then compare (used by run_bench.bat)")
    add_run_args(q, quick=True)
    q.set_defaults(func=cmd_quick)

    c = sub.add_parser("compare", help="summarize a results CSV")
    c.add_argument("csv", nargs="?", default="bench_results.csv")
    c.add_argument("--baseline", default="baseline", help="label to compute speedups against")
    c.add_argument("--any-workflow", action="store_true",
                   help="compute speedups vs the baseline label even for a different workflow file")
    c.set_defaults(func=cmd_compare)

    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
