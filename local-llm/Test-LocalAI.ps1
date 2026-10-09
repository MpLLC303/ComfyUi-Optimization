#Requires -Version 5.1

<#
.SYNOPSIS
    Acceptance test for the local AI stack: the guide's "finished V1" checklist, actually executed.

.DESCRIPTION
    Read-mostly checks plus functional tests that go through the real chain
    (browser API -> Open WebUI -> Ollama -> RTX 3090):

      GPU + driver, Ollama, models installed, presets measured on the running Ollama version (and
      the nightly re-check that keeps them so), models 100% on GPU at their tuned context, a direct SearXNG search (names failed engines),
      Docker, containers, Open WebUI login, presets (system prompt + native tool calling, past-chat
      search, code execution and the writing tools still off, image upload matching what Ollama
      reports for the model; the switches also on every toolkit preset that is still in Open WebUI
      without being selected), no context size set in Open WebUI over
      the tuned aliases, signup off / memories on, RAG + web search settings, a chat per preset, an
      image read by each preset with images (Uncensored Vision), memory recall, document retrieval, web
      search, backups, the health watch (and what it found changed in the installed scripts, tasks
      and listeners since the last install or update), and that nothing listens beyond 127.0.0.1.

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
    [switch]$CpuCheck,
    # Seconds to wait, when Open WebUI is found down while a backup, restore or update holds the
    # volume lock, for that work to finish before Open WebUI is judged (they stop it for minutes).
    # The wait is taken once in a run.
    [int]$LockWaitSec = 600
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
        # The verdict is the last answer with one of the four results. A body that gives none (nothing
        # at all, plain text, a result this script does not know) has checked nothing: never a PASS.
        $r = @(& $Body | Where-Object { $_ -is [hashtable] -and @('PASS', 'WARN', 'FAIL', 'SKIP') -ccontains [string]$_['Status'] }) | Select-Object -Last 1
        if ($null -eq $r) { $r = @{ Status = 'SKIP'; Detail = 'this check gave no answer' } }
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
# Why Open WebUI is down, for the row that found it so: always the words of a failure (Text), never
# of a warning. A backup, restore or update holds the volume lock while it works and stops Open WebUI
# for a few minutes, so a held lock is waited for, -WaitSec seconds at most, and the row then looks
# at Open WebUI once more (Waited). The wait is all a held lock is good for. Any program of this user
# can hold that lock and stop the container, nothing says who holds it or since when, and while a
# held lock made the row a warning, a run with Open WebUI stopped ended with '0 failures' for as
# long as somebody held it. Text is, in this order: the lock, when it is still held at the end of
# the wait; the hold a failed restore left, with its reason and the way out; else -Otherwise, what
# the row itself saw. Known says that it is one of the first two. The lock is asked first, as the
# health watch does: a restore still running has written its hold already, but has not failed.
# The words for a lock that stays held claim what was seen and no more: that it was still held
# after the wait. Who holds it is not known, and the toolkit's own scripts wait longer for this
# lock than this check does (Start again, the installer, an update; and an update keeps the lock
# through its download), so the words never say that no backup, restore or update can be at
# work, and the step they give ends none of them: a window that is still working is left to
# finish, and the PC is restarted only when there is none (a restore cut off by a restart leaves
# the volume half-swapped). -EnoughSec is the wait that is longer than a backup, restore or
# update normally takes (the default of -LockWaitSec). A shorter one (-LockWaitSec given) cannot
# tell work in progress from a lock that is stuck, says so, and is a failure all the same.
# -Again: this run has waited for the lock once already, and the wait is taken once in a run. A
# lock that is let go and taken again, or that the next row meets still held, would otherwise be
# waited for a second time, -LockWaitSec seconds each. Asked again, a held lock is said at once.
function Get-WebUIStopReason {
    param([int]$WaitSec = 0, [string]$Otherwise = '', [int]$EnoughSec = 600, [switch]$Again)
    if ($Again) { $WaitSec = 0 }
    $letFinish = 'If a Local AI window is still at work on a backup, restore or update, let it finish and run the health check again. If none is, restart the PC, which ends whatever holds the lock, and run the health check again'
    $waited = $false
    $until = (Get-Date).AddSeconds([Math]::Max(0, $WaitSec))
    while (Test-LaiVolumeLockBusy) {
        if ((Get-Date) -ge $until) {
            $held = "Open WebUI is down and the volume lock was still held after the $WaitSec s this check was told to wait (-LockWaitSec), too short a time to tell a backup, restore or update at work from a lock that is stuck. Run the health check again without -LockWaitSec: it then waits $EnoughSec s, longer than any of them normally takes"
            if ($WaitSec -ge $EnoughSec) { $held = "Open WebUI is still down, and the volume lock was still held after the $WaitSec s this check waits for it, longer than a backup, restore or update normally takes. $letFinish" }
            if ($Again) { $held = "Open WebUI is down and the volume lock is held. This run has waited for that lock once already and does not wait a second time. $letFinish" }
            # Waited only when this call did wait: the row then looks at Open WebUI once more.
            return @{ Waited = $waited; Known = $true; Text = $held }
        }
        if (-not $waited) { Write-LaiLog INFO "Open WebUI is down and the volume lock is held: a backup, restore or update may be at work, which stops it for a few minutes. Waiting up to $WaitSec s for the lock before judging" }
        $waited = $true
        Start-Sleep -Seconds 1
    }
    $hold = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($hold) { return @{ Waited = $waited; Known = $true; Text = "kept stopped after a failed restore ($($hold['Reason'])). Recover first: $($hold['Recover'])" } }
    return @{ Waited = $waited; Known = $false; Text = $Otherwise }
}
# $true when a run did not find Open WebUI answering and none of its rows is a failure. Each row
# that meets a stopped Open WebUI fails today; this is asked before the count at the end, so that
# no row of tomorrow (a warning, a skip) lets such a run end with '0 failures' again.
function Test-WebUIDownUncounted {
    param([bool]$WebUp, [object[]]$Rows = @())
    if ($WebUp) { return $false }
    return (@($Rows | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0)
}
# The catalog entries whose preset this install does not have selected, from every catalog file
# given that is there, each preset once. Such a preset can still be in Open WebUI (Vision or Code
# skipped later, a trial that was dropped: hidden at most, never deleted), and a chat can still be
# started on it, so it is judged like the selected ones. A file that cannot be read is named in
# Unread instead of ending the run. (Reads only the files it is given; unit-tested in
# tests\Invoke-WindowsUnitTests.ps1.)
function Get-UnselectedPresetEntry {
    param([string[]]$CatalogFiles = @(), [string[]]$SelectedPresets = @())
    $entries = @(); $seen = @(); $unread = @()
    foreach ($file in $CatalogFiles) {
        if (-not $file -or -not (Test-Path -LiteralPath $file)) { continue }
        # Every entry of the file, trials and official models included. Read here with -ErrorAction
        # Stop: Windows PowerShell 5.1 only prints the error for a file that is no data file and
        # hands back nothing, which would read as a catalog without presets.
        try { $all = @((Import-PowerShellDataFile -LiteralPath $file -ErrorAction Stop).Models) }
        catch { $unread += "$file ($($_.Exception.Message))"; continue }
        foreach ($entry in $all) {
            $id = [string]$entry.Preset
            # Held against the selected ids and the ones before it character for character
            # (IndexOf), not with -ccontains: for that an id with a soft hyphen in it is the id
            # without, and a catalog entry under such a name would take the real preset out of
            # this walk.
            if (-not $id -or [array]::IndexOf(@($SelectedPresets), $id) -ge 0 -or [array]::IndexOf($seen, $id) -ge 0) { continue }
            $seen += $id
            $entries += $entry
        }
    }
    return @{ Entries = $entries; Unread = $unread }
}

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
# Open WebUI down for a reason that Get-WebUIStopReason knows (a volume lock that stays held, or the
# hold of a failed restore) is failed by the first check that meets it; the next one skips.
$script:webStopSaid = $false
# How long Open WebUI gets to answer: 30 s, and $webBackSec once this run has waited for a backup,
# restore or update to finish, which start it again as their last step (its page needs a while).
$webBackSec = 120
$script:webAnswerSec = 30
# The wait for the volume lock (-LockWaitSec) has an end, also when a number below 0 was given,
# and it is taken once in a run: the row that waited says so here, and a row that asks after it
# (Get-WebUIStopReason -Again) is told of a held lock at once, without a second wait.
if ($LockWaitSec -lt 0) { $LockWaitSec = 0 }
$script:lockWaited = $false
$startAgain = 'Start menu > Local AI > Start again'
# Every docker call has a time limit. A Docker Desktop that stopped answering (it can after sleep) is
# then one failed check with what to do, not a window that waits without a word.
$dockerLimit = Get-LaiDockerTimeout
$hungMsg = 'Docker Desktop is not responding. Restart it (whale icon > Restart), wait for Engine running, then run this again.'
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

$dockerCmd = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue
if ($NoContainers) {
    Add-Check 'Docker + containers' { Skip 'not checked (-NoContainers)' }
} else {
    Add-Check 'Docker engine' {
        if (-not $dockerCmd) { return (Fail 'docker CLI not found') }
        $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('version', '--format', '{{.Server.Version}}') -TimeoutSec $dockerLimit
        # No answer is not 'not running': Start again cannot help a Docker Desktop that is stuck.
        if ($r.TimedOut) { $script:engineUp = $false; return (Fail $hungMsg) }
        if ($r.ExitCode -ne 0) { $script:engineUp = $false; return (Fail "engine not running - $startAgain (starts Docker Desktop)") }
        Pass "engine $(([string]$r.Out).Trim())"
    }
    $containers = @('open-webui', 'searxng')
    if ($researchPort -gt 0) { $containers += 'deep-research' }
    if (-not ($config.ContainsKey('WebUIOllamaUrl') -and $config['WebUIOllamaUrl'] -and $config['WebUIOllamaUrl'] -notlike '*render-guard*')) { $containers += 'render-guard' }
    # One look at a container: Hung (docker gave no answer in its time), Down (not there, or not
    # running), its status line, and the words for one that is down.
    $containerLook = { param([string]$Name)
        $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('inspect', '-f', '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} {{.HostConfig.RestartPolicy.Name}}', $Name) -TimeoutSec $dockerLimit
        $s = ([string]$r.Out).Trim()
        $why = "$s - $startAgain"
        if ($r.ExitCode -ne 0) { $why = "not found - re-run the installer: double-click $(Join-Path (Join-Path $AIRoot 'Scripts') 'Install-LocalAI.cmd') and click Yes" }
        return @{ Hung = [bool]$r.TimedOut; Down = ($r.ExitCode -ne 0 -or $s -notmatch '^running'); Status = $s; Why = $why }
    }
    foreach ($c in $containers) {
        Add-Check "Container $c" {
            if ($c -eq 'searxng') { $script:searxUp = $false }
            if (-not $script:engineUp) { return (Skip 'Docker engine down') }
            $look = & $containerLook $c
            # Docker stopped answering after its engine check: said once, and the rest is skipped.
            if ($look.Hung) { $script:engineUp = $false; return (Fail $hungMsg) }
            if ($look.Down -and $c -eq 'open-webui') {
                # Open WebUI down: a backup, restore or update at work gets the time to finish, and
                # then one more look. Still down, it is a failure whatever the reason: a lock that
                # is still held, the hold of a failed restore (neither is a container to start
                # again or to install again), or what the look itself says.
                $stop = Get-WebUIStopReason -WaitSec $LockWaitSec -Again:$script:lockWaited -Otherwise $look.Why
                if ($stop.Waited) {
                    $script:lockWaited = $true
                    $look = & $containerLook $c
                    if ($look.Hung) { $script:engineUp = $false; return (Fail $hungMsg) }
                    # The row's own words are those of the last look.
                    if (-not $stop.Known) { $stop.Text = $look.Why }
                    # Running again after that work: its page gets the time to come up.
                    if (-not $look.Down) { $script:webAnswerSec = $webBackSec }
                }
                if ($look.Down) {
                    if ($stop.Known) { $script:webStopSaid = $true }
                    return (Fail $stop.Text)
                }
            }
            if ($look.Down) { return (Fail $look.Why) }
            if ($c -eq 'searxng') { $script:searxUp = $true }
            if ($look.Status -match 'unhealthy') { return (Warn $look.Status) }
            Pass $look.Status
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
    if ($script:webStopSaid) { return (Skip 'Open WebUI is down (see Container open-webui)') }
    $answers = $true
    try { Wait-LaiWebUI -BaseUrl $webUrl -TimeoutSec $script:webAnswerSec } catch { $answers = $false }
    if (-not $answers) {
        # Asked only now: an Open WebUI that answers is fine, whoever holds the lock. No answer: a
        # backup, restore or update at work gets the time to finish, and then one more look. Still
        # no answer, it is a failure whatever the reason; with a lock that stays held or a hold,
        # Start again is the wrong advice (it waits for the lock, or refuses on the hold).
        $stop = Get-WebUIStopReason -WaitSec $LockWaitSec -Again:$script:lockWaited -Otherwise "no answer on http://localhost:$webPort - $startAgain; if it persists: docker logs --tail 50 open-webui"
        if ($stop.Waited) {
            $script:lockWaited = $true
            # The lock was let go and no hold is left: Open WebUI was just started again and gets
            # the time to come up. Else a short look is enough.
            $againSec = 5; if (-not $stop.Known) { $againSec = $webBackSec }
            $answers = $true
            try { Wait-LaiWebUI -BaseUrl $webUrl -TimeoutSec $againSec } catch { $answers = $false }
        }
        if (-not $answers) { return (Fail $stop.Text) }
    }
    $script:webUp = $true
    Pass "http://localhost:$webPort"
}

$token = $null
Add-Check 'Open WebUI version' {
    if (-not $script:webUp) { return (Skip 'Open WebUI not reachable') }
    $ver = [string](Invoke-LaiApi -Uri "$webUrl/api/version" -TimeoutSec 15).version
    $compat = Get-LaiWebUICompat -Version $ver
    if ($compat -eq 'tested') { return (Pass "$ver (the version this toolkit was tested with)") }
    if ($compat -eq 'newer') { return (Warn "$ver is newer than the tested 0.11.4; if a check below fails, Update-OpenWebUI.ps1 -Rollback goes back") }
    Warn "$ver (tested with 0.11.4)"
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
            # Before the image switch: its warning would otherwise be all this row says. The judge is
            # the module's, the one the installer holds every preset to: past chats, code, and the
            # writing tools, each off only when it is written out as off.
            $risks = @(Get-LaiPresetToolRisk $p.meta)
            if ($risks.Count) { return (Fail "the assistant can $($risks -join ' and ') again; run Start menu > Local AI - Update toolkit to put the safety settings back") }
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
            Pass "system prompt set, native tool calling, past-chat search, code execution and the writing tools off$(if ($presetVision) { ', images on' })"
        }
    }
    # The toolkit's presets that are in Open WebUI without being selected, each with a row of its
    # own and the same judge: such a preset keeps the switches it had when it was last written, and
    # a chat can be started on it. The entries come from the catalog this run reads and, always,
    # from the toolkit's own catalog next to this script: a -CatalogPath (or the test variable
    # above) that names a shorter list cannot take a preset out of this check. A preset that is not
    # in Open WebUI gets no row; one that cannot be read gets a failed one.
    $unselected = Get-UnselectedPresetEntry -CatalogFiles @($CatalogPath, (Join-Path (Join-Path $PSScriptRoot 'config') 'models.psd1')) -SelectedPresets @($catalog.Models | ForEach-Object { [string]$_.Preset })
    foreach ($unreadCatalog in @($unselected.Unread)) {
        Add-Check 'Presets that are not selected' { Fail "the catalog $unreadCatalog could not be read, so the presets it lists were not checked; run Start menu > Local AI - Update toolkit to put the toolkit's files back" }
    }
    foreach ($m in @($unselected.Entries)) {
        # Asked before the row, which a preset that is not there does not get.
        $kept = $null; $keptUnread = ''
        try { $kept = Get-LaiWebUIModel -BaseUrl $webUrl -Token $token -Id $m.Preset } catch { $keptUnread = 'error: ' + (Get-LaiHttpErrorText $_) }
        if (-not $kept -and -not $keptUnread) { continue }
        Add-Check "Preset $($m.Display) (not selected)" {
            if ($keptUnread) { return (Fail "Open WebUI did not hand this preset over ($keptUnread), so its safety settings were not checked; run the health check again, and if this stays, Start menu > Local AI - Update toolkit") }
            $risks = @(Get-LaiPresetToolRisk $kept.meta)
            if ($risks.Count) { return (Fail "the assistant can $($risks -join ' and ') in this preset, which is not selected but still in Open WebUI, where a chat can be started on it; run Start menu > Local AI - Update toolkit to switch that off") }
            Pass 'still in Open WebUI, with past-chat search, code execution and the writing tools off'
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
        if ($expected -like '*render-guard*') { return (Pass "$expected (render guard), Ollama $($v.version)") }
        Pass "$expected (direct), Ollama $($v.version)"
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
    # An -EMPTY archive (made on a night Open WebUI had lost its users or chats) is no backup to name
    # as the newest good one, or to restore from, any more than a -CORRUPT one.
    $newest = $all | Where-Object { $_.Name -notlike '*-CORRUPT.tar.gz' -and $_.Name -notlike '*-EMPTY.tar.gz' } | Select-Object -First 1
    # Age is judged on the nightly archives only, so a tagged one cannot hide a broken nightly task.
    $daily = $all | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' } | Select-Object -First 1
    if ($all.Count -gt 0 -and $all[0].Name -like '*-CORRUPT.tar.gz') {
        return (Fail "the newest backup $($all[0].Name) failed its database check; the live Open WebUI data may be damaged (restore the last good one with Restore-OpenWebUI.ps1 -Archive $(if ($newest) { "'$($newest.FullName)'" } else { '<an older archive>' }), see the README's Maintain section)")
    }
    # The nightly backup found Open WebUI without its users or chats and recorded it (backup-state.json,
    # 'emptied': at, lastGood, users, chats, hadUsers, hadChats). It stands until the data is back or
    # the owner accepts it; the watch reports the same. 'at' is text under Windows PowerShell 5.1 and
    # a date under PowerShell 7. It is the first night the data looked wiped; the counts are those
    # of the last backup. The mark goes when a backup counts the data again, not when a restore ends,
    # so the line says that too: it stays for some hours after a restore that did its work.
    $wiped = (Read-LaiState -Path (Join-Path $AIRoot 'backup-state.json'))['emptied']
    if ($wiped -is [hashtable]) {
        $since = $wiped['at']; if ($since -is [datetime]) { $since = $since.ToString('s') }
        $good = ([string]$wiped['lastGood'] -replace '\s+', ' ').Trim()
        if ($good.Length -gt 300) { $good = $good.Substring(0, 300) + '...' }
        if (-not $good) { $good = 'none on record' }
        return (Fail ("Open WebUI's data has looked wiped since the nightly backup of {0}; at the last backup {1} user(s) and {2} chat(s), {3} and {4} at the last good one ({5}). Nightly archives are kept as -EMPTY and no older backup is deleted until this is settled: run Restore-OpenWebUI.ps1 to get the data back (it takes that last good backup), or, if you emptied it yourself, Backup-OpenWebUI.ps1 -AcceptEmpty once. After a restore this line stays until the next nightly backup has counted the data again; Backup-OpenWebUI.ps1 run by hand does that at once" -f $since, $wiped['users'], $wiped['chats'], $wiped['hadUsers'], $wiped['hadChats'], $good))
    }
    # The same archive with its record gone (a backup-state.json that was damaged or deleted): the
    # old backups may be held back by nothing any more, and the watch fails Backups for it as well.
    if ($all.Count -gt 0 -and $all[0].Name -like '*-EMPTY.tar.gz') {
        $way = "no nightly backup from before it is in $dir"
        if ($daily) { $way = "if you did not empty it yourself, first put back the newest nightly backup from before it: Restore-OpenWebUI.ps1 -Archive '$($daily.FullName)'" }
        return (Fail "the newest backup $($all[0].Name) was made when Open WebUI's data looked wiped, and the record of it is gone from backup-state.json: without it the next nightly backup can take the data as it is now for normal and delete old backups by age again; $way")
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

function Format-TakenList {
    # What a baseline took in, for the Integrity watch line: the first twelve by name, and how many
    # there are in all (-Count; more than the names when the baseline counts some without naming them).
    param([string[]]$Names = @(), [int]$Count = 0)
    $shown = @($Names | Select-Object -First 12)
    $list = $shown -join '; '
    if ($shown.Count -eq 0) { $list = 'none of them is listed by name any more' }
    elseif ($Count -gt $shown.Count) { $list += ' and {0} more' -f ($Count - $shown.Count) }
    return $list
}

Add-Check 'Integrity watch' {
    # What the health watch found when it last compared the installed scripts, the Stack folder, the
    # LocalAI-* scheduled tasks and the network listeners with the baseline the last install or update
    # recorded. Read from the watch's own record: nothing is hashed here, and a difference is a
    # warning, not a failure (the stack works; something was changed). The baseline sits in a folder
    # this user can write, so this shows accidents, other software and clumsy tampering, no more.
    # Not watched at all, and so never part of this result: Stack\.env beyond the settings that say
    # where chats and searches go, logs, and everything under a Secrets folder.
    $ws = Read-LaiState -Path (Join-Path $AIRoot 'watch-state.json')
    $ig = @{}; if ($ws['integrity'] -is [hashtable]) { $ig = $ws['integrity'] }
    $accept = "& $(ConvertTo-LaiPsQuoted (Join-Path (Join-Path $AIRoot 'Scripts') 'Watch-LocalAI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -AcceptBaseline"
    # The installer runs this checklist itself before it records its new baseline, and files are
    # being replaced while any install or model update runs: what the watch found against the old
    # baseline is then no advice to act on ('accept this change' about a file that was just put
    # back). The installer holds the setup lock on this very thread, where it reads as free (a mutex
    # lets its owner in again), so that case is told by the installer's own $SetupLock, which this
    # script sees when the installer calls it. Any program can hold that lock, though: one held for
    # $skipHours hours no longer hides the result (the watch announces it after the same time).
    $skipHours = 6
    $byInstaller = (Get-Variable -Name SetupLock -ValueOnly -ErrorAction SilentlyContinue) -is [System.Threading.Mutex]
    $lockSince = ConvertTo-LaiIntegrityDate $ig['skippedSince']
    if ($byInstaller -or ((Test-LaiSetupLockBusy) -and (-not $lockSince -or [math]::Abs(((Get-Date) - $lockSince).TotalHours) -lt $skipHours))) {
        return (Skip 'an install, update or model update is running: files are being replaced, so nothing is compared until it has finished (an install or update then records a new baseline)')
    }
    $base = Read-LaiIntegrityBaseline -AIRoot $AIRoot
    if (-not $base) {
        # The watch had one and it is gone: that is not 'none yet'.
        if ($ig['baseline']) { return (Warn ("the baseline (""{0}"") is gone or cannot be read, so changes are no longer noticed. If you did not remove it, {1} If you did, record a new one by pasting this into PowerShell: {2}" -f (Get-LaiIntegrityPath -AIRoot $AIRoot), (Get-LaiIntegrityAdvice -Ids @('baseline|gone') -AIRoot $AIRoot), $accept)) }
        return (Skip 'no baseline yet (an install or Start menu > Local AI - Update toolkit records one when it finishes)')
    }
    $recorded = ConvertTo-LaiIntegrityDate $base['recordedAt']
    $when = [string]$base['recordedAt']; if ($recorded) { $when = $recorded.ToString('yyyy-MM-dd HH:mm') }
    $about = "baseline of $when ($(Get-LaiIntegritySummary -Baseline $base))"
    # A baseline takes in whatever is there when it is recorded. What it took in beyond the toolkit's
    # own (an install or update), or at all (recorded by hand, which any program running as this user
    # can do), stays in this line for as long as that baseline is the one in use.
    $taken = @($base['accepted'] | Where-Object { $_ -is [hashtable] })
    $takenCount = $taken.Count; if ([int]$base['acceptedCount'] -gt $takenCount) { $takenCount = [int]$base['acceptedCount'] }
    $byHand = ([string]$base['reason'] -ne 'install')
    $origin = ''; if ($byHand) { $origin = ' That baseline was recorded by hand (-AcceptBaseline).' }
    if ($takenCount) {
        # By name the first twelve. An entry that stands for what the baseline does not name ('more|...',
        # past a thousand kept items or in the old 50-name form) is no name: it is part of the count,
        # and of the advice below.
        $takenNamed = @($taken | Where-Object { [string]$_['Id'] -notlike 'more|*' })
        $takenList = Format-TakenList -Names @($takenNamed | ForEach-Object { [string]$_['Text'] }) -Count $takenCount
        $takenAdvice = Get-LaiIntegrityAdvice -Ids @($taken | ForEach-Object { [string]$_['Id'] }) -AIRoot $AIRoot
        if ($byHand) { $origin = " That baseline was recorded by hand (-AcceptBaseline), which made $takenCount change(s) count as normal: $takenList. If that was not you, $takenAdvice" }
        else {
            # An install carries on, marked 'Settled', what the owner accepted by hand and the watch has not
            # had its turn with yet: that was not "kept although the install did not put it there", it is
            # worded apart. What the baseline counts without naming it ('more|...') is settled only when
            # its own entry says so.
            $restSettled = (@($taken | Where-Object { [string]$_['Id'] -like 'more|*' -and $_['Settled'] }).Count -gt 0)
            $restCount = [math]::Max(0, $takenCount - $takenNamed.Count)
            $keptNamed = @($takenNamed | Where-Object { -not $_['Settled'] })
            $settledNamed = @($takenNamed | Where-Object { $_['Settled'] })
            $keptCount = $keptNamed.Count; $settledCount = $settledNamed.Count
            if ($restSettled) { $settledCount += $restCount } else { $keptCount += $restCount }
            # One sentence for each kind, and with both of them the number in all. Then the advice, once
            # and for all of them together ($takenAdvice: with a script among them, of either kind, no
            # shortcut is named; one advice for each kind could say both), and last the command to
            # paste: the line is a warning in each of these shapes, so each says what ends it.
            $origin = ''; $subject = ' That install or update'
            $ifNot = 'If you did not add them,'; $ifSo = 'If you did,'
            if ($settledCount) {
                $settledList = Format-TakenList -Names @($settledNamed | ForEach-Object { [string]$_['Text'] }) -Count $settledCount
                $origin = "$subject carried on $settledCount thing(s) already accepted by hand (-AcceptBaseline), which still count as normal: $settledList."
                $subject = ' It also'
                $ifNot = 'If that acceptance was not yours,'; $ifSo = 'If it was,'
            }
            if ($keptCount) {
                $keptList = Format-TakenList -Names @($keptNamed | ForEach-Object { [string]$_['Text'] }) -Count $keptCount
                $origin += "$subject kept $keptCount thing(s) it did not install, which now count as normal: $keptList."
                if ($settledCount) {
                    $origin += " That is $takenCount in all."
                    $ifNot = 'If that acceptance was not yours, or you did not add what was kept,'; $ifSo = 'If both were you,'
                }
            }
            $origin += " $ifNot $takenAdvice $ifSo this goes away with: $accept"
        }
    }
    # An update that kept what it did not install is a warning until the owner has looked.
    $keptByUpdate = ($takenCount -gt 0 -and -not $byHand)
    if ([string]$ig['baseline'] -ne [string]$base['id'] -or -not $ig['checkedAt']) {
        # The watch's record belongs to this baseline only when it names its id: under another id it is
        # the previous baseline's, and the reason in it (every install leaves 'an install ... is
        # running' there) is stale. Under this one, a comparison that could not run says why.
        if ([string]$ig['baseline'] -eq [string]$base['id'] -and $ig['skippedWhy']) {
            return (Warn "$about; the health watch has not compared the PC with it yet: the comparison is not running ($($ig['skippedWhy'])).$origin")
        }
        $msg = "$about; the health watch compares the PC with it on its next run.$origin"
        if ($keptByUpdate) { return (Warn $msg) }
        return (Pass $msg)
    }
    # A result is only as good as the comparison behind it: say when that did not run, or left
    # something out, instead of showing an old 'nothing changed' as today's.
    $notes = @()
    $checkedAt = ConvertTo-LaiIntegrityDate $ig['checkedAt']
    $watchRan = ConvertTo-LaiIntegrityDate $ws['checked']
    $checkedText = [string]$ig['checkedAt']; if ($checkedAt) { $checkedText = $checkedAt.ToString('yyyy-MM-dd HH:mm') }
    if ($ig['skippedWhy']) {
        $notes += "the comparison is not running ($($ig['skippedWhy'])), so this is the result of $checkedText and later changes are not in it"
    } elseif ($checkedAt -and $watchRan -and ((Get-Date) - $checkedAt).TotalHours -gt 3 -and ((Get-Date) - $watchRan).TotalMinutes -le 120) {
        $notes += "the last comparison was at $checkedText although the health watch has run since, so later changes are not in it (see Logs\watch.log)"
    }
    $unread = @($ig['notRead'] | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if ($unread.Count) { $notes += ($unread -join ' and ') + ' could not be read at the last comparison and were not compared' }
    $found = @($ig['found'] | Where-Object { $_ -is [hashtable] })
    if ($found.Count -eq 0) {
        if ($notes.Count) { return (Warn ("no change was found against the $about, but " + ($notes -join '; ') + ".$origin")) }
        if ($keptByUpdate) { return (Warn "nothing changed since the $about.$origin") }
        return (Pass "nothing changed since the $about.$origin")
    }
    $more = ''; if ($notes.Count) { $more = ' Also: ' + ($notes -join '; ') + '.' }
    Warn ("{0} change(s) since the {1}: {2}. If you did not make them, {3} If you did, make them the new baseline by pasting this into PowerShell: {4}{5}{6}" -f $found.Count, $about, (Format-LaiIntegrityList -Items @($found | ForEach-Object { [string]$_['Text'] }) -Max 12),
        (Get-LaiIntegrityAdvice -Ids @($found | ForEach-Object { [string]$_['Id'] }) -AIRoot $AIRoot), $accept, $more, $origin)
}

Add-Check 'Nothing exposed beyond localhost' {
    if (-not $onWindows) { return (Skip 'Windows-only check') }
    $bad = @()
    $ports = @(11434, $webPort, $searxPort)
    if ($researchPort -gt 0) { $ports += $researchPort }
    foreach ($port in $ports) {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
        foreach ($l in $listeners) {
            if (@('127.0.0.1', '::1') -notcontains $l.LocalAddress) { $bad += "${port}@$($l.LocalAddress)" }
        }
    }
    if ($bad.Count -eq 0) { return (Pass "$($ports -join ', ') bound to loopback only") }
    $onlyOllama = @($bad | Where-Object { $_ -notlike '11434@*' }).Count -eq 0
    if ($onlyOllama) {
        # A rule of the right name is not yet a block. The module reads the rule and judges it, and
        # one answer only keeps this a warning: a rule that is on and blocks by address. One that is
        # switched off or was changed, the older one on the network adapters (a VPN and Tailscale
        # get past it), no rule, and a firewall that could not be asked are failures, each in its
        # own words and with the step that goes with it (the answer's Fix). That step is not Update
        # toolkit alone: the installer makes the rule only where it opened the port itself, so with
        # no rule the Ollama app's own setting comes first, as in the closing failure below.
        $fw = Get-LaiOllamaBlockState
        if ($fw.State -eq 'blocked') {
            return (Warn "Ollama listens on all interfaces (Docker fallback) but the LAN block rule is in place: $($bad -join ', ')")
        }
        return (Fail "Ollama listens beyond loopback ($($bad -join ', ')) and $($fw.Text); $($fw.Fix)")
    }
    Fail "listening beyond loopback: $($bad -join ', ') - reachable from your network; run Start menu > Local AI - Update toolkit to restore the localhost-only settings (for 11434 also turn off 'Expose Ollama to the network' in the Ollama app's Settings, which overrides them)"
}

# Whatever the rows above said: a run in which Open WebUI did not answer never ends with '0 failures'.
if (Test-WebUIDownUncounted -WebUp $script:webUp -Rows @($results)) {
    Add-Check 'Open WebUI answers' { Fail "Open WebUI did not answer in this run, and no check above counted that as a failure - $startAgain, then run the health check again" }
}
$fails = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warns = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Host ''
if ($fails -eq 0) { Write-LaiLog OK "V1 COMPLETE: $($results.Count) checks, $warns warnings, 0 failures" }
else { Write-LaiLog FAIL "$fails of $($results.Count) checks failed ($warns warnings)" }
exit $fails
