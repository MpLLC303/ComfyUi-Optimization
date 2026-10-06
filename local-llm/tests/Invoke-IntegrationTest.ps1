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
# Start from values other than the wanted ones (the server's own defaults already equal most of
# them, so an ignored write would otherwise still read back 'right').
Set-LaiWebUIRetrievalConfig -BaseUrl $WebUIUrl -Token $token -Settings @{ TOP_K = 3; CHUNK_SIZE = 1000; CHUNK_OVERLAP = 100; FILE_IMAGE_COMPRESSION_WIDTH = 640; FILE_IMAGE_COMPRESSION_HEIGHT = 480
    web = @{ WEB_SEARCH_RESULT_COUNT = 3; WEB_FETCH_MAX_CONTENT_LENGTH = 1000 } } | Out-Null
Set-LaiWebUIAdminConfig -BaseUrl $WebUIUrl -Token $token -Changes @{ ENABLE_MEMORY_SYSTEM_CONTEXT = $false } | Out-Null
$pre = Get-LaiWebUIRetrievalConfig -BaseUrl $WebUIUrl -Token $token
if ($pre.TOP_K -ne 3 -or $pre.CHUNK_SIZE -ne 1000 -or $pre.web.WEB_SEARCH_RESULT_COUNT -ne 3) { Write-LaiLog FAIL "could not move the settings away from the wanted values first (top_k=$($pre.TOP_K) chunk=$($pre.CHUNK_SIZE))"; $failures++ }
if ([int]$pre.FILE_IMAGE_COMPRESSION_WIDTH -ne 640 -or [int]$pre.web.WEB_FETCH_MAX_CONTENT_LENGTH -ne 1000) { Write-LaiLog FAIL "could not move the image scaling / fetch cap away first (width=$($pre.FILE_IMAGE_COMPRESSION_WIDTH) fetch=$($pre.web.WEB_FETCH_MAX_CONTENT_LENGTH))"; $failures++ }
$setupWarn = @(Invoke-LaiWebUISetup -BaseUrl $WebUIUrl -Token $token -Models $catalog.Models -ModelResults $results -SystemPrompt $system `
    -DefaultPreset $catalog.DefaultPreset -Collections @('PC & Electronics', 'General References') -SearxngQueryUrl $SearxngQueryUrl)
$post = Get-LaiWebUIRetrievalConfig -BaseUrl $WebUIUrl -Token $token
$postAdmin = Invoke-LaiApi -Uri "$WebUIUrl/api/v1/auths/admin/config" -Token $token
if ($post.TOP_K -ne 5 -or $post.CHUNK_SIZE -ne 2000 -or $post.CHUNK_OVERLAP -ne 200 -or $post.web.WEB_SEARCH_RESULT_COUNT -ne 5 -or $postAdmin.ENABLE_MEMORY_SYSTEM_CONTEXT -ne $true) { Write-LaiLog FAIL 'the configuration pass did not change the moved settings back'; $failures++ }
# Context budget (Local Vision 32K, Fast 40K): image scaling and the fetched-page cap, read back from the real server.
$ragWant = Get-LaiRagWanted
if ([int]$post.FILE_IMAGE_COMPRESSION_WIDTH -ne $ragWant.FILE_IMAGE_COMPRESSION_WIDTH -or [int]$post.FILE_IMAGE_COMPRESSION_HEIGHT -ne $ragWant.FILE_IMAGE_COMPRESSION_HEIGHT -or [int]$post.web.WEB_FETCH_MAX_CONTENT_LENGTH -ne $ragWant.web.WEB_FETCH_MAX_CONTENT_LENGTH) {
    Write-LaiLog FAIL "image scaling / fetch cap not applied (width=$($post.FILE_IMAGE_COMPRESSION_WIDTH) height=$($post.FILE_IMAGE_COMPRESSION_HEIGHT) fetch=$($post.web.WEB_FETCH_MAX_CONTENT_LENGTH))"; $failures++
} else { Write-LaiLog OK "images scaled to $($post.FILE_IMAGE_COMPRESSION_WIDTH) px, fetched pages cut at $($post.web.WEB_FETCH_MAX_CONTENT_LENGTH) characters" }
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

# A Context Length set in Open WebUI overrides the tuned alias: the real 0.11.4 must show it where
# Get-LaiContextOverride looks (the admin's own settings and a preset), and nothing once it is gone.
$origUi = Invoke-LaiApi -Uri "$WebUIUrl/api/v1/users/user/settings?raw=true" -Token $token
$origParams = $null
if ($origUi -and $origUi.ui -and $origUi.ui.PSObject.Properties.Name -contains 'params') { $origParams = $origUi.ui.params }
$pc = ConvertTo-LaiHashtable (Get-LaiWebUIModel -BaseUrl $WebUIUrl -Token $token -Id $catalog.DefaultPreset)
$presetUpdate = { param($Params) Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/models/model/update" -Token $token -Body @{
        id = $pc['id']; name = $pc['name']; base_model_id = $pc['base_model_id']; meta = $pc['meta']; params = $Params; is_active = $true } | Out-Null }
try {
    Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/users/user/settings/update" -Token $token -Body @{ ui = @{ params = @{ num_ctx = 4096 } } } | Out-Null
    $planted = @{}; foreach ($k in $pc['params'].Keys) { $planted[$k] = $pc['params'][$k] }
    $planted['num_ctx'] = 4096
    & $presetUpdate $planted
    $found = @(Get-LaiContextOverride -BaseUrl $WebUIUrl -Token $token -PresetIds @($catalog.DefaultPreset))
    if (@($found | Where-Object { $_ -like 'your Settings*num_ctx 4096*' }).Count -ne 1 -or @($found | Where-Object { $_ -like "Workspace > Models > $($pc['name']) >*num_ctx 4096*" }).Count -ne 1) {
        Write-LaiLog FAIL "a num_ctx in the user settings and in a preset was not found: $($found -join ' | ')"; $failures++
    } else { Write-LaiLog OK "context overrides found: $($found -join ' | ')" }
} finally {
    Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/users/user/settings/update" -Token $token -Body @{ ui = @{ params = $origParams } } | Out-Null
    & $presetUpdate $pc['params']
}
$left = @(Get-LaiContextOverride -BaseUrl $WebUIUrl -Token $token -PresetIds @($catalog.DefaultPreset))
if ($left.Count -ne 0) { Write-LaiLog FAIL "context override still reported after clearing it: $($left -join ' | ')"; $failures++ }

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

# What a self-test cut off mid-run leaves (its collection and uploaded manual) must be removed by
# the next run; a user's collection with a similar name must not be.
$seedDir = Join-Path ([System.IO.Path]::GetTempPath()) ('lai-seed-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $seedDir | Out-Null
$seedFile = Join-Path $seedDir 'localai-selftest-manual.md'
Set-Content -LiteralPath $seedFile -Value '# leftover from an interrupted self-test'
$seedKb = Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/knowledge/create" -Token $token -Body @{ name = 'LocalAI Self-Test (temporary)'; description = 'seeded leftover' }
$seedFileId = Send-LaiWebUIFile -BaseUrl $WebUIUrl -Token $token -Path $seedFile
$decoy = Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/knowledge/create" -Token $token -Body @{ name = 'LocalAI Self-Test (temporary) - my notes'; description = 'user collection' }
Remove-Item -LiteralPath $seedDir -Recurse -Force
$seen = @(Get-LaiWebUISelfTestLeftover -BaseUrl $WebUIUrl -Token $token)
if (@($seen | Where-Object { $_.Id -eq $seedKb.id }).Count -ne 1 -or @($seen | Where-Object { $_.Id -eq $seedFileId }).Count -ne 1 -or @($seen | Where-Object { $_.Id -eq $decoy.id }).Count -ne 0) {
    Write-LaiLog FAIL "leftover detection is wrong: found $(@($seen | ForEach-Object { "$($_.Kind) $($_.Id)" }) -join ', ')"; $failures++
}
$rag = Test-LaiWebUIRag -BaseUrl $WebUIUrl -Token $token -Model $main
Write-LaiLog $(if ($rag.Passed) { 'OK' } else { 'FAIL' }) "rag: expected $($rag.Expected), got '$($rag.Answer)'"
if (-not $rag.Passed) { $failures++ }

$web = Test-LaiWebUIWebSearch -BaseUrl $WebUIUrl -Token $token
$lvl = 'OK'; if ($web.Status -eq 'no-results') { $lvl = 'WARN' } elseif ($web.Status -ne 'ok') { $lvl = 'FAIL'; $failures++ }
Write-LaiLog $lvl "web search: $($web.Status) ($($web.Count) results) $($web.Detail)"
# The health check's direct SearXNG probe against the real pinned image: it must either find pages
# or name every failed engine with a reason (offline sandbox: each engine with its network error).
$sxBase = $SearxngQueryUrl -replace '/search\?.*$', ''
try {
    $sx = Get-LaiSearxngProbe -BaseUrl $sxBase
    $sxEngines = @($sx.Engines)
    $sxNamed = @($sxEngines | Where-Object { $_ -match '^\S[^:]*: \S' })
    if ($sx.Count -gt 0 -or ($sxEngines.Count -gt 0 -and $sxNamed.Count -eq $sxEngines.Count)) { Write-LaiLog OK "direct SearXNG probe: $($sx.Summary)" }
    else { Write-LaiLog FAIL "direct SearXNG probe found nothing and named no failed engine: $($sx.Summary)"; $failures++ }
} catch { Write-LaiLog FAIL "direct SearXNG probe on $sxBase failed: $($_.Exception.Message)"; $failures++ }

$kbsAfter = @(Get-LaiWebUIKnowledge -BaseUrl $WebUIUrl -Token $token)
if (@($kbsAfter | Where-Object { $_.id -eq $decoy.id }).Count -ne 1) { Write-LaiLog FAIL "the clean-up removed a user's collection with a similar name"; $failures++ }
Invoke-LaiApi -Method DELETE -Uri "$WebUIUrl/api/v1/knowledge/$($decoy.id)/delete" -Token $token | Out-Null
$leftover = @(Get-LaiWebUIKnowledge -BaseUrl $WebUIUrl -Token $token | Where-Object { $_.name -like 'LocalAI Self-Test*' })
$leftFiles = @(Get-LaiWebUISelfTestLeftover -BaseUrl $WebUIUrl -Token $token | Where-Object { $_.Kind -eq 'file' })
if ($leftover.Count -gt 0 -or $leftFiles.Count -gt 0) { Write-LaiLog FAIL "self-test collection or file was not cleaned up ($($leftover.Count) collection(s), $($leftFiles.Count) file(s))"; $failures++ }
else { Write-LaiLog OK "the self-test removed an interrupted run's collection and file and its own, and kept the user's similar collection" }

# Skills: <AIRoot>\Skills synced into the real Open WebUI, and the skill notebook tool run in Open
# WebUI's own Python against its own database (as Open WebUI runs it when the model calls it).
$skFail = $failures
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Reset-Sandbox.ps1') -SkillsOnly -WebUIUrl $WebUIUrl -Email $Email -Password $Password | Out-Null
$skDir = Join-Path ([System.IO.Path]::GetTempPath()) ('lai-skills-' + [guid]::NewGuid().ToString('N'))
$presetIds = @($catalog.Models | ForEach-Object { $_.Preset })
try {
    $r1 = Invoke-LaiSkillSync -BaseUrl $WebUIUrl -Token $token -Folder $skDir -SeedFrom (Join-Path $root 'skills') -PresetIds $presetIds
    $starters = @(Get-ChildItem -LiteralPath (Join-Path $root 'skills') -Directory | ForEach-Object { $_.Name })
    $p1 = Get-LaiWebUIModel -BaseUrl $WebUIUrl -Token $token -Id $catalog.DefaultPreset
    $att = @(); if ($p1.meta.PSObject.Properties['skillIds']) { $att = @($p1.meta.skillIds) }
    if (@($r1.Seeded).Count -ne $starters.Count -or @($r1.Created).Count -ne $starters.Count -or @($starters | Where-Object { $att -notcontains $_ }).Count) { Write-LaiLog FAIL "first sync: seeded $(@($r1.Seeded) -join ',') created $(@($r1.Created) -join ',') attached $($att -join ',')"; $failures++ }
    # Edited, switched off in Open WebUI, removed, and a name already taken by a skill made in Open WebUI.
    Add-Content -LiteralPath (Join-Path (Join-Path $skDir 'research-with-sources') 'SKILL.md') -Value "`nExtra line from the integration test."
    Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/skills/id/troubleshoot-step-by-step/toggle" -Token $token | Out-Null
    Remove-Item -LiteralPath (Join-Path $skDir 'remember-and-improve') -Recurse -Force
    Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/skills/create" -Token $token -Body @{ id = 'made-in-webui'; name = 'Made in Open WebUI'; description = 'd'; content = 'mine'; meta = @{ tags = @() }; is_active = $true } | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $skDir 'made-in-webui') | Out-Null
    Set-Content -LiteralPath (Join-Path (Join-Path $skDir 'made-in-webui') 'SKILL.md') -Value "---`nname: Clash`ndescription: x`n---`nfrom the folder"
    $r2 = Invoke-LaiSkillSync -BaseUrl $WebUIUrl -Token $token -Folder $skDir -SeedFrom (Join-Path $root 'skills') -PresetIds $presetIds
    $all2 = Get-LaiWebUISkills -BaseUrl $WebUIUrl -Token $token
    $checks = @(
        @{ Ok = (@($r2.Seeded).Count -eq 0); What = 'an existing folder is not seeded again (a deleted starter skill stays deleted)' }
        @{ Ok = (@($r2.Updated) -contains 'research-with-sources' -and [string]$all2['research-with-sources'].content -match 'Extra line from the integration test'); What = 'an edited SKILL.md updates its skill' }
        @{ Ok = ($all2['troubleshoot-step-by-step'] -and -not $all2['troubleshoot-step-by-step'].is_active -and @($r2.Updated) -notcontains 'troubleshoot-step-by-step'); What = 'a skill switched off in Open WebUI stays off' }
        @{ Ok = (@($r2.Disabled) -contains 'remember-and-improve' -and -not $all2['remember-and-improve'].is_active); What = 'a removed folder switches its skill off' }
        @{ Ok = (@($r2.Skipped | Where-Object { $_ -match "'made-in-webui' already exists" }).Count -eq 1 -and [string]$all2['made-in-webui'].content -eq 'mine'); What = 'a skill made in Open WebUI is never overwritten by a folder of the same name' }
    )
    foreach ($c in $checks) { if (-not $c.Ok) { Write-LaiLog FAIL "skills sync: $($c.What)"; $failures++ } }
    Invoke-LaiApi -Method DELETE -Uri "$WebUIUrl/api/v1/skills/id/made-in-webui/delete" -Token $token | Out-Null

    # The notebook tool: created, unchanged, updated through the API; then its functions in Open WebUI's Python.
    $nbCode = (Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $root 'stack/openwebui-tools/skill_notebook.py')).Replace('__LOCALAI_PRESETS__', ($presetIds -join ','))
    $t1 = Set-LaiWebUITool -BaseUrl $WebUIUrl -Token $token -Id 'localai_skill_notebook' -Name 'Skill notebook (Local AI)' -Content $nbCode
    $t2 = Set-LaiWebUITool -BaseUrl $WebUIUrl -Token $token -Id 'localai_skill_notebook' -Name 'Skill notebook (Local AI)' -Content $nbCode
    $t3 = Set-LaiWebUITool -BaseUrl $WebUIUrl -Token $token -Id 'localai_skill_notebook' -Name 'Skill notebook (Local AI)' -Content ($nbCode + "`n")
    if ("$t1/$t2/$t3" -ne 'created/unchanged/updated') { Write-LaiLog FAIL "notebook tool via the API: $t1/$t2/$t3"; $failures++ }
    $owuiPid = @(& pgrep -f 'open-webui serve' | Where-Object { $_ }) | Select-Object -First 1
    # The interpreter as started (its venv path), not /proc/<pid>/exe: that resolves to the system
    # Python, which does not see the venv's packages.
    $owuiPy = @([System.IO.File]::ReadAllText("/proc/$owuiPid/cmdline") -split [char]0)[0]
    $owuiEnv = @{}
    foreach ($kv in ([System.IO.File]::ReadAllText("/proc/$owuiPid/environ") -split [char]0)) { if ($kv -match '^(DATA_DIR|WEBUI_SECRET_KEY|DATABASE_URL)=(.*)$') { $owuiEnv[$Matches[1]] = $Matches[2] } }
    $drv = Join-Path $skDir 'notebook_driver.py'
    $nbFile = Join-Path $skDir 'skill_notebook.py'
    [System.IO.File]::WriteAllText($nbFile, $nbCode, (New-Object System.Text.UTF8Encoding($false)))
    Set-Content -LiteralPath $drv -Encoding ascii -Value @(
        'import asyncio, importlib.util, json, sys'
        'spec = importlib.util.spec_from_file_location("nb", sys.argv[1]); nb = importlib.util.module_from_spec(spec); spec.loader.exec_module(nb)'
        'from open_webui.models.users import Users'
        'async def main():'
        '    users = await Users.get_users(); lst = users["users"] if isinstance(users, dict) else users'
        '    a = [u for u in lst if u.role == "admin"][0]; ud = {"id": a.id, "role": "admin"}'
        '    t = nb.Tools(); out = []'
        '    out.append(await t.save_skill_draft("Integration check", "When testing", "1. step one", __user__=ud))'
        '    out.append(await t.save_skill_draft("Integration check", "When testing", "1. step one, improved", __user__=ud))'
        '    out.append(await t.save_skill_draft("x", "y", "z", __user__={"id": "u", "role": "user"}))'
        '    out.append(await t.list_skill_drafts(__user__=ud))'
        '    print(json.dumps(out))'
        'asyncio.run(main())'
    )
    $saved = @{}; foreach ($k in $owuiEnv.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); Set-LaiProcessEnv -Name $k -Value $owuiEnv[$k] }
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $nbOut = @(& $owuiPy $drv $nbFile 2>$null) } finally { $ErrorActionPreference = $prevEap; foreach ($k in $saved.Keys) { Set-LaiProcessEnv -Name $k -Value $saved[$k] } }
    $nbRes = @(); try { $nbRes = @(($nbOut | Where-Object { $_ -like '[[]*' } | Select-Object -Last 1) | ConvertFrom-Json) } catch { $nbRes = @() }
    $draft = (Get-LaiWebUISkills -BaseUrl $WebUIUrl -Token $token)['learned-integration-check']
    $pMain = Get-LaiWebUIModel -BaseUrl $WebUIUrl -Token $token -Id $catalog.DefaultPreset
    $mainSkills = @(); if ($pMain.meta.PSObject.Properties['skillIds']) { $mainSkills = @($pMain.meta.skillIds) }
    if ($nbRes.Count -ne 4 -or -not $draft -or $draft.is_active -or [string]$draft.content -ne '1. step one, improved' -or $mainSkills -notcontains 'learned-integration-check' -or [string]$nbRes[2] -notmatch 'Only the admin') {
        Write-LaiLog FAIL "skill notebook in Open WebUI's Python: results $($nbRes -join ' | '); draft active=$($draft.is_active) content=$($draft.content); in $($catalog.DefaultPreset): $($mainSkills -contains 'learned-integration-check')"; $failures++
    }
    if ($failures -eq $skFail) { Write-LaiLog OK 'skills: seeded, offered in the presets, edits/removals/switched-off/name clashes handled; the notebook saves an off draft, improves it, refuses non-admins' }
} catch {
    Write-LaiLog FAIL "skills: $($_.Exception.Message)"; $failures++
} finally {
    Remove-Item -LiteralPath $skDir -Recurse -Force -ErrorAction SilentlyContinue
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Reset-Sandbox.ps1') -SkillsOnly -WebUIUrl $WebUIUrl -Email $Email -Password $Password | Out-Null
}

