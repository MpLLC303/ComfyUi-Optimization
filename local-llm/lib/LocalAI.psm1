# LocalAI.psm1 - shared helpers for the local AI stack (Ollama + Open WebUI + SearXNG).
#
# Compatibility rules for this file (it must run on Windows PowerShell 5.1 AND PowerShell 7):
#   - ASCII only. PS 5.1 reads BOM-less .ps1/.psm1 files as ANSI, so smart quotes break parsing.
#   - No ?? / ?. / ternary / && / || operators.
#   - Every Invoke-RestMethod goes through Invoke-LaiApi (UTF-8 body bytes, -UseBasicParsing).
#
# Nothing in here is Windows-specific; the Windows-only steps live in Install-LocalAI.ps1.
# That split lets the API layer be integration-tested against real Ollama/Open WebUI on Linux.

Set-StrictMode -Version 1

# Windows PowerShell 5.1 on .NET 4.x may still default to SSL3/TLS 1.0, which registries and GitHub
# refuse. Every script imports this module, so enabling TLS 1.2 here covers all of them.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose 'TLS setting unavailable' }

# The RAG self-test's temporary collection and uploaded file (exact names; see Get-LaiWebUISelfTestLeftover).
$script:LaiSelfTestKb = 'LocalAI Self-Test (temporary)'
$script:LaiSelfTestFile = 'localai-selftest-manual.md'

#region Logging and small utilities -------------------------------------------------------

function Write-LaiLog {
    param(
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'FAIL')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message
    )
    $colors = @{ INFO = 'Gray'; STEP = 'Cyan'; OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }
    $line = '{0} [{1,-4}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $colors[$Level]
}

function ConvertTo-LaiCmdArg {
    # Quotes one argument for a Windows command line (scheduled task action, shortcut, Start-Process
    # string), the way CommandLineToArgvW / powershell.exe read it back: backslashes before a quote
    # are doubled, so 'D:\' or 'D:\AI\' does not turn the closing quote into a literal one.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]'\') { $slashes++; continue }
        if ($ch -eq [char]'"') { [void]$sb.Append('\', 2 * $slashes + 1); [void]$sb.Append('"') }
        else { [void]$sb.Append('\', $slashes); [void]$sb.Append($ch) }
        $slashes = 0
    }
    [void]$sb.Append('\', 2 * $slashes)
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Remove-LaiTree {
    # Deletes a file or directory tree WITHOUT following a junction or symbolic link inside it: a link
    # is removed as a link, never what it points at. Windows PowerShell 5.1's Remove-Item -Recurse
    # follows directory junctions, so in the elevated installer, working in C:\AI (which the user and
    # anything running as the user controls), a planted junction would make it delete system files.
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) } else { [IO.File]::Delete($item.FullName) }
        return
    }
    if (-not $item.PSIsContainer) {
        $item.Attributes = [IO.FileAttributes]::Normal
        [IO.File]::Delete($item.FullName)
        return
    }
    foreach ($child in @((New-Object System.IO.DirectoryInfo($item.FullName)).GetFileSystemInfos())) { Remove-LaiTree -Path $child.FullName }
    [IO.Directory]::Delete($item.FullName, $false)
}

function ConvertTo-LaiPsQuoted {
    # A path as a PowerShell single-quoted literal, for commands printed for the user to paste.
    # PowerShell also ends a single-quoted string at the typographic quotes U+2018-U+201B: doubled too.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $t = $Value
    foreach ($q in @("'", [string][char]0x2018, [string][char]0x2019, [string][char]0x201A, [string][char]0x201B)) { $t = $t.Replace($q, $q + $q) }
    return "'" + $t + "'"
}

function Get-LaiScriptCommandLine {
    # powershell.exe arguments that run one toolkit script with -AIRoot (scheduled tasks, shortcuts).
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$AIRoot, [string]$Extra = '', [switch]$Hidden)
    $s = '-NoProfile -ExecutionPolicy Bypass '
    if ($Hidden) { $s += '-WindowStyle Hidden ' }
    $s += '-File ' + (ConvertTo-LaiCmdArg $ScriptPath) + ' -AIRoot ' + (ConvertTo-LaiCmdArg $AIRoot)
    if ($Extra) { $s += ' ' + $Extra }
    return $s
}

function Get-LaiHiddenTaskLaunch {
    # Execute + Argument for a scheduled task that runs powershell.exe with no window at all.
    # '-WindowStyle Hidden' alone is not enough on Windows 11, where Windows Terminal is the default
    # console host: the task still opens a terminal (only minimized), and closing it kills the run -
    # for the backup possibly between stopping and starting Open WebUI. conhost --headless (Windows
    # 10 2004, build 19041, and later) never creates a window. -WindowStyle Hidden stays in $PsArgs
    # for the older-Windows fallback. -Build / -ConhostPath: for tests.
    param([Parameter(Mandatory)][string]$PsArgs, [int]$Build = 0, [string]$ConhostPath = '')
    if ($Build -le 0) { $Build = [Environment]::OSVersion.Version.Build }
    if (-not $ConhostPath -and $env:WINDIR) { $ConhostPath = Join-Path $env:WINDIR 'System32\conhost.exe' }
    if ($Build -ge 19041 -and $ConhostPath -and (Test-Path -LiteralPath $ConhostPath)) {
        return [pscustomobject]@{ Execute = $ConhostPath; Argument = ('--headless powershell.exe ' + $PsArgs) }
    }
    return [pscustomobject]@{ Execute = 'powershell.exe'; Argument = $PsArgs }
}

function Get-LaiLastDailyRun {
    # The most recent moment, at or before -Now, at which a daily schedule ('HH:mm') was due.
    param([Parameter(Mandatory)][string]$At, [datetime]$Now = (Get-Date))
    $t = [datetime]::ParseExact($At.Trim(), 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $due = $Now.Date.Add($t.TimeOfDay)
    if ($due -gt $Now) { $due = $due.AddDays(-1) }
    return $due
}

function Invoke-LaiTimedNative {
    # Runs a native program with a time limit. For CLIs that can wait forever on a stuck service:
    # Docker Desktop's backend can stop answering after sleep while its pipe still accepts
    # connections, and every docker command then blocks. A scheduled task would hang until Task
    # Scheduler kills it, with nothing logged; with this the caller reports it instead. On timeout
    # the whole process tree is killed (a .cmd wrapper would otherwise leave its child running).
    # Each argument is quoted for the Windows command line (paths with spaces survive); output is
    # read as UTF-8 (docker writes UTF-8). Returns ExitCode (-1 on timeout), TimedOut, Out (stdout)
    # and Text (stdout + stderr, for messages).
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [int]$TimeoutSec = 30)
    $exe = Get-Command $File -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { throw "$File was not found. Is it installed (and on PATH)?" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$exe.Source
    $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-LaiCmdArg ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
        if ($env:OS -eq 'Windows_NT') {
            # Local 'Continue': under 'Stop', Windows PowerShell turns taskkill's stderr into an error.
            $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null } finally { $ErrorActionPreference = $prevEap }
        }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { Write-Verbose 'already gone' }
        return [pscustomobject]@{ ExitCode = -1; TimedOut = $true; Out = ''; Text = "no answer within $TimeoutSec s" }
    }
    # Reading has a limit too: a child that outlived the program could keep the pipes open.
    $out = ''; $err = ''
    if ([System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($outTask, $errTask), 10000)) { $out = [string]$outTask.Result; $err = [string]$errTask.Result }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; TimedOut = $false; Out = $out; Text = ($out + $err).Trim() }
}

function Get-LaiDockerTimeout {
    # Seconds a quick docker command (version, inspect, start, exec of a probe) may take before
    # Docker Desktop counts as not responding. LOCALAI_DOCKER_TIMEOUT: test hook.
    $s = 30
    # Only a positive whole number counts. The nightly backup and the model update ask for this at
    # their start: a value that is no number, left in the owner's variables, must not end them.
    $asked = 0
    if ($env:LOCALAI_DOCKER_TIMEOUT -and [int]::TryParse([string]$env:LOCALAI_DOCKER_TIMEOUT, [ref]$asked) -and $asked -gt 0) { $s = $asked }
    return $s
}

function Test-LaiDockerEngine {
    # 'ok'; 'down' (the CLI answered: the engine is not running); 'hung' (no answer within the limit:
    # Docker Desktop is stuck, as it can be after sleep - restarting it is the fix); 'missing' (no
    # docker CLI on PATH).
    param([int]$TimeoutSec = 30)
    if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) { return 'missing' }
    $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('version', '--format', '{{.Server.Version}}') -TimeoutSec $TimeoutSec
    if ($r.TimedOut) { return 'hung' }
    if ($r.ExitCode -eq 0) { return 'ok' }
    return 'down'
}

function Get-LaiChatsInFlight {
    # Chat answers the render guard is forwarding right now; -1 when it cannot tell (no guard, Docker
    # not answering, a guard that is off the chat path): then nothing waits. The status page probes
    # every ComfyUI first; a busy or firewalled one can make that take ~10 s, exactly while chats run
    # slowly on the CPU: 15 s (tests/test_render_guard.py checks the margin), within -TimeoutSec.
    # LOCALAI_TEST_CHATS_IN_FLIGHT: test hook, the count to report; 'after-load' reports 1 only with
    # -AfterLoad (a chat that started while the nightly re-check measured a model), else 0.
    param([int]$TimeoutSec = 30, [switch]$AfterLoad)
    if ($env:LOCALAI_TEST_CHATS_IN_FLIGHT) {
        if ($env:LOCALAI_TEST_CHATS_IN_FLIGHT -eq 'after-load') { if ($AfterLoad) { return 1 }; return 0 }
        return [int]$env:LOCALAI_TEST_CHATS_IN_FLIGHT
    }
    $py = "import json,urllib.request as u;print(json.load(u.urlopen('http://127.0.0.1:11434/render-guard/status',timeout=15))['inflight'])"
    try { $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('exec', 'render-guard', 'python3', '-c', $py) -TimeoutSec $TimeoutSec } catch { return -1 }
    $m = [regex]::Match([string]$r.Out, '(?m)^\s*(\d+)\s*$')
    if ($r.ExitCode -ne 0 -or -not $m.Success) { return -1 }
    return [int]$m.Groups[1].Value
}

function ConvertTo-LaiHashtable {
    # PS 5.1 has no ConvertFrom-Json -AsHashtable; this converts PSCustomObject trees recursively.
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-LaiHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [pscustomobject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-LaiHashtable $p.Value }
        return $h
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $list = @()
        foreach ($item in $InputObject) { $list += , (ConvertTo-LaiHashtable $item) }
        return , $list
    }
    return $InputObject
}

function ConvertFrom-LaiStateFile([string]$Path) {
    # $null when missing, empty or unreadable JSON; otherwise a hashtable.
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # -Encoding UTF8: Windows PowerShell 5.1 reads BOM-less files in the ANSI code page otherwise.
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { $h = ConvertTo-LaiHashtable ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
    if ($h -isnot [hashtable]) { return $null }
    return $h
}

function Read-LaiState {
    # A state file cut short (power loss, full disk) must not stop every script that reads it: fall
    # back to the previous good copy that Save-LaiState keeps (<file>.bak), else start empty. The
    # damaged file is kept as <file>.bad for inspection.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    $h = ConvertFrom-LaiStateFile $Path
    if ($null -ne $h) { return $h }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { $bak = ConvertFrom-LaiStateFile "$Path.bak"; if ($null -ne $bak) { return $bak }; return @{} }
    try { Copy-Item -LiteralPath $Path -Destination "$Path.bad" -Force -ErrorAction Stop } catch { Write-Verbose 'could not keep the damaged copy' }
    $bak = ConvertFrom-LaiStateFile "$Path.bak"
    if ($null -ne $bak) {
        Write-LaiLog WARN "$(Split-Path -Leaf $Path) was damaged (kept as .bad); using the previous saved copy."
        return $bak
    }
    Write-LaiLog WARN "$(Split-Path -Leaf $Path) was damaged (kept as .bad) and there is no earlier copy; starting from empty settings."
    return @{}
}

function Save-LaiState {
    # Atomic: write a temp file next to it, then swap it in (the old version becomes <file>.bak), so a
    # crash mid-write never leaves a half-written file. -ErrorAction Stop everywhere: inside a module
    # the caller's $ErrorActionPreference does not apply, and a failed save must not pass silently.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
    $State['updated'] = (Get-Date).ToString('s')
    $json = ConvertTo-Json -InputObject $State -Depth 20
    $tmp = "$Path.tmp"
    # With a BOM, like the Set-Content -Encoding UTF8 this replaced: any 5.1 reader (Get-Content
    # without -Encoding, older copies of these scripts) then still decodes non-ASCII paths correctly.
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($true)))
    for ($i = 1; $i -le 5; $i++) {
        try {
            if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, "$Path.bak") }
            else { [System.IO.File]::Move($tmp, $Path) }
            return
        } catch {
            # A reader holding the file open (antivirus, another script) blocks the swap briefly.
            if ($i -eq 5) { throw "Could not save $Path : $($_.Exception.Message)" }
            Start-Sleep -Milliseconds (200 * $i)
        }
    }
}

function Get-LaiBlockRange {
    <#
    .SYNOPSIS
        Every IPv4 address EXCEPT the given CIDR blocks, as firewall ranges ("a.b.c.d-e.f.g.h"). Used
        for the Ollama block rule: everything but loopback and the Docker/WSL subnets is blocked,
        whichever adapter it arrives on (Wi-Fi, Ethernet, Tailscale, VPN, adapters added later).
    #>
    param([Parameter(Mandatory)][string[]]$Allowed)
    $toLong = { param($ip) $o = @($ip.Split('.') | ForEach-Object { [long]$_ }); return ($o[0] * 16777216 + $o[1] * 65536 + $o[2] * 256 + $o[3]) }
    $toIp = { param([long]$n) return ('{0}.{1}.{2}.{3}' -f [math]::Floor($n / 16777216), ([math]::Floor($n / 65536) % 256), ([math]::Floor($n / 256) % 256), ($n % 256)) }
    $spans = @()
    foreach ($c in $Allowed) {
        $parts = $c.Split('/')
        $bits = 32; if ($parts.Count -gt 1) { $bits = [int]$parts[1] }
        $size = [long][math]::Pow(2, 32 - $bits)
        $start = [long]([math]::Floor((& $toLong $parts[0]) / $size) * $size)
        $spans += , @($start, ($start + $size - 1))
    }
    $spans = @($spans | Sort-Object { $_[0] })
    $out = @()
    $next = [long]0
    foreach ($sp in $spans) {
        if ($sp[0] -gt $next) { $out += ('{0}-{1}' -f (& $toIp $next), (& $toIp ($sp[0] - 1))) }
        if ($sp[1] + 1 -gt $next) { $next = $sp[1] + 1 }
    }
    if ($next -le 4294967295) { $out += ('{0}-{1}' -f (& $toIp $next), '255.255.255.255') }
    return $out
}

function Get-LaiReparsePath {
    # The path itself or the first folder above it that is a junction or symbolic link, else $null.
    # The elevated installer works in C:\AI, which the user (and anything running as the user)
    # controls: a planted link would point its permission changes and writes somewhere else.
    param([Parameter(Mandatory)][string]$Path)
    $p = [System.IO.Path]::GetFullPath($Path)
    while ($p) {
        if (Test-Path -LiteralPath $p) {
            $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $p }
        }
        $parent = [System.IO.Path]::GetDirectoryName($p)
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
    return $null
}

function Enable-LaiKeepAwake {
    # Keeps Windows from sleeping while this process runs (an install downloads for hours; a sleep
    # mid-download fails the pull). The display may still turn off. Ends with the process. Returns
    # whether it took ($false off Windows or if the call is not available).
    if ($env:OS -ne 'Windows_NT') { return $false }
    try {
        if (-not ('LaiPower' -as [type])) {
            Add-Type -Namespace '' -Name 'LaiPower' -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
        }
        # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        return ([LaiPower]::SetThreadExecutionState([uint32]2147483649) -ne 0)
    } catch { return $false }
}

function Set-LaiPrivateAcl {
    <#
    .SYNOPSIS
        Replaces a file's or folder's permissions with: the given user, SYSTEM and Administrators
        (inheritance from the parent removed, so "Authenticated Users" from C:\ no longer applies;
        an entry any other account was given by name on it is taken out, and when another account
        owns it Administrators become its owner, because an owner can give itself an entry again).
        Each entry taken out and each owner changed is logged with the account it was.
        Only the file or folder it is given: what lies in a folder keeps the entries and the owner
        of its own, so a caller names every one it means.
        -UserAccess ReadOnly gives the user read/execute only. Windows only; returns icacls' exit
        code and output (a code that is not 0, with the reason first, when the owner or an entry of
        another account could not be read, changed or taken out).
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$UserSid, [ValidateSet('Full', 'ReadOnly')][string]$UserAccess = 'Full')
    # icacls changes what a symbolic link points at: granting the user full control there would hand
    # them any file or folder on the system. Refuse links anywhere on the path.
    $link = Get-LaiReparsePath -Path $Path
    if ($link) { throw "Refusing to change permissions through a link: $link is a junction or symbolic link. Remove it and run again." }
    $inherit = ''
    if ((Get-Item -LiteralPath $Path -Force) -is [System.IO.DirectoryInfo]) { $inherit = '(OI)(CI)' }
    $userGrant = $inherit + 'F'
    if ($UserAccess -eq 'ReadOnly') { $userGrant = $inherit + 'RX' }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $left = @()
    try {
        # The call below sets the entries of the three names it is given (/grant:r) and drops what
        # was handed down from the folder above (/inheritance:r). An entry that some other account
        # was given by name on this very file or folder is neither of the two and would stay: those
        # are taken out first. Windows only (elsewhere there is no Get-Acl). .NET is asked as well as
        # the OS variable: a per-user variable of that name replaces the system's one in that user's
        # processes, the elevated installer included, and going by the variable alone anything
        # running as the user could switch this off.
        if ($env:OS -eq 'Windows_NT' -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $keep = @($UserSid, 'S-1-5-18', 'S-1-5-32-544')
            # An account as the log and a reason name it: the name Windows has for it, then its SID.
            $nameOf = {
                param([string]$Sid)
                $name = ''
                try { $name = [string](New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value }
                catch { Write-Verbose "Windows has no name for $Sid" }
                if ($name) { return "$name ($Sid)" }
                return $Sid
            }
            $owner = ''
            $others = @()
            $wasRead = $false
            try {
                $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
                $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier])
                if ($null -ne $ownerSid) { $owner = [string]$ownerSid.Value }
                # ($true, $false): the entries it holds as its own, not the ones handed down.
                $others = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) |
                    ForEach-Object { [string]$_.IdentityReference.Value } | Where-Object { $keep -notcontains $_ } | Sort-Object -Unique)
                $wasRead = $true
            } catch { $left += "its owner and the entries other accounts hold on it could not be read ($(([string]$_.Exception.Message).Trim()))" }
            # The owner first. Whoever owns a file or folder may rewrite its permissions whatever
            # they say, so an owner outside the three could put its entry straight back; and with
            # Administrators as the owner the calls after this one are allowed in any case.
            if ($wasRead -and -not $owner) { $left += 'its owner could not be read' }
            elseif ($owner -and $keep -notcontains $owner) {
                $who = & $nameOf $owner
                $said = & icacls.exe $Path '/setowner' '*S-1-5-32-544' 2>&1 | ForEach-Object { "$_" }
                if ($LASTEXITCODE -ne 0) { $left += "its owner is $who, who can give itself access again, and that could not be changed ($($said -join ' '))" }
                else { Write-LaiLog INFO "Permissions on ${Path}: it was owned by $who, who could have given itself access again; Administrators own it now" }
            }
            foreach ($other in $others) {
                $who = & $nameOf $other
                $said = & icacls.exe $Path '/remove' "*$other" 2>&1 | ForEach-Object { "$_" }
                if ($LASTEXITCODE -ne 0) { $left += "the entry of $who could not be removed ($($said -join ' '))" }
                else { Write-LaiLog INFO "Permissions on ${Path}: the entry of $who was removed (only the user, SYSTEM and Administrators are to have one)" }
            }
        }
        $out = & icacls.exe $Path '/inheritance:r' '/grant:r' "*${UserSid}:$userGrant" "*S-1-5-18:${inherit}F" "*S-1-5-32-544:${inherit}F" 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    $text = ($out -join "`n")
    if ($left.Count -gt 0) {
        # The three names are set all the same. What may be left for somebody else is a failure, in
        # words, even where the call above went through.
        if ($code -eq 0) { $code = 1 }
        $text = ((@($left) + @($text)) -join "`n")
    }
    return [pscustomobject]@{ ExitCode = $code; Text = $text }
}

function Get-LaiWebUIHold {
    <#
    .SYNOPSIS
        A failed restore can leave Open WebUI stopped on purpose (its volume may be half-swapped). It
        records that in <AIRoot>\open-webui-hold.json; the watch, Start-LocalAI and the installer must
        not start the container while it exists. Returns the hold (reason, recover, containers) or $null.
    #>
    param([Parameter(Mandatory)][string]$AIRoot)
    $path = Join-Path $AIRoot 'open-webui-hold.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $h = Read-LaiState -Path $path
    $h['Path'] = $path
    return $h
}

function New-LaiSecret {
    # Hex secret from the OS CSPRNG (same construction as the guide's Step 19).
    param([int]$Bytes = 32)
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return (($buffer | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-LaiPassword {
    # 24 chars from an unambiguous alphabet; satisfies any reasonable complexity rule.
    param([int]$Length = 24)
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $buffer = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    $chars = foreach ($b in $buffer) { $alphabet[$b % $alphabet.Length] }
    return ('Lai-' + (-join $chars) + '-9x')
}

function Protect-LaiSecretText {
    # The text protected with the Windows account that runs this (DPAPI, scope CurrentUser, no extra
    # entropy), as Base64: only that account on this Windows opens it again. It throws when it
    # cannot and never returns nothing or an empty text. A failed .NET call only ends its own
    # statement, and this module sets no error preference: so every one sits in a try that throws.
    # The type is loaded here, behind the check for Windows, never when the module is imported, and
    # is asked for by name: Windows PowerShell does not have it until System.Security is loaded.
    param([Parameter(Mandatory)][string]$Text)
    if ($env:OS -ne 'Windows_NT') { throw 'Protecting a stored password with the Windows account works on Windows only.' }
    $blob = ''
    try {
        $protector = 'System.Security.Cryptography.ProtectedData' -as [type]
        if (-not $protector) {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $protector = 'System.Security.Cryptography.ProtectedData' -as [type]
        }
        if (-not $protector) { throw 'the type ProtectedData is not there' }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $blob = [Convert]::ToBase64String($protector::Protect($bytes, $null, 'CurrentUser'))
    } catch {
        $said = $_.Exception
        if ($said.InnerException) { $said = $said.InnerException }
        throw "Windows data protection did not work in this session ($(([string]$said.Message).Trim()))."
    }
    if (-not $blob) { throw 'Windows data protection did not work in this session (no result).' }
    return $blob
}

function Unprotect-LaiSecretText {
    # The text Protect-LaiSecretText protected. Text that is not Base64, that was changed, or that
    # another account protected throws: a value this account cannot open is never an empty text.
    param([Parameter(Mandatory)][string]$Blob)
    if ($env:OS -ne 'Windows_NT') { throw 'Protecting a stored password with the Windows account works on Windows only.' }
    $protector = $null
    try {
        $protector = 'System.Security.Cryptography.ProtectedData' -as [type]
        if (-not $protector) {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $protector = 'System.Security.Cryptography.ProtectedData' -as [type]
        }
        if (-not $protector) { throw 'the type ProtectedData is not there' }
    } catch {
        $said = $_.Exception
        if ($said.InnerException) { $said = $said.InnerException }
        throw "Windows data protection did not work in this session ($(([string]$said.Message).Trim()))."
    }
    $cannotOpen = "This Windows account cannot open the protected password (protected by another account, or the Windows password was reset, or Windows was reinstalled, or this is a remote session without the account's key)."
    $text = $null
    try {
        $bytes = $protector::Unprotect([Convert]::FromBase64String($Blob), $null, 'CurrentUser')
        if ($null -ne $bytes) { $text = [System.Text.Encoding]::UTF8.GetString($bytes) }
    } catch { throw $cannotOpen }
    if ($null -eq $text) { throw $cannotOpen }
    return $text
}

function Read-LaiSecretFile {
    <#
    .SYNOPSIS
        Reads a stored password file (JSON: an e-mail or user name, the password, other fields) in
        either form and returns its object with 'password' filled in. The plain form ("password") is
        returned as it is. The protected form ("protected": "dpapi-user-1", the value in
        "passwordProtected") is opened with the Windows account that runs this.
        Every failure throws, each with words of its own: a file that is empty or was cut off, a form
        this version does not know, a plain file without a password, a protected file without its
        value, a value this account cannot open. None of them is ever read as an empty password.
        -NoPassword opens nothing and asks for no password: a protected file comes back with
        'password' set to '', a plain one as it is, with a password or without (for a caller that
        needs the other fields only). The two refusals of the file itself stay.
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$NoPassword)
    # Inside a module the caller's $ErrorActionPreference does not apply, and an error that only
    # ends its own statement would let this go on to its return with no password filled in.
    $ErrorActionPreference = 'Stop'
    $text = [string](Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    # The text is judged here, not by ConvertFrom-Json: an empty file reads as no text at all, which
    # 5.1 and 7 take differently, and only an object ('{') is a secret file.
    $o = $null
    if ($text.TrimStart().StartsWith('{', [System.StringComparison]::Ordinal)) { try { $o = ConvertFrom-Json -InputObject $text -ErrorAction Stop } catch { $o = $null } }
    if ($o -isnot [System.Management.Automation.PSCustomObject]) { throw "$Path is empty or was cut off: it holds no stored password." }
    # The form goes by the marker being there, not by what it holds: an empty marker is no plain file.
    $marker = $o.PSObject.Properties['protected']
    if ($null -eq $marker) {
        if ($NoPassword) { return $o }
        # A plain file is returned as it is, when it holds a password. One that holds none (the
        # field empty, or gone, or the marker of a protected file lost in an edit by hand) would
        # reach the caller as an empty password, which is what this function never hands back.
        $plain = $o.PSObject.Properties['password']
        if ($null -ne $plain -and $null -ne $plain.Value -and [string]$plain.Value -ne '') { return $o }
        $why = "$Path holds no password."
        if ($null -ne $o.PSObject.Properties['passwordProtected']) { $why += " It has a 'passwordProtected' value, but not the 'protected' field that says in which form." }
        throw $why
    }
    if (-not ($marker.Value -is [string] -and $marker.Value -ceq 'dpapi-user-1')) { throw "$Path is protected in a form this toolkit version does not know ('$([string]$marker.Value)'). Update the toolkit." }
    if ($NoPassword) {
        Add-Member -InputObject $o -NotePropertyName 'password' -NotePropertyValue '' -Force
        return $o
    }
    # Before anything is opened, so this file is refused with these words on every system.
    $held = $o.PSObject.Properties['passwordProtected']
    $blob = ''
    if ($null -ne $held -and $null -ne $held.Value) { $blob = ([string]$held.Value).Trim() }
    if (-not $blob) { throw "$Path is marked as protected but holds no protected password." }
    $password = ''
    try { $password = [string](Unprotect-LaiSecretText -Blob $blob) }
    catch { throw "Cannot read the password in ${Path}: $($_.Exception.Message)" }
    if (-not $password) { throw "$Path is marked as protected but holds no protected password." }
    Add-Member -InputObject $o -NotePropertyName 'password' -NotePropertyValue $password -Force
    return $o
}

function Save-LaiSecretFile {
    <#
    .SYNOPSIS
        Writes a stored password file: the fields of -Value (a hashtable or an object, which must
        hold a password) in the plain form ("password") or the protected one ("protected":
        "dpapi-user-1" and "passwordProtected", the password protected with the Windows account that
        runs this). A file never holds both.
        -Form Keep (the default) keeps the form of the file that is there. It goes by that file's
        marker alone and opens nothing, so it also writes over a protected value this account cannot
        open. A file that is not there, or that holds no JSON object, is written plain.
        A file with a marker this version does not know is left alone, whatever -Form says.
        Whatever fails throws, and throws before the file is touched: a caller reaches the line after
        its save only with the new password on disk. The content is replaced in place (no delete, no
        temp file swapped in), so the file keeps the permissions the installer gave it.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [ValidateSet('Keep', 'Plain', 'Protected')][string]$Form = 'Keep')
    # Inside a module the caller's $ErrorActionPreference does not apply, and an error that only
    # ends its own statement would let this run to its end, and the caller go on, with nothing saved.
    $ErrorActionPreference = 'Stop'
    # 1. The fields of the value, in its own order (a hashtable has none).
    $fields = [ordered]@{}
    if ($Value -is [System.Collections.IDictionary]) { foreach ($key in @($Value.Keys)) { $fields[[string]$key] = $Value[$key] } }
    else { foreach ($prop in @($Value.PSObject.Properties)) { $fields[[string]$prop.Name] = $prop.Value } }
    $password = ''
    if ($fields.Contains('password') -and $null -ne $fields['password']) { $password = [string]$fields['password'] }
    if (-not $password) { throw "Nothing to store in ${Path}: the value has no password." }
    # 2. The form. Only the marker of the file that is there is looked at, as text.
    $marker = $null
    if (Test-Path -LiteralPath $Path) {
        $oldText = [string](Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop)
        if ($oldText.Length -gt 0 -and $oldText[0] -eq [char]0xFEFF) { $oldText = $oldText.Substring(1) }
        $old = $null
        if ($oldText.TrimStart().StartsWith('{', [System.StringComparison]::Ordinal)) { try { $old = ConvertFrom-Json -InputObject $oldText -ErrorAction Stop } catch { $old = $null } }
        if ($old -is [System.Management.Automation.PSCustomObject]) { $marker = $old.PSObject.Properties['protected'] }
    }
    $isProtected = ($null -ne $marker -and $marker.Value -is [string] -and $marker.Value -ceq 'dpapi-user-1')
    if ($null -ne $marker -and -not $isProtected) { throw "$Path is protected in a form this toolkit version does not know ('$([string]$marker.Value)'). Update the toolkit." }
    $toForm = $Form
    if ($toForm -eq 'Keep') {
        $toForm = 'Plain'
        if ($isProtected) { $toForm = 'Protected' }
    }
    # 3. The whole new text, in memory: the other fields, then the password in its form.
    $out = [ordered]@{}
    foreach ($name in @($fields.Keys)) { if (@('password', 'protected', 'passwordProtected') -notcontains $name) { $out[$name] = $fields[$name] } }
    if ($toForm -eq 'Protected') {
        $blob = ''
        try { $blob = [string](Protect-LaiSecretText -Text $password) }
        catch { throw "Cannot store the password in ${Path}: $($_.Exception.Message)" }
        if (-not $blob) { throw "Cannot store the password in ${Path}: Windows data protection did not work in this session (no result)." }
        $out['protected'] = 'dpapi-user-1'
        $out['passwordProtected'] = $blob
    } else { $out['password'] = $password }
    $json = ConvertTo-Json -InputObject $out -Depth 20
    # 4. Only now the file.
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8 -ErrorAction Stop
}

function Invoke-LaiRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$Attempts = 3,
        [int]$DelaySeconds = 5,
        [string]$What = 'operation'
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        try { return (& $Action) }
        catch {
            if ($i -eq $Attempts) { throw }
            Write-LaiLog WARN "$What failed (attempt $i/$Attempts): $($_.Exception.Message). Retrying in $DelaySeconds s."
            Start-Sleep -Seconds $DelaySeconds
            $DelaySeconds = [Math]::Min($DelaySeconds * 2, 60)
        }
    }
}

#endregion

#region HTTP ------------------------------------------------------------------------------

function Invoke-LaiApi {
    param(
        [ValidateSet('GET', 'POST', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        $Body = $null,
        [string]$Token = '',
        [int]$TimeoutSec = 60
    )
    $params = @{
        Method          = $Method
        Uri             = $Uri
        TimeoutSec      = $TimeoutSec
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
        Headers         = @{}
    }
    if ($Token) { $params.Headers['Authorization'] = "Bearer $Token" }
    if ($null -ne $Body) {
        if ($Body -is [string]) { $json = $Body } else { $json = ConvertTo-Json -InputObject $Body -Depth 30 -Compress }
        $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes($json)
        $params['ContentType'] = 'application/json; charset=utf-8'
    }
    # Decode the reply as UTF-8 ourselves: Open WebUI (FastAPI) sends 'application/json' without a
    # charset, and Invoke-RestMethod on Windows PowerShell 5.1 then reads it as ISO-8859-1, so every
    # read-modify-write of its settings would double-encode non-ASCII names and prompts.
    # (No progress bar: on 5.1 it slows big transfers several-fold.)
    $ProgressPreference = 'SilentlyContinue'
    $resp = Invoke-WebRequest @params
    $bytes = $resp.RawContentStream.ToArray()
    if ($bytes.Length -eq 0) { return $null }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    # Open WebUI serves its web app for any unknown path with status 200: a moved or removed API
    # endpoint answers with an HTML page. Treating that as data hides the change (or reads a setting
    # as 'off'), so say what happened instead.
    if ($text -match '^\s*<(!doctype|html)') { throw "$Uri returned a web page instead of data: this API is not available in this Open WebUI version." }
    try { return (ConvertFrom-Json -InputObject $text -ErrorAction Stop) } catch { return $text }
}

function Get-LaiHttpStatus {
    # HTTP status code from an Invoke-RestMethod error record (0 = no HTTP response at all).
    param($ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($null -eq $resp) { return 0 }
        return [int]$resp.StatusCode
    } catch { return 0 }
}

function Test-LaiConnectionRefused {
    # True when nothing listens at the address (the service is not running), from the exception
    # TYPES, not their text: the message is translated on non-English Windows.
    param($ErrorRecord)
    $e = $ErrorRecord
    if ($e -is [System.Management.Automation.ErrorRecord]) { $e = $e.Exception }
    while ($e) {
        if ($e -is [System.Net.Sockets.SocketException] -and $e.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) { return $true }
        if ($e -is [System.Net.WebException] -and $e.Status -eq [System.Net.WebExceptionStatus]::ConnectFailure) { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Get-LaiHttpErrorText {
    # One-line error text; prefers the API's own {"detail": ...} / {"error": ...} message.
    param($ErrorRecord)
    $text = $ErrorRecord.Exception.Message
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $text = $ErrorRecord.ErrorDetails.Message
        try {
            $j = $text | ConvertFrom-Json
            if ($j.PSObject.Properties.Name -contains 'detail' -and $j.detail) { $text = [string]$j.detail }
            elseif ($j.PSObject.Properties.Name -contains 'error' -and $j.error) { $text = [string]$j.error }
        } catch { Write-Verbose 'error body is not JSON' }
    }
    return (($text -replace '\s+', ' ').Trim())
}

function Wait-LaiHttp {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutSec = 120,
        [scriptblock]$Condition = $null
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-LaiApi -Uri $Uri -TimeoutSec 10
            if ($null -eq $Condition -or (& $Condition $r)) { return $r }
            $last = 'condition not met yet'
        } catch { $last = $_.Exception.Message }
        Start-Sleep -Seconds 2
    }
    throw "Timed out after $TimeoutSec s waiting for $Uri ($last)"
}

function New-LaiVolumeMutex {
    # The installer and Uninstall run elevated; a mutex they create gets an admin-only DACL by default, and a
    # non-elevated restore or the health watch could then not even open it. On Windows PowerShell
    # create it so every signed-in user may wait on it. Falls back to the default (other platforms,
    # or a mutex an older version already created) - then UnauthorizedAccessException means "busy".
    param([string]$Name = 'Global\LocalAI-OpenWebUI-Volume',
        [string]$BusyMessage = 'Another backup/restore of the Open WebUI volume is running with administrator rights. Wait for it to finish (or run this elevated).')
    $name = $Name
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        try {
            $sec = New-Object System.Security.AccessControl.MutexSecurity
            $sid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid, $null)
            $rights = [System.Security.AccessControl.MutexRights]::Synchronize -bor [System.Security.AccessControl.MutexRights]::Modify
            $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($sid, $rights, [System.Security.AccessControl.AccessControlType]::Allow)))
            $created = $false
            return [System.Threading.Mutex]::new($false, $name, [ref]$created, $sec)
        } catch [System.UnauthorizedAccessException] {
            throw $BusyMessage
        } catch { Write-Verbose "mutex ACL not applied: $($_.Exception.Message)" }
    }
    try { return (New-Object System.Threading.Mutex($false, $name)) }
    catch [System.UnauthorizedAccessException] {
        throw $BusyMessage
    }
}

