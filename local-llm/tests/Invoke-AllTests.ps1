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

    Under CI (GitHub Actions sets GITHUB_ACTIONS to 'true') a suite also fails for every block it
    skipped: a test that did not run proves nothing, and a block that runs on one system only would
    drop out unseen the day the runner changes. The only skips allowed there are the ones the
    workflow job declares in LAI_DECLARED_SKIPS, one skip message per line, exactly as the suite
    prints it. Outside CI a skip stays what it was: a grey line.

    -Step runs one suite file with that check and the one for the PASSED banner, and nothing else
    (no sandbox reset, no lock, no log file): the CI workflows start each of their suite steps
    through it. The suite's output is shown as it comes and its exit code is kept; when that is 0,
    the exit code is the number of skips the job has not declared, plus one when the suite did not
    print its PASSED banner (it stopped before its end). The banner is asked for under CI and
    outside it, of every suite file this runner has a banner for: the suites of the full run and
    the stack smoke test, by file name. The step ends when the suite does, also when a helper
    process the suite left running still holds its output open (the workflow's next step, 'Nothing
    left behind', is there to name that helper). It also runs on Windows PowerShell 5.1 (the
    Windows job).

.EXAMPLE
    pwsh tests/Invoke-AllTests.ps1
    pwsh tests/Invoke-AllTests.ps1 -Only Static, Mock
.EXAMPLE
    & ./tests/Invoke-AllTests.ps1 -Step ./tests/Invoke-WatchTest.ps1 -StepArgs '-Work', '/tmp/watch-test'
    One suite file with its own arguments, as a CI workflow step runs it. Typed in a PowerShell
    session, not started as 'pwsh tests/Invoke-AllTests.ps1 ...': see -StepArgs.
.EXAMPLE
    pwsh tests/Invoke-AllTests.ps1 -Since origin/main
    Only the suites a change since that git ref can affect: the suites whose test file names a changed
    script (or, for the installer's own scripts, the mock run), every suite for shared code (lib,
    config, the compose file, the sandbox reset) or a file no suite names, and Static always. A quick
    check while working; the full run still decides before main moves.
#>
param(
    # Harness, Static, Unit, Bootstrap, RenderGuard, Mock, ModelUpdate, UpdateWebUI, Uninstall, Watch, Integration, Acceptance
    [string[]]$Only = @(),
    # A git ref (e.g. origin/main): run only the suites the changes since then can affect.
    [string]$Since = '',
    [string]$LogDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'lai-alltests'),
    [string]$SplitterForSandbox = 'character',
    # Per suite; a hung suite is killed (with its child processes) and counted as failed.
    [int]$TimeoutSec = 1800,
    [switch]$SelfTest,
    # One suite file, run the way a CI workflow step runs it (see the description).
    [string]$Step = '',
    # That suite's own arguments, e.g. '-Work', '/tmp/watch-test'. Only from a PowerShell session
    # (& ./tests/Invoke-AllTests.ps1 -Step ... -StepArgs '-Work', '/tmp/watch-test'): started as
    # 'pwsh tests/Invoke-AllTests.ps1 ...' (pwsh -File), a value that begins with '-' is read as a
    # parameter of this runner, and the run stops before any suite starts.
    [string[]]$StepArgs = @()
)
$ErrorActionPreference = 'Stop'
# Refuses to run anywhere but a throwaway test machine (it would delete a real install's data).
if (-not (& (Join-Path $PSScriptRoot 'Assert-LaiSandbox.ps1'))) { exit 99 }
$src = Split-Path -Parent $PSScriptRoot
$t = $PSScriptRoot
$script:VerdictPattern = '^\s*ASSERT FAIL|^(PARSE|NONASCII|PSSA|CANARY|PS51|FORMAT|MATCHES|BOUND|ENCODING|ELEVATED|NOSILENT|HELP|DOCPARAM|NATIVEQUOTE|COMPOSELOG|COMPOSESEC|RECURSE|SETTINGS|HANG|HIDDENTASK|ENVFIRST|LOCATOR|MDTABLE|OLLAMAAPP|SERVERLOG|DRIFT|DEPSKIP|ENVRESTORE|NETCATCH|INSTEXIT)\s'

