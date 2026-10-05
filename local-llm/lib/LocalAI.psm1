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

function Set-LaiPrivateAcl {
    <#
    .SYNOPSIS
        Replaces a file's or folder's permissions with: the given user, SYSTEM and Administrators
        (inheritance from the parent removed, so "Authenticated Users" from C:\ no longer applies).
        -UserAccess ReadOnly gives the user read/execute only. Windows only; returns icacls' exit
        code and output.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$UserSid, [ValidateSet('Full', 'ReadOnly')][string]$UserAccess = 'Full')
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

function Get-LaiGpuInfo {
    # First NVIDIA GPU via nvidia-smi, or $null when nvidia-smi is unavailable.
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return $null }
    # Local 'Continue': in Windows PowerShell 5.1 a native command's stderr becomes a terminating error
    # under the caller's 'Stop' preference, even when redirected.
    $ErrorActionPreference = 'Continue'
    $out = & $smi --query-gpu=name,driver_version,memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $f = (@($out)[0]).Split(',') | ForEach-Object { $_.Trim() }
    return [pscustomobject]@{
        Name          = $f[0]
        DriverVersion = $f[1]
        TotalMiB      = [int]$f[2]
        UsedMiB       = [int]$f[3]
        FreeMiB       = [int]$f[4]
    }
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

