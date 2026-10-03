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
    [string]$AIRoot = 'C:\AI',
    [int]$Port = 0,
    [switch]$Disable
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$cmd = Get-Command tailscale -ErrorAction SilentlyContinue
if ($cmd) { $ts = $cmd } else {
    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Tailscale is not installed. Get it from https://tailscale.com/download/windows, sign in, then re-run.' }
    $ts = $exe
}

function Invoke-Tailscale {
    param([string[]]$Arguments)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& $ts @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ ExitCode = $code; Text = ($out -join "`n") }
}

if ($Port -le 0) {
    $config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
    $Port = 3000
    if ($config.ContainsKey('WebUIPort')) { $Port = [int]$config['WebUIPort'] }
}

$statusRun = Invoke-Tailscale @('status', '--json')
if ($statusRun.ExitCode -ne 0) { throw "tailscale status failed: $($statusRun.Text)" }
$status = $statusRun.Text | ConvertFrom-Json
if ($status.BackendState -ne 'Running') {
    throw "Tailscale is '$($status.BackendState)'. Open the Tailscale app, sign in, then re-run."
}
$dns = ([string]$status.Self.DNSName).TrimEnd('.')

if ($Disable) {
    $r = Invoke-Tailscale @('serve', '--https=443', 'off')
    if ($r.ExitCode -ne 0 -and $r.Text -notmatch 'does not exist') { throw "Could not remove the mapping: $($r.Text)" }
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
$cfg = (Invoke-Tailscale @('serve', 'status', '--json')).Text | ConvertFrom-Json
$target = "http://127.0.0.1:$Port"
$ok = $false
if ($cfg -and $cfg.PSObject.Properties.Name -contains 'Web' -and $cfg.Web) {
    foreach ($site in $cfg.Web.PSObject.Properties) {
        foreach ($h in $site.Value.Handlers.PSObject.Properties) { if ($h.Value.Proxy -eq $target) { $ok = $true } }
    }
}
if (-not $ok) { throw "tailscale serve did not record a mapping to $target. Output: $($r.Text)" }

Write-LaiLog OK "Open WebUI is available to your tailnet at https://$dns/ (HTTPS, not public, survives reboots)."
Write-LaiLog INFO 'Install Tailscale on the phone, sign in to the same tailnet, open that URL and add it to the home screen.'
Write-LaiLog INFO 'Remove it again with: Enable-TailscaleAccess.ps1 -Disable'
