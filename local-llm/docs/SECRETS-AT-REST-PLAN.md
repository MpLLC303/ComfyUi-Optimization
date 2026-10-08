# Secrets at rest under Windows DPAPI (security track item 4): a plan, nothing built yet

Status (2026-10-07): plan only. No code has changed and nothing here has been run. What it says
about the toolkit was read from the code at commit ea191d1 and carries a function name and a line
number (lines move once step 1 inserts code: find by name). What it says about how Windows DPAPI
behaves is its documented behaviour, **not tested against this toolkit**: only the Windows CI job
can run DPAPI, so the Windows tests of step 1 are the first evidence. Where the plan is not sure,
it says "treat as lost".

Today every secret is plain text and only folder permissions protect it: `Set-LaiPrivateAcl`
(lib/LocalAI.psm1:335) through `Protect-Path` (Install-LocalAI.ps1:483) leaves the installing
account, SYSTEM and Administrators.

## What DPAPI adds and what it does not
DPAPI (.NET class `ProtectedData`, scope CurrentUser) encrypts a value with a key Windows keeps
for one account and unlocks with that account's sign-in.

Adds:
- A copy of a protected file that leaves this Windows is useless without that account's Windows
  sign-in: a disk taken out of the PC or read from another operating system, a backup or image of
  `<AIRoot>`, a synced or zipped Secrets folder. Folder permissions stop none of these; they only
  count while this Windows is the one running.
- On the running PC, another administrator account can no longer simply open the file and read
  the password. That is a delay, not a stop (below). A standard account gains nothing here: the
  folder permissions already keep it out.

Does not add:
- **A program running as the owner still reads everything.** It asks Windows to open the value the
  way the toolkit does, with no prompt. Malware, a script or a browser helper under the owner's
  account is neither stopped nor slowed.
- **Anything lasting against an administrator, or a program running elevated or as SYSTEM, on the
  running PC.** It reads the file today: the permissions name SYSTEM and Administrators
  (lib/LocalAI.psm1:354). With DPAPI it can still get the value while the owner is signed in, by
  having its own code run as the owner: the scheduled tasks run as the owner
  (Install-LocalAI.ps1:574, 1921, 1934, 1951) and an administrator can change what they start.
- Strength beyond the Windows sign-in password: an account without one gets close to nothing.
- Anything for Docker: the secret key is in the container's environment
  (stack/docker-compose.yml:56) and `docker inspect` prints it; the installer reads an older
  container's key that way (Install-LocalAI.ps1:1590).
