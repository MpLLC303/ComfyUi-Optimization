# Phone access over Tailscale: who may connect, key expiry, Tailnet Lock

`Enable-TailscaleAccess.ps1` publishes Open WebUI to your tailnet with `tailscale serve` and adds the
phone's address to Open WebUI's allowed origins. Three things are missing today:

- Nothing limits which device of the tailnet may open it. Open WebUI's own login is the only gate.
- Nothing notices when this PC's Tailscale key expires (180 days by default, audit R7). Phone access
  then stops, and neither the PC nor the phone says why.
- Nothing checks that Funnel, which publishes to the whole internet, is off. The script's help
  (l.11) and its success line (l.143) say "not public" without looking.

Part 1 is what the owner can do about this today, by hand. Part 2 is what a builder adds to the
scripts. This document changes no code.

## Status: what was checked, and against what

No web access was available while this was written (the build rules forbid it), and no Tailscale
command was run. So:

- **Nothing in Part 1 could be checked against Tailscale's current documentation.** Every page
  name, button label, policy keyword and Tailnet Lock behaviour below is from memory.
- Every JSON field that Part 2 reads for the first time is from memory.
- What `Enable-TailscaleAccess.ps1` already calls is "used by this repository's tests". That means
  exercised against a fake `tailscale` (a shim). It shows the script handles that shape, not that a
  real client produces it.
- Statements about this repository's code were read at commit ea191d1; line numbers are from it.

If a page or button is not where a step says, stop at that step. Nothing in Part 1 is urgent, and
each procedure ends with its Undo. The one exception is step 1.7 (tagging the PC, variant B): the
PC stays open until it is done, so that step says what to do when it cannot be done.

| Item | Rests on | Status |
|---|---|---|
| 1.1 Save the current policy text | "Access controls" page, "JSON editor" tab; the editor holds the whole policy | from memory, not verified |
| 1.2 Read what you saved | the starting policy is one allow-everything rule (`acls` or `grants`) and perhaps `ssh`; replacing it ends exit-node use, subnet routes and shared devices | from memory, not verified |
| 1.2 The extra rule for exit-node use | `autogroup:internet:*` as a destination | from memory, not verified |
| 1.3 Read the two addresses | "Machines" page, "Addresses" column | from memory, not verified |
| 1.4 Choose variant A or B | what `autogroup:self` covers; tagged devices are not "yours" | from memory, not verified |
| 1.5 Paste the policy | policy syntax: `hosts`, `tagOwners`, `acls`, `tests` | from memory, not verified |
| 1.6 Save | the console runs `tests` and refuses a failing policy | from memory, not verified |
| 1.7 Tag the PC (variant B) | "Edit ACL tags..." in the device menu; side effects of a tag; an untagged PC stays reachable through `autogroup:self`, and `tests` cannot see that | from memory, not verified |
| 1.8 Test from the phone | policy takes effect within about a minute | from memory, not verified |
| 1.9 Negative test from another device | a refused connection times out | from memory, not verified |
| Undo 1 | pasting the old text restores the old rules; untagging asks for sign-in | from memory, not verified |
| 2.1 Find the PC's expiry | "Machines" page shows an expiry date per device | from memory, not verified |
| 2.2 Switch it off | "Disable key expiry" in the device menu | from memory, not verified |
| 2.3 Check the row | "Expiry disabled" label | from memory, not verified |
| 2.4 Leave the phone's expiry on | the phone app asks for sign-in when its key expires; with Tailnet Lock on, a device that signed in again may need a new signature (a recent client may carry its signature over) | from memory, not verified |
| Undo 2 | "Enable key expiry"; an old key may expire at once | from memory, not verified |
| 3.1 Order: procedures 1 and 2 first, then clear out the Machines list | a new key needs a new signature; the enabling command signs every device present at that moment | from memory, not verified |
| 3.2 Update Tailscale | Tailnet Lock needs a recent client | from memory, not verified |
| 3.3 Prepare where the secrets go | secrets are shown once, by the enabling command | from memory, not verified |
| 3.4 Read the PC's lock key | `tailscale lock status` prints a `tlpub:` key | from memory, not verified |
| 3.5 Console dialog | Settings > Device management > Tailnet lock; support secret option | from memory, not verified |
| 3.6 Enable and store the secrets | `tailscale lock init`, `--confirm`, `disablement-secret:` lines | from memory, not verified |
| 3.7 Check the state | `tailscale lock status`; "Locked out" label | from memory, not verified |
| 3.8 Phone test | existing devices are signed by the enabling command | from memory, not verified |
| 3.9 New devices from now on | every new device waits for a signature; `tailscale lock sign`; a locked-out computer's own `tailscale lock status` prints its `nodekey:` | from memory, not verified |
| 3.9 Where the phone app shows its node key | a Tailnet lock entry in the app's settings | open question, not verified |
| Phone as a signer | whether the phone app can sign at all | open question, not verified |
| Undo 3 | `tailscale lock disable <secret>` | from memory, not verified |
| JSON: `Self.KeyExpiry` in `tailscale status --json` | absent when expiry is off | from memory, not verified |
| JSON: `AllowFunnel` in `tailscale serve status --json` | map of `<host>:<port>` to `true` | from memory, not verified |
| JSON: `Foreground.<id>.AllowFunnel` in the same output | foreground sessions keep their own copy | from memory, not verified |
| JSON: `Foreground.<id>.Web` and `TCP.<port>.TCPForward` in the same output | a foreground session's own sites; a raw TCP forward, written `<host>:<port>` | from memory, not verified |
| Command `tailscale lock status --json` | the `--json` switch exists | from memory, not verified |
| JSON: `Enabled`, `NodeKeySigned` in that output | booleans | from memory, not verified |
| Commands named in messages: `tailscale funnel reset`, `tailscale lock sign` | spelling and effect; whether `funnel reset` also removes `serve` mappings | from memory, not verified |
| `tailscale serve --https=443 off` on a signed-out client | whether it still edits the stored mappings | open question, not verified |
| Windows: the Tailscale network adapter | its `InterfaceDescription` starts with `Tailscale` | from memory, not verified |
| `tailscale status --json`: `BackendState`, `Self.DNSName`, `Self.CapMap` | Enable l.81-87, l.114-115; shim l.418-424 | used by this repository's tests |
| `tailscale status --json`: `CertDomains` | Enable l.117; no test supplies it | read by the script only |
| `tailscale serve --bg <port>` | Enable l.128; shim l.425 | used by this repository's tests |
| `tailscale serve status --json`: `Web.<site>.Handlers.<path>.Proxy` | Enable l.132-139; shim l.426-429 | used by this repository's tests |
| `tailscale serve --https=443 off` | Enable l.105; shim l.430 | used by this repository's tests |

---

## Part 1. For the owner

You need: this PC with phone access already working (`Enable-TailscaleAccess.ps1` has run and the
phone opens `https://<this-pc>.<tailnet>.ts.net/`), and the sign-in for the account that owns the
tailnet. The admin console is at `https://login.tailscale.com/admin`.

Do the procedures in this order. Procedures 1 and 2 are worth doing today. Procedure 3 is optional
and is the only one that can lock you out.

### Procedure 1. Access policy: only the phone reaches this PC, only on port 443

What changes: a tailnet starts with a policy that lets every device reach every other device on
every port. Afterwards the only connection allowed to this PC is phone to PC, port 443 (the HTTPS
address the script publishes). The PC can no longer start connections to other devices.

