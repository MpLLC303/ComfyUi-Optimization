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
$specs = @(Get-LaiShortcutSpecs -AIRoot "C:\It's AI" -WebUIPort 3001)
Assert-That ($specs.Count -eq 7) "seven shortcut specs (got $($specs.Count))"
$upd = $specs | Where-Object { $_.Name -like '*Update toolkit*' }
Assert-That ($upd -and $upd.Arguments -match 'LOCALAI_ROOT' -and $upd.Arguments -notmatch '-AIRoot') 'Update toolkit passes the AI root via LOCALAI_ROOT'
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
    $r = & $runTs 'needslogin' @()
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'NeedsLogin' -and -not ($r.Calls -match '^serve')) 'not signed in: clear error, nothing served'
    $r = & $runTs 'nohttps' @()
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'HTTPS certificates' -and -not ($r.Calls -match '^serve')) 'HTTPS certificates off: explained, serve never called (it would block)'
    $r = & $runTs 'noapply' @()
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'did not record a mapping') 'serve exits 0 but records nothing: not reported as success'
    $r = & $runTs 'ok' @('-Disable')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'removed') '-Disable with nothing mapped is fine (idempotent)'
    $r = & $runTs 'hang' @()
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'did not answer within 8 s' -and $r.Seconds -lt 40) ("a hung tailscale CLI times out instead of hanging ({0:N0} s)" -f $r.Seconds)
} finally {
    $env:Path = $savedPath; if (-not $onWindows) { $env:PATH = $savedPATH }
    $env:LAI_TS_SCENARIO = ''; $env:LOCALAI_TS_TIMEOUT = ''
}

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
$cmdTr = "[System.Globalization.CultureInfo]::CurrentCulture = 'tr-TR'; & '" + (Join-Path $src 'Get-LocalAIDiagnostics.ps1').Replace("'", "''") + "' -AIRoot '" + $tRoot.Replace("'", "''") + "' -OutDir '" + $outTr.Replace("'", "''") + "'; exit 0"
& $childExe -NoProfile -ExecutionPolicy Bypass -Command $cmdTr 2>&1 | Out-Null
$codeTr = $LASTEXITCODE; $ErrorActionPreference = $prev
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
Remove-LaiTree -Path $tree
Assert-That (-not (Test-Path -LiteralPath $tree)) 'the tree is gone'
Assert-That ((Test-Path -LiteralPath (Join-Path $victim 'important.txt')) -and (Get-Content -LiteralPath (Join-Path $victim 'important.txt')) -eq 'keep') 'what the link pointed at is untouched'

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
    $tpl = @($instAst2.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like '*com.docker.compose.project*' }, $true))[0].Value
    $shimDir = Join-Path $Work 'dockershim'
    New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
    $rawFile = Join-Path $shimDir 'args.txt'
    Set-Content -LiteralPath (Join-Path $shimDir 'docker.cmd') -Encoding ASCII -Value ("@echo off`r`n>`"$rawFile`" echo %*")
    $savedPath = $env:Path; $env:Path = "$shimDir;$env:Path"
    try { Invoke-Native -File 'docker' -Arguments @('ps', '-a', '--format', $tpl) -Capture -AllowFail | Out-Null } finally { $env:Path = $savedPath }
    $raw = ''; if (Test-Path -LiteralPath $rawFile) { $raw = (Get-Content -LiteralPath $rawFile -Raw).Trim() }
    Assert-That ($raw.Contains($tpl)) "docker receives the template unchanged ($raw)"
} else { Skip 'native argument check runs on Windows only' }

if ($failures -eq 0) { Write-Host "`nWINDOWS UNIT TESTS PASSED" -ForegroundColor Green } else { Write-Host "`nWINDOWS UNIT TESTS FAILED ($failures)" -ForegroundColor Red }
exit $failures
