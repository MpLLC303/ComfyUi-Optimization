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
    name/SID, OS build, drive free space) and, only in a phase that asks for it, the user's
    environment variables ($global:MockUserEnv), a system-wide OLLAMA_MODELS
    ($global:MockMachineModels) and what Preflight is told of the running Ollama's list of models
    ($global:MockOllamaListed). Nothing else in the installer is changed.

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
# The colour a captured Write-Host line was written in, as a colour name, or '' when it has none
# that can be passed on. A line written with no -ForegroundColor carries the host's current colour,
# and PowerShell on Linux gives that as -1 (not known): no colour name, and handed to Write-Host it
# ends the suite with 'Cannot bind parameter ForegroundColor' (the first CI round of batch 5 stopped
# that way in phase 6d, at the first blank line of the installer run it captures).
function ConvertTo-ColourName($Carried) {
    if ($null -eq $Carried -or -not [Enum]::IsDefined([ConsoleColor], $Carried)) { return '' }
    return [string]$Carried
}
function Get-ScreenColour($Line) {
    if ($Line -isnot [System.Management.Automation.InformationRecord] -or $Line.MessageData -isnot [System.Management.Automation.HostInformationMessage]) { return '' }
    return (ConvertTo-ColourName $Line.MessageData.ForegroundColor)
}
# Asked here, in the first second of the suite, and not twenty minutes in where phase 6d needs it:
# the value Linux gives, and a line this host writes with no colour of its own, read back and
# printed again the way phase 6d does it.
$plainColour = '?'; $plainShown = ''
try {
    $plainLine = @(Write-Host '  a line with no colour of its own, captured and printed again' 6>&1)[0]
    $plainColour = Get-ScreenColour $plainLine
    if ($plainColour) { Write-Host "$plainLine" -ForegroundColor $plainColour } else { Write-Host "$plainLine" }
    $plainShown = 'printed'
} catch { $plainShown = "not printed: $($_.Exception.Message)" }
Assert-That ($plainShown -eq 'printed' -and ($plainColour -eq '' -or [Enum]::GetNames([ConsoleColor]) -contains $plainColour)) "a captured line with no colour of its own can be printed again: it is given a colour only when it carries a colour name (carried: '$plainColour'; $plainShown)"
Assert-That ((ConvertTo-ColourName ([Enum]::ToObject([ConsoleColor], -1))) -eq '' -and (ConvertTo-ColourName $null) -eq '' -and (ConvertTo-ColourName ([ConsoleColor]::Red)) -eq 'Red') 'the colour of a captured line is passed on only as a colour name: -1 (what PowerShell on Linux gives for no colour) and nothing at all are no colour, Red is Red'

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
    @('$qualifier = Split-Path -Qualifier $Path', 'return [Math]::Round($global:MockFreeBytes / 1GB, 1)'),
    # Windows keeps a user's environment variables in the registry; this machine has no such scope (a
    # read gives nothing, a write is dropped). A phase that needs one sets $global:MockUserEnv to a
    # hashtable, which then stands in for it: Set-UserEnv's read and write, and every read of the
    # user's OLLAMA_MODELS. While it is $null (every other phase) the installer's own code runs.
    @('$current = [Environment]::GetEnvironmentVariable($Name, ''User'')', '$current = $(if ($null -ne $global:MockUserEnv) { $global:MockUserEnv[$Name] } else { [Environment]::GetEnvironmentVariable($Name, ''User'') })'),
    @('[Environment]::SetEnvironmentVariable($Name, $Value, ''User'')', 'if ($null -ne $global:MockUserEnv) { if ($Value -eq '''') { $global:MockUserEnv.Remove($Name) } else { $global:MockUserEnv[$Name] = $Value } } else { [Environment]::SetEnvironmentVariable($Name, $Value, ''User'') }'),
    @('[Environment]::GetEnvironmentVariable(''OLLAMA_MODELS'', ''User'')', '$(if ($null -ne $global:MockUserEnv) { $global:MockUserEnv[''OLLAMA_MODELS''] } else { [Environment]::GetEnvironmentVariable(''OLLAMA_MODELS'', ''User'') })'),
    # The same for a system-wide OLLAMA_MODELS, which the installer only reads: a phase that sets
    # $global:MockMachineModels to a folder has one; while it is $null the installer's own code runs.
    @('[Environment]::GetEnvironmentVariable(''OLLAMA_MODELS'', ''Machine'')', '$(if ($null -ne $global:MockMachineModels) { $global:MockMachineModels } else { [Environment]::GetEnvironmentVariable(''OLLAMA_MODELS'', ''Machine'') })'),
    # What Preflight is told when it asks the running Ollama whether it has models (it asks for a
    # folder in use that it does not look at). The sandbox's real Ollama always answers, and always
    # with models: a phase that sets $global:MockOllamaListed to an answer (Content and Listed, as
    # Get-OllamaListedContent gives them) has an Ollama that lists none, or does not answer. While
    # it is $null the installer's own code asks the real one.
    @('$byList = Get-OllamaListedContent -OllamaUrl $OllamaUrl', '$byList = $(if ($null -ne $global:MockOllamaListed) { $global:MockOllamaListed } else { Get-OllamaListedContent -OllamaUrl $OllamaUrl })')
)
foreach ($p in $patches) {
    if (-not $text.Contains($p[0])) { throw "patch target not found: $($p[0])" }
    $text = $text.Replace($p[0], $p[1])
}
Set-Content -Path $inst -Value $text
# The window stays open after the installer ends (-NoExit), and with it the thread that asked Windows
# not to sleep: Stop-Install has to take that request back. kernel32 is Windows only, so what is
# checked here is the function's own text: the guard, the call and its value, all before the exit.
$stopFn = [regex]::Match($text, '(?s)function Stop-Install \{.*?\r?\n\}').Value
$awakeGuardAt = $stopFn.IndexOf("if ('LaiPower' -as [type])")
$awakeClearAt = $stopFn.IndexOf('[LaiPower]::SetThreadExecutionState([uint32]2147483648)')
Assert-That ($awakeGuardAt -ge 0 -and $awakeClearAt -gt $awakeGuardAt -and $awakeClearAt -lt $stopFn.IndexOf('exit $Code') -and $stopFn -match '(?s)try \{[^{}]*SetThreadExecutionState\(\[uint32\]2147483648\)[^{}]*\} catch \{') 'Stop-Install clears the keep-awake request before it exits (ES_CONTINUOUS alone, only when the LaiPower type is loaded, inside try/catch)'

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
# A phase can say what a start of the Ollama app leaves in server.log ($global:MockOllamaLog: the
# 'server config' line of a start through Explorer, User, and of one from the installer's own session,
# Session), with the time of the start, as each real start logs a new line. The OLLAMA_HOST a start
# from the session would inherit from the installer's process is kept as well.
$global:MockOllamaLog = $null
$global:SessionStartHosts = New-Object System.Collections.ArrayList
function global:Start-Process {
    param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $Verb, $ErrorAction)
    Record "Start-Process $FilePath $ArgumentList"
    if ($Verb -eq 'RunAs') { Record "RUNAS $($ArgumentList -join ' ')" }
    if ("$FilePath $ArgumentList" -like '*ollama app.exe*') {
        $asUser = "$FilePath" -like '*explorer.exe'
        if (-not $asUser) { [void]$global:SessionStartHosts.Add([string]$env:OLLAMA_HOST) }
        if ($global:MockOllamaLog) {
            $line = $global:MockOllamaLog['Session']; if ($asUser) { $line = $global:MockOllamaLog['User'] }
            Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'Ollama/server.log') -Value ('time=' + [DateTime]::UtcNow.ToString('o') + ' ' + ($line -replace '^time=\S+\s*', ''))
        }
    }
    if ($PassThru) { [pscustomobject]@{ ExitCode = 0 } }
}
# A phase can make the copy of a manual install's data into the managed volume fail part-way
# ($global:MockCopyFail), as a disk that fills up does: something is written, then the copy stops.
$global:MockCopyFail = $false
# And the backup taken before that copy ($global:MockBackupFail = the name of the volume it is taken
# of): the archive cannot be written, as on a Backups drive that is full.
$global:MockBackupFail = ''
# The user's environment variables, for a phase that sets a hashtable here, a system-wide
# OLLAMA_MODELS, for a phase that sets a folder here, and the running Ollama's list of models as
# Preflight hears of it, for a phase that sets an answer here (see $patches).
$global:MockUserEnv = $null
$global:MockMachineModels = $null
$global:MockOllamaListed = $null
function global:docker {
    $a = @($args)
    if ($a[0] -eq 'compose') { Record "docker $($a -join ' ')"; $global:LASTEXITCODE = 0; return }
    if ($a[0] -eq 'exec' -and $a[1] -eq 'open-webui') { $global:LASTEXITCODE = 0; return '{"version":"0.35.1"}' }
    if ($global:MockBackupFail -and $a[0] -eq 'run' -and $a -contains ($global:MockBackupFail + ':/data:ro') -and $a -contains 'czf') {
        Record "docker backup archive of $($global:MockBackupFail) failed (mock)"
        $global:LASTEXITCODE = 1
        return 'tar: write error: No space left on device'
    }
    if ($global:MockCopyFail -and $a[0] -eq 'run' -and $a -contains 'open-webui:/to') {
        & /usr/bin/docker run --rm -v open-webui:/to alpine:3.20 sh -c 'echo half > /to/half-copied.txt' | Out-Null
        Record 'docker copy into open-webui failed part-way (mock)'
        $global:LASTEXITCODE = 1
        return 'cp: write error: No space left on device'
    }
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
# must tell it how to pass the folder on. Every script the rules name outside Never is named in the
# intro, and either really declares -AIRoot or is named there together with LOCALAI_ROOT (the toolkit
# update, Get-LocalAI.ps1, has no parameters and reads the folder from that variable).
$agentIntro = [regex]::Match($agentText, '(?s)^(.*?)## Never').Groups[1].Value
$agentOutsideNever = [regex]::Replace($agentText, '(?s)## Never.*?(?=## Fine without asking)', '')
$agentRootScripts = @([regex]::Matches($agentOutsideNever, '[A-Za-z][A-Za-z0-9-]*\.ps1') | ForEach-Object { $_.Value } | Select-Object -Unique)
$agentRootBad = @($agentRootScripts | Where-Object {
        $takesRoot = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $src $_)) -cmatch '\[string\]\$AIRoot\s*='
        $namedInIntro = $agentIntro -match [regex]::Escape($_)
        $viaEnv = $agentIntro -match ('(?s)' + [regex]::Escape($_) + '.{0,200}LOCALAI_ROOT')
        -not ($namedInIntro -and ($takesRoot -or $viaEnv))
    })
Assert-That ($agentIntro -match [regex]::Escape('-AIRoot <that folder>') -and $agentRootScripts.Count -ge 5 -and $agentRootBad.Count -eq 0) "the rules tell the agent to pass -AIRoot to the scripts that take it and to use LOCALAI_ROOT for the toolkit update ($($agentRootScripts.Count) scripts named outside Never; not covered: $($agentRootBad -join ', '))"

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
# Every phase here passes -SkipTests (phase 6d does not, but puts a stand-in in the health check's
# place), so the installer's Verify stage never runs the real health check (which then prints 'SKIP
# Integrity watch: an install, update or model update is running') in this suite;
# Invoke-WatchTest.ps1 section 10 runs that case with a stand-in for the installer. What
# makes it true is read from the installer instead: it takes the setup lock into $script:SetupLock,
# runs the health check in its own process (not a child, which could not see that lock as its own)
# and records the baseline only after it.
$igLockAt = $text.IndexOf('$script:SetupLock = Enter-LaiSetupLock')
$igVerifyAt = $text.IndexOf("& (Join-Path `$SourceRoot 'Test-LocalAI.ps1') -AIRoot `$AIRoot")
$igSaveAt = $text.IndexOf('Save-LaiIntegrityBaseline -AIRoot $AIRoot -Reason ''install''')
$igHealth = Get-Content -Raw -Encoding UTF8 (Join-Path $copy 'Test-LocalAI.ps1')
Assert-That ($igLockAt -ge 0 -and $igVerifyAt -gt $igLockAt -and $igSaveAt -gt $igVerifyAt) 'the installer holds the setup lock, runs the health check in its own process and records the baseline only after it'
Assert-That ($igHealth -match 'Get-Variable -Name SetupLock' -and $igHealth -match "Skip 'an install, update or model update is running") 'and the health check, called by an installer that holds the lock, skips the integrity line instead of advising on findings against the old baseline'
$tok2 = Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email $Email -Password $Password
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
Assert-That ($allLogs -notmatch 'This update adds the official models') 'a first install is not told that an update adds the official models, also not where it goes on after its reboot (its first pass recorded the choice)'
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
$choice3 = @($st3.flags.trialChoice)
Assert-That ($p3Log -notmatch 'Downloading testorg/does-not-exist' -and $choice3 -contains 'trial-ok' -and $choice3 -notcontains 'trial-missing') "a trial that failed for a reason of its own (its tag is gone) left the choice: a re-run without -TrialModels does not download it again (trialChoice: $($choice3 -join ', '))"
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

