# Local LLM stack for the RTX 3090 rig

A private, self-hosted assistant: low-refusal local models, persistent memory, document
knowledge (RAG), private web search, and nightly backups. It's installed by **one resumable
script** that runs the whole "V1" build and checks every checkpoint along the way.

```
Browser ──> Open WebUI (Docker, 127.0.0.1:3000) ──> Ollama (native Windows, 127.0.0.1:11434) ──> RTX 3090
                 │  memory, knowledge/RAG, presets                ├─ localai-main   Qwen3 30B-A3B 2507 abliterated
                 └─> SearXNG (Docker, 127.0.0.1:8888)             ├─ localai-fast   Qwen3 14B abliterated
                      private metasearch, no API key               ├─ localai-vision Qwen3-VL 30B-A3B abliterated (optional)
                                                                   └─ localai-code   Qwen3-Coder 30B-A3B abliterated (optional)
```

## Run it

Pick one. In each case you get **one UAC prompt**, and then the installer runs unattended.

1. **Double-click** `local-llm\Install-LocalAI.cmd` in a downloaded copy of this repository.
2. **PowerShell**, from the `local-llm` folder:
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-LocalAI.ps1`
3. **No download needed (public repositories only).** This repository is private, so GitHub answers
   anonymous `raw.githubusercontent.com` requests with **404** and the `irm ... | iex` bootstrap
   (`Get-LocalAI.ps1`) will not work. Use option 1 or 2 with a copy you download while signed in:
   https://github.com/MpLLC303/ComfyUi-Optimization/archive/refs/heads/main.zip
   (or `git clone https://github.com/MpLLC303/ComfyUi-Optimization`, which prompts you to sign in).

Expect about 30-90 minutes. Most of that is about 67 GB of model downloads plus the Docker
image. If WSL or Docker needs a reboot, the script warns you 60 seconds ahead (`shutdown /a`
cancels it), reboots, and **continues by itself after you sign in**. You can re-run it at any
time: finished steps are detected and skipped. At the end it opens
http://localhost:3000 and prints the admin login (also saved in
`C:\AI\Secrets\openwebui-admin.json`).

Options are in the config block at the top of `Install-LocalAI.ps1`. The common ones:

| Switch | Effect |
|---|---|
| `-SkipVision`, `-SkipCoder` | Skip the optional ~20 GB models. They're also skipped automatically if disk space is short. |
| `-ModelDir D:\AI\OllamaModels` | Put the models on another drive. This is chosen automatically when C: is short on space. |
| `-Retune` | Re-measure the context sizes after a driver or hardware change. |
| `-NoReboot` | Print "reboot now" instead of rebooting. It still resumes at the next sign-in. |
| `-MaxBusyVramMiB 3500` / `-GpuWaitMinutes 10` | Before loading or tuning models, wait for other GPU apps (ComfyUI, Forge, games) to free VRAM; stop with their names if they don't. |
| `-KeepAlive 5m` | How long an idle model stays in VRAM (default 15m). |

## What the installer does (guide part → stage)