- Anything for `Stack\.env`, the key file and the pending file: they stay plain (next section).
- Anything for the rest of a copied `<AIRoot>`. The key that signs Open WebUI logins (the
  installer's words, Install-LocalAI.ps1:1637-1638) stays plain in `Secrets\openwebui-secret.txt`
  and `Stack\.env`, and `<AIRoot>\Backups` holds archives of the whole Open WebUI data, chats
  included, which the toolkit does not encrypt (Backup-OpenWebUI.ps1:5-13). Whoever holds such a
  copy reads the chats from an archive, and with the key may sign a login of their own on an Open
  WebUI they can reach (how Open WebUI checks a login was not read for this plan: assume yes).
- Anything for a password in use: it is shown once at the end of the first install
  (Install-LocalAI.ps1:2076) and sent to Open WebUI at every sign-in.

What that leaves for the admin file: the text of the password is protected, nothing else. That
counts when this one file leaks alone, or when the same password is used somewhere else. The file
where protection guards data is deep-research.json: the research and its backups are encrypted
with that password (Backup-OpenWebUI.ps1:19-20). It is also the file this plan leaves plain until
the owner has a copy off the PC.

## Per file
Paths under `<AIRoot>`.

| File | Today | Plan | Why |
|---|---|---|---|
| `Secrets\openwebui-admin.json` | plain JSON: email, password, url, rotated | protected in step 3, after the owner has typed the password back (its readers first, step 2) | it guards no data and can be made again with `Set-OpenWebUIPassword.ps1 -PromptCurrent`, but only by someone who knows the password |
| `Secrets\openwebui-admin.pending.json` | plain; exists only during a password change (written Set-OpenWebUIPassword.ps1:71, removed :88) | stays plain for good | it can be the only copy of a live password, and an older `Resolve-LaiPendingPassword` deletes a pending file that has no `password` (lib/LocalAI.psm1:2091-2096) |
| `Secrets\deep-research.json` | plain JSON: username, password, url (Install-LocalAI.ps1:770-773) | stays plain until the owner confirms a copy kept off this PC; then step 3 | the research database is encrypted with this password (Backup-OpenWebUI.ps1:19-20): without it the research and every backup of it are gone |
| `Secrets\openwebui-secret.txt` | plain text | stays plain | the same value sits plain in `.env` (Install-LocalAI.ps1:1663) |
| `Stack\.env` | plain: WEBUI_SECRET_KEY always, WEBUI_ADMIN_PASSWORD until the first sign-in is verified | stays plain, untouched | docker compose reads it as text |

`.env` in detail: no step touches it and no protected value is ever written into it. The installer
copies the opened admin password into it for the first start (Install-LocalAI.ps1:1669, 1785) and
empties that line once the first sign-in is verified (1811-1817). That window stays as it is.

The admin file is today also where the owner looks the password up. The installer makes the
password, shows it once (Install-LocalAI.ps1:2076) and from then on points at the file (2045,
2079; README.md:38 and 51). A protected file shows Base64 instead. So in step 3 the file is
protected only after the owner has typed the password back, which shows it exists outside the
file; the command can show a protected password; and those messages change.

The admin file has eight readers, all the same line
(`Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json`):
Set-OpenWebUIPassword.ps1:45 and the seven of step 2. Its writers are in steps 1 and 3. One of
them is `Resolve-LaiPendingPassword` (lib/LocalAI.psm1:2108): it writes the admin file and reads
only the pending file (2090).

## Which account protects and which reads
- One account does both: the one the installer runs as, `$CurrentUser` (Install-LocalAI.ps1:223).
  The scheduled tasks run as that account, `-LogonType Interactive -RunLevel Limited` (574 resume,
  1921 backup), so they open what the installer protected.
- Elevation does not matter: the elevated installer and the tasks that are not elevated are the
  same account and get the same key.
- Interactive does matter: the tasks run inside the owner's sign-in session, where the key is
  unlocked. A task changed to run without a signed-in session may not get the key (not tested):
  do not change the logon type without a test.
- Installer run under another administrator's account (that password typed at the UAC prompt;
  warning at Install-LocalAI.ps1:1003-1008): unchanged. Already today the tasks and the file
  permissions belong to that administrator (`Protect-Path` uses `$CurrentUserSid`, line 488). The
  protected files then belong to that account too; the signed-in account reads them no more than
  it does today.
- LocalMachine scope is rejected: the key would sit on the same disk needing nobody's sign-in, so
  the removed disk, the main gain, would no longer be covered, and any program on the PC that can
  read the file could open the value. CurrentUser scope does not keep an administrator or SYSTEM
  out either (first section).

## Recovery
Keeps working: changing the Windows password the normal way (typing the old one), a restart, a
Windows update. Loses every protected value: a Windows password that is reset without the old one
(by another administrator, or "I forgot my password"), a Windows reinstall, a new or different
Windows account, another PC. A Microsoft account password reset online, and "Reset this PC" with
"keep my files": not sure, **treat as lost**. `.env`, the key file and the pending file are plain
and are not affected.

A session in which Windows does not hand out the account's key fails the same way while nothing is
lost (some remote and SSH sessions; documented behaviour, not tested): run again from a normal
sign-in before treating anything as lost.

The two cases below differ: `Set-OpenWebUIPassword.ps1` signs in to a running Open WebUI before
it changes anything (line 64), and after a reinstall there is none.

After a reset Windows password (same Windows; Open WebUI still runs with its data):
1. Delete nothing in `<AIRoot>\Secrets`, and do not follow any "start over" advice: the one for
   deep research deletes its saved research (Install-LocalAI.ps1:758).
2. Admin password: run `Set-OpenWebUIPassword.ps1 -PromptCurrent -Prompt`. It asks for a new
   password of your own, twice (12 characters or more), then for the one you sign in to Open WebUI
   with now. The new one is stored protected for the account you are in. Without `-Prompt` the
   script makes a random new password and prints it once (line 55): save it, the one you knew
   stops working. If nobody knows the current password this plan has no answer, which is why
   step 3 asks for it before it protects the file.
