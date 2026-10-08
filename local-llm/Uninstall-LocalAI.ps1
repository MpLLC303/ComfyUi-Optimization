#Requires -Version 5.1

<#
.SYNOPSIS
    Removes the local AI stack that Install-LocalAI.ps1 set up, with a final backup first.

.DESCRIPTION
    Default (safe) removal:
      1. Final verified backup of the Open WebUI volume (Backups\open-webui-<ts>-pre-uninstall.tar.gz).
      2. Scheduled tasks LocalAI-Backup-OpenWebUI, LocalAI-Watch, LocalAI-Recheck-Models,
         LocalAI-Install-Resume.
      3. The Tailscale HTTPS mapping to Open WebUI, if there is one.
      4. The containers (open-webui, searxng, render-guard) and their network (docker compose down).
      5. The tuned Ollama aliases (localai-*; they share weights with the source models, ~0 GB).
      6. The "ComfyUI (free GPU first)" desktop shortcut and the "Local AI" Start-menu folder.
    Kept unless asked: the Open WebUI data volume (chats, memories, knowledge), the downloaded models
    (~67 GB), the Ollama settings, the backups, and everything outside C:\AI. Ollama, Docker Desktop
    and WSL are never uninstalled (other programs may use them; remove them in Settings > Apps).

      -RemoveData       also delete the open-webui volume (and the deep research one) and C:\AI\{Stack,Scripts,Secrets,Logs}
                        and state files. The Backups folder and a CLAUDE.md in the install folder are always kept.
      -RemoveModels     also delete the catalog's source models from Ollama (and OLLAMA_MODELS).
      -ResetOllamaSettings  remove the OLLAMA_* user variables the installer set (flash attention,
                        q8_0 KV cache, keep-alive, ...), plus OLLAMA_HOST and its LAN firewall block.
                        A value you had set yourself before the first install (this toolkit
                        version or later) is put back instead. The firewall block stays while the
                        running Ollama still listens on the network: restart Ollama, run this again.

    Exit code 0: finished. 1: stopped before anything was removed. 2: a step failed, or something
    could not be removed because Docker Desktop (the containers) or Ollama (the models, with
    -RemoveModels) was not running; the last lines name it. Start that program and run the
    uninstaller again: it removes only what is still there. Tuned aliases alone, left because
    Ollama was not running, are listed as kept and do not make it 2. While a run asks for another
    one that changes Ollama's settings or models, -RemoveData keeps install-state.json and
    localai-config.json for it (your own Ollama settings from before the install are read from
    there); that run deletes them.

.EXAMPLE
    .\Uninstall-LocalAI.ps1 -WhatIf        # show what would happen
.EXAMPLE
    .\Uninstall-LocalAI.ps1                # remove the stack, keep data and models
