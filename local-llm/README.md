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

**Needs** Windows 10 22H2 or 11 and an NVIDIA GPU with 24 GB of VRAM (RTX 3090/4090). On a
smaller card the installer stops before it downloads anything (a card that holds the two required
models but not Vision or Code just skips those). With no NVIDIA GPU it says what it found instead.
With two NVIDIA GPUs it measures the larger one and says how to keep Ollama on it.

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
  parameters, hiding a preset) are kept, and so are two switches it only sets when it creates a
  preset: **Think** (Local Fast's reasoning) and **Image Generation** (e.g. after you connect
  ComfyUI in Admin Panel > Settings > Images). Code execution stays off. The RAG settings (chunking,
  top-k, web search, image scaling, the fetched-page limit) are reset to the installer's values.
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
| `-RenderGuard off` | Don't move chats to the CPU while ComfyUI renders. The proxy stays in the path: it still relays chats and drops images that a text-only preset can't read. Worth it with two NVIDIA GPUs when ComfyUI is pinned to the other card and Ollama is kept on its own with `CUDA_VISIBLE_DEVICES`. |

## What the installer does (guide part → stage)

| Stage | Guide | What happens and what gets checked |
|---|---|---|
| Preflight | 1-4 | Checks for Windows 10 22H2 or newer, an NVIDIA driver ≥ 551.61 (via `nvidia-smi`), VRAM (a required model that can't load fully on the card stops the install here, before any download), virtualization, RAM, and disk space per drive. Picks which models fit, creates `C:\AI\...` and `C:\AI\Workspace\{Projects,Scratch,Downloads,Generated}`, and locks down `C:\AI\Secrets` (ACL). |
| Ollama | 5-7 | Installs Ollama (winget, falling back to the signed vendor installer; an Ollama already installed in a custom folder with `OllamaSetup.exe /DIR=...` is found and used), sets the user environment, restarts the tray app, and confirms from `server.log` that the server picked up flash attention, the q8_0 KV cache and the planned model folder. If the Ollama app's own **Model location** setting points elsewhere and a model still has to be downloaded, it stops before the download. |
| Models | 8-14 | Pulls the 14B first, then the 30B, then the optional models. **Checkpoint:** each one has to load 100% on the GPU and answer a prompt, or the install stops (the guide's "don't continue until `ollama ps` shows GPU"). |
| Tuning | 15, 25-27 | Finds the largest context that keeps each model 100% in VRAM with headroom left over. It then creates a tuned alias (`localai-*`) with that `num_ctx`, sampling parameters and the system prompt built in, and measures tokens/s. |
| WSL | 6 | Turns on the Windows features, installs or updates WSL (no Linux distribution needed), checks WSL ≥ 2.1.5, and caps the WSL VM at 16 GB RAM if you have no `.wslconfig` (only on PCs with more than 32 GB; smaller PCs keep WSL's own limit of half the RAM, which is lower). |
| Docker | 7 | Installs Docker Desktop (WSL2 backend, licence accepted silently), adds you to `docker-users`, sets it to start at sign-in (a Windows sign-in entry; also tick **Start Docker Desktop when you sign in** in Docker Desktop's Settings > General, because saving its settings with that box clear can remove the entry), waits for the engine, then runs `hello-world`. |
| Stack | 8-9, 18, 26 | Starts Open WebUI, SearXNG and the render guard with docker compose. A container named `searxng` or `render-guard` from another setup (Open WebUI's own SearXNG guide uses that name) stops it before any container is changed; a port that Docker holds for another project's container is skipped like any busy port. Versions are pinned, every port is bound to 127.0.0.1, and the volume is the same `open-webui` volume the guide uses. The admin account is created headlessly. It also checks that the container can reach Ollama. |
| Configure | 10-18 | Turns signup off and memories on. Creates the presets **Local Main / Fast / Vision / Code** (system prompt, native tool calling, memory, web search and knowledge tools), hides the raw models, makes Local Main the default, applies the RAG settings (token splitter, 2000/200, top-k 5), scales attached images to 1920 px, caps a fetched web page at 32,000 characters, sets SearXNG web search, and creates your six knowledge collections. Every setting is read back after it is written: sign-up left on stops the install; a documents/web-search setting or a knowledge collection that did not take is listed under "Settings that need attention" in `install-report.md` (and at the end of the run) instead of stopping the install before backups are scheduled. |
| Backup | 22 | Takes a nightly consistent backup with a scheduled task, then runs the first backup and verifies the archive. Also registers `LocalAI-Watch`, a 15-minute health check (see Maintain). |
| Verify | 28 | Runs `Test-LocalAI.ps1`, which executes the "finished V1" checklist for real (details below). |

## Where I deviated from the guide, and why

The numbers below come from the model architectures (Qwen3-30B-A3B: 48 layers, 4 KV heads,
head dim 128; Qwen3-14B: 40 layers, 8 KV heads) and Ollama v0.35.1's source code. The
installer **measures** the real values on your machine and writes them to
`C:\AI\install-report.md`.

Measured on the first real install (RTX 3090, driver 617.14, Windows 11 25H2, about 2.3 GB of VRAM
used by the desktop and open apps):

| Preset | Model | Context (tokens) | VRAM with cache | Generation (new chat, short prompt) |
|---|---|---:|---:|---:|
| Local Main | Qwen3 30B-A3B 2507 | 65,536 | 20.6 GiB | **188.5 tok/s** |
| Local Code | Qwen3-Coder 30B-A3B | 65,536 | 20.6 GiB | 178.5 tok/s |
| Local Vision | Qwen3-VL 30B-A3B | 32,768 | 19.2 GiB | 184.8 tok/s |
| Local Fast | Qwen3 14B (dense) | 40,960 (its maximum) | 11.6 GiB | 79 tok/s |

The speeds are measured with a short prompt, so the context is nearly empty. Each new token reads
the whole KV cache, so generation slows as a chat grows: expect roughly a fifth slower at about 16K
tokens and a third or more past 32K on the 30B models (estimates from upstream llama.cpp numbers,
not measured here). A long pasted document, RAG result or web page also takes a few seconds of
prompt processing before the first token appears. Both are normal.

1. **The context is measured, not guessed.** The guide starts the 30B at 8K. The KV cache costs
   2 × 48 × 4 × 128 values per token. That's 96 KiB/token at f16, or about 51 KiB/token with the q8_0 KV cache the
   installer turns on, which is what lets the 30B reach 64K. The tuner tries 64K → 8K and keeps the largest size that is still
   100% on the GPU with at least 768 MiB free. It landed on 64K with 874 MiB to spare, so the margin is thin: a busy
   browser or another GPU app can push it into slow shared memory (see Troubleshooting). The fit was measured on
   Ollama 0.35.1, and the Ollama app installs its own updates at sign-in (its *Auto-download updates* setting, on by
   default). A new version can place layers differently, so the health watch shows a notification once and the Health
   check warns until `Update-Models.ps1` has checked every preset on the GPU again. Turn that setting off if you would
   rather update Ollama yourself with `Update-Models.ps1 -UpdateOllama`, which re-checks in the same run.
2. **The 14B can't use 64K.** Qwen3-14B was trained to 40,960 positions, and Ollama silently caps
   `num_ctx` there. The guide's "later try 65536" is a no-op, so the tuner caps at 40,960.
3. **"Local Fast" is *not* faster than "Local Main": it is about 2.4× slower.** The 30B-A3B is a mixture of experts
   with about 3.3B parameters active per token; the 14B is dense, with 14.8B active, and generation speed tracks the
   active parameters. My pre-install estimates (90-140 and 50-65 tok/s) were too low on both counts. Fast also reasons
   ("thinks") by default, which delays the first token, so the preset turns that off. Open WebUI 0.11.4 applies the
   preset's Think setting over the per-chat Chat Controls switch, so that switch cannot turn it back on. For
   step-by-step reasoning set **Think (Ollama)** to On in Workspace > Models > Local Fast > Advanced Params; re-runs keep it.
   Use Fast for its smaller VRAM footprint (11.6 GiB, so it can sit next to a small ComfyUI job) or for step-by-step reasoning.
4. **`num_ctx` is baked into Ollama aliases, not set in Open WebUI.** Open WebUI's background tasks
   (titles, tags, search queries) don't always send the chat's `num_ctx`. When two callers ask for
   different contexts, Ollama reloads the 19 GB model each time. Baking the context into the model means everyone asks for the same size.
   So leave **Context Length** (and Batch Size) at Default everywhere in Open WebUI: Settings > General > Advanced
   Parameters, Admin Panel > Settings > Models (default parameters), a preset's Advanced Params and a chat's Controls.
   A value there wins over the tuned alias; the installer report and `Test-LocalAI.ps1` warn about the first three.
5. **Image versions are pinned** (Open WebUI v0.11.4, SearXNG 2026.10.2) instead of `:main`. A moving tag
   can migrate your database on an unplanned restart. `Update-OpenWebUI.ps1 -Latest` updates deliberately, with a backup first.
6. **SearXNG is set up from day one.** It needs no API key and keeps searches private, so there's no provider to choose
   and nothing to sign up for. It's bound to localhost only.
7. **Backups are consistent and versioned.** The guide's command tars a live SQLite database and
   overwrites one file. The script stops the container while the archive is written (seconds to a few minutes), keeps timestamped archives
   (14 days, never fewer than 3), and verifies each one contains `webui.db`. The PC is not woken for the 03:30 run: a night
   missed while it was off, asleep or signed out is caught up after it wakes or at the next sign-in, and that run first
   waits (up to 10 minutes) for a chat answer that is still being written, so it does not cut one off.
8. **Privacy and robustness flags.** `OLLAMA_NO_CLOUD=1` (no cloud models or cloud search), `OLLAMA_NUM_PARALLEL=1`
   (the KV cache is allocated per parallel slot), `OLLAMA_GPU_OVERHEAD=512 MiB` (since Ollama 0.35 hands placement to
   its llama-server runner, this reserves no VRAM; it only lowers the figure Ollama picks its automatic default
   context from, which drops from 32K to 4K above 1 GiB. The real desktop margin is the tuner's `-MinFreeVramMiB`, 768 MiB),
   and `OLLAMA_IGPU_ENABLE=0` (never use the Ryzen
   iGPU). Open WebUI telemetry, community sharing and the update check are off, and open signup is disabled.
9. **The raw models are hidden.** The model selector shows just the four presets from the guide's "eventual selector".

## Daily use

- **Local Main** for everything, **Local Vision** when you attach images, **Local Code** for code.
- **Once a chat has an image, keep that chat on Local Vision** (it handles text and code too) or
  start a new chat for the other presets. Open WebUI sends every earlier image again with each
  message, and Main, Fast and Code can't take images. The render guard drops them for those presets
  and leaves a note in the message ("image omitted"), so the chat keeps working, but the model can't
  see the screenshot any more. Only what Local Vision already wrote about it stays in the chat.
- **Start menu → Local AI:** opens Open WebUI, has *Gaming mode (free GPU)*, *Start again*, *Health check*, *ComfyUI (free GPU first)*, *Diagnostics (redacted zip)* and *Update toolkit*. Each script window stays open until you press Enter, so you can read the result.
- **Before ComfyUI/Forge:** start ComfyUI with `C:\AI\Scripts\Start-ComfyUI.ps1` (add `-CreateShortcut` once for a desktop icon). It unloads Ollama, shows free VRAM and launches Comfy Desktop or the portable build. If ComfyUI is installed somewhere unusual, run it once as `C:\AI\Scripts\Start-ComfyUI.ps1 -Path <...\run_nvidia_gpu.bat or Comfy Desktop.exe>`; the path is remembered. For Forge or anything else, run `C:\AI\Scripts\Release-GPU.ps1`. Ollama keeps the last model in
  VRAM for 15 minutes, and a resident 19 GB model plus Wan 2.2 doesn't fit in 24 GB. On Windows, the
  driver then spills into system RAM instead of failing, so renders slow to a crawl without any error.
- **Chatting during a render (render guard):** Open WebUI reaches Ollama through a small proxy
  container, `render-guard`. While ComfyUI (port 8188 or Comfy Desktop's 8000) has a job running or
  queued, and for 60 s afterwards, chats and Open WebUI's background calls (titles, web-search queries)
  run **on the CPU** (`num_gpu 0`), so the render keeps the GPU. After that 60 s the guard unloads
  the CPU copy (Ollama would otherwise keep reusing it for as long as you keep chatting), so the
  next chat loads onto the GPU again (that first answer waits a few seconds for the load). If a
  render starts while a chat model sits idle in VRAM, the model is unloaded. If ComfyUI is idle but
  still caches models in VRAM, the guard asks ComfyUI to free them before a chat loads. If something
  answers on 8188/8000 but the guard can't read a ComfyUI queue there, `docker logs render-guard`
  says so once and chats stay on the GPU. Expect roughly 15-25 tok/s for Local Main
  on the CPU, and a slow first token with long web or RAG context. That's an estimate, not measured
  on your PC. Measure it with `C:\AI\Scripts\Test-LocalAI.ps1 -Quick -CpuCheck` (close ComfyUI first; it reports CPU tok/s, prompt speed and the VRAM the CPU mode still takes), and see the guard's decisions in `docker logs render-guard`.
  On the CPU the whole model sits in RAM: a preset needs about its download size plus 12 GB of RAM
  (Local Main about 31 GB). On a PC with less, the installer warns which presets would page to
  disk during a render (and slow the render too); wait for the render before chatting with those. Turn it off
  with `C:\AI\Scripts\Install-LocalAI.cmd -RenderGuard off` (the image fix above stays on).
- **Memory vs knowledge:** memory holds durable facts and preferences (Settings → Personalization →
  Memory, or just say "remember that…"). Manuals and PDFs go into **Workspace → Knowledge** collections,
  which you attach in a chat with `#`.
- **Web search** is on by default in each preset. Native tool calling lets the model decide when to search.
  A page or PDF the model opens is cut to 32,000 characters (about 8K tokens), so one long page can't
  fill the context.
- **Context limits:** each preset holds its tuned context (table above). When a chat outgrows it,
  Ollama drops the oldest messages without telling you, so answers start ignoring the beginning of
  the chat. Start a new chat for a new topic, and use Local Main (65K) for long documents.
- **Images:** the browser scales an attached image to fit 1920 x 1920 before sending it (1080p
  screenshots stay as they are). Each image costs Local Vision about 1,000-2,700 of its 32K tokens,
  and every image in a chat is sent again with each message. After roughly ten images Vision answers
  "exceeds the available context size" or stops mid-sentence: start a new chat (don't raise the
  context; 32K is what fits in VRAM next to the image encoder).
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
- the presets: system prompt, native tool calling, and image upload only where Ollama says the model reads images
- that no Context Length set in Open WebUI overrides the tuned aliases (your settings, the default parameters, the presets)
- signup off and memories on
- the RAG and search settings (including image scaling and the fetched-page limit)
- a chat through every preset, and for Local Vision an image whose colour it must name
- that a memory is recalled in a new conversation (it uses a random number, then deletes it)
- that a document is retrieved from a freshly indexed collection (random code, deleted afterwards)
- that a SearXNG search returns results
- that the backup task is scheduled (a newest backup older than about two days is a warning)
- that ports 11434/3000/8888 listen on loopback only

The exit code is the number of failures.

## Maintain

| Task | Command |
|---|---|
| Update SearXNG | `C:\AI\Scripts\Update-OpenWebUI.ps1 -SearxngVersion <tag>` (a tag from hub.docker.com/r/searxng/searxng/tags; newer tags bring fixed search-engine scrapers). The render guard runs on the same image, and the quick test afterwards checks both, plus one real search. SearXNG keeps no data, so the way back is the same command with the old tag, which the update prints and writes to `C:\AI\Logs\update.log`. `-Rollback` only undoes Open WebUI updates |
| Update Open WebUI | `C:\AI\Scripts\Update-OpenWebUI.ps1 -Latest` (backs up, pulls, recreates the container, runs a quick test). Undo it with `Update-OpenWebUI.ps1 -Rollback` (type YES): previous image plus the data from just before the update, so chats made since the update are lost (a safety copy of them is kept in `C:\AI\Backups`). The newest `before-<version>` backup is never pruned. After a successful update, older Open WebUI images are removed (the running one and the one `-Rollback` needs stay), so Docker's disk does not grow by several GB per update. History in `C:\AI\Logs\update.log`. Re-running the installer keeps the updated version |
| Change the admin password | `C:\AI\Scripts\Set-OpenWebUIPassword.ps1` (random) or `-Prompt` (type your own); updates the secrets file and signs out old sessions |
| Back up now | `C:\AI\Scripts\Backup-OpenWebUI.ps1` (add `-Mirror E:\Backups` or set `-BackupMirror` at install for a second copy) |
| Update models / Ollama | `C:\AI\Scripts\Update-Models.ps1` re-pulls every model and re-tunes only those whose upstream tag changed (`-UpdateOllama` upgrades Ollama first). A model that really changed keeps its previous version as `<tag>-prev`, which costs its size on disk until the next update. Bring it back with `-Rollback main` (or `fast`, `vision`, `code`, `all`), which also pins it so later updates leave it alone until `-Unpin main`. Free the space with `-DropPrevious`. A model whose new download cannot be loaded at all is left as it was (its preset keeps the version it was tuned on); the run says why and ends with an error, and the next run tries again |
| Re-tune after a driver/GPU change | Happens by itself on the next re-run when the driver version changed; force it with `C:\AI\Scripts\Install-LocalAI.ps1 -Retune` |
| Add or swap a model | Try newer ones with `-TrialModels` first. To change the catalog for good, edit `config\models.psd1` in a downloaded copy (the copy in `C:\AI\Scripts` is replaced by the next Update toolkit) and run `Install-LocalAI.cmd` from there |
| Health watch | Task `LocalAI-Watch` runs `C:\AI\Scripts\Watch-LocalAI.ps1` every 15 minutes while you're signed in: checks Ollama, the Docker engine (one that stopped answering, as Docker Desktop can after sleep, is reported instead of hanging the check), Open WebUI, SearXNG, the render guard, whether Open WebUI can actually reach Ollama (the path chats take), backup freshness, the backup mirror (when you set one) and free disk space (models, backups, Docker data; warns under 10 GB), restarts a stopped container or Ollama (never Docker Desktop itself, in case you quit it on purpose), and shows a Windows notification only when a problem persists for two checks in a row, again every 24 hours while it lasts, and once when it's fixed. It also notifies once when Ollama has updated itself since the presets were tuned (run `Update-Models.ps1` then). History in `C:\AI\Logs\watch.log`; run it by hand with `-NoHeal -Verbose`; silence it with `-PauseMinutes 240` (gaming, stack stopped on purpose) and `-Unpause` |
| Gaming / long render: free everything | `C:\AI\Scripts\Stop-LocalAI.ps1` unloads the models, stops the containers (data kept) and pauses the health watch for 12 h. Add `-QuitDocker` to also release the WSL VM's RAM (up to 16 GB), or `-QuitOllama`. `Start-LocalAI.ps1` brings it all back and resumes the watch |
| Something's wrong / asking for help | `C:\AI\Scripts\Get-LocalAIDiagnostics.ps1 -RunTests` (or Start menu → Local AI → Diagnostics) writes `C:\AI\Logs\diagnostics-<time>.zip` and copies a short summary to the clipboard. It covers versions, GPU/VRAM, Ollama, containers, logs and test results. The admin password, secret keys, tokens, your Windows user name and the admin e-mail are redacted. Nothing is uploaded. The last run of each Start-menu shortcut (Gaming mode, Start again, Health check, ComfyUI) is kept in `C:\AI\Logs\shortcut-<script>.log` and included, so an error from a window you already closed can still be read |
| Uninstall | Start Docker Desktop first, then `C:\AI\Scripts\Uninstall-LocalAI.ps1` (elevated; `-WhatIf` first to preview; it asks you to type YES). It takes a verified final backup (`...-pre-uninstall.tar.gz`), then removes the scheduled tasks, containers, Tailscale mapping, `localai-*` aliases, the shortcuts, the Start-menu folder and `C:\Program Files\LocalAI`. Chats and models are kept unless you add `-RemoveData` / `-RemoveModels`, and `-ResetOllamaSettings` also drops the OLLAMA_* variables (a value you had set yourself before the install, e.g. `OLLAMA_NUM_PARALLEL=4` for another tool, is put back instead; the first install logs each one it finds, and installs from before this toolkit version only remove). If the final backup fails, nothing is removed; with Docker not running, `-RemoveData` refuses. The Backups folder is kept, and the final backup is never pruned, even after a reinstall: get your chats back with `Restore-OpenWebUI.ps1 -Archive <that file>` |
| After restoring an older backup | The restore puts this install's Ollama connection back. If the backup had a different admin password, run `Set-OpenWebUIPassword.ps1 -PromptCurrent` (type the old one; it then sets a new random password and prints it, add `-Prompt` to choose your own), then re-run the installer to re-apply presets. `Test-LocalAI.ps1` warns if the connection is wrong |
| Restore a backup | `C:\AI\Scripts\Restore-OpenWebUI.ps1` (newest daily backup) or `-Archive <file>` (local, NAS or UNC path). It takes a verified safety backup first, swaps the data only after the archive checks out, and rolls back automatically if anything fails. If even the rollback fails, Open WebUI is **kept stopped on purpose** so nothing writes to half-restored data: Start again, the installer, updates and nightly backups refuse until you run the recovery command the restore printed (also in the health-watch notification and `C:\AI\open-webui-hold.json`) |

Every nightly backup is also opened with SQLite in a throwaway volume (with the Open WebUI image named in `C:\AI\Stack\.env`, or the one running if that is not on the PC; when neither is there the check is skipped and counted, and the health watch reports 3 such nights in a row; the restore's own safety copy skips it) (integrity check plus user/chat counts in
`C:\AI\Logs\backup.log`). An archive that fails is kept as `...-CORRUPT.tar.gz`, never replaces a good one, and makes
`Test-LocalAI.ps1` fail so you notice.

Keep a copy of `C:\AI\Secrets` (session key and admin login) in your password manager. It's
deliberately not inside the backup archives.

## Troubleshooting

"Re-run the installer" below means `C:\AI\Scripts\Install-LocalAI.cmd`, with any switch after it, e.g. `C:\AI\Scripts\Install-LocalAI.cmd -RenderGuard off`. To also get the newest toolkit, use **Update toolkit** instead (it keeps your switches' effects).

| Symptom | Likely cause | Fix |
|---|---|---|
| Installer stops: "only N% on the GPU even at 8K" | Another app holds VRAM (ComfyUI, Forge, a game), or the driver/Ollama is stale | Close the GPU apps (or run `Release-GPU.ps1`), quit Ollama from the tray, re-run. Update the driver if it's old. For Vision or Code you can also leave the model out with `-SkipVision` / `-SkipCoder`. |
| Installer stops: "cannot load fully on this ... sized for a 24 GB NVIDIA card" | The card has less than 24 GB of VRAM | Nothing was downloaded. The models need a 24 GB card (RTX 3090/4090); for a smaller one, edit the catalog (Maintain > Add or swap a model). |
| Installer stops: "No NVIDIA GPU found" | An AMD or Intel GPU, or an ARM PC | This toolkit needs an NVIDIA GPU with 24 GB of VRAM. |
| Installer stops: "Settings > Model location overrides the OLLAMA_MODELS variable" | The Ollama app saved its own model folder (it does so once its window has been opened) and starts the server with it | Open the Ollama app > Settings, set **Model location** to the folder the message names (or re-run with `-ModelDir` set to the app's folder), quit Ollama from the tray, re-run. |
| Installer stops: "A container named searxng from another setup" | Open WebUI and SearXNG installed by hand from Open WebUI's guides | Nothing was changed. `docker rename searxng searxng-old` (stop it first if it uses port 8888), re-run: the installer then moves your Open WebUI data into its own stack. |
| Main runs well under ~150 tok/s in a new, short chat (normal is ~188) | The desktop or browser grew its VRAM use, so the driver is spilling into system RAM | First run `C:\AI\Scripts\Test-LocalAI.ps1`: its speed check uses a short prompt, so a warning there means spilling, not a long chat. Then run `Release-GPU.ps1` and close GPU-heavy apps, or re-run with `-Retune`. If Ollama updated itself recently, run `Update-Models.ps1` first: it re-checks every preset on the new version. Optionally set NVIDIA Control Panel → *CUDA - Sysmem Fallback Policy* → *Prefer No Sysmem Fallback* for `%LOCALAPPDATA%\Programs\Ollama\lib\ollama\llama-server.exe` so it fails loudly instead of crawling. That is the process holding the model in VRAM (Task Manager and `nvidia-smi` show it); a setting for `ollama.exe` has no effect since Ollama 0.35. Check the name again after an Ollama update. Plugging the monitor into the motherboard (the Ryzen iGPU) frees about 0.5-1 GB. |
| A long chat gets slower (e.g. ~120-140 tok/s past 32K tokens) | Expected: every new token reads the whole KV cache, which grows with the chat | Nothing to fix. Start a new chat for a new topic |
| Model reloads (pause of several seconds) on every message, or one preset is slow while `Test-LocalAI.ps1` passes | A Context Length set in Open WebUI overrides the tuned alias | `Test-LocalAI.ps1` names the place (check "Context decided by the tuned aliases"); set it back to Default there. A chat's own Controls can't be checked: look there too |
| Local Vision: "exceeds the available context size", or answers stop mid-sentence | The chat's images (each sent again with every message) plus the text no longer fit in Vision's 32K | Start a new chat, with fewer images per chat |
| ComfyUI OOM or slow right after chatting | An Ollama model is still resident | Run `Release-GPU.ps1`, or install with `-KeepAlive 5m` |
| Open WebUI lists no models | Ollama isn't running | Start Ollama from the Start menu, then run `Test-LocalAI.ps1 -Quick` |
| "Docker engine did not start" | Licence prompt, virtualization off, or WSL broken | Open Docker Desktop once. Enable virtualization in the BIOS (**SVM Mode** on AMD, **Intel Virtualization Technology / VT-x** on Intel). Run `wsl --update`. Re-run. |
| Web search: "no results" | The sites SearXNG asks (DuckDuckGo, Brave, Google CSE by default) are rate-limiting this PC, or one changed its pages so the pinned SearXNG cannot read them | Run the Health check: its *SearXNG search* line names each engine and its reason. *CAPTCHA* or *too many requests*: wait a few minutes to an hour. *HTTP error* or *server API error*: the site answered but refused; wait, and if it lasts try a newer SearXNG. *parsing error*: only a newer SearXNG fixes it, see Update SearXNG under Maintain. If that line finds results but Open WebUI's search does not, Open WebUI could not load the pages: check Admin Settings > Web Search (web loader, SSL verification) and `docker logs --tail 50 open-webui`. Details: `docker logs --tail 50 searxng`. |
| RAG gives a wrong or empty answer | File not processed, collection not attached, or the chunk wasn't retrieved | Check Workspace → Knowledge (processing status). Attach the collection with `#`. Ask with the manual's own wording. |
| A scanned PDF fails with "The content provided is empty", or values printed inside pictures are never found | Open WebUI reads only a PDF's text layer by default | Turn on Admin Panel > Settings > Documents > **PDF Extract Images (OCR)** (re-runs keep it; OCR runs on the CPU and makes indexing slower), then upload the PDF again. For a page or two, a screenshot in a Local Vision chat also works |
| Odd answers in Open WebUI but fine in `ollama run localai-main` | A preset or chat parameter was changed in the UI | Re-run the installer to restore its system prompt and tool mode. Your own extra parameters are kept, so remove those in Workspace > Models if they are the cause |
| Ollama tray settings | The new Ollama app's **Expose to network**, **Context length** and **Model location** settings override the environment variables. Model location is saved as soon as the app's window is used, so it then stays on the folder of that time | Leave Expose off (the installer warns, and Health check fails, when Ollama listens beyond 127.0.0.1). After changing `-ModelDir`, set Model location in the app to the same folder (the installer stops if they differ and a model still has to be downloaded). The tuned aliases keep their own context either way. |
| Port 3000 or 8888 already in use | Another local service, or another project's Docker container | The installer picks the next free port and records it in `install-report.md` |
| Chat is suddenly slow (CPU speed) | ComfyUI has a job queued or finished less than 60 s ago, so the render guard runs chats on the CPU. Afterwards the guard unloads the CPU copy, so the next chat after that loads onto the GPU again | Expected. `docker logs render-guard` shows why ("runs on the CPU", then "unloaded the CPU copy"). Wait for the render, or re-run the installer with `-RenderGuard off`. Still slow a minute after the render: run `C:\AI\Scripts\Release-GPU.ps1` and send the message again |
| A chat answers "image omitted", or fails with "does not support multimodal requests" | The chat has an image from Local Vision and you switched it to Main, Fast or Code. The render guard drops such images (without it, every message in that chat fails) | Switch that chat back to Local Vision, or start a new chat |
| Open WebUI: "render-guard: Ollama ... is not reachable" | Ollama isn't running (the guard only relays the error) | Start Ollama from the Start menu, then send the message again. `-RenderGuard off` does not help here: it only stops the CPU routing, and chats still go through the guard (changing the URL by hand in Admin Settings is undone by the next installer run) |
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
  - While it runs as administrator, the installer refuses to work through a junction or symbolic
    link in `C:\AI` (it stops with a message), deletes folders there without following links, and
    downloads the Ollama/Docker installers into an administrators-only folder before checking
    their signature and running them.
  - Like any installer, the first run trusts the copy you downloaded: it runs from your user
    folders, so anything already running as you could have changed it before you clicked Yes.
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