- **1.1** Save the current policy text first. In a browser on the PC open the admin console and
  choose the **Access controls** page; if it opens in a visual editor, switch to the **JSON editor**
  tab. Click into the text, Ctrl+A, Ctrl+C, paste into Notepad and save it as
  `tailscale-policy-before.txt` where you will find it again. This file is the Undo. Do not go on
  without it: replacing the allow-everything rule cuts every other pair of devices in the tailnet.
- **1.2** Read what you saved before you replace it. Skip the lines that start with `//`.
  - A tailnet's starting policy holds one rule that accepts everything from everywhere, written
    either as `acls` (`"src": ["*"]`, `"dst": ["*:*"]`) or as `grants` (`"src": ["*"]`,
    `"dst": ["*"]`), and perhaps an `ssh` section. This procedure is written for that policy.
  - If yours holds anything more (further rules, or sections named `groups`, `hosts`, `tagOwners`,
    `nodeAttrs` or `autoApprovers`), stop here and keep it. Somebody shaped it on purpose, and
    step 1.5 deletes all of it. What this procedure is for then has to be built into your own
    policy: nothing but the phone reaches this PC, and only on port 443.
  - Even the starting policy allows things the two variants do not. From step 1.6 on these stop,
    for every device of the tailnet: using an exit node (the phone or a laptop sends its internet
    traffic through this PC or another device), reaching a home network through a subnet router,
    devices another person shared with you or you with them, and Tailscale SSH (see 1.4).
  - You use an exit node: add the extra rule shown below the variants. You use a subnet router or
    shared devices: stop here, this guide has no text for them.
  - Why this cannot wait: the test in 1.8 passes either way. A lost exit node shows only later, as
    a phone without internet whenever the exit node is selected.
- **1.3** Open the **Machines** page. From the **Addresses** column note this PC's address
  (`<pc-ip>`) and the phone's (`<phone-ip>`). Both begin with `100.`.
- **1.4** Choose a variant.
  - **A** when the tailnet holds only this PC and the phone, or no other two devices need each other.
  - **B** when you have other devices that must keep reaching each other.
  - Why not A plus a rule "my devices may reach my devices": that rule (`autogroup:self`) counts
    this PC as one of your devices and re-opens it to all of them on every port. Variant B gives the
    PC a tag; a tagged device no longer counts as yours.
  - If your saved policy has an `ssh` section and you use Tailscale SSH between other devices, copy
    that section into the new text unchanged.
- **1.5** Back on **Access controls**, replace the whole text with the variant's text below and put
  your addresses in place of the placeholders (keep the quotes).
- **1.6** Click **Save**. The console first runs the `tests` block and refuses to save when a line
  of it fails; a refusal means nothing was changed. Do not delete the tests to get past it. If it
  reports a syntax error it names the line: check for a placeholder you did not replace. If the text
  is refused for a reason you cannot fix, paste the saved text back and stop.
- **1.7** Variant B only: **Machines** > this PC's row > `...` menu > **Edit ACL tags...** > add
  `tag:ai-pc` > **Save**, then check that the row shows the tag. Until it does, variant B protects
  nothing: its first rule lets every one of your devices reach this PC on every port, the phone
  among them (so nothing is cut in between). The `tests` block cannot tell you; it passes with no
  device tagged. So do not stop at this step. If you cannot find the menu entry, or the tag is
  refused, either run Undo 1 or go back to 1.5 with variant A. A tagged PC usually has key expiry
  off already; check it in procedure 2.
- **1.8** Test from the phone: the Tailscale app shows it is connected; in the phone's browser open
  `https://<this-pc>.<tailnet>.ts.net/`. Open WebUI's sign-in page must appear. Allow a minute.
- **1.9** Negative test: on any other device signed in to the tailnet (a laptop, a tablet) open the
  same address. It must not load; the browser waits and gives up.
  - Variant B: this step is not optional (B is for a tailnet that has such a device). If the page
    loads, the tag is missing: go back to 1.7.
  - Variant A: if the page loads, the policy is not in effect: go back to 1.5. With no other
    device, the `deny` line in `tests` is the only negative test you have; repeat this step when
    you add one.

Variant A (replace `<pc-ip>` and `<phone-ip>`):

```json
{
  "hosts": {
    "ai-pc": "<pc-ip>",
    "phone": "<phone-ip>"
  },
  "acls": [
    { "action": "accept", "src": ["phone"], "dst": ["ai-pc:443"] }
  ],
  "tests": [
    {
      "src": "phone",
      "accept": ["ai-pc:443"],
      "deny": ["ai-pc:11434", "ai-pc:3000"]
    }
  ]
}
```

Variant B (replace `<phone-ip>`):

```json
{
  "tagOwners": {
    "tag:ai-pc": ["autogroup:admin"]
  },
  "hosts": {
    "phone": "<phone-ip>"
  },
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self:*"] },
    { "action": "accept", "src": ["phone"], "dst": ["tag:ai-pc:443"] }
  ],
  "tests": [
    {
      "src": "phone",
      "accept": ["tag:ai-pc:443"],
      "deny": ["tag:ai-pc:11434", "tag:ai-pc:3000"]
    }
  ]
}
```

Ports 11434 and 3000 in the `deny` lines are Ollama and Open WebUI's own port: neither may ever be
reachable from the tailnet directly.

Exit node (only if step 1.2 sent you here; not verified): add this line to the `acls` list of your
variant, below the last rule, and put a comma at the end of the line above it. After 1.8, select
the exit node on the phone and open any website.

```json
{ "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:internet:*"] }
```

Later: a phone that is removed from the tailnet and added again gets a new address. The policy then
no longer matches it and phone access stops. Put the new address in `hosts` and save.

**Undo 1.** **Access controls** > **JSON editor** > select everything > paste the text from
`tailscale-policy-before.txt` > **Save**. Variant B also: **Machines** > this PC > `...` >
**Edit ACL tags...** > remove `tag:ai-pc`. Taking the last tag off a device makes it ask for
sign-in again: sign in on the PC, run `Enable-TailscaleAccess.ps1` again, repeat 1.8.

### Procedure 2. Switch key expiry off for this PC

- **2.1** Admin console > **Machines**. In this PC's row find its expiry ("Expires" with a date).
- **2.2** The row's `...` menu > **Disable key expiry**.
- **2.3** The row now reads **Expiry disabled**. Nothing to do on the PC or the phone; no restart.
- **2.4** Leave the phone's expiry on, unless you turn on Tailnet Lock. When the phone's key runs
  out, the app asks you to sign in and you see it. The PC is the one that fails with nobody
  looking. With Tailnet Lock (procedure 3) a phone that signs in again may have to be signed from
  the PC before it connects: read "What you can lose" there before you decide.

What you give up: expiry is what drops a stolen or copied PC out of the tailnet by itself. With it
off, that is your job: **Machines** > the PC > `...` > **Remove**.

**Undo 2.** Same menu > **Enable key expiry**. A key older than the limit may expire at once: the
PC then asks for sign-in and phone access stops until you have signed in.

### Procedure 3. Tailnet Lock (optional)

**What it protects against.** Without it, this PC accepts every device that Tailscale's servers
present as a member of your tailnet. Whoever can add a device there gets one the PC will talk to:
someone who gets into the account you sign in to Tailscale with, or Tailscale's servers if they were
ever compromised. That same account edits the policy of procedure 1, so the policy does not stop
them. With Tailnet Lock on, your devices accept another device only when its key was signed by one
of your signing devices, and the signing keys never leave those devices. An intruder in the account
can still add a device and rewrite the policy, but the device stays locked out until it is signed
from this PC.

