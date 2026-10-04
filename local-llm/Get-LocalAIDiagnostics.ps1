#Requires -Version 5.1
<#
.SYNOPSIS
    Collects everything needed to troubleshoot the local AI stack into one redacted zip, plus a short
    summary you can paste into a chat or an issue.

.DESCRIPTION
    Gathers: Windows/PowerShell versions, GPU and VRAM (nvidia-smi), Ollama version, models, what is
    loaded and its OLLAMA_* settings, the Ollama server log tail, Docker and container states, container
    log tails, the render guard status, Open WebUI health, the config/state/report files, the watch and
    backup logs, the newest install log, free disk space and (with -RunTests) Test-LocalAI -Quick.

    Redaction, applied to every file before it is zipped:
      - the exact secret values this install uses (admin password, WEBUI_SECRET_KEY, SearXNG secret,
        anything else in Stack\.env whose name says KEY/SECRET/PASSWORD/TOKEN);
      - patterns: password=..., "password": "...", Bearer tokens, JWTs, long hex keys;
      - your Windows user name and the admin e-mail (use -KeepNames to leave them in).
    Nothing is uploaded anywhere. Output: <AIRoot>\Logs\diagnostics-<timestamp>.zip

.EXAMPLE
    .\Get-LocalAIDiagnostics.ps1            # zip + summary (summary also copied to the clipboard)
.EXAMPLE
    .\Get-LocalAIDiagnostics.ps1 -RunTests  # also runs Test-LocalAI -Quick and includes its output
#>
param(
    [string]$AIRoot = 'C:\AI',
    [switch]$RunTests,
    [switch]$KeepNames,
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$onWindows = ($env:OS -eq 'Windows_NT')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutDir) { $OutDir = Join-Path $AIRoot 'Logs' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$work = Join-Path ([System.IO.Path]::GetTempPath()) "lai-diag-$stamp"
New-Item -ItemType Directory -Force -Path $work | Out-Null

$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$ollamaUrl = 'http://127.0.0.1:11434'
if ($config.ContainsKey('OllamaUrl') -and $config['OllamaUrl']) { $ollamaUrl = [string]$config['OllamaUrl'] }
$webPort = 3000; if ($config.ContainsKey('WebUIPort')) { $webPort = [int]$config['WebUIPort'] }

# ---- secrets to redact -------------------------------------------------------------------------
$secrets = New-Object System.Collections.ArrayList
function Add-Secret([string]$Value) { if ($Value -and $Value.Length -ge 6 -and -not $secrets.Contains($Value)) { [void]$secrets.Add($Value) } }
$names = New-Object System.Collections.ArrayList
$credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
if (Test-Path -LiteralPath $credFile) {
    try { $c = Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json; Add-Secret ([string]$c.password); if ($c.email) { [void]$names.Add([string]$c.email) } } catch { Write-Verbose 'cred file unreadable' }
}
$keyFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-secret.txt'
if (Test-Path -LiteralPath $keyFile) { Add-Secret ((Get-Content -LiteralPath $keyFile -Raw).Trim()) }
$envFile = Join-Path (Join-Path $AIRoot 'Stack') '.env'
if (Test-Path -LiteralPath $envFile) {
    foreach ($line in (Get-Content -Encoding UTF8 -LiteralPath $envFile)) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.+)$') {
            # Copy the groups first: the second -match below replaces $Matches.
            $k = $Matches[1]; $v = $Matches[2].Trim()
            if ($k -match 'KEY|SECRET|PASSWORD|TOKEN') { Add-Secret $v }
        }
    }
}
$searxSettings = Join-Path (Join-Path (Join-Path $AIRoot 'Stack') 'searxng') 'settings.yml'
if (Test-Path -LiteralPath $searxSettings) {
    $m = Select-String -LiteralPath $searxSettings -Pattern 'secret_key:\s*"?([^"\s]+)' | Select-Object -First 1
    if ($m) { Add-Secret $m.Matches[0].Groups[1].Value }
}
if ($env:USERNAME) { [void]$names.Add($env:USERNAME) }

function Protect-Text([string]$Text) {
    if (-not $Text) { return $Text }
    foreach ($s in $secrets) { $Text = $Text.Replace($s, '[REDACTED]') }
    $Text = [regex]::Replace($Text, '(?i)(password|passwd|secret|secret_key|api_key|token)(["'']?\s*[:=]\s*["'']?)[^\s"'',;}]+', '$1$2[REDACTED]')
    $Text = [regex]::Replace($Text, '(?i)Bearer\s+[A-Za-z0-9\-._~+/]+=*', 'Bearer [REDACTED]')
    $Text = [regex]::Replace($Text, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}', '[JWT]')
    $Text = [regex]::Replace($Text, '\b[0-9a-fA-F]{48,}\b', '[HEX]')
    if (-not $KeepNames) {
        foreach ($n in $names) {
            if ($n -and $n.Length -ge 3) { $Text = [regex]::Replace($Text, [regex]::Escape($n), '<user>', 'IgnoreCase') }
        }
    }
    return $Text
}

