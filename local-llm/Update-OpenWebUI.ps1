#Requires -Version 5.1
<#
.SYNOPSIS
    Backs up, then updates Open WebUI (and optionally SearXNG) to a newer pinned image.

.DESCRIPTION
    Replaces the guide's manual "docker pull / stop / rm / run" sequence (Part 23). Versions are pinned
    in <AIRoot>\Stack\.env, so nothing changes until you run this. Data lives in the "open-webui"
    volume and survives the container being recreated.

.EXAMPLE
    .\Update-OpenWebUI.ps1 -Latest              # newest GitHub release of Open WebUI
.EXAMPLE
    .\Update-OpenWebUI.ps1 -Version v0.11.5     # a specific release
.EXAMPLE
    .\Update-OpenWebUI.ps1 -Rollback           # undo the last update: previous image + the data from
                                                # just before it (the 'before-<version>' backup)
#>
param(
    [string]$AIRoot = 'C:\AI',
    [string]$Version = '',
    [switch]$Latest,
    [string]$SearxngVersion = '',
    [switch]$SkipBackup,
    # Undo the last update: switch back to the previous image and restore the backup taken right
    # before the update (Open WebUI migrates its database on upgrade, so the old image needs old data).
    [switch]$Rollback,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$stack = Join-Path $AIRoot 'Stack'
$envPath = Join-Path $stack '.env'
$compose = Join-Path $stack 'docker-compose.yml'
if (-not (Test-Path -LiteralPath $envPath)) { throw "No stack found at $stack. Run Install-LocalAI.ps1 first." }

$configPath = Join-Path $AIRoot 'localai-config.json'
$updateLog = Join-Path (Join-Path $AIRoot 'Logs') 'update.log'
function Write-UpdateLog {
    param([string]$Level, [string]$Message)
    Write-LaiLog $Level $Message
    try { Add-Content -LiteralPath $updateLog -Value ('{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message) } catch { Write-Verbose 'no update log' }
}
function Set-EnvVersion {
    param([string]$OpenWebUI, [string]$Searxng)
    $out = foreach ($l in @(Get-Content -Encoding UTF8 -LiteralPath $envPath)) {
        if ($OpenWebUI -and $l -like 'OPEN_WEBUI_VERSION=*') { "OPEN_WEBUI_VERSION=$OpenWebUI" }
        elseif ($Searxng -and $l -like 'SEARXNG_VERSION=*') { "SEARXNG_VERSION=$Searxng" }
        else { $l }
    }
    [System.IO.File]::WriteAllLines($envPath, [string[]]$out, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Docker {
    param([string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker @Arguments; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw "docker $($Arguments -join ' ') failed with exit code $code" }
}

$config = Read-LaiState -Path $configPath
$port = 3000; if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
$base = @('compose', '--project-directory', $stack, '-f', $compose)

$hold = Get-LaiWebUIHold -AIRoot $AIRoot
if ($hold) { throw "Open WebUI is kept stopped after a failed restore ($($hold['Reason'])); updating now would start it on damaged data. Recover first: $($hold['Recover'])" }

if ($Rollback) {
    $prevVer = ''; $archive = ''
    if ($config.ContainsKey('PreviousOpenWebUIVersion')) { $prevVer = [string]$config['PreviousOpenWebUIVersion'] }
    if ($config.ContainsKey('RollbackArchive')) { $archive = [string]$config['RollbackArchive'] }
    if (-not $prevVer -or -not $archive -or -not (Test-Path -LiteralPath $archive)) {
        throw 'Nothing to roll back: no update with a backup is recorded (or its before-<version> backup is gone). Use Restore-OpenWebUI.ps1 -Archive <file> and Update-OpenWebUI.ps1 -Version <old> by hand.'
    }
    $cur = ((Get-Content -Encoding UTF8 -LiteralPath $envPath | Where-Object { $_ -like 'OPEN_WEBUI_VERSION=*' } | Select-Object -First 1) -replace '^OPEN_WEBUI_VERSION=', '')
    Write-UpdateLog WARN "Rollback: Open WebUI $cur -> $prevVer, and the data from $(Split-Path -Leaf $archive) (chats since that update are lost; a safety backup of the current data is taken first)."
    if (-not $Force -and (Read-Host 'Type YES to roll back') -cne 'YES') { Write-UpdateLog INFO 'Nothing changed.'; exit 1 }
    $lock = Enter-LaiVolumeLock -TimeoutSec 900
    try {
        # Again under the lock: a restore that held it while this waited may have failed meanwhile.
        $hold = Get-LaiWebUIHold -AIRoot $AIRoot
        if ($hold) { throw "Open WebUI is kept stopped after a failed restore ($($hold['Reason'])). Recover first: $($hold['Recover'])" }
        # Old image first (it may not start on the migrated database; that is expected), then the
        # restore stops it, swaps in the pre-update data and starts it again.
        $envBefore = @(Get-Content -Encoding UTF8 -LiteralPath $envPath)
        Set-EnvVersion -OpenWebUI $prevVer
        try { Invoke-Docker -Arguments ($base + @('pull', '--policy', (Get-LaiPullPolicy -Tags @($prevVer)), 'open-webui')) }
        catch {
            # Leave .env on the version that is running: otherwise the next Start again or installer
            # run would start the old image on the already-migrated database.
            [System.IO.File]::WriteAllLines($envPath, [string[]]$envBefore, (New-Object System.Text.UTF8Encoding($false)))
            throw "Could not download Open WebUI $prevVer, nothing was changed: $($_.Exception.Message)"
        }
        Invoke-Docker -Arguments ($base + @('up', '-d', 'open-webui'))
        & (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1') -AIRoot $AIRoot -Archive $archive -Force
        if ($LASTEXITCODE -ne 0) {
            # The volume still holds the data the current version migrated (the restore rolled back, or
            # holds Open WebUI down): go back to the current version, never the old image on that data.
            [System.IO.File]::WriteAllLines($envPath, [string[]]$envBefore, (New-Object System.Text.UTF8Encoding($false)))
            if (Get-LaiWebUIHold -AIRoot $AIRoot) {
                throw "The restore step failed; see above. The version setting is back on $cur. After the recovery command above, use Start menu > Local AI > Start again."
            }
            Invoke-Docker -Arguments ($base + @('up', '-d', 'open-webui'))
            throw "The restore step failed and was undone; Open WebUI $cur is running again on its current data."
        }
    } finally { Exit-LaiVolumeLock $lock }
    $config['OpenWebUIVersion'] = $prevVer
    $config.Remove('PreviousOpenWebUIVersion'); $config.Remove('RollbackArchive')
    Save-LaiState -State $config -Path $configPath
    Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec 600
    Write-UpdateLog OK "Rolled back to Open WebUI $((Invoke-LaiApi -Uri "http://127.0.0.1:$port/api/version").version)"
    & (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick
    exit $LASTEXITCODE
}

if ($Latest) {
    $Version = (Invoke-RestMethod -Uri 'https://api.github.com/repos/open-webui/open-webui/releases/latest' -UseBasicParsing).tag_name
    Write-UpdateLog INFO "Latest Open WebUI release: $Version"
}

$lines = @(Get-Content -Encoding UTF8 -LiteralPath $envPath)
$current = ($lines | Where-Object { $_ -like 'OPEN_WEBUI_VERSION=*' } | Select-Object -First 1) -replace '^OPEN_WEBUI_VERSION=', ''
if (-not $Version -and -not $SearxngVersion) { Write-UpdateLog INFO 'Nothing to do: pass -Latest, -Version <tag> or -SearxngVersion <tag> (or -Rollback).'; exit 0 }
if ($Version -and $Version -eq $current) {
    if (-not $SearxngVersion) { Write-UpdateLog OK "Already on $current"; exit 0 }
    $Version = ''   # SearXNG-only: leave Open WebUI and its rollback point alone
}
$pre = $null
$configBefore = Read-LaiState -Path $configPath

# Hold the volume lock for backup + swap, so the health watch does not restart the old container
# halfway through and a scheduled backup does not run against a half-replaced stack.
$lock = Enter-LaiVolumeLock -TimeoutSec 900
try {
    # Again under the lock: a restore that held it while this waited may have failed meanwhile.
    $hold = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($hold) { throw "Open WebUI is kept stopped after a failed restore ($($hold['Reason'])). Recover first: $($hold['Recover'])" }
    if (-not $SkipBackup) {
        if ($Version) { $tag = "before-$($Version -replace '[^\w\.-]', '')" } else { $tag = "before-searxng-$($SearxngVersion -replace '[^\w\.-]', '')" }
        & (Join-Path $PSScriptRoot 'Backup-OpenWebUI.ps1') -AIRoot $AIRoot -Tag $tag
        if ($LASTEXITCODE -ne 0) { throw 'Backup failed; not updating. Use -SkipBackup to override.' }
        $pre = Get-ChildItem -LiteralPath (Join-Path $AIRoot 'Backups') -Filter "open-webui-*-$tag.tar.gz" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
    }
    if ($Version) {
        # Record the rollback point now, not after success: if anything below fails, -Rollback must work.
        if ($pre) { $config['PreviousOpenWebUIVersion'] = $current; $config['RollbackArchive'] = $pre.FullName }
        else { [void]$config.Remove('PreviousOpenWebUIVersion'); [void]$config.Remove('RollbackArchive') }
        Save-LaiState -State $config -Path $configPath
    }

    # The revert lives in 'finally' so it also runs when the multi-GB download is cancelled with
    # Ctrl+C (PowerShell skips 'catch' then). Without it, the next Start again would quietly pull
    # and run the new version outside this script.
    $pulled = $false
    try {
        Set-EnvVersion -OpenWebUI $Version -Searxng $SearxngVersion
        # Pinned versions already on disk are reused (no registry, no Docker Hub rate limit);
        # floating tags (main, latest) are re-pulled.
        $envNow = @{}
        foreach ($l in (Get-Content -Encoding UTF8 -LiteralPath $envPath)) { if ($l -match '^([A-Z_]+)=(.*)$') { $envNow[$Matches[1]] = $Matches[2] } }
        Invoke-Docker -Arguments ($base + @('pull', '--policy', (Get-LaiPullPolicy -Tags @($envNow['OPEN_WEBUI_VERSION'], $envNow['SEARXNG_VERSION']))))
        $pulled = $true
    } catch {
        throw "Could not pull the new image(s), nothing was changed: $($_.Exception.Message)"
    } finally {
        if (-not $pulled) {
            [System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
            Save-LaiState -State $configBefore -Path $configPath
        }
    }
    try { Invoke-Docker -Arguments ($base + @('up', '-d', '--remove-orphans')) }
    catch { if ($pre -and $Version) { throw "$($_.Exception.Message). Undo the update with: Update-OpenWebUI.ps1 -Rollback" } else { throw } }
} finally { Exit-LaiVolumeLock $lock }

if ($Version) {
    $config['OpenWebUIVersion'] = $Version
    Save-LaiState -State $config -Path $configPath
}
try { Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec 600 }
catch {
    if ($pre -and $Version) { throw "Open WebUI $Version did not come up ($($_.Exception.Message)). Check 'docker logs --tail 80 open-webui', or undo with: Update-OpenWebUI.ps1 -Rollback" }
    throw
}
$running = (Invoke-LaiApi -Uri "http://127.0.0.1:$port/api/version").version
Write-UpdateLog OK "Open WebUI $running is up on http://localhost:$port (was $current)"
if ($pre -and $Version) { Write-UpdateLog INFO "If this version misbehaves: Update-OpenWebUI.ps1 -Rollback (back to $current with the data from $($pre.Name))" }

& (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick
exit $LASTEXITCODE
