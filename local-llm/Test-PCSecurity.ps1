#Requires -Version 5.1

<#
.SYNOPSIS
    Read-only security check of this Windows PC for the local AI stack. It changes nothing.

.DESCRIPTION
    Checks what matters for a home PC that runs Ollama, Open WebUI, SearXNG, ComfyUI and RGB/fan
    tools, and says for every problem one next step you can follow yourself:

      antivirus (Microsoft Defender or the product Windows Security knows), Windows Update and a
      pending restart, the firewall, User Account Control, Core isolation (memory integrity) and the
      Microsoft vulnerable driver blocklist, Secure Boot and the TPM, drive encryption (system drive,
      the install folder's drive, the Ollama models' drive), Smart App Control and SmartScreen, known
      vulnerable kernel drivers that RGB/fan/overclocking tools install, Remote Desktop, SMBv1, programs
      listening beyond this PC (the AI ports must not), Docker Desktop's version and its unprotected
      API setting, ComfyUI custom nodes and pickle-format model files, the toolkit's Secrets folder
      permissions, and whether you use an administrator account day to day.

    Only reads: registry values, CIM/WMI queries, Get-* cmdlets, folder listings and permissions. It
    never changes a setting, starts or stops anything, or contacts the internet. Every check is
    wrapped: a query that fails becomes SKIP, never an error that stops the run.

    Works in a normal window; some checks (TPM, Secure Boot on some PCs, drive encryption, SMBv1)
    need an elevated one and say so. For the full check: right-click Start menu > Local AI - Security
    check > More > Run as administrator.

    The Markdown report leaves out your Windows user name, the computer name, e-mail addresses and
    anything that looks like a password or key (your profile folder becomes %USERPROFILE%).
    Exit code = number of FAILs (0 = nothing urgent).

