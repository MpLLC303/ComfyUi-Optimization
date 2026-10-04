<#
.SYNOPSIS
    Runs every test suite one after another against the sandbox and prints one summary table.

.DESCRIPTION
    The suites share one Ollama, one Open WebUI and one Docker engine: run side by side they unload
    each other's models and fight over the open-webui volume, and the failures look like product
    bugs. This runner serialises them and refuses to start while another run holds the lock.
    Each suite's full output goes to <LogDir>\<suite>.log; exit code = number of failed suites.

.EXAMPLE
    pwsh tests/Invoke-AllTests.ps1
    pwsh tests/Invoke-AllTests.ps1 -Only Static, Mock
#>
param(
    # Static, Unit, RenderGuard, Mock, ModelUpdate, UpdateWebUI, Uninstall, Watch, Integration, Acceptance
    [string[]]$Only = @(),
    [string]$LogDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'lai-alltests'),
    [string]$SplitterForSandbox = 'character'
)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $PSScriptRoot
$t = $PSScriptRoot
$suites = @(
    @{ Name = 'Static'; File = (Join-Path $t 'Invoke-StaticChecks.ps1'); Args = @() }
    @{ Name = 'Unit'; File = (Join-Path $t 'Invoke-WindowsUnitTests.ps1'); Args = @() }
    @{ Name = 'RenderGuard'; Exe = 'python3'; File = (Join-Path $t 'test_render_guard.py'); Args = @() }
    @{ Name = 'Mock'; File = (Join-Path $t 'Invoke-InstallerMockRun.ps1'); Args = @() }
    @{ Name = 'ModelUpdate'; File = (Join-Path $t 'Invoke-ModelUpdateTest.ps1'); Args = @() }
    @{ Name = 'UpdateWebUI'; File = (Join-Path $t 'Invoke-UpdateWebUITest.ps1'); Args = @() }
    @{ Name = 'Uninstall'; File = (Join-Path $t 'Invoke-UninstallTest.ps1'); Args = @() }
    @{ Name = 'Watch'; File = (Join-Path $t 'Invoke-WatchTest.ps1'); Args = @() }
    @{ Name = 'Integration'; File = (Join-Path $t 'Invoke-IntegrationTest.ps1'); Args = @('-SandboxTextSplitter', $SplitterForSandbox) }
    @{ Name = 'Acceptance'; File = (Join-Path $src 'Test-LocalAI.ps1'); Args = @('-AIRoot', (Join-Path $LogDir 'acceptance-root'), '-CatalogPath', (Join-Path $t 'models.test.psd1'), '-NoContainers') }
)
# 'pwsh -File' hands "Static,Mock" over as one string, so split here (and validate by hand).
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$unknown = @($Only | Where-Object { @($suites | ForEach-Object { $_.Name }) -notcontains $_ })
if ($unknown.Count) { Write-Host "Unknown suite(s): $($unknown -join ', '). Known: $(($suites | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Red; exit 100 }
# The acceptance checklist needs the sandbox settings the integration test applies (character
# splitter, host SearXNG URL); the mock run's installer replaces them with the production ones.
if ($Only -contains 'Acceptance' -and $Only -notcontains 'Integration') {
    $Only += 'Integration'
    Write-Host 'Acceptance needs the sandbox settings from Integration: running that first.' -ForegroundColor Yellow
}
if ($Only.Count) { $suites = @($suites | Where-Object { $Only -contains $_.Name }) }

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
# An exclusive handle on the lock file: a second runner fails to open it until this one exits
# (the OS releases it even if this process is killed).
# Fixed path (not under -LogDir): the shared resource is the sandbox, whatever the log folder.
$lockPath = Join-Path ([System.IO.Path]::GetTempPath()) 'lai-alltests.lock'
try { $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
catch { Write-Host "Another test run holds $lockPath; wait for it to finish." -ForegroundColor Red; exit 100 }

# The acceptance checklist reads an install root: give it the sandbox admin login and a fresh backup.
$acc = Join-Path $LogDir 'acceptance-root'
foreach ($d in 'Secrets', 'Backups') { New-Item -ItemType Directory -Force -Path (Join-Path $acc $d) | Out-Null }
ConvertTo-Json @{ email = 'admin@localhost'; password = 'Test-Password-123' } | Set-Content -LiteralPath (Join-Path $acc 'Secrets/openwebui-admin.json')
Get-ChildItem -LiteralPath (Join-Path $acc 'Backups') -Filter 'open-webui-*' | Remove-Item -Force
Set-Content -LiteralPath (Join-Path $acc ('Backups/open-webui-{0}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Value 'stand-in'

$results = @()
try {
    foreach ($s in $suites) {
        $log = Join-Path $LogDir ($s.Name + '.log')
        Write-Host ("{0,-12} running..." -f $s.Name) -ForegroundColor Cyan
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        if ($s.ContainsKey('Exe')) { & $s.Exe $s.File @($s.Args) *> $log }
        else { & pwsh -NoProfile -File $s.File @($s.Args) *> $log }
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        $sw.Stop()
        $fails = @(Select-String -LiteralPath $log -Pattern 'ASSERT FAIL|\[FAIL\]|^\s*FAIL |^PARSE|^NONASCII|^PSSA|^CANARY|^PS51|^FORMAT|^MATCHES|^BOUND' | Select-Object -First 5 | ForEach-Object { $_.Line.Trim() })
        if ($code -ne 0 -and -not $fails.Count) { $fails = @(Get-Content -LiteralPath $log -Tail 4 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
        $results += [pscustomobject]@{ Suite = $s.Name; Result = $(if ($code -eq 0) { 'PASS' } else { "FAIL ($code)" }); Seconds = [int]$sw.Elapsed.TotalSeconds; Log = $log; First = $fails }
        Write-Host ("{0,-12} {1,-10} {2,5} s" -f $s.Name, $results[-1].Result, $results[-1].Seconds) -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Red' })
        if ($code -ne 0) { $fails | ForEach-Object { Write-Host "             $_" -ForegroundColor Red } }
    }
} finally {
    $lock.Dispose()
}

$failed = @($results | Where-Object { $_.Result -ne 'PASS' })
$total = 0; foreach ($r in $results) { $total += $r.Seconds }
Write-Host ''
Write-Host ("{0} suite(s), {1} failed, {2} s total. Logs: {3}" -f $results.Count, $failed.Count, $total, $LogDir) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
exit $failed.Count
