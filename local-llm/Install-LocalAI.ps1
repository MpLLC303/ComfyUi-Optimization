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
    reboots (60 s warning, cancel with "shutdown /a") and continues by itself after you sign in.

    The only prompts you should see: one UAC prompt (admin rights) at the start.

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
    # Loopback ports (never exposed to the LAN). A busy port is replaced by the next free one.
    [int]$WebUIPort = 3000,
    [int]$SearxngPort = 8888,
    # Pinned image versions (the guide's :main tag is a moving target; Update-OpenWebUI.ps1 bumps these).
    [string]$OpenWebUIVersion = 'v0.11.4',
    [string]$SearxngVersion = '2026.10.2-19ffbcd30',
    # Open WebUI admin login. A random password is generated and stored in <AIRoot>\Secrets.
    [string]$AdminEmail = 'admin@localhost',
    # Ollama tuning. q8_0 halves KV-cache VRAM vs f16 at negligible quality cost, which roughly
    # doubles the context that fits next to a 19 GB model on 24 GB.
    [ValidateSet('f16', 'q8_0', 'q4_0')][string]$KvCacheType = 'q8_0',
    # VRAM Ollama leaves untouched for the desktop/browser (keep <= 1024 or Ollama's default context drops to 4K).
    [ValidateRange(0, 1024)][int]$GpuOverheadMiB = 512,
    # The context tuner requires at least this much VRAM still free with the model loaded.
    [int]$MinFreeVramMiB = 768,
    # How long an idle model stays in VRAM. Run Release-GPU.ps1 before ComfyUI/Forge sessions.
    [string]$KeepAlive = '15m',
    [string[]]$KnowledgeCollections = @('PC & Electronics', '3D Printing', 'Property', 'School', 'Home Projects', 'General References'),
    # Nightly backup of the Open WebUI volume (chats, memories, settings, knowledge).
    [string]$BackupTime = '03:30',
    [int]$BackupRetentionDays = 14,
    [string]$BackupMirror = '',
    # Behaviour switches.
    [switch]$NoReboot,
    [switch]$Retune,
    [switch]$SkipTests,
    [switch]$Resume
    # ========================================================
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$SourceRoot = $PSScriptRoot
Import-Module (Join-Path $SourceRoot 'lib\LocalAI.psm1') -Force

#region Elevation ---------------------------------------------------------------------------

