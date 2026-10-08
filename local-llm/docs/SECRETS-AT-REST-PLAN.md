# Secrets at rest under Windows DPAPI (security track item 4): a plan, nothing built yet

Status (2026-10-07): plan only. No code has changed and nothing here has been run. What it says
about the toolkit was read from the code at commit ea191d1 and carries a function name and a line
number (lines move once step 1 inserts code: find by name). What it says about how Windows DPAPI
behaves is its documented behaviour, **not tested against this toolkit**: only the Windows CI job
can run DPAPI, so the Windows tests of step 1 are the first evidence. Where the plan is not sure,
it says "treat as lost".

Added 2026-10-08, still plan only: the recovery copy the owner asked for (step 3), questions 2,
4 and 7 to 9, two additions under step 1, and the smaller points of IMPROVEMENTS.md row 121.
What these additions say about the toolkit was read at commit 1e9e510; they name functions, or
say "at 1e9e510" where they give a line. The older line numbers are still those of ea191d1.
Nothing of the toolkit was run for them. One statement, about `ConvertFrom-Json` under step 1,
comes from a one-line check outside the toolkit and says so.

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
- **Anything for a copy of the file made before protection was switched on.** The protect switch
  protects the password that is in the file on that day; it does not change it. So every earlier
  copy still holds that password in plain: an image or a backup of `<AIRoot>`, a Secrets folder
  copied to where secrets are kept (what the help text of Backup-OpenWebUI.ps1 advises), a
  synced or zipped folder. Such a copy stops being worth anything only when the password is
  changed afterwards. That is why the protect switch of step 3 ends by naming
  `Set-OpenWebUIPassword.ps1 -Prompt`, and after it a new recovery copy.
- **A way to change the deep research password.** The toolkit has none (read at 1e9e510). For
  Local Deep Research the module makes the account through the program's own sign-up form
  (`Register-LaiResearchUser`) and signs in (`Connect-LaiResearch`); the only call in the
  toolkit that changes a password is the Open WebUI one, in Set-OpenWebUIPassword.ps1. Whether
  Local Deep Research itself can change a password, and what that would do to a database that
  is encrypted with it, cannot be told from the toolkit's code. One installer message reckons
  with it ("Sign in at ... with the password you set", in `Invoke-DeepResearchSetup`); that is a
  sentence, not a call. Treat the password as one that cannot be changed: an earlier plain copy
  of deep-research.json, and a recovery copy that gets lost, stay good for as long as that
  account exists.

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

The admin file is read in eight places: Set-OpenWebUIPassword.ps1:45 and the seven of step 2.
They are of one shape, `Get-Content -Encoding UTF8` of the file with `-Raw`, piped to
`ConvertFrom-Json`, but they are not one line letter for letter (looked at again at 1e9e510).
Seven carry `Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json`, two of
them inside a longer line: the installer's in a `return ( ... )` in `Get-AdminCredential`, the
one in Get-LocalAIDiagnostics.ps1 in a try together with the redaction calls. The eighth,
Sync-LocalAISkills.ps1:34, has `-Raw` before `-LiteralPath`, and so have the two deep research
reads of step 2. A search for the one line misses those, and so would a static rule written
for it: match the shape. The writers of the admin file are in steps 1 and 3. One of them is
`Resolve-LaiPendingPassword` (lib/LocalAI.psm1:2108): it writes the admin file and reads only
the pending file (2090).

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

Both start from the recovery copy (step 3, "The recovery copy") and its date. With several
copies the newest date counts. A copy is in date when no password was changed after it was made.
For the admin password the listing of the step 3 command helps: it shows when the password
script last changed it (`rotated`, readable in a protected file as well; a file the installer
wrote has none). The proof is the sign-in, and trying costs nothing, because the password script
signs in before it changes anything. Where a step says "from the copy", an owner without a copy
uses a password he knows from elsewhere; without either, the step says what is left.

After a reset Windows password (same Windows; Open WebUI still runs with its data):
1. Take the recovery copy and read its date.
2. Delete nothing in `<AIRoot>\Secrets`, and do not follow any "start over" advice: the one for
   deep research deletes its saved research (Install-LocalAI.ps1:758).
3. Admin password: run `Set-OpenWebUIPassword.ps1 -PromptCurrent -Prompt`. It asks for a new
   password of your own, twice (12 characters or more), then for the one you sign in to Open WebUI
   with now: the admin password from the copy. The new one is stored protected for the account
   you are in. Without `-Prompt` the script makes a random new password and prints it once
   (line 55): save it, the one you knew stops working. If Open WebUI refuses the password from
   the copy, nothing was changed and the copy is out of date for it. If nobody knows the current
   password this plan has no answer, which is why step 3 asks for it before it protects the file.
