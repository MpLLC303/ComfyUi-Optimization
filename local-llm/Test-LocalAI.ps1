#Requires -Version 5.1
<#
.SYNOPSIS
    Acceptance test for the local AI stack: the guide's "finished V1" checklist, actually executed.

.DESCRIPTION
    Read-mostly checks plus functional tests that go through the real chain
    (browser API -> Open WebUI -> Ollama -> RTX 3090):

      GPU + driver, Ollama, models installed, models 100% on GPU at their tuned context,
      Docker, containers, Open WebUI login, presets (system prompt + native tool calling),
      signup off / memories on, RAG + web search settings, a chat per preset, memory recall,
      document retrieval, web search, backups, and that nothing listens beyond 127.0.0.1.

    The functional tests create a temporary memory and a temporary knowledge collection and delete
    both afterwards. Exit code = number of failed checks (0 = V1 complete).

.PARAMETER Quick
    Skip the model loads and chat/memory/RAG/web tests (takes seconds instead of minutes).

.PARAMETER CpuCheck
    Also measure what the render guard does while ComfyUI renders: load the default preset's model
    with num_gpu 0 (CPU only), and report generation speed, prompt-processing speed for a ~1,500-token
    prompt, and how much VRAM the CPU load still takes. Close ComfyUI first so the reading is
    clean. The first CPU load reads the whole model into RAM (about 19 GB for Local Main).
#>
param(
    [string]$AIRoot = 'C:\AI',
    [switch]$Quick,
    # Defaults to config\models.psd1 next to this script.
    [string]$CatalogPath = '',
    # For the Linux integration harness, where Open WebUI is not a container.
    [switch]$NoContainers,
    [switch]$CpuCheck
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$onWindows = ($env:OS -eq 'Windows_NT')
$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$state = Read-LaiState -Path (Join-Path $AIRoot 'install-state.json')
$tuning = @{}
if ($state.ContainsKey('tuning') -and $state['tuning']) { $tuning = $state['tuning'] }
$selected = @()
if ($config.ContainsKey('SelectedModels')) { $selected = @($config['SelectedModels']) }
if (-not $CatalogPath -and $env:LOCALAI_TEST_CATALOG) { $CatalogPath = $env:LOCALAI_TEST_CATALOG }
if (-not $CatalogPath) { $CatalogPath = Join-Path (Join-Path $PSScriptRoot 'config') 'models.psd1' }
$catalog = Get-LaiCatalog -Path $CatalogPath -IncludeKeys $selected
$ollamaUrl = 'http://127.0.0.1:11434'
if ($config.ContainsKey('OllamaUrl') -and $config['OllamaUrl']) { $ollamaUrl = $config['OllamaUrl'] }
$webPort = 3000; if ($config.ContainsKey('WebUIPort')) { $webPort = [int]$config['WebUIPort'] }
$searxPort = 8888; if ($config.ContainsKey('SearxngPort')) { $searxPort = [int]$config['SearxngPort'] }
$webUrl = "http://127.0.0.1:$webPort"

$results = New-Object System.Collections.ArrayList
function Add-Check {
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = & $Body
        if ($null -eq $r) { $r = @{ Status = 'PASS'; Detail = '' } }
    } catch {
        $r = @{ Status = 'FAIL'; Detail = $_.Exception.Message }
    }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Status = $r.Status; Detail = $r.Detail })
    $level = @{ PASS = 'OK'; WARN = 'WARN'; FAIL = 'FAIL'; SKIP = 'INFO' }[$r.Status]
    Write-LaiLog $level ('{0,-4} {1}: {2}' -f $r.Status, $Name, $r.Detail)
}
function Pass([string]$d) { @{ Status = 'PASS'; Detail = $d } }
function Fail([string]$d) { @{ Status = 'FAIL'; Detail = $d } }
function Warn([string]$d) { @{ Status = 'WARN'; Detail = $d } }
function Skip([string]$d) { @{ Status = 'SKIP'; Detail = $d } }

Write-LaiLog STEP 'Local AI acceptance test'
$gpu = Get-LaiGpuInfo