function ConvertTo-PsLiteral {
    param($Value)
    if ($Value -is [array]) { return (($Value | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ',') }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Get-RelaunchCommand {
    param([string]$ScriptPath = $PSCommandPath, [switch]$AddResume)
    $cmd = "& '" + $ScriptPath.Replace("'", "''") + "'"
    foreach ($kv in $script:BoundParams.GetEnumerator()) {
        if ($kv.Key -eq 'Resume') { continue }
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value.IsPresent) { $cmd += " -$($kv.Key)" }
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
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', (Get-RelaunchCommand))
    exit 0
}

#endregion

#region Paths, state, helpers ---------------------------------------------------------------

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
$OllamaDir = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
$DockerExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
$DockerBin = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'
$ResumeTask = 'LocalAI-Install-Resume'
$BackupTask = 'LocalAI-Backup-OpenWebUI'
$CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$CurrentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

foreach ($d in @($P.Root, $P.Logs, $P.Secrets, $P.Backups, $P.Downloads)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
$script:TranscriptOn = $false
try { Start-Transcript -Path (Join-Path $P.Logs ('install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) | Out-Null; $script:TranscriptOn = $true } catch { Write-Verbose 'Transcript unavailable' }

$State = Read-LaiState -Path $P.State
foreach ($k in @('stages', 'tuning', 'flags')) { if (-not $State.ContainsKey($k) -or $null -eq $State[$k]) { $State[$k] = @{} } }

function Save-State { Save-LaiState -State $State -Path $P.State }

function Invoke-Stage {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    Write-Host ''
    Write-LaiLog STEP ('=' * 12 + " $Name " + '=' * 12)
    & $Body
    $State.stages[$Name] = (Get-Date).ToString('s')
    Save-State
}

function Stop-Install {
    param([int]$Code = 0)
    if ($script:TranscriptOn) { try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript' } }
    exit $Code
}

function Invoke-Native {
    # Runs a native command without PS 5.1 turning stderr lines into terminating errors.
    # -Capture returns its combined output; otherwise output streams straight to the console.
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [switch]$Capture, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Capture) { $out = @(& $File @Arguments 2>&1 | ForEach-Object { "$_" }) }
        else { & $File @Arguments | Out-Host; $out = @() }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
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

function Add-SessionPath {
    param([string]$Dir)
    if ($Dir -and (Test-Path -LiteralPath $Dir) -and (($env:Path -split ';') -notcontains $Dir)) { $env:Path = "$Dir;$env:Path" }
}

function Protect-Path {
    # Owner, SYSTEM and Administrators only (folders under C:\ otherwise inherit "Authenticated Users").
    param([Parameter(Mandatory)][string]$Path)
    $grant = 'F'
    if ((Get-Item -LiteralPath $Path -Force) -is [System.IO.DirectoryInfo]) { $grant = '(OI)(CI)F' }
    $r = Invoke-Native -File 'icacls.exe' -Arguments @($Path, '/inheritance:r', '/grant:r', "*${CurrentUserSid}:$grant", "*S-1-5-18:$grant", "*S-1-5-32-544:$grant") -Capture -AllowFail
    if ($r.ExitCode -ne 0) { Write-LaiLog WARN "Could not restrict permissions on ${Path}: $($r.Text)" }
}

function Get-FreeGB {
    param([Parameter(Mandatory)][string]$Path)
    $qualifier = Split-Path -Qualifier $Path
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$qualifier'"
    if (-not $disk) { return 0 }
    return [Math]::Round($disk.FreeSpace / 1GB, 1)
}

function Install-App {
    # winget first (hash-verified manifest); direct download from the vendor as the fallback.
    param(
        [Parameter(Mandatory)][string]$WingetId,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string[]]$InstallerArgs,
        [Parameter(Mandatory)][scriptblock]$IsInstalled
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
    $dest = Join-Path $P.Downloads $FileName
    Write-LaiLog INFO "Downloading $Url"
    Invoke-LaiRetry -What "download $FileName" -Action { Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing } | Out-Null
    $sig = Get-AuthenticodeSignature -FilePath $dest
    if ($sig.Status -ne 'Valid') { throw "$FileName has an invalid Authenticode signature ($($sig.Status)); refusing to run it." }
    Write-LaiLog INFO "Running $FileName (signed by $($sig.SignerCertificate.Subject.Split(',')[0]))"
    $proc = Start-Process -FilePath $dest -ArgumentList $InstallerArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) { throw "$FileName exited with code $($proc.ExitCode)" }
    if ($proc.ExitCode -eq 3010) { $State.flags['rebootPending'] = $true }
    if (-not (& $IsInstalled)) { throw "$FileName finished but the product is still not detected." }
}

function Register-ResumeTask {
    $scriptPath = Join-Path $P.Scripts 'Install-LocalAI.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { $scriptPath = $PSCommandPath }
    $cmd = Get-RelaunchCommand -ScriptPath $scriptPath -AddResume
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -NoExit -Command $cmd"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
    $principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 8)
    Register-ScheduledTask -TaskName $ResumeTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

function Request-Reboot {
    param([Parameter(Mandatory)][string]$Reason)
    Register-ResumeTask
    $State.flags['rebootRequestedAt'] = (Get-Date).ToString('s')
    Save-State
    Write-LaiLog WARN "Reboot required: $Reason"
    if ($NoReboot) {
        Write-LaiLog WARN 'Reboot when convenient and sign in again; the installer resumes automatically.'
        Stop-Install 3010
    }
    Write-LaiLog WARN 'Rebooting in 60 seconds. Save your work, or run "shutdown /a" to cancel. The installer resumes after you sign in.'
    Invoke-Native -File 'shutdown.exe' -Arguments @('/r', '/t', '60', '/c', "Local AI installer: $Reason. It continues after you sign in.") | Out-Null
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

function Get-PortOwner {
    param([int]$Port)
    $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return $null }
    $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    if ($proc) { return $proc.ProcessName }
    return "pid $($c.OwningProcess)"
}

function Select-FreePort {
    # Keeps the requested port if it is free or already served by Docker; otherwise the next free one.
    param([int]$Preferred)
    $dockerProcs = @('com.docker.backend', 'wslrelay', 'vpnkit', 'com.docker.proxy', 'docker-proxy')
    for ($port = $Preferred; $port -lt $Preferred + 20; $port++) {
        $owner = Get-PortOwner -Port $port
        if (-not $owner -or $dockerProcs -contains $owner) { return $port }
        Write-LaiLog WARN "Port $port is used by '$owner'; trying $($port + 1)."
    }
    throw "No free port found near $Preferred."
}

function Write-StackEnv {
    param([hashtable]$Values)
    $envPath = Join-Path $P.Stack '.env'
    $lines = foreach ($k in ($Values.Keys | Sort-Object)) { "$k=$($Values[$k])" }
    [System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    Protect-Path -Path $envPath
}

function Get-AdminCredential {
    $file = Join-Path $P.Secrets 'openwebui-admin.json'
    if (Test-Path -LiteralPath $file) { return (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) }
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

$SystemPrompt = (Get-Content -LiteralPath (Join-Path $SourceRoot 'config\system-prompt.txt') -Raw).Trim()
$CatalogPath = Join-Path $SourceRoot 'config\models.psd1'
# Test hooks for tests/Invoke-InstallerMockRun.ps1 only (small stand-in model on a CPU-only box).
if ($env:LOCALAI_TEST_CATALOG) { $CatalogPath = $env:LOCALAI_TEST_CATALOG }
$AllowCpu = ($env:LOCALAI_TEST_ALLOW_CPU -eq '1')
$script:WebUIPortEffective = $WebUIPort
if ($State.flags.ContainsKey('webuiPort')) { $script:WebUIPortEffective = [int]$State.flags['webuiPort'] }
$script:SearxngPortEffective = $SearxngPort
if ($State.flags.ContainsKey('searxngPort')) { $script:SearxngPortEffective = [int]$State.flags['searxngPort'] }

Write-LaiLog STEP "Local AI installer - log: $($P.Logs)"
if ($Resume) { Write-LaiLog INFO 'Resuming after reboot/sign-in.' }

try {

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
        throw 'nvidia-smi was not found, so the NVIDIA driver is missing or broken. Install the current Game Ready driver from https://www.nvidia.com/Download/index.aspx, reboot, then re-run this script.'
    }
    Write-LaiLog OK "GPU: $($gpu.Name), driver $($gpu.DriverVersion), $($gpu.TotalMiB) MiB VRAM ($($gpu.FreeMiB) MiB free)"
    if ([version]$gpu.DriverVersion -lt [version]'551.61') {
        throw "NVIDIA driver $($gpu.DriverVersion) is older than 551.61, the minimum Ollama supports on Windows. Update from https://www.nvidia.com/Download/index.aspx, reboot, re-run."
    }
    if ($gpu.TotalMiB -lt 23000) { Write-LaiLog WARN 'The model catalog is sized for a 24 GB card; the 30B models will partly run on the CPU.' }
    if ($gpu.UsedMiB -gt 3000) {
        Write-LaiLog WARN "$($gpu.UsedMiB) MiB of VRAM is already in use (ComfyUI/Forge/games?). Close GPU-heavy apps before the context tuning step for accurate results."
    }

    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Write-LaiLog INFO ("CPU: {0}; RAM: {1} GB" -f $cpu.Name.Trim(), [Math]::Round($cs.TotalPhysicalMemory / 1GB))
    if (-not $cs.HypervisorPresent -and -not $cpu.VirtualizationFirmwareEnabled) {
        Write-LaiLog WARN 'CPU virtualization looks disabled in firmware. Docker needs it: enable SVM Mode (AMD) in the BIOS (Advanced > CPU Configuration).'
    }

    # Disk planning: decide where models go and whether the optional models fit.
    $catalogAll = Get-LaiCatalog -Path $CatalogPath
    $defaultModels = Join-Path $env:USERPROFILE '.ollama\models'
    $envModels = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User')
    $target = $defaultModels
    if ($ModelDir) { $target = $ModelDir }
    elseif ($State.flags.ContainsKey('modelDir')) { $target = $State.flags['modelDir'] }
    elseif ($envModels) { $target = $envModels }
    else {
        # Catalog entries are hashtables; Windows PowerShell 5.1's Measure-Object -Property can't read their keys.
        $needAll = 10
        foreach ($cm in $catalogAll.Models) { $needAll += [double]$cm.DownloadGB }
        $hasExisting = (Test-Path -LiteralPath (Join-Path $defaultModels 'manifests'))
        if (-not $hasExisting -and (Get-FreeGB $env:SystemDrive) -lt ($needAll + 40)) {
            $best = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.DeviceID -ne $env:SystemDrive } |
                Sort-Object FreeSpace -Descending | Select-Object -First 1  # lai-ok: objects
            if ($best -and ($best.FreeSpace / 1GB) -ge ($needAll + 10)) {
                $target = Join-Path "$($best.DeviceID)\" 'AI\OllamaModels'
                Write-LaiLog INFO "System drive is short on space; models go to $target"
            }
        }
    }
    $State.flags['modelDir'] = $target
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }

    $selected = @()
    $freeGB = Get-FreeGB $target
    $present = @()
    try { $present = Get-LaiOllamaModelNames -BaseUrl $OllamaUrl } catch { Write-Verbose 'Ollama not installed yet' }
    $budget = $freeGB - 15
    foreach ($m in ($catalogAll.Models | Sort-Object { $_.Optional })) {
        $need = $m.DownloadGB
        if ($present -contains (Resolve-LaiModelName $m.Source)) { $need = 0 }
        if ($m.Optional) {
            if (($m.Key -eq 'vision' -and $SkipVision) -or ($m.Key -eq 'code' -and $SkipCoder)) { Write-LaiLog INFO "Skipping $($m.Display) (switch)"; continue }
            if ($need -gt 0 -and $need -gt $budget) { Write-LaiLog WARN "Skipping $($m.Display): needs $need GB, only $([Math]::Round($budget,1)) GB to spare on $target"; continue }
        } elseif ($need -gt 0 -and $need -gt $budget) {
            throw "Not enough disk space on ${target}: $($m.Display) needs $need GB plus a 15 GB margin; $freeGB GB free. Free space or pass -ModelDir <path on a bigger drive>."
        }
        $budget -= $need
        $selected += $m.Key
    }
    $State.flags['selectedModels'] = $selected
    Write-LaiLog OK "Models: $($selected -join ', ') -> $target ($freeGB GB free)"
    if ((Get-FreeGB $env:SystemDrive) -lt 15) { Write-LaiLog WARN "Less than 15 GB free on $env:SystemDrive; Docker images and WSL need about 10 GB there." }

    # Keep a stable copy of the scripts for scheduled tasks and the resume task.
    if ($SourceRoot.TrimEnd('\') -ne $P.Scripts.TrimEnd('\')) {
        if (-not (Test-Path -LiteralPath $P.Scripts)) { New-Item -ItemType Directory -Force -Path $P.Scripts | Out-Null }
        foreach ($item in @('Install-LocalAI.ps1', 'Install-LocalAI.cmd', 'Test-LocalAI.ps1', 'Backup-OpenWebUI.ps1', 'Update-OpenWebUI.ps1', 'Release-GPU.ps1', 'Set-OpenWebUIPassword.ps1', 'README.md', 'lib', 'config', 'stack')) {
            $src = Join-Path $SourceRoot $item
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $P.Scripts -Recurse -Force }
        }
        Write-LaiLog OK "Scripts copied to $($P.Scripts)"
    }
    foreach ($d in @('Projects', 'Scratch', 'Downloads', 'Generated')) {
        $w = Join-Path $P.Workspace $d
        if (-not (Test-Path -LiteralPath $w)) { New-Item -ItemType Directory -Force -Path $w | Out-Null }
    }
    Protect-Path -Path $P.Secrets
}
$Catalog = Get-LaiCatalog -Path $CatalogPath -IncludeKeys @($State.flags['selectedModels'])
#endregion

#region 2. Ollama ---------------------------------------------------------------------------
Invoke-Stage 'Ollama' {
    $ollamaExe = Join-Path $OllamaDir 'ollama.exe'
    if (-not (Test-Path -LiteralPath $ollamaExe)) {
        Install-App -WingetId 'Ollama.Ollama' -Url 'https://ollama.com/download/OllamaSetup.exe' -FileName 'OllamaSetup.exe' `
            -InstallerArgs @('/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES') -IsInstalled { Test-Path -LiteralPath $ollamaExe }
    }
    Add-SessionPath $OllamaDir

    $settings = [ordered]@{
        OLLAMA_FLASH_ATTENTION = '1'
        OLLAMA_KV_CACHE_TYPE   = $KvCacheType
        OLLAMA_NUM_PARALLEL    = '1'                                  # KV cache is allocated per parallel slot
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
    $changed = $false
    foreach ($k in $settings.Keys) { if (Set-UserEnv -Name $k -Value $settings[$k]) { $changed = $true; Write-LaiLog INFO "set $k=$($settings[$k])" } }

    $up = $false
    try { Get-LaiOllamaVersion -BaseUrl $OllamaUrl | Out-Null; $up = $true } catch { Write-Verbose 'Ollama API not up' }
    if ($changed -or -not $up) {
        Write-LaiLog INFO 'Restarting Ollama so it picks up the settings'
        Get-Process -Name 'ollama app', 'ollama', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Start-AsUser (Join-Path $OllamaDir 'ollama app.exe')
        try { Wait-LaiHttp -Uri "$OllamaUrl/api/version" -TimeoutSec 60 | Out-Null }
        catch {
            Write-LaiLog WARN 'Ollama did not start via Explorer; starting it directly.'
            Start-Process -FilePath (Join-Path $OllamaDir 'ollama app.exe')
            Wait-LaiHttp -Uri "$OllamaUrl/api/version" -TimeoutSec 90 | Out-Null
        }
    }
    $ver = Get-LaiOllamaVersion -BaseUrl $OllamaUrl
    Write-LaiLog OK "Ollama $ver on $OllamaUrl"

    $log = Join-Path $env:LOCALAPPDATA 'Ollama\server.log'
    if (Test-Path -LiteralPath $log) {
        $cfgLine = Select-String -LiteralPath $log -Pattern 'msg="server config"' | Select-Object -Last 1
        if ($cfgLine) {
            $ok = ($cfgLine.Line -match 'OLLAMA_FLASH_ATTENTION:true') -and ($cfgLine.Line -match "OLLAMA_KV_CACHE_TYPE:$KvCacheType")
            if (-not $ok) {
                # Explorer may not have refreshed its environment yet; this process has the new values.
                Write-LaiLog WARN 'Ollama did not pick up the new settings; restarting it from this session.'
                Get-Process -Name 'ollama app', 'ollama', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
                Start-Process -FilePath (Join-Path $OllamaDir 'ollama app.exe')
                Wait-LaiHttp -Uri "$OllamaUrl/api/version" -TimeoutSec 90 | Out-Null
                Start-Sleep -Seconds 2
                $cfgLine = Select-String -LiteralPath $log -Pattern 'msg="server config"' | Select-Object -Last 1
                $ok = $cfgLine -and ($cfgLine.Line -match 'OLLAMA_FLASH_ATTENTION:true') -and ($cfgLine.Line -match "OLLAMA_KV_CACHE_TYPE:$KvCacheType")
            }
            if ($ok) { Write-LaiLog OK "Server running with flash attention + $KvCacheType KV cache" }
            else { Write-LaiLog WARN 'Ollama server log still does not show the new settings; sign out and in again, then re-run with -Retune.' }
        }
        $gpuLine = Select-String -LiteralPath $log -Pattern 'inference compute' | Select-Object -Last 1
        if ($gpuLine) { Write-LaiLog INFO ($gpuLine.Line -replace '^.*msg="inference compute"\s*', 'inference compute: ') }
    }
}
#endregion

#region 3. Models (guide Parts 3-4: pull, run, verify 100% GPU) ----------------------------
Invoke-Stage 'Models' {
    # The ollama CLI is a client of the local server; never let it target 0.0.0.0 (LAN fallback mode).
    $env:OLLAMA_HOST = '127.0.0.1:11434'
    foreach ($m in ($Catalog.Models | Sort-Object { $_.Optional }, { $_.DownloadGB })) {
        if (Test-LaiOllamaModel -BaseUrl $OllamaUrl -Name $m.Source) {
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
    }
    Stop-LaiOllamaModels -BaseUrl $OllamaUrl
}
#endregion

#region 4. Context tuning + tuned aliases (guide Parts 5, 10, 27 automated) ---------------
Invoke-Stage 'Tuning' {
    $gpu = Get-LaiGpuInfo
    $fingerprint = "driver=$($gpu.DriverVersion);kv=$KvCacheType;overhead=$GpuOverheadMiB;free=$MinFreeVramMiB"
    $results = Invoke-LaiModelSetup -BaseUrl $OllamaUrl -Models $Catalog.Models -Candidates $Catalog.ContextCandidates `
        -SystemPrompt $SystemPrompt -Previous $State.tuning -Fingerprint $fingerprint -MinFreeMiB $MinFreeVramMiB -Retune:$Retune -AllowCpu:$AllowCpu
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

    # Cap the WSL VM so Docker's page cache cannot crowd out RAM that Ollama/ComfyUI need (only if you have no .wslconfig yet).
    $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
    if (-not (Test-Path -LiteralPath $wslConfig)) {
        $content = "[wsl2]`r`nmemory=16GB`r`n`r`n[experimental]`r`nautoMemoryReclaim=gradual`r`n"
        [System.IO.File]::WriteAllText($wslConfig, $content, (New-Object System.Text.UTF8Encoding($false)))
        Write-LaiLog OK "Created $wslConfig (WSL memory cap 16 GB, gradual reclaim)"
    }
}
#endregion

#region 6. Docker Desktop (guide Part 7) ----------------------------------------------------
Invoke-Stage 'Docker' {
    if (-not (Test-Path -LiteralPath $DockerExe)) {
        Install-App -WingetId 'Docker.DockerDesktop' -Url 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' `
            -FileName 'DockerDesktopInstaller.exe' -InstallerArgs @('install', '--quiet', '--accept-license', '--backend=wsl-2', '--always-run-service') `
            -IsInstalled { Test-Path -LiteralPath $DockerExe }
        $State.flags['dockerInstalledAt'] = (Get-Date).ToString('s')
        Save-State
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
        throw ('Docker engine did not start. Open Docker Desktop once: accept the agreement if asked, wait for "Engine running", ' +
            'then re-run. If it reports virtualization errors, enable SVM Mode in the BIOS.')
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
    if (-not (Test-Path -LiteralPath $P.Stack)) { New-Item -ItemType Directory -Force -Path $P.Stack | Out-Null }
    $searxDir = Join-Path $P.Stack 'searxng'
    if (-not (Test-Path -LiteralPath $searxDir)) { New-Item -ItemType Directory -Force -Path $searxDir | Out-Null }
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'stack\docker-compose.yml') -Destination $P.Stack -Force
    $searxSettings = Join-Path $searxDir 'settings.yml'
    if (-not (Test-Path -LiteralPath $searxSettings)) {
        $tpl = Get-Content -LiteralPath (Join-Path $SourceRoot 'stack\searxng\settings.yml') -Raw
        [System.IO.File]::WriteAllText($searxSettings, $tpl.Replace('__SEARXNG_SECRET__', (New-LaiSecret)), (New-Object System.Text.UTF8Encoding($false)))
    }

    # A container from the guide's manual "docker run" would clash with the compose-managed one.
    $legacy = Invoke-Native -File 'docker' -Arguments @('ps', '-a', '--filter', 'name=^/open-webui$', '--format', '{{.ID}}|{{.Label "com.docker.compose.project"}}') -Capture -AllowFail
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
            Invoke-Native -File 'docker' -Arguments @('run', '--rm', '-v', $from, '-v', 'open-webui:/to', 'alpine:3.20', 'sh', '-c', 'cp -a /from/. /to/') -Capture | Out-Null
            Write-LaiLog OK "Copied the old Open WebUI data (from $($from -replace ':/from:ro$', '')) into the open-webui volume"
        } elseif ($from) {
            Write-LaiLog WARN "Both the old data ($from) and an open-webui volume exist; leaving both untouched. See README > Troubleshooting to merge."
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
        if (Test-Path -LiteralPath $guideSecret) { Copy-Item -LiteralPath $guideSecret -Destination $secretFile }
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
        WEBUI_SECRET_KEY   = (Get-Content -LiteralPath $secretFile -Raw).Trim()
        WEBUI_ADMIN_EMAIL  = $cred.email
        WEBUI_ADMIN_PASSWORD = ''
        OLLAMA_BASE_URL    = 'http://host.docker.internal:11434'
    }
    if (-not $State.flags['adminVerified']) { $envValues['WEBUI_ADMIN_PASSWORD'] = $cred.password }
    Write-StackEnv -Values $envValues

    Write-LaiLog INFO "Pulling images (Open WebUI $OpenWebUIVersion is several GB on first install)"
    Invoke-LaiRetry -What 'docker compose pull' -Attempts 3 -DelaySeconds 15 -Action { Invoke-Compose -Arguments @('pull') | Out-Null } | Out-Null
    Invoke-Compose -Arguments @('up', '-d', '--remove-orphans') | Out-Null
    $webui = "http://127.0.0.1:$($script:WebUIPortEffective)"
    Write-LaiLog INFO "Waiting for Open WebUI on $webui (first start runs database migrations)"
    Wait-LaiWebUI -BaseUrl $webui -TimeoutSec 600
    Write-LaiLog OK "Open WebUI is up on http://localhost:$($script:WebUIPortEffective)"

    # Can the container reach Ollama on the Windows host? (guide Part 9 / troubleshooting)
    $probe = "import urllib.request;print(urllib.request.urlopen('http://host.docker.internal:11434/api/version',timeout=5).read().decode())"
    $r = Invoke-Native -File 'docker' -Arguments @('exec', 'open-webui', 'python', '-c', $probe) -Capture -AllowFail
    if ($r.Text -notmatch '"version"') {
        Write-LaiLog WARN 'Open WebUI cannot reach Ollama on 127.0.0.1. Switching Ollama to listen on all interfaces with a firewall block for the LAN.'
        $State.flags['ollamaLanFallback'] = $true
        Save-State
        Set-UserEnv -Name 'OLLAMA_HOST' -Value '0.0.0.0:11434' | Out-Null
        $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceAlias })
        if ($nics.Count -gt 0 -and -not (Get-NetFirewallRule -DisplayName 'LocalAI - Block Ollama from LAN' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName 'LocalAI - Block Ollama from LAN' -Direction Inbound -Protocol TCP -LocalPort 11434 `
                -Action Block -InterfaceAlias $nics -Profile Any | Out-Null
        }
        Get-Process -Name 'ollama app', 'ollama', 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Start-AsUser (Join-Path $OllamaDir 'ollama app.exe')
        Wait-LaiHttp -Uri "$OllamaUrl/api/version" -TimeoutSec 90 | Out-Null
        $r = Invoke-Native -File 'docker' -Arguments @('exec', 'open-webui', 'python', '-c', $probe) -Capture -AllowFail
        if ($r.Text -notmatch '"version"') { throw "Open WebUI still cannot reach Ollama at host.docker.internal:11434. Output: $($r.Text)" }
    }
    Write-LaiLog OK 'Open WebUI container reaches Ollama at host.docker.internal:11434'
}
$WebUIUrl = "http://127.0.0.1:$($script:WebUIPortEffective)"
#endregion

#region 8. Configure Open WebUI (guide Parts 10-18) -----------------------------------------
Invoke-Stage 'Configure' {
    $cred = Get-AdminCredential
    $token = $null
    if ((Invoke-LaiApi -Uri "$WebUIUrl/api/config").onboarding -eq $true) {
        # Empty database (fresh volume): admin accounts are only created at container start, so
        # put the bootstrap password back and recreate the container.
        Write-LaiLog INFO 'Open WebUI has no users yet; creating the admin account'
        $State.flags['adminVerified'] = $false
        $envPath = Join-Path $P.Stack '.env'
        $lines = Get-Content -LiteralPath $envPath | ForEach-Object { if ($_ -like 'WEBUI_ADMIN_PASSWORD=*') { "WEBUI_ADMIN_PASSWORD=$($cred.password)" } else { $_ } }
        [System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        Invoke-Compose -Arguments @('up', '-d', '--force-recreate', 'open-webui') | Out-Null
        Wait-LaiWebUI -BaseUrl $WebUIUrl -TimeoutSec 300
    }
    try { $token = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $cred.email -Password $cred.password }
    catch {
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
        $lines = Get-Content -LiteralPath $envPath | ForEach-Object { if ($_ -like 'WEBUI_ADMIN_PASSWORD=*') { 'WEBUI_ADMIN_PASSWORD=' } else { $_ } }
        [System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        Invoke-Compose -Arguments @('up', '-d') | Out-Null
        Wait-LaiWebUI -BaseUrl $WebUIUrl -TimeoutSec 300
        $c2 = Get-AdminCredential
        $token = Connect-LaiWebUI -BaseUrl $WebUIUrl -Email $c2.email -Password $c2.password
        Write-LaiLog OK 'Bootstrap admin password removed from the container environment'
    }

    Invoke-LaiWebUISetup -BaseUrl $WebUIUrl -Token $token -Models $Catalog.Models -ModelResults $State.tuning `
        -SystemPrompt $SystemPrompt -DefaultPreset $Catalog.DefaultPreset -Collections $KnowledgeCollections
}
#endregion

#region 9. Backups (guide Parts 22-23) -------------------------------------------------------
Invoke-Stage 'Backup' {
    $config = @{
        AIRoot = $AIRoot; WebUIPort = $script:WebUIPortEffective; SearxngPort = $script:SearxngPortEffective
        OpenWebUIVersion = $OpenWebUIVersion; SearxngVersion = $SearxngVersion; OllamaUrl = $OllamaUrl
        ModelDir = $State.flags['modelDir']; SelectedModels = @($State.flags['selectedModels'])
        BackupRetentionDays = $BackupRetentionDays; BackupMirror = $BackupMirror; KeepAlive = $KeepAlive
    }
    ConvertTo-Json -InputObject $config -Depth 5 | Set-Content -LiteralPath $P.Config -Encoding UTF8

    $backupScript = Join-Path $P.Scripts 'Backup-OpenWebUI.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -AIRoot "{1}"' -f $backupScript, $AIRoot)
    $trigger = New-ScheduledTaskTrigger -Daily -At $BackupTime
    $principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $BackupTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-LaiLog OK "Scheduled task '$BackupTask' runs daily at $BackupTime (missed runs catch up at next sign-in)"

    & $backupScript -AIRoot $AIRoot
    if ($LASTEXITCODE -ne 0) { throw 'The first backup failed; see the messages above.' }
}
#endregion

#region 10. Acceptance tests (guide Part 28 "finished V1") ---------------------------------
$testExit = 0
if (-not $SkipTests) {
    Invoke-Stage 'Verify' {
        & (Join-Path $P.Scripts 'Test-LocalAI.ps1') -AIRoot $AIRoot
        $script:testExit = $LASTEXITCODE
    }
    $testExit = $script:testExit
}
#endregion

#region Report ---------------------------------------------------------------------------
Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue
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
    "- Scripts: $($P.Scripts) (Test-LocalAI, Backup-OpenWebUI, Update-OpenWebUI, Release-GPU)"
    ''
    '| Preset | Model | Context (tokens) | On GPU | Tokens/s |'
    '|---|---|---:|---:|---:|'
) + $rows + @(
    ''
    'Context = largest value that kept the model 100% in VRAM with headroom, capped at the trained/configured maximum.'
    'Before ComfyUI/Forge sessions run Release-GPU.ps1 so Ollama gives back the VRAM.'
)
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
Write-Host 'Open a NEW terminal to use the ollama command (windows opened before the install do not see the PATH change).' -ForegroundColor Gray
Start-AsUser "http://localhost:$($script:WebUIPortEffective)"
exit $testExit
#endregion

} catch {
    Write-LaiLog FAIL $_.Exception.Message
    if ($_.InvocationInfo) { Write-LaiLog FAIL ("at " + $_.InvocationInfo.PositionMessage.Split("`n")[0]) }
    Write-LaiLog FAIL "Fix the issue above and run the installer again; finished steps are skipped. Log: $($P.Logs)"
    Save-State
    Stop-Install 1
}
