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

.EXAMPLE
    .\Update-Models.ps1                    # check all models
.EXAMPLE
    .\Update-Models.ps1 -UpdateOllama      # upgrade Ollama via winget first
.EXAMPLE
    .\Update-Models.ps1 -Retune            # re-measure every model even if nothing changed
.EXAMPLE
    .\Update-Models.ps1 -Rollback main     # go back to the previous version of Local Main ('all' = every kept one)
.EXAMPLE
    .\Update-Models.ps1 -DropPrevious      # delete the kept previous versions to free the disk space
.EXAMPLE
    .\Update-Models.ps1 -Unpin main        # after a -Rollback: let updates touch Local Main again
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
    [switch]$NoKeepPrevious
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$statePath = Join-Path $AIRoot 'install-state.json'
# Not while the installer or another model update runs: both tune the same models.
$script:SetupLock = Enter-LaiSetupLock
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
    exit 0
}
if ($DropPrevious) {
    foreach ($m in $catalog.Models) {
        $pn = Get-PrevName $m.Source
        if (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $pn) { Remove-Model $pn; Write-LaiLog OK "Deleted $pn" }
    }
    exit 0
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
} else {
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

if ($changed.Count -gt 0) {
    Stop-LaiOllamaModels -BaseUrl $ollamaUrl
    $gpu = Wait-LaiGpuIdle -MaxUsedMiB $maxBusy -TimeoutSec 600
    $fingerprint = ''
    foreach ($k in $state['tuning'].Keys) { if ($state['tuning'][$k]['Fingerprint']) { $fingerprint = $state['tuning'][$k]['Fingerprint']; break } }
    if (-not $fingerprint -and $gpu) { $fingerprint = "driver=$($gpu.DriverVersion)" }
    # Today's driver, not the one stored with the old tuning: otherwise the next installer run sees a
    # 'driver change' and measures these freshly tuned models all over again.
    elseif ($gpu) { $fingerprint = $fingerprint -replace '(^|;)driver=[^;]*', ('$1driver=' + $gpu.DriverVersion) }
    $results = Invoke-LaiModelSetup -BaseUrl $ollamaUrl -Models $changed -Candidates $catalog.ContextCandidates -SystemPrompt $system `
        -Fingerprint $fingerprint -MinFreeMiB $minFree -Retune -AllowCpu:$allowCpu
    foreach ($k in $results.Keys) { $state['tuning'][$k] = $results[$k] }
    Save-LaiState -State $state -Path $statePath
    Write-LaiLog OK "Re-tuned: $(($changed | ForEach-Object { $_.Display }) -join ', ')"
} else {
    Write-LaiLog OK 'All models are current; nothing to re-tune.'
}

if ($failedPulls.Count -gt 0) { Write-LaiLog WARN "Not updated (download failed): $($failedPulls -join ', '). Run Update-Models.ps1 again later." }
if (-not $SkipTests) {
    & (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick
    exit [Math]::Max($LASTEXITCODE, $failedPulls.Count)
}
exit $failedPulls.Count
