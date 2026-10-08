# ComfyUI in a container (security track item 7, optional): plan only, nothing built

Status (2026-10-07): a plan for backlog row 86 (7). No code was changed and nothing was run for
it: no container was started, no image was pulled, the owner's PC was not touched. What the
toolkit does today was read from the code named in each line. What Docker, NVIDIA, Microsoft and
ComfyUI do comes from the pages named beside each statement; a web researcher collected them on
2026-10-07 and they were not opened again for this text. A statement no page carried is marked
"estimate" or "not verified" and is listed again under "Open questions". The owner decides from
the last section, "Your decision", alone; everything before it is the reasoning behind it.

Revised the same day after a security review of the first draft. Its ten findings were checked
against the code and worked in. Where a statement rests on the reviewer's or the writer's
knowledge of another product, not on a page or on this repository's code, it says so. The
command lines in "Your decision" were written for this plan and not run.

## What the toolkit does today (read from the code)
- **How ComfyUI starts.** `Start-ComfyUI.ps1` unloads every Ollama model, reports the free VRAM
  and starts a Windows program with `Start-Process`: Comfy Desktop's exe or the portable build's
  `run_nvidia_gpu.bat`. It looks in `-Path`, the path remembered as `ComfyUIPath` in
  `C:\AI\localai-config.json`, Comfy Desktop's usual folders, two portable-build folders, then
  the Start-menu shortcuts. The Start-menu entry *ComfyUI (free GPU first)* and the optional
  desktop icon run this script. So ComfyUI runs directly on Windows, as the signed-in user.
- **What that means for custom nodes.** A custom node is Python code from the internet that
  ComfyUI loads into its own process, so it has every right the owner has. The README says so,
  and `Test-PCSecurity.ps1` lists the installed nodes, fails on the known malicious
  `ComfyUI_LLMVISION` and warns about model files in the pickle formats (`.ckpt`, `.pt`, `.pth`,
  `.bin`), which can run code when loaded. Those checks read. They fence nothing.
- **The render guard** (`stack/render-guard/render_guard.py`, a container) talks to ComfyUI over
  HTTP only, at the addresses in `COMFYUI_URLS` (default `http://host.docker.internal:8188` and
  `:8000`). It opens a TCP connection, reads `/queue` (or `/api/queue`) to see whether a job is
  running or queued, reads `/system_stats` for the VRAM PyTorch holds, and sends `POST /free`
  with `{"unload_models": true, "free_memory": true}` when ComfyUI is idle but still holds 1024
  MiB or more. It never looks at Windows processes. An address where nothing answers counts as
  "no ComfyUI there", and chats then stay on the GPU.
- **`Release-GPU.ps1`** talks to Ollama only: it unloads the loaded models and prints the free
  VRAM before and after. It does not touch ComfyUI.
- **Gaming mode** (`Stop-LocalAI.ps1`) unloads the Ollama models, pauses the health watch and
  runs `docker compose stop` on the stack. It does not stop ComfyUI. `Start-LocalAI.ps1` brings
  the stack back with `docker compose up -d`.
- **Phone access.** `Enable-TailscaleAccess.ps1` publishes one thing to the tailnet: Open WebUI,
  with `tailscale serve` in front of `127.0.0.1:<Open WebUI port>`. The toolkit publishes
  ComfyUI nowhere, and the security check counts a ComfyUI (8188/8000) that can be reached from
  the network as a failure. If ComfyUI's own page is opened from the phone, that is a link made
  outside the toolkit; the repository cannot show it (see "Open questions").
- **The standard the other containers meet** (`stack/docker-compose.yml`; rule COMPOSESEC in
  `tests/Invoke-StaticChecks.ps1`): `cap_drop: [ALL]`, `no-new-privileges:true`, a `mem_limit`
  and a `pids_limit` written as plain values, every published port on 127.0.0.1; where the image
  allows it also an unprivileged `user` and `read_only: true`. No service mounts the Docker
  socket. Internal-only networks were left out on purpose, because every service so far needs
  the host or the internet.
- **Docker and memory.** The installer installs Docker Desktop with the WSL 2 back end, runs
  `wsl --update` and requires WSL 2.1.5 or newer. On a PC with more than 32 GB of RAM and no
  `.wslconfig` it wrote one with `memory=16GB`: everything in Docker then shares 16 GB. It also
  puts the owner's account in `docker-users`. The integrity watch keeps `COMFYUI_URLS` of
  `Stack\.env` in its baseline and reports a change made outside an install or update.

