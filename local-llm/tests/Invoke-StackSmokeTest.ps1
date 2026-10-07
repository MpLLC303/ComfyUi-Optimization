<#
.SYNOPSIS
    Starts the production stack from stack/docker-compose.yml with docker compose (the real Open
    WebUI image, the render guard inside the SearXNG image, SearXNG, optionally Local Deep Research)
    and checks that it comes up and answers.

.DESCRIPTION
    The other suites run Open WebUI from pip and take only SearXNG from the compose file, so the
    stack the installer really deploys never started in CI. This one does, the way the installer
    does it: the compose file, render_guard.py and settings.yml are copied into a Stack folder, a
    .env with the installer's keys (test values only) is written next to them, then
    'docker compose pull' and 'up -d --remove-orphans'. Ollama is a stand-in at -OllamaUrl that
    the containers must reach as host.docker.internal:11434 (on Linux that means it listens on all
    interfaces, which is what the installer's fallback does on Windows).

    Checks: every service of the active profiles is running (healthy where it has a healthcheck,
    and has not restarted); every service carries the container hardening the compose file gives it
    (docs/CONTAINER-HARDENING-PLAN.md), read back from docker inspect with a format template (no
    new privileges, ALL capabilities dropped and only the listed ones added back, the memory and
    pids limits, the read-only root and the unprivileged user where the service has them) and from
    the kernel inside the container (NoNewPrivs, the capability sets, the user of PID 1); every
    published port is bound to 127.0.0.1 and nothing answers on the machine's other addresses; Open
    WebUI answers on its port with the pinned version, the admin from .env signs in and its Ollama
    connection works (all of it without a single capability); the render guard answers its status
    page as a non-root user and reaches Ollama; Open WebUI reaches Ollama through the guard and
    SearXNG over the compose network; SearXNG answers a JSON search as its unprivileged user on a
    read-only filesystem, and its log names no file it could not write and no missing privilege;
    deep research (-DeepResearch) answers and reaches Ollama through the guard; after all of that
    no container was ended by its memory limit or restarted. Last, the stack is taken down with
    its volumes and nothing of it may remain.

    The containers have fixed names (open-webui, searxng, render-guard, deep-research), so this
    cannot share a Docker engine with the other suites or with a real install: it refuses to start
    when one of those names or the open-webui volume exists. CI runs it in a job of its own.

.PARAMETER OllamaUrl
    The stand-in Ollama as seen from this machine. Containers reach it as host.docker.internal:11434.
.PARAMETER DeepResearch
    Also start the optional deep-research service (the installer's -DeepResearch writes
    COMPOSE_PROFILES=research).
#>
param(
    [string]$Work = (Join-Path ([System.IO.Path]::GetTempPath()) 'lai-stacksmoke'),
    [string]$OllamaUrl = 'http://127.0.0.1:11434',
    [int]$WebUIPort = 3000,
    [int]$SearxngPort = 8888,
    [int]$ResearchPort = 5055,
    [switch]$DeepResearch,
    [int]$StartTimeoutSec = 900
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
function Invoke-DockerCli([string[]]$DockerArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& docker @DockerArgs 2>&1 | ForEach-Object { "$_" }); return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out } }
    finally { $ErrorActionPreference = $prev }
}
function Get-DockerJson([string[]]$DockerArgs) {
    # Standard output only (compose prints warnings on standard error), parsed as JSON.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $text = (@(& docker @DockerArgs 2>$null | ForEach-Object { "$_" }) -join "`n")
        if ($LASTEXITCODE -ne 0) { throw "docker $($DockerArgs -join ' ') failed (exit $LASTEXITCODE)" }
        # Through a variable: Windows PowerShell 5.1 hands a JSON array over as ONE object (nested in
        # @()); returning the variable enumerates it there and in PowerShell 7 alike.
        $parsed = ConvertFrom-Json -InputObject $text
        return $parsed
    } finally { $ErrorActionPreference = $prev }
}
function Invoke-Compose([string[]]$ComposeArgs) {
    return (Invoke-DockerCli (@('compose', '--project-directory', $stack, '-f', $composeFile) + $ComposeArgs))
}
function Get-StackContainers {
    $ids = @((Invoke-DockerCli @('ps', '-a', '-q', '--filter', 'label=com.docker.compose.project=localai')).Out | Where-Object { $_ -match '^[0-9a-f]{12,64}$' })
    if (-not $ids.Count) { return @() }
    return @(Get-DockerJson (@('inspect') + $ids))
}
function Get-ServiceName($Container) { return [string]$Container.Config.Labels.'com.docker.compose.service' }
function Test-ContainerReady($Container) {
    # Running, and healthy when the image or the compose file defines a healthcheck.
    if ($Container.State.Status -ne 'running') { return $false }
    if ($Container.State.PSObject.Properties['Health'] -and $Container.State.Health) { return ($Container.State.Health.Status -eq 'healthy') }
    return $true
}
function Get-InstallerDefault([string]$Name) {
    $p = @($installerAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name })
    if (-not $p.Count) { throw "Install-LocalAI.ps1 has no parameter -$Name" }
    return [string]$p[0].DefaultValue.Value
}
function Test-TcpPort([string]$Address, [int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(3000)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch { return $false } finally { $client.Close() }
}
function Get-NonLoopbackAddress {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not [System.Net.IPAddress]::IsLoopback($ua.Address)) { $found.Add($ua.Address.ToString()) }
        }
    }
    return @($found)
}
function Invoke-InContainer([string]$Container, [string]$Python) {
    # python3 -c inside a running container (no shell, no quoting layers); JSON or text on stdout.
    return (Invoke-DockerCli @('exec', $Container, 'python3', '-c', $Python))
}
function ConvertFrom-ExecJson($Result) {
    try { return (ConvertFrom-Json -InputObject ($Result.Out -join "`n")) } catch { return $null }
}
function Get-ContainerHardening([string]$Container) {
    # What the engine was told to enforce on one container, read back with a docker inspect format
    # template: one line, the fields joined by '|', a list as 'item,item,'. (No double quote in the
    # template: Windows PowerShell 5.1 would hand it to docker stripped.) $null when it cannot be read.
    $format = '{{range .HostConfig.SecurityOpt}}{{.}},{{end}}|{{range .HostConfig.CapDrop}}{{.}},{{end}}|{{range .HostConfig.CapAdd}}{{.}},{{end}}|{{.HostConfig.Memory}}|{{json .HostConfig.PidsLimit}}|{{.HostConfig.ReadonlyRootfs}}|{{.Config.User}}'
    $r = Invoke-DockerCli @('inspect', '--format', $format, $Container)
    $line = [string](@($r.Out | Where-Object { @($_ -split '\|').Count -eq 7 }) | Select-Object -Last 1)
    if ($r.Code -ne 0 -or -not $line) { return $null }
    $f = @($line -split '\|')
    # Capability names as the kernel headers spell them, without the CAP_ some engines put in front.
    $caps = { param([string]$List) @($List -split ',' | ForEach-Object { $_.Trim().ToUpperInvariant() -replace '^CAP_', '' } | Where-Object { $_ } | Sort-Object) }
    $memory = [int64]0; [void][int64]::TryParse($f[3], [ref]$memory)
    $pids = [int64]0; [void][int64]::TryParse($f[4], [ref]$pids)
    return [pscustomobject]@{
        SecurityOpt = @($f[0] -split ',' | Where-Object { $_ })
        CapDrop     = @(& $caps $f[1])
        CapAdd      = @(& $caps $f[2])
        Memory      = $memory
        Pids        = $pids
        ReadOnly    = ($f[5] -eq 'true')
        User        = [string]$f[6]
    }
}
function ConvertFrom-CapHex([string]$Hex) {
    # A capability set as /proc/<pid>/status prints it (hex digits) as a number; $null when it is not one.
    if ($Hex -notmatch '^[0-9a-fA-F]{1,16}$') { return $null }
    return [Convert]::ToInt64($Hex, 16)
}

