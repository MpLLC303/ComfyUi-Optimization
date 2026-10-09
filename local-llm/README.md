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

It downloads the newest toolkit to your temp folder and asks Windows for administrator rights:
**one UAC prompt**. The step that has those rights copies the download into a folder under Program
Files that only administrators can change, unpacks it there and starts the installer from that
folder. Then everything runs unattended in the new Administrator window (one more prompt after
each reboot it needs). Started from a Windows PowerShell window that already has administrator
rights, the installer runs in that window instead. The one exception: if Open WebUI already has an admin account
the installer doesn't know, it asks once for that account's e-mail and password. Only one installer
run (or model update) can run at a time; a second one says so and stops.

The admin password it creates is shown once, at the end of the run that finishes the install, and
kept in `C:\AI\Secrets\openwebui-admin.json`. Later runs only say where it is, so a screenshot or
a pasted log of an update does not give it away.

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
The everyday ones (Open WebUI, Gaming mode, Start again, Health check, Re-check models, ComfyUI,
Diagnostics, Update toolkit) have Start-menu shortcuts under **Local AI**; run the rest from `C:\AI\Scripts`. Every
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
- **What runs:** the window shows the toolkit version and the exact commit before Windows asks for
  administrator rights, and that commit is what gets installed (a re-run after a failure, or the
  resume after a restart, installs the same code). An older toolkit refuses to run over a newer
  install (`-AllowDowngrade` if you really mean to go back).
- **You see what changes before anything is downloaded:** when Local AI is already installed, the
  update first shows the version and commit installed now, the commit about to be installed (id,
  date, subject line) and the files that differ between the two, the scripts that run as
  administrator first. It goes on only after you type `OK` at the keyboard. Anything else, or a
  window without a keyboard, stops with nothing downloaded or changed. A first install has nothing
  to compare and is not asked. The list names the files, not what changed inside them: the review
  prints the address of the full comparison for that.
  - *When GitHub's API does not answer* (its hourly limit, a proxy), the commit is read from its
    page on github.com instead and shown, with the file list said to be missing. The update then
    stops before the question: the list of the commit's files, which the download is compared
    with (*What is installed* below), comes from the API alone. Try again later. Setting `$env:LOCALAI_REF` to a
    full commit id names the commit without GitHub, but not the files it holds, so it does not
    get an update past this either.
  - *For a run nobody watches,* set `$env:LOCALAI_REVIEWED_COMMIT` to the full 40-character id of
    the commit you reviewed. It counts for exactly that commit: when the branch has moved on, the
    question is asked as usual, and without a typed OK nothing is installed. Such a run has nobody
    to click Yes at the prompt of Windows either: start it from Windows PowerShell with
    administrator rights.
  - `$env:LOCALAI_REF` may name a branch, a tag or a commit id (4 or more hex characters count as
    an id). A commit id is not checked to be on a branch of this repository, and the review says so.
  - The first update that brings this review is not reviewed when you start it from the Start
    menu, because that shortcut runs the copy already on the PC. The one-liner fetches the new
    copy and reviews at once.
- **What is installed is the commit that was shown:** the download is asked for by that commit's
  full id and compared with the list of files GitHub's API gives for that commit: every file under
  `local-llm`, no file more and none less. A download that differs is refused and nothing is
  installed; without that list an update stops, it is never installed unchecked. The step with
  administrator rights compares its own copy again in its folder under Program Files, so a download
  swapped in your temp folder in between is refused too, and it removes that folder at the end. A
  first install was not reviewed: it says that its download cannot be compared with a reviewed
  commit, and goes on. The first window removes the two files it put in your temp folder once the
  Administrator window has read them. When it cannot tell (that window did not answer in the time
  it waits, or this window could not make the signal that window answers with), it leaves them,
  says which of the two it was, and the next run removes them.
- **A backup comes first:** before the update changes anything, the chats are backed up, once per
  toolkit version and commit
  (`C:\AI\Backups\open-webui-<time>-before-toolkit-<version>-<commit>.tar.gz`, with the first 7
  characters of the commit, or the day as `yyyyMMdd` for a ZIP unpacked by hand, which names no
  commit; `Restore-OpenWebUI.ps1 -Archive <that file>` goes back to it).
- **Options with the one-liner:** set them first, e.g. `$env:LOCALAI_ARGS = '-OfficialModels none'`, then
  paste the command. Plain options only (no quotes).
- **The first update that brings the official models** (about 42 GB) says so and waits 20 seconds, so you
  can close the window and run it again with `-OfficialModels none`. Windows will not go to sleep while
  the installer runs. If the stored Open WebUI admin login no longer works, it asks for it at the start,
  not after the downloads.
