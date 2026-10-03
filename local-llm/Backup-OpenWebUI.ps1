#Requires -Version 5.1
<#
.SYNOPSIS
    Consistent backup of the Open WebUI data volume (users, chats, memories, presets, settings,
    uploaded documents and their vector index).

.DESCRIPTION
    Stops the open-webui container for a few seconds so SQLite and the vector store are not copied
    mid-write, archives the "open-webui" Docker volume to <AIRoot>\Backups\open-webui-<timestamp>.tar.gz,
    restarts the container, verifies the archive, prunes old archives and optionally mirrors the newest
    one to a second location. The installer schedules this daily.

    The models are not backed up (re-download them). Secrets live in <AIRoot>\Secrets: keep a copy of
    that folder in your password manager, not next to the backups.

.EXAMPLE
    .\Backup-OpenWebUI.ps1                     # uses C:\AI\localai-config.json settings
    .\Backup-OpenWebUI.ps1 -Mirror E:\Backups  # also copy the newest archive to E:
#>
param(
    [string]$AIRoot = 'C:\AI',
    # 0 = take the value from localai-config.json (14 days if not set).
    [int]$RetentionDays = 0,
    # Optional second copy (another drive, NAS share). '' = take it from localai-config.json.
    [string]$Mirror = '',
    [string]$Tag = '',
    # Archive the running container instead of stopping it (used before replacing a manual install).
    [switch]$NoStop,
    # Used by Restore-OpenWebUI.ps1: never delete or mirror anything while a restore is in progress.
    [switch]$NoPrune,
    [switch]$NoMirror,
    [string]$Volume = 'open-webui',
    [string]$Container = 'open-webui',
    [string]$HelperImage = 'alpine:3.20',
    # Deep check: open the archived webui.db with SQLite (integrity_check + user/chat counts) in a
    # throwaway volume. Uses an image that is already local (Open WebUI's own) so nothing is downloaded.
    [switch]$SkipDeepVerify,
    [string]$VerifyImage = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$backupDir = Join-Path $AIRoot 'Backups'
$logDir = Join-Path $AIRoot 'Logs'
foreach ($d in @($backupDir, $logDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
$logFile = Join-Path $logDir 'backup.log'

function Write-BackupLog {
    param([string]$Level, [string]$Message)
    Write-LaiLog $Level $Message
    Add-Content -LiteralPath $logFile -Value ('{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message)
}

function Invoke-Docker {
    param([string[]]$Arguments, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& docker @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0 -and -not $AllowFail) { throw "docker $($Arguments -join ' ') failed ($code): $($out -join ' ')" }
    return [pscustomobject]@{ ExitCode = $code; Text = ($out -join "`n") }
}

$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
if ($RetentionDays -le 0) {
    $RetentionDays = 14
    if ($config.ContainsKey('BackupRetentionDays') -and [int]$config['BackupRetentionDays'] -gt 0) { $RetentionDays = [int]$config['BackupRetentionDays'] }
}
if (-not $Mirror -and $config.ContainsKey('BackupMirror') -and $config['BackupMirror']) { $Mirror = [string]$config['BackupMirror'] }

$suffix = ''
if ($Tag) { $suffix = "-$Tag" }
$name = 'open-webui-{0}{1}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $suffix
$archive = Join-Path $backupDir $name
$stopped = $false
$exitCode = 0

$lock = $null
try {
    $lock = Enter-LaiVolumeLock
    if ((Invoke-Docker -Arguments @('volume', 'inspect', $Volume) -AllowFail).ExitCode -ne 0) { throw "Docker volume '$Volume' does not exist." }
    $running = (Invoke-Docker -Arguments @('inspect', '-f', '{{.State.Running}}', $Container) -AllowFail).Text.Trim() -eq 'true'
    if ($running -and -not $NoStop) {
        Invoke-Docker -Arguments @('stop', '-t', '30', $Container) | Out-Null
        $stopped = $true
    }
    try {
        Invoke-Docker -Arguments @('run', '--rm', '-v', "${Volume}:/data:ro", '-v', "${backupDir}:/backup", $HelperImage,
            'tar', 'czf', "/backup/$name", '-C', '/data', '.') | Out-Null
    } finally {
        if ($stopped) { Invoke-Docker -Arguments @('start', $Container) | Out-Null }
    }

    $size = (Get-Item -LiteralPath $archive).Length
    $listing = (Invoke-Docker -Arguments @('run', '--rm', '-v', "${backupDir}:/backup:ro", $HelperImage, 'tar', 'tzf', "/backup/$name")).Text
    if ($size -lt 100 -or $listing -notmatch '(?m)^(\./)?webui\.db\s*$') { throw "Archive $name looks incomplete ($size bytes, webui.db missing)." }
    $verified = ''
    if (-not $SkipDeepVerify) {
        if (-not $VerifyImage) {
            $ver = 'v0.11.4'
            $envFile = Join-Path (Join-Path $AIRoot 'Stack') '.env'
            if (Test-Path -LiteralPath $envFile) {
                $line = Get-Content -LiteralPath $envFile | Where-Object { $_ -like 'OPEN_WEBUI_VERSION=*' } | Select-Object -First 1
                if ($line) { $ver = $line.Substring(19) }
            }
            $VerifyImage = "ghcr.io/open-webui/open-webui:$ver"
        }
        # webui.db plus its WAL/SHM files if present (a live -NoStop backup can hold recent rows only in the WAL).
        if ((Invoke-Docker -Arguments @('image', 'inspect', $VerifyImage) -AllowFail).ExitCode -ne 0) {
            # Never pull a multi-GB image from a scheduled task; just say the deep check was skipped.
            Write-BackupLog WARN "Deep check skipped: image $VerifyImage is not present locally."
            $SkipDeepVerify = $true
        }
    }
    if (-not $SkipDeepVerify) {
        $members = @([regex]::Matches($listing, '(?m)^(\./)?webui\.db(-wal|-shm)?\s*$') | ForEach-Object { $_.Value.Trim() })
        $scratch = 'localai-verify-' + (Get-Date -Format 'yyyyMMddHHmmss')
        Invoke-Docker -Arguments @('volume', 'create', $scratch) | Out-Null
        try {
            $extract = @('run', '--rm', '-v', "${scratch}:/d", '-v', "${backupDir}:/backup:ro", $HelperImage, 'tar', 'xzf', "/backup/$name", '-C', '/d') + $members
            Invoke-Docker -Arguments $extract | Out-Null
            # Single quotes only inside the Python code: PS 5.1 mangles double quotes in native arguments.
            $py = "import sqlite3;c=sqlite3.connect('/d/webui.db');" +
                "r=c.execute('pragma integrity_check').fetchone()[0];" +
                "n=lambda t:c.execute('select count(*) from '+t).fetchone()[0];" +
                "print(r,n('user'),n('chat'))"
            $run = Invoke-Docker -Arguments @('run', '--rm', '--entrypoint', 'python3', '-v', "${scratch}:/d", $VerifyImage, '-c', $py) -AllowFail
            $out = $run.Text.Trim()
            $parts = ($out -split '\s+')
            if ($run.ExitCode -ne 0 -or $parts[0] -ne 'ok') {
                # Keep it for inspection, but tagged so it never counts as one of the three protected daily backups.
                $bad = $archive -replace '\.tar\.gz$', '-CORRUPT.tar.gz'
                Move-Item -LiteralPath $archive -Destination $bad -Force
                $reason = ($out -split "`n" | Select-Object -Last 1)
                throw "Archive ${name}: webui.db failed the SQLite check ($reason). Kept as $(Split-Path -Leaf $bad). Your live data may be damaged: do not delete older backups."
            }
            $verified = "; database OK ($($parts[1]) users, $($parts[2]) chats)"
        } finally {
            Invoke-Docker -Arguments @('volume', 'rm', '-f', $scratch) -AllowFail | Out-Null
        }
    }
    Write-BackupLog OK ("Backup {0} ({1:N1} MB){2}{3}" -f $archive, ($size / 1MB), $(if ($stopped) { '; container was paused for consistency' } else { '' }), $verified)

    # Retention: daily (untagged) archives older than N days go, but the newest three daily ones always
    # stay. Tagged archives (pre-compose, pre-restore, before-<version>) never count toward those three.
    if (-not $NoPrune) {
        $all = @(Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz')
        $daily = @($all | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' } | Sort-Object LastWriteTime -Descending)  # lai-ok: objects
        $tagged = @($all | Where-Object { $_.Name -notmatch '^open-webui-\d{8}-\d{6}\.tar\.gz$' })
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        foreach ($old in (@($daily | Select-Object -Skip 3) + $tagged | Where-Object { $_.LastWriteTime -lt $cutoff -and $_.FullName -ne $archive })) {
            Remove-Item -LiteralPath $old.FullName -Force
            Write-BackupLog INFO "Pruned $($old.Name)"
        }
    }

    if ($Mirror -and -not $NoMirror) {
        try {
            if (-not (Test-Path -LiteralPath $Mirror)) { New-Item -ItemType Directory -Force -Path $Mirror | Out-Null }
            Copy-Item -LiteralPath $archive -Destination $Mirror -Force
            Write-BackupLog OK "Mirrored to $Mirror"
        } catch {
            # The local archive is complete and verified; an offline NAS must not fail the backup.
            Write-BackupLog WARN "Mirror copy to $Mirror failed: $($_.Exception.Message)"
        }
    }
} catch {
    Write-BackupLog FAIL $_.Exception.Message
    $exitCode = 1
} finally {
    Exit-LaiVolumeLock $lock
}
exit $exitCode
