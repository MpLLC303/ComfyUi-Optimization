<#
.SYNOPSIS
    Tests Update-Models.ps1 against a real Ollama: unchanged pull, a re-published tag (keeps
    <tag>-prev and re-tunes), -Rollback, and -DropPrevious.

.DESCRIPTION
    Works on private copies of the stand-in model (testorg/update-test:1b plus a variant with a
    different digest), so the models the other suites use are never touched. A re-publish upstream is
    simulated with LOCALAI_TEST_PULL_FROM (Update-Models copies that model over the tag instead of
    pulling, which the offline sandbox could not do anyway).
#>
param(
    [string]$OllamaUrl = 'http://127.0.0.1:11434',
    [string]$BaseModel = 'testorg/qwen3-abliterated:1.7b',
    [string]$Work = (Join-Path ([System.IO.Path]::GetTempPath()) 'lai-modelupdate')
)
$ErrorActionPreference = 'Stop'
# Refuses to run anywhere but a throwaway test machine (it would delete a real install's data).
if (-not (& (Join-Path $PSScriptRoot 'Assert-LaiSandbox.ps1'))) { exit 99 }
$src = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
$failures = 0
function Assert-That([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  ASSERT OK   $Message" -ForegroundColor Green }
    else { Write-Host "  ASSERT FAIL $Message" -ForegroundColor Red; $script:failures++ }
}

$tag = 'testorg/update-test:1b'
$variant = 'testorg/update-test:1b-v2'
$prev = "$tag-prev"
$alias = 'localai-update-test'
function Remove-IfThere([string]$Name) {
    if (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $Name) { Invoke-LaiApi -Method DELETE -Uri "$OllamaUrl/api/delete" -Body @{ model = $Name } | Out-Null }
}
function Get-Digest([string]$Name) { return (Get-LaiOllamaDigest -BaseUrl $OllamaUrl -Name $Name) }
function Invoke-Update([string[]]$Arguments, [string]$PullFrom) {
    $env:LOCALAI_TEST_PULL_FROM = $PullFrom
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & pwsh -NoProfile -File (Join-Path $src 'Update-Models.ps1') -AIRoot $aiRoot -SkipTests @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    $env:LOCALAI_TEST_PULL_FROM = ''
    $out | Select-Object -Last 3 | ForEach-Object { Write-Host "    | $_" }
    return [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}

# ---- setup -----------------------------------------------------------------------------------
if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
$aiRoot = Join-Path $Work 'AI'
New-Item -ItemType Directory -Force -Path $aiRoot | Out-Null
foreach ($n in @($tag, $variant, $prev, "$tag-prevnew", $alias)) { Remove-IfThere $n }
Invoke-LaiApi -Method POST -Uri "$OllamaUrl/api/copy" -Body @{ source = $BaseModel; destination = $tag } | Out-Null
Invoke-LaiApi -Method POST -Uri "$OllamaUrl/api/create" -TimeoutSec 300 -Body @{ model = $variant; from = $BaseModel; system = 'Re-published variant for the update test.' } | Out-Null
$original = Get-Digest $tag
Assert-That ($original -and (Get-Digest $variant) -ne $original) 'test model and its re-published variant have different digests'

$catalogFile = Join-Path $Work 'models.update-test.psd1'
@"
@{
    DefaultPreset     = 'local-main'
    ContextCandidates = @(8192, 4096)
    Models            = @(
        @{ Key = 'main'; Order = 1; Display = 'Update test'; Preset = 'local-main'; Alias = '$alias'; Source = '$tag'
           Optional = `$false; DownloadGB = 1.1; MaxContext = 8192; Vision = `$false; Think = `$null; MinTokensPerSec = 1
           Parameters = @{ temperature = 0.7 }; Description = 'Update-Models test model.' }
    )
}
"@ | Set-Content -LiteralPath $catalogFile
ConvertTo-Json @{ OllamaUrl = $OllamaUrl; SelectedModels = @('main') } | Set-Content -LiteralPath (Join-Path $aiRoot 'localai-config.json')
$env:LOCALAI_TEST_CATALOG = $catalogFile
$env:LOCALAI_TEST_ALLOW_CPU = '1'

$holder = $null
try {
    Write-Host "`n=== 1. nothing changed upstream ===" -ForegroundColor Cyan
    $r = Invoke-Update @() $tag
    Assert-That ($r.Code -eq 0) "update exits 0 (got $($r.Code))"
    Assert-That ((Get-Digest $tag) -eq $original) 'digest unchanged'
    Assert-That (-not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $prev)) 'no -prev kept when nothing changed'
    Assert-That (-not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name "$tag-prevnew")) 'temporary reference cleaned up'
    Assert-That (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $alias) 'missing alias was (re)built'

    Write-Host "`n=== 2. tag re-published upstream ===" -ForegroundColor Cyan
    $r = Invoke-Update @() $variant
    Assert-That ($r.Code -eq 0) "update exits 0 (got $($r.Code))"
    Assert-That ((Get-Digest $tag) -eq (Get-Digest $variant)) 'tag now has the new content'
    Assert-That ((Get-Digest $prev) -eq $original) 'previous version kept as -prev'
    Assert-That ($r.Text -match 'Re-tuned') 'changed model was re-tuned'
    Assert-That (-not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name "$tag-prevnew")) 'temporary reference cleaned up'

    Write-Host "`n=== 2b. a new Ollama re-checks the tuned models ===" -ForegroundColor Cyan
    # Ollama was updated (by -UpdateOllama, or the tray app): placement may differ, so the tuned
    # models are loaded once even though none of them changed.
    $stPath = Join-Path $aiRoot 'install-state.json'
    $st2 = Read-LaiState -Path $stPath
    $ctxBefore = $st2['tuning']['main']['Context']
    $st2['tuning']['main']['OllamaVersion'] = '0.0.1'
    Save-LaiState -State $st2 -Path $stPath
    $r = Invoke-Update @() $variant
    $st3 = Read-LaiState -Path $stPath
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Ollama is now' -and [string]$st3['tuning']['main']['OllamaVersion'] -eq (Get-LaiOllamaVersion -BaseUrl $OllamaUrl)) "after an Ollama version change the model is checked again (exit $($r.Code))"
    Assert-That ($st3['tuning']['main']['Context'] -eq $ctxBefore) 'and keeps its context when it still fits'
    $r = Invoke-Update @() $variant
    Assert-That ($r.Text -notmatch 'Ollama is now') 'nothing to re-check on the next run'

    Write-Host "`n=== 2c. a re-published tag this Ollama cannot load keeps the working preset ===" -ForegroundColor Cyan
    # LOCALAI_TEST_LOAD_FAIL makes every load of the tag fail the way Ollama reports weights it cannot
    # read; the alias (what Open WebUI chats with) still loads, as it would on its old blobs.
    $aliasBefore = Get-Digest $alias
    $tunedBefore = [string](Read-LaiState -Path $stPath)['tuning']['main']['Digest']
    $env:LOCALAI_TEST_LOAD_FAIL = $tag
    try { $r = Invoke-Update @() $BaseModel } finally { $env:LOCALAI_TEST_LOAD_FAIL = '' }
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'could not be loaded at any context') "the run ends with an error that says the new download does not load (exit $($r.Code))"
    Assert-That ((Get-Digest $alias) -eq $aliasBefore) 'the tuned alias was not rebuilt on the unloadable weights'
    Assert-That ([string](Read-LaiState -Path $stPath)['tuning']['main']['Digest'] -eq $tunedBefore) 'install-state still records the version the alias was tuned on'
    Assert-That ($r.Text -match 'Update-Models\.ps1 -UpdateOllama' -and $r.Text -match 'Update-Models\.ps1 -Rollback main') 'it names both ways out: a newer Ollama, or -Rollback main'
    Assert-That ($r.Text -notmatch 'does not fit fully in VRAM') "no misleading 'does not fit in VRAM' warning"
    # Fixed (here: the hook gone, as after -UpdateOllama): the next run sets it up by itself.
    $r = Invoke-Update @() $BaseModel
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Re-tuned') "the next run retries and re-tunes it (exit $($r.Code))"
    # Back to the state the steps below expect: the tag on the variant, the original kept as -prev.
    $r = Invoke-Update @() $variant
    Assert-That ($r.Code -eq 0 -and (Get-Digest $tag) -eq (Get-Digest $variant) -and (Get-Digest $prev) -eq $original) 'setup for the next steps: tag on the variant again, original kept as -prev'

    Write-Host "`n=== 2d. a failed re-check after an Ollama update does not advise -Rollback ===" -ForegroundColor Cyan
    # Nothing was downloaded (the tag is unchanged; a -prev from the earlier update is still there):
    # the model did not change, so swapping in that older copy would not touch the cause.
    $st4 = Read-LaiState -Path $stPath
    $st4['tuning']['main']['OllamaVersion'] = '0.0.1'
    Save-LaiState -State $st4 -Path $stPath
    $env:LOCALAI_TEST_LOAD_FAIL = $alias
    try { $r = Invoke-Update @() $variant } finally { $env:LOCALAI_TEST_LOAD_FAIL = '' }
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'Ollama is now' -and $r.Text -match 'not set up') "the re-check fails and the run exits non-zero (exit $($r.Code))"
    Assert-That ($r.Text -notmatch '-Rollback main' -and $r.Text -match 'Update-Models\.ps1 -UpdateOllama') 'it advises a newer Ollama, not -Rollback of a model that did not change'
    Assert-That ((Get-Digest $prev) -eq $original -and (Get-Digest $tag) -eq (Get-Digest $variant)) 'nothing was rolled back or swapped by itself'
    $r = Invoke-Update @() $variant
    $st5 = Read-LaiState -Path $stPath
    Assert-That ($r.Code -eq 0 -and [string]$st5['tuning']['main']['OllamaVersion'] -eq (Get-LaiOllamaVersion -BaseUrl $OllamaUrl)) "the next run re-checks it and records this Ollama (exit $($r.Code))"

    Write-Host "`n=== 3. -Rollback main ===" -ForegroundColor Cyan
    $r = Invoke-Update @('-Rollback', 'main') ''
    Assert-That ($r.Code -eq 0) "rollback exits 0 (got $($r.Code))"
    Assert-That ((Get-Digest $tag) -eq $original) 'tag is back to the original content'
    Assert-That (-not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $prev)) '-prev consumed by the rollback'
    $r = Invoke-Update @('-Rollback', 'main') ''
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'Nothing to roll back') 'second rollback refuses clearly'
    $r = Invoke-Update @() $variant
    Assert-That ((Get-Digest $tag) -eq $original -and $r.Text -match 'pinned after a rollback') 'rolled-back model is pinned: the next update leaves it alone'
    $r = Invoke-Update @('-Unpin', 'main') ''
    Assert-That ($r.Code -eq 0) 'unpin'

    Write-Host "`n=== 3b. a failed download keeps the current version, no leftovers ===" -ForegroundColor Cyan
    $before = Get-Digest $tag
    $r = Invoke-Update @() 'testorg/does-not-exist:1b'
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'download failed') "failed download is reported and the run exits non-zero (exit $($r.Code))"
    Assert-That ((Get-Digest $tag) -eq $before) 'model unchanged'
    Assert-That (-not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name "$tag-prevnew")) 'temporary reference cleaned up after the failure'

    Assert-That ((Test-LaiRegistryReachable -Url "$OllamaUrl/v2/") -and -not (Test-LaiRegistryReachable -Url 'http://127.0.0.1:1/v2/' -TimeoutSec 3)) 'registry probe: an HTTP 404 counts as online, a refused connection as offline'

    Write-Host "`n=== 3c. a run cut off after the download is finished by the next run ===" -ForegroundColor Cyan
    # The tag already holds new content (the pull finished), but the re-tune never ran: the tuned
    # alias and the recorded digest are still the old ones.
    Invoke-LaiApi -Method POST -Uri "$OllamaUrl/api/copy" -Body @{ source = $variant; destination = $tag } | Out-Null
    $tunedBefore = [string](Read-LaiState -Path (Join-Path $aiRoot 'install-state.json'))['tuning']['main']['Digest']
    $r = Invoke-Update @() $variant
    $tunedAfter = [string](Read-LaiState -Path (Join-Path $aiRoot 'install-state.json'))['tuning']['main']['Digest']
    Assert-That ($tunedBefore -and $tunedBefore -ne (Get-Digest $tag)) 'setup: tuning still records the old content'
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Re-tuned' -and $tunedAfter -eq (Get-Digest $tag)) "the stale alias is re-tuned although the download itself found nothing new ($tunedAfter)"
    Invoke-LaiApi -Method POST -Uri "$OllamaUrl/api/copy" -Body @{ source = $BaseModel; destination = $tag } | Out-Null

    Write-Host "`n=== 4. -DropPrevious ===" -ForegroundColor Cyan
    Invoke-Update @() $variant | Out-Null
    Assert-That (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $prev) '-prev kept again after another re-publish'
    $r = Invoke-Update @('-DropPrevious') ''
    Assert-That ($r.Code -eq 0 -and -not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $prev)) '-DropPrevious deletes it'

    Write-Host "`n=== 5. one model update at a time ===" -ForegroundColor Cyan
    $holdScript = Join-Path $Work 'hold-setup.ps1'
    $ready = Join-Path $Work 'holder.ready'
    Set-Content -LiteralPath $holdScript -Value ("Import-Module '{0}' -Force; `$l = Enter-LaiSetupLock; Set-Content -LiteralPath '{1}' -Value x; Start-Sleep -Seconds 60" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'), $ready)
    $holder = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $holdScript) -PassThru
    # Wait until it really holds the lock (a cold pwsh start can take several seconds on CI).
    for ($i = 0; $i -lt 150 -and -not (Test-Path -LiteralPath $ready) -and -not $holder.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
    Assert-That (Test-Path -LiteralPath $ready) 'setup: the other process holds the setup lock'
    $r = Invoke-Update @() ''
    if (-not $holder.HasExited) { $holder.Kill() }
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'already running') "a second update refuses while another holds the lock (exit $($r.Code))"
} finally {
    if ($holder -and -not $holder.HasExited) { $holder.Kill() }
    foreach ($n in @($tag, $variant, $prev, "$tag-prevnew", $alias)) { try { Remove-IfThere $n } catch { Write-Verbose "cleanup $n" } }
    $env:LOCALAI_TEST_CATALOG = ''
}

if ($failures -eq 0) { Write-Host "`nMODEL UPDATE TEST PASSED" -ForegroundColor Green } else { Write-Host "`nMODEL UPDATE TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
