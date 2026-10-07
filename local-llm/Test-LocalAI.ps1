#Requires -Version 5.1

<#
.SYNOPSIS
    Acceptance test for the local AI stack: the guide's "finished V1" checklist, actually executed.

.DESCRIPTION
    Read-mostly checks plus functional tests that go through the real chain
    (browser API -> Open WebUI -> Ollama -> RTX 3090):

      GPU + driver, Ollama, models installed, presets measured on the running Ollama version (and
      the nightly re-check that keeps them so), models 100% on GPU at their tuned context, a direct SearXNG search (names failed engines),
      Docker, containers, Open WebUI login, presets (system prompt + native tool calling, image
      upload matching what Ollama reports for the model), no context size set in Open WebUI over
      the tuned aliases, signup off / memories on, RAG + web search settings, a chat per preset, an
      image read by each preset with images (Uncensored Vision), memory recall, document retrieval, web
      search, backups, and that nothing listens beyond 127.0.0.1.

    The functional tests create a temporary memory and a temporary knowledge collection and delete
    both afterwards. Exit code = number of failed checks (0 = V1 complete).

.PARAMETER Quick
    Skip the model loads and chat/image/memory/RAG/web tests (takes seconds instead of minutes).

.PARAMETER CpuCheck
    Also measure what the render guard does while ComfyUI renders: load the default preset's model
    with num_gpu 0 (CPU only), and report generation speed, prompt-processing speed for a ~1,500-token
    prompt, and how much VRAM the CPU load still takes. Close ComfyUI first so the reading is
    clean. The first CPU load reads the whole model into RAM (about 19 GB for Uncensored Main).