Write-Host "`n=== PHASE 4a: a preset that is no longer selected is held safe too, and the health check says when it is not ===" -ForegroundColor Cyan
# The trial was dropped in phase 4: its preset is still in Open WebUI, hidden, and a chat can still be
# started on it. Here it is given the switches an install from before the writing tools were switched
# off wrote: seven, none of them for notes, tasks, automations, calendar, notifications, channels or
# sub-agents, and Open WebUI takes a missing switch for on. The installer wrote only the selected
# presets and the health check judged only those, so this preset stayed open and no row said so.
$owui = 'http://127.0.0.1:3000'
$writing4a = 'use its notes, tasks, automations, calendar, notifications, channels, subagents tools'
$trialOld = ConvertTo-LaiHashtable (Get-LaiWebUIModel -BaseUrl $owui -Token $tok4 -Id 'trial-standin')
$trialOld['meta']['builtinTools'] = @{ memory = $true; web_search = $true; knowledge = $true; chats = $false; time = $true; image_generation = $false; code_interpreter = $false }
if ($null -eq $trialOld['params']) { $trialOld['params'] = @{} }
Invoke-LaiApi -Method POST -Uri "$owui/api/v1/models/model/update" -Body $trialOld -Token $tok4 | Out-Null
$switchNames = { param($Preset) if ($Preset -and $Preset.meta -and $Preset.meta.builtinTools) { @($Preset.meta.builtinTools.PSObject.Properties | ForEach-Object { [string]$_.Name }) } }
$tpOld = Get-LaiWebUIModel -BaseUrl $owui -Token $tok4 -Id 'trial-standin'
$oldNames = @(& $switchNames $tpOld)
Assert-That ($oldNames.Count -eq 7 -and $oldNames -cnotcontains 'notes' -and $oldNames -cnotcontains 'subagents' -and $tpOld.meta.hidden -eq $true) "setup: the trial preset, not selected and hidden, has the seven old switches and none for the writing tools ($($oldNames -join ', '))"
# Asked without writing anything first (-ReadOnly): the catalog's presets that are in Open WebUI, the
# open one named with what the assistant can do there, and the preset left as it was.
$every4a = @((Get-LaiCatalog -Path $env:LOCALAI_TEST_CATALOG -IncludeTrials).Models)
$asked4a = @(Invoke-LaiPresetSafety -BaseUrl $owui -Token $tok4 -Entries $every4a -ReadOnly)
$askedTrial = @($asked4a | Where-Object { $_.Preset -eq 'trial-standin' })
$askedOn = ''; if ($askedTrial.Count -eq 1) { $askedOn = @($askedTrial[0].On) -join ' and ' }
Assert-That ($askedTrial.Count -eq 1 -and $askedOn -ceq $writing4a -and -not $askedTrial[0].Written -and @($asked4a | Where-Object { $_.Preset -like '*-missing' }).Count -eq 0 -and @(& $switchNames (Get-LaiWebUIModel -BaseUrl $owui -Token $tok4 -Id 'trial-standin')).Count -eq 7) "asked with -ReadOnly, the real Open WebUI's unselected trial preset is found open (the assistant can $askedOn), presets that were never set up are not listed, and nothing is written"
# The health check itself, the copy in AI\Scripts, in a process of its own; only the row of this
# preset is read (this simulated PC has no GPU and no containers of its own, so other rows fail).
$healthRow = { param([string]$Check)
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $hcLines = @(& pwsh -NoProfile -File (Join-Path $aiRoot 'Scripts/Test-LocalAI.ps1') -AIRoot $aiRoot -Quick -NoContainers 2>&1 | ForEach-Object { "$_" })
    $ErrorActionPreference = $prevPref
    $hcRow = @($hcLines | Where-Object { $_ -match (' (PASS|WARN|FAIL|SKIP) ' + [regex]::Escape($Check) + ': ') } | Select-Object -Last 1)
    if ($hcRow.Count -eq 1) { return [string]$hcRow[0] }
    return ('no such row; the health check ended with: ' + (@($hcLines | Select-Object -Last 3) -join ' / '))
}
$trialRow = 'Preset Trial: stand-in (not selected)'
$rowOpen = & $healthRow $trialRow
Assert-That ($rowOpen -match (' FAIL ' + [regex]::Escape("${trialRow}: the assistant can $writing4a in this preset")) -and $rowOpen -match 'run Start menu > Local AI - Update toolkit to switch that off') "the health check fails a toolkit preset that is in Open WebUI without being selected and has the writing tools on, and names Update toolkit as the step ($rowOpen)"
# The next installer run is the first one of phase 4b, in which the trial is asked for again and
# left out for the busy GPU: still not selected. What that run did to this preset is checked there.

