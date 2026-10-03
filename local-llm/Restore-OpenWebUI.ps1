#Requires -Version 5.1
<#
.SYNOPSIS
    Restores an Open WebUI backup archive (made by Backup-OpenWebUI.ps1) into the open-webui volume.

.DESCRIPTION
    1. Picks the archive (newest in <AIRoot>\Backups unless -Archive is given) and checks it contains webui.db.
    2. Takes a safety backup of the current volume (tag "pre-restore"), so a restore can itself be undone.
    3. Stops the open-webui container, replaces the volume contents with the archive, starts it again
       and waits until Open WebUI answers.

    Chats, memories, users, presets, settings and uploaded documents return to the archive's state.
    Ollama models are not touched.

.EXAMPLE
    .\Restore-OpenWebUI.ps1                                   # newest backup
.EXAMPLE
    .\Restore-OpenWebUI.ps1 -Archive C:\AI\Backups\open-webui-20261002-175511.tar.gz
#>
param(
    [string]$AIRoot = 'C:\AI',
    [string]$Archive = '',
    [switch]$SkipSafetyBackup,
    [string]$Volume = 'open-webui',
    [string]$Container = 'open-webui',
    [string]$HelperImage = 'alpine:3.20'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

function Invoke-Docker {
    param([string[]]$Arguments, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& docker @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0 -and -not $AllowFail) { throw "docker $($Arguments -join ' ') failed ($code): $($out -join ' ')" }
    return [pscustomobject]@{ ExitCode = $code; Text = ($out -join "`n") }
}

# 1. Which archive?
if (-not $Archive) {
    $newest = Get-ChildItem -LiteralPath (Join-Path $AIRoot 'Backups') -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*-pre-restore.tar.gz' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
    if (-not $newest) { throw "No backups found in $(Join-Path $AIRoot 'Backups')." }
    $Archive = $newest.FullName
}
$item = Get-Item -LiteralPath $Archive
$dir = $item.DirectoryName
$name = $item.Name
$listing = (Invoke-Docker -Arguments @('run', '--rm', '-v', "${dir}:/backup:ro", $HelperImage, 'tar', 'tzf', "/backup/$name")).Text
if ($listing -notmatch 'webui\.db') { throw "$name does not look like an Open WebUI backup (no webui.db inside)." }
Write-LaiLog INFO ("Restoring {0} ({1:N1} MB, {2})" -f $name, ($item.Length / 1MB), $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))

# 2. Safety backup of what is there now.
$volumeExists = (Invoke-Docker -Arguments @('volume', 'inspect', $Volume) -AllowFail).ExitCode -eq 0
if ($volumeExists -and -not $SkipSafetyBackup) {
    & (Join-Path $PSScriptRoot 'Backup-OpenWebUI.ps1') -AIRoot $AIRoot -Volume $Volume -Container $Container -Tag 'pre-restore'
    if ($LASTEXITCODE -ne 0) { throw 'Safety backup failed; nothing was changed. Use -SkipSafetyBackup to restore anyway.' }
}
if (-not $volumeExists) { Invoke-Docker -Arguments @('volume', 'create', $Volume) | Out-Null }

# 3. Swap the contents with the container stopped.
$running = (Invoke-Docker -Arguments @('inspect', '-f', '{{.State.Running}}', $Container) -AllowFail).Text.Trim() -eq 'true'
if ($running) { Invoke-Docker -Arguments @('stop', '-t', '30', $Container) | Out-Null }
try {
    Invoke-Docker -Arguments @('run', '--rm', '-v', "${Volume}:/data", '-v', "${dir}:/backup:ro", $HelperImage,
        'sh', '-c', "find /data -mindepth 1 -delete && tar xzf '/backup/$name' -C /data") | Out-Null
} finally {
    if ($running) { Invoke-Docker -Arguments @('start', $Container) | Out-Null }
}
Write-LaiLog OK "Volume '$Volume' now holds $name"

# 4. Wait for Open WebUI (only if the container exists and was running).
if ($running) {
    $config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
    $port = 3000
    if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
    Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec 300
    Write-LaiLog OK "Open WebUI is back on http://localhost:$port"
}
Write-LaiLog INFO 'The admin login is whatever it was when that backup was taken; if C:\AI\Secrets\openwebui-admin.json no longer matches, run Set-OpenWebUIPassword.ps1 after signing in, or restore the matching secrets file.'
