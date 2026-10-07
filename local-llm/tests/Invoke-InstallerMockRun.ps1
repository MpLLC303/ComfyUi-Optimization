<#
.SYNOPSIS
    Runs Install-LocalAI.ps1 end to end on a non-Windows box with the Windows-only commands mocked,
    to exercise the orchestration logic: stage order, state file, reboot + resume via the logon task,
    legacy-container migration, .env/secret handling, backup task, report, and idempotent re-runs.

.DESCRIPTION
    Real:   Ollama API, Open WebUI API (running natively), Docker engine (ps/rm/run/volume, backups).
    Mocked: winget, wsl.exe, icacls, shutdown, nvidia-smi, CIM/registry/optional-feature cmdlets,
            local groups, scheduled tasks, Start-Process/explorer, docker compose, docker exec probe.
    A patched copy of the installer replaces four Windows-only expressions (admin check, user
    name/SID, OS build, drive free space). Nothing else in the installer is changed.

    Prerequisites: same as Invoke-IntegrationTest.ps1, plus a running SearXNG container is optional.
#>
param(
    [string]$Work = '/home/user/lai-test/mockroot',
    [string]$Email = 'admin@localhost',
    [string]$Password = 'Test-Password-123'
)
$ErrorActionPreference = 'Stop'
# Refuses to run anywhere but a throwaway test machine (it would delete a real install's data).
if (-not (& (Join-Path $PSScriptRoot 'Assert-LaiSandbox.ps1'))) { exit 99 }
$src = Split-Path -Parent $PSScriptRoot
$failures = 0
function Assert-That([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  ASSERT OK   $Message" -ForegroundColor Green }
    else { Write-Host "  ASSERT FAIL $Message" -ForegroundColor Red; $script:failures++ }
}

# ---- sandbox layout ------------------------------------------------------------------------
if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
$copy = Join-Path $Work 'src/local-llm'
New-Item -ItemType Directory -Force -Path $copy | Out-Null
Copy-Item -Path (Join-Path $src '*') -Destination $copy -Recurse -Force
$aiRoot = Join-Path $Work 'AI'
foreach ($d in 'LocalAppData/Ollama', 'ProgramFiles', 'Windows', 'Users/testuser', 'AI/Secrets') { New-Item -ItemType Directory -Force -Path (Join-Path $Work $d) | Out-Null }
$env:LOCALAPPDATA = Join-Path $Work 'LocalAppData'
$env:ProgramFiles = Join-Path $Work 'ProgramFiles'
$env:WINDIR = Join-Path $Work 'Windows'
# conhost.exe present (as on Windows 10 2004+): scheduled tasks must then run with no window at all.
New-Item -ItemType Directory -Force -Path (Join-Path $Work 'Windows/System32') | Out-Null
Set-Content -LiteralPath (Join-Path $Work 'Windows/System32/conhost.exe') -Value 'x'
# The same path spelled the way the module builds it, whichever way this platform reads its backslash.
[System.IO.File]::WriteAllText((Join-Path $env:WINDIR 'System32\conhost.exe'), 'x')
$env:USERPROFILE = Join-Path $Work 'Users/testuser'
$env:SystemDrive = 'C:'
$env:ProgramData = Join-Path $Work 'ProgramData'
$env:LOCALAI_TEST_CATALOG = Join-Path $copy 'tests/models.test.psd1'
$env:LOCALAI_TEST_ALLOW_CPU = '1'
# Open WebUI talks to Ollama through the real render guard, as in the stack (started here with the
# local python3 because docker compose is mocked). Its request counter proves traffic went through it.
$env:LOCALAI_TEST_WEBUI_OLLAMA_URL = 'http://127.0.0.1:11435'
$guardStatus = 'http://127.0.0.1:11435/render-guard/status'
# Always this checkout's guard: one left running by an earlier run may be older code.
& /bin/sh -c "pkill -f 'render-guard/render_guard[.]py' ; true"
$guardProc = Start-Process -FilePath 'python3' -ArgumentList @('-u', "$src/stack/render-guard/render_guard.py") -PassThru -RedirectStandardOutput (Join-Path $Work 'render-guard.log') -RedirectStandardError (Join-Path $Work 'render-guard.err') -Environment @{ UPSTREAM = 'http://127.0.0.1:11434'; COMFYUI_URLS = 'http://127.0.0.1:18188'; LISTEN_PORT = '11435' }
$guardBefore = $null
for ($i = 0; $i -lt 60 -and $null -eq $guardBefore -and -not $guardProc.HasExited; $i++) {
    try { $guardBefore = [int](Invoke-RestMethod $guardStatus -TimeoutSec 2).stats.requests } catch { Start-Sleep -Milliseconds 500 }
}
if ($null -eq $guardBefore) { Write-Host "render guard did not start: $(Get-Content -Raw (Join-Path $Work 'render-guard.err'))" -ForegroundColor Red; exit 1 }

# The sandbox Open WebUI already has an admin; give the installer its credentials.
ConvertTo-Json @{ email = $Email; password = $Password } | Set-Content (Join-Path $aiRoot 'Secrets/openwebui-admin.json')
# Ollama's server log with the settings line the installer verifies.
$cfgLine = (& /usr/bin/docker logs ollama-test 2>&1 | Where-Object { "$_" -match 'msg="server config"' } | Select-Object -Last 1)
# As on a Windows PC: Ollama on loopback, models in the folder the installer plans (the default under
# the user profile; slog doubles backslashes). The container's own 0.0.0.0 and /root/.ollama/models
# would read as the Ollama app's 'Expose' and 'Model location' settings overriding the installer's.
$plannedModels = Join-Path $env:USERPROFILE '.ollama\models'
$cfgLine = ("$cfgLine" -replace 'OLLAMA_MODELS:[^ \]]*', ('OLLAMA_MODELS:' + $plannedModels.Replace('\', '\\'))) -replace 'OLLAMA_HOST:[^ \]]*', 'OLLAMA_HOST:http://127.0.0.1:11434'
Set-Content (Join-Path $env:LOCALAPPDATA 'Ollama/server.log') "$cfgLine"
# A "manual install" container + volume, as left behind by the guide's docker run.
& /usr/bin/docker rm -f open-webui 2>$null | Out-Null
& /usr/bin/docker ps -aq --filter 'name=^/open-webui-legacy-' | ForEach-Object { & /usr/bin/docker rm -f $_ | Out-Null }
# It uses a differently named volume ('owui-old'), so the installer has to find and copy the data.
& /usr/bin/docker volume rm open-webui owui-old 2>$null | Out-Null
& /usr/bin/docker volume create owui-old | Out-Null
& /usr/bin/docker run --rm -v owui-old:/data alpine:3.20 sh -c 'head -c 65536 /dev/urandom > /data/webui.db; echo legacy-marker > /data/marker.txt' | Out-Null
& /usr/bin/docker run -d --restart always --label lai-test=1 --name open-webui -v owui-old:/app/backend/data alpine:3.20 sleep 3600 | Out-Null

# Everything below runs in try/finally: the container above has restart=always and comes back after
# a reboot, and the shared Open WebUI must not keep pointing at this run's render guard.
try {

# The sandbox's own SearXNG container is not part of the simulated PC (compose is mocked here): park
# it under the name Reset-Sandbox restores, so the installer's check for a 'searxng' container of
# another setup sees only what a phase puts there. A rename keeps it running.
$parkedSearxng = $false
if (@(& /usr/bin/docker ps -a --filter 'name=^/searxng$' --format '{{.Names}}') -contains 'searxng') {
    & /usr/bin/docker rename searxng searxng-uninstall-test-keep | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'could not move the sandbox searxng container aside' }
    $parkedSearxng = $true
}

# ---- patched installer copy ----------------------------------------------------------------
$inst = Join-Path $copy 'Install-LocalAI.ps1'
$text = Get-Content -Raw $inst
$patches = @(
    @('$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())', '$p = $null'),
    @('return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)', 'return (-not $env:LOCALAI_MOCK_NOT_ADMIN)'),
    @('[Security.Principal.WindowsIdentity]::GetCurrent().Name', "'MOCKPC\testuser'"),
    @('[Security.Principal.WindowsIdentity]::GetCurrent().User.Value', "'S-1-5-21-1-2-3-1001'"),
    @('[Environment]::OSVersion.Version.Build', '22631'),
    # A fixed free-space figure ($global:MockFreeBytes): the sandbox's real one is often under 5 GB.
    @('$qualifier = Split-Path -Qualifier $Path', 'return [Math]::Round($global:MockFreeBytes / 1GB, 1)')
)
foreach ($p in $patches) {
    if (-not $text.Contains($p[0])) { throw "patch target not found: $($p[0])" }
    $text = $text.Replace($p[0], $p[1])
}
Set-Content -Path $inst -Value $text

# ---- mocks ----------------------------------------------------------------------------------
$global:Calls = New-Object System.Collections.ArrayList
$global:Tasks = @{}
$global:ConsoleUser = 'MOCKPC\testuser'
$global:TaskPrincipals = @{}
$global:TaskExec = @{}
$global:TaskTriggerArgs = @{}
$global:TaskSettingsArgs = @{}
$global:WslInstalled = $false
function global:Record([string]$s) { [void]$global:Calls.Add($s) }
# Other hardware for the later phases: $global:MockGpu = nvidia-smi line(s) or 'none' (no GPU, exit 6),
# $global:MockVideo = the display adapters Windows lists, $global:MockRamBytes = installed RAM.
$global:MockGpu = $null
$global:MockVideo = @('NVIDIA GeForce RTX 3090')
$global:MockRamBytes = 64GB
$global:MockFreeBytes = 60GB
function global:nvidia-smi {
    if ($global:MockGpu -eq 'none') { $global:LASTEXITCODE = 6; 'No devices were found'; return }
    $global:LASTEXITCODE = 0
    if ($global:MockGpu) { $global:MockGpu } else { 'NVIDIA GeForce RTX 3090, 566.36, 24576, 1200, 23376' }
}
function global:Get-CimInstance {
    param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    # A fixed figure: the sandbox's real free space (often under 5 GB) would make the installer's
    # per-model 5 GB margin, not the missing tag under test, decide whether a pull is even tried.
    $free = $global:MockFreeBytes
    switch ($ClassName) {
        'Win32_LogicalDisk' { [pscustomobject]@{ DeviceID = 'C:'; FreeSpace = $free } }
        'Win32_ComputerSystem' { [pscustomobject]@{ TotalPhysicalMemory = $global:MockRamBytes; HypervisorPresent = $true; UserName = $global:ConsoleUser } }
        'Win32_VideoController' { foreach ($n in @($global:MockVideo)) { [pscustomobject]@{ Name = $n } } }
        'Win32_Processor' { [pscustomobject]@{ Name = 'AMD Ryzen 9 9950X3D 16-Core Processor'; VirtualizationFirmwareEnabled = $true } }
    }
}
function global:Get-ItemProperty { param($Path) [pscustomobject]@{ DisplayVersion = '24H2'; UBR = 4317 } }
function global:Set-ItemProperty { param($Path, $Name, $Value) Record "Set-ItemProperty $Name=$Value" }
function global:Get-WindowsOptionalFeature { param([switch]$Online, $FeatureName) [pscustomobject]@{ State = 'Enabled' } }
function global:Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $false } }
function global:wsl.exe {
    Record "wsl $($args -join ' ')"
    if ($args[0] -eq '--version') {
        if ($global:WslInstalled) { $global:LASTEXITCODE = 0; 'WSL version: 2.5.10.0'; 'Kernel version: 6.6.87.2-1' } else { $global:LASTEXITCODE = 1; 'Usage: wsl.exe [Argument]' }
        return
    }
    $global:LASTEXITCODE = 0
}
function global:winget {
    Record "winget $($args -join ' ')"
    $id = $args[[array]::IndexOf($args, '--id') + 1]
    if ($id -eq 'Ollama.Ollama') {
        $d = Join-Path $env:LOCALAPPDATA 'Programs/Ollama'; New-Item -ItemType Directory -Force $d | Out-Null
        'x' | Set-Content (Join-Path $d 'ollama.exe'); 'x' | Set-Content (Join-Path $d 'ollama app.exe')
    }
    if ($id -eq 'Docker.DockerDesktop') {
        $d = Join-Path $env:ProgramFiles 'Docker/Docker'; New-Item -ItemType Directory -Force $d | Out-Null
        'x' | Set-Content (Join-Path $d 'Docker Desktop.exe')
    }
    $global:LASTEXITCODE = 0
}
function global:icacls.exe { Record "icacls $($args -join ' ')"; $global:LASTEXITCODE = 0 }
function global:shutdown.exe { Record "shutdown $($args -join ' ')"; $global:LASTEXITCODE = 0 }
function global:Get-LocalGroup { param($Name) [pscustomobject]@{ Name = $Name } }
function global:Add-LocalGroupMember { param($Group, $Member) Record "Add-LocalGroupMember $Group $Member" }
function global:Get-NetTCPConnection { $null }
# On this host the containerised Ollama shows up in the process table; the installer must not kill it.
function global:Get-Process { param($Name, $Id, $ErrorAction) Record "Get-Process $Name" }
function global:Stop-Process { Record 'Stop-Process' }
function global:New-ScheduledTaskAction { param($Execute, $Argument) [pscustomobject]@{ Execute = $Execute; Argument = $Argument } }
function global:New-ScheduledTaskTrigger { [pscustomobject]@{ Args = "$args" } }
function global:New-ScheduledTaskPrincipal { [pscustomobject]@{ Args = "$args" } }
function global:New-ScheduledTaskSettingsSet { [pscustomobject]@{ Args = "$args" } }
function global:Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $Principal, $Settings, [switch]$Force)
    $global:Tasks[$TaskName] = $Action.Argument; $global:TaskPrincipals[$TaskName] = [string]$Principal.Args; $global:TaskExec[$TaskName] = [string]$Action.Execute
    $global:TaskTriggerArgs[$TaskName] = (@($Trigger) | ForEach-Object { [string]$_.Args }) -join ' | '
    $global:TaskSettingsArgs[$TaskName] = [string]$Settings.Args
    Record "Register-ScheduledTask $TaskName"
}
function global:Unregister-ScheduledTask { param($TaskName, $Confirm) $global:Tasks.Remove($TaskName); Record "Unregister-ScheduledTask $TaskName" }
function global:Start-Process { param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $Verb, $ErrorAction) Record "Start-Process $FilePath $ArgumentList"; if ($Verb -eq 'RunAs') { Record "RUNAS $($ArgumentList -join ' ')" }; if ($PassThru) { [pscustomobject]@{ ExitCode = 0 } } }
function global:docker {
    $a = @($args)
    if ($a[0] -eq 'compose') { Record "docker $($a -join ' ')"; $global:LASTEXITCODE = 0; return }
    if ($a[0] -eq 'exec' -and $a[1] -eq 'open-webui') { $global:LASTEXITCODE = 0; return '{"version":"0.35.1"}' }
    & /usr/bin/docker @a
}

