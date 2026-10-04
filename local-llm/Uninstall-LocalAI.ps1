#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the local AI stack that Install-LocalAI.ps1 set up, with a final backup first.

.DESCRIPTION
    Default (safe) removal:
      1. Final verified backup of the Open WebUI volume (Backups\open-webui-<ts>-pre-uninstall.tar.gz).
      2. Scheduled tasks LocalAI-Backup-OpenWebUI, LocalAI-Watch, LocalAI-Install-Resume.
      3. The containers (open-webui, searxng, render-guard) and their network (docker compose down).
      4. The Tailscale HTTPS mapping to Open WebUI, if there is one.
      5. The tuned Ollama aliases (localai-*; they share weights with the source models, ~0 GB).
      6. The "ComfyUI (free GPU first)" desktop shortcut and the "Local AI" Start-menu folder.
    Kept unless asked: the Open WebUI data volume (chats, memories, knowledge), the downloaded models
    (~67 GB), the Ollama settings, the backups, and everything outside C:\AI. Ollama, Docker Desktop
    and WSL are never uninstalled (other programs may use them; remove them in Settings > Apps).

      -RemoveData       also delete the open-webui volume and C:\AI\{Stack,Scripts,Secrets,Logs}
                        and state files. The Backups folder is always kept.
      -RemoveModels     also delete the catalog's source models from Ollama (and OLLAMA_MODELS).
      -ResetOllamaSettings  remove the OLLAMA_* user variables the installer set (flash attention,
                        q8_0 KV cache, keep-alive, ...), plus OLLAMA_HOST and its LAN firewall block.

.EXAMPLE
    .\Uninstall-LocalAI.ps1 -WhatIf        # show what would happen
.EXAMPLE
    .\Uninstall-LocalAI.ps1                # remove the stack, keep data and models
.EXAMPLE
    .\Uninstall-LocalAI.ps1 -RemoveData -RemoveModels -ResetOllamaSettings -Force
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$AIRoot = 'C:\AI',
    [switch]$RemoveData,
    [switch]$RemoveModels,
    [switch]$ResetOllamaSettings,
    [switch]$NoBackup,
    [switch]$Force,
    [string]$OllamaUrl = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$onWindows = ($env:OS -eq 'Windows_NT')
if ($onWindows -and -not $WhatIfPreference) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this from an elevated PowerShell (it removes scheduled tasks, the Program Files copy and firewall rules).'
    }
}

$configPath = Join-Path $AIRoot 'localai-config.json'
$config = Read-LaiState -Path $configPath
if (-not $OllamaUrl) {
    $OllamaUrl = 'http://127.0.0.1:11434'
    if ($config.ContainsKey('OllamaUrl') -and $config['OllamaUrl']) { $OllamaUrl = [string]$config['OllamaUrl'] }
}
$stackDir = Join-Path $AIRoot 'Stack'
$compose = Join-Path $stackDir 'docker-compose.yml'
$problems = @()

function Invoke-Docker {
    param([string[]]$Arguments)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& docker @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ ExitCode = $code; Text = ($out -join "`n") }
}

function Invoke-Step {
    # Runs one removal step; a failure is reported and the remaining steps still run.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$What, [scriptblock]$Action)
    if (-not $PSCmdlet.ShouldProcess($What, 'Remove')) { return }
    try { & $Action } catch {
        $script:problems += "${What}: $($_.Exception.Message)"
        Write-LaiLog WARN "$What failed: $($_.Exception.Message)"
    }
}

$dockerUp = $false
if (Get-Command docker -ErrorAction SilentlyContinue) { $dockerUp = ((Invoke-Docker @('version', '--format', '{{.Server.Version}}')).ExitCode -eq 0) }
$volumeExists = $dockerUp -and ((Invoke-Docker @('volume', 'inspect', 'open-webui')).ExitCode -eq 0)

# ---- plan + confirmation ------------------------------------------------------------------------
$plan = @('scheduled tasks (backup, health watch, install resume)', 'containers open-webui, searxng, render-guard',
    'Tailscale mapping to Open WebUI (if any)', 'tuned Ollama aliases localai-*', 'shortcuts (desktop ComfyUI, Start-menu Local AI folder)')
$kept = @()
if ($RemoveData) { $plan += 'Open WebUI data volume (chats, memories, knowledge) and C:\AI stack/scripts/secrets/logs' } else { $kept += 'Open WebUI data volume (re-run Install-LocalAI.ps1 and everything comes back)' }
if ($RemoveModels) { $plan += 'downloaded models from the catalog' } else { $kept += 'downloaded models' }
if ($ResetOllamaSettings) { $plan += 'OLLAMA_* user variables set by the installer (+ OLLAMA_HOST firewall rule)' } else { $kept += 'Ollama settings' }
$kept += "backups in $(Join-Path $AIRoot 'Backups')"
Write-LaiLog STEP 'Uninstall plan'
foreach ($p in $plan) { Write-LaiLog INFO "remove: $p" }
foreach ($k in $kept) { Write-LaiLog INFO "keep:   $k" }
if (-not $Force -and -not $WhatIfPreference) {
    $answer = Read-Host 'Type YES to continue'
    if ($answer -cne 'YES') { Write-LaiLog INFO 'Nothing changed.'; exit 1 }
}