Write-Host "`n=== PHASE 4b: the official models come back while the GPU is busy ===" -ForegroundColor Cyan
# Forget official-ok's GPU check, so this run has to wait for an idle GPU before checking it again.
# The same for the trial, which this run asks for again: it is skipped for the busy GPU as well.
$st = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$st.tuning.PSObject.Properties.Remove('official-ok')
$st.tuning.PSObject.Properties.Remove('trial-ok')
$st | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $aiRoot 'install-state.json')
$global:MockGpu = 'NVIDIA GeForce RTX 3090, 566.36, 24576, 20000, 4576'
try { & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels trial-ok -OfficialModels all -GpuWaitMinutes 0 } finally { $global:MockGpu = $null }
$c4b = $LASTEXITCODE
$log4b = Get-Content -Raw (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
$st4b = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
Assert-That ($c4b -eq 0 -and $log4b -match 'Official: stand-in is set up on the next run: the GPU was busy') "a busy GPU skips the official model for now and the install completes (exit $c4b)"
Assert-That (-not $st4b.flags.officialFailed.PSObject.Properties['official-ok'] -and [string]$st4b.flags.officialFailed.'official-missing'.Source) 'a busy GPU is not recorded as the model failing (a missing tag is)'
Assert-That ($log4b -match 'Trial: stand-in is set up on the next run: the GPU was busy' -and @($st4b.flags.selectedModels) -notcontains 'trial-ok' -and @($st4b.flags.trialChoice) -contains 'trial-ok') "a trial skipped for the busy GPU is left out of this run and stays the choice (selected: $(@($st4b.flags.selectedModels) -join ', '); trialChoice: $(@($st4b.flags.trialChoice) -join ', '))"
# The preset of phase 4a, open and not selected in that run either: one installer run (what Update
# toolkit runs) has switched the writing tools off on it and says so, the rest of the preset is as
# it was, nothing was created, and the health check row that failed passes.
$tpSafe = Get-LaiWebUIModel -BaseUrl $owui -Token $tok4 -Id 'trial-standin'
$safeNames = @(& $switchNames $tpSafe)
$notOff4a = @('chats', 'code_interpreter', 'notes', 'tasks', 'automations', 'calendar', 'notifications', 'channels', 'subagents' | Where-Object { -not ($safeNames -ccontains $_ -and $tpSafe.meta.builtinTools.$_ -is [bool] -and $tpSafe.meta.builtinTools.$_ -eq $false) })
Assert-That ($c4b -eq 0 -and @($st4b.flags.selectedModels) -notcontains 'trial-ok' -and $log4b.Contains("Preset 'Trial: stand-in' made safe again: the assistant could $writing4a there, which is switched off now")) "the next installer run, with the trial still not selected, says in its log what it switched off on that preset (exit $c4b)"
Assert-That ($notOff4a.Count -eq 0 -and @(Get-LaiPresetToolRisk $tpSafe.meta).Count -eq 0 -and $tpSafe.meta.capabilities.code_interpreter -eq $false) "past chats, code and the seven writing tools are written out as off on the unselected preset in the real Open WebUI (not off: $($notOff4a -join ', '); switches: $($safeNames -join ', '))"
Assert-That ($tpSafe.meta.hidden -eq $true -and $tpSafe.meta.builtinTools.memory -eq $true -and $tpSafe.meta.builtinTools.time -eq $true -and [string]$tpSafe.name -eq [string]$tpOld.name -and [string]$tpSafe.params.system -eq [string]$tpOld.params.system -and [string]$tpSafe.base_model_id -eq [string]$tpOld.base_model_id) 'and the rest of it is as it was: still hidden, the switches the toolkit leaves on, its name, base model and system prompt'
Assert-That (-not (Get-LaiWebUIModel -BaseUrl $owui -Token $tok4 -Id 'trial-missing') -and -not (Get-LaiWebUIModel -BaseUrl $owui -Token $tok4 -Id 'official-missing')) 'a catalog preset that was never set up is not created by it'
$rowSafe = & $healthRow $trialRow
Assert-That ($rowSafe -match (' PASS ' + [regex]::Escape("${trialRow}: "))) "and after that one run the same health check row passes ($rowSafe)"
# No -TrialModels on this run: the trial comes from the recorded choice, not from what was set up.
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -GpuWaitMinutes 10
$st4c = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$op = Get-TestPreset 'official-standin'
Assert-That ($LASTEXITCODE -eq 0 -and @($st4c.flags.selectedModels) -contains 'official-ok' -and $op -and -not $op.meta.hidden) "the next run with an idle GPU sets it up and shows its preset again (exit $LASTEXITCODE)"
Assert-That (@($st4c.flags.selectedModels) -contains 'trial-ok' -and $null -ne $st4c.tuning.'trial-ok' -and @($st4c.flags.trialChoice) -contains 'trial-ok') "and it sets up the trial skipped before, though this run was given no -TrialModels: selected and tuned (selected: $(@($st4c.flags.selectedModels) -join ', '))"

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
# On the same run, Ollama's start-up log shows a setting other than the one just written (Explorer had
# not taken the new environment over yet): the installer starts Ollama from its own elevated session
# to measure with the right settings, and must not leave it running as administrator afterwards.
$srvLog4 = Join-Path $env:LOCALAPPDATA 'Ollama/server.log'
$srvGood4 = (Get-Content -Raw -Encoding UTF8 -LiteralPath $srvLog4).TrimEnd()
$srvWrong4 = $srvGood4 -replace 'OLLAMA_FLASH_ATTENTION:[^ \]]*', 'OLLAMA_FLASH_ATTENTION:false'
# An Ollama that does not log the key: put it in, so the line reads as a wrong value all the same.
if ($srvWrong4 -ceq $srvGood4) { $srvWrong4 = ([regex]'map\[').Replace($srvGood4, 'map[OLLAMA_FLASH_ATTENTION:false ', 1) }
$ollamaStarts = { param([int]$From) @($global:Calls | Select-Object -Skip $From | Where-Object { $_ -like 'Start-Process *ollama app.exe*' }) }
Set-Content -LiteralPath $srvLog4 -Value $srvWrong4
$calls4e = $global:Calls.Count
try { & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -OfficialModels all } finally { Set-Content -LiteralPath $srvLog4 -Value $srvGood4 }
$st4e = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
Assert-That ($LASTEXITCODE -eq 0 -and @($st4e.flags.selectedModels) -contains 'official-ok' -and -not $st4e.flags.officialFailed.PSObject.Properties['official-ok']) "naming the choice again (-OfficialModels all) retries it (exit $LASTEXITCODE)"
$log4e = Get-Content -Raw -Encoding UTF8 (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
$starts4e = @(& $ollamaStarts $calls4e)
$asUser4e = @($starts4e | Where-Object { $_ -like '*explorer.exe*' }).Count
$mainRestarts4e = [regex]::Matches($log4e, 'Restarting Ollama so it picks up the settings').Count
Assert-That ($log4e -match 'Ollama did not pick up the new settings \(OLLAMA_FLASH_ATTENTION=false' -and ($starts4e.Count - $asUser4e) -ge 1) "wrong settings in server.log: Ollama is restarted from the installer's own session for the measuring ($($starts4e.Count) starts, $asUser4e via Explorer)"
# One start through Explorer more than the settings restart(s): the one that ends the Tuning stage.
Assert-That ($asUser4e -eq $mainRestarts4e + 1 -and $starts4e.Count -ge 2 -and $starts4e[-1] -like '*explorer.exe*' -and $log4e -match 'Restarting Ollama without administrator rights' -and -not $st4e.flags.PSObject.Properties['ollamaElevated']) "and once the presets are measured it is started as the signed-in user again: the last start is through Explorer, nothing is left to remember ($asUser4e via Explorer, $mainRestarts4e settings restart(s))"

Write-Host "`n=== PHASE 4f: the owner's own default model and hidden presets survive an update ===" -ForegroundColor Cyan
$tokF = Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email $Email -Password $Password
Set-LaiWebUIModelsConfig -BaseUrl 'http://127.0.0.1:3000' -Token $tokF -DefaultModel 'local-fast' | Out-Null
Hide-LaiWebUIModel -BaseUrl 'http://127.0.0.1:3000' -Token $tokF -Id 'official-standin' | Out-Null
# On the same run, the wrong settings in server.log again, and this time Explorer goes on handing out
# the old environment: every start through it logs the wrong setting, every start from the installer's
# session the right one (the Start-Process mock writes the line a real start would). The start as the
# signed-in user at the end of Tuning answers, but with the wrong setting: Ollama stays up from the
# installer's session, and the owner is told so. No test hook in the installer does this. The end
# screen is captured (and still shown), as in phase 3.
$elevatedNotice = 'Ollama is running with administrator rights: quit it from its tray icon and start it from the Start menu'
$restoreFn = [regex]::Match($text, '(?s)function Restore-OllamaAsUser \{.*?\r?\n\}').Value
Assert-That ($restoreFn -match 'Start-OllamaAsUser' -and $restoreFn -notmatch 'LOCALAI_TEST_') 'the restart of Ollama without administrator rights has no test switch that could turn it off'
Set-Content -LiteralPath $srvLog4 -Value $srvWrong4
$global:MockOllamaLog = @{ User = $srvWrong4; Session = $srvGood4 }
$global:SessionStartHosts.Clear()
$calls4f = $global:Calls.Count
try {
    $screen4f = @(& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none 6>&1 | ForEach-Object { $l = "$_"; Write-Host $l; $l })
    $c4f = $LASTEXITCODE
} finally { $global:MockOllamaLog = $null; Set-Content -LiteralPath $srvLog4 -Value $srvGood4 }
$tokF = Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:3000' -Email $Email -Password $Password
$mcfgF = Invoke-LaiApi -Uri 'http://127.0.0.1:3000/api/v1/configs/models' -Token $tokF
$opF = Get-TestPreset 'official-standin'
Assert-That ($c4f -eq 0 -and [string]$mcfgF.DEFAULT_MODELS -eq 'local-fast') "a default model the owner picked is kept by an update (default '$($mcfgF.DEFAULT_MODELS)', exit $c4f)"
Assert-That ($opF -and $opF.meta.hidden -eq $true) 'a selected preset the owner hid stays hidden'
$st4f = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$rep4f = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-report.md')
$starts4f = @(& $ollamaStarts $calls4f)
Assert-That (@($screen4f | Where-Object { $_ -like "*Needs attention: $elevatedNotice*" }).Count -eq 1 -and $rep4f -match '## Settings that need attention' -and $rep4f.Contains("- $elevatedNotice")) 'Ollama could not be started as the signed-in user: the end screen says once, under Needs attention, that it runs with administrator rights and what to do, and so does the report'
Assert-That (@($screen4f | Where-Object { $_ -like "*WARN*$elevatedNotice*" }).Count -eq 1 -and $st4f.flags.ollamaElevated -eq $true -and $starts4f.Count -ge 1 -and $starts4f[-1] -notlike '*explorer.exe*') "it is said where it happens too, remembered for the next run, and Ollama was started again, from the installer's session, so the run could go on ($($starts4f.Count) starts)"
Assert-That (@($screen4f | Where-Object { $_ -like '*WARN*could not be left running without administrator rights: started as the signed-in user it shows OLLAMA_FLASH_ATTENTION=false*' }).Count -eq 1) 'an answer from the API was not taken for a good start: the line that start logged was read, and the screen names the setting it shows wrong'
# That last start is the first one from the session after the Models stage pointed OLLAMA_HOST at
# loopback for the ollama CLI: the server must get the user's own value (none here), the CLI its own back.
Assert-That ($global:SessionStartHosts.Count -ge 2 -and [string]$global:SessionStartHosts[$global:SessionStartHosts.Count - 1] -ne '127.0.0.1:11434' -and $env:OLLAMA_HOST -eq '127.0.0.1:11434') "the Ollama started from the session does not inherit the CLI's OLLAMA_HOST (it got '$($global:SessionStartHosts -join "', '")'; the installer's own is '$($env:OLLAMA_HOST)' again)"
Write-Host "`n=== PHASE 4g: an older toolkit over a newer install; a folder in AI that is not ours ===" -ForegroundColor Cyan
$cfgPathG = Join-Path $aiRoot 'localai-config.json'
$cfgG = Read-LaiState -Path $cfgPathG; $cfgG['ToolkitVersion'] = '2099.01.01'; Save-LaiState -State $cfgG -Path $cfgPathG
$foreignDir = Join-Path $aiRoot 'ComfyUI'; New-Item -ItemType Directory -Force -Path $foreignDir | Out-Null
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
$c4g = $LASTEXITCODE
$log4g = Get-Content -Raw (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
Assert-That ($c4g -eq 1 -and $log4g -match 'older than the installed 2099\.01\.01\. Nothing was changed') "an older toolkit refuses to run over a newer install (exit $c4g)"
$calls4h = $global:Calls.Count
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -AllowDowngrade
$c4h = $LASTEXITCODE
$log4h = Get-Content -Raw (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
Assert-That ($c4h -eq 0 -and $log4h -match 'also holds ComfyUI: their permissions are left alone') "-AllowDowngrade runs it; a folder in AI that is not the toolkit's keeps its permissions (exit $c4h)"
# One by one reaches only what is there at that moment, so the pass runs twice: in Preflight, and
# again once the last stage is done, for what the stages created in between. The user's own grant
# on the folder itself (the path, then a space: not a file inside it).
$aclCount = { param([object[]]$Recorded, [string]$Folder) @($Recorded | Where-Object { $_ -like ('icacls ' + $Folder + ' /inheritance:r /grant:r *' + $userSid + ':(OI)(CI)F *') }).Count }
$acl4h = @($global:Calls | Select-Object -Skip $calls4h)
$aclStack4h = & $aclCount $acl4h (Join-Path $aiRoot 'Stack'); $aclSkills4h = & $aclCount $acl4h (Join-Path $aiRoot 'Skills')
Assert-That ($aclStack4h -eq 2 -and $aclSkills4h -eq 2 -and $log4h -match "Permissions on the toolkit's own folders and files in .* set once more") "with such a folder there, the toolkit's own folders are locked down in Preflight and once more after the last stage (icacls calls in that run: Stack $aclStack4h, Skills $aclSkills4h)"
# The first run to complete after the one that left Ollama running as administrator puts that right.
$st4h = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
Assert-That ($log4h -match 'Restarting Ollama without administrator rights' -and $log4h -notmatch [regex]::Escape($elevatedNotice) -and -not $st4h.flags.PSObject.Properties['ollamaElevated']) 'the next run that reaches the end of Tuning starts Ollama as the signed-in user and forgets the notice'
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
# The same with the data in a folder of the PC (a bind mount) that is empty. A volume is backed up
# first, and the backup is what refuses it above; of a folder no backup is taken (it stays where it
# is), so here the copy's own look for webui.db is what stops the run. By then the managed volume
# has been made: it has to go again, or the next run would find 'both exist' and start on it empty.
$bindEmpty6c = Join-Path $Work 'owui-bind-empty'
New-Item -ItemType Directory -Force -Path $bindEmpty6c | Out-Null
& /usr/bin/docker rm -f open-webui 2>$null | Out-Null
& /usr/bin/docker create --name open-webui --label lai-test=1 -v "${bindEmpty6c}:/app/backend/data" alpine:3.20 sleep 3600 | Out-Null
$env:LOCALAI_TEST_FAIL_STAGE = 'Configure'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
$c6cBind = $LASTEXITCODE
$env:LOCALAI_TEST_FAIL_STAGE = ''
$log6cBind = Get-Content -Raw -LiteralPath (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
$legacyAfterBind = @(& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Names}}')
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& /usr/bin/docker volume inspect open-webui 2>&1 | Out-Null; $managedVolBind = ($LASTEXITCODE -eq 0)
& /usr/bin/docker container inspect open-webui 2>&1 | Out-Null; $oldKeptBind = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prevEap
Assert-That ($c6cBind -ne 0 -and $log6cBind -match 'The old Open WebUI data folder \([^)]*owui-bind-empty\) has no webui\.db, so nothing was copied' -and $log6cBind -notmatch 'Copied the old Open WebUI data' -and $log6cBind -notmatch 'Test hook') "an empty data folder of the PC (bind mount): the copy itself stops, and the run names that folder (exit $c6cBind)"
Assert-That (-not $managedVolBind -and $oldKeptBind -and $legacyAfterBind.Count -eq $legacyBefore.Count) "the managed volume made for that copy is gone again, the old container untouched under its name (volume there: $managedVolBind, container there: $oldKeptBind)"
& /usr/bin/docker rm -f open-webui 2>$null | Out-Null
& /usr/bin/docker volume rm owui-empty 2>$null | Out-Null
Remove-Item -LiteralPath $bindEmpty6c -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=== PHASE 6d: the copy of a manual install's data stops part-way; the next run; a failed acceptance check ===" -ForegroundColor Cyan
# A manual install with real data, and a disk that fills up while it is copied: the volume the run
# created a moment before must not stay. Left behind, the next run would find 'both exist', copy
# nothing and start Open WebUI on the half copy.
& /usr/bin/docker rm -f open-webui 2>$null | Out-Null
& /usr/bin/docker volume rm open-webui owui-6d 2>$null | Out-Null
& /usr/bin/docker volume create owui-6d | Out-Null
& /usr/bin/docker run --rm -v owui-6d:/data alpine:3.20 sh -c 'head -c 65536 /dev/urandom > /data/webui.db; echo marker-6d > /data/marker.txt' | Out-Null
& /usr/bin/docker create --name open-webui --label lai-test=1 -v owui-6d:/app/backend/data alpine:3.20 sleep 3600 | Out-Null
$legacyBefore6d = @(& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Names}}')
$preCompose6d = @(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*-pre-compose.tar.gz').Count
# First with a Backups drive that is full: the archive of the old data cannot be written. The copy,
# the stop and the rename are what that backup is taken for, so none of them may follow: no volume
# is made, and the old container keeps its name. (This data is complete, with its webui.db: what
# stops the run is the backup's result and nothing else.)
$callsBefore6d = $global:Calls.Count
$global:MockBackupFail = 'owui-6d'
$env:LOCALAI_TEST_FAIL_STAGE = 'Configure'
try { & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests } finally { $global:MockBackupFail = ''; $env:LOCALAI_TEST_FAIL_STAGE = '' }
$c6dBackup = $LASTEXITCODE
$log6dBackup = Get-Content -Raw -LiteralPath (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
$backupFails6d = @($global:Calls | Select-Object -Skip $callsBefore6d | Where-Object { $_ -eq 'docker backup archive of owui-6d failed (mock)' }).Count
$legacyAfter6dBackup = @(& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Names}}')
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& /usr/bin/docker volume inspect open-webui 2>&1 | Out-Null; $managedVol6dBackup = ($LASTEXITCODE -eq 0)
& /usr/bin/docker container inspect open-webui 2>&1 | Out-Null; $oldKept6dBackup = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prevEap
Assert-That ($c6dBackup -ne 0 -and $backupFails6d -eq 1 -and $log6dBackup -match 'The backup of the old Open WebUI data \(Docker volume owui-6d\) did not work' -and $log6dBackup -match 'it is not replaced without that backup' -and $log6dBackup -notmatch 'has no webui\.db' -and $log6dBackup -notmatch 'Test hook') "a backup of the old data that fails stops the run, which says that nothing is replaced without it (exit $c6dBackup; the archive failed $backupFails6d time(s))"
Assert-That (-not $managedVol6dBackup -and $oldKept6dBackup -and $legacyAfter6dBackup.Count -eq $legacyBefore6d.Count -and $log6dBackup -notmatch 'Copied the old Open WebUI data') "nothing was replaced: no managed volume made, no copy, the old container untouched under its name (volume there: $managedVol6dBackup, container there: $oldKept6dBackup)"
Assert-That (@(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*-pre-compose.tar.gz').Count -eq $preCompose6d) 'and no archive of that failed backup is left among the backups'
$global:MockCopyFail = $true
$env:LOCALAI_TEST_FAIL_STAGE = 'Configure'
try { & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests } finally { $global:MockCopyFail = $false; $env:LOCALAI_TEST_FAIL_STAGE = '' }
$c6d = $LASTEXITCODE
$log6d = Get-Content -Raw -LiteralPath (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName  # lai-ok: objects
$legacyAfter6d = @(& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Names}}')
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& /usr/bin/docker volume inspect open-webui 2>&1 | Out-Null; $managedVol6d = ($LASTEXITCODE -eq 0)
& /usr/bin/docker container inspect open-webui 2>&1 | Out-Null; $oldKept6d = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prevEap
Assert-That ($c6d -ne 0 -and $log6d -match 'Copying the old Open WebUI data failed: .*No space left on device' -and $log6d -match 'half-filled open-webui volume was removed again' -and $log6d -notmatch 'Test hook') "a copy that stops part-way stops the run, which says why and what it did about the volume (exit $c6d)"
Assert-That (-not $managedVol6d -and $oldKept6d -and $legacyAfter6d.Count -eq $legacyBefore6d.Count) "the volume that run created is gone again, the old container untouched under its name (volume there: $managedVol6d, container there: $oldKept6d)"
Assert-That (@(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter 'open-webui-*-pre-compose.tar.gz').Count -eq $preCompose6d + 1) 'and the old data was backed up before the copy was tried (a backup that works does not stop the run)'
# The next run, with room on the disk again: it finds no volume in the way and copies the data. This
# one also runs the acceptance checks (no -SkipTests), and three of them fail: a stand-in for
# Test-LocalAI.ps1 in the installer's own folder, which is where the installer runs it from. The end
# screen is captured with its colours (and still shown).
$realTest6d = Join-Path $aiRoot 'Scripts/Test-LocalAI.ps1'
$testAside6d = Join-Path $Work 'Test-LocalAI-aside-6d.ps1'
Copy-Item -LiteralPath $realTest6d -Destination $testAside6d -Force
# The integrity baseline that run records would take the stand-in for the installed health check:
# the one from before is put back with the script.
$baseline6d = Get-LaiIntegrityPath -AIRoot $aiRoot
$baselineAside6d = Join-Path $Work 'integrity-baseline-aside-6d.json'
$baselineKept6d = Test-Path -LiteralPath $baseline6d
if ($baselineKept6d) { Copy-Item -LiteralPath $baseline6d -Destination $baselineAside6d -Force }
Set-Content -LiteralPath $realTest6d -Value @('param([string]$AIRoot)', "Write-Host ('12:00:00 [FAIL] FAIL Stand-in check: one of three that fail in ' + `$AIRoot) -ForegroundColor Red", 'exit 3')
$screen6d = @()
try {
    $screen6d = @(& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot 6>&1 | ForEach-Object {
            # '' for a line with no colour of its own (Get-ScreenColour): on Linux such a line carries -1.
            $line6d = "$_"; $colour6d = Get-ScreenColour $_
            if ($colour6d) { Write-Host $line6d -ForegroundColor $colour6d } else { Write-Host $line6d }
            [pscustomobject]@{ Text = $line6d; Colour = $colour6d }
        })
    $c6d2 = $LASTEXITCODE
} finally {
    Copy-Item -LiteralPath $testAside6d -Destination $realTest6d -Force
    if ($baselineKept6d) { Copy-Item -LiteralPath $baselineAside6d -Destination $baseline6d -Force }
}
$copied6d = (& /usr/bin/docker run --rm -v open-webui:/d:ro alpine:3.20 sh -c 'cat /d/marker.txt; ls /d') -join ' '
$legacyNow6d = @(& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Names}}')
Assert-That ($copied6d -match '^marker-6d ' -and $copied6d -notmatch 'half-copied' -and $legacyNow6d.Count -eq $legacyBefore6d.Count + 1) "the next run copies the old data into a new volume, with nothing of the half copy in it, and keeps the old container under another name ($copied6d)"
$shown6d = @($screen6d | Where-Object { $_.Text.Trim() })
$last6d = $null; if ($shown6d.Count) { $last6d = $shown6d[-1] }
Assert-That ($c6d2 -eq 3 -and $last6d -and $last6d.Colour -eq 'Red' -and $last6d.Text -match '^3 of the acceptance checks FAILED' -and $last6d.Text -match 'run the installer again') "three failed acceptance checks: the installer exits 3, and the last line on the screen is red, with the count and what to do (exit $c6d2; last line $($last6d.Colour): $($last6d.Text))"
$block6d = @($shown6d | Where-Object { $_.Text -match '^(Open WebUI|Login|Password): ' })
Assert-That ($block6d.Count -eq 3 -and @($block6d | Where-Object { $_.Colour -ne 'Yellow' }).Count -eq 0 -and @($shown6d | Where-Object { $_.Colour -eq 'Green' -and $_.Text -match '^(Open WebUI|Login|Password|Research): ' }).Count -eq 0) "and the address, login and password lines above it are yellow, not the green of an install that passed ($(@($block6d | ForEach-Object { $_.Colour }) -join ', '))"
# As phase 6c left the simulated PC: no managed volume, no manual install, the health check itself.
foreach ($legacy6d in @($legacyNow6d | Where-Object { $legacyBefore6d -notcontains $_ })) { & /usr/bin/docker rm -f $legacy6d 2>$null | Out-Null }
& /usr/bin/docker rm -f open-webui 2>$null | Out-Null
& /usr/bin/docker volume rm open-webui owui-6d 2>$null | Out-Null
Remove-Item -LiteralPath $testAside6d, $baselineAside6d -Force -ErrorAction SilentlyContinue

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
Assert-That ($asUser7b -eq $mainRestarts7b + 2 -and $starts7b.Count -ge 3 -and $starts7b[-3] -like '*explorer.exe*' -and $starts7b[-2] -notlike '*explorer.exe*') "Model location restart: as the user first, from the elevated session only as the fallback ($($starts7b.Count) starts, $asUser7b via Explorer, $mainRestarts7b settings restart(s))"
# The run stopped right after that start from its own session, long before the end of Tuning: it
# must not end with Ollama running as administrator and nothing said.
$failAt7b = $log7b.IndexOf('Nothing was downloaded'); $restoreAt7b = $log7b.IndexOf('Restarting Ollama without administrator rights')
Assert-That ($starts7b.Count -ge 3 -and $starts7b[-1] -like '*explorer.exe*' -and $failAt7b -ge 0 -and $restoreAt7b -gt $failAt7b -and -not (Read-LaiState -Path $statePath)['flags'].ContainsKey('ollamaElevated')) 'a run that fails after starting Ollama from its own session starts it as the signed-in user again before it ends: the last start is through Explorer, after the failure, and nothing is left to remember'

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
# The folder also holds something that is not the toolkit's (ComfyUI kept next to it), so its
# permissions are set one by one, on what is there. On a first install Stack and Skills are not: the
# Stack and Configure stages make them, long after Preflight, and they must not be left open to
# every account until the next run.
New-Item -ItemType Directory -Force -Path (Join-Path $ai3 'ComfyUI') | Out-Null
$calls7f = $global:Calls.Count
$env:LOCALAI_TEST_FAIL_STAGE = 'Ollama'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $ai3 -SkipTests -TrialModels none
$env:LOCALAI_TEST_FAIL_STAGE = ''
$log7f = (@(Get-ChildItem -LiteralPath (Join-Path $ai3 'Logs') -Filter 'install-*.log' -ErrorAction SilentlyContinue) | ForEach-Object { Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName }) -join "`n"
Assert-That ($log7f -match '=+ Preflight =+' -and $log7f -match 'Test hook: stage Ollama failed' -and (Test-Path -LiteralPath (Join-Path $ai3 'Scripts/Install-LocalAI.ps1'))) 'the first run in a new folder went through Preflight and stopped at the Ollama stage'
Assert-That ((Get-FileHash -LiteralPath $theirRulesFile).Hash -eq $theirRulesHash -and [System.IO.File]::ReadAllText($theirRulesFile) -ceq $theirRules) 'a CLAUDE.md that was there before the first install is not replaced (byte for byte)'
Assert-That ($log7f -match 'already exists: left as it is' -and $log7f -notmatch 'Rules for an AI agent opened in this folder placed') 'and the log says it was left, not placed'
$acl7f = @($global:Calls | Select-Object -Skip $calls7f)
$aclStack7f = & $aclCount $acl7f (Join-Path $ai3 'Stack'); $aclSkills7f = & $aclCount $acl7f (Join-Path $ai3 'Skills')
Assert-That ($log7f -match 'also holds ComfyUI: their permissions are left alone' -and (Test-Path -LiteralPath (Join-Path $ai3 'Stack') -PathType Container) -and $aclStack7f -ge 1 -and $aclSkills7f -ge 1) "a first install next to a folder that is not the toolkit's: Stack and Skills are made in Preflight and locked down with the rest (icacls calls: Stack $aclStack7f, Skills $aclSkills7f)"
# Made early, Skills still gets the starter skills: the skills step puts them only into a folder it
# creates itself, and would find this one there already.
$skills7f = @(Get-ChildItem -LiteralPath (Join-Path $ai3 'Skills') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
Assert-That ($skills7f.Count -eq 3 -and $skills7f -contains 'remember-and-improve' -and (Test-Path -LiteralPath (Join-Path $ai3 'Skills/remember-and-improve/SKILL.md') -PathType Leaf) -and $log7f -match 'with the starter skills: ') "and Skills holds the three starter skills ($($skills7f -join ', '))"
# An install made before the installer placed this file has none: the update places it.
Remove-Item -LiteralPath $agentFile -Force
# The same update, and one more after it, on an install that is also from before the official models
# (no choice recorded, none of them set up or failed): the first says what the update adds and how to
# skip it, the second does not say it again. The state of the other phases is set aside meanwhile.
$stateAside = Join-Path $Work 'install-state-before-7f.json'
Copy-Item -LiteralPath $statePath -Destination $stateAside -Force
$st7f = Read-LaiState -Path $statePath
$st7f['flags'].Remove('officialChoice'); $st7f['flags'].Remove('officialFailed')
$st7f['flags']['selectedModels'] = @($st7f['flags']['selectedModels'] | Where-Object { $_ -notlike 'official-*' })
Save-LaiState -State $st7f -Path $statePath
$env:LOCALAI_TEST_FAIL_STAGE = 'Ollama'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
$log7fb = Get-NewestLog
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
$env:LOCALAI_TEST_FAIL_STAGE = ''
$log7fc = Get-NewestLog
$choice7f = @((Read-LaiState -Path $statePath)['flags']['officialChoice'])
Copy-Item -LiteralPath $stateAside -Destination $statePath -Force
Assert-That ((Test-Path -LiteralPath $agentFile -PathType Leaf) -and (Get-FileHash -LiteralPath $agentFile).Hash -eq (Get-FileHash -LiteralPath $agentTemplate).Hash) 'an update of an install without the file places the template, byte for byte'
Assert-That ($log7fb -match 'Rules for an AI agent opened in this folder placed' -and $log7fb -notmatch 'already exists: left as it is') 'and the log says it was placed'
$told7f = [regex]::Matches($log7fb + "`n" + $log7fc, 'This update adds the official models').Count
Assert-That ($log7fb -match 'This update adds the official models .* -OfficialModels none' -and $told7f -eq 1 -and $log7fc -match 'Test hook: stage Ollama failed' -and $choice7f.Count -eq 1 -and [string]$choice7f[0] -eq 'all') "an install from before the official models is told once what the update adds and how to skip it, not again on the next update; the choice is recorded as all (said $told7f time(s) in two runs; choice: $($choice7f -join ', '))"

Write-Host "`n=== PHASE 7g: another -ModelDir, back to Ollama's default folder, and whose OLLAMA_MODELS it is ===" -ForegroundColor Cyan
# Ollama keeps its models in its default folder: its start-up log says so, and they are there (the
# manifest of the catalog's model and a 3 MB blob stand in for them). A run with another -ModelDir
# used to point Ollama at the empty folder: every model downloaded again, the old copy left, and
# passing the old folder again did not bring it back. The user's environment variables are
# $global:MockUserEnv for this phase; the state of the other phases is set aside meanwhile.
$stateAside7g = Join-Path $Work 'install-state-before-7g.json'
Copy-Item -LiteralPath $statePath -Destination $stateAside7g -Force
$srv7g = (Get-Content -Raw -Encoding UTF8 -LiteralPath $serverLog).TrimEnd()
$otherModels = Join-Path $Work 'OtherModels'
$srvOther7g = $srv7g -replace 'OLLAMA_MODELS:[^ \]]*', ('OLLAMA_MODELS:' + $otherModels.Replace('\', '\\'))
# Folders with an apostrophe in the name: one that holds the models and one that -ModelDir is given
# (A), and one on a drive that is not there, which the variable and Ollama's log name (F). A message
# that tells the owner what to type has to write them as PowerShell reads one folder: in single
# quotes, the apostrophe doubled ($asTyped7g).
$aposModels = Join-Path $Work "Owner's Models"
$aposTarget = Join-Path $Work "Owner's New Models"
$goneModels = "Z:\Gone\Owner's models"
$srvApos7g = $srv7g -replace 'OLLAMA_MODELS:[^ \]]*', ('OLLAMA_MODELS:' + $aposModels.Replace('\', '\\'))
$srvGone7g = $srv7g -replace 'OLLAMA_MODELS:[^ \]]*', ('OLLAMA_MODELS:' + $goneModels.Replace('\', '\\'))
$asTyped7g = { param([string]$Folder) "'" + $Folder.Replace("'", "''") + "'" }
$modelName7g = Resolve-LaiModelName 'testorg/qwen3-abliterated:1.7b'
$manifest7g = Get-LaiModelManifestPath -ModelDir $plannedModels -Name $modelName7g
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest7g), (Join-Path $plannedModels 'blobs') | Out-Null
Set-Content -LiteralPath $manifest7g -Value '{}'
Set-Content -LiteralPath (Join-Path (Join-Path $plannedModels 'blobs') 'sha256-stand-in') -Value ('x' * 3MB) -NoNewline
$moveModels7g = { param([string]$From, [string]$To)
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    foreach ($part in 'manifests', 'blobs') { Move-Item -LiteralPath (Join-Path $From $part) -Destination (Join-Path $To $part) }
}
# The state a case starts from: flags to set (one given as $null is taken away), and what the record
# of the owner's own settings from before the first install holds for OLLAMA_MODELS ('' = not set).
$setState7g = { param([hashtable]$Flags, [string]$OwnersModels)
    $st7g = Read-LaiState -Path $statePath
    foreach ($flag7g in @($Flags.Keys)) { if ($null -eq $Flags[$flag7g]) { $st7g['flags'].Remove($flag7g) } else { $st7g['flags'][$flag7g] = $Flags[$flag7g] } }
    if (-not ($st7g['flags']['prevOllamaEnv'] -is [hashtable])) { $st7g['flags']['prevOllamaEnv'] = @{} }
    $st7g['flags']['prevOllamaEnv']['OLLAMA_MODELS'] = $OwnersModels
    Save-LaiState -State $st7g -Path $statePath
}
$global:MockUserEnv = @{}
try {
    # A: refused in Preflight, before anything changes. (Should it not be, the run stops at the next
    # stage instead of installing into the other folder.)
    $env:LOCALAI_TEST_FAIL_STAGE = 'Ollama'
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $otherModels
    $c7gA = $LASTEXITCODE
    $log7gA = Get-NewestLog
    $flags7gA = (Read-LaiState -Path $statePath)['flags']
    # (The refusal gave the size of that folder's blobs as well, added up by listing every file
    # under it with administrator rights, through whatever link lay there. No size is given now.)
    $refusal7g = { param([string]$Log) @($Log -split "`n" | Where-Object { $_ -match '-ModelDir .* is not the folder Ollama keeps its models in now' }) -join ' ' }
    $sized7g = '\(about |\d (MB|GB)\b'
    $said7gA = & $refusal7g $log7gA
    Assert-That ($c7gA -ne 0 -and $log7gA -notmatch '=+ Ollama =+' -and $said7gA.Contains("is not the folder Ollama keeps its models in now: they are in $plannedModels. Going on would download every model again") -and $said7gA -notmatch $sized7g -and $log7gA -match 'Nothing was changed') "another -ModelDir while the folder in use holds models: refused in Preflight, naming that folder, which was looked at, and no size (exit ${c7gA}: $said7gA)"
    Assert-That ($log7gA -match 'run the installer again without -ModelDir' -and $log7gA.Contains("move everything in $plannedModels into $otherModels") -and $log7gA -notmatch 'remove the OLLAMA_MODELS variable') 'and both ways on: keep the folder (no -ModelDir), or quit Ollama, move the models and run again (no variable is in the way, and none is named)'
    Assert-That ((Test-LaiSamePath ([string]$flags7gA['modelDir']) $plannedModels) -and -not $flags7gA.ContainsKey('ollamaModelsEnv') -and -not (Test-Path -LiteralPath $otherModels) -and -not $global:MockUserEnv.ContainsKey('OLLAMA_MODELS')) "nothing changed: the state still plans the folder in use, the new folder was not created, no variable was set (state: $($flags7gA['modelDir']))"
    # The same refusal with apostrophes in both names, and with a folder in use that is not the plan
    # either (the Ollama app's own Model location names it, as in 7b): keeping it takes -ModelDir
    # with that folder. Both commands the message gives must be typed as it writes them.
    # That folder is named by Ollama's log and by nothing the installer chose itself: not its
    # state, not a value it wrote into OLLAMA_MODELS, and it is not Ollama's default. Any program
    # of this user can write that log, and the installer, which has administrator rights, opened
    # the folder it named, listed it, and put its size into the refusal. It is not looked at any
    # more: the running Ollama's own list says that there are models, and the refusal says who
    # names the folder and that it was not looked at, with no size.
    $notLooked7g = { param([string]$Folder) "and $Folder, the folder they should be in, was not looked at (Ollama's start-up log names it, and the installer did not choose it itself). Going on would download every model again" }
    $listed7g = { param([string]$Refusal) [regex]::Match($Refusal, 'the running Ollama lists ([1-9]\d*) model\(s\), ').Groups[1].Value }
    & $moveModels7g $plannedModels $aposModels
    Set-Content -LiteralPath $serverLog -Value $srvApos7g
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $aposTarget
    $c7gA2 = $LASTEXITCODE
    $log7gA2 = Get-NewestLog
    & $moveModels7g $aposModels $plannedModels
    Remove-Item -LiteralPath $aposModels -Recurse -Force
    Set-Content -LiteralPath $serverLog -Value $srv7g
    $said7gA2 = & $refusal7g $log7gA2
    Assert-That ($c7gA2 -ne 0 -and $log7gA2 -notmatch '=+ Ollama =+' -and (& $listed7g $said7gA2) -and $said7gA2.Contains((& $notLooked7g $aposModels)) -and -not (Test-Path -LiteralPath $aposTarget)) "the folder in use named by the Ollama app's own setting, with an apostrophe in its name: refused all the same, on the running Ollama's own list of models, and the message says that the folder Ollama's log names was not looked at (exit ${c7gA2}: $said7gA2)"
    $notSeen7g = 'now: they are in |the models stay in |' + $sized7g
    Assert-That ($said7gA2 -and $said7gA2 -notmatch $notSeen7g) "and that refusal carries no size, and says neither that the models are in that folder nor that they stay there: nobody has looked ($said7gA2)"
    # Both ways on, each with its folder as PowerShell reads one folder. The way that keeps the
    # models is given on a condition and says where to check it: the folder is named by the log
    # alone, and a run that planned it would create it with administrator rights and keep it as
    # the installer's own. After a move Ollama is started again: the next run asks its list too.
    Assert-That ($said7gA2.Contains("If your models are in $aposModels (the Ollama app shows the folder it uses under Settings > Model location), run the installer again with -ModelDir $(& $asTyped7g $aposModels) to keep them there. To move them instead: quit Ollama from its tray icon, move everything in $aposModels into $aposTarget, start Ollama again, and run the installer again with -ModelDir $(& $asTyped7g $aposTarget).")) "and both commands write their folder as PowerShell reads one folder, the apostrophe doubled; keeping the folder is given on the condition that the models are in it, and the move ends with Ollama started again (to keep: -ModelDir $(& $asTyped7g $aposModels); after the move: -ModelDir $(& $asTyped7g $aposTarget))"
    # What is in such a folder plays no part, because it is never opened: here the log names a
    # folder that is there and empty. Looked at, it read 'holds no models' and the run went on into
    # the download this check is there for. It is refused as above, with the same count of models
    # and no size.
    $emptyNamed = Join-Path $Work 'Log Named Empty'
    New-Item -ItemType Directory -Force -Path $emptyNamed | Out-Null
    Set-Content -LiteralPath $serverLog -Value ($srv7g -replace 'OLLAMA_MODELS:[^ \]]*', ('OLLAMA_MODELS:' + $emptyNamed.Replace('\', '\\')))
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $aposTarget
    $c7gA3 = $LASTEXITCODE
    $log7gA3 = Get-NewestLog
    Set-Content -LiteralPath $serverLog -Value $srv7g
    $said7gA3 = & $refusal7g $log7gA3
    $notRead7g = $notSeen7g + '|holds no models|a folder that is not there|cannot be looked at'
    Assert-That ($c7gA3 -ne 0 -and $log7gA3 -notmatch '=+ Ollama =+' -and $said7gA3.Contains((& $notLooked7g $emptyNamed)) -and (& $listed7g $said7gA3) -and (& $listed7g $said7gA3) -eq (& $listed7g $said7gA2) -and $said7gA3 -notmatch $notRead7g -and
        @(Get-ChildItem -LiteralPath $emptyNamed -Force).Count -eq 0 -and -not (Test-Path -LiteralPath $aposTarget)) "a folder that only Ollama's log names and that is empty: still refused in Preflight while the running Ollama lists models, with the same count and no size (exit ${c7gA3}: $said7gA3)"
    Remove-Item -LiteralPath $emptyNamed -Recurse -Force
    # And the other way round: the log names a folder that does hold the models, and the running
    # Ollama lists none (this phase gives the answer, see $patches). Only that list is asked, so
    # Preflight has nothing to refuse and says what it went by: had the folder been opened, the
    # manifest in it would have refused the run with 'they are in'. Then the same with an Ollama
    # that does not answer: the installer cannot tell, says so with the reason, and what it gives
    # to do is to start Ollama and run the same command again, not to pass a folder nobody has
    # looked at as -ModelDir (that run would create it and keep it as the installer's own). Both
    # runs pass Preflight and stop at the next stage; the state is put back after each.
    $fullNamed = Join-Path $Work 'Log Named Full'
    $stateAside7gA = Join-Path $Work 'install-state-before-7g-list.json'
    Copy-Item -LiteralPath $statePath -Destination $stateAside7gA -Force
    & $moveModels7g $plannedModels $fullNamed
    Set-Content -LiteralPath $serverLog -Value ($srv7g -replace 'OLLAMA_MODELS:[^ \]]*', ('OLLAMA_MODELS:' + $fullNamed.Replace('\', '\\')))
    $log7gA4 = ''; $log7gA5 = ''
    try {
        $global:MockOllamaListed = @{ Content = 'empty'; Listed = 0 }
        & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $aposTarget
        $log7gA4 = Get-NewestLog
        Copy-Item -LiteralPath $stateAside7gA -Destination $statePath -Force
        $global:MockOllamaListed = @{ Content = 'unknown'; Listed = -1 }
        & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $aposTarget
        $log7gA5 = Get-NewestLog
    } finally {
        $global:MockOllamaListed = $null
        Copy-Item -LiteralPath $stateAside7gA -Destination $statePath -Force
        Set-Content -LiteralPath $serverLog -Value $srv7g
    }
    $manifestStill7g = Test-Path -LiteralPath (Get-LaiModelManifestPath -ModelDir $fullNamed -Name $modelName7g)
    & $moveModels7g $fullNamed $plannedModels
    Remove-Item -LiteralPath $fullNamed -Recurse -Force
    if (Test-Path -LiteralPath $aposTarget) { Remove-Item -LiteralPath $aposTarget -Recurse -Force }
    $wasRead7g = 'now: they are in |which holds no models|a folder that is not there|cannot be looked at|could not be looked at'
    $info7gA4 = @($log7gA4 -split "`n" | Where-Object { $_ -match 'is not the folder Ollama uses now' }) -join ' '
    Assert-That ($manifestStill7g -and $log7gA4 -match 'Test hook: stage Ollama failed' -and -not (& $refusal7g $log7gA4) -and $info7gA4.Contains("($fullNamed, which was not looked at; the running Ollama lists no models)") -and $log7gA4 -notmatch $wasRead7g) "a folder that only Ollama's log names and that holds a manifest, while the running Ollama lists no models: the folder is not opened, Preflight goes by the list and says so ($info7gA4)"
    $warn7gA5 = @($log7gA5 -split "`n" | Where-Object { $_ -match 'The folder Ollama uses now, ' }) -join ' '
    Assert-That ($log7gA5 -match 'Test hook: stage Ollama failed' -and -not (& $refusal7g $log7gA5) -and $warn7gA5.Contains("The folder Ollama uses now, $fullNamed, was not looked at (Ollama's start-up log names it, and the installer did not choose it itself), and Ollama, whose list of models would tell, did not answer, so the installer cannot tell whether models are in it.") -and
        $log7gA5.Contains("($fullNamed, which was not looked at, and Ollama did not answer)") -and $log7gA5 -notmatch $wasRead7g) "the same folder with an Ollama that does not answer: the run warns that it cannot tell, with the reason, and nowhere says that the folder cannot be read or holds nothing ($warn7gA5)"
    Assert-That ($warn7gA5.Contains('Not wanted? Close this window now, start Ollama, and run the installer again in the same way: it then goes by the models Ollama lists. Continuing in 20 seconds.') -and -not $warn7gA5.Contains('-ModelDir ' + (& $asTyped7g $fullNamed)) -and $warn7gA5 -notmatch 'connect the drive') 'and what that warning gives to do is to start Ollama and run the same command again: it does not tell the owner to pass the folder nobody looked at as -ModelDir, or to connect a drive'
    # The two judges that refusal rests on, from the installer's own text. A folder is the
    # installer's own when it is one of those it chose (spelling apart), and no other; and for a
    # folder that is not, the running Ollama's list is all that is asked.
    $ownFn7g = [regex]::Match($text, '(?s)function Test-OwnModelFolder \{.*?\r?\n\}').Value
    $listFn7g = [regex]::Match($text, '(?s)function Get-OllamaListedContent \{.*?\r?\n\}').Value
    $judges7g = @{ Own = @(); Models = @{}; None = @{}; Down = @{} }
    if ($ownFn7g -and $listFn7g) {
        $judges7g = & {
            . ([scriptblock]::Create($ownFn7g)); . ([scriptblock]::Create($listFn7g))
            $answer7g = 'models'
            function Get-LaiOllamaModelNames { param($BaseUrl) $null = $BaseUrl; if ($answer7g -eq 'down') { throw 'no answer' }; if ($answer7g -eq 'none') { return @() }; return @('one:latest', 'two:latest') }
            $r7g = @{ Own = @((Test-OwnModelFolder -Path 'D:\Models' -Own @('C:\Users\testuser\.ollama\models', '', 'd:/models/')), (Test-OwnModelFolder -Path 'E:\Other' -Own @('C:\Users\testuser\.ollama\models', 'D:\Models', '')), (Test-OwnModelFolder -Path 'E:\Other' -Own @('', '')), (Test-OwnModelFolder -Path 'E:\Other')) }
            $r7g['Models'] = Get-OllamaListedContent -OllamaUrl 'http://stand-in'
            $answer7g = 'none'; $r7g['None'] = Get-OllamaListedContent -OllamaUrl 'http://stand-in'
            $answer7g = 'down'; $r7g['Down'] = Get-OllamaListedContent -OllamaUrl 'http://stand-in'
            $r7g
        }
    }
    Assert-That ($judges7g['Own'].Count -eq 4 -and $judges7g['Own'][0] -eq $true -and $judges7g['Own'][1] -eq $false -and $judges7g['Own'][2] -eq $false -and $judges7g['Own'][3] -eq $false) "a folder is the installer's own when it is one of the folders it chose (letter case, slashes and a closing separator apart), and not when it is another folder or when nothing was chosen ($($judges7g['Own'] -join ', '))"
    Assert-That ([string]$judges7g['Models']['Content'] -eq 'models' -and [int]$judges7g['Models']['Listed'] -eq 2 -and [string]$judges7g['None']['Content'] -eq 'empty' -and [int]$judges7g['None']['Listed'] -eq 0 -and [string]$judges7g['Down']['Content'] -eq 'unknown' -and [int]$judges7g['Down']['Listed'] -eq -1) "for a folder that is not its own the installer goes by the running Ollama's list: models when it lists some, empty when it lists none, unknown when it does not answer ($($judges7g['Models']['Content']) / $($judges7g['None']['Content']) / $($judges7g['Down']['Content']))"
    # And where the installer does look: the one listing of the folder in use is behind 'the
    # installer chose this folder itself', a look that met a link counts as no look, and no size
    # is taken from any folder (the function that added one up is gone).
    $looks7g = [regex]::Matches($text, 'Get-ModelFolderContent -Path \$inUse').Count
    Assert-That ($looks7g -eq 1 -and $text -match '(?s)if \(\$otherModelDir -and \$inUseOwn\) \{\s+\$inUseContent = Get-ModelFolderContent -Path \$inUse\s+\$lookedAt = \(\$inUseContent -ne ''link''\)' -and $text -notmatch 'Get-FolderSizeText|\(about \{' -and
        $text.Contains('$inUseOwn = Test-OwnModelFolder -Path $inUse -Own @($defaultModels, [string]$State.flags[''modelDir''], $ownModelsVar)')) "the installer lists the folder in use in one place, only when that folder is Ollama's default, the folder of its last plan or the value it wrote into OLLAMA_MODELS, takes a look that met a link for no look, and takes no size from any folder ($looks7g listing(s))"
    # A link in the folder the installer chose itself. Ollama's default folder lies in the user's
    # profile, where any program of the user's can put a link in place of a folder. Here manifests
    # is a symbolic link to a folder elsewhere that holds a manifest (it stands in for a folder
    # only administrators can read). The installer, which has administrator rights, listed
    # through the link, said 'they are in', and added up the size of what lay behind a linked
    # blobs. It follows no link now: with a link on the way the folder counts as not looked at and
    # the running Ollama's list decides, as for a folder the installer did not choose. First with
    # the sandbox's Ollama, which lists models (refused, with the reason), then with one that
    # lists none: the run goes on, which it could not if the manifest behind the link were read.
    $behindLink = Join-Path $Work 'Behind A Link'
    $link7g = (Join-Path $plannedModels 'manifests').Replace('\', '/')
    $stateAside7gL = Join-Path $Work 'install-state-before-7g-link.json'
    Copy-Item -LiteralPath $statePath -Destination $stateAside7gL -Force
    & $moveModels7g $plannedModels $behindLink
    $c7gL = -1; $log7gL = ''; $log7gL2 = ''; $linkMade7g = $false
    try {
        New-Item -ItemType SymbolicLink -Path $link7g -Target (Join-Path $behindLink 'manifests') | Out-Null
        $linkMade7g = [bool]((Get-Item -LiteralPath $link7g -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -and (Test-Path -LiteralPath (Get-LaiModelManifestPath -ModelDir $plannedModels -Name $modelName7g))
        & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $otherModels
        $c7gL = $LASTEXITCODE
        $log7gL = Get-NewestLog
        Copy-Item -LiteralPath $stateAside7gL -Destination $statePath -Force
        $global:MockOllamaListed = @{ Content = 'empty'; Listed = 0 }
        & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $otherModels
        $log7gL2 = Get-NewestLog
    } finally {
        $global:MockOllamaListed = $null
        Copy-Item -LiteralPath $stateAside7gL -Destination $statePath -Force
        # The link itself, not what it points at (unlink; the folder behind it is moved back below).
        if ($linkMade7g) { try { [System.IO.File]::Delete($link7g) } catch { & /bin/rm -f $link7g } }
    }
    $linkGone7g = -not (Test-Path -LiteralPath $link7g)
    if ($linkGone7g) { & $moveModels7g $behindLink $plannedModels; Remove-Item -LiteralPath $behindLink -Recurse -Force }
    if (Test-Path -LiteralPath $otherModels) { Remove-Item -LiteralPath $otherModels -Recurse -Force }
    $said7gL = & $refusal7g $log7gL
    $byLink7g = 'it is, or lies behind, a junction or symbolic link, which the installer does not follow with administrator rights'
    Assert-That ($linkMade7g -and $linkGone7g -and (Test-Path -LiteralPath $manifest7g)) "setup: manifests in the folder the installer chose was a symbolic link to a folder that holds a manifest, and is the folder itself again afterwards (made: $linkMade7g, taken away: $linkGone7g)"
    Assert-That ($c7gL -ne 0 -and $log7gL -notmatch '=+ Ollama =+' -and (& $listed7g $said7gL) -and $said7gL.Contains("and $plannedModels, the folder they should be in, was not looked at ($byLink7g). Going on would download every model again") -and $said7gL -notmatch $notSeen7g) "the installer's own folder with a link in place of manifests: refused on the running Ollama's list, and the message says that the folder was not looked at because of the link, with no size and no 'they are in' (exit ${c7gL}: $said7gL)"
    Assert-That ($said7gL.Contains("If your models are in $plannedModels (the Ollama app shows the folder it uses under Settings > Model location), run the installer again without -ModelDir to keep them there. To move them instead: quit Ollama from its tray icon, move everything in $plannedModels into $otherModels, start Ollama again, and run the installer again with -ModelDir $(& $asTyped7g $otherModels).")) 'and its two ways on are those for a folder nobody looked at: keeping it on the condition that the models are in it, and a move that ends with Ollama started again'
    $info7gL2 = @($log7gL2 -split "`n" | Where-Object { $_ -match 'is not the folder Ollama uses now' }) -join ' '
    Assert-That ($log7gL2 -match 'Test hook: stage Ollama failed' -and -not (& $refusal7g $log7gL2) -and $info7gL2.Contains("($plannedModels, which was not looked at; the running Ollama lists no models)") -and $log7gL2 -notmatch $wasRead7g) "with an Ollama that lists no models the same run goes on: the manifest behind the link was not read (read, it refuses the run with 'they are in'), and the log says what the installer went by ($info7gL2)"

    # B: the models moved by hand, as the message says. The folder in use is empty now, so the run
    # goes on, and it reads what is installed from the new folder's manifests (the running Ollama
    # still lists the old one). Each start of Ollama logs the folder its variable names.
    & $moveModels7g $plannedModels $otherModels
    $env:LOCALAI_TEST_FAIL_STAGE = 'Models'
    $global:MockOllamaLog = @{ User = $srvOther7g; Session = $srvOther7g }
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $otherModels
    $log7gB = Get-NewestLog
    $flags7gB = (Read-LaiState -Path $statePath)['flags']
    Assert-That ($log7gB -match 'Test hook: stage Models failed' -and $log7gB.Contains("what is installed is read from $(Join-Path $otherModels 'manifests'): $modelName7g")) 'after the move the same -ModelDir passes Preflight and the Ollama stage, and the log names the manifests the installed models were read from, and the model found there'
    Assert-That ($log7gB.Contains("($plannedModels, which holds no models)") -and $log7gB -notmatch 'cannot be looked at') 'the folder in use was read and found empty: the log says that it holds no models, and warns of nothing'
    Assert-That ((Test-LaiSamePath ([string]$global:MockUserEnv['OLLAMA_MODELS']) $otherModels) -and $log7gB.Contains("set OLLAMA_MODELS=$otherModels") -and (Test-LaiSamePath ([string]$flags7gB['modelDir']) $otherModels) -and (Test-LaiSamePath ([string]$flags7gB['ollamaModelsEnv']) $otherModels)) "OLLAMA_MODELS is set to the new folder, and the state keeps that value as the installer's own (variable: $($global:MockUserEnv['OLLAMA_MODELS']))"

    # C: back. The models moved back, folder and all (the other folder is gone), -ModelDir with the
    # default folder: the variable, which is the installer's own, has to go, or Ollama would stay
    # with the other folder. A folder that is not there on a drive that is holds no models: named as
    # that, without the warning for a folder that cannot be looked at (and without its wait).
    & $moveModels7g $otherModels $plannedModels
    Remove-Item -LiteralPath $otherModels -Recurse -Force
    $global:MockOllamaLog = @{ User = $srv7g; Session = $srv7g }
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $plannedModels
    $log7gC = Get-NewestLog
    $flags7gC = (Read-LaiState -Path $statePath)['flags']
    Assert-That ($log7gC -match 'Test hook: stage Models failed' -and -not $global:MockUserEnv.ContainsKey('OLLAMA_MODELS') -and -not $env:OLLAMA_MODELS -and $log7gC.Contains("removed OLLAMA_MODELS (the installer had set it to $otherModels)")) 'back to the default folder: the OLLAMA_MODELS the installer had set is removed (from the user''s variables and from this process), and the log says so'
    Assert-That ((Test-LaiSamePath ([string]$flags7gC['modelDir']) $plannedModels) -and -not $flags7gC.ContainsKey('ollamaModelsEnv') -and $log7gC.Contains("what is installed is read from $(Join-Path $plannedModels 'manifests'): $modelName7g") -and $log7gC -match 'Restarting Ollama so it picks up the settings') "the state plans the default folder again and keeps no value of its own; Ollama is restarted to drop the variable (state: $($flags7gC['modelDir']))"
    Assert-That ($log7gC.Contains("($otherModels, a folder that is not there)") -and $log7gC -notmatch 'cannot be looked at' -and $log7gC.Contains("Ollama's own default folder is used again")) 'the folder Ollama used, moved away whole, is named as a folder that is not there (its drive is, so nothing can be in it), with no warning; with no other OLLAMA_MODELS left the log says that the default folder is used again'

    # D: OLLAMA_MODELS is the owner's own, set before the first install, which took that folder for
    # its plan: the state's plan, the value the installer wrote and the record Uninstall puts back
    # all name it, Ollama's log names it, and the models are in it. Back to the default folder is
    # refused as in A, but here the move alone leads nowhere: that variable is not the installer's
    # to remove, Ollama would stay with the folder it names, and every model moved out of it would
    # count as missing. So the message puts removing the variable first.
    & $moveModels7g $plannedModels $otherModels
    & $setState7g @{ modelDir = $otherModels; ollamaModelsEnv = $otherModels } $otherModels
    $global:MockUserEnv['OLLAMA_MODELS'] = $otherModels
    Set-Content -LiteralPath $serverLog -Value $srvOther7g
    $global:MockOllamaLog = @{ User = $srvOther7g; Session = $srvOther7g }
    $env:LOCALAI_TEST_FAIL_STAGE = 'Ollama'
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $plannedModels
    $c7gD = $LASTEXITCODE
    $log7gD = Get-NewestLog
    $removeAt7gD = $log7gD.IndexOf("first remove the OLLAMA_MODELS variable from your user variables (Start menu > 'Edit environment variables for your account'): it names $otherModels and is not the installer's own setting")
    $moveAt7gD = $log7gD.IndexOf("move everything in $otherModels into $plannedModels")
    $said7gD = & $refusal7g $log7gD
    Assert-That ($c7gD -ne 0 -and $log7gD -notmatch '=+ Ollama =+' -and $said7gD.Contains("is not the folder Ollama keeps its models in now: they are in $otherModels. Going on would download every model again") -and $said7gD -notmatch $sized7g -and $log7gD -match 'run the installer again without -ModelDir') "back to the default folder while the owner's own OLLAMA_MODELS names the folder in use, which holds the models: refused in Preflight, naming that folder and no size (exit ${c7gD}: $said7gD)"
    Assert-That ($removeAt7gD -ge 0 -and $moveAt7gD -gt $removeAt7gD) "and the way to the default folder starts with removing that variable, named with where Windows shows it, before the move (removal at $removeAt7gD, move at $moveAt7gD)"
    Assert-That ((Test-LaiSamePath ([string]$global:MockUserEnv['OLLAMA_MODELS']) $otherModels) -and (Test-LaiSamePath ([string](Read-LaiState -Path $statePath)['flags']['modelDir']) $otherModels)) "nothing changed: the variable is there, the state still plans the folder in use (variable: $($global:MockUserEnv['OLLAMA_MODELS']))"
    # The owner moves the models all the same. Preflight has nothing to refuse (the folder in use
    # is empty), the Ollama stage leaves the variable, and Ollama stays with the folder it names:
    # a model still to download would go there. The run stops before the download and names the
    # variable as the cause, not the Ollama app's own Model location setting.
    & $moveModels7g $otherModels $plannedModels
    $env:LOCALAI_TEST_FAIL_STAGE = 'Models'
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels trial-missing -ModelDir $plannedModels
    $c7gD2 = $LASTEXITCODE
    $log7gD2 = Get-NewestLog
    Assert-That ((Test-LaiSamePath ([string]$global:MockUserEnv['OLLAMA_MODELS']) $otherModels) -and $log7gD2 -notmatch 'removed OLLAMA_MODELS' -and $log7gD2.Contains("OLLAMA_MODELS=$otherModels is not the installer's own setting and is left as it is")) "a value the owner had before the first install is left alone, and the log says why (variable: $($global:MockUserEnv['OLLAMA_MODELS']))"
    Assert-That ($c7gD2 -ne 0 -and $log7gD2 -notmatch '=+ Models =+' -and $log7gD2 -match 'Nothing was downloaded' -and $log7gD2.Contains("Ollama keeps its models in $otherModels, not in ${plannedModels}: the OLLAMA_MODELS variable in your user variables names that folder") -and $log7gD2.Contains("Remove that variable with 'Edit environment variables for your account' from the Start menu") -and $log7gD2 -notmatch 'Settings > Model location') "with a model still to download the run stops in the Ollama stage and names that variable as the cause, and its removal as the cure, not the Ollama app's Model location (exit $c7gD2)"

    # E: an install from before the installer kept which value it had written. The state plans the
    # other folder and OLLAMA_MODELS names it, but nothing says whose the variable is, and nothing
    # was there before the first install. Preflight takes the plan for the installer's own value,
    # so going back to the default folder removes the variable. Here a system-wide OLLAMA_MODELS
    # names that folder too ($global:MockMachineModels): the installer never writes one, Ollama
    # reads it once the user's is gone, and the run names it as what keeps Ollama there.
    & $setState7g @{ modelDir = $otherModels; ollamaModelsEnv = $null } ''
    $global:MockUserEnv['OLLAMA_MODELS'] = $otherModels
    $global:MockMachineModels = $otherModels
    Set-Content -LiteralPath $serverLog -Value $srvOther7g
    $global:MockOllamaLog = @{ User = $srvOther7g; Session = $srvOther7g }
    try { & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $plannedModels } finally { $global:MockMachineModels = $null }
    $log7gE = Get-NewestLog
    $flags7gE = (Read-LaiState -Path $statePath)['flags']
    Assert-That ($log7gE -match 'Test hook: stage Models failed' -and -not $global:MockUserEnv.ContainsKey('OLLAMA_MODELS') -and $log7gE.Contains("removed OLLAMA_MODELS (the installer had set it to $otherModels)") -and -not $flags7gE.ContainsKey('ollamaModelsEnv') -and (Test-LaiSamePath ([string]$flags7gE['modelDir']) $plannedModels)) "an install from before that value was kept: the planned folder counts as the installer's own value, and going back to the default folder removes the variable (still there: $($global:MockUserEnv['OLLAMA_MODELS']))"
    Assert-That ($log7gE.Contains("the OLLAMA_MODELS in the system variables is what Ollama reads now, $otherModels") -and $log7gE.Contains("Ollama keeps its models in $otherModels, not in ${plannedModels}: the OLLAMA_MODELS variable in the system variables names that folder") -and $log7gE.Contains("Remove that variable with 'Edit the system environment variables' from the Start menu") -and $log7gE -notmatch 'Settings > Model location') 'a system-wide OLLAMA_MODELS stays: the run says that Ollama reads it now, and that it, not the Ollama app''s setting, keeps Ollama on that folder'

    # F: the owner changed OLLAMA_MODELS by hand after the install, to a folder on a disk that is
    # not plugged in now. It no longer holds the value the installer wrote, so it is not the
    # installer's to remove, and the state forgets that value. And the folder Ollama uses cannot be
    # looked at: said in a warning before anything is planned (with the folder as it has to be
    # typed), not passed off as a folder that holds no models. The state is written by hand here to
    # plan that folder: only that makes it a folder the installer chose and may look at (no run of
    # the installer leaves this state: with a plan recorded, a run without -ModelDir keeps the plan
    # and does not take the variable). Named by the log and the variable alone it is not looked
    # at, and the running Ollama's list decides: that is F2, below.
    & $setState7g @{ modelDir = $goneModels; ollamaModelsEnv = $otherModels } ''
    $global:MockUserEnv['OLLAMA_MODELS'] = $goneModels
    Set-Content -LiteralPath $serverLog -Value $srvGone7g
    $global:MockOllamaLog = @{ User = $srvGone7g; Session = $srvGone7g }
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $plannedModels
    $log7gF = Get-NewestLog
    $flags7gF = (Read-LaiState -Path $statePath)['flags']
    $goneTyped7g = & $asTyped7g $goneModels
    Assert-That ($log7gF -match 'Test hook: stage Models failed' -and [string]$global:MockUserEnv['OLLAMA_MODELS'] -ceq $goneModels -and $log7gF -notmatch 'removed OLLAMA_MODELS' -and $log7gF.Contains("OLLAMA_MODELS=$goneModels is not the installer's own setting and is left as it is") -and -not $flags7gF.ContainsKey('ollamaModelsEnv')) "a value the owner set by hand after the install (not the one the installer wrote) is left alone, and the state no longer keeps a value as the installer's own (variable: $($global:MockUserEnv['OLLAMA_MODELS']))"
    Assert-That ($log7gF.Contains("The folder Ollama uses now, $goneModels, cannot be looked at") -and $log7gF.Contains("run the installer again with -ModelDir $goneTyped7g. Continuing in 20 seconds") -and $log7gF.Contains("($goneModels, which could not be looked at)") -and $log7gF -notmatch 'which holds no models') 'a folder in use on a drive that is not there: the run warns that it cannot tell whether models are in it and what follows, and nowhere says that it holds none'
    Assert-That ($log7gF.Contains('the OLLAMA_MODELS variable in your user variables names that folder') -and $log7gF.Contains("(or re-run the installer with -ModelDir $goneTyped7g)") -and $log7gF -notmatch 'Settings > Model location') "with every model there the Ollama stage only warns: it names the variable as the cause, and writes the folder to pass as PowerShell reads one folder (-ModelDir $goneTyped7g)"

    # F2: the state an install does leave when the owner changes OLLAMA_MODELS by hand afterwards.
    # The plan and the value the installer wrote name the other folder; the variable and Ollama's
    # log name the folder on the drive that is not there. That folder is nothing the installer
    # chose, so it is not looked at (not even to find its drive missing), and the running Ollama,
    # which lists models, decides: refused in Preflight, with the count, who names the folder and
    # no size. The variable is not the installer's to remove, so the way to the default folder
    # starts with removing it, and it ends with Ollama started again.
    & $setState7g @{ modelDir = $otherModels; ollamaModelsEnv = $otherModels } ''
    $global:MockUserEnv['OLLAMA_MODELS'] = $goneModels
    Set-Content -LiteralPath $serverLog -Value $srvGone7g
    $global:MockOllamaLog = @{ User = $srvGone7g; Session = $srvGone7g }
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none -ModelDir $plannedModels
    $c7gF2 = $LASTEXITCODE
    $log7gF2 = Get-NewestLog
    $flags7gF2 = (Read-LaiState -Path $statePath)['flags']
    $said7gF2 = & $refusal7g $log7gF2
    Assert-That ($c7gF2 -ne 0 -and $log7gF2 -notmatch '=+ Ollama =+' -and (& $listed7g $said7gF2) -and $said7gF2.Contains((& $notLooked7g $goneModels)) -and $said7gF2 -notmatch $notRead7g -and $log7gF2 -notmatch 'The folder Ollama uses now, ') "a folder on a drive that is not there, named by the variable and Ollama's log alone: not looked at, and refused in Preflight on the running Ollama's list of models, with no warning about a drive (exit ${c7gF2}: $said7gF2)"
    Assert-That ($said7gF2.Contains("If your models are in $goneModels (the Ollama app shows the folder it uses under Settings > Model location), run the installer again with -ModelDir $goneTyped7g to keep them there. To move them instead: first remove the OLLAMA_MODELS variable from your user variables (Start menu > 'Edit environment variables for your account'): it names $goneModels and is not the installer's own setting") -and
        $said7gF2.Contains("Then quit Ollama from its tray icon, move everything in $goneModels into $plannedModels, start Ollama again, and run the installer again with -ModelDir $(& $asTyped7g $plannedModels).")) 'and its two ways on: keeping that folder on the condition that the models are in it, or removing the variable first, moving the models and starting Ollama again'
    Assert-That ((Test-LaiSamePath ([string]$flags7gF2['modelDir']) $otherModels) -and (Test-LaiSamePath ([string]$flags7gF2['ollamaModelsEnv']) $otherModels) -and [string]$global:MockUserEnv['OLLAMA_MODELS'] -ceq $goneModels) "nothing changed: the state still plans the other folder and keeps the installer's own value, and the variable is as the owner set it (state: $($flags7gF2['modelDir']))"
} finally {
    $env:LOCALAI_TEST_FAIL_STAGE = ''
    $global:MockOllamaLog = $null
    $global:MockUserEnv = $null
    $global:MockMachineModels = $null
    $global:MockOllamaListed = $null
    Remove-Item -LiteralPath Env:OLLAMA_MODELS -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $serverLog -Value $srv7g
    Copy-Item -LiteralPath $stateAside7g -Destination $statePath -Force
    foreach ($made7g in @((Join-Path $plannedModels 'manifests'), (Join-Path $plannedModels 'blobs'), $otherModels, $aposModels, $aposTarget, (Join-Path $Work 'Log Named Empty'), (Join-Path $Work 'Log Named Full'), (Join-Path $Work 'Behind A Link'))) {
        if (Test-Path -LiteralPath $made7g) { Remove-Item -LiteralPath $made7g -Recurse -Force }
    }
}

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
    # Before the update changed anything, the chats were backed up, once per toolkit version and commit.
    # This copy has no COMMIT file (as a ZIP unpacked by hand), so the day stands in for the commit; no
    # fixed number of archives is asked for, because the phases before this one may have crossed midnight.
    $preFilter8 = 'open-webui-*-before-toolkit-*.tar.gz'
    $pre8 = @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter $preFilter8 -ErrorAction SilentlyContinue)
    $preFlag8 = [string](Read-LaiState -Path $statePath)['flags']['preUpdateBackup']
    Assert-That ($pre8.Count -ge 1 -and $preFlag8 -match '^before-toolkit-.+-\d{8}$' -and @($pre8 | Where-Object { $_.Name -like "*-$preFlag8.tar.gz" }).Count -ge 1) "an update of an existing install backs the chats up first; without a COMMIT file the backup is keyed on the version and the day ($preFlag8; $($pre8.Count) archive(s))"
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
    # The same VERSION at another commit than the one the last backup was taken for (Get-LocalAI.ps1
    # writes COMMIT next to the scripts): the next two runs must take one new backup, then none.
    $commitFile8 = Join-Path $aiRoot 'Scripts/COMMIT'
    Set-Content -LiteralPath $commitFile8 -Value ('a' * 40)
    $st8p = Read-LaiState -Path $statePath
    $st8p['flags']['preUpdateBackup'] = $preFlag8 -replace '-\d{8}$', '-bbbbbbb'
    Save-LaiState -State $st8p -Path $statePath
    # A re-run with the account in place signs in instead of making another one.
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
    $rc8b = Get-Content -Raw -Encoding UTF8 -LiteralPath $rcFile | ConvertFrom-Json
    Assert-That ($LASTEXITCODE -eq 0 -and $rc8b.password -eq $rc8.password -and @((Read-LaiState -Path (Join-Path $aiRoot 'install-state.json'))['flags']['configureWarnings']).Count -eq 0) 're-run without the switch keeps deep research on and reuses the account'
    $pre8b = @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter $preFilter8 -ErrorAction SilentlyContinue)
    $preFlag8b = [string](Read-LaiState -Path $statePath)['flags']['preUpdateBackup']
    Assert-That ($pre8b.Count -eq $pre8.Count + 1 -and $preFlag8b -match '^before-toolkit-.+-aaaaaaa$' -and @($pre8b | Where-Object { $_.Name -like "*-$preFlag8b.tar.gz" }).Count -ge 1) "the same VERSION at another commit: one new backup before the update, tagged with the version and the short commit ($preFlag8b; $($pre8.Count) archive(s) before, $($pre8b.Count) after)"
    & /usr/bin/docker volume create localai-deep-research 2>$null | Out-Null
    & (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -NoDeepResearch
    $pre8c = @(Get-ChildItem -LiteralPath (Join-Path $aiRoot 'Backups') -Filter $preFilter8 -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $commitFile8 -Force
    Assert-That ($pre8c.Count -eq $pre8b.Count -and [string](Read-LaiState -Path $statePath)['flags']['preUpdateBackup'] -eq $preFlag8b) "and the next run of that commit takes none ($($pre8c.Count) archive(s))"
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
    & /usr/bin/docker volume rm open-webui owui-old owui-6d 2>$null | Out-Null
    $global:MockCopyFail = $false; $global:MockBackupFail = ''; $global:MockUserEnv = $null; $global:MockMachineModels = $null
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