**What it does not protect against.** Someone who controls a signing device (this PC). A leaked
Open WebUI password used from a device that is already in. Funnel.

**What you can lose.**

- Every new device (a new phone, a reset phone, a reinstalled Windows) must be signed from a signing
  device before it can connect. If this PC is the only device that can sign and its disk fails,
  nothing can be signed any more.
- The same may hold for a device you already have. When its key expires and you sign in again, it
  comes back with a new key (the rule in 3.1) and may stay **Locked out** until it is signed from
  this PC as in 3.9. Not verified: a recent client may carry its signature over. For the phone,
  whose expiry procedure 2 leaves on, that means: the key runs out while you are away, you sign
  in, and the phone cannot reach the PC until you are home. Two ways round it: switch key expiry
  off for the phone too (procedure 2 on the phone's row, at the same price: a lost phone must be
  removed by hand), or note the phone's expiry date from the **Machines** page and, before it and
  at home, sign out and in again in the phone's app and sign it from the PC if it is locked out.
- The way out is a disablement secret, which switches the lock off for the whole tailnet. Without
  one, what is left is Tailscale's support (only if you let the setup hand them a secret, see 3.5)
  or deleting the tailnet and starting a new one.
- A new tailnet costs an evening, not data. Chats, models and settings are on the PC's disk and are
  not touched. Lost are the device list, the policy of procedure 1 and the PC's `.ts.net` name, so
  `Enable-TailscaleAccess.ps1` must run again and the phone's home-screen shortcut is replaced.

**Keeping the disablement secrets.**

- They are shown once, by the command that switches the lock on (3.6), and never again.
- Keep every secret in two places that depend neither on this PC nor on the tailnet: for example a
  password manager you can open from the phone without the PC, and a printed sheet with your papers.
- Not under the install folder, not in a chat with the local AI, not in a note that lives only on
  this PC: the PC is the thing whose loss they are for.
- Anyone holding one secret can switch the lock off for everyone. That lets nobody in by itself
  (they still need a device in your tailnet), but it removes the protection. Treat it as a password.

Steps:

- **3.1** Finish procedures 1 and 2 and check that phone access works. A device that signs in again
  with a new key needs a new signature; with expiry off the PC never does that by surprise. Then
  open **Machines** and remove (`...` > **Remove**) every device you do not recognise or no longer
  use. The command in 3.6 signs every device that is in the tailnet at that moment, a forgotten
  laptop or an intruder's device included, and they stay trusted afterwards.
- **3.2** Update Tailscale on the PC and on the phone.
- **3.3** Store first: set up where the secrets go, before anything is switched on. Password-manager
  entry open and ready to paste into; printer on, or pen and paper on the desk.
- **3.4** On the PC open PowerShell and run `tailscale lock status`. It says that Tailnet Lock is not
  enabled and prints this PC's lock key, which starts with `tlpub:`.
- **3.5** Admin console > **Settings** > **Device management** > **Tailnet lock** >
  **Enable tailnet lock**. Choose this PC as a signing node and, if it is offered, the phone (see the
  open question below). The dialog asks whether one disablement secret goes to Tailscale's support.
  Saying yes means support can switch the lock off for you after a total loss; it also means the
  lock no longer protects against Tailscale itself. For a home tailnet, where locking yourself out
  is the likelier accident, yes is reasonable; it is your decision. The dialog ends with a command
  that starts with `tailscale lock init`. Copy it. Nothing is enabled yet.
- **3.6** Look at the **Machines** list (3.1) and at 3.3 once more, then run that command in PowerShell on the PC. This is the step
  that switches the lock on, and the same output prints the secrets as lines starting with
  `disablement-secret:`. Put every one of them into both places before you do anything else, and
  read each stored copy back against the screen before you close the window. (The command takes
  effect only when it contains `--confirm`; without that word it prints what it would do and stops.
  If yours asks a question before enabling, answer after the secrets are stored.)
- **3.7** Run `tailscale lock status` again: it reports the lock as enabled and this PC's key as
  signed. On the **Machines** page no device is marked **Locked out**.
- **3.8** Open the address on the phone. Devices that were already in the tailnet are signed by the
  enabling command, so it should load. If the phone is marked **Locked out**, sign it as in 3.9.
- **3.9** From now on every new device stays **Locked out** until it is signed from this PC. Its
  row in the admin console shows a command that starts with `tailscale lock sign`. The console is
  exactly what Tailnet Lock is there not to trust, so never run that command just because a row
  shows it:
  - Sign only a device you added yourself, minutes ago. A **Locked out** row you did not expect is
    what an intrusion looks like: do not sign it. Remove the device (`...` > **Remove**) and change
    the password of the account you sign in to Tailscale with.
  - Compare the `nodekey:` value in the command with the one the new device shows itself. On a
    computer, `tailscale lock status` run on that device prints it. For the phone app I could not
    confirm where it is shown; look for a Tailnet lock entry in its settings. If you cannot
    compare, sign only when exactly one device is locked out and it appeared as you added yours.
  - Paste that one line, starting with `tailscale lock sign`, and nothing else.
  - A device you already have may come back **Locked out** after its key expired and you signed in
    again (see "What you can lose"). That is the one expected case besides a new device; the same
    checks apply.

  Write on the printed sheet which devices can sign.

**Open question: can the phone sign?** Signing is a command (`tailscale lock sign`), and I know of
no way to run it in the phone app. It may be that the phone can be listed as a signing node and
still cannot sign anything. If so, listing it adds nothing for recovery: this PC is then the only
device that can admit a new one, and after losing the PC a disablement secret is the only way to
get a device in again. Plan as if that is the case until you have signed a device from the phone
yourself. A second computer with Tailscale as a signing node would close the gap.

**Undo 3.** On the PC: `tailscale lock disable <disablement-secret>`. The lock is then off for the
whole tailnet and that secret is spent; switching it on again means this procedure again, with new
secrets. Check with `tailscale lock status`.

---

## Part 2. For a builder

Seven checks (C1 to C7) in three items (T1 to T3). The existing switches of
`Enable-TailscaleAccess.ps1` are `-AIRoot`, `-Port` and `-Disable`; no new switch is proposed.

Proposed, so none of it exists yet, wherever it is named below:

- config keys `TailscaleServe` and `OllamaBlockRule` in `localai-config.json`;
- the install-state flag `ollamaBlockRule`; the `watch-state.json` key `tailscaleExpiryNotifiedFor`;
- the watch result names `Phone access` and `Tailnet only`;
- the module functions `Get-LaiTailscaleFunnelSite`, `Get-LaiTailscaleKeyState`,
  `Get-LaiTailscaleLockState`, `Test-LaiTailscaleInUse`, `Get-LaiOllamaTailnetWarning`, with their
  parameters;
- the shim scenarios `funnel`, `funnelport`, `funnelother`, `expiring`, `lockoff`, `lockon`,
  `lockunsigned`, and the shim variable `LAI_TS_EXPIRY`.

Existing and only reused: the config key `WebUIPort`, the flag `ollamaLanFallback`, the shim
scenarios `ok`, `needslogin`, `nohttps`, `noapply`, `hang`, the variable `LOCALAI_TS_TIMEOUT`
(Enable l.45), the watch's `-NoHeal` and `-NoNotify`.

### 2.1 What the code does today (commit ea191d1)

