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
    - Scheduled tasks: the no-window launch (conhost --headless), the daily-time math, and native
      calls with a time limit (a CLI that never answers is stopped, not waited on).
    Exit code = number of failed assertions.
#>
param([string]$Work = (Join-Path ([System.IO.Path]::GetTempPath()) 'lai-wintest'))
$ErrorActionPreference = 'Stop'
# Refuses to run anywhere but a throwaway test machine (it would delete a real install's data).
if (-not (& (Join-Path $PSScriptRoot 'Assert-LaiSandbox.ps1'))) { exit 99 }
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
Save-LaiState -State @{ gen = 2 } -Path $statePath
Assert-That ((Read-LaiState -Path $statePath)['gen'] -eq 2 -and (Read-LaiState -Path "$statePath.bak").ContainsKey('nested')) 'a save keeps the previous version as .bak'
Assert-That (-not (Test-Path -LiteralPath "$statePath.tmp")) 'no temp file left behind'
# A write cut short by a power loss or a full disk.
Set-Content -LiteralPath $statePath -Value '{"gen": 3, "fail'
$st = Read-LaiState -Path $statePath
Assert-That ($st.ContainsKey('nested') -and (Test-Path -LiteralPath "$statePath.bad")) 'damaged file: previous copy used, damaged one kept as .bad'
Remove-Item -LiteralPath "$statePath.bak"
Assert-That ((Read-LaiState -Path $statePath).Count -eq 0) 'damaged file and no .bak: empty settings instead of a crash'
Save-LaiState -State @{ gen = 4 } -Path $statePath
Assert-That ((Read-LaiState -Path $statePath)['gen'] -eq 4) 'saving over a damaged file works'
# A Windows user name with an accent ends up in saved paths (C:\Users\J<o-umlaut>rg\...).
$accented = 'C:\Users\J' + [char]0x00F6 + 'rg\AI\OllamaModels'
Save-LaiState -State @{ modelDir = $accented } -Path $statePath
Assert-That ((Read-LaiState -Path $statePath)['modelDir'] -eq $accented) 'non-ASCII path survives the round trip'
Assert-That (((Get-Content -LiteralPath $statePath -Raw) | ConvertFrom-Json).modelDir -eq $accented) 'and a plain Get-Content (no -Encoding) reads it right too'  # lai-ok: encoding

# ---- UTF-8 request bodies ----------------------------------------------------------------------
Write-Host "`n=== Invoke-LaiApi UTF-8 both ways ===" -ForegroundColor Cyan
# Both directions: the request body must be UTF-8, and a reply sent as plain 'application/json'
# (no charset, as Open WebUI does) must be decoded as UTF-8, not ISO-8859-1 (5.1's default).
$port = Get-Random -Minimum 20000 -Maximum 40000
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()
$async = $listener.BeginGetContext($null, $null)
# The client runs in its own process, exactly as the scripts do.
$client = Join-Path $Work 'client.ps1'
$echoOut = Join-Path $Work 'echo.txt'
Set-Content -LiteralPath $client -Value (("Import-Module '{0}' -Force`n" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1')) +
    ('$r = Invoke-LaiApi -Method POST -Uri "http://127.0.0.1:{0}/echo" -Body @{{ text = "caf$([char]0xE9) $([char]0x2713)" }} -TimeoutSec 20' -f $port) + "`n" +
    ("[System.IO.File]::WriteAllText('{0}', [string]`$r.echo, [System.Text.Encoding]::UTF8)" -f $echoOut))
$spArgs = @{ FilePath = $childExe; ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $client); PassThru = $true }
if ($onWindows) { $spArgs['WindowStyle'] = 'Hidden' }
$proc = Start-Process @spArgs
if ($async.AsyncWaitHandle.WaitOne(30000)) {
    $ctx = $listener.EndGetContext($async)
    $ms = New-Object System.IO.MemoryStream
    $ctx.Request.InputStream.CopyTo($ms)
    $bytes = $ms.ToArray()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $sent = (ConvertFrom-Json -InputObject $text).text
    $reply = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @{ echo = $sent } -Compress))
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($reply, 0, $reply.Length)
    $ctx.Response.Close()
    Assert-That ($text -like "*caf$([char]0xE9)*$([char]0x2713)*") "request body is UTF-8 ($($bytes.Length) bytes)"
} else { Assert-That $false 'request arrived at the test listener' }
if (-not $proc.WaitForExit(30000)) { $proc.Kill() }
$listener.Stop()
$got = ''
if (Test-Path -LiteralPath $echoOut) { $got = [System.IO.File]::ReadAllText($echoOut, [System.Text.Encoding]::UTF8) }
Assert-That ($got -eq "caf$([char]0xE9) $([char]0x2713)") "reply without a charset is decoded as UTF-8 (got '$got')"

Write-Host "`n=== pending admin password: only a clear refusal drops it ===" -ForegroundColor Cyan
$pRoot = Join-Path $Work 'pending'
New-Item -ItemType Directory -Force -Path (Join-Path $pRoot 'Secrets') | Out-Null
$pendingFile = Join-Path (Join-Path $pRoot 'Secrets') 'openwebui-admin.pending.json'
Set-Content -LiteralPath $pendingFile -Value '{"email": "admin@localhost", "password": "Pending-Password-1"}' -Encoding UTF8
$port2 = Get-Random -Minimum 20000 -Maximum 40000
$listener2 = New-Object System.Net.HttpListener
$listener2.Prefixes.Add("http://127.0.0.1:$port2/")
$listener2.Start()
$pOut = Join-Path $Work 'pending-out.txt'
$client2 = Join-Path $Work 'client2.ps1'
Set-Content -LiteralPath $client2 -Value (("Import-Module '{0}' -Force`n" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1')) +
    ("`$a = Resolve-LaiPendingPassword -AIRoot '{0}' -BaseUrl 'http://127.0.0.1:{1}'`n" -f $pRoot, $port2) +
    ("`$kept = Test-Path -LiteralPath '{0}'`n" -f $pendingFile) +
    ("`$b = Resolve-LaiPendingPassword -AIRoot '{0}' -BaseUrl 'http://127.0.0.1:{1}'`n" -f $pRoot, $port2) +
    ("Set-Content -LiteralPath '{0}' -Value (`"`$a,`$kept,`$b,`" + (Test-Path -LiteralPath '{1}'))" -f $pOut, $pendingFile))
$spArgs2 = @{ FilePath = $childExe; ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $client2); PassThru = $true }
if ($onWindows) { $spArgs2['WindowStyle'] = 'Hidden' }
$proc2 = Start-Process @spArgs2
foreach ($status in 500, 400) {
    $as = $listener2.BeginGetContext($null, $null)
    if (-not $as.AsyncWaitHandle.WaitOne(30000)) { break }
    $ctx = $listener2.EndGetContext($as)
    $ctx.Response.StatusCode = $status
    $msg = [System.Text.Encoding]::UTF8.GetBytes('{"detail":"x"}')
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($msg, 0, $msg.Length)
    $ctx.Response.Close()
}
if (-not $proc2.WaitForExit(30000)) { $proc2.Kill() }
$listener2.Stop()
$res = ''; if (Test-Path -LiteralPath $pOut) { $res = (Get-Content -LiteralPath $pOut -Raw).Trim() }
# Open WebUI's sign-in rate limit (429) is waited out, not reported as a failure.
$listener2 = New-Object System.Net.HttpListener
$listener2.Prefixes.Add("http://127.0.0.1:$port2/")
$listener2.Start()
$client3 = Join-Path $Work 'client3.ps1'
$tOut = Join-Path $Work 'token-out.txt'
Set-Content -LiteralPath $client3 -Value (("Import-Module '{0}' -Force`n`$env:LOCALAI_TEST_SIGNIN_WAIT = '1'`n" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1')) +
    ("Set-Content -LiteralPath '{0}' -Value (Connect-LaiWebUI -BaseUrl 'http://127.0.0.1:{1}' -Email 'a@b' -Password 'x')" -f $tOut, $port2))
$spArgs3 = @{ FilePath = $childExe; ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $client3); PassThru = $true }
if ($onWindows) { $spArgs3['WindowStyle'] = 'Hidden' }
$proc3 = Start-Process @spArgs3
foreach ($reply in @(@{ Code = 429; Body = '{"detail":"limited"}' }, @{ Code = 200; Body = '{"role":"admin","token":"tok-123"}' })) {
    $as = $listener2.BeginGetContext($null, $null)
    if (-not $as.AsyncWaitHandle.WaitOne(30000)) { break }
    $ctx = $listener2.EndGetContext($as)
    $ctx.Response.StatusCode = $reply.Code
    $msg = [System.Text.Encoding]::UTF8.GetBytes($reply.Body)
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($msg, 0, $msg.Length)
    $ctx.Response.Close()
}
if (-not $proc3.WaitForExit(30000)) { $proc3.Kill() }
$listener2.Stop()
$tok = ''; if (Test-Path -LiteralPath $tOut) { $tok = (Get-Content -LiteralPath $tOut -Raw).Trim() }
Assert-That ($tok -eq 'tok-123') "sign-in waits out a 429 rate limit and then succeeds (got '$tok')"
Assert-That ($res -eq 'none,True,dropped,False') "a 500 keeps the pending password, a 400 drops it (got '$res')"
Set-Content -LiteralPath $pendingFile -Value '{"email": "adm'
$rv = Resolve-LaiPendingPassword -AIRoot $pRoot -BaseUrl 'http://127.0.0.1:1'
Assert-That ($rv -eq 'dropped' -and -not (Test-Path -LiteralPath $pendingFile)) 'a pending file cut off mid-write is dropped instead of blocking every run'

Write-Host "`n=== private ACLs (AI folder, read-only Scripts) ===" -ForegroundColor Cyan
if ($onWindows) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $aclRoot = Join-Path $Work 'aclroot'
    $aclScripts = Join-Path $aclRoot 'Scripts'
    New-Item -ItemType Directory -Force -Path $aclScripts | Out-Null
    Set-Content -LiteralPath (Join-Path $aclScripts 'x.ps1') -Value '1'
    $r1 = Set-LaiPrivateAcl -Path $aclRoot -UserSid $sid
    $r2 = Set-LaiPrivateAcl -Path $aclScripts -UserSid $sid -UserAccess ReadOnly
    $rules = { param($p) @((Get-Acl -LiteralPath $p).Access | ForEach-Object { [pscustomobject]@{ Sid = $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value; Rights = [string]$_.FileSystemRights; Inherited = $_.IsInherited } }) }
    $rootRules = & $rules $aclRoot
    $scriptRules = & $rules (Join-Path $aclScripts 'x.ps1')
    $others = @('S-1-5-11', 'S-1-5-32-545', 'S-1-1-0')   # Authenticated Users, Users, Everyone
    Assert-That ($r1.ExitCode -eq 0 -and (Get-Acl -LiteralPath $aclRoot).AreAccessRulesProtected -and @($rootRules | Where-Object { $others -contains $_.Sid }).Count -eq 0) 'AI folder: inheritance cut, no Users / Authenticated Users / Everyone'
    $userOnScript = @($scriptRules | Where-Object { $_.Sid -eq $sid })
    Assert-That ($r2.ExitCode -eq 0 -and $userOnScript.Count -ge 1 -and @($userOnScript | Where-Object { $_.Rights -match 'Write|Modify|FullControl' }).Count -eq 0) "Scripts: the user can read and run but not change files ($(($userOnScript | ForEach-Object { $_.Rights }) -join '; '))"
    Assert-That (@($scriptRules | Where-Object { $_.Sid -eq 'S-1-5-32-544' -and $_.Rights -match 'FullControl' }).Count -ge 1) 'Scripts: Administrators keep full control (elevated updates still work)'
} else { Skip 'ACL test runs on Windows only' }

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
$specs = @(Get-LaiShortcutSpecs -AIRoot ("C:\It's Dad" + [char]0x2019 + 's AI') -WebUIPort 3001)
Assert-That ($specs.Count -eq 9) "nine shortcut specs (got $($specs.Count))"
$rc = $specs | Where-Object { $_.Name -eq 'Local AI - Re-check models' }
Assert-That ($rc -and $rc.Arguments -match "Update-Models\.ps1' -AIRoot '" -and $rc.Arguments -match "' -RecheckOnly \}" -and $rc.Arguments -notmatch '-Scheduled' -and $rc.Arguments -match 'shortcut-Update-Models\.log') "Re-check models runs Update-Models.ps1 -RecheckOnly (no downloads), logged ($($rc.Arguments))"
$upd = $specs | Where-Object { $_.Name -like '*Update toolkit*' }
Assert-That ($upd -and $upd.Arguments -match 'LOCALAI_ROOT' -and $upd.Arguments -notmatch '-AIRoot') 'Update toolkit passes the AI root via LOCALAI_ROOT'
foreach ($sc in ($specs | Where-Object { $_.Kind -eq 'lnk' })) {
    $cmd = $sc.Arguments.Substring($sc.Arguments.IndexOf('"') + 1).TrimEnd('"')
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$errs)
    Assert-That (@($errs).Count -eq 0) "payload of '$($sc.Name)' parses"
}
# Run a real payload against a script that fails: the error must be on screen before the window
# waits for Enter (-NonInteractive so the test never blocks on Read-Host).
$scRoot = Join-Path $Work 'shortcut-root'
New-Item -ItemType Directory -Force -Path (Join-Path $scRoot 'Scripts') | Out-Null
Set-Content -LiteralPath (Join-Path (Join-Path $scRoot 'Scripts') 'Start-LocalAI.ps1') -Value "param([string]`$AIRoot) throw 'stub failure for the shortcut test'"
$startSpec = @(Get-LaiShortcutSpecs -AIRoot $scRoot) | Where-Object { $_.Name -eq 'Local AI - Start again' }
$payload = $startSpec.Arguments.Substring($startSpec.Arguments.IndexOf('"') + 1).TrimEnd('"')
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$scOut = (& $childExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $payload 2>&1 | ForEach-Object { "$_" }) -join "`n"
$ErrorActionPreference = $prev
Assert-That ($scOut -match 'FAILED: stub failure for the shortcut test') "a failing script's error is shown in the shortcut window before it waits ($(($scOut -split "`n" | Select-Object -First 2) -join ' | '))"
# The window's text is lost when it closes: the run is kept in Logs\shortcut-<script>.log (Logs is
# created by the installer; created here as it would be).
New-Item -ItemType Directory -Force -Path (Join-Path $scRoot 'Logs') | Out-Null
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$null = & $childExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $payload 2>&1
$ErrorActionPreference = $prev
$scLog = Join-Path (Join-Path $scRoot 'Logs') 'shortcut-Start-LocalAI.log'
Assert-That ((Test-Path -LiteralPath $scLog) -and ((Get-Content -Raw -LiteralPath $scLog) -match 'FAILED: stub failure')) 'the shortcut run, failure included, is kept in Logs\shortcut-Start-LocalAI.log'
$updPayload = ($specs | Where-Object { $_.Name -like '*Update toolkit*' }).Arguments
Assert-That ($updPayload -notmatch 'Start-Transcript') 'Update toolkit is not logged (an installer in that window prints the admin password)'
$longSpecs = @(Get-LaiShortcutSpecs -AIRoot ('D:\' + ('x' * 120) + '\AI') | Where-Object { $_.Kind -eq 'lnk' })
$maxLen = ($longSpecs | ForEach-Object { $_.Arguments.Length } | Measure-Object -Maximum).Maximum
Assert-That ($maxLen -lt 1024 -and @($longSpecs | Where-Object { $_.TooLong }).Count -eq 0 -and @($longSpecs | Where-Object { $_.Arguments -match 'Start-Transcript' }).Count -eq 6) "a 125-char AI root: every shortcut fits the 1024-char .lnk limit, logs included ($maxLen)"
$longSpecs = @(Get-LaiShortcutSpecs -AIRoot ('D:\' + ('y' * 200) + '\AI') | Where-Object { $_.Kind -eq 'lnk' })
Assert-That (@($longSpecs | Where-Object { -not $_.TooLong -and $_.Arguments.Length -ge 1024 }).Count -eq 0 -and @($longSpecs | Where-Object { $_.Arguments -match 'Start-Transcript' }).Count -eq 0 -and @($longSpecs | Where-Object { -not $_.TooLong }).Count -ge 6) 'a 205-char AI root: the log is dropped so the shortcuts still fit; none over the limit is offered as usable'
$longSpecs = @(Get-LaiShortcutSpecs -AIRoot ('D:\' + ('z' * 400) + '\AI') | Where-Object { $_.Kind -eq 'lnk' })
Assert-That (@($longSpecs | Where-Object { $_.TooLong }).Count -eq $longSpecs.Count) 'a 405-char AI root: every shortcut is marked too long (the installer skips them with a warning)'
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

# ---- execution policy -------------------------------------------------------------------------
Write-Host "`n=== execution policy ===" -ForegroundColor Cyan
$cases = @(
    @{ Args = @{}; Want = 'set' }
    @{ Args = @{ LocalMachine = 'Restricted' }; Want = 'set' }
    @{ Args = @{ LocalMachine = 'RemoteSigned' }; Want = 'none' }
    @{ Args = @{ LocalMachine = 'Restricted'; CurrentUser = 'RemoteSigned' }; Want = 'none' }
    @{ Args = @{ CurrentUser = 'Restricted' }; Want = 'user' }
    @{ Args = @{ MachinePolicy = 'AllSigned' }; Want = 'gpo' }
    @{ Args = @{ UserPolicy = 'RemoteSigned'; LocalMachine = 'Restricted' }; Want = 'none' }
)
foreach ($c in $cases) {
    $a = $c.Args
    $got = Get-LaiExecutionPolicyAction @a
    Assert-That ($got -eq $c.Want) "policy action for $(($a.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') -> $got (want $($c.Want))"
}

Write-Host "`n=== model manifest paths ===" -ForegroundColor Cyan
$md = Join-Path $Work 'models'
$sep = [System.IO.Path]::DirectorySeparatorChar
foreach ($c in @(
        @{ Name = 'huihui_ai/qwen3-abliterated:32b'; Want = 'manifests/registry.ollama.ai/huihui_ai/qwen3-abliterated/32b' }
        @{ Name = 'qwen3:8b'; Want = 'manifests/registry.ollama.ai/library/qwen3/8b' }
        @{ Name = 'nomic-embed-text'; Want = 'manifests/registry.ollama.ai/library/nomic-embed-text/latest' }
        @{ Name = 'hf.co/bartowski/Qwen3-8B-GGUF:Q4_K_M'; Want = 'manifests/hf.co/bartowski/Qwen3-8B-GGUF/Q4_K_M' }
    )) {
    $got = Get-LaiModelManifestPath -ModelDir $md -Name $c.Name
    $want = Join-Path $md ($c.Want -replace '/', $sep)
    Assert-That ($got -eq $want) "manifest path for $($c.Name)"
}

