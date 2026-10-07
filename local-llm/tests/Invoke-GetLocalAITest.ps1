<#
.SYNOPSIS
    Get-LocalAI.ps1's update review: what the bootstrap shows and asks before it starts the installer.

.DESCRIPTION
    Needs no network, Docker, Ollama or Open WebUI; runs on PowerShell 7 and Windows PowerShell 5.1.
    - The decisions are pure functions inside Get-LocalAI.ps1. They are read out of the file with the
      parser (the bootstrap itself is not run) and fed GitHub's answers as JSON written here: a first
      install, an update, a repair run, a comparison that failed or cannot be read, an install whose
      commit is unknown or that sits in another folder, an older or diverged commit, a long or cut-off
      file list, file names Windows stores elsewhere than git says, hostile text, the typed answer.
    - GitHub's API not answering (its hourly limit): the commit is read from its page in patch form,
      shown and asked about. An update whose commit neither can name stops without a question; a
      first install goes on.
    - GitHub's answers as text of more than 2 million characters, and as the dictionaries the second
      JSON reader of Windows PowerShell 5.1 yields.
    - The one way to skip the question (LOCALAI_REVIEWED_COMMIT naming the incoming commit in full),
      and that nothing else does: no other value, no fetched text, no other variable.
    - The bootstrap's own flow, read from its syntax tree: the ref is checked before GitHub is asked,
      one question, before the one download and the one request for administrator rights; the
      installer is started in one place only, in the step that has those rights, after its checks.
    - The gate (Get-UpdateConsent) with a stand-in for the keyboard: only an OK typed after the review
      goes on; no keyboard, an error, a piped-in OK or an unreadable review does not.
    - What is installed is the commit that was shown: git's id of a file, the one line-end rule
      (.cmd), GitHub's list of a commit's files (and every answer that is not used as one), a
      download that differs in one byte, holds a file the list does not or lacks one, an update
      without that list, the rules of a folder only administrators can change (as data), the text
      and the command the step with administrator rights is handed, archives with names that would
      land outside the folder they are unpacked into.
    - Windows only: the whole bootstrap in a child process, started the way 'irm | iex' starts it,
      with GitHub replaced by stand-ins and a stand-in installer in the archive. With nobody to type
      OK, or with an OK piped in, nothing is downloaded and no installer starts; with the reviewed
      commit named, the commit that was shown is the one downloaded, recorded and run. Every trace of
      an install the bootstrap looks for (in the AI folder, and the all-users Start-menu folder
      outside it, which is created for that run and removed again) makes it ask; a ref that is no
      plain name reaches neither GitHub nor the download.
      The request for administrator rights is a stand-in too (the test machine's user is an
      administrator already): it starts the same command line and waits. The step behind it is the
      real one: it makes its folder under Program Files of the test machine, runs the stand-in
      installer from there and removes the folder again. A download that is not the commit, an
      archive swapped in the temp folder after the first comparison and a changed step are refused;
      a real folder that Users may modify does not pass the check of its rules; no run leaves
      anything in the temp folder or under Program Files.
    Exit code = number of failed assertions.
