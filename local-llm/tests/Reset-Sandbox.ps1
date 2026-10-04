<#
.SYNOPSIS
    Puts the shared test sandbox back into its known state, or (-Check) only reports what a test
    left behind.

.DESCRIPTION
    The suites share one Docker engine, one Ollama and one Open WebUI. A suite that is killed
    mid-run (or forgets a cleanup) leaves throwaway containers (some with restart=always, so they
    come back after a reboot), volumes, helper processes, a renamed SearXNG, test models or a
    changed admin password behind, and the NEXT suite then fails, or passes for the wrong reason.

    Invoke-AllTests.ps1 runs this before the first suite, runs it with -Check after every suite (a
    leftover fails that suite, then is cleaned), and CI runs -Check after the last suite.
    Exit code = number of leftovers found (-Check) or that could not be cleaned.

.PARAMETER Check
    Only report leftovers; change nothing.

.PARAMETER LeftoversOnly
    Report a missing sandbox service (SearXNG, Ollama) without counting it: after each suite only
    what the suite left behind should fail it, not an environment problem it did not cause.

.PARAMETER SkipWebUI
    Skip the Open WebUI checks (admin password, Ollama connection). Each one costs a sign-in, and
    Open WebUI allows 15 per 3 minutes.
#>
param(
    [switch]$Check,
    [switch]$SkipWebUI,
    [switch]$LeftoversOnly,
    # The sandbox services and the admin login every suite expects.
    [string]$WebUIUrl = 'http://127.0.0.1:3000',
    [string]$OllamaUrl = 'http://127.0.0.1:11434',
    [string]$Email = 'admin@localhost',
    [string]$Password = 'Test-Password-123'
)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
$script:found = 0
$script:missingCounts = -not $LeftoversOnly
$script:unfixed = 0

