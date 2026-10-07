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
# known here), and shown with the file list said to be missing. An update still stops then, before
# the question: the list of the commit's files, which the download is compared with (see below), comes
# from the API alone. An update whose commit neither of the two can name (offline, or both refuse) is
# not offered at all: nothing is shown as agreed that could not be shown. Try again later. Setting
# LOCALAI_REF to a full commit id names the commit without GitHub, but not the files it holds.
# The one way to skip the question, for a run nobody watches: name the commit you reviewed, in full:
#
#   $env:LOCALAI_REVIEWED_COMMIT = '<its 40-character id>'
#
# It counts for exactly that commit. When the branch has moved on, the question is asked as usual, and
# without a typed OK nothing is installed.
#
# What is installed is the commit that was shown:
# - The download is asked for by that commit's full id, never by branch name, and compared with the
#   list of files GitHub's API gives for that commit: every file under local-llm by its git id, no
#   file more and none less. A download that differs is refused and nothing is installed. Without
#   that list an update stops; it is never installed unchecked.
# - A first install was not reviewed: it says that its download cannot be compared with a reviewed
#   commit, and goes on.
# - The installer runs with administrator rights (Windows asks once) from a folder under Program
#   Files that only administrators can change. The step that has those rights makes that folder,
#   unpacks the download there and compares it again, so files swapped in your temp folder after the
#   first comparison are refused too. The folder and the downloaded files are removed at the end,
#   also after a refusal.
# The threat model and exactly what is compared stand above Get-Sha256Hex further down.
#
# What the review does not cover:
# - It is only as trustworthy as the copy of this file that runs it. Start menu > Local AI > Update
#   toolkit runs the copy already on this PC. The command above fetches this file from the main branch
#   and runs it unseen: whoever can change that branch can change the review with it. To review that
#   path too, replace refs/heads/main in its address with the id of a commit you have read.
# - It lists the names of the files that differ, not what changed inside them (it prints the address
#   of the full comparison). GitHub lists at most 300 files; a longer list is said to be cut off.
# - It is no defence against a program that already runs under your Windows account: the installed
#   copy of this file sits in a folder such a program can write to. (The comparison above keeps such
#   a program from swapping the downloaded files, not from changing this file.)
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

    # ---- What runs with administrator rights is the commit that was shown -------------------------
    # Threat model.
    # Written against two attackers:
    #   A. Someone able to push to the branch after the review was read (or to have another archive
    #      handed over than the commit shown). The download is asked for by the full id of the commit
    #      the review showed, never by branch name, and installed only when it compares equal to the
    #      list of files GitHub's tree API gives for that id.
    #   B. A program that runs under the same Windows account, without administrator rights. The
    #      download sits in the user's temp folder, which such a program can rewrite at any moment up
    #      to the click on Yes. So the installer is not started from there: the step that has
    #      administrator rights (Invoke-ElevatedInstall) makes a folder under Program Files, gives it
    #      to Administrators and SYSTEM alone, reads those rules back, copies the archive in, unpacks
    #      it there and compares the result again before it starts anything from it. That step is
    #      itself handed over as text in a file in the temp folder: the window with administrator
    #      rights is started with that text's SHA-256 on its command line, reads the file once, and
    #      runs what it read only when the two agree (Get-ElevatedLauncher).
    # Out of scope: an attacker who is already administrator (or SYSTEM) on this PC. Such a program
    # can change Program Files, this check and Windows itself; nothing here is written against it.
    # Not covered either, and said so that it is not taken for granted:
    #   - Attacker B changing what is run before this point: the installed copy of this file, or the
    #     command that was pasted. The header of this file says the same about the review.
    #   - What Windows PowerShell itself reads from the user's folders when it starts with
    #     administrator rights (it looks for modules in the user's Documents folder before the
    #     system's), and what the installer reads from the AI folder, which the user owns.
    #   - GitHub itself: the list of files and the archive both come from it, over TLS.
    #
    # What is compared (Compare-ToolkitTree, Get-ToolkitDigest):
    #   - Every file under local-llm, on both sides: the paths the commit's tree lists and the files
    #     the unpacked archive holds. A file whose content differs, a file the tree does not list
    #     and a file that is missing each refuse the download. Names are compared letter for letter.
    #   - Content by git blob id: SHA-1 over 'blob <length>', a zero byte and the bytes
    #     (Get-GitBlobId). It is the 'sha' the tree API gives for each file; SHA-1 is git's choice,
    #     not one made here.
    #   - One rule for line ends: local-llm/.gitattributes marks *.cmd 'text eol=crlf', so GitHub's
    #     archive holds those files with CRLF while the tree lists the id of their LF form. For a
    #     path that ends in .cmd, CRLF is read as LF before the id is taken (Get-ToolkitFileId). No
    #     other file is touched: a .ps1 that arrives with CRLF does not compare equal.
    #   - Nothing outside local-llm: the rest of the archive is neither compared nor unpacked, and
    #     the installer runs from local-llm alone.
    #   - A tree that cannot be compared exactly is not used at all (Get-TreeManifest): one GitHub
    #     cut off, a path that is no plain file (a link, a submodule), two paths that differ in
    #     capitals only, a path Windows would store elsewhere than git says (Test-PlainRepoPath).
    #   - Without a usable tree an update stops, before the question and before any download: it
    #     is never installed unchecked (Get-DownloadCheck).
    #   - A first install has no reviewed commit: nothing it downloads is compared with one, and it
    #     says so. It is compared with the tree of the commit it shows when GitHub hands that over,
    #     and with nothing when not. Either way the step with administrator rights still makes sure
    #     that it runs exactly the files that were downloaded.
    # The step with administrator rights is told one number, the digest (Get-ToolkitDigest): of the
    # tree's list when the download was compared with it, else of the files as they were downloaded.
    # It works the same number out from what it unpacked, and starts the installer only when the two
    # are equal.
    # The functions down to Get-ElevatedLauncher are pure, like the review's (the tests run them as
    # they are); the ones that touch this PC follow under "Bootstrap".

    function Get-Sha256Hex {
        # SHA-256 of -Bytes as 64 lower-case hex digits.
        param([byte[]]$Bytes)
        if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
        $sha = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }

    function Get-GitBlobId {
        # The id git gives a file with this content: SHA-1 over 'blob <length>', a zero byte and the
        # bytes, as 40 lower-case hex digits. GitHub's tree API lists it as 'sha' for every file.
        param([byte[]]$Bytes)
        if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
        $head = [System.Text.Encoding]::ASCII.GetBytes('blob ' + $Bytes.Length + [char]0)
        $sha = New-Object System.Security.Cryptography.SHA1CryptoServiceProvider
        try {
            [void]$sha.TransformBlock($head, 0, $head.Length, $null, 0)
            [void]$sha.TransformFinalBlock($Bytes, 0, $Bytes.Length)
            return ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
    }

    function Get-ToolkitFileId {
        # The id a downloaded file must have in the commit's tree, from its path in the repository
        # and its bytes as they arrived. A path that ends in .cmd (small letters, as the pattern in
        # local-llm/.gitattributes reads on GitHub) is in the archive with CRLF and in the tree with
        # LF: its CRLF is read as LF first. Every other file is taken byte for byte.
        param([string]$Path, [byte[]]$Bytes)
        if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
        if ($Path -cmatch '\.cmd\z') {
            # Latin-1 maps every byte to one character and back, whatever the file holds.
            $latin = [System.Text.Encoding]::GetEncoding(28591)
            $Bytes = $latin.GetBytes($latin.GetString($Bytes).Replace("`r`n", "`n"))
        }
        return (Get-GitBlobId -Bytes $Bytes)
    }

    function Get-TreeManifest {
        # The files of a commit under local-llm as a list of Path ('local-llm/...', as git writes it)
        # and Id (git blob id), from GitHub's answer to git/trees/<commit>?recursive=1. $null when
        # the answer cannot be compared exactly with what Windows unpacks:
        #   - it is no tree answer, or GitHub cut the list off ('truncated' must be there and false)
        #   - a path (anywhere in the tree) that Windows may store elsewhere than written, or that
        #     holds a '\': it could land under local-llm, or on another file there
        #   - two paths that differ in capitals only: on Windows the second replaces the first
        #   - an entry that is neither a folder nor a plain file (a symbolic link, a submodule), or
        #     whose id is no git id
        #   - no file under local-llm at all
        param($Tree)
        $truncated = Get-ReviewField -Object $Tree -Path 'truncated'
        $entries = Get-ReviewField -Object $Tree -Path 'tree'
        if ($truncated -isnot [bool] -or $truncated -or $null -eq $entries -or $entries -is [string]) { return $null }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $files = New-Object System.Collections.Generic.List[object]
        foreach ($entry in @($entries)) {
            $path = [string](Get-ReviewField -Object $entry -Path 'path')
            $type = [string](Get-ReviewField -Object $entry -Path 'type')
            if ($path.Contains('\') -or -not (Test-PlainRepoPath -Path $path) -or -not $seen.Add($path)) { return $null }
            if ($type -ceq 'tree') { continue }
            $id = [string](Get-ReviewField -Object $entry -Path 'sha')
            $mode = [string](Get-ReviewField -Object $entry -Path 'mode')
            if ($type -cne 'blob' -or @('100644', '100755') -notcontains $mode -or $id -cnotmatch '^[0-9a-f]{40}\z') { return $null }
            if ($path.StartsWith('local-llm/', [System.StringComparison]::Ordinal)) { $files.Add([pscustomobject]@{ Path = $path; Id = $id }) }
        }
        if ($files.Count -eq 0) { return $null }
        return , $files.ToArray()
    }

    function Compare-ToolkitTree {
        # What differs between the commit's files (-Manifest: Get-TreeManifest) and the files that
        # were unpacked (-Files: Get-ToolkitFileList), as lines to print; none when the two lists
        # hold the same paths with the same ids. Paths are compared letter for letter.
        param($Manifest, $Files)
        $want = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
        foreach ($m in @($Manifest)) { $want[[string]$m.Path] = [string]$m.Id }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        $found = New-Object System.Collections.Generic.List[string]
        foreach ($f in @($Files)) {
            $path = [string]$f.Path
            if (-not $seen.Add($path)) { $found.Add("there twice: $path") }
            elseif (-not $want.ContainsKey($path)) { $found.Add("not in the commit: $path") }
            elseif ($want[$path] -cne [string]$f.Id) { $found.Add("not as in the commit: $path") }
        }
        foreach ($path in $want.Keys) { if (-not $seen.Contains($path)) { $found.Add("missing: $path") } }
        return , $found.ToArray()
    }

    function Get-ToolkitDigest {
        # One number for a whole list of files (Path, Id): SHA-256 over its lines '<id> <path>',
        # sorted by character code (the same on every PC, whatever its language), as 64 lower-case
        # hex digits. Two lists have the same digest when they hold the same paths with the same ids.
        param($Files)
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($f in @($Files)) { $lines.Add(([string]$f.Id) + ' ' + ([string]$f.Path)) }
        $sorted = $lines.ToArray()
        [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        return (Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes(($sorted -join "`n"))))
    }

    function Test-AdminOnlyRule {
        # Whether only administrators can change a folder, from its owner and access rules as plain
        # data (-Rule: Owner, a SID as text, and Rules, each with Sid, Rights as a number, Allow and
        # InheritOnly; Get-FolderRule reads them). '' when so, else the first reason why not.
        # SYSTEM, Administrators and TrustedInstaller may own it and hold any right. Everyone else
        # may read and run only: any other right is a no, the generic ones included (generic write
        # and generic all are rights as well, though no file right is named in them). Rules that deny
        # are left out: they take away, never give.
        # -Parent: the folder is the one the new folder is made in. Rules that are inherit-only say
        # nothing about the folder itself (Program Files carries one for CREATOR OWNER) and are left
        # out; for the new folder itself every rule counts.
        param($Rule, [switch]$Parent)
        $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        # ReadAndExecute with Synchronize (0x1200A9), generic read (0x80000000), generic execute
        # (0x20000000). Counted as unsigned 32-bit numbers: the top bit must not turn the sum negative.
        $readBits = [long]0x1200A9 + 2147483648 + 536870912
        $otherBits = 4294967295 - $readBits
        if ($null -eq $Rule -or $null -eq $Rule.Rules) { return 'its access rules could not be read' }
        $owner = [string]$Rule.Owner
        if ($trusted -notcontains $owner) { return "its owner is not SYSTEM, Administrators or TrustedInstaller (owner: $(ConvertTo-ReviewText -Text $owner -Max 80))" }
        foreach ($r in @($Rule.Rules)) {
            $sid = [string]$r.Sid
            if ($r.Allow -isnot [bool] -or $r.InheritOnly -isnot [bool] -or -not $sid -or ($r.Rights -isnot [int] -and $r.Rights -isnot [long])) { return 'one of its access rules could not be read' }
            if (-not $r.Allow -or ($Parent -and $r.InheritOnly) -or $trusted -contains $sid) { continue }
            $rights = [long]$r.Rights
            if ($rights -lt 0) { $rights += 4294967296 }
            if (($rights -band $otherBits) -ne 0) { return ('{0} may change it (rights 0x{1:X8})' -f (ConvertTo-ReviewText -Text $sid -Max 80), $rights) }
        }
        return ''
    }

    function Get-DownloadCheck {
        # Whether what is about to be downloaded can be compared with the commit the review showed,
        # from data that was already fetched:
        #   -Review         Get-UpdateReview's answer
        #   -Manifest       Get-TreeManifest's answer for the review's commit; $null when there is
        #                   none (-ManifestError: why)
        # Returns Lines (Text, Color) to print under the review; Compare: the download is compared
        # with -Manifest; and Stop: when not empty, why this run ends here, before any question and
        # before any download. An update goes on only with a manifest. No answer from GitHub, an
        # answer that is cut off and one that cannot be read all stop it, and nothing turns that
        # into a go: no typed OK, no LOCALAI_REVIEWED_COMMIT. Whatever is not plainly a first
        # install counts as an update. Only a first install goes on without a manifest, and says
        # that its download cannot be compared with a reviewed commit. A review that says Stop
        # itself is left to the gate (Get-UpdateConsent), which stops it.
        param($Review, $Manifest, [string]$ManifestError)
        $lines = New-Object System.Collections.Generic.List[object]
        $say = { param($Text, $Color) $lines.Add([pscustomobject]@{ Text = [string]$Text; Color = [string]$Color }) }
        $pad = ' ' * 18
        $count = @($Manifest).Count
        $usable = ($null -ne $Manifest -and $count -gt 0)
        $why = ConvertTo-ReviewText -Text $ManifestError -Max 200 -AllowUnicode
        if (-not $why) { $why = 'GitHub gave no answer' }
        if ([string](Get-ReviewField -Object $Review -Path 'Stop')) { return [pscustomobject]@{ Stop = ''; Compare = $false; Lines = $lines.ToArray() } }
        $commit = [string](Get-ReviewField -Object $Review -Path 'Commit')
        if ([string](Get-ReviewField -Object $Review -Path 'Kind') -ceq 'first') {
            & $say '  Download check: a first install was not reviewed, so this download cannot be compared with a reviewed commit.' 'Yellow'
            if ($usable -and $commit) { & $say ($pad + "It is compared with the $count file(s) GitHub lists under local-llm for the commit above.") 'Gray' }
            elseif ($commit) { & $say ($pad + "GitHub's list of that commit's files could not be used either ($why): it is installed as it arrives.") 'Yellow' }
            else { & $say ($pad + 'Without a commit there is no list of its files either: it is installed as it arrives.') 'Yellow' }
            return [pscustomobject]@{ Stop = ''; Compare = ($usable -and [bool]$commit); Lines = $lines.ToArray() }
        }
        if ($usable -and $commit) {
            & $say "  Download check: what is downloaded must hold exactly the $count file(s) GitHub lists under local-llm for this commit, or it is not installed." 'Gray'
            return [pscustomobject]@{ Stop = ''; Compare = $true; Lines = $lines.ToArray() }
        }
        $stop = "GitHub's list of the files of this commit could not be used ($why), so the download could not be compared with the commit shown above. An update is never installed unchecked. Try again later (GitHub's API answers 60 questions an hour for everyone behind one address)."
        return [pscustomobject]@{ Stop = $stop; Compare = $false; Lines = $lines.ToArray() }
    }

    function Get-ElevatedFunctionList {
        # The functions of this file that the step with administrator rights is made of: it is
        # handed their text (Get-ElevatedStage), because that window has nothing else of this file.
        # Every function one of them calls has to be in this list too (the tests check that).
        return @('ConvertTo-ReviewText', 'Test-PlainRepoPath', 'Get-Sha256Hex', 'Get-GitBlobId', 'Get-ToolkitFileId', 'Get-ToolkitDigest', 'Test-AdminOnlyRule',
            'Get-ToolkitFileList', 'ConvertTo-FolderRule', 'Get-FolderRule', 'Set-AdminOnlyRule', 'Expand-ToolkitArchive', 'Remove-ToolkitTree', 'Remove-HandedOverFile', 'Invoke-ElevatedInstall')
    }

    function Get-ElevatedStage {
        # The text of the step that runs with administrator rights: the functions it is made of
        # (-Definitions: name and body of each, as this file defines them) and one line that calls
        # Invoke-ElevatedInstall. Every value in that line travels as base64 and is turned back by
        # the text itself, so no folder name, however it is spelled (a quote, a '$', a space), can
        # become part of the command.
        param([System.Collections.IDictionary]$Definitions, [string]$Zip, [string]$StageFile, [string]$Digest, [string]$Commit, [string]$Root, [string[]]$Extra)
        $value = { param([string]$Text) '(& $plain ''' + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)) + ''')' }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('$ErrorActionPreference = ''Stop''')
        $lines.Add('$ProgressPreference = ''SilentlyContinue''')
        foreach ($name in @($Definitions.Keys)) { $lines.Add('function ' + $name + ' {' + [string]$Definitions[$name] + '}') }
        $lines.Add('$plain = { param([string]$Text) [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Text)) }')
        $words = @($Extra | Where-Object { $_ } | ForEach-Object { & $value $_ }) -join ', '
        $lines.Add('Invoke-ElevatedInstall -Zip ' + (& $value $Zip) + ' -StageFile ' + (& $value $StageFile) + ' -Digest ' + (& $value $Digest) + ' -Commit ' + (& $value $Commit) + ' -Root ' + (& $value $Root) + ' -Extra @(' + $words + ')')
        return ($lines -join "`n")
    }

    function Get-ElevatedLauncher {
        # The command the window with administrator rights is started with: it reads the file with
        # the step's text (Get-ElevatedStage) once, and runs what it read only when its SHA-256 is
        # -Hash. The hash is part of the command Windows was asked to start with administrator
        # rights, where a program of the user can no longer change it; the file is in the user's
        # temp folder, where it can. A file that was changed or removed is refused, and both files
        # in the temp folder are removed (only as plain files in a folder that is no link: with
        # administrator rights nothing is removed through a link).
        # One line, without a double quote and without two spaces in a row: Start-Process hands its
        # arguments over joined by spaces, and powershell.exe puts the command together from the
        # pieces again. The two paths travel as base64 for the same reason.
        param([string]$StageFile, [string]$Zip, [string]$Hash)
        $value = { param([string]$Text) "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)) + "'))" }
        $refuse = @(
            'Write-Host ''Stopped: the file that carries the step with administrator rights was changed or removed after this window was asked for (a program running under your Windows account can do that).'' -ForegroundColor Red'
            'Write-Host ''Nothing was installed or changed: your Local AI keeps working as it is.'' -ForegroundColor Yellow'
            'foreach($p in $f,$z){try{$i=New-Object IO.FileInfo($p);if($i.Exists -and -not(($i.Attributes -bor $i.Directory.Attributes) -band 1024)){$i.Delete()}}catch{$i=$null}}'
        ) -join ';'
        $steps = @(
            ('$f=' + (& $value $StageFile))
            ('$z=' + (& $value $Zip))
            '$b=[byte[]]@()'
            'try{$b=[IO.File]::ReadAllBytes($f)}catch{$b=[byte[]]@()}'
            '$h=[BitConverter]::ToString((New-Object Security.Cryptography.SHA256CryptoServiceProvider).ComputeHash($b)).Replace(''-'','''')'
            ('if($h -eq ''' + $Hash + '''){& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString($b)))}else{' + $refuse + '}')
        )
        return ($steps -join ';')
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

    function Get-ToolkitFileList {
        # Every file under <Top>\local-llm of an unpacked archive as Path ('local-llm/...', as git
        # writes it) and Id (Get-ToolkitFileId): what Compare-ToolkitTree and Get-ToolkitDigest take.
        # A link among them is an error: nothing is read through one.
        param([string]$Top)
        $list = New-Object System.Collections.Generic.List[object]
        $todo = New-Object System.Collections.Generic.Queue[object]
        $todo.Enqueue([pscustomobject]@{ Folder = [System.IO.Path]::Combine($Top, 'local-llm'); Name = 'local-llm' })
        while ($todo.Count -gt 0) {
            $at = $todo.Dequeue()
            $folder = New-Object System.IO.DirectoryInfo($at.Folder)
            if (-not $folder.Exists) { continue }
            if ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "$($at.Name) is a link in the unpacked archive" }
            foreach ($item in $folder.GetFileSystemInfos()) {
                $name = $at.Name + '/' + $item.Name
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "$name is a link in the unpacked archive" }
                if ($item -is [System.IO.DirectoryInfo]) { $todo.Enqueue([pscustomobject]@{ Folder = $item.FullName; Name = $name }); continue }
                $list.Add([pscustomobject]@{ Path = $name; Id = (Get-ToolkitFileId -Path $name -Bytes ([System.IO.File]::ReadAllBytes($item.FullName))) })
            }
        }
        return , $list.ToArray()
    }

    function ConvertTo-FolderRule {
        # A folder's security descriptor as the plain data Test-AdminOnlyRule takes: Owner (a SID as
        # text) and Rules, one for each access rule, inherited ones included (Sid, Rights as a
        # number, Allow, InheritOnly). A folder without any list of rules is open to everyone;
        # Windows hands that over as one rule for Everyone with every right.
        param($Security)
        $sidType = [System.Security.Principal.SecurityIdentifier]
        $rules = New-Object System.Collections.Generic.List[object]
        foreach ($r in $Security.GetAccessRules($true, $true, $sidType)) {
            $rules.Add([pscustomobject]@{
                    Sid         = [string]$r.IdentityReference.Value
                    Rights      = [int]$r.FileSystemRights
                    Allow       = ($r.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow)
                    InheritOnly = (([int]$r.PropagationFlags -band 2) -ne 0)
                })
        }
        return [pscustomobject]@{ Owner = [string]$Security.GetOwner($sidType).Value; Rules = $rules.ToArray() }
    }

    function Get-FolderRule {
        # Owner and access rules of the folder -Path as plain data (ConvertTo-FolderRule).
        param([string]$Path)
        return (ConvertTo-FolderRule -Security (Get-Acl -LiteralPath $Path))
    }

    function Set-AdminOnlyRule {
        # Gives the folder -Path to Administrators and lets SYSTEM and Administrators alone into it
        # and into all that is made in it; nothing is inherited from the folder above. Windows
        # PowerShell only, which is what the step with administrator rights runs in.
        param([string]$Path)
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        $security.SetAccessRuleProtection($true, $false)
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $who = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($who, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)))
        }
        (New-Object System.IO.DirectoryInfo($Path)).SetAccessControl($security)
    }

    function Expand-ToolkitArchive {
        # Unpacks the toolkit from the archive -Zip (as GitHub sends it: one top folder, local-llm in
        # it) into the folder -Destination and returns the top folder there. Only what lies under
        # local-llm is written: the rest of the archive is neither compared nor run.
        # Not Expand-Archive: this also runs with administrator rights, on an archive that was not
        # compared yet, and no name in it may decide where a file lands. Every name has to be one
        # Windows stores as written (Test-PlainRepoPath: no '..', no drive, no stream) and to stay
        # inside -Destination; no file is written over another; and no more than -MaxBytes of
        # unpacked content is taken. Anything else is an error, and the caller stops.
        param([string]$Zip, [string]$Destination, [long]$MaxBytes = 268435456)
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $separator = [string][System.IO.Path]::DirectorySeparatorChar
        $base = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
        $top = ''
        $total = [long]0
        $buffer = New-Object byte[] 65536
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            foreach ($entry in $archive.Entries) {
                # Compress-Archive of Windows PowerShell 5.1 writes '\' between the parts, GitHub '/'.
                $name = ([string]$entry.FullName).Replace('\', '/')
                $isFolder = $name.EndsWith('/')
                if ($isFolder) { $name = $name.Substring(0, $name.Length - 1) }
                if (-not (Test-PlainRepoPath -Path $name)) { throw "the archive holds a name Windows may store elsewhere than written: $(ConvertTo-ReviewText -Text $entry.FullName -Max 120)" }
                $parts = $name.Split('/')
                if (-not $top) { $top = $parts[0] }
                if ($parts[0] -cne $top -or ($parts.Count -eq 1 -and -not $isFolder)) { throw 'the archive does not hold one top folder with everything in it' }
                if ($isFolder -or $parts.Count -lt 3 -or $parts[1] -ine 'local-llm') { continue }
                $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $name.Replace('/', $separator)))
                if (-not $target.StartsWith($base + $separator, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'a file of the archive would land outside the folder it is unpacked into' }
                [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
                $from = $entry.Open()
                try {
                    $to = New-Object System.IO.FileStream($target, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $read = $from.Read($buffer, 0, $buffer.Length)
                        while ($read -gt 0) {
                            $total += $read
                            if ($total -gt $MaxBytes) { throw 'the archive unpacks to far more than a toolkit holds' }
                            $to.Write($buffer, 0, $read)
                            $read = $from.Read($buffer, 0, $buffer.Length)
                        }
                    } finally { $to.Dispose() }
                } finally { $from.Dispose() }
            }
        } finally { $archive.Dispose() }
        if (-not $top) { throw 'the archive is empty' }
        return [System.IO.Path]::Combine($base, $top)
    }

    function Remove-ToolkitTree {
        # Removes the folder -Path with all that is in it; nothing happens when it is not there.
        # Not Remove-Item -Recurse: Windows PowerShell 5.1 walks into a junction with it and empties
        # what the junction points at. Here a link is removed as a link and never walked into.
        param([string]$Path)
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path); return }
        $folder = New-Object System.IO.DirectoryInfo($Path)
        if (-not $folder.Exists) { return }
        if (-not ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            foreach ($item in $folder.GetFileSystemInfos()) {
                if ($item -is [System.IO.DirectoryInfo]) { Remove-ToolkitTree -Path $item.FullName; continue }
                # A read-only file is not removed as it is; a link keeps the marks it has.
                if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $item.Attributes = [System.IO.FileAttributes]::Normal }
                $item.Delete()
            }
        }
        $folder.Delete()
    }

    function Remove-HandedOverFile {
        # Removes a file the step with administrator rights was handed in the user's temp folder.
        # That folder is the user's, and this runs with administrator rights: the file is removed
        # only as a plain file in a folder that is no link, by its own name, so that the name cannot
        # be made to stand for a file somewhere else. What is left in place is named.
        param([string]$Path)
        if (-not $Path) { return }
        try {
            $file = New-Object System.IO.FileInfo($Path)
            if (-not $file.Exists) { return }
            if (($file.Attributes -bor $file.Directory.Attributes) -band [System.IO.FileAttributes]::ReparsePoint) {
                Write-Host "Left in place, because it or its folder is a link: $Path" -ForegroundColor Yellow
                return
            }
            $file.Delete()
        } catch { Write-Host "Could not remove $Path ($(ConvertTo-ReviewText -Text $_.Exception.Message -Max 200 -AllowUnicode))." -ForegroundColor Yellow }
    }

    function Invoke-ElevatedInstall {
        # The step that runs with administrator rights (the threat model stands above
        # Get-Sha256Hex). It is handed the downloaded archive (-Zip, in the user's temp folder) and
        # the digest the files under local-llm must have (-Digest), and takes nothing from the temp
        # folder on trust. In this order, and every "no" ends the step before the installer starts:
        #   1. Program Files itself must be a folder only administrators can change.
        #   2. What an earlier run left there is removed, and the folder LocalAI-Update is made anew.
        #      (Not Program Files\LocalAI: the installer keeps its copy for the resume after a
        #      restart there, and removes that folder when it runs from anywhere else.)
        #   3. The folder is given to Administrators and SYSTEM alone, and its rules are read back.
        #   4. The archive is copied in and unpacked there; it must hold one top folder.
        #   5. The digest of what was unpacked must be -Digest.
        #   6. Only then: COMMIT is written next to the installer, which records it, and the
        #      installer is started from that folder, by the full path of Windows PowerShell.
        # At the end, whatever happened, the folder is removed again, and so are the two files in
        # the temp folder (-Zip, and -StageFile: the file this step's text was read from). A run
        # that is cut off (the window closed) leaves them; the next one removes them.
        param([string]$Zip, [string]$StageFile, [string]$Digest, [string]$Commit, [string]$Root, [string[]]$Extra)
        # Windows is asked where its folders are: a variable of this session could name others.
        $programFiles = [Environment]::GetFolderPath('ProgramFiles')
        $shell = [System.IO.Path]::Combine([Environment]::GetFolderPath('System'), 'WindowsPowerShell', 'v1.0', 'powershell.exe')
        $stage = [System.IO.Path]::Combine($programFiles, 'LocalAI-Update')
        $lockFile = [System.IO.Path]::Combine($stage, 'in-use')
        $lock = $null
        $made = $false
        $started = $false
        try {
            Write-Host 'Checking the download once more, in a folder only administrators can change...' -ForegroundColor Cyan
            if ($Digest -cnotmatch '^[0-9a-f]{64}\z' -or ($Commit -and $Commit -cnotmatch '^[0-9a-f]{40}\z')) { throw 'this step was not told what the download has to be' }
            $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'this step did not get administrator rights' }
            if (-not $programFiles -or -not [System.IO.File]::Exists($shell)) { throw 'Windows did not name its Program Files folder, or Windows PowerShell is not where Windows keeps it' }
            $parentWhy = Test-AdminOnlyRule -Rule (Get-FolderRule -Path $programFiles) -Parent
            if ($parentWhy) { throw "$programFiles is not a folder only administrators can change: $parentWhy" }
            # A run that is still installing holds this file open: its folder is not taken away.
            if ([System.IO.File]::Exists($lockFile)) {
                try { [System.IO.File]::Delete($lockFile) } catch { throw "another Local AI update is still running ($stage is in use). Let it finish, then run this again" }
            }
            Remove-ToolkitTree -Path $stage
            $made = $true
            [void][System.IO.Directory]::CreateDirectory($stage)
            Set-AdminOnlyRule -Path $stage
            $stageWhy = Test-AdminOnlyRule -Rule (Get-FolderRule -Path $stage)
            if ($stageWhy) { throw "$stage could not be made a folder only administrators can change: $stageWhy" }
            if ((New-Object System.IO.DirectoryInfo($stage)).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "$stage is a link, not a folder" }
            $lock = New-Object System.IO.FileStream($lockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $zipCopy = [System.IO.Path]::Combine($stage, 'download.zip')
            # The file in the temp folder is whatever a program of the user left there: no more of it
            # is copied than a toolkit can be.
            if ((New-Object System.IO.FileInfo($Zip)).Length -gt 268435456) { throw 'the archive in the temp folder is far larger than a toolkit: it is not the download that was compared' }
            [System.IO.File]::Copy($Zip, $zipCopy)
            $top = Expand-ToolkitArchive -Zip $zipCopy -Destination $stage
            $found = Get-ToolkitDigest -Files (Get-ToolkitFileList -Top $top)
            if ($found -cne $Digest) { throw 'the archive in the temp folder is not the download that was compared: it was changed while Windows asked for administrator rights' }
            $installer = [System.IO.Path]::Combine($top, 'local-llm', 'Install-LocalAI.ps1')
            if (-not [System.IO.File]::Exists($installer)) { throw 'the download holds no installer (Install-LocalAI.ps1 under local-llm)' }
            # Recorded by the installer (localai-config.json, diagnostics), so it is known what code runs.
            if ($Commit) { [System.IO.File]::WriteAllText([System.IO.Path]::Combine($top, 'local-llm', 'COMMIT'), $Commit) }
            Write-Host 'It is the download that was compared. Starting the installer from that folder...' -ForegroundColor Cyan
            $started = $true
            & $shell -NoProfile -ExecutionPolicy Bypass -File $installer -AIRoot $Root @Extra
            $code = $LASTEXITCODE
            Write-Host ''
            if ($code -eq 3010) { Write-Host 'A restart is needed; the installer resumes after you sign in again (click Yes when Windows asks).' -ForegroundColor Cyan }
            elseif ($code -ne 0) { Write-Host "The installer stopped with an error (code $code); see the messages above." -ForegroundColor Red }
        } catch {
            Write-Host "Stopped: $(ConvertTo-ReviewText -Text $_.Exception.Message -Max 400 -AllowUnicode)" -ForegroundColor Red
            if ($started) { Write-Host 'The installer had been started already: see its messages above.' -ForegroundColor Yellow }
            else { Write-Host 'Nothing was installed or changed: your Local AI keeps working as it is.' -ForegroundColor Yellow }
        } finally {
            if ($lock) { $lock.Dispose() }
            if ($made) {
                # A virus scanner may still hold a file it is reading: tried a few times.
                $notRemoved = 'not tried'
                for ($attempt = 1; $attempt -le 4 -and $notRemoved; $attempt++) {
                    try { Remove-ToolkitTree -Path $stage; $notRemoved = '' }
                    catch { $notRemoved = $_.Exception.Message; Start-Sleep -Milliseconds 500 }
                }
                if ($notRemoved) { Write-Host "Could not remove $stage ($(ConvertTo-ReviewText -Text $notRemoved -Max 200 -AllowUnicode)); the next update removes it." -ForegroundColor Yellow }
            }
            Remove-HandedOverFile -Path $Zip
            Remove-HandedOverFile -Path $StageFile
        }
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
    # Downloaded into the user's temp folder and unpacked there only to be compared and to read the
    # version: nothing is run from there. The installer is started by the step with administrator
    # rights, from its own folder under Program Files (Invoke-ElevatedInstall); that step is handed
    # over as text in $stageFile. The installer copies itself into AI\Scripts (and, before a reboot,
    # into Program Files\LocalAI for the resume).
    $dest = Join-Path $env:TEMP 'LocalAI-Installer'
    $zip = Join-Path $env:TEMP 'localai-installer.zip'
    $stageFile = Join-Path $env:TEMP 'localai-elevated-step.txt'
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
    # The files of that commit, as GitHub's tree API lists them: what the download is compared with.
    # Asked for by the commit's id, like the download. Without a list that can be used, an update
    # stops here, before the question (Get-DownloadCheck); only a first install goes on.
    $manifest = $null; $manifestError = ''
    if ($review.Commit) {
        try {
            $manifest = Get-TreeManifest -Tree (ConvertFrom-ReviewJson -Text (Get-GitHubText -Uri "https://api.github.com/repos/$repo/git/trees/$($review.Commit)?recursive=1" -Accept 'application/vnd.github+json'))
            if ($null -eq $manifest) { $manifestError = 'its answer is no complete list of plain files: cut off, not readable, or with a name Windows stores elsewhere than git says' }
        } catch { $manifest = $null; $manifestError = $_.Exception.Message; if (-not $manifestError) { $manifestError = 'no answer' } }
    }
    $check = Get-DownloadCheck -Review $review -Manifest $manifest -ManifestError $manifestError
    foreach ($line in $check.Lines) { Write-Host -Object $line.Text -ForegroundColor $line.Color }
    if ($check.Stop) {
        Write-Host "Stopped: $($check.Stop)" -ForegroundColor Yellow
        Write-Host 'Nothing was downloaded or changed: your Local AI keeps working as it is.' -ForegroundColor Yellow
        return
    }
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

    # Options for the installer, e.g. -OfficialModels none: plain words only (no quotes or scripts).
    # Looked at before anything is downloaded.
    $extra = @()
    if ($env:LOCALAI_ARGS) { $extra = @($env:LOCALAI_ARGS -split '\s+' | Where-Object { $_ }) }
    $bad = @($extra | Where-Object { $_ -notmatch '^[A-Za-z0-9_:,.\\-]+$' })
    if ($bad.Count) {
        Write-Host "LOCALAI_ARGS may hold only plain options such as -OfficialModels none; not used: $($bad -join ' ')" -ForegroundColor Red
        Write-Host 'Nothing was downloaded or changed.' -ForegroundColor Yellow
        return
    }

    # Whatever happens from here on, nothing of this run stays behind in the temp folder: what was
    # unpacked there goes in any case, and the archive and the step's text go too unless the window
    # with administrator rights was started (it removes them itself, once it has read them).
    $handedOver = $false
    try {
        Write-Host "Downloading installer ($ref$(if ($commit) { ', commit ' + $commit.Substring(0, 7) }))..." -ForegroundColor Cyan
        try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing }
        catch {
            Write-Host "The download failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Nothing was changed: your Local AI keeps working as it is. Check the internet connection and run the command again; to repair the installed copy instead, double-click $root\Scripts\Install-LocalAI.cmd." -ForegroundColor Yellow
            return
        }
        $top = ''; $files = @(); $unpackError = ''
        try {
            Remove-ToolkitTree -Path $dest
            $top = Expand-ToolkitArchive -Zip $zip -Destination $dest
            $files = Get-ToolkitFileList -Top $top
        } catch { $unpackError = $_.Exception.Message; if (-not $unpackError) { $unpackError = 'no reason given' } }
        if ($unpackError) {
            Write-Host "Stopped: the download could not be unpacked ($(ConvertTo-ReviewText -Text $unpackError -Max 300 -AllowUnicode))." -ForegroundColor Red
            Write-Host 'Nothing was installed or changed: your Local AI keeps working as it is.' -ForegroundColor Yellow
            return
        }
        # The first comparison, before Windows is asked for administrator rights: what arrived has to
        # be the commit that was shown. The step with administrator rights compares again.
        if ($check.Compare) {
            $differences = Compare-ToolkitTree -Manifest $manifest -Files $files
            if ($differences.Count) {
                Write-Host "Stopped: what was downloaded is not commit $commit as GitHub lists it ($($differences.Count) difference(s) under local-llm):" -ForegroundColor Red
                foreach ($difference in @($differences | Select-Object -First 10)) { Write-Host "  $(ConvertTo-ReviewText -Text $difference -Max 150)" -ForegroundColor Red }
                if ($differences.Count -gt 10) { Write-Host "  ... and $($differences.Count - 10) more" -ForegroundColor Red }
                Write-Host 'Nothing was installed or changed: your Local AI keeps working as it is. Run the command again; a download that is refused again should not be installed by hand either.' -ForegroundColor Yellow
                return
            }
            $digest = Get-ToolkitDigest -Files $manifest
        } else {
            # A first install without a list of the commit's files: there is nothing to compare with,
            # but what runs with administrator rights has to be exactly what was downloaded here.
            $digest = Get-ToolkitDigest -Files $files
        }
        $installer = [System.IO.Path]::Combine($top, 'local-llm', 'Install-LocalAI.ps1')
        if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found in the downloaded archive ($installer)." }
        $version = ''; $vf = [System.IO.Path]::Combine($top, 'local-llm', 'VERSION')
        if (Test-Path -LiteralPath $vf) { $version = ConvertTo-ReviewText -Text ([System.IO.File]::ReadAllText($vf)) -Max 40 }
        Write-Host "Installing Local AI toolkit $version$(if ($commit) { ' (commit ' + $commit.Substring(0, 7) + ')' }). Windows asks for administrator rights next." -ForegroundColor Cyan

        # The step with administrator rights: its functions as this file defines them and the values
        # of this run, written to one file; and the window that reads it, started with the SHA-256
        # the file must have (Get-ElevatedStage, Get-ElevatedLauncher). Windows PowerShell by its full
        # path: no folder on the PATH decides what gets the administrator rights.
        $definitions = [ordered]@{}
        foreach ($name in (Get-ElevatedFunctionList)) { $definitions[$name] = [string](Get-Command -Name $name -CommandType Function).Definition }
        $stageBytes = [System.Text.Encoding]::UTF8.GetBytes((Get-ElevatedStage -Definitions $definitions -Zip $zip -StageFile $stageFile -Digest $digest -Commit $commit -Root $root -Extra $extra))
        [System.IO.File]::WriteAllBytes($stageFile, $stageBytes)
        $launcher = Get-ElevatedLauncher -StageFile $stageFile -Zip $zip -Hash (Get-Sha256Hex -Bytes $stageBytes)
        $shell = [System.IO.Path]::Combine([Environment]::GetFolderPath('System'), 'WindowsPowerShell', 'v1.0', 'powershell.exe')
        # -NoExit: the window stays open with the installer's messages, as the installer's own does.
        try { Start-Process -FilePath $shell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', $launcher) -ErrorAction Stop }
        catch {
            # 'No' at the prompt of Windows (or closing it) lands here.
            Write-Host ''
            Write-Host 'Administrator rights were declined; run the command again and click Yes.' -ForegroundColor Red
            Write-Host "($(ConvertTo-ReviewText -Text $_.Exception.Message -Max 200 -AllowUnicode))" -ForegroundColor DarkGray
            Write-Host 'Nothing was installed or changed: your Local AI keeps working as it is.' -ForegroundColor Yellow
            return
        }
        $handedOver = $true
        Write-Host ''
        Write-Host 'The installer continues in the Administrator window that opened.' -ForegroundColor Cyan
    } finally {
        try { Remove-ToolkitTree -Path $dest } catch { $null = $_ }
        if (-not $handedOver) {
            foreach ($leftover in @($zip, $stageFile)) {
                try { if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force } } catch { $null = $_ }
            }
        }
    }
}
