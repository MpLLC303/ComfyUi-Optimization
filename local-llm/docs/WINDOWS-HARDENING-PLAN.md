# Windows hardening with undo (security track item 5): plan only, nothing is built yet

Status (2026-10-07): plan for two files that do not exist yet, `local-llm/Set-PCHardening.ps1` and
`local-llm/tests/Invoke-PCHardeningTest.ps1` (IMPROVEMENTS row 86 (5)). It was written on the
owner's PC, where nothing from the repository may be run, and without the web. So: **what this
plan says about Windows, Defender and Microsoft's documentation is from memory and unchecked**
(section 1 lists what to check, the rule ids first). What it says about this repository was read
from the code at commit ea191d1; line numbers are from that commit.

The script is opt-in, for Windows 11 Home, and switches on three things, each of which it can put
back exactly as found: Defender's attack surface reduction (ASR) rules, Controlled folder access
(CFA) with the toolkit's programs allowed once that is needed and safe (section 5), and LSA
protection. `Test-PCSecurity.ps1` stays the
read-only check. It already reads Defender's mode (:956-987), LSA protection (:1067-1074) and
Controlled folder access (:1075-1085); it has no row for the ASR rules.

## 1. Before building

**The owner settles the antivirus first.** The PC audit of 2026-10-07 found another antivirus
registered but snoozed, and Defender in passive mode. In that state ASR and CFA do nothing
(section 3) and the script offers LSA protection only. Either the other product is removed and
Defender takes over (all three switches), or it stays and is kept running (LSA only, for good).
The script can be built before the owner decides; its ASR and CFA parts can be tried on the
owner's PC only after.

**Then check these, in this order.** A check that only reads may be done on any Windows 11 PC. A
check that needs a change is done on a throwaway Windows 11 machine with Defender in charge, never
on the owner's PC and never on a CI runner.