4. Secret key: nothing to do, it was never protected.
5. Deep research, file left plain: nothing to do. File protected: paste its password from the
   copy back with the step 3 command. No copy: the saved research and every
   `deep-research-*.tar.gz` backup cannot be opened again by anyone; only starting over is left.
6. Run `Test-LocalAI.ps1` and read what it reports.
7. The admin password is a new one now and the copy holds the old one: make a new copy
   (`-RecoveryCopy <folder>`) and destroy the old one.

After a Windows reinstall, or on another PC or account with `<AIRoot>` copied over, when Docker's
data went with the old Windows: there is no Open WebUI to sign in to, so `-PromptCurrent` cannot
work yet, and the installer stops at an admin file it cannot open (step 2). If Open WebUI still
runs with its old data, use the steps above instead. This path was read in the code, not run.
1. Take the recovery copy and read its date.
2. Delete nothing, as above.
3. Deep research file protected: paste its password from the copy back with the step 3 command
   first; it needs nothing running. The file is then what a plain one would be after a
   reinstall; how the installer and `Restore-OpenWebUI.ps1 -DeepResearch` go on from there was
   not read for this plan.
4. Admin file protected: move `Secrets\openwebui-admin.json` out of the Secrets folder. Keep it,
   do not delete it.
5. Run the installer. Without an admin file it makes a new login (Install-LocalAI.ps1:1643-1646)
   and shows the password once at the end: save it.
6. To get the old chats back: `Restore-OpenWebUI.ps1`, then
   `Set-OpenWebUIPassword.ps1 -PromptCurrent -Prompt` with the password from when that backup was
   made (Restore-OpenWebUI.ps1:417-418 says the same). That is the admin password from the copy
   when no password change lies between that backup and the copy; the backup's date is in its
   file name. If nobody knows that password, do not restore: the new install works with its new
   login, and this plan has no answer for the old chats.
7. Run `Test-LocalAI.ps1` and read what it reports.
8. The admin password is a new one after step 5 or 6: make a new copy and destroy the old one.

Before a planned reinstall, a new PC or a new account:
1. Take the recovery copy and read its date. If a password was changed since, make a new one
   first: it is the way back if a step below goes wrong.