3. Secret key: nothing to do, it was never protected.
4. Deep research, file left plain: nothing to do. File protected: paste your saved copy back with
   the step 3 command. No copy: the saved research and every `deep-research-*.tar.gz` backup
   cannot be opened again by anyone; only starting over is left.
5. Run `Test-LocalAI.ps1` and read what it reports.

After a Windows reinstall, or on another PC or account with `<AIRoot>` copied over, when Docker's
data went with the old Windows: there is no Open WebUI to sign in to, so `-PromptCurrent` cannot
work yet, and the installer stops at an admin file it cannot open (step 2). If Open WebUI still
runs with its old data, use the steps above instead. This path was read in the code, not run.
1. Delete nothing, as above.
2. Deep research file protected: paste your saved copy back with the step 3 command first; it
   needs nothing running. The file is then what a plain one would be after a reinstall; how the
   installer and `Restore-OpenWebUI.ps1 -DeepResearch` go on from there was not read for this plan.
3. Admin file protected: move `Secrets\openwebui-admin.json` out of the Secrets folder. Keep it,
   do not delete it.
4. Run the installer. Without an admin file it makes a new login (Install-LocalAI.ps1:1643-1646)
   and shows the password once at the end: save it.
5. To get the old chats back: `Restore-OpenWebUI.ps1`, then
   `Set-OpenWebUIPassword.ps1 -PromptCurrent -Prompt` with the password from when that backup was
   made (Restore-OpenWebUI.ps1:417-418 says the same). If nobody knows that password, do not
   restore: the new install works with its new login, and this plan has no answer for the old
   chats.
6. Run `Test-LocalAI.ps1` and read what it reports.

Before a planned reinstall, a new PC or a new account:
1. Turn the files back to plain (step 3 command).
2. Copy the Secrets folder to where you keep secrets (Backup-OpenWebUI.ps1:22-23).
3. On the new Windows, protect again.

## The old and the new form side by side
Same file name, same folder, same permissions. Only the password field changes.

```json
{ "email": "admin@localhost", "password": "<the password>",
  "url": "http://localhost:3000", "rotated": "2026-10-07T12:00:00" }

{ "email": "admin@localhost", "protected": "dpapi-user-1", "passwordProtected": "<Base64>",
  "url": "http://localhost:3000", "rotated": "2026-10-07T12:00:00" }
```

- `protected` names the form. `dpapi-user-1` means: UTF-8 bytes of the password, DPAPI scope
  CurrentUser, no extra entropy, the result as Base64 in `passwordProtected`.
- A file never holds both `password` and `passwordProtected`. Every other field stays readable.
- A reader that meets any other `protected` value refuses and says to update the toolkit. It
  never reads such a file as an empty password.
- Updating: step 1 and step 2 change nothing on disk. From step 2 every reader understands both
  forms. From step 3 the writers keep the form they find, and only the command changes a form.
  So no protected file can exist before every reader can open it.
- Going back to a toolkit older than step 2: turn the files back to plain first. If that was
  forgotten, the old readers find no `password` and their sign-ins fail; an old installer on an
  empty Open WebUI would put an empty admin password into `.env` (Install-LocalAI.ps1:1669,
  1785), and with deep research it can end at its "start over" advice (758-765). Do not follow
  that. Update again and turn back to plain; for the admin file alone the old
  `Set-OpenWebUIPassword.ps1 -PromptCurrent` also works (it takes the e-mail from the file and
  writes the file plain, lines 45-82).

## Diagnostics redaction
Get-LocalAIDiagnostics.ps1:49-75 collects the exact values to blank out of the bundle: the admin
password and e-mail (58), the key file (62), every `.env` value whose name contains KEY, SECRET,
PASSWORD or TOKEN (64-75). A file it cannot read goes into `$script:unreadableSecrets` and the run
ends with a warning to check the bundle before sharing it (228-229).

Against a protected admin file the line at 58 would not fail. It would find no `password`, add
nothing and warn about nothing, leaving only the general patterns to catch the password in a log.
So in step 2:
- Line 58 reads through `Read-LaiSecretFile`, which **throws** when the value cannot be opened
  (Diagnostics run from another account, the case the comment at 53-54 describes). The existing
  catch then lists the file and the existing warning appears. This is why the reader must throw
  and never return an empty password.
