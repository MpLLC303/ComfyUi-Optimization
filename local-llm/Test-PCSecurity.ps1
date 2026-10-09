#Requires -Version 5.1

<#
.SYNOPSIS
    Read-only security check of this Windows PC for the local AI stack. It changes nothing.

.DESCRIPTION
    Checks what matters for a home PC that runs Ollama, Open WebUI, SearXNG, ComfyUI and RGB/fan
    tools, and says for every problem one next step you can follow yourself:

      antivirus (Microsoft Defender or the product Windows Security knows; an antivirus that is
      registered but snoozed or expired while Defender stands back counts as none, and one left
      behind snoozed, expired or out of date while Defender protects is named), Windows Update and
      a pending restart, the firewall, User Account Control, Core isolation (memory integrity) and the
      Microsoft vulnerable driver blocklist, Secure Boot and the TPM, drive encryption (system drive,
      the install folder's drive, the Ollama models' drive), Smart App Control and SmartScreen, known
      vulnerable kernel drivers that RGB/fan/overclocking tools install, hardware-access drivers of
      such tools that any program can open, Remote Desktop, SMBv1, programs listening beyond this PC
      (the AI ports must not), firewall rules that let other computers reach a script runner (python,
      node, PowerShell and the like), Docker Desktop's version and its unprotected API setting, ComfyUI
      custom nodes and pickle-format model files, the toolkit's Secrets folder permissions, a
      cloud-sync program (OneDrive) that holds the backups but is not running, and whether you use an
      administrator account day to day.

    Only reads: registry values, CIM/WMI queries, Get-* cmdlets, folder listings and permissions. One
    check goes a step further and is still look-only: for a listed hardware-access driver that is
    loaded, it opens the driver's device without read or write access and closes it at once (in a
    normal window only). It never changes a setting, starts or stops anything, or contacts the
    internet. Every check is wrapped: a query that fails becomes SKIP, never an error that stops the run.

    No single window makes every check, and each check says which one it needs. Use
    a normal window for the driver test (the hardware-access drivers any program can open) and
    Run as administrator for TPM, drive encryption and SMBv1 (on some PCs also for Secure Boot):
    right-click Start menu > Local AI - Security check > More > Run as administrator.

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
    # State is an unofficial reading too, the one community scripts share: the 0xF000 nibble as a
    # whole is 0x0000 off, 0x1000 on, 0x2000 snoozed, 0x3000 expired. The four names are the documented
    # ones (WSC_SECURITY_PRODUCT_STATE in the Windows SDK's iwscapi.h: on, off, snoozed, expired); that
    # the number carries them in these values is not documented. So any other nibble is 'Unknown',
    # and whoever asks must count such a product as not checked, neither as on nor as off.
    # Enabled is true for 'On' alone: 0x3000 (expired) has the 0x1000 bit set as well, and the bit
    # test used to read an expired antivirus as on.
    param([long]$State)
    $nibble = $State -band 0xF000
    if ($nibble -eq 0x1000) { $name = 'On' }
    elseif ($nibble -eq 0x0000) { $name = 'Off' }
    elseif ($nibble -eq 0x2000) { $name = 'Snoozed' }
    elseif ($nibble -eq 0x3000) { $name = 'Expired' }
    else { $name = 'Unknown' }
    return [pscustomobject]@{ State = $name; Enabled = ($name -eq 'On'); UpToDate = (($State -band 0x10) -eq 0) }
}

function Group-PcsAvProduct {
    <#
    Windows Security Center's antivirus list (displayName, productState, pathToSignedProductExe),
    sorted by what each product reports about itself. Output: On (the names of those that are on),
    Stale (of these, the ones whose definitions Windows reports out of date), Idle (one sentence
    for each that is snoozed, expired or switched off), IdleNames (their names, Microsoft
    Defender's own left out) and Unknown (name and number of each state ConvertFrom-PcsAvState does
    not know). SkipOwn leaves Microsoft Defender's own entry out altogether.
    #>
    param([object[]]$Products = @(), [bool]$SkipOwn = $false)
    $on = @(); $stale = @(); $idle = @(); $idleNames = @(); $unknown = @()
    foreach ($p in @($Products)) {
        if ($null -eq $p) { continue }
        $name = [string]$p.displayName
        if (-not $name) { $name = 'an antivirus without a name' }
        $own = ($name -match '(?i)^(windows|microsoft) defender') -or ([string]$p.pathToSignedProductExe -match '(?i)^windowsdefender:')
        if ($own -and $SkipOwn) { continue }
        $raw = [string]$p.productState
        $state = 'Unknown'; $current = $true
        if ($raw -match '^\d+$') {
            $st = ConvertFrom-PcsAvState -State ([long]$raw)
            $state = $st.State; $current = $st.UpToDate
        }
        if ($state -eq 'On') {
            $on += $name
            if (-not $current) { $stale += $name }
        } elseif ($state -eq 'Snoozed' -or $state -eq 'Expired' -or $state -eq 'Off') {
            $said = "$name is switched off"
            if ($state -eq 'Snoozed') { $said = "$name reports itself snoozed (its protection is paused)" }
            if ($state -eq 'Expired') { $said = "$name reports itself expired" }
            $idle += $said
            if (-not $own) { $idleNames += $name }
        } else {
            $unknown += "$name (productState $raw)"
        }
    }
    return [pscustomobject]@{ On = $on; Stale = $stale; Idle = $idle; IdleNames = $idleNames; Unknown = $unknown }
}

function Get-PcsAvLeftoverNote {
    <#
    What the Antivirus row adds when Microsoft Defender is plainly the antivirus in charge and
    Windows Security Center still lists another one that is not doing its part: snoozed, expired or
    switched off (what a trial that ran out leaves behind once Defender has taken over), on but
    with definitions out of date, or in a state this check cannot read. Products and ProductsRead
    as for Get-PcsAvVerdict; Defender's own entry is left out. Output: the text to append to the
    row's detail, '' when there is nothing to say. It never changes the row's result (Defender is
    doing the protecting). A list or a state that could not be read is named as not checked.
    #>
    param([object[]]$Products = @(), [bool]$ProductsRead = $true)
    if (-not $ProductsRead) { return '; not checked: Windows Security Center could not be asked whether another antivirus is still registered' }
    $g = Group-PcsAvProduct -Products $Products -SkipOwn $true
    $idle = @($g.Idle); $idleNames = @($g.IdleNames); $stale = @($g.Stale); $unknown = @($g.Unknown)
    $note = ''
    if ($idle.Count) {
        $note += "; also registered with Windows but not protecting: $($idle -join '; '). Microsoft Defender is doing the protecting instead. If you no longer use $($idleNames -join ', '), uninstall it completely (Settings > Apps > Installed apps; if it stays listed, use its maker's removal tool); if you do, open it and switch its protection back on (renew it if it has expired)"
    }
    if ($stale.Count) { $note += "; $($stale -join ', ') is on as well, but Windows reports its definitions out of date: open it and run its update, or uninstall it if you no longer use it" }
    if ($unknown.Count) { $note += "; not checked: Windows Security Center reports a state this check cannot read for $($unknown -join ', ')" }
    return $note
}