.PARAMETER AIRoot
    Install folder (the installer's -AIRoot). Its localai-config.json gives the Open WebUI/SearXNG
    ports and the Ollama model folder; its Secrets folder's permissions are checked; the report goes
    to its Logs folder.

.PARAMETER ReportPath
    Where the Markdown report is written. Empty (the default) = <AIRoot>\Logs\pc-security-<yyyyMMdd-HHmmss>.md.

.EXAMPLE
    .\Test-PCSecurity.ps1
.EXAMPLE
    .\Test-PCSecurity.ps1 -AIRoot D:\AI -ReportPath D:\pc-security.md
#>
param(
    [string]$AIRoot = 'C:\AI',
    [string]$ReportPath = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

#region Pure helpers (no PC access; unit-tested in tests\Invoke-WindowsUnitTests.ps1) -------------

function Test-PcsVersionBelow {
    # $true when $Version is lower than $Minimum, $false when not, $null when $Version has no number.
    param([string]$Version, [string]$Minimum)
    $toVer = {
        param([string]$s)
        if ($s -notmatch '^\s*v?(\d+(\.\d+){0,3})') { return $null }
        $t = $Matches[1]
        if ($t -notmatch '\.') { $t += '.0' }
        try { return [version]$t } catch { return $null }
    }
    $v = & $toVer $Version
    $m = & $toVer $Minimum
    if ($null -eq $v -or $null -eq $m) { return $null }
    return ($v -lt $m)
}

function Find-PcsRiskyDriver {
    <#
    Kernel drivers with a published flaw that lets any program on the PC read and write kernel
    memory (and so become SYSTEM or switch off antivirus). Input: Win32_SystemDriver-like objects
    (Name, PathName, State) and installed apps (Name, Version). Output: one object per match;
    Fixed = $true when the app that brings it is at or above the version that fixed the driver.
    Sources:
      WinRing0 (WinRing0x64.sys): CVE-2020-14979 https://nvd.nist.gov/vuln/detail/CVE-2020-14979 ;
        Microsoft Defender detects it as HackTool:Win32/Winring0 since 2025:
        https://www.neowin.net/news/windows-1110-is-flagging-winring0-on-your-pc-monitoring-fan-control-apps-heres-why/
        https://github.com/Rem0o/FanControl.Releases/discussions/3017
      RTCore64.sys (MSI Afterburner): CVE-2019-16098 https://nvd.nist.gov/vuln/detail/cve-2019-16098
      CorsairLLAccess64.sys (iCUE before 3.25.60): CVE-2020-8808 https://nvd.nist.gov/vuln/detail/CVE-2020-8808
      AsIO2 (ASUS GPU Tweak II before 2.3.0.3): CVE-2021-28685 https://attackerkb.com/topics/5NmTx2P1AB/cve-2021-28685
      AsIO3.sys (ASUS Armoury Crate / AI Suite 3): CVE-2025-3464 (patched June 2025),
        https://blog.talosintelligence.com/decrement-by-one-to-rule-them-all/ ; CVE-2025-1533
        https://www.talosintelligence.com/vulnerability_reports/TALOS-2025-2144
      gdrv.sys (GIGABYTE APP Center, AORUS Graphics Engine, ...): CVE-2018-19320
        https://www.gigabyte.com/Support/Security/1801
    The first ASUS AsIO.sys is left out: no published CVE for it could be confirmed.
    #>
    param([object[]]$Drivers = @(), [object[]]$Apps = @())
    $known = @(
        @{ File = '^winring0(x64)?\.sys$'; Service = '^winring0'; App = 'fan-control, RGB and hardware-monitoring tools (for example older FanControl, Libre/Open Hardware Monitor, older Razer Synapse 3 and some RGB utilities)'
            Cve = 'CVE-2020-14979; Microsoft Defender flags it as HackTool:Win32/Winring0'; Fix = 'update the tool that installed it to a version without WinRing0, or uninstall it (Settings > Apps > Installed apps)'; AppMatch = ''; FixedIn = '' }
        @{ File = '^rtcore(64|32)\.sys$'; Service = '^rtcore(64|32)$'; App = 'MSI Afterburner'
            Cve = 'CVE-2019-16098'; Fix = 'update MSI Afterburner to the newest version from msi.com, or uninstall it if you do not use it'; AppMatch = ''; FixedIn = '' }
        @{ File = '^corsairllaccess(64|32)\.sys$'; Service = '^corsairllaccess'; App = 'Corsair iCUE'
            Cve = 'CVE-2020-8808, fixed in iCUE 3.25.60'; Fix = 'update iCUE (iCUE > Settings > Software and Updates), or install the newest version from corsair.com'; AppMatch = '(?i)\bicue\b'; FixedIn = '3.25.60' }
        @{ File = '^asio2(_?(64|32))?\.sys$'; Service = '^asio2$'; App = 'ASUS GPU Tweak II'
            Cve = 'CVE-2021-28685, fixed in GPU Tweak II 2.3.0.3'; Fix = 'update ASUS GPU Tweak II, or uninstall it if you do not use it'; AppMatch = '(?i)gpu ?tweak ?ii'; FixedIn = '2.3.0.3' }
        @{ File = '^asio3(_?64)?\.sys$'; Service = '^asio3$'; App = 'ASUS Armoury Crate / AI Suite 3'
            Cve = 'CVE-2025-3464 and CVE-2025-1533'; Fix = 'update Armoury Crate (Armoury Crate > Settings > Update Center), or remove it with ASUS''s Armoury Crate Uninstall Tool if you do not use it'; AppMatch = ''; FixedIn = '' }
        @{ File = '^gdrv\.sys$'; Service = '^gdrv$'; App = 'GIGABYTE APP Center / AORUS Graphics Engine / RGB Fusion'
            Cve = 'CVE-2018-19320'; Fix = 'update the GIGABYTE tool from gigabyte.com, or uninstall it if you do not use it'; AppMatch = ''; FixedIn = '' }
    )
    $out = @()
    foreach ($d in @($Drivers)) {
        if ($null -eq $d) { continue }
        $name = [string]$d.Name
        $path = ([string]$d.PathName).Trim().Trim('"')
        $leaf = ''
        if ($path -match '([^\\/]+)$') { $leaf = $Matches[1] }
        foreach ($k in $known) {
            if (-not (($leaf -and $leaf -match $k.File) -or ($name -and $name -match $k.Service))) { continue }
            $fixed = $false
            $appText = ''
            if ($k.AppMatch -and $k.FixedIn) {
                foreach ($a in @($Apps | Where-Object { $_ -and ([string]$_.Name) -match $k.AppMatch })) {
                    $below = Test-PcsVersionBelow -Version ([string]$a.Version) -Minimum $k.FixedIn
                    if ($false -eq $below) { $fixed = $true; $appText = "$($a.Name) $($a.Version)" }
                }
            }
            $file = $leaf; if (-not $file) { $file = $name }
            $out += [pscustomobject]@{
                Driver = $file; Service = $name; State = [string]$d.State; Running = ([string]$d.State -eq 'Running')
                App = $k.App; Cve = $k.Cve; Fix = $k.Fix; Fixed = $fixed; FixedBy = $appText
            }
            break
        }
    }
    return $out
}

function ConvertFrom-PcsAvState {
    # Windows Security Center's productState for an antivirus product. Microsoft does not document
    # it; the widely used reading: bit 0x1000 = real-time scanning on, bit 0x10 = definitions out of date.
    # https://jdhitsolutions.com/blog/powershell/5187/get-antivirus-product-status-with-powershell/
    param([long]$State)
    return [pscustomobject]@{ Enabled = (($State -band 0x1000) -ne 0); UpToDate = (($State -band 0x10) -eq 0) }
}

function Get-PcsAclVerdict {
    # Rules: objects with Sid, Type ('Allow'/'Deny') and Who (display name). Allowed: SYSTEM,
    # Administrators, CREATOR OWNER / OWNER RIGHTS, the folder's owner and the current user.
    # Broad groups (Everyone, Authenticated Users, Users, Interactive, Guests, Anonymous) = FAIL.
    # Any other account = FAIL, except when the current user is not on the list at all (run from
    # another account than the one that installed): then WARN.
    param([object[]]$Rules = @(), [string]$CurrentSid = '', [string]$OwnerSid = '')
    $ok = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-3-4')
    if ($CurrentSid) { $ok += $CurrentSid }
    if ($OwnerSid) { $ok += $OwnerSid }
    $broad = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4', 'S-1-5-32-546', 'S-1-5-7')
    $bad = @(); $broadHit = $false; $currentListed = $false
    foreach ($r in @($Rules)) {
        if ($null -eq $r -or [string]$r.Type -ne 'Allow') { continue }
        $sid = [string]$r.Sid
        if ($CurrentSid -and $sid -eq $CurrentSid) { $currentListed = $true }
        if ($ok -contains $sid) { continue }
        if ($broad -contains $sid) { $broadHit = $true }
        $who = [string]$r.Who; if (-not $who) { $who = $sid }
        if ($bad -notcontains $who) { $bad += $who }
    }
    $status = 'PASS'
    if ($bad.Count) { $status = 'FAIL' }
    if ($bad.Count -and -not $broadHit -and -not $currentListed) { $status = 'WARN' }
    return [pscustomobject]@{ Status = $status; Bad = $bad }
}

function Get-PcsExposedPort {
    # Listeners: objects with Port, Address, Process. Critical: listeners on one of $CriticalPorts at
    # an address other than loopback. Other: non-loopback listeners of programs that are not part of
    # Windows itself (each 'port@address (process)' once).
    param([object[]]$Listeners = @(), [int[]]$CriticalPorts = @())
    $system = @('system', 'svchost', 'lsass', 'wininit', 'services', 'spoolsv', 'idle')
    $critical = @(); $other = @()
    foreach ($l in @($Listeners)) {
        if ($null -eq $l) { continue }
        $addr = [string]$l.Address
        if ($addr -match '^127\.' -or $addr -eq '::1' -or $addr -match '^::ffff:127\.') { continue }
        $proc = [string]$l.Process
        $label = '{0}@{1} ({2})' -f $l.Port, $addr, $(if ($proc) { $proc } else { 'unknown program' })
        if ($CriticalPorts -contains [int]$l.Port) {
            if ($critical -notcontains $label) { $critical += $label }
        } elseif ($system -notcontains $proc.ToLowerInvariant()) {
            if ($other -notcontains $label) { $other += $label }
        }
    }
    return [pscustomobject]@{ Critical = $critical; Other = $other }
}

function Get-PcsJsonFlag {
    # A setting from a JSON object, name compared without case (Docker Desktop's settings-store.json
    # and its older settings.json spell keys differently). An admin-style { "value": x } is unwrapped.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    foreach ($p in $Object.PSObject.Properties) {
        if ($p.Name -ne $Name) { continue }
        $v = $p.Value
        if ($null -ne $v -and $v -is [pscustomobject] -and $v.PSObject.Properties['value']) { return $v.value }
        return $v
    }
    return $null
}

function Find-PcsComfyRoot {
    # ComfyUI folders (the one holding custom_nodes and models): Comfy Desktop's basePath from
    # %APPDATA%\ComfyUI\config.json, the folder of the start file the toolkit remembered
    # (Start-ComfyUI.ps1), then the usual places. Only folders that exist and hold custom_nodes or models.
    param([string]$AppData = '', [string]$UserProfile = '', [string]$Remembered = '')
    $cands = @()
    if ($AppData) {
        $cfg = Join-Path (Join-Path $AppData 'ComfyUI') 'config.json'
        if (Test-Path -LiteralPath $cfg) {
            try {
                $j = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                $bp = Get-PcsJsonFlag -Object $j -Name 'basePath'
                if ($bp) { $cands += [string]$bp }
            } catch { Write-Verbose 'Comfy Desktop config.json unreadable' }
        }
    }
    if ($Remembered -and $Remembered -notmatch '\.(exe|lnk)$') {
        $dir = $Remembered
        if ($Remembered -match '\.(bat|cmd|ps1|py)$') { $dir = Split-Path -Parent $Remembered }
        if ($dir) { $cands += (Join-Path $dir 'ComfyUI'); $cands += $dir }
    }
    if ($UserProfile) { $cands += (Join-Path (Join-Path $UserProfile 'Documents') 'ComfyUI') }
    $cands += 'C:\ComfyUI\ComfyUI_windows_portable\ComfyUI'
    $cands += 'C:\ComfyUI_windows_portable\ComfyUI'
    $cands += 'C:\ComfyUI'
    $roots = @()
    foreach ($c in $cands) {
        if (-not $c) { continue }
        # [IO.Path]::Combine, not Join-Path: Join-Path fails on a drive this system does not have
        # (the fixed C:\ candidates off Windows).
        $hasNodes = Test-Path -LiteralPath ([System.IO.Path]::Combine($c, 'custom_nodes'))
        $hasModels = Test-Path -LiteralPath ([System.IO.Path]::Combine($c, 'models'))
        if (-not ($hasNodes -or $hasModels)) { continue }
        $full = $c
        try { $full = (Resolve-Path -LiteralPath $c -ErrorAction Stop).Path } catch { Write-Verbose "cannot resolve $c" }
        if (@($roots | Where-Object { $_ -eq $full }).Count -eq 0) { $roots += $full }
    }
    return $roots
}

function Get-PcsPickleFile {
    # Model files in a pickle-based format (.ckpt .pt .pth .bin): loading one can run code hidden in
    # it. Breadth-first, at most -MaxDepth folders deep, -MaxSeconds and -MaxEntries, so a huge or
    # looping (linked) folder tree cannot keep the check busy. Read-only listing.
    param([string]$Root, [int]$MaxDepth = 8, [int]$MaxSeconds = 20, [int]$MaxEntries = 200000)
    $found = New-Object System.Collections.Generic.List[string]
    $truncated = $false
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return [pscustomobject]@{ Files = @(); Truncated = $false } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # A plain list walked by index works as the queue (no generic Queue type needed on 5.1).
    $queue = New-Object System.Collections.ArrayList
    [void]$queue.Add(@((New-Object System.IO.DirectoryInfo($Root)), 0))
    $next = 0
    $seen = 0
    while ($next -lt $queue.Count) {
        if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds -or $seen -gt $MaxEntries) { $truncated = $true; break }
        $item = $queue[$next]
        $queue[$next] = $null
        $next++
        $dir = $item[0]; $depth = [int]$item[1]
        $entries = @()
        try { $entries = @($dir.GetFileSystemInfos()) } catch { Write-Verbose "cannot list $($dir.FullName)"; continue }
        foreach ($e in $entries) {
            $seen++
            if ($e -is [System.IO.DirectoryInfo]) {
                if ($depth + 1 -gt $MaxDepth) { $truncated = $true; continue }
                [void]$queue.Add(@($e, ($depth + 1)))
            } elseif ($e.Extension -match '^\.(ckpt|pt|pth|bin)$') {
                $found.Add($e.FullName)
            }
        }
    }
    return [pscustomobject]@{ Files = $found.ToArray(); Truncated = $truncated }
}