# ---- 1. final backup ----------------------------------------------------------------------------
if (-not $NoBackup -and $volumeExists) {
    if ($PSCmdlet.ShouldProcess('Open WebUI volume', 'Final backup')) {
        & (Join-Path $PSScriptRoot 'Backup-OpenWebUI.ps1') -AIRoot $AIRoot -Tag 'pre-uninstall' -NoPrune
        if ($LASTEXITCODE -ne 0) {
            throw 'The final backup failed, so nothing was removed. Fix the backup or re-run with -NoBackup.'
        }
    }
} elseif ($RemoveData -and $volumeExists -and $NoBackup) {
    Write-LaiLog WARN 'Deleting the data volume WITHOUT a final backup (-NoBackup).'
}

# ---- 2. scheduled tasks -------------------------------------------------------------------------
if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
    foreach ($t in @('LocalAI-Backup-OpenWebUI', 'LocalAI-Watch', 'LocalAI-Install-Resume')) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Invoke-Step "scheduled task $t" { Unregister-ScheduledTask -TaskName $t -Confirm:$false; Write-LaiLog OK "Removed scheduled task $t" }
        }
    }
}

# ---- 3. containers ------------------------------------------------------------------------------
if ($dockerUp) {
    Invoke-Step 'containers' {
        if (Test-Path -LiteralPath $compose) {
            $r = Invoke-Docker @('compose', '--project-directory', $stackDir, '-f', $compose, 'down', '--remove-orphans')
            if ($r.ExitCode -ne 0) { Write-LaiLog WARN "docker compose down: $($r.Text)" }
        }
        # Also catch containers whose compose file is gone or that were renamed by hand.
        foreach ($c in @('open-webui', 'searxng', 'render-guard')) {
            if ((Invoke-Docker @('container', 'inspect', $c)).ExitCode -eq 0) {
                $r = Invoke-Docker @('rm', '-f', $c)
                if ($r.ExitCode -ne 0) { throw "docker rm $c failed: $($r.Text)" }
            }
        }
        Write-LaiLog OK 'Containers removed'
    }
    if ($RemoveData -and $volumeExists) {
        Invoke-Step 'open-webui volume' {
            $r = Invoke-Docker @('volume', 'rm', 'open-webui')
            if ($r.ExitCode -ne 0) { throw $r.Text }
            Write-LaiLog OK 'Open WebUI data volume deleted'
        }
    }
} else {
    Write-LaiLog WARN 'Docker engine is not running: containers and the data volume were left in place. Start Docker Desktop and re-run to remove them.'
}

# ---- 4. Tailscale -------------------------------------------------------------------------------
$ts = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $ts -and $env:ProgramFiles -and (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'))) { $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
if ($ts) {
    $port = 3000; if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $json = (& $ts serve status --json 2>$null) -join "`n" } finally { $ErrorActionPreference = $prev }
    if ($json -match [regex]::Escape("http://127.0.0.1:$port")) {
        Invoke-Step 'Tailscale mapping' { & (Join-Path $PSScriptRoot 'Enable-TailscaleAccess.ps1') -AIRoot $AIRoot -Port $port -Disable }
    }
}

# ---- 5. Ollama aliases / models / settings --------------------------------------------------------
$ollamaUp = $true
try { $names = @(Get-LaiOllamaModelNames -BaseUrl $OllamaUrl) } catch { $ollamaUp = $false; $names = @() }
if ($ollamaUp) {
    $toRemove = @($names | Where-Object { $_ -like 'localai-*' })
    if ($RemoveModels) {
        $catalog = Get-LaiCatalog -Path (Join-Path (Join-Path $PSScriptRoot 'config') 'models.psd1') -IncludeTrials
        foreach ($m in $catalog.Models) {
            $full = Resolve-LaiModelName $m.Source
            if ($names -contains $full) { $toRemove += $full }
            if ($names -contains "$full-prev") { $toRemove += "$full-prev" }
        }
    }
    foreach ($n in $toRemove) {
        Invoke-Step "Ollama model $n" {
            Invoke-LaiApi -Method DELETE -Uri "$OllamaUrl/api/delete" -Body @{ model = $n } | Out-Null
            Write-LaiLog OK "Removed $n from Ollama"
        }
    }
} else {
    Write-LaiLog WARN "Ollama is not answering at $OllamaUrl; its aliases/models were left in place. Start Ollama and re-run."
}

