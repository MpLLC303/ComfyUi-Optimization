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

    $lines = Get-Content -LiteralPath $f.FullName
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (@('Measure-Object', 'Group-Object', 'Sort-Object', 'Select-Object', 'measure', 'group', 'sort', 'select') -notcontains $name) { continue }
        $lineText = $lines[$c.Extent.StartLineNumber - 1]
        if ($lineText -match '#\s*lai-ok:\s*objects') { continue }
        # Let PowerShell's own binder decide what lands in -Property (named or positional).
        $bound = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($c, $true)
        $byName = $false
        if ($bound.BoundParameters.ContainsKey('Property')) {
            $v = $bound.BoundParameters['Property'].Value
            $items = @($v)
            if ($v -is [System.Management.Automation.Language.ArrayLiteralAst]) { $items = @($v.Elements) }
            foreach ($it in $items) {
                if ($it -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $it -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $byName = $true }
            }
        }
        if ($byName) {
            $problems++
            Write-Host "PS51     $($f.Name):$($c.Extent.StartLineNumber) $name by property name fails on hashtables in Windows PowerShell 5.1; use a scriptblock or add '# lai-ok: objects'" -ForegroundColor Red
        }
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
        foreach ($r in (Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings)) {
            $problems++
            Write-Host ("PSSA     {0}:{1} [{2}] {3}" -f $f.Name, $r.Line, $r.RuleName, $r.Message) -ForegroundColor Red
        }
    }
} else {
    Write-Host 'PSScriptAnalyzer not available; skipped.' -ForegroundColor Yellow
}

Write-Host ("Static checks: {0} files, {1} problem(s)" -f $files.Count, $problems) -ForegroundColor $(if ($problems) { 'Red' } else { 'Green' })
exit $problems