function Protect-PcsText {
    # The report must not carry who you are: profile paths become %USERPROFILE%, user and computer
    # names (whole words, any case) <user> / <computer>, e-mail addresses <email>, and password=...,
    # Bearer tokens, JWTs and long hex keys [REDACTED] (same patterns as the diagnostics bundle).
    param([string]$Text, [string[]]$UserNames = @(), [string[]]$ComputerNames = @(), [string[]]$Paths = @())
    if (-not $Text) { return $Text }
    # CultureInvariant: under tr-TR, IgnoreCase does not pair I with i.
    $ci = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'
    foreach ($p in @($Paths | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object { $_.Length } -Descending)) {
        # Not when it is only the start of a longer folder name (C:\Users\Jo vs C:\Users\John).
        $Text = [regex]::Replace($Text, [regex]::Escape($p.TrimEnd([char]'\', [char]'/')) + '(?![\p{L}\p{N}])', '%USERPROFILE%', $ci)
    }
    # Any other profile folder too: another account's, or the short 8.3 form of yours (C:\Users\JOHNDO~1).
    $Text = [regex]::Replace($Text, '(?<![\p{L}\p{N}])([A-Za-z]:\\Users\\)[^\\/\s|"'',;)]+', '$1<user>', $ci)
    $Text = [regex]::Replace($Text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>')
    $Text = [regex]::Replace($Text, '(password|passwd|secret|secret_key|api_key|token)(["'']?\s*[:=]\s*["'']?)[^\s"'',;}]+', '$1$2[REDACTED]', $ci)
    $Text = [regex]::Replace($Text, 'Bearer\s+[A-Za-z0-9\-._~+/]+=*', 'Bearer [REDACTED]', $ci)
    $Text = [regex]::Replace($Text, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}', '[REDACTED]')
    $Text = [regex]::Replace($Text, '\b[0-9a-fA-F]{48,}\b', '[REDACTED]')
    foreach ($pair in @(@{ Names = $ComputerNames; Tag = '<computer>' }, @{ Names = $UserNames; Tag = '<user>' })) {
        foreach ($n in @($pair.Names | Where-Object { $_ -and $_.Length -ge 2 } | Sort-Object { $_.Length } -Descending)) {
            # Whole words only, so a short name does not cut into longer words.
            $Text = [regex]::Replace($Text, '(?<![\p{L}\p{N}])' + [regex]::Escape($n) + '(?![\p{L}\p{N}])', $pair.Tag, $ci)
        }
    }
    return $Text
}

#endregion

#region PC queries (read-only) ---------------------------------------------------------------------

function Get-PcsRegValue {
    # One registry value, or $null when the key or value is missing or unreadable.
    param([string]$Path, [string]$Name)
    try {
        $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $p.$Name
    } catch { return $null }
}

function Get-PcsInstalledApp {
    # DisplayName / DisplayVersion of installed programs (machine-wide, 32-bit and per-user entries).
    $apps = @()
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue)) {
            try { $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop } catch { continue }
            if (-not ($p.PSObject.Properties['DisplayName'] -and $p.DisplayName)) { continue }
            $ver = ''
            if ($p.PSObject.Properties['DisplayVersion'] -and $p.DisplayVersion) { $ver = [string]$p.DisplayVersion }
            $apps += [pscustomobject]@{ Name = [string]$p.DisplayName; Version = $ver }
        }
    }
    return $apps
}

function Get-PcsDriveOf {
    # 'C:' for 'C:\AI\...', '' for UNC or relative paths.
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):') { return ($Matches[1].ToUpperInvariant() + ':') }
    return ''
}

#endregion

