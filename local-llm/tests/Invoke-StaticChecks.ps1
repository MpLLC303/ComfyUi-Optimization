<#
.SYNOPSIS
    Static checks for every script in local-llm: parses, ASCII-only, PSScriptAnalyzer with Windows
    PowerShell 5.1 compatibility profiles, and a scan for 5.1 *runtime* pitfalls PSSA cannot see.

.DESCRIPTION
    Why the extra scan: PSSA's compatibility rules check syntax and parameter names, not behaviour.
    Windows PowerShell 5.1 cannot read hashtable keys as properties in Measure-Object, Group-Object,
    Sort-Object or Select-Object (PowerShell 7 can), which crashed the first real install
    ("The value of argument Property is not valid"). Every such call with a property *name* is
    flagged unless the line carries the marker  # lai-ok: objects  (input is real objects, e.g. CIM
    or FileInfo). Scriptblocks ({ $_.Key }) work on hashtables in both versions and are not flagged.

    Exit code = number of problems. PSSA is used when found (-PssaPath or installed module), else skipped.
#>
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$PssaPath = '/home/user/pssa/out/PSScriptAnalyzer/1.25.0/PSScriptAnalyzer.psd1'
)
$ErrorActionPreference = 'Stop'
$problems = 0
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd([char]'/', [char]'\')
$files = Get-ChildItem -Path $Root -Recurse -File -Include *.ps1, *.psm1, *.psd1

# Runtime pitfalls the parser and PSSA accept. Each rule was a real bug in this toolkit; each has
# canaries below that must keep firing, so a broken rule fails the build instead of going quiet.
#   PS51     Measure/Group/Sort/Select -Property <name> on hashtables (5.1 cannot; 7 can).
#   FORMAT   Write-X ('...') -f $a   or   Write-X '...' + $b   in command mode: -f / + become separate
#            arguments, so the log line prints the raw template (wrap the whole expression in parens).
#   MATCHES  an if-condition with two -match operators whose body (or a later part of the condition)
#            reads $Matches: the second match has replaced the groups of the first.
#   BOUND    $PSBoundParameters inside a scriptblock run with & or Invoke-Stage: it is the
#            scriptblock's own (empty) set there, not the script's; copy it to a script variable.
#   ELEVATED Install-LocalAI.ps1 (runs elevated, silently from the resume task) running code
#            from AI\Scripts, a folder inside the user-controlled C:\AI.
#   NOSILENT a scheduled task with -RunLevel Highest (elevated without a UAC prompt).
#   ENCODING Get-Content of an env/config/state/secret file, or Select-String on any file, without
#            -Encoding UTF8 (5.1 reads BOM-less UTF-8 as ANSI; .env must be BOM-less for docker compose).
#   INSTEXIT Install-LocalAI.ps1: a bare 'exit' after Start-Transcript (use Stop-Install).
#   HELP     a user-facing script (toolkit root) with a parameter its help never mentions: no
#            .PARAMETER entry, no comment right above it, no -Name in the help text.
#   DOCPARAM README.md or a script message tells the user to run a script with a -Switch that script
#            does not have, or with a -Parameter that needs a value and gets none.
#   RECURSE  Remove-Item -Recurse in a script that runs as administrator (installer, uninstaller):
#            Windows PowerShell 5.1 follows junctions in the user-controlled C:\AI. Use Remove-LaiTree.
#   SETTINGS an OLLAMA_* setting the installer writes that Uninstall -ResetOllamaSettings does not
#            remove or the diagnostics bundle does not show.
#   COMPOSELOG a service in stack/docker-compose.yml without 'logging:' (Docker keeps container logs
#            forever by default; on an always-on PC they grow without limit).
#   NATIVEQUOTE a literal double quote inside an argument for a native program (docker, wsl, ...):
#            Windows PowerShell 5.1 does not escape it, so the program receives it stripped.
#   HANG     a docker call without a time limit in a script that a stuck Docker Desktop would hang
#            without a word: any direct docker call in Watch-LocalAI.ps1 (a scheduled task) and in
#            Start-LocalAI.ps1, Stop-LocalAI.ps1, Test-LocalAI.ps1 and Get-LocalAIDiagnostics.ps1 (the
#            windows the owner opens when something is wrong), and in those five and in
#            Backup-OpenWebUI.ps1 the engine probe ('version'), called directly or through
#            Invoke-Docker. Docker Desktop can stop answering after sleep; a task then hangs
#            silently until killed, a window waits without a word. The rule goes by the command's
#            name: a timed call through Invoke-LaiTimedNative or Invoke-Capture is not looked at,
#            and neither is another program that can wait (wsl.exe --shutdown in Stop-LocalAI.ps1).
#            Three forms of an untimed docker call have another name and are not seen either: docker
#            run from a variable (& $dockerCmd ps), through Start-Process, or by its full path. None
#            of the six scripts holds one today; a new one would pass this rule.
#   HIDDENTASK a scheduled task action that runs powershell.exe directly: on Windows 11 (Windows
#            Terminal as console host) -WindowStyle Hidden still shows a window, and closing it kills
#            the run. Use Get-LaiHiddenTaskLaunch (conhost --headless).
#   NETCATCH a .GetResult() (HttpClient and other .NET async calls) outside a try that has a catch:
#            a .NET exception is only statement-terminating, so the function carries on with no
#            result and the real cause is lost (a later 'HTTP ' or 'variable not set' error instead).
#   ENVRESTORE [Environment]::SetEnvironmentVariable for this process (no 'User'/'Machine' target):
#            restoring a variable that was not set passes '' from PowerShell, which PowerShell 7 on
#            Linux keeps as an empty variable (docker compose then prefers it over .env). Use
#            Set-LaiProcessEnv, which removes the variable for $null.
#   ENVFIRST Update-OpenWebUI.ps1 writing the new version into .env before the image is pulled: a run
#            cut off mid-download then leaves .env naming an image that is not there.
#   MDTABLE  a README.md table row with more or fewer cells than its header (two rows joined by a
#            lost newline: GitHub drops the extra cells, so a troubleshooting row disappears).
#   LOCATOR  a user-facing script spelling out Ollama's or Docker Desktop's default install folder
#            (Programs\Ollama, Docker\Docker): both can be installed elsewhere (OllamaSetup.exe /DIR=,
#            --installation-dir), so only Find-LaiOllamaDir / Find-LaiDockerDesktopExe may.
#   OLLAMAAPP Start-Process / Start-AsUser of the Ollama tray app without 'hidden': since the 0.10
#            desktop app that opens the Ollama window (over a full-screen game, every heal). Use
#            Start-LaiOllamaApp, or mark an Explorer start that cannot pass arguments '# lai-ok: hidden'.
#            Also any start of Ollama's Startup\Ollama.lnk: the app takes it for a sign-in start (hidden,
#            no --fast-startup) and installs a pending Ollama update right then.
#   SERVERLOG a hard-coded 'OLLAMA_X:value' searched for in server.log text: a newer Ollama that stops
#            logging the key looks like a wrong setting (restart, -Retune advice). Use
#            Test-LaiOllamaServerSettings, which tells a missing key from a wrong value.
#   DRIFT    Watch-LocalAI, Test-LocalAI or Update-Models not judging "presets measured on another
#            Ollama" with Get-LaiTuningDrift: the watch must notice the Ollama app updating itself, and
#            its notice must be exactly the list Update-Models re-checks (else it never clears).
#   DEPSKIP  Test-LocalAI's 'SearXNG search' not skipping when the searxng container check failed
#            (one cause reported as two FAILs).
#   COMPOSESEC a service in stack/docker-compose.yml without no-new-privileges, cap_drop ALL, a
#            mem_limit or a pids_limit, with a published port not bound to 127.0.0.1, or with a line
#            that hands it all back or that this check cannot read (privileged, ALL under cap_add,
#            a '<<' merge or 'extends' at the service's own level, a key not written plainly).
#   TESTHOOK a script outside tests (.ps1, .psm1) that takes something from a test and is not on the
#            pinned list ($testHookPins: what main held when this rule came, one entry per file and
#            name). Two things count. A read of a test variable from the environment: a name that
#            begins LOCALAI_TEST_, or LOCALAI_DOCKER_TIMEOUT, or LOCALAI_TS_TIMEOUT, read as
#            $env:NAME, as [Environment]::GetEnvironmentVariable('NAME'), or through Get-Item,
#            Get-Content, Get-ChildItem or Test-Path (or an alias of one) on Env:NAME. And a
#            parameter in the script's own param block whose name begins Test. A variable can be
#            set for good by any program running as the user, and every later run then takes it
#            for a test's. Use a stand-in the test puts on PATH, a real parameter, or a -Test
#            parameter the run announces. Setting such a variable is not a read. A pinned entry
#            that matches nothing any more fails too, so the list only shrinks, and no marker
#            comment silences the rule. What it cannot see: a name put together at run time
#            ('LOCALAI_' + 'TEST_X', or a variable that holds the name, as in
#            GetEnvironmentVariable($n)); a read under another .NET call (the table that
#            GetEnvironmentVariables() returns, ExpandEnvironmentVariables); 'Get-ChildItem Env:'
#            with the names picked out afterwards; a read in code that a script holds as text for
#            another PowerShell or for cmd; a second read of a pinned name in its file, which
#            passes with the first; and a test parameter under a name that does not begin Test.
#            So an entry goes stale when its read is gone, and just as well when the read only
#            moved into one of those: taking the entry out then removes the last trace of a hook
#            that is still read. The sentence for a stale entry says so, and where a string outside
#            tests still holds the entry's name, or the start of it from LOCALAI_TEST_ on
#            ('LOCALAI_TEST_' + $what), it names that place and does not ask for the entry to go.
#            Such a string is looked at for a stale entry only. By itself it is no problem (a
#            message may name a variable), so a read that never had an entry and is written in one
#            of those ways still passes.
function Find-Pitfall([System.Management.Automation.Language.Ast]$Ast, [string[]]$Lines, [string]$FileName = '', [switch]$UserFacing) {
    $found = New-Object System.Collections.Generic.List[object]
    $add = { param($Rule, $Node, $Msg) $found.Add([pscustomobject]@{ Rule = $Rule; Line = $Node.Extent.StartLineNumber; Message = $Msg }) }
    $marker = { param($Node, $Tag) $Lines[$Node.Extent.StartLineNumber - 1] -match ('#\s*lai-ok:\s*' + $Tag) }
    # Variables holding the Ollama tray app's path (for OLLAMAAPP: 'Start-Process $app').
    $appVars = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Right.Extent.Text -match 'ollama app\.exe|Get-LaiOllamaAppPath' }, $true) |
        ForEach-Object { $_.Left.VariablePath.UserPath })
    # Variables holding Ollama's sign-in shortcut (for OLLAMAAPP: 'Start-AsUser $lnk').
    $startupLinkRx = 'Startup\\+Ollama\.lnk'
    $linkVars = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Right.Extent.Text -match $startupLinkRx }, $true) |
        ForEach-Object { $_.Left.VariablePath.UserPath })
    # Variables that hold a path under $P.Scripts (for ELEVATED: '& $backupScript' is the same as
    # '& (Join-Path $P.Scripts ...)').
    $scriptsVars = @()
    if ($FileName -eq 'Install-LocalAI.ps1') {
        $scriptsVars = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Right.Extent.Text -match '\$P\.Scripts' }, $true) |
            ForEach-Object { $_.Left.VariablePath.UserPath })
    }

    foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (@('Measure-Object', 'Group-Object', 'Sort-Object', 'Select-Object', 'measure', 'group', 'sort', 'select') -contains $name -and -not (& $marker $c 'objects')) {
            # Let PowerShell's own binder decide what lands in -Property (named or positional).
            $bound = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($c, $true)
            if ($bound.BoundParameters.ContainsKey('Property')) {
                $v = $bound.BoundParameters['Property'].Value
                $items = @($v)
                if ($v -is [System.Management.Automation.Language.ArrayLiteralAst]) { $items = @($v.Elements) }
                if (@($items | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $_ -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }).Count) {
                    & $add 'PS51' $c "$name by property name fails on hashtables in Windows PowerShell 5.1; use a scriptblock or add '# lai-ok: objects'"
                }
            }
        }
        # The installer runs elevated (silently, from the resume task): it must never run code from
        # AI\Scripts, which lives in a folder the user controls. Use $SourceRoot (its own copy).
        $viaVar = ($c.InvocationOperator -eq 'Ampersand' -or $c.InvocationOperator -eq 'Dot') -and $c.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $scriptsVars -contains $c.CommandElements[0].VariablePath.UserPath
        if ($FileName -eq 'Install-LocalAI.ps1' -and ($c.InvocationOperator -eq 'Ampersand' -or $c.InvocationOperator -eq 'Dot' -or $name -eq 'Import-Module') -and
            ($c.Extent.Text -match '\$P\.Scripts' -or $viaVar) -and -not (& $marker $c 'elevated')) {
            & $add 'ELEVATED' $c 'the elevated installer runs code from AI\Scripts (user-controlled folder); run it from $SourceRoot'
        }
        # No scheduled task may run elevated: the scripts work on C:\AI, which the user controls.
        if ($name -eq 'New-ScheduledTaskPrincipal' -and $c.Extent.Text -match '(?i)-RunLevel\s+Highest' -and -not (& $marker $c 'elevated')) {
            & $add 'NOSILENT' $c 'scheduled task with -RunLevel Highest: it would run toolkit code elevated without a UAC prompt'
        }
        # A double quote inside an argument for a native program: 5.1 wraps an argument with spaces in
        # quotes but leaves inner ones unescaped (docker got '{{.Label com.docker...}}' and failed).
        $nativeNames = @('docker', 'docker.exe', 'wsl', 'wsl.exe', 'ollama', 'ollama.exe', 'icacls', 'schtasks', 'netsh', 'tailscale', 'nvidia-smi', 'winget', 'cmd', 'cmd.exe', 'git')
        $wrappers = @('Invoke-Native', 'Invoke-Docker', 'Invoke-DockerText', 'Invoke-DockerCli', 'Invoke-DockerQuiet', 'Invoke-Compose', 'Invoke-Tailscale', 'Invoke-Capture', 'Invoke-LaiTimedNative')
        if (($nativeNames -contains $name -or $wrappers -contains $name) -and -not (& $marker $c 'quote')) {
            $quoted = @($c.FindAll({ param($n) ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -ne 'BareWord') -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) |
                Where-Object { $_.Value -match '"' })
            if ($quoted.Count) { & $add 'NATIVEQUOTE' $c "argument with a double quote for a native program ($($quoted[0].Extent.Text)): 5.1 strips it; use backticks in Go templates or avoid the quote" }
        }
        # Scheduled tasks' scripts, and the four the owner runs when something is wrong: docker only
        # through the timed helpers (Test-LaiDockerEngine, Invoke-LaiTimedNative), at least for the
        # engine probe, which is where a stuck Docker hangs first. In $hangNoDirect no direct docker
        # call at all (the backup script keeps its own untimed wrapper for the long calls).
        $hangNoDirect = @('Watch-LocalAI.ps1', 'Start-LocalAI.ps1', 'Stop-LocalAI.ps1', 'Test-LocalAI.ps1', 'Get-LocalAIDiagnostics.ps1')
        if ((@('Backup-OpenWebUI.ps1') + $hangNoDirect) -contains $FileName -and -not (& $marker $c 'hang')) {
            $isDocker = @('docker', 'docker.exe') -contains $name
            $probe = (($isDocker -or $name -eq 'Invoke-Docker') -and @($c.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq 'version' }, $true)).Count -gt 0)
            if ($probe -or ($isDocker -and $hangNoDirect -contains $FileName)) {
                & $add 'HANG' $c 'docker without a time limit: a stuck Docker Desktop hangs this script without a word; use Test-LaiDockerEngine / Invoke-LaiTimedNative'
            }
        }
        # A task action that runs powershell.exe itself shows a window on Windows 11.
        if ($name -eq 'New-ScheduledTaskAction' -and -not (& $marker $c 'window')) {
            $els2 = $c.CommandElements
            for ($j = 1; $j -lt $els2.Count - 1; $j++) {
                if ($els2[$j] -is [System.Management.Automation.Language.CommandParameterAst] -and $els2[$j].ParameterName -eq 'Execute' -and
                    $els2[$j + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $els2[$j + 1].Value -match '(?i)^powershell(\.exe)?$') {
                    & $add 'HIDDENTASK' $c 'scheduled task runs powershell.exe directly (a visible window on Windows 11); use Get-LaiHiddenTaskLaunch, or mark an intentionally visible one # lai-ok: window'
                }
            }
        }
        # The Ollama tray app started without 'hidden' shows its window (0.10+ desktop app).
        if (@('Start-Process', 'saps', 'start', 'Start-AsUser') -contains $name -and -not (& $marker $c 'hidden')) {
            $viaApp = @($c.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $appVars -contains $n.VariablePath.UserPath }, $true)).Count -gt 0
            if (($c.Extent.Text -match 'ollama app\.exe' -or $viaApp) -and $c.Extent.Text -notmatch "'hidden'") {
                & $add 'OLLAMAAPP' $c "the Ollama tray app is started without 'hidden', so its window opens; use Start-LaiOllamaApp"
            }
        }
        # Ollama's Startup shortcut opened: a sign-in start without --fast-startup installs a pending update.
        if (@('Start-Process', 'saps', 'start', 'Start-AsUser', 'Invoke-Item', 'ii') -contains $name) {
            $viaLink = @($c.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $linkVars -contains $n.VariablePath.UserPath }, $true)).Count -gt 0
            if ($c.Extent.Text -match $startupLinkRx -or $viaLink) {
                & $add 'OLLAMAAPP' $c "Ollama started through its Startup\Ollama.lnk installs a pending Ollama update right away; use Start-LaiOllamaApp (or the exe, '# lai-ok: hidden')"
            }
        }
        if (@('Install-LocalAI.ps1', 'Uninstall-LocalAI.ps1') -contains $FileName -and @('Remove-Item', 'rm', 'del', 'rmdir', 'rd', 'ri', 'erase') -contains $name -and
            @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and ($_.ParameterName -like 'rec*' -or $_.ParameterName -eq 'r') }).Count -and -not (& $marker $c 'recurse')) {
            & $add 'RECURSE' $c 'Remove-Item -Recurse as administrator follows junctions in C:\AI on Windows PowerShell 5.1; use Remove-LaiTree'
        }
        # Get-Content of a config/state/env/secret file without -Encoding: Windows PowerShell 5.1 reads
        # BOM-less UTF-8 (how .env must be written for docker compose) as ANSI and garbles non-ASCII.
        if (@('Get-Content', 'gc', 'cat', 'type') -contains $name -and -not (& $marker $c 'encoding')) {
            $gb = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($c, $true)
            $pathArg = $null
            foreach ($pn in 'LiteralPath', 'Path') { if (-not $pathArg -and $gb.BoundParameters.ContainsKey($pn)) { $pathArg = $gb.BoundParameters[$pn].Value } }
            # -Encoding is a provider (dynamic) parameter the static binder cannot see: look for it directly.
            $hasEnc = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and 'encoding'.StartsWith($_.ParameterName.ToLower()) -and $_.ParameterName.Length -ge 3 }).Count -gt 0
            if ($pathArg -and -not $hasEnc -and $pathArg.Extent.Text -match '(?i)env|json|cred|secret|config|state|settings|hold|pending|\.yml') {
                & $add 'ENCODING' $c "Get-Content $($pathArg.Extent.Text) without -Encoding UTF8: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI"
            }
        }
        # Select-String on a file: 5.1 reads it in the ANSI code page too (Ollama's server.log is UTF-8,
        # so C:\Users\Jos<e-acute> came back as a different folder). Any file: the encoding is not
        # in its name. Text piped in (Get-Content ... -Encoding UTF8 | Select-String) is not flagged.
        if (@('Select-String', 'sls') -contains $name -and -not (& $marker $c 'encoding')) {
            $sb = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($c, $true)
            $hasEnc = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and 'encoding'.StartsWith($_.ParameterName.ToLower()) -and $_.ParameterName.Length -ge 3 }).Count -gt 0
            $hasPath = $sb.BoundParameters.ContainsKey('LiteralPath') -or $sb.BoundParameters.ContainsKey('Path') -or
                @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -match '^(LiteralPath|Path|PSPath|LP)$' }).Count -gt 0
            if ($hasPath -and -not $hasEnc) {
                & $add 'ENCODING' $c 'Select-String on a file without -Encoding UTF8: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI'
            }
        }
        # Writing a file: 5.1's Add-Content/Set-Content default to the ANSI code page (Out-File to
        # UTF-16), while every reader here uses UTF-8, so a non-ASCII path or name in a log came back
        # garbled and could slip past the diagnostics redaction.
        # Toolkit scripts only: the test harness writes its own scratch files and runs on pwsh.
        if (@('Add-Content', 'ac', 'Set-Content', 'sc', 'Out-File') -contains $name -and $FileName -notmatch '^(Invoke-|Reset-Sandbox)' -and -not (& $marker $c 'encoding')) {
            $hasEnc = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and 'encoding'.StartsWith($_.ParameterName.ToLower()) -and $_.ParameterName.Length -ge 3 }).Count -gt 0
            if (-not $hasEnc) { & $add 'ENCODING' $c "$name without -Encoding: Windows PowerShell 5.1 writes the ANSI code page (Out-File: UTF-16), the readers expect UTF-8" }
        }
        # A string or (...) argument followed by a bare -f or + : meant as an operator, bound as an
        # argument. Only Verb-Noun commands: native tools (docker -f file) take -f legitimately.
        $els = $c.CommandElements
        for ($i = 2; $i -lt $els.Count -and $name -match '^[A-Za-z]+-[A-Za-z]+$'; $i++) {
            $prevEl = $els[$i - 1]
            $isText = $prevEl -is [System.Management.Automation.Language.ParenExpressionAst] -or
                $prevEl -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                $prevEl -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                ($prevEl -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $prevEl.StringConstantType -ne 'BareWord')
            if (-not $isText) { continue }
            $el = $els[$i]
            $op = $null
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq 'f') { $op = '-f' }
            # String operators no cmdlet here has as a parameter: '@(Get-X @(...) -split "`n")' passes
            # -split to Get-X and never splits.
            elseif ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -match '^[ci]?(split|join|replace)$') { $op = '-' + $el.ParameterName }
            elseif ($el -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $el.StringConstantType -eq 'BareWord' -and $el.Value -eq '+') { $op = '+' }
            if ($op -and -not (& $marker $c 'format')) {
                & $add 'FORMAT' $c "$name gets '$op' as a separate argument (command mode); wrap the whole expression: $name ((...) $op ...)"
            }
        }
    }

    # Ollama's settings line searched for a hard-coded key and value instead of parsed.
    foreach ($b in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$n.Operator -match '^[IC]?(Match|NotMatch|Like|NotLike)$' }, $true)) {
        # Ollama's own 'OLLAMA_X:value' (no space; not part of a longer name such as LDR_LLM_OLLAMA_URL: in compose).
        if ($b.Right.Extent.Text -cmatch '(?<![A-Z_])OLLAMA_[A-Z_]+:(?! )' -and -not (& $marker $b 'serverlog')) {
            & $add 'SERVERLOG' $b "server.log searched for $($b.Right.Extent.Text): a key a newer Ollama no longer logs reads as a wrong setting; use Test-LaiOllamaServerSettings"
        }
    }

    foreach ($if in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
        foreach ($clause in $if.Clauses) {
            $cond = $clause.Item1; $body = $clause.Item2
            $matchOps = @($cond.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and @('Imatch', 'Cmatch', 'Match') -contains [string]$n.Operator }, $true) | Sort-Object { $_.Extent.StartOffset })
            if ($matchOps.Count -lt 2 -or (& $marker $cond 'matches')) { continue }
            $isMatches = { param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq 'Matches' }
            $secondEnd = $matchOps[1].Extent.EndOffset
            $late = @($cond.FindAll($isMatches, $true) | Where-Object { $_.Extent.StartOffset -ge $secondEnd })
            $inBody = @($body.FindAll($isMatches, $true))
            if ($late.Count -or $inBody.Count) {
                & $add 'MATCHES' $cond 'two -match operators in one condition, then $Matches is read: it holds the groups of the LAST match; copy the groups before matching again'
            }
        }
    }

    # Update-OpenWebUI.ps1: no .env switch (Set-EnvVersion) followed, in its block or one nested in
    # it, by a pull (pulls inside another function do not count: Invoke-PullFirst's own body).
    if ($FileName -eq 'Update-OpenWebUI.ps1') {
        $upTo = { param($n, [type]$T) $q = $n.Parent; while ($q -and -not ($q -is $T)) { $q = $q.Parent }; $q }
        $fnStart = { param($n) $f = & $upTo $n ([System.Management.Automation.Language.FunctionDefinitionAst]); if ($f) { $f.Extent.StartOffset } else { -1 } }
        $cmds = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $pulls = @($cmds | Where-Object { $_.GetCommandName() -eq 'Invoke-PullFirst' -or (@('Invoke-Docker', 'docker', 'docker.exe') -contains $_.GetCommandName() -and
            @($_.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq 'pull' }, $true)).Count -gt 0) })
        foreach ($sw in @($cmds | Where-Object { $_.GetCommandName() -eq 'Set-EnvVersion' })) {
            $blk = $sw.Parent
            while ($blk -and -not ($blk -is [System.Management.Automation.Language.StatementBlockAst] -or $blk -is [System.Management.Automation.Language.NamedBlockAst])) { $blk = $blk.Parent }
            if (-not $blk) { continue }
            $swFn = & $fnStart $sw
            $later = @($pulls | Where-Object { $_.Extent.StartOffset -gt $sw.Extent.StartOffset -and $_.Extent.EndOffset -le $blk.Extent.EndOffset -and (& $fnStart $_) -eq $swFn })
            if ($later.Count -and -not (& $marker $sw 'envfirst')) {
                & $add 'ENVFIRST' $sw '.env is switched before the image is pulled: a run cut off mid-download leaves .env naming a missing image; pull first (Invoke-PullFirst), then Set-EnvVersion'
            }
        }
    }

    # Ollama / Docker Desktop in a custom folder: only the locators in lib\LocalAI.psm1 know the defaults.
    if ($UserFacing) {
        foreach ($s in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
            if ([string]$s.Value -match '(?i)Programs[\\/]Ollama|Docker[\\/]Docker' -and -not (& $marker $s 'locator')) {
                & $add 'LOCATOR' $s 'hard-coded Ollama / Docker Desktop install folder (a custom install folder is missed); use Find-LaiOllamaDir / Find-LaiDockerDesktopExe'
            }
        }
    }

    # .GetResult() must sit in a try with a catch (statement-terminating .NET exceptions).
    foreach ($gr in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -eq 'GetResult' }, $true)) {
        $caught = $false
        $q = $gr.Parent
        while ($q) {
            if ($q -is [System.Management.Automation.Language.TryStatementAst] -and $q.CatchClauses.Count -gt 0 -and
                $gr.Extent.StartOffset -ge $q.Body.Extent.StartOffset -and $gr.Extent.EndOffset -le $q.Body.Extent.EndOffset) { $caught = $true; break }
            $q = $q.Parent
        }
        if (-not $caught -and -not (& $marker $gr 'netcatch')) { & $add 'NETCATCH' $gr '.GetResult() outside a try with a catch: a failed .NET call would let the function carry on with no result; catch it and throw a clear message' }
    }

    # A process-scope environment variable set directly (Set-LaiProcessEnv removes one restored to $null).
    foreach ($im in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -eq 'SetEnvironmentVariable' }, $true)) {
        $target = ''; if (@($im.Arguments).Count -ge 3) { $target = [string]$im.Arguments[2].Extent.Text }
        if ($target -notmatch "(?i)'(User|Machine)'|EnvironmentVariableTarget\]::(User|Machine)" -and -not (& $marker $im 'env')) {
            & $add 'ENVRESTORE' $im "process environment set with SetEnvironmentVariable: a `$null value leaves an empty variable on PowerShell 7/Linux; use Set-LaiProcessEnv"
        }
    }

    # Every parameter of a user-facing script is explained somewhere Get-Help shows it.
    $help = $null
    if ($UserFacing -and $Ast -is [System.Management.Automation.Language.ScriptBlockAst] -and $Ast.ParamBlock) { $help = $Ast.GetHelpContent() }
    # A help block PowerShell does not recognise is invisible to Get-Help: '#Requires' directly
    # above '<#' (no blank line) joins them into one comment that does not start with a keyword.
    if ($UserFacing -and -not $help -and @($Lines | Select-Object -First 6 | Where-Object { $_ -match '^\s*<#' }).Count) {
        & $add 'HELP' $Ast 'the comment-based help is not recognised (Get-Help shows nothing); put a blank line between #Requires and <#'
    }
    if ($help) {
        $helpText = (@($help.Synopsis, $help.Description) + @($help.Examples) + @($help.Notes)) -join "`n"
        foreach ($prm in $Ast.ParamBlock.Parameters) {
            $pn = $prm.Name.VariablePath.UserPath
            if ($help.Parameters.ContainsKey($pn.ToUpperInvariant())) { continue }
            if ($helpText -match ('(?i)-' + [regex]::Escape($pn) + '\b')) { continue }
            $above = $prm.Extent.StartLineNumber - 2
            while ($above -ge 0 -and $Lines[$above] -match '^\s*$') { $above-- }
            if ($above -ge 0 -and $Lines[$above] -match '^\s*#') { continue }
            if (& $marker $prm 'help') { continue }
            & $add 'HELP' $prm "parameter -$pn is not documented: add .PARAMETER $pn or a # comment line right above it"
        }
    }

    foreach ($v in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq 'PSBoundParameters' }, $true)) {
        $sb = $v.Parent
        while ($sb -and -not ($sb -is [System.Management.Automation.Language.ScriptBlockAst])) { $sb = $sb.Parent }
        if (-not $sb -or -not ($sb.Parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst])) { continue }
        # ForEach-Object / Where-Object (and .ForEach/.Where) run the block in the caller's scope: fine.
        $owner = $sb.Parent.Parent
        if ($owner -is [System.Management.Automation.Language.CommandAst] -and @('ForEach-Object', 'Where-Object', '%', '?', 'foreach', 'where') -contains $owner.GetCommandName()) { continue }
        if ($owner -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and @('ForEach', 'Where') -contains [string]$owner.Member.Value) { continue }
        if (& $marker $v 'bound') { continue }
        & $add 'BOUND' $v '$PSBoundParameters inside a scriptblock is that block''s own (empty) set; copy the script''s to $script:BoundParams first'
    }
    # INSTEXIT: once the installer has started its transcript and taken the setup lock, a bare 'exit'
    # leaves both behind (in a long-lived session the transcript keeps writing; the lock blocks the
    # next run until the window closes). Stop-Install releases them.
    if ($FileName -eq 'Install-LocalAI.ps1' -or $FileName -eq 'INSTEXIT-canary') {
        $tr = $Ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Transcript' }, $true)
        if ($tr) {
            foreach ($x in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] -and $n.Extent.StartOffset -gt $tr.Extent.StartOffset }, $true))) {
                $fn = $x.Parent
                while ($fn -and -not ($fn -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $fn = $fn.Parent }
                if ($fn -and $fn.Name -eq 'Stop-Install') { continue }
                if (& $marker $x 'exit') { continue }
                & $add 'INSTEXIT' $x 'bare exit after the transcript and setup lock are taken: use Stop-Install -Code <n> (releases both)'
            }
        }
    }
    return , $found
}