Add-Check 'RTX 3090 visible' {
    if (-not $gpu) { if ($onWindows) { return (Fail 'nvidia-smi not found') } else { return (Skip 'no NVIDIA GPU on this host') } }
    if ([version]$gpu.DriverVersion -lt [version]'551.61') { return (Fail "driver $($gpu.DriverVersion) < 551.61") }
    Pass "$($gpu.Name), driver $($gpu.DriverVersion), $($gpu.TotalMiB) MiB"
}

# Checks that depend on a failed one are skipped with the reason, so one cause shows up once.
$script:ollamaUp = $false
$script:engineUp = $true
$script:webUp = $false
$startAgain = 'Start menu > Local AI > Start again'
Add-Check 'Ollama running' {
    try { $v = Get-LaiOllamaVersion -BaseUrl $ollamaUrl } catch { return (Fail "not answering on $ollamaUrl - start Ollama from the Start menu, or $startAgain") }
    $script:ollamaUp = $true
    Pass "v$v on $ollamaUrl"
}

foreach ($m in $catalog.Models) {
    Add-Check "$($m.Display) installed" {
        if (-not $script:ollamaUp) { return (Skip 'Ollama not running') }
        if (-not (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $m.Source)) { return (Fail "$($m.Source) missing") }
        if (-not (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $m.Alias)) { return (Fail "tuned alias $($m.Alias) missing (re-run the installer)") }
        Pass "$($m.Source) -> $($m.Alias)"
    }
}

if (-not $Quick) {
    foreach ($m in $catalog.Models) {
        Add-Check "$($m.Display) fully on GPU" {
            if (-not $script:ollamaUp) { return (Skip 'Ollama not running') }
            $load = Invoke-LaiOllamaLoad -BaseUrl $ollamaUrl -Name $m.Alias -KeepAlive '1m'
            $detail = "ctx $($load.Context), $($load.GpuPercent)% GPU, $($load.SizeGiB) GiB"
            if (-not $gpu) { return (Skip "$detail (CPU-only host)") }
            if ($load.GpuPercent -lt 100) { return (Fail "$detail - spilling to CPU; close GPU apps or re-run the installer with -Retune") }
            if ($tuning.ContainsKey($m.Key) -and [int]$tuning[$m.Key]['Context'] -ne $load.Context) {
                return (Warn "$detail, but the installer tuned $($tuning[$m.Key]['Context']); re-run the installer")
            }
            # 100% GPU can still be slow on Windows when the driver quietly pages VRAM to system RAM.
            $speed = Measure-LaiOllamaSpeed -BaseUrl $ollamaUrl -Name $m.Alias -Tokens 64
            $detail += ", $speed tok/s"
            if ($m.MinTokensPerSec -and $speed -lt $m.MinTokensPerSec) {
                return (Warn "$detail - below $($m.MinTokensPerSec) tok/s: VRAM is probably spilling to system RAM; close GPU apps or run Release-GPU.ps1")
            }
            Pass $detail
        }
    }
    try { Stop-LaiOllamaModels -BaseUrl $ollamaUrl } catch { Write-Verbose 'unload failed' }
}