$onWindows = ($env:OS -eq 'Windows_NT')
$config = @{}
try { $config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json') } catch { Write-Verbose 'config unreadable' }
$webPort = 3000; if ($config.ContainsKey('WebUIPort') -and $config['WebUIPort']) { $webPort = [int]$config['WebUIPort'] }
$searxPort = 8888; if ($config.ContainsKey('SearxngPort') -and $config['SearxngPort']) { $searxPort = [int]$config['SearxngPort'] }
$researchPort = 0; if ($config.ContainsKey('DeepResearchPort') -and $config['DeepResearchPort']) { $researchPort = [int]$config['DeepResearchPort'] }
$userProfile = $env:USERPROFILE; if (-not $userProfile) { $userProfile = $HOME }
$modelDir = ''
if ($config.ContainsKey('ModelDir') -and $config['ModelDir']) { $modelDir = [string]$config['ModelDir'] }
if (-not $modelDir -and $onWindows) { try { $modelDir = [string][Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User') } catch { $modelDir = '' } }
if (-not $modelDir -and $userProfile) { $modelDir = Join-Path $userProfile '.ollama' }

# What the report and the console must not show.
$redactUsers = @(@($env:USERNAME, $env:USER, [Environment]::UserName) | Where-Object { $_ })
if ($userProfile) { $redactUsers += (Split-Path -Leaf $userProfile) }
$redactComputers = @(@($env:COMPUTERNAME, [Environment]::MachineName) | Where-Object { $_ })
$redactPaths = @(@($env:USERPROFILE, $HOME) | Where-Object { $_ })
function Protect-Out([string]$Text) { Protect-PcsText -Text $Text -UserNames $redactUsers -ComputerNames $redactComputers -Paths $redactPaths }

$isElevated = $false
if ($onWindows) {
    try { $isElevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $isElevated = $false }
}
$needAdmin = 'needs an elevated window (right-click Start menu > Local AI - Security check > More > Run as administrator)'
$winOnly = 'Windows-only check'

$results = New-Object System.Collections.ArrayList
$sections = New-Object System.Collections.ArrayList
function Add-ReportSection([string]$Title, [string[]]$Lines) { [void]$sections.Add([pscustomobject]@{ Title = $Title; Lines = @($Lines) }) }
function Add-Check {
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = @(& $Body | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Status') }) | Select-Object -Last 1
        if ($null -eq $r) { $r = @{ Status = 'PASS'; Detail = ''; Fix = '' } }
    } catch {
        # One failing query must not end the run: report it and go on.
        $r = @{ Status = 'SKIP'; Detail = "could not be read ($($_.Exception.Message))"; Fix = '' }
    }
    $detail = Protect-Out ([string]$r.Detail)
    $fix = Protect-Out ([string]$r.Fix)
    [void]$results.Add([pscustomobject]@{ Check = $Name; Status = $r.Status; Detail = $detail; Fix = $fix })
    $level = @{ PASS = 'OK'; WARN = 'WARN'; FAIL = 'FAIL'; SKIP = 'INFO' }[$r.Status]
    Write-LaiLog $level ('{0,-4} {1}: {2}' -f $r.Status, $Name, $detail)
    if ($fix -and ($r.Status -eq 'WARN' -or $r.Status -eq 'FAIL')) { Write-LaiLog $level ('     Next step: {0}' -f $fix) }
}
function Pass([string]$d) { @{ Status = 'PASS'; Detail = $d; Fix = '' } }
function Fail([string]$d, [string]$f) { @{ Status = 'FAIL'; Detail = $d; Fix = $f } }
function Warn([string]$d, [string]$f) { @{ Status = 'WARN'; Detail = $d; Fix = $f } }
function Skip([string]$d) { @{ Status = 'SKIP'; Detail = $d; Fix = '' } }

Write-LaiLog STEP 'PC security check (read-only: nothing on this PC is changed)'
if ($onWindows -and -not $isElevated) { Write-LaiLog INFO "Not elevated: a few checks are skipped. For all of them: $needAdmin." }

# ---- 1. antivirus -----------------------------------------------------------------------------------
Add-Check 'Antivirus' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $mp = $null
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { $mp = $null }
    }
    $mode = ''; if ($mp) { $mode = [string]$mp.AMRunningMode }
    if ($mp -and $mp.AntivirusEnabled -and $mode -notmatch '(?i)passive|not running') {
        if (-not $mp.RealTimeProtectionEnabled) {
            return (Fail 'Microsoft Defender is installed, but real-time protection is OFF' 'Windows Security > Virus & threat protection > Manage settings > turn Real-time protection On')
        }
        $age = [int]$mp.AntivirusSignatureAge
        $issues = @(); $fixes = @()
        if ($age -gt 3) { $issues += "virus definitions are $age days old"; $fixes += 'Windows Security > Virus & threat protection > Protection updates > Check for updates' }
        if (-not $mp.IsTamperProtected) { $issues += 'Tamper Protection is off (malware can switch Defender off)'; $fixes += 'Windows Security > Virus & threat protection > Manage settings > Tamper Protection On' }
        if ($issues.Count) { return (Warn ('Microsoft Defender real-time protection is on, but ' + ($issues -join '; ')) ($fixes -join '; then ')) }
        return (Pass "Microsoft Defender on (real-time protection, Tamper Protection, definitions $age day(s) old)")
    }
    # Defender passive (another antivirus took over) or absent: ask Windows Security Center.
    $products = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -OperationTimeoutSec 30 -ErrorAction Stop)
    $active = @(); $stale = @()
    foreach ($p in $products) {
        $st = ConvertFrom-PcsAvState -State ([long]$p.productState)
        if ($st.Enabled) { $active += [string]$p.displayName; if (-not $st.UpToDate) { $stale += [string]$p.displayName } }
    }
    if ($active.Count -eq 0) {
        return (Fail "no antivirus with real-time protection on (registered: $(if ($products.Count) { @($products | ForEach-Object { [string]$_.displayName }) -join ', ' } else { 'none' }))" 'Windows Security > Virus & threat protection: turn Microsoft Defender on, or open your own antivirus and switch its protection on')
    }
    if ($stale.Count) { return (Warn "$($stale -join ', ') is on, but Windows reports its definitions out of date" 'open that antivirus and run its update') }
    Pass "$($active -join ', ') on (Microsoft Defender is passive: $mode)"
}

# ---- 2. Windows Update ------------------------------------------------------------------------------
Add-Check 'Windows updates installed recently' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $dated = @()
    foreach ($h in @(Get-HotFix -ErrorAction Stop)) {
        $on = $null
        try { $on = $h.InstalledOn } catch { $on = $null }
        if ($on -is [datetime]) { $dated += [pscustomobject]@{ Id = [string]$h.HotFixID; On = $on } }
    }
    if ($dated.Count -eq 0) { return (Skip 'Windows lists no installed update with a date') }
    $newest = $dated | Sort-Object { $_.On } -Descending | Select-Object -First 1
    $days = [int][Math]::Floor(((Get-Date) - $newest.On).TotalDays)
    if ($days -gt 35) { return (Warn "the newest installed update ($($newest.Id)) is $days days old; Windows normally installs one every month" 'Settings > Windows Update > Check for updates (and Resume updates if they are paused)') }
    Pass "newest update $($newest.Id) installed $days day(s) ago"
}
Add-Check 'Restart to finish updates' {
    if (-not $onWindows) { return (Skip $winOnly) }
    # The keys Windows sets while an update waits for a restart (Component Based Servicing, Windows
    # Update). PendingFileRenameOperations alone is left out: many installers set it and it means little.
    $why = @()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $why += 'a Windows component update' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $why += 'Windows Update' }
    if ($why.Count) { return (Warn "a restart is pending for $($why -join ' and '); the update is not in force until then" 'save your work and restart the PC (Start > Power > Update and restart)') }
    Pass 'no restart pending'
}

