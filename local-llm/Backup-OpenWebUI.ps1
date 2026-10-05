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
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    # 0 = take the value from localai-config.json (14 days if not set).
    [int]$RetentionDays = 0,
    # Optional second copy (another drive, NAS share). '' = take it from localai-config.json.
    [string]$Mirror = '',
    # Suffix for the archive name (pre-uninstall, before-<version>, ...). Tagged archives are not daily ones.
    [string]$Tag = '',
    # Archive the running container instead of stopping it (used before replacing a manual install).
    [switch]$NoStop,
    # Used by Restore-OpenWebUI.ps1: never delete or mirror anything while a restore is in progress.
    [switch]$NoPrune,
    # Do not copy this archive to the mirror folder.
    [switch]$NoMirror,
    # A missed 03:30 run starts right after sign-in, while Docker Desktop is still starting.
    [int]$EngineWaitSec = 300,
    # Docker volume to archive (tests use throwaway ones).
    [string]$Volume = 'open-webui',
    # Container that uses the volume; stopped while the archive is written unless -NoStop.
    [string]$Container = 'open-webui',
    # Small local image that runs tar on the volume.
    [string]$HelperImage = 'alpine:3.20',
    # Deep check: open the archived webui.db with SQLite (integrity_check + user/chat counts) in a
    # throwaway volume. Uses an image that is already local (Open WebUI's own) so nothing is downloaded.
    [switch]$SkipDeepVerify,
    # Image for the deep check; '' = the Open WebUI version in Stack\.env (skipped if that image is not local).
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

# After a failed restore the volume may hold damaged data: a nightly archive of it would push the
# good backups out of the protected newest three. Tagged runs (the recovery's own safety backup,
# before an update) still run.
$hold = Get-LaiWebUIHold -AIRoot $AIRoot
if ($hold -and -not $Tag) {
    Write-BackupLog WARN "Skipped: Open WebUI is held after a failed restore ($($hold['Reason'])). Recover first: $($hold['Recover'])"
    exit 0
}

$suffix = ''
if ($Tag) { $suffix = "-$Tag" }
$name = 'open-webui-{0}{1}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $suffix
$archive = Join-Path $backupDir $name
# Written under a name no reader matches (open-webui-*.tar.gz) and renamed only once verified, so a
# crash, reboot or full disk mid-archive never leaves a truncated file that counts as a fresh backup.
$workName = "incomplete-$name"
$backupStatePath = Join-Path $AIRoot 'backup-state.json'
$work = Join-Path $backupDir $workName
$stopped = $false
$verifiedOk = $false
$exitCode = 0

$deadline = (Get-Date).AddSeconds($EngineWaitSec)
while ((Invoke-Docker -Arguments @('version', '--format', '{{.Server.Version}}') -AllowFail).ExitCode -ne 0) {
    if ((Get-Date) -ge $deadline) {
        Write-BackupLog FAIL "Docker engine is not running (waited $EngineWaitSec s). Start Docker Desktop (Start menu > Local AI > Start again); the next run will catch up."
        exit 1
    }
    Start-Sleep -Seconds 10
}

