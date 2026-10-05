# Local LLM stack for the RTX 3090 rig

A private, self-hosted assistant: low-refusal local models, persistent memory, document
knowledge (RAG), private web search, and nightly backups. It's installed by **one resumable
script** that runs the whole "V1" build and checks every checkpoint along the way.

```
Browser ──> Open WebUI (Docker, 127.0.0.1:3000) ──> render-guard ──> Ollama (native Windows, 127.0.0.1:11434) ──> RTX 3090
                 │  memory, knowledge/RAG, presets  (CPU while          ├─ localai-main   Qwen3 30B-A3B 2507 abliterated
                 │                                   ComfyUI renders)   │
                 └─> SearXNG (Docker, 127.0.0.1:8888)             ├─ localai-fast   Qwen3 14B abliterated
                      private metasearch, no API key               ├─ localai-vision Qwen3-VL 30B-A3B abliterated (optional)
                                                                   └─ localai-code   Qwen3-Coder 30B-A3B abliterated (optional)
```

## Run it

Open a normal PowerShell window (Start > type *PowerShell*) and paste:

```powershell
$env:LOCALAI_REF = 'main'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
irm https://raw.githubusercontent.com/MpLLC303/ComfyUi-Optimization/refs/heads/main/local-llm/Get-LocalAI.ps1 | iex
```

It downloads the newest toolkit to your temp folder, unblocks it and starts the installer. You get
**one UAC prompt**, and then everything runs unattended in a new Administrator window (one more
prompt after each reboot it needs). The one exception: if Open WebUI already has an admin account
the installer doesn't know, it asks once for that account's e-mail and password. Only one installer
run (or model update) can run at a time; a second one says so and stops.

Alternative: download https://github.com/MpLLC303/ComfyUi-Optimization/archive/refs/heads/main.zip,
**Extract All**, and double-click `local-llm\Install-LocalAI.cmd`. Running it from inside the ZIP
fails. The first window then says it continues in the Administrator window, and you can close it.

Expect about 30-90 minutes. Most of that is about 67 GB of model downloads plus the Docker
image. If WSL or Docker needs a reboot, the script warns you 60 seconds ahead (`shutdown /a`
cancels it), reboots, and **continues after you sign in**: click **Yes** when Windows asks for
administrator rights. If the resumed run fails twice in a row, it stops resuming by itself: fix the
cause and run `C:\AI\Scripts\Install-LocalAI.cmd` again. At the end it opens
http://localhost:3000 and prints the admin login (also saved in
`C:\AI\Secrets\openwebui-admin.json`). The installer also allows typing script names such as
`C:\AI\Scripts\Test-LocalAI.ps1` in PowerShell, by setting the execution policy to RemoteSigned.
The everyday ones (Open WebUI, Gaming mode, Start again, Health check, ComfyUI, Diagnostics, Update
toolkit) have Start-menu shortcuts under **Local AI**; run the rest from `C:\AI\Scripts`. Every
script explains itself: `Get-Help C:\AI\Scripts\<name>.ps1 -Detailed`.

### Update the toolkit (existing installs)

New features (health watch, render guard, Start-menu folder, ...) arrive by **running the newest
toolkit**, either with **Start menu > Local AI > Update toolkit** or the same one-liner as above.
Don't run `C:\AI\Scripts\Install-LocalAI.ps1` for this: that is the copy you already have, and it
only re-applies it (it warns you). If your install is older than the Start-menu folder, use the
one-liner.

A re-run is safe, and it keeps your chats, models, image versions set by `Update-OpenWebUI.ps1`,
render-guard mode and trial models. Updating an install made by an early version of this toolkit
also carries over its backup retention, backup mirror, keep-alive and VRAM settings, makes its
scheduled tasks run without administrator rights, and removes the old `C:\AI\Installer` copy.
- **Time:** a few minutes when nothing changed. Models that are installed and already passed the
  GPU check are not loaded again, and the stored context tuning is reused. The health check at the
  end still loads each model once to measure its speed (skip it with `-SkipTests`).
- **ComfyUI and games:** they matter only when something has to be measured (a new model, a driver
  update, `-Retune`). Then the installer waits up to 10 minutes for other GPU apps to let go.
