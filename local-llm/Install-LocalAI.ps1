#Requires -Version 5.1

<#
.SYNOPSIS
    One-shot, resumable installer for a private local AI stack on Windows + RTX 3090:
    Ollama (native, GPU) -> abliterated Qwen3 models -> WSL2 -> Docker Desktop -> Open WebUI + SearXNG.

.DESCRIPTION
    Executes the "local AI V1" build end to end, in the guide's order, and verifies every checkpoint
    before moving on (driver -> Ollama -> 14B on GPU -> 30B on GPU -> context tuning -> WSL2 -> Docker
    -> Open WebUI -> presets/memory/RAG/web search -> backup -> acceptance tests).

    Safe to re-run at any time: every step checks the current state first, nothing is downloaded twice,
    and tuned settings are reused. If WSL or Docker needs a reboot, the script registers a logon task,
    reboots (60 s warning, cancel with "shutdown /a") and continues after you sign in (it asks for
    administrator rights again: click Yes).

    The only prompts you should see: a UAC prompt (admin rights) at the start, and another after
    each reboot it needs.

.EXAMPLE
    # From the folder containing this file (normal PowerShell; it elevates itself):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-LocalAI.ps1

.EXAMPLE
    # Skip the optional vision and coding models, put models on D:
    .\Install-LocalAI.ps1 -SkipVision -SkipCoder -ModelDir D:\AI\OllamaModels
