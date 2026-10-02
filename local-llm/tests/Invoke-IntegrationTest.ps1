<#
.SYNOPSIS
    Integration test for the portable half of the installer (lib/LocalAI.psm1) against REAL
    Ollama and Open WebUI servers. Used to validate the API calls before they ever run on Windows.

.DESCRIPTION
    Runs the same functions Install-LocalAI.ps1 runs - context tuning, tuned aliases, Open WebUI
    presets, admin/RAG/web-search configuration, knowledge collections - and then the functional
    smoke tests (chat, memory, RAG, web search). It uses a small test catalog so it finishes on a
    CPU-only box in a few minutes.

    Prerequisites (see tests/README.md):
      - Ollama on $OllamaUrl with the model named in tests/models.test.psd1
      - Open WebUI on $WebUIUrl, admin account $Email / $Password
      - SearXNG reachable from Open WebUI at $SearxngQueryUrl

.PARAMETER SandboxTextSplitter
    Overrides the RAG text splitter after setup. The cloud sandbox blocks the tiktoken download that
    the 'token' splitter needs; the official Open WebUI image ships that file pre-cached.
#>
param(
    [string]$OllamaUrl = 'http://127.0.0.1:11434',
    [string]$WebUIUrl = 'http://127.0.0.1:3000',
    [string]$Email = 'admin@localhost',
    [string]$Password = 'Test-Password-123',
    [string]$SearxngQueryUrl = 'http://localhost:8888/search?q=<query>',
    [string]$SandboxTextSplitter = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib/LocalAI.psm1') -Force

$catalog = Get-LaiCatalog -Path (Join-Path $PSScriptRoot 'models.test.psd1')
$system = Get-Content -Raw (Join-Path $root 'config/system-prompt.txt')
$failures = 0

Write-LaiLog STEP "Ollama $(Get-LaiOllamaVersion -BaseUrl $OllamaUrl)"
$results = Invoke-LaiModelSetup -BaseUrl $OllamaUrl -Models $catalog.Models -Candidates $catalog.ContextCandidates `
    -SystemPrompt $system -Fingerprint 'test' -AllowCpu

# Second run must reuse the stored tuning instead of re-measuring.
$again = Invoke-LaiModelSetup -BaseUrl $OllamaUrl -Models $catalog.Models -Candidates $catalog.ContextCandidates `
    -SystemPrompt $system -Fingerprint 'test' -Previous $results -AllowCpu
foreach ($k in $results.Keys) {
    if ($again[$k]['Context'] -ne $results[$k]['Context']) { Write-LaiLog FAIL "re-run changed context for $k"; $failures++ }
}

$token = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $Email -Password $Password
Invoke-LaiWebUISetup -BaseUrl $WebUIUrl -Token $token -Models $catalog.Models -ModelResults $results -SystemPrompt $system `
    -DefaultPreset $catalog.DefaultPreset -Collections @('PC & Electronics', 'General References') -SearxngQueryUrl $SearxngQueryUrl
# Idempotency: the whole configuration pass must succeed a second time unchanged.
Invoke-LaiWebUISetup -BaseUrl $WebUIUrl -Token $token -Models $catalog.Models -ModelResults $results -SystemPrompt $system `
    -DefaultPreset $catalog.DefaultPreset -Collections @('PC & Electronics', 'General References') -SearxngQueryUrl $SearxngQueryUrl

$rc = Get-LaiWebUIRetrievalConfig -BaseUrl $WebUIUrl -Token $token
if ($rc.web.SEARXNG_LANGUAGE -ne 'all' -or $rc.web.WEB_LOADER_CONCURRENT_REQUESTS -ne 10 -or $rc.TEXT_SPLITTER -ne 'token' -or $rc.TOP_K -ne 5) {
    Write-LaiLog FAIL "retrieval config clobbered: language=$($rc.web.SEARXNG_LANGUAGE) loader=$($rc.web.WEB_LOADER_CONCURRENT_REQUESTS) splitter=$($rc.TEXT_SPLITTER) top_k=$($rc.TOP_K)"
    $failures++
}

$kbs = @(Get-LaiWebUIKnowledge -BaseUrl $WebUIUrl -Token $token | Where-Object { $_.name -eq 'PC & Electronics' })
if ($kbs.Count -ne 1) { Write-LaiLog FAIL "expected exactly one 'PC & Electronics' collection, found $($kbs.Count)"; $failures++ }

foreach ($m in $catalog.Models) {
    $p = Get-LaiWebUIModel -BaseUrl $WebUIUrl -Token $token -Id $m.Preset
    if (-not $p -or $p.params.function_calling -ne 'native' -or -not $p.params.system) { Write-LaiLog FAIL "preset $($m.Preset) incomplete"; $failures++ }
    $raw = Get-LaiWebUIModel -BaseUrl $WebUIUrl -Token $token -Id (Resolve-LaiModelName $m.Source)
    if (-not $raw -or $raw.meta.hidden -ne $true) { Write-LaiLog FAIL "raw model $($m.Source) not hidden"; $failures++ }
}

if ($SandboxTextSplitter) {
    Write-LaiLog WARN "Sandbox override: RAG text splitter -> $SandboxTextSplitter"
    Set-LaiWebUIRetrievalConfig -BaseUrl $WebUIUrl -Token $token -Settings @{ TEXT_SPLITTER = $SandboxTextSplitter } | Out-Null
}

$main = $catalog.DefaultPreset
$chat = Test-LaiWebUIChat -BaseUrl $WebUIUrl -Token $token -Model $main
Write-LaiLog $(if ($chat.Passed) { 'OK' } else { 'FAIL' }) "chat: $($chat.Answer)"
if (-not $chat.Passed) { $failures++ }

$mem = Test-LaiWebUIMemory -BaseUrl $WebUIUrl -Token $token -Model $main
Write-LaiLog $(if ($mem.Passed) { 'OK' } else { 'FAIL' }) "memory: expected $($mem.Expected), got '$($mem.Answer)'"
if (-not $mem.Passed) { $failures++ }

$rag = Test-LaiWebUIRag -BaseUrl $WebUIUrl -Token $token -Model $main
Write-LaiLog $(if ($rag.Passed) { 'OK' } else { 'FAIL' }) "rag: expected $($rag.Expected), got '$($rag.Answer)'"
if (-not $rag.Passed) { $failures++ }

$web = Test-LaiWebUIWebSearch -BaseUrl $WebUIUrl -Token $token
$lvl = 'OK'; if ($web.Status -eq 'no-results') { $lvl = 'WARN' } elseif ($web.Status -ne 'ok') { $lvl = 'FAIL'; $failures++ }
Write-LaiLog $lvl "web search: $($web.Status) ($($web.Count) results) $($web.Detail)"

$leftover = @(Get-LaiWebUIKnowledge -BaseUrl $WebUIUrl -Token $token | Where-Object { $_.name -like 'LocalAI Self-Test*' })
if ($leftover.Count -gt 0) { Write-LaiLog FAIL 'self-test collection was not cleaned up'; $failures++ }

if ($failures -eq 0) { Write-LaiLog OK 'INTEGRATION TEST PASSED' } else { Write-LaiLog FAIL "INTEGRATION TEST FAILED ($failures)" }
exit $failures