# The optional research agent (-DeepResearch): the real Local Deep Research image against the
# sandbox's Ollama, through the module functions the installer and Test-LocalAI use. A research run
# itself takes minutes on this CPU and is left to Test-LocalAI on the real PC.
$ldrImage = 'localdeepresearch/local-deep-research:1.10.7'
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& docker image inspect $ldrImage 2>$null | Out-Null; $haveLdr = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prevEap
if ($haveLdr) {
    $ldrUrl = 'http://127.0.0.1:5057'
    try {
        & docker rm -f lai-ldr-integration 2>$null | Out-Null
        & docker run -d --name lai-ldr-integration --label lai-test=1 --network host -e LDR_WEB_HOST=127.0.0.1 -e LDR_WEB_PORT=5057 -e LDR_DATA_DIR=/data `
            -e LDR_LLM_PROVIDER=ollama -e "LDR_LLM_OLLAMA_URL=$OllamaUrl" -e "LDR_LLM_MODEL=$(@($catalog.Models)[0].Alias)" -e LDR_SEARCH_TOOL=searxng `
            --cap-drop ALL --cap-add CHOWN --cap-add FOWNER --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID $ldrImage | Out-Null
        Wait-LaiHttp -Uri "$ldrUrl/api/v1/health" -TimeoutSec 180 | Out-Null
        $ldrPw = New-LaiPassword
        Register-LaiResearchUser -BaseUrl $ldrUrl -Account 'localai' -Password $ldrPw
        $dup = ''; try { Register-LaiResearchUser -BaseUrl $ldrUrl -Account 'localai' -Password $ldrPw } catch { $dup = $_.Exception.Message }
        $bad = ''; $badKind = ''
        try { Connect-LaiResearch -BaseUrl $ldrUrl -Account 'localai' -Password 'Not-The-Password-1' | Out-Null } catch { $bad = $_.Exception.Message; $badKind = [string]$_.Exception.Data['LaiKind'] }
        $rs = Connect-LaiResearch -BaseUrl $ldrUrl -Account 'localai' -Password $ldrPw
        $rs.Client.Dispose()
        # From inside the container (where the configured address means something): the real Ollama, then nothing.
        $reachOk = Test-LaiResearchOllama -OllamaUrl $OllamaUrl -Container 'lai-ldr-integration'
        $reachNo = Test-LaiResearchOllama -OllamaUrl 'http://127.0.0.1:9' -Container 'lai-ldr-integration'
        if ($dup -notmatch "did not create the account 'localai'") { Write-LaiLog FAIL "a second sign-up with the same name was not reported as refused ($dup)"; $failures++ }
        elseif ($bad -notmatch 'refused the sign-in' -or $badKind -ne 'bad-password') { Write-LaiLog FAIL "a wrong password was not reported as a refused sign-in of kind bad-password (${badKind}: $bad)"; $failures++ }
        elseif (-not $reachOk.Ok -or $reachNo.Ok -or $reachNo.Message -notmatch '127\.0\.0\.1:9 not reachable from the lai-ldr-integration container') { Write-LaiLog FAIL "reach check: Ollama ok=$($reachOk.Ok) ($($reachOk.Message)); closed port ok=$($reachNo.Ok) ($($reachNo.Message))"; $failures++ }
        else { Write-LaiLog OK 'deep research: account made, duplicate and wrong password refused (kind bad-password), signed in, the container reaches Ollama and reports an address it cannot reach' }
    } catch {
        Write-LaiLog FAIL "deep research against the real Local Deep Research: $($_.Exception.Message)"; $failures++
    } finally {
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & docker rm -f lai-ldr-integration 2>$null | Out-Null
        $ErrorActionPreference = $prevEap
    }
} else { Write-LaiLog WARN "SKIP deep research: $ldrImage is not on this machine (docker pull it to run this check)" }

