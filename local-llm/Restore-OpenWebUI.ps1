#Requires -Version 5.1

<#
.SYNOPSIS
    Restores an Open WebUI backup archive (made by Backup-OpenWebUI.ps1) into the open-webui volume.

.DESCRIPTION
    Built so that a failed restore can never leave you with an empty or half-written volume:
      1. Picks the archive (newest daily backup unless -Archive is given), copies it into
         <AIRoot>\Backups\restore-staging (also makes NAS/UNC archives usable by Docker), and checks
         that webui.db sits at the top level.
      2. Takes a verified safety backup of the current volume (tag "pre-restore"; never pruned or
         mirrored during the restore).
      3. Stops every container using the volume, extracts the archive into a staging folder *inside*
         the volume, and only after webui.db is confirmed there swaps it in. An archive that does
         not unpack touches none of the old data: Open WebUI is started again on it as it was.
      4. If anything fails after the old data was touched, it puts the safety backup back. If even that
         fails, the container is left stopped and the exact recovery command is printed. The same
         when the restore is stopped (Ctrl+C) while it replaces the old data: Open WebUI stays
         stopped, and the command that finishes the restore is printed.
    A machine-wide lock stops the scheduled backup from running at the same time.

    A backup leaves out the document-search and speech models Open WebUI downloaded (about 7 GB).
    The ones in the volume are kept through the swap, so Open WebUI does not fetch them again; only
    a volume that had none (a new PC, a wiped volume) downloads them at the first start, which can
    take longer than the 5 minutes this script waits for an answer (-WebUIWaitSec sets another wait).

    A backup carries the settings of its day, so once Open WebUI is back this install's own are
    applied again: its Ollama connection, sign-up off, and on the toolkit's presets no past-chat
    search, no code execution, none of the seven writing tools (notes, tasks, automations,
    calendar, notifications, channels, sub-agents) and (uncensored ones) no web search without
    being asked. Any other preset in the restored data that has one of these on is named in a
    warning with where to switch it off, and is not changed. An archive
    the nightly backup marked -EMPTY (made after the data was wiped) is never picked by itself, and
    until that mark is settled the pick is the last good backup, not the newest; naming an -EMPTY
    one with -Archive asks first.

.EXAMPLE
    .\Restore-OpenWebUI.ps1                                   # newest daily backup
.EXAMPLE
    .\Restore-OpenWebUI.ps1 -Archive \\nas\backups\open-webui-20261002-175511.tar.gz
.EXAMPLE
    .\Restore-OpenWebUI.ps1 -DeepResearch                    # deep research's newest backup instead
#>
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    [string]$Archive = '',
    # Do not archive the current data first (no automatic rollback if the restore fails).
    [switch]$SkipSafetyBackup,
    # Docker volume to restore into.
    [string]$Volume = 'open-webui',
    # Container that uses the volume; stopped during the restore.
    [string]$Container = 'open-webui',
    # Small local image that runs tar on the volume.
    [string]$HelperImage = 'alpine:3.20',
    # Skip the "type YES" confirmation (scripts, automation).
    [switch]$Force,
    # Restore deep research's data (accounts, history, reports) instead of Open WebUI's, from a
    # deep-research-*.tar.gz (the newest daily one unless -Archive is given).
    [switch]$DeepResearch,
    # Deep research's volume (tests use throwaway ones).
    [string]$ResearchVolume = 'localai-deep-research',
    # Deep research's container; stopped during its restore.
    [string]$ResearchContainer = 'deep-research',
    # The models catalog whose presets get this install's safety settings back after the restore.
    # Defaults to config\models.psd1 next to this script.
    [string]$CatalogPath = '',
    # How many seconds Open WebUI gets to answer after the restore (5 minutes unless given).
    [ValidateRange(1, [int]::MaxValue)][int]$WebUIWaitSec = 300,
    # Test only (tests/Invoke-UpdateWebUITest.ps1; no shortcut and no scheduled task passes it):
    # setting this install's Ollama connection after the restore counts as failed, the way an
    # error from Open WebUI ends it. A run that gets it says so in a warning at its start.
    [switch]$TestFailOllamaUrl
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force
# Said at the start of every run that got it, before anything is asked, checked or changed, as
# Update-Models.ps1 says -TestAllowCpu. It used to be named only in the failure it causes, minutes
# later and only when the restore came that far.
if ($TestFailOllamaUrl) { Write-LaiLog WARN 'Test run: -TestFailOllamaUrl was passed, so the step that puts this install''s Ollama connection back after a restore of Open WebUI''s data counts as failed, and that data keeps the connection it came with. Only tests/Invoke-UpdateWebUITest.ps1 passes it (no shortcut, no scheduled task): if you did not mean to, run Start menu > Local AI - Update toolkit after the restore, which sets the connection.' }
$img = $HelperImage
# -CatalogPath is looked at before anything is asked or changed (the step that reads the catalog
# runs minutes later, once the data is swapped) and kept as a full path. $catalogGiven: said in
# that step, so the log of a restore names a catalog that was not the toolkit's own.
$catalogGiven = [bool]$CatalogPath
if ($catalogGiven) {
    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw "The models catalog given with -CatalogPath was not found: $CatalogPath. Nothing was changed." }
    $CatalogPath = (Resolve-Path -LiteralPath $CatalogPath).ProviderPath
} else { $CatalogPath = Join-Path (Join-Path $PSScriptRoot 'config') 'models.psd1' }

function Invoke-Docker {
    param([string[]]$Arguments, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& docker @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0 -and -not $AllowFail) { throw "docker $($Arguments -join ' ') failed ($code): $($out -join ' ')" }
    return [pscustomobject]@{ ExitCode = $code; Text = ($out -join "`n") }
}

