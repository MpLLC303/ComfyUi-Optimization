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

    Write-Host "`n=== 4. -DropPrevious ===" -ForegroundColor Cyan
    Invoke-Update @() $variant | Out-Null
    Assert-That (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $prev) '-prev kept again after another re-publish'
    $r = Invoke-Update @('-DropPrevious') ''
    Assert-That ($r.Code -eq 0 -and -not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $prev)) '-DropPrevious deletes it'
} finally {
    foreach ($n in @($tag, $variant, $prev, "$tag-prevnew", $alias)) { try { Remove-IfThere $n } catch { Write-Verbose "cleanup $n" } }
    $env:LOCALAI_TEST_CATALOG = ''
}

if ($failures -eq 0) { Write-Host "`nMODEL UPDATE TEST PASSED" -ForegroundColor Green } else { Write-Host "`nMODEL UPDATE TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