| Stage | Guide | What happens and what gets checked |
|---|---|---|
| Preflight | 1-4 | Checks for Windows 10 22H2 or newer, an NVIDIA driver ≥ 551.61 (via `nvidia-smi`), VRAM, virtualization, and disk space per drive. Picks which models fit, creates `C:\AI\...` and `C:\AI\Workspace\{Projects,Scratch,Downloads,Generated}`, and locks down `C:\AI\Secrets` (ACL). |
| Ollama | 5-7 | Installs Ollama (winget, falling back to the signed vendor installer), sets the user environment, restarts the tray app, and confirms from `server.log` that the server picked up flash attention and the q8_0 KV cache. |
| Models | 8-14 | Pulls the 14B first, then the 30B, then the optional models. **Checkpoint:** each one has to load 100% on the GPU and answer a prompt, or the install stops (the guide's "don't continue until `ollama ps` shows GPU"). |
| Tuning | 15, 25-27 | Finds the largest context that keeps each model 100% in VRAM with headroom left over. It then creates a tuned alias (`localai-*`) with that `num_ctx`, sampling parameters and the system prompt built in, and measures tokens/s. |
| WSL | 6 | Turns on the Windows features, installs or updates WSL (no Linux distribution needed), checks WSL ≥ 2.1.5, and caps the WSL VM at 16 GB RAM if you have no `.wslconfig`. |
| Docker | 7 | Installs Docker Desktop (WSL2 backend, licence accepted silently), adds you to `docker-users`, sets it to start at sign-in, waits for the engine, then runs `hello-world`. |
| Stack | 8-9, 18, 26 | Starts Open WebUI and SearXNG with docker compose. Versions are pinned, every port is bound to 127.0.0.1, and the volume is the same `open-webui` volume the guide uses. The admin account is created headlessly. It also checks that the container can reach Ollama. |
| Configure | 10-18 | Turns signup off and memories on. Creates the presets **Local Main / Fast / Vision / Code** (system prompt, native tool calling, memory, web search and knowledge tools), hides the raw models, makes Local Main the default, applies the RAG settings (token splitter, 2000/200, top-k 5), sets SearXNG web search, and creates your six knowledge collections. |
| Backup | 22 | Takes a nightly consistent backup with a scheduled task, then runs the first backup and verifies the archive. |
| Verify | 28 | Runs `Test-LocalAI.ps1`, which executes the "finished V1" checklist for real (details below). |

## Where I deviated from the guide, and why

The numbers below come from the model architectures (Qwen3-30B-A3B: 48 layers, 4 KV heads,
head dim 128; Qwen3-14B: 40 layers, 8 KV heads) and Ollama v0.35.1's source code. The
installer **measures** the real values on your machine and writes them to
`C:\AI\install-report.md`.

1. **The context is measured, not guessed.** The guide starts the 30B at 8K. The KV cache costs
   2 × 48 × 4 × 128 values per token. That's 96 KiB/token at f16, or about 51 KiB/token with the q8_0 KV cache the
   installer turns on. With roughly 17.3 GiB of weights and about 22.5 GiB of usable VRAM, that leaves room
   for roughly **48K-64K tokens** on the 30B. The tuner tries 64K → 8K and keeps the largest size that is still
   100% on the GPU with at least 768 MiB free. Confidence that 30B lands at ≥32K: high. Confidence that it lands at 64K:
   about 50/50; it depends on how much VRAM your desktop is using.
2. **The 14B can't use 64K.** Qwen3-14B was trained to 40,960 positions, and Ollama silently caps
   `num_ctx` there. The guide's "later try 65536" is a no-op, so the tuner caps at 40,960.
3. **"Local Fast" is probably *not* faster than "Local Main".** The 30B-A3B is a mixture of experts with
   about 3.3B parameters active per token. The 14B is dense, with 14.8B active. Token generation is
   memory-bandwidth bound, so expect about 90-140 tok/s from Main and about 50-65 tok/s from Fast on a 3090
   (estimate ±30%; the installer prints your real numbers). Fast also has reasoning ("thinking") on by default,
   which delays the first token. The installer turns it off in the preset; you can turn it back on per chat. Use Fast
   for its smaller VRAM footprint (it can run next to ComfyUI) or for step-by-step reasoning, not for speed.
4. **`num_ctx` is baked into Ollama aliases, not set in Open WebUI.** Open WebUI's background tasks
   (titles, tags, search queries) don't always send the chat's `num_ctx`. When two callers ask for
   different contexts, Ollama reloads the 19 GB model each time. Baking the context into the model means everyone asks for the same size.
5. **Image versions are pinned** (Open WebUI v0.11.4, SearXNG 2026.10.2) instead of `:main`. A moving tag
   can migrate your database on an unplanned restart. `Update-OpenWebUI.ps1 -Latest` updates deliberately, with a backup first.
6. **SearXNG is set up from day one.** It needs no API key and keeps searches private, so there's no provider to choose
   and nothing to sign up for. It's bound to localhost only.
7. **Backups are consistent and versioned.** The guide's command tars a live SQLite database and
   overwrites one file. The script pauses the container for a few seconds, keeps timestamped archives
   (14 days, never fewer than 3), and verifies each one contains `webui.db`.
8. **Privacy and robustness flags.** `OLLAMA_NO_CLOUD=1` (no cloud models or cloud search), `OLLAMA_NUM_PARALLEL=1`
   (the KV cache is allocated per parallel slot), `OLLAMA_GPU_OVERHEAD=512 MiB` (keeps ≤1 GiB free; above that,
   Ollama's automatic default context drops from 32K to 4K), and `OLLAMA_IGPU_ENABLE=0` (never use the Ryzen
   iGPU). Open WebUI telemetry, community sharing and the update check are off, and open signup is disabled.
9. **The raw models are hidden.** The model selector shows just the four presets from the guide's "eventual selector".

## Daily use

- **Local Main** for everything, **Local Vision** when you attach images, **Local Code** for code.
- **Before ComfyUI/Forge:** start ComfyUI with `C:\AI\Scripts\Start-ComfyUI.ps1` (add `-CreateShortcut` once for a desktop icon). It unloads Ollama, shows free VRAM and launches Comfy Desktop or the portable build. For Forge or anything else, run `C:\AI\Scripts\Release-GPU.ps1`. Ollama keeps the last model in
  VRAM for 15 minutes, and a resident 19 GB model plus Wan 2.2 doesn't fit in 24 GB. On Windows, the
  driver then spills into system RAM instead of failing, so renders slow to a crawl without any error. A chat sent
  during a render reloads the model, so finish chatting first.
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
- Docker and both containers
- that Open WebUI sees the models
- the presets: system prompt and native tool calling
- signup off and memories on
- the RAG and search settings
- a chat through every preset
- that a memory is recalled in a new conversation (it uses a random number, then deletes it)
- that a document is retrieved from a freshly indexed collection (random code, deleted afterwards)
- that a SearXNG search returns results
- that a backup from the last two days exists and the task is scheduled
- that ports 11434/3000/8888 listen on loopback only

The exit code is the number of failures.

## Maintain

| Task | Command |
|---|---|
| Update Open WebUI | `C:\AI\Scripts\Update-OpenWebUI.ps1 -Latest` (backs up, pulls, recreates the container, runs a quick test) |
| Change the admin password | `C:\AI\Scripts\Set-OpenWebUIPassword.ps1` (random) or `-Prompt` (type your own); updates the secrets file and signs out old sessions |
| Back up now | `C:\AI\Scripts\Backup-OpenWebUI.ps1` (add `-Mirror E:\Backups` or set `-BackupMirror` at install for a second copy) |
| Update models / Ollama | `C:\AI\Scripts\Update-Models.ps1` re-pulls every model and re-tunes only those whose upstream tag changed; `-UpdateOllama` upgrades Ollama first |
| Re-tune after a driver/GPU change | `C:\AI\Scripts\Install-LocalAI.ps1 -Retune` |
| Add or swap a model | Edit `config\models.psd1`, then re-run the installer |
| Restore a backup | `C:\AI\Scripts\Restore-OpenWebUI.ps1` (newest daily backup) or `-Archive <file>` (local, NAS or UNC path). It takes a verified safety backup first, swaps the data only after the archive checks out, and rolls back automatically if anything fails |

Keep a copy of `C:\AI\Secrets` (session key and admin login) in your password manager. It's
deliberately not inside the backup archives.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Installer stops: "only N% on the GPU even at 8K" | Another app holds VRAM (ComfyUI, Forge, a game), or the driver/Ollama is stale | Close the GPU apps (or run `Release-GPU.ps1`), quit Ollama from the tray, re-run. Update the driver if it's old. |
| Main runs at well under 45 tok/s | The desktop or browser grew its VRAM use, so the driver is spilling into system RAM | Run `Release-GPU.ps1` and close GPU-heavy apps, or re-run with `-Retune`. Optionally set NVIDIA Control Panel → *CUDA - Sysmem Fallback Policy* → *Prefer No Sysmem Fallback* for `ollama.exe` so it fails loudly instead of crawling. Plugging the monitor into the motherboard (the Ryzen iGPU) frees about 0.5-1 GB. |
| ComfyUI OOM or slow right after chatting | An Ollama model is still resident | Run `Release-GPU.ps1`, or install with `-KeepAlive 5m` |
| Open WebUI lists no models | Ollama isn't running | Start Ollama from the Start menu, then run `Test-LocalAI.ps1 -Quick` |
| "Docker engine did not start" | Licence prompt, virtualization off, or WSL broken | Open Docker Desktop once. Enable **SVM Mode** in the BIOS. Run `wsl --update`. Re-run. |
| Web search: "no results" | SearXNG's upstream engines are rate-limiting (captchas) | Retry later. Tune engines in `C:\AI\Stack\searxng\settings.yml`, then `docker restart searxng`. |
| RAG gives a wrong or empty answer | File not processed, collection not attached, or the chunk wasn't retrieved | Check Workspace → Knowledge (processing status). Attach the collection with `#`. Ask with the manual's own wording. |
| Odd answers in Open WebUI but fine in `ollama run localai-main` | A preset or chat parameter was changed in the UI | Re-run the installer (it resets the presets) |
| Ollama tray settings | The new Ollama app's **Expose to network**, **Context length** and **Model location** settings override the environment variables | Leave them at their defaults. The tuned aliases keep their own context either way. |
| Port 3000 or 8888 already in use | Another local service | The installer picks the next free port and records it in `install-report.md` |
| Installer interrupted | Power loss, closed window | Run it again. It's idempotent, and tuning results are reused. |

## Security model (unchanged from the guide's Part 19-26 intent)

- **Conversation is permissive. Execution isn't available.** V1 gives the models no shell, no code interpreter
  and no file write access: those capabilities are turned off in every preset. Shell access (Open
  Terminal in a Docker sandbox, scoped to `C:\AI\Workspace`) is V2 and should keep the guide's
  permission levels A-F.
- **Nothing listens beyond 127.0.0.1**, and `Test-LocalAI.ps1` checks this. For phone access, use
  `tailscale serve 3000` (HTTPS on your tailnet only) rather than port forwarding or binding to `0.0.0.0`.
- **Secrets** live in `C:\AI\Secrets` and `C:\AI\Stack\.env`, readable only by you, SYSTEM and
  Administrators. The bootstrap admin password is removed from the container environment after
  the first login.
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
