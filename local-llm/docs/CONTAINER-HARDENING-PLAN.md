# Container hardening (security track item 1): applied to the compose file and passed by the CI job `stack`; digests not started

Status (2026-10-07): the per-service hardening below is in `local-llm/stack/docker-compose.yml`,
with a static rule (COMPOSESEC) and checks in `tests/Invoke-StackSmokeTest.ps1` that fail when it
is missing or breaks a service. It was written on a PC where the stack may not be started; **the
first run on real containers, the CI job `stack`, passed on commit 8340532**. Every hardening
assertion against the real containers was OK: all capabilities dropped, no new privileges, the
memory and process limits, SearXNG as user 977 on a read-only root with a settings.yml dated 2020,
a 64 MB chat through the render guard, and no container killed or restarted. Those are Linux
containers on a CI machine, so what that job cannot see is still open, as are the digest plan
(not started) and the request body cap (being built): see "Still to do".

Evidence for the choices comes from the Open WebUI v0.11.4 source and Dockerfile, the SearXNG image
`searxng/searxng:2026.10.2-19ffbcd30` (inspected, not started) and the compose file.

## What each service runs with
Every service: `cap_drop: [ALL]`, `security_opt: ["no-new-privileges:true"]`, a `mem_limit`, a
`pids_limit`, and every published port bound to 127.0.0.1.

- **open-webui:** no capability added back, `mem_limit: 16g`, `pids_limit: 4096`.
  - Runs as root (Dockerfile `ARG UID=0`, `USER $UID:$GID`; /app and /root root-owned).
  - Needs no capabilities: `backend/start.sh` has no chown/su/setcap; the Python source has no
    `os.chown`/setuid/setgid; port 8080 needs no bind capability.
  - Not `read_only`: it rewrites `/app/backend/open_webui/static` at every start (config.py,
    about lines 100-145), pip-installs tool requirements into site-packages
    (`utils/plugin.py:441`) and uses tempfile.
  - 16g leaves room for the CPU embedder (bge-m3) and reranker (bge-reranker-v2-m3).
- **searxng:** `user: "977:977"`, `read_only: true`, `./searxng:/etc/searxng:ro`, a tmpfs on `/tmp`
  (256m) and on `/var/cache/searxng` (64m, owned by 977), both `noexec,nosuid,nodev`,
  `mem_limit: 2g`, `pids_limit: 512`.
  - Before, it ran as root (no USER in the image). `entrypoint.sh` chowns /etc/searxng and
    /var/cache/searxng and runs update-ca-certificates only as root, then starts granian as root.
  - As 977 the chown is skipped (a warning in the log) and so is the CA update; settings are copied
    only when settings.yml is missing, and the installer always writes it first.
  - That reading does not say what the entrypoint does when settings.yml is there but older than
    the image, which is the state of every existing install after a SearXNG update (the installer
    writes the file once). A start script may then want to put its newer settings beside the old
    file, into a folder that is now read-only. It was not read from the image; the stack smoke
    test starts SearXNG in exactly that state and decides it (see "What checks it"). The CI job
    `stack` did so on 8340532 and passed: SearXNG as user 977 on a read-only root with a
    settings.yml dated 2020.
  - Runtime writes go only to /tmp (SQLite caches sxng_cache_*.db and faviconcache.db:
    searx/cache.py, favicons/cache.py).
  - `read_only` covers the image's own files, not a folder the image declares as a volume: Docker
    mounts a writable volume there (no size limit, programs can be run from it, kept across
    restarts) unless the compose file mounts something else. /etc/searxng is the bind mount;
    /var/cache/searxng, the image's data folder, gets the tmpfs (nothing is written there with the
    toolkit's settings). Whether the image declares either as a volume was not read from it: the
    tmpfs is right both ways, and the smoke test reads the kernel's mount table.