function Test-LaiVolumeLockBusy {
    # $true while a backup/restore/update holds the volume lock (never waits).
    $m = $null
    try { $m = New-LaiVolumeMutex } catch { return $true }
    try {
        $got = $false
        try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if ($got) { $m.ReleaseMutex(); return $false }
        return $true
    } finally { $m.Dispose() }
}

function Enter-LaiVolumeLock {
    # Machine-wide lock so the scheduled backup and a restore never touch the volume at the same time.
    # Re-entrant on the same thread (Restore calls Backup for its safety copy). Returns the mutex.
    param([int]$TimeoutSec = 600)
    $m = New-LaiVolumeMutex
    try { $got = $m.WaitOne([TimeSpan]::FromSeconds($TimeoutSec)) }
    catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { $m.Dispose(); throw "Another backup/restore of the Open WebUI volume is still running (waited $TimeoutSec s)." }
    return $m
}

function Exit-LaiVolumeLock {
    param($Mutex)
    if ($Mutex) { try { $Mutex.ReleaseMutex() } catch { Write-Verbose 'lock already released' }; $Mutex.Dispose() }
}

function Enter-LaiSetupLock {
    # One installer run or model update at a time: both load, tune and rebuild the same models, and
    # two of them interleaved leave tuning results that match neither. Does not wait; throws when
    # busy. Released when the process exits (even if it is killed). Returns the mutex.
    $busy = 'Another Local AI installer run or model update is already running. Wait for it to finish (or close an installer window that is still open), then try again.'
    $m = New-LaiVolumeMutex -Name 'Global\LocalAI-Setup' -BusyMessage $busy
    $got = $false
    try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { $m.Dispose(); throw $busy }
    return $m
}

function Test-LaiSetupLockBusy {
    # $true while an installer run or a model update holds the setup lock (never waits). The health
    # watch asks before its integrity comparison: an update in progress is replacing the very files
    # it would compare.
    $m = $null
    try { $m = New-LaiVolumeMutex -Name 'Global\LocalAI-Setup' -BusyMessage 'the setup lock is held with administrator rights' } catch { return $true }
    try {
        $got = $false
        try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if ($got) { $m.ReleaseMutex(); return $false }
        return $true
    } finally { $m.Dispose() }
}

#endregion

#region Integrity watch (what changed outside an install or update) -------------------------
# A baseline (<AIRoot>\integrity-baseline.json) records, at the end of every successful install or
# update: the SHA-256 of each file under <AIRoot>\Scripts and <AIRoot>\Stack, a fingerprint of the
# settings in Stack\.env that say where chats and searches are sent, what each LocalAI-* scheduled
# task runs, as whom and at what privilege, and which programs listen on which TCP ports.
# Watch-LocalAI.ps1 compares the PC with it about once an hour and names what differs.
# Not compared: the rest of Stack\.env (versions, ports, keys, the extra origins that
# Enable-TailscaleAccess.ps1 sets), logs, the .tmp/.bak/.bad leftovers of a save, and anything in a
# folder called Secrets.
#
# What this is good for, and what it is not: the baseline lives in the install folder, which the
# signed-in user (and so anything running as that user) can write. It catches accidental changes,
# other software and unsophisticated tampering. It does NOT stop, or even notice, an attacker who
# already runs as the owner and rewrites the baseline (or the watch, or the watch's own record)
# together with the change. And program names are only names: anything that calls itself 'ollama'
# reads as Ollama here. Nor is every new listener news: a program that accepted connections on one
# of Windows' per-start ports (49152 and up) when the baseline was recorded may open any number of
# them without a word, and so may anything with its name; a listener an install knew stays
# accepted for 90 days after it was last seen (ConvertTo-LaiListenerBaseline).

function Get-LaiIntegrityPath {
    # The baseline file: next to the other state files, never under Scripts or Stack (it would be
    # part of what it describes).
    param([Parameter(Mandatory)][string]$AIRoot)
    return (Join-Path $AIRoot 'integrity-baseline.json')
}

function Test-LaiIntegrityExcluded {
    # Pure (unit-tested). Names the file comparison leaves out because they change in normal use:
    # Stack\.env (updates and the Tailscale script rewrite it, and it holds secrets; the settings in
    # it that decide where chats go are compared by name, see ConvertTo-LaiIntegrityEnv), logs, and
    # the .tmp/.bak/.bad leftovers of a file being saved. A folder called Secrets is never entered,
    # so nothing in it is listed, read or hashed.
    param([Parameter(Mandatory)][string]$Name, [switch]$Folder)
    if ($Folder) { return ($Name -eq 'Secrets') }
    if ($Name -eq '.env') { return $true }
    foreach ($pattern in @('*.log', '*.tmp', '*.bak', '*.bad')) { if ($Name -like $pattern) { return $true } }
    return $false
}

function ConvertTo-LaiIntegrityName {
    # Pure (unit-tested). A file, task, setting or program name as it may be shown. Whoever made the
    # change chose these names (a container can create files in Stack\searxng, any program can listen
    # under any name), and they end up in a notification, in watch.log, in the health check and in
    # the Open WebUI banner, which every Open WebUI user sees rendered as Markdown. So letters,
    # digits, space, dot, underscore, hyphen and backslash stay, everything else becomes '?', and a
    # long name is cut in the middle: a name cannot carry a link, a second line or a paragraph.
    param([AllowEmptyString()][string]$Name = '', [int]$Max = 80)
    $t = [regex]::Replace($Name, '[^\p{L}\p{Nd} ._\\-]', '?')
    if ($t.Length -gt $Max) {
        $head = [int][math]::Floor(($Max - 3) / 2)
        $t = $t.Substring(0, $head) + '...' + $t.Substring($t.Length - ($Max - 3 - $head))
    }
    return $t
}

function ConvertTo-LaiIntegrityDate {
    # A time from a state file: PowerShell 7 reads an ISO string back as a date, Windows PowerShell
    # 5.1 as text. $null when it is neither.
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    return $null
}

function New-LaiIntegrityBudget {
    # How much one walk over Scripts and Stack may read: entries (files, folders, links), bytes
    # hashed and seconds. The toolkit installs well under a hundred files there. But Stack\searxng
    # is writable from inside the SearXNG container, anything running as the user can fill either
    # folder, and the watch task is ended after ten minutes: without a limit one such folder would
    # stop every later run before it reports anything at all. 'Stopped' names the first entry that
    # was not read ('' = everything was).
    param([int]$MaxEntries = 3000, [long]$MaxBytes = 300MB, [int]$MaxSeconds = 20)
    return @{ MaxEntries = $MaxEntries; MaxBytes = $MaxBytes; MaxSeconds = $MaxSeconds; Entries = 0; Bytes = [long]0; Clock = [System.Diagnostics.Stopwatch]::StartNew(); Stopped = '' }
}

