# Bootstrap: downloads the newest toolkit as a ZIP and starts Install-LocalAI.ps1 from it. Use it for
# the first install and for every update (Start menu > Local AI > Update toolkit runs this file).
# Paste into a normal (non-admin) PowerShell window:
#
#   $env:LOCALAI_REF = 'main'
#   [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
#   irm https://raw.githubusercontent.com/MpLLC303/ComfyUi-Optimization/refs/heads/main/local-llm/Get-LocalAI.ps1 | iex
#
# LOCALAI_REF selects the branch, tag or commit to install from. LOCALAI_ARGS passes installer options,
# e.g. $env:LOCALAI_ARGS = '-OfficialModels none'. Everything runs inside a script block so the settings
# below do not leak into your PowerShell session.
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
    # The ref is resolved to one commit first: what is downloaded is exactly what is shown here, and a
    # re-run after a failure (or the resume after a reboot) installs the same code even if the branch
    # moved meanwhile. Without GitHub's API (rate limit, proxy) the ref itself is used.
    $commit = ''
    try {
        $c = Invoke-RestMethod -Uri "https://api.github.com/repos/MpLLC303/ComfyUi-Optimization/commits/$ref" -UseBasicParsing -Headers @{ Accept = 'application/vnd.github+json' }
        if ([string]$c.sha -match '^[0-9a-f]{40}$') { $commit = [string]$c.sha }
    } catch { Write-Host "Could not look up '$ref' on GitHub ($($_.Exception.Message)); downloading it as is." -ForegroundColor Yellow }
    $get = $ref; if ($commit) { $get = $commit }
    # zip/<ref> accepts a branch, a tag or a commit, so a reviewed version can be pinned.
    $url = "https://codeload.github.com/MpLLC303/ComfyUi-Optimization/zip/$get"

    Write-Host "Downloading installer ($ref$(if ($commit) { ', commit ' + $commit.Substring(0, 7) }))..." -ForegroundColor Cyan
    try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing }
    catch {
        Write-Host "The download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Nothing was changed: your Local AI keeps working as it is. Check the internet connection and run the command again; to repair the installed copy instead, double-click $root\Scripts\Install-LocalAI.cmd." -ForegroundColor Yellow
        return
    }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    Remove-Item -LiteralPath $zip -Force

    $top = Get-ChildItem -LiteralPath $dest -Directory | Select-Object -First 1
    $installer = Join-Path $top.FullName 'local-llm\Install-LocalAI.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found in the downloaded archive ($installer)." }
    Get-ChildItem -LiteralPath $top.FullName -Recurse -File | Unblock-File
    # Recorded by the installer (localai-config.json, diagnostics), so it is known what code runs.
    if ($commit) { [System.IO.File]::WriteAllText((Join-Path (Split-Path -Parent $installer) 'COMMIT'), $commit) }
    $version = ''; $vf = Join-Path (Split-Path -Parent $installer) 'VERSION'
    if (Test-Path -LiteralPath $vf) { $version = ([System.IO.File]::ReadAllText($vf)).Trim() }
    Write-Host "Installing Local AI toolkit $version$(if ($commit) { ' (commit ' + $commit.Substring(0, 7) + ')' }). Windows asks for administrator rights next." -ForegroundColor Cyan

    # Options for the installer, e.g. -OfficialModels none: plain words only (no quotes or scripts).
    $extra = @()
    if ($env:LOCALAI_ARGS) { $extra = @($env:LOCALAI_ARGS -split '\s+' | Where-Object { $_ }) }
    $bad = @($extra | Where-Object { $_ -notmatch '^[A-Za-z0-9_:,.\\-]+$' })
    if ($bad.Count) { Write-Host "LOCALAI_ARGS may hold only plain options such as -OfficialModels none; not used: $($bad -join ' ')" -ForegroundColor Red; return }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -AIRoot $root @extra
    $code = $LASTEXITCODE
    Write-Host ''
    if ($code -eq 10) { Write-Host 'The installer continues in the Administrator window that opened.' -ForegroundColor Cyan }
    elseif ($code -eq 1223) { Write-Host 'Administrator rights were declined; run the command again and click Yes.' -ForegroundColor Red }
    elseif ($code -eq 3010) { Write-Host 'A restart is needed; the installer resumes after you sign in again (click Yes when Windows asks).' -ForegroundColor Cyan }
    elseif ($code -ne 0) { Write-Host "The installer stopped with an error (code $code); see the messages above." -ForegroundColor Red }
}