$lock = $null
try {
    $lock = Enter-LaiVolumeLock
    # Again under the lock: a restore that held it while this run waited may have failed meanwhile.
    $hold = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($hold -and -not $Tag) {
        Write-BackupLog WARN "Skipped: Open WebUI is held after a failed restore ($($hold['Reason'])). Recover first: $($hold['Recover'])"
        exit 0   # 'finally' still releases the lock
    }
    if ((Invoke-Docker -Arguments @('volume', 'inspect', $Volume) -AllowFail).ExitCode -ne 0) { throw "Docker volume '$Volume' does not exist." }
    $running = (Invoke-Docker -Arguments @('inspect', '-f', '{{.State.Running}}', $Container) -AllowFail).Text.Trim() -eq 'true'
    if ($running -and -not $NoStop) {
        Invoke-Docker -Arguments @('stop', '-t', '30', $Container) | Out-Null
        $stopped = $true
    }
    # Leftovers of an interrupted earlier run (we hold the volume lock, so none is in progress).
    Get-ChildItem -LiteralPath $backupDir -Filter 'incomplete-open-webui-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    # Scratch volumes of a deep check that was killed (task time limit, power cut) hold a copy of webui.db.
    foreach ($v in @((Invoke-Docker -Arguments @('volume', 'ls', '-q', '--filter', 'name=localai-verify-') -AllowFail).Text -split "`n" | Where-Object { $_ -match '^localai-verify-\d{14}$' })) {
        Invoke-Docker -Arguments @('volume', 'rm', '-f', $v) -AllowFail | Out-Null
    }
    try {
        Invoke-Docker -Arguments @('run', '--rm', '-v', "${Volume}:/data:ro", '-v', "${backupDir}:/backup", $HelperImage,
            'tar', 'czf', "/backup/$workName", '-C', '/data', '.') | Out-Null
    } finally {
        if ($stopped) { Invoke-Docker -Arguments @('start', $Container) | Out-Null }
    }

    $size = (Get-Item -LiteralPath $work).Length
    $listing = (Invoke-Docker -Arguments @('run', '--rm', '-v', "${backupDir}:/backup:ro", $HelperImage, 'tar', 'tzf', "/backup/$workName")).Text
    if ($size -lt 100 -or $listing -notmatch '(?m)^(\./)?webui\.db\s*$') { throw "Archive $name looks incomplete ($size bytes, webui.db missing)." }
    $verified = ''
    if (-not $SkipDeepVerify) {
        if (-not $VerifyImage) {
            $ver = 'v0.11.4'
            $envFile = Join-Path (Join-Path $AIRoot 'Stack') '.env'
            if (Test-Path -LiteralPath $envFile) {
                $line = Get-Content -Encoding UTF8 -LiteralPath $envFile | Where-Object { $_ -like 'OPEN_WEBUI_VERSION=*' } | Select-Object -First 1
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
            $extract = @('run', '--rm', '-v', "${scratch}:/d", '-v', "${backupDir}:/backup:ro", $HelperImage, 'tar', 'xzf', "/backup/$workName", '-C', '/d') + $members
            Invoke-Docker -Arguments $extract | Out-Null
            # Single quotes only inside the Python code: PS 5.1 mangles double quotes in native arguments.
            $py = "import sqlite3;c=sqlite3.connect('/d/webui.db');" +
                "r=c.execute('pragma integrity_check').fetchone()[0];" +
                "n=lambda t:c.execute('select count(*) from '+t).fetchone()[0];" +
                "print(r,n('user'),n('chat'))"
            $run = Invoke-Docker -Arguments @('run', '--rm', '--entrypoint', 'python3', '-v', "${scratch}:/d", $VerifyImage, '-c', $py) -AllowFail
            $out = $run.Text.Trim()
            $parts = ($out -split '\s+')
            # Corrupt only when SQLite itself says so: integrity_check printed something other than 'ok',
            # or the file is not a readable database. A check that could not run (docker error, out of
            # memory, an image without python3, a renamed table in a newer Open WebUI) says nothing about
            # the data, and quarantining every nightly archive for it would stop pruning and fill the disk.
            $sqliteSaysBad = ($run.ExitCode -eq 0 -and $parts[0] -ne 'ok') -or ($out -match 'DatabaseError|malformed|not a database|file is encrypted')
            if ($sqliteSaysBad) {
                # Keep it for inspection, but tagged so it never counts as one of the three protected daily backups.
                $bad = $archive -replace '\.tar\.gz$', '-CORRUPT.tar.gz'
                Move-Item -LiteralPath $work -Destination $bad -Force
                # Two quarantined archives are enough to investigate; more just fill the disk night after night.
                Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*-CORRUPT.tar.gz' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 2 |  # lai-ok: objects
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                $reason = ($out -split "`n" | Select-Object -Last 1)
                throw "Archive ${name}: webui.db failed the SQLite check ($reason). Kept as $(Split-Path -Leaf $bad). Your live data may be damaged: do not delete older backups."
            }
            if ($run.ExitCode -ne 0 -or $parts.Count -lt 3) {
                Write-BackupLog WARN "Deep check could not run (exit $($run.ExitCode): $(($out -split "`n" | Select-Object -Last 1))); the archive is kept as a normal backup."
                $verified = '; deep check could not run'
            } else {
                $verified = "; database OK ($($parts[1]) users, $($parts[2]) chats)"
            }
        } finally {
            Invoke-Docker -Arguments @('volume', 'rm', '-f', $scratch) -AllowFail | Out-Null
        }
    }
    # Verified: from here on the archive is good, and nothing below may delete it.
    $verifiedOk = $true
    for ($i = 1; $i -le 5; $i++) {
        try { Move-Item -LiteralPath $work -Destination $archive -Force -ErrorAction Stop; break }
        catch {
            # Antivirus or a sync client can hold a just-written file for a moment.
            if ($i -eq 5) {
                # Last resort: a copy under the final name (a reader may still allow that). The
                # incomplete-* original is swept by the next run, so never leave the only copy there.
                try { Copy-Item -LiteralPath $work -Destination $archive -Force -ErrorAction Stop; Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue; break }
                catch { throw "Backup verified but could not be saved under its final name ($($_.Exception.Message)); the next run makes a new one." }
            }
            Start-Sleep -Seconds (2 * $i)
        }
    }
    Write-BackupLog OK ("Backup {0} ({1:N1} MB){2}{3}" -f $archive, ($size / 1MB), $(if ($stopped) { '; container was paused for consistency' } else { '' }), $verified)

    # Retention: daily (untagged) archives older than N days go, but the newest three daily ones always
    # stay. Tagged archives (pre-compose, pre-restore, before-<version>) never count toward those three.
    # The final backup of an uninstall (-pre-uninstall) is never pruned: after a reinstall it is the
    # only copy of the old chats, and the new install's first backup would otherwise delete it.
    # The archive Update-OpenWebUI.ps1 -Rollback would use stays no matter how old it is. Applied to
    # the mirror too, which would otherwise fill the NAS. One file that cannot be deleted (open in an
    # archiver, held by a sync client) is a warning, not a failed backup.
    $keepNames = @()
    if ($config.ContainsKey('RollbackArchive') -and $config['RollbackArchive']) { $keepNames += Split-Path -Leaf ([string]$config['RollbackArchive']) }
    # The archive a pending recovery command names must survive too.
    if ($hold -and $hold['Archive']) { $keepNames += Split-Path -Leaf ([string]$hold['Archive']) }
    $prune = {
        param([string]$Dir)
        $all = @(Get-ChildItem -LiteralPath $Dir -Filter 'open-webui-*.tar.gz' -ErrorAction Stop)
        $daily = @($all | Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' } | Sort-Object LastWriteTime -Descending)  # lai-ok: objects
        $tagged = @($all | Where-Object { $_.Name -notmatch '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.Name -notmatch '-pre-uninstall\.tar\.gz$' -and $keepNames -notcontains $_.Name })
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        foreach ($old in (@($daily | Select-Object -Skip 3) + $tagged | Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Name -ne $name })) {
            try { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop; Write-BackupLog INFO "Pruned $($old.FullName)" }
            catch { Write-BackupLog WARN "Could not prune $($old.FullName): $($_.Exception.Message)" }
        }
    }
    if (-not $NoPrune) { & $prune $backupDir }

    if ($Mirror -and -not $NoMirror) {
        try {
            if (-not (Test-Path -LiteralPath $Mirror)) { New-Item -ItemType Directory -Force -Path $Mirror -ErrorAction Stop | Out-Null }
            # Copy under a temporary name, then rename: an interrupted copy never looks like a backup.
            $mirrorTmp = Join-Path $Mirror $workName
            Copy-Item -LiteralPath $archive -Destination $mirrorTmp -Force -ErrorAction Stop
            Move-Item -LiteralPath $mirrorTmp -Destination (Join-Path $Mirror $name) -Force -ErrorAction Stop
            Write-BackupLog OK "Mirrored to $Mirror"
            # The health watch reads this: a mirror that stops working must not go unnoticed for months.
            $bs = Read-LaiState -Path $backupStatePath; $bs['mirrorOkAt'] = (Get-Date).ToString('s'); $bs['mirrorTarget'] = $Mirror; $bs.Remove('mirrorError')
            Save-LaiState -State $bs -Path $backupStatePath
            Get-ChildItem -LiteralPath $Mirror -Filter 'incomplete-open-webui-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            if (-not $NoPrune) { & $prune $Mirror }
        } catch {
            # The local archive is complete and verified; an offline NAS must not fail the backup.
            Write-BackupLog WARN "Mirror copy to $Mirror failed: $($_.Exception.Message)"
            try { $bs = Read-LaiState -Path $backupStatePath; $bs['mirrorError'] = $_.Exception.Message; $bs['mirrorErrorAt'] = (Get-Date).ToString('s'); Save-LaiState -State $bs -Path $backupStatePath }
            catch { Write-BackupLog WARN "Could not record the mirror failure: $($_.Exception.Message)" }
        }
    }
} catch {
    Write-BackupLog FAIL $_.Exception.Message
    $exitCode = 1
    if (-not $verifiedOk -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue }
} finally {
    Exit-LaiVolumeLock $lock
}
exit $exitCode