2. Turn the files back to plain (step 3 command).
3. Copy the Secrets folder to where you keep secrets (Backup-OpenWebUI.ps1:22-23).
4. On the new Windows, protect again. The command asks for both passwords from the copy, as it
   did the first time.

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
- Going back to an older toolkit while a file is protected: turn the files back to plain first,
  whichever older toolkit it is. If that was forgotten, it depends on where the older one stands:
  - Older than step 1: the old readers find no `password` and their sign-ins fail; an old
    installer on an empty Open WebUI would put an empty admin password into `.env`
    (Install-LocalAI.ps1:1669, 1785), and with deep research it can end at its "start over"
    advice (758-765). Do not follow that. Update again and turn back to plain; for the admin file
    alone the old `Set-OpenWebUIPassword.ps1 -PromptCurrent` also works (it takes the e-mail from
    the file and writes the file plain, lines 45-82).
  - At step 1: the seven other readers are still the old ones, so the same failures, and the
    same "do not follow that". The way through the password script is closed here: from step 1
    it opens both forms and keeps the form it finds (call sites 2 and 3), so `-PromptCurrent`
    leaves the file protected and the seven still find no `password`. Nothing in step 1 changes
    a form. Update again and turn back to plain.
  - At step 2: every reader opens both forms, so nothing fails. The installer's writers are
    still the old ones (step 3 changes them). When the installer saves a login that the owner
    typed in because the stored one was refused (`Save-AdminCredential`, and the write in its
    early sign-in check), it writes the admin file plain, without a word and without the gate of
    step 3. Nothing is lost by that; the deep research write only ever makes a new file. After
    updating again, the listing shows which file is plain: protect it again.

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
Answered so far (owner's decision of 2026-10-07): he wants a recovery copy of the stored
passwords to keep offline. The copy is designed under step 3, "The recovery copy": what it holds,
its form, the switch that makes it, where it may not be written, and that a file is protected
only after its password was typed back from the copy. Questions 2 and 4 are rewritten around it
and 7 to 9 are new. Each of those five carries a recommended answer, and step 3 is built to the
recommended answers unless he says otherwise. Nothing is built. Whether he wants protection
switched on at all (question 1) and questions 3, 5 and 6 are open as written.

1. Do you want this? It protects the text of the stored admin password when a copy of that one
   file leaves this PC (a backup, a synced folder, a disk taken out). It does not protect against
   a program running under your account, nor against another administrator account or anything
   running with administrator rights on this PC. And a copy of the whole `<AIRoot>` folder still
   holds your chats (the Backups folder) and the key that signs Open WebUI logins, both
   unprotected: against such a copy you gain close to nothing for Open WebUI. The file where
   protection guards data is the deep research one (question 4).
2. The Open WebUI admin password goes on the recovery copy, with its e-mail and address. Today
   the file is where you look that password up. Once protected it shows scrambled text, and the
   copy, or the command that shows it on the screen, is where you read it. Shall the admin file
   be protected once you have typed its password back from the copy? Recommended: yes, if your
   answer to 1 is yes. Without the typing back the file stays plain. After every password change
   the copy has to be made again (the password script tells you), and a copy that gets lost can
   be made worthless for this password by changing it and making a new copy.
3. Do you sign in to Windows with a password you know and will still know? If it is ever reset
   instead of changed, the protected passwords are lost and you type the Open WebUI password in
   again.
4. The deep research password goes on the recovery copy too, with its user name and address. It
   is the one password that guards data: without it the saved research and every backup of it
   cannot be opened by anyone. Shall that file be protected once you have typed or pasted its
   password back from the copy? Recommended: yes, if your answer to 1 is yes. Without a copy you
   have confirmed that way the file stays plain. Know before you answer: the toolkit cannot
   change this password, so a copy that gets lost stays good for deep research.
5. Switch it on only when you run a command yourself (recommended), or by itself at an update?
   Either way you type the admin password once first.
6. Does anything but your own account need these files: a second Windows account that uses Local
   AI, a copy of the Secrets folder you count on for a new PC, a reinstall you are planning? A
   protected copy is useless there; you would turn the files back to plain first.
7. Shall the recovery copy also hold the key that signs Open WebUI logins? Recommended: no. The
   key is never protected, so nothing in this plan can lose it. If its file is ever gone the
   installer makes a new one, and the price, by the installer's own comment, is that everybody
   signs in again. And on a copy that gets lost it is the one line you could not make worthless:
   no command of the toolkit changes the key. Not read for this plan: what else Open WebUI does
   with that key. Should it also encrypt stored data with it, this answer is looked at again.
8. After a password change the copy you confirmed holds the old password. Shall the file stay
   protected (recommended), with the password script telling you each time to make a new copy?
   Or go back to plain until you have typed the new password back from a new copy? Staying
   protected means: between the change and the new copy, the new password exists outside the
   file only if you typed it yourself or saved the one that was shown once. Going back to plain
   means: every password change switches protection off until you switch it on again.
9. Where will the copy live: on paper (recommended) or on a USB stick? Paper: write the copy to
   a stick, print it from the stick, keep the paper where you keep papers that matter. No program
   reads paper and it does not stop working in a drawer; the price is typing a password back by
   hand, 31 characters for one the toolkit made (those leave out the letters and digits that
   look alike, `New-LaiPassword`). A stick: nothing to type, but whatever runs under your
   account reads it whenever it is plugged in, and a stick can stop working unnoticed (both are
   general behaviour, of Windows and of flash memory, not tested). Either way: not in or beside
   this PC, not with the backups, and after printing the stick still holds the file, because
   deleting it does not wipe it (documented behaviour of file systems, not tested): keep the
   stick with the paper or use it for nothing else.

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
  twenty-three becomes twenty-four). The Linux job of the step 1 branch is red until then (Skips, above).

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
no mark = both jobs. For 22-28 and 31 use the harness of lines 115-141: an `HttpListener` from
`Start-TestListener` (a loopback port the system names free; never a drawn number, which can be a
port that is taken) in the test process, the code under test in a child started from
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

Two additions of 2026-10-08 (IMPROVEMENTS.md row 121 (1) and (3)). Step 1 is built from the text
above as it stands plus these two:
- M7: the reader refuses an empty or cut-off file with a message of its own. `Read-LaiSecretFile`
  throws M7 when the file is empty or when its text is not JSON (cut off while it was written),
  on every system and before it looks for a marker: such a file has none. M7 names the file and
  says that it is empty or cut off. Its wording is the one step 1 is built with; this plan does
  not fix it, and test 32 matches a part of it. Why: the text above promises a refusal only when
  a protected value cannot be opened. Read with the old line, an empty file gives nothing and no
  error, and the caller that then asks for `.password` holds an empty one, which the reader must
  never hand out (Diagnostics redaction). A cut-off file ends in the error of `ConvertFrom-Json`,
  which names no file and repeats the text it could not read; in this file that text can be part
  of the password. (Both under Windows PowerShell 5.1, not tested in CI: seen in a one-line check
  on 2026-10-08.) So M7 does not carry that error's text. This last sentence is not in what
  step 1 is built from: hold the reader as built against it.