| Fact | Where |
|---|---|
| `$status` is the parsed `tailscale status --json` | Enable l.81-83 |
| `$cfg` is the parsed `tailscale serve status --json` | Enable l.132 |
| Only `.Out` (stdout) is JSON; `.Text` also holds stderr warnings | Enable l.71-72 |
| `Invoke-Tailscale` throws when the CLI does not answer in time | Enable l.56-66 |
| `$config` exists only when `-Port` was not given | Enable l.75-79 |
| The uninstaller always passes `-Port` together with `-Disable` | Uninstall l.186-190 |
| `-Disable` ends the script with `exit 0` | Enable l.104-110 |
| `-Disable` is reached only after the CLI lookup and the `Running` check, and both `throw` | Enable l.34-39, l.84-86 |
| The origin line is written on success and removed by `-Disable`; the installer keeps `.env` keys it does not manage | Enable l.141, l.107; Install l.654-655 |
| `docs/` is classed as not installed; the installer names no docs folder | Get-LocalAI l.268-275 |
| Help and success line say "not public" unconditionally | Enable l.11, l.143 |
| `Read-LaiState`, `Save-LaiState` (hashtable in, atomic write, throws after 5 tries) | module l.228, l.248 |
| The installer merges into `localai-config.json`; keys of other scripts survive | Install l.1885-1897 |
| The watch reads the config once | Watch l.65 |
| `ConvertTo-WatchDate`: a date from JSON is a `[datetime]` under PowerShell 7, a string under 5.1 | Watch l.92-97 |
| `$results` / `$details`: one entry per check; two strikes, reminders and "back to normal" follow from them | Watch l.237-238, l.689-750 |
| `$previous` (last run's `watch-state.json`) is available from here on | Watch l.370 |
| Once-only notices: told only when `Send-Notification` returned `$true`; keys saved at the end | Watch l.411-452, l.804-815 |
| Under `-NoNotify`, `Send-Notification` writes a `NOTIFY` line and returns `$true` | Watch l.149 |
| `Get-WatchHint` | Watch l.713-730 |
| `Invoke-LaiTimedNative`: throws when the program is not on PATH; returns `ExitCode` (-1 on timeout), `TimedOut`, `Out`, `Text` | module l.116-127 |
| `Set-OllamaBlockRule -AdaptersOnly` warns once and records nothing | Install l.459-473, called l.1745 |
| The adapter-only rule is created with `-InterfaceAlias`, the address rule with `-RemoteAddress` and no interface | Install l.470, l.479 |
| The installer sets Ollama to all interfaces and the flag `ollamaLanFallback` | Install l.1725-1728 |
| The address rule is rebuilt and tried first on every installer run | Install l.1731-1734 |
| `Get-LaiOllamaServerConfig` / `Get-LaiOllamaLiveConfig` return `HostIsLoopback` | module l.1678-1701 |
| The health check calls the fallback "the LAN block rule is in place" whichever rule it is | Test-LocalAI l.654-657 |
| The shim answers unknown commands with exit code 2 and no output | unit tests l.431 |
| The shim's normal status JSON has no `KeyExpiry` | unit tests l.423 |
| The Windows job runs the static checks, `Invoke-WindowsUnitTests.ps1` and `Invoke-GetLocalAITest.ps1`; `Invoke-WatchTest.ps1` runs on Linux only | tests/README.md l.3 |

### 2.2 The checks

Remember the FORMAT rule of the static checks: a message built with `-f` or `+` goes in parentheses.
Read optional JSON properties the way Enable l.114 does (`PSObject.Properties.Name -contains`).

#### C1. Funnel is off (T1)

- Target: `Enable-TailscaleAccess.ps1`, between l.140 and l.141 (before the origin is added).
- Source: `$cfg` from l.132. No new call.
- Fields: `AllowFunnel` and `Foreground.<id>.AllowFunnel`, every key whose value is `$true`. For
  what a funnelled site reaches: `Web.<site>.Handlers.<path>.Proxy`, the same under
  `Foreground.<id>.Web`, and `TCP.<port>.TCPForward`.
- Proposed pure function in the module: `Get-LaiTailscaleFunnelSite -ServeConfig <object>
  -WebUIPort <int>`, returns one `@{ Site; ReachesWebUI }` per `<host>:<port>` key that is on (both
  places, no duplicates), `@()` for `$null` or `{}`.
- `ReachesWebUI` is `$true` when a handler of that site, in either `Web` place, has a `Proxy` to
  loopback in any spelling (`127.0.0.1`, `localhost`, `[::1]`) on the Open WebUI port, whatever the
  scheme and path, or when `TCP.<the site's port>.TCPForward` is such an address. The exact match
  of l.137 is too narrow here: it takes `http://localhost:3000` for somebody else's.
- `$false` means "not seen to reach Open WebUI", never "does not reach it": a proxy that forwards
  on, or a shape this function does not know, looks the same. No message may say more than that.
- "Ours" below is a funnelled site with `ReachesWebUI`. With any such site there is no success
  line, and the script undoes only what it made. When `<dns>:443` is among them, it removes that
  mapping with the call it already has, `Invoke-Tailscale @('serve', '--https=443', 'off')`. A
  site on another port is left alone: the script did not create it, and removing the 443 mapping
  does not end it.
- Only `<dns>:443` is ours and its removal worked, `throw`:

  ```text
  Tailscale Funnel is switched on for <sites>: Open WebUI would be reachable from the whole internet, not only from your tailnet. The mapping was removed again. Switch Funnel off on this PC (tailscale funnel reset), then re-run this script.
  ```

  When that removal fails (exit code not 0 and no "does not exist", as at l.106), `throw`:

  ```text
  Tailscale Funnel is switched on for <sites>, and the mapping could not be removed (<tailscale's text>): Open WebUI may be reachable from the whole internet right now. Quit Tailscale from its tray icon, then switch Funnel off (tailscale funnel reset).
  ```

- A site on another port is ours, whatever happened to 443: `throw` with the text below. It names
  every ours site that is still there and never says "removed": the public address exists. When
  443 was not funnelled, the mapping the script just created stays too; it is tailnet-only.

  ```text
  Tailscale Funnel is STILL ON for <sites> and forwards to Open WebUI: Open WebUI is reachable from the whole internet right now. This script did not set that up and has not changed it. Switch Funnel off on this PC now (tailscale funnel reset; if that fails, quit Tailscale from its tray icon), then run this script again.
  ```

- A funnelled site that is not ours: `Write-LaiLog WARN`, the script goes on:

  ```text
  Tailscale Funnel is switched on for <sites> on this PC: whatever answers there is reachable from the whole internet. This script did not set it up and cannot tell what answers there. If you did not set it up either, switch it off: tailscale funnel reset. That may remove the phone mapping as well, so run this script again afterwards.
  ```

- After that warning the success line at l.143 leaves out "not public" and reads "(HTTPS, survives
  reboots)": the script has just said that it cannot tell what the funnelled site reaches.
- Nothing funnelled: no message. The "not public" of l.143 then rests on a check; reword l.11 to
  say that the script stops when Funnel is on for the mapping.
- A record and an origin left by an earlier successful run stay as they are; the watch (C5) then
  reports that phone access is gone, which is true.

#### C2. Key expiry (T1)

- Target: `Enable-TailscaleAccess.ps1`, between l.141 and l.143.
- Source: `$status` from l.83. No new call. Field: `Self.KeyExpiry`.
- Proposed pure function in the module: `Get-LaiTailscaleKeyState -KeyExpiry <object> -Now <datetime>
  -WarnDays 14`, returns `@{ State; Days; When }` with `State` one of `off`, `ok`, `soon`,
  `expired`, `unknown`.
  - `$null`, `''` or a year before 2000: `off`.
  - A `[datetime]` is used as it is; a string is parsed with the invariant culture and
    `RoundtripKind`. Not parseable: `unknown`.
  - Compare in UTC (`.ToUniversalTime()` on both sides). PowerShell 7 hands over a `[datetime]`
    that can be of kind UTC, 5.1 a string: without this the two can differ by the time zone.
    `Days` is the floor of the difference; `soon` at `WarnDays` or less; `expired` below 0.
    `When` is the expiry as a UTC `[datetime]`.