# ---- phase 1: fresh install until WSL needs a reboot ----------------------------------------
Write-Host "`n=== PHASE 1: fresh run (expects reboot request) ===" -ForegroundColor Cyan
# 'trial-ok,trial-missing' as ONE string, the way Install-LocalAI.cmd (powershell -File) delivers it.
# The U+2019 apostrophe must survive the quoting of the resume task's command line (PowerShell ends
# a single-quoted string at it too).
& $inst -AIRoot $aiRoot -SkipTests -TrialModels 'trial-ok,trial-missing' -KeepAlive 7m -BackupRetentionDays 9 -SkipCoder:$false -KnowledgeCollections "PC & Electronics,Dad$([char]0x2019)s References"
$code1 = $LASTEXITCODE
$state = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
Assert-That ($code1 -eq 3010) "phase 1 exits 3010 for reboot (got $code1)"
Assert-That ($global:Tasks.ContainsKey('LocalAI-Install-Resume')) 'resume task registered'
Assert-That ([string]$global:TaskPrincipals['LocalAI-Install-Resume'] -match 'Limited' -and [string]$global:TaskPrincipals['LocalAI-Install-Resume'] -notmatch 'Highest') 'resume task is not elevated (the installer asks with a UAC prompt)'
Assert-That ($global:Tasks['LocalAI-Install-Resume'] -match '-SkipCoder:\$false') 'an explicit false switch survives the reboot/resume relaunch'
Assert-That ($global:Tasks['LocalAI-Install-Resume'] -match "-Resume" -and $global:Tasks['LocalAI-Install-Resume'] -match [regex]::Escape((Join-Path $env:ProgramFiles 'LocalAI'))) 'resume task runs the administrators-only copy in Program Files\LocalAI with -Resume'
Assert-That (@($global:Calls | Where-Object { $_ -like 'shutdown /r /t 60*' }).Count -eq 1) 'reboot scheduled with 60 s warning'
Assert-That ($null -ne $state.stages.Tuning -and $null -eq $state.stages.WSL) 'stages up to Tuning done, WSL pending'
Assert-That (Test-Path (Join-Path $aiRoot 'Scripts/lib/LocalAI.psm1')) 'scripts copied to AI\Scripts'
# The rules for an AI agent opened in the install folder (config\agent-rules.md): a first install places
# the template as AI\CLAUDE.md, byte for byte, and its log says that it was placed.
$agentFile = Join-Path $aiRoot 'CLAUDE.md'
$agentTemplate = Join-Path (Join-Path $src 'config') 'agent-rules.md'
$agentLog1 = (@(Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log') | ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName }) -join "`n"
Assert-That ((Test-Path -LiteralPath $agentFile -PathType Leaf) -and (Get-FileHash -LiteralPath $agentFile).Hash -eq (Get-FileHash -LiteralPath $agentTemplate).Hash) 'a fresh install places config\agent-rules.md as AI\CLAUDE.md, byte for byte'
Assert-That ($agentLog1 -match 'Rules for an AI agent opened in this folder placed' -and $agentLog1 -notmatch 'already exists: left as it is') 'the install log says the rules file was placed (and not that one was already there)'
Assert-That (Test-Path -LiteralPath (Join-Path (Join-Path $aiRoot 'Scripts') 'config/agent-rules.md')) 'the template travels to AI\Scripts\config with the other config files (the toolkit copy)'
# But under another name: an agent that reads a file in a subfolder loads a CLAUDE.md there as rules
# too, and the owner can neither edit the copy in Scripts (read-only, replaced by every update) nor
# remove it. The only CLAUDE.md the installer creates is the owner's, in the install folder.
$agentStray = @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Scripts') -Recurse -File -Force | Where-Object { $_.Name -ieq 'CLAUDE.md' } | ForEach-Object { $_.FullName })
Assert-That ($agentStray.Count -eq 0) "no CLAUDE.md in the toolkit copy in AI\Scripts: only the one in the install folder is read as rules ($($agentStray -join ', '))"
$agentStrayRepo = @(Get-ChildItem -LiteralPath (Join-Path $src 'config') -Recurse -File -Force | Where-Object { $_.Name -ieq 'CLAUDE.md' } | ForEach-Object { $_.FullName })
Assert-That ($agentStrayRepo.Count -eq 0) "no CLAUDE.md in the toolkit's config folder either: a session that reads config\models.psd1 would load it ($($agentStrayRepo -join ', '))"
# The template itself: what the agent is told must stay true of this toolkit.
$agentText = Get-Content -Raw -Encoding UTF8 -LiteralPath $agentTemplate
Assert-That ($agentText -cnotmatch '[^\x00-\x7F]') 'the rules template is ASCII only'
$agentSections = @('## Never', '## Fine without asking', '## Ask first', '## Reporting', '## Where things are')
$agentMissing = @($agentSections | Where-Object { $agentText -notmatch ('(?m)^' + [regex]::Escape($_) + '\s*$') })
Assert-That ($agentMissing.Count -eq 0) "the rules template has all five sections ($($agentMissing -join ', ') missing)"
$agentNever = [regex]::Match($agentText, '(?s)## Never(.*?)## Fine without asking').Groups[1].Value
$agentNotNever = @('Reset-Sandbox.ps1', 'Invoke-AllTests.ps1', 'docker rm', 'docker volume rm', 'docker compose down -v', 'docker system prune', 'Uninstall-LocalAI.ps1', 'Restore-OpenWebUI.ps1', 'Backups', 'Secrets') | Where-Object { $agentNever -notmatch [regex]::Escape($_) }
Assert-That (@($agentNotNever).Count -eq 0) "everything destructive is under Never ($(@($agentNotNever) -join ', ') missing)"
$agentFine = [regex]::Match($agentText, '(?s)## Fine without asking(.*?)## Ask first').Groups[1].Value
$agentNotFine = @('Test-LocalAI.ps1 -Quick', 'Test-PCSecurity.ps1', 'install-report.md', 'localai-config.json', 'docker ps', 'docker logs --tail 100', 'nvidia-smi', 'ollama ps', 'ollama list') | Where-Object { $agentFine -notmatch [regex]::Escape($_) }
Assert-That (@($agentNotFine).Count -eq 0) "the read-only checks are under Fine without asking ($(@($agentNotFine) -join ', ') missing)"
# Every script it names exists in this toolkit (a renamed script would leave the agent a dead rule).
$agentNamed = @([regex]::Matches($agentText, '[A-Za-z][A-Za-z0-9-]*\.ps1') | ForEach-Object { $_.Value } | Select-Object -Unique)
$agentUnknown = @($agentNamed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $src $_)) -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $src 'tests') $_)) })
Assert-That ($agentNamed.Count -ge 9 -and $agentUnknown.Count -eq 0) "every script the rules name exists in the toolkit ($($agentNamed.Count) named; unknown: $($agentUnknown -join ', '))"
# An install in another folder (-AIRoot): the scripts the agent may run default to C:\AI, so the rules
# must tell it to pass the folder on. Each script the note lists really takes -AIRoot.
$agentIntro = [regex]::Match($agentText, '(?s)^(.*?)## Never').Groups[1].Value
$agentRootScripts = @('Test-LocalAI.ps1', 'Test-PCSecurity.ps1', 'Start-LocalAI.ps1', 'Stop-LocalAI.ps1')
$agentRootBad = @($agentRootScripts | Where-Object { $agentIntro -notmatch [regex]::Escape($_) -or (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $src $_)) -cnotmatch '\[string\]\$AIRoot\s*=' })
Assert-That ($agentIntro -match [regex]::Escape('-AIRoot <that folder>') -and $agentRootBad.Count -eq 0) "the rules tell the agent to pass -AIRoot to the scripts when the install is elsewhere (not covered: $($agentRootBad -join ', '))"