- Three refusals are asserted on both jobs. "A save that fails stops before the file is touched"
  is proved above through M1, on the Linux job only (29-31), while the loss it prevents, a
  pending file removed although the new password is not on disk, can only happen on Windows,
  where files are protected. M3 and M4 are thrown on every system, so the Windows job asserts
  through them as well: the rule itself with M3 (33, 34), and with M4 that a file marked
  protected without its value is refused and not read as an empty password (35). For 35, M4 is
  checked before the platform guard: the reader looks for `passwordProtected` before it calls
  `Unprotect-LaiSecretText`, where M1 is thrown. A file marked `dpapi-user-1` that holds no
  protected password is then refused with M4 on both jobs, and never with M1 on Linux.

Four tests for them, no mark (both jobs), after 31 in the same section; no new skip message. The
marker no version knows is hand-written, for example `not-a-known-form`.

32. `an empty file and a cut-off file are refused with a message of their own`
33. `saving with no -Form over a marker this version does not know is refused and leaves the file byte for byte`
34. `a pending password stays in the pending file when the admin file has a marker this version does not know, and the admin file is unchanged`
35. `a file marked protected that holds no protected password is refused with a message of its own`

32, 33 and 35 are refusals as trap 11 means it: each matches part of its message (M7, M3, M4),
never only that something was thrown. 34 uses the harness of 31, with the admin file carrying the
unknown marker: one reply, sign-in 200, and the two files are read after the child has ended. Why
each fails without the change:
- 32: neither a function that does not exist nor `ConvertFrom-Json` says M7's words, and a reader
  built from the text above alone does not refuse the empty file at all.
- 33: the function does not exist, and that error does not contain M3. The bytes are compared as
  well, so a save that refused only after it wrote fails too.
- 34: the raw copy at 2108 overwrites the admin file and 2109 removes the pending file, as for
  31. This is the loss itself, now asserted on the Windows job.
- 35: the function does not exist, and that error does not contain M4; a reader that asked the
  platform first would answer M1 on the Linux job.

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
22-23: a copied protected file opens nowhere else, so the copy to keep is the recovery copy),
`Set-OpenWebUIPassword.ps1` (two sentences, below), `tests/Invoke-WindowsUnitTests.ps1`,
`tests/Invoke-StaticChecks.ps1` (the static rule of the Tests paragraph with its canaries; the
file lists in it stay with the integrator). For the integrator: the installer copy list, the
uninstaller, the static-check file lists, README.md (lines 38 and 51 send the owner to the admin
file as well; it also has to say what the recovery copy is and where it must not be kept),
tests/README.md, any new skip message (Skips), the backlog row.

The command:
- With no switch it lists each file as plain, protected and opens, or protected and cannot be
  opened. It also names, without printing them, the plain copies of the admin password it finds:
  a leftover pending file and a non-empty `WEBUI_ADMIN_PASSWORD` in `.env`. For the admin file it
  also shows `rotated` when the file has one: the time the password script last changed the
  password. That field is readable in either form, so nothing is opened to show it, and the date
  of a recovery copy can be held against it (Recovery). A file the installer wrote has no such
  field (`Save-AdminCredential` writes e-mail, password and address only).
- One switch protects the admin file, and only after the owner has typed the admin password and
  it equals the one in the file. Otherwise it changes nothing and names
  `Set-OpenWebUIPassword.ps1 -PromptCurrent -Prompt`. This is the same gate as for deep research:
  the password must exist outside the file before the file stops showing it. The prompt asks for
  the password as it stands on the recovery copy (below). For each file it protected, the switch
  ends with one more line: copies of that file made before today still hold this password in
  plain ("Does not add"). For the admin file that line names `Set-OpenWebUIPassword.ps1 -Prompt`
  and, after it, a new recovery copy. For deep research it says that the toolkit cannot change
  that password.
- One switch shows the password of a protected file on the screen and writes nothing, so nobody
  turns protection off just to read a password.
