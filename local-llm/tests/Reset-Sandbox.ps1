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
    # Only remove what the skills feature put into the shared Open WebUI (the installer mock run and
    # the integration test call this when they finish).
    [switch]$SkillsOnly,
    # The sandbox services and the admin login every suite expects.
    [string]$WebUIUrl = 'http://127.0.0.1:3000',
    [string]$OllamaUrl = 'http://127.0.0.1:11434',
    [string]$Email = 'admin@localhost',
    [string]$Password = 'Test-Password-123'
)
$ErrorActionPreference = 'Stop'
# Refuses to run anywhere but a throwaway test machine (it would delete a real install's data).
if (-not (& (Join-Path $PSScriptRoot 'Assert-LaiSandbox.ps1'))) { exit 99 }
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
$testVolumes = @('owui-old', 'owui-empty', 'lai-deep-test', 'lai-empty-test', 'lai-ok-test')
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

function Invoke-SkillsCleanup([string]$Token) {
    # The skills feature (installer Configure stage, integration test): folder skills, learned
    # drafts, the skill notebook tool, and the presets' references to them.
    $all = Get-LaiWebUISkills -BaseUrl $WebUIUrl -Token $Token
    $ours = @($all.Values | Where-Object { (Test-LaiSkillTag $_ 'localai-folder') -or (Test-LaiSkillTag $_ 'learned') } | ForEach-Object { [string]$_.id })
    foreach ($sid in $ours) {
        Invoke-Repair "skill $sid (made by a test)" { Invoke-LaiApi -Method DELETE -Uri "$WebUIUrl/api/v1/skills/id/$sid/delete" -Token $Token | Out-Null }
    }
    $nb = $null; try { $nb = Invoke-LaiApi -Uri "$WebUIUrl/api/v1/tools/id/localai_skill_notebook" -Token $Token } catch { $nb = $null }
    if ($nb) { Invoke-Repair 'the skill notebook tool (made by a test)' { Invoke-LaiApi -Method DELETE -Uri "$WebUIUrl/api/v1/tools/id/localai_skill_notebook/delete" -Token $Token | Out-Null } }
    foreach ($pm in @(Invoke-LaiApi -Uri "$WebUIUrl/api/v1/models/export" -Token $Token | ForEach-Object { $_ })) {
        if (-not $pm -or -not $pm.meta) { continue }
        $sk = @(); if ($pm.meta.PSObject.Properties['skillIds']) { $sk = @($pm.meta.skillIds) }
        $tl = @(); if ($pm.meta.PSObject.Properties['toolIds']) { $tl = @($pm.meta.toolIds) }
        $stale = @($sk | Where-Object { $ours -contains $_ -or $_ -like 'learned-*' }) + @($tl | Where-Object { $_ -eq 'localai_skill_notebook' })
        if (-not $stale.Count) { continue }
        Invoke-Repair "preset $([string]$pm.id) still offers $($stale -join ', ')" {
            $form = ConvertTo-LaiHashtable $pm
            $form['meta']['skillIds'] = [object[]]@($sk | Where-Object { $stale -notcontains $_ })
            $form['meta']['toolIds'] = [object[]]@($tl | Where-Object { $stale -notcontains $_ })
            if ($null -eq $form['params']) { $form['params'] = @{} }
            Invoke-LaiApi -Method POST -Uri "$WebUIUrl/api/v1/models/model/update" -Body $form -Token $Token | Out-Null
        }
    }
}

if ($SkillsOnly) {
    $token = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $Email -Password $Password
    Invoke-SkillsCleanup -Token $token
    Write-Host ("Skills cleanup: {0} item(s) found, {1} could not be removed" -f $script:found, $script:unfixed)
    exit $script:unfixed
}

# ---- containers -----------------------------------------------------------------------------------
$rows = @((Invoke-DockerCli @('ps', '-a', '--format', '{{.Names}}|{{.Image}}|{{.State}}|{{.Label `com.docker.compose.project`}}')).Out | Where-Object { $_ })
$names = @($rows | ForEach-Object { ($_ -split '\|')[0] })
foreach ($row in $rows) {
    $name, $image, $state, $project = $row -split '\|'
    $isTest = ($testProjects -contains $project) -or ($name -match '^open-webui-legacy-') -or
        (($standInNames -contains $name) -and $image -like 'alpine:*') -or
        ((Invoke-DockerCli @('inspect', '-f', '{{index .Config.Labels `lai-test`}}', $name)).Out -join '') -eq '1'
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

# A stand-in 'older image' tag from the update test.
if (@((Invoke-DockerCli @('images', '-q', 'alpine:lai-old-test')).Out | Where-Object { $_ }).Count) {
    Invoke-Repair 'image tag alpine:lai-old-test' { Assert-Docker (Invoke-DockerCli @('rmi', 'alpine:lai-old-test')) 'docker rmi' }
}

# ---- volumes and networks ------------------------------------------------------------------------
foreach ($v in @((Invoke-DockerCli @('volume', 'ls', '--format', '{{.Name}}|{{.Label `com.docker.compose.project`}}')).Out | Where-Object { $_ })) {
    $name, $project = $v -split '\|'
    # 'open-webui' only when no container uses it (the tests' stand-in volume; the sandbox's Open
    # WebUI keeps its data in a folder). localai-verify-*: the backup deep check's scratch volume.
    $unused = $false
    if ($name -eq 'open-webui') { $unused = -not @((Invoke-DockerCli @('ps', '-aq', '--filter', 'volume=open-webui')).Out | Where-Object { $_ }).Count }
    if ($testVolumes -contains $name -or $testProjects -contains $project -or $unused -or $name -match '^localai-verify-\d{14}$') {
        Invoke-Repair "volume $name" { Assert-Docker (Invoke-DockerCli @('volume', 'rm', '-f', $name)) "docker volume rm $name" }
    }
}
foreach ($n in @((Invoke-DockerCli @('network', 'ls', '--format', '{{.Name}}|{{.Label `com.docker.compose.project`}}')).Out | Where-Object { $_ })) {
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
} elseif ($env:GITHUB_ACTIONS -eq 'true') {
    # Without pgrep nothing above has looked. Under CI that counts, also with -LeftoversOnly: the
    # 'Nothing left behind' step must not pass without having looked for helper processes.
    $script:found++; $script:unfixed++
    Write-Host '  MISSING  pgrep: helper processes left by a suite were not looked for' -ForegroundColor Red
} else {
    Write-Host '  MISSING  pgrep: helper processes left by a suite were not looked for (not counted outside CI)' -ForegroundColor Yellow
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
        Invoke-SkillsCleanup -Token $token
        # A run killed during a RAG self-test leaves its collection and file; the next suite's
        # leftover check would fail for that reason.
        foreach ($left in @(Get-LaiWebUISelfTestLeftover -BaseUrl $WebUIUrl -Token $token)) {
            Invoke-Repair "RAG self-test $($left.Kind) $($left.Id) left by an interrupted run" { Invoke-LaiApi -Method DELETE -Uri $left.Uri -Token $token | Out-Null }
        }
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