- **render-guard:** already had user `65534:65534`, `read_only`, `cap_drop: [ALL]` and
  `no-new-privileges`; now also `mem_limit: 2g`, `pids_limit: 512`.
  - One thread per request plus a watcher; it writes no files.
  - The memory limit is for the requests. `render_guard.py` reads every request body whole into
    memory before it passes it on (`_read_body`), and for /api/chat and /api/generate it also
    decodes and parses it, and writes it out again when it changes the request: about three
    copies at the peak, about five when it rewrites. A chat with pictures carries all of them
    again at every turn. 2g holds a chat of several hundred MB. The handover's 512m did not
    count the bodies.
  - Known limit: a request the limit cannot hold ends the guard (Docker restarts it; the chats
    running through it are cut off). That is any body near 2 GB on a path the guard does not
    parse, for example a model file sent to Ollama's /api/blobs through the guard. Before the
    limit such a request was bounded only by the Docker VM's memory. The cure is in the guard,
    not in the limit: see "Still to do".
  - It runs from the SearXNG image, so it would carry that image's volumes too, if the image
    declares any. The compose file mounts nothing over them for the guard: the smoke test checks
    instead that the guard's user (65534) can write nowhere outside /dev.
- **deep-research** (compose profile `research`, enabled through `COMPOSE_PROFILES` in Stack\.env):
  already had `cap_drop: [ALL]` plus CHOWN, FOWNER, DAC_OVERRIDE, SETUID, SETGID, and
  `no-new-privileges` (its image drops privileges with `setpriv`, which works under
  no-new-privileges); now also `mem_limit: 8g`, `pids_limit: 2048`. Not `read_only` (write paths
  not verified).

An existing install gets this the next time `Install-LocalAI.ps1` runs: it copies the compose file
into Stack and runs `docker compose up`, which recreates the containers whose settings changed.
The line `searxng/searxng:${SEARXNG_VERSION:-...}` is unchanged: `Invoke-UpdateWebUITest.ps1`
matches it with a regex.

## What checks it
- **Static check, rule COMPOSESEC** (`Find-ComposeSecGap` in `tests/Invoke-StaticChecks.ps1`, both
  CI jobs): a service in the compose file without no-new-privileges, `cap_drop` ALL, a `mem_limit`
  or a `pids_limit`, or with a published port not bound to 127.0.0.1, is a problem. So is a line
  that hands it all back while those keys are still there: `privileged` (anything but false),
  ALL under `cap_add`, a `<<:` merge or an `extends` key at the service's own level (they could
  bring in `privileged` or `ports` from an anchor or a service the check does not follow), or a
  line at the service's own level the check cannot read as `key: value` (a quoted key, a space
  before the colon: it could be one of those keys written another way). It reads only what is
  written out in the service's own block: a flow mapping or a `${VARIABLE}` for a limit does not
  satisfy it. Its
  canaries take one thing at a time away from a hardened service, or add one such line, and
  require exactly that gap to be reported.
- **Stack smoke test** (`tests/Invoke-StackSmokeTest.ps1`, CI job `stack`, real images):
  - per service, from `docker inspect` with a format template: no-new-privileges, ALL dropped and
    only the listed capabilities added back, the memory and pids limits, the read-only root and
    the user where the service has them;
  - per service, from the kernel inside the container: `NoNewPrivs` is 1 and the capability
    bounding set is exactly the added capabilities (/proc/self/status of a process started there),
    PID 1 holds no capability outside that set, and PID 1 of searxng and render-guard is not root;
  - searxng and render-guard (the services with a read-only root), from the kernel's mount table
    inside the container: every read-write mount outside /proc, /sys and /dev is tried as the
    service's user. searxng may be able to write only to /tmp and /var/cache/searxng, each a
    tmpfs with a size limit and noexec; render-guard nowhere outside /dev. A volume the image
    declares and the compose file does not cover fails this. The mounts under /dev are not tried:
    Docker's own /dev/shm (a tmpfs of 64 MB, mounted noexec, gone at a restart, its pages counted
    against the memory limit) could take a file from a service that was taken over, but not a
    program that can be run. A later `shm_size:` or `ipc: host` line would change that mount and
    this test would not notice;
  - Open WebUI, with no capability at all, starts, makes the admin account from .env, signs it in
    and reaches Ollama through the render guard;
  - SearXNG is started with a settings.yml dated 2020, as old as an existing install's, and the
    test checks that the container sees that date (it also prints the date of the settings.yml
    that came with the image). In that state it answers /healthz and a JSON search as uid 977
    with `/` and /etc/searxng mounted read-only and /tmp a writable tmpfs, and its log names no
    file it could not write and no missing privilege (the entrypoint's ownership warning is
    expected; what single search engines answer is not judged, they often refuse a test
    machine). A start script that tried to write beside the old settings.yml would fail here;
  - the render guard reaches Ollama, then passes on a chat with 64 MB of pictures, sent from the
    Open WebUI container, and Ollama's answer comes back; the guard is not ended for it and the
    test prints the most memory it held. This shows a real request body under the limit; it does
    not show where the limit is reached;
  - deep research reaches Ollama through the guard under its limits;
  - after all of that every container is still running, was never ended for exceeding its memory
    limit and never restarted.