$stack = Join-Path $Work 'Stack'
$composeFile = Join-Path $stack 'docker-compose.yml'
$stackNames = @('open-webui', 'searxng', 'render-guard', 'deep-research')
$stackVolumes = @('open-webui', 'localai-deep-research')
$adminEmail = 'admin@localhost'
$adminPassword = 'Test-Password-123'
# The hardening every service must run with (docs/CONTAINER-HARDENING-PLAN.md). Each one drops ALL
# capabilities, gets back only CapAdd and cannot gain privileges; Memory and Pids are its limits.
# ReadOnly (root filesystem) and User only where the plan sets them.
$hardening = @{
    'open-webui'    = @{ Memory = 16GB; Pids = 4096; ReadOnly = $false; User = ''; CapAdd = @() }
    'searxng'       = @{ Memory = 2GB; Pids = 512; ReadOnly = $true; User = '977:977'; CapAdd = @() }
    'render-guard'  = @{ Memory = 512MB; Pids = 512; ReadOnly = $true; User = '65534:65534'; CapAdd = @() }
    'deep-research' = @{ Memory = 8GB; Pids = 2048; ReadOnly = $false; User = ''; CapAdd = @('CHOWN', 'DAC_OVERRIDE', 'FOWNER', 'SETGID', 'SETUID') }
}
# Their numbers in the kernel (linux/capability.h): the bit of each in the sets /proc/<pid>/status shows.
$capBits = @{ CHOWN = 0; DAC_OVERRIDE = 1; FOWNER = 3; SETGID = 6; SETUID = 7 }
# Run inside a container: what the kernel holds for a process started there now (/proc/self: the
# no-new-privileges flag and the capability bounding set, the most any process in it can ever hold)
# and for the service itself (PID 1: its user, its flag, the capabilities in effect).
$procView = "import json;r=lambda p:dict(l.split(':',1) for l in open(p).read().splitlines() if ':' in l);a=r('/proc/self/status');b=r('/proc/1/status');print(json.dumps({'nnp':a.get('NoNewPrivs','').strip(),'bnd':a.get('CapBnd','').strip(),'nnp1':b.get('NoNewPrivs','').strip(),'eff1':b.get('CapEff','').strip(),'uid1':(b.get('Uid','').split() or [''])[0]}))"