# The harness must see such a leftover too (a killed suite would otherwise fail the next one).
$probeKb = Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/knowledge/create" -Token $token -Body @{ name = 'LocalAI Self-Test (temporary)'; description = 'reset-sandbox probe' }
$resetOut = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Reset-Sandbox.ps1') -Check -WebUIUrl $WebUIUrl -Email $Email -Password $Password 2>&1 | ForEach-Object { "$_" }) -join "`n"
Invoke-LaiApi -Method DELETE -Uri "$WebUIUrl/api/v1/knowledge/$($probeKb.id)/delete" -Token $token | Out-Null
if ($resetOut -notmatch ('LEFTOVER RAG self-test collection ' + [regex]::Escape([string]$probeKb.id))) { Write-LaiLog FAIL "Reset-Sandbox -Check did not report a self-test leftover: $resetOut"; $failures++ } else { Write-LaiLog OK 'Reset-Sandbox -Check reports a self-test leftover' }

# Render guard against the real Ollama: a chat it sent to the CPU during a render must not keep
# running on that CPU runner afterwards. Ollama 0.35.1 reuses a loaded runner for a request without
# num_gpu (needsReload), so the guard has to unload it; the first chat after the hold must show a
# fresh load (load_duration), not the reused runner. ComfyUI is faked by a static file server whose
# 'queue' file says busy, then idle. The guard's watcher is off, so the request path is what's tested.
$freePort = { $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p }
$rgDir = Join-Path ([System.IO.Path]::GetTempPath()) ('lai-rg-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $rgDir | Out-Null
$queueFile = Join-Path $rgDir 'queue'
Set-Content -LiteralPath $queueFile -Encoding ascii -Value '{"queue_running": [[1]], "queue_pending": []}'
$comfyPort = & $freePort
$rgPort = & $freePort
$rgProcs = @()
# The guard reads its settings from the environment (set for the child, restored afterwards).
$rgEnv = @{ UPSTREAM = $OllamaUrl; COMFYUI_URLS = "http://127.0.0.1:$comfyPort"; LISTEN_PORT = "$rgPort"; HOLD_SEC = '3'; CACHE_SEC = '0'; WATCH_SEC = '100000' }
$rgEnvBefore = @{}
foreach ($k in $rgEnv.Keys) { $rgEnvBefore[$k] = [Environment]::GetEnvironmentVariable($k) }
try {
    $rgProcs += Start-Process -FilePath 'python3' -ArgumentList @('-m', 'http.server', "$comfyPort", '--bind', '127.0.0.1', '--directory', $rgDir) -PassThru `
        -RedirectStandardOutput (Join-Path $rgDir 'comfy.log') -RedirectStandardError (Join-Path $rgDir 'comfy.err')
    foreach ($k in $rgEnv.Keys) { Set-LaiProcessEnv -Name $k -Value $rgEnv[$k] }
    $rgProcs += Start-Process -FilePath 'python3' -ArgumentList @('-u', (Join-Path $root 'stack/render-guard/render_guard.py')) -PassThru `
        -RedirectStandardOutput (Join-Path $rgDir 'guard.log') -RedirectStandardError (Join-Path $rgDir 'guard.err')
    foreach ($k in $rgEnv.Keys) { Set-LaiProcessEnv -Name $k -Value $rgEnvBefore[$k] }
    $rgUrl = "http://127.0.0.1:$rgPort"
    $up = $null
    for ($i = 0; $i -lt 60 -and -not ($up -and $up.comfyui -and $up.comfyui.busy); $i++) {
        try { $up = Invoke-RestMethod "$rgUrl/render-guard/status" -TimeoutSec 5 } catch { Write-Verbose 'guard not up yet' }
        if (-not ($up -and $up.comfyui -and $up.comfyui.busy)) { Start-Sleep -Milliseconds 500 }
    }
    if (-not ($up -and $up.comfyui -and $up.comfyui.busy)) { throw "render guard or fake ComfyUI did not start (status: $($up | ConvertTo-Json -Compress -Depth 5))" }
    $gen = { (Invoke-RestMethod -Method POST -Uri "$rgUrl/api/generate" -ContentType 'application/json' -TimeoutSec 900 `
        -Body (@{ model = @($catalog.Models)[0].Alias; prompt = 'Say OK.'; stream = $false; options = @{ num_predict = 1 } } | ConvertTo-Json -Depth 5)) }
    Stop-LaiOllamaModels -BaseUrl $OllamaUrl
    & $gen | Out-Null                       # render running: loaded with num_gpu 0
    $reused = & $gen                        # render running: reuses that runner
    Set-Content -LiteralPath $queueFile -Encoding ascii -Value '{"queue_running": [], "queue_pending": []}'
    Start-Sleep -Seconds 5                  # past HOLD_SEC
    $after = & $gen
    $reusedMs = [double]$reused.load_duration / 1e6
    $afterMs = [double]$after.load_duration / 1e6
    $unloaded = [int](Invoke-RestMethod "$rgUrl/render-guard/status" -TimeoutSec 10).stats.ollama_unloaded
    if ($afterMs -lt [Math]::Max(150, 4 * $reusedMs) -or $unloaded -lt 1) {
        Write-LaiLog FAIL ("render guard: the first chat after the render reused the CPU runner (load {0:N0} ms vs {1:N0} ms reused, guard unloads: {2}); guard log: {3}" -f $afterMs, $reusedMs, $unloaded, ((Get-Content -Raw (Join-Path $rgDir 'guard.log')) -replace '\s+', ' '))
        $failures++
    } else { Write-LaiLog OK ("render guard: after the render the chat model is loaded fresh, not kept on the CPU runner (load {0:N0} ms vs {1:N0} ms reused)" -f $afterMs, $reusedMs) }
} catch {
    Write-LaiLog FAIL "render guard against the real Ollama: $($_.Exception.Message)"; $failures++
} finally {
    foreach ($k in $rgEnv.Keys) { Set-LaiProcessEnv -Name $k -Value $rgEnvBefore[$k] }
    foreach ($p in $rgProcs) { try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } } catch { Write-Verbose 'already gone' } }
    try { Stop-LaiOllamaModels -BaseUrl $OllamaUrl } catch { Write-Verbose 'unload failed' }
    Remove-Item -LiteralPath $rgDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -eq 0) { Write-LaiLog OK 'INTEGRATION TEST PASSED' } else { Write-LaiLog FAIL "INTEGRATION TEST FAILED ($failures)" }
exit $failures
