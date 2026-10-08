#Requires -Version 5.1

<#
.SYNOPSIS
    Brings the local AI stack back after Stop-LocalAI.ps1 (or after quitting Docker/Ollama by hand).

.DESCRIPTION
    Starts Ollama and Docker Desktop if they are not running, starts the containers, waits until
    Open WebUI answers, checks that a chat can reach Ollama from inside Open WebUI, and resumes the
    health watch. Models load on the first chat as usual.

    Every docker command has a time limit. A Docker Desktop that does not answer (it can stop
    answering after sleep) ends the run with what to do about it, not with a window that waits.

.EXAMPLE
    .\Start-LocalAI.ps1
#>
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    # How long to wait for Docker and Open WebUI to come up.
    [int]$TimeoutSec = 300
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$onWindows = ($env:OS -eq 'Windows_NT')
$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$ollamaUrl = 'http://127.0.0.1:11434'
if ($config.ContainsKey('OllamaUrl') -and $config['OllamaUrl']) { $ollamaUrl = [string]$config['OllamaUrl'] }
$webPort = 3000; if ($config.ContainsKey('WebUIPort')) { $webPort = [int]$config['WebUIPort'] }
$stackDir = Join-Path $AIRoot 'Stack'
$compose = Join-Path $stackDir 'docker-compose.yml'

# Every docker call has a time limit. After sleep Docker Desktop can stop answering while its
# commands still start: without a limit this window would wait on the first of them without a word.
$dockerLimit = Get-LaiDockerTimeout
$hungMsg = 'Docker Desktop is not responding. Restart it (whale icon > Restart), wait for Engine running, then run this again.'
$restartStep = 'Restart Docker Desktop (whale icon in the taskbar > Restart), wait until it says Engine running, then use Start menu > Local AI - Start again.'

function Invoke-Docker {
    # For the quick calls (inspect, the probe run with exec): no answer within the limit ends the run
    # with the one message for that. Not for 'desktop start' and 'compose up' below, which have work
    # to do: one of those taking long is not a Docker Desktop that stopped answering.
    param([string[]]$Arguments)
    $r = Invoke-LaiTimedNative -File 'docker' -Arguments $Arguments -TimeoutSec $dockerLimit
    if ($r.TimedOut) { throw $hungMsg }
    return $r
}
function Get-ContainerState {
    # 'running', 'exited', 'created', ...; 'missing' when there is no container of that name.
    param([string]$Name)
    $r = Invoke-Docker @('inspect', '-f', '{{.State.Status}}', $Name)
    if ($r.ExitCode -ne 0) { return 'missing' }
    return ([string]$r.Out).Trim()
}