Write-Host "`n=== Ollama firewall block ranges ===" -ForegroundColor Cyan
$ranges = @(Get-LaiBlockRange -Allowed @('127.0.0.0/8', '172.16.0.0/12', '192.168.50.7/20'))
$toN = { param($ip) $o = @($ip.Split('.') | ForEach-Object { [long]$_ }); $o[0] * 16777216 + $o[1] * 65536 + $o[2] * 256 + $o[3] }
$isBlocked = { param($ip) $n = & $toN $ip; @($ranges | Where-Object { $a, $b = $_.Split('-'); (& $toN $a) -le $n -and $n -le (& $toN $b) }).Count -gt 0 }
foreach ($ip in '127.0.0.1', '172.17.0.2', '172.31.255.254', '192.168.48.1', '192.168.63.255') { Assert-That (-not (& $isBlocked $ip)) "not blocked: $ip (loopback / Docker / WSL)" }
foreach ($ip in '192.168.1.20', '192.168.47.255', '192.168.64.0', '10.0.0.5', '100.101.102.103', '8.8.8.8', '0.0.0.0', '255.255.255.255', '172.15.255.255', '172.32.0.0') { Assert-That (& $isBlocked $ip) "blocked: $ip (LAN / Tailscale / internet)" }
if ($onWindows -and (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
    # The real cmdlet must accept the exact list the installer builds (IPv4 ranges + the IPv6 range).
    $ruleName = 'LocalAI CI test - block ranges'
    try {
        $blockedList = @(Get-LaiBlockRange -Allowed @('127.0.0.0/8', '172.16.0.0/12')) + '::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort 11434 -Action Block -RemoteAddress $blockedList -Profile Any -Enabled False | Out-Null
        $filter = Get-NetFirewallRule -DisplayName $ruleName | Get-NetFirewallAddressFilter
        Assert-That (@($filter.RemoteAddress).Count -eq $blockedList.Count) "Windows Firewall accepts the block ranges ($(@($filter.RemoteAddress) -join ', '))"
    } catch { Assert-That $false "Windows Firewall rejected the block ranges: $($_.Exception.Message)" }
    finally { Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
}

Write-Host "`n=== image pull policy ===" -ForegroundColor Cyan
foreach ($c in @(
        @{ Tags = @('v0.11.4', '2026.10.2-19ffbcd30'); Want = 'missing' }
        @{ Tags = @('v0.11.4-cuda', ''); Want = 'missing' }
        @{ Tags = @('main', '2026.10.2-19ffbcd30'); Want = 'always' }
        @{ Tags = @('v0.11.4', 'latest'); Want = 'always' }
        @{ Tags = @('cuda'); Want = 'always' }
        @{ Tags = @('latest-2'); Want = 'always' }
    )) {
    $got = Get-LaiPullPolicy -Tags $c.Tags
    Assert-That ($got -eq $c.Want) "pull policy for $($c.Tags -join ',') -> $got (want $($c.Want))"
}
$isAdmin = $false
if ($onWindows) { $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
if ($onWindows -and $isAdmin -and $PSVersionTable.PSEdition -eq 'Desktop') {
    # The real thing, exactly as the installer runs it: from a -ExecutionPolicy Bypass process.
    $savedLm = Get-ExecutionPolicy -Scope LocalMachine; $savedCu = Get-ExecutionPolicy -Scope CurrentUser
    try {
        Set-ExecutionPolicy Undefined -Scope CurrentUser -Force -ErrorAction SilentlyContinue
        try { Set-ExecutionPolicy Restricted -Scope LocalMachine -Force -ErrorAction Stop } catch { Write-Verbose 'override warning' }
        $msg = Set-LaiScriptPolicy
        Assert-That ((Get-ExecutionPolicy -Scope LocalMachine) -eq 'RemoteSigned') "Set-LaiScriptPolicy from a Bypass process sets LocalMachine RemoteSigned ($msg)"
        $msg2 = Set-LaiScriptPolicy
        Assert-That ($msg2 -like '*already allows*') 'second run is a no-op'
    } finally {
        try { Set-ExecutionPolicy $savedLm -Scope LocalMachine -Force -ErrorAction Stop } catch { Write-Verbose 'restore' }
        try { Set-ExecutionPolicy $savedCu -Scope CurrentUser -Force -ErrorAction Stop } catch { Write-Verbose 'restore' }
    }
} else { Skip 'real execution-policy change needs elevated Windows PowerShell (runs in Windows CI)' }

# ---- the tests refuse to run outside a throwaway sandbox -------------------------------------------
Write-Host "`n=== a test script refuses to run on a machine not marked as a sandbox ===" -ForegroundColor Cyan
$probe = Join-Path $PSScriptRoot ('zz-sandbox-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
Set-Content -LiteralPath $probe -Value @("`$ErrorActionPreference = 'Stop'", "if (-not (& (Join-Path `$PSScriptRoot 'Assert-LaiSandbox.ps1'))) { exit 99 }", "Write-Host 'PROBE-RAN'")
$savedSandbox = $env:LAI_SANDBOX; $savedHome = $env:HOME
$probeHome = Join-Path ([System.IO.Path]::GetTempPath()) ('lai-nosandbox-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $probeHome | Out-Null
try {
    $env:LAI_SANDBOX = ''
    # Linux: the marker is looked up in $HOME. Windows: the CI runner's profile has no marker.
    if ($env:OS -ne 'Windows_NT') { $env:HOME = $probeHome }
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $probeOut = (& $childExe -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $probeCode = $LASTEXITCODE; $ErrorActionPreference = $prevPref
} finally {
    $env:LAI_SANDBOX = $savedSandbox; $env:HOME = $savedHome
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $probeHome -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-That ($probeCode -eq 99 -and $probeOut -match 'REFUSED' -and $probeOut -notmatch 'PROBE-RAN') "without LAI_SANDBOX=1 or a .lai-sandbox file the test stops before doing anything (exit $probeCode)"

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
# A CI runner may have notifications off for PowerShell: then the line says so ('toast not shown, ...').
$toastLines = @($log | Where-Object { $_ -like '*NOTIFY*Local AI: problem detected*' })
Assert-That ($toastLines.Count -eq 1 -and $toastLines[0] -notlike '*toast failed*') "second failing run sends exactly one notification (toast code ran: $($toastLines -join ' | '))"
$wsToast = [string](Read-LaiState -Path (Join-Path $aiRoot 'watch-state.json'))['toastSetting']
Assert-That (($wsToast -eq '') -eq ($toastLines[0] -notlike '*toast not shown*')) "Windows' notification switch is recorded exactly when the toast was dropped ('$wsToast')"
Assert-That ($r2.Text -notmatch 'Exception') 'notification path does not throw'

$r = Invoke-Child 'Uninstall-LocalAI.ps1' @('-AIRoot', $aiRoot, '-WhatIf')
Assert-That ($r.Code -eq 0) "Uninstall -WhatIf on an empty root exits 0 (got $($r.Code))"
$r = Invoke-Child 'Stop-LocalAI.ps1' @('-AIRoot', $aiRoot, '-PauseHours', '1')
Assert-That ($r.Code -eq 0) "Stop-LocalAI with nothing running exits 0 (got $($r.Code))"
$comfyDir = Join-Path $Work 'ComfyUI_portable'
New-Item -ItemType Directory -Force -Path $comfyDir | Out-Null
Set-Content -LiteralPath (Join-Path $comfyDir 'run_nvidia_gpu.bat') -Value '@echo off'
Push-Location $comfyDir
try { $r = Invoke-Child 'Start-ComfyUI.ps1' @('-AIRoot', $aiRoot, '-Path', (Join-Path '.' 'run_nvidia_gpu.bat'), '-NoLaunch', '-OllamaUrl', 'http://127.0.0.1:1') } finally { Pop-Location }
$saved = [string](Read-LaiState -Path (Join-Path $aiRoot 'localai-config.json'))['ComfyUIPath']
Assert-That ($r.Code -eq 0 -and [System.IO.Path]::IsPathRooted($saved) -and $saved -like '*ComfyUI_portable*run_nvidia_gpu.bat') "Start-ComfyUI remembers a relative -Path as a full path ($saved)"
$r = Invoke-Child 'Release-GPU.ps1' @('-OllamaUrl', 'http://127.0.0.1:1')
Assert-That ($r.Code -eq 0 -and $r.Text -match 'not running') "Release-GPU with Ollama closed says so and exits 0 (got $($r.Code))"
if ($r.Code -ne 0 -or $failures -gt 0) { Write-Host $r.Text }
# Refused before the setup lock or Ollama are touched (both may be in use by another suite).
$r = Invoke-Child 'Update-Models.ps1' @('-AIRoot', $aiRoot, '-RecheckOnly', '-Rollback', 'main')
Assert-That ($r.Code -ne 0 -and $r.Text -match 'cannot be combined' -and -not (Test-Path -LiteralPath (Join-Path $aiRoot 'model-recheck.json'))) "Update-Models -RecheckOnly -Rollback is refused, nothing recorded (exit $($r.Code))"

Write-Host "`n=== Enable-TailscaleAccess against a fake tailscale CLI ===" -ForegroundColor Cyan
$shimDir = Join-Path $Work 'tsshim'
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
$shimPs = Join-Path $shimDir 'tailscale-shim.ps1'
@'
$a = $args -join ' '
Add-Content -LiteralPath $env:LAI_TS_LOG -Value $a
$sc = $env:LAI_TS_SCENARIO
if ($a -eq 'status --json') {
    if ($sc -eq 'hang') { Start-Sleep -Seconds 60 }
    if ($sc -eq 'needslogin') { '{"BackendState":"NeedsLogin","Self":{"DNSName":"pc.tail.ts.net."}}'; exit 0 }
    if ($sc -eq 'nohttps') { '{"BackendState":"Running","Self":{"DNSName":"pc.tail.ts.net."}}'; exit 0 }
    [Console]::Error.WriteLine('Warning: client version differs from the daemon')   # stderr must not break the JSON
    '{"BackendState":"Running","Self":{"DNSName":"pc.tail.ts.net.","CapMap":{"https":null}}}'; exit 0
}
if ($a -like 'serve --bg *') { exit 0 }
if ($a -eq 'serve status --json') {
    if ($sc -eq 'noapply') { '{}'; exit 0 }
    '{"Web":{"pc.tail.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3999"}}}}}'; exit 0
}
if ($a -eq 'serve --https=443 off') { [Console]::Error.WriteLine('error: handler does not exist'); exit 1 }
exit 2
'@ | Set-Content -LiteralPath $shimPs
if ($onWindows) {
    Set-Content -LiteralPath (Join-Path $shimDir 'tailscale.cmd') -Value ('@"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" %*' -f $childExe, $shimPs)
} else {
    Set-Content -LiteralPath (Join-Path $shimDir 'tailscale') -Value ("#!/bin/sh`nexec pwsh -NoProfile -File '{0}' `"`$@`"" -f $shimPs)
    & chmod +x (Join-Path $shimDir 'tailscale')
}
$tsLog = Join-Path $shimDir 'calls.txt'
# A fake docker too: the script recreates Open WebUI with the phone's address allowed.
$dockerLog = Join-Path $shimDir 'docker-calls.txt'
$dockerPs = Join-Path $shimDir 'docker-shim.ps1'
Set-Content -LiteralPath $dockerPs -Encoding UTF8 -Value ('Add-Content -LiteralPath ''{0}'' -Value ($args -join '' ''); exit 0' -f $dockerLog)
if ($onWindows) { Set-Content -LiteralPath (Join-Path $shimDir 'docker.cmd') -Value ('@"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" %*' -f $childExe, $dockerPs) }
else { Set-Content -LiteralPath (Join-Path $shimDir 'docker') -Value ("#!/bin/sh`nexec pwsh -NoProfile -File '{0}' `"`$@`"" -f $dockerPs); & chmod +x (Join-Path $shimDir 'docker') }
New-Item -ItemType Directory -Force -Path (Join-Path $aiRoot 'Stack') | Out-Null
Set-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Stack') '.env') -Encoding UTF8 -Value @('WEBUI_PORT=3999', 'KEEP_ME=1')
$savedPath = $env:Path; $savedPATH = $env:PATH
$env:Path = $shimDir + [System.IO.Path]::PathSeparator + $savedPath
if (-not $onWindows) { $env:PATH = $env:Path }
$env:LAI_TS_LOG = $tsLog
$env:LOCALAI_TS_TIMEOUT = '8'
try {
    $runTs = { param($Scenario, [string[]]$More)
        $env:LAI_TS_SCENARIO = $Scenario
        if (Test-Path -LiteralPath $tsLog) { Remove-Item -LiteralPath $tsLog }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $res = Invoke-Child 'Enable-TailscaleAccess.ps1' (@('-AIRoot', $aiRoot, '-Port', '3999') + $More)
        $calls = @(); if (Test-Path -LiteralPath $tsLog) { $calls = @(Get-Content -LiteralPath $tsLog) }
        return [pscustomobject]@{ Code = $res.Code; Text = $res.Text; Calls = $calls; Seconds = $sw.Elapsed.TotalSeconds }
    }
    $r = & $runTs 'ok' @()
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'available to your tailnet at https://pc\.tail\.ts\.net/') "serve applied and verified -> success (exit $($r.Code))"
    $envTs = @(Get-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Stack') '.env') -Encoding UTF8)
    $dCalls = @(); if (Test-Path -LiteralPath $dockerLog) { $dCalls = @(Get-Content -LiteralPath $dockerLog) }
    Assert-That ($envTs -contains 'WEBUI_EXTRA_ORIGINS=;https://pc.tail.ts.net' -and $envTs -contains 'KEEP_ME=1' -and @($dCalls | Where-Object { $_ -match 'compose .*up -d open-webui$' }).Count -eq 1) "the phone's address is allowed to call Open WebUI, which is recreated ($($dCalls -join ' | '))"
    $r = & $runTs 'needslogin' @()
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'NeedsLogin' -and -not ($r.Calls -match '^serve')) 'not signed in: clear error, nothing served'
    $r = & $runTs 'nohttps' @()
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'HTTPS certificates' -and -not ($r.Calls -match '^serve')) 'HTTPS certificates off: explained, serve never called (it would block)'
    $r = & $runTs 'noapply' @()
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'did not record a mapping') 'serve exits 0 but records nothing: not reported as success'
    $r = & $runTs 'ok' @('-Disable')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'removed') '-Disable with nothing mapped is fine (idempotent)'
    $envTs = @(Get-Content -LiteralPath (Join-Path (Join-Path $aiRoot 'Stack') '.env') -Encoding UTF8)
    Assert-That (@($envTs | Where-Object { $_ -like 'WEBUI_EXTRA_ORIGINS=*' }).Count -eq 0 -and $envTs -contains 'KEEP_ME=1') '-Disable takes the phone address off the allowed list'
    $r = & $runTs 'hang' @()
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'did not answer within 8 s' -and $r.Seconds -lt 40) ("a hung tailscale CLI times out instead of hanging ({0:N0} s)" -f $r.Seconds)
} finally {
    $env:Path = $savedPath; if (-not $onWindows) { $env:PATH = $savedPATH }
    $env:LAI_TS_SCENARIO = ''; $env:LOCALAI_TS_TIMEOUT = ''
}

$composeText = Get-Content -LiteralPath (Join-Path (Join-Path $src 'stack') 'docker-compose.yml') -Raw -Encoding UTF8
Assert-That ($composeText -match 'CORS_ALLOW_ORIGIN: "http://localhost:\$\{WEBUI_PORT:-3000\};http://127\.0\.0\.1:\$\{WEBUI_PORT:-3000\}\$\{WEBUI_EXTRA_ORIGINS:-\}"') 'Open WebUI accepts API calls with your login only from its own pages (no CORS wildcard)'

Write-Host "`n=== resume command: real round trip through Windows PowerShell 5.1 ===" -ForegroundColor Cyan
if ($onWindows) {
    # The installer's own functions, taken from its source, not a copy.
    $instAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Install-LocalAI.ps1'), [ref]$null, [ref]$null)
    foreach ($fn in 'ConvertTo-PsLiteral', 'Get-RelaunchCommand') {
        $def = $instAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)
        . ([scriptblock]::Create($def.Extent.Text))
    }
    $q = [string][char]0x2019
    $stubDir = Join-Path $Work ("stub O'Brien" + $q + 's')
    New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
    $stub = Join-Path $stubDir 'Install-LocalAI.ps1'
    $stubOut = Join-Path $Work 'stub-args.json'
    Set-Content -LiteralPath $stub -Encoding UTF8 -Value ("param([string]`$AIRoot, [string[]]`$KnowledgeCollections, [switch]`$SkipCoder, [switch]`$Resume, [int]`$GpuOverheadMiB)`n" +
        "ConvertTo-Json @{ AIRoot = `$AIRoot; KC = @(`$KnowledgeCollections); SkipCoderPresent = `$PSBoundParameters.ContainsKey('SkipCoder'); SkipCoder = [bool]`$SkipCoder; Resume = [bool]`$Resume; Gpu = `$GpuOverheadMiB } | Set-Content -LiteralPath '$stubOut' -Encoding UTF8")
    $weirdRoot = "C:\AI O'Brien " + $q + 'x'
    $script:BoundParams = @{ AIRoot = $weirdRoot; KnowledgeCollections = @(("Dad" + $q + 's Notes'), 'PC & Electronics'); SkipCoder = [switch]$false; GpuOverheadMiB = 512 }
    $cmd = Get-RelaunchCommand -ScriptPath $stub -AddResume
    if (Test-Path -LiteralPath $stubOut) { Remove-Item -LiteralPath $stubOut }
    # Exactly how the resume task passes it: one argument string to powershell.exe.
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command $cmd" -Wait -WindowStyle Hidden
    $got = $null; if (Test-Path -LiteralPath $stubOut) { $got = Get-Content -Encoding UTF8 -Raw -LiteralPath $stubOut | ConvertFrom-Json }
    Assert-That ($got -and $got.AIRoot -eq $weirdRoot) "AI root with an apostrophe and U+2019 arrives intact ($($got.AIRoot))"
    Assert-That ($got -and @($got.KC).Count -eq 2 -and @($got.KC)[0] -eq ("Dad" + $q + 's Notes') -and @($got.KC)[1] -eq 'PC & Electronics') 'list parameter with U+2019 and & arrives as two items'
    Assert-That ($got -and $got.SkipCoderPresent -and -not $got.SkipCoder -and $got.Resume -and $got.Gpu -eq 512) 'explicit -SkipCoder:$false, -Resume and the number survive'
} else { Skip 'resume round trip runs on Windows only' }

Write-Host "`n=== Test-LocalAI: anything listening beyond localhost is reported ===" -ForegroundColor Cyan
if ($onWindows) {
    $expRoot = Join-Path $Work 'exposure'
    New-Item -ItemType Directory -Force -Path $expRoot | Out-Null
    ConvertTo-Json @{ WebUIPort = 39998; SearxngPort = 39997; OllamaUrl = 'http://127.0.0.1:1' } | Set-Content -LiteralPath (Join-Path $expRoot 'localai-config.json')
    $line = { param($Addr)
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($Addr), 39998)
        $l.Start()
        try { $res = Invoke-Child 'Test-LocalAI.ps1' @('-AIRoot', $expRoot, '-NoContainers', '-Quick') } finally { $l.Stop() }
        return (@($res.Text -split "`n" | Where-Object { $_ -match 'Nothing exposed beyond localhost' }) -join ' ')
    }
    $open = & $line '0.0.0.0'
    $closed = & $line '127.0.0.1'
    Assert-That ($open -match 'FAIL' -and $open -match '39998@0\.0\.0\.0') "a port bound to all interfaces fails the check ($open)"
    Assert-That ($closed -match 'PASS') "the same port on 127.0.0.1 passes ($closed)"
} else { Skip 'exposure check runs on Windows only' }

