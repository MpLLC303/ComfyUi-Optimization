# Tests

These harnesses check the scripts before they ever run on Windows. Both run under
PowerShell 7 on Linux against **real** servers. The only stand-in is a small Qwen3 model (same
architecture family and chat template as the real ones), so the tests fit on a CPU-only box.

| Script | What it proves |
|---|---|
| `Invoke-IntegrationTest.ps1` | The API layer (`lib/LocalAI.psm1`) against Ollama v0.35.1 and Open WebUI v0.11.4: it covers the context tuner, the tuned aliases, presets, hiding raw models, admin/RAG/web-search config (run twice to check it's idempotent), knowledge collections, and the chat/memory/RAG/web-search smoke tests. |
| `Invoke-InstallerMockRun.ps1` | The full `Install-LocalAI.ps1` orchestration, with Windows-only commands mocked: a fresh run that hits a reboot, a resume via the logon task, migrating a manual-install container, `.env`/secret handling, backup task, report, and an idempotent re-run. |
| `Invoke-UninstallTest.ps1` | `Uninstall-LocalAI.ps1` against real Docker with a fake Ollama (it records deletes, so the real models stay put) and mocked scheduled tasks: `-WhatIf` changes nothing; the default removal takes a verified backup and removes containers, aliases and tasks while keeping data; `-RemoveData -RemoveModels`; and a failing backup that aborts before anything is removed. A sandbox `searxng` container is moved aside and restored. |
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

pwsh tests/Invoke-IntegrationTest.ps1 -SandboxTextSplitter character
pwsh tests/Invoke-InstallerMockRun.ps1
pwsh tests/Invoke-UninstallTest.ps1
```

The sandbox blocks Hugging Face, the tiktoken CDN and the public search engines. So:
- embeddings use an Ollama model instead of the default embedding model, which ships inside the official Docker image;
- the RAG test uses the `character` splitter (the official image pre-caches the tiktoken file that `token` needs);
- web search shows up as `no-results`, which shows the Open WebUI → SearXNG link works and only the upstream engines were unreachable.
