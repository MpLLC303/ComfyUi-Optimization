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

if ($failures -eq 0) { Write-Host "`nWINDOWS UNIT TESTS PASSED" -ForegroundColor Green } else { Write-Host "`nWINDOWS UNIT TESTS FAILED ($failures)" -ForegroundColor Red }
exit $failures
