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
function Find-Pitfall([System.Management.Automation.Language.Ast]$Ast, [string[]]$Lines) {
    $found = New-Object System.Collections.Generic.List[object]
    $add = { param($Rule, $Node, $Msg) $found.Add([pscustomobject]@{ Rule = $Rule; Line = $Node.Extent.StartLineNumber; Message = $Msg }) }
    $marker = { param($Node, $Tag) $Lines[$Node.Extent.StartLineNumber - 1] -match ('#\s*lai-ok:\s*' + $Tag) }

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
    @{ Rule = 'MATCHES'; Fire = $true; Code = 'if ($l -match ''^(\w+)=(.*)$'' -and $Matches[1] -match ''KEY'') { Add-Secret $Matches[2] }' }
    @{ Rule = 'MATCHES'; Fire = $true; Code = 'if ($a -match ''x(\d)'' -and $b -match ''y'' -and $Matches[1]) { 1 }' }
    @{ Rule = 'MATCHES'; Fire = $false; Code = 'if ($l -match ''^(\w+)=(.*)$'') { $k = $Matches[1]; if ($k -match ''KEY'') { 1 } }' }
    @{ Rule = 'MATCHES'; Fire = $false; Code = 'if ($a -match ''x'' -and $b -match ''y'') { 1 }' }
    @{ Rule = 'BOUND'; Fire = $true; Code = 'Invoke-Stage ''Prep'' { if ($PSBoundParameters.ContainsKey(''X'')) { 1 } }' }
    @{ Rule = 'BOUND'; Fire = $true; Code = '$b = { $PSBoundParameters.Count }; & $b' }
    @{ Rule = 'BOUND'; Fire = $false; Code = 'function F { param($X) $PSBoundParameters.ContainsKey(''X'') }' }
    @{ Rule = 'BOUND'; Fire = $false; Code = 'function F { param($X) $PSBoundParameters.Keys | ForEach-Object { $PSBoundParameters[$_] } }' }
)
$canaryFail = 0
foreach ($k in $canaries) {
    $t = $null; $e = $null
    $cast = [System.Management.Automation.Language.Parser]::ParseInput($k.Code, [ref]$t, [ref]$e)
    $hit = @((Find-Pitfall $cast @($k.Code -split "`n")) | Where-Object { $_.Rule -eq $k.Rule }).Count -gt 0
    if ($hit -ne $k.Fire) {
        $canaryFail++; $problems++
        Write-Host ("CANARY   rule {0} {1} on: {2}" -f $k.Rule, $(if ($k.Fire) { 'did not fire' } else { 'fired wrongly' }), $k.Code) -ForegroundColor Red
    }
}
Write-Host ("Pitfall-rule canaries: {0}/{1} OK" -f ($canaries.Count - $canaryFail), $canaries.Count) -ForegroundColor $(if ($canaryFail) { 'Red' } else { 'Green' })

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

    foreach ($p in (Find-Pitfall $ast @(Get-Content -LiteralPath $f.FullName))) {
        $problems++
        Write-Host ("{0,-8} {1}:{2} {3}" -f $p.Rule, $f.Name, $p.Line, $p.Message) -ForegroundColor Red
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
