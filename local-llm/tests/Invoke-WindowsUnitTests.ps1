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
    - Test-LocalAI: the judge of a preset's past-chat and code switches on canned input, a check
      that gives no verdict (SKIP with words in both check scripts, never a PASS), every row ending
      in a verdict, and on Windows a port listening beyond localhost (the research agent's too).
    - Test-PCSecurity: its helpers (driver matcher, redaction, ACL/port verdicts, ComfyUI scan), the
      judges for what a real PC audit found (a snoozed or expired antivirus behind a passive Defender,
      a hardware-access driver any program can open, firewall openings for script runners, a stopped
      cloud-sync program the backups lie in) on canned input, their readers on Windows, that it runs
      no changing command and compiles no code that does more than open and close a device, and a
      full read-only run in a child process.
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
Assert-That ($specs.Count -eq 10) "ten shortcut specs (got $($specs.Count))"
$rc = $specs | Where-Object { $_.Name -eq 'Local AI - Re-check models' }
Assert-That ($rc -and $rc.Arguments -match "Update-Models\.ps1' -AIRoot '" -and $rc.Arguments -match "' -RecheckOnly \}" -and $rc.Arguments -notmatch '-Scheduled' -and $rc.Arguments -match 'shortcut-Update-Models\.log') "Re-check models runs Update-Models.ps1 -RecheckOnly (no downloads), logged ($($rc.Arguments))"
Assert-That (@($specs | Where-Object { $_.Name -eq 'Local AI - Security check' -and $_.Script -eq 'Test-PCSecurity.ps1' -and $_.Arguments -match 'Start-Transcript' }).Count -eq 1) 'a logged Security check shortcut runs Test-PCSecurity.ps1'
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
Assert-That ($maxLen -lt 1024 -and @($longSpecs | Where-Object { $_.TooLong }).Count -eq 0 -and @($longSpecs | Where-Object { $_.Arguments -match 'Start-Transcript' }).Count -eq 7) "a 125-char AI root: every shortcut fits the 1024-char .lnk limit, logs included ($maxLen)"
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
} else { Skip 'Windows Firewall block ranges need New-NetFirewallRule' }

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

Write-Host "`n=== Test-LocalAI: a preset that can read past chats again, and a check without a verdict ===" -ForegroundColor Cyan
# The rows of a script (its Add-Check calls) that do not give a verdict on every path. A row does when
# its code is a literal scriptblock whose last statement calls Pass, Fail, Warn, Skip or Convert-Verdict
# and whose own returns each hand one of them back. Add-Check reports a row without a verdict as SKIP
# 'this check gave no answer', so a row that has one on some paths only would change its result.
# Add-Check keeps the last verdict, so one that is neither handed back with 'return (...)' nor the
# row's last statement would be lost without a sound (a FAIL under the closing PASS): no row has one.
$looseRows = { param($Ast)
    $verdict = '(Pass|Fail|Warn|Skip|Convert-Verdict) '
    $verdictNames = @('Pass', 'Fail', 'Warn', 'Skip', 'Convert-Verdict')
    $rows = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Check' }, $true))
    $loose = @()
    foreach ($cmd in $rows) {
        $ok = $false
        if ($cmd.CommandElements.Count -eq 3 -and $cmd.CommandElements[2] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $body = $cmd.CommandElements[2].ScriptBlock
            $st = @($body.EndBlock.Statements)
            $returns = @($body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $false))
            # Where a kept verdict starts: the last statement, and right after each 'return (' (8 characters).
            $kept = @($st | Select-Object -Last 1 | ForEach-Object { $_.Extent.StartOffset }) + @($returns | ForEach-Object { $_.Extent.StartOffset + 8 })
            $lost = @($body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $verdictNames -contains $n.GetCommandName() -and $kept -notcontains $n.Extent.StartOffset }, $true))
            $ok = ($st.Count -gt 0 -and [string]$st[$st.Count - 1].Extent.Text -match ('^' + $verdict) -and
                @($returns | Where-Object { [string]$_.Extent.Text -notmatch ('^return \(' + $verdict) }).Count -eq 0 -and $lost.Count -eq 0)
        }
        if (-not $ok) { $loose += [string]$cmd.CommandElements[1].Extent.Text }
    }
    [pscustomobject]@{ Rows = $rows.Count; Loose = $loose }
}
# That rule on four rows written for it: a verdict that is returned, one that lost its 'return', one
# inside a nested scriptblock (its 'return' would leave that block, not the row), and no last word.
$looseCanary = & $looseRows ([System.Management.Automation.Language.Parser]::ParseInput((@('Add-Check "kept" { if ($a) { return (Fail "x") }; Pass "y" }', 'Add-Check "dropped" { if ($a) { Fail "x" }; Pass "y" }',
            'Add-Check "nested" { $a | ForEach-Object { return (Warn "x") }; Pass "y" }', 'Add-Check "no last word" { if ($a) { return (Fail "x") } }') -join "`n"), [ref]$null, [ref]$null))
Assert-That ($looseCanary.Rows -eq 4 -and ($looseCanary.Loose -join ' ') -ceq '"dropped" "nested" "no last word"') "a row whose verdict is neither returned nor its last statement is found, also inside a nested scriptblock, and a row that returns its verdicts is not (found: $($looseCanary.Loose -join ' '))"
# Add-Check as a script has it, with that script's own Pass/Fail/Warn/Skip, given bodies with no verdict,
# with one, and with an error. In a scope of its own: a script's Skip is not this file's, whose Skip
# prints a line CI counts. What a row would print is collected instead, and Test-PCSecurity's
# Protect-Out (it needs the PC's names) hands its text back.
$addCheckRows = { param([object[]]$Functions)
    foreach ($fd in $Functions) { . ([scriptblock]::Create($fd.Extent.Text)) }
    $results = New-Object System.Collections.ArrayList
    $said = New-Object System.Collections.ArrayList
    function Write-LaiLog([string]$Level, [string]$Message) { [void]$said.Add("[$Level] $Message") }
    function Protect-Out([string]$Text) { $Text }
    Add-Check 'empty' { }
    Add-Check 'words only' { 'some words'; 42 }
    Add-Check 'no result' { @{ Detail = 'a table without a result' } }
    Add-Check 'unknown result' { @{ Status = 'DONE'; Detail = 'not one of the four' } }
    Add-Check 'passes' { Pass 'x' }
    Add-Check 'words, then a verdict' { 'some words'; Warn 'w' }
    Add-Check 'throws' { throw 'boom' }
    $rows = @{ Said = @($said) }
    foreach ($x in $results) { $rows[[string]$x.Check] = "$($x.Status) $($x.Detail)" }
    $rows
}
$noAnswerRows = @('empty', 'words only', 'no result', 'unknown result')
$hcAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Test-LocalAI.ps1'), [ref]$null, [ref]$null)
$hcTop = @($hcAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
$hcFns = @($hcTop | Where-Object { @('Add-Check', 'Pass', 'Fail', 'Warn', 'Skip') -contains $_.Name })
$hcAc = @{ Said = @() }
try { $hcAc = & $addCheckRows $hcFns } catch { Write-Host "  the Add-Check cases stopped: $($_.Exception.Message)" }
$hcSilent = @($noAnswerRows | Where-Object { $hcAc[$_] -ne 'SKIP this check gave no answer' })
Assert-That ($hcFns.Count -eq 5 -and $hcSilent.Count -eq 0 -and $hcAc['Said'] -contains '[INFO] SKIP empty: this check gave no answer') "a health check that gives no verdict (an empty body, plain text, a table without a result, a result that is none of the four) is SKIP 'this check gave no answer', never a PASS without words (not: $($hcSilent -join ', '))"
Assert-That ($hcAc['passes'] -eq 'PASS x' -and $hcAc['words, then a verdict'] -eq 'WARN w' -and $hcAc['throws'] -eq 'FAIL boom') "a verdict is kept as given, also after other output, and a health check that throws is still FAIL with the error ($($hcAc['passes']) | $($hcAc['words, then a verdict']) | $($hcAc['throws']))"
$hcVerdicts = & $looseRows $hcAst
Assert-That ($hcVerdicts.Rows -ge 25 -and $hcVerdicts.Loose.Count -eq 0) "every health check row ends in Pass, Fail, Warn or Skip, returns nothing else and gives no verdict it does not hand back, so none of them meets that SKIP or loses a FAIL ($($hcVerdicts.Rows) rows; not: $($hcVerdicts.Loose -join ', '))"
# The judge of a preset's switches: one function at the top of the script that calls nothing (no
# command, no method, no static member) and reads no variable but its argument and its own.
$riskDefs = @($hcTop | Where-Object { $_.Name -eq 'Get-PresetToolRisk' })
$riskCalls = @(); $riskOutside = @()
if ($riskDefs.Count -eq 1) {
    $riskCalls = @($riskDefs[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -or $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
                ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Static) }, $true))
    $riskOwn = @('Meta', 'null', 'true', 'false') + @($riskDefs[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
        ForEach-Object { [string]$_.Left.VariablePath.UserPath })
    $riskOutside = @($riskDefs[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { [string]$_.VariablePath.UserPath } | Where-Object { $riskOwn -notcontains $_ } | Select-Object -Unique)
}
Assert-That ($riskDefs.Count -eq 1 -and $riskCalls.Count -eq 0 -and $riskOutside.Count -eq 0) "Get-PresetToolRisk is one top-level function that only reads its argument ($($riskDefs.Count) definition(s); calls: $(@($riskCalls | ForEach-Object { [string]$_.Extent.Text }) -join ', '); other variables: $($riskOutside -join ', '))"
$riskOf = { param([string]$Json)
    . ([scriptblock]::Create($riskDefs[0].Extent.Text))
    $meta = $null; if ($Json) { $meta = $Json | ConvertFrom-Json }
    '[' + (@(Get-PresetToolRisk $meta) -join ' and ') + ']'
}
$chatsOn = @(); $nothingOff = @(); $switchesOff = ''; $codeOn = @(); $codeUnread = @(); $bothOn = ''
if ($riskDefs.Count -eq 1) {
    $chatsOn = @((& $riskOf '{"builtinTools":{"chats":true,"code_interpreter":false},"capabilities":{"code_interpreter":false}}'),
        (& $riskOf '{"builtinTools":{"code_interpreter":false},"capabilities":{"code_interpreter":false}}'))
    $nothingOff = @((& $riskOf '{"capabilities":{"vision":true}}'), (& $riskOf '{}'), (& $riskOf ''))
    $switchesOff = & $riskOf '{"builtinTools":{"chats":false,"code_interpreter":false},"capabilities":{"code_interpreter":false}}'
    $codeOn = @((& $riskOf '{"builtinTools":{"chats":false,"code_interpreter":true},"capabilities":{"code_interpreter":false}}'),
        (& $riskOf '{"builtinTools":{"chats":false,"code_interpreter":false},"capabilities":{"code_interpreter":true}}'),
        (& $riskOf '{"builtinTools":{"chats":false,"code_interpreter":true},"capabilities":{"code_interpreter":true}}'))
    # A code switch that is not there, or is null, was not read as off: both missing (with and without
    # capabilities), then each one missing and each one null beside the other set to false.
    $codeUnread = @((& $riskOf '{"builtinTools":{"chats":false}}'),
        (& $riskOf '{"builtinTools":{"chats":false},"capabilities":{"vision":true}}'),
        (& $riskOf '{"builtinTools":{"chats":false},"capabilities":{"code_interpreter":false}}'),
        (& $riskOf '{"builtinTools":{"chats":false,"code_interpreter":false},"capabilities":{"vision":true}}'),
        (& $riskOf '{"builtinTools":{"chats":false,"code_interpreter":null},"capabilities":{"code_interpreter":false}}'),
        (& $riskOf '{"builtinTools":{"chats":false,"code_interpreter":false},"capabilities":{"code_interpreter":null}}'))
    $bothOn = & $riskOf '{"builtinTools":{"chats":true,"code_interpreter":true},"capabilities":{"code_interpreter":true}}'
}
Assert-That ($chatsOn.Count -eq 2 -and @($chatsOn | Where-Object { $_ -ceq '[read past chats]' }).Count -eq 2) "past-chat search counts as on when the preset says so and when the chats key is missing, as Open WebUI treats it ($($chatsOn -join ' | '))"
Assert-That ($nothingOff.Count -eq 3 -and @($nothingOff | Where-Object { $_ -ceq '[read past chats and run code]' }).Count -eq 3) "a preset without builtinTools, with an empty meta or with no meta at all has switched nothing off: past chats and code both count as on ($($nothingOff -join ' | '))"
Assert-That ($switchesOff -ceq '[]') "a preset with all three switches set to false is clean (found: $switchesOff)"
Assert-That ($codeOn.Count -eq 3 -and @($codeOn | Where-Object { $_ -ceq '[run code]' }).Count -eq 3 -and $bothOn -ceq '[read past chats and run code]') "code execution counts as on with either of its two switches, is named once with both, and comes after past chats when both are back ($($codeOn -join ' | ') | $bothOn)"
Assert-That ($codeUnread.Count -eq 6 -and @($codeUnread | Where-Object { $_ -ceq '[run code]' }).Count -eq 6) "a code switch that is missing or null counts as on like a missing chats key, so the row never prints 'code execution off' for a switch it did not read as off ($($codeUnread -join ' | '))"
# The Preset row asks that judge before the image switch and before any warning (either would otherwise
# be all the row says), and its sentence, taken from the row's source, is word for word the one below.
$presetRow = $hcAst.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Check' -and $n.CommandElements.Count -eq 3 -and [string]$n.CommandElements[1].Extent.Text -like '"Preset $*' }, $true)
$presetAt = @{}; $presetText = @(); $presetNot = @('the sentence is not in the row')
if ($presetRow) {
    foreach ($name in 'Get-PresetToolRisk', 'Test-LaiPresetVision', 'Warn') {
        $hit = $presetRow.CommandElements[2].Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $name }, $true)
        if ($hit) { $presetAt[$name] = $hit.Extent.StartOffset }
    }
    $presetSays = $presetRow.CommandElements[2].Find({ param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $n.Value -like 'the assistant can *' }, $true)
    if ($presetSays) {
        # $risks is the row's own variable for what Get-PresetToolRisk found.
        $sayIt = [scriptblock]::Create('param($risks) ' + $presetSays.Extent.Text)
        $presetText = @([string](& $sayIt @('read past chats')), [string](& $sayIt @('read past chats', 'run code')))
        # How the sentence leaves the row: as Fail's own words in a 'return (Fail ...)' that is all the
        # row's own 'if ($risks.Count)' does, $risks being what the judge said of this preset's meta,
        # ahead of the image switch and of every warning. A Warn there, or a lost 'return' (the row's
        # closing Pass is then the last verdict), would let such a preset through.
        $presetNot = @()
        $presetBody = $presetRow.CommandElements[2].ScriptBlock
        if (-not ($presetSays.Parent -is [System.Management.Automation.Language.CommandAst] -and $presetSays.Parent.GetCommandName() -eq 'Fail')) { $presetNot += 'it is not what Fail is given' }
        $sayReturn = @($presetBody.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] -and $n.Extent.StartOffset -le $presetSays.Extent.StartOffset -and $n.Extent.EndOffset -ge $presetSays.Extent.EndOffset }, $false))
        if (-not ($sayReturn.Count -eq 1 -and [string]$sayReturn[0].Extent.Text -cmatch '^return \(Fail "the assistant can ')) { $presetNot += "it is not handed back with 'return (Fail ...)'" }
        $sayIf = $null; if ($sayReturn.Count -eq 1 -and $sayReturn[0].Parent) { $sayIf = $sayReturn[0].Parent.Parent }
        if (-not ($sayIf -is [System.Management.Automation.Language.IfStatementAst] -and [object]::ReferenceEquals($sayIf.Parent, $presetBody.EndBlock) -and $sayIf.Clauses.Count -eq 1 -and
                [string]$sayIf.Clauses[0].Item1.Extent.Text -cmatch '^\$risks\.Count( -gt 0)?$' -and $sayIf.Clauses[0].Item2.Statements.Count -eq 1)) { $presetNot += "that return is not all the row's own 'if (`$risks.Count)' does" }
        elseif (-not ($presetAt.Count -eq 3 -and $sayIf.Extent.StartOffset -lt $presetAt['Test-LaiPresetVision'] -and $sayIf.Extent.StartOffset -lt $presetAt['Warn'])) { $presetNot += 'it comes after the image switch or a warning' }
        $riskSet = @($presetBody.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and [string]$n.Left.Extent.Text -eq '$risks' }, $true))
        if (-not ($riskSet.Count -eq 1 -and [string]$riskSet[0].Right.Extent.Text -cmatch '^@\(Get-PresetToolRisk \$p\.meta\)$' -and [object]::ReferenceEquals($riskSet[0].Parent, $presetBody.EndBlock))) { $presetNot += '$risks is not, once and for every preset, what Get-PresetToolRisk says of $p.meta' }
    }
}
Assert-That ($presetAt.Count -eq 3 -and $presetAt['Get-PresetToolRisk'] -lt $presetAt['Test-LaiPresetVision'] -and $presetAt['Get-PresetToolRisk'] -lt $presetAt['Warn']) "the Preset row judges the past-chat and code switches before the image switch and before any warning (found: $(@($presetAt.Keys) -join ', '))"
Assert-That ($presetNot.Count -eq 0) "the Preset row hands that sentence back as a failure: 'return (Fail ...)' is all its 'if (`$risks.Count)' does, on what Get-PresetToolRisk says of the preset's meta, ahead of the image switch and of every warning (not so: $($presetNot -join '; '))"
$presetFix = ' again; run Start menu > Local AI - Update toolkit to put the safety settings back'
Assert-That ($presetText.Count -eq 2 -and $presetText[0] -ceq "the assistant can read past chats$presetFix" -and $presetText[1] -ceq "the assistant can read past chats and run code$presetFix" -and ([string]$hcAst.Extent.Text) -notmatch 'memory/web/knowledge tools on') "a preset that can read past chats fails with what it can do again and the one step that puts it back, and the row no longer says 'tools on' without having read them ($($presetText -join ' | '))"

Write-Host "`n=== Test-LocalAI: anything listening beyond localhost is reported ===" -ForegroundColor Cyan
if ($onWindows) {
    $expRoot = Join-Path $Work 'exposure'
    New-Item -ItemType Directory -Force -Path $expRoot | Out-Null
    ConvertTo-Json @{ WebUIPort = 39998; SearxngPort = 39997; OllamaUrl = 'http://127.0.0.1:1' } | Set-Content -LiteralPath (Join-Path $expRoot 'localai-config.json')
    $line = { param($Addr, [int]$Port = 39998, [string]$Root = $expRoot)
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($Addr), $Port)
        $l.Start()
        try { $res = Invoke-Child 'Test-LocalAI.ps1' @('-AIRoot', $Root, '-NoContainers', '-Quick') } finally { $l.Stop() }
        return (@($res.Text -split "`n" | Where-Object { $_ -match 'Nothing exposed beyond localhost' }) -join ' ')
    }
    $open = & $line '0.0.0.0'
    $closed = & $line '127.0.0.1'
    Assert-That ($open -match 'FAIL' -and $open -match '39998@0\.0\.0\.0') "a port bound to all interfaces fails the check ($open)"
    Assert-That ($closed -match 'PASS' -and $closed -match ': 11434, 39998, 39997 bound to loopback only') "the same port on 127.0.0.1 passes, and without the research agent no fourth port is on the list ($closed)"
    # The optional research agent's port is one of them once it is installed (DeepResearchPort above 0).
    # In a root of its own: with that port set the run also waits for the agent to answer.
    $expResearch = Join-Path $Work 'exposure-research'
    New-Item -ItemType Directory -Force -Path $expResearch | Out-Null
    ConvertTo-Json @{ WebUIPort = 39998; SearxngPort = 39997; DeepResearchPort = 39993; OllamaUrl = 'http://127.0.0.1:1' } | Set-Content -LiteralPath (Join-Path $expResearch 'localai-config.json')
    $research = & $line '0.0.0.0' 39993 $expResearch
    Assert-That ($research -match 'FAIL' -and $research -match '39993@0\.0\.0\.0') "the research agent's port bound to all interfaces fails the check too ($research)"
} else { Skip 'exposure check runs on Windows only' }

