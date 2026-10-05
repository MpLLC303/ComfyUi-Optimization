<#
.SYNOPSIS
    Runs every test suite one after another against the sandbox and prints one summary table.

.DESCRIPTION
    The suites share one Ollama, one Open WebUI and one Docker engine: run side by side they unload
    each other's models and fight over the open-webui volume, and the failures look like product
    bugs. This runner serialises them and refuses to start while another run holds the lock.

    A suite passes only if it exits 0, prints its own PASSED banner (a suite that never ran, or died
    half-way with exit 0, has none), prints no ASSERT FAIL line, finishes within -TimeoutSec, and
    leaves nothing behind in the sandbox (tests/Reset-Sandbox.ps1 -Check; leftovers are then
    cleaned so the next suite starts clean). The sandbox is reset before the first suite.
    Each suite's full output goes to <LogDir>\<suite>.log; exit code = number of failed suites.
    -SelfTest proves each of those checks still catches its failure (no sandbox needed).

.EXAMPLE
    pwsh tests/Invoke-AllTests.ps1
    pwsh tests/Invoke-AllTests.ps1 -Only Static, Mock
#>
param(
    # Harness, Static, Unit, RenderGuard, Mock, ModelUpdate, UpdateWebUI, Uninstall, Watch, Integration, Acceptance
    [string[]]$Only = @(),
    [string]$LogDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'lai-alltests'),
    [string]$SplitterForSandbox = 'character',
    # Per suite; a hung suite is killed (with its child processes) and counted as failed.
    [int]$TimeoutSec = 1800,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $PSScriptRoot
$t = $PSScriptRoot
$script:VerdictPattern = '^\s*ASSERT FAIL|^(PARSE|NONASCII|PSSA|CANARY|PS51|FORMAT|MATCHES|BOUND|ENCODING|ELEVATED|NOSILENT|HELP|DOCPARAM|NATIVEQUOTE|COMPOSELOG|RECURSE|SETTINGS|HANG|HIDDENTASK|ENVFIRST|LOCATOR|MDTABLE|OLLAMAAPP|SERVERLOG|DRIFT|DEPSKIP|ENVRESTORE)\s'

function Invoke-Suite {
    # Runs one suite with stdout+stderr in order into its log, under a time limit. Linux/macOS only
    # (the sandbox runner): /bin/sh does the redirection, so a missing program is exit 127, not a
    # PowerShell error that would leave the previous suite's $LASTEXITCODE in place.
    param([hashtable]$Suite, [string]$Log, [int]$Limit)
    $exe = 'pwsh'; $argv = @('-NoProfile', '-File', $Suite.File)
    if ($Suite.ContainsKey('Exe')) { $exe = $Suite.Exe; $argv = @($Suite.File) }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = '/bin/sh'
    $psi.UseShellExecute = $false
    foreach ($a in @('-c', 'exec "$0" "$@" > "$LAI_SUITE_LOG" 2>&1', $exe) + $argv + @($Suite.Args)) { $psi.ArgumentList.Add([string]$a) }
    $psi.Environment['LAI_SUITE_LOG'] = $Log
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $timedOut = -not $p.WaitForExit($Limit * 1000)
    if ($timedOut) { $p.Kill($true); $p.WaitForExit(10000) | Out-Null }
    $sw.Stop()
    $code = if ($timedOut) { -1 } else { $p.ExitCode }
    $text = if (Test-Path -LiteralPath $Log) { Get-Content -LiteralPath $Log -Raw } else { '' }
    if ($null -eq $text) { $text = '' }
    # Only a suite's own verdict lines decide: an ASSERT FAIL at the start of a line, or a static-check
    # rule hit. Product output quoted by a passing test ('[FAIL] Test hook: ...') must not.
    $lines = @($text -split "`r?`n")
    $asserts = @($lines | Where-Object { $_ -match $script:VerdictPattern } | Select-Object -First 5 | ForEach-Object { $_.Trim() })
    $banner = $text -match $Suite.Pass
    $why = @()
    if ($timedOut) { $why += "timed out after $Limit s (killed with its child processes)" }
    elseif ($code -ne 0) { $why += "exit $code" }
    if (-not $timedOut -and -not $banner) { $why += "no '$($Suite.Pass)' banner in the log" }
    $why += $asserts
    if ($why.Count -and -not ($asserts.Count -or $timedOut) -and $code -ne 0) {
        # Exit code only: show the suite's own failure lines, else its last lines.
        $hint = @($lines | Where-Object { $_ -match '\[FAIL\]|FAILED' } | Select-Object -First 3 | ForEach-Object { $_.Trim() })
        if (-not $hint.Count) { $hint = @($lines | Where-Object { $_.Trim() } | Select-Object -Last 3 | ForEach-Object { $_.Trim() }) }
        $why += $hint
    }
    $result = 'PASS'
    if ($timedOut) { $result = 'TIMEOUT' } elseif ($why.Count) { $result = "FAIL ($code)" }
    return [pscustomobject]@{ Suite = $Suite.Name; Result = $result; Seconds = [int]$sw.Elapsed.TotalSeconds; Log = $Log; First = $why }
}