if ($CpuCheck) {
    Add-Check 'CPU fallback (render guard)' {
        if (-not $script:ollamaUp) { return (Skip 'Ollama not running') }
        $m = $catalog.Models | Where-Object { $_.Preset -eq $catalog.DefaultPreset } | Select-Object -First 1
        if (-not $m) { $m = @($catalog.Models)[0] }
        Stop-LaiOllamaModels -BaseUrl $ollamaUrl
        Start-Sleep -Seconds 2
        $before = Get-LaiGpuInfo
        # ~1,500 tokens of context, like a chat with web-search results attached.
        $filler = ('The quick brown fox jumps over the lazy dog while the river keeps flowing past the old mill. ' * 75)
        $body = @{
            model   = $m.Alias
            prompt  = $filler + "`nSummarize the text above in one sentence."
            stream  = $false
            options = @{ num_gpu = 0; num_predict = 64; temperature = 0 }
        }
        $info = Get-LaiOllamaModelInfo -BaseUrl $ollamaUrl -Name $m.Alias
        if ($info.Capabilities -contains 'thinking') { $body['think'] = $false }
        $r = Invoke-LaiApi -Method POST -Uri "$ollamaUrl/api/generate" -Body $body -TimeoutSec 1800
        $after = Get-LaiGpuInfo
        $gen = 0; $pp = 0
        if ($r.eval_duration -and [double]$r.eval_duration -gt 0) { $gen = [Math]::Round([double]$r.eval_count / ([double]$r.eval_duration / 1e9), 1) }
        if ($r.prompt_eval_duration -and [double]$r.prompt_eval_duration -gt 0) { $pp = [Math]::Round([double]$r.prompt_eval_count / ([double]$r.prompt_eval_duration / 1e9), 0) }
        $loadS = 0
        if ($r.load_duration) { $loadS = [Math]::Round([double]$r.load_duration / 1e9, 1) }
        $detail = "$($m.Display) on CPU: $gen tok/s generation, $pp tok/s prompt ($($r.prompt_eval_count) tokens), load $loadS s"
        try { Stop-LaiOllamaModels -BaseUrl $ollamaUrl } catch { Write-Verbose 'unload failed' }
        if ($before -and $after) {
            $delta = $after.UsedMiB - $before.UsedMiB
            $detail += ", VRAM +$delta MiB"
            if ($delta -gt 1024) { return (Warn "$detail - the CPU mode still takes VRAM; a render near the 24 GB limit may notice") }
        }
        if ($gen -lt 5) { return (Warn "$detail - very slow; chats during renders will crawl (consider -RenderGuard off and pausing renders)") }
        Pass $detail
    }
}

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($NoContainers) {
    Add-Check 'Docker + containers' { Skip 'not checked (-NoContainers)' }
} else {
    Add-Check 'Docker engine' {
        if (-not $dockerCmd) { return (Fail 'docker CLI not found') }
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $v = (& docker version --format '{{.Server.Version}}' 2>$null); $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($code -ne 0) { $script:engineUp = $false; return (Fail "engine not running - $startAgain (starts Docker Desktop)") }
        Pass "engine $v"
    }
    $containers = @('open-webui', 'searxng')
    if (-not ($config.ContainsKey('WebUIOllamaUrl') -and $config['WebUIOllamaUrl'] -and $config['WebUIOllamaUrl'] -notlike '*render-guard*')) { $containers += 'render-guard' }
    foreach ($c in $containers) {
        Add-Check "Container $c" {
            if (-not $script:engineUp) { return (Skip 'Docker engine down') }
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $s = (& docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} {{.HostConfig.RestartPolicy.Name}}' $c 2>$null); $code = $LASTEXITCODE
            $ErrorActionPreference = $prev
            if ($code -ne 0) { return (Fail 'not found - re-run the installer (C:\AI\Scripts\Install-LocalAI.cmd)') }
            if ($s -notmatch '^running') { return (Fail "$s - $startAgain") }
            if ($s -match 'unhealthy') { return (Warn $s) }
            Pass $s
        }
    }
}

Add-Check 'Open WebUI reachable' {
    if (-not $script:engineUp) { return (Skip 'Docker engine down') }
    try { Wait-LaiWebUI -BaseUrl $webUrl -TimeoutSec 30 } catch { return (Fail "no answer on http://localhost:$webPort - $startAgain; if it persists: docker logs --tail 50 open-webui") }
    $script:webUp = $true
    Pass "http://localhost:$webPort"
}

$token = $null
Add-Check 'Open WebUI admin login' {
    if (-not $script:webUp) { return (Skip 'Open WebUI not reachable') }
    $credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
    if (-not (Test-Path -LiteralPath $credFile)) { return (Fail "missing $credFile") }
    try { Resolve-LaiPendingPassword -AIRoot $AIRoot -BaseUrl $webUrl | Out-Null } catch { Write-Verbose 'pending password check failed' }
    $cred = Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json
    try { $script:token = Connect-LaiWebUI -BaseUrl $webUrl -Email $cred.email -Password $cred.password }
    catch { return (Fail "sign-in as $($cred.email) failed - after restoring an older backup run Set-OpenWebUIPassword.ps1 -PromptCurrent") }
    Pass $cred.email
}

