<#
.SYNOPSIS
    Checks that only make sense on real Windows PowerShell 5.1 (run by CI on a Windows runner;
    on Linux/PowerShell 7 the Windows-only parts are skipped).

.DESCRIPTION
    - The module imports and its state helpers round-trip through 5.1's ConvertFrom-Json.
    - Invoke-LaiApi sends UTF-8 bodies (5.1 would otherwise send ISO-8859-1).
    - The volume lock: the mutex gets the Authenticated Users ACL, and a second process sees it busy
      while held and free after release.
    - Start-menu shortcuts: real .lnk files are written and read back; the -Command payload parses.
    - Watch-LocalAI: pause / unpause / a full run with nothing installed must not throw.
    - Uninstall-LocalAI -WhatIf and Stop-LocalAI on an empty AI root must not throw.
    Exit code = number of failed assertions.
#>
param([string]$Work = (Join-Path ([System.IO.Path]::GetTempPath()) 'lai-wintest'))
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $PSScriptRoot
$onWindows = ($env:OS -eq 'Windows_NT')
$failures = 0
function Assert-That([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  ASSERT OK   $Message" -ForegroundColor Green }
    else { Write-Host "  ASSERT FAIL $Message" -ForegroundColor Red; $script:failures++ }
}
function Skip([string]$Message) { Write-Host "  SKIP        $Message" -ForegroundColor DarkGray }

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) on $(if ($onWindows) { 'Windows' } else { 'non-Windows' })"
if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$aiRoot = Join-Path $Work 'AI'
New-Item -ItemType Directory -Force -Path (Join-Path $aiRoot 'Logs') | Out-Null
$childExe = 'pwsh'
if ($PSVersionTable.PSEdition -eq 'Desktop') { $childExe = 'powershell.exe' }

Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
Assert-That ($null -ne (Get-Command Get-LaiShortcutSpecs -ErrorAction SilentlyContinue)) 'module imports and exports its functions'

# ---- state round trip -------------------------------------------------------------------------
Write-Host "`n=== state files ===" -ForegroundColor Cyan
$statePath = Join-Path $Work 'state.json'
Save-LaiState -State @{ failed = @('Docker'); notified = @(); pausedUntil = '2030-01-01T00:00:00'; nested = @{ a = 1 } } -Path $statePath
$st = Read-LaiState -Path $statePath
Assert-That ($st -is [hashtable]) 'Read-LaiState returns a hashtable'
Assert-That (@($st['failed']).Count -eq 1 -and @($st['failed'])[0] -eq 'Docker') 'single-element array survives the round trip'
Assert-That ($st['nested'] -is [hashtable] -and $st['nested']['a'] -eq 1) 'nested objects become hashtables'

# ---- UTF-8 request bodies ----------------------------------------------------------------------
Write-Host "`n=== Invoke-LaiApi UTF-8 body ===" -ForegroundColor Cyan
if ($onWindows) {
    $port = Get-Random -Minimum 20000 -Maximum 40000
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    $async = $listener.BeginGetContext($null, $null)
    $job = Start-Job -ScriptBlock {
        param($mod, $port)
        Import-Module $mod -Force
        Invoke-LaiApi -Method POST -Uri "http://127.0.0.1:$port/echo" -Body @{ text = "caf$([char]0xE9) $([char]0x2713)" } -TimeoutSec 20
    } -ArgumentList (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'), $port
    if ($async.AsyncWaitHandle.WaitOne(30000)) {
        $ctx = $listener.EndGetContext($async)
        $ms = New-Object System.IO.MemoryStream
        $ctx.Request.InputStream.CopyTo($ms)
        $bytes = $ms.ToArray()
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $ok = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($ok, 0, $ok.Length)
        $ctx.Response.Close()
        Assert-That ($text -like "*caf$([char]0xE9)*$([char]0x2713)*") "request body is UTF-8 ($($bytes.Length) bytes)"
    } else { Assert-That $false 'request arrived at the test listener' }
    $null = Wait-Job $job -Timeout 30; Remove-Job $job -Force
    $listener.Stop()
} else { Skip 'HttpListener test runs on Windows only' }

# ---- volume lock ---------------------------------------------------------------------------------
Write-Host "`n=== volume lock ===" -ForegroundColor Cyan
$m = New-LaiVolumeMutex
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $rules = @($m.GetAccessControl().GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
    $authSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid, $null)
    Assert-That (@($rules | Where-Object { $_.IdentityReference -eq $authSid }).Count -ge 1) 'mutex ACL grants Authenticated Users'
} else { Skip 'mutex ACL exists only on Windows PowerShell' }
$m.Dispose()
$probe = Join-Path $Work 'probe.ps1'
Set-Content -LiteralPath $probe -Value ("Import-Module '{0}' -Force; if (Test-LaiVolumeLockBusy) {{ 'BUSY' }} else {{ 'FREE' }}" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'))
$lock = Enter-LaiVolumeLock -TimeoutSec 5
$busy = (& $childExe -NoProfile -ExecutionPolicy Bypass -File $probe | Select-Object -Last 1)
Assert-That ($busy -eq 'BUSY') "another process sees the lock as busy while held (got '$busy')"
Exit-LaiVolumeLock $lock
$free = (& $childExe -NoProfile -ExecutionPolicy Bypass -File $probe | Select-Object -Last 1)
Assert-That ($free -eq 'FREE') "and as free after release (got '$free')"

# ---- shortcuts -----------------------------------------------------------------------------------
Write-Host "`n=== Start-menu shortcuts ===" -ForegroundColor Cyan
$specs = @(Get-LaiShortcutSpecs -AIRoot "C:\It's AI" -WebUIPort 3001)
Assert-That ($specs.Count -eq 5) "five shortcut specs (got $($specs.Count))"
foreach ($sc in ($specs | Where-Object { $_.Kind -eq 'lnk' })) {
    $cmd = $sc.Arguments.Substring($sc.Arguments.IndexOf('"') + 1).TrimEnd('"')
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$errs)
    Assert-That (@($errs).Count -eq 0) "payload of '$($sc.Name)' parses"
}
if ($onWindows) {
    $shell = New-Object -ComObject WScript.Shell
    $lnkPath = Join-Path $Work 'test.lnk'
    $spec = $specs | Where-Object { $_.Kind -eq 'lnk' } | Select-Object -First 1
    $l = $shell.CreateShortcut($lnkPath)
    $l.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $l.Arguments = $spec.Arguments
    $l.Save()
    $back = $shell.CreateShortcut($lnkPath)
    Assert-That ((Test-Path -LiteralPath $lnkPath) -and $back.Arguments -eq $spec.Arguments) '.lnk written and its arguments read back unchanged'
    Assert-That ($spec.Arguments.Length -lt 1024) "arguments fit the 1024-char .lnk limit ($($spec.Arguments.Length))"
} else { Skip '.lnk creation needs WScript.Shell' }

