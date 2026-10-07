#Requires -Version 5.1

<#
.SYNOPSIS
    Consistent backup of the Open WebUI data volume (users, chats, memories, presets, settings,
    uploaded documents and their vector index). The models Open WebUI downloads for document search
    and speech are left out: it fetches them again by itself after a restore.

.DESCRIPTION
    Stops the open-webui container while the archive is written (seconds to a few minutes; a
    scheduled run first waits for a chat answer that is still being written) so SQLite and the
    vector store are not copied mid-write, archives the "open-webui" Docker volume to
    <AIRoot>\Backups\open-webui-<timestamp>.tar.gz, restarts the container, verifies the archive,
    prunes old archives and optionally mirrors the newest one to a second location. The installer
    schedules this daily (and at sign-in, to catch up a missed night).

    With deep research installed (-DeepResearch), its accounts, research history and reports are
    archived too, as <AIRoot>\Backups\deep-research-<timestamp>.tar.gz (paused for a second or two,
    not stopped; restore with Restore-OpenWebUI.ps1 -DeepResearch). Its database is encrypted with
    the password in <AIRoot>\Secrets\deep-research.json, so keep that file with your secrets.

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
    # Image for the deep check; '' = the Open WebUI version in Stack\.env, or the image Open WebUI
    # runs when that one is not on this PC (skipped, and counted, if neither is).
    [string]$VerifyImage = '',
    # Scheduled runs: before stopping Open WebUI, wait up to this many seconds while a chat answer
    # is still being written (the render guard counts them), so a run that catches up after wake or
    # sign-in does not cut one off. 0 = do not wait.
    [int]$WaitForChatsSec = 0,
    # Deep research's volume (Install-LocalAI.ps1 -DeepResearch); archived on daily and pre-uninstall
    # runs when it exists. '' = never.
    [string]$ResearchVolume = 'localai-deep-research',
    # Deep research's container; paused (not stopped) while its archive is written unless -NoStop.
    [string]$ResearchContainer = 'deep-research',
    # Scheduled runs: the daily backup time (HH:mm). A run that finds a nightly backup made since that
    # time last came round does nothing, so the extra run at sign-in only catches up a missed night.
    [string]$DailyAt = ''
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
    Add-Content -LiteralPath $logFile -Value ('{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message) -Encoding UTF8
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

# The task also runs at sign-in (a missed run of a task that needs you signed in may not catch up on
# its own); with -DailyAt that extra run does nothing when the last night's backup is already there.
if ($DailyAt -and -not $Tag) {
    $due = $null
    try { $due = Get-LaiLastDailyRun -At $DailyAt } catch { Write-BackupLog WARN "Ignoring -DailyAt '$DailyAt': expected a time like 03:30." }
    if ($due) {
        $done = @(Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.LastWriteTime -ge $due -and $_.LastWriteTime -le (Get-Date).AddHours(1) })
        if ($done.Count) {
            Write-LaiLog INFO "Nothing to do: the backup due at $($due.ToString('yyyy-MM-dd HH:mm')) was already made ($($done[0].Name))."
            exit 0
        }
    }
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

# Each probe has a time limit: a Docker Desktop that stopped answering (it can after sleep) would
# otherwise hang this run until the task's 1 h limit, with no line in backup.log.
$dockerLimit = Get-LaiDockerTimeout
$deadline = (Get-Date).AddSeconds($EngineWaitSec)
while ($true) {
    $engine = Test-LaiDockerEngine -TimeoutSec $dockerLimit
    if ($engine -eq 'ok') { break }
    if ($engine -eq 'missing') {
        Write-BackupLog FAIL 'The docker command was not found. Repair Docker Desktop (or re-run the installer); the next run will catch up.'
        exit 1
    }
    if ((Get-Date) -ge $deadline) {
        if ($engine -eq 'hung') {
            Write-BackupLog FAIL "Docker Desktop is not responding (docker got no answer within $dockerLimit s; waited $EngineWaitSec s). Restart it (whale icon > Restart); the next run will catch up."
        } else {
            Write-BackupLog FAIL "Docker engine is not running (waited $EngineWaitSec s). Start Docker Desktop (Start menu > Local AI > Start again); the next run will catch up."
        }
        exit 1
    }
    Start-Sleep -Seconds 10
}

if ($WaitForChatsSec -gt 0 -and -not $NoStop) {
    # A run that catches up after wake or sign-in starts while you may be chatting: stopping Open
    # WebUI then would cut off the answer being written. Before the volume lock, so Start again or a
    # restore are not blocked while this waits.
    $poll = 15; if ($env:LOCALAI_TEST_CHAT_POLL_SEC) { $poll = [int]$env:LOCALAI_TEST_CHAT_POLL_SEC }
    $chatStart = Get-Date
    $capped = $false
    while ((Get-LaiChatsInFlight -TimeoutSec $dockerLimit) -gt 0) {
        if (((Get-Date) - $chatStart).TotalSeconds -ge $WaitForChatsSec) { $capped = $true; break }
        Start-Sleep -Seconds $poll
    }
    $waited = [int]((Get-Date) - $chatStart).TotalSeconds
    if ($capped) { Write-BackupLog WARN "A chat answer was still being written after $waited s; stopping Open WebUI anyway (regenerate that answer if it was cut off)." }
    elseif ($waited -ge $poll) { Write-BackupLog INFO "Waited $waited s for a chat answer to finish before stopping Open WebUI." }
}

function Save-ResearchArchive {
    param([string]$RVolume, [string]$RContainer)
    # Local Deep Research's accounts, history and reports, in a small archive next to Open WebUI's.
    # Paused rather than stopped, and only while its data is copied to a scratch volume inside Docker
    # (no compression, no Windows folder: about a second): a research run in progress carries on
    # afterwards. The copy is what a power cut at that instant would leave, which SQLite (its
    # SQLCipher databases) recovers from by design. A failure is a warning on a nightly run (Open
    # WebUI's archive above is complete, the next run tries again, Test-LocalAI reports it) and fails
    # an uninstall's final backup, so the uninstaller never deletes research data it could not save.
    $rName = 'deep-research-{0}{1}.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $suffix
    $rWork = Join-Path $backupDir "incomplete-$rName"
    $scratch = 'localai-research-copy-' + (Get-Date -Format 'yyyyMMddHHmmss')
    try {
        Get-ChildItem -LiteralPath $backupDir -Filter 'incomplete-deep-research-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        foreach ($v in @((Invoke-Docker -Arguments @('volume', 'ls', '-q', '--filter', 'name=localai-research-copy-') -AllowFail).Text -split "`n" | Where-Object { $_ -match '^localai-research-copy-\d{14}$' })) {
            Invoke-Docker -Arguments @('volume', 'rm', '-f', $v) -AllowFail | Out-Null
        }
        $state = (Invoke-Docker -Arguments @('inspect', '-f', '{{.State.Status}}', $RContainer) -AllowFail).Text.Trim()
        if ($state -eq 'paused') {
            # Left paused by an earlier run that was killed mid-copy (nothing else here pauses it).
            Invoke-Docker -Arguments @('unpause', $RContainer) | Out-Null
            Write-BackupLog WARN "Deep research was left paused by an interrupted earlier backup; woke it."
            $state = 'running'
        }
        Invoke-Docker -Arguments @('volume', 'create', $scratch) | Out-Null
        $paused = $false
        if ($state -eq 'running' -and -not $NoStop) { Invoke-Docker -Arguments @('pause', $RContainer) | Out-Null; $paused = $true }
        try {
            Invoke-Docker -Arguments @('run', '--rm', '-v', ($RVolume + ':/data:ro'), '-v', ($scratch + ':/copy'), $HelperImage, 'cp', '-a', '/data/.', '/copy/') | Out-Null
        } catch {
            throw
        } finally {
            if ($paused -and (Invoke-Docker -Arguments @('unpause', $RContainer) -AllowFail).ExitCode -ne 0) {
                # Reported as a failed research backup (Test-LocalAI shows it); the next run wakes it.
                throw "deep research could not be woken after the copy ('docker unpause $RContainer' does it; the next backup tries too)"
            }
        }
        Invoke-Docker -Arguments @('run', '--rm', '-v', ($scratch + ':/data:ro'), '-v', "${backupDir}:/backup", $HelperImage,
            'tar', 'czf', "/backup/incomplete-$rName", '-C', '/data', '.') | Out-Null
        $list = (Invoke-Docker -Arguments @('run', '--rm', '-v', "${backupDir}:/backup:ro", $HelperImage, 'tar', 'tzf', "/backup/incomplete-$rName")).Text
        if ($list -notmatch '(?m)^(\./)?encrypted_databases/?\s*$') { throw "$rName has no encrypted_databases folder (the volume is not Local Deep Research's data)" }
        $rArchive = Join-Path $backupDir $rName
        for ($i = 1; $i -le 5; $i++) {
            # Antivirus or a sync client can hold a just-written file for a moment.
            try { Move-Item -LiteralPath $rWork -Destination $rArchive -Force -ErrorAction Stop; break }
            catch { if ($i -eq 5) { throw }; Start-Sleep -Seconds (2 * $i) }
        }
        $rSize = (Get-Item -LiteralPath $rArchive).Length
        $note = ''
        if ($Mirror -and -not $NoMirror) {
            try {
                if (-not (Test-Path -LiteralPath $Mirror)) { New-Item -ItemType Directory -Force -Path $Mirror -ErrorAction Stop | Out-Null }
                Copy-Item -LiteralPath $rArchive -Destination (Join-Path $Mirror "incomplete-$rName") -Force -ErrorAction Stop
                Move-Item -LiteralPath (Join-Path $Mirror "incomplete-$rName") -Destination (Join-Path $Mirror $rName) -Force -ErrorAction Stop
                $note = '; mirrored'
            } catch { $note = "; mirror copy failed ($($_.Exception.Message))" }
        }
        # Same rule as Open WebUI's: daily archives older than N days go, the newest three always stay,
        # and a pre-uninstall one is never pruned.
        if (-not $NoPrune) {
            foreach ($dir in @($backupDir) + @($(if ($Mirror -and -not $NoMirror -and (Test-Path -LiteralPath $Mirror)) { $Mirror }))) {
                $daily = @(Get-ChildItem -LiteralPath $dir -Filter 'deep-research-*.tar.gz' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^deep-research-\d{8}-\d{6}\.tar\.gz$' } | Sort-Object LastWriteTime -Descending)  # lai-ok: objects
                # Safety copies of a restore (-pre-restore) go by age alone, like Open WebUI's tagged ones.
                $tagged = @(Get-ChildItem -LiteralPath $dir -Filter 'deep-research-*-pre-restore.tar.gz' -ErrorAction SilentlyContinue)
                foreach ($old in @(@($daily | Select-Object -Skip 3) + $tagged | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) -and $_.Name -ne $rName })) {
                    try { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop; Write-BackupLog INFO "Pruned $($old.FullName)" }
                    catch { Write-BackupLog WARN "Could not prune $($old.FullName): $($_.Exception.Message)" }
                }
            }
        }
        Write-BackupLog OK ("Deep research backup {0} ({1:N1} MB){2}" -f $rArchive, ($rSize / 1MB), $note)
        try { $bs = Read-LaiState -Path $backupStatePath; $bs['researchOkAt'] = (Get-Date).ToString('s'); $bs.Remove('researchError'); Save-LaiState -State $bs -Path $backupStatePath }
        catch { Write-BackupLog WARN "Could not record the deep research backup: $($_.Exception.Message)" }
    } catch {
        Remove-Item -LiteralPath $rWork -Force -ErrorAction SilentlyContinue
        if ($Tag -eq 'pre-uninstall') {
            Write-BackupLog FAIL "Deep research backup failed: $($_.Exception.Message). Its data is not saved, so the uninstall must not delete it."
            $script:exitCode = 1
        } else {
            Write-BackupLog WARN "Deep research backup failed: $($_.Exception.Message). Open WebUI's backup is not affected; the next run tries again."
        }
        try { $bs = Read-LaiState -Path $backupStatePath; $bs['researchError'] = $_.Exception.Message; $bs['researchErrorAt'] = (Get-Date).ToString('s'); Save-LaiState -State $bs -Path $backupStatePath }
        catch { Write-BackupLog WARN "Could not record the failure: $($_.Exception.Message)" }
    } finally {
        Invoke-Docker -Arguments @('volume', 'rm', '-f', $scratch) -AllowFail | Out-Null
    }
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
        # Without the models Open WebUI downloads for document search and speech (several GB, fetched
        # again by itself after a restore): every nightly archive would otherwise carry them.
        Invoke-Docker -Arguments @('run', '--rm', '-v', "${Volume}:/data:ro", '-v', "${backupDir}:/backup", $HelperImage,
            'tar', 'czf', "/backup/$workName", '--exclude=./cache/embedding/models', '--exclude=./cache/whisper/models', '-C', '/data', '.') | Out-Null
    } finally {
        if ($stopped) { Invoke-Docker -Arguments @('start', $Container) | Out-Null }
    }

    $size = (Get-Item -LiteralPath $work).Length
    $listing = (Invoke-Docker -Arguments @('run', '--rm', '-v', "${backupDir}:/backup:ro", $HelperImage, 'tar', 'tzf', "/backup/$workName")).Text
    if ($size -lt 100 -or $listing -notmatch '(?m)^(\./)?webui\.db\s*$') { throw "Archive $name looks incomplete ($size bytes, webui.db missing)." }
    $verified = ''
    if (-not $SkipDeepVerify) {
        $imageFromEnv = -not $VerifyImage
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
            # .env can name a version whose download never finished (an update cut off by a restart):
            # the image Open WebUI actually runs is local and does the check just as well.
            $runImage = ''
            if ($imageFromEnv) {
                $ci = Invoke-Docker -Arguments @('inspect', '-f', '{{.Config.Image}}', $Container) -AllowFail
                if ($ci.ExitCode -eq 0 -and $ci.Text.Trim() -and (Invoke-Docker -Arguments @('image', 'inspect', $ci.Text.Trim()) -AllowFail).ExitCode -eq 0) { $runImage = $ci.Text.Trim() }
            }
            if ($runImage) {
                Write-BackupLog INFO "Deep check: $VerifyImage (named in Stack\.env) is not on this PC; using the image Open WebUI runs ($runImage)."
                $VerifyImage = $runImage
            } else {
                # Never pull a multi-GB image from a scheduled task. Counted like a check that could not
                # run: the health watch fails 'Backups' after 3 nights, so it cannot stop for good unnoticed.
                Write-BackupLog WARN "Deep check skipped: image $VerifyImage is not present locally."
                $SkipDeepVerify = $true
                $verified = '; deep check skipped (image not on this PC)'
                try {
                    $bstate = Read-LaiState -Path $backupStatePath
                    $skips = 0; if ($bstate['deepCheckSkips']) { $skips = [int]$bstate['deepCheckSkips'] }
                    $bstate['deepCheck'] = 'could-not-run'; $bstate['deepCheckSkips'] = $skips + 1
                    Save-LaiState -State $bstate -Path $backupStatePath
                } catch { Write-BackupLog WARN "Could not record the skipped deep check: $($_.Exception.Message)" }
            }
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
            # One line per step, so a failure part-way still tells what SQLite saw:
            #   T <tables> <has user> <has chat>   I <integrity_check>   C <users> <chats>
            $py = "import sqlite3;c=sqlite3.connect('/d/webui.db');" +
                "t=[x[0] for x in c.execute('select name from sqlite_master where type=?',('table',))];" +
                "print('T',len(t),int('user' in t),int('chat' in t),flush=True);" +
                "print('I',c.execute('pragma integrity_check').fetchone()[0],flush=True);" +
                "n=lambda x:c.execute('select count(*) from '+x).fetchone()[0];" +
                "print('C',n('user'),n('chat'))"
            $run = Invoke-Docker -Arguments @('run', '--rm', '--entrypoint', 'python3', '-v', "${scratch}:/d", $VerifyImage, '-c', $py) -AllowFail
            $out = $run.Text.Trim()
            $tLine = [regex]::Match($out, '(?m)^T (\d+) ([01]) ([01])\s*$')
            $iLine = [regex]::Match($out, '(?m)^I (.+?)\s*$')
            $cLine = [regex]::Match($out, '(?m)^C (\d+) (\d+)\s*$')
            # Corrupt when SQLite itself says so: integrity_check is not 'ok', the database has no
            # tables at all (an empty or truncated webui.db), or SQLite cannot read the file. A check that
            # could not run (docker error, out of memory, an image without python3, tables renamed by a
            # newer Open WebUI) says nothing about the data: quarantining every nightly archive for it
            # would stop pruning and fill the disk.
            $sqliteSaysBad = ($iLine.Success -and $iLine.Groups[1].Value -ne 'ok') -or
                ($tLine.Success -and [int]$tLine.Groups[1].Value -eq 0) -or
                ($out -match 'DatabaseError|malformed|not a database|file is encrypted|disk I/O error')
            $bstate = Read-LaiState -Path $backupStatePath
            if ($sqliteSaysBad) {
                # Keep it for inspection, but tagged so it never counts as one of the three protected daily backups.
                $bad = $archive -replace '\.tar\.gz$', '-CORRUPT.tar.gz'
                Move-Item -LiteralPath $work -Destination $bad -Force
                # Two quarantined archives are enough to investigate: the OLDEST (closest to the last good
                # state) and the newest. More just fill the disk night after night. An uninstall's final
                # backup is never touched.
                $cor = @(Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*-CORRUPT.tar.gz' | Where-Object { $_.Name -notmatch '-pre-uninstall-CORRUPT\.tar\.gz$' } | Sort-Object LastWriteTime)  # lai-ok: objects
                if ($cor.Count -gt 2) {
                    $cor[1..($cor.Count - 2)] | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                }
                try { $bstate['deepCheck'] = 'corrupt'; $bstate['deepCheckSkips'] = 0; Save-LaiState -State $bstate -Path $backupStatePath } catch { Write-Verbose 'backup state not saved' }
                $reason = ($out -split "`n" | Select-Object -Last 1)
                throw "Archive ${name}: webui.db failed the SQLite check ($reason). Kept as $(Split-Path -Leaf $bad). Your live data may be damaged: do not delete older backups."
            }
            if ($cLine.Success) {
                $verified = "; database OK ($($cLine.Groups[1].Value) users, $($cLine.Groups[2].Value) chats)"
                $bstate['deepCheck'] = 'ok'; $bstate['deepCheckSkips'] = 0; $bstate['deepCheckOkAt'] = (Get-Date).ToString('s')
            } else {
                # Counted: the health watch fails 'Backups' after 3 nights in a row, so a check that has
                # quietly stopped working (new image, renamed tables) does not stay unnoticed.
                $skips = 0; if ($bstate['deepCheckSkips']) { $skips = [int]$bstate['deepCheckSkips'] }
                $bstate['deepCheck'] = 'could-not-run'; $bstate['deepCheckSkips'] = $skips + 1
                Write-BackupLog WARN "Deep check could not run (exit $($run.ExitCode): $(($out -split "`n" | Select-Object -Last 1))); the archive is kept as a normal backup."
                $verified = '; deep check could not run'
            }
            try { Save-LaiState -State $bstate -Path $backupStatePath } catch { Write-BackupLog WARN "Could not record the deep-check result: $($_.Exception.Message)" }
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
            try {
                $bs = Read-LaiState -Path $backupStatePath; $bs['mirrorOkAt'] = (Get-Date).ToString('s'); $bs['mirrorTarget'] = $Mirror; $bs.Remove('mirrorError')
                Save-LaiState -State $bs -Path $backupStatePath
            } catch { Write-BackupLog WARN "Mirror copy done, but its state could not be recorded: $($_.Exception.Message)" }
            Get-ChildItem -LiteralPath $Mirror -Filter 'incomplete-open-webui-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            if (-not $NoPrune) { & $prune $Mirror }
        } catch {
            # The local archive is complete and verified; an offline NAS must not fail the backup.
            Write-BackupLog WARN "Mirror copy to $Mirror failed: $($_.Exception.Message)"
            try { $bs = Read-LaiState -Path $backupStatePath; $bs['mirrorError'] = $_.Exception.Message; $bs['mirrorErrorAt'] = (Get-Date).ToString('s'); Save-LaiState -State $bs -Path $backupStatePath }
            catch { Write-BackupLog WARN "Could not record the mirror failure: $($_.Exception.Message)" }
        }
    }

    if ($ResearchVolume -and (-not $Tag -or $Tag -eq 'pre-uninstall') -and (Invoke-Docker -Arguments @('volume', 'inspect', $ResearchVolume) -AllowFail).ExitCode -eq 0) {
        Save-ResearchArchive -RVolume $ResearchVolume -RContainer $ResearchContainer
    }
} catch {
    Write-BackupLog FAIL $_.Exception.Message
    $exitCode = 1
    if (-not $verifiedOk -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue }
} finally {
    Exit-LaiVolumeLock $lock
}
exit $exitCode