- `off`, `Write-LaiLog OK`:

  ```text
  Tailscale reports no key expiry for this PC: phone access does not end by itself.
  ```

- `ok`, `soon`, `expired`, `Write-LaiLog WARN` (date as `yyyy-MM-dd`, the PC's local date:
  `When.ToLocalTime()`):

  ```text
  This PC's Tailscale key expires on <date> (in <N> days). From that day the phone can no longer open Open WebUI, and nothing on the PC or the phone says why. Switch key expiry off for this PC: Tailscale admin console > Machines > this PC > ... menu > Disable key expiry.
  ```

- `unknown`, `Write-LaiLog INFO`:

  ```text
  Tailscale's key expiry for this PC could not be read; look at this PC's row on the Machines page of the Tailscale admin console.
  ```

#### C3. Tailnet Lock state (T1)

- Target: `Enable-TailscaleAccess.ps1`, between l.141 and l.143, after C2.
- Source: one new call, `Invoke-Tailscale @('lock', 'status', '--json')`. Fields: `Enabled`,
  `NodeKeySigned`.
- It must degrade, never throw: `Invoke-Tailscale` throws on a timeout, an old client exits with an
  error, and `ConvertFrom-Json` throws on empty text. Wrap call and parsing in `try`/`catch`; parse
  `.Out` only.
- Proposed pure function in the module: `Get-LaiTailscaleLockState -Json <string>`, returns
  `unknown` (empty, not JSON, no `Enabled`), `off`, `signed` or `unsigned`.
- `unknown`, `Write-LaiLog INFO`:

  ```text
  Tailnet Lock: this Tailscale version did not report its state; not checked.
  ```

- `off`, `Write-LaiLog INFO`:

  ```text
  Tailnet Lock is off: this PC trusts every device that Tailscale's servers add to your tailnet. Turning it on is optional and can lock you out. What it protects, what you can lose and the steps are in docs/TAILSCALE-ACCESS.md in the toolkit's repository; the docs folder is not copied to this PC.
  ```

- `signed`, `Write-LaiLog OK`:

  ```text
  Tailnet Lock is on and this PC's key is signed.
  ```

- `unsigned`, `Write-LaiLog WARN`:

  ```text
  Tailnet Lock is on, but this PC's key is not signed: no other device, the phone included, will connect to it. Sign this PC from a signing device (its row on the Machines page of the Tailscale admin console shows the command).
  ```

#### C4. A record that Tailscale is used (T1)

