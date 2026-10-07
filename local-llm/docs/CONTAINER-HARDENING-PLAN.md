# Container hardening (security track item 1): research done, nothing applied yet

Status at handover (2026-10-07): research finished, no code or compose changes made. This file is
the work in progress. Evidence comes from the Open WebUI v0.11.4 source and Dockerfile, the SearXNG
image `searxng/searxng:2026.10.2-19ffbcd30` (inspected, not started) and
`local-llm/stack/docker-compose.yml`. Nothing here has been tested on running containers.

## Already in place
- render-guard: user `65534:65534`, `read_only`, `cap_drop: [ALL]`, `no-new-privileges`.
- deep-research (compose profile `research`, enabled through `COMPOSE_PROFILES` in Stack\.env):
  `cap_drop: [ALL]` plus CHOWN, FOWNER, DAC_OVERRIDE, SETUID, SETGID, and `no-new-privileges`
  (its image drops privileges with `setpriv`, which works under no-new-privileges).
- Every published port is bound to 127.0.0.1.
- open-webui and searxng have none of the hardening keys.

## To apply, per service
- **open-webui:** `security_opt: [no-new-privileges:true]`, `cap_drop: [ALL]` (no adds),
  `mem_limit: 16g`, `pids_limit: 4096`.
  - Runs as root (Dockerfile `ARG UID=0`, `USER $UID:$GID`; /app and /root root-owned).
  - Needs no capabilities: `backend/start.sh` has no chown/su/setcap; the Python source has no
    `os.chown`/setuid/setgid; port 8080 needs no bind capability.
  - Not `read_only`: it rewrites `/app/backend/open_webui/static` at every start (config.py,
    about lines 100-145), pip-installs tool requirements into site-packages
    (`utils/plugin.py:441`) and uses tempfile.
  - 16g leaves room for the CPU embedder (bge-m3) and reranker (bge-reranker-v2-m3).
- **searxng:** `user: "977:977"`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`,
  `read_only: true`, `tmpfs: ["/tmp:size=256m,mode=1777"]`, `./searxng:/etc/searxng:ro`,
  `mem_limit: 2g`, `pids_limit: 512`.
  - Today it runs as root (no USER in the image). `entrypoint.sh` chowns /etc/searxng and
    /var/cache/searxng and runs update-ca-certificates only as root, then starts granian as root.
  - As 977 the chown is skipped (one warning line in the log) and so is the CA update; settings
    are copied only when settings.yml is missing, and the installer always writes it first.
  - Runtime writes go only to /tmp (SQLite caches sxng_cache_*.db and faviconcache.db:
    searx/cache.py, favicons/cache.py).
- **render-guard:** add `mem_limit: 512m`, `pids_limit: 512` (one thread per request plus a
  watcher; writes no files).
- **deep-research:** add `mem_limit: 8g`, `pids_limit: 2048`; not `read_only` (write paths not
  verified).
- **Static check:** a COMPOSESEC rule in `tests/Invoke-StaticChecks.ps1` with canaries: every
  service has no-new-privileges, `cap_drop` ALL, `mem_limit`, `pids_limit`, and 127.0.0.1-only
  ports. Add the rule name to `VerdictPattern` in `tests/Invoke-AllTests.ps1`.
- **Docs:** README security notes; IMPROVEMENTS row 87.
- Keep the line `searxng/searxng:${SEARXNG_VERSION:-...}` unchanged: `Invoke-UpdateWebUITest.ps1`
  matches it with a regex.

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

## Digest plan
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

## Verify on real containers after applying
1. Open WebUI starts with no capabilities: sign in, upload a document (embedding and reranking),
   run a web search, save the skill notebook tool (that path runs pip install).
2. SearXNG as 977 reads settings.yml from a Windows bind mount and answers searches on a
   read-only filesystem; its log shows only the expected ownership warning.
3. render-guard and deep research still work under their memory and pids limits.
4. `docker compose config` accepts the new keys.
5. The full suite passes, including the update test and the installer mock run.