if ($SelfTest) {
    # Each fake suite is a way a broken suite could slip through as PASS.
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('lai-runner-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $pidFile = Join-Path $dir 'child.pid'
    $fakes = @(
        @{ Name = 'missing-exe'; Exe = 'lai-no-such-program'; Body = $null; Want = 'FAIL'; Why = 'program not installed' }
        @{ Name = 'assert-fail-exit-0'; Body = "Write-Host '  ASSERT FAIL something'; Write-Host 'FAKE PASSED'; exit 0"; Want = 'FAIL'; Why = 'a failed assertion despite exit 0 and banner' }
        @{ Name = 'rule-hit-exit-0'; Body = "Write-Host 'HELP     X.ps1:3 parameter -Y is not documented'; Write-Host 'FAKE PASSED'; exit 0"; Want = 'FAIL'; Why = 'a static-check rule hit despite exit 0 and banner' }
        @{ Name = 'quoted-product-fail'; Body = "Write-Host '12:00:00 [FAIL] Test hook: stage Ollama failed'; Write-Host '    | 12:00:01 [FAIL] Docker is not running'; Write-Host '  ASSERT OK   it failed as intended'; Write-Host 'FAKE PASSED'; exit 0"; Want = 'PASS'; Why = 'product [FAIL] output quoted by a passing test' }
        @{ Name = 'no-banner'; Body = 'exit 0'; Want = 'FAIL'; Why = 'exit 0 without its banner' }
        @{ Name = 'exit-code'; Body = "Write-Host 'FAKE PASSED'; exit 3"; Want = 'FAIL'; Why = 'banner but exit 3' }
        @{ Name = 'hang'; Exe = '/bin/sh'; Body = "sleep 300 &`necho `$! > '$pidFile'`nwait"; Ext = '.sh'; Want = 'TIMEOUT'; Why = 'hangs with a child process' }
        @{ Name = 'good'; Body = "Write-Host 'FAKE PASSED'; exit 0"; Want = 'PASS'; Why = 'a passing suite still passes' }
    )
    $bad = 0
    foreach ($f in $fakes) {
        $file = Join-Path $dir ($f.Name + $(if ($f.Ext) { $f.Ext } else { '.ps1' }))
        if ($null -ne $f.Body) { Set-Content -LiteralPath $file -Value $f.Body }
        $suite = @{ Name = $f.Name; File = $file; Args = @(); Pass = 'FAKE PASSED' }
        if ($f.Exe) { $suite.Exe = $f.Exe }
        # A cold pwsh start can take several seconds on CI: only the hang gets a short limit.
        $r = Invoke-Suite -Suite $suite -Log (Join-Path $dir ($f.Name + '.log')) -Limit $(if ($f.Name -eq 'hang') { 4 } else { 60 })
        $ok = $r.Result -like "$($f.Want)*"
        if ($f.Name -eq 'hang') {
            $childPid = 0
            if (Test-Path -LiteralPath $pidFile) { $childPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim() }
            # SIGKILL is asynchronous, and the orphan stays a zombie until init reaps it.
            $alive = $true
            for ($i = 0; $i -lt 50 -and $alive; $i++) {
                $stat = ''
                try { $stat = Get-Content -LiteralPath "/proc/$childPid/stat" -Raw -ErrorAction Stop } catch { $stat = '' }
                $alive = $childPid -and $stat -and $stat -notmatch '^\d+ \(.*\) [ZX] '
                if ($alive) { Start-Sleep -Milliseconds 100 }
            }
            $ok = $ok -and $childPid -and -not $alive -and $r.Seconds -lt 15
            if ($alive) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
        }
        if ($ok) { Write-Host ("  ASSERT OK   {0}: {1} -> {2}" -f $f.Name, $f.Why, $r.Result) -ForegroundColor Green }
        else { Write-Host ("  ASSERT FAIL {0}: {1} -> {2} (wanted {3}) {4}" -f $f.Name, $f.Why, $r.Result, $f.Want, ($r.First -join ' | ')) -ForegroundColor Red; $bad++ }
    }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    if ($bad) { Write-Host "`nHARNESS SELF-TEST FAILED ($bad)" -ForegroundColor Red } else { Write-Host "`nHARNESS SELF-TEST PASSED" -ForegroundColor Green }
    exit $bad
}

$suites = @(
    @{ Name = 'Harness'; File = $PSCommandPath; Args = @('-SelfTest'); Pass = 'HARNESS SELF-TEST PASSED' }
    @{ Name = 'Static'; File = (Join-Path $t 'Invoke-StaticChecks.ps1'); Args = @(); Pass = 'Static checks: \d+ files, 0 problem' }
    @{ Name = 'Unit'; File = (Join-Path $t 'Invoke-WindowsUnitTests.ps1'); Args = @(); Pass = 'WINDOWS UNIT TESTS PASSED' }
    @{ Name = 'RenderGuard'; Exe = 'python3'; File = (Join-Path $t 'test_render_guard.py'); Args = @(); Pass = 'RENDER GUARD TEST PASSED' }
    @{ Name = 'Mock'; File = (Join-Path $t 'Invoke-InstallerMockRun.ps1'); Args = @(); Pass = 'MOCK RUN PASSED' }
    @{ Name = 'ModelUpdate'; File = (Join-Path $t 'Invoke-ModelUpdateTest.ps1'); Args = @(); Pass = 'MODEL UPDATE TEST PASSED' }
    @{ Name = 'UpdateWebUI'; File = (Join-Path $t 'Invoke-UpdateWebUITest.ps1'); Args = @(); Pass = 'UPDATE WEBUI TEST PASSED' }
    @{ Name = 'Uninstall'; File = (Join-Path $t 'Invoke-UninstallTest.ps1'); Args = @(); Pass = 'UNINSTALL TEST PASSED' }
    @{ Name = 'Watch'; File = (Join-Path $t 'Invoke-WatchTest.ps1'); Args = @(); Pass = 'WATCH TEST PASSED' }
    @{ Name = 'Integration'; File = (Join-Path $t 'Invoke-IntegrationTest.ps1'); Args = @('-SandboxTextSplitter', $SplitterForSandbox); Pass = 'INTEGRATION TEST PASSED' }
    @{ Name = 'Acceptance'; File = (Join-Path $src 'Test-LocalAI.ps1'); Args = @('-AIRoot', (Join-Path $LogDir 'acceptance-root'), '-CatalogPath', (Join-Path $t 'models.test.psd1'), '-NoContainers'); Pass = 'V1 COMPLETE' }
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

# The acceptance checklist reads an install root: give it the sandbox admin login, the sandbox's
# Open WebUI -> Ollama URL (so its connection check really probes) and a fresh backup.
$acc = Join-Path $LogDir 'acceptance-root'
foreach ($d in 'Secrets', 'Backups') { New-Item -ItemType Directory -Force -Path (Join-Path $acc $d) | Out-Null }
ConvertTo-Json @{ email = 'admin@localhost'; password = 'Test-Password-123' } | Set-Content -LiteralPath (Join-Path $acc 'Secrets/openwebui-admin.json')
ConvertTo-Json @{ WebUIOllamaUrl = 'http://127.0.0.1:11434' } | Set-Content -LiteralPath (Join-Path $acc 'localai-config.json')
Get-ChildItem -LiteralPath (Join-Path $acc 'Backups') -Filter 'open-webui-*' | Remove-Item -Force
Set-Content -LiteralPath (Join-Path $acc ('Backups/open-webui-{0}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Value 'stand-in'

$reset = Join-Path $t 'Reset-Sandbox.ps1'
$needsSandbox = @($suites | Where-Object { @('Harness', 'Static', 'Unit', 'RenderGuard') -notcontains $_.Name }).Count -gt 0
$results = @()
try {
    if ($needsSandbox) {
        # Whatever a killed earlier run left behind (containers that restart on their own, a renamed
        # SearXNG, a changed admin password) would fail - or falsely pass - the first suites.
        Write-Host 'Sandbox      resetting...' -ForegroundColor Cyan
        & pwsh -NoProfile -File $reset *> (Join-Path $LogDir 'sandbox-reset.log')
        if ($LASTEXITCODE -ne 0) { Get-Content -LiteralPath (Join-Path $LogDir 'sandbox-reset.log') | ForEach-Object { Write-Host "             $_" -ForegroundColor Red } }
    }
    foreach ($s in $suites) {
        Write-Host ("{0,-12} running..." -f $s.Name) -ForegroundColor Cyan
        $r = Invoke-Suite -Suite $s -Log (Join-Path $LogDir ($s.Name + '.log')) -Limit $TimeoutSec
        if ($needsSandbox) {
            # A suite that leaves something behind fails, even if its own checks passed.
            $leakLog = Join-Path $LogDir ($s.Name + '.leaks.log')
            & pwsh -NoProfile -File $reset -Check -SkipWebUI -LeftoversOnly *> $leakLog
            if ($LASTEXITCODE -ne 0) {
                $r.First = @($r.First) + @(Get-Content -LiteralPath $leakLog | Where-Object { $_ -match 'LEFTOVER|MISSING' } | ForEach-Object { 'left behind: ' + $_.Trim() })
                if ($r.Result -eq 'PASS') { $r.Result = 'FAIL (leak)' }
                & pwsh -NoProfile -File $reset -SkipWebUI *>> $leakLog
            }
        }
        $results += $r
        Write-Host ("{0,-12} {1,-12} {2,5} s" -f $r.Suite, $r.Result, $r.Seconds) -ForegroundColor $(if ($r.Result -eq 'PASS') { 'Green' } else { 'Red' })
        if ($r.Result -ne 'PASS') { $r.First | ForEach-Object { Write-Host "             $_" -ForegroundColor Red } }
    }
    if ($needsSandbox) {
        # Also the shared Open WebUI state (admin password, Ollama connection), once: each check costs a sign-in.
        $endLog = Join-Path $LogDir 'sandbox-final.log'
        & pwsh -NoProfile -File $reset -Check *> $endLog
        $ok = $LASTEXITCODE -eq 0
        $results += [pscustomobject]@{ Suite = 'Sandbox'; Result = $(if ($ok) { 'PASS' } else { 'FAIL (leak)' }); Seconds = 0; Log = $endLog; First = @(Get-Content -LiteralPath $endLog | Where-Object { $_ -match 'LEFTOVER|MISSING' }) }
        Write-Host ("{0,-12} {1,-12}" -f 'Sandbox', $results[-1].Result) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        if (-not $ok) { $results[-1].First | ForEach-Object { Write-Host "             $_" -ForegroundColor Red }; & pwsh -NoProfile -File $reset *>> $endLog }
    }
} finally {
    $lock.Dispose()
}

$failed = @($results | Where-Object { $_.Result -ne 'PASS' })
$total = 0; foreach ($r in $results) { $total += $r.Seconds }
Write-Host ''
Write-Host ("{0} suite(s), {1} failed, {2} s total. Logs: {3}" -f $results.Count, $failed.Count, $total, $LogDir) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
exit $failed.Count
