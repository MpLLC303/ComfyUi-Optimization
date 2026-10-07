# Bootstrap: downloads the newest toolkit as a ZIP and starts Install-LocalAI.ps1 from it. Use it for
# the first install and for every update (Start menu > Local AI > Update toolkit runs this file).
# Paste into a normal (non-admin) PowerShell window:
#
#   $env:LOCALAI_REF = 'main'
#   [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
#   irm https://raw.githubusercontent.com/MpLLC303/ComfyUi-Optimization/refs/heads/main/local-llm/Get-LocalAI.ps1 | iex
#
# LOCALAI_REF selects the branch, tag or commit to install from (letters, digits and . _ / - only).
# LOCALAI_ARGS passes installer options, e.g. $env:LOCALAI_ARGS = '-OfficialModels none'. LOCALAI_ROOT
# names the AI folder when it is not C:\AI (the Start-menu entry sets it). Everything runs inside a
# script block so the settings below do not leak into your PowerShell session.
#
# Update review: when Local AI is already installed, nothing is downloaded until you have seen what is
# installed now, the commit about to be installed (id, date, subject line) and the files that differ
# between the two, and have typed OK at the keyboard (an OK piped in, or pasted ahead of the question,
# does not count). A first install has nothing to compare and is not asked. An install that is found
# on this PC but not in the AI folder named here is asked about as well.
# When GitHub's API does not answer (its hourly limit, a proxy), the commit is read from its page on
# github.com instead, which the API does not serve (whether that page has a limit of its own is not
# known here): it is shown and asked about as usual, and the file list is said to be missing. Only an
# update whose commit neither of the two can name (offline, or both refuse) is not offered at all:
# nothing is shown as agreed that could not be shown. Try again later, or set LOCALAI_REF to a full
# commit id.
# The one way to skip the question, for a run nobody watches: name the commit you reviewed, in full:
#
#   $env:LOCALAI_REVIEWED_COMMIT = '<its 40-character id>'
#
# It counts for exactly that commit. When the branch has moved on, the question is asked as usual, and
# without a typed OK nothing is installed.
#
# What the review does not cover:
# - It is only as trustworthy as the copy of this file that runs it. Start menu > Local AI > Update
#   toolkit runs the copy already on this PC. The command above fetches this file from the main branch
#   and runs it unseen: whoever can change that branch can change the review with it. To review that
#   path too, replace refs/heads/main in its address with the id of a commit you have read.
# - It lists the names of the files that differ, not what changed inside them (it prints the address
#   of the full comparison). GitHub lists at most 300 files; a longer list is said to be cut off.
# - It is no defence against a program that already runs under your Windows account: the installed
#   copy of this file sits in a folder such a program can write to.
# - A commit id in LOCALAI_REF is not checked to be on a branch of this repository (GitHub also
#   answers at this address for commits that exist only in a fork); the review says so.
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
            # An answer read by ConvertFrom-ReviewJson's second reader is made of dictionaries.
            if ($o -is [System.Collections.IDictionary]) {
                $there = $false
                foreach ($key in $o.Keys) { if ($key -ceq $name) { $there = $true; break } }
                if (-not $there) { return $null }
                $o = $o[$name]
                continue
            }
            $prop = $o.PSObject.Properties[$name]
            if ($null -eq $prop) { return $null }
            $o = $prop.Value
        }
        return , $o
    }

    function ConvertTo-ReviewBody {
        # The body of a web answer as text: Invoke-WebRequest hands it over as text or, for some
        # content types on Windows PowerShell 5.1, as bytes. Anything else is no text.
        param($Content)
        if ($Content -is [string]) { return $Content }
        if ($Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($Content) }
        return ''
    }

    function ConvertFrom-ReviewJson {
        # GitHub's answer (JSON text) as an object; $null when it is not JSON. A comparison carries a
        # patch for each of up to 300 files and runs to millions of characters. Invoke-RestMethod of
        # Windows PowerShell 5.1 hands an answer of more than about 2 million back unread, so the text
        # is fetched as it is and read here. Should ConvertFrom-Json of an older 5.1 refuse the
        # length as well, .NET's reader takes it without a limit; that one yields dictionaries and
        # arrays (Get-ReviewField reads both).
        param([string]$Text)
        if (-not $Text) { return $null }
        try { return (ConvertFrom-Json -InputObject $Text -ErrorAction Stop) } catch { $null = $_ }
        if ($PSVersionTable.PSVersion.Major -ge 6) { return $null }
        try {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $reader = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $reader.MaxJsonLength = [int]::MaxValue
            return , $reader.DeserializeObject($Text)
        } catch { return $null }
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

    function Test-ToolkitRef {
        # Whether -Ref (LOCALAI_REF) may go into the addresses GitHub is asked for: the name of a
        # branch, a tag or a commit, made of letters, digits and . _ / - only. No '..', no '.' or
        # empty part between slashes: .NET folds such parts away, and the address would then name
        # another repository than the one the review shows.
        param([string]$Ref)
        if ($Ref.Length -gt 200 -or $Ref -notmatch '^[A-Za-z0-9._/-]+\z' -or $Ref.Contains('..')) { return $false }
        foreach ($part in $Ref.Split('/')) { if ($part -eq '' -or $part -eq '.') { return $false } }
        return $true
    }

    function Test-DirectCommitRef {
        # Whether -Ref names a commit by itself instead of through a branch or tag of this
        # repository: a commit id (short or full), a pull request's ref or another refs/ name. GitHub
        # answers for such a commit also when it exists only in a fork, so the review says that it
        # was not checked to be on a branch of this repository.
        param([string]$Ref)
        # From 4 characters: the shortest id git itself takes. A branch named like one ('beef') gets
        # the remark too, which costs a line and nothing else.
        if ($Ref -match '^[0-9a-f]{4,40}\z') { return $true }
        if ($Ref -match '(^|/)pull/') { return $true }
        return ($Ref -match '^refs/' -and $Ref -notmatch '^refs/(heads|tags)/')
    }

    function Get-PatchCommit {
        # Id, date and subject line from the head of a commit's page in patch form
        # (github.com/<repository>/commit/<ref>.patch): 'From <id> ...', then 'Date:' and 'Subject:'
        # (with the lines a long subject is folded onto) before the first empty line. $null when the
        # text does not start with a full commit id.
        # The date is the day its author wrote down, not turned into UTC.
        param([string]$Text)
        $head = $Text
        if ($head.Length -gt 8000) { $head = $head.Substring(0, 8000) }
        $lines = @($head -split "`r?`n")
        if ($lines[0] -notmatch '^From ([0-9a-f]{40}) ') { return $null }
        $sha = $Matches[1].ToLowerInvariant()
        $months = @{ Jan = '01'; Feb = '02'; Mar = '03'; Apr = '04'; May = '05'; Jun = '06'; Jul = '07'; Aug = '08'; Sep = '09'; Oct = '10'; Nov = '11'; Dec = '12' }
        $date = ''; $subject = ''
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -eq '') { break }
            if (-not $date -and $line -match '^Date:\s+(?:[A-Za-z]{3},\s+)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s') {
                $day = [int]$Matches[1]; $month = $Matches[2]; $year = $Matches[3]
                if ($months.ContainsKey($month) -and $day -ge 1 -and $day -le 31) { $date = $year + '-' + $months[$month] + '-' + $day.ToString('00') }
            } elseif (-not $subject -and $line -match '^Subject:\s*(.*)\z') {
                $subject = $Matches[1]
                # A long subject line is folded: its continuation lines start with a space or a tab.
                while ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^[ \t]+(\S.*)\z') { $i++; $subject += ' ' + $Matches[1] }
                $subject = $subject -replace '^\[PATCH[^\]]*\]\s*', ''
            }
        }
        return [pscustomobject]@{ Sha = $sha; Date = $date; Subject = (ConvertTo-ReviewText -Text $subject -Max 100) }
    }

    function Get-IncomingCommit {
        # The commit -Ref points to: the answer of GitHub's API when it names one. When it does not
        # (its hourly limit, a proxy): the commit's page in patch form, -PatchText (Get-PatchCommit).
        # When that names none either, a -Ref that is itself a full commit id (it pins the download by
        # itself; date and subject line stay empty). Otherwise $null: a branch or tag GitHub does not
        # answer for cannot be pinned. A page that names another commit than a full id in -Ref is not
        # used: the id in -Ref is the one asked for.
        param([string]$Ref, $Answer, [string]$PatchText)
        $summary = Get-CommitSummary -Commit $Answer
        if ($summary) { return $summary }
        $full = ($Ref -match '^[0-9a-f]{40}\z')
        $page = Get-PatchCommit -Text $PatchText
        if ($page -and (-not $full -or $page.Sha -eq $Ref.ToLowerInvariant())) { return $page }
        if ($full) { return [pscustomobject]@{ Sha = $Ref.ToLowerInvariant(); Date = ''; Subject = '' } }
        return $null
    }

    function Get-InstalledToolkit {
        # What the install in the AI folder says about itself: Install-LocalAI.ps1 records
        # ToolkitVersion and ToolkitCommit in localai-config.json near its end.
        #   State 'none'     nothing is installed: a first install
        #   State 'known'    an install, and the commit it came from
        #   State 'unknown'  an install, but not which commit (Why: what exactly is missing)
        # -ConfigText: the text of localai-config.json, $null when there is no such file.
        # -OtherSigns: the folder holds other traces of an install (install-state.json, the Scripts
        # folder). Whatever cannot be read is 'unknown', never 'none'.
        # -StartMenu: the installer's Start-menu folder exists. It does not depend on the AI folder,
        # so with nothing in the AI folder it means an install somewhere else (Elsewhere): the AI
        # folder named here is the wrong one, and that is not a first install either.
        param($ConfigText, [bool]$OtherSigns, [bool]$StartMenu)
        $r = [pscustomobject]@{ State = 'none'; Version = ''; Commit = ''; Why = ''; Elsewhere = $false }
        if ($null -eq $ConfigText) {
            if ($OtherSigns) { $r.State = 'unknown'; $r.Why = 'there is no localai-config.json: the install did not finish' }
            elseif ($StartMenu) { $r.State = 'unknown'; $r.Elsewhere = $true; $r.Why = 'the install is in another folder, so its localai-config.json was not read' }
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

    function Test-PlainRepoPath {
        # Whether Windows stores a file of the archive under exactly the path git gives it. Not so
        # for: no name at all; a '.' or '..' part, an empty part, or a part that ends in a dot or a
        # space (Windows drops those); a character outside printable ASCII; one of : * ? " < > |
        # (a colon names a stream of another file); '~' and a digit (a short 8.3 name of another
        # file). Git takes such a path for a file of its own; on this PC it can be, or replace,
        # another one, the installer included.
        param([string]$Path)
        $p = $Path -replace '\\', '/'
        if ($p -eq '' -or $p -match '[^\x20-\x7E]' -or $p -match '[:*?"<>|]' -or $p -match '~[0-9]') { return $false }
        foreach ($part in $p.Split('/')) { if ($part -eq '' -or $part -match '[. ]\z') { return $false } }
        return $true
    }

    function Get-ChangedFileGroup {
        # Where a changed file matters, from its path in the repository as Windows will store it
        # (the archive is unpacked on this PC: capitals do not tell two names apart, '\' is '/'):
        #   'admin'    the installer, the module it loads and every toolkit script it can start (the
        #              installer runs as administrator); also a script or program in a new toolkit
        #              folder, and every path Windows may store elsewhere than written (Test-PlainRepoPath)
        #   'toolkit'  the other files installed on this PC (stack, config, skills, VERSION, README)
        #   'other'    not installed: tests, docs, the backlog and the repository's other folders
        # Only the exact names tests, docs and IMPROVEMENTS.md count as not installed.
        param([string]$Path)
        if (-not (Test-PlainRepoPath -Path $Path)) { return 'admin' }
        $p = $Path -replace '\\', '/'
        if (-not $p.StartsWith('local-llm/', [System.StringComparison]::OrdinalIgnoreCase)) { return 'other' }
        $rest = $p.Substring(10)
        if ($rest -cmatch '^(tests|docs)/' -or $rest -ceq 'IMPROVEMENTS.md') { return 'other' }
        if ($rest -match '^lib/' -or $rest -match '\.(ps1|psm1|cmd|bat|exe|msi|dll|vbs)\z') { return 'admin' }
        return 'toolkit'
    }

    function Get-ChangedFileReport {
        # The comparison's file list as lines (Text, Color) to print. Every file that is installed on
        # this PC is named, however long the list: first the scripts that run as administrator (the
        # installer, then its module, then the rest by name), then the other toolkit files (the stack
        # and the config first: images, published ports and mounted folders are set there). A list
        # of more than -MaxListed files is summarised: the files that are not installed are only
        # counted. A renamed file counts for the stricter of its two names.
        # GitHub sends at most -ListLimit files. A list of that length is called cut off (Cut), above
        # the list, and is never said to hold no administrator script: that is then not known.
        param($Files, [int]$MaxListed = 25, [int]$ListLimit = 300)
        $words = @{ added = 'new'; removed = 'removed'; modified = 'changed'; changed = 'changed'; renamed = 'renamed'; copied = 'copied' }
        $strictness = @{ admin = 0; toolkit = 1; other = 2 }
        $rankOf = {
            # Capitals do not matter here either: -eq and -like read names as Windows does.
            param([string]$Path)
            $p = $Path -replace '\\', '/'
            if ($p -eq 'local-llm/Install-LocalAI.ps1') { return 0 }
            if ($p -like 'local-llm/lib/*' -or $p -like 'local-llm/stack/*') { return 1 }
            if ($p -like 'local-llm/config/*') { return 2 }
            return 3
        }
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($f in @($Files)) {
            if ($null -eq $f) { continue }
            $name = [string](Get-ReviewField -Object $f -Path 'filename')
            $status = [string](Get-ReviewField -Object $f -Path 'status')
            $word = 'changed'; if ($words.ContainsKey($status)) { $word = $words[$status] }
            $shown = '(a file GitHub did not name)'; if ($name) { $shown = ConvertTo-ReviewText -Text $name -Max 110 }
            $group = Get-ChangedFileGroup -Path $name
            $rank = & $rankOf $name
            $plain = (-not $name) -or (Test-PlainRepoPath -Path $name)
            $old = [string](Get-ReviewField -Object $f -Path 'previous_filename')
            if ($old) {
                # Moved or renamed: the name it had counts as much as the name it has now.
                $shown = (ConvertTo-ReviewText -Text $old -Max 110) + ' -> ' + $shown
                $oldGroup = Get-ChangedFileGroup -Path $old
                if ($strictness[$oldGroup] -lt $strictness[$group]) { $group = $oldGroup }
                $oldRank = & $rankOf $old
                if ($oldRank -lt $rank) { $rank = $oldRank }
                if (-not (Test-PlainRepoPath -Path $old)) { $plain = $false }
            }
            if (-not $plain) { $shown += '  (unusual name: Windows may store it somewhere else)' }
            $items.Add([pscustomobject]@{ Group = $group; Rank = $rank; Name = $name; Line = ('    {0,-8} {1}' -f $word, $shown) })
        }
        $admin = @($items | Where-Object { $_.Group -eq 'admin' } | Sort-Object { $_.Rank }, { $_.Name })
        $toolkit = @($items | Where-Object { $_.Group -eq 'toolkit' } | Sort-Object { $_.Rank }, { $_.Name })
        $other = @($items | Where-Object { $_.Group -eq 'other' } | Sort-Object { $_.Name })
        $long = ($items.Count -gt $MaxListed -and $other.Count -gt 0)
        $cut = (@($Files).Count -ge $ListLimit)
        $lines = New-Object System.Collections.Generic.List[object]
        $say = { param($Text, $Color) $lines.Add([pscustomobject]@{ Text = [string]$Text; Color = [string]$Color }) }
        $title = '  Scripts that run as administrator, or that the installer can start'
        if ($cut) { & $say "  GitHub lists at most $ListLimit files and this list is that long: it is cut off, and more files may differ than are shown here." 'Yellow' }
        if ($admin.Count -and $cut) {
            & $say "$title ($($admin.Count) in the part GitHub listed; more may be among the files it did not list):" 'Yellow'
        } elseif ($admin.Count) {
            & $say "$title ($($admin.Count)):" 'Gray'
        } elseif ($cut) {
            & $say "${title}: not known. GitHub's list stops at $ListLimit files, and administrator scripts may be among those not listed." 'Yellow'
        } else {
            & $say "${title}: none of them differ." 'Gray'
        }
        foreach ($i in $admin) { & $say $i.Line 'Gray' }
        if ($toolkit.Count) {
            & $say "  Other toolkit files installed on this PC ($($toolkit.Count)):" 'Gray'
            foreach ($i in $toolkit) { & $say $i.Line 'Gray' }
        }
        if ($other.Count -and $long) {
            & $say "  Not installed on this PC (tests, notes, other folders): $($other.Count) file(s), not listed here" 'Gray'
        } elseif ($other.Count) {
            & $say "  Not installed on this PC (tests, notes, other folders) ($($other.Count)):" 'Gray'
            foreach ($i in $other) { & $say $i.Line 'Gray' }
        }
        return [pscustomobject]@{ Total = $items.Count; Admin = $admin.Count; Long = $long; Cut = $cut; Lines = $lines.ToArray() }
    }

    function Get-UpdateReview {
        # What the update review shows and decides, from data that was already fetched:
        #   -Installed       Get-InstalledToolkit's answer for the AI folder -Root
        #   -Incoming        Get-IncomingCommit's answer for -Ref; $null when GitHub could not name
        #                    the commit. -IncomingError: why GitHub's API did not name it (the commit
        #                    may then still be known: from its page, or from a full id in -Ref)
        #   -Compare         GitHub's comparison of the installed commit with the incoming one; $null
        #                    when there is none (-CompareError: why)
        #   -ReviewedCommit  LOCALAI_REVIEWED_COMMIT, the one way to skip the question
        # Returns Lines (Text, Color) to print; NeedsOk: wait for a typed OK before going on; Stop:
        # when not empty, why this run ends here without a question; and Commit, Get and Url: what is
        # downloaded. Url is built from the commit that Lines shows, so what is read here is what is
        # fetched and run. An update whose commit cannot be named is not offered (Stop, no Url):
        # there is nothing to show, so there is nothing to agree to. Only a first install goes on
        # with the ref as it is. Nothing in the fetched data clears NeedsOk: only a first install and
        # a matching -ReviewedCommit do, and nothing clears Stop.
        param([string]$Repo, [string]$Root, [string]$Ref, $Installed, $Incoming, [string]$IncomingError, $Compare, [string]$CompareError, [string]$ReviewedCommit, [int]$MaxListed = 25)
        $lines = New-Object System.Collections.Generic.List[object]
        $say = { param($Text, $Color) $lines.Add([pscustomobject]@{ Text = [string]$Text; Color = [string]$Color }) }
        $pad = ' ' * 18
        $commit = ''; if ($Incoming) { $commit = [string]$Incoming.Sha }
        $refShown = ConvertTo-ReviewText -Text $Ref -Max 80
        $get = $Ref; if ($commit) { $get = $commit }
        $url = "https://codeload.github.com/$Repo/zip/$get"
        $first = ($Installed.State -eq 'none')
        $kind = 'update'
        if ($first) {
            $kind = 'first'
            & $say "First install: nothing is installed in $Root yet, so there is nothing to compare." 'Cyan'
        } elseif ($Installed.Elsewhere) {
            & $say "Update review: Local AI is installed on this PC (its Start-menu folder is there), but not in $Root." 'Yellow'
            & $say '  If it lives in another folder: type anything but OK, set LOCALAI_ROOT to that folder and run this again.' 'Yellow'
            & $say '  Start menu > Local AI > Update toolkit names the folder by itself.' 'Yellow'
            & $say "  Installed now : not in $Root" 'Gray'
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
        $notNamed = ConvertTo-ReviewText -Text $IncomingError -Max 160 -AllowUnicode
        if ($commit) {
            & $say "  To install    : commit $commit (from '$refShown')" 'Gray'
            $described = ($Incoming.Date + '  ' + $Incoming.Subject).Trim()
            if ($described) {
                & $say ($pad + $described) 'Gray'
                if ($notNamed) { & $say ($pad + "GitHub's API did not answer ($notNamed): this was read from the commit's page on github.com instead.") 'Yellow' }
            } else { & $say ($pad + "GitHub could not describe it ($notNamed): no date or subject line.") 'Yellow' }
            if (Test-DirectCommitRef -Ref $Ref) { & $say ($pad + "Not checked to be on a branch of this repository: '$refShown' names a commit directly, and GitHub also answers here for commits that exist only in a fork.") 'Yellow' }
        } elseif ($first) {
            & $say "  To install    : whatever '$refShown' is on GitHub when the download starts." 'Yellow'
            & $say ($pad + "GitHub could not name its commit ($notNamed), so it cannot be shown or pinned.") 'Yellow'
        } else {
            & $say "  To install    : not known. GitHub could not name the commit '$refShown' stands for ($notNamed)." 'Yellow'
            & $say ($pad + 'An update is installed only after its commit was shown here. Try again later, or set LOCALAI_REF to the full 40-character id of the commit to install.') 'Yellow'
        }
        if ($first) { return [pscustomobject]@{ Kind = $kind; NeedsOk = $false; Stop = ''; Lines = $lines.ToArray(); Commit = $commit; Get = $get; Url = $url } }
        if (-not $commit) {
            # No question: an OK here would be an OK to code nobody has seen, and LOCALAI_REVIEWED_COMMIT
            # has no commit to be compared with. Nothing is left to download either.
            $stop = 'the commit to install could not be named, so there is nothing to show and nothing to agree to. Try again later, or set LOCALAI_REF to the full id of the commit to install.'
            return [pscustomobject]@{ Kind = 'unpinned'; NeedsOk = $true; Stop = $stop; Lines = $lines.ToArray(); Commit = ''; Get = ''; Url = '' }
        }

        $link = ''
        if ($Installed.State -ne 'known') {
            $kind = 'unknown'
            & $say "  The changes cannot be listed: it is not known which commit is installed ($($Installed.Why))." 'Yellow'
            $link = "  This commit on GitHub: https://github.com/$Repo/commit/$commit"
        } elseif ($Installed.Commit -eq $commit) {
            $kind = 'repair'
            & $say '  That is the commit already installed: a repair run of the same version. It is downloaded again and the installer re-applies it.' 'Gray'
        } else {
            $link = "  Full comparison: https://github.com/$Repo/compare/$($Installed.Commit)...$commit"
            $status = [string](Get-ReviewField -Object $Compare -Path 'status')
            $files = Get-ReviewField -Object $Compare -Path 'files'
            $why = ConvertTo-ReviewText -Text $CompareError -Max 200 -AllowUnicode
            if (-not $why -and $null -eq $Compare) { $why = 'GitHub gave no answer' }
            if (-not $why -and (@('ahead', 'behind', 'diverged', 'identical') -notcontains $status -or $null -eq $files)) { $why = 'its answer could not be read (not a comparison)' }
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
                $count = [string]$report.Total; if ($report.Cut) { $count = "$($report.Total) or more" }
                $note = ''; if ($report.Long) { $note = ' (a long list: the files that are not installed are only counted)' }
                & $say "  Changes       : $ahead commit(s), $count file(s) differ$note" 'Gray'
                foreach ($l in $report.Lines) { & $say $l.Text $l.Color }
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
        return [pscustomobject]@{ Kind = $kind; NeedsOk = $needsOk; Stop = ''; Lines = $lines.ToArray(); Commit = $commit; Get = $get; Url = $url }
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
        #   the review says Stop (an update whose commit could not be named)         stop, not asked
        #   nothing to ask (-Review says so: a first install, the reviewed commit)   go on
        #   the console window's input is redirected: nobody can type there          stop, not asked
        #   -ReadAnswer (asks, returns what was typed) fails                          stop: an error is not consent
        #   anything typed but OK                                                     stop
        # A piped-in "OK" is therefore no answer. Hosts without a console window (ISE, a remote
        # session, an editor) ask through their own window. A review that cannot be read is asked about.
        param($Review, [string]$HostName, [bool]$InputRedirected, [scriptblock]$ReadAnswer)
        $unattended = 'For a run nobody watches, set LOCALAI_REVIEWED_COMMIT to the full id of the commit you reviewed.'
        # Stop comes first: no answer and no setting turns it into a go.
        $stop = [string](Get-ReviewField -Object $Review -Path 'Stop')
        if ($stop) { return [pscustomobject]@{ Go = $false; Why = $stop } }
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

    function Get-GitHubText {
        # What GitHub answers at -Uri, as text. Not Invoke-RestMethod: on Windows PowerShell 5.1 it
        # hands a long JSON answer back unread (ConvertFrom-ReviewJson reads it instead).
        param([string]$Uri, [string]$Accept)
        $headers = @{}
        if ($Accept) { $headers['Accept'] = $Accept }
        $answer = Invoke-WebRequest -Uri $Uri -UseBasicParsing -Headers $headers -TimeoutSec 60
        return (ConvertTo-ReviewBody -Content $answer.Content)
    }

    $ref = $env:LOCALAI_REF
    if (-not $ref) { $ref = 'main' }
    # The ref goes into the addresses GitHub is asked for: a plain name only, checked before any of them is built.
    if (-not (Test-ToolkitRef -Ref $ref)) {
        Write-Host "LOCALAI_REF may hold only the name of a branch, a tag or a commit (letters, digits and . _ / - , no '..'); not used: $(ConvertTo-ReviewText -Text $ref -Max 120)" -ForegroundColor Red
        Write-Host 'Nothing was downloaded or changed.' -ForegroundColor Yellow
        return
    }
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
    # moved meanwhile. Without GitHub's API (rate limit, proxy) the commit's page on github.com names
    # it. Without both, only a first install goes on, with the ref itself; an update stops, because
    # its commit could not be shown.
    $lookup = $null; $incomingError = ''
    try { $lookup = ConvertFrom-ReviewJson -Text (Get-GitHubText -Uri "https://api.github.com/repos/$repo/commits/$ref" -Accept 'application/vnd.github+json') }
    catch { $incomingError = $_.Exception.Message; if (-not $incomingError) { $incomingError = 'no answer' } }
    if (-not $incomingError -and $null -eq (Get-CommitSummary -Commit $lookup)) { $incomingError = 'its answer holds no commit id' }
    # The page is not served by the API, so the API's hourly limit (60 questions for everyone behind
    # one address) is not what decides here. Whether pages have a limit of their own is not known: a
    # page that does not answer either leaves the commit unnamed, and an update then stops below.
    $patchText = ''
    if ($incomingError) { try { $patchText = Get-GitHubText -Uri "https://github.com/$repo/commit/$($ref).patch" } catch { $patchText = '' } }
    $incoming = Get-IncomingCommit -Ref $ref -Answer $lookup -PatchText $patchText

    # What is installed now. Trouble reading it means "an install whose commit is unknown", never
    # "nothing installed": only a folder without a trace of an install goes on without the question.
    $configText = $null; $otherSigns = $false
    try {
        $otherSigns = (Test-Path -LiteralPath ([System.IO.Path]::Combine($root, 'install-state.json'))) -or (Test-Path -LiteralPath ([System.IO.Path]::Combine($root, 'Scripts', 'Install-LocalAI.ps1')))
        $configFile = [System.IO.Path]::Combine($root, 'localai-config.json')
        if (Test-Path -LiteralPath $configFile) { $configText = [System.IO.File]::ReadAllText($configFile) }
    } catch { $configText = '' }
    # An install in another folder than $root (the command in the README does not know LOCALAI_ROOT)
    # is no first install either. The installer's Start-menu folder is for all users, wherever the AI
    # folder is, and only an administrator can remove it. Windows is asked where the all-users Start
    # menu is: a variable of this session (ProgramData) could be pointed somewhere else, and would
    # then be a second way around the question. No answer, or not readable, counts as "it is there".
    $startMenu = $true
    try {
        $allUsersPrograms = [Environment]::GetFolderPath('CommonPrograms')
        if ($allUsersPrograms) { $startMenu = Test-Path -LiteralPath ([System.IO.Path]::Combine($allUsersPrograms, 'Local AI')) }
    } catch { $startMenu = $true }
    $installed = Get-InstalledToolkit -ConfigText $configText -OtherSigns $otherSigns -StartMenu $startMenu
    # The files that differ between the two commits (GitHub's compare API; the repository is public).
    $compare = $null; $compareError = ''
    if ($installed.State -eq 'known' -and $incoming -and $installed.Commit -ne $incoming.Sha) {
        try {
            $compare = ConvertFrom-ReviewJson -Text (Get-GitHubText -Uri "https://api.github.com/repos/$repo/compare/$($installed.Commit)...$($incoming.Sha)" -Accept 'application/vnd.github+json')
            if ($null -eq $compare) { $compareError = 'its answer could not be read (not JSON)' }
        } catch { $compareError = $_.Exception.Message; if (-not $compareError) { $compareError = 'no answer' } }
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
