#Requires -Version 5.1

<#
.SYNOPSIS
    Rotates the Open WebUI admin password and updates <AIRoot>\Secrets\openwebui-admin.json.

.DESCRIPTION
    Signs in with the stored credentials, changes the password through Open WebUI's own API (which
    also revokes existing sessions), verifies the new password works, then rewrites the secrets file.
    Without -NewPassword a random 24-character password is generated and printed once.

.EXAMPLE
    .\Set-OpenWebUIPassword.ps1                       # random new password
.EXAMPLE
    .\Set-OpenWebUIPassword.ps1 -Prompt               # type your own (hidden input)
.EXAMPLE
    .\Set-OpenWebUIPassword.ps1 -PromptCurrent        # after restoring an older backup: type the
                                                      # password that backup had; the stored one is replaced
#>
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    # For automation only: a password typed here stays in the PowerShell history and is visible in
    # the process list. Interactively, use -Prompt (and -PromptCurrent) instead.
    [string]$NewPassword = '',
    [switch]$Prompt,
    # The password Open WebUI currently accepts, when it differs from the stored one (e.g. after a
    # restore). -PromptCurrent asks for it without echoing or leaving it in the shell history.
    [string]$CurrentPassword = '',
    [switch]$PromptCurrent,
    # Do not print the new password (it is still stored in <AIRoot>\Secrets).
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
if (-not (Test-Path -LiteralPath $credFile)) { throw "No stored credentials at $credFile. Run Install-LocalAI.ps1 first." }
$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$port = 3000
if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
$baseUrl = "http://127.0.0.1:$port"
# A previous run cut off mid-change: settle which password is live before changing it again.
Resolve-LaiPendingPassword -AIRoot $AIRoot -BaseUrl $baseUrl | Out-Null
$cred = Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json

if ($Prompt) {
    $a = Read-Host 'New password' -AsSecureString
    $b = Read-Host 'Repeat' -AsSecureString
    $pa = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
    $pb = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
    if ($pa -ne $pb) { throw 'The two passwords do not match.' }
    $NewPassword = $pa
}
if (-not $NewPassword) { $NewPassword = New-LaiPassword }
if ($NewPassword.Length -lt 12) { throw 'Use at least 12 characters.' }

$current = [string]$cred.password
if ($PromptCurrent) {
    $c = Read-Host "Current Open WebUI password for $($cred.email)" -AsSecureString
    $CurrentPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($c))
}
if ($CurrentPassword) { $current = $CurrentPassword }
$token = Connect-LaiWebUI -BaseUrl $baseUrl -Email $cred.email -Password $current

# The new password is written down BEFORE Open WebUI is asked to change it: if the request times out
# after the change went through, or saving the file fails, the admin password is never lost.
# (Same Secrets folder, so it inherits the folder's restricted permissions.)
$pending = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.pending.json'
$updated = @{ email = $cred.email; password = $NewPassword; url = "http://localhost:$port"; rotated = (Get-Date).ToString('s') }
ConvertTo-Json -InputObject $updated | Set-Content -LiteralPath $pending -Encoding UTF8
try {
    $ok = Invoke-LaiApi -Method POST -Uri "$baseUrl/api/v1/auths/update/password" -Token $token -Body @{ password = $current; new_password = $NewPassword }
} catch {
    Write-LaiLog FAIL "The password change request failed: $($_.Exception.Message)"
    Write-LaiLog WARN "If the change went through anyway, the new password is in $pending (otherwise the old one in $credFile still works)."
    exit 1
}
if ($ok -ne $true) { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue; throw 'Open WebUI refused the password change; the old password still works.' }

# Keep the file's existing ACL (the installer restricted it); just replace the content.
try { ConvertTo-Json -InputObject $updated | Set-Content -LiteralPath $credFile -Encoding UTF8 -ErrorAction Stop }
catch {
    Write-LaiLog FAIL "Password changed, but $credFile could not be updated ($($_.Exception.Message)). The new password is in $pending; copy it over."
    Write-Host "New password: $NewPassword" -ForegroundColor Green
    exit 1
}
Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
try { Connect-LaiWebUI -BaseUrl $baseUrl -Email $cred.email -Password $NewPassword | Out-Null }
catch { Write-LaiLog WARN "Password changed and stored, but the check sign-in failed ($($_.Exception.Message)); try signing in on http://localhost:$port." }
Write-LaiLog OK "Password changed for $($cred.email); existing sessions were signed out. Stored in $credFile"
if (-not $Quiet) { Write-Host "New password: $NewPassword" -ForegroundColor Green }
