# Bootstrap: downloads the newest toolkit as a ZIP and starts Install-LocalAI.ps1 from it. Use it for
# the first install and for every update (Start menu > Local AI > Update toolkit runs this file).
# Paste into a normal (non-admin) PowerShell window:
#
#   $env:LOCALAI_REF = 'main'
#   [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
#   irm https://raw.githubusercontent.com/MpLLC303/ComfyUi-Optimization/refs/heads/main/local-llm/Get-LocalAI.ps1 | iex
#
# LOCALAI_REF selects the branch, tag or commit to install from. LOCALAI_ARGS passes installer options,
# e.g. $env:LOCALAI_ARGS = '-OfficialModels none'. Everything runs inside a script block so the settings
# below do not leak into your PowerShell session.
#
# Update review: when Local AI is already installed, nothing is downloaded until you have seen what is
# installed now, the commit about to be installed (id, date, subject line) and the files that differ
# between the two, and have typed OK at the keyboard (an OK piped in, or pasted ahead of the question,
# does not count). A first install has nothing to compare and is not asked.
# The one way to skip the question, for a run nobody watches: name the commit you reviewed, in full:
#
#   $env:LOCALAI_REVIEWED_COMMIT = '<its 40-character id>'
#
# It counts for exactly that commit. When the branch has moved on, or the commit cannot be named
# (GitHub does not answer and LOCALAI_REF is not itself a full commit id), the question is asked as
# usual, and without a typed OK nothing is installed.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # ---- Update review ---------------------------------------------------------------------------
    # Pure functions: the fetched data and the typed answer come in as parameters, and none of them
    # touches the network or the console (tests\Invoke-GetLocalAITest.ps1 runs them as they are).

    function ConvertTo-ReviewText {
        # Text from outside (a commit's subject line, a file name, an error message) as one printable
        # line of at most -Max characters, so nothing GitHub sends can repaint the window or add a
        # line of its own. Only plain ASCII stays; -AllowUnicode (this PC's own error messages) drops
        # control characters only.
        param([string]$Text, [int]$Max = 100, [switch]$AllowUnicode)
        if ($AllowUnicode) { $t = $Text -replace '[\x00-\x1F\x7F]', ' ' } else { $t = $Text -replace '[^\x20-\x7E]', '?' }
        $t = $t.Trim()
        if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
        return $t
    }

    function Get-ReviewField {
        # $Object.a.b of an answer from GitHub; $null when a step is missing (outside data: no
        # property is taken for granted).
        param($Object, [string[]]$Path)
        $o = $Object
        foreach ($name in $Path) {
            if ($null -eq $o) { return $null }
            $prop = $o.PSObject.Properties[$name]
            if ($null -eq $prop) { return $null }
            $o = $prop.Value
        }
        return , $o
    }

    function ConvertTo-ReviewDate {
        # GitHub's date as yyyy-MM-dd (UTC). PowerShell 7 hands it over as a date, Windows PowerShell
        # 5.1 as text.
        param($Value)
        if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
        if ([string]$Value -match '^(\d{4}-\d{2}-\d{2})T') { return $Matches[1] }
        return ''
    }

    function ConvertTo-ReviewCount {
        # A count from GitHub's answer as text; '?' when it is not a plain number.
        param($Value)
        if ([string]$Value -match '^\d{1,9}\z') { return [string]$Value }
        return '?'
    }

    function Get-CommitSummary {
        # Id, date and subject line of a commit as GitHub's API describes it; $null when the answer
        # does not hold a full commit id.
        param($Commit)
        $sha = [string](Get-ReviewField -Object $Commit -Path 'sha')
        if ($sha -notmatch '^[0-9a-f]{40}\z') { return $null }
        $message = [string](Get-ReviewField -Object $Commit -Path 'commit', 'message')
        return [pscustomobject]@{
            Sha     = $sha.ToLowerInvariant()
            Date    = ConvertTo-ReviewDate -Value (Get-ReviewField -Object $Commit -Path 'commit', 'committer', 'date')
            Subject = ConvertTo-ReviewText -Text (($message -split "`r?`n")[0]) -Max 100
        }
    }

    function Get-IncomingCommit {
        # The commit -Ref points to: GitHub's answer when it names one. When it does not, a -Ref that
        # is itself a full commit id (it pins the download by itself; date and subject line stay
        # empty). Otherwise $null: a branch or tag GitHub does not answer for cannot be pinned.
        param([string]$Ref, $Answer)
        $summary = Get-CommitSummary -Commit $Answer
        if ($summary) { return $summary }
        if ($Ref -match '^[0-9a-f]{40}\z') { return [pscustomobject]@{ Sha = $Ref.ToLowerInvariant(); Date = ''; Subject = '' } }
        return $null
    }

    function Get-InstalledToolkit {
        # What the install in the AI folder says about itself: Install-LocalAI.ps1 records
        # ToolkitVersion and ToolkitCommit in localai-config.json near its end.
        #   State 'none'     nothing is installed there: a first install
        #   State 'known'    an install, and the commit it came from
        #   State 'unknown'  an install, but not which commit (Why: what exactly is missing)
        # -ConfigText: the text of localai-config.json, $null when there is no such file.
        # -OtherSigns: the folder holds other traces of an install (install-state.json, the Scripts
        # folder). Whatever cannot be read is 'unknown', never 'none'.
        param($ConfigText, [bool]$OtherSigns)
        $r = [pscustomobject]@{ State = 'none'; Version = ''; Commit = ''; Why = '' }
        if ($null -eq $ConfigText) {
            if ($OtherSigns) { $r.State = 'unknown'; $r.Why = 'there is no localai-config.json: the install did not finish' }
            return $r
        }
        $r.State = 'unknown'
        $cfg = $null
        try { $cfg = ConvertFrom-Json -InputObject ([string]$ConfigText) -ErrorAction Stop } catch { $cfg = $null }
        if ($cfg -isnot [System.Management.Automation.PSCustomObject]) { $r.Why = 'localai-config.json could not be read'; return $r }
        $version = [string](Get-ReviewField -Object $cfg -Path 'ToolkitVersion')
        if ($version -match '^[0-9A-Za-z._-]{1,32}\z') { $r.Version = $version }
        # Only a full commit id counts: this value ends up in the address GitHub is asked about.
        $commit = ([string](Get-ReviewField -Object $cfg -Path 'ToolkitCommit')).Trim()
        if ($commit -match '^[0-9a-f]{40}\z') { $r.State = 'known'; $r.Commit = $commit.ToLowerInvariant(); return $r }
        $r.Why = 'localai-config.json names no commit: installed from a ZIP downloaded by hand, or GitHub could not name the commit at the time'
        return $r
    }

    function Get-ChangedFileGroup {
        # Where a changed file matters, from its path in the repository:
        #   'admin'    the installer, the module it loads and every toolkit script it can start (the
        #              installer runs as administrator); also a script or program in a new toolkit folder
        #   'toolkit'  the other files installed on this PC (stack, config, skills, VERSION, README)
        #   'other'    not installed: tests, docs, the backlog and the repository's other folders
        param([string]$Path)
        $p = $Path -replace '\\', '/'
        if (-not $p.StartsWith('local-llm/', [System.StringComparison]::Ordinal)) { return 'other' }
        $rest = $p.Substring(10)
        if ($rest -cmatch '^(tests|docs)/' -or $rest -ceq 'IMPROVEMENTS.md') { return 'other' }
        if ($rest -cmatch '^lib/' -or $rest -match '\.(ps1|psm1|cmd|bat|exe|msi|dll|vbs)\z') { return 'admin' }
        return 'toolkit'
    }

    function Get-ChangedFileReport {
        # The comparison's file list as lines to print, scripts that run as administrator first (the
        # installer, then its module, then the rest by name). Up to -MaxListed files are all named. A
        # longer list is summarised: every administrator script by name, then as many other toolkit
        # files as still fit, and the files that are not installed only counted.
        param($Files, [int]$MaxListed = 25)
        $words = @{ added = 'new'; removed = 'removed'; modified = 'changed'; changed = 'changed'; renamed = 'renamed'; copied = 'copied' }
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($f in @($Files)) {
            if ($null -eq $f) { continue }
            $name = [string](Get-ReviewField -Object $f -Path 'filename')
            $status = [string](Get-ReviewField -Object $f -Path 'status')
            $word = 'changed'; if ($words.ContainsKey($status)) { $word = $words[$status] }
            $shown = '(a file GitHub did not name)'; if ($name) { $shown = ConvertTo-ReviewText -Text $name -Max 110 }
            $old = [string](Get-ReviewField -Object $f -Path 'previous_filename')
            if ($old -and $status -eq 'renamed') { $shown = (ConvertTo-ReviewText -Text $old -Max 110) + ' -> ' + $shown }
            $rank = 2
            if ($name -ceq 'local-llm/Install-LocalAI.ps1') { $rank = 0 } elseif ($name -clike 'local-llm/lib/*') { $rank = 1 }
            $items.Add([pscustomobject]@{ Group = (Get-ChangedFileGroup -Path $name); Rank = $rank; Name = $name; Line = ('    {0,-8} {1}' -f $word, $shown) })
        }
        $admin = @($items | Where-Object { $_.Group -eq 'admin' } | Sort-Object { $_.Rank }, { $_.Name })
        $toolkit = @($items | Where-Object { $_.Group -eq 'toolkit' } | Sort-Object { $_.Name })
        $other = @($items | Where-Object { $_.Group -eq 'other' } | Sort-Object { $_.Name })
        $long = $items.Count -gt $MaxListed
        $lines = New-Object System.Collections.Generic.List[string]
        if ($admin.Count) {
            $lines.Add("  Scripts that run as administrator, or that the installer can start ($($admin.Count)):")
            foreach ($i in $admin) { $lines.Add($i.Line) }
        } else {
            $lines.Add('  Scripts that run as administrator, or that the installer can start: none of them differ.')
        }
        if ($toolkit.Count) {
            $room = $toolkit.Count
            if ($long) { $room = [Math]::Max(0, $MaxListed - $admin.Count) }
            if ($room -gt 0) {
                $lines.Add("  Other toolkit files installed on this PC ($($toolkit.Count)):")
                foreach ($i in @($toolkit | Select-Object -First $room)) { $lines.Add($i.Line) }
                if ($toolkit.Count -gt $room) { $lines.Add("    ... and $($toolkit.Count - $room) more, not listed here") }
            } else {
                $lines.Add("  Other toolkit files installed on this PC: $($toolkit.Count) file(s), not listed here")
            }
        }
        if ($other.Count -and $long) {
            $lines.Add("  Not installed on this PC (tests, notes, other folders): $($other.Count) file(s), not listed here")
        } elseif ($other.Count) {
            $lines.Add("  Not installed on this PC (tests, notes, other folders) ($($other.Count)):")
            foreach ($i in $other) { $lines.Add($i.Line) }
        }
        return [pscustomobject]@{ Total = $items.Count; Admin = $admin.Count; Long = $long; Lines = $lines.ToArray() }
    }

    function Get-UpdateReview {
        # What the update review shows and decides, from data that was already fetched:
        #   -Installed       Get-InstalledToolkit's answer for the AI folder -Root
        #   -Incoming        Get-IncomingCommit's answer for -Ref; $null when GitHub could not name
        #                    the commit (-IncomingError: why)
        #   -Compare         GitHub's comparison of the installed commit with the incoming one; $null
        #                    when there is none (-CompareError: why)
        #   -ReviewedCommit  LOCALAI_REVIEWED_COMMIT, the one way to skip the question
        # Returns Lines (Text, Color) to print; NeedsOk: wait for a typed OK before going on; and
        # Commit, Get and Url: what is downloaded. Url is built from the commit that Lines shows, so
        # what is read here is what is fetched and run. Nothing in the fetched data clears NeedsOk:
        # only a first install and a matching -ReviewedCommit do.
        param([string]$Repo, [string]$Root, [string]$Ref, $Installed, $Incoming, [string]$IncomingError, $Compare, [string]$CompareError, [string]$ReviewedCommit, [int]$MaxListed = 25)
        $lines = New-Object System.Collections.Generic.List[object]
        $say = { param($Text, $Color) $lines.Add([pscustomobject]@{ Text = [string]$Text; Color = [string]$Color }) }
        $pad = ' ' * 18
        $commit = ''; if ($Incoming) { $commit = [string]$Incoming.Sha }
        $get = $Ref; if ($commit) { $get = $commit }
        $url = "https://codeload.github.com/$Repo/zip/$get"
        $first = ($Installed.State -eq 'none')
        $kind = 'update'
        if ($first) {
            $kind = 'first'
            & $say "First install: nothing is installed in $Root yet, so there is nothing to compare." 'Cyan'
        } else {
            & $say "Update review: Local AI is already installed in $Root." 'Cyan'
            $version = 'version unknown'; if ($Installed.Version) { $version = "version $($Installed.Version)" }
            if ($Installed.State -eq 'known') {
                & $say "  Installed now : $version, commit $($Installed.Commit)" 'Gray'
                $base = Get-CommitSummary -Commit (Get-ReviewField -Object $Compare -Path 'base_commit')
                if ($base -and $base.Sha -eq $Installed.Commit) { & $say ($pad + ($base.Date + '  ' + $base.Subject).Trim()) 'Gray' }
            } else {
                & $say "  Installed now : $version, commit not recorded" 'Gray'
            }
        }
        if ($commit) {
            & $say "  To install    : commit $commit (from '$Ref')" 'Gray'
            $described = ($Incoming.Date + '  ' + $Incoming.Subject).Trim()
            if ($described) { & $say ($pad + $described) 'Gray' }
            else { & $say ($pad + "GitHub could not describe it ($(ConvertTo-ReviewText -Text $IncomingError -Max 160 -AllowUnicode)): no date or subject line.") 'Yellow' }
        } else {
            & $say "  To install    : whatever '$Ref' is on GitHub when the download starts." 'Yellow'
            & $say ($pad + "GitHub could not name its commit ($(ConvertTo-ReviewText -Text $IncomingError -Max 160 -AllowUnicode)), so it cannot be shown or pinned.") 'Yellow'
        }
        if ($first) { return [pscustomobject]@{ Kind = $kind; NeedsOk = $false; Lines = $lines.ToArray(); Commit = $commit; Get = $get; Url = $url } }

        $link = ''
        if ($Installed.State -ne 'known') {
            $kind = 'unknown'
            & $say "  The changes cannot be listed: it is not known which commit is installed ($($Installed.Why))." 'Yellow'
            if ($commit) { $link = "  This commit on GitHub: https://github.com/$Repo/commit/$commit" }
        } elseif (-not $commit) {
            $kind = 'unpinned'
            & $say '  The changes cannot be listed without the commit that would be installed.' 'Yellow'
        } elseif ($Installed.Commit -eq $commit) {
            $kind = 'repair'
            & $say '  That is the commit already installed: a repair run of the same version. It is downloaded again and the installer re-applies it.' 'Gray'
        } else {
            $link = "  Full comparison: https://github.com/$Repo/compare/$($Installed.Commit)...$commit"
            $status = [string](Get-ReviewField -Object $Compare -Path 'status')
            $files = Get-ReviewField -Object $Compare -Path 'files'
            $why = ConvertTo-ReviewText -Text $CompareError -Max 200 -AllowUnicode
            if (-not $why -and $null -eq $Compare) { $why = 'GitHub gave no answer' }
            if (-not $why -and (@('ahead', 'behind', 'diverged', 'identical') -notcontains $status -or $null -eq $files)) { $why = 'its answer could not be read (too large, or not a comparison)' }
            if ($why) {
                $kind = 'nocompare'
                & $say "  The list of changed files could not be fetched from GitHub: $why" 'Yellow'
            } elseif ($status -eq 'behind') {
                $kind = 'older'
                & $say "  This commit is OLDER than the installed one ($(ConvertTo-ReviewCount -Value (Get-ReviewField -Object $Compare -Path 'behind_by')) commit(s) back): a step back, not an update." 'Yellow'
                & $say '  GitHub lists no files in that direction; the link below shows what differs.' 'Yellow'
                $link = "  Full comparison: https://github.com/$Repo/compare/$commit...$($Installed.Commit)"
            } else {
                $ahead = ConvertTo-ReviewCount -Value (Get-ReviewField -Object $Compare -Path 'ahead_by')
                if ($status -eq 'diverged') {
                    $kind = 'diverged'
                    $behind = ConvertTo-ReviewCount -Value (Get-ReviewField -Object $Compare -Path 'behind_by')
                    & $say "  This commit does not continue from the installed one ($ahead commit(s) ahead of their common ancestor, $behind behind): another branch, or the branch was rewritten on GitHub." 'Yellow'
                    & $say '  The files below changed since that ancestor; what the installed commit added after it would be gone.' 'Yellow'
                }
                $report = Get-ChangedFileReport -Files $files -MaxListed $MaxListed
                $note = ''; if ($report.Long) { $note = ' (a long list: summarised)' }
                & $say "  Changes       : $ahead commit(s), $($report.Total) file(s) differ$note" 'Gray'
                foreach ($l in $report.Lines) { & $say $l 'Gray' }
                if ($report.Total -ge 300) { & $say '  GitHub lists at most 300 files: more than these may differ.' 'Yellow' }
            }
        }
        if ($link) { & $say $link 'Gray' }

        $needsOk = $true
        $named = $ReviewedCommit.Trim()
        if ($named) {
            if ($commit -and $named -eq $commit) {
                $needsOk = $false
                & $say '  Not asking: LOCALAI_REVIEWED_COMMIT names exactly this commit.' 'Yellow'
            } else {
                & $say '  LOCALAI_REVIEWED_COMMIT is set, but not to the full id of this commit: it does not count here.' 'Yellow'
            }
        }
        return [pscustomobject]@{ Kind = $kind; NeedsOk = $needsOk; Lines = $lines.ToArray(); Commit = $commit; Get = $get; Url = $url }
    }

    function Test-UpdateAnswer {
        # Only the typed word OK (any case, spaces around it ignored) is consent. Enter alone, y, yes
        # or no answer at all (no console, an error while reading) is not.
        param($Answer)
        if ($Answer -isnot [string]) { return $false }
        return ($Answer.Trim() -eq 'ok')
    }

    function Get-UpdateConsent {
        # Whether the installer may be started after the review: Go, and when not, Why.
        #   nothing to ask (-Review says so: a first install, the reviewed commit)   go on
        #   the console window's input is redirected: nobody can type there          stop, not asked
        #   -ReadAnswer (asks, returns what was typed) fails                          stop: an error is not consent
        #   anything typed but OK                                                     stop
        # A piped-in "OK" is therefore no answer. Hosts without a console window (ISE, a remote
        # session, an editor) ask through their own window. A review that cannot be read is asked about.
        param($Review, [string]$HostName, [bool]$InputRedirected, [scriptblock]$ReadAnswer)
        $unattended = 'For a run nobody watches, set LOCALAI_REVIEWED_COMMIT to the full id of the commit you reviewed.'
        if ($Review -and $Review.NeedsOk -is [bool] -and -not $Review.NeedsOk) { return [pscustomobject]@{ Go = $true; Why = '' } }
        if ($HostName -eq 'ConsoleHost' -and $InputRedirected) {
            return [pscustomobject]@{ Go = $false; Why = "there is no keyboard to type OK on (this window's input comes from a file or another program). $unattended" }
        }
        $answer = $null
        try { $answer = & $ReadAnswer }
        catch { return [pscustomobject]@{ Go = $false; Why = "the answer could not be read ($(ConvertTo-ReviewText -Text $_.Exception.Message -Max 200 -AllowUnicode)). $unattended" } }
        if (Test-UpdateAnswer -Answer $answer) { return [pscustomobject]@{ Go = $true; Why = '' } }
        return [pscustomobject]@{ Go = $false; Why = 'OK was not typed.' }
    }

    # ---- Bootstrap -------------------------------------------------------------------------------

    $ref = $env:LOCALAI_REF
    if (-not $ref) { $ref = 'main' }
    # LOCALAI_ROOT: the install's AI folder (set by the Start-menu 'Update toolkit' shortcut).
    $root = $env:LOCALAI_ROOT
    if (-not $root) { $root = 'C:\AI' }
    $repo = 'MpLLC303/ComfyUi-Optimization'
    # Unpacked in the user's temp folder; the installer copies itself into AI\Scripts (and, before a
    # reboot, into Program Files\LocalAI for the resume).
    $dest = Join-Path $env:TEMP 'LocalAI-Installer'
    $zip = Join-Path $env:TEMP 'localai-installer.zip'
    # The ref is resolved to one commit first: what is downloaded is exactly what is shown here, and a
    # re-run after a failure (or the resume after a reboot) installs the same code even if the branch
    # moved meanwhile. Without GitHub's API (rate limit, proxy) the ref itself is used.
    $lookup = $null; $incomingError = ''
    try { $lookup = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/$ref" -UseBasicParsing -Headers @{ Accept = 'application/vnd.github+json' } }
    catch { $incomingError = $_.Exception.Message; if (-not $incomingError) { $incomingError = 'no answer' } }
    if (-not $incomingError -and $null -eq (Get-CommitSummary -Commit $lookup)) { $incomingError = 'its answer holds no commit id' }
    $incoming = Get-IncomingCommit -Ref $ref -Answer $lookup

    # What is installed now. Trouble reading it means "an install whose commit is unknown", never
    # "nothing installed": only a folder without a trace of an install goes on without the question.
    $configText = $null; $otherSigns = $false
    try {
        $otherSigns = (Test-Path -LiteralPath ([System.IO.Path]::Combine($root, 'install-state.json'))) -or (Test-Path -LiteralPath ([System.IO.Path]::Combine($root, 'Scripts', 'Install-LocalAI.ps1')))
        $configFile = [System.IO.Path]::Combine($root, 'localai-config.json')
        if (Test-Path -LiteralPath $configFile) { $configText = [System.IO.File]::ReadAllText($configFile) }
    } catch { $configText = '' }
    $installed = Get-InstalledToolkit -ConfigText $configText -OtherSigns $otherSigns
    # The files that differ between the two commits (GitHub's compare API; the repository is public).
    $compare = $null; $compareError = ''
    if ($installed.State -eq 'known' -and $incoming -and $installed.Commit -ne $incoming.Sha) {
        try { $compare = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/compare/$($installed.Commit)...$($incoming.Sha)" -UseBasicParsing -Headers @{ Accept = 'application/vnd.github+json' } -TimeoutSec 60 }
        catch { $compareError = $_.Exception.Message; if (-not $compareError) { $compareError = 'no answer' } }
    }
    $review = Get-UpdateReview -Repo $repo -Root $root -Ref $ref -Installed $installed -Incoming $incoming -IncomingError $incomingError -Compare $compare -CompareError $compareError -ReviewedCommit $env:LOCALAI_REVIEWED_COMMIT
    Write-Host ''
    foreach ($line in $review.Lines) { Write-Host -Object $line.Text -ForegroundColor $line.Color }
    # Only an OK typed after the review goes on: no keyboard, no answer or an error is not consent.
    $redirected = $true
    try { $redirected = [bool][Console]::IsInputRedirected } catch { $redirected = $true }
    $consent = Get-UpdateConsent -Review $review -HostName $Host.Name -InputRedirected $redirected -ReadAnswer {
        # Keys typed or pasted before the review was on screen do not answer it.
        try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { $null = $_ }
        Read-Host -Prompt 'Type OK and press Enter to download and install this; anything else stops here'
    }
    if (-not $consent.Go) {
        Write-Host "Stopped: $($consent.Why)" -ForegroundColor Yellow
        Write-Host 'Nothing was downloaded or changed: your Local AI keeps working as it is.' -ForegroundColor Yellow
        return
    }
    # From here on only what the review showed: its commit, and the address built from it.
    $commit = $review.Commit
    # zip/<ref> accepts a branch, a tag or a commit, so a reviewed version can be pinned.
    $url = $review.Url

    Write-Host "Downloading installer ($ref$(if ($commit) { ', commit ' + $commit.Substring(0, 7) }))..." -ForegroundColor Cyan
    try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing }
    catch {
        Write-Host "The download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Nothing was changed: your Local AI keeps working as it is. Check the internet connection and run the command again; to repair the installed copy instead, double-click $root\Scripts\Install-LocalAI.cmd." -ForegroundColor Yellow
        return
    }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    Remove-Item -LiteralPath $zip -Force

    $top = Get-ChildItem -LiteralPath $dest -Directory | Select-Object -First 1
    $installer = Join-Path $top.FullName 'local-llm\Install-LocalAI.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found in the downloaded archive ($installer)." }
    Get-ChildItem -LiteralPath $top.FullName -Recurse -File | Unblock-File
    # Recorded by the installer (localai-config.json, diagnostics), so it is known what code runs.
    if ($commit) { [System.IO.File]::WriteAllText((Join-Path (Split-Path -Parent $installer) 'COMMIT'), $commit) }
    $version = ''; $vf = Join-Path (Split-Path -Parent $installer) 'VERSION'
    if (Test-Path -LiteralPath $vf) { $version = ([System.IO.File]::ReadAllText($vf)).Trim() }
    Write-Host "Installing Local AI toolkit $version$(if ($commit) { ' (commit ' + $commit.Substring(0, 7) + ')' }). Windows asks for administrator rights next." -ForegroundColor Cyan

    # Options for the installer, e.g. -OfficialModels none: plain words only (no quotes or scripts).
    $extra = @()
    if ($env:LOCALAI_ARGS) { $extra = @($env:LOCALAI_ARGS -split '\s+' | Where-Object { $_ }) }
    $bad = @($extra | Where-Object { $_ -notmatch '^[A-Za-z0-9_:,.\\-]+$' })
    if ($bad.Count) { Write-Host "LOCALAI_ARGS may hold only plain options such as -OfficialModels none; not used: $($bad -join ' ')" -ForegroundColor Red; return }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -AIRoot $root @extra
    $code = $LASTEXITCODE
    Write-Host ''
    if ($code -eq 10) { Write-Host 'The installer continues in the Administrator window that opened.' -ForegroundColor Cyan }
    elseif ($code -eq 1223) { Write-Host 'Administrator rights were declined; run the command again and click Yes.' -ForegroundColor Red }
    elseif ($code -eq 3010) { Write-Host 'A restart is needed; the installer resumes after you sign in again (click Yes when Windows asks).' -ForegroundColor Cyan }
    elseif ($code -ne 0) { Write-Host "The installer stopped with an error (code $code); see the messages above." -ForegroundColor Red }
}