#>
[CmdletBinding()]
param(
    # ===================== CONFIG BLOCK =====================
    # Root for everything this installer creates (stack files, secrets, backups, logs, workspace).
    [string]$AIRoot = 'C:\AI',
    # Where Ollama keeps model blobs. '' = Ollama default (%USERPROFILE%\.ollama\models), unless that
    # drive is too full for the downloads and another fixed drive has room - then <drive>:\AI\OllamaModels.
    [string]$ModelDir = '',
    # Optional models (each ~19-20 GB). They are also skipped automatically when disk space is short.
    [switch]$SkipVision,
    [switch]$SkipCoder,
    # Opt-in newer models (keys marked Trial in config\models.psd1, e.g. trial-fast, trial-gemma4,
    # trial-code27b), added as extra presets next to the four measured ones; 'none' removes them.
    # Omitted on a re-run = keep the trials chosen before.
    [string[]]$TrialModels = @(),
    # Loopback ports (never exposed to the LAN). A busy port is replaced by the next free one.
    [int]$WebUIPort = 3000,
    # SearXNG's loopback port (Open WebUI's web search).
    [int]$SearxngPort = 8888,
    # Pinned image versions (the guide's :main tag is a moving target; Update-OpenWebUI.ps1 bumps these).
    [string]$OpenWebUIVersion = 'v0.11.4',
    # Pinned SearXNG image tag.
    [string]$SearxngVersion = '2026.10.2-19ffbcd30',
    # Open WebUI admin login. A random password is generated and stored in <AIRoot>\Secrets.
    [string]$AdminEmail = 'admin@localhost',
    # Ollama tuning. q8_0 halves KV-cache VRAM vs f16 at negligible quality cost, which roughly
    # doubles the context that fits next to a 19 GB model on 24 GB.
    [ValidateSet('f16', 'q8_0', 'q4_0')][string]$KvCacheType = 'q8_0',
    # OLLAMA_GPU_OVERHEAD. Since Ollama's llama-server runner (0.35) it only lowers the VRAM figure
    # Ollama picks its own default context from (keep <= 1024 or that drops to 4K); it reserves no VRAM.
    # For more room for the desktop/browser raise -MinFreeVramMiB instead.
    [ValidateRange(0, 1024)][int]$GpuOverheadMiB = 512,
    # The context tuner requires at least this much VRAM still free with the model loaded (the real
    # desktop/browser margin).
    [int]$MinFreeVramMiB = 768,
    # Before loading/tuning models, wait until other programs use at most this much VRAM (desktop is ~1.5-2.5 GB).
    [int]$MaxBusyVramMiB = 3500,
    # How long to wait for that before loading anyway.
    [int]$GpuWaitMinutes = 10,
    # How long an idle model stays in VRAM. Run Release-GPU.ps1 before ComfyUI/Forge sessions.
    [string]$KeepAlive = '15m',
    # While ComfyUI has a job running or queued, answer chats on the CPU instead of taking VRAM from
    # the render (stack/render-guard). 'off' = plain pass-through to Ollama.
    [ValidateSet('cpu', 'off')][string]$RenderGuard = 'cpu',
    # Empty Open WebUI knowledge collections to create (existing ones are kept).
    [string[]]$KnowledgeCollections = @('PC & Electronics', '3D Printing', 'Property', 'School', 'Home Projects', 'General References'),
    # Nightly backup of the Open WebUI volume (chats, memories, settings, knowledge).
    [string]$BackupTime = '03:30',
    # Daily archives older than this are deleted (the newest three always stay).
    [int]$BackupRetentionDays = 14,
    # Optional second copy of each backup (another drive or a NAS share).
    [string]$BackupMirror = '',
    # Behaviour switches.
    # When WSL/Docker needs a reboot: do not reboot by itself; stop (exit 3010) and resume after the next sign-in.
    [switch]$NoReboot,
    # Measure every model's context again, even when nothing changed.
    [switch]$Retune,
    # Skip the acceptance checklist (Test-LocalAI.ps1) at the end.
    [switch]$SkipTests,
    # Forget the settings remembered from earlier runs (e.g. a -SkipVision) and use the defaults above.
    [switch]$ForgetSettings,
    # Set by the after-reboot task: continue where the previous run stopped.
    [switch]$Resume
    # ========================================================
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$SourceRoot = $PSScriptRoot
$ToolkitVersion = 'unknown'
$versionFile = Join-Path $SourceRoot 'VERSION'
if (Test-Path -LiteralPath $versionFile) { $ToolkitVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim() }
Import-Module (Join-Path $SourceRoot 'lib\LocalAI.psm1') -Force

#region Elevation ---------------------------------------------------------------------------

function ConvertTo-PsLiteral {
    param($Value)
    if ($Value -is [array]) { return (($Value | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ',') }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    # PowerShell also ends a single-quoted string at the typographic quotes U+2018-U+201B: double them too.
    $t = [string]$Value
    foreach ($q in @("'", [string][char]0x2018, [string][char]0x2019, [string][char]0x201A, [string][char]0x201B)) { $t = $t.Replace($q, $q + $q) }
    return "'" + $t + "'"
}

function Get-RelaunchCommand {
    param([string]$ScriptPath = $PSCommandPath, [switch]$AddResume)
    $cmd = '& ' + (ConvertTo-PsLiteral $ScriptPath)
    foreach ($kv in $script:BoundParams.GetEnumerator()) {
        if ($kv.Key -eq 'Resume') { continue }
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            # An explicit -Name:$false matters too: it overrides a remembered switch.
            if ($kv.Value.IsPresent) { $cmd += " -$($kv.Key)" } else { $cmd += " -$($kv.Key):`$false" }
        } else {
            $cmd += " -$($kv.Key) " + (ConvertTo-PsLiteral $kv.Value)
        }
    }
    if ($AddResume) { $cmd += ' -Resume' }
    return $cmd
}

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:BoundParams = @{}
foreach ($kv in $PSBoundParameters.GetEnumerator()) { $script:BoundParams[$kv.Key] = $kv.Value }

if (-not (Test-IsAdmin)) {
    Write-Host 'Requesting administrator rights (needed for WSL, Docker Desktop, scheduled tasks and the port audit)...' -ForegroundColor Cyan
    # -AddResume keeps -Resume when the (non-elevated) resume task started this at sign-in, so the
    # elevated run counts failed resumes and stops retrying after two.
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', (Get-RelaunchCommand -AddResume:$Resume)) -ErrorAction Stop }
    catch {
        # 'No' at the UAC prompt (or closing it) lands here.
        if ($Resume) {
            Write-Host 'The Local AI install is not finished. It asks again at your next sign-in (sign out and back in to continue now), then click Yes.' -ForegroundColor Yellow
        } else {
            Write-Host 'Administrator rights were not granted, so nothing was installed. Run it again and click Yes at the prompt.' -ForegroundColor Red
        }
        exit 1223   # ERROR_CANCELLED
    }
    # Exit code 10 tells the wrappers (Install-LocalAI.cmd, Get-LocalAI.ps1) that the install goes on
    # in the new Administrator window.
    Write-Host 'The installer continues in the Administrator window that just opened; you can close this one.' -ForegroundColor Cyan
    exit 10
}

#endregion

#region Paths, state, helpers ---------------------------------------------------------------

# 'D:\AI\' and 'D:\AI' are the same folder; one spelling keeps state, task command lines and
# comparisons consistent. A bare drive gets its root backslash.
$AIRoot = $AIRoot.Trim()
if ($AIRoot -match '^[A-Za-z]:$') { $AIRoot += '\' }
elseif ($AIRoot.Length -gt 3) { $AIRoot = $AIRoot.TrimEnd([char]'\', [char]'/') }

$P = @{
    Root      = $AIRoot
    Scripts   = Join-Path $AIRoot 'Scripts'
    Stack     = Join-Path $AIRoot 'Stack'
    Secrets   = Join-Path $AIRoot 'Secrets'
    Backups   = Join-Path $AIRoot 'Backups'
    Logs      = Join-Path $AIRoot 'Logs'
    Workspace = Join-Path $AIRoot 'Workspace'
    Downloads = Join-Path $AIRoot 'Downloads'
    State     = Join-Path $AIRoot 'install-state.json'
    Config    = Join-Path $AIRoot 'localai-config.json'
    Report    = Join-Path $AIRoot 'install-report.md'
}
$OllamaUrl = 'http://127.0.0.1:11434'
# Where Ollama and Docker Desktop really are: both can be installed to a custom folder (to save C:),
# and running their vendor installer again over that fails. Default folders when not installed yet.
$OllamaDir = Find-LaiOllamaDir -OrDefault
$DockerExe = Find-LaiDockerDesktopExe -OrDefault
$DockerBin = Join-Path (Split-Path -Parent $DockerExe) 'resources\bin'
$ResumeTask = 'LocalAI-Install-Resume'
$ToolkitItems = @('Install-LocalAI.ps1', 'Install-LocalAI.cmd', 'Test-LocalAI.ps1', 'Backup-OpenWebUI.ps1', 'Update-OpenWebUI.ps1', 'Release-GPU.ps1', 'Set-OpenWebUIPassword.ps1', 'Restore-OpenWebUI.ps1', 'Update-Models.ps1', 'Start-ComfyUI.ps1', 'Enable-TailscaleAccess.ps1', 'Watch-LocalAI.ps1', 'Uninstall-LocalAI.ps1', 'Stop-LocalAI.ps1', 'Start-LocalAI.ps1', 'Get-LocalAIDiagnostics.ps1', 'Get-LocalAI.ps1', 'VERSION', 'README.md', 'lib', 'config', 'stack')
# After a reboot the resume task (not elevated) starts this copy, which asks for admin rights with a
# UAC prompt. The prompt names powershell.exe, not the script, so the script it runs must be one
# only Administrators can change: not C:\AI\Scripts (the user has full control of C:\AI and can
# swap any folder inside it).
$ElevatedDir = Join-Path $env:ProgramFiles 'LocalAI'
$BackupTask = 'LocalAI-Backup-OpenWebUI'
$WatchTask = 'LocalAI-Watch'
$CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$CurrentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

# This runs as administrator in folders the user controls: if one of them is a junction or symbolic
# link, the writes, permission changes and transcript below would land wherever it points.
foreach ($d in @($P.Root, $P.Logs, $P.Secrets, $P.Backups, $P.Downloads, $P.Scripts, $P.Stack)) {
    $link = Get-LaiReparsePath -Path $d
    if ($link) {
        Write-Host "$link is a junction or symbolic link. The installer runs as administrator and does not write through links; replace it with a normal folder, then run again." -ForegroundColor Red
        exit 1
    }
}
foreach ($d in @($P.Root, $P.Logs, $P.Secrets, $P.Backups, $P.Downloads)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
$script:TranscriptOn = $false
$script:TranscriptPath = Join-Path $P.Logs ('install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $script:TranscriptPath | Out-Null; $script:TranscriptOn = $true } catch { Write-Verbose 'Transcript unavailable' }

# One installer run or model update at a time (released when this process ends, even if killed).
try { $script:SetupLock = Enter-LaiSetupLock }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
$State = Read-LaiState -Path $P.State
foreach ($k in @('stages', 'tuning', 'flags')) { if (-not $State.ContainsKey($k) -or $null -eq $State[$k]) { $State[$k] = @{} } }

# Settings passed on an earlier run are remembered, so "Update toolkit" (which passes none) does not
# quietly undo them (e.g. download the Vision model skipped with -SkipVision). A value passed now wins.
# 'powershell -File' (Install-LocalAI.cmd) passes "a,b" as ONE string; split list parameters here.
$TrialModels = @($TrialModels | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$KnowledgeCollections = [string[]]@($KnowledgeCollections | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$RememberedParams = @('SkipVision', 'SkipCoder', 'AdminEmail', 'KvCacheType', 'GpuOverheadMiB', 'MinFreeVramMiB',
    'MaxBusyVramMiB', 'GpuWaitMinutes', 'KeepAlive', 'KnowledgeCollections', 'BackupTime', 'BackupRetentionDays', 'BackupMirror')
if ($ForgetSettings) { $State.flags['params'] = @{}; Write-LaiLog INFO 'Forgetting settings remembered from earlier runs (-ForgetSettings)' }
if (-not $State.flags.ContainsKey('params') -or $null -eq $State.flags['params']) {
    $State.flags['params'] = @{}
    # Installs made before settings were remembered: infer the skips from what was installed, so the
    # first update does not download a 20 GB model the user had left out.
    if (-not $ForgetSettings -and $State.flags.ContainsKey('selectedModels') -and @($State.flags['selectedModels']).Count -gt 0) {
        $had = @($State.flags['selectedModels'])
        if ($had -notcontains 'vision') { $State.flags['params']['SkipVision'] = $true }
        if ($had -notcontains 'code') { $State.flags['params']['SkipCoder'] = $true }
    }
    # Those installs kept some settings only in localai-config.json and in the tuning fingerprint.
    # Without this, the first update reset them: a 90-day retention became 14 (the first backup then
    # pruned 15-90-day-old archives), a backup mirror stopped, a custom KV cache forced a full re-tune.
    if (-not $ForgetSettings) {
        $oldCfg = Read-LaiState -Path $P.Config
        foreach ($k in @('BackupRetentionDays', 'BackupMirror', 'KeepAlive')) {
            if ($oldCfg.ContainsKey($k) -and $null -ne $oldCfg[$k] -and [string]$oldCfg[$k] -ne '') { $State.flags['params'][$k] = $oldCfg[$k] }
        }
        $fp = @($State.tuning.Values | Where-Object { $_ -is [hashtable] -and $_['Fingerprint'] } | ForEach-Object { [string]$_['Fingerprint'] }) | Select-Object -First 1
        if ($fp) {
            $kvOld = [regex]::Match($fp, '(?:^|;)kv=([^;]+)'); $ohOld = [regex]::Match($fp, '(?:^|;)overhead=(\d+)'); $frOld = [regex]::Match($fp, '(?:^|;)free=(\d+)')
            if ($kvOld.Success -and @('f16', 'q8_0', 'q4_0') -contains $kvOld.Groups[1].Value) { $State.flags['params']['KvCacheType'] = $kvOld.Groups[1].Value }
            if ($ohOld.Success -and [int]$ohOld.Groups[1].Value -le 1024) { $State.flags['params']['GpuOverheadMiB'] = [int]$ohOld.Groups[1].Value }
            if ($frOld.Success) { $State.flags['params']['MinFreeVramMiB'] = [int]$frOld.Groups[1].Value }
        }
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            try {
                $bt = Get-ScheduledTask -TaskName 'LocalAI-Backup-OpenWebUI' -ErrorAction Stop
                $sb = [string](@($bt.Triggers)[0].StartBoundary)
                if ($sb -match 'T(\d{2}:\d{2})') { $State.flags['params']['BackupTime'] = $Matches[1] }
            } catch { Write-Verbose 'no earlier backup task' }
        }
        $inferred = @($State.flags['params'].Keys | Sort-Object)
        if ($inferred.Count) { Write-LaiLog INFO "Settings carried over from the earlier install: $($inferred -join ', ')" }
    }
}
$savedParams = $State.flags['params']
foreach ($name in $RememberedParams) {
    if ($PSBoundParameters.ContainsKey($name)) {
        # The variable, not $PSBoundParameters: list parameters were split above, the bound value was not.
        $v = Get-Variable -Name $name -ValueOnly
        if ($v -is [System.Management.Automation.SwitchParameter]) { $v = [bool]$v.IsPresent }
        $savedParams[$name] = $v
    } elseif ($savedParams.ContainsKey($name)) {
        $v = $savedParams[$name]
        if ($name -like 'Skip*') { $v = [System.Management.Automation.SwitchParameter][bool]$v }
        if ($name -eq 'KnowledgeCollections') { $v = [string[]]@($v) }
        Set-Variable -Name $name -Value $v -Scope Script
        Write-Verbose "Using $name from the previous run"
    }
}

function Save-State { Save-LaiState -State $State -Path $P.State }

function Invoke-Stage {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    Write-Host ''
    Write-LaiLog STEP ('=' * 12 + " $Name " + '=' * 12)
    if ($env:LOCALAI_TEST_FAIL_STAGE -and $env:LOCALAI_TEST_FAIL_STAGE -eq $Name) { throw "Test hook: stage $Name failed" }
    & $Body
    $State.stages[$Name] = (Get-Date).ToString('s')
    Save-State
}

function Stop-Install {
    param([int]$Code = 0)
    if ($script:TranscriptOn) { try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript' } }
    # The relaunched window stays open after the script ends (-NoExit), and a mutex stays owned as
    # long as its thread lives: release it, or a re-run would be refused until that window closes.
    if ($script:SetupLock) { Exit-LaiVolumeLock $script:SetupLock; $script:SetupLock = $null }
    exit $Code
}

function Invoke-Native {
    # Runs a native command without PS 5.1 turning stderr lines into terminating errors.
    # -Capture returns its combined output; otherwise output streams straight to the console.
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [switch]$Capture, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # docker and ollama write UTF-8; 5.1 decodes captured output with the console code page (437,
    # 850, 932...), which turns a non-ASCII path like C:\Users\Jose-with-accent into something else.
    $prevEnc = $null
    if ($Capture -and (Split-Path -Leaf $File) -match '^(docker|ollama)(\.exe)?$') {
        try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $prevEnc = $null }
    }
    try {
        if ($Capture) { $out = @(& $File @Arguments 2>&1 | ForEach-Object { "$_" }) }
        else { & $File @Arguments | Out-Host; $out = @() }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
        if ($prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { Write-Verbose 'console encoding not restored' } }
    }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "'$File $($Arguments -join ' ')' failed with exit code $code. $(($out | Select-Object -Last 15) -join "`n")"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $out; Text = ($out -join "`n") }
}

function Start-AsUser {
    # Explorer starts the target with the signed-in user's normal (non-elevated) token, so tray apps
    # like Ollama and Docker Desktop do not inherit this script's admin rights.
    param([Parameter(Mandatory)][string]$Target)
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('"{0}"' -f $Target)
}

function Start-OllamaAsUser {
    # Explorer passes no arguments, so 'hidden' cannot be given: the Ollama window opens once, while
    # the user watches the install. Not via Ollama's Startup\Ollama.lnk: the app treats that as a
    # sign-in start (hidden, no --fast-startup) and installs a pending update right then, swapping
    # Ollama in the middle of the install (the presets would be measured on the old version).
    Start-AsUser (Join-Path $OllamaDir 'ollama app.exe')  # lai-ok: hidden
}

function Set-UserEnv {
    # Persists a user environment variable (broadcasts WM_SETTINGCHANGE) and applies it to this process.
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Value)
    $current = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ($Value -eq '') { $Value = $null }
    if ($current -eq $Value) { return $false }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path "Env:$Name" -Value $Value -ErrorAction SilentlyContinue
    if ($null -eq $Value) { Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue }
    return $true
}

function Save-PrevUserEnv {
    # Before the installer first writes its OLLAMA_* variables, records what each one was ('' = unset),
    # so Uninstall -ResetOllamaSettings puts a value of the user's own back (e.g. OLLAMA_NUM_PARALLEL=4
    # for an IDE agent) and removes only the installer's. Once the Ollama stage has completed, the
    # values are the installer's own (an earlier -KeepAlive, an older default): nothing is recorded.
    param([Parameter(Mandatory)][string[]]$Names)
    $saved = @{}
    if ($State.flags['prevOllamaEnv'] -is [hashtable]) { $saved = $State.flags['prevOllamaEnv'] }
    $any = $false
    foreach ($n in $Names) {
        $cur = [Environment]::GetEnvironmentVariable($n, 'User')
        if (Add-LaiPrevEnv -Saved $saved -Name $n -Current $cur -InstallerSetBefore:([bool]$State.stages['Ollama'])) {
            $any = $true
            if ($cur) { Write-LaiLog INFO "$n was '$cur' (your own setting); Uninstall-LocalAI.ps1 -ResetOllamaSettings puts it back" }
        }
    }
    if ($any) { $State.flags['prevOllamaEnv'] = $saved; Save-State }
}

function Add-SessionPath {
    param([string]$Dir)
    if ($Dir -and (Test-Path -LiteralPath $Dir) -and (($env:Path -split ';') -notcontains $Dir)) { $env:Path = "$Dir;$env:Path" }
}

function Set-OllamaBlockRule {
    # Only while Ollama has to listen beyond 127.0.0.1 (containers could not reach it otherwise).
    # Default: block port 11434 by ADDRESS (everything except loopback, Docker Desktop's
    # 192.168.65.0/24 and the WSL/Docker adapter subnets found now), whichever adapter traffic comes
    # in on: Wi-Fi, Ethernet, Tailscale, VPN, adapters added later. -AdaptersOnly: the older rule on
    # the physical adapters, used when Docker cannot get through the address rule.
    param([switch]$AdaptersOnly)
    $ruleName = 'LocalAI - Block Ollama from LAN'
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    if ($AdaptersOnly) {
        $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceAlias })
        if ($nics.Count -gt 0) { New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort 11434 -Action Block -InterfaceAlias $nics -Profile Any | Out-Null }
        Write-LaiLog WARN "Docker could not reach Ollama through the address-based block; using a block on the network adapters ($($nics -join ', ')) instead. VPN/Tailscale adapters are NOT covered: don't share this PC's Ollama port on a tailnet."
        return
    }
    $allowed = @('127.0.0.0/8', '192.168.65.0/24')
    $allowed += @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -like 'vEthernet (WSL*' -or $_.InterfaceAlias -like '*Docker*' } |
        ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
    $blocked = @(Get-LaiBlockRange -Allowed $allowed) + '::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort 11434 -Action Block -RemoteAddress $blocked -Profile Any | Out-Null
    Write-LaiLog OK "Firewall: Ollama port 11434 blocked from every address except this PC and Docker/WSL ($($allowed -join ', '))"
}

function Protect-Path {
    # Owner, SYSTEM and Administrators only (folders under C:\ otherwise inherit "Authenticated Users").
    # -UserAccess ReadOnly: the user may read and run but not change it (Administrators still can);
    # used for the copy the resume relaunches elevated (see $ElevatedDir).
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('Full', 'ReadOnly')][string]$UserAccess = 'Full')
    $r = Set-LaiPrivateAcl -Path $Path -UserSid $CurrentUserSid -UserAccess $UserAccess
    if ($r.ExitCode -ne 0) { Write-LaiLog WARN "Could not restrict permissions on ${Path}: $($r.Text)" }
}

function Get-DriveOf {
    # 'D:' for 'D:\Users\x\...'; the system drive when the path has no drive letter.
    param([Parameter(Mandatory)][string]$Path)
    try { $q = Split-Path -Qualifier $Path -ErrorAction Stop; if ($q) { return $q } } catch { Write-Verbose "no drive in $Path" }
    return $env:SystemDrive
}

function Get-FreeGB {
    param([Parameter(Mandatory)][string]$Path)
    $qualifier = Split-Path -Qualifier $Path
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$qualifier'"
    if (-not $disk) { return 0 }
    return [Math]::Round($disk.FreeSpace / 1GB, 1)
}

function Get-OllamaLiveConfig {
    # OLLAMA_MODELS / OLLAMA_HOST as the Ollama server last started with them (its server.log), after
    # the tray app's own settings overrode the environment; $null when there is no such log line.
    return (Get-LaiOllamaLiveConfig -LogPath (Join-Path $env:LOCALAPPDATA 'Ollama\server.log'))
}

function Install-App {
    # winget first (hash-verified manifest); direct download from the vendor as the fallback.
    param(
        [Parameter(Mandatory)][string]$WingetId,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string[]]$InstallerArgs,
        [Parameter(Mandatory)][scriptblock]$IsInstalled,
        # The vendor name the signing certificate must carry: a valid signature from anyone else
        # (a hijacked download, a look-alike) is refused.
        [Parameter(Mandatory)][string]$Publisher
    )
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-LaiLog INFO "winget install $WingetId"
        $wargs = @('install', '--exact', '--id', $WingetId, '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($InstallerArgs.Count -gt 0 -and $WingetId -eq 'Docker.DockerDesktop') { $wargs += @('--override', ($InstallerArgs -join ' ')) }
        Invoke-Native -File $winget.Name -Arguments $wargs -AllowFail | Out-Null
        if (& $IsInstalled) { return }
        Write-LaiLog WARN "winget did not install $WingetId; falling back to a direct download."
    }
    # An administrators-only folder: in C:\AI\Downloads (the user's), anything running as the user could
    # swap the file between the signature check and Start-Process, which runs it as administrator.
    $dlDir = Join-Path $env:ProgramFiles 'LocalAI-Downloads'
    if (-not (Test-Path -LiteralPath $dlDir)) { New-Item -ItemType Directory -Force -Path $dlDir | Out-Null }
    if (Get-LaiReparsePath -Path $dlDir) { throw "$dlDir is a link; refusing to download an installer there." }
    $dest = Join-Path $dlDir $FileName
    Write-LaiLog INFO "Downloading $Url"
    Invoke-LaiRetry -What "download $FileName" -Action { Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing } | Out-Null
    $sig = Get-AuthenticodeSignature -FilePath $dest
    if ($sig.Status -ne 'Valid') { throw "$FileName has an invalid Authenticode signature ($($sig.Status)); refusing to run it." }
    # The vendor must BE the certificate's CN= or O= (whole word): 'O=Docker, Inc.' passes,
    # 'O=Dockerize LLC' does not.
    if ([string]$sig.SignerCertificate.Subject -notmatch ('(^|,\s*)(CN|O)="?' + [regex]::Escape($Publisher) + '\b')) { throw "$FileName is signed by '$($sig.SignerCertificate.Subject)', not $Publisher; refusing to run it." }
    Write-LaiLog INFO "Running $FileName (signed by $($sig.SignerCertificate.Subject.Split(',')[0]))"
    try { $proc = Start-Process -FilePath $dest -ArgumentList $InstallerArgs -Wait -PassThru }
    finally { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }   # also after a failure
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) { throw "$FileName exited with code $($proc.ExitCode)" }
    if ($proc.ExitCode -eq 3010) { $State.flags['rebootPending'] = $true }
    if (-not (& $IsInstalled)) { throw "$FileName finished but the product is still not detected." }
}

