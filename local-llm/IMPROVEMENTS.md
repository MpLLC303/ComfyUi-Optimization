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
| 6 | ComfyUI/Ollama GPU handoff: `Start-ComfyUI.ps1` wrapper that runs Release-GPU first (and optional `-KeepAlive 0` mode while ComfyUI runs) | done | Unloads Ollama, reports free VRAM and remaining GPU apps, finds Comfy Desktop / portable build / Start-menu shortcut, remembers the path, `-CreateShortcut` desktop icon. Keep-alive-0 mode dropped: it would slow every chat, not just during renders |
| 7 | Optional `-TailscaleServe` (phone access over the tailnet via `tailscale serve`, still no LAN exposure) | done | `Enable-TailscaleAccess.ps1`: subagent read the tailscale v1.104 source; script pre-checks login + HTTPS-cert capability (serve otherwise blocks or exits 0 doing nothing), runs `serve --bg`, verifies via `serve status --json`, `-Disable` is idempotent; mock-tested all paths |
| 9 | Backup integrity: periodic `tar tzf` test-restore of the newest archive into a scratch volume (catches silent corruption) | done | Every backup now opens the archived webui.db (+WAL) with SQLite in a throwaway volume using the already-local Open WebUI image: `integrity_check` + user/chat counts in the log. Corrupt archives are quarantined as `-CORRUPT` (never count toward keep-3) and Test-LocalAI fails loudly; tested with a real Open WebUI DB and a deliberately corrupted one |
| 10 | `Test-LocalAI.ps1 -Watch`: lightweight health check (Ollama/Open WebUI/SearXNG up, model on GPU) suitable for a scheduled task that toasts on failure | done | Separate `Watch-LocalAI.ps1` (~1 s, loads no model): Ollama/Open WebUI/SearXNG/backup freshness, self-heals stopped containers and Ollama, two-strike toasts (no false alarm while Docker starts after sign-in), recovery toast; 15-min non-elevated task via `conhost --headless`; sandbox-tested 7 state sequences |
| 12 | Watch: also alert when Docker Desktop itself is not running (start it), and when free disk on the model/volume drive drops below 10 GB | todo | |
| 13 | Uninstall/cleanup script: remove scheduled tasks, containers, volume (after a final backup), aliases; keep models unless asked | todo | |
| 11 | Render guard: while ComfyUI's python.exe holds the GPU, have Open WebUI chats fall back to Local Fast (14B, 11.6 GiB) or warn, instead of evicting the render | todo | |
| 8 | README refresh with the measured numbers and the corrected speed expectations | done | Measured table in README, speed claims corrected (Main is 2.4x Fast), slow-speed thresholds = half the measured speed, and Test-LocalAI now measures tok/s per model to catch silent VRAM->RAM spill |