function Find-DocParam([string]$Text, [hashtable]$ParamsByScript, [hashtable]$ValueParamsByScript = @{}) {
    # "Script.ps1 -A -B x" in the docs: every -A must be a parameter of that script. The command runs
    # to the end of the code span or line, or a comment / pipe / ';'. Install-LocalAI.cmd passes its
    # arguments to Install-LocalAI.ps1. -WhatIf/-Confirm/-Verbose are common parameters.
    # A parameter that takes a value (not a [switch]; listed in $ValueParamsByScript) must be followed
    # by one: "Update-Models.ps1 -Rollback, ..." stops with "Missing an argument for parameter".
    $found = New-Object System.Collections.Generic.List[object]
    $lineNo = 0
    foreach ($line in ($Text -split "`n")) {
        $lineNo++
        foreach ($m in [regex]::Matches($line, '([A-Za-z][\w-]*)\.(ps1|cmd)((?:[ \t]+(?![\w\\:.-]*\.(?:ps1|cmd)\b)[^`|#;\s]+)*)')) {
            $script = $m.Groups[1].Value + '.ps1'
            if (-not $ParamsByScript.ContainsKey($script)) { continue }
            $words = @($m.Groups[3].Value -split '\s+' | Where-Object { $_ })
            for ($i = 0; $i -lt $words.Count; $i++) {
                if ($words[$i] -notmatch '^-([A-Za-z]\w*)(.*)$') { continue }
                $pn = $Matches[1]; $rest = $Matches[2]
                if (@('WhatIf', 'Confirm', 'Verbose') -contains $pn) { continue }
                if (@($ParamsByScript[$script] | Where-Object { $_ -eq $pn }).Count -eq 0) {
                    $found.Add([pscustomobject]@{ Rule = 'DOCPARAM'; Line = $lineNo; Message = "$script has no parameter -$pn (docs: $($m.Value.Trim()))" })
                    continue
                }
                if (-not $ValueParamsByScript.ContainsKey($script) -or @($ValueParamsByScript[$script] | Where-Object { $_ -eq $pn }).Count -eq 0) { continue }
                # A value: -Name:value, or a next word that is not another -Parameter. "-Name," / "-Name)"
                # (punctuation right after the name) ends the command there.
                $hasValue = ($rest -match '^:.') -or ($rest -eq '' -and $i + 1 -lt $words.Count -and $words[$i + 1] -notmatch '^-[A-Za-z]')
                if (-not $hasValue) {
                    $found.Add([pscustomobject]@{ Rule = 'DOCPARAM'; Line = $lineNo; Message = "$script -$pn needs a value (docs: $($m.Value.Trim()))" })
                }
            }
        }
    }
    return , $found
}

