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

.EXAMPLE
    .\Update-Models.ps1                    # check all models
.EXAMPLE
    .\Update-Models.ps1 -UpdateOllama      # upgrade Ollama via winget first
.EXAMPLE
    .\Update-Models.ps1 -Retune            # re-measure every model even if nothing changed
#>
param(
    [string]$AIRoot = 'C:\AI',
    [switch]$UpdateOllama,
    [switch]$Retune,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$statePath = Join-Path $AIRoot 'install-state.json'
$state = Read-LaiState -Path $statePath
if (-not $state.ContainsKey('tuning') -or $null -eq $state['tuning']) { $state['tuning'] = @{} }
$ollamaUrl = 'http://127.0.0.1:11434'
if ($config.ContainsKey('OllamaUrl') -and $config['OllamaUrl']) { $ollamaUrl = $config['OllamaUrl'] }
$selected = @()
if ($config.ContainsKey('SelectedModels')) { $selected = @($config['SelectedModels']) }
$catalogPath = Join-Path (Join-Path $PSScriptRoot 'config') 'models.psd1'
if ($env:LOCALAI_TEST_CATALOG) { $catalogPath = $env:LOCALAI_TEST_CATALOG }
$catalog = Get-LaiCatalog -Path $catalogPath -IncludeKeys $selected
$system = (Get-Content -LiteralPath (Join-Path (Join-Path $PSScriptRoot 'config') 'system-prompt.txt') -Raw).Trim()
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
$changed = @()
foreach ($m in $catalog.Models) {
    $old = Get-LaiOllamaDigest -BaseUrl $ollamaUrl -Name $m.Source
    Write-LaiLog STEP "Checking $($m.Source)"
    Invoke-LaiOllamaPull -BaseUrl $ollamaUrl -Name $m.Source
    $new = Get-LaiOllamaDigest -BaseUrl $ollamaUrl -Name $m.Source
    if ($old -ne $new -or $Retune -or -not (Test-LaiOllamaModel -BaseUrl $ollamaUrl -Name $m.Alias)) {
        Write-LaiLog INFO ("  {0}: {1} -> {2}" -f $m.Display, $(if ($old) { $old.Substring(0, 12) } else { 'missing' }), $new.Substring(0, 12))
        $changed += $m
    } else {
        Write-LaiLog OK "  $($m.Display): unchanged ($($new.Substring(0, 12)))"
    }
}

if ($changed.Count -gt 0) {
    Stop-LaiOllamaModels -BaseUrl $ollamaUrl
    $gpu = Wait-LaiGpuIdle -MaxUsedMiB $maxBusy -TimeoutSec 600
    $fingerprint = ''
    foreach ($k in $state['tuning'].Keys) { if ($state['tuning'][$k]['Fingerprint']) { $fingerprint = $state['tuning'][$k]['Fingerprint']; break } }
    if (-not $fingerprint -and $gpu) { $fingerprint = "driver=$($gpu.DriverVersion)" }
    $results = Invoke-LaiModelSetup -BaseUrl $ollamaUrl -Models $changed -Candidates $catalog.ContextCandidates -SystemPrompt $system `
        -Fingerprint $fingerprint -MinFreeMiB $minFree -Retune -AllowCpu:$allowCpu
    foreach ($k in $results.Keys) { $state['tuning'][$k] = $results[$k] }
    Save-LaiState -State $state -Path $statePath
    Write-LaiLog OK "Re-tuned: $(($changed | ForEach-Object { $_.Display }) -join ', ')"
} else {
    Write-LaiLog OK 'All models are current; nothing to re-tune.'
}

if (-not $SkipTests) {
    & (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick
    exit $LASTEXITCODE
}
exit 0