# ---- 3. firewall ------------------------------------------------------------------------------------
Add-Check 'Firewall on for every network type' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $fwProfiles = $null
    # ActiveStore = what is in force (a group policy can override the local settings).
    try { $fwProfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop) } catch { $fwProfiles = @(Get-NetFirewallProfile -ErrorAction Stop) }
    $off = @($fwProfiles | Where-Object { [string]$_.Enabled -ne 'True' } | ForEach-Object { [string]$_.Name })
    if ($off.Count) { return (Fail "Windows Firewall is OFF for: $($off -join ', ')" 'Windows Security > Firewall & network protection > turn Microsoft Defender Firewall On for Domain, Private and Public network') }
    Pass "on for $(@($fwProfiles | ForEach-Object { [string]$_.Name }) -join ', ')"
}

# ---- 4. UAC -----------------------------------------------------------------------------------------
Add-Check 'User Account Control' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lua = Get-PcsRegValue $key 'EnableLUA'
    $cpba = Get-PcsRegValue $key 'ConsentPromptBehaviorAdmin'
    $fix = 'Control Panel > User Accounts > Change User Account Control settings > move the slider to the second step from the top (the default), OK, then restart'
    if ($null -ne $lua -and [int]$lua -eq 0) { return (Fail 'User Account Control is switched off (EnableLUA = 0): every program runs with full administrator rights' $fix) }
    if ($null -ne $cpba -and [int]$cpba -eq 0) { return (Fail 'User Account Control never asks (ConsentPromptBehaviorAdmin = 0): any program you start can take administrator rights silently' $fix) }
    $c = 5; if ($null -ne $cpba) { $c = [int]$cpba }
    Pass "on (EnableLUA = 1, ConsentPromptBehaviorAdmin = $c)"
}

# ---- 5. core isolation -----------------------------------------------------------------------------
# https://learn.microsoft.com/en-us/windows/security/hardware-security/enable-virtualization-based-protection-of-code-integrity
# SecurityServicesRunning contains 2 = memory integrity (hypervisor-enforced code integrity) running.
Add-Check 'Core isolation: memory integrity' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $fix = 'Windows Security > Device security > Core isolation details > Memory integrity On, then restart. If Windows refuses, that page names the incompatible driver (often an old RGB, fan or overclocking tool; see the driver check below): update or remove that tool first'
    $dg = $null
    try { $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -OperationTimeoutSec 30 -ErrorAction Stop } catch { $dg = $null }
    if ($dg) {
        if (@(@($dg.SecurityServicesRunning) | Where-Object { [int]$_ -eq 2 }).Count) { return (Pass 'running') }
        return (Warn 'memory integrity is not running, so a vulnerable or malicious driver can tamper with Windows itself' $fix)
    }
    # Unreadable: the setting itself (configured, not proof that it runs).
    $en = Get-PcsRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
    if ($null -ne $en -and [int]$en -eq 1) { return (Pass 'switched on (running state not readable here)') }
    if ($null -ne $en) { return (Warn 'memory integrity is switched off' $fix) }
    Skip "state not readable; $needAdmin"
}
# https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/design/microsoft-recommended-driver-block-rules
# On by default since Windows 11 22H2; VulnerableDriverBlocklistEnable = 0 switches it off.
Add-Check 'Microsoft vulnerable driver blocklist' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $v = Get-PcsRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable'
    if ($null -ne $v -and [int]$v -eq 0) { return (Warn 'the blocklist is switched off, so drivers Microsoft knows to be abusable can load' 'Windows Security > Device security > Core isolation details > Microsoft Vulnerable Driver Blocklist On') }
    if ($null -eq $v) { return (Pass 'on (Windows 11 default; not set otherwise)') }
    Pass 'on'
}

# https://learn.microsoft.com/en-us/windows-server/security/credentials-protection-and-management/configuring-additional-lsa-protection
# RunAsPPL 1 = on with a UEFI lock, 2 = on without it (the Windows Security switch). Works on Home.
Add-Check 'Local Security Authority protection' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $v = Get-PcsRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'
    if ($null -ne $v -and @(1, 2) -contains [int]$v) { return (Pass 'on (password-stealing tools cannot read the sign-in process)') }
    Warn 'off, so malware running as administrator can copy sign-in secrets out of memory' 'Windows Security > Device security > Core isolation details > Local Security Authority protection On, then restart'
}
# Ransomware protection. 0 off, 1 on, 2 audit only (3/4: disk-sector modes).
Add-Check 'Ransomware protection (Controlled Folder Access)' {
    if (-not $onWindows) { return (Skip $winOnly) }
    if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { return (Skip 'Microsoft Defender settings not readable (another antivirus may be in charge)') }
    $pref = Get-MpPreference -ErrorAction Stop
    $mode = [int]$pref.EnableControlledFolderAccess
    $fix = 'Windows Security > Virus & threat protection > Manage ransomware protection > Controlled folder access On; add C:\AI\Backups under Protected folders; if it blocks a program you trust (ComfyUI saving images, a game saving files), allow that program from the same page'
    if ($mode -eq 1) { return (Pass 'on') }
    if ($mode -eq 2) { return (Warn 'in audit mode only (it reports but blocks nothing)' $fix) }
    Warn 'off, so ransomware can encrypt Documents, Pictures and the backups like any other file' $fix
}

# ---- 6. Secure Boot and TPM ------------------------------------------------------------------------
Add-Check 'Secure Boot' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $fix = 'turn Secure Boot on in the PC''s UEFI setup (Settings > System > Recovery > Advanced startup > Restart now > Troubleshoot > Advanced options > UEFI Firmware Settings; usually under Boot or Security). Windows must be installed in UEFI mode for it'
    $v = Get-PcsRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
    if ($null -ne $v) {
        if ([int]$v -eq 1) { return (Pass 'on') }
        return (Warn 'Secure Boot is off: malware that starts before Windows is not stopped' $fix)
    }
    if (-not $isElevated) { return (Skip $needAdmin) }
    try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop }
    catch {
        if ($_.Exception.Message -match '(?i)not supported') { return (Warn 'this PC starts in legacy BIOS mode, which has no Secure Boot' $fix) }
        throw
    }
    if ($sb) { return (Pass 'on') }
    Warn 'Secure Boot is off: malware that starts before Windows is not stopped' $fix
}
Add-Check 'TPM' {
    if (-not $onWindows) { return (Skip $winOnly) }
    if (-not $isElevated) { return (Skip $needAdmin) }
    $t = Get-Tpm -ErrorAction Stop
    $fix = 'turn on the firmware TPM in the PC''s UEFI setup (AMD: fTPM, Intel: PTT; Settings > System > Recovery > Advanced startup > UEFI Firmware Settings)'
    if (-not $t.TpmPresent) { return (Warn 'no TPM found: drive encryption and Windows Hello cannot protect their keys with it' $fix) }
    if (-not $t.TpmReady) { return (Warn 'a TPM is present but not ready for use' 'Windows Security > Device security > Security processor details > Security processor troubleshooting (or run tpm.msc to see why)') }
    Pass 'present and ready'
}