function Find-MdTableGap([string]$Text) {
    # Line numbers of Markdown table rows whose cell count differs from their table's header row: a
    # lost newline between two rows ('... | | next row ...' or '...||...') makes one long row, and
    # GitHub drops the extra cells, so the second row vanishes from the rendered README.
    $gaps = New-Object System.Collections.Generic.List[int]
    $want = -1
    $n = 0
    foreach ($l in ($Text -split "`r?`n")) {
        $n++
        if ($l -notmatch '^\s*\|') { $want = -1; continue }
        # Code spans and escaped pipes are not cell borders.
        $cells = (($l -replace '`[^`]*`', 'x') -replace '\\\|', 'x').Trim().Trim('|').Split('|').Count
        if ($want -lt 0) { $want = $cells; continue }
        if ($cells -ne $want) { $gaps.Add($n) }
    }
    return , $gaps
}

function Find-ComposeLogGap([string]$Text) {
    # Service names under 'services:' whose block has no 'logging:' (or a '<<:' merge that may carry
    # it). Comments and blank lines are skipped; the service indent is taken from the first service.
    $missing = @(); $inServices = $false; $svc = $null; $hasLog = $false; $ind = $null
    foreach ($raw in (($Text -split "`n") + @('end:'))) {
        $l = $raw.TrimEnd("`r")
        if ($l -match '^\s*(#|$)') { continue }
        if ($l -match '^\S') {
            if ($svc -and -not $hasLog) { $missing += $svc }
            $svc = $null; $ind = $null; $inServices = ($l -match '^services:\s*(#.*)?$'); continue
        }
        if (-not $inServices) { continue }
        $lead = $l.Length - $l.TrimStart(' ').Length
        if ($null -eq $ind) { $ind = $lead }
        if ($lead -eq $ind -and $l -match '^\s*([A-Za-z0-9_.-]+):\s*(#.*)?$') {
            if ($svc -and -not $hasLog) { $missing += $svc }
            $svc = $Matches[1]; $hasLog = $false
        } elseif ($lead -eq 2 * $ind -and $l -match '^\s*(logging|<<):') { $hasLog = $true }
    }
    return , $missing
}

function Find-ComposeSecGap([string]$Text) {
    # Rule COMPOSESEC: what a service in stack/docker-compose.yml lacks of the hardening every
    # service of the stack carries (docs/CONTAINER-HARDENING-PLAN.md): 'no-new-privileges:true'
    # under security_opt, ALL under cap_drop, a mem_limit, a pids_limit, and every published port
    # bound to 127.0.0.1. One sentence per gap. Without them a container that is taken over keeps
    # every default capability, may use all the memory and processes of the PC, or is reachable
    # from the LAN.
    # Also a gap: what hands all of it back in one line. 'privileged' (anything but false) makes
    # Docker ignore cap_drop and give every capability, and ALL under cap_add does the same beside
    # cap_drop ALL.
    # Only what is written out in the service's own block counts: a flow mapping or a ${VARIABLE}
    # for a limit cannot be read here, so it does not satisfy the rule. A '<<' merge at the
    # service's own level is a gap by itself: it can bring in any key ('privileged', 'ports') from
    # an anchor this check does not follow, and so can 'extends'. A line at the service's own level
    # that this check cannot read as 'key: value' (a quoted key, a space before the colon) is a gap
    # too: it could be a 'privileged' or 'ports' key written another way, which Docker reads.
    $gaps = New-Object System.Collections.Generic.List[string]
    $bodies = [ordered]@{}
    $inServices = $false; $svc = $null; $ind = $null
    foreach ($raw in ($Text -split "`n")) {
        $l = $raw.TrimEnd("`r")
        if ($l -match '^\s*(#|$)') { continue }
        if ($l -match '^\S') { $svc = $null; $ind = $null; $inServices = ($l -match '^services:\s*(#.*)?$'); continue }
        if (-not $inServices) { continue }
        $lead = $l.Length - $l.TrimStart(' ').Length
        if ($null -eq $ind) { $ind = $lead }
        if ($lead -eq $ind) { $svc = ($l.Trim() -split ':')[0]; $bodies[$svc] = New-Object System.Collections.Generic.List[string]; continue }
        if ($svc) { $bodies[$svc].Add($l) }
    }
    if ($bodies.Count -eq 0) { $gaps.Add("no service found under 'services:'") }
    # A YAML list as written, one string per item: inline '[a, "b"]' or one '- item' per line (the
    # further lines of a mapping item are joined to it). Comments and the quotes around an item go.
    $items = {
        param($Lines)
        $out = New-Object System.Collections.Generic.List[string]
        if ($null -eq $Lines) { return }
        $inline = ($Lines[0] -replace '(^|\s+)#.*$', '').Trim()
        if ($inline -match '^\[(.*)\]$') { foreach ($p in ($Matches[1] -split ',')) { if ($p.Trim()) { $out.Add($p.Trim().Trim([char]34, [char]39)) } } }
        elseif ($inline) { $out.Add($inline.Trim([char]34, [char]39)) }
        for ($i = 1; $i -lt $Lines.Count; $i++) {
            $t = ($Lines[$i] -replace '(^|\s+)#.*$', '').Trim()
            if ($t -match '^-\s*(.*)$') { $out.Add($Matches[1].Trim().Trim([char]34, [char]39)) }
            elseif ($t -and $out.Count) { $out[$out.Count - 1] = $out[$out.Count - 1] + '; ' + $t }
        }
        return $out
    }
    foreach ($name in $bodies.Keys) {
        # The service's own keys (the indent of its first line), each with its value: what follows
        # the colon, then the lines below it that are deeper or are list items ('- x' may stand at
        # the indent of its key).
        $keys = @{}; $key = $null; $kInd = $null
        foreach ($l in $bodies[$name]) {
            $lead = $l.Length - $l.TrimStart(' ').Length
            if ($null -eq $kInd) { $kInd = $lead }
            if ($lead -gt $kInd -or $l.Trim() -match '^-(\s|$)') { if ($key) { $keys[$key].Add($l.Trim()) }; continue }
            $key = $null
            # '<<' is read as a key like any other, so that a merge at this level is seen below.
            if ($l -match '^\s*([A-Za-z0-9_.-]+|<<):(\s.*)?$') {
                $key = $Matches[1]
                $keys[$key] = New-Object System.Collections.Generic.List[string]
                $keys[$key].Add(([string]$Matches[2]).Trim())
            } else {
                $shown = $l.Trim(); if ($shown.Length -gt 50) { $shown = $shown.Substring(0, 50) + '...' }
                $gaps.Add("service '$name' has a line this check cannot read ($shown): write the key plainly, as key: value")
            }
        }
        if (-not @(& $items $keys['security_opt'] | Where-Object { $_ -match '^no-new-privileges([:=]true)?$' }).Count) {
            $gaps.Add("service '$name' has no 'no-new-privileges:true' under security_opt")
        }
        if (-not @(& $items $keys['cap_drop'] | Where-Object { $_ -eq 'ALL' }).Count) {
            $gaps.Add("service '$name' has no ALL under cap_drop")
        }
        if (@(& $items $keys['cap_add'] | Where-Object { $_ -match '^(CAP_)?ALL$' }).Count) {
            $gaps.Add("service '$name' has ALL under cap_add (that gives back every capability cap_drop took away)")
        }
        if ($keys.ContainsKey('privileged')) {
            $priv = (@(& $items $keys['privileged']) -join ' ')
            if ($priv -ne 'false') { $gaps.Add("service '$name' has 'privileged: $priv' (a privileged container gets every capability, whatever cap_drop says; only false or no such line will do)") }
        }
        if ($keys.ContainsKey('<<')) {
            $gaps.Add("service '$name' takes keys from a '<<' merge (this check reads only what is written out in the service itself: write the keys out)")
        }
        if ($keys.ContainsKey('extends')) {
            $gaps.Add("service '$name' takes keys from another service with 'extends' (this check does not follow it: write the keys out)")
        }
        $mem = (@(& $items $keys['mem_limit']) -join ' ')
        if ($mem -notmatch '^[0-9]' -or $mem -match '^0+(\.0+)?[A-Za-z]*$') {
            $gaps.Add("service '$name' has no mem_limit (a size above zero, written out)")
        }
        $pids = (@(& $items $keys['pids_limit']) -join ' ')
        if ($pids -notmatch '^[1-9][0-9]*$') {
            $gaps.Add("service '$name' has no pids_limit (a number above zero, written out)")
        }
        foreach ($p in @(& $items $keys['ports'])) {
            # Long syntax (a mapping with host_ip) or short syntax ('127.0.0.1:3000:8080').
            $bound = $p -match '^127\.0\.0\.1:'
            if ($p -match '(^|[{;,\s])[a-z_]+:(\s|$)') { $bound = $p -match '(^|[{;,\s])host_ip:\s*["'']?127\.0\.0\.1["'']?\s*([;,}]|$)' }
            if (-not $bound) { $gaps.Add("service '$name' publishes a port that is not bound to 127.0.0.1 ($p)") }
        }
    }
    return , $gaps.ToArray()
}