# The archive is always mounted as /restore.tar.gz, so its file name never reaches the shell.
# No double quotes anywhere in these scripts: Windows PowerShell 5.1 mangles them in native arguments.
# The swap is two runs of the helper (Invoke-Swap). The first ($extractScript) unpacks the archive
# next to the old data and checks it: it deletes nothing of that data, so when it fails Open WebUI
# goes back on the data it had, with no rollback. The second ($moveScript) deletes the old data and
# moves the unpacked tree into its place: only from there on can the volume be half replaced.
# The 'for' line of the second run: a backup leaves out the document-search and speech models Open
# WebUI downloaded (cache/embedding/models and cache/whisper/models, about 7 GB), and the delete
# after it takes all the volume holds. So the two folders move into the staging tree first and come
# back with it, unless the archive brings its own. Every restore, and every rollback to a safety
# backup, used to end with Open WebUI downloading them again.
# The 'for' line of the first run: a swap that failed or was cut off after that move left the two
# folders in the staging tree, and this swap (the rollback to the safety backup, or the restore run
# again) starts by clearing that tree. They go back to their place first, where the second run
# finds them. Best effort (|| true): it only saves a download, and must never stop a restore.
# The archive is unpacked next to the staging tree (.restore-partial), checked there and only then
# renamed, so the staging tree only ever holds a complete tree that passed the check: a models
# folder taken back from it is whole, never the first part of one from an older archive (those
# still carry the models) whose unpacking was cut off, and never that of an archive the check
# turned down (checked after the rename, such a tree was the staging tree when the sweep below
# ran, and its models went into a volume that had none).
# The 'rm' after the unpacking: a backup made while one of the two trees sat in the volume (a
# sweep that could not run) carries it, and the second run cannot move a folder named
# .restore-staging onto the staging tree itself: it failed after the old data was gone, and so did
# the rollback, whose safety backup carried the folder as well.
# $sweepScript is how the first run begins (the models back to their place, both trees gone). It is
# also run by itself after an unpacking that failed or was cut off, so that what it left in the
# volume does not stay there.
# The second run begins with a check of its own that the staging tree is there: without one, its
# delete would take the old data and leave nothing to move in.
$sweepScript = 'set -e; ' +
    'for m in cache/embedding/models cache/whisper/models; do if [ -d /data/.restore-staging/$m ]; then if [ ! -e /data/$m ]; then ' +
    'mkdir -p /data/${m%/*} && mv /data/.restore-staging/$m /data/$m || true; fi; fi; done; ' +
    'rm -rf /data/.restore-staging /data/.restore-partial'
$extractScript = $sweepScript + '; mkdir /data/.restore-partial; ' +
    'tar xzf /restore.tar.gz -C /data/.restore-partial; ' +
    'rm -rf /data/.restore-partial/.restore-staging /data/.restore-partial/.restore-partial; ' +
    'test -f /data/.restore-partial/webui.db; mv /data/.restore-partial /data/.restore-staging'
$moveScript = 'set -e; test -d /data/.restore-staging; ' +
    'for m in cache/embedding/models cache/whisper/models; do if [ -d /data/$m ]; then if [ ! -e /data/.restore-staging/$m ]; then ' +
    'mkdir -p /data/.restore-staging/${m%/*}; mv /data/$m /data/.restore-staging/$m; fi; fi; done; ' +
    'find /data -mindepth 1 -maxdepth 1 ! -name .restore-staging -exec rm -rf {} +; ' +
    'cd /data/.restore-staging; find . -mindepth 1 -maxdepth 1 -exec mv {} /data/ \; ; ' +
    'cd /; rmdir /data/.restore-staging'
# Both in one run, for deep research (one container, no hold): its branch below swaps the check
# 'test -f /data/.restore-partial/webui.db' in this text for its own.
$swapScript = $extractScript + '; ' + $moveScript