# ---- 7. drive encryption ---------------------------------------------------------------------------
Add-Check 'Drive encryption' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $drives = @()
    foreach ($d in @((Get-PcsDriveOf $env:SystemDrive), (Get-PcsDriveOf $AIRoot), (Get-PcsDriveOf $modelDir))) { if ($d -and $drives -notcontains $d) { $drives += $d } }
    $homeNote = 'on Windows 11 Home it is called Device encryption: Settings > Privacy & security > Device encryption'
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) { return (Skip "BitLocker tools not available on this Windows; $homeNote") }
    if (-not $isElevated) { return (Skip "$needAdmin; checks $($drives -join ', ') ($homeNote)") }
    $plain = @(); $ok = @()
    foreach ($d in $drives) {
        $v = Get-BitLockerVolume -MountPoint $d -ErrorAction Stop
        $vs = [string]$v.VolumeStatus; $ps = [string]$v.ProtectionStatus
        if ($vs -eq 'FullyEncrypted' -and $ps -eq 'On') { $ok += $d }
        elseif ($vs -eq 'FullyEncrypted' -or $vs -eq 'EncryptionInProgress') { $plain += "$d ($vs, protection $ps)" }
        else { $plain += "$d (not encrypted)" }
    }
    $what = @('Windows')
    if ((Get-PcsDriveOf $AIRoot) -ne (Get-PcsDriveOf $env:SystemDrive)) { $what += 'the AI folder' }
    if ($modelDir -and (Get-PcsDriveOf $modelDir) -ne (Get-PcsDriveOf $env:SystemDrive)) { $what += 'the models' }
    if ($plain.Count) {
        return (Warn "$($plain -join ', '): anyone who takes the PC or the drive can read your chats, documents and passwords stored on it" "Control Panel > System and Security > BitLocker Drive Encryption > Turn on BitLocker for each drive listed ($homeNote). Save the recovery key in your Microsoft account or print it first")
    }
    Pass "encrypted and protected: $($ok -join ', ') ($($what -join ', '))"
}

# ---- 8. Smart App Control and SmartScreen ----------------------------------------------------------
# VerifiedAndReputablePolicyState: 0 off, 1 on (enforced), 2 evaluation.
# https://n4r1b.com/posts/2022/08/smart-app-control-internals-part-1/
Add-Check 'Smart App Control (information)' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $v = Get-PcsRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' 'VerifiedAndReputablePolicyState'
    if ($null -eq $v) { return (Pass 'not available on this Windows (it needs a clean Windows 11 install)') }
    switch ([int]$v) {
        0 { return (Pass 'off (common on PCs that run developer and AI tools)') }
        1 { return (Pass 'on: unknown and unsigned programs are blocked (it may also block some AI tools)') }
        2 { return (Pass 'evaluation: Windows is still deciding whether to turn it on') }
    }
    Pass "state $v"
}
Add-Check 'SmartScreen for apps and files' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $fix = 'Windows Security > App & browser control > Reputation-based protection settings > Check apps and files On'
    $pol = Get-PcsRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
    if ($null -ne $pol -and [int]$pol -eq 0) { return (Warn 'SmartScreen is switched off by a policy: downloaded programs are not checked before they run' "$fix (a policy set it off: Local Group Policy Editor > Computer Configuration > Administrative Templates > Windows Components > File Explorer > Configure Windows Defender SmartScreen = Not configured)") }
    $v = Get-PcsRegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
    if ([string]$v -eq 'Off') { return (Warn 'SmartScreen for apps and files is off: downloaded programs are not checked before they run' $fix) }
    if ($null -eq $v) { return (Pass 'on (Windows default)') }
    Pass "on ($v)"
}

# ---- 9. vulnerable kernel drivers -----------------------------------------------------------------
Add-Check 'Known-vulnerable drivers (RGB, fan, overclocking tools)' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $drv = @(Get-CimInstance -ClassName Win32_SystemDriver -OperationTimeoutSec 60 -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; PathName = [string]$_.PathName; State = [string]$_.State } })
    $apps = @(); try { $apps = @(Get-PcsInstalledApp) } catch { $apps = @() }
    $hits = @(Find-PcsRiskyDriver -Drivers $drv -Apps $apps)
    $open = @($hits | Where-Object { -not $_.Fixed })
    $done = @($hits | Where-Object { $_.Fixed })
    $lines = @($hits | ForEach-Object { '{0} ({1}) - usually from {2}; {3}{4}' -f $_.Driver, $(if ($_.Running) { 'loaded' } else { "installed, $($_.State)" }), $_.App, $_.Cve, $(if ($_.Fixed) { "; fixed version present ($($_.FixedBy))" } else { '' }) })
    if ($lines.Count) { Add-ReportSection 'Vulnerable drivers found' $lines }
    $fixedNote = ''
    if ($done.Count) { $fixedNote = "; up to date: $(@($done | ForEach-Object { "$($_.Driver) ($($_.FixedBy))" }) -join ', ')" }
    if ($open.Count) {
        $txt = @($open | ForEach-Object { '{0} ({1}, usually from {2}; {3})' -f $_.Driver, $(if ($_.Running) { 'loaded' } else { 'installed' }), $_.App, $_.Cve }) -join '; '
        $fx = @($open | ForEach-Object { "$($_.Driver): $($_.Fix)" } | Select-Object -Unique) -join '. '
        return (Warn "$txt$fixedNote. Any program on this PC can use such a driver to take over Windows" $fx)
    }
    Pass "none of WinRing0, RTCore64, CorsairLLAccess, AsIO2/AsIO3 or gdrv is installed$fixedNote"
}

# ---- 10. remote access surface ----------------------------------------------------------------------
Add-Check 'Remote Desktop' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $v = Get-PcsRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
    if ($null -ne $v -and [int]$v -eq 0) { return (Warn 'Remote Desktop is on: this PC accepts remote sign-ins (port 3389)' 'if you do not connect to this PC from another computer: Settings > System > Remote Desktop > Off. If you do, keep it on with a strong password and Network Level Authentication') }
    Pass 'off'
}
Add-Check 'SMBv1 file sharing' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $cfg = $null
    try { $cfg = Get-SmbServerConfiguration -ErrorAction Stop }
    catch {
        if (-not $isElevated) { return (Skip $needAdmin) }
        throw
    }
    if ($cfg.EnableSMB1Protocol) { return (Warn 'the old SMBv1 file-sharing protocol is on (used by WannaCry-style worms)' 'Control Panel > Programs > Turn Windows features on or off > untick SMB 1.0/CIFS File Sharing Support, OK, restart') }
    Pass 'off'
}

