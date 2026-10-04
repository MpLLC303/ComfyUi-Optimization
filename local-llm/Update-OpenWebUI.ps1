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
    $out = foreach ($l in @(Get-Content -LiteralPath $envPath)) {
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

if ($Rollback) {
    $prevVer = ''; $archive = ''
    if ($config.ContainsKey('PreviousOpenWebUIVersion')) { $prevVer = [string]$config['PreviousOpenWebUIVersion'] }
    if ($config.ContainsKey('RollbackArchive')) { $archive = [string]$config['RollbackArchive'] }
    if (-not $prevVer -or -not $archive -or -not (Test-Path -LiteralPath $archive)) {
        throw 'Nothing to roll back: no update with a backup is recorded (or its before-<version> backup is gone). Use Restore-OpenWebUI.ps1 -Archive <file> and Update-OpenWebUI.ps1 -Version <old> by hand.'
    }
    $cur = ((Get-Content -LiteralPath $envPath | Where-Object { $_ -like 'OPEN_WEBUI_VERSION=*' } | Select-Object -First 1) -replace '^OPEN_WEBUI_VERSION=', '')
    Write-UpdateLog WARN "Rollback: Open WebUI $cur -> $prevVer, and the data from $(Split-Path -Leaf $archive) (chats since that update are lost; a safety backup of the current data is taken first)."
    if (-not $Force -and (Read-Host 'Type YES to roll back') -cne 'YES') { Write-UpdateLog INFO 'Nothing changed.'; exit 1 }
    $lock = Enter-LaiVolumeLock -TimeoutSec 900
    try {
        # Old image first (it may not start on the migrated database; that is expected), then the
        # restore stops it, swaps in the pre-update data and starts it again.
        Set-EnvVersion -OpenWebUI $prevVer
        Invoke-Docker -Arguments ($base + @('pull', 'open-webui'))
        Invoke-Docker -Arguments ($base + @('up', '-d', 'open-webui'))
        & (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1') -AIRoot $AIRoot -Archive $archive -Force
        if ($LASTEXITCODE -ne 0) { throw "The restore step failed; see above. The stack is set to $prevVer." }
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

$lines = @(Get-Content -LiteralPath $envPath)
$current = ($lines | Where-Object { $_ -like 'OPEN_WEBUI_VERSION=*' } | Select-Object -First 1) -replace '^OPEN_WEBUI_VERSION=', ''
if ($Version -and $Version -eq $current -and -not $SearxngVersion) { Write-UpdateLog OK "Already on $current"; exit 0 }
$pre = $null

# Hold the volume lock for backup + swap, so the health watch does not restart the old container
# halfway through and a scheduled backup does not run against a half-replaced stack.
$lock = Enter-LaiVolumeLock -TimeoutSec 900
try {
    if (-not $SkipBackup) {
        $tag = "before-$($Version -replace '[^\w\.-]', '')"
        & (Join-Path $PSScriptRoot 'Backup-OpenWebUI.ps1') -AIRoot $AIRoot -Tag $tag
        if ($LASTEXITCODE -ne 0) { throw 'Backup failed; not updating. Use -SkipBackup to override.' }
        $pre = Get-ChildItem -LiteralPath (Join-Path $AIRoot 'Backups') -Filter "open-webui-*-$tag.tar.gz" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
    }

    Set-EnvVersion -OpenWebUI $Version -Searxng $SearxngVersion
    Invoke-Docker -Arguments ($base + @('pull'))
    Invoke-Docker -Arguments ($base + @('up', '-d', '--remove-orphans'))
} finally { Exit-LaiVolumeLock $lock }

if ($Version) {
    $config['OpenWebUIVersion'] = $Version
    if ($pre) { $config['PreviousOpenWebUIVersion'] = $current; $config['RollbackArchive'] = $pre.FullName }
    Save-LaiState -State $config -Path $configPath
}
Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec 600
$running = (Invoke-LaiApi -Uri "http://127.0.0.1:$port/api/version").version
Write-UpdateLog OK "Open WebUI $running is up on http://localhost:$port (was $current)"
if ($pre) { Write-UpdateLog INFO "If this version misbehaves: Update-OpenWebUI.ps1 -Rollback (back to $current with the data from $($pre.Name))" }

& (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick
exit $LASTEXITCODE
