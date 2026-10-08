#Requires -Version 5.1

<#
.SYNOPSIS
    Makes Open WebUI reachable from your phone/laptop over Tailscale (HTTPS, tailnet only), without
    exposing anything to the LAN or the internet.

.DESCRIPTION
    Runs `tailscale serve --bg <port>`: tailscaled terminates HTTPS on https://<this-pc>.<tailnet>.ts.net
    and proxies to http://127.0.0.1:<port>. Open WebUI keeps listening on loopback only, it is not
    Funnel (not public), and the mapping survives reboots. Only devices in your tailnet can connect,
    and Open WebUI's own login still applies.

    Checks done first, because `tailscale serve` can otherwise hang or exit 0 without doing anything:
      - Tailscale is installed, running and logged in;
      - HTTPS certificates are enabled for the tailnet (admin console > DNS > HTTPS Certificates).
    The result is verified with `tailscale serve status --json`.

.EXAMPLE
    .\Enable-TailscaleAccess.ps1            # expose Open WebUI
.EXAMPLE
    .\Enable-TailscaleAccess.ps1 -Disable   # remove the mapping again
#>
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    # Open WebUI's loopback port; 0 = take it from localai-config.json (3000 if not set).
    [int]$Port = 0,
    [switch]$Disable
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$cmd = Get-Command tailscale -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cmd) { $ts = $cmd.Source } else {
    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Tailscale is not installed. Get it from https://tailscale.com/download/windows, sign in, then re-run.' }
    $ts = $exe
}

function Invoke-Tailscale {
    # With a time limit: when the Tailscale service is stuck, the CLI waits forever, and so would this
    # script. Arguments here never contain spaces, so joining them is safe.
    param([string[]]$Arguments)
    $limit = 30; if ($env:LOCALAI_TS_TIMEOUT) { $limit = [int]$env:LOCALAI_TS_TIMEOUT }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$ts
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($limit * 1000)) {
        # The whole process tree: a wrapper (a .cmd, a shell script) would otherwise leave its child
        # running and holding the output handles open.
        if ($env:OS -eq 'Windows_NT') {
            # Local 'Continue': under 'Stop', Windows PowerShell turns taskkill's stderr into an error.
            $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null } finally { $ErrorActionPreference = $prevEap }
        }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { Write-Verbose 'already gone' }
        throw "tailscale $($Arguments -join ' ') did not answer within $limit s. Is the Tailscale service running? Restart the Tailscale app and try again."
    }
    # Reading has a limit too: a child that outlived tailscale could keep the pipes open.
    if (-not [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($outTask, $errTask), 10000)) {
        throw "tailscale $($Arguments -join ' ') finished but its output never closed. Restart the Tailscale app and try again."
    }
    # Out: stdout only (the JSON); Text: everything, for messages (warnings go to stderr).
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $outTask.Result; Text = ($outTask.Result + $errTask.Result).Trim() }
}

if ($Port -le 0) {
    $config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
    $Port = 3000
    if ($config.ContainsKey('WebUIPort')) { $Port = [int]$config['WebUIPort'] }
}

$statusRun = Invoke-Tailscale @('status', '--json')
if ($statusRun.ExitCode -ne 0) { throw "tailscale status failed: $($statusRun.Text)" }
$status = $statusRun.Out | ConvertFrom-Json
if ($status.BackendState -ne 'Running') {
    throw "Tailscale is '$($status.BackendState)'. Open the Tailscale app, sign in, then re-run."
}
$dns = ([string]$status.Self.DNSName).TrimEnd('.')