- One turns every file back to plain.
- Deep research is protected only after the owner pastes its password back from where it is
  saved and it matches. After a loss the same paste writes that file back plain, with nothing
  running and nothing to compare it with: the next sign-in (the installer or `Test-LocalAI.ps1`)
  is the check.
- `-RecoveryCopy <folder>` writes the recovery copy (below) and changes nothing.
- It never touches the pending file, the key file or `.env`.
- A typed password can also come as a parameter, for automation only, as in
  Set-OpenWebUIPassword.ps1:23-29: that is how the tests supply it.

`Set-OpenWebUIPassword.ps1` in step 3: two sentences, nothing else.
- The catch after the save (line 84 at 1e9e510) ends with "The new password is in <the pending
  file>; copy it over." Copying the plain pending file over a protected admin file turns that
  file plain, without the gate and without a word (IMPROVEMENTS.md row 121 (5)). No protected
  file can exist before step 3, so the sentence does no harm until then; that is why it changes
  here and not in step 1. The new sentence: copy nothing; the new password is in the pending file
  and is printed below; the next run of this script, or of `Test-LocalAI.ps1`, moves it into the
  admin file in the form that file has (`Resolve-LaiPendingPassword`, call site 1 of step 1).
- After a change that went through, one more line says that a recovery copy made before now
  holds the old password (below, "How it goes out of date").

#### The recovery copy
The owner's decision of 2026-10-07 (IMPROVEMENTS.md rows 109 and 121): he wants a copy of the
stored passwords to keep offline. It is designed here so that step 3 can be cut from this plan
alone. None of it is built and none of it was run. Each point carries its reason.

What it is for. Two days: the day Windows can no longer open a protected file (Recovery), and
the day the Secrets folder is gone together with its disk. The second can come whether or not
protection is ever switched on (question 1). So the copy has a switch of its own and is made
from plain files as well as from protected ones.

What it holds:
- Open WebUI: the address (`url`), the admin e-mail and the admin password. The password is what
  `-PromptCurrent` asks for in both Recovery paths, the e-mail is the sign-in name that goes
  with it, and the address says where the two are typed.
- Deep research: the address, the user name and the password. Without that password the saved
  research and every `deep-research-*.tar.gz` backup cannot be opened by anyone ("Per file"),
  and nothing makes it again. The three are all the fields deep-research.json has
  (`Invoke-DeepResearchSetup`), so the copy alone is enough to write that file again by hand if
  the Secrets folder is lost. The command does not do that: it pastes a password into a file
  that is there.