- **NVIDIA driver updates:** after one, the models are re-tuned automatically, which takes longer.
- **Open WebUI:** it restarts briefly for the backup step.
- **Your settings:** on the four presets the installer refreshes only what it manages (base model,
  system prompt, tool mode, capabilities). Your additions (attached knowledge, tools, access, extra
  parameters, hiding a preset) are kept. The RAG settings (chunking, top-k, web search) are reset to
  the installer's values.
- **Switches are remembered:** `-SkipVision`, `-KeepAlive` and the like apply to later runs too.
  Change one by passing it again; `-ForgetSettings` goes back to the defaults. It does not reset
  `-RenderGuard`, `-ModelDir`, the ports or the trial models: pass those again to change them
  (e.g. `Install-LocalAI.cmd -RenderGuard cpu` turns the render guard back on).

Options are in the config block at the top of `Install-LocalAI.ps1`. The common ones:

| Switch | Effect |
|---|---|
| `-SkipVision`, `-SkipCoder` | Skip the optional ~20 GB models. They're also skipped automatically if disk space is short. Remembered for later runs; `-ForgetSettings` brings them back. |
| `-ModelDir D:\AI\OllamaModels` | Put the models on another drive. This is chosen automatically when C: is short on space. |
| `-Retune` | Re-measure the context sizes after a driver or hardware change. |
| `-NoReboot` | Print "reboot now" instead of rebooting. It still resumes at the next sign-in. |
| `-MaxBusyVramMiB 3500` / `-GpuWaitMinutes 10` | Before loading or tuning models, wait for other GPU apps (ComfyUI, Forge, games) to free VRAM; stop with their names if they don't. |
| `-KeepAlive 5m` | How long an idle model stays in VRAM (default 15m). |
| `-TrialModels trial-fast,trial-gemma4` | Also install newer models as extra **Trial** presets, next to the four measured ones (which stay as they are): `trial-fast` Qwen3.5 9B (6.6 GB), `trial-gemma4` Gemma 4 26B MoE with vision (18 GB), `trial-code27b` Qwen3.6 27B dense (17 GB, slow and careful). Each goes through the same 100%-GPU checkpoint and context tuner. One that can't be pulled, that this Ollama can't load, or that doesn't fit is skipped with a warning. `-TrialModels none` hides them again |
| `-RenderGuard off` | Don't move chats to the CPU while ComfyUI renders (the proxy then just passes requests through). |

## What the installer does (guide part → stage)