function Get-PcsAvVerdict {
    <#
    Who protects this PC when Microsoft Defender is not plainly the antivirus in charge.
    Defender: what Defender's own status report answered (AntivirusEnabled,
    RealTimeProtectionEnabled, AMRunningMode), or $null when it gave no answer. Products: Windows
    Security Center's antivirus list (displayName, productState, pathToSignedProductExe);
    ProductsRead = $false when that list could not be read. Output: Status, Detail, Fix.
    When Defender's own report answered, it alone decides Defender, and Defender's entry in the
    Security Center list is left out. Counted, an entry that still reads "on" makes a passive
    Defender behind a snoozed, expired or half-removed antivirus look like a protected PC.
    AMRunningMode: Normal, Passive Mode, SxS Passive Mode and EDR Block Mode are the documented
    values ("Microsoft Defender Antivirus compatibility with other security products",
    https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-compatibility).
    "Not running" is not on that list (unofficial: what Defender answers while it is switched off).
    EDR Block Mode (a managed PC) and any text not named here are not judged: not checked.
    #>
    param($Defender = $null, [object[]]$Products = @(), [bool]$ProductsRead = $true)
    $defOn = $false; $defText = ''; $defWhy = ''
    if ($null -ne $Defender) {
        $mode = ([string]$Defender.AMRunningMode).Trim()
        if ($mode -match '(?i)^(sxs )?passive( mode)?$') {
            $defText = 'Microsoft Defender is in passive mode'
            $defWhy = "$defText (it leaves the protecting to another antivirus)"
        } elseif ($mode -match '(?i)^not running$') {
            $defText = 'Microsoft Defender is not running'
        } elseif (-not $Defender.AntivirusEnabled) {
            $defText = 'Microsoft Defender is switched off'
        } elseif ($mode -eq '' -or $mode -match '(?i)^normal$') {
            # No mode at all: an older Defender that does not report one. Its two switches decide.
            if ($Defender.RealTimeProtectionEnabled) { $defOn = $true } else { $defText = 'Microsoft Defender''s real-time protection is off' }
        } else {
            return [pscustomobject]@{ Status = 'SKIP'; Detail = "Microsoft Defender reports the running mode '$mode', which this check does not judge"; Fix = '' }
        }
        if (-not $defWhy) { $defWhy = $defText }
    }
    $g = Group-PcsAvProduct -Products $Products -SkipOwn ($null -ne $Defender)
    $on = @($g.On); $stale = @($g.Stale); $idle = @($g.Idle); $idleNames = @($g.IdleNames); $unknown = @($g.Unknown)
    $also = ''
    if ($idle.Count) { $also = "; also registered with Windows but not protecting: $($idle -join '; ')" }
    if ($unknown.Count) { $also += "; state not readable for $($unknown -join ', ')" }
    if ($defOn) { return [pscustomobject]@{ Status = 'PASS'; Detail = "Microsoft Defender on (real-time protection)$also"; Fix = '' } }
    if (-not $ProductsRead) {
        $lead = 'Microsoft Defender''s status gave no answer'
        if ($defText) { $lead = $defText }
        return [pscustomobject]@{ Status = 'SKIP'; Detail = "$lead, and Windows Security Center could not be asked whether another antivirus is on"; Fix = '' }
    }
    if ($on.Count) {
        if ($stale.Count) { return [pscustomobject]@{ Status = 'WARN'; Detail = "$($stale -join ', ') is on, but Windows reports its definitions out of date"; Fix = 'open that antivirus and run its update' } }
        $note = ''
        if ($defText) { $note = " ($defText)" }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "$($on -join ', ') on$note$also"; Fix = '' }
    }
    if ($unknown.Count) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = "Windows Security Center reports a state this check cannot read for $($unknown -join ', '), and no other antivirus reports itself on"; Fix = '' }
    }
    $parts = @()
    if ($defWhy) { $parts += $defWhy }
    $parts += $idle
    if ($idle.Count -eq 0) {
        if ($null -ne $Defender) { $parts += 'Windows Security Center lists no other antivirus' } else { $parts += 'Windows Security Center lists no antivirus' }
    }
    $fix = 'Windows Security > Virus & threat protection: turn Microsoft Defender on, or open your own antivirus and switch its protection on'
    if ($idleNames.Count) {
        $fix = "open $($idleNames -join ', ') and switch the protection back on (renew it if it has expired). If you no longer use it, uninstall it completely (Settings > Apps > Installed apps; if it stays listed, use its maker's removal tool) and restart: Microsoft Defender then takes over by itself. Afterwards Windows Security > Virus & threat protection must show the protection on"
    }
    return [pscustomobject]@{ Status = 'FAIL'; Detail = "no antivirus is protecting this PC: $($parts -join '; ')"; Fix = $fix }
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