- In that catch, read once more with `-NoPassword` so the e-mail is still redacted by value.
- The deep-research.json read switches the same way.

That read does not exist yet, and the gap is there today, whatever is decided about DPAPI: neither
deep-research.json nor openwebui-admin.pending.json is on the by-value list (neither name appears
in the script), although the bundle carries `docker logs deep-research` (179) and a pending file is
there exactly when a password change went wrong and may hold the live password. Handed to the
integrator as its own backlog row, built before step 2 and whatever the owner answers below: both
passwords go on the by-value list, each with the existing unreadable-file warning. Step 2 then
only switches the admin and deep research reads; the pending file is always plain and its read
stays.

## Questions for the owner
Answered so far (owner's decision of 2026-10-07): he wants a recovery copy to keep offline. That
bears on questions 2 and 4, which ask whether the passwords are saved somewhere off this PC: such
a copy is to exist, kept offline, before a file is protected. How the copy is made, what it holds
and where the owner is told to keep it is not designed yet; it belongs to step 3 (the command that
switches protection on) and has to be written into this plan before step 3 is cut. Nothing is
built. Whether he wants protection switched on at all (question 1) and questions 3, 5 and 6 are
open as written.

1. Do you want this? It protects the text of the stored admin password when a copy of that one
   file leaves this PC (a backup, a synced folder, a disk taken out). It does not protect against
   a program running under your account, nor against another administrator account or anything
   running with administrator rights on this PC. And a copy of the whole `<AIRoot>` folder still
   holds your chats (the Backups folder) and the key that signs Open WebUI logins, both
   unprotected: against such a copy you gain close to nothing for Open WebUI. The file where
   protection guards data is the deep research one (question 4).
2. Do you know your Open WebUI admin password, or is it saved somewhere off this PC? Today the
   file is where you look it up. Once protected it shows scrambled text, so you are asked to type
   the password before the file is protected, and a command shows it to you afterwards.
3. Do you sign in to Windows with a password you know and will still know? If it is ever reset
   instead of changed, the protected passwords are lost and you type the Open WebUI password in
   again.
4. Is the deep research password saved somewhere off this PC, such as a password manager? Without
   a copy that file stays plain. With one, do you want it protected?
5. Switch it on only when you run a command yourself (recommended), or by itself at an update?
   Either way you type the admin password once first.
6. Does anything but your own account need these files: a second Windows account that uses Local
   AI, a copy of the Secrets folder you count on for a new PC, a reinstall you are planning? A
   protected copy is useless there; you would turn the files back to plain first.

## Build steps
Nothing from the repository may run on the owner's PC. The tests run in CI only: DPAPI assertions
on the Windows job (Windows PowerShell 5.1), plain-form assertions on both jobs.

Skips. A Windows-only block prints a SKIP line on the Linux `gate` job, and that job fails on any
skip message that is not a line of its `LAI_DECLARED_SKIPS`
(.github/workflows/local-llm-linux.yml:66-85; tests/README.md, "How a skip is declared"). The
workflow file is in no step's file list, so every new skip message is handed to the integrator,
who adds the line in the merge that brings the step in. Until then the Linux job of that branch
is red at "Cross-platform unit tests" with `ASSERT FAIL skipped under CI, not declared for this
job: <message>`, and the Windows job is the evidence. Report that; never drop the SKIP line to
turn the job green. A block of step 2 or 3 that prints step 1's message letter for letter needs
no new line; any other message is handed over the same way.

### Step 1: the functions and the password script; files on disk stay plain
Files, exactly: `local-llm/lib/LocalAI.psm1`, `local-llm/Set-OpenWebUIPassword.ps1`,
`local-llm/tests/Invoke-WindowsUnitTests.ps1`. Nothing in step 1 passes `-Form Protected`, so no
file on a real install changes form and the seven other readers are unchanged. Only the tests
write the protected form. Hand to the integrator, both for the merge of the step 1 branch:
- a line in tests/README.md for the new section;
- the line `DPAPI round trips need Windows` in `LAI_DECLARED_SKIPS` of the `gate` job in
  .github/workflows/local-llm-linux.yml, and the count in the comment above that list (line 60:
  nineteen becomes twenty). The Linux job of the step 1 branch is red until then (Skips, above).

Four functions, inserted after `New-LaiPassword` (lib/LocalAI.psm1:384-393):
- `Protect-LaiSecretText -Text <string>` returns the Base64 text. Off Windows it throws M1. When
  Windows cannot protect it throws M6. It never returns nothing or an empty text.
- `Unprotect-LaiSecretText -Blob <string>` returns the text. Off Windows it throws M1. Text that is
  not Base64, was changed, or was protected by another account: throws M2. The `Add-Type` failing:
  M6.
- `Read-LaiSecretFile -Path <string> [-NoPassword]` returns the object `ConvertFrom-Json` gives,
  with `password` filled in either form. Plain file: returned as it is. `protected` equal to
  `dpapi-user-1`: `password` is added from `passwordProtected` (M4 when that is missing); a
  failure throws `Cannot read the password in <Path>: ` followed by M1, M2 or M6. Any other
  `protected` value: throws M3, checked before anything else, on every system. `-NoPassword`
  never opens anything: a protected file comes back with `password` set to ''.
- `Save-LaiSecretFile -Path <string> -Value <hashtable or object> [-Form Keep|Plain|Protected]`,
  default Keep. In this order:
  1. No non-empty `password` in `-Value`: throws M5.
  2. The form. Keep looks only at the marker of the file that is there and opens nothing:
     `dpapi-user-1` gives Protected; no `protected` field, no file, or text that is not JSON gives
     Plain; any other marker throws M3.
  3. The whole new text, in memory: every field of `-Value` except `password`, `protected` and
     `passwordProtected`, then `password` (Plain) or the two protected fields (Protected).
     `Protect-LaiSecretText` is called here; a failure throws `Cannot store the password in
     <Path>: ` followed by M1 or M6, and so does a result that is empty.
  4. Only now the file: `Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop`, which
     throws when it fails.

  The rule: whatever fails in 1 to 3 throws before the file is touched, and every failure throws.
  A caller therefore never reaches the line after its save, which removes the pending file
  (lib/LocalAI.psm1:2109, Set-OpenWebUIPassword.ps1:88), unless the new password is on disk.

Messages (the tests match parts of them):
- M1 `Protecting a stored password with the Windows account works on Windows only.`
- M2 `This Windows account cannot open the protected password (protected by another account, or
  the Windows password was reset, or Windows was reinstalled, or this is a remote session without
  the account's key).`
- M3 `<Path> is protected in a form this toolkit version does not know ('<marker>'). Update the
  toolkit.`
- M4 `<Path> is marked as protected but holds no protected password.`
- M5 `Nothing to store in <Path>: the value has no password.`
- M6 `Windows data protection did not work in this session (<reason>).` The reason is what
  Windows said, or `no result`.

The core of the two text functions (a sketch, not run anywhere). Every .NET call and the
`Add-Type` sit in a try that throws (trap 2):

```powershell
# Both functions start with:
if ($env:OS -ne 'Windows_NT') { throw '<M1>' }
try {
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) { Add-Type -AssemblyName System.Security -ErrorAction Stop }
    $scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
} catch { throw "<M6 with $($_.Exception.Message)>" }
# Protect-LaiSecretText then:
$blob = ''
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $blob = [Convert]::ToBase64String([System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, $scope))
} catch { throw "<M6 with $($_.Exception.Message)>" }
if (-not $blob) { throw '<M6 with no result>' }
return $blob
# Unprotect-LaiSecretText then:
$bytes = $null
try { $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Blob), $null, $scope) }
catch { throw '<M2>' }
if ($null -eq $bytes) { throw '<M2>' }
return [System.Text.Encoding]::UTF8.GetString($bytes)
```

Three call sites:
1. `Resolve-LaiPendingPassword`, lib/LocalAI.psm1:2108. The raw copy of the pending file would
   turn a protected file plain. Replace it with `Save-LaiSecretFile -Path $credFile -Value $p`
   (`$p` is the pending object parsed at 2090). Lines 2090-2096 and the log line at 2110 stay.
   No try around the save: when it throws, the function must end before line 2109 removes the
   pending file.
2. Set-OpenWebUIPassword.ps1:45 (script body). `$cred = Read-LaiSecretFile -Path $credFile` in a
   try. In the catch: with `-PromptCurrent` or `-CurrentPassword` given, read again with
   `-NoPassword` (the owner is supplying the live password; only the e-mail is needed);
   otherwise throw the same message plus ` If you know the password Open WebUI accepts now, run
   this again with -PromptCurrent.`
3. Set-OpenWebUIPassword.ps1:82 (script body). `Save-LaiSecretFile -Path $credFile -Value $updated`
   inside the existing try. Line 71 stays: the pending file is always plain.

Tests: a new section `=== secret files: plain and protected form ===` after
Invoke-WindowsUnitTests.ps1:170, before the `=== private ACLs` header. [W] = inside
`if ($onWindows)`; [L] = in its else branch, next to `Skip 'DPAPI round trips need Windows'`;
no mark = both jobs. For 22-28 and 31 use the harness of lines 115-141: an `HttpListener` on
`http://127.0.0.1:<random port>/` in the test process, the code under test in a child started from
a small client script that writes its result to a file. For 24-28 the client script sets
`$global:LASTEXITCODE = 0`, runs `Set-OpenWebUIPassword.ps1 -AIRoot <root> -NewPassword <text>
-Quiet` in a try (a throw counts as exit 1) and writes the exit code and all output (`*>&1`);
`<root>\localai-config.json` holds `{"WebUIPort": <port>}`. Replies in order, all 200 and
`application/json`: sign-in `{"role":"admin","token":"tok-123"}`, change `true`, sign-in again.
Keep each request body: the first carries the password the script signed in with.

1. `a plain secret file reads with its password and e-mail`
2. `saving with no -Form keeps a plain file plain, and the old one-line reader still finds the password`
3. `a file that does not exist yet is written plain`
4. `other fields (url, rotated) survive a save`
5. `a marker this version does not know is refused, not read as an empty password`
6. `-NoPassword returns the e-mail of a protected file without opening it`
7. `a value without a password is refused`
8. [L] `off Windows, protecting says it works on Windows only`
9. [L] `off Windows, a protected file is refused with that message, not read as empty`
10. [W] `protect then unprotect returns the same text, with a non-ASCII character`
11. [W] `the protected text is Base64 and does not contain the password`
12. [W] `protecting the same text twice gives two different texts that both open`
13. [W] `a protected text with one byte changed is refused: cannot open`
14. [W] `text that is not Base64 is refused the same way`
15. [W] `-Form Protected writes the marker dpapi-user-1 and passwordProtected, and no password field`
16. [W] `the password appears nowhere in the protected file`
17. [W] `a protected file reads back with the same password and e-mail`
18. [W] `saving with no -Form keeps a protected file protected, with the new password`
19. [W] `-Form Plain turns a protected file back into the plain form`
20. [W] `a protected file with a changed blob makes the read throw, it does not return an empty password`
21. [W] `saving with no -Form over a protected file this account cannot open writes one that opens`
22. `a promoted pending password is stored plain in a plain file (got '<result>')`
23. [W] `a promoted pending password keeps a protected file protected (got '<result>')`
24. `rotation over a plain file: exit 0, still plain with the new password, no pending file (exit <n>)`
25. [W] `rotation over a protected file signs in with the opened password`
26. [W] `rotation over a protected file leaves it protected, with the new password (exit <n>)`
27. [W] `a protected file this account cannot open stops the rotation, names -PromptCurrent and changes nothing (exit <n>)`
28. [W] `with -CurrentPassword the same file is rotated and protected again (exit <n>)`
29. [L] `off Windows, -Form Protected over a plain file is refused with that message and leaves the file byte for byte`
30. [L] `off Windows, saving with no -Form over a file marked protected is refused the same way and leaves it byte for byte`
31. [L] `a pending password that cannot be stored protected stays in the pending file, and the admin file is unchanged`

For 29-31 the file marked protected is hand-written: marker `dpapi-user-1` and any Base64 text.
For 31 the client script calls `Resolve-LaiPendingPassword` with no try, as client2.ps1 does
(121-125), and the listener gives one reply, sign-in 200. The throw ends the client before its
result line, so the test reads the two files after the child has ended: the pending file is still
there and the admin file equals the hand-written one byte for byte.

22 and 24 pass before the change too: they guard the plain path. All others fail without it, the
refusals only when written as trap 11 says:
- 1-4, 6, 10-12, 15-19 and 21 call functions that do not exist.
- 5, 7-9, 13, 14, 20, 29 and 30 expect a refusal. A call to a function that does not exist is
  refused too, so they fail before the change only because they match the message (M1, M2, M3 or
  M5), which a command-not-found error does not contain.
- 23 because the raw copy at 2108 writes the plain pending text; 25 because line 45 finds no
  `password`; 26 because line 82 writes plain; 27 and 28 because line 45 has no way past a value
  it cannot open; 31 because the raw copy at 2108 overwrites the admin file and 2109 removes the
  pending file.

Not tested: M6 and the empty-result check of the save. The Windows job cannot make `Protect` fail
(one account, a normal session). 29-31 prove through M1, on Linux, that a save which cannot
protect throws before it writes and that the pending file survives it.

Traps:
1. The module is imported on Linux. `Add-Type -AssemblyName System.Security` goes inside the two
   text functions, behind the `$env:OS` guard (as in `Enable-LaiKeepAwake`, lib/LocalAI.psm1:325),
   never at module level.
2. A failed .NET call only ends its own statement, and the module sets no
   `$ErrorActionPreference = 'Stop'` (lib/LocalAI.psm1:11 is only `Set-StrictMode`). Without a try
   that throws, `Unprotect-LaiSecretText` would return an empty text and `Protect-LaiSecretText`
   nothing. The save would then write the marker with an empty `passwordProtected`, and
   `Resolve-LaiPendingPassword`, called with no try at Set-OpenWebUIPassword.ps1:44, would go on
   to remove the pending file: the only copy of the live password. So `Protect`, `Unprotect`,
   `FromBase64String` and the `Add-Type` all sit in a try that throws (sketch), and the save
   checks the result once more. `Protect` can fail where Windows does not hand out the account's
   key: some remote and SSH sessions (documented behaviour, not tested).
3. A value this account cannot open throws. It is never treated as cut off or empty. Leave the
   pending read at 2090 alone: its catch turns any error into "cut off" and 2094 deletes the file.
4. CI has one account, so nothing can be protected as somebody else. Make the "cannot open" case
   by changing one byte: decode the Base64, flip the last byte, encode again.
5. Invoke-UpdateWebUITest.ps1:379-398 (Linux, real Open WebUI) reads the file with the old line,
   expects `.password` and matches the log text `had gone through`: plain must stay plain.
6. Nothing to register for the exports: `Export-ModuleMember -Function *-Lai*` (3757) takes the
   four names as they are.
7. Static rule ENCODING (tests/Invoke-StaticChecks.ps1:180-211): `-Encoding UTF8` on every
   `Get-Content` whose path text contains json, cred, secret, pending, config, state or env, in
   the test file too, and `-Encoding` on every `Set-Content` in the module and the script.
8. Saving. Inside the module the caller's error preference does not apply (comment at
   lib/LocalAI.psm1:250-251): put `-ErrorAction Stop` on `Get-Content` and `Set-Content`. The save
   must throw when it fails (the catch at Set-OpenWebUIPassword.ps1:83 prints the new password and
   points at the pending file). Replace the content in place, no delete and recreate, no temp file
   swapped in: the file's permissions must survive (comments at 2107 and the script's line 81).