.EXAMPLE
    .\Uninstall-LocalAI.ps1 -RemoveData -RemoveModels -ResetOllamaSettings -Force
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    [switch]$RemoveData,
    [switch]$RemoveModels,
    [switch]$ResetOllamaSettings,
    # Skip the final backup (with -RemoveData the chats are then gone for good).
    [switch]$NoBackup,
    [switch]$Force,
    # Ollama to remove the aliases (and with -RemoveModels the models) from; '' = OllamaUrl from localai-config.json, else 127.0.0.1:11434.
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
# What this run cannot remove because the program it needs is not running, and which program that
# is. Named in the plan and again at the end: the run then ends 'Not finished' with exit 2.
$left = @()
$startFirst = @()

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
# Without the engine there is no final backup and the data volume stays, but -RemoveData would
# still delete Secrets: the stored admin password for data that is still there. Refuse instead.
$dockerInstalled = [bool](Get-Command docker -ErrorAction SilentlyContinue)
if (-not $dockerInstalled) { $dockerInstalled = [bool](Find-LaiDockerDesktopExe) }
if ($RemoveData -and -not $dockerUp -and $dockerInstalled -and $WhatIfPreference) {
    Write-LaiLog WARN 'Docker is not running: without -WhatIf, -RemoveData would refuse until Docker Desktop is started.'
} elseif ($RemoveData -and -not $dockerUp -and $dockerInstalled) {
    Write-LaiLog FAIL 'Docker is not running, so the final backup cannot be taken and the Open WebUI data cannot be removed. Start Docker Desktop, wait until it says "Engine running", then run this again. Nothing was removed.'
    exit 1
}
# Docker is installed but closed: its containers cannot be removed in this run (the data volume is
# either kept anyway or, with -RemoveData, refused above).
$dockerDown = ($dockerInstalled -and -not $dockerUp)
if ($dockerDown) { $left += 'containers open-webui, searxng, render-guard (Docker is not running)'; $startFirst += 'Docker Desktop' }
# Ollama is asked once, before the plan, so the plan already says what cannot be removed.
$ollamaUp = $true
try { $names = @(Get-LaiOllamaModelNames -BaseUrl $OllamaUrl) } catch { $ollamaUp = $false; $names = @() }
$modelsNow = ($RemoveModels -and $ollamaUp)
$aliases = 'tuned Ollama aliases localai-*'
if ($RemoveModels -and -not $ollamaUp) { $left += "$aliases and downloaded models from the catalog (Ollama is not answering at $OllamaUrl)"; $startFirst += 'Ollama' }

# ---- plan + confirmation ------------------------------------------------------------------------
$plan = @('scheduled tasks (backup, health watch, install resume)', 'Tailscale mapping to Open WebUI (if any)')
if (-not $dockerDown) { $plan += 'containers open-webui, searxng, render-guard' }
if ($ollamaUp) { $plan += $aliases }
$plan += 'shortcuts (desktop ComfyUI, Start-menu Local AI folder)'
$kept = @()
if ($RemoveData) { $plan += 'Open WebUI data volume (chats, memories, knowledge) and C:\AI stack/scripts/secrets/logs' } else { $kept += 'Open WebUI data volume (re-run Install-LocalAI.ps1 and everything comes back)' }
if ($modelsNow) { $plan += 'downloaded models from the catalog' } elseif (-not $RemoveModels) { $kept += 'downloaded models' }
# The aliases alone (about 0 GB) are named as kept and do not make the run 'Not finished': a PC
# whose Ollama was uninstalled first could then never finish.
if (-not $ollamaUp -and -not $RemoveModels) { $kept += "$aliases (Ollama is not answering at $OllamaUrl; to remove them, start Ollama and run the uninstaller again)" }
if ($ResetOllamaSettings) { $plan += 'OLLAMA_* user variables set by the installer (+ OLLAMA_HOST firewall rule)' } else { $kept += 'Ollama settings' }
$kept += "backups in $(Join-Path $AIRoot 'Backups')"
# The rules file for an AI coding agent (written by the installer, edited by the owner) is not in the list of what -RemoveData deletes.
if (Test-Path -LiteralPath (Join-Path $AIRoot 'CLAUDE.md') -PathType Leaf) { $kept += "CLAUDE.md in $AIRoot (the rules for an AI coding agent)" }
Write-LaiLog STEP 'Uninstall plan'
foreach ($p in $plan) { Write-LaiLog INFO "remove: $p" }
foreach ($k in $kept) { Write-LaiLog INFO "keep:   $k" }
foreach ($l in $left) { Write-LaiLog WARN "cannot remove in this run: $l" }
if (-not $Force -and -not $WhatIfPreference) {
    $answer = Read-Host 'Type YES to continue'
    if ($answer -cne 'YES') { Write-LaiLog INFO 'Nothing changed.'; exit 1 }
}