function Find-PcsOpenDriver {
    <#
    Kernel drivers made to give one utility direct access to the hardware (I/O ports, processor
    registers, memory). When every program may open such a driver's device, every program on the PC
    has that access, not only the utility. A short list of known ones from vendor fan, lighting and
    tuning tools that Find-PcsRiskyDriver does not carry; for these the name alone settles nothing,
    so the one thing that makes them dangerous is tried.
    Input: Win32_SystemDriver-like objects (Name, PathName, State); installed apps (Name,
    InstallLocation); Elevated; DriversRead = $false when the driver list was not readable; Probe, a
    scriptblock that is handed a device name and answers 'opened', 'denied', 'absent' or 'error ...'
    (Test-PcsDeviceOpen, or a canned answer in the tests). The probe is asked only for a listed
    driver that is loaded (State Running), and never when Elevated: an administrator may open every
    device, so the answer would say nothing. Output: Status, Detail, Fix and Hits (one per match).
    opened = WARN; denied = fine; anything else for a loaded driver (not asked, no such device, any
    other answer) = not checked, never fine.
    Sources. Each names the driver, what it hands out, and that an unprivileged user reaches it:
      AsIO.sys, the first ASUS one (Aura Sync, AI Suite, older Armoury Crate): CVE-2018-18535 (processor
        registers) https://nvd.nist.gov/vuln/detail/CVE-2018-18535 and CVE-2018-18536 (I/O ports)
        https://nvd.nist.gov/vuln/detail/CVE-2018-18536 name "the Asusgio low-level driver" of Aura
        Sync 1.07.22 and earlier. That Asusgio is the file AsIO.sys is not in the CVE text
        (unofficial), which is why it is tested here and not listed by name in Find-PcsRiskyDriver.
      GLCKIo.sys (ASUS Aura Sync): CVE-2018-18536 and CVE-2018-18537
        https://nvd.nist.gov/vuln/detail/CVE-2018-18537
      ene.sys / EneIo64.sys (lighting tools for ENE controllers, e.g. G.SKILL Trident Z Lighting
        Control): CVE-2020-12446 https://nvd.nist.gov/vuln/detail/CVE-2020-12446
      MsIo64.sys / MsIo32.sys (Patriot Viper RGB and other lighting tools): CVE-2019-18845
        https://nvd.nist.gov/vuln/detail/CVE-2019-18845
    Device is the name the driver's device answers to (a program opens it as \\.\<Device>; the
    probe asks Windows' own list of device names, see Test-PcsDeviceOpen). The advisories do not all
    spell it out, so these names are unofficial: where one is wrong the probe finds no such device,
    and the driver counts as not checked.
    #>
    param([object[]]$Drivers = @(), [object[]]$Apps = @(), [bool]$Elevated = $false, [scriptblock]$Probe = $null, [bool]$DriversRead = $true)
    $known = @(
        @{ File = '^asio(32|64)?\.sys$'; Service = '^(asusgio|asio)$'; Device = 'Asusgio'; App = 'an ASUS utility such as Aura Sync, AI Suite or Armoury Crate'; AppMatch = '(?i)\b(aura sync|ai suite|armoury crate)\b' }
        @{ File = '^glckio\.sys$'; Service = '^glckio$'; Device = 'GLCKIo'; App = 'ASUS Aura Sync'; AppMatch = '(?i)\baura sync\b' }
        @{ File = '^(ene|eneio(32|64)?)\.sys$'; Service = '^(ene|eneio)$'; Device = 'EneIo'; App = 'a lighting utility for ENE controllers such as G.SKILL Trident Z Lighting Control'; AppMatch = '(?i)trident z lighting' }
        @{ File = '^msio(32|64)\.sys$'; Service = '^msio(32|64)?$'; Device = 'MsIo'; App = 'a lighting utility such as Patriot Viper RGB'; AppMatch = '(?i)viper rgb' }
    )
    if (-not $DriversRead) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'the list of drivers was not readable (see the check above)'; Fix = ''; Hits = @() } }
    $ic = [System.StringComparison]::OrdinalIgnoreCase
    # Paths are compared as text (this also runs on the non-Windows test job): quotes, a leading \??\
    # and a closing backslash off, forward slashes turned.
    $clean = { param([string]$p) ((([string]$p).Trim().Trim('"') -replace '^\\\?\?\\', '') -replace '/', '\').TrimEnd([char]'\') }
    $hits = @()
    foreach ($d in @($Drivers)) {
        if ($null -eq $d) { continue }
        $name = [string]$d.Name
        $path = & $clean ([string]$d.PathName)
        $leaf = $path; $folder = ''
        if ($path -match '^(.*)\\([^\\]+)$') { $folder = $Matches[1]; $leaf = $Matches[2] }
        foreach ($k in $known) {
            if (-not (($leaf -and $leaf -match $k.File) -or ($name -and $name -match $k.Service))) { continue }
            # The program that installed it: the one whose install folder holds the driver, else
            # the installed programs that usually bring it, else only what usually brings it.
            $owner = ''; $best = 0
            foreach ($a in @($Apps)) {
                if ($null -eq $a -or -not $folder) { continue }
                $loc = & $clean ([string]$a.InstallLocation)
                # Not a drive root or the Windows folder: every driver would belong to that program.
                if ($loc.Length -lt 4 -or $loc.Length -le $best -or $loc -match '(?i)^[a-z]:\\windows(\\|$)') { continue }
                if ($folder.Equals($loc, $ic) -or $folder.StartsWith($loc + '\', $ic)) { $owner = [string]$a.Name; $best = $loc.Length }
            }
            $from = "usually from $($k.App)"
            $remove = "the program it came with ($($k.App))"
            if ($owner) {
                $from = "installed by $owner"; $remove = $owner
            } else {
                $present = @($Apps | Where-Object { $_ -and ([string]$_.Name) -match $k.AppMatch } | ForEach-Object { [string]$_.Name } | Select-Object -Unique | Select-Object -First 3)
                if ($present.Count) { $from = "$from; installed here: $($present -join ', ')"; $remove = $present -join ' / ' }
            }
            $running = ([string]$d.State -eq 'Running')
            $result = 'not loaded'
            if ($running -and $Elevated) {
                $result = 'not asked'
            } elseif ($running) {
                $result = 'error (no answer)'
                if ($null -ne $Probe) {
                    try {
                        $answer = @(& $Probe $k.Device)
                        if ($answer.Count) { $result = [string]$answer[$answer.Count - 1] }
                    } catch { $result = "error ($($_.Exception.Message))" }
                }
            }
            $file = $leaf; if (-not $file) { $file = $name }
            $hits += [pscustomobject]@{ Driver = $file; Service = $name; State = [string]$d.State; Running = $running; Device = $k.Device; From = $from; Remove = $remove; Result = $result }
            break
        }
    }
    if ($hits.Count -eq 0) {
        return [pscustomobject]@{ Status = 'PASS'; Detail = 'none of the ones this check knows is installed (ASUS AsIO and GLCKIo, ENE EneIo, MsIo)'; Fix = ''; Hits = @() }
    }
    $opened = @($hits | Where-Object { $_.Result -eq 'opened' })
    $untested = @($hits | Where-Object { $_.Running -and $_.Result -ne 'opened' -and $_.Result -ne 'denied' })
    $notes = @()
    foreach ($h in $untested) {
        if ($h.Result -eq 'absent') { $notes += "$($h.Driver) is loaded, but no device named $($h.Device) was found, which is the name this check knows for it" }
        elseif ($h.Result -ne 'not asked') { $notes += "$($h.Driver) is loaded, but the test ended with: $($h.Result)" }
    }
    $unasked = @($untested | Where-Object { $_.Result -eq 'not asked' } | ForEach-Object { "$($_.Driver) ($($_.From))" })
    if ($unasked.Count) { $notes += "$($unasked -join ', ') is loaded, but this window runs as administrator, and an administrator may open every device. Run the check again without Run as administrator (Start menu > Local AI - Security check)" }
    if ($opened.Count) {
        $what = @($opened | ForEach-Object { "$($_.Driver) (loaded, $($_.From))" }) -join ', '
        $detail = "$what can be opened by any program on this PC without administrator rights. Such a driver gives its own utility direct access to the hardware (I/O ports, processor registers, memory), so every program you run, a malicious one too, can use that access to take over Windows or switch off the antivirus"
        if ($notes.Count) { $detail += ". Not tested: $($notes -join '; ')" }
        $fix = @($opened | ForEach-Object { "$($_.Driver): if you do not use $($_.Remove), uninstall it (Settings > Apps > Installed apps) and restart; the driver goes with it. If you use it, install its newest version and run this check again" }) -join '. '
        return [pscustomobject]@{ Status = 'WARN'; Detail = $detail; Fix = $fix; Hits = $hits }
    }
    if ($untested.Count) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = "not tested: $($notes -join '; ')"; Fix = ''; Hits = $hits }
    }
    $fine = @()
    foreach ($h in $hits) {
        if ($h.Running) { $fine += "$($h.Driver) is loaded ($($h.From)), but its device refused this program, which has no administrator rights, as it should" }
        else { $fine += "$($h.Driver) is installed but not loaded ($($h.From))" }
    }
    return [pscustomobject]@{ Status = 'PASS'; Detail = ($fine -join '; '); Fix = ''; Hits = $hits }
}

function Find-PcsInterpreterRule {
    <#
    Firewall rules that let other computers connect to a program that runs any script handed to it.
    Such a rule is not an opening for one app: every script started with that program can be
    reached. Windows writes one when you answer Allow to its "firewall has blocked some features"
    question while a script is listening.
    Rules: the rule strings as Windows keeps them, one per rule, for example
      v2.30|Action=Allow|Active=TRUE|Dir=In|Protocol=6|Profile=Private|App=C:\Python312\python.exe|Name=python.exe|
    RulesRead = $false when the list was not readable. Output: Status, Detail, Fix and Hits.
    Grammar: [MS-GPFAS] "Group Policy: Firewall and Advanced Security Data Structure", section
    "Firewall Rule and the Firewall Rule Grammar Rule": fields joined by '|'; Action = Allow | Block |
    ByPass; Dir = In | Out; Active = TRUE | FALSE; Profile = Domain | Private | Public, none meaning
    every network; App = the program's path.
    Flagged: Allow + In + TRUE. Not flagged: a rule that says Block, Out or FALSE. Anything else for
    a listed program (ByPass, a missing field, a value not named here) is not judged: not checked.
    #>
    param([string[]]$Rules = @(), [bool]$RulesRead = $true)
    $programs = @('python.exe', 'pythonw.exe', 'node.exe', 'powershell.exe', 'pwsh.exe', 'wscript.exe', 'cscript.exe', 'java.exe')
    if (-not $RulesRead) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'the firewall''s rule list was not readable'; Fix = ''; Hits = @() } }
    $seen = 0; $byApp = @{}; $order = @(); $unclear = @()
    foreach ($text in @($Rules)) {
        if (-not $text) { continue }
        $seen++
        $field = @{}; $nets = @()
        foreach ($part in ($text -split '\|')) {
            if ($part -notmatch '^([A-Za-z0-9_]+)=(.*)$') { continue }
            $key = $Matches[1].ToLowerInvariant(); $value = $Matches[2].Trim()
            if ($key -eq 'profile') { if ($nets -notcontains $value) { $nets += $value } }
            elseif (-not $field.ContainsKey($key)) { $field[$key] = $value }
        }
        if (-not $field.ContainsKey('app')) { continue }
        $app = [string]$field['app']
        $leaf = ''
        if ($app -match '([^\\/]+)$') { $leaf = $Matches[1].ToLowerInvariant() }
        if ($programs -notcontains $leaf) { continue }
        $action = [string]$field['action']; $dir = [string]$field['dir']; $active = [string]$field['active']
        if ($action -eq 'Block' -or $dir -eq 'Out' -or $active -eq 'FALSE') { continue }
        if ($action -eq 'Allow' -and $dir -eq 'In' -and $active -eq 'TRUE') {
            # One program usually has two rules (TCP and UDP): listed once, its networks joined.
            $id = $app.ToLowerInvariant()
            if (-not $byApp.ContainsKey($id)) { $byApp[$id] = @{ Program = $leaf; App = $app; Nets = @(); Every = $false }; $order += $id }
            if ($nets.Count -eq 0) { $byApp[$id]['Every'] = $true }
            foreach ($n in $nets) { if ($byApp[$id]['Nets'] -notcontains $n) { $byApp[$id]['Nets'] = @($byApp[$id]['Nets']) + $n } }
        } elseif ($unclear -notcontains $leaf) {
            $unclear += $leaf
        }
    }
    $hits = @()
    foreach ($id in $order) {
        $h = $byApp[$id]
        $netText = 'every network'
        if (-not $h['Every'] -and @($h['Nets']).Count) { $netText = "$(@($h['Nets']) -join ', ') networks" }
        $hits += [pscustomobject]@{ Program = $h['Program']; App = $h['App']; Networks = $netText; Text = ('{0} ({1}; {2})' -f $h['Program'], $h['App'], $netText) }
    }
    $odd = ''
    if ($unclear.Count) { $odd = "a firewall rule for $($unclear -join ', ') is written in a way this check does not know, so it was not judged" }
    if ($hits.Count) {
        $shown = @($hits | Select-Object -First 6 | ForEach-Object { $_.Text }) -join '; '
        if ($hits.Count -gt 6) { $shown += " and $($hits.Count - 6) more (see the report)" }
        $detail = "the firewall lets other computers connect to $shown. These programs run whatever script they are given, so the opening is not for one app: every script started with them can be reached from the network"
        if ($odd) { $detail += ". Also: $odd" }
        $fix = 'Windows Security > Firewall & network protection > Allow an app through firewall > Change settings: untick these entries (or select one and Remove) unless you run a server with that program on purpose; if you do, leave only Private ticked. The toolkit needs none of them'
        return [pscustomobject]@{ Status = 'WARN'; Detail = $detail; Fix = $fix; Hits = $hits }
    }
    if ($odd) { return [pscustomobject]@{ Status = 'SKIP'; Detail = $odd; Fix = ''; Hits = @() } }
    if ($seen -eq 0) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'Windows lists no firewall rules in the place this check reads them'; Fix = ''; Hits = @() } }
    return [pscustomobject]@{ Status = 'PASS'; Detail = "no rule lets other computers connect to $($programs[0..6] -join ', ') or $($programs[7]) ($seen firewall rules read)"; Fix = ''; Hits = @() }
}