$script:listeners = $null
$aiPorts = @(11434, $webPort, $searxPort, 8188, 8000, 2375)
if ($researchPort -gt 0) { $aiPorts += $researchPort }
$aiPorts = @($aiPorts | Select-Object -Unique)
Add-Check 'AI ports reachable only from this PC' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $names = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $names[[int]$p.Id] = [string]$p.ProcessName }
    $script:listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | ForEach-Object {
            $procName = ''; if ($names.ContainsKey([int]$_.OwningProcess)) { $procName = $names[[int]$_.OwningProcess] }
            [pscustomobject]@{ Port = [int]$_.LocalPort; Address = [string]$_.LocalAddress; Process = $procName }
        })
    $exp = Get-PcsExposedPort -Listeners $script:listeners -CriticalPorts $aiPorts
    if ($exp.Critical.Count -eq 0) { return (Pass "$($aiPorts -join ', ') not reachable from the network (loopback only or closed)") }
    $fixes = @()
    $ports = @($exp.Critical | ForEach-Object { [int](($_ -split '@')[0]) })
    if ($ports -contains 11434) { $fixes += 'Ollama (11434): Ollama app > Settings > turn off Expose Ollama to the network, then Start menu > Local AI - Update toolkit' }
    if (@($ports | Where-Object { @($webPort, $searxPort, $researchPort) -contains $_ }).Count) { $fixes += 'Open WebUI / SearXNG: run Start menu > Local AI - Update toolkit (it binds them to 127.0.0.1 again)' }
    if (@($ports | Where-Object { @(8188, 8000) -contains $_ }).Count) { $fixes += 'ComfyUI (8188/8000): remove --listen from its start options (Comfy Desktop: Settings > Server-Config > Host 127.0.0.1)' }
    if ($ports -contains 2375) { $fixes += 'Docker (2375): Docker Desktop > Settings > General > untick Expose daemon on tcp://localhost:2375 without TLS' }
    $onlyOllama = @($ports | Where-Object { $_ -ne 11434 }).Count -eq 0
    if ($onlyOllama -and (Get-NetFirewallRule -DisplayName 'LocalAI - Block Ollama from LAN' -ErrorAction SilentlyContinue)) {
        return (Warn "Ollama listens on all network adapters ($($exp.Critical -join ', ')), but the toolkit's firewall rule blocks other computers" ($fixes -join '. '))
    }
    Fail "reachable from your network: $($exp.Critical -join ', ') - anyone on the same Wi-Fi or LAN can use them without a password" ($fixes -join '. ')
}
Add-Check 'Other programs reachable from the network' {
    if (-not $onWindows) { return (Skip $winOnly) }
    if ($null -eq $script:listeners) { return (Skip 'listening ports not readable') }
    $exp = Get-PcsExposedPort -Listeners $script:listeners -CriticalPorts $aiPorts
    if ($exp.Other.Count -eq 0) { return (Pass 'only Windows itself listens beyond this PC') }
    Add-ReportSection 'Programs listening beyond this PC (port@address (program))' $exp.Other
    $shown = @($exp.Other | Select-Object -First 12) -join ', '
    if ($exp.Other.Count -gt 12) { $shown += " and $($exp.Other.Count - 12) more (see the report)" }
    Warn "these programs accept connections from other computers (the firewall still decides who gets through): $shown" 'look for programs you do not recognise; Windows Security > Firewall & network protection > Allow an app through firewall shows which ones the firewall lets in: untick any you do not need'
}

# ---- 11. Docker Desktop -----------------------------------------------------------------------------
Add-Check 'Docker Desktop version' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $dd = @(Get-PcsInstalledApp | Where-Object { $_.Name -eq 'Docker Desktop' }) | Select-Object -First 1
    if (-not $dd) { return (Skip 'Docker Desktop is not installed') }
    # CVE-2025-9074 (CVSS 9.3): containers could reach the Docker Engine API and, with the WSL 2
    # backend, the Windows drive; fixed in 4.44.3.
    # https://thehackernews.com/2025/08/docker-fixes-cve-2025-9074-critical.html
    $below = Test-PcsVersionBelow -Version $dd.Version -Minimum '4.44.3'
    if ($null -eq $below) { return (Skip "version not readable ($($dd.Version))") }
    if ($below) { return (Fail "Docker Desktop $($dd.Version) is older than 4.44.3 (CVE-2025-9074: a container can control Docker and read your files)" 'Docker Desktop > Settings (gear) > Software updates > Check for updates, install, restart Docker Desktop') }
    Pass "$($dd.Version) (CVE-2025-9074 fixed in 4.44.3; keep it updated: Settings > Software updates)"
}
Add-Check 'Docker API not exposed without TLS' {
    if (-not $onWindows) { return (Skip $winOnly) }
    if (-not $env:APPDATA) { return (Skip 'no APPDATA folder') }
    $found = $false
    foreach ($f in @('settings-store.json', 'settings.json')) {
        $settingsFile = Join-Path (Join-Path $env:APPDATA 'Docker') $f
        if (-not (Test-Path -LiteralPath $settingsFile)) { continue }
        $found = $true
        $j = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $v = Get-PcsJsonFlag -Object $j -Name 'exposeDockerAPIOnTCP2375'
        if ($v -eq $true) { return (Fail 'Docker Desktop''s Expose daemon on tcp://localhost:2375 without TLS is ON: any program or web page trick on this PC can control Docker without a password' 'Docker Desktop > Settings > General > untick Expose daemon on tcp://localhost:2375 without TLS > Apply & restart') }
        return (Pass "off ($f)")
    }
    if (-not $found) { return (Skip 'no Docker Desktop settings file for this account') }
}