function Register-ResumeTask {
    if ($SourceRoot.TrimEnd('\', '/') -ne $ElevatedDir.TrimEnd('\', '/')) {
        if (Test-Path -LiteralPath $ElevatedDir) { Remove-LaiTree -Path $ElevatedDir }
        New-Item -ItemType Directory -Force -Path $ElevatedDir | Out-Null
        foreach ($item in $ToolkitItems) {
            $src = Join-Path $SourceRoot $item
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $ElevatedDir -Recurse -Force }
        }
        Protect-Path -Path $ElevatedDir -UserAccess ReadOnly
    }
    $scriptPath = Join-Path $ElevatedDir 'Install-LocalAI.ps1'
    $cmd = Get-RelaunchCommand -ScriptPath $scriptPath -AddResume
    # Visible on purpose: the resumed installer shows its progress and waits for you (-NoExit).
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -NoExit -Command $cmd"   # lai-ok: window
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
    # Not elevated: at sign-in it starts the installer, which asks for administrator rights with a
    # normal UAC prompt (as on the first run). A task that ran the installer elevated without asking
    # would let anything running as the user steer it through files in C:\AI (state, junctions,
    # tools found on the user's PATH): nothing in this toolkit gets admin rights without a prompt.
    $principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 8)
    Register-ScheduledTask -TaskName $ResumeTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

function Request-Reboot {
    param([Parameter(Mandatory)][string]$Reason)
    Register-ResumeTask
    $State.flags['rebootRequestedAt'] = (Get-Date).ToString('s')
    $State.flags['resumeFailures'] = 0
    Save-State
    Write-LaiLog WARN "Reboot required: $Reason"
    if ($NoReboot) {
        Write-LaiLog WARN 'Reboot when convenient and sign in again; the installer resumes then (click Yes when Windows asks for administrator rights).'
        Stop-Install 3010
    }
    Write-LaiLog WARN 'Rebooting in 60 seconds. Save your work, or run "shutdown /a" to cancel. After you sign in the installer resumes: click Yes when Windows asks for administrator rights.'
    Invoke-Native -File 'shutdown.exe' -Arguments @('/r', '/t', '60', '/c', "Local AI installer: $Reason. It continues after you sign in (click Yes at the prompt).") | Out-Null
    Stop-Install 3010
}

function Test-DockerEngine {
    $r = Invoke-Native -File 'docker' -Arguments @('info', '--format', '{{.ServerVersion}}') -Capture -AllowFail
    return ($r.ExitCode -eq 0 -and $r.Text -match '^\d')
}

function Invoke-Compose {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Capture, [switch]$AllowFail)
    $base = @('compose', '--project-directory', $P.Stack, '-f', (Join-Path $P.Stack 'docker-compose.yml'))
    return Invoke-Native -File 'docker' -Arguments ($base + $Arguments) -Capture:$Capture -AllowFail:$AllowFail
}

function Invoke-ComposeUp {
    # Starting containers goes through the volume lock: never between a backup's stop and its archive,
    # or between a restore's stop and its swap. Under the lock, a restore that failed meanwhile
    # (hold) stops it from starting Open WebUI on a damaged volume.
    param([Parameter(Mandatory)][string[]]$Arguments)
    if (Test-LaiVolumeLockBusy) { Write-LaiLog INFO 'Waiting for a backup/restore/update to finish first' }
    $lock = Enter-LaiVolumeLock -TimeoutSec 1800
    try {
        $hold = Get-LaiWebUIHold -AIRoot $AIRoot
        if ($hold) { throw "Open WebUI is kept stopped after a failed restore ($($hold['Reason'])); starting it could run on damaged data. Recover first: $($hold['Recover'])" }
        Invoke-Compose -Arguments $Arguments | Out-Null
    } finally { Exit-LaiVolumeLock $lock }
}

function Get-PortOwner {
    param([int]$Port)
    $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return $null }
    $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    if ($proc) { return $proc.ProcessName }
    return "pid $($c.OwningProcess)"
}

function Select-FreePort {
    # Keeps the requested port if it is free or already published by this stack's own container;
    # otherwise the next free one. Docker's listener can also be another project's container (Grafana
    # on 3000, Jupyter on 8888) or a WSL service: compose would then stop with "port is already allocated".
    param([int]$Preferred)
    $dockerProcs = @('com.docker.backend', 'wslrelay', 'vpnkit', 'com.docker.proxy', 'docker-proxy')
    for ($port = $Preferred; $port -lt $Preferred + 20; $port++) {
        $owner = Get-PortOwner -Port $port
        if (-not $owner) { return $port }
        if ($dockerProcs -contains $owner) {
            $pub = Invoke-Native -File 'docker' -Arguments @('ps', '-a', '--filter', "publish=$port", '--format', '{{.Names}}|{{.Label `com.docker.compose.project`}}') -Capture -AllowFail
            # docker not answering: keep the port, as before (it is most likely this stack's).
            if ($pub.ExitCode -ne 0) { return $port }
            $users = @($pub.Output | Where-Object { $_ })
            if (@($users | Where-Object { $_ -match '\|localai$' }).Count) { return $port }
            $who = 'a program behind Docker/WSL'
            if ($users.Count) { $who = 'the container ' + (@($users | ForEach-Object { ($_ -split '\|')[0] }) -join ', ') + ' (not part of this stack)' }
            Write-LaiLog WARN "Port $port is used by $who; trying $($port + 1)."
            continue
        }
        Write-LaiLog WARN "Port $port is used by '$owner'; trying $($port + 1)."
    }
    throw "No free port found near $Preferred."
}

function Write-StackEnv {
    # Writes the managed keys and keeps any other key already in .env (e.g. a custom COMFYUI_URLS).
    param([hashtable]$Values)
    $envPath = Join-Path $P.Stack '.env'
    $all = @{}
    if (Test-Path -LiteralPath $envPath) {
        foreach ($line in (Get-Content -Encoding UTF8 -LiteralPath $envPath)) {
            if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $all[$Matches[1]] = $Matches[2] }
        }
    }
    foreach ($k in $Values.Keys) { $all[$k] = $Values[$k] }
    $lines = foreach ($k in ($all.Keys | Sort-Object)) { "$k=$($all[$k])" }
    [System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    Protect-Path -Path $envPath
}

function Get-AdminCredential {
    $credFile = Join-Path $P.Secrets 'openwebui-admin.json'
    if (Test-Path -LiteralPath $credFile) { return (Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json) }
    return $null
}

function Save-AdminCredential {
    param([string]$Email, [string]$Password)
    $file = Join-Path $P.Secrets 'openwebui-admin.json'
    ConvertTo-Json -InputObject @{ email = $Email; password = $Password; url = "http://localhost:$($script:WebUIPortEffective)" } |
        Set-Content -LiteralPath $file -Encoding UTF8
    Protect-Path -Path $file
}

#endregion

$SystemPrompt = (Get-Content -Encoding UTF8 -LiteralPath (Join-Path $SourceRoot 'config\system-prompt.txt') -Raw).Trim()
$CatalogPath = Join-Path $SourceRoot 'config\models.psd1'
# Test hooks for tests/Invoke-InstallerMockRun.ps1 only (small stand-in model on a CPU-only box).
if ($env:LOCALAI_TEST_CATALOG) { $CatalogPath = $env:LOCALAI_TEST_CATALOG }
$AllowCpu = ($env:LOCALAI_TEST_ALLOW_CPU -eq '1')
$script:WebUIPortEffective = $WebUIPort
if ($State.flags.ContainsKey('webuiPort')) { $script:WebUIPortEffective = [int]$State.flags['webuiPort'] }
$script:SearxngPortEffective = $SearxngPort
if ($State.flags.ContainsKey('searxngPort')) { $script:SearxngPortEffective = [int]$State.flags['searxngPort'] }

# A re-run keeps what changed since the first install unless the parameter is passed explicitly:
# image versions bumped by Update-OpenWebUI.ps1 (the volume is already migrated to them, so going
# back to the installer's pin would break Open WebUI) and the render-guard mode.
$PrevStackEnv = @{}
$prevEnvPath = Join-Path $P.Stack '.env'
if (Test-Path -LiteralPath $prevEnvPath) {
    foreach ($line in (Get-Content -Encoding UTF8 -LiteralPath $prevEnvPath)) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $PrevStackEnv[$Matches[1]] = $Matches[2] }
    }
}
if (-not $PSBoundParameters.ContainsKey('OpenWebUIVersion') -and $PrevStackEnv['OPEN_WEBUI_VERSION'] -and $PrevStackEnv['OPEN_WEBUI_VERSION'] -ne $OpenWebUIVersion) {
    Write-LaiLog INFO "Keeping the installed Open WebUI $($PrevStackEnv['OPEN_WEBUI_VERSION']) (this installer pins $OpenWebUIVersion; change versions with Update-OpenWebUI.ps1)"
    $OpenWebUIVersion = $PrevStackEnv['OPEN_WEBUI_VERSION']
}
if (-not $PSBoundParameters.ContainsKey('SearxngVersion') -and $PrevStackEnv['SEARXNG_VERSION'] -and $PrevStackEnv['SEARXNG_VERSION'] -ne $SearxngVersion) {
    Write-LaiLog INFO "Keeping the installed SearXNG $($PrevStackEnv['SEARXNG_VERSION'])"
    $SearxngVersion = $PrevStackEnv['SEARXNG_VERSION']
}
if (-not $PSBoundParameters.ContainsKey('RenderGuard') -and @('cpu', 'off') -contains $PrevStackEnv['RENDER_GUARD_MODE'] -and $PrevStackEnv['RENDER_GUARD_MODE'] -ne $RenderGuard) {
    Write-LaiLog INFO "Keeping render guard mode '$($PrevStackEnv['RENDER_GUARD_MODE'])' (pass -RenderGuard to change it)"
    $RenderGuard = $PrevStackEnv['RENDER_GUARD_MODE']
}

