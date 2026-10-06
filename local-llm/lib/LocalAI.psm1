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
    if ($env:LOCALAI_DOCKER_TIMEOUT) { $s = [int]$env:LOCALAI_DOCKER_TIMEOUT }
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

function Set-LaiPrivateAcl {
    <#
    .SYNOPSIS
        Replaces a file's or folder's permissions with: the given user, SYSTEM and Administrators
        (inheritance from the parent removed, so "Authenticated Users" from C:\ no longer applies).
        -UserAccess ReadOnly gives the user read/execute only. Windows only; returns icacls' exit
        code and output.
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
    try {
        $out = & icacls.exe $Path '/inheritance:r' '/grant:r' "*${UserSid}:$userGrant" "*S-1-5-18:${inherit}F" "*S-1-5-32-544:${inherit}F" 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ ExitCode = $code; Text = ($out -join "`n") }
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
    # Replace the content only, so the credentials file keeps its restricted permissions.
    Get-Content -Encoding UTF8 -LiteralPath $pending -Raw | Set-Content -LiteralPath $credFile -Encoding UTF8 -NoNewline -ErrorAction Stop
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
            $wait = 45; if ($env:LOCALAI_TEST_SIGNIN_WAIT) { $wait = [int]$env:LOCALAI_TEST_SIGNIN_WAIT }
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
    #                    switch, so the preset is the only place to turn Local Fast's reasoning on.
    #   image_generation an image button the user wired to ComfyUI (not code execution, which stays off).
    $createOnly = @{ params = @('think'); capabilities = @('image_generation'); builtinTools = @('image_generation') }
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
        # capabilities / builtinTools: set the switches the installer manages, keep every other one.
        # Replacing the whole set erased the user's own choices (Open WebUI treats a missing tool
        # category as ON, so a calendar or notes tool the user had turned off came back on).
        if ($Managed['meta'][$k] -is [hashtable] -and $meta.ContainsKey($k) -and $meta[$k] -is [hashtable]) {
            foreach ($leaf in $Managed['meta'][$k].Keys) {
                if ($createOnly.ContainsKey($k) -and $createOnly[$k] -contains $leaf -and $meta[$k].ContainsKey($leaf) -and $null -ne $meta[$k][$leaf]) { continue }
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
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][hashtable]$Settings)
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
    return Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/retrieval/config/update" -Body $body -Token $Token -TimeoutSec 120
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

#region Deep research (Local Deep Research, optional: Install-LocalAI.ps1 -DeepResearch) ---------

function Get-LaiDeepResearchEnv {
    <#
    .SYNOPSIS
        The Stack\.env values for the optional deep-research service. Off: COMPOSE_PROFILES is empty,
        so docker compose never starts it. On: it uses the preset's tuned context, because a num_ctx
        that differs from the alias makes Ollama reload the model (and fit it differently) on every call.
    #>
    param([bool]$Enabled, [string]$Model = 'localai-main:latest', [int]$Context = 32768, [int]$Port = 5055, [bool]$AllowRegistrations = $true)
    # With its tag: its model list and checks compare names exactly with Ollama's ('x:latest').
    if ($Model -notmatch ':[^/]+$') { $Model += ':latest' }
    $profiles = ''; if ($Enabled) { $profiles = 'research' }
    $allow = 'false'; if ($AllowRegistrations) { $allow = 'true' }
    return @{
        COMPOSE_PROFILES                  = $profiles
        DEEP_RESEARCH_PORT                = [string]$Port
        DEEP_RESEARCH_MODEL               = $Model
        DEEP_RESEARCH_CONTEXT             = [string]$Context
        DEEP_RESEARCH_ALLOW_REGISTRATIONS = $allow
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
    $r = Invoke-LaiResearchRequest -Session $s -Method POST -Path '/auth/login' -Form @{ username = $Account; password = $Password; csrf_token = $t }
    if ($r.Status -eq 429) {
        $s.Client.Dispose()
        # 5 sign-ins per 15 minutes: say so, a 'wrong password' guess would send the user the wrong way.
        throw 'Local Deep Research refused the sign-in: too many sign-ins in the last 15 minutes. Wait 15 minutes and try again.'
    }
    $chk = Invoke-LaiResearchRequest -Session $s -Path '/auth/check'
    if ($chk.Status -ne 200) {
        $why = Get-LaiResearchFormError $r.Body
        $s.Client.Dispose()
        if ($why) { throw "Local Deep Research refused the sign-in for '$Account' ($why)." }
        throw "Local Deep Research refused the sign-in for '$Account' (HTTP $($r.Status))."
    }
    return $s
}

function Test-LaiResearchModel {
    # Whether Local Deep Research reaches Ollama and finds its model: Available plus its message.
    # The model is passed: this endpoint does not fall back to LDR_LLM_MODEL (only research runs do).
    # Its check compares the name exactly with Ollama's list, which always has the tag ('x:latest').
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Model)
    if ($Model -notmatch ':[^/]+$') { $Model += ':latest' }
    $path = '/research/api/check/ollama_model?model=' + [uri]::EscapeDataString($Model)
    $r = Invoke-LaiResearchRequest -Session $Session -Path $path
    $o = $null; try { $o = ConvertFrom-Json -InputObject $r.Body } catch { $o = $null }
    if ($r.Status -ne 200 -or -not $o) { return [pscustomobject]@{ Available = $false; Message = "HTTP $($r.Status)" } }
    $msg = ''; if ($o.PSObject.Properties['message']) { $msg = [string]$o.message }
    return [pscustomobject]@{ Available = [bool]$o.available; Message = $msg }
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
    return [pscustomobject]@{ Summary = [string]$o.summary; Sources = @($o.sources | Where-Object { $_ }).Count; Findings = @($o.findings).Count }
}

#endregion

#region High-level setup (shared by the installer and the Linux integration harness) -----

function Get-LaiCatalog {
    # Loads config/models.psd1. -IncludeKeys filters to the models selected for this install;
    # without it, opt-in trial models are left out unless -IncludeTrials.
    param([Parameter(Mandatory)][string]$Path, [string[]]$IncludeKeys = @(), [switch]$IncludeTrials)
    $data = Import-PowerShellDataFile -Path $Path
    $models = @($data.Models)
    if ($IncludeKeys.Count -gt 0) { $models = @($models | Where-Object { $IncludeKeys -contains $_.Key }) }
    elseif (-not $IncludeTrials) { $models = @($models | Where-Object { -not $_.Trial }) }
    return [pscustomobject]@{
        DefaultPreset     = $data.DefaultPreset
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
        $candKey = (@($Candidates | Sort-Object -Descending -Unique) -join ',')
        $sameCandidates = $prev -and (-not $prev['Candidates'] -or [string]$prev['Candidates'] -eq $candKey)
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

function New-LaiPresetForm {
    # Open WebUI workspace model ("preset") on top of a tuned Ollama alias.
    param([Parameter(Mandatory)][hashtable]$Entry, [Parameter(Mandatory)][bool]$NativeTools, [Parameter(Mandatory)][string]$SystemPrompt)
    $params = @{ system = $SystemPrompt }
    if ($NativeTools) { $params['function_calling'] = 'native' } else { $params['function_calling'] = 'legacy' }
    if ($Entry.Think -eq $false) { $params['think'] = $false }
    $meta = @{
        description       = $Entry.Description
        profile_image_url = '/static/favicon.png'
        capabilities      = @{
            vision = [bool]$Entry.Vision; file_upload = $true; file_context = $true; web_search = $true
            image_generation = $false; code_interpreter = $false; terminal = $false
            citations = $true; status_updates = $true; memory = $true; builtin_tools = $true
        }
        builtinTools      = @{
            memory = $true; web_search = $true; knowledge = $true; chats = $true; time = $true
            image_generation = $false; code_interpreter = $false
        }
        tags              = @(@{ name = 'local' })
    }
    # A trial that is selected again must be shown again (the installer hid it when it was dropped);
    # the measured presets keep whatever the user chose.
    if ($Entry.Trial) { $meta['hidden'] = $false }
    # Native tool calling lets the model decide when to search. In legacy (prompt-based) mode a
    # default-on web search would run a search before every single message, so leave it off there.
    if ($NativeTools) { $meta['defaultFeatureIds'] = @('web_search') }
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

function Get-LaiRagWanted {
    # The documents (RAG), image upload and web search settings the installer writes and reads back;
    # Test-LocalAI compares the live ones with the same list.
    param([string]$SearxngQueryUrl = 'http://searxng:8080/search?q=<query>')
    return @{
        TEXT_SPLITTER                        = 'token'
        ENABLE_MARKDOWN_HEADER_TEXT_SPLITTER = $true
        CHUNK_SIZE                           = 2000
        CHUNK_OVERLAP                        = 200
        TOP_K                                = 5
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
        $form = Merge-LaiPresetForm -Managed (New-LaiPresetForm -Entry $m -NativeTools $native -SystemPrompt $SystemPrompt) `
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
    if (-not ($Models | Where-Object { $_.Preset -eq $default })) { $default = $order[0] }
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
        @{ Name = 'ComfyUI (free GPU first)'; Script = 'Start-ComfyUI.ps1'; Extra = ''; Log = $true }
        @{ Name = 'Local AI - Diagnostics (redacted zip)'; Script = 'Get-LocalAIDiagnostics.ps1'; Extra = ' -RunTests' }
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
