#Requires -Version 5.1

<#
.SYNOPSIS
    Re-pulls the installed models and re-tunes only the ones whose content actually changed.

.DESCRIPTION
    For every model selected at install time:
      1. remembers its manifest digest, pulls the tag again (a no-op when nothing changed upstream),
      2. if the digest changed (the community author re-published the tag), re-runs the context tuner
         for that model and rebuilds its localai-* alias; otherwise leaves the tuned alias untouched.
    Optionally upgrades Ollama itself first (-UpdateOllama). Finishes with Test-LocalAI.ps1 -Quick.
    Open WebUI needs no change: its presets point at the alias names, which stay the same.

    When a model really changed, the version you had is kept as <tag>-prev (Ollama would otherwise
    delete its files right after the pull), so -Rollback can bring it back if the new upload is
    worse. That costs the old model's size on disk until the next update or -DropPrevious.

    -RecheckOnly downloads nothing. It loads, on the Ollama installed now, only the presets measured
    on another Ollama version (the Ollama app updates itself) or left partly on the CPU by an earlier
    check, re-tunes any that no longer fit fully on the GPU, and records the result in
    <AIRoot>\model-recheck.json. Start menu > Local AI - Re-check models runs it. The scheduled task
    LocalAI-Recheck-Models runs it every night with -Scheduled, which never waits: it skips (exit 0,
    tomorrow night tries again) while another installer run or model update is going, Gaming mode is
    on, a chat answer is being written, or another program uses the GPU. Its log is
    <AIRoot>\Logs\model-recheck.log. The health watch shows a notification only when a preset could
    not be put back fully on the GPU.

.EXAMPLE
    .\Update-Models.ps1                    # check all models
.EXAMPLE
    .\Update-Models.ps1 -RecheckOnly       # no downloads: re-check the presets on the Ollama installed now
.EXAMPLE
    .\Update-Models.ps1 -UpdateOllama      # upgrade Ollama via winget first
.EXAMPLE
    .\Update-Models.ps1 -Retune            # re-measure every model even if nothing changed
.EXAMPLE
    .\Update-Models.ps1 -Rollback main     # go back to the previous version of Uncensored Main ('all' = every kept one)
.EXAMPLE
    .\Update-Models.ps1 -DropPrevious      # delete the kept previous versions to free the disk space
.EXAMPLE
    .\Update-Models.ps1 -Unpin main        # after a -Rollback: let updates touch Uncensored Main again
#>
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    [switch]$UpdateOllama,
    [switch]$Retune,
    # Skip the quick health check at the end.
    [switch]$SkipTests,
    [string[]]$Rollback = @(),
    [string[]]$Unpin = @(),
    [switch]$DropPrevious,
    # Do not keep the old version of an updated model as <tag>-prev (saves disk space, no -Rollback).
    [switch]$NoKeepPrevious,
    # No downloads: only re-check the presets measured on another Ollama version (see above).
    [switch]$RecheckOnly,
    # For the nightly task: -RecheckOnly -SkipTests that never waits and skips while the PC is in use.
    [switch]$Scheduled
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

# The nightly task: a re-check nobody watches, so no health check at the end (it would only add a
# minute of GPU use at night) and no waiting anywhere.
if ($Scheduled) { $RecheckOnly = [switch]$true; $SkipTests = [switch]$true }
if ($RecheckOnly -and ($UpdateOllama -or $Retune -or $DropPrevious -or @($Rollback | Where-Object { $_ }).Count -or @($Unpin | Where-Object { $_ }).Count)) {
    throw '-RecheckOnly (only a re-check, no downloads) cannot be combined with -UpdateOllama, -Retune, -Rollback, -Unpin or -DropPrevious; run those without it.'
}