Write-Host "`n=== Test-LocalAI: the Integrity watch line for an install baseline ===" -ForegroundColor Cyan
# The health check's own sentences for a baseline an install recorded, run under Windows PowerShell
# 5.1 against a baseline and a watch record written by hand: what an acceptance settled and an
# install carried on is worded apart from what the install kept, with one advice and the command
# to paste; the watch's reason for a comparison that did not run is shown only when its record
# carries this baseline's own id.
if ($onWindows) {
    $ihRoot = Join-Path $Work 'integrity-health'
    New-Item -ItemType Directory -Force -Path $ihRoot | Out-Null
    ConvertTo-Json @{ WebUIPort = 39996; SearxngPort = 39995; OllamaUrl = 'http://127.0.0.1:1' } | Set-Content -LiteralPath (Join-Path $ihRoot 'localai-config.json')
    $ihSettled = @{ Id = 'file+|Scripts\extra.ps1'; Text = '"Scripts\extra.ps1" is new'; Settled = $true }
    $ihKept = @{ Id = 'file+|Stack\planted.yml'; Text = '"Stack\planted.yml" is new' }
    $ihLine = { param([object[]]$Accepted, [hashtable]$Watch)
        Save-LaiState -Path (Get-LaiIntegrityPath -AIRoot $ihRoot) -State @{ version = 1; id = 'ih-new'; reason = 'install'; recordedAt = '2026-01-02T10:00:00'; files = @{ 'Scripts\tool.ps1' = 'x' }; accepted = @($Accepted); acceptedCount = @($Accepted).Count }
        Save-LaiState -Path (Join-Path $ihRoot 'watch-state.json') -State @{ integrity = $Watch }
        $res = Invoke-Child 'Test-LocalAI.ps1' @('-AIRoot', $ihRoot, '-NoContainers', '-Quick')
        return (@($res.Text -split "`n" | Where-Object { $_ -match 'Integrity watch' }) -join ' ')
    }
    $ihWhy = 'the comparison started at 09:00 did not finish'
    $ihStale = & $ihLine @($ihSettled, $ihKept) @{ baseline = 'ih-old'; skippedWhy = $ihWhy }
    $ihOwn = & $ihLine @($ihSettled) @{ baseline = 'ih-new'; skippedWhy = $ihWhy }
    $ihPlain = & $ihLine @($ihKept) @{ baseline = 'ih-old' }
    Assert-That ($ihStale -match 'WARN Integrity watch: .*on its next run\. That install or update carried on 1 thing\(s\) already accepted by hand \(-AcceptBaseline\), which still count as normal: "Scripts\\extra\.ps1" is new\. It also kept 1 thing\(s\) it did not install, which now count as normal: "Stack\\planted\.yml" is new\. That is 2 in all\. If that acceptance was not yours, or you did not add what was kept, do not repair this with Update toolkit' -and [regex]::Matches($ihStale, 'do not repair this with Update toolkit').Count -eq 1 -and $ihStale -notmatch 'first remove what was added|Start menu > Local AI - Update toolkit' -and [regex]::Matches($ihStale, 'this goes away with: ').Count -eq 1 -and $ihStale -match 'If both were you, this goes away with: .*-AcceptBaseline' -and $ihStale -notmatch 'the comparison is not running|did not finish') "a settled script and a kept Stack file: one advice, which names no shortcut, the number in all, and no reason from the record of another baseline ($ihStale)"
    Assert-That ($ihOwn -match 'WARN Integrity watch: .*has not compared the PC with it yet: the comparison is not running \(the comparison started at 09:00 did not finish\)\. That install or update carried on 1 thing\(s\) already accepted by hand' -and $ihOwn -match 'If that acceptance was not yours, do not repair this with Update toolkit.*If it was, this goes away with: .*-AcceptBaseline' -and $ihOwn -notmatch 'on its next run|kept \d+ thing\(s\) it did not install') "the watch's record under this baseline's id: its reason is shown, and an all-settled list still ends in the command ($ihOwn)"
    Assert-That ($ihPlain -match 'WARN Integrity watch: .*on its next run\. That install or update kept 1 thing\(s\) it did not install, which now count as normal: "Stack\\planted\.yml" is new\. If you did not add them, first remove what was added.*If you did, this goes away with: .*-AcceptBaseline' -and $ihPlain -notmatch 'carried on|in all') "only kept things: the line reads as before ($ihPlain)"
    # The Backups row of such a run, in the same root: the nightly backup found Open WebUI without its
    # users or chats and recorded it (backup-state.json, 'emptied'), and the newest archive is the
    # -EMPTY one of that night. The row fails with the counts, the last good backup and both ways out,
    # and does not name the -EMPTY archive as a backup.
    $ihBk = Join-Path $ihRoot 'Backups'
    New-Item -ItemType Directory -Force -Path $ihBk | Out-Null
    $ihGood = Join-Path $ihBk 'open-webui-20260101-030000.tar.gz'
    $ihEmpty = Join-Path $ihBk 'open-webui-20260102-030000-EMPTY.tar.gz'
    Set-Content -LiteralPath $ihGood -Value 'x'
    (Get-Item -LiteralPath $ihGood).LastWriteTime = (Get-Date).AddHours(-30)
    Set-Content -LiteralPath $ihEmpty -Value 'x'
    Save-LaiState -Path (Join-Path $ihRoot 'backup-state.json') -State @{ emptied = @{ at = '2026-01-02T03:00:00'; archive = $ihEmpty; lastGood = $ihGood; users = 0; chats = 0; hadUsers = 3; hadChats = 40 } }
    $ihRes = Invoke-Child 'Test-LocalAI.ps1' @('-AIRoot', $ihRoot, '-NoContainers', '-Quick')
    $ihBackups = @($ihRes.Text -split "`n" | Where-Object { $_ -match ' Backups: ' }) -join ' '
    Assert-That ($ihBackups -match 'FAIL Backups: ' -and $ihBackups -match 'looked wiped' -and $ihBackups -match '0 users and 0 chats, 3 and 40 at the last good backup' -and $ihBackups -match [regex]::Escape($ihGood) -and $ihBackups -match 'Restore-OpenWebUI\.ps1' -and $ihBackups -match '-AcceptEmpty' -and $ihBackups -notmatch 'EMPTY\.tar\.gz') "an Open WebUI the nightly backup found wiped fails the Backups row with the counts now and before, the last good backup and both ways out, and its -EMPTY archive is not named as a backup ($ihBackups)"
} else { Skip 'the Integrity watch line of the health check runs on Windows only' }

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
    if ($env:COMPUTERNAME) { Assert-That ($all -notmatch [regex]::Escape($env:COMPUTERNAME)) 'computer name redacted' } else { Skip 'computer name redaction needs COMPUTERNAME' }
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
# The limit itself. LOCALAI_DOCKER_TIMEOUT is a test hook; the nightly backup and the model update
# ask for the limit at their start, so a value left in the owner's own variables that is no positive
# whole number must not end them (it was cast with [int], which fails on 'x').
$dtSaved = $env:LOCALAI_DOCKER_TIMEOUT
$dtGot = @()
try { foreach ($dtValue in 'x', '0', '-5', '7', '') { $env:LOCALAI_DOCKER_TIMEOUT = $dtValue; $dtGot += [string](Get-LaiDockerTimeout) } }
catch { $dtGot += "stopped: $($_.Exception.Message)" }
finally { $env:LOCALAI_DOCKER_TIMEOUT = $dtSaved }
Assert-That (($dtGot -join ',') -eq '30,30,30,7,30') "the docker time limit takes LOCALAI_DOCKER_TIMEOUT only as a positive whole number: 'x', 0 and -5 keep 30 s, 7 is 7, unset is 30 ($($dtGot -join ','))"
$libTextDt = Get-Content -LiteralPath (Join-Path (Join-Path $src 'lib') 'LocalAI.psm1') -Raw -Encoding UTF8
Assert-That ($libTextDt -notmatch '\[int\]\$env:LOCALAI_DOCKER_TIMEOUT' -and $libTextDt -notmatch '\[int\]\$env:LOCALAI_TEST_SIGNIN_WAIT' -and $libTextDt -match 'TryParse\(\[string\]\$env:LOCALAI_TEST_SIGNIN_WAIT') 'the library casts neither that variable nor the sign-in wait of the tests to a number unchecked (text of lib\LocalAI.psm1)'

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

Write-Host "`n=== integrity watch: files, settings, scheduled tasks and listeners against a baseline ===" -ForegroundColor Cyan
# The watch compares the installed scripts, the Stack folder, the LocalAI-* tasks and the listeners
# with what the last install or update recorded. First the parts every platform has.
Assert-That ((Test-LaiIntegrityExcluded -Name '.env') -and (Test-LaiIntegrityExcluded -Name 'watch.log') -and (Test-LaiIntegrityExcluded -Name 'state.json.bak') -and (Test-LaiIntegrityExcluded -Name 'Secrets' -Folder)) '.env, logs, the leftovers of a save and a Secrets folder are left out'
Assert-That (-not (Test-LaiIntegrityExcluded -Name 'docker-compose.yml') -and -not (Test-LaiIntegrityExcluded -Name 'lib' -Folder) -and -not (Test-LaiIntegrityExcluded -Name '.env.example') -and -not (Test-LaiIntegrityExcluded -Name 'Secrets')) 'a compose file, an ordinary folder and look-alike names are not'
$igRoot = Join-Path $Work 'integrity'
$igScripts = Join-Path $igRoot 'Scripts'; $igStack = Join-Path $igRoot 'Stack'; $igOutside = Join-Path $Work 'integrity-outside'
foreach ($d in (Join-Path $igScripts 'lib'), (Join-Path $igScripts 'Secrets'), $igStack, (Join-Path $igRoot 'Logs'), $igOutside) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$igTool = Join-Path $igScripts 'tool.ps1'; $igHelper = Join-Path (Join-Path $igScripts 'lib') 'helper.psm1'; $igEnvFile = Join-Path $igStack '.env'
Set-Content -LiteralPath $igTool -Value 'original'
Set-Content -LiteralPath $igHelper -Value 'original'
Set-Content -LiteralPath (Join-Path (Join-Path $igScripts 'Secrets') 'token.txt') -Value 'never read'
Set-Content -LiteralPath (Join-Path $igStack 'docker-compose.yml') -Value 'services: {}'
Set-Content -LiteralPath $igEnvFile -Value @('A=1', 'OLLAMA_BASE_URL=http://render-guard:11434', 'WEBUI_SECRET_KEY=never-shown')
Set-Content -LiteralPath (Join-Path $igOutside 'elsewhere.txt') -Value 'not part of the install'
# A folder inside Stack swapped for a link to somewhere else (a junction needs no admin rights).
$igLink = Join-Path $igStack 'linked'
if ($onWindows) { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; & cmd.exe /c mklink /J $igLink $igOutside 2>&1 | Out-Null; $ErrorActionPreference = $prev } else { & ln -s $igOutside $igLink }
Assert-That (Test-Path -LiteralPath (Join-Path $igLink 'elsewhere.txt')) 'setup: the link inside Stack reaches the folder outside'
$igFiles = Get-LaiIntegrityFiles -AIRoot $igRoot
$igNames = @($igFiles.Keys)
Assert-That ($igNames.Count -eq 4 -and $igNames -contains 'Scripts\tool.ps1' -and $igNames -contains 'Scripts\lib\helper.psm1' -and $igNames -contains 'Stack\docker-compose.yml' -and $igNames -contains 'Stack\linked') "every file of Scripts and Stack is listed by its path below the install folder; .env and everything under Secrets are not ($(($igNames | Sort-Object) -join ', '))"
Assert-That ([string]$igFiles['Scripts\tool.ps1'] -eq [string](Get-FileHash -LiteralPath $igTool -Algorithm SHA256).Hash) 'a file is recorded by its SHA-256'
Assert-That ([string]$igFiles['Stack\linked'] -eq 'link' -and @($igNames | Where-Object { $_ -like '*elsewhere*' }).Count -eq 0) 'a link is recorded as a link and never followed (nothing outside the install folder is read)'
# A folder swapped for a link after its parent was listed and before it is read itself (the walk
# holds what the listing said about it): asked again right before the read, it is a link.
$igSwapRoot = Join-Path $Work 'integrity-swap'; $igSwap = Join-Path $igSwapRoot 'sub'
New-Item -ItemType Directory -Force -Path $igSwap | Out-Null
Set-Content -LiteralPath (Join-Path $igSwap 'inside.txt') -Value 'x'
$igStale = Get-Item -LiteralPath $igSwap -Force
$igWasFolder = -not ($igStale.Attributes -band [IO.FileAttributes]::ReparsePoint)
Remove-Item -LiteralPath $igSwap -Recurse -Force
if ($onWindows) { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; & cmd.exe /c mklink /J $igSwap $igOutside 2>&1 | Out-Null; $ErrorActionPreference = $prev } else { & ln -s $igOutside $igSwap }
$igSwapMap = @{}
Add-LaiIntegrityEntry -Map $igSwapMap -Item $igStale -Relative 'Stack\sub'
Assert-That ($igWasFolder -and (Test-Path -LiteralPath (Join-Path $igSwap 'elsewhere.txt')) -and @($igSwapMap.Keys).Count -eq 1 -and [string]$igSwapMap['Stack\sub'] -eq 'link') "a folder that became a link after it was listed is not entered: recorded as a link, nothing behind it is named or hashed ($(@($igSwapMap.Keys | Sort-Object) -join ', '))"
Assert-That ([string](Get-LaiIntegrityFiles -AIRoot $igRoot -MaxHashBytes 3)['Scripts\tool.ps1'] -like 'size *') 'a file above the size limit is recorded by its size instead of being hashed'

# A folder filled beyond what the watch reads in one go (a container writing into Stack\searxng, an
# archive unpacked there). The watch task is ended after ten minutes: a walk without a limit would
# stop every later run before it reports anything. So the walk stops, says where, and the
# comparison reports that once instead of calling everything it did not reach 'gone'.
$igFull = Get-LaiIntegritySnapshot -AIRoot $igRoot -TaskPattern 'LaiNoSuchTask-*'
$igPart = Get-LaiIntegritySnapshot -AIRoot $igRoot -TaskPattern 'LaiNoSuchTask-*' -Budget (New-LaiIntegrityBudget -MaxEntries 4)
$igTiny = Get-LaiIntegritySnapshot -AIRoot $igRoot -TaskPattern 'LaiNoSuchTask-*' -Budget (New-LaiIntegrityBudget -MaxEntries 2)
# (Other programs on this machine may open a port between two snapshots: not what is compared here.)
foreach ($s in $igFull, $igPart, $igTiny) { $s['listeners'] = $null }
Assert-That ([string]$igFull['filesStopped'] -eq '' -and @($igFull['files'].Keys).Count -eq 4) 'the folders as installed are read completely'
Assert-That ([string]$igPart['filesStopped'] -eq 'Stack' -and @($igPart['files'].Keys).Count -eq 2 -and $igPart['files'].ContainsKey('Scripts\tool.ps1') -and $igPart['files'].ContainsKey('Scripts\lib\helper.psm1')) "a walk with room for four entries reads Scripts (first, in name order) and stops at Stack ($([string]$igPart['filesStopped']))"
$igPartDiff = @(Compare-LaiIntegrity -Baseline $igFull -Current $igPart)
Assert-That ($igPartDiff.Count -eq 1 -and [string]$igPartDiff[0].Id -eq 'walk|Stack' -and [string]$igPartDiff[0].Text -like 'reading "Stack" stopped at "Stack"*the rest was not compared') "against a complete baseline that is one difference, and no file it did not reach is called gone ($(@($igPartDiff | ForEach-Object { [string]$_.Text }) -join '; '))"
$igTinyDiff = @(Compare-LaiIntegrity -Baseline $igFull -Current $igTiny)
Assert-That ([string]$igTiny['filesStopped'] -like 'Scripts*' -and @($igTinyDiff | Where-Object { $_.Id -like 'file-|*' }).Count -eq 0 -and @($igTinyDiff | Where-Object { $_.Id -eq 'walk|Scripts' }).Count -eq 1) "a walk that stops inside Scripts says so and calls nothing gone ($([string]$igTiny['filesStopped']))"
Assert-That (@(Compare-LaiIntegrity -Baseline $igPart -Current $igPart).Count -eq 0 -and @(Compare-LaiIntegrity -Baseline $igPart -Current $igFull).Count -eq 0) 'a baseline recorded that way raises nothing by itself, and files it never read are not called new'
$igByBytes = Get-LaiIntegritySnapshot -AIRoot $igRoot -TaskPattern 'LaiNoSuchTask-*' -Budget (New-LaiIntegrityBudget -MaxBytes 1)
$igByTime = Get-LaiIntegritySnapshot -AIRoot $igRoot -TaskPattern 'LaiNoSuchTask-*' -Budget (New-LaiIntegrityBudget -MaxSeconds 0)
Assert-That ([string]$igByBytes['filesStopped'] -eq 'Scripts\tool.ps1' -and @($igByBytes['files'].Keys).Count -eq 1 -and [string]$igByTime['filesStopped'] -eq 'Scripts' -and @($igByTime['files'].Keys).Count -eq 0) "the walk also has a limit on the bytes it hashes and on its time ($([string]$igByBytes['filesStopped']) / $([string]$igByTime['filesStopped']))"
Assert-That ((Get-LaiIntegritySummary -Baseline $igPart) -match '^2 files \(not all of them') 'and a baseline that could not read everything says so in its summary'

# Where chats and searches are sent is a line in Stack\.env: those settings are compared by name, as
# a fingerprint. Their values, and every other line (versions, ports, keys), are not kept.
$igEnvMap = ConvertTo-LaiIntegrityEnv -Lines @('# a comment', 'OPEN_WEBUI_VERSION=v1', 'OLLAMA_BASE_URL=http://render-guard:11434', ' OLLAMA_UPSTREAM = http://host.docker.internal:11434 ', 'COMFYUI_URLS=http://host.docker.internal:8188', 'DEEP_RESEARCH_OLLAMA_URL=http://render-guard:11434', 'WEBUI_SECRET_KEY=never-shown', 'WEBUI_EXTRA_ORIGINS=;https://pc.tail.ts.net', 'WEBUI_PORT=3000')
Assert-That (((@($igEnvMap.Keys) | Sort-Object) -join ',') -eq 'COMFYUI_URLS,DEEP_RESEARCH_OLLAMA_URL,OLLAMA_BASE_URL,OLLAMA_UPSTREAM') "of .env only the settings that route chats and searches are kept ($((@($igEnvMap.Keys) | Sort-Object) -join ','))"
Assert-That ([string]$igEnvMap['OLLAMA_BASE_URL'] -match '^[0-9A-F]{12}$' -and [string]$igEnvMap['OLLAMA_BASE_URL'] -eq [string]$igEnvMap['DEEP_RESEARCH_OLLAMA_URL'] -and [string]$igEnvMap['OLLAMA_BASE_URL'] -ne [string]$igEnvMap['OLLAMA_UPSTREAM'] -and @($igEnvMap.Values | Where-Object { $_ -match 'http|render' }).Count -eq 0) 'each as a short fingerprint of its value: the same address reads the same, another one differs, and no value is kept'
$igEnvNow = Get-LaiIntegrityEnv -AIRoot $igRoot
Assert-That ($igEnvNow -is [hashtable] -and @($igEnvNow.Keys).Count -eq 1 -and [string]$igEnvNow['OLLAMA_BASE_URL'] -eq [string]$igEnvMap['OLLAMA_BASE_URL'] -and (Get-LaiIntegrityEnv -AIRoot $igOutside) -is [hashtable] -and @((Get-LaiIntegrityEnv -AIRoot $igOutside).Keys).Count -eq 0) 'read from the real file; no .env at all is an empty answer'