- **Open WebUI:** it restarts briefly for the backup step.
- **Your settings:** on the presets the installer refreshes only what it manages (base model,
  system prompt, tool mode, capabilities and the 16 switches for Open WebUI's built-in tools). Your
  additions (attached knowledge, attached tools, access, extra parameters, hiding a preset) are
  kept, and so are four switches it only sets when it creates a preset: **Think** (Uncensored
  Fast's reasoning), **Image Generation** (e.g. after you connect ComfyUI in
  Admin Panel > Settings > Images), and the two built-in tools that only ask you a question or
  read the files of the chat. Every other built-in tool switch is put back on every run: code
  execution and past-chat search stay off, and so do the note, task, automation, calendar,
  notification, channel and sub-agent tools, also after you switched one on, and also on a
  toolkit preset that is still in Open WebUI although you no longer have it selected (see
  *Security model*). The RAG settings (chunking, top-k, web search, image scaling, the fetched-page limit)
  are reset to the installer's values.
- **Document search models:** the embedder and reranker (roughly 7 GB together: Open WebUI fetches
  each model's whole repository) download into Open WebUI's data folder on the first run that sets
  them, which takes a few minutes; they are left out of the backups (they download again after a
  restore). Re-indexing existing collections for the new embedder runs once and can take a while
  for large ones. If either step fails, the install report says so and documents keep working
  with the old model.
- **Switches are remembered:** `-SkipVision`, `-KeepAlive` and the like apply to later runs too.
  Change one by passing it again; `-ForgetSettings` goes back to the defaults. It does not reset
  `-RenderGuard`, `-ModelDir`, the ports or the trial models: pass those again to change them
  (e.g. `Install-LocalAI.cmd -RenderGuard cpu` turns the render guard back on).

Options are in the config block at the top of `Install-LocalAI.ps1`. The common ones:

| Switch | Effect |
|---|---|
| `-SkipVision`, `-SkipCoder` | Skip the optional ~20 GB models. They're also skipped automatically if disk space is short. Remembered for later runs; `-ForgetSettings` brings them back. |
| `-ModelDir D:\AI\OllamaModels` | Put the models on another drive. This is chosen automatically when C: is short on space. A later run with another folder is refused while the folder Ollama uses now still holds models (going on would download every model again and leave the old copy where it is). To move them: quit Ollama from its tray icon, move everything in the old folder into the new one, and run the installer again with `-ModelDir` set to the new folder; the refusal prints both ways out with the real folder names. `-ModelDir` set to Ollama's own default folder (`.ollama\models` in your user folder) goes back to it and removes the `OLLAMA_MODELS` variable the installer had set. An `OLLAMA_MODELS` you set yourself, or a system-wide one, is never removed. In most cases the installer says so, and tells you to remove it first when it would keep Ollama on the other folder. Not in two cases, both still open (IMPROVEMENTS.md, row 151): with a system-wide variable under the installer's own one, a missing model can still be downloaded to the default folder, which an Ollama you start yourself then does not read; and on a PC where the installer's Ollama step has never finished, the move can be offered without the advice to remove the variable first. |
| `-Retune` | Re-measure the context sizes after a driver or hardware change. |
| `-NoReboot` | Print "reboot now" instead of rebooting. It still resumes at the next sign-in. |
| `-MaxBusyVramMiB 3500` / `-GpuWaitMinutes 10` | Before loading or tuning models, wait for other GPU apps (ComfyUI, Forge, games) to free VRAM; stop with their names if they don't. |
| `-KeepAlive 5m` | How long an idle model stays in VRAM (default 15m). |
| `-TrialModels trial-fast,trial-gemma4` | Also install newer models as extra **Trial** presets, next to the four measured ones (which stay as they are): `trial-fast` Qwen3.5 9B (6.6 GB), `trial-gemma4` Gemma 4 26B MoE with vision (18 GB), `trial-code27b` Qwen3.6 27B dense (17 GB, slow and careful), `trial-research` Tongyi DeepResearch 30B-A3B abliterated (19 GB, trained for long web research; with `-DeepResearch` the research agent uses it). Each goes through the same 100%-GPU checkpoint and context tuner. One that can't be pulled, that this Ollama can't load, or that doesn't fit is skipped with a warning. `-TrialModels none` hides them again |
| `-DeepResearch` | Adds the optional **deep research** agent at `http://localhost:5055` (Start menu → Local AI → *Deep Research*; see Daily use). About 1 GB to download, about 4 GB on disk. Free: it searches only through your private SearXNG, with no search API or key. `-NoDeepResearch` removes it again (your saved research stays in its data volume). `-DeepResearchPort 5056` picks another loopback port |
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
| Configure | 10-18 | Turns signup off and memories on. Creates the presets **Official Main / Deep / Fast** and **Uncensored Main / Fast / Vision / Code** (system prompt, native tool calling, memory, web search and knowledge tools), hides the raw models, makes Official Main the default (Uncensored Main when the official models are left out), applies the RAG settings (token splitter, 1000/100, top-k 10, hybrid search with the `BAAI/bge-reranker-v2-m3` reranker keeping the best 5), switches document search to the multilingual `BAAI/bge-m3` embedder (only while it is still on the stock one; a model you chose yourself is kept) and re-indexes your knowledge collections for it, scales attached images to 1920 px, caps a fetched web page at 32,000 characters, sets SearXNG web search, and creates your six knowledge collections. Every setting is read back after it is written: sign-up left on stops the install; a documents/web-search setting or a knowledge collection that did not take is listed under "Settings that need attention" in `install-report.md` (and at the end of the run) instead of stopping the install before backups are scheduled. |
| Backup | 22 | Takes a nightly consistent backup with a scheduled task, then runs the first backup and verifies the archive. Also registers `LocalAI-Watch`, a 15-minute health check, and `LocalAI-Recheck-Models`, the nightly re-check after Ollama updates itself (see Maintain). |
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
| Uncensored Main | Qwen3 30B-A3B 2507 | 65,536 | 20.6 GiB | **188.5 tok/s** |
| Uncensored Code | Qwen3-Coder 30B-A3B | 65,536 | 20.6 GiB | 178.5 tok/s |
| Uncensored Vision | Qwen3-VL 30B-A3B | 32,768 | 19.2 GiB | 184.8 tok/s |
| Uncensored Fast | Qwen3 14B (dense) | 40,960 (its maximum) | 11.6 GiB | 79 tok/s |
| Official Main | Gemma 4 26B-A4B (QAT) | 65,536 | 14.3 GiB | 143.6 tok/s |
| Official Deep | Qwen3.8 27B (dense) | 65,536 | 16.3 GiB | 79.2 tok/s |
| Official Fast | Qwen3.5 9B (dense) | 65,536 (now tuned up to 131,072) | 6.8 GiB | 111.1 tok/s |

The official rows are from the first update that installed them (same PC, toolkit 2026.10.06).
Official Fast keeps very little cache per token, so it is the one preset allowed past 65,536: at
131,072 it should need about 8.5 GiB. Its tuned size and speed are in `install-report.md` after
the next run.

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
   default). A new version can place layers differently, so the task `LocalAI-Recheck-Models` checks every preset on
   the GPU again that night, an hour after the backup (`Update-Models.ps1 -RecheckOnly -Scheduled`). It downloads
   nothing, runs only while the PC is idle (no Gaming mode, no ComfyUI or game on the GPU, no chat answer being
   written; otherwise it tries again the next night), and re-tunes a preset that no longer fits. You see a
   notification only when a preset could not be put back fully on the GPU, or when the re-check could not run for 3
   days. Then close ComfyUI and games and use **Start menu > Local AI > Re-check models**. Until it has run, the
   Health check warns. Turn the Ollama setting off if you would rather update Ollama yourself with
   `Update-Models.ps1 -UpdateOllama`, which re-checks in the same run.
2. **The 14B can't use 64K.** Qwen3-14B was trained to 40,960 positions, and Ollama silently caps
   `num_ctx` there. The guide's "later try 65536" is a no-op, so the tuner caps at 40,960.
3. **"Uncensored Fast" is *not* faster than "Uncensored Main": it is about 2.4× slower.** The 30B-A3B is a mixture of experts
   with about 3.3B parameters active per token; the 14B is dense, with 14.8B active, and generation speed tracks the
   active parameters. My pre-install estimates (90-140 and 50-65 tok/s) were too low on both counts. Fast also reasons
   ("thinks") by default, which delays the first token, so the preset turns that off. Open WebUI 0.11.4 applies the
   preset's Think setting over the per-chat Chat Controls switch, so that switch cannot turn it back on. For
   step-by-step reasoning set **Think (Ollama)** to On in Workspace > Models > Uncensored Fast > Advanced Params; re-runs keep it.
   Use Fast for its smaller VRAM footprint (11.6 GiB, so it can sit next to a small ComfyUI job) or for step-by-step reasoning.
4. **`num_ctx` is baked into Ollama aliases, not set in Open WebUI.** Open WebUI's background tasks
   (titles, tags, search queries) don't always send the chat's `num_ctx`. When two callers ask for
   different contexts, Ollama reloads the 19 GB model each time. Baking the context into the model means everyone asks for the same size.
   So leave **Context Length** (and Batch Size) at Default everywhere in Open WebUI: Settings > General > Advanced
   Parameters, Admin Panel > Settings > Models (default parameters), a preset's Advanced Params and a chat's Controls.
   A value there wins over the tuned alias; the installer report and `Test-LocalAI.ps1` warn about the first three.
5. **Image versions are pinned** (Open WebUI v0.11.4, SearXNG 2026.10.2) instead of `:main`. A moving tag
   can migrate your database on an unplanned restart. `Update-OpenWebUI.ps1 -Latest` updates deliberately, with a backup first.
6. **SearXNG is set up from day one.** It needs no API key and no account, and builds no profile of you (the search sites still see your IP
   address and the query), so there's no provider to choose
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
9. **The raw models are hidden.** The model selector shows just the presets: the official releases first, then the
   uncensored ones (the guide's "eventual selector").

## Daily use

- **Two families of presets, picked per chat in the model selector.** Every one runs on your own GPU and
  costs nothing.

  | Preset | Model | Use it for |
  |---|---|---|
  | **Official Main** (new chats start here) | Gemma 4 26B-A4B, Google's own release (QAT 4-bit) | Everyday questions, writing, images. Mixture of experts (~4B active per token), so it is fast |
  | **Official Deep** | Qwen3.8 27B, Alibaba's own release | Hard reasoning, maths, careful code. The strongest model that fits a 24 GB card; dense, so roughly a quarter of the speed |
  | **Official Fast** | Qwen3.5 9B, Alibaba's own release | Quick answers and light tasks |
  | **Uncensored Main / Fast / Vision / Code** | Community "abliterated" builds of Qwen3 (refusals removed) | Anything an official model refuses. Slightly less capable, and they will do what is asked without the safety judgement |

  The official models are the makers' own releases, so they are the most capable and also decline some
  requests; switch the chat to an Uncensored preset when that gets in the way (Open WebUI keeps the
  conversation). All three official ones read images. Their speeds are measured by your install (see
  the install report); the table above under "What the installer does" has the uncensored ones.
  They take about 42 GB of disk next to the uncensored ones. Leave them out with
  `Install-LocalAI.cmd -OfficialModels none`, or pick some (`-OfficialModels official-main,official-fast`);
  the choice is remembered (`-OfficialModels all` brings them all back). Leaving them out hides their
  presets but keeps the downloads; free the disk with `ollama rm gemma4:26b-a4b-it-qat qwen3.8:27b qwen3.5:9b`
  in a terminal (only if you don't use those tags yourself elsewhere). One whose download or GPU check fails
  is skipped with a warning; a model that cannot work here (tag gone, this Ollama cannot load it, does not
  fit) is tried again only after an Ollama update or when you name the choice again (`-OfficialModels all`),
  anything else (busy GPU, dropped download) on the next run.
- On the uncensored side: **Uncensored Main** for everything, **Uncensored Vision** when you attach images, **Uncensored Code** for code.
- **Once a chat has an image, keep that chat on a preset that sees images** (any Official one, or Uncensored Vision) or
  start a new chat for the other presets. Open WebUI sends every earlier image again with each
  message, and Uncensored Main, Fast and Code can't take images. The render guard drops them for those presets
  and leaves a note in the message ("image omitted"), so the chat keeps working, but the model can't
  see the screenshot any more. Only what Uncensored Vision already wrote about it stays in the chat.
- **It learns you (memory).** Every preset saves lasting things you tell it (preferences, projects,
  your setup, standing instructions) without being asked, says so in one line ("Noted: ..."), and
  updates rather than duplicates. It never keeps passwords, keys, account or ID numbers. See, edit or
  delete what it remembers in Settings → Personalization → Memory (or just tell it to forget something).
- **Skills.** A skill is a folder in `C:\AI\Skills` with a `SKILL.md`: a short front matter block
  (`name:` and `description:`) and then the instructions in Markdown. That is the Agent Skills layout,
  so skills written for other assistants can be dropped in as they are. After adding or editing one,
  run Start menu → Local AI → *Sync skills* (or `C:\AI\Scripts\Sync-LocalAISkills.ps1`): every
  preset then sees each skill's name and description and reads the full instructions only when a
  question needs them. A deleted folder switches its skill off and it comes back on with the folder;
  renaming a folder carries the skill over; a skill you switch off in Workspace → Skills stays off, and
  skills you make there are left alone. A SKILL.md with a problem (over 100 KB, no instructions) is
  reported and its last synced version kept. The first install puts three starter skills there
  (*Research with sources*, *Troubleshoot step by step*, *Remember and improve*). A preset that uses
  prompt-based (legacy) tool calling, because its model has no native tool template, gets no skills:
  there Open WebUI would paste every skill in full into every message.
- **It improves itself, with your approval.** When the assistant works out a method you are likely to
  need again, it can save it with the *skill notebook* tool as a draft ("Learned: ..."). **Drafts start
  switched off**: open Workspace → Skills, read it, and switch it on; from then on every preset offers
  it. It can improve a draft until you touch it; once you switch it on (or off again) or edit it, it is
  yours and is never changed (a new version arrives as a separate "(proposed update)" draft). It never
  touches skills it did not make. The approval step
  is deliberate: a skill is read in every later chat, so a web page or document the assistant read
  must never be able to plant one by itself.
- **Deep research** (installed with `-DeepResearch`): Start menu → Local AI → *Deep Research*, or
  `http://localhost:5055`. Sign in as `localai` with the password in `C:\AI\Secrets\deep-research.json`
  (the installer made the account and then turned sign-up off). Ask a question and pick *Quick
  summary* (a few minutes) or *Detailed report* (longer, several sections). It plans searches, reads
  the pages through your private SearXNG, and writes an answer with its sources, using Uncensored Main, or
  the Tongyi DeepResearch model if you installed it with `-TrialModels trial-research`. Nothing goes to
  a paid service: the searches go through SearXNG, the pages it reads are fetched directly (as your
  browser would), and it downloads public journal lists (OpenAlex, DOAJ) to rate its sources. Searches are spaced 3 s apart, because a run sends dozens and the sites SearXNG asks
  answer a burst with CAPTCHAs, which looks like "no sources found"; if that happens, wait a while and
  run it again. During a ComfyUI render it runs on the CPU like chats do, so it is much slower then.
  Its accounts and saved research are in the nightly backup too (`C:\AI\Backups\deep-research-<time>.tar.gz`; it is paused for a second or two, so a research run carries on); restore them with `Restore-OpenWebUI.ps1 -DeepResearch`. They are encrypted with the password in `C:\AI\Secrets\deep-research.json`, so keep that file with your other secrets. With the Tongyi model, research and Uncensored Main (both about 19 GB) take turns on the GPU, so the first message after switching reloads the model.
- **Start menu → Local AI:** opens Open WebUI, has *Gaming mode (free GPU)*, *Start again*, *Health check*, *Re-check models*, *ComfyUI (free GPU first)*, *Sync skills*, *Diagnostics (redacted zip)* and *Update toolkit*. Each script window stays open until you press Enter, so you can read the result.
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
  says so once and chats stay on the GPU. Measured on the RTX 3090 PC this toolkit
  was built for, on 2026-10-07 with the GPU idle (`Test-LocalAI.ps1 -Quick -CpuCheck`): Uncensored
  Main on the CPU generates 18.8 tok/s and reads the prompt at 117 tok/s (a 1889-token prompt),
  loads in 20.2 s and takes 1 MiB of VRAM. So a chat stays usable during a render, but a long web
  or RAG context makes the first token slow (those 1889 tokens take about 16 s to read). Another
  CPU gives other numbers: measure yours with `C:\AI\Scripts\Test-LocalAI.ps1 -Quick -CpuCheck` (close ComfyUI first; it reports CPU tok/s, prompt speed and the VRAM the CPU mode still takes), and see the guard's decisions in `docker logs render-guard`.
  On the CPU the whole model sits in RAM: a preset needs about its download size plus 12 GB of RAM
  (Uncensored Main about 31 GB). On a PC with less, the installer warns which presets would page to
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
  the chat. Start a new chat for a new topic, and use Uncensored Main (65K) for long documents.
- **Images:** the browser scales an attached image to fit 1920 x 1920 before sending it (1080p
  screenshots stay as they are). Each image costs Uncensored Vision about 1,000-2,700 of its 32K tokens,
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
- an Open WebUI that is stopped is a failure, never a warning. A backup, a restore and an update stop it for a few minutes and hold a lock meanwhile; when the check finds Open WebUI down and that lock held, it waits for the lock (up to 10 minutes, once in a run; `-LockWaitSec <seconds>` sets another wait) and looks at Open WebUI once more. Still down, the row fails and says what to do next: after the full wait, to let a Local AI window that is still at work finish, and to restart the PC only when there is none; after a shorter wait that you set yourself, that the wait was too short to tell, and to run the check again without `-LockWaitSec`. A run in which Open WebUI did not answer never ends with 0 failures
- that Open WebUI sees the models
- the presets: system prompt, native tool calling, image upload only where Ollama says the model reads images, and that past-chat search, code execution and the seven writing tools (notes, tasks, automations, calendar, notifications, channels, sub-agents) are still off (a preset where one of them is on again fails; Start menu > Local AI > Update toolkit puts the safety settings back, as a restore does for the presets of its catalog). A toolkit preset that is still in Open WebUI without being selected (Vision or Code skipped later, a trial or official preset dropped later) is judged on the same switches, in a row of its own, `Preset <name> (not selected)`
- that no Context Length set in Open WebUI overrides the tuned aliases (your settings, the default parameters, the presets)
- signup off and memories on
- the RAG and search settings (including image scaling and the fetched-page limit)
- a chat through every preset, and for Uncensored Vision an image whose colour it must name
- that a memory is recalled in a new conversation (it uses a random number, then deletes it)
- that a document is retrieved from a freshly indexed collection (random code, deleted afterwards)
- that a SearXNG search returns results
- that the backup task is scheduled (a newest backup older than about two days is a warning)
- that the health watch is still running (no check for two hours is a warning) and that Windows shows its notifications
- what the health watch found when it last compared the installed scripts, the Stack folder, the `LocalAI-*` tasks and the listening programs with the baseline of the last install or update (a difference is a warning, not a failure; see *Integrity watch* under Maintain)
- that ports 11434/3000/8888 (and the deep research port, when it is installed) listen on loopback only

The exit code is the number of failures.

## Maintain

| Task | Command |
|---|---|
| Update SearXNG | `C:\AI\Scripts\Update-OpenWebUI.ps1 -SearxngVersion <tag>` (a tag from hub.docker.com/r/searxng/searxng/tags; newer tags bring fixed search-engine scrapers). The render guard runs on the same image, and the quick test afterwards checks both, plus one real search. SearXNG keeps no data, so the way back is the same command with the old tag, which the update prints and writes to `C:\AI\Logs\update.log`. `-Rollback` only undoes Open WebUI updates |
| Update Open WebUI | `C:\AI\Scripts\Update-OpenWebUI.ps1 -Latest` (backs up, pulls, recreates the container, runs a quick test). Undo it with `Update-OpenWebUI.ps1 -Rollback` (type YES): previous image plus the data from just before the update, so chats made since the update are lost (a safety copy of them is kept in `C:\AI\Backups`). The newest `before-<version>` backup is never pruned. After a successful update, older Open WebUI images are removed (the running one and the one `-Rollback` needs stay), so Docker's disk does not grow by several GB per update. An update whose new version does not answer within 10 minutes is remembered as one that had not answered. Running the same update again then waits for Open WebUI once more and says how it went (it does not say "Already on"). An update to another version first looks whether Open WebUI answers by now, and goes on if it does. While Open WebUI runs and still does not answer, that update is refused and nothing is changed: go back first with `Update-OpenWebUI.ps1 -Rollback`, or add `-Force` to update all the same (when no backup from before the failed update is recorded, it warns and goes on by itself). While Open WebUI is stopped or Docker Desktop is not up, the same update says to start it first and gives no rollback advice, because nothing can be seen then. An update to another version says the same, unless `-Force` is given (it goes on) or no backup from before the failed update is recorded (it warns and goes on). If the old version does not answer after a rollback, the message gives the way back, in this order: `Update-OpenWebUI.ps1 -Version <new> -SkipBackup` first, then `Restore-OpenWebUI.ps1 -Archive <the pre-restore archive it names>`. A rollback by hand goes the same way round: the old version first (`-Version <old> -SkipBackup`), then its data. `-WebUIWaitSec <seconds>` gives the new version another time to answer than those 10 minutes, and `-CatalogPath <file>` names another model catalog than `config\models.psd1` for the health check that ends an update; with `-Rollback` both are handed on to the restore when given (which waits 5 minutes unless told otherwise). History in `C:\AI\Logs\update.log`. Re-running the installer keeps the updated version |
| Change the admin password | `C:\AI\Scripts\Set-OpenWebUIPassword.ps1` (random) or `-Prompt` (type your own); updates the secrets file and signs out old sessions. A password the script makes is shown once (not at all with `-Quiet`). One you give yourself, with `-Prompt` or `-NewPassword`, is never printed back: the script says which file holds it. `-Prompt` asks twice and compares the two entries letter for letter, capitals included. If the secrets file cannot be written after Open WebUI took the new password, the run ends as failed and names `C:\AI\Secrets\openwebui-admin.pending.json`, which holds the new password; the next run of the script moves it into the secrets file |
| Back up now | `C:\AI\Scripts\Backup-OpenWebUI.ps1` (add `-Mirror E:\Backups` or set `-BackupMirror` at install for a second copy) |
| Update models / Ollama | `C:\AI\Scripts\Update-Models.ps1` re-pulls every model and re-tunes only those whose upstream tag changed (`-UpdateOllama` upgrades Ollama first). Before it loads and measures a model, a run you started waits up to 10 minutes for other GPU programs to let go, as the installer does. `Update-Models.ps1 -GpuWaitMinutes <n>` sets another wait, and with 0 it does not wait at all: a GPU that other programs are using then ends the run at once, with their names. `Update-Models.ps1 -CatalogPath <file>` takes another model catalog than `config\models.psd1` for that one run and the health check at its end; the nightly re-check, the shortcuts, a later run without it and the installer read `config\models.psd1` again (for a change that lasts see *Add or swap a model* below). A model that really changed keeps its previous version as `<tag>-prev`, which costs its size on disk until the next update. Bring it back with `-Rollback main` (or `fast`, `vision`, `code`, `all`), which also pins it so later updates leave it alone until `-Unpin main`. A pinned model is not downloaded again, but its preset is still rebuilt when the alias is missing, when it was last measured on other content than the tag holds now, or with `-Retune`. A rollback says OK only once the preset is rebuilt. One that could not finish the rebuild (the GPU stayed busy, the model did not load, the measurement failed) says so instead: the tag is back and pinned, chats may still get the version you rolled back from, and running `Update-Models.ps1` again without the rollback option finishes it without a download. A rollback that an error or Ctrl+C ends between the pin and the rebuild prints the same warning. A second `-Rollback main` after one that could not finish finds no kept version; it now also says that the model is pinned with its preset behind, and to run the script without the rollback option. Free the space with `-DropPrevious`. A model whose new download cannot be loaded at all is left as it was (its preset keeps the version it was tuned on); the run says why and ends with an error, and the next run tries again. `-RecheckOnly` (Start menu → Local AI → Re-check models) downloads nothing: it only checks again, on the Ollama installed now, the presets measured on another Ollama version or left partly on the CPU by an earlier check, and records the result in `C:\AI\model-recheck.json`. The task `LocalAI-Recheck-Models` runs it every night with `-Scheduled`, which never waits: while another update runs, Gaming mode is on, a chat answer is being written or another program uses the GPU, it skips and tries again the next night (log: `C:\AI\Logs\model-recheck.log`) |
| Re-tune after a driver/GPU change | Happens by itself on the next re-run when the driver version changed; force it with `C:\AI\Scripts\Install-LocalAI.ps1 -Retune` |
| Add or swap a model | Try newer ones with `-TrialModels` first. To change the catalog for good, edit `config\models.psd1` in a downloaded copy (the copy in `C:\AI\Scripts` is replaced by the next Update toolkit) and run `Install-LocalAI.cmd` from there |
| Health watch | Task `LocalAI-Watch` runs `C:\AI\Scripts\Watch-LocalAI.ps1` every 15 minutes while you're signed in: checks Ollama, the Docker engine (one that stopped answering, as Docker Desktop can after sleep, is reported instead of hanging the check), Open WebUI, SearXNG, the render guard, whether Open WebUI can actually reach Ollama (the path chats take), backup freshness, the backup mirror (when you set one) and free disk space (models, backups, Docker data; warns under 10 GB), restarts a stopped container or Ollama (never Docker Desktop itself, in case you quit it on purpose; and an Open WebUI or deep research found down while the volume lock is held, as a backup, restore or update holds it, is left alone for 45 minutes, counted over runs that follow one another, and reported as not working after that, still without being started), and shows a Windows notification only when a problem persists for two checks in a row, again every 24 hours while it lasts, and once when it's fixed. A problem that persists is also shown as a banner at the top of Open WebUI (so you see it on the phone too, and when Windows has notifications switched off for PowerShell), and the banner goes away when it's fixed; banners you add yourself are kept. The health check warns when the watch has not run for two hours or Windows is dropping its notifications. When Ollama has updated itself since the presets were tuned, it only notes in its log that the nightly re-check will measure them; it notifies only when that re-check could not put a preset back fully on the GPU, or could not run for 3 days (then close ComfyUI and games and use Start menu → Local AI → Re-check models). On an install without that task it notifies once per new Ollama version instead. History in `C:\AI\Logs\watch.log`; run it by hand with `-NoHeal -Verbose`; silence it with `-PauseMinutes 240` (gaming, stack stopped on purpose) and `-Unpause` |
| Changes outside an update | About once an hour the health watch also compares the installed scripts, the Stack folder, the `LocalAI-*` tasks and the listening programs with what the last install or update recorded, and names what differs; see *Integrity watch* below. Accept changes you made yourself with `C:\AI\Scripts\Watch-LocalAI.ps1 -AcceptBaseline` |
| Gaming / long render: free everything | `C:\AI\Scripts\Stop-LocalAI.ps1` pauses the health watch for 12 h, stops the containers (data kept) and then unloads the models, in that order, so that a chat still being answered cannot load one again. It looks once more and unloads a second time; a model that is still loaded after that is named in a warning. If the containers could not be stopped, the health watch is switched on again and the run ends as failed. Add `-QuitDocker` to also release the WSL VM's RAM (up to 16 GB), or `-QuitOllama`. `-QuitDocker` also stops any other containers and WSL distributions you run, and a Docker Desktop that does not answer the request to quit within 5 minutes is ended instead (its process is stopped and WSL is shut down), with a warning. `Start-LocalAI.ps1` brings it all back and resumes the watch; it ends as failed, and says why, when Open WebUI cannot reach Ollama (the path chats take) or the render guard is not running |
| Something's wrong / asking for help | `C:\AI\Scripts\Get-LocalAIDiagnostics.ps1 -RunTests` (or Start menu → Local AI → Diagnostics) writes `C:\AI\Logs\diagnostics-<time>.zip` and copies a short summary to the clipboard. It covers versions, GPU/VRAM, Ollama, containers, logs and test results. Its health check waits at most 30 seconds for a backup, restore or update that holds the volume lock (run by itself the health check waits up to 10 minutes); an Open WebUI that is still stopped then is a failed row that says the wait was too short to tell. The admin password, secret keys, tokens, your Windows user name and the admin e-mail are redacted. Nothing is uploaded. The last run of each Start-menu shortcut (Gaming mode, Start again, Health check, Re-check models, ComfyUI) is kept in `C:\AI\Logs\shortcut-<script>.log` and included, and so are the nightly re-check's `model-recheck.json` and `model-recheck.log`, so an error from a window you already closed can still be read |
| Security check | Start menu → Local AI → *Security check* (or `C:\AI\Scripts\Test-PCSecurity.ps1`) checks this PC's own security and changes nothing; see [Keeping the PC safe](#keeping-the-pc-safe). No single window makes every check: a normal window for the driver test, Run as administrator (right-click the shortcut > More) for TPM, drive encryption and SMBv1. The report is `C:\AI\Logs\pc-security-<time>.md` (`-ReportPath` to put it elsewhere) |
| Uninstall | Start Docker Desktop first, then `C:\AI\Scripts\Uninstall-LocalAI.ps1` (elevated; `-WhatIf` first to preview; it asks you to type YES). It takes a verified final backup (`...-pre-uninstall.tar.gz`), then removes the scheduled tasks (backup, health watch, nightly model re-check), the Tailscale mapping (before the containers, so that step cannot bring one back), the containers, `localai-*` aliases, the shortcuts, the Start-menu folder and `C:\Program Files\LocalAI`. Chats and models are kept unless you add `-RemoveData` / `-RemoveModels`, and `-ResetOllamaSettings` also drops the OLLAMA_* variables (a value you had set yourself before the install, e.g. `OLLAMA_NUM_PARALLEL=4` for another tool, is put back instead; the first install logs each one it finds, and installs from before this toolkit version only remove). If the final backup fails, nothing is removed; with Docker not running, `-RemoveData` refuses. A run with Docker Desktop closed and no `-RemoveData`, or with `-RemoveModels` while Ollama is not answering, says in its plan what it will leave, ends `Not finished` with exit code 2, and asks to be run again once they are started; tuned aliases left because Ollama was closed are only listed as kept and do not change the exit code. `-ResetOllamaSettings` keeps the firewall rule that blocks Ollama from the network while Ollama still listens beyond this PC: restart Ollama, then run the uninstaller once more. The Backups folder is kept, and the final backup is never pruned, even after a reinstall: get your chats back with `Restore-OpenWebUI.ps1 -Archive <that file>` |
| After restoring an older backup | The restore puts this install's Ollama connection back, turns sign-up off again and, on the toolkit's presets that are in the restored data, switches off past-chat search, code execution and the seven writing tools (notes, tasks, automations, calendar, notifications, channels, sub-agents), and default web search too, except on the Official presets. When it could not, it says so and names the fix: Start menu > Local AI > Update toolkit. Any other preset in the restored data that lets the assistant read past chats, run code or use a writing tool is named in a warning (its name and id) with where to switch it off (Workspace > Models), and is not changed. When Open WebUI could not be asked for its presets, the last warning says they were not looked at, and that Update toolkit does not look at them either. If the backup had a different admin password, run `Set-OpenWebUIPassword.ps1 -PromptCurrent` (type the old one; it then sets a new random password and prints it, add `-Prompt` to choose your own), then re-run the installer to re-apply presets. `Test-LocalAI.ps1` warns if the connection is wrong |
| Restore a backup | `C:\AI\Scripts\Restore-OpenWebUI.ps1` (newest daily backup; while the data is marked as wiped, the last good one, see below) or `-Archive <file>` (local, NAS or UNC path; naming an `-EMPTY` archive gets one more question). It takes a verified safety backup first, swaps the data only after the archive checks out, and rolls back automatically if anything fails after the old data was touched (deep research: add `-DeepResearch`; its replaced data is kept as `deep-research-<time>-pre-restore.tar.gz`). For Open WebUI's data the swap has two steps (deep research's is still one): the archive is unpacked next to the old data and checked, and only then is the old data deleted and the unpacked data moved into its place. An archive that does not unpack therefore touches nothing: Open WebUI starts again on the data it had, with no rollback and nothing kept stopped. If even the rollback fails, Open WebUI is **kept stopped on purpose** so nothing writes to half-restored data: Start again, the installer, updates and nightly backups refuse until you run the recovery command the restore printed (also in the health-watch notification and `C:\AI\open-webui-hold.json`). The same when you stop the restore (Ctrl+C) while it replaces the data, or stop its rollback before it is through: Open WebUI stays stopped, and the restore prints the command that finishes the job. The hold file then gives its reason as `a restore was stopped while it replaced the data` or `the rollback of a failed restore was stopped before it was through`. The two steps run in helper containers named `localai-restore-<volume>-unpack` and `localai-restore-<volume>-move`; the restore ends them itself, also after Ctrl+C, and warns when it could not make sure of that. The presets that get their safety settings back are those of `config\models.psd1` (`-CatalogPath <file>` names another catalog, and the restore says so). A backup leaves out the document-search and speech models Open WebUI downloaded (about 7 GB); a restore keeps the ones that are already in the volume, also after a swap that was cut off, so they are not downloaded again. Only a volume that had none (a new PC, a wiped volume) fetches them at the first start, which can take longer than the 5 minutes the restore waits (`-WebUIWaitSec <seconds>` sets another wait): it then says that Open WebUI may still be fetching them, and prints the command back to the data from before the restore, with the note that this copy goes with the Open WebUI version that ran before. A restore that Open WebUI answers after also takes off the mark of an update that had not answered (see Update Open WebUI) |

Every nightly backup is also opened with SQLite in a throwaway volume (with the Open WebUI image named in `C:\AI\Stack\.env`, or the one running if that is not on the PC; when neither is there the check is skipped and counted, and the health watch reports 3 such nights in a row; the restore's own safety copy skips it) (integrity check plus user/chat counts in
`C:\AI\Logs\backup.log`). An archive that fails is kept as `...-CORRUPT.tar.gz`, never replaces a good one, and makes
`Test-LocalAI.ps1` fail so you notice.

The same check counts users and chats. A night on which Open WebUI has lost the users or chats the
last good backup had (Docker's "Purge data", a reset by hand) is saved as
`open-webui-<time>-EMPTY.tar.gz`, the data is marked as wiped, and no older backup is deleted until
that is settled. Two `-EMPTY` archives are kept, the first and the newest, here and in the mirror.
While the mark stands, `Restore-OpenWebUI.ps1` without `-Archive` takes the last good backup, not
the newest, and of the deep research archives made since only the newest two are kept. The health
watch tells you on its next run, and it and `Test-LocalAI.ps1` fail their Backups check until it is
settled. There are two ways out: run `Restore-OpenWebUI.ps1` to get the data back, or, if you
emptied it yourself, run `Backup-OpenWebUI.ps1 -AcceptEmpty` once. The mark also clears by itself
when a nightly backup finds at least half the users and chats of the last good backup again. A
restore does not clear it: both checks still fail until the next nightly backup has counted the
data. To clear it at once after a restore, run `Backup-OpenWebUI.ps1` by hand.

Keep a copy of `C:\AI\Secrets` (session key and admin login) in your password manager. It's
deliberately not inside the backup archives.

### Integrity watch

At the end of every successful install or update the installer records a baseline in
`C:\AI\integrity-baseline.json`: the SHA-256 of every file under `C:\AI\Scripts` and `C:\AI\Stack`,
what each `LocalAI-*` scheduled task runs, as whom and at what privilege, and which programs listen
on which TCP ports. About once an hour the health watch compares the PC with it and names what
differs.

- **Two looks, one notice.** A difference is announced when two runs in a row saw it, so a file
  being saved or a port open for a minute raises nothing. It is announced once, as "Local AI:
  changed outside an update", and again at most once a day when the same thing is changed again.
  It also shows on the Open WebUI banner and in the health check's **Integrity watch** line. The
  whole list is in `C:\AI\Logs\watch.log`.
- **What is left out:** logs, the `.tmp`/`.bak`/`.bad` leftovers of a save, anything in a folder
  called `Secrets`, and `Stack\.env` except the settings that say where chats and searches are sent
  (names ending in `_URL`, `_URLS` or `_UPSTREAM`; a fingerprint of each value is kept, never the
  value). Of the listeners only additions that matter are reported: a program that newly accepts
  connections from other devices, and one of the stack's own ports held by another program.
  Listeners on this PC only, and ones that went away, are not.
- **An update is never reported as a change, but it is no undo.** The installer puts its own files
  and its three scheduled tasks back and removes nothing else, and the new baseline takes in
  whatever is there. What it takes in that the installer did not put there is a warning in the
  installer's log, is named once by the watch ("Local AI: the update kept changes it did not
  make") and stays a warning in the health check. Updating again does not clear that list: it is
  carried on until you accept it or remove what was added. Accepting names it once more, and it
  stays listed, also by a second acceptance or an update, until the health watch has run once after
  that; it does not wait for the notification to get through. A folder the install could not read
  to the end is carried the same way, and stays a warning until you accept it. So remove additions
  first, then update.
- **Changes you made yourself:** `C:\AI\Scripts\Watch-LocalAI.ps1 -AcceptBaseline` records the
  current state as the new baseline (the health check prints the exact line to paste). Any program
  running under your account could run that as well, so the next watch run confirms it with a
  notification ("Local AI: integrity baseline accepted") that names what was accepted, including
  what an earlier update had kept. If that notification cannot be shown (for example because
  Windows has notifications off for PowerShell), the list is in `C:\AI\Logs\watch.log`.
- **When a script changed,** or the baseline itself is gone, the advice names no Start-menu
  shortcut: every shortcut starts a script from that folder, and Update toolkit then asks for
  administrator rights. Delete what was added and install from a fresh copy of the toolkit (the
  one-line command under *Run it*, or a new download).
- **When it cannot compare:** while an install or a model update runs, nothing is compared (files
  are being replaced). If that lasts 6 hours, or a comparison keeps failing, you get "Local AI:
  changes are not being checked", and the health check says that its result is an old one.
- **When it cannot read a folder:** the watch never reads through a junction or symbolic link. If
  `C:\AI\Scripts` or `C:\AI\Stack` is one, or `C:\AI` itself is (for example because the folder was
  moved to another drive and a link left in its place), or Windows will not let the watch open the
  folder, it reads nothing in that folder. The notice then says that the folder "is a link to
  another place" or "could not be read, so the files in it were not compared", instead of calling
  every file gone. If you accept that state with `-AcceptBaseline`, the notice stops, but the files
  in that folder are still not watched: the baseline's own line (in the installer's log, in
  `watch.log` and in the health check's **Integrity watch** line) then reads "none in Scripts ...:
  changes there are NOT noticed" instead of counting files. The installer does not work in a
  linked install folder either: it says so and stops. Put the real folder back in place of the
  link.
- **What it is not:** the baseline sits in the install folder, which your Windows account can
  write. It catches accidents, other software and clumsy tampering. It does not stop, or even
  notice, someone who already runs as you and rewrites the baseline together with the change, and
  a program name is only a name.

`Uninstall-LocalAI.ps1 -RemoveData` removes the baseline together with the other state files. Two
of them can stay for one more run: when the run was also given `-ResetOllamaSettings` or
`-RemoveModels` and asks to be run again (it ended `Not finished`, Ollama did not answer, or the
firewall rule was kept), `install-state.json` and `localai-config.json` are named as kept, because
the follow-up run reads your own Ollama settings from before the install out of them. The first
run that has nothing left to ask for deletes them.

## Troubleshooting

"Re-run the installer" below means `C:\AI\Scripts\Install-LocalAI.cmd`, with any switch after it, e.g. `C:\AI\Scripts\Install-LocalAI.cmd -RenderGuard off`. To also get the newest toolkit, use **Update toolkit** instead (it keeps your switches' effects).

| Symptom | Likely cause | Fix |
|---|---|---|
| Installer stops: "only N% on the GPU even at 8K" | Another app holds VRAM (ComfyUI, Forge, a game), or the driver/Ollama is stale | Close the GPU apps (or run `Release-GPU.ps1`), quit Ollama from the tray, re-run. Update the driver if it's old. For Vision or Code you can also leave the model out with `-SkipVision` / `-SkipCoder`. |
| Installer stops: "cannot load fully on this ... sized for a 24 GB NVIDIA card" | The card has less than 24 GB of VRAM | Nothing was downloaded. The models need a 24 GB card (RTX 3090/4090); for a smaller one, edit the catalog (Maintain > Add or swap a model). |
| Installer stops: "No NVIDIA GPU found" | An AMD or Intel GPU, or an ARM PC | This toolkit needs an NVIDIA GPU with 24 GB of VRAM. |
| Installer stops: "Settings > Model location overrides the OLLAMA_MODELS variable" | The Ollama app saved its own model folder (it does so once its window has been opened) and starts the server with it | Open the Ollama app > Settings, set **Model location** to the folder the message names (or re-run with `-ModelDir` set to the app's folder), quit Ollama from the tray, re-run. |
| Installer stops: "the OLLAMA_MODELS variable in your user variables names that folder. It is not the installer's own setting" (or: "in the system variables") | An `OLLAMA_MODELS` variable you set yourself, or a system-wide one, keeps Ollama on another folder than the planned one, and a model still has to be downloaded. The installer removes only a variable it wrote itself | Nothing was downloaded. Remove the variable (Start menu > *Edit environment variables for your account*, or *Edit the system environment variables* for a system-wide one), or re-run with `-ModelDir` set to the folder the variable names. Quit Ollama from the tray, then re-run. |
| Installer stops: "-ModelDir ... is not the folder Ollama keeps its models in now" | You passed `-ModelDir` with another folder than the one Ollama uses, and that folder still holds models. Going on would download every model again and leave the old copy where it is | Nothing was changed. Either run the installer again the way the message says (without `-ModelDir`, or with the folder in use), and the models stay where they are; or quit Ollama from its tray icon, move everything from the old folder into the new one, and run the installer again with `-ModelDir` set to the new folder. The message gives both with the real folder names. The installer looks into the folder in use only when it chose that folder itself (Ollama's default folder, the folder of its last plan, or the value it wrote into `OLLAMA_MODELS`) and no junction or symbolic link has to be followed for it. A folder that only Ollama's log or a variable names, or one with a link at it, above it or under its manifests folder, is not looked at: the installer then goes by the models the running Ollama lists, says why it did not look, gives keeping the folder on the condition that your models are in it (the Ollama app shows its folder under Settings > Model location), and its move ends with starting Ollama again before the installer is run. No size of any folder is given. |
| Installer stops: "A container named searxng from another setup" | Open WebUI and SearXNG installed by hand from Open WebUI's guides | Nothing was changed. `docker rename searxng searxng-old` (stop it first if it uses port 8888), re-run: the installer then moves your Open WebUI data into its own stack. |
| Main runs well under ~150 tok/s in a new, short chat (normal is ~188) | The desktop or browser grew its VRAM use, so the driver is spilling into system RAM | First run `C:\AI\Scripts\Test-LocalAI.ps1`: its speed check uses a short prompt, so a warning there means spilling, not a long chat. Then run `Release-GPU.ps1` and close GPU-heavy apps, or re-run with `-Retune`. If Ollama updated itself recently, use Start menu → Local AI → *Re-check models* first (no downloads): it re-checks the presets on the new version, as the nightly re-check would. Optionally set NVIDIA Control Panel → *CUDA - Sysmem Fallback Policy* → *Prefer No Sysmem Fallback* for `%LOCALAPPDATA%\Programs\Ollama\lib\ollama\llama-server.exe` so it fails loudly instead of crawling. That is the process holding the model in VRAM (Task Manager and `nvidia-smi` show it); a setting for `ollama.exe` has no effect since Ollama 0.35. Check the name again after an Ollama update. Plugging the monitor into the motherboard (the Ryzen iGPU) frees about 0.5-1 GB. |
| A long chat gets slower (e.g. ~120-140 tok/s past 32K tokens) | Expected: every new token reads the whole KV cache, which grows with the chat | Nothing to fix. Start a new chat for a new topic |
| Model reloads (pause of several seconds) on every message, or one preset is slow while `Test-LocalAI.ps1` passes | A Context Length set in Open WebUI overrides the tuned alias | `Test-LocalAI.ps1` names the place (check "Context decided by the tuned aliases"); set it back to Default there. A chat's own Controls can't be checked: look there too |
| Uncensored Vision: "exceeds the available context size", or answers stop mid-sentence | The chat's images (each sent again with every message) plus the text no longer fit in Vision's 32K | Start a new chat, with fewer images per chat |
| ComfyUI OOM or slow right after chatting | An Ollama model is still resident | Run `Release-GPU.ps1`, or install with `-KeepAlive 5m` |
| Open WebUI lists no models | Ollama isn't running | Start Ollama from the Start menu, then run `Test-LocalAI.ps1 -Quick` |
| "Docker engine did not start" | Licence prompt, virtualization off, or WSL broken | Open Docker Desktop once. Enable virtualization in the BIOS (**SVM Mode** on AMD, **Intel Virtualization Technology / VT-x** on Intel). Run `wsl --update`. Re-run. |
| "Docker Desktop is not responding. Restart it (whale icon > Restart), wait for Engine running, then run this again." | Docker Desktop has stopped answering while its commands still start; it can after the PC slept. Start again, Gaming mode and the Health check end with this line instead of waiting without a word; Diagnostics prints it as a warning and makes its zip without the Docker parts | Right-click the whale icon in the taskbar > Restart, wait until Docker Desktop says *Engine running*, then run the same thing again. Gaming mode has unloaded the models all the same, and has not left the health watch paused. |
| Web search: "no results" | The sites SearXNG asks (DuckDuckGo, Brave, Google CSE by default) are rate-limiting this PC, or one changed its pages so the pinned SearXNG cannot read them | Run the Health check: its *SearXNG search* line names each engine and its reason. *CAPTCHA* or *too many requests*: wait a few minutes to an hour. *HTTP error* or *server API error*: the site answered but refused; wait, and if it lasts try a newer SearXNG. *parsing error*: only a newer SearXNG fixes it, see Update SearXNG under Maintain. If that line finds results but Open WebUI's search does not, Open WebUI could not load the pages: check Admin Settings > Web Search (web loader, SSL verification) and `docker logs --tail 50 open-webui`. Details: `docker logs --tail 50 searxng`. |
| RAG gives a wrong or empty answer | File not processed, collection not attached, or the chunk wasn't retrieved | Check Workspace → Knowledge (processing status). Attach the collection with `#`. Ask with the manual's own wording. |
| A scanned PDF fails with "The content provided is empty", or values printed inside pictures are never found | Open WebUI reads only a PDF's text layer by default | Turn on Admin Panel > Settings > Documents > **PDF Extract Images (OCR)** (re-runs keep it; OCR runs on the CPU and makes indexing slower), then upload the PDF again. For a page or two, a screenshot in a Uncensored Vision chat also works |
| Odd answers in Open WebUI but fine in `ollama run localai-main` | A preset or chat parameter was changed in the UI | Re-run the installer to restore its system prompt and tool mode. Your own extra parameters are kept, so remove those in Workspace > Models if they are the cause |
| Ollama tray settings | The new Ollama app's **Expose to network**, **Context length** and **Model location** settings override the environment variables. Model location is saved as soon as the app's window is used, so it then stays on the folder of that time | Leave Expose off (the installer warns, and Health check fails, when Ollama listens beyond 127.0.0.1). After changing `-ModelDir`, set Model location in the app to the same folder (the installer stops if they differ and a model still has to be downloaded). The tuned aliases keep their own context either way. |
| Port 3000 or 8888 already in use | Another local service, or another project's Docker container | The installer picks the next free port and records it in `install-report.md` |
| Chat is suddenly slow (CPU speed) | ComfyUI has a job queued or finished less than 60 s ago, so the render guard runs chats on the CPU. Afterwards the guard unloads the CPU copy, so the next chat after that loads onto the GPU again | Expected. `docker logs render-guard` shows why ("runs on the CPU", then "unloaded the CPU copy"). Wait for the render, or re-run the installer with `-RenderGuard off`. Still slow a minute after the render: run `C:\AI\Scripts\Release-GPU.ps1` and send the message again |
| A chat answers "image omitted", or fails with "does not support multimodal requests" | The chat has an image from Uncensored Vision and you switched it to Main, Fast or Code. The render guard drops such images (without it, every message in that chat fails) | Switch that chat back to Uncensored Vision, or start a new chat |
| Open WebUI: "render-guard: Ollama is not running, so this chat cannot be answered. Start it (Start menu > Local AI - Start again), then send the message again." | The render guard could not connect to Ollama. The address it tried and the error are in the guard's log only (`docker logs render-guard`) | Start menu > Local AI > *Start again* (or start Ollama from the Start menu), then send the message again. `-RenderGuard off` does not help here: it only stops the CPU routing, and chats still go through the guard (changing the URL by hand in Admin Settings is undone by the next installer run) |
| Open WebUI: "render-guard: Ollama gave no answer. A long answer on the CPU can take many minutes: ask for a shorter one or wait for the render to end, then send the message again." | Ollama took the request and no answer came: it stopped or was restarted in the middle of the chat, it ended the connection, or it said nothing for the 15 minutes the guard waits. The error is in the guard's log (`docker logs render-guard`) | Send the message again. While ComfyUI renders, ask for a shorter answer or wait for the render to end. If it happens with no render running, run the Health check |
| Open WebUI: "render-guard: this request is larger than 256 MiB" (HTTP 413) | The chat has grown past the size the render guard takes for one request. A chat sends all its pictures again at every turn, so a long chat with many or large pictures gets there | Start a new chat, or attach fewer or smaller pictures. The size is the setting `RENDER_GUARD_MAX_BODY_MIB`; see *The containers are locked down* under Security model before you raise it |
| Installer interrupted | Power loss, closed window | Run it again. It's idempotent, and tuning results are reused. |
| The installer's last line is red: "N of the acceptance checks FAILED" | The install ran to its end, but the health check that closes it found N problems. The address, login and password lines above it are yellow then, not green | Each `[FAIL]` line further up (also in the install log the red line names) says what is wrong and what to do. Fix them, then run the installer again: re-running is safe, reuses what is done and repeats the checks. One failed row is not cleared by running it again: where Ollama has to listen beyond this PC and Docker does not get through the firewall rule by address, the installer keeps the rule on the network adapters only, so *Nothing exposed beyond localhost* fails after every install and update until the toolkit settles this itself (`IMPROVEMENTS.md`, row 169); keep such a PC off any VPN or tailnet that others are on, as that row's next step says, and know that the two things you can do by hand end the failure only until the next installer run, which sets both back: making Ollama listen on this PC only (chats then work only if the containers reach it that way), or blocking port 11434 by address yourself under the rule's name, *LocalAI - Block Ollama from LAN*, leaving out the addresses Docker comes from. |
| "Another Local AI installer run or model update is already running" | An installer window (often the Administrator one) or `Update-Models.ps1` is still open | Let it finish or close that window, then try again |
| "Open WebUI is kept stopped after a failed restore" | A restore and its automatic rollback both failed, or a restore (or its rollback) was stopped while it replaced the data | Run the recovery command shown in the message (also in `C:\AI\open-webui-hold.json`), then Start again |
| Health check: "Open WebUI is down and the volume lock was still held" (or "is still down, and the volume lock was still held", or "is down and the volume lock is held"), or a health watch notice "Open WebUI (down, and by the watch's record the volume lock was held each time it looked since ..." | Open WebUI is stopped while something holds the lock that a backup, a restore and an update hold while they work. The check waited for the lock (10 minutes unless `-LockWaitSec` set another wait; once in a run, so a later row of the same run says "is held" at once) and it was not let go. Nothing says who holds it. Any program running under your account can hold that lock and stop Open WebUI: for as long as it does, every health check waits those 10 minutes and then fails, also the check at the end of an install, an update and a model update. That is a delay, never a wrong PASS. The health watch leaves an Open WebUI or deep research that is down under that lock alone for 45 minutes, counted over 15-minute runs that follow one another and starting over after more than 35 minutes without a look; after that it reports it as not working on every run (a notification on the second such run, reminders every 24 hours) and still never starts it under the lock. Not closed: a program that removes or re-dates the watch's two times in `C:\AI\watch-state.json` before each run keeps the watch quiet | If a Local AI window is still at work on a backup, restore or update, let it finish and run the Health check again. If none is, restart the PC, which ends whatever holds the lock, and run it again. After a wait you shortened yourself, run the check again without `-LockWaitSec` first |

## Keeping the PC safe

The stack itself is locked down (next section), but it is only as safe as the PC under it. Start menu →
Local AI → *Security check* (`C:\AI\Scripts\Test-PCSecurity.ps1`) looks at the PC and, for every problem,
names one next step you can do yourself (a Settings path or a download page). It **only reads**: no
setting is changed, nothing is started, stopped or uninstalled, and nothing is sent anywhere. One
check goes a step further and still changes nothing: for a hardware-access driver on its list that
is loaded, it opens the driver's device without asking for read or write access and closes it at
once, to see whether any program may. It checks:

- antivirus on and current (Microsoft Defender, or the product Windows Security knows), Tamper
  Protection. An antivirus that Windows still lists but that is snoozed, expired or switched off
  counts as none: when Microsoft Defender stands back for it (passive mode) or has its real-time
  protection off, nothing is protecting the PC, and that is a failure. When Defender is doing the
  protecting, such a leftover, or one whose definitions are out of date, is named on the same
  line with what to do about it;
- Windows Update installed something in the last 35 days, and no restart is pending;
- the firewall is on for every network type; User Account Control is on and asks;
- Core isolation's memory integrity, the Microsoft vulnerable driver blocklist, Local Security Authority
  protection, ransomware protection (Controlled folder access), Secure Boot and the TPM;
- drive encryption (BitLocker, or *Device encryption* on Windows 11 Home) for the Windows drive and the
  drives holding `C:\AI` and the Ollama models;
- Smart App Control (for information) and SmartScreen for apps;
- known-vulnerable kernel drivers that RGB, fan and overclocking tools install: WinRing0 (many fan and
  RGB tools; Microsoft Defender flags it since 2025), RTCore64 (MSI Afterburner), CorsairLLAccess64
  (iCUE before 3.25.60), ASUS AsIO2/AsIO3 and GIGABYTE gdrv; each with the app it usually comes with
  and whether updating or uninstalling that app fixes it;
- hardware-access drivers of fan, lighting and tuning tools that are on no such list but hand out
  direct access to the hardware (ASUS AsIO and GLCKIo, ENE EneIo, MsIo): a warning when any
  program on the PC can open one, not only the tool it came with, because every program you run,
  a malicious one too, could then use it to take over Windows;
- Remote Desktop and SMBv1, and programs listening beyond this PC; Ollama, Open WebUI, SearXNG,
  ComfyUI (8188/8000) or Docker (2375) reachable from the network is a failure;
- firewall rules that let other computers connect to a program that runs any script it is given
  (python, node, PowerShell, wscript, cscript, java). Windows writes such a rule when you answer
  *Allow* to its firewall question while a script is listening, and the opening then holds for
  every script started with that program, not for one app;
- Docker Desktop at 4.44.3 or newer (CVE-2025-9074) and its *Expose daemon on tcp://localhost:2375
  without TLS* setting off;
- ComfyUI: the custom nodes you have (they run with your full user rights; one called
  ComfyUI_LLMVISION stole browser passwords in 2024) and model files in the pickle format
  (`.ckpt`, `.pt`, `.pth`, `.bin`), which can run code when loaded: prefer `.safetensors`;
- `C:\AI\Secrets` readable only by you, Administrators and SYSTEM;
- OneDrive, when the backups (or the second copy you set up for them) lie in its folder: a warning
  when it is set to start with Windows but is not running, because nothing uploads the backups
  then and they exist on this PC only;
- whether you use an administrator account day to day (a standard account is safer).

It works in a normal window; the TPM, drive encryption and SMBv1 checks need *Run as administrator*
and say so. The hardware-access driver test is the other way round: it runs in a normal window
only (an administrator may open every device, so the answer would say nothing) and says so in an
elevated one. What the antivirus, driver, firewall-rule and OneDrive checks cannot read, or do not
know how to judge, is shown as not checked (SKIP), never as fine. The report in `C:\AI\Logs\pc-security-<time>.md` leaves out your user name, the computer
name and e-mail addresses, so it can be shared when asking for help. The exit code is the number of
failures.

## Security model (unchanged from the guide's Part 19-26 intent)

- **Conversation is permissive. Execution isn't available.** V1 gives the models no shell, no code interpreter
  and no file write access: those capabilities are turned off in every preset. Shell access (Open
  Terminal in a Docker sandbox, scoped to `C:\AI\Workspace`) is V2 and should keep the guide's
  permission levels A-F.
- **What the assistant may do without asking is the same short list in every preset.** Open WebUI
  0.11.4 offers a model its built-in tools in 16 groups, and a preset has one switch for each. A
  switch that is missing counts as on, so the installer writes all 16:
  - **On:** telling the time and date; asking you a question; searching the web and opening a web
    page; reading the knowledge collections attached to the preset or the chat; reading the files
    of the chat; and memory. Memory is the one of these groups that is on and changes something:
    the model can save a memory, and it can also change and delete memories, all without asking.
    That is how it learns you; what it holds is in Settings > Personalization > Memory.
  - **Off:** searching and reading your past chats; running code; making pictures; writing and
    changing notes; making and changing task lists; automations (creating, changing, switching on
    or off and deleting things that run later by themselves); the calendar (reading, creating,
    changing and deleting entries); sending notifications; reading channels; and handing work to
    sub-agents.

  Three things have no switch among the 16. A preset that has skills can always read one
  (`view_skill`). The terminal tools have none either; the toolkit sets up no terminal for them to
  reach. And a chat you open from inside a note can read and write notes whatever the notes switch
  says. The 16 switches are also about Open WebUI's built-in tools only. A preset can call the
  tools attached to it just the same, without asking: the installer attaches one, the *skill
  notebook*, which saves a skill draft that stays switched off until you switch it on (see *It
  improves itself, with your approval* above), and a tool or tool server you attach yourself is
  called the same way. To switch a group on, tick it in the preset's list of built-in tools
  (Workspace > Models, edit the preset). The next install or update switches it off again: only
  *asking you a question*, *reading the files of the chat* and *making pictures* stay as you set
  them, on or off. Two things hold this for every preset of the toolkit that is in Open WebUI,
  also for one you no longer have selected (Vision or Code skipped later, a trial or official
  preset dropped later: such a preset is hidden at most, never deleted, and a chat can still be
  started on it). The installer and Update toolkit look at each of them and switch off what is
  on again: past-chat search, code execution, the seven writing tools (notes, tasks,
  automations, calendar, notifications, channels, sub-agents) and, except on the Official
  presets, web search without being asked. And `Test-LocalAI.ps1` judges each of them on
  past-chat search, code execution and the seven writing tools: a switch that is not written
  out as off, under the exact name Open WebUI reads, fails the preset's row, which names Update
  toolkit as the fix. The clean-up after restoring an older backup does the same for the
  toolkit's presets that are in the restored data: it switches the same things off there
  itself, the seven writing tools included. What it only names: a preset in the restored data
  that the restore's catalog does not list (one you made, one of another catalog, one the
  toolkit has retired) and that lets the assistant read past chats, run code or use a writing
  tool gets a warning with its name and id, and is not changed. The restore reads one catalog
  (the toolkit's own unless `-CatalogPath` names another), not the two lists the installer and
  the health check read. The 16 names are
  those of Open WebUI 0.11.4, the version the installer sets up; a
  group that a newer Open WebUI adds is on until the toolkit knows it.
- **Web pages and documents can try to steer the assistant.** Text in a search result, a fetched page
  or an uploaded PDF reaches the model like your own words, and a page can hide instructions in it. So
  no preset can search or read your past chats (a planted instruction could otherwise have them sent
  out inside a web address the model fetches), and the Uncensored presets, which have no refusal
  training, search the web only when you switch **Search** on for that chat. The Official presets search
  by themselves. For browsing unknown sites, prefer an Official preset.
- **Nothing listens beyond 127.0.0.1**, and `Test-LocalAI.ps1` checks this. For phone access install
  Tailscale, sign in, turn on MagicDNS and HTTPS Certificates at login.tailscale.com/admin/dns, then run
  `C:\AI\Scripts\Enable-TailscaleAccess.ps1`: HTTPS at `https://<this-pc>.<tailnet>.ts.net`, tailnet only, survives
  reboots, nothing opened on the LAN (`-Disable` removes it). By default every device in your tailnet
  can open that address, and the PC's Tailscale key expires after 180 days, which ends phone access
  without a message: `docs/TAILSCALE-ACCESS.md` in the repository (the docs folder is not copied to
  the PC) has the steps for an access policy that admits only the phone, for switching key expiry
  off, and for Tailnet Lock. Those steps were written without access to Tailscale's own pages and
  are labelled so in the guide: check each against Tailscale's documentation before you follow it.
  Never port-forward or bind to `0.0.0.0`.
- **The containers are locked down.** Every container drops all Linux capabilities (deep research
  keeps the five its start script needs and nothing more), cannot gain new privileges, and has a
  memory limit and a limit on how many processes it may start: 16 GB for Open WebUI, 8 GB for deep
  research, 2 GB each for SearXNG and the render guard. A container that misbehaves or is taken over
  can therefore not use up the PC. SearXNG and the render guard also run as unprivileged users on a
  read-only filesystem; SearXNG reads its settings from a folder it cannot write to, and gets two
  small temporary folders it can write to but cannot run programs from. Open WebUI still runs as
  root inside its container, with no capabilities and a writable filesystem, because it rewrites some
  of its own files at every start. The render guard keeps only chats in memory (it may have to
  rewrite them), and only up to a size cap: one chat request may be 256 MiB at most, because the
  guard holds it up to six times over while it reads and rewrites it (1536 MiB of its 2 GB). A
  larger one is refused with a message that says so (HTTP 413, see Troubleshooting) instead of
  ending the guard. Everything else, a model file sent through it for one, passes through in
  small pieces whatever its size. The cap is the setting `RENDER_GUARD_MAX_BODY_MIB`; to change
  it, add a line such as `RENDER_GUARD_MAX_BODY_MIB=128` to `C:\AI\Stack\.env` and use Start menu >
  Local AI > *Start again*. A lower number is safe. A higher one uses up the room that is left,
  and from about 340 on a single chat can outgrow the 2 GB and end the guard. It must be a whole
  number above 0: anything else counts as 256, and the guard's log says so in a line at its
  start (`docker logs render-guard`). What the cap does not cover:
  several chats near it at the same moment, and a request built to be expensive to read (only a
  program inside one of the containers can send one); Docker then restarts the guard and the
  chats running through it are cut off. An existing install gets
  all of this the next time you run the installer or Update toolkit, which copies the new compose
  file and recreates the containers whose settings changed. The reasons for each choice, and what
  is still open, are in `docs/CONTAINER-HARDENING-PLAN.md`.
- **Your data stays yours.**
  - `C:\AI` is readable only by you, SYSTEM and Administrators. Without this, other Windows accounts
    could read the backups, which hold every chat. Secrets in `C:\AI\Secrets` and
    `C:\AI\Stack\.env` are locked the same way. Each installer run also takes out an entry that
    another account was given by name, and makes Administrators the owner where another account
    owned it (an owner can give itself access again). It does this on the AI folder itself, on
    Scripts, on Secrets and on the files it protects by name when it writes them, and writes each
    one to the install log; what it could not remove shows as a warning that begins
    `Could not restrict permissions`, with the reason. Not reached yet: such an entry or owner on
    Backups and the other folders inside `C:\AI`, and on a password file an earlier run wrote.
    Also open: where
    your own account is the owner of `C:\AI\Scripts`, a folder the installer lets you read and
    run but not change, it stays the owner, and an owner can give itself write access again
    (IMPROVEMENTS.md, row 160).
  - The bootstrap admin password is removed from the container environment after the first login.
  - The installer places `C:\AI\CLAUDE.md`, rules for an AI coding agent opened in that folder
    (which commands it may run, what it must never touch), only if no file of that name is there;
    it is never overwritten or merged, so edit it freely, and the uninstaller leaves it.
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
  - Where Docker does not get through that rule, the installer falls back to a rule on the
    physical network adapters only, which a VPN and Tailscale get past. The Health check and the
    Security check count Ollama as blocked only under a rule that is on and blocks by address.
    The adapter rule, a rule that is switched off or was changed, no rule at all and a firewall
    that could not be asked are each a failed row with its own next step (for the adapter rule
    see the Troubleshooting row on the installer's red last line).
- **Updates trust this repository.** "Update toolkit" downloads the `main` branch over HTTPS and
  runs it as administrator. Whoever can push to `main` controls what it installs, so keep two-factor
  authentication on the GitHub account. To install a reviewed version instead, set
  `$env:LOCALAI_REF` to a tag or commit before running the command, and replace `refs/heads/main`
  in its URL with the same tag or commit (otherwise the downloader itself still comes from `main`).
  An update shows the incoming commit and the names of the files that differ and waits for a typed
  OK (see *Update the toolkit*). That lists file names, not their contents, so it does not replace
  reading the comparison whose address it prints, and it is only as trustworthy as the copy of the
  downloader that runs it.
  - Ollama and Docker Desktop installers come from winget (hash-checked). The direct-download
    fallback refuses a file without a valid signature whose signer name begins with Ollama or
    Docker. The whole name is not compared yet, so a look-alike name that only begins with one of
    those words would pass, and the file would be run as administrator (open: IMPROVEMENTS.md,
    row 151, fault 4).
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