9. `Invoke-Child` is defined at Invoke-WindowsUnitTests.ps1:368, after the new section, and the
   sections above never read `$proc.ExitCode`: use their client-script pattern (120-128).
10. ASCII only in source: build the non-ASCII test character with `[char]0x00E9`. PSScriptAnalyzer
    runs in CI: every declared parameter must be used.
11. "Is refused" means the message. Every assertion that expects a refusal (5, 7-9, 13, 14, 20,
    29, 30) matches part of M1, M2, M3 or M5 in the text of the caught error, never only that
    something was thrown. A call to a function that does not exist throws too, and a try in the
    test also catches a .NET error that the function itself let through (trap 2).

### Step 2: the other seven readers
Files: `Get-LocalAIDiagnostics.ps1` (58), `Install-LocalAI.ps1` (`Get-AdminCredential`, 672, and
the deep research read at 757), `Restore-OpenWebUI.ps1` (411), `Sync-LocalAISkills.ps1` (34),
`Test-LocalAI.ps1` (308, and the deep research read at 257), `Update-Models.ps1` (178),
`Watch-LocalAI.ps1` (770), `tests/Invoke-WindowsUnitTests.ps1`, `tests/Invoke-StaticChecks.ps1`.
Each read becomes `Read-LaiSecretFile`. Each script decides what "cannot open" means for it. The
installer: `Get-AdminCredential` (670-674) is its one read of the admin file, called at 965, 1643,
1646, 1777, 1791, 1820 and 2068. A file it cannot open stops the run at the first of them it
reaches, with the reader's message and the two ways on (Recovery): Open WebUI still runs with its
data, `Set-OpenWebUIPassword.ps1 -PromptCurrent -Prompt`; its data is gone, move the file out of
Secrets and run the installer again. It never makes a new login over a file it cannot open; it
makes one only when the file is missing, as today (1643-1646). The Diagnostics reads come after
the backlog row named under Diagnostics redaction. Still nothing on disk changes.

