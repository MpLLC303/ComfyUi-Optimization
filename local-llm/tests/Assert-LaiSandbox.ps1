<#
.SYNOPSIS
    Stops a test script unless it runs on a throwaway test machine.

.DESCRIPTION
    Called at the top of every test script that changes Docker, Ollama or Open WebUI, as
        if (-not (& (Join-Path $PSScriptRoot 'Assert-LaiSandbox.ps1'))) { exit 99 }
    It returns $true on a sandbox; otherwise it explains and returns $false, and the caller exits
    (an 'exit' in here would only end this file, not the test). Those
    scripts create, rename and delete containers and volumes named open-webui, searxng and
    deep-research, change the Open WebUI admin password and unload models: on a PC with a real
    install that is the owner's chat data. A machine counts as a sandbox only when it says so:
    the environment variable LAI_SANDBOX=1 (set by the CI workflows) or a file named .lai-sandbox in
    the home folder (created by hand when the sandbox is set up). On Windows a real install
    (C:\AI\install-state.json or %SystemDrive%\AI\install-state.json) refuses even then, unless the
    script runs in GitHub Actions.
#>
$laiSandboxMarker = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.lai-sandbox'
$laiSandboxOk = ($env:LAI_SANDBOX -eq '1') -or (Test-Path -LiteralPath $laiSandboxMarker)
$laiRealInstall = $false
if ($env:OS -eq 'Windows_NT' -and $env:GITHUB_ACTIONS -ne 'true') {
    foreach ($root in @('C:\AI', (Join-Path $env:SystemDrive 'AI'))) {
        if (Test-Path -LiteralPath (Join-Path $root 'install-state.json')) { $laiRealInstall = $true }
    }
}
if ($laiRealInstall -or -not $laiSandboxOk) {
    $why = 'this machine is not marked as a test sandbox'
    if ($laiRealInstall) { $why = 'this PC has a real Local AI install' }
    Write-Host ''
    Write-Host "REFUSED: $(Split-Path -Leaf $MyInvocation.PSCommandPath) is a test that deletes Docker containers, volumes and chat data, and $why." -ForegroundColor Red
    Write-Host 'Run it only on a throwaway test machine: set LAI_SANDBOX=1 there, or create the file' -ForegroundColor Red
    Write-Host "$laiSandboxMarker on that machine. Nothing was changed." -ForegroundColor Red
    return $false
}
return $true