## What a container changes, and what it cannot
**Today** a hostile node, a hostile package a node installs, or code hidden in a pickle model
file runs as the owner. It can read every file he can (documents, the passwords and sign-in
cookies his browsers keep, and `C:\AI\Secrets` and `Stack\.env`, which are locked to him: the
node is him), change, delete or encrypt them, make itself start with Windows, use the internet,
use Docker, and reach every program that listens on this PC only (Ollama has no login). This
has happened: ComfyUI_LLMVISION (June 2024) named wheels in its requirements that ran a hidden
PowerShell command and took browser passwords, wallets and screenshots
(https://gigazine.net/gsc_news/en/20240611-comfyui-llmvision-malware). In April 2026 more than
1,000 ComfyUI installs that were open to the internet were taken over through ComfyUI-Manager
for coin mining and a proxy botnet
(https://thehackernews.com/2026/04/over-1000-exposed-comfyui-instances.html). This PC's ComfyUI
is not open to the internet, so here the way in is a node or model the owner installs himself.

**In the container, in normal use,** the same code:
- sees ComfyUI's program files, the node folders, their packages and the models, all read-only;
- can write the `input` and `output` folders, the container's own `user` volume (saved workflows
  and settings) and a temporary area that is emptied at every stop;
- has no network of its own, by design: no internet, no home network, no Windows, no Ollama, no
  Open WebUI. Docker's page says that of an internal network; that it holds on Docker Desktop
  for Windows is not verified, and check 2 in "Your decision" tests it before anything is built;
- runs as a Linux user without rights, under a ceiling on memory and on processes.

What is left to it: spoil or delete what is in `input`, `output` and its `user` volume, read the
models and the pictures, drop a file into `output` that the owner might open on Windows, keep
the card busy, and report "a render is running" for as long as it likes, which keeps chats on
the CPU.

**Three ways around "no network".** The container has none; the programs that talk to it do.
- **The page in the browser.** A custom node may ship script for ComfyUI's page (nodes add their
  buttons and previews that way), and code inside the ComfyUI process decides what the server
  sends. That script runs in the owner's browser on Windows, which has the internet. It can
  fetch through ComfyUI whatever the jail can read (pictures, inputs, workflows), send it out,
  and take commands back over ComfyUI's own websocket. It can also call programs that listen on
  this PC only: Ollama has no login and by default answers pages served from `http://127.0.0.1`
  on any port (the reviewer's and the writer's knowledge of Ollama, not verified here; the
  toolkit sets no `OLLAMA_ORIGINS`), so the script could list, delete and pull models. Open
  WebUI's API refuses pages that are not its own (`CORS_ALLOW_ORIGIN` in the compose file, set
  for this very case). So while the page is open, "no internet, no Ollama" does not hold. All
  of this is true today as well: the container neither opens this hole nor closes it. Partial
  answer: the start script opens the page in a browser profile of its own (see "What each
  script has to change"; not verified). A phone's browser is outside that.
- **The render guard.** It asks ComfyUI on a timer and at each chat, and it has the internet and
  the host. As written today (`_http_json` in `render_guard.py`) it follows redirects and reads
  an answer of any length. A hostile ComfyUI could answer `/queue` with a redirect to an outside
  address that carries data, and that server could redirect back with a command: a slow channel
  both ways. It could also send the guard's GET to anything the guard can reach, or answer
  without end until Docker stops the guard at its 2 GB limit and the chats in progress are cut.
  Build item 6 closes this.
- **Open WebUI's picture button.** If the owner connected ComfyUI under Admin Panel > Settings >
  Images, Open WebUI is a second program that calls the jailed server and reads its answers.
  How it treats a redirect or an endless answer was not read (it is not this repository's
  code). Open; see "Open questions".

**In install mode** (adding or updating nodes, see Design) it can change node code, and through
a gate it reaches a short list of download sites and nothing else. Those sites take uploads
too. It still sees no Windows file outside the mounted folders.

**What a container does not stop:**
- **A break-out.** With a GPU the container must run on Docker Desktop's WSL 2 back end, where
  all containers share one Linux kernel; Docker's stricter mode has no GPU support
  (https://docs.docker.com/desktop/features/wsl/, https://docs.docker.com/desktop/features/gpu/).
  Break-outs have existed: CVE-2025-9074 (any container could drive Docker without a password;
  fixed in Docker Desktop 4.44.3, which the security check already asks for) and three in
  NVIDIA's container toolkit, the last one CVE-2025-23266, fixed in toolkit 1.17.8, which Docker
  says Desktop 4.44 and newer carry (https://docs.docker.com/security/security-announcements/).
  The NVIDIA ones need a hostile image; a build of our own rules that out. Research from March
  2026 shows that code which has reached Docker's Linux VM can start programs on Windows as the
  current user through Docker Desktop's own features, and that Docker does not plan to change
  it (Trend Micro, read in machine translation:
  https://www.trendmicro.com/ja_jp/research/26/c/cracking-the-isolation-novel-docker-desktop-vm-escape-techniques-under-wsl2.html).
  So a break-out ends where a node starts today, as the owner on Windows: never worse than now,
  and no wall against a skilled attacker.
- **The graphics path.** The container's GPU requests are carried out by the Windows graphics
  kernel and the NVIDIA driver on the host
  (https://learn.microsoft.com/windows-hardware/drivers/display/gpu-paravirtualization). A flaw
  there can be reached from inside. One was fixed in July 2026 (CVE-2026-50382, KB5101650;
  whether it could be reached from WSL 2 is not established). ComfyUI on Windows uses the same
  driver today, so this is nothing new, only something the container does not remove. Windows
  Update and driver updates are the defence.

## How a container gets the graphics card
- Docker Desktop supports NVIDIA GPUs on Windows with the WSL 2 back end only. Needed: a current
  Windows 10 or 11, an NVIDIA driver that supports WSL 2, a current WSL kernel (`wsl --update`).
  The same page gives a test command (https://docs.docker.com/desktop/features/gpu/). The
  toolkit's install already has the back end and the update. Windows 11 Home is enough: there
  Docker Desktop runs Linux containers through WSL 2
  (https://docs.docker.com/desktop/setup/install/windows-install/).
- Only the Windows driver is installed; NVIDIA says not to install a Linux driver inside WSL
  (https://docs.nvidia.com/cuda/wsl-user-guide/index.html). No page that was read tells a Docker
  Desktop user to install NVIDIA's container toolkit himself; it appears to come with Docker
  Desktop (medium confidence, not verified on this PC).
- One community guide adds a mount (`/usr/lib/wsl`) and a step after every driver update
  (https://github.com/mmartial/ComfyUI-Nvidia-Docker/wiki/Windows:-WSL2). It may describe Docker
  installed inside WSL, not Docker Desktop. Not verified either way; check 1 in
  "Your decision" answers it for this PC.
- In the compose file the request is the compose form of `--gpus all`. Its spelling was not
  looked up for this plan; build item 3 confirms it with `docker compose config`. No
  `privileged`, no device besides the GPU.
- Whether the card still works when the container is locked down as well (no capabilities, not
  root, read-only, no network) is on no page that was read. It is the first thing to find out.
  It costs ten minutes and needs no build.

## Design

### Image: our own build, every input pinned
There is no official ComfyUI image: the project lists a desktop app, a portable build, a manual
install, comfy-cli and its cloud (https://github.com/comfyanonymous/ComfyUI). The community
images were looked at and none is used:
- `yanwk/comfyui-boot`: the most pulled (about 1.5 million), updated 2026-10-06; runs as root;
  no signing or pinning mentioned (https://github.com/YanWenKun/ComfyUI-Docker).
- `mmartial/comfyui-nvidia-docker`: runs as an unprivileged user and documents WSL 2, but keeps
  ComfyUI and its Python packages in a mounted folder, so a pinned image would not pin the code
  that runs (read from its layout, medium confidence:
  https://github.com/mmartial/ComfyUI-Nvidia-Docker).
- `ai-dock/comfyui`: made for rented cloud machines; possibly not maintained since late 2024
  (low confidence).

None was shown to be a Docker Official, Verified Publisher or Sponsored image, the three tiers
Docker names as trusted (https://docs.docker.com/build/building/best-practices/). Each is one
maintainer's build, and trusting a stranger's build is what this item is meant to end.

So: a Dockerfile in the repository, built on the owner's PC, never pulled as a finished image.
- **Base:** a Docker Official Image of Python (Debian slim), named by digest
  (`python@sha256:...`), because a tag can be moved to other content (same page). PyTorch's CUDA
  packages bring their own CUDA libraries, so an NVIDIA base image should not be needed (the
  writer's knowledge of those packages, not verified: build item 1 proves it, or switches to
  NVIDIA's CUDA base, also by digest).
- **ComfyUI:** fetched while building, one release, checked out by its full commit id.
- **Python packages:** one lock file with a version and a hash for every package, PyTorch
  included, installed with pip's hash checking. Nothing is installed as "latest".
- **System packages** the common nodes need (git, ffmpeg, the libraries OpenCV loads) go into
  the image, because nothing can be installed afterwards.
- **User:** a fixed unprivileged one (uid 10001), set in the image, so it never starts as root.
- **Tag:** the ComfyUI version and a build number (`localai/comfyui:<version>-1`). An update is
  a new build from new pins; the old image stays until the new one has rendered (item 10).
- **What a pin cannot cover:** whatever is put into a volume later. Custom nodes and their
  packages are exactly that. That is why they are read-only in normal use.

### Where things live
- **ComfyUI, PyTorch, system libraries:** in the image, on a read-only root (`read_only: true`).
- **Custom nodes:** named volume `comfyui-nodes`, mounted read-only. They are thousands of small
  files, and a Windows folder is about 60 times slower per file operation than Docker's own disk
  (one measurement: https://brainwagon.org/blog/2026_07_11_wsl2_filesystem_speed); Microsoft
  says to keep files on the side where the tools run
  (https://learn.microsoft.com/en-us/windows/wsl/filesystems).
- **The packages nodes need:** named volume `comfyui-venv` (a Python environment on top of the
  image's), read-only. A constraints file keeps a node from swapping PyTorch.
- **Models:** first where they are. The existing Windows `models` folder is mounted read-only
  and nothing is copied. Loading is slow that way (see "Speed, VRAM and memory"). Only if it is
  too slow do they move into a named volume `comfyui-models` (see "Taking over"). ComfyUI can
  list several model folders (its `extra_model_paths.yaml`), so the few big models used every
  day can sit in the volume and the rest stay on Windows.
- **input, output:** the existing Windows folders, mounted writable, in place. Small files, so
  the slow path does not matter, and the pictures stay where the owner finds them today.
- **user (saved workflows and settings):** not the host install's folder. A named volume
  `comfyui-user` that belongs to the container. The take-over copies the owner's workflow files
  in. Nothing comes back by itself: on request the script copies workflow `.json` files out,
  only those, each checked to be plain JSON, into a subfolder of their own (`from-container`),
  never over an existing file. Why: the host ComfyUI reads `user` when it starts.
  ComfyUI-Manager keeps its settings and a list of commands to run at the next start under
  `user`, and Comfy Desktop keeps the server's start options there (the reviewer's knowledge,
  not verified here; build item 1 reads at the pinned release what ComfyUI, Manager and Desktop
  load from `user`). In a shared, writable `user`, code from a hostile model file, to which
  this design otherwise leaves nothing lasting, could arrange to run as the owner on Windows at
  the next start of the host ComfyUI, which is this plan's own way back. Inside the container
  the same applies to install mode, so whatever Manager reads at start sits on a volume of its
  own (`comfyui-manager`), read-only in normal use.
- **Temporary files:** `/tmp` and ComfyUI's temp folder as tmpfs with a size limit and `noexec`.
  Downloads that nodes keep (Hugging Face, Torch hub): named volume `comfyui-cache`, read-only.
- **Never mounted:** the Docker socket (OWASP: that equals root on the host,
  https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html), the owner's
  profile, `C:\AI`, a drive root. No `privileged`, no host `pid` or `ipc`.

ComfyUI is pointed at these places with its own start options (`--listen`, `--port`,
`--input-directory`, `--output-directory`, `--user-directory`, `--temp-directory`,
`--extra-model-paths-config`; `--cpu` for CI). They are named from the writer's knowledge of
ComfyUI; build item 1 confirms each against the pinned release.

### The hardening keys, and what breaks under each
- **`cap_drop: [ALL]`, `no-new-privileges:true`:** ComfyUI is a Python web server on port 8188
  and needs neither, as long as the image starts as its own user (an image that starts as root
  and steps down needs capabilities back, as deep-research does with CHOWN, FOWNER,
  DAC_OVERRIDE, SETUID and SETGID). Breaks: a node whose install script calls `apt-get` or
  `sudo`. Answer: that library goes into the image.
- **`user: "10001:10001"`:** breaks nothing in ComfyUI. Not verified: that a user who is not
  root can open the GPU device WSL 2 provides.
- **`read_only: true`, with nodes, packages, cache and models read-only:** breaks (a) installing
  or updating a node, and ComfyUI-Manager altogether, in normal use: install mode is for that;
  (b) a node that downloads its own models the first time it is used, as many preprocessor, face
  and caption nodes do: it is run once in install mode; (c) a node that writes settings or a
  cache into its own folder on every run: it fails or forgets, and if such a node matters its
  folder becomes a named exception. Python's `__pycache__` writing is switched off in the image.
- **`mem_limit`:** a plain number (the static check accepts no variable), set for this PC once
  its RAM is known. A render that needs more is ended by Docker; the PC stays up.
  **`pids_limit: 4096`**, as Open WebUI has. `/dev/shm` stays at Docker's 64 MB; a node that
  trains or uses PyTorch worker processes may want more, decided when one fails (the smoke test
  does not watch that mount: CONTAINER-HARDENING-PLAN, "What checks it").
- **Port:** none on the ComfyUI container; the door (below) publishes one port on 127.0.0.1, the
  one the host ComfyUI used. Inside,
  ComfyUI listens on every address of its private network; as the compose file says of SearXNG,
  exposure is decided by `ports`.
- **`logging: *logging`** like every service. **No `restart: always`:** ComfyUI runs when it is
  started, as today.

Breaks that come from Linux, not from the hardening:
- nodes made for Windows only (they call an `.exe`, use pywin32, or ship Windows packages only);
- every node's packages are installed again, for Linux (the take-over script does it);
- a saved workflow that names a model in a subfolder holds the Windows form
  (`sdxl\model.safetensors`) where Linux lists `sdxl/model.safetensors`, so the model may have
  to be picked again once per workflow (expected from how ComfyUI lists files; not verified);
- Comfy Desktop's own window, updater and built-in Manager are not used: the container runs
  ComfyUI's server and the page opens in the browser.

### Network: no way out, one door in
- A new network `comfy-inner` with `internal: true`: Docker gives it no route out and drops
  traffic to and from other networks
  (https://docs.docker.com/reference/cli/docker/network/create/). ComfyUI is attached to it and
  to nothing else. It is the first service of the stack that can live that way.
- Whether a published port works on an internal-only network was not established, and on Docker
  Desktop the Windows side has no route to a container's own address (not re-checked for this
  plan). The design does not depend on either. A second, tiny container, the **door**, sits on
  `comfy-inner` and on the stack's normal network, publishes one port on 127.0.0.1 and passes
  bytes to `comfyui:8188` and back (the page uses a websocket; a relay of bytes carries it). It
  is standard-library Python from the SearXNG image, as the render guard is: user 65534,
  read-only, no capabilities, small limits. It starts and stops together with ComfyUI.
- **Which port.** The portable build listens on 8188, Comfy Desktop on 8000 (compose file,
  README). The owner's bookmark, Open WebUI's picture setting and a phone link of his own point
  at the one he has, and the plan does not know which (open question 2). So the door publishes
  that port: the switch to the container notes which of the two answers while the host ComfyUI
  still runs (else 8000 for Desktop, 8188 for the portable build) and remembers it.
- What ComfyUI can reach, by design: the door's one port, which leads back to itself. Nothing
  else of its own accord; the three ways around that are in "What a container changes".
- What can reach ComfyUI: the PC's browser at `http://127.0.0.1:<that port>` and the stack's
  containers at `http://comfy-door:8188`. Open WebUI and the render guard can reach ComfyUI
  today as well. Not verified: whether an Open WebUI picture setting that names
  `host.docker.internal:<port>` still arrives when Docker itself publishes that port; if not,
  the setting becomes `http://comfy-door:8188` (one field, the owner's to change). A phone link
  made with `tailscale serve` in front of that port keeps working. One that relied on ComfyUI
  itself listening on the network (`--listen`) stops; the security check fails that kind
  already.
- Not verified, and the centre of the plan: that on Docker Desktop for Windows an internal
  network reaches neither `host.docker.internal`, nor Docker's own addresses, nor an outside
  address, and that Docker's built-in name service passes no outside name on (a slow way to leak
  data). Check 2 in "Your decision" tests exactly these on the PC before anything is built; CI
  and the PC test them again on the real services. The Docker address it tries
  (`192.168.65.7:2375`) is the one the 2025 flaw used (the writer's knowledge of that flaw's
  write-ups). If the network's gateway answers, build item 3 looks at the bridge option that
  leaves Docker's side of an internal network without an address
  (`com.docker.network.bridge.gateway_mode_ipv4=isolated`; the writer's knowledge of newer
  Docker Engine releases, not verified).

### Two ways to start
- **Normal:** service `comfyui`, as described. ComfyUI-Manager is not loaded.
- **Install mode:** service `comfyui-install`: same image and volumes, but nodes, packages,
  cache and Manager's own volume writable, and Manager on. It gets no ordinary network either.
  It sits on a second internal network, `comfy-install`, with the door and a **gate**: a small
  allow-list proxy (standard-library Python from the SearXNG image, hardened like the door) that
  is the only way out. The gate passes encrypted connections on port 443 to named sites and
  refuses everything else: PyPI, GitHub, Hugging Face and download.pytorch.org with their
  download hosts (the exact host names are settled in build item 7; a node that needs another
  site is a named addition). It does not look inside the connections. pip, git and the Hugging
  Face downloader are pointed at it with the usual proxy variables. The normal service is not on
  that network, so a gate left running gives it nothing. Same user, no capabilities, same
  limits, the same folders and no others. Only one of the two runs at a time (one port, one
  card).
- **What install mode still gives away.** It is the moment hostile code usually arrives
  (LLMVISION acted while its requirements were installed). There it can change node code that
  later runs in normal mode. The listed sites take uploads too (a repository, a model page), so
  what was read earlier, in normal mode, can leave at the next install mode; and what is fetched
  from them is still unchecked code. What the gate ends: reaching Ollama (no login) and the
  other programs that listen on this PC only, which every container on an ordinary Docker
  Desktop network can (CONTAINER-HARDENING-PLAN, "Deliberately not applied"), and the devices of
  the home network and the tailnet (the reviewer's knowledge of Docker Desktop, not verified
  here). It still reads no Windows file outside the mounted folders, which is the difference
  from today.

### What each script has to change
- **Render guard: one code change (build item 6), then a setting.** Its calls to ComfyUI
  (`/queue`, `/system_stats`, `POST /free`) refuse every redirect, read at most about 1 MiB and
  give up after a fixed total time. A redirect or an over-long answer counts as "answers, but
  not with a ComfyUI queue", for which the guard has a path already (idle, logged once, shown
  on the status page); a call that runs out of time counts as busy, as a timeout does today.
  Its calls to Ollama stay as they are. `tests/test_render_guard.py` gains the cases. What
  remains: a hostile ComfyUI can report "busy" for ever, which keeps chats on the CPU; the
  status page shows it and nothing stops it. While the container is the
  ComfyUI in use, `Stack\.env` carries `COMFYUI_URLS=http://comfy-door:8188` and the guard is
  recreated to read it; going back removes the line and the compose default applies again. The
  installer's `Write-StackEnv` keeps such a line across runs. With the door stopped the name
  does not resolve, which the guard already treats as "no ComfyUI there". Two things to mind.
  The integrity watch reports a changed `COMFYUI_URLS`. The switch must not answer that with a
  whole new baseline: `Save-LaiIntegrityBaseline` takes in whatever is there at that moment (its
  own comment says so) and would bless any other change along with it. The switch replaces the
  `COMFYUI_URLS` entry of the stored baseline and nothing else (a small function in
  `lib/LocalAI.psm1`, build item 8). And a line left behind after going back would hide a host
  ComfyUI from the guard (chats would then take VRAM from renders), so the health check gains
  the test audit item T6 asks for: when something answers on 8188 or 8000, the guard's status
  page must list it.
- **`Start-ComfyUI.ps1`:** a remembered choice in `localai-config.json` (host or container). In
  container mode, after its unchanged first step (unload Ollama, report VRAM), it starts the
  door and ComfyUI with `docker compose`, waits until the page answers and opens it in a browser
  profile of its own (next point).
  New switches: one for install mode, which says in a line what that means, and one each to
  change to the container and back. It refuses in plain words when Docker is not running, the
  image is not built, or the door's port is taken (a host ComfyUI still open). The shortcuts
  stay as they are: they run this script.
- **A browser profile for the page (part of `Start-ComfyUI.ps1`).** Edge or Chrome is started
  with a profile folder of its own and a proxy setting under which only ComfyUI's address can be
  reached. In that window a hostile page script reaches neither the internet nor Ollama, and no
  site the owner is signed in to shares the profile. To verify on the PC before anyone relies
  on it: that the setting covers the addresses of this PC (the browser leaves those out of a
  proxy unless told otherwise; the writer's knowledge), that the browser's direct connections
  (WebRTC) do not go around it, and that ComfyUI's page loads completely without the internet.
  It covers that one window. The same address in his everyday browser, or on the phone, is as
  open as today.
- **`Release-GPU.ps1`: no change.** It frees Ollama's VRAM for ComfyUI, wherever ComfyUI runs.
- **Gaming mode (`Stop-LocalAI.ps1`):** one more step that stops the ComfyUI container and the
  door by name, so a game gets their VRAM and RAM. It is written out, not left to
  `docker compose stop`: the ComfyUI services sit behind a compose profile that `Stack\.env`
  does not switch on (otherwise *Start again* would start ComfyUI every time), and whether
  `stop` reaches such a service was not checked. A render in progress is cut off, as Gaming mode
  intends. Today Gaming mode leaves a host ComfyUI running, so this is a gain.
- **"Which program uses the GPU":** `Get-LaiGpuApps` asks nvidia-smi for process names, and the
  nightly model re-check skips its run when another program is listed. A process inside WSL may
  not be listed on Windows (low confidence:
  https://forums.developer.nvidia.com/t/nvml-problems-for-windows-not-available-in-wddm-driver-model/77557).
  Until that is seen on the PC, a running ComfyUI container has to count as "GPU busy" by itself.
- **`Test-PCSecurity.ps1`:** its two ComfyUI checks read `custom_nodes` and `models` from
  Windows folders. From the first day of stage 1 the nodes that run live in a volume, so the
  node check would list the old Windows folder and pass, whatever install mode added: a false
  all-clear. This is therefore part of stage 1 (build item 8). In container mode the checks read
  the volumes (`comfyui-nodes`; for pickle files also `comfyui-cache`, where nodes keep their
  own downloads, and `comfyui-models` once it exists) through a short-lived container that has
  them read-only and no network. When they cannot (Docker is not running) they say "not
  checked: the nodes live in the container" as a warning, never as a pass.
- **`Watch-LocalAI.ps1`: no change.** It watches Open WebUI, SearXNG, the render guard and deep
  research; a ComfyUI that runs on demand is correctly none of its business.
- **Installer and uninstaller** (the integrator's files): copy the three new stack folders;
  remove the containers and the image, keep the volumes unless `-RemoveData`. `comfyui-models`
  is never part of `-RemoveData`: after a stage 2 move it holds the only copy of the models. It
  gets a switch of its own that names the size and asks for a typed confirmation, which `-Force`
  does not give.

## Speed, VRAM and memory: what is known
- **Rendering.** No like-for-like ComfyUI measurement was found (same card, Windows against a
  WSL 2 container). The nearest: NVIDIA, 2021, CUDA in WSL 2 against Linux on one machine,
  within 1% for a long render (Blender) and at least 90% in the worst case of many tiny jobs
  (https://developer.nvidia.com/blog/leveling-up-cuda-performance-on-wsl2-with-new-enhancements).
  A 2025 PyTorch run on an RTX 5090 found small differences between Windows, WSL and Linux in
  training and larger ones in some inference tests, on image-classification models, not
  diffusion (https://github.com/MatrixSP/pytorch-gpu-benchmark). Expectation: the same within a
  few percent, at worst about 10% slower. Not measured for this owner's workflows.
- **Loading models from a Windows folder** is the slow path. Reports, each from one user: under
  50 MB/s (https://github.com/YanWenKun/ComfyUI-Docker/issues/43); a first render of over 5
  minutes and 120 s afterwards from a Windows folder, against 70 s and 50 s from inside WSL, on
  an RTX 4090 (https://github.com/mmartial/ComfyUI-Nvidia-Docker/issues/82). At 50 MB/s a 14 GB
  model file takes about 5 minutes to read. **From a named volume:** one measurement of writing
  gives 850 MB/s there against 125 MB/s on the Windows path (the brainwagon page above); no
  measurement of reading was found. Expectation: close to today.
- **VRAM.** There is no separate pool and no cap. The Windows host's video memory manager serves
  the container's requests beside those of Windows programs (the Microsoft page above), and
  `.wslconfig` has no VRAM setting (https://learn.microsoft.com/en-us/windows/wsl/wsl-config).
  Ollama and the container draw on the same 24 GB as today, and the render guard is needed just
  as today. Not established: whether a full card ends in an error or in the silent spill into
  system RAM that the driver does for Windows programs, and what the pass-through itself takes.
- **RAM: the real cost.** Today ComfyUI and Ollama share the PC's RAM freely. In Docker, ComfyUI
  gets what the WSL VM may use: half the PC's RAM by default (same page), and 16 GB on this
  toolkit's installs with more than 32 GB. Video workflows keep tens of GB of model data in RAM
  (estimate; Task Manager during the heaviest render shows the real figure). The limit in
  `%USERPROFILE%\.wslconfig` has to rise to that figure plus room for the other containers, and
  Windows cannot use that RAM while the VM does (`autoMemoryReclaim=gradual`, which the
  installer sets, hands unused cache back). The render guard's CPU mode needs about 31 GB of
  Windows RAM for Uncensored Main (README). On a 64 GB PC a 40 GB VM leaves 24 GB, so a chat
  with Main during a render would page to disk; on 32 GB video work is not expected to fit.
  Those two statements are arithmetic on the README's figure, not measurements.
- **Starting.** Docker needs a few seconds to start a container (estimate, not measured), and
  Docker Desktop must be running: it is whenever the stack is, but after Gaming mode with
  `-QuitDocker` it has to start first.
- **Disk.** The image about 8 GB (estimate from the size of PyTorch's CUDA packages; the build
  prints the real figure), node packages 1 to 5 GB (estimate), models the same in total. Docker's
  disk file grows when models move in and does not shrink by itself when they move out.

## Taking over the existing ComfyUI, and going back
**Stage 1: beside the existing install. Nothing of the owner's is moved or changed.**
1. Checks 1 to 3 in "Your decision" pass (the card, the fence, the memory).
2. The security check shows Docker Desktop 4.44.3 or newer; Windows Update and the NVIDIA driver
   are current.
3. The `memory=` line in `.wslconfig` is raised (the old line stays as a comment for the way
   back) and Docker Desktop is restarted.
4. The image is built on the PC.
5. The start script changes to the container. It finds the existing ComfyUI folder the way
   `Start-ComfyUI.ps1` and the security check already do (the remembered `ComfyUIPath`, Comfy
   Desktop's `basePath`, the usual folders), mounts its `models` read-only and its `input`
   and `output` writable, creates the `comfyui-user` volume and copies his workflow files into
   it, notes the port for the door, writes the `COMFYUI_URLS` line, recreates the guard and
   starts ComfyUI without custom nodes.
6. The take-over script copies `custom_nodes` into the volume (without `__pycache__`), installs
   each node's requirements in install mode and prints one line per node: works, or failed and
   why. The Windows copy is not touched.
7. The owner renders his own workflows and times them (list under "only the PC").

**Going back from stage 1:** close ComfyUI and change the start script back. It stops the
containers, removes the `COMFYUI_URLS` line and recreates the guard. The host install was never
changed, and no folder it loads code or settings from was ever handed to the container: `user`
was never mounted and `models` only read-only, so there is nothing to restore. `input` and
`output` were shared; the host ComfyUI reads what is in them as pictures. Workflows saved in the
container come back as `.json` files on request (see "Where things live"). To remove every
trace: delete the image, the volumes `comfyui-nodes`, `comfyui-venv`, `comfyui-cache`,
`comfyui-user` and `comfyui-manager` and the browser profile folder, and put the old `memory=`
line back.

**Stage 2: only if loading from the Windows folder is too slow.**
8. Models move into `comfyui-models` one file at a time: copy, compare size and SHA-256, only
   then delete the Windows original. Free space needed: the largest single file plus a margin,
   never the whole library. A switch moves only the folders named. An interrupted run goes on
   where it stopped, and no original is deleted after a failed comparison. Before it starts it
   checks the free space on the drive that holds Docker's disk file; when the models are on
   another drive, either Docker's disk file moves there first (Docker Desktop > Settings >
   Resources) or only part of the library is moved.

**After a move the only copy of a moved model is inside Docker's disk file,** and no backup of
the toolkit covers it. Docker Desktop's "Clean / Purge data", a reset to factory settings,
removing Docker Desktop or a command that deletes the volume takes the models with it (the
reviewer's and the writer's knowledge of Docker Desktop, not verified here). The toolkit's own
uninstaller does not, without the separate switch. Most models can be downloaded again; ones
the owner trained or merged cannot, so the move takes named folders and those stay on Windows.

**Going back from stage 2:** the same script moves the files out again in the same careful way,
which takes as long as the move in. Until then the host install lacks the moved models. Docker's
disk file keeps its size until it is compacted (the exact step was not verified).

## What CI can prove, and what only the PC can
**CI, without a GPU:**
- the static rules COMPOSESEC and COMPOSELOG on the new services (they apply as soon as the
  services are in the compose file);
- the image builds from the pins alone; a package without a hash stops the build;
- ComfyUI started with `--cpu` in the hardened container: user, no capabilities, read-only root
  and limits read back from Docker and from the kernel, as the stack smoke test does for the
  other services; the mount table shows only the expected writable places; it answers the three
  calls the guard makes (`/queue`, `/system_stats`, `POST /free`);
- from inside the ComfyUI container: no outside name resolves, no outside address answers, the
  host, the render guard, Open WebUI and SearXNG cannot be reached; the door passes a page and a
  websocket both ways and is published on 127.0.0.1 only;
- the guard's status page lists the ComfyUI behind the door;
- the door's own test (a closed far end, a client that stops, many connections at once);
- the gate's own test: a listed site passes; an unlisted site, another port and Ollama's address
  are refused; from inside install mode nothing but the gate and the door answers;
- the guard's test: a redirect from ComfyUI is not followed, an over-long answer is cut off;
- the security check against stand-in volumes: it lists a node that exists only in the volume,
  and says "not checked" when Docker does not answer;
- the start script and Gaming mode against a fake `docker` on PATH: the commands sent, the
  `.env` line written and removed, each refusal;
- the take-over script on stand-in folders: no original deleted before its copy compared equal,
  an interrupted move goes on, the way back.

CI runs Docker Engine on Linux, not Docker Desktop on Windows: what differs there (reaching the
host, Windows folders, the internal network) is only shown on the PC.

**Only the PC:**
- the card is visible in the hardened container (check 1, then the real image:
  `/system_stats` names the RTX 3090 with its 24 GB);
- speed: his own workflow three times each way (seconds per picture or clip); the first and the
  second load of his largest model, from the Windows folder and from the volume;
- the VRAM hand-over: after `POST /free` the VRAM Windows reports drops; a chat during a render
  runs on the CPU; afterwards the chat model loads fully onto the GPU; what a full card does;
- RAM: the peak of his heaviest workflow against the limit, with Windows still usable;
- Docker Desktop itself: 8188 cannot be reached from another device (the security check tests
  listeners), and the inner network reaches neither `host.docker.internal` nor Docker's own
  addresses;
- his nodes: which install and run on Linux, offline and read-only; his workflows open;
- the Windows folders can be written by uid 10001 and the pictures show up in Explorer;
- the phone: Open WebUI's picture button still makes a picture; his own link, if he has one;
- the page: in the window the start script opens, `fetch('http://127.0.0.1:11434/api/tags')`
  typed into the page's console (F12) must fail, and so must a fetch of an outside address. The
  same line in his everyday browser shows what a page script can do with Ollama today;
- Gaming mode gives back ComfyUI's VRAM too; the container survives sleep and wake.

## Cheaper ways to get part of it
- **Care, and the check that exists (free).** Few nodes, known authors, `.safetensors` only.
  The security check lists the nodes and the pickle files. Lowers the odds, fences nothing.
- **A firewall rule that blocks ComfyUI's Python from the internet.** Windows Firewall works on
  Home; a block rule wins over allow rules; a program rule needs the full path of the exe
  (https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules).
  A simple thief cannot send out what it read. The rule covers that one program file: a node
  can start `powershell.exe` or `curl.exe` (inference). It is switched off for installs. It
  stops no reading, changing or encrypting of files.
- **A separate Windows account that only runs ComfyUI.** A profile folder can be read by its
  owner, SYSTEM and Administrators only
  (https://learn.microsoft.com/en-us/answers/questions/1203486/permission-to-access-the-profile-of-other-users-re),
  and `C:\AI\Secrets` is locked the same way, so a node there reaches neither the owner's
  documents nor his saved passwords. Full speed; models and nodes stay as they are. It can still
  read whatever is not locked, reach programs that listen on this PC only, and use the internet
  unless a rule tied to the account blocks it (`-LocalUser`, not verified for block rules:
  https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule). **The
  two belong together:** a block rule for the account covers every program the account starts,
  which closes the `powershell.exe` and `curl.exe` gap of the program rule above. Connections
  that stay on this PC are not filtered (the writer's knowledge of Windows Firewall), so Ollama
  stays reachable, and the page in the browser is as open as with the container. Not found:
  whether the card works for a process started as a second account; check 4 in "Your decision"
  tests the start the toolkit would use (a second sign-in inside the owner's session). Not
  designed here: where ComfyUI has to live so that the account can read it (not inside the
  owner's profile) and how the start script signs in as it. "Your decision" sets the pair
  beside the container in a table.
- **Controlled folder access** (row 86 (5)) keeps programs that are not on its list from
  changing Documents, Pictures and Desktop: against encrypting, not against reading. If ComfyUI
  is put on that list, every node is on it too. Worth settling in that item.
- **Not available or not shown to work:** Windows Sandbox is not offered on Windows 11 Home
  (https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview).
  For low-integrity processes, Win32 app isolation and Sandboxie no evidence was found that CUDA
  works in them, and a low-integrity process can still read files
  (https://learn.microsoft.com/en-us/windows/win32/secauthz/mandatory-integrity-control).

## Open questions
**Only the owner knows:**
1. How much RAM the PC has, and how much is in use during his heaviest render.
2. Comfy Desktop or the portable build.
3. How large the `models` folder is, on which drive, and how much is free on Docker's drive.
4. Which nodes he uses, and whether a workflow calls Ollama or an online service from inside
   ComfyUI (that cannot work without a network).
5. Whether he opens ComfyUI's own page from the phone, or only makes pictures through Open
   WebUI.
6. How often he adds nodes or models: that is how often install mode is in his way.
7. Which address Open WebUI's picture setting holds, if he connected ComfyUI there, and how his
   phone link to ComfyUI's page was made, if he has one.

**Not verified; the PC tests decide:**
- the card in a locked-down container on Docker Desktop, and whether the `/usr/lib/wsl` mount or
  a step after driver updates is needed;
- the inner network on Docker Desktop: no host, no Docker addresses, no outside names;
- `127.0.0.1:` publishing on Docker Desktop for Windows. An old thread (2015) says it did not
  hold there; Docker's current page says it does
  (https://docs.docker.com/get-started/docker-concepts/running-containers/publishing-ports/).
  The stack relies on it for three ports already;
- VRAM: a full card, the cost of the pass-through, and whether nvidia-smi on Windows names the
  container's process;
- ComfyUI at the pinned release: its start options, what `POST /free` does (only third-party
  descriptions were read; the guard sends it today), how Manager behaves offline, whether the
  page loads without the internet, and what ComfyUI, Manager and Comfy Desktop load from `user`
  when they start;
- the page in the browser: whether Ollama answers a page served from `127.0.0.1:8188` (if it
  does, setting `OLLAMA_ORIGINS` is worth an item of its own, container or not), and whether a
  browser profile with a proxy setting really leaves only ComfyUI's address reachable;
- Open WebUI's picture client: what it does with a redirect or an endless answer from ComfyUI,
  and whether `host.docker.internal:<port>` reaches a port that Docker publishes on 127.0.0.1;
- the gate: which host names pip, git, the Hugging Face downloader and PyTorch's index really
  use; that an ordinary Docker Desktop network reaches the home network and the tailnet;
- the account: `-LocalUser` on a block rule, and the card for a second account (check 4);
- compose: the spelling of the GPU request; whether the installer's and the update script's
  `pull` and `up` trip over an image that exists on this PC only; what `stop` does to a profile
  that is switched off;
- whether CVE-2026-50382 or another graphics-kernel flaw can be reached from WSL 2.

## The build, in items
Nothing is built before the checks in "Your decision" have passed. The split follows the rules the batch
plans apply (they are not written down in the repository, so this is how they were read): an
item names every file it writes; no file belongs to two items of one batch; the README,
`IMPROVEMENTS.md`, the installer's copy list, the uninstaller, the static-check and suite lists
and the CI workflow are the integrator's.

Stage 1 (items 1, 2 and 6 to 8 in one batch, 3 to 5 in the next):
1. **comfyui-image:** `stack/comfyui/Dockerfile`, `stack/comfyui/requirements.lock`,
   `stack/comfyui/start.sh`, `tests/Invoke-ComfyImageTest.ps1`. The pinned build; the test
   builds it and runs ComfyUI with `--cpu` under the full hardening.
2. **comfy-door:** `stack/comfy-door/comfy_door.py`, `tests/test_comfy_door.py`.
3. **comfyui-compose:** `stack/docker-compose.yml`, `tests/Invoke-StackSmokeTest.ps1`. The
   services `comfyui`, `comfyui-install`, `comfy-door` and `comfy-gate`, the two internal
   networks, the door's port, the mounts item 1 found safe for `user`, and the network
   checks listed under CI.
4. **comfyui-start:** `Start-ComfyUI.ps1`, `Stop-LocalAI.ps1`, `tests/Invoke-ComfyStartTest.ps1`.
5. **comfyui-nodes-takeover:** `Move-ComfyUI.ps1`, `tests/Invoke-ComfyMoveTest.ps1`. Nodes, and
   the workflow copies in and out.
6. **render-guard-comfy-calls:** `stack/render-guard/render_guard.py`,
   `tests/test_render_guard.py`. No redirects, a size cap and a total time limit on the calls to
   ComfyUI. Useful without the container too.
7. **comfy-gate:** `stack/comfy-gate/comfy_gate.py`, `tests/test_comfy_gate.py`. The allow-list
   proxy for install mode.
8. **comfyui-checks:** `Test-PCSecurity.ps1`, `Test-LocalAI.ps1`, `lib/LocalAI.psm1`,
   `tests/Invoke-WindowsUnitTests.ps1`. The security check reads the volumes or says "not
   checked"; a running container counts as "GPU busy"; the health check's test from audit T6;
   the function that replaces one entry of the integrity baseline. Stage 1 is not handed to the
   owner without it.

Stage 2 (only after stage 1 was used on the PC):
9. **comfyui-models-move:** the same two files as item 5, with the move and the way back. Built
   only if loading from the Windows folder was too slow.
10. **comfyui-image-update:** `Update-ComfyUIImage.ps1` and its test. New pins, the old image
    kept, a way back. Every ComfyUI update after the first build goes through it.

Hand to the integrator with each: the copy list, the uninstaller (with the separate switch for
`comfyui-models`), the lists of the static checks
and of the test runner, a workflow step that builds the image before the `stack` job, a
Start-menu entry for install mode, the README, and a backlog row for item 7 of row 86.

## Your decision
**The question.** Should ComfyUI run inside a locked box (a container) instead of directly on
Windows as you? Build it, build a smaller fence instead, later, or no.

**Two things only you know, which change what follows.** Please answer them with your decision.
- Do you use Comfy Desktop (its own window) or the portable build (a folder with
  `run_nvidia_gpu.bat`)? Desktop answers on port 8000, the portable build on 8188.
- Do you open ComfyUI's own page from your phone, and if so, how was that link made? And did you
  connect ComfyUI to Open WebUI's picture button (Admin Panel > Settings > Images)?

**What you get.** Picture a custom node, or a model file, that turns out to be hostile.
- *Today* it runs as you. It can read every file you can (documents, the passwords your browser
  saved, `C:\AI\Secrets`), change or encrypt them, make itself start with Windows, and send
  anything out over the internet.
- *In the container* it sees ComfyUI's own files, the nodes and your models, all read-only, and
  can write only your input and output folders and the box's own copy of your saved workflows.
  By design it has no network of its own: no internet, no Windows, no Ollama, no Open WebUI.
  That is what Docker promises; on your PC it is not proven yet, and check 2 below proves it or
  stops the plan. The worst it can then do: read your models and your pictures, spoil or delete
  what is in input and output, leave a file in output that you might open, keep the graphics
  card busy, and make chats slow by telling the toolkit that a render is running.
- *One hole the container does not close: ComfyUI's page in your browser.* A hostile node can
  put script into that page. The script runs in your browser, which has the internet, so it can
  send out the pictures and workflows the box can read, and it can use Ollama (list, delete and
  download models; my knowledge of Ollama's defaults, not tested here). This is the same today.
  The plan has the start script open ComfyUI in a browser window of its own that reaches nothing
  else, which should close the hole on the PC (not verified). Your phone's browser, and a tab in
  your everyday browser, stay as open as today.
- *While you install or update nodes* ("install mode") it can change node code and reach four
  download sites (PyPI, GitHub, Hugging Face, PyTorch) and nothing else. Those sites also take
  uploads, so what it read earlier can leave at that moment. It still sees none of your other
  Windows files.
- *Not covered:* an attacker who also has a way to break out of Docker. Such ways have existed;
  the known ones are fixed in Docker Desktop 4.44.3 and newer, and new ones can appear. A
  break-out ends where a node starts today, as you on Windows, so the container is never worse
  than now.

**What it costs you.**
- *Once:* the checks below; raising the memory Docker may use; about half an hour
  while the PC builds the image, with about 8 GB to download (both estimates, not measured); one
  run of a script that installs your nodes again for Linux and lists the ones that fail. Your models
  stay where they are. Only if loading them proves too slow are they moved into Docker's disk,
  one file at a time, never as a second full copy. **After such a move the only copy of those
  models is inside Docker.** Docker Desktop's "Clean / Purge data", a reset or a reinstall
  deletes them, and no backup of this toolkit covers them. The toolkit's own uninstaller will
  not delete them without a separate switch that asks you first. Models you made yourself
  should stay on Windows.
- *Disk:* about 8 GB for the image and 1 to 5 GB for node packages (estimates).
- *Speed:* rendering should be the same within a few percent, at worst about 10% slower. That
  rests on NVIDIA's 2021 measurements of this technique against Linux; nobody has published a
  ComfyUI comparison, so only your own render, timed both ways, settles it. Loading a model from
  a Windows folder is slow (users report under 50 MB/s: about 5 minutes for a 14 GB file); from
  Docker's own disk it should be close to today (not measured). Starting takes a few seconds
  longer (estimate).
- *Memory:* today ComfyUI and chats share the PC's RAM freely. A container gets a fixed share.
  With 64 GB, a share big enough for video work leaves too little to chat with Uncensored Main
  on the CPU during a render; with 32 GB I expect it not to fit (my arithmetic from the README's
  31 GB figure, not a measurement).
- *Day to day:* the same Start-menu entry starts it. It opens in a browser window of its own, at
  the address you use today: http://127.0.0.1:8188 with the portable build, http://127.0.0.1:8000
  with Comfy Desktop (the Comfy Desktop window itself is no longer used). The phone: the toolkit
  puts only Open WebUI on Tailscale, and that does not change. A link of your own to ComfyUI's
  page keeps working only if it was made with `tailscale serve` pointing at that address. A link
  that works because ComfyUI itself listens on the network (`--listen`) stops, and the Security
  check counts that kind as a failure already. Open WebUI's picture button may need its address
  typed in again, once. To add or update a node you start "install mode", then start normally
  again. Your saved workflows are copied into the box; ones you save there come back to Windows
  when you ask the script for them. Some nodes will stop
  working: Windows-only ones, ones that call Ollama or an online service while rendering, ones
  that write into their own folder on every run. A saved workflow may ask you to pick its model
  again once. Updating ComfyUI is no longer a click: every update is a new build that has to be
  prepared in the toolkit first and then takes the PC about half an hour again (estimate). Until
  then you stay on the old version.

**What could go wrong, and the way back.** The graphics card may not work in a locked-down
container on this PC; renders may be slower; a node you rely on may not survive. Until models
are moved, your current ComfyUI is not changed at all, and its settings folder is never handed
to the box, so the box can leave nothing behind that starts by itself on Windows. Going back is
one switch on the start script; deleting the image and the Docker volumes and putting the
memory setting back removes every trace. After a move, the same script moves the models back,
which takes as long as the move did.

**Cheaper alternatives.**
- *Care, and the check you already have (free, today):* few nodes, known authors,
  `.safetensors` only; the Security check lists your nodes and risky model files. Lowers the
  odds, fences nothing.
- *A firewall rule that keeps ComfyUI's Python off the internet* (small build): a simple thief
  cannot send your files out. It does not stop reading, changing or encrypting them, and a
  careful attacker starts another program the rule does not cover.
- *A separate Windows account that only runs ComfyUI* (medium build; full speed, models and
  nodes stay as they are): Windows itself then keeps it out of your documents and saved
  passwords. With a block rule tied to that account it also cannot send anything out by itself
  (not verified for this kind of rule). Not proven: that the graphics card works for a second
  account; check 4 below tests it.
- *Windows Sandbox* is not available on Windows 11 Home.

**Side by side.** What a hostile node or model file can do under each of the three:

| It can ... | Today | Own Windows account + block rule | Container |
|---|---|---|---|
| read your documents, saved passwords, `C:\AI\Secrets` | yes | no | no |
| read your models and pictures | yes | yes | yes |
| change, delete or encrypt files | all of yours | ComfyUI's folders, and folders open to every account | input, output, its copy of your workflows |
| send data out by itself | yes | no if the rule holds (not verified); yes while you install nodes | no (check 2); to four sites while you install nodes |
| send data out through ComfyUI's page | yes | yes | not from the window the start script opens (not verified); yes from the phone |
| use Ollama, which has no login | yes | yes | not by itself (check 2); through the page as in the row above |
| stay after a restart | yes, anywhere in Windows | yes, in ComfyUI's folders | only a node you installed; code from a model file does not |
| get past the fence with | nothing | a flaw in Windows | a flaw in Docker, WSL or the graphics driver |
| speed and memory | as now | as now | a few % slower (expected), a fixed share of RAM |
| work | none | medium build, needs a short plan of its own | 8 build items, nodes installed again, every update a new build |

**My recommendation: later, and four short checks decide what gets built.** Do not start a
build today. The container fences more and costs more: eight build items, a fixed share of your
RAM, your nodes installed again, every ComfyUI update a new build. The separate account with a
block rule also takes your documents and passwords out of a hostile node's reach, at full speed
and with nothing moved, but it leaves Ollama reachable and node code changeable. Whether either
works on this PC is not known, so the checks come first. Waiting holds nothing up: two items of
the security track, (4) and (5), are still ahead of this one. The command lines below were
written for this plan and not run; if one prints something other than what is described here,
send me the output.

*Check 1, the card in a locked box (ten minutes).* Paste into PowerShell. The first line
downloads NVIDIA's test image, the one Docker's own GPU page names, and runs it locked down and
without any network. It should name your RTX 3090 and print a speed figure. The second line
prints the image's fingerprint, which I could not look up from here; keep it with the result.

```
docker run --rm -it --gpus=all --cap-drop=ALL --security-opt=no-new-privileges --user 10001:10001 --read-only --network none nvcr.io/nvidia/k8s/cuda-sample:nbody nbody -gpu -benchmark
docker image inspect --format "{{index .RepoDigests 0}}" nvcr.io/nvidia/k8s/cuda-sample:nbody
```

Only if the first line failed, run it once without the locks (still without a network), to see
whether the card works in a container at all:

```
docker run --rm -it --gpus=all --network none nvcr.io/nvidia/k8s/cuda-sample:nbody nbody -gpu -benchmark
```

Then remove the image:

```
docker image rm nvcr.io/nvidia/k8s/cuda-sample:nbody
```

*Check 2, the fence (five minutes; downloads nothing).* With the AI stack running, paste these
one after the other into the same PowerShell window. They make a test network of the kind the
plan relies on, try five ways out of it from a small container, and remove it again. The five
are: Ollama on Windows, Docker's own control address, the network's gateway, an internet
address and an internet name. Each line may take up to half a minute.

```
$img = docker inspect --format "{{.Config.Image}}" render-guard
$probe = "import socket,sys; sys.excepthook=lambda t,e,tb: print('blocked:', e); a=socket.gethostbyname(sys.argv[1]); print('address', a); socket.create_connection((a, int(sys.argv[2])), 5); print('REACHED', sys.argv[1])"
docker network create --internal --subnet 172.31.250.0/24 comfy-probe
docker run --rm --network comfy-probe --entrypoint python3 $img -c $probe host.docker.internal 11434
docker run --rm --network comfy-probe --entrypoint python3 $img -c $probe 192.168.65.7 2375
docker run --rm --network comfy-probe --entrypoint python3 $img -c $probe 172.31.250.1 2375
docker run --rm --network comfy-probe --entrypoint python3 $img -c $probe 1.1.1.1 443
docker run --rm --network comfy-probe --entrypoint python3 $img -c $probe example.com 443
docker network rm comfy-probe
```

It passes when each of the five ends in `blocked` and the last one prints no `address` line
first. A line that says `REACHED` means the fence leaks there.

*Check 3, memory.* In Task Manager > Performance > Memory, note the total, and "In use" during
your heaviest render. Rule of thumb (mine, not measured): it fits if at least 8 GB is still free
at that moment; chatting on the CPU during a render needs about 31 GB more.

*Check 4, the card for a second Windows account (ten minutes).* In a PowerShell window opened
with "Run as administrator". The first line makes a temporary Windows account and asks you to
invent a password for it (nothing shows while you type). The second asks for that password and
opens a black window that runs as the new account; its table should name the RTX 3090.

```
net user comfy-probe * /add
runas /noprofile /user:comfy-probe "cmd /k nvidia-smi"
```

With the portable build, type the next line into that black window, with FOLDER replaced by
your ComfyUI folder. It should print the card's name and 8.0. "Access is denied" means the new
account may not read that folder, which says nothing about the card: tell me. With Comfy
Desktop skip this line (its Python sits inside your own profile) and tell me what the table
showed.

```
"FOLDER\python_embeded\python.exe" -c "import torch; print(torch.cuda.get_device_name(0), torch.ones(8).cuda().sum().item())"
```

Close the black window and remove the account again:

```
net user comfy-probe /delete
```

What the results mean:
- **Check 4 passes: say "account".** I would build the separate account with the block rule
  first. It is the smaller build, costs no speed or memory, and takes your documents and
  passwords out of reach, which is the largest single gain in the table. It needs a short plan
  of its own; this document does not design it. The container can still follow later, if checks
  1 to 3 passed and you want what the table shows it adds.
- **Check 4 fails and checks 1 to 3 pass: say "build".** Stage 1 (eight items) puts the
  container beside your current ComfyUI without touching it. You try your own workflows for a
  week and only then decide about moving anything.
- **Check 4 fails, and check 1 fails even without the locks or the RAM does not fit: the answer
  is no.** Care, the Security check and item (5) of the security track are what is left.
- **In check 1 only the locked-down line fails, or check 2 does not pass:** send the output
  before deciding. One setting may be the cause, and the plan may be able to do without it.