function Save-Part([string]$Name, [string]$Text) {
    [System.IO.File]::WriteAllText((Join-Path $work $Name), (Protect-Text $Text), (New-Object System.Text.UTF8Encoding($false)))
}
function Invoke-Capture([string]$File, [string[]]$Arguments) {
    if (-not (Get-Command $File -ErrorAction SilentlyContinue)) { return "($File not found)" }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& $File @Arguments 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $prev }
    return ($out -join "`n")
}
function Get-Tail([string]$Path, [int]$Lines = 200) {
    if (-not (Test-Path -LiteralPath $Path)) { return "(missing: $Path)" }
    return ((Get-Content -LiteralPath $Path -Tail $Lines) -join "`n")
}
function Invoke-Safely([scriptblock]$Block) { try { return (& $Block) } catch { return "(unavailable: $($_.Exception.Message))" } }

$summary = New-Object System.Collections.ArrayList
function Add-Summary([string]$Line) { [void]$summary.Add($Line) }

# ---- system ------------------------------------------------------------------------------------
$os = Invoke-Safely { if ($onWindows) { $o = Get-CimInstance Win32_OperatingSystem; "$($o.Caption) $($o.Version) (build $($o.BuildNumber))" } else { [System.Environment]::OSVersion.VersionString } }
Add-Summary "Local AI diagnostics $stamp"
Add-Summary "OS: $os; PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
$gpu = Get-LaiGpuInfo
if ($gpu) { Add-Summary ("GPU: {0}, driver {1}, VRAM used {2}/{3} MiB; GPU apps: {4}" -f $gpu.Name, $gpu.DriverVersion, $gpu.UsedMiB, $gpu.TotalMiB, ((Get-LaiGpuApps) -join ', ')) } else { Add-Summary 'GPU: nvidia-smi not available' }
Save-Part 'gpu.txt' (Invoke-Capture 'nvidia-smi' @())
$disk = @()
foreach ($p in @($AIRoot, $config['ModelDir'])) {
    if (-not $p) { continue }
    try { $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath([string]$p)); $d = New-Object System.IO.DriveInfo($root); $disk += ('{0} {1:N0} GB free' -f $root, ($d.AvailableFreeSpace / 1GB)) } catch { Write-Verbose 'drive unavailable' }
}
Add-Summary "Disk: $(@($disk | Select-Object -Unique) -join '; ')"

# ---- Ollama ------------------------------------------------------------------------------------
$ollamaVer = Invoke-Safely { Get-LaiOllamaVersion -BaseUrl $ollamaUrl }
Add-Summary "Ollama: $ollamaVer at $ollamaUrl"
$tags = Invoke-Safely { (Invoke-LaiApi -Uri "$ollamaUrl/api/tags" -TimeoutSec 10).models | ForEach-Object { '{0}  {1:N1} GB' -f $_.name, ($_.size / 1GB) } }
$ps = Invoke-Safely { (Invoke-LaiApi -Uri "$ollamaUrl/api/ps" -TimeoutSec 10).models | ForEach-Object { '{0}  ctx {1}  {2:N0}% GPU' -f $_.name, $_.context_length, $(if ($_.size) { 100.0 * $_.size_vram / $_.size } else { 0 }) } }
Add-Summary "Loaded now: $(if ($ps) { @($ps) -join '; ' } else { 'nothing' })"
$ollamaEnv = @()
foreach ($scope in @('User', 'Machine')) {
    foreach ($k in @('OLLAMA_FLASH_ATTENTION', 'OLLAMA_KV_CACHE_TYPE', 'OLLAMA_NUM_PARALLEL', 'OLLAMA_GPU_OVERHEAD', 'OLLAMA_KEEP_ALIVE', 'OLLAMA_NO_CLOUD', 'OLLAMA_IGPU_ENABLE', 'OLLAMA_HOST', 'OLLAMA_MODELS', 'OLLAMA_CONTEXT_LENGTH')) {
        $v = [Environment]::GetEnvironmentVariable($k, $scope)
        if ($v) { $ollamaEnv += "$scope $k=$v" }
    }
}
Save-Part 'ollama.txt' (@("version: $ollamaVer", '', 'models:', ($tags -join "`n"), '', 'loaded:', ($ps -join "`n"), '', 'environment:', ($ollamaEnv -join "`n")) -join "`n")
if ($onWindows -and $env:LOCALAPPDATA) { Save-Part 'ollama-server.log' (Get-Tail (Join-Path $env:LOCALAPPDATA 'Ollama\server.log') 300) }