function Get-PcsSyncVerdict {
    <#
    Backups kept inside a cloud-sync folder leave this PC only while that sync program runs. One
    that has a start-with-Windows entry but is not running (signed out, crashed or half-removed)
    uploads nothing, and nothing says so.
    BackupFolders: the folders the toolkit writes backups to. Clients: one object per sync program
    with Name, Process (its process name, without .exe), Folders (its sync folders), StartEntry (its
    start-with-Windows command, '' when it has none) and StartRead ($false when that was not
    readable). Processes: the names of the processes running in the session that asks (what
    Select-PcsSessionProcess keeps); ProcessesRead = $false when unknown. Output: Status, Detail, Fix.
    Reported only for a client whose folder holds a backup folder. "Inside" compares whole folder
    names, so a folder next to it that only starts with the same letters ("OneDriveArchive" beside
    "OneDrive") does not count. Paths are compared as text (this also runs on the non-Windows test
    job). The text names the place below the sync folder only, not the profile path above it.
    The client's folders are those of the account this check runs as. In a window opened with
    another account's administrator password that is the administrator, not the everyday account
    whose folder holds the backups. So a backup folder that is none of the client's folders but lies
    in a folder named like one, directly under a user profile (<drive>:\Users\<name>\OneDrive, or
    "OneDrive - <organisation>" as work accounts have it), is not checked: SKIP, never "not inside".
    #>
    param([string[]]$BackupFolders = @(), [object[]]$Clients = @(), [string[]]$Processes = @(), [bool]$ProcessesRead = $true)
    $ic = [System.StringComparison]::OrdinalIgnoreCase
    $clean = { param([string]$p) ((([string]$p).Trim().Trim('"')) -replace '/', '\').TrimEnd([char]'\') }
    $running = @($Processes | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() -replace '(?i)\.exe$', '' })
    $known = @(); $stopped = @(); $fixes = @(); $unread = @(); $fine = @()
    foreach ($c in @($Clients)) {
        if ($null -eq $c) { continue }
        $name = [string]$c.Name
        $known += $name
        $places = @(); $alike = @()
        foreach ($b in @($BackupFolders)) {
            $bp = & $clean $b
            if (-not $bp) { continue }
            $held = $false
            foreach ($f in @($c.Folders)) {
                $fp = & $clean ([string]$f)
                if ($fp.Length -lt 3) { continue }
                $same = $bp.Equals($fp, $ic)
                if (-not ($same -or $bp.StartsWith($fp + '\', $ic))) { continue }
                $place = "the $name folder itself"
                if (-not $same) { $place = $name + '\' + $bp.Substring($fp.Length + 1) }
                if ($places -notcontains $place) { $places += $place }
                $held = $true
                break
            }
            if ($held -or -not $name) { continue }
            # None of this account's sync folders. Named like one, directly under a user profile?
            $like = [regex]::Match($bp, '(?i)^[A-Za-z]:\\Users\\[^\\]+\\' + [regex]::Escape($name) + '(?: - [^\\]+)?(\\.+)?$')
            if (-not $like.Success) { continue }
            $place = "the $name folder itself"
            if ($like.Groups[1].Success) { $place = $name + $like.Groups[1].Value }
            if ($alike -notcontains $place) { $alike += $place }
        }
        if ($alike.Count) {
            $unread += "the backups lie in $($alike -join ', ') under a user profile; that looks like a $name folder, but not one of the account this check runs as. If it is another account's, run this check from that account in a normal window (without Run as administrator)"
        }
        if ($places.Count -eq 0) { continue }
        $inside = $places -join ', '
        if (-not $ProcessesRead) { $unread += "the backups lie in $inside, but the list of running programs was not readable"; continue }
        if ($running -contains [string]$c.Process) { $fine += "$name is running, and the backups lie in its folder ($inside)"; continue }
        if (-not $c.StartRead) { $unread += "the backups lie in $inside and $name is not running, but whether it is set to start with Windows was not readable"; continue }
        if ([string]$c.StartEntry) {
            $stopped += "$name has a start-with-Windows entry but is not running, and the backups lie in its folder ($inside): nothing uploads them, so they exist on this PC only"
            $fixes += "start $name (Start menu > $name) and wait until its icon near the clock shows it signed in and up to date. If it does not start or asks to be set up again, reinstall it and sign in. If you no longer want $name, keep the backups in a folder outside it (another drive is best)"
        } else {
            $fine += "the backups lie in $inside; $name has no start-with-Windows entry, so it is not expected to run (it uploads them only while you run it)"
        }
    }
    if ($stopped.Count) {
        $detail = $stopped -join '; '
        if ($unread.Count) { $detail += ". Not checked: $($unread -join '; ')" }
        return [pscustomobject]@{ Status = 'WARN'; Detail = $detail; Fix = ($fixes -join '. ') }
    }
    if ($unread.Count) { return [pscustomobject]@{ Status = 'SKIP'; Detail = "not checked: $($unread -join '; ')"; Fix = '' } }
    if ($fine.Count) { return [pscustomobject]@{ Status = 'PASS'; Detail = ($fine -join '; '); Fix = '' } }
    $which = 'a cloud-sync folder'
    if ($known.Count) { $which = "a cloud-sync folder this check knows ($($known -join ', '))" }
    return [pscustomobject]@{ Status = 'PASS'; Detail = "the backup folders are not inside $which, so no sync program has to run for them"; Fix = '' }
}

function Select-PcsSessionProcess {
    <#
    The names of the processes that run in one Windows session (one signed-in account's desktop).
    Windows lists the processes of every session, so with two accounts signed in (fast user
    switching) the other account's OneDrive would pass for this account's.
    Processes: objects with ProcessName and SessionId, as Get-Process gives them. SessionId: the
    session to keep. Output: Read, Names. Read = $false when no process of that session was found:
    whoever asks runs in it, so an empty answer means the session numbers were not readable, and
    the caller must count the list as not read.
    Session 0 is answered the same way, as not read. Since Windows Vista it is the session of the
    services, without a desktop, and the first account to sign in gets session 1 (Microsoft,
    "Session 0 isolation"). A check started there (over SSH, by a service) cannot see from its own
    session whether the account's sync program runs on the desktop.
    #>
    param([object[]]$Processes = @(), $SessionId = $null)
    $names = @()
    $want = [string]$SessionId
    if ($want -match '^\d+$' -and $want.Trim('0') -ne '') {
        foreach ($p in @($Processes)) {
            if ($null -eq $p -or $null -eq $p.SessionId) { continue }
            if ([string]$p.SessionId -ne $want) { continue }
            if ([string]$p.ProcessName) { $names += [string]$p.ProcessName }
        }
    }
    return [pscustomobject]@{ Read = ($names.Count -gt 0); Names = $names }
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
    # DisplayName / DisplayVersion / InstallLocation of installed programs (machine-wide, 32-bit and
    # per-user entries). InstallLocation is '' where the program's installer did not record one.
    $apps = @()
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue)) {
            try { $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop } catch { continue }
            if (-not ($p.PSObject.Properties['DisplayName'] -and $p.DisplayName)) { continue }
            $ver = ''
            if ($p.PSObject.Properties['DisplayVersion'] -and $p.DisplayVersion) { $ver = [string]$p.DisplayVersion }
            $loc = ''
            if ($p.PSObject.Properties['InstallLocation'] -and $p.InstallLocation) { $loc = [string]$p.InstallLocation }
            $apps += [pscustomobject]@{ Name = [string]$p.DisplayName; Version = $ver; InstallLocation = $loc }
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

function Get-PcsAvProduct {
    # Windows Security Center's antivirus list, as Get-PcsAvVerdict wants it (displayName,
    # productState, pathToSignedProductExe). Read = $false when it could not be asked (Windows Server
    # has no Security Center). A standard account may read it.
    try {
        $list = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -OperationTimeoutSec 30 -ErrorAction Stop |
                ForEach-Object { [pscustomobject]@{ displayName = [string]$_.displayName; productState = $_.productState; pathToSignedProductExe = [string]$_.pathToSignedProductExe } })
        return [pscustomobject]@{ Read = $true; Products = $list }
    } catch {
        return [pscustomobject]@{ Read = $false; Products = @() }
    }
}

function ConvertFrom-PcsOpenStatus {
    <#
    Pure (unit-tested). What the status of opening a driver's device says: 'opened', 'denied',
    'absent' (no device of that name) or 'error 0x<status>'. Status is the NTSTATUS that NtOpenFile
    handed back, as the 32-bit number it is (the ones that say "failed" are negative, and PowerShell
    reads 0xC0000022 as that same negative number).
    Read from the status itself, never from the Windows error code it is turned into for a program:
    there 0xC0000022 (the device's own access check refused the caller) and 0xC00000BA (what was
    opened is a folder) are both 5, "access denied". So only 0xC0000022 is 'denied'.
    NTSTATUS values (ntstatus.h; [MS-ERREF] section 2.3.1): 0x00000000 STATUS_SUCCESS;
      0xC0000022 STATUS_ACCESS_DENIED; 0xC0000034 STATUS_OBJECT_NAME_NOT_FOUND and 0xC000003A
      STATUS_OBJECT_PATH_NOT_FOUND = no such device. Any other status is handed on as 'error 0x...'
      and not interpreted: not checked.
    #>
    param([int]$Status)
    if ($Status -eq 0) { return 'opened' }
    if ($Status -eq 0xC0000022) { return 'denied' }
    if ($Status -eq 0xC0000034 -or $Status -eq 0xC000003A) { return 'absent' }
    return ('error 0x{0:X8}' -f $Status)
}

function Test-PcsDeviceOpen {
    <#
    Can this program open a driver's device? Answers 'opened', 'denied', 'absent' (no device of
    that name) or 'error ...'. It opens the device asking for neither read nor write access and
    closes the handle at once, in one call: nothing is sent to the driver and nothing is changed.
    Takes a bare device name only. The answer means something only in a window without
    administrator rights; the caller sees to that.
    The device is opened by its place in Windows' own list of device names, \GLOBAL??\<Device>,
    where a driver puts its name and a program without administrator rights cannot put one. Not as
    \\.\<Device>: that form is looked up among the names of this sign-in session first, and there
    any program may add a name without administrator rights (DefineDosDevice, which is what 'subst'
    uses). The driver's name pointed at a folder that way made this check read 'denied', and so
    fine, while every program could still open the real device. \\.\GLOBALROOT\... is no way round
    it: GLOBALROOT is itself looked up among the session's names first.
    ("Local and Global MS-DOS Device Names",
    https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/local-and-global-ms-dos-device-names )
    NtOpenFile (winternl.h), https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntopenfile ,
    called with what CreateFileW passes on for an open that asks for no access:
      DesiredAccess 0x00100080 = SYNCHRONIZE | FILE_READ_ATTRIBUTES, neither read nor write (the open
      still has to pass the device's own access check); ShareAccess 3 = FILE_SHARE_READ |
      FILE_SHARE_WRITE; OpenOptions 0x60 = FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE;
      in the object attributes 0x40 = OBJ_CASE_INSENSITIVE and no root directory, so the name is the
      whole path. NtOpenFile opens what exists and creates nothing.
    What the status it hands back means: ConvertFrom-PcsOpenStatus.
    #>
    param([string]$Device)
    if ($env:OS -ne 'Windows_NT') { return 'error (not Windows)' }
    if ($Device -notmatch '^[A-Za-z0-9_]{1,64}$') { return 'error (not a device name)' }
    try {
        if (-not ('PcsDevice' -as [type])) {
            $members = @(
                '[System.Runtime.InteropServices.DllImport("ntdll.dll")]'
                'static extern int NtOpenFile(out System.IntPtr FileHandle, uint DesiredAccess, ref OBJECT_ATTRIBUTES ObjectAttributes, out IO_STATUS_BLOCK IoStatusBlock, uint ShareAccess, uint OpenOptions);'
                '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]'
                'static extern bool CloseHandle(System.IntPtr hObject);'
                '[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]'
                'struct UNICODE_STRING { public ushort Length; public ushort MaximumLength; public System.IntPtr Buffer; }'
                '[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]'
                'struct OBJECT_ATTRIBUTES { public uint Length; public System.IntPtr RootDirectory; public System.IntPtr ObjectName; public uint Attributes; public System.IntPtr SecurityDescriptor; public System.IntPtr SecurityQualityOfService; }'
                '[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]'
                'struct IO_STATUS_BLOCK { public System.IntPtr Status; public System.IntPtr Information; }'
                '// The NTSTATUS of the open. 0 = opened, and closed again here. The path is handed over as a'
                '// counted string (its length in bytes, without the closing zero) in memory that is freed here.'
                'public static int TryOpen(string path) {'
                '    System.IntPtr text = System.IntPtr.Zero;'
                '    System.IntPtr namePointer = System.IntPtr.Zero;'
                '    try {'
                '        text = System.Runtime.InteropServices.Marshal.StringToHGlobalUni(path);'
                '        namePointer = System.Runtime.InteropServices.Marshal.AllocHGlobal(System.Runtime.InteropServices.Marshal.SizeOf(typeof(UNICODE_STRING)));'
                '        UNICODE_STRING name;'
                '        name.Length = (ushort)(path.Length * 2);'
                '        name.MaximumLength = (ushort)(path.Length * 2 + 2);'
                '        name.Buffer = text;'
                '        System.Runtime.InteropServices.Marshal.StructureToPtr(name, namePointer, false);'
                '        OBJECT_ATTRIBUTES attributes;'
                '        attributes.Length = (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES));'
                '        attributes.RootDirectory = System.IntPtr.Zero;'
                '        attributes.ObjectName = namePointer;'
                '        attributes.Attributes = 0x40;'
                '        attributes.SecurityDescriptor = System.IntPtr.Zero;'
                '        attributes.SecurityQualityOfService = System.IntPtr.Zero;'
                '        System.IntPtr handle;'
                '        IO_STATUS_BLOCK io;'
                '        int status = NtOpenFile(out handle, 0x00100080, ref attributes, out io, 3, 0x60);'
                '        if (status == 0) { CloseHandle(handle); }'
                '        return status;'
                '    } finally {'
                '        System.Runtime.InteropServices.Marshal.FreeHGlobal(namePointer);'
                '        System.Runtime.InteropServices.Marshal.FreeHGlobal(text);'
                '    }'
                '}'
            ) -join "`n"
            Add-Type -Namespace '' -Name 'PcsDevice' -MemberDefinition $members
        }
        $status = [PcsDevice]::TryOpen('\GLOBAL??\' + $Device)
    } catch {
        return "error ($($_.Exception.Message))"
    }
    return (ConvertFrom-PcsOpenStatus -Status $status)
}

function Get-PcsFirewallRuleText {
    # Every firewall rule as Windows keeps it, one string per rule: this PC's own rules, then the
    # ones a policy sets ([MS-GPFAS] describes the policy key; the PC's own store keeps the same
    # strings). One registry read, not a query per rule. Read = $false when no rule store could be
    # read. A standard account may read both keys.
    $list = New-Object System.Collections.Generic.List[string]
    $read = $false
    try {
        foreach ($k in @('HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules', 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\FirewallRules')) {
            if (-not (Test-Path -LiteralPath $k)) { continue }
            $key = Get-Item -LiteralPath $k -ErrorAction Stop
            foreach ($n in @($key.GetValueNames())) { $list.Add([string]$key.GetValue($n)) }
            $read = $true
        }
    } catch {
        $read = $false
    }
    return [pscustomobject]@{ Read = $read; Rules = $list.ToArray() }
}

function Get-PcsSyncClient {
    # The cloud-sync programs this check knows, as Get-PcsSyncVerdict wants them. OneDrive: its
    # folders are the ones its client puts into the OneDrive, OneDriveConsumer and OneDriveCommercial
    # environment variables of this account; its start-with-Windows entry is the value OneDrive under
    # this account's Run key. Task Manager's Startup apps page can switch such an entry off and leave
    # it in place, so the verdict says "has a start-with-Windows entry", not "starts with Windows".
    $folders = @(@($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial) | Where-Object { $_ } | Select-Object -Unique)
    $entry = ''; $read = $true
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        if (Test-Path -LiteralPath $runKey) {
            $run = Get-ItemProperty -LiteralPath $runKey -ErrorAction Stop
            if ($run -and $run.PSObject.Properties['OneDrive']) { $entry = [string]$run.OneDrive }
        }
    } catch {
        $read = $false
    }
    return [pscustomobject]@{ Name = 'OneDrive'; Process = 'OneDrive'; Folders = $folders; StartEntry = $entry; StartRead = $read }
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
        # The verdict is the last answer with one of the four results. A body that gives none (nothing
        # at all, plain text, a result this script does not know) has checked nothing: never a PASS.
        $r = @(& $Body | Where-Object { $_ -is [hashtable] -and @('PASS', 'WARN', 'FAIL', 'SKIP') -ccontains [string]$_['Status'] }) | Select-Object -Last 1
        if ($null -eq $r) { $r = @{ Status = 'SKIP'; Detail = 'this check gave no answer'; Fix = '' } }
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
function Convert-Verdict($Verdict) {
    # A judge's answer (an object with Status, Detail, Fix) as the hashtable Add-Check keeps. Add-Check
    # takes anything else for no answer, so a status that is none of the four ends here as not checked.
    switch ([string]$Verdict.Status) {
        'PASS' { return (Pass ([string]$Verdict.Detail)) }
        'WARN' { return (Warn ([string]$Verdict.Detail) ([string]$Verdict.Fix)) }
        'FAIL' { return (Fail ([string]$Verdict.Detail) ([string]$Verdict.Fix)) }
        'SKIP' { return (Skip ([string]$Verdict.Detail)) }
    }
    Skip 'the check gave no answer this script understands'
}

Write-LaiLog STEP 'PC security check (read-only: nothing on this PC is changed)'
if ($onWindows -and -not $isElevated) { Write-LaiLog INFO 'Not elevated: this is a normal window for the driver test; use Run as administrator for TPM, drive encryption and SMBv1 (right-click Start menu > Local AI - Security check > More > Run as administrator).' }

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
        # Defender is in charge. Windows Security Center may still list another antivirus that is
        # snoozed, expired or out of date (a trial that ran out, a half-removed product): the row
        # names it and keeps its result. This only reads; Get-PcsAvLeftoverNote judges.
        $left = Get-PcsAvProduct
        $also = Get-PcsAvLeftoverNote -Products $left.Products -ProductsRead $left.Read
        $age = [int]$mp.AntivirusSignatureAge
        $issues = @(); $fixes = @()
        if ($age -gt 3) { $issues += "virus definitions are $age days old"; $fixes += 'Windows Security > Virus & threat protection > Protection updates > Check for updates' }
        if (-not $mp.IsTamperProtected) { $issues += 'Tamper Protection is off (malware can switch Defender off)'; $fixes += 'Windows Security > Virus & threat protection > Manage settings > Tamper Protection On' }
        if ($issues.Count) { return (Warn ('Microsoft Defender real-time protection is on, but ' + ($issues -join '; ') + $also) ($fixes -join '; then ')) }
        return (Pass "Microsoft Defender on (real-time protection, Tamper Protection, definitions $age day(s) old)$also")
    }
    # Defender is not the antivirus in charge (passive, switched off, or its status gave no answer):
    # Windows Security Center knows the others. This only reads; Get-PcsAvVerdict judges. What
    # Defender itself answered goes along, so that its own Security Center entry is not counted: a
    # passive Defender behind a snoozed or expired antivirus used to pass here as "Windows Defender on".
    $seen = $null
    if ($mp) { $seen = [pscustomobject]@{ AntivirusEnabled = [bool]$mp.AntivirusEnabled; RealTimeProtectionEnabled = [bool]$mp.RealTimeProtectionEnabled; AMRunningMode = $mode } }
    $wsc = Get-PcsAvProduct
    Convert-Verdict (Get-PcsAvVerdict -Defender $seen -Products $wsc.Products -ProductsRead $wsc.Read)
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
$script:drivers = $null
$script:apps = @()
Add-Check 'Known-vulnerable drivers (RGB, fan, overclocking tools)' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $drv = @(Get-CimInstance -ClassName Win32_SystemDriver -OperationTimeoutSec 60 -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; PathName = [string]$_.PathName; State = [string]$_.State } })
    $apps = @(); try { $apps = @(Get-PcsInstalledApp) } catch { $apps = @() }
    # The next check works on the same two lists.
    $script:drivers = $drv; $script:apps = $apps
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
# Drivers of the same kind that the list above cannot name by a flaw of their own: the device of each
# loaded one is opened and closed (no read, no write access) to see whether any program may.
Add-Check 'Hardware-access drivers any program can open' {
    if (-not $onWindows) { return (Skip $winOnly) }
    # Never in an elevated window: an administrator may open every device. Find-PcsOpenDriver does
    # not ask the probe then, nor for a driver that is not on its list or not loaded.
    $v = Find-PcsOpenDriver -Drivers @($script:drivers) -Apps @($script:apps) -Elevated $isElevated -DriversRead ($null -ne $script:drivers) -Probe { param($Device) Test-PcsDeviceOpen -Device $Device }
    Convert-Verdict $v
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
    if ($onlyOllama) {
        # A rule of the right name is not yet a block. The module reads the rule (it changes
        # nothing) and judges it, and one answer only keeps this a warning: a rule that is on and
        # blocks by address. One that is switched off or was changed, the older one on the network
        # adapters (a VPN and Tailscale get past it), no rule, and a firewall that could not be
        # asked are failures, each in its own words and with the step that goes with it (the
        # answer's Fix). That step is not Update toolkit alone: the installer makes the rule only
        # where it opened the port itself, so with no rule the Ollama app's own setting comes first.
        $fw = Get-LaiOllamaBlockState
        if ($fw.State -eq 'blocked') {
            return (Warn "Ollama listens on all network adapters ($($exp.Critical -join ', ')), but the toolkit's firewall rule blocks other computers" ($fixes -join '. '))
        }
        return (Fail "Ollama listens beyond this PC itself ($($exp.Critical -join ', ')), and $($fw.Text)" ([string]$fw.Fix))
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
Add-Check 'Firewall openings for script runners' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $fw = Get-PcsFirewallRuleText
    $v = Find-PcsInterpreterRule -Rules $fw.Rules -RulesRead $fw.Read
    if (@($v.Hits).Count) { Add-ReportSection 'Firewall rules that let other computers reach a script runner (program (path; networks))' @($v.Hits | ForEach-Object { [string]$_.Text }) }
    Convert-Verdict $v
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
    foreach ($f in @('settings-store.json', 'settings.json')) {
        $settingsFile = Join-Path (Join-Path $env:APPDATA 'Docker') $f
        if (-not (Test-Path -LiteralPath $settingsFile)) { continue }
        $j = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $v = Get-PcsJsonFlag -Object $j -Name 'exposeDockerAPIOnTCP2375'
        if ($v -eq $true) { return (Fail 'Docker Desktop''s Expose daemon on tcp://localhost:2375 without TLS is ON: any program or web page trick on this PC can control Docker without a password' 'Docker Desktop > Settings > General > untick Expose daemon on tcp://localhost:2375 without TLS > Apply & restart') }
        return (Pass "off ($f)")
    }
    Skip 'no Docker Desktop settings file for this account'
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
# The backups, and the second copy the installer's -BackupMirror names, are off this PC only while
# the sync program whose folder they lie in is running.
Add-Check 'Cloud sync the backups rely on' {
    if (-not $onWindows) { return (Skip $winOnly) }
    $folders = @((Join-Path $AIRoot 'Backups'))
    if ($config.ContainsKey('BackupMirror') -and $config['BackupMirror']) { $folders += [string]$config['BackupMirror'] }
    # Only what runs in this session counts: Get-Process also lists the processes of every other
    # signed-in account, and another account's OneDrive uploads nothing for this one. Where this
    # session's processes cannot be told (Select-PcsSessionProcess says when), the row is not checked.
    $procs = @(); $procsRead = $false
    try {
        $mine = Select-PcsSessionProcess -Processes @(Get-Process -ErrorAction Stop) -SessionId ([System.Diagnostics.Process]::GetCurrentProcess().SessionId)
        $procs = @($mine.Names); $procsRead = [bool]$mine.Read
    } catch { $procsRead = $false }
    Convert-Verdict (Get-PcsSyncVerdict -BackupFolders $folders -Clients @(Get-PcsSyncClient) -Processes $procs -ProcessesRead $procsRead)
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
    if ($isElevated) {
        # One check works the other way round: it tells nothing in an elevated window and asks for a normal one.
        $normalOnly = @($results | Where-Object { $_.Status -eq 'SKIP' -and $_.Detail -like '*without Run as administrator*' }).Count
        if ($normalOnly -gt 0) { return (Pass "elevated: every check that needs it ran; $normalOnly check(s) above can only be made in a normal window") }
        return (Pass 'elevated: every check ran')
    }
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