# The health watch comes back on even when a step below fails: the user asked for the stack, so an
# outage should be reported, not silenced by the pause from Stop-LocalAI.
try {
    # 1. Ollama.
    $ollamaOk = $true
    try { Get-LaiOllamaVersion -BaseUrl $ollamaUrl | Out-Null } catch { $ollamaOk = $false }
    if (-not $ollamaOk) {
        $app = Get-LaiOllamaAppPath
        if ($onWindows -and $app -and (Test-Path -LiteralPath $app)) {
            Start-LaiOllamaApp -Path $app
            Wait-LaiHttp -Uri "$ollamaUrl/api/version" -TimeoutSec 90 | Out-Null
            Write-LaiLog OK 'Ollama started'
        } else {
            throw "Ollama is not running (no answer at $ollamaUrl). Start Ollama from the Start menu, then use Start menu > Local AI - Start again."
        }
    } else { Write-LaiLog OK 'Ollama is running' }

    # 2. Docker engine.
    $engine = Test-LaiDockerEngine -TimeoutSec $dockerLimit
    if ($engine -eq 'missing') { throw 'Docker Desktop is not installed (the docker command was not found). Run Start menu > Local AI - Update toolkit to install it again.' }
    # No answer at all is not 'not running': Docker Desktop is there and stuck, and starting it once
    # more changes nothing.
    if ($engine -eq 'hung') { throw $hungMsg }
    if ($engine -ne 'ok') {
        if (-not $onWindows) { throw 'Docker engine is not running.' }
        Write-LaiLog INFO 'Starting Docker Desktop (takes a minute or two)'
        # 'docker desktop start' can wait until Docker Desktop is up, so it gets the whole wait. Using
        # all of it is not 'stuck' either (a first start after an update, a dialog that waits for an
        # answer): the command is ended, and the engine is asked below like after any other start.
        $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('desktop', 'start') -TimeoutSec $TimeoutSec
        # While it starts, Docker may give no answer for a while: that is not yet 'stuck'. Only the
        # deadline ends the wait, and what was seen last picks the message.
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        if ($r.TimedOut) {
            # The wait is used up already: one look at the engine, and that look picks the message.
            $deadline = Get-Date
        } elseif ($r.ExitCode -ne 0) {
            $exe = Find-LaiDockerDesktopExe
            if (-not $exe) { throw 'Docker Desktop.exe was not found (not in its registered install folder, next to the docker command or in Program Files). Start Docker Desktop from the Start menu, then use Start menu > Local AI - Start again.' }
            Start-Process -FilePath $exe
        }
        while ($true) {
            $engine = Test-LaiDockerEngine -TimeoutSec $dockerLimit
            if ($engine -eq 'ok') { break }
            if ((Get-Date) -ge $deadline) {
                if ($engine -eq 'hung') { throw $hungMsg }
                throw "Docker engine did not start within $TimeoutSec s. Open Docker Desktop and check for errors."
            }
            Start-Sleep -Seconds 5
        }
    }
    Write-LaiLog OK 'Docker engine is running'

    # 3. Containers.
    if (-not (Test-Path -LiteralPath $compose)) { throw "Missing $compose. Re-run Install-LocalAI.ps1." }
    $hold = Get-LaiWebUIHold -AIRoot $AIRoot
    if ($hold) { throw "Open WebUI is kept stopped after a failed restore ($($hold['Reason'])). Recover first: $($hold['Recover'])" }
    # Not in the middle of a backup/restore/update (it stopped Open WebUI on purpose).
    if (Test-LaiVolumeLockBusy) { Write-LaiLog INFO 'Waiting for a backup/restore/update to finish first' }
    $lock = Enter-LaiVolumeLock -TimeoutSec 1800
    try {
        # Again under the lock: a restore that held it while this waited may have failed meanwhile.
        $hold = Get-LaiWebUIHold -AIRoot $AIRoot
        if ($hold) { throw "Open WebUI is kept stopped after a failed restore ($($hold['Reason'])). Recover first: $($hold['Recover'])" }
        # Twenty times the limit of a quick call (600 s), or -TimeoutSec when that is more: it may
        # have images to download. Running out of it is said as that, not as 'not responding'.
        $upLimit = [Math]::Max(20 * $dockerLimit, $TimeoutSec)
        $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('compose', '--project-directory', $stackDir, '-f', $compose, 'up', '-d') -TimeoutSec $upLimit
        if ($r.TimedOut) { throw "docker compose up did not finish within $upLimit s. $restartStep" }
        if ($r.ExitCode -ne 0) { throw "docker compose up failed: $($r.Text)" }
    } finally { Exit-LaiVolumeLock $lock }
    try { Wait-LaiWebUI -BaseUrl "http://127.0.0.1:$webPort" -TimeoutSec $TimeoutSec }
    catch { throw "Open WebUI did not answer within $TimeoutSec s. $restartStep" }

    # 4. The path chats take. Open WebUI answering says nothing about it: with the render guard down,
    # or Docker's network to this PC broken (it can be after sleep or a reboot), every chat fails
    # while the page loads fine. The health watch's own probe, run here: from inside the Open WebUI
    # container to the Ollama address it was given.
    $chatUrl = 'http://render-guard:11434'
    if ($config.ContainsKey('WebUIOllamaUrl') -and $config['WebUIOllamaUrl']) { $chatUrl = [string]$config['WebUIOllamaUrl'] }
    # The render guard is on that path unless Open WebUI was pointed past it (read as the health check reads it).
    if (-not ($config.ContainsKey('WebUIOllamaUrl') -and $config['WebUIOllamaUrl'] -and $config['WebUIOllamaUrl'] -notlike '*render-guard*')) {
        $guardState = Get-ContainerState 'render-guard'
        # No container of that name is not judged here: the health check names a missing one.
        if ($guardState -ne 'running' -and $guardState -ne 'missing') {
            throw "Open WebUI answers, but the render guard, which passes its chats on to Ollama, is not running (Docker says: $guardState), so chats would fail. $restartStep If the render guard still does not run after that, look at: docker logs --tail 50 render-guard"
        }
    }
    if ((Get-ContainerState 'open-webui') -eq 'running') {
        $probe = "import sys,urllib.request as u;u.urlopen(sys.argv[1].rstrip('/')+'/api/version',timeout=10)"
        $r = Invoke-Docker @('exec', 'open-webui', 'python3', '-c', $probe, $chatUrl)
        if ($r.ExitCode -ne 0) { throw "Open WebUI answers, but it cannot reach Ollama at $chatUrl, so chats would fail. $restartStep" }
        Write-LaiLog OK "Chats reach Ollama (Open WebUI gets an answer from $chatUrl)"
    } else {
        # Said, not passed over in silence: nothing below claims that chats work.
        Write-LaiLog INFO 'Open WebUI does not run as the open-webui container here: chat path not checked'
    }
    Write-LaiLog OK "Open WebUI is up on http://localhost:$webPort"

} catch {
    # Said last and clearly, so a failed start never ends on the 'watch resumed' line below.
    Write-LaiLog FAIL "Local AI did not start: $($_.Exception.Message)"
    throw
} finally {
    # 5. Watch back on.
    & (Join-Path $PSScriptRoot 'Watch-LocalAI.ps1') -AIRoot $AIRoot -Unpause | Out-Null
    Write-LaiLog OK 'Health watch resumed'
}