# ---- refuse to touch anything that is not this test's own ---------------------------------------
if ((Invoke-DockerCli @('info', '--format', '{{.ServerVersion}}')).Code -ne 0) { Write-Host 'Docker engine not reachable.' -ForegroundColor Red; exit 1 }
$taken = @((Invoke-DockerCli @('ps', '-a', '--format', '{{.Names}}')).Out | Where-Object { $stackNames -contains $_ }) +
    @((Invoke-DockerCli @('volume', 'ls', '--format', '{{.Name}}')).Out | Where-Object { $stackVolumes -contains $_ })
if ($taken.Count) {
    Write-Host "This Docker engine already has $($taken -join ', '): the stack test would take it down with its volumes. Run it on a clean engine only." -ForegroundColor Red
    exit 1
}
$started = $false
try {
    $ollamaVersion = [string](Get-LaiOllamaVersion -BaseUrl $OllamaUrl)
    Write-Host "Stand-in Ollama $ollamaVersion at $OllamaUrl"

    # ---- the stack folder and .env, as the installer writes them ----------------------------------
    Write-Host "`n=== stack folder and .env ===" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
    foreach ($d in 'render-guard', 'searxng') { New-Item -ItemType Directory -Force -Path (Join-Path $stack $d) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $src 'stack/docker-compose.yml') -Destination $stack -Force
    Copy-Item -LiteralPath (Join-Path $src 'stack/render-guard/render_guard.py') -Destination (Join-Path $stack 'render-guard') -Force
    $tpl = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $src 'stack/searxng/settings.yml') -Raw
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $stack 'searxng') 'settings.yml'), $tpl.Replace('__SEARXNG_SECRET__', 'stack-smoke-test-secret'), (New-Object System.Text.UTF8Encoding($false)))

    # The versions the installer pins are the ones it writes to .env; the compose file's own fallbacks must agree.
    $installerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Install-LocalAI.ps1'), [ref]$null, [ref]$null)
    $webuiTag = Get-InstallerDefault 'OpenWebUIVersion'
    $searxTag = Get-InstallerDefault 'SearxngVersion'
    $composeText = Get-Content -Encoding UTF8 -LiteralPath $composeFile -Raw
    $composeWebui = [regex]::Match($composeText, 'OPEN_WEBUI_VERSION:-([^}]+)\}').Groups[1].Value
    $composeSearx = [regex]::Match($composeText, 'SEARXNG_VERSION:-([^}]+)\}').Groups[1].Value
    Assert-That ($composeWebui -eq $webuiTag -and $composeSearx -eq $searxTag) "the compose file's fallback tags ($composeWebui, $composeSearx) are the ones the installer pins ($webuiTag, $searxTag)"

    $values = @{
        OPEN_WEBUI_VERSION   = $webuiTag
        SEARXNG_VERSION      = $searxTag
        WEBUI_PORT           = [string]$WebUIPort
        SEARXNG_PORT         = [string]$SearxngPort
        WEBUI_SECRET_KEY     = 'stack-smoke-test-key'
        WEBUI_ADMIN_EMAIL    = $adminEmail
        WEBUI_ADMIN_PASSWORD = $adminPassword
        OLLAMA_BASE_URL      = 'http://render-guard:11434'
        RENDER_GUARD_MODE    = 'cpu'
    }
    $research = Get-LaiDeepResearchEnv -Enabled ([bool]$DeepResearch) -Port $ResearchPort
    foreach ($k in $research.Keys) { $values[$k] = $research[$k] }
    $lines = foreach ($k in ($values.Keys | Sort-Object)) { "$k=$($values[$k])" }
    [System.IO.File]::WriteAllLines((Join-Path $stack '.env'), [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))

    # Which services this .env starts: no profile, or one of COMPOSE_PROFILES.
    $cfg = Get-DockerJson @('compose', '--project-directory', $stack, '-f', $composeFile, 'config', '--format', 'json')
    $active = @([string]$values['COMPOSE_PROFILES'] -split ',' | Where-Object { $_ })
    $expected = @()
    foreach ($svc in $cfg.services.PSObject.Properties) {
        $profiles = @(); if ($svc.Value.PSObject.Properties['profiles']) { $profiles = @($svc.Value.profiles) }
        if ($profiles.Count -eq 0 -or @($profiles | Where-Object { $active -contains $_ }).Count) { $expected += $svc.Name }
    }
    Assert-That ($expected -contains 'open-webui' -and $expected -contains 'render-guard' -and $expected -contains 'searxng' -and (($expected -contains 'deep-research') -eq [bool]$DeepResearch)) "the compose file starts: $($expected -join ', ')"

    # ---- pull and start ------------------------------------------------------------------------
    Write-Host "`n=== docker compose pull and up ===" -ForegroundColor Cyan
    Invoke-LaiRetry -What 'docker compose pull' -Attempts 3 -DelaySeconds 15 -Action {
        $pull = Invoke-Compose @('pull')
        if ($pull.Code -ne 0) { throw "exit $($pull.Code): $(@($pull.Out | Select-Object -Last 3) -join ' | ')" }
    } | Out-Null
    $started = $true
    $up = Invoke-Compose @('up', '-d', '--remove-orphans')
    Assert-That ($up.Code -eq 0) "docker compose up -d --remove-orphans starts the stack (exit $($up.Code))"
    if ($up.Code -ne 0) { throw "compose up failed: $(@($up.Out | Select-Object -Last 5) -join ' | ')" }

    # ---- every service running (healthy where there is a healthcheck) ---------------------------
    Write-Host "`n=== services ===" -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($StartTimeoutSec)
    $ready = $false
    $containers = @()
    while (-not $ready -and (Get-Date) -lt $deadline) {
        $containers = @(Get-StackContainers)
        $have = @($containers | ForEach-Object { Get-ServiceName $_ })
        $ready = (@($expected | Where-Object { $have -notcontains $_ }).Count -eq 0) -and (@($containers | Where-Object { -not (Test-ContainerReady $_) }).Count -eq 0)
        if (-not $ready) { Start-Sleep -Seconds 5 }
    }
    $notReady = @()
    foreach ($svc in $expected) {
        $c = @($containers | Where-Object { (Get-ServiceName $_) -eq $svc }) | Select-Object -First 1
        $what = 'missing'
        if ($c) {
            $what = [string]$c.State.Status
            if ($c.State.PSObject.Properties['Health'] -and $c.State.Health) { $what += ", health $($c.State.Health.Status)" } else { $what += ', no healthcheck' }
            $what += ", $([int]$c.RestartCount) restart(s)"
        }
        $isReady = [bool]($c -and (Test-ContainerReady $c))
        if (-not $isReady) { $notReady += $svc }
        Assert-That ($isReady -and [int]$c.RestartCount -eq 0) "service $svc is running, healthy where it has a healthcheck, and never restarted ($what)"
    }
    # Stop here when a service never came ready: everything below would wait out its own timeout
    # (minutes each) before the finally block prints the container logs, and the job's time limit
    # could end the run first, with the logs unread.
    if ($notReady.Count) { throw "not ready after $StartTimeoutSec seconds: $($notReady -join ', ')" }
    $owui = @($containers | Where-Object { (Get-ServiceName $_) -eq 'open-webui' }) | Select-Object -First 1
    $guard = @($containers | Where-Object { (Get-ServiceName $_) -eq 'render-guard' }) | Select-Object -First 1
    if (-not $owui -or -not $guard) { throw 'open-webui or render-guard is not there; the checks below need both' }
    Assert-That ($owui.Config.Image -eq "ghcr.io/open-webui/open-webui:$webuiTag" -and $guard.Config.Image -eq "searxng/searxng:$searxTag") "the images are the pinned ones ($($owui.Config.Image), $($guard.Config.Image))"

    # ---- container hardening: what the engine was told, and what the kernel holds ----------------
    # Every check further down (sign-in, searches, the way to Ollama) runs on containers that passed
    # this one: that is the proof the services work with the hardening on.
    Write-Host "`n=== container hardening ===" -ForegroundColor Cyan
    foreach ($svc in $expected) {
        $want = $hardening[$svc]
        Assert-That ($null -ne $want) "this test knows the hardening service $svc must run with (a new service gets its line in `$hardening)"
        if ($null -eq $want) { continue }
        $h = Get-ContainerHardening $svc
        Assert-That ($null -ne $h) "docker inspect shows the hardening of $svc"
        if ($null -eq $h) { continue }
        $wantAdd = (@($want.CapAdd | Sort-Object) -join ',')
        $addText = 'none'; if ($wantAdd) { $addText = $wantAdd }
        Assert-That (@($h.SecurityOpt | Where-Object { $_ -match '^no-new-privileges([:=]true)?$' }).Count -gt 0) "$svc cannot gain privileges: no-new-privileges is on (security options: $($h.SecurityOpt -join ', '))"
        Assert-That (($h.CapDrop -join ',') -eq 'ALL' -and ($h.CapAdd -join ',') -eq $wantAdd) "$svc drops ALL capabilities and gets back: $addText (dropped: $($h.CapDrop -join ','); added: $($h.CapAdd -join ','))"
        Assert-That ($h.Memory -eq $want.Memory) "$svc has a memory limit of $([int]($want.Memory / 1MB)) MB (the engine has $([int]($h.Memory / 1MB)) MB; 0 is no limit)"
        Assert-That ($h.Pids -eq $want.Pids) "$svc may run at most $($want.Pids) processes and threads (the engine has $($h.Pids); 0 is no limit)"
        if ($want.ReadOnly) { Assert-That $h.ReadOnly "$svc has a read-only root filesystem" }
        if ($want.User) { Assert-That ($h.User -eq $want.User) "$svc is started as the unprivileged user $($want.User) (configured user: '$($h.User)')" }

        # The same from inside: the kernel's own record, which no setting in between can misreport.
        $mask = [int64]0
        foreach ($cap in $want.CapAdd) { $mask = $mask -bor ([int64]1 -shl [int]$capBits[$cap]) }
        $maskText = '{0:x16}' -f $mask
        $r = Invoke-InContainer $svc $procView
        $seen = ConvertFrom-ExecJson $r
        $bnd = $null; $eff1 = $null
        if ($seen) { $bnd = ConvertFrom-CapHex ([string]$seen.bnd); $eff1 = ConvertFrom-CapHex ([string]$seen.eff1) }
        Assert-That ($r.Code -eq 0 -and $seen -and [string]$seen.nnp -eq '1' -and $null -ne $bnd -and $bnd -eq $mask) "inside $svc the kernel allows no new privileges (NoNewPrivs $($seen.nnp)) and no capability beyond: $addText (bounding set $($seen.bnd), expected $maskText; exit $($r.Code))"
        Assert-That ($seen -and [string]$seen.nnp1 -eq '1' -and $null -ne $eff1 -and ($eff1 -band (-bnot $mask)) -eq 0) "the $svc service itself (PID 1, uid $($seen.uid1)) holds no capability beyond: $addText (in effect $($seen.eff1)) and cannot gain privileges (NoNewPrivs $($seen.nnp1))"
        if ($want.User) {
            $wantUid = ($want.User -split ':')[0]
            Assert-That ($seen -and [string]$seen.uid1 -eq $wantUid) "the $svc service itself (PID 1) runs as uid $wantUid, not as root (uid $($seen.uid1))"
        }
    }

    # ---- ports: only 127.0.0.1 ------------------------------------------------------------------
    Write-Host "`n=== published ports ===" -ForegroundColor Cyan
    $published = @()
    foreach ($c in $containers) {
        foreach ($port in $c.NetworkSettings.Ports.PSObject.Properties) {
            foreach ($b in @($port.Value)) {
                if ($b) { $published += [pscustomobject]@{ Service = (Get-ServiceName $c); Target = $port.Name; HostIp = [string]$b.HostIp; HostPort = [int]$b.HostPort } }
            }
        }
    }
    $listing = (@($published | ForEach-Object { "$($_.Service) $($_.HostIp):$($_.HostPort)" }) -join ', ')
    $wantPorts = @($WebUIPort, $SearxngPort); if ($DeepResearch) { $wantPorts += $ResearchPort }
    $gotPorts = @($published | ForEach-Object { $_.HostPort })
    Assert-That ((@($wantPorts | Where-Object { $gotPorts -notcontains $_ }).Count -eq 0) -and (@($gotPorts | Where-Object { $wantPorts -notcontains $_ }).Count -eq 0)) "the stack publishes exactly the ports $($wantPorts -join ', ') ($listing)"
    Assert-That (@($published | Where-Object { $_.HostIp -ne '127.0.0.1' }).Count -eq 0) "every published port is bound to 127.0.0.1 only ($listing)"
    $others = @(Get-NonLoopbackAddress)
    foreach ($port in $wantPorts) {
        Assert-That (Test-TcpPort '127.0.0.1' $port) "port $port answers on 127.0.0.1"
        $open = @($others | Where-Object { Test-TcpPort $_ $port })
        Assert-That ($open.Count -eq 0) "port $port does not answer on this machine's other addresses ($($others -join ', '); open on: $($open -join ', '))"
    }

    # ---- Open WebUI --------------------------------------------------------------------------------
    # Root in its container but, as shown above, without a single capability: it must still start,
    # make the admin account, sign it in and answer.
    Write-Host "`n=== Open WebUI ===" -ForegroundColor Cyan
    $webui = "http://127.0.0.1:$WebUIPort"
    Wait-LaiWebUI -BaseUrl $webui -TimeoutSec 300
    $ver = [string](Invoke-LaiApi -Uri "$webui/api/version" -TimeoutSec 15).version
    Assert-That ($ver -eq $webuiTag.TrimStart('v')) "Open WebUI answers on port $WebUIPort with the pinned version ($ver)"
    $token = Connect-LaiWebUI -BaseUrl $webui -Email $adminEmail -Password $adminPassword
    Assert-That ([bool]$token) 'the admin account made from .env signs in'
    $oc = Invoke-LaiApi -Uri "$webui/ollama/config" -Token $token
    $urls = @($oc.OLLAMA_BASE_URLS | ForEach-Object { ([string]$_).TrimEnd('/') })
    Assert-That ($urls -contains 'http://render-guard:11434') "Open WebUI's Ollama connection is the render guard ($($urls -join ', '))"
    $viaWebui = Invoke-LaiApi -Uri "$webui/ollama/api/version" -Token $token -TimeoutSec 30
    Assert-That ([string]$viaWebui.version -eq $ollamaVersion) "Open WebUI reaches the stand-in Ollama through the guard (reports $($viaWebui.version), Ollama is $ollamaVersion)"

    # ---- render guard ------------------------------------------------------------------------------
    Write-Host "`n=== render guard ===" -ForegroundColor Cyan
    $r = Invoke-InContainer 'render-guard' "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:11434/render-guard/status',timeout=10).read().decode())"
    $status = ConvertFrom-ExecJson $r
    Assert-That ($r.Code -eq 0 -and $status -and $status.config.mode -eq 'cpu' -and $status.config.upstream -eq 'http://host.docker.internal:11434') "the render guard answers its status page (mode $($status.config.mode), upstream $($status.config.upstream))"
    $r = Invoke-InContainer 'render-guard' "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:11434/api/version',timeout=10).read().decode())"
    $guardVer = ConvertFrom-ExecJson $r
    Assert-That ($r.Code -eq 0 -and $guardVer -and [string]$guardVer.version -eq $ollamaVersion) "the guard reaches Ollama on the host: /api/version through it is $ollamaVersion (exit $($r.Code), $(@($r.Out | Select-Object -Last 1) -join ''))"
    $r = Invoke-InContainer 'render-guard' 'import os;print(os.getuid())'
    Assert-That ($r.Code -eq 0 -and (@($r.Out) -join '').Trim() -eq '65534') "the guard runs as the unprivileged user 65534 (uid $((@($r.Out) -join '').Trim()))"
    $r = Invoke-InContainer 'open-webui' "import urllib.request;print(urllib.request.urlopen('http://render-guard:11434/api/version',timeout=10).read().decode())"
    $fromWebui = ConvertFrom-ExecJson $r
    Assert-That ($r.Code -eq 0 -and $fromWebui -and [string]$fromWebui.version -eq $ollamaVersion) "the Open WebUI container reaches Ollama as render-guard:11434 (exit $($r.Code))"

    # ---- SearXNG -----------------------------------------------------------------------------------
    Write-Host "`n=== SearXNG ===" -ForegroundColor Cyan
    $sx = $null; $sxErr = ''
    try { $sx = Get-LaiSearxngProbe -BaseUrl "http://127.0.0.1:$SearxngPort" } catch { $sxErr = $_.Exception.Message }
    $sxSummary = $sxErr; if ($sx) { $sxSummary = [string]$sx.Summary }
    Assert-That ($null -ne $sx) "SearXNG answers on port $SearxngPort, /healthz and a JSON search ($sxSummary)"
    $r = Invoke-InContainer 'open-webui' "import urllib.request;print(urllib.request.urlopen('http://searxng:8080/healthz',timeout=10).status)"
    Assert-That ($r.Code -eq 0 -and (@($r.Out) -join '').Trim() -eq '200') "the Open WebUI container reaches SearXNG as searxng:8080 (exit $($r.Code))"
    # It answered that search as its unprivileged user on a read-only filesystem: asked of the
    # kernel inside the container (/proc/mounts: file system type and 'ro' or 'rw' per mount).
    # settings.yml comes from a read-only mount; /tmp, where its SQLite caches go, is a tmpfs of
    # its own that its user can write.
    $r = Invoke-InContainer 'searxng' "import json,os;m=[l.split() for l in open('/proc/mounts')];f=lambda p:[x[2]+' '+x[3].split(',')[0] for x in m if x[1]==p];print(json.dumps({'uid':os.getuid(),'root':f('/'),'etc':f('/etc/searxng'),'tmp':f('/tmp'),'tmpw':os.access('/tmp',os.W_OK),'settings':os.access('/etc/searxng/settings.yml',os.R_OK)}))"
    $fs = ConvertFrom-ExecJson $r
    $rootFs = ''; $etcFs = ''; $tmpFs = ''
    if ($fs) {
        $rootFs = [string](@($fs.root) | Select-Object -Last 1)
        $etcFs = [string](@($fs.etc) | Select-Object -Last 1)
        $tmpFs = [string](@($fs.tmp) | Select-Object -Last 1)
    }
    Assert-That ($r.Code -eq 0 -and $fs -and [string]$fs.uid -eq '977' -and $rootFs -match ' ro$' -and $etcFs -match ' ro$' -and $fs.settings -eq $true) "SearXNG works as uid $($fs.uid) on a read-only filesystem: / is '$rootFs', /etc/searxng is '$etcFs', settings.yml can be read: $($fs.settings) (exit $($r.Code))"
    Assert-That ($fs -and $tmpFs -eq 'tmpfs rw' -and $fs.tmpw -eq $true) "SearXNG has a /tmp of its own for its caches ('$tmpFs', writable by its user: $($fs.tmpw))"
    # Its log, from the start through that search: nothing that says a file could not be written or
    # a privilege is missing. The entrypoint's warning that /etc/searxng is not owned by its user is
    # expected (as root it changed the owner; unprivileged it cannot and need not). What single
    # search engines answer is not judged here: they often refuse a test machine.
    $sxLog = @((Invoke-DockerCli @('logs', 'searxng')).Out)
    $sxBad = @($sxLog | Where-Object { $_ -match '(?i)!!!\s*ERROR|permission denied|read-only file system|operation not permitted|unable to open database|readonly database' })
    $sxOwner = @($sxLog | Where-Object { $_ -match '(?i)not owned by' }).Count
    Assert-That ($sxLog.Count -gt 0 -and $sxBad.Count -eq 0) "SearXNG's log ($($sxLog.Count) lines, $sxOwner with the expected ownership warning) names no file it could not write and no missing privilege ($(@($sxBad | Select-Object -First 3) -join ' | '))"

    # ---- deep research (optional service) --------------------------------------------------------
    if ($DeepResearch) {
        Write-Host "`n=== deep research ===" -ForegroundColor Cyan
        $drUp = $false; $drErr = ''
        try { Wait-LaiHttp -Uri "http://127.0.0.1:$ResearchPort/api/v1/health" -TimeoutSec 120 | Out-Null; $drUp = $true } catch { $drErr = $_.Exception.Message }
        Assert-That $drUp "deep research answers on port $ResearchPort ($drErr)"
        $reach = Test-LaiResearchOllama -OllamaUrl 'http://render-guard:11434' -Container 'deep-research'
        Assert-That $reach.Ok "the deep research container reaches Ollama through the guard ($($reach.Message))"
    }

    # ---- after all of the above: no limit ended a container --------------------------------------
    Write-Host "`n=== after the checks ===" -ForegroundColor Cyan
    foreach ($svc in $expected) {
        $r = Invoke-DockerCli @('inspect', '--format', '{{.State.Status}}|{{.State.OOMKilled}}|{{.RestartCount}}', $svc)
        $state = [string](@($r.Out) | Select-Object -Last 1)
        Assert-That ($r.Code -eq 0 -and $state -eq 'running|false|0') "after every check $svc is still running, was never ended for exceeding its memory limit and never restarted (state|out of memory|restarts: $state)"
    }
} catch {
    Write-Host "  ASSERT FAIL the stack test stopped early: $($_.Exception.Message)" -ForegroundColor Red
    $failures++
} finally {
    if ($started) {
        if ($failures -gt 0) {
            Write-Host "`n=== what the containers say (before they are removed) ===" -ForegroundColor Yellow
            foreach ($section in @(@('ps', '-a'), @('logs', '--no-color', '--tail', '60'))) { (Invoke-Compose $section).Out | ForEach-Object { Write-Host "  $_" } }
        }
        Write-Host "`n=== taking the stack down ===" -ForegroundColor Cyan
        $down = Invoke-Compose @('down', '--volumes', '--remove-orphans')
        Assert-That ($down.Code -eq 0) "docker compose down --volumes --remove-orphans (exit $($down.Code): $(@($down.Out | Select-Object -Last 2) -join ' | '))"
        $left = @((Invoke-DockerCli @('ps', '-a', '--format', '{{.Names}}')).Out | Where-Object { $stackNames -contains $_ }) +
            @((Invoke-DockerCli @('volume', 'ls', '--format', '{{.Name}}')).Out | Where-Object { $stackVolumes -contains $_ }) +
            @((Invoke-DockerCli @('network', 'ls', '--format', '{{.Name}}', '--filter', 'label=com.docker.compose.project=localai')).Out | Where-Object { $_ })
        Assert-That ($left.Count -eq 0) "nothing of the stack is left: containers, volumes, network ($($left -join ', '))"
    }
}
Write-Host ''
if ($failures -eq 0) { Write-Host 'STACK SMOKE TEST PASSED' -ForegroundColor Green } else { Write-Host "STACK SMOKE TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