# The two runs of Invoke-Swap have a name each (per volume), so that a run can be ended. Ending the
# docker client (Ctrl+C, a closed window) does not end the container it started: the helper went on
# unpacking, or moving data, with nothing waiting for it. After a stopped unpacking the volume was
# swept and Open WebUI started while it ran, and it then left its staging tree next to the live
# data, where every backup from then on carried it.
$helperName = 'localai-restore-' + ($Volume -replace '[^A-Za-z0-9_.-]', '-')
$helperRuns = @("${helperName}-unpack", "${helperName}-move")
function Stop-SwapHelper {
    # Ends a run of the helper that is still there. $true when Docker says none is running any
    # more (asked, not read off 'rm': what that answers for a container that is already gone
    # differs between Docker versions). Never throws: 'finally' calls it.
    try {
        Invoke-Docker -Arguments (@('rm', '-f') + $helperRuns) -AllowFail | Out-Null
        $left = Invoke-Docker -Arguments @('ps', '-q', '--filter', "name=$helperName") -AllowFail
        return [bool]($left.ExitCode -eq 0 -and -not $left.Text.Trim())
    } catch {
        Write-Verbose "the helper could not be looked for: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-Swap {
    # extractOpen: the first run was started and the second was not, so what it unpacked may sit in
    # the volume ('finally' removes it). volumeTouched and swapOpen: set right before the second
    # run, never before the first (an archive that does not unpack sets off no rollback). swapOpen
    # is cleared once the second run is through: while it is set, the volume may be half replaced,
    # and 'finally' starts nothing on it.
    param([string]$ArchivePath)
    # One helper on the volume at a time: a run an earlier restore left behind (its window was
    # closed), or one whose docker client gave up while the container ran on, is ended first. It
    # would hold its name, and it would write into the tree this swap builds.
    Stop-SwapHelper | Out-Null
    $script:extractOpen = $true
    Invoke-Docker -Arguments @('run', '--rm', '--name', $helperRuns[0], '-v', "${Volume}:/data", '-v', "${ArchivePath}:/restore.tar.gz:ro", $img, 'sh', '-c', $extractScript) | Out-Null
    $script:volumeTouched = $true
    $script:swapOpen = $true
    $script:extractOpen = $false
    Invoke-Docker -Arguments @('run', '--rm', '--name', $helperRuns[1], '-v', "${Volume}:/data", $img, 'sh', '-c', $moveScript) | Out-Null
    $script:swapOpen = $false
}

function Test-Archive {
    param([string]$ArchivePath)
    $r = Invoke-Docker -Arguments @('run', '--rm', '-v', "${ArchivePath}:/restore.tar.gz:ro", $img, 'tar', 'tzf', '/restore.tar.gz') -AllowFail
    return ($r.ExitCode -eq 0 -and $r.Text -match '(?m)^(\./)?webui\.db\s*$')
}

$backupDir = Join-Path $AIRoot 'Backups'
$stagingDir = Join-Path $backupDir 'restore-staging'
$lock = $null
$stoppedContainers = @()
# What Invoke-Swap sets (see there).
$volumeTouched = $false
$script:swapOpen = $false
$script:extractOpen = $false
$safety = $null
# Set once the rollback to the safety backup begins: 'finally' then speaks of a stopped rollback.
$rollbackStarted = $false
$holdPath = Join-Path $AIRoot 'open-webui-hold.json'
$script:holdArchive = ''
$script:recoverCmd = ''
$script:holdWritten = $false
function Clear-Hold([string]$Note) {
    # Never throws: a hold that cannot be deleted right now (antivirus, a sync client) is a warning,
    # not a reason to abandon a restore that worked. Retries briefly first.
    for ($i = 1; $i -le 5; $i++) {
        if (-not (Test-Path -LiteralPath $holdPath)) { return }
        try { Remove-Item -LiteralPath $holdPath -Force -ErrorAction Stop; if ($Note) { Write-LaiLog OK $Note }; return }
        catch { Start-Sleep -Milliseconds (300 * $i) }
    }
    Write-LaiLog WARN "Could not delete $holdPath; delete it by hand, or Start again, backups and updates keep refusing."
}
function Set-Hold([string]$Why, [object[]]$Held) {
    # Keep Open WebUI down until a restore succeeds: the watch, Start-LocalAI and the installer
    # check this file. The original restart policies are kept here so the recovery can put them back.
    $list = @($Held | ForEach-Object { @{ Id = $_.Id; Policy = $_.Policy } })
    $ids = @($list | ForEach-Object { $_['Id'] })
    $old = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($old -and $old['Containers']) { foreach ($c in @($old['Containers'])) { if ($ids -notcontains $c['Id']) { $list += $c } } }
    $recover = $script:recoverCmd; $archive = [string]$script:holdArchive
    # A failed recovery run (no safety backup of its own) must not replace the earlier hold's pointer
    # to the safety archive: that one holds the newest data.
    if (-not $archive -and $old -and $old['Archive']) { $archive = [string]$old['Archive']; $recover = [string]$old['Recover'] }
    Save-LaiState -State @{ Reason = $Why; Recover = $recover; Archive = $archive; Containers = $list; Since = (Get-Date).ToString('s') } -Path $holdPath
    if ($recover -ne $script:recoverCmd) { Write-LaiLog FAIL "The earlier recovery command still applies: $recover" }
}

if ($DeepResearch) {
    # Deep research is much simpler than Open WebUI: one container, no hold. The current data is
    # archived first and put back if the swap fails; its database stays readable only with the
    # password in Secrets\deep-research.json, which a restore does not change.
    if (-not $Archive) {
        $newest = Get-ChildItem -LiteralPath $backupDir -Filter 'deep-research-*.tar.gz' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^deep-research-\d{8}-\d{6}(-pre-uninstall)?\.tar\.gz$' -and $_.LastWriteTime -le (Get-Date).AddHours(1) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
        if (-not $newest) { throw "No deep research backups found in $backupDir. Pass -Archive <file>." }
        $Archive = $newest.FullName
    }
    if (-not (Test-Path -LiteralPath $Archive)) { throw "Archive not found: $Archive" }
    $source = Get-Item -LiteralPath $Archive
    if (-not $Force) {
        Write-LaiLog WARN ("This replaces ALL current deep research data (accounts, research history, reports) with {0} from {1}." -f $source.Name, $source.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
        if ((Read-Host 'Type YES to restore') -cne 'YES') { Write-LaiLog INFO 'Nothing changed.'; exit 1 }
    }
    $rSwap = $swapScript.Replace('test -f /data/.restore-partial/webui.db', 'test -d /data/.restore-partial/encrypted_databases')
    # Putting the earlier data back: whatever it held (it may have been a fresh, empty install).
    $rBack = $swapScript.Replace('test -f /data/.restore-partial/webui.db', 'true')
    if ($rSwap -eq $swapScript -or $rBack -eq $swapScript) { throw 'Internal error: the swap script changed; nothing was done.' }
    $wasRunning = $false
    $policy = ''
    $rSafety = $null
    $rTouched = $false
    $keepStopped = $false
    $code = 0
    try {
        $lock = Enter-LaiVolumeLock
        if ((Invoke-Docker -Arguments @('version', '--format', '{{.Server.Version}}') -AllowFail).ExitCode -ne 0) {
            throw 'Docker Desktop is not running. Start it (Start menu > Local AI - Start again), then run the restore again. Nothing was changed.'
        }
        if (-not (Test-Path -LiteralPath $stagingDir)) { New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null }
        $staged = Join-Path $stagingDir 'restore-deep-research.tar.gz'
        Copy-Item -LiteralPath $source.FullName -Destination $staged -Force
        $list = Invoke-Docker -Arguments @('run', '--rm', '-v', "${staged}:/restore.tar.gz:ro", $img, 'tar', 'tzf', '/restore.tar.gz') -AllowFail
        if ($list.ExitCode -ne 0 -or $list.Text -notmatch '(?m)^(\./)?encrypted_databases/?\s*$') { throw "$($source.Name) is not a deep research backup (unreadable, or no encrypted_databases folder). Nothing was changed." }
        # Stopped first, so the safety copy is consistent and nothing writes during the swap; its
        # restart policy is off meanwhile, so a Docker Desktop restart cannot start it mid-swap (the
        # health watch leaves it alone while this holds the volume lock).
        $insp = Invoke-Docker -Arguments @('inspect', '-f', '{{.State.Running}}|{{.HostConfig.RestartPolicy.Name}}', $ResearchContainer) -AllowFail
        if ($insp.ExitCode -eq 0) {
            $wasRunning = ($insp.Text.Trim() -split '\|')[0] -eq 'true'
            $policy = ($insp.Text.Trim() -split '\|')[1]
            if ($policy -and $policy -ne 'no') { Invoke-Docker -Arguments @('update', '--restart', 'no', $ResearchContainer) | Out-Null }
            if ($wasRunning) { Invoke-Docker -Arguments @('stop', '-t', '30', $ResearchContainer) | Out-Null }
        }
        if ((Invoke-Docker -Arguments @('volume', 'inspect', $ResearchVolume) -AllowFail).ExitCode -ne 0) {
            Invoke-Docker -Arguments @('volume', 'create', $ResearchVolume) | Out-Null
        } elseif (-not $SkipSafetyBackup) {
            # Written under a temporary name and checked before it counts as the safety copy.
            $rSafety = Join-Path $backupDir ('deep-research-{0}-pre-restore.tar.gz' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $tmp = 'incomplete-' + (Split-Path -Leaf $rSafety)
            Invoke-Docker -Arguments @('run', '--rm', '-v', "${ResearchVolume}:/data:ro", '-v', "${backupDir}:/backup", $img, 'tar', 'czf', "/backup/$tmp", '-C', '/data', '.') | Out-Null
            Invoke-Docker -Arguments @('run', '--rm', '-v', "${backupDir}:/backup:ro", $img, 'tar', 'tzf', "/backup/$tmp") | Out-Null
            Move-Item -LiteralPath (Join-Path $backupDir $tmp) -Destination $rSafety -Force -ErrorAction Stop
            Write-LaiLog OK "Current deep research data saved as $rSafety"
        }
        $rTouched = $true
        Invoke-Docker -Arguments @('run', '--rm', '-v', "${ResearchVolume}:/data", '-v', "${staged}:/restore.tar.gz:ro", $img, 'sh', '-c', $rSwap) | Out-Null
        Write-LaiLog OK "Deep research data restored from $($source.Name)"
    } catch {
        $code = 1
        Write-LaiLog FAIL $_.Exception.Message
        Get-ChildItem -LiteralPath $backupDir -Filter 'incomplete-deep-research-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        if ($rTouched) {
            if ($rSafety -and (Test-Path -LiteralPath $rSafety)) {
                try {
                    Invoke-Docker -Arguments @('run', '--rm', '-v', "${ResearchVolume}:/data", '-v', "${rSafety}:/restore.tar.gz:ro", $img, 'sh', '-c', $rBack) | Out-Null
                    Write-LaiLog OK 'The data from before the restore was put back.'
                } catch {
                    $keepStopped = $true
                    Write-LaiLog FAIL "Putting the earlier data back failed too ($($_.Exception.Message)). Deep research is kept stopped; the earlier data is in ${rSafety}: run this again with -DeepResearch -Archive '$rSafety'."
                }
            } else {
                # No safety copy (-SkipSafetyBackup, or a new volume): the volume may be half written.
                $keepStopped = $true
                Write-LaiLog FAIL "Deep research is kept stopped (its data may be incomplete): run this again with -DeepResearch -Archive '$($source.FullName)'."
            }
        }
    } finally {
        if ($policy -and $policy -ne 'no' -and -not $keepStopped) { Invoke-Docker -Arguments @('update', '--restart', $policy, $ResearchContainer) -AllowFail | Out-Null }
        if ($wasRunning -and -not $keepStopped) {
            if ((Invoke-Docker -Arguments @('start', $ResearchContainer) -AllowFail).ExitCode -ne 0) { Write-LaiLog WARN 'Deep research did not start again: Start menu > Local AI > Start again.' }
        }
        Remove-Item -LiteralPath (Join-Path $stagingDir 'restore-deep-research.tar.gz') -Force -ErrorAction SilentlyContinue
        Exit-LaiVolumeLock $lock
    }
    exit $code
}

# Pick and confirm the archive before taking the lock, so an unanswered prompt never blocks the
# nightly backup.
if (-not $Archive) {
    $daily = @(Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.LastWriteTime -le (Get-Date).AddHours(1) } | Sort-Object LastWriteTime -Descending)  # lai-ok: objects (never one dated in the future)
    # While the nightly backup has the data marked as wiped (backup-state.json: emptied), a nightly
    # name proves nothing: a night whose database check did not run keeps one although it holds the
    # wiped data. So the last good archive is taken, or else the newest one made before the mark.
    $mark = $null
    try { $mark = (Read-LaiState -Path (Join-Path $AIRoot 'backup-state.json'))['emptied'] } catch { Write-Verbose 'backup state not read' }
    if ($mark -is [hashtable]) {
        $lastGood = ''; if ($mark['lastGood']) { $lastGood = Split-Path -Leaf ([string]$mark['lastGood']) }
        # (PowerShell 7 reads the saved time back as a date, Windows PowerShell 5.1 as text.)
        $at = $null; try { $at = [datetime]$mark['at'] } catch { Write-Verbose 'the mark has no usable date' }
        $when = 'an earlier night'; if ($at) { $when = $at.ToString('yyyy-MM-dd HH:mm') }
        $fromBefore = @($daily | Where-Object { $_.Name -eq $lastGood })
        if ($fromBefore.Count -eq 0 -and $at) {
            $stamp = $at.ToString('yyyyMMdd-HHmmss')
            $fromBefore = @($daily | Where-Object { [string]::CompareOrdinal($_.Name.Substring(11, 15), $stamp) -lt 0 })
        }
        if ($fromBefore.Count -eq 0) { throw "The nightly backup marked Open WebUI's data as wiped on $when, and no nightly backup from before that is in $backupDir. Pass -Archive <file> (one from your backup mirror, if you have one)." }
        Write-LaiLog INFO "The nightly backup marked Open WebUI's data as wiped on ${when}: taking $($fromBefore[0].Name), made before that."
        $daily = $fromBefore
    }
    if ($daily.Count -eq 0) { throw "No daily backups found in $backupDir. Pass -Archive <file>." }
    $Archive = $daily[0].FullName
}
if (-not (Test-Path -LiteralPath $Archive)) { throw "Archive not found: $Archive" }
# An archive the nightly backup set aside because the database had lost its users or chats (a wiped
# volume). It is never picked above; named on purpose, it gets a question of its own first.
$leaf = Split-Path -Leaf $Archive
if ($leaf -like '*-EMPTY.tar.gz') {
    Write-LaiLog WARN "$leaf was set aside by the nightly backup: Open WebUI's data was already wiped when it was made, so restoring it brings back an (almost) empty Open WebUI. Without -Archive the newest backup that still has the data is used."
    if (-not $Force -and (Read-Host 'Type YES to restore this emptied backup all the same') -cne 'YES') { Write-LaiLog INFO 'Nothing changed.'; exit 1 }
}
if (-not $Force) {
    $info = Get-Item -LiteralPath $Archive
    Write-LaiLog WARN ("This replaces ALL current Open WebUI data (chats, memories, knowledge, settings) with {0} from {1}." -f $info.Name, $info.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    Write-LaiLog INFO 'A verified safety backup of the current data is taken first, and the swap rolls back if anything fails.'
    if ((Read-Host 'Type YES to restore') -cne 'YES') { Write-LaiLog INFO 'Nothing changed.'; exit 1 }
}

try {
    $lock = Enter-LaiVolumeLock

    # 1. Archive selection and staging copy.
    if (-not $Archive) {
        $newest = Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.LastWriteTime -le (Get-Date).AddHours(1) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects (never one dated in the future)
        if (-not $newest) { throw "No daily backups found in $backupDir. Pass -Archive <file>." }
        $Archive = $newest.FullName
    }
    $source = Get-Item -LiteralPath $Archive
    # Without the engine every archive would look unreadable below: say what is actually wrong.
    if ((Invoke-Docker -Arguments @('version', '--format', '{{.Server.Version}}') -AllowFail).ExitCode -ne 0) {
        throw 'Docker Desktop is not running, so the backup could not be opened. Start it (Start menu > Local AI - Start again), wait until it says Engine running, then run the restore again. Nothing was checked or changed.'
    }
    if (-not (Test-Path -LiteralPath $stagingDir)) { New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null }
    $staged = Join-Path $stagingDir 'restore.tar.gz'
    Copy-Item -LiteralPath $source.FullName -Destination $staged -Force
    if (-not (Test-Archive $staged)) { throw "$($source.Name) is not a valid Open WebUI backup (unreadable, or no top-level webui.db)." }
    Write-LaiLog INFO ("Restoring {0} ({1:N1} MB, {2})" -f $source.Name, ($source.Length / 1MB), $source.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))

    # The named container, if it exists, must actually use this volume for its data.
    $mounts = Invoke-Docker -Arguments @('inspect', '--type', 'container', '--format', '{{range .Mounts}}{{.Name}}|{{.Destination}}{{println}}{{end}}', $Container) -AllowFail
    if ($mounts.ExitCode -eq 0 -and $mounts.Text -notmatch ('(?m)^' + [regex]::Escape($Volume) + '\|/app/backend/data\s*$')) {
        throw "Container '$Container' does not keep its data in volume '$Volume'; refusing to restore into the wrong place."
    }

    # A helper an earlier restore left running in the volume (its window was closed during the
    # swap, or Docker did not stop it) is ended by its name before the volume is read or written.
    # Found only in step 3, among the containers that use the volume, it would be writing while the
    # safety backup is taken, then be waited on for 30 seconds and 'started again' at the end.
    Stop-SwapHelper | Out-Null

    # 2. Safety backup (verified, never pruned or mirrored here).
    $volumeExists = (Invoke-Docker -Arguments @('volume', 'inspect', $Volume) -AllowFail).ExitCode -eq 0
    if (-not $volumeExists) {
        Write-LaiLog INFO "Volume '$Volume' does not exist yet; creating it (nothing to back up)."
        Invoke-Docker -Arguments @('volume', 'create', $Volume) | Out-Null
    } elseif ($SkipSafetyBackup) {
        Write-LaiLog WARN 'No safety backup (-SkipSafetyBackup): the current data cannot be recovered if this restore is wrong.'
    } else {
        $before = @(Get-ChildItem -LiteralPath $backupDir -Filter '*-pre-restore.tar.gz' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        # No SQLite deep check here: when the live database is the thing that is broken, that check
        # would quarantine the safety copy and block the very restore meant to fix it.
        & (Join-Path $PSScriptRoot 'Backup-OpenWebUI.ps1') -AIRoot $AIRoot -Volume $Volume -Container $Container -Tag 'pre-restore' -NoPrune -NoMirror -SkipDeepVerify
        $safety = Get-ChildItem -LiteralPath $backupDir -Filter '*-pre-restore.tar.gz' | Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
        if ($LASTEXITCODE -ne 0 -or -not $safety -or -not (Test-Archive $safety.FullName)) {
            throw "The safety backup of your current data failed, so nothing was changed. The reason is in $(Join-Path (Join-Path $AIRoot 'Logs') 'backup.log') (most often: the disk is full). Fix that, then run the restore again."
        }
    }

    # 3. Stop everything that uses the volume, then swap.
    $users = @((Invoke-Docker -Arguments @('ps', '-q', '--filter', "volume=$Volume")).Text -split "`n" | Where-Object { $_ })
    # A run cut off after turning a policy off (below) left the container running with policy 'no'
    # and the original in its hold: take it from there, or the recovery would keep 'no' for good.
    $earlier = Get-LaiWebUIHold -AIRoot $AIRoot
    $toStop = @()
    foreach ($id in $users) {
        $policy = (Invoke-Docker -Arguments @('inspect', '-f', '{{.HostConfig.RestartPolicy.Name}}', $id) -AllowFail).Text.Trim()
        if (-not $policy) { $policy = 'no' }
        if ($policy -eq 'no' -and $earlier -and $earlier['Containers']) {
            foreach ($h in @($earlier['Containers'])) { if ([string]$h['Id'] -eq $id -and $h['Policy']) { $policy = [string]$h['Policy'] } }
        }
        $toStop += [pscustomobject]@{ Id = $id; Policy = $policy }
    }
    # Recorded BEFORE any container is touched: if this window is closed or the PC loses power from
    # here on, no catch or finally runs. Once the swap's second run has started the volume may be
    # half replaced; even before it, a container may be left with its restart policy off (it would
    # then stay down after every reboot, with nothing saying why). The hold keeps the watch, Start
    # again and the installer from starting Open WebUI, says how to finish, and holds the original
    # policies the recovery puts back. Cleared on success, after a rollback that worked, and on a
    # failure before the old data was touched (that includes an archive that did not unpack). It
    # stays when the swap's second run failed without a rollback, or when that run or the rollback
    # after it was stopped (Ctrl+C).
    $priorHold = Test-Path -LiteralPath $holdPath
    if (-not $priorHold) {
        $script:recoverCmd = "& $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive $(ConvertTo-LaiPsQuoted (Get-Item -LiteralPath $Archive).FullName) -SkipSafetyBackup"
        if ($safety) { $script:holdArchive = $safety.FullName }
        Set-Hold 'a restore was interrupted (or is still running)' $toStop
        $script:holdWritten = $true
    }
    foreach ($c in $toStop) {
        # Listed before its policy is turned off: if that or the stop fails (or Ctrl+C), 'finally'
        # still puts the policy back and starts it.
        $stoppedContainers += $c
        Invoke-Docker -Arguments @('update', '--restart', 'no', $c.Id) -AllowFail | Out-Null   # keep it down even across a reboot
        Invoke-Docker -Arguments @('stop', '-t', '30', $c.Id) | Out-Null
    }
    $back = @((Invoke-Docker -Arguments @('ps', '--filter', "volume=$Volume", '--format', '{{.Names}} ({{.Image}}, {{.Status}})')).Text -split "`n" | Where-Object { $_.Trim() })
    if ($back.Count -gt 0) {
        throw "Something restarted a container on volume '$Volume' ($($back -join '; ')); aborting before any change."
    }
    Invoke-Swap $staged
    Write-LaiLog OK "Volume '$Volume' now holds $($source.Name)"
    # Recovering from an earlier failed restore: its containers are already stopped (so not listed
    # above) and their policy is 'no'. Only now that the data is good, bring them back with the
    # policy they had (adding them before the swap would start them on the damaged volume on failure).
    $hold = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($hold -and $hold['Containers']) {
        foreach ($h in @($hold['Containers'])) {
            if (@($stoppedContainers | ForEach-Object { $_.Id }) -notcontains $h['Id'] -and
                (Invoke-Docker -Arguments @('inspect', '--type', 'container', $h['Id']) -AllowFail).ExitCode -eq 0) {
                $stoppedContainers += [pscustomobject]@{ Id = [string]$h['Id']; Policy = [string]$h['Policy'] }
            }
        }
    }
    # The data is in place: clear the hold while still holding the lock, so nothing (Start again, a
    # waiting update, the nightly backup) sees a stale "interrupted" hold after a restore that worked.
    Clear-Hold 'Restore complete: Open WebUI may run again'
} catch {
    $failure = $_.Exception.Message
    Write-LaiLog FAIL $failure
    if ($volumeTouched) {
        if ($safety) {
            Write-LaiLog WARN "Rolling back to the safety backup $($safety.Name)"
            $rolledBack = $false
            # From here on the way out is the safety backup, not the archive whose swap has just
            # failed. Set before the rollback starts, not only once it has failed: a rollback that
            # is stopped (Ctrl+C) skips its 'catch', and 'finally' then records and prints this
            # command. It used to be the one for the archive that had just failed, and the safety
            # backup, which holds the newest data, was offered as a command nowhere.
            $script:recoverCmd = "& $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive $(ConvertTo-LaiPsQuoted $safety.FullName) -SkipSafetyBackup"
            $script:holdArchive = $safety.FullName
            $rollbackStarted = $true
            try {
                Invoke-Swap $safety.FullName
                Write-LaiLog OK 'Rollback complete: the volume is as it was before the restore.'
                $rolledBack = $true
            }
            catch {
                Write-LaiLog FAIL "Rollback failed too: $($_.Exception.Message)"
                Write-LaiLog FAIL "Open WebUI is left STOPPED (the health watch will not start it). Recover with: $script:recoverCmd"
                # Hold the list first, clear it, then record: if writing the hold fails (full disk), the
                # 'finally' below must still not start Open WebUI on the damaged volume.
                $held = $stoppedContainers
                $stoppedContainers = @()
                try { Set-Hold 'restore and its rollback failed' $held } catch { Write-LaiLog FAIL "Could not record the hold ($($_.Exception.Message)): do NOT start Open WebUI until the restore succeeds." }
            }
            # The data is good again: drop the in-progress hold this run wrote (not an older one).
            # Outside the rollback's try, so a failed delete is not mistaken for a failed rollback.
            if ($rolledBack -and -not $priorHold) { Clear-Hold '' }
        } else {
            # A command that works when pasted: the newest other nightly backup (not the one that just
            # failed, not one dated in the future). Without one, say where to pick a file.
            $other = Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^open-webui-\d{8}-\d{6}\.tar\.gz$' -and $_.FullName -ne $source.FullName -and $_.LastWriteTime -le (Get-Date).AddHours(1) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
            if ($other) {
                $script:recoverCmd = "& $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive $(ConvertTo-LaiPsQuoted $other.FullName) -SkipSafetyBackup"
            } else {
                $script:recoverCmd = "no other nightly backup in $backupDir; copy one from your backup mirror there, then run: & $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive <that file> -SkipSafetyBackup"
            }
            Write-LaiLog FAIL "No safety backup exists; Open WebUI is left STOPPED so it cannot start on a damaged volume (the health watch will not start it). Recover with: $script:recoverCmd"
            # Hold the list first, clear it, then record: if writing the hold fails (full disk), the
            # 'finally' below must still not start Open WebUI on the damaged volume.
            $held = $stoppedContainers
            $stoppedContainers = @()
            try { Set-Hold 'restore failed without a safety backup' $held } catch { Write-LaiLog FAIL "Could not record the hold ($($_.Exception.Message)): do NOT start Open WebUI until the restore succeeds." }
        }
    }
    $script:restoreFailed = $true
} finally {
    # A run of the helper may still be going: Ctrl+C ends the docker client, not the container it
    # started (see $helperName). Ended first, before anything is swept, started or recorded: what
    # is said below about the volume is then true of a volume nothing writes to any more. A helper
    # that could not be seen to stop changes nothing in what follows: it deletes none of the old
    # data in its first run, and the hold below is recorded either way in its second.
    if ($script:extractOpen -or $script:swapOpen) {
        if (-not (Stop-SwapHelper)) {
            Write-LaiLog WARN "Could not make sure that the restore's helper container ($($helperRuns -join ' or ')) has stopped: Docker did not answer, or did not remove it. It may still be working in volume '$Volume'. The next restore stops it before it changes anything."
        }
    }
    # The archive did not unpack, or its unpacking was stopped (Ctrl+C): what it had unpacked by
    # then sits in the volume. None of the old data was deleted for it, but it can be GBs, Open
    # WebUI would start next to it, and every backup from then on would carry it. Best effort,
    # before anything is started. Not while the swap is open: the tree is the data moving in then.
    if ($script:extractOpen -and -not $script:swapOpen) {
        $swept = $false
        try { $swept = ((Invoke-Docker -Arguments @('run', '--rm', '-v', "${Volume}:/data", $img, 'sh', '-c', $sweepScript) -AllowFail).ExitCode -eq 0) }
        catch { Write-Verbose "the helper did not run: $($_.Exception.Message)" }
        if (-not $swept) { Write-LaiLog WARN "Could not remove what the unpacking left in volume '$Volume' (the folder .restore-partial or .restore-staging); the next restore removes it." }
        if (-not $volumeTouched) { Write-LaiLog INFO "The restore ended before the old data was touched: nothing in volume '$Volume' was deleted or replaced by this run." }
    }
    if ($script:swapOpen) {
        # The swap's second run was started and neither came through nor was rolled back: the volume
        # may be half replaced, so nothing is started on it and the hold stays. 'catch' has said so
        # and recorded the hold with the way out, unless it never ran or never came to its end
        # (Ctrl+C skips 'catch', but not 'finally'; it used to start Open WebUI on that volume).
        # Then both are done here, with this run's containers and their original restart policies.
        if (-not $script:restoreFailed) {
            # Hold the list first, clear it, then record (as in 'catch').
            $held = $stoppedContainers
            $stoppedContainers = @()
            # The way out an earlier hold names still applies when this run has none of its own (a
            # recovery run, which writes no hold before its swap). With neither: this archive again.
            $holdNow = $null
            try { $holdNow = Get-LaiWebUIHold -AIRoot $AIRoot } catch { Write-Verbose "the hold was not read: $($_.Exception.Message)" }
            if ($holdNow) {
                if (-not $script:recoverCmd) { $script:recoverCmd = [string]$holdNow['Recover'] }
                if (-not $script:holdArchive) { $script:holdArchive = [string]$holdNow['Archive'] }
            }
            if (-not $script:recoverCmd) { $script:recoverCmd = "& $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive $(ConvertTo-LaiPsQuoted $source.FullName) -SkipSafetyBackup" }
            # What was stopped: the restore itself, or the rollback after its swap had failed (the way
            # out is then the safety backup, which 'catch' set before the rollback began).
            # A stopped rollback may not have come to replacing anything yet (it unpacks first), but
            # the swap that failed before it has.
            $holdWhy = 'a restore was stopped while it replaced the data'
            $stoppedWhat = "The restore was stopped while it replaced the data in volume '$Volume', which may be half replaced."
            if ($rollbackStarted) {
                $holdWhy = 'the rollback of a failed restore was stopped before it was through'
                $stoppedWhat = "The rollback to the safety backup was stopped before it was through, so the data in volume '$Volume' may still be half replaced."
            }
            # The watch is named only once the hold is on record: without one it would start Open WebUI.
            $watchNote = ''
            try { Set-Hold $holdWhy $held; $watchNote = ' (the health watch will not start it)' }
            catch { Write-LaiLog FAIL "Could not record the hold ($($_.Exception.Message)): do NOT start Open WebUI until the restore succeeds." }
            Write-LaiLog FAIL "$stoppedWhat Open WebUI is left STOPPED${watchNote}. Recover with: $script:recoverCmd"
        }
    } else {
        foreach ($c in $stoppedContainers) {
            try {
                Invoke-Docker -Arguments @('update', '--restart', $c.Policy, $c.Id) -AllowFail | Out-Null
                Invoke-Docker -Arguments @('start', $c.Id) | Out-Null
            } catch { Write-LaiLog WARN "Could not restart container $($c.Id): $($_.Exception.Message)" }
        }
    }
    # Stopped before the old data was touched (an error, an archive that did not unpack, or Ctrl+C,
    # which skips 'catch' but not 'finally'): the containers are back, so drop the in-progress hold
    # this run wrote. After a good restore it is already gone, and after a rollback that worked
    # 'catch' has dropped it; a swap that is still open keeps it (volumeTouched is set with it).
    if ($script:holdWritten -and -not $volumeTouched) { Clear-Hold '' }
    if ($staged -and (Test-Path -LiteralPath $staged)) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
    Exit-LaiVolumeLock $lock
}
if ($script:restoreFailed) { exit 1 }
# Normally cleared under the lock already (above); a last try that never throws.
Clear-Hold 'Earlier failed restore cleared: Open WebUI may run again'

# 4. Wait for Open WebUI.
# Why step 5 did not put this install's safety settings back; '' once it has.
$notReapplied = 'Open WebUI was not running, so its settings could not be reached'
if ($stoppedContainers.Count -gt 0) {
    $configPath = Join-Path $AIRoot 'localai-config.json'
    $config = Read-LaiState -Path $configPath
    $port = 3000
    if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
    $up = $false
    # -WebUIWaitSec: 5 minutes unless given.
    try { Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec $WebUIWaitSec; Write-LaiLog OK "Open WebUI is back on http://localhost:$port"; $up = $true }
    catch {
        # The models a backup leaves out came along in the swap if the volume had them. A volume that
        # had none (a new one, or the models were deleted) makes Open WebUI download them at this start.
        Write-LaiLog WARN "Data restored, but Open WebUI did not answer within $([math]::Round($WebUIWaitSec / 60, 1)) minutes. It may still be fetching its document-search models (several GB, when the volume had none): give it some minutes, and check 'docker logs --tail 100 $Container'."
        if ($safety) {
            # That copy fits the version that ran before this restore. Update-OpenWebUI.ps1 -Rollback
            # switches the version right before it calls this script: put back by itself there, the
            # copy would land the data the newer version migrated under the older image.
            Write-LaiLog INFO ("If it does not come up, the data from before this restore is in $($safety.Name). It goes with the Open WebUI version that was running before this restore: where the version was switched as well (Update-OpenWebUI.ps1 -Rollback does that), switch it back first. " +
                "Then, to go back to that data: & $(ConvertTo-LaiPsQuoted (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1')) -AIRoot $(ConvertTo-LaiPsQuoted $AIRoot) -Archive $(ConvertTo-LaiPsQuoted $safety.FullName)")
        }
        $notReapplied = 'Open WebUI did not answer'
    }
    if ($up) {
        # Update-OpenWebUI.ps1 marks an update whose new version had not answered when it ended
        # (UpdatePending) and takes the mark off in a later run of its own. Open WebUI answers now,
        # so the mark goes here as well: after a recovery by hand (the old version, then this
        # restore) it would sit on a healthy install, and the next update would speak of an update
        # that had not answered. Read again first: the wait above can take minutes.
        try {
            $configNow = Read-LaiState -Path $configPath
            if ($configNow.ContainsKey('UpdatePending')) {
                [void]$configNow.Remove('UpdatePending')
                Save-LaiState -State $configNow -Path $configPath
            }
        } catch { Write-Verbose "the update mark stays: $($_.Exception.Message)" }
    }

    # 5. The restored database carries the settings from when the backup was taken, including the
    # Ollama connection: a backup from before the render guard points straight at Ollama. Put the
    # connection this install uses back (the installer recorded it).
    if ($up) {
        $expected = 'http://render-guard:11434'
        if ($config.ContainsKey('WebUIOllamaUrl') -and $config['WebUIOllamaUrl']) { $expected = [string]$config['WebUIOllamaUrl'] }
        $credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
        try {
            try { Resolve-LaiPendingPassword -AIRoot $AIRoot -BaseUrl "http://127.0.0.1:$port" | Out-Null } catch { Write-Verbose 'pending password check failed' }
            $cred = Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json
            $token = Connect-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -Email $cred.email -Password $cred.password
            # A try of its own: an error here is not a failed sign-in, and must not keep the safety
            # settings below from being put back.
            try {
                # Test only (-TestFailOllamaUrl, which only tests/Invoke-UpdateWebUITest.ps1 passes): the
                # connection counts as not set, the way an error from Open WebUI ends this step, with
                # the parameter named in the warning below.
                if ($TestFailOllamaUrl) { throw 'the test parameter -TestFailOllamaUrl was passed, which makes this step fail (no shortcut and no scheduled task passes it, so something else started this run)' }
                if (Set-LaiWebUIOllamaUrl -BaseUrl "http://127.0.0.1:$port" -Token $token -OllamaUrl $expected) {
                    Write-LaiLog OK "Re-applied this install's Ollama connection ($expected) to the restored settings"
                }
            } catch {
                Write-LaiLog WARN "Could not re-apply this install's Ollama connection ($expected) to the restored settings: $($_.Exception.Message). If chats get no answer, run Start menu > Local AI - Update toolkit"
            }
            # The same goes for what keeps your chats on this PC. A backup from before the toolkit
            # turned them off brings back sign-up for anyone who reaches the page, presets whose model
            # can search and read every past chat, run code or use the seven writing tools (notes,
            # tasks, automations, calendar, notifications, channels, sub-agents), and uncensored presets
            # that search the web without being asked. A try of its own: an error here is not a failed
            # sign-in.
            try {
                $base = "http://127.0.0.1:$port"
                Set-LaiWebUIAdminConfig -BaseUrl $base -Token $token -Changes @{ ENABLE_SIGNUP = $false } | Out-Null
                if ((Invoke-LaiApi -Uri "$base/api/v1/auths/admin/config" -Token $token).ENABLE_SIGNUP -ne $false) { throw "Open WebUI did not keep 'sign-up off'" }
                # $CatalogPath: config\models.psd1 next to this script, unless -CatalogPath named another.
                if ($catalogGiven) { Write-LaiLog INFO "The presets to look at are those of the catalog given with -CatalogPath: $CatalogPath" }
                # The module's walk, the one the installer runs, over that catalog's entries: each preset
                # that is in the restored data is judged (past chats, code, the writing tools and, on a
                # preset that is not an official one, what is on by default for every chat), written safe
                # when it leaves anything on, and read back. One that is not there is passed over (nothing
                # is created). A write that fails, or that Open WebUI does not keep, is an error: it ends
                # this step, and the warning at the end says the settings were not put back. This script
                # used to have a loop of its own here, which knew nothing of the writing tools and logged
                # the settings as put back with those still on.
                $walked = @(Invoke-LaiPresetSafety -BaseUrl $base -Token $token -Entries @((Get-LaiCatalog -Path $CatalogPath -IncludeTrials).Models))
                # What else Open WebUI holds, asked also when the walk found none: a preset no entry of
                # the catalog names (one you made, one of another catalog, one the toolkit has retired)
                # came back with the backup too, and a chat can be started on it. Each one is held to the
                # same judge and named when it leaves anything on. None is changed: it is not the
                # toolkit's, and the switches on it may be meant. A try of its own, which only warns:
                # what the walk did stands, and a list that cannot be read must not turn it into 'the
                # settings could not be applied', or end a restore that worked as failed.
                $whose = "the toolkit's presets"
                if ($catalogGiven) { $whose = 'the presets of the catalog given with -CatalogPath' }
                try {
                    $covered = @($walked | ForEach-Object { [string]$_.Preset })
                    foreach ($pm in @(Invoke-LaiApi -Uri "$base/api/v1/models/export" -Token $token | ForEach-Object { $_ })) {
                        # An answer that is not a list of entries with an id (a text, an object around
                        # the list) cannot be read here and is said as that: passed over, it would look
                        # like an Open WebUI that holds no other preset.
                        if ($null -eq $pm -or -not $pm.PSObject.Properties['id']) { throw 'what it sent is not a list of presets' }
                        # No base model: Open WebUI's entry for one of Ollama's own models, not a preset.
                        if (-not $pm.base_model_id) { continue }
                        # Held against the ids the walk covered character for character (IndexOf, as the
                        # walk does it): a look-alike id must not pass for a preset that was made safe.
                        if ([array]::IndexOf($covered, [string]$pm.id) -ge 0) { continue }
                        # No skip for a preset without meta: Open WebUI takes every switch that is not
                        # written out as off for on, and the judge counts it that way.
                        $risks = @(Get-LaiPresetToolRisk $pm.meta)
                        if ($risks.Count -eq 0) { continue }
                        # The name is text from the restored data: on one line, whatever it holds (line
                        # breaks and control characters become a blank). A preset without one goes by its id.
                        $presetName = ([string]$pm.name -replace '[\s\x00-\x1f\x7f]+', ' ').Trim()
                        if (-not $presetName) { $presetName = ([string]$pm.id -replace '[\s\x00-\x1f\x7f]+', ' ').Trim() }
                        Write-LaiLog WARN "The restored data holds the preset '$presetName', which is not one of ${whose}: the assistant can $($risks -join ' and ') there. It was left as it is. If that is not what you want, switch it off in Open WebUI: Workspace > Models > $presetName"
                    }
                } catch {
                    Write-LaiLog WARN "Could not read the list of presets from Open WebUI ($(Get-LaiHttpErrorText $_)), so the presets in the restored data that are not among $whose were not all looked at: one of them may let the assistant read past chats, run code or use the writing tools. Look through them in Open WebUI: Workspace > Models"
                }
                # None of them there (a backup of another install, presets since retired): no preset was
                # looked at, so nothing may say the presets are fine. The warning below gives the way.
                if ($walked.Count -eq 0) { throw "sign-up is off again, but none of the toolkit's presets is in the restored data, so no preset was checked" }
                $what = 'all had past-chat search, code execution and the writing tools off already'
                # What the walk wrote, in its words: the preset's name and what the assistant could do there.
                $changed = @($walked | Where-Object { $_.Written } | ForEach-Object { "$($_.Display) ($($_.On -join ' and '))" })
                if ($changed.Count -gt 0) { $what = 'turned off on the restored presets: ' + ($changed -join '; ') }
                Write-LaiLog OK "Re-applied this install's safety settings to the restored data: sign-up off; $($walked.Count) toolkit preset(s) checked, $what"
                $notReapplied = ''
            } catch { $notReapplied = $_.Exception.Message }
        } catch {
            Write-LaiLog WARN (("Could not sign in with {0}: the restored data has the admin password from when the backup was taken. " -f $credFile) +
                'Run Set-OpenWebUIPassword.ps1 -PromptCurrent (type that old password), then re-run Install-LocalAI.ps1 to re-apply presets and the render guard.')
            $notReapplied = 'the sign-in failed (set the password right first, as said above)'
        }
    }
}
if ($notReapplied) {
    Write-LaiLog WARN ("The restored data has the settings from when the backup was taken, and this install's safety settings (sign-up off; past-chat search, code execution, the writing tools and unasked web search off on the presets) were not put back: $notReapplied. " +
        'To put them back, run Start menu > Local AI - Update toolkit')
}
exit 0