function Set-WebUIExtraOrigin([string]$Value) {
    # Open WebUI accepts API calls (and live chat streaming) only from the origins it is told about
    # (CORS_ALLOW_ORIGIN in the compose file): the phone's https://<pc>.<tailnet>.ts.net is added
    # here and removed with -Disable. Open WebUI is then recreated to pick it up (about 20 s).
    # .env is rewritten every time; the container is only recreated when that is safe:
    #   - under the volume lock, so never in the middle of a backup, restore or update (they stop
    #     Open WebUI on purpose while they work on its data);
    #   - not while a failed restore keeps it stopped (the hold);
    #   - not when there is no open-webui container. The uninstaller calls this script: 'compose up'
    #     would bring the removed containers back, with restart: always, and after -RemoveData on an
    #     empty volume with no account, where the first visitor becomes the administrator.
    $envPath = Join-Path (Join-Path $AIRoot 'Stack') '.env'
    if (-not (Test-Path -LiteralPath $envPath)) { Write-LaiLog WARN "No $envPath; re-run the installer, then this script."; return }
    if (Test-LaiVolumeLockBusy) { Write-LaiLog INFO 'Waiting for a backup/restore/update to finish first' }
    $lock = Enter-LaiVolumeLock
    try {
        $lines = @(Get-Content -LiteralPath $envPath -Encoding UTF8 | Where-Object { $_ -notlike 'WEBUI_EXTRA_ORIGINS=*' })
        if ($Value) { $lines += "WEBUI_EXTRA_ORIGINS=$Value" }
        [System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        $hold = Get-LaiWebUIHold -AIRoot $AIRoot
        if ($hold) {
            Write-LaiLog WARN "Open WebUI is kept stopped after a failed restore ($($hold['Reason'])), so it was not restarted; the new address list is saved and applies when it starts again. Recover first: $($hold['Recover'])"
            return
        }
        # By exit code: 0 only when the container exists (running or stopped). No container, Docker
        # not running and Docker not answering all end here, with nothing started.
        try { $there = Invoke-LaiTimedNative -File 'docker' -Arguments @('container', 'inspect', 'open-webui') -TimeoutSec (Get-LaiDockerTimeout) }
        catch { $there = [pscustomobject]@{ ExitCode = -1 } }
        if ($there.ExitCode -ne 0) {
            Write-LaiLog INFO 'Open WebUI was not restarted: there is no open-webui container, or Docker is not running. The new address list is saved and applies the next time Open WebUI is started.'
            return
        }
        $stackDir = Join-Path $AIRoot 'Stack'
        try { $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('compose', '--project-directory', $stackDir, '-f', (Join-Path $stackDir 'docker-compose.yml'), 'up', '-d', 'open-webui') -TimeoutSec 300 }
        catch { $r = [pscustomobject]@{ ExitCode = -1; Text = $_.Exception.Message } }
        if ($r.ExitCode -ne 0) { Write-LaiLog WARN "Open WebUI could not be restarted with the new address list ($($r.Text)); Start menu > Local AI > Start again does it." }
    } finally { Exit-LaiVolumeLock $lock }
}

if ($Disable) {
    $r = Invoke-Tailscale @('serve', '--https=443', 'off')
    if ($r.ExitCode -ne 0 -and $r.Text -notmatch 'does not exist') { throw "Could not remove the mapping: $($r.Text)" }
    Set-WebUIExtraOrigin ''
    Write-LaiLog OK "Tailscale access to Open WebUI removed (https://$dns no longer served)."
    exit 0
}

# HTTPS certificates must be enabled, or `tailscale serve` blocks waiting for an admin.
$hasHttps = $false
if ($status.Self.PSObject.Properties.Name -contains 'CapMap' -and $status.Self.CapMap) {
    $hasHttps = @($status.Self.CapMap.PSObject.Properties.Name) -contains 'https'
}
if (-not $hasHttps -and $status.PSObject.Properties.Name -contains 'CertDomains' -and @($status.CertDomains).Count -gt 0) { $hasHttps = $true }
if (-not $hasHttps) {
    throw ('HTTPS certificates are not enabled for your tailnet. In the Tailscale admin console go to DNS, enable MagicDNS ' +
        'and "HTTPS Certificates" (https://login.tailscale.com/admin/dns), then re-run this script.')
}

try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadString("http://127.0.0.1:$Port/health") | Out-Null
} catch { Write-LaiLog WARN "Open WebUI is not answering on 127.0.0.1:$Port right now; the mapping is created anyway." }

$r = Invoke-Tailscale @('serve', '--bg', [string]$Port)
if ($r.ExitCode -ne 0) { throw "tailscale serve failed: $($r.Text)" }

# Trust the stored config, not the exit code (serve can exit 0 without applying anything).
$cfg = (Invoke-Tailscale @('serve', 'status', '--json')).Out | ConvertFrom-Json
$target = "http://127.0.0.1:$Port"
$ok = $false
if ($cfg -and $cfg.PSObject.Properties.Name -contains 'Web' -and $cfg.Web) {
    foreach ($site in $cfg.Web.PSObject.Properties) {
        foreach ($h in $site.Value.Handlers.PSObject.Properties) { if ($h.Value.Proxy -eq $target) { $ok = $true } }
    }
}
if (-not $ok) { throw "tailscale serve did not record a mapping to $target. Output: $($r.Text)" }
Set-WebUIExtraOrigin ";https://$dns"

Write-LaiLog OK "Open WebUI is available to your tailnet at https://$dns/ (HTTPS, not public, survives reboots)."
Write-LaiLog INFO 'Install Tailscale on the phone, sign in to the same tailnet, open that URL and add it to the home screen.'
Write-LaiLog INFO 'Remove it again with: Enable-TailscaleAccess.ps1 -Disable'
