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
    .\Update-OpenWebUI.ps1 -Version v0.11.4 -SkipBackup   # roll back the image, then restore the
                                                         # 'before-<version>' backup it printed:
    .\Restore-OpenWebUI.ps1 -Archive C:\AI\Backups\open-webui-<timestamp>-before-<version>.tar.gz
#>
param(
    [string]$AIRoot = 'C:\AI',
    [string]$Version = '',
    [switch]$Latest,
    [string]$SearxngVersion = '',
    [switch]$SkipBackup
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$stack = Join-Path $AIRoot 'Stack'
$envPath = Join-Path $stack '.env'
$compose = Join-Path $stack 'docker-compose.yml'
if (-not (Test-Path -LiteralPath $envPath)) { throw "No stack found at $stack. Run Install-LocalAI.ps1 first." }

function Invoke-Docker {
    param([string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker @Arguments; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw "docker $($Arguments -join ' ') failed with exit code $code" }
}

if ($Latest) {
    $Version = (Invoke-RestMethod -Uri 'https://api.github.com/repos/open-webui/open-webui/releases/latest' -UseBasicParsing).tag_name
    Write-LaiLog INFO "Latest Open WebUI release: $Version"
}

$lines = @(Get-Content -LiteralPath $envPath)
$current = ($lines | Where-Object { $_ -like 'OPEN_WEBUI_VERSION=*' } | Select-Object -First 1) -replace '^OPEN_WEBUI_VERSION=', ''
if ($Version -and $Version -eq $current -and -not $SearxngVersion) { Write-LaiLog OK "Already on $current"; exit 0 }

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
        if ($pre) {
            Write-LaiLog INFO ("To roll back later: Update-OpenWebUI.ps1 -Version {0} -SkipBackup, then Restore-OpenWebUI.ps1 -Archive '{1}'" -f $current, $pre.FullName)
        }
    }

    $new = foreach ($l in $lines) {
        if ($Version -and $l -like 'OPEN_WEBUI_VERSION=*') { "OPEN_WEBUI_VERSION=$Version" }
        elseif ($SearxngVersion -and $l -like 'SEARXNG_VERSION=*') { "SEARXNG_VERSION=$SearxngVersion" }
        else { $l }
    }
    [System.IO.File]::WriteAllLines($envPath, [string[]]$new, (New-Object System.Text.UTF8Encoding($false)))

    $base = @('compose', '--project-directory', $stack, '-f', $compose)
    Invoke-Docker -Arguments ($base + @('pull'))
    Invoke-Docker -Arguments ($base + @('up', '-d', '--remove-orphans'))
} finally { Exit-LaiVolumeLock $lock }

$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$port = 3000; if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
if ($Version) { $config['OpenWebUIVersion'] = $Version; Save-LaiState -State $config -Path (Join-Path $AIRoot 'localai-config.json') }
Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec 600
$running = (Invoke-LaiApi -Uri "http://127.0.0.1:$port/api/version").version
Write-LaiLog OK "Open WebUI $running is up on http://localhost:$port"

& (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick
exit $LASTEXITCODE
