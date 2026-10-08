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
# without a typed OK nothing is installed. A run nobody watches has nobody to click Yes at the prompt
# of Windows either: start it from Windows PowerShell with administrator rights (see below).
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
#   copies the download in, unpacks it there and compares it again, so a download swapped in your
#   temp folder after the first comparison is refused too. Nothing is unpacked in the temp folder.
#   That folder is removed at the end, also after a refusal. The step removes nothing in your temp
#   folder: the two files this window put there (the download, and the step's own text) are
#   removed by this window, with your rights, once the other window has read them.
# - Started from a Windows PowerShell window that already has administrator rights, the installer
#   runs in that window, after the same checks: its messages and its result stay there.
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
    #      download sits in the user's temp folder, which such a program can rewrite at any moment.
    #      So nothing is unpacked there and the installer is not started from there. This script
    #      reads the downloaded file once and works on those bytes alone: their SHA-256, and the
    #      comparison with the commit's files, in memory. The step that has administrator rights
    #      (Invoke-ElevatedInstall) makes a folder under Program Files that belongs to
    #      Administrators and SYSTEM alone from the moment it exists, reads those rules back, copies
    #      the archive in, refuses a copy that does not have that SHA-256 before it opens it,
    #      unpacks it there and compares what was unpacked again before it starts anything from it.
    #      In the user's folders that step only reads: it removes and writes nothing there, since
    #      a program of the user can make a name in its own folders stand for a file anywhere on
    #      the PC, and a removal with administrator rights would then be aimed by that program.
    #      The two files in the temp folder are removed by the window that put them there, with
    #      the user's own rights, once the step has said that it has read them
    #      (Start-ElevatedWindow, Send-HandOverSignal). It says so by a signal that window made,
    #      which it finds by name. A name is something a program of the user can make stand for
    #      another signal of Windows, so the step looks at what it opened before it touches it,
    #      and sets it only when it belongs to the account that asked. That step is itself handed
    #      over as text in a file in the temp folder: the window with administrator rights is
    #      started with that text's SHA-256 on its command line, reads the file once, and runs
    #      what it read only when the two agree (Get-ElevatedLauncher).
    # Out of scope: an attacker who is already administrator (or SYSTEM) on this PC. Such a program
    # can change Program Files, this check and Windows itself; nothing here is written against it.
    # Not covered either, and said so that it is not taken for granted:
    #   - Attacker B changing what is run before this point: the installed copy of this file, or the
    #     command that was pasted. The header of this file says the same about the review.
    #   - Attacker B setting what this script reads from the environment (LOCALAI_REF,
    #     LOCALAI_REVIEWED_COMMIT, LOCALAI_ROOT, LOCALAI_ARGS) for the windows the user opens later.
    #     With the first two it can name a commit of its own as the reviewed one (GitHub answers
    #     at this address for a fork's commits too): the question is then not asked, and the
    #     prompt of Windows is all the user sees.
    #   - Attacker B swapping the downloaded file between the download and the one read of it. With
    #     the commit's list of files that is caught, as any other download that is not the commit.
    #     Without it (a first install GitHub's API did not answer for) nothing was shown that the
    #     bytes could be held against: what is installed then is the file as it was read here, and
    #     no more is claimed.
    #   - This script itself started with administrator rights: then all it does has those rights,
    #     the download into the temp folder and the removal of its two files there included, as it
    #     always had. The step's own checks are the same.
    #   - What Windows PowerShell itself reads from the user's folders when it starts with
    #     administrator rights (it looks for modules in the user's Documents folder before the
    #     system's), and what the installer reads from the AI folder, which the user owns.
    #   - GitHub itself: the list of files and the archive both come from it, over TLS.
    #
    # What is compared (Compare-ToolkitTree, Get-ToolkitDigest):
    #   - Every file under local-llm, on both sides: the paths the commit's tree lists and the files
    #     the archive holds. A file whose content differs, a file the tree does not list and a file
    #     that is missing each refuse the download. Names are compared letter for letter.
    #   - Content by git blob id: SHA-1 over 'blob <length>', a zero byte and the bytes
    #     (Get-GitBlobId). It is the 'sha' the tree API gives for each file; SHA-1 is git's choice,
    #     not one made here.
    #   - One rule for line ends: local-llm/.gitattributes marks *.cmd 'text eol=crlf', so GitHub's
    #     archive holds those files with CRLF while the tree lists the id of their LF form. For a
    #     path that ends in .cmd, CRLF is read as LF before the id is taken (Get-ToolkitFileId). No
    #     other file is touched: a .ps1 that arrives with CRLF does not compare equal.
    #   - Nothing outside local-llm: the rest of the archive is neither read, compared nor written
    #     (Get-ToolkitEntry), and the installer runs from local-llm alone. So nothing out there can
    #     stand in the way either: a name Windows could not store, a link or a submodule in another
    #     folder of the repository stops no install and no update.
    #   - A tree that cannot be compared exactly is not used at all (Get-TreeManifest): one GitHub
    #     cut off; and under local-llm a path that is no plain file (a link, a submodule), two paths
    #     that differ in capitals only, a path Windows would store elsewhere than git says
    #     (Test-PlainRepoPath).
    #   - Without a usable tree an update stops, before the question and before any download: it
    #     is never installed unchecked (Get-DownloadCheck).
    #   - A first install has no reviewed commit: nothing it downloads is compared with one, and it
    #     says so. It is compared with the tree of the commit it shows when GitHub hands that over,
    #     and with nothing when not.
    # Assumed about GitHub, which no test with stand-ins can show: that git/trees/<commit id>
    # answers for a commit id, and that its archive holds every file under local-llm byte for byte
    # as the commit does, *.cmd apart. tests\Invoke-GetLocalAITest.ps1 -ProbeCommit <id> asks GitHub
    # itself for a pushed commit and compares the two.
    # The step with administrator rights is told two numbers. The SHA-256 of the archive as this
    # script read it: the copy the step took must have it, or it is not even opened. And the digest
    # (Get-ToolkitDigest) of the tree's list when the download was compared with it, else of the
    # files as they were read from the archive: the step works the same number out from what it
    # unpacked under Program Files, and starts the installer only when the two are equal. That
    # second check is the comparison with the reviewed commit, made again after Windows gave the
    # administrator rights.
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
        # The files of a commit under local-llm, from GitHub's answer to git/trees/<commit>?recursive=1:
        # Files, a list of Path ('local-llm/...', as git writes it) and Id (git blob id). Files is
        # $null when the answer cannot be compared exactly with what Windows unpacks; Why then says
        # what stands in the way, and Lasting whether it is this commit's own list (true: asking
        # again later changes nothing) or an answer that may be another one next time.
        # Only what the download's reader takes is looked at (Get-ToolkitEntry): entries whose first
        # part is local-llm, in whatever capitals. All else the repository holds is never read or
        # written on this PC, so a name out there (a letter outside ASCII, a link, a submodule)
        # stands in nobody's way. Not usable:
        #   - no tree answer at all, or one GitHub cut off ('truncated' must be there and false)
        #   - under local-llm: a path Windows may store elsewhere than written, or that holds a '\'
        #     (the reader takes '\' for '/'); two paths that differ in capitals only (on Windows
        #     the second replaces the first); an entry that is neither a folder nor a plain file (a
        #     symbolic link, a submodule), or whose id is no git id
        #   - no file under local-llm at all
        param($Tree)
        $no = { param([string]$Why, [bool]$Lasting) [pscustomobject]@{ Files = $null; Why = $Why; Lasting = $Lasting } }
        $truncated = Get-ReviewField -Object $Tree -Path 'truncated'
        $entries = Get-ReviewField -Object $Tree -Path 'tree'
        if ($truncated -isnot [bool] -or $null -eq $entries -or $entries -is [string]) { return (& $no 'its answer is no list of files' $false) }
        if ($truncated) { return (& $no 'GitHub cut the list off: the commit holds more files than GitHub lists in one answer' $true) }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $files = New-Object System.Collections.Generic.List[object]
        foreach ($entry in @($entries)) {
            $path = [string](Get-ReviewField -Object $entry -Path 'path')
            $type = [string](Get-ReviewField -Object $entry -Path 'type')
            # Outside local-llm: not looked at, as it is not read from the download either.
            if ($path.Replace('\', '/').Split('/')[0] -ine 'local-llm') { continue }
            $shown = ConvertTo-ReviewText -Text $path -Max 80
            if ($path.Contains('\') -or -not (Test-PlainRepoPath -Path $path)) { return (& $no "under local-llm the commit holds a name Windows may store elsewhere than written: $shown" $true) }
            if (-not $seen.Add($path)) { return (& $no "under local-llm the commit holds two names that differ in capitals only: $shown" $true) }
            if ($type -ceq 'tree') { continue }
            $id = [string](Get-ReviewField -Object $entry -Path 'sha')
            $mode = [string](Get-ReviewField -Object $entry -Path 'mode')
            if ($type -cne 'blob' -or @('100644', '100755') -notcontains $mode) { return (& $no "under local-llm the commit holds an entry that is no plain file (a link or a submodule): $shown" $true) }
            if ($id -cnotmatch '^[0-9a-f]{40}\z') { return (& $no "its answer gives no git id for $shown" $false) }
            if ($path.StartsWith('local-llm/', [System.StringComparison]::Ordinal)) { $files.Add([pscustomobject]@{ Path = $path; Id = $id }) }
        }
        if ($files.Count -eq 0) { return (& $no 'the commit holds no file under local-llm' $true) }
        return [pscustomobject]@{ Files = $files.ToArray(); Why = ''; Lasting = $false }
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
        # -Parent: the folder is the one the new folder is made in. One rule is left out there: what
        # Program Files hands to CREATOR OWNER (S-1-3-0) in folders made later, inherit-only. It
        # names whoever makes a folder in it, and the other rules say who can do that. Every other
        # inherit-only rule counts as if it were for the folder itself: it decides who may write
        # into a folder made there, the one this step makes included (Windows sets Program Files
        # up with such rules for reading only, which pass). For the new folder itself every rule
        # counts.
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
            if (-not $r.Allow -or ($Parent -and $r.InheritOnly -and $sid -ceq 'S-1-3-0') -or $trusted -contains $sid) { continue }
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
        #   -Manifest       the files Get-TreeManifest lists for the review's commit; $null when
        #                   there are none (-ManifestError: why; -Lasting: the commit's own list is
        #                   what cannot be used, so asking again later changes nothing)
        # Returns Lines (Text, Color) to print under the review; Compare: the download is compared
        # with -Manifest; and Stop: when not empty, why this run ends here, before any question and
        # before any download. An update goes on only with a manifest. No answer from GitHub, an
        # answer that is cut off and one that cannot be read all stop it, and nothing turns that
        # into a go: no typed OK, no LOCALAI_REVIEWED_COMMIT. Whatever is not plainly a first
        # install counts as an update. Only a first install goes on without a manifest, and says
        # that its download cannot be compared with a reviewed commit. A review that says Stop
        # itself is left to the gate (Get-UpdateConsent), which stops it.
        param($Review, $Manifest, [string]$ManifestError, [bool]$Lasting)
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
        $stop = "GitHub's list of the files of this commit could not be used ($why), so the download could not be compared with the commit shown above. An update is never installed unchecked."
        # "Try again later" only where later can differ: not for a list that is what it is.
        if ($Lasting) { $stop += ' Trying again later changes nothing: it is the list of this commit itself that cannot be used, and it stays as it is. That needs a fix in the repository; a commit without the trouble (LOCALAI_REF takes its full id) installs as usual.' }
        else { $stop += " Try again later (GitHub's API answers 60 questions an hour for everyone behind one address)." }
        return [pscustomobject]@{ Stop = $stop; Compare = $false; Lines = $lines.ToArray() }
    }

    function Get-ToolkitEntry {
        # What one entry of the downloaded archive is, from its name as the archive has it
        # (-FullName) and the archive's top folder as seen so far (-Top: '' at the first entry).
        # GitHub's archive holds one top folder with the repository in it. Returns Top, and for a
        # file of the toolkit (one below <top>/local-llm, in whatever capitals) Path ('local-llm/...')
        # and Name (the whole name, with '/'). Path is '' for every other entry: a folder, and all
        # that lies outside local-llm. Those are neither read nor written, so their names decide
        # nothing and are not looked at: a letter outside ASCII in another folder of the repository
        # must not stop an install. Both readers of the archive go by this one rule
        # (Get-ArchiveFileList, Expand-ToolkitArchive), and Get-TreeManifest by the same.
        # An error (the caller stops) for: a top folder whose name is more than letters, digits and
        # . _ - or that Windows may store elsewhere than written, a second top folder or a file
        # beside it, and under local-llm any name Windows may store elsewhere than written
        # (Test-PlainRepoPath: no '..', no drive, no stream).
        param([string]$FullName, [string]$Top)
        # Compress-Archive of Windows PowerShell 5.1 writes '\' between the parts, GitHub '/'.
        $name = $FullName.Replace('\', '/')
        $isFolder = $name.EndsWith('/')
        if ($isFolder) { $name = $name.Substring(0, $name.Length - 1) }
        $parts = $name.Split('/')
        if (-not $Top) {
            $Top = $parts[0]
            # The top folder becomes a folder on this PC, in the path the installer is started from
            # with administrator rights, and no comparison covers its name (the digest lists paths
            # from local-llm down). GitHub makes it of the repository's name, a '-' and the commit
            # or the ref: letters, digits and . _ - are all it ever holds. A quote, a bracket, a
            # ';' or a space has no business in that path.
            if ($Top -cnotmatch '^[A-Za-z0-9._-]+\z' -or -not (Test-PlainRepoPath -Path $Top)) { throw "the archive's top folder has a name that is more than letters, digits and . _ - (GitHub names it after the repository and the commit): $(ConvertTo-ReviewText -Text $FullName -Max 120)" }
        }
        if ($parts[0] -cne $Top -or ($parts.Count -eq 1 -and -not $isFolder)) { throw 'the archive does not hold one top folder with everything in it' }
        $other = [pscustomobject]@{ Top = $Top; Path = ''; Name = '' }
        if ($parts.Count -lt 2 -or $parts[1] -ine 'local-llm') { return $other }
        if (-not (Test-PlainRepoPath -Path $name)) { throw "the archive holds a name Windows may store elsewhere than written: $(ConvertTo-ReviewText -Text $FullName -Max 120)" }
        if ($isFolder -or $parts.Count -lt 3) { return $other }
        return [pscustomobject]@{ Top = $Top; Path = ('local-llm/' + $name.Substring($parts[0].Length + $parts[1].Length + 2)); Name = $name }
    }

    function Get-ElevationRoute {
        # Where the step with administrator rights runs:
        #   'here'    in this window: it has administrator rights already (-Administrator) and is
        #             Windows PowerShell (-Edition 'Desktop'), which the step is written for. The
        #             installer's messages and its result then stay in this window, and no second
        #             window is opened that nobody asked for.
        #   'window'  in a window of its own that Windows is asked to start with administrator
        #             rights (Start-ElevatedWindow): every other case.
        # Neither answer is taken on trust by the step: it checks for itself that it has
        # administrator rights, and refuses without them.
        param([bool]$Administrator, [string]$Edition)
        if ($Administrator -and $Edition -ceq 'Desktop') { return 'here' }
        return 'window'
    }

    function Get-ElevatedFunctionList {
        # The functions of this file that the step with administrator rights is made of: it is
        # handed their text (Get-ElevatedStage), because that window has nothing else of this file.
        # Every function one of them calls has to be in this list too (the tests check that).
        return @('ConvertTo-ReviewText', 'Test-PlainRepoPath', 'Get-Sha256Hex', 'Get-GitBlobId', 'Get-ToolkitFileId', 'Get-ToolkitDigest', 'Test-AdminOnlyRule', 'Get-ToolkitEntry',
            'Get-ToolkitFileList', 'ConvertTo-FolderRule', 'Get-FolderRule', 'Get-AdminOnlySecurity', 'Set-AdminOnlyRule', 'Expand-ToolkitArchive', 'Copy-HandedOverArchive', 'Send-HandOverSignal', 'Remove-ToolkitTree', 'Invoke-ElevatedInstall')
    }

    function Get-ElevatedStage {
        # The text of the step that runs with administrator rights: the functions it is made of
        # (-Definitions: name and body of each, as this file defines them) and one line that calls
        # Invoke-ElevatedInstall. Every value in that line travels as base64 and is turned back by
        # the text itself, so no folder name, however it is spelled (a quote, a '$', a space), can
        # become part of the command.
        param([System.Collections.IDictionary]$Definitions, [string]$Zip, [string]$ZipHash, [string]$Digest, [string]$Commit, [string]$Root, [string[]]$Extra, [string]$Signal, [string]$SignalOwner)
        $value = { param([string]$Text) '(& $plain ''' + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)) + ''')' }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('$ErrorActionPreference = ''Stop''')
        $lines.Add('$ProgressPreference = ''SilentlyContinue''')
        foreach ($name in @($Definitions.Keys)) { $lines.Add('function ' + $name + ' {' + [string]$Definitions[$name] + '}') }
        $lines.Add('$plain = { param([string]$Text) [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Text)) }')
        $words = @($Extra | Where-Object { $_ } | ForEach-Object { & $value $_ }) -join ', '
        $lines.Add('Invoke-ElevatedInstall -Zip ' + (& $value $Zip) + ' -ZipHash ' + (& $value $ZipHash) + ' -Digest ' + (& $value $Digest) + ' -Commit ' + (& $value $Commit) + ' -Root ' + (& $value $Root) + ' -Signal ' + (& $value $Signal) + ' -SignalOwner ' + (& $value $SignalOwner) + ' -Extra @(' + $words + ')')
        return ($lines -join "`n")
    }

    function Get-ElevatedLauncher {
        # The command the window with administrator rights is started with: it reads the file with
        # the step's text (Get-ElevatedStage) once, and runs what it read only when its SHA-256 is
        # -Hash. The hash is part of the command Windows was asked to start with administrator
        # rights, where a program of the user can no longer change it; the file is in the user's
        # temp folder, where it can. A file that was changed or removed is refused: the command
        # says so and does no more than that. It removes nothing: the files in the temp folder are
        # left to the window that put them there, which is told that this one is done with them
        # (-Signal: the name of that window's signal; -SignalOwner: the account it must belong to,
        # as its SID. The rule is Send-HandOverSignal's: what the name opens is set only when it
        # belongs to that account, and closed untouched when not).
        # One line, without a double quote and without two spaces in a row: Start-Process hands its
        # arguments over joined by spaces, and powershell.exe puts the command together from the
        # pieces again. The path travels as base64 for the same reason.
        param([string]$StageFile, [string]$Hash, [string]$Signal, [string]$SignalOwner)
        $value = { param([string]$Text) "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)) + "'))" }
        $refuse = @(
            'Write-Host ''Stopped: the file that carries the step with administrator rights was changed or removed after this window was asked for (a program running under your Windows account can do that).'' -ForegroundColor Red'
            'Write-Host ''Nothing was installed or changed: your Local AI keeps working as it is.'' -ForegroundColor Yellow'
        )
        # A name made here holds letters, digits and '-' only, and a SID digits and '-' behind
        # 'S-1-'. With any other name, or without a SID, the signal is left out of the command.
        if ($Signal -cmatch '^[A-Za-z0-9-]{1,80}\z' -and $SignalOwner -cmatch '^S-1-[0-9-]{1,180}\z') {
            $refuse += ('try{$e=[Threading.EventWaitHandle]::OpenExisting(''' + $Signal + ''',[Security.AccessControl.EventWaitHandleRights]''Modify,Synchronize,ReadPermissions'');if($e.GetAccessControl().GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq ''' + $SignalOwner + '''){$null=$e.Set()};$e.Close()}catch{$e=$null}')
        }
        $steps = @(
            ('$f=' + (& $value $StageFile))
            '$b=[byte[]]@()'
            'try{$b=[IO.File]::ReadAllBytes($f)}catch{$b=[byte[]]@()}'
            '$h=[BitConverter]::ToString((New-Object Security.Cryptography.SHA256CryptoServiceProvider).ComputeHash($b)).Replace(''-'','''')'
            ('if($h -eq ''' + $Hash + '''){& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString($b)))}else{' + ($refuse -join ';') + '}')
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

    function Get-AdminOnlySecurity {
        # Owner and access rules of a folder only administrators can change: it belongs to
        # Administrators, SYSTEM and Administrators alone are let into it and into all that is made
        # in it, and nothing is inherited from the folder above.
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        $security.SetAccessRuleProtection($true, $false)
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $who = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($who, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)))
        }
        return $security
    }

    function Set-AdminOnlyRule {
        # Gives the folder -Path the owner and rules of Get-AdminOnlySecurity. Windows PowerShell
        # only, which is what the step with administrator rights runs in.
        param([string]$Path)
        (New-Object System.IO.DirectoryInfo($Path)).SetAccessControl((Get-AdminOnlySecurity))
    }

    function Expand-ToolkitArchive {
        # Unpacks the toolkit from the archive -Zip (as GitHub sends it: one top folder, local-llm in
        # it) into the folder -Destination and returns the top folder there. Only what lies under
        # local-llm is written (Get-ToolkitEntry): the rest of the archive is neither compared nor run.
        # Not Expand-Archive: this runs with administrator rights, and no name in the archive may
        # decide where a file lands. Every name that is written has to be one Windows stores as
        # written and to stay inside -Destination; no file is written over another; and no more
        # than -MaxBytes of unpacked content is taken. Anything else is an error, and the caller stops.
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
                $item = Get-ToolkitEntry -FullName ([string]$entry.FullName) -Top $top
                $top = $item.Top
                if (-not $item.Path) { continue }
                $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $item.Name.Replace('/', $separator)))
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

    function Get-ArchiveFileList {
        # The toolkit in the archive -Bytes (the download as it was read, once), without writing
        # anything: Files, a list of Path ('local-llm/...') and Id (Get-ToolkitFileId), which
        # Compare-ToolkitTree and Get-ToolkitDigest take; Version, the text of local-llm/VERSION
        # without the line break it ends in (and without a byte order mark, should an editor have
        # left one); and Top, the archive's top folder. The same entries Expand-ToolkitArchive
        # writes, by the same rule (Get-ToolkitEntry), so the first comparison needs no file in the
        # temp folder that a program of the user could rewrite between the unpacking and the reading.
        # A file that is in the archive twice, also under two names that differ in capitals only
        # (Windows keeps one of them), and more than -MaxBytes of content are errors.
        param([byte[]]$Bytes, [long]$MaxBytes = 268435456)
        if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
        Add-Type -AssemblyName System.IO.Compression
        $top = ''
        $version = ''
        $total = [long]0
        $buffer = New-Object byte[] 65536
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $files = New-Object System.Collections.Generic.List[object]
        $stream = New-Object System.IO.MemoryStream(, $Bytes)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($stream)
            try {
                foreach ($entry in $archive.Entries) {
                    $item = Get-ToolkitEntry -FullName ([string]$entry.FullName) -Top $top
                    $top = $item.Top
                    if (-not $item.Path) { continue }
                    if (-not $seen.Add($item.Path)) { throw "the archive holds a file twice: $(ConvertTo-ReviewText -Text $item.Path -Max 120)" }
                    $content = New-Object System.IO.MemoryStream
                    try {
                        $from = $entry.Open()
                        try {
                            $read = $from.Read($buffer, 0, $buffer.Length)
                            while ($read -gt 0) {
                                $total += $read
                                if ($total -gt $MaxBytes) { throw 'the archive unpacks to far more than a toolkit holds' }
                                $content.Write($buffer, 0, $read)
                                $read = $from.Read($buffer, 0, $buffer.Length)
                            }
                        } finally { $from.Dispose() }
                        $fileBytes = $content.ToArray()
                    } finally { $content.Dispose() }
                    $files.Add([pscustomobject]@{ Path = $item.Path; Id = (Get-ToolkitFileId -Path $item.Path -Bytes $fileBytes) })
                    # Trimmed here, where it is read: the file ends in a line break, and the text is
                    # made printable before it is shown (ConvertTo-ReviewText), which would turn
                    # that line break into a '?' behind the version.
                    if ($item.Path -ceq 'local-llm/VERSION') { $version = [System.Text.Encoding]::UTF8.GetString($fileBytes).TrimStart([char]0xFEFF).Trim() }
                }
            } finally { $archive.Dispose() }
        } finally { $stream.Dispose() }
        if (-not $top) { throw 'the archive is empty' }
        return [pscustomobject]@{ Top = $top; Version = $version; Files = $files.ToArray() }
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

    function Copy-HandedOverArchive {
        # Copies the archive -From (in the user's temp folder) to -To (in the step's own folder) and
        # returns the SHA-256 of the bytes that were written, as Get-Sha256Hex gives it. The file is
        # opened once and read to its end through that one handle, so what was hashed is what was
        # copied, whatever a program of the user does to the name meanwhile; no more than -MaxBytes
        # is taken (the file is whatever such a program left there). Nothing is written or removed
        # in the temp folder.
        param([string]$From, [string]$To, [long]$MaxBytes = 268435456)
        $buffer = New-Object byte[] 65536
        $total = [long]0
        $sha = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
        try {
            $source = New-Object System.IO.FileStream($From, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            try {
                $target = New-Object System.IO.FileStream($To, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try {
                    $read = $source.Read($buffer, 0, $buffer.Length)
                    while ($read -gt 0) {
                        $total += $read
                        if ($total -gt $MaxBytes) { throw 'the archive in the temp folder is far larger than a toolkit: it is not the download that was compared' }
                        [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
                        $target.Write($buffer, 0, $read)
                        $read = $source.Read($buffer, 0, $buffer.Length)
                    }
                } finally { $target.Dispose() }
            } finally { $source.Dispose() }
            [void]$sha.TransformFinalBlock($buffer, 0, 0)
            return ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
    }

    function New-HandOverSignal {
        # The signal the window with administrator rights sets when it needs the two files in the
        # temp folder no longer (Send-HandOverSignal): an event of Windows with the name -Name, made
        # here and waited for by Start-ElevatedWindow. It is made to belong to the account that runs
        # this (-Owner, its SID as text): the other window sets a signal only when it finds that
        # owner on it, and left to itself Windows hands what an administrator's window makes to
        # the group Administrators on some systems. That account and Administrators may set it and
        # read whom it belongs to: the administrator rights may be those of another account (a
        # standard user who types an administrator's password at the prompt of Windows). $null when
        # it cannot be made; the files then stay until the next run.
        param([string]$Name, [string]$Owner)
        try {
            $account = New-Object System.Security.Principal.SecurityIdentifier($Owner)
            $security = New-Object System.Security.AccessControl.EventWaitHandleSecurity
            $security.SetOwner($account)
            $rights = [System.Security.AccessControl.EventWaitHandleRights]'Modify, Synchronize, ReadPermissions'
            foreach ($who in @($account, (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
                $security.AddAccessRule((New-Object System.Security.AccessControl.EventWaitHandleAccessRule($who, $rights, [System.Security.AccessControl.AccessControlType]::Allow)))
            }
            $madeNew = $false
            return (New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $Name, [ref]$madeNew, $security))
        } catch { $null = $_ }
        # Without an owner and rules of its own (PowerShell 7 has no such constructor): it is what
        # Windows makes of it. Where that is not this account's, the other window leaves it alone,
        # and the files stay until the next run.
        try { return (New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $Name)) } catch { return $null }
    }

    function Send-HandOverSignal {
        # Tells the window that asked for administrator rights that the two files it put in the
        # temp folder are needed no longer: it sets that window's signal (New-HandOverSignal). That
        # window then removes its files, with its own rights; nothing in the temp folder is
        # removed with administrator rights. The signal carries no trust and nothing is read from it.
        # The signal is found by its name, and the name alone must not decide what is set: when
        # the window that made the signal is gone (a program of the user can end it), the name is
        # free, and such a program can make it stand for another signal of Windows, one that only
        # administrators may set. So what the name opened is looked at before it is touched, and it
        # is set only when it belongs to the account that asked (-Owner, that account's SID). The
        # question is put to the signal that was opened, not to the name a second time, so nothing
        # can change between the look and the setting. A signal of that account is one a program
        # of that account can set without this step; any other is closed again as it was found.
        # No signal (no name, no owner, a name that is none, a window that is gone, a signal that
        # is somebody else's) is no error: the files then stay until the next run.
        param([string]$Name, [string]$Owner)
        if ($Name -cnotmatch '^[A-Za-z0-9-]{1,80}\z' -or $Owner -cnotmatch '^S-1-[0-9-]{1,180}\z') { return }
        try {
            $rights = [System.Security.AccessControl.EventWaitHandleRights]'Modify, Synchronize, ReadPermissions'
            $handle = [System.Threading.EventWaitHandle]::OpenExisting($Name, $rights)
            try {
                $belongsTo = $handle.GetAccessControl().GetOwner([System.Security.Principal.SecurityIdentifier])
                if ($null -ne $belongsTo -and ([string]$belongsTo.Value) -ceq $Owner) { [void]$handle.Set() }
            } finally { $handle.Dispose() }
        } catch { $null = $_ }
    }

    function Invoke-ElevatedInstall {
        # The step that runs with administrator rights (the threat model stands above
        # Get-Sha256Hex). It is handed the downloaded archive (-Zip, in the user's temp folder), the
        # SHA-256 that file had when it was compared (-ZipHash) and the digest the files under
        # local-llm must have (-Digest), and takes nothing from the temp folder on trust. In this
        # order, and every "no" ends the step before the installer starts:
        #   1. Program Files itself must be a folder only administrators can change, also in what
        #      it hands down to folders made in it.
        #   2. What an earlier run left there is removed, and the folder LocalAI-Update is made anew,
        #      with its owner and rules in the same call: it never has the rules of the folder above.
        #      (Not Program Files\LocalAI: the installer keeps its copy for the resume after a
        #      restart there, and removes that folder when it runs from anywhere else.)
        #   3. Owner and rules are set once more and read back: Administrators and SYSTEM alone.
        #      The folder must be a folder, and empty: nothing was put into it by anyone else.
        #   4. The archive is copied in, and the copy must have the SHA-256 -ZipHash. A copy that
        #      has not is not opened.
        #   5. It is unpacked there; it must hold one top folder.
        #   6. The digest of what was unpacked must be -Digest.
        #   7. Only then: COMMIT is written next to the installer, which records it, and the
        #      installer is started from that folder, by the full path of Windows PowerShell.
        # At the end, whatever happened, the folder is removed again. In the temp folder this step
        # removes nothing: it tells the window that put the files there, and that window removes
        # them (-Signal and -SignalOwner: that window's signal and the account it must belong to,
        # see Send-HandOverSignal). It tells it once: when it has its copy, or at its end when it
        # never got that far.
        param([string]$Zip, [string]$ZipHash, [string]$Digest, [string]$Commit, [string]$Root, [string[]]$Extra, [string]$Signal, [string]$SignalOwner)
        # Windows is asked where its folders are: a variable of this session could name others.
        $programFiles = [Environment]::GetFolderPath('ProgramFiles')
        $shell = [System.IO.Path]::Combine([Environment]::GetFolderPath('System'), 'WindowsPowerShell', 'v1.0', 'powershell.exe')
        $stage = [System.IO.Path]::Combine($programFiles, 'LocalAI-Update')
        $lockFile = [System.IO.Path]::Combine($stage, 'in-use')
        $lock = $null
        $made = $false
        $started = $false
        $told = $false
        try {
            Write-Host 'Checking the download once more, in a folder only administrators can change...' -ForegroundColor Cyan
            if ($ZipHash -cnotmatch '^[0-9a-f]{64}\z' -or $Digest -cnotmatch '^[0-9a-f]{64}\z' -or ($Commit -and $Commit -cnotmatch '^[0-9a-f]{40}\z')) { throw 'this step was not told what the download has to be' }
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
            # Made with its owner and rules in one call: at no moment does it have the rules Program
            # Files hands down, so nobody else can put anything into it before it is closed. Then set
            # once more and read back: what counts is what the folder has, not what was asked for.
            [void][System.IO.Directory]::CreateDirectory($stage, (Get-AdminOnlySecurity))
            Set-AdminOnlyRule -Path $stage
            $stageWhy = Test-AdminOnlyRule -Rule (Get-FolderRule -Path $stage)
            if ($stageWhy) { throw "$stage could not be made a folder only administrators can change: $stageWhy" }
            $stageFolder = New-Object System.IO.DirectoryInfo($stage)
            if ($stageFolder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "$stage is a link, not a folder" }
            # A folder somebody else made first (the call above then made none), or put something
            # into, is not used: a folder in it could have another owner than this one.
            if (@($stageFolder.GetFileSystemInfos()).Count -ne 0) { throw "$stage is not empty right after it was made: something else put files into it" }
            $lock = New-Object System.IO.FileStream($lockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $zipCopy = [System.IO.Path]::Combine($stage, 'download.zip')
            $copied = Copy-HandedOverArchive -From $Zip -To $zipCopy
            # From here on nothing more is read from the temp folder: the window that put the files
            # there may remove them. It is told now and not again: once it has heard, it is done
            # with its signal, and the name is then nobody's.
            Send-HandOverSignal -Name $Signal -Owner $SignalOwner
            $told = $true
            if ($copied -cne $ZipHash) { throw 'the archive in the temp folder is not the download that was compared: it was changed after the comparison' }
            $top = Expand-ToolkitArchive -Zip $zipCopy -Destination $stage
            $found = Get-ToolkitDigest -Files (Get-ToolkitFileList -Top $top)
            if ($found -cne $Digest) { throw 'the files that were unpacked are not the files that were compared' }
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
            # After a refusal that came before the copy the files are needed no longer either, and
            # the first window has not been told yet.
            if (-not $told) { Send-HandOverSignal -Name $Signal -Owner $SignalOwner }
        }
    }

    function Start-ElevatedWindow {
        # Starts the step with administrator rights in a window of its own (Windows asks once) and
        # waits, at most -WaitSeconds, until that window says that it needs the files in the temp
        # folder no longer. The step's functions as this file defines them and the values of this
        # run are written to -StageFile; the window that reads it is started with the SHA-256 the
        # file must have (Get-ElevatedStage, Get-ElevatedLauncher). Windows PowerShell by its full
        # path: no folder on the PATH decides what gets the administrator rights.
        # Returns Started ($false: there is no such window, Why says what Windows answered: 'No' at
        # its prompt lands here) and Taken (the window has read both files: they can go).
        param([string]$Zip, [string]$StageFile, [string]$ZipHash, [string]$Digest, [string]$Commit, [string]$Root, [string[]]$Extra, [int]$WaitSeconds = 120)
        $signalName = 'LocalAI-Update-' + [guid]::NewGuid().ToString('N')
        # The account that asks, by its SID: the signal is made to belong to it, and the other
        # window is told so in the step's text and on its command line. Without it the other
        # window sets nothing, and the files stay until the next run.
        $asker = ''
        try { $asker = [string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $asker = '' }
        $signal = New-HandOverSignal -Name $signalName -Owner $asker
        try {
            $definitions = [ordered]@{}
            foreach ($name in (Get-ElevatedFunctionList)) { $definitions[$name] = [string](Get-Command -Name $name -CommandType Function).Definition }
            $stageBytes = [System.Text.Encoding]::UTF8.GetBytes((Get-ElevatedStage -Definitions $definitions -Zip $Zip -ZipHash $ZipHash -Digest $Digest -Commit $Commit -Root $Root -Extra $Extra -Signal $signalName -SignalOwner $asker))
            [System.IO.File]::WriteAllBytes($StageFile, $stageBytes)
            $launcher = Get-ElevatedLauncher -StageFile $StageFile -Hash (Get-Sha256Hex -Bytes $stageBytes) -Signal $signalName -SignalOwner $asker
            $shell = [System.IO.Path]::Combine([Environment]::GetFolderPath('System'), 'WindowsPowerShell', 'v1.0', 'powershell.exe')
            # -NoExit: the window stays open with the installer's messages, as the installer's own does.
            try { Start-Process -FilePath $shell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', $launcher) -ErrorAction Stop }
            catch { return [pscustomobject]@{ Started = $false; Taken = $false; Why = [string]$_.Exception.Message } }
            # Windows has started the window (the click on Yes is behind us): it reads the step's
            # text at once and copies the archive a moment later.
            $taken = $false
            if ($signal) { try { $taken = [bool]$signal.WaitOne($WaitSeconds * 1000) } catch { $taken = $false } }
            return [pscustomobject]@{ Started = $true; Taken = $taken; Why = '' }
        } finally { if ($signal) { $signal.Dispose() } }
    }

    function Install-ToolkitDownload {
        # All that follows the review and the typed OK: the download (-Url, built from the commit
        # that was shown), the first comparison, and the step with administrator rights.
        #   -Ref, -Commit      what was shown: for the messages, and for the installer to record
        #   -Manifest          the commit's list of files; -Compare: the download is held against it
        #   -Zip, -StageFile   the two files this run puts in the temp folder: the download, and
        #                      the step's text for a window of its own
        #   -OldFolder         where earlier versions of this file unpacked the download, and left it
        #   -Route             Get-ElevationRoute's answer: the step runs 'here' or in a 'window'
        # The downloaded file is read once. Everything this function does afterwards it does with
        # those bytes: their SHA-256, the list of the toolkit's files in them, the comparison. Nothing
        # is unpacked in the temp folder, and the step is told the SHA-256 the file must have.
        # Whatever happens, nothing of this run stays behind in the temp folder: the two files are
        # removed here, with the rights this window has. One exception, and it is said: a window
        # with administrator rights that was started and has not said in time that it has read
        # them. They are then left for it, and the next run removes them first thing.
        param([string]$Url, [string]$Ref, [string]$Commit, $Manifest, [bool]$Compare, [string]$Zip, [string]$StageFile, [string]$OldFolder, [string]$Root, [string[]]$Extra, [string]$Route, [int]$WaitSeconds = 120)
        $leave = $false
        $removeOwn = {
            foreach ($own in @($Zip, $StageFile)) {
                try { if ([System.IO.File]::Exists($own)) { [System.IO.File]::Delete($own) } } catch { $null = $_ }
            }
        }
        try {
            # What an earlier run left: its two files, and the folder older versions unpacked into.
            & $removeOwn
            try { Remove-ToolkitTree -Path $OldFolder } catch { $null = $_ }
            Write-Host "Downloading installer ($Ref$(if ($Commit) { ', commit ' + $Commit.Substring(0, 7) }))..." -ForegroundColor Cyan
            try { Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing }
            catch {
                Write-Host "The download failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "Nothing was changed: your Local AI keeps working as it is. Check the internet connection and run the command again; to repair the installed copy instead, double-click $Root\Scripts\Install-LocalAI.cmd." -ForegroundColor Yellow
                return
            }
            $zipBytes = $null; $archive = $null; $readError = ''
            try {
                if ((New-Object System.IO.FileInfo($Zip)).Length -gt 268435456) { throw 'it is far larger than a toolkit' }
                # The one read of the downloaded file.
                $zipBytes = [System.IO.File]::ReadAllBytes($Zip)
                $archive = Get-ArchiveFileList -Bytes $zipBytes
            } catch { $readError = $_.Exception.Message; if (-not $readError) { $readError = 'no reason given' } }
            if ($readError) {
                Write-Host "Stopped: the download could not be read as an archive of the toolkit ($(ConvertTo-ReviewText -Text $readError -Max 300 -AllowUnicode))." -ForegroundColor Red
                Write-Host 'Nothing was installed or changed: your Local AI keeps working as it is.' -ForegroundColor Yellow
                return
            }
            $zipHash = Get-Sha256Hex -Bytes $zipBytes
            $files = $archive.Files
            # The first comparison, before Windows is asked for administrator rights: what arrived has to
            # be the commit that was shown. The step with administrator rights compares again.
            if ($Compare) {
                $differences = Compare-ToolkitTree -Manifest $Manifest -Files $files
                if ($differences.Count) {
                    Write-Host "Stopped: what was downloaded is not commit $Commit as GitHub lists it ($($differences.Count) difference(s) under local-llm):" -ForegroundColor Red
                    foreach ($difference in @($differences | Select-Object -First 10)) { Write-Host "  $(ConvertTo-ReviewText -Text $difference -Max 150)" -ForegroundColor Red }
                    if ($differences.Count -gt 10) { Write-Host "  ... and $($differences.Count - 10) more" -ForegroundColor Red }
                    Write-Host 'Nothing was installed or changed: your Local AI keeps working as it is. Run the command again; a download that is refused again should not be installed by hand either.' -ForegroundColor Yellow
                    return
                }
                $digest = Get-ToolkitDigest -Files $Manifest
            } else {
                # A first install without a list of the commit's files: there is nothing to compare
                # with. What is installed is the archive as it was read above, and no other.
                $digest = Get-ToolkitDigest -Files $files
            }
            if (@($files | Where-Object { $_.Path -ceq 'local-llm/Install-LocalAI.ps1' }).Count -ne 1) {
                Write-Host 'Stopped: the download holds no installer (Install-LocalAI.ps1 under local-llm).' -ForegroundColor Red
                Write-Host 'Nothing was installed or changed: your Local AI keeps working as it is.' -ForegroundColor Yellow
                return
            }
            $what = "Installing Local AI toolkit $(ConvertTo-ReviewText -Text $archive.Version -Max 40)$(if ($Commit) { ' (commit ' + $Commit.Substring(0, 7) + ')' })."
            if ($Route -ceq 'here') {
                Write-Host "$what This window has administrator rights already: the installer runs here." -ForegroundColor Cyan
                Invoke-ElevatedInstall -Zip $Zip -ZipHash $zipHash -Digest $digest -Commit $Commit -Root $Root -Extra $Extra
                return
            }
            Write-Host "$what Windows asks for administrator rights next." -ForegroundColor Cyan
            $handOver = Start-ElevatedWindow -Zip $Zip -StageFile $StageFile -ZipHash $zipHash -Digest $digest -Commit $Commit -Root $Root -Extra $Extra -WaitSeconds $WaitSeconds
            if (-not $handOver.Started) {
                Write-Host ''
                Write-Host 'Administrator rights were declined; run the command again and click Yes.' -ForegroundColor Red
                Write-Host "($(ConvertTo-ReviewText -Text $handOver.Why -Max 200 -AllowUnicode))" -ForegroundColor DarkGray
                Write-Host 'Nothing was installed or changed: your Local AI keeps working as it is.' -ForegroundColor Yellow
                return
            }
            Write-Host ''
            Write-Host 'The installer continues in the Administrator window that opened.' -ForegroundColor Cyan
            if (-not $handOver.Taken) {
                $leave = $true
                Write-Host "That window has not said within $WaitSeconds seconds that it has read the two files this one put in the temp folder for it. They are left there ($Zip and $StageFile); the next run of this command removes them." -ForegroundColor Yellow
            }
        } finally {
            if (-not $leave) { & $removeOwn }
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
    # Downloaded into the user's temp folder, read from there once and not unpacked there: nothing
    # is run from it. The installer is started by the step with administrator rights, from its own
    # folder under Program Files (Invoke-ElevatedInstall); for a window of its own that step is
    # handed over as text in $stageFile. $dest is where earlier versions of this file unpacked the
    # download and left it: it is only removed. The installer copies itself into AI\Scripts (and,
    # before a reboot, into Program Files\LocalAI for the resume).
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
    # A list that cannot be used says why, and whether asking again later can change that.
    $manifest = $null; $manifestError = ''; $manifestLasting = $false
    if ($review.Commit) {
        try {
            $listing = Get-TreeManifest -Tree (ConvertFrom-ReviewJson -Text (Get-GitHubText -Uri "https://api.github.com/repos/$repo/git/trees/$($review.Commit)?recursive=1" -Accept 'application/vnd.github+json'))
            $manifest = $listing.Files
            if ($null -eq $manifest) { $manifestError = $listing.Why; $manifestLasting = $listing.Lasting }
        } catch { $manifest = $null; $manifestError = $_.Exception.Message; if (-not $manifestError) { $manifestError = 'no answer' } }
    }
    $check = Get-DownloadCheck -Review $review -Manifest $manifest -ManifestError $manifestError -Lasting $manifestLasting
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

    # A window that has administrator rights already runs the step itself; any other asks Windows
    # for a window that has them. The step makes sure of its rights either way.
    $administrator = $false
    try { $administrator = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $administrator = $false }
    $route = Get-ElevationRoute -Administrator $administrator -Edition ([string]$PSVersionTable.PSEdition)
    Install-ToolkitDownload -Url $url -Ref $ref -Commit $commit -Manifest $manifest -Compare $check.Compare -Zip $zip -StageFile $stageFile -OldFolder $dest -Root $root -Extra $extra -Route $route
}
