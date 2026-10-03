# Improvement backlog

Worked top-down by a continuous improve-test-ship loop. An item is only marked done after the
sandbox harness (static checks, integration test, installer mock run) passes and the change is on
`main`.

Ground truth from the first real install (RTX 3090, driver 617.14, Windows 11 25H2):
Main 188.5 tok/s @ 65,536 ctx, Fast 79 tok/s @ 40,960, Vision 184.8 tok/s @ 32,768,
Code 178.5 tok/s @ 65,536; 31/31 acceptance checks.

| # | Item | Status | Result |
|---|---|---|---|
| 1 | `Set-OpenWebUIPassword.ps1`: rotate the admin password via the API and update `Secrets\openwebui-admin.json` | done | Verified against Open WebUI 0.11.4: old password rejected, sessions revoked, secrets file updated; copied to `C:\AI\Scripts` by the installer |
| 2 | Repo-local static checks (`tests/Invoke-StaticChecks.ps1`): parse, ASCII, PSSA 5.1 compat, plus a custom scan for PS 5.1 runtime pitfalls (e.g. `Measure-Object -Property` on hashtables) | done | Uses PowerShell's static binder to find property-name args to Measure/Group/Sort/Select; canary-tested; 13 files, 0 problems |
| 3 | `Restore-OpenWebUI.ps1`: restore a backup archive into the volume (with a safety backup first) | done | Subagent review found 12 issues (wipe-before-extract, retention pruning the target, shell-quoting data loss...); rewritten with staged swap + auto-rollback + machine-wide lock; tested: odd file names, NAS-style external path, corrupt/junk archives (no change), mid-swap failure (rolled back), restart policies preserved |
| 4 | VRAM-busy guard: before tuning, refuse/wait when other processes hold > 3 GB, so contexts are not tuned against a busy card | done | `Wait-LaiGpuIdle` runs before the Models and Tuning stages: waits up to `-GpuWaitMinutes` (10) for other apps to drop below `-MaxBusyVramMiB` (3500), names the GPU processes, then stops with a clear message; nvidia-smi calls made safe for PS 5.1 stderr handling |
| 5 | `Update-Models.ps1`: re-pull catalog models, rebuild tuned aliases only when the source digest changed | done | Digest before/after each pull; unchanged models untouched, changed ones re-tuned and aliases rebuilt (presets keep working); `-UpdateOllama` via winget; tested both paths in the sandbox |
| 6 | ComfyUI/Ollama GPU handoff: `Start-ComfyUI.ps1` wrapper that runs Release-GPU first (and optional `-KeepAlive 0` mode while ComfyUI runs) | todo | |
| 7 | Optional `-TailscaleServe` (phone access over the tailnet via `tailscale serve`, still no LAN exposure) | todo | |
| 9 | Backup integrity: periodic `tar tzf` test-restore of the newest archive into a scratch volume (catches silent corruption) | todo | |
| 10 | `Test-LocalAI.ps1 -Watch`: lightweight health check (Ollama/Open WebUI/SearXNG up, model on GPU) suitable for a scheduled task that toasts on failure | todo | |
| 8 | README refresh with the measured numbers and the corrected speed expectations | todo | |