Write-Host "`n=== diagnostics bundle: redaction ===" -ForegroundColor Cyan
$dRoot = Join-Path $Work 'diagroot'
foreach ($d in 'Secrets', 'Stack', 'Logs') { New-Item -ItemType Directory -Force -Path (Join-Path $dRoot $d) | Out-Null }
$pw = 'Pw-' + [guid]::NewGuid().ToString('N').Substring(0, 16)
$key = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
ConvertTo-Json @{ email = 'someone@example.org'; password = $pw } | Set-Content -LiteralPath (Join-Path (Join-Path $dRoot 'Secrets') 'openwebui-admin.json')
Set-Content -LiteralPath (Join-Path (Join-Path $dRoot 'Stack') '.env') -Value @("WEBUI_SECRET_KEY=$key", 'OPEN_WEBUI_VERSION=v0.11.4')
Set-Content -LiteralPath (Join-Path (Join-Path $dRoot 'Logs') 'install-20990101-000000.log') -Value @("Admin password: $pw", "secret $key", 'login someone@example.org', 'shared by other.person@family.example', "Machine: $env:COMPUTERNAME-TESTHOST", 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop')
Set-Content -LiteralPath (Join-Path (Join-Path $dRoot 'Logs') 'shortcut-Start-LocalAI.log') -Value @('FAILED: shortcut marker 7731', "signed in as someone@example.org with $pw")
ConvertTo-Json @{ WebUIPort = 39999; OllamaUrl = 'http://127.0.0.1:39997' } | Set-Content -LiteralPath (Join-Path $dRoot 'localai-config.json')
$outDir = Join-Path $Work 'diagout'
$r = Invoke-Child 'Get-LocalAIDiagnostics.ps1' @('-AIRoot', $dRoot, '-OutDir', $outDir)
$zipFile = Get-ChildItem -LiteralPath $outDir -Filter 'diagnostics-*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
Assert-That ($r.Code -eq 0 -and $null -ne $zipFile) "diagnostics runs with nothing installed and writes a zip (exit $($r.Code))"
if ($zipFile) {
    $x = Join-Path $Work 'diagx'
    Expand-Archive -LiteralPath $zipFile.FullName -DestinationPath $x -Force
    $all = (Get-ChildItem -LiteralPath $x -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    Assert-That ($all -notmatch [regex]::Escape($pw)) 'admin password redacted'
    Assert-That ($all -notmatch $key) 'secret key redacted'
    Assert-That ($all -notmatch 'someone@example\.org') 'admin e-mail redacted'
    Assert-That ($all -notmatch 'eyJhbGci') 'bearer token redacted'
    Assert-That ($all -notmatch 'other\.person@family') 'any other e-mail address redacted'
    if ($env:COMPUTERNAME) { Assert-That ($all -notmatch [regex]::Escape($env:COMPUTERNAME)) 'computer name redacted' }
    Assert-That ($all -match '\[REDACTED\]') 'redaction markers present'
    Assert-That ((Test-Path -LiteralPath (Join-Path $x 'shortcut-Start-LocalAI.log')) -and ($all -match 'shortcut marker 7731')) 'the last Start-menu shortcut run is in the bundle (redacted with the rest)'
}

Write-Host "`n=== diagnostics redaction: Turkish culture, a 2-letter name, a non-ASCII profile folder ===" -ForegroundColor Cyan
# Under tr-TR, IgnoreCase does not pair I with i; 2-letter names are common (CJK, 'Li'); the profile
# folder keeps an old (accented) name after an account rename; logs are UTF-8 without BOM, which 5.1
# would read as ANSI and so never match the accented name.
$acc = 'Jos' + [char]0x00E9 + '-old'
$tRoot = Join-Path $Work 'diagroot-tr'
foreach ($d in 'Secrets', 'Stack', 'Logs') { New-Item -ItemType Directory -Force -Path (Join-Path $tRoot $d) | Out-Null }
ConvertTo-Json @{ WebUIPort = 39999; OllamaUrl = 'http://127.0.0.1:39997' } | Set-Content -LiteralPath (Join-Path $tRoot 'localai-config.json')
[System.IO.File]::WriteAllText((Join-Path (Join-Path $tRoot 'Logs') 'install-20990101-000000.log'),
    ("models in C:\Users\$acc\.ollama`nuser Li signed in`nOPENAI_API_KEY=sk-tr1234567890`nLimited client list stays readable`n"), (New-Object System.Text.UTF8Encoding($false)))
$saved = @{ U = $env:USERNAME; P = $env:USERPROFILE }
$env:USERNAME = 'Li'; $env:USERPROFILE = (Join-Path (Join-Path $Work 'Users') $acc)
$outTr = Join-Path $Work 'diagout-tr'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$cmdTr = "[System.Globalization.CultureInfo]::CurrentCulture = 'tr-TR'; Write-Output ('CULTURE=' + [System.Globalization.CultureInfo]::CurrentCulture.Name); & '" + (Join-Path $src 'Get-LocalAIDiagnostics.ps1').Replace("'", "''") + "' -AIRoot '" + $tRoot.Replace("'", "''") + "' -OutDir '" + $outTr.Replace("'", "''") + "'; exit 0"
$outTrText = (& $childExe -NoProfile -ExecutionPolicy Bypass -Command $cmdTr 2>&1 | ForEach-Object { "$_" }) -join "`n"
$codeTr = $LASTEXITCODE; $ErrorActionPreference = $prev
Assert-That ($outTrText -match 'CULTURE=tr-TR') 'setup: the diagnostics child really ran under tr-TR'
$env:USERNAME = $saved.U; $env:USERPROFILE = $saved.P
$zipTr = Get-ChildItem -LiteralPath $outTr -Filter 'diagnostics-*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
Assert-That ($codeTr -eq 0 -and $null -ne $zipTr) "diagnostics under tr-TR writes a zip (exit $codeTr)"
if ($zipTr) {
    $xt = Join-Path $Work 'diagx-tr'
    Expand-Archive -LiteralPath $zipTr.FullName -DestinationPath $xt -Force
    $allTr = (Get-ChildItem -LiteralPath $xt -Recurse -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
    Assert-That ($allTr -notmatch 'sk-tr1234567890') 'OPENAI_API_KEY redacted under tr-TR (I/i case rule)'
    Assert-That (-not $allTr.Contains($acc) -and $allTr -match 'C:\\Users\\<user>\\\.ollama') 'accented profile-folder name redacted from a UTF-8 log'
    Assert-That ($allTr -notmatch '\bLi\b' -and $allTr -match 'user <user> signed in') '2-letter user name redacted'
    Assert-That ($allTr -match 'Limited client list stays readable') 'a short name is redacted as a whole word only'
}

Write-Host "`n=== command-line quoting for tasks, shortcuts and pasted commands ===" -ForegroundColor Cyan
Assert-That ((ConvertTo-LaiCmdArg 'D:\') -eq '"D:\\"') 'drive root: the trailing backslash is doubled before the closing quote'
Assert-That ((ConvertTo-LaiCmdArg 'C:\A B\x') -eq '"C:\A B\x"') 'inner backslashes stay single'
Assert-That ((ConvertTo-LaiCmdArg 'a"b') -eq '"a\"b"') 'an inner quote is escaped'
$cl = Get-LaiScriptCommandLine -ScriptPath 'C:\AI\Scripts\Watch-LocalAI.ps1' -AIRoot 'D:\' -Hidden
Assert-That ($cl -eq '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\AI\Scripts\Watch-LocalAI.ps1" -AIRoot "D:\\"') "task command line for a drive-root install ($cl)"
$q = [string][char]0x2019
foreach ($pth in @("C:\Users\O'Brien\AI", ('C:\Mike' + $q + 's Files\AI'), 'C:\plain path\AI')) {
    $back = & ([scriptblock]::Create('param($x) $x')) (& ([scriptblock]::Create('return ' + (ConvertTo-LaiPsQuoted $pth))))
    Assert-That ($back -eq $pth) "pasted PowerShell literal round-trips: $pth"
}
if ($onWindows) {
    # Real round trip: exactly what Task Scheduler / a shortcut hands to powershell.exe.
    $argStub = Join-Path $Work 'argstub.ps1'
    $argOut = Join-Path $Work 'argstub.json'
    Set-Content -LiteralPath $argStub -Encoding UTF8 -Value "param([string]`$AIRoot, [int]`$EngineWaitSec) ConvertTo-Json @{ AIRoot = `$AIRoot; Wait = `$EngineWaitSec } | Set-Content -LiteralPath '$argOut' -Encoding UTF8"
    foreach ($root in @('D:\', 'D:\AI\', "C:\Users\O'Brien\My AI", ('C:\Users\Jos' + [char]0x00E9 + '\AI'))) {
        if (Test-Path -LiteralPath $argOut) { Remove-Item -LiteralPath $argOut }
        Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-LaiScriptCommandLine -ScriptPath $argStub -AIRoot $root -Extra '-EngineWaitSec 1200' -Hidden) -Wait -WindowStyle Hidden
        $gotArg = $null; if (Test-Path -LiteralPath $argOut) { $gotArg = Get-Content -Encoding UTF8 -Raw -LiteralPath $argOut | ConvertFrom-Json }
        Assert-That ($gotArg -and $gotArg.AIRoot -eq $root -and $gotArg.Wait -eq 1200) "powershell.exe receives -AIRoot '$root' and the next argument intact ($($gotArg.AIRoot))"
    }
} else { Skip 'task command-line round trip runs on Windows only' }

Write-Host "`n=== scheduled tasks: no window, the daily time, docker calls with a time limit ===" -ForegroundColor Cyan
# Windows Terminal (Windows 11's default console) shows a window despite -WindowStyle Hidden, and
# closing it kills the run: tasks go through conhost --headless where it exists.
$fakeConhost = Join-Path $Work 'conhost.exe'
Set-Content -LiteralPath $fakeConhost -Value 'x'
$hl = Get-LaiHiddenTaskLaunch -PsArgs '-NoProfile -WindowStyle Hidden -File "x.ps1"' -Build 26200 -ConhostPath $fakeConhost
Assert-That ($hl.Execute -eq $fakeConhost -and $hl.Argument -eq '--headless powershell.exe -NoProfile -WindowStyle Hidden -File "x.ps1"') "Windows 11: conhost --headless, which never opens a window ($($hl.Execute) $($hl.Argument))"
$hl = Get-LaiHiddenTaskLaunch -PsArgs '-NoProfile -WindowStyle Hidden -File "x.ps1"' -Build 18363 -ConhostPath $fakeConhost
Assert-That ($hl.Execute -eq 'powershell.exe' -and $hl.Argument -like '*-WindowStyle Hidden*') 'before Windows 10 2004 (no --headless): powershell.exe -WindowStyle Hidden'
$hl = Get-LaiHiddenTaskLaunch -PsArgs '-File "x.ps1"' -Build 26200 -ConhostPath (Join-Path $Work 'no-such-conhost.exe')
Assert-That ($hl.Execute -eq 'powershell.exe') 'no conhost.exe: powershell.exe'
# The backup's sign-in run is a no-op when the backup due at the last daily time exists.
Assert-That ((Get-LaiLastDailyRun -At '03:30' -Now ([datetime]::new(2026, 10, 5, 9, 0, 0))) -eq [datetime]::new(2026, 10, 5, 3, 30, 0)) 'last daily run at 09:00: today 03:30'
Assert-That ((Get-LaiLastDailyRun -At '03:30' -Now ([datetime]::new(2026, 10, 5, 2, 0, 0))) -eq [datetime]::new(2026, 10, 4, 3, 30, 0)) 'last daily run at 02:00: yesterday 03:30'
Assert-That ((Get-LaiLastDailyRun -At '03:30' -Now ([datetime]::new(2026, 10, 5, 3, 30, 0))) -eq [datetime]::new(2026, 10, 5, 3, 30, 0)) 'the 03:30 run itself is due today'
# A CLI that never answers (Docker Desktop stuck after sleep) is stopped at the limit, not waited on.
$sw = [Diagnostics.Stopwatch]::StartNew()
$tn = Invoke-LaiTimedNative -File $childExe -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -TimeoutSec 3
Assert-That ($tn.TimedOut -and $tn.ExitCode -eq -1 -and $sw.Elapsed.TotalSeconds -lt 30) ("a program that never answers is stopped after the limit ({0:N0} s)" -f $sw.Elapsed.TotalSeconds)
$tn = Invoke-LaiTimedNative -File $childExe -Arguments @('-NoProfile', '-Command', "Write-Output 'a b|c'; exit 7") -TimeoutSec 120
Assert-That (-not $tn.TimedOut -and $tn.ExitCode -eq 7 -and ([string]$tn.Out).Trim() -eq 'a b|c') "arguments with spaces arrive intact; output and exit code come back (exit $($tn.ExitCode): $($tn.Out))"

Write-Host "`n=== context search (Find-LaiMaxContext) with a mocked Ollama and nvidia-smi ===" -ForegroundColor Cyan
# The integration test runs the tuner on a CPU box with -AllowCpu, so the search itself (step-down,
# headroom, failed loads) never runs there. Mocks inside the module: load results and VRAM readings.
$mod = Get-Module LocalAI
& $mod {
    $script:MockLoads = @(); $script:MockFree = [System.Collections.Queue]::new(); $script:MockTrain = 131072
    function script:Get-LaiOllamaModelInfo { param($BaseUrl, $Name) $null = $BaseUrl, $Name; [pscustomobject]@{ TrainContext = $script:MockTrain; Capabilities = @() } }
    function script:Stop-LaiOllamaModels { param($BaseUrl) $null = $BaseUrl }
    function script:Invoke-LaiOllamaLoad {
        param($BaseUrl, $Name, $NumCtx, $KeepAlive)
        $null = $BaseUrl, $KeepAlive
        $script:MockLoads += $NumCtx
        if ($NumCtx -eq 65536) { throw 'cudaMalloc failed: out of memory' }
        [pscustomobject]@{ Name = $Name; Context = $NumCtx; SizeGiB = 20; VramGiB = 20; GpuPercent = 100 }
    }
    function script:Get-LaiGpuInfo { $f = 5000; if ($script:MockFree.Count) { $f = $script:MockFree.Dequeue() }; [pscustomobject]@{ FreeMiB = $f; DriverVersion = '1.0' } }
}
# 65536 fails to load; at 57344 one reading dips to 600 MiB (another app for a moment), the others are 900+.
& $mod { foreach ($v in 600, 900, 950) { $script:MockFree.Enqueue($v) } }
$fit = Find-LaiMaxContext -Name 'm' -Candidates @(32768, 65536, 57344, 65536) -MinFreeMiB 768
$loads = & $mod { $script:MockLoads }
Assert-That ($fit.Context -eq 57344 -and $fit.Fits) "a failed load at 65536 steps down instead of failing; one low VRAM reading does not decide (got $($fit.Context), fits=$($fit.Fits))"
Assert-That ((@($loads) -join ',') -eq '65536,57344') "candidates tried largest first, each once ($(@($loads) -join ','))"
& $mod { $script:MockLoads = @(); $script:MockTrain = 16384; $script:MockFree.Clear() }
$fit = Find-LaiMaxContext -Name 'm' -Candidates @(32768, 65536) -MinFreeMiB 768
Assert-That ($fit.Context -eq 16384 -and (@(& $mod { $script:MockLoads }) -join ',') -eq '16384') 'a model trained on less than every candidate is tried at its own limit'
# A re-published tag this Ollama cannot load at all: every size fails. The search must stop there,
# before the tuned alias (the preset the user chats with) is rebuilt on those weights.
& $mod {
    $script:MockLoads = @(); $script:MockTrain = 131072; $script:Creates = @()
    function script:Invoke-LaiOllamaLoad {
        param($BaseUrl, $Name, $NumCtx, $KeepAlive)
        $null = $BaseUrl, $Name, $KeepAlive
        $script:MockLoads += $NumCtx
        throw '500 llama-server: this model may be incompatible with your version of Ollama'
    }
    function script:Set-LaiOllamaDerivedModel { param($BaseUrl, $Name, $From, $NumCtx, $Parameters, $System) $null = $BaseUrl, $From, $NumCtx, $Parameters, $System; $script:Creates += $Name }
    function script:Get-LaiOllamaVersion { param($BaseUrl) $null = $BaseUrl; '0.35.1' }
    function script:Get-LaiOllamaDigest { param($BaseUrl, $Name) $null = $BaseUrl, $Name; 'digest-new' }
    function script:Test-LaiOllamaModel { param($BaseUrl, $Name) $null = $BaseUrl, $Name; $true }
}
$fitErr = ''
try { Find-LaiMaxContext -Name 'm' -Candidates @(65536, 32768, 8192) -MinFreeMiB 768 | Out-Null } catch { $fitErr = $_.Exception.Message }
Assert-That ($fitErr -match '^m could not be loaded at any context' -and $fitErr -match 'incompatible') "no size loads: an error naming the model and Ollama's reason, not '8192, does not fit' ($fitErr)"
Assert-That ((@(& $mod { $script:MockLoads }) -join ',') -eq '65536,32768,8192') 'every size was tried before giving up'
$setupErr = ''
$um = @(@{ Key = 'main'; Display = 'Main'; Source = 'src:2'; Alias = 'localai-main'; MaxContext = 0; MinTokensPerSec = 40; Parameters = @{} })
try { Invoke-LaiModelSetup -Models $um -Candidates @(65536, 8192) -SystemPrompt 'x' -Retune | Out-Null } catch { $setupErr = $_.Exception.Message }
Assert-That ($setupErr -match 'could not be loaded at any context' -and @(& $mod { $script:Creates }).Count -eq 0) "unloadable weights: the setup stops and the tuned alias is not rebuilt on them (alias writes: $(@(& $mod { $script:Creates }).Count))"
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
$mod = Get-Module LocalAI
& $mod {
    function script:Get-LaiOllamaLoaded { param($BaseUrl) $null = $BaseUrl; @([pscustomobject]@{ name = (Resolve-LaiModelName 'm'); size = 100 }) }
    function script:Invoke-LaiApi { param($Method, $Uri, $Body, $TimeoutSec) $null = $Method, $Uri, $Body, $TimeoutSec }
}
$apiErr = ''
try { Invoke-LaiOllamaLoad -Name 'm' -NumCtx 4096 | Out-Null } catch { $apiErr = $_.Exception.Message }
Assert-That ($apiErr -match 'no size/size_vram') "an Ollama whose /api/ps lacks size_vram is reported, not tuned as 0% GPU ($apiErr)"
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force

Write-Host "`n=== tuning reuse rules (Invoke-LaiModelSetup) with a mocked Ollama ===" -ForegroundColor Cyan
$mod = Get-Module LocalAI
& $mod {
    function script:Get-LaiOllamaVersion { param($BaseUrl) $null = $BaseUrl; '0.35.1' }
    function script:Get-LaiOllamaModelInfo { param($BaseUrl, $Name) $null = $BaseUrl, $Name; [pscustomobject]@{ TrainContext = 32768; Capabilities = @('tools') } }
    function script:Get-LaiOllamaDigest { param($BaseUrl, $Name) $null = $BaseUrl, $Name; 'digest1' }
    function script:Test-LaiOllamaModel { param($BaseUrl, $Name) $null = $BaseUrl, $Name; $true }
    function script:Set-LaiOllamaDerivedModel { param($BaseUrl, $Name, $From, $NumCtx, $Parameters, $System) $null = $BaseUrl, $Name, $From, $NumCtx, $Parameters, $System }
    function script:Stop-LaiOllamaModels { param($BaseUrl) $null = $BaseUrl }
    function script:Invoke-LaiOllamaLoad { param($BaseUrl, $Name, $NumCtx, $KeepAlive) $null = $BaseUrl, $NumCtx, $KeepAlive; [pscustomobject]@{ Name = $Name; Context = 8192; SizeGiB = 2; VramGiB = 2; GpuPercent = 100 } }
    function script:Measure-LaiOllamaSpeed { param($BaseUrl, $Name) $null = $BaseUrl, $Name; 55.5 }
    function script:Find-LaiMaxContext { param($BaseUrl, $Name, $Candidates, $MaxContext, $MinFreeMiB, [switch]$AllowCpu) $null = $BaseUrl, $Candidates, $MaxContext, $MinFreeMiB, $AllowCpu; [pscustomobject]@{ Name = $Name; Context = 8192; Fits = $true } }
}
$mm = @(@{ Key = 'main'; Display = 'Main'; Source = 'src:1'; Alias = 'localai-main'; MaxContext = 0; MinTokensPerSec = 40; Parameters = @{} })
$good = @{ Source = 'src:1'; Fingerprint = 'fp'; MaxContext = 0; Digest = 'digest1'; OllamaVersion = '0.35.1'; TokensPerSec = 50; GpuPercent = 100; Context = 8192; Candidates = '8192' }
$runSetup = { param($Prev) (Invoke-LaiModelSetup -Models $mm -Candidates @(8192) -SystemPrompt 'x' -Previous @{ main = $Prev } -Fingerprint 'fp')['main'] }
Assert-That ((& $runSetup $good.Clone())['Reused']) 'a good earlier result is reused without loading'
$slow = $good.Clone(); $slow['TokensPerSec'] = 10
Assert-That (-not (& $runSetup $slow)['Reused']) 'a result below the minimum speed is measured again, not reused forever'
$spill = $good.Clone(); $spill['GpuPercent'] = 93
Assert-That (-not (& $runSetup $spill)['Reused']) 'a result that was partly on the CPU is measured again'
$cand = $good.Clone(); $cand['Candidates'] = '4096'
Assert-That (-not (& $runSetup $cand)['Reused']) 'an edited candidate list takes effect'
$mmCap = @(@{ Key = 'main'; Display = 'Main'; Source = 'src:1'; Alias = 'localai-main'; MaxContext = 8192; MinTokensPerSec = 40; Parameters = @{} })
$capGood = $good.Clone(); $capGood['MaxContext'] = 8192
Assert-That ((Invoke-LaiModelSetup -Models $mmCap -Candidates @(16384, 8192) -SystemPrompt 'x' -Previous @{ main = $capGood } -Fingerprint 'fp')['main']['Reused']) 'a larger size added for another model does not re-tune a model capped below it'
$capOld = $capGood.Clone(); $capOld['Candidates'] = '16384,8192'
Assert-That ((Invoke-LaiModelSetup -Models $mmCap -Candidates @(32768, 16384, 8192) -SystemPrompt 'x' -Previous @{ main = $capOld } -Fingerprint 'fp')['main']['Reused']) 'a full list recorded before the cap rule still counts as the same for a capped model (no re-tune on update)'
$old = $good.Clone(); $old.Remove('Candidates')
Assert-That ((& $runSetup $old)['Reused']) 'a result from before candidates were recorded is still reused (no forced re-tune)'
& $mod { function script:Invoke-LaiApi { param($Method, $Uri, $Body, $Token, $TimeoutSec) $null = $Method, $Uri, $Body, $Token, $TimeoutSec; [pscustomobject]@{ filenames = @('', $null) } } }
Assert-That ((Test-LaiWebUIWebSearch -Token 't').Status -eq 'no-results') 'an empty web-search result is no-results, not ok'
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force

Write-Host "`n=== Ollama drift: settings line parsed, versions compared, tray app started hidden ===" -ForegroundColor Cyan
# A real 0.35.1 line (shortened). A key a newer Ollama stops logging must read as 'unknown', not as
# a wrong setting (which would kill Ollama twice and advise a pointless -Retune).
$srvLine = 'time=2026-10-04T23:07:51.129Z level=INFO source=routes.go:2117 msg="server config" env="map[CUDA_VISIBLE_DEVICES: LLAMA_ARG_FIT_TARGET: OLLAMA_CONTEXT_LENGTH:0 OLLAMA_FLASH_ATTENTION:true OLLAMA_KV_CACHE_TYPE:q8_0 OLLAMA_MODELS:C:\Users\x\.ollama\models OLLAMA_ORIGINS:[http://localhost https://localhost app://*] OLLAMA_REMOTES:[ollama.com] ROCR_VISIBLE_DEVICES: http_proxy: no_proxy:]"'
$srv = ConvertFrom-LaiServerConfigLine -Line $srvLine
Assert-That ($srv['OLLAMA_KV_CACHE_TYPE'] -eq 'q8_0' -and $srv['OLLAMA_FLASH_ATTENTION'] -eq 'true' -and $srv['OLLAMA_MODELS'] -eq 'C:\Users\x\.ollama\models' -and $srv.ContainsKey('LLAMA_ARG_FIT_TARGET') -and $srv['LLAMA_ARG_FIT_TARGET'] -eq '' -and $srv['OLLAMA_REMOTES'] -eq '[ollama.com]') "server config line parsed: values, empty values, a Windows path ($($srv.Count) keys)"
Assert-That ((Test-LaiOllamaServerSettings -Line $srvLine -KvCacheType 'q8_0').Status -eq 'ok') 'settings applied: ok'
$chkWrong = Test-LaiOllamaServerSettings -Line ($srvLine -replace 'OLLAMA_KV_CACHE_TYPE:q8_0', 'OLLAMA_KV_CACHE_TYPE:') -KvCacheType 'q8_0'
Assert-That ($chkWrong.Status -eq 'wrong' -and ($chkWrong.Wrong -join ' ') -match 'OLLAMA_KV_CACHE_TYPE= \(wanted q8_0\)') "a key logged with another value (empty = f16): wrong, so Ollama is restarted ($($chkWrong.Wrong -join ' '))"
$chkGone = Test-LaiOllamaServerSettings -Line ($srvLine -replace 'OLLAMA_FLASH_ATTENTION:true ', '') -KvCacheType 'q8_0'
Assert-That ($chkGone.Status -eq 'unknown' -and @($chkGone.Missing) -contains 'OLLAMA_FLASH_ATTENTION') 'a key this Ollama no longer logs: unknown, not wrong'
Assert-That ((Test-LaiOllamaServerSettings -Line '' -KvCacheType 'q8_0').Status -eq 'unknown') 'no settings line at all: unknown'
# Presets measured on another Ollama version (the tray app updates itself at sign-in).
$tn = @{ main = @{ Alias = 'localai-main'; OllamaVersion = '0.35.1' }; fast = @{ OllamaVersion = '0.36.0' }; old = @{ Alias = 'localai-old' }; vision = @{ OllamaVersion = '0.35.1' } }
$drift = @(Get-LaiTuningDrift -Tuning $tn -OllamaVersion '0.36.0' -Keys @('main', 'fast', 'old'))
Assert-That ((@($drift | ForEach-Object { $_.Key }) -join ',') -eq 'main' -and $drift[0].Was -eq '0.35.1') "only selected presets measured on another version count; one without a recorded version is left out ($(@($drift | ForEach-Object { $_.Key }) -join ','))"
Assert-That (@(Get-LaiTuningDrift -Tuning $tn -OllamaVersion '').Count -eq 0 -and @(Get-LaiTuningDrift -Tuning $tn -OllamaVersion '0.35.1' -Keys @('main', 'vision')).Count -eq 0) 'Ollama not answering, or the same version: nothing to report'
$mod = Get-Module LocalAI
& $mod { $script:Started = ''; function script:Start-Process { param($FilePath, $ArgumentList) $script:Started = "$FilePath|$(@($ArgumentList) -join ' ')" } }
Start-LaiOllamaApp -Path 'C:\x\ollama app.exe'
Assert-That ((& $mod { $script:Started }) -eq 'C:\x\ollama app.exe|hidden --fast-startup') "the tray app is started hidden (no Ollama window over a game) and without installing a pending update ($(& $mod { $script:Started }))"
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force

Write-Host "`n=== SearXNG: an empty search names each failed engine and the fix ===" -ForegroundColor Cyan
$sxAll = '{"query":"x","results":[],"unresponsive_engines":[["brave","Suspended: too many requests"],["duckduckgo","Suspended: CAPTCHA"],["google cse","parsing error"]]}' | ConvertFrom-Json
$dg = ConvertTo-LaiSearxngDiagnosis -Response $sxAll
Assert-That ($dg.Count -eq 0 -and @($dg.Engines).Count -eq 3 -and (@($dg.Engines) -join '; ') -match 'duckduckgo: Suspended: CAPTCHA') "every failed engine is named with its reason ($(@($dg.Engines) -join '; '))"
Assert-That ((@($dg.Broken) -join ',') -eq 'google cse' -and $dg.Hint -match '-SearxngVersion' -and $dg.Hint -match 'google cse') "a parsing error points at a SearXNG update and names the engine ($($dg.Hint))"
$dg1 = ConvertTo-LaiSearxngDiagnosis -Response ('{"results":[],"unresponsive_engines":[["brave","Suspended: too many requests"]]}' | ConvertFrom-Json)
Assert-That (@($dg1.Engines).Count -eq 1 -and (@($dg1.Blocked) -join ',') -eq 'brave' -and $dg1.Hint -match 'wait' -and $dg1.Hint -notmatch 'SearxngVersion') "one rate-limited engine: wait, no update advice ($($dg1.Hint))"
$dg2 = ConvertTo-LaiSearxngDiagnosis -Response ('{"results":[{"url":"https://a.example"},{"url":"https://b.example"}],"unresponsive_engines":[]}' | ConvertFrom-Json)
Assert-That ($dg2.Count -eq 2 -and @($dg2.Engines).Count -eq 0) 'results counted when the search works'
# A site that answered but refused (SearXNG's 'server API error' / 'HTTP error') is not a connection problem.
$dg3 = ConvertTo-LaiSearxngDiagnosis -Response ('{"results":[],"unresponsive_engines":[["mojeek","server API error"],["qwant","Suspended: HTTP error"]]}' | ConvertFrom-Json)
Assert-That ((@($dg3.Refused) -join ',') -eq 'mojeek,qwant' -and $dg3.Hint -match 'mojeek, qwant answered but refused' -and $dg3.Hint -notmatch 'internet connection') "a refused search names the engines and does not blame the connection ($($dg3.Hint))"
# Results, but some engines failing: the PASS text still names them (a CAPTCHA wave starts that way).
$dg4 = ConvertTo-LaiSearxngDiagnosis -Response ('{"results":[{"url":"https://a.example"}],"unresponsive_engines":[["duckduckgo","Suspended: CAPTCHA"]]}' | ConvertFrom-Json)
Assert-That ($dg4.Summary -eq '1 results (not answering: duckduckgo: Suspended: CAPTCHA)') "results with a failing engine: the summary names it ($($dg4.Summary))"
Assert-That ($dg2.Summary -eq '2 results' -and $dg1.Summary -match '^no results \(brave: Suspended: too many requests\) - brave is rate-limiting') "summary without failures, and for an empty search ($($dg1.Summary))"
# Open WebUI's search empty while SearXNG finds pages: Open WebUI keeps only pages its web loader fetched.
Assert-That ($dg4.WebUIHint -match 'SearXNG itself finds 1 results, so Open WebUI could not use them' -and $dg4.WebUIHint -match 'web loader' -and $dg1.WebUIHint -match 'brave') "Open WebUI empty but SearXNG not: points at Open WebUI's web loader settings ($($dg4.WebUIHint))"
# The probe right after an update recreated the container: the port answers before SearXNG does.
$mod = Get-Module LocalAI
& $mod {
    $script:SxCalls = @(); $script:SxAnswer = $null; $script:SxRefuse = $false
    function script:Invoke-LaiApi {
        param($Method, $Uri, $Body, $Token, $TimeoutSec)
        $null = $Method, $Body, $Token, $TimeoutSec
        $script:SxCalls += [string]$Uri
        # Nothing listening at all (the container is not running).
        if ($script:SxRefuse) { throw (New-Object System.Net.Sockets.SocketException 10061) }
        # Starting: the first /healthz (and any search before it answers) gets a dropped connection.
        $ready = @($script:SxCalls | Where-Object { $_ -like '*/healthz' }).Count -ge 2
        if (-not $ready) { throw 'The underlying connection was closed: An unexpected error occurred on a receive.' }
        if ([string]$Uri -like '*/healthz') { return 'OK' }
        return $script:SxAnswer
    }
    $script:SxAnswer = '{"results":[{"url":"https://a.example"}],"unresponsive_engines":[]}' | ConvertFrom-Json
}
$sxp = $null; $sxErr = ''
try { $sxp = Get-LaiSearxngProbe -BaseUrl 'http://127.0.0.1:8888' -WaitSec 20 } catch { $sxErr = $_.Exception.Message }
$sxCalls = @(& $mod { $script:SxCalls })
Assert-That ($null -ne $sxp -and $sxp.Count -eq 1 -and ($sxCalls -join ' ') -match 'healthz.*healthz.*search\?format=json') "a SearXNG still starting is waited for (/healthz), not reported as down ($sxErr; $($sxCalls -join ' '))"
& $mod { $script:SxCalls = @('x/healthz'); $script:SxAnswer = 'Not JSON at all' }
$sxErr = ''
try { Get-LaiSearxngProbe -BaseUrl 'http://127.0.0.1:8888' -WaitSec 20 | Out-Null } catch { $sxErr = $_.Exception.Message }
Assert-That ($sxErr -match 'did not answer with JSON') "a SearXNG that answers without JSON is an error naming the settings.yml fix ($sxErr)"
& $mod { $script:SxCalls = @(); $script:SxRefuse = $true }
$sxErr = ''
try { Get-LaiSearxngProbe -BaseUrl 'http://127.0.0.1:8888' -WaitSec 60 -RefusedSec 0 | Out-Null } catch { $sxErr = $_.Exception.Message }
$sxCalls = @(& $mod { $script:SxCalls })
Assert-That ($sxErr -match 'not answering' -and ($sxCalls -join ' ') -eq 'http://127.0.0.1:8888/healthz') "nothing listening: reported at once, not after the full wait ($sxErr; $($sxCalls -join ' '))"
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force

Write-Host "`n=== Update-Models: what to do after a model could not be set up ===" -ForegroundColor Cyan
$adv = @(Get-LaiModelSetupAdvice -Why 'm could not be loaded at any context (last error: this model may be incompatible with your version of Ollama)' -Display 'Main' -Key 'main' -Changed -HasPrevious) -join ' | '
Assert-That ($adv -match 'Update-Models\.ps1 -UpdateOllama' -and $adv -match 'Update-Models\.ps1 -Rollback main') "a new download this Ollama cannot load: a newer Ollama, or -Rollback ($adv)"
$adv = @(Get-LaiModelSetupAdvice -Why 'cudaMalloc failed: out of memory' -Display 'Main' -Key 'main' -HasPrevious) -join ' | '
Assert-That ($adv -notmatch 'Rollback' -and $adv -match 'close ComfyUI') "a re-check after an Ollama update (model unchanged, an old -prev still there): no -Rollback; out of memory names the GPU programs ($adv)"
$adv = @(Get-LaiModelSetupAdvice -Why 'connection refused' -Display 'Main' -Key 'main') -join ' | '
Assert-That ($adv -match 'run Update-Models\.ps1 again' -and $adv -notmatch 'Rollback') "anything else: run it again ($adv)"

Write-Host "`n=== skills: SKILL.md files (Agent Skills layout) ===" -ForegroundColor Cyan
$skRoot = Join-Path $Work 'skills-unit'
foreach ($d in 'My Skill!', 'folded', 'plain', 'bom') { New-Item -ItemType Directory -Force -Path (Join-Path $skRoot $d) | Out-Null }
[System.IO.File]::WriteAllText((Join-Path (Join-Path $skRoot 'My Skill!') 'SKILL.md'), "---`nname: ""Export a workflow""`ndescription: When the user shares a ComfyUI workflow`nlicense: MIT`n---`n# Steps`n`n1. Open the menu`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path (Join-Path $skRoot 'folded') 'SKILL.md'), "---`r`nname: Folded`r`ndescription: >`r`n  first line`r`n  second line`r`n---`r`nBody here`r`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path (Join-Path $skRoot 'plain') 'SKILL.md'), "Just instructions, no front matter.`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path (Join-Path $skRoot 'bom') 'SKILL.md'), "---`nname: Caf" + [char]0x00E9 + "`ndescription: x`n---`nok`n", (New-Object System.Text.UTF8Encoding($true)))
$k1 = ConvertFrom-LaiSkillFile -Path (Join-Path (Join-Path $skRoot 'My Skill!') 'SKILL.md')
Assert-That ($k1.Id -eq 'my-skill' -and $k1.Name -eq 'Export a workflow' -and $k1.Description -eq 'When the user shares a ComfyUI workflow' -and $k1.Content -eq "# Steps`n`n1. Open the menu") "front matter read, quotes dropped, other keys ignored; id made from the folder name ($($k1.Id))"
$k2 = ConvertFrom-LaiSkillFile -Path (Join-Path (Join-Path $skRoot 'folded') 'SKILL.md')
Assert-That ($k2.Description -eq 'first line second line' -and $k2.Content -eq 'Body here') "a folded description (>) and CRLF line ends ($($k2.Description))"
$k3 = ConvertFrom-LaiSkillFile -Path (Join-Path (Join-Path $skRoot 'plain') 'SKILL.md')
Assert-That ($k3.Name -eq 'plain' -and $k3.Description -eq '' -and $k3.Content -eq 'Just instructions, no front matter.') 'no front matter: the folder name is the name, the whole file the instructions'
$k4 = ConvertFrom-LaiSkillFile -Path (Join-Path (Join-Path $skRoot 'bom') 'SKILL.md')
Assert-That ($k4.Name -eq ('Caf' + [char]0x00E9) -and $k4.Content -eq 'ok') 'a UTF-8 file with a BOM and an accented name (Windows Notepad saves it so)'
$fmCases = @(
    @{ Text = "---`nname: Plain`ndescription: starts here`n  and goes on # a comment`n---`nb"; Name = 'Plain'; Desc = 'starts here and goes on'; What = 'a plain value continued on the next line, trailing comment dropped' }
    @{ Text = "---`nname: Block`ndescription: |-`n  one`n`n  two`nlicense: MIT`n---`nb"; Name = 'Block'; Desc = 'one two'; What = 'a blank line inside a | block does not end it' }
    @{ Text = "---`nname: Ind`ndescription: >2`n  indented`n---`nb"; Name = 'Ind'; Desc = 'indented'; What = 'a block with an indent digit (>2)' }
    @{ Text = '---' + "`n" + "name: 'It''s mine'" + "`n" + 'description: "say \"hi\"" # c' + "`n---`nb"; Name = "It's mine"; Desc = 'say "hi"'; What = 'YAML quote escapes, and a comment after a quoted value' }
    @{ Text = "---`n---`nonly the body"; Name = 'fm'; Desc = ''; What = 'empty front matter is not part of the instructions'; Body = 'only the body' }
)
New-Item -ItemType Directory -Force -Path (Join-Path $skRoot 'fm') | Out-Null
foreach ($c in $fmCases) {
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $skRoot 'fm') 'SKILL.md'), $c.Text, (New-Object System.Text.UTF8Encoding($false)))
    $kc = ConvertFrom-LaiSkillFile -Path (Join-Path (Join-Path $skRoot 'fm') 'SKILL.md')
    $body = 'b'; if ($c.Body) { $body = $c.Body }
    Assert-That ($kc.Name -ceq $c.Name -and $kc.Description -ceq $c.Desc -and $kc.Content -ceq $body) "SKILL.md: $($c.What) (name '$($kc.Name)', description '$($kc.Description)', body '$($kc.Content)')"
}
Assert-That ((ConvertTo-LaiSkillId 'My Skill!') -eq 'my-skill' -and (ConvertTo-LaiSkillId 'research!') -eq (ConvertTo-LaiSkillId 'Research') -and (ConvertTo-LaiSkillId '!!!') -eq '') 'skill ids from folder names (two folders can give one id: the sync skips the second)'
$mf = Get-LaiSkillMetaForm ([pscustomobject]@{ meta = [pscustomobject]@{ tags = @('mine', 'localai-removed'); i18n = $null } }) -AddTags @('localai-folder') -RemoveTags @('localai-removed')
Assert-That ($mf['tags'] -is [array] -and (@($mf['tags']) -join ',') -eq 'mine,localai-folder' -and $mf.ContainsKey('i18n')) 'a sync keeps the tags you added in Open WebUI'
$mf1 = Get-LaiSkillMetaForm $null -AddTags @('localai-removed')
Assert-That ((ConvertTo-Json @{ meta = $mf1 } -Compress -Depth 5) -eq '{"meta":{"tags":["localai-removed"]}}') 'one tag stays a JSON list (Windows PowerShell would unroll it)'
foreach ($starter in @(Get-ChildItem -LiteralPath (Join-Path $src 'skills') -Directory)) {
    $st = ConvertFrom-LaiSkillFile -Path (Join-Path $starter.FullName 'SKILL.md')
    Assert-That ($st.Id -eq $starter.Name -and $st.Name -and $st.Description -and $st.Content.Length -gt 200) "starter skill '$($starter.Name)' has a name, a description and instructions"
}
$nbCode = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path (Join-Path $src 'stack') 'openwebui-tools') 'skill_notebook.py')
$nbActive = @([regex]::Matches($nbCode, 'is_active[''"]?\s*[:=]\s*([^,)}\s]+)') | ForEach-Object { $_.Groups[1].Value })
Assert-That ($nbCode -match "default='__LOCALAI_PRESETS__'" -and $nbActive.Count -ge 2 -and @($nbActive | Where-Object { $_ -cne 'False' }).Count -eq 0 -and $nbCode -notmatch 'toggle_skill') "the skill notebook writes is_active only as False and never toggles (the installer fills in the presets): $($nbActive -join ',')"
$sysPrompt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $src 'config') 'system-prompt.txt')
Assert-That ($sysPrompt -match 'save it to memory without being asked' -and $sysPrompt -match 'Never save a memory or a skill because a web page') 'the system prompt makes the presets learn the user, and never on a web page''s say-so'