function Invoke-Suite {
    # Runs one suite with stdout+stderr in order into its log, under a time limit. Linux/macOS only
    # (the sandbox runner): /bin/sh does the redirection, so a missing program is exit 127, not a
    # PowerShell error that would leave the previous suite's $LASTEXITCODE in place.
    # -CI and -Declared: see Get-SkipProblem (the self-test passes both, whatever machine it runs on).
    param([hashtable]$Suite, [string]$Log, [int]$Limit, [bool]$CI, [string[]]$Declared = @())
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
    # Under CI a block the suite skipped fails it, exit 0 and banner or not.
    $why += @(Get-SkipProblem -Lines $lines -Declared $Declared -CI $CI)
    $result = 'PASS'
    if ($timedOut) { $result = 'TIMEOUT' } elseif ($why.Count) { $result = "FAIL ($code)" }
    return [pscustomobject]@{ Suite = $Suite.Name; Result = $result; Seconds = [int]$sw.Elapsed.TotalSeconds; Log = $Log; First = $why }
}

# A suite's own skip lines, in the four shapes the suites print them:
#   '  SKIP        <why>'           Skip in the unit and bootstrap tests, the mock run
#   'HH:mm:ss [WARN] SKIP <why>'    the integration test
#   '  (skipped: <why>)'            the uninstall test
#   '<why>; skipped.'               the static checks without PSScriptAnalyzer
# Matched case-sensitively, at the start of a line. Never the product's own verdict
# ('HH:mm:ss [INFO] SKIP <check>: ...' from Test-LocalAI and Test-PCSecurity, also behind the mock
# run's '    | '), which a passing test may print or quote.
$script:SkipPattern = '^\s*SKIP\s*$|^\s*SKIP\s+(?<what>\S.*)$|^\d\d:\d\d:\d\d \[WARN\] SKIP (?<what>\S.*)$|^\s*\(skipped: (?<what>.+)\)\s*$|^(?<what>(?!\d\d:\d\d:\d\d )\S.*); skipped\.\s*$'
# Read here and nowhere else: GitHub Actions sets GITHUB_ACTIONS to 'true'; the workflow job lists the
# skips that are right for it in LAI_DECLARED_SKIPS, one message (the <why> above) per line.
$inCI = ($env:GITHUB_ACTIONS -eq 'true')
$declaredSkips = @("$env:LAI_DECLARED_SKIPS" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Get-SkipProblem {
    # One line per skip in a suite's output that the job has not declared. Nothing outside CI: on a
    # developer's machine a skip stays a grey line.
    param([string[]]$Lines = @(), [string[]]$Declared = @(), [bool]$CI)
    $found = @()
    if (-not $CI) { return $found }
    foreach ($line in $Lines) {
        # Colour codes, should a PowerShell ever write them into redirected output, must not hide a skip.
        if (($line -replace '\x1b\[[0-9;]*m', '') -cmatch $script:SkipPattern) {
            $what = ([string]$Matches['what']).Trim()
            # A skip that gives no reason cannot be declared: it always fails.
            if (-not $what) { $found += 'ASSERT FAIL skipped under CI without a reason: a skip must say what did not run and why' }
            elseif ($Declared -cnotcontains $what) { $found += "ASSERT FAIL skipped under CI, not declared for this job: $what" }
        }
    }
    return $found
}

function ConvertTo-StepArg {
    # One argument for a process command line, the way CommandLineToArgvW and powershell.exe read
    # it back (.NET on Linux splits ProcessStartInfo.Arguments by the same rules). Quoted only when
    # it has to be (empty, a space, a quote); backslashes before a quote are then doubled, so a
    # path with a space and a trailing backslash arrives whole. The rules of ConvertTo-LaiCmdArg
    # in lib/LocalAI.psm1, which this runner does not load.
    param([string]$Value)
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]'\') { $slashes++; continue }
        if ($ch -eq [char]'"') { [void]$sb.Append('\', 2 * $slashes + 1); [void]$sb.Append('"') }
        else { [void]$sb.Append('\', $slashes); [void]$sb.Append($ch) }
        $slashes = 0
    }
    [void]$sb.Append('\', 2 * $slashes)
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-Step {
    # Runs one suite file the way a CI workflow step does: in a child PowerShell of the edition that
    # runs this script (Windows PowerShell 5.1 on the Windows job), its output shown line by line as
    # it comes (a suite takes up to half an hour, and a job cut off at its time limit must still
    # show how far it got), its exit code kept. Problems = the skips the job has not declared.
    # NoBanner = the suite ended with exit 0 and its output has no line that fits -Pass (the suite's
    # PASSED banner, a pattern as in the suite table), so it stopped before its end. Never set
    # without -Pass, and never after another exit code, which is the failure already.
    # The step ends when the suite's process does, not when its output pipes close. A helper the
    # suite left running (a lock holder, a fake server) has inherited those pipes, and a pipeline
    # (& $exe 2>&1 | ...) returns only when their last holder is gone: minutes later, when the
    # workflow's 'Nothing left behind' step finds nothing left to name, or never. What the suite
    # wrote is still read to the end: the pipes get -GraceSec after the exit, as in
    # Invoke-LaiTimedNative. HeldOpen = they were still open after that.
    param([string]$File, [string[]]$Arguments = @(), [string[]]$Declared = @(), [bool]$CI, [switch]$Quiet, [int]$GraceSec = 5, [string]$Pass = '')
    $exe = 'pwsh'
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $exe = 'powershell.exe' }
    $argv = @('-NoProfile', '-File', $File) + @($Arguments | Where-Object { $_ })
    $show = -not $Quiet
    $out = New-Object System.Collections.Generic.List[string]
    $code = 127; $held = $false
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    # One command-line string, not ArgumentList: Windows PowerShell 5.1 does not have that.
    $psi.Arguments = (@($argv | ForEach-Object { ConvertTo-StepArg ([string]$_) }) -join ' ')
    $psi.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = $null
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch {
        # No such program: said in the output, and the exit code stays 127 (what a shell gives).
        $out.Add("$exe could not be started: $($_.Exception.Message)")
        if ($show) { Write-Host $out[0] -ForegroundColor Red }
    }
    if ($p) {
        # Both pipes are polled, one pending line each, so that this loop also sees the process end.
        $readers = @($p.StandardOutput, $p.StandardError)
        $pending = @($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
        $sinceExit = $null
        while ($pending[0] -or $pending[1]) {
            $got = $false
            for ($i = 0; $i -lt 2; $i++) {
                # At most 500 lines of one pipe in a row: a helper that floods it after the suite
                # has ended must not keep this loop from looking at the exit below.
                for ($n = 0; $n -lt 500 -and $pending[$i] -and $pending[$i].IsCompleted; $n++) {
                    $line = $null
                    if ($pending[$i].Status -eq 'RanToCompletion') { $line = $pending[$i].Result }
                    if ($null -eq $line) { $pending[$i] = $null; break }   # this pipe is closed
                    $got = $true
                    $out.Add($line)
                    if ($show) { Write-Host $line }
                    $pending[$i] = $readers[$i].ReadLineAsync()
                }
            }
            if ($p.HasExited) {
                if ($null -eq $sinceExit) { $sinceExit = [System.Diagnostics.Stopwatch]::StartNew() }
                elseif ($sinceExit.Elapsed.TotalSeconds -ge $GraceSec) { $held = $true; break }
            }
            if (-not $got) { Start-Sleep -Milliseconds 50 }
        }
        # Both pipes closed while the suite still runs: wait for the suite itself.
        if (-not $p.HasExited) { $p.WaitForExit() }
        $code = $p.ExitCode
        if ($held -and $show) { Write-Host 'The suite has ended, but something it started still holds its output open (a helper process left running?). Not waiting for it: the step ends with the suite.' -ForegroundColor Yellow }
    }
    $noBanner = $false
    if ($Pass -and $code -eq 0) { $noBanner = (($out.ToArray() -join "`n") -notmatch $Pass) }
    return [pscustomobject]@{ Code = $code; HeldOpen = $held; NoBanner = $noBanner; Problems = @(Get-SkipProblem -Lines ($out.ToArray()) -Declared $Declared -CI $CI) }
}

$suites = @(
    @{ Name = 'Harness'; File = $PSCommandPath; Args = @('-SelfTest'); Pass = 'HARNESS SELF-TEST PASSED' }
    @{ Name = 'Static'; File = (Join-Path $t 'Invoke-StaticChecks.ps1'); Args = @(); Pass = 'Static checks: \d+ files, 0 problem' }
    @{ Name = 'Unit'; File = (Join-Path $t 'Invoke-WindowsUnitTests.ps1'); Args = @(); Pass = 'WINDOWS UNIT TESTS PASSED' }
    @{ Name = 'Bootstrap'; File = (Join-Path $t 'Invoke-GetLocalAITest.ps1'); Args = @(); Pass = 'GET-LOCALAI TEST PASSED' }
    @{ Name = 'RenderGuard'; Exe = 'python3'; File = (Join-Path $t 'test_render_guard.py'); Args = @(); Pass = 'RENDER GUARD TEST PASSED' }
    @{ Name = 'Mock'; File = (Join-Path $t 'Invoke-InstallerMockRun.ps1'); Args = @(); Pass = 'MOCK RUN PASSED' }
    @{ Name = 'ModelUpdate'; File = (Join-Path $t 'Invoke-ModelUpdateTest.ps1'); Args = @(); Pass = 'MODEL UPDATE TEST PASSED' }
    @{ Name = 'UpdateWebUI'; File = (Join-Path $t 'Invoke-UpdateWebUITest.ps1'); Args = @(); Pass = 'UPDATE WEBUI TEST PASSED' }
    @{ Name = 'Uninstall'; File = (Join-Path $t 'Invoke-UninstallTest.ps1'); Args = @(); Pass = 'UNINSTALL TEST PASSED' }
    @{ Name = 'Watch'; File = (Join-Path $t 'Invoke-WatchTest.ps1'); Args = @(); Pass = 'WATCH TEST PASSED' }
    @{ Name = 'Integration'; File = (Join-Path $t 'Invoke-IntegrationTest.ps1'); Args = @('-SandboxTextSplitter', $SplitterForSandbox); Pass = 'INTEGRATION TEST PASSED' }
    @{ Name = 'Acceptance'; File = (Join-Path $src 'Test-LocalAI.ps1'); Args = @('-AIRoot', (Join-Path $LogDir 'acceptance-root'), '-CatalogPath', (Join-Path $t 'models.test.psd1'), '-NoContainers'); Pass = 'V1 COMPLETE' }
)
# The suites only a CI job runs, through -Step, each with the banner it prints at its end. The stack
# smoke test starts the production stack under its fixed container names, so it needs a Docker
# engine of its own and cannot be in the table above. The full run never starts these.
$stepOnlySuites = @(
    @{ Name = 'StackSmoke'; File = (Join-Path $t 'Invoke-StackSmokeTest.ps1'); Pass = 'STACK SMOKE TEST PASSED' }
)

function Get-StepBanner {
    # The PASSED banner (a pattern) that -Step asks of a suite file: that of the suite with the same
    # file name. '' for a file that is no suite of this toolkit (a made-up suite in a check of -Step
    # itself): there is nothing to ask of it.
    param([string]$File, [object[]]$Suites)
    $leaf = Split-Path -Leaf $File
    foreach ($su in $Suites) { if ((Split-Path -Leaf $su.File) -eq $leaf) { return [string]$su.Pass } }
    return ''
}

function Get-SuitesForChange {
    # Suite names (in run order) that changed files can affect. Paths are relative to local-llm.
    param([string[]]$Files, [object[]]$Suites, [string]$Root)
    $all = @($Suites | ForEach-Object { $_.Name })
    $pick = @('Static')
    $texts = @{}
    # Not this runner itself: its self-test names scripts as data.
    foreach ($su in $Suites) { if ($su.Name -ne 'Harness' -and $su.File -match '\.ps1$' -and (Test-Path -LiteralPath $su.File)) { $texts[$su.Name] = Get-Content -LiteralPath $su.File -Raw } }
    $installer = ''; $ip = Join-Path $Root 'Install-LocalAI.ps1'; if (Test-Path -LiteralPath $ip) { $installer = Get-Content -LiteralPath $ip -Raw }
    foreach ($f in @($Files | ForEach-Object { ($_ -replace '\\', '/').Trim() } | Where-Object { $_ })) {
        # Shared by every suite: no narrower answer is safe.
        if ($f -match '^(lib/|config/|stack/docker-compose\.yml$|stack/searxng/|stack/openwebui-tools/|tests/Reset-Sandbox\.ps1$|tests/models\.test\.psd1$)') { return $all }
        if ($f -match '\.md$') { continue }   # documentation: the static checks read it
        if ($f -eq 'tests/Invoke-AllTests.ps1') { $pick += 'Harness'; continue }
        if ($f -like 'stack/render-guard/*' -or $f -eq 'tests/test_render_guard.py') { $pick += @('RenderGuard', 'Mock'); continue }
        $leaf = Split-Path -Leaf $f
        $hit = @($Suites | Where-Object { (Split-Path -Leaf $_.File) -eq $leaf } | ForEach-Object { $_.Name })
        $hit += @($texts.Keys | Where-Object { $texts[$_] -match [regex]::Escape($leaf) })
        if ($installer -and $leaf -ne 'Install-LocalAI.ps1' -and $installer -match [regex]::Escape($leaf)) { $hit += 'Mock' }
        if (@($hit | Where-Object { $_ -ne 'Static' }).Count -eq 0) { return $all }   # nothing names it: unknown reach
        $pick += $hit
    }
    return @($all | Where-Object { $pick -contains $_ })
}

if ($SelfTest) {
    # Each fake suite is a way a broken suite could slip through as PASS.
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('lai-runner-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $pidFile = Join-Path $dir 'child.pid'
    $skipWhy = 'fake block runs on another system only'
    $skipBody = "Write-Host '  SKIP        $skipWhy'; Write-Host 'FAKE PASSED'; exit 0"
    $fakes = @(
        @{ Name = 'missing-exe'; Exe = 'lai-no-such-program'; Body = $null; Want = 'FAIL'; Why = 'program not installed' }
        @{ Name = 'assert-fail-exit-0'; Body = "Write-Host '  ASSERT FAIL something'; Write-Host 'FAKE PASSED'; exit 0"; Want = 'FAIL'; Why = 'a failed assertion despite exit 0 and banner' }
        @{ Name = 'rule-hit-exit-0'; Body = "Write-Host 'HELP     X.ps1:3 parameter -Y is not documented'; Write-Host 'FAKE PASSED'; exit 0"; Want = 'FAIL'; Why = 'a static-check rule hit despite exit 0 and banner' }
        @{ Name = 'quoted-product-fail'; Body = "Write-Host '12:00:00 [FAIL] Test hook: stage Ollama failed'; Write-Host '    | 12:00:01 [FAIL] Docker is not running'; Write-Host '  ASSERT OK   it failed as intended'; Write-Host 'FAKE PASSED'; exit 0"; Want = 'PASS'; Why = 'product [FAIL] output quoted by a passing test' }
        @{ Name = 'no-banner'; Body = 'exit 0'; Want = 'FAIL'; Why = 'exit 0 without its banner' }
        @{ Name = 'exit-code'; Body = "Write-Host 'FAKE PASSED'; exit 3"; Want = 'FAIL'; Why = 'banner but exit 3' }
        @{ Name = 'hang'; Exe = '/bin/sh'; Body = "sleep 300 &`necho `$! > '$pidFile'`nwait"; Ext = '.sh'; Want = 'TIMEOUT'; Why = 'hangs with a child process' }
        @{ Name = 'good'; Body = "Write-Host 'FAKE PASSED'; exit 0"; Want = 'PASS'; Why = 'a passing suite still passes' }
        # A skipped block. CI is handed to each fake (never read from this machine), so the same
        # cases hold on a developer's sandbox and in the CI job that runs this self-test.
        @{ Name = 'skip-in-ci'; Body = $skipBody; CI = $true; Want = 'FAIL'; Says = $skipWhy; Why = 'a skipped block under CI despite exit 0 and banner' }
        @{ Name = 'skip-outside-ci'; Body = $skipBody; Want = 'PASS'; Why = 'the same skip outside CI stays a grey line' }
        @{ Name = 'declared-skip-in-ci'; Body = $skipBody; CI = $true; Declared = @('some other block', $skipWhy); Want = 'PASS'; Why = 'under CI a skip the job declares' }
        @{ Name = 'changed-skip-in-ci'; Body = $skipBody; CI = $true; Declared = @($skipWhy + ' (reworded)'); Want = 'FAIL'; Says = $skipWhy; Why = 'under CI a skip whose message is not the declared one' }
        @{ Name = 'quoted-product-skip'; Body = "Write-Host '12:00:00 [INFO] SKIP Integrity watch: an install, update or model update is running'; Write-Host '    | 12:00:01 [INFO] SKIP SearXNG search: the searxng container is not running'; Write-Host '  ASSERT OK   off Windows the checks are skipped, none fails (12:00:02 [INFO] SKIP Firewall: not Windows)'; Write-Host 'FAKE PASSED'; exit 0"; CI = $true; Want = 'PASS'; Why = 'product SKIP verdicts printed or quoted by a passing test, under CI' }
        @{ Name = 'warn-skip-in-ci'; Body = "Write-Host '12:00:00 [WARN] SKIP deep research: fake image is not on this machine'; Write-Host 'FAKE PASSED'; exit 0"; CI = $true; Want = 'FAIL'; Says = 'deep research: fake image is not on this machine'; Why = "the integration test's skip line under CI" }
        @{ Name = 'paren-skip-in-ci'; Body = "Write-Host '  (skipped: this machine has a real fake volume)'; Write-Host 'FAKE PASSED'; exit 0"; CI = $true; Want = 'FAIL'; Says = 'this machine has a real fake volume'; Why = "the uninstall test's skip line under CI" }
        @{ Name = 'tool-skip-in-ci'; Body = "Write-Host 'Fake analyzer not available; skipped.'; Write-Host 'FAKE PASSED'; exit 0"; CI = $true; Want = 'FAIL'; Says = 'Fake analyzer not available'; Why = "the static checks' skip line under CI" }
        @{ Name = 'bare-skip-in-ci'; Body = "Write-Host '  SKIP'; Write-Host 'FAKE PASSED'; exit 0"; CI = $true; Want = 'FAIL'; Says = 'without a reason'; Why = 'under CI a skip that gives no reason' }
    )
    $bad = 0
    foreach ($f in $fakes) {
        $file = Join-Path $dir ($f.Name + $(if ($f.Ext) { $f.Ext } else { '.ps1' }))
        if ($null -ne $f.Body) { Set-Content -LiteralPath $file -Value $f.Body }
        $suite = @{ Name = $f.Name; File = $file; Args = @(); Pass = 'FAKE PASSED' }
        if ($f.Exe) { $suite.Exe = $f.Exe }
        $fakeDeclared = @(); if ($f.Declared) { $fakeDeclared = @($f.Declared) }
        # A cold pwsh start can take several seconds on CI: only the hang gets a short limit.
        $r = Invoke-Suite -Suite $suite -Log (Join-Path $dir ($f.Name + '.log')) -Limit $(if ($f.Name -eq 'hang') { 4 } else { 60 }) -CI ([bool]$f.CI) -Declared $fakeDeclared
        $ok = $r.Result -like "$($f.Want)*"
        # A skip must be named in the reasons, so the job log says what did not run and why.
        if ($f.Says) { $ok = $ok -and (@($r.First) -join ' | ').Contains([string]$f.Says) }
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
    # The same skip through -Step, the way the CI workflows start a suite. -Quiet: echoed into this
    # self-test's own output, the fake's SKIP line would be a skip of the self-test.
    $stepCases = @(
        @{ CI = $true; Declared = @(); Want = 1; Why = 'under CI an undeclared skip is a problem that names it' }
        @{ CI = $false; Declared = @(); Want = 0; Why = 'outside CI the same skip is none' }
        @{ CI = $true; Declared = @($skipWhy); Want = 0; Why = 'under CI a declared skip is none' }
    )
    foreach ($c in $stepCases) {
        $s = Invoke-Step -File (Join-Path $dir 'skip-in-ci.ps1') -Declared $c.Declared -CI ([bool]$c.CI) -Quiet
        # Not held open: a suite that left nothing running ends with its pipes, without the wait.
        $ok = ($s.Code -eq 0 -and @($s.Problems).Count -eq $c.Want -and -not $s.HeldOpen)
        if ($c.Want) { $ok = $ok -and (@($s.Problems) -join ' | ').Contains($skipWhy) }
        if ($ok) { Write-Host ("  ASSERT OK   -Step: {0} -> exit {1}, {2} problem(s)" -f $c.Why, $s.Code, @($s.Problems).Count) -ForegroundColor Green }
        else { Write-Host ("  ASSERT FAIL -Step: {0} -> exit {1}, {2} problem(s), output held open: {5} (wanted exit 0, {3}, not held open) {4}" -f $c.Why, $s.Code, @($s.Problems).Count, $c.Want, (@($s.Problems) -join ' | '), $s.HeldOpen) -ForegroundColor Red; $bad++ }
    }
    $s = Invoke-Step -File (Join-Path $dir 'exit-code.ps1') -CI $true -Quiet
    if ($s.Code -eq 3) { Write-Host '  ASSERT OK   -Step: the exit code of the suite is kept -> exit 3' -ForegroundColor Green }
    else { Write-Host "  ASSERT FAIL -Step: the exit code of the suite is kept -> exit $($s.Code) (wanted 3)" -ForegroundColor Red; $bad++ }
    # The PASSED banner through -Step, on the fakes written above: a suite that ends with exit 0
    # without its banner stopped before its end, and no skip line says so.
    $bannerCases = @(
        @{ File = 'no-banner.ps1'; Pass = 'FAKE PASSED'; Code = 0; Want = $true; Why = 'exit 0 without its banner is a failure' }
        @{ File = 'good.ps1'; Pass = 'FAKE PASSED'; Code = 0; Want = $false; Why = 'exit 0 with its banner is none' }
        @{ File = 'no-banner.ps1'; Pass = ''; Code = 0; Want = $false; Why = 'a file with no banner to ask for is not asked for one' }
        @{ File = 'exit-code.ps1'; Pass = 'NO SUCH BANNER'; Code = 3; Want = $false; Why = 'after another exit code the banner is not asked for (that code is the failure)' }
    )
    foreach ($c in $bannerCases) {
        $s = Invoke-Step -File (Join-Path $dir $c.File) -CI $true -Pass $c.Pass -Quiet
        $ok = ($s.Code -eq $c.Code -and $s.NoBanner -eq $c.Want -and @($s.Problems).Count -eq 0)
        if ($ok) { Write-Host ("  ASSERT OK   -Step: {0} -> exit {1}, banner missing: {2}" -f $c.Why, $s.Code, $s.NoBanner) -ForegroundColor Green }
        else { Write-Host ("  ASSERT FAIL -Step: {0} -> exit {1}, banner missing: {2}, {3} problem(s) (wanted exit {4}, banner missing: {5}, 0 problems)" -f $c.Why, $s.Code, $s.NoBanner, @($s.Problems).Count, $c.Code, $c.Want) -ForegroundColor Red; $bad++ }
    }
    # -Step finds a suite's banner by its file name. Every suite file in this folder must have one
    # (a new suite without it would pass its CI step when it stops early), the stack smoke test
    # among them although the full run does not hold it, and a file that is no suite has none.
    $known = @($suites) + @($stepOnlySuites)
    $unasked = @(Get-ChildItem -LiteralPath $t -Filter 'Invoke-*.ps1' -File | Where-Object { -not (Get-StepBanner -File $_.FullName -Suites $known) } | ForEach-Object { $_.Name })
    $smokeBanner = Get-StepBanner -File (Join-Path $dir 'Invoke-StackSmokeTest.ps1') -Suites $known
    $noSuiteBanner = Get-StepBanner -File (Join-Path $dir 'no-banner.ps1') -Suites $known
    if ($unasked.Count -eq 0 -and $smokeBanner -eq 'STACK SMOKE TEST PASSED' -and $noSuiteBanner -eq '') { Write-Host '  ASSERT OK   -Step: every Invoke-*.ps1 in the tests folder has a banner to ask for, found by file name; a file that is no suite has none' -ForegroundColor Green }
    else { Write-Host ("  ASSERT FAIL -Step: every Invoke-*.ps1 in the tests folder has a banner to ask for, found by file name; a file that is no suite has none -> without one: {0}; stack smoke test: '{1}'; no suite: '{2}' (add the suite to the suite table or to the -Step only table of Invoke-AllTests.ps1)" -f ($unasked -join ', '), $smokeBanner, $noSuiteBanner) -ForegroundColor Red; $bad++ }
    # A suite that exits 0 and leaves a helper running. The helper is started the way the watch,
    # model update and uninstall tests start theirs (Start-Process without a redirection), so it
    # has the suite's output pipes: -Step must end with the suite, not with the helper 300 seconds
    # later, and must still have read what the suite wrote (its skip line).
    $leakIdFile = Join-Path $dir 'left-running.pid'
    $leakFile = Join-Path $dir 'left-running.ps1'
    Set-Content -LiteralPath $leakFile -Value "`$helper = Start-Process -FilePath 'sleep' -ArgumentList '300' -PassThru; Set-Content -LiteralPath '$leakIdFile' -Value `$helper.Id; $skipBody"
    $leakWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $s = Invoke-Step -File $leakFile -CI $true -Quiet
    $leakWatch.Stop()
    $leakId = 0
    if (Test-Path -LiteralPath $leakIdFile) { $leakId = [int](Get-Content -LiteralPath $leakIdFile -Raw).Trim() }
    # HeldOpen is the proof that the helper did hold the pipes: without it this case tests nothing.
    # 60 s: a cold pwsh start and the wait after the exit take several seconds on CI, the helper 300.
    $ok = ($s.Code -eq 0 -and $s.HeldOpen -and $leakWatch.Elapsed.TotalSeconds -lt 60 -and @($s.Problems).Count -eq 1 -and (@($s.Problems) -join ' | ').Contains($skipWhy))
    if ($ok) { Write-Host ("  ASSERT OK   -Step: a suite that left a helper running, with its output pipes, ends with the suite -> exit {0} after {1} s, {2} problem(s)" -f $s.Code, [int]$leakWatch.Elapsed.TotalSeconds, @($s.Problems).Count) -ForegroundColor Green }
    else { Write-Host ("  ASSERT FAIL -Step: a suite that left a helper running, with its output pipes, ends with the suite -> exit {0} after {1} s, output held open: {2}, {3} problem(s) (wanted exit 0 within 60 s, held open, 1 problem that names the skip) {4}" -f $s.Code, [int]$leakWatch.Elapsed.TotalSeconds, $s.HeldOpen, @($s.Problems).Count, (@($s.Problems) -join ' | ')) -ForegroundColor Red; $bad++ }
    if ($leakId) { Stop-Process -Id $leakId -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    # -Since: the suites picked for a change.
    $cases = @(
        @{ Files = @('README.md'); Want = 'Static'; Why = 'documentation only' }
        @{ Files = @('lib/LocalAI.psm1'); Want = (@($suites | ForEach-Object { $_.Name }) -join ','); Why = 'shared module: everything' }
        @{ Files = @('Watch-LocalAI.ps1'); Has = @('Static', 'Unit', 'Watch', 'Mock'); Not = @('Integration', 'ModelUpdate'); Why = 'the watch: its suite, the unit smoke runs, the mock run (the installer registers it)' }
        @{ Files = @('Update-Models.ps1'); Has = @('ModelUpdate', 'Mock'); Why = 'a script the installer runs: its suite and the mock run' }
        @{ Files = @('Test-LocalAI.ps1'); Has = @('Acceptance'); Why = 'the checklist is the Acceptance suite' }
        @{ Files = @('No-Such-Script.ps1'); Want = (@($suites | ForEach-Object { $_.Name }) -join ','); Why = 'a file no suite names: everything' }
    )
    foreach ($c in $cases) {
        $got = @(Get-SuitesForChange -Files $c.Files -Suites $suites -Root $src)
        $ok = $true
        if ($c.Want) { $ok = (($got -join ',') -eq $c.Want) }
        if ($c.Has) { $ok = $ok -and @($c.Has | Where-Object { $got -notcontains $_ }).Count -eq 0 }
        if ($c.Not) { $ok = $ok -and @($c.Not | Where-Object { $got -contains $_ }).Count -eq 0 }
        if ($ok) { Write-Host ("  ASSERT OK   -Since {0}: {1} -> {2}" -f ($c.Files -join ','), $c.Why, ($got -join ',')) -ForegroundColor Green }
        else { Write-Host ("  ASSERT FAIL -Since {0}: {1} -> {2}" -f ($c.Files -join ','), $c.Why, ($got -join ',')) -ForegroundColor Red; $bad++ }
    }
    if ($bad) { Write-Host "`nHARNESS SELF-TEST FAILED ($bad)" -ForegroundColor Red } else { Write-Host "`nHARNESS SELF-TEST PASSED" -ForegroundColor Green }
    exit $bad
}

if ($Step) {
    # One suite file, for a CI workflow step. The suite's own exit code stays the step's; a suite that
    # exits 0 still fails the step under CI when it skipped a block the job has not declared, and
    # anywhere when it did not print its PASSED banner: it stopped before its end, which no skip
    # line would show.
    if ($Only.Count -or $Since) { Write-Host '-Step cannot be combined with -Only or -Since.' -ForegroundColor Red; exit 100 }
    if (-not (Test-Path -LiteralPath $Step -PathType Leaf)) { Write-Host "-Step: there is no suite file '$Step'." -ForegroundColor Red; exit 100 }
    $stepFile = (Resolve-Path -LiteralPath $Step).ProviderPath
    $stepBanner = Get-StepBanner -File $stepFile -Suites (@($suites) + @($stepOnlySuites))
    $r = Invoke-Step -File $stepFile -Arguments $StepArgs -Declared $declaredSkips -CI $inCI -Pass $stepBanner
    if ($r.Problems.Count) {
        Write-Host ''
        foreach ($p in $r.Problems) { Write-Host "  $p" -ForegroundColor Red }
        Write-Host ("{0}: {1} skip(s) this CI job has not declared. A block that did not run proves nothing." -f (Split-Path -Leaf $stepFile), $r.Problems.Count) -ForegroundColor Red
        Write-Host 'Make it run on this job; if it cannot run here by design, add its message to LAI_DECLARED_SKIPS of this job in the workflow file.' -ForegroundColor Red
    }
    if ($r.NoBanner) {
        Write-Host ''
        Write-Host ("  ASSERT FAIL {0} ended with exit 0 without its line '{1}': it stopped before its end, and what comes after that point did not run." -f (Split-Path -Leaf $stepFile), $stepBanner) -ForegroundColor Red
    }
    if ($r.Code -ne 0) { exit $r.Code }
    $stepBad = $r.Problems.Count
    if ($r.NoBanner) { $stepBad++ }
    exit $stepBad
}

if ($Since) {
    if ($Only.Count) { Write-Host '-Since and -Only cannot be combined.' -ForegroundColor Red; exit 100 }
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $changed = @(& git -C $src diff --relative --name-only $Since 2>&1) + @(& git -C $src ls-files --others --exclude-standard 2>&1)
    $gitCode = $LASTEXITCODE; $ErrorActionPreference = $prevPref
    if ($gitCode -ne 0) { Write-Host "git could not list the changes since '$Since': $($changed -join ' ')" -ForegroundColor Red; exit 100 }
    $changed = @($changed | ForEach-Object { "$_" } | Where-Object { $_ } | Sort-Object -Unique)
    $Only = @(Get-SuitesForChange -Files $changed -Suites $suites -Root $src)
    Write-Host ("Changed since {0}: {1} file(s) -> {2}" -f $Since, $changed.Count, ($Only -join ', ')) -ForegroundColor Cyan
}
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
$needsSandbox = @($suites | Where-Object { @('Harness', 'Static', 'Unit', 'Bootstrap', 'RenderGuard') -notcontains $_.Name }).Count -gt 0
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
        $r = Invoke-Suite -Suite $s -Log (Join-Path $LogDir ($s.Name + '.log')) -Limit $TimeoutSec -CI $inCI -Declared $declaredSkips
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