$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$statePath = Join-Path $AIRoot 'install-state.json'
$recheckPath = Join-Path $AIRoot 'model-recheck.json'
$script:transcriptOn = $false
if ($Scheduled) {
    # No window to read afterwards: the runs are kept in Logs\model-recheck.log (the older ones move to
    # model-recheck.log.old past 1 MB).
    $logDir = Join-Path $AIRoot 'Logs'
    $recheckLog = Join-Path $logDir 'model-recheck.log'
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        if ((Test-Path -LiteralPath $recheckLog) -and (Get-Item -LiteralPath $recheckLog).Length -gt 1MB) { Move-Item -LiteralPath $recheckLog -Destination "$recheckLog.old" -Force }
        Start-Transcript -LiteralPath $recheckLog -Append | Out-Null
        $script:transcriptOn = $true
    } catch { Write-Verbose "no transcript: $($_.Exception.Message)" }
}
function Close-Run {
    # The setup lock stays owned as long as this thread lives, and the Start-menu window keeps it
    # alive at 'press Enter to close': release it, or that open window would block the nightly
    # re-check and the installer.
    if ($script:SetupLock) { Exit-LaiVolumeLock $script:SetupLock; $script:SetupLock = $null }
    if ($script:transcriptOn) { try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }; $script:transcriptOn = $false }
}
function Stop-Run([int]$Code) {
    Close-Run
    exit $Code
}
# The same for an error that ends the run ('break' still ends it, with the error shown). Written
# out, not Close-Run: a trap covers the whole script, also errors raised before that is defined.
trap {
    if ($script:SetupLock) { Exit-LaiVolumeLock $script:SetupLock; $script:SetupLock = $null }
    if ($script:transcriptOn) { try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }; $script:transcriptOn = $false }
    break
}
function Save-Recheck {
    # What the last re-check found, for the health watch: it notifies only when a preset could not be
    # put back fully on the GPU, or when the nightly run keeps being skipped.
    param([string]$Result, [string[]]$Presets = @(), [string]$Reason = '', [string]$Version = '')
    $rec = @{ ollamaVersion = $Version; at = (Get-Date).ToString('s'); result = $Result; presets = @($Presets); reason = $Reason }
    try {
        # A skip must not hide a preset the last re-check left off the GPU on this Ollama (the health
        # check warns about it): that record stays, with the skip noted for the watch's 3-day notice.
        # No version (the setup lock was busy before Ollama was asked) counts as the same one.
        $old = Read-LaiState -Path $recheckPath
        if ($Result -eq 'skipped' -and @('off-gpu', 'failed') -contains [string]$old['result'] -and (-not $Version -or [string]$old['ollamaVersion'] -eq $Version)) {
            $rec = $old
            $rec['lastSkip'] = $Reason
            $rec['lastSkipAt'] = (Get-Date).ToString('s')
        }
        Save-LaiState -State $rec -Path $recheckPath
    } catch { Write-LaiLog WARN "Could not write $recheckPath : $($_.Exception.Message)" }
}
function Exit-Skipped([string]$Reason, [string]$Version = '') {
    # -Scheduled only: nothing is measured or recorded in the tuning, and tomorrow night tries again.
    Write-LaiLog WARN "Re-check skipped: $Reason. The next nightly run tries again (or Start menu > Local AI - Re-check models)."
    Save-Recheck -Result 'skipped' -Reason $Reason -Version $Version
    Stop-Run 0
}

# Not while the installer or another model update runs: both tune the same models.
try { $script:SetupLock = Enter-LaiSetupLock }
catch {
    if ($Scheduled) { Exit-Skipped 'another installer run or model update was running' }
    throw
}
$state = Read-LaiState -Path $statePath
if (-not $state.ContainsKey('tuning') -or $null -eq $state['tuning']) { $state['tuning'] = @{} }
$ollamaUrl = 'http://127.0.0.1:11434'
if ($config.ContainsKey('OllamaUrl') -and $config['OllamaUrl']) { $ollamaUrl = $config['OllamaUrl'] }
$selected = @()
if ($config.ContainsKey('SelectedModels')) { $selected = @($config['SelectedModels']) }
$catalogPath = Join-Path (Join-Path $PSScriptRoot 'config') 'models.psd1'
if ($env:LOCALAI_TEST_CATALOG) { $catalogPath = $env:LOCALAI_TEST_CATALOG }
$catalog = Get-LaiCatalog -Path $catalogPath -IncludeKeys $selected
$system = (Get-Content -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $PSScriptRoot 'config') 'system-prompt.txt') -Raw).Trim()
$minFree = 768; if ($config.ContainsKey('MinFreeVramMiB')) { $minFree = [int]$config['MinFreeVramMiB'] }
$maxBusy = 3500; if ($config.ContainsKey('MaxBusyVramMiB')) { $maxBusy = [int]$config['MaxBusyVramMiB'] }
$allowCpu = ($env:LOCALAI_TEST_ALLOW_CPU -eq '1')

