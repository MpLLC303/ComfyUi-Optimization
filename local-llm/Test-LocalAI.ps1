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
#>
param(
    [string]$AIRoot = 'C:\AI',
    [switch]$Quick,
    # Defaults to config\models.psd1 next to this script.
    [string]$CatalogPath = '',
    # For the Linux integration harness, where Open WebUI is not a container.
    [switch]$NoContainers
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

Add-Check 'Ollama running' { Pass "v$(Get-LaiOllamaVersion -BaseUrl $ollamaUrl) on $ollamaUrl" }

foreach ($m in $catalog.Models) {
    Add-Check "$($m.Display) installed" {
        if (-not (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $m.Source)) { return (Fail "$($m.Source) missing") }
        if (-not (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $m.Alias)) { return (Fail "tuned alias $($m.Alias) missing (re-run the installer)") }
        Pass "$($m.Source) -> $($m.Alias)"
    }
}

if (-not $Quick) {
    foreach ($m in $catalog.Models) {
        Add-Check "$($m.Display) fully on GPU" {
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

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($NoContainers) {
    Add-Check 'Docker + containers' { Skip 'not checked (-NoContainers)' }
} else {
    Add-Check 'Docker engine' {
        if (-not $dockerCmd) { return (Fail 'docker CLI not found') }
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $v = (& docker version --format '{{.Server.Version}}' 2>$null); $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($code -ne 0) { return (Fail 'engine not running - start Docker Desktop') }
        Pass "engine $v"
    }
    foreach ($c in @('open-webui', 'searxng')) {
        Add-Check "Container $c" {
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $s = (& docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} {{.HostConfig.RestartPolicy.Name}}' $c 2>$null); $code = $LASTEXITCODE
            $ErrorActionPreference = $prev
            if ($code -ne 0) { return (Fail 'not found') }
            if ($s -notmatch '^running') { return (Fail $s) }
            if ($s -match 'unhealthy') { return (Warn $s) }
            Pass $s
        }
    }
}

Add-Check 'Open WebUI reachable' {
    Wait-LaiWebUI -BaseUrl $webUrl -TimeoutSec 30
    Pass "http://localhost:$webPort"
}

$token = $null
Add-Check 'Open WebUI admin login' {
    $credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
    if (-not (Test-Path -LiteralPath $credFile)) { return (Fail "missing $credFile") }
    $cred = Get-Content -LiteralPath $credFile -Raw | ConvertFrom-Json
    $script:token = Connect-LaiWebUI -BaseUrl $webUrl -Email $cred.email -Password $cred.password
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
    if ($all.Count -gt 0 -and $all[0].Name -like '*-CORRUPT.tar.gz') {
        return (Fail "the newest backup $($all[0].Name) failed its database check; the live Open WebUI data may be damaged (restore from $(if ($newest) { $newest.Name } else { 'an older archive' }))")
    }
    if (-not $newest) { return (Fail "no archive in $dir") }
    $age = (Get-Date) - $newest.LastWriteTime
    $detail = '{0} ({1:N1} MB, {2:N0} h old)' -f $newest.Name, ($newest.Length / 1MB), $age.TotalHours
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