- Not the signing key (question 7). It is never protected, so none of the losses under Recovery
  takes it away. When its file is missing the installer makes a new one, and by the installer's
  own comment the price is that existing sessions end ("reuse the guide's key file if present so
  existing sessions stay valid", above its `New-LaiSecret` call at 1e9e510). And on the copy it
  would be the one line that cannot be made worthless once a copy is lost: no command of the
  toolkit changes the key. What else Open WebUI does with that key was not read for this plan;
  should it encrypt stored data with it, this answer has to be looked at again.
- Not the Windows sign-in password (the toolkit never has it), nothing from `.env`, no chat and
  no research. It is a copy of passwords, not a backup.
- Not the name of the PC or of the Windows account. The owner knows which PC it is, and a finder
  is not told where to go.
- A part that cannot be filled says so in the copy: deep research is not installed (there is no
  such file), or this account cannot open the password (below). No gap is left unexplained,
  because on the day the copy is read nobody remembers why a line is missing.

Its form:
- One plain text file, `LocalAI-recovery-<yyyy-MM-dd>.txt`, UTF-8, lines ending in CR LF. Not
  encrypted, not an archive, no code to scan: it has to be readable years from now on any device
  and from paper, without the toolkit and without one more password. An encrypted copy only
  moves the question to where its password is kept. To print it or to put it on a USB stick is
  all it is for. (That Notepad shows and prints such a file line by line is documented
  behaviour, not tested.)
- Dated: the day in the name, the day and the time in its first lines. Two copies can then be
  told apart, and a copy can be held against a password change ("How it goes out of date"). For
  the same reason it repeats `rotated` when the admin file has one.
- Every line explained, in the copy itself and in plain words: what each value is, where it is
  typed, what the copy does not hold, and the two commands that use it. It is read on a bad day,
  perhaps years later and perhaps by somebody else, with no documentation at hand.
- Each password alone on its line, from the first column, with its length on the line above. A
  paste then carries nothing but the password, and a character lost while typing from paper
  shows.
- No private permissions are set on it. `Protect-Path` would name this account of this Windows,
  which is in the way on the day the copy is needed: another account, or another Windows. (How
  file permissions behave on another Windows is documented behaviour, not tested.) The copy is
  protected by where it is kept and by nothing else, and its first lines say so.

A sketch of the copy. The wording is step 3's; the parts and their order are not:

```text
Local AI: recovery copy of the stored passwords
Made 2026-10-08 14:05 on the PC that runs Local AI.
Keep it offline: on paper, or on a stick that is not left plugged in. Not in a synced folder
and not next to the backups. Nothing protects this text: whoever reads it can sign in to both
programs below.
A password changed after the time above is NOT on this copy. Make a new copy, destroy this one.

OPEN WEBUI (the chat pages)
Address, opened in a browser on that PC:
http://localhost:3000
E-mail the administrator signs in with:
admin@localhost
Password, 31 characters, capital and small letters differ. The next line is the password:
<the password>
Last changed with Set-OpenWebUIPassword.ps1: 2026-10-07T12:00:00

DEEP RESEARCH
Address:
http://localhost:5055
User name:
localai
Password, 31 characters. It also unlocks the saved research and every deep-research-*.tar.gz
backup. Nothing else does, and the toolkit cannot change it. The next line is the password:
<the password>

NOT ON THIS COPY
Your Windows sign-in password. Your chats: they are in the Backups folder, which is not
encrypted and which this copy neither replaces nor protects. The key file openwebui-secret.txt.

TO USE IT (after a Windows password reset, a Windows reinstall, or on a new PC)
Set-OpenWebUIPassword.ps1 -PromptCurrent -Prompt asks for the Open WebUI password above.
Protect-LocalAISecrets.ps1 asks for the deep research password above (its paste switch).
Test-LocalAI.ps1 then checks that both sign in.
```

The switch: `-RecoveryCopy <folder>` (working name), given alone. With any other switch the
command stops with its usage line.
- It reads the two files through `Read-LaiSecretFile`, which opens a protected one (what DPAPI
  does there is documented behaviour, not tested, as everywhere in this plan), writes the one
  file into the folder and prints where the file is. It changes nothing under `<AIRoot>`: no
  file, no form, and no record that a copy was made. It needs nothing running. Why nothing
  changes: making a copy has to be safe to repeat, on a bad day too.
- It never prints a password. What is printed can stay in the window's scroll-back and in a
  transcript of that session, on this PC (documented behaviour, not tested). The show action is
  the one that prints, on purpose.
- The folder has to exist; the command never makes one. A stick that is not plugged in, or a
  mistyped path, must end in a refusal and not in a new folder on this PC's disk.
- No default folder. Every default would be a place on this PC, and Desktop and Documents can
  lie inside the OneDrive folder (its folder backup: documented behaviour, not tested). Where
  plain passwords go is named by the owner, each time.
- It never replaces a file. When a copy of the same day is already in the folder it stops and
  says so. Why: a run on a day when one file cannot be opened must not wipe out an older copy
  that is complete.
- With a leftover pending file it stops and names `Test-LocalAI.ps1`, whose admin sign-in check
  settles the change (`Resolve-LaiPendingPassword`). Why: until then the admin file may hold a
  password that is no longer the one in use, and the copy would carry it.
- A file this account cannot open is left out. The command warns and names the file, and the
  copy says in that place, in capitals, that this password is not on it and why (the reader's
  message). The rest is written. When no password at all can be read, nothing is written: a copy
  without a password is paper that only looks like safety.
- It does not sign in anywhere. The copy holds what the files hold; `Test-LocalAI.ps1` is the
  check that those are the passwords in use, and the command's closing lines say so.

Where it may not be written. The folder is made a full path, `/` becomes `\`, a trailing `\` is
dropped, and the result is compared as text, by whole folder names, capitals ignored: is it this
place, or does it lie below it? That is how `Get-PcsSyncVerdict` (Test-PCSecurity.ps1) compares,
and it runs the same on both jobs. The judge is one function in the command's script that reads
nothing itself: the folder, `<AIRoot>`, the mirror and the sync folders come in as parameters,
and the reason for a refusal, or nothing, comes out. Refused, with a message that names the
reason and with nothing written:
- `<AIRoot>` and everything below it: the install folder, Secrets and Backups in one rule. Why:
  a copy there is lost together with what it is for, it lies next to the chats, and it travels
  with every copy of `<AIRoot>`, the very copy protection is meant to make useless.
- The folder that `BackupMirror` in localai-config.json names, when one is set, and everything
  below it (`Backup-OpenWebUI.ps1` reads the same key). Why: the archives go there. With the
  copy beside them one find gives the chats and both logins, and a mirror is by its purpose a
  place that other copies are made of.
- The OneDrive folders of this account and everything below them: the folders in the environment
  variables `OneDrive`, `OneDriveConsumer` and `OneDriveCommercial`, the same three that
  `Get-PcsSyncClient` (Test-PCSecurity.ps1) reads. That function lives in a script and not in
  the module, so the command reads the three itself, and its comment names `Get-PcsSyncClient`
  so that a change there is made here too. Refused as well, as `Get-PcsSyncVerdict` treats it: a
  folder named `OneDrive` or `OneDrive - <organisation>` directly under a user profile
  (`<drive>:\Users\<name>\`), because in a window opened with another account's administrator
  password the variables are that administrator's. Why: a synced folder uploads the plain
  passwords, and offline is what was asked for. (That OneDrive keeps its folders in these
  variables, and whose they are in such a window, is what the comments in Test-PCSecurity.ps1
  say: documented behaviour, not tested.)

Not recognised, so the command's help, its closing lines and the first lines of the copy say it
and the owner checks it himself: any other sync program (Dropbox, Google Drive, iCloud Drive and
the like), a network share or a mapped drive, a folder that some backup program copies, and a
link that leads into a refused place (the comparison is text). The command also does not go by
whether the drive calls itself removable: that does not settle it (some USB drives report as
fixed disks: documented behaviour, not tested). When the folder is on the drive of `<AIRoot>` or
of Windows, the closing lines add: this is a disk of this PC; move the file to a stick or print
it, then delete it here, and know that a deleted file can be read from a disk until it is
overwritten (documented behaviour of file systems, not tested).

Confirmed, and only then protected. A file is protected only after the owner confirmed the copy
for that file, and "confirmed" means one thing: at the prompt of the protect switch he typed or
pasted that file's password, and it equals the stored one. The prompt says to read it from the
recovery copy and not from the file. It is the gate the command has anyway (above), now with a
place to read from.
- Per file. A match protects that file; no match leaves it plain and says which. One file can be
  protected without the other. Why: the two passwords guard different things, and a typing slip
  in one must not undo the other.
- What it does not show: that the copy left this PC, or that the text came from the copy and not
  from the plain file open in another window. The command can see neither. Reading it from the
  copy is the owner's part, and the prompt and the README say so in those words.
- No record is kept: no flag, no date, no file that says a copy was made or confirmed. Why: a
  record says that a copy existed once, not that it still exists, can be read or is in date, and
  a later protect that trusted it would skip the one check there is. So every protect asks
  again, and the only trace is the file itself: it is protected because the typed text matched.

How it goes out of date. Only a password change does it, and the change says so.
- After every change that went through, `Set-OpenWebUIPassword.ps1` says that a recovery copy
  made before now holds the old password, and names `Protect-LocalAISecrets.ps1 -RecoveryCopy
  <folder>` and destroying the old copy. Over a protected file the sentence is firm (a copy was
  confirmed for it); over a plain file it begins "If you keep a recovery copy". Why both: no
  record of copies is kept, and a copy can exist beside a plain file.
- A protected file stays protected through a change (form Keep, step 1), although the copy that
  was confirmed for it is now out of date (question 8). Why: otherwise the everyday act of
  changing a password would switch protection off. The price is a window, from the change to the
  new copy, in which the new password exists outside the file only if the owner typed it himself
  (`-Prompt`) or saved the one that was shown once. In that window the show action and a new
  `-RecoveryCopy` still open the file, for as long as this Windows account can (Recovery says
  when it no longer can: documented behaviour, not tested).
- The deep research password has no such moment: the toolkit cannot change it ("Does not add").
  Its line on the copy goes out of date only when that account is made anew ("start over"), or
  when the password is changed in Local Deep Research itself, should that program be able to.
- Not closed by this plan: a password changed on Open WebUI's own settings page says nothing,
  because the toolkit is not there. File and copy are then both out of date, and the installer
  asks for the current login at its next run.

What a finder of the copy gets: both logins in plain text, with the names and the addresses
that go with them.
- That alone is not a way in. Both programs answer on this PC only (stack/docker-compose.yml
  binds every published port to 127.0.0.1), unless phone access was set up with
  Enable-TailscaleAccess.ps1; what that opens was not read for this plan. So the finder also has
  to sit at this PC in a signed-in session, run a program on it, or be on that private network.
- With that: the sign-in of the Open WebUI administrator. What an administrator can see there
  was not read for this plan; assume every user's chats and every setting. And the deep research
  sign-in, with the means to open the saved research and every `deep-research-*.tar.gz` he gets
  hold of.
- Not: the Windows sign-in, the signing key, or anything on a PC he cannot reach.
- When a copy is lost: change the admin password (`Set-OpenWebUIPassword.ps1 -Prompt`) and make
  a new copy; the lost one is then worth nothing for Open WebUI. For deep research the lost copy
  stays good: the toolkit cannot change that password, and the only end this plan knows is to
  start over, which deletes the saved research.

What the copy does not cover: the chats in Backups. It holds no chat and no research, so it
brings nothing back when the archives are lost. And it adds nothing to their safety: the
`open-webui-*.tar.gz` archives are not encrypted by the toolkit ("Does not add"), so whoever
holds one reads the chats without the copy. Keeping the copy well does not make Backups
or the mirror safe. The deep research archives are the other way round: encrypted with the
password on the copy, they open with it and not without it. The copy does not cover the models,
the settings, `.env` or the signing key either.

The order that needs one copy only: change the admin password (`Set-OpenWebUIPassword.ps1
-Prompt`), make the copy, protect. Every earlier copy of the admin file then holds a password
that no longer works. The protect switch prints its closing line all the same: it cannot know
how old the password is (`rotated` is missing in a file the installer wrote).

Tests: [W] plain to protected to plain gives the same fields back; the listing names each of the
three states (changed blob for the third); deep research is refused without a matching paste and
left plain; the admin file is refused after a wrong typed password and left plain; the show action
prints the password of a protected file and changes no file; the listing names a leftover pending
file and a non-empty `WEBUI_ADMIN_PASSWORD` and prints neither value; back-to-plain on a file that
cannot be opened changes nothing and says so. Both jobs:
an installer run leaves a plain file plain. A static rule with canaries: no `Set-Content` to
openwebui-admin.json or deep-research.json outside `Save-LaiSecretFile`.

Tests for the recovery copy and the two messages. None can pass before step 3: the command, its
switch and both sentences do not exist. Both jobs, with plain files:
- the copy holds the address, e-mail and password of the admin file and the address, user name
  and password of the deep research file, and its name and its first lines carry the day;
- the key in openwebui-secret.txt appears nowhere in the copy;
- every file under `<AIRoot>` has the same bytes after the run and none was added;
- what the command prints holds neither password;
- each refused folder ends with an exit code that is not 0, a message that names the reason and
  no `LocalAI-recovery-*` file in it: `<AIRoot>` itself, Secrets, Backups, the folder
  `BackupMirror` names and a folder below that one; a folder that does not exist is refused and
  is not made;
- the judge on made-up paths, no file touched: a OneDrive folder and a folder below it are
  refused; a folder beside it whose name only starts the same (`OneDriveArchive`) is not;
  `OneDrive - <organisation>` under another profile is;
- a second copy on the same day says so and leaves the first byte for byte;
- a leftover pending file refuses the copy and the message names `Test-LocalAI.ps1`;
- without deep-research.json the copy says deep research is not installed and still holds the
  admin values;
- a password change over a plain file names `-RecoveryCopy` (the harness of test 24).

[W]:
- the copy made from protected files holds the same four values as the one made from plain ones;
- with a changed blob in the admin file the command names that file, the copy says in that place
  that the password is not on it, and the deep research values are there;
- with a changed blob in both files nothing is written;
- a password change over a protected file names `-RecoveryCopy` and leaves the file protected
  (the harness of tests 25 to 28);
- what the protect switch prints names `Set-OpenWebUIPassword.ps1 -Prompt` for the admin file,
  and for deep research says that the toolkit cannot change that password;
- a save that fails after the change went through names the pending file and no longer says
  "copy it over"; the pending file still holds the new password and the admin file is byte for
  byte what it was. The test makes the save fail by setting the admin file read-only; that
  `Set-Content` then fails under Windows PowerShell 5.1 is documented behaviour, not tested.

Not tested: the command's own reading of the three OneDrive variables (the Windows job may have
none of them set; the judge behind it is tested on made-up paths), and everything the owner does
with the copy afterwards. Say both in tests/README.md. The judge is taken out of the command's
script by its name, the way the suite already takes single functions out of the installer (the
`ParseFile` and `FunctionDefinitionAst` lines of tests/Invoke-WindowsUnitTests.ps1 at 1e9e510).
Static rule DOCPARAM reads every script message: a message that names the switch gives it its
value (`-RecoveryCopy <folder>`), and the command must have the switch under that name.
