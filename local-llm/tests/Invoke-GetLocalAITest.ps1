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
      one question, before the one download and the one installer start.
    - The gate (Get-UpdateConsent) with a stand-in for the keyboard: only an OK typed after the review
      goes on; no keyboard, an error, a piped-in OK or an unreadable review does not.
    - Windows only: the whole bootstrap in a child process, started the way 'irm | iex' starts it,
      with GitHub replaced by stand-ins and a stand-in installer in the archive. With nobody to type
      OK, or with an OK piped in, nothing is downloaded and no installer starts; with the reviewed
      commit named, the commit that was shown is the one downloaded, recorded and run. Every trace of
      an install the bootstrap looks for (in the AI folder, and the all-users Start-menu folder
      outside it, which is created for that run and removed again) makes it ask; a ref that is no
      plain name reaches neither GitHub nor the download.
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
    'Get-InstalledToolkit', 'Test-PlainRepoPath', 'Get-ChangedFileGroup', 'Get-ChangedFileReport', 'Get-UpdateReview', 'Test-UpdateAnswer', 'Get-UpdateConsent')
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
    Assert-That (-not $selfReviewed.NeedsOk -and $selfReviewed.Url -eq "https://codeload.github.com/$repo/zip/$shaNew") 'and naming that id as the reviewed commit skips the question: an unattended run does not depend on GitHub answering'

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
$starts = @($commands | Where-Object { $_.GetCommandName() -eq 'powershell.exe' })
$inOrder = ($asks.Count -eq 1 -and $downloads.Count -eq 1 -and $starts.Count -eq 1)
if ($inOrder) { $inOrder = ($asks[0].Extent.StartOffset -lt $downloads[0].Extent.StartOffset -and $downloads[0].Extent.StartOffset -lt $starts[0].Extent.StartOffset) }
Assert-That $inOrder "the bootstrap asks once, before its one download and its one installer start (Read-Host: $($asks.Count), Invoke-WebRequest -OutFile: $($downloads.Count), powershell.exe: $($starts.Count))"
$askOwner = $null
if ($asks.Count -eq 1) { $askOwner = $asks[0].Parent; while ($askOwner -and $askOwner -isnot [System.Management.Automation.Language.CommandAst]) { $askOwner = $askOwner.Parent } }
Assert-That ($askOwner -and $askOwner.GetCommandName() -eq 'Get-UpdateConsent') 'and only through the gate: Get-UpdateConsent decides whether to ask and what the answer means'
# GitHub is asked through one function that hands back text; Invoke-RestMethod is not used (on Windows
# PowerShell 5.1 it hands a long answer back unread, and the file list would be missing).
$questionOwner = $null
if ($questions.Count -eq 1) { $questionOwner = $questions[0].Parent; while ($questionOwner -and $questionOwner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $questionOwner = $questionOwner.Parent } }
$restCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-RestMethod' })
$textCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Get-GitHubText' })
Assert-That ($questions.Count -eq 1 -and $questionOwner -and $questionOwner.Name -eq 'Get-GitHubText' -and $restCalls.Count -eq 0 -and $textCalls.Count -eq 3) "GitHub's answers are fetched as text in one place (Get-GitHubText: commit, its page, comparison) and never through Invoke-RestMethod (calls: $($textCalls.Count), Invoke-RestMethod: $($restCalls.Count))"
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
    $zipTop = Join-Path (Join-Path $e2e 'zipsrc') "ComfyUi-Optimization-$shaNew"
    $zipLlm = Join-Path $zipTop 'local-llm'
    foreach ($d in @($e2eTemp, $apiFull, $apiNoCompare, $apiNone, $apiPage, $apiLarge, $rootInstalled, $rootEmpty, $rootStateOnly, (Join-Path $rootScriptsOnly 'Scripts'), $rootDamaged, $rootLocked, $zipLlm)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $e2eLog = Join-Path $e2e 'calls.log'
    $harness = Join-Path $e2e 'harness.ps1'
    $zipFile = Join-Path $e2e 'toolkit.zip'

    # The archive GitHub would send: one top folder, local-llm inside it. Its "installer" only writes
    # down that it ran and which COMMIT file the bootstrap put next to it.
    $installerStub = @'
param([string]$AIRoot)
$commit = ''
$commitFile = Join-Path $PSScriptRoot 'COMMIT'
if (Test-Path -LiteralPath $commitFile) { $commit = [System.IO.File]::ReadAllText($commitFile) }
[System.IO.File]::WriteAllText((Join-Path $AIRoot 'installer-ran.txt'), ('commit=' + $commit))
exit 0
'@
    [System.IO.File]::WriteAllText((Join-Path $zipLlm 'Install-LocalAI.ps1'), $installerStub)
    [System.IO.File]::WriteAllText((Join-Path $zipLlm 'VERSION'), '2099.01.02')
    Compress-Archive -LiteralPath $zipTop -DestinationPath $zipFile -Force

    # GitHub's two answers, and an installed copy that records the old commit.
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
    # Everything else is the real thing: the review, the gate, Read-Host, Expand-Archive and
    # powershell.exe for the installer.
    # The stand-ins are called from inside the bootstrap's script block, and PowerShell looks a
    # variable up in the caller's scope first: a harness value named like one of the bootstrap's own
    # variables ($zip, $root, $ref) would be read as the bootstrap's. Hence the StandIn names, and
    # $script: wherever a stand-in function reads one.
    $harnessText = @'
param([string]$StandInBootstrap, [string]$StandInZip, [string]$StandInLog, [string]$StandInApi, [string]$StandInRoot, [string]$StandInRef, [string]$StandInReviewed, [string]$StandInTemp, [string]$StandInProgramData)
$ErrorActionPreference = 'Stop'
$env:TEMP = $StandInTemp
if ($StandInProgramData -ne 'NONE') { $env:ProgramData = $StandInProgramData }
$env:LOCALAI_ROOT = $StandInRoot
$env:LOCALAI_REF = $StandInRef
$env:LOCALAI_ARGS = ''
$env:LOCALAI_REVIEWED_COMMIT = ''
if ($StandInReviewed -ne 'NONE') { $env:LOCALAI_REVIEWED_COMMIT = $StandInReviewed }
function Invoke-RestMethod {
    [System.IO.File]::AppendAllText($script:StandInLog, "REST $args`r`n")
    throw 'Invoke-RestMethod is not to be used by the bootstrap.'
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
        # wait for more).
        param([string]$Root, [string]$ApiDir, [string]$Ref = 'main', [string]$Reviewed = 'NONE', [string]$ProgramData = 'NONE', [switch]$PipeOk)
        $marker = Join-Path $Root 'installer-ran.txt'
        foreach ($f in @($e2eLog, $marker)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
        $harnessArgs = @('-StandInBootstrap', $bootstrap, '-StandInZip', $zipFile, '-StandInLog', $e2eLog, '-StandInApi', $ApiDir, '-StandInRoot', $Root, '-StandInRef', $Ref, '-StandInReviewed', $Reviewed, '-StandInTemp', $e2eTemp, '-StandInProgramData', $ProgramData)
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        if ($PipeOk) { $out = 'OK' | & $childExe -NoProfile -ExecutionPolicy Bypass -File $harness @harnessArgs 2>&1 | ForEach-Object { "$_" } }
        else { $out = & $childExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness @harnessArgs 2>&1 | ForEach-Object { "$_" } }
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        $log = @(); if (Test-Path -LiteralPath $e2eLog) { $log = @([System.IO.File]::ReadAllLines($e2eLog)) }
        $ran = ''; if (Test-Path -LiteralPath $marker) { $ran = [System.IO.File]::ReadAllText($marker) }
        return [pscustomobject]@{
            Code = $code
            Text = (@($out) -join "`n")
            Tail = (@($out | Where-Object { $_ } | Select-Object -Last 3) -join ' | ')
            Api  = @($log | Where-Object { $_ -like 'API *' })
            Page = @($log | Where-Object { $_ -like 'PAGE *' })
            Odd  = @($log | Where-Object { $_ -like 'REST *' -or $_ -like 'OTHER *' })
            Get  = @($log | Where-Object { $_ -like 'GET *' })
            Ran  = $ran
        }
    }

    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull
    Assert-That ($r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'Stopped: ' -and $r.Text -match 'Nothing was downloaded or changed') "an update with nobody to type OK: nothing is downloaded, no installer starts, and the run says so (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    Assert-That ($r.Text -match $shaOld -and $r.Text -match "To install\s+: commit $shaNew" -and $r.Text -match 'Stand-in installed subject' -and $r.Text -match '2026-10-06\s+Stand-in incoming subject' -and $r.Text -match 'local-llm/Install-LocalAI\.ps1') 'the review was on screen first: both commits with date and subject line, and the changed installer'
    Assert-That ($r.Api.Count -eq 2 -and @($r.Api | Where-Object { $_ -like "*/compare/$shaOld...$shaNew" }).Count -eq 1) "GitHub was asked for the incoming commit and for its comparison with the installed one ($($r.Api.Count) API call(s))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -PipeOk
    Assert-That ($r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'no keyboard to type OK on') "an OK piped into the run is not a typed OK: still nothing downloaded or started (downloads $($r.Get.Count), installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiFull -Reviewed $shaNew
    Assert-That ($r.Ran -eq "commit=$shaNew" -and $r.Text -match 'Not asking: LOCALAI_REVIEWED_COMMIT') "LOCALAI_REVIEWED_COMMIT naming the incoming commit: the installer from the archive runs, with that commit recorded next to it (installer '$($r.Ran)'; $($r.Tail))"
    Assert-That ($r.Get.Count -eq 1 -and $r.Get[0] -like "GET https://codeload.github.com/*/zip/$shaNew" -and $r.Text -match "To install\s+: commit $shaNew") "and what was downloaded is the commit the review showed, not the branch ($($r.Get -join ' '))"
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
    }
    # The comparison as GitHub sends it across many commits: over 2 million characters. Read in full
    # by Windows PowerShell 5.1, with the file list on screen.
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiLarge
    Assert-That ($r.Text -match '2 commit\(s\), 2 file\(s\) differ' -and $r.Text -match 'local-llm/Install-LocalAI\.ps1' -and $r.Text -match 'Stand-in installed subject' -and $r.Text -notmatch 'could not be read' -and $r.Text -notmatch 'could not be fetched' -and $r.Text -match 'Stopped: ' -and $r.Get.Count -eq 0) "a comparison of $($largeJson.Length) characters is read and listed, not given up on ($($r.Tail))"
    # GitHub's API over its hourly limit (the lookup and the comparison both refused), github.com
    # answering: the commit is read from its page, shown, and OK is asked. Not a stop.
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiPage
    Assert-That ($r.Text -match "To install\s+: commit $shaNew" -and $r.Text -match '2026-10-06\s+Stand-in incoming subject' -and $r.Text -match "read from the commit's page" -and $r.Text -match 'could not be fetched from GitHub' -and $r.Text -notmatch 'could not be named') "the API refusing while the commit's page answers: the incoming commit is shown with date and subject line, and the missing file list is said ($($r.Tail))"
    Assert-That ($r.Page.Count -eq 1 -and $r.Page[0] -like 'PAGE https://github.com/*/commit/main.patch' -and $r.Api.Count -eq 2 -and $r.Text -match 'Stopped: ' -and $r.Get.Count -eq 0 -and -not $r.Ran) "it is asked about like any update, and with nobody to type OK nothing is downloaded (page $($r.Page -join ' '), downloads $($r.Get.Count), installer '$($r.Ran)')"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiPage -Reviewed $shaNew
    Assert-That ($r.Ran -eq "commit=$shaNew" -and $r.Get.Count -eq 1 -and $r.Get[0] -like "GET https://codeload.github.com/*/zip/$shaNew") "and the commit the page named is the one downloaded, recorded and run, not the branch (installer '$($r.Ran)'; $($r.Get -join ' '))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNoCompare
    Assert-That ($r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'could not be fetched from GitHub' -and $r.Text -match '\(403\) Forbidden' -and $r.Text -match "To install\s+: commit $shaNew") "a comparison GitHub refuses: the error and the incoming commit are shown, and it does not go on by itself (installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNoCompare -Reviewed $shaNew
    Assert-That ($r.Ran -eq "commit=$shaNew") "the reviewed commit installs even then: the owner decided, not the error (installer '$($r.Ran)')"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNone
    Assert-That ($r.Page.Count -eq 1 -and $r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'Stopped: the commit to install could not be named' -and $r.Text -match 'Try again later, or set LOCALAI_REF' -and $r.Text -notmatch 'whatever' -and $r.Text -match $shaOld) "GitHub not answering at all for an update: it stops and says what to do; the branch is not offered, let alone installed unseen (installer '$($r.Ran)'; $($r.Tail))"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNone -Reviewed $shaNew
    Assert-That ($r.Get.Count -eq 0 -and -not $r.Ran -and $r.Text -match 'Stopped: the commit to install could not be named') "and LOCALAI_REVIEWED_COMMIT does not carry it through: there is no commit it could name (installer '$($r.Ran)')"
    $r = Invoke-Bootstrap -Root $rootInstalled -ApiDir $apiNone -Ref $shaNew -Reviewed $shaNew
    Assert-That ($r.Ran -eq "commit=$shaNew" -and $r.Get.Count -eq 1 -and $r.Get[0] -like "GET https://codeload.github.com/*/zip/$shaNew") "a ref and a reviewed commit that both name the full id install it without GitHub's API (installer '$($r.Ran)'; $($r.Tail))"
    Assert-That ($r.Text -match 'Not checked to be on a branch of this repository') 'and the review says that a commit id was not checked to be on a branch of this repository'
    if ($menuWasThere) {
        Skip "a first install without GitHub answering: this machine has the installer's Start-menu folder"
    } else {
        $r = Invoke-Bootstrap -Root $rootEmpty -ApiDir $apiNone
        Assert-That ($r.Ran -eq 'commit=' -and $r.Get.Count -eq 1 -and $r.Get[0] -like 'GET https://codeload.github.com/*/zip/main' -and $r.Text -match 'cannot be shown or pinned') "only a first install goes on without GitHub's API and without the commit's page, with the ref as it is and no commit recorded (installer '$($r.Ran)'; $($r.Tail))"
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
    Assert-That ($r.Text -match "Installed now : version 2026\.10\.05, commit $shaOld" -and $r.Api.Count -eq 2) 'the same folder with the file free again reads as the install it is (so it was the lock that made the difference)'
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
    if ($failures -eq 0) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
} else {
    Skip 'the bootstrap end to end (it starts powershell.exe: the Windows job runs this part)'
}

if ($failures -eq 0) { Write-Host "`nGET-LOCALAI TEST PASSED" -ForegroundColor Green } else { Write-Host "`nGET-LOCALAI TEST FAILED ($failures)" -ForegroundColor Red }
exit $failures