#>
param([string]$Work = (Join-Path ([System.IO.Path]::GetTempPath()) 'lai-getlocalai-test'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# The Windows part starts the bootstrap for real (with stand-ins): only on a throwaway test machine.
if (-not (& (Join-Path $PSScriptRoot 'Assert-LaiSandbox.ps1'))) { exit 99 }
$src = Split-Path -Parent $PSScriptRoot
$onWindows = ($env:OS -eq 'Windows_NT')
$failures = 0
function Assert-That([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "  ASSERT OK   $Message" -ForegroundColor Green }
    else { Write-Host "  ASSERT FAIL $Message" -ForegroundColor Red; $script:failures++ }
}
function Skip([string]$Message) { Write-Host "  SKIP        $Message" -ForegroundColor DarkGray }

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) on $(if ($onWindows) { 'Windows' } else { 'non-Windows' })"
$childExe = 'pwsh'
if ($PSVersionTable.PSEdition -eq 'Desktop') { $childExe = 'powershell.exe' }

# ---- the review functions, straight out of the bootstrap ------------------------------------------
Write-Host "`n=== Get-LocalAI.ps1: the review functions ===" -ForegroundColor Cyan
$bootstrap = Join-Path $src 'Get-LocalAI.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($bootstrap, [ref]$tokens, [ref]$parseErrors)
$fnAsts = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$wanted = @('ConvertTo-ReviewText', 'Get-ReviewField', 'ConvertTo-ReviewBody', 'ConvertFrom-ReviewJson', 'Get-PatchCommit', 'ConvertTo-ReviewDate', 'ConvertTo-ReviewCount', 'Get-CommitSummary', 'Test-ToolkitRef', 'Test-DirectCommitRef', 'Get-IncomingCommit',
    'Get-InstalledToolkit', 'Test-PlainRepoPath', 'Get-ChangedFileGroup', 'Get-ChangedFileReport', 'Get-UpdateReview', 'Test-UpdateAnswer', 'Get-UpdateConsent',
    'Get-Sha256Hex', 'Get-GitBlobId', 'Get-ToolkitFileId', 'Get-TreeManifest', 'Compare-ToolkitTree', 'Get-ToolkitDigest', 'Test-AdminOnlyRule', 'Get-DownloadCheck', 'Get-ElevatedFunctionList', 'Get-ElevatedStage', 'Get-ElevatedLauncher',
    'Get-ToolkitFileList', 'ConvertTo-FolderRule', 'Get-FolderRule', 'Set-AdminOnlyRule', 'Expand-ToolkitArchive', 'Remove-ToolkitTree', 'Remove-HandedOverFile', 'Invoke-ElevatedInstall')
$have = @($fnAsts | ForEach-Object { $_.Name })
$missing = @($wanted | Where-Object { $have -notcontains $_ })
$haveFunctions = (@($parseErrors).Count -eq 0 -and $missing.Count -eq 0)
Assert-That $haveFunctions "Get-LocalAI.ps1 parses and defines the review functions (missing: $($missing -join ', '))"
# Only the function definitions are loaded: nothing of the bootstrap runs here.
if ($haveFunctions) { . ([scriptblock]::Create((@($fnAsts | ForEach-Object { $_.Extent.Text }) -join "`n"))) }

function New-GitHubCommit {
    # A commit as GitHub's API answers, through the JSON parser of the PowerShell that runs this test
    # (7 turns the date into a DateTime, 5.1 leaves it text: the bootstrap has to read both).
    param([string]$Sha, [string]$Date, [string]$Message)
    $json = ConvertTo-Json -Depth 6 -InputObject @{ sha = $Sha; commit = @{ message = $Message; committer = @{ name = 'A Committer'; date = $Date } } }
    return (ConvertFrom-Json -InputObject $json)
}
function New-GitHubCompare {
    # GitHub's "compare two commits" answer, cut down to the fields the review reads.
    param([string]$Status, [int]$Ahead, [int]$Behind, $Base, [object[]]$Files)
    $json = ConvertTo-Json -Depth 8 -InputObject @{ status = $Status; ahead_by = $Ahead; behind_by = $Behind; total_commits = $Ahead; base_commit = $Base; files = $Files }
    return (ConvertFrom-Json -InputObject $json)
}
function ConvertTo-TestDictionary($Value) {
    # A hashtable tree as the dictionaries and arrays .NET's JSON reader yields (the second reader of
    # ConvertFrom-ReviewJson on Windows PowerShell 5.1), built by hand so that it runs everywhere.
    if ($Value -is [System.Collections.IDictionary]) {
        $d = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        foreach ($k in @($Value.Keys)) { $d[[string]$k] = ConvertTo-TestDictionary $Value[$k] }
        return $d
    }
    if ($Value -is [array]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($v in $Value) { $list.Add((ConvertTo-TestDictionary $v)) }
        return , $list.ToArray()
    }
    return $Value
}
function Get-ReviewText($Review) { return (@($Review.Lines | ForEach-Object { $_.Text }) -join "`n") }
function Get-LineIndex([string]$Text, [string]$Pattern) {
    # Index of the first line of -Text that matches -Pattern; -1 when none does.
    $all = @($Text -split "`n")
    for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i] -match $Pattern) { return $i } }
    return -1
}
function Get-ShownCommit($Review) {
    # The commit id on the review's "To install" line; '' when it shows none.
    $m = [regex]::Match((Get-ReviewText $Review), 'To install\s+: commit ([0-9a-f]{40})\b')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function New-TreeEntry([string]$Path, [string]$Id = ('a' * 40), [string]$Mode = '100644', [string]$Type = 'blob') {
    # One entry of GitHub's "get a tree" answer: a file (blob), a folder (tree) or a submodule (commit).
    return @{ path = $Path; mode = $Mode; type = $Type; sha = $Id; size = 1 }
}
function New-TreeAnswer([object[]]$Entries, $Truncated = $false) {
    # GitHub's answer to git/trees/<commit>?recursive=1, through the JSON parser of this PowerShell.
    $json = ConvertTo-Json -Depth 6 -InputObject @{ sha = ('f' * 40); truncated = $Truncated; tree = $Entries }
    return (ConvertFrom-Json -InputObject $json)
}
function New-TestRule([string]$Sid, $Rights, [switch]$Deny, [switch]$InheritOnly) {
    # One access rule of a folder as Get-FolderRule hands it over: it allows unless -Deny is given.
    return [pscustomobject]@{ Sid = $Sid; Rights = $Rights; Allow = (-not $Deny); InheritOnly = [bool]$InheritOnly }
}
function Copy-TestTable($Table) {
    # A table of path and bytes once more, so that one file in it can be changed.
    $copy = [ordered]@{}
    foreach ($key in @($Table.Keys)) { $copy[$key] = $Table[$key] }
    return $copy
}
function Get-TestFileList($Table) {
    # What Get-ToolkitFileList makes of unpacked files, from a table of path and bytes.
    $list = @($Table.Keys | ForEach-Object { [pscustomobject]@{ Path = [string]$_; Id = (Get-ToolkitFileId -Path ([string]$_) -Bytes $Table[$_]) } })
    return , $list
}
function New-TestZip([string]$Path, [object[]]$Entries) {
    # An archive with exactly these entries (Name, Text), under the names as given: the archive
    # cmdlets would not write a name that climbs out of its folder.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($item in $Entries) {
                $entry = $archive.CreateEntry([string]$item.Name)
                $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$item.Text)
                $writer = $entry.Open()
                try { $writer.Write($bytes, 0, $bytes.Length) } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

$repo = 'example-owner/example-repo'
$shaOld = '1a2b3c4d5e' * 4
$shaNew = '9f8e7d6c5b' * 4
$shaOther = '0123456789' * 4
$esc = [string][char]27

if ($haveFunctions) {
    Write-Host "`n=== the typed answer ===" -ForegroundColor Cyan
    $yes = @('OK', 'ok', 'Ok', ' OK ', "OK`t")
    Assert-That (@($yes | Where-Object { -not (Test-UpdateAnswer -Answer $_) }).Count -eq 0) 'OK in any case, with spaces around it, is consent'
    $no = @('', ' ', 'y', 'Y', 'yes', 'okay', 'OK please', 'O K', 'k', 'no', '0', 'true', "OK`nOK")
    $wrong = @($no | Where-Object { Test-UpdateAnswer -Answer $_ })
    Assert-That ($wrong.Count -eq 0) "Enter alone, y, yes and everything else is not ($($wrong.Count) wrongly accepted)"
    Assert-That (-not (Test-UpdateAnswer -Answer $null) -and -not (Test-UpdateAnswer -Answer $true) -and -not (Test-UpdateAnswer -Answer 1) -and -not (Test-UpdateAnswer -Answer @('OK'))) 'no answer at all (no console, an error while reading) is not consent, nor is anything that is not typed text'

    Write-Host "`n=== what is installed now ===" -ForegroundColor Cyan
    $configText = ConvertTo-Json -InputObject @{ AIRoot = 'C:\AI'; WebUIPort = 3000; ToolkitVersion = '2026.10.05'; ToolkitCommit = $shaOld; updated = '2026-10-05T10:00:00' }
    $known = Get-InstalledToolkit -ConfigText $configText -OtherSigns $true
    Assert-That ($known.State -eq 'known' -and $known.Commit -eq $shaOld -and $known.Version -eq '2026.10.05') "the installer's localai-config.json gives version and commit ($($known.State), $($known.Version))"
    $none = Get-InstalledToolkit -ConfigText $null -OtherSigns $false
    Assert-That ($none.State -eq 'none') 'no config file and no other trace of an install: nothing is installed'
    $half = Get-InstalledToolkit -ConfigText $null -OtherSigns $true
    Assert-That ($half.State -eq 'unknown' -and $half.Why -match 'did not finish') "no config file but other traces (an install that did not finish): an install whose commit is unknown, not 'nothing installed' ($($half.State))"
    $handZip = Get-InstalledToolkit -ConfigText (ConvertTo-Json -InputObject @{ ToolkitVersion = '2026.10.05'; ToolkitCommit = '' }) -OtherSigns $true
    Assert-That ($handZip.State -eq 'unknown' -and $handZip.Version -eq '2026.10.05' -and $handZip.Why -match 'names no commit') 'a config without a commit (a ZIP installed by hand): unknown, and it says so'
    $damaged = @('', '   ', '{"ToolkitCommit": "1a2b', '[1, 2]', '"text"', 'null')
    $states = @($damaged | ForEach-Object { (Get-InstalledToolkit -ConfigText $_ -OtherSigns $false).State })
    Assert-That (@($states | Where-Object { $_ -ne 'unknown' }).Count -eq 0) "a damaged or empty config is an install whose commit is unknown, never 'nothing installed' ($($states -join ', '))"
    # The recorded commit ends up in the address GitHub is asked about: only a full id may get there.
    $tampered = @(($shaOld + '/../../other/repo'), $shaOld.Substring(0, 39), ($shaOld + '0'), "$shaOld`n$shaOther", ('../' + $shaOld.Substring(3)), 'main')
    $accepted = @($tampered | Where-Object { (Get-InstalledToolkit -ConfigText (ConvertTo-Json -InputObject @{ ToolkitCommit = $_ }) -OtherSigns $true).State -eq 'known' })
    Assert-That ($accepted.Count -eq 0) "anything but a 40-character commit id in the config is not taken as the installed commit ($($accepted.Count) accepted)"
    $odd = Get-InstalledToolkit -ConfigText (ConvertTo-Json -InputObject @{ ToolkitVersion = ('1' + $esc + '[2J'); ToolkitCommit = $shaOld.ToUpperInvariant() }) -OtherSigns $true
    Assert-That ($odd.State -eq 'known' -and $odd.Commit -eq $shaOld -and $odd.Version -eq '') 'an upper-case id is the same commit; a version with control characters is not shown'
    # The command in the README does not know the AI folder: an install in another one must not pass
    # for a first install. The installer's Start-menu folder is there wherever the AI folder is.
    $elsewhere = Get-InstalledToolkit -ConfigText $null -OtherSigns $false -StartMenu $true
    Assert-That ($elsewhere.State -eq 'unknown' -and $elsewhere.Elsewhere -eq $true -and $elsewhere.Why -match 'another folder') "an empty AI folder while the installer's Start-menu folder exists: an install in another folder, not 'nothing installed' ($($elsewhere.State))"
    $menuToo = @((Get-InstalledToolkit -ConfigText $configText -OtherSigns $true -StartMenu $true), (Get-InstalledToolkit -ConfigText $null -OtherSigns $true -StartMenu $true), (Get-InstalledToolkit -ConfigText '' -OtherSigns $false -StartMenu $true))
    Assert-That ($menuToo[0].State -eq 'known' -and $menuToo[1].Why -match 'did not finish' -and $menuToo[2].Why -match 'could not be read' -and @($menuToo | Where-Object { $_.Elsewhere }).Count -eq 0 -and -not $none.Elsewhere) 'with a trace of an install in the AI folder itself, the Start-menu folder changes nothing'

    Write-Host "`n=== the ref: a plain name, and whether it names a commit directly ===" -ForegroundColor Cyan
    # LOCALAI_REF goes into the addresses GitHub is asked for; .NET folds '..' parts away, so
    # zip/../../../other/repo/zip/main would be fetched from another repository than the one shown.
    $goodRefs = @('main', 'v2026.10.05', 'claude/item-update-review', 'refs/heads/main', 'feature_x', $shaNew, $shaNew.Substring(0, 7))
    $badRefs = @('', '../../../other/repo/zip/main', 'main/../../x', 'a..b', './main', 'main/.', '/main', 'main/', 'a//b', 'main?x=1', 'main#x', 'main x', "main`n", 'main%2e%2e', 'main\x', ('m' * 201), ('ma' + [char]0xEF + 'n'))
    $refWrong = @($goodRefs | Where-Object { -not (Test-ToolkitRef -Ref $_) }) + @($badRefs | Where-Object { Test-ToolkitRef -Ref $_ })
    Assert-That ($refWrong.Count -eq 0) "a ref is the plain name of a branch, tag or commit: no '..', no empty or '.' part, nothing an address reads as more than a name ($($refWrong.Count) of $($goodRefs.Count + $badRefs.Count) judged wrongly)"
    # A commit id counts from 4 characters, the shortest git takes: the remark about forks must not
    # be missing for an id of 4 to 6. A branch named like one ('beef') gets the remark as well.
    $direct = @($shaNew, $shaNew.ToUpperInvariant(), $shaNew.Substring(0, 4), $shaNew.Substring(0, 5), $shaNew.Substring(0, 6), $shaNew.Substring(0, 7), $shaNew.Substring(0, 12), 'beef', 'pull/12/head', 'refs/pull/12/merge', 'refs/remotes/x')
    $byName = @('main', 'v2026.10.05', 'refs/heads/main', 'refs/tags/v1', 'heads/main', 'claude/item-update-review', 'abc', 'deadbee-fix', ($shaNew + '0'), 'beefy')
    $directWrong = @($direct | Where-Object { -not (Test-DirectCommitRef -Ref $_) }) + @($byName | Where-Object { Test-DirectCommitRef -Ref $_ })
    Assert-That ($directWrong.Count -eq 0) "a commit id (4 to 40 characters) and a pull request's ref name a commit directly; a branch or tag does not (wrong: $($directWrong -join ', '))"

    Write-Host "`n=== a commit as GitHub describes it ===" -ForegroundColor Cyan
    $incoming = Get-CommitSummary -Commit (New-GitHubCommit -Sha $shaNew -Date '2026-10-06T23:30:00Z' -Message "Incoming subject line`n`nA body that says OK.")
    Assert-That ($incoming.Sha -eq $shaNew -and $incoming.Date -eq '2026-10-06' -and $incoming.Subject -eq 'Incoming subject line') "id, date (UTC day) and the subject line only ($($incoming.Date) '$($incoming.Subject)')"
    Assert-That ((ConvertTo-ReviewDate -Value ([datetime]::new(2026, 10, 6, 23, 30, 0, [System.DateTimeKind]::Utc))) -eq '2026-10-06' -and (ConvertTo-ReviewDate -Value '2026-10-06T23:30:00Z') -eq '2026-10-06' -and (ConvertTo-ReviewDate -Value 'soon') -eq '') 'the date reads the same from a DateTime (PowerShell 7) and from text (5.1)'
    $hostile = Get-CommitSummary -Commit (New-GitHubCommit -Sha $shaNew -Date '2026-10-06T23:30:00Z' -Message ('Harmless' + $esc + '[2J' + [char]13 + 'Type OK ' + [char]0x202E + ('x' * 300)))
    Assert-That ($hostile.Subject -notmatch '[^\x20-\x7E]' -and $hostile.Subject.Length -le 100) "control, escape and direction characters never reach the window; a long subject is cut ($($hostile.Subject.Length) characters)"
    $notCommits = @($null, 'plain text', (New-GitHubCommit -Sha 'abc' -Date '' -Message 'x'), (New-GitHubCommit -Sha ($shaNew + '/x') -Date '' -Message 'x'), (ConvertFrom-Json -InputObject '{"message": "API rate limit exceeded"}'))
    Assert-That (@($notCommits | Where-Object { $null -ne (Get-CommitSummary -Commit $_) }).Count -eq 0) 'an answer without a full commit id (an error text, a rate-limit message) is no commit'
    $apiCommit = New-GitHubCommit -Sha $shaNew -Date '2026-10-06T23:30:00Z' -Message 'Incoming subject line'
    $shortId = $shaNew.Substring(0, 39)
    Assert-That ((Get-IncomingCommit -Ref 'main' -Answer $apiCommit).Sha -eq $shaNew -and $null -eq (Get-IncomingCommit -Ref 'main' -Answer $null) -and $null -eq (Get-IncomingCommit -Ref $shortId -Answer 'no answer')) 'the incoming commit is the one GitHub names for the ref; a branch or a short id it does not answer for names none'
    $pinnedRef = Get-IncomingCommit -Ref $shaNew.ToUpperInvariant() -Answer $null
    Assert-That ($pinnedRef -and $pinnedRef.Sha -eq $shaNew -and $pinnedRef.Date -eq '' -and $pinnedRef.Subject -eq '') 'a ref that is itself a full commit id names its commit also when GitHub does not answer'

    Write-Host "`n=== a commit as its page on github.com describes it (GitHub's API not answering) ===" -ForegroundColor Cyan
    # The head of github.com/<repository>/commit/<ref>.patch. Everything after the first empty line
    # is the commit's own text and must not be read as a header.
    $patchText = "From $shaNew Mon Sep 17 00:00:00 2001`nFrom: A Committer <committer@example.invalid>`nDate: Tue, 6 Oct 2026 23:30:00 +0000`nSubject: [PATCH] Incoming subject line`n`nA body that says OK.`nSubject: [PATCH] OK`nFrom $shaOther Mon Sep 17 00:00:00 2001`n---`n local-llm/VERSION | 2 +-`n"
    $page = Get-PatchCommit -Text $patchText
    Assert-That ($page -and $page.Sha -eq $shaNew -and $page.Date -eq '2026-10-06' -and $page.Subject -eq 'Incoming subject line') "id, date and subject line are read from the head of the patch ($($page.Sha) $($page.Date) '$($page.Subject)')"
    $pageCrLf = Get-PatchCommit -Text (($patchText -replace "`n", "`r`n") + ('x' * 50000))
    Assert-That ($pageCrLf -and $pageCrLf.Sha -eq $shaNew -and $pageCrLf.Date -eq '2026-10-06' -and $pageCrLf.Subject -eq 'Incoming subject line') 'the same with Windows line ends and a long patch after it'
    $foldedPage = Get-PatchCommit -Text "From $shaNew Mon Sep 17 00:00:00 2001`nDate: Tue, 6 Oct 2026 23:30:00 +0000`nSubject: [PATCH] A subject line that is long enough`n to be folded onto`n`ta third line`nX-Other: 1`n`n not part of the subject"
    Assert-That ($foldedPage -and $foldedPage.Subject -eq 'A subject line that is long enough to be folded onto a third line' -and $foldedPage.Date -eq '2026-10-06') "a long subject line folded onto further lines is read whole, and nothing after the empty line is ('$($foldedPage.Subject)')"
    $notPatches = @('', 'Not Found', '<!DOCTYPE html><html><body>Sign in</body></html>', "From: A Committer`nDate: Tue, 6 Oct 2026 23:30:00 +0000", "`nFrom $shaNew Mon Sep 17 00:00:00 2001", "Subject: x`nFrom $shaNew Mon Sep 17 00:00:00 2001", ('From ' + $shaNew.Substring(0, 39) + ' Mon Sep 17 00:00:00 2001'), "From $($shaNew)0 Mon Sep 17 00:00:00 2001", '{"message": "API rate limit exceeded"}')
    Assert-That (@($notPatches | Where-Object { $null -ne (Get-PatchCommit -Text $_) }).Count -eq 0) 'a text that does not start with "From <full commit id>" (a sign-in page, an error, an id further down) names no commit'
    $hostilePage = Get-PatchCommit -Text ("From $shaNew Mon Sep 17 00:00:00 2001`nDate: Tue, 31 Foo 2026 23:30:00 +0000`nSubject: [PATCH 1/2] Harmless" + $esc + '[2J' + [char]0x202E + ('x' * 300) + "`n`n")
    Assert-That ($hostilePage.Sha -eq $shaNew -and $hostilePage.Date -eq '' -and $hostilePage.Subject -like 'Harmless*' -and $hostilePage.Subject -notmatch '[^\x20-\x7E]' -and $hostilePage.Subject.Length -le 100) "its subject line is cleaned and cut like any other; a date that is none stays empty ($($hostilePage.Subject.Length) characters)"
    $viaPage = Get-IncomingCommit -Ref 'main' -Answer $null -PatchText $patchText
    Assert-That ($viaPage -and $viaPage.Sha -eq $shaNew -and $viaPage.Subject -eq 'Incoming subject line' -and $null -eq (Get-IncomingCommit -Ref 'main' -Answer $null -PatchText 'Not Found')) "a branch GitHub's API does not answer for is named by its page; a page that names no commit leaves it unnamed"
    $apiWins = Get-IncomingCommit -Ref 'main' -Answer (New-GitHubCommit -Sha $shaOld -Date '2026-10-05T10:00:00Z' -Message 'From the API') -PatchText $patchText
    Assert-That ($apiWins.Sha -eq $shaOld -and $apiWins.Subject -eq 'From the API') "when the API answers, its commit is the one: the page is not looked at"
    $idWins = Get-IncomingCommit -Ref $shaOther -Answer $null -PatchText $patchText
    $idDescribed = Get-IncomingCommit -Ref $shaNew.ToUpperInvariant() -Answer $null -PatchText $patchText
    Assert-That ($idWins.Sha -eq $shaOther -and $idWins.Date -eq '' -and $idWins.Subject -eq '' -and $idDescribed.Sha -eq $shaNew -and $idDescribed.Date -eq '2026-10-06') 'a ref that is a full commit id is never replaced by what a page says: the page only adds date and subject line when it is about that id'

    Write-Host "`n=== GitHub's answers: long ones, and the two shapes they are read into ===" -ForegroundColor Cyan
    Assert-That ((ConvertTo-ReviewBody -Content 'text') -eq 'text' -and (ConvertTo-ReviewBody -Content ([System.Text.Encoding]::UTF8.GetBytes('{"sha": "x"}'))) -eq '{"sha": "x"}' -and (ConvertTo-ReviewBody -Content $null) -eq '' -and (ConvertTo-ReviewBody -Content 5) -eq '') 'the body of an answer is text, whether it arrives as text or as bytes; anything else is no text'
    $notJson = @('', 'Not Found', '<html>', '{"status": "ahead", "files": [')
    Assert-That (@($notJson | Where-Object { $null -ne (ConvertFrom-ReviewJson -Text $_) }).Count -eq 0) 'a text that is not JSON is no answer (and no error either: the review then says that it could not be read)'
    # A comparison across many commits: a patch for every file. More than 2 million characters is
    # where Invoke-RestMethod of Windows PowerShell 5.1 stops reading (it hands back the text).
    $bigNames = @('local-llm/tests/big-000.ps1', 'local-llm/stack/docker-compose.yml') + @(1..117 | ForEach-Object { 'local-llm/tests/big-{0:d3}.ps1' -f $_ }) + @('local-llm/Install-LocalAI.ps1')
    $bigJson = New-Object System.Text.StringBuilder
    [void]$bigJson.Append('{"status":"ahead","ahead_by":250,"behind_by":0,"total_commits":250,"base_commit":{"sha":"' + $shaOld + '","commit":{"message":"Installed subject line","committer":{"date":"2026-10-05T10:00:00Z"}}},"files":[')
    $bigPatch = 'x' * 20000
    for ($i = 0; $i -lt $bigNames.Count; $i++) {
        if ($i) { [void]$bigJson.Append(',') }
        [void]$bigJson.Append('{"filename":"' + $bigNames[$i] + '","status":"modified","patch":"' + $bigPatch + '"}')
    }
    [void]$bigJson.Append(']}')
    $bigText = $bigJson.ToString()
    $bigIncoming = Get-CommitSummary -Commit (New-GitHubCommit -Sha $shaNew -Date '2026-10-06T23:30:00Z' -Message 'Incoming subject line')
    $bigInstalled = Get-InstalledToolkit -ConfigText (ConvertTo-Json -InputObject @{ ToolkitVersion = '2026.10.05'; ToolkitCommit = $shaOld }) -OtherSigns $true
    $bigReview = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $bigInstalled -Incoming $bigIncoming -Compare (ConvertFrom-ReviewJson -Text $bigText)
    $bigReviewText = Get-ReviewText $bigReview
    Assert-That ($bigText.Length -gt 2200000 -and $bigReview.Kind -eq 'update' -and $bigReview.NeedsOk -and $bigReviewText -match '250 commit\(s\), 120 file\(s\) differ' -and $bigReviewText -notmatch 'could not be') "a comparison of $($bigText.Length) characters is read on this PowerShell: 250 commits, 120 files ($($bigReview.Kind))"
    Assert-That ($bigReviewText -match '2026-10-05\s+Installed subject line' -and (Get-LineIndex -Text $bigReviewText -Pattern 'local-llm/Install-LocalAI\.ps1') -gt 0 -and (Get-LineIndex -Text $bigReviewText -Pattern 'local-llm/Install-LocalAI\.ps1') -lt (Get-LineIndex -Text $bigReviewText -Pattern 'stack/docker-compose\.yml') -and $bigReviewText -match '118 file\(s\), not listed') 'and its file list is the usual one: the installer first, then the stack, the tests counted'
    # The same answers as dictionaries and arrays (what .NET's reader yields) give the same review,
    # letter for letter, as the objects ConvertFrom-Json yields.
    $shapeFiles = @(
        @{ filename = 'local-llm/tests/Invoke-Some.ps1'; status = 'added' }
        @{ filename = 'local-llm/Install-LocalAI.ps1'; status = 'modified' }
        @{ filename = 'local-llm/Moved-Here.ps1'; previous_filename = 'local-llm/tests/Was-There.ps1'; status = 'renamed' }
    )
    $shapeCompare = @{ status = 'ahead'; ahead_by = 3; behind_by = 0; base_commit = @{ sha = $shaOld; commit = @{ message = 'Installed subject line'; committer = @{ date = '2026-10-05T10:00:00Z' } } }; files = $shapeFiles }
    $shapeCommit = @{ sha = $shaNew; commit = @{ message = "Incoming subject line`n`nbody"; committer = @{ date = '2026-10-06T23:30:00Z' } } }
    $asObjects = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $bigInstalled -Incoming (Get-CommitSummary -Commit (ConvertFrom-Json -InputObject (ConvertTo-Json -Depth 8 -InputObject $shapeCommit))) -Compare (ConvertFrom-Json -InputObject (ConvertTo-Json -Depth 8 -InputObject $shapeCompare))
    $dictCommit = Get-CommitSummary -Commit (ConvertTo-TestDictionary $shapeCommit)
    $asDictionaries = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $bigInstalled -Incoming $dictCommit -Compare (ConvertTo-TestDictionary $shapeCompare)
    Assert-That ($dictCommit -and $dictCommit.Sha -eq $shaNew -and $dictCommit.Date -eq '2026-10-06' -and $dictCommit.Subject -eq 'Incoming subject line') 'a commit read into dictionaries gives id, date and subject line'
    Assert-That ((Get-ReviewText $asObjects) -match '3 commit\(s\), 3 file\(s\) differ' -and (Get-ReviewText $asObjects) -match 'Was-There\.ps1 -> local-llm/Moved-Here\.ps1' -and (Get-ReviewText $asDictionaries) -ceq (Get-ReviewText $asObjects) -and $asDictionaries.Kind -eq 'update' -and $asDictionaries.NeedsOk) 'a comparison read into dictionaries and arrays gives the same review as one read into objects'
    $dictProbe = ConvertTo-TestDictionary @{ a = @{ b = 'deep' }; list = @(1, 2); none = @() }
    Assert-That ((Get-ReviewField -Object $dictProbe -Path 'a', 'b') -eq 'deep' -and $null -eq (Get-ReviewField -Object $dictProbe -Path 'a', 'missing') -and $null -eq (Get-ReviewField -Object $dictProbe -Path 'Count') -and (Get-ReviewField -Object $dictProbe -Path 'list').Count -eq 2) "a dictionary is read by its keys only: a missing key is nothing, and its own members (Count) are no answer"
    Assert-That ($null -ne (Get-ReviewField -Object $dictProbe -Path 'none') -and (Get-ReviewField -Object $dictProbe -Path 'none').Count -eq 0) 'an empty list in a dictionary comes back as an empty list, not as a missing key'
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        # The reader itself, as ConvertFrom-ReviewJson falls back to it on Windows PowerShell 5.1.
        Add-Type -AssemblyName System.Web.Extensions
        $netReader = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $netReader.MaxJsonLength = [int]::MaxValue
        $netCompare = $netReader.DeserializeObject($bigText)
        $netReview = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $bigInstalled -Incoming $bigIncoming -Compare $netCompare
        Assert-That ($netCompare -is [System.Collections.IDictionary] -and (Get-ReviewText $netReview) -ceq $bigReviewText) "Windows PowerShell 5.1: the long comparison read by .NET's reader gives the same review ($($netCompare.GetType().Name))"
    } else {
        Skip "the long comparison through .NET's JSON reader (Windows PowerShell 5.1 only: the Windows job runs this)"
    }

    Write-Host "`n=== which changed files matter ===" -ForegroundColor Cyan
    $admin = @('local-llm/Install-LocalAI.ps1', 'local-llm/lib/LocalAI.psm1', 'local-llm/lib/anything.txt', 'local-llm/Install-LocalAI.cmd', 'local-llm/Some-Script.ps1', 'local-llm/new-folder/Tool.PS1', 'local-llm/stack/helper.exe', 'local-llm\lib\LocalAI.psm1')
    $toolkit = @('local-llm/stack/compose-part.yml', 'local-llm/config/models.psd1', 'local-llm/skills/a/SKILL.md', 'local-llm/VERSION', 'local-llm/README.md')
    $other = @('local-llm/tests/Invoke-Some.ps1', 'local-llm/docs/NOTES.md', 'local-llm/IMPROVEMENTS.md', 'README.md', 'another-folder/run.ps1', '.github/workflows/ci.yml', 'LOCAL-LLM/docs/NOTES.md')
    $bad = @($admin | Where-Object { (Get-ChangedFileGroup -Path $_) -ne 'admin' }) + @($toolkit | Where-Object { (Get-ChangedFileGroup -Path $_) -ne 'toolkit' }) + @($other | Where-Object { (Get-ChangedFileGroup -Path $_) -ne 'other' })
    Assert-That ($bad.Count -eq 0) "installer, module and toolkit scripts run (or can be started) as administrator; stack and config are installed; tests, docs and other folders are not (wrong: $($bad -join ', '))"
    Assert-That ((Get-ChangedFileGroup -Path 'local-llm/Tests/Sneaky.ps1') -eq 'admin') "only the exact tests and docs folders count as not installed (a script in 'Tests' is listed with the administrator scripts)"
    # The archive is unpacked on Windows, and the bootstrap then starts local-llm\Install-LocalAI.ps1
    # whatever its capitals. Names git takes for another file and Windows for the same one: other
    # capitals, a '.', '..' or empty part, a trailing dot or space, a stream (':'), a short 8.3 name,
    # anything outside printable ASCII, and an entry without a name. None of them is "not installed".
    $sameOnWindows = @('Local-LLM/Install-LocalAI.ps1', 'LOCAL-LLM/lib/x.psm1', 'local-llm/LIB/anything.txt', 'local-llm/tests\..\Install-LocalAI.ps1', 'local-llm/tests/../Install-LocalAI.ps1', 'local-llm/docs/./../Install-LocalAI.ps1',
        'local-llm/Install-LocalAI.ps1.', 'local-llm/Install-LocalAI.ps1 ', 'local-llm /Install-LocalAI.ps1', 'local-llm./Install-LocalAI.ps1', 'local-llm//Install-LocalAI.ps1', '/local-llm/Install-LocalAI.ps1',
        'local-llm/Install-LocalAI.ps1::$DATA', 'local-llm/tests/x.txt:Install-LocalAI.ps1', 'LOCAL-~1/INSTAL~1.PS1', 'local-llm/tests/INSTAL~1', ('local-llm/tests/x' + [char]0xE9 + '.txt'), "local-llm/tests/x`t.txt", '')
    $missed = @($sameOnWindows | Where-Object { (Get-ChangedFileGroup -Path $_) -ne 'admin' })
    Assert-That ($missed.Count -eq 0) "a name that Windows stores as (or over) another file is listed with the administrator scripts, never as 'not installed' (missed: $($missed -join ' | '))"
    $plainWrong = @($sameOnWindows | Select-Object -Skip 3 | Where-Object { Test-PlainRepoPath -Path $_ }) + @(@($admin + $toolkit + $other) | Where-Object { -not (Test-PlainRepoPath -Path $_) })
    Assert-That ($plainWrong.Count -eq 0) "and all but a change of capitals is called an unusual name; an ordinary path is not ($($plainWrong.Count) judged wrongly)"

    $base = New-GitHubCommit -Sha $shaOld -Date '2026-10-05T10:00:00Z' -Message 'Installed subject line'
    $fewFiles = @(
        @{ filename = 'local-llm/tests/Invoke-Some.ps1'; status = 'added' }
        @{ filename = 'local-llm/Some-Script.ps1'; status = 'modified' }
        @{ filename = 'local-llm/stack/compose-part.yml'; status = 'modified' }
        @{ filename = 'local-llm/lib/LocalAI.psm1'; status = 'modified' }
        @{ filename = 'local-llm/Install-LocalAI.ps1'; status = 'modified' }
        @{ filename = 'local-llm/Moved-Here.ps1'; previous_filename = 'local-llm/tests/Was-There.ps1'; status = 'renamed' }
        @{ filename = 'docs/old-notes.md'; status = 'removed' }
    )
    $few = Get-ChangedFileReport -Files (New-GitHubCompare -Status 'ahead' -Ahead 3 -Behind 0 -Base $base -Files $fewFiles).files
    $fewText = Get-ReviewText $few
    $shownAll = @($fewFiles | Where-Object { $fewText -notmatch [regex]::Escape($_.filename) }).Count -eq 0
    Assert-That ($few.Total -eq 7 -and $few.Admin -eq 4 -and -not $few.Long -and $shownAll) "a short list names every file ($($few.Total) files, $($few.Admin) that run as administrator)"
    $iInstaller = Get-LineIndex -Text $fewText -Pattern 'local-llm/Install-LocalAI\.ps1'
    $iModule = Get-LineIndex -Text $fewText -Pattern 'local-llm/lib/LocalAI\.psm1'
    $iScript = Get-LineIndex -Text $fewText -Pattern 'local-llm/Some-Script\.ps1'
    $iStack = Get-LineIndex -Text $fewText -Pattern 'compose-part\.yml'
    $iTest = Get-LineIndex -Text $fewText -Pattern 'tests/Invoke-Some\.ps1'
    Assert-That ($iInstaller -ge 0 -and $iInstaller -lt $iModule -and $iModule -lt $iScript -and $iScript -lt $iStack -and $iStack -lt $iTest) "administrator scripts come first (installer, module, other scripts), then the stack, then what is not installed ($iInstaller, $iModule, $iScript, $iStack, $iTest)"
    Assert-That ($fewText -match 'renamed\s+local-llm/tests/Was-There\.ps1 -> local-llm/Moved-Here\.ps1' -and $fewText -match 'new\s+local-llm/tests/Invoke-Some\.ps1' -and $fewText -match 'removed\s+docs/old-notes\.md') 'each file says what happened to it; a script moved out of the tests folder shows both names'

    $manyFiles = @($fewFiles | Where-Object { $_.filename -ne 'local-llm/Moved-Here.ps1' -and $_.filename -ne 'local-llm/stack/compose-part.yml' -and $_.filename -notlike '*tests*' -and $_.filename -notlike 'docs*' })
    foreach ($n in 1..20) { $manyFiles += @{ filename = ('local-llm/stack/part-{0:d2}.yml' -f $n); status = 'modified' } }
    foreach ($n in 1..37) { $manyFiles += @{ filename = ('local-llm/tests/case-{0:d2}.ps1' -f $n); status = 'added' } }
    $many = Get-ChangedFileReport -Files (New-GitHubCompare -Status 'ahead' -Ahead 9 -Behind 0 -Base $base -Files $manyFiles).files -MaxListed 10
    $manyText = Get-ReviewText $many
    $stackShown = @([regex]::Matches($manyText, 'local-llm/stack/part-\d\d\.yml')).Count
    Assert-That ($many.Total -eq 60 -and $many.Long -and -not $many.Cut -and $many.Admin -eq 3) "a long list is counted ($($many.Total) files, $($many.Admin) that run as administrator)"
    Assert-That ($manyText -match 'local-llm/Install-LocalAI\.ps1' -and $manyText -match 'local-llm/lib/LocalAI\.psm1' -and $manyText -match 'local-llm/Some-Script\.ps1' -and (Get-LineIndex -Text $manyText -Pattern 'Install-LocalAI\.ps1') -lt (Get-LineIndex -Text $manyText -Pattern 'part-\d\d\.yml')) 'and still names every administrator script, first'
    Assert-That ($stackShown -eq 20 -and $manyText -notmatch 'more, not listed' -and $manyText -notmatch 'case-\d\d\.ps1' -and $manyText -match '37 file\(s\), not listed') "then every other installed file by name ($stackShown of 20): only what is not installed is reduced to a count"
    # Padding must not push an installed file off the screen: 20 scripts with a one-line change each
    # used to leave room for five more names, and the stack's compose file (images, published ports,
    # mounted folders) sorts last.
    $paddedFiles = @(1..20 | ForEach-Object { @{ filename = ('local-llm/Script-{0:d2}.ps1' -f $_); status = 'modified' } })
    foreach ($n in @('local-llm/README.md', 'local-llm/VERSION', 'local-llm/config/models.psd1', 'local-llm/config/system-prompt.txt', 'local-llm/skills/a/SKILL.md', 'local-llm/stack/docker-compose.yml', 'local-llm/tests/one.ps1')) { $paddedFiles += @{ filename = $n; status = 'modified' } }
    $padded = Get-ChangedFileReport -Files (New-GitHubCompare -Status 'ahead' -Ahead 1 -Behind 0 -Base $base -Files $paddedFiles).files
    $paddedText = Get-ReviewText $padded
    $paddedMissing = @($paddedFiles | Where-Object { $_.filename -notlike '*tests*' -and $paddedText -notmatch [regex]::Escape($_.filename) })
    Assert-That ($padded.Long -and $padded.Admin -eq 20 -and $paddedMissing.Count -eq 0 -and $paddedText -notmatch 'more, not listed' -and $paddedText -match '1 file\(s\), not listed') "a list padded with 20 changed scripts still names every installed file, docker-compose.yml included ($($paddedMissing.Count) missing)"
    $iCompose = Get-LineIndex -Text $paddedText -Pattern 'stack/docker-compose\.yml'
    $iConfig = Get-LineIndex -Text $paddedText -Pattern 'config/models\.psd1'
    Assert-That ($iCompose -ge 0 -and $iCompose -lt $iConfig -and $iConfig -lt (Get-LineIndex -Text $paddedText -Pattern 'local-llm/README\.md') -and $iConfig -lt (Get-LineIndex -Text $paddedText -Pattern 'skills/a/SKILL\.md')) 'among the other installed files the stack comes first, then the config, then the rest'
    $noAdmin = Get-ChangedFileReport -Files (New-GitHubCompare -Status 'ahead' -Ahead 1 -Behind 0 -Base $base -Files @(@{ filename = 'local-llm/VERSION'; status = 'modified' })).files
    Assert-That ($noAdmin.Total -eq 1 -and $noAdmin.Admin -eq 0 -and (Get-ReviewText $noAdmin) -match 'none of them differ') 'a change without administrator scripts says so (a one-file list stays a list on 5.1)'
    # A file that was moved counts for the stricter of its two names: the installer moved into a
    # folder whose name differs only in capitals is still the installer on Windows; a script moved
    # out of the toolkit is a script that is gone; the compose file moved away is an installed file.
    $movedFiles = @(
        @{ filename = 'local-llm/tests/a.txt'; previous_filename = 'local-llm/tests/b.txt'; status = 'renamed' }
        @{ filename = 'docs/compose.md'; previous_filename = 'local-llm/stack/docker-compose.yml'; status = 'renamed' }
        @{ filename = 'local-llm/tests/Parked.txt'; previous_filename = 'local-llm/Watch-LocalAI.ps1'; status = 'renamed' }
        @{ filename = 'Local-LLM/Install-LocalAI.ps1'; previous_filename = 'local-llm/Install-LocalAI.ps1'; status = 'renamed' }
        @{ filename = 'local-llm/tests\..\Install-LocalAI.ps1'; status = 'added' }
    )
    $moved = Get-ChangedFileReport -Files (New-GitHubCompare -Status 'ahead' -Ahead 1 -Behind 0 -Base $base -Files $movedFiles).files
    $movedText = Get-ReviewText $moved
    $iHead = Get-LineIndex -Text $movedText -Pattern 'Scripts that run as administrator'
    $iToolkitHead = Get-LineIndex -Text $movedText -Pattern 'Other toolkit files'
    $iOtherHead = Get-LineIndex -Text $movedText -Pattern 'Not installed on this PC'
    Assert-That ($moved.Admin -eq 3 -and $movedText -notmatch 'none of them differ' -and (Get-LineIndex -Text $movedText -Pattern 'local-llm/Install-LocalAI\.ps1 -> Local-LLM/Install-LocalAI\.ps1') -eq ($iHead + 1)) "the installer moved into 'Local-LLM' is listed first among the administrator scripts, not as a file that is not installed ($($moved.Admin) administrator scripts)"
    $iParked = Get-LineIndex -Text $movedText -Pattern 'Watch-LocalAI\.ps1 -> local-llm/tests/Parked\.txt'
    $iMovedCompose = Get-LineIndex -Text $movedText -Pattern 'stack/docker-compose\.yml -> docs/compose\.md'
    Assert-That ($iParked -gt $iHead -and $iParked -lt $iToolkitHead -and $iMovedCompose -gt $iToolkitHead -and $iMovedCompose -lt $iOtherHead -and (Get-LineIndex -Text $movedText -Pattern 'tests/b\.txt -> local-llm/tests/a\.txt') -gt $iOtherHead) 'a moved file counts for the stricter of its two names (a script moved into tests, the compose file moved into docs, a test renamed)'
    Assert-That (@($movedText -split "`n" | Where-Object { $_ -match 'unusual name' }).Count -eq 1 -and $movedText -match 'local-llm/tests\\\.\.\\Install-LocalAI\.ps1\s+\(unusual name') "and a name Windows may store elsewhere ('tests\..\Install-LocalAI.ps1') says so on its line"
    # GitHub's list stops at 300 files. Whatever sorts after the 300th is not in it, so a list of that
    # length cannot say that no administrator script differs.
    $cutNone = Get-ChangedFileReport -Files (New-GitHubCompare -Status 'ahead' -Ahead 1 -Behind 0 -Base $base -Files @(1..6 | ForEach-Object { @{ filename = ('.github/pad/{0:d3}.txt' -f $_); status = 'added' } })).files -ListLimit 6
    $cutNoneText = Get-ReviewText $cutNone
    Assert-That ($cutNone.Cut -and $cutNoneText -notmatch 'none of them differ' -and @($cutNone.Lines | Where-Object { $_.Text -match 'can start: not known' -and $_.Text -match 'may be among those not listed' -and $_.Color -eq 'Yellow' }).Count -eq 1) 'a list as long as GitHub lists at most: whether an administrator script differs is not known, said in yellow, never "none of them differ"'
    Assert-That ((Get-LineIndex -Text $cutNoneText -Pattern 'at most 6 files') -eq 0 -and @($cutNone.Lines)[0].Color -eq 'Yellow') 'and the notice that the list is cut off stands above it'
    $cutSome = Get-ChangedFileReport -Files (New-GitHubCompare -Status 'ahead' -Ahead 1 -Behind 0 -Base $base -Files (@($fewFiles | Select-Object -First 5) + @(@{ filename = 'docs/x.md'; status = 'added' }))).files -ListLimit 6
    Assert-That ($cutSome.Cut -and (Get-ReviewText $cutSome) -match 'more may be among the files it did not list' -and (Get-ReviewText $cutSome) -match 'local-llm/Install-LocalAI\.ps1') 'with administrator scripts in the listed part they are named, and more are said to be possible'
    $notCut = Get-ChangedFileReport -Files (New-GitHubCompare -Status 'ahead' -Ahead 1 -Behind 0 -Base $base -Files @(1..5 | ForEach-Object { @{ filename = ('.github/pad/{0:d3}.txt' -f $_); status = 'added' } })).files -ListLimit 6
    Assert-That (-not $notCut.Cut -and (Get-ReviewText $notCut) -match 'none of them differ' -and (Get-ReviewText $notCut) -notmatch 'at most') 'one file short of that length the list is complete and says so'
    $reports = @($few, $many, $padded, $moved, $cutNone, $cutSome, $notCut, $noAdmin)
    Assert-That (@($reports | ForEach-Object { $_.Lines } | Where-Object { @('Gray', 'Yellow') -notcontains $_.Color -or $_.Text -isnot [string] -or -not $_.Text }).Count -eq 0) 'every line of a file list is text with a colour the console knows'

    Write-Host "`n=== the review: first install, update, repair ===" -ForegroundColor Cyan
    $compare = New-GitHubCompare -Status 'ahead' -Ahead 3 -Behind 0 -Base $base -Files $fewFiles
    $first = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $none -Incoming $incoming
    $firstText = Get-ReviewText $first
    Assert-That ($first.Kind -eq 'first' -and -not $first.NeedsOk -and $firstText -match 'First install' -and $firstText -match 'nothing to compare' -and $firstText -match $shaNew) 'a first install says there is nothing to compare, shows the commit and does not ask'
    $update = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -Compare $compare
    $updateText = Get-ReviewText $update
    Assert-That ($update.Kind -eq 'update' -and $update.NeedsOk) 'an update waits for OK'
    Assert-That ($updateText -match "Installed now : version 2026\.10\.05, commit $shaOld" -and $updateText -match '2026-10-05\s+Installed subject line') 'it shows what is installed now: version, commit id, date, subject line'
    Assert-That ($updateText -match "To install\s+: commit $shaNew" -and $updateText -match '2026-10-06\s+Incoming subject line') 'and what is about to be installed: commit id, date, subject line'
    Assert-That ($updateText -match '3 commit\(s\), 7 file\(s\) differ' -and $updateText -match 'local-llm/Install-LocalAI\.ps1' -and $updateText -match [regex]::Escape("https://github.com/$repo/compare/$shaOld...$shaNew")) 'and the files that differ between the two, with the address of the full comparison'
    $repair = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming (Get-CommitSummary -Commit $base)
    Assert-That ($repair.Kind -eq 'repair' -and $repair.NeedsOk -and (Get-ReviewText $repair) -match 'repair run of the same version') 'the commit that is already installed: a repair run of the same version, asked once (no comparison needed)'
    $otherFolder = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $elsewhere -Incoming $incoming
    $otherFolderText = Get-ReviewText $otherFolder
    Assert-That ($otherFolder.NeedsOk -and -not $otherFolder.Stop -and $otherFolderText -notmatch 'First install' -and $otherFolderText -match 'installed on this PC' -and $otherFolderText -match 'but not in C:\\AI' -and $otherFolderText -match 'set LOCALAI_ROOT to that folder') 'an install that is not in the AI folder named here: said so, with LOCALAI_ROOT as the way to name the right one, and OK asked (not a first install)'
    Assert-That ($otherFolderText -match "To install\s+: commit $shaNew" -and $otherFolderText -match 'not known which commit is installed \(the install is in another folder' -and $otherFolderText -notmatch 'file\(s\) differ') 'the incoming commit is still shown, and no file list is made up for it'
    $byId = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref $shaNew -Installed $known -Incoming $incoming -Compare $compare
    $firstById = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref $shaNew.Substring(0, 7) -Installed $none -Incoming $incoming
    Assert-That (@($byId.Lines | Where-Object { $_.Text -match 'Not checked to be on a branch of this repository' -and $_.Text -match 'fork' -and $_.Color -eq 'Yellow' }).Count -eq 1 -and (Get-ReviewText $firstById) -match 'Not checked to be on a branch' -and $updateText -notmatch 'Not checked to be on a branch') 'a ref that is a commit id (not a branch or tag) is said not to be checked to be on a branch of this repository; a branch gets no such line'

    Write-Host "`n=== the review: when the comparison is not there ===" -ForegroundColor Cyan
    $failed = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -Compare $null -CompareError 'The remote server returned an error: (403) Forbidden.'
    $failedText = Get-ReviewText $failed
    Assert-That ($failed.NeedsOk -and $failedText -match 'could not be fetched from GitHub: The remote server returned an error: \(403\) Forbidden' -and $failedText -match "To install\s+: commit $shaNew" -and $failedText -match 'Incoming subject line') 'a comparison that failed (offline, rate limit) is named with its error; the incoming commit is still shown and OK still asked'
    $unreadable = @('a text too large for the JSON reader', (ConvertFrom-Json -InputObject '{"status": "ahead", "ahead_by": 2}'), (ConvertFrom-Json -InputObject '{"message": "Not Found"}'), (New-GitHubCompare -Status 'surprise' -Ahead 1 -Behind 0 -Base $base -Files $fewFiles))
    $unreadableBad = @($unreadable | Where-Object { $r = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -Compare $_; -not $r.NeedsOk -or (Get-ReviewText $r) -notmatch 'could not be read' -or (Get-ReviewText $r) -match 'file\(s\) differ' })
    Assert-That ($unreadableBad.Count -eq 0) "an answer that is not a comparison (plain text, no file list, an error message) is never shown as 'no files differ' ($($unreadableBad.Count) wrong)"
    $silent = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming
    Assert-That ($silent.NeedsOk -and (Get-ReviewText $silent) -match 'could not be fetched from GitHub: GitHub gave no answer') 'no comparison and no error either is still "could not be fetched"'
    $unknown = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $handZip -Incoming $incoming
    $unknownText = Get-ReviewText $unknown
    Assert-That ($unknown.NeedsOk -and $unknownText -match 'not known which commit is installed' -and $unknownText -match 'names no commit' -and $unknownText -match "To install\s+: commit $shaNew" -and $unknownText -notmatch 'file\(s\) differ') 'an install whose commit is unknown: said so, with the reason; the incoming commit shown, OK asked'
    # GitHub's API over its hourly limit: the lookup and the comparison both fail. The commit's page
    # still names it, so it is shown and asked about; only the file list is missing, and said to be.
    $limit = 'The remote server returned an error: (403) rate limit exceeded.'
    $limited = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $viaPage -IncomingError $limit -Compare $null -CompareError $limit
    $limitedText = Get-ReviewText $limited
    Assert-That ($limited.Kind -eq 'nocompare' -and $limited.NeedsOk -and -not $limited.Stop -and $limited.Url -eq "https://codeload.github.com/$repo/zip/$shaNew") "the API over its limit, the commit named by its page: no stop, OK is asked, and the download is pinned to that commit ($($limited.Kind))"
    Assert-That ($limitedText -match "To install\s+: commit $shaNew" -and $limitedText -match '2026-10-06\s+Incoming subject line' -and @($limited.Lines | Where-Object { $_.Text -match "API did not answer \(The remote server returned an error: \(403\) rate limit exceeded\.\): this was read from the commit's page" -and $_.Color -eq 'Yellow' }).Count -eq 1 -and $limitedText -match 'could not be fetched from GitHub: The remote server returned an error: \(403\) rate limit exceeded') 'the incoming commit is shown with date and subject line, where they were read from is said, and so is the missing file list'
    $script:limitedAsked = 0
    $limitedNo = Get-UpdateConsent -Review $limited -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer { $script:limitedAsked++; '' }
    $limitedOk = Get-UpdateConsent -Review $limited -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer { $script:limitedAsked++; 'OK' }
    Assert-That (-not $limitedNo.Go -and $limitedOk.Go -and $script:limitedAsked -eq 2) "and it goes on only after a typed OK: the error is not consent (asked $($script:limitedAsked) time(s))"
    Assert-That ($updateText -notmatch 'API did not answer' -and $failedText -notmatch 'API did not answer') 'a review whose commit the API named says nothing about a page'
    # An update whose commit cannot be named at all (neither the API nor the page answers) is not
    # offered: an OK would be an OK to code nobody saw, fetched from the branch unpinned and recorded
    # without a commit. It stops; nothing in the review can be downloaded.
    $unpinned = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $null -IncomingError 'The operation has timed out.'
    $unpinnedText = Get-ReviewText $unpinned
    Assert-That ($unpinned.Kind -eq 'unpinned' -and $unpinned.Stop -match 'could not be named' -and $unpinned.Stop -match 'LOCALAI_REF' -and $unpinned.NeedsOk -and $unpinned.Commit -eq '' -and $unpinned.Get -eq '' -and $unpinned.Url -eq '') "GitHub cannot name the incoming commit of an update: the review says stop and holds nothing to download (address '$($unpinned.Url)')"
    Assert-That ($unpinnedText -match "could not name the commit 'main' stands for \(The operation has timed out\.\)" -and $unpinnedText -match 'Try again later, or set LOCALAI_REF to the full 40-character id' -and $unpinnedText -match "Installed now : version 2026\.10\.05, commit $shaOld" -and $unpinnedText -notmatch 'whatever' -and $unpinnedText -notmatch 'zip/main') 'it says so with the error and the two ways on (later, or a full commit id); what is installed is still shown, the branch is not offered'
    $unpinnedOthers = @($handZip, $half, $elsewhere, (Get-InstalledToolkit -ConfigText '' -OtherSigns $false) | ForEach-Object { Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $_ -Incoming $null -IncomingError 'offline' })
    Assert-That (@($unpinnedOthers | Where-Object { -not $_.Stop -or $_.Url -ne '' }).Count -eq 0) "the same for every install that is not 'nothing installed': commit not recorded, not finished, in another folder, config unreadable"
    $firstUnpinned = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $none -Incoming $null -IncomingError 'The operation has timed out.'
    Assert-That (-not $firstUnpinned.NeedsOk -and -not $firstUnpinned.Stop -and $firstUnpinned.Url -eq "https://codeload.github.com/$repo/zip/main" -and (Get-ReviewText $firstUnpinned) -match 'cannot be shown or pinned') 'only a first install then goes on as before, downloading the ref as it is, and says that it is not pinned'
    $selfPinned = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref $shaNew -Installed $known -Incoming $pinnedRef -IncomingError 'The operation has timed out.' -CompareError 'The operation has timed out.'
    $selfPinnedText = Get-ReviewText $selfPinned
    Assert-That ($selfPinned.NeedsOk -and $selfPinnedText -match "To install\s+: commit $shaNew" -and $selfPinnedText -match 'could not describe it \(The operation has timed out\.\)' -and $selfPinnedText -notmatch 'cannot be shown or pinned') 'a ref that is a full commit id, without GitHub: the id is shown as pinned, said to come without date and subject line, OK asked'
    $selfReviewed = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref $shaNew -Installed $known -Incoming $pinnedRef -IncomingError 'offline' -CompareError 'offline' -ReviewedCommit $shaNew
    Assert-That (-not $selfReviewed.NeedsOk -and $selfReviewed.Url -eq "https://codeload.github.com/$repo/zip/$shaNew") "and naming that id as the reviewed commit skips the question (what it cannot skip is GitHub's list of the commit's files: see Get-DownloadCheck further down)"

    Write-Host "`n=== the review: an older or diverged commit, a truncated list ===" -ForegroundColor Cyan
    $older = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -Compare (New-GitHubCompare -Status 'behind' -Ahead 0 -Behind 5 -Base $base -Files @())
    $olderText = Get-ReviewText $older
    Assert-That ($older.Kind -eq 'older' -and $older.NeedsOk -and $olderText -match 'OLDER than the installed one \(5 commit' -and $olderText -notmatch 'file\(s\) differ' -and $olderText -match [regex]::Escape("compare/$shaNew...$shaOld")) "a commit older than the installed one is called a step back, not 'no files differ' (GitHub lists none in that direction)"
    $diverged = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -Compare (New-GitHubCompare -Status 'diverged' -Ahead 4 -Behind 2 -Base $base -Files $fewFiles)
    $divergedText = Get-ReviewText $diverged
    Assert-That ($diverged.Kind -eq 'diverged' -and $diverged.NeedsOk -and $divergedText -match 'does not continue from the installed one \(4 commit\(s\) ahead of their common ancestor, 2 behind\)' -and $divergedText -match 'rewritten' -and $divergedText -match 'local-llm/Install-LocalAI\.ps1') 'a commit that does not continue from the installed one (another branch, rewritten history) is named as such, with its files'
    # 300 added files that sort before local-llm/ fill GitHub's list: a changed installer after them
    # is not in it. The review must not say that no administrator script differs.
    $hundreds = @(1..300 | ForEach-Object { @{ filename = ('.github/pad/{0:d3}.txt' -f $_); status = 'added' } })
    $truncated = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -Compare (New-GitHubCompare -Status 'ahead' -Ahead 40 -Behind 0 -Base $base -Files $hundreds)
    $truncatedText = Get-ReviewText $truncated
    Assert-That ($truncated.NeedsOk -and $truncatedText -match '300 or more file\(s\) differ' -and $truncatedText -notmatch ' 300 file\(s\) differ' -and $truncatedText -match 'at most 300 files') "GitHub's limit of 300 listed files is said, not hidden: '300 or more' files differ"
    Assert-That ($truncatedText -notmatch 'none of them differ' -and @($truncated.Lines | Where-Object { $_.Text -match 'can start: not known' -and $_.Color -eq 'Yellow' }).Count -eq 1) "a list cut off at 300 never says that no administrator script differs: it says 'not known', in yellow"
    $iCutNotice = Get-LineIndex -Text $truncatedText -Pattern 'at most 300 files'
    Assert-That ($iCutNotice -gt (Get-LineIndex -Text $truncatedText -Pattern '300 or more file') -and $iCutNotice -lt (Get-LineIndex -Text $truncatedText -Pattern 'Scripts that run as administrator') -and $iCutNotice -lt (Get-LineIndex -Text $truncatedText -Pattern 'Not installed on this PC')) 'and the notice stands above the list, not under it'
    $nearly = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -Compare (New-GitHubCompare -Status 'ahead' -Ahead 40 -Behind 0 -Base $base -Files @($hundreds | Select-Object -First 299))
    Assert-That ((Get-ReviewText $nearly) -match ' 299 file\(s\) differ' -and (Get-ReviewText $nearly) -match 'none of them differ' -and (Get-ReviewText $nearly) -notmatch 'at most 300') 'a list of 299 files is complete and is reported as before'

    Write-Host "`n=== what is shown is what is downloaded ===" -ForegroundColor Cyan
    $pinned = @($first, $update, $repair, $otherFolder, $byId, $failed, $limited, $unknown, $selfPinned, $older, $diverged, $truncated, $bigReview, $asDictionaries)
    $mismatch = @($pinned | Where-Object { $shown = Get-ShownCommit $_; -not $shown -or $_.Commit -ne $shown -or $_.Get -ne $shown -or $_.Url -ne "https://codeload.github.com/$repo/zip/$shown" })
    Assert-That ($mismatch.Count -eq 0) "in every review the commit on the 'To install' line is the one in the download address and the one recorded ($($mismatch.Count) of $($pinned.Count) differ)"
    Assert-That ((Get-ShownCommit $update) -eq $shaNew -and (Get-ShownCommit $repair) -eq $shaOld -and (Get-ShownCommit $unpinned) -eq '') 'and that is the commit GitHub named for the ref (none is shown when it named none)'
    # Every review that can go on (asked or not) names a commit, except the first install of a ref
    # GitHub did not answer for; an update never has an address without a commit shown for it.
    $everyReview = @($pinned) + @($unpinned, $firstUnpinned, $nearly) + @($unpinnedOthers)
    $unseen = @($everyReview | Where-Object { $_.Kind -ne 'first' -and $_.Url -and -not (Get-ShownCommit $_) })
    Assert-That ($unseen.Count -eq 0) "no update holds a download address without a commit on its 'To install' line ($($unseen.Count) of $($everyReview.Count) do)"
    $colours = @($everyReview | ForEach-Object { $_.Lines } | Where-Object { @('Gray', 'Yellow', 'Cyan') -notcontains $_.Color -or -not $_.Text })
    Assert-That ($colours.Count -eq 0) 'every line of every review is text with a colour the console knows (the file list included)'
    $ids = @([regex]::Matches($updateText, '\b[0-9a-f]{40}\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
    Assert-That ($ids.Count -eq 2 -and $ids -contains $shaOld -and $ids -contains $shaNew) 'no other commit id appears in the review'

    Write-Host "`n=== the one way to skip the question ===" -ForegroundColor Cyan
    $skipUpdate = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -Compare $compare -ReviewedCommit $shaNew
    Assert-That (-not $skipUpdate.NeedsOk -and (Get-ReviewText $skipUpdate) -match 'Not asking: LOCALAI_REVIEWED_COMMIT names exactly this commit' -and (Get-ReviewText $skipUpdate) -match 'local-llm/Install-LocalAI\.ps1') 'LOCALAI_REVIEWED_COMMIT naming the incoming commit in full: not asked, and the review is still printed'
    $skipOthers = @(
        (Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming (Get-CommitSummary -Commit $base) -ReviewedCommit $shaOld)
        (Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $handZip -Incoming $incoming -ReviewedCommit "  $($shaNew.ToUpperInvariant())  ")
        (Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -CompareError 'offline' -ReviewedCommit $shaNew)
    )
    Assert-That (@($skipOthers | Where-Object { $_.NeedsOk }).Count -eq 0) 'the same for a repair run, an unknown installed commit and a failed comparison (the id may be upper case or padded)'
    $notThis = @($shaOther, $shaOld, $shaNew.Substring(0, 7), $shaNew.Substring(0, 39), ($shaNew + '0'), '1', 'true', 'yes', 'OK', 'main', '*', "$shaOther $shaNew")
    $skipped = @($notThis | Where-Object { -not (Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -Compare $compare -ReviewedCommit $_).NeedsOk })
    Assert-That ($skipped.Count -eq 0) "any other value (another commit, a short id, 1, true, yes, OK) does not skip it ($($skipped.Count) of $($notThis.Count) did)"
    $stale = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $incoming -Compare $compare -ReviewedCommit $shaOther
    Assert-That ($stale.NeedsOk -and (Get-ReviewText $stale) -match 'LOCALAI_REVIEWED_COMMIT is set, but not to the full id of this commit') 'a value left over from an earlier run is said not to count, and the question is asked'
    $unpinnedGoes = @(@('main', $shaNew, $shaOld, '') | Where-Object { $r = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $null -IncomingError 'offline' -ReviewedCommit $_; -not $r.NeedsOk -or -not $r.Stop -or $r.Url -or (Get-UpdateConsent -Review $r -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer { 'OK' }).Go })
    Assert-That ($unpinnedGoes.Count -eq 0) "when GitHub cannot name the commit of an update nothing makes it go on: no value of LOCALAI_REVIEWED_COMMIT (not even the ref itself), and no typed OK ($($unpinnedGoes.Count) of 4 went on)"

    Write-Host "`n=== the gate: only an OK typed after the review goes on ===" -ForegroundColor Cyan
    $script:asked = 0
    $typesOk = { $script:asked++; 'OK' }
    $typesNo = { $script:asked++; 'no' }
    $pressesEnter = { $script:asked++; '' }
    $cannotRead = { $script:asked++; throw 'Read and Prompt functionality is not available.' }
    $gate = Get-UpdateConsent -Review $first -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer $typesNo
    Assert-That ($gate.Go -and $script:asked -eq 0) 'a first install goes on without the question being asked'
    $gate = Get-UpdateConsent -Review $skipUpdate -HostName 'ConsoleHost' -InputRedirected $true -ReadAnswer $typesNo
    Assert-That ($gate.Go -and $script:asked -eq 0) 'so does the reviewed commit, also on a run without a keyboard'
    $gate = Get-UpdateConsent -Review $update -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer $typesOk
    Assert-That ($gate.Go -and $script:asked -eq 1) "an update goes on after one question answered OK (asked $($script:asked) time(s))"
    $refused = @(@($typesNo, $pressesEnter, { $null }, { 'O', 'K' }) | Where-Object { (Get-UpdateConsent -Review $update -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer $_).Go })
    Assert-That ($refused.Count -eq 0 -and (Get-UpdateConsent -Review $update -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer $typesNo).Why -match 'OK was not typed') 'anything else typed, Enter alone or no answer stops, and says why'
    $gate = Get-UpdateConsent -Review $update -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer $cannotRead
    Assert-That (-not $gate.Go -and $gate.Why -match 'could not be read \(Read and Prompt functionality is not available\.\)' -and $gate.Why -match 'LOCALAI_REVIEWED_COMMIT') 'an error while reading the answer is not consent; the message names the error and the way to run unattended'
    $script:asked = 0
    $gate = Get-UpdateConsent -Review $update -HostName 'ConsoleHost' -InputRedirected $true -ReadAnswer $typesOk
    Assert-That (-not $gate.Go -and $script:asked -eq 0 -and $gate.Why -match 'no keyboard' -and $gate.Why -match 'LOCALAI_REVIEWED_COMMIT') 'a console whose input is redirected is not asked at all: an OK piped in is not an answer'
    $gate = Get-UpdateConsent -Review $update -HostName 'Windows PowerShell ISE Host' -InputRedirected $true -ReadAnswer $typesOk
    Assert-That ($gate.Go -and $script:asked -eq 1) 'a host without a console window (ISE, a remote session) still asks through its own window'
    $notReviews = @($null, 'text', (ConvertFrom-Json -InputObject '{"NeedsOk": "False"}'), (ConvertFrom-Json -InputObject '{"Kind": "first"}'))
    $slipped = @($notReviews | Where-Object { (Get-UpdateConsent -Review $_ -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer $typesNo).Go })
    Assert-That ($slipped.Count -eq 0) "a review that is missing or unreadable is asked about, never waved through ($($slipped.Count) of $($notReviews.Count) went on)"
    # A review that says Stop (an update whose commit could not be named) is not asked about at all:
    # there is nothing on screen an OK could be about.
    $script:asked = 0
    $gate = Get-UpdateConsent -Review $unpinned -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer $typesOk
    Assert-That (-not $gate.Go -and $script:asked -eq 0 -and $gate.Why -match 'could not be named' -and $gate.Why -match 'Try again later') "an update whose commit could not be named stops without the question (asked $($script:asked) time(s)), and says what to do"
    $gate = Get-UpdateConsent -Review ([pscustomobject]@{ NeedsOk = $false; Stop = 'stand-in reason' }) -HostName 'ConsoleHost' -InputRedirected $false -ReadAnswer $typesOk
    Assert-That (-not $gate.Go -and $script:asked -eq 0 -and $gate.Why -eq 'stand-in reason') 'Stop wins over everything else in a review, "nothing to ask" included'

    Write-Host "`n=== fetched text cannot answer for the owner ===" -ForegroundColor Cyan
    $evilCommit = Get-CommitSummary -Commit (New-GitHubCommit -Sha $shaNew -Date '2026-10-06T23:30:00Z' -Message ('OK' + [char]13 + $esc + "[1A  To install    : commit $shaOther"))
    $evilFiles = @(
        @{ filename = "local-llm/tests/x`n  To install    : commit $shaOther"; status = 'added' }
        @{ filename = ('local-llm/Install-LocalAI.ps1' + $esc + '[2K' + [char]13 + 'OK'); status = 'modified' }
        @{ filename = 'OK'; status = 'added' }
    )
    $evilBase = New-GitHubCommit -Sha $shaOld -Date '2026-10-05T10:00:00Z' -Message "LOCALAI_REVIEWED_COMMIT=$shaNew"
    $evil = Get-UpdateReview -Repo $repo -Root 'C:\AI' -Ref 'main' -Installed $known -Incoming $evilCommit -Compare (New-GitHubCompare -Status 'ahead' -Ahead 1 -Behind 0 -Base $evilBase -Files $evilFiles)
    $evilLines = @($evil.Lines | ForEach-Object { $_.Text })
    Assert-That ($evil.NeedsOk -and -not (Test-UpdateAnswer -Answer (Get-ReviewText $evil))) "a subject line, file name or message that says OK is not an answer: the question is still asked"
    Assert-That (@($evilLines | Where-Object { $_ -match '[^\x20-\x7E]' }).Count -eq 0) 'no line of the review holds a control or escape character, whatever the commit and file names hold'
    Assert-That (@($evilLines | Where-Object { $_ -match '^\s*To install\s+:' }).Count -eq 1 -and (Get-ShownCommit $evil) -eq $shaNew -and $evil.Url -eq "https://codeload.github.com/$repo/zip/$shaNew") "and a file name cannot add a second 'To install' line: one line, one commit, the one downloaded"

    Write-Host "`n=== what is installed is the commit that was shown: git's id of a file ===" -ForegroundColor Cyan
    $utf8 = [System.Text.Encoding]::UTF8
    $emptyId = 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'
    Assert-That ((Get-GitBlobId -Bytes ([byte[]]@())) -ceq $emptyId -and (Get-GitBlobId -Bytes $null) -ceq $emptyId -and (Get-GitBlobId -Bytes $utf8.GetBytes("hello`n")) -ceq 'ce013625030ba8dba906f756967f9e9ca394464a' -and (Get-GitBlobId -Bytes $utf8.GetBytes("test content`n")) -ceq 'd670460b4b4aece5915caf5c68d12f560a9fe3e4') "a file's id is the one git itself gives it (an empty file and two known texts, as 'git hash-object' prints them)"
    Assert-That ((Get-Sha256Hex -Bytes $utf8.GetBytes('abc')) -ceq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' -and (Get-Sha256Hex -Bytes $null) -ceq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') 'SHA-256 comes as lower-case hex (the known values for "abc" and for nothing)'
    # The same two lines with LF and with CRLF: two different files to git.
    $cmdLf = $utf8.GetBytes("@echo off`necho hi`n")
    $cmdCrLf = $utf8.GetBytes("@echo off`r`necho hi`r`n")
    $idLf = '1a75d2d9c49ef9604fe0d579c626306e0cb501f2'
    $idCrLf = '3ea93f8f70477b93ede6ba3ede409fb4a98beacc'
    Assert-That ((Get-GitBlobId -Bytes $cmdLf) -ceq $idLf -and (Get-GitBlobId -Bytes $cmdCrLf) -ceq $idCrLf) 'the same text with LF and with CRLF has two ids'
    Assert-That ((Get-ToolkitFileId -Path 'local-llm/Install-LocalAI.cmd' -Bytes $cmdCrLf) -ceq $idLf -and (Get-ToolkitFileId -Path 'local-llm/Install-LocalAI.cmd' -Bytes $cmdLf) -ceq $idLf) "a .cmd file that arrives with CRLF (as GitHub's archive holds it) has the id of its LF form, the one the commit's list holds"
    $otherNames = @('local-llm/Install-LocalAI.ps1', 'local-llm/lib/LocalAI.psm1', 'local-llm/x.CMD', 'local-llm/x.cmd.txt', 'local-llm/cmd', 'local-llm/x.bat')
    $touched = @($otherNames | Where-Object { (Get-ToolkitFileId -Path $_ -Bytes $cmdCrLf) -cne $idCrLf })
    Assert-That ($touched.Count -eq 0) "no other file is touched: a .ps1 (or .CMD, .cmd.txt, .bat) that arrives with CRLF keeps its own id and does not pass for its LF form (touched: $($touched -join ', '))"
    Assert-That ((Get-ToolkitFileId -Path 'x.cmd' -Bytes ([byte[]]@(255, 13, 10, 0, 13, 200, 10))) -ceq (Get-GitBlobId -Bytes ([byte[]]@(255, 10, 0, 13, 200, 10)))) 'in a .cmd only a CR in front of an LF goes; a CR alone and every other byte stay as they are'
    # The rule above is the one rule the repository's .gitattributes hold. Another one there (an eol
    # for another kind of file, an export rule) changes what GitHub's archive holds, and needs its
    # counterpart in Get-ToolkitFileId.
    $attributeLines = { param([string]$File) @([System.IO.File]::ReadAllLines($File) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) }
    $toolkitAttributes = @()
    if (Test-Path -LiteralPath (Join-Path $src '.gitattributes')) { $toolkitAttributes = @(& $attributeLines (Join-Path $src '.gitattributes')) }
    $attributeFiles = @(Get-ChildItem -LiteralPath $src -Recurse -Force -File -Filter '.gitattributes')
    $rootAttributeFile = Join-Path (Split-Path -Parent $src) '.gitattributes'
    $rootAttributes = @('* text=auto')
    if (Test-Path -LiteralPath $rootAttributeFile) { $rootAttributes = @(& $attributeLines $rootAttributeFile) }
    Assert-That ($toolkitAttributes.Count -eq 1 -and $toolkitAttributes[0] -ceq '*.cmd text eol=crlf' -and $attributeFiles.Count -eq 1 -and $rootAttributes.Count -eq 1 -and $rootAttributes[0] -ceq '* text=auto') "the repository's .gitattributes mark *.cmd alone ('text eol=crlf'): the one rule Get-ToolkitFileId knows (local-llm: $($toolkitAttributes -join ' | '); above it: $($rootAttributes -join ' | '); files: $($attributeFiles.Count))"

    Write-Host "`n=== what is installed is the commit that was shown: GitHub's list of the commit's files ===" -ForegroundColor Cyan
    # The toolkit of a small commit as it arrives in GitHub's archive (the .cmd with CRLF), and the
    # list GitHub gives for that commit (the .cmd with the id of its LF form, as the repository holds it).
    $arrived = [ordered]@{
        'local-llm/Install-LocalAI.ps1' = $utf8.GetBytes("param([string]`$AIRoot)`n'stand-in installer'`n")
        'local-llm/Install-LocalAI.cmd' = $utf8.GetBytes("@echo off`r`nrem stand-in`r`n")
        'local-llm/VERSION'             = $utf8.GetBytes('2099.01.02')
        'local-llm/lib/LocalAI.psm1'    = $utf8.GetBytes("# stand-in module`n")
    }
    $treeEntries = @((New-TreeEntry 'README.md'), (New-TreeEntry '.github' -Mode '040000' -Type 'tree'), (New-TreeEntry '.github/workflows/ci.yml'), (New-TreeEntry 'local-llm' -Mode '040000' -Type 'tree'), (New-TreeEntry 'local-llm/lib' -Mode '040000' -Type 'tree'))
    foreach ($path in $arrived.Keys) {
        $stored = $arrived[$path]
        $mode = '100644'
        if ($path -like '*.cmd') { $stored = $utf8.GetBytes($utf8.GetString($stored).Replace("`r`n", "`n")); $mode = '100755' }
        $treeEntries += (New-TreeEntry $path (Get-GitBlobId -Bytes $stored) -Mode $mode)
    }
    $manifest = Get-TreeManifest -Tree (New-TreeAnswer $treeEntries)
    Assert-That ($manifest -is [array] -and $manifest.Count -eq 4 -and @($manifest | Where-Object { $_.Path -notlike 'local-llm/*' -or $_.Id -cnotmatch '^[0-9a-f]{40}\z' }).Count -eq 0 -and (@($manifest | ForEach-Object { $_.Path }) -join ' ') -ceq (@($arrived.Keys) -join ' ')) "GitHub's list of a commit's files gives the files under local-llm with their ids, and nothing from outside it ($(@($manifest).Count) file(s))"
    $manifestFromDictionaries = Get-TreeManifest -Tree (ConvertTo-TestDictionary @{ sha = ('f' * 40); truncated = $false; tree = $treeEntries })
    Assert-That (@($manifestFromDictionaries).Count -eq 4 -and (Get-ToolkitDigest -Files $manifestFromDictionaries) -ceq (Get-ToolkitDigest -Files $manifest)) 'the same answer read into dictionaries and arrays (the second JSON reader of Windows PowerShell 5.1) gives the same list'
    $single = Get-TreeManifest -Tree (New-TreeAnswer @((New-TreeEntry 'local-llm' -Mode '040000' -Type 'tree'), (New-TreeEntry 'local-llm/Install-LocalAI.ps1')))
    Assert-That ($single -is [array] -and $single.Count -eq 1) 'a list of one file stays a list'
    $withEntry = { param([object[]]$More) New-TreeAnswer (@($treeEntries) + @($More)) }
    $notUsable = [ordered]@{
        'cut off by GitHub'                        = (New-TreeAnswer $treeEntries $true)
        'no word on whether it is cut off'         = (ConvertFrom-Json -InputObject (ConvertTo-Json -Depth 6 -InputObject @{ sha = ('f' * 40); tree = $treeEntries }))
        'cut off answered as text'                 = (New-TreeAnswer $treeEntries 'false')
        'no list in it'                            = (ConvertFrom-Json -InputObject '{"sha": "x", "truncated": false}')
        'an empty list'                            = (ConvertFrom-Json -InputObject '{"sha": "x", "truncated": false, "tree": []}')
        'a list that is text'                      = (ConvertFrom-Json -InputObject '{"truncated": false, "tree": "local-llm/Install-LocalAI.ps1"}')
        'an error message'                         = (ConvertFrom-Json -InputObject '{"message": "Not Found"}')
        'plain text'                               = 'Not Found'
        'nothing at all'                           = $null
        'a symbolic link'                          = (& $withEntry (New-TreeEntry 'local-llm/link' -Mode '120000'))
        'a submodule'                              = (& $withEntry (New-TreeEntry 'vendor' -Mode '160000' -Type 'commit'))
        'an entry of an unknown kind'              = (& $withEntry (New-TreeEntry 'local-llm/new.ps1' -Type 'tag'))
        'two files that differ in capitals only'   = (& $withEntry (New-TreeEntry 'local-llm/install-localai.ps1'))
        'two folders that differ in capitals only' = (& $withEntry @((New-TreeEntry 'local-llm/Lib' -Mode '040000' -Type 'tree'), (New-TreeEntry 'local-llm/Lib/x.ps1')))
        'a name that ends in a dot'                = (& $withEntry (New-TreeEntry 'local-llm./Install-LocalAI.ps1'))
        'a name with a backslash'                  = (& $withEntry (New-TreeEntry 'local-llm\Evil.ps1'))
        'a name with a colon'                      = (& $withEntry (New-TreeEntry 'local-llm/x.txt:Install-LocalAI.ps1'))
        'a short 8.3 name'                         = (& $withEntry (New-TreeEntry 'LOCAL-~1/x.ps1'))
        'a name outside ASCII'                     = (& $withEntry (New-TreeEntry ('docs/x' + [char]0xE9 + '.md')))
        'an id that is no git id'                  = (& $withEntry (New-TreeEntry 'local-llm/new.ps1' 'abc'))
        'an id in capitals'                        = (& $withEntry (New-TreeEntry 'local-llm/new.ps1' ('A' * 40)))
        'no file under local-llm'                  = (New-TreeAnswer @((New-TreeEntry 'README.md'), (New-TreeEntry 'Local-LLM' -Mode '040000' -Type 'tree'), (New-TreeEntry 'Local-LLM/Install-LocalAI.ps1')))
    }
    $wronglyUsed = @($notUsable.Keys | Where-Object { $null -ne (Get-TreeManifest -Tree $notUsable[$_]) })
    Assert-That ($wronglyUsed.Count -eq 0) "an answer that cannot be compared exactly with what Windows unpacks is not used as a list at all: cut off, no list, a link, a submodule, capitals, names Windows stores elsewhere ($($notUsable.Count) kinds; wrongly used: $($wronglyUsed -join ', '))"

    Write-Host "`n=== what is installed is the commit that was shown: the download against that list ===" -ForegroundColor Cyan
    $same = Compare-ToolkitTree -Manifest $manifest -Files (Get-TestFileList $arrived)
    Assert-That ($same.Count -eq 0 -and (Get-ToolkitDigest -Files (Get-TestFileList $arrived)) -ceq (Get-ToolkitDigest -Files $manifest)) "a correct download passes: every file of the commit and nothing else, the .cmd with CRLF among them ($($same -join '; '))"
    $oneByte = Copy-TestTable $arrived
    $changedBytes = [byte[]]$arrived['local-llm/lib/LocalAI.psm1'].Clone()
    $changedBytes[$changedBytes.Length - 1] = $changedBytes[$changedBytes.Length - 1] -bxor 1
    $oneByte['local-llm/lib/LocalAI.psm1'] = $changedBytes
    $diffOneByte = Compare-ToolkitTree -Manifest $manifest -Files (Get-TestFileList $oneByte)
    Assert-That ($diffOneByte.Count -eq 1 -and $diffOneByte[0] -ceq 'not as in the commit: local-llm/lib/LocalAI.psm1' -and (Get-ToolkitDigest -Files (Get-TestFileList $oneByte)) -cne (Get-ToolkitDigest -Files $manifest)) "a download that differs from the commit's files in one byte is refused, and the file is named ($($diffOneByte -join '; '))"
    $unlisted = Copy-TestTable $arrived
    $unlisted['local-llm/Extra-Tool.ps1'] = $utf8.GetBytes('# not in the commit')
    $diffUnlisted = Compare-ToolkitTree -Manifest $manifest -Files (Get-TestFileList $unlisted)
    Assert-That ($diffUnlisted.Count -eq 1 -and $diffUnlisted[0] -ceq 'not in the commit: local-llm/Extra-Tool.ps1') "a file the commit's list does not hold is refused, and named ($($diffUnlisted -join '; '))"
    $lacking = Copy-TestTable $arrived
    $lacking.Remove('local-llm/VERSION')
    $diffMissing = Compare-ToolkitTree -Manifest $manifest -Files (Get-TestFileList $lacking)
    Assert-That ($diffMissing.Count -eq 1 -and $diffMissing[0] -ceq 'missing: local-llm/VERSION') "a missing file is refused, and named ($($diffMissing -join '; '))"
    $lfCmd = Copy-TestTable $arrived
    $lfCmd['local-llm/Install-LocalAI.cmd'] = $utf8.GetBytes("@echo off`nrem stand-in`n")
    $crlfScript = Copy-TestTable $arrived
    $crlfScript['local-llm/Install-LocalAI.ps1'] = $utf8.GetBytes("param([string]`$AIRoot)`r`n'stand-in installer'`r`n")
    $diffCrlfScript = Compare-ToolkitTree -Manifest $manifest -Files (Get-TestFileList $crlfScript)
    Assert-That ((Compare-ToolkitTree -Manifest $manifest -Files (Get-TestFileList $lfCmd)).Count -eq 0 -and ($diffCrlfScript -join '; ') -ceq 'not as in the commit: local-llm/Install-LocalAI.ps1') "line ends: the .cmd passes with CRLF and with LF; a .ps1 that arrives with CRLF is not the file the commit holds ($($diffCrlfScript -join '; '))"
    $otherCapitals = [ordered]@{}
    foreach ($path in $arrived.Keys) { $otherCapitals[$path.Replace('Install-LocalAI.ps1', 'install-localai.ps1')] = $arrived[$path] }
    $diffCapitals = Compare-ToolkitTree -Manifest $manifest -Files (Get-TestFileList $otherCapitals)
    Assert-That ($diffCapitals.Count -eq 2 -and $diffCapitals -contains 'not in the commit: local-llm/install-localai.ps1' -and $diffCapitals -contains 'missing: local-llm/Install-LocalAI.ps1') "names are compared letter for letter: the installer under a name in other capitals is one file too many and one missing ($($diffCapitals -join '; '))"
    Assert-That ((Compare-ToolkitTree -Manifest $manifest -Files @()).Count -eq 4) 'a download without any toolkit file lacks every file of the commit'
    $digestList = @([pscustomobject]@{ Path = 'local-llm/b'; Id = ('a' * 40) }, [pscustomobject]@{ Path = 'local-llm/B'; Id = ('b' * 40) }, [pscustomobject]@{ Path = 'local-llm/a'; Id = ('c' * 40) })
    $digest = Get-ToolkitDigest -Files $digestList
    Assert-That ($digest -ceq 'b81c78d46f6430500f48d23b99f215f61d4de0fc10e742d7cb19d056877631c6' -and (Get-ToolkitDigest -Files @($digestList[2], $digestList[0], $digestList[1])) -ceq $digest) "the digest of a list is one fixed number, in whatever order the list comes and on whatever PowerShell ($digest)"
    $digestOthers = @(
        (Get-ToolkitDigest -Files @($digestList[0], $digestList[1]))
        (Get-ToolkitDigest -Files @($digestList[0], $digestList[1], [pscustomobject]@{ Path = 'local-llm/a'; Id = ('d' * 40) }))
        (Get-ToolkitDigest -Files @($digestList[0], $digestList[1], [pscustomobject]@{ Path = 'local-llm/A'; Id = ('c' * 40) }))
        (Get-ToolkitDigest -Files @())
    )
    Assert-That (@($digestOthers | Where-Object { $_ -ceq $digest -or $_ -cnotmatch '^[0-9a-f]{64}\z' }).Count -eq 0 -and @($digestOthers | Select-Object -Unique).Count -eq 4) 'a file less, another id or a name in other capitals each give another digest'

    Write-Host "`n=== without the commit's list of files an update stops ===" -ForegroundColor Cyan
    $checkUpdate = Get-DownloadCheck -Review $update -Manifest $manifest
    Assert-That (-not $checkUpdate.Stop -and $checkUpdate.Compare -and (Get-ReviewText $checkUpdate) -match 'must hold exactly the 4 file\(s\) GitHub lists under local-llm') 'an update with the list goes on to the question, and says what the download will be held against'
    # Every kind of update, asked about or with the reviewed commit named, and every way of not
    # having the list: GitHub's API not answering (its limit, a timeout), an answer that is no list.
    $updateReviews = @($update, $repair, $otherFolder, $byId, $failed, $limited, $unknown, $selfPinned, $selfReviewed, $skipUpdate, $older, $diverged, $truncated)
    $noListReasons = @('', 'The remote server returned an error: (403) rate limit exceeded.', 'The operation has timed out.', 'its answer is no complete list of plain files')
    $wentOn = 0
    foreach ($review in $updateReviews) {
        foreach ($reason in $noListReasons) {
            $checked = Get-DownloadCheck -Review $review -Manifest $null -ManifestError $reason
            if (-not $checked.Stop -or $checked.Compare) { $wentOn++ }
        }
    }
    Assert-That ($wentOn -eq 0) "GitHub's API not answering for the list stops the update: every kind of update, asked about or with the reviewed commit named, whatever the error ($($updateReviews.Count * $noListReasons.Count) cases, $wentOn went on)"
    $noList = Get-DownloadCheck -Review $skipUpdate -Manifest $null -ManifestError 'The remote server returned an error: (403) Forbidden.'
    Assert-That ($noList.Stop -match 'could not be used \(The remote server returned an error: \(403\) Forbidden\.\)' -and $noList.Stop -match 'never installed unchecked' -and $noList.Stop -match 'Try again later') 'it says why, that an update is never installed unchecked, and to try again later'
    $checkFirst = Get-DownloadCheck -Review $first -Manifest $manifest
    Assert-That (-not $checkFirst.Stop -and $checkFirst.Compare -and (Get-ReviewText $checkFirst) -match 'cannot be compared with a reviewed commit' -and (Get-ReviewText $checkFirst) -match 'compared with the 4 file\(s\) GitHub lists') 'a first install says plainly that its download cannot be compared with a reviewed commit; with the list it is still held against the commit it shows'
    $checkFirstNoList = Get-DownloadCheck -Review $first -Manifest $null -ManifestError 'The operation has timed out.'
    $checkFirstUnpinned = Get-DownloadCheck -Review $firstUnpinned -Manifest $null
    Assert-That (-not $checkFirstNoList.Stop -and -not $checkFirstNoList.Compare -and (Get-ReviewText $checkFirstNoList) -match 'cannot be compared with a reviewed commit' -and (Get-ReviewText $checkFirstNoList) -match 'could not be used either \(The operation has timed out\.\): it is installed as it arrives') 'only a first install goes on without the list, and says that it is installed as it arrives'
    Assert-That (-not $checkFirstUnpinned.Stop -and -not $checkFirstUnpinned.Compare -and (Get-ReviewText $checkFirstUnpinned) -match 'cannot be compared with a reviewed commit' -and (Get-ReviewText $checkFirstUnpinned) -match 'Without a commit there is no list') 'the same for a first install whose commit GitHub could not name'
    $checkStopped = Get-DownloadCheck -Review $unpinned -Manifest $null -ManifestError 'offline'
    Assert-That (-not $checkStopped.Stop -and -not $checkStopped.Compare -and @($checkStopped.Lines).Count -eq 0) 'a review that says stop itself (no commit named) is left to the gate, which stops it with its own reason'
    $oddReviews = @($null, 'text', (ConvertFrom-Json -InputObject '{"Kind": "First"}'), (ConvertFrom-Json -InputObject '{"Kind": "first ", "Commit": ""}'), [pscustomobject]@{ Kind = 'update'; Commit = '' })
    $oddWentOn = @($oddReviews | Where-Object { -not (Get-DownloadCheck -Review $_ -Manifest $null).Stop }).Count + @($oddReviews | Where-Object { -not (Get-DownloadCheck -Review $_ -Manifest $manifest).Stop }).Count
    Assert-That ($oddWentOn -eq 0) "whatever is not plainly a first install counts as an update: a review that is missing, unreadable or names no commit stops, with a list or without ($oddWentOn of $($oddReviews.Count * 2) went on)"
    $checkLines = @(@($checkUpdate, $checkFirst, $checkFirstNoList, $checkFirstUnpinned) | ForEach-Object { $_.Lines })
    Assert-That ($checkLines.Count -ge 7 -and @($checkLines | Where-Object { @('Gray', 'Yellow') -notcontains $_.Color -or -not $_.Text -or $_.Text -match '[^\x20-\x7E]' }).Count -eq 0) 'every line of the check is plain text with a colour the console knows'

    Write-Host "`n=== a folder only administrators can change, from its rules ===" -ForegroundColor Cyan
    $sidSystem = 'S-1-5-18'
    $sidAdmins = 'S-1-5-32-544'
    $sidUsers = 'S-1-5-32-545'
    $sidInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    $sidPerson = 'S-1-5-21-1-2-3-1001'
    # Rights as Windows numbers them: full control, modify, read and run, and the generic ones.
    $full = 2032127
    $modify = 1245631
    $readRun = 1179817
    $genericAll = 268435456
    $genericWrite = 1073741824
    $genericReadRun = -1610612736
    # Program Files as Windows sets it up: what is made in it later gets its rules from the
    # inherit-only ones, among them full control for whoever makes it (CREATOR OWNER, S-1-3-0).
    $programFilesRule = [pscustomobject]@{ Owner = $sidInstaller; Rules = @(
            (New-TestRule $sidInstaller $full), (New-TestRule $sidInstaller $genericAll -InheritOnly), (New-TestRule $sidSystem $modify), (New-TestRule $sidSystem $genericAll -InheritOnly),
            (New-TestRule $sidAdmins $modify), (New-TestRule $sidAdmins $genericAll -InheritOnly), (New-TestRule $sidUsers $readRun), (New-TestRule $sidUsers $genericReadRun -InheritOnly),
            (New-TestRule 'S-1-3-0' $genericAll -InheritOnly), (New-TestRule 'S-1-15-2-1' $readRun), (New-TestRule 'S-1-15-2-1' $genericReadRun -InheritOnly))
    }
    Assert-That ((Test-AdminOnlyRule -Rule $programFilesRule -Parent) -eq '') "Program Files as Windows sets it up passes as the folder the new one is made in ('$(Test-AdminOnlyRule -Rule $programFilesRule -Parent)')"
    Assert-That ((Test-AdminOnlyRule -Rule $programFilesRule) -match '^S-1-3-0 may change it \(rights 0x10000000\)') 'the same rules would not do for the new folder itself: there an inherit-only rule counts too, and a generic right is a right'
    $adminOnly = [pscustomobject]@{ Owner = $sidAdmins; Rules = @((New-TestRule $sidSystem $full), (New-TestRule $sidAdmins $full)) }
    $withRule = { param($More, [string]$Owner = $sidAdmins) [pscustomobject]@{ Owner = $Owner; Rules = @($adminOnly.Rules) + @($More) } }
    $writable = [ordered]@{
        'Users may modify'                = (& $withRule (New-TestRule $sidUsers $modify))
        'Users have full control'         = (& $withRule (New-TestRule $sidUsers $full))
        'Users may write (generic)'       = (& $withRule (New-TestRule $sidUsers $genericWrite))
        'Users may create files'          = (& $withRule (New-TestRule $sidUsers ($readRun -bor 2)))
        'signed-in users may add folders' = (& $withRule (New-TestRule 'S-1-5-11' 4))
        'Everyone may delete'             = (& $withRule (New-TestRule 'S-1-1-0' 65536))
        'a user may change the rules'     = (& $withRule (New-TestRule $sidPerson 262144))
        'a user may take it over'         = (& $withRule (New-TestRule $sidPerson 524288))
        'an inherit-only rule for a user' = (& $withRule (New-TestRule $sidPerson $genericAll -InheritOnly))
        'a user owns it'                  = (& $withRule @() $sidPerson)
        'nobody is named as owner'        = (& $withRule @() '')
        'a rule without a right'          = (& $withRule ([pscustomobject]@{ Sid = $sidUsers; Allow = $true; InheritOnly = $false }))
        'a rule without a name'           = (& $withRule (New-TestRule '' $readRun))
        'rules that are no rules'         = [pscustomobject]@{ Owner = $sidAdmins; Rules = @('text') }
        'no rules handed over'            = [pscustomobject]@{ Owner = $sidAdmins }
        'nothing at all'                  = $null
    }
    $adminsOnly = [ordered]@{
        'SYSTEM and Administrators alone'     = $adminOnly
        'Users may read and run'              = (& $withRule (New-TestRule $sidUsers $readRun))
        'Users may read and run (generic)'    = (& $withRule (New-TestRule $sidUsers $genericReadRun))
        'generic read alone (the top bit)'    = (& $withRule (New-TestRule $sidUsers ([int]::MinValue)))
        'the right as a 64-bit number'        = (& $withRule (New-TestRule $sidUsers ([long]$readRun)))
        'a rule that denies'                  = (& $withRule (New-TestRule $sidUsers $full -Deny))
        'TrustedInstaller owns it'            = (& $withRule @() $sidInstaller)
        'no rule at all: the owner alone'     = [pscustomobject]@{ Owner = $sidSystem; Rules = @() }
    }
    $wronglyAccepted = @($writable.Keys | Where-Object { (Test-AdminOnlyRule -Rule $writable[$_]) -eq '' })
    $wronglyRefused = @($adminsOnly.Keys | Where-Object { (Test-AdminOnlyRule -Rule $adminsOnly[$_]) -ne '' })
    Assert-That ($wronglyAccepted.Count -eq 0) "the check of a folder's rules refuses a folder a normal user can write: modify, full control, a generic write, making files or folders, deleting, changing the rules, owning it; and rules it cannot read ($($writable.Count) cases; wrongly accepted: $($wronglyAccepted -join ', '))"
    Assert-That ($wronglyRefused.Count -eq 0) "it accepts a folder that SYSTEM, Administrators and TrustedInstaller alone can change, whoever else may read and run ($($adminsOnly.Count) cases; wrongly refused: $($wronglyRefused -join ', '))"
    Assert-That ((Test-AdminOnlyRule -Rule $writable['Users may modify']) -match '^S-1-5-32-545 may change it \(rights 0x001301BF\)' -and (Test-AdminOnlyRule -Rule $writable['a user owns it']) -match '^its owner is not SYSTEM, Administrators or TrustedInstaller \(owner: S-1-5-21-1-2-3-1001\)') 'and it says who may change the folder, or that its owner is the trouble'
    Assert-That ((Test-AdminOnlyRule -Rule $writable['an inherit-only rule for a user'] -Parent) -eq '' -and (Test-AdminOnlyRule -Rule $writable['Users may modify'] -Parent) -ne '' -and (Test-AdminOnlyRule -Rule $writable['a user owns it'] -Parent) -ne '') 'for the folder above, only the inherit-only rules are left out: a user who may modify it, or who owns it, is still a no'

    Write-Host "`n=== the step with administrator rights: its text, and the command that starts it ===" -ForegroundColor Cyan
    $stageNames = @(Get-ElevatedFunctionList)
    $stageAsts = @($fnAsts | Where-Object { $stageNames -contains $_.Name })
    $callsOutside = New-Object System.Collections.Generic.List[string]
    foreach ($fn in $stageAsts) {
        foreach ($call in @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $called = $call.GetCommandName()
            if ($called -and $have -contains $called -and $stageNames -notcontains $called) { $callsOutside.Add("$($fn.Name) calls $called") }
        }
    }
    Assert-That ($stageNames -contains 'Invoke-ElevatedInstall' -and $stageAsts.Count -eq $stageNames.Count -and $callsOutside.Count -eq 0) "the step is handed every function of the bootstrap that it calls, and each of them once ($($stageNames.Count) functions; not handed over: $($callsOutside -join ', '))"
    $definitions = [ordered]@{}
    foreach ($fn in $stageAsts) { $definitions[$fn.Name] = $fn.Body.Extent.Text.Substring(1, $fn.Body.Extent.Text.Length - 2) }
    $notAsWritten = @($stageNames | Where-Object { [string](Get-Command -Name $_ -CommandType Function).Definition -cne [string]$definitions[$_] })
    Assert-That ($notAsWritten.Count -eq 0) "what PowerShell hands over as a function's text (the bootstrap writes that into the step's file) is the text the file has (differing: $($notAsWritten -join ', '))"
    # Values that must not become part of a command: a quote, a '$(', a backtick, a space, a letter
    # outside ASCII, a trailing backslash.
    $oddRoot = 'D:\My AI''s $(calc) `n "q" ' + [char]0xE9 + '\'
    $oddZip = 'T:\temp folder\localai-installer.zip'
    $oddStage = 'T:\temp folder\localai-elevated-step.txt'
    $standInBody = ' param($Zip, $StageFile, $Digest, $Commit, $Root, [string[]]$Extra) [pscustomobject]@{ Zip = $Zip; StageFile = $StageFile; Digest = $Digest; Commit = $Commit; Root = $Root; Extra = $Extra } '
    $probeStage = Get-ElevatedStage -Definitions ([ordered]@{ 'Invoke-ElevatedInstall' = $standInBody }) -Zip $oddZip -StageFile $oddStage -Digest $digest -Commit '' -Root $oddRoot -Extra @('-OfficialModels', 'none')
    $handed = & ([scriptblock]::Create($probeStage))
    Assert-That ($handed.Zip -ceq $oddZip -and $handed.StageFile -ceq $oddStage -and $handed.Digest -ceq $digest -and $handed.Commit -ceq '' -and $handed.Root -ceq $oddRoot -and @($handed.Extra).Count -eq 2 -and (@($handed.Extra) -join ' ') -ceq '-OfficialModels none') "every value reaches the step as it was, also a folder name with a quote, a '`$(', a space and a letter outside ASCII (root '$($handed.Root)')"
    Assert-That (-not $probeStage.Contains('My AI') -and -not $probeStage.Contains('temp folder') -and -not $probeStage.Contains('OfficialModels')) 'and none of them stands in the text as it is: they travel as base64, so no name can become part of the command'
    $handedNone = & ([scriptblock]::Create((Get-ElevatedStage -Definitions ([ordered]@{ 'Invoke-ElevatedInstall' = $standInBody }) -Zip 'z' -StageFile 's' -Digest $digest -Commit $shaNew -Root 'C:\AI' -Extra @())))
    Assert-That (@($handedNone.Extra).Count -eq 0 -and $handedNone.Commit -ceq $shaNew -and $handedNone.Root -ceq 'C:\AI') 'no options are no options, and a commit id arrives as the id'
    $realStage = Get-ElevatedStage -Definitions $definitions -Zip $oddZip -StageFile $oddStage -Digest $digest -Commit $shaNew -Root $oddRoot -Extra @()
    $stageErrors = $null
    $stageAst = [System.Management.Automation.Language.Parser]::ParseInput($realStage, [ref]$null, [ref]$stageErrors)
    $stageDefined = @($stageAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name })
    $lastStatement = @($stageAst.EndBlock.Statements)[-1]
    Assert-That (@($stageErrors).Count -eq 0 -and $stageDefined.Count -eq $stageNames.Count -and @($stageNames | Where-Object { $stageDefined -notcontains $_ }).Count -eq 0 -and $lastStatement.Extent.Text -like 'Invoke-ElevatedInstall -Zip *') "the step's text is a script of its own: it parses, defines the $($stageNames.Count) functions and ends in the one call of Invoke-ElevatedInstall ($(@($stageErrors).Count) parse error(s))"
    $stageHash = Get-Sha256Hex -Bytes $utf8.GetBytes($realStage)
    $launcher = Get-ElevatedLauncher -StageFile $oddStage -Zip $oddZip -Hash $stageHash
    $launcherErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($launcher, [ref]$null, [ref]$launcherErrors)
    Assert-That (@($launcherErrors).Count -eq 0 -and -not $launcher.Contains('"') -and $launcher -notmatch '\s\s|[\r\n\t]' -and $launcher.Contains("'$stageHash'") -and -not $launcher.Contains('temp folder') -and $launcher.Length -lt 2000) "the command the window with administrator rights is started with is one line that can be cut at its spaces and joined again: no double quote, no two spaces in a row, the paths as base64, the hash in it ($($launcher.Length) characters)"
    # The command itself, run here on two stand-in files: with the hash of the step's text it runs
    # that text; with any other hash, or without the file, it runs nothing and removes both files.
    $fileWork = Join-Path $Work 'files'
    if (Test-Path -LiteralPath $fileWork) { Remove-Item -LiteralPath $fileWork -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $fileWork | Out-Null
    $probeStep = Join-Path $fileWork 'step.txt'
    $probeZip = Join-Path $fileWork 'download.zip'
    $stepBytes = $utf8.GetBytes("'the step ran'")
    $runLauncher = {
        param([string]$Hash)
        [System.IO.File]::WriteAllBytes($probeStep, $stepBytes)
        [System.IO.File]::WriteAllText($probeZip, 'stand-in archive')
        $said = @(& ([scriptblock]::Create((Get-ElevatedLauncher -StageFile $probeStep -Zip $probeZip -Hash $Hash))) 6>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ Said = ($said -join "`n"); StepLeft = (Test-Path -LiteralPath $probeStep); ZipLeft = (Test-Path -LiteralPath $probeZip) }
    }
    $rightHash = & $runLauncher (Get-Sha256Hex -Bytes $stepBytes)
    Assert-That ($rightHash.Said -ceq 'the step ran' -and $rightHash.StepLeft -and $rightHash.ZipLeft) "started with the hash the file has, the command runs the step's text, and leaves the files to the step ('$($rightHash.Said)')"
    $wrongHash = & $runLauncher ('0' * 64)
    Assert-That ($wrongHash.Said -match 'Stopped: the file that carries the step with administrator rights was changed or removed' -and $wrongHash.Said -match 'Nothing was installed or changed' -and $wrongHash.Said -notmatch 'the step ran' -and -not $wrongHash.StepLeft -and -not $wrongHash.ZipLeft) "a file that does not have the hash the window was started with is not run: the command says so and removes both files ($($wrongHash.Said -replace '\s+', ' '))"
    $goneFile = @(& ([scriptblock]::Create((Get-ElevatedLauncher -StageFile (Join-Path $fileWork 'no-such-step.txt') -Zip (Join-Path $fileWork 'no-such.zip') -Hash (Get-Sha256Hex -Bytes $stepBytes)))) 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-That ($goneFile -match 'Stopped: ' -and $goneFile -notmatch 'the step ran') 'a file that is gone is refused the same way'

    Write-Host "`n=== unpacking: the toolkit only, and no name decides where a file lands ===" -ForegroundColor Cyan
    $topName = "example-repo-$shaNew"
    $goodEntries = @(@{ Name = "$topName/"; Text = '' }, @{ Name = "$topName/README.md"; Text = 'outside local-llm' }, @{ Name = "$topName/.github/workflows/ci.yml"; Text = 'on: push' }, @{ Name = "$topName/local-llm/"; Text = '' })
    foreach ($path in $arrived.Keys) { $goodEntries += @{ Name = "$topName/$path"; Text = $utf8.GetString($arrived[$path]) } }
    $goodZip = Join-Path $fileWork 'good.zip'
    New-TestZip $goodZip $goodEntries
    $unpackTo = Join-Path $fileWork 'unpacked'
    $topFolder = Expand-ToolkitArchive -Zip $goodZip -Destination $unpackTo
    $unpacked = Get-ToolkitFileList -Top $topFolder
    $unpackedDiff = Compare-ToolkitTree -Manifest $manifest -Files $unpacked
    Assert-That ((Split-Path -Leaf $topFolder) -ceq $topName -and (Test-Path -LiteralPath $topFolder -PathType Container) -and @($unpacked).Count -eq 4 -and $unpackedDiff.Count -eq 0 -and (Get-ToolkitDigest -Files $unpacked) -ceq (Get-ToolkitDigest -Files $manifest)) "an archive as GitHub sends it is unpacked, and the files that were unpacked are the commit's list of files, by name and by id ($(@($unpacked).Count) file(s); $($unpackedDiff -join '; '))"
    Assert-That (-not (Test-Path -LiteralPath (Join-Path $topFolder 'README.md')) -and -not (Test-Path -LiteralPath (Join-Path $topFolder '.github')) -and @(Get-ChildItem -LiteralPath $topFolder -Force).Count -eq 1) 'nothing outside local-llm is unpacked: it is not compared, so it is not there to be run either'
    $backslashZip = Join-Path $fileWork 'backslash.zip'
    New-TestZip $backslashZip @(@{ Name = "$topName\local-llm\Install-LocalAI.ps1"; Text = 'one' }, @{ Name = "$topName\local-llm\lib\LocalAI.psm1"; Text = 'two' })
    $backslashList = Get-ToolkitFileList -Top (Expand-ToolkitArchive -Zip $backslashZip -Destination (Join-Path $fileWork 'unpacked-backslash'))
    $backslashPaths = @($backslashList | ForEach-Object { $_.Path } | Sort-Object)
    Assert-That (($backslashPaths -join ' ') -ceq 'local-llm/Install-LocalAI.ps1 local-llm/lib/LocalAI.psm1') "names written with '\' between their parts (Compress-Archive of Windows PowerShell 5.1 does that) are the same files ($($backslashPaths -join ' '))"
    $hostile = [ordered]@{
        'a name that climbs out with ..'      = @(@{ Name = "$topName/local-llm/ok.txt"; Text = 'ok' }, @{ Name = "$topName/local-llm/../../escaped.txt"; Text = 'out' })
        'a name that starts above the folder' = @(@{ Name = '../escaped.txt'; Text = 'out' })
        'a name from the root'                = @(@{ Name = "/$topName/local-llm/escaped.txt"; Text = 'out' })
        'a name with a drive'                 = @(@{ Name = "$topName/local-llm/C:/escaped.txt"; Text = 'out' })
        'a name with a stream'                = @(@{ Name = "$topName/local-llm/ok.txt:escaped.txt"; Text = 'out' })
        'a folder name that ends in a dot'    = @(@{ Name = "$topName/local-llm./escaped.txt"; Text = 'out' })
        'a second top folder'                 = @(@{ Name = "$topName/local-llm/ok.txt"; Text = 'ok' }, @{ Name = 'other-top/local-llm/escaped.txt'; Text = 'out' })
        'a file beside the top folder'        = @(@{ Name = 'escaped.txt'; Text = 'out' })
        'the same file twice'                 = @(@{ Name = "$topName/local-llm/ok.txt"; Text = 'one' }, @{ Name = "$topName/local-llm/ok.txt"; Text = 'two' })
        'a file where a folder has to be'     = @(@{ Name = "$topName/local-llm/lib"; Text = 'a file' }, @{ Name = "$topName/local-llm/lib/escaped.txt"; Text = 'out' })
        'no entry at all'                     = @()
    }
    $notRefused = New-Object System.Collections.Generic.List[string]
    $number = 0
    foreach ($kind in $hostile.Keys) {
        $number++
        $hostileZip = Join-Path $fileWork "hostile-$number.zip"
        New-TestZip $hostileZip $hostile[$kind]
        $threw = $false
        try { $null = Expand-ToolkitArchive -Zip $hostileZip -Destination (Join-Path (Join-Path $fileWork "hostile-$number") 'inner') } catch { $threw = $true }
        if (-not $threw) { $notRefused.Add($kind) }
    }
    $escaped = @(Get-ChildItem -LiteralPath $fileWork -Recurse -Force -File | Where-Object { $_.Name -eq 'escaped.txt' })
    Assert-That ($notRefused.Count -eq 0 -and $escaped.Count -eq 0) "an archive with a name that would land somewhere else is refused as a whole, and none of those files is written anywhere ($($hostile.Count) kinds; not refused: $($notRefused -join ', '); written: $($escaped.Count))"
    $tooMuch = ''
    try { $null = Expand-ToolkitArchive -Zip $goodZip -Destination (Join-Path $fileWork 'unpacked-capped') -MaxBytes 20 } catch { $tooMuch = $_.Exception.Message }
    Assert-That ($tooMuch -match 'far more than a toolkit holds') "an archive that unpacks to more than the limit is given up on ('$tooMuch')"
    (Get-Item -LiteralPath (Join-Path (Join-Path $topFolder 'local-llm') 'VERSION')).IsReadOnly = $true
    Remove-ToolkitTree -Path $unpackTo
    Remove-ToolkitTree -Path $unpackTo
    Assert-That (-not (Test-Path -LiteralPath $unpackTo)) 'a folder is removed with all that is in it, a read-only file included; removing what is not there is no error'
    Remove-Item -LiteralPath $fileWork -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host '  (the review functions are missing: their tests cannot run)' -ForegroundColor Red
}

# ---- the bootstrap's own flow, read from its syntax tree (not run) ---------------------------------
Write-Host "`n=== Get-LocalAI.ps1: one question, before the download and the installer ===" -ForegroundColor Cyan
$commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
$asks = @($commands | Where-Object { $_.GetCommandName() -eq 'Read-Host' })
# Invoke-WebRequest with -OutFile is the download of the toolkit; without it, a question to GitHub
# whose answer is only read (Get-GitHubText).
$webRequests = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-WebRequest' })
$downloads = @($webRequests | Where-Object { @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'OutFile' }).Count -gt 0 })
$questions = @($webRequests | Where-Object { $downloads -notcontains $_ })
# The bootstrap does not start the installer itself any more: it asks Windows for administrator
# rights once (Start-Process -Verb RunAs), for the step that checks the download again and then
# starts the installer from its own folder. So: one question, then one download, then that one request.
$ownerFunction = {
    # The function a node of the syntax tree stands in; $null for the bootstrap's own flow.
    param($Node)
    $at = $Node.Parent
    while ($at -and $at -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $at = $at.Parent }
    return $at
}
$elevations = @($commands | Where-Object { $_.GetCommandName() -eq 'Start-Process' })
$inOrder = ($asks.Count -eq 1 -and $downloads.Count -eq 1 -and $elevations.Count -eq 1)
if ($inOrder) { $inOrder = ($asks[0].Extent.StartOffset -lt $downloads[0].Extent.StartOffset -and $downloads[0].Extent.StartOffset -lt $elevations[0].Extent.StartOffset) }
if ($inOrder) { $inOrder = ($null -eq (& $ownerFunction $asks[0]) -or (& $ownerFunction $asks[0]).Name -eq 'Get-UpdateConsent') -and $null -eq (& $ownerFunction $downloads[0]) -and $null -eq (& $ownerFunction $elevations[0]) -and $elevations[0].Extent.Text -match '-Verb RunAs\b' }
Assert-That $inOrder "the bootstrap asks once, before its one download and its one request for administrator rights (Read-Host: $($asks.Count), Invoke-WebRequest -OutFile: $($downloads.Count), Start-Process -Verb RunAs: $($elevations.Count))"
# The installer is started in exactly one place: in the step with administrator rights, by the
# full path of Windows PowerShell, from the folder that step made under Program Files.
$starts = @($commands | Where-Object { $_.InvocationOperator -eq 'Ampersand' -and @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'File' }).Count -gt 0 })
$byBareName = @($commands | Where-Object { @('powershell', 'powershell.exe', 'pwsh', 'pwsh.exe') -contains $_.GetCommandName() })
$stepAst = $null
if ($starts.Count -eq 1) { $stepAst = & $ownerFunction $starts[0] }
Assert-That ($starts.Count -eq 1 -and $byBareName.Count -eq 0 -and $stepAst -and $stepAst.Name -eq 'Invoke-ElevatedInstall' -and $starts[0].Extent.Text -like '& $shell *-File $installer *') "the installer is started in one place only, inside Invoke-ElevatedInstall, by a full path and not by a name looked up on the PATH (starts: $($starts.Count), by bare name: $($byBareName.Count))"
if ($stepAst) {
    $inStep = @($stepAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    $members = @($stepAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
    $firstOffset = { param($Nodes) $all = @($Nodes); if ($all.Count -gt 0) { return $all[0].Extent.StartOffset }; return -1 }
    $ruleChecks = @($inStep | Where-Object { $_.GetCommandName() -eq 'Test-AdminOnlyRule' })
    $stepOrder = [ordered]@{
        'the folder above is checked'  = (& $firstOffset @($ruleChecks | Where-Object { $_.Extent.Text -match '-Parent\b' }))
        'the folder is made'           = (& $firstOffset @($members | Where-Object { [string]$_.Member.Value -eq 'CreateDirectory' }))
        'owner and rules are set'      = (& $firstOffset @($inStep | Where-Object { $_.GetCommandName() -eq 'Set-AdminOnlyRule' }))
        'the rules are read back'      = (& $firstOffset @($ruleChecks | Where-Object { $_.Extent.Text -notmatch '-Parent\b' }))
        'the archive is copied in'     = (& $firstOffset @($members | Where-Object { [string]$_.Member.Value -eq 'Copy' }))
        'it is unpacked there'         = (& $firstOffset @($inStep | Where-Object { $_.GetCommandName() -eq 'Expand-ToolkitArchive' }))
        'its digest is taken'          = (& $firstOffset @($inStep | Where-Object { $_.GetCommandName() -eq 'Get-ToolkitDigest' }))
        'the digest is compared'       = (& $firstOffset @($stepAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$found -cne $Digest' }, $true)))
        'COMMIT is written'            = (& $firstOffset @($members | Where-Object { [string]$_.Member.Value -eq 'WriteAllText' -and $_.Extent.Text -match "'COMMIT'" }))
        'the installer is started'     = $starts[0].Extent.StartOffset
    }
    $offsets = @($stepOrder.Values)
    $outOfOrder = @(0..($offsets.Count - 2) | Where-Object { $offsets[$_] -lt 0 -or $offsets[$_] -ge $offsets[$_ + 1] })
    Assert-That ($ruleChecks.Count -eq 2 -and $outOfOrder.Count -eq 0) "inside that step: the folder above is checked, the folder is made, given to administrators alone, its rules read back, the archive copied in, unpacked, its digest compared, COMMIT written, and only then the installer started (out of order at: $(@($outOfOrder | ForEach-Object { @($stepOrder.Keys)[$_] }) -join ', '))"
    $refusals = @($stepAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true))
    $outerTry = $stepAst.Find({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)
    $cleaning = @()
    if ($outerTry -and $outerTry.Finally) { $cleaning = @($outerTry.Finally.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() }) }
    $startInTry = ($outerTry -and $starts[0].Extent.StartOffset -gt $outerTry.Body.Extent.StartOffset -and $starts[0].Extent.EndOffset -lt $outerTry.Body.Extent.EndOffset)
    Assert-That ($refusals.Count -ge 8 -and @($refusals | Where-Object { $_.Extent.StartOffset -gt $starts[0].Extent.StartOffset }).Count -eq 0 -and $startInTry -and $cleaning -contains 'Remove-ToolkitTree' -and @($cleaning | Where-Object { $_ -eq 'Remove-HandedOverFile' }).Count -eq 2) "every refusal of the step comes before the installer start ($($refusals.Count) of them), and whatever happens its 'finally' removes the folder and the two files in the temp folder (it calls: $($cleaning -join ', '))"
    $stepStrings = @($stepAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
    $stepEnv = @($stepAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.DriveName -eq 'env' }, $true))
    Assert-That ($stepStrings -contains 'ProgramFiles' -and $stepStrings -contains 'LocalAI-Update' -and $stepStrings -notcontains 'LocalAI' -and $stepStrings -contains 'System' -and $stepEnv.Count -eq 0 -and $stepAst.Extent.Text -match "GetFolderPath\('ProgramFiles'\)") "the step asks Windows where Program Files is (no variable of the session decides it) and works in LocalAI-Update there, not in the installer's own LocalAI folder"
} else {
    Assert-That $false 'the step with administrator rights could not be found in the syntax tree: its order cannot be checked'
}
$recursiveRemovals = @($commands | Where-Object { @('Remove-Item', 'rm', 'del', 'rmdir', 'rd', 'ri', 'erase') -contains $_.GetCommandName() -and @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and ($_.ParameterName -like 'rec*' -or $_.ParameterName -eq 'r') }).Count -gt 0 })
$archiveCmdlets = @($commands | Where-Object { $_.GetCommandName() -eq 'Expand-Archive' })
Assert-That ($recursiveRemovals.Count -eq 0 -and $archiveCmdlets.Count -eq 0) "nothing in the bootstrap removes a folder with Remove-Item -Recurse (Windows PowerShell 5.1 walks into junctions with it) or unpacks with Expand-Archive (recursive removals: $($recursiveRemovals.Count), Expand-Archive: $($archiveCmdlets.Count))"
# Before the question: GitHub's list of the commit's files, by the commit's id, and the check that
# stops an update without one. Its stop comes before the question and before the download, and the
# download's address is still the one the review built from the commit id.
$treeCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Get-GitHubText' -and $_.Extent.Text -match 'api\.github\.com/repos/\$repo/git/trees/\$\(\$review\.Commit\)\?recursive=1' })
$checkCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Get-DownloadCheck' })
$stopReturns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$check.Stop' -and $null -ne $n.Clauses[0].Item2.Find({ param($m) $m -is [System.Management.Automation.Language.ReturnStatementAst] }, $true) }, $true))
$urlAssignments = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$url' }, $true) | Where-Object { $null -eq (& $ownerFunction $_) })
$checkedFirst = ($treeCalls.Count -eq 1 -and $checkCalls.Count -eq 1 -and $stopReturns.Count -eq 1 -and $asks.Count -eq 1 -and $downloads.Count -eq 1)
if ($checkedFirst) { $checkedFirst = ($treeCalls[0].Extent.StartOffset -lt $checkCalls[0].Extent.StartOffset -and $checkCalls[0].Extent.StartOffset -lt $stopReturns[0].Extent.StartOffset -and $stopReturns[0].Extent.StartOffset -lt $asks[0].Extent.StartOffset) }
Assert-That $checkedFirst "the list of the commit's files is asked for by the commit's id, and an update without it is stopped before the question and before the download (tree calls: $($treeCalls.Count), checks: $($checkCalls.Count), stops: $($stopReturns.Count))"
Assert-That ($downloads.Count -eq 1 -and $downloads[0].Extent.Text -match '-Uri \$url\b' -and $urlAssignments.Count -eq 1 -and $urlAssignments[0].Right.Extent.Text -eq '$review.Url') 'and the download still goes to the address the review built from the commit id, nowhere else'
$askOwner = $null
if ($asks.Count -eq 1) { $askOwner = $asks[0].Parent; while ($askOwner -and $askOwner -isnot [System.Management.Automation.Language.CommandAst]) { $askOwner = $askOwner.Parent } }
Assert-That ($askOwner -and $askOwner.GetCommandName() -eq 'Get-UpdateConsent') 'and only through the gate: Get-UpdateConsent decides whether to ask and what the answer means'
# GitHub is asked through one function that hands back text; Invoke-RestMethod is not used (on Windows
# PowerShell 5.1 it hands a long answer back unread, and the file list would be missing).
$questionOwner = $null
if ($questions.Count -eq 1) { $questionOwner = $questions[0].Parent; while ($questionOwner -and $questionOwner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $questionOwner = $questionOwner.Parent } }
$restCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-RestMethod' })
$textCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Get-GitHubText' })
Assert-That ($questions.Count -eq 1 -and $questionOwner -and $questionOwner.Name -eq 'Get-GitHubText' -and $restCalls.Count -eq 0 -and $textCalls.Count -eq 4) "GitHub's answers are fetched as text in one place (Get-GitHubText: commit, its page, comparison, the commit's list of files) and never through Invoke-RestMethod (calls: $($textCalls.Count), Invoke-RestMethod: $($restCalls.Count))"
$pageCalls = @($textCalls | Where-Object { $_.Extent.Text -match 'github\.com/\$repo/commit/' })
Assert-That ($pageCalls.Count -eq 1 -and $asks.Count -eq 1 -and $pageCalls[0].Extent.StartOffset -lt $asks[0].Extent.StartOffset -and $pageCalls[0].Extent.Text -notmatch 'api\.github\.com') "the commit's page on github.com (not the API) is the second source for the commit, asked before the question"
# LOCALAI_REF is part of every address GitHub is asked for: it is checked before the first of them.
$refChecks = @($commands | Where-Object { $_.GetCommandName() -eq 'Test-ToolkitRef' })
$firstFetch = @($commands | Where-Object { @('Invoke-RestMethod', 'Invoke-WebRequest', 'Get-GitHubText') -contains $_.GetCommandName() -and $_ -ne $questions[0] } | ForEach-Object { $_.Extent.StartOffset } | Sort-Object | Select-Object -First 1)
Assert-That ($refChecks.Count -eq 1 -and $firstFetch.Count -eq 1 -and $refChecks[0].Extent.StartOffset -lt $firstFetch[0]) "the ref is checked to be a plain name before GitHub is asked anything (checks: $($refChecks.Count))"
# Every setting the bootstrap takes from outside is an environment variable (it has no parameters:
# 'irm | iex' could not pass any). A new one is a new way in and has to be added here on purpose.
# ProgramData is not among them: a session that points it at an empty folder would make an install
# in another AI folder pass for a first install, a second way around the question.
$envVars = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.DriveName -eq 'env' }, $true))
$envNames = @($envVars | ForEach-Object { $_.VariablePath.UserPath -replace '^env:', '' })
$allowed = @('LOCALAI_REF', 'LOCALAI_ROOT', 'LOCALAI_ARGS', 'LOCALAI_REVIEWED_COMMIT', 'TEMP')
$unexpected = @($envNames | Where-Object { $allowed -notcontains $_ } | Select-Object -Unique)
Assert-That ($null -eq $ast.ParamBlock -and $unexpected.Count -eq 0) "the bootstrap takes no parameters and reads only the documented environment variables (others: $($unexpected -join ', '))"
$skipReads = @($envVars | Where-Object { $_.VariablePath.UserPath -eq 'env:LOCALAI_REVIEWED_COMMIT' })
$skipOwner = $null
if ($skipReads.Count -eq 1) { $skipOwner = $skipReads[0].Parent; while ($skipOwner -and $skipOwner -isnot [System.Management.Automation.Language.CommandAst]) { $skipOwner = $skipOwner.Parent } }
Assert-That ($skipReads.Count -eq 1 -and $skipOwner -and $skipOwner.GetCommandName() -eq 'Get-UpdateReview') "LOCALAI_REVIEWED_COMMIT is read in exactly one place and handed to the review, which alone decides ($($skipReads.Count) read(s))"
$firstCodeLine = $ast.EndBlock.Extent.StartLineNumber
$header = (@($tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Extent.StartLineNumber -lt $firstCodeLine } | ForEach-Object { $_.Text }) -join "`n")
Assert-That ($header -match 'LOCALAI_REVIEWED_COMMIT' -and $header -match 'typed OK') 'the comment at the top of the file documents the review and the one way to skip it'
Assert-That ($header -match 'only as trustworthy as the copy of this file' -and $header -match 'replace refs/heads/main' -and $header -match 'not what changed inside them' -and $header -match 'already runs under your Windows account' -and $header -match 'fork') 'and where the review ends: the command that fetches this file from main, file names without their contents, a program of the same user, a commit id that may be from a fork'
# The installer creates its Start-menu folder under the all-users Start menu. The bootstrap asks
# Windows where that is (the known folder CommonPrograms), not the session's ProgramData variable;
# the two files have to mean the same folder, or an install in another AI folder passes for a first
# install.
$menuPath = 'Microsoft\Windows\Start Menu\Programs\Local AI'
$stringsInBootstrap = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
$installerText = [System.IO.File]::ReadAllText((Join-Path $src 'Install-LocalAI.ps1'))
Assert-That (@($stringsInBootstrap | Where-Object { $_ -eq 'CommonPrograms' }).Count -eq 1 -and @($stringsInBootstrap | Where-Object { $_ -eq 'Local AI' }).Count -eq 1 -and @($stringsInBootstrap | Where-Object { $_ -clike '*Start Menu\Programs*' }).Count -eq 0 -and $installerText.Contains("Join-Path `$env:ProgramData '$menuPath'")) "the bootstrap takes the all-users Start menu from Windows (CommonPrograms) and looks for the installer's 'Local AI' folder in it"
$realPrograms = ''
try { $realPrograms = [string][Environment]::GetFolderPath('CommonPrograms') } catch { $realPrograms = '' }
if ($onWindows) {
    Assert-That ($realPrograms -and $env:ProgramData -and $realPrograms.TrimEnd('\') -eq (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')) "on Windows that is the folder the installer writes to (%ProgramData%\Microsoft\Windows\Start Menu\Programs: '$realPrograms')"
} else {
    Skip 'where Windows keeps the all-users Start menu (the Windows job checks this)'
}
# The resume after a reboot must not come through the bootstrap: nobody is there to type OK at
# sign-in. The installer's logon task starts the copy of the installer that was already downloaded.
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Install-LocalAI.ps1'), [ref]$null, [ref]$null)
$resumeFn = $installerAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Register-ResumeTask' }, $true)
$resumeText = ''; if ($resumeFn) { $resumeText = $resumeFn.Extent.Text }
Assert-That ($resumeText -match 'Install-LocalAI\.ps1' -and $resumeText -notmatch 'Get-LocalAI') "the installer's after-reboot task starts Install-LocalAI.ps1 itself, not this bootstrap: a resume is never held up by the question"