if ($onWindows -and ($ResetOllamaSettings -or $RemoveModels)) {
    $vars = @()
    if ($ResetOllamaSettings) {
        $vars += 'OLLAMA_FLASH_ATTENTION', 'OLLAMA_KV_CACHE_TYPE', 'OLLAMA_NUM_PARALLEL', 'OLLAMA_GPU_OVERHEAD',
            'OLLAMA_KEEP_ALIVE', 'OLLAMA_NO_CLOUD', 'OLLAMA_IGPU_ENABLE', 'OLLAMA_HOST'
    }
    if ($RemoveModels) { $vars += 'OLLAMA_MODELS' }
    foreach ($v in $vars) {
        if ([Environment]::GetEnvironmentVariable($v, 'User')) {
            Invoke-Step "user variable $v" { [Environment]::SetEnvironmentVariable($v, $null, 'User'); Write-LaiLog OK "Removed user variable $v" }
        }
    }
    # The firewall block only exists because Ollama listened on all interfaces; drop it with OLLAMA_HOST.
    if ($ResetOllamaSettings -and (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        if (Get-NetFirewallRule -DisplayName 'LocalAI - Block Ollama from LAN' -ErrorAction SilentlyContinue) {
            Invoke-Step 'firewall rule' { Remove-NetFirewallRule -DisplayName 'LocalAI - Block Ollama from LAN'; Write-LaiLog OK 'Removed firewall rule' }
        }
    }
    Write-LaiLog INFO 'Quit Ollama from the tray and start it again so it picks up the changed settings.'
}

# ---- 6. shortcut + files -------------------------------------------------------------------------
$desktop = [Environment]::GetFolderPath('Desktop')
if ($desktop) {
    $lnk = Join-Path $desktop 'ComfyUI (free GPU first).lnk'
    if (Test-Path -LiteralPath $lnk) { Invoke-Step 'desktop shortcut' { Remove-Item -LiteralPath $lnk -Force; Write-LaiLog OK 'Removed desktop shortcut' } }
}

# The administrators-only copy the resume task runs (see Install-LocalAI.ps1, $ElevatedDir).
if ($env:ProgramFiles) {
    $elevated = Join-Path $env:ProgramFiles 'LocalAI'
    if (Test-Path -LiteralPath $elevated) { Invoke-Step $elevated { Remove-Item -LiteralPath $elevated -Recurse -Force; Write-LaiLog OK "Deleted $elevated" } }
}
if ($env:ProgramData) {
    $menu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Local AI'
    if (Test-Path -LiteralPath $menu) { Invoke-Step 'Start-menu folder' { Remove-Item -LiteralPath $menu -Recurse -Force; Write-LaiLog OK "Removed Start-menu folder 'Local AI'" } }
}

if ($RemoveData) {
    $here = (Resolve-Path -LiteralPath $PSScriptRoot).Path
    $stateFiles = @()
    foreach ($j in 'install-state.json', 'localai-config.json', 'watch-state.json') { $stateFiles += @($j, "$j.bak", "$j.bad", "$j.tmp") }
    foreach ($item in (@('Stack', 'Secrets', 'Logs', 'Downloads', 'install-report.md', 'open-webui-hold.json') + $stateFiles)) {
        $path = Join-Path $AIRoot $item
        if (-not (Test-Path -LiteralPath $path)) { continue }
        Invoke-Step $path { Remove-Item -LiteralPath $path -Recurse -Force; Write-LaiLog OK "Deleted $path" }
    }
    # The running script lives in AIRoot\Scripts when started from there: delete it last, or tell the user.
    $scripts = Join-Path $AIRoot 'Scripts'
    if (Test-Path -LiteralPath $scripts) {
        $scriptsFull = (Resolve-Path -LiteralPath $scripts).Path
        if ($here -eq $scriptsFull -or $here.StartsWith($scriptsFull + [IO.Path]::DirectorySeparatorChar)) {
            Write-LaiLog INFO "Delete $scripts yourself after this window closes (this script is running from it)."
        } else {
            Invoke-Step $scripts { Remove-Item -LiteralPath $scripts -Recurse -Force; Write-LaiLog OK "Deleted $scripts" }
        }
    }
}

if ($problems.Count -gt 0) {
    Write-LaiLog WARN "Finished with $($problems.Count) problem(s):"
    foreach ($p in $problems) { Write-LaiLog WARN "  $p" }
    exit 2
}
Write-LaiLog OK 'Uninstall finished.'
foreach ($k in $kept) { Write-LaiLog INFO "kept: $k" }
exit 0