# What counts as a difference, and how it reads (pure: made-up baselines).
$igBase = @{
    files     = @{ 'Scripts\a.ps1' = 'AAAAAAAAAAAAAAAA1'; 'Scripts\b.ps1' = 'BBBB'; 'Stack\c.yml' = 'CCCC'; 'Scripts\lib' = 'DDDD' }
    env       = @{ OLLAMA_BASE_URL = 'T1'; OLLAMA_UPSTREAM = 'T2'; DEEP_RESEARCH_OLLAMA_URL = 'T4' }
    tasks     = @{
        'LocalAI-Watch' = @{ Run = 'conhost.exe --headless powershell.exe -File watch.ps1'; User = 'owner'; LogonType = 'Interactive'; RunLevel = 'Limited' }
        'LocalAI-Gone'  = @{ Run = 'x.exe'; User = 'owner'; LogonType = 'Interactive'; RunLevel = 'Limited' }
    }
    listeners = @(@{ Program = 'ollama'; Port = 11434; Network = $false }, @{ Program = 'svchost'; Port = 49664; Network = $true }, @{ Program = 'com.docker.backend'; Port = 3000; Network = $false })
}
$igNow = @{
    files     = @{ 'Scripts\a.ps1' = 'ZZZZZZZZZZZZZZZZ2'; 'Scripts\b.ps1' = 'BBBB'; 'Stack\new.yml' = 'NNNN'; 'Scripts\lib' = 'link' }
    env       = @{ OLLAMA_BASE_URL = 'T1'; OLLAMA_UPSTREAM = 'T9'; COMFYUI_URLS = 'T3' }
    tasks     = @{
        'LocalAI-Watch' = @{ Run = 'other.exe'; User = 'someone-else'; LogonType = 'Interactive'; RunLevel = 'Highest' }
        'LocalAI-New'   = @{ Run = 'y.exe'; User = 'owner'; LogonType = 'Interactive'; RunLevel = 'Highest' }
    }
    listeners = @(@{ Program = 'ollama'; Port = 11434; Network = $true }, @{ Program = 'svchost'; Port = 49670; Network = $true }, @{ Program = 'python'; Port = 3000; Network = $false },
        @{ Program = 'llama-server'; Port = 51000; Network = $false }, @{ Program = 'steam'; Port = 27036; Network = $true }, @{ Program = 'steam'; Port = 50001; Network = $true }, @{ Program = 'steam'; Port = 50002; Network = $true })
}
$igDiff = @(Compare-LaiIntegrity -Baseline $igBase -Current $igNow -WatchedPorts @(11434, 3000))
$igText = @($igDiff | ForEach-Object { [string]$_.Text })
Assert-That ($igText -contains '"Scripts\a.ps1" was changed' -and $igText -contains '"Stack\new.yml" is new' -and $igText -contains '"Stack\c.yml" is gone' -and $igText -contains '"Scripts\lib" is now a link to another place') "files: changed, new, gone and swapped for a link, each by name ($($igText -join '; '))"
Assert-That ($igText -contains 'the setting "OLLAMA_UPSTREAM" in Stack\.env was changed' -and $igText -contains 'the setting "COMFYUI_URLS" was added to Stack\.env' -and $igText -contains 'the setting "DEEP_RESEARCH_OLLAMA_URL" was removed from Stack\.env' -and @($igText | Where-Object { $_ -match 'T9|T2|OLLAMA_BASE_URL' }).Count -eq 0) 'a routing setting in .env: changed, added and removed, by its name only'
Assert-That ($igText -contains 'the scheduled task "LocalAI-Watch" now runs a different command and runs as a different account or sign-in type and runs with administrator rights') 'a task: what it runs, as whom and at what privilege'
Assert-That ($igText -contains 'the scheduled task "LocalAI-New" is new and runs with administrator rights' -and $igText -contains 'the scheduled task "LocalAI-Gone" is gone') 'a new task (elevated ones say so) and a removed one'
Assert-That ($igText -contains '"ollama" now accepts connections from other devices on port 11434' -and $igText -contains '"steam" now accepts connections from other devices on port 27036') 'a program newly reachable from the network is named with its port (also one that listened on loopback only before)'
Assert-That ($igText -contains 'port 3000 is now held by "python" (it was "com.docker.backend")') "one of the stack's own ports held by another program is news even on loopback"
Assert-That (@($igText | Where-Object { $_ -like '"steam"*a temporary port' }).Count -eq 1 -and @($igText | Where-Object { $_ -match 'svchost|llama-server' }).Count -eq 0 -and $igDiff.Count -eq 14) "not news: Windows' per-start ports for a program that had one (several count once), and a new loopback-only listener ($($igDiff.Count) differences)"
Assert-That (@(Compare-LaiIntegrity -Baseline $igBase -Current $igNow | Where-Object { $_.Key -like 'port*' }).Count -eq 0) 'a port that is not one of the stack''s own changing hands on loopback is not news'
Assert-That (@(Compare-LaiIntegrity -Baseline $igBase -Current $igBase).Count -eq 0) 'a state compared with itself: no difference'
Assert-That (@(Compare-LaiIntegrity -Baseline $igBase -Current @{ files = $igBase['files']; env = $null; tasks = $null; listeners = $null }).Count -eq 0) 'settings, tasks and listeners that could not be read are skipped, not reported as gone'
# What a difference is about (Id) and what its content was (Key): the watch counts its two looks
# by the first, and knows a second, different change by the second.
$igOne = @(Compare-LaiIntegrity -Baseline @{ files = @{ 'Scripts\a' = 'H1' } } -Current @{ files = @{ 'Scripts\a' = 'H2' } })[0]
$igTwo = @(Compare-LaiIntegrity -Baseline @{ files = @{ 'Scripts\a' = 'H1' } } -Current @{ files = @{ 'Scripts\a' = 'H3' } })[0]
Assert-That ([string]$igOne.Id -eq 'file|Scripts\a' -and [string]$igTwo.Id -eq [string]$igOne.Id -and [string]$igOne.Key -ne [string]$igTwo.Key -and [string]$igOne.Key -eq [string]@(Compare-LaiIntegrity -Baseline @{ files = @{ 'Scripts\a' = 'H1' } } -Current @{ files = @{ 'Scripts\a' = 'H2' } })[0].Key) "a file changed twice is one difference (same Id) with two contents (two Keys); the same change keeps its Key ($([string]$igOne.Key) / $([string]$igTwo.Key))"
# An archive unpacked into the wrong folder is one line, not hundreds.
$igManyNow = @{ 'Stack\c.yml' = 'CCCC'; 'Stack\searxng\settings.yml' = 'S'; 'Stack\searxng\one.yml' = 'N1' }
foreach ($i in 1..25) { $igManyNow["Stack\unpacked\sub$($i % 3)\f$i.txt"] = "H$i" }
$igManyBase = @{ files = @{ 'Stack\c.yml' = 'CCCC'; 'Stack\searxng\settings.yml' = 'S' } }
$igManyText = @(Compare-LaiIntegrity -Baseline $igManyBase -Current @{ files = $igManyNow } | ForEach-Object { [string]$_.Text })
Assert-That ($igManyText.Count -eq 2 -and $igManyText -contains '25 new files in "Stack\unpacked"' -and $igManyText -contains '"Stack\searxng\one.yml" is new') "more than 20 new files under one new folder are one difference with a count; one new file next to known ones keeps its name ($($igManyText -join '; '))"
Assert-That (@(Compare-LaiIntegrity -Baseline $igManyBase -Current @{ files = $igManyNow } -MaxNewPerFolder ([int]::MaxValue)).Count -eq 26) 'and each is listed by name where every one has to be judged (what a new baseline takes in)'
# Names are chosen by whoever made the change and are shown to every Open WebUI user on the banner.
$igOddName = 'Stack\x. NOTICE - sign in again at [recover](www.example.org) <b>now</b>.yml'
$igClean = ConvertTo-LaiIntegrityName -Name $igOddName
Assert-That ($igClean.Length -eq $igOddName.Length -and $igClean -notmatch '[\[\]()<>/]' -and $igClean -like 'Stack\x. NOTICE - sign in again at ?recover??www.example.org? ?b?now??b?.yml') "a name keeps letters, digits, space, dot, underscore, hyphen and backslash; everything a link or a tag is made of becomes '?' ($igClean)"
$igLong = ConvertTo-LaiIntegrityName -Name ('Stack\' + ('a' * 200) + '.yml')
Assert-That ($igLong.Length -eq 80 -and $igLong -like 'Stack\aaa*...*aaa.yml' -and (ConvertTo-LaiIntegrityName -Name "a`r`nb`tc") -eq 'a??b?c' -and (ConvertTo-LaiIntegrityName -Name 'Scripts\.git_ignore-1') -eq 'Scripts\.git_ignore-1' -and (ConvertTo-LaiIntegrityName -Name ('caf' + [char]0x00E9 + '"`')) -eq ('caf' + [char]0x00E9 + '??')) "a long name is cut in the middle to 80 characters, a line break cannot start a second line, quotes and backticks go ($igLong)"
$igOddText = [string]@(Compare-LaiIntegrity -Baseline @{ files = @{} } -Current @{ files = @{ $igOddName = 'H' } })[0].Text
$igOddNet = [string]@(Compare-LaiIntegrity -Baseline @{ files = @{}; listeners = @() } -Current @{ files = @{}; listeners = @(@{ Program = 'x" now [a](b) "y'; Port = 4444; Network = $true }) })[0].Text
Assert-That ($igOddText -eq ('"' + $igClean + '" is new') -and [regex]::Matches($igOddNet, '"').Count -eq 2 -and $igOddNet -notmatch '[\[\]]' -and $igOddNet -like '"x? now ?a??b? ?y" now accepts connections from other devices on port 4444') "in a difference the cleaned name stands in double quotes, and nothing in a name can end them ($igOddNet)"
# The baseline file can be edited by hand, and one bad row must not stop every comparison for good.
$igBadBase = @{ files = @{}; listeners = @(@{ Program = 'python'; Port = 'x'; Network = $true }, @{ Port = 8188; Network = $true }, 'junk', @{ Program = 'ollama'; Port = '11434'; Network = $false }) }
$igBadDiff = $null; $igBadErr = ''
try { $igBadDiff = @(Compare-LaiIntegrity -Baseline $igBadBase -Current @{ files = @{}; listeners = @(@{ Program = 'python'; Port = 8188; Network = $true }, @{ Program = 'ollama'; Port = 11434; Network = $false }) } -WatchedPorts @(11434)) } catch { $igBadErr = $_.Exception.Message }
Assert-That (-not $igBadErr -and @($igBadDiff).Count -eq 1 -and [string]@($igBadDiff)[0].Id -eq 'net|python|8188') "a listener row without a port number is no row: the comparison still runs, and reports what that row would have covered ($igBadErr)"
$igTempDiff = @(Compare-LaiIntegrity -Baseline @{ files = @{}; listeners = @(@{ Program = 'svchost'; Port = 0; Network = $true }, @{ Program = 'com.docker.backend'; Port = 50123; Network = $false }) } -Current @{ files = @{}; listeners = @(@{ Program = 'svchost'; Port = 49670; Network = $true }, @{ Program = 'svchost'; Port = 51111; Network = $true }, @{ Program = 'python'; Port = 50123; Network = $false }) } -WatchedPorts @(50123))
Assert-That ($igTempDiff.Count -eq 1 -and [string]$igTempDiff[0].Text -eq 'port 50123 is now held by "python" (it was "com.docker.backend")') "a baseline row with port 0 stands for all of a program's temporary ports; one of the stack's own ports keeps its number even up there ($(@($igTempDiff | ForEach-Object { [string]$_.Text }) -join '; '))"
$igRows = @(
    [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 11434; OwningProcess = [uint32]100 }, [pscustomobject]@{ LocalAddress = '::1'; LocalPort = 11434; OwningProcess = [uint32]100 },
    [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 3000; OwningProcess = [uint32]300 }, [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 3000; OwningProcess = [uint32]300 },
    [pscustomobject]@{ LocalAddress = '::'; LocalPort = 445; OwningProcess = [uint32]4 }, [pscustomobject]@{ LocalAddress = 'not-an-address'; LocalPort = 9; OwningProcess = [uint32]999 })
$igSet = ConvertTo-LaiListenerSet -Connections $igRows -ProcessNames @{ 100 = 'Ollama'; 300 = 'com.docker.backend'; 4 = 'System' }
$igLine = @(@($igSet) | ForEach-Object { '{0}:{1}:{2}' -f $_['Program'], $_['Port'], $_['Network'] }) -join ' '
Assert-That (@($igSet).Count -eq 4 -and $igLine -eq 'com.docker.backend:3000:True ollama:11434:False system:445:True unknown:9:True') "listener rows become one entry per program and port, reachable when any address is not loopback ($igLine)"
$igEmpty = ConvertTo-LaiListenerSet -Connections @() -ProcessNames @{}
Assert-That ($null -ne $igEmpty -and @($igEmpty).Count -eq 0) 'no listeners is an empty list, not "could not tell"'
Assert-That ((Format-LaiIntegrityList -Items @('a', 'b', 'c', 'd', 'e') -Max 3) -eq 'a; b; c and 2 more' -and (Format-LaiIntegrityList -Items @('a')) -eq 'a') 'a long list is cut for a notification and says how many more'

# The listeners a baseline keeps. An install carries a known one that is not running at that moment
# (it would otherwise be news after every update), but not for ever; the owner's acceptance records
# exactly what listens now.
$igDay = [datetime]::new(2026, 6, 1, 12, 0, 0)
$igCur = @(@{ Program = 'ollama'; Port = 11434; Network = $false }, @{ Program = 'svchost'; Port = 49664; Network = $true }, @{ Program = 'svchost'; Port = 49670; Network = $true },
    @{ Program = 'svchost'; Port = 135; Network = $true }, @{ Program = 'com.docker.backend'; Port = 50123; Network = $false })
$igKnown = @(
    @{ Program = 'python'; Port = 8188; Network = $true; Seen = '2026-05-20T10:00:00' }, @{ Program = 'steam'; Port = 27036; Network = $true; Seen = '2026-02-01T10:00:00' },
    @{ Program = 'later'; Port = 4444; Network = $true; Seen = '2099-01-01T00:00:00' }, @{ Program = 'undated'; Port = 5555; Network = $true },
    @{ Program = 'ollama'; Port = 11434; Network = $false; Seen = '2026-05-20T10:00:00' }, @{ Program = 'python'; Port = 'x'; Network = $true; Seen = '2026-05-20T10:00:00' })
$igRowText = { param($Rows) @(@($Rows) | ForEach-Object { '{0}:{1}:{2}' -f $_['Program'], $_['Port'], $_['Network'] }) }
$igCarried = ConvertTo-LaiListenerBaseline -Current $igCur -Known $igKnown -Carry -Now $igDay -WatchedPorts @(11434, 50123) -KnownSeen '2026-05-01T09:00:00'
$igCarriedText = & $igRowText $igCarried
Assert-That ($igCarriedText.Count -eq 6 -and $igCarriedText -contains 'ollama:11434:False' -and $igCarriedText -contains 'svchost:135:True' -and $igCarriedText -contains 'svchost:0:True' -and $igCarriedText -contains 'com.docker.backend:50123:False' -and $igCarriedText -contains 'python:8188:True' -and $igCarriedText -contains 'undated:5555:True') "an install keeps what listens now, the temporary ports as one row per program (port 0), and a known listener that is not running ($($igCarriedText -join ' '))"
Assert-That (@($igCarriedText | Where-Object { $_ -match '^(steam|later):' -or $_ -match ':x:' }).Count -eq 0) 'but not one last seen more than 90 days ago, one dated in the future, or a row without a port number'
$igSeenOf = { param($Program) [string]@(@($igCarried) | Where-Object { $_['Program'] -eq $Program -and [int]$_['Port'] -ne 135 -and [int]$_['Port'] -ne 0 })[0]['Seen'] }
Assert-That ((& $igSeenOf 'ollama') -eq '2026-06-01T12:00:00' -and (& $igSeenOf 'python') -eq '2026-05-20T10:00:00' -and (& $igSeenOf 'undated') -eq '2026-05-01T09:00:00') 'each row says when a baseline last saw it listening: now, the date it carried, or the date of its baseline when it had none'
$igExact = ConvertTo-LaiListenerBaseline -Current $igCur -Known $igKnown -Now $igDay -WatchedPorts @(11434, 50123) -KnownSeen '2026-05-01T09:00:00'
$igExactText = & $igRowText $igExact
Assert-That ($igExactText.Count -eq 4 -and @($igExactText | Where-Object { $_ -match '^(python|undated|steam|later):' }).Count -eq 0) "the owner's acceptance keeps exactly what listens now: a listener that was switched off is no longer accepted ($($igExactText -join ' '))"
$igNext = ConvertTo-LaiListenerBaseline -Current @(@{ Program = 'svchost'; Port = 50001; Network = $true }, @{ Program = 'svchost'; Port = 50002; Network = $true }) -Known @($igCarried) -Carry -Now ($igDay.AddDays(1)) -WatchedPorts @(11434, 50123)
Assert-That (@(@($igNext) | Where-Object { $_['Program'] -eq 'svchost' -and [int]$_['Port'] -eq 0 }).Count -eq 1 -and @(@($igNext) | Where-Object { [int]$_['Port'] -ge 49152 -and [int]$_['Port'] -ne 50123 }).Count -eq 0) 'update after update the temporary ports stay one row per program: the list does not grow by a row per port'

# Which differences are announced, and when (pure). A difference is told when two looks in a row
# found it; the looks count by what it is about, so a file rewritten in between is still told.
$igAt = [datetime]::new(2026, 6, 1, 12, 0, 0)
$igMake = { param($Id, $Tag) [pscustomobject]@{ Id = $Id; Key = ($Id + '|' + $Tag); Text = ($Id + ' differs') } }
$igNews = @(Select-LaiIntegrityNews -Diffs @((& $igMake 'file|Scripts\a' 'K2'), (& $igMake 'net|x|4444' 'K1')) -Told @() -Pending @('file|Scripts\a') -Now $igAt)
Assert-That ($igNews.Count -eq 1 -and [string]$igNews[0].Id -eq 'file|Scripts\a') 'seen on the last look, with whatever content: announced now; seen for the first time: waits for the next look'
$igToldA = @(@{ Id = 'file|Scripts\a'; Key = 'file|Scripts\a|K2'; At = $igAt.ToString('s') })
Assert-That (@(Select-LaiIntegrityNews -Diffs @((& $igMake 'file|Scripts\a' 'K2')) -Told $igToldA -Pending @() -Now ($igAt.AddHours(30))).Count -eq 0) 'told, and unchanged since: never again'
Assert-That (@(Select-LaiIntegrityNews -Diffs @((& $igMake 'file|Scripts\a' 'K3')) -Told $igToldA -Pending @() -Now ($igAt.AddHours(2))).Count -eq 0 -and @(Select-LaiIntegrityNews -Diffs @((& $igMake 'file|Scripts\a' 'K3')) -Told $igToldA -Pending @() -Now ($igAt.AddHours(25))).Count -eq 1) 'told, and changed again: news again, but at most once a day (a file rewritten all day is not a notice every half hour)'
$igManyDiffs = @(1..250 | ForEach-Object { & $igMake "file+|Stack\f$_" 'H' })
$igToldMany = @(Update-LaiIntegrityTold -Told @() -Announced $igManyDiffs -Diffs $igManyDiffs -Now $igAt)
Assert-That ($igToldMany.Count -eq 250 -and @(Select-LaiIntegrityNews -Diffs $igManyDiffs -Told $igToldMany -Pending @() -Now ($igAt.AddMinutes(15))).Count -eq 0) "250 differences announced at once all stay told: none of them is news again on the next run ($($igToldMany.Count) kept)"
# What the watch keeps is bounded: thousands of differences with long names would grow
# watch-state.json past what Windows PowerShell 5.1 reads back, and the watch would lose its memory.
$igHuge = @(1..400 | ForEach-Object { & $igMake ('file|Scripts\f{0:D4}' -f $_) 'H' }) + @((& $igMake 'task+|LocalAI-Helper' 'T'), (& $igMake 'net|x|4444' ''))
$igCut = @(Limit-LaiIntegrityFound -Diffs $igHuge)
$igCutIds = @($igCut | ForEach-Object { [string]$_.Id })
Assert-That ($igCut.Count -eq 301 -and $igCutIds -contains 'task+|LocalAI-Helper' -and $igCutIds -contains 'net|x|4444' -and $igCutIds -contains 'file|Scripts\f0001' -and $igCutIds -notcontains 'file|Scripts\f0400' -and [string]$igCut[-1].Id -eq 'more|Scripts' -and [string]$igCut[-1].Key -eq 'more|Scripts|102' -and [string]$igCut[-1].Text -eq '102 more differences than are listed here') "402 differences are kept as 300 and one line for the rest; a task and a listener are never the ones cut ($([string]$igCut[-1].Text))"
Assert-That (@(Limit-LaiIntegrityFound -Diffs $igManyDiffs).Count -eq 250 -and [string]@(Limit-LaiIntegrityFound -Diffs @(1..310 | ForEach-Object { & $igMake "file+|Stack\f$_" 'H' }))[-1].Id -eq 'more|other' -and @(Limit-LaiIntegrityFound -Diffs @()).Count -eq 0) 'fewer than that are left as they are; what was cut says whether a script is among it (that decides the advice)'
$igCutTold = @(Update-LaiIntegrityTold -Told @() -Announced $igCut -Diffs $igCut -Now $igAt)
Assert-That ($igCutTold.Count -eq 301 -and @(Select-LaiIntegrityNews -Diffs @(Limit-LaiIntegrityFound -Diffs $igHuge) -Told $igCutTold -Pending @() -Now ($igAt.AddMinutes(15))).Count -eq 0) 'and the same 402 on the next run are the same 301: told once, not in rotation'
$igGone = @(1..230 | ForEach-Object { & $igMake "net|prog$_|4444" 'K' })
$igToldAll = @(Update-LaiIntegrityTold -Told $igToldMany -Announced $igGone -Diffs $igManyDiffs -Now $igAt)
$igToldIds = @($igToldAll | ForEach-Object { [string]$_['Id'] })
Assert-That ($igToldAll.Count -eq 450 -and @($igToldIds | Where-Object { $_ -like 'file+|*' }).Count -eq 250 -and $igToldIds -contains 'net|prog230|4444' -and $igToldIds -notcontains 'net|prog30|4444') "only what is no longer found is ever forgotten (the 200 told last are kept: a program that listens while it runs is not news at every start) ($($igToldAll.Count) kept)"

# What to do about a change nobody meant to make. Every Local AI shortcut starts a script from
# <AIRoot>\Scripts, and Update toolkit then asks for administrator rights: when the scripts are what
# changed, neither may be the advice.
$igAdvIds = @('net|x|4444', 'file|Scripts\Get-LocalAI.ps1')
$igBrief = Get-LaiIntegrityAdvice -Ids $igAdvIds -AIRoot 'C:\AI' -Brief
$igLongAdv = Get-LaiIntegrityAdvice -Ids $igAdvIds -AIRoot 'C:\AI'
Assert-That ($igBrief -notmatch 'Start menu|Health check|Update toolkit' -and $igBrief -match 'do not use the Local AI shortcuts' -and $igBrief -like '*"C:\AI\Logs\watch.log"*' -and $igBrief -match 'fresh copy of the toolkit') "a changed script: the notification names no shortcut, but watch.log and a fresh copy of the toolkit ($igBrief)"
Assert-That ($igLongAdv -match 'do not repair this with Update toolkit' -and $igLongAdv -notmatch 'Start menu >' -and $igLongAdv -match 'fresh copy of the toolkit' -and $igLongAdv -match 'administrator rights') 'and the health check says not to use Update toolkit for it, and why'
$igUntrusted = @('file+|Scripts\lib\new.psm1', 'file-|Scripts\x.ps1', 'files+|Scripts\lib', 'file|Scripts', 'walk|Scripts', 'more|Scripts', 'baseline|gone')
Assert-That (@($igUntrusted | Where-Object { (Get-LaiIntegrityAdvice -Ids @($_) -AIRoot 'C:\AI' -Brief) -match 'Start menu' }).Count -eq 0) 'the same for a new or deleted script, a Scripts folder swapped for a link or not read to the end, and a baseline that is gone'
$igOtherIds = @('file|Stack\docker-compose.yml', 'file+|Stack\Scripts\x.yml', 'task+|LocalAI-Helper', 'net|x|4444', 'env|OLLAMA_UPSTREAM', 'walk|Stack')
$igBriefOther = Get-LaiIntegrityAdvice -Ids $igOtherIds -AIRoot 'C:\AI' -Brief
$igLongOther = Get-LaiIntegrityAdvice -Ids $igOtherIds -AIRoot 'C:\AI'
Assert-That ($igBriefOther -match 'open Start menu > Local AI - Health check') 'for Stack, settings, tasks and listeners the health check shortcut is named'
Assert-That ($igLongOther -match 'first remove what was added' -and $igLongOther -match 'then run Start menu > Local AI - Update toolkit' -and $igLongOther -match 'records everything else it finds as the new baseline' -and $igLongOther -like '*"C:\AI\Stack"*' -and $igLongOther -match 'Task Scheduler') "and the health check says that Update toolkit is no undo: what was added has to be removed first, and where ($igLongOther)"

# An install that got somewhere after the baseline and did not finish is told from the installer's
# own record (a stage it finished), never from a log file: every run writes one, also a run that
# was refused, and anybody can drop a file named like one into Logs.
$igNowU = [datetime]::new(2026, 6, 10, 12, 0, 0); $igSinceU = [datetime]::new(2026, 6, 9, 8, 0, 0)
$igInstState = Join-Path $igRoot 'install-state.json'
foreach ($n in 'install-20260610-110000.log', 'install-20991231-000000.log') { Set-Content -LiteralPath (Join-Path (Join-Path $igRoot 'Logs') $n) -Value 'x' }
Assert-That ($null -eq (Get-LaiUnfinishedInstall -AIRoot $igRoot -Since $igSinceU -Now $igNowU)) 'installer logs dated after the baseline (one of them in the future) are no unfinished install'
Save-LaiState -State @{ stages = @{ Preflight = '2026-06-09T07:00:00'; Ollama = '2026-06-10T11:30:00'; Models = '2099-12-31T00:00:00' } } -Path $igInstState
Assert-That ((Get-LaiUnfinishedInstall -AIRoot $igRoot -Since $igSinceU -Now $igNowU) -eq [datetime]::new(2026, 6, 10, 11, 30, 0)) 'a stage the installer finished after the baseline is: the newest one that is not dated in the future'
Assert-That ($null -eq (Get-LaiUnfinishedInstall -AIRoot $igRoot -Since $igSinceU -Now ($igNowU.AddHours(60))) -and $null -eq (Get-LaiUnfinishedInstall -AIRoot $igRoot -Since ([datetime]::new(2026, 6, 10, 11, 30, 0)) -Now $igNowU)) 'not for ever (two days), and not a stage finished before the baseline was recorded'
Remove-Item -LiteralPath $igInstState -Force

# A baseline through the state file (Windows PowerShell 5.1 reads JSON its own way).
$igSaved = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'test' -TaskPattern 'LaiNoSuchTask-*'
$igRead = Read-LaiIntegrityBaseline -AIRoot $igRoot
Assert-That ($igRead -and [string]$igRead['id'] -eq [string]$igSaved['id'] -and $igRead['files'] -is [hashtable] -and [string]$igRead['files']['Scripts\lib\helper.psm1'] -eq [string]$igFiles['Scripts\lib\helper.psm1'] -and $igRead['env'] -is [hashtable] -and [string]$igRead['env']['OLLAMA_BASE_URL'] -eq [string]$igEnvNow['OLLAMA_BASE_URL']) 'a baseline survives being saved and read back (its id, paths with backslashes, hashes, the settings)'
Assert-That (@($igRead['accepted']).Count -eq 0 -and [int]$igRead['acceptedCount'] -eq 0) 'the first baseline took nothing in: there was none before it'
Assert-That (@(Compare-LaiIntegrity -Baseline $igRead -Current (Get-LaiIntegritySnapshot -AIRoot $igRoot -TaskPattern 'LaiNoSuchTask-*') | Where-Object { $_.Key -notmatch '^(net|port)\|' }).Count -eq 0) 'and the same folder compared with it shows no difference'
Assert-That ((Split-Path -Leaf (Split-Path -Parent (Get-LaiIntegrityPath -AIRoot $igRoot))) -eq 'integrity' -and (Get-LaiIntegritySummary -Baseline $igRead) -match '^4 files, ') "the baseline is kept in the install folder itself, outside the folders it describes ($(Get-LaiIntegritySummary -Baseline $igRead))"
Set-Content -LiteralPath $igTool -Value 'changed outside an update'
Set-Content -LiteralPath $igEnvFile -Value @('A=2', 'OLLAMA_BASE_URL=http://elsewhere.example:11434', 'WEBUI_SECRET_KEY=another')
$igChanged = @(Compare-LaiIntegrity -Baseline $igRead -Current (Get-LaiIntegritySnapshot -AIRoot $igRoot -TaskPattern 'LaiNoSuchTask-*') | Where-Object { $_.Key -notmatch '^(net|port)\|' } | ForEach-Object { [string]$_.Text })
Assert-That ($igChanged.Count -eq 2 -and $igChanged -contains '"Scripts\tool.ps1" was changed' -and $igChanged -contains 'the setting "OLLAMA_BASE_URL" in Stack\.env was changed') "a script edited after the baseline is named, and so is a changed Ollama address in .env; its other lines are not watched ($($igChanged -join '; '))"
# A new baseline takes in whatever is there. Recorded by hand it lists all of it (the watch then
# says so: anything running as the owner can paste that command).
$igHand = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*'
$igHandRead = @((Read-LaiIntegrityBaseline -AIRoot $igRoot)['accepted'] | Where-Object { $_ -is [hashtable] -and [string]$_['Id'] -notmatch '^(net|port)\|' })
Assert-That ($igHandRead.Count -eq 2 -and @($igHandRead | Where-Object { [string]$_['Id'] -eq 'file|Scripts\tool.ps1' -and [string]$_['Text'] -eq '"Scripts\tool.ps1" was changed' }).Count -eq 1 -and @($igHandRead | Where-Object { [string]$_['Id'] -eq 'env|OLLAMA_BASE_URL' }).Count -eq 1 -and [int]$igHand['acceptedCount'] -ge 2) "a baseline recorded by hand lists what it took in, and the list survives the state file ($(@($igHandRead | ForEach-Object { [string]$_['Text'] }) -join '; '))"
# Recorded by an install it lists only what the installer did not put there itself: not its own
# copies, not the tasks and settings it writes. Update toolkit keeps everything else it finds.
$igSource = Join-Path $Work 'integrity-source'
New-Item -ItemType Directory -Force -Path (Join-Path $igSource 'stack') | Out-Null
Set-Content -LiteralPath (Join-Path $igSource 'tool.ps1') -Value 'the next version'
Set-Content -LiteralPath (Join-Path (Join-Path $igSource 'stack') 'docker-compose.yml') -Value 'services: { next: {} }'
Copy-Item -LiteralPath (Join-Path $igSource 'tool.ps1') -Destination $igTool -Force
Copy-Item -LiteralPath (Join-Path (Join-Path $igSource 'stack') 'docker-compose.yml') -Destination (Join-Path $igStack 'docker-compose.yml') -Force
Set-Content -LiteralPath (Join-Path $igStack 'planted.yml') -Value 'x'
Set-Content -LiteralPath $igHelper -Value 'edited, and not a file this installer ships'
Set-Content -LiteralPath $igEnvFile -Value @('A=2', 'OLLAMA_BASE_URL=http://render-guard:11434', 'OLLAMA_UPSTREAM=http://elsewhere.example:11434')
$igInstalled = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igSource -OwnTasks @('LocalAI-Watch') -OwnSettings @('OLLAMA_BASE_URL')
$igKeptText = @($igInstalled['accepted'] | Where-Object { [string]$_['Id'] -notmatch '^(net|port)\|' } | ForEach-Object { [string]$_['Text'] })
Assert-That ($igKeptText.Count -eq 3 -and $igKeptText -contains '"Stack\planted.yml" is new' -and $igKeptText -contains '"Scripts\lib\helper.psm1" was changed' -and $igKeptText -contains 'the setting "OLLAMA_UPSTREAM" was added to Stack\.env') "a baseline recorded by an install lists the added file, the changed file it does not ship and the setting it does not write ($($igKeptText -join '; '))"
Assert-That (@($igKeptText | Where-Object { $_ -match 'tool\.ps1|docker-compose|OLLAMA_BASE_URL' }).Count -eq 0) 'and none of its own: the files it copied and the setting it wrote'
Set-Content -LiteralPath $igTool -Value 'changed, and the installer was started from the installed copy'
$igSelf = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts
Assert-That (@($igSelf['accepted'] | Where-Object { [string]$_['Id'] -eq 'file|Scripts\tool.ps1' }).Count -eq 1) 'an installer run from the installed folder copies no scripts, so a changed script is not its own work'
# What one baseline took in is still listed by the next one until somebody has looked: a second
# update minutes after the first must not record an empty list and so clear every report.
$igIds = { param($Baseline) @($Baseline['accepted'] | Where-Object { $_ -is [hashtable] -and [string]$_['Id'] -notmatch '^(net|port)\|' } | ForEach-Object { [string]$_['Id'] }) }
$igSelfIds = @(& $igIds $igSelf)
Assert-That ($igSelfIds -contains 'file+|Stack\planted.yml' -and $igSelfIds -contains 'file|Scripts\lib\helper.psm1' -and $igSelfIds -contains 'env+|OLLAMA_UPSTREAM' -and [int]$igSelf['acceptedCount'] -ge 4) "a second install right after the first still lists what the first one kept ($($igSelfIds -join '; '))"
Assert-That (@($igSelfIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) 'each of them once'
Remove-Item -LiteralPath (Join-Path $igStack 'planted.yml') -Force
$igWatchState = Join-Path $igRoot 'watch-state.json'
if (Test-Path -LiteralPath $igWatchState) { Remove-Item -LiteralPath $igWatchState -Force }
$igThird = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts
$igThirdIds = @(& $igIds $igThird)
Assert-That ($igThirdIds -contains 'file|Scripts\lib\helper.psm1' -and $igThirdIds -contains 'file|Scripts\tool.ps1' -and @($igThirdIds | Where-Object { $_ -like '*planted.yml' }).Count -eq 0) "a third install carries them on, but not the added file that was removed in between ($($igThirdIds -join '; '))"
# The owner records a baseline by hand, with an edit of their own, and the watch has not run since
# the update (there is no watch-state.json). The acceptance names the edit and, once more, what the
# updates before it had kept: accepting is what settles that.
$igSettledIds = { param($Baseline) @($Baseline['accepted'] | Where-Object { $_ -is [hashtable] -and $_['Settled'] } | ForEach-Object { [string]$_['Id'] }) }
Set-Content -LiteralPath $igHelper -Value 'edited once more, by the owner'
$igOnce = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*'
$igOnceIds = @(& $igIds $igOnce); $igOnceSettled = @(& $igSettledIds $igOnce)
Assert-That ($igOnceIds -contains 'file|Scripts\lib\helper.psm1' -and $igOnceIds -contains 'file|Scripts\tool.ps1' -and $igOnceIds -contains 'env+|OLLAMA_UPSTREAM') "a baseline recorded by hand names what it takes in itself and what the update before it had kept ($($igOnceIds -join '; '))"
Assert-That ($igOnceSettled -contains 'file|Scripts\tool.ps1' -and $igOnceSettled -contains 'env+|OLLAMA_UPSTREAM' -and $igOnceSettled -notcontains 'file|Scripts\lib\helper.psm1') "what the update had kept is marked as settled by this acceptance; the owner's own edit is not ($($igOnceSettled -join '; '))"
# Recorded by hand again, still before the watch has had its turn with the first: all of it is
# named again, also what the first acceptance settled. Anything running as the owner can record a
# baseline, and the watch's notice is what shows one the owner did not make: a second acceptance
# that recorded an empty list would leave the watch nothing to say about what the update had kept.
$igAgain = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*'
$igAgainIds = @(& $igIds $igAgain); $igAgainSettled = @(& $igSettledIds $igAgain)
Assert-That ($igAgainIds -contains 'file|Scripts\lib\helper.psm1' -and $igAgainIds -contains 'file|Scripts\tool.ps1' -and $igAgainIds -contains 'env+|OLLAMA_UPSTREAM') "the acceptance command run twice before the watch has announced the first still lists what was taken in ($($igAgainIds -join '; '))"
Assert-That ($igAgainSettled -contains 'file|Scripts\tool.ps1' -and $igAgainSettled -contains 'env+|OLLAMA_UPSTREAM' -and $igAgainSettled -notcontains 'file|Scripts\lib\helper.psm1') "what the first acceptance settled is still marked as settled there, and nothing else is ($($igAgainSettled -join '; '))"
# The watch has had its turn with that baseline: it wrote the list to watch.log and tried to announce
# it, and the notification failed ('tried' and no 'announced': on a PC where none ever goes out that
# is all there will ever be). What an acceptance settled is done with then, or it would be listed
# by every acceptance and every update for good. What the acceptance took in itself still waits
# for a notification that went out.
Save-LaiState -State @{ integrity = @{ baseline = [string]$igAgain['id']; tried = [string]$igAgain['id'] } } -Path $igWatchState
$igTried = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*'
$igTriedIds = @(& $igIds $igTried)
Assert-That ($igTriedIds -notcontains 'file|Scripts\tool.ps1' -and $igTriedIds -notcontains 'env+|OLLAMA_UPSTREAM') "once the watch has tried to announce a baseline, the next one no longer lists what an acceptance had settled, although no notification went out ($($igTriedIds -join '; '))"
Assert-That ($igTriedIds -contains 'file|Scripts\lib\helper.psm1') "what the acceptance took in itself is still listed: that waits for a notification that went out ($($igTriedIds -join '; '))"
# Once the watch has announced a baseline recorded by hand, the owner has been told: settled.
Save-LaiState -State @{ integrity = @{ baseline = [string]$igTried['id']; announced = [string]$igTried['id'] } } -Path $igWatchState
$igSettled = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts
Assert-That (@(& $igIds $igSettled).Count -eq 0) "an install after an acceptance the watch has announced does not list it again ($(@(& $igIds $igSettled) -join '; '))"
foreach ($f in $igWatchState, "$igWatchState.bak") { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
# More kept than any report shows. An update keeps 60 added files, and the update after it must
# still list every one of them: a list cut to what is shown lost the last ten right there, with
# nobody having looked, and with them a planted file behind fifty decoy names.
$igMany = Join-Path $igStack 'many'
New-Item -ItemType Directory -Force -Path $igMany | Out-Null
foreach ($i in 1..60) { Set-Content -LiteralPath (Join-Path $igMany ('added{0:D2}.yml' -f $i)) -Value "added $i" }
$igManyIds = { param($Baseline) @($Baseline['accepted'] | Where-Object { $_ -is [hashtable] -and [string]$_['Id'] -like 'file*|Stack\many\*' } | ForEach-Object { [string]$_['Id'] }) }
$igSixty = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts
$igSixtyNext = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts
$igSixtyIds = @(& $igManyIds $igSixty); $igSixtyNextIds = @(& $igManyIds $igSixtyNext)
Assert-That ($igSixtyIds.Count -eq 60 -and [int]$igSixty['acceptedCount'] -ge 60) "an update that keeps 60 added files lists every one of them by name ($($igSixtyIds.Count) listed, $([int]$igSixty['acceptedCount']) counted)"
Assert-That ($igSixtyNextIds.Count -eq 60 -and $igSixtyNextIds -contains 'file+|Stack\many\added60.yml' -and [int]$igSixtyNext['acceptedCount'] -ge 60) "the update after it carries all 60, the last one too: none leaves the reports with nobody having looked ($($igSixtyNextIds.Count) listed, $([int]$igSixtyNext['acceptedCount']) counted)"
# The owner accepts them by hand before the watch has run (no watch-state.json). The acceptance
# names what it settles, all 60. The acceptance run again, and an update after that, still list
# every one, still marked: an empty list there, before the watch's next run, and a planted file
# among them would have left every report without being in any notice. The watch's word about a
# baseline other than the one before does not count either.
$igManySettled = { param($Baseline) @(& $igSettledIds $Baseline | Where-Object { $_ -like 'file*|Stack\many\*' }) }
$igByHand = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*'
$igHandAgain = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*'
Save-LaiState -State @{ integrity = @{ baseline = [string]$igByHand['id']; tried = [string]$igByHand['id'] } } -Path $igWatchState
$igHandUpdate = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts
# The watch has had its turn with that last baseline, and no notification went out. Settled is
# settled then: the next update lists none of them. Before, they were listed at every acceptance
# and every update on a PC where no notification ever goes out.
Save-LaiState -State @{ integrity = @{ baseline = [string]$igHandUpdate['id']; tried = [string]$igHandUpdate['id'] } } -Path $igWatchState
$igAfterHand = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts
foreach ($f in $igWatchState, "$igWatchState.bak") { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
$igByHandIds = @(& $igManyIds $igByHand); $igByHandSettled = @(& $igManySettled $igByHand)
$igHandAgainIds = @(& $igManyIds $igHandAgain); $igHandUpdateIds = @(& $igManyIds $igHandUpdate); $igAfterHandIds = @(& $igManyIds $igAfterHand)
Assert-That ($igByHandIds.Count -eq 60 -and $igByHandSettled.Count -eq 60) "accepting by hand names what the update had kept, marked as settled by that ($($igByHandSettled.Count) of $($igByHandIds.Count) listed)"
Assert-That ($igHandAgainIds.Count -eq 60 -and @(& $igManySettled $igHandAgain).Count -eq 60 -and [int]$igHandAgain['acceptedCount'] -ge 60) "the acceptance run again before the watch has had its turn still lists all 60, still marked as settled ($($igHandAgainIds.Count) listed, $([int]$igHandAgain['acceptedCount']) counted)"
Assert-That ($igHandUpdateIds.Count -eq 60 -and @(& $igManySettled $igHandUpdate).Count -eq 60) "and so does an update after it, when the watch has only had its turn with a baseline before that one ($($igHandUpdateIds.Count) listed)"
Assert-That ($igAfterHandIds.Count -eq 0) "once the watch has had its turn with a baseline that lists them as settled, the next update lists none of them, without any notification having gone out ($($igAfterHandIds.Count) listed)"
# No list is without end. With room for five names (-MaxListed: a thousand unless told otherwise),
# what does not fit is one entry that stands for the rest, and the count still has all of it.
foreach ($i in 1..8) { Set-Content -LiteralPath (Join-Path $igMany "late$i.yml") -Value "late $i" }
$igNamedOf = { param($Baseline) @($Baseline['accepted'] | Where-Object { $_ -is [hashtable] -and [string]$_['Id'] -notlike 'more|*' }) }
$igMoreOf = { param($Baseline) @($Baseline['accepted'] | Where-Object { $_ -is [hashtable] -and [string]$_['Id'] -like 'more|*' }) }
$igFew = $null; $igFewNext = $null; $igFewThird = $null; $igFewHand = $null; $igFewHandAgain = $null; $igFewAfter = $null; $igFewErr = ''
try {
    $igFew = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts -MaxListed 5
    # That baseline as one was recorded when the list was cut at 50: some names, the true count,
    # and nothing that stands for the rest.
    $igOldStyle = Read-LaiIntegrityBaseline -AIRoot $igRoot
    $igOldStyle['accepted'] = @($igOldStyle['accepted'] | Where-Object { $_ -is [hashtable] -and [string]$_['Id'] -notlike 'more|*' })
    Save-LaiState -State $igOldStyle -Path (Get-LaiIntegrityPath -AIRoot $igRoot)
    $igFewNext = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts -MaxListed 5
    $igFewThird = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts -MaxListed 5
    $igFewHand = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*' -MaxListed 5
    # Accepted again before the watch has had its turn (no watch-state.json), then the watch has
    # it (tried, no notification went out), then an update.
    $igFewHandAgain = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*' -MaxListed 5
    Save-LaiState -State @{ integrity = @{ baseline = [string]$igFewHandAgain['id']; tried = [string]$igFewHandAgain['id'] } } -Path $igWatchState
    $igFewAfter = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' -TaskPattern 'LaiNoSuchTask-*' -SourceRoot $igScripts
} catch { $igFewErr = $_.Exception.Message }
foreach ($f in $igWatchState, "$igWatchState.bak") { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
$igFewMore = @(); $igNextMore = @(); $igThirdMore = @(); $igHandMore = @(); $igHandAgainMore = @(); $igFewCount = 0; $igHandAgainCount = 0
if (-not $igFewErr) { $igFewMore = @(& $igMoreOf $igFew); $igNextMore = @(& $igMoreOf $igFewNext); $igThirdMore = @(& $igMoreOf $igFewThird); $igHandMore = @(& $igMoreOf $igFewHand); $igHandAgainMore = @(& $igMoreOf $igFewHandAgain); $igFewCount = [int]$igFew['acceptedCount']; $igHandAgainCount = [int]$igFewHandAgain['acceptedCount'] }
Assert-That (-not $igFewErr -and @(& $igNamedOf $igFew).Count -eq 5 -and $igFewMore.Count -eq 1 -and [string]$igFewMore[0]['Id'] -eq 'more|other' -and [string]$igFewMore[0]['Text'] -eq ('{0} more than are listed here' -f ($igFewCount - 5)) -and $igFewCount -ge 8) "eight kept and room for five names: five are named, one entry stands for the rest, and the count has them all ($igFewCount counted) $igFewErr"
Assert-That (-not $igFewErr -and $igNextMore.Count -eq 1 -and [string]$igNextMore[0]['Id'] -eq 'more|Scripts' -and [int]$igFewNext['acceptedCount'] -ge 8 -and [string]$igNextMore[0]['Text'] -eq ('{0} more than are listed here' -f ([int]$igFewNext['acceptedCount'] - @(& $igNamedOf $igFewNext).Count))) "a baseline that counted more than it named: the next update carries the rest on as a number, and cannot rule out that a script is among it $igFewErr"
Assert-That (-not $igFewErr -and $igThirdMore.Count -eq 1 -and [string]$igThirdMore[0]['Id'] -eq 'more|Scripts' -and -not $igThirdMore[0]['Settled'] -and [int]$igFewThird['acceptedCount'] -ge 8) "update after update that number stays: the count does not shrink while nobody has accepted what it stands for $igFewErr"
Assert-That (-not $igFewErr -and $igHandMore.Count -eq 1 -and $igHandMore[0]['Settled'] -and [int]$igFewHand['acceptedCount'] -ge 8) "the owner's acceptance names it once more and settles it, the unnamed rest as well $igFewErr"
Assert-That (-not $igFewErr -and $igHandAgainMore.Count -eq 1 -and $igHandAgainMore[0]['Settled'] -and [string]$igHandAgainMore[0]['Id'] -eq 'more|Scripts' -and $igHandAgainCount -ge 8 -and @(& $igManyIds $igFewHandAgain).Count -ge 1 -and @(& $igManySettled $igFewHandAgain).Count -eq @(& $igManyIds $igFewHandAgain).Count) "accepted again before the watch has had its turn, the count has not shrunk: the names and the unnamed rest are still listed, still marked as settled ($igHandAgainCount counted) $igFewErr"
Assert-That (-not $igFewErr -and @(& $igMoreOf $igFewAfter).Count -eq 0 -and @(& $igManyIds $igFewAfter).Count -eq 0) "once the watch has had its turn the update after that lists none of it, names or number $igFewErr"
# Whether the watch has announced a baseline is read from watch-state.json, which the watch replaces
# every few minutes. A read that fails must not keep the baseline from being recorded (the watch
# would then report the whole update as changes), and counts as 'not announced': carried.
Set-Content -LiteralPath (Join-Path $igMany 'added01.yml') -Value 'changed by the owner'
$igMine = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*'
# Something of that name that cannot be read as a file.
New-Item -ItemType Directory -Force -Path $igWatchState | Out-Null
$igUnread = $null; $igUnreadErr = ''
try { $igUnread = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*' } catch { $igUnreadErr = $_.Exception.Message }
Remove-Item -LiteralPath $igWatchState -Force
Assert-That (@(& $igManyIds $igMine) -contains 'file|Stack\many\added01.yml' -and -not $igUnreadErr -and $igUnread -and @(& $igManyIds $igUnread) -contains 'file|Stack\many\added01.yml') "a watch-state.json that cannot be read does not stop the baseline from being recorded, and what the one before it took in is carried ($igUnreadErr)"
if ($onWindows) {
    # The file itself, saying that the baseline in use was announced, held by another handle the way
    # it is while the watch replaces it. Unreadable is not 'announced'; read again, it is.
    $igOnDisk = [string](Read-LaiIntegrityBaseline -AIRoot $igRoot)['id']
    Save-LaiState -State @{ integrity = @{ baseline = $igOnDisk; announced = $igOnDisk } } -Path $igWatchState
    $igHeld = [System.IO.File]::Open($igWatchState, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $igHeldSave = $null; $igHeldErr = ''; $igReadSave = $null
    try { $igHeldSave = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*' } catch { $igHeldErr = $_.Exception.Message } finally { $igHeld.Dispose() }
    if ($igHeldSave) {
        Save-LaiState -State @{ integrity = @{ baseline = [string]$igHeldSave['id']; announced = [string]$igHeldSave['id'] } } -Path $igWatchState
        $igReadSave = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*'
    }
    Assert-That (-not $igHeldErr -and $igHeldSave -and @(& $igManyIds $igHeldSave) -contains 'file|Stack\many\added01.yml') "held open by another handle, a watch-state.json that says 'announced' is not taken for that: the baseline is recorded, and carries ($igHeldErr)"
    Assert-That ($igReadSave -and @(& $igManyIds $igReadSave) -notcontains 'file|Stack\many\added01.yml') 'readable again and saying so, it is: what the watch has announced is not carried'
    foreach ($f in $igWatchState, "$igWatchState.bak") { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
} else { Skip 'a watch-state.json held open by another handle (the read fails with a sharing violation) is a Windows case' }
# A baseline recorded by hand while the folders hold more than is read says that the rest was not
# compared. That names no single thing that could be gone again: a second acceptance, before the
# watch has announced the first, still says it.
$igWalk1 = $null; $igWalk2 = $null; $igWalkErr = ''
try {
    $igWalk1 = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*' -Budget (New-LaiIntegrityBudget -MaxEntries 4)
    $igWalk2 = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' -TaskPattern 'LaiNoSuchTask-*' -Budget (New-LaiIntegrityBudget -MaxEntries 4)
} catch { $igWalkErr = $_.Exception.Message }
$igWalkText = { param($Baseline) (@($Baseline['accepted'] | Where-Object { $_ -is [hashtable] -and [string]$_['Id'] -eq 'walk|Stack' } | ForEach-Object { [string]$_['Text'] }) -join ' | ') }
$igWalkOne = ''; $igWalkTwo = ''
if (-not $igWalkErr) { $igWalkOne = [string](& $igWalkText $igWalk1); $igWalkTwo = [string](& $igWalkText $igWalk2) }
Assert-That (-not $igWalkErr -and [string]$igWalk1['filesStopped'] -eq 'Stack' -and $igWalkOne -like 'reading "Stack" stopped at*the rest was not compared') "a baseline recorded by hand while the walk stops says that the rest was not compared ($igWalkOne) $igWalkErr"
Assert-That (-not $igWalkErr -and $igWalkTwo -and $igWalkTwo -eq $igWalkOne) "and the acceptance run again still says it ($igWalkTwo) $igWalkErr"
Remove-Item -LiteralPath $igMany -Recurse -Force
$igStillSnap = @{ files = @{ 'Stack\a.yml' = 'x'; 'Stack\sub\b.yml' = 'x' }; filesStopped = ''; env = @{ OLLAMA_UPSTREAM = 'x' }; tasks = $null; listeners = @(@{ Program = 'python'; Port = 8000; Network = $true }, @{ Program = 'ollama'; Port = 11434; Network = $false }) }
Assert-That ((Test-LaiIntegrityStill -Id 'file+|Stack\a.yml' -Snapshot $igStillSnap) -and (Test-LaiIntegrityStill -Id 'files+|Stack\sub' -Snapshot $igStillSnap) -and (Test-LaiIntegrityStill -Id 'file-|Stack\gone.yml' -Snapshot $igStillSnap) -and (Test-LaiIntegrityStill -Id 'env|OLLAMA_UPSTREAM' -Snapshot $igStillSnap) -and (Test-LaiIntegrityStill -Id 'net|python|8000' -Snapshot $igStillSnap) -and (Test-LaiIntegrityStill -Id 'port|11434|ollama' -Snapshot $igStillSnap)) 'still so: a file and a folder that are there, a file that is still gone, a setting that is set, a program that still listens'
Assert-That (-not (Test-LaiIntegrityStill -Id 'file+|Stack\removed.yml' -Snapshot $igStillSnap) -and -not (Test-LaiIntegrityStill -Id 'file-|Stack\a.yml' -Snapshot $igStillSnap) -and -not (Test-LaiIntegrityStill -Id 'env+|OTHER_URL' -Snapshot $igStillSnap) -and -not (Test-LaiIntegrityStill -Id 'net|ollama|11434' -Snapshot $igStillSnap) -and -not (Test-LaiIntegrityStill -Id 'net|steam|27036' -Snapshot $igStillSnap) -and -not (Test-LaiIntegrityStill -Id 'walk|Stack' -Snapshot $igStillSnap) -and -not (Test-LaiIntegrityStill -Id 'more|other' -Snapshot $igStillSnap)) 'no longer so: a removed file, a file that came back, a removed setting, a program that listens on this PC only or not at all; and nothing that names no single thing'
Assert-That ((Test-LaiIntegrityStill -Id 'task+|LocalAI-Other' -Snapshot $igStillSnap) -and (Test-LaiIntegrityStill -Id 'file+|Stack\z.yml' -Snapshot @{ files = @{}; filesStopped = 'Stack\m' })) 'what could not be read (tasks here, files after a walk that stopped early) counts as still so'
$igOwn = { param($Id) Test-LaiIntegrityOwn -Difference ([pscustomobject]@{ Id = $Id }) -Snapshot @{ files = @{} } -AIRoot $igRoot -SourceRoot $igSource -OwnTasks @('LocalAI-Watch') -OwnSettings @('OLLAMA_BASE_URL') }
Assert-That ((& $igOwn 'task|LocalAI-Watch') -and (& $igOwn 'env|OLLAMA_BASE_URL') -and (& $igOwn 'file-|Stack\gone.yml') -and (& $igOwn 'task-|LocalAI-Old')) 'its own: a task it registers, a setting it writes, and whatever is gone (nothing is taken in)'
Assert-That (-not (& $igOwn 'task+|LocalAI-Helper') -and -not (& $igOwn 'task|LocalAI-Other') -and -not (& $igOwn 'env+|OLLAMA_UPSTREAM') -and -not (& $igOwn 'net|x|4444') -and -not (& $igOwn 'port|3000|x') -and -not (& $igOwn 'walk|Stack') -and -not (& $igOwn 'file+|Stack\nowhere.yml')) 'not its own: another LocalAI-* task, another setting, a new listener, a file it has no copy of'
Set-Content -LiteralPath $igTool -Value 'original'

# The one place that makes 'an update is never reported as a change' true is the end of the
# installer. Read from its source: after the last stage and after the resume task is removed, in a
# try of its own (a baseline that cannot be written must not fail an install that worked), and
# telling the baseline what the installer put there itself.
$igInstAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Install-LocalAI.ps1'), [ref]$null, [ref]$null)
$igCmds = @($igInstAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
$igSaveCalls = @($igCmds | Where-Object { $_.GetCommandName() -eq 'Save-LaiIntegrityBaseline' })
$igStages = @($igCmds | Where-Object { $_.GetCommandName() -eq 'Invoke-Stage' } | Sort-Object { $_.Extent.StartOffset })
$igAfterStages = -1; if ($igStages.Count) { $igAfterStages = $igStages[-1].Extent.EndOffset }
$igResumeGone = @($igCmds | Where-Object { $_.GetCommandName() -eq 'Unregister-ScheduledTask' -and $_.Extent.Text -match '\$ResumeTask' -and $_.Extent.StartOffset -gt $igAfterStages } | Sort-Object { $_.Extent.StartOffset })
$igCall = $null; if ($igSaveCalls.Count -eq 1) { $igCall = $igSaveCalls[0] }
$igTry = $null
if ($igCall) { $igTry = $igCall.Parent; while ($igTry -and -not ($igTry -is [System.Management.Automation.Language.TryStatementAst])) { $igTry = $igTry.Parent } }
Assert-That ($igCall -and $igStages.Count -ge 5 -and $igResumeGone.Count -ge 1 -and $igCall.Extent.StartOffset -gt $igAfterStages -and $igCall.Extent.StartOffset -gt $igResumeGone[0].Extent.EndOffset) "the installer records the baseline once, after its last stage and after the resume task is removed ($($igSaveCalls.Count) call(s), $($igStages.Count) stages)"
Assert-That ($igTry -and $igTry.CatchClauses.Count -gt 0 -and $igTry.Extent.StartOffset -gt $igAfterStages -and $igTry.Extent.Text -notmatch '\bthrow\b|Stop-Install') 'in a try of its own whose catch only warns: a baseline that cannot be written does not fail an install that worked'
Assert-That ($igCall -and $igCall.Extent.Text -match "-Reason 'install'" -and $igCall.Extent.Text -match '-SourceRoot \$SourceRoot' -and $igCall.Extent.Text -match '-OwnTasks @\(\$BackupTask, \$WatchTask, \$RecheckTask\)' -and $igCall.Extent.Text -match '-OwnSettings') 'as an install, naming its own copy of the toolkit, the three tasks it registers and the settings it writes'
Assert-That ($igTry -and $igTry.Extent.Text -match "\['accepted'\]" -and $igTry.Extent.Text -match 'Write-LaiLog WARN "Kept, although this run did not install it') 'and it logs a warning for everything else the new baseline is about to make normal'

if ($onWindows) {
    # Real scheduled tasks and real listeners exist only here, and so does the non-elevated watch that
    # must read them the way the installer recorded them. A throwaway task (never started: it has no
    # trigger) and two ports opened by this test process stand in for a tampered task and a new server.
    $igTask = 'LocalAI-IntegrityTest'
    $igNet = $null; $igLocal = $null; $igLock = $null
    try {
        Register-ScheduledTask -TaskName $igTask -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0') -Force | Out-Null
        $igTasks = Get-LaiIntegrityTasks -NamePattern 'LocalAI-IntegrityTest*'
        $igT = $null; if ($igTasks -is [hashtable]) { $igT = $igTasks[$igTask] }
        Assert-That ($igT -is [hashtable] -and [string]$igT['Run'] -eq 'cmd.exe /c exit 0' -and [string]$igT['RunLevel'] -eq 'Limited' -and [string]$igT['User'] -and [string]$igT['LogonType']) "a real task is read: what it runs, as whom, at what privilege ($([string]$igT['Run']) / $([string]$igT['RunLevel']) / $([string]$igT['LogonType']))"
        Assert-That ((Get-LaiIntegrityTasks -NamePattern 'LaiNoSuchTask-*') -is [hashtable] -and @((Get-LaiIntegrityTasks -NamePattern 'LaiNoSuchTask-*').Keys).Count -eq 0) 'no task of that name is an empty answer, not "could not tell"'
        $igMe = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName.ToLowerInvariant()
        $igLocal = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 39872); $igLocal.Start()
        $igNet = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, 39871); $igNet.Start()
        $igListen = Get-LaiIntegrityListeners
        $igMineNet = @($igListen | Where-Object { $_ -is [hashtable] -and [int]$_['Port'] -eq 39871 })
        $igMineLocal = @($igListen | Where-Object { $_ -is [hashtable] -and [int]$_['Port'] -eq 39872 })
        Assert-That ($igMineNet.Count -eq 1 -and [string]$igMineNet[0]['Program'] -eq $igMe -and $igMineNet[0]['Network'] -eq $true) "a port open to the network is listed with the program that owns it ($igMe) and marked reachable"
        Assert-That ($igMineLocal.Count -eq 1 -and [string]$igMineLocal[0]['Program'] -eq $igMe -and $igMineLocal[0]['Network'] -eq $false) 'a port on 127.0.0.1 only is listed as not reachable from other devices'
        $igNet.Stop(); $igNet = $null

        # End to end, as the scheduled task runs it: baseline, three changes outside an update, two runs.
        # From a clean slate: no earlier baseline, so this one took nothing in and has nothing to confirm.
        ConvertTo-Json @{ WebUIPort = 39996; SearxngPort = 39995; OllamaUrl = 'http://127.0.0.1:39994' } | Set-Content -LiteralPath (Join-Path $igRoot 'localai-config.json')
        $igStateFile = Join-Path $igRoot 'watch-state.json'
        foreach ($f in (Get-LaiIntegrityPath -AIRoot $igRoot), $igStateFile) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
        $igB = Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'test'
        $igBRead = Read-LaiIntegrityBaseline -AIRoot $igRoot
        Assert-That ($igBRead['tasks'] -is [hashtable] -and $igBRead['tasks'][$igTask] -is [hashtable] -and @($igBRead['listeners'] | Where-Object { $_ -is [hashtable] -and [int]$_['Port'] -eq 39872 -and [string]$_['Program'] -eq $igMe -and [string]$_['Seen'] }).Count -eq 1 -and [string]$igBRead['id'] -eq [string]$igB['id']) "the recorded baseline holds the task and the listeners ($(Get-LaiIntegritySummary -Baseline $igBRead))"
        $igListenRows = @($igBRead['listeners'] | Where-Object { $_ -is [hashtable] })
        $igTempRows = @($igListenRows | Where-Object { [int]$_['Port'] -eq 0 })
        $igTwice = @($igTempRows | Group-Object { '{0}|{1}' -f $_['Program'], $_['Network'] } | Where-Object { $_.Count -gt 1 })
        Assert-That (@($igListenRows | Where-Object { [int]$_['Port'] -ge 49152 }).Count -eq 0 -and $igTwice.Count -eq 0) "Windows' per-start ports are kept as one 'temporary' row per program, not as a row per port ($($igTempRows.Count) of $($igListenRows.Count) rows)"
        $igWatchArgs = @('-AIRoot', $igRoot, '-NoHeal', '-NoNotify')
        $igWatchLog = { @(Get-Content -LiteralPath (Join-Path (Join-Path $igRoot 'Logs') 'watch.log') -Encoding UTF8 -ErrorAction SilentlyContinue) }
        # (Only the notices about this test's own changes: another program on this machine opening a
        # port during the test is a difference too, and would be announced as well.)
        $igNotices = { @(& $igWatchLog | Where-Object { $_ -like '* NOTIFY Local AI: changed outside an update*' -and $_ -match 'tool\.ps1|IntegrityTest|39871' }) }
        $igView = { $s = (Read-LaiState -Path $igStateFile)['integrity']; if ($s -is [hashtable]) { $s } else { @{} } }
        $igOurs = { @((& $igView)['found'] | Where-Object { $_ -is [hashtable] -and [string]$_['Text'] -match 'tool\.ps1|IntegrityTest|39871' }) }
        $igHourAgo = { $s = Read-LaiState -Path $igStateFile; $s['integrity']['checkedAt'] = (Get-Date).AddMinutes(-61).ToString('s'); Save-LaiState -State $s -Path $igStateFile }
        $r = Invoke-Child 'Watch-LocalAI.ps1' $igWatchArgs
        $igS = & $igView
        Assert-That ([string]$igS['baseline'] -eq [string]$igB['id'] -and @(& $igOurs).Count -eq 0 -and @($igS['notRead']).Count -eq 0 -and $r.Text -notmatch 'Exception') "the watch compares against the baseline, reads tasks and listeners as the baseline did, and finds none of it changed ($(@($igS['found'] | Where-Object { $_ -is [hashtable] } | ForEach-Object { [string]$_['Text'] }) -join '; '))"
        Set-Content -LiteralPath $igTool -Value 'changed outside an update'
        Register-ScheduledTask -TaskName $igTask -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 1') -Force | Out-Null
        $igNet = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, 39871); $igNet.Start()
        # Compared a moment ago and nothing waiting for a second look (another program on this machine
        # opening a port just then would be): the next run is not due.
        $igS = Read-LaiState -Path $igStateFile; $igS['integrity']['pending'] = @(); $igS['integrity']['checkedAt'] = (Get-Date).ToString('s'); Save-LaiState -State $igS -Path $igStateFile
        $r = Invoke-Child 'Watch-LocalAI.ps1' $igWatchArgs
        Assert-That (@(& $igOurs).Count -eq 0 -and @(& $igNotices).Count -eq 0) 'the next run, minutes later, does not hash again (about once an hour)'
        & $igHourAgo
        $r = Invoke-Child 'Watch-LocalAI.ps1' $igWatchArgs
        $igSeen = @((& $igView)['found'] | Where-Object { $_ -is [hashtable] } | ForEach-Object { [string]$_['Text'] })
        $igTaskText = 'the scheduled task "{0}" now runs a different command' -f $igTask
        Assert-That ($igSeen -contains '"Scripts\tool.ps1" was changed' -and $igSeen -contains $igTaskText -and $igSeen -contains ('"{0}" now accepts connections from other devices on port 39871' -f $igMe)) "an hour later: the changed file, the changed task and the new network listener are seen ($($igSeen -join '; '))"
        Assert-That (@(& $igNotices).Count -eq 0) 'seen once: not announced yet (two strikes)'
        # The file is rewritten before the second look: still the same difference.
        Set-Content -LiteralPath $igTool -Value 'rewritten before the second look'
        $r = Invoke-Child 'Watch-LocalAI.ps1' $igWatchArgs
        $igN = @(& $igNotices)
        $igTold = @((& $igView)['told'] | Where-Object { $_ -is [hashtable] } | ForEach-Object { [string]$_['Id'] })
        Assert-That ($igN.Count -eq 1 -and $igN[0] -like '*"Scripts\tool.ps1" was changed*' -and $igN[0] -like ('*' + $igTaskText + '*') -and $igN[0] -like '*If you did not do this*') "seen again on the next run: one notification that names what changed, also the file that was rewritten in between ($($igN -join ' | '))"
        Assert-That ($igN.Count -eq 1 -and $igN[0] -notlike '*Health check*' -and $igN[0] -notlike '*Update toolkit*' -and $igN[0] -notlike '*Start menu*' -and $igN[0] -like '*Logs\watch.log*' -and $igN[0] -like '*fresh copy of the toolkit*') 'a script is among the changes: the next step names no shortcut (each starts a script from that folder), but watch.log and a fresh copy'
        $igWaiting = @((& $igView)['pending'] | Where-Object { $_ -match 'tool\.ps1|IntegrityTest|39871' })
        Assert-That ($igTold -contains ('net|{0}|39871' -f $igMe) -and $igTold -contains ('task|' + $igTask) -and $igTold -contains 'file|Scripts\tool.ps1' -and $igWaiting.Count -eq 0 -and $r.Text -notmatch 'Exception') 'the file, the task and the listener count as told, and none of them waits for another look'
        & $igHourAgo
        $r = Invoke-Child 'Watch-LocalAI.ps1' $igWatchArgs
        Assert-That (@(& $igNotices).Count -eq 1) 'compared again an hour later: what was told is not told again'
        # An installer run or a model update holds the setup lock (here: this process). The watch does not
        # compare half-replaced files, keeps its last result, and records that it did not look.
        & $igHourAgo
        $igAtBefore = [string](& $igView)['checkedAt']
        $igLock = Enter-LaiSetupLock
        $r = Invoke-Child 'Watch-LocalAI.ps1' $igWatchArgs
        Exit-LaiVolumeLock $igLock; $igLock = $null
        $igS = & $igView
        $igSkipLines = @(& $igWatchLog | Where-Object { $_ -like '* INTEGRITY not compared: an install or a model update is running*' })
        Assert-That ([string]$igS['checkedAt'] -eq $igAtBefore -and [string]$igS['skippedWhy'] -like 'an install or a model update is running*' -and [string]$igS['skippedSince'] -and $igSkipLines.Count -eq 1) "while the setup lock is held the watch does not compare, keeps its last result and says why ($($igSkipLines.Count) line(s) in watch.log)"
        $r = Invoke-Child 'Watch-LocalAI.ps1' $igWatchArgs
        $igS = & $igView
        Assert-That (-not $igS['skippedWhy'] -and -not $igS['skippedSince'] -and [string]$igS['checkedAt'] -ne $igAtBefore -and @(& $igNotices).Count -eq 1) 'and compares again on the first run after the lock is free'
        # The owner made these changes: accepted, they are the baseline.
        $r = Invoke-Child 'Watch-LocalAI.ps1' @('-AIRoot', $igRoot, '-AcceptBaseline')
        Assert-That ($r.Code -eq 0 -and $r.Text -match 'integrity baseline accepted' -and $r.Text -match 'accepted: "Scripts\\tool\.ps1" was changed' -and $r.Text -like ('*accepted: ' + $igTaskText + '*')) "-AcceptBaseline records the current state and lists what it accepted (exit $($r.Code))"
        $r = Invoke-Child 'Watch-LocalAI.ps1' $igWatchArgs
        $r = Invoke-Child 'Watch-LocalAI.ps1' $igWatchArgs
        $igS = & $igView
        Assert-That ([string]$igS['baseline'] -ne [string]$igB['id'] -and [string]$igS['checkedAt'] -and @(& $igOurs).Count -eq 0 -and @(& $igNotices).Count -eq 1) 'after that the same state is compared with the new baseline: nothing of it is reported'
        # Anything running as the owner can run that command, so the acceptance is itself announced.
        $igAccepted = @(& $igWatchLog | Where-Object { $_ -like '* NOTIFY Local AI: integrity baseline accepted*' })
        Assert-That ($igAccepted.Count -eq 1 -and $igAccepted[0] -like '*"Scripts\tool.ps1" was changed*' -and $igAccepted[0] -like '*If that was not you*') "the next scheduled run names what was accepted, once over two runs ($($igAccepted -join ' | '))"
        # What the next baseline goes by (Save-LaiIntegrityBaseline): the watch has had its turn with
        # this one's list, and the owner was told.
        Assert-That ([string]$igS['baseline'] -and [string]$igS['tried'] -eq [string]$igS['baseline'] -and [string]$igS['announced'] -eq [string]$igS['baseline']) "and the watch keeps both under that baseline's id (tried $([string]$igS['tried']), announced $([string]$igS['announced']))"
        # Listeners, both ways of recording a baseline. The accepted one holds the open port.
        $igHas = { @((Read-LaiIntegrityBaseline -AIRoot $igRoot)['listeners'] | Where-Object { $_ -is [hashtable] -and [int]$_['Port'] -eq 39871 -and [string]$_['Program'] -eq $igMe -and $_['Network'] }).Count }
        $igWhileOpen = & $igHas
        $igNet.Stop(); $igNet = $null
        Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'install' | Out-Null
        $igAfterInstall = & $igHas
        Save-LaiIntegrityBaseline -AIRoot $igRoot -Reason 'accepted by the owner' | Out-Null
        $igAfterAccept = & $igHas
        Assert-That ($igWhileOpen -eq 1 -and $igAfterInstall -eq 1) 'an install keeps a listener the baseline before it knew although it is not running right now (not announced again after every update)'
        Assert-That ($igAfterAccept -eq 0) "the owner accepting the current state records what listens now: a port that was closed again is no longer accepted ($igAfterAccept)"
    } catch {
        Assert-That $false "the integrity checks on Windows ran through ($($_.Exception.Message))"
    } finally {
        if ($igLock) { Exit-LaiVolumeLock $igLock }
        foreach ($l in $igNet, $igLocal) { if ($l) { $l.Stop() } }
        Unregister-ScheduledTask -TaskName $igTask -Confirm:$false -ErrorAction SilentlyContinue
        # What the watch wrote about its comparisons, for reading a failure above.
        Get-Content -LiteralPath (Join-Path (Join-Path $igRoot 'Logs') 'watch.log') -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -like '* INTEGRITY *' } | ForEach-Object { Write-Host "  watch.log   $_" -ForegroundColor DarkGray }
    }
} else { Skip 'real scheduled tasks, real listeners and the watch reading them run on Windows only' }

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
# Stop-Install takes the request back (the -NoExit window and its thread outlive the installer).
# Its own 'LaiPower' statement is run here, taken from the function, not a copy of it. The call
# hands back the state before it: 0x80000001 after Enable-LaiKeepAwake, and 0x80000000
# (ES_CONTINUOUS alone) only when that statement really ran and took.
if ($env:OS -eq 'Windows_NT') {
    $kaAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Install-LocalAI.ps1'), [ref]$null, [ref]$null)
    $kaStop = $kaAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-Install' }, $true)
    $kaIf = $null; if ($kaStop) { $kaIf = $kaStop.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -match 'LaiPower' }, $true) }
    Assert-That ($null -ne $kaIf) 'Stop-Install has a statement that clears the keep-awake request'
    if ($kaIf) {
        Enable-LaiKeepAwake | Out-Null
        . ([scriptblock]::Create($kaIf.Extent.Text))
        $kaAfter = [LaiPower]::SetThreadExecutionState([uint32]2147483648)
        Assert-That ($kaAfter -eq [uint32]2147483648) ("after Stop-Install's clear the thread asks for ES_CONTINUOUS alone (the state before the next call: 0x{0:X8})" -f $kaAfter)
    }
}
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
# A chat answer in flight (the render guard's count): the same hook shape, so the sandbox suites do
# not depend on chats the shared render guard happens to serve.
$env:LOCALAI_TEST_CHATS_IN_FLIGHT = '0'
try { Assert-That ((Get-LaiChatsInFlight) -eq 0 -and (Get-LaiChatsInFlight -AfterLoad) -eq 0) 'chats-in-flight hook: a count is reported as is' } finally { $env:LOCALAI_TEST_CHATS_IN_FLIGHT = '' }
$env:LOCALAI_TEST_CHATS_IN_FLIGHT = 'after-load'
try { Assert-That ((Get-LaiChatsInFlight) -eq 0 -and (Get-LaiChatsInFlight -AfterLoad) -eq 1) "chats-in-flight hook 'after-load': a chat only once a model was measured" } finally { $env:LOCALAI_TEST_CHATS_IN_FLIGHT = '' }
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
# An update whose Administrator window was closed mid-run leaves its folder under Program Files.
Assert-That ($ustText -match "Join-Path \`$env:ProgramFiles 'LocalAI-Update'" -and $ustText -match 'Remove-LaiTree -Path \$updDir') 'Uninstall-LocalAI.ps1 also removes LocalAI-Update under Program Files, the folder an update unpacks into (text of the script)'

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

Write-Host "`n=== Test-PCSecurity: read-only PC security check ===" -ForegroundColor Cyan
# The script's own helpers, taken from its source (not a copy).
$pcsAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Test-PCSecurity.ps1'), [ref]$null, [ref]$null)
foreach ($fd in @($pcsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like '*-Pcs*' }, $true))) { . ([scriptblock]::Create($fd.Extent.Text)) }
Assert-That ((Test-PcsVersionBelow '4.44.2' '4.44.3') -eq $true -and (Test-PcsVersionBelow '4.44.3' '4.44.3') -eq $false -and (Test-PcsVersionBelow '4.45.0.20123' '4.44.3') -eq $false -and
    (Test-PcsVersionBelow '5' '4.44.3') -eq $false -and $null -eq (Test-PcsVersionBelow 'unknown' '4.44.3')) 'version compare: the Docker Desktop 4.44.3 cut-off, a 4-part build, a bare major, unreadable text'

$drvIn = @(
    [pscustomobject]@{ Name = 'WinRing0_1_2_0'; PathName = '\??\C:\Program Files\FanTool\WinRing0x64.sys'; State = 'Running' }
    [pscustomobject]@{ Name = 'RTCore64'; PathName = 'C:\Program Files (x86)\MSI Afterburner\RTCore64.sys'; State = 'Stopped' }
    [pscustomobject]@{ Name = 'CorsairLLAccess64'; PathName = '"C:\Program Files\Corsair\CORSAIR iCUE 5 Software\CorsairLLAccess64.sys"'; State = 'Running' }
    [pscustomobject]@{ Name = 'Asusgio3'; PathName = 'C:\Windows\system32\drivers\AsIO3.sys'; State = 'Running' }
    [pscustomobject]@{ Name = 'gdrv'; PathName = 'system32\drivers\gdrv.sys'; State = 'Stopped' }
    [pscustomobject]@{ Name = 'nvlddmkm'; PathName = 'C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64\nvlddmkm.sys'; State = 'Running' }
    [pscustomobject]@{ Name = 'AsIO'; PathName = 'C:\Windows\system32\drivers\AsIO.sys'; State = 'Running' }
)
$hits = @(Find-PcsRiskyDriver -Drivers $drvIn -Apps @([pscustomobject]@{ Name = 'iCUE'; Version = '5.25.95' }))
Assert-That ($hits.Count -eq 5 -and @($hits | Where-Object { $_.Driver -eq 'nvlddmkm.sys' -or $_.Driver -eq 'AsIO.sys' }).Count -eq 0) "drivers: the five listed ones found; the GPU driver and the uncited AsIO.sys not ($(@($hits | ForEach-Object { $_.Driver }) -join ', '))"
$w0 = $hits | Where-Object { $_.Driver -eq 'WinRing0x64.sys' }
Assert-That ($w0 -and $w0.Running -and -not $w0.Fixed -and $w0.Cve -match 'CVE-2020-14979' -and $w0.Fix -match 'uninstall' -and $w0.App -match 'fan') 'WinRing0: loaded, named with the CVE, the usual apps and the fix'
$cor = $hits | Where-Object { $_.Driver -eq 'CorsairLLAccess64.sys' }
Assert-That ($cor -and $cor.Fixed -and $cor.FixedBy -match '5\.25') 'CorsairLLAccess64 from iCUE 5 counts as the fixed driver (CVE-2020-8808 fixed in 3.25.60)'
$old = @(Find-PcsRiskyDriver -Drivers @($drvIn[2]) -Apps @([pscustomobject]@{ Name = 'Corsair iCUE Software'; Version = '3.20.80' }))
$unk = @(Find-PcsRiskyDriver -Drivers @($drvIn[2]))
Assert-That ($old.Count -eq 1 -and -not $old[0].Fixed -and $unk.Count -eq 1 -and -not $unk[0].Fixed) 'and from iCUE 3.20, or with no iCUE version known, it is reported'
$byName = @(Find-PcsRiskyDriver -Drivers @([pscustomobject]@{ Name = 'WinRing0_1_2_0'; PathName = ''; State = 'Stopped' }))
Assert-That ($byName.Count -eq 1 -and -not $byName[0].Running -and $byName[0].Driver -eq 'WinRing0_1_2_0') 'a driver is also matched by its service name when the path is empty'

$hex = 'ab' * 32
$red = Protect-PcsText -Text ("models in C:\Users\JohnDoe\.ollama and C:\Users\JohnDoe2\x; temp C:\Users\JOHNDO~1\AppData; user JOHNDOE on DESKTOP-AB12CD; Johnny stays; mail john.doe@example.com; password=Hunter2-secret; key $hex") `
    -UserNames @('JohnDoe') -ComputerNames @('DESKTOP-AB12CD') -Paths @('C:\Users\JohnDoe')
Assert-That ($red.Contains('%USERPROFILE%\.ollama') -and $red.Contains('C:\Users\<user>\x') -and $red.Contains('C:\Users\<user>\AppData')) "profile paths: yours -> %USERPROFILE%, any other (or its 8.3 short form) -> C:\Users\<user> ($red)"
Assert-That ($red.Contains('user <user> on <computer>') -and $red.Contains('Johnny stays') -and $red.Contains('<email>') -and $red -notmatch 'Hunter2' -and -not $red.Contains($hex)) 'user and computer name (any case, whole words), e-mail, password and key redacted'

$s1 = ConvertFrom-PcsAvState 397568; $s2 = ConvertFrom-PcsAvState 393472; $s3 = ConvertFrom-PcsAvState 397584
Assert-That ($s1.Enabled -and $s1.UpToDate -and -not $s2.Enabled -and $s3.Enabled -and -not $s3.UpToDate) 'Security Center antivirus state: on and current / off / on but out of date'

$meSid = 'S-1-5-21-1-2-3-1001'
$okRules = @(@{ Sid = 'S-1-5-18'; Type = 'Allow'; Who = 'SYSTEM' }, @{ Sid = 'S-1-5-32-544'; Type = 'Allow'; Who = 'Administrators' }, @{ Sid = $meSid; Type = 'Allow'; Who = 'PC\me' }) | ForEach-Object { [pscustomobject]$_ }
$va = Get-PcsAclVerdict -Rules $okRules -CurrentSid $meSid -OwnerSid 'S-1-5-32-544'
$vb = Get-PcsAclVerdict -Rules ($okRules + [pscustomobject]@{ Sid = 'S-1-5-11'; Type = 'Allow'; Who = 'Authenticated Users' }) -CurrentSid $meSid
$vc = Get-PcsAclVerdict -Rules ($okRules + [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1002'; Type = 'Allow'; Who = 'PC\other' }) -CurrentSid $meSid
$vd = Get-PcsAclVerdict -Rules @($okRules[0], $okRules[1], [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1002'; Type = 'Allow'; Who = 'PC\installer' }) -CurrentSid $meSid
$ve = Get-PcsAclVerdict -Rules ($okRules + [pscustomobject]@{ Sid = 'S-1-1-0'; Type = 'Deny'; Who = 'Everyone' }) -CurrentSid $meSid
Assert-That ($va.Status -eq 'PASS' -and $vb.Status -eq 'FAIL' -and @($vb.Bad) -contains 'Authenticated Users' -and $vc.Status -eq 'FAIL' -and $vd.Status -eq 'WARN' -and $ve.Status -eq 'PASS') "Secrets ACL: private PASS, Authenticated Users FAIL, another account FAIL, run from another account WARN, a deny rule ignored ($($va.Status) $($vb.Status) $($vc.Status) $($vd.Status) $($ve.Status))"

$lis = @(
    [pscustomobject]@{ Port = 11434; Address = '0.0.0.0'; Process = 'ollama' }
    [pscustomobject]@{ Port = 3000; Address = '127.0.0.1'; Process = 'com.docker.backend' }
    [pscustomobject]@{ Port = 3000; Address = '::1'; Process = 'com.docker.backend' }
    [pscustomobject]@{ Port = 8188; Address = '::ffff:127.0.0.1'; Process = 'python' }
    [pscustomobject]@{ Port = 8000; Address = '::'; Process = 'python' }
    [pscustomobject]@{ Port = 135; Address = '0.0.0.0'; Process = 'svchost' }
    [pscustomobject]@{ Port = 445; Address = '::'; Process = 'System' }
    [pscustomobject]@{ Port = 27036; Address = '0.0.0.0'; Process = 'steam' }
    [pscustomobject]@{ Port = 27036; Address = '0.0.0.0'; Process = 'steam' }
)
$ex = Get-PcsExposedPort -Listeners $lis -CriticalPorts @(11434, 3000, 8888, 8188, 8000, 2375)
Assert-That (@($ex.Critical).Count -eq 2 -and ($ex.Critical -join ' ') -match '11434@0\.0\.0\.0 \(ollama\)' -and ($ex.Critical -join ' ') -match '8000@:: \(python\)') "AI ports: all-interfaces listeners caught, loopback ones (IPv4, IPv6, mapped) not ($($ex.Critical -join '; '))"
Assert-That (@($ex.Other).Count -eq 1 -and @($ex.Other)[0] -eq '27036@0.0.0.0 (steam)') 'other listeners: Windows itself left out, each program listed once'

$j1 = '{"ExposeDockerAPIOnTCP2375": true, "AutoStart": false}' | ConvertFrom-Json
$j2 = '{"exposeDockerAPIOnTCP2375": false}' | ConvertFrom-Json
$j3 = '{"exposeDockerAPIOnTCP2375": {"locked": true, "value": true}}' | ConvertFrom-Json
Assert-That ((Get-PcsJsonFlag $j1 'exposeDockerAPIOnTCP2375') -eq $true -and (Get-PcsJsonFlag $j2 'exposeDockerAPIOnTCP2375') -eq $false -and (Get-PcsJsonFlag $j3 'exposeDockerAPIOnTCP2375') -eq $true -and $null -eq (Get-PcsJsonFlag $j2 'missing')) 'Docker settings: the 2375 flag is read whatever the key case, also in the admin { value } form'

$cfRoot = Join-Path $Work 'pcs-comfy'
$cfAppData = Join-Path $cfRoot 'AppData'
$cfBase = Join-Path $cfRoot 'ComfyBase'
$cfPortable = Join-Path $cfRoot 'ComfyUI_windows_portable'
foreach ($d in @((Join-Path $cfAppData 'ComfyUI'), (Join-Path (Join-Path $cfBase 'custom_nodes') 'ComfyUI-Manager'), (Join-Path (Join-Path $cfPortable 'ComfyUI') 'custom_nodes'))) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
ConvertTo-Json @{ basePath = $cfBase; installState = 'installed' } | Set-Content -LiteralPath (Join-Path (Join-Path $cfAppData 'ComfyUI') 'config.json') -Encoding UTF8
$cfFound = @(Find-PcsComfyRoot -AppData $cfAppData -UserProfile (Join-Path $cfRoot 'nobody') -Remembered (Join-Path $cfPortable 'run_nvidia_gpu.bat'))
Assert-That ($cfFound.Count -eq 2 -and $cfFound[0] -eq (Resolve-Path -LiteralPath $cfBase).Path -and $cfFound[1] -eq (Resolve-Path -LiteralPath (Join-Path $cfPortable 'ComfyUI')).Path) "ComfyUI found from Comfy Desktop's config.json basePath and the remembered portable start file ($($cfFound -join '; '))"

$mRoot = Join-Path $cfBase 'models'
foreach ($sub in 'checkpoints', 'upscale_models', 'loras') { New-Item -ItemType Directory -Force -Path (Join-Path $mRoot $sub) | Out-Null }
foreach ($f in @(@('checkpoints', 'old.ckpt'), @('checkpoints', 'new.safetensors'), @('upscale_models', 'x4.pth'), @('loras', 'style.PT'), @('loras', 'notes.bin.txt'))) { Set-Content -LiteralPath (Join-Path (Join-Path $mRoot $f[0]) $f[1]) -Value 'x' }
$deep = $mRoot; foreach ($i in 1..10) { $deep = Join-Path $deep "d$i" }
New-Item -ItemType Directory -Force -Path $deep | Out-Null
Set-Content -LiteralPath (Join-Path $deep 'buried.pt') -Value 'x'
$scan = Get-PcsPickleFile -Root $mRoot -MaxDepth 8
$leafs = @($scan.Files | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object)
Assert-That (($leafs -join ',') -eq 'old.ckpt,style.PT,x4.pth' -and $scan.Truncated) "pickle files found (any case), .safetensors and look-alikes not, the depth limit holds and is reported ($($leafs -join ','))"
Assert-That ((Get-PcsPickleFile -Root $mRoot -MaxEntries 1).Truncated -and @((Get-PcsPickleFile -Root (Join-Path $cfRoot 'missing')).Files).Count -eq 0) 'the entry limit stops the scan; a missing folder is no error'

# What a real PC audit found and the check had not noticed (backlog 91). Each judge gets canned
# input: one that must be flagged, one that must not be, one that could not be read (SKIP, never PASS).
# Product, program and folder names below are made up.
$sz = ConvertFrom-PcsAvState 0x062000; $sx = ConvertFrom-PcsAvState 0x063000; $su = ConvertFrom-PcsAvState 0x064000
Assert-That ($s1.State -eq 'On' -and $s2.State -eq 'Off' -and $sz.State -eq 'Snoozed' -and -not $sz.Enabled -and $sx.State -eq 'Expired' -and -not $sx.Enabled -and $su.State -eq 'Unknown' -and -not $su.Enabled) "antivirus state nibble: 0x1000 on, 0 off; 0x2000 snoozed and 0x3000 expired are not on (0x3000 carries the 0x1000 bit); any other nibble is unknown ($($sz.State) $($sx.State) $($su.State))"

$avPassive = [pscustomobject]@{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $false; AMRunningMode = 'Passive Mode' }
$avOff = [pscustomobject]@{ AntivirusEnabled = $false; RealTimeProtectionEnabled = $false; AMRunningMode = 'Not running' }
$avNoRtp = [pscustomobject]@{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $false; AMRunningMode = 'Normal' }
$avOddMode = [pscustomobject]@{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $true; AMRunningMode = 'Some Later Mode' }
$avOwn = [pscustomobject]@{ displayName = 'Windows Defender'; productState = 397568; pathToSignedProductExe = 'windowsdefender://' }
$avOther = { param([long]$State) [pscustomobject]@{ displayName = 'Example Antivirus'; productState = $State; pathToSignedProductExe = 'C:\Program Files\Example\av.exe' } }
$avA = Get-PcsAvVerdict -Defender $avPassive -Products @($avOwn, (& $avOther 0x062000))
Assert-That ($avA.Status -eq 'FAIL' -and $avA.Detail -match 'passive mode' -and $avA.Detail -match 'Example Antivirus reports itself snoozed' -and $avA.Fix -match 'uninstall it completely') "antivirus flagged: Defender passive behind a snoozed antivirus is FAIL although Defender's own Security Center entry reads on ($($avA.Status): $($avA.Detail))"
$avB = Get-PcsAvVerdict -Defender $avOff -Products @((& $avOther 0x063000))
$avC = Get-PcsAvVerdict -Defender $avPassive -Products @($avOwn)
$avD = Get-PcsAvVerdict -Defender $avNoRtp -Products @()
Assert-That ($avB.Status -eq 'FAIL' -and $avB.Detail -match 'reports itself expired' -and $avC.Status -eq 'FAIL' -and $avC.Detail -match 'no other antivirus' -and $avD.Status -eq 'FAIL' -and $avD.Detail -match 'real-time protection is off') "antivirus flagged: an expired antivirus with Defender off, Defender passive with no other antivirus, Defender's real-time protection off with no other antivirus ($($avB.Status) $($avC.Status) $($avD.Status))"
$avE = Get-PcsAvVerdict -Defender $avPassive -Products @($avOwn, (& $avOther 397584))
Assert-That ($avE.Status -eq 'WARN' -and $avE.Detail -match 'Example Antivirus is on, but .* out of date') "antivirus flagged: an antivirus that is on but out of date is WARN ($($avE.Status))"
$avF = Get-PcsAvVerdict -Defender $avPassive -Products @($avOwn, (& $avOther 397568))
$avG = Get-PcsAvVerdict -Defender $null -Products @($avOwn)
Assert-That ($avF.Status -eq 'PASS' -and $avF.Detail -match '^Example Antivirus on' -and $avG.Status -eq 'PASS' -and $avG.Detail -match '^Windows Defender on') "antivirus not flagged: Defender passive next to an antivirus that is on; Defender's Security Center entry counts when Defender itself gave no answer ($($avF.Status) $($avG.Status))"
$avH = Get-PcsAvVerdict -Defender $avPassive -Products @() -ProductsRead $false
$avI = Get-PcsAvVerdict -Defender $avPassive -Products @($avOwn, (& $avOther 0x064000))
$avJ = Get-PcsAvVerdict -Defender $avOddMode -Products @((& $avOther 397568))
$avK = Get-PcsAvVerdict -Defender $null -Products @() -ProductsRead $false
Assert-That ($avH.Status -eq 'SKIP' -and $avI.Status -eq 'SKIP' -and $avI.Detail -match 'Example Antivirus \(productState' -and $avJ.Status -eq 'SKIP' -and $avK.Status -eq 'SKIP') "antivirus could not be read: Security Center unreadable, an unknown state nibble, a running mode this check does not know, nothing readable at all ($($avH.Status) $($avI.Status) $($avJ.Status) $($avK.Status))"
# Defender plainly in charge (the usual PC): the row keeps its result and names the antivirus that is
# left behind, which is what a trial that ran out looks like once Defender has taken over.
$avN1 = Get-PcsAvLeftoverNote -Products @($avOwn, (& $avOther 0x063000))
$avN2 = Get-PcsAvLeftoverNote -Products @($avOwn, (& $avOther 0x062000))
$avN3 = Get-PcsAvLeftoverNote -Products @($avOwn, (& $avOther 397584))
Assert-That ($avN1 -match '^; also registered with Windows but not protecting: Example Antivirus reports itself expired' -and $avN1 -match 'If you no longer use Example Antivirus, uninstall it completely' -and $avN2 -match 'Example Antivirus reports itself snoozed' -and
    $avN3 -match '^; Example Antivirus is on as well, but .* out of date' -and "$avN1 $avN2 $avN3" -notmatch 'Windows Defender') "antivirus left behind flagged: with Defender in charge an expired, a snoozed and an on-but-out-of-date antivirus are each named, with what to do; Defender's own entry is not ($avN1)"
$avN4 = Get-PcsAvLeftoverNote -Products @($avOwn, (& $avOther 397568))
$avN5 = Get-PcsAvLeftoverNote -Products @($avOwn)
$avN6 = Get-PcsAvLeftoverNote -Products @()
Assert-That ($avN4 -is [string] -and $avN4 -eq '' -and $avN5 -eq '' -and $avN6 -eq '') "antivirus left behind not flagged: another antivirus that is on and current, Defender's own entry alone, an empty list add nothing to the row ('$avN4' '$avN5' '$avN6')"
$avN7 = Get-PcsAvLeftoverNote -Products @() -ProductsRead $false
$avN8 = Get-PcsAvLeftoverNote -Products @($avOwn, (& $avOther 0x064000))
Assert-That ($avN7 -match '^; not checked: Windows Security Center could not be asked' -and $avN8 -match '^; not checked: .* Example Antivirus \(productState' -and "$avN7 $avN8" -notmatch 'not protecting') "antivirus left behind could not be read: an unreadable Security Center and an unknown state nibble are said as not checked, never passed over ($avN7 | $avN8)"
# Each row's own code (the scriptblock Add-Check is given), to see what a row calls and how it ends.
$pcsRows = @{}
foreach ($cmd in @($pcsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Check' }, $true))) {
    if ($cmd.CommandElements.Count -ge 3 -and $cmd.CommandElements[2] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $pcsRows[[string]$cmd.CommandElements[1].Value] = $cmd.CommandElements[2] }
}
$avRowText = ''; if ($pcsRows.ContainsKey('Antivirus')) { $avRowText = [string]$pcsRows['Antivirus'].Extent.Text }
$avOnLines = @($avRowText -split "`n" | Where-Object { $_ -match 'Microsoft Defender real-time protection is on, but|Microsoft Defender on \(real-time protection, Tamper Protection' })
$avOnNoted = @($avOnLines | Where-Object { $_.Contains('$also') })
Assert-That ($avRowText -match '\$also = Get-PcsAvLeftoverNote -Products \$\w+\.Products -ProductsRead \$\w+\.Read' -and $avOnLines.Count -eq 2 -and $avOnNoted.Count -eq 2) "and the Antivirus row asks Security Center on the Defender-on path too: its PASS and its WARN both carry the note ($($avOnNoted.Count) of $($avOnLines.Count) lines)"

$syClient = { param([string]$Entry, [bool]$Read) [pscustomobject]@{ Name = 'OneDrive'; Process = 'OneDrive'; Folders = @('C:\Users\JohnDoe\OneDrive\'); StartEntry = $Entry; StartRead = $Read } }
$syEntry = '"C:\Program Files\Microsoft OneDrive\OneDrive.exe" /background'
$syInside = @('C:\AI\Backups', 'C:\Users\JohnDoe\OneDrive\AI-Backups\')
$syBeside = @('C:\AI\Backups', 'C:\Users\JohnDoe\OneDriveArchive\AI-Backups')
$syA = Get-PcsSyncVerdict -BackupFolders $syInside -Clients @(& $syClient $syEntry $true) -Processes @('explorer', 'svchost')
Assert-That ($syA.Status -eq 'WARN' -and $syA.Detail -match 'OneDrive has a start-with-Windows entry but is not running' -and $syA.Detail -match 'OneDrive\\AI-Backups' -and $syA.Detail -notmatch 'JohnDoe' -and $syA.Fix -match 'start OneDrive') "cloud sync flagged: OneDrive has its start entry, no OneDrive process, and the backup copy lies in its folder; the text shows no profile path ($($syA.Status): $($syA.Detail))"
$syB = Get-PcsSyncVerdict -BackupFolders $syInside -Clients @(& $syClient $syEntry $true) -Processes @('explorer', 'onedrive.exe')
$syC = Get-PcsSyncVerdict -BackupFolders $syBeside -Clients @(& $syClient $syEntry $true) -Processes @('explorer')
$syD = Get-PcsSyncVerdict -BackupFolders $syInside -Clients @(& $syClient '' $true) -Processes @('explorer')
Assert-That ($syB.Status -eq 'PASS' -and $syC.Status -eq 'PASS' -and $syC.Detail -match 'not inside' -and $syD.Status -eq 'PASS' -and $syD.Detail -match 'no start-with-Windows entry') "cloud sync not flagged: OneDrive running; a backup folder in 'OneDriveArchive', which only starts with the same letters; no start entry ($($syB.Status) $($syC.Status) $($syD.Status))"
$syE = Get-PcsSyncVerdict -BackupFolders $syInside -Clients @(& $syClient $syEntry $true) -Processes @() -ProcessesRead $false
$syF = Get-PcsSyncVerdict -BackupFolders $syInside -Clients @(& $syClient '' $false) -Processes @('explorer')
Assert-That ($syE.Status -eq 'SKIP' -and $syF.Status -eq 'SKIP') "cloud sync could not be read: the running programs or the start entry unreadable while the backups lie in the OneDrive folder ($($syE.Status) $($syF.Status))"
# The check may run as another account than the one whose OneDrive holds the backups (a window opened
# with a second administrator's password: that account's folders and start entries are the ones read).
# A backup folder named like a OneDrive folder under a user profile, but none of this account's, is
# not checked; it used to read "not inside a cloud-sync folder".
$syNone = [pscustomobject]@{ Name = 'OneDrive'; Process = 'OneDrive'; Folders = @(); StartEntry = ''; StartRead = $true }
$syG = Get-PcsSyncVerdict -BackupFolders @('C:\AI\Backups', 'C:\Users\OtherUser\OneDrive\AI-Backups') -Clients @($syNone) -Processes @('explorer')
$syH = Get-PcsSyncVerdict -BackupFolders @('C:\AI\Backups', 'c:/users/JohnDoe/OneDrive - Work/AI-Backups/') -Clients @(& $syClient $syEntry $true) -Processes @('explorer', 'OneDrive')
Assert-That ($syG.Status -eq 'SKIP' -and $syG.Detail -match 'OneDrive\\AI-Backups under a user profile' -and $syG.Detail -match 'run this check from that account in a normal window' -and $syG.Detail -notmatch 'OtherUser' -and $syH.Status -eq 'SKIP' -and $syH.Detail -notmatch 'Work|JohnDoe') "cloud sync could not be read: the backups lie in another account's OneDrive folder, or in a folder named 'OneDrive - <organisation>' that this account's OneDrive does not name; the text shows neither name ($($syG.Status): $($syG.Detail))"
$syI = Get-PcsSyncVerdict -BackupFolders @('C:\AI\Backups', 'D:\Backups\OneDrive\AI', 'C:\Users\JohnDoe\Documents\OneDrive\AI') -Clients @($syNone) -Processes @('explorer')
Assert-That ($syI.Status -eq 'PASS' -and $syI.Detail -match 'not inside') "cloud sync not flagged: a folder merely called OneDrive on another drive or deeper inside a profile is not taken for a OneDrive folder ($($syI.Status))"
$syJ = Get-PcsSyncVerdict -BackupFolders @('C:\Users\JohnDoe\OneDrive\AI-Backups', 'C:\Users\OtherUser\OneDrive\More') -Clients @(& $syClient $syEntry $true) -Processes @('explorer')
Assert-That ($syJ.Status -eq 'WARN' -and $syJ.Detail -match 'has a start-with-Windows entry but is not running' -and $syJ.Detail -match 'Not checked: the backups lie in OneDrive\\More under a user profile') "cloud sync flagged: a stopped OneDrive stays WARN and the folder in another account's OneDrive is added as not checked ($($syJ.Status))"
# Only this session's processes count. With two accounts signed in (fast user switching) the other
# account's OneDrive is in the list Windows gives, and it uploads nothing for this account.
$syProcs = @(
    [pscustomobject]@{ ProcessName = 'explorer'; SessionId = 1 }
    [pscustomobject]@{ ProcessName = 'OneDrive'; SessionId = 2 }
    [pscustomobject]@{ ProcessName = 'svchost'; SessionId = 0 }
    [pscustomobject]@{ ProcessName = 'unnumbered'; SessionId = $null }
)
$syMine = Select-PcsSessionProcess -Processes $syProcs -SessionId 1
$syTheirs = Select-PcsSessionProcess -Processes $syProcs -SessionId 2
$syK = Get-PcsSyncVerdict -BackupFolders $syInside -Clients @(& $syClient $syEntry $true) -Processes @($syMine.Names) -ProcessesRead $syMine.Read
$syL = Get-PcsSyncVerdict -BackupFolders $syInside -Clients @(& $syClient $syEntry $true) -Processes @($syTheirs.Names) -ProcessesRead $syTheirs.Read
Assert-That ($syMine.Read -and (@($syMine.Names) -join ',') -eq 'explorer' -and $syK.Status -eq 'WARN' -and $syK.Detail -match 'OneDrive has a start-with-Windows entry but is not running') "cloud sync flagged: OneDrive runs in another account's session only, so for this session it is not running ($($syK.Status); this session: $(@($syMine.Names) -join ','))"
Assert-That ($syTheirs.Read -and (@($syTheirs.Names) -join ',') -eq 'OneDrive' -and $syL.Status -eq 'PASS' -and $syL.Detail -match 'OneDrive is running') "cloud sync not flagged: OneDrive runs in the session that asks ($($syL.Status))"
$syNoNumber = Select-PcsSessionProcess -Processes $syProcs -SessionId $null
$syNobody = Select-PcsSessionProcess -Processes $syProcs -SessionId 7
$syServices = Select-PcsSessionProcess -Processes $syProcs -SessionId 0
$syM = Get-PcsSyncVerdict -BackupFolders $syInside -Clients @(& $syClient $syEntry $true) -Processes @($syNobody.Names) -ProcessesRead $syNobody.Read
Assert-That (-not $syNoNumber.Read -and @($syNoNumber.Names).Count -eq 0 -and -not $syNobody.Read -and @($syNobody.Names).Count -eq 0 -and -not $syServices.Read -and @($syServices.Names).Count -eq 0 -and $syM.Status -eq 'SKIP' -and $syM.Detail -match 'running programs was not readable') "cloud sync could not be read: no session number, no process at all in the session that asks (it runs there itself), or a check started in the services' session 0 is an unread list and SKIP, never 'not running' ($($syM.Status))"
$syRowText = ''; $syRowReads = @()
if ($pcsRows.ContainsKey('Cloud sync the backups rely on')) {
    $syRowText = [string]$pcsRows['Cloud sync the backups rely on'].Extent.Text
    $syRowReads = @($pcsRows['Cloud sync the backups rely on'].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Process' }, $true))
}
Assert-That ($syRowText -match 'Select-PcsSessionProcess -Processes @\(Get-Process -ErrorAction Stop\) -SessionId \(\[System\.Diagnostics\.Process\]::GetCurrentProcess\(\)\.SessionId\)' -and $syRowText -match '-Processes \$procs -ProcessesRead \$procsRead' -and $syRowReads.Count -eq 1) "and the cloud-sync row hands the judge this session's processes only: its one Get-Process call goes through the session filter ($($syRowReads.Count) Get-Process call(s))"

$odApps = @(
    [pscustomobject]@{ Name = 'Example Lighting Suite'; Version = '2.1'; InstallLocation = 'C:\Program Files\ExampleLighting\' }
    [pscustomobject]@{ Name = 'Example Lighting Suite Two'; Version = '1.0'; InstallLocation = 'C:\Program Files\ExampleLighting2' }
    [pscustomobject]@{ Name = 'Example Tool In The Drive Root'; Version = '1.0'; InstallLocation = 'C:\' }
)
$odEne = [pscustomobject]@{ Name = 'EneIo'; PathName = '\??\C:\Program Files\ExampleLighting\drivers\EneIo64.sys'; State = 'Running' }
$odIdle = [pscustomobject]@{ Name = 'MsIo64'; PathName = 'C:\Windows\system32\drivers\MsIo64.sys'; State = 'Stopped' }
$odLoaded = @($odEne, $drvIn[3], $drvIn[5])
$script:odAsked = @()
$odProbe = { param($Device) $script:odAsked += [string]$Device; 'opened' }
$odA = Find-PcsOpenDriver -Drivers $odLoaded -Apps $odApps -Probe $odProbe
Assert-That ($odA.Status -eq 'WARN' -and @($odA.Hits).Count -eq 1 -and $odA.Detail -match 'EneIo64\.sys \(loaded, installed by Example Lighting Suite\)' -and $odA.Detail -match 'without administrator rights' -and $odA.Fix -match 'if you do not use Example Lighting Suite, uninstall it' -and ($script:odAsked -join ',') -eq 'EneIo') "open driver flagged: probe 'opened' is WARN, names the program whose folder holds the driver and says it can be uninstalled; only the listed driver was probed ($($odA.Status); asked: $($script:odAsked -join ','))"
$odB = Find-PcsOpenDriver -Drivers $odLoaded -Apps $odApps -Probe { 'denied' }
$odC = Find-PcsOpenDriver -Drivers @($drvIn[3], $drvIn[5]) -Apps $odApps -Probe $odProbe
$odD = Find-PcsOpenDriver -Drivers @($odIdle) -Apps $odApps -Probe $odProbe
Assert-That ($odB.Status -eq 'PASS' -and $odB.Detail -match 'refused' -and $odC.Status -eq 'PASS' -and @($odC.Hits).Count -eq 0 -and $odD.Status -eq 'PASS' -and $odD.Detail -match 'not loaded' -and ($script:odAsked -join ',') -eq 'EneIo') "open driver not flagged: probe 'denied'; no listed driver (AsIO3 and the GPU driver are not on this list); a listed one that is not loaded is not probed ($($odB.Status) $($odC.Status) $($odD.Status))"
$odE = Find-PcsOpenDriver -Drivers $odLoaded -Apps $odApps -Elevated $true -Probe $odProbe
$odF = Find-PcsOpenDriver -Drivers $odLoaded -Apps $odApps -Probe { 'absent' }
$odG = Find-PcsOpenDriver -Drivers $odLoaded -Apps $odApps -Probe { 'error 31' }
$odH = Find-PcsOpenDriver -Drivers $odLoaded -Apps $odApps -Probe { throw 'the probe broke' }
$odI = Find-PcsOpenDriver -Drivers @() -DriversRead $false -Probe $odProbe
Assert-That ($odE.Status -eq 'SKIP' -and $odE.Detail -match 'without Run as administrator' -and $odE.Detail -notmatch 'elevated window' -and ($script:odAsked -join ',') -eq 'EneIo' -and $odF.Status -eq 'SKIP' -and $odG.Status -eq 'SKIP' -and $odH.Status -eq 'SKIP' -and $odI.Status -eq 'SKIP') "open driver could not be read: elevated is SKIP and the probe is never asked; no such device, another error, a probe that throws, an unreadable driver list ($($odE.Status) $($odF.Status) $($odG.Status) $($odH.Status) $($odI.Status))"
$odJ = Find-PcsOpenDriver -Drivers $drvIn -Apps @([pscustomobject]@{ Name = 'Armoury Crate Service'; Version = '5.0'; InstallLocation = '' }) -Probe { 'opened' }
Assert-That (@($odJ.Hits).Count -eq 1 -and $odJ.Hits[0].Driver -eq 'AsIO.sys' -and $odJ.Hits[0].Device -eq 'Asusgio' -and $odJ.Hits[0].From -match 'installed here: Armoury Crate Service') "open driver: of the vulnerable-driver fixture only AsIO.sys is on this list; a driver in the Windows folder gets its program by name ($(@($odJ.Hits | ForEach-Object { $_.Driver }) -join ', '))"

$fwPy = 'v2.30|Action=Allow|Active=TRUE|Dir=In|Protocol=6|Profile=Private|Profile=Public|App=C:\Python312\python.exe|Name=python.exe|Desc=python.exe|Defer=User|'
$fwQuiet = @(
    ($fwPy -replace 'Action=Allow', 'Action=Block')
    ($fwPy -replace 'Dir=In', 'Dir=Out')
    ($fwPy -replace 'Active=TRUE', 'Active=FALSE')
    'v2.30|Action=Allow|Active=TRUE|Dir=In|Protocol=6|App=C:\Program Files\Example\notpython.exe|Name=a look-alike name|'
    'v2.30|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=3389|Name=a rule without a program|'
)
$fwLoud = @($fwPy, ($fwPy -replace 'Protocol=6', 'Protocol=17'), 'v2.31|Action=Allow|Active=TRUE|Dir=In|App=%SystemRoot%\System32\WindowsPowerShell\v1.0\PowerShell.EXE|Name=no profile named|')
$fwA = Find-PcsInterpreterRule -Rules ($fwLoud + $fwQuiet)
Assert-That ($fwA.Status -eq 'WARN' -and @($fwA.Hits).Count -eq 2 -and $fwA.Detail.Contains('python.exe (C:\Python312\python.exe; Private, Public networks)') -and $fwA.Detail -match 'powershell\.exe \(.*; every network\)' -and $fwA.Detail -notmatch 'notpython' -and $fwA.Fix -match 'Allow an app through firewall') "firewall flagged: an inbound allow rule for python.exe (its TCP and UDP rules listed once, with its networks) and for PowerShell.EXE under an environment-variable path ($($fwA.Status): $(@($fwA.Hits | ForEach-Object { $_.Text }) -join ' | '))"
$fwB = Find-PcsInterpreterRule -Rules $fwQuiet
Assert-That ($fwB.Status -eq 'PASS' -and @($fwB.Hits).Count -eq 0 -and $fwB.Detail -match '5 firewall rules read') "firewall not flagged: a Block, a Dir=Out and an Active=FALSE python.exe rule, a look-alike program name, a rule without a program ($($fwB.Status))"
$fwC = Find-PcsInterpreterRule -Rules @() -RulesRead $false
$fwD = Find-PcsInterpreterRule -Rules @($fwQuiet[4], ($fwPy -replace 'Action=Allow', 'Action=ByPass'))
$fwE = Find-PcsInterpreterRule -Rules @($fwQuiet[4], 'v2.30|Action=Allow|Active=TRUE|App=C:\Java\bin\java.exe|Name=no direction given|')
$fwF = Find-PcsInterpreterRule -Rules @()
Assert-That ($fwC.Status -eq 'SKIP' -and $fwD.Status -eq 'SKIP' -and $fwD.Detail -match 'python\.exe' -and $fwE.Status -eq 'SKIP' -and $fwF.Status -eq 'SKIP') "firewall could not be read: an unreadable rule list, an action this check does not judge (ByPass), a rule without a direction, an empty rule list ($($fwC.Status) $($fwD.Status) $($fwE.Status) $($fwF.Status))"

if ($onWindows) {
    # The readers against this Windows itself. NUL is a device every program may open.
    $devNul = Test-PcsDeviceOpen -Device 'NUL'
    $devNone = Test-PcsDeviceOpen -Device ('LaiNoSuchDevice' + (Get-Random -Minimum 100000 -Maximum 999999))
    $devFile = Test-PcsDeviceOpen -Device 'C:\Windows\win.ini'
    Assert-That ($devNul -eq 'opened' -and $devNone -eq 'absent' -and $devFile -like 'error*') "the device-open reader: NUL opens, a made-up device name does not (absent), a file path is turned away unopened ($devNul / $devNone / $devFile)"
    $fwReal = Get-PcsFirewallRuleText
    $fwShaped = @($fwReal.Rules | Where-Object { $_ -match '^v\d+\.\d+\|' } | Where-Object { $_ -match '\|Action=(Allow|Block)\|' } | Where-Object { $_ -match '\|Dir=(In|Out)\|' } | Where-Object { $_ -match '\|Active=(TRUE|FALSE)\|' })
    $fwRealVerdict = Find-PcsInterpreterRule -Rules $fwReal.Rules -RulesRead $fwReal.Read
    Assert-That ($fwReal.Read -and $fwShaped.Count -ge 10 -and @('PASS', 'WARN') -contains $fwRealVerdict.Status) "this Windows keeps its firewall rules in the form the check reads ($(@($fwReal.Rules).Count) rules, $($fwShaped.Count) with Action, Dir and Active; verdict $($fwRealVerdict.Status): $($fwRealVerdict.Detail))"
    $avReal = Get-PcsAvProduct
    $syReal = @(Get-PcsSyncClient)
    Assert-That ($avReal.Read -is [bool] -and $syReal.Count -eq 1 -and $syReal[0].Name -eq 'OneDrive' -and $syReal[0].StartRead -is [bool]) "the Security Center and cloud-sync readers answer without an error (Security Center read: $($avReal.Read); OneDrive folders: $(@($syReal[0].Folders).Count))"
    # What the cloud-sync row does: every process Windows lists, cut down to this session's.
    $spSelf = [System.Diagnostics.Process]::GetCurrentProcess()
    $spAll = @(Get-Process)
    $spReal = Select-PcsSessionProcess -Processes $spAll -SessionId $spSelf.SessionId
    $spNumbered = @($spAll | Where-Object { $null -ne $_.SessionId })
    # In a desktop session the filter must find this test's own process; in session 0 (a CI agent that
    # runs as a service) it must answer "not read".
    $spDesktop = ($spSelf.SessionId -ne 0)
    $spFound = (@($spReal.Names) -contains $spSelf.ProcessName)
    Assert-That ($spNumbered.Count -eq $spAll.Count -and $spReal.Read -eq $spDesktop -and $spFound -eq $spDesktop -and @($spReal.Names).Count -le $spAll.Count) "this Windows gives every process its session number, and the session filter finds this test's own process exactly when it runs in a desktop session ($(@($spReal.Names).Count) of $($spAll.Count) processes kept for session $($spSelf.SessionId); read: $($spReal.Read))"
} else { Skip 'device-open, firewall, Security Center, cloud-sync and session readers: Windows only (the judges above ran on canned input)' }

# Every command the script runs reads: none that sets, removes, starts or stops anything.
$changeVerbs = @('Set', 'Remove', 'Enable', 'Disable', 'Clear', 'Start', 'Stop', 'Restart', 'Install', 'Uninstall', 'Register', 'Unregister', 'Update', 'Suspend', 'Resume',
    'Rename', 'Move', 'Copy', 'Grant', 'Revoke', 'Reset', 'Repair', 'Mount', 'Dismount', 'Lock', 'Unlock', 'Invoke', 'Send', 'Publish', 'Initialize', 'Block', 'Unblock')
$changeTools = @('icacls', 'reg', 'netsh', 'sc', 'schtasks', 'bcdedit', 'manage-bde', 'wmic', 'powercfg', 'dism', 'takeown', 'docker', 'wsl', 'winget', 'cmd', 'ollama')
$pcsCmds = @($pcsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { [string]$_.GetCommandName() } | Where-Object { $_ } | Select-Object -Unique)
$changing = @($pcsCmds | Where-Object { ($_ -match '^([A-Za-z]+)-' -and $changeVerbs -contains $Matches[1]) -or $changeTools -contains ($_.ToLowerInvariant() -replace '\.exe$', '') })
Assert-That ($pcsCmds.Count -gt 20 -and $changing.Count -eq 0) "Test-PCSecurity.ps1 runs no command that changes the PC ($($pcsCmds.Count) commands; changing: $($changing -join ', '))"
# That list sees command names only, not what the script's one piece of compiled code calls in Windows
# itself (the C# in Test-PcsDeviceOpen). So what that code may do is pinned here: one Add-Type, given
# $members; two imports from kernel32.dll, CreateFileW and CloseHandle, under their own names; one
# CreateFileW call, asking for no access (dwDesiredAccess 0) to something that exists (OPEN_EXISTING, 3);
# and no other call: nothing that reads, writes or sends a driver a control code. Whoever changes that
# code has to change this list with it.
$pcsSource = [string]$pcsAst.Extent.Text
$pcsAddType = @($pcsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' }, $true))
$pcsMemberSets = @($pcsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$members' }, $true))
$pcsCs = ''
if ($pcsMemberSets.Count -eq 1) {
    # The C# lines, without the comment lines among them and without the line break they are joined with.
    $pcsCs = @($pcsMemberSets[0].Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { [string]$_.Value } | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('//') }) -join "`n"
}
$pcsAddTypeOk = ($pcsAddType.Count -eq 1 -and $pcsMemberSets.Count -eq 1 -and ([string]$pcsAddType[0].Extent.Text).EndsWith('-MemberDefinition $members'))
$pcsExterns = @([regex]::Matches($pcsSource, '\bextern\s+[\w\.]+\s+(\w+)\s*\(') | ForEach-Object { $_.Groups[1].Value })
$pcsImportsOk = ($pcsExterns.Count -eq 2 -and $pcsExterns -ccontains 'CreateFileW' -and $pcsExterns -ccontains 'CloseHandle' -and
    [regex]::Matches($pcsSource, 'DllImport').Count -eq 2 -and [regex]::Matches($pcsSource, 'DllImport\("kernel32\.dll"').Count -eq 2 -and $pcsSource -notmatch 'EntryPoint')
$pcsOpens = @([regex]::Matches($pcsCs, 'CreateFileW\s*\([^)]*\)') | ForEach-Object { $_.Value })
$pcsOpenOk = ($pcsOpens.Count -eq 2 -and
    $pcsOpens -ccontains 'CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, System.IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, System.IntPtr hTemplateFile)' -and
    $pcsOpens -ccontains 'CreateFileW(name, 0, 3, System.IntPtr.Zero, 3, 0, System.IntPtr.Zero)')
$pcsMayCall = @('DllImport', 'CreateFileW', 'CloseHandle', 'TryOpen', 'IntPtr', 'GetLastWin32Error', 'if')
$pcsCalled = @([regex]::Matches($pcsCs, '([A-Za-z_]\w*)\s*\(') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$pcsStray = @($pcsCalled | Where-Object { $pcsMayCall -cnotcontains $_ })
$pcsUnseen = @($pcsMayCall | Where-Object { $pcsCalled -cnotcontains $_ })
Assert-That ($pcsAddTypeOk -and $pcsImportsOk) "the script compiles code once (Add-Type with `$members) and imports CreateFileW and CloseHandle from kernel32.dll, nothing else ($($pcsAddType.Count) Add-Type; imports: $($pcsExterns -join ', '))"
Assert-That ($pcsOpenOk -and $pcsStray.Count -eq 0 -and $pcsUnseen.Count -eq 0) "and that code makes one CreateFileW call, with no access asked for (name, 0, 3, null, 3, 0, null), closes the handle and calls nothing else ($($pcsOpens.Count) CreateFileW text(s); calls: $($pcsCalled -join ', '); not on the list: $($pcsStray -join ', '); expected and not found: $($pcsUnseen -join ', '))"
# Add-Check keeps a hashtable with one of the four results; anything else a row's code returns is no
# answer. Convert-Verdict is what turns a judge's answer into that hashtable, so the four rows must end in it,
# and a status it does not know must come out as not checked. (Loaded in a scope of its own: the
# script's Skip is not this file's.)
$pcsVerdictRows = @('Antivirus', 'Hardware-access drivers any program can open', 'Firewall openings for script runners', 'Cloud sync the backups rely on')
$pcsLoose = @($pcsVerdictRows | Where-Object {
        $last = ''
        if ($pcsRows.ContainsKey($_)) { $st = @($pcsRows[$_].ScriptBlock.EndBlock.Statements); if ($st.Count) { $last = [string]$st[$st.Count - 1].Extent.Text } }
        $last -notmatch '^Convert-Verdict '
    })
$cvFns = @($pcsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and @('Pass', 'Fail', 'Warn', 'Skip', 'Convert-Verdict') -contains $n.Name }, $true))
$cv = @(& {
        foreach ($fd in $cvFns) { . ([scriptblock]::Create($fd.Extent.Text)) }
        Convert-Verdict ([pscustomobject]@{ Status = 'WARN'; Detail = 'the detail'; Fix = 'the fix' })
        Convert-Verdict ([pscustomobject]@{ Status = 'PASS'; Detail = 'fine'; Fix = '' })
        Convert-Verdict ([pscustomobject]@{ Status = 'DONE'; Detail = 'a status that is none of the four'; Fix = '' })
        Convert-Verdict $null
    })
Assert-That ($pcsLoose.Count -eq 0 -and $cvFns.Count -eq 5 -and $cv.Count -eq 4 -and @($cv | Where-Object { $_ -is [hashtable] }).Count -eq 4 -and $cv[0].Status -eq 'WARN' -and $cv[0].Detail -eq 'the detail' -and $cv[0].Fix -eq 'the fix' -and
    $cv[1].Status -eq 'PASS' -and $cv[1].Detail -eq 'fine' -and $cv[2].Status -eq 'SKIP' -and [string]$cv[2].Detail -and $cv[3].Status -eq 'SKIP') "a judge's answer reaches Add-Check as a hashtable with its words; a status that is none of the four, or no answer, is SKIP, never a silent PASS; the four rows end in Convert-Verdict (not: $($pcsLoose -join ', '))"
# Add-Check itself: no verdict is SKIP with words, and a row whose code throws is still 'could not be
# read (<error>)'. Every row gives a verdict on every path, so none of them meets that SKIP.
$pcsAcFns = @($cvFns) + @($pcsAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Add-Check' })
$pcsAc = @{ Said = @() }
try { $pcsAc = & $addCheckRows $pcsAcFns } catch { Write-Host "  the Add-Check cases stopped: $($_.Exception.Message)" }
$pcsSilent = @($noAnswerRows | Where-Object { $pcsAc[$_] -ne 'SKIP this check gave no answer' })
Assert-That ($pcsAcFns.Count -eq 6 -and $pcsSilent.Count -eq 0 -and $pcsAc['Said'] -contains '[INFO] SKIP empty: this check gave no answer') "a security check that gives no verdict (an empty body, plain text, a table without a result, a result that is none of the four) is SKIP 'this check gave no answer', never a PASS without words (not: $($pcsSilent -join ', '))"
Assert-That ($pcsAc['passes'] -eq 'PASS x' -and $pcsAc['words, then a verdict'] -eq 'WARN w' -and $pcsAc['throws'] -eq 'SKIP could not be read (boom)') "a verdict is kept as given, also after other output, and a security check that throws is still SKIP 'could not be read (<error>)' ($($pcsAc['passes']) | $($pcsAc['words, then a verdict']) | $($pcsAc['throws']))"
$pcsVerdicts = & $looseRows $pcsAst
Assert-That ($pcsVerdicts.Rows -ge 25 -and $pcsVerdicts.Loose.Count -eq 0) "every security check row ends in Pass, Fail, Warn, Skip or Convert-Verdict, returns nothing else and gives no verdict it does not hand back ($($pcsVerdicts.Rows) rows; not: $($pcsVerdicts.Loose -join ', '))"
# Which window: no single one makes every check, so the help and the line a normal window starts with
# name both, and neither sends the reader to 'the full check' any more.
$pcsWindowWords = @('a normal window for the driver test', 'Run as administrator for TPM, drive encryption and SMBv1')
$pcsFile = [System.IO.File]::ReadAllText((Join-Path $src 'Test-PCSecurity.ps1'))
# The help is what stands before the param block.
$pcsWindowTexts = @([string]@($pcsFile -split "`nparam\(", 2)[0], [string](@($pcsFile -split "`n" | Where-Object { $_ -cmatch "Write-LaiLog INFO 'Not elevated: " }) -join ' '))
$pcsWindowOk = @($pcsWindowTexts | Where-Object { $_.Contains($pcsWindowWords[0]) -and $_.Contains($pcsWindowWords[1]) })
Assert-That ($pcsWindowOk.Count -eq 2 -and $pcsFile -cnotmatch 'For the full check|a few checks are skipped|For all of them') "the help and the 'Not elevated' line both name a normal window for the driver test and Run as administrator for TPM, drive encryption and SMBv1 ($($pcsWindowOk.Count) of 2)"

# The whole script in its own process: runs to the end, never throws, writes a report without names.
$pcsRoot = Join-Path $Work 'pcs-root'
New-Item -ItemType Directory -Force -Path (Join-Path $pcsRoot 'Secrets') | Out-Null
ConvertTo-Json @{ WebUIPort = 39996; SearxngPort = 39995 } | Set-Content -LiteralPath (Join-Path $pcsRoot 'localai-config.json')
$pcsReport = Join-Path (Join-Path $pcsRoot 'Logs') 'pc-security-test.md'
$pcsSw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Child 'Test-PCSecurity.ps1' @('-AIRoot', $pcsRoot, '-ReportPath', $pcsReport)
$pcsSecs = [int]$pcsSw.Elapsed.TotalSeconds
$checkLines = @($r.Text -split "`n" | Where-Object { $_ -match '\[(OK|WARN|FAIL|INFO) *\] (PASS|WARN|FAIL|SKIP) ' })
$failLines = @($checkLines | Where-Object { $_ -match '\] FAIL ' })
Assert-That ($r.Text -match 'PC SECURITY CHECK COMPLETE: \d+ checks, \d+ warnings, \d+ failures' -and $checkLines.Count -ge 20) "the security check runs to its summary line ($($checkLines.Count) checks, $pcsSecs s)"
$pcsNewRows = @('Hardware-access drivers any program can open', 'Firewall openings for script runners', 'Cloud sync the backups rely on')
# Each of them with words after the colon: a row that prints its result and nothing else would
# otherwise pass here as a row that is there.
$pcsMissing = @($pcsNewRows | Where-Object { $r.Text -notmatch ('\] (PASS|WARN|FAIL|SKIP) ' + [regex]::Escape($_) + ': \S') })
$pcsAvRows = @($checkLines | Where-Object { $_ -match '\] (PASS|WARN|FAIL|SKIP) Antivirus: \S' })
$pcsWordlessRx = '\] (PASS|WARN|FAIL|SKIP) (Antivirus|' + (@($pcsNewRows | ForEach-Object { [regex]::Escape($_) }) -join '|') + '):\s*$'
$pcsWordless = @($checkLines | Where-Object { $_ -match $pcsWordlessRx })
Assert-That ($pcsMissing.Count -eq 0 -and $pcsAvRows.Count -eq 1 -and $pcsWordless.Count -eq 0) "the run has the three new rows and still one Antivirus row, each saying what it found (missing or wordless: $($pcsMissing -join ', '); Antivirus rows with words: $($pcsAvRows.Count); rows with nothing after the colon: $($pcsWordless.Count))"
# A row whose own code throws is caught by the script and reported as 'could not be read (<error>)': the
# rows changed here read through their own readers, so that text on one of them is a bug in the row.
$pcsRowRx = 'Antivirus: |' + (@($pcsNewRows | ForEach-Object { [regex]::Escape($_) + ': ' }) -join '|')
$pcsBroken = @($checkLines | Where-Object { $_ -match $pcsRowRx } | Where-Object { $_ -match 'could not be read \(' })
Assert-That ($pcsBroken.Count -eq 0) "and none of these four rows ends in an error of its own ($($pcsBroken -join ' | '))"
Assert-That ($r.Text -notmatch 'FullyQualifiedErrorId|ParentContainsErrorRecordException') 'and never throws'
Assert-That ($r.Code -is [int] -and $r.Code -ge 0 -and $r.Code -eq $failLines.Count) "exit code = number of FAILs (exit $($r.Code), $($failLines.Count) FAIL line(s))"
$pcsText = ''; if (Test-Path -LiteralPath $pcsReport) { $pcsText = [System.IO.File]::ReadAllText($pcsReport) }
Assert-That ($pcsText -match 'PC SECURITY CHECK COMPLETE' -and $pcsText -match '\| Result \| Check \| Details \| What to do \|') 'the Markdown report is written'
$names = @(@($env:USERNAME, [Environment]::UserName, $env:COMPUTERNAME, [Environment]::MachineName) | Where-Object { $_ -and $_.Length -ge 2 } | Select-Object -Unique)
$leaks = @($names | Where-Object { $pcsText -match ('(?i)(?<![\p{L}\p{N}])' + [regex]::Escape($_) + '(?![\p{L}\p{N}])') })
Assert-That ($names.Count -ge 1 -and $leaks.Count -eq 0) "the report names neither the user nor the computer ($($names.Count) name(s) checked, $($leaks.Count) found)"
if ($env:USERPROFILE) { Assert-That (-not $pcsText.ToLowerInvariant().Contains($env:USERPROFILE.ToLowerInvariant())) 'and shows no profile path' } else { Skip 'profile path check needs USERPROFILE' }
if ($onWindows) {
    # On Windows the checks really run. These rows read a plain setting or this account, which every
    # Windows answers in any window, so each of them must say PASS, WARN or FAIL here.
    $pcsMustJudge = @('Restart to finish updates', 'User Account Control', 'Microsoft vulnerable driver blocklist', 'Local Security Authority protection', 'SmartScreen for apps and files', 'Remote Desktop', 'Daily account type')
    $pcsNotJudged = @($pcsMustJudge | Where-Object { $r.Text -notmatch ('\] (PASS|WARN|FAIL) ' + [regex]::Escape($_) + ': \S') })
    Assert-That ($pcsNotJudged.Count -eq 0) "on Windows the checks really run: each of these $($pcsMustJudge.Count) rows says PASS, WARN or FAIL (without a verdict: $($pcsNotJudged -join ', '))"
    # 'could not be read (<error>)' is a row whose own code threw. Only the rows that ask the firmware or
    # BitLocker, which a CI machine may not have, may end that way; on any other row it is a bug in the row.
    $pcsMayThrow = @('Secure Boot', 'TPM', 'Drive encryption')
    $pcsMayThrowRx = '\] SKIP (' + (@($pcsMayThrow | ForEach-Object { [regex]::Escape($_) }) -join '|') + '): could not be read \('
    $pcsThrew = @($checkLines | Where-Object { $_ -match 'could not be read \(' -and $_ -notmatch $pcsMayThrowRx })
    Assert-That ($pcsThrew.Count -eq 0) "no row ends in an error of its own, but for $($pcsMayThrow -join ', ') ($($pcsThrew -join ' | '))"
    $pcsNoWordsRx = '\] (PASS|WARN|FAIL|SKIP) (' + (@($pcsRows.Keys | ForEach-Object { [regex]::Escape([string]$_) }) -join '|') + '):\s*$'
    $pcsNoWords = @($checkLines | Where-Object { $_ -match $pcsNoWordsRx })
    Assert-That ($pcsRows.Count -ge 25 -and $pcsNoWords.Count -eq 0) "and not one of the $($pcsRows.Count) rows prints a result with nothing after the colon ($($pcsNoWords -join ' | '))"
} else {
    $notSkipped = @($checkLines | Where-Object { $_ -notmatch '\] SKIP ' })
    Assert-That ($notSkipped.Count -le 2 -and $r.Code -eq 0) "off Windows the checks are skipped, none fails ($($notSkipped.Count) of $($checkLines.Count) not skipped)"
}
if ($failures -gt 0) { Write-Host ($r.Text -split "`n" | Select-Object -Last 40 | Out-String) }

if ($failures -eq 0) { Write-Host "`nWINDOWS UNIT TESTS PASSED" -ForegroundColor Green } else { Write-Host "`nWINDOWS UNIT TESTS FAILED ($failures)" -ForegroundColor Red }
exit $failures