# ---- 1. final backup ----------------------------------------------------------------------------
$researchBefore = @(Get-ChildItem -LiteralPath (Join-Path $AIRoot 'Backups') -Filter 'deep-research-*-pre-uninstall.tar.gz' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
if (-not $NoBackup -and $volumeExists) {
    if ($PSCmdlet.ShouldProcess('Open WebUI volume', 'Final backup')) {
        & (Join-Path $PSScriptRoot 'Backup-OpenWebUI.ps1') -AIRoot $AIRoot -Tag 'pre-uninstall' -NoPrune
        if ($LASTEXITCODE -ne 0) {
            throw "The final backup failed, so nothing was removed. The reason is in $(Join-Path (Join-Path $AIRoot 'Logs') 'backup.log') (most often: Docker Desktop is not running, or the disk is full). Fix that, then run the uninstaller again."
        }
    }
} elseif ($RemoveData -and $volumeExists -and $NoBackup) {
    Write-LaiLog WARN 'Deleting the data volume WITHOUT a final backup (-NoBackup).'
}

# ---- 2. scheduled tasks -------------------------------------------------------------------------
if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
    foreach ($t in @('LocalAI-Backup-OpenWebUI', 'LocalAI-Watch', 'LocalAI-Recheck-Models', 'LocalAI-Install-Resume')) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Invoke-Step "scheduled task $t" { Unregister-ScheduledTask -TaskName $t -Confirm:$false; Write-LaiLog OK "Removed scheduled task $t" }
        }
    }
}

# ---- 3. Tailscale -------------------------------------------------------------------------------
# Before the containers are removed, never after: -Disable recreates Open WebUI ('compose up') to
# take the phone's address off its allowed list. Run after the removal, that brought the stack back
# with restart: always, and after -RemoveData on an empty volume with no account, where the first
# visitor becomes the administrator. The script now leaves a missing container alone as well; this
# order does not rely on it.
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