Tests: [W] the diagnostics section (Invoke-WindowsUnitTests.ps1:558) once more with a protected
admin file: the password is still redacted; with a changed blob: exit 0, the warning names the
file, the e-mail is still redacted. A static rule with canaries: the old one-line read of
openwebui-admin.json or deep-research.json outside the module is a problem. The Linux job keeps
proving the plain form against real servers. The Windows job has no containers, so a script that
needs Docker before its sign-in gets the static rule only: say which, per script. The installer's
stop message needs an assertion too; how the suite reaches one installer function without running
the installer was not read for this plan. Hand to the integrator: any new skip message (Skips).

### Step 3: the writers, the command, the registrations
Files: `Install-LocalAI.ps1` (`Save-AdminCredential` 676-687, the write at 974, the deep research
write at 773: all through `Save-LaiSecretFile`, form Keep, so the installer never changes a form;
and its messages that send the owner to a file to read a password: 2045 and 2079 for the admin
file, 2047 and 2074 for deep research. Against a protected file they name the command's show
action instead. 2076 stays: a login the installer has just made is in a plain file),
a new command (working name `Protect-LocalAISecrets.ps1`), `Backup-OpenWebUI.ps1` (the advice at
22-23: a copied protected file opens nowhere else), `tests/Invoke-WindowsUnitTests.ps1`. For the
integrator: the installer copy list, the uninstaller, the static-check file lists, README.md
(lines 38 and 51 send the owner to the admin file as well), tests/README.md, any new skip message
(Skips), the backlog row.