#>
param(
    # Install folder (the installer's -AIRoot).
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
# Optional research agent (Install-LocalAI.ps1 -DeepResearch); 0 = not installed.
$researchPort = 0; if ($config.ContainsKey('DeepResearchPort') -and $config['DeepResearchPort']) { $researchPort = [int]$config['DeepResearchPort'] }
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

Add-Check 'NVIDIA GPU visible' {
    if (-not $gpu) { if ($onWindows) { return (Fail 'nvidia-smi not found or lists no GPU') } else { return (Skip 'no NVIDIA GPU on this host') } }
    if ([version]$gpu.DriverVersion -lt [version]'551.61') { return (Fail "driver $($gpu.DriverVersion) < 551.61") }
    Pass "$($gpu.Name), driver $($gpu.DriverVersion), $($gpu.TotalMiB) MiB"
}

# Checks that depend on a failed one are skipped with the reason, so one cause shows up once.
$script:ollamaUp = $false
$script:engineUp = $true
$script:webUp = $false
$script:searxUp = $true
$startAgain = 'Start menu > Local AI > Start again'
Add-Check 'Ollama running' {
    try { $v = Get-LaiOllamaVersion -BaseUrl $ollamaUrl } catch { return (Fail "not answering on $ollamaUrl - start Ollama from the Start menu, or $startAgain") }
    $script:ollamaUp = $true
    $script:ollamaVer = [string]$v
    Pass "v$v on $ollamaUrl"
}

# The Ollama app installs its own updates at sign-in; the presets were measured on one version.
Add-Check 'Presets measured on this Ollama' {
    if (-not $script:ollamaUp) { return (Skip 'Ollama not running') }
    $known = @($catalog.Models | Where-Object { $tuning.ContainsKey($_.Key) -and $tuning[$_.Key]['OllamaVersion'] })
    if ($known.Count -eq 0) { return (Skip 'no tuning with a recorded Ollama version') }
    $drift = @(Get-LaiTuningDrift -Tuning $tuning -OllamaVersion $script:ollamaVer -Keys @($catalog.Models | ForEach-Object { $_.Key }))
    if ($drift.Count -eq 0) { return (Pass "all $($known.Count) measured on Ollama $($script:ollamaVer)") }
    $was = @($drift | ForEach-Object { $_.Was } | Select-Object -Unique) -join ', '
    $how = 'Start menu > Local AI - Re-check models checks them on the GPU again (no downloads, about a minute each)'
    if ($config['ModelRecheckAt']) { $how = "the nightly re-check at $($config['ModelRecheckAt']) does that by itself while the PC is idle, or Start menu > Local AI - Re-check models checks them now (no downloads, about a minute each)" }
    Warn "Ollama is now $($script:ollamaVer) (it updates itself), but $(@($drift | ForEach-Object { $_.Key }) -join ', ') were measured on $was - $how"
}

# The re-check after the Ollama app has updated itself (Update-Models.ps1 -RecheckOnly -Scheduled).
Add-Check 'Nightly model re-check' {
    if ($onWindows) {
        $task = Get-ScheduledTask -TaskName 'LocalAI-Recheck-Models' -ErrorAction SilentlyContinue
        if (-not $task) { return (Fail 'the LocalAI-Recheck-Models task is missing, so the presets are not re-checked after Ollama updates itself - run Start menu > Local AI - Update toolkit to set it up again') }
        if ([string]$task.State -eq 'Disabled') { return (Fail 'the LocalAI-Recheck-Models task is disabled - enable it in Task Scheduler (Task Scheduler Library > LocalAI-Recheck-Models > Enable)') }
    }
    $rec = Read-LaiState -Path (Join-Path $AIRoot 'model-recheck.json')
    if (-not $rec['result']) { return (Pass 'not needed yet (it runs only on nights after Ollama has updated itself)') }
    # PowerShell 7's ConvertFrom-Json already turns the ISO time into a date; 5.1 leaves the string.
    $at = $rec['at']; if ($at -is [datetime]) { $at = $at.ToString('s') }
    $what = "last result $($rec['result']) on Ollama $($rec['ollamaVersion']) ($at)"
    if (@('off-gpu', 'failed') -contains [string]$rec['result'] -and $script:ollamaVer -and [string]$rec['ollamaVersion'] -eq $script:ollamaVer) {
        return (Warn "${what}: $(@($rec['presets']) -join ', ') ($($rec['reason'])) - close ComfyUI and games, then Start menu > Local AI - Re-check models (details: Logs\model-recheck.log)")
    }
    if ([string]$rec['result'] -eq 'skipped') { $what += ": $($rec['reason'])" }
    Pass $what
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
            if ($load.GpuPercent -lt 100) { return (Fail "$detail - spilling to CPU; close GPU apps (Start menu > Local AI - Gaming mode frees the GPU from this stack), then run the health check again") }
            if ($tuning.ContainsKey($m.Key) -and [int]$tuning[$m.Key]['Context'] -ne $load.Context) {
                return (Warn "$detail, but the installer tuned $($tuning[$m.Key]['Context']); re-run the installer")
            }
            # 100% GPU can still be slow on Windows when the driver quietly pages VRAM to system RAM.
            $speed = Measure-LaiOllamaSpeed -BaseUrl $ollamaUrl -Name $m.Alias -Tokens 64
            $detail += ", $speed tok/s"
            if ($m.MinTokensPerSec -and $speed -lt $m.MinTokensPerSec) {
                return (Warn "$detail - below $($m.MinTokensPerSec) tok/s: VRAM is probably spilling to system RAM; close GPU-heavy apps (games, ComfyUI) and run the health check again")
            }
            Pass $detail
        }
    }
    try { Stop-LaiOllamaModels -BaseUrl $ollamaUrl } catch { Write-Verbose 'unload failed' }
}

