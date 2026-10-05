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
#   ENCODING Get-Content of an env/config/state/secret file without -Encoding UTF8 (5.1 reads
#            BOM-less UTF-8 as ANSI; .env must be BOM-less for docker compose).
#   HELP     a user-facing script (toolkit root) with a parameter its help never mentions: no
#            .PARAMETER entry, no comment right above it, no -Name in the help text.
#   DOCPARAM README.md tells the user to run a script with a -Switch that script does not have.
#   COMPOSELOG a service in stack/docker-compose.yml without 'logging:' (Docker keeps container logs
#            forever by default; on an always-on PC they grow without limit).
#   NATIVEQUOTE a literal double quote inside an argument for a native program (docker, wsl, ...):
#            Windows PowerShell 5.1 does not escape it, so the program receives it stripped.
function Find-Pitfall([System.Management.Automation.Language.Ast]$Ast, [string[]]$Lines, [string]$FileName = '', [switch]$UserFacing) {
    $found = New-Object System.Collections.Generic.List[object]
    $add = { param($Rule, $Node, $Msg) $found.Add([pscustomobject]@{ Rule = $Rule; Line = $Node.Extent.StartLineNumber; Message = $Msg }) }
    $marker = { param($Node, $Tag) $Lines[$Node.Extent.StartLineNumber - 1] -match ('#\s*lai-ok:\s*' + $Tag) }
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
        $wrappers = @('Invoke-Native', 'Invoke-Docker', 'Invoke-DockerText', 'Invoke-DockerCli', 'Invoke-DockerQuiet', 'Invoke-Compose', 'Invoke-Tailscale', 'Invoke-Capture')
        if (($nativeNames -contains $name -or $wrappers -contains $name) -and -not (& $marker $c 'quote')) {
            $quoted = @($c.FindAll({ param($n) ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -ne 'BareWord') -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) |
                Where-Object { $_.Value -match '"' })
            if ($quoted.Count) { & $add 'NATIVEQUOTE' $c "argument with a double quote for a native program ($($quoted[0].Extent.Text)): 5.1 strips it; use backticks in Go templates or avoid the quote" }
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
        # A string or (...) argument followed by a bare -f or + : meant as an operator, bound as an
        # argument. Only Verb-Noun commands: native tools (docker -f file) take -f legitimately.
        $els = $c.CommandElements
        for ($i = 2; $i -lt $els.Count -and $name -match '^[A-Za-z]+-[A-Za-z]+$'; $i++) {
            $prevEl = $els[$i - 1]
            $isText = $prevEl -is [System.Management.Automation.Language.ParenExpressionAst] -or
                $prevEl -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                ($prevEl -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $prevEl.StringConstantType -ne 'BareWord')
            if (-not $isText) { continue }
            $el = $els[$i]
            $op = $null
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq 'f') { $op = '-f' }
            elseif ($el -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $el.StringConstantType -eq 'BareWord' -and $el.Value -eq '+') { $op = '+' }
            if ($op -and -not (& $marker $c 'format')) {
                & $add 'FORMAT' $c "$name gets '$op' as a separate argument (command mode); wrap the whole expression: $name ((...) $op ...)"
            }
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
    return , $found
}

function Find-DocParam([string]$Text, [hashtable]$ParamsByScript) {
    # "Script.ps1 -A -B x" in the docs: every -A must be a parameter of that script. The command runs
    # to the end of the code span or line, or a comment / pipe / ';'. Install-LocalAI.cmd passes its
    # arguments to Install-LocalAI.ps1. -WhatIf/-Confirm/-Verbose are common parameters.
    $found = New-Object System.Collections.Generic.List[object]
    $lineNo = 0
    foreach ($line in ($Text -split "`n")) {
        $lineNo++
        foreach ($m in [regex]::Matches($line, '([A-Za-z][\w-]*)\.(ps1|cmd)((?:[ \t]+[^`|#;\s]+)*)')) {
            $script = $m.Groups[1].Value + '.ps1'
            if (-not $ParamsByScript.ContainsKey($script)) { continue }
            foreach ($a in [regex]::Matches($m.Groups[3].Value, '(?<=^|\s)-([A-Za-z]\w*)')) {
                $pn = $a.Groups[1].Value
                if (@('WhatIf', 'Confirm', 'Verbose') -contains $pn) { continue }
                if (@($ParamsByScript[$script] | Where-Object { $_ -eq $pn }).Count -eq 0) {
                    $found.Add([pscustomobject]@{ Rule = 'DOCPARAM'; Line = $lineNo; Message = "$script has no parameter -$pn (docs: $($m.Value.Trim()))" })
                }
            }
        }
    }
    return , $found
}

function Find-ComposeLogGap([string]$Text) {
    # Service names under 'services:' whose block has no 'logging:' key.
    $missing = @(); $inServices = $false; $svc = $null; $hasLog = $false
    foreach ($l in (($Text -split "`n") + @('end:'))) {
        if ($l -match '^\S') {
            if ($svc -and -not $hasLog) { $missing += $svc }
            $svc = $null; $inServices = ($l -match '^services:\s*$'); continue
        }
        if (-not $inServices) { continue }
        if ($l -match '^  ([A-Za-z0-9_-]+):\s*$') { if ($svc -and -not $hasLog) { $missing += $svc }; $svc = $Matches[1]; $hasLog = $false }
        elseif ($l -match '^    logging:') { $hasLog = $true }
    }
    return , $missing
}

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
    @{ Rule = 'FORMAT'; Fire = $false; Code = '& docker inspect -f ''{{.State.Status}}'' open-webui' }
    @{ Rule = 'FORMAT'; Fire = $false; Code = 'Remove-Item $p -f' }
    @{ Rule = 'FORMAT'; Fire = $false; Code = '& docker compose --project-directory (Join-Path $r ''S'') -f (Join-Path $r ''c.yml'') up' }
    @{ Rule = 'ELEVATED'; Fire = $true; File = 'Install-LocalAI.ps1'; Code = '& (Join-Path $P.Scripts ''Test-LocalAI.ps1'') -AIRoot $AIRoot' }
    @{ Rule = 'ELEVATED'; Fire = $true; File = 'Install-LocalAI.ps1'; Code = 'Import-Module (Join-Path $P.Scripts ''lib\LocalAI.psm1'')' }
    @{ Rule = 'ELEVATED'; Fire = $false; File = 'Install-LocalAI.ps1'; Code = '& (Join-Path $SourceRoot ''Test-LocalAI.ps1'') -AIRoot $AIRoot' }
    @{ Rule = 'ELEVATED'; Fire = $false; File = 'Install-LocalAI.ps1'; Code = '$x = Join-Path $P.Scripts ''Watch-LocalAI.ps1''' }
    @{ Rule = 'ELEVATED'; Fire = $true; File = 'Install-LocalAI.ps1'; Code = "`$b = Join-Path `$P.Scripts 'Backup-OpenWebUI.ps1'`n& `$b -AIRoot `$AIRoot" }
    @{ Rule = 'ELEVATED'; Fire = $false; File = 'Install-LocalAI.ps1'; Code = "`$b = Join-Path `$SourceRoot 'Backup-OpenWebUI.ps1'`n& `$b -AIRoot `$AIRoot" }
    @{ Rule = 'NOSILENT'; Fire = $true; Code = '$p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest' }
    @{ Rule = 'NOSILENT'; Fire = $false; Code = '$p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Limited' }
    @{ Rule = 'ENCODING'; Fire = $true; Code = 'foreach ($l in (Get-Content -LiteralPath $envPath)) { $l }' }
    @{ Rule = 'ENCODING'; Fire = $true; Code = '$c = Get-Content -LiteralPath $credFile -Raw | ConvertFrom-Json' }
    @{ Rule = 'ENCODING'; Fire = $false; Code = '$c = Get-Content -LiteralPath $credFile -Raw -Encoding UTF8 | ConvertFrom-Json' }
    @{ Rule = 'ENCODING'; Fire = $false; Code = 'Get-Content -LiteralPath $logFile -Tail 50' }
    @{ Rule = 'ENCODING'; Fire = $true; Code = '$k = (Get-Content -LiteralPath $secretFile -Raw).Trim()' }
    @{ Rule = 'MATCHES'; Fire = $true; Code = 'if ($l -match ''^(\w+)=(.*)$'' -and $Matches[1] -match ''KEY'') { Add-Secret $Matches[2] }' }
    @{ Rule = 'MATCHES'; Fire = $true; Code = 'if ($a -match ''x(\d)'' -and $b -match ''y'' -and $Matches[1]) { 1 }' }
    @{ Rule = 'MATCHES'; Fire = $false; Code = 'if ($l -match ''^(\w+)=(.*)$'') { $k = $Matches[1]; if ($k -match ''KEY'') { 1 } }' }
    @{ Rule = 'MATCHES'; Fire = $false; Code = 'if ($a -match ''x'' -and $b -match ''y'') { 1 }' }
    @{ Rule = 'BOUND'; Fire = $true; Code = 'Invoke-Stage ''Prep'' { if ($PSBoundParameters.ContainsKey(''X'')) { 1 } }' }
    @{ Rule = 'BOUND'; Fire = $true; Code = '$b = { $PSBoundParameters.Count }; & $b' }
    @{ Rule = 'BOUND'; Fire = $false; Code = 'function F { param($X) $PSBoundParameters.ContainsKey(''X'') }' }
    @{ Rule = 'BOUND'; Fire = $false; Code = 'function F { param($X) $PSBoundParameters.Keys | ForEach-Object { $PSBoundParameters[$_] } }' }
    @{ Rule = 'HELP'; Fire = $true; UserFacing = $true; Code = "<#`n.SYNOPSIS`n  x`n#>`nparam(`n  [switch]`$Force`n)" }
    @{ Rule = 'HELP'; Fire = $false; UserFacing = $true; Code = "<#`n.SYNOPSIS`n  x`n.PARAMETER Force`n  y`n#>`nparam(`n  [switch]`$Force`n)" }
    @{ Rule = 'HELP'; Fire = $false; UserFacing = $true; Code = "<#`n.SYNOPSIS`n  x`n#>`nparam(`n  # skip the prompt`n  [switch]`$Force`n)" }
    @{ Rule = 'HELP'; Fire = $false; UserFacing = $true; Code = "<#`n.SYNOPSIS`n  x`n.DESCRIPTION`n  -Force skips the prompt.`n#>`nparam(`n  [switch]`$Force`n)" }
    @{ Rule = 'HELP'; Fire = $false; Code = "<#`n.SYNOPSIS`n  x`n#>`nparam(`n  [switch]`$Force`n)" }
    @{ Rule = 'NATIVEQUOTE'; Fire = $true; Code = '$l = Invoke-Native -File ''docker'' -Arguments @(''ps'', ''--format'', ''{{.ID}}|{{.Label "com.docker.compose.project"}}'') -Capture' }
    @{ Rule = 'NATIVEQUOTE'; Fire = $true; Code = '& docker inspect -f ''{{index .Labels "x"}}'' c' }
    @{ Rule = 'NATIVEQUOTE'; Fire = $false; Code = '$l = Invoke-Native -File ''docker'' -Arguments @(''ps'', ''--format'', ''{{.Label `x`}}'') -Capture' }
    @{ Rule = 'NATIVEQUOTE'; Fire = $false; Code = 'Write-Host ''say "hi"''' }
    @{ Rule = 'HELP'; Fire = $true; UserFacing = $true; Code = "#Requires -Version 5.1`n<#`n.SYNOPSIS`n  x`n#>`nparam(`n  # y`n  [switch]`$Force`n)" }
    @{ Rule = 'HELP'; Fire = $false; UserFacing = $true; Code = "#Requires -Version 5.1`n`n<#`n.SYNOPSIS`n  x`n#>`nparam(`n  # y`n  [switch]`$Force`n)" }
)
$canaryFail = 0
$docCanaries = @(
    @{ Fire = $true; Text = 'Run `Update-OpenWebUI.ps1 -Latests` to update.' }
    @{ Fire = $true; Text = '    .\Install-LocalAI.cmd -RenderGuard off -NoSuchSwitch' }
    @{ Fire = $false; Text = 'Run `Update-OpenWebUI.ps1 -Latest` or `Install-LocalAI.cmd -RenderGuard off` (or -Foo outside the span).' }
    @{ Fire = $false; Text = '.\Uninstall-LocalAI.ps1 -WhatIf   # -NotAParam in a comment' }
)
foreach ($k in @(
        @{ Fire = $true; Text = "services:`n  a:`n    image: x`n    logging: *l`n  b:`n    image: y`nvolumes:`n  v:" }
        @{ Fire = $false; Text = "services:`n  a:`n    image: x`n    logging: *l`nvolumes:`n  v:" })) {
    if (((Find-ComposeLogGap $k.Text).Count -gt 0) -ne $k.Fire) {
        $canaryFail++; $problems++
        Write-Host ("CANARY   rule COMPOSELOG {0}" -f $(if ($k.Fire) { 'did not fire' } else { 'fired wrongly' })) -ForegroundColor Red
    }
}
foreach ($k in $docCanaries) {
    $hit = (Find-DocParam -Text $k.Text -ParamsByScript @{ 'Update-OpenWebUI.ps1' = @('Latest'); 'Install-LocalAI.ps1' = @('RenderGuard'); 'Uninstall-LocalAI.ps1' = @('Force') }).Count -gt 0
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
Write-Host ("Pitfall-rule canaries: {0}/{1} OK" -f ($canaries.Count + $docCanaries.Count + 2 - $canaryFail), ($canaries.Count + $docCanaries.Count + 2)) -ForegroundColor $(if ($canaryFail) { 'Red' } else { 'Green' })

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

# The README's commands against the scripts' real parameters.
$paramsByScript = @{}
foreach ($f in ($files | Where-Object { $_.DirectoryName -eq $Root -and $_.Extension -eq '.ps1' })) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    $paramsByScript[$f.Name] = @(if ($ast.ParamBlock) { $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } })
}
$composeFile = Join-Path (Join-Path $Root 'stack') 'docker-compose.yml'
if (Test-Path -LiteralPath $composeFile) {
    foreach ($svc in (Find-ComposeLogGap (Get-Content -LiteralPath $composeFile -Raw -Encoding UTF8))) {
        $problems++; Write-Host "COMPOSELOG docker-compose.yml: service '$svc' has no logging limits (add 'logging: *logging')" -ForegroundColor Red
    }
}

# Every rule prefix this script prints must be one the test runner counts as a failure.
$runnerText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-AllTests.ps1') -Raw -Encoding UTF8
$myRules = @([regex]::Matches((Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8), "(?m)^#   ([A-Z0-9]+) ") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
foreach ($rule in $myRules) {
    if ($runnerText -notmatch ('VerdictPattern = [^\r\n]*\b' + $rule + '\b')) { $problems++; Write-Host "CANARY   rule $rule is not in Invoke-AllTests.ps1's VerdictPattern" -ForegroundColor Red }
}

# README.md only: IMPROVEMENTS.md is a backlog and may name switches that do not exist yet.
foreach ($doc in @(Get-ChildItem -LiteralPath $Root -Filter 'README.md' -File)) {
    foreach ($p in (Find-DocParam -Text (Get-Content -LiteralPath $doc.FullName -Raw -Encoding UTF8) -ParamsByScript $paramsByScript)) {
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