function Test-LaiIntegrityOnWindows {
    # Whether the integrity walk runs on Windows, asked of .NET and not of the OS variable. A
    # per-user variable of that name (HKCU\Environment, which needs no administrator rights)
    # replaces the system's one in that user's processes, the elevated installer and its resume task
    # included: read from the variable, the walk went by path again, which is the walk that can be
    # raced (Add-LaiIntegrityEntry). Watch-LocalAI.ps1 asks the same way for its notifications.
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Initialize-LaiIntegrityNative {
    # Windows only. The Windows calls that let the integrity walk ask a handle instead of a path
    # (Add-LaiIntegrityEntry says why), compiled once per process the way Enable-LaiKeepAwake does
    # it. Returns whether they are there: $false off Windows or when they could not be compiled, and
    # the walk then records 'unreadable' and reads nothing.
    #   Open       CreateFileW, https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew :
    #              0x80000000 GENERIC_READ; 7 = FILE_SHARE_READ | WRITE | DELETE, so nobody is kept
    #              from writing, renaming or deleting meanwhile; 3 OPEN_EXISTING; 0x02300000 =
    #              FILE_FLAG_BACKUP_SEMANTICS (a folder can be opened too) |
    #              FILE_FLAG_OPEN_REPARSE_POINT (a link in the last place of the path is opened
    #              itself, not what it points at) | SECURITY_SQOS_PRESENT with SECURITY_ANONYMOUS
    #              (should a path lead to a named pipe after all, its server cannot act as this
    #              account; .NET opens every file that way). The path goes in behind \\?\, so it is
    #              taken as written whatever its length. error: 0, or the Windows error code.
    #              Only the place a walk starts from is opened this way (the install folder).
    #   OpenBelow  NtOpenFile (winternl.h), https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntopenfile ,
    #              with the handle of an open folder as the root directory and one name as the whole
    #              name: the entry of that name in the folder the handle holds. No path is looked up,
    #              so what any path to that folder leads to by now decides nothing. 0x80100000 =
    #              GENERIC_READ | SYNCHRONIZE; 7 as above; 0x00200020 = FILE_OPEN_REPARSE_POINT (a
    #              link is opened itself) | FILE_SYNCHRONOUS_IO_NONALERT (a read waits for its data,
    #              as CreateFileW arranges it); 0x40 = OBJ_CASE_INSENSITIVE. Without
    #              FILE_OPEN_FOR_BACKUP_INTENT: NtOpenFile opens a folder without it, and with it an
    #              administrator's backup privilege would stand in for the permissions of the entry.
    #              NtOpenFile opens what exists and creates nothing. A name that is no single name of
    #              a folder ('.', '..', one with a backslash, a slash or a colon, one longer than a
    #              file system allows) is not handed over (error -1). error: 0; 2 when the folder has
    #              no such entry (0xC0000034 STATUS_OBJECT_NAME_NOT_FOUND, 0xC000003A
    #              STATUS_OBJECT_PATH_NOT_FOUND); else the NTSTATUS, a negative number.
    #   FinalPath  GetFinalPathNameByHandleW, https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew :
    #              2 = FILE_NAME_NORMALIZED | VOLUME_NAME_NT. Where what the handle holds really is,
    #              in long names and with the volume as a device (\Device\HarddiskVolume3\AI\Stack).
    #              $null when Windows does not say.
    #   Describe   GetFileInformationByHandleEx, https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfileinformationbyhandleex :
    #              9 FileAttributeTagInfo (the attributes) and 1 FileStandardInfo (the size:
    #              EndOfFile, at byte 8), both of the handle. $null when Windows does not say.
    #   List       the same call with 11 FileIdBothDirectoryRestartInfo for the first entries and
    #              10 FileIdBothDirectoryInfo for the rest, until error 18 ERROR_NO_MORE_FILES
    #              (FILE_ID_BOTH_DIR_INFO: NextEntryOffset at byte 0, FileAttributes at 56,
    #              FileNameLength at 60, FileName at 104). The names in the folder the handle holds,
    #              sorted by name (ordinal), each with whether it is a folder; no more than 'room' of
    #              them, 'cut' when there were more. $null when the folder could not be listed.
    if (-not (Test-LaiIntegrityOnWindows)) { return $false }
    try {
        if (-not ('LaiIntegrityNative' -as [type])) {
            $members = @(
                '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]'
                'static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, System.IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, System.IntPtr hTemplateFile);'
                '[System.Runtime.InteropServices.DllImport("ntdll.dll")]'
                'static extern int NtOpenFile(out System.IntPtr FileHandle, uint DesiredAccess, ref OBJECT_ATTRIBUTES ObjectAttributes, System.IntPtr IoStatusBlock, uint ShareAccess, uint OpenOptions);'
                '[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]'
                'struct UNICODE_STRING { public ushort Length; public ushort MaximumLength; public System.IntPtr Buffer; }'
                '[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]'
                'struct OBJECT_ATTRIBUTES { public uint Length; public System.IntPtr RootDirectory; public System.IntPtr ObjectName; public uint Attributes; public System.IntPtr SecurityDescriptor; public System.IntPtr SecurityQualityOfService; }'
                '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]'
                'static extern uint GetFinalPathNameByHandleW(Microsoft.Win32.SafeHandles.SafeFileHandle hFile, System.Text.StringBuilder lpszFilePath, uint cchFilePath, uint dwFlags);'
                '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]'
                'static extern bool GetFileInformationByHandleEx(Microsoft.Win32.SafeHandles.SafeFileHandle hFile, int FileInformationClass, System.IntPtr lpFileInformation, uint dwBufferSize);'
                'public static Microsoft.Win32.SafeHandles.SafeFileHandle Open(string path, out int error) {'
                '    error = -1;'
                '    // A device name (\\.\NUL) is no file or folder of the install.'
                '    if (path.StartsWith(@"\\.\", System.StringComparison.Ordinal)) { return null; }'
                '    string literal = path;'
                '    if (!path.StartsWith(@"\\?\", System.StringComparison.Ordinal)) {'
                '        literal = path.StartsWith(@"\\", System.StringComparison.Ordinal) ? @"\\?\UNC\" + path.Substring(2) : @"\\?\" + path;'
                '    }'
                '    Microsoft.Win32.SafeHandles.SafeFileHandle handle = CreateFileW(literal, 0x80000000, 7, System.IntPtr.Zero, 3, 0x02300000, System.IntPtr.Zero);'
                '    if (!handle.IsInvalid) { error = 0; return handle; }'
                '    int code = System.Runtime.InteropServices.Marshal.GetLastWin32Error();'
                '    handle.Dispose();'
                '    if (code != 0) { error = code; }'
                '    return null;'
                '}'
                '// The name is handed over as a counted string (its length in bytes, without the closing'
                '// zero) in memory that is freed here; the folder cannot be closed while the call runs.'
                'public static Microsoft.Win32.SafeHandles.SafeFileHandle OpenBelow(Microsoft.Win32.SafeHandles.SafeFileHandle folder, string name, out int error) {'
                '    error = -1;'
                '    if (folder == null || string.IsNullOrEmpty(name) || name == "." || name == ".." || name.Length > 255) { return null; }'
                '    if (name.IndexOf(@"\", System.StringComparison.Ordinal) >= 0 || name.IndexOf("/", System.StringComparison.Ordinal) >= 0 || name.IndexOf(":", System.StringComparison.Ordinal) >= 0) { return null; }'
                '    System.IntPtr text = System.IntPtr.Zero;'
                '    System.IntPtr namePointer = System.IntPtr.Zero;'
                '    System.IntPtr io = System.IntPtr.Zero;'
                '    bool held = false;'
                '    try {'
                '        // Room for the IO_STATUS_BLOCK the call fills in (a status and a count, a pointer wide each); not read here.'
                '        io = System.Runtime.InteropServices.Marshal.AllocHGlobal(2 * System.IntPtr.Size);'
                '        text = System.Runtime.InteropServices.Marshal.StringToHGlobalUni(name);'
                '        namePointer = System.Runtime.InteropServices.Marshal.AllocHGlobal(System.Runtime.InteropServices.Marshal.SizeOf(typeof(UNICODE_STRING)));'
                '        UNICODE_STRING counted;'
                '        counted.Length = (ushort)(name.Length * 2);'
                '        counted.MaximumLength = (ushort)(name.Length * 2 + 2);'
                '        counted.Buffer = text;'
                '        System.Runtime.InteropServices.Marshal.StructureToPtr(counted, namePointer, false);'
                '        folder.DangerousAddRef(ref held);'
                '        OBJECT_ATTRIBUTES attributes;'
                '        attributes.Length = (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES));'
                '        attributes.RootDirectory = folder.DangerousGetHandle();'
                '        attributes.ObjectName = namePointer;'
                '        attributes.Attributes = 0x40;'
                '        attributes.SecurityDescriptor = System.IntPtr.Zero;'
                '        attributes.SecurityQualityOfService = System.IntPtr.Zero;'
                '        System.IntPtr opened;'
                '        int status = NtOpenFile(out opened, 0x80100000, ref attributes, io, 7, 0x00200020);'
                '        if (status == 0) { error = 0; return new Microsoft.Win32.SafeHandles.SafeFileHandle(opened, true); }'
                '        if (status == unchecked((int)0xC0000034) || status == unchecked((int)0xC000003A)) { error = 2; } else { error = status; }'
                '        return null;'
                '    } finally {'
                '        if (held) { folder.DangerousRelease(); }'
                '        System.Runtime.InteropServices.Marshal.FreeHGlobal(namePointer);'
                '        System.Runtime.InteropServices.Marshal.FreeHGlobal(text);'
                '        System.Runtime.InteropServices.Marshal.FreeHGlobal(io);'
                '    }'
                '}'
                'public static string FinalPath(Microsoft.Win32.SafeHandles.SafeFileHandle handle) {'
                '    System.Text.StringBuilder text = new System.Text.StringBuilder(1024);'
                '    uint length = GetFinalPathNameByHandleW(handle, text, (uint)text.Capacity, 2);'
                '    // Too small: the answer is then the room it needs.'
                '    if (length >= text.Capacity && length < 65536) {'
                '        text = new System.Text.StringBuilder((int)length + 1);'
                '        length = GetFinalPathNameByHandleW(handle, text, (uint)text.Capacity, 2);'
                '    }'
                '    if (length == 0 || length >= text.Capacity) { return null; }'
                '    return text.ToString();'
                '}'
                'public static long[] Describe(Microsoft.Win32.SafeHandles.SafeFileHandle handle) {'
                '    System.IntPtr buffer = System.Runtime.InteropServices.Marshal.AllocHGlobal(24);'
                '    try {'
                '        if (!GetFileInformationByHandleEx(handle, 9, buffer, 8)) { return null; }'
                '        long attributes = (uint)System.Runtime.InteropServices.Marshal.ReadInt32(buffer, 0);'
                '        if (!GetFileInformationByHandleEx(handle, 1, buffer, 24)) { return null; }'
                '        return new long[] { attributes, System.Runtime.InteropServices.Marshal.ReadInt64(buffer, 8) };'
                '    } finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(buffer); }'
                '}'
                '// The entries of one filled buffer. True when there was no room for one of them.'
                'static bool Take(System.IntPtr buffer, int size, int room, System.Collections.Generic.SortedDictionary<string, bool> found) {'
                '    int at = 0;'
                '    while (true) {'
                '        if (at < 0 || at > size - 104) { throw new System.IO.InvalidDataException(); }'
                '        int next = System.Runtime.InteropServices.Marshal.ReadInt32(buffer, at);'
                '        int attributes = System.Runtime.InteropServices.Marshal.ReadInt32(buffer, at + 56);'
                '        int bytes = System.Runtime.InteropServices.Marshal.ReadInt32(buffer, at + 60);'
                '        if (bytes < 0 || bytes > size - 104 - at) { throw new System.IO.InvalidDataException(); }'
                '        string name = System.Runtime.InteropServices.Marshal.PtrToStringUni(System.IntPtr.Add(buffer, at + 104), bytes / 2);'
                '        if (name != "." && name != "..") {'
                '            if (found.Count >= room) { return true; }'
                '            found[name] = (attributes & 0x10) != 0;'
                '        }'
                '        if (next <= 0) { return false; }'
                '        at += next;'
                '    }'
                '}'
                'public static System.Collections.Generic.SortedDictionary<string, bool> List(Microsoft.Win32.SafeHandles.SafeFileHandle folder, int room, out bool cut) {'
                '    cut = false;'
                '    System.Collections.Generic.SortedDictionary<string, bool> found = new System.Collections.Generic.SortedDictionary<string, bool>(System.StringComparer.Ordinal);'
                '    const int size = 65536;'
                '    System.IntPtr buffer = System.Runtime.InteropServices.Marshal.AllocHGlobal(size);'
                '    try {'
                '        int kind = 11;'
                '        while (true) {'
                '            if (!GetFileInformationByHandleEx(folder, kind, buffer, size)) {'
                '                int code = System.Runtime.InteropServices.Marshal.GetLastWin32Error();'
                '                // 18: no more entries. 2 on the first call: a folder with none at all (the top of a drive).'
                '                if (code == 18 || (code == 2 && kind == 11)) { return found; }'
                '                return null;'
                '            }'
                '            kind = 10;'
                '            if (Take(buffer, size, room, found)) { cut = true; return found; }'
                '        }'
                '    } finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(buffer); }'
                '}'
            ) -join "`n"
            Add-Type -Namespace '' -Name 'LaiIntegrityNative' -MemberDefinition $members
        }
        return $true
    } catch { return $false }
}

function Open-LaiIntegrityHandle {
    # Windows only (unit-tested there). Opens one file or folder for the integrity walk and says what
    # the handle holds. State 'ok' comes with Handle (the caller disposes it), Final (where the entry
    # really is, as Windows says of that handle: long names, the volume as a device, every link above
    # it resolved), Folder and Size. Any other State comes without a handle: 'gone' (no such entry),
    # 'link' or 'unreadable' (also off Windows and when the Windows calls are not there).
    #   -Path    by its path, a link in its last place not followed. Only for the place a walk starts
    #            from: a link further up is followed as in any path.
    #   -Parent  the entry -Name of the folder that this open handle holds (OpenBelow). No path is
    #            looked up, so it is that folder's own entry, whatever a path to the folder leads to
    #            by now, and the answer says nothing about any other folder. The entry must also be
    #            that name directly below -ParentFinal (where the folder was when its handle was
    #            asked): the entries of a folder that was moved since are a 'link' as well.
    # Final paths are compared, never paths as they are written: two spellings of one place differ
    # (C:\Users\LONGNA~1 and C:\Users\LongName), and a path says nothing about where it leads.
    # A link is never 'ok', so nothing is read through one.
    param([string]$Path = '', $Parent = $null, [string]$ParentFinal = '', [string]$Name = '')
    if (-not (Initialize-LaiIntegrityNative)) { return @{ State = 'unreadable' } }
    $handle = $null; $keep = $false
    try {
        $openError = 0
        if ($Parent) { $handle = [LaiIntegrityNative]::OpenBelow($Parent, $Name, [ref]$openError) }
        else { $handle = [LaiIntegrityNative]::Open([System.IO.Path]::GetFullPath($Path), [ref]$openError) }
        if ($null -eq $handle) {
            # 2 ERROR_FILE_NOT_FOUND, 3 ERROR_PATH_NOT_FOUND.
            if ($openError -eq 2 -or $openError -eq 3) { return @{ State = 'gone' } }
            return @{ State = 'unreadable' }
        }
        $final = [string][LaiIntegrityNative]::FinalPath($handle)
        $info = [LaiIntegrityNative]::Describe($handle)
        if (-not $final -or $null -eq $info) { return @{ State = 'unreadable' } }
        if ($Parent -and -not $final.Equals($ParentFinal.TrimEnd([char]'\') + '\' + $Name, [StringComparison]::OrdinalIgnoreCase)) { return @{ State = 'link' } }
        # 0x400 FILE_ATTRIBUTE_REPARSE_POINT, 0x10 FILE_ATTRIBUTE_DIRECTORY.
        if ([long]$info[0] -band 0x400) { return @{ State = 'link' } }
        $keep = $true
        return @{ State = 'ok'; Handle = $handle; Final = $final; Folder = [bool]([long]$info[0] -band 0x10); Size = [long]$info[1] }
    } catch {
        return @{ State = 'unreadable' }
    } finally {
        if ($handle -and -not $keep) { $handle.Dispose() }
    }
}

function Add-LaiIntegrityEntry {
    # Adds one file, or everything under one folder, to $Map as 'Scripts\lib\LocalAI.psm1' = SHA-256.
    # A junction or symbolic link is recorded as 'link' and never followed: the installer records the
    # baseline as administrator in a folder the user controls, and a planted link must neither make it
    # read files elsewhere nor hide that a folder was swapped for one. A file that cannot be read is
    # 'unreadable'; one above -MaxHashBytes (nothing the toolkit installs comes near it) is recorded
    # by size, so a huge file dropped there cannot make the watch run for minutes. With -Budget
    # (New-LaiIntegrityBudget) the walk ends where the budget does and says where.
    # Which entry, in one of two ways:
    #   -Item    a file or folder by its path. Where a walk starts (it must not be a link itself; what
    #            lies above it is the caller's business), and off Windows every entry of a walk.
    #   -Parent  (Windows) the open handle of the folder the entry is in, with -ParentFinal (where
    #            that folder really is, as its handle said), -Name (the entry as the folder listed
    #            it) and -Folder (the listing called it a folder). The walk goes down this way.
    param([Parameter(Mandatory)][hashtable]$Map, [System.IO.FileSystemInfo]$Item = $null, [Parameter(Mandatory)][string]$Relative, [long]$MaxHashBytes = 50MB, [hashtable]$Budget = $null,
        $Parent = $null, [string]$ParentFinal = '', [string]$Name = '', [switch]$Folder)
    if ($Budget) {
        if ($Budget['Stopped']) { return }
        if ($Budget['Entries'] -ge $Budget['MaxEntries'] -or $Budget['Bytes'] -ge $Budget['MaxBytes'] -or $Budget['Clock'].Elapsed.TotalSeconds -ge $Budget['MaxSeconds']) { $Budget['Stopped'] = $Relative; return }
        $Budget['Entries'] = [int]$Budget['Entries'] + 1
    }
    if (Test-LaiIntegrityOnWindows) {
        # On Windows no file or folder of the walk is reached by its path, except the place the walk
        # starts from. The user (or anything running as the user) can swap a folder for a link to a
        # place only an administrator may read, and back, as often as it likes while the installer
        # walks. A path that is looked up again for every entry follows such a link: the names and
        # hashes of that other place then land in a baseline the user can read, and even an entry
        # that is only opened and then refused tells whether a name of the user's choosing exists
        # there. So a folder is opened once, and each of its entries is opened by its name in that
        # open folder (Open-LaiIntegrityHandle -Parent), a link not followed. Everything else is asked
        # of the entry's own handle: where it really is, whether it is a link, its size, the names in
        # a folder, the bytes that are hashed. An entry that is a link, or that is not its own name
        # directly below where its folder was when that folder was listed (the folder was moved
        # since), is a 'link': nothing in it or below it is listed, read or hashed, whenever the swap
        # happened and however often, and whatever lies behind the link.
        # Still taken on trust: the folders above the install folder (Get-LaiIntegrityFiles opens the
        # install folder by its path, and it must not be a link itself, but a link further up is
        # followed as in any path), and that a second name for a file (a hard link) is that file:
        # whether one can be made to a file the user may not read is Windows' rule, not checked here.
        if (-not (Initialize-LaiIntegrityNative)) { $Map[$Relative] = 'unreadable'; return }
        # What the listing (or the caller) took the entry for.
        $entryName = $Name; $listedFolder = [bool]$Folder
        if (-not $Parent) {
            if (-not $Item) { $Map[$Relative] = 'unreadable'; return }
            $entryName = [string]$Item.Name; $listedFolder = ($Item -is [System.IO.DirectoryInfo])
        }
        $opened = $null; $stream = $null
        try {
            if ($Parent) { $opened = Open-LaiIntegrityHandle -Parent $Parent -ParentFinal $ParentFinal -Name $entryName }
            else { $opened = Open-LaiIntegrityHandle -Path $Item.FullName }
            # Gone since it was listed: no entry.
            if ($opened['State'] -eq 'gone') { return }
            if ($opened['State'] -ne 'ok') { $Map[$Relative] = [string]$opened['State']; return }
            $handle = $opened['Handle']; $final = [string]$opened['Final']
            $isFolder = [bool]$opened['Folder']
            # What it is, is the handle's answer, not the listing's: a file that has become a folder
            # called Secrets since (or a folder that has become a file called .env) stays left out.
            if ($isFolder -ne $listedFolder -and (Test-LaiIntegrityExcluded -Name $entryName -Folder:$isFolder)) { return }
            if ($isFolder) {
                # By name, whatever order the file system lists them in, so a walk that runs out of
                # budget stops at the same entry every time. No more are listed than the budget has
                # room for: a folder with a million entries is not read to the end just to be sorted.
                $room = [int]::MaxValue; if ($Budget) { $room = [int]$Budget['MaxEntries'] - [int]$Budget['Entries'] }
                $cut = $false
                $children = [LaiIntegrityNative]::List($handle, $room, [ref]$cut)
                if ($null -eq $children) { $Map[$Relative] = 'unreadable'; return }
                # (Through the enumerator: to PowerShell, .Keys of a dictionary that holds a file
                # called 'Keys' is that file's entry, not the list of names.)
                foreach ($entry in $children.GetEnumerator()) {
                    $childName = [string]$entry.Key
                    $childIsFolder = [bool]$entry.Value
                    if (Test-LaiIntegrityExcluded -Name $childName -Folder:$childIsFolder) { continue }
                    # Each entry by its name in this open folder, exactly as the folder listed it (a
                    # closing dot or space included: no path is written out, so nothing is made
                    # another name of). This folder's path is not looked up again.
                    Add-LaiIntegrityEntry -Map $Map -Relative ($Relative + '\' + $childName) -MaxHashBytes $MaxHashBytes -Budget $Budget -Parent $handle -ParentFinal $final -Name $childName -Folder:$childIsFolder
                }
                if ($cut -and $Budget -and -not $Budget['Stopped']) { $Budget['Stopped'] = $Relative }
                return
            }
            $size = [long]$opened['Size']
            if ($size -gt $MaxHashBytes) { $Map[$Relative] = 'size ' + $size; return }
            if ($Budget) { $Budget['Bytes'] = [long]$Budget['Bytes'] + $size }
            $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read)
            $Map[$Relative] = [string](Get-FileHash -InputStream $stream -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch {
            $Map[$Relative] = 'unreadable'
        } finally {
            if ($stream) { $stream.Dispose() }
            if ($opened -and $opened['Handle']) { $opened['Handle'].Dispose() }
        }
        return
    }
    # Off Windows (the toolkit installs on Windows only; the test jobs on Linux run this) the walk
    # goes by path. $Item was listed with its parent, some time ago: what it is, is asked again right
    # before it is read, and for a folder once more after it was listed. A folder swapped for a link
    # in between is then a 'link' and whatever was read below it is dropped. That narrows the gap to
    # the moment between the question and the read; it does not close it (a swap there, undone
    # before the second question, is still followed).
    try { $Item.Refresh() } catch { $Map[$Relative] = 'unreadable'; return }
    if (-not $Item.Exists) { return }
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $Map[$Relative] = 'link'; return }
    if ($Item -is [System.IO.DirectoryInfo]) {
        # By name, whatever order the file system lists them in, so a walk that runs out of budget
        # stops at the same entry every time. No more are listed than the budget has room for: a
        # folder with a million entries is not read to the end just to be sorted.
        $children = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([System.StringComparer]::Ordinal)
        $room = [int]::MaxValue; if ($Budget) { $room = [int]$Budget['MaxEntries'] - [int]$Budget['Entries'] }
        $cut = $false
        try { foreach ($child in $Item.EnumerateFileSystemInfos()) { if ($children.Count -ge $room) { $cut = $true; break }; $children[$child.Name] = $child } }
        catch { $Map[$Relative] = 'unreadable'; return }
        foreach ($child in @($children.Values)) {
            if (Test-LaiIntegrityExcluded -Name $child.Name -Folder:($child -is [System.IO.DirectoryInfo])) { continue }
            Add-LaiIntegrityEntry -Map $Map -Item $child -Relative ($Relative + '\' + $child.Name) -MaxHashBytes $MaxHashBytes -Budget $Budget
        }
        $swapped = $false
        try { $Item.Refresh(); $swapped = [bool]($Item.Exists -and ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) } catch { $swapped = $true }
        if ($swapped) {
            $below = $Relative + '\'
            foreach ($k in @($Map.Keys | Where-Object { ([string]$_).StartsWith($below, [StringComparison]::OrdinalIgnoreCase) })) { $Map.Remove($k) }
            $Map[$Relative] = 'link'
            return
        }
        if ($cut -and $Budget -and -not $Budget['Stopped']) { $Budget['Stopped'] = $Relative }
        return
    }
    if ($Item.Length -gt $MaxHashBytes) { $Map[$Relative] = 'size ' + $Item.Length; return }
    if ($Budget) { $Budget['Bytes'] = [long]$Budget['Bytes'] + $Item.Length }
    try { $Map[$Relative] = [string](Get-FileHash -LiteralPath $Item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
    catch { $Map[$Relative] = 'unreadable' }
}

function Get-LaiIntegrityFiles {
    # Every file under <AIRoot>\Scripts and <AIRoot>\Stack with its SHA-256, keyed by its path below
    # the install folder (always with backslashes, so a baseline reads the same everywhere). Scripts
    # first: when -Budget runs out in Stack, the scripts have all been read.
    # On Windows the install folder is opened once, by its path, and held open: Scripts and Stack are
    # opened by their names in that open folder, and so is everything below them, each in its own
    # folder (Add-LaiIntegrityEntry, -Parent). An install folder that is a link itself is not read
    # through: Scripts and Stack are each recorded as a 'link' then, without a look at what lies
    # behind it. When the install folder cannot be opened that way, or the Windows calls for it are
    # not there, both are 'unreadable', and nothing is read by its path instead. Either way no file
    # of that folder is in the list: Get-LaiIntegrityUnread is how the comparison and the summary
    # tell, and both say so.
    param([Parameter(Mandatory)][string]$AIRoot, [long]$MaxHashBytes = 50MB, [hashtable]$Budget = $null)
    $map = @{}
    if (Test-LaiIntegrityOnWindows) {
        $root = Open-LaiIntegrityHandle -Path $AIRoot
        try {
            # No install folder, or a file of that name: there is nothing to read.
            if ($root['State'] -eq 'gone' -or ($root['State'] -eq 'ok' -and -not $root['Folder'])) { return $map }
            foreach ($top in @('Scripts', 'Stack')) {
                if ($root['State'] -ne 'ok') { $map[$top] = [string]$root['State']; continue }
                Add-LaiIntegrityEntry -Map $map -Relative $top -MaxHashBytes $MaxHashBytes -Budget $Budget -Parent $root['Handle'] -ParentFinal ([string]$root['Final']) -Name $top -Folder
            }
        } finally {
            if ($root['Handle']) { $root['Handle'].Dispose() }
        }
        return $map
    }
    foreach ($top in @('Scripts', 'Stack')) {
        $item = Get-Item -LiteralPath (Join-Path $AIRoot $top) -Force -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        Add-LaiIntegrityEntry -Map $map -Item $item -Relative $top -MaxHashBytes $MaxHashBytes -Budget $Budget
    }
    return $map
}

function Get-LaiIntegrityUnread {
    # Pure (unit-tested). Which of Scripts and Stack a walk did not read, from its list of files
    # (Get-LaiIntegrityFiles): the folder's name = 'link' or 'unreadable'. A folder is in that list
    # under its own name only when the walk stopped at the folder itself: it is a link, the install
    # folder above it is one, or it could not be opened or listed. Not one file in it was listed or
    # hashed then, so not one is compared, and a baseline recorded that way holds none: two such
    # states read as equal for good while every file in the folder may change. Whoever shows a
    # comparison or a baseline asks here and says so (Compare-LaiIntegrity, Get-LaiIntegritySummary).
    param($Files)
    $unread = @{}
    if ($Files -is [hashtable]) {
        foreach ($top in @('Scripts', 'Stack')) {
            $state = [string]$Files[$top]
            if ($state -eq 'link' -or $state -eq 'unreadable') { $unread[$top] = $state }
        }
    }
    return $unread
}

function Get-LaiIntegrityUnreadText {
    # Pure. Why a folder was not read (a state of Get-LaiIntegrityUnread), as a sentence fragment
    # after the folder's name: one wording for the notice, the log and the health check.
    param([string]$State = '')
    if ($State -eq 'link') { return 'is a link to another place, or lies in an install folder that is one' }
    return 'could not be read'
}

function ConvertTo-LaiIntegrityEnv {
    # Pure (unit-tested). The lines of Stack\.env become name = tag for the settings that say where
    # chats and searches are sent: names ending in _URL, _URLS or _UPSTREAM (OLLAMA_BASE_URL,
    # OLLAMA_UPSTREAM, DEEP_RESEARCH_OLLAMA_URL, COMFYUI_URLS). One changed line there sends every
    # prompt and answer through another machine. Only a short tag of each value is kept, never the
    # value, and no other line is looked at: versions and ports change with every Open WebUI update,
    # the keys are secrets, and WEBUI_EXTRA_ORIGINS is rewritten by Enable-TailscaleAccess.ps1, which
    # records no baseline.
    param([string[]]$Lines = @())
    $map = @{}
    foreach ($line in $Lines) {
        if ([string]$line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
            $name = $Matches[1]; $value = $Matches[2]
            if ($name -like '*_URL' -or $name -like '*_URLS' -or $name -like '*_UPSTREAM') { $map[$name] = Get-LaiIntegrityTag -Text $value.Trim() }
        }
    }
    return $map
}

function Get-LaiIntegrityEnv {
    # The routing settings of <AIRoot>\Stack\.env (ConvertTo-LaiIntegrityEnv). Empty when there is no
    # .env; $null when it cannot be told (a link, which is not followed; not a file; too big to be
    # one; unreadable): the comparison then skips the settings instead of calling them all removed.
    # On Windows the file is reached the way the walk reaches its files (Add-LaiIntegrityEntry says
    # why): the install folder is opened by its path, Stack by its name in that open folder and .env
    # by its name in Stack, none of them through a link, and what is read is the handle's own
    # stream, no more of it than the size the handle gave. Read by its path, a Stack swapped for a
    # link to a folder only an administrator may read put the names of that folder's .env settings,
    # each with a fingerprint of its value, into the baseline the user can read.
    param([Parameter(Mandatory)][string]$AIRoot)
    if (Test-LaiIntegrityOnWindows) {
        $held = New-Object System.Collections.Generic.List[object]
        $stream = $null; $reader = $null
        try {
            $at = Open-LaiIntegrityHandle -Path $AIRoot
            foreach ($name in @('Stack', '.env')) {
                if ($at['Handle']) { $held.Add($at['Handle']) }
                if ($at['State'] -eq 'gone') { return @{} }
                if ($at['State'] -ne 'ok') { return $null }
                # A file where a folder was expected has no .env in it.
                if (-not $at['Folder']) { return @{} }
                $at = Open-LaiIntegrityHandle -Parent $at['Handle'] -ParentFinal ([string]$at['Final']) -Name $name
            }
            if ($at['Handle']) { $held.Add($at['Handle']) }
            if ($at['State'] -eq 'gone') { return @{} }
            if ($at['State'] -ne 'ok' -or $at['Folder'] -or [long]$at['Size'] -gt 1MB) { return $null }
            $size = [int]$at['Size']
            $bytes = New-Object byte[] $size
            $stream = New-Object System.IO.FileStream($at['Handle'], [System.IO.FileAccess]::Read)
            $got = 0
            while ($got -lt $size) {
                $n = $stream.Read($bytes, $got, $size - $got)
                if ($n -le 0) { break }
                $got += $n
            }
            # Through a reader, as Get-Content reads it: a byte order mark is no part of the first name.
            $reader = New-Object System.IO.StreamReader((New-Object System.IO.MemoryStream($bytes, 0, $got)), [System.Text.Encoding]::UTF8)
            $lines = New-Object System.Collections.Generic.List[string]
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                $lines.Add($line)
            }
            return (ConvertTo-LaiIntegrityEnv -Lines $lines.ToArray())
        } catch {
            return $null
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($stream) { $stream.Dispose() }
            foreach ($h in $held) { $h.Dispose() }
        }
    }
    $item = Get-Item -LiteralPath (Join-Path (Join-Path $AIRoot 'Stack') '.env') -Force -ErrorAction SilentlyContinue
    if (-not $item) { return @{} }
    if (($item -is [System.IO.DirectoryInfo]) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 1MB) { return $null }
    try { return (ConvertTo-LaiIntegrityEnv -Lines @(Get-Content -LiteralPath $item.FullName -Encoding UTF8 -ErrorAction Stop)) } catch { return $null }
}

function Get-LaiIntegrityTasks {
    # What each scheduled task named like -NamePattern runs (program, arguments, start folder), as
    # whom (account and sign-in type) and at what privilege ('Limited', or 'Highest' = administrator
    # rights without a prompt). Triggers are left out: the installer gives the watch a new start time
    # on every run. $null when tasks cannot be read here (no Task Scheduler cmdlets, as on the Linux
    # test machine, or the query failed): the comparison then skips tasks instead of calling every
    # one of them gone.
    param([string]$NamePattern = 'LocalAI-*')
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }
    $tasks = @()
    try { $tasks = @(Get-ScheduledTask -TaskName $NamePattern -ErrorAction Stop | Where-Object { $_ }) }
    catch {
        # 'No task of that name' is an answer (none); anything else is 'could not tell'.
        if ([string]$_.CategoryInfo.Category -ne 'ObjectNotFound') { return $null }
    }
    $map = @{}
    foreach ($t in $tasks) {
        $name = [string]$t.TaskName
        $folder = ([string]$t.TaskPath).Trim('\')
        if ($folder) { $name = $folder + '\' + $name }
        $runs = @($t.Actions | Where-Object { $_ } | ForEach-Object {
                $run = (@([string]$_.Execute, [string]$_.Arguments) | Where-Object { $_ }) -join ' '
                if ($_.WorkingDirectory) { $run += ' [in ' + [string]$_.WorkingDirectory + ']' }
                if ($_.ClassId) { $run += ' [COM ' + [string]$_.ClassId + ']' }
                $run
            })
        $who = [string]$t.Principal.UserId
        if (-not $who) { $who = [string]$t.Principal.GroupId }
        $map[$name] = @{ Run = ($runs -join ' ; '); User = $who; LogonType = [string]$t.Principal.LogonType; RunLevel = [string]$t.Principal.RunLevel }
    }
    return $map
}

function ConvertTo-LaiListenerSet {
    # Pure (unit-tested). Rows as Get-NetTCPConnection -State Listen returns them (LocalAddress,
    # LocalPort, OwningProcess) and a table of process id -> name become one entry per program and
    # port: Program (lower case, 'unknown' when the process is gone), Port, and Network = $true when
    # at least one of its addresses is not loopback, i.e. other devices can reach it. An address that
    # cannot be read counts as reachable. Callers assign the result, never wrap the call in @().
    param([object[]]$Connections = @(), [hashtable]$ProcessNames = @{})
    $set = @{}
    foreach ($c in $Connections) {
        if ($null -eq $c) { continue }
        $prog = 'unknown'
        $procId = [int]$c.OwningProcess
        if ($ProcessNames.ContainsKey($procId) -and $ProcessNames[$procId]) { $prog = ([string]$ProcessNames[$procId]).ToLowerInvariant() }
        $port = [int]$c.LocalPort
        $ip = $null
        $loopback = ([System.Net.IPAddress]::TryParse([string]$c.LocalAddress, [ref]$ip) -and [System.Net.IPAddress]::IsLoopback($ip))
        $key = '{0}|{1:D5}' -f $prog, $port
        if (-not $set.ContainsKey($key)) { $set[$key] = @{ Program = $prog; Port = $port; Network = $false } }
        if (-not $loopback) { $set[$key]['Network'] = $true }
    }
    return , @($set.Keys | Sort-Object | ForEach-Object { $set[$_] })
}

function Get-LaiIntegrityListeners {
    # Every listening TCP port with the program that owns it (ConvertTo-LaiListenerSet). $null when
    # this PC cannot tell (no Get-NetTCPConnection, as on the Linux test machine, or the query
    # failed): the comparison then skips listeners. Process names are readable without administrator
    # rights, so the elevated installer and the non-elevated watch see the same list.
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return $null }
    $conns = @()
    try { $conns = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_ }) } catch { return $null }
    # One list of all processes (a single snapshot) is quicker than asking for each owner by id.
    $names = @{}
    if ($conns.Count) {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { if ($p) { $names[[int]$p.Id] = [string]$p.ProcessName } }
    }
    $set = ConvertTo-LaiListenerSet -Connections $conns -ProcessNames $names
    return , $set
}

function Get-LaiIntegrityTag {
    # A short, stable tag for a piece of text (first 12 hex digits of its SHA-256): keeps the watch's
    # 'already told' keys short without storing command lines or account names in them.
    param([string]$Text = '')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').Substring(0, 12) }
    finally { $sha.Dispose() }
}

function Get-LaiIntegrityPorts {
    # The stack's own ports, from localai-config.json: another program holding one of them is news
    # even on loopback. The watch and the baseline both ask here, so they always mean the same ports.
    param([Parameter(Mandatory)][string]$AIRoot)
    $config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
    $ports = @(3000, 8888, 11434)
    try {
        if ($config['WebUIPort']) { $ports[0] = [int]$config['WebUIPort'] }
        if ($config['SearxngPort']) { $ports[1] = [int]$config['SearxngPort'] }
        if ($config['OllamaUrl']) { $ports[2] = [int]([uri][string]$config['OllamaUrl']).Port }
        if ($config['DeepResearchPort'] -and [int]$config['DeepResearchPort'] -gt 0) { $ports += [int]$config['DeepResearchPort'] }
    } catch { Write-Verbose "a port in localai-config.json could not be read: $($_.Exception.Message)" }
    return [int[]]$ports
}

function Compare-LaiIntegrity {
    # Pure (unit-tested). What differs between a baseline and the state now, as objects with
    #   Id    what the difference is about (its kind and name). It stays the same for as long as the
    #         thing differs, whatever its content: a file rewritten between two looks is still one
    #         difference, and the watch counts its two strikes by this;
    #   Key   the Id plus a tag of the new content: a second, different change to the same thing has
    #         another Key, which is how the watch knows it is news again;
    #   Text  a plain sentence fragment that names the thing: '"Scripts\x.ps1" was changed'. Names
    #         are cleaned (ConvertTo-LaiIntegrityName) and stand in double quotes, and nothing else
    #         in a Text does, so the banner can show exactly the names as code.
    #   files      changed, new and gone, each by name. More than -MaxNewPerFolder new files in one
    #              place (an archive unpacked into the wrong folder) are one difference with a count.
    #              A walk that ran out of budget ('filesStopped') cannot say what is gone from there
    #              on and says that instead; a baseline recorded that way cannot say what is new.
    #              Scripts or Stack not read at all (Get-LaiIntegrityUnread: a link, or not
    #              readable) is one difference, 'walk|<folder>', that says its files were not
    #              compared, and none of them is called gone. Not when the baseline was recorded
    #              the same way: accepted like that, it is the baseline's summary that says no
    #              file of the folder is watched (Get-LaiIntegritySummary).
    #   settings   the routing settings of Stack\.env (ConvertTo-LaiIntegrityEnv): changed, added,
    #              removed, by name only. Skipped when either side could not read them.
    #   tasks      a different command, account or privilege; new and gone. Skipped when either side
    #              could not read tasks.
    #   listeners  only additions, and only what matters: a program that now accepts connections
    #              from other devices (not loopback-only) on a port it did not have, and one of
    #              -WatchedPorts (the stack's own) now held by another program. Ports from
    #              -DynamicPortFrom up are handed out by Windows per start and count as one
    #              'temporary port' per program. Left out on purpose: listeners that went away (a
    #              program that is not running; the health checks cover the stack's own) and new
    #              loopback-only ones (not reachable from the network; Ollama's model runners and
    #              ordinary programs open them all day). Skipped when either side could not read them.
    param([Parameter(Mandatory)][hashtable]$Baseline, [Parameter(Mandatory)][hashtable]$Current, [int[]]$WatchedPorts = @(), [int]$DynamicPortFrom = 49152, [int]$MaxNewPerFolder = 20)
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    # -Tag '' = nothing of its own to tell apart by (the thing is gone).
    $add = { param([string]$Id, [string]$Tag, [string]$Text)
        if ($seen.ContainsKey($Id)) { return }
        $seen[$Id] = $true
        $full = $Id; if ($Tag) { $full = $Id + '|' + $Tag }
        $out.Add([pscustomobject]@{ Id = $Id; Key = $full; Text = $Text })
    }
    $q = { param([string]$Name) return ('"' + (ConvertTo-LaiIntegrityName -Name $Name) + '"') }

    $bf = @{}; if ($Baseline['files'] -is [hashtable]) { $bf = $Baseline['files'] }
    $cf = @{}; if ($Current['files'] -is [hashtable]) { $cf = $Current['files'] }
    $bStopped = [string]$Baseline['filesStopped']; $cStopped = [string]$Current['filesStopped']
    # The folders the baseline knows. New files are counted under the topmost folder it does not
    # know (a whole unpacked tree is one place), else under the folder they are in.
    $bFolders = @{}
    foreach ($k in $bf.Keys) {
        $p = [string]$k
        while ($p.LastIndexOf('\') -gt 0) { $p = $p.Substring(0, $p.LastIndexOf('\')); $bFolders[$p] = $true }
    }
    $new = @{}
    $cUnread = Get-LaiIntegrityUnread -Files $cf
    foreach ($k in @($cf.Keys | Sort-Object)) {
        $now = [string]$cf[$k]
        $tag = $now; if ($now.Length -eq 64) { $tag = $now.Substring(0, 12) }
        if ($cUnread.ContainsKey([string]$k)) {
            # Not 'is new' (it was there all along) and not one 'is gone' for every file in it.
            if ([string]$bf[$k] -ne $now) { & $add "walk|$k" $now ('{0} {1}, so the files in it were not compared' -f (& $q $k), (Get-LaiIntegrityUnreadText -State $now)) }
            continue
        }
        if (-not $bf.ContainsKey($k)) {
            if ($bStopped) { continue }
            $parts = ([string]$k).Split('\'); $place = ''
            for ($i = 1; $i -lt $parts.Count; $i++) { $place = ($parts[0..($i - 1)] -join '\'); if (-not $bFolders.ContainsKey($place)) { break } }
            if (-not $new.ContainsKey($place)) { $new[$place] = New-Object System.Collections.Generic.List[object] }
            $new[$place].Add(@{ Name = [string]$k; Tag = $tag })
            continue
        }
        if ([string]$bf[$k] -eq $now) { continue }
        $what = 'was changed'
        if ($now -eq 'link') { $what = 'is now a link to another place' } elseif ($now -eq 'unreadable') { $what = 'can no longer be read' }
        & $add "file|$k" $tag ((& $q $k) + ' ' + $what)
    }
    foreach ($place in @($new.Keys | Sort-Object)) {
        $list = $new[$place]
        if ($list.Count -gt $MaxNewPerFolder) { & $add "files+|$place" ([string]$list.Count) ('{0} new files in {1}' -f $list.Count, (& $q $place)); continue }
        foreach ($f in $list) { & $add ('file+|' + $f['Name']) ([string]$f['Tag']) ((& $q $f['Name']) + ' is new') }
    }
    $cTop = ''; if ($cStopped) { $cTop = $cStopped.Split('\')[0] }
    foreach ($k in @($bf.Keys | Sort-Object)) {
        if ($cf.ContainsKey($k)) { continue }
        # In a folder that was not read: not compared, so not gone.
        if ($cUnread.ContainsKey(([string]$k).Split('\')[0])) { continue }
        # A walk that stopped early cannot say what is gone from there on. Scripts is read first, so
        # one that stopped in Stack still read all of Scripts.
        $read = (-not $cStopped) -or ($cTop -eq 'Stack' -and ([string]$k -eq 'Scripts' -or ([string]$k).StartsWith('Scripts\', [StringComparison]::OrdinalIgnoreCase)))
        if ($read) { & $add "file-|$k" '' ((& $q $k) + ' is gone') }
    }
    if ($cStopped -and -not $bStopped) {
        & $add "walk|$cTop" '' ('reading {0} stopped at {1} (more files, data or time than the watch allows itself), so the rest was not compared' -f (& $q $cTop), (& $q $cStopped))
    }

    if ($Baseline['env'] -is [hashtable] -and $Current['env'] -is [hashtable]) {
        $be = $Baseline['env']; $ce = $Current['env']
        foreach ($n in @($ce.Keys | Sort-Object)) {
            $tag = [string]$ce[$n]
            if (-not $be.ContainsKey($n)) { & $add "env+|$n" $tag ('the setting {0} was added to Stack\.env' -f (& $q $n)); continue }
            if ([string]$be[$n] -ne $tag) { & $add "env|$n" $tag ('the setting {0} in Stack\.env was changed' -f (& $q $n)) }
        }
        foreach ($n in @($be.Keys | Sort-Object)) { if (-not $ce.ContainsKey($n)) { & $add "env-|$n" '' ('the setting {0} was removed from Stack\.env' -f (& $q $n)) } }
    }

    if ($Baseline['tasks'] -is [hashtable] -and $Current['tasks'] -is [hashtable]) {
        $bt = $Baseline['tasks']; $ct = $Current['tasks']
        foreach ($n in @($ct.Keys | Sort-Object)) {
            $c = $ct[$n]
            if (-not ($c -is [hashtable])) { continue }
            $tag = Get-LaiIntegrityTag -Text (@([string]$c['Run'], [string]$c['User'], [string]$c['LogonType'], [string]$c['RunLevel']) -join '|')
            $task = 'the scheduled task ' + (& $q $n)
            if (-not ($bt[$n] -is [hashtable])) {
                $admin = ''; if ([string]$c['RunLevel'] -eq 'Highest') { $admin = ' and runs with administrator rights' }
                & $add "task+|$n" $tag ($task + ' is new' + $admin)
                continue
            }
            $b = $bt[$n]
            $ch = @()
            if ([string]$b['Run'] -ne [string]$c['Run']) { $ch += 'runs a different command' }
            if ([string]$b['User'] -ne [string]$c['User'] -or [string]$b['LogonType'] -ne [string]$c['LogonType']) { $ch += 'runs as a different account or sign-in type' }
            if ([string]$b['RunLevel'] -ne [string]$c['RunLevel']) {
                if ([string]$c['RunLevel'] -eq 'Highest') { $ch += 'runs with administrator rights' } else { $ch += 'runs without administrator rights' }
            }
            if ($ch.Count) { & $add "task|$n" $tag ($task + ' now ' + ($ch -join ' and ')) }
        }
        foreach ($n in @($bt.Keys | Sort-Object)) { if (-not $ct.ContainsKey($n)) { & $add "task-|$n" '' ('the scheduled task ' + (& $q $n) + ' is gone') } }
    }

    if ($null -ne $Baseline['listeners'] -and $null -ne $Current['listeners']) {
        # Port 0 in a baseline row stands for 'a temporary port' (ConvertTo-LaiListenerBaseline). One of
        # the stack's own ports is never a temporary one, wherever it was put.
        # Read here, outside the scriptblock: the analyzer cannot see a parameter used only inside one.
        $dynamicFrom = $DynamicPortFrom
        $slotOf = { param([int]$Port) if ($Port -le 0 -or ($Port -ge $dynamicFrom -and $WatchedPorts -notcontains $Port)) { return 'temporary' }; return [string]$Port }
        $net = @{}; $owners = @{}
        foreach ($l in @($Baseline['listeners'])) {
            $port = 0
            # A row without a program or a port number is no row: the file can be edited by hand, and
            # one bad row must not stop every comparison.
            if (-not ($l -is [hashtable]) -or -not $l['Program'] -or -not [int]::TryParse([string]$l['Port'], [ref]$port)) { continue }
            $prog = [string]$l['Program']; $slot = & $slotOf $port
            if ($l['Network']) { $net["$prog|$slot"] = $true }
            if ($WatchedPorts -contains $port) { $owners[$slot] = @($owners[$slot] | Where-Object { $_ }) + $prog }
        }
        foreach ($l in @($Current['listeners'])) {
            $port = 0
            if (-not ($l -is [hashtable]) -or -not [int]::TryParse([string]$l['Port'], [ref]$port)) { continue }
            $prog = [string]$l['Program']; $slot = & $slotOf $port
            $place = "port $port"; if ($slot -eq 'temporary') { $place = 'a temporary port' }
            $was = @($owners[$slot] | Where-Object { $_ } | Select-Object -Unique)
            if ($WatchedPorts -contains $port -and $was.Count -and $was -notcontains $prog -and $prog -ne 'unknown' -and $was -notcontains 'unknown') {
                & $add "port|$slot|$prog" '' ('port {0} is now held by {1} (it was {2})' -f $port, (& $q $prog), (@($was | ForEach-Object { & $q $_ }) -join ', '))
            } elseif ($l['Network'] -and -not $net.ContainsKey("$prog|$slot")) {
                & $add "net|$prog|$slot" '' ('{0} now accepts connections from other devices on {1}' -f (& $q $prog), $place)
            }
        }
    }
    return $out.ToArray()
}

function Limit-LaiIntegrityFound {
    # Pure (unit-tested). The first -Max of -Diffs (Compare-LaiIntegrity) as they are, and everything
    # after them as one more difference with a count. The watch keeps what it found, what it told and
    # what waits for a second look in watch-state.json, next to the record of the health checks:
    # thousands of entries with long names would grow that file past what Windows PowerShell 5.1
    # reads back (2 MB), and the watch would lose its whole memory with it. Files are cut in the
    # order of Compare-LaiIntegrity (by name), so the same ones on every run. The one that stands for
    # the rest says whether an installed script is among them ('more|Scripts'), which decides the
    # advice (Get-LaiIntegrityAdvice); its Key carries the count, so a count that changes is news
    # again like any other changed difference.
    param([object[]]$Diffs = @(), [int]$Max = 300)
    $all = @($Diffs | Where-Object { $null -ne $_ })
    if ($all.Count -le $Max) { return $all }
    # Settings, tasks and listeners are few and are never the ones cut: a new task must not go
    # unnamed because a few hundred files changed as well.
    $all = @($all | Where-Object { [string]$_.Id -notmatch '^files?[+-]?\|' }) + @($all | Where-Object { [string]$_.Id -match '^files?[+-]?\|' })
    $rest = @($all | Select-Object -Skip $Max)
    $place = 'other'
    if (@($rest | Where-Object { [string]$_.Id -match '^(files?[+-]?\|Scripts(\\|$)|walk\|Scripts$)' }).Count) { $place = 'Scripts' }
    $more = [pscustomobject]@{ Id = "more|$place"; Key = ('more|{0}|{1}' -f $place, $rest.Count); Text = ('{0} more differences than are listed here' -f $rest.Count) }
    return @(@($all | Select-Object -First $Max) + $more)
}

function Get-LaiIntegritySnapshot {
    # The state right now, in the shape of a baseline: files (hashed; 'filesStopped' names where the
    # walk ran out of budget, '' when it read everything), the routing settings of Stack\.env, tasks,
    # listeners.
    param([Parameter(Mandatory)][string]$AIRoot, [string]$TaskPattern = 'LocalAI-*', [hashtable]$Budget = $null)
    # (The Windows calls the walk needs are compiled before its clock starts: the first use in a
    # process takes a moment that is not the folders' doing.)
    if (-not $Budget) { [void](Initialize-LaiIntegrityNative); $Budget = New-LaiIntegrityBudget }
    $files = Get-LaiIntegrityFiles -AIRoot $AIRoot -Budget $Budget
    return @{
        files        = $files
        filesStopped = [string]$Budget['Stopped']
        env          = (Get-LaiIntegrityEnv -AIRoot $AIRoot)
        tasks        = (Get-LaiIntegrityTasks -NamePattern $TaskPattern)
        listeners    = (Get-LaiIntegrityListeners)
    }
}

function Read-LaiIntegrityBaseline {
    # The recorded baseline, or $null when there is none (or it is not one).
    param([Parameter(Mandatory)][string]$AIRoot)
    $path = Get-LaiIntegrityPath -AIRoot $AIRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $b = Read-LaiState -Path $path
    if (-not ($b['files'] -is [hashtable]) -or -not $b['id']) { return $null }
    return $b
}

function ConvertTo-LaiListenerBaseline {
    # Pure (unit-tested). The listener rows a baseline keeps: Program, Port, Network, and Seen (when a
    # baseline last found it listening).
    #   -Current  what listens now (ConvertTo-LaiListenerSet): always kept, Seen = now.
    #   -Known    the rows of the baseline this one replaces. Only with -Carry (an install or update)
    #             is one that does not listen right now kept: a game, or a ComfyUI started for the
    #             LAN, would otherwise be announced again after every update. It is kept for
    #             -KeepDays after it was last seen and then forgotten, so the list of what counts as
    #             normal cannot only ever grow. A row dated in the future, or not dated at all
    #             (-KnownSeen: the date of its baseline, for rows from before rows had one), is not
    #             carried. Without -Carry (the owner accepting the current state) the baseline is
    #             exactly what listens now: what the owner switched off is no longer accepted.
    # Ports from -DynamicPortFrom up are handed out by Windows anew at every start: one row per
    # program with Port 0 stands for all of them, instead of one more row per port at every update.
    # One of -WatchedPorts (the stack's own) keeps its number wherever it was put.
    # Callers assign the result, never wrap the call in @().
    param([object[]]$Current = @(), [object[]]$Known = @(), [switch]$Carry, [datetime]$Now = (Get-Date), [int]$KeepDays = 90, [int[]]$WatchedPorts = @(), [int]$DynamicPortFrom = 49152, [string]$KnownSeen = '')
    $rows = @{}
    # Read here, outside the scriptblock: the analyzer cannot see a parameter used only inside one.
    $dynamicFrom = $DynamicPortFrom; $watched = $WatchedPorts
    $put = { param($Row, [string]$Seen)
        $port = 0
        if (-not ($Row -is [hashtable]) -or -not $Row['Program'] -or -not [int]::TryParse([string]$Row['Port'], [ref]$port)) { return }
        if ($port -lt 0 -or ($port -ge $dynamicFrom -and $watched -notcontains $port)) { $port = 0 }
        $rowKey = '{0}|{1:D5}|{2}' -f ([string]$Row['Program']), $port, [bool]$Row['Network']
        if (-not $rows.ContainsKey($rowKey)) { $rows[$rowKey] = @{ Program = [string]$Row['Program']; Port = $port; Network = [bool]$Row['Network']; Seen = $Seen } }
    }
    $nowText = $Now.ToString('s')
    foreach ($r in $Current) { & $put $r $nowText }
    if ($Carry) {
        foreach ($r in $Known) {
            if (-not ($r -is [hashtable])) { continue }
            $seen = ConvertTo-LaiIntegrityDate $r['Seen']
            if (-not $seen) { $seen = ConvertTo-LaiIntegrityDate $KnownSeen }
            if (-not $seen -or $seen -gt $Now.AddDays(1) -or ($Now - $seen).TotalDays -gt $KeepDays) { continue }
            $seenText = $seen.ToString('s')
            & $put $r $seenText
        }
    }
    return , @($rows.Keys | Sort-Object | ForEach-Object { $rows[$_] })
}

function Test-LaiIntegrityOwn {
    # $true when a difference between the last baseline and the state after an install is the
    # installer's own work, or takes nothing in: a file that now equals the installer's own copy
    # (-SourceRoot: its files are copied to Scripts, those under its stack\ to Stack), a task it
    # registers (-OwnTasks), a setting it writes (-OwnSettings), or something that is gone. $false
    # for everything else: it was there before the run, or something else put it there, and the new
    # baseline takes it in. A run started from <AIRoot>\Scripts itself copies no scripts, so nothing
    # in Scripts is its own then.
    param([Parameter(Mandatory)]$Difference, [Parameter(Mandatory)][hashtable]$Snapshot, [Parameter(Mandatory)][string]$AIRoot, [string]$SourceRoot = '', [string[]]$OwnTasks = @(), [string[]]$OwnSettings = @())
    $kind, $name = ([string]$Difference.Id) -split '\|', 2
    if ($kind -like '*-') { return $true }
    if ($kind -eq 'task' -or $kind -eq 'task+') { return ($OwnTasks -contains $name) }
    if ($kind -eq 'env' -or $kind -eq 'env+') { return ($OwnSettings -contains $name) }
    if ($kind -ne 'file' -and $kind -ne 'file+') { return $false }
    if (-not $SourceRoot -or -not ($Snapshot['files'] -is [hashtable])) { return $false }
    # Only a file recorded by its SHA-256 can equal a copy (not a link, not one recorded by size).
    $now = [string]$Snapshot['files'][$name]
    $parts = @(([string]$name).Split('\'))
    if ($now.Length -ne 64 -or $parts.Count -lt 2) { return $false }
    $own = $SourceRoot
    if ($parts[0] -eq 'Stack') { $own = Join-Path $own 'stack' }
    elseif ($parts[0] -ne 'Scripts' -or $SourceRoot.TrimEnd('\', '/') -eq (Join-Path $AIRoot 'Scripts').TrimEnd('\', '/')) { return $false }
    foreach ($seg in @($parts | Select-Object -Skip 1)) { $own = Join-Path $own $seg }
    if (-not (Test-Path -LiteralPath $own -PathType Leaf)) { return $false }
    try { return ([string](Get-FileHash -LiteralPath $own -Algorithm SHA256 -ErrorAction Stop).Hash -eq $now) } catch { return $false }
}

function Test-LaiIntegrityStill {
    # Pure (unit-tested). $true while what a recorded difference is about (by its Id, as
    # Compare-LaiIntegrity gives it) is still so in -Snapshot (Get-LaiIntegritySnapshot, before its
    # listeners are turned into baseline rows): the file, setting or task that was new or changed is
    # still there, the one that was gone is still gone, the program still listens (for a 'now reachable
    # from other devices' entry: still on an address other devices reach). Where the snapshot
    # could not tell (settings, tasks or listeners not read; a file missing from a walk that stopped
    # early, or in a Scripts or Stack that was not read at all: Get-LaiIntegrityUnread) it counts
    # as still so: saying less would hide it. $false for everything that names no
    # single thing (a walk that stopped, the count that stands for a cut list).
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][hashtable]$Snapshot)
    $kind, $name = $Id -split '\|', 2
    if (-not $kind -or -not $name) { return $false }
    $gone = $kind.EndsWith('-')
    $what = $kind.TrimEnd('+', '-')
    if ($what -eq 'net' -or $what -eq 'port') {
        if ($null -eq $Snapshot['listeners']) { return $true }
        # 'net|program|port' and 'port|port|program'.
        $parts = @($name -split '\|')
        $prog = $parts[0]; if ($what -eq 'port') { $prog = $parts[-1] }
        return (@($Snapshot['listeners'] | Where-Object { $_ -is [hashtable] -and [string]$_['Program'] -eq $prog -and ($what -eq 'port' -or $_['Network']) }).Count -gt 0)
    }
    $there = $null
    if ($what -eq 'file' -or $what -eq 'files') {
        if ($Snapshot['files'] -is [hashtable]) {
            if ($what -eq 'file') { $there = $Snapshot['files'].ContainsKey($name) }
            else { $below = $name + '\'; $there = (@($Snapshot['files'].Keys | Where-Object { ([string]$_).StartsWith($below, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) }
            # Not found by a walk that stopped early, or in a folder the walk did not read at all:
            # that is 'could not tell', not 'no longer there'.
            if (-not $there -and ($Snapshot['filesStopped'] -or (Get-LaiIntegrityUnread -Files $Snapshot['files']).ContainsKey(([string]$name).Split('\')[0]))) { $there = $null }
        }
    }
    elseif ($what -eq 'env') { if ($Snapshot['env'] -is [hashtable]) { $there = $Snapshot['env'].ContainsKey($name) } }
    elseif ($what -eq 'task') { if ($Snapshot['tasks'] -is [hashtable]) { $there = $Snapshot['tasks'].ContainsKey($name) } }
    else { return $false }
    if ($null -eq $there) { return $true }
    if ($gone) { return (-not $there) }
    return [bool]$there
}

function Save-LaiIntegrityBaseline {
    # Records the state right now as the baseline and returns it. Called where an install or update
    # ends successfully (-Reason 'install', so an update is never reported as a change) and by
    # Watch-LocalAI.ps1 -AcceptBaseline (the owner accepting changes they made).
    # A new baseline takes in whatever is there, also what nobody meant to put there: the installer
    # overwrites its own files and registers its own tasks, and removes nothing else. So 'accepted'
    # lists what this baseline has that the one before it did not, for the installer's log, the
    # watch and the health check to show: for the owner's acceptance all of it, for an install only
    # what the installer did not put there itself (Test-LaiIntegrityOwn; -SourceRoot, -OwnTasks and
    # -OwnSettings say what it did).
    # What the baseline before this one took in is carried on for as long as nobody has settled it
    # and it is still so (Test-LaiIntegrityStill): without that a second update minutes after the
    # first, or the acceptance command run twice, would record an empty list, and the addition would
    # drop out of every report with nobody having looked. Settled means the owner accepted it and
    # the watch has had its turn with a baseline that says so:
    #   - One install after another always carries (minus what the installer has since put there
    #     itself).
    #   - A baseline recorded by hand settles what an install listed. It names that once more,
    #     marked 'Settled' (the acceptance says what it accepted). An entry marked like that stays
    #     listed, still marked, by every baseline after it, of either kind, until the watch has had
    #     its turn with a baseline that lists it: the watch wrote that list to watch.log and tried
    #     to announce it ('tried' in watch-state.json; 'announced' when the notification went out).
    #     Dropped any sooner, the acceptance command run twice, or once and then an update, before
    #     the watch's next run would record an empty list, and the watch would have nothing to say
    #     about an acceptance the owner did not make. It does not wait for the notification to go
    #     out: on a PC where none ever does nothing would be settled, and every acceptance and every
    #     update would list the same things again. There it clears after one run of the watch, and
    #     watch.log is the only place that names it.
    #     Not named again when the watch has already announced that install's list.
    #   - What a baseline recorded by hand took in itself is carried by the next one, of either
    #     kind, until the watch has announced that baseline: anything running as the owner can
    #     record one, and the watch's notice is what shows an acceptance the owner did not make.
    # What the watch has announced or tried is read from watch-state.json, which the watch replaces
    # every few minutes. A read that fails counts as neither, which carries (the safe side); it
    # must not keep the baseline from being recorded, or the watch would report the whole update.
    # 'The rest was not compared' (a walk that stopped) is carried without asking whether it is
    # still so: it names no single thing that could be gone again, and stays true of every
    # baseline recorded since.
    # 'accepted' names all of it, up to -MaxListed: a list cut to what the reports show (a
    # notification three, the health check twelve; they cut for themselves) lost the rest at the
    # next carry. What does not fit, and what a baseline counted without naming it (one recorded
    # when the list was cut at 50), is one last entry 'more|Scripts' or 'more|other', as
    # Limit-LaiIntegrityFound makes it ('Scripts' also when nothing says what it stands for), and
    # stays in 'acceptedCount'. Nobody can tell whether that is still there, so that number does
    # not go down until the owner's acceptance settles it (and, as for an entry with a name, the
    # watch has had its turn with a baseline that says so).
    # Listeners: ConvertTo-LaiListenerBaseline (an install carries known ones for a while, the
    # owner's acceptance records exactly what listens now).
    # 'id' is what the watch remembers the baseline by: PowerShell 7 reads a saved time back as a
    # date and Windows PowerShell 5.1 as text, an id reads the same in both.
    # -Budget as for Get-LaiIntegritySnapshot.
    param([Parameter(Mandatory)][string]$AIRoot, [string]$Reason = 'install', [string]$TaskPattern = 'LocalAI-*', [string]$SourceRoot = '', [string[]]$OwnTasks = @(), [string[]]$OwnSettings = @(), [hashtable]$Budget = $null, [int]$MaxListed = 1000)
    $snap = Get-LaiIntegritySnapshot -AIRoot $AIRoot -TaskPattern $TaskPattern -Budget $Budget
    $old = Read-LaiIntegrityBaseline -AIRoot $AIRoot
    $ports = Get-LaiIntegrityPorts -AIRoot $AIRoot
    $install = ($Reason -eq 'install')
    $taken = @()
    # $settled: the Ids listed here because this acceptance settles them, or one before it did and
    # the watch has not had its turn yet. $unnamed: how many this baseline carries without a name
    # ($unnamedSettled: an acceptance has settled those); $restScripts: an installed script may be
    # among them.
    $settles = $false; $settled = @{}; $unnamed = 0; $unnamedSettled = $false; $restScripts = $false
    if ($old) {
        # Every new file by its own name here (no 'N new files in ...'): each is judged on its own.
        $taken = @(Compare-LaiIntegrity -Baseline $old -Current $snap -WatchedPorts $ports -MaxNewPerFolder ([int]::MaxValue))
        if ($install) { $taken = @($taken | Where-Object { -not (Test-LaiIntegrityOwn -Difference $_ -Snapshot $snap -AIRoot $AIRoot -SourceRoot $SourceRoot -OwnTasks $OwnTasks -OwnSettings $OwnSettings) }) }
    }
    if ($old) {
        $oldAccepted = @($old['accepted'] | Where-Object { $_ -is [hashtable] -and $_['Id'] })
        $oldNamed = @($oldAccepted | Where-Object { [string]$_['Id'] -notlike 'more|*' })
        $oldMore = @($oldAccepted | Where-Object { [string]$_['Id'] -like 'more|*' })
        # The file can be edited by hand: a count that is no number is none.
        $oldCount = 0
        if (-not [int]::TryParse([string]$old['acceptedCount'], [ref]$oldCount)) { $oldCount = 0 }
        $oldUnnamed = [math]::Max(0, $oldCount - $oldNamed.Count)
        $announced = ''; $tried = ''
        try {
            $watchIg = (Read-LaiState -Path (Join-Path $AIRoot 'watch-state.json'))['integrity']
            if ($watchIg -is [hashtable]) { $announced = [string]$watchIg['announced']; $tried = [string]$watchIg['tried'] }
        } catch { Write-Verbose "watch-state.json could not be read, so the baseline before this one counts as neither announced nor tried: $($_.Exception.Message)" }
        $oldId = [string]$old['id']
        $oldInstall = ([string]$old['reason'] -eq 'install')
        $settles = ($oldInstall -and -not $install)
        # The watch has had its turn with the baseline before this one: only then does what an
        # acceptance settled leave the list.
        $watchSaw = ($announced -eq $oldId -or $tried -eq $oldId)
        if (($oldNamed.Count -or $oldUnnamed) -and (($install -and $oldInstall) -or $announced -ne $oldId)) {
            # 'is new' and 'was changed' are about the same thing: listed once.
            $have = @{}
            foreach ($d in $taken) { $have[([string]$d.Id -replace '^([a-z]+)\+\|', '$1|')] = $true }
            foreach ($a in $oldNamed) {
                $wasSettled = [bool]$a['Settled']
                if ($wasSettled -and $watchSaw) { continue }
                $d = [pscustomobject]@{ Id = [string]$a['Id']; Key = [string]$a['Id']; Text = [string]$a['Text'] }
                $same = $d.Id -replace '^([a-z]+)\+\|', '$1|'
                if ($have.ContainsKey($same)) { continue }
                if ($d.Id -notlike 'walk|*' -and -not (Test-LaiIntegrityStill -Id $d.Id -Snapshot $snap)) { continue }
                if ($install -and (Test-LaiIntegrityOwn -Difference $d -Snapshot $snap -AIRoot $AIRoot -SourceRoot $SourceRoot -OwnTasks $OwnTasks -OwnSettings $OwnSettings)) { continue }
                $have[$same] = $true
                if ($settles -or $wasSettled) { $settled[$d.Id] = $true }
                $taken += $d
            }
            $oldMoreSettled = (@($oldMore | Where-Object { $_['Settled'] }).Count -gt 0)
            if ($oldUnnamed -and -not ($oldMoreSettled -and $watchSaw)) {
                $unnamed = $oldUnnamed
                $unnamedSettled = ($settles -or $oldMoreSettled)
                $restScripts = ($oldMore.Count -eq 0 -or @($oldMore | Where-Object { [string]$_['Id'] -eq 'more|Scripts' }).Count -gt 0)
            }
        }
    }
    if ($null -ne $snap['listeners']) {
        $known = @(); $knownSeen = ''
        if ($old -and $null -ne $old['listeners']) {
            $known = @($old['listeners'])
            $oldAt = ConvertTo-LaiIntegrityDate $old['recordedAt']
            if ($oldAt) { $knownSeen = $oldAt.ToString('s') }
        }
        $snap['listeners'] = ConvertTo-LaiListenerBaseline -Current @($snap['listeners']) -Known $known -Carry:$install -WatchedPorts $ports -KnownSeen $knownSeen
    }
    $listed = @($taken); $cut = @()
    if ($taken.Count -gt $MaxListed) {
        # The first -MaxListed in the order of Limit-LaiIntegrityFound (settings, tasks and listeners
        # are never the ones cut); its last entry says whether a script is among the rest.
        $limited = @(Limit-LaiIntegrityFound -Diffs $taken -Max $MaxListed)
        if ([string]$limited[-1].Id -eq 'more|Scripts') { $restScripts = $true }
        $listed = @($limited | Select-Object -First $MaxListed)
        $shown = @{}
        foreach ($d in $listed) { $shown[[string]$d.Id] = $true }
        $cut = @($taken | Where-Object { -not $shown.ContainsKey([string]$_.Id) })
    }
    $accepted = @($listed | ForEach-Object {
            $entry = @{ Id = [string]$_.Id; Text = [string]$_.Text }
            if ($settled.ContainsKey([string]$_.Id)) { $entry['Settled'] = $true }
            $entry
        })
    $rest = $unnamed + $cut.Count
    if ($rest -gt 0) {
        $place = 'other'; if ($restScripts) { $place = 'Scripts' }
        $more = @{ Id = "more|$place"; Text = ('{0} more than are listed here' -f $rest) }
        # Settled as well when all it stands for is: what is carried without a name where an
        # acceptance has settled it (this one, or one the watch has not had its turn with), what
        # did not fit only where none of it is this baseline's own.
        if (($unnamed -eq 0 -or $unnamedSettled) -and @($cut | Where-Object { -not $settled.ContainsKey([string]$_.Id) }).Count -eq 0) { $more['Settled'] = $true }
        $accepted += $more
    }
    # By name, and how many in all (more than the names when one entry stands for the rest).
    $snap['accepted'] = $accepted
    $snap['acceptedCount'] = $listed.Count + $rest
    $snap['version'] = 1
    $snap['id'] = [guid]::NewGuid().ToString('N')
    $snap['recordedAt'] = (Get-Date).ToString('s')
    $snap['reason'] = $Reason
    Save-LaiState -State $snap -Path (Get-LaiIntegrityPath -AIRoot $AIRoot)
    return $snap
}

function Get-LaiIntegritySummary {
    # '61 files, 3 scheduled tasks, 24 listeners' for messages; says so when tasks or listeners could
    # not be read where the baseline was recorded, or when the folders held more than is read.
    # And when Scripts or Stack was not read at all (Get-LaiIntegrityUnread): the folder's own entry
    # is then all the baseline holds of it, and two such states compare as equal whatever happens to
    # the files. Counted as '2 files' without a word, that read like a small install that is being
    # watched; the installer's log, the acceptance and the health check all print this line.
    param([Parameter(Mandatory)][hashtable]$Baseline)
    $files = 0; if ($Baseline['files'] -is [hashtable]) { $files = @($Baseline['files'].Keys).Count }
    $notes = @()
    if ($Baseline['filesStopped']) { $notes += 'not all of them: the folders hold more than the watch reads' }
    $unread = Get-LaiIntegrityUnread -Files $Baseline['files']
    foreach ($top in @($unread.Keys | Sort-Object)) {
        # The folder's own entry is no file.
        $files--
        $notes += ('none in {0}, which {1}: changes there are NOT noticed' -f $top, (Get-LaiIntegrityUnreadText -State ([string]$unread[$top])))
    }
    $more = ''; if ($notes.Count) { $more = ' (' + ($notes -join '; ') + ')' }
    $tasks = 'scheduled tasks not read'; if ($Baseline['tasks'] -is [hashtable]) { $tasks = '{0} scheduled tasks' -f @($Baseline['tasks'].Keys).Count }
    $listeners = 'listeners not read'; if ($null -ne $Baseline['listeners']) { $listeners = '{0} listeners' -f @($Baseline['listeners']).Count }
    return ('{0} files{1}, {2}, {3}' -f $files, $more, $tasks, $listeners)
}

function Format-LaiIntegrityList {
    # Pure (unit-tested). 'a; b; c and 4 more': a notification has room for a few names, not sixty.
    param([string[]]$Items = @(), [int]$Max = 3)
    $shown = @($Items | Select-Object -First $Max)
    $text = $shown -join '; '
    if ($Items.Count -gt $shown.Count) { $text += ' and {0} more' -f ($Items.Count - $shown.Count) }
    return $text
}

function Get-LaiUnfinishedInstall {
    # When the installer last finished one of its stages after -Since (the time the baseline was
    # recorded), else $null. The installer stamps every finished stage into install-state.json and
    # records a baseline only at the very end, so a stamp newer than the baseline means an install or
    # update that got somewhere and then failed, or is waiting for a restart: file differences may be
    # its half-done work. The watch adds that as one sentence to its notice and never lets it replace
    # the warning: install-state.json is as writable as the baseline, so it may put a notice into
    # context but must not explain one away. Hence also the limits: nothing dated in the future,
    # nothing older than -MaxAgeHours. (An installer log proves no work: every run writes one, also
    # a run that was refused because another one was going.)
    param([Parameter(Mandatory)][string]$AIRoot, [Parameter(Mandatory)][datetime]$Since, [datetime]$Now = (Get-Date), [int]$MaxAgeHours = 48)
    $stages = (Read-LaiState -Path (Join-Path $AIRoot 'install-state.json'))['stages']
    if (-not ($stages -is [hashtable])) { return $null }
    $newest = $null
    foreach ($v in @($stages.Values)) {
        $t = ConvertTo-LaiIntegrityDate $v
        if (-not $t -or $t -le $Since -or $t -gt $Now -or ($Now - $t).TotalHours -gt $MaxAgeHours) { continue }
        if (-not $newest -or $t -gt $newest) { $newest = $t }
    }
    return $newest
}

function Select-LaiIntegrityNews {
    # Pure (unit-tested). Which of -Diffs (Compare-LaiIntegrity) the watch announces now.
    #   -Pending  the Ids seen on the last look and not told yet;
    #   -Told     what was announced: Id, Key (the content it had then) and At.
    # Never told: announced when the last look saw it too. Two strikes, so a file being saved or a
    # port open for a minute raises nothing; and counted by Id, not by content, so a file that is
    # rewritten between the two looks is still the same difference.
    # Told before: quiet while its content is the one that was told. Changed again since: news
    # again, but at most once in -QuietHours, so a file that is rewritten all day is one notice a
    # day and not one every half hour.
    param([object[]]$Diffs = @(), [object[]]$Told = @(), [string[]]$Pending = @(), [datetime]$Now = (Get-Date), [int]$QuietHours = 24)
    $toldById = @{}; $waiting = @{}
    foreach ($t in $Told) { if ($t -is [hashtable] -and $t['Id']) { $toldById[[string]$t['Id']] = $t } }
    foreach ($p in $Pending) { if ($p) { $waiting[[string]$p] = $true } }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in $Diffs) {
        if ($null -eq $d) { continue }
        $id = [string]$d.Id
        if (-not $toldById.ContainsKey($id)) { if ($waiting.ContainsKey($id)) { $out.Add($d) }; continue }
        if ([string]$toldById[$id]['Key'] -eq [string]$d.Key) { continue }
        $at = ConvertTo-LaiIntegrityDate $toldById[$id]['At']
        if (-not $at -or [math]::Abs(($Now - $at).TotalHours) -ge $QuietHours) { $out.Add($d) }
    }
    return $out.ToArray()
}

function Update-LaiIntegrityTold {
    # Pure (unit-tested). The 'told' list after -Announced went out (none: only tidied), cut to what
    # is worth remembering: everything that is still found (-Diffs), however many, because one of
    # those dropped from the list would be announced again on the next run, and the next, in turn;
    # plus the -MaxStale most recently told ones that are not found right now (a program that
    # listens only while it runs must not be news every time it is started).
    param([object[]]$Told = @(), [object[]]$Announced = @(), [object[]]$Diffs = @(), [datetime]$Now = (Get-Date), [int]$MaxStale = 200)
    $byId = [ordered]@{}
    foreach ($t in $Told) {
        if (-not ($t -is [hashtable]) -or -not $t['Id']) { continue }
        $at = ConvertTo-LaiIntegrityDate $t['At']
        $atText = ''; if ($at) { $atText = $at.ToString('s') }
        $byId[[string]$t['Id']] = @{ Id = [string]$t['Id']; Key = [string]$t['Key']; At = $atText }
    }
    foreach ($a in $Announced) {
        if ($null -eq $a) { continue }
        $id = [string]$a.Id
        # Told last = most recent: taken out and put back at the end.
        if ($byId.Contains($id)) { $byId.Remove($id) }
        $byId[$id] = @{ Id = $id; Key = [string]$a.Key; At = $Now.ToString('s') }
    }
    $found = @{}
    foreach ($d in $Diffs) { if ($null -ne $d) { $found[[string]$d.Id] = $true } }
    $keep = @($byId.Values | Where-Object { $found.ContainsKey($_['Id']) })
    $stale = @($byId.Values | Where-Object { -not $found.ContainsKey($_['Id']) } | Select-Object -Last $MaxStale)
    return @($stale + $keep)
}

function Get-LaiIntegrityAdvice {
    # Pure (unit-tested). What to do about differences nobody meant to make, by their Ids: -Brief for
    # the notification and the banner, else for the health check. The caller writes the 'If you did
    # not ...' in front.
    # A difference in the installed scripts, or a baseline that is gone, means nothing in
    # <AIRoot>\Scripts can be trusted to report on itself or to repair itself: every Local AI
    # shortcut starts a script from there, and Update toolkit goes on to ask for administrator
    # rights, which would hand them to whatever replaced Get-LocalAI.ps1. So no shortcut is named
    # then: the list is in watch.log, and the files come back from a fresh copy of the toolkit.
    # Otherwise the shortcuts are fine, but Update toolkit is no undo: it puts the toolkit's own
    # files and its three tasks back and records everything else it finds as the new baseline, so
    # what was added has to be removed first.
    param([string[]]$Ids = @(), [Parameter(Mandatory)][string]$AIRoot, [switch]$Brief)
    $root = $AIRoot.TrimEnd('\', '/')
    $fresh = 'a fresh copy of the toolkit (the one-line install command in its README, or a new download)'
    $scripts = @($Ids | Where-Object { $_ -match '^(files?[+-]?\|Scripts(\\|$)|walk\|Scripts$|more\|Scripts$|baseline\|)' }).Count -gt 0
    if ($scripts) {
        if ($Brief) { return ('do not use the Local AI shortcuts to look into it (they start the installed scripts, which may no longer be the toolkit''s own): the list is in "{0}\Logs\watch.log", and {1} puts the files back.' -f $root, $fresh) }
        return ('do not repair this with Update toolkit or any other Local AI shortcut: the scripts in "{0}\Scripts" may no longer be the toolkit''s own, the shortcuts start them, and Update toolkit then asks for administrator rights. Delete what was added, get {1} and run its installer: that puts the toolkit''s own files and its three scheduled tasks back, and records everything else it finds as the new baseline.' -f $root, $fresh)
    }
    if ($Brief) { return 'open Start menu > Local AI - Health check: it lists every change and what to do about it.' }
    return ('first remove what was added (new files from "{0}\Stack", new tasks in Task Scheduler > Task Scheduler Library; Start menu > Local AI - Security check lists every program that listens), then run Start menu > Local AI - Update toolkit. In that order: Update toolkit puts the toolkit''s own files and its three scheduled tasks back, and records everything else it finds as the new baseline.' -f $root)
}

#endregion

#region GPU -------------------------------------------------------------------------------

function ConvertFrom-LaiGpuQuery {
    # nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,memory.free (csv, noheader,
    # nounits) lines -> one object per GPU, in nvidia-smi's (PCI bus) order. Unparsable lines are skipped.
    param([string[]]$Lines)
    $gpus = @()
    foreach ($l in @($Lines)) {
        $f = @(([string]$l).Split(',') | ForEach-Object { $_.Trim() })
        $n = 0
        if ($f.Count -lt 5 -or -not [int]::TryParse($f[2], [ref]$n)) { continue }
        $gpus += [pscustomobject]@{ Name = $f[0]; DriverVersion = $f[1]; TotalMiB = [int]$f[2]; UsedMiB = [int]$f[3]; FreeMiB = [int]$f[4] }
    }
    return , $gpus
}

function Get-LaiGpuInfo {
    # The NVIDIA GPU the models run on, or $null when nvidia-smi is unavailable or lists none.
    # With several cards this is the one with the most VRAM (Ollama places a model on the card with the
    # most free memory, and CUDA's default device 0 for ComfyUI is the fastest card), not nvidia-smi's
    # first line, which is often a small display card. Count and All describe every card.
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return $null }
    # Local 'Continue': in Windows PowerShell 5.1 a native command's stderr becomes a terminating error
    # under the caller's 'Stop' preference, even when redirected.
    $ErrorActionPreference = 'Continue'
    $out = & $smi --query-gpu=name,driver_version,memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $all = ConvertFrom-LaiGpuQuery -Lines @($out | ForEach-Object { "$_" })
    if ($all.Count -eq 0) { return $null }
    $best = $all[0]
    foreach ($g in $all) { if ($g.TotalMiB -gt $best.TotalMiB) { $best = $g } }
    return [pscustomobject]@{
        Name          = $best.Name
        DriverVersion = $best.DriverVersion
        TotalMiB      = $best.TotalMiB
        UsedMiB       = $best.UsedMiB
        FreeMiB       = $best.FreeMiB
        Count         = $all.Count
        All           = $all
    }
}

function Test-LaiModelFitsVram {
    # Rough pre-download check: can a model of -DownloadGB load 100% on a card of -TotalMiB at the
    # installer's 8K checkpoint? Weights (the download size, read as GiB) plus 1 GiB for the 8K KV cache
    # and compute buffers, against the card minus 1.5 GiB for the desktop and Ollama's overhead.
    # Generous on purpose: it only has to catch cards that cannot work (a 30B on 16 GB), never refuse a
    # card that can (every model in the catalog fits a 24 GB RTX 3090/4090; a unit test checks that).
    param([Parameter(Mandatory)][double]$DownloadGB, [Parameter(Mandatory)][int]$TotalMiB)
    $needMiB = [Math]::Ceiling($DownloadGB * 1024) + 1024
    return ($needMiB -le ($TotalMiB - 1536))
}

function Get-LaiNoNvidiaMessage {
    # What Preflight says when nvidia-smi finds no GPU: name what this PC has instead of blaming a
    # broken NVIDIA driver on a PC that has an AMD/Intel GPU or an ARM CPU.
    param([string[]]$VideoControllers = @(), [string]$Architecture = '')
    $cards = @($VideoControllers | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    $nvidia = @($cards | Where-Object { $_ -match '(?i)nvidia|geforce|quadro' })
    if ($Architecture -match '(?i)arm') {
        return "This PC has an ARM processor ($Architecture). This toolkit needs a 64-bit x86 PC with an NVIDIA GPU with 24 GB of VRAM (RTX 3090/4090); nothing was installed."
    }
    if ($nvidia.Count) {
        return "Windows lists $($nvidia -join ', '), but nvidia-smi does not answer, so the NVIDIA driver is missing or broken. Install the current Game Ready driver from https://www.nvidia.com/Download/index.aspx, reboot, then re-run this script."
    }
    if ($cards.Count) {
        return "No NVIDIA GPU found (this PC has: $($cards -join ', ')). This toolkit needs an NVIDIA GPU with 24 GB of VRAM (RTX 3090/4090) and the NVIDIA driver; nothing was installed."
    }
    return 'nvidia-smi was not found, so there is no NVIDIA GPU or its driver is missing or broken. This toolkit needs an NVIDIA GPU with 24 GB of VRAM; if you have one, install the current Game Ready driver from https://www.nvidia.com/Download/index.aspx, reboot, then re-run this script.'
}

function Get-LaiVirtualizationHint {
    # The BIOS setting that turns CPU virtualization on, by CPU maker (Win32_Processor.Manufacturer).
    param([string]$Manufacturer = '')
    if ($Manufacturer -match '(?i)intel') { return 'Intel Virtualization Technology (VT-x) in the BIOS/UEFI (usually under Advanced > CPU Configuration)' }
    if ($Manufacturer -match '(?i)amd') { return 'SVM Mode in the BIOS/UEFI (usually under Advanced > CPU Configuration)' }
    return 'CPU virtualization in the BIOS/UEFI (SVM Mode on AMD, Intel Virtualization Technology / VT-x on Intel)'
}

function Get-LaiWslMemoryCapGB {
    # The memory= value for a new .wslconfig, or $null to leave WSL's own default (half the RAM).
    # 16 GB is a cap only above 32 GB of RAM; on smaller PCs it would RAISE WSL's limit.
    param([Parameter(Mandatory)][double]$TotalGB)
    if ($TotalGB -gt 32) { return 16 }
    return $null
}

function Test-LaiCpuFallbackFits {
    # Can the render guard's CPU mode (num_gpu 0, no mmap in Ollama 0.35.1) hold a model of -DownloadGB
    # in RAM next to Windows, Docker and a ComfyUI render? Weights + ~4 GB KV cache/buffers + ~8 GB.
    param([Parameter(Mandatory)][double]$DownloadGB, [Parameter(Mandatory)][double]$RamGB)
    return (($DownloadGB + 12) -le $RamGB)
}

function Get-LaiGpuApps {
    # Names of processes holding a CUDA context (memory is N/A under Windows WDDM, names are not).
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return @() }
    $ErrorActionPreference = 'Continue'
    $out = & $smi --query-compute-apps=pid,process_name --format=csv,noheader 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return @() }
    return @($out | ForEach-Object { ($_ -split ',', 2)[1].Trim() } | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ } | Select-Object -Unique)
}

function Wait-LaiGpuIdle {
    # Waits until VRAM used by everything else is at most -MaxUsedMiB (desktop + light apps), so model
    # placement and context tuning are measured against a quiet card. Returns the last GPU reading.
    # Throws after -TimeoutSec with the names of the GPU processes still running.
    param([int]$MaxUsedMiB = 3500, [int]$TimeoutSec = 600, [int]$PollSec = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $warned = $false
    while ($true) {
        $gpu = Get-LaiGpuInfo
        if (-not $gpu -or $gpu.UsedMiB -le $MaxUsedMiB) { return $gpu }
        $apps = Get-LaiGpuApps
        if ((Get-Date) -ge $deadline) {
            throw ("{0} MiB of VRAM is in use by other programs (limit {1} MiB). GPU compute processes: {2}. Close them (ComfyUI/Forge/games), then re-run." -f $gpu.UsedMiB, $MaxUsedMiB, $(if ($apps) { $apps -join ', ' } else { 'none listed' }))
        }
        if (-not $warned) {
            Write-LaiLog WARN ("{0} MiB of VRAM is in use by other programs ({1}); waiting up to {2} min for it to drop below {3} MiB..." -f $gpu.UsedMiB, $(if ($apps) { $apps -join ', ' } else { 'unknown' }), [Math]::Ceiling($TimeoutSec / 60), $MaxUsedMiB)
            $warned = $true
        }
        Start-Sleep -Seconds $PollSec
    }
}

function Get-LaiGpuBusyReason {
    # Why the GPU is not free for measuring models right now, or '' when it is: for unattended runs
    # (the nightly model re-check), which skip instead of waiting. Another program holding a CUDA
    # context (ComfyUI, Forge, a game) counts; Ollama's own processes (ollama*.exe, llama-server.exe)
    # do not, the caller unloads its models. -MaxUsedMiB > 0 also counts VRAM use above it (only
    # meaningful once Ollama's models are unloaded). LOCALAI_TEST_GPU_BUSY: test hook, the reason to
    # report; 'after-load' reports one only with -AfterLoad (a program that started mid-measurement).
    param([int]$MaxUsedMiB = 0, [switch]$AfterLoad)
    if ($env:LOCALAI_TEST_GPU_BUSY) {
        if ($env:LOCALAI_TEST_GPU_BUSY -ne 'after-load') { return [string]$env:LOCALAI_TEST_GPU_BUSY }
        if ($AfterLoad) { return 'a GPU program started during the measurement (test hook)' }
    }
    $apps = @(Get-LaiGpuApps | Where-Object { $_ -and $_ -notmatch '(?i)^(ollama[^\\/]*|llama-server)(\.exe)?$' })
    if ($apps.Count) { return "GPU in use by $($apps -join ', ')" }
    if ($MaxUsedMiB -gt 0) {
        $gpu = Get-LaiGpuInfo
        if ($gpu -and $gpu.UsedMiB -gt $MaxUsedMiB) { return ("{0} MiB of VRAM in use by other programs (limit {1} MiB)" -f $gpu.UsedMiB, $MaxUsedMiB) }
    }
    return ''
}

#endregion

#region Ollama ----------------------------------------------------------------------------

function Resolve-LaiModelName {
    # Ollama reports untagged models as name:latest.
    param([Parameter(Mandatory)][string]$Name)
    $leaf = $Name.Split('/')[-1]
    if ($leaf.Contains(':')) { return $Name }
    return "${Name}:latest"
}

function Get-LaiModelManifestPath {
    <#
    .SYNOPSIS
        Where Ollama keeps a model's manifest under its models folder:
        <dir>\manifests\<host>\<namespace>\<name>\<tag> (host registry.ollama.ai, namespace library
        when the name has none). Lets the installer see installed models while Ollama is not running.
    #>
    param([Parameter(Mandatory)][string]$ModelDir, [Parameter(Mandatory)][string]$Name)
    $full = Resolve-LaiModelName $Name
    $i = $full.LastIndexOf(':')
    $repo = $full.Substring(0, $i); $tag = $full.Substring($i + 1)
    $parts = @($repo.Split('/'))
    if ($parts.Count -ge 2 -and $parts[0].Contains('.')) { $hostName = $parts[0]; $parts = @($parts | Select-Object -Skip 1) } else { $hostName = 'registry.ollama.ai' }
    if ($parts.Count -eq 1) { $parts = @('library') + $parts }
    $p = Join-Path (Join-Path $ModelDir 'manifests') $hostName
    foreach ($seg in $parts) { $p = Join-Path $p $seg }
    return (Join-Path $p $tag)
}

function Find-LaiOllamaDir {
    # The folder of Ollama's tray app ('ollama app.exe'), or $null when Ollama is not installed
    # (-OrDefault: the default folder instead). Ollama's Windows docs install to a custom folder with
    # OllamaSetup.exe /DIR=...; its installer registration (fixed AppId) names that folder. Then a
    # running tray app, then the default %LOCALAPPDATA%\Programs\Ollama. Only a folder that really
    # holds the app counts (a CLI-only build or a shim on PATH does not).
    param([string]$LocalAppData = $env:LOCALAPPDATA, [switch]$OrDefault)
    $ErrorActionPreference = 'Stop'
    $default = $null; if ($LocalAppData) { $default = Join-Path $LocalAppData 'Programs\Ollama' }
    $cands = @()
    foreach ($hive in 'HKCU:', 'HKLM:') {
        try { $cands += [string](Get-ItemProperty -Path ($hive + '\Software\Microsoft\Windows\CurrentVersion\Uninstall\{44E83376-CE68-45EB-8FC1-393500EB558C}_is1')).InstallLocation }
        catch { Write-Verbose "no Ollama registration in $hive" }
    }
    try { $cands += @(Get-Process -Name 'ollama app' -ErrorAction SilentlyContinue | Where-Object { $_.Path } | ForEach-Object { Split-Path -Parent ([string]$_.Path) }) }
    catch { Write-Verbose 'no running Ollama app' }
    $cands += $default
    foreach ($c in $cands) {
        if (-not $c) { continue }
        $d = ([string]$c).TrimEnd('\', '/')
        if ($d -and (Test-Path -LiteralPath (Join-Path $d 'ollama app.exe'))) { return $d }
    }
    if ($OrDefault) { return $default }
    return $null
}

function Find-LaiDockerDesktopExe {
    # 'Docker Desktop.exe', or $null when it is not installed (-OrDefault: the default path instead).
    # Docker Desktop can be installed with --installation-dir: its uninstall registration names the
    # folder, else the docker CLI on PATH (<folder>\resources\bin\docker.exe), else Program Files.
    param([string]$ProgramFiles = $env:ProgramFiles, [switch]$OrDefault)
    $ErrorActionPreference = 'Stop'
    $default = $null; if ($ProgramFiles) { $default = Join-Path $ProgramFiles 'Docker\Docker\Docker Desktop.exe' }
    $dirs = @()
    foreach ($hive in 'HKLM:', 'HKCU:') {
        try { $dirs += [string](Get-ItemProperty -Path ($hive + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop')).InstallLocation }
        catch { Write-Verbose "no Docker Desktop registration in $hive" }
    }
    try {
        $cli = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cli -and $cli.Source) { $dirs += (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $cli.Source))) }
    } catch { Write-Verbose 'docker CLI path not usable' }
    foreach ($d in $dirs) {
        if (-not $d) { continue }
        $exe = Join-Path ([string]$d).TrimEnd('\', '/') 'Docker Desktop.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    if ($default -and ((Test-Path -LiteralPath $default) -or $OrDefault)) { return $default }
    return $null
}

function Get-LaiOllamaServerConfig {
    # What the Ollama server really runs with, from the newest 'msg="server config"' line of its
    # server.log: the tray app's own settings (Model location, Expose Ollama to the network) override
    # the OLLAMA_MODELS / OLLAMA_HOST environment variables when it starts 'ollama serve', and only
    # this line shows the result. Returns @{ Models; Host; HostIsLoopback } or $null.
    param([string]$Line)
    $m = [regex]::Match([string]$Line, 'env="((?:[^"\\]|\\.)*)"')
    if (-not $m.Success) { return $null }
    # slog quotes the map Go-style: C:\Users -> C:\\Users. Values may contain spaces, so a value runs
    # up to the next ' KEY:' (keys are printed in sorted order) or the closing ']'.
    $map = [regex]::Replace($m.Groups[1].Value, '\\(.)', '$1')
    $r = @{ Models = $null; Host = $null; HostIsLoopback = $true }
    foreach ($kv in @(@('OLLAMA_MODELS', 'Models'), @('OLLAMA_HOST', 'Host'))) {
        $v = [regex]::Match($map, '(?:^map\[| )' + $kv[0] + ':(.*?)(?= [A-Za-z_][A-Za-z0-9_]*:|\]$)')
        if ($v.Success -and $v.Groups[1].Value) { $r[$kv[1]] = $v.Groups[1].Value }
    }
    if ($r['Host']) {
        $h = [regex]::Match($r['Host'], '^(?:[A-Za-z][A-Za-z0-9+.-]*://)?(\[[^\]]*\]|[^:/]+)').Groups[1].Value
        $r['HostIsLoopback'] = ($h -match '^(127\.|localhost$|\[::1\]$|::1$)')
    }
    return $r
}

function Get-LaiOllamaLiveConfig {
    # Get-LaiOllamaServerConfig for the newest 'server config' line of Ollama's server.log, or $null.
    # Read as UTF-8 (how Ollama writes it): Windows PowerShell 5.1's Select-String reads a file without
    # a BOM in the ANSI code page, which turns C:\Users\Jos<e-acute> into a different folder.
    param([string]$LogPath)
    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return $null }
    $line = Select-String -LiteralPath $LogPath -Pattern 'msg="server config"' -Encoding UTF8 | Select-Object -Last 1
    if (-not $line) { return $null }
    return (Get-LaiOllamaServerConfig -Line $line.Line)
}

function Test-LaiSamePath {
    # Same folder, ignoring case, slash direction and a trailing separator (Windows paths).
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    $na = ($A -replace '/', '\').TrimEnd('\'); $nb = ($B -replace '/', '\').TrimEnd('\')
    return [string]::Equals($na, $nb, [StringComparison]::OrdinalIgnoreCase)
}

function Add-LaiPrevEnv {
    # Records the value a setting had before the installer first wrote it ('' = it was unset), so
    # Uninstall -ResetOllamaSettings puts the user's own back and removes only what the installer
    # added. Only before the first write: with -InstallerSetBefore (the Ollama stage has completed
    # once, also on installs from before this record existed) the current value is the installer's
    # own, so nothing is recorded. The first value seen wins. Returns $true when it recorded one.
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Saved, [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Current, [switch]$InstallerSetBefore)
    if ($InstallerSetBefore -or $Saved.ContainsKey($Name)) { return $false }
    $Saved[$Name] = [string]$Current
    return $true
}

function Get-LaiEnvResetPlan {
    # Uninstall -ResetOllamaSettings: each variable goes back to the user's own value from before the
    # install (recorded by the installer in install-state.json) or, when there was none, is removed.
    param([string[]]$Names, [hashtable]$Saved = @{})
    foreach ($n in $Names) {
        $v = $null
        if ($Saved -and $Saved.ContainsKey($n) -and [string]$Saved[$n]) { $v = [string]$Saved[$n] }
        [pscustomobject]@{ Name = $n; Value = $v }
    }
}

function Get-LaiOllamaVersion {
    param([string]$BaseUrl = 'http://127.0.0.1:11434')
    return (Invoke-LaiApi -Uri "$BaseUrl/api/version" -TimeoutSec 10).version
}

function Set-LaiProcessEnv {
    # Sets a variable for this process and the programs it starts; $null (a variable that was not
    # set before) REMOVES it. [Environment]::SetEnvironmentVariable with $null passes '' from
    # PowerShell: Windows then deletes it, but PowerShell 7 on Linux keeps an empty variable, which
    # docker compose prefers over .env (an image 'alpine:' with no tag).
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value -eq '') { Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue }
    else { Set-Item -LiteralPath "Env:$Name" -Value $Value }
}

function Get-LaiOllamaAppPath {
    # The Ollama tray app, also when installed to a custom folder (Find-LaiOllamaDir); '' when it is
    # not installed or this is not Windows.
    $d = Find-LaiOllamaDir
    if (-not $d) { return '' }
    return (Join-Path $d 'ollama app.exe')
}

function Start-LaiOllamaApp {
    # Starts the tray app without its window. Since the 0.10 desktop app, a start without 'hidden'
    # opens the Ollama window, which can take the focus from a full-screen game. '--fast-startup'
    # leaves a downloaded Ollama update for the next sign-in (a hidden start would install it now),
    # so a heal never swaps the version the presets were measured on.
    param([string]$Path = (Get-LaiOllamaAppPath))
    Start-Process -FilePath $Path -ArgumentList @('hidden', '--fast-startup')
}

function ConvertFrom-LaiServerConfigLine {
    # The settings Ollama logs at start (msg="server config" env="map[KEY:value KEY:value ...]") as a
    # hashtable. A key missing from the line is missing from the result: a newer Ollama that stops
    # reporting a setting is not the same as the setting being off.
    param([string]$Line)
    $map = @{}
    $envPart = [regex]::Match([string]$Line, 'env="?map\[(.*)\]')
    if (-not $envPart.Success) { return $map }
    foreach ($m in [regex]::Matches($envPart.Groups[1].Value, '(?<=^|[\s\[])([A-Z][A-Z0-9_]*):(\S*)')) { $map[$m.Groups[1].Value] = $m.Groups[2].Value }
    return $map
}

function Test-LaiOllamaServerSettings {
    # Checks the settings the tuning relies on against Ollama's start-up log line. Status 'ok';
    # 'wrong' (reported with another value: Ollama did not pick up the environment, restart it);
    # 'unknown' (no line, or this Ollama no longer reports the key: a restart cannot change that, the
    # measured fit and speed are the check then).
    param([string]$Line, [string]$KvCacheType = 'q8_0')
    $cfg = ConvertFrom-LaiServerConfigLine -Line $Line
    $want = [ordered]@{ OLLAMA_FLASH_ATTENTION = 'true'; OLLAMA_KV_CACHE_TYPE = $KvCacheType }
    $wrong = @(); $missing = @()
    foreach ($k in $want.Keys) {
        if (-not $cfg.ContainsKey($k)) { $missing += $k }
        elseif ([string]$cfg[$k] -ne [string]$want[$k]) { $wrong += ('{0}={1} (wanted {2})' -f $k, $cfg[$k], $want[$k]) }
    }
    $status = 'ok'
    if ($missing.Count) { $status = 'unknown' }
    if ($wrong.Count) { $status = 'wrong' }
    return [pscustomobject]@{ Status = $status; Wrong = $wrong; Missing = $missing }
}

function Get-LaiTuningDrift {
    # Tuned presets measured on another Ollama version than the running one (the Ollama app installs
    # its own updates at sign-in). Entries without a recorded version are left out: Update-Models.ps1
    # re-checks exactly this list, so a notice about anything else could never clear.
    param([hashtable]$Tuning = @{}, [string]$OllamaVersion = '', [string[]]$Keys = @())
    $out = @()
    if (-not $OllamaVersion -or -not $Tuning) { return $out }
    foreach ($k in @($Tuning.Keys | Sort-Object)) {
        if ($Keys.Count -and $Keys -notcontains $k) { continue }
        $t = $Tuning[$k]
        if (-not ($t -is [hashtable]) -or -not $t['OllamaVersion']) { continue }
        if ([string]$t['OllamaVersion'] -ne $OllamaVersion) { $out += [pscustomobject]@{ Key = [string]$k; Alias = [string]$t['Alias']; Was = [string]$t['OllamaVersion'] } }
    }
    return $out
}

function Get-LaiOllamaModelNames {
    param([string]$BaseUrl = 'http://127.0.0.1:11434')
    $r = Invoke-LaiApi -Uri "$BaseUrl/api/tags" -TimeoutSec 30
    return @($r.models | ForEach-Object { $_.name })
}

function Get-LaiOllamaDigest {
    # Manifest digest of an installed model ('' if missing); changes whenever a pull brings new content.
    param([string]$BaseUrl = 'http://127.0.0.1:11434', [Parameter(Mandatory)][string]$Name)
    $r = Invoke-LaiApi -Uri "$BaseUrl/api/tags" -TimeoutSec 30
    $want = Resolve-LaiModelName $Name
    $m = @($r.models | Where-Object { $_.name -eq $want }) | Select-Object -First 1
    if ($m) { return [string]$m.digest }
    return ''
}

function Test-LaiOllamaModel {
    param([string]$BaseUrl = 'http://127.0.0.1:11434', [Parameter(Mandatory)][string]$Name)
    return (Get-LaiOllamaModelNames -BaseUrl $BaseUrl) -contains (Resolve-LaiModelName $Name)
}

function Get-LaiOllamaModelInfo {
    param([string]$BaseUrl = 'http://127.0.0.1:11434', [Parameter(Mandatory)][string]$Name)
    $r = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/show" -Body @{ model = $Name } -TimeoutSec 60
    $trainCtx = 0
    $arch = ''
    if ($r.model_info) {
        $archProp = $r.model_info.PSObject.Properties | Where-Object { $_.Name -eq 'general.architecture' } | Select-Object -First 1
        if ($archProp) { $arch = [string]$archProp.Value }
        $ctxProp = $r.model_info.PSObject.Properties | Where-Object { $_.Name -eq "$arch.context_length" } | Select-Object -First 1
        if (-not $ctxProp) {
            $ctxProp = $r.model_info.PSObject.Properties | Where-Object { $_.Name -like '*.context_length' } | Select-Object -First 1
        }
        if ($ctxProp) { $trainCtx = [int]$ctxProp.Value }
    }
    $caps = @()
    if ($r.PSObject.Properties.Name -contains 'capabilities' -and $r.capabilities) { $caps = @($r.capabilities) }
    return [pscustomobject]@{
        Name         = $Name
        Architecture = $arch
        TrainContext = $trainCtx
        Capabilities = $caps
        Parameters   = [string]$r.parameters
    }
}

function Invoke-LaiOllamaPull {
    # Uses the ollama CLI when it is on PATH (progress bars, resumable partial downloads),
    # otherwise the HTTP API. Both are idempotent: an already-present model is a no-op.
    param(
        [string]$BaseUrl = 'http://127.0.0.1:11434',
        [Parameter(Mandatory)][string]$Name,
        [int]$Attempts = 3
    )
    $cli = Get-Command ollama -ErrorAction SilentlyContinue
    Invoke-LaiRetry -Attempts $Attempts -DelaySeconds 10 -What "pull $Name" -Action {
        if ($cli) {
            & $cli pull $Name | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "ollama pull exited with code $LASTEXITCODE" }
        } else {
            $r = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/pull" -Body @{ model = $Name; stream = $false } -TimeoutSec 0
            if ($r.status -ne 'success') { throw "pull returned status '$($r.status)'" }
        }
    } | Out-Null
    if (-not (Test-LaiOllamaModel -BaseUrl $BaseUrl -Name $Name)) { throw "Model $Name is still missing after pull." }
}

function Test-LaiRegistryReachable {
    # Any HTTP answer (even 401/404) means the network path works; only a connection or name
    # resolution failure counts as offline. Used to stop retrying every model when the PC is offline.
    param([string]$Url = 'https://registry.ollama.ai/v2/', [int]$TimeoutSec = 8)
    try { Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop | Out-Null; return $true }
    catch {
        $resp = $null
        try { $resp = $_.Exception.Response } catch { $resp = $null }
        if ($null -ne $resp) { return $true }
        # A TLS/certificate failure (proxy inspection, old protocol) is not "offline": the pulls should
        # still be tried and report their own error.
        $msg = [string]$_.Exception.Message
        if ($_.Exception.InnerException) { $msg += ' ' + $_.Exception.InnerException.Message }
        return ($msg -match 'SSL|TLS|trust|certificate')
    }
}

function Get-LaiOllamaLoaded {
    param([string]$BaseUrl = 'http://127.0.0.1:11434')
    $r = Invoke-LaiApi -Uri "$BaseUrl/api/ps" -TimeoutSec 30
    return @($r.models)
}

function Stop-LaiOllamaModels {
    # Unloads every model from VRAM (keep_alive=0). Used before context tuning and by Release-GPU.ps1.
    param([string]$BaseUrl = 'http://127.0.0.1:11434', [int]$TimeoutSec = 60)
    foreach ($m in (Get-LaiOllamaLoaded -BaseUrl $BaseUrl)) {
        try {
            Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/generate" -Body @{ model = $m.name; keep_alive = 0 } -TimeoutSec 120 | Out-Null
        } catch {
            # e.g. the model was deleted while still resident; it is evicted when its keep-alive expires.
            Write-LaiLog WARN "Could not unload $($m.name): $(Get-LaiHttpErrorText $_)"
        }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $left = @(Get-LaiOllamaLoaded -BaseUrl $BaseUrl)
        if ($left.Count -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    Write-LaiLog WARN "Still loaded after $TimeoutSec s: $(($left | ForEach-Object { $_.name }) -join ', ')"
}

function Invoke-LaiOllamaLoad {
    # Loads a model without generating (empty prompt) at a given context, then reports placement.
    param(
        [string]$BaseUrl = 'http://127.0.0.1:11434',
        [Parameter(Mandatory)][string]$Name,
        [int]$NumCtx = 0,
        [string]$KeepAlive = '5m'
    )
    # Test hook (tests/Invoke-ModelUpdateTest.ps1): a re-published tag this Ollama cannot load.
    if ($env:LOCALAI_TEST_LOAD_FAIL -and (Resolve-LaiModelName $Name) -eq (Resolve-LaiModelName $env:LOCALAI_TEST_LOAD_FAIL)) {
        throw 'llama-server: this model may be incompatible with your version of Ollama (test hook)'
    }
    $body = @{ model = $Name; keep_alive = $KeepAlive }
    if ($NumCtx -gt 0) { $body['options'] = @{ num_ctx = $NumCtx } }
    Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/generate" -Body $body -TimeoutSec 900 | Out-Null
    $resolved = Resolve-LaiModelName $Name
    $entry = Get-LaiOllamaLoaded -BaseUrl $BaseUrl | Where-Object { $_.name -eq $resolved } | Select-Object -First 1
    if (-not $entry) { throw "Model $Name did not appear in /api/ps after loading." }
    if ($null -eq $entry.size -or $null -eq $entry.size_vram) {
        throw "This Ollama version's /api/ps reports no size/size_vram for $Name; the tuner needs them (tested with Ollama 0.35.1)."
    }
    $size = [int64]$entry.size
    $vram = [int64]$entry.size_vram
    $pct = 0
    if ($size -gt 0) { $pct = [int][Math]::Floor(100.0 * $vram / $size) }
    return [pscustomobject]@{
        Name       = $resolved
        Context    = [int]$entry.context_length
        SizeGiB    = [Math]::Round($size / 1GB, 2)
        VramGiB    = [Math]::Round($vram / 1GB, 2)
        GpuPercent = $pct
    }
}

function Find-LaiMaxContext {
    # Largest context that keeps the model 100% in VRAM with -MinFreeMiB to spare.
    # Ollama's own placement decides GPU vs CPU layers; nvidia-smi confirms real headroom, because
    # on Windows an over-full card silently spills into shared system memory instead of failing.
    param(
        [string]$BaseUrl = 'http://127.0.0.1:11434',
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int[]]$Candidates,
        [int]$MaxContext = 0,
        [int]$MinFreeMiB = 768,
        [switch]$AllowCpu
    )
    $info = Get-LaiOllamaModelInfo -BaseUrl $BaseUrl -Name $Name
    $limit = $info.TrainContext
    if ($MaxContext -gt 0 -and ($limit -le 0 -or $MaxContext -lt $limit)) { $limit = $MaxContext }
    $list = @($Candidates | Where-Object { $limit -le 0 -or $_ -le $limit } | Sort-Object -Descending -Unique)
    if ($list.Count -eq 0) { $list = @($limit) }

    $result = $null
    $lastError = ''
    foreach ($ctx in $list) {
        # Each size from an empty card: VRAM freed by the previous size may show up late on Windows.
        Stop-LaiOllamaModels -BaseUrl $BaseUrl
        try { $load = Invoke-LaiOllamaLoad -BaseUrl $BaseUrl -Name $Name -NumCtx $ctx -KeepAlive '2m' }
        catch {
            # E.g. 'cudaMalloc failed: out of memory' when Ollama under-estimates: try the next size
            # instead of failing the whole install.
            $lastError = Get-LaiHttpErrorText $_
            Write-LaiLog WARN ("  ctx {0,6}: load failed ({1}); trying a smaller context" -f $ctx, $lastError)
            continue
        }
        # Median of three readings: one other program grabbing VRAM for a moment must not decide the
        # context that is then kept until the next -Retune.
        $reads = @()
        for ($i = 0; $i -lt 3; $i++) {
            $g = Get-LaiGpuInfo
            if ($g) { $reads += [int]$g.FreeMiB }
            if ($i -lt 2) { Start-Sleep -Milliseconds 700 }
        }
        $free = -1
        if ($reads.Count) { $free = @($reads | Sort-Object)[[int][Math]::Floor($reads.Count / 2)] }
        $fits = ($load.GpuPercent -ge 100) -or $AllowCpu
        $roomy = ($free -lt 0) -or ($free -ge $MinFreeMiB)
        Write-LaiLog INFO ("  ctx {0,6}: {1,3}% GPU, model+cache {2} GiB, VRAM free {3} MiB" -f $ctx, $load.GpuPercent, $load.SizeGiB, $free)
        $result = [pscustomobject]@{
            Name = $Name; TrainContext = $info.TrainContext; Context = $ctx
            GpuPercent = $load.GpuPercent; SizeGiB = $load.SizeGiB; FreeMiB = $free; Fits = ($fits -and $roomy)
        }
        if ($result.Fits) { break }
    }
    Stop-LaiOllamaModels -BaseUrl $BaseUrl
    # Not one size loaded: the weights themselves are the problem (a re-published tag this Ollama
    # cannot read, a broken upload), not VRAM. Stop before the caller rebuilds the tuned alias on them.
    if ($null -eq $result) { throw "$Name could not be loaded at any context (last error: $lastError)" }
    return $result
}

function Measure-LaiOllamaSpeed {
    # Generation speed in tokens/s at the model's configured context (load time excluded).
    param([string]$BaseUrl = 'http://127.0.0.1:11434', [Parameter(Mandatory)][string]$Name, [int]$Tokens = 128)
    # Test hook (tests/Invoke-ModelUpdateTest.ps1): a measurement that fails with the model loaded.
    if ($env:LOCALAI_TEST_SPEED_FAIL -and (Resolve-LaiModelName $Name) -eq (Resolve-LaiModelName $env:LOCALAI_TEST_SPEED_FAIL)) {
        throw 'the speed measurement failed (test hook)'
    }
    $info = Get-LaiOllamaModelInfo -BaseUrl $BaseUrl -Name $Name
    $body = @{
        model   = $Name
        prompt  = 'Explain in detail how a turbocharger works.'
        stream  = $false
        options = @{ num_predict = $Tokens; temperature = 0 }
    }
    if ($info.Capabilities -contains 'thinking') { $body['think'] = $false }
    $r = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/generate" -Body $body -TimeoutSec 900
    if (-not $r.eval_duration -or [double]$r.eval_duration -le 0) { return 0 }
    return [Math]::Round([double]$r.eval_count / ([double]$r.eval_duration / 1e9), 1)
}

function Set-LaiOllamaDerivedModel {
    # Creates/overwrites a thin model that inherits the source weights and bakes in num_ctx,
    # sampling parameters and the system prompt. Blobs are shared, so it costs no disk space.
    # Baking num_ctx here (instead of per-request) means every client - Open WebUI chats, its
    # background title/tag tasks, `ollama run` - asks for the same context, so Ollama never
    # reloads the model just because two callers disagreed about num_ctx.
    param(
        [string]$BaseUrl = 'http://127.0.0.1:11434',
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][int]$NumCtx,
        [hashtable]$Parameters = @{},
        [string]$System = ''
    )
    $params = @{}
    foreach ($k in $Parameters.Keys) { $params[$k] = $Parameters[$k] }
    $params['num_ctx'] = $NumCtx
    $body = @{ model = $Name; from = $From; parameters = $params; stream = $false }
    if ($System) { $body['system'] = $System }
    $r = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/create" -Body $body -TimeoutSec 600
    if ($r.status -ne 'success') { throw "ollama create $Name returned '$($r.status)'" }
}

#endregion

#region Open WebUI ------------------------------------------------------------------------

function Wait-LaiWebUI {
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [int]$TimeoutSec = 300)
    Wait-LaiHttp -Uri "$BaseUrl/health" -TimeoutSec $TimeoutSec -Condition { param($r) $r.status -eq $true } | Out-Null
}

function Resolve-LaiPendingPassword {
    <#
    .SYNOPSIS
        Set-OpenWebUIPassword.ps1 writes the new password to openwebui-admin.pending.json before it
        asks Open WebUI to change it. If that run was cut off, find out which password is live: if the
        pending one signs in, it becomes the stored one; if not, the pending file is dropped.
        Returns 'promoted', 'dropped' or 'none'.
    #>
    param([Parameter(Mandatory)][string]$AIRoot, [Parameter(Mandatory)][string]$BaseUrl)
    $secrets = Join-Path $AIRoot 'Secrets'
    $pending = Join-Path $secrets 'openwebui-admin.pending.json'
    $credFile = Join-Path $secrets 'openwebui-admin.json'
    if (-not (Test-Path -LiteralPath $pending)) { return 'none' }
    $p = $null
    try { $p = Get-Content -Encoding UTF8 -LiteralPath $pending -Raw | ConvertFrom-Json } catch { $p = $null }
    if (-not $p -or -not $p.password) {
        # Cut off while being written: the change request is only sent after the file is complete,
        # so it never happened.
        Remove-Item -LiteralPath $pending -Force
        return 'dropped'
    }
    try { Connect-LaiWebUI -BaseUrl $BaseUrl -Email $p.email -Password $p.password | Out-Null }
    catch {
        # Only a clear 'wrong password' (400/401/403) proves the change never happened. A 5xx, a rate
        # limit or no answer at all decides nothing: the pending file may be the only copy.
        if (@(400, 401, 403) -contains [int](Get-LaiHttpStatus $_)) {
            Remove-Item -LiteralPath $pending -Force
            return 'dropped'
        }
        return 'none'
    }
    # Replace the content only, so the credentials file keeps its restricted permissions, and in the
    # form that file has (a raw copy of the pending text would turn a protected one plain). No try:
    # a save that fails throws, and this must end before the pending file, then the only copy, goes.
    Save-LaiSecretFile -Path $credFile -Value $p
    Remove-Item -LiteralPath $pending -Force
    Write-LaiLog OK "An interrupted password change had gone through; $credFile now holds the new password."
    return 'promoted'
}

function Connect-LaiWebUI {
    param(
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Password
    )
    # Open WebUI allows 15 sign-ins per e-mail per rolling 3 minutes (failed ones count too) and then
    # answers 429. Running the installer, the health check and an update back to back can hit that,
    # so wait it out (the window frees a minute's worth every 60 s) instead of failing.
    $r = $null
    # 8 tries 45 s apart (~5 min): rejected attempts may count too, so leave margin past the 3-minute window.
    for ($try = 1; $try -le 8; $try++) {
        try { $r = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/auths/signin" -Body @{ email = $Email; password = $Password } -TimeoutSec 60; break }
        catch {
            if ([int](Get-LaiHttpStatus $_) -ne 429 -or $try -eq 8) { throw }
            if ($try -eq 1) { Write-LaiLog WARN 'Open WebUI is rate-limiting sign-ins (15 per 3 minutes); waiting for the limit to clear.' }
            # The test hook counts only as a positive whole number: anything else keeps the 45 s
            # instead of ending the sign-in with a cast error.
            $wait = 45; $askedWait = 0
            if ($env:LOCALAI_TEST_SIGNIN_WAIT -and [int]::TryParse([string]$env:LOCALAI_TEST_SIGNIN_WAIT, [ref]$askedWait) -and $askedWait -gt 0) { $wait = $askedWait }
            Start-Sleep -Seconds $wait
        }
    }
    if (-not $r -or -not $r.token -or -not $r.role) { throw "Open WebUI's sign-in answer has an unexpected shape (no token/role); this Open WebUI version may not be supported yet." }
    if ($r.role -ne 'admin') { throw "Signed in as '$Email' but role is '$($r.role)', not admin." }
    return [string]$r.token
}

function Get-LaiWebUIModelIds {
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token)
    $r = Invoke-LaiApi -Uri "$BaseUrl/api/models?refresh=true" -Token $Token -TimeoutSec 120
    return @($r.data | ForEach-Object { $_.id })
}

function Get-LaiWebUIModel {
    # Workspace/override entry for a model id, or $null if none exists.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Id)
    try {
        return Invoke-LaiApi -Uri ("$BaseUrl/api/v1/models/model?id=" + [uri]::EscapeDataString($Id)) -Token $Token
    } catch {
        if ((Get-LaiHttpStatus $_) -eq 404) { return $null }
        throw
    }
}

function Merge-LaiPresetForm {
    # Re-runs update only what the installer manages (base model, name, system prompt, tool mode,
    # capabilities, ...). Everything else the user changed on the preset - attached knowledge, tools,
    # access, extra parameters - is kept.
    param([Parameter(Mandatory)][hashtable]$Managed, $Existing)
    if (-not $Existing) { return $Managed }
    # Set when the preset is created, then left to the user:
    #   think            Open WebUI 0.11.4 re-applies a preset's think over the per-chat Chat Controls
    #                    switch, so the preset is the only place to turn Uncensored Fast's reasoning on.
    #   image_generation an image button the user wired to ComfyUI (not code execution, which stays off).
    #   user_input, files the two tool categories that only ask you a question or read the files of
    #                    the chat: on when the preset is made, and off for good once you switch them
    #                    off. (Every other tool category but image_generation is put back to the
    #                    installer's value: the ones that write, schedule, send or start something
    #                    stay off.)
    # A value that is there is the user's. A think or an image capability that is missing or null
    # gets the installer's value again. One of these three tool switches that is missing from a set
    # of tool switches the preset already has is ON: Open WebUI takes a missing switch for on, and
    # (as its 0.11.4 source was read on 2026-10-08, not seen in a running one) its editor stores a
    # box that was ticked again by deleting the switch. So 'missing' is how a picture tool the owner
    # switched on arrives here, and writing the installer's false over it switched that tool off
    # again with every update. It is written out as true instead, which changes nothing in what the
    # model may do and leaves nothing to a default. (No such set at all: the preset is not the
    # installer's work yet, and it gets the whole set as a new preset does.)
    $createOnly = @{ params = @('think'); capabilities = @('image_generation'); builtinTools = @('image_generation', 'user_input', 'files') }
    $old = ConvertTo-LaiHashtable $Existing
    $params = @{}
    if ($old.ContainsKey('params') -and $old['params'] -is [hashtable]) { $params = $old['params'] }
    foreach ($k in $Managed['params'].Keys) {
        if ($createOnly['params'] -contains $k -and $params.ContainsKey($k) -and $null -ne $params[$k]) { continue }
        $params[$k] = $Managed['params'][$k]
    }
    $meta = @{}
    if ($old.ContainsKey('meta') -and $old['meta'] -is [hashtable]) { $meta = $old['meta'] }
    foreach ($k in $Managed['meta'].Keys) {
        # capabilities / builtinTools: set the switches the installer manages, keep every other one
        # (replacing the whole set erased what the user had chosen for the rest). Among the tools
        # the installer now manages every category Open WebUI 0.11.4 has (New-LaiPresetForm lists
        # them), because Open WebUI treats a missing tool category as ON: an install from before
        # that, where the note, task, automation, calendar, notification, channel and subagent
        # switches are missing, gets them here, off, and gets them off again when they were
        # switched on. What is kept is a switch of a newer Open WebUI that the installer does not know.
        if ($Managed['meta'][$k] -is [hashtable] -and $meta.ContainsKey($k) -and $meta[$k] -is [hashtable]) {
            foreach ($leaf in $Managed['meta'][$k].Keys) {
                $own = ($createOnly.ContainsKey($k) -and $createOnly[$k] -contains $leaf)
                if ($own -and $meta[$k].ContainsKey($leaf) -and $null -ne $meta[$k][$leaf]) { continue }
                if ($own -and $k -eq 'builtinTools' -and -not $meta[$k].ContainsKey($leaf)) { $meta[$k][$leaf] = $true; continue }
                $meta[$k][$leaf] = $Managed['meta'][$k][$leaf]
            }
        } else { $meta[$k] = $Managed['meta'][$k] }
    }
    $access = $Managed['access_grants']
    if ($old.ContainsKey('access_grants') -and $null -ne $old['access_grants']) { $access = @($old['access_grants']) }
    return @{
        id = $Managed['id']; name = $Managed['name']; base_model_id = $Managed['base_model_id']
        meta = $meta; params = $params; access_grants = $access; is_active = $true
    }
}

function Set-LaiWebUIModel {
    # Idempotent create-or-update of a workspace model (preset).
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][hashtable]$Model)
    $existing = Get-LaiWebUIModel -BaseUrl $BaseUrl -Token $Token -Id $Model.id
    if ($existing) {
        Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/models/model/update" -Body $Model -Token $Token | Out-Null
        return 'updated'
    }
    Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/models/create" -Body $Model -Token $Token | Out-Null
    return 'created'
}

function Show-LaiWebUIModel {
    # Undoes Hide-LaiWebUIModel on an existing model; everything else on it is kept.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Id)
    $existing = Get-LaiWebUIModel -BaseUrl $BaseUrl -Token $Token -Id $Id
    if (-not $existing) { return 'missing' }
    $form = ConvertTo-LaiHashtable $existing
    if (-not $form.ContainsKey('meta') -or $null -eq $form['meta']) { $form['meta'] = @{} }
    if ($form['meta']['hidden'] -ne $true) { return 'already shown' }
    $form['meta']['hidden'] = $false
    $form['id'] = $Id
    if ($null -eq $form['params']) { $form['params'] = @{} }
    Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/models/model/update" -Body $form -Token $Token | Out-Null
    return 'shown'
}

function Hide-LaiWebUIModel {
    # Hides a raw/base model from the chat selector without touching any per-model settings
    # the user already saved for it (same thing the Admin > Models "hide" toggle does).
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Id)
    $existing = Get-LaiWebUIModel -BaseUrl $BaseUrl -Token $Token -Id $Id
    if ($existing) {
        $form = ConvertTo-LaiHashtable $existing
        if (-not $form.ContainsKey('meta') -or $null -eq $form['meta']) { $form['meta'] = @{} }
        if ($form['meta']['hidden'] -eq $true) { return 'already hidden' }
        $form['meta']['hidden'] = $true
        # The whole model as the server returned it (it ignores fields it does not know): a fixed key
        # list would reset everything else, such as who may use the model.
        $update = $form
        $update['id'] = $Id
        if ($null -eq $update['params']) { $update['params'] = @{} }
        Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/models/model/update" -Body $update -Token $Token | Out-Null
        return 'hidden'
    }
    $form = @{ id = $Id; name = $Id; base_model_id = $null; meta = @{ hidden = $true }; params = @{}; access_grants = @(); is_active = $true }
    Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/models/create" -Body $form -Token $Token | Out-Null
    return 'hidden'
}

function Get-LaiWebUIRetrievalConfig {
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token)
    return Invoke-LaiApi -Uri "$BaseUrl/api/v1/retrieval/config" -Token $Token
}

function Set-LaiWebUIRetrievalConfig {
    # Top-level RAG keys are a partial update (Open WebUI skips null fields). The nested 'web'
    # object is NOT: the server assigns every web field it defines, so a partial 'web' would null
    # out the rest (e.g. SEARXNG_LANGUAGE=None crashes every SearXNG search with AttributeError).
    # So 'web' is always sent as current-config + changes, with known defaults repaired.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][hashtable]$Settings, [int]$TimeoutSec = 120)
    $body = @{}
    foreach ($k in $Settings.Keys) { $body[$k] = $Settings[$k] }
    if ($body.ContainsKey('web')) {
        $current = ConvertTo-LaiHashtable (Get-LaiWebUIRetrievalConfig -BaseUrl $BaseUrl -Token $Token)
        $web = @{}
        if ($current.ContainsKey('web') -and $current['web']) { $web = $current['web'] }
        $defaults = @{ SEARXNG_LANGUAGE = 'all'; WEB_SEARCH_CONCURRENT_REQUESTS = 0; WEB_LOADER_CONCURRENT_REQUESTS = 10; WEB_SEARCH_TRUST_ENV = $true }
        foreach ($k in $defaults.Keys) {
            if (-not $web.ContainsKey($k) -or $null -eq $web[$k] -or "$($web[$k])" -eq '') { $web[$k] = $defaults[$k] }
        }
        foreach ($k in $body['web'].Keys) { $web[$k] = $body['web'][$k] }
        $body['web'] = $web
    }
    return Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/retrieval/config/update" -Body $body -Token $Token -TimeoutSec $TimeoutSec
}

# Document search runs these inside the Open WebUI container, on the CPU (an Ollama embedder would
# push the chat model out of VRAM on every question: OLLAMA_MAX_LOADED_MODELS=1). Open WebUI's own
# default, all-MiniLM-L6-v2, reads only the first ~256 tokens of a chunk; bge-m3 reads 8,192.
$script:LaiEmbeddingModel = 'BAAI/bge-m3'
$script:LaiRerankingModel = 'BAAI/bge-reranker-v2-m3'
$script:LaiStockEmbeddingModel = 'sentence-transformers/all-MiniLM-L6-v2'

function Set-LaiWebUIEmbedding {
    <#
    .SYNOPSIS
        Puts document search on a long-context embedding model and a reranker (both downloaded by
        Open WebUI once, roughly 7 GB together, and run on the CPU), then re-indexes the knowledge
        collections, whose vectors from the old model cannot be compared with the new one. Leaves
        alone an embedding setup the owner chose (another engine or model) and a reranker they set.
        Returns Result ('changed', 'unchanged', 'owner') and Warnings (a failure keeps the old model).
    #>
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [int]$TimeoutSec = 1800)
    $warn = @()
    $cur = Invoke-LaiApi -Uri "$BaseUrl/api/v1/retrieval/embedding" -Token $Token
    $engine = [string]$cur.RAG_EMBEDDING_ENGINE; $model = [string]$cur.RAG_EMBEDDING_MODEL
    if ($engine -ne '' -or ($model -and @($script:LaiStockEmbeddingModel, $script:LaiEmbeddingModel) -notcontains $model)) {
        return [pscustomobject]@{ Result = 'owner'; Detail = (("$engine $model").Trim()); Warnings = @() }
    }
    $result = 'unchanged'
    if ($model -ne $script:LaiEmbeddingModel) {
        Write-LaiLog STEP "Document search: embedding model $($script:LaiEmbeddingModel) (a one-time download of a few GB; runs on the CPU)"
        try {
            Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/retrieval/embedding/update" -Token $Token -TimeoutSec $TimeoutSec `
                -Body @{ RAG_EMBEDDING_ENGINE = ''; RAG_EMBEDDING_MODEL = $script:LaiEmbeddingModel } | Out-Null
            $now = [string](Invoke-LaiApi -Uri "$BaseUrl/api/v1/retrieval/embedding" -Token $Token).RAG_EMBEDDING_MODEL
            if ($now -ne $script:LaiEmbeddingModel) { throw "Open WebUI kept $now" }
        } catch {
            $why = (Get-LaiHttpErrorText $_) -replace '\s+', ' '
            if (-not $why) { $why = $_.Exception.Message }
            $warn += "Document search keeps its old embedding model: switching to $($script:LaiEmbeddingModel) failed ($why). Run the installer again when the internet connection is fine"
            return [pscustomobject]@{ Result = 'unchanged'; Detail = $model; Warnings = $warn }
        }
        $result = 'changed'
        Write-LaiLog OK "Document search uses $($script:LaiEmbeddingModel); re-indexing the knowledge collections with it (minutes per few hundred pages)"
        try { Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/knowledge/reindex" -Token $Token -TimeoutSec 7200 | Out-Null; Write-LaiLog OK 'Knowledge collections re-indexed' }
        catch { $warn += "The knowledge collections still hold the old model's index ($((Get-LaiHttpErrorText $_) -replace '\s+', ' ')): Admin Panel > Settings > Documents > Reindex Knowledge Base Vectors" }
    }
    # The reranker re-scores the candidates of hybrid search (keywords + meaning) and keeps the best.
    # Open WebUI switches hybrid search off by itself if the reranker cannot load: checked below.
    try {
        $rc = Get-LaiWebUIRetrievalConfig -BaseUrl $BaseUrl -Token $Token
        $rr = [string]$rc.RAG_RERANKING_MODEL
        if (-not $rr) {
            Write-LaiLog STEP "Document search: reranker $($script:LaiRerankingModel) (a one-time download of a few GB; runs on the CPU)"
            Set-LaiWebUIRetrievalConfig -BaseUrl $BaseUrl -Token $Token -Settings @{ ENABLE_RAG_HYBRID_SEARCH = $true; RAG_RERANKING_MODEL = $script:LaiRerankingModel } -TimeoutSec $TimeoutSec | Out-Null
            $rc = Get-LaiWebUIRetrievalConfig -BaseUrl $BaseUrl -Token $Token
            if ([string]$rc.RAG_RERANKING_MODEL -ne $script:LaiRerankingModel -or -not $rc.ENABLE_RAG_HYBRID_SEARCH) { throw 'Open WebUI could not load it and turned hybrid search off' }
            if ($result -eq 'unchanged') { $result = 'changed' }
        }
    } catch {
        $why = (Get-LaiHttpErrorText $_) -replace '\s+', ' '
        if (-not $why) { $why = $_.Exception.Message }
        $warn += "Document search runs without its reranker ($why); run the installer again to retry"
    }
    return [pscustomobject]@{ Result = $result; Detail = $script:LaiEmbeddingModel; Warnings = $warn }
}

# The health watch's banner at the top of every Open WebUI page (phone included): a toast is easy to
# miss, and Windows can have them switched off for PowerShell.
$script:LaiBannerId = 'localai-health-watch'

function Set-LaiWebUIBanner {
    <#
    .SYNOPSIS
        Shows $Text as the health watch's banner, or removes it with -Clear. Banners the owner made
        are kept. Returns $true when the list changed.
    #>
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [string]$Text = '', [switch]$Clear)
    $uri = "$BaseUrl/api/v1/configs/banners"
    $cur = @(Invoke-LaiApi -Uri $uri -Token $Token | Where-Object { $null -ne $_ })
    $others = @($cur | Where-Object { [string]$_.id -ne $script:LaiBannerId })
    $mine = @($cur | Where-Object { [string]$_.id -eq $script:LaiBannerId })
    if ($Clear) {
        if ($mine.Count -eq 0) { return $false }
        $list = $others
    } else {
        if ($mine.Count -eq 1 -and [string]$mine[0].content -eq $Text) { return $false }
        $list = @($others) + @([ordered]@{ id = $script:LaiBannerId; type = 'warning'; title = 'Local AI'; content = $Text; dismissible = $true; timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() })
    }
    Invoke-LaiApi -Method POST -Uri $uri -Token $Token -Body @{ banners = @($list) } | Out-Null
    return $true
}

function Set-LaiWebUIOllamaUrl {
    # Points Open WebUI's Ollama connection at $OllamaUrl. OLLAMA_BASE_URL is only a first-boot
    # default, so an existing install has to be changed through the API. Only connections this
    # installer manages (host.docker.internal:11434, the render guard, or a localhost URL, which
    # never works from inside a container) are rewritten; any other connection the user added is
    # left alone. Returns $true when something changed.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$OllamaUrl)
    $cfg = ConvertTo-LaiHashtable (Invoke-LaiApi -Uri "$BaseUrl/ollama/config" -Token $Token)
    # A newer Open WebUI that renamed the list must not be read as 'no connections' and overwritten
    # with ours alone (that would delete every connection the user added).
    if (-not ($cfg -is [hashtable]) -or -not $cfg.ContainsKey('OLLAMA_BASE_URLS')) {
        Write-LaiLog WARN "Open WebUI's Ollama settings have an unexpected shape (no OLLAMA_BASE_URLS); not changing them. Set the connection in Admin Settings > Connections if chats fail."
        return $false
    }
    $managed = @('http://host.docker.internal:11434', 'http://render-guard:11434', 'http://localhost:11434', 'http://127.0.0.1:11434')
    $urls = @()
    if ($cfg.ContainsKey('OLLAMA_BASE_URLS') -and $cfg['OLLAMA_BASE_URLS']) { $urls = @($cfg['OLLAMA_BASE_URLS']) }
    $new = @(); $changed = $false
    foreach ($u in $urls) {
        $t = ([string]$u).TrimEnd('/')
        if ($managed -contains $t -and $t -ne $OllamaUrl) { $new += $OllamaUrl; $changed = $true } else { $new += $t }
    }
    if ($new.Count -eq 0) { $new = @($OllamaUrl); $changed = $true }
    if ($new -notcontains $OllamaUrl) { Write-LaiLog WARN "Open WebUI uses a custom Ollama connection ($($new -join ', ')); not changing it." }
    $enabled = $true
    if ($cfg.ContainsKey('ENABLE_OLLAMA_API') -and $cfg['ENABLE_OLLAMA_API'] -eq $false) { $changed = $true }
    if (-not $changed) { return $false }
    $apiConfigs = @{}
    if ($cfg.ContainsKey('OLLAMA_API_CONFIGS') -and $cfg['OLLAMA_API_CONFIGS']) { $apiConfigs = $cfg['OLLAMA_API_CONFIGS'] }
    # The server's own object with only the two managed keys changed: any setting a newer version
    # adds is sent back as it was.
    $body = $cfg
    $body['ENABLE_OLLAMA_API'] = $enabled; $body['OLLAMA_BASE_URLS'] = [object[]]$new; $body['OLLAMA_API_CONFIGS'] = $apiConfigs
    Invoke-LaiApi -Method POST -Uri "$BaseUrl/ollama/config/update" -Body $body -Token $Token | Out-Null
    return $true
}

function Get-LaiWebUICompat {
    # Compares an Open WebUI version ('v0.12.1', '0.11.4-dev') with the one this toolkit was tested
    # against. Returns 'tested', 'newer', 'older' or 'unknown'. Newer versions usually work, but API
    # changes are possible: callers warn instead of assuming.
    param([string]$Version, [string]$Tested = '0.11.4')
    $m = [regex]::Match([string]$Version, '(\d+)\.(\d+)\.(\d+)')
    if (-not $m.Success) { return 'unknown' }
    $v = [version]('{0}.{1}.{2}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
    $t = [version]$Tested
    if ($v -gt $t) { return 'newer' }
    if ($v -lt $t) { return 'older' }
    return 'tested'
}

function Get-LaiWebUIKnowledge {
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token)
    $all = @()
    for ($page = 1; $page -le 50; $page++) {
        $r = Invoke-LaiApi -Uri "$BaseUrl/api/v1/knowledge/?page=$page" -Token $Token
        # Without 'items' every run would find no collections and create them all again.
        if (-not $r -or -not ($r.PSObject.Properties.Name -contains 'items')) { throw "Open WebUI's knowledge list has an unexpected shape (no 'items'); not creating collections to avoid duplicates." }
        $items = @($r.items)
        $all += $items
        if ($items.Count -eq 0 -or $all.Count -ge [int]$r.total) { break }
    }
    return $all
}

function Add-LaiWebUIKnowledge {
    # Ensures a knowledge collection with this exact name exists; returns its id.
    param(
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = ''
    )
    $found = Get-LaiWebUIKnowledge -BaseUrl $BaseUrl -Token $Token | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($found) { return [pscustomobject]@{ Id = $found.id; Action = 'exists' } }
    $r = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/knowledge/create" -Body @{ name = $Name; description = $Description } -Token $Token
    return [pscustomobject]@{ Id = $r.id; Action = 'created' }
}

function Send-LaiWebUIFile {
    # Multipart upload via HttpClient (PS 5.1 has no Invoke-RestMethod -Form). Returns the file id.
    param(
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Path,
        [string]$ContentType = 'text/markdown'
    )
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    try {
        $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token)
        $form = New-Object System.Net.Http.MultipartFormDataContent
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $part = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $bytes)
        $part.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
        $form.Add($part, 'file', [System.IO.Path]::GetFileName($Path))
        # Caught: a .NET exception is only statement-terminating, so the real cause would be lost.
        try {
            $resp = $client.PostAsync("$BaseUrl/api/v1/files/", $form).GetAwaiter().GetResult()
            $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } catch {
            $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
            throw "Upload to $BaseUrl failed: $($e.Message)"
        }
        if (-not $resp.IsSuccessStatusCode) { throw "Upload failed: HTTP $([int]$resp.StatusCode) $text" }
        return ($text | ConvertFrom-Json).id
    } finally { $client.Dispose() }
}

function Wait-LaiWebUIFileProcessed {
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$FileId, [int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $s = Invoke-LaiApi -Uri "$BaseUrl/api/v1/files/$FileId/process/status" -Token $Token
        if ($s.status -eq 'completed') { return }
        if ($s.status -eq 'failed') {
            throw 'Open WebUI could not process the test document (embedding/tokenizer failure). Check: docker logs --tail 200 open-webui'
        }
        Start-Sleep -Seconds 2
    }
    throw "Document processing did not finish within $TimeoutSec s."
}

function Invoke-LaiWebUIChat {
    # One non-streaming completion through Open WebUI (exercises its whole middleware chain:
    # system prompt, memory injection, RAG). Returns the assistant text.
    param(
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Prompt,
        [hashtable]$Features = @{},
        [object[]]$Files = @(),
        # PNG images (base64, no data: prefix) sent with the prompt, as the browser sends a pasted image.
        [string[]]$ImageBase64 = @(),
        [int]$TimeoutSec = 900
    )
    $content = $Prompt
    if ($ImageBase64.Count -gt 0) {
        $content = @(@{ type = 'text'; text = $Prompt }) + @($ImageBase64 | ForEach-Object { @{ type = 'image_url'; image_url = @{ url = "data:image/png;base64,$_" } } })
    }
    $body = @{
        model    = $Model
        stream   = $false
        messages = @(@{ role = 'user'; content = $content })
    }
    if ($Features.Count -gt 0) { $body['features'] = $Features }
    if ($Files.Count -gt 0) { $body['files'] = $Files }
    $r = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/chat/completions" -Body $body -Token $Token -TimeoutSec $TimeoutSec
    return [string]$r.choices[0].message.content
}

function Test-LaiWebUIChat {
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Model)
    $answer = Invoke-LaiWebUIChat -BaseUrl $BaseUrl -Token $Token -Model $Model -Prompt 'Respond with exactly: LOCAL AI WORKING'
    # CultureInvariant: on tr-TR, IgnoreCase does not pair I with i ('working' vs 'WORKING').
    return [pscustomobject]@{ Passed = [regex]::IsMatch($answer, 'LOCAL AI WORKING', 'IgnoreCase, CultureInvariant'); Answer = $answer.Trim() }
}

# 64x64 single-colour PNGs for the image check (a few hundred bytes; no encoder needed on 5.1).
$script:LaiTestImages = @{
    red   = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAS0lEQVR42u3PQQkAAAgAsetfWiP4FgYrsKZeS0BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEDgsqnc8OJg6Ln3AAAAAElFTkSuQmCC'
    green = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAATElEQVR42u3PQQkAAAgAseufwqhG8C0MVmA1/SYgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcFlT0gCXrcLQywAAAABJRU5ErkJggg=='
    blue  = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAS0lEQVR42u3PQQkAAAgAsetfWiP4FgYrsGqeExAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBA4LMf88OL0EKXAAAAAAElFTkSuQmCC'
}

function Test-LaiWebUIVision {
    # Sends a single-colour image through a preset (browser path: Open WebUI's image conversion, the
    # render guard, Ollama's projector, llama.cpp) and asks for its colour. A text-only path answers
    # that it sees no image, or errors. -Colour picks the image (default: random, so a guess rarely
    # passes).
    param(
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Model,
        [ValidateSet('', 'red', 'green', 'blue')][string]$Colour = ''
    )
    if (-not $Colour) { $Colour = @('red', 'green', 'blue')[(Get-Random -Minimum 0 -Maximum 3)] }
    $answer = Invoke-LaiWebUIChat -BaseUrl $BaseUrl -Token $Token -Model $Model -ImageBase64 @($script:LaiTestImages[$Colour]) `
        -Prompt 'What colour is this image? Answer with one word.'
    return [pscustomobject]@{ Passed = [regex]::IsMatch($answer, "\b$Colour\b", 'IgnoreCase, CultureInvariant'); Expected = $Colour; Answer = $answer.Trim() }
}

function Test-LaiPresetVision {
    # A preset's image upload against what Ollama reports for its model: 'ok', 'missing' (the preset
    # accepts images the model cannot read, so every image errors) or 'unused' (the model reads
    # images but the preset refuses them).
    param([bool]$PresetVision, [string[]]$Capabilities = @())
    $model = @($Capabilities) -contains 'vision'
    if ($PresetVision -and -not $model) { return 'missing' }
    if ($model -and -not $PresetVision) { return 'unused' }
    return 'ok'
}

function Get-LaiContextOverride {
    <#
    .SYNOPSIS
        Places where Open WebUI sends its own num_ctx / num_batch to Ollama instead of letting the
        tuned alias decide: the signed-in user's Settings, the admin default model parameters and
        the presets' Advanced Params. One line per place; empty when there is none. A different
        context reloads the 19 GB model whenever a background task (titles, follow-ups) asks for the
        alias's own size, and a larger one spills to the CPU. Per-chat Controls are stored with each
        chat and cannot be read here. A place that cannot be read is skipped.
    #>
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [string[]]$PresetIds = @())
    $find = {
        param($Params)
        $p = ConvertTo-LaiHashtable $Params
        $hits = @()
        if ($p -is [hashtable]) {
            $sets = @($p)
            if ($p.ContainsKey('custom_params') -and $p['custom_params'] -is [hashtable]) { $sets += $p['custom_params'] }
            foreach ($s in $sets) {
                foreach ($k in 'num_ctx', 'num_batch') {
                    if ($s.ContainsKey($k) -and $null -ne $s[$k] -and "$($s[$k])" -ne '') { $hits += "$k $($s[$k])" }
                }
            }
        }
        return $hits
    }
    $out = @()
    try {
        $us = ConvertTo-LaiHashtable (Invoke-LaiApi -Uri "$BaseUrl/api/v1/users/user/settings" -Token $Token)
        if ($us -is [hashtable] -and $us['ui'] -is [hashtable]) {
            $hits = @(& $find $us['ui']['params'])
            if ($hits.Count) { $out += "your Settings > General > Advanced Parameters ($($hits -join ', '))" }
        }
    } catch { Write-Verbose "user settings not readable: $($_.Exception.Message)" }
    try {
        $mc = ConvertTo-LaiHashtable (Invoke-LaiApi -Uri "$BaseUrl/api/v1/configs/models" -Token $Token)
        if ($mc -is [hashtable]) {
            $hits = @(& $find $mc['DEFAULT_MODEL_PARAMS'])
            if ($hits.Count) { $out += "Admin Panel > Settings > Models > default parameters ($($hits -join ', '))" }
        }
    } catch { Write-Verbose "model defaults not readable: $($_.Exception.Message)" }
    foreach ($id in $PresetIds) {
        try {
            $p = Get-LaiWebUIModel -BaseUrl $BaseUrl -Token $Token -Id $id
            if (-not $p) { continue }
            $hits = @(& $find $p.params)
            $name = [string]$p.name; if (-not $name) { $name = $id }
            if ($hits.Count) { $out += "Workspace > Models > $name > Advanced Params ($($hits -join ', '))" }
        } catch { Write-Verbose "preset $id not readable: $($_.Exception.Message)" }
    }
    return $out
}

function Test-LaiWebUIMemory {
    # Guide Step 29, automated: store a fact, ask for it in a fresh conversation, then delete it.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Model)
    $number = Get-Random -Minimum 1000 -Maximum 9999
    $mem = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/memories/add" -Token $Token -Body @{
        content = "For test purposes, my preferred test number is $number."
        type    = 'user'
    }
    try {
        $answer = Invoke-LaiWebUIChat -BaseUrl $BaseUrl -Token $Token -Model $Model -Features @{ memory = $true } `
            -Prompt 'What is my preferred test number? Answer with just the number.'
        return [pscustomobject]@{ Passed = ($answer -match [string]$number); Expected = $number; Answer = $answer.Trim() }
    } finally {
        Invoke-LaiApi -Method DELETE -Uri "$BaseUrl/api/v1/memories/$($mem.id)" -Token $Token | Out-Null
    }
}

function Get-LaiWebUISelfTestLeftover {
    # What a RAG self-test that was cut off (window closed, PC shut down) leaves in Open WebUI: its
    # temporary collection and the uploaded manual, which nothing else would ever remove. Exact names
    # only, so nothing the user made matches. Returns one object per item with the URI that deletes it.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token)
    $out = @()
    foreach ($k in @(Get-LaiWebUIKnowledge -BaseUrl $BaseUrl -Token $Token | Where-Object { $_.name -ceq $script:LaiSelfTestKb })) {
        $out += [pscustomobject]@{ Kind = 'collection'; Id = [string]$k.id; Uri = "$BaseUrl/api/v1/knowledge/$($k.id)/delete" }
    }
    $files = @()
    # 404 is this endpoint's 'no file has that name'.
    try { $files = @(Invoke-LaiApi -Uri "$BaseUrl/api/v1/files/search?filename=$([uri]::EscapeDataString($script:LaiSelfTestFile))&content=false" -Token $Token | ForEach-Object { $_ }) }
    catch { if ((Get-LaiHttpStatus $_) -ne 404) { throw } }
    foreach ($f in $files) {
        if ([string]$f.filename -ceq $script:LaiSelfTestFile) { $out += [pscustomobject]@{ Kind = 'file'; Id = [string]$f.id; Uri = "$BaseUrl/api/v1/files/$($f.id)" } }
    }
    return $out
}

function Test-LaiWebUIRag {
    # Guide Step 33, automated: index a document containing a random code, retrieve it, clean up.
    param(
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Model,
        [string]$WorkDir = [System.IO.Path]::GetTempPath()
    )
    $code = 'QX-{0}-TANGERINE' -f (Get-Random -Minimum 1000 -Maximum 9999)
    # A run that was cut off before its clean-up left these behind: remove them first.
    try {
        foreach ($left in @(Get-LaiWebUISelfTestLeftover -BaseUrl $BaseUrl -Token $Token)) {
            Invoke-LaiApi -Method DELETE -Uri $left.Uri -Token $Token | Out-Null
            Write-LaiLog INFO "Removed a self-test $($left.Kind) left by an interrupted earlier check"
        }
    } catch { Write-LaiLog WARN "Could not remove what an interrupted earlier self-test left in Open WebUI ($($_.Exception.Message)); delete '$script:LaiSelfTestKb' in Workspace > Knowledge" }
    $doc = Join-Path $WorkDir $script:LaiSelfTestFile
    $text = "# Zorblax 9000 Widget Manual`n`n## Calibration`n`nThe calibration code for the Zorblax 9000 widget is $code. " +
        "Hold the reset button for 12 seconds before entering it.`n`n## Maintenance`n`nClean the intake filter monthly.`n"
    [System.IO.File]::WriteAllText($doc, $text, (New-Object System.Text.UTF8Encoding($false)))
    $kb = $null; $fileId = $null
    try {
        $kb = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/knowledge/create" -Token $Token -Body @{
            name = $script:LaiSelfTestKb; description = 'Created and deleted by Install-LocalAI.ps1'
        }
        $fileId = Send-LaiWebUIFile -BaseUrl $BaseUrl -Token $Token -Path $doc
        Wait-LaiWebUIFileProcessed -BaseUrl $BaseUrl -Token $Token -FileId $fileId
        Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/knowledge/$($kb.id)/file/add" -Token $Token -Body @{ file_id = $fileId } | Out-Null
        $answer = Invoke-LaiWebUIChat -BaseUrl $BaseUrl -Token $Token -Model $Model -Files @(@{ type = 'collection'; id = $kb.id }) `
            -Prompt 'According to the supplied manual, what is the calibration code for the Zorblax 9000 widget? Reply with only the code.'
        return [pscustomobject]@{ Passed = [regex]::IsMatch($answer, [regex]::Escape($code), 'IgnoreCase, CultureInvariant'); Expected = $code; Answer = $answer.Trim() }
    } finally {
        if ($kb) { try { Invoke-LaiApi -Method DELETE -Uri "$BaseUrl/api/v1/knowledge/$($kb.id)/delete" -Token $Token | Out-Null } catch { Write-Verbose 'self-test KB already gone' } }
        if ($fileId) { try { Invoke-LaiApi -Method DELETE -Uri "$BaseUrl/api/v1/files/$fileId" -Token $Token | Out-Null } catch { Write-Verbose 'self-test file already gone' } }
        Remove-Item -LiteralPath $doc -Force -ErrorAction SilentlyContinue
    }
}

function Test-LaiWebUIWebSearch {
    # Runs a search through Open WebUI -> SearXNG. 'no-results' means the wiring works but the
    # upstream engines returned nothing (rate limits, captchas); 'error' means the chain is broken.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [string]$Query = 'Ollama release notes')
    try {
        $r = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/retrieval/process/web/search" -Token $Token -Body @{ queries = @($Query) } -TimeoutSec 180
        $urls = @($r.filenames | Where-Object { $_ })
        # An empty list is the same situation as "No results found": not proof that search works.
        if ($urls.Count -eq 0) { return [pscustomobject]@{ Status = 'no-results'; Count = 0; Detail = 'the search returned no pages' } }
        return [pscustomobject]@{ Status = 'ok'; Count = $urls.Count; Detail = (($urls | Select-Object -First 3) -join ', ') }
    } catch {
        $msg = Get-LaiHttpErrorText $_
        if ($msg -match 'No results found') { return [pscustomobject]@{ Status = 'no-results'; Count = 0; Detail = $msg } }
        return [pscustomobject]@{ Status = 'error'; Count = 0; Detail = $msg }
    }
}

function ConvertTo-LaiSearxngDiagnosis {
    # Reads a SearXNG JSON answer: how many results, and which engines failed and why. Open WebUI keeps
    # only the results, so an empty search there cannot tell a CAPTCHA (wait) from a scraper broken
    # by a site change (only a newer SearXNG image fixes that).
    # Summary: the 'SearXNG search' check's text. WebUIHint: why Open WebUI's own search came back empty.
    param($Response)
    $count = 0; $engines = @(); $broken = @(); $blocked = @(); $refused = @()
    $names = @(); if ($Response -and $Response.PSObject) { $names = @($Response.PSObject.Properties.Name) }
    if ($names -contains 'results') { $count = @($Response.results | Where-Object { $_ }).Count }
    if ($names -contains 'unresponsive_engines') {
        foreach ($u in @($Response.unresponsive_engines)) {
            $pair = @($u)
            if ($pair.Count -lt 1 -or -not $pair[0]) { continue }
            $engine = [string]$pair[0]; $why = ''
            if ($pair.Count -gt 1) { $why = [string]$pair[1] }
            $engines += ('{0}: {1}' -f $engine, $why)
            # SearXNG's own labels (searx/webutils.py); 'Suspended: ' may come first.
            if ($why -match 'parsing error|unexpected crash') { $broken += $engine }
            elseif ($why -match 'CAPTCHA|too many requests|access denied') { $blocked += $engine }
            elseif ($why -match 'HTTP error|server API error') { $refused += $engine }
        }
    }
    $hint = 'the search engines answered with nothing; check the internet connection (docker logs --tail 50 searxng shows the details)'
    if ($broken.Count) {
        $hint = "$($broken -join ', ') no longer understands its site's pages (parsing error): only a newer SearXNG fixes that: Update-OpenWebUI.ps1 -SearxngVersion <newer tag from hub.docker.com/r/searxng/searxng/tags>"
    } elseif ($blocked.Count) {
        $hint = "$($blocked -join ', ') is rate-limiting this PC (CAPTCHA / too many requests): wait a few minutes to an hour, then search again"
    } elseif ($refused.Count) {
        # The site answered, with an error page or an API refusal: not a connection problem.
        $hint = "$($refused -join ', ') answered but refused the search (the site may be blocking this PC): wait, and if it lasts, a newer SearXNG may help (Update-OpenWebUI.ps1 -SearxngVersion <newer tag from hub.docker.com/r/searxng/searxng/tags>)"
    }
    $list = $engines -join '; '
    if ($count -gt 0) {
        $summary = "$count results"
        # Some engines failing while others answer is how a CAPTCHA wave or a broken scraper starts.
        if ($engines.Count) { $summary += " (not answering: $list)" }
        # Open WebUI keeps only the pages its web loader could fetch (process_web_search 'filenames').
        $webui = "SearXNG itself finds $count results, so Open WebUI could not use them: check Admin Settings > Web Search (SearXNG query URL, web loader / SSL verification) and docker logs --tail 50 open-webui"
    } else {
        $who = ''; if ($engines.Count) { $who = " ($list)" }
        $summary = "no results$who - $hint"
        $webui = "SearXNG finds nothing either$who - $hint"
    }
    return [pscustomobject]@{ Count = $count; Engines = $engines; Broken = $broken; Blocked = $blocked; Refused = $refused; Hint = $hint; Summary = $summary; WebUIHint = $webui }
}

function Get-LaiSearxngProbe {
    # One search straight against SearXNG's JSON API (no Open WebUI, no model, a few seconds). Waits
    # for /healthz first: right after 'compose up' recreated the container (a SearXNG update) the
    # port is already open while SearXNG is still starting, and a search then would fail a working update.
    # A refused connection (nothing listens: the container is not running) ends the wait after
    # -RefusedSec instead of the full -WaitSec.
    param([string]$BaseUrl = 'http://127.0.0.1:8888', [string]$Query = 'Ollama release notes', [int]$TimeoutSec = 30,
        [int]$WaitSec = 60, [int]$RefusedSec = 10)
    if ($WaitSec -gt 0) {
        $deadline = (Get-Date).AddSeconds($WaitSec)
        $refusedEnd = (Get-Date).AddSeconds([Math]::Min($RefusedSec, $WaitSec))
        while ($true) {
            try { Invoke-LaiApi -Uri "$BaseUrl/healthz" -TimeoutSec 10 | Out-Null; break }
            catch {
                $now = Get-Date
                if (($now -ge $refusedEnd -and (Test-LaiConnectionRefused $_)) -or $now -ge $deadline) {
                    throw "SearXNG at $BaseUrl is not answering ($(Get-LaiHttpErrorText $_))"
                }
            }
            Start-Sleep -Seconds 2
        }
    }
    $r = Invoke-LaiApi -Uri ("$BaseUrl/search?format=json&q=" + [uri]::EscapeDataString($Query)) -TimeoutSec $TimeoutSec
    if ($null -eq $r -or $r -is [string]) { throw "SearXNG at $BaseUrl did not answer with JSON (its settings.yml must list json under search: formats:)" }
    return (ConvertTo-LaiSearxngDiagnosis -Response $r)
}

#endregion

#region Skills (<AIRoot>\Skills -> Open WebUI Skills) and the skill notebook (drafts the model writes) ---

# Folder skills carry this tag: the sync only ever changes or switches off skills it made itself.
$script:LaiFolderSkillTag = 'localai-folder'
# Drafts the skill notebook tool writes carry this one (it never touches any other skill).
$script:LaiLearnedSkillTag = 'learned'
# A folder skill the sync switched off because its folder went away (on again when it returns).
$script:LaiRemovedSkillTag = 'localai-removed'

function ConvertFrom-LaiSkillFile {
    <#
    .SYNOPSIS
        Reads one SKILL.md in the Agent Skills layout: YAML front matter with name and description,
        then the instructions. The id is the folder name, reduced to what Open WebUI ids allow.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $folder = Split-Path -Leaf (Split-Path -Parent $Path)
    $id = ConvertTo-LaiSkillId $folder
    $name = $folder; $desc = ''; $body = $text
    # Front matter between two '---' lines (it may be empty: '---' right after '---').
    $fm = [regex]::Match($text, '(?s)\A\s*---[ \t]*\r?\n(?:(.*?)\r?\n)?---[ \t]*(\r?\n|\z)(.*)\z')
    if ($fm.Success) {
        $body = $fm.Groups[3].Value
        $lines = @($fm.Groups[1].Value -split '\r?\n')
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $kv = [regex]::Match($lines[$i], '^(name|description)\s*:\s*(.*?)\s*$')
            if (-not $kv.Success) { continue }
            $key = $kv.Groups[1].Value; $val = $kv.Groups[2].Value
            # Indented lines below are part of the value: a block ('>' or '|', with optional +/- and
            # indent digit, blank lines allowed inside) or a plain value continued on the next lines.
            $block = $val -match '^[>|][+-]?[0-9]?[+-]?$'
            if ($block -or $val -notmatch '^["'']') {
                $more = @(); if (-not $block -and $val) { $more += $val }
                while ($i + 1 -lt $lines.Count -and ($lines[$i + 1] -match '^\s+\S' -or ($block -and $lines[$i + 1] -match '^\s*$'))) {
                    $i++; if ($lines[$i].Trim()) { $more += $lines[$i].Trim() }
                }
                $val = $more -join ' '
                if (-not $block) { $val = $val -replace '\s+#.*\z', '' }   # a trailing comment on a plain value
            }
            $val = $val.Trim()
            if ($val -match '^("(?:[^"\\]|\\.)*"|''(?:[^'']|'''')*'')\s+#') { $val = $Matches[1] }
            if ($val -match '^"(.*)"$') { $val = $Matches[1] -replace '\\"', '"' }
            elseif ($val -match "^'(.*)'$") { $val = $Matches[1] -replace "''", "'" }
            if ($key -eq 'name' -and $val) { $name = $val } elseif ($key -eq 'description') { $desc = $val }
        }
    }
    return [pscustomobject]@{ Id = $id; Name = $name; Description = $desc; Content = $body.Trim() }
}

function Get-LaiWebUISkills {
    # Every skill with its content (admin), keyed by id.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token)
    $all = @{}
    foreach ($sk in @(Invoke-LaiApi -Uri "$BaseUrl/api/v1/skills/export" -Token $Token | ForEach-Object { $_ })) {
        if ($sk -and $sk.PSObject.Properties['id']) { $all[[string]$sk.id] = $sk }
    }
    return $all
}

function Test-LaiSkillTag($Skill, [string]$Tag) {
    if (-not $Skill -or -not $Skill.PSObject.Properties['meta'] -or -not $Skill.meta) { return $false }
    if (-not $Skill.meta.PSObject.Properties['tags']) { return $false }
    return (@($Skill.meta.tags) -contains $Tag)
}

function ConvertTo-LaiSkillId([string]$FolderName) {
    # A folder name reduced to what Open WebUI skill ids allow ('' when nothing is left).
    return ($FolderName.ToLowerInvariant() -replace '[^a-z0-9_-]+', '-').Trim('-')
}

function Get-LaiSkillMetaForm($Existing, [string[]]$AddTags = @(), [string[]]$RemoveTags = @()) {
    # The skill's current meta (tags, translations) with tags added or removed: a sync never drops
    # what you added in Open WebUI.
    $meta = @{}
    if ($Existing -and $Existing.PSObject.Properties['meta'] -and $Existing.meta) { $meta = ConvertTo-LaiHashtable $Existing.meta }
    $tags = @()
    if ($meta.ContainsKey('tags') -and $meta['tags']) { $tags = @($meta['tags'] | ForEach-Object { [string]$_ } | Where-Object { $RemoveTags -notcontains $_ }) }
    foreach ($t in $AddTags) { if ($tags -notcontains $t) { $tags += $t } }
    $meta['tags'] = [object[]]$tags
    return $meta
}

function Sync-LaiWebUISkills {
    <#
    .SYNOPSIS
        Makes Open WebUI's skills match <AIRoot>\Skills: one skill per <folder>\SKILL.md, created or
        updated in place, switched off when its folder is gone and back on when it returns. Skills made
        in Open WebUI itself and the notebook's drafts are never changed. A skill you switched off in
        Open WebUI stays off. A SKILL.md with a problem is reported and its last synced version kept.
        Returns Created/Updated/Restored/Replaced/Disabled/Skipped and the ids now active.
    #>
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Folder)
    $result = [pscustomobject]@{ Created = @(); Updated = @(); Restored = @(); Replaced = @(); Disabled = @(); Skipped = @(); ActiveIds = @() }
    $existing = Get-LaiWebUISkills -BaseUrl $BaseUrl -Token $Token
    $seen = @()     # ids the folder accounts for, including ones skipped for a problem (left as they are)
    $wanted = @()
    $files = @()
    if (Test-Path -LiteralPath $Folder) {
        $files = @(Get-ChildItem -LiteralPath $Folder -Directory -ErrorAction SilentlyContinue | Sort-Object Name |  # lai-ok: objects
            ForEach-Object { Join-Path $_.FullName 'SKILL.md' } | Where-Object { Test-Path -LiteralPath $_ })
    }
    foreach ($f in $files) {
        $folderName = Split-Path -Leaf (Split-Path -Parent $f)
        $id = ConvertTo-LaiSkillId $folderName
        if (-not $id) { $result.Skipped += "$folderName has no letters or digits to make an id from; rename the folder"; continue }
        if ($seen -contains $id) { $result.Skipped += "$folderName gives the id '$id', which another folder already uses; rename one of them"; continue }
        $seen += $id
        if ((Get-Item -LiteralPath $f).Length -gt 102400) { $result.Skipped += "$folderName\SKILL.md is over 100 KB (each chat that uses it would carry all of it); the last synced version stays"; continue }
        $sk = ConvertFrom-LaiSkillFile -Path $f
        if (-not $sk.Content) { $result.Skipped += "$folderName\SKILL.md has no instructions after its front matter; the last synced version stays"; continue }
        $e = $null; if ($existing.ContainsKey($id)) { $e = $existing[$id] }
        if ($e -and -not (Test-LaiSkillTag $e $script:LaiFolderSkillTag)) {
            $result.Skipped += "'$id' already exists in Open WebUI (made there or by the notebook); rename the folder $folderName to keep both"
            continue
        }
        if ($e -and $e.is_active) { $result.ActiveIds += $id }   # kept even if its update below fails
        $wanted += [pscustomobject]@{ Skill = $sk; Existing = $e }
    }
    # Folder skills whose folder is gone. One whose name a new folder uses (a renamed folder) is
    # deleted first: names are unique in Open WebUI, so it would block the new one for good.
    $orphans = @($existing.Keys | Where-Object { (Test-LaiSkillTag $existing[$_] $script:LaiFolderSkillTag) -and $seen -notcontains $_ })
    foreach ($w in @($wanted | Where-Object { -not $_.Existing })) {
        foreach ($oid in @($orphans | Where-Object { [string]$existing[$_].name -ceq $w.Skill.Name })) {
            try {
                Invoke-LaiApi -Method DELETE -Uri "$BaseUrl/api/v1/skills/id/$oid/delete" -Token $Token | Out-Null
                $result.Replaced += "$oid -> $($w.Skill.Id)"
                $orphans = @($orphans | Where-Object { $_ -ne $oid })
            } catch { $result.Skipped += "'$oid' (folder gone) could not be removed: $((Get-LaiHttpErrorText $_) -replace '\s+', ' ')" }
        }
    }
    foreach ($w in $wanted) {
        $sk = $w.Skill; $e = $w.Existing
        try {
            if (-not $e) {
                $form = @{ id = $sk.Id; name = $sk.Name; description = $sk.Description; content = $sk.Content; meta = @{ tags = @($script:LaiFolderSkillTag) }; is_active = $true }
                Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/skills/create" -Body $form -Token $Token | Out-Null
                $result.Created += $sk.Id
                $result.ActiveIds += $sk.Id
                continue
            }
            # Back on only if the sync itself switched it off when the folder went away.
            $back = Test-LaiSkillTag $e $script:LaiRemovedSkillTag
            $changed = [string]$e.content -cne $sk.Content -or [string]$e.name -cne $sk.Name -or [string]$e.description -cne $sk.Description
            if (-not ($back -or $changed)) { continue }
            $form = @{ id = $sk.Id; name = $sk.Name; description = $sk.Description; content = $sk.Content
                meta = (Get-LaiSkillMetaForm $e -AddTags @($script:LaiFolderSkillTag) -RemoveTags @($script:LaiRemovedSkillTag))
                is_active = ([bool]$e.is_active -or $back) }   # an update form without it would switch the skill on
            Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/skills/id/$($sk.Id)/update" -Body $form -Token $Token | Out-Null
            if ($back) { $result.Restored += $sk.Id; if ($result.ActiveIds -notcontains $sk.Id) { $result.ActiveIds += $sk.Id } }
            else { $result.Updated += $sk.Id }
        } catch {
            # Most often: another skill already has this name (names are unique in Open WebUI).
            $result.Skipped += "'$($sk.Id)': $((Get-LaiHttpErrorText $_) -replace '\s+', ' ')"
        }
    }
    foreach ($oid in $orphans) {
        $e = $existing[$oid]
        if (-not $e.is_active -or (Test-LaiSkillTag $e $script:LaiRemovedSkillTag)) { continue }   # already off: yours or ours
        # Switched off with an update, not a toggle (a toggle flips, so two syncs at once would switch
        # it back on); the tag lets a later sync switch it on again when the folder returns.
        $form = @{ id = $oid; name = [string]$e.name; description = [string]$e.description; content = [string]$e.content
            meta = (Get-LaiSkillMetaForm $e -AddTags @($script:LaiRemovedSkillTag)); is_active = $false }
        try {
            Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/skills/id/$oid/update" -Body $form -Token $Token | Out-Null
            $result.Disabled += $oid
        } catch { $result.Skipped += "'$oid' (folder gone) could not be switched off: $((Get-LaiHttpErrorText $_) -replace '\s+', ' ')" }
    }
    return $result
}

function Add-LaiPresetSkills {
    # Offers skills (and tools) in a preset; ids already there stay. Returns 'added', 'unchanged' or
    # 'legacy'. In native function calling Open WebUI 0.11.4 lists every active skill you can read to
    # the model anyway (it loads one with view_skill), so the attached list mainly keeps the preset's
    # own list in the model editor right. A legacy (prompt-based) preset instead gets the FULL text
    # of every attached skill in every message, which would crowd a small model's context: it gets
    # tools only, and the ids in -RemoveSkillIds (ours) are taken off it.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$PresetId,
        [string[]]$SkillIds = @(), [string[]]$ToolIds = @(), [string[]]$RemoveSkillIds = @())
    $existing = Get-LaiWebUIModel -BaseUrl $BaseUrl -Token $Token -Id $PresetId
    if (-not $existing) { return 'unchanged' }
    $form = ConvertTo-LaiHashtable $existing
    if (-not $form.ContainsKey('meta') -or $null -eq $form['meta']) { $form['meta'] = @{} }
    if ($null -eq $form['params']) { $form['params'] = @{} }
    $legacy = ($form['params'] -is [System.Collections.IDictionary] -and [string]$form['params']['function_calling'] -eq 'legacy')
    $changed = $false
    foreach ($pair in @(@{ Key = 'skillIds'; Add = $SkillIds }, @{ Key = 'toolIds'; Add = $ToolIds })) {
        $have = @(); if ($form['meta'].ContainsKey($pair.Key) -and $form['meta'][$pair.Key]) { $have = @($form['meta'][$pair.Key]) }
        if ($pair.Key -eq 'skillIds' -and $legacy) {
            $new = @($have | Where-Object { $RemoveSkillIds -notcontains $_ -and $SkillIds -notcontains $_ })
        } else {
            $new = @($have + @($pair.Add | Where-Object { $_ -and $have -notcontains $_ }))
        }
        if ($new.Count -ne $have.Count) { $form['meta'][$pair.Key] = [object[]]$new; $changed = $true }
    }
    if ($changed) {
        $form['id'] = $PresetId
        Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/models/model/update" -Body $form -Token $Token | Out-Null
    }
    if ($legacy) { return 'legacy' }
    if ($changed) { return 'added' }
    return 'unchanged'
}

function Invoke-LaiSkillSync {
    <#
    .SYNOPSIS
        The whole skills step, shared by Sync-LocalAISkills.ps1 and the installer: makes the folder (with
        the toolkit's starter skills) the first time, syncs it, and offers every active skill in the given
        presets. Returns the result of Sync-LaiWebUISkills plus Seeded and Attached.
    #>
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Folder,
        [string]$SeedFrom = '', [string[]]$PresetIds = @())
    $seeded = @()
    if (-not (Test-Path -LiteralPath $Folder)) {
        New-Item -ItemType Directory -Force -Path $Folder | Out-Null
        # Only when the folder does not exist yet: skills you deleted from it are not brought back.
        if ($SeedFrom -and (Test-Path -LiteralPath $SeedFrom)) {
            foreach ($d in @(Get-ChildItem -LiteralPath $SeedFrom -Directory)) {
                Copy-Item -LiteralPath $d.FullName -Destination (Join-Path $Folder $d.Name) -Recurse -Force
                $seeded += $d.Name
            }
        }
    }
    $r = Sync-LaiWebUISkills -BaseUrl $BaseUrl -Token $Token -Folder $Folder
    $attached = @(); $legacy = @()
    # Ours: folder skills and the notebook's learned ones (taken off legacy presets).
    $ours = @()
    $after = Get-LaiWebUISkills -BaseUrl $BaseUrl -Token $Token
    foreach ($k in @($after.Keys)) { if ((Test-LaiSkillTag $after[$k] $script:LaiFolderSkillTag) -or (Test-LaiSkillTag $after[$k] $script:LaiLearnedSkillTag)) { $ours += $k } }
    foreach ($presetId in $PresetIds) {
        switch (Add-LaiPresetSkills -BaseUrl $BaseUrl -Token $Token -PresetId $presetId -SkillIds @($r.ActiveIds) -RemoveSkillIds $ours) {
            'added' { $attached += $presetId }
            'legacy' { $legacy += $presetId }
        }
    }
    $r | Add-Member -NotePropertyName Seeded -NotePropertyValue $seeded
    $r | Add-Member -NotePropertyName Attached -NotePropertyValue $attached
    $r | Add-Member -NotePropertyName Legacy -NotePropertyValue $legacy
    return $r
}

function Set-LaiWebUITool {
    # Creates or updates a workspace tool from Python source (admin). Returns 'created' / 'updated' / 'unchanged'.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Content, [string]$Description = '')
    $current = $null
    try { $current = Invoke-LaiApi -Uri "$BaseUrl/api/v1/tools/id/$Id" -Token $Token } catch { if ((Get-LaiHttpStatus $_) -notin 401, 404) { throw } }
    $form = @{ id = $Id; name = $Name; content = $Content; meta = @{ description = $Description; manifest = @{} } }
    if (-not $current) {
        Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/tools/create" -Body $form -Token $Token | Out-Null
        return 'created'
    }
    $curDesc = ''; if ($current.PSObject.Properties['meta'] -and $current.meta -and $current.meta.PSObject.Properties['description']) { $curDesc = [string]$current.meta.description }
    if ([string]$current.content -ceq $Content -and [string]$current.name -ceq $Name -and $curDesc -ceq $Description) { return 'unchanged' }
    Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/tools/id/$Id/update" -Body $form -Token $Token | Out-Null
    return 'updated'
}

#endregion

#region Deep research (Local Deep Research, optional: Install-LocalAI.ps1 -DeepResearch) ---------

function Get-LaiDeepResearchEnv {
    <#
    .SYNOPSIS
        The Stack\.env values for the optional deep-research service. Off: COMPOSE_PROFILES is empty,
        so docker compose never starts it. On: it uses the preset's tuned context, because a num_ctx
        that differs from the alias makes Ollama reload the model (and fit it differently) on every call.
    #>
    # -Thinking: only for a model whose Ollama capabilities include 'thinking'. Local Deep Research
    # asks for thinking by default, and Ollama answers any other model with 400 'does not support
    # thinking', so every research run with an Instruct model would fail.
    param([bool]$Enabled, [string]$Model = 'localai-main:latest', [int]$Context = 32768, [int]$Port = 5055, [bool]$AllowRegistrations = $true,
        [bool]$Thinking = $false, [string]$OllamaUrl = 'http://render-guard:11434')
    # With its tag: its model list compares names exactly with Ollama's ('x:latest').
    if ($Model -notmatch ':[^/]+$') { $Model += ':latest' }
    $profiles = ''; if ($Enabled) { $profiles = 'research' }
    $allow = 'false'; if ($AllowRegistrations) { $allow = 'true' }
    $think = 'false'; if ($Thinking) { $think = 'true' }
    return @{
        COMPOSE_PROFILES                  = $profiles
        DEEP_RESEARCH_PORT                = [string]$Port
        DEEP_RESEARCH_MODEL               = $Model
        DEEP_RESEARCH_CONTEXT             = [string]$Context
        DEEP_RESEARCH_ALLOW_REGISTRATIONS = $allow
        DEEP_RESEARCH_THINKING            = $think
        DEEP_RESEARCH_OLLAMA_URL          = $OllamaUrl
    }
}

function New-LaiResearchSession {
    # An HTTP client with its own cookie jar and no automatic redirects: Local Deep Research answers a
    # good sign-up or sign-in with a redirect to '/', a refused one by showing the form again (200).
    # HttpClient behaves the same on Windows PowerShell 5.1 and PowerShell 7 (Invoke-WebRequest does
    # not: 5.1 has no -SkipHttpErrorCheck and throws on a redirect it may not follow).
    param([Parameter(Mandatory)][string]$BaseUrl, [int]$TimeoutSec = 30)
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.CookieContainer = New-Object System.Net.CookieContainer
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    return [pscustomobject]@{ BaseUrl = $BaseUrl.TrimEnd('/'); Client = $client }
}

function Invoke-LaiResearchRequest {
    # One request; returns status, redirect target and body (never throws for an HTTP status).
    param([Parameter(Mandatory)]$Session, [string]$Method = 'GET', [Parameter(Mandatory)][string]$Path,
        [hashtable]$Form, $Json, [string]$Csrf = '')
    $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), ($Session.BaseUrl + $Path))
    if ($Form) {
        $pairs = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
        foreach ($k in $Form.Keys) { $pairs.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]'([string]$k, [string]$Form[$k]))) }
        # ::new, not New-Object: New-Object would pass the list's items as separate arguments.
        $req.Content = [System.Net.Http.FormUrlEncodedContent]::new($pairs)
    } elseif ($null -ne $Json) {
        $req.Content = New-Object System.Net.Http.StringContent((ConvertTo-Json -InputObject $Json -Depth 10 -Compress), [Text.Encoding]::UTF8, 'application/json')
    }
    if ($Csrf) { [void]$req.Headers.TryAddWithoutValidation('X-CSRFToken', $Csrf) }
    # A .NET exception is only statement-terminating: without this catch, try/finally lets the
    # function carry on with no response (and the caller sees 'HTTP ' with nothing after it).
    try {
        $resp = $Session.Client.SendAsync($req).GetAwaiter().GetResult()
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $what = $e.Message
        if ($e -is [System.Threading.Tasks.TaskCanceledException] -or $e -is [System.TimeoutException]) { $what = "no answer within $([int]$Session.Client.Timeout.TotalSeconds) s" }
        throw "Local Deep Research at $($Session.BaseUrl) could not be reached ($what)."
    } finally { $req.Dispose() }
    $loc = ''; if ($resp.Headers.Location) { $loc = [string]$resp.Headers.Location }
    return [pscustomobject]@{ Status = [int]$resp.StatusCode; Location = $loc; Body = $body }
}

function Get-LaiResearchCsrf {
    param([Parameter(Mandatory)]$Session)
    $r = Invoke-LaiResearchRequest -Session $Session -Path '/auth/csrf-token'
    $t = ''
    if ($r.Status -eq 200) { try { $t = [string](ConvertFrom-Json -InputObject $r.Body).csrf_token } catch { $t = '' } }
    if (-not $t) { throw "Local Deep Research at $($Session.BaseUrl) gave no sign-in token (HTTP $($r.Status)); is it a different program on that port?" }
    return $t
}

function Get-LaiResearchFormError([string]$Html) {
    # The message a refused form shows (Flask flash), for a readable error.
    $m = [regex]::Match([string]$Html, '(?is)class="[^"]*(alert|flash|error)[^"]*"[^>]*>\s*([^<]{3,200})')
    if ($m.Success) { return ($m.Groups[2].Value -replace '\s+', ' ').Trim() }
    return ''
}

function Register-LaiResearchUser {
    # Creates the account (Local Deep Research keeps one encrypted database per account; there is no
    # headless way except its own sign-up form). Throws with the reason when it is refused.
    param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string]$Password)
    $s = New-LaiResearchSession -BaseUrl $BaseUrl -TimeoutSec 120
    try {
        $t = Get-LaiResearchCsrf $s
        $r = Invoke-LaiResearchRequest -Session $s -Method POST -Path '/auth/register' -Form @{
            username = $Account; password = $Password; confirm_password = $Password; acknowledge = 'true'; csrf_token = $t
        }
        if ($r.Status -ge 300 -and $r.Status -lt 400 -and $r.Location -notmatch '/auth/') { return }
        $why = Get-LaiResearchFormError $r.Body
        if (-not $why -and $r.Location -match '/auth/login') { $why = 'new accounts are turned off' }
        if (-not $why) { $why = "HTTP $($r.Status)" }
        throw "Local Deep Research did not create the account '$Account' ($why)."
    } finally { $s.Client.Dispose() }
}

function Connect-LaiResearch {
    # A signed-in session (check with /auth/check, not the redirect: both outcomes of a sign-in
    # redirect somewhere).
    param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string]$Password, [int]$TimeoutSec = 30)
    $s = New-LaiResearchSession -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec
    $t = Get-LaiResearchCsrf $s
    # The reason travels in Exception.Data['LaiKind'] (bad-password, locked, refused), so a caller
    # never mistakes a lock-out or an outage for a wrong password (and, say, makes a new account).
    $fail = {
        param($Kind, $Message)
        $s.Client.Dispose()
        $ex = New-Object System.Exception($Message)
        $ex.Data['LaiKind'] = $Kind
        throw $ex
    }
    $r = Invoke-LaiResearchRequest -Session $s -Method POST -Path '/auth/login' -Form @{ username = $Account; password = $Password; csrf_token = $t }
    if ($r.Status -eq 429) { & $fail 'locked' 'Local Deep Research refused the sign-in: too many sign-in attempts. Wait 15 minutes and try again.' }
    $chk = Invoke-LaiResearchRequest -Session $s -Path '/auth/check'
    if ($chk.Status -ne 200) {
        $why = Get-LaiResearchFormError $r.Body
        if ($why -match '(?i)locked|too many') { & $fail 'locked' "Local Deep Research refused the sign-in for '$Account' ($why). Wait 15 minutes and try again." }
        if ($why -match '(?i)invalid username or password') { & $fail 'bad-password' "Local Deep Research refused the sign-in for '$Account' ($why)." }
        if (-not $why) { $why = "HTTP $($r.Status)" }
        & $fail 'refused' "Local Deep Research refused the sign-in for '$Account' ($why)."
    }
    return $s
}

function Test-LaiResearchOllama {
    # Whether the research container reaches Ollama at the URL it is configured with (from inside
    # the container, the only place that address means anything). Local Deep Research's own model
    # check cannot tell: it ignores the configured URL and always asks localhost:11434.
    param([Parameter(Mandatory)][string]$OllamaUrl, [string]$Container = 'deep-research', [int]$TimeoutSec = 30)
    $py = "import sys,urllib.request as u;u.urlopen(sys.argv[1].rstrip('/')+'/api/tags',timeout=10).read();print('OK')"
    $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('exec', $Container, 'python3', '-c', $py, $OllamaUrl) -TimeoutSec $TimeoutSec
    if ($r.ExitCode -eq 0 -and [string]$r.Out -match 'OK') { return [pscustomobject]@{ Ok = $true; Message = $OllamaUrl } }
    $why = ([string]$r.Text -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
    if ($r.TimedOut) { $why = "no answer within $TimeoutSec s" }
    return [pscustomobject]@{ Ok = $false; Message = "$OllamaUrl not reachable from the $Container container ($([string]$why).Trim())" }
}

function Update-LaiDeepResearchContext {
    <#
    .SYNOPSIS
        After a re-tune (Update-Models.ps1): the research agent must ask for the alias's new context,
        or Ollama reloads the model every time research and chats take turns (and a context larger
        than the new one may no longer fit on the GPU). Rewrites DEEP_RESEARCH_CONTEXT in Stack\.env
        and recreates the container. Returns a line for the log, or '' when nothing changed.
    #>
    param([Parameter(Mandatory)][string]$AIRoot, [Parameter(Mandatory)][hashtable]$Tuning, [Parameter(Mandatory)][object[]]$Models)
    $stack = Join-Path $AIRoot 'Stack'
    $envPath = Join-Path $stack '.env'
    if (-not (Test-Path -LiteralPath $envPath)) { return '' }
    $lines = @(Get-Content -Encoding UTF8 -LiteralPath $envPath)
    $get = { param($n) $v = ''; foreach ($l in $lines) { if ($l -like "$n=*") { $v = $l.Substring($n.Length + 1) } }; $v }
    if ((& $get 'COMPOSE_PROFILES') -notmatch '(^|,)research(,|$)') { return '' }
    $alias = (& $get 'DEEP_RESEARCH_MODEL') -replace ':latest$', ''
    $m = @($Models | Where-Object { $_.Alias -eq $alias }) | Select-Object -First 1
    if (-not $m -or -not $Tuning.ContainsKey($m.Key) -or -not $Tuning[$m.Key]['Context']) { return '' }
    $want = [int]$Tuning[$m.Key]['Context']
    $have = 0; [void][int]::TryParse((& $get 'DEEP_RESEARCH_CONTEXT'), [ref]$have)
    if ($want -eq $have) { return '' }
    $out = foreach ($l in $lines) { if ($l -like 'DEEP_RESEARCH_CONTEXT=*') { "DEEP_RESEARCH_CONTEXT=$want" } else { $l } }
    [System.IO.File]::WriteAllLines($envPath, [string[]]$out, (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-LaiTimedNative -File 'docker' -Arguments @('compose', '--project-directory', $stack, '-f', (Join-Path $stack 'docker-compose.yml'), 'up', '-d', 'deep-research') -TimeoutSec 300
    if ($r.ExitCode -ne 0) { return "Deep research context set to $want tokens in Stack\.env (was $have), but restarting it failed: $(([string]$r.Text).Trim()). Run Start menu > Local AI > Start again." }
    return "Deep research now uses $want tokens of context (was $have), the same as $alias"
}

function Invoke-LaiResearchQuick {
    # One quick research run (search, read, summarise) through the API; Summary, Sources and Findings.
    # A run takes minutes, so give the session a long time limit (Connect-LaiResearch -TimeoutSec).
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Query, [int]$Iterations = 1)
    $t = Get-LaiResearchCsrf $Session
    $r = Invoke-LaiResearchRequest -Session $Session -Method POST -Path '/api/v1/quick_summary' -Csrf $t -Json @{
        query = $Query; search_tool = 'searxng'; iterations = $Iterations; questions_per_iteration = 1
    }
    $o = $null; try { $o = ConvertFrom-Json -InputObject $r.Body } catch { $o = $null }
    if ($r.Status -ne 200 -or -not $o) {
        $err = ''; if ($o -and $o.PSObject.Properties['error']) { $err = [string]$o.error }
        throw "Local Deep Research research run failed (HTTP $($r.Status)$(if ($err) { ': ' + $err }))."
    }
    return [pscustomobject]@{ Summary = [string]$o.summary; Sources = @($o.sources | Where-Object { $_ }).Count; Findings = @($o.findings | Where-Object { $_ }).Count }
}

#endregion

#region High-level setup (shared by the installer and the Linux integration harness) -----

function Get-LaiCatalog {
    # Loads config/models.psd1. -IncludeKeys filters to the models selected for this install;
    # without it, opt-in models (trials, official releases) are left out unless -IncludeTrials.
    param([Parameter(Mandatory)][string]$Path, [string[]]$IncludeKeys = @(), [switch]$IncludeTrials)
    $data = Import-PowerShellDataFile -Path $Path
    $models = @($data.Models)
    if ($IncludeKeys.Count -gt 0) { $models = @($models | Where-Object { $IncludeKeys -contains $_.Key }) }
    # Without a selection: no opt-in models (trials, official releases), which are only there once chosen.
    elseif (-not $IncludeTrials) { $models = @($models | Where-Object { -not ($_.Trial -or $_.Official) }) }
    # New chats start on the preferred preset (an official release) once it is installed.
    $default = $data.DefaultPreset
    if ($data.ContainsKey('PreferredDefaultPreset') -and @($models | Where-Object { $_.Preset -eq $data.PreferredDefaultPreset }).Count) { $default = $data.PreferredDefaultPreset }
    return [pscustomobject]@{
        DefaultPreset     = $default
        # The measured everyday preset (Uncensored Main): Test-LocalAI's functional checks run on it, so
        # they keep testing the same, well-known model whichever preset new chats start on.
        BaseDefaultPreset = $data.DefaultPreset
        ContextCandidates = @($data.ContextCandidates)
        Models            = $models
        AllModels         = @($data.Models)
    }
}

function Get-LaiModelSetupAdvice {
    # What to do after Update-Models could not set a model up. -Rollback only for a model this run
    # downloaded anew (-Changed): in the re-check after an Ollama update the files are the same, and
    # swapping in an older copy left from an earlier update would pin it without touching the cause.
    param([string]$Why, [string]$Display, [string]$Key, [switch]$Changed, [switch]$HasPrevious)
    $out = @()
    $what = "$Display's files"; if ($Changed) { $what = 'the new download' }
    if ($Why -match 'incompatible with your version|requires a newer version') {
        $out += "This Ollama cannot load ${what}: Update-Models.ps1 -UpdateOllama upgrades Ollama, and the next run then sets $Display up by itself."
    } elseif ($Why -match 'out of memory|cudaMalloc|CUDA error') {
        $out += "The GPU ran out of memory: close ComfyUI and other GPU programs, then run Update-Models.ps1 again."
    }
    if ($Changed -and $HasPrevious) { $out += "To go back to the version you had instead: Update-Models.ps1 -Rollback $Key" }
    elseif ($out.Count -eq 0) { $out += "Run Update-Models.ps1 again once the cause above is fixed; it retries $Display by itself." }
    return $out
}

function Invoke-LaiModelSetup {
    # For each catalog model: find the largest all-GPU context, create the tuned alias, confirm
    # placement at that context and measure generation speed. Previously tuned results are reused
    # when nothing relevant changed (same source tag, driver, KV cache type and VRAM reserve).
    param(
        [string]$BaseUrl = 'http://127.0.0.1:11434',
        [Parameter(Mandatory)][object[]]$Models,
        [Parameter(Mandatory)][int[]]$Candidates,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [hashtable]$Previous = @{},
        [string]$Fingerprint = '',
        [int]$MinFreeMiB = 768,
        [switch]$Retune,
        [switch]$AllowCpu,
        # Runs once, right before the first model is loaded (e.g. wait until the GPU is idle). A re-run
        # that reuses every tuning loads nothing, so it never waits on a busy GPU.
        [scriptblock]$BeforeFirstLoad = $null
    )
    $results = @{}
    $loadedOnce = $false
    $ollamaVer = ''
    try { $ollamaVer = [string](Get-LaiOllamaVersion -BaseUrl $BaseUrl) } catch { Write-Verbose 'version unknown' }
    foreach ($m in $Models) {
        Write-LaiLog STEP "Tuning $($m.Display) ($($m.Source))"
        $info = Get-LaiOllamaModelInfo -BaseUrl $BaseUrl -Name $m.Source
        $digest = Get-LaiOllamaDigest -BaseUrl $BaseUrl -Name $m.Source
        $prev = $null
        if ($Previous.ContainsKey($m.Key)) { $prev = $Previous[$m.Key] }
        # Results from before Digest/OllamaVersion were recorded still count (no forced re-tune).
        $sameModel = $prev -and (-not $prev['Digest'] -or $prev['Digest'] -eq $digest)
        $sameOllama = $prev -and $prev['OllamaVersion'] -and $prev['OllamaVersion'] -eq $ollamaVer
        # The candidate list counts too (an edited ContextCandidates must take effect); results from
        # before it was recorded still count.
        # Only the sizes this model may use, on both sides: a size added above a model's cap (and
        # the full lists recorded before this rule) must not re-tune it.
        $capList = { param($List) (@($List | ForEach-Object { [int]$_ } | Where-Object { [int]$m.MaxContext -le 0 -or $_ -le [int]$m.MaxContext } | Sort-Object -Descending -Unique) -join ',') }
        $candKey = & $capList $Candidates
        $sameCandidates = $prev -and (-not $prev['Candidates'] -or (& $capList @(([string]$prev['Candidates']) -split ',' | Where-Object { $_ })) -eq $candKey)
        $reuse = (-not $Retune) -and $prev -and ($prev['Source'] -eq $m.Source) -and ($prev['Fingerprint'] -eq $Fingerprint) -and
            ($prev['MaxContext'] -eq $m.MaxContext) -and $sameModel -and $sameCandidates -and (Test-LaiOllamaModel -BaseUrl $BaseUrl -Name $m.Alias)
        # A result that was slow or not fully on the GPU when measured is checked again, not trusted forever.
        $wasGood = $prev -and $prev['TokensPerSec'] -and $null -ne $prev['GpuPercent'] -and
            ($AllowCpu -or ([int]$prev['GpuPercent'] -ge 100 -and [double]$prev['TokensPerSec'] -ge [double]$m.MinTokensPerSec))
        # Skipping the load also needs the same Ollama: a new version can place layers differently.
        # (Results without a recorded version take the verify path once, which records it.)
        if ($reuse -and $sameOllama -and $wasGood) {
            # Nothing that decides the fit changed: refresh the alias (system prompt, parameters) and
            # keep the measured numbers. The acceptance test at the end measures speed again.
            $ctx = [int]$prev['Context']
            Set-LaiOllamaDerivedModel -BaseUrl $BaseUrl -Name $m.Alias -From $m.Source -NumCtx $ctx -Parameters $m.Parameters -System $SystemPrompt
            Write-LaiLog OK ("  {0}: reusing tuned context {1} ({2}% GPU, {3} tok/s when measured; -Retune measures again)" -f $m.Alias, $ctx, $prev['GpuPercent'], $prev['TokensPerSec'])
            $results[$m.Key] = $prev.Clone()
            $results[$m.Key]['Alias'] = $m.Alias
            $results[$m.Key]['Tools'] = ($info.Capabilities -contains 'tools')
            $results[$m.Key]['Vision'] = ($info.Capabilities -contains 'vision')
            $results[$m.Key]['Digest'] = $digest
            $results[$m.Key]['Reused'] = $true
            continue
        }
        if (-not $loadedOnce) { $loadedOnce = $true; if ($BeforeFirstLoad) { & $BeforeFirstLoad } }
        if ($reuse) {
            $ctx = [int]$prev['Context']
            Write-LaiLog INFO "  reusing tuned context $ctx (use -Retune to measure again)"
        } else {
            $fit = Find-LaiMaxContext -BaseUrl $BaseUrl -Name $m.Source -Candidates $Candidates -MaxContext $m.MaxContext -MinFreeMiB $MinFreeMiB -AllowCpu:$AllowCpu
            $ctx = $fit.Context
            if (-not $fit.Fits) { Write-LaiLog WARN "  even $ctx tokens does not fit fully in VRAM; expect slow generation (see README troubleshooting)" }
        }
        Set-LaiOllamaDerivedModel -BaseUrl $BaseUrl -Name $m.Alias -From $m.Source -NumCtx $ctx -Parameters $m.Parameters -System $SystemPrompt
        $load = Invoke-LaiOllamaLoad -BaseUrl $BaseUrl -Name $m.Alias -KeepAlive '2m'
        if ($reuse -and $load.GpuPercent -lt 100 -and -not $AllowCpu) {
            # The reused context no longer fits (new Ollama, other VRAM use): measure it again.
            Write-LaiLog WARN "  reused context $ctx is now only $($load.GpuPercent)% on the GPU; re-tuning"
            Stop-LaiOllamaModels -BaseUrl $BaseUrl
            $fit = Find-LaiMaxContext -BaseUrl $BaseUrl -Name $m.Source -Candidates $Candidates -MaxContext $m.MaxContext -MinFreeMiB $MinFreeMiB -AllowCpu:$AllowCpu
            $ctx = $fit.Context
            Set-LaiOllamaDerivedModel -BaseUrl $BaseUrl -Name $m.Alias -From $m.Source -NumCtx $ctx -Parameters $m.Parameters -System $SystemPrompt
            $load = Invoke-LaiOllamaLoad -BaseUrl $BaseUrl -Name $m.Alias -KeepAlive '2m'
        }
        $speed = Measure-LaiOllamaSpeed -BaseUrl $BaseUrl -Name $m.Alias
        Stop-LaiOllamaModels -BaseUrl $BaseUrl
        $level = 'OK'
        if ($load.GpuPercent -lt 100 -or $speed -lt $m.MinTokensPerSec) { $level = 'WARN' }
        if ($AllowCpu) { $level = 'OK' }
        Write-LaiLog $level ("  {0}: ctx {1} (trained {2}), {3}% GPU, {4} GiB, {5} tok/s" -f $m.Alias, $load.Context, $info.TrainContext, $load.GpuPercent, $load.SizeGiB, $speed)
        # The context the alias was built with, if /api/ps does not report one (older/newer Ollama).
        $finalCtx = [int]$load.Context
        if ($finalCtx -le 0) { $finalCtx = [int]$ctx }
        $results[$m.Key] = @{
            Source       = $m.Source
            Alias        = $m.Alias
            Context      = $finalCtx
            Candidates   = $candKey
            TrainContext = $info.TrainContext
            MaxContext   = $m.MaxContext
            GpuPercent   = $load.GpuPercent
            SizeGiB      = $load.SizeGiB
            TokensPerSec = $speed
            Tools        = ($info.Capabilities -contains 'tools')
            Vision       = ($info.Capabilities -contains 'vision')
            Fingerprint  = $Fingerprint
            Digest       = $digest
            OllamaVersion = $ollamaVer
            Reused       = $false
        }
    }
    return $results
}

function Compare-LaiConfig {
    <#
    .SYNOPSIS
        Lists the settings in $Expected that $Actual (what the API reads back) does not hold, one
        'KEY: wanted X, got Y' line each; nested hashtables are compared key by key ('web.KEY').
        Open WebUI answers a settings POST with 200 even when a newer version ignores a field, so
        a write is only trusted once it reads back.
    #>
    param([Parameter(Mandatory)][hashtable]$Expected, [AllowNull()]$Actual, [string]$Prefix = '')
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $a = ConvertTo-LaiHashtable $Actual
    $out = @()
    foreach ($k in @($Expected.Keys | Sort-Object)) {
        $name = $Prefix + $k
        $want = $Expected[$k]
        if (-not ($a -is [hashtable]) -or -not $a.ContainsKey($k)) { $out += "${name}: not returned"; continue }
        $got = $a[$k]
        if ($want -is [hashtable]) { $out += @(Compare-LaiConfig -Expected $want -Actual $got -Prefix "$name."); continue }
        # 5.1 reads a JSON 5.0 as [decimal] 5.0, which prints as '5.0': numbers compare as numbers.
        $num = { param($v) $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or $v -is [single] }
        if ((& $num $want) -and (& $num $got)) {
            if ([double]$want -ne [double]$got) { $out += "${name}: wanted $([Convert]::ToString($want, $inv)), got $([Convert]::ToString($got, $inv))" }
            continue
        }
        $w = if ($null -eq $want) { '' } else { [Convert]::ToString($want, $inv) }
        $g = if ($null -eq $got) { '' } else { [Convert]::ToString($got, $inv) }
        if (-not [string]::Equals($w, $g, [StringComparison]::OrdinalIgnoreCase)) {
            $shown = if ($null -eq $got) { 'nothing' } else { $g }
            $out += "${name}: wanted $w, got $shown"
        }
    }
    return $out
}

function Set-LaiWebUIAdminConfig {
    # GET -> merge -> POST, so settings this script does not manage are left untouched.
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][hashtable]$Changes)
    $cfg = ConvertTo-LaiHashtable (Invoke-LaiApi -Uri "$BaseUrl/api/v1/auths/admin/config" -Token $Token)
    foreach ($k in $Changes.Keys) { $cfg[$k] = $Changes[$k] }
    return Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/auths/admin/config" -Body $cfg -Token $Token
}

function Set-LaiWebUIModelsConfig {
    param(
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$DefaultModel,
        [string[]]$Order = @()
    )
    $cfg = ConvertTo-LaiHashtable (Invoke-LaiApi -Uri "$BaseUrl/api/v1/configs/models" -Token $Token)
    $cfg['DEFAULT_MODELS'] = $DefaultModel
    if ($Order.Count -gt 0) {
        # The presets first, then the order the user gave every other model (kept, not replaced).
        $rest = @()
        if ($cfg.ContainsKey('MODEL_ORDER_LIST') -and $cfg['MODEL_ORDER_LIST']) { $rest = @($cfg['MODEL_ORDER_LIST'] | Where-Object { $Order -notcontains $_ }) }
        $cfg['MODEL_ORDER_LIST'] = @(@($Order) + $rest)
    }
    return Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/configs/models" -Body $cfg -Token $Token
}

# The tool categories of Open WebUI (meta.builtinTools) that are off in every preset of the toolkit,
# selected or not, and that every install or update switches off again: past chats, code, and the
# seven that write, schedule, send or start something (why each is off: New-LaiPresetForm). One
# list for the three that have to agree: the form of a new preset (New-LaiPresetForm), the judge of
# a preset as Open WebUI holds it (Get-LaiPresetToolRisk) and the form that makes a preset safe
# again (Protect-LaiPresetForm). image_generation is off in a new preset as well, but it is the
# owner's to switch on, so it is not in this list.
$script:LaiPresetToolsOff = @('chats', 'code_interpreter', 'notes', 'tasks', 'automations', 'calendar', 'notifications', 'channels', 'subagents')

function New-LaiPresetForm {
    # Open WebUI workspace model ("preset") on top of a tuned Ollama alias.
    param([Parameter(Mandatory)][hashtable]$Entry, [Parameter(Mandatory)][bool]$NativeTools, [Parameter(Mandatory)][string]$SystemPrompt)
    $params = @{ system = $SystemPrompt }
    if ($NativeTools) { $params['function_calling'] = 'native' } else { $params['function_calling'] = 'legacy' }
    if ($Entry.Think -eq $false) { $params['think'] = $false }
    # The 16 tool switches (the comment in $meta below says which is which, and why): seven written
    # here, and the nine of the shared list, off.
    $tools = @{ time = $true; user_input = $true; knowledge = $true; files = $true; web_search = $true; memory = $true; image_generation = $false }
    foreach ($off in $script:LaiPresetToolsOff) { $tools[$off] = $false }
    $meta = @{
        description       = $Entry.Description
        profile_image_url = '/static/favicon.png'
        capabilities      = @{
            vision = [bool]$Entry.Vision; file_upload = $true; file_context = $true; web_search = $true
            image_generation = $false; code_interpreter = $false; terminal = $false
            citations = $true; status_updates = $true; memory = $true; builtin_tools = $true
        }
        # Every tool category Open WebUI has gets a switch that is written out, true or false: it
        # takes a MISSING one for ON, so a category left out here is one the model may use without
        # asking, in a turn that holds a web page's text too. The 16 names are those of Open WebUI
        # v0.11.4, the version the toolkit pins (its model editor, BuiltinTools.svelte, and
        # get_builtin_tools in backend/open_webui/utils/tools.py, as read from its source on
        # 2026-10-08). tests/Invoke-IntegrationTest.ps1 compares this list, in both directions, with
        # the names the installed Open WebUI's own code asks for (on the Linux job): a name spelt
        # differently there would be a switch that does nothing, and its tools would stay on.
        # A category a newer Open WebUI adds is not in this list and is on there until it is added
        # here; that comparison fails when the pinned version has one.
        #   on   time, user_input (the model asks you a question), knowledge and files (it reads
        #        attached collections and the files of the chat), web_search (search_web, fetch_url)
        #        and memory, which reads AND writes: add_memory, update_memory,
        #        replace_memory_content, delete_memory. Saving what you tell it is what it is for.
        #   off  chats: with it the model can search and read every past chat, and a web page or
        #        document it reads could tell it to put what it finds into a URL it fetches
        #        (fetch_url reaches any public site, without asking).
        #        code_interpreter (it runs code) and image_generation (yours to switch on).
        #        notes, tasks, automations, calendar, notifications, subagents: each can write,
        #        schedule, send or start something (write_note, create_tasks, create_automation,
        #        create_calendar_event, notify, delegate_task ...). The owner decided on 2026-10-07
        #        that none of that is on in any preset. channels: it only reads Open WebUI's
        #        channels, which the toolkit has no use for.
        # Re-runs put every 'off' back, all but image_generation, and leave that one, user_input
        # and files as the owner set them, also when the owner's 'on' is a switch that is no longer
        # there (Merge-LaiPresetForm). Three things no switch here covers: view_skill (offered
        # whenever the preset has skills), the terminal tools (the toolkit connects no terminal),
        # and a chat opened from a note, which gets the note tools whatever 'notes' says. And the
        # switches are about Open WebUI's built-in tools only: a tool attached to the preset is
        # called without asking as well (the installer attaches one, the skill notebook, which
        # saves a skill draft that stays off until the owner switches it on).
        builtinTools      = $tools
        tags              = @(@{ name = 'local' })
    }
    # No 'hidden' here: a preset the owner hid stays hidden. The installer shows a trial or official
    # preset again only when it hid it itself (Show-LaiWebUIModel).
    # Native tool calling lets the model decide when to search. In legacy (prompt-based) mode a
    # default-on web search would run a search before every single message, so leave it off there.
    # The uncensored presets search only when you switch Search on for the chat: they have no refusal
    # training, so they are the ones a planted instruction in a page most easily steers.
    if ($NativeTools -and $Entry.Official) { $meta['defaultFeatureIds'] = @('web_search') }
    else { $meta['defaultFeatureIds'] = @() }
    return @{
        id            = $Entry.Preset
        base_model_id = "$($Entry.Alias):latest"
        name          = $Entry.Display
        meta          = $meta
        params        = $params
        access_grants = @()
        is_active     = $true
    }
}

function Get-LaiPresetToolRisk {
    # What a preset lets the assistant do that the toolkit switches off in every preset, from the
    # preset's meta as Open WebUI returns it (an object, or the same as a table): 'read past chats',
    # 'run code', and one entry that names the writing tools that are on ('use its notes, tasks
    # tools'). Nothing = safe. Pure: it reads its argument and the shared list above and calls
    # nothing (tests\Invoke-WindowsUnitTests.ps1 holds it to that).
    # Open WebUI takes a missing tool category for ON, so a switch counts as off only when it is
    # written out as the boolean false under its exact name, letter case included: Open WebUI reads
    # 'chats' and never 'Chats', while PowerShell's own $tools.chats reads either and would call a
    # preset safe that is not. A switch that is missing, null, true, a text or spelt another way
    # counts as on, and so does every switch of a set (builtinTools, capabilities) that is not
    # there under its exact name. Code execution has two switches and counts as on when either does.
    # Exact means character for character. The names are held against a pattern that begins with
    # \A and ends with \z (-cmatch, -cnotmatch), never with -ceq, -cne or -ccontains: those go by
    # the rules of a language, for which 'chats' followed by a soft hyphen (U+00AD), by a
    # zero-width joiner or by a NUL is the same word as 'chats'. Open WebUI reads the exact key,
    # finds none under such a name and takes the switch for on. (The names of the shared list are
    # letters and underscores, so they are their own pattern.)
    param($Meta)
    # For each of the two sets, the names in it that are written out as false.
    $off = @{ builtinTools = @(); capabilities = @() }
    $sets = @()
    if ($Meta -is [System.Collections.IDictionary]) { foreach ($k in @($Meta.PSBase.Keys)) { $sets += , @([string]$k, $Meta[$k]) } }
    elseif ($null -ne $Meta) { foreach ($p in $Meta.PSObject.Properties) { $sets += , @([string]$p.Name, $p.Value) } }
    foreach ($set in $sets) {
        $setName = $set[0]; $switches = $set[1]
        if ($setName -cnotmatch '\A(builtinTools|capabilities)\z') { continue }
        $names = @()
        if ($switches -is [System.Collections.IDictionary]) {
            foreach ($k in @($switches.PSBase.Keys)) { if ($switches[$k] -is [bool] -and -not $switches[$k]) { $names += [string]$k } }
        } elseif ($null -ne $switches) {
            foreach ($p in $switches.PSObject.Properties) { if ($p.Value -is [bool] -and -not $p.Value) { $names += [string]$p.Name } }
        }
        $off[$setName] = $names
    }
    $risks = @()
    if (@(@($off['builtinTools']) -cmatch '\Achats\z').Count -eq 0) { $risks += 'read past chats' }
    if (@(@($off['builtinTools']) -cmatch '\Acode_interpreter\z').Count -eq 0 -or @(@($off['capabilities']) -cmatch '\Acode_interpreter\z').Count -eq 0) { $risks += 'run code' }
    $writing = @()
    foreach ($name in $script:LaiPresetToolsOff) {
        if ($name -ceq 'chats' -or $name -ceq 'code_interpreter') { continue }
        if (@(@($off['builtinTools']) -cmatch ('\A' + $name + '\z')).Count -eq 0) { $writing += $name }
    }
    if ($writing.Count -gt 0) { $risks += ('use its ' + ($writing -join ', ') + ' tools') }
    return $risks
}

function Protect-LaiPresetForm {
    # A preset as Open WebUI returned it, made safe: the form to send back. Past chats, both code
    # switches and the seven writing tools are written out as false under their exact names, and
    # no feature is on by default for every chat, unless the preset is one of the official releases
    # (-Official: those search the web by default, the others only when asked). Everything else
    # is kept as it was found: name, base model, system prompt and parameters, who may use the
    # preset, whether it is active or hidden, the owner's picture tool, what is attached to it,
    # and every other switch.
    # Pure: a copy is changed and returned, the argument is not, and Open WebUI is not asked.
    # A switch under a look-alike name ('Chats') is taken out before the exact one is written: a
    # PowerShell table finds 'Chats' when it is asked for 'chats' and would keep that spelling,
    # which Open WebUI does not read. The same goes for the two sets and for defaultFeatureIds.
    param([Parameter(Mandatory)]$Existing, [switch]$Official)
    $form = ConvertTo-LaiHashtable $Existing
    if ($form -isnot [hashtable]) { throw 'Open WebUI did not return the preset as an object, so it cannot be changed' }
    $meta = $form['meta']; $form.Remove('meta')
    if ($meta -isnot [hashtable]) { $meta = @{} }
    $form['meta'] = $meta
    foreach ($set in 'builtinTools', 'capabilities') {
        $switches = $meta[$set]; $meta.Remove($set)
        if ($switches -isnot [hashtable]) { $switches = @{} }
        $meta[$set] = $switches
    }
    foreach ($name in $script:LaiPresetToolsOff) { $meta['builtinTools'].Remove($name); $meta['builtinTools'][$name] = $false }
    $meta['capabilities'].Remove('code_interpreter'); $meta['capabilities']['code_interpreter'] = $false
    if (-not $Official) { $meta.Remove('defaultFeatureIds'); $meta['defaultFeatureIds'] = @() }
    return $form
}

function Invoke-LaiPresetSafety {
    # Holds the toolkit's presets safe, every one that is in Open WebUI, selected or not. A preset
    # that is no longer selected (Vision or Code skipped later, a trial that was dropped, official
    # models left out) is hidden at most and never deleted: old chats use it, and a new chat can
    # be started on it. -Entries: catalog entries (Get-LaiCatalog -IncludeTrials has all of them).
    # For each one whose preset is there: what it lets the assistant do (Get-LaiPresetToolRisk),
    # and on a preset that is not an official one what is on by default for every chat. When there
    # is anything, the safe form is written (Protect-LaiPresetForm), read back and judged again.
    # A preset that is not in Open WebUI is passed over: nothing is created (Set-LaiWebUIModel
    # would). A write that fails, or that Open WebUI does not keep, is an error: this never reports
    # a preset as safe that is still open. -ReadOnly judges and writes nothing.
    # Returns one object for each preset found: Key, Preset, Display, On (what the assistant could
    # do there, in words; empty = it was safe already) and Written.
    param(
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries,
        [switch]$ReadOnly
    )
    $found = @(); $seen = @()
    foreach ($m in $Entries) {
        $id = [string]$m.Preset
        # Each id once, held against the ones before it character for character (IndexOf), not
        # with -ccontains: for that an id with a soft hyphen in it is the id without, and an entry
        # under such a name, listed first, would take the real preset out of this walk.
        if (-not $id -or [array]::IndexOf($seen, $id) -ge 0) { continue }
        $seen += $id
        $existing = Get-LaiWebUIModel -BaseUrl $BaseUrl -Token $Token -Id $id
        if (-not $existing) { continue }
        $official = [bool]$m.Official
        # What a preset as Open WebUI holds it leaves open: asked before the write and again after it.
        $openIn = { param($Preset)
            $open = @(Get-LaiPresetToolRisk $Preset.meta)
            if (-not $official -and $Preset.meta) {
                $auto = @($Preset.meta.defaultFeatureIds | Where-Object { $_ })
                if ($auto.Count -gt 0) { $open += ('use ' + ($auto -join ', ') + ' in every chat without being asked') }
            }
            $open
        }
        $on = @(& $openIn $existing)
        $written = $false
        if (-not $ReadOnly -and $on.Count -gt 0) {
            $byHand = "Run the installer again (Start menu > Local AI - Update toolkit). If this stays, switch that off by hand in Open WebUI: Workspace > Models > $($m.Display)"
            try {
                $form = Protect-LaiPresetForm -Existing $existing -Official:$official
                # The update takes the preset by its id and refuses a form without parameters.
                $form['id'] = $id
                if ($null -eq $form['params']) { $form['params'] = @{} }
                Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/models/model/update" -Body $form -Token $Token | Out-Null
            } catch { throw "The safety settings of the preset '$($m.Display)' could not be written to Open WebUI ($(Get-LaiHttpErrorText $_)): the assistant can still $($on -join ' and ') there. $byHand" }
            $after = Get-LaiWebUIModel -BaseUrl $BaseUrl -Token $Token -Id $id
            if (-not $after) { throw "The preset '$($m.Display)' was not in Open WebUI any more when its safety settings were read back, so they were not checked. $byHand" }
            $left = @(& $openIn $after)
            if ($left.Count -gt 0) { throw "Open WebUI did not keep the safety settings of the preset '$($m.Display)': the assistant can still $($left -join ' and ') there. $byHand" }
            $written = $true
        }
        $found += [pscustomobject]@{ Key = [string]$m.Key; Preset = $id; Display = [string]$m.Display; On = $on; Written = $written }
    }
    return $found
}

function Get-LaiRagWanted {
    # The documents (RAG), image upload and web search settings the installer writes and reads back;
    # Test-LocalAI compares the live ones with the same list.
    param([string]$SearxngQueryUrl = 'http://searxng:8080/search?q=<query>')
    return @{
        TEXT_SPLITTER                        = 'token'
        ENABLE_MARKDOWN_HEADER_TEXT_SPLITTER = $true
        # 1,000-token chunks (whole ones fit the embedder), 10 candidates from keywords + meaning,
        # the best 5 kept (re-scored by the reranker when it is set, else by similarity).
        CHUNK_SIZE                           = 1000
        CHUNK_OVERLAP                        = 100
        TOP_K                                = 10
        ENABLE_RAG_HYBRID_SEARCH             = $true
        TOP_K_RERANKER                       = 5
        # The browser scales an attached image to fit 1920x1920 before sending it. Every image in a
        # chat is sent again with each message, and a full-size photo costs up to 4,096 of Local
        # Vision's 32K tokens (llama.cpp's Qwen-VL cap): unscaled, a chat with about seven photos no
        # longer fits. 1920 leaves 1080p screenshots untouched (readable text) and shrinks a phone
        # photo to about 2,700 tokens.
        FILE_IMAGE_COMPRESSION_WIDTH         = 1920
        FILE_IMAGE_COMPRESSION_HEIGHT        = 1920
        web                                  = @{
            ENABLE_WEB_SEARCH            = $true
            WEB_SEARCH_ENGINE            = 'searxng'
            SEARXNG_QUERY_URL            = $SearxngQueryUrl
            WEB_SEARCH_RESULT_COUNT      = 5
            # A page or PDF the model opens with its fetch_url tool is cut to 32,000 characters
            # (about 8K tokens). Uncapped, one long page fills Fast's 40K or Vision's 32K context, and
            # Ollama then silently drops the oldest messages - the user's question first.
            WEB_FETCH_MAX_CONTENT_LENGTH = 32000
        }
    }
}

function Invoke-LaiWebUISetup {
    # Everything the guide does by clicking through Admin/Workspace settings (Parts 9-18).
    param(
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][object[]]$Models,
        [Parameter(Mandatory)][hashtable]$ModelResults,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$DefaultPreset,
        # The default is a model the owner picked (kept even if it is not one of these presets).
        [switch]$DefaultIsOwners,
        [string[]]$Collections = @(),
        [string]$SearxngQueryUrl = 'http://searxng:8080/search?q=<query>'
    )
    # Returns the optional steps that did not take, one line each (empty when all did). Signing up,
    # the presets and the model list are essential and throw; the RAG/web-search settings and the
    # knowledge collections are not: a failure there must not stop the install before the Backup
    # stage schedules the nightly backups, and a re-run retries them.
    $warnings = New-Object System.Collections.Generic.List[string]
    Write-LaiLog STEP 'Open WebUI: admin settings (signup off, memories on, community sharing off)'
    $adminWanted = @{ ENABLE_SIGNUP = $false; ENABLE_MEMORIES = $true; ENABLE_MEMORY_SYSTEM_CONTEXT = $true; ENABLE_COMMUNITY_SHARING = $false }
    Set-LaiWebUIAdminConfig -BaseUrl $BaseUrl -Token $Token -Changes $adminWanted | Out-Null
    $adminBad = @(Compare-LaiConfig -Expected $adminWanted -Actual (Invoke-LaiApi -Uri "$BaseUrl/api/v1/auths/admin/config" -Token $Token))
    if (@($adminBad | Where-Object { $_ -like 'ENABLE_SIGNUP:*' }).Count -gt 0) {
        # Anyone who can reach the page could make an account: never carry on with that.
        throw "Open WebUI did not keep 'sign-up off' ($($adminBad -join '; ')). Turn it off in Admin Panel > Settings > General, then run the installer again."
    }
    foreach ($b in $adminBad) {
        $warnings.Add("Admin setting not kept ($b); set it in Admin Panel > Settings")
        Write-LaiLog WARN "Open WebUI did not keep an admin setting: $b"
    }

    Write-LaiLog STEP 'Open WebUI: waiting for the tuned Ollama models to be listed'
    $wanted = @($Models | ForEach-Object { "$($_.Alias):latest" })
    $deadline = (Get-Date).AddSeconds(120)
    do {
        $ids = Get-LaiWebUIModelIds -BaseUrl $BaseUrl -Token $Token
        $missing = @($wanted | Where-Object { $ids -notcontains $_ })
        if ($missing.Count -eq 0) { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    if ($missing.Count -gt 0) { throw "Open WebUI cannot see these Ollama models: $($missing -join ', '). Check the Ollama connection (Admin > Settings > Connections)." }
    Write-LaiLog OK "Open WebUI sees $($ids.Count) models from Ollama"

    foreach ($m in $Models) {
        $native = [bool]$ModelResults[$m.Key]['Tools']
        if (-not $native) { Write-LaiLog WARN "$($m.Source) has no native tool-calling template; $($m.Display) uses legacy (prompt-based) function calling" }
        # Image upload follows what Ollama says the download can do: a build without the image part
        # would turn every image into an error.
        $entry = $m
        $r = $ModelResults[$m.Key]
        if ($m.Vision -and $r -is [System.Collections.IDictionary] -and $r.Contains('Vision') -and -not $r['Vision']) {
            $entry = $m.Clone(); $entry['Vision'] = $false
            Write-LaiLog WARN "$($m.Source) cannot read images (Ollama reports no vision capability); image upload is off for $($m.Display)"
        }
        $form = Merge-LaiPresetForm -Managed (New-LaiPresetForm -Entry $entry -NativeTools $native -SystemPrompt $SystemPrompt) `
            -Existing (Get-LaiWebUIModel -BaseUrl $BaseUrl -Token $Token -Id $m.Preset)
        $action = Set-LaiWebUIModel -BaseUrl $BaseUrl -Token $Token -Model $form
        Write-LaiLog OK "Preset '$($m.Display)' $action (base $($m.Alias), function calling $(if ($native) { 'native' } else { 'legacy' }))"
    }

    # Hide raw and alias models so the selector shows exactly the presets.
    $hide = @()
    foreach ($m in $Models) { $hide += (Resolve-LaiModelName $m.Source); $hide += "$($m.Alias):latest" }
    foreach ($id in ($hide | Select-Object -Unique)) {
        if ($ids -contains $id) { Hide-LaiWebUIModel -BaseUrl $BaseUrl -Token $Token -Id $id | Out-Null }
    }
    $order = @($Models | Sort-Object { $_.Order } | ForEach-Object { $_.Preset })
    $default = $DefaultPreset
    if (-not $DefaultIsOwners -and -not ($Models | Where-Object { $_.Preset -eq $default })) { $default = $order[0] }
    Set-LaiWebUIModelsConfig -BaseUrl $BaseUrl -Token $Token -DefaultModel $default -Order $order | Out-Null
    Write-LaiLog OK "Raw models hidden; default model '$default'; selector order: $($order -join ', ')"

    Write-LaiLog STEP 'Open WebUI: documents (RAG) and web search settings'
    $ragWanted = Get-LaiRagWanted -SearxngQueryUrl $SearxngQueryUrl
    try {
        Set-LaiWebUIRetrievalConfig -BaseUrl $BaseUrl -Token $Token -Settings $ragWanted | Out-Null
        $rc = Get-LaiWebUIRetrievalConfig -BaseUrl $BaseUrl -Token $Token
        $ragBad = @(Compare-LaiConfig -Expected $ragWanted -Actual $rc)
        if ($ragBad.Count -gt 0) {
            $warnings.Add("Documents/web search settings not kept: $($ragBad -join '; '). Set them in Admin Panel > Settings > Documents and Web Search")
            Write-LaiLog WARN "Open WebUI did not keep these documents/web search settings: $($ragBad -join '; ')"
        } else {
            Write-LaiLog OK ("RAG: splitter={0}, chunk={1}/{2}, top_k={3}; web search={4} via {5}" -f $rc.TEXT_SPLITTER, $rc.CHUNK_SIZE, $rc.CHUNK_OVERLAP, $rc.TOP_K, $rc.web.ENABLE_WEB_SEARCH, $rc.web.WEB_SEARCH_ENGINE)
        }
    } catch {
        $why = $_.Exception.Message -replace '\s+', ' '
        $warnings.Add("Documents/web search settings failed ($why); run the installer again, or set them in Admin Panel > Settings > Documents and Web Search")
        Write-LaiLog WARN "Documents/web search settings failed: $why"
    }
    try {
        $emb = Set-LaiWebUIEmbedding -BaseUrl $BaseUrl -Token $Token
        if ($emb.Result -eq 'owner') { Write-LaiLog INFO "Document search keeps the embedding setup you chose ($($emb.Detail))" }
        elseif ($emb.Result -eq 'unchanged' -and -not $emb.Warnings.Count) { Write-LaiLog OK "Document search: $($emb.Detail) with a reranker" }
        foreach ($w in @($emb.Warnings)) { $warnings.Add($w); Write-LaiLog WARN $w }
    } catch {
        $why = $_.Exception.Message -replace '\s+', ' '
        $warnings.Add("Document search models were not checked ($why); run the installer again")
        Write-LaiLog WARN "Document search models were not checked: $why"
    }

    foreach ($c in $Collections) {
        try {
            if ($env:LOCALAI_TEST_KNOWLEDGE_FAIL -and $env:LOCALAI_TEST_KNOWLEDGE_FAIL -eq $c) { throw "Test hook: collection '$c' rejected" }
            $k = Add-LaiWebUIKnowledge -BaseUrl $BaseUrl -Token $Token -Name $c -Description "Knowledge collection: $c"
            Write-LaiLog OK "Knowledge collection '$c' $($k.Action)"
        } catch {
            $why = $_.Exception.Message -replace '\s+', ' '
            $warnings.Add("Knowledge collection '$c' was not created ($why); add it in Workspace > Knowledge")
            Write-LaiLog WARN "Knowledge collection '$c' was not created: $why"
        }
    }

    # A context set in Open WebUI wins over the tuned alias (kept on purpose: user parameters survive
    # re-runs), so say where it is instead of silently running at another size.
    foreach ($o in @(Get-LaiContextOverride -BaseUrl $BaseUrl -Token $Token -PresetIds @($Models | ForEach-Object { $_.Preset }))) {
        $warnings.Add("Open WebUI overrides the tuned context in $o; set Context Length (and Batch Size) there back to Default so the tuned alias decides")
        Write-LaiLog WARN "Open WebUI overrides the tuned context in $o"
    }
    return $warnings.ToArray()
}

#endregion

function Get-LaiPullPolicy {
    <#
    .SYNOPSIS
        'missing' when every image tag is a pinned release (an image already on disk is the right one,
        so re-runs need no registry), 'always' when any tag floats (main, latest, cuda, ...), which
        would otherwise never be refreshed. A pinned tag carries a version number.
    #>
    param([string[]]$Tags)
    foreach ($t in $Tags) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t -notmatch '\d' -or $t -match '^(latest|main|dev|nightly)(-|$)') { return 'always' }
    }
    return 'missing'
}

function Get-LaiExecutionPolicyAction {
    # What to do so typed script paths work. Pure function (unit-tested). Note: the effective policy
    # of the running process is useless here, because every entry point runs with -ExecutionPolicy
    # Bypass; the persistent scopes decide what the user's own PowerShell windows will do.
    #   'none'  - typed scripts already allowed
    #   'set'   - set LocalMachine to RemoteSigned
    #   'gpo'   - a Group Policy decides; cannot be changed here
    #   'user'  - the CurrentUser scope blocks it; only that user can change it
    param([string]$MachinePolicy = 'Undefined', [string]$UserPolicy = 'Undefined', [string]$CurrentUser = 'Undefined', [string]$LocalMachine = 'Undefined')
    $blocking = @('Restricted', 'AllSigned', 'Undefined')
    foreach ($gp in @($MachinePolicy, $UserPolicy)) {
        if ($gp -and $gp -ne 'Undefined') { if (@('Restricted', 'AllSigned') -contains $gp) { return 'gpo' } else { return 'none' } }
    }
    if ($CurrentUser -and $CurrentUser -ne 'Undefined') {
        if (@('Restricted', 'AllSigned') -contains $CurrentUser) { return 'user' }
        return 'none'
    }
    if ($blocking -contains $LocalMachine) { return 'set' }
    return 'none'
}

function Set-LaiScriptPolicy {
    # Lets the user run C:\AI\Scripts\*.ps1 by name. Returns a one-line result for the log.
    $s = @{}
    foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') { $s[$scope] = [string](Get-ExecutionPolicy -Scope $scope) }
    $action = Get-LaiExecutionPolicyAction -MachinePolicy $s['MachinePolicy'] -UserPolicy $s['UserPolicy'] -CurrentUser $s['CurrentUser'] -LocalMachine $s['LocalMachine']
    switch ($action) {
        'none' { return "execution policy already allows typed scripts (LocalMachine=$($s['LocalMachine']), CurrentUser=$($s['CurrentUser']))" }
        'gpo' { return "execution policy is set by Group Policy ($($s['MachinePolicy'])/$($s['UserPolicy'])); use the Start-menu shortcuts" }
        'user' { return "your CurrentUser execution policy is $($s['CurrentUser']); run 'Set-ExecutionPolicy RemoteSigned -Scope CurrentUser' once, or use the Start-menu shortcuts" }
    }
    try { Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop }
    catch {
        # This process runs with -ExecutionPolicy Bypass, so PowerShell reports that the new setting is
        # "overridden by a more specific scope". The machine setting was still written.
        if ($_.FullyQualifiedErrorId -notlike '*ExecutionPolicyOverride*') { throw }
    }
    $now = [string](Get-ExecutionPolicy -Scope LocalMachine)
    if ($now -ne 'RemoteSigned') { throw "LocalMachine execution policy is still $now" }
    return "execution policy LocalMachine: $($s['LocalMachine']) -> RemoteSigned (typed scripts now run)"
}

function Get-LaiShortcutSpecs {
    # What goes into the "Local AI" Start-menu folder. Script shortcuts keep their window open
    # after the script ends (also after an error) so the result can be read.
    param([Parameter(Mandatory)][string]$AIRoot, [int]$WebUIPort = 3000, [int]$DeepResearchPort = 0)
    # Plain string building (Windows paths), so this also works when tested on Linux.
    $scripts = $AIRoot.TrimEnd('\') + '\Scripts'
    # ConvertTo-LaiPsQuoted, not a plain '' doubling: a typographic apostrophe in the path also ends the string.
    $q = { param($s) ConvertTo-LaiPsQuoted $s }
    $items = @(
        @{ Name = 'Local AI - Gaming mode (free GPU)'; Script = 'Stop-LocalAI.ps1'; Extra = ''; Log = $true }
        @{ Name = 'Local AI - Start again'; Script = 'Start-LocalAI.ps1'; Extra = ''; Log = $true }
        @{ Name = 'Local AI - Health check'; Script = 'Test-LocalAI.ps1'; Extra = ' -Quick'; Log = $true }
        @{ Name = 'Local AI - Re-check models'; Script = 'Update-Models.ps1'; Extra = ' -RecheckOnly'; Log = $true }
        @{ Name = 'ComfyUI (free GPU first)'; Script = 'Start-ComfyUI.ps1'; Extra = ''; Log = $true }
        @{ Name = 'Local AI - Diagnostics (redacted zip)'; Script = 'Get-LocalAIDiagnostics.ps1'; Extra = ' -RunTests' }
        @{ Name = 'Local AI - Sync skills'; Script = 'Sync-LocalAISkills.ps1'; Extra = ''; Log = $true }
        @{ Name = 'Local AI - Security check'; Script = 'Test-PCSecurity.ps1'; Extra = ''; Log = $true }
        @{ Name = 'Local AI - Update toolkit'; Script = 'Get-LocalAI.ps1'; Extra = ''; Env = 'LOCALAI_ROOT' }
    )
    $specs = @([pscustomobject]@{ Name = 'Local AI (Open WebUI)'; Kind = 'url'; Script = ''; Target = "http://localhost:$WebUIPort/"; Arguments = ''; TooLong = $false })
    if ($DeepResearchPort -gt 0) { $specs += [pscustomobject]@{ Name = 'Local AI - Deep Research'; Kind = 'url'; Script = ''; Target = "http://localhost:$DeepResearchPort/"; Arguments = ''; TooLong = $false } }
    foreach ($i in $items) {
        $path = $scripts + '\' + $i.Script
        if ($i.Env) { $call = "`$env:$($i.Env) = $(& $q $AIRoot.TrimEnd('\')); & $(& $q $path)" }   # bootstrap reads the root from the environment
        else { $call = "& $(& $q $path) -AIRoot $(& $q $AIRoot)$($i.Extra)" }
        # 'catch' prints the error BEFORE the window waits: with only try/finally PowerShell shows the
        # error after the user has pressed Enter, i.e. as the window closes, so it was never read.
        # The window's text is gone once it closes, so the last run of each is kept in Logs\shortcut-*.log
        # for the diagnostics zip. Not for Update toolkit: an installer running in the same window
        # prints the admin password at the end.
        $logOn = ''; $logOff = ''
        if ($i.Log) {
            $logPath = $AIRoot.TrimEnd('\') + '\Logs\shortcut-' + $i.Script.Replace('.ps1', '') + '.log'
            $logOn = "try { Start-Transcript -LiteralPath $(& $q $logPath) -Force | Out-Null } catch { Write-Host 'This run is not logged.' }; "
            $logOff = 'try { Stop-Transcript | Out-Null } catch { $null = $_ }; '
        }
        $body = "try { $call } catch { Write-Host ''; Write-Host ('FAILED: ' + `$_.Exception.Message) -ForegroundColor Red; Write-Host 'For help: Start menu > Local AI - Diagnostics (redacted zip).' -ForegroundColor Yellow } finally { Write-Host ''; ${logOff}Read-Host 'Done - press Enter to close' }"
        $arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $logOn + $body + '"'
        # A .lnk holds at most 1024 characters of arguments, and a long install folder appears up to
        # three times: drop the log first, and mark the shortcut unusable if it still does not fit.
        if ($arguments.Length -ge 1024 -and $logOn) {
            $body = $body.Replace($logOff, '')
            $arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $body + '"'
        }
        $specs += [pscustomobject]@{
            Name      = $i.Name
            Kind      = 'lnk'
            Script    = $i.Script
            Target    = 'powershell.exe'
            Arguments = $arguments
            TooLong   = ($arguments.Length -ge 1024)
        }
    }
    return $specs
}

Export-ModuleMember -Function *-Lai*