function Find-TestHook([System.Management.Automation.Language.Ast]$Ast, [string]$File = '') {
    # Rule TESTHOOK, the finding half: every place where the script $Ast takes something from a
    # test. One object per place: File (as given), Kind ('env' for a read of a test variable from
    # the environment, 'param' for a script parameter that begins Test), Name, Line, and Seen (the
    # form, for the message). The syntax tree only, never the file's text: comments name these
    # variables (Watch-LocalAI.ps1 says why it reads none of them).
    # A third kind, 'text', is no such place and no problem: a string that holds a test
    # variable's name, or the start of one, and is none of the reads. It is what a read leaves
    # behind when it moves out of this rule's sight; Find-TestHookProblem holds a stale entry
    # against it.
    $found = New-Object System.Collections.Generic.List[object]
    $nameRx = [regex]'(?i)^(?:LOCALAI_TEST_.*|LOCALAI_DOCKER_TIMEOUT|LOCALAI_TS_TIMEOUT)$'
    $add = { param($Kind, $Name, $Node, $Seen) $found.Add([pscustomobject]@{ File = $File; Kind = $Kind; Name = $Name; Line = $Node.Extent.StartLineNumber; Seen = $Seen }) }
    # The strings that are a read below (by where they begin): not looked at again as 'text'.
    $counted = @{}

    # $env:NAME, also inside a double-quoted string.
    foreach ($v in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $path = [string]$v.VariablePath.UserPath
        if ($path -notmatch '^env:' -or -not $nameRx.IsMatch($path.Substring(4))) { continue }
        # '$env:NAME = value' sets it (a cast in front changes nothing): not a read. '+=' and the
        # like read it first, and so does the same name in the condition of the line that sets it
        # (Restore-OpenWebUI.ps1: if ($env:NAME) { $env:NAME = '' }).
        $left = $v
        while ($left.Parent -is [System.Management.Automation.Language.AttributedExpressionAst]) { $left = $left.Parent }
        $asg = $left.Parent
        if ($asg -is [System.Management.Automation.Language.AssignmentStatementAst] -and [object]::ReferenceEquals($asg.Left, $left) -and [string]$asg.Operator -eq 'Equals') { continue }
        & $add 'env' $path.Substring(4) $v ('$env:' + $path.Substring(4))
    }

    # [Environment]::GetEnvironmentVariable('NAME'), with or without a target. By the method's name,
    # as ENVRESTORE goes by SetEnvironmentVariable; a name that is not written out is not seen.
    foreach ($im in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -eq 'GetEnvironmentVariable' }, $true)) {
        $first = @($im.Arguments)[0]
        if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $nameRx.IsMatch([string]$first.Value)) {
            & $add 'env' ([string]$first.Value) $im ("GetEnvironmentVariable('{0}')" -f $first.Value)
            $counted[$first.Extent.StartOffset] = $true
        }
    }

    # Get-Item, Get-Content, Get-ChildItem and Test-Path on the Env: drive (Env:NAME, Env:\NAME,
    # Env:/NAME), by position, behind -Path or -LiteralPath, or as one of several paths.
    $readers = @('Get-Item', 'gi', 'Get-Content', 'gc', 'cat', 'type', 'Get-ChildItem', 'gci', 'dir', 'ls', 'Test-Path')
    foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $cmd = $c.GetCommandName()
        if (-not $cmd -or $readers -notcontains $cmd) { continue }
        foreach ($s in $c.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $false)) {
            $word = [string]$s.Value
            if ($word -notmatch '^env:[\\/]?') { continue }
            $name = $word -replace '^env:[\\/]?', ''
            if ($nameRx.IsMatch($name)) { & $add 'env' $name $s ('{0} Env:{1}' -f $cmd, $name); $counted[$s.Extent.StartOffset] = $true }
        }
    }

    # Kind 'text': a string (quoted, a here-string, a bare word, a key) that holds such a name, or
    # LOCALAI_TEST_ with as much of a name as follows it there, and is none of the reads above. A
    # name put together at run time ('LOCALAI_TEST_' + $what), one kept in a variable or looked up
    # in the table of all variables, and code held as text for another PowerShell all leave one.
    # So do a message that names a variable and a call that sets one: no read, hence no problem.
    $wordRx = [regex]'(?i)(?<![A-Za-z0-9_])(?:LOCALAI_TEST_[A-Za-z0-9_]*|LOCALAI_DOCKER_TIMEOUT|LOCALAI_TS_TIMEOUT)(?![A-Za-z0-9_])'
    foreach ($s in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
        if ($counted.ContainsKey($s.Extent.StartOffset)) { continue }
        $text = [string]$s.Extent.Text
        if ($s -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            # What the string expands is not the string's own text ("... $env:NAME" is a read
            # above): blanked, the line breaks kept for the line number.
            $chars = $text.ToCharArray()
            foreach ($ne in $s.NestedExpressions) {
                $to = [Math]::Min($ne.Extent.EndOffset - $s.Extent.StartOffset, $chars.Length)
                for ($i = [Math]::Max($ne.Extent.StartOffset - $s.Extent.StartOffset, 0); $i -lt $to; $i++) {
                    if ($chars[$i] -ne [char]10) { $chars[$i] = [char]32 }
                }
            }
            $text = -join $chars
        }
        foreach ($m in $wordRx.Matches($text)) {
            $line = $s.Extent.StartLineNumber + @($text.Substring(0, $m.Index) -split "`n").Count - 1
            $found.Add([pscustomobject]@{ File = $File; Kind = 'text'; Name = $m.Value; Line = $line; Seen = 'a string' })
        }
    }

    # A parameter of the script itself. Not FindAll: a function's own parameter is that
    # function's business (lib\LocalAI.psm1 has a $Tested, an Ollama version).
    if ($Ast -is [System.Management.Automation.Language.ScriptBlockAst] -and $Ast.ParamBlock) {
        foreach ($prm in $Ast.ParamBlock.Parameters) {
            $pn = [string]$prm.Name.VariablePath.UserPath
            if ($pn -match '^Test') { & $add 'param' $pn $prm ('-' + $pn) }
        }
    }
    return $found.ToArray()
}

