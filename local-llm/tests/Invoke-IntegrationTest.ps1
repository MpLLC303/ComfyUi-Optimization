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
$system = Get-Content -Encoding UTF8 -Raw (Join-Path $root 'config/system-prompt.txt')
$failures = 0

Write-LaiLog STEP "Ollama $(Get-LaiOllamaVersion -BaseUrl $OllamaUrl)"
$results = Invoke-LaiModelSetup -BaseUrl $OllamaUrl -Models $catalog.Models -Candidates $catalog.ContextCandidates `
    -SystemPrompt $system -Fingerprint 'test' -AllowCpu

# Second run must reuse the stored tuning instead of re-measuring.
$again = Invoke-LaiModelSetup -BaseUrl $OllamaUrl -Models $catalog.Models -Candidates $catalog.ContextCandidates `
    -SystemPrompt $system -Fingerprint 'test' -Previous $results -AllowCpu
foreach ($k in $results.Keys) {
    if ($again[$k]['Context'] -ne $results[$k]['Context']) { Write-LaiLog FAIL "re-run changed context for $k"; $failures++ }
    if (-not $again[$k]['Reused']) { Write-LaiLog FAIL "re-run loaded $k again although nothing changed"; $failures++ }
}
# A re-published model (new digest) is measured again; a new Ollama version is at least re-verified.
$mainKey = @($catalog.Models)[0].Key
$tamper = {
    param([string]$Field, [string]$Value)
    $p = @{}; foreach ($k in $results.Keys) { $p[$k] = $results[$k].Clone() }
    $p[$mainKey][$Field] = $Value
    return (Invoke-LaiModelSetup -BaseUrl $OllamaUrl -Models @(@($catalog.Models)[0]) -Candidates $catalog.ContextCandidates `
        -SystemPrompt $system -Fingerprint 'test' -Previous $p -AllowCpu)
}
$d = & $tamper 'Digest' 'sha256:republished'
if ($d[$mainKey]['Reused']) { Write-LaiLog FAIL 'a changed model digest did not trigger a new measurement'; $failures++ } else { Write-LaiLog OK 'changed digest: measured again' }
$v = & $tamper 'OllamaVersion' '0.0.1'
if ($v[$mainKey]['Reused'] -or $v[$mainKey]['Context'] -ne $results[$mainKey]['Context']) { Write-LaiLog FAIL 'a new Ollama version was not re-verified at the tuned context'; $failures++ } else { Write-LaiLog OK 'new Ollama version: re-verified at the tuned context' }

$token = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $Email -Password $Password
# Point the shared Open WebUI straight at Ollama: an earlier suite (the mock run's render guard on
# :11435) may have left it elsewhere, and the chat checks below would fail for that reason.
$oc = ConvertTo-LaiHashtable (Invoke-LaiApi -Uri "$WebUIUrl/ollama/config" -Token $token)
$ocCfgs = @{}; if ($oc.ContainsKey('OLLAMA_API_CONFIGS') -and $oc['OLLAMA_API_CONFIGS']) { $ocCfgs = $oc['OLLAMA_API_CONFIGS'] }
Invoke-LaiApi -Method POST -Uri "$WebUIUrl/ollama/config/update" -Token $token -Body @{ ENABLE_OLLAMA_API = $true; OLLAMA_BASE_URLS = [object[]]@($OllamaUrl); OLLAMA_API_CONFIGS = $ocCfgs } | Out-Null
$setupWarn = @(Invoke-LaiWebUISetup -BaseUrl $WebUIUrl -Token $token -Models $catalog.Models -ModelResults $results -SystemPrompt $system `
    -DefaultPreset $catalog.DefaultPreset -Collections @('PC & Electronics', 'General References') -SearxngQueryUrl $SearxngQueryUrl)
# Every setting written must read back from the real server (a mismatch here means the comparison
# or a payload is wrong, and real installs would print false 'needs attention' lines).
if ($setupWarn.Count -ne 0) { Write-LaiLog FAIL "the first configuration pass reported settings that did not take: $($setupWarn -join ' | ')"; $failures++ } else { Write-LaiLog OK 'every admin, documents and web search setting read back as written' }
# A user edit to a preset (attached knowledge, an extra parameter) must survive a re-run.
$p0 = ConvertTo-LaiHashtable (Get-LaiWebUIModel -BaseUrl $WebUIUrl -Token $token -Id $catalog.DefaultPreset)
$p0['meta']['knowledge'] = @(@{ id = 'user-kb'; name = 'User collection'; type = 'collection' })
$p0['params']['temperature'] = 0.33
Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/models/model/update" -Token $token -Body @{
    id = $p0['id']; name = $p0['name']; base_model_id = $p0['base_model_id']; meta = $p0['meta']; params = $p0['params']; is_active = $true
} | Out-Null
# Idempotency: the whole configuration pass must succeed a second time unchanged.
$setupWarn = @(Invoke-LaiWebUISetup -BaseUrl $WebUIUrl -Token $token -Models $catalog.Models -ModelResults $results -SystemPrompt $system `
    -DefaultPreset $catalog.DefaultPreset -Collections @('PC & Electronics', 'General References') -SearxngQueryUrl $SearxngQueryUrl)
if ($setupWarn.Count -ne 0) { Write-LaiLog FAIL "the second configuration pass reported warnings: $($setupWarn -join ' | ')"; $failures++ }

$p1 = Get-LaiWebUIModel -BaseUrl $WebUIUrl -Token $token -Id $catalog.DefaultPreset
if (@($p1.meta.knowledge).Count -ne 1 -or $p1.meta.knowledge[0].id -ne 'user-kb' -or [double]$p1.params.temperature -ne 0.33) {
    Write-LaiLog FAIL "re-run dropped the user's preset edits (knowledge=$(@($p1.meta.knowledge).Count), temperature=$($p1.params.temperature))"; $failures++
} elseif (-not $p1.params.system -or $p1.params.function_calling -ne 'native') {
    Write-LaiLog FAIL 're-run did not restore the managed preset keys'; $failures++
} else { Write-LaiLog OK 're-run kept the user preset edits (attached knowledge, temperature) and refreshed the managed keys' }

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