- Target: `Enable-TailscaleAccess.ps1`. Set: between l.141 and l.143, before C2. Clear: with
  `-Disable`, right after l.32 and before the CLI lookup at l.34 (see "`-Disable` without
  Tailscale" below).
- Data: `<AIRoot>\localai-config.json`, proposed key `TailscaleServe` (`$true`). It survives
  updates (Install l.1885-1897). The file is outside what the integrity watch hashes.
- Do not use `$config`: it is unset whenever `-Port` is given, which is how the uninstaller calls
  the script. Read, change and save in one go:
  `$c = Read-LaiState -Path $p; $c['TailscaleServe'] = $true; Save-LaiState -State $c -Path $p`.
- With `-Disable`: remove the key and save only when the key is there, so that a PC that never had
  the file does not get one.
- A failed save must not fail a working mapping: `try`/`catch`.
- Set, `Write-LaiLog INFO`:

  ```text
  Recorded in localai-config.json that phone access over Tailscale is in use.
  ```

- Save failed, `Write-LaiLog WARN`:

  ```text
  Could not record in localai-config.json that phone access is in use (<error>); phone access itself works.
  ```

- Cleared: no new message (the line at l.108 says it).
- Who counts as "in use": proposed pure function `Test-LaiTailscaleInUse -Config <hashtable>
  -EnvLines <string[]>`, `$true` when `TailscaleServe` is set or a `WEBUI_EXTRA_ORIGINS=` line
  contains `.ts.net`. The second half is for an install where phone access was enabled before T1:
  it has the origin line (Enable l.141 writes it, `Write-StackEnv` at Install l.654-655 keeps it
  through updates) and never gets the key unless the script runs again. C5, C6 and C7 ask this
  function, so they work on such an install without anyone running anything again.
- `-Disable` without Tailscale. Today `-Disable` is reached only at l.104, after the `throw` for
  "not installed" (l.37) and the one for a state other than `Running` (l.85). An owner whose key
  expired, or who uninstalled Tailscale, could never clear the record, and the watch (C5) would
  report "Phone access" every day with no way to stop it. So, with `-Disable`, in this order:
  1. Remove the record (as above) and call `Set-WebUIExtraOrigin ''`. Move that function (l.89-102)
     above l.34; it needs only `$AIRoot`.
  2. CLI lookup. Not installed: no `throw`; `Write-LaiLog OK` with the first text below, `exit 0`.
  3. `status --json` serves only the address in the l.108 line. A failed call or a state other than
     `Running` does not stop `-Disable`; l.82 and l.84-86 guard the enabling path only.
  4. `serve --https=443 off` as at l.105. It worked, or "does not exist": the l.108 line (without
     the address when step 3 gave none), `exit 0`. Anything else: `throw` with the second text.

  ```text
  Tailscale is not installed on this PC, so nothing is published. Phone access is recorded as off; the watch no longer checks it.
  ```

  ```text
  Could not remove the mapping (<tailscale's text>). It is still stored: once Tailscale runs and is signed in, Open WebUI is served to your tailnet again. Then run Enable-TailscaleAccess.ps1 -Disable once more. Phone access is recorded as off; the watch no longer checks it.
  ```

#### C5. The watch: the mapping still exists (T2)

- Target: `Watch-LocalAI.ps1`, between l.375 and l.377.
- Gate: `Test-LaiTailscaleInUse` (C4) with `$config` and the lines of `<AIRoot>\Stack\.env` (a file
  read; `@()` when the file is missing). When it says no, the watch never starts `tailscale`.
- Find the CLI as Enable l.34-39 does, then call it only through `Invoke-LaiTimedNative
  -TimeoutSec 10` (or `LOCALAI_TS_TIMEOUT` when set, as Enable l.45 reads it), inside `try`/`catch`
  (it throws when the program is missing):
  1. `status --json`: `BackendState` (and `Self.KeyExpiry` for C6);
  2. `serve status --json`: a handler whose `Proxy` equals `"http://127.0.0.1:$webPort"`, the same
     walk as Enable l.135-139. Skipped when call 1 failed.
- Result name (proposed): `Phone access`. `$results['Phone access']` is `$true` only when the state
  is `Running` and the handler is there. Otherwise `$details['Phone access']` is one of:

  ```text
  Tailscale is not installed any more
  Tailscale did not answer within 10 s
  Tailscale gave no status
  Tailscale is '<BackendState>': sign in again in the Tailscale app on this PC
  Tailscale no longer forwards to Open WebUI
  ```

  The log line then reads `FAIL Phone access (Tailscale no longer forwards to Open WebUI)`, and the
  notification `Not working: Phone access (...)`, after two runs in a row (l.689-698).
- Hint: a new `elseif` in `Get-WatchHint`, between l.727 and l.728:

  ```text
  Open the Tailscale app on this PC and sign in if it asks. Then run Enable-TailscaleAccess.ps1 in <AIRoot>\Scripts again. If you no longer want phone access, run it with -Disable instead: that also ends this check.
  ```

  Build the folder with `Join-Path $AIRoot 'Scripts'`. The hint names the script because it has no
  Start-menu shortcut.
- No healing: the watch never publishes anything by itself.
- A deliberate `-Disable` is not a failure: C4 clears the record and the origin first, also when
  Tailscale is signed out or no longer installed.
- Recommended, beyond the item text, at no extra call: with a funnelled site that has
  `ReachesWebUI` in call 2 (`Get-LaiTailscaleFunnelSite`, C1), set `$results['Tailnet only'] = $false` (proposed name) with the
  detail `Tailscale Funnel publishes Open WebUI on the internet`. A Funnel switched on after the
  script ran is the case C1 cannot see.

#### C6. The watch: key expiry within 14 days (T2)

- Target: `Watch-LocalAI.ps1`, between l.453 and l.455; the state key is saved between l.812 and
  l.815, in the form of l.810.
- Source: `Self.KeyExpiry` from call 1 of C5. No extra call. Evaluate with
  `Get-LaiTailscaleKeyState` (C2), not with `ConvertTo-WatchDate`, which returns a `[datetime]`
  unchanged whatever its kind.
- Not a `$results` entry: everything still works (the reasoning of Watch l.380-381).
- Two stages, 14 days and 3 days: one toast is easy to miss (Watch l.76-77). Proposed key in
  `watch-state.json`: `tailscaleExpiryNotifiedFor`, value `<expiry>|<stage>`: the expiry in UTC to
  the second (`yyyy-MM-ddTHH:mm:ssZ`), the stage `14` while `Days` is 4 to 14 and `3` from 3 down.
- State `soon`: a notice is sent when that value differs from the stored one, so once per stage,
  and again for a new expiry (after signing in again). State `ok` leaves the stored value alone;
  state `off` removes the key.
- `<date>` in the text is the PC's local date, as in C2. The key is in UTC so that a change of
  time zone or of daylight saving does not send the notice twice.
- `Send-Notification`, title `Local AI: phone access ends soon`, text:

  ```text
  This PC's Tailscale key expires on <date> (in <N> days). After that the phone can no longer open Open WebUI, and nothing says why. Switch key expiry off for this PC: Tailscale admin console > Machines > this PC > ... menu > Disable key expiry.
  ```

- An expired key needs no notice here: the state is then not `Running` and C5 reports it.

#### C7. Ollama beyond loopback under the adapter-only firewall rule (T3)

- The hole: under the adapter-only rule port 11434 is blocked on the physical adapters only. A VPN
  adapter and Tailscale's are not among them, Ollama listens on all interfaces, and Ollama has no
  login. For a tailnet: every device in it can use Ollama unless the access policy (Part 1,
  procedure 1) stops it.
- The exposure comes from the PC being in a tailnet, which is the first step of the README's phone
  instructions, not from `Enable-TailscaleAccess.ps1` having run. So the warning does not wait for
  the record of C4; a sign of Tailscale only adds a sentence to it.
- Rule kind, two sources:
  - Live, in `Test-LocalAI.ps1` (Windows): pipe the rule that l.655 already fetches to
    `Get-NetFirewallInterfaceFilter`. An `InterfaceAlias` other than `Any` is the adapter-only rule
    (Install l.470), `Any` the address rule (l.479). This covers installs made before T3 and does
    not rest on a file the user can write.
  - Recorded, for `Enable-TailscaleAccess.ps1`, whose test must run on both jobs: proposed
    install-state flag `ollamaBlockRule`, set to `address` at Install l.1734 and to `adapters` at
    l.1745, removed when `ollamaLanFallback` is not set; copied to `localai-config.json` as
    proposed key `OllamaBlockRule` in the `$managed` table (Install l.1887-1895), so that scripts
    that do not run elevated can read it. An install made before T3 has no record until its next
    installer run: until then Enable prints nothing, and the health check, which reads the live
    rule, warns all the same.
- Proposed pure function in the module: `Get-LaiOllamaTailnetWarning -BlockRule <string> -Live
  <hashtable or $null> -TailscaleSeen <bool>`, returns the message or `''`:

  | `BlockRule` | `Live` | `TailscaleSeen` | Result |
  |---|---|---|---|
  | not `adapters` | any | any | `''` |
  | `adapters` | `HostIsLoopback` is `$true` | any | `''` |
  | `adapters` | `$null`, or `HostIsLoopback` is `$false` | `$false` | the message |
  | `adapters` | `$null`, or `HostIsLoopback` is `$false` | `$true` | the message, a space, the tailnet sentence |

  `$null` counts as "beyond loopback": under this rule the installer itself set all interfaces.
- `Live` comes from `Get-LaiOllamaLiveConfig -LogPath (Join-Path $env:LOCALAPPDATA
  'Ollama\server.log')` when `$env:LOCALAPPDATA` is set, else `$null`.
- `TailscaleSeen`: `Test-LaiTailscaleInUse` (C4), or, in `Test-LocalAI.ps1` on Windows, a network
  adapter that is up and whose `InterfaceDescription` starts with `Tailscale` (`Get-NetAdapter`;
  the name is from memory, 2.5 item 8). A miss costs the extra sentence, not the warning.
- Printed in two places:
  - `Enable-TailscaleAccess.ps1`, between l.141 and l.143, after C3, with the recorded kind and
    `-TailscaleSeen $true`: `Write-LaiLog WARN`.
  - `Test-LocalAI.ps1`, l.655-657, with the live kind and `-Live @{ HostIsLoopback = $false }`
    (l.648-654 has just seen the listener): when the function returns a message, `Warn` with it in
    place of "the LAN block rule is in place".
- Message:

  ```text
  Ollama on this PC listens on all interfaces, and the firewall rule in place blocks its port 11434 only on the physical network adapters (the installer had to fall back to that rule). VPN and Tailscale adapters are not covered: a device on such a network can use Ollama directly, without a login. Start menu > Local AI - Update toolkit tries the address-based rule again.
  ```

- The tailnet sentence:

  ```text
  This PC is in a tailnet: every device in it can use Ollama unless an access policy stops it. Limit the tailnet to your phone and port 443 (Tailscale admin console > Access controls). The text to paste is in docs/TAILSCALE-ACCESS.md in the toolkit's repository, part 1, procedure 1; the docs folder is not copied to this PC.
  ```

### 2.3 Items, file lists, order

No list holds a rule-7 file. All three items edit `tests/Invoke-WindowsUnitTests.ps1`, the only
unit-test file the Windows job runs, so no two of them fit in one batch, and none fits in a batch
with another item that edits a file of its list.

| Item | Checks | Files |
|---|---|---|
| T1 Enable-TailscaleAccess: Funnel, key expiry, Tailnet Lock, record of use | C1-C4 | `local-llm/Enable-TailscaleAccess.ps1`, `local-llm/lib/LocalAI.psm1`, `local-llm/tests/Invoke-WindowsUnitTests.ps1` |
| T2 Watch: phone access still mapped, key expiry within 14 days | C5, C6 | `local-llm/Watch-LocalAI.ps1`, `local-llm/tests/Invoke-WatchTest.ps1`, `local-llm/tests/Invoke-WindowsUnitTests.ps1` |
| T3 Ollama under the adapter-only rule: record and warning | C7 | `local-llm/Install-LocalAI.ps1`, `local-llm/lib/LocalAI.psm1`, `local-llm/Test-LocalAI.ps1`, `local-llm/Enable-TailscaleAccess.ps1`, `local-llm/tests/Invoke-WindowsUnitTests.ps1` |

Order: T1, then T2 and T3 in either order, each in its own batch. T2 needs T1's record,
`Test-LaiTailscaleInUse` and `Get-LaiTailscaleKeyState`; T3 needs T1's record and
`Test-LaiTailscaleInUse`, and edits two of T1's files. T1 and T2 may go to
one builder as one item (the union of both lists). T3 edits the installer away from its copy list
(l.1726-1745, l.1887-1895). If the integrator counts `Test-LocalAI.ps1` as "diagnostics", that
part of C7 goes to the integrator.

### 2.4 Tests, with a fake tailscale on PATH

The shim is `tailscale-shim.ps1` in `Invoke-WindowsUnitTests.ps1` (l.413-432), started by a `.cmd`
launcher on Windows and an `sh` launcher on Linux (l.433-438). `LAI_TS_SCENARIO` chooses its
answers. Leave the shim's last line (`exit 2`) and its normal answers as they are: the existing
assertion at l.463 then stays green and doubles as the "old client" case.

New shim answers:

| Scenario | Command | Answer |
|---|---|---|
| `funnel` | `serve status --json` | the normal `Web` object plus `"AllowFunnel":{"<the same site key>":true}` |
| `funnelport` | `serve status --json` | the normal `Web` object plus a site for the same host on port 8443 whose handler proxies to `http://localhost:3999`, and `AllowFunnel` for that 8443 key only |
| `funnelother` | `serve status --json` | the normal `Web` object plus `AllowFunnel` for the same host on port 8443, with no `Web` or `TCP` entry for it |
| `expiring` | `status --json` | the normal JSON plus `Self.KeyExpiry` holding the text of `LAI_TS_EXPIRY`, echoed as given: the shim computes no date |
| `lockoff` | `lock status --json` | `{"Enabled":false}` |
| `lockon` | `lock status --json` | `{"Enabled":true,"NodeKeySigned":true}` |
| `lockunsigned` | `lock status --json` | `{"Enabled":true,"NodeKeySigned":false}` |

One instant per case. The test works out the expiry once, as text
(`[datetime]::UtcNow.AddDays(10).AddHours(12)`, formatted `yyyy-MM-ddTHH:mm:ssZ` with the invariant
culture), puts it in `LAI_TS_EXPIRY`, and derives every expected value from that same text: the
local date in the messages (C2, C6) and the key in `watch-state.json`. A shim that worked out "10
days ahead" on each call would hand every run a different second; the once-only key of C6 would
differ, and a correct watch would send two notices. The half day keeps `Days`, and with it the
stage, the same on both runs. Clear the variable in `finally`.

Suite `Invoke-WindowsUnitTests.ps1` (both jobs), section "Enable-TailscaleAccess against a fake
tailscale CLI" (l.410-482), item T1:

| Check | Scenario | Assertion (the message is the test's name) |
|---|---|---|
| C1 | `funnel` | "Funnel on for the mapping: refused, mapping removed again, not reported as available" (exit not 0; text has "Funnel is switched on" and "removed again"; calls hold `serve --https=443 off`; no "available to your tailnet"; no `TailscaleServe`, see the note below the table) |
| C1 | `funnelport` | "Funnel on another port that forwards to Open WebUI: refused, and no removal is claimed" (exit not 0; text has "STILL ON" and the 8443 key; no "removed"; no "available to your tailnet"; calls hold no `serve --https=443 off`; no `TailscaleServe`) |
| C1 | `funnelother` | "Funnel on for another port: warned by name, phone access still set up, not called 'not public'" (exit 0; WARN names the 8443 key and says "cannot tell"; no "not public" anywhere in the text) |
| C1 | `ok` | the existing assertion at l.463, extended: the success line still says "not public" (the control for the row above) |
| C1 | none (pure) | "`Get-LaiTailscaleFunnelSite`: top level and Foreground; reaches Open WebUI by `localhost`, by `[::1]`, by a Foreground `Web` and by a `TCPForward`; another port does not; nothing from `{}`" |
| C2 | `expiring` | "a key that expires in 10 days is announced with its date" (exit 0; "expires on" plus the date) |
| C2 | `ok` | "no KeyExpiry: reported as no key expiry" |
| C2 | none (pure) | "`Get-LaiTailscaleKeyState`: string and `[datetime]`, UTC, 14-day boundary, year 1, garbage" |
| C3 | `lockunsigned` | "Tailnet Lock on and this PC unsigned: warned" |
| C3 | `lockon`, `lockoff` | "Tailnet Lock state reported (on and signed; off)" |
| C3 | `ok` | "a client without `lock status`: said so, still exit 0" (calls hold `lock status --json` once) |
| C4 | `ok` | "the record is written and other keys of the config survive" (seed a key first) |
| C4 | `ok` with `-Disable` | "`-Disable` removes the record" |
| C4 | `needslogin` with `-Disable` | "signed out: `-Disable` still removes the record and the origin" (set both first; exit 0; calls hold `serve --https=443 off`) |
| C4 | `-Disable` with the shim folder taken off `Path` | "no Tailscale: `-Disable` still removes the record, exit 0" (Windows job only: l.36 needs `$env:ProgramFiles`; the test fails, not skips, when a real `tailscale.exe` is there) |
| C4 | none (pure) | "`Test-LaiTailscaleInUse`: record only, origin only, an origin without `.ts.net`, neither" |
| C4 | `noapply` | "no mapping, no record" (see the note below the table) |
| C1-C4 | `needslogin`, `nohttps` | the existing assertions at l.468-470 still hold: no `serve` call, and now no `lock` call either |

The record in these rows. Every run of this section shares one `$aiRoot\localai-config.json` and
one `Stack\.env`, and by C1's last rule a failed run leaves an earlier record alone. The first run
(l.462, `ok`) writes both, and `-Disable` comes only at l.473. So the test itself removes
`TailscaleServe` and the origin line immediately before each of the `funnel`, `funnelport` and
`noapply` runs, and asserts that both are still absent afterwards; the C4 `ok` row is the positive
control. Without this a correct T1 fails "no record", and the short way to green, letting a failed
run clear the record, breaks the rule that the watch reports a lost mapping.

Same suite, a new section right after it, inside the same PATH setup, item T2. Run
`Watch-LocalAI.ps1` as a child with `-NoHeal -NoNotify` (l.377 already runs the watch that way,
without the shim): notices then land in `watch.log` as `NOTIFY` lines (Watch l.149). The sandbox
config needs `WebUIPort = 3999`, the port the shim's mapping points at.

| Check | Scenario | Assertion |
|---|---|---|
| C5 | `ok`, no record, no origin line | "without a record the watch never starts tailscale" (the shim's call log stays empty) |
| C5 | `ok`, origin line in `Stack\.env`, no record | "phone access enabled before the record existed: the watch checks" (the call log holds `status --json`) |
| C5 | `ok`, record set | "mapping present: Phone access is not among the failures" |
| C5 | `noapply` | "mapping gone: FAIL line names Phone access and the reason" |
| C5 | `needslogin` | "signed out: Phone access fails with the state" |
| C5 | `hang` | "a hung tailscale costs the watch its time limit, not the run" (state file still written) |
| C6 | `expiring`, expiry E1 10.5 days ahead, two runs | "10 days left: exactly one notice over two runs" (the stored key is `<E1>\|14`) |
| C6 | `expiring`, expiry E2 2.5 days ahead, the key set to `<E2>\|14` first | "the 3-day stage: one more notice for the same expiry" (exactly one; the key is now `<E2>\|3`) |
| C6 | the same E2, the key left at `<E2>\|3`, one more run | "3-day stage already told: no notice" |
| C6 | `expiring`, expiry E3 11.5 days ahead, the key still `<E2>\|3` | "a new expiry after signing in again is told again" |
| C6 | `ok` | "no expiry: no notice, the key is removed from watch-state.json" |

A notice here is a `NOTIFY` line of `watch.log` with the title `Local AI: phone access ends soon`;
the sandbox's other checks write `NOTIFY` lines of their own. E1 to E3 are fixed instants passed in
`LAI_TS_EXPIRY`, and "the key set" means `tailscaleExpiryNotifiedFor` changed in the existing
`watch-state.json` between runs. The second and third C6 rows fail when the stage logic is
missing, the fourth when the expiry is dropped from the key.

This section is what proves C6 on Windows PowerShell 5.1, where the date arrives as a string.

Suite `Invoke-WatchTest.ps1` (Linux end-to-end job), new section "11. phone access over Tailscale:
mapping gone, key about to expire", item T2. It needs its own `sh` launcher for the shim (the
suite's only fake so far is the `sh` docker at l.291-316; copy the launcher line of unit tests
l.436-437) and `LAI_TS_LOG`. Assertions: C5 `noapply` twice gives one "problem detected" notice
with the hint, then `ok` gives "back to normal"; C6 `expiring` with a fixed `LAI_TS_EXPIRY`, as above.

Suite `Invoke-WindowsUnitTests.ps1`, item T3:

| Check | Where | Assertion |
|---|---|---|
| C7 | section "Ollama firewall block ranges" (l.296), pure | "`Get-LaiOllamaTailnetWarning`: the four rows of the table; with no sign of Tailscale it still warns, without the tailnet sentence" |
| C7 | Enable section, scenario `ok`, config `OllamaBlockRule = 'adapters'` | "adapter-only rule: the warning is printed, with the tailnet sentence" |
| C7 | Enable section, scenario `ok`, config `OllamaBlockRule = 'address'` | "address rule: no warning" |

For the two Enable runs point `LOCALAPPDATA` of the child at a folder under the work folder that
holds a made-up `Ollama\server.log` (lines as at unit tests l.1956-1971), and restore it in
`finally`: otherwise the result depends on whether the runner has an Ollama log. The installer's
part (the flag at l.1734 and l.1745) and the health check's live read of the rule have no test
that runs on a job without the real firewall rule. Keep that read to one line that feeds the pure
function, and say so in the item's report instead of adding a skipped test.

### 2.5 For the integrator

Not in any builder's list; described here, to be made by hand.

1. **README.md l.540-543.** After "(`-Disable` removes it)." add:
   "By default every device in your tailnet can open that address, and the PC's Tailscale key
   expires after 180 days, which ends phone access without a message: `docs/TAILSCALE-ACCESS.md` in
   the repository (the docs folder is not copied to the PC) has the steps for an access policy that admits only the phone, for switching key expiry off, and for
   Tailnet Lock." Until T1 has shipped, "tailnet only" in l.542 is a promise nothing checks.
2. **IMPROVEMENTS.md**, four rows (`<n>` is the next free number), and in row 86 replace "then
   Tailscale with ACLs/Tailnet Lock" by a pointer to them:
   - `| <n> | Tailscale phone access: the owner's guide (86) | done | docs/TAILSCALE-ACCESS.md: an access policy that admits only the phone on port 443, key expiry off, Tailnet Lock with what it can cost. Written without web access: every Tailscale step in it is from memory and labelled so. Specifies rows <n+1> to <n+3>. |`
   - `| <n+1> | Enable-TailscaleAccess checks Funnel, key expiry and Tailnet Lock and records that Tailscale is used (86, audit R7) | open | TAILSCALE-ACCESS.md part 2, item T1 (C1-C4). |`
   - `| <n+2> | Watch: phone access still mapped; Tailscale key expiry within 14 days (audit R7) | open | TAILSCALE-ACCESS.md part 2, item T2 (C5, C6). After <n+1>. |`
   - `| <n+3> | Ollama reachable from the tailnet under the adapter-only firewall rule: record and warning (sweep security-3) | open | TAILSCALE-ACCESS.md part 2, item T3 (C7). After <n+1>. |`
3. **tests/Invoke-StaticChecks.ps1 l.145-151 (HANG).** With T2, extend the rule: a direct
   `tailscale` or `tailscale.exe` command in `Watch-LocalAI.ps1` is a HANG problem (use
   `Invoke-LaiTimedNative`), with a canary. A call through a variable (`& $ts`) is not seen by a
   name test; the canary should include that form if the rule is to cover it.
4. **Uninstall-LocalAI.ps1 l.183-190.** l.188 runs `tailscale serve status --json` directly, with
   no time limit: a stuck Tailscale service hangs the uninstaller, the case Enable l.42-43 guards
   against. Use a timed call. After T1 the `-Disable` call at l.190 also clears the record; no
   change is needed for that.
5. **Diagnostics bundle.** After T1 and T3: show `TailscaleServe` and `OllamaBlockRule`. Do not
   include raw `tailscale status --json`: it carries device names, the tailnet name and addresses.
   State, days until expiry, lock state and Funnel on or off are enough.
6. **The docs folder is not on an installed PC.** `Get-LocalAI.ps1` l.268-275 classes `docs/` as
   not installed, and `Install-LocalAI.ps1` names no docs folder. The messages of C3 and C7 and the
   README sentence of item 1 therefore say "in the toolkit's repository" and carry what the owner
   needs to act without the file (C2 the menu path, C7 the console page). If Part 1 should be on
   the PC instead: copy this one file with the toolkit (installer copy list), class it as `toolkit`
   at `Get-LocalAI.ps1` l.275 with its test, and point the three texts at the installed path. T1 to
   T3 do not depend on that.
7. **tests/README.md.** Describe the new sections when T1 to T3 land.
8. **Before T1 ships:** someone with a real Tailscale client and its documentation confirms the
   rows marked "from memory" in the status table, first of all `KeyExpiry`, `AllowFunnel`,
   `lock status --json` and the two commands printed in messages. Until then C2 and C3 can only
   under-report (they fall back to "no expiry" and "not checked"), and C1 can miss a Funnel. Also
   to settle, each with what rests on it:
   - Does `tailscale funnel reset` remove `serve` mappings too? The messages assume it may, and
     say to run the script again. Is `tailscale funnel --https=<port> off` the targeted form?
   - `Foreground.<id>.Web` and `TCP.<port>.TCPForward`: C1's `ReachesWebUI` reads them.
   - Does `serve --https=443 off` work on a signed-out client? C4's `-Disable` handles both answers.
   - Does a device that signs in again need a new Tailnet Lock signature? Part 1 (2.4, 3.1, "What
     you can lose") warns as if it does.
   - Does a locked-out device's `tailscale lock status` print its `nodekey:`, and where does the
     phone app show it? Step 3.9 compares against it.
   - The exit-node rule of step 1.2 (`autogroup:internet:*`).
   - The Tailscale adapter's `InterfaceDescription` on Windows (C7's extra sentence).

Sources: IMPROVEMENTS row 86 (Tailscale with ACLs and Tailnet Lock); audit R7
(`docs/AUDIT-2026-10-06.md` l.59); sweep security-3 (the warning at Install l.471).