# ---- Docker / containers -------------------------------------------------------------------------
$dockerVer = Invoke-Capture 'docker' @('version', '--format', '{{.Server.Version}}')
Add-Summary "Docker engine: $(($dockerVer -split "`n")[0])"
$states = Invoke-Capture 'docker' @('ps', '-a', '--filter', 'label=com.docker.compose.project=localai', '--format', '{{.Names}}: {{.Status}} ({{.Image}})')
Add-Summary "Containers: $(($states -split "`n" | Where-Object { $_ }) -join '; ')"
Save-Part 'docker.txt' (@("engine: $dockerVer", '', $states, '', (Invoke-Capture 'docker' @('volume', 'ls'))) -join "`n")
foreach ($c in @('open-webui', 'searxng', 'render-guard')) { Save-Part "logs-$c.txt" (Invoke-Capture 'docker' @('logs', '--tail', '200', $c)) }
$guard = Invoke-Capture 'docker' @('exec', 'render-guard', 'python3', '-c', "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:11434/render-guard/status',timeout=5).read().decode())")
Save-Part 'render-guard-status.json' $guard
$health = Invoke-Safely { (Invoke-LaiApi -Uri "http://127.0.0.1:$webPort/health" -TimeoutSec 10) | ConvertTo-Json -Compress }
$owVer = Invoke-Safely { (Invoke-LaiApi -Uri "http://127.0.0.1:$webPort/api/version" -TimeoutSec 10).version }
Add-Summary "Open WebUI: $owVer on port $webPort, health $health"

# ---- files ----------------------------------------------------------------------------------------
foreach ($f in @('localai-config.json', 'install-state.json', 'install-report.md', 'watch-state.json')) {
    $p = Join-Path $AIRoot $f
    if (Test-Path -LiteralPath $p) { Save-Part $f (Get-Content -LiteralPath $p -Raw) }
}
$logs = Join-Path $AIRoot 'Logs'
Save-Part 'watch.log' (Get-Tail (Join-Path $logs 'watch.log') 150)
Save-Part 'backup.log' (Get-Tail (Join-Path $logs 'backup.log') 150)
$inst = Get-ChildItem -LiteralPath $logs -Filter 'install-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
if ($inst) { Save-Part 'install-latest.log' (Get-Tail $inst.FullName 500) }
$lastWatch = (Get-Tail (Join-Path $logs 'watch.log') 1)
Add-Summary "Health watch, last line: $lastWatch"
$backups = @(Get-ChildItem -LiteralPath (Join-Path $AIRoot 'Backups') -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)  # lai-ok: objects
if ($backups.Count -gt 0) { Add-Summary ("Newest backup: {0} ({1:N0} h old), {2} archives" -f $backups[0].Name, ((Get-Date) - $backups[0].LastWriteTime).TotalHours, $backups.Count) } else { Add-Summary 'Newest backup: none' }

# ---- optional acceptance test ----------------------------------------------------------------------
if ($RunTests) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $exe = 'powershell.exe'; if ($PSVersionTable.PSEdition -ne 'Desktop') { $exe = 'pwsh' }
    $t = @(& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick 2>&1 | ForEach-Object { "$_" })
    $ErrorActionPreference = $prev
    Save-Part 'test-localai.txt' ($t -join "`n")
    $verdict = $t | Where-Object { $_ -match 'V1 COMPLETE|checks failed' } | Select-Object -Last 1
    Add-Summary "Test-LocalAI -Quick: $verdict"
    foreach ($l in ($t | Where-Object { $_ -match '\b(FAIL|WARN)\b' } | Select-Object -First 8)) { Add-Summary "  $l" }
}

# ---- package --------------------------------------------------------------------------------------
$summaryText = Protect-Text ($summary -join "`n")
[System.IO.File]::WriteAllText((Join-Path $work 'summary.txt'), $summaryText, (New-Object System.Text.UTF8Encoding($false)))
$zip = Join-Path $OutDir "diagnostics-$stamp.zip"
Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -Force
Remove-Item -LiteralPath $work -Recurse -Force

Write-Host ''
Write-Host $summaryText
Write-Host ''
try { Set-Clipboard -Value $summaryText; $clip = ' (summary copied to the clipboard)' } catch { $clip = '' }
Write-LaiLog OK "Diagnostics: $zip$clip. Secrets, tokens$(if (-not $KeepNames) { ', your user name and the admin e-mail' }) are redacted; still, skim it before sharing."