function Get-LaiOllamaVersion {
    param([string]$BaseUrl = 'http://127.0.0.1:11434')
    return (Invoke-LaiApi -Uri "$BaseUrl/api/version" -TimeoutSec 10).version
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
    $body = @{ model = $Name; keep_alive = $KeepAlive }
    if ($NumCtx -gt 0) { $body['options'] = @{ num_ctx = $NumCtx } }
    Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/generate" -Body $body -TimeoutSec 900 | Out-Null
    $resolved = Resolve-LaiModelName $Name
    $entry = Get-LaiOllamaLoaded -BaseUrl $BaseUrl | Where-Object { $_.name -eq $resolved } | Select-Object -First 1
    if (-not $entry) { throw "Model $Name did not appear in /api/ps after loading." }
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

    Stop-LaiOllamaModels -BaseUrl $BaseUrl
    $result = $null
    foreach ($ctx in $list) {
        $load = Invoke-LaiOllamaLoad -BaseUrl $BaseUrl -Name $Name -NumCtx $ctx -KeepAlive '2m'
        $gpu = Get-LaiGpuInfo
        $free = -1
        if ($gpu) { $free = $gpu.FreeMiB }
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
    $old = ConvertTo-LaiHashtable $Existing
    $params = @{}
    if ($old.ContainsKey('params') -and $old['params'] -is [hashtable]) { $params = $old['params'] }
    foreach ($k in $Managed['params'].Keys) { $params[$k] = $Managed['params'][$k] }
    $meta = @{}
    if ($old.ContainsKey('meta') -and $old['meta'] -is [hashtable]) { $meta = $old['meta'] }
    foreach ($k in $Managed['meta'].Keys) { $meta[$k] = $Managed['meta'][$k] }
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
        $update = @{
            id = $Id; name = $form['name']; base_model_id = $form['base_model_id']
            meta = $form['meta']; params = $form['params']; is_active = $form['is_active']
        }
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
    $body = @{ ENABLE_OLLAMA_API = $enabled; OLLAMA_BASE_URLS = [object[]]$new; OLLAMA_API_CONFIGS = $apiConfigs }
    Invoke-LaiApi -Method POST -Uri "$BaseUrl/ollama/config/update" -Body $body -Token $Token | Out-Null
    return $true
}

function Get-LaiWebUIKnowledge {
    param([string]$BaseUrl = 'http://127.0.0.1:3000', [Parameter(Mandatory)][string]$Token)
    $all = @()
    for ($page = 1; $page -le 50; $page++) {
        $r = Invoke-LaiApi -Uri "$BaseUrl/api/v1/knowledge/?page=$page" -Token $Token
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
        $resp = $client.PostAsync("$BaseUrl/api/v1/files/", $form).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
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
        [int]$TimeoutSec = 900
    )
    $body = @{
        model    = $Model
        stream   = $false
        messages = @(@{ role = 'user'; content = $Prompt })
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

function Test-LaiWebUIRag {
    # Guide Step 33, automated: index a document containing a random code, retrieve it, clean up.
    param(
        [string]$BaseUrl = 'http://127.0.0.1:3000',
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Model,
        [string]$WorkDir = [System.IO.Path]::GetTempPath()
    )
    $code = 'QX-{0}-TANGERINE' -f (Get-Random -Minimum 1000 -Maximum 9999)
    $doc = Join-Path $WorkDir 'localai-selftest-manual.md'
    $text = "# Zorblax 9000 Widget Manual`n`n## Calibration`n`nThe calibration code for the Zorblax 9000 widget is $code. " +
        "Hold the reset button for 12 seconds before entering it.`n`n## Maintenance`n`nClean the intake filter monthly.`n"
    [System.IO.File]::WriteAllText($doc, $text, (New-Object System.Text.UTF8Encoding($false)))
    $kb = $null; $fileId = $null
    try {
        $kb = Invoke-LaiApi -Method POST -Uri "$BaseUrl/api/v1/knowledge/create" -Token $Token -Body @{
            name = 'LocalAI Self-Test (temporary)'; description = 'Created and deleted by Install-LocalAI.ps1'
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
        $reuse = (-not $Retune) -and $prev -and ($prev['Source'] -eq $m.Source) -and ($prev['Fingerprint'] -eq $Fingerprint) -and
            ($prev['MaxContext'] -eq $m.MaxContext) -and $sameModel -and (Test-LaiOllamaModel -BaseUrl $BaseUrl -Name $m.Alias)
        # Skipping the load also needs the same Ollama: a new version can place layers differently.
        # (Results without a recorded version take the verify path once, which records it.)
        if ($reuse -and $sameOllama -and $prev['TokensPerSec'] -and $null -ne $prev['GpuPercent']) {
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
        $results[$m.Key] = @{
            Source       = $m.Source
            Alias        = $m.Alias
            Context      = $load.Context
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
    if ($Order.Count -gt 0) { $cfg['MODEL_ORDER_LIST'] = @($Order) }
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
    Write-LaiLog STEP 'Open WebUI: admin settings (signup off, memories on, community sharing off)'
    Set-LaiWebUIAdminConfig -BaseUrl $BaseUrl -Token $Token -Changes @{
        ENABLE_SIGNUP = $false; ENABLE_MEMORIES = $true; ENABLE_MEMORY_SYSTEM_CONTEXT = $true; ENABLE_COMMUNITY_SHARING = $false
    } | Out-Null

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
    Set-LaiWebUIRetrievalConfig -BaseUrl $BaseUrl -Token $Token -Settings @{
        TEXT_SPLITTER                        = 'token'
        ENABLE_MARKDOWN_HEADER_TEXT_SPLITTER = $true
        CHUNK_SIZE                           = 2000
        CHUNK_OVERLAP                        = 200
        TOP_K                                = 5
        web                                  = @{
            ENABLE_WEB_SEARCH       = $true
            WEB_SEARCH_ENGINE       = 'searxng'
            SEARXNG_QUERY_URL       = $SearxngQueryUrl
            WEB_SEARCH_RESULT_COUNT = 5
        }
    } | Out-Null
    $rc = Get-LaiWebUIRetrievalConfig -BaseUrl $BaseUrl -Token $Token
    Write-LaiLog OK ("RAG: splitter={0}, chunk={1}/{2}, top_k={3}; web search={4} via {5}" -f $rc.TEXT_SPLITTER, $rc.CHUNK_SIZE, $rc.CHUNK_OVERLAP, $rc.TOP_K, $rc.web.ENABLE_WEB_SEARCH, $rc.web.WEB_SEARCH_ENGINE)

    foreach ($c in $Collections) {
        $k = Add-LaiWebUIKnowledge -BaseUrl $BaseUrl -Token $Token -Name $c -Description "Knowledge collection: $c"
        Write-LaiLog OK "Knowledge collection '$c' $($k.Action)"
    }
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
    param([Parameter(Mandatory)][string]$AIRoot, [int]$WebUIPort = 3000)
    # Plain string building (Windows paths), so this also works when tested on Linux.
    $scripts = $AIRoot.TrimEnd('\') + '\Scripts'
    $q = { param($s) "'" + $s.Replace("'", "''") + "'" }
    $items = @(
        @{ Name = 'Local AI - Gaming mode (free GPU)'; Script = 'Stop-LocalAI.ps1'; Extra = '' }
        @{ Name = 'Local AI - Start again'; Script = 'Start-LocalAI.ps1'; Extra = '' }
        @{ Name = 'Local AI - Health check'; Script = 'Test-LocalAI.ps1'; Extra = ' -Quick' }
        @{ Name = 'ComfyUI (free GPU first)'; Script = 'Start-ComfyUI.ps1'; Extra = '' }
        @{ Name = 'Local AI - Diagnostics (redacted zip)'; Script = 'Get-LocalAIDiagnostics.ps1'; Extra = ' -RunTests' }
        @{ Name = 'Local AI - Update toolkit'; Script = 'Get-LocalAI.ps1'; Extra = ''; Env = 'LOCALAI_ROOT' }
    )
    $specs = @([pscustomobject]@{ Name = 'Local AI (Open WebUI)'; Kind = 'url'; Target = "http://localhost:$WebUIPort/"; Arguments = '' })
    foreach ($i in $items) {
        $path = $scripts + '\' + $i.Script
        if ($i.Env) { $call = "`$env:$($i.Env) = $(& $q $AIRoot.TrimEnd('\')); & $(& $q $path)" }   # bootstrap reads the root from the environment
        else { $call = "& $(& $q $path) -AIRoot $(& $q $AIRoot)$($i.Extra)" }
        $cmd = "try { $call } finally { Write-Host ''; Read-Host 'Done - press Enter to close' }"
        $specs += [pscustomobject]@{
            Name      = $i.Name
            Kind      = 'lnk'
            Target    = 'powershell.exe'
            Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $cmd + '"'
        }
    }
    return $specs
}

Export-ModuleMember -Function *-Lai*