# ---- phase 2: resume after "reboot" ----------------------------------------------------------
# ---- phase 1b: the (non-elevated) resume task at sign-in asks for admin rights --------------
Write-Host "`n=== PHASE 1b: resume task at sign-in, not elevated ===" -ForegroundColor Cyan
$resumeCmd = $global:Tasks['LocalAI-Install-Resume']
$cmd = $resumeCmd.Substring($resumeCmd.IndexOf('-Command ') + 9)
$env:LOCALAI_MOCK_NOT_ADMIN = '1'
Invoke-Expression $cmd
$code1b = $LASTEXITCODE
$env:LOCALAI_MOCK_NOT_ADMIN = ''
$runas = @($global:Calls | Where-Object { $_ -like 'RUNAS *' }) | Select-Object -Last 1
Assert-That ($code1b -eq 10 -and $runas) "not elevated: relaunches through a UAC prompt (exit $code1b)"
Assert-That ($runas -match '-Resume' -and $runas -match [regex]::Escape((Join-Path $env:ProgramFiles 'LocalAI'))) 'the elevated relaunch keeps -Resume (2-strike limit) and runs the Program Files copy'

Write-Host "`n=== PHASE 2: resume after reboot ===" -ForegroundColor Cyan
# What older versions on Windows PowerShell 5.1 left behind: the installer's OWN container, renamed
# as if it were a manual install (compose labels intact). It must go; the manual one must stay.
& /usr/bin/docker create --name open-webui-legacy-20250101000000 --label lai-test=1 --label com.docker.compose.project=localai --label com.docker.compose.service=open-webui alpine:3.20 true | Out-Null
$global:WslInstalled = $true
Invoke-Expression $cmd
$code2 = $LASTEXITCODE
$state = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$envFile = Get-Content -Encoding UTF8 (Join-Path $aiRoot 'Stack/.env')
Assert-That ($code2 -eq 0) "phase 2 completes (exit $code2)"
foreach ($s in 'Preflight', 'Ollama', 'Models', 'Tuning', 'WSL', 'Docker', 'Stack', 'Configure', 'Backup') { Assert-That ($null -ne $state.stages.$s) "stage $s recorded" }
Assert-That (-not $global:Tasks.ContainsKey('LocalAI-Install-Resume')) 'resume task removed at the end'
$seededSkills = @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Skills') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
Assert-That ($seededSkills.Count -eq 3 -and $seededSkills -contains 'remember-and-improve') "the first install creates AI\Skills with the starter skills ($($seededSkills -join ', '))"
Import-Module (Join-Path $copy 'lib/LocalAI.psm1') -Force
# The finished install recorded the baseline the health watch compares with, and nothing differs
# from it right afterwards: an install is never reported as a change. (Scheduled tasks cannot be
# read on this machine and are skipped on both sides; the Windows unit tests read real ones.)
$igDiffs = {
    $b = Read-LaiIntegrityBaseline -AIRoot $aiRoot
    if (-not $b) { return @('no baseline') }
    @(Compare-LaiIntegrity -Baseline $b -Current (Get-LaiIntegritySnapshot -AIRoot $aiRoot) -WatchedPorts (Get-LaiIntegrityPorts -AIRoot $aiRoot) | Where-Object { [string]$_.Id -match '^(files?[+-]?|env[+-]?|task[+-]?|walk)\|' } | ForEach-Object { [string]$_.Text })
}
$base2 = Read-LaiIntegrityBaseline -AIRoot $aiRoot
$base2Files = @(); if ($base2 -and $base2['files'] -is [hashtable]) { $base2Files = @($base2['files'].Keys) }
Assert-That ($base2 -and [string]$base2['reason'] -eq 'install' -and [string]$base2['id'] -and $base2Files -contains 'Scripts\lib\LocalAI.psm1' -and $base2Files -contains 'Stack\docker-compose.yml' -and -not [string]$base2['filesStopped']) "the finished install recorded an integrity baseline with reason 'install' that lists the installed scripts and the stack files ($($base2Files.Count) files)"
Assert-That (@($base2Files | Where-Object { $_ -match '(^|\\)\.env$|\\Secrets\\|\.log$' }).Count -eq 0 -and $base2 -and @($base2['accepted'] | Where-Object { $_ -is [hashtable] }).Count -eq 0) 'not .env, logs or anything under a Secrets folder; and a first install took nothing in that it did not put there'
$igNow = @(& $igDiffs)
Assert-That ($igNow.Count -eq 0) "right after the install no file, setting or task differs from that baseline ($($igNow -join '; '))"
# Every phase here passes -SkipTests, so the installer's Verify stage (the health check, which then
# prints 'SKIP Integrity watch: an install, update or model update is running') never runs in this
# suite; Invoke-WatchTest.ps1 section 10 runs that case with a stand-in for the installer. What
# makes it true is read from the installer instead: it takes the setup lock into $script:SetupLock,
# runs the health check in its own process (not a child, which could not see that lock as its own)
# and records the baseline only after it.
$igLockAt = $text.IndexOf('$script:SetupLock = Enter-LaiSetupLock')
$igVerifyAt = $text.IndexOf("& (Join-Path `$SourceRoot 'Test-LocalAI.ps1') -AIRoot `$AIRoot")
$igSaveAt = $text.IndexOf('Save-LaiIntegrityBaseline -AIRoot $AIRoot -Reason ''install''')
$igHealth = Get-Content -Raw -Encoding UTF8 (Join-Path $copy 'Test-LocalAI.ps1')
Assert-That ($igLockAt -ge 0 -and $igVerifyAt -gt $igLockAt -and $igSaveAt -gt $igVerifyAt) 'the installer holds the setup lock, runs the health check in its own process and records the baseline only after it'
Assert-That ($igHealth -match 'Get-Variable -Name SetupLock' -and $igHealth -match "Skip 'an install, update or model update is running") 'and the health check, called by an installer that holds the lock, skips the integrity line instead of advising on findings against the old baseline'
$tok2 =Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email $Email -Password $Password
$nbTool = $null; try { $nbTool = Invoke-LaiApi -Uri 'http://127.0.0.1:3000/api/v1/tools/id/localai_skill_notebook' -Token $tok2 } catch { $nbTool = $null }
$mainP = Get-LaiWebUIModel -BaseUrl 'http://127.0.0.1:3000' -Token $tok2 -Id 'local-main'
Assert-That ($nbTool -and [string]$nbTool.content -notmatch '__LOCALAI_PRESETS__' -and @($mainP.meta.toolIds) -contains 'localai_skill_notebook' -and @($mainP.meta.skillIds) -contains 'research-with-sources') 'the skill notebook is installed with the presets filled in, and it and the starter skills are offered in Local Main'
Assert-That ($state.flags.PSObject.Properties['configureWarnings'] -and @($state.flags.configureWarnings).Count -eq 0) "Configure read every setting back from the real Open WebUI: no warnings ($(@($state.flags.configureWarnings) -join ' | '))"
Assert-That (-not (Select-String -LiteralPath (Join-Path $aiRoot 'install-report.md') -Pattern 'need attention' -Encoding UTF8 -Quiet)) 'a clean install report has no attention section'
$sel = @($state.flags.selectedModels)
Assert-That ($sel -contains 'trial-ok') 'trial model that works was added (passed through the reboot/resume)'
Assert-That ($sel -notcontains 'trial-missing') 'trial model with a missing tag was skipped, not fatal'
Assert-That ((Get-Content -Raw (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName) -match 'Trial Trial: missing tag .* skipped') 'the skip came from the failed pull (Models stage), not the disk planner'  # lai-ok: objects
Assert-That ($null -ne $state.tuning.'trial-ok') 'trial model was tuned like the others'
function Get-TestPreset([string]$Id) {
    # Sign in through the module, which waits out Open WebUI's sign-in limit (15 per 3 minutes).
    # A raw sign-in here failed a CI run with HTTP 429 on a commit that had just passed.
    $tok = Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email $Email -Password $Password
    try { return Invoke-RestMethod -Uri "http://127.0.0.1:3000/api/v1/models/model?id=$Id" -Headers @{ Authorization = "Bearer $tok" } } catch { return $null }
}
$tp = Get-TestPreset 'trial-standin'
Assert-That ($tp -and -not $tp.meta.hidden) 'trial preset created in Open WebUI and visible'
# Official releases are installed by default (no -OfficialModels), listed first, and new chats start on one.
Assert-That ($sel -contains 'official-ok' -and $sel -notcontains 'official-missing') "official models are installed by default; one whose tag cannot be pulled is skipped, not fatal ($($sel -join ', '))"
$allLogs = (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
Assert-That ($allLogs -match 'Official model Official: missing tag \(testorg/official-does-not-exist:1b\) skipped: .*The uncensored presets are unaffected') 'the official skip came from the Models stage and says the uncensored presets are unaffected'
Assert-That ($allLogs -match 'This update adds the official models .* -OfficialModels none') 'an existing install that never chose is told about the official models and how to skip them before the downloads'
Assert-That ($allLogs -match 'Open WebUI admin sign-in checked') 'an existing install checks the stored admin login before the downloads'
Assert-That ($state.flags.officialFailed.PSObject.Properties['official-missing'] -and [string]$state.flags.officialFailed.'official-missing'.Source -eq 'testorg/official-does-not-exist:1b') 'the failed official model is recorded, so later runs do not download and load it again'
$op = Get-TestPreset 'official-standin'
$mcfg = Invoke-LaiApi -Uri 'http://127.0.0.1:3000/api/v1/configs/models' -Token $tok2
Assert-That ($op -and $op.meta.capabilities.vision -eq $false -and $allLogs -match 'cannot read images \(Ollama reports no vision capability\); image upload is off for Official: stand-in') 'a model listed as seeing images whose download cannot gets image upload turned off (instead of an error on every image)'
Assert-That ($op -and -not $op.meta.hidden -and [string]$mcfg.DEFAULT_MODELS -eq 'official-standin') "the official preset is visible and new chats start on it (default '$($mcfg.DEFAULT_MODELS)', preset found: $([bool]$op), hidden: $($op.meta.hidden))"
Assert-That ($global:Tasks.ContainsKey('LocalAI-Backup-OpenWebUI')) 'daily backup task registered'
$guardAfter = [int](Invoke-RestMethod $guardStatus -TimeoutSec 5).stats.requests
Assert-That (($guardAfter - $guardBefore) -ge 1) "Open WebUI reaches Ollama through the render guard ($($guardAfter - $guardBefore) requests)"
Assert-That (Test-Path (Join-Path $aiRoot 'Stack/render-guard/render_guard.py')) 'render guard copied into the stack folder'
$urlFile = Get-ChildItem -Path (Join-Path $Work 'ProgramData') -Recurse -Filter 'Local AI (Open WebUI).url' -ErrorAction SilentlyContinue | Select-Object -First 1
Assert-That ($urlFile -and ((Get-Content -Raw $urlFile.FullName) -match 'URL=http://localhost:\d+/')) 'Start-menu Open WebUI shortcut written'
Assert-That ($global:Tasks.ContainsKey('LocalAI-Watch') -and $global:Tasks['LocalAI-Watch'] -like '*Watch-LocalAI.ps1*') 'health watch task registered'
Assert-That (($envFile -contains 'WEBUI_ADMIN_PASSWORD=') -and ($envFile -match '^WEBUI_SECRET_KEY=[0-9a-f]{64}$')) '.env: bootstrap password blanked, 64-hex secret key'
Assert-That (@(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*-pre-compose.tar.gz').Count -eq 1) 'legacy container volume backed up before replacement'
Assert-That (@(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*.tar.gz').Count -ge 2) 'scheduled-style backup created too'
Assert-That ((& /usr/bin/docker run --rm -v open-webui:/d:ro alpine:3.20 cat /d/marker.txt) -eq 'legacy-marker') 'old data copied from the legacy volume into open-webui'
$legacyNow = @(& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Names}}')
Assert-That ($legacyNow -notcontains 'open-webui-legacy-20250101000000' -and $legacyNow.Count -eq 1) "the installer's own mis-renamed container is removed, the manual install's is kept ($($legacyNow -join ', '))"
Assert-That ((& /usr/bin/docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' (& /usr/bin/docker ps -aq --filter 'name=^/open-webui-legacy-')) -eq 'no') 'legacy container restart policy disabled'
Assert-That ($null -eq (& /usr/bin/docker ps -a --filter 'name=^/open-webui$' --format '{{.ID}}') -and (& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Status}}') -match 'Exited') 'legacy container stopped and renamed (kept)'
Assert-That (@($global:Calls | Where-Object { $_ -like 'docker compose*up -d*' }).Count -ge 2) 'compose up ran (initial + after password removal)'
# Match the user's own grant (the SYSTEM/Administrators grants would match a loose pattern).
$userSid = 'S-1-5-21-1-2-3-1001'
Assert-That (@($global:Calls | Where-Object { $_ -like ('icacls ' + $aiRoot + ' /inheritance:r /grant:r *' + $userSid + ':(OI)(CI)F *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F') }).Count -ge 1) 'AI folder locked to the user, SYSTEM and Administrators'
Assert-That (@($global:Calls | Where-Object { $_ -like ('icacls ' + (Join-Path $aiRoot 'Scripts') + ' /inheritance:r /grant:r *' + $userSid + ':(OI)(CI)RX *') }).Count -ge 1) 'Scripts read-only for the user'
$elevated = Join-Path $env:ProgramFiles 'LocalAI'
Assert-That ((Test-Path (Join-Path $elevated 'Install-LocalAI.ps1')) -and (Test-Path (Join-Path $elevated 'lib/LocalAI.psm1'))) 'resume copy of the toolkit in Program Files\LocalAI'
Assert-That (@($global:Calls | Where-Object { $_ -like ('icacls ' + $elevated + ' /inheritance:r /grant:r *' + $userSid + ':(OI)(CI)RX *') }).Count -ge 1) 'that copy is read-only for the user'
Assert-That (@(Get-ChildItem -LiteralPath $elevated -Recurse -File -Force | Where-Object { $_.Name -ieq 'CLAUDE.md' }).Count -eq 0) 'and holds no CLAUDE.md (an agent reading a file there would load it as rules)'
Assert-That ([string]$global:TaskPrincipals['LocalAI-Backup-OpenWebUI'] -match 'Limited' -and [string]$global:TaskPrincipals['LocalAI-Backup-OpenWebUI'] -notmatch 'Highest') 'nightly backup task runs non-elevated'
# Windows Terminal (Windows 11's default console) shows a window despite -WindowStyle Hidden, and
# closing it kills the run: both tasks go through conhost --headless.
foreach ($tn in 'LocalAI-Backup-OpenWebUI', 'LocalAI-Watch', 'LocalAI-Recheck-Models') {
    Assert-That ([string]$global:TaskExec[$tn] -like '*conhost.exe' -and [string]$global:Tasks[$tn] -like '--headless powershell.exe *-WindowStyle Hidden*') "$tn runs with no window at all ($($global:TaskExec[$tn]) $($global:Tasks[$tn]))"
}
$bArgs = [string]$global:Tasks['LocalAI-Backup-OpenWebUI']
Assert-That ($bArgs -match '-WaitForChatsSec [1-9]\d*' -and $bArgs -match '-DailyAt 03:30') "the backup task waits for a chat answer being written and knows its daily time ($bArgs)"
Assert-That ([string]$global:TaskTriggerArgs['LocalAI-Backup-OpenWebUI'] -match '-Daily' -and [string]$global:TaskTriggerArgs['LocalAI-Backup-OpenWebUI'] -match '-AtLogOn') "the backup task also runs at sign-in, to catch up a night missed while signed out ($($global:TaskTriggerArgs['LocalAI-Backup-OpenWebUI']))"
# The nightly re-check after Ollama updated itself: an hour after the backup, never at sign-in or as
# a catch-up after wake (both are when the owner starts using the GPU), never elevated.
$rcTask = 'LocalAI-Recheck-Models'
Assert-That ($global:Tasks.ContainsKey($rcTask) -and [string]$global:Tasks[$rcTask] -like '*Update-Models.ps1*' -and [string]$global:Tasks[$rcTask] -match ' -RecheckOnly -Scheduled') "nightly model re-check task registered with -RecheckOnly -Scheduled ($($global:Tasks[$rcTask]))"
Assert-That ([string]$global:TaskPrincipals[$rcTask] -match 'Limited' -and [string]$global:TaskPrincipals[$rcTask] -notmatch 'Highest') 'the re-check task runs non-elevated'
Assert-That ([string]$global:TaskTriggerArgs[$rcTask] -match '-Daily' -and [string]$global:TaskTriggerArgs[$rcTask] -match '04:30' -and [string]$global:TaskTriggerArgs[$rcTask] -notmatch 'AtLogOn') "the re-check runs daily an hour after the backup, with no sign-in trigger ($($global:TaskTriggerArgs[$rcTask]))"
Assert-That ([string]$global:TaskSettingsArgs[$rcTask] -match 'IgnoreNew' -and [string]$global:TaskSettingsArgs[$rcTask] -notmatch 'StartWhenAvailable|WakeToRun') "no catch-up start after a missed night and no waking the PC ($($global:TaskSettingsArgs[$rcTask]))"
Assert-That ([string](Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'localai-config.json') | ConvertFrom-Json).ModelRecheckAt -eq '04:30') 'the config records the re-check time, so the health watch waits for it instead of notifying'
Assert-That (@($global:Calls | Where-Object { $_ -like 'docker compose*pull*' }).Count -ge 1 -and @($global:Calls | Where-Object { $_ -like 'docker compose*pull*' -and $_ -notlike '*--policy missing*' }).Count -eq 0) 'image pulls reuse local images (--policy missing)'
Assert-That ((Test-Path (Join-Path $env:USERPROFILE '.wslconfig')) -and (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $env:USERPROFILE '.wslconfig')) -match 'memory=16GB') '.wslconfig created, with the 16 GB WSL cap on this 64 GB PC'
Assert-That ((Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'Stack/searxng/settings.yml')) -notmatch '__SEARXNG_SECRET__') 'SearXNG secret filled in'
Assert-That (Test-Path (Join-Path $aiRoot 'install-report.md')) 'install report written'
Assert-That ((Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'localai-config.json') | ConvertFrom-Json).SelectedModels.Count -ge 1) 'config written with selected models'

# ---- phase 3: idempotent re-run ----------------------------------------------------------------
Write-Host "`n=== PHASE 3: re-run (idempotent) ===" -ForegroundColor Cyan
# What changed after the first install must survive a re-run: an Update-OpenWebUI version bump, a
# render-guard mode, a custom .env key, and keys other scripts keep in the config (ComfyUIPath).
$envFile = Join-Path $aiRoot 'Stack/.env'
$envLines = @(Get-Content -Encoding UTF8 $envFile | ForEach-Object { if ($_ -like 'OPEN_WEBUI_VERSION=*') { 'OPEN_WEBUI_VERSION=v0.99.0' } elseif ($_ -like 'RENDER_GUARD_MODE=*') { 'RENDER_GUARD_MODE=off' } else { $_ } }) + 'COMFYUI_URLS=http://host.docker.internal:8190'
Set-Content -Path $envFile -Value $envLines
$cfgFile = Join-Path $aiRoot 'localai-config.json'
$cfgObj = Get-Content -Raw $cfgFile | ConvertFrom-Json
$cfgObj | Add-Member -NotePropertyName ComfyUIPath -NotePropertyValue 'D:\ComfyUI\run_nvidia_gpu.bat' -Force
$cfgObj | ConvertTo-Json -Depth 5 | Set-Content $cfgFile
# An older render_guard.py was started last: the re-run must restart the guard (compose up would not).
$restartCalls = { @($global:Calls | Where-Object { $_ -like 'docker compose*restart render-guard*' }).Count }
Assert-That ((& $restartCalls) -eq 0) 'fresh install: no render-guard restart needed'
$stG = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
Assert-That ([string]$stG.flags.guardHash -ne '') 'the started render-guard code is recorded'
$stG.flags.guardHash = 'hash-of-an-older-version'
# As after a first install that stopped before its end screen: the password it made is still to be shown.
$stG.flags | Add-Member -NotePropertyName adminPasswordToShow -NotePropertyValue $true -Force
$stG | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $aiRoot 'install-state.json')
# The owner edited the rules file the first install placed (CRLF on purpose: nothing may normalise it).
# The re-run must neither restore the template nor merge into the file.
$ownerRules = "# Rules of my own`r`nAnswer in French.`r`n"
[System.IO.File]::WriteAllText($agentFile, $ownerRules, (New-Object System.Text.UTF8Encoding($false)))
$ownerRulesHash = (Get-FileHash -LiteralPath $agentFile).Hash
$sw = [Diagnostics.Stopwatch]::StartNew()
# One optional step fails (a rejected knowledge collection): a warning in the report, not a failed install.
$env:LOCALAI_TEST_KNOWLEDGE_FAIL = 'PC & Electronics'
# The end screen is captured (and still shown) to check what it says about the password.
$screen3 = @(& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests 6>&1 | ForEach-Object { $l = "$_"; Write-Host $l; $l })
$code3 = $LASTEXITCODE
$env:LOCALAI_TEST_KNOWLEDGE_FAIL = ''
# An update records a new baseline as well, and says what it kept that it did not put there itself:
# here the routing setting added to .env by hand above.
$base3 = Read-LaiIntegrityBaseline -AIRoot $aiRoot
$kept3 = @(); if ($base3) { $kept3 = @($base3['accepted'] | Where-Object { $_ -is [hashtable] } | ForEach-Object { [string]$_['Id'] }) }
$igNow = @(& $igDiffs)
Assert-That ($base3 -and $base2 -and [string]$base3['id'] -ne [string]$base2['id'] -and [string]$base3['reason'] -eq 'install' -and $igNow.Count -eq 0) "the re-run records a new integrity baseline, and no file, setting or task differs from it right afterwards ($($igNow -join '; '))"
Assert-That ($kept3 -contains 'env+|COMFYUI_URLS' -and @($kept3 | Where-Object { $_ -match '^files?[+]?\|Scripts\\' }).Count -eq 0) "it lists the custom setting it kept and did not write itself, and none of its own scripts ($($kept3 -join '; '))"
$st3 = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$rep3 = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-report.md')
Assert-That (@($screen3 | Where-Object { $_ -like "*Password:*$Password*shown this once*" }).Count -eq 1 -and -not ($st3.flags.PSObject.Properties.Name -contains 'adminPasswordToShow')) 'a password not shown yet is shown once at the end, then marked as shown'
Assert-That (@($st3.flags.configureWarnings).Count -eq 1 -and $null -ne $st3.stages.Backup -and $rep3 -match '## Settings that need attention' -and $rep3 -match "Knowledge collection 'PC & Electronics' was not created") 'a failed optional step is listed under Settings that need attention, and the install still reaches Backup'
Assert-That ((& $restartCalls) -eq 1) 'changed render_guard.py: the guard is restarted to load it'
Assert-That ($code3 -eq 0) "re-run completes (exit $code3) in $([int]$sw.Elapsed.TotalSeconds) s"
# This process lives on after the run (like the -NoExit Administrator window): the setup lock must
# be free again, or a re-run / Update-Models would be refused until the window is closed.
$probeLock = (& pwsh -NoProfile -Command ("Import-Module '{0}'; try {{ `$l = Enter-LaiSetupLock; 'FREE' }} catch {{ 'BUSY' }}" -f (Join-Path $copy 'lib/LocalAI.psm1'))) -join ''
Assert-That ($probeLock -eq 'FREE') "setup lock released when the installer finishes ($probeLock)"
Assert-That (@(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter '*pre-compose*').Count -eq 1) 'no second legacy migration on re-run'
$envAfter = Get-Content -Encoding UTF8 $envFile
Assert-That ($envAfter -contains 'OPEN_WEBUI_VERSION=v0.99.0') 're-run keeps the Open WebUI version set by Update-OpenWebUI'
Assert-That ($envAfter -contains 'RENDER_GUARD_MODE=off') 're-run keeps the render-guard mode'
Assert-That ($envAfter -contains 'COMFYUI_URLS=http://host.docker.internal:8190') 're-run keeps custom .env keys'
$cfgAfter = Get-Content -Raw $cfgFile | ConvertFrom-Json
Assert-That ($cfgAfter.ComfyUIPath -eq 'D:\ComfyUI\run_nvidia_gpu.bat') 're-run keeps ComfyUIPath in the config'
Assert-That ($cfgAfter.OpenWebUIVersion -eq 'v0.99.0' -and $cfgAfter.RenderGuard -eq 'off') 'config reflects the kept version and mode'
Assert-That ([string]$cfgAfter.WebUIOllamaUrl -ne '') 'config records the Ollama URL Open WebUI was given'
$kc = @((Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.params.KnowledgeCollections)
Assert-That ($kc.Count -eq 2 -and $kc -contains "Dad$([char]0x2019)s References") "a comma list given as one string is remembered split, a typographic apostrophe intact through the resume command ($($kc -join ' | '))"
Assert-That ($cfgAfter.KeepAlive -eq '7m' -and [int]$cfgAfter.BackupRetentionDays -eq 9) 're-run without switches keeps -KeepAlive / -BackupRetentionDays from the first run'

Assert-That (@((Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.selectedModels) -contains 'trial-ok') 're-run without -TrialModels keeps the chosen trial'
$p3Log = Get-Content -Raw (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
Assert-That ($p3Log -match 'Official: missing tag is not set up: it failed before' -and $p3Log -notmatch 'Downloading testorg/official-does-not-exist') 'a re-run does not try the failed official model again, and says how to'
Assert-That (@((Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.selectedModels) -contains 'official-ok') 're-run keeps the official model'
Assert-That ((Get-FileHash -LiteralPath $agentFile).Hash -eq $ownerRulesHash -and [System.IO.File]::ReadAllText($agentFile) -ceq $ownerRules) 're-run leaves a rules file the owner edited byte for byte as it is (not restored from the template, not merged)'
Assert-That ($p3Log -match 'already exists: left as it is' -and $p3Log -notmatch 'Rules for an AI agent opened in this folder placed') 'and the re-run log says it was left, not placed'

# ---- phase 4: drop the trial again ---------------------------------------------------------------
Write-Host "`n=== PHASE 4: re-run with -TrialModels none ===" -ForegroundColor Cyan
# Pretend this install predates remembered settings: the skips must be inferred from what is installed.
$st = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$st.flags.PSObject.Properties.Remove('params')
$st | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $aiRoot 'install-state.json')
# This run: a standard account signed in, an administrator's password typed at the UAC prompt.
$global:ConsoleUser = 'MOCKPC\kid'
$screen4 = @(& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -OfficialModels none 6>&1 | ForEach-Object { $l = "$_"; Write-Host $l; $l })
Assert-That ($LASTEXITCODE -eq 0) "phase 4 completes (exit $LASTEXITCODE)"
Assert-That (@($screen4 | Where-Object { $_ -like '*Password:*openwebui-admin.json*' }).Count -eq 1 -and @($screen4 | Where-Object { $_ -like "*$Password*" }).Count -eq 0) 'a later run says where the password is, without showing it'
$global:ConsoleUser = 'MOCKPC\testuser'
$lastLog = Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1  # lai-ok: objects
Assert-That ($lastLog -and (Get-Content -Raw $lastLog.FullName) -match 'signed in as MOCKPC\\kid, but the installer runs as MOCKPC\\testuser') 'warns when UAC was approved with another account'
Assert-That ((& $restartCalls) -eq 1) 'unchanged render_guard.py: no restart'
Assert-That (@((Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.selectedModels) -notcontains 'trial-ok') '-TrialModels none deselects the trial'
$tp = Get-TestPreset 'trial-standin'
Assert-That ($tp -and $tp.meta.hidden -eq $true) 'deselected trial preset is hidden (kept for old chats)'
$op = Get-TestPreset 'official-standin'
$tok4 = Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email $Email -Password $Password
$mcfg = Invoke-LaiApi -Uri 'http://127.0.0.1:3000/api/v1/configs/models' -Token $tok4
$st4 = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
Assert-That (@($st4.flags.selectedModels) -notcontains 'official-ok' -and $op -and $op.meta.hidden -eq $true -and [string]$mcfg.DEFAULT_MODELS -eq 'local-main') "-OfficialModels none hides the official preset and new chats start on Local Main again (default '$($mcfg.DEFAULT_MODELS)')"

Write-Host "`n=== PHASE 4b: the official models come back while the GPU is busy ===" -ForegroundColor Cyan
# Forget official-ok's GPU check, so this run has to wait for an idle GPU before checking it again.
$st = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$st.tuning.PSObject.Properties.Remove('official-ok')
$st | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $aiRoot 'install-state.json')
$global:MockGpu = 'NVIDIA GeForce RTX 3090, 566.36, 24576, 20000, 4576'
try { & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -OfficialModels all -GpuWaitMinutes 0 } finally { $global:MockGpu = $null }
$c4b = $LASTEXITCODE
$log4b = Get-Content -Raw (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
$st4b = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
Assert-That ($c4b -eq 0 -and $log4b -match 'Official: stand-in is set up on the next run: the GPU was busy') "a busy GPU skips the official model for now and the install completes (exit $c4b)"
Assert-That (-not $st4b.flags.officialFailed.PSObject.Properties['official-ok'] -and [string]$st4b.flags.officialFailed.'official-missing'.Source) 'a busy GPU is not recorded as the model failing (a missing tag is)'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -GpuWaitMinutes 10
$st4c = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$op = Get-TestPreset 'official-standin'
Assert-That ($LASTEXITCODE -eq 0 -and @($st4c.flags.selectedModels) -contains 'official-ok' -and $op -and -not $op.meta.hidden) "the next run with an idle GPU sets it up and shows its preset again (exit $LASTEXITCODE)"

Write-Host "`n=== PHASE 4d: an official model whose tuned alias fails to load: left out, the update completes ===" -ForegroundColor Cyan
# The 8K check (on the source) passes; tuning loads the alias, which this hook makes fail like a
# model this Ollama cannot run. Before the fix this threw out of the Tuning stage and stopped the run.
$st = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$st.tuning.PSObject.Properties.Remove('official-ok')
$st | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $aiRoot 'install-state.json')
$env:LOCALAI_TEST_LOAD_FAIL = 'localai-official-standin'
try { & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none } finally { $env:LOCALAI_TEST_LOAD_FAIL = '' }
$c4d = $LASTEXITCODE
$log4d = Get-Content -Raw (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
$st4d = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
Assert-That ($c4d -eq 0 -and $log4d -match 'Official model Official: stand-in \(testorg/qwen3-abliterated:1\.7b\) skipped: .*incompatible' -and $log4d -match '=+ Backup =+') "a tuning failure of an official model skips it and the run goes on to the Backup stage (exit $c4d)"
Assert-That (@($st4d.flags.selectedModels) -notcontains 'official-ok' -and [string]$st4d.flags.officialFailed.'official-ok'.Why -match 'incompatible' -and $null -ne $st4d.tuning.main) 'it is recorded as the model''s own failure; the uncensored presets stay tuned'
Assert-That ($log4d -notmatch 'download \([\d.]+ GB\) was removed') 'a model this run did not download is not deleted (its files are shared with Uncensored Main here)'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -OfficialModels all
$st4e = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
Assert-That ($LASTEXITCODE -eq 0 -and @($st4e.flags.selectedModels) -contains 'official-ok' -and -not $st4e.flags.officialFailed.PSObject.Properties['official-ok']) "naming the choice again (-OfficialModels all) retries it (exit $LASTEXITCODE)"

Write-Host "`n=== PHASE 4f: the owner's own default model and hidden presets survive an update ===" -ForegroundColor Cyan
$tokF = Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email $Email -Password $Password
Set-LaiWebUIModelsConfig -BaseUrl 'http://127.0.0.1:3000' -Token $tokF -DefaultModel 'local-fast' | Out-Null
Hide-LaiWebUIModel -BaseUrl 'http://127.0.0.1:3000' -Token $tokF -Id 'official-standin' | Out-Null
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
$c4f = $LASTEXITCODE
$tokF = Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email $Email -Password $Password
$mcfgF = Invoke-LaiApi -Uri 'http://127.0.0.1:3000/api/v1/configs/models' -Token $tokF
$opF = Get-TestPreset 'official-standin'
Assert-That ($c4f -eq 0 -and [string]$mcfgF.DEFAULT_MODELS -eq 'local-fast') "a default model the owner picked is kept by an update (default '$($mcfgF.DEFAULT_MODELS)', exit $c4f)"
Assert-That ($opF -and $opF.meta.hidden -eq $true) 'a selected preset the owner hid stays hidden'
Write-Host "`n=== PHASE 4g: an older toolkit over a newer install; a folder in AI that is not ours ===" -ForegroundColor Cyan
$cfgPathG = Join-Path $aiRoot 'localai-config.json'
$cfgG = Read-LaiState -Path $cfgPathG; $cfgG['ToolkitVersion'] = '2099.01.01'; Save-LaiState -State $cfgG -Path $cfgPathG
$foreignDir = Join-Path $aiRoot 'ComfyUI'; New-Item -ItemType Directory -Force -Path $foreignDir | Out-Null
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
$c4g = $LASTEXITCODE
$log4g = Get-Content -Raw (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
Assert-That ($c4g -eq 1 -and $log4g -match 'older than the installed 2099\.01\.01\. Nothing was changed') "an older toolkit refuses to run over a newer install (exit $c4g)"
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -AllowDowngrade
$c4h = $LASTEXITCODE
$log4h = Get-Content -Raw (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
Assert-That ($c4h -eq 0 -and $log4h -match 'also holds ComfyUI: their permissions are left alone') "-AllowDowngrade runs it; a folder in AI that is not the toolkit's keeps its permissions (exit $c4h)"
Remove-Item -LiteralPath $foreignDir -Recurse -Force
# Back to the toolkit's own default for the later phases.
Set-LaiWebUIModelsConfig -BaseUrl 'http://127.0.0.1:3000' -Token $tokF -DefaultModel 'official-standin' | Out-Null
Show-LaiWebUIModel -BaseUrl 'http://127.0.0.1:3000' -Token $tokF -Id 'official-standin' | Out-Null
$p4 = (Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.params
Assert-That ($p4.SkipVision -eq $true -and $p4.SkipCoder -eq $true) 'older install: skips inferred from the installed models (no surprise 20 GB downloads)'
Assert-That (@((Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.configureWarnings).Count -eq 0 -and -not (Select-String -LiteralPath (Join-Path $aiRoot 'install-report.md') -Pattern 'need attention' -Encoding UTF8 -Quiet)) "the next clean run clears phase 3's warning (no stale attention section)"

# ---- phase 5: a resume that keeps failing stops starting itself -----------------------------------
Write-Host "`n=== PHASE 5: failing resume gives up after two sign-ins ===" -ForegroundColor Cyan
$global:Tasks['LocalAI-Install-Resume'] = $resumeCmd
$env:LOCALAI_TEST_FAIL_STAGE = 'Ollama'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -Resume
$c5a = $LASTEXITCODE
Assert-That ($c5a -ne 0 -and $global:Tasks.ContainsKey('LocalAI-Install-Resume')) "first failed resume (exit $c5a) keeps the task for one more sign-in"
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -Resume
Assert-That (-not $global:Tasks.ContainsKey('LocalAI-Install-Resume')) 'second failed resume removes the task'
$env:LOCALAI_TEST_FAIL_STAGE = ''
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
Assert-That ($LASTEXITCODE -eq 0 -and -not (Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.PSObject.Properties['resumeFailures']) 'a good run clears the failure count'

Write-Host "`n=== PHASE 6: update over an install made by an early version ===" -ForegroundColor Cyan
# Early versions: no remembered settings (they lived in localai-config.json and the tuning
# fingerprint), backup and resume tasks elevated, a toolkit copy in AI\Installer, the secret key
# copied rather than moved. The run fails at the first stage: the fixes must already be done.
Import-Module (Join-Path $copy 'lib/LocalAI.psm1')
$statePath = Join-Path $aiRoot 'install-state.json'; $cfgPath = Join-Path $aiRoot 'localai-config.json'
$st6 = Read-LaiState -Path $statePath
$st6.flags.Remove('params')
foreach ($k in @($st6.tuning.Keys)) { if ($st6.tuning[$k] -is [hashtable] -and $st6.tuning[$k]['Fingerprint']) { $st6.tuning[$k]['Fingerprint'] = ([string]$st6.tuning[$k]['Fingerprint']) -replace 'overhead=\d+', 'overhead=600' } }
Save-LaiState -State $st6 -Path $statePath
$cfg6 = Read-LaiState -Path $cfgPath; $cfg6['BackupRetentionDays'] = 90; $cfg6['BackupMirror'] = (Join-Path $Work 'nas-mirror'); $cfg6['KeepAlive'] = '30m'; Save-LaiState -State $cfg6 -Path $cfgPath
$global:TaskTriggers = @{ 'LocalAI-Backup-OpenWebUI' = '2025-01-01T02:15:00' }
function global:Get-ScheduledTask {
    param($TaskName, $ErrorAction)
    if (-not $global:Tasks.ContainsKey($TaskName)) { if ($ErrorAction -eq 'Stop') { throw "no task $TaskName" }; return $null }
    $lvl = 'Limited'; if ([string]$global:TaskPrincipals[$TaskName] -match 'Highest') { $lvl = 'Highest' }
    [pscustomobject]@{ TaskName = $TaskName; Principal = [pscustomobject]@{ RunLevel = $lvl }; Actions = @([pscustomobject]@{ Arguments = [string]$global:Tasks[$TaskName] }); Triggers = @([pscustomobject]@{ StartBoundary = [string]$global:TaskTriggers[$TaskName] }) }
}
function global:Set-ScheduledTask { param($TaskName, $Principal) $global:TaskPrincipals[$TaskName] = [string]$Principal.Args; Record "Set-ScheduledTask $TaskName" }
$global:Tasks['LocalAI-Backup-OpenWebUI'] = '-File "C:\AI\Scripts\Backup-OpenWebUI.ps1" -AIRoot "C:\AI"'; $global:TaskPrincipals['LocalAI-Backup-OpenWebUI'] = '-UserId x -LogonType Interactive -RunLevel Highest'
$global:Tasks['LocalAI-Install-Resume'] = '-File "C:\AI\Scripts\Install-LocalAI.ps1"'; $global:TaskPrincipals['LocalAI-Install-Resume'] = '-UserId x -LogonType Interactive -RunLevel Highest'
$global:Tasks['LocalAI-Watch'] = '-File "C:\AI\Scripts\Watch-LocalAI.ps1"'; $global:TaskPrincipals['LocalAI-Watch'] = '-UserId x -LogonType Interactive -RunLevel Highest'
# Exactly what the first bootstrap unpacked: Installer\ComfyUi-Optimization-<ref>\local-llm\...
$oldCopy = Join-Path $aiRoot 'Installer/ComfyUi-Optimization-main/local-llm'
New-Item -ItemType Directory -Force -Path (Join-Path $oldCopy 'lib') | Out-Null
Set-Content -LiteralPath (Join-Path $oldCopy 'Install-LocalAI.ps1') -Value '# old'; Set-Content -LiteralPath (Join-Path $oldCopy 'lib/LocalAI.psm1') -Value '# old'
Copy-Item -LiteralPath (Join-Path $aiRoot 'Secrets/openwebui-secret.txt') -Destination (Join-Path $aiRoot 'openwebui-secret.txt')
$env:LOCALAI_TEST_FAIL_STAGE = 'Preflight'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
$c6 = $LASTEXITCODE
$env:LOCALAI_TEST_FAIL_STAGE = ''
Assert-That ($c6 -ne 0) "the run stops at the first stage (exit $c6)"
Assert-That ([string]$global:TaskPrincipals['LocalAI-Backup-OpenWebUI'] -match 'Limited' -and [string]$global:TaskPrincipals['LocalAI-Backup-OpenWebUI'] -notmatch 'Highest') 'an elevated backup task from an early version is made non-elevated before anything can fail'
Assert-That (-not $global:Tasks.ContainsKey('LocalAI-Install-Resume')) "an elevated after-reboot task from an early version is removed"
Assert-That ([string]$global:TaskPrincipals['LocalAI-Watch'] -match 'Limited') 'an elevated health-watch task is made non-elevated too'
$p6 = (Read-LaiState -Path $statePath).flags['params']
Assert-That ($p6 -and [int]$p6['BackupRetentionDays'] -eq 90 -and [string]$p6['BackupMirror'] -eq (Join-Path $Work 'nas-mirror') -and [string]$p6['KeepAlive'] -eq '30m') 'retention, mirror and keep-alive carried over from the old config (no pruning of 15-90-day-old backups)'
Assert-That ($p6 -and [int]$p6['GpuOverheadMiB'] -eq 600 -and [string]$p6['BackupTime'] -eq '02:15') 'VRAM overhead from the tuning fingerprint (no needless re-tune) and backup time from the old task'
Assert-That (-not (Test-Path -LiteralPath (Join-Path $aiRoot 'Installer'))) 'the outdated AI\Installer toolkit copy is removed'
# A folder of the user's that happens to be called Installer is not ours to delete.
New-Item -ItemType Directory -Force -Path (Join-Path $aiRoot 'Installer') | Out-Null; Set-Content -LiteralPath (Join-Path $aiRoot 'Installer/my-notes.txt') -Value 'mine'
$env:LOCALAI_TEST_FAIL_STAGE = 'Preflight'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
$env:LOCALAI_TEST_FAIL_STAGE = ''
Assert-That (Test-Path -LiteralPath (Join-Path $aiRoot 'Installer/my-notes.txt')) "a user's own folder named Installer is left alone"
Remove-Item -LiteralPath (Join-Path $aiRoot 'Installer') -Recurse -Force
# A second key file that DIFFERS from the managed one is not a duplicate: deleting it could lose a key.
Set-Content -LiteralPath (Join-Path $aiRoot 'openwebui-secret.txt') -Value 'some-other-key' -NoNewline
$env:LOCALAI_TEST_FAIL_STAGE = 'Preflight'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
$env:LOCALAI_TEST_FAIL_STAGE = ''
Assert-That ((Test-Path -LiteralPath (Join-Path $aiRoot 'openwebui-secret.txt')) -and (Test-Path -LiteralPath (Join-Path $aiRoot 'Secrets/openwebui-secret.txt'))) 'a different key file outside Secrets is kept'
Remove-Item -LiteralPath (Join-Path $aiRoot 'openwebui-secret.txt') -Force
Assert-That (-not (Test-Path -LiteralPath (Join-Path $aiRoot 'openwebui-secret.txt')) -and (Test-Path -LiteralPath (Join-Path $aiRoot 'Secrets/openwebui-secret.txt'))) 'the second copy of the secret key outside Secrets is removed'
Remove-Item -Path 'function:Get-ScheduledTask', 'function:Set-ScheduledTask' -ErrorAction SilentlyContinue
Assert-That (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) 'task mocks removed for the next phase'

Write-Host "`n=== PHASE 6a: a folder in the install root replaced by a link ===" -ForegroundColor Cyan
# Anything running as the user can swap C:\AI\Logs for a link; the elevated installer must not write
# (its transcript, here) through it.
$logsDir = Join-Path $aiRoot 'Logs'; $elsewhere = Join-Path $Work 'elsewhere-logs'
Rename-Item -LiteralPath $logsDir -NewName 'Logs-real'
New-Item -ItemType Directory -Force -Path $elsewhere | Out-Null
& ln -s $elsewhere $logsDir
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
$c6a = $LASTEXITCODE
Assert-That ($c6a -ne 0 -and @(Get-ChildItem -LiteralPath $elsewhere).Count -eq 0) "refuses before writing anything through it (exit $c6a)"
Remove-Item -LiteralPath $logsDir -Force; Rename-Item -LiteralPath (Join-Path $aiRoot 'Logs-real') -NewName 'Logs'

Write-Host "`n=== PHASE 6b: an old 'Update toolkit' shortcut pointing at the wrong folder ===" -ForegroundColor Cyan
# Older shortcuts ignored -AIRoot and ran against C:\AI. With an install running elsewhere, a fresh
# folder must not become a second, broken install.
& /usr/bin/docker create --name lai-test-elsewhere --label lai-test=1 --label com.docker.compose.project=localai --label com.docker.compose.service=open-webui --label com.docker.compose.project.working_dir=/elsewhere/AI/Stack alpine:3.20 true | Out-Null
$ai2 = Join-Path $Work 'AI-second'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $ai2 -SkipTests
$c6b = $LASTEXITCODE
& /usr/bin/docker rm -f lai-test-elsewhere 2>$null | Out-Null
$log6b = (Get-ChildItem -LiteralPath (Join-Path $ai2 'Logs') -Filter 'install-*.log' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
$st6b = Read-LaiState -Path (Join-Path $ai2 'install-state.json')
Assert-That ($c6b -ne 0 -and $log6b -match 'already installed with its stack in /elsewhere/AI/Stack' -and -not ($st6b['stages'] -and $st6b['stages'].Count)) "refuses and names the existing install's folder (exit $c6b)"

Write-Host "`n=== PHASE 6c: a manual install whose data folder holds no webui.db ===" -ForegroundColor Cyan
# A mis-decoded or emptied data path: copying it would start the managed stack on an empty volume.
& /usr/bin/docker rm -f open-webui 2>$null | Out-Null
& /usr/bin/docker volume rm open-webui owui-empty 2>$null | Out-Null
& /usr/bin/docker volume create owui-empty | Out-Null
& /usr/bin/docker run --rm -v owui-empty:/data alpine:3.20 sh -c 'echo x > /data/marker.txt' | Out-Null
& /usr/bin/docker create --name open-webui --label lai-test=1 -v owui-empty:/app/backend/data alpine:3.20 sleep 3600 | Out-Null
$legacyBefore = @(& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Names}}')
$env:LOCALAI_TEST_FAIL_STAGE = 'Configure'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
$c6c = $LASTEXITCODE
$env:LOCALAI_TEST_FAIL_STAGE = ''
$log6c = Get-Content -Raw -LiteralPath (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
$legacyAfter = @(& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Names}}')
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& /usr/bin/docker volume inspect open-webui 2>&1 | Out-Null; $managedVol = ($LASTEXITCODE -eq 0)
& /usr/bin/docker container inspect open-webui 2>&1 | Out-Null; $oldKept = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prevEap
Assert-That ($c6c -ne 0 -and $log6c -match 'has no webui\.db') "stops and says the old data folder has no webui.db (exit $c6c)"
Assert-That (-not $managedVol -and $oldKept -and $legacyAfter.Count -eq $legacyBefore.Count) 'no empty managed volume left, the old container untouched (not renamed)'
& /usr/bin/docker rm -f open-webui 2>$null | Out-Null
& /usr/bin/docker volume rm owui-empty 2>$null | Out-Null

# ---- phase 7: hardware and setups other than the owner's ----------------------------------------
function Get-NewestLog { Get-Content -Raw -Encoding UTF8 -LiteralPath (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName }  # lai-ok: objects

Write-Host "`n=== PHASE 7a: a 16 GB card, then no NVIDIA GPU: refused before any download ===" -ForegroundColor Cyan
# The real catalog: Local Main (18.6 GB) cannot load fully on 16 GB, and used to fail the 100%-GPU
# checkpoint only after 28 GB of downloads.
$global:MockGpu = 'NVIDIA GeForce RTX 4080, 617.14, 16376, 900, 15476'
$env:LOCALAI_TEST_CATALOG = Join-Path $copy 'config/models.psd1'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
$c7a = $LASTEXITCODE
$log7a = Get-NewestLog
$env:LOCALAI_TEST_CATALOG = Join-Path $copy 'tests/models.test.psd1'
Assert-That ($c7a -ne 0 -and $log7a -match 'Uncensored Main \([\d.,]+ GB\) cannot load fully on this NVIDIA GeForce RTX 4080' -and $log7a -match '24 GB NVIDIA card' -and $log7a -match 'Nothing was downloaded') "a 16 GB card: stops and says why (exit $c7a)"
Assert-That ($log7a -notmatch '=+ Ollama =+' -and $log7a -notmatch 'Downloading ') 'it stops in Preflight: no Ollama stage, no download'
$global:MockGpu = 'none'; $global:MockVideo = @('AMD Radeon RX 7900 XTX')
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
$c7a2 = $LASTEXITCODE
$log7a2 = Get-NewestLog
$global:MockGpu = $null; $global:MockVideo = @('NVIDIA GeForce RTX 3090')
Assert-That ($c7a2 -ne 0 -and $log7a2 -match 'AMD Radeon RX 7900 XTX' -and $log7a2 -notmatch 'nvidia\.com/Download') "no NVIDIA GPU: names the AMD card instead of blaming an NVIDIA driver (exit $c7a2)"

Write-Host "`n=== PHASE 7b: the Ollama app's own Model location and Expose settings ===" -ForegroundColor Cyan
# Ollama 0.35.1's tray app starts 'ollama serve' with its saved Settings, overriding OLLAMA_MODELS /
# OLLAMA_HOST; only server.log shows it. A model still to download would land on the other drive.
$serverLog = Join-Path $env:LOCALAPPDATA 'Ollama/server.log'
$goodCfg = (Get-Content -Raw -Encoding UTF8 -LiteralPath $serverLog).TrimEnd()
Set-Content -LiteralPath $serverLog -Value (($goodCfg -replace 'OLLAMA_MODELS:[^ \]]*', 'OLLAMA_MODELS:C:\\Users\\testuser\\OllamaApp\\models') -replace 'OLLAMA_HOST:[^ \]]*', 'OLLAMA_HOST:http://0.0.0.0:11434')
$calls7b = $global:Calls.Count
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels trial-missing
$c7b = $LASTEXITCODE
$log7b = Get-NewestLog
$starts7b = @($global:Calls | Select-Object -Skip $calls7b | Where-Object { $_ -like 'Start-Process *ollama app.exe*' })
$asUser7b = @($starts7b | Where-Object { $_ -like '*explorer.exe*' }).Count
$mainRestarts7b = [regex]::Matches($log7b, 'Restarting Ollama so it picks up the settings').Count
Set-Content -LiteralPath $serverLog -Value $goodCfg
Assert-That ($c7b -ne 0 -and $log7b -match 'Settings > Model location' -and $log7b -match 'Nothing was downloaded') "a model to download while the app's Model location points elsewhere: stops first (exit $c7b)"
Assert-That ($log7b -notmatch '=+ Models =+' -and $log7b -notmatch 'Downloading ') 'no Models stage, no download'
Assert-That ($log7b -match 'Expose Ollama to the network') 'Ollama on 0.0.0.0 that the installer did not set is reported'
# The restart for the Model location runs Ollama as the signed-in user (through Explorer) first; the
# elevated start from the installer's own session only because the log still shows the other folder.
Assert-That ($asUser7b -eq $mainRestarts7b + 1 -and $starts7b.Count -ge 2 -and $starts7b[-2] -like '*explorer.exe*' -and $starts7b[-1] -notlike '*explorer.exe*') "Model location restart: as the user first, from the elevated session only as the fallback ($($starts7b.Count) starts, $asUser7b via Explorer, $mainRestarts7b settings restart(s))"

Write-Host "`n=== PHASE 7c: Ollama installed to a custom folder (OllamaSetup.exe /DIR=...) ===" -ForegroundColor Cyan
$defaultOllama = Join-Path $env:LOCALAPPDATA 'Programs/Ollama'
$global:CustomOllama = Join-Path $Work 'D-drive/Ollama'
New-Item -ItemType Directory -Force -Path (Join-Path $Work 'D-drive') | Out-Null
Move-Item -LiteralPath $defaultOllama -Destination $global:CustomOllama
# Inno Setup records the folder under Ollama's fixed AppId (InstallLocation, with a trailing backslash).
function global:Get-ItemProperty { param($Path) if ([string]$Path -like '*44E83376-CE68-45EB-8FC1-393500EB558C*') { return [pscustomobject]@{ InstallLocation = $global:CustomOllama + '\' } }; [pscustomobject]@{ DisplayVersion = '24H2'; UBR = 4317 } }
$wingetBefore = @($global:Calls | Where-Object { $_ -like 'winget*Ollama.Ollama*' }).Count
$env:LOCALAI_TEST_FAIL_STAGE = 'Models'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
$env:LOCALAI_TEST_FAIL_STAGE = ''
$log7c = Get-NewestLog
Assert-That (@($global:Calls | Where-Object { $_ -like 'winget*Ollama.Ollama*' }).Count -eq $wingetBefore -and -not (Test-Path -LiteralPath (Join-Path $defaultOllama 'ollama.exe'))) 'no winget / vendor installer run over the existing install'
Assert-That ($log7c -match 'Ollama \S+ on http://127\.0\.0\.1:11434' -and $log7c -match 'Test hook: stage Models failed') 'the Ollama stage passes with the custom folder'
Assert-That (@($global:Calls | Where-Object { $_ -like '*D-drive*ollama app.exe*' }).Count -ge 1) 'Ollama is started from the custom folder'
function global:Get-ItemProperty { param($Path) [pscustomobject]@{ DisplayVersion = '24H2'; UBR = 4317 } }
if (Test-Path -LiteralPath $defaultOllama) { Remove-Item -LiteralPath $defaultOllama -Recurse -Force }
Move-Item -LiteralPath $global:CustomOllama -Destination $defaultOllama

Write-Host "`n=== PHASE 7d: a PC with 8 GB of RAM ===" -ForegroundColor Cyan
$global:MockRamBytes = 8GB
$wslCfgPath = Join-Path $env:USERPROFILE '.wslconfig'
Remove-Item -LiteralPath $wslCfgPath -Force -ErrorAction SilentlyContinue
$env:LOCALAI_TEST_FAIL_STAGE = 'Docker'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -RenderGuard cpu
$env:LOCALAI_TEST_FAIL_STAGE = ''
$global:MockRamBytes = 64GB
$log7d = Get-NewestLog
$wsl7d = ''; if (Test-Path -LiteralPath $wslCfgPath) { $wsl7d = Get-Content -Raw -Encoding UTF8 -LiteralPath $wslCfgPath }
Assert-That ($wsl7d -match 'autoMemoryReclaim' -and $wsl7d -notmatch 'memory=') ".wslconfig keeps WSL's own limit (half the RAM) instead of raising it to 16 GB ($($wsl7d -replace '\s+', ' '))"
Assert-That ($log7d -match 'This PC has 8 GB of RAM') 'the render guard CPU mode warns that its models do not fit in RAM'

Write-Host "`n=== PHASE 7e: Open WebUI and SearXNG set up from Open WebUI's own guides ===" -ForegroundColor Cyan
# Its SearXNG guide names the container 'searxng' too. Compose would stop on the clash only after the
# old Open WebUI was stopped and renamed, and a re-run would no longer see that one.
& /usr/bin/docker rm -f open-webui 2>$null | Out-Null
& /usr/bin/docker run -d --label lai-test=1 --name searxng alpine:3.20 sleep 3600 | Out-Null
& /usr/bin/docker run -d --restart always --label lai-test=1 --name open-webui alpine:3.20 sleep 3600 | Out-Null
$legacy7e = @(& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Names}}').Count
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
$c7e = $LASTEXITCODE
$log7e = Get-NewestLog
$ow7e = (& /usr/bin/docker inspect -f '{{.State.Status}}|{{.HostConfig.RestartPolicy.Name}}' open-webui 2>$null) -join ''
Assert-That ($c7e -ne 0 -and $log7e -match 'A container named searxng from another setup' -and $log7e -match 'No container was changed') "a 'searxng' container of another setup: stops before changing anything (exit $c7e)"
Assert-That ($ow7e -eq 'running|always' -and @(& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Names}}').Count -eq $legacy7e) "the existing Open WebUI keeps running under its name, restart=always ($ow7e)"
& /usr/bin/docker rm -f searxng open-webui 2>$null | Out-Null

Write-Host "`n=== PHASE 7f: a rules file for an AI agent: one there before the first install, then none on an update ===" -ForegroundColor Cyan
# A folder that already holds a CLAUDE.md of the owner's before the installer has ever run there: no
# install state at all, so nothing but the file itself can tell the installer to leave it. The run
# stops at the first stage after Preflight (where the file is handled), so the stack is not touched.
$ai3 = Join-Path $Work 'AI-rules'
$theirRulesFile = Join-Path $ai3 'CLAUDE.md'
New-Item -ItemType Directory -Force -Path $ai3 | Out-Null
$theirRules = "# Notes of the owner`r`nThis file was here before the toolkit.`r`n"
[System.IO.File]::WriteAllText($theirRulesFile, $theirRules, (New-Object System.Text.UTF8Encoding($false)))
$theirRulesHash = (Get-FileHash -LiteralPath $theirRulesFile).Hash
$env:LOCALAI_TEST_FAIL_STAGE = 'Ollama'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $ai3 -SkipTests -TrialModels none
$env:LOCALAI_TEST_FAIL_STAGE = ''
$log7f = (@(Get-ChildItem -LiteralPath (Join-Path $ai3 'Logs') -Filter 'install-*.log' -ErrorAction SilentlyContinue) | ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName }) -join "`n"
Assert-That ($log7f -match '=+ Preflight =+' -and $log7f -match 'Test hook: stage Ollama failed' -and (Test-Path -LiteralPath (Join-Path $ai3 'Scripts/Install-LocalAI.ps1'))) 'the first run in a new folder went through Preflight and stopped at the Ollama stage'
Assert-That ((Get-FileHash -LiteralPath $theirRulesFile).Hash -eq $theirRulesHash -and [System.IO.File]::ReadAllText($theirRulesFile) -ceq $theirRules) 'a CLAUDE.md that was there before the first install is not replaced (byte for byte)'
Assert-That ($log7f -match 'already exists: left as it is' -and $log7f -notmatch 'Rules for an AI agent opened in this folder placed') 'and the log says it was left, not placed'
# An install made before the installer placed this file has none: the update places it.
Remove-Item -LiteralPath $agentFile -Force
$env:LOCALAI_TEST_FAIL_STAGE = 'Ollama'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
$env:LOCALAI_TEST_FAIL_STAGE = ''
$log7fb = Get-NewestLog
Assert-That ((Test-Path -LiteralPath $agentFile -PathType Leaf) -and (Get-FileHash -LiteralPath $agentFile).Hash -eq (Get-FileHash -LiteralPath $agentTemplate).Hash) 'an update of an install without the file places the template, byte for byte'
Assert-That ($log7fb -match 'Rules for an AI agent opened in this folder placed' -and $log7fb -notmatch 'already exists: left as it is') 'and the log says it was placed'

Write-Host "`n=== PHASE 8: -DeepResearch (Local Deep Research), then -NoDeepResearch ===" -ForegroundColor Cyan
# compose is mocked: a real Local Deep Research container stands in for the one compose would start
# (same image, the installer's port), on the host network so it reaches the sandbox's real Ollama.
$ldrImage = 'localdeepresearch/local-deep-research:1.10.7'
if ((& /usr/bin/docker image inspect $ldrImage 2>$null) -and $LASTEXITCODE -eq 0) {
    & /usr/bin/docker rm -f deep-research 2>$null | Out-Null
    & /usr/bin/docker run -d --name deep-research --label lai-test=1 --network host -e LDR_WEB_HOST=127.0.0.1 -e LDR_WEB_PORT=5055 -e LDR_DATA_DIR=/data `
        -e LDR_LLM_PROVIDER=ollama -e LDR_LLM_OLLAMA_URL=http://127.0.0.1:11434 -e LDR_LLM_MODEL=localai-main -e LDR_SEARCH_TOOL=searxng `
        -e LDR_SEARCH_ENGINE_WEB_SEARXNG_DEFAULT_PARAMS_INSTANCE_URL=http://127.0.0.1:8888 `
        --cap-drop ALL --cap-add CHOWN --cap-add FOWNER --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID $ldrImage | Out-Null
    # Phase 7e left the simulated PC without the Open WebUI volume; the first backup needs one.
    & /usr/bin/docker volume create open-webui | Out-Null
    & /usr/bin/docker run --rm -v open-webui:/data alpine:3.20 sh -c 'test -f /data/webui.db || head -c 65536 /dev/urandom > /data/webui.db' | Out-Null
    $before8 = @($global:Calls).Count
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -DeepResearch
    $c8 = $LASTEXITCODE
    # Before the update changed anything, the chats were backed up once for this toolkit version.
    $pre8 = @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*-before-toolkit-*.tar.gz' -ErrorAction SilentlyContinue)
    Assert-That ($pre8.Count -eq 1 -and [string](Read-LaiState -Path (Join-Path $aiRoot 'install-state.json'))['flags']['preUpdateBackup'] -like 'before-toolkit-*') "an update of an existing install backs the chats up first, once per toolkit version ($($pre8.Count) archive(s))"
    $env8 = @(Get-Content -Encoding UTF8 (Join-Path $aiRoot 'Stack/.env'))
    $st8 = Read-LaiState -Path (Join-Path $aiRoot 'install-state.json')
    $cfg8 = Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json')
    $mainCtx = [int]$st8['tuning']['main']['Context']
    Assert-That ($c8 -eq 0 -and @($st8['flags']['configureWarnings']).Count -eq 0) "the install with -DeepResearch completes without warnings (exit $c8; $(@($st8['flags']['configureWarnings']) -join ' | '))"
    $thinks8 = @((Get-LaiOllamaModelInfo -BaseUrl 'http://127.0.0.1:11434' -Name 'localai-main').Capabilities) -contains 'thinking'
    Assert-That ($env8 -contains ('DEEP_RESEARCH_THINKING=' + ([string]$thinks8).ToLowerInvariant()) -and $env8 -contains ('DEEP_RESEARCH_OLLAMA_URL=' + [string]$cfg8['WebUIOllamaUrl'])) "thinking follows the model's Ollama capabilities ($thinks8) and the Ollama address is Open WebUI's ($($cfg8['WebUIOllamaUrl']))"
    Assert-That ($env8 -contains 'COMPOSE_PROFILES=research' -and $env8 -contains 'DEEP_RESEARCH_MODEL=localai-main:latest' -and $env8 -contains "DEEP_RESEARCH_CONTEXT=$mainCtx" -and $env8 -contains 'DEEP_RESEARCH_PORT=5055') "Stack\.env turns the service on with Local Main at its tuned context ($mainCtx), port 5055"
    Assert-That ($env8 -contains 'DEEP_RESEARCH_ALLOW_REGISTRATIONS=false' -and @($global:Calls[$before8..($global:Calls.Count - 1)] | Where-Object { $_ -like 'docker compose*up -d deep-research*' }).Count -ge 1) 'after the account is made, sign-up is turned off and the service recreated with that'
    $rcFile = Join-Path $aiRoot 'Secrets/deep-research.json'
    $rc8 = $null; if (Test-Path -LiteralPath $rcFile) { $rc8 = Get-Content -Raw -Encoding UTF8 -LiteralPath $rcFile | ConvertFrom-Json }
    $login8 = ''
    if ($rc8) { try { $s8 = Connect-LaiResearch -BaseUrl 'http://127.0.0.1:5055' -Account $rc8.username -Password $rc8.password; $login8 = 'ok'; $s8.Client.Dispose() } catch { $login8 = $_.Exception.Message } }
    Assert-That ($login8 -eq 'ok') "the stored research account signs in to the real Local Deep Research ($login8)"
    Assert-That ([int]$cfg8['DeepResearchPort'] -eq 5055 -and @(Get-ChildItem -Path (Join-Path $Work 'ProgramData') -Recurse -Filter 'Local AI - Deep Research.url' -ErrorAction SilentlyContinue).Count -eq 1) 'the config records the port and the Start menu has a Deep Research shortcut'
    Assert-That ((Get-Content -Raw -Encoding UTF8 (Join-Path $aiRoot 'install-report.md')) -match 'Deep research: http://localhost:5055') 'the install report names the research address'
    # A re-run with the account in place signs in instead of making another one.
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
    $rc8b = Get-Content -Raw -Encoding UTF8 -LiteralPath $rcFile | ConvertFrom-Json
    Assert-That ($LASTEXITCODE -eq 0 -and $rc8b.password -eq $rc8.password -and @((Read-LaiState -Path (Join-Path $aiRoot 'install-state.json'))['flags']['configureWarnings']).Count -eq 0) 're-run without the switch keeps deep research on and reuses the account'
    & /usr/bin/docker volume create localai-deep-research 2>$null | Out-Null
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -NoDeepResearch
    $env8c = @(Get-Content -Encoding UTF8 (Join-Path $aiRoot 'Stack/.env'))
    $gone = -not ((& /usr/bin/docker container inspect deep-research 2>$null) -and $LASTEXITCODE -eq 0)
    $volKept = [bool](& /usr/bin/docker volume inspect localai-deep-research 2>$null) -and $LASTEXITCODE -eq 0
    Assert-That ($env8c -contains 'COMPOSE_PROFILES=' -and $gone -and $volKept -and [int](Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json'))['DeepResearchPort'] -eq 0) '-NoDeepResearch turns the profile off and removes the container, the data volume stays'
    Assert-That (@(Get-ChildItem -Path (Join-Path $Work 'ProgramData') -Recurse -Filter 'Local AI - Deep Research.url' -ErrorAction SilentlyContinue).Count -eq 0) 'and its Start-menu shortcut is removed'
    Assert-That ((Read-LaiState -Path (Join-Path $aiRoot 'install-state.json'))['flags']['params']['DeepResearch'] -eq $false) 'the off switch is remembered (a later plain re-run does not bring it back)'
    & /usr/bin/docker rm -f deep-research 2>$null | Out-Null
    & /usr/bin/docker volume rm localai-deep-research 2>$null | Out-Null
} else { Write-Host "  SKIP        $ldrImage is not on this machine (docker pull it to run this phase)" -ForegroundColor DarkGray }

} finally {
    $env:LOCALAI_TEST_FAIL_STAGE = ''
    & /usr/bin/docker rm -f open-webui lai-test-elsewhere deep-research 2>$null | Out-Null
    # A 'searxng' that phase 7e made as another setup's goes; the sandbox's own comes back.
    foreach ($id in @(& /usr/bin/docker ps -aq --filter 'name=^/searxng$' --filter 'label=lai-test=1')) { if ($id) { & /usr/bin/docker rm -f $id 2>$null | Out-Null } }
    if ($parkedSearxng) { & /usr/bin/docker rename searxng-uninstall-test-keep searxng 2>$null | Out-Null }
    & /usr/bin/docker volume rm owui-empty 2>$null | Out-Null
    & /usr/bin/docker ps -aq --filter 'name=^/open-webui-legacy-' | ForEach-Object { & /usr/bin/docker rm -f $_ | Out-Null }
    & /usr/bin/docker volume rm open-webui owui-old 2>$null | Out-Null
    # The installer pointed the shared Open WebUI at the guard on :11435; point it back at Ollama.
    try {
        Import-Module (Join-Path $src 'lib/LocalAI.psm1') -Force
        $tok = Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email $Email -Password $Password
        $oc = ConvertTo-LaiHashtable (Invoke-LaiApi -Uri 'http://127.0.0.1:3000/ollama/config' -Token $tok)
        $cfgs = @{}; if ($oc.ContainsKey('OLLAMA_API_CONFIGS') -and $oc['OLLAMA_API_CONFIGS']) { $cfgs = $oc['OLLAMA_API_CONFIGS'] }
        Invoke-LaiApi -Method POST -Uri 'http://127.0.0.1:3000/ollama/config/update' -Token $tok -Body @{ ENABLE_OLLAMA_API = $true; OLLAMA_BASE_URLS = [object[]]@('http://127.0.0.1:11434'); OLLAMA_API_CONFIGS = $cfgs } | Out-Null
    } catch { Write-Host "  could not point Open WebUI back at Ollama: $($_.Exception.Message)" -ForegroundColor Yellow }
    if ($guardProc -and -not $guardProc.HasExited) { $guardProc.Kill() }
    # What the installer's skills step put into the shared Open WebUI (skills, the notebook, preset links).
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Reset-Sandbox.ps1') -SkillsOnly -Email $Email -Password $Password | Out-Null
}
if ($failures -eq 0) { Write-Host "`nMOCK RUN PASSED" -ForegroundColor Green } else { Write-Host "`nMOCK RUN FAILED ($failures)" -ForegroundColor Red }
exit $failures