if ($CpuCheck) {
    Add-Check 'CPU fallback (render guard)' {
        if (-not $script:ollamaUp) { return (Skip 'Ollama not running') }
        $m = $catalog.Models | Where-Object { $_.Preset -eq $catalog.BaseDefaultPreset } | Select-Object -First 1
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
    if ($researchPort -gt 0) { $containers += 'deep-research' }
    if (-not ($config.ContainsKey('WebUIOllamaUrl') -and $config['WebUIOllamaUrl'] -and $config['WebUIOllamaUrl'] -notlike '*render-guard*')) { $containers += 'render-guard' }
    foreach ($c in $containers) {
        Add-Check "Container $c" {
            if ($c -eq 'searxng') { $script:searxUp = $false }
            if (-not $script:engineUp) { return (Skip 'Docker engine down') }
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $s = (& docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} {{.HostConfig.RestartPolicy.Name}}' $c 2>$null); $code = $LASTEXITCODE
            $ErrorActionPreference = $prev
            if ($code -ne 0) { return (Fail "not found - re-run the installer: double-click $(Join-Path (Join-Path $AIRoot 'Scripts') 'Install-LocalAI.cmd') and click Yes") }
            if ($s -notmatch '^running') { return (Fail "$s - $startAgain") }
            if ($c -eq 'searxng') { $script:searxUp = $true }
            if ($s -match 'unhealthy') { return (Warn $s) }
            Pass $s
        }
    }
}

# One search straight against SearXNG (also in -Quick: one request, no model): an empty answer names
# each failed engine and why, which Open WebUI's own web search cannot show. The probe waits up to
# 60 s for SearXNG to finish starting (an update just recreated the container).
Add-Check 'SearXNG search' {
    if (-not $script:engineUp) { return (Skip 'Docker engine down') }
    if (-not $script:searxUp) { return (Skip 'SearXNG container not running') }
    try { $p = Get-LaiSearxngProbe -BaseUrl "http://127.0.0.1:$searxPort" }
    catch { return (Fail "no search answer on http://127.0.0.1:$searxPort ($((Get-LaiHttpErrorText $_))) - $startAgain; if it persists: docker logs --tail 50 searxng") }
    if ($p.Count -gt 0) { return (Pass $p.Summary) }
    Warn $p.Summary
}

if ($researchPort -gt 0) {
    # One sign-in for both checks: Local Deep Research allows 5 per 15 minutes.
    $script:research = $null
    Add-Check 'Deep research signs in and reaches its model' {
        if (-not $script:engineUp) { return (Skip 'Docker engine down') }
        $rUrl = "http://127.0.0.1:$researchPort"
        try { Wait-LaiHttp -Uri "$rUrl/api/v1/health" -TimeoutSec 30 | Out-Null }
        catch { return (Fail "no answer on http://localhost:$researchPort - $startAgain; if it persists: docker logs --tail 50 deep-research") }
        $rCredFile = Join-Path (Join-Path $AIRoot 'Secrets') 'deep-research.json'
        if (-not (Test-Path -LiteralPath $rCredFile)) { return (Fail "missing $rCredFile - run the installer again (it creates the account)") }
        $rc = Get-Content -Encoding UTF8 -Raw -LiteralPath $rCredFile | ConvertFrom-Json
        $rModel = 'localai-main:latest'; $rOllama = 'http://render-guard:11434'
        $envFile = Join-Path (Join-Path $AIRoot 'Stack') '.env'
        if (Test-Path -LiteralPath $envFile) {
            foreach ($l in (Get-Content -Encoding UTF8 -LiteralPath $envFile)) {
                if ($l -like 'DEEP_RESEARCH_MODEL=*') { $rModel = $l.Substring(20) }
                if ($l -like 'DEEP_RESEARCH_OLLAMA_URL=*') { $rOllama = $l.Substring(25) }
            }
        }
        try { $script:research = Connect-LaiResearch -BaseUrl $rUrl -Account $rc.username -Password $rc.password -TimeoutSec 900 }
        catch { return (Fail "$($_.Exception.Message) (account in $rCredFile)") }
        if (-not (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $rModel)) { return (Fail "signed in, but its model $rModel is not in Ollama - run the installer again") }
        $reach = Test-LaiResearchOllama -OllamaUrl $rOllama
        if (-not $reach.Ok) { return (Fail "signed in, but $($reach.Message) - $startAgain") }
        Pass "http://localhost:$researchPort, model $rModel via $rOllama"
    }
    if (-not $Quick) {
        Add-Check 'Deep research answers a question' {
            if (-not $script:research) { return (Skip 'deep research not signed in') }
            try { $q = Invoke-LaiResearchQuick -Session $script:research -Query 'What is the capital of France? Answer in one sentence.' }
            catch { return (Fail "$($_.Exception.Message) - docker logs --tail 80 deep-research") }
            if (-not $q.Summary.Trim()) { return (Fail 'the run finished without an answer - docker logs --tail 80 deep-research') }
            # It answers only from sources; none = the sites SearXNG asks returned nothing (see the SearXNG search check).
            if ($q.Sources -eq 0) { return (Warn 'it ran, but the searches found no pages (see SearXNG search above); it answers only from sources') }
            Pass ("{0} sources, {1} findings" -f $q.Sources, $q.Findings)
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
Add-Check 'Open WebUI version' {
    if (-not $script:webUp) { return (Skip 'Open WebUI not reachable') }
    $ver = [string](Invoke-LaiApi -Uri "$webUrl/api/version" -TimeoutSec 15).version
    switch (Get-LaiWebUICompat -Version $ver) {
        'tested' { Pass "$ver (the version this toolkit was tested with)" }
        'newer' { Warn "$ver is newer than the tested 0.11.4; if a check below fails, Update-OpenWebUI.ps1 -Rollback goes back" }
        default { Warn "$ver (tested with 0.11.4)" }
    }
}
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
    Add-Check 'Skills and the skill notebook' {
        $skillDir = Join-Path $AIRoot 'Skills'
        $all = Get-LaiWebUISkills -BaseUrl $webUrl -Token $token
        $files = @()
        if (Test-Path -LiteralPath $skillDir) { $files = @(Get-ChildItem -LiteralPath $skillDir -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') }) }
        # A folder whose skill is not in Open WebUI as a folder skill (a skill made there with the same id
        # does not count), or that the sync still has switched off as removed. Switched off by you counts.
        $notLoaded = @($files | Where-Object {
                $sk = $all[(ConvertTo-LaiSkillId $_.Name)]
                -not (Test-LaiSkillTag $sk 'localai-folder') -or (Test-LaiSkillTag $sk 'localai-removed')
            } | ForEach-Object { $_.Name })
        $drafts = @($all.Values | Where-Object { (Test-LaiSkillTag $_ 'learned') -and -not $_.is_active })
        $on = @($all.Values | Where-Object { $_.is_active }).Count
        $main = Get-LaiWebUIModel -BaseUrl $webUrl -Token $token -Id $catalog.BaseDefaultPreset
        $hasNotebook = $main -and $main.meta -and $main.meta.PSObject.Properties['toolIds'] -and (@($main.meta.toolIds) -contains 'localai_skill_notebook')
        $draftNote = ''; if ($drafts.Count) { $draftNote = "; $($drafts.Count) learned draft(s) waiting for you in Workspace > Skills" }
        if (-not $hasNotebook) { return (Warn "the skill notebook is not offered in $($catalog.BaseDefaultPreset) - run the installer again$draftNote") }
        if ($notLoaded.Count) { return (Warn "not loaded yet: $($notLoaded -join ', ') - Start menu > Local AI > Sync skills$draftNote") }
        Pass "$on skill(s) on, notebook offered$draftNote"
    }
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
            # Image upload on the preset against what Ollama reports for the model (no model load).
            $presetVision = $false
            if ($p.meta -and $p.meta.capabilities -and $p.meta.capabilities.vision -eq $true) { $presetVision = $true }
            $caps = $null
            if ($script:ollamaUp) { try { $caps = @((Get-LaiOllamaModelInfo -BaseUrl $ollamaUrl -Name $m.Alias).Capabilities) } catch { Write-Verbose "no model info for $($m.Alias)" } }
            if ($null -ne $caps) {
                switch (Test-LaiPresetVision -PresetVision $presetVision -Capabilities $caps) {
                    'missing' { return (Fail "the preset accepts images, but Ollama reports no vision support for $($m.Alias), so every image fails; if a model update caused this, Update-Models.ps1 -Rollback $($m.Key) brings the previous version back") }
                    'unused' { return (Warn "Ollama reports vision support for $($m.Alias), but the preset refuses images (Vision = `$false for '$($m.Key)' in config\models.psd1)") }
                }
            }
            if ($p.params.function_calling -ne 'native') { return (Warn "function calling = $($p.params.function_calling) (model template has no tool support)") }
            Pass "system prompt set, native tool calling, memory/web/knowledge tools on$(if ($presetVision) { ', images on' })"
        }
    }
    Add-Check 'Context decided by the tuned aliases' {
        $over = @(Get-LaiContextOverride -BaseUrl $webUrl -Token $token -PresetIds @($catalog.Models | ForEach-Object { $_.Preset }))
        if ($over.Count -gt 0) {
            return (Warn "Open WebUI sets its own context in $($over -join '; '). Chats then run at that size, reload the model for background tasks or spill to the CPU: set Context Length (and Batch Size) back to Default there")
        }
        Pass 'no num_ctx/num_batch in your settings, the default parameters or the presets'
    }
    Add-Check 'Ollama connection' {
        $expected = 'http://render-guard:11434'
        if ($config.ContainsKey('WebUIOllamaUrl') -and $config['WebUIOllamaUrl']) { $expected = [string]$config['WebUIOllamaUrl'] }
        $oc = Invoke-LaiApi -Uri "$webUrl/ollama/config" -Token $token
        $urls = @($oc.OLLAMA_BASE_URLS | ForEach-Object { ([string]$_).TrimEnd('/') })
        # Actually through Open WebUI to Ollama, not just the setting: catches a render guard that is
        # down or a stale firewall rule (LAN-fallback installs after WSL picked a new subnet). Probed
        # even when the URL is not the expected one, so a broken connection is a FAIL, not a WARN.
        $via = $expected; if ($urls -notcontains $expected) { $via = $urls -join ', ' }
        try { $v = Invoke-LaiApi -Uri "$webUrl/ollama/api/version" -Token $token -TimeoutSec 20 }
        catch { return (Fail "Open WebUI cannot reach Ollama via $via ($((Get-LaiHttpErrorText $_))) - $startAgain; if it persists, re-run Install-LocalAI.cmd (it also refreshes the firewall rule)") }
        if ($urls -notcontains $expected) {
            return (Warn "Open WebUI uses $via instead of $expected (e.g. after restoring an older backup); it works, but re-run Install-LocalAI.ps1 to put it back")
        }
        # Open WebUI answers {"version": false} when its Ollama API is switched off: not a working link.
        if (-not ([string]$v.version -match '^\d')) { return (Fail "Open WebUI reports no Ollama version through $via ($($v.version)): its Ollama connection is switched off or not working - re-run the installer") }
        if ($expected -like '*render-guard*') { Pass "$expected (render guard), Ollama $($v.version)" } else { Pass "$expected (direct), Ollama $($v.version)" }
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
        # Everything else the installer writes (chunking, image scaling, the web-page cap); the SearXNG
        # address depends on the install.
        $changed = @(Compare-LaiConfig -Expected (Get-LaiRagWanted) -Actual $rc | Where-Object { $_ -notlike 'web.SEARXNG_QUERY_URL:*' })
        if ($changed.Count -gt 0) { return (Warn "$d; changed from the installer's values: $($changed -join '; ') - re-run the installer to restore them") }
        # The embedder: Open WebUI's stock one reads only ~256 tokens of each chunk.
        $emb = $null; try { $emb = Invoke-LaiApi -Uri "$webUrl/api/v1/retrieval/embedding" -Token $token } catch { Write-Verbose 'embedding config unreadable' }
        $embNote = ''
        if ($emb) {
            if ([string]$emb.RAG_EMBEDDING_ENGINE -eq '' -and [string]$emb.RAG_EMBEDDING_MODEL -eq 'sentence-transformers/all-MiniLM-L6-v2') {
                return (Warn "$d; document search still uses Open WebUI's stock embedding model (reads ~256 tokens of each chunk) - re-run the installer (it downloads a better one)")
            }
            $embNote = "; embedding $(([string]$emb.RAG_EMBEDDING_ENGINE + ' ' + [string]$emb.RAG_EMBEDDING_MODEL).Trim())$(if ($rc.RAG_RERANKING_MODEL) { ', reranker ' + $rc.RAG_RERANKING_MODEL })"
        }
        Pass "$d$embNote, images scaled to $($rc.FILE_IMAGE_COMPRESSION_WIDTH) px, fetched pages cut at $($rc.web.WEB_FETCH_MAX_CONTENT_LENGTH) characters"
    }

    if (-not $Quick) {
        $main = $catalog.BaseDefaultPreset
        if (-not ($catalog.Models | Where-Object { $_.Preset -eq $main })) { $main = $catalog.Models[0].Preset }
        foreach ($m in $catalog.Models) {
            Add-Check "Chat via $($m.Display)" {
                $r = Test-LaiWebUIChat -BaseUrl $webUrl -Token $token -Model $m.Preset
                if (-not $r.Passed) { return (Fail "answer: $($r.Answer)") }
                Pass $r.Answer
            }
            # Right after its text chat, while the model is still loaded: a real image through the
            # browser's path (Open WebUI's image conversion, render guard, Ollama's projector).
            # Only when the download can read images (the installer turned image upload off otherwise).
            $canSee = $m.Vision
            if ($tuning.ContainsKey($m.Key) -and $tuning[$m.Key] -is [System.Collections.IDictionary] -and $tuning[$m.Key].Contains('Vision') -and -not $tuning[$m.Key]['Vision']) { $canSee = $false }
            if ($canSee) {
                Add-Check "Vision: $($m.Display) reads an image" {
                    try { $r = Test-LaiWebUIVision -BaseUrl $webUrl -Token $token -Model $m.Preset }
                    catch { return (Fail "the image request failed ($((Get-LaiHttpErrorText $_))); if this started after an update, roll it back (Update-Models.ps1 -Rollback $($m.Key) or Update-OpenWebUI.ps1 -Rollback)") }
                    if (-not $r.Passed) { return (Warn "asked for the colour of a plain $($r.Expected) test image, got: $($r.Answer) - attach a picture in a $($m.Display) chat to see whether images reach the model") }
                    Pass "named the colour of a $($r.Expected) test image"
                }
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
            if ($r.Status -eq 'no-results') {
                # Ask SearXNG itself why: a CAPTCHA passes, a scraper broken by a site change does not,
                # and results there mean Open WebUI could not load the pages.
                $why = 'SearXNG answered with nothing; see the SearXNG search check above'
                try { $why = (Get-LaiSearxngProbe -BaseUrl "http://127.0.0.1:$searxPort").WebUIHint } catch { Write-Verbose 'direct SearXNG probe failed' }
                return (Warn "Open WebUI's web search returned no pages: $why")
            }
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
        return (Fail "the newest backup $($all[0].Name) failed its database check; the live Open WebUI data may be damaged (restore the last good one with Restore-OpenWebUI.ps1 -Archive $(if ($newest) { "'$($newest.FullName)'" } else { '<an older archive>' }), see the README's Maintain section)")
    }
    if (-not $newest) { return (Fail "no archive in $dir") }
    if (-not $daily) { return (Warn "no nightly archive yet (newest: $($newest.Name)); the nightly backup task has not run yet; if this stays, run Start menu > Local AI - Update toolkit to set it up again") }
    $age = (Get-Date) - $daily.LastWriteTime
    $detail = '{0} ({1:N1} MB, {2:N0} h old)' -f $daily.Name, ($daily.Length / 1MB), $age.TotalHours
    if ($onWindows -and -not (Get-ScheduledTask -TaskName 'LocalAI-Backup-OpenWebUI' -ErrorAction SilentlyContinue)) { return (Fail "$detail; the nightly backup task is missing - run Start menu > Local AI - Update toolkit to set it up again") }
    if ($age.TotalHours -gt 50) { return (Warn "$detail - older than two days") }
    if ($researchPort -gt 0) {
        # Deep research's own archive, made by the same nightly run (a failure there is only a warning
        # in backup.log, so it is reported here).
        $bs = Read-LaiState -Path (Join-Path $AIRoot 'backup-state.json')
        $rNewest = Get-ChildItem -LiteralPath $dir -Filter 'deep-research-*.tar.gz' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^deep-research-\d{8}-\d{6}\.tar\.gz$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
        if ($bs['researchError']) { return (Warn "$detail; deep research's last backup failed: $($bs['researchError']) (see Logs\backup.log)") }
        if (-not $rNewest) { return (Warn "$detail; no deep research backup yet (the nightly run makes one once deep research is installed)") }
        if (((Get-Date) - $rNewest.LastWriteTime).TotalHours -gt 50) { return (Warn "$detail; deep research's newest backup $($rNewest.Name) is older than two days") }
        $detail += "; deep research $($rNewest.Name)"
    }
    Pass $detail
}

Add-Check 'Health watch' {
    # The watch is what tells you about everything else; nothing would notice if it stopped running.
    $ws = Read-LaiState -Path (Join-Path $AIRoot 'watch-state.json')
    $toDate = { param($v) if ($null -eq $v -or "$v" -eq '') { return $null }; if ($v -is [datetime]) { return $v }; try { return [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null } }
    $fix = 'run Start menu > Local AI - Update toolkit to set it up again'
    if ($onWindows) {
        $task = Get-ScheduledTask -TaskName 'LocalAI-Watch' -ErrorAction SilentlyContinue
        if (-not $task) { return (Fail "the LocalAI-Watch task is missing, so problems are not reported - $fix") }
        if ([string]$task.State -eq 'Disabled') { return (Fail 'the LocalAI-Watch task is disabled, so problems are not reported - enable it in Task Scheduler (Task Scheduler Library > LocalAI-Watch > Enable)') }
    }
    $paused = & $toDate $ws['pausedUntil']
    if ($paused -and (Get-Date) -lt $paused) { return (Warn ("paused until {0:HH:mm} (Watch-LocalAI.ps1 -Unpause resumes it)" -f $paused)) }
    $last = & $toDate $ws['checked']
    if (-not $last) { return (Pass 'not run yet (every 15 minutes while you are signed in)') }
    $mins = [int]((Get-Date) - $last).TotalMinutes
    # Two hours: the task runs every 15 minutes while you are signed in; a PC that was asleep or off
    # also leaves a gap, so this is a warning and says so.
    if ($mins -gt 120) { return (Warn ("last check {0:N1} h ago ({1}); unless the PC was asleep or off since, the LocalAI-Watch task has stopped running - see its History in Task Scheduler, or {2}" -f ($mins / 60), $last.ToString('yyyy-MM-dd HH:mm'), $fix)) }
    if ($ws['toastSetting']) { return (Warn "last check $mins min ago, but Windows has notifications switched off for PowerShell ($($ws['toastSetting'])), so its alerts never pop up: Settings > System > Notifications > Windows PowerShell. Problems that last still show as a banner in Open WebUI") }
    Pass "last check $mins min ago"
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
    Fail "listening beyond loopback: $($bad -join ', ') - reachable from your network; run Start menu > Local AI - Update toolkit to restore the localhost-only settings (for 11434 also turn off 'Expose Ollama to the network' in the Ollama app's Settings, which overrides them)"
}

$fails = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warns = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Host ''
if ($fails -eq 0) { Write-LaiLog OK "V1 COMPLETE: $($results.Count) checks, $warns warnings, 0 failures" }
else { Write-LaiLog FAIL "$fails of $($results.Count) checks failed ($warns warnings)" }
exit $fails