Write-LaiLog STEP "Local AI installer $ToolkitVersion - log: $($P.Logs)"
if (-not $Resume -and $SourceRoot.TrimEnd('\') -eq $P.Scripts.TrimEnd('\')) {
    Write-LaiLog WARN (('This is the installed copy in {0}; it re-applies the toolkit you already have. To get the newest ' +
        'version use Start menu > Local AI > Update toolkit, or the one-line command in the README.') -f $P.Scripts)
}
if ($Resume) { Write-LaiLog INFO 'Resuming after reboot/sign-in.' }

function Repair-LegacyInstall {
    # Leftovers of earlier versions that must not wait until a stage near the end (which a failed or
    # interrupted run never reaches).
    # 1. Before the no-silent-elevation change, the backup and resume tasks ran elevated (RunLevel
    #    Highest) and executed code from C:\AI, which the user controls: an admin escalation path.
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        foreach ($tn in @($BackupTask, $WatchTask)) {
            $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
            if ($t -and [string]$t.Principal.RunLevel -eq 'Highest') {
                Set-ScheduledTask -TaskName $tn -Principal (New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited) | Out-Null
                Write-LaiLog OK "Scheduled task '$tn' from an earlier version no longer runs as administrator"
            }
        }
        $rt = Get-ScheduledTask -TaskName $ResumeTask -ErrorAction SilentlyContinue
        if ($rt) {
            $acts = @($rt.Actions | ForEach-Object { [string]$_.Arguments }) -join ' '
            if ([string]$rt.Principal.RunLevel -eq 'Highest' -or $acts -notlike "*$ElevatedDir*") {
                if ($Resume) { Register-ResumeTask } else { Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false }
                Write-LaiLog OK 'Replaced the after-reboot task of an earlier version (it ran the installer as administrator without asking)'
            }
        }
    }
    # 2. The first bootstrap unpacked the toolkit into C:\AI\Installer; double-clicking that old copy
    #    would rewrite .env, drop the render guard and register an elevated task again.
    #    Only exactly what it made (ComfyUi-Optimization-<ref>\local-llm with the toolkit, nothing
    #    else): a folder of the user's that happens to be called Installer is left alone.
    $oldInstaller = Join-Path $P.Root 'Installer'
    $isOldCopy = $false
    if (Test-Path -LiteralPath $oldInstaller -PathType Container) {
        $entries = @(Get-ChildItem -LiteralPath $oldInstaller -Force)
        $isOldCopy = $entries.Count -gt 0 -and @($entries | Where-Object {
                -not ($_.PSIsContainer -and $_.Name -like 'ComfyUi-Optimization-*' -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'local-llm/Install-LocalAI.ps1')) -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'local-llm/lib/LocalAI.psm1'))) }).Count -eq 0
        if (-not $isOldCopy) { Write-Verbose "$oldInstaller is not the old toolkit copy; left alone" }
    }
    if ($isOldCopy -and -not ($SourceRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar).StartsWith($oldInstaller.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        try { Remove-LaiTree -Path $oldInstaller; Write-LaiLog OK "Removed the outdated toolkit copy in $oldInstaller" }
        catch { Write-LaiLog WARN "Could not remove the outdated toolkit copy in ${oldInstaller}: $($_.Exception.Message)" }
    }
    # 3. Early versions copied the guide's secret key into Secrets instead of moving it.
    $rootSecret = Join-Path $P.Root 'openwebui-secret.txt'
    $managedSecret = Join-Path $P.Secrets 'openwebui-secret.txt'
    if ((Test-Path -LiteralPath $rootSecret) -and (Test-Path -LiteralPath $managedSecret)) {
        $a = ([string](Get-Content -LiteralPath $rootSecret -Raw -Encoding UTF8)).Trim(); $b = ([string](Get-Content -LiteralPath $managedSecret -Raw -Encoding UTF8)).Trim()
        if ($a -and $a -eq $b) {
            Remove-Item -LiteralPath $rootSecret -Force
            Write-LaiLog OK "Removed a second copy of the Open WebUI secret key outside $($P.Secrets)"
        }
    }
    # 4. An old "Update toolkit" shortcut ignored -AIRoot and ran against C:\AI: a fresh state here
    #    next to a running install somewhere else would build a second, broken install.
    if (-not $State.stages.Count -and (Get-Command docker -ErrorAction SilentlyContinue)) {
        $wd = Invoke-Native -File 'docker' -Arguments @('ps', '-a', '--filter', 'label=com.docker.compose.project=localai', '--filter', 'label=com.docker.compose.service=open-webui', '--format', '{{.Label `com.docker.compose.project.working_dir`}}') -Capture -AllowFail
        if ($wd.ExitCode -eq 0) {
            $other = @($wd.Output | Where-Object { $_ -and $_.TrimEnd('\', '/') -ne $P.Stack.TrimEnd('\', '/') } | Select-Object -Unique)
            if ($other.Count) {
                throw "Local AI is already installed with its stack in $($other[0]), not in $($P.Stack). Run the installer with -AIRoot '$(Split-Path -Parent $other[0])' (nothing was changed)."
            }
        }
    }
}

try {
Repair-LegacyInstall


#region 1. Preflight ------------------------------------------------------------------------
Invoke-Stage 'Preflight' {
    $build = [Environment]::OSVersion.Version.Build
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $osName = 'Windows 10'
    if ($build -ge 22000) { $osName = 'Windows 11' }
    Write-LaiLog INFO "$osName $($cv.DisplayVersion) (build $build.$($cv.UBR))"
    if ($build -lt 19045) { throw 'Windows 10 22H2 (build 19045) or newer is required by Ollama and Docker Desktop. Run Windows Update, then re-run.' }

    $gpu = Get-LaiGpuInfo
    if (-not $gpu) {
        # Say what this PC has: an AMD/Intel GPU or an ARM CPU is not a broken NVIDIA driver.
        $videoNames = @()
        try { $videoNames = @(Get-CimInstance Win32_VideoController | ForEach-Object { [string]$_.Name }) } catch { Write-Verbose 'video controllers not readable' }
        throw (Get-LaiNoNvidiaMessage -VideoControllers $videoNames -Architecture ([string]$env:PROCESSOR_ARCHITECTURE))
    }
    Write-LaiLog OK "GPU: $($gpu.Name), driver $($gpu.DriverVersion), $($gpu.TotalMiB) MiB VRAM ($($gpu.FreeMiB) MiB free)"
    if ($gpu.Count -gt 1) {
        $gpuList = @($gpu.All | ForEach-Object { '{0} ({1} MiB)' -f $_.Name, $_.TotalMiB }) -join '; '
        Write-LaiLog WARN ("{0} NVIDIA GPUs: {1}. The VRAM checks and the context tuning use the largest, {2}. Ollama spreads a model that does not fit in 80% of one card's free memory over all cards, which is slower; to keep it on one card, set the user environment variable CUDA_VISIBLE_DEVICES to that card's UUID (nvidia-smi -L lists them), then quit and restart Ollama." -f $gpu.Count, $gpuList, $gpu.Name)
    }
    if ([version]$gpu.DriverVersion -lt [version]'551.61') {
        throw "NVIDIA driver $($gpu.DriverVersion) is older than 551.61, the minimum Ollama supports on Windows. Update from https://www.nvidia.com/Download/index.aspx, reboot, re-run."
    }
    if ($gpu.TotalMiB -lt 23000) { Write-LaiLog WARN "This $($gpu.Name) has $($gpu.TotalMiB) MiB of VRAM; the model catalog is sized for a 24 GB card. Models that cannot load fully on it are left out (or the install stops) before anything is downloaded." }
    if ($gpu.UsedMiB -gt 3000) {
        Write-LaiLog WARN "$($gpu.UsedMiB) MiB of VRAM is already in use (ComfyUI/Forge/games?). Close GPU-heavy apps before the context tuning step for accurate results."
    }

    $cs = Get-CimInstance Win32_ComputerSystem
    # A standard account that typed an administrator's password at the UAC prompt runs this as that
    # administrator: tasks, AppData and folder permissions then belong to the other account, and the
    # resume after a reboot waits for the administrator to sign in.
    if ($cs.UserName -and $cs.UserName -ne $CurrentUser) {
        Write-LaiLog WARN "You are signed in as $($cs.UserName), but the installer runs as $CurrentUser (credentials typed at the UAC prompt). Local AI is set up for $CurrentUser. To use it from $($cs.UserName), make that account an administrator and run the installer there."
    }
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ramGB = [Math]::Round($cs.TotalPhysicalMemory / 1GB)
    Write-LaiLog INFO ("CPU: {0}; RAM: {1} GB" -f $cpu.Name.Trim(), $ramGB)
    if (-not $cs.HypervisorPresent -and -not $cpu.VirtualizationFirmwareEnabled) {
        Write-LaiLog WARN ('CPU virtualization looks disabled in firmware. Docker needs it: enable ' + (Get-LaiVirtualizationHint -Manufacturer ([string]$cpu.Manufacturer)) + '.')
    }

    # Disk planning: decide where models go and whether the optional models fit.
    $catalogAll = Get-LaiCatalog -Path $CatalogPath -IncludeTrials
    $trialWanted = @()
    if ($script:BoundParams.ContainsKey('TrialModels')) {
        $trialWanted = @($TrialModels | Where-Object { $_ -and $_ -ne 'none' })
    } elseif ($State.flags.ContainsKey('selectedModels')) {
        $trialWanted = @($State.flags['selectedModels'] | Where-Object { $_ -like 'trial-*' })
    }
    $trialKeys = @($catalogAll.Models | Where-Object { $_.Trial } | ForEach-Object { $_.Key })
    foreach ($t in $trialWanted) { if ($trialKeys -notcontains $t) { Write-LaiLog WARN "Unknown trial model '$t' (known: $($trialKeys -join ', '))" } }

    # VRAM before disk: a model that cannot load fully on this card would fail the Models stage's
    # 100%-GPU checkpoint only after its download (Fast + Main = 28 GB), on every re-run.
    $tooBigForGpu = @()
    foreach ($m in $catalogAll.Models) {
        if ($m.Trial -and $trialWanted -notcontains $m.Key) { continue }
        if (Test-LaiModelFitsVram -DownloadGB $m.DownloadGB -TotalMiB $gpu.TotalMiB) { continue }
        if (-not $m.Optional) {
            throw ("{0} ({1} GB) cannot load fully on this {2} ({3} MiB of VRAM): this toolkit's models are sized for a 24 GB NVIDIA card (RTX 3090/4090). Nothing was downloaded. For a smaller card the catalog has to be edited (README: Maintain > Add or swap a model)." -f $m.Display, $m.DownloadGB, $gpu.Name, $gpu.TotalMiB)
        }
        $tooBigForGpu += $m.Key
    }

    $defaultModels = Join-Path $env:USERPROFILE '.ollama\models'
    # User scope first (the installer's own), then a system-wide one, then the folder the running
    # Ollama really uses (its app's Settings > Model location overrides both variables).
    $envModels = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User')
    if (-not $envModels) { $envModels = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'Machine') }
    $liveCfg = Get-OllamaLiveConfig
    if (-not $envModels -and $liveCfg -and $liveCfg['Models'] -and -not (Test-LaiSamePath $liveCfg['Models'] $defaultModels)) { $envModels = $liveCfg['Models'] }
    $target = $defaultModels
    if ($ModelDir) { $target = $ModelDir }
    elseif ($State.flags.ContainsKey('modelDir')) { $target = $State.flags['modelDir'] }
    elseif ($envModels) { $target = $envModels }
    else {
        # Catalog entries are hashtables; Windows PowerShell 5.1's Measure-Object -Property can't read their keys.
        $needAll = 10
        foreach ($cm in $catalogAll.Models) { if (-not $cm.Trial -or $trialWanted -contains $cm.Key) { $needAll += [double]$cm.DownloadGB } }
        $hasExisting = (Test-Path -LiteralPath (Join-Path $defaultModels 'manifests'))
        # The drive Ollama's default folder is on: the user profile can live on D: (not the system drive).
        $defaultDrive = Get-DriveOf $defaultModels
        if (-not $hasExisting -and (Get-FreeGB $defaultModels) -lt ($needAll + 40)) {
            $best = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.DeviceID -ne $defaultDrive } |
                Sort-Object FreeSpace -Descending | Select-Object -First 1  # lai-ok: objects
            if ($best -and ($best.FreeSpace / 1GB) -ge ($needAll + 10)) {
                $target = Join-Path "$($best.DeviceID)\" 'AI\OllamaModels'
                Write-LaiLog INFO "$defaultDrive is short on space; models go to $target"
            }
        }
    }
    $State.flags['modelDir'] = $target
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }

    $selected = @()
    $freeGB = Get-FreeGB $target
    $present = @()
    try { $present = Get-LaiOllamaModelNames -BaseUrl $OllamaUrl }
    catch {
        # Ollama not running (resume at sign-in, after gaming mode) or not installed yet: read the
        # model folder instead, so installed models are not charged their full download size.
        foreach ($cm in $catalogAll.Models) {
            if (Test-Path -LiteralPath (Get-LaiModelManifestPath -ModelDir $target -Name $cm.Source)) { $present += (Resolve-LaiModelName $cm.Source) }
        }
        if ($present.Count) { Write-LaiLog INFO "Ollama is not answering yet; found $($present.Count) installed model(s) in $target" }
    }
    $budget = $freeGB - 15
    foreach ($m in ($catalogAll.Models | Sort-Object { $_.Optional })) {
        $need = $m.DownloadGB
        if ($m.Trial -and $trialWanted -notcontains $m.Key) { continue }
        if ($present -contains (Resolve-LaiModelName $m.Source)) { $need = 0 }
        if ($m.Optional) {
            if (($m.Key -eq 'vision' -and $SkipVision) -or ($m.Key -eq 'code' -and $SkipCoder)) { Write-LaiLog INFO "Skipping $($m.Display) (switch, or not installed before; add it with -Skip$(if ($m.Key -eq 'vision') { 'Vision' } else { 'Coder' }):`$false)"; continue }
            if ($tooBigForGpu -contains $m.Key) { Write-LaiLog WARN "Skipping $($m.Display): about $($m.DownloadGB) GB of weights cannot load fully on this card's $($gpu.TotalMiB) MiB of VRAM (nothing downloaded)."; continue }
            if ($need -gt 0 -and $need -gt $budget) { Write-LaiLog WARN "Skipping $($m.Display): needs $need GB, only $([Math]::Round($budget,1)) GB to spare on $target"; continue }
        } elseif ($need -gt 0 -and $need -gt $budget) {
            throw "Not enough disk space on ${target}: $($m.Display) needs $need GB plus a 15 GB margin; $freeGB GB free. Free space or pass -ModelDir <path on a bigger drive>."
        }
        $budget -= $need
        $selected += $m.Key
    }
    $State.flags['selectedModels'] = $selected
    Write-LaiLog OK "Models: $($selected -join ', ') -> $target ($freeGB GB free)"
    # The render guard's CPU mode loads the whole model into RAM (Ollama turns mmap off for num_gpu 0):
    # on a PC with little RAM such a chat pages to disk and slows the render it is meant to protect.
    if ($RenderGuard -eq 'cpu') {
        $ramShort = @($catalogAll.Models | Where-Object { $selected -contains $_.Key -and -not (Test-LaiCpuFallbackFits -DownloadGB $_.DownloadGB -RamGB $ramGB) } | ForEach-Object { $_.Display })
        if ($ramShort.Count) {
            Write-LaiLog WARN ("This PC has $ramGB GB of RAM. While ComfyUI renders, the render guard runs chats on the CPU, and $($ramShort -join ', ') need(s) about its download size plus 12 GB of RAM for that: such a chat pages to disk, crawls and slows the render. Wait for renders to finish before chatting with them; the rest of the time they run on the GPU as usual.")
        }
    }
    # Docker Desktop's WSL disk lives under %LOCALAPPDATA% (the profile's drive), not necessarily C:.
    $dockerDataPath = $env:SystemDrive + '\'; if ($env:LOCALAPPDATA) { $dockerDataPath = $env:LOCALAPPDATA }
    if ((Get-FreeGB $dockerDataPath) -lt 15) { Write-LaiLog WARN "Less than 15 GB free on $(Get-DriveOf $dockerDataPath); Docker images and WSL need about 10 GB there." }

    # Keep a stable copy of the scripts for scheduled tasks and the resume task.
    if ($SourceRoot.TrimEnd('\') -ne $P.Scripts.TrimEnd('\')) {
        if (-not (Test-Path -LiteralPath $P.Scripts)) { New-Item -ItemType Directory -Force -Path $P.Scripts | Out-Null }
        foreach ($item in $ToolkitItems) {
            $src = Join-Path $SourceRoot $item
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $P.Scripts -Recurse -Force }
        }
        Write-LaiLog OK "Scripts copied to $($P.Scripts)"
    }
    # Downloaded files carry the browser's "from the internet" mark; with it, typing a script path
    # in PowerShell is refused even under RemoteSigned. Shortcuts and tasks use -Bypass anyway.
    try { Get-ChildItem -LiteralPath $P.Scripts -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction Stop }
    catch { Write-Verbose "Unblock-File skipped: $($_.Exception.Message)" }
    # Windows' default policy (Restricted) refuses every typed .ps1. RemoteSigned still blocks
    # unsigned scripts that come from the internet, and is the Windows Server default.
    if ($env:OS -eq 'Windows_NT') {
        try { Write-LaiLog OK ('PowerShell: ' + (Set-LaiScriptPolicy)) }
        catch { Write-LaiLog WARN "Could not change the PowerShell execution policy ($($_.Exception.Message)); use the Start-menu shortcuts or 'powershell -ExecutionPolicy Bypass -File <script>'." }
    }
    foreach ($d in @('Projects', 'Scratch', 'Downloads', 'Generated')) {
        $w = Join-Path $P.Workspace $d
        if (-not (Test-Path -LiteralPath $w)) { New-Item -ItemType Directory -Force -Path $w | Out-Null }
    }
    # The whole AI folder belongs to this user (folders under C:\ otherwise let every account change
    # them): backups hold every chat, logs the install transcript. The scripts that the backup and
    # resume tasks run as administrator are read-only even for the user. Skipped when the AI root is
    # a drive root (not ours to lock down).
    if ([System.IO.Path]::GetPathRoot($P.Root).TrimEnd('\', '/') -ne $P.Root.TrimEnd('\', '/')) {
        Protect-Path -Path $P.Root
        if (Test-Path -LiteralPath $P.Scripts) { Protect-Path -Path $P.Scripts -UserAccess ReadOnly }
    }
    Protect-Path -Path $P.Secrets
}
$Catalog = Get-LaiCatalog -Path $CatalogPath -IncludeKeys @($State.flags['selectedModels'])
#endregion

#region 2. Ollama ---------------------------------------------------------------------------
Invoke-Stage 'Ollama' {
    $ollamaExe = Join-Path $OllamaDir 'ollama.exe'
    if (-not (Test-Path -LiteralPath $ollamaExe)) {
        # Found again afterwards: winget or the vendor installer may reuse an earlier custom folder.
        Install-App -WingetId 'Ollama.Ollama' -Publisher 'Ollama' -Url 'https://ollama.com/download/OllamaSetup.exe' -FileName 'OllamaSetup.exe' `
            -InstallerArgs @('/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES') -IsInstalled { $d = Find-LaiOllamaDir; $d -and (Test-Path -LiteralPath (Join-Path $d 'ollama.exe')) }
        $script:OllamaDir = Find-LaiOllamaDir -OrDefault
    }
    Add-SessionPath $OllamaDir

    $settings = [ordered]@{
        OLLAMA_FLASH_ATTENTION = '1'
        OLLAMA_KV_CACHE_TYPE   = $KvCacheType
        OLLAMA_NUM_PARALLEL    = '1'                                  # KV cache is allocated per parallel slot
        OLLAMA_MAX_LOADED_MODELS = '1'                                # each preset is tuned for an otherwise empty card
        OLLAMA_GPU_OVERHEAD    = [string]([int64]$GpuOverheadMiB * 1MB)
        OLLAMA_KEEP_ALIVE      = $KeepAlive
        OLLAMA_NO_CLOUD        = '1'                                  # private: no cloud models/web search
        OLLAMA_IGPU_ENABLE     = '0'                                  # never schedule on the Ryzen iGPU
    }
    $defaultModels = Join-Path $env:USERPROFILE '.ollama\models'
    if ($State.flags['modelDir'] -and ($State.flags['modelDir'].TrimEnd('\') -ne $defaultModels.TrimEnd('\'))) {
        $settings['OLLAMA_MODELS'] = $State.flags['modelDir']
    }
    if ($State.flags['ollamaLanFallback']) { $settings['OLLAMA_HOST'] = '0.0.0.0:11434' }
    # Every variable Uninstall -ResetOllamaSettings / -RemoveModels touches, also the two set only
    # sometimes (OLLAMA_HOST by the Stack stage's LAN fallback, OLLAMA_MODELS by a later -ModelDir).
    Save-PrevUserEnv -Names (@($settings.Keys) + @('OLLAMA_HOST', 'OLLAMA_MODELS') | Select-Object -Unique)
    $changed = $false
    foreach ($k in $settings.Keys) { if (Set-UserEnv -Name $k -Value $settings[$k]) { $changed = $true; Write-LaiLog INFO "set $k=$($settings[$k])" } }

    $up = $false
    try { Get-LaiOllamaVersion -BaseUrl $OllamaUrl | Out-Null; $up = $true } catch { Write-Verbose 'Ollama API not up' }
    if ($changed -or -not $up) {
        Write-LaiLog INFO 'Restarting Ollama so it picks up the settings'
        Get-Process -Name 'ollama app', 'ollama', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Start-OllamaAsUser
        try { Wait-LaiHttp -Uri "$OllamaUrl/api/version" -TimeoutSec 60 | Out-Null }
        catch {
            Write-LaiLog WARN 'Ollama did not start via Explorer; starting it directly.'
            Start-LaiOllamaApp -Path (Join-Path $OllamaDir 'ollama app.exe')
            Wait-LaiHttp -Uri "$OllamaUrl/api/version" -TimeoutSec 90 | Out-Null
        }
    }
    $ver = Get-LaiOllamaVersion -BaseUrl $OllamaUrl
    Write-LaiLog OK "Ollama $ver on $OllamaUrl"

    $log = Join-Path $env:LOCALAPPDATA 'Ollama\server.log'
    if (Test-Path -LiteralPath $log) {
        $cfgLine = Select-String -LiteralPath $log -Pattern 'msg="server config"' -Encoding UTF8 | Select-Object -Last 1
        if ($cfgLine) {
            # Parsed, not searched for: a key a newer Ollama no longer logs is 'unknown' (a restart
            # cannot change that), only a key logged with another value means the settings were missed.
            $chk = Test-LaiOllamaServerSettings -Line $cfgLine.Line -KvCacheType $KvCacheType
            if ($chk.Status -eq 'wrong') {
                # Explorer may not have refreshed its environment yet; this process has the new values.
                Write-LaiLog WARN "Ollama did not pick up the new settings ($($chk.Wrong -join ', ')); restarting it from this session."
                Get-Process -Name 'ollama app', 'ollama', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
                Start-LaiOllamaApp -Path (Join-Path $OllamaDir 'ollama app.exe')
                Wait-LaiHttp -Uri "$OllamaUrl/api/version" -TimeoutSec 90 | Out-Null
                Start-Sleep -Seconds 2
                $cfgLine = Select-String -LiteralPath $log -Pattern 'msg="server config"' -Encoding UTF8 | Select-Object -Last 1
                $line2 = ''; if ($cfgLine) { $line2 = $cfgLine.Line }
                $chk = Test-LaiOllamaServerSettings -Line $line2 -KvCacheType $KvCacheType
            }
            if ($chk.Status -eq 'ok') { Write-LaiLog OK "Server running with flash attention + $KvCacheType KV cache" }
            elseif ($chk.Status -eq 'unknown') { Write-LaiLog INFO "This Ollama no longer reports $($chk.Missing -join ', ') in server.log; the context tuning below checks the real fit and speed instead." }
            else { Write-LaiLog WARN "Ollama server log still shows $($chk.Wrong -join ', '); sign out and in again, then re-run with -Retune." }
        }
        $gpuLine = Select-String -LiteralPath $log -Pattern 'inference compute' -Encoding UTF8 | Select-Object -Last 1
        if ($gpuLine) { Write-LaiLog INFO ($gpuLine.Line -replace '^.*msg="inference compute"\s*', 'inference compute: ') }
    }

    # The Ollama app's own Settings win over the variables set above (it starts 'ollama serve' with
    # them): Model location sends every download to a folder other than the one planned and checked
    # for space, and 'Expose Ollama to the network' opens Ollama to the LAN.
    $live = Get-OllamaLiveConfig
    $missing = @()
    if ($live -and $live['Models'] -and -not (Test-LaiSamePath $live['Models'] $State.flags['modelDir'])) {
        $missing = @($Catalog.Models | Where-Object { -not (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $_.Source) })
    }
    # Only when a download would go to the wrong folder (every model present: a warning below, Ollama
    # keeps running). As the signed-in user first, so Ollama does not run with admin rights; from this
    # session only if that still shows the old folder (Explorer may hand out the old OLLAMA_MODELS).
    foreach ($how in @('user', 'session')) {
        if (-not $missing.Count -or -not $live -or (Test-LaiSamePath $live['Models'] $State.flags['modelDir'])) { break }
        Write-LaiLog INFO "Ollama uses $($live['Models']) for models; restarting it to apply $($State.flags['modelDir'])"
        Get-Process -Name 'ollama app', 'ollama', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        # Explorer cannot pass 'hidden', so the user start may show the Ollama window once (the user is
        # at the installer anyway); the direct start hides it.
        if ($how -eq 'user') { Start-AsUser (Join-Path $OllamaDir 'ollama app.exe') }   # lai-ok: hidden
        else { Start-LaiOllamaApp -Path (Join-Path $OllamaDir 'ollama app.exe') }
        try { Wait-LaiHttp -Uri "$OllamaUrl/api/version" -TimeoutSec 90 | Out-Null }
        catch {
            if ($how -eq 'session') { throw }
            Write-LaiLog WARN 'Ollama did not start via Explorer; starting it directly.'
            continue
        }
        Start-Sleep -Seconds 2
        $live = Get-OllamaLiveConfig
    }
    if ($live -and -not $live['HostIsLoopback'] -and -not $State.flags['ollamaLanFallback']) {
        Write-LaiLog WARN "Ollama listens on $($live['Host']), so other devices on your network can use it; the installer did not set that. Turn off 'Expose Ollama to the network' in the Ollama app's Settings (or remove an OLLAMA_HOST variable you set), then quit and restart Ollama from the tray."
    }
    if ($live -and $live['Models'] -and -not (Test-LaiSamePath $live['Models'] $State.flags['modelDir'])) {
        $why = "Ollama keeps its models in $($live['Models']), not in $($State.flags['modelDir']): the Ollama app's own Settings > Model location overrides the OLLAMA_MODELS variable."
        if ($missing.Count) {
            throw "$why Nothing was downloaded. Open the Ollama app > Settings and set Model location to $($State.flags['modelDir']) (or re-run the installer with -ModelDir '$($live['Models'])'), quit Ollama from the tray, then run the installer again."
        }
        Write-LaiLog WARN "$why Every model is already there, so nothing changes now. Set Model location in the Ollama app (or re-run the installer with -ModelDir '$($live['Models'])') so the disk checks and the health watch look at the right drive."
    }
}
#endregion

#region 3. Models (guide Parts 3-4: pull, run, verify 100% GPU) ----------------------------
Invoke-Stage 'Models' {
    # The ollama CLI is a client of the local server; never let it target 0.0.0.0 (LAN fallback mode).
    $env:OLLAMA_HOST = '127.0.0.1:11434'
    $droppedTrials = @()
    $gpuReady = $false
    foreach ($m in ($Catalog.Models | Sort-Object { $_.Optional }, { $_.DownloadGB })) {
      try {
        if (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $m.Source) {
            # Installed and already proven on 100% GPU by an earlier run: no 8K checkpoint load again
            # (it costs a 9-20 GB load per model and waits on a busy GPU). -Retune checks again.
            $t = $null; if ($State.tuning.ContainsKey($m.Key)) { $t = $State.tuning[$m.Key] }
            # Same content (digest) too: Update-Models may have pulled a re-published tag.
            if (-not $Retune -and $t -and $t['Source'] -eq $m.Source -and ([int]$t['GpuPercent'] -ge 100 -or $AllowCpu) -and
                (-not $t['Digest'] -or $t['Digest'] -eq (Get-LaiOllamaDigest -BaseUrl $OllamaUrl -Name $m.Source))) {
                Write-LaiLog OK "$($m.Source) already installed and checked"
                continue
            }
            Write-LaiLog OK "$($m.Source) already installed"
        } else {
            $free = Get-FreeGB $State.flags['modelDir']
            if ($free -lt ($m.DownloadGB + 5)) { throw "Only $free GB free for $($m.Source) (~$($m.DownloadGB) GB)." }
            Write-LaiLog STEP "Downloading $($m.Source) (~$($m.DownloadGB) GB)"
            Invoke-LaiOllamaPull -BaseUrl $OllamaUrl -Name $m.Source
            Write-LaiLog OK "$($m.Source) downloaded"
        }
        # Checkpoint (guide Steps 10-12, 14): it must load entirely on the RTX 3090 at a modest context.
        Stop-LaiOllamaModels -BaseUrl $OllamaUrl
        # Once, and only when something is loaded (Ollama's own models are unloaded first, so they don't count as busy).
        if (-not $gpuReady) { Wait-LaiGpuIdle -MaxUsedMiB $MaxBusyVramMiB -TimeoutSec ($GpuWaitMinutes * 60) | Out-Null; $gpuReady = $true }
        $load = Invoke-LaiOllamaLoad -BaseUrl $OllamaUrl -Name $m.Source -NumCtx 8192 -KeepAlive '1m'
        $gpu = Get-LaiGpuInfo
        Write-LaiLog INFO ("  loaded at 8K context: {0}% GPU, {1} GiB, VRAM used {2}/{3} MiB" -f $load.GpuPercent, $load.SizeGiB, $gpu.UsedMiB, $gpu.TotalMiB)
        if ($load.GpuPercent -lt 100 -and -not $AllowCpu) {
            throw ("$($m.Source) is only $($load.GpuPercent)% on the GPU even at 8K context. Stop here (the guide's checkpoint): " +
                'close other GPU apps, update the NVIDIA driver, quit/restart Ollama from the tray, then re-run.')
        }
        $answer = Invoke-LaiApi -Method POST -Uri "$OllamaUrl/api/generate" -TimeoutSec 600 -Body @{
            model = $m.Source; prompt = 'In one sentence: how does a turbocharger work?'; stream = $false; think = $false; options = @{ num_predict = 60; num_ctx = 8192 }
        }
        if (-not $answer.response) { throw "$($m.Source) loaded but returned an empty answer." }
        Write-LaiLog OK "  $($m.Display) answers on 100% GPU: $(([string]$answer.response).Trim() -replace '\s+', ' ')"
      } catch {
        # A trial must never stop the install: the tag may be gone, this Ollama may not know the
        # architecture yet, or it may not fit. The measured models still fail loudly.
        if (-not $m.Trial) { throw }
        $why = Get-LaiHttpErrorText $_
        if (-not $why) { $why = $_.Exception.Message }
        Write-LaiLog WARN "Trial $($m.Display) ($($m.Source)) skipped: $why"
        $droppedTrials += $m.Key
        try { Stop-LaiOllamaModels -BaseUrl $OllamaUrl } catch { Write-Verbose 'unload failed' }
      }
    }
    if ($droppedTrials.Count -gt 0) {
        $State.flags['selectedModels'] = @($State.flags['selectedModels'] | Where-Object { $droppedTrials -notcontains $_ })
        Save-State
        $script:Catalog = Get-LaiCatalog -Path $CatalogPath -IncludeKeys @($State.flags['selectedModels'])
    }
    Stop-LaiOllamaModels -BaseUrl $OllamaUrl
}
#endregion

#region 4. Context tuning + tuned aliases (guide Parts 5, 10, 27 automated) ---------------
Invoke-Stage 'Tuning' {
    $gpu = Get-LaiGpuInfo
    $fingerprint = "driver=$($gpu.DriverVersion);kv=$KvCacheType;overhead=$GpuOverheadMiB;free=$MinFreeVramMiB"
    # Only when something is measured: unload, then wait for the GPU (a ComfyUI render may hold it).
    $beforeLoad = {
        Stop-LaiOllamaModels -BaseUrl $OllamaUrl
        Wait-LaiGpuIdle -MaxUsedMiB $MaxBusyVramMiB -TimeoutSec ($GpuWaitMinutes * 60) | Out-Null
    }
    $results = Invoke-LaiModelSetup -BaseUrl $OllamaUrl -Models $Catalog.Models -Candidates $Catalog.ContextCandidates `
        -SystemPrompt $SystemPrompt -Previous $State.tuning -Fingerprint $fingerprint -MinFreeMiB $MinFreeVramMiB -Retune:$Retune -AllowCpu:$AllowCpu `
        -BeforeFirstLoad $beforeLoad
    foreach ($k in $results.Keys) { $State.tuning[$k] = $results[$k] }
}
#endregion

#region 5. WSL2 (guide Part 6) --------------------------------------------------------------
Invoke-Stage 'WSL' {
    $env:WSL_UTF8 = '1'   # wsl.exe prints UTF-16 otherwise, which breaks parsing
    $needReboot = $false
    foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $feature
        if ($f.State -ne 'Enabled') {
            Write-LaiLog INFO "Enabling Windows feature $feature"
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
            if ($r.RestartNeeded) { $needReboot = $true }
        }
    }
    if ($needReboot) { Request-Reboot -Reason 'Windows features for WSL2 were enabled' }

    $v = Invoke-Native -File 'wsl.exe' -Arguments @('--version') -Capture -AllowFail
    if ($v.ExitCode -ne 0) {
        Write-LaiLog INFO 'Installing the current WSL (no Linux distribution needed for Docker)'
        $i = Invoke-Native -File 'wsl.exe' -Arguments @('--install', '--no-distribution') -Capture -AllowFail
        $v = Invoke-Native -File 'wsl.exe' -Arguments @('--version') -Capture -AllowFail
        if ($v.ExitCode -ne 0) {
            if ($State.flags['wslRebooted']) { throw "WSL is still not working after a reboot. Output: $($i.Text)" }
            $State.flags['wslRebooted'] = $true
            Request-Reboot -Reason 'WSL was installed'
        }
    }
    Invoke-Native -File 'wsl.exe' -Arguments @('--update') -Capture -AllowFail | Out-Null
    Invoke-Native -File 'wsl.exe' -Arguments @('--set-default-version', '2') -Capture -AllowFail | Out-Null
    $v = Invoke-Native -File 'wsl.exe' -Arguments @('--version') -Capture
    $wslVer = [regex]::Match($v.Text, '\d+\.\d+\.\d+(\.\d+)?').Value
    if ($wslVer -and ([version]$wslVer -lt [version]'2.1.5')) { throw "WSL $wslVer is older than 2.1.5 (Docker minimum) and 'wsl --update' did not fix it." }
    Write-LaiLog OK "WSL $wslVer"

    # Cap the WSL VM so Docker's page cache cannot crowd out RAM that Ollama/ComfyUI need (only if you
    # have no .wslconfig yet). WSL's own default is half the RAM, so 16 GB is a cap only above 32 GB;
    # on a 16 or 24 GB PC it would raise the limit, and the default is left alone there.
    $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
    if (-not (Test-Path -LiteralPath $wslConfig)) {
        $ramGB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $capGB = Get-LaiWslMemoryCapGB -TotalGB $ramGB
        $content = ''
        if ($capGB) { $content = "[wsl2]`r`nmemory=${capGB}GB`r`n`r`n" }
        $content += "[experimental]`r`nautoMemoryReclaim=gradual`r`n"
        [System.IO.File]::WriteAllText($wslConfig, $content, (New-Object System.Text.UTF8Encoding($false)))
        if ($capGB) { Write-LaiLog OK "Created $wslConfig (WSL memory cap $capGB GB, gradual reclaim)" }
        else { Write-LaiLog OK "Created $wslConfig (gradual reclaim; WSL keeps its default limit of half the RAM, $([Math]::Floor($ramGB / 2)) GB)" }
    }
}
#endregion

#region 6. Docker Desktop (guide Part 7) ----------------------------------------------------
Invoke-Stage 'Docker' {
    if (-not (Test-Path -LiteralPath $DockerExe)) {
        Install-App -WingetId 'Docker.DockerDesktop' -Publisher 'Docker' -Url 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' `
            -FileName 'DockerDesktopInstaller.exe' -InstallerArgs @('install', '--quiet', '--accept-license', '--backend=wsl-2', '--always-run-service') `
            -IsInstalled { [bool](Find-LaiDockerDesktopExe) }
        $State.flags['dockerInstalledAt'] = (Get-Date).ToString('s')
        Save-State
        $script:DockerExe = Find-LaiDockerDesktopExe -OrDefault
        $script:DockerBin = Join-Path (Split-Path -Parent $DockerExe) 'resources\bin'
    }
    Add-SessionPath $DockerBin

    if (Get-LocalGroup -Name 'docker-users' -ErrorAction SilentlyContinue) {
        # Add directly instead of listing members first: Get-LocalGroupMember throws on groups that
        # contain orphaned or Azure AD SIDs.
        try {
            Add-LocalGroupMember -Group 'docker-users' -Member $CurrentUser -ErrorAction Stop
            Write-LaiLog OK "Added $CurrentUser to docker-users"
            $State.flags['dockerGroupAdded'] = $true
        } catch {
            if ($_.FullyQualifiedErrorId -notlike 'MemberExists*') { Write-LaiLog WARN "Could not add $CurrentUser to docker-users: $($_.Exception.Message)" }
        }
    }

    # Start Docker Desktop at sign-in so the restart:always containers come back after reboots.
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Docker Desktop' -Value ('"{0}"' -f $DockerExe)
    # Docker Desktop manages that entry itself from its own setting (off by default) and may drop it
    # when its settings are saved; its settings file is not ours to edit while it runs, so say it.
    Write-LaiLog INFO "Docker Desktop starts at sign-in. If you change Docker Desktop's settings later, also tick 'Start Docker Desktop when you sign in' (Settings > General), or it may stop starting by itself."

    if (-not (Test-DockerEngine)) {
        Write-LaiLog INFO 'Starting Docker Desktop (first start initialises its WSL VM; this can take a few minutes)'
        Start-AsUser $DockerExe
        $deadline = (Get-Date).AddMinutes(6)
        while ((Get-Date) -lt $deadline -and -not (Test-DockerEngine)) { Start-Sleep -Seconds 5 }
    }
    if (-not (Test-DockerEngine)) {
        if (($State.flags['rebootPending'] -or $State.flags['dockerGroupAdded']) -and -not $State.flags['dockerRebooted']) {
            $State.flags['dockerRebooted'] = $true
            $State.flags['rebootPending'] = $false
            Request-Reboot -Reason 'Docker Desktop was installed (group membership and services need a fresh sign-in)'
        }
        $cpuMaker = ''
        try { $cpuMaker = [string](Get-CimInstance Win32_Processor | Select-Object -First 1).Manufacturer } catch { Write-Verbose 'CPU maker unknown' }
        throw ('Docker engine did not start. Open Docker Desktop once: accept the agreement if asked, wait for "Engine running", ' +
            'then re-run. If it reports virtualization errors, enable ' + (Get-LaiVirtualizationHint -Manufacturer $cpuMaker) + '.')
    }
    $server = (Invoke-Native -File 'docker' -Arguments @('version', '--format', '{{.Server.Version}}') -Capture).Text
    Write-LaiLog OK "Docker engine $server"
    $hello = Invoke-Native -File 'docker' -Arguments @('run', '--rm', 'hello-world') -Capture -AllowFail
    if ($hello.Text -notmatch 'Hello from Docker!') { throw "docker run hello-world failed: $($hello.Text)" }
    Write-LaiLog OK 'docker run hello-world: Hello from Docker!'
}
#endregion

#region 7. Open WebUI + SearXNG (guide Part 8, 9, 18) ---------------------------------------
Invoke-Stage 'Stack' {
    $hold = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($hold) { throw "Open WebUI is kept stopped after a failed restore ($($hold['Reason'])); starting it could run on damaged data. Recover first: $($hold['Recover'])" }
    if (-not (Test-Path -LiteralPath $P.Stack)) { New-Item -ItemType Directory -Force -Path $P.Stack | Out-Null }
    $searxDir = Join-Path $P.Stack 'searxng'
    if (-not (Test-Path -LiteralPath $searxDir)) { New-Item -ItemType Directory -Force -Path $searxDir | Out-Null }
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'stack\docker-compose.yml') -Destination $P.Stack -Force
    $guardDir = Join-Path $P.Stack 'render-guard'
    if (-not (Test-Path -LiteralPath $guardDir)) { New-Item -ItemType Directory -Force -Path $guardDir | Out-Null }
    # compose up only recreates a container whose configuration changed; a new render_guard.py in
    # the mounted folder would otherwise keep running the old code until the next reboot.
    # The hash of the code last *started* is kept in state, so a run that fails before the restart
    # (image pull, compose up) still restarts the guard on the next run. An install from before this
    # was recorded (a guard file exists, no hash) cannot tell what runs: restart it once.
    $guardFile = Join-Path $guardDir 'render_guard.py'
    $guardRunning = [string]$State.flags['guardHash']
    if (-not $guardRunning -and (Test-Path -LiteralPath $guardFile)) { $guardRunning = 'unknown' }
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'stack\render-guard\render_guard.py') -Destination $guardDir -Force
    $guardNow = (Get-FileHash -LiteralPath $guardFile -Algorithm SHA256).Hash
    $guardChanged = $guardRunning -and $guardRunning -ne $guardNow
    $searxSettings = Join-Path $searxDir 'settings.yml'
    if (-not (Test-Path -LiteralPath $searxSettings)) {
        $tpl = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $SourceRoot 'stack\searxng\settings.yml') -Raw
        [System.IO.File]::WriteAllText($searxSettings, $tpl.Replace('__SEARXNG_SECRET__', (New-LaiSecret)), (New-Object System.Text.UTF8Encoding($false)))
    }

    # Containers from another setup with the names this stack uses (Open WebUI's own SearXNG guide
    # also calls its container 'searxng'): compose would stop on the clash only after the old Open
    # WebUI below was stopped and renamed, and a re-run would no longer find that one. Checked first.
    $clash = @()
    foreach ($cn in @('searxng', 'render-guard')) {
        $r = Invoke-Native -File 'docker' -Arguments @('ps', '-a', '--filter', "name=^/$cn`$", '--format', '{{.Names}}|{{.Label `com.docker.compose.project`}}') -Capture -AllowFail
        if ($r.ExitCode -ne 0) { throw "docker ps failed: $($r.Text)" }
        $clash += @($r.Output | Where-Object { $_ -and $_ -notmatch '\|localai$' } | ForEach-Object { ($_ -split '\|')[0] })
    }
    if ($clash.Count) {
        $first = $clash[0]
        throw ("A container named {0} from another setup is in the way: this stack's own containers need the names searxng and render-guard. No container was changed. Keep it under another name with 'docker rename {1} {1}-old' (stop it first if it uses port {2} or {3}), or remove it if you no longer need it, then run the installer again." -f ($clash -join ', '), $first, $script:WebUIPortEffective, $script:SearxngPortEffective)
    }

    # A container from the guide's manual "docker run" would clash with the compose-managed one.
    # Go raw-string backticks, not double quotes: Windows PowerShell 5.1 strips inner double quotes
    # from native arguments, and the broken template's error text looked like a legacy container.
    $legacy = Invoke-Native -File 'docker' -Arguments @('ps', '-a', '--filter', 'name=^/open-webui$', '--format', '{{.ID}}|{{.Label `com.docker.compose.project`}}') -Capture -AllowFail
    if ($legacy.ExitCode -ne 0) { throw "docker ps failed: $($legacy.Text)" }
    $secretFile = Join-Path $P.Secrets 'openwebui-secret.txt'
    if ($legacy.Text -and $legacy.Text -notmatch '\|localai$') {
        Write-LaiLog WARN 'Found an existing open-webui container from a manual install; migrating its data into the managed stack.'
        $envDump = Invoke-Native -File 'docker' -Arguments @('inspect', '--format', '{{range .Config.Env}}{{println .}}{{end}}', 'open-webui') -Capture -AllowFail
        $oldKey = ($envDump.Output | Where-Object { $_ -like 'WEBUI_SECRET_KEY=*' } | Select-Object -First 1)
        if ($oldKey -and -not (Test-Path -LiteralPath $secretFile)) { Set-Content -LiteralPath $secretFile -Value $oldKey.Substring(17) -NoNewline }
        # Where did that container keep /app/backend/data? (No double quotes in the template: PS 5.1 mangles them for native args.)
        $mounts = Invoke-Native -File 'docker' -Arguments @('inspect', '--format', '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}{{println}}{{end}}', 'open-webui') -Capture -AllowFail
        $data = $mounts.Output | Where-Object { $_ -like '*|/app/backend/data' } | Select-Object -First 1
        $managedExists = (Invoke-Native -File 'docker' -Arguments @('volume', 'inspect', 'open-webui') -Capture -AllowFail).ExitCode -eq 0
        $from = $null
        if ($data) {
            $f = $data.Split('|')
            if ($f[0] -eq 'volume' -and $f[1] -eq 'open-webui') {
                & (Join-Path $SourceRoot 'Backup-OpenWebUI.ps1') -AIRoot $AIRoot -NoStop -Tag 'pre-compose'
            } elseif ($f[0] -eq 'volume') {
                & (Join-Path $SourceRoot 'Backup-OpenWebUI.ps1') -AIRoot $AIRoot -NoStop -Tag 'pre-compose' -Volume $f[1]
                $from = "$($f[1]):/from:ro"
            } elseif ($f[0] -eq 'bind') {
                $from = "$($f[2]):/from:ro"
            }
        } else {
            Write-LaiLog WARN 'The old container kept its data inside the container itself (no volume); it is kept (stopped, renamed) so nothing is lost.'
        }
        if ($from -and -not $managedExists) {
            Invoke-Native -File 'docker' -Arguments @('volume', 'create', 'open-webui') -Capture | Out-Null
            # Copy only if the old data really is there: a mis-decoded or vanished bind-mount path makes
            # 'docker run -v' create an EMPTY folder, and the copy would "succeed" with nothing in it.
            $copy = Invoke-Native -File 'docker' -Arguments @('run', '--rm', '-v', $from, '-v', 'open-webui:/to', 'alpine:3.20', 'sh', '-c', 'test -f /from/webui.db || exit 3; cp -a /from/. /to/') -Capture -AllowFail
            if ($copy.ExitCode -eq 3) {
                Invoke-Native -File 'docker' -Arguments @('volume', 'rm', 'open-webui') -Capture -AllowFail | Out-Null
                throw "The old Open WebUI data folder ($($from -replace ':/from:ro$', '')) has no webui.db, so nothing was copied and the old container was left as it is. Check that folder (or remove the old container if it held no data), then run the installer again."
            }
            if ($copy.ExitCode -ne 0) { throw "Copying the old Open WebUI data failed: $($copy.Text)" }
            Write-LaiLog OK "Copied the old Open WebUI data (from $($from -replace ':/from:ro$', '')) into the open-webui volume"
        } elseif ($from) {
            Write-LaiLog WARN "Both the old data ($from) and an open-webui volume exist; leaving both untouched: Open WebUI keeps using the open-webui volume, and nothing of the old data is deleted."
        }
        # Keep the old container (stopped, renamed) instead of deleting it.
        # (restart policy off first, or the guide's --restart always would bring it back after a reboot)
        $legacyName = 'open-webui-legacy-' + (Get-Date -Format 'yyyyMMddHHmmss')
        Invoke-Native -File 'docker' -Arguments @('update', '--restart', 'no', 'open-webui') -Capture -AllowFail | Out-Null
        Invoke-Native -File 'docker' -Arguments @('stop', 'open-webui') -Capture -AllowFail | Out-Null
        Invoke-Native -File 'docker' -Arguments @('rename', 'open-webui', $legacyName) -Capture | Out-Null
        Write-LaiLog OK "Old container kept (stopped) as $legacyName; remove it with 'docker rm $legacyName' once you are happy."
    }

    # Secrets: reuse the guide's key file if present so existing sessions stay valid.
    $guideSecret = Join-Path $P.Root 'openwebui-secret.txt'
    if (-not (Test-Path -LiteralPath $secretFile)) {
        # Moved, not copied: the old file sits outside Secrets where other accounts could read it,
        # and that key signs Open WebUI logins.
        if (Test-Path -LiteralPath $guideSecret) { Move-Item -LiteralPath $guideSecret -Destination $secretFile }
        else { Set-Content -LiteralPath $secretFile -Value (New-LaiSecret) -NoNewline }
    }
    Protect-Path -Path $secretFile
    $cred = Get-AdminCredential
    if (-not $cred) {
        Save-AdminCredential -Email $AdminEmail -Password (New-LaiPassword)
        $cred = Get-AdminCredential
    }

    $script:WebUIPortEffective = Select-FreePort -Preferred $script:WebUIPortEffective
    $script:SearxngPortEffective = Select-FreePort -Preferred $script:SearxngPortEffective
    $State.flags['webuiPort'] = $script:WebUIPortEffective
    $State.flags['searxngPort'] = $script:SearxngPortEffective

    $envValues = @{
        OPEN_WEBUI_VERSION = $OpenWebUIVersion
        SEARXNG_VERSION    = $SearxngVersion
        WEBUI_PORT         = $script:WebUIPortEffective
        SEARXNG_PORT       = $script:SearxngPortEffective
        WEBUI_SECRET_KEY   = (Get-Content -Encoding UTF8 -LiteralPath $secretFile -Raw).Trim()
        WEBUI_ADMIN_EMAIL  = $cred.email
        WEBUI_ADMIN_PASSWORD = ''
        OLLAMA_BASE_URL    = 'http://render-guard:11434'
        RENDER_GUARD_MODE  = $RenderGuard
    }
    if (-not $State.flags['adminVerified']) { $envValues['WEBUI_ADMIN_PASSWORD'] = $cred.password }
    Write-StackEnv -Values $envValues

    Write-LaiLog INFO "Pulling images (Open WebUI $OpenWebUIVersion is several GB on first install)"
    # Pinned versions: an image already on disk is the right one, so re-runs need no registry
    # (Docker Hub rate-limits anonymous pulls). A floating tag (main, latest) is always re-pulled.
    $pullPolicy = Get-LaiPullPolicy -Tags @($OpenWebUIVersion, $SearxngVersion)
    Invoke-LaiRetry -What 'docker compose pull' -Attempts 3 -DelaySeconds 15 -Action { Invoke-Compose -Arguments @('pull', '--policy', $pullPolicy) | Out-Null } | Out-Null
    # Earlier versions on Windows PowerShell 5.1 mistook their own container for a manual install on
    # every re-run (a docker template with inner quotes) and renamed it to open-webui-legacy-<time>.
    # Those still carry this project's labels, so compose would see two open-webui containers. Their
    # data is in the open-webui volume; a real manual install's container has no such label and stays.
    $own = Invoke-Native -File 'docker' -Arguments @('ps', '-a', '--filter', 'label=com.docker.compose.project=localai', '--filter', 'label=com.docker.compose.service=open-webui', '--format', '{{.Names}}') -Capture -AllowFail
    foreach ($n in @($own.Output | Where-Object { $_ -and $_ -ne 'open-webui' })) {
        Invoke-Native -File 'docker' -Arguments @('rm', '-f', $n) -Capture -AllowFail | Out-Null
        Write-LaiLog OK "Removed $n (this installer's own earlier container, renamed by mistake; its data is in the open-webui volume)"
    }
    Invoke-ComposeUp -Arguments @('up', '-d', '--remove-orphans')
    $guardStarted = $true
    if ($guardChanged) {
        try { Invoke-Compose -Arguments @('restart', 'render-guard') | Out-Null; Write-LaiLog OK 'Render guard restarted with the updated code' }
        catch { $guardStarted = $false; Write-LaiLog WARN "Render guard still runs the old code until it restarts: $($_.Exception.Message)" }
    }
    if ($guardStarted) { $State.flags['guardHash'] = $guardNow; Save-State }
    $webui = "http://127.0.0.1:$($script:WebUIPortEffective)"
    Write-LaiLog INFO "Waiting for Open WebUI on $webui (first start runs database migrations)"
    Wait-LaiWebUI -BaseUrl $webui -TimeoutSec 600
    Write-LaiLog OK "Open WebUI is up on http://localhost:$($script:WebUIPortEffective)"

    # Can the container reach Ollama on the Windows host? (guide Part 9 / troubleshooting)
    $probe = "import urllib.request;print(urllib.request.urlopen('http://host.docker.internal:11434/api/version',timeout=5).read().decode())"
    $r = Invoke-Native -File 'docker' -Arguments @('exec', 'open-webui', 'python', '-c', $probe) -Capture -AllowFail
    $switched = $false
    if ($r.Text -notmatch '"version"') {
        Write-LaiLog WARN 'Open WebUI cannot reach Ollama on 127.0.0.1. Switching Ollama to listen on all interfaces with a firewall block for the LAN.'
        $State.flags['ollamaLanFallback'] = $true
        Save-State
        Set-UserEnv -Name 'OLLAMA_HOST' -Value '0.0.0.0:11434' | Out-Null
        $switched = $true
    }
    if ($State.flags['ollamaLanFallback']) {
        # Rebuilt on every run, so the rule follows WSL's subnet (picked again at boot) and installs
        # with the older adapter-only rule get this one.
        Set-OllamaBlockRule
        if ($switched) {
            Get-Process -Name 'ollama app', 'ollama', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Start-OllamaAsUser
            Wait-LaiHttp -Uri "$OllamaUrl/api/version" -TimeoutSec 90 | Out-Null
        }
        $r = Invoke-Native -File 'docker' -Arguments @('exec', 'open-webui', 'python', '-c', $probe) -Capture -AllowFail
        if ($r.Text -notmatch '"version"') {
            # Docker reaches the host from a subnet we did not detect: fall back to blocking the
            # physical adapters only (the LAN), and say what is not covered.
            Set-OllamaBlockRule -AdaptersOnly
            $r = Invoke-Native -File 'docker' -Arguments @('exec', 'open-webui', 'python', '-c', $probe) -Capture -AllowFail
        }
        if ($r.Text -notmatch '"version"') { throw "Open WebUI still cannot reach Ollama at host.docker.internal:11434. Output: $($r.Text)" }
    }
    Write-LaiLog OK 'Open WebUI container reaches Ollama at host.docker.internal:11434'

    # Same check through the render guard; fall back to the direct connection if it is broken.
    $script:WebUIOllamaUrl = 'http://render-guard:11434'
    $gProbe = "import urllib.request;print(urllib.request.urlopen('http://render-guard:11434/api/version',timeout=5).read().decode())"
    $r = $null
    for ($i = 0; $i -lt 10; $i++) {
        $r = Invoke-Native -File 'docker' -Arguments @('exec', 'open-webui', 'python', '-c', $gProbe) -Capture -AllowFail
        if ($r.Text -match '"version"') { break }
        Start-Sleep -Seconds 3
    }
    if ($r.Text -match '"version"') { Write-LaiLog OK "Render guard is up (mode: $RenderGuard)" }
    else {
        Write-LaiLog WARN "Render guard is not answering; Open WebUI will talk to Ollama directly. See: docker logs render-guard"
        $script:WebUIOllamaUrl = 'http://host.docker.internal:11434'
    }
    if ($env:LOCALAI_TEST_WEBUI_OLLAMA_URL) { $script:WebUIOllamaUrl = $env:LOCALAI_TEST_WEBUI_OLLAMA_URL }
}
$WebUIUrl = "http://127.0.0.1:$($script:WebUIPortEffective)"
#endregion

#region 8. Configure Open WebUI (guide Parts 10-18) -----------------------------------------
Invoke-Stage 'Configure' {
    try {
        $webVer = [string](Invoke-LaiApi -Uri "$WebUIUrl/api/version" -TimeoutSec 15).version
        if ((Get-LaiWebUICompat -Version $webVer) -eq 'newer') { Write-LaiLog WARN "Open WebUI $webVer is newer than the tested 0.11.4; its settings are applied as usual, but report any step that fails." }
    } catch { Write-Verbose 'Open WebUI version unknown' }
    $cred = Get-AdminCredential
    $token = $null
    if ((Invoke-LaiApi -Uri "$WebUIUrl/api/config").onboarding -eq $true) {
        # Empty database (fresh volume): admin accounts are only created at container start, so
        # put the bootstrap password back and recreate the container.
        Write-LaiLog INFO 'Open WebUI has no users yet; creating the admin account'
        $State.flags['adminVerified'] = $false
        $envPath = Join-Path $P.Stack '.env'
        $lines = Get-Content -Encoding UTF8 -LiteralPath $envPath | ForEach-Object { if ($_ -like 'WEBUI_ADMIN_PASSWORD=*') { "WEBUI_ADMIN_PASSWORD=$($cred.password)" } else { $_ } }
        [System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        Invoke-ComposeUp -Arguments @('up', '-d', '--force-recreate', 'open-webui')
        Wait-LaiWebUI -BaseUrl $WebUIUrl -TimeoutSec 300
    }
    # An interrupted Set-OpenWebUIPassword run may have left the live password only in the pending file.
    if ((Resolve-LaiPendingPassword -AIRoot $AIRoot -BaseUrl $WebUIUrl) -eq 'promoted') { $cred = Get-AdminCredential }
    try { $token = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $cred.email -Password $cred.password }
    catch {
        # Only a rejected login means "an admin account from before"; a timeout, server error or rate
        # limit must not turn into a prompt for credentials the user never had (and that blocks an
        # unattended resume after a reboot).
        $signInStatus = Get-LaiHttpStatus $_
        if (@(400, 401, 403) -notcontains $signInStatus -and $_.Exception.Message -notmatch 'not admin') {
            throw "Open WebUI did not accept the sign-in request ($(Get-LaiHttpErrorText $_)). Wait a minute, then run the installer again."
        }
        # Existing install whose admin was created by hand: ask once, then store it.
        Write-LaiLog WARN "Could not sign in as $($cred.email). This Open WebUI already has an admin account from before."
        $email = Read-Host 'Existing Open WebUI admin email'
        $sec = Read-Host 'Password' -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        $token = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $email -Password $plain
        Save-AdminCredential -Email $email -Password $plain
    }
    Write-LaiLog OK 'Signed in to Open WebUI as admin'

    if (-not $State.flags['adminVerified']) {
        # The bootstrap password has done its job; remove it from the container environment.
        $State.flags['adminVerified'] = $true
        Save-State
        $envPath = Join-Path $P.Stack '.env'
        $lines = Get-Content -Encoding UTF8 -LiteralPath $envPath | ForEach-Object { if ($_ -like 'WEBUI_ADMIN_PASSWORD=*') { 'WEBUI_ADMIN_PASSWORD=' } else { $_ } }
        [System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        Invoke-ComposeUp -Arguments @('up', '-d')
        Wait-LaiWebUI -BaseUrl $WebUIUrl -TimeoutSec 300
        $c2 = Get-AdminCredential
        $token = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $c2.email -Password $c2.password
        Write-LaiLog OK 'Bootstrap admin password removed from the container environment'
    }

    if (-not $script:WebUIOllamaUrl) { $script:WebUIOllamaUrl = 'http://render-guard:11434' }
    if (Set-LaiWebUIOllamaUrl -BaseUrl $WebUIUrl -Token $token -OllamaUrl $script:WebUIOllamaUrl) {
        Write-LaiLog OK "Open WebUI now reaches Ollama through $($script:WebUIOllamaUrl)"
    }

    # Trial presets that are no longer selected are hidden, not deleted (chats that used them stay readable).
    foreach ($tm in ((Get-LaiCatalog -Path $CatalogPath -IncludeTrials).Models | Where-Object { $_.Trial })) {
        if (@($State.flags['selectedModels']) -notcontains $tm.Key -and (Get-LaiWebUIModel -BaseUrl $WebUIUrl -Token $token -Id $tm.Preset)) {
            Hide-LaiWebUIModel -BaseUrl $WebUIUrl -Token $token -Id $tm.Preset | Out-Null
            Write-LaiLog INFO "Trial preset '$($tm.Display)' hidden (not selected)"
        }
    }

    # Optional settings that did not take come back as warnings instead of stopping the install
    # before the Backup stage; they are repeated in the report and at the end.
    $State.flags['configureWarnings'] = @(Invoke-LaiWebUISetup -BaseUrl $WebUIUrl -Token $token -Models $Catalog.Models -ModelResults $State.tuning `
        -SystemPrompt $SystemPrompt -DefaultPreset $Catalog.DefaultPreset -Collections $KnowledgeCollections)
}
#endregion

#region 9. Backups (guide Parts 22-23) -------------------------------------------------------
Invoke-Stage 'Backup' {
    # Merge into the existing file: other scripts keep their own keys there (e.g. ComfyUIPath).
    $config = Read-LaiState -Path $P.Config
    $managed = @{
        AIRoot = $AIRoot; WebUIPort = $script:WebUIPortEffective; SearxngPort = $script:SearxngPortEffective
        OpenWebUIVersion = $OpenWebUIVersion; SearxngVersion = $SearxngVersion; OllamaUrl = $OllamaUrl
        ModelDir = $State.flags['modelDir']; SelectedModels = @($State.flags['selectedModels'])
        BackupRetentionDays = $BackupRetentionDays; BackupMirror = $BackupMirror; KeepAlive = $KeepAlive
        MinFreeVramMiB = $MinFreeVramMiB; MaxBusyVramMiB = $MaxBusyVramMiB; RenderGuard = $RenderGuard
        WebUIOllamaUrl = $script:WebUIOllamaUrl; ToolkitVersion = $ToolkitVersion
    }
    foreach ($k in $managed.Keys) { $config[$k] = $managed[$k] }
    ConvertTo-Json -InputObject $config -Depth 5 | Set-Content -LiteralPath $P.Config -Encoding UTF8

    $backupScript = Join-Path $P.Scripts 'Backup-OpenWebUI.ps1'
    # -EngineWaitSec: a missed 03:30 run starts at sign-in, while Docker Desktop may need several minutes.
    # -WaitForChatsSec: that catch-up run may start while you chat; it waits for an answer being
    # written before stopping Open WebUI (1200 + 600 s still leave half of the 1 h time limit).
    # -DailyAt: the extra run at sign-in does nothing when the night's backup is already there.
    # No -WakeToRun: waking the PC every night (fans, possibly in a bedroom) is not worth it; a PC
    # asleep at 03:30 backs up shortly after it wakes instead.
    $backupExtra = '-EngineWaitSec 1200 -WaitForChatsSec 600'
    $dailyAt = ''
    try { $dailyAt = ([datetime]::Parse($BackupTime, [Globalization.CultureInfo]::InvariantCulture)).ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) } catch { Write-Verbose "BackupTime '$BackupTime' not read as a time of day" }
    if ($dailyAt) { $backupExtra += ' -DailyAt ' + $dailyAt }
    # Hidden for real (no Windows Terminal window that closing would kill mid-backup): see Get-LaiHiddenTaskLaunch.
    $launch = Get-LaiHiddenTaskLaunch -PsArgs (Get-LaiScriptCommandLine -ScriptPath $backupScript -AIRoot $AIRoot -Extra $backupExtra -Hidden) -Build ([Environment]::OSVersion.Version.Build)
    $action = New-ScheduledTaskAction -Execute $launch.Execute -Argument $launch.Argument
    # Also at sign-in: a task that needs you signed in may not run its missed start when you were
    # signed out at 03:30 (or signed in long after booting). Only with -DailyAt, which makes that
    # run a no-op on a normal day.
    $trigger = @(New-ScheduledTaskTrigger -Daily -At $BackupTime)
    if ($dailyAt) { $trigger += New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser }
    # Not elevated: docker-users membership, the volume mutex and C:\AI\Backups are all it needs, and
    # an elevated task would run code from C:\AI, which the user controls (see $ElevatedDir).
    # Non-elevated also sees mapped network drives, so a NAS mirror on a drive letter works.
    $principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $BackupTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-LaiLog OK "Scheduled task '$BackupTask' runs daily at $BackupTime; a night missed while the PC was off, asleep or signed out is caught up after it wakes or at the next sign-in"

    # Health watch every 15 minutes while signed in: restarts a stopped container or Ollama and
    # shows a notification only when something breaks or recovers. Runs non-elevated, with no
    # console window (Get-LaiHiddenTaskLaunch), so nothing flashes every 15 minutes.
    $watchArgs = Get-LaiScriptCommandLine -ScriptPath (Join-Path $P.Scripts 'Watch-LocalAI.ps1') -AIRoot $AIRoot -Hidden
    $watchLaunch = Get-LaiHiddenTaskLaunch -PsArgs $watchArgs -Build ([Environment]::OSVersion.Version.Build)
    $watchAction = New-ScheduledTaskAction -Execute $watchLaunch.Execute -Argument $watchLaunch.Argument
    $watchTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 15)
    $watchPrincipal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited
    $watchSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $WatchTask -Action $watchAction -Trigger $watchTrigger -Principal $watchPrincipal -Settings $watchSettings -Force | Out-Null
    Write-LaiLog OK "Scheduled task '$WatchTask' checks the stack every 15 minutes (log: $(Join-Path $P.Logs 'watch.log'))"

    # Start-menu folder with one-click shortcuts (all users: the installer runs elevated and may
    # be a different admin account than the person who signs in).
    if ($env:ProgramData) {
        $menu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Local AI'
        try {
            if (-not (Test-Path -LiteralPath $menu)) { New-Item -ItemType Directory -Force -Path $menu | Out-Null }
            $shell = $null
            try { $shell = New-Object -ComObject WScript.Shell } catch { Write-Verbose 'WScript.Shell unavailable' }
            $made = @()
            foreach ($sc in (Get-LaiShortcutSpecs -AIRoot $AIRoot -WebUIPort $script:WebUIPortEffective)) {
                if ($sc.TooLong) {
                    Write-LaiLog WARN "Start-menu shortcut '$($sc.Name)' skipped: the install folder path is too long for a shortcut (1024 characters). Run $($sc.Script) from $($P.Scripts) instead."
                } elseif ($sc.Kind -eq 'url') {
                    [System.IO.File]::WriteAllText((Join-Path $menu ($sc.Name + '.url')), "[InternetShortcut]`r`nURL=$($sc.Target)`r`n")
                    $made += $sc.Name
                } elseif ($shell) {
                    $lnk = $shell.CreateShortcut((Join-Path $menu ($sc.Name + '.lnk')))
                    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    $lnk.Arguments = $sc.Arguments
                    $lnk.WorkingDirectory = $P.Scripts
                    $lnk.Save()
                    $made += $sc.Name
                }
            }
            Write-LaiLog OK "Start menu folder 'Local AI': $($made -join '; ')"
        } catch { Write-LaiLog WARN "Could not create the Start-menu shortcuts: $($_.Exception.Message)" }
    }

    # This copy, not the one in AI\Scripts (a folder the user controls): the installer runs elevated.
    & (Join-Path $SourceRoot 'Backup-OpenWebUI.ps1') -AIRoot $AIRoot
    if ($LASTEXITCODE -ne 0) { throw 'The first backup failed; see the messages above.' }
}
#endregion

#region 10. Acceptance tests (guide Part 28 "finished V1") ---------------------------------
$testExit = 0
if (-not $SkipTests) {
    Invoke-Stage 'Verify' {
        # From the installer's own copy, never AI\Scripts: this runs elevated (approved for the
        # installer, not for whatever sits in AI\Scripts), and the user can swap folders inside C:\AI.
        & (Join-Path $SourceRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot
        $script:testExit = $LASTEXITCODE
    }
    $testExit = $script:testExit
}
#endregion

#region Report ---------------------------------------------------------------------------
Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue
if ($State.flags.ContainsKey('resumeFailures')) { [void]$State.flags.Remove('resumeFailures'); Save-State }
$rows = foreach ($m in ($Catalog.Models | Sort-Object { $_.Order })) {
    $t = $State.tuning[$m.Key]
    '| {0} | `{1}` | {2:N0} | {3}% | {4} |' -f $m.Display, $m.Source, $t['Context'], $t['GpuPercent'], $t['TokensPerSec']
}
$report = @(
    '# Local AI install report'
    ''
    "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') - $(if ($SkipTests) { 'acceptance tests skipped (-SkipTests)' } else { "acceptance test failures: $testExit" })"
    ''
    "- Open WebUI: http://localhost:$($script:WebUIPortEffective) (login in $($P.Secrets)\openwebui-admin.json)"
    "- Private search: http://localhost:$($script:SearxngPortEffective)"
    "- Ollama API: $OllamaUrl (models in $($State.flags['modelDir']))"
    "- Backups: $($P.Backups), daily at $BackupTime, kept $BackupRetentionDays days"
    "- Scripts: $($P.Scripts) (Test-LocalAI, Stop-/Start-LocalAI, Start-ComfyUI, Release-GPU, Backup-/Restore-OpenWebUI, Update-OpenWebUI, Update-Models, Set-OpenWebUIPassword, Watch-LocalAI, Enable-TailscaleAccess, Get-LocalAIDiagnostics, Uninstall-LocalAI); Start menu folder 'Local AI'"
    ''
    '| Preset | Model | Context (tokens) | On GPU | Tokens/s |'
    '|---|---|---:|---:|---:|'
) + $rows + @(
    ''
    'Context = largest value that kept the model 100% in VRAM with headroom, capped at the trained/configured maximum.'
    'Start ComfyUI with Start-ComfyUI.ps1 (or Start menu > Local AI); chats during a render run on the CPU (render guard). For Forge or games run Release-GPU.ps1 or Stop-LocalAI.ps1.'
)
$attention = @()
if ($State.flags.ContainsKey('configureWarnings')) { $attention = @($State.flags['configureWarnings'] | Where-Object { $_ }) }
# One line each, and '<' escaped: Markdown would hide '<query>' as a tag.
if ($attention.Count -gt 0) { $report += @('', '## Settings that need attention', '') + @($attention | ForEach-Object { '- ' + (($_ -replace '\s+', ' ') -replace '<', '\<') }) }
Set-Content -LiteralPath $P.Report -Value $report -Encoding UTF8
Write-Host ''
Write-LaiLog OK "Report: $($P.Report)"
$rows | ForEach-Object { Write-Host "  $_" }

$cred = Get-AdminCredential
Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
$script:TranscriptOn = $false
Write-Host ''
Write-Host "Open WebUI:  http://localhost:$($script:WebUIPortEffective)" -ForegroundColor Green
Write-Host "Login:       $($cred.email)" -ForegroundColor Green
Write-Host "Password:    $($cred.password)   (also in $($P.Secrets)\openwebui-admin.json)" -ForegroundColor Green
foreach ($a in $attention) { Write-Host "Needs attention: $a" -ForegroundColor Yellow }
Write-Host 'Open a NEW terminal to use the ollama command (windows opened before the install do not see the PATH change).' -ForegroundColor Gray
Start-AsUser "http://localhost:$($script:WebUIPortEffective)"
Stop-Install $testExit
#endregion

} catch {
    Write-LaiLog FAIL $_.Exception.Message
    if ($_.InvocationInfo) { Write-LaiLog INFO ("(technical detail for a bug report: " + $_.InvocationInfo.PositionMessage.Split("`n")[0] + ')') }
    Write-LaiLog FAIL "Fix the issue above and run the installer again (double-click $(Join-Path $P.Scripts 'Install-LocalAI.cmd') and click Yes); re-running is safe and reuses what is done (downloads, tuning). Full log: $($script:TranscriptPath)"
    if ($Resume -and $State -and $State.flags) {
        # The resume task starts the installer at every sign-in. A failure that a reboot does not fix
        # (virtualization off, a broken Docker) must not open an elevated window forever.
        $n = 1; if ($State.flags.ContainsKey('resumeFailures')) { $n = [int]$State.flags['resumeFailures'] + 1 }
        $State.flags['resumeFailures'] = $n
        if ($n -ge 2) {
            Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue
            Write-LaiLog WARN "This failed after sign-in twice in a row, so the installer no longer starts by itself. After fixing it, double-click $(Join-Path $P.Scripts 'Install-LocalAI.cmd') and click Yes."
        } else {
            Write-LaiLog WARN 'The installer tries once more at the next sign-in.'
        }
    }
    Save-State
    Stop-Install 1
}
