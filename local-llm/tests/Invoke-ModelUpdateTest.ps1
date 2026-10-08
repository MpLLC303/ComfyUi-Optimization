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
# The nightly re-check skips while a chat answer is being written: the shared sandbox's render guard
# may be serving one, so the count comes from the hook (and no docker call is made).
$env:LOCALAI_TEST_CHATS_IN_FLIGHT = '0'

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

    Write-Host "`n=== 2e. -RecheckOnly / -Scheduled: the re-check after Ollama updated itself, no downloads ===" -ForegroundColor Cyan
    $ollamaVer = [string](Get-LaiOllamaVersion -BaseUrl $OllamaUrl)
    $recheckFile = Join-Path $aiRoot 'model-recheck.json'
    $recheckLog = Join-Path (Join-Path $aiRoot 'Logs') 'model-recheck.log'
    $setOld = { $s = Read-LaiState -Path $stPath; $s['tuning']['main']['OllamaVersion'] = '0.0.1'; Save-LaiState -State $s -Path $stPath }
    $tunedVer = { [string](Read-LaiState -Path $stPath)['tuning']['main']['OllamaVersion'] }
    & $setOld
    $digestBefore = Get-Digest $tag
    # A pull from a model that does not exist would fail loudly: the run must not try one.
    $r = Invoke-Update @('-RecheckOnly') 'testorg/does-not-exist:1b'
    $rec = Read-LaiState -Path $recheckFile
    Assert-That ($r.Code -eq 0 -and $r.Text -notmatch 'download failed' -and $r.Text -notmatch 'Checking testorg/update-test' -and (Get-Digest $tag) -eq $digestBefore) "-RecheckOnly downloads nothing (exit $($r.Code))"
    Assert-That ($r.Text -match 'Ollama is now' -and (& $tunedVer) -eq $ollamaVer) "the preset is re-checked and the running Ollama recorded ($(& $tunedVer))"
    Assert-That ([string]$rec['result'] -eq 'ok' -and [string]$rec['ollamaVersion'] -eq $ollamaVer) "model-recheck.json: ok on $ollamaVer ($($rec['result']), $($rec['ollamaVersion']))"
    $r = Invoke-Update @('-RecheckOnly') ''
    $rec2 = Read-LaiState -Path $recheckFile
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Nothing to re-check' -and "$($rec2['at'])" -eq "$($rec['at'])") 'nothing left to re-check: says so and leaves the record alone'
    $r = Invoke-Update @('-RecheckOnly', '-Rollback', 'main') ''
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'cannot be combined' -and (Get-Digest $tag) -eq $digestBefore -and (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $prev)) "-RecheckOnly -Rollback is refused and rolls nothing back (exit $($r.Code))"

    # The nightly run with the GPU in use: skipped, nothing measured, exit 0 (the task shows no error).
    & $setOld
    $env:LOCALAI_TEST_GPU_BUSY = 'GPU in use by Game.exe (test)'
    try { $r = Invoke-Update @('-Scheduled') '' } finally { $env:LOCALAI_TEST_GPU_BUSY = '' }
    $rec = Read-LaiState -Path $recheckFile
    Assert-That ($r.Code -eq 0 -and [string]$rec['result'] -eq 'skipped' -and [string]$rec['reason'] -match 'Game\.exe') "-Scheduled with the GPU in use: skipped with the reason, exit 0 (exit $($r.Code), $($rec['result']): $($rec['reason']))"
    Assert-That ((& $tunedVer) -eq '0.0.1') 'nothing measured: the preset still waits for its re-check'
    Assert-That ((Test-Path -LiteralPath $recheckLog) -and (Get-Content -Raw -LiteralPath $recheckLog) -match 'Re-check skipped') 'the nightly run keeps its log in Logs\model-recheck.log'

    # A program took the GPU while the model was being measured: that result is not kept.
    $ctxBefore = [int](Read-LaiState -Path $stPath)['tuning']['main']['Context']
    $env:LOCALAI_TEST_GPU_BUSY = 'after-load'
    try { $r = Invoke-Update @('-Scheduled') '' } finally { $env:LOCALAI_TEST_GPU_BUSY = '' }
    $rec = Read-LaiState -Path $recheckFile
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'discarded' -and [string]$rec['result'] -eq 'skipped') "a measurement the GPU was taken from mid-way is discarded (exit $($r.Code), $($rec['result']))"
    Assert-That ((& $tunedVer) -eq '0.0.1' -and [int](Read-LaiState -Path $stPath)['tuning']['main']['Context'] -eq $ctxBefore) 'and not recorded under the new Ollama: the next night measures it again'
    $aliasParams = (Get-LaiOllamaModelInfo -BaseUrl $OllamaUrl -Name $alias).Parameters
    Assert-That ($aliasParams -match "num_ctx\s+$ctxBefore\b") "the preset's alias is back at its previous context ($ctxBefore)"

    # A chat that started while the model was being measured: the same (the chat slowed the load).
    $env:LOCALAI_TEST_CHATS_IN_FLIGHT = 'after-load'
    try { $r = Invoke-Update @('-Scheduled') '' } finally { $env:LOCALAI_TEST_CHATS_IN_FLIGHT = '0' }
    $rec = Read-LaiState -Path $recheckFile
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'discarded' -and [string]$rec['result'] -eq 'skipped' -and [string]$rec['reason'] -match 'chat' -and (& $tunedVer) -eq '0.0.1') "a chat that started mid-measurement: result discarded, nothing recorded (exit $($r.Code), $($rec['result']): $($rec['reason']))"

    # The measurement fails with the model still loaded: unloaded before the after-load check (on a
    # real GPU its own VRAM would read as another program and turn 'failed' into 'skipped').
    $env:LOCALAI_TEST_SPEED_FAIL = $alias
    try { $r = Invoke-Update @('-Scheduled') '' } finally { $env:LOCALAI_TEST_SPEED_FAIL = '' }
    $rec = Read-LaiState -Path $recheckFile
    $loadedNow = @(Get-LaiOllamaLoaded -BaseUrl $OllamaUrl | ForEach-Object { [string]$_.name })
    Assert-That ([string]$rec['result'] -eq 'failed' -and $loadedNow -notcontains "${alias}:latest") "a setup that failed with the model loaded is recorded as failed and the model unloaded ($($rec['result']); loaded: $($loadedNow -join ', '))"
    $r = Invoke-Update @('-RecheckOnly') ''
    Assert-That ($r.Code -eq 0 -and (& $tunedVer) -eq $ollamaVer) "setup for the next steps: re-checked by hand (exit $($r.Code))"

    # A preset an earlier check left partly on the CPU is searched again from the largest context,
    # not reloaded at its stored, shrunken one (which on a quiet card would load at 100% and stay small).
    $s2 = Read-LaiState -Path $stPath; $s2['tuning']['main']['GpuPercent'] = 50; $s2['tuning']['main']['Context'] = 4096; Save-LaiState -State $s2 -Path $stPath
    $env:LOCALAI_TEST_ALLOW_CPU = ''
    try { $r = Invoke-Update @('-RecheckOnly') '' } finally { $env:LOCALAI_TEST_ALLOW_CPU = '1' }
    Assert-That ($r.Text -match 'Update test' -and $r.Text -notmatch 'reusing tuned context' -and $r.Text -match 'ctx\s+8192:') "a preset left partly on the CPU is re-tuned from the top, not reused at 4096 (exit $($r.Code))"
    $s2 = Read-LaiState -Path $stPath; $s2['tuning']['main']['GpuPercent'] = 100; Save-LaiState -State $s2 -Path $stPath
    & $setOld

    # The re-check runs but the preset cannot be set up on this Ollama: recorded for the watch's notice.
    $env:LOCALAI_TEST_LOAD_FAIL = $alias
    try { $r = Invoke-Update @('-Scheduled') '' } finally { $env:LOCALAI_TEST_LOAD_FAIL = '' }
    $rec = Read-LaiState -Path $recheckFile
    Assert-That ($r.Code -ne 0 -and [string]$rec['result'] -eq 'failed' -and [string]$rec['ollamaVersion'] -eq $ollamaVer -and (@($rec['presets']) -join ' ') -match 'Update test' -and [string]$rec['reason'] -match 'incompatible') "a preset that cannot be set up: model-recheck.json says failed and names it (exit $($r.Code), $($rec['result']): $(@($rec['presets']) -join ', '))"
    # The next night is skipped (GPU in use): the failed record stays, so the health check keeps warning.
    $env:LOCALAI_TEST_GPU_BUSY = 'GPU in use by Game.exe (test)'
    try { $r = Invoke-Update @('-Scheduled') '' } finally { $env:LOCALAI_TEST_GPU_BUSY = '' }
    $rec = Read-LaiState -Path $recheckFile
    Assert-That ($r.Code -eq 0 -and [string]$rec['result'] -eq 'failed' -and [string]$rec['lastSkip'] -match 'Game\.exe') "a later skip does not replace the failed record; the skip is noted on it ($($rec['result']), last skip: $($rec['lastSkip']))"
    $r = Invoke-Update @('-RecheckOnly') ''
    $rec = Read-LaiState -Path $recheckFile
    Assert-That ($r.Code -eq 0 -and [string]$rec['result'] -eq 'ok' -and (& $tunedVer) -eq $ollamaVer) "the Start-menu re-check fixes it once the cause is gone (exit $($r.Code))"

    Write-Host "`n=== 3. -Rollback main ===" -ForegroundColor Cyan
    # The words of the WARN a rollback ends with when its preset was not rebuilt to the end.
    $notRebuilt = 'rebuild of its preset was not completed'
    $tunedOn = { [string](Read-LaiState -Path $stPath)['tuning']['main']['Digest'] }
    $pinnedNow = { $f = (Read-LaiState -Path $stPath)['flags']; if ($f -is [hashtable]) { @($f['pinnedModels']) } else { @() } }
    $r = Invoke-Update @('-Rollback', 'main') ''
    Assert-That ($r.Code -eq 0) "rollback exits 0 (got $($r.Code))"
    Assert-That ((Get-Digest $tag) -eq $original) 'tag is back to the original content'
    Assert-That (-not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $prev)) '-prev consumed by the rollback'
    # "Back to the previous version" is only true once the preset was rebuilt on it: the OK comes
    # after the re-tune, not before it.
    $tuneAt = $r.Text.IndexOf('Tuning Update test', [StringComparison]::Ordinal)
    $okAt = $r.Text.IndexOf('pinned so the next update', [StringComparison]::Ordinal)
    Assert-That ($tuneAt -ge 0 -and $okAt -gt $tuneAt) "the rollback's OK line is printed after the re-tune, not before it (re-tune at $tuneAt, OK at $okAt)"
    Assert-That ($r.Text -match 'Re-tuned:' -and $r.Text -notmatch $notRebuilt -and (& $tunedOn) -eq $original) 'and the preset was rebuilt on the restored version'
    $r = Invoke-Update @('-Rollback', 'main') ''
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'Nothing to roll back') 'second rollback refuses clearly'
    $r = Invoke-Update @() $variant
    Assert-That ((Get-Digest $tag) -eq $original -and $r.Text -match 'pinned after a rollback') 'rolled-back model is pinned: the next update leaves it alone'
    Assert-That ($r.Code -eq 0 -and $r.Text -notmatch 'Re-tuned:') "and its preset, already built on the restored version, is not re-tuned again (exit $($r.Code))"
    $r = Invoke-Update @('-Unpin', 'main') ''
    Assert-That ($r.Code -eq 0) 'unpin'

    # A rollback whose re-tune fails, three ways (the other two follow below). Here the restored
    # version does not load: the tag is back and pinned, the preset is not rebuilt, and the run says
    # that instead of OK.
    $r = Invoke-Update @() $variant
    $variantDigest = Get-Digest $variant
    Assert-That ($r.Code -eq 0 -and (Get-Digest $tag) -eq $variantDigest -and (Get-Digest $prev) -eq $original) "setup: re-published once more, the original kept as -prev (exit $($r.Code))"
    $env:LOCALAI_TEST_LOAD_FAIL = $tag
    try { $r = Invoke-Update @('-Rollback', 'main') '' } finally { $env:LOCALAI_TEST_LOAD_FAIL = '' }
    Assert-That ($r.Code -ne 0) "a rollback whose re-tune fails exits non-zero (exit $($r.Code))"
    Assert-That ((Get-Digest $tag) -eq $original -and -not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $prev)) 'its tag is back on the original all the same, and -prev is used up'
    Assert-That ($r.Text -match $notRebuilt -and $r.Text -notmatch 'pinned so the next update') 'it says the tag is back but the rebuild of the preset was not completed, and prints no OK for the rollback'
    Assert-That ($r.Text -match "cannot load Update test's files" -and $r.Text -notmatch 'the new download') 'and it does not call the restored version a new download'
    Assert-That ([string](Read-LaiState -Path $stPath)['tuning']['main']['Digest'] -eq $variantDigest) 'install-state still records the upload the preset was really built on'
    $r = Invoke-Update @('-Rollback', 'main') ''
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'Nothing to roll back') 'a second rollback has nothing to roll back: it cannot be what repairs the preset'
    # While the cause lasts, a plain run tries the pinned model again and fails the same honest way.
    $env:LOCALAI_TEST_LOAD_FAIL = $tag
    try { $r = Invoke-Update @() $variant } finally { $env:LOCALAI_TEST_LOAD_FAIL = '' }
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'pinned after a rollback' -and $r.Text -match 'not set up' -and $r.Text -notmatch 'the new download' -and (Get-Digest $tag) -eq $original) "a plain run retries the pinned model's preset while the cause lasts, downloads nothing and exits non-zero (exit $($r.Code))"
    # The cause gone: the next plain run finishes the rollback, still without downloading anything.
    $r = Invoke-Update @() $variant
    $tunedNow = [string](Read-LaiState -Path $stPath)['tuning']['main']['Digest']
    Assert-That ($r.Code -eq 0 -and (Get-Digest $tag) -eq $original -and $r.Text -match 'pinned after a rollback') "the next plain run still downloads nothing for the pinned model (exit $($r.Code))"
    Assert-That ($r.Text -match 'Re-tuned:' -and $tunedNow -eq $original) "but it finishes the rollback: the preset is rebuilt on the restored version ($tunedNow)"
    $r = Invoke-Update @() $variant
    Assert-That ($r.Code -eq 0 -and $r.Text -notmatch 'Re-tuned:' -and (Get-Digest $tag) -eq $original) "and the run after that has nothing left to rebuild (exit $($r.Code))"

    # The other two ways start from the same state: unpinned and re-published once more, so the tag
    # is on the variant, the original is kept as -prev and the preset was measured on the variant.
    $republish = {
        param([string]$Before)
        $u = Invoke-Update @('-Unpin', 'main') ''
        $p = Invoke-Update @() $variant
        Assert-That ($u.Code -eq 0 -and $p.Code -eq 0 -and (Get-Digest $tag) -eq $variantDigest -and (Get-Digest $prev) -eq $original -and (& $tunedOn) -eq $variantDigest) "setup ($Before): unpinned and re-published, the original kept as -prev, the preset measured on the new upload (exit $($u.Code), $($p.Code))"
    }
    # The plain run after a rollback that could not finish: nothing is downloaded for the pinned
    # model, and the preset is rebuilt and measured on the restored version.
    $finish = {
        param([string]$After)
        $p = Invoke-Update @() $variant
        Assert-That ($p.Code -eq 0 -and $p.Text -match 'pinned after a rollback' -and (Get-Digest $tag) -eq $original) "the plain run after $After downloads nothing for the pinned model (exit $($p.Code))"
        Assert-That ($p.Text -match 'Re-tuned:' -and (& $tunedOn) -eq $original) "and finishes the rollback: the preset is measured on the restored version ($(& $tunedOn))"
    }

    # The GPU stays busy: the run ends at the wait for a quiet card, before anything is tuned. The
    # tag is back and pinned by then, so the run must say that the preset is not, and not only why
    # it stopped. (-TestGpuStaysBusy ends the wait the way ten minutes of a busy card end it.)
    & $republish 'the GPU stays busy'
    $r = Invoke-Update @('-Rollback', 'main', '-TestGpuStaysBusy') ''
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'The GPU counts as busy' -and $r.Text -notmatch 'Tuning Update test') "a rollback that finds the GPU busy ends there with the reason and exit 1, before any tuning (exit $($r.Code))"
    Assert-That ($r.Text -match $notRebuilt -and $r.Text -notmatch 'pinned so the next update') 'it says the tag is back but the rebuild of the preset was not completed, and prints no OK for the rollback'
    Assert-That ((Get-Digest $tag) -eq $original -and -not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $prev)) 'its tag is back on the original, and -prev is used up'
    Assert-That (@(& $pinnedNow) -contains 'main' -and (& $tunedOn) -eq $variantDigest) "install-state.json has the model pinned and still records the upload the preset was built on (pinned: $(@(& $pinnedNow) -join ', '))"
    & $finish 'a busy GPU'

    # The failure comes after the alias was rebuilt: the search on the restored tag finds a context,
    # the alias is created from it, and then its speed cannot be measured. Chats get the restored
    # version from then on, so "chats still get the version you rolled back from" would be false
    # here; the run says only what holds in every case, and the same plain run finishes it.
    & $republish 'the measurement fails'
    $env:LOCALAI_TEST_SPEED_FAIL = $alias
    try { $r = Invoke-Update @('-Rollback', 'main') '' } finally { $env:LOCALAI_TEST_SPEED_FAIL = '' }
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'ctx\s+8192:' -and $r.Text -match 'speed measurement failed') "a rollback whose re-tune fails after the alias was rebuilt exits non-zero (exit $($r.Code))"
    Assert-That ($r.Text -match $notRebuilt -and $r.Text -notmatch 'pinned so the next update') 'it says the rebuild of the preset was not completed, and prints no OK for the rollback'
    Assert-That ($r.Text -match 'chats may still get' -and $r.Text -notmatch 'chats still get') 'it does not claim that chats still get the newer upload: this alias was already rebuilt on the restored one'
    Assert-That ((Get-Digest $tag) -eq $original -and @(& $pinnedNow) -contains 'main' -and (& $tunedOn) -eq $variantDigest) 'the tag is back on the original and pinned, and install-state.json does not record a measurement that did not finish'
    & $finish 'a failed measurement'
    # Pinned means no download, not no upkeep: -Retune and a deleted alias are still handled.
    $r = Invoke-Update @('-Retune') $variant
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Re-tuned:' -and (Get-Digest $tag) -eq $original) "-Retune measures a pinned model again without downloading it (exit $($r.Code))"
    Remove-IfThere $alias
    $r = Invoke-Update @() $variant
    Assert-That ($r.Code -eq 0 -and (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $alias) -and (Get-Digest $tag) -eq $original) "a pinned model's deleted alias is rebuilt, again without a download (exit $($r.Code))"
    # The tag itself deleted by hand: nothing to build from, so a warning and no error trace.
    Remove-IfThere $tag
    $r = Invoke-Update @() $variant
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'is not in Ollama any more' -and $r.Text -notmatch 'Re-tuned:' -and -not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $tag)) "a pinned model whose tag was deleted is warned about, not downloaded and not an error (exit $($r.Code))"
    Invoke-LaiApi -Method POST -Uri "$OllamaUrl/api/copy" -Body @{ source = $BaseModel; destination = $tag } | Out-Null
    Assert-That ((Get-Digest $tag) -eq $original) 'setup for the next steps: the tag is back on the original'
    $r = Invoke-Update @('-Unpin', 'main') ''
    Assert-That ($r.Code -eq 0) 'unpin again: the steps below update this model'

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
    # The nightly re-check meets the same lock: it skips quietly (exit 0) and says why.
    $rs = Invoke-Update @('-Scheduled') ''
    if (-not $holder.HasExited) { $holder.Kill() }
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'already running') "a second update refuses while another holds the lock (exit $($r.Code))"
    $rec = Read-LaiState -Path (Join-Path $aiRoot 'model-recheck.json')
    Assert-That ($rs.Code -eq 0 -and [string]$rec['result'] -eq 'skipped' -and [string]$rec['reason'] -match 'another installer run or model update') "the nightly re-check skips instead (exit $($rs.Code), $($rec['result']): $($rec['reason']))"

    Write-Host "`n=== 5b. a finished run frees the setup lock, even while its window stays open ===" -ForegroundColor Cyan
    # The Start-menu shortcut runs the script inside a PowerShell that waits for Enter afterwards; a
    # mutex stays owned while its thread lives, so the script must release it itself (also on an error).
    $stayScript = Join-Path $Work 'stay-open.ps1'
    $stayReady = Join-Path $Work 'stay.ready'
    $lockFreeAfter = {
        param([string]$ScriptArgs)
        Remove-Item -LiteralPath $stayReady -Force -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $stayScript -Value ("try {{ & '{0}' -AIRoot '{1}' -SkipTests {2} }} catch {{ Write-Host `$_.Exception.Message }}; Set-Content -LiteralPath '{3}' -Value x; Start-Sleep -Seconds 60" -f (Join-Path $src 'Update-Models.ps1'), $aiRoot, $ScriptArgs, $stayReady)
        $stay = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $stayScript) -PassThru
        for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath $stayReady) -and -not $stay.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
        $free = $false
        if (Test-Path -LiteralPath $stayReady) { try { $l = Enter-LaiSetupLock; $free = $true; Exit-LaiVolumeLock $l } catch { $free = $false } }
        if (-not $stay.HasExited) { $stay.Kill() }
        return $free
    }
    Assert-That (& $lockFreeAfter '-RecheckOnly') 'after a -RecheckOnly run (nothing to re-check), another run can take the lock while the window is still open'
    Assert-That (& $lockFreeAfter '-Rollback main') 'also after a run that ended with an error (nothing to roll back)'
} finally {
    if ($holder -and -not $holder.HasExited) { $holder.Kill() }
    foreach ($n in @($tag, $variant, $prev, "$tag-prevnew", $alias)) { try { Remove-IfThere $n } catch { Write-Verbose "cleanup $n" } }
    $env:LOCALAI_TEST_CATALOG = ''
    $env:LOCALAI_TEST_CHATS_IN_FLIGHT = ''
    $env:LOCALAI_TEST_ALLOW_CPU = ''
}

if ($failures -eq 0) { Write-Host "`nMODEL UPDATE TEST PASSED" -ForegroundColor Green } else { Write-Host "`nMODEL UPDATE TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