function Find-TestHookProblem($Hits, [string[]]$Pins = @()) {
    # Rule TESTHOOK, the judging half: one sentence per place in $Hits (from Find-TestHook) that
    # $Pins does not allow, and one per entry of $Pins that allows nothing any more. An entry is
    # '<file> <kind> <name>', the file as its path below the toolkit folder with '/', and stands
    # for itself only: no wildcard, no pattern. The list is handed in, so the canaries judge with
    # their own and the real one is read in one place. Nothing in a script can switch this off.
    # A hit of kind 'text' is no problem and no entry allows one: a stale 'env' entry is held
    # against them. An entry goes stale when its read is gone, and just as well when the read
    # only moved out of this rule's sight (the header lists where to). Told 'take it out' and no
    # more, the reader deletes the last trace of a hook that is still read, and the build is
    # green: so the sentence gives both cases, and names the string a moved read left behind.
    $out = New-Object System.Collections.Generic.List[string]
    $used = @{}; $said = @{}
    $texts = New-Object System.Collections.Generic.List[object]
    foreach ($h in $Hits) {
        if ($h.Kind -eq 'text') { $texts.Add($h); continue }
        $key = '{0} {1} {2}' -f $h.File, $h.Kind, $h.Name
        if ($Pins -contains $key) { $used[$key] = $true; continue }
        # Two reads of one name on one line are one sentence.
        $at = '{0}:{1}' -f $h.File, $h.Line
        if ($said.ContainsKey("$at $key")) { continue }
        $said["$at $key"] = $true
        if ($h.Kind -eq 'param') {
            $out.Add("$at test parameter $($h.Seen) is not on the pinned list: use a stand-in the test puts on PATH or a real parameter; a -Test parameter the run announces needs its own entry in `$testHookPins (tests/Invoke-StaticChecks.ps1)")
        } else {
            $out.Add("$at test variable $($h.Name) is read from the environment ($($h.Seen)): any program running as the user can set it for good; use a stand-in the test puts on PATH, a real parameter, or a -Test parameter the run announces")
        }
    }
    $list = '$testHookPins in tests/Invoke-StaticChecks.ps1'
    $moved = 'a helper, a name put together at run time, code held as text for another PowerShell'
    foreach ($p in $Pins) {
        if ($used.ContainsKey($p)) { continue }
        $gone = "pinned entry '$p' matches nothing any more"
        $entry = [regex]::Match($p, '^(?<file>.+) (?<kind>env|param) (?<name>\S+)$')
        if (-not $entry.Success) {
            $out.Add("${gone}: an entry is '<file> env <name>' or '<file> param <name>', nothing else; take it out of $list")
            continue
        }
        $pinFile = $entry.Groups['file'].Value; $pinName = $entry.Groups['name'].Value
        if ($entry.Groups['kind'].Value -eq 'param') {
            $out.Add("${gone}: if $pinFile has that parameter under no other name either, take the entry out of $list (the list only shrinks); a test parameter that only got a name that does not begin Test is a new hook this rule cannot see, not a removed one")
            continue
        }
        # The strings, in any script, that hold the entry's name or the start of it.
        $held = @($texts | Where-Object { $pinName.StartsWith([string]$_.Name, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($held.Count) {
            $more = ''; if ($held.Count -gt 1) { $more = ' (and {0} more outside tests)' -f ($held.Count - 1) }
            $out.Add("$gone, but $($held[0].File):$($held[0].Line) still holds '$($held[0].Name)' in a string${more}: a read that only moved ($moved) is a new hook this rule cannot see, not a removed one; take the entry out of $list only when nothing there reads $pinName")
        } else {
            $out.Add("${gone}: if neither $pinFile nor anything it calls reads $pinName any more, take the entry out of $list (the list only shrinks); if the read only moved ($moved), it is a new hook this rule cannot see, not a removed one, and the entry is its last trace")
        }
    }
    return $out.ToArray()
}

# Rule TESTHOOK: what main held when the rule came. One entry per file, kind and name, each
# written out (Find-TestHookProblem compares whole entries). Nothing is added here for a new read
# from the environment; an entry whose read or parameter is gone must go too. Gone, not moved: a
# read that went into a helper, into a name put together at run time or into text for another
# PowerShell is still read, this rule no longer sees it, and its entry is the last trace of it.
# Put such a read back where the rule sees it, or replace it, before the entry goes.
# Two entries are younger than the rule. Each is a test parameter that took the place of reads
# from the environment, and each has its reason in the comment above it. A parameter has to be
# passed to the run it changes; a variable set once changes every later run. The word 'env' or
# 'param' in an entry is written in small letters, as the sentence for a stale entry reads it.
$testHookPins = @(
    'Backup-OpenWebUI.ps1 env LOCALAI_TEST_CHAT_POLL_SEC'
    'Enable-TailscaleAccess.ps1 env LOCALAI_TS_TIMEOUT'
    'Install-LocalAI.ps1 env LOCALAI_TEST_ALLOW_CPU'
    'Install-LocalAI.ps1 env LOCALAI_TEST_CATALOG'
    'Install-LocalAI.ps1 env LOCALAI_TEST_FAIL_STAGE'
    'Install-LocalAI.ps1 env LOCALAI_TEST_WEBUI_OLLAMA_URL'
    # -TestFailOllamaUrl came in place of the variable LOCALAI_TEST_FAIL_OLLAMA_URL. It does one
    # thing: the step that sets the Ollama connection after a restore counts as failed, and the
    # message of that failure names the parameter. It is not said at the start of the run
    # (IMPROVEMENTS.md has the row). Only tests/Invoke-UpdateWebUITest.ps1 passes it.
    'Restore-OpenWebUI.ps1 param TestFailOllamaUrl'
    'Test-LocalAI.ps1 env LOCALAI_TEST_CATALOG'
    # -TestAllowCpu came in place of the variable LOCALAI_TEST_ALLOW_CPU. A run that gets it says
    # so in a warning at its start. Only tests/Invoke-ModelUpdateTest.ps1 passes it.
    'Update-Models.ps1 param TestAllowCpu'
    'Watch-LocalAI.ps1 param TestDockerTimeout'
    'Watch-LocalAI.ps1 param TestIntegrityEnd'
    'Watch-LocalAI.ps1 param TestToastFail'
    'Watch-LocalAI.ps1 param TestToastSetting'
    'lib/LocalAI.psm1 env LOCALAI_DOCKER_TIMEOUT'
    'lib/LocalAI.psm1 env LOCALAI_TEST_CHATS_IN_FLIGHT'
    'lib/LocalAI.psm1 env LOCALAI_TEST_GPU_BUSY'
    'lib/LocalAI.psm1 env LOCALAI_TEST_KNOWLEDGE_FAIL'
    'lib/LocalAI.psm1 env LOCALAI_TEST_LOAD_FAIL'
    'lib/LocalAI.psm1 env LOCALAI_TEST_SIGNIN_WAIT'
    'lib/LocalAI.psm1 env LOCALAI_TEST_SPEED_FAIL'
)

# ---- canaries: every rule must fire on its bad snippet and stay quiet on the fixed one ---------
$canaries = @(
    @{ Rule = 'PS51'; Fire = $true; Code = '$h | Measure-Object -Property Size -Sum' }
    @{ Rule = 'PS51'; Fire = $true; Code = '$h | Sort-Object Name' }
    @{ Rule = 'PS51'; Fire = $false; Code = '$h | Sort-Object { $_.Name }' }
    @{ Rule = 'PS51'; Fire = $false; Code = '$f | Measure-Object -Property Length -Sum  # lai-ok: objects' }
    @{ Rule = 'FORMAT'; Fire = $true; Code = 'Write-LaiLog WARN ("{0} left" -f $a) -f $b' }
    @{ Rule = 'FORMAT'; Fire = $true; Code = 'Write-LaiLog WARN ("{0} free") -f $gb' }
    @{ Rule = 'FORMAT'; Fire = $true; Code = 'Write-Host ''Disk: '' + $gb' }
    @{ Rule = 'FORMAT'; Fire = $true; Code = 'Write-UpdateLog "x $a" -f $b' }
    @{ Rule = 'FORMAT'; Fire = $false; Code = 'Write-LaiLog WARN (("{0} free") -f $gb)' }
    @{ Rule = 'FORMAT'; Fire = $true; Code = '$t = @(Invoke-DockerText @(''images'', ''x'') -split "`n")' }
    @{ Rule = 'FORMAT'; Fire = $true; Code = 'Write-Host "a,b" -replace '','', '';''' }
    @{ Rule = 'FORMAT'; Fire = $false; Code = '$t = @((Invoke-DockerText @(''images'', ''x'')) -split "`n")' }
    @{ Rule = 'FORMAT'; Fire = $false; Code = '& docker inspect -f ''{{.State.Status}}'' open-webui' }
    @{ Rule = 'FORMAT'; Fire = $false; Code = 'Remove-Item $p -f' }
    @{ Rule = 'FORMAT'; Fire = $false; Code = '& docker compose --project-directory (Join-Path $r ''S'') -f (Join-Path $r ''c.yml'') up' }
    @{ Rule = 'ELEVATED'; Fire = $true; File = 'Install-LocalAI.ps1'; Code = '& (Join-Path $P.Scripts ''Test-LocalAI.ps1'') -AIRoot $AIRoot' }
    @{ Rule = 'ELEVATED'; Fire = $true; File = 'Install-LocalAI.ps1'; Code = 'Import-Module (Join-Path $P.Scripts ''lib\LocalAI.psm1'')' }
    @{ Rule = 'ELEVATED'; Fire = $false; File = 'Install-LocalAI.ps1'; Code = '& (Join-Path $SourceRoot ''Test-LocalAI.ps1'') -AIRoot $AIRoot' }
    @{ Rule = 'ELEVATED'; Fire = $false; File = 'Install-LocalAI.ps1'; Code = '$x = Join-Path $P.Scripts ''Watch-LocalAI.ps1''' }
    @{ Rule = 'ELEVATED'; Fire = $true; File = 'Install-LocalAI.ps1'; Code = "`$b = Join-Path `$P.Scripts 'Backup-OpenWebUI.ps1'`n& `$b -AIRoot `$AIRoot" }
    @{ Rule = 'ELEVATED'; Fire = $false; File = 'Install-LocalAI.ps1'; Code = "`$b = Join-Path `$SourceRoot 'Backup-OpenWebUI.ps1'`n& `$b -AIRoot `$AIRoot" }
    @{ Rule = 'RECURSE'; Fire = $true; File = 'Uninstall-LocalAI.ps1'; Code = 'Remove-Item -LiteralPath $p -Recurse -Force' }
    @{ Rule = 'RECURSE'; Fire = $true; File = 'Install-LocalAI.ps1'; Code = 'rm $p -r' }
    @{ Rule = 'RECURSE'; Fire = $false; File = 'Install-LocalAI.ps1'; Code = 'Remove-LaiTree -Path $p' }
    @{ Rule = 'RECURSE'; Fire = $false; File = 'Backup-OpenWebUI.ps1'; Code = 'Remove-Item -LiteralPath $p -Recurse -Force' }
    @{ Rule = 'NOSILENT'; Fire = $true; Code = '$p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest' }
    @{ Rule = 'NOSILENT'; Fire = $false; Code = '$p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Limited' }
    @{ Rule = 'ENCODING'; Fire = $true; Code = 'foreach ($l in (Get-Content -LiteralPath $envPath)) { $l }' }
    @{ Rule = 'ENCODING'; Fire = $true; Code = '$c = Get-Content -LiteralPath $credFile -Raw | ConvertFrom-Json' }
    @{ Rule = 'ENCODING'; Fire = $false; Code = '$c = Get-Content -LiteralPath $credFile -Raw -Encoding UTF8 | ConvertFrom-Json' }
    @{ Rule = 'ENCODING'; Fire = $false; Code = 'Get-Content -LiteralPath $logFile -Tail 50' }
    @{ Rule = 'ENCODING'; Fire = $true; Code = '$k = (Get-Content -LiteralPath $secretFile -Raw).Trim()' }
    @{ Rule = 'ENCODING'; Fire = $true; Code = '$l = Select-String -LiteralPath $log -Pattern ''msg="server config"'' | Select-Object -Last 1' }
    @{ Rule = 'ENCODING'; Fire = $true; Code = 'if (Select-String -Path $report -Pattern ''need attention'' -Quiet) { 1 }' }
    @{ Rule = 'ENCODING'; Fire = $false; Code = '$l = Select-String -LiteralPath $log -Pattern ''x'' -Encoding UTF8 | Select-Object -Last 1' }
    @{ Rule = 'ENCODING'; Fire = $false; Code = '$l = Get-Content -LiteralPath $log -Encoding UTF8 | Select-String -Pattern ''x''' }
    @{ Rule = 'ENCODING'; Fire = $true; Code = 'Add-Content -LiteralPath $logFile -Value $line' }
    @{ Rule = 'ENCODING'; Fire = $true; Code = '$x | Out-File -FilePath $p' }
    @{ Rule = 'ENCODING'; Fire = $false; Code = 'Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8' }
    @{ Rule = 'INSTEXIT'; Fire = $true; File = 'INSTEXIT-canary'; Code = "Start-Transcript -Path `$x`nif (`$bad) { exit 1 }" }
    @{ Rule = 'INSTEXIT'; Fire = $false; File = 'INSTEXIT-canary'; Code = "Start-Transcript -Path `$x`nfunction Stop-Install { exit 0 }`nif (`$bad) { Stop-Install -Code 1 }" }
    @{ Rule = 'INSTEXIT'; Fire = $false; File = 'INSTEXIT-canary'; Code = "if (`$early) { exit 1 }`nStart-Transcript -Path `$x" }
    @{ Rule = 'MATCHES'; Fire = $true; Code = 'if ($l -match ''^(\w+)=(.*)$'' -and $Matches[1] -match ''KEY'') { Add-Secret $Matches[2] }' }
    @{ Rule = 'MATCHES'; Fire = $true; Code = 'if ($a -match ''x(\d)'' -and $b -match ''y'' -and $Matches[1]) { 1 }' }
    @{ Rule = 'MATCHES'; Fire = $false; Code = 'if ($l -match ''^(\w+)=(.*)$'') { $k = $Matches[1]; if ($k -match ''KEY'') { 1 } }' }
    @{ Rule = 'MATCHES'; Fire = $false; Code = 'if ($a -match ''x'' -and $b -match ''y'') { 1 }' }
    @{ Rule = 'BOUND'; Fire = $true; Code = 'Invoke-Stage ''Prep'' { if ($PSBoundParameters.ContainsKey(''X'')) { 1 } }' }
    @{ Rule = 'BOUND'; Fire = $true; Code = '$b = { $PSBoundParameters.Count }; & $b' }
    @{ Rule = 'BOUND'; Fire = $false; Code = 'function F { param($X) $PSBoundParameters.ContainsKey(''X'') }' }
    @{ Rule = 'BOUND'; Fire = $false; Code = 'function F { param($X) $PSBoundParameters.Keys | ForEach-Object { $PSBoundParameters[$_] } }' }
    @{ Rule = 'HELP'; Fire = $true; UserFacing = $true; Code = "<#`n.SYNOPSIS`n  x`n#>`nparam(`n  [switch]`$Force`n)" }
    @{ Rule = 'NETCATCH'; Fire = $true; Code = 'try { $r = $c.SendAsync($q).GetAwaiter().GetResult() } finally { $c.Dispose() }' }
    @{ Rule = 'NETCATCH'; Fire = $true; Code = '$r = $c.SendAsync($q).GetAwaiter().GetResult()' }
    @{ Rule = 'NETCATCH'; Fire = $false; Code = 'try { $r = $c.SendAsync($q).GetAwaiter().GetResult() } catch { throw ''x'' } finally { $c.Dispose() }' }
    @{ Rule = 'ENVRESTORE'; Fire = $true; Code = 'foreach ($n in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($n, $saved[$n], ''Process'') }' }
    @{ Rule = 'ENVRESTORE'; Fire = $true; Code = '[Environment]::SetEnvironmentVariable($k, $before[$k])' }
    @{ Rule = 'ENVRESTORE'; Fire = $false; Code = '[Environment]::SetEnvironmentVariable(''OLLAMA_HOST'', $v, ''User'')' }
    @{ Rule = 'ENVRESTORE'; Fire = $false; Code = 'Set-LaiProcessEnv -Name $n -Value $saved[$n]' }
    @{ Rule = 'HELP'; Fire = $false; UserFacing = $true; Code = "<#`n.SYNOPSIS`n  x`n.PARAMETER Force`n  y`n#>`nparam(`n  [switch]`$Force`n)" }
    @{ Rule = 'HELP'; Fire = $false; UserFacing = $true; Code = "<#`n.SYNOPSIS`n  x`n#>`nparam(`n  # skip the prompt`n  [switch]`$Force`n)" }
    @{ Rule = 'HELP'; Fire = $false; UserFacing = $true; Code = "<#`n.SYNOPSIS`n  x`n.DESCRIPTION`n  -Force skips the prompt.`n#>`nparam(`n  [switch]`$Force`n)" }
    @{ Rule = 'HELP'; Fire = $false; Code = "<#`n.SYNOPSIS`n  x`n#>`nparam(`n  [switch]`$Force`n)" }
    @{ Rule = 'NATIVEQUOTE'; Fire = $true; Code = '$l = Invoke-Native -File ''docker'' -Arguments @(''ps'', ''--format'', ''{{.ID}}|{{.Label "com.docker.compose.project"}}'') -Capture' }
    @{ Rule = 'NATIVEQUOTE'; Fire = $true; Code = '& docker inspect -f ''{{index .Labels "x"}}'' c' }
    @{ Rule = 'NATIVEQUOTE'; Fire = $false; Code = '$l = Invoke-Native -File ''docker'' -Arguments @(''ps'', ''--format'', ''{{.Label `x`}}'') -Capture' }
    @{ Rule = 'NATIVEQUOTE'; Fire = $false; Code = 'Write-Host ''say "hi"''' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Watch-LocalAI.ps1'; Code = '$s = & docker inspect -f ''{{.State.Status}}'' $Name 2>$null' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Watch-LocalAI.ps1'; Code = '& docker version --format ''{{.Server.Version}}'' 2>$null | Out-Null' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Backup-OpenWebUI.ps1'; Code = 'while ((Invoke-Docker -Arguments @(''version'', ''--format'', ''{{.Server.Version}}'') -AllowFail).ExitCode -ne 0) { Start-Sleep 10 }' }
    @{ Rule = 'HANG'; Fire = $false; File = 'Watch-LocalAI.ps1'; Code = '$engine = Test-LaiDockerEngine -TimeoutSec $dockerLimit' }
    @{ Rule = 'HANG'; Fire = $false; File = 'Backup-OpenWebUI.ps1'; Code = 'Invoke-Docker -Arguments @(''volume'', ''inspect'', $Volume) -AllowFail' }
    @{ Rule = 'HANG'; Fire = $false; File = 'Update-OpenWebUI.ps1'; Code = '& docker version' }
    # The four scripts the owner runs when something is wrong: no direct docker call, and no engine
    # probe through their own Invoke-Docker.
    @{ Rule = 'HANG'; Fire = $true; File = 'Start-LocalAI.ps1'; Code = '& docker version --format ''{{.Server.Version}}'' 2>$null | Out-Null' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Start-LocalAI.ps1'; Code = '$s = & docker inspect -f ''{{.State.Status}}'' $Name 2>$null' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Start-LocalAI.ps1'; Code = '$r = Invoke-Docker @(''version'', ''--format'', ''{{.Server.Version}}'')' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Stop-LocalAI.ps1'; Code = '& docker version --format ''{{.Server.Version}}'' 2>$null | Out-Null' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Stop-LocalAI.ps1'; Code = '$s = & docker inspect -f ''{{.State.Status}}'' $Name 2>$null' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Stop-LocalAI.ps1'; Code = '$r = Invoke-Docker @(''version'', ''--format'', ''{{.Server.Version}}'') -TimeoutSec $slowLimit' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Test-LocalAI.ps1'; Code = '& docker version --format ''{{.Server.Version}}'' 2>$null | Out-Null' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Test-LocalAI.ps1'; Code = '$s = & docker inspect -f ''{{.State.Status}}'' $Name 2>$null' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Get-LocalAIDiagnostics.ps1'; Code = '& docker version --format ''{{.Server.Version}}'' 2>$null | Out-Null' }
    @{ Rule = 'HANG'; Fire = $true; File = 'Get-LocalAIDiagnostics.ps1'; Code = '$s = & docker.exe inspect -f ''{{.State.Status}}'' $Name 2>$null' }
    @{ Rule = 'HANG'; Fire = $false; File = 'Start-LocalAI.ps1'; Code = '$engine = Test-LaiDockerEngine -TimeoutSec $dockerLimit' }
    @{ Rule = 'HANG'; Fire = $false; File = 'Stop-LocalAI.ps1'; Code = '$r = Invoke-Docker @(''compose'', ''--project-directory'', $stackDir, ''-f'', $compose, ''stop'') -TimeoutSec $slowLimit' }
    # The two timed calls that carry the word 'version', as they stand in the scripts: not this rule's.
    @{ Rule = 'HANG'; Fire = $false; File = 'Test-LocalAI.ps1'; Code = '$r = Invoke-LaiTimedNative -File ''docker'' -Arguments @(''version'', ''--format'', ''{{.Server.Version}}'') -TimeoutSec $dockerLimit' }
    @{ Rule = 'HANG'; Fire = $false; File = 'Get-LocalAIDiagnostics.ps1'; Code = '$dockerVer = Invoke-Capture ''docker'' @(''version'', ''--format'', ''{{.Server.Version}}'')' }
    @{ Rule = 'HIDDENTASK'; Fire = $true; Code = '$a = New-ScheduledTaskAction -Execute ''powershell.exe'' -Argument $x' }
    @{ Rule = 'HIDDENTASK'; Fire = $false; Code = '$a = New-ScheduledTaskAction -Execute $l.Execute -Argument $l.Argument' }
    @{ Rule = 'HIDDENTASK'; Fire = $false; Code = '$a = New-ScheduledTaskAction -Execute ''powershell.exe'' -Argument $x   # lai-ok: window' }
    @{ Rule = 'ENVFIRST'; Fire = $true; File = 'Update-OpenWebUI.ps1'; Code = "Set-EnvVersion -OpenWebUI `$v`ntry { Invoke-Docker -Arguments (`$base + @('pull', '--policy', 'missing')) } catch { throw }" }
    @{ Rule = 'ENVFIRST'; Fire = $false; File = 'Update-OpenWebUI.ps1'; Code = "Invoke-PullFirst -OpenWebUI `$v`nSet-EnvVersion -OpenWebUI `$v`nInvoke-Docker -Arguments (`$base + @('up', '-d'))" }
    @{ Rule = 'ENVFIRST'; Fire = $false; File = 'Update-OpenWebUI.ps1'; Code = "function Invoke-PullFirst { Invoke-Docker -Arguments @('pull') }`nInvoke-PullFirst`nSet-EnvVersion -OpenWebUI `$v" }
    @{ Rule = 'OLLAMAAPP'; Fire = $true; Code = "`$app = Join-Path `$env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'`nif (Test-Path -LiteralPath `$app) { Start-Process -FilePath `$app }" }
    @{ Rule = 'OLLAMAAPP'; Fire = $true; Code = 'Start-AsUser (Join-Path $OllamaDir ''ollama app.exe'')' }
    @{ Rule = 'OLLAMAAPP'; Fire = $true; Code = 'Start-Process -FilePath (Join-Path $OllamaDir ''ollama app.exe'')' }
    @{ Rule = 'OLLAMAAPP'; Fire = $false; Code = 'Start-Process -FilePath (Join-Path $OllamaDir ''ollama app.exe'') -ArgumentList ''hidden''' }
    @{ Rule = 'OLLAMAAPP'; Fire = $false; Code = "`$app = Get-LaiOllamaAppPath`nStart-LaiOllamaApp -Path `$app" }
    @{ Rule = 'OLLAMAAPP'; Fire = $false; Code = 'Start-AsUser (Join-Path $OllamaDir ''ollama app.exe'')  # lai-ok: hidden' }
    @{ Rule = 'OLLAMAAPP'; Fire = $true; Code = "`$lnk = ''`nif (`$env:APPDATA) { `$lnk = Join-Path `$env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk' }`nif (`$lnk -and (Test-Path -LiteralPath `$lnk)) { Start-AsUser `$lnk }" }
    @{ Rule = 'OLLAMAAPP'; Fire = $true; Code = 'Invoke-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk"' }
    @{ Rule = 'OLLAMAAPP'; Fire = $false; Code = "`$lnk = Join-Path `$env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk'`nif (Test-Path -LiteralPath `$lnk) { Remove-Item -LiteralPath `$lnk }" }
    @{ Rule = 'SERVERLOG'; Fire = $true; Code = '$ok = ($cfgLine.Line -match ''OLLAMA_FLASH_ATTENTION:true'') -and ($cfgLine.Line -match "OLLAMA_KV_CACHE_TYPE:$KvCacheType")' }
    @{ Rule = 'SERVERLOG'; Fire = $false; Code = '$chk = Test-LaiOllamaServerSettings -Line $cfgLine.Line -KvCacheType $KvCacheType' }
    @{ Rule = 'SERVERLOG'; Fire = $false; Code = '$ok = $svc -match ''LDR_LLM_OLLAMA_URL: http://render-guard:11434''' }
    @{ Rule = 'SERVERLOG'; Fire = $false; Code = 'if ($line -match ''msg="server config"'') { 1 }' }
    @{ Rule = 'HELP'; Fire = $true; UserFacing = $true; Code = "#Requires -Version 5.1`n<#`n.SYNOPSIS`n  x`n#>`nparam(`n  # y`n  [switch]`$Force`n)" }
    @{ Rule = 'HELP'; Fire = $false; UserFacing = $true; Code = "#Requires -Version 5.1`n`n<#`n.SYNOPSIS`n  x`n#>`nparam(`n  # y`n  [switch]`$Force`n)" }
    @{ Rule = 'LOCATOR'; Fire = $true; UserFacing = $true; Code = '$app = Join-Path $env:LOCALAPPDATA ''Programs\Ollama\ollama app.exe''' }
    @{ Rule = 'LOCATOR'; Fire = $true; UserFacing = $true; Code = '$exe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"' }
    @{ Rule = 'LOCATOR'; Fire = $false; UserFacing = $true; Code = '$app = Join-Path (Find-LaiOllamaDir -OrDefault) ''ollama app.exe''' }
    @{ Rule = 'LOCATOR'; Fire = $false; Code = '$d = Join-Path $LocalAppData ''Programs\Ollama''' }
)
$canaryFail = 0
$docCanaries = @(
    @{ Fire = $true; Text = 'Run `Update-OpenWebUI.ps1 -Latests` to update.' }
    @{ Fire = $true; Text = '    .\Install-LocalAI.cmd -RenderGuard off -NoSuchSwitch' }
    @{ Fire = $false; Text = 'Run `Update-OpenWebUI.ps1 -Latest` or `Install-LocalAI.cmd -RenderGuard off` (or -Foo outside the span).' }
    @{ Fire = $false; Text = '.\Uninstall-LocalAI.ps1 -WhatIf   # -NotAParam in a comment' }
    @{ Fire = $false; Text = 'Use Uninstall-LocalAI.ps1 -Force and then Update-OpenWebUI.ps1 -Latest by hand.' }
    @{ Fire = $true; Text = 'Use Uninstall-LocalAI.ps1 -Force and then Update-OpenWebUI.ps1 -Lates by hand.' }
    @{ Fire = $true; Text = 'roll it back (Update-Models.ps1 -Rollback, Update-OpenWebUI.ps1 -Rollback)' }
    @{ Fire = $true; Text = 'run `Update-Models.ps1 -Rollback`' }
    @{ Fire = $true; Text = 'Update-Models.ps1 -Rollback -WhatIf' }
    @{ Fire = $false; Text = 'roll it back (Update-Models.ps1 -Rollback $($m.Key) or Update-OpenWebUI.ps1 -Rollback)' }
    @{ Fire = $false; Text = '.\Update-Models.ps1 -Rollback main     # go back' }
    @{ Fire = $false; Text = 'Update-Models.ps1 -Rollback:all' }
)
$composeCanaries = @(
    @{ Fire = $true; Text = "services:`n  a:`n    image: x`n    logging: *l`n  b:`n    image: y`nvolumes:`n  v:" }
    @{ Fire = $false; Text = "services:`n  a:`n    image: x`n    logging: *l`nvolumes:`n  v:" }
    @{ Fire = $true; Text = "services:`n  a:`n    logging: *l`n# a comment at column 0`n  b:`n    image: y" }
    @{ Fire = $true; Text = "services:`n    a:`n        image: x`n    b:`n        logging: *l" }
    @{ Fire = $true; Text = "services:`n  a:   # first`n    image: x`n  b:`n    logging: *l" }
    @{ Fire = $false; Text = "services:`n  a:`n    <<: *common`n  b:   # second`n    logging: *l" })
# COMPOSESEC: one hardened service, then the same service with one thing taken away, weakened or
# written another way. A canary that fires must report exactly the gap it names (Says) and no
# other (Gaps, 1 unless given): a rule that fires for the wrong reason proves nothing.
$secPort = '      - "127.0.0.1:${P:-3000}:8080"'
$secOk = @('services:', '  a:', '    image: x', '    ports:', $secPort, '    cap_drop: [ALL]', '    security_opt: ["no-new-privileges:true"]', '    mem_limit: 2g', '    pids_limit: 512') -join "`n"
$composeSecCanaries = @(
    @{ Fire = $false; Text = $secOk }
    @{ Fire = $true; Says = 'no-new-privileges'; Text = $secOk.Replace('    security_opt: ["no-new-privileges:true"]', '    restart: always') }
    @{ Fire = $true; Says = 'no-new-privileges'; Text = $secOk.Replace('privileges:true', 'privileges:false') }
    @{ Fire = $true; Gaps = 2; Says = 'has no ALL under cap_drop.* has ALL under cap_add'; Text = $secOk.Replace('cap_drop: [ALL]', 'cap_add: [ALL]') }
    @{ Fire = $true; Says = 'cap_drop'; Text = $secOk.Replace('[ALL]', '[NET_RAW]') }
    # What hands everything back while the four keys are all still there.
    @{ Fire = $true; Says = 'has ALL under cap_add'; Text = ($secOk + "`n    cap_add: [ALL]") }
    @{ Fire = $true; Says = 'has ALL under cap_add'; Text = ($secOk + "`n    cap_add:`n      - CHOWN`n      - all   # every one") }
    @{ Fire = $true; Says = "has 'privileged: true'"; Text = ($secOk + "`n    privileged: true") }
    @{ Fire = $true; Says = "has 'privileged: yes'"; Text = $secOk.Replace('    image: x', "    image: x`n    privileged: 'yes'   # for a test") }
    @{ Fire = $false; Text = ($secOk + "`n    privileged: false") }
    @{ Fire = $true; Says = "takes keys from a '<<' merge"; Text = ($secOk + "`n    <<: *wide") }
    @{ Fire = $true; Says = "takes keys from a '<<' merge"; Text = $secOk.Replace('    image: x', "    <<: [*wide, *open]`n    image: x") }
    @{ Fire = $false; Text = ($secOk + "`n    environment:`n      <<: *env`n      A: b") }
    @{ Fire = $true; Says = "another service with 'extends'"; Text = ($secOk + "`n    extends:`n      file: other.yml`n      service: wide") }
    @{ Fire = $true; Says = "another service with 'extends'"; Text = ($secOk + "`n    extends: { file: other.yml, service: wide }") }
    @{ Fire = $false; Text = ($secOk + "`n    environment:`n      extends: x") }
    # A line the key pattern cannot read could be one of the keys above written another way.
    @{ Fire = $true; Says = 'cannot read'; Text = ($secOk + "`n" + '    "privileged": true') }
    @{ Fire = $true; Says = 'cannot read'; Text = ($secOk + "`n    privileged : true") }
    @{ Fire = $true; Says = 'mem_limit'; Text = $secOk.Replace('    mem_limit: 2g', '    # mem_limit: 2g') }
    @{ Fire = $true; Says = 'mem_limit'; Text = $secOk.Replace('mem_limit: 2g', 'mem_limit: 0') }
    @{ Fire = $true; Says = 'pids_limit'; Text = $secOk.Replace('    pids_limit: 512', "    environment:`n      pids_limit: 512") }
    @{ Fire = $true; Says = 'pids_limit'; Text = $secOk.Replace('pids_limit: 512', 'pids_limit: -1') }
    @{ Fire = $true; Says = 'not bound to 127'; Text = $secOk.Replace('127.0.0.1:', '') }
    @{ Fire = $true; Says = 'not bound to 127'; Text = $secOk.Replace('127.0.0.1:', '0.0.0.0:') }
    @{ Fire = $true; Says = 'not bound to 127'; Text = $secOk.Replace($secPort, "    - 8080`n    - '127.0.0.1:3000:8080'") }
    @{ Fire = $true; Says = 'not bound to 127'; Text = $secOk.Replace($secPort, "      - target: 8080`n        published: 3000") }
    @{ Fire = $false; Text = $secOk.Replace($secPort, "      - target: 8080`n        published: 3000`n        host_ip: 127.0.0.1") }
    @{ Fire = $false; Text = $secOk.Replace("    ports:`n$secPort`n", '') }
    @{ Fire = $false; Text = $secOk.Replace('cap_drop: [ALL]', "cap_drop:`n    - ALL   # every one`n    cap_add: [CHOWN]").Replace('security_opt: ["no-new-privileges:true"]', "security_opt:`n      - 'no-new-privileges:true'").Replace('mem_limit: 2g', 'mem_limit: "512m"   # enough') }
    @{ Fire = $true; Gaps = 3; Says = "service 'b' has no mem_limit"; Text = ($secOk + "`n  b:`n    image: y`n    cap_drop: [ALL]`nvolumes:`n  mem_limit: 2g") }
    @{ Fire = $true; Gaps = 4; Says = "service 'a' has no ALL under cap_drop"; Text = "services:`n  a: { image: x, cap_drop: [ALL] }" }
    @{ Fire = $true; Says = 'no service found'; Text = "volumes:`n  v:" })
$mdCanaries = @(
    @{ Fire = $true; Text = "| A | B |`n|---|---|`n| a1 | b1 || a2 | b2 |" }
    @{ Fire = $true; Text = "| A | B |`n|---|---|`n| a1 | b1 | | a2 | b2 |" }
    @{ Fire = $false; Text = "| A | B |`n|---|---|`n| a1 | b1 |`n| a2 | b2 |" }
    @{ Fire = $false; Text = "| A | B |`n|---|---|`n| ``a || b`` | x \| y |`n`ntext`n`n| C |`n|---|`n| c |" })
# TESTHOOK: Code is the script 'Canary.ps1', judged with the pinned list Pins (none unless given).
# A canary that fires must say what it found (Says) in exactly one sentence (Gaps, when more): the
# forms of a read first, then the parameter, then the pinned list, then what must stay quiet.
$testHookCanaries = @(
    @{ Fire = $true; Says = '^Canary\.ps1:1 test variable LOCALAI_TEST_X is read from the environment \(\$env:LOCALAI_TEST_X\).* use a stand-in the test puts on PATH, a real parameter, or a -Test parameter the run announces$'; Code = 'if ($env:LOCALAI_TEST_X) { throw ''Test hook: stage failed'' }' }
    # Read twice on one line, as the scripts do: one sentence.
    @{ Fire = $true; Says = '^Canary\.ps1:1 test variable LOCALAI_DOCKER_TIMEOUT is read'; Code = '$s = 30; if ($env:LOCALAI_DOCKER_TIMEOUT) { $s = [int]$env:LOCALAI_DOCKER_TIMEOUT }' }
    @{ Fire = $true; Says = '^Canary\.ps1:1 test variable LOCALAI_TS_TIMEOUT is read'; Code = '$limit = 30; if ($env:LOCALAI_TS_TIMEOUT) { $limit = [int]$env:LOCALAI_TS_TIMEOUT }' }
    @{ Fire = $true; Says = '^Canary\.ps1:1 test variable LOCALAI_TEST_X is read'; Code = '$x = $env:LOCALAI_TEST_X' }
    @{ Fire = $true; Says = '^Canary\.ps1:2 test variable LOCALAI_TEST_X is read'; Code = "`$a = 1`n`$b = `$env:LOCALAI_TEST_X" }
    # Read and set on one line (Restore-OpenWebUI.ps1's hook that fails once): the read counts, once.
    @{ Fire = $true; Says = '^Canary\.ps1:1 test variable LOCALAI_TEST_X is read'; Code = 'if ($env:LOCALAI_TEST_X) { $env:LOCALAI_TEST_X = ''''; throw ''Test hook: first swap failed'' }' }
    @{ Fire = $true; Says = '^Canary\.ps1:1 test variable LOCALAI_TEST_X is read'; Code = '$env:LOCALAI_TEST_X += ''a''' }
    @{ Fire = $true; Says = 'test variable LOCALAI_TEST_CATALOG is read'; Code = 'Write-Host "catalog: $env:LOCALAI_TEST_CATALOG"' }
    @{ Fire = $true; Says = 'test variable localai_test_x is read'; Code = '$x = $env:localai_test_x' }
    @{ Fire = $true; Says = 'test variable LOCALAI_TEST_X is read from the environment \(GetEnvironmentVariable\(''LOCALAI_TEST_X''\)\)'; Code = '$v = [Environment]::GetEnvironmentVariable(''LOCALAI_TEST_X'')' }
    @{ Fire = $true; Says = 'test variable LOCALAI_TS_TIMEOUT is read from the environment \(GetEnvironmentVariable\(''LOCALAI_TS_TIMEOUT''\)\)'; Code = '$v = [System.Environment]::GetEnvironmentVariable("LOCALAI_TS_TIMEOUT", ''User'')' }
    @{ Fire = $true; Says = 'test variable LOCALAI_TEST_X is read from the environment \(Get-Item Env:LOCALAI_TEST_X\)'; Code = '$i = Get-Item Env:LOCALAI_TEST_X' }
    @{ Fire = $true; Says = 'test variable LOCALAI_TEST_X is read from the environment \(Get-Content Env:LOCALAI_TEST_X\)'; Code = '$t = Get-Content Env:LOCALAI_TEST_X' }
    @{ Fire = $true; Says = 'test variable LOCALAI_TEST_X is read from the environment \(Get-ChildItem Env:LOCALAI_TEST_X\)'; Code = '$all = Get-ChildItem Env:LOCALAI_TEST_X' }
    @{ Fire = $true; Says = 'test variable LOCALAI_TEST_X is read from the environment \(Test-Path Env:LOCALAI_TEST_X\)'; Code = 'if (Test-Path Env:LOCALAI_TEST_X) { 1 }' }
    @{ Fire = $true; Says = '\(Get-Item Env:LOCALAI_DOCKER_TIMEOUT\)'; Code = '$i = Get-Item -LiteralPath ''Env:\LOCALAI_DOCKER_TIMEOUT'' -ErrorAction SilentlyContinue' }
    @{ Fire = $true; Says = '\(Test-Path Env:LOCALAI_TEST_X\)'; Code = '$both = Test-Path Env:OLLAMA_HOST, Env:/LOCALAI_TEST_X' }
    @{ Fire = $true; Says = 'test variable LOCALAI_TEST_\* is read from the environment \(gci Env:LOCALAI_TEST_\*\)'; Code = 'foreach ($i in (gci Env:LOCALAI_TEST_*)) { $i.Value }' }
    @{ Fire = $true; Says = '^Canary\.ps1:3 test parameter -TestX is not on the pinned list: use a stand-in the test puts on PATH or a real parameter'; Code = "param(`n    [int]`$Port = 3000,`n    [switch]`$TestX`n)`n`$hook = [bool]`$TestX" }
    # The pinned list: an entry is one file and one name, written out; one that allows nothing is a problem.
    @{ Fire = $true; Gaps = 2; Says = '^Canary\.ps1:1 test variable LOCALAI_TEST_X is read.* \| pinned entry ''Other\.ps1 env LOCALAI_TEST_X'' matches nothing any more'; Pins = @('Other.ps1 env LOCALAI_TEST_X'); Code = '$x = $env:LOCALAI_TEST_X' }
    @{ Fire = $true; Gaps = 2; Says = '^Canary\.ps1:1 test variable LOCALAI_TEST_Y is read.* \| pinned entry ''Canary\.ps1 env LOCALAI_TEST_X'' matches nothing any more'; Pins = @('Canary.ps1 env LOCALAI_TEST_X'); Code = '$y = $env:LOCALAI_TEST_Y' }
    @{ Fire = $true; Gaps = 2; Says = '^Canary\.ps1:1 test variable LOCALAI_TEST_X is read.* \| pinned entry ''Canary\.ps1 env LOCALAI_TEST_\*'' matches nothing any more'; Pins = @('Canary.ps1 env LOCALAI_TEST_*'); Code = '$x = $env:LOCALAI_TEST_X' }
    # A stale entry is to go only when its read is gone, and the sentence says so: one whose read
    # only moved out of this rule's sight would lose its last trace, and the build would be green.
    @{ Fire = $true; Says = '^pinned entry ''Canary\.ps1 env LOCALAI_TEST_X'' matches nothing any more: if neither Canary\.ps1 nor anything it calls reads LOCALAI_TEST_X any more, take the entry out of \$testHookPins in tests/Invoke-StaticChecks\.ps1 \(the list only shrinks\); if the read only moved \(.*\), it is a new hook this rule cannot see, not a removed one, and the entry is its last trace$'; Pins = @('Canary.ps1 env LOCALAI_TEST_X'); Code = '$a = 1' }
    @{ Fire = $true; Says = '^pinned entry ''Canary\.ps1 param TestX'' matches nothing any more: if Canary\.ps1 has that parameter under no other name either, take the entry out of \$testHookPins .*the list only shrinks.* a test parameter that only got a name that does not begin Test is a new hook this rule cannot see, not a removed one$'; Pins = @('Canary.ps1 env LOCALAI_TEST_X', 'Canary.ps1 param TestX'); Code = "param([switch]`$Force)`n`$x = `$env:LOCALAI_TEST_X" }
    # The read that moved leaves a string with the name, or with the start of it: then the sentence
    # names that place, in whatever script it is (the entry is Update.ps1's, the helper the
    # library's), and does not ask for the entry to go. A helper that puts the name together, code
    # held as text for another PowerShell, a name kept in a variable, a path put together in a
    # string and a look in the table of all variables, text over several lines.
    @{ Fire = $true; Says = '^pinned entry ''Update\.ps1 env LOCALAI_TEST_CATALOG'' matches nothing any more, but lib/Canary\.psm1:2 still holds ''LOCALAI_TEST_'' in a string: a read that only moved \(.*\) is a new hook this rule cannot see, not a removed one; take the entry out of \$testHookPins in tests/Invoke-StaticChecks\.ps1 only when nothing there reads LOCALAI_TEST_CATALOG$'; Pins = @('Update.ps1 env LOCALAI_TEST_CATALOG'); File = 'lib/Canary.psm1'; Code = "function Get-LaiTestHook([string]`$Name) {`n    return [Environment]::GetEnvironmentVariable('LOCALAI_TEST_' + `$Name)`n}" }
    @{ Fire = $true; Says = '^pinned entry ''Canary\.ps1 env LOCALAI_TEST_X'' matches nothing any more, but Canary\.ps1:1 still holds ''LOCALAI_TEST_X'' in a string: '; Pins = @('Canary.ps1 env LOCALAI_TEST_X'); Code = '$cmd = ''if ($env:LOCALAI_TEST_X) { exit 3 }''; & powershell.exe -NoProfile -Command $cmd' }
    @{ Fire = $true; Says = ' matches nothing any more, but Canary\.ps1:1 still holds ''LOCALAI_TS_TIMEOUT'' in a string: '; Pins = @('Canary.ps1 env LOCALAI_TS_TIMEOUT'); Code = '$n = ''LOCALAI_TS_TIMEOUT''; $v = [Environment]::GetEnvironmentVariable($n)' }
    @{ Fire = $true; Says = ' matches nothing any more, but Canary\.ps1:2 still holds ''LOCALAI_TEST_FAIL_'' in a string \(and 1 more outside tests\): .* only when nothing there reads LOCALAI_TEST_FAIL_SWAP$'; Pins = @('Canary.ps1 env LOCALAI_TEST_FAIL_SWAP'); Code = "`$a = 1`n`$v = (Get-Item `"Env:LOCALAI_TEST_FAIL_`$what`").Value; `$all = [Environment]::GetEnvironmentVariables()['LOCALAI_TEST_FAIL_SWAP']" }
    @{ Fire = $true; Says = ' matches nothing any more, but Canary\.ps1:4 still holds ''LOCALAI_DOCKER_TIMEOUT'' in a string: '; Pins = @('Canary.ps1 env LOCALAI_DOCKER_TIMEOUT'); Code = "`$a = 1`n`$cmd = @'`nWrite-Host started`nif (`$env:LOCALAI_DOCKER_TIMEOUT) { exit 3 }`n'@" }
    # No such string, no such claim. The pinned reads of the name in another script are reads, not
    # strings (one of them inside a string); another variable's name is not the start of this one;
    # a comment is not looked at.
    @{ Fire = $true; Says = '^pinned entry ''Other\.ps1 env LOCALAI_TEST_X'' matches nothing any more: if neither Other\.ps1 nor anything it calls reads LOCALAI_TEST_X any more, take the entry out '; Pins = @('Canary.ps1 env LOCALAI_TEST_X', 'Other.ps1 env LOCALAI_TEST_X'); Code = 'Write-Host "catalog: $env:LOCALAI_TEST_X"; $v = [Environment]::GetEnvironmentVariable(''LOCALAI_TEST_X''); $i = Get-Item Env:LOCALAI_TEST_X' }
    @{ Fire = $true; Says = '^pinned entry ''Canary\.ps1 env LOCALAI_TEST_CATALOG'' matches nothing any more: if neither '; Pins = @('Canary.ps1 env LOCALAI_TEST_CATALOG'); Code = 'Write-Host ''LOCALAI_TEST_OTHER is set''; $s = ''LOCALAI_TEST_CATALOG_DIR''' }
    @{ Fire = $true; Says = '^pinned entry ''Canary\.ps1 env LOCALAI_TS_TIMEOUT'' matches nothing any more: if neither '; Pins = @('Canary.ps1 env LOCALAI_TS_TIMEOUT'); Code = "# LOCALAI_TS_TIMEOUT is read no more.`n`$a = 'LOCALAI_TS_TIMEOUT_SEC'; `$b = 'MY_LOCALAI_TS_TIMEOUT'; `$c = 'LOCALAI_TESTING'" }
    # Such a string cannot be pinned: an entry is a read or a parameter.
    @{ Fire = $true; Says = '^pinned entry ''Canary\.ps1 text LOCALAI_TEST_'' matches nothing any more: an entry is ''<file> env <name>'' or ''<file> param <name>'', nothing else; take it out of \$testHookPins '; Pins = @('Canary.ps1 text LOCALAI_TEST_'); Code = '$n = ''LOCALAI_TEST_'' + $what' }
    # And it is no problem by itself: the entry here still has its read.
    @{ Fire = $false; Pins = @('Canary.ps1 env LOCALAI_TEST_X'); Code = 'if ($env:LOCALAI_TEST_X) { $n = ''LOCALAI_TEST_X''; Write-Host "LOCALAI_TEST_$n" }' }
    @{ Fire = $false; Pins = @('Canary.ps1 env LOCALAI_TEST_X'); Code = 'if ($env:LOCALAI_TEST_X) { $p = $env:LOCALAI_TEST_X }' }
    @{ Fire = $false; Pins = @('lib/Canary.psm1 env LOCALAI_DOCKER_TIMEOUT'); File = 'lib/Canary.psm1'; Code = 'if ($env:LOCALAI_DOCKER_TIMEOUT) { 1 }' }
    @{ Fire = $false; Pins = @('Canary.ps1 param TestX'); Code = "param(`n    [switch]`$TestX`n)`n`$hook = [bool]`$TestX" }
    # The owner's own options of Get-LocalAI.ps1, as it reads them.
    @{ Fire = $false; Code = '$ref = $env:LOCALAI_REF' }
    @{ Fire = $false; Code = '$root = $env:LOCALAI_ROOT' }
    @{ Fire = $false; Code = 'if ($env:LOCALAI_ARGS) { $extra = @($env:LOCALAI_ARGS -split ''\s+'' | Where-Object { $_ }) }' }
    @{ Fire = $false; Code = '$review = Get-UpdateReview -Ref $ref -ReviewedCommit $env:LOCALAI_REVIEWED_COMMIT' }
    # Setting is not reading.
    @{ Fire = $false; Code = '$env:LOCALAI_TEST_X = ''''' }
    @{ Fire = $false; Code = '[string]$env:LOCALAI_TEST_X = 1' }
    @{ Fire = $false; Code = '[Environment]::SetEnvironmentVariable(''LOCALAI_TEST_X'', ''1'', ''Process'')' }
    @{ Fire = $false; Code = 'Set-Item Env:LOCALAI_TEST_X 1; Remove-Item Env:LOCALAI_TEST_X' }
    # A function's own parameter, a name that only looks like one, a variable that is not the environment's.
    @{ Fire = $false; Code = 'function Test-Known { param([string]$Version, [string]$Tested = ''0.11.4'') return ([version]$Version -le [version]$Tested) }' }
    @{ Fire = $false; Code = '$a = $env:LOCALAI_TESTING; $b = $env:MY_LOCALAI_TEST_X; $c = $env:LOCALAI_TS_TIMEOUT_SEC; $d = $script:LOCALAI_TEST_X; $e = $LOCALAI_DOCKER_TIMEOUT' }
    # Comments and messages name the variables; the commands read other things.
    @{ Fire = $false; Code = "# LOCALAI_DOCKER_TIMEOUT: test hook.`nWrite-Host 'Not wanted? First `$env:LOCALAI_TEST_X = 1, or set LOCALAI_TS_TIMEOUT.'" }
    @{ Fire = $false; Code = 'if (Test-Path -LiteralPath $p) { $t = Get-Content -LiteralPath $p -Encoding UTF8 }; $r = Get-Item Env:LOCALAI_ROOT; $n = @(Get-ChildItem Env:).Count' }
    # A name that is not written out is not seen (the header says so); it must not stop the check either.
    @{ Fire = $false; Code = 'foreach ($n in @(''OPEN_WEBUI_VERSION'', ''SEARXNG_VERSION'')) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, ''Process'') }' })
foreach ($k in $mdCanaries) {
    if (((Find-MdTableGap $k.Text).Count -gt 0) -ne $k.Fire) {
        $canaryFail++; $problems++
        Write-Host ("CANARY   rule MDTABLE {0} on: {1}" -f $(if ($k.Fire) { 'did not fire' } else { 'fired wrongly' }), ($k.Text -replace "`n", ' / ')) -ForegroundColor Red
    }
}
foreach ($k in $composeCanaries) {
    if (((Find-ComposeLogGap $k.Text).Count -gt 0) -ne $k.Fire) {
        $canaryFail++; $problems++
        Write-Host ("CANARY   rule COMPOSELOG {0}" -f $(if ($k.Fire) { 'did not fire' } else { 'fired wrongly' })) -ForegroundColor Red
    }
}
foreach ($k in $composeSecCanaries) {
    $got = Find-ComposeSecGap $k.Text
    $want = 0; $says = ''
    if ($k.Fire) { $want = 1; $says = $k.Says; if ($k.ContainsKey('Gaps')) { $want = $k.Gaps } }
    if ($got.Count -ne $want -or ($says -and ($got -join ' | ') -notmatch $says)) {
        $canaryFail++; $problems++
        Write-Host ("CANARY   rule COMPOSESEC wanted {0} gap(s) [{1}], found {2} [{3}] on: {4}" -f $want, $says, $got.Count, ($got -join ' | '), ($k.Text -replace "`n", ' / ')) -ForegroundColor Red
    }
}
foreach ($k in $testHookCanaries) {
    $t = $null; $e = $null
    $cast = [System.Management.Automation.Language.Parser]::ParseInput($k.Code, [ref]$t, [ref]$e)
    $fn = 'Canary.ps1'; if ($k.ContainsKey('File')) { $fn = $k.File }
    $pins = @(); if ($k.ContainsKey('Pins')) { $pins = @($k.Pins) }
    $got = @(Find-TestHookProblem -Hits @(Find-TestHook -Ast $cast -File $fn) -Pins $pins)
    $want = 0; $says = ''
    if ($k.Fire) { $want = 1; $says = $k.Says; if ($k.ContainsKey('Gaps')) { $want = $k.Gaps } }
    # A snippet that does not parse proves nothing, whatever it finds.
    if (@($e).Count -or $got.Count -ne $want -or ($says -and ($got -join ' | ') -notmatch $says)) {
        $canaryFail++; $problems++
        Write-Host ("CANARY   rule TESTHOOK wanted {0} problem(s) [{1}], found {2} [{3}] on: {4}" -f $want, $says, $got.Count, ($got -join ' | '), ($k.Code -replace "`n", ' / ')) -ForegroundColor Red
    }
}
foreach ($k in $docCanaries) {
    $hit = (Find-DocParam -Text $k.Text -ParamsByScript @{ 'Update-OpenWebUI.ps1' = @('Latest', 'Rollback'); 'Install-LocalAI.ps1' = @('RenderGuard'); 'Uninstall-LocalAI.ps1' = @('Force'); 'Update-Models.ps1' = @('Rollback') } `
        -ValueParamsByScript @{ 'Install-LocalAI.ps1' = @('RenderGuard'); 'Update-Models.ps1' = @('Rollback') }).Count -gt 0
    if ($hit -ne $k.Fire) {
        $canaryFail++; $problems++
        Write-Host ("CANARY   rule DOCPARAM {0} on: {1}" -f $(if ($k.Fire) { 'did not fire' } else { 'fired wrongly' }), $k.Text) -ForegroundColor Red
    }
}
foreach ($k in $canaries) {
    $t = $null; $e = $null
    $cast = [System.Management.Automation.Language.Parser]::ParseInput($k.Code, [ref]$t, [ref]$e)
    $fn = ''; if ($k.ContainsKey('File')) { $fn = $k.File }
    $hit = @((Find-Pitfall -Ast $cast -Lines @($k.Code -split "`n") -FileName $fn -UserFacing:([bool]$k.UserFacing)) | Where-Object { $_.Rule -eq $k.Rule }).Count -gt 0
    if ($hit -ne $k.Fire) {
        $canaryFail++; $problems++
        Write-Host ("CANARY   rule {0} {1} on: {2}" -f $k.Rule, $(if ($k.Fire) { 'did not fire' } else { 'fired wrongly' }), $k.Code) -ForegroundColor Red
    }
}
$canaryCount = $canaries.Count + $docCanaries.Count + $composeCanaries.Count + $composeSecCanaries.Count + $mdCanaries.Count + $testHookCanaries.Count
Write-Host ("Pitfall-rule canaries: {0}/{1} OK" -f ($canaryCount - $canaryFail), $canaryCount) -ForegroundColor $(if ($canaryFail) { 'Red' } else { 'Green' })

foreach ($f in $files) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    foreach ($e in $errs) { $problems++; Write-Host "PARSE    $($f.Name):$($e.Extent.StartLineNumber) $($e.Message)" -ForegroundColor Red }

    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 127) {
            $line = ([System.Text.Encoding]::UTF8.GetString($bytes, 0, $i) -split "`n").Count
            $problems++; Write-Host "NONASCII $($f.Name):$line (PS 5.1 misreads BOM-less non-ASCII files)" -ForegroundColor Red
            break
        }
    }

    $userFacing = $f.DirectoryName -eq $root
    foreach ($p in (Find-Pitfall -Ast $ast -Lines @(Get-Content -LiteralPath $f.FullName) -FileName $f.Name -UserFacing:$userFacing)) {
        $problems++
        Write-Host ("{0,-8} {1}:{2} {3}" -f $p.Rule, $f.Name, $p.Line, $p.Message) -ForegroundColor Red
    }
}

# TESTHOOK: every script outside tests against the pinned list. All of them are read first and
# judged once: an entry is stale only when no script holds its read or parameter any more, and a
# stale one is held against the strings of all of them (a read may have moved into the library).
$testHookHits = @()
foreach ($f in ($files | Where-Object { $_.Extension -in '.ps1', '.psm1' })) {
    # The path below $Root with '/', on Windows as on Linux: the entries are written that way.
    $rel = $f.FullName.Substring($Root.Length).TrimStart([char]'/', [char]'\').Replace('\', '/')
    if ($rel -like 'tests/*') { continue }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    $testHookHits += @(Find-TestHook -Ast $ast -File $rel)
}
foreach ($msg in @(Find-TestHookProblem -Hits $testHookHits -Pins $testHookPins)) {
    $problems++
    Write-Host ('{0,-8} {1}' -f 'TESTHOOK', $msg) -ForegroundColor Red
}

# The README's commands against the scripts' real parameters.
$paramsByScript = @{}; $valueParamsByScript = @{}
foreach ($f in ($files | Where-Object { $_.DirectoryName -eq $Root -and $_.Extension -eq '.ps1' })) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    $paramsByScript[$f.Name] = @(if ($ast.ParamBlock) { $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } })
    $valueParamsByScript[$f.Name] = @(if ($ast.ParamBlock) { $ast.ParamBlock.Parameters | Where-Object { $_.StaticType -ne [switch] } | ForEach-Object { $_.Name.VariablePath.UserPath } })
}
$composeFile = Join-Path (Join-Path $Root 'stack') 'docker-compose.yml'
if (Test-Path -LiteralPath $composeFile) {
    $composeText = Get-Content -LiteralPath $composeFile -Raw -Encoding UTF8
    foreach ($svc in (Find-ComposeLogGap $composeText)) {
        $problems++; Write-Host "COMPOSELOG docker-compose.yml: service '$svc' has no logging limits (add 'logging: *logging')" -ForegroundColor Red
    }
    foreach ($gap in (Find-ComposeSecGap $composeText)) {
        $problems++; Write-Host "COMPOSESEC docker-compose.yml: $gap (see docs/CONTAINER-HARDENING-PLAN.md)" -ForegroundColor Red
    }
}

# Every rule prefix this script prints must be one the test runner counts as a failure.
$runnerText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-AllTests.ps1') -Raw -Encoding UTF8
$myRules = @([regex]::Matches((Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8), "(?m)^#   ([A-Z0-9]+) ") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
foreach ($rule in $myRules) {
    if ($runnerText -notmatch ('VerdictPattern = [^\r\n]*\b' + $rule + '\b')) { $problems++; Write-Host "CANARY   rule $rule is not in Invoke-AllTests.ps1's VerdictPattern" -ForegroundColor Red }
}

# The same check on the scripts' own messages ('Run Update-OpenWebUI.ps1 -Rollback'): a command a
# message tells the user to type must exist with those parameters.
foreach ($f in ($files | Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.DirectoryName -notlike '*tests*' })) {
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$er)
    $strings = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))
    # Comments too: the help's .EXAMPLE lines are commands users copy.
    $texts = @($strings | ForEach-Object { [pscustomobject]@{ Text = [string]$_.Value; Line = $_.Extent.StartLineNumber } }) +
        @($tk | Where-Object { $_.Kind -eq 'Comment' } | ForEach-Object { [pscustomobject]@{ Text = $_.Text; Line = $_.Extent.StartLineNumber } })
    foreach ($t in $texts) {
        foreach ($p in (Find-DocParam -Text $t.Text -ParamsByScript $paramsByScript -ValueParamsByScript $valueParamsByScript)) {
            $problems++
            Write-Host ("{0,-8} {1}:{2} names {3}" -f $p.Rule, $f.Name, ($t.Line + $p.Line - 1), $p.Message) -ForegroundColor Red
        }
    }
}

# Every OLLAMA_* user setting the installer writes is also undone by Uninstall -ResetOllamaSettings
# and shown by the diagnostics bundle (OLLAMA_MODELS is removed only with -RemoveModels).
$instFile = Join-Path $Root 'Install-LocalAI.ps1'
if (Test-Path -LiteralPath $instFile) {
    $ia = [System.Management.Automation.Language.Parser]::ParseFile($instFile, [ref]$null, [ref]$null)
    $setHt = $ia.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$settings' -and $n.Right.Extent.Text -match 'OLLAMA_' }, $true)
    $keys = @()
    if ($setHt) { $keys = @($setHt.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | ForEach-Object { $_.KeyValuePairs } | ForEach-Object { $_.Item1.Extent.Text.Trim("'") }) }
    if ($keys.Count -lt 5) { $problems++; Write-Host "CANARY   rule SETTINGS found only $($keys.Count) OLLAMA_* settings in the installer" -ForegroundColor Red }
    $unText = Get-Content -LiteralPath (Join-Path $Root 'Uninstall-LocalAI.ps1') -Raw -Encoding UTF8
    $diText = Get-Content -LiteralPath (Join-Path $Root 'Get-LocalAIDiagnostics.ps1') -Raw -Encoding UTF8
    foreach ($k in $keys) {
        if ($k -ne 'OLLAMA_MODELS' -and $unText -notmatch ("'" + $k + "'")) { $problems++; Write-Host "SETTINGS Uninstall-LocalAI.ps1 -ResetOllamaSettings does not remove $k" -ForegroundColor Red }
        if ($diText -notmatch ("'" + $k + "'")) { $problems++; Write-Host "SETTINGS Get-LocalAIDiagnostics.ps1 does not report $k" -ForegroundColor Red }
    }
    # llama-server (which places the layers since Ollama 0.35) reads LLAMA_ARG_* from the same
    # environment; one left by another llama.cpp tool must show up in the bundle.
    if ($diText -notmatch "'LLAMA_ARG_\*'") { $problems++; Write-Host 'SETTINGS Get-LocalAIDiagnostics.ps1 does not report LLAMA_ARG_* variables' -ForegroundColor Red }
}

# One definition of "presets measured on another Ollama" for the watch, the health check and
# Update-Models: the watch notices the Ollama app updating itself, and running Update-Models clears it.
foreach ($n in 'Watch-LocalAI.ps1', 'Test-LocalAI.ps1', 'Update-Models.ps1') {
    $fp = Join-Path $Root $n
    if (-not (Test-Path -LiteralPath $fp)) { continue }
    $da = [System.Management.Automation.Language.Parser]::ParseFile($fp, [ref]$null, [ref]$null)
    if (-not $da.Find({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Get-LaiTuningDrift' }, $true)) {
        $problems++; Write-Host "DRIFT    $n does not call Get-LaiTuningDrift (an Ollama that updated itself goes unnoticed, or its notice never clears)" -ForegroundColor Red
    }
}

# Test-LocalAI: the direct SearXNG search depends on the searxng container; with the container down
# it must SKIP with that reason (one cause, one FAIL), as every other dependent check does.
$tlFile = Join-Path $Root 'Test-LocalAI.ps1'
if (Test-Path -LiteralPath $tlFile) {
    $tlAst = [System.Management.Automation.Language.Parser]::ParseFile($tlFile, [ref]$null, [ref]$null)
    $sxCheck = $tlAst.Find({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Add-Check' -and
            $x.CommandElements.Count -ge 2 -and $x.CommandElements[1].Extent.Text -eq "'SearXNG search'" }, $true)
    if (-not $sxCheck -or $sxCheck.Extent.Text -notmatch '\$script:searxUp') {
        $problems++; Write-Host "DEPSKIP  Test-LocalAI.ps1 'SearXNG search' does not skip when the searxng container check failed (`$script:searxUp)" -ForegroundColor Red
    }
}

# README.md only: IMPROVEMENTS.md is a backlog and may name switches that do not exist yet.
foreach ($doc in @(Get-ChildItem -LiteralPath $Root -Filter 'README.md' -File)) {
    foreach ($ln in (Find-MdTableGap (Get-Content -LiteralPath $doc.FullName -Raw -Encoding UTF8))) {
        $problems++
        Write-Host ("MDTABLE  {0}:{1} table row has a different number of cells than its header (two rows on one line?)" -f $doc.Name, $ln) -ForegroundColor Red
    }
    foreach ($p in (Find-DocParam -Text (Get-Content -LiteralPath $doc.FullName -Raw -Encoding UTF8) -ParamsByScript $paramsByScript -ValueParamsByScript $valueParamsByScript)) {
        $problems++
        Write-Host ("{0,-8} {1}:{2} {3}" -f $p.Rule, $doc.Name, $p.Line, $p.Message) -ForegroundColor Red
    }
}

if (Test-Path -LiteralPath $PssaPath) { Import-Module $PssaPath -Force }
if (Get-Module PSScriptAnalyzer) {
    $profile51 = 'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
    $settings = @{
        Rules        = @{
            PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
            PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @($profile51) }
            PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = @($profile51) }
        }
        ExcludeRules = @('PSAvoidUsingWriteHost', 'PSUseShouldProcessForStateChangingFunctions', 'PSUseSingularNouns',
            'PSAvoidUsingPlainTextForPassword', 'PSAvoidUsingConvertToSecureStringWithPlainText', 'PSUseBOMForUnicodeEncodedFile')
    }
    # The mock harness shadows cmdlets with global functions on purpose.
    foreach ($f in ($files | Where-Object { $_.Name -ne 'Invoke-InstallerMockRun.ps1' })) {
        # PSScriptAnalyzer itself occasionally throws a NullReferenceException (seen with the
        # compatibility rules); retry once so a flaky analyzer does not fail the build, and report
        # the file if it crashes twice.
        $found = $null
        for ($attempt = 1; $attempt -le 2 -and $null -eq $found; $attempt++) {
            try { $found = @(Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings) }
            catch {
                if ($attempt -eq 2) { $problems++; Write-Host "PSSA     $($f.Name): analyzer crashed twice: $($_.Exception.Message)" -ForegroundColor Red; $found = @() }
            }
        }
        foreach ($r in $found) {
            $problems++
            Write-Host ("PSSA     {0}:{1} [{2}] {3}" -f $f.Name, $r.Line, $r.RuleName, $r.Message) -ForegroundColor Red
        }
    }
} else {
    Write-Host 'PSScriptAnalyzer not available; skipped.' -ForegroundColor Yellow
}

Write-Host ("Static checks: {0} files, {1} problem(s)" -f $files.Count, $problems) -ForegroundColor $(if ($problems) { 'Red' } else { 'Green' })
exit $problems
