#Requires -Version 5.1

<#
.SYNOPSIS
    Backs up, then updates Open WebUI (and optionally SearXNG) to a newer pinned image.

.DESCRIPTION
    Replaces the guide's manual "docker pull / stop / rm / run" sequence (Part 23). Versions are pinned
    in <AIRoot>\Stack\.env, so nothing changes until you run this. Data lives in the "open-webui"
    volume and survives the container being recreated.

    An update whose new version does not answer within 10 minutes (-WebUIWaitSec sets another
    wait) is remembered as one that had not answered when it ended. Running the same update again
    then waits for Open WebUI once more and says how it went (it never says 'Already on'). An
    update to another version first looks whether Open WebUI answers by now; while it runs and
    still does not, that update is refused (-Rollback goes back first), because its backup would
    hold the broken state and replace the rollback point. While Open WebUI is stopped nothing can
    be seen, so both say to start it first.

.EXAMPLE
    .\Update-OpenWebUI.ps1 -Latest              # newest GitHub release of Open WebUI
.EXAMPLE
    .\Update-OpenWebUI.ps1 -Version v0.11.5     # a specific release
.EXAMPLE
    .\Update-OpenWebUI.ps1 -Rollback           # undo the last Open WebUI update: previous image + the data
                                                # from just before it (the 'before-<version>' backup)
.EXAMPLE
    .\Update-OpenWebUI.ps1 -SearxngVersion 2026.10.2-19ffbcd30   # SearXNG only; it keeps no data, so going
                                                # back is the same command with the old tag (printed by the update)
#>
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    [string]$Version = '',
    [switch]$Latest,
    # Also move SearXNG to this image tag.
    [string]$SearxngVersion = '',
    # Skip the backup before the update (then -Rollback has no matching data).
    [switch]$SkipBackup,
    # Undo the last Open WebUI update: switch back to the previous image and restore the backup taken
    # right before it (Open WebUI migrates its database on upgrade, so the old image needs old data).
    # SearXNG is not changed by it; a SearXNG update prints its own way back (-SearxngVersion <old tag>).
    [switch]$Rollback,
    # Skip the "type YES" confirmation of -Rollback. With -Version or -Latest: update all the same
    # when the last update had not answered and Open WebUI still does not (without it that is refused).
    [switch]$Force,
    # The models catalog for the health check that ends an update, and for the restore of -Rollback
    # (handed on to Test-LocalAI.ps1 and Restore-OpenWebUI.ps1). Defaults to config\models.psd1 next
    # to those scripts.
    [string]$CatalogPath = '',
    # How many seconds the new version gets to answer (10 minutes unless given). With -Rollback the
    # restore waits that long as well (5 minutes unless given).
    [ValidateRange(1, [int]::MaxValue)][int]$WebUIWaitSec = 600
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

# -CatalogPath and -WebUIWaitSec are handed on only when given: without them Test-LocalAI.ps1 and
# Restore-OpenWebUI.ps1 keep their own defaults. The catalog is looked at before anything is
# changed (the scripts that read it run after the update, or in the middle of a rollback) and kept
# as a full path.
$catalogArgs = @{}
if ($CatalogPath) {
    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw "The models catalog given with -CatalogPath was not found: $CatalogPath. Nothing was changed." }
    $catalogArgs['CatalogPath'] = (Resolve-Path -LiteralPath $CatalogPath).ProviderPath
}
$restoreArgs = $catalogArgs.Clone()
if ($PSBoundParameters.ContainsKey('WebUIWaitSec')) { $restoreArgs['WebUIWaitSec'] = $WebUIWaitSec }

$stack = Join-Path $AIRoot 'Stack'
$envPath = Join-Path $stack '.env'
$compose = Join-Path $stack 'docker-compose.yml'
if (-not (Test-Path -LiteralPath $envPath)) { throw "No stack found at $stack. Run Install-LocalAI.ps1 first." }