if ($UpdateOllama) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'winget not found; update Ollama from https://ollama.com/download instead.' }
    $before = Get-LaiOllamaVersion -BaseUrl $ollamaUrl
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $winget upgrade --exact --id Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
    $ErrorActionPreference = $prev
    Wait-LaiHttp -Uri "$ollamaUrl/api/version" -TimeoutSec 120 | Out-Null
    Write-LaiLog OK "Ollama $before -> $(Get-LaiOllamaVersion -BaseUrl $ollamaUrl)"
}

$env:OLLAMA_HOST = '127.0.0.1:11434'   # the CLI is only a client of the local server
# 'powershell -File' passes "main,fast" as one string.
$Rollback = @($Rollback | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Unpin = @($Unpin | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $state.ContainsKey('flags') -or $null -eq $state['flags']) { $state['flags'] = @{} }
$pinned = @()
if ($state['flags'].ContainsKey('pinnedModels') -and $state['flags']['pinnedModels']) { $pinned = @($state['flags']['pinnedModels']) }
function Save-Pins { $state['flags']['pinnedModels'] = @($script:pinned); Save-LaiState -State $state -Path $statePath }

function Hide-InWebUI([string]$Id) {
    # Keeps the -prev copy out of Open WebUI's model list (admins see every Ollama model). Best effort.
    try {
        $credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
        if (-not (Test-Path -LiteralPath $credFile)) { return }
        $port = 3000; if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
        Resolve-LaiPendingPassword -AIRoot $AIRoot -BaseUrl "http://127.0.0.1:$port" | Out-Null
        $cred = Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json
        $tok = Connect-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -Email $cred.email -Password $cred.password
        Hide-LaiWebUIModel -BaseUrl "http://127.0.0.1:$port" -Token $tok -Id $Id | Out-Null
    } catch { Write-Verbose "could not hide $Id in Open WebUI: $($_.Exception.Message)" }
}

function Get-CurrentFingerprint($Gpu) {
    # The tuning fingerprint (driver, KV cache, VRAM settings) as stored, with today's driver: the
    # next installer run must not see a 'driver change' for models tuned here.
    $fp = ''
    foreach ($k in $state['tuning'].Keys) { if ($state['tuning'][$k]['Fingerprint']) { $fp = [string]$state['tuning'][$k]['Fingerprint']; break } }
    if (-not $fp -and $Gpu) { return "driver=$($Gpu.DriverVersion)" }
    if ($Gpu) { $fp = $fp -replace '(^|;)driver=[^;]*', ('$1driver=' + $Gpu.DriverVersion) }
    return $fp
}

function Get-PrevName([string]$Source) {
    $full = Resolve-LaiModelName $Source
    return "$full-prev"
}
function Copy-Model([string]$From, [string]$To) {
    Invoke-LaiApi -Method POST -Uri "$ollamaUrl/api/copy" -Body @{ source = $From; destination = $To } | Out-Null
}
function Remove-Model([string]$Name) {
    if (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $Name) { Invoke-LaiApi -Method DELETE -Uri "$ollamaUrl/api/delete" -Body @{ model = $Name } | Out-Null }
}
function Get-ModelGB([string]$Name) {
    $t = (Invoke-LaiApi -Uri "$ollamaUrl/api/tags").models | Where-Object { $_.name -eq (Resolve-LaiModelName $Name) } | Select-Object -First 1
    if ($t) { return [Math]::Round($t.size / 1GB, 1) }
    return 0
}

$changed = @()
$failedPulls = @()
if ($Unpin.Count -gt 0) {
    if ($Unpin -contains 'all') { $script:pinned = @() } else { $script:pinned = @($pinned | Where-Object { $Unpin -notcontains $_ }) }
    Save-Pins
    Write-LaiLog OK "Updates may change these again: $($Unpin -join ', ')"
    Stop-Run 0
}
if ($DropPrevious) {
    foreach ($m in $catalog.Models) {
        $pn = Get-PrevName $m.Source
        if (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $pn) { Remove-Model $pn; Write-LaiLog OK "Deleted $pn" }
    }
    Stop-Run 0
}
if ($Rollback.Count -gt 0) {
    foreach ($m in $catalog.Models) {
        if ($Rollback -notcontains 'all' -and $Rollback -notcontains $m.Key) { continue }
        $pn = Get-PrevName $m.Source
        if (-not (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $pn)) { Write-LaiLog WARN "$($m.Display): no previous version kept ($pn)"; continue }
        Copy-Model $pn (Resolve-LaiModelName $m.Source)
        Remove-Model $pn
        Write-LaiLog OK "$($m.Display): back to the previous version ($((Get-LaiOllamaDigest -BaseUrl $ollamaUrl -Name $m.Source).Substring(0, 12))); pinned so the next update leaves it alone (Update-Models.ps1 -Unpin $($m.Key) to undo)"
        if ($pinned -notcontains $m.Key) { $script:pinned = @($pinned) + $m.Key }
        $changed += $m
    }
    if ($changed.Count -eq 0) { throw "Nothing to roll back for: $($Rollback -join ', ')" }
    Save-Pins
} elseif (-not $RecheckOnly) {
    # (-RecheckOnly: no downloads, so no model counts as changed; only the re-check below runs.)
    $offline = $false
    foreach ($m in $catalog.Models) {
        if ($pinned -contains $m.Key) { Write-LaiLog WARN "$($m.Display): pinned after a rollback, not updated (Update-Models.ps1 -Unpin $($m.Key) to allow it)"; continue }
        if ($offline) { Write-LaiLog WARN "  $($m.Display): skipped, no connection to the model registry"; $failedPulls += $m.Display; continue }
        $old = Get-LaiOllamaDigest -BaseUrl $ollamaUrl -Name $m.Source
        Write-LaiLog STEP "Checking $($m.Source)"
        # Keep a reference to the current version first: a pull deletes files no tag points to.
        $candidate = "$(Resolve-LaiModelName $m.Source)-prevnew"
        try {
            if ($old -and -not $NoKeepPrevious) { Copy-Model (Resolve-LaiModelName $m.Source) $candidate }
            try {
                if ($env:LOCALAI_TEST_PULL_FROM) { Copy-Model $env:LOCALAI_TEST_PULL_FROM (Resolve-LaiModelName $m.Source) }   # test hook: simulated re-publish
                else { Invoke-LaiOllamaPull -BaseUrl $ollamaUrl -Name $m.Source }
            } catch {
                # Keep going: the models already updated in this run still get re-tuned below.
                Write-LaiLog WARN "  $($m.Display): download failed, kept the current version ($((Get-LaiHttpErrorText $_)))"
                $failedPulls += $m.Display
                # Offline: the remaining models would each spend ~30 s in retries for nothing.
                $probeUrl = 'https://registry.ollama.ai/v2/'
                if ($env:LOCALAI_TEST_REGISTRY_URL) { $probeUrl = $env:LOCALAI_TEST_REGISTRY_URL }
                if (-not (Test-LaiRegistryReachable -Url $probeUrl)) { $offline = $true; Write-LaiLog WARN '  The model registry is unreachable (offline?); skipping the remaining downloads.' }
                continue
            }
            $new = Get-LaiOllamaDigest -BaseUrl $ollamaUrl -Name $m.Source
            if ($old -and $old -ne $new -and -not $NoKeepPrevious) {
                $pn = Get-PrevName $m.Source
                Remove-Model $pn
                Copy-Model $candidate $pn
                Hide-InWebUI $pn
                Write-LaiLog INFO ("  previous version kept as {0} (~{1} GB until the next update; Update-Models.ps1 -Rollback {2} brings it back, -DropPrevious frees it)" -f $pn, (Get-ModelGB $pn), $m.Key)
            }
        } finally { try { Remove-Model $candidate } catch { Write-Verbose "could not remove $candidate" } }
        # Also when the tuned alias was built from other content than the tag holds now: a run cut off
        # after the download but before the re-tune would otherwise report "unchanged" for good.
        $tunedDigest = ''
        if ($state['tuning'].ContainsKey($m.Key) -and $state['tuning'][$m.Key]['Digest']) { $tunedDigest = [string]$state['tuning'][$m.Key]['Digest'] }
        if ($old -ne $new -or $Retune -or ($tunedDigest -and $tunedDigest -ne $new) -or -not (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $m.Alias)) {
            Write-LaiLog INFO ("  {0}: {1} -> {2}" -f $m.Display, $(if ($old) { $old.Substring(0, 12) } else { 'missing' }), $new.Substring(0, 12))
            $changed += $m
        } else {
            Write-LaiLog OK "  $($m.Display): unchanged ($($new.Substring(0, 12)))"
        }
    }
}

$failedSetups = @()
$script:setupWhy = ''
function Invoke-ModelSetup {
    # One model at a time: a model that cannot be set up (e.g. a re-published tag this Ollama cannot
    # load) must not lose the others' results, and its own tuned alias stays as it was.
    # -Changed: this run downloaded the model anew (only then is -Rollback the way back).
    param([object]$Model, [hashtable]$SetupArgs, [switch]$Changed)
    try {
        $r = Invoke-LaiModelSetup -BaseUrl $ollamaUrl -Models @($Model) -Candidates $catalog.ContextCandidates -SystemPrompt $system `
            -MinFreeMiB $minFree -AllowCpu:$allowCpu @SetupArgs
        foreach ($k in $r.Keys) { $state['tuning'][$k] = $r[$k] }
        Save-LaiState -State $state -Path $statePath
        return $true
    } catch {
        $why = Get-LaiHttpErrorText $_
        if (-not $why) { $why = $_.Exception.Message }
        $script:failedSetups += $Model.Display
        if (-not $script:setupWhy) { $script:setupWhy = $why }
        Write-LaiLog FAIL "  $($Model.Display): not set up ($why)"
        $hasPrev = $false
        if ($Changed) {
            try { $hasPrev = Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name (Get-PrevName $Model.Source) } catch { Write-Verbose 'could not look for the previous version' }
        }
        foreach ($line in (Get-LaiModelSetupAdvice -Why $why -Display $Model.Display -Key $Model.Key -Changed:$Changed -HasPrevious:$hasPrev)) { Write-LaiLog INFO "  $line" }
        return $false
    }
}
function Wait-GpuIdle {
    # A run someone started waits for a quiet card; one that stays busy ends the run with a plain
    # message instead of an error trace.
    try { return (Wait-LaiGpuIdle -MaxUsedMiB $maxBusy -TimeoutSec 600) }
    catch { Write-LaiLog FAIL $_.Exception.Message; Stop-Run 1 }
}

if ($changed.Count -gt 0) {
    Stop-LaiOllamaModels -BaseUrl $ollamaUrl
    $gpu = Wait-GpuIdle
    $fingerprint = Get-CurrentFingerprint $gpu
    $done = @()
    foreach ($m in $changed) {
        if (Invoke-ModelSetup -Model $m -SetupArgs @{ Fingerprint = $fingerprint; Retune = $true } -Changed) { $done += $m.Display }
    }
    if ($done.Count) { Write-LaiLog OK "Re-tuned: $($done -join ', ')" }
} elseif (-not $RecheckOnly) {
    Write-LaiLog OK 'All models are current; nothing to re-tune.'
}

# A new Ollama (this run's -UpdateOllama, or one the tray app installed by itself) can place layers
# differently: load every other tuned model once and re-tune any that no longer fits fully on the GPU.
$ollamaNow = ''
try { $ollamaNow = [string](Get-LaiOllamaVersion -BaseUrl $ollamaUrl) } catch { Write-Verbose 'version unknown' }
if ($RecheckOnly -and -not $ollamaNow) {
    if ($Scheduled) { Exit-Skipped "Ollama was not running ($ollamaUrl)" }
    Write-LaiLog FAIL "Ollama is not answering on $ollamaUrl. Start it (Start menu > Local AI - Start again), then re-check again."
    Stop-Run 1
}
$changedKeys = @($changed | ForEach-Object { $_.Key })
# The same list the health watch and Test-LocalAI report, so running this clears their notice.
$driftKeys = @(Get-LaiTuningDrift -Tuning $state['tuning'] -OllamaVersion $ollamaNow -Keys @($catalog.Models | ForEach-Object { $_.Key }) | ForEach-Object { $_.Key })
# A re-check someone started (the Start-menu shortcut) also measures again a preset an earlier check
# left partly on the CPU: closing ComfyUI or a game first is often all it needed. Not the nightly run,
# which would load it again every night for the same result.
$offKeys = @()
if ($RecheckOnly -and -not $Scheduled -and -not $allowCpu) {
    $offKeys = @($catalog.Models | Where-Object { $state['tuning'][$_.Key] -is [hashtable] -and $null -ne $state['tuning'][$_.Key]['GpuPercent'] -and [int]$state['tuning'][$_.Key]['GpuPercent'] -lt 100 } | ForEach-Object { $_.Key })
}
$toVerify = @($catalog.Models | Where-Object { $changedKeys -notcontains $_.Key -and ($driftKeys -contains $_.Key -or $offKeys -contains $_.Key) })
if ($RecheckOnly -and $toVerify.Count -eq 0) {
    # Nothing written either: the last re-check's record stays what the health watch reads.
    Write-LaiLog OK "Nothing to re-check: every preset was measured on Ollama $ollamaNow$(if (-not $allowCpu) { ' and runs fully on the GPU' })."
    Stop-Run 0
}
$recheckOff = @(); $recheckFailed = @(); $recheckWhy = ''
if ($ollamaNow -and $toVerify.Count -gt 0) {
    Write-LaiLog STEP "Ollama is now ${ollamaNow}: checking that $(($toVerify | ForEach-Object { $_.Display }) -join ', ') still fit fully on the GPU"
    if ($Scheduled) {
        # Nobody is watching: never in the way, and never a result measured on a card something else
        # was using. Skipped (tomorrow night tries again) instead of waiting.
        $ws = Read-LaiState -Path (Join-Path $AIRoot 'watch-state.json')
        $paused = $null
        if ($ws['pausedUntil'] -is [datetime]) { $paused = $ws['pausedUntil'] }
        elseif ($ws['pausedUntil']) { try { $paused = [datetime]::Parse([string]$ws['pausedUntil'], [Globalization.CultureInfo]::InvariantCulture) } catch { $paused = $null } }
        if ($paused -and (Get-Date) -lt $paused) { Exit-Skipped ("Gaming mode is on (the health watch is paused until {0:HH:mm})" -f $paused) $ollamaNow }
        if ((Get-LaiChatsInFlight -TimeoutSec (Get-LaiDockerTimeout)) -gt 0) { Exit-Skipped 'a chat answer was being written' $ollamaNow }
        # Programs only: before the unload, Ollama's own models still fill the VRAM.
        $busy = Get-LaiGpuBusyReason
        if ($busy) { Exit-Skipped $busy $ollamaNow }
    }
    Stop-LaiOllamaModels -BaseUrl $ollamaUrl
    if ($Scheduled) { $gpu = Get-LaiGpuInfo } else { $gpu = Wait-GpuIdle }
    # Today's driver too: after a driver update the stored fingerprint no longer matches, so those
    # models are measured again instead of keeping a result recorded under the old driver.
    $vfp = Get-CurrentFingerprint $gpu
    foreach ($m in $toVerify) {
        if ($Scheduled) {
            # Before each model (the first: right after the unload, when the VRAM in use counts too).
            $busy = Get-LaiGpuBusyReason -MaxUsedMiB $maxBusy
            if ($busy) { $recheckWhy = $busy; Write-LaiLog WARN "Re-check stopped: $busy"; break }
        }
        $prevEntry = $state['tuning'][$m.Key]
        $setupArgs = @{ Previous = $state['tuning']; Fingerprint = $vfp }
        # Left partly on the CPU by an earlier check: search the context again from the top. Reusing
        # the stored (shrunken) one would load at 100% on a quiet card and never grow back.
        if ($offKeys -contains $m.Key) { $setupArgs['Retune'] = $true }
        $ok = Invoke-ModelSetup -Model $m -SetupArgs $setupArgs
        if ($Scheduled) {
            # A program that took the GPU, or a chat that started, while this model was measured (a
            # game started at night) makes the result meaningless: put back what was there (recorded
            # under the old Ollama, so the next run measures it again) and stop. A failed setup can
            # leave the model loaded: unloaded first, so its own VRAM does not count as another program.
            try { Stop-LaiOllamaModels -BaseUrl $ollamaUrl } catch { Write-Verbose "could not unload: $($_.Exception.Message)" }
            $busy = Get-LaiGpuBusyReason -MaxUsedMiB $maxBusy -AfterLoad
            if (-not $busy -and (Get-LaiChatsInFlight -TimeoutSec (Get-LaiDockerTimeout) -AfterLoad) -gt 0) { $busy = 'a chat answer started' }
            if ($busy) {
                if ($prevEntry) { $state['tuning'][$m.Key] = $prevEntry } else { $state['tuning'].Remove($m.Key) }
                Save-LaiState -State $state -Path $statePath
                $failedSetups = @($failedSetups | Where-Object { $_ -ne $m.Display })
                if ($recheckFailed.Count -eq 0) { $script:setupWhy = '' }
                # Not after a failed setup whose source model is gone: /api/create would download it.
                $haveSource = $ok
                if (-not $haveSource) { try { $haveSource = Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $m.Source } catch { $haveSource = $false } }
                if ($prevEntry -and $prevEntry['Context'] -and $haveSource) {
                    try { Set-LaiOllamaDerivedModel -BaseUrl $ollamaUrl -Name $m.Alias -From $m.Source -NumCtx ([int]$prevEntry['Context']) -Parameters $m.Parameters -System $system }
                    catch { Write-LaiLog WARN "  could not rebuild $($m.Alias) at its previous context: $($_.Exception.Message)" }
                }
                $recheckWhy = "$busy while $($m.Display) was measured"
                Write-LaiLog WARN "Re-check stopped: $recheckWhy; that result was discarded."
                break
            }
        }
        if (-not $ok) { $recheckFailed += $m.Display; continue }
        $t = $state['tuning'][$m.Key]
        if (-not $allowCpu -and $null -ne $t['GpuPercent'] -and [int]$t['GpuPercent'] -lt 100) { $recheckOff += ('{0} ({1}% GPU)' -f $m.Display, [int]$t['GpuPercent']) }
    }
    # For the health watch: a notification only when a preset could not be put back fully on the GPU.
    $presets = @(@($recheckFailed | ForEach-Object { "$_ (could not be set up)" }) + @($recheckOff))
    if ($recheckFailed.Count) { Save-Recheck -Result 'failed' -Presets $presets -Reason $script:setupWhy -Version $ollamaNow }
    elseif ($recheckOff.Count) { Save-Recheck -Result 'off-gpu' -Presets $presets -Reason 'not fully on the GPU even at the smallest context' -Version $ollamaNow }
    elseif ($recheckWhy) { Save-Recheck -Result 'skipped' -Reason $recheckWhy -Version $ollamaNow }
    else { Save-Recheck -Result 'ok' -Version $ollamaNow }
    if ($recheckOff.Count) {
        Write-LaiLog WARN ("Not fully on the GPU on Ollama {0}: {1}. If ComfyUI, a game or another GPU program was open, close it and re-check (Start menu > Local AI - Re-check models); otherwise this Ollama needs more VRAM for them than the last one did." -f $ollamaNow, ($recheckOff -join ', '))
    }
}

# The research agent (Install-LocalAI.ps1 -DeepResearch) asks Ollama for a context of its own: keep
# it equal to its model's tuned context, or every switch between chats and research reloads the model.
# Under the volume lock: its container must not be recreated while a backup has it paused.
try {
    $drLock = $null
    if ($config.ContainsKey('DeepResearchPort') -and [int]$config['DeepResearchPort'] -gt 0) { $drLock = Enter-LaiVolumeLock -TimeoutSec 900 }
    try {
        $drLine = Update-LaiDeepResearchContext -AIRoot $AIRoot -Tuning $state['tuning'] -Models @($catalog.Models)
        if ($drLine) { Write-LaiLog OK $drLine }
    } finally { Exit-LaiVolumeLock $drLock }
} catch { Write-LaiLog WARN "Could not update the deep research context: $($_.Exception.Message)" }

if ($failedPulls.Count -gt 0) {
    Write-LaiLog WARN "Not updated (download failed): $($failedPulls -join ', ')."
    if ($offline) { Write-LaiLog INFO 'Run Update-Models.ps1 again when the PC is online.' }
    else {
        # Online, so retrying later rarely helps: the reason is in the download messages above.
        Write-LaiLog INFO ("If the messages above say 'file does not exist', that tag was removed upstream: pick another in config\models.psd1. " +
            "If they say the model requires a newer version of Ollama, run Update-Models.ps1 -UpdateOllama. Otherwise run Update-Models.ps1 again later.")
    }
}
$problems = $failedPulls.Count + $failedSetups.Count
if (-not $SkipTests) {
    & (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick
    Stop-Run ([Math]::Max($LASTEXITCODE, $problems))
}
Stop-Run $problems
