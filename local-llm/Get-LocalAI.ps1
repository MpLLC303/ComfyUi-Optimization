# Bootstrap: downloads the newest toolkit as a ZIP and starts Install-LocalAI.ps1 from it. Use it for
# the first install and for every update (Start menu > Local AI > Update toolkit runs this file).
# Paste into a normal (non-admin) PowerShell window:
#
#   $env:LOCALAI_REF = 'main'
#   [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
#   irm https://raw.githubusercontent.com/MpLLC303/ComfyUi-Optimization/refs/heads/main/local-llm/Get-LocalAI.ps1 | iex
#
# LOCALAI_REF selects the branch, tag or commit to install from. Everything runs inside a script block so the
# settings below do not leak into your PowerShell session.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $ref = $env:LOCALAI_REF
    if (-not $ref) { $ref = 'main' }
    # LOCALAI_ROOT: the install's AI folder (set by the Start-menu 'Update toolkit' shortcut).
    $root = $env:LOCALAI_ROOT
    if (-not $root) { $root = 'C:\AI' }
    # Unpacked in the user's temp folder; the installer copies itself into AI\Scripts (and, before a
    # reboot, into Program Files\LocalAI for the resume).
    $dest = Join-Path $env:TEMP 'LocalAI-Installer'
    $zip = Join-Path $env:TEMP 'localai-installer.zip'
    # zip/<ref> accepts a branch, a tag or a commit, so a reviewed version can be pinned.
    $url = "https://codeload.github.com/MpLLC303/ComfyUi-Optimization/zip/$ref"

    Write-Host "Downloading installer ($ref)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    Remove-Item -LiteralPath $zip -Force

    $top = Get-ChildItem -LiteralPath $dest -Directory | Select-Object -First 1
    $installer = Join-Path $top.FullName 'local-llm\Install-LocalAI.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found in the downloaded archive ($installer)." }
    Get-ChildItem -LiteralPath $top.FullName -Recurse -File | Unblock-File

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -AIRoot $root
    $code = $LASTEXITCODE
    Write-Host ''
    if ($code -eq 10) { Write-Host 'The installer continues in the Administrator window that opened.' -ForegroundColor Cyan }
    elseif ($code -eq 1223) { Write-Host 'Administrator rights were declined; run the command again and click Yes.' -ForegroundColor Red }
    elseif ($code -eq 3010) { Write-Host 'A restart is needed; the installer resumes after you sign in again (click Yes when Windows asks).' -ForegroundColor Cyan }
    elseif ($code -ne 0) { Write-Host "The installer stopped with an error (code $code); see the messages above." -ForegroundColor Red }
}