function Invoke-DockerCli([string[]]$DockerArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& docker @DockerArgs 2>&1 | ForEach-Object { "$_" }); return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out } }
    finally { $ErrorActionPreference = $prev }
}
function Invoke-Repair([string]$What, [scriptblock]$Action) {
    $script:found++
    if ($Check) { Write-Host "  LEFTOVER $What" -ForegroundColor Red; return }
    try { & $Action; Write-Host "  cleaned  $What" -ForegroundColor Yellow }
    catch { $script:unfixed++; Write-Host "  FAILED   $What : $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Docker($Result, [string]$What) { if ($Result.Code -ne 0) { throw "$What failed: $($Result.Out -join ' ')" } }
function Write-Missing([string]$What) {
    if ($script:missingCounts) { $script:found++; $script:unfixed++ }
    Write-Host "  MISSING  $What" -ForegroundColor Red
}

# Compose projects and volumes only the tests create; container names the tests give alpine stand-ins.
$testProjects = @('lai-update-test', 'lai-uninstall-test', 'lai-stopstart-test')
$testVolumes = @('owui-old', 'lai-deep-test', 'lai-empty-test')
$standInNames = @('open-webui', 'render-guard', 'lai-stopstart-probe')

if ((Invoke-DockerCli @('info', '--format', '{{.ServerVersion}}')).Code -ne 0) {
    Write-Host '  Docker engine not reachable: cannot check containers or volumes.' -ForegroundColor Red
    exit 1
}
# The sandbox runs Open WebUI natively. A real Open WebUI container means a real install, whose
# data this script must never touch.
$real = @((Invoke-DockerCli @('ps', '-a', '--format', '{{.Names}} {{.Image}}')).Out | Where-Object { $_ -match ' ghcr\.io/open-webui/' })
if ($real.Count) {
    Write-Host "  Refusing: this Docker engine runs a real Open WebUI ($($real -join ', ')). Run the tests on a sandbox only." -ForegroundColor Red
    exit 1
}

# ---- containers -----------------------------------------------------------------------------------
$rows = @((Invoke-DockerCli @('ps', '-a', '--format', '{{.Names}}|{{.Image}}|{{.State}}|{{.Label "com.docker.compose.project"}}')).Out | Where-Object { $_ })
$names = @($rows | ForEach-Object { ($_ -split '\|')[0] })
foreach ($row in $rows) {
    $name, $image, $state, $project = $row -split '\|'
    $isTest = ($testProjects -contains $project) -or ($name -match '^open-webui-legacy-') -or
        (($standInNames -contains $name) -and $image -like 'alpine:*') -or
        ((Invoke-DockerCli @('inspect', '-f', '{{index .Config.Labels "lai-test"}}', $name)).Out -join '') -eq '1'
    if ($isTest) {
        Invoke-Repair "container $name ($image, $state)" { Assert-Docker (Invoke-DockerCli @('rm', '-f', $name)) "docker rm $name" }
    }
}

# The uninstall test parks the real SearXNG under another name; the watch test stops it.
if ($names -contains 'searxng-uninstall-test-keep') {
    if ($names -notcontains 'searxng') {
        Invoke-Repair 'SearXNG still renamed to searxng-uninstall-test-keep' {
            Assert-Docker (Invoke-DockerCli @('rename', 'searxng-uninstall-test-keep', 'searxng')) 'docker rename'
        }
        if (-not $Check) { $names += 'searxng' }
    } else {
        $script:found++; $script:unfixed++
        Write-Host '  LEFTOVER both searxng and searxng-uninstall-test-keep exist: remove the one that is not the sandbox SearXNG by hand' -ForegroundColor Red
    }
}
if ($names -contains 'searxng') {
    $st = ((Invoke-DockerCli @('inspect', '-f', '{{.State.Status}}', 'searxng')).Out -join '').Trim()
    if ($st -ne 'running') {
        Invoke-Repair "SearXNG not running ($st)" { Assert-Docker (Invoke-DockerCli @('start', 'searxng')) 'docker start searxng' }
    }
} elseif ($names -notcontains 'searxng-uninstall-test-keep') {
    Write-Missing 'the sandbox searxng container'
}

# ---- volumes and networks ------------------------------------------------------------------------
foreach ($v in @((Invoke-DockerCli @('volume', 'ls', '--format', '{{.Name}}|{{.Label "com.docker.compose.project"}}')).Out | Where-Object { $_ })) {
    $name, $project = $v -split '\|'
    # 'open-webui' only when no container uses it (the tests' stand-in volume; the sandbox's Open
    # WebUI keeps its data in a folder). localai-verify-*: the backup deep check's scratch volume.
    $unused = $false
    if ($name -eq 'open-webui') { $unused = -not @((Invoke-DockerCli @('ps', '-aq', '--filter', 'volume=open-webui')).Out | Where-Object { $_ }).Count }
    if ($testVolumes -contains $name -or $testProjects -contains $project -or $unused -or $name -match '^localai-verify-\d{14}$') {
        Invoke-Repair "volume $name" { Assert-Docker (Invoke-DockerCli @('volume', 'rm', '-f', $name)) "docker volume rm $name" }
    }
}
foreach ($n in @((Invoke-DockerCli @('network', 'ls', '--format', '{{.Name}}|{{.Label "com.docker.compose.project"}}')).Out | Where-Object { $_ })) {
    $name, $project = $n -split '\|'
    if ($testProjects -contains $project) {
        Invoke-Repair "network $name" { Assert-Docker (Invoke-DockerCli @('network', 'rm', $name)) "docker network rm $name" }
    }
}

# ---- helper processes ----------------------------------------------------------------------------
# The mock run's render guard, the uninstall test's fake Ollama, lock holders of the watch and
# model-update tests. None of them may outlive its suite.
if (Get-Command pgrep -ErrorAction SilentlyContinue) {
    foreach ($pattern in @('render-guard/render_guard\.py', 'fake_ollama\.py', 'hold-lock\.ps1', 'hold-setup\.ps1')) {
        $procIds = @(& pgrep -f $pattern 2>$null | Where-Object { $_ -and [int]$_ -ne $PID })
        foreach ($procId in $procIds) {
            $cmd = ''
            try { $cmd = (Get-Content -LiteralPath "/proc/$procId/cmdline" -Raw -ErrorAction Stop) -replace "`0", ' ' } catch { $cmd = $pattern }
            Invoke-Repair "process $procId ($($cmd.Trim()))" { Stop-Process -Id ([int]$procId) -Force -ErrorAction Stop }
        }
    }
}

# ---- Ollama test models --------------------------------------------------------------------------
try {
    $tags = @((Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 10).models | ForEach-Object { [string]$_.name })
    foreach ($m in $tags) {
        if ($m -match '^(testorg/update-test|localai-update-test)') {
            Invoke-Repair "Ollama model $m" {
                Invoke-RestMethod -Method Delete -Uri "$OllamaUrl/api/delete" -ContentType 'application/json' -Body (ConvertTo-Json @{ model = $m }) -TimeoutSec 30 | Out-Null
            }
        }
    }
} catch {
    Write-Missing "Ollama at $OllamaUrl ($($_.Exception.Message))"
}

# ---- Open WebUI: the admin password and Ollama connection every suite expects ---------------------
if (-not $SkipWebUI) {
    $token = $null
    try { $token = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $Email -Password $Password }
    catch {
        # The password-rotation test's values: a run killed mid-test leaves one of them set.
        foreach ($pw in 'Rotated-Password-456', 'Rotated-Password-789') {
            $t = $null
            try { $t = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $Email -Password $pw } catch { Write-Verbose "not $pw" }
            if ($t) {
                Invoke-Repair 'Open WebUI admin password left changed by the rotation test' {
                    Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/auths/update/password" -Token $t -Body @{ password = $pw; new_password = $Password } | Out-Null
                }
                if (-not $Check) { $token = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $Email -Password $Password }
                break
            }
        }
        # Counted in -Check too: a check that cannot sign in has not shown the state is clean.
        if (-not $token) {
            $script:found++; if (-not $Check) { $script:unfixed++ }
            Write-Host "  FAILED   cannot sign in to Open WebUI as $Email with any known test password" -ForegroundColor Red
        }
    }
    if ($token) {
        $urls = @((Invoke-LaiApi -Uri "$WebUIUrl/ollama/config" -Token $token).OLLAMA_BASE_URLS | ForEach-Object { ([string]$_).TrimEnd('/') })
        if (($urls -join ',') -ne $OllamaUrl) {
            Invoke-Repair "Open WebUI's Ollama connection is $($urls -join ', ') (not $OllamaUrl)" {
                # Set outright: the mock run's render guard URL is not one Set-LaiWebUIOllamaUrl rewrites.
                $cfg = ConvertTo-LaiHashtable (Invoke-LaiApi -Uri "$WebUIUrl/ollama/config" -Token $token)
                $apiConfigs = @{}
                if ($cfg.ContainsKey('OLLAMA_API_CONFIGS') -and $cfg['OLLAMA_API_CONFIGS']) { $apiConfigs = $cfg['OLLAMA_API_CONFIGS'] }
                $body = @{ ENABLE_OLLAMA_API = $true; OLLAMA_BASE_URLS = [object[]]@($OllamaUrl); OLLAMA_API_CONFIGS = $apiConfigs }
                Invoke-LaiApi -Method POST -Uri "$WebUIUrl/ollama/config/update" -Body $body -Token $token | Out-Null
            }
        }
    }
}

if ($Check) {
    if ($script:found) { Write-Host "Sandbox check: $($script:found) leftover(s)" -ForegroundColor Red } else { Write-Host 'Sandbox check: clean' -ForegroundColor Green }
    exit $script:found
}
Write-Host ("Sandbox reset: {0} item(s) cleaned, {1} could not be" -f ($script:found - $script:unfixed), $script:unfixed) -ForegroundColor $(if ($script:unfixed) { 'Red' } else { 'Green' })
exit $script:unfixed