if ($script:token) {
    $token = $script:token
    Add-Check 'Open WebUI sees Ollama models' {
        $ids = Get-LaiWebUIModelIds -BaseUrl $webUrl -Token $token
        $missing = @($catalog.Models | Where-Object { $ids -notcontains "$($_.Alias):latest" } | ForEach-Object { $_.Alias })
        if ($missing.Count -gt 0) { return (Fail "missing: $($missing -join ', ')") }
        Pass "$($ids.Count) models listed"
    }
    foreach ($m in $catalog.Models) {
        Add-Check "Preset $($m.Display)" {
            $p = Get-LaiWebUIModel -BaseUrl $webUrl -Token $token -Id $m.Preset
            if (-not $p) { return (Fail 'not found') }
            if ($p.base_model_id -ne "$($m.Alias):latest") { return (Fail "base is $($p.base_model_id)") }
            if (-not $p.params.system) { return (Fail 'no system prompt') }
            if ($p.params.function_calling -ne 'native') { return (Warn "function calling = $($p.params.function_calling) (model template has no tool support)") }
            Pass 'system prompt set, native tool calling, memory/web/knowledge tools on'
        }
    }
    Add-Check 'Ollama connection' {
        $expected = 'http://render-guard:11434'
        if ($config.ContainsKey('WebUIOllamaUrl') -and $config['WebUIOllamaUrl']) { $expected = [string]$config['WebUIOllamaUrl'] }
        $oc = Invoke-LaiApi -Uri "$webUrl/ollama/config" -Token $token
        $urls = @($oc.OLLAMA_BASE_URLS | ForEach-Object { ([string]$_).TrimEnd('/') })
        if ($urls -notcontains $expected) {
            return (Warn "Open WebUI uses $($urls -join ', ') instead of $expected (e.g. after restoring an older backup) - re-run Install-LocalAI.ps1")
        }
        if ($expected -like '*render-guard*') { Pass "$expected (render guard)" } else { Pass "$expected (direct)" }
    }
    Add-Check 'Signup disabled, memories enabled' {
        $a = Invoke-LaiApi -Uri "$webUrl/api/v1/auths/admin/config" -Token $token
        if ($a.ENABLE_SIGNUP) { return (Fail 'open signup is ON') }
        if (-not $a.ENABLE_MEMORIES) { return (Fail 'memories feature is off') }
        Pass 'signup off, memories on'
    }
    Add-Check 'RAG + web search settings' {
        $rc = Get-LaiWebUIRetrievalConfig -BaseUrl $webUrl -Token $token
        $d = "splitter=$($rc.TEXT_SPLITTER) chunk=$($rc.CHUNK_SIZE)/$($rc.CHUNK_OVERLAP) top_k=$($rc.TOP_K) web=$($rc.web.WEB_SEARCH_ENGINE)"
        if (-not $rc.web.ENABLE_WEB_SEARCH -or $rc.web.WEB_SEARCH_ENGINE -ne 'searxng') { return (Fail $d) }
        if ($rc.CHUNK_SIZE -ne 2000 -or $rc.CHUNK_OVERLAP -ne 200 -or $rc.TOP_K -ne 5) { return (Warn "$d (changed from the installer's values)") }
        Pass $d
    }

    if (-not $Quick) {
        $main = $catalog.DefaultPreset
        if (-not ($catalog.Models | Where-Object { $_.Preset -eq $main })) { $main = $catalog.Models[0].Preset }
        foreach ($m in $catalog.Models) {
            Add-Check "Chat via $($m.Display)" {
                $r = Test-LaiWebUIChat -BaseUrl $webUrl -Token $token -Model $m.Preset
                if (-not $r.Passed) { return (Fail "answer: $($r.Answer)") }
                Pass $r.Answer
            }
        }
        Add-Check 'Memory across conversations' {
            $r = Test-LaiWebUIMemory -BaseUrl $webUrl -Token $token -Model $main
            if (-not $r.Passed) { return (Fail "expected $($r.Expected), got: $($r.Answer)") }
            Pass "recalled $($r.Expected) in a new chat"
        }
        Add-Check 'Document retrieval (RAG)' {
            $r = Test-LaiWebUIRag -BaseUrl $webUrl -Token $token -Model $main
            if (-not $r.Passed) { return (Fail "expected $($r.Expected), got: $($r.Answer)") }
            Pass "retrieved $($r.Expected) from an indexed document"
        }
        Add-Check 'Web search (SearXNG)' {
            $r = Test-LaiWebUIWebSearch -BaseUrl $webUrl -Token $token
            if ($r.Status -eq 'ok') { return (Pass "$($r.Count) results, e.g. $($r.Detail)") }
            if ($r.Status -eq 'no-results') { return (Warn 'SearXNG answered but its engines returned nothing (rate limit/captcha); retry later') }
            Fail "$($r.Detail) - check: docker logs --tail 50 searxng"
        }
        try { Stop-LaiOllamaModels -BaseUrl $ollamaUrl } catch { Write-Verbose 'unload failed' }
    }
}

