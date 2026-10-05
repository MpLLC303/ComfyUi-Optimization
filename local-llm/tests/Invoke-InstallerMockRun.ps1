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

# ---- patched installer copy ----------------------------------------------------------------
$inst = Join-Path $copy 'Install-LocalAI.ps1'
$text = Get-Content -Raw $inst
$patches = @(
    @('$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())', '$p = $null'),
    @('return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)', 'return (-not $env:LOCALAI_MOCK_NOT_ADMIN)'),
    @('[Security.Principal.WindowsIdentity]::GetCurrent().Name', "'MOCKPC\testuser'"),
    @('[Security.Principal.WindowsIdentity]::GetCurrent().User.Value', "'S-1-5-21-1-2-3-1001'"),
    @('[Environment]::OSVersion.Version.Build', '22631'),
    @('$qualifier = Split-Path -Qualifier $Path', 'return [Math]::Round((Get-PSDrive -Name "/").Free / 1GB, 1)')
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
$global:WslInstalled = $false
function global:Record([string]$s) { [void]$global:Calls.Add($s) }
function global:nvidia-smi { $global:LASTEXITCODE = 0; 'NVIDIA GeForce RTX 3090, 566.36, 24576, 1200, 23376' }
function global:Get-CimInstance {
    param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    $free = (Get-PSDrive -Name '/').Free
    switch ($ClassName) {
        'Win32_LogicalDisk' { [pscustomobject]@{ DeviceID = 'C:'; FreeSpace = $free } }
        'Win32_ComputerSystem' { [pscustomobject]@{ TotalPhysicalMemory = 64GB; HypervisorPresent = $true; UserName = $global:ConsoleUser } }
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
function global:Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings, [switch]$Force) $global:Tasks[$TaskName] = $Action.Argument; $global:TaskPrincipals[$TaskName] = [string]$Principal.Args; Record "Register-ScheduledTask $TaskName" }
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
Assert-That ($state.flags.PSObject.Properties['configureWarnings'] -and @($state.flags.configureWarnings).Count -eq 0) "Configure read every setting back from the real Open WebUI: no warnings ($(@($state.flags.configureWarnings) -join ' | '))"
Assert-That (-not (Select-String -LiteralPath (Join-Path $aiRoot 'install-report.md') -Pattern 'need attention' -Quiet)) 'a clean install report has no attention section'
$sel = @($state.flags.selectedModels)
Assert-That ($sel -contains 'trial-ok') 'trial model that works was added (passed through the reboot/resume)'
Assert-That ($sel -notcontains 'trial-missing') 'trial model with a missing tag was skipped, not fatal'
Assert-That ((Get-Content -Raw (Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName) -match 'Trial Trial: missing tag .* skipped') 'the skip came from the failed pull (Models stage), not the disk planner'  # lai-ok: objects
Assert-That ($null -ne $state.tuning.'trial-ok') 'trial model was tuned like the others'
function Get-TestPreset([string]$Id) {
    $tok = (Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:3000/api/v1/auths/signin' -ContentType 'application/json' -Body (ConvertTo-Json @{ email = $Email; password = $Password })).token
    try { return Invoke-RestMethod -Uri "http://127.0.0.1:3000/api/v1/models/model?id=$Id" -Headers @{ Authorization = "Bearer $tok" } } catch { return $null }
}
$tp = Get-TestPreset 'trial-standin'
Assert-That ($tp -and -not $tp.meta.hidden) 'trial preset created in Open WebUI and visible'
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
Assert-That ([string]$global:TaskPrincipals['LocalAI-Backup-OpenWebUI'] -match 'Limited' -and [string]$global:TaskPrincipals['LocalAI-Backup-OpenWebUI'] -notmatch 'Highest') 'nightly backup task runs non-elevated'
Assert-That (@($global:Calls | Where-Object { $_ -like 'docker compose*pull*' }).Count -ge 1 -and @($global:Calls | Where-Object { $_ -like 'docker compose*pull*' -and $_ -notlike '*--policy missing*' }).Count -eq 0) 'image pulls reuse local images (--policy missing)'
Assert-That (Test-Path (Join-Path $env:USERPROFILE '.wslconfig')) '.wslconfig created'
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
$stG | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $aiRoot 'install-state.json')
$sw = [Diagnostics.Stopwatch]::StartNew()
# One optional step fails (a rejected knowledge collection): a warning in the report, not a failed install.
$env:LOCALAI_TEST_KNOWLEDGE_FAIL = 'PC & Electronics'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
$code3 = $LASTEXITCODE
$env:LOCALAI_TEST_KNOWLEDGE_FAIL = ''
$st3 = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$rep3 = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-report.md')
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

# ---- phase 4: drop the trial again ---------------------------------------------------------------
Write-Host "`n=== PHASE 4: re-run with -TrialModels none ===" -ForegroundColor Cyan
# Pretend this install predates remembered settings: the skips must be inferred from what is installed.
$st = Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$st.flags.PSObject.Properties.Remove('params')
$st | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $aiRoot 'install-state.json')
# This run: a standard account signed in, an administrator's password typed at the UAC prompt.
$global:ConsoleUser = 'MOCKPC\kid'
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
Assert-That ($LASTEXITCODE -eq 0) "phase 4 completes (exit $LASTEXITCODE)"
$global:ConsoleUser = 'MOCKPC\testuser'
$lastLog = Get-ChildItem (Join-Path $aiRoot 'Logs') -Filter 'install-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1  # lai-ok: objects
Assert-That ($lastLog -and (Get-Content -Raw $lastLog.FullName) -match 'signed in as MOCKPC\\kid, but the installer runs as MOCKPC\\testuser') 'warns when UAC was approved with another account'
Assert-That ((& $restartCalls) -eq 1) 'unchanged render_guard.py: no restart'
Assert-That (@((Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.selectedModels) -notcontains 'trial-ok') '-TrialModels none deselects the trial'
$tp = Get-TestPreset 'trial-standin'
Assert-That ($tp -and $tp.meta.hidden -eq $true) 'deselected trial preset is hidden (kept for old chats)'
$p4 = (Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.params
Assert-That ($p4.SkipVision -eq $true -and $p4.SkipCoder -eq $true) 'older install: skips inferred from the installed models (no surprise 20 GB downloads)'
Assert-That (@((Get-Content -Encoding UTF8 -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.configureWarnings).Count -eq 0 -and -not (Select-String -LiteralPath (Join-Path $aiRoot 'install-report.md') -Pattern 'need attention' -Quiet)) "the next clean run clears phase 3's warning (no stale attention section)"

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

} finally {
    $env:LOCALAI_TEST_FAIL_STAGE = ''
    & /usr/bin/docker rm -f open-webui lai-test-elsewhere 2>$null | Out-Null
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
}
if ($failures -eq 0) { Write-Host "`nMOCK RUN PASSED" -ForegroundColor Green } else { Write-Host "`nMOCK RUN FAILED ($failures)" -ForegroundColor Red }
exit $failures