$configPath = Join-Path $AIRoot 'localai-config.json'
$updateLog = Join-Path (Join-Path $AIRoot 'Logs') 'update.log'
function Write-UpdateLog {
    param([string]$Level, [string]$Message)
    Write-LaiLog $Level $Message
    try { Add-Content -LiteralPath $updateLog -Value ('{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message) -Encoding UTF8 } catch { Write-Verbose 'no update log' }
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
function Get-DockerResult {
    # Captured output and exit code; never throws (for optional steps such as removing old images).
    param([string[]]$Arguments)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& docker @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ ExitCode = $code; Text = ($out -join "`n") }
}

$config = Read-LaiState -Path $configPath
$port = 3000; if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
$base = @('compose', '--project-directory', $stack, '-f', $compose)
# How long a new version gets to answer: -WebUIWaitSec, 10 minutes unless given.
$waitSec = $WebUIWaitSec

function Clear-UpdatePending {
    # Open WebUI answered: the last update is no longer one that had not answered (see UpdatePending below).
    if (-not $config.ContainsKey('UpdatePending')) { return }
    [void]$config.Remove('UpdatePending')
    Save-LaiState -State $config -Path $configPath
}
function Test-WebUIContainerRunning {
    # Is there an Open WebUI to wait for? $true while its container runs (one that keeps restarting
    # counts as running). $false when it is stopped (Stop-LocalAI.ps1, 'docker stop'), gone, or
    # Docker does not answer (Docker Desktop quit, or still starting): no answer then says nothing
    # about the last update, and going back to the backup from before it is no advice to give.
    $state = Get-DockerResult -Arguments @('inspect', '-f', '{{.State.Running}}', 'open-webui')
    return [bool]($state.ExitCode -eq 0 -and $state.Text -match '(?m)^\s*true\s*$')
}

function Invoke-PullFirst {
    # Downloads the images for the new versions WITHOUT touching .env: docker compose takes a
    # variable from the environment before the one in .env. .env is switched only once the
    # download is complete, so a window closed, a restart or a power cut during the multi-GB pull
    # (no catch or finally runs then) leaves .env on the version that is running. Before, it named
    # a version that was never downloaded: a re-run said 'Already on', the nightly deep check was
    # skipped, and the next Start again pulled and migrated outside this script.
    param([string]$OpenWebUI, [string]$Searxng, [string[]]$Services = @())
    $envNow = @{}
    foreach ($l in (Get-Content -Encoding UTF8 -LiteralPath $envPath)) { if ($l -match '^([A-Z_]+)=(.*)$') { $envNow[$Matches[1]] = $Matches[2] } }
    $tags = @()
    if ($OpenWebUI) { $tags += $OpenWebUI } else { $tags += [string]$envNow['OPEN_WEBUI_VERSION'] }
    if (@($Services).Count -eq 0 -or @($Services) -contains 'searxng') { if ($Searxng) { $tags += $Searxng } else { $tags += [string]$envNow['SEARXNG_VERSION'] } }
    $saved = @{}
    foreach ($n in @('OPEN_WEBUI_VERSION', 'SEARXNG_VERSION')) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    try {
        if ($OpenWebUI) { Set-LaiProcessEnv -Name 'OPEN_WEBUI_VERSION' -Value $OpenWebUI }
        if ($Searxng) { Set-LaiProcessEnv -Name 'SEARXNG_VERSION' -Value $Searxng }
        # Pinned versions already on disk are reused (no registry, no Docker Hub rate limit);
        # floating tags (main, latest) are re-pulled.
        Invoke-Docker -Arguments ($base + @('pull', '--policy', (Get-LaiPullPolicy -Tags $tags)) + @($Services))
    } finally {
        foreach ($n in @($saved.Keys)) { Set-LaiProcessEnv -Name $n -Value $saved[$n] }
    }
}

function Get-RunningTag {
    # The Open WebUI tag the container was created from; '' when there is none (or it is a digest).
    $ri = Get-DockerResult -Arguments @('inspect', '-f', '{{.Config.Image}}', 'open-webui')
    if ($ri.ExitCode -eq 0 -and $ri.Text.Trim() -notmatch '@' -and $ri.Text.Trim() -match ':([^:/]+)$') { return $Matches[1] }
    return ''
}
function Get-EnvWebUIVersion {
    return ((Get-Content -Encoding UTF8 -LiteralPath $envPath | Where-Object { $_ -like 'OPEN_WEBUI_VERSION=*' } | Select-Object -First 1) -replace '^OPEN_WEBUI_VERSION=', '')
}
function Repair-EnvFromRunning {
    # An update by an older version of this script that was cut off mid-download left .env naming
    # the new version while the old one kept running. Put .env back on what runs before anything
    # else: otherwise a SearXNG-only update (or the next Start again) pulls and starts that version
    # on the live data with no backup for it, and '-Version <it>' says 'Already on' and stops.
    $runningTag = Get-RunningTag; $envTag = Get-EnvWebUIVersion
    if (-not $runningTag -or -not $envTag -or $runningTag -eq $envTag) { return }
    $l = Enter-LaiVolumeLock -TimeoutSec 900
    try {
        # Again under the lock: an update that held it meanwhile may have switched both already.
        $runningTag = Get-RunningTag; $envTag = Get-EnvWebUIVersion
        if ($runningTag -and $envTag -and $runningTag -ne $envTag) {
            Write-UpdateLog WARN "Stack\.env names Open WebUI $envTag, but $runningTag is running (an earlier update was interrupted during the download). Setting Stack\.env back to $runningTag first."
            Set-EnvVersion -OpenWebUI $runningTag
        }
    } finally { Exit-LaiVolumeLock $l }
}

$hold = Get-LaiWebUIHold -AIRoot $AIRoot
if ($hold) { throw "Open WebUI is kept stopped after a failed restore ($($hold['Reason'])); updating now would start it on damaged data. Recover first: $($hold['Recover'])" }
Repair-EnvFromRunning

# The rollback point of the last update: the version before it and the backup taken right before it.
# -Rollback works only with both, and with that archive still there.
$prevVer = ''; $archive = ''
if ($config.ContainsKey('PreviousOpenWebUIVersion')) { $prevVer = [string]$config['PreviousOpenWebUIVersion'] }
if ($config.ContainsKey('RollbackArchive')) { $archive = [string]$config['RollbackArchive'] }
$rbOk = [bool]($prevVer -and $archive -and (Test-Path -LiteralPath $archive))
$archiveName = ''; if ($archive) { $archiveName = Split-Path -Leaf $archive }

if ($Rollback) {
    if (-not $rbOk) {
        # The old image first, then the old data: restored first, the new version would start on the
        # old data and migrate it again before the old image is there.
        throw 'Nothing to roll back: no update with a backup is recorded (or its before-<version> backup is gone). By hand: Update-OpenWebUI.ps1 -Version <old> -SkipBackup first, then Restore-OpenWebUI.ps1 -Archive <file>.'
    }
    $cur = ((Get-Content -Encoding UTF8 -LiteralPath $envPath | Where-Object { $_ -like 'OPEN_WEBUI_VERSION=*' } | Select-Object -First 1) -replace '^OPEN_WEBUI_VERSION=', '')
    Write-UpdateLog WARN "Rollback: Open WebUI $cur -> $prevVer, and the data from $archiveName (chats since that update are lost; a safety backup of the current data is taken first)."
    if (-not $Force -and (Read-Host 'Type YES to roll back') -cne 'YES') { Write-UpdateLog INFO 'Nothing changed.'; exit 1 }
    # The restore below takes a safety backup of its own (the data $cur migrated, from just before
    # this rollback). It is the newest pre-restore archive that was not there before.
    $backupDir = Join-Path $AIRoot 'Backups'
    $safetyWere = @(Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*-pre-restore.tar.gz' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $safetyNew = $null
    $lock = Enter-LaiVolumeLock -TimeoutSec 900
    try {
        # Again under the lock: a restore that held it while this waited may have failed meanwhile.
        $hold = Get-LaiWebUIHold -AIRoot $AIRoot
        if ($hold) { throw "Open WebUI is kept stopped after a failed restore ($($hold['Reason'])). Recover first: $($hold['Recover'])" }
        # Old image first (it may not start on the migrated database; that is expected), then the
        # restore stops it, swaps in the pre-update data and starts it again.
        $envBefore = @(Get-Content -Encoding UTF8 -LiteralPath $envPath)
        # Download first, .env after: until the old image is here, .env must keep naming the version
        # that is running, or the next Start again or installer run would start the old image on the
        # already-migrated database (also after a closed window or a power cut mid-download).
        try { Invoke-PullFirst -OpenWebUI $prevVer -Services @('open-webui') }
        catch { throw "Could not download Open WebUI $prevVer, nothing was changed: $($_.Exception.Message)" }
        Set-EnvVersion -OpenWebUI $prevVer
        Invoke-Docker -Arguments ($base + @('up', '-d', 'open-webui'))
        & (Join-Path $PSScriptRoot 'Restore-OpenWebUI.ps1') -AIRoot $AIRoot -Archive $archive -Force @restoreArgs
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
        $safetyNew = Get-ChildItem -LiteralPath $backupDir -Filter 'open-webui-*-pre-restore.tar.gz' -ErrorAction SilentlyContinue | Where-Object { $safetyWere -notcontains $_.FullName } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
    } finally { Exit-LaiVolumeLock $lock }
    $config['OpenWebUIVersion'] = $prevVer
    # The update that was rolled back is no longer one to wait for (UpdatePending).
    $config.Remove('PreviousOpenWebUIVersion'); $config.Remove('RollbackArchive'); $config.Remove('UpdatePending')
    Save-LaiState -State $config -Path $configPath
    try { Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec $waitSec }
    catch {
        # Not a bare timeout: the only way back on screen would be the hint the restore printed for
        # its safety backup, and that archive alone puts the data $cur migrated under $prevVer. The
        # way back from here is the one of the by-hand advice above: the version first, then its data.
        $why = "Open WebUI $prevVer did not come up after the rollback ($($_.Exception.Message)). It may still be starting: check 'docker logs --tail 80 open-webui'"
        if (-not $safetyNew) { throw "$why." }
        throw "$why. To return to Open WebUI $cur and the data from just before this rollback: Update-OpenWebUI.ps1 -Version $cur -SkipBackup first, then Restore-OpenWebUI.ps1 -Archive $(ConvertTo-LaiPsQuoted $safetyNew.FullName)"
    }
    Write-UpdateLog OK "Rolled back to Open WebUI $((Invoke-LaiApi -Uri "http://127.0.0.1:$port/api/version").version)"
    & (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick @catalogArgs
    exit $LASTEXITCODE
}

if ($Latest) {
    $Version = (Invoke-RestMethod -Uri 'https://api.github.com/repos/open-webui/open-webui/releases/latest' -UseBasicParsing).tag_name
    Write-UpdateLog INFO "Latest Open WebUI release: $Version"
}
if ($Version -and (Get-LaiWebUICompat -Version $Version) -eq 'newer') {
    Write-UpdateLog WARN "Open WebUI $Version is newer than the version this toolkit was tested with (0.11.4). It usually works; if the health check after the update fails, Update-OpenWebUI.ps1 -Rollback goes back."
}

# .env names what runs (Repair-EnvFromRunning above).
$current = Get-EnvWebUIVersion
$lines = @(Get-Content -Encoding UTF8 -LiteralPath $envPath)
$currentSx = [string](($lines | Where-Object { $_ -like 'SEARXNG_VERSION=*' } | Select-Object -First 1) -replace '^SEARXNG_VERSION=', '')
if ($SearxngVersion -and $SearxngVersion -eq $currentSx) { $SearxngVersion = '' }
if (-not $Version -and -not $SearxngVersion) { Write-UpdateLog INFO 'Nothing to do: pass -Latest, -Version <tag> or -SearxngVersion <tag> (or -Rollback).'; exit 0 }
# UpdatePending is saved with the rollback point, before .env is switched, and removed once Open
# WebUI answers. Still there for the version .env names: that update had not answered when it ended
# (its health wait timed out, or the run ended before it). 'Already on' would then say nothing about
# Open WebUI, and an update to another version would back up the broken state and record that as
# the rollback point, so the one archive from the working state is pruned later.
# The mark says what was seen then, not what is true now: nothing takes it off between two runs of
# this script (a restore that Open WebUI answers after does), so the update may have come up a
# minute later and been in use for weeks. Hence the look at Open WebUI before anything is said,
# and no word of -Rollback while Open WebUI is merely stopped: that swaps those weeks of chats for
# the backup from before the update.
$pendingNow = [bool]($current -and $config['UpdatePending'] -is [hashtable] -and [string]$config['UpdatePending']['Version'] -eq $current)
$notRunning = "Open WebUI is not running (its container is stopped, or Docker Desktop is not up), so nothing was changed. The last update, to Open WebUI $current, had not answered when it ended; whether it has come up since shows only while it runs. Start it (Start menu > Local AI - Start again), then run this again."
if ($Version -and $Version -eq $current) {
    if ($pendingNow) {
        # The same update again: look at Open WebUI, for as long as the update itself would. A
        # container that is not running is not waited for (10 minutes, to end on -Rollback).
        if (-not (Test-WebUIContainerRunning)) { throw $notRunning }
        Write-UpdateLog INFO "The update to Open WebUI $current had not answered when it ended. Waiting for it again (up to $waitSec s)."
        try { Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec $waitSec }
        catch {
            $why = "Open WebUI $current did not come up ($($_.Exception.Message)). Check 'docker logs --tail 80 open-webui'"
            if ($rbOk) { throw "$why, or undo with: Update-OpenWebUI.ps1 -Rollback" }
            throw "$why. No backup from before that update is recorded, so there is nothing to roll back to."
        }
        Clear-UpdatePending
        $running = (Invoke-LaiApi -Uri "http://127.0.0.1:$port/api/version").version
        Write-UpdateLog OK "Open WebUI $running is up on http://localhost:$port (the update to $current came up after all)"
        if ($rbOk) { Write-UpdateLog INFO "If this version misbehaves: Update-OpenWebUI.ps1 -Rollback (back to $prevVer with the data from $archiveName)" }
        if (-not $SearxngVersion) { exit 0 }
    } elseif (-not $SearxngVersion) { Write-UpdateLog OK "Already on $current"; exit 0 }
    $Version = ''   # SearXNG-only: leave Open WebUI and its rollback point alone
} elseif ($Version -and $pendingNow -and -not $Force) {
    # Another version on top of an update that had not answered. A short look first: it may have
    # come up since (a first start that took longer than the wait). Before the lock, the backup and
    # the download: a refusal changes nothing.
    $containerUp = Test-WebUIContainerRunning
    $answers = $false
    if ($containerUp) {
        try { Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec ([Math]::Min(30, $waitSec)); $answers = $true }
        catch { Write-Verbose "Open WebUI $current does not answer" }
    }
    if ($answers) { Clear-UpdatePending }
    elseif (-not $rbOk) {
        # No rollback point to protect and none to go back to: a refusal would leave no way on at
        # all (-Rollback says 'Nothing to roll back').
        $seenNow = 'is not running'; if ($containerUp) { $seenNow = 'does not answer now' }
        Write-UpdateLog WARN "The last update, to Open WebUI $current, had not answered when it ended, Open WebUI $seenNow, and no backup from before it is recorded to roll back to. Updating to $Version on top of it."
    }
    elseif (-not $containerUp) { throw $notRunning }
    else {
        throw "The last update, to Open WebUI $current, had not answered when it ended, and Open WebUI does not answer now, so nothing was changed. The backup before an update to $Version would hold that state and take the place of the rollback point ($archiveName, from $prevVer). If it was started only just now, give it a few minutes and run this again ('docker logs --tail 80 open-webui' shows what it is doing). If it does not come up, go back first with Update-OpenWebUI.ps1 -Rollback and then update again. Add -Force to update all the same."
    }
}
$pre = $null

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
        if ($LASTEXITCODE -ne 0) { throw "The backup before the update failed, so nothing was changed. The reason is in $(Join-Path (Join-Path $AIRoot 'Logs') 'backup.log') (most often: the disk is full). Fix that, then run the update again." }
        $pre = Get-ChildItem -LiteralPath (Join-Path $AIRoot 'Backups') -Filter "open-webui-*-$tag.tar.gz" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
    }
    # Download first, switch after (see Invoke-PullFirst): an interrupted download changes nothing.
    try { Invoke-PullFirst -OpenWebUI $Version -Searxng $SearxngVersion }
    catch { throw "Could not pull the new image(s), nothing was changed: $($_.Exception.Message)" }
    if ($Version) {
        # Record the rollback point before the switch, not after success: if starting the new version
        # fails, -Rollback must work.
        $preArchive = ''
        if ($pre) { $preArchive = [string]$pre.FullName; $config['PreviousOpenWebUIVersion'] = $current; $config['RollbackArchive'] = $preArchive }
        else { [void]$config.Remove('PreviousOpenWebUIVersion'); [void]$config.Remove('RollbackArchive') }
        # With it, the update as one that has not been seen to answer yet (also without a backup):
        # removed after the health wait below, read by the next run when that wait never passed.
        $config['UpdatePending'] = @{ Version = [string]$Version; Previous = [string]$current; Archive = $preArchive }
        Save-LaiState -State $config -Path $configPath
    }
    # The images are on disk now: from here a cut-off run only means the next Start again starts
    # the new version (no download), just without the health check below.
    Set-EnvVersion -OpenWebUI $Version -Searxng $SearxngVersion
    # SearXNG (and the render guard, which runs on its image) keeps no data: going back is re-pinning
    # the old tag. Recorded and said now, so the way back is known even if the start below fails.
    $sxUndo = ''
    if ($SearxngVersion) {
        $config['SearxngVersion'] = $SearxngVersion
        if ($currentSx) { $sxUndo = "Update-OpenWebUI.ps1 -SearxngVersion $currentSx"; $config['PreviousSearxngVersion'] = $currentSx }
        Save-LaiState -State $config -Path $configPath
        if ($sxUndo) { Write-UpdateLog INFO "SearXNG $currentSx -> $SearxngVersion. If search or chats misbehave, go back with: $sxUndo" }
    }
    try { Invoke-Docker -Arguments ($base + @('up', '-d', '--remove-orphans')) }
    catch {
        if ($pre -and $Version) { throw "$($_.Exception.Message). Undo the update with: Update-OpenWebUI.ps1 -Rollback" }
        elseif ($sxUndo) { throw "$($_.Exception.Message). Go back to the previous SearXNG with: $sxUndo" }
        else { throw }
    }
} finally { Exit-LaiVolumeLock $lock }

if ($Version) {
    $config['OpenWebUIVersion'] = $Version
    Save-LaiState -State $config -Path $configPath
}
try { Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$port" -TimeoutSec $waitSec }
catch {
    if ($pre -and $Version) { throw "Open WebUI $Version did not come up ($($_.Exception.Message)). Check 'docker logs --tail 80 open-webui', or undo with: Update-OpenWebUI.ps1 -Rollback" }
    throw
}
# It answers: this update came up (and so did an earlier one that a SearXNG-only run found marked).
Clear-UpdatePending
$running = (Invoke-LaiApi -Uri "http://127.0.0.1:$port/api/version").version
Write-UpdateLog OK "Open WebUI $running is up on http://localhost:$port (was $current)"
if ($pre -and $Version) { Write-UpdateLog INFO "If this version misbehaves: Update-OpenWebUI.ps1 -Rollback (back to $current with the data from $($pre.Name))" }

& (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick @catalogArgs
$testExit = $LASTEXITCODE
if ($testExit -eq 0 -and $Version) {
    # Each Open WebUI image is several GB and Docker's disk image never shrinks by itself: keep the
    # running version and the one -Rollback goes back to, remove the older ones. An image still in
    # use by any container is refused by 'docker rmi' and simply stays.
    $img = (Get-DockerResult -Arguments @('inspect', '-f', '{{.Config.Image}}', 'open-webui')).Text.Trim()
    $repo = $img -replace ':[^:/]+$', ''
    if ($repo -and $repo -ne $img) {
        $keep = @("${repo}:$Version", "${repo}:$current")
        $tags = @((Get-DockerResult -Arguments @('images', '--format', '{{.Repository}}:{{.Tag}}', $repo)).Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notlike '*:<none>' })
        foreach ($t in @($tags | Where-Object { $keep -notcontains $_ })) {
            if ((Get-DockerResult -Arguments @('rmi', $t)).ExitCode -eq 0) { Write-UpdateLog INFO "Removed the old image $t" }
        }
    }
}
exit $testExit