| # | Check | Why it matters |
|---|---|---|
| C1 | The 16 ids and names of section 4, letter for letter, against Microsoft Learn "Attack surface reduction rules reference". Also whether that page lists rules missing here (from memory three newer ones: restart in Safe Mode, copied or impersonated system tools, webshell creation on servers) | Defender takes an id it does not know without an error, stores it and reads it back. A typo is never noticed afterwards |
| C2 | The action numbers (0 off, 1 block, 2 audit, 5 not configured, 6 warn) and the names the cmdlet takes for them: read the enum behind `(Get-Command Add-MpPreference).Parameters['AttackSurfaceReductionRules_Actions'].ParameterType` | Whether a name for 5 exists decides how a rule found at 5 is put back |
| C3 | `Add-MpPreference` with an id that is already in the list changes that one rule and leaves the rest; `Remove-MpPreference -AttackSurfaceReductionRules_Ids <id>` takes one rule out (and whether it wants the action too); `Set-MpPreference` with the same parameters replaces the whole list | The whole of section 4 rests on it. Needs a change: throwaway machine |
| C4 | Events 1121 (rule blocked), 1122 (rule audited), 1123 (CFA blocked), 1124 (CFA audited) in the log `Microsoft-Windows-Windows Defender/Operational`, and the names of their data fields (rule id, program path, file path), and whether the program path is written with a drive letter | The events are the only proof that Windows acts on a setting, and a program is allowed only after one names it (section 5) |
| C5 | Microsoft's requirements for ASR name Pro, Enterprise and Education, not Home. Whether Home acts on the rules shows only on a Home PC: an event 1122 for a rule in audit | Note N1 |
| C6 | Which rules need cloud-delivered protection (from memory: the prevalence rule and the ransomware rule) | Note N3 |
| C7 | Tamper Protection covers none of the three settings, so the cmdlets work while it is on, for this script and for any other program with administrator rights | The script never asks for it to be switched off; N2 and the table's footer must not promise more than this |
| C8 | CFA: mode numbers 0 to 4; the folders protected by default (Documents, Pictures, Videos, Music, Desktop, Favorites); an allowed program is named by its full path and stays allowed when an update replaces the file; Microsoft allows programs it trusts by itself | Section 5, "stay right after updates" |
| C9 | Which Windows program really writes: for a Docker bind mount into a protected folder, and for ComfyUI (a venv's `Scripts\python.exe` may only start another python.exe). Event 1124 names it | The allowed-program list must name the program that writes |
| C10 | LSA: `RunAsPPL` = 2 works from build 22621; what `RunAsPPLBoot` is and who writes it; the policy value `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System\RunAsPPL`; System-log event 12 from Wininit; Shut down with Fast Startup is not a restart. Page: the link at Test-PCSecurity.ps1:1067 | Section 6 |
| C11 | The policy keys under `HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard` (`ASR\Rules`, `Controlled Folder Access`) | Refusal R14 |
| C12 | What `Get-MpPreference` shows in a normal window (the allowed-program list may read "N/A: Must be an administrator"), and whether that window can read the Defender event log | What the bare run can show without administrator rights |
| C13 | Owner and permissions, each entry with its account, its raw rights number, allow or deny, and whether it is inherit-only: of `HKLM:\SOFTWARE` and a key below it that some installer made; of a key newly made there from an elevated window, with UAC on and with UAC off; of the root of the system drive, the Program Files folder, a program folder in it and its .exe. From memory a new key inherits an inherit-only entry for CREATOR OWNER (S-1-3-0) whose rights read 268435456 (generic all), and belongs to Administrators, but to the user account where UAC is off or the built-in Administrator account is used | Section 7, rule 1: the judge must pass what Windows really hands out and nothing wider, and T44's fixtures are copied from these answers. Reading needs no change: any PC. The new key: throwaway machine (W4 makes one on the Windows CI job too) |
| C14 | From an elevated window of another account: how to tell which account is signed in at the screen (`Win32_ComputerSystem.UserName`, or the owner of explorer.exe in the console session), its profile folder (`ProfileImagePath` under `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\<SID>`) and its hive `HKEY_USERS\<SID>` | Section 5: the programs are looked for in the everyday account's profile, not in the administrator's |

**Then one acceptance run on that throwaway machine, before the script is run on the owner's PC.**
No CI test runs -Apply or -Undo against a real Defender (section 8), so this is the first time
the Defender calls meet Windows. In an elevated window, from the administrators-only copy: save
`Get-MpPreference` and the two LSA values. The bare run changes nothing. `-Apply`: every row done,
the store as section 7 draws it. Restart: the LSA row reads "on". Let a program that is not
allowed write into Documents: event 1124, and the table offers that program by rules 2 and 3 of
section 5 and no other. Set every `Since` in the store back past the audit time by hand (the one
time a person edits the store), then `-Apply -Enforce`: 14 rules at block, 2 in audit, Controlled
folder access on. `-Undo` and restart: the saved values are back, value for value, and the store
key is gone. Then once more from another start: one rule at 0, one at 1, Controlled folder access
in audit.

## 2. Commands and what the owner sees

| Command | What it does |
|---|---|
| `Set-PCHardening.ps1` | Shows the table below. Changes nothing |
| `Set-PCHardening.ps1 -Apply` | Makes the changes the table shows: rules and CFA go to audit mode, the programs the table offers are allowed, LSA protection is set |
| `Set-PCHardening.ps1 -Apply -Enforce` | As -Apply, and raises to block what this script has had in audit for the audit time (question 1) |
| `Set-PCHardening.ps1 -Enforce` | Shows what `-Apply -Enforce` would change. Changes nothing |
| `Set-PCHardening.ps1 -Undo` | Puts back every value this script changed, exactly as it found it |
| `-Only Asr,Cfa,Apps,Lsa` | With any of the above: only the named switches. `Cfa` is the mode and the allowed programs, `Apps` the allowed programs alone. `[string[]]`; each element is first split on commas and trimmed, as Install-LocalAI.ps1:253-255 does, because `powershell.exe -File` hands `Asr,Cfa` over as one string. The names are checked by the script, so that a wrong one gets R03 and not PowerShell's own error |
| `-AllowWritable <full path>` | With -Apply: allow this one program although any program running as the owner can change or start it. It must be a path the table shows with R26, which says what that costs. `[string[]]`, not split on commas (a path may hold one) |
| `-AIRoot <folder>` | The install folder, as for the other scripts. Only read: its `localai-config.json` gives `ComfyUIPath`. Nothing is written under it |

**The bare run is write-free.** It sets nothing, creates no registry key or value and writes no
file, not even a log: `Write-LaiLog` writes to the window only (lib/LocalAI.psm1:23-31). It works
in a normal window; a cell it cannot read there says "needs an administrator window" (note N5).

**The table.** One row per rule (16), one for the CFA mode, one per allowed program, one for LSA:

```
Item                                    Now           Would become           Refused because
ASR  Office: child processes            not set       audit
ASR  Credential stealing from lsass     block         -                      already at block, not set by this script (R16)
CFA  Controlled folder access           off           audit
CFA  allow ComfyUI (<path>)             not allowed   -                      any program running as you can start it (R26)
CFA  allow Docker Desktop (<path>)      not allowed   allowed
LSA  LSA protection                     off           on after a restart
These settings stop programs that run without administrator rights. A program that already has
administrator rights can switch all of them off again, with or without Tamper Protection.
```

The last two lines are the table's footer, printed on every run.

After -Apply or -Undo the same table is printed with what was done, and appended to
`<ProgramFiles>\LocalAI-Logs\pc-hardening.log`, with the everyday account's profile folder written
as %USERPROFILE% (as Test-PCSecurity.ps1:908 does). Not under <AIRoot>: this run is elevated, the
user account has full control there, and a planted link would send the write somewhere else
(lib/LocalAI.psm1:303-306); the table also carries text that others choose (program paths from
events, the ComfyUI path). The folder is made if missing and inherits the permissions of Program
Files, like the download folder beside it (Install-LocalAI.ps1:536-538). The file is a record: the
script never reads it back, and a record that cannot be written is note N7, not a refusal.

One item that fails does not stop the others (as Add-Check, Test-PCSecurity.ps1:920-928). Exit
code: 0 = shown, or everything asked for was done; 2 = something was refused under -Apply or
-Undo; 1 = an error the script did not expect.

**Every refusal, as the owner reads it.** `<...>` is filled in. The sentences live in one
function, `Get-PchRefusalText` (section 8).

Whole run refused (printed once, nothing is changed):

| Id | When | Sentence |
|---|---|---|
| R01 | not Windows | "This script only works on Windows. Nothing was changed." |
| R02 | -Undo with -Apply or -Enforce | "Choose one: -Apply or -Undo. Nothing was changed." |
| R03 | -Only names something else | "-Only takes Asr, Cfa, Apps or Lsa. '<value>' is none of them. Nothing was changed." |
| R04 | -Apply or -Undo, not administrator | "Changing these settings needs administrator rights. Open Terminal (Admin) from a right-click on Start and run <command> there. Nothing was changed." |
| R05 | 32-bit PowerShell on 64-bit Windows | "This is a 32-bit PowerShell window, where the stored values would land in the wrong place. Start Windows PowerShell from the Start menu and run the script again. Nothing was changed." |
| R06 | -Apply or -Undo from a folder others can change: `Get-PchAclFault` finds a fault in the `ScriptAcl` rows of section 8 (question 6) | "This copy of the script is in a folder that programs without administrator rights can change (<folder>). Run the copy only administrators can change: <path>. Nothing was changed." When that file is not there, the second sentence is: "The copy only administrators can change is not on this PC yet (<path>): run the installer or 'Update toolkit' once more, which puts it there, then run that copy." |
| R07 | -Apply or -Undo on a test machine (`LAI_SANDBOX` = 1 or `GITHUB_ACTIONS` = true) | "This looks like a test machine: the environment variable <name> is set to <value>, and there the script only shows. If this is your own PC, take the variable out (in this window: Remove-Item Env:<name>; for good: Settings > System > About > Advanced system settings > Environment Variables) and run the script again. Nothing was changed." |
| R08 | the store is not administrators-only (section 7, rule 1) | "The place where this script keeps the old values (<key>) can be changed without administrator rights (<its owner is <account> / <account> may write to it>), so an undo could not be trusted. Nothing was changed." Under -Undo it goes on: "To put the settings back by hand: <by hand>." |
| R09 | the store cannot be made or read | "The place where this script keeps the old values (<key>) could not be made or read (<error>). Nothing was changed." |

They are checked in this order: R01, R02, R03, R07, R04, R05, R06 by `Get-PchRunRefusal`, then R08
and R09 by `Invoke-PchRun`, once the store's permissions are read. `<command>` in R04 and `<path>`
in R06 are always the administrators-only copy, `<ProgramFiles>\LocalAI\Set-PCHardening.ps1`, with
the switches the owner gave: no message names the Scripts folder for -Apply or -Undo. `<by hand>`
in R08, R41 and R42 comes from one pure function, `Get-PchByHandText`. For a rule it is the exact
line, because the rules have no page in Windows Security: `Remove-MpPreference
-AttackSurfaceReductionRules_Ids <id>`, or `Add-MpPreference` with the id and the action's name.
For Controlled folder access: "Windows Security > Virus & threat protection > Manage ransomware
protection". For LSA protection: "Windows Security > Device security > Core isolation details",
then a restart.

**R06 is guidance, not a control.** It runs inside the copy it judges, after that copy's lib has
been imported, so a copy that was tampered with simply leaves the check out. What protects the
owner is starting the administrators-only copy in the first place; R06 only catches the honest
mistake of starting the other one. R07 can be set off by anything that can set an environment
variable for the user, which is why its sentence names the variable and the way out.

One item refused (the "Refused because" column):

| Id | When | Sentence |
|---|---|---|
| R10 | ASR, CFA: Defender passive, switched off or not running | "Microsoft Defender is not the antivirus in charge on this PC (<it is in passive mode / it is switched off / it is not running>). Windows keeps this setting but does not act on it while another antivirus is registered, so it is not switched on. Run the security check (Test-PCSecurity.ps1), settle the antivirus, then run this again." |
| R11 | ASR, CFA: real-time protection off | "Microsoft Defender's real-time protection is off, and this setting needs it. Turn it on (Windows Security > Virus & threat protection > Manage settings), then run this again." |
| R12 | ASR, CFA: Defender gave no answer | "Microsoft Defender did not answer (<error>), so this script cannot tell whether it is in charge. Not changed." |
| R13 | ASR, CFA: a running mode other than Normal | "Microsoft Defender reports the running mode '<mode>', which this script does not know. Not changed." |
| R14 | a policy value exists for the setting | "A policy on this PC already sets this (<registry path>). This script does not change what a policy owns." |
| R15 | ASR: the two lists differ in length | "Defender's list of rules cannot be read reliably (<n> ids, <m> actions). No rule was changed." |
| R16 | a rule at block or warn; CFA already on | "Already at <block / warn / on> and not set by this script: left alone." |
| R17 | a state outside the known ones, a value of the wrong type, or unreadable | "This is in a state this script does not know (<what it read>): left alone." |
| R18 | -Enforce, audit-only rule | "Stays in audit mode: in block mode this rule would stop <what>." |
| R19 | -Enforce before the audit time is over | "In audit mode since <date> (<n> of <N> days). -Enforce waits, so that you can first see what would be blocked." |
| R20 | -Apply: the setting holds none of the values this script stored for it (section 7, rule 3) | "Changed since this script set it (it set <x>, now it is <y>): left alone. -Undo makes this script forget it." |
| R21 | CFA: a program is not installed | "<Program> was not found on this PC (looked among the programs of <account>), so nothing was allowed for it." |
| R22 | LSA: `RunAsPPL` = 1 | "LSA protection is already on, with a firmware lock (RunAsPPL = 1). This script leaves it alone: taking that lock off needs a Microsoft firmware tool, and the script only makes changes it can undo." |
| R23 | LSA: build below 22621 | "This Windows build (<build>) is older than Windows 11 22H2. The setting this script can undo only works from 22H2 on. Not changed." |
| R24 | CFA: a found program's path is not one the script allows | "<Program> was found at <path>. This script only allows a program file (.exe) on a built-in drive, named by its full path. Not allowed." |
| R25 | CFA: no event names the program | "Controlled folder access has not stopped <Program> <since <date> / so far>, so nothing was allowed for it: every allowed program is a way around the protection." |
| R26 | CFA: the program can be changed without administrator rights, or is python.exe | "Any program running as you can <change this file / start this python.exe with a script of its own> (<path>). Allowing it lets every such program change your protected folders. Not allowed. If you want it all the same, run this again with -AllowWritable '<path>'." |
| R27 | CFA programs: the account signed in at the screen cannot be told | "This script could not tell which account is signed in at the screen, so it does not know whose programs to look for. No program was allowed." |
| R30 | the before-value did not read back from the store | "The old value could not be stored safely (wrote <x>, read <y>), so the setting was not changed." |
| R31 | the setting did not read back as written | "Windows did not take this change: asked for <x>, it still reads <y>. A policy or Tamper Protection may hold the setting. It was put back to <the value it had>. Do not switch Tamper Protection off for this." |
| R32 | as R31, and putting back failed | "Windows did not take this change, and putting the old value back failed too (<error>). It now reads <y>. The old value (<before>) is still stored: run the script with -Undo." |
| R33 | the cmdlet or registry write threw, and the setting still reads what it held | "Windows refused this change (<error>). Nothing was changed for this item." |
| R40 | -Undo, nothing stored | "This script has changed nothing here that it could undo." |
| R41 | -Undo, a stored value is not one the script writes | "The stored old value for <item> is not one this script writes ('<value>'), so it is not used. The setting was left as it is; to change it by hand: <by hand>." |
| R42 | -Undo, the setting no longer holds what this script set | "Changed since this script set it (it set <x>, before that it was <before>, now it is <y>): left alone and forgotten. To put the old value back by hand: <by hand>." |
| R43 | -Undo, Defender's settings cannot be reached | "Microsoft Defender's settings cannot be reached (<error>), so <n> value(s) were not put back. They stay stored: run -Undo again when Defender answers." |
| R44 | -Undo, the old value did not read back | "<Item> could not be put back (asked for <before>, it reads <y>). The old value stays stored: run -Undo again." |

Notes (printed, nothing refused):

| Id | When | Sentence |
|---|---|---|
| N1 | ASR on a Home edition | "Microsoft's list of Windows editions for these rules does not name Home. The script sets them and reads them back, but on Home only an entry in the audit count below proves that Windows acts on them." |
| N2 | Tamper Protection off | "Tamper Protection is off: a program with administrator rights can switch Microsoft Defender's real-time protection off, and the rules and Controlled folder access stop working with it. Turn it on: Windows Security > Virus & threat protection > Manage settings." |
| N3 | cloud-delivered protection off (`MAPSReporting` = 0) | "Cloud-delivered protection is off; <rule names> do nothing without it. This script does not change that setting." |
| N4 | LSA changed, by -Apply or by -Undo | "Restart the PC to finish (Start > Power > Restart; Shut down is not enough while Fast Startup is on)." |
| N5 | bare run in a normal window | "Some cells need an administrator window to be read." |
| N6 | a program allowed through -AllowWritable | "<path> is now allowed. Any program running as you can <change this file / start it with a script of its own, every ComfyUI custom node included> and then change files in your protected folders: against those programs Controlled folder access no longer protects." |
| N7 | the record could not be written | "The record of this run could not be written (<error>). The changes shown above were made." |
| N8 | the window's account is not the one signed in at the screen | "Programs are looked for in the profile of <account>, the account signed in at the screen. This window runs as <other account>." |

## 3. The gate: which switch may be switched on

Decided first, from what `Get-MpComputerStatus` answers and from `CurrentBuildNumber` and
`EditionID` under `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` (Home: `EditionID` starts
with `Core`).

**Defender in charge** is the test of Test-PCSecurity.ps1:963, `$mp -and $mp.AntivirusEnabled -and
$mode -notmatch '(?i)passive|not running'` (:984 lists the three answers it rests on), made
stricter in two ways because this script changes things. Real-time protection must be on (:964
reports that as a FAIL). And the running mode must be `Normal` or empty: :963 lets any other text
through, where `Get-PcsAvVerdict` (:244-256) already declines to judge (EDR Block Mode is a
managed PC with another antivirus in charge).

| Defender answers | ASR | CFA | LSA |
|---|---|---|---|
| in charge (mode Normal or empty, antivirus enabled, real-time protection on) | offered | offered | offered |
| Passive Mode, SxS Passive Mode, Not running, or antivirus not enabled | R10 | R10 | offered |
| in charge, real-time protection off | R11 | R11 | offered |
| no answer (cmdlet missing, or an error) | R12 | R12 | offered |
| any other mode text | R13 | R13 | offered |

`Get-PchGate` judges in the order of `Get-PcsAvVerdict` (:243-256), with the mode trimmed and
matched as there, anchored and without regard to case: (1) `(sxs )?passive( mode)?`: R10, passive
mode; (2) `not running`: R10; (3) antivirus not enabled: R10, switched off, so EDR Block Mode
with the antivirus off is R10 and not R13; (4) mode empty or `normal`: offered when real-time
protection is on, else R11; (5) any other text: R13. No answer at all: R12. What :963 turns down
with its unanchored match ends in R10 or R13 here, so the gate is never looser than :963. The
gate is a second copy of that judgement, and T46 holds the two together as T45 does for the
ComfyUI finder.

LSA protection is a Windows setting, not a Defender one, so it is offered in every row; its own
conditions are in section 6.

**The trap that makes the gate necessary.** In passive mode Defender takes `Add-MpPreference` and
`Set-MpPreference` without an error, and `Get-MpPreference` returns the new values. Nothing acts
on them. So **a read-back that matches is not accepted as proof that a switch works, in passive
mode or anywhere else**: the gate decides whether a switch is offered, and the read-back only
catches a write that did not land.

**Tamper Protection.** The script never asks the owner to switch it off, in no message. From
memory it covers none of the three settings (C7). That is why the script's cmdlets and -Undo work
while it is on, and for the same reason **none of the three switches holds against a program
that already has administrator rights**: such a program can change all three settings, or run
this script with -Undo, with Tamper Protection on or off. The table's footer says so on every
run. What Tamper Protection does guard is Defender itself, so when it is off N2 says that and no
more (the advice of Test-PCSecurity.ps1:975), and the script goes on. If C7 is wrong for a
setting, the write does not land and the read-back sees it: the before-value is put back and the
item is refused with R31.

**Policy.** A setting that a policy value owns (C10, C11) is refused before any write (R14). A
policy the script did not see shows as a read-back mismatch: put back, R31.

## 4. Switch 1: attack surface reduction rules

**Setting.** One rule per call:
`Add-MpPreference -AttackSurfaceReductionRules_Ids <id> -AttackSurfaceReductionRules_Actions AuditMode`
(block: `Enabled`). Never `Set-MpPreference` with these two parameters: it replaces the whole
list, and with it every rule the owner or another program had set. One call per rule also gives
each rule its own before-value, write and read-back (section 7), so one failure cannot leave
sixteen rules half set.

All 16 rules start in audit mode (2). `-Apply -Enforce` raises the 14 enforceable ones to block
(1) once the audit time is over; the two audit-only rules never leave audit (R18).

The ids below are the work order's, and from memory: **check them against Microsoft's reference
before the build (C1)**.

| Id | Microsoft's name | Start | -Enforce | What block mode can stop |
|---|---|---|---|---|
| 56a863a9-875e-4185-98a7-b882c64b5ce5 | Block abuse of exploited vulnerable signed drivers | audit | block | the installer of an RGB, fan or overclocking tool that brings a driver on Microsoft's list |
| 9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2 | Block credential stealing from the Windows local security authority subsystem (lsass.exe) | audit | block | little; many harmless programs trip it, so its audit count is high |
| e6db77e5-3df2-4cf1-b95a-636979351e5b | Block persistence through WMI event subscription | audit | block | a hardware vendor's tool that registers a WMI event subscription |
| d3e037e1-3eb8-44c8-a917-57927947596d | Block JavaScript or VBScript from launching downloaded executable content | audit | block | an old installer or sign-in script (.js, .vbs) that starts a downloaded program |
| be9ba2d9-53ea-4cdc-84e5-9b1eeee46550 | Block executable content from email client and webmail | audit | block | starting a program or script straight out of an e-mail |
| b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4 | Block untrusted and unsigned processes that run from USB | audit | block | unsigned portable tools started from a USB stick or a memory card |
| c1db55ab-c21a-4637-bb3f-a12568109d35 | Use advanced protection against ransomware | audit | block | a rare, new, unsigned program that changes many files |
| 5beb7efe-fd9a-4556-801d-275e5ffc04cc | Block execution of potentially obfuscated scripts | audit | block | a packed or encoded PowerShell, JavaScript or VBScript file |
| d4f940ab-401b-4efc-aadc-ad5f3c50688a | Block all Office applications from creating child processes | audit | block | an Office macro or add-in that starts another program |
| 3b576869-a4ec-4529-8536-b80a7769e899 | Block Office applications from creating executable content | audit | block | a macro or add-in that writes a program or script file |
| 75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84 | Block Office applications from injecting code into other processes | audit | block | a rare Office add-in |
| 92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b | Block Win32 API calls from Office macros | audit | block | old macros that call Windows functions directly |
| 26190899-1602-49e8-8b27-eb1d0a1ce869 | Block Office communication application from creating child processes | audit | block | Outlook starting another program for an attachment or add-in |
| 7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c | Block Adobe Reader from creating child processes | audit | block | Adobe Reader starting another program from a PDF |
| 01443614-cd74-433a-b99e-2ecdc07bfc25 | Block executable files from running unless they meet a prevalence, age, or trusted list criterion | audit | stays audit | (audit only) the programs that ComfyUI custom nodes bring, fresh builds, new releases of small tools |
| d1e49aac-8f56-4280-b9ba-993a6d77406c | Block process creations originating from PSExec and WMI commands | audit | stays audit | (audit only) vendor tools and installers that start programs through WMI |

What -Apply does per rule, from the state found. Read `Get-MpPreference`:
`AttackSurfaceReductionRules_Ids` and `AttackSurfaceReductionRules_Actions` are two lists that
belong together by position. Wrap both in `@()` (one rule comes back as a bare value, none as
`$null`), compare ids without regard to case, store them in lower case, cast actions to `[int]`.

| Found | -Apply | Before-value stored |
|---|---|---|
| not in the list | set to audit | `absent` |
| 0 (off) | set to audit | `0` |
| 5 (not configured) | set to audit; if C2 finds no cmdlet name for 5: nothing, R17 | `5` |
| 2 (audit) | no write to Defender; the script adopts the rule (store entry only), so that -Enforce has a start date | `2` |
| 1 (block) or 6 (warn) | nothing: a rule is never lowered (R16) | none |
| any other number | nothing (R17) | none |
| the two lists differ in length | no rule at all is changed (R15) | none |
| the id is under the policy key (C11) | nothing (R14) | none |

**Must be true first.** Defender in charge by the :963 test and section 3; an administrator
window; the rule not owned by a policy. Tamper Protection: may be on or off; never asked off; N2
when off. Home: Microsoft's requirements do not name Home (C5). The backlog row asks for the rules
on Home, so the script sets them there and prints N1 on every run. Build: none beyond the cmdlets
being there. Cloud-delivered protection off: N3 for the rules that need it (C6).

**What can stop working.** In audit: nothing; Windows only writes event 1122. In block: the last
column above, each time with a Windows notification. The toolkit's own scripts: a search at
ea191d1 finds no `-EncodedCommand`, no WMI process start (`Invoke-CimMethod`, `Invoke-WmiMethod`)
and no wscript or .vbs in them, so none of the 14 rules is aimed at what they do; the audit time
is the proof.

**Read back.** After each call `Get-MpPreference` again: the id must be in the list with the
action asked for, else R31. That proves the write landed and nothing more (section 3; a wrong id
reads back too, C1). The proof that Windows acts on a rule is an event that carries its id: 1122
in audit, 1121 in block. The table shows per rule the number of such events since `Since` and the
programs they name (`Get-PchAuditSummary`, C4).

**Undo.** Before-value `absent`: `Remove-MpPreference -AttackSurfaceReductionRules_Ids <id>`, then
read back that the id is gone. Before-value `0`, `2` or `5`: `Add-MpPreference` with that action
(`Disabled`, `AuditMode`, the name for 5), then read back. So "was absent" and "was 0" end
differently: the first leaves no entry in Defender's list, the second an entry that says off.

## 5. Switch 2: Controlled folder access

**Setting.** `Set-MpPreference -EnableControlledFolderAccess AuditMode` (2); with
`-Apply -Enforce` after the audit time `Enabled` (1). The numbers are those of
Test-PCSecurity.ps1:1075-1084: 0 off, 1 on, 2 audit, 3 and 4 the disk-sector modes. Allowed
programs, one path per call: `Add-MpPreference -ControlledFolderAccessAllowedApplications <full
path>`, taken out again with `Remove-MpPreference` and the same parameter. No protected folder is
added (question 2).

| Found mode | -Apply | Before-value stored |
|---|---|---|
| 0 (off) | set to audit | `0` |
| 2 (audit) | no write; adopted (store entry only) | `2` |
| 1 (on) | mode left alone (R16); the program rows are still judged | none |
| 3, 4, any other number, or no number at all | nothing (R17). A missing answer is never read as 0 (Test-PCSecurity.ps1:1080 may cast `$null` to 0; this script may not) | none |

**How the allowed programs are found.** Never by a spelled-out folder: the static rule LOCATOR
(tests/Invoke-StaticChecks.ps1:69) forbids that for Ollama and Docker Desktop, because both can
be installed elsewhere. A file that exists is a candidate, not yet an allowed program: the three
rules further down decide. A program that is not installed gets R21.

| Program | Found by | Files offered |
|---|---|---|
| Ollama | `Find-LaiOllamaDir -LocalAppData <the everyday account's>` (lib/LocalAI.psm1:1627), without -OrDefault | `ollama.exe` and `ollama app.exe` in that folder |
| Docker Desktop | `Find-LaiDockerDesktopExe` (lib/LocalAI.psm1:1653), without -OrDefault | that file, and `resources\com.docker.backend.exe` beside it (the installer derives `resources\bin` the same way, Install-LocalAI.ps1:211) |
| ComfyUI | the roots of `Find-PcsComfyRoot` (Test-PCSecurity.ps1:355), fed as at :1292, with the everyday account's AppData and profile folder and the config's `ComfyUIPath` | per root the first that exists of `<root>\.venv\Scripts\python.exe`, `<parent of root>\python_embeded\python.exe`, `<root>\venv\Scripts\python.exe` (from memory, C9; question 3) |

`Find-PcsComfyRoot` lives in a script, not in the module, so `Set-PCHardening.ps1` cannot call it.
The plan: its own copy, `Find-PchComfyRoot`, and a test that holds the two to the same answer
(T45). Moving the function into lib/LocalAI.psm1 would be cleaner but touches two more files and
the tests that load it by name; that is the lane manager's call.

**Whose programs.** The locators read the profile of the account that owns the window
(`$env:LOCALAPPDATA` and HKCU, lib/LocalAI.psm1:1633-1638). Under the setup that
Test-PCSecurity.ps1:1379 advises, a Standard everyday account and a second administrator, the
elevated window belongs to the administrator: -Apply would look in the wrong profile and not find
what the bare run showed. So the reader first settles which account is signed in at the screen
(C14), takes its profile folder from `ProfileList`, and `AppData\Roaming` and `AppData\Local`
beneath it unless that account's `User Shell Folders` key under `HKEY_USERS\<SID>` names other
folders. Those folders go to `Find-LaiOllamaDir -LocalAppData` and to `Find-PchComfyRoot`, in the
bare run and in the elevated one alike, and into the %USERPROFILE% rewrite of the record. N8 is
printed when the two accounts differ. When the account at the screen cannot be told, the program
rows get R27. One gap stays: an Ollama installed to a custom folder for the everyday account
alone is registered in that account's hive, which `Find-LaiOllamaDir` does not read, so it is
found only while Ollama's tray app runs.

**What an allowed program costs, and the three rules that follow.** An entry on Defender's list
lets that file change the protected folders, whoever starts it and whatever the file has become
since. Everything the locators read can be written without administrator rights: the HKCU
registration and the folder of a running `ollama app` (lib/LocalAI.psm1:1637-1647), `basePath` in
%APPDATA%\ComfyUI\config.json, `ComfyUIPath` under <AIRoot>, Documents\ComfyUI, and two fixed
folders at the root of C:, where every signed-in account may add a folder
(Test-PCSecurity.ps1:361-378). So can the usual homes of the real programs: Ollama's per-user
folder, ComfyUI in Documents. And python.exe runs any script it is handed. A program running as
the owner could therefore point a locator at a file of its own, replace the real file, or start
the allowed python.exe itself, and an elevated -Apply would have put it past Controlled folder
access. So, per candidate and in this order:

1. **The path rule, at -Apply and at -Undo alike** (`Test-PchStoreValue`, kind AppPath): a full
   path that starts with a drive letter (no `\\server` path, no `\\?\` form), ends in `.exe` and
   holds no `*` and no `?`. `[`, `]`, spaces and commas are ordinary characters. At discovery the
   drive must also be a built-in one (`DriveType` Fixed). Else R24.
2. **No entry before it is needed.** A candidate is offered only when a Controlled folder access
   event (1124 in audit, 1123 when on) names exactly that path as the program, since `Cfa\Since`,
   or in the last 30 days when Controlled folder access was on already and has no entry. Else
   R25. So a first -Apply allows nothing: the audit time shows what would be stopped, and the
   next -Apply offers that. Ollama and Docker Desktop keep their data outside the protected
   folders unless the owner moved it, so their rows may stay at R25 for good.
3. **Nothing that others can change or steer.** The file, the folder it is in and every folder
   above it are judged like the store (section 7, rule 1), over the `Acl` rows of the `Programs`
   reader. A fault anywhere is R26, and so is a file named python.exe or pythonw.exe wherever it
   lies: not allowed unless `-AllowWritable` names exactly that path, and then with N6. Docker
   Desktop under Program Files passes. ComfyUI's python.exe never does (question 3).

Comfy Desktop's default folder is `%USERPROFILE%\Documents\ComfyUI` (Find-PcsComfyRoot, :376),
inside a folder Controlled folder access protects, so ComfyUI saving a picture is the first thing
it would stop. The way that needs no allowed program is to move ComfyUI's output folder out of
Documents; the README names that first. The table prints beside each candidate the number of
events that name it (C9), and lists the programs that were seen and are no candidates.

**How they stay right after updates.** An entry is a full path. Ollama and Docker Desktop update
in place, so the path and the entry hold (C8). A program that moved (installed again elsewhere, a
Comfy Desktop update that moves its Python) is caught because every run, the bare one too, finds
the programs afresh and compares them with the paths under `Cfa\Apps`: a stored path whose file
is gone, or a found path that is not stored, is shown as drift. `-Apply` then takes out its own
stale entry, Defender's list first and the store value last, and always: an entry for a file that
is gone can be filled by whoever may write to that folder. The new path is a new candidate and
goes through the three rules again, `-AllowWritable` included. Nothing runs this by itself in v1; the
README tells the owner to run the bare script when a program is blocked after an update.

**Must be true first.** Defender in charge by the :963 test with real-time protection on
(section 3); an administrator window; no policy value (C11). Tamper Protection: as in section 4.
Home: Controlled folder access is in Windows Security on Home (Ransomware protection), so no note.
Build: none beyond the cmdlets being there.

**What can stop working.** In audit: nothing; Windows writes event 1124. On: any program that
Microsoft does not trust by itself is stopped from changing files in Documents, Pictures, Videos,
Music, Desktop and Favorites, with a notification: ComfyUI saving pictures, game saves, scripts
run by powershell.exe or python.exe, older tools. The toolkit's own files are under <AIRoot>,
which is not protected. The way out stays the one Test-PCSecurity.ps1:1081 names: allow the
program in Windows Security.

**Read back.** `Get-MpPreference` again: `EnableControlledFolderAccess` holds the number asked
for; `@(ControlledFolderAccessAllowedApplications)` holds the path (compared without regard to
case). Else R31. Events: 1124 in audit, 1123 when on; both name the program and the file.

**Undo.** Mode: `Set-MpPreference -EnableControlledFolderAccess` with the stored before-value
(`0` as `Disabled`, `2` as `AuditMode`). Programs: `Remove-MpPreference` for each path under
`Cfa\Apps` that is still in Defender's list; a path the script did not store is never taken out.
"Was absent" and "was 0" here: a program that was absent from the list before is one the script
added and stored, and undo removes it, while one that was there before has no store entry and
stays; the mode is never absent (a mode that cannot be read is R17, not 0), and a stored `0` is
written back as off.

## 6. Switch 3: LSA protection

**Setting.** Key `HKLM:\SYSTEM\CurrentControlSet\Control\Lsa`, value `RunAsPPL`, type REG_DWORD,
data 2: on, without the firmware lock (Test-PCSecurity.ps1:1068; the value behind the switch in
Windows Security). Never 1: that also stores the setting in the PC's firmware, and taking it out
again needs a Microsoft firmware tool. `RunAsPPLBoot` in the same key is not written by -Apply,
but its before-value is stored: from memory Windows writes it itself once protection is on, and a
left-over 2 keeps protection on after `RunAsPPL` is gone (C10).

| Found `RunAsPPL` | -Apply | Before-value stored |
|---|---|---|
| absent | set to 2 | `absent` (and `RunAsPPLBoot`: `absent`, `0`, `1` or `2`) |
| 0 | set to 2 | `0` (and `RunAsPPLBoot` as above) |
| 2 | nothing: already on | none |
| 1 | nothing: R22 | none |
| another number, not a DWORD, or unreadable | nothing: R17 | none |

Absent, a value and unreadable are three different answers. `Get-PcsRegValue`
(Test-PCSecurity.ps1:756-763) returns `$null` for a missing value and for a failed read alike.
That is fine for a check and wrong here: an unreadable value taken for absent would be deleted by
undo. Read with `Get-Item -LiteralPath`, then `GetValueNames()`, `GetValue()` and
`GetValueKind()`; any error is "unreadable".

**Must be true first.** Windows build 22621 or later (R23). An administrator window. No policy
value (R14, C10). Defender in charge: not needed; this is the one switch offered when the :963
test fails (section 3). Tamper Protection: not involved. Home: works (Test-PCSecurity.ps1:1068).

**What can stop working.** Windows no longer loads sign-in plug-ins that are not signed for it:
smart-card software, an older fingerprint reader's software, a VPN or password tool that hooks
into sign-in (question 4). Password and PIN keep working, so the owner can always sign in and
undo. Tools that read the sign-in process's memory stop working; that is the purpose.

**Read back.** Right after the write: the value is 2 and a DWORD, else R31. It is in force only
after a restart, so the row compares two times: the entry's `Since` (section 7) and the last
start of Windows (`Win32_OperatingSystem.LastBootUpTime`, `LastBoot` in the `Lsa` reader's
answer). Last start before `Since`: "set, waits for a restart". Last start after it, and the
System log holds event 12 from Wininit ("LSASS.exe was started as a protected process") newer
than that start: "on". Last start after it and no such event: "set, but Windows did not start the
sign-in process protected" (shown as a warning; nothing is undone by itself). Where the script
has no entry (found at 2 or 1), the event alone decides between "on" and that warning.

**Restart.** Needed after -Apply and again after -Undo. The script prints N4 both times and never
restarts the PC.

**Undo.** `RunAsPPL` first: before-value `absent` deletes the value (`Remove-ItemProperty`); `0`
writes 0 as a DWORD. So "was absent" and "was 0" end differently. Then `RunAsPPLBoot`, the same
way from `BeforeBoot`, whenever it differs from it: also when `RunAsPPL` was found back at its
before-value already (an undo cut off between the two, or the owner's own switch in Windows
Security), because a 2 left there would keep protection on. Both are read back, and the entry
goes last. Because the script wrote 2 and never 1, no firmware tool is needed;
the owner can also do it by hand: Windows Security > Device security > Core isolation details >
Local Security Authority protection Off, then restart.

## 7. Where the before-values are kept

Key `HKLM:\SOFTWARE\LocalAI\PCHardening`, in the 64-bit view (R05 keeps a 32-bit window out).

Never under <AIRoot>. A before-value decides what an elevated -Undo writes into Windows' security
settings. The user account has full control of <AIRoot> (Install-LocalAI.ps1:215-219), so any
program running as the owner could plant "before: off" there for a rule the owner had at block,
and the next -Undo would switch it off with administrator rights. `HKLM:\SOFTWARE` lets only
administrators and SYSTEM write. The script does not lean on what a new key inherits (rule 1).

Everything is a REG_SZ from a closed set, so that `absent` and `0` are two different words and
nothing else fits:

```
HKLM:\SOFTWARE\LocalAI\PCHardening
  Asr\<rule id, lower case>   Before = absent | 0 | 2 | 5    Set = 2 | 1    Since = <time>
                              Pending = 2 | 1    Left = absent | <number>
  Cfa                         Before = 0 | 2                 Set = 2 | 1    Since = <time>
                              Pending = 2 | 1    Left = <number>
  Cfa\Apps                    <full path of a program this script allowed> = <time>
  Lsa                         Before = absent | 0    BeforeBoot = absent | 0 | 1 | 2
                              Set = 2    Since = <time>
                              Pending = 2    Left = absent | <number>
```

`Before` is what the script found before its first change. `Set` is what it last wrote and read
back, or adopted. `Pending` is what it is about to write, and `Left` what the setting read after
a put-back failed: both exist only while a change is unfinished (rule 2). `<time>` is UTC,
`yyyy-MM-ddTHH:mm:ssZ`. `Since` is the time of the first -Apply for that item: R19 counts whole
days from it, and the LSA row compares it with the last start of Windows (section 6).

1. **Administrators only: made so, then checked.** A key the script makes gets its own
   permissions and no inherited ones: owner Administrators, full control for SYSTEM and
   Administrators, read for Users, handed on to its subkeys (`CreateSubKey` with a
   `RegistrySecurity`; from memory, W4 proves it). That holds also where UAC is off or the
   built-in Administrator account is used, where a new key would otherwise belong to the user
   account (C13). Then, before the first write and before -Undo reads, every key from
   `HKLM:\SOFTWARE\LocalAI` down is judged: `PCHardening`, `Asr`, each `Asr\<id>`, `Cfa`,
   `Cfa\Apps`, `Lsa`. A fault is R08; a key that cannot be made or read is R09. The pure judge is
   `Get-PchAclFault`. It also judges files and folders (R06, and rule 3 of section 5):
   - The owner must be SYSTEM (S-1-5-18), Administrators (S-1-5-32-544) or TrustedInstaller
     (S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464). The owner counts: an
     owner who is a plain account can rewrite the permissions without administrator rights.
   - Deny entries and inherit-only entries are skipped. An inherit-only entry gives nothing on
     the object itself, and every key, file and folder the script relies on is judged itself.
     This is what lets the entry pass that Windows hands down from `HKLM:\SOFTWARE` and from
     Program Files: CREATOR OWNER (S-1-3-0), inherit-only, rights 268435456.
   - Every other Allow entry whose rights hold a write bit must name one of those three
     accounts, OWNER RIGHTS (S-1-3-4) or CREATOR OWNER (S-1-3-0, which is no account anyone
     signs in with); `Get-PcsAclVerdict` accepts the same two (Test-PCSecurity.ps1:299). The
     rights are judged as the raw number (`[int]` of the entry's rights), never by flag names:
     generic rights have none.
   - The write bits, by what is judged (from memory, C13):

   | Kind | Judged | Write bits |
   |---|---|---|
   | Key | a registry key | 0x2 set value, 0x4 create subkey, 0x20 create link, 0x10000 delete, 0x40000 change permissions, 0x80000 take ownership, 0x40000000 generic write, 0x10000000 generic all |
   | File, Folder | a program or script file, and the folder it is in | 0x2 write (folder: add a file), 0x4 append (folder: add a folder), 0x40 delete what is inside, 0x10000, 0x40000, 0x80000, 0x40000000, 0x10000000 |
   | Above | every folder further up, to the root of the drive | 0x40, 0x10000, 0x40000, 0x80000, 0x10000000. Adding something there replaces nothing, and the root of the system drive lets every signed-in account add a folder |

2. **Written and read back around each change.** `Invoke-PchPlan` does this per item. Every
   value it stores goes through `Test-PchStoreValue` first; a `$false` there is a bug in a
   planner, not a refusal, and ends the run with exit code 1.
   - (a) The store. On a first -Apply: `Before`, `Since` and, last, `Pending` = the target. Under
     -Enforce: `Pending` = 1 into the entry that is there. An item found in audit already is
     adopted with `Before`, `Since` and, last, `Set`, and that is all: no setting is written.
   - (b) Read the entry back. If it differs: take out what (a) wrote, R30, and the setting is not
     written.
   - (c) Write the setting.
   - (d) Read the setting back, whether (c) threw or not. It holds the target: write `Set` = the
     target, then delete `Pending`. It holds what it held before (c): nothing landed, so take
     out what (a) wrote (the whole entry on a first -Apply, only `Pending` under -Enforce); the
     row says R33 if (c) threw, else R31. It holds something else: write back what it held
     before (c) and read that back. If that worked, take out what (a) wrote, R31. If not, the
     entry stays, `Left` = what the setting reads now is added, and the row says R32.
   - (e) Taking out goes the other way round: the setting first, the store last. That holds for
     every -Undo step and for a stale allowed program (section 5). An allowed program is added
     store value first, then Defender's list, then read back; so a path under `Cfa\Apps` that is
     not in Defender's list is one the script was about to add. -Apply adds it if it is still a
     candidate and takes the value out if not.
3. **A second run never overwrites a before-value, and finishes what an earlier run left.**
   `Before` and `Since` are never written twice. What -Apply does with an entry that is there:

   | The entry has | The setting holds | -Apply |
   |---|---|---|
   | `Set`, no `Pending` | `Set` | nothing; under -Enforce, rule 2 from (a) |
   | `Pending` | `Pending` | the write landed and the run was cut off after it: write `Set`, delete `Pending`, also without -Enforce |
   | `Pending` | what it held before the cut: `Set`, or `Before` when there is no `Set` | the write never happened. Without `Set`: go on at (c). With `Set`: delete `Pending`, then as the first row |
   | neither `Set` nor `Pending` | anything | the entry was cut off while being made, before the script touched the setting (`Set` and `Pending` are written last): take it out and plan the item afresh |
   | anything else | anything else | R20: nothing is written, the entry is untouched |

   So -Apply takes an entry out in three cases only: one it made in this step and could not use
   (rule 2), one that was cut off while being made, and its own stale allowed program. Everything
   else stays until -Undo. An -Undo that was cut off after its setting write leaves `Set` in the
   store and `Before` in the setting: -Apply answers that with R20 as well, and -Undo run again
   finishes it.
4. **Closed-set values only, at every write and every read.** `Test-PchStoreValue` judges each
   value before it is stored (rule 2) and each value -Undo reads: the sets above; a time by its
   pattern; `Left` a whole number or `absent`; a rule id one of the 16; a program path by the
   path rule of section 5. What -Undo cannot accept is R41, and the setting is left.
5. **-Undo writes `Before` only over a value this script left there.** The setting holds `Before`
   already: the entry is forgotten. It holds `Set`, `Pending` or `Left`: `Before` is written. It
   holds anything else: R42, left alone, forgotten, with the by-hand line. An entry with neither
   `Set` nor `Pending` is forgotten without a write (rule 3). Each undo is read back; a mismatch
   keeps the entry (R44).
6. When the last entry is gone, -Undo removes `PCHardening`, and `HKLM:\SOFTWARE\LocalAI` only
   when that is empty too.
7. The bare run reads the store when it exists and never creates it.

## 8. Code layout and tests

**Set-PCHardening.ps1** begins like Test-PCSecurity.ps1:1-57: `#Requires -Version 5.1`, help that
names every parameter (static rule HELP), `$ErrorActionPreference = 'Stop'`, the import of
lib/LocalAI.psm1 (`Write-LaiLog`, `Read-LaiState` as at :893, the two locators), the elevation
test of :910-913. Then functions only, all named `*-Pch*`, then a body of a few lines: build the
real reader and writer, call `Invoke-PchRun`, print, exit. The test loads the functions from the
source text, so the body holds nothing a test must reach. Windows PowerShell 5.1, ASCII only. Of
the rules at tests/Invoke-StaticChecks.ps1:27-88 these bite here: HELP, DOCPARAM, LOCATOR, PS51,
MATCHES, ENCODING. The static checks take every *.ps1 under local-llm (:23): no file list to
register.

Pure functions (no cmdlet that asks Windows, no reader, no writer inside):

| Function | Input | Output |
|---|---|---|
| `Get-PchRefusalText` | `-Id`, `-Values` (hashtable for the `<...>` parts) | the sentence of section 2 |
| `Get-PchCatalog` | none | the 16 rules: Id, Name, Short, AuditOnly, BlockStops, NeedsCloud |
| `Get-PchRunRefusal` | `-Apply`, `-Undo`, `-Enforce` (bool), `-Only` (string[], split on commas here), `-Run` (the answer of the `Run` reader) | `$null`, or the first of R01 to R07 in the order of section 2: Id and the Values for its sentence |
| `Get-PchGate` | `-Defender` (`$null`, or an object with AntivirusEnabled, RealTimeProtectionEnabled, AMRunningMode, IsTamperProtected, Error), `-MapsReporting` (a number, or `$null` when it cannot be read: then no N3), `-Build` (int), `-EditionId` | an object: Asr, Cfa, Lsa (each '' or a refusal id), Notes (note ids), DefenderText |
| `Get-PchAsrPlan` | `-Catalog`, `-Ids`, `-Actions`, `-PolicyIds`, `-Store` (id to its entry), `-Enforce`, `-Now`, `-AuditDays` | one row per rule: Id, Name, Now, Want, Clean (what rule 3 of section 7 takes out of the store first: nothing, a left-over `Pending`, or a cut-off entry), Step (None, Adopt, Set, Resume at (c), Finish in the store), Before, Refusal |
| `Get-PchCfaPlan` | `-Mode`, `-Allowed` (string[]), `-Programs` (the rows of the `Programs` reader, or `$null` for R27), `-Seen` (the program paths that events name), `-AllowWritable`, `-Policy`, `-Store`, `-Enforce`, `-Now`, `-AuditDays` | a mode row with the fields of a rule's row, and one row per program: Step (None, AddApp, RemoveApp), Refusal, Note |
| `Get-PchLsaPlan` | `-RunAsPPL`, `-RunAsPPLBoot` (each `absent`, a number or `unreadable`), `-Policy`, `-Build`, `-Store`, `-RunningProtected`, `-LastBoot`, `-Now` | one row: Now, Want, Clean, Step, Before, BeforeBoot, Refusal, Restart |
| `Get-PchUndoPlan` | `-Store` (all of it), `-Now` (rule states, CFA mode, allowed programs, RunAsPPL, RunAsPPLBoot) | steps: Item, Kind (AsrRemove, AsrSet, CfaMode, CfaAppRemove, LsaSet, LsaDelete, Forget), Value, Refusal |
| `Test-PchStoreValue` | `-Kind` (AsrBefore, AsrSet, CfaBefore, CfaSet, LsaBefore, LsaBootBefore, LsaSet, Left, Time, RuleId, AppPath; a `Pending` is judged as the `Set` of its item), `-Value` | `$true` or `$false` |
| `Get-PchAclFault` | `-Kind` (Key, File, Folder, Above), `-OwnerSid`, `-Rules` (Sid, Type, Rights, InheritOnly) | `$null` when only administrators can change it, else Why (Owner or Rule) and Sid (section 7, rule 1) |
| `Get-PchByHandText` | `-Item`, `-Before` | the `<by hand>` text of section 2 |
| `Get-PchDefenderCall` | `-Name` (AsrSet, AsrRemove, CfaMode, CfaAppAdd, CfaAppRemove), `-Key`, `-Value` | Cmdlet, and the parameters to splat. The one place where the cmdlet, parameter and action names are spelled; W6 checks them against the real cmdlets |
| `Get-PchPlace` | none | StoreRoot, LsaKey, LogFile, AdminCopy: the real places, spelled once |
| `Find-PchProgram` | `-OllamaDir`, `-DockerExe`, `-ComfyRoots`, `-Exists` (scriptblock) | rows: Name, Path |
| `Find-PchComfyRoot` | as `Find-PcsComfyRoot`: `-AppData`, `-UserProfile`, `-Remembered` | folders |
| `Get-PchAuditSummary` | `-Events` (rows: Id, RuleId, Program, File, Time), `-Since` | per rule id and for CFA: Count, Programs; and Seen, the program paths that CFA events name |
| `Format-PchTable` | rows | the lines of section 2's table, the footer last |

The three functions that touch the PC, and only through what they are handed:

| Function | Input | Output |
|---|---|---|
| `Invoke-PchPlan` | `-Steps`, `-Reader`, `-Writer` (scriptblocks) | one result row per step. The only function that calls `$Writer`; it follows section 7, rules 2 and 3, and ends with one `Log` call that carries the table (a throw there is N7) |
| `Invoke-PchRun` | `-Apply`, `-Undo`, `-Enforce` (bool), `-Only`, `-AllowWritable`, `-Reader`, `-Writer`, `-Now`, `-AuditDays` | Rows, Notes, ExitCode. Asks the `Run` reader and `Get-PchRunRefusal` first, then `StoreAcl` (R08, R09), then the gate and the planners. Hands the `Programs` reader the folders of the account at the screen. Calls `Invoke-PchPlan` for -Apply and -Undo only |
| `Get-PchRealReader` | `-AIRoot`, `-StoreRoot`, `-LsaKey` | the reader for the real PC. The only place with `Get-MpComputerStatus`, `Get-MpPreference`, `Get-WinEvent`, `Get-Acl` and the registry reads |
| `Get-PchRealStoreWriter` (`-Root`), `Get-PchRealLsaWriter` (`-Key`), `Get-PchRealDefenderWriter`, `Get-PchRealLogWriter` (`-File`) | as named; none takes `-AIRoot` | the four parts of the writer, and the only places with a command or method that changes anything. The store and LSA parts take their key as a parameter so that W4 and W5 can run them on a scratch key. The Defender part always, and the other two when built for the real key of `Get-PchPlace`, begin with R07's test and throw on a test machine: the brake then holds whichever function calls them |
| `Get-PchRealWriter` | `-StoreRoot`, `-LsaKey`, `-LogFile` | one scriptblock that hands each writer name to its part |

The reader answers `& $Reader <name>` (`Programs` takes one argument); the writer takes
`& $Writer <name> <key> <value>` and throws when Windows refuses:

| Reader name | Answer | Writer name | Key, value |
|---|---|---|---|
| `Run` | OnWindows, Elevated, Is64BitOs, Is64BitProcess, SandboxVar and SandboxValue (the variable R07 found, or ''), ScriptAcl (rows as `StoreAcl`: the script's folder, the script, `lib`, the module, the folders above), AdminCopy, AdminCopyExists, WindowUser, DeskUser (`$null`, or Name, Sid, Profile, AppData, LocalAppData) | `Store` | `@(<subkey>, <value name>)`, as in `@('Asr\<id>', 'Before')` or `@('Cfa\Apps', '<full path>')`, so a value name may hold backslashes; a value. `$null` removes the value, and with a `$null` value name the whole subkey |
| `Defender` | the status object or `$null` | `AsrSet` | rule id, action number |
| `Os` | Build, EditionId | `AsrRemove` | rule id |
| `Asr` | Ids, Actions, PolicyIds, MapsReporting | `CfaMode` | (none), mode number |
| `Cfa` | Mode, Allowed, Policy | `CfaAppAdd`, `CfaAppRemove` | path |
| `Lsa` | RunAsPPL, RunAsPPLBoot, Policy, RunningProtected, LastBoot | `LsaSet` | value name, number |
| `Store` | the store as nested hashtables, or `$null` | `LsaDelete` | value name |
| `StoreAcl` | one row per key from `HKLM:\SOFTWARE\LocalAI` down: Path, Kind, OwnerSid, Rules (Sid, Type, Rights, InheritOnly) | `Log` | (none), the lines |
| `Programs` (argument: the `DeskUser` folders) | rows: Name, Path, DriveFixed, Acl (rows as `StoreAcl`: the file, its folder, each folder above) | | |
| `Events` | rows of the last 90 days: Id, RuleId, Program, File, Time | | |

**Invoke-PCHardeningTest.ps1** begins with the sandbox guard of Invoke-WindowsUnitTests.ps1:27,
has `Assert-That` and `Skip` as :31-35, loads the functions as :2039-2040 does (parse
`Set-PCHardening.ps1`, dot-source every function named `*-Pch*`), ends with the exit code = failed
assertions and the banner `PC HARDENING TEST PASSED`.

**Tests never change the runner's real Defender or LSA settings.** No test starts the script with
-Apply or -Undo. No test calls `Get-PchRealWriter` or `Get-PchRealDefenderWriter`: their text is
loaded, the functions are never run. Every test of a change runs against a fake PC: one hashtable
(rules, CFA mode, allowed programs, the two LSA values, the store) with a reader and a writer
over it, and a journal of every writer call in order. Its variants: "sticky" (one setting takes
the write and still reads back the old value, as under a policy), "warped" (one setting reads
back a third value), "throwing" (one named writer call throws and changes nothing), "boot"
(`RunAsPPLBoot` turns 2 once `RunAsPPL` is written, as Windows is said to do) and "passive"
(Defender answers Passive Mode, and every write reads back). A run that was cut off is made by
replaying the first n journal entries of a whole run onto a fresh fake PC.

What the fake PC cannot show is whether the real writer and reader fit Windows. Three things
close that without touching Defender or LSA, on the Windows job only. The store part and the LSA
part of the writer run for real, against scratch keys the test makes under
`HKLM:\SOFTWARE\LocalAI-Test-<random>` and removes again (W4, W5): the store is neither a
Defender nor an LSA setting, and a scratch key is not the LSA key. The Defender part is never
run; the names it would use are checked against the real cmdlets, read-only (W6). And the judge
runs over real permissions (W4, W7). T39 to T42 hold all this in the source itself, and R07's
brake sits in the writer parts too, so it holds even if a later test built them for the real
keys. Still no test runs -Apply or -Undo against a real Defender: that is the acceptance run of
section 1.

Assertions, by the name each prints. All but W1 to W7 run on both CI jobs.

| # | Assertion |
|---|---|
| T01 | gate: Defender in charge allows ASR, CFA and LSA |
| T02 | gate: passive mode refuses ASR and Controlled folder access and still offers LSA |
| T03 | gate: SxS passive, not running, switched off, no answer and an unknown mode each refuse ASR and CFA, never LSA |
| T04 | gate: real-time protection off gives R11 for ASR and CFA |
| T05 | gate: build 22000 refuses LSA only (R23); a Home edition adds note N1 and refuses nothing |
| T06 | passive mode: on a fake PC where every write reads back, -Apply ends with no ASR or CFA writer call (the gate decides, not the read-back) |
| T07 | run: -Apply not elevated, in a 32-bit window, from a folder others can change, on a test machine, and together with -Undo each get their own refusal through `Invoke-PchRun`, and none calls the writer. R06 with the administrators-only copy missing uses its other sentence and names the installer; R07 names the variable and its value |
| T08 | run: -Only with an unknown name is R03; `'Asr,Cfa'` handed over as one string is the two names; -Only Lsa plans no ASR and no CFA row; `-Undo -Only Apps` takes out this script's allowed programs and leaves the mode, the rules, LSA and their entries |
| T09 | catalog: 16 rules, 14 enforceable and 2 audit only, the ids equal to a second list kept in the test |
| T10 | ASR: an absent rule and a rule at 0 both go to audit, with the before-values absent and 0 kept apart |
| T11 | ASR: a rule at block (1) or warn (6) is not lowered and gets no store entry |
| T12 | ASR: ids compare without regard to case; a single rule that comes back as a bare value is read |
| T13 | ASR: three ids with two actions refuse every rule (R15) |
| T14 | ASR: -Enforce raises only rules this script has had in audit for the audit time (R19 before), and the two audit-only rules stay at 2 (R18) |
| T15 | ASR: a rule found in audit is adopted: a store entry, no writer call to Defender |
| T16 | ASR: a rule under the policy key is refused (R14) |
| T17 | ASR: the store says Set 2, the PC says 0: R20, the before-value untouched |
| T18 | CFA: off goes to audit; on is left alone; modes 3 and 4 and a missing mode are refused |
| T19 | CFA: a found program that is not allowed yet is added and stored; one already allowed is neither added nor stored |
| T20 | CFA: a stored path that is gone is drift: its entry is removed and the new path added; an entry the script did not store is never removed |
| T21 | CFA: a program that is not installed gives R21 and no entry |
| T22 | LSA: absent and 0 both go to 2, with the before-values absent and 0 kept apart |
| T23 | LSA: RunAsPPL 1 is refused (R22), 2 is left alone, 7 and an unreadable value are refused (R17) |
| T24 | LSA: -Apply and -Undo both end with the restart note N4 |
| T25 | order: for every item `Before`, `Since` and `Pending` are written to the store and read back before the setting is written; `Set` is written and `Pending` removed only after the setting read back. Taking out goes the other way: the setting first, the entry last |
| T26 | a store entry that does not read back stops the item (R30): no setting is written |
| T27 | read-back mismatch: on the sticky PC the entry made for the item is removed and no second setting write is made; on the warped PC the old value is written back and read back first. Both rows say R31 |
| T28 | warped PC and a put-back that throws: the entry stays with `Pending` and `Left`, the row says R32. -Undo then writes `Before`; had the setting changed once more, it is R42 with the by-hand line |
| T29 | a second -Apply, and -Apply -Enforce after it, leave the first before-value in the store |
| T30 | one rule per writer call: 16 rules give 16 `AsrSet` calls, none carries two ids |
| T31 | undo of a value that was absent removes it (rule: `AsrRemove`; LSA: `LsaDelete`); undo of a value that was 0 writes 0 |
| T32 | a tampered store value (Before = 3, an empty Before, a rule id not in the catalog, a path with `*` or `?`, a `\\server` path) is refused (R41) and the setting left |
| T33 | undo removes only the allowed programs this script added |
| T34 | -Apply then -Undo on the fake PC gives back the starting state exactly, and an empty store, for each of several starting states |
| T35 | undo with nothing stored: R40, no writer call |
| T36 | undo of a setting changed since: left alone, the entry forgotten (R42); for a rule the sentence carries the exact cmdlet line |
| T37 | the bare run calls no writer, `Log` included: `Invoke-PchRun` with neither -Apply nor -Undo and a writer that throws returns its rows |
| T38 | -Enforce without -Apply calls no writer |
| T39 | Set-PCHardening.ps1, by its syntax tree: outside the four writer parts there is no command call named Set-, Add- or Remove-MpPreference, New-, Set-, Remove- or Clear-ItemProperty, New-Item, Set-Item, Remove-Item, Set-Acl, Add-Content, Set-Content, Out-File, reg or reg.exe; no method call named SetValue, DeleteValue, CreateSubKey, DeleteSubKey, DeleteSubKeyTree, SetAccessControl, AppendAllText, WriteAllText or WriteAllLines; no redirection into a file (`$null` is none); and the `Cmdlet` that `Get-PchDefenderCall` names is read and called in the Defender part only (it is called through `&`, so no Mp cmdlet is a command call anywhere in the script) |
| T40 | Set-PCHardening.ps1: only `Invoke-PchPlan` invokes `$Writer` |
| T41 | `Get-PchDefenderCall`: no call for a rule names `Set-MpPreference`, and each carries exactly one id |
| T42 | this test file, by its syntax tree: no command call named `Get-PchRealWriter`, `Get-PchRealDefenderWriter` or one of the three Mp cmdlets (the same names as strings, as in T39's list, are data and fine); powershell.exe is started in one place only, and that call's text holds none of -Apply, -Undo, -Enforce. Files and keys the test makes for itself (T45's folder tree, the scratch keys of W4 and W5) are not what this guards |
| T43 | every refusal and note id of section 2 has a sentence with no `<...>` left in it once its values are given, and every id the script uses is one of them |
| T44 | Get-PchAclFault, on rows copied from C13's answers: the permissions a new key really gets under `HKLM:\SOFTWARE` pass, CREATOR OWNER's inherit-only 268435456 included; so do Users with read (131097), and the root of the system drive judged as Above. A fault: Users with generic write (1073741824) or with set value (2), a plain account with 268435456 that is not inherit-only, a plain account as owner |
| T45 | Find-PchComfyRoot and Find-PcsComfyRoot (loaded from Test-PCSecurity.ps1) give the same folders for the same folder tree |
| T46 | gate and security check agree: for a table of Defender answers (the modes of section 3, with stray spaces and capitals, each with the antivirus on and off and real-time protection on and off), wherever `Get-PchGate` offers ASR, `Get-PcsAvVerdict` (loaded from Test-PCSecurity.ps1, no other product) says PASS "Microsoft Defender on"; wherever its text says passive mode, not running or switched off the gate says R10; real-time protection off is R11; a mode it does not judge is R13 |
| T47 | the writer throws on a first -Apply and the setting is unchanged: the entry made for the item is gone, the row says R33, and the next -Apply plans the item afresh (no R20) |
| T48 | the writer throws under -Enforce: `Set` is still 2, `Pending` is gone, the setting is still audit, R33; -Undo then gives back the starting state |
| T49 | cut-off runs: for -Apply, for -Apply -Enforce and for -Undo, and for every n, the first n writer calls of the whole run are replayed on a fresh fake PC. -Undo from there ends at the starting state with an empty store. For the first two, the same command from there ends in the state and the store of the whole run |
| T50 | -Apply, then -Apply -Enforce after the audit time, then -Undo gives back the starting state exactly, and an empty store, for each starting state of T34 |
| T51 | LSA on the boot PC: after -Apply `RunAsPPLBoot` reads 2; -Undo deletes it when `BeforeBoot` was absent, writes 0 when it was 0 and leaves 2 when it was 2. With `RunAsPPL` back at its before-value already, -Undo still puts `RunAsPPLBoot` back |
| T52 | LSA row: last start before `Since` reads "set, waits for a restart"; after it with the event, "on"; after it without the event, the warning |
| T53 | CFA programs: a candidate no event names gets R25; one named by an event, with file and folders only administrators can change, is added and stored; with a folder a plain account may write, R26; the same with -AllowWritable naming it is added, with N6; -AllowWritable naming another path changes nothing; python.exe in a folder only administrators can change is R26 all the same. No refusal makes a writer call |
| T54 | path rule at -Apply and -Undo alike: a `\\server` path, a path without .exe, one with `*` or `?`, and one on a drive that is not built in get R24 and no store write; a path with `[`, `]`, a space and a comma is allowed, stored, and taken out again by -Undo |
| T55 | everyday account: `Invoke-PchRun` hands the `Programs` reader the folders of the account at the screen, not those of the window's account, and prints N8 when the two differ; with no account at the screen the program rows get R27 and nothing is added |
| T56 | record: -Apply and -Undo each end with one `Log` call, after every other writer call, with the profile folder as %USERPROFILE%; a `Log` call that throws adds N7 and changes neither the rows nor the exit code |
| T57 | Set-PCHardening.ps1: no writer part has an `-AIRoot` parameter |
| T58 | the table ends with the footer of section 2, and N2's sentence names Microsoft Defender's real-time protection, not these settings |
| W1 | Windows only: the real reader answers every name without an error and in the shape the planners take |
| W2 | Windows only: the bare run in a child powershell.exe ends with exit code 0 and a table of 16 rule rows, a CFA row and an LSA row |
| W3 | Windows only: that run changed nothing: rule ids and actions, CFA mode and allowed programs, RunAsPPL, RunAsPPLBoot and the absence of the store key are the same before and after |
| W4 | Windows only: the real store part, `Store` reader and `StoreAcl` reader on a scratch key: a value named by a full path with backslashes comes back under that name; `$null` removes a value, and a subkey; a key the part made is owned by Administrators and passes `Get-PchAclFault`, and fails it once the test gives Users set value there; `HKLM:\SOFTWARE` itself, read only, passes with its CREATOR OWNER entry; when the last value goes, the scratch key goes (section 7, rule 6) |
| W5 | Windows only: the real LSA part and `Lsa` reader on a scratch key: absent, 0 and 2 each read back as written, the value is a DWORD, delete gives absent, and a value of another type reads `unreadable` |
| W6 | Windows only, read-only: for every writer name, the cmdlet of `Get-PchDefenderCall` exists, has each parameter named, and each action name is one that parameter's type takes |
| W7 | Windows only: the real `Programs` rows and `Get-PchAclFault` find no fault for cmd.exe in System32, its folder and the folders above, and find one for a file the test makes in its temp folder |

On Linux the block W1 to W7 prints one SKIP line; that exact line has to be declared (below). On
the Windows job nothing in it may skip: W4 and W5 need an elevated runner, which GitHub's Windows
runners are (from memory), and W6 needs the Defender cmdlets. Where one is missing the assertion
fails, so that it cannot go quiet.

**Registrations for the integrator** (none of these files belongs to the builder of the two):

| File | Change |
|---|---|
| tests/Invoke-AllTests.ps1:243-256 | a row in `$suites`: Name `PCHardening`, the test file, no arguments, Pass `PC HARDENING TEST PASSED`. Not in `$stepOnlySuites` (:260-262): the suite needs no Docker engine and is safe in the full run. `Get-StepBanner` (:264) then finds its banner for -Step; check that `Get-SuitesForChange` (:274) picks the suite for a change to Set-PCHardening.ps1 |
| .github/workflows/local-llm-windows.yml:97-108 | a step like the two there: `Invoke-AllTests.ps1 -Step .\local-llm\tests\Invoke-PCHardeningTest.ps1` under `shell: powershell` |
| .github/workflows/local-llm-linux.yml:66 | the SKIP line of W1 to W7, word for word, under `LAI_DECLARED_SKIPS`, and the count in the comment above it (:60) |
| Install-LocalAI.ps1:213, :555-564 and tests/Invoke-InstallerMockRun.ps1 | `Set-PCHardening.ps1` in `$ToolkitItems`: that copies it to the Scripts folder. It does not put it where R04 and R06 point. The administrators-only copy `$ElevatedDir` (:219) is made only inside `Register-ResumeTask`, which runs before a reboot (:581) and in the -Resume repair (:870), so an install or update without a restart leaves it missing or old (Get-LocalAI.ps1:535-536 says the same). Needed, as a change to the installer: it makes or refreshes that copy on every run that has administrator rights, and sets the copy's owner to Administrators (S-1-5-32-544), which `Set-LaiPrivateAcl` (lib/LocalAI.psm1:335) does not do. And a mock-run assertion: after an install without a restart the copy holds `Set-PCHardening.ps1` and `lib` |
| config/agent-rules.md and tests/Invoke-InstallerMockRun.ps1:239-247 | the rules for a local agent: `Set-PCHardening.ps1 -Apply` and `-Undo` under Never (line 28 already forbids changing Windows security settings) and in the mock run's list at :239. The bare run under "Fine without asking" and in the list at :242 only if the owner wants an agent to run it; :245-247 checks that every script named exists |
| Uninstall-LocalAI.ps1:253-258 | it deletes the administrators-only copy, the one that can undo. Before that it starts that copy with `-Undo -Only Apps`: the allowed programs go even if the rest stays, because an entry for a program that is gone can be filled by another. What happens to the copy, the store and `LocalAI-Logs` depends on question 5 |
| README.md and tests/README.md | the script (DOCPARAM checks every switch named there; MDTABLE the tables) and the suite. The README gives -Apply and -Undo by the Program Files path only, repeats the footer of section 2, names moving ComfyUI's output folder before -AllowWritable, and gives the by-hand undo of each switch |
| Test-PCSecurity.ps1:1073, :1081, :1082 | the two next steps may name the script once it exists; :1081's advice to protect the Backups folder depends on question 2. The Controlled folder access row passes "on" from the setting alone (:1082), also while the :963 test fails and nothing acts on the setting: there it has to WARN ("set, but Microsoft Defender is not in charge") |
| IMPROVEMENTS.md | row 86 (5) |

No Start-menu shortcut (lib/LocalAI.psm1:3717 lists them): an opt-in administrator script is
started by its command, which the README gives.

**Not in v1:** rule or folder exclusions, warn mode, added protected folders, a scheduled drift
check, an ASR row in Test-PCSecurity.ps1, the rules C1 may find beyond the 16, a way for
`Find-LaiOllamaDir` to read another account's hive.

## 9. Questions for the owner

The antivirus (section 1) comes first. Then, with what the plan assumes until answered:

1. **Audit days.** How many days must a rule or Controlled folder access have been in audit before
   -Enforce may raise it to block? Assumed: 7.
2. **Protect <AIRoot>\Backups?** Controlled folder access can guard that folder too, but then the
   backup task must be allowed, and it runs as powershell.exe: allowing that allows every script.
   Assumed: no. Test-PCSecurity.ps1:1081 advises it today and would change.
3. **Allow ComfyUI's python.exe?** The backlog row says yes. But python.exe runs any script, and
   ComfyUI's folder can be changed without administrator rights, so the entry lets every program
   running as you past Controlled folder access, custom nodes included (R26, N6). Assumed: not by
   itself. The table shows the row with R26, and you allow it by naming its path with
   -AllowWritable. The way that needs no allowed program: move ComfyUI's output folder out of
   Documents.
4. **Sign-in plug-ins.** Do you sign in with anything but a password, a PIN or built-in Windows
   Hello: a smart card, a fingerprint reader with its own software, a VPN or password tool at the
   sign-in screen? LSA protection may stop it. Assumed: no.
5. **Does uninstalling keep the hardening?** It protects the PC, not the toolkit. Assumed: the
   rules, Controlled folder access and LSA protection stay; the uninstaller says so, names the
   -Undo command, and leaves the stored before-values, the record and a copy of the script that
   can undo. The allowed programs do not stay: an entry for a program that is gone can be filled
   by another, so the uninstaller takes them out.
6. **Run only from the administrators-only copy?** -Apply and -Undo would refuse to run from the
   Scripts folder, which any program running as you can change (R06). Assumed: yes. It needs the
   installer change of section 8; without it that copy is often not there.