# ---- 4. containers ------------------------------------------------------------------------------
if ($dockerUp) {
    Invoke-Step 'containers' {
        if (Test-Path -LiteralPath $compose) {
            $r = Invoke-Docker @('compose', '--project-directory', $stackDir, '-f', $compose, 'down', '--remove-orphans')
            if ($r.ExitCode -ne 0) { Write-LaiLog WARN "docker compose down: $($r.Text)" }
        }
        # Also catch containers whose compose file is gone or that were renamed by hand.
        foreach ($c in @('open-webui', 'searxng', 'render-guard', 'deep-research')) {
            if ((Invoke-Docker @('container', 'inspect', $c)).ExitCode -eq 0) {
                $r = Invoke-Docker @('rm', '-f', '-v', $c)   # -v: anonymous volumes only; named data volumes stay
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
    # The optional research agent's saved research (Install-LocalAI.ps1 -DeepResearch).
    # Deleted only once this run's final backup holds it (the final backup fails when it could not save
    # it); with no Open WebUI volume there was no final backup run at all, so it is kept.
    $researchSaved = @(Get-ChildItem -LiteralPath (Join-Path $AIRoot 'Backups') -Filter 'deep-research-*-pre-uninstall.tar.gz' -ErrorAction SilentlyContinue | Where-Object { $researchBefore -notcontains $_.Name }).Count -gt 0
    $researchVolume = $RemoveData -and (Invoke-Docker @('volume', 'inspect', 'localai-deep-research')).ExitCode -eq 0
    if ($researchVolume -and -not $NoBackup -and -not $researchSaved) {
        Write-LaiLog WARN "Kept the deep research data volume (localai-deep-research): no final backup of it was made in this run (see Logs\backup.log). To delete it anyway, run the uninstaller again with -RemoveData -NoBackup."
    } elseif ($researchVolume) {
        Invoke-Step 'deep research volume' {
            $r = Invoke-Docker @('volume', 'rm', 'localai-deep-research')
            if ($r.ExitCode -ne 0) { throw $r.Text }
            Write-LaiLog OK 'Deep research data volume deleted'
        }
    }
} else {
    Write-LaiLog WARN 'Docker engine is not running: containers and the data volume were left in place. Start Docker Desktop and re-run to remove them.'
}

# ---- 5. Ollama aliases / models / settings --------------------------------------------------------
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

# OLLAMA_MODELS goes only with the models: while they are still there (Ollama did not answer), the
# next run finds them through it.
if ($onWindows -and ($ResetOllamaSettings -or $modelsNow)) {
    $vars = @()
    if ($ResetOllamaSettings) {
        $vars += 'OLLAMA_FLASH_ATTENTION', 'OLLAMA_KV_CACHE_TYPE', 'OLLAMA_NUM_PARALLEL', 'OLLAMA_MAX_LOADED_MODELS', 'OLLAMA_GPU_OVERHEAD',
            'OLLAMA_KEEP_ALIVE', 'OLLAMA_NO_CLOUD', 'OLLAMA_IGPU_ENABLE', 'OLLAMA_HOST'
    }
    if ($modelsNow) { $vars += 'OLLAMA_MODELS' }
    # A value the user had before the install (for other Ollama clients) goes back instead of away.
    $prevEnv = @{}
    $instState = Read-LaiState -Path (Join-Path $AIRoot 'install-state.json')
    if ($instState['flags'] -is [hashtable] -and $instState['flags']['prevOllamaEnv'] -is [hashtable]) { $prevEnv = $instState['flags']['prevOllamaEnv'] }
    foreach ($step in (Get-LaiEnvResetPlan -Names $vars -Saved $prevEnv)) {
        $v = $step.Name; $old = $step.Value
        $cur = [Environment]::GetEnvironmentVariable($v, 'User')
        if ($old) {
            if ($cur -ne $old) { Invoke-Step "user variable $v" { [Environment]::SetEnvironmentVariable($v, $old, 'User'); Write-LaiLog OK "Put back your own $v=$old (from before the install)" } }
        } elseif ($cur) {
            Invoke-Step "user variable $v" { [Environment]::SetEnvironmentVariable($v, $null, 'User'); Write-LaiLog OK "Removed user variable $v" }
        }
    }
    Write-LaiLog INFO 'Quit Ollama from the tray and start it again so it picks up the changed settings.'
}
# The firewall block only exists because Ollama listened on all interfaces; drop it with OLLAMA_HOST.
# But not yet while something still listens on 11434 beyond loopback: the running Ollama keeps the
# address it started with until it is restarted, and without the rule every device on the network
# could reach it.
$blockRule = 'LocalAI - Block Ollama from LAN'
$ruleKept = $false
if ($ResetOllamaSettings -and (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
    if (Get-NetFirewallRule -DisplayName $blockRule -ErrorAction SilentlyContinue) {
        # 'Could not be read' is not 'nothing listens': the rule goes only when the list was read and
        # shows nothing on 11434 beyond loopback. All listeners are asked for and filtered here (asking
        # for the one port is an error when nothing listens on it); a missing cmdlet is caught as well.
        $why = ''; $after = ''
        try {
            $rows = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_ -and $_.LocalPort -eq 11434 })
            $set = ConvertTo-LaiListenerSet -Connections $rows
            if (@($set | Where-Object { $_['Network'] }).Count -gt 0) { $why = 'port 11434 is still open beyond this PC (the running Ollama keeps listening there until it is restarted)' }
        } catch {
            $why = "this PC's list of listening ports could not be read ($($_.Exception.Message)), so it is not known whether Ollama still listens on the network"
            $after = ' If this message comes back after that, the rule can stay: all it does is keep other devices away from port 11434.'
        }
        if ($why) {
            $ruleKept = $true
            Write-LaiLog WARN "The firewall rule '$blockRule' stays for now: $why, and without the rule other devices on your network could use it. Quit Ollama from its tray icon, start it again, then run this once more.$after"
            $kept += "firewall rule '$blockRule' (until Ollama is restarted; then run this once more)"
        } else {
            Invoke-Step 'firewall rule' { Remove-NetFirewallRule -DisplayName $blockRule; Write-LaiLog OK 'Removed firewall rule' }
        }
    }
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
    $dlDir = Join-Path $env:ProgramFiles 'LocalAI-Downloads'
    if (Test-Path -LiteralPath $dlDir) { Invoke-Step $dlDir { Remove-LaiTree -Path $dlDir; Write-LaiLog OK "Deleted $dlDir" } }
    if (Test-Path -LiteralPath $elevated) { Invoke-Step $elevated { Remove-LaiTree -Path $elevated; Write-LaiLog OK "Deleted $elevated" } }
}
if ($env:ProgramData) {
    $menu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Local AI'
    if (Test-Path -LiteralPath $menu) { Invoke-Step 'Start-menu folder' { Remove-LaiTree -Path $menu; Write-LaiLog OK "Removed Start-menu folder 'Local AI'" } }
}

if ($RemoveData) {
    $here = (Resolve-Path -LiteralPath $PSScriptRoot).Path
    # This run asks for another one (Ollama did not answer, or the firewall rule waits for Ollama's
    # restart). When that run changes Ollama's settings or models it reads two files: your own
    # Ollama settings from before the install, and Ollama's address. Deleted now, it would remove
    # the settings this run has just put back. So they stay, and that run deletes them.
    $again = ($left.Count -gt 0 -or -not $ollamaUp -or $ruleKept)
    $forNextRun = @()
    if ($again -and ($ResetOllamaSettings -or $RemoveModels)) { foreach ($j in 'install-state.json', 'localai-config.json') { $forNextRun += @($j, "$j.bak") } }
    $stay = @($forNextRun | Where-Object { Test-Path -LiteralPath (Join-Path $AIRoot $_) })
    if ($stay.Count -gt 0) { $kept += "$($stay -join ', ') in $AIRoot (the next run reads them, then deletes them)" }
    $stateFiles = @()
    foreach ($j in 'install-state.json', 'localai-config.json', 'watch-state.json', 'backup-state.json', 'model-recheck.json', 'integrity-baseline.json') { $stateFiles += @($j, "$j.bak", "$j.bad", "$j.tmp") }
    foreach ($item in (@('Stack', 'Secrets', 'Logs', 'Downloads', 'install-report.md', 'open-webui-hold.json') + $stateFiles)) {
        if ($forNextRun -contains $item) { continue }
        $path = Join-Path $AIRoot $item
        if (-not (Test-Path -LiteralPath $path)) { continue }
        # Never Remove-Item -Recurse here: this runs as administrator in a folder the user controls,
        # and Windows PowerShell 5.1 follows junctions inside it (deleting whatever they point at).
        Invoke-Step $path { Remove-LaiTree -Path $path; Write-LaiLog OK "Deleted $path" }
    }
    # The running script lives in AIRoot\Scripts when started from there: delete it last, or tell the user.
    $scripts = Join-Path $AIRoot 'Scripts'
    if (Test-Path -LiteralPath $scripts) {
        $scriptsFull = (Resolve-Path -LiteralPath $scripts).Path
        if ($here -eq $scriptsFull -or $here.StartsWith($scriptsFull + [IO.Path]::DirectorySeparatorChar)) {
            Write-LaiLog INFO "Delete $scripts yourself after this window closes (this script is running from it)."
        } else {
            Invoke-Step $scripts { Remove-LaiTree -Path $scripts; Write-LaiLog OK "Deleted $scripts" }
        }
    }
}

if ($problems.Count -gt 0) {
    Write-LaiLog WARN "Finished with $($problems.Count) problem(s):"
    foreach ($p in $problems) { Write-LaiLog WARN "  $p" }
    Write-LaiLog INFO 'Next step: fix what these lines name, then run the uninstaller again. It removes only what is still there.'
}
# Under -WhatIf nothing was attempted: the plan above already names what a real run would leave.
$unfinished = ($left.Count -gt 0 -and -not $WhatIfPreference)
if ($problems.Count -eq 0 -and $left.Count -eq 0) { Write-LaiLog OK 'Uninstall finished.' }
# Also before a 'Not finished': the files kept for the run it asks for are named here.
foreach ($k in $kept) { Write-LaiLog INFO "kept: $k" }
if ($unfinished) { Write-LaiLog WARN "Not finished: $($left -join '; '). Start $($startFirst -join ' and '), then run the uninstaller again with the same options." }
if ($problems.Count -gt 0 -or $unfinished) { exit 2 }
exit 0
