# Tests

These harnesses check the scripts before they ever run on Windows. CI runs them all on every push: `.github/workflows/local-llm-linux.yml` rebuilds this sandbox from scratch on Ubuntu (several jobs side by side, see *How CI runs them* below), and `local-llm-windows.yml` runs the static checks, `Invoke-WindowsUnitTests.ps1` and `Invoke-GetLocalAITest.ps1` on real Windows PowerShell 5.1. The integration test and the installer mock run both run under
PowerShell 7 on Linux against **real** servers. The only stand-in is a small Qwen3 model (same
architecture family and chat template as the real ones), so the tests fit on a CPU-only box.

**Never run these on a PC with a real install.** They create, rename and delete the containers and
volumes named `open-webui`, `searxng` and `deep-research`, change the admin password and unload
models. Every script that touches Docker, Ollama or Open WebUI therefore stops at once (exit 99,
nothing changed) unless the machine is marked as a throwaway sandbox: `LAI_SANDBOX=1` in the
environment (the CI workflows set it) or a file `~/.lai-sandbox` (create it once on the sandbox).
On Windows a real install (`C:\AI\install-state.json`) refuses even with the marker, except in
GitHub Actions. `Invoke-StaticChecks.ps1` only reads files and runs anywhere.

| Script | What it proves |
|---|---|
| `Invoke-IntegrationTest.ps1` | The API layer (`lib/LocalAI.psm1`) against Ollama v0.35.1 and Open WebUI v0.11.4: it covers the context tuner, the tuned aliases, presets, hiding raw models, admin/RAG/web-search config (run twice to check it's idempotent), knowledge collections, and the chat/memory/RAG/web-search smoke tests, plus the health check's direct SearXNG probe against the real image (it finds pages or names every failed engine). Last, it runs the real render guard in front of that Ollama with a faked ComfyUI: a chat sent to the CPU during a "render" must be followed, after the hold, by a fresh load (`load_duration`), not the reused CPU runner. |
| `Invoke-InstallerMockRun.ps1` | The full `Install-LocalAI.ps1` orchestration, with Windows-only commands mocked: a fresh run that hits a reboot, a resume via the logon task, migrating a manual-install container, `.env`/secret handling, backup task, report, and an idempotent re-run. After the install and again after the re-run it reads the integrity baseline the installer recorded (reason `install`, the installed scripts and stack files, nothing from `.env`, logs or a Secrets folder) and compares the folder with it: no file, setting or task may differ right after an install, and the re-run must list the custom `.env` routing setting it kept. Every phase passes `-SkipTests`, so the installer's own health-check stage does not run here; that it runs in the installer's process, under the setup lock and before the baseline is recorded, is read from the installer's text. Phase 7 covers other hardware and setups: a 16 GB card and a PC without an NVIDIA GPU (refused before any download), the Ollama app's own Model location / Expose settings in `server.log`, Ollama in a custom install folder, a PC with 8 GB of RAM (`.wslconfig`, render-guard warning), and a `searxng` container from Open WebUI's own guide. The sandbox's `searxng` container is parked as `searxng-uninstall-test-keep` for the run and restored at the end. It also covers the rules file for an AI agent (`config\agent-rules.md`, placed as `AI\CLAUDE.md`): placed byte for byte on a fresh install; no `CLAUDE.md` anywhere in the toolkit copies (`AI\Scripts`, `Program Files\LocalAI`, the repository's `config` folder), where an agent would load it as a second set of rules; a file the owner edited kept byte for byte on a re-run (phase 3); a file the owner had in a new folder before the first install kept as it is (phase 7f); a missing file placed again by an update (7f); and checks on the template itself (ASCII only, its five sections, everything destructive under Never, the read-only checks under Fine without asking, every script it names exists, and its note on `-AIRoot`: every script it names outside Never either takes `-AIRoot` or is named together with `LOCALAI_ROOT`). |
| `Invoke-ModelUpdateTest.ps1` | `Update-Models.ps1` against a real Ollama, on private copies of the stand-in model: an unchanged pull keeps no extra copy, a re-published tag keeps `<tag>-prev` and re-tunes, a re-published tag this Ollama cannot load (`LOCALAI_TEST_LOAD_FAIL`) leaves the tuned alias alone and names `-UpdateOllama` / `-Rollback`, a failed re-check after an Ollama update does not advise `-Rollback`; `-RecheckOnly` downloads nothing and records the running Ollama, `-Scheduled` skips with exit 0 while the GPU is busy (`LOCALAI_TEST_GPU_BUSY`) or the setup lock is held, discards a measurement interrupted by a GPU program (`LOCALAI_TEST_GPU_BUSY=after-load`) or a chat (`LOCALAI_TEST_CHATS_IN_FLIGHT=after-load`), records a preset it cannot set up in `model-recheck.json` (also when the measurement fails with the model loaded, `LOCALAI_TEST_SPEED_FAIL`) and keeps that record over a later skip; a preset left partly on the CPU is re-tuned from the largest context; a finished or failed run frees the setup lock while its window stays open; then `-Rollback` and `-DropPrevious`. |
| `Invoke-UpdateWebUITest.ps1` | `Update-OpenWebUI.ps1` on a throwaway stack (alpine images standing in for Open WebUI versions): an update records a rollback point, a failed pull changes nothing, an update killed mid-download leaves `.env` alone, an install left with `.env` naming a version that never ran is set back first, the rollback archive survives pruning, `-Rollback` brings back the old image and the pre-update data, and a second rollback refuses. Also the backup's wait for a chat answer, its sign-in run (a no-op after a night's backup, a catch-up after a missed one), a missing deep-check image being counted, a restore killed right after it turned auto-restart off, and one whose `docker stop` fails. A SearXNG-only update records and prints the tag it replaced (the way back). |
| `Invoke-UninstallTest.ps1` | `Uninstall-LocalAI.ps1` against real Docker with a fake Ollama (it records deletes, so the real models stay put) and mocked scheduled tasks: `-WhatIf` changes nothing; the default removal takes a verified backup and removes containers, aliases and tasks while keeping data; `-RemoveData -RemoveModels`; and a failing backup that aborts before anything is removed. A `CLAUDE.md` in the install folder (the rules for an AI agent, which the owner may have edited) is still there after `-RemoveData`, its content unchanged, and the closing message lists it once as kept; when there is none, no output line names one. A sandbox `searxng` container is moved aside and restored. |
| `Invoke-WatchTest.ps1` | `Watch-LocalAI.ps1` against real containers: a stopped SearXNG is restarted, nothing is healed while paused, Open WebUI is left alone while another process holds the volume lock, a docker CLI that never answers is reported (watch and backup) instead of hanging, and Open WebUI unable to reach Ollama is a failed check. An Ollama newer than the one the presets were tuned on gets exactly one notice naming the Re-check models shortcut, never a failed check, and none once the tuning records it; with the nightly re-check armed, no notice at all, then exactly one for a failed re-check (not repeated when the next night finds the same) and one when it could not run for 72 h. Section 10 is the integrity watch on files and the `.env` routing settings (Linux has no Task Scheduler and no listener list, so tasks and listeners are left to the Windows unit tests): nothing is compared without a baseline; `.env` versions, logs and a Secrets folder are not differences; a changed script is looked for about once an hour, needs two looks and is announced once, also when the file is rewritten between the looks or the first notification fails; the Open WebUI banner shows names as code and cannot carry a link; the health-check line and its advice (no shortcut is named when a script changed); new and deleted files told together; a changed Ollama address named without its value; 235 new files at once told in one notice and never again; an unfinished install as one added sentence; the setup lock held by another process (nothing compared, said once, announced after hours); the health check called inside an installer; a comparison that was started and did not finish is not started again on every run; a run ended in the middle of its first comparison with a new baseline (the test hook `LOCALAI_TEST_INTEGRITY_END`, which works only with that baseline's id) keeps its mark and what it announced under that baseline, is not restarted for an hour, then finishes, and its "not being checked" notice names the variable instead of sending the owner to an installer window or a restart (the notice for a held setup lock does give that advice); `-AcceptBaseline` and the notification that confirms it, and with more than 200 changes it prints 50 by name and counts the rest; what an update kept that it did not install; and a baseline that was deleted. |
| `Invoke-WindowsUnitTests.ps1` | The parts that need no sandbox services, on Windows PowerShell 5.1 (the Windows job) and on PowerShell 7 (the Linux gate job): the setup mutex and its access list, Start-menu shortcuts, UTF-8 request bodies, and smoke runs of the watch, the uninstaller and the stop script, among others. Its integrity-watch section covers the pure functions: what is left out, cleaned names, a folder swapped for a link while it is read, the walk budget, the `.env` routing settings, the cap on what the watch remembers, the listener baseline (temporary ports, the 90-day carry), which differences are news, the advice, an unfinished install, what a baseline took in and what the next one carries on until somebody has looked (60 kept items listed and carried in full, the rest as a number that does not shrink: `-MaxListed`, and a baseline in the old 50-name form; an acceptance by hand settling what an update kept without any notification; an unreadable `watch-state.json`, a folder here and the file held open on Windows; the stopped-walk line on a second acceptance), and where the installer records its baseline (read from its syntax tree). On Windows only: a real scheduled task, real listeners, and the watch end to end as the scheduled task runs it (baseline, three changes, two looks, the setup lock, `-AcceptBaseline`). Its `Test-PCSecurity.ps1` section covers the helpers (driver matcher, redaction, the verdicts for folder permissions and ports, the ComfyUI scan) and the judges for what a real PC audit found: an antivirus that is snoozed, expired or out of date (also behind a Defender that stands back for it), a hardware-access driver any program can open, firewall openings for script runners, and a stopped OneDrive the backups lie in. Each judge gets canned input in three ways: one that must be flagged, one that must not be, and one that could not be read, which must come out as not checked and never as fine. It also checks that the script runs no command that changes the PC, that its one piece of compiled code imports only `CreateFileW` and `CloseHandle` and opens a device with no access asked for, and a full run in a child process: it must reach its summary line, print the three new rows and one Antivirus row, each with words after the colon, and write a report without the user name or the computer name. On Windows only: the readers against the machine itself (the `NUL` device opens and a made-up device name does not, the runner's firewall rules are in the form the check reads, the Security Center and OneDrive readers answer, the session filter finds the test's own process exactly when it runs in a desktop session). The Windows runner has administrator rights, so the driver row is not tested there by design: opening the device of a listed driver is never tried in CI, only `NUL`. |
| `Invoke-GetLocalAITest.ps1` | `Get-LocalAI.ps1`'s update review without a network. The decision functions are read out of the bootstrap with the parser and fed GitHub answers as text: first install, update, repair run, a failed or unreadable comparison, an unknown installed commit, an older or diverged commit, a long file list, hostile text, the commit read from its page when the API does not answer (also a folded subject line), the typed answer, and the one variable that skips the question. The bootstrap's flow is checked on its syntax tree. On Windows the whole bootstrap also runs in a child process with stand-ins for GitHub and for the installer; that block creates the empty all-users Start-menu folder `Local AI` for one run and removes it again, so it needs administrator rights (the CI runner has them), and on a machine that already has the folder the first-install runs are skipped with a message. It needs no Docker, Ollama or Open WebUI, but still carries the sandbox guard because the Windows block starts the bootstrap. |
| `Invoke-StackSmokeTest.ps1` | The production stack itself: `stack/docker-compose.yml` with the real images, set up the way the installer does it (compose file, render guard and SearXNG settings copied into a Stack folder, a `.env` with test values, `docker compose pull` and `up`). Every service runs, is healthy and has not restarted; every published port is bound to 127.0.0.1 only; Open WebUI answers with the pinned version and reaches Ollama through the render guard and SearXNG over the compose network; with `-DeepResearch` that service answers too. It also reads each service's container hardening back, from `docker inspect` and from the kernel inside the container: no new privileges, the capability bounding set, the memory and process limits, the user, the read-only root, and the only folders a read-only service can write to (tmpfs mounts with a size limit that nothing can be run from; the mounts under `/dev`, Docker's own `/dev/shm` among them, are not tried). SearXNG is started with a `settings.yml` as old as an existing install's and must answer as user 977 on read-only mounts with a clean log (what single search engines answer is not judged). The render guard's status page must show a size cap for one chat that is above the chat the test sends; then a chat with 64 MB of pictures goes through the guard, and at the end no container may have been ended for exceeding its memory limit or restarted. The test's `.env` sets no `RENDER_GUARD_MAX_BODY_MIB`, so it does not show that a number set there reaches the guard. Not covered: the Windows bind mount, document upload, a web search from a chat, saving the skill notebook tool, a full deep research run. Then the stack is taken down and nothing of it may remain. Its containers have the fixed names `open-webui`, `searxng`, `render-guard` and `deep-research`, which clash with the shared sandbox, so it is **not** in `Invoke-AllTests.ps1`: it needs a clean Docker engine and runs in a CI job of its own. It starts and probes the stack only; backup, wipe and restore on that stack are not tested yet. |
| `Invoke-AllTests.ps1 -SelfTest` | The runner itself: a suite whose program is missing, one that prints ASSERT FAIL but exits 0, one without its PASSED banner, one with a non-zero exit, and one that hangs (killed with its child process after the time limit) are all reported as failed. The skip rule (see *A skipped test fails its job* below): a suite that skipped a block fails under CI and passes outside it; it passes under CI when the job declares that skip, and fails again when the declared message is worded differently; each of the four ways a suite prints a skip is caught, and so is a skip without a reason; the product's own SKIP verdicts, printed or quoted by a passing test, are not taken for one. The same through `-Step`: the suite's exit code is kept, and a suite that leaves a helper process holding its output still ends with the suite, with its skip line read. |
| `Reset-Sandbox.ps1` | Puts the shared sandbox back (throwaway containers and volumes, helper processes, a parked SearXNG, test models, the admin password, Open WebUI's Ollama connection). `-Check` only reports: the runner runs it after every suite, and a suite that leaves anything behind fails. Helper processes are looked for with `pgrep`; on a machine without it that part cannot look, which under CI counts as a failed check and elsewhere is one yellow line. |
| `test_render_guard.py` | `render_guard.py` with a fake ComfyUI and a fake streaming Ollama that follows Ollama 0.35.1's runner-reuse rule (a request without `num_gpu` reuses the loaded runner). It checks CPU routing while busy and for the hold period, that the CPU copy is unloaded after the hold (by the watcher, or exactly once by the first of two concurrent chats) so the next chat loads fresh, that a 500 from Ollama during that unload is retried (and given up after 5 tries), that a CPU copy evicted by another model is no longer marked, `/free` with back-off, 20 concurrent streams, images dropped for a model without `vision` (and passed through when `/api/show` fails; capabilities read again after a pull through the guard and after `CAPS_NO_VISION_TTL_SEC`), ComfyUI read through `/api/queue` when `/queue` is refused, connected-but-silent counted as busy, unreachable counted as not busy, a status page with slow ComfyUIs answering well within the backup's wait for it, and SIGTERM. Request bodies: an upload (a model file for `/api/blobs`) is passed on piece by piece, with a Content-Length and chunked, and Ollama holds the first half before the client sends the second; a client that hangs up in the middle of an upload, or sends one the guard cannot read to its end, gets no answer from the guard (no 502) and Ollama sees the upload cut short; a chat or generate call above `RENDER_GUARD_MAX_BODY_MIB` gets HTTP 413 with one line that names the setting and never reaches Ollama, in both framings, while a chat of exactly the cap passes byte for byte; a chat sent two bytes to the chunk does not make the guard hold more than the cap counts (its peak memory is read from `/proc`, so the suite needs Linux); a Content-Length that is not a number gets HTTP 400; and after its own answer the guard reads on from a client that keeps sending for `DRAIN_SEC`, and no longer. Not covered: the guard's 502 answer when Ollama cannot be reached while a client is still sending (every guard in the suite has a reachable fake Ollama). |
| `../Test-LocalAI.ps1 -CatalogPath tests/models.test.psd1 -NoContainers` | The acceptance checklist itself. |

## How CI runs them

The Linux workflow used to be one job that ran every suite in a row and took about 57 of its 60
minutes. The suites share one Ollama, one Open WebUI and one Docker engine, so they cannot run side
by side on one machine. Now each job is a machine of its own with only the services its suites need,
and the jobs run in parallel:

| Job | What runs there |
|---|---|
| `gate` | Static checks, the runner self-test, the render guard test, the cross-platform unit tests and the bootstrap update review: the five suites that need no sandbox services. |
| `integration` | The integration test, then the health watch test. |
| `installer` | The installer mock run. |
| `webui-update` | The Open WebUI update / rollback test, on its own. It shared the `installer` job until the two together took 39 of that job's 40 minutes (the mock run 17, the update test 17, the Open WebUI setup 3). The update test ends in the quick health check, which only passes on an Open WebUI that has the tuned model aliases and presets, and the mock run used to leave them. So this job makes them itself, in the step before the test, with the model setup and Open WebUI setup calls of the integration test, without its knowledge collections. It starts no deep research image. |
| `models` | The model update test, then the uninstall test (Ollama and Docker only). |
| `stack` | `Invoke-StackSmokeTest.ps1`: the production stack from the compose file with the real images. |
| `all-passed` | Needs every job above and fails unless each one succeeded, and unless its list of jobs is the list of jobs in the file. Its name, `local-llm Linux - every job passed`, is the one status to require on the branch. |

Every sandbox job ends with the leftover check (`Reset-Sandbox.ps1 -Check`) and prints the service
logs when it failed. The jobs that start SearXNG from the compose file (`integration`, `installer`,
`webui-update`) make its folder readable first, because the compose file runs it as user 977, and
stop with its log when it does not answer. No sandbox job is expected to need more than about 25
of its 40 minutes; that is an estimate until CI has run a few times (`installer` about 22 and
`webui-update` about 25 are guesses). The `gate` job is cut off at 20 minutes, not 40: its last
green run took 2.8, before the render guard test and the unit tests grew in batch 3. Adding a job
means adding it to the `needs` list of `all-passed`. If the branch protection requires `local-llm Linux - every job
passed` only, nothing else has to change. A rule that names a single job holds that job's title,
and the installer job's title changed (it was `Installer mock run and Open WebUI update / rollback
test`): such a rule needs the two new titles in its place.

The Windows workflow is one job, all on Windows PowerShell 5.1 and cut off at 20 minutes: a check
of the skip rule below (a made-up suite that prints a SKIP line must fail its step with a line that
names the skip, and pass once the job declares it; a suite's own exit code and an argument with a
space must come through), the static checks, `Invoke-WindowsUnitTests.ps1` and
`Invoke-GetLocalAITest.ps1`.

## A skipped test fails its job

A test that did not run proves nothing, and a block that runs on one system only would drop out
unseen the day a runner changes. So under CI (GitHub Actions sets `GITHUB_ACTIONS` to `true`) a
suite step fails for every block the suite skipped, unless the job says that this skip is right
for it. Outside CI nothing changes: a skip stays a grey line.

- **How a step is started.** The workflows start every suite step through the runner:
  `Invoke-AllTests.ps1 -Step <suite file> -StepArgs <the suite's own arguments>`. It shows the
  suite's output as it comes and keeps its exit code; when that is 0, the step's exit code is the
  number of skips the job has not declared, each named in a line `ASSERT FAIL skipped under CI, not
  declared for this job: <message>`. A new suite step must be started the same way, or its skips
  go unseen. Typed in a PowerShell session it looks like this:

  ```powershell
  & ./tests/Invoke-AllTests.ps1 -Step ./tests/Invoke-WatchTest.ps1 -StepArgs '-Work', '/tmp/watch-test'
  ```

  Not as `pwsh tests/Invoke-AllTests.ps1 -Step ... -StepArgs '-Work', ...`: started that way, a
  value that begins with `-` is read as a parameter of the runner, and the run stops before the
  suite starts.
- **How a skip is declared.** Each job in the workflow file has a variable `LAI_DECLARED_SKIPS`: one
  skip message per line, letter for letter what the suite prints after `SKIP`. Only the Linux
  `gate` job has a list: it runs the Windows suites on Linux, where their Windows-only blocks
  cannot run, and the Windows job runs those blocks. Every other job, the Windows job included,
  declares none, so any skip there fails the job (a deep research image that was not pulled, a
  leftover volume in the uninstall test). To declare a skip, add its message as a line to
  `LAI_DECLARED_SKIPS` of the job the suite runs in, in the same change that adds or rewords the
  skip. First ask whether the block can run on that job: a declared skip is a decision that the
  block may be left out there.
- **What counts as a skip.** A line of the suite's output in one of four forms, at the start of a
  line: `  SKIP        <why>` (the `Skip` function of the unit tests and the bootstrap test; the
  mock run prints the same form), `HH:mm:ss [WARN] SKIP <why>` (the integration test),
  `  (skipped: <why>)` (the uninstall test) and `<why>; skipped.` (the static checks without
  PSScriptAnalyzer). A skip without a reason always fails. The product's own verdicts
  (`HH:mm:ss [INFO] SKIP <check>: ...` from the health check and the security check) are not skips
  of a test. A suite should print its skips through its `Skip` function. An `if` without an `else`
  leaves a block out without a word, and the runner cannot see that: give it an
  `else { Skip '<why>' }`.
- **What the rule does not see.** The steps that are not started through `-Step`: the static
  checks, the runner self-test and the render guard test. A declared skip that no longer happens
  is not reported, so a list can keep a line nobody needs. And `-Step` does not ask for the suite's
  PASSED banner, which the full runner does: a suite that ends early with exit 0 and prints no skip
  line still passes its step.

## Sandbox setup used

```bash
# Ollama 0.35.1 (CPU) with the stand-in model imported as testorg/qwen3-abliterated:1.7b
docker run -d --name ollama-test -p 127.0.0.1:11434:11434 -e OLLAMA_FLASH_ATTENTION=1 \
  -e OLLAMA_KV_CACHE_TYPE=q8_0 -e OLLAMA_HOST=0.0.0.0:11434 ollama/ollama:0.35.1
#   ollama create testorg/qwen3-abliterated:1.7b -f Modelfile   (FROM qwen3-1.7b-q4_K_M.gguf)
#   ollama create nomic-embed-text -f Modelfile                (sandbox embedding model, see below)

# Open WebUI 0.11.4 from PyPI, with the same environment variables as stack/docker-compose.yml plus:
#   WEBUI_ADMIN_EMAIL=admin@localhost WEBUI_ADMIN_PASSWORD=Test-Password-123
#   RAG_EMBEDDING_ENGINE=ollama RAG_EMBEDDING_MODEL=nomic-embed-text:latest
#   SEARXNG_QUERY_URL=http://localhost:8888/search?q=<query>
pip install open-webui==0.11.4 && open-webui serve --port 3000

# SearXNG straight from stack/docker-compose.yml
docker compose -f stack/docker-compose.yml up -d searxng

pwsh tests/Invoke-AllTests.ps1                 # every suite, one after another, one summary table
pwsh tests/Invoke-AllTests.ps1 -Only Static,Mock   # a subset
```

Run the suites through `Invoke-AllTests.ps1` (or one at a time, after `pwsh tests/Reset-Sandbox.ps1`). A suite passes only with exit 0, its own PASSED banner, no ASSERT FAIL line, within `-TimeoutSec` (default 1800), and with nothing left behind (under CI also: with no skip its job has not declared, see above). They share one Ollama, one Open WebUI and one
Docker engine, so running two at once makes them unload each other's models and fight over the
`open-webui` volume. The failures look like product bugs. The runner holds a lock file, so a second run refuses to start.

`Invoke-StaticChecks.ps1` also scans for runtime pitfalls that parse cleanly. Each one was a real bug here:
- `Measure/Sort/Select -Property <name>` on hashtables (fails on 5.1).
- `Write-X ('...') -f $a`, where `-f` becomes a separate argument.
- `$Matches` read after a second `-match` in the same condition.
- `$PSBoundParameters` inside a `&`-invoked scriptblock, where it is empty.
- A service in `stack/docker-compose.yml` that lacks the container hardening (rule `COMPOSESEC`): no
  `no-new-privileges`, no ALL under `cap_drop`, no `mem_limit` or `pids_limit`, a published port not
  bound to 127.0.0.1, a line that hands it all back (`privileged`, ALL under `cap_add`, a `<<` merge
  or `extends` at the service's own level), or a line the check cannot read as `key: value`.

Built-in canaries check that every rule still fires.

The sandbox blocks Hugging Face, the tiktoken CDN and the public search engines. So:
- embeddings use an Ollama model instead of the default embedding model, which ships inside the official Docker image;
- the RAG test uses the `character` splitter (the official image pre-caches the tiktoken file that `token` needs);
- web search shows up as `no-results`, which shows the Open WebUI → SearXNG link works and only the upstream engines were unreachable.