| Stage | Guide | What happens and what gets checked |
|---|---|---|
| Preflight | 1-4 | Checks for Windows 10 22H2 or newer, an NVIDIA driver ≥ 551.61 (via `nvidia-smi`), VRAM, virtualization, and disk space per drive. Picks which models fit, creates `C:\AI\...` and `C:\AI\Workspace\{Projects,Scratch,Downloads,Generated}`, and locks down `C:\AI\Secrets` (ACL). |
| Ollama | 5-7 | Installs Ollama (winget, falling back to the signed vendor installer), sets the user environment, restarts the tray app, and confirms from `server.log` that the server picked up flash attention and the q8_0 KV cache. |
| Models | 8-14 | Pulls the 14B first, then the 30B, then the optional models. **Checkpoint:** each one has to load 100% on the GPU and answer a prompt, or the install stops (the guide's "don't continue until `ollama ps` shows GPU"). |
| Tuning | 15, 25-27 | Finds the largest context that keeps each model 100% in VRAM with headroom left over. It then creates a tuned alias (`localai-*`) with that `num_ctx`, sampling parameters and the system prompt built in, and measures tokens/s. |
| WSL | 6 | Turns on the Windows features, installs or updates WSL (no Linux distribution needed), checks WSL ≥ 2.1.5, and caps the WSL VM at 16 GB RAM if you have no `.wslconfig`. |
| Docker | 7 | Installs Docker Desktop (WSL2 backend, licence accepted silently), adds you to `docker-users`, sets it to start at sign-in, waits for the engine, then runs `hello-world`. |
| Stack | 8-9, 18, 26 | Starts Open WebUI, SearXNG and the render guard with docker compose. Versions are pinned, every port is bound to 127.0.0.1, and the volume is the same `open-webui` volume the guide uses. The admin account is created headlessly. It also checks that the container can reach Ollama. |
| Configure | 10-18 | Turns signup off and memories on. Creates the presets **Local Main / Fast / Vision / Code** (system prompt, native tool calling, memory, web search and knowledge tools), hides the raw models, makes Local Main the default, applies the RAG settings (token splitter, 2000/200, top-k 5), sets SearXNG web search, and creates your six knowledge collections. |
| Backup | 22 | Takes a nightly consistent backup with a scheduled task, then runs the first backup and verifies the archive. Also registers `LocalAI-Watch`, a 15-minute health check (see Maintain). |
| Verify | 28 | Runs `Test-LocalAI.ps1`, which executes the "finished V1" checklist for real (details below). |

## Where I deviated from the guide, and why

The numbers below come from the model architectures (Qwen3-30B-A3B: 48 layers, 4 KV heads,
head dim 128; Qwen3-14B: 40 layers, 8 KV heads) and Ollama v0.35.1's source code. The
installer **measures** the real values on your machine and writes them to
`C:\AI\install-report.md`.

Measured on the first real install (RTX 3090, driver 617.14, Windows 11 25H2, about 2.3 GB of VRAM
used by the desktop and open apps):

| Preset | Model | Context (tokens) | VRAM with cache | Generation |
|---|---|---:|---:|---:|
| Local Main | Qwen3 30B-A3B 2507 | 65,536 | 20.6 GiB | **188.5 tok/s** |
| Local Code | Qwen3-Coder 30B-A3B | 65,536 | 20.6 GiB | 178.5 tok/s |
| Local Vision | Qwen3-VL 30B-A3B | 32,768 | 19.2 GiB | 184.8 tok/s |
| Local Fast | Qwen3 14B (dense) | 40,960 (its maximum) | 11.6 GiB | 79 tok/s |

1. **The context is measured, not guessed.** The guide starts the 30B at 8K. The KV cache costs
   2 × 48 × 4 × 128 values per token. That's 96 KiB/token at f16, or about 51 KiB/token with the q8_0 KV cache the
   installer turns on, which is what lets the 30B reach 64K. The tuner tries 64K → 8K and keeps the largest size that is still
   100% on the GPU with at least 768 MiB free. It landed on 64K with 874 MiB to spare, so the margin is thin: a busy
   browser or another GPU app can push it into slow shared memory (see Troubleshooting).
2. **The 14B can't use 64K.** Qwen3-14B was trained to 40,960 positions, and Ollama silently caps
   `num_ctx` there. The guide's "later try 65536" is a no-op, so the tuner caps at 40,960.
3. **"Local Fast" is *not* faster than "Local Main": it is about 2.4× slower.** The 30B-A3B is a mixture of experts
   with about 3.3B parameters active per token; the 14B is dense, with 14.8B active, and generation speed tracks the
   active parameters. My pre-install estimates (90-140 and 50-65 tok/s) were too low on both counts. Fast also reasons
   ("thinks") by default, which delays the first token; the preset turns that off and you can turn it back on per chat.
   Use Fast for its smaller VRAM footprint (11.6 GiB, so it can sit next to a small ComfyUI job) or for step-by-step reasoning.
4. **`num_ctx` is baked into Ollama aliases, not set in Open WebUI.** Open WebUI's background tasks
   (titles, tags, search queries) don't always send the chat's `num_ctx`. When two callers ask for
   different contexts, Ollama reloads the 19 GB model each time. Baking the context into the model means everyone asks for the same size.
5. **Image versions are pinned** (Open WebUI v0.11.4, SearXNG 2026.10.2) instead of `:main`. A moving tag
   can migrate your database on an unplanned restart. `Update-OpenWebUI.ps1 -Latest` updates deliberately, with a backup first.
6. **SearXNG is set up from day one.** It needs no API key and keeps searches private, so there's no provider to choose
   and nothing to sign up for. It's bound to localhost only.
7. **Backups are consistent and versioned.** The guide's command tars a live SQLite database and
   overwrites one file. The script stops the container while the archive is written (seconds to a few minutes), keeps timestamped archives
   (14 days, never fewer than 3), and verifies each one contains `webui.db`.
8. **Privacy and robustness flags.** `OLLAMA_NO_CLOUD=1` (no cloud models or cloud search), `OLLAMA_NUM_PARALLEL=1`
   (the KV cache is allocated per parallel slot), `OLLAMA_GPU_OVERHEAD=512 MiB` (keeps ≤1 GiB free; above that,
   Ollama's automatic default context drops from 32K to 4K), and `OLLAMA_IGPU_ENABLE=0` (never use the Ryzen
   iGPU). Open WebUI telemetry, community sharing and the update check are off, and open signup is disabled.
9. **The raw models are hidden.** The model selector shows just the four presets from the guide's "eventual selector".

## Daily use

- **Local Main** for everything, **Local Vision** when you attach images, **Local Code** for code.
- **Start menu → Local AI:** opens Open WebUI, has *Gaming mode (free GPU)*, *Start again*, *Health check*, *ComfyUI (free GPU first)*, *Diagnostics (redacted zip)* and *Update toolkit*. Each script window stays open until you press Enter, so you can read the result.
- **Before ComfyUI/Forge:** start ComfyUI with `C:\AI\Scripts\Start-ComfyUI.ps1` (add `-CreateShortcut` once for a desktop icon). It unloads Ollama, shows free VRAM and launches Comfy Desktop or the portable build. If ComfyUI is installed somewhere unusual, run it once as `C:\AI\Scripts\Start-ComfyUI.ps1 -Path <...\run_nvidia_gpu.bat or Comfy Desktop.exe>`; the path is remembered. For Forge or anything else, run `C:\AI\Scripts\Release-GPU.ps1`. Ollama keeps the last model in
  VRAM for 15 minutes, and a resident 19 GB model plus Wan 2.2 doesn't fit in 24 GB. On Windows, the
  driver then spills into system RAM instead of failing, so renders slow to a crawl without any error.
- **Chatting during a render (render guard):** Open WebUI reaches Ollama through a small proxy
  container, `render-guard`. While ComfyUI (port 8188 or Comfy Desktop's 8000) has a job running or
  queued, and for 60 s afterwards, chats and Open WebUI's background calls (titles, web-search queries)
  run **on the CPU** (`num_gpu 0`), so the render keeps the GPU. If a render starts while a chat model
  sits idle in VRAM, the model is unloaded. If ComfyUI is idle but still caches models in VRAM, the
  guard asks ComfyUI to free them before a chat loads. Expect roughly 15-25 tok/s for Local Main
  on the CPU, and a slow first token with long web or RAG context. That's an estimate, not measured
  on your PC. Measure it with `C:\AI\Scripts\Test-LocalAI.ps1 -Quick -CpuCheck` (close ComfyUI first; it reports CPU tok/s, prompt speed and the VRAM the CPU mode still takes), and see the guard's decisions in `docker logs render-guard`. Turn it off
  with `C:\AI\Scripts\Install-LocalAI.cmd -RenderGuard off`.
- **Memory vs knowledge:** memory holds durable facts and preferences (Settings → Personalization →
  Memory, or just say "remember that…"). Manuals and PDFs go into **Workspace → Knowledge** collections,
  which you attach in a chat with `#`.
- **Web search** is on by default in each preset. Native tool calling lets the model decide when to search.
- **Terminal:** `ollama run localai-main` gives you the same tuned model and system prompt as the web UI.

## Verify

```powershell
C:\AI\Scripts\Test-LocalAI.ps1          # full: model loads + chat/memory/RAG/web tests (~3-5 min)
C:\AI\Scripts\Test-LocalAI.ps1 -Quick   # config/health only (seconds)
```

Every item on the guide's V1 list is a real test. It checks:
- the GPU and driver
- that both models are installed and 100% on the GPU at their tuned context
- Docker and the containers (Open WebUI, SearXNG, render guard), and that Open WebUI talks to Ollama through the connection the installer set
- that Open WebUI sees the models
- the presets: system prompt and native tool calling
- signup off and memories on
- the RAG and search settings
- a chat through every preset
- that a memory is recalled in a new conversation (it uses a random number, then deletes it)
- that a document is retrieved from a freshly indexed collection (random code, deleted afterwards)
- that a SearXNG search returns results
- that the backup task is scheduled (a newest backup older than about two days is a warning)
- that ports 11434/3000/8888 listen on loopback only

The exit code is the number of failures.

## Maintain

| Task | Command |
|---|---|
| Update Open WebUI | `C:\AI\Scripts\Update-OpenWebUI.ps1 -Latest` (backs up, pulls, recreates the container, runs a quick test). Undo it with `Update-OpenWebUI.ps1 -Rollback` (type YES): previous image plus the data from just before the update, so chats made since the update are lost (a safety copy of them is kept in `C:\AI\Backups`). The newest `before-<version>` backup is never pruned. History in `C:\AI\Logs\update.log`. Re-running the installer keeps the updated version |
| Change the admin password | `C:\AI\Scripts\Set-OpenWebUIPassword.ps1` (random) or `-Prompt` (type your own); updates the secrets file and signs out old sessions |
| Back up now | `C:\AI\Scripts\Backup-OpenWebUI.ps1` (add `-Mirror E:\Backups` or set `-BackupMirror` at install for a second copy) |
| Update models / Ollama | `C:\AI\Scripts\Update-Models.ps1` re-pulls every model and re-tunes only those whose upstream tag changed (`-UpdateOllama` upgrades Ollama first). A model that really changed keeps its previous version as `<tag>-prev`, which costs its size on disk until the next update. Bring it back with `-Rollback main` (or `fast`, `vision`, `code`, `all`), which also pins it so later updates leave it alone until `-Unpin main`. Free the space with `-DropPrevious` |
| Re-tune after a driver/GPU change | Happens by itself on the next re-run when the driver version changed; force it with `C:\AI\Scripts\Install-LocalAI.ps1 -Retune` |
| Add or swap a model | Try newer ones with `-TrialModels` first. To change the catalog for good, edit `config\models.psd1` in a downloaded copy (the copy in `C:\AI\Scripts` is replaced by the next Update toolkit) and run `Install-LocalAI.cmd` from there |
| Health watch | Task `LocalAI-Watch` runs `C:\AI\Scripts\Watch-LocalAI.ps1` every 15 minutes while you're signed in: checks Ollama, the Docker engine, Open WebUI, SearXNG, the render guard, backup freshness and free disk space (models, backups, Docker data; warns under 10 GB), restarts a stopped container or Ollama (never Docker Desktop itself, in case you quit it on purpose), and shows a Windows notification only when a problem persists for two checks in a row (and once when it's fixed). History in `C:\AI\Logs\watch.log`; run it by hand with `-NoHeal -Verbose`; silence it with `-PauseMinutes 240` (gaming, stack stopped on purpose) and `-Unpause` |
| Gaming / long render: free everything | `C:\AI\Scripts\Stop-LocalAI.ps1` unloads the models, stops the containers (data kept) and pauses the health watch for 12 h. Add `-QuitDocker` to also release the WSL VM's RAM (up to 16 GB), or `-QuitOllama`. `Start-LocalAI.ps1` brings it all back and resumes the watch |
| Something's wrong / asking for help | `C:\AI\Scripts\Get-LocalAIDiagnostics.ps1 -RunTests` (or Start menu → Local AI → Diagnostics) writes `C:\AI\Logs\diagnostics-<time>.zip` and copies a short summary to the clipboard. It covers versions, GPU/VRAM, Ollama, containers, logs and test results. The admin password, secret keys, tokens, your Windows user name and the admin e-mail are redacted. Nothing is uploaded |
| Uninstall | Start Docker Desktop first, then `C:\AI\Scripts\Uninstall-LocalAI.ps1` (elevated; `-WhatIf` first to preview; it asks you to type YES). It takes a verified final backup (`...-pre-uninstall.tar.gz`), then removes the scheduled tasks, containers, Tailscale mapping, `localai-*` aliases, the shortcuts, the Start-menu folder and `C:\Program Files\LocalAI`. Chats and models are kept unless you add `-RemoveData` / `-RemoveModels`, and `-ResetOllamaSettings` also drops the OLLAMA_* variables. If the final backup fails, nothing is removed; with Docker not running, `-RemoveData` refuses. The Backups folder is kept, and the final backup is never pruned, even after a reinstall: get your chats back with `Restore-OpenWebUI.ps1 -Archive <that file>` |
| After restoring an older backup | The restore puts this install's Ollama connection back. If the backup had a different admin password, run `Set-OpenWebUIPassword.ps1 -PromptCurrent` (type the old one; it then sets a new random password and prints it, add `-Prompt` to choose your own), then re-run the installer to re-apply presets. `Test-LocalAI.ps1` warns if the connection is wrong |
| Restore a backup | `C:\AI\Scripts\Restore-OpenWebUI.ps1` (newest daily backup) or `-Archive <file>` (local, NAS or UNC path). It takes a verified safety backup first, swaps the data only after the archive checks out, and rolls back automatically if anything fails. If even the rollback fails, Open WebUI is **kept stopped on purpose** so nothing writes to half-restored data: Start again, the installer, updates and nightly backups refuse until you run the recovery command the restore printed (also in the health-watch notification and `C:\AI\open-webui-hold.json`) |

Every nightly backup is also opened with SQLite in a throwaway volume (when the Open WebUI image is on the PC; the restore's own safety copy skips it) (integrity check plus user/chat counts in
`C:\AI\Logs\backup.log`). An archive that fails is kept as `...-CORRUPT.tar.gz`, never replaces a good one, and makes
`Test-LocalAI.ps1` fail so you notice.

Keep a copy of `C:\AI\Secrets` (session key and admin login) in your password manager. It's
deliberately not inside the backup archives.

## Troubleshooting

"Re-run the installer" below means `C:\AI\Scripts\Install-LocalAI.cmd`, with any switch after it, e.g. `C:\AI\Scripts\Install-LocalAI.cmd -RenderGuard off`. To also get the newest toolkit, use **Update toolkit** instead (it keeps your switches' effects).

| Symptom | Likely cause | Fix |
|---|---|---|
| Installer stops: "only N% on the GPU even at 8K" | Another app holds VRAM (ComfyUI, Forge, a game), or the driver/Ollama is stale | Close the GPU apps (or run `Release-GPU.ps1`), quit Ollama from the tray, re-run. Update the driver if it's old. |
| Main runs well under ~150 tok/s (normal is ~188) | The desktop or browser grew its VRAM use, so the driver is spilling into system RAM | Run `Release-GPU.ps1` and close GPU-heavy apps, or re-run with `-Retune`. Optionally set NVIDIA Control Panel → *CUDA - Sysmem Fallback Policy* → *Prefer No Sysmem Fallback* for `ollama.exe` so it fails loudly instead of crawling. Plugging the monitor into the motherboard (the Ryzen iGPU) frees about 0.5-1 GB. |
| ComfyUI OOM or slow right after chatting | An Ollama model is still resident | Run `Release-GPU.ps1`, or install with `-KeepAlive 5m` |
| Open WebUI lists no models | Ollama isn't running | Start Ollama from the Start menu, then run `Test-LocalAI.ps1 -Quick` |
| "Docker engine did not start" | Licence prompt, virtualization off, or WSL broken | Open Docker Desktop once. Enable **SVM Mode** in the BIOS. Run `wsl --update`. Re-run. |
| Web search: "no results" | SearXNG's upstream engines are rate-limiting (captchas) | Retry later. Tune engines in `C:\AI\Stack\searxng\settings.yml`, then `docker restart searxng`. |
| RAG gives a wrong or empty answer | File not processed, collection not attached, or the chunk wasn't retrieved | Check Workspace → Knowledge (processing status). Attach the collection with `#`. Ask with the manual's own wording. |
| Odd answers in Open WebUI but fine in `ollama run localai-main` | A preset or chat parameter was changed in the UI | Re-run the installer to restore its system prompt and tool mode. Your own extra parameters are kept, so remove those in Workspace > Models if they are the cause |
| Ollama tray settings | The new Ollama app's **Expose to network**, **Context length** and **Model location** settings override the environment variables | Leave them at their defaults. The tuned aliases keep their own context either way. |
| Port 3000 or 8888 already in use | Another local service | The installer picks the next free port and records it in `install-report.md` |
| Chat is suddenly slow (CPU speed) | ComfyUI has a job queued or finished less than 60 s ago, so the render guard runs chats on the CPU | Expected. `docker logs render-guard` shows why. Wait for the render, or re-run the installer with `-RenderGuard off` |
| Open WebUI: "render-guard: Ollama ... is not reachable" | Ollama isn't running | Start Ollama from the Start menu. To take the guard out of the path, re-run the installer with `-RenderGuard off` (changing the URL by hand in Admin Settings is undone by the next installer run) |
| Installer interrupted | Power loss, closed window | Run it again. It's idempotent, and tuning results are reused. |
| "Another Local AI installer run or model update is already running" | An installer window (often the Administrator one) or `Update-Models.ps1` is still open | Let it finish or close that window, then try again |
| "Open WebUI is kept stopped after a failed restore" | A restore and its automatic rollback both failed | Run the recovery command shown in the message (also in `C:\AI\open-webui-hold.json`), then Start again |

## Security model (unchanged from the guide's Part 19-26 intent)

- **Conversation is permissive. Execution isn't available.** V1 gives the models no shell, no code interpreter
  and no file write access: those capabilities are turned off in every preset. Shell access (Open
  Terminal in a Docker sandbox, scoped to `C:\AI\Workspace`) is V2 and should keep the guide's
  permission levels A-F.
- **Nothing listens beyond 127.0.0.1**, and `Test-LocalAI.ps1` checks this. For phone access install
  Tailscale, sign in, turn on MagicDNS and HTTPS Certificates at login.tailscale.com/admin/dns, then run
  `C:\AI\Scripts\Enable-TailscaleAccess.ps1`: HTTPS at `https://<this-pc>.<tailnet>.ts.net`, tailnet only, survives
  reboots, nothing opened on the LAN (`-Disable` removes it). Never port-forward or bind to `0.0.0.0`.
- **Your data stays yours.**
  - `C:\AI` is readable only by you, SYSTEM and Administrators. Without this, other Windows accounts
    could read the backups, which hold every chat. Secrets in `C:\AI\Secrets` and
    `C:\AI\Stack\.env` are locked the same way.
  - The bootstrap admin password is removed from the container environment after the first login.
- **No silent admin rights.** No scheduled task runs as administrator.
  - The nightly backup and the health watch run as you.
  - The installer's resume after a reboot starts as you and asks for administrator rights with the
    normal Windows prompt. The installer works on files in `C:\AI`, which you control (you could
    even swap folders in it), so it must never get admin rights without asking.
  - That resume runs a copy in `C:\Program Files\LocalAI`, which only an administrator can change.
  - Members of the `docker-users` group (you) are effectively administrators anyway, because Docker
    can mount any drive. Don't add other accounts to it.
- **If the installer had to open Ollama beyond 127.0.0.1** (only when containers couldn't reach it):
  - The firewall blocks port 11434 from every address except this PC, Docker Desktop
    (192.168.65.0/24) and the WSL/Docker adapter subnets found on this PC. That covers Wi-Fi,
    Ethernet, Tailscale and VPN alike.
  - WSL can pick a new subnet at boot. If chats then stop working, re-run the installer: it
    rebuilds the rule on every run, and Health check flags it.
- **Updates trust this repository.** "Update toolkit" downloads the `main` branch over HTTPS and
  runs it as administrator. Whoever can push to `main` controls what it installs, so keep two-factor
  authentication on the GitHub account. To install a reviewed version instead, set
  `$env:LOCALAI_REF` to a tag or commit before running the command, and replace `refs/heads/main`
  in its URL with the same tag or commit (otherwise the downloader itself still comes from `main`).
  - Ollama and Docker Desktop installers come from winget (hash-checked). The direct-download
    fallback refuses files that aren't signed by Ollama or Docker.
- **Passwords on the command line** end up in PowerShell history. Use `Set-OpenWebUIPassword.ps1 -Prompt`
  rather than `-NewPassword`.
- **Abliterated models** are community modifications: refusal behaviour is removed, but nobody has done release QA on them.
  Spot-check them before relying on them for anything important (guide Part 12).

## How this was tested

`tests/Invoke-IntegrationTest.ps1` runs the portable half of the installer (`lib/LocalAI.psm1`)
against **real** Ollama v0.35.1 and Open WebUI v0.11.4 servers. It covers the context tuner, tuned
aliases, presets, raw-model hiding, admin/RAG/search configuration (run twice, to prove it's
idempotent), knowledge collections, and the chat, memory, RAG and web-search smoke tests. It used a
CPU-only box with a small Qwen3 stand-in model. Running it caught one real bug before shipping:
Open WebUI's settings endpoint resets any web-search field you leave out, which breaks
SearXNG searches. The fix is in `Set-LaiWebUIRetrievalConfig`.

**Not tested in that sandbox:** the Windows-only steps (winget/installer, WSL, Docker Desktop,
scheduled tasks, ACLs, port audit) and real GPU numbers. All scripts are checked with
PSScriptAnalyzer for Windows PowerShell 5.1 syntax compatibility and are ASCII-only. PowerShell 5.1 misreads
non-ASCII characters in scripts saved without a BOM.
