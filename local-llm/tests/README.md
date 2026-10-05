# Tests

These harnesses check the scripts before they ever run on Windows. CI runs them all on every push: `.github/workflows/local-llm-linux.yml` rebuilds this sandbox from scratch on Ubuntu, and `local-llm-windows.yml` runs the static checks and `Invoke-WindowsUnitTests.ps1` on real Windows PowerShell 5.1. Both run under
PowerShell 7 on Linux against **real** servers. The only stand-in is a small Qwen3 model (same
architecture family and chat template as the real ones), so the tests fit on a CPU-only box.

| Script | What it proves |
|---|---|
| `Invoke-IntegrationTest.ps1` | The API layer (`lib/LocalAI.psm1`) against Ollama v0.35.1 and Open WebUI v0.11.4: it covers the context tuner, the tuned aliases, presets, hiding raw models, admin/RAG/web-search config (run twice to check it's idempotent), knowledge collections, and the chat/memory/RAG/web-search smoke tests, plus the health check's direct SearXNG probe against the real image (it finds pages or names every failed engine). Last, it runs the real render guard in front of that Ollama with a faked ComfyUI: a chat sent to the CPU during a "render" must be followed, after the hold, by a fresh load (`load_duration`), not the reused CPU runner. |
| `Invoke-InstallerMockRun.ps1` | The full `Install-LocalAI.ps1` orchestration, with Windows-only commands mocked: a fresh run that hits a reboot, a resume via the logon task, migrating a manual-install container, `.env`/secret handling, backup task, report, and an idempotent re-run. Phase 7 covers other hardware and setups: a 16 GB card and a PC without an NVIDIA GPU (refused before any download), the Ollama app's own Model location / Expose settings in `server.log`, Ollama in a custom install folder, a PC with 8 GB of RAM (`.wslconfig`, render-guard warning), and a `searxng` container from Open WebUI's own guide. The sandbox's `searxng` container is parked as `searxng-uninstall-test-keep` for the run and restored at the end. |
| `Invoke-ModelUpdateTest.ps1` | `Update-Models.ps1` against a real Ollama, on private copies of the stand-in model: an unchanged pull keeps no extra copy, a re-published tag keeps `<tag>-prev` and re-tunes, a re-published tag this Ollama cannot load (`LOCALAI_TEST_LOAD_FAIL`) leaves the tuned alias alone and names `-UpdateOllama` / `-Rollback`, a failed re-check after an Ollama update does not advise `-Rollback`, then `-Rollback` and `-DropPrevious`. |
| `Invoke-UpdateWebUITest.ps1` | `Update-OpenWebUI.ps1` on a throwaway stack (alpine images standing in for Open WebUI versions): an update records a rollback point, a failed pull changes nothing, an update killed mid-download leaves `.env` alone, an install left with `.env` naming a version that never ran is set back first, the rollback archive survives pruning, `-Rollback` brings back the old image and the pre-update data, and a second rollback refuses. Also the backup's wait for a chat answer, its sign-in run (a no-op after a night's backup, a catch-up after a missed one), a missing deep-check image being counted, a restore killed right after it turned auto-restart off, and one whose `docker stop` fails. A SearXNG-only update records and prints the tag it replaced (the way back). |
| `Invoke-UninstallTest.ps1` | `Uninstall-LocalAI.ps1` against real Docker with a fake Ollama (it records deletes, so the real models stay put) and mocked scheduled tasks: `-WhatIf` changes nothing; the default removal takes a verified backup and removes containers, aliases and tasks while keeping data; `-RemoveData -RemoveModels`; and a failing backup that aborts before anything is removed. A sandbox `searxng` container is moved aside and restored. |
| `Invoke-WatchTest.ps1` | `Watch-LocalAI.ps1` against real containers: a stopped SearXNG is restarted, nothing is healed while paused, Open WebUI is left alone while another process holds the volume lock, a docker CLI that never answers is reported (watch and backup) instead of hanging, and Open WebUI unable to reach Ollama is a failed check. An Ollama newer than the one the presets were tuned on gets exactly one notice naming `Update-Models.ps1`, never a failed check, and none once the tuning records it. |
| `Invoke-AllTests.ps1 -SelfTest` | The runner itself: a suite whose program is missing, one that prints ASSERT FAIL but exits 0, one without its PASSED banner, one with a non-zero exit, and one that hangs (killed with its child process after the time limit) are all reported as failed. |
| `Reset-Sandbox.ps1` | Puts the shared sandbox back (throwaway containers and volumes, helper processes, a parked SearXNG, test models, the admin password, Open WebUI's Ollama connection). `-Check` only reports: the runner runs it after every suite, and a suite that leaves anything behind fails. |
| `test_render_guard.py` | `render_guard.py` with a fake ComfyUI and a fake streaming Ollama that follows Ollama 0.35.1's runner-reuse rule (a request without `num_gpu` reuses the loaded runner). It checks CPU routing while busy and for the hold period, that the CPU copy is unloaded after the hold (by the watcher, or exactly once by the first of two concurrent chats) so the next chat loads fresh, that a 500 from Ollama during that unload is retried (and given up after 5 tries), that a CPU copy evicted by another model is no longer marked, `/free` with back-off, 20 concurrent streams, images dropped for a model without `vision` (and passed through when `/api/show` fails; capabilities read again after a pull through the guard and after `CAPS_NO_VISION_TTL_SEC`), ComfyUI read through `/api/queue` when `/queue` is refused, connected-but-silent counted as busy, unreachable counted as not busy, a status page with slow ComfyUIs answering well within the backup's wait for it, and SIGTERM. |
| `../Test-LocalAI.ps1 -CatalogPath tests/models.test.psd1 -NoContainers` | The acceptance checklist itself. |

## Sandbox setup used

```bash
# Ollama 0.35.1 (CPU) with the stand-in model imported as testorg/qwen3-abliterated:1.7b
docker run -d --name ollama-test -p 127.0.0.1:11434:11434 -e OLLAMA_FLASH_ATTENTION=1 \
  -e OLLAMA_KV_CACHE_TYPE=q8_0 -e OLLAMA_HOST=0.0.0.0:11434 ollama/ollama:0.35.1
#   ollama create testorg/qwen3-abliterated:1.7b -f Modelfile   (FROM qwen3-1.7b-q4_K_M.gguf)
#   ollama create nomic-embed-text -f Modelfile                (sandbox embedding model, see below)

# Open WebUI 0.11.4 from PyPI, with the same environment variables as stack/docker-compose.yml plus:
#   WEBUI_ADMIN_EMAIL=admin@localhost WEBUI_ADMIN_PASSWORD=Test-Password-123
#   RAG_EMBEDDING_ENGINE=ollama RAG_EMBEDDING_MODEL=nomic-embed-text:latest
#   SEARXNG_QUERY_URL=http://localhost:8888/search?q=<query>
pip install open-webui==0.11.4 && open-webui serve --port 3000

# SearXNG straight from stack/docker-compose.yml
docker compose -f stack/docker-compose.yml up -d searxng

pwsh tests/Invoke-AllTests.ps1                 # every suite, one after another, one summary table
pwsh tests/Invoke-AllTests.ps1 -Only Static,Mock   # a subset
```

Run the suites through `Invoke-AllTests.ps1` (or one at a time, after `pwsh tests/Reset-Sandbox.ps1`). A suite passes only with exit 0, its own PASSED banner, no ASSERT FAIL line, within `-TimeoutSec` (default 1800), and with nothing left behind. They share one Ollama, one Open WebUI and one
Docker engine, so running two at once makes them unload each other's models and fight over the
`open-webui` volume. The failures look like product bugs. The runner holds a lock file, so a second run refuses to start.

`Invoke-StaticChecks.ps1` also scans for runtime pitfalls that parse cleanly. Each one was a real bug here:
- `Measure/Sort/Select -Property <name>` on hashtables (fails on 5.1).
- `Write-X ('...') -f $a`, where `-f` becomes a separate argument.
- `$Matches` read after a second `-match` in the same condition.
- `$PSBoundParameters` inside a `&`-invoked scriptblock, where it is empty.

Built-in canaries check that every rule still fires.

The sandbox blocks Hugging Face, the tiktoken CDN and the public search engines. So:
- embeddings use an Ollama model instead of the default embedding model, which ships inside the official Docker image;
- the RAG test uses the `character` splitter (the official image pre-caches the tiktoken file that `token` needs);
- web search shows up as `no-results`, which shows the Open WebUI → SearXNG link works and only the upstream engines were unreachable.