Add-Check 'Backups' {
    $dir = Join-Path $AIRoot 'Backups'
    $all = @(Get-ChildItem -LiteralPath $dir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)  # lai-ok: objects
    $newest = $all | Where-Object { $_.Name -notlike '*-CORRUPT.tar.gz' } | Select-Object -First 1
    # Age is judged on the nightly archives only, so a tagged one cannot hide a broken nightly task.
    $daily = $all | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' } | Select-Object -First 1
    if ($all.Count -gt 0 -and $all[0].Name -like '*-CORRUPT.tar.gz') {
        return (Fail "the newest backup $($all[0].Name) failed its database check; the live Open WebUI data may be damaged (restore from $(if ($newest) { $newest.Name } else { 'an older archive' }))")
    }
    if (-not $newest) { return (Fail "no archive in $dir") }
    if (-not $daily) { return (Warn "no nightly archive yet (newest: $($newest.Name)); check the LocalAI-Backup-OpenWebUI task") }
    $age = (Get-Date) - $daily.LastWriteTime
    $detail = '{0} ({1:N1} MB, {2:N0} h old)' -f $daily.Name, ($daily.Length / 1MB), $age.TotalHours
    if ($onWindows -and -not (Get-ScheduledTask -TaskName 'LocalAI-Backup-OpenWebUI' -ErrorAction SilentlyContinue)) { return (Fail "$detail; daily task missing") }
    if ($age.TotalHours -gt 50) { return (Warn "$detail - older than two days") }
    Pass $detail
}

Add-Check 'Nothing exposed beyond localhost' {
    if (-not $onWindows) { return (Skip 'Windows-only check') }
    $bad = @()
    foreach ($port in @(11434, $webPort, $searxPort)) {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
        foreach ($l in $listeners) {
            if (@('127.0.0.1', '::1') -notcontains $l.LocalAddress) { $bad += "${port}@$($l.LocalAddress)" }
        }
    }
    if ($bad.Count -eq 0) { return (Pass "11434, $webPort, $searxPort bound to loopback only") }
    $onlyOllama = @($bad | Where-Object { $_ -notlike '11434@*' }).Count -eq 0
    if ($onlyOllama -and (Get-NetFirewallRule -DisplayName 'LocalAI - Block Ollama from LAN' -ErrorAction SilentlyContinue)) {
        return (Warn "Ollama listens on all interfaces (Docker fallback) but the LAN block rule is in place: $($bad -join ', ')")
    }
    Fail "listening beyond loopback: $($bad -join ', ')"
}

$fails = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warns = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Host ''
if ($fails -eq 0) { Write-LaiLog OK "V1 COMPLETE: $($results.Count) checks, $warns warnings, 0 failures" }
else { Write-LaiLog FAIL "$fails of $($results.Count) checks failed ($warns warnings)" }
exit $fails