- The CI jobs `integration`, `installer` and `webui-update` start SearXNG from the same compose file,
  so their web-search checks also run against the hardened SearXNG. They mount the repository's own
  `stack/searxng` folder (the template `settings.yml`, dated by the checkout, so newer than the
  image's) read-only; the job step makes the folder readable for user 977 first and stops with
  SearXNG's log when it does not answer.

## Deliberately not applied
- **CPU limits:** a `cpus` value above the Docker VM's CPU count stops the container from being
  created, and that count is not known. Memory and pids limits cover runaway use.
- **Internal networks:** none of the services can go internal-only. Open WebUI must reach
  `host.docker.internal:11434` (installer probe and fallback); render-guard, SearXNG and deep
  research need the host or the internet. On Docker Desktop every container can also reach every
  host service bound to 127.0.0.1, so splitting networks gains little.
- **Image digests in the image lines:** does not fit the current flow. Windows cannot set an empty
  environment variable for one process, so `Invoke-PullFirst` could not blank a stale digest while
  pulling a new tag; and `Get-RunningTag`, the image cleanup in `Update-OpenWebUI.ps1` and the
  backup's check image all assume `repo:tag`.

## Still to do
- **Request bodies in the render guard** (`stack/render-guard/render_guard.py`), in progress (it
  is being built as its own change and is not in yet): pass the body of a path it does not rewrite
  straight through instead of reading it whole, or answer 413 above a size. Until it is in, a
  request too big for the guard's memory limit ends the guard.
- **By hand on a real install** (the smoke test has no browser and no model): upload a document
  (embedding and reranking), run a web search from a chat, save the skill notebook tool (that path
  runs pip install), and run one deep research report, all with the hardening on.
- **The digest plan** below.

## Digest plan (not started)
1. Record and verify without changing what runs. New module helpers:
   - `Get-LaiComposeImages`: reads the compose `image:` lines and resolves `${VAR:-default}`.
   - `Get-LaiImageDigest`: `docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}'`,
     picking the digest for the image's own repo.
   - a pure comparison function.
2. Store and warn. Keep `IMAGE_DIGESTS=repo:tag@sha256:...,...` in Stack\.env and record each tag
   the first time it is pulled; skip floating tags (anything `Get-LaiPullPolicy` always re-pulls).
   If a recorded tag later has a different digest, keep the recorded one and warn loudly on every
   run (deleting the line accepts the new image). Call it after `compose pull` in the installer's
   Stack stage (warnings into the install report) and after `Invoke-PullFirst` in the update
   script. The installer mock mocks compose but sends other docker calls to real Docker, so a
   missing image is skipped.
3. Then enforce: `image: ...:${OPEN_WEBUI_PIN:-${OPEN_WEBUI_VERSION:-v0.11.4}}`, the same for
   SearXNG and deep research. `Invoke-PullFirst` sets the pin to the new tag (never empty); every
   `.env` writer (`Set-EnvVersion`, `Write-StackEnv`) sets version and pin together;
   `Get-RunningTag` and the image cleanup strip `@sha256:` first.

## Verify on real containers
What the handover asked to be verified once applied, and where each item stands:
1. Open WebUI starts with no capabilities: sign in, upload a document (embedding and reranking),
   run a web search, save the skill notebook tool (that path runs pip install).
   *Start and sign-in: stack smoke test. The rest: by hand, see "Still to do".*
2. SearXNG as 977 reads settings.yml from a Windows bind mount and answers searches on a
   read-only filesystem; its log shows only the expected ownership warning.
   *Stack smoke test, on a Linux bind mount, with a settings.yml older than the image. A Windows
   bind mount (Docker Desktop): by hand; the render guard already reads its script that way
   (`./render-guard:/guard:ro`, user 65534).*
3. render-guard and deep research still work under their memory and pids limits.
   *Stack smoke test: both reach Ollama, the guard passes on a chat with 64 MB of pictures, and
   none is ended or restarted. A full research run: by hand.*
4. `docker compose config` accepts the new keys. *Stack smoke test (it runs `config` first).*
5. The full suite passes, including the update test and the installer mock run. *CI.*