The command:
- With no switch it lists each file as plain, protected and opens, or protected and cannot be
  opened. It also names, without printing them, the plain copies of the admin password it finds:
  a leftover pending file and a non-empty `WEBUI_ADMIN_PASSWORD` in `.env`.
- One switch protects the admin file, and only after the owner has typed the admin password and
  it equals the one in the file. Otherwise it changes nothing and names
  `Set-OpenWebUIPassword.ps1 -PromptCurrent -Prompt`. This is the same gate as for deep research:
  the password must exist outside the file before the file stops showing it.
- One switch shows the password of a protected file on the screen and writes nothing, so nobody
  turns protection off just to read a password.
- One turns every file back to plain.
- Deep research is protected only after the owner pastes its password back from where it is
  saved and it matches. After a loss the same paste writes that file back plain, with nothing
  running and nothing to compare it with: the next sign-in (the installer or `Test-LocalAI.ps1`)
  is the check.
- It never touches the pending file, the key file or `.env`.
- A typed password can also come as a parameter, for automation only, as in
  Set-OpenWebUIPassword.ps1:23-29: that is how the tests supply it.

Tests: [W] plain to protected to plain gives the same fields back; the listing names each of the
three states (changed blob for the third); deep research is refused without a matching paste and
left plain; the admin file is refused after a wrong typed password and left plain; the show action
prints the password of a protected file and changes no file; the listing names a leftover pending
file and a non-empty `WEBUI_ADMIN_PASSWORD` and prints neither value; back-to-plain on a file that
cannot be opened changes nothing and says so. Both jobs:
an installer run leaves a plain file plain. A static rule with canaries: no `Set-Content` to
openwebui-admin.json or deep-research.json outside `Save-LaiSecretFile`.