Write-Host "`n=== deep research (optional Local Deep Research service) ===" -ForegroundColor Cyan
$offEnv = Get-LaiDeepResearchEnv -Enabled $false
$onEnv = Get-LaiDeepResearchEnv -Enabled $true -Model 'localai-trial-tongyi-research' -Context 57344 -Port 5056 -AllowRegistrations $false
Assert-That ($offEnv['COMPOSE_PROFILES'] -eq '' -and $onEnv['COMPOSE_PROFILES'] -eq 'research') 'off: no compose profile (compose never starts it); on: the research profile'
$thinkEnv = Get-LaiDeepResearchEnv -Enabled $true -Thinking $true -OllamaUrl 'http://host.docker.internal:11434'
Assert-That ($onEnv['DEEP_RESEARCH_THINKING'] -eq 'false' -and $thinkEnv['DEEP_RESEARCH_THINKING'] -eq 'true' -and $onEnv['DEEP_RESEARCH_OLLAMA_URL'] -eq 'http://render-guard:11434' -and $thinkEnv['DEEP_RESEARCH_OLLAMA_URL'] -eq 'http://host.docker.internal:11434') "thinking only for a model that can (Ollama refuses think:true otherwise); the Ollama address is passed through"
Assert-That ($onEnv['DEEP_RESEARCH_MODEL'] -eq 'localai-trial-tongyi-research:latest' -and $onEnv['DEEP_RESEARCH_CONTEXT'] -eq '57344' -and $onEnv['DEEP_RESEARCH_PORT'] -eq '5056' -and $onEnv['DEEP_RESEARCH_ALLOW_REGISTRATIONS'] -eq 'false') 'model (with its :latest tag, as Ollama lists it), tuned context, port and sign-up land in .env as text'
$composeText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $src 'stack') 'docker-compose.yml')
$svc = [regex]::Match($composeText, '(?ms)^  deep-research:\r?\n(.*?)(?=^\S|^  \S)').Groups[1].Value
Assert-That ($svc -match 'profiles: \["research"\]' -and $svc -match '"127\.0\.0\.1:\$\{DEEP_RESEARCH_PORT' -and $svc -match 'LDR_LLM_OLLAMA_URL: \$\{DEEP_RESEARCH_OLLAMA_URL:-http://render-guard:11434\}' -and $svc -match 'LDR_LLM_OLLAMA_ENABLE_THINKING: \$\{DEEP_RESEARCH_THINKING:-false\}' -and $svc -match 'LDR_LLM_LOCAL_CONTEXT_WINDOW_SIZE: \$\{DEEP_RESEARCH_CONTEXT' -and $svc -match 'cap_drop: \[ALL\]') 'compose: only with the research profile, loopback port, through the render guard by default, thinking off by default, at the tuned context, capabilities dropped'
Assert-That ($svc -match 'LDR_SEARCH_TOOL: searxng' -and $svc -notmatch '(?i)api_key|tavily|serpapi|brave_api') 'compose: free search only (the private SearXNG), no search API key'
foreach ($k in @($onEnv.Keys)) { if ($k -ne 'COMPOSE_PROFILES') { Assert-That ($composeText -match [regex]::Escape('${' + $k)) "compose reads $k" } }
$rsCat = @((Get-LaiCatalog -Path (Join-Path (Join-Path $src 'config') 'models.psd1') -IncludeTrials).Models | Where-Object { $_.Key -eq 'trial-research' })
Assert-That ($rsCat.Count -eq 1 -and $rsCat[0].Trial -and $rsCat[0].Source -eq 'huihui_ai/tongyi-deepresearch-abliterated:30b' -and $rsCat[0].Parameters['presence_penalty'] -eq 1.1) 'the Tongyi DeepResearch trial is in the catalog, opt-in, with its own sampling'
$rsSpecs = @(Get-LaiShortcutSpecs -AIRoot 'C:\AI' -WebUIPort 3000 -DeepResearchPort 5056 | Where-Object { $_.Name -eq 'Local AI - Deep Research' })
Assert-That ($rsSpecs.Count -eq 1 -and $rsSpecs[0].Target -eq 'http://localhost:5056/' -and @(Get-LaiShortcutSpecs -AIRoot 'C:\AI' | Where-Object { $_.Name -like '*Deep Research*' }).Count -eq 0) 'a Deep Research shortcut only when it is installed'
# After a re-tune the research agent must ask for the new context (else Ollama reloads on every switch).
$drRoot = Join-Path $Work 'dr-ctx'; New-Item -ItemType Directory -Force -Path (Join-Path $drRoot 'Stack') | Out-Null
$drEnv = Join-Path (Join-Path $drRoot 'Stack') '.env'
$drModels = @(@{ Key = 'main'; Alias = 'localai-main' }, @{ Key = 'trial-research'; Alias = 'localai-trial-tongyi-research' })
Set-Content -LiteralPath $drEnv -Value @('COMPOSE_PROFILES=research', 'DEEP_RESEARCH_MODEL=localai-trial-tongyi-research:latest', 'DEEP_RESEARCH_CONTEXT=65536', 'OTHER=kept')
$mod = Get-Module LocalAI
& $mod { $script:DrCalls = @(); function script:Invoke-LaiTimedNative { param($File, $Arguments, $TimeoutSec) $null = $TimeoutSec; $script:DrCalls += ($File + ' ' + ($Arguments -join ' ')); [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Out = ''; Text = '' } } }
$drLine = Update-LaiDeepResearchContext -AIRoot $drRoot -Tuning @{ 'trial-research' = @{ Context = 49152 }; main = @{ Context = 65536 } } -Models $drModels
$drAfter = @(Get-Content -Encoding UTF8 -LiteralPath $drEnv)
Assert-That ($drAfter -contains 'DEEP_RESEARCH_CONTEXT=49152' -and $drAfter -contains 'OTHER=kept' -and @(& $mod { $script:DrCalls }).Count -eq 1 -and (@(& $mod { $script:DrCalls })[0] -match 'compose .* up -d deep-research') -and $drLine -match '49152') "a re-tuned research model: Stack\.env gets its new context and the service is recreated ($drLine)"
$drLine2 = Update-LaiDeepResearchContext -AIRoot $drRoot -Tuning @{ 'trial-research' = @{ Context = 49152 } } -Models $drModels
Set-Content -LiteralPath $drEnv -Value @('COMPOSE_PROFILES=', 'DEEP_RESEARCH_MODEL=localai-main:latest', 'DEEP_RESEARCH_CONTEXT=1')
$drLine3 = Update-LaiDeepResearchContext -AIRoot $drRoot -Tuning @{ main = @{ Context = 65536 } } -Models $drModels
Assert-That (-not $drLine2 -and -not $drLine3 -and @(& $mod { $script:DrCalls }).Count -eq 1 -and (@(Get-Content -Encoding UTF8 -LiteralPath $drEnv) -contains 'DEEP_RESEARCH_CONTEXT=1')) 'nothing to do when the context already matches, or when deep research is off'
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
$mod = Get-Module LocalAI
$closedPort = 1; $refused = ''
try { Connect-LaiResearch -BaseUrl "http://127.0.0.1:$closedPort" -Account 'a' -Password 'b' -TimeoutSec 5 | Out-Null; $refused = 'no error' } catch { $refused = $_.Exception.Message }
Assert-That ($refused -match '^Local Deep Research at http://127\.0\.0\.1:1 could not be reached') "nothing listening: one clear error naming the address, not a half-run request ($refused)"
Assert-That ((Get-LaiResearchFormError '<div class="alert alert-error">Invalid username or password</div>') -eq 'Invalid username or password' -and (Get-LaiResearchFormError '<p>ok</p>') -eq '') "a refused form's message is read for the error"