# ---- the whole bootstrap in a child process (Windows: it starts powershell.exe) --------------------
Write-Host "`n=== Get-LocalAI.ps1 end to end, with a stand-in for GitHub ===" -ForegroundColor Cyan
if ($onWindows) {
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
    $e2e = Join-Path $Work 'e2e'
    $e2eTemp = Join-Path $e2e 'temp'
    $apiFull = Join-Path $e2e 'api-full'
    $apiNoCompare = Join-Path $e2e 'api-no-compare'
    $apiNone = Join-Path $e2e 'api-none'
    # GitHub's API over its limit while github.com answers; and a comparison of over 2 million characters.
    $apiPage = Join-Path $e2e 'api-page-only'
    $apiLarge = Join-Path $e2e 'api-large'
    $rootInstalled = Join-Path $e2e 'root-installed'
    $rootEmpty = Join-Path $e2e 'root-empty'
    # AI folders that each hold one trace of an install the bootstrap looks for, and nothing else.
    $rootStateOnly = Join-Path $e2e 'root-state-only'
    $rootScriptsOnly = Join-Path $e2e 'root-scripts-only'
    $rootDamaged = Join-Path $e2e 'root-damaged'
    $rootLocked = Join-Path $e2e 'root-locked'
    # The installer's Start-menu folder, where Windows keeps it for all users. The bootstrap looks
    # there and nowhere a session variable could point it, so no stand-in can take its place: on a
    # test machine that has none, it is created for one run below and removed again.
    $realMenu = ''
    if ($realPrograms) { $realMenu = Join-Path $realPrograms 'Local AI' }
    $menuWasThere = ($realMenu -and (Test-Path -LiteralPath $realMenu))
    # GitHub's API answering for the commit and the comparison but not for the list of the commit's
    # files; and answering with a list it cut off.
    $apiNoTree = Join-Path $e2e 'api-no-tree'
    $apiCutTree = Join-Path $e2e 'api-cut-tree'
    # Where the step with administrator rights makes its folder on this (throwaway) machine.
    $programFilesReal = [Environment]::GetFolderPath('ProgramFiles')
    $stagingReal = Join-Path $programFilesReal 'LocalAI-Update'
    $zipTop = Join-Path (Join-Path $e2e 'zipsrc') "ComfyUi-Optimization-$shaNew"
    $zipLlm = Join-Path $zipTop 'local-llm'
    foreach ($d in @($e2eTemp, $apiFull, $apiNoCompare, $apiNone, $apiPage, $apiLarge, $apiNoTree, $apiCutTree, $rootInstalled, $rootEmpty, $rootStateOnly, (Join-Path $rootScriptsOnly 'Scripts'), $rootDamaged, $rootLocked, (Join-Path $zipLlm 'lib'))) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $e2eLog = Join-Path $e2e 'calls.log'
    $harness = Join-Path $e2e 'harness.ps1'
    $zipFile = Join-Path $e2e 'toolkit.zip'
    $zipOneByte = Join-Path $e2e 'toolkit-one-byte.zip'
    $zipExtra = Join-Path $e2e 'toolkit-extra-file.zip'
    $zipMissing = Join-Path $e2e 'toolkit-missing-file.zip'

    # The archive GitHub would send: one top folder, local-llm inside it. Its "installer" only writes
    # down that it ran and which COMMIT file was put next to it; and, in a second file, where it ran
    # from, the rules of the folder two levels up (the one the step with administrator rights made),
    # whether it has administrator rights, the options it was given, and whether the step's lock
    # file was there.
    $installerStub = @'
param([string]$AIRoot)
$commit = ''
$commitFile = Join-Path $PSScriptRoot 'COMMIT'
if (Test-Path -LiteralPath $commitFile) { $commit = [System.IO.File]::ReadAllText($commitFile) }
[System.IO.File]::WriteAllText((Join-Path $AIRoot 'installer-ran.txt'), ('commit=' + $commit))
$madeFolder = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$asAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
[System.IO.File]::WriteAllLines((Join-Path $AIRoot 'installer-from.txt'), [string[]]@($PSScriptRoot, (Get-Acl -LiteralPath $madeFolder).Sddl, [string]$asAdmin, ($args -join ' '), [string](Test-Path -LiteralPath (Join-Path $madeFolder 'in-use'))))
exit 0
'@
    $moduleFile = Join-Path (Join-Path $zipLlm 'lib') 'LocalAI.psm1'
    [System.IO.File]::WriteAllText((Join-Path $zipLlm 'Install-LocalAI.ps1'), $installerStub)
    [System.IO.File]::WriteAllText((Join-Path $zipLlm 'Install-LocalAI.cmd'), "@echo off`r`nrem stand-in`r`n")
    [System.IO.File]::WriteAllText((Join-Path $zipLlm 'VERSION'), '2099.01.02')
    [System.IO.File]::WriteAllText($moduleFile, "# stand-in module`n")
    [System.IO.File]::WriteAllText((Join-Path $zipTop 'README.md'), 'outside local-llm')
    # GitHub's list of that commit's files, with the ids git gives them: of the bytes as they are in
    # the archive, and for the .cmd (CRLF in the archive) of its LF form, as the repository holds it.
    $encoding = [System.Text.Encoding]::UTF8
    $standInTree = @(@{ path = 'README.md'; mode = '100644'; type = 'blob'; sha = (Get-GitBlobId -Bytes ([System.IO.File]::ReadAllBytes((Join-Path $zipTop 'README.md')))) }, @{ path = 'local-llm'; mode = '040000'; type = 'tree'; sha = ('0' * 40) }, @{ path = 'local-llm/lib'; mode = '040000'; type = 'tree'; sha = ('0' * 40) })
    foreach ($relative in @('Install-LocalAI.ps1', 'Install-LocalAI.cmd', 'VERSION', 'lib/LocalAI.psm1')) {
        $fileBytes = [System.IO.File]::ReadAllBytes((Join-Path $zipLlm ($relative.Replace('/', '\'))))
        if ($relative -like '*.cmd') { $fileBytes = $encoding.GetBytes($encoding.GetString($fileBytes).Replace("`r`n", "`n")) }
        $standInTree += @{ path = "local-llm/$relative"; mode = '100644'; type = 'blob'; sha = (Get-GitBlobId -Bytes $fileBytes) }
    }
    $treeJson = ConvertTo-Json -Depth 6 -InputObject @{ sha = ('f' * 40); truncated = $false; tree = $standInTree }
    $cutTreeJson = ConvertTo-Json -Depth 6 -InputObject @{ sha = ('f' * 40); truncated = $true; tree = $standInTree }
    # Four archives: the commit as it is; one byte different in one file; one file more; one file less.
    Compress-Archive -LiteralPath $zipTop -DestinationPath $zipFile -Force
    [System.IO.File]::WriteAllText($moduleFile, "# stand-in modulf`n")
    Compress-Archive -LiteralPath $zipTop -DestinationPath $zipOneByte -Force
    [System.IO.File]::WriteAllText($moduleFile, "# stand-in module`n")
    [System.IO.File]::WriteAllText((Join-Path $zipLlm 'Extra-Tool.ps1'), '# not in the commit')
    Compress-Archive -LiteralPath $zipTop -DestinationPath $zipExtra -Force
    Remove-Item -LiteralPath (Join-Path $zipLlm 'Extra-Tool.ps1') -Force
    Remove-Item -LiteralPath (Join-Path $zipLlm 'VERSION') -Force
    Compress-Archive -LiteralPath $zipTop -DestinationPath $zipMissing -Force
    [System.IO.File]::WriteAllText((Join-Path $zipLlm 'VERSION'), '2099.01.02')

    # GitHub's answers, and an installed copy that records the old commit.
    $commitJson = ConvertTo-Json -Depth 6 -InputObject @{ sha = $shaNew; commit = @{ message = "Stand-in incoming subject`n`nbody"; committer = @{ date = '2026-10-06T23:30:00Z' } } }
    $compareJson = ConvertTo-Json -Depth 8 -InputObject @{
        status = 'ahead'; ahead_by = 2; behind_by = 0; total_commits = 2
        base_commit = @{ sha = $shaOld; commit = @{ message = 'Stand-in installed subject'; committer = @{ date = '2026-10-05T10:00:00Z' } } }
        files = @(@{ filename = 'local-llm/Install-LocalAI.ps1'; status = 'modified' }, @{ filename = 'local-llm/tests/Invoke-Some.ps1'; status = 'added' })
    }
    [System.IO.File]::WriteAllText((Join-Path $apiFull 'commit.json'), $commitJson)
    [System.IO.File]::WriteAllText((Join-Path $apiFull 'compare.json'), $compareJson)
    [System.IO.File]::WriteAllText((Join-Path $apiNoCompare 'commit.json'), $commitJson)
    [System.IO.File]::WriteAllText((Join-Path $apiPage 'commit.patch'), "From $shaNew Mon Sep 17 00:00:00 2001`nFrom: A Committer <committer@example.invalid>`nDate: Tue, 6 Oct 2026 23:30:00 +0000`nSubject: [PATCH] Stand-in incoming subject`n`nbody`n---`n")
    # The same comparison with a field of 2.3 million characters in it (patches, in GitHub's answer).
    $largeJson = $compareJson.Substring(0, $compareJson.LastIndexOf('}')) + ', "padding": "' + ('x' * 2300000) + '"}'
    [System.IO.File]::WriteAllText((Join-Path $apiLarge 'commit.json'), $commitJson)
    [System.IO.File]::WriteAllText((Join-Path $apiLarge 'compare.json'), $largeJson)
    # The list of the commit's files: there wherever the API answers in full, missing in one folder
    # (the API refuses that one question), cut off in another. The folder where only the commit's
    # page answers has none: the API refuses everything there.
    foreach ($apiFolder in @($apiFull, $apiNoCompare, $apiLarge)) { [System.IO.File]::WriteAllText((Join-Path $apiFolder 'tree.json'), $treeJson) }
    foreach ($apiFolder in @($apiNoTree, $apiCutTree)) {
        [System.IO.File]::WriteAllText((Join-Path $apiFolder 'commit.json'), $commitJson)
        [System.IO.File]::WriteAllText((Join-Path $apiFolder 'compare.json'), $compareJson)
    }
    [System.IO.File]::WriteAllText((Join-Path $apiCutTree 'tree.json'), $cutTreeJson)
    $installedConfig = ConvertTo-Json -InputObject @{ AIRoot = $rootInstalled; ToolkitVersion = '2026.10.05'; ToolkitCommit = $shaOld }
    [System.IO.File]::WriteAllText((Join-Path $rootInstalled 'localai-config.json'), $installedConfig)
    # One trace each: the installer's state file (an install that did not finish), the installed copy
    # of the installer, a config cut off mid-write, and a config that is there but cannot be opened.
    [System.IO.File]::WriteAllText((Join-Path $rootStateOnly 'install-state.json'), '{}')
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $rootScriptsOnly 'Scripts') 'Install-LocalAI.ps1'), '# stand-in')
    [System.IO.File]::WriteAllText((Join-Path $rootDamaged 'localai-config.json'), '{"ToolkitCommit": "1a2b')
    $lockedConfig = Join-Path $rootLocked 'localai-config.json'
    [System.IO.File]::WriteAllText($lockedConfig, $installedConfig)

    # The harness: a function with the name of the one cmdlet that reaches GitHub (functions win over
    # cmdlets; Invoke-RestMethod fails the run, should it come back), then the bootstrap's text
    # through Invoke-Expression, as 'irm | iex' runs it. An answer is handed over as text, the way
    # the cmdlet does it: the bootstrap's own JSON reader has to read it, the long one included.
    # Windows is not asked for administrator rights either (the test machine's user has them, and
    # nobody is there to click Yes): the stand-in for Start-Process starts the same program with the
    # same arguments, joined by spaces as Start-Process hands them over, and waits for it. Only
    # -NoExit is left out, which would keep that window open. Before it starts the program it can
    # play the program of the user that the step is written against: put another archive in the temp
    # folder (-StandInSwap), or change the file with the step's text (-StandInEdit).
    # Everything else is the real thing: the review, the gate, Read-Host, the comparison, the command
    # line of the window with administrator rights, the step itself with its folder under Program
    # Files, and Windows PowerShell for the installer.
    # The stand-ins are called from inside the bootstrap's script block, and PowerShell looks a
    # variable up in the caller's scope first: a harness value named like one of the bootstrap's own
    # variables ($zip, $root, $ref) would be read as the bootstrap's. Hence the StandIn names, and
    # $script: wherever a stand-in function reads one.
    $harnessText = @'
param([string]$StandInBootstrap, [string]$StandInZip, [string]$StandInLog, [string]$StandInApi, [string]$StandInRoot, [string]$StandInRef, [string]$StandInReviewed, [string]$StandInTemp, [string]$StandInProgramData, [string]$StandInOptions, [string]$StandInSwap, [string]$StandInEdit)
$ErrorActionPreference = 'Stop'
$env:TEMP = $StandInTemp
if ($StandInProgramData -ne 'NONE') { $env:ProgramData = $StandInProgramData }
$env:LOCALAI_ROOT = $StandInRoot
$env:LOCALAI_REF = $StandInRef
$env:LOCALAI_ARGS = ''
# The options arrive behind 'options=': an argument that starts with a dash would be taken for a parameter.
if ($StandInOptions -ne 'NONE') { $env:LOCALAI_ARGS = $StandInOptions.Substring(8) }
$env:LOCALAI_REVIEWED_COMMIT = ''
if ($StandInReviewed -ne 'NONE') { $env:LOCALAI_REVIEWED_COMMIT = $StandInReviewed }
function Invoke-RestMethod {
    [System.IO.File]::AppendAllText($script:StandInLog, "REST $args`r`n")
    throw 'Invoke-RestMethod is not to be used by the bootstrap.'
}
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string[]]$ArgumentList, [string]$Verb)
    [System.IO.File]::AppendAllText($script:StandInLog, "START $Verb $FilePath`r`n")
    if ($script:StandInSwap -ne 'NONE') { Copy-Item -LiteralPath $script:StandInSwap -Destination (Join-Path $script:StandInTemp 'localai-installer.zip') -Force }
    if ($script:StandInEdit -ne 'NONE') { [System.IO.File]::AppendAllText((Join-Path $script:StandInTemp 'localai-elevated-step.txt'), "`n# changed after it was written") }
    $standInStart = New-Object System.Diagnostics.ProcessStartInfo
    $standInStart.FileName = $FilePath
    $standInStart.Arguments = (@($ArgumentList | Where-Object { $_ -ne '-NoExit' }) -join ' ')
    $standInStart.UseShellExecute = $false
    $standInStarted = [System.Diagnostics.Process]::Start($standInStart)
    $standInStarted.WaitForExit()
}
function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, $Headers, [switch]$UseBasicParsing, [int]$TimeoutSec)
    if ($OutFile) {
        [System.IO.File]::AppendAllText($script:StandInLog, "GET $Uri`r`n")
        Copy-Item -LiteralPath $script:StandInZip -Destination $OutFile -Force
        return
    }
    $standInName = 'commit.json'
    if ($Uri -like '*/compare/*') { $standInName = 'compare.json' }
    if ($Uri -like '*/git/trees/*') { $standInName = 'tree.json' }
    if ($Uri -like 'https://github.com/*/commit/*.patch') { $standInName = 'commit.patch'; [System.IO.File]::AppendAllText($script:StandInLog, "PAGE $Uri`r`n") }
    elseif ($Uri -like 'https://api.github.com/*') { [System.IO.File]::AppendAllText($script:StandInLog, "API $Uri`r`n") }
    else { [System.IO.File]::AppendAllText($script:StandInLog, "OTHER $Uri`r`n"); throw 'The stand-in for GitHub does not know this address.' }
    $standInFile = Join-Path $script:StandInApi $standInName
    if (-not (Test-Path -LiteralPath $standInFile)) { throw 'The remote server returned an error: (403) Forbidden.' }
    return [pscustomobject]@{ Content = [System.IO.File]::ReadAllText($standInFile) }
}
Invoke-Expression ([System.IO.File]::ReadAllText($StandInBootstrap))
'@
    [System.IO.File]::WriteAllText($harness, $harnessText)
    # No name the harness reads may be one the bootstrap assigns: that was a real fault here (the
    # download stand-in read the bootstrap's $zip, copied the target onto itself, and no installer ran).
    $bootstrapNames = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath } | Select-Object -Unique)
    $harnessAst = [System.Management.Automation.Language.Parser]::ParseInput($harnessText, [ref]$null, [ref]$null)
    $harnessNames = @($harnessAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath -replace '^script:', '' } | Where-Object { $_ -like 'StandIn*' } | Select-Object -Unique)
    $shared = @($harnessNames | Where-Object { $bootstrapNames -contains $_ })
    Assert-That ($harnessNames.Count -ge 9 -and $shared.Count -eq 0) "the harness's own values have names the bootstrap does not use ($($harnessNames.Count) names, shared: $($shared -join ', '))"

    function Invoke-Bootstrap {
        # One run of Get-LocalAI.ps1 through the harness; nobody can type on it: -NonInteractive, and
        # on the CI runner no keyboard at all. -Ref: LOCALAI_REF. -Reviewed: LOCALAI_REVIEWED_COMMIT
        # (NONE: not set). -ProgramData: a folder the session's ProgramData variable is pointed at
        # (NONE: left as it is). -PipeOk: the text OK is piped into the run instead (no
        # -NonInteractive, so a Read-Host would take it; the pipe closes after it, so nothing can
        # wait for more). -Zip: the archive GitHub's stand-in sends. -Options: LOCALAI_ARGS (NONE: not
        # set). -Swap: an archive put in the temp folder in place of the downloaded one, at the
        # moment Windows would ask for administrator rights (NONE: none). -Edit: the file with the
        # step's text is changed at that moment (NONE: left as it is).
        # Before the run, what an earlier run left in the temp folder is removed, so that every run
        # is judged by itself; after it, whatever is left there or under Program Files is recorded
        # (Left, and $leftBehind for all runs together).
        param([string]$Root, [string]$ApiDir, [string]$Ref = 'main', [string]$Reviewed = 'NONE', [string]$ProgramData = 'NONE', [switch]$PipeOk, [string]$Zip = $zipFile, [string]$Options = 'NONE', [string]$Swap = 'NONE', [string]$Edit = 'NONE')
        $marker = Join-Path $Root 'installer-ran.txt'
        $fromFile = Join-Path $Root 'installer-from.txt'
        foreach ($f in @($e2eLog, $marker, $fromFile)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
        foreach ($old in @(Get-ChildItem -LiteralPath $e2eTemp -Force | Where-Object { $_.Name -like 'localai*' })) { Remove-Item -LiteralPath $old.FullName -Recurse -Force }
        $optionsArgument = 'NONE'
        if ($Options -ne 'NONE') { $optionsArgument = 'options=' + $Options }
        $harnessArgs = @('-StandInBootstrap', $bootstrap, '-StandInZip', $Zip, '-StandInLog', $e2eLog, '-StandInApi', $ApiDir, '-StandInRoot', $Root, '-StandInRef', $Ref, '-StandInReviewed', $Reviewed, '-StandInTemp', $e2eTemp, '-StandInProgramData', $ProgramData,
            '-StandInOptions', $optionsArgument, '-StandInSwap', $Swap, '-StandInEdit', $Edit)
        $script:bootstrapRuns++
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        if ($PipeOk) { $out = 'OK' | & $childExe -NoProfile -ExecutionPolicy Bypass -File $harness @harnessArgs 2>&1 | ForEach-Object { "$_" } }
        else { $out = & $childExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness @harnessArgs 2>&1 | ForEach-Object { "$_" } }
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        $log = @(); if (Test-Path -LiteralPath $e2eLog) { $log = @([System.IO.File]::ReadAllLines($e2eLog)) }
        $ran = ''; if (Test-Path -LiteralPath $marker) { $ran = [System.IO.File]::ReadAllText($marker) }
        $from = @(); if (Test-Path -LiteralPath $fromFile) { $from = @([System.IO.File]::ReadAllLines($fromFile)) }
        $left = @(Get-ChildItem -LiteralPath $e2eTemp -Force | Where-Object { $_.Name -like 'localai*' } | ForEach-Object { 'temp folder: ' + $_.Name })
        if (Test-Path -LiteralPath $stagingReal) { $left += 'Program Files: LocalAI-Update' }
        foreach ($item in $left) { $leftBehind.Add("run $($script:bootstrapRuns): $item") }
        return [pscustomobject]@{
            Code  = $code
            Text  = (@($out) -join "`n")
            Tail  = (@($out | Where-Object { $_ } | Select-Object -Last 3) -join ' | ')
            Api   = @($log | Where-Object { $_ -like 'API *' })
            Page  = @($log | Where-Object { $_ -like 'PAGE *' })
            Odd   = @($log | Where-Object { $_ -like 'REST *' -or $_ -like 'OTHER *' })
            Get   = @($log | Where-Object { $_ -like 'GET *' })
            Start = @($log | Where-Object { $_ -like 'START *' })
            Ran   = $ran
            From  = $from
            Left  = $left
        }
    }
    $script:bootstrapRuns = 0
    $leftBehind = New-Object System.Collections.Generic.List[string]

    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull
    Assert-That ($r.Get.Count -eq 0 -and -not $r.Ran -and $r.Start.Count -eq 0 -and $r.Text -match 'Stopped: ' -and $r.Text -match 'Nothing was downloaded or changed') "an update with nobody to type OK: nothing is downloaded, no installer starts, and the run says so (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    Assert-That ($r.Text -match $shaOld -and $r.Text -match "To install\s+: commit $shaNew" -and $r.Text -match 'Stand-in installed subject' -and $r.Text -match '2026-10-06\s+Stand-in incoming subject' -and $r.Text -match 'local-llm/Install-LocalAI\.ps1') 'the review was on screen first: both commits with date and subject line, and the changed installer'
    Assert-That ($r.Api.Count -eq 3 -and @($r.Api | Where-Object { $_ -like "*/compare/$shaOld...$shaNew" }).Count -eq 1 -and @($r.Api | Where-Object { $_ -like "*/git/trees/$shaNew*recursive=1" }).Count -eq 1 -and $r.Text -match 'must hold exactly the 4 file\(s\) GitHub lists under local-llm') "GitHub was asked for the incoming commit, for its comparison with the installed one and for the list of its files, by the commit's id ($($r.Api.Count) API call(s))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -PipeOk
    Assert-That ($r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'no keyboard to type OK on') "an OK piped into the run is not a typed OK: still nothing downloaded or started (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -Reviewed $shaNew
    Assert-That ($r.Ran -eq "commit=$shaNew" -and $r.Text -match 'Not asking: LOCALAI_REVIEWED_COMMIT') "LOCALAI_REVIEWED_COMMIT naming the incoming commit: the installer from the archive runs, with that commit recorded next to it (installer '$($r.Ran)'; $($r.Tail))"
    Assert-That ($r.Get.Count -eq 1 -and $r.Get[0] -like "GET https://codeload.github.com/*/zip/$shaNew" -and $r.Text -match "To install\s+: commit $shaNew") "and what was downloaded is the commit the review showed, not the branch ($($r.Get -join ' '))"
    # The same run, looked at for what this file is about: a correct download passes both
    # comparisons, Windows is asked for administrator rights once, and the installer runs from the
    # folder the step made under Program Files, which only administrators can change.
    $ranFrom = ''
    $madeRule = $null
    $madeWhy = 'the installer wrote nothing down'
    if ($r.From.Count -ge 5) {
        $ranFrom = $r.From[0]
        $madeSecurity = New-Object System.Security.AccessControl.DirectorySecurity
        $madeSecurity.SetSecurityDescriptorSddlForm($r.From[1])
        $madeRule = ConvertTo-FolderRule -Security $madeSecurity
        $madeWhy = Test-AdminOnlyRule -Rule $madeRule
    }
    $madeHolders = @()
    if ($madeRule) { $madeHolders = @($madeRule.Rules | ForEach-Object { $_.Sid } | Sort-Object -Unique) }
    Assert-That ($r.Start.Count -eq 1 -and $r.Start[0] -like 'START RunAs *\WindowsPowerShell\v1.0\powershell.exe' -and $r.Text -match 'Windows asks for administrator rights next' -and $r.Text -match 'The installer continues in the Administrator window that opened') "a correct download passes: Windows is asked for administrator rights once, for Windows PowerShell by its full path ($($r.Start -join ' '))"
    Assert-That ($ranFrom -like (Join-Path $stagingReal '*\local-llm') -and $ranFrom -notlike "$e2eTemp*" -and $r.Text -match 'It is the download that was compared') "and the installer ran from the folder the step made under Program Files, not from the temp folder (ran from '$ranFrom')"
    Assert-That ($madeWhy -eq '' -and $madeRule -and $madeRule.Owner -eq 'S-1-5-32-544' -and ($madeHolders -join ' ') -eq 'S-1-5-18 S-1-5-32-544') "that folder, as the installer found it, is accepted by the check of its rules: owned by Administrators, with rules for SYSTEM and Administrators and nobody else ('$madeWhy'; rules for: $($madeHolders -join ' '))"
    Assert-That ($r.From.Count -ge 5 -and $r.From[2] -eq 'True' -and $r.From[3] -eq '' -and $r.From[4] -eq 'True') 'the installer had administrator rights, got no option it was not given, and ran while the step held its folder'
    Assert-That ($r.Left.Count -eq 0) "after that run nothing is left behind: not the archive, the unpacked files or the step's text in the temp folder, not the folder under Program Files ($($r.Left -join ', '))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -Reviewed $shaNew -Options '-OfficialModels none'
    Assert-That ($r.Ran -eq "commit=$shaNew" -and $r.From.Count -ge 5 -and $r.From[3] -eq '-OfficialModels none') "options for the installer (LOCALAI_ARGS) reach it through the step as they were given ('$(if ($r.From.Count -ge 5) { $r.From[3] })')"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -Reviewed $shaNew -Options '-OfficialModels none;more'
    Assert-That ($r.Get.Count -eq 0 -and $r.Start.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'LOCALAI_ARGS may hold only plain options' -and $r.Text -match 'Nothing was downloaded or changed') "options that are more than plain words are refused before anything is downloaded (downloads $($r.Get.Count), installer '$($r.Ran)')"

    # GitHub's API not answering for the list of the commit's files: an update stops, before the
    # question and before the download, also with the reviewed commit named.
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNoTree -Reviewed $shaNew
    Assert-That ($r.Get.Count -eq 0 -and $r.Start.Count -eq 0 -and -not $r.Ran -and $r.Api.Count -eq 3 -and $r.Text -match "Stopped: GitHub's list of the files of this commit could not be used \(The remote server returned an error: \(403\) Forbidden\.\)" -and $r.Text -match 'never installed unchecked' -and $r.Text -match 'Nothing was downloaded or changed') "the API not answering for the list of the commit's files stops the update, also with the reviewed commit named: nothing is downloaded, no installer runs (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNoTree
    Assert-That ($r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'could not be used' -and $r.Text -notmatch 'no keyboard to type OK on') "and without it the question is not even asked: there is nothing an OK could be about (installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiCutTree -Reviewed $shaNew
    Assert-That ($r.Get.Count -eq 0 -and $r.Start.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'could not be used \(its answer is no complete list of plain files') "a list GitHub cut off stops the update the same way (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"

    # The download is not the commit: refused at the first comparison, before Windows is asked for
    # administrator rights.
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -Reviewed $shaNew -Zip $zipOneByte
    Assert-That ($r.Get.Count -eq 1 -and $r.Start.Count -eq 0 -and -not $r.Ran -and $r.Text -match "Stopped: what was downloaded is not commit $shaNew" -and $r.Text -match 'not as in the commit: local-llm/lib/LocalAI\.psm1' -and $r.Text -match 'Nothing was installed or changed') "a download that differs from the commit in one byte is refused, the file is named, and Windows is not even asked for administrator rights (installer '$($r.Ran)'; $($r.Tail))"
    Assert-That ($r.Left.Count -eq 0) "after that refusal nothing is left in the temp folder ($($r.Left -join ', '))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -Reviewed $shaNew -Zip $zipExtra
    Assert-That ($r.Get.Count -eq 1 -and $r.Start.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'not in the commit: local-llm/Extra-Tool\.ps1' -and $r.Left.Count -eq 0) "a download with a file the commit's list does not hold is refused (installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -Reviewed $shaNew -Zip $zipMissing
    Assert-That ($r.Get.Count -eq 1 -and $r.Start.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'missing: local-llm/VERSION' -and $r.Left.Count -eq 0) "a download that lacks a file of the commit is refused (installer '$($r.Ran)'; $($r.Tail))"

    # A program of the user at work between the first comparison and the click on Yes: the archive
    # in the temp folder is swapped, or the file with the step's text is changed. Both are caught
    # behind the request for administrator rights, and the installer does not run.
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -Reviewed $shaNew -Swap $zipOneByte
    Assert-That ($r.Get.Count -eq 1 -and $r.Start.Count -eq 1 -and -not $r.Ran -and $r.From.Count -eq 0 -and $r.Text -match 'Stopped: the archive in the temp folder is not the download that was compared' -and $r.Text -match 'Nothing was installed or changed') "a zip swapped in the temp folder after the first check is refused by the step with administrator rights: the installer in it does not run (installer '$($r.Ran)'; $($r.Tail))"
    Assert-That ($r.Left.Count -eq 0) "after that refusal nothing is left either: not in the temp folder, not under Program Files ($($r.Left -join ', '))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -Reviewed $shaNew -Edit 'yes'
    Assert-That ($r.Start.Count -eq 1 -and -not $r.Ran -and $r.Text -match 'Stopped: the file that carries the step with administrator rights was changed or removed' -and $r.Text -notmatch 'Checking the download once more' -and $r.Left.Count -eq 0) "the step's own text changed in the temp folder is not run at all: the window was started with the hash of the text as it was written (installer '$($r.Ran)'; left: $($r.Left -join ', '); $($r.Tail))"

    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -Reviewed $shaOther
    Assert-That ($r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'does not count here') "LOCALAI_REVIEWED_COMMIT naming another commit skips nothing (downloads $($r.Get.Count), installer '$($r.Ran)')"
    Assert-That ($r.Page.Count -eq 0 -and $r.Odd.Count -eq 0) "with the API answering, the commit's page is not asked for, and nothing else is either (page $($r.Page.Count), other $($r.Odd -join ' '))"
    # A machine that has the installer's Start-menu folder is a PC with an install: an empty AI folder
    # is then no first install (that case follows further down), so these runs need one without it.
    if ($menuWasThere) {
        Skip "a first install end to end: this machine has the installer's Start-menu folder ($realMenu), so no run here is a first install"
    } else {
        $r = Invoke-Bootstrap -Root $rootEmpty -ApiDir $apiFull
        Assert-That ($r.Ran -eq "commit=$shaNew" -and $r.Text -match 'First install' -and $r.Text -notmatch 'Stopped' -and @($r.Api | Where-Object { $_ -like '*/compare/*' }).Count -eq 0) "a first install is not asked and goes on as before (installer '$($r.Ran)'; $($r.Tail))"
        Assert-That ($r.Text -match 'a first install was not reviewed, so this download cannot be compared with a reviewed commit' -and $r.Text -match 'It is compared with the 4 file\(s\) GitHub lists' -and $r.Api.Count -eq 2 -and $r.Start.Count -eq 1 -and $r.Left.Count -eq 0) "it says plainly that this first download cannot be compared with a reviewed commit, holds it against the commit it shows, and runs the installer through the same step ($($r.Api.Count) API call(s), left: $($r.Left -join ', '))"
        # Nobody reviewed a first install, and without the list nothing was compared either. What
        # runs with administrator rights is still what was downloaded: a swap is caught here too.
        $r = Invoke-Bootstrap -Root $rootEmpty -ApiDir $apiNone -Swap $zipOneByte
        Assert-That ($r.Get.Count -eq 1 -and $r.Start.Count -eq 1 -and -not $r.Ran -and $r.Text -match 'Stopped: the archive in the temp folder is not the download that was compared' -and $r.Left.Count -eq 0) "a first install that could not be compared with anything is protected against a swapped archive all the same (installer '$($r.Ran)'; $($r.Tail))"
    }
    # The comparison as GitHub sends it across many commits: over 2 million characters. Read in full
    # by Windows PowerShell 5.1, with the file list on screen.
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiLarge
    Assert-That ($r.Text -match '2 commit\(s\), 2 file\(s\) differ' -and $r.Text -match 'local-llm/Install-LocalAI\.ps1' -and $r.Text -match 'Stand-in installed subject' -and $r.Text -notmatch 'could not be read' -and $r.Text -notmatch 'could not be fetched' -and $r.Text -match 'Stopped: ' -and $r.Get.Count -eq 0) "a comparison of $($largeJson.Length) characters is read and listed, not given up on ($($r.Tail))"
    # GitHub's API over its hourly limit (the lookup, the comparison and the list of files all
    # refused), github.com answering: the commit is read from its page and shown. The update stops
    # all the same, before the question: the list of the commit's files comes from the API alone,
    # and without it the download cannot be compared with what was shown.
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiPage
    Assert-That ($r.Text -match "To install\s+: commit $shaNew" -and $r.Text -match '2026-10-06\s+Stand-in incoming subject' -and $r.Text -match "read from the commit's page" -and $r.Text -match 'could not be fetched from GitHub' -and $r.Text -notmatch 'could not be named') "the API refusing while the commit's page answers: the incoming commit is shown with date and subject line, and the missing file list is said ($($r.Tail))"
    Assert-That ($r.Page.Count -eq 1 -and $r.Page[0] -like 'PAGE https://github.com/*/commit/main.patch' -and $r.Api.Count -eq 3 -and $r.Text -match 'Stopped: ' -and $r.Text -match 'list of the files of this commit could not be used' -and $r.Text -notmatch 'no keyboard to type OK on' -and $r.Get.Count -eq 0 -and -not $r.Ran) "but it stops there, before the question: the API did not hand over the list of the commit's files, so nothing is downloaded (page $($r.Page -join ' '), downloads $($r.Get.Count), installer '$($r.Ran)')"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiPage -Reviewed $shaNew
    Assert-That ($r.Get.Count -eq 0 -and $r.Start.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'Not asking: LOCALAI_REVIEWED_COMMIT' -and $r.Text -match 'Stopped: ' -and $r.Text -match 'never installed unchecked' -and $r.Text -match 'Nothing was downloaded or changed') "the API not answering stops the update also when the reviewed commit is named: the commit the page named is not downloaded, and no installer runs (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNoCompare
    Assert-That ($r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'could not be fetched from GitHub' -and $r.Text -match '\(403\) Forbidden' -and $r.Text -match "To install\s+: commit $shaNew") "a comparison GitHub refuses: the error and the incoming commit are shown, and it does not go on by itself (installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNoCompare -Reviewed $shaNew
    Assert-That ($r.Ran -eq "commit=$shaNew") "the reviewed commit installs even then: the owner decided, not the error (installer '$($r.Ran)')"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNone
    Assert-That ($r.Page.Count -eq 1 -and $r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'Stopped: the commit to install could not be named' -and $r.Text -match 'Try again later, or set LOCALAI_REF' -and $r.Text -notmatch 'whatever' -and $r.Text -match $shaOld) "GitHub not answering at all for an update: it stops and says what to do; the branch is not offered, let alone installed unseen (installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNone -Reviewed $shaNew
    Assert-That ($r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'Stopped: the commit to install could not be named') "and LOCALAI_REVIEWED_COMMIT does not carry it through: there is no commit it could name (installer '$($r.Ran)')"
    # A ref that is a full commit id names the commit without GitHub, and the reviewed commit skips
    # the question. Neither names the files the commit holds: without the API the update stops.
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNone -Ref $shaNew -Reviewed $shaNew
    Assert-That ($r.Get.Count -eq 0 -and $r.Start.Count -eq 0 -and -not $r.Ran -and $r.Text -match "To install\s+: commit $shaNew" -and $r.Text -match 'Stopped: ' -and $r.Text -match 'list of the files of this commit could not be used') "a ref and a reviewed commit that both name the full id do not install it without GitHub's API: the commit is known, the files it holds are not, and the update stops (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    Assert-That ($r.Text -match 'Not checked to be on a branch of this repository') 'and the review says that a commit id was not checked to be on a branch of this repository'
    if ($menuWasThere) {
        Skip "a first install without GitHub answering: this machine has the installer's Start-menu folder"
    } else {
        $r = Invoke-Bootstrap -Root $rootEmpty -ApiDir $apiNone
        Assert-That ($r.Ran -eq 'commit=' -and $r.Get.Count -eq 1 -and $r.Get[0] -like 'GET https://codeload.github.com/*/zip/main' -and $r.Text -match 'cannot be shown or pinned') "only a first install goes on without GitHub's API and without the commit's page, with the ref as it is and no commit recorded (installer '$($r.Ran)'; $($r.Tail))"
        Assert-That ($r.Text -match 'cannot be compared with a reviewed commit' -and $r.Text -match 'Without a commit there is no list of its files either: it is installed as it arrives' -and $r.Api.Count -eq 1 -and $r.Left.Count -eq 0) "and it says plainly that this first download cannot be compared with a reviewed commit, nor with anything else ($($r.Api.Count) API call(s), left: $($r.Left -join ', '))"
    }

    # What the bootstrap itself takes for an install. Each of these AI folders holds one trace only;
    # missing one of them would turn an update into a "first install" that is not asked about.
    $traces = @(
        @{ Root = $rootStateOnly; Says = 'did not finish'; What = 'only install-state.json (an install that did not finish)' }
        @{ Root = $rootScriptsOnly; Says = 'did not finish'; What = 'only Scripts\Install-LocalAI.ps1' }
        @{ Root = $rootDamaged; Says = 'localai-config\.json could not be read'; What = 'a localai-config.json cut off mid-write' }
    )
    foreach ($trace in $traces) {
        $r = Invoke-Bootstrap -Root $trace.Root -ApiDir $apiFull
        Assert-That ($r.Text -match 'Update review' -and $r.Text -notmatch 'First install' -and $r.Text -match $trace.Says -and $r.Text -match "To install\s+: commit $shaNew" -and $r.Text -match 'Stopped: ' -and $r.Get.Count -eq 0 -and -not $r.Ran) "an AI folder with $($trace.What) is an install, not a first install: reviewed, asked, nothing downloaded (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    }
    # A config that exists but cannot be opened (held by another program): the read error must end
    # as "an install whose commit is unknown", not as "no config, so nothing installed".
    $lock = [System.IO.File]::Open($lockedConfig, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try { $r = Invoke-Bootstrap -Root $rootLocked -ApiDir $apiFull } finally { $lock.Dispose() }
    Assert-That ($r.Text -match 'Update review' -and $r.Text -notmatch 'First install' -and $r.Text -match 'localai-config\.json could not be read' -and $r.Text -match 'Stopped: ' -and $r.Get.Count -eq 0 -and -not $r.Ran -and @($r.Api | Where-Object { $_ -like '*/compare/*' }).Count -eq 0) "a localai-config.json that cannot be opened is an install whose commit is unknown: asked, nothing downloaded (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootLocked -ApiDir $apiFull
    Assert-That ($r.Text -match "Installed now : version 2026\.10\.05, commit $shaOld" -and $r.Api.Count -eq 3) 'the same folder with the file free again reads as the install it is (so it was the lock that made the difference)'
    # An install in another folder: the AI folder named here is empty, the installer's Start-menu
    # folder exists. With the command from the README (no LOCALAI_ROOT) that is an update, not a first
    # install. The folder is the real one of this (throwaway) machine: created empty here unless it
    # is there already, and removed again only when it was created here.
    # ProgramData pointed at an empty folder, as a session could do it: the bootstrap must not take
    # the Start menu's place from there and call this a first install. Made before the Start-menu
    # folder is, so that nothing that can fail stands between creating that folder and the try
    # whose finally removes it.
    $emptyProgramData = Join-Path $e2e 'programdata-empty'
    New-Item -ItemType Directory -Force -Path $emptyProgramData | Out-Null
    $menuMade = $false
    if ($realMenu -and -not $menuWasThere) {
        try { New-Item -ItemType Directory -Path $realMenu -ErrorAction Stop | Out-Null; $menuMade = $true } catch { $menuMade = $false }
    }
    if ($menuWasThere -or $menuMade) {
        try { $r = Invoke-Bootstrap -Root $rootEmpty -ApiDir $apiFull -ProgramData $emptyProgramData }
        finally { if ($menuMade) { Remove-Item -LiteralPath $realMenu -Force -ErrorAction SilentlyContinue } }
        Assert-That ($r.Text -notmatch 'First install' -and $r.Text -match 'installed on this PC' -and $r.Text -match 'but not in' -and $r.Text -match 'set LOCALAI_ROOT to that folder' -and $r.Text -match "To install\s+: commit $shaNew" -and $r.Text -match 'Stopped: ' -and $r.Get.Count -eq 0 -and -not $r.Ran) "an empty AI folder on a PC that has the installer's Start-menu folder, with ProgramData pointed elsewhere in the session: still not a first install; said so with LOCALAI_ROOT, asked, nothing downloaded (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    } else {
        Assert-That $false "the installer's Start-menu folder could not be created for one run ($realMenu): the Windows job runs as administrator, so this is a fault of the test machine"
    }
    # A ref that is more than a name: .NET would fold the '..' parts away and fetch another repository.
    $r = Invoke-Bootstrap -Root $rootEmpty -ApiDir $apiNone -Ref '../../../other/repo/zip/main'
    Assert-That ($r.Api.Count -eq 0 -and $r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'LOCALAI_REF may hold only' -and $r.Text -match 'Nothing was downloaded or changed') "a LOCALAI_REF with '..' in it is refused before GitHub is asked anything: no lookup, no download, no installer (API $($r.Api.Count), downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    # Every run above, whether it installed, was refused or stopped: nothing of it stays behind.
    Assert-That ($script:bootstrapRuns -ge 25 -and $leftBehind.Count -eq 0) "none of the $($script:bootstrapRuns) runs left anything in the temp folder or under Program Files, after a success and after a refusal alike (left: $($leftBehind -join '; '))"

    # The check of a folder's rules on real folders of this machine (Get-FolderRule reads them,
    # Test-AdminOnlyRule judges them). One folder is first given to SYSTEM and Administrators alone,
    # the way the step with administrator rights sets its own up, and passes; then Users are
    # allowed to modify it, and it does not pass any more.
    $probeFolder = Join-Path $e2e 'rules-probe'
    New-Item -ItemType Directory -Force -Path $probeFolder | Out-Null
    $icaclsCodes = @()
    & icacls.exe $probeFolder '/setowner' '*S-1-5-32-544' | Out-Null
    $icaclsCodes += $LASTEXITCODE
    & icacls.exe $probeFolder '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    $icaclsCodes += $LASTEXITCODE
    $closedWhy = Test-AdminOnlyRule -Rule (Get-FolderRule -Path $probeFolder)
    Assert-That ($closedWhy -eq '') "a real folder that SYSTEM and Administrators alone can change passes the check of its rules ('$closedWhy'; icacls exit codes $($icaclsCodes -join ', '))"
    & icacls.exe $probeFolder '/grant' '*S-1-5-32-545:(OI)(CI)M' | Out-Null
    $icaclsCodes += $LASTEXITCODE
    $openWhy = Test-AdminOnlyRule -Rule (Get-FolderRule -Path $probeFolder)
    Assert-That ($openWhy -match '^S-1-5-32-545 may change it' -and @($icaclsCodes | Where-Object { $_ -ne 0 }).Count -eq 0) "the same folder once Users may modify it is refused: a folder a normal user can write is not one the installer is run from ('$openWhy'; icacls exit codes $($icaclsCodes -join ', '))"
    $programFilesWhy = Test-AdminOnlyRule -Rule (Get-FolderRule -Path $programFilesReal) -Parent
    $tempWhy = Test-AdminOnlyRule -Rule (Get-FolderRule -Path $e2eTemp)
    Assert-That ($programFilesWhy -eq '' -and $tempWhy -ne '') "Program Files of this machine passes as the folder the step makes its own in; the temp folder the download sits in does not pass (Program Files: '$programFilesWhy'; temp folder: '$tempWhy')"
    # A junction inside a folder that is removed, or among unpacked files: never walked into.
    $linkRoot = Join-Path $e2e 'link-probe'
    $linkTarget = Join-Path $e2e 'link-target'
    New-Item -ItemType Directory -Force -Path (Join-Path $linkRoot 'local-llm') | Out-Null
    New-Item -ItemType Directory -Force -Path $linkTarget | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $linkTarget 'keep.txt'), 'not part of the folder')
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $linkRoot 'local-llm') 'file.txt'), 'part of the folder')
    New-Item -ItemType Junction -Path (Join-Path (Join-Path $linkRoot 'local-llm') 'jump') -Value $linkTarget | Out-Null
    $linkError = ''
    try { $null = Get-ToolkitFileList -Top $linkRoot } catch { $linkError = $_.Exception.Message }
    Remove-ToolkitTree -Path $linkRoot
    Assert-That ($linkError -match 'is a link in the unpacked archive' -and -not (Test-Path -LiteralPath $linkRoot) -and (Test-Path -LiteralPath (Join-Path $linkTarget 'keep.txt'))) "a junction among unpacked files is an error, not a way to more files; and a folder is removed without walking into a junction in it: what the junction points at is still there ('$linkError')"
    if ($failures -eq 0) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
} else {
    Skip 'the bootstrap end to end, the step with administrator rights and the rules of real folders (Windows only: the Windows job runs this part)'
}

if ($failures -eq 0) { Write-Host "`nGET-LOCALAI TEST PASSED" -ForegroundColor Green } else { Write-Host "`nGET-LOCALAI TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
