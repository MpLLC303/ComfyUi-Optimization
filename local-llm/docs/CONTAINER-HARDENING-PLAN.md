# Container hardening (security track item 1): applied to the compose file; digests not started

Status (2026-10-07): the per-service hardening below is in `local-llm/stack/docker-compose.yml`,
with a static rule (COMPOSESEC) and checks in `tests/Invoke-StackSmokeTest.ps1` that fail when it
is missing or breaks a service. It was written on a PC where the stack may not be started, so
**the first run on real containers is the CI job `stack`**: until that job has passed on this
change, nothing here is proven on running containers. The digest plan is not started. What is
still open is listed under "Still to do".

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
- **searxng:** `user: "977:977"`, `read_only: true`, `tmpfs: ["/tmp:size=256m,mode=1777"]`,
  `./searxng:/etc/searxng:ro`, `mem_limit: 2g`, `pids_limit: 512`.
  - Before, it ran as root (no USER in the image). `entrypoint.sh` chowns /etc/searxng and
    /var/cache/searxng and runs update-ca-certificates only as root, then starts granian as root.
  - As 977 the chown is skipped (a warning in the log) and so is the CA update; settings are copied
    only when settings.yml is missing, and the installer always writes it first.
  - Runtime writes go only to /tmp (SQLite caches sxng_cache_*.db and faviconcache.db:
    searx/cache.py, favicons/cache.py).
- **render-guard:** already had user `65534:65534`, `read_only`, `cap_drop: [ALL]` and
  `no-new-privileges`; now also `mem_limit: 512m`, `pids_limit: 512` (one thread per request plus
  a watcher; writes no files).
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
  or a `pids_limit`, or with a published port not bound to 127.0.0.1, is a problem. It reads only
  what is written out in the service's own block: a `<<:` merge, a flow mapping or a `${VARIABLE}`
  for a limit does not satisfy it. Its canaries take one thing at a time away from a hardened
  service and require exactly that gap to be reported.
- **Stack smoke test** (`tests/Invoke-StackSmokeTest.ps1`, CI job `stack`, real images):
  - per service, from `docker inspect` with a format template: no-new-privileges, ALL dropped and
    only the listed capabilities added back, the memory and pids limits, the read-only root and
    the user where the service has them;
  - per service, from the kernel inside the container: `NoNewPrivs` is 1 and the capability
    bounding set is exactly the added capabilities (/proc/self/status of a process started there),
    PID 1 holds no capability outside that set, and PID 1 of searxng and render-guard is not root;
  - Open WebUI, with no capability at all, starts, makes the admin account from .env, signs it in
    and reaches Ollama through the render guard;
  - SearXNG answers /healthz and a JSON search as uid 977 with `/` and /etc/searxng mounted
    read-only and /tmp a writable tmpfs, and its log names no file it could not write and no
    missing privilege (the entrypoint's ownership warning is expected; what single search engines
    answer is not judged, they often refuse a test machine);
  - the render guard and deep research reach Ollama under their limits;
  - after all of that every container is still running, was never ended for exceeding its memory
    limit and never restarted.
- The CI jobs `integration` and `installer` start SearXNG from the same compose file, so their
  web-search checks also run against the hardened SearXNG.

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
- **Register the rule:** add COMPOSESEC to `VerdictPattern` in `tests/Invoke-AllTests.ps1` (so the
  runner's summary quotes its hits; a hit already fails the run by its exit code), then list it in
  the rule list at the top of `tests/Invoke-StaticChecks.ps1` like the others. That script checks
  that every listed rule is in the pattern, which is why the rule is described at its function for
  now.
- **Docs:** README security notes; the backlog row; the stack smoke test's row in
  `tests/README.md`.
- **By hand on a real install** (the smoke test has no browser and no model): upload a document
  (embedding and reranking), run a web search from a chat, save the skill notebook tool (that path
  runs pip install), and run one deep research report, all with the hardening on.
- **By hand, an install with an old settings.yml:** the smoke test always writes settings.yml just
  before the start. After a SearXNG image update on an install whose settings.yml is older than
  the image, read `docker logs searxng` once: the entrypoint was read as copying settings only when
  settings.yml is missing, and a line saying `Read-only file system` would show that reading wrong.
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
   *Stack smoke test, on a Linux bind mount. A Windows bind mount (Docker Desktop): by hand; the
   render guard already reads its script that way (`./render-guard:/guard:ro`, user 65534).*
3. render-guard and deep research still work under their memory and pids limits.
   *Stack smoke test: both reach Ollama and none is ended or restarted. A full research run: by
   hand.*
4. `docker compose config` accepts the new keys. *Stack smoke test (it runs `config` first).*
5. The full suite passes, including the update test and the installer mock run. *CI.*