# ---- 12. ComfyUI ------------------------------------------------------------------------------------
$script:comfyRoots = @()
try { $script:comfyRoots = @(Find-PcsComfyRoot -AppData $env:APPDATA -UserProfile $userProfile -Remembered ([string]$config['ComfyUIPath'])) } catch { $script:comfyRoots = @() }
Add-Check 'ComfyUI custom nodes' {
    if ($script:comfyRoots.Count -eq 0) { return (Skip 'ComfyUI not found (Comfy Desktop, Documents\ComfyUI or the portable build)') }
    $all = @(); $lines = @()
    foreach ($root in $script:comfyRoots) {
        $cn = Join-Path $root 'custom_nodes'
        if (-not (Test-Path -LiteralPath $cn)) { continue }
        $nodes = @(Get-ChildItem -LiteralPath $cn -Directory -Force -ErrorAction Stop | Where-Object { $_.Name -ne '__pycache__' } | ForEach-Object { $_.Name })
        $all += $nodes
        $lines += "$root\custom_nodes ($($nodes.Count)):"
        $lines += @($nodes | ForEach-Object { "  - $_" })
    }
    if ($lines.Count) { Add-ReportSection 'ComfyUI custom nodes' $lines }
    # ComfyUI_LLMVISION (June 2024) stole browser passwords and card details through its requirements.
    # https://gigazine.net/gsc_news/en/20240611-comfyui-llmvision-malware
    # https://404media.co/hackers-target-ai-users-with-malicious-stable-diffusion-tool-on-github
    $bad = @($all | Where-Object { $_ -match '(?i)^ComfyUI_LLMVISION' })
    if ($bad.Count) { return (Fail "known malicious custom node installed: $($bad -join ', ') (it steals saved browser passwords and card details)" 'delete that folder from custom_nodes, run a full scan (Windows Security > Virus & threat protection > Scan options > Full scan), then change the passwords saved in your browsers and turn on two-step sign-in for your important accounts') }
    $sample = @($all | Select-Object -First 10) -join ', '
    if ($all.Count -gt 10) { $sample += ', ...' }
    Pass "$($all.Count) custom node(s)$(if ($all.Count) { ": $sample" }). Custom nodes run with your full user rights: install only ones you trust (the full list is in the report)"
}
Add-Check 'ComfyUI model files in pickle format' {
    if ($script:comfyRoots.Count -eq 0) { return (Skip 'ComfyUI not found') }
    $files = @(); $truncated = $false; $roots = @()
    foreach ($root in $script:comfyRoots) {
        $modelsDir = Join-Path $root 'models'
        if (-not (Test-Path -LiteralPath $modelsDir)) { continue }
        $roots += $modelsDir
        $scan = Get-PcsPickleFile -Root $modelsDir -MaxDepth 8 -MaxSeconds 20
        $files += @($scan.Files | ForEach-Object { $_.Substring($modelsDir.Length).TrimStart([char]'\', [char]'/') })
        if ($scan.Truncated) { $truncated = $true }
    }
    if ($roots.Count -eq 0) { return (Skip 'no models folder') }
    $cut = ''; if ($truncated) { $cut = ' (scan stopped at its time/depth limit; there may be more)' }
    if ($files.Count -eq 0) { return (Pass "no .ckpt/.pt/.pth/.bin files$cut") }
    $first = @($files | Select-Object -First 10)
    Add-ReportSection 'ComfyUI pickle-format model files (first 10)' $first
    Warn "$($files.Count) model file(s) in a pickle-based format (.ckpt .pt .pth .bin), e.g. $($first -join ', ')$cut. Loading such a file can run code hidden in it" 'prefer .safetensors downloads; keep pickle files only from sources you trust (well-known authors on Hugging Face or Civitai) and delete the ones you do not use'
}

# ---- 13. toolkit secrets ----------------------------------------------------------------------------
Add-Check 'Toolkit Secrets folder private' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $dir = Join-Path $AIRoot 'Secrets'
    if (-not (Test-Path -LiteralPath $dir)) { return (Skip "no $dir (the toolkit is not installed here)") }
    $acl = Get-Acl -LiteralPath $dir -ErrorAction Stop
    $rules = @($acl.Access | ForEach-Object {
            $sid = ''
            try { $sid = $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { $sid = [string]$_.IdentityReference }
            [pscustomobject]@{ Sid = $sid; Type = [string]$_.AccessControlType; Who = [string]$_.IdentityReference }
        })
    $ownerSid = ''; try { $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { $ownerSid = '' }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $v = Get-PcsAclVerdict -Rules $rules -CurrentSid $me -OwnerSid $ownerSid
    $fix = 'run Start menu > Local AI - Update toolkit: the installer limits the Secrets folder to your account, Administrators and SYSTEM again'
    if ($v.Status -eq 'FAIL') { return (Fail "$dir (admin password, keys) is also readable by: $($v.Bad -join ', ')" $fix) }
    if ($v.Status -eq 'WARN') { return (Warn "$dir is limited to another account ($($v.Bad -join ', ')); run this check from the account that installed the toolkit" $fix) }
    Pass "$dir only for your account, Administrators and SYSTEM"
}

# ---- 14. account --------------------------------------------------------------------------------------
Add-Check 'Daily account type' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $admin = $isElevated
    if (-not $admin) {
        # A UAC-filtered token still lists Administrators (as deny-only); whoami shows SIDs in any language.
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $g = (& whoami.exe /groups /fo csv 2>$null) -join "`n" } finally { $ErrorActionPreference = $prev }
        if ($g -match 'S-1-5-32-544') { $admin = $true }
    }
    if ($admin) { return (Warn 'you are signed in with an administrator account: a program you start by mistake needs only one Yes to change Windows' 'optional but safer: Settings > Accounts > Other users > Add account to create a second administrator, then change your everyday account to Standard user (Change account type); UAC then asks for that password instead') }
    Pass 'standard account (administrator rights need a separate password)'
}
Add-Check 'This window' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $n = @($results | Where-Object { $_.Status -eq 'SKIP' -and $_.Detail -like '*elevated window*' }).Count
    if ($isElevated) { return (Pass 'elevated: every check ran') }
    if ($n -gt 0) { return (Skip "not elevated: $n check(s) above were skipped; for all of them: $needAdmin") }
    Pass 'not elevated (nothing needed it)'
}

# ---- summary and report ------------------------------------------------------------------------------
$fails = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warns = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
$summary = "PC SECURITY CHECK COMPLETE: $($results.Count) checks, $warns warnings, $fails failures"
Write-Host ''
$sumLevel = 'OK'; if ($warns) { $sumLevel = 'WARN' }; if ($fails) { $sumLevel = 'FAIL' }
Write-LaiLog $sumLevel $summary

if (-not $ReportPath) { $ReportPath = Join-Path (Join-Path $AIRoot 'Logs') ('pc-security-{0}.md' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$cell = { param([string]$s) (([string]$s) -replace '\|', '\|' -replace "`r?`n", ' ') }
$md = New-Object System.Collections.Generic.List[string]
$md.Add('# PC security check')
$md.Add('')
$winText = 'not Windows'
if ($onWindows) {
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [string](Get-PcsRegValue $cv 'CurrentBuild')
    $name = 'Windows 10'; if ($build -and [int]$build -ge 22000) { $name = 'Windows 11' }
    $winText = ('{0} {1} {2} (build {3}.{4})' -f $name, (Get-PcsRegValue $cv 'EditionID'), (Get-PcsRegValue $cv 'DisplayVersion'), $build, (Get-PcsRegValue $cv 'UBR'))
}
$md.Add(('{0} - {1}, {2} window. Read-only: this check changed nothing on the PC.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $winText, $(if ($isElevated) { 'elevated' } else { 'normal (not elevated)' })))
$md.Add('')
$md.Add("**$summary**")
$md.Add('')
$md.Add('| Result | Check | Details | What to do |')
$md.Add('|---|---|---|---|')
foreach ($r in $results) { $md.Add(('| {0} | {1} | {2} | {3} |' -f $r.Status, (& $cell $r.Check), (& $cell $r.Detail), (& $cell $r.Fix))) }
foreach ($s in $sections) {
    $md.Add('')
    $md.Add("## $($s.Title)")
    $md.Add('')
    foreach ($l in $s.Lines) { $md.Add($(if ($l -match '^\s+- ') { $l } else { "- $l" })) }
}
$md.Add('')
$md.Add('PASS = fine, WARN = worth fixing, FAIL = fix soon, SKIP = not checked (the reason is given). Run it again after a fix: Start menu > Local AI - Security check.')
$text = Protect-Out ($md -join "`r`n")
try {
    $dir = Split-Path -Parent $ReportPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
    [System.IO.File]::WriteAllText($ReportPath, $text + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-LaiLog INFO ('Report: {0}' -f (Protect-Out $ReportPath))
} catch {
    Write-LaiLog WARN ('Could not write the report to {0}: {1}' -f (Protect-Out $ReportPath), $_.Exception.Message)
}
exit $fails
