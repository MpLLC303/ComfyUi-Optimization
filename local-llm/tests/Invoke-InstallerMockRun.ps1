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
try { Invoke-RestMethod $guardStatus -TimeoutSec 2 | Out-Null } catch {
    & /bin/sh -c "UPSTREAM=http://127.0.0.1:11434 COMFYUI_URLS=http://127.0.0.1:18188 LISTEN_PORT=11435 setsid nohup python3 '$src/stack/render-guard/render_guard.py' > /tmp/render-guard-mock.log 2>&1 &"
    Start-Sleep -Seconds 2
}
$guardBefore = [int](Invoke-RestMethod $guardStatus -TimeoutSec 5).stats.requests

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
& /usr/bin/docker run -d --restart always --name open-webui -v owui-old:/app/backend/data alpine:3.20 sleep 3600 | Out-Null

# ---- patched installer copy ----------------------------------------------------------------
$inst = Join-Path $copy 'Install-LocalAI.ps1'
$text = Get-Content -Raw $inst
$patches = @(
    @('$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())', '$p = $null'),
    @('return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)', 'return $true'),
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
$global:WslInstalled = $false
function global:Record([string]$s) { [void]$global:Calls.Add($s) }
function global:nvidia-smi { $global:LASTEXITCODE = 0; 'NVIDIA GeForce RTX 3090, 566.36, 24576, 1200, 23376' }
function global:Get-CimInstance {
    param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    $free = (Get-PSDrive -Name '/').Free
    switch ($ClassName) {
        'Win32_LogicalDisk' { [pscustomobject]@{ DeviceID = 'C:'; FreeSpace = $free } }
        'Win32_ComputerSystem' { [pscustomobject]@{ TotalPhysicalMemory = 64GB; HypervisorPresent = $true } }
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
function global:Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings, [switch]$Force) $global:Tasks[$TaskName] = $Action.Argument; Record "Register-ScheduledTask $TaskName" }
function global:Unregister-ScheduledTask { param($TaskName, $Confirm) $global:Tasks.Remove($TaskName); Record "Unregister-ScheduledTask $TaskName" }
function global:Start-Process { param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $Verb) Record "Start-Process $FilePath $ArgumentList"; if ($PassThru) { [pscustomobject]@{ ExitCode = 0 } } }
function global:docker {
    $a = @($args)
    if ($a[0] -eq 'compose') { Record "docker $($a -join ' ')"; $global:LASTEXITCODE = 0; return }
    if ($a[0] -eq 'exec' -and $a[1] -eq 'open-webui') { $global:LASTEXITCODE = 0; return '{"version":"0.35.1"}' }
    & /usr/bin/docker @a
}

# ---- phase 1: fresh install until WSL needs a reboot ----------------------------------------
Write-Host "`n=== PHASE 1: fresh run (expects reboot request) ===" -ForegroundColor Cyan
# 'trial-ok,trial-missing' as ONE string, the way Install-LocalAI.cmd (powershell -File) delivers it.
& $inst -AIRoot $aiRoot -SkipTests -TrialModels 'trial-ok,trial-missing' -KeepAlive 7m -BackupRetentionDays 9 -SkipCoder:$false
$code1 = $LASTEXITCODE
$state = Get-Content -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
Assert-That ($code1 -eq 3010) "phase 1 exits 3010 for reboot (got $code1)"
Assert-That ($global:Tasks.ContainsKey('LocalAI-Install-Resume')) 'resume task registered'
Assert-That ($global:Tasks['LocalAI-Install-Resume'] -match '-SkipCoder:\$false') 'an explicit false switch survives the reboot/resume relaunch'
Assert-That ($global:Tasks['LocalAI-Install-Resume'] -match "-Resume" -and $global:Tasks['LocalAI-Install-Resume'] -match [regex]::Escape((Join-Path $aiRoot 'Scripts'))) 'resume task runs the stable copy in AI\Scripts with -Resume'
Assert-That (@($global:Calls | Where-Object { $_ -like 'shutdown /r /t 60*' }).Count -eq 1) 'reboot scheduled with 60 s warning'
Assert-That ($null -ne $state.stages.Tuning -and $null -eq $state.stages.WSL) 'stages up to Tuning done, WSL pending'
Assert-That (Test-Path (Join-Path $aiRoot 'Scripts/lib/LocalAI.psm1')) 'scripts copied to AI\Scripts'