# ---- scripts that must run on a machine with nothing installed -------------------------------------
Write-Host "`n=== Watch / Uninstall / Stop smoke runs ===" -ForegroundColor Cyan
ConvertTo-Json @{ WebUIPort = 39999; SearxngPort = 39998; OllamaUrl = 'http://127.0.0.1:39997' } | Set-Content -LiteralPath (Join-Path $aiRoot 'localai-config.json')
function Invoke-Child([string]$Script, [string[]]$Arguments) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $childExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src $Script) @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}
$r = Invoke-Child 'Watch-LocalAI.ps1' @('-AIRoot', $aiRoot, '-PauseMinutes', '30')
Assert-That ($r.Code -eq 0 -and (Read-LaiState -Path (Join-Path $aiRoot 'watch-state.json')).ContainsKey('pausedUntil')) 'watch -PauseMinutes writes the pause'
$r = Invoke-Child 'Watch-LocalAI.ps1' @('-AIRoot', $aiRoot, '-NoHeal')
Assert-That ($r.Code -eq 0) "paused watch exits 0 without checking (got $($r.Code))"
$r = Invoke-Child 'Watch-LocalAI.ps1' @('-AIRoot', $aiRoot, '-Unpause')
Assert-That ($r.Code -eq 0 -and -not (Read-LaiState -Path (Join-Path $aiRoot 'watch-state.json')).ContainsKey('pausedUntil')) 'watch -Unpause clears it'
$r = Invoke-Child 'Watch-LocalAI.ps1' @('-AIRoot', $aiRoot, '-NoHeal', '-MinFreeGB', '1')
$r2 = Invoke-Child 'Watch-LocalAI.ps1' @('-AIRoot', $aiRoot, '-NoHeal', '-MinFreeGB', '1')
Assert-That ($r.Code -gt 0 -and $r.Text -notmatch 'Exception') "watch with nothing installed reports failures without throwing (exit $($r.Code))"
$log = Get-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Logs') 'watch.log')
Assert-That (@($log | Where-Object { $_ -like '*NOTIFY Local AI: problem detected*' }).Count -eq 1) 'second failing run sends exactly one notification (toast code ran)'
Assert-That ($r2.Text -notmatch 'Exception') 'notification path does not throw'

$r = Invoke-Child 'Uninstall-LocalAI.ps1' @('-AIRoot', $aiRoot, '-WhatIf')
Assert-That ($r.Code -eq 0) "Uninstall -WhatIf on an empty root exits 0 (got $($r.Code))"
$r = Invoke-Child 'Stop-LocalAI.ps1' @('-AIRoot', $aiRoot, '-PauseHours', '1')
Assert-That ($r.Code -eq 0) "Stop-LocalAI with nothing running exits 0 (got $($r.Code))"
if ($r.Code -ne 0 -or $failures -gt 0) { Write-Host $r.Text }

if ($failures -eq 0) { Write-Host "`nWINDOWS UNIT TESTS PASSED" -ForegroundColor Green } else { Write-Host "`nWINDOWS UNIT TESTS FAILED ($failures)" -ForegroundColor Red }
exit $failures