Write-Host "`n=== process environment: a variable restored to 'not set' is removed, not left empty ===" -ForegroundColor Cyan
Remove-Item -LiteralPath 'Env:LAI_UNIT_ENV' -ErrorAction SilentlyContinue
$before = [Environment]::GetEnvironmentVariable('LAI_UNIT_ENV', 'Process')
Set-LaiProcessEnv -Name 'LAI_UNIT_ENV' -Value '3.20'
$during = [Environment]::GetEnvironmentVariable('LAI_UNIT_ENV', 'Process')
Set-LaiProcessEnv -Name 'LAI_UNIT_ENV' -Value $before
Assert-That ($during -eq '3.20' -and -not (Test-Path -LiteralPath 'Env:LAI_UNIT_ENV')) "set, then restored to not set: the variable is gone (docker compose would prefer an empty one over .env)"

Write-Host "`n=== Open WebUI setup: settings are read back; optional steps only warn ===" -ForegroundColor Cyan
$cmp = @(Compare-LaiConfig -Expected @{ A = $true; N = 2000; S = 'searxng'; web = @{ U = 'http://x/?q=<query>'; C = 5 } } `
    -Actual ([pscustomobject]@{ A = $true; N = [long]2000; S = 'searxng'; web = [pscustomobject]@{ U = 'http://x/?q=<query>'; C = 5 } }))
Assert-That ($cmp.Count -eq 0) "identical settings compare equal across JSON types (bool, Int64, nested) ($($cmp -join '; '))"
$cmp = @(Compare-LaiConfig -Expected @{ A = $false; N = 2000; web = @{ C = 5; Z = 1 } } -Actual ([pscustomobject]@{ A = $true; web = [pscustomobject]@{ C = $null } }))
Assert-That (($cmp -join '|') -eq 'A: wanted False, got True|N: not returned|web.C: wanted 5, got nothing|web.Z: not returned') "differences are listed by key, nested ones as web.KEY ($($cmp -join '|'))"
$savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    $cmp = @(Compare-LaiConfig -Expected @{ R = 0.5 } -Actual ([pscustomobject]@{ R = [double]0.5 }))
} finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture }
Assert-That ($cmp.Count -eq 0) 'a decimal compares equal under a comma-decimal culture'
$cmp = @(Compare-LaiConfig -Expected @{ K = 5; J = 5 } -Actual ('{"K": 5.0, "J": 5.5}' | ConvertFrom-Json))
Assert-That (($cmp -join '|') -eq 'J: wanted 5, got 5.5') "numbers compare as numbers: JSON 5.0 equals 5, 5.5 does not ($($cmp -join '|'))"
$mod = Get-Module LocalAI
& $mod {
    $script:FakeAdmin = @{ ENABLE_SIGNUP = $true; ENABLE_MEMORIES = $false; ENABLE_MEMORY_SYSTEM_CONTEXT = $false; ENABLE_COMMUNITY_SHARING = $true; OTHER = 'kept' }
    $script:DropSignup = $false; $script:OldTopK = $null; $script:RagThrows = $false; $script:Rag = @{}; $script:Kbs = @()
    $script:NullKey = $null; $script:RagSent = @{}; $script:UserParams = $null
    function script:Invoke-LaiApi { param($Method, $Uri, $Body, $Token, $TimeoutSec) $null = $Token, $TimeoutSec
        # The context-override lookup at the end of the setup (read-only).
        if ($Uri -like '*/api/v1/users/user/settings') { return [pscustomobject]@{ ui = [pscustomobject]@{ params = $script:UserParams } } }
        if ($Uri -like '*/api/v1/configs/models') { return [pscustomobject]@{ DEFAULT_MODEL_PARAMS = $null } }
        if ($Uri -notlike '*/api/v1/auths/admin/config') { throw "unexpected call $Uri" }
        if ($Method -eq 'POST') { foreach ($k in @($Body.Keys)) { if (-not ($script:DropSignup -and $k -eq 'ENABLE_SIGNUP')) { $script:FakeAdmin[$k] = $Body[$k] } } }
        return [pscustomobject]$script:FakeAdmin }
    function script:Get-LaiWebUIModelIds { param($BaseUrl, $Token) $null = $BaseUrl, $Token; @('localai-main:latest', 'qwen3:1.7b') }
    function script:Get-LaiWebUIModel { param($BaseUrl, $Token, $Id) $null = $BaseUrl, $Token, $Id; $null }
    function script:Set-LaiWebUIModel { param($BaseUrl, $Token, $Model) $null = $BaseUrl, $Token, $Model; 'created' }
    function script:Hide-LaiWebUIModel { param($BaseUrl, $Token, $Id) $null = $BaseUrl, $Token, $Id }
    function script:Set-LaiWebUIModelsConfig { param($BaseUrl, $Token, $DefaultModel, $Order) $null = $BaseUrl, $Token, $DefaultModel, $Order }
    function script:Set-LaiWebUIRetrievalConfig { param($BaseUrl, $Token, $Settings) $null = $BaseUrl, $Token
        if ($script:RagThrows) { throw 'HTTP 500 Internal Server Error' }
        $script:RagSent = ConvertTo-LaiHashtable $Settings
        $script:Rag = ConvertTo-LaiHashtable $Settings
        if ($null -ne $script:OldTopK) { $script:Rag['TOP_K'] = $script:OldTopK }
        if ($script:NullKey) { $script:Rag[$script:NullKey] = $null } }
    function script:Get-LaiWebUIRetrievalConfig { param($BaseUrl, $Token) $null = $BaseUrl, $Token; [pscustomobject]$script:Rag }
    function script:Add-LaiWebUIKnowledge { param($BaseUrl, $Token, $Name, $Description) $null = $BaseUrl, $Token, $Description
        if ($Name -eq 'Rejected') { throw 'HTTP 400 Bad Request' }
        $script:Kbs += $Name; [pscustomobject]@{ Action = 'created' } }
    # Document search models: tested on their own (below); here an owner's setup, nothing changed.
    function script:Set-LaiWebUIEmbedding { param($BaseUrl, $Token) $null = $BaseUrl, $Token; [pscustomobject]@{ Result = 'owner'; Detail = 'ollama test'; Warnings = @() } }
}
$setupArgs = @{ Token = 't'; SystemPrompt = 'sys'; DefaultPreset = 'local-main'; ModelResults = @{ main = @{ Tools = $true } }; Collections = @('Rejected', 'Notes')
    Models = @(@{ Key = 'main'; Preset = 'local-main'; Alias = 'localai-main'; Source = 'qwen3:1.7b'; Display = 'Local Main'; Description = 'd'; Order = 1; Vision = $false; Think = $null; Trial = $false }) }
$w = @(Invoke-LaiWebUISetup @setupArgs)
Assert-That ((& $mod { $script:FakeAdmin['ENABLE_SIGNUP'] }) -eq $false -and (& $mod { $script:FakeAdmin['OTHER'] }) -eq 'kept') 'sign-up is turned off and unmanaged admin settings are kept'
Assert-That ($w.Count -eq 1 -and $w[0] -like "Knowledge collection 'Rejected'*") "a rejected knowledge collection is one warning, not a failed install ($($w -join ' | '))"
Assert-That ((@(& $mod { $script:Kbs }) -join ',') -eq 'Notes') 'the collections after a rejected one are still created'
& $mod { $script:OldTopK = 3; $script:Kbs = @() }
$w = @(Invoke-LaiWebUISetup @setupArgs)
Assert-That (@($w | Where-Object { $_ -like '*TOP_K: wanted 10, got 3*' }).Count -eq 1) "a RAG setting the server did not keep is reported by name ($($w -join ' | '))"
# Context budget: full-size images re-sent every turn overflow Local Vision's 32K after ~7 photos, and
# one uncapped fetched page fills Fast/Vision so Ollama silently drops the user's question.
& $mod { $script:OldTopK = $null; $script:NullKey = 'FILE_IMAGE_COMPRESSION_WIDTH' }
$w = @(Invoke-LaiWebUISetup @setupArgs)
$sent = & $mod { $script:RagSent }
Assert-That ($sent['FILE_IMAGE_COMPRESSION_WIDTH'] -eq 1920 -and $sent['FILE_IMAGE_COMPRESSION_HEIGHT'] -eq 1920) "attached images are scaled to fit 1920 px (sent: $($sent['FILE_IMAGE_COMPRESSION_WIDTH']) x $($sent['FILE_IMAGE_COMPRESSION_HEIGHT']))"
$fetchCap = 0; if ($sent['web'] -is [hashtable] -and $null -ne $sent['web']['WEB_FETCH_MAX_CONTENT_LENGTH']) { $fetchCap = [int]$sent['web']['WEB_FETCH_MAX_CONTENT_LENGTH'] }
Assert-That ($fetchCap -gt 0 -and $fetchCap -le 40000) "a page the model fetches is capped at about 10K tokens or less (sent: $fetchCap characters)"
Assert-That (@($w | Where-Object { $_ -like '*FILE_IMAGE_COMPRESSION_WIDTH: wanted 1920, got nothing*' }).Count -eq 1) "an Open WebUI that does not keep the image scaling is reported by name ($($w -join ' | '))"
# A context set in the user's own Settings wins over the tuned alias: the install report names it.
& $mod { $script:NullKey = $null; $script:UserParams = [pscustomobject]@{ num_ctx = 8192 } }
$w = @(Invoke-LaiWebUISetup @setupArgs)
Assert-That (@($w | Where-Object { $_ -like '*overrides the tuned context in your Settings*num_ctx 8192*' }).Count -eq 1) "a context override in the user's Settings is in the install report ($($w -join ' | '))"
& $mod { $script:UserParams = $null; $script:RagThrows = $true }
$w = @(Invoke-LaiWebUISetup @setupArgs)
Assert-That (@($w | Where-Object { $_ -like 'Documents/web search settings failed (HTTP 500*' }).Count -eq 1) 'a failing RAG update is a warning, and the setup carries on'
& $mod { $script:RagThrows = $false; $script:DropSignup = $true; $script:FakeAdmin['ENABLE_SIGNUP'] = $true }
$threw = $null
try { Invoke-LaiWebUISetup @setupArgs | Out-Null } catch { $threw = $_.Exception.Message }
Assert-That ($threw -like "*did not keep 'sign-up off'*ENABLE_SIGNUP: wanted False, got True*") "sign-up left on stops the install, it is never just a warning ($threw)"
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
$mod = Get-Module LocalAI

Write-Host "`n=== Open WebUI: user settings survive re-runs; a newer Open WebUI is handled safely ===" -ForegroundColor Cyan
# A preset the user changed: a tool category the installer does not manage turned off, an extra
# capability, an unknown key. A re-run must change only what the installer manages.
$entry = @{ Preset = 'local-main'; Alias = 'localai-main'; Display = 'Local Main'; Description = 'd'; Vision = $false; Think = $null; Trial = $false }
$managedForm = New-LaiPresetForm -Entry $entry -NativeTools $true -SystemPrompt 'sys'
# Prompt injection: no preset may read past chats (a page could have them sent out in a fetched URL),
# and only the official presets search the web on their own.
$offForm = New-LaiPresetForm -Entry @{ Preset = 'official-main'; Alias = 'localai-official-main'; Display = 'Official Main'; Description = 'd'; Vision = $true; Think = $null; Official = $true } -NativeTools $true -SystemPrompt 'sys'
Assert-That ($managedForm.meta.builtinTools['chats'] -eq $false -and $offForm.meta.builtinTools['chats'] -eq $false) 'no preset gets the past-chat tools'
Assert-That (@($managedForm.meta['defaultFeatureIds']).Count -eq 0 -and @($offForm.meta['defaultFeatureIds']) -contains 'web_search') 'uncensored presets search only when asked; official ones by default'
$mergedOld = Merge-LaiPresetForm -Managed $managedForm -Existing ([pscustomobject]@{ id = 'local-main'; meta = [pscustomobject]@{ defaultFeatureIds = @('web_search'); builtinTools = [pscustomobject]@{ chats = $true } }; params = [pscustomobject]@{} })
Assert-That (@($mergedOld.meta['defaultFeatureIds']).Count -eq 0 -and $mergedOld.meta.builtinTools['chats'] -eq $false) 'an existing install loses auto-search on the uncensored presets and the past-chat tools on update'
# The preset form never sets 'hidden': a preset the owner hid stays hidden on re-runs. The installer
# shows a trial/official preset again only when it hid it itself (mock run phases 4 and 4f).
foreach ($kind in 'Official', 'Trial') {
    $oe = @{ Preset = 'official-main'; Alias = 'localai-official-main'; Display = 'Official Main'; Description = 'd'; Vision = $true; Think = $null; Trial = ($kind -eq 'Trial'); Official = ($kind -eq 'Official') }
    $of = New-LaiPresetForm -Entry $oe -NativeTools $true -SystemPrompt 'sys'
    $om = Merge-LaiPresetForm -Managed $of -Existing ([pscustomobject]@{ id = 'official-main'; name = 'Official Main'; meta = [pscustomobject]@{ hidden = $true }; params = [pscustomobject]@{} })
    Assert-That (-not $of.meta.ContainsKey('hidden') -and $om.meta['hidden'] -eq $true) "a $kind preset the owner hid stays hidden on a re-run"
}
Assert-That (-not $managedForm.meta.ContainsKey('hidden')) 'a measured preset form leaves hidden alone (the user may have hidden it)'
$existingPreset = [pscustomobject]@{ id = 'local-main'; name = 'Local Main'; base_model_id = 'localai-main:latest'; params = [pscustomobject]@{ temperature = 0.3 }
    meta = [pscustomobject]@{ builtinTools = [pscustomobject]@{ calendar = $false; web_search = $false; code_interpreter = $true }
        capabilities = [pscustomobject]@{ usage = $true; code_interpreter = $true }; myOwnKey = 'kept' } }
$merged = Merge-LaiPresetForm -Managed $managedForm -Existing $existingPreset
Assert-That ($merged.meta.builtinTools['calendar'] -eq $false -and $merged.meta.capabilities['usage'] -eq $true -and $merged.meta['myOwnKey'] -eq 'kept') 'a tool category the user turned off, an extra capability and an unknown key are kept'
Assert-That ($merged.meta.builtinTools['code_interpreter'] -eq $false -and $merged.meta.capabilities['code_interpreter'] -eq $false -and $merged.meta.builtinTools['web_search'] -eq $true) 'what the installer manages is still enforced (no code execution)'
Assert-That ($merged.params['temperature'] -eq 0.3 -and $merged.params['system'] -eq 'sys') 'user parameters kept, system prompt refreshed'
Assert-That ((Get-LaiWebUICompat -Version 'v0.11.4') -eq 'tested' -and (Get-LaiWebUICompat -Version 'v0.12.0') -eq 'newer' -and (Get-LaiWebUICompat -Version '0.11.4-dev') -eq 'tested' -and (Get-LaiWebUICompat -Version 'main') -eq 'unknown') 'Open WebUI versions are compared numerically'
$mod = Get-Module LocalAI
& $mod {
    $script:Posts = 0
    function script:Invoke-LaiApi { param($Method, $Uri, $Body, $Token, $TimeoutSec) $null = $Uri, $Body, $Token, $TimeoutSec; if ($Method -eq 'POST') { $script:Posts++ }; [pscustomobject]@{ OLLAMA_URLS = @('http://user-added:11434') } }
}
$chg = Set-LaiWebUIOllamaUrl -Token 't' -OllamaUrl 'http://render-guard:11434'
Assert-That (-not $chg -and (& $mod { $script:Posts }) -eq 0) "a renamed connection list is left alone, not overwritten with ours alone (the user's connections would be deleted)"
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force

Write-Host "`n=== document search: embedder and reranker, the owner's own setup left alone ===" -ForegroundColor Cyan
# A fake Open WebUI: $script:Emb is its embedding config, $script:Rc its retrieval config; posts are logged.
$runEmb = {
    param([hashtable]$Emb, [hashtable]$Rc, [string]$FailOn = '')
    $mod = Get-Module LocalAI
    & $mod {
        param($e, $r, $f)
        $script:Emb = $e; $script:Rc = $r; $script:FailOn = $f; $script:Posted = @()
        function script:Invoke-LaiApi {
            param($Method, $Uri, $Body, $Token, $TimeoutSec)
            $null = $Token, $TimeoutSec
            if ($Method -eq 'POST') {
                $script:Posted += ($Uri -replace '^.*/api/v1/', '')
                if ($script:FailOn -and $Uri -like "*$script:FailOn*") { throw 'download failed (test)' }
                if ($Uri -like '*/retrieval/embedding/update') { $script:Emb['RAG_EMBEDDING_ENGINE'] = $Body.RAG_EMBEDDING_ENGINE; $script:Emb['RAG_EMBEDDING_MODEL'] = $Body.RAG_EMBEDDING_MODEL }
                if ($Uri -like '*/retrieval/config/update') { foreach ($k in $Body.Keys) { $script:Rc[$k] = $Body[$k] } }
                return $true
            }
            if ($Uri -like '*/retrieval/embedding') { return [pscustomobject]$script:Emb }
            if ($Uri -like '*/retrieval/config') { return [pscustomobject]$script:Rc }
            return $null
        }
    } $Emb $Rc $FailOn
    $res = Set-LaiWebUIEmbedding -Token 't'
    return [pscustomobject]@{ Result = $res.Result; Warnings = @($res.Warnings); Posted = @(& $mod { $script:Posted }); Emb = (& $mod { $script:Emb }); Rc = (& $mod { $script:Rc }) }
}
$e1 = & $runEmb @{ RAG_EMBEDDING_ENGINE = ''; RAG_EMBEDDING_MODEL = 'sentence-transformers/all-MiniLM-L6-v2' } @{ RAG_RERANKING_MODEL = ''; ENABLE_RAG_HYBRID_SEARCH = $true }
Assert-That ($e1.Result -eq 'changed' -and $e1.Emb['RAG_EMBEDDING_MODEL'] -eq 'BAAI/bge-m3' -and $e1.Posted -contains 'knowledge/reindex' -and $e1.Rc['RAG_RERANKING_MODEL'] -eq 'BAAI/bge-reranker-v2-m3' -and $e1.Warnings.Count -eq 0) "Open WebUI's stock embedder is replaced, the collections re-indexed, the reranker set ($($e1.Posted -join ', '))"
$e2 = & $runEmb @{ RAG_EMBEDDING_ENGINE = 'ollama'; RAG_EMBEDDING_MODEL = 'nomic-embed-text:latest' } @{ RAG_RERANKING_MODEL = ''; ENABLE_RAG_HYBRID_SEARCH = $true }
Assert-That ($e2.Result -eq 'owner' -and $e2.Posted.Count -eq 0) 'an embedding engine the owner chose is left alone (nothing posted)'
$e3 = & $runEmb @{ RAG_EMBEDDING_ENGINE = ''; RAG_EMBEDDING_MODEL = 'intfloat/e5-large-v2' } @{ RAG_RERANKING_MODEL = ''; ENABLE_RAG_HYBRID_SEARCH = $true }
Assert-That ($e3.Result -eq 'owner' -and $e3.Posted.Count -eq 0) "another embedding model the owner picked is left alone"
$e4 = & $runEmb @{ RAG_EMBEDDING_ENGINE = ''; RAG_EMBEDDING_MODEL = 'BAAI/bge-m3' } @{ RAG_RERANKING_MODEL = 'my/reranker'; ENABLE_RAG_HYBRID_SEARCH = $true }
Assert-That ($e4.Result -eq 'unchanged' -and $e4.Posted.Count -eq 0 -and $e4.Rc['RAG_RERANKING_MODEL'] -eq 'my/reranker') 'already set up: nothing is downloaded again, and a reranker the owner chose stays'
$e5 = & $runEmb @{ RAG_EMBEDDING_ENGINE = ''; RAG_EMBEDDING_MODEL = 'sentence-transformers/all-MiniLM-L6-v2' } @{ RAG_RERANKING_MODEL = ''; ENABLE_RAG_HYBRID_SEARCH = $true } 'embedding/update'
Assert-That ($e5.Result -eq 'unchanged' -and $e5.Warnings.Count -eq 1 -and $e5.Warnings[0] -match 'keeps its old embedding model' -and $e5.Posted -notcontains 'knowledge/reindex') 'a failed download keeps the old model, warns, and does not re-index'
$e6 = & $runEmb @{ RAG_EMBEDDING_ENGINE = ''; RAG_EMBEDDING_MODEL = 'BAAI/bge-m3' } @{ RAG_RERANKING_MODEL = ''; ENABLE_RAG_HYBRID_SEARCH = $true } 'retrieval/config/update'
Assert-That ($e6.Warnings.Count -eq 1 -and $e6.Warnings[0] -match 'without its reranker') 'a reranker that cannot be set up is a warning'
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
$rw = Get-LaiRagWanted
Assert-That ($rw.CHUNK_SIZE -eq 1000 -and $rw.ENABLE_RAG_HYBRID_SEARCH -eq $true -and $rw.TOP_K -gt $rw.TOP_K_RERANKER) 'document search: whole 1,000-token chunks, hybrid search, more candidates than results'

Write-Host "`n=== presets: Think and image generation stay the user's; context overrides, vision and images are checked ===" -ForegroundColor Cyan
# Open WebUI 0.11.4 re-applies a preset's think over the per-chat Chat Controls switch, so the preset is
# the only place to turn Local Fast's reasoning on: a re-run must not switch it off again.
$fastEntry = @{ Preset = 'local-fast'; Alias = 'localai-fast'; Display = 'Local Fast'; Description = 'd'; Vision = $false; Think = $false; Trial = $false }
$fastForm = New-LaiPresetForm -Entry $fastEntry -NativeTools $true -SystemPrompt 'sys'
Assert-That ($fastForm.params['think'] -eq $false -and $fastForm.meta.capabilities['image_generation'] -eq $false) 'a new preset starts with Think = $false (catalog) and image generation off'
$userFast = [pscustomobject]@{ id = 'local-fast'; name = 'Local Fast'; base_model_id = 'localai-fast:latest'; params = [pscustomobject]@{ think = $true; system = 'old' }
    meta = [pscustomobject]@{ capabilities = [pscustomobject]@{ image_generation = $true; code_interpreter = $true }; builtinTools = [pscustomobject]@{ image_generation = $true; code_interpreter = $true } } }
$mFast = Merge-LaiPresetForm -Managed $fastForm -Existing $userFast
Assert-That ($mFast.params['think'] -eq $true -and $mFast.params['system'] -eq 'sys') "Think turned on in the preset survives a re-run (think=$($mFast.params['think'])), the system prompt is still refreshed"
Assert-That ($mFast.meta.capabilities['image_generation'] -eq $true -and $mFast.meta.builtinTools['image_generation'] -eq $true) 'image generation the user switched on (ComfyUI hookup) survives a re-run'
Assert-That ($mFast.meta.capabilities['code_interpreter'] -eq $false -and $mFast.meta.builtinTools['code_interpreter'] -eq $false) 'code execution is still forced off'
$resetFast = [pscustomobject]@{ id = 'local-fast'; name = 'Local Fast'; params = [pscustomobject]@{ think = $null }; meta = [pscustomobject]@{} }
$mReset = Merge-LaiPresetForm -Managed $fastForm -Existing $resetFast
Assert-That ($mReset.params['think'] -eq $false) 'a preset whose Think was set back to Default gets the catalog value again'
$catData = Import-PowerShellDataFile -Path (Join-Path (Join-Path $src 'config') 'models.psd1')
$promise = @($catData.Models | Where-Object { $_.Think -eq $false -and $_.Description -match '(?i)chat controls' -and $_.Description -notmatch '(?i)cannot' } | ForEach-Object { $_.Key })
Assert-That ($promise.Count -eq 0) "no catalog entry with Think = `$false promises a Chat Controls switch that the preset overrides ($($promise -join ', '))"
$readme = Get-Content -LiteralPath (Join-Path $src 'README.md') -Raw -Encoding UTF8
Assert-That ($readme -notmatch '(?i)turn it back on per chat|turn it on in Chat Controls') 'the README does not promise a per-chat Think switch'
# The measured speeds are for a nearly empty context; a row that quotes tok/s without saying so
# sends a normal long-chat slowdown to the VRAM-spilling fixes.
$header = ''; $inTable = $false; $speedRows = @()
foreach ($line in ($readme -split "`n")) {
    $isRow = $line -match '^\s*\|'
    if ($isRow -and -not $inTable) { $header = $line }
    $inTable = $isRow
    if ($isRow -and $line -match 'tok/s' -and ($line + ' ' + $header) -notmatch '(?i)short prompt|short chat|long chat') { $speedRows += $line.Trim() }
}
Assert-That ($speedRows.Count -eq 0) "every README table row with a tok/s figure says what chat length it applies to ($($speedRows -join ' || '))"
# Official releases next to the uncensored presets: listed first, opt-out-able, never fatal, and the
# default chat model once installed.
$offs = @($catData.Models | Where-Object { $_.Official })
$uncens = @($catData.Models | Where-Object { -not $_.Official -and -not $_.Trial })
Assert-That ($offs.Count -ge 3 -and @($offs | Where-Object { -not $_.Optional -or $_.Key -notlike 'official-*' -or $_.Source -match '/' }).Count -eq 0) "official entries are optional, keyed official-*, and pulled from the Ollama library itself (no community namespace): $(@($offs | ForEach-Object { $_.Source }) -join ', ')"
$maxOff = [int](@($offs | ForEach-Object { [int]$_.Order } | Sort-Object)[-1]); $minUnc = [int](@($uncens | ForEach-Object { [int]$_.Order } | Sort-Object)[0])
Assert-That ($maxOff -lt $minUnc) "official presets are listed before the uncensored ones (orders up to $maxOff vs from $minUnc)"
Assert-That (@($uncens | Where-Object { $_.Display -notlike 'Uncensored *' }).Count -eq 0) "the uncensored presets say so in their name: $(@($uncens | ForEach-Object { $_.Display }) -join ', ')"
Assert-That (@($catData.Models | Where-Object { $_.Preset -eq $catData.PreferredDefaultPreset -and $_.Official }).Count -eq 1) 'the preferred default preset is an official release from the catalog'
$catPath = Join-Path (Join-Path $src 'config') 'models.psd1'
$cWith = Get-LaiCatalog -Path $catPath -IncludeKeys @('main', 'fast', 'official-main')
$cWithout = Get-LaiCatalog -Path $catPath -IncludeKeys @('main', 'fast')
$cDefault = Get-LaiCatalog -Path $catPath
Assert-That ($cWith.DefaultPreset -eq 'official-main' -and $cWithout.DefaultPreset -eq 'local-main') "new chats start on Official Main once it is installed, on Uncensored Main otherwise ($($cWith.DefaultPreset) / $($cWithout.DefaultPreset))"
Assert-That (@($cDefault.Models | Where-Object { $_.Official -or $_.Trial }).Count -eq 0 -and $cDefault.DefaultPreset -eq 'local-main') 'without a selection the catalog holds no opt-in model (scripts reading an old install see what it has)'
Assert-That ($cWith.BaseDefaultPreset -eq 'local-main') 'the health check keeps testing memory, documents and search on the measured Uncensored Main'

$need = @('Test-LaiPresetVision', 'Test-LaiWebUIVision', 'Get-LaiContextOverride', 'Get-LaiRagWanted')
$missingFn = @($need | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
Assert-That ($missingFn.Count -eq 0) "the module has the vision, image and context-override checks ($($missingFn -join ', ') missing)"
$tlText = Get-Content -LiteralPath (Join-Path $src 'Test-LocalAI.ps1') -Raw -Encoding UTF8
Assert-That (@($need | Where-Object { $tlText -notmatch $_ }).Count -eq 0) 'Test-LocalAI uses all four (image read for Vision presets, preset vision against Ollama, context overrides, every installer RAG setting)'
# A rollback hint must say which model: typed bare, Update-Models.ps1 -Rollback stops with "Missing an
# argument for parameter 'Rollback'" (a catalog key, 'all', or a placeholder the code fills in).
$rbKeys = @($catData.Models | ForEach-Object { $_.Key }) + @('all')
$rbBad = @()
$rbFiles = @(Get-ChildItem -LiteralPath $src -File | Where-Object { $_.Extension -in '.ps1', '.md' -and $_.Name -ne 'IMPROVEMENTS.md' }) + @(Get-Item -LiteralPath (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1'))
foreach ($f in $rbFiles) {
    foreach ($rm in [regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8), 'Update-Models\.ps1 -Rollback(?::|[ \t]+)?([^\s,;)`|]*)')) {
        $rv = $rm.Groups[1].Value
        if (-not ($rbKeys -contains $rv -or $rv -match '^(\$|\{\d+\}|<)')) { $rbBad += "$($f.Name): $($rm.Value)" }
    }
}
Assert-That ($rbBad.Count -eq 0) "every Update-Models.ps1 -Rollback hint names the model to roll back ($($rbBad -join ' | '))"
if ($missingFn.Count -eq 0) {
    Assert-That ((Test-LaiPresetVision -PresetVision $true -Capabilities @('completion', 'tools')) -eq 'missing') 'a preset that accepts images for a model without vision is found'
    Assert-That ((Test-LaiPresetVision -PresetVision $false -Capabilities @('completion', 'vision')) -eq 'unused') 'a model that reads images behind a preset that refuses them is found'
    Assert-That ((Test-LaiPresetVision -PresetVision $true -Capabilities @('vision')) -eq 'ok' -and (Test-LaiPresetVision -PresetVision $false -Capabilities @()) -eq 'ok') 'matching vision settings are ok'
    $mod = Get-Module LocalAI
    & $mod {
        $script:Planted = $true; $script:LastBody = $null; $script:VisionAnswer = ''
        function script:Invoke-LaiApi { param($Method, $Uri, $Body, $Token, $TimeoutSec) $null = $Method, $Token, $TimeoutSec
            if ($Uri -like '*/api/chat/completions') {
                $script:LastBody = $Body
                return [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = $script:VisionAnswer } }) }
            }
            if (-not $script:Planted) {
                if ($Uri -like '*/api/v1/models/model*') { return [pscustomobject]@{ name = 'Local Main'; params = [pscustomobject]@{ temperature = 0.3 } } }
                return [pscustomobject]@{ ui = [pscustomobject]@{ params = [pscustomobject]@{ temperature = 0.5 } } }
            }
            if ($Uri -like '*/api/v1/users/user/settings') { return [pscustomobject]@{ ui = [pscustomobject]@{ params = [pscustomobject]@{ num_ctx = 8192 } } } }
            if ($Uri -like '*/api/v1/configs/models') { return [pscustomobject]@{ DEFAULT_MODELS = 'local-main'; DEFAULT_MODEL_PARAMS = [pscustomobject]@{ custom_params = [pscustomobject]@{ num_ctx = '16384' } } } }
            if ($Uri -like '*id=local-main') { return [pscustomobject]@{ name = 'Local Main'; params = [pscustomobject]@{ num_batch = 256; temperature = 0.3 } } }
            if ($Uri -like '*id=local-fast') { return [pscustomobject]@{ name = 'Local Fast'; params = [pscustomobject]@{ num_ctx = $null } } }
            throw "unexpected call $Uri" }
    }
    $over = @(Get-LaiContextOverride -Token 't' -PresetIds @('local-main', 'local-fast'))
    Assert-That ($over.Count -eq 3 -and $over[0] -match 'Settings > General.*num_ctx 8192' -and $over[1] -match 'default parameters.*num_ctx 16384' -and $over[2] -match 'Local Main.*num_batch 256') "num_ctx/num_batch in the user's settings, the default parameters (custom) and a preset are each named ($($over -join ' | '))"
    & $mod { $script:Planted = $false }
    $over = @(Get-LaiContextOverride -Token 't' -PresetIds @('local-main'))
    Assert-That ($over.Count -eq 0) "no override in a clean Open WebUI ($($over -join ' | '))"
    # The image check: the request has the browser's shape, and each embedded test image really is
    # the colour the check asks for (decoded here: PNG chunks, zlib, first pixel).
    foreach ($colour in 'red', 'green', 'blue') {
        & $mod { param($c) $script:VisionAnswer = "It is $c." } $colour
        $v = Test-LaiWebUIVision -Token 't' -Model 'local-vision' -Colour $colour
        $sentBody = & $mod { $script:LastBody }
        $parts = @($sentBody['messages'][0]['content'])
        $url = ''; $shapeOk = $false
        try {
            if ($parts.Count -eq 2 -and $parts[0] -is [hashtable] -and $parts[1] -is [hashtable] -and $parts[1]['image_url']) { $url = [string]$parts[1]['image_url']['url'] }
            $shapeOk = $parts[0]['type'] -eq 'text' -and $parts[1]['type'] -eq 'image_url' -and $url.StartsWith('data:image/png;base64,')
        } catch { $shapeOk = $false }
        Assert-That ($v.Passed -and $shapeOk) "the $colour test image is sent as a text part plus an image_url data URI, and a correct answer passes"
        $rgb = @(); $sigOk = $false
        try {
            $png = [Convert]::FromBase64String($url.Substring('data:image/png;base64,'.Length))
            $sigOk = ($png.Length -gt 8 -and $png[0] -eq 0x89 -and $png[1] -eq 0x50 -and $png[2] -eq 0x4E -and $png[3] -eq 0x47)
            $pos = 8; $idat = $null
            while ($pos + 8 -le $png.Length) {
                $len = ([int]$png[$pos] -shl 24) -bor ([int]$png[$pos + 1] -shl 16) -bor ([int]$png[$pos + 2] -shl 8) -bor [int]$png[$pos + 3]
                $type = [System.Text.Encoding]::ASCII.GetString($png, $pos + 4, 4)
                if ($type -eq 'IDAT') { $idat = New-Object byte[] $len; [Array]::Copy($png, $pos + 8, $idat, 0, $len) }
                $pos += 12 + $len
            }
            $ms = New-Object System.IO.MemoryStream -ArgumentList (, $idat)
            $ms.Position = 2   # zlib header
            $ds = New-Object System.IO.Compression.DeflateStream -ArgumentList $ms, ([System.IO.Compression.CompressionMode]::Decompress)
            $px = New-Object byte[] 4; $got = 0
            while ($got -lt 4) { $n = $ds.Read($px, $got, 4 - $got); if ($n -le 0) { break }; $got += $n }
            $ds.Dispose()
            $rgb = @([int]$px[1], [int]$px[2], [int]$px[3])
        } catch { Write-Host "  (PNG decode failed: $($_.Exception.Message))" }
        $want = @{ red = 0; green = 1; blue = 2 }[$colour]
        $isColour = $rgb.Count -eq 3 -and @(0, 1, 2 | Where-Object { $_ -ne $want -and $rgb[$_] -ge $rgb[$want] }).Count -eq 0 -and $rgb[$want] -ge 128
        Assert-That ($sigOk -and $isColour) "the embedded $colour test image is a valid PNG of that colour (first pixel RGB $($rgb -join ','))"
    }
    & $mod { $script:VisionAnswer = 'I cannot see any image in your message.' }
    $v = Test-LaiWebUIVision -Token 't' -Model 'local-vision'
    Assert-That (-not $v.Passed -and @('red', 'green', 'blue') -contains $v.Expected) "an answer without the colour fails the check (expected $($v.Expected))"
}
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
# A moved endpoint: Open WebUI answers any unknown path with its web page (status 200).
$htmlPort = Get-Random -Minimum 41000 -Maximum 49000
$hl = New-Object System.Net.HttpListener
$hl.Prefixes.Add("http://127.0.0.1:$htmlPort/")
$hl.Start()
$hAsync = $hl.BeginGetContext($null, $null)
$hClient = Join-Path $Work 'html-client.ps1'; $hOut = Join-Path $Work 'html-out.txt'
Set-Content -LiteralPath $hClient -Value (("Import-Module '{0}' -Force`n" -f (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1')) +
    ("`$m = try {{ Invoke-LaiApi -Uri 'http://127.0.0.1:{0}/api/v1/auths/admin/config' -TimeoutSec 20 | Out-Null; 'NO ERROR' }} catch {{ `$_.Exception.Message }}`n`$m | Set-Content -LiteralPath '{1}'" -f $htmlPort, $hOut))
$hsp = @{ FilePath = $childExe; ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hClient); PassThru = $true }
if ($onWindows) { $hsp['WindowStyle'] = 'Hidden' }
$hProc = Start-Process @hsp
if ($hAsync.AsyncWaitHandle.WaitOne(30000)) {
    $hctx = $hl.EndGetContext($hAsync)
    $page = [System.Text.Encoding]::UTF8.GetBytes('<!doctype html><html><body>Open WebUI</body></html>')
    $hctx.Response.ContentType = 'text/html'
    $hctx.Response.OutputStream.Write($page, 0, $page.Length)
    $hctx.Response.Close()
}
[void]$hProc.WaitForExit(30000)
$hl.Stop()
$hText = ''; if (Test-Path -LiteralPath $hOut) { $hText = Get-Content -LiteralPath $hOut -Raw }
Assert-That ($hText -match 'returned a web page instead of data') "an API path answered with Open WebUI's web page is an error, not data ($hText)"

Write-Host "`n=== watch dates are read the same in every culture ===" -ForegroundColor Cyan
# PowerShell 7's ConvertFrom-Json already returns dates; 5.1 leaves strings, so this path is 5.1's.
$wAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Watch-LocalAI.ps1'), [ref]$null, [ref]$null)
. ([scriptblock]::Create($wAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-WatchDate' }, $true).Extent.Text))
$savedCulture = [System.Globalization.CultureInfo]::CurrentCulture
foreach ($c in 'de-DE', 'tr-TR', 'ja-JP') {
    [System.Globalization.CultureInfo]::CurrentCulture = $c
    $d = ConvertTo-WatchDate '2026-10-05T13:45:00'
    Assert-That ($d -and $d.Month -eq 10 -and $d.Day -eq 5 -and $d.Hour -eq 13) "an ISO date from the state file reads the same under $c"
}
[System.Globalization.CultureInfo]::CurrentCulture = $savedCulture
Assert-That ($null -eq (ConvertTo-WatchDate 'not a date') -and $null -eq (ConvertTo-WatchDate '')) 'a damaged value reads as no date (no crash)'

Write-Host "`n=== Remove-LaiTree never follows a junction / symbolic link ===" -ForegroundColor Cyan
# The elevated installer and uninstaller delete trees in C:\AI, which the user controls. A link planted
# there must be removed as a link: what it points at (here a 'victim' folder outside) stays.
$victim = Join-Path $Work 'victim'; $tree = Join-Path $Work 'tree-to-delete'
foreach ($d in $victim, (Join-Path $tree 'a/b')) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
Set-Content -LiteralPath (Join-Path $victim 'important.txt') -Value 'keep'
Set-Content -LiteralPath (Join-Path $tree 'a/b/f.txt') -Value 'x'
$linkMade = $false
if ($onWindows) {
    # A directory junction needs no admin rights: exactly what a standard-user process can plant.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & cmd.exe /c mklink /J (Join-Path $tree 'a\junction') $victim 2>&1 | Out-Null
    $ErrorActionPreference = $prev
    $linkMade = Test-Path -LiteralPath (Join-Path $tree 'a\junction\important.txt')
} else {
    & ln -s $victim (Join-Path $tree 'a/dirlink'); & ln -s (Join-Path $victim 'important.txt') (Join-Path $tree 'filelink')
    $linkMade = Test-Path -LiteralPath (Join-Path $tree 'a/dirlink/important.txt')
}
Assert-That $linkMade 'setup: a link inside the tree reaches the victim folder'
Set-Content -LiteralPath (Join-Path $tree 'a/readonly.txt') -Value 'ro'
(Get-Item -LiteralPath (Join-Path $tree 'a/readonly.txt')).Attributes = 'ReadOnly'
Remove-LaiTree -Path $tree
Assert-That (-not (Test-Path -LiteralPath $tree)) 'the tree is gone (a read-only file in it included)'
Assert-That ((Test-Path -LiteralPath (Join-Path $victim 'important.txt')) -and (Get-Content -LiteralPath (Join-Path $victim 'important.txt')) -eq 'keep') 'what the link pointed at is untouched'
# The path itself a link (a whole folder in C:\AI swapped for one): only the link goes.
$rootLink = Join-Path $Work 'root-link'
if ($onWindows) { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; & cmd.exe /c mklink /J $rootLink $victim 2>&1 | Out-Null; $ErrorActionPreference = $prev } else { & ln -s $victim $rootLink }
Remove-LaiTree -Path $rootLink
Assert-That (-not (Test-Path -LiteralPath $rootLink) -and (Test-Path -LiteralPath (Join-Path $victim 'important.txt'))) 'a link given as the folder to delete: the link goes, its target stays'

Write-Host "`n=== permission changes and installer folders refuse links ===" -ForegroundColor Cyan
$lroot = Join-Path $Work 'linkroot'; $outside = Join-Path $Work 'outside-target'
foreach ($d in $lroot, $outside) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$linkPath = Join-Path $lroot 'Secrets'
if ($onWindows) { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; & cmd.exe /c mklink /J $linkPath $outside 2>&1 | Out-Null; $ErrorActionPreference = $prev }
else { & ln -s $outside $linkPath }
Assert-That ((Get-LaiReparsePath -Path (Join-Path $linkPath 'openwebui-admin.json')) -eq $linkPath) 'a link anywhere above a path is found'
Assert-That ($null -eq (Get-LaiReparsePath -Path (Join-Path $lroot 'plain/file.txt'))) 'a normal path has none'
$refused = $false
try { Set-LaiPrivateAcl -Path $linkPath -UserSid 'S-1-5-21-1-2-3-1001' | Out-Null } catch { $refused = $_.Exception.Message -match 'through a link' }
Assert-That $refused 'Set-LaiPrivateAcl refuses to change permissions through a link (icacls would change the target)'

Write-Host "`n=== docker template from the installer reaches docker intact (Windows PowerShell 5.1) ===" -ForegroundColor Cyan
if ($onWindows) {
    # 5.1 leaves inner double quotes unescaped in native arguments; a docker.cmd stand-in records the
    # raw command line it got for the installer's own legacy-container template (taken from its source).
    $instAst2 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Install-LocalAI.ps1'), [ref]$null, [ref]$null)
    $nativeDef = $instAst2.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Native' }, $true)
    . ([scriptblock]::Create($nativeDef.Extent.Text))
    $tpl = @($instAst2.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like '{{.ID}}|{{.Label*' }, $true))[0].Value
    Assert-That ($tpl -match '\{\{\.Label') "setup: the installer's legacy-container template was found ($tpl)"
    $shimDir = Join-Path $Work 'dockershim'
    New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
    $rawFile = Join-Path $shimDir 'args.txt'
    Set-Content -LiteralPath (Join-Path $shimDir 'docker.cmd') -Encoding ASCII -Value ("@echo off`r`n>`"$rawFile`" echo %*")
    $savedPath = $env:Path; $env:Path = "$shimDir;$env:Path"
    try { Invoke-Native -File 'docker' -Arguments @('ps', '-a', '--format', $tpl) -Capture -AllowFail | Out-Null } finally { $env:Path = $savedPath }
    $raw = ''; if (Test-Path -LiteralPath $rawFile) { $raw = (Get-Content -LiteralPath $rawFile -Raw).Trim() }
    Assert-That ($raw.Contains($tpl)) "docker receives the template unchanged ($raw)"
} else { Skip 'native argument check runs on Windows only' }

Write-Host "`n=== docker output with a non-ASCII path is decoded as UTF-8 (Windows PowerShell 5.1) ===" -ForegroundColor Cyan
if ($onWindows) {
    # docker writes UTF-8; 5.1 decodes captured output with the console code page unless told otherwise.
    $utfDir = Join-Path $Work 'docker-utf8'
    New-Item -ItemType Directory -Force -Path $utfDir | Out-Null
    $jose = 'C:\Users\Jos' + [char]0x00E9 + '\owui'
    [System.IO.File]::WriteAllText((Join-Path $utfDir 'out.txt'), "bind||$jose|/app/backend/data`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Set-Content -LiteralPath (Join-Path $utfDir 'docker.cmd') -Encoding ASCII -Value ("@echo off`r`ntype `"" + (Join-Path $utfDir 'out.txt') + "`"")
    $encBefore = [Console]::OutputEncoding.CodePage
    $savedPath = $env:Path; $env:Path = "$utfDir;$env:Path"
    try { $res = Invoke-Native -File 'docker' -Arguments @('inspect') -Capture -AllowFail } finally { $env:Path = $savedPath }
    Assert-That ($res.Text -match [regex]::Escape($jose)) "a path with an accent comes back intact ($($res.Text))"
    Assert-That ([Console]::OutputEncoding.CodePage -eq $encBefore) 'the console encoding is restored afterwards'
} else { Skip 'console code pages exist on Windows only' }

# Keep-awake for long installs: takes on Windows (Windows CI), a no-op elsewhere.
if ($env:OS -eq 'Windows_NT') { Assert-That (Enable-LaiKeepAwake) 'Windows does not sleep while the installer runs (SetThreadExecutionState took)' }
else { Assert-That (-not (Enable-LaiKeepAwake)) 'keep-awake is a no-op off Windows' }
Write-Host "`n=== other hardware: GPU size, several GPUs, no NVIDIA GPU, RAM ===" -ForegroundColor Cyan
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
# The owner's card must keep passing: every model of the real catalog fits a 24 GB RTX 3090.
$realCatalog = Get-LaiCatalog -Path (Join-Path (Join-Path $src 'config') 'models.psd1') -IncludeTrials
foreach ($cm in $realCatalog.Models) {
    Assert-That (Test-LaiModelFitsVram -DownloadGB $cm.DownloadGB -TotalMiB 24576) "$($cm.Display) ($($cm.DownloadGB) GB) fits a 24 GB card"
}
$mainGB = @($realCatalog.Models | Where-Object { $_.Key -eq 'main' })[0].DownloadGB
$fastGB = @($realCatalog.Models | Where-Object { $_.Key -eq 'fast' })[0].DownloadGB
Assert-That (-not (Test-LaiModelFitsVram -DownloadGB $mainGB -TotalMiB 16376)) 'Uncensored Main does not fit a 16 GB RTX 4080 (refused before its download)'
Assert-That (Test-LaiModelFitsVram -DownloadGB $fastGB -TotalMiB 16376) 'Uncensored Fast fits a 16 GB card'
Assert-That (-not (Test-LaiModelFitsVram -DownloadGB $fastGB -TotalMiB 8192)) 'Uncensored Fast does not fit an 8 GB card'
# Two GPUs: nvidia-smi lists them in PCI order, often the small display card first. A stand-in
# nvidia-smi inside the module: an alias (Get-Command finds it before any real one) for a function
# with an approved verb, so PSScriptAnalyzer's PSUseApprovedVerbs stays quiet.
$smiLines = @('NVIDIA GeForce RTX 3060, 617.14, 12288, 3900, 8388', 'NVIDIA GeForce RTX 3090, 617.14, 24576, 300, 24276')
$mod = Get-Module LocalAI
& $mod { function script:Get-FakeNvidiaSmiOutput { $script:LASTEXITCODE = $script:FakeSmiCode; $script:FakeSmi }; Set-Alias -Name nvidia-smi -Value Get-FakeNvidiaSmiOutput -Scope Script }
foreach ($order in @(@(0, 1), @(1, 0))) {
    $twoCards = @($smiLines[$order[0]], $smiLines[$order[1]])
    & $mod { param($Lines) $script:FakeSmi = $Lines; $script:FakeSmiCode = 0 } $twoCards
    $g2 = Get-LaiGpuInfo
    Assert-That ($g2 -and $g2.Name -eq 'NVIDIA GeForce RTX 3090' -and $g2.TotalMiB -eq 24576 -and $g2.Count -eq 2 -and @($g2.All).Count -eq 2) "two GPUs ($($twoCards[0].Split(',')[0]) listed first): the 24 GB card is the one measured ($($g2.Name), count $($g2.Count))"
    $idle = $null
    try { $idle = Wait-LaiGpuIdle -MaxUsedMiB 3500 -TimeoutSec 0 -PollSec 0 } catch { $idle = $null }
    Assert-That ($idle -and $idle.UsedMiB -eq 300) 'a busy display card does not make the GPU-idle wait time out'
}
& $mod { $script:FakeSmi = @('No devices were found'); $script:FakeSmiCode = 6 }
Assert-That ($null -eq (Get-LaiGpuInfo)) "nvidia-smi without a GPU ('No devices were found', exit 6) reads as no GPU"
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force
$msg = Get-LaiNoNvidiaMessage -VideoControllers @('AMD Radeon RX 7900 XTX', 'Microsoft Basic Display Adapter') -Architecture 'AMD64'
Assert-That ($msg -match 'AMD Radeon RX 7900 XTX' -and $msg -match '24 GB' -and $msg -notmatch 'nvidia\.com/Download') "an AMD card is named, not blamed on a broken NVIDIA driver ($msg)"
$msg = Get-LaiNoNvidiaMessage -VideoControllers @('Qualcomm(R) Adreno(TM) X1-85 GPU') -Architecture 'ARM64'
Assert-That ($msg -match 'ARM' -and $msg -notmatch 'nvidia\.com/Download') "an ARM64 PC is told so ($msg)"
$msg = Get-LaiNoNvidiaMessage -VideoControllers @('NVIDIA GeForce RTX 3090') -Architecture 'AMD64'
Assert-That ($msg -match 'nvidia\.com/Download' -and $msg -match 'RTX 3090') 'an NVIDIA card Windows lists but nvidia-smi does not: the driver advice stays'
Assert-That ((Get-LaiVirtualizationHint -Manufacturer 'GenuineIntel') -match 'VT-x' -and (Get-LaiVirtualizationHint -Manufacturer 'GenuineIntel') -notmatch 'SVM') 'an Intel PC is told to enable VT-x, not SVM Mode'
Assert-That ((Get-LaiVirtualizationHint -Manufacturer 'AuthenticAMD') -match 'SVM') 'an AMD PC is told to enable SVM Mode'
foreach ($c in @(@{ Ram = 8; Want = $null }, @{ Ram = 16; Want = $null }, @{ Ram = 24; Want = $null }, @{ Ram = 32; Want = $null }, @{ Ram = 48; Want = 16 }, @{ Ram = 64; Want = 16 })) {
    $cap = Get-LaiWslMemoryCapGB -TotalGB $c.Ram
    Assert-That ($cap -eq $c.Want) "WSL memory cap for $($c.Ram) GB of RAM: $(if ($null -eq $cap) { 'WSL default (half)' } else { "$cap GB" }) (never above WSL's own default of half the RAM)"
}
Assert-That (-not (Test-LaiCpuFallbackFits -DownloadGB $mainGB -RamGB 16) -and (Test-LaiCpuFallbackFits -DownloadGB $mainGB -RamGB 64)) 'the render guard CPU mode: Local Main does not fit 16 GB of RAM, fits 64 GB'

Write-Host "`n=== the nightly model re-check: is the GPU free? ===" -ForegroundColor Cyan
# Update-Models.ps1 -Scheduled skips instead of waiting while another program uses the GPU. Mocks
# inside the module: the CUDA programs nvidia-smi lists, and the VRAM in use.
$mod = Get-Module LocalAI
& $mod {
    $script:MockApps = @(); $script:MockUsed = 500
    function script:Get-LaiGpuApps { @($script:MockApps) }
    function script:Get-LaiGpuInfo { [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 3090'; DriverVersion = '1.0'; TotalMiB = 24576; UsedMiB = $script:MockUsed; FreeMiB = 24576 - $script:MockUsed } }
}
$setGpu = { param($Apps, $Used) & $mod { param($a, $u) $script:MockApps = @($a); $script:MockUsed = $u } $Apps $Used }
& $setGpu @('ollama.exe', 'ollama app.exe', 'llama-server.exe', 'ollama_llama_server.exe') 900
$busy = Get-LaiGpuBusyReason -MaxUsedMiB 3500
Assert-That ($busy -eq '') "Ollama's own processes (ollama*.exe, llama-server.exe) do not make the GPU busy ('$busy')"
& $setGpu @('ollama.exe', 'python.exe') 900
$busy = Get-LaiGpuBusyReason
Assert-That ($busy -match 'python\.exe' -and $busy -notmatch 'ollama') "another CUDA program (ComfyUI's python.exe) is named, Ollama is not ($busy)"
& $setGpu @() 9000
$busy = Get-LaiGpuBusyReason -MaxUsedMiB 3500
Assert-That ((Get-LaiGpuBusyReason) -eq '' -and $busy -match '9000 MiB') "VRAM in use counts only with -MaxUsedMiB: before the unload Ollama's own models fill it ($busy)"
& $setGpu @() 900
$env:LOCALAI_TEST_GPU_BUSY = 'after-load'
try { Assert-That ((Get-LaiGpuBusyReason -MaxUsedMiB 3500) -eq '' -and (Get-LaiGpuBusyReason -MaxUsedMiB 3500 -AfterLoad) -ne '') "test hook 'after-load': busy only once a model was measured" } finally { $env:LOCALAI_TEST_GPU_BUSY = '' }
$env:LOCALAI_TEST_GPU_BUSY = 'GPU in use by Game.exe'
try { Assert-That ((Get-LaiGpuBusyReason) -eq 'GPU in use by Game.exe') 'test hook: any other value is the reason reported' } finally { $env:LOCALAI_TEST_GPU_BUSY = '' }
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force

Write-Host "`n=== the Ollama app's own settings (server.log) ===" -ForegroundColor Cyan
# A real Ollama 0.35.1 'server config' line (slog doubles the backslashes); the path has a space and an apostrophe.
$cfgLine = 'time=2026-10-04T23:07:51.129Z level=INFO source=routes.go:2117 msg="server config" env="map[CUDA_VISIBLE_DEVICES: HTTPS_PROXY: OLLAMA_FLASH_ATTENTION:true OLLAMA_GPU_OVERHEAD:536870912 OLLAMA_HOST:http://127.0.0.1:11434 OLLAMA_IGPU_ENABLE:false OLLAMA_KV_CACHE_TYPE:q8_0 OLLAMA_MODELS:C:\\Users\\Jo O''Neil\\.ollama\\models OLLAMA_NOHISTORY:false OLLAMA_ORIGINS:[http://localhost https://localhost app://*] OLLAMA_REMOTES:[ollama.com] no_proxy:]"'
$live = Get-LaiOllamaServerConfig -Line $cfgLine
Assert-That ($live -and $live['Models'] -eq "C:\Users\Jo O'Neil\.ollama\models" -and $live['Host'] -eq 'http://127.0.0.1:11434' -and $live['HostIsLoopback']) "server config line: model folder and host read back ($($live['Models']) / $($live['Host']))"
$live = Get-LaiOllamaServerConfig -Line ($cfgLine -replace '127\.0\.0\.1:11434', '0.0.0.0:11434')
Assert-That ($live -and -not $live['HostIsLoopback']) "the app's 'Expose Ollama to the network' (0.0.0.0) is seen"
Assert-That ($null -eq (Get-LaiOllamaServerConfig -Line 'time=x level=INFO msg="inference compute"')) 'another log line is not a config'
Assert-That ((Test-LaiSamePath 'C:\Users\a\.ollama\models\' 'c:/users/A/.ollama/models') -and -not (Test-LaiSamePath 'C:\x' 'D:\x')) 'folders compare without case, slash direction or a trailing separator'
# Ollama writes server.log as UTF-8 without a BOM and keeps a printable accent as is; Windows
# PowerShell 5.1's Select-String would read it as ANSI and see a different (garbled) folder.
$joseModels = 'C:\Users\Jos' + [char]0x00E9 + '\.ollama\models'
$logDir = Join-Path $Work 'ollama-log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'server.log'
$joseLine = $cfgLine.Replace("OLLAMA_MODELS:C:\\Users\\Jo O'Neil\\.ollama\\models", 'OLLAMA_MODELS:' + $joseModels.Replace('\', '\\'))
[System.IO.File]::WriteAllText($logFile, ("time=x level=INFO msg=`"inference compute`"`n" + $joseLine + "`n"), (New-Object System.Text.UTF8Encoding($false)))
$live = Get-LaiOllamaLiveConfig -LogPath $logFile
Assert-That ($joseLine -ne $cfgLine -and $live -and $live['Models'] -eq $joseModels) "server.log read as UTF-8: a user folder with an accent comes back unchanged ($(if ($live) { $live['Models'] }))"
Assert-That ($null -eq (Get-LaiOllamaLiveConfig -LogPath (Join-Path $logDir 'missing.log'))) 'no server.log yet: no config'

Write-Host "`n=== Ollama / Docker Desktop installed to a custom folder ===" -ForegroundColor Cyan
$lad = Join-Path $Work 'lad'; $customOllama = Join-Path $Work 'D-Ollama'
foreach ($d in @((Join-Path $lad 'Programs/Ollama'), $customOllama)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
Set-Content -LiteralPath (Join-Path $customOllama 'ollama app.exe') -Value 'x'
$mod = Get-Module LocalAI
# Inno Setup records the folder chosen with OllamaSetup.exe /DIR=... under Ollama's fixed AppId.
# No real Ollama app or docker CLI may leak in: on the owner's PC Ollama runs and Docker Desktop's
# docker.exe is on PATH, which the locators also look at.
& $mod { function script:Get-Process { param($Name, $ErrorAction) $null = $Name, $ErrorAction }; function script:Get-Command { param($Name, $CommandType, $ErrorAction) $null = $Name, $CommandType, $ErrorAction } }
& $mod { param($c) $script:FakeLoc = $c; function script:Get-ItemProperty { param($Path) if ([string]$Path -like '*44E83376-CE68-45EB-8FC1-393500EB558C*' -or [string]$Path -like '*Uninstall\Docker Desktop') { return [pscustomobject]@{ InstallLocation = $script:FakeLoc } }; throw 'no such key' } } ($customOllama + [System.IO.Path]::DirectorySeparatorChar)
Assert-That ((Find-LaiOllamaDir -LocalAppData $lad) -eq $customOllama) 'Ollama in its registered custom folder is found (no reinstall over it)'
Remove-Item -LiteralPath (Join-Path $customOllama 'ollama app.exe')
Assert-That ($null -eq (Find-LaiOllamaDir -LocalAppData $lad)) 'a registration whose folder has no app, and no app in the default folder: not installed'
Assert-That ((Find-LaiOllamaDir -LocalAppData $lad -OrDefault) -eq (Join-Path $lad 'Programs\Ollama')) '-OrDefault gives the default folder to install into'
Set-Content -LiteralPath (Join-Path (Join-Path $lad 'Programs/Ollama') 'ollama app.exe') -Value 'x'
Assert-That ((Find-LaiOllamaDir -LocalAppData $lad) -eq (Join-Path $lad 'Programs\Ollama')) 'the default folder is used when the registered one is empty'
Set-Content -LiteralPath (Join-Path $customOllama 'Docker Desktop.exe') -Value 'x'
$fakePf = Join-Path $Work 'pf'
Assert-That ((Find-LaiDockerDesktopExe -ProgramFiles $fakePf) -eq (Join-Path $customOllama 'Docker Desktop.exe')) 'Docker Desktop in its registered install folder is found'
& $mod { function script:Get-ItemProperty { param($Path) $null = $Path; throw 'no such key' } }
Assert-That ($null -eq (Find-LaiDockerDesktopExe -ProgramFiles $fakePf) -and (Find-LaiDockerDesktopExe -ProgramFiles $fakePf -OrDefault) -eq (Join-Path $fakePf 'Docker\Docker\Docker Desktop.exe')) 'not installed: $null, or the default path with -OrDefault'
# No registration, but the docker CLI on PATH sits in <install folder>\resources\bin.
& $mod { param($c) $script:FakeCli = $c; function script:Get-Command { param($Name, $CommandType, $ErrorAction) $null = $CommandType, $ErrorAction; if ($Name -eq 'docker') { [pscustomobject]@{ Source = $script:FakeCli } } } } (Join-Path (Join-Path (Join-Path $customOllama 'resources') 'bin') 'docker.exe')
Assert-That ((Find-LaiDockerDesktopExe -ProgramFiles $fakePf) -eq (Join-Path $customOllama 'Docker Desktop.exe')) 'Docker Desktop found from the docker CLI on PATH (three folders up)'
Import-Module (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Force

Write-Host "`n=== the user's own OLLAMA_* values are recorded and put back ===" -ForegroundColor Cyan
# First install (the Ollama stage never completed): every variable is recorded as it was, '' = unset.
$savedEnv = @{}
Assert-That (Add-LaiPrevEnv -Saved $savedEnv -Name 'OLLAMA_NUM_PARALLEL' -Current '4') "a user's own OLLAMA_NUM_PARALLEL=4 is recorded before the installer sets 1"
Assert-That (-not (Add-LaiPrevEnv -Saved $savedEnv -Name 'OLLAMA_NUM_PARALLEL' -Current '1')) "a resumed run does not record the installer's own value over it"
Assert-That ((Add-LaiPrevEnv -Saved $savedEnv -Name 'OLLAMA_KEEP_ALIVE' -Current '') -and (Add-LaiPrevEnv -Saved $savedEnv -Name 'OLLAMA_FLASH_ATTENTION' -Current '1')) 'an unset variable and one already equal to the installer value are recorded too'
$plan = @(Get-LaiEnvResetPlan -Names @('OLLAMA_NUM_PARALLEL', 'OLLAMA_KEEP_ALIVE', 'OLLAMA_FLASH_ATTENTION') -Saved $savedEnv)
Assert-That ($plan.Count -eq 3 -and $plan[0].Value -eq '4' -and $null -eq $plan[1].Value -and $plan[2].Value -eq '1') "-ResetOllamaSettings puts back 4, removes OLLAMA_KEEP_ALIVE, keeps the user's own OLLAMA_FLASH_ATTENTION=1 ($(($plan | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))"
# A later run (README: re-run with -KeepAlive 5m), and every install from before this record: the
# current values are the installer's own, so nothing is recorded and the reset removes them.
$savedLater = @{}
Assert-That (-not (Add-LaiPrevEnv -Saved $savedLater -Name 'OLLAMA_KEEP_ALIVE' -Current '15m' -InstallerSetBefore) -and $savedLater.Count -eq 0) "after the first install, the installer's own OLLAMA_KEEP_ALIVE=15m is not recorded as the user's"
$plan = @(Get-LaiEnvResetPlan -Names @('OLLAMA_KEEP_ALIVE') -Saved $savedLater)
Assert-That ($plan.Count -eq 1 -and $null -eq $plan[0].Value) '-ResetOllamaSettings then removes OLLAMA_KEEP_ALIVE instead of setting 15m again'
$instText = Get-Content -LiteralPath (Join-Path $src 'Install-LocalAI.ps1') -Raw -Encoding UTF8
Assert-That ($instText -match "-InstallerSetBefore:\(\[bool\]\`$State\.stages\['Ollama'\]\)") 'the installer records only before its Ollama stage first completed'
$ustText = Get-Content -LiteralPath (Join-Path $src 'Uninstall-LocalAI.ps1') -Raw -Encoding UTF8
Assert-That ($ustText -match 'Get-LaiEnvResetPlan' -and $ustText -match 'prevOllamaEnv') 'Uninstall-LocalAI.ps1 restores from the recorded values instead of only deleting'

Write-Host "`n=== installer port choice: a port Docker holds for another project is not this stack's ===" -ForegroundColor Cyan
$instAst4 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Install-LocalAI.ps1'), [ref]$null, [ref]$null)
$sfpDef = $instAst4.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Select-FreePort' }, $true)
$portCases = @(
    @{ Ps = @('grafana|monitoring'); Code = 0; Want = 3001; What = "another project's container" }
    @{ Ps = @(); Code = 0; Want = 3001; What = 'a Docker/WSL listener with no container' }
    @{ Ps = @('open-webui|localai'); Code = 0; Want = 3000; What = "this stack's own container" }
    @{ Ps = @(); Code = 1; Want = 3000; What = 'a docker CLI that does not answer (kept, as before)' }
)
foreach ($pc in $portCases) {
    $gotPort = & {
        . ([scriptblock]::Create($sfpDef.Extent.Text))
        function Get-PortOwner { param([int]$Port) if ($Port -eq 3000) { 'com.docker.backend' } else { $null } }
        function Invoke-Native { param([string]$File, [string[]]$Arguments, [switch]$Capture, [switch]$AllowFail) $null = $File, $Arguments, $Capture, $AllowFail; [pscustomobject]@{ ExitCode = $pc.Code; Output = @($pc.Ps); Text = (@($pc.Ps) -join "`n") } }
        Select-FreePort -Preferred 3000
    }
    Assert-That ($gotPort -eq $pc.Want) "port 3000 held by Docker for $($pc.What) -> $gotPort (want $($pc.Want))"
}

if ($failures -eq 0) { Write-Host "`nWINDOWS UNIT TESTS PASSED" -ForegroundColor Green } else { Write-Host "`nWINDOWS UNIT TESTS FAILED ($failures)" -ForegroundColor Red }
exit $failures