# ---- phase 2: resume after "reboot" ----------------------------------------------------------
Write-Host "`n=== PHASE 2: resume after reboot ===" -ForegroundColor Cyan
$global:WslInstalled = $true
$resumeCmd = $global:Tasks['LocalAI-Install-Resume']
$cmd = $resumeCmd.Substring($resumeCmd.IndexOf('-Command ') + 9)
Invoke-Expression $cmd
$code2 = $LASTEXITCODE
$state = Get-Content -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$envFile = Get-Content (Join-Path $aiRoot 'Stack/.env')
Assert-That ($code2 -eq 0) "phase 2 completes (exit $code2)"
foreach ($s in 'Preflight', 'Ollama', 'Models', 'Tuning', 'WSL', 'Docker', 'Stack', 'Configure', 'Backup') { Assert-That ($null -ne $state.stages.$s) "stage $s recorded" }
Assert-That (-not $global:Tasks.ContainsKey('LocalAI-Install-Resume')) 'resume task removed at the end'
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
Assert-That ((& /usr/bin/docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' (& /usr/bin/docker ps -aq --filter 'name=^/open-webui-legacy-')) -eq 'no') 'legacy container restart policy disabled'
Assert-That ($null -eq (& /usr/bin/docker ps -a --filter 'name=^/open-webui$' --format '{{.ID}}') -and (& /usr/bin/docker ps -a --filter 'name=^/open-webui-legacy-' --format '{{.Status}}') -match 'Exited') 'legacy container stopped and renamed (kept)'
Assert-That (@($global:Calls | Where-Object { $_ -like 'docker compose*up -d*' }).Count -ge 2) 'compose up ran (initial + after password removal)'
Assert-That (Test-Path (Join-Path $env:USERPROFILE '.wslconfig')) '.wslconfig created'
Assert-That ((Get-Content -Raw (Join-Path $aiRoot 'Stack/searxng/settings.yml')) -notmatch '__SEARXNG_SECRET__') 'SearXNG secret filled in'
Assert-That (Test-Path (Join-Path $aiRoot 'install-report.md')) 'install report written'
Assert-That ((Get-Content -Raw (Join-Path $aiRoot 'localai-config.json') | ConvertFrom-Json).SelectedModels.Count -ge 1) 'config written with selected models'

# ---- phase 3: idempotent re-run ----------------------------------------------------------------
Write-Host "`n=== PHASE 3: re-run (idempotent) ===" -ForegroundColor Cyan
# What changed after the first install must survive a re-run: an Update-OpenWebUI version bump, a
# render-guard mode, a custom .env key, and keys other scripts keep in the config (ComfyUIPath).
$envFile = Join-Path $aiRoot 'Stack/.env'
$envLines = @(Get-Content $envFile | ForEach-Object { if ($_ -like 'OPEN_WEBUI_VERSION=*') { 'OPEN_WEBUI_VERSION=v0.99.0' } elseif ($_ -like 'RENDER_GUARD_MODE=*') { 'RENDER_GUARD_MODE=off' } else { $_ } }) + 'COMFYUI_URLS=http://host.docker.internal:8190'
Set-Content -Path $envFile -Value $envLines
$cfgFile = Join-Path $aiRoot 'localai-config.json'
$cfgObj = Get-Content -Raw $cfgFile | ConvertFrom-Json
$cfgObj | Add-Member -NotePropertyName ComfyUIPath -NotePropertyValue 'D:\ComfyUI\run_nvidia_gpu.bat' -Force
$cfgObj | ConvertTo-Json -Depth 5 | Set-Content $cfgFile
$sw = [Diagnostics.Stopwatch]::StartNew()
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests
$code3 = $LASTEXITCODE
Assert-That ($code3 -eq 0) "re-run completes (exit $code3) in $([int]$sw.Elapsed.TotalSeconds) s"
Assert-That (@(Get-ChildItem (Join-Path $aiRoot 'Backups') -Filter '*pre-compose*').Count -eq 1) 'no second legacy migration on re-run'
$envAfter = Get-Content $envFile
Assert-That ($envAfter -contains 'OPEN_WEBUI_VERSION=v0.99.0') 're-run keeps the Open WebUI version set by Update-OpenWebUI'
Assert-That ($envAfter -contains 'RENDER_GUARD_MODE=off') 're-run keeps the render-guard mode'
Assert-That ($envAfter -contains 'COMFYUI_URLS=http://host.docker.internal:8190') 're-run keeps custom .env keys'
$cfgAfter = Get-Content -Raw $cfgFile | ConvertFrom-Json
Assert-That ($cfgAfter.ComfyUIPath -eq 'D:\ComfyUI\run_nvidia_gpu.bat') 're-run keeps ComfyUIPath in the config'
Assert-That ($cfgAfter.OpenWebUIVersion -eq 'v0.99.0' -and $cfgAfter.RenderGuard -eq 'off') 'config reflects the kept version and mode'
Assert-That ([string]$cfgAfter.WebUIOllamaUrl -ne '') 'config records the Ollama URL Open WebUI was given'
Assert-That ($cfgAfter.KeepAlive -eq '7m' -and [int]$cfgAfter.BackupRetentionDays -eq 9) 're-run without switches keeps -KeepAlive / -BackupRetentionDays from the first run'

Assert-That (@((Get-Content -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.selectedModels) -contains 'trial-ok') 're-run without -TrialModels keeps the chosen trial'

# ---- phase 4: drop the trial again ---------------------------------------------------------------
Write-Host "`n=== PHASE 4: re-run with -TrialModels none ===" -ForegroundColor Cyan
# Pretend this install predates remembered settings: the skips must be inferred from what is installed.
$st = Get-Content -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json
$st.flags.PSObject.Properties.Remove('params')
$st | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $aiRoot 'install-state.json')
& (Join-Path $aiRoot 'Scripts/Install-LocalAI.ps1') -AIRoot $aiRoot -SkipTests -TrialModels none
Assert-That ($LASTEXITCODE -eq 0) "phase 4 completes (exit $LASTEXITCODE)"
Assert-That (@((Get-Content -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.selectedModels) -notcontains 'trial-ok') '-TrialModels none deselects the trial'
$tp = Get-TestPreset 'trial-standin'
Assert-That ($tp -and $tp.meta.hidden -eq $true) 'deselected trial preset is hidden (kept for old chats)'
$p4 = (Get-Content -Raw (Join-Path $aiRoot 'install-state.json') | ConvertFrom-Json).flags.params
Assert-That ($p4.SkipVision -eq $true -and $p4.SkipCoder -eq $true) 'older install: skips inferred from the installed models (no surprise 20 GB downloads)'

& /usr/bin/docker rm -f open-webui 2>$null | Out-Null
& /usr/bin/docker ps -aq --filter 'name=^/open-webui-legacy-' | ForEach-Object { & /usr/bin/docker rm -f $_ | Out-Null }
if ($failures -eq 0) { Write-Host "`nMOCK RUN PASSED" -ForegroundColor Green } else { Write-Host "`nMOCK RUN FAILED ($failures)" -ForegroundColor Red }
exit $failures
