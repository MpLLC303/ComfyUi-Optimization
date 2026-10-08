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
    A program that gives no answer within its time limit (a Docker Desktop that stopped answering
    after sleep) is written down as such, and the bundle is made without its parts.

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
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI',
    [switch]$RunTests,
    [switch]$KeepNames,
    # Where the zip is written; '' = <AIRoot>\Logs.
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
# Run from another account, the secret files cannot be read and their exact values can't be
# redacted (the patterns below still apply): say so instead of shipping a bundle silently.
$script:unreadableSecrets = @()
$credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
if (Test-Path -LiteralPath $credFile) {
    try { $c = Get-Content -Encoding UTF8 -LiteralPath $credFile -Raw | ConvertFrom-Json; Add-Secret ([string]$c.password); if ($c.email) { [void]$names.Add([string]$c.email) } } catch { $script:unreadableSecrets += $credFile }
}
$keyFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-secret.txt'
if (Test-Path -LiteralPath $keyFile) {
    try { Add-Secret ((Get-Content -Encoding UTF8 -LiteralPath $keyFile -Raw -ErrorAction Stop).Trim()) } catch { $script:unreadableSecrets += $keyFile }
}
$envFile = Join-Path (Join-Path $AIRoot 'Stack') '.env'
if (Test-Path -LiteralPath $envFile) {
    $envLines = @()
    try { $envLines = @(Get-Content -Encoding UTF8 -LiteralPath $envFile -ErrorAction Stop) } catch { $script:unreadableSecrets += $envFile }
    foreach ($line in $envLines) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.+)$') {
            # Copy the groups first: the second -match below replaces $Matches.
            $k = $Matches[1]; $v = $Matches[2].Trim()
            if ($k -match 'KEY|SECRET|PASSWORD|TOKEN') { Add-Secret $v }
        }
    }
}
$searxSettings = Join-Path (Join-Path (Join-Path $AIRoot 'Stack') 'searxng') 'settings.yml'
if (Test-Path -LiteralPath $searxSettings) {
    $m = Select-String -LiteralPath $searxSettings -Pattern 'secret_key:\s*"?([^"\s]+)' -Encoding UTF8 | Select-Object -First 1
    if ($m) { Add-Secret $m.Matches[0].Groups[1].Value }
}
if ($env:USERNAME) { [void]$names.Add($env:USERNAME) }
# The profile folder keeps its first name after an account rename (and differs for Microsoft/Azure AD
# accounts), and it is in every path.
if ($env:USERPROFILE) { [void]$names.Add((Split-Path -Leaf $env:USERPROFILE)) }
# The computer name shows up in transcripts (Machine:, HOST\user) and container logs.
if ($env:COMPUTERNAME) { [void]$names.Add($env:COMPUTERNAME) }

function Protect-Text([string]$Text) {
    if (-not $Text) { return $Text }
    foreach ($s in $secrets) { $Text = $Text.Replace($s, '[REDACTED]') }
    # CultureInvariant: under tr-TR, IgnoreCase does not pair I/i, so OPENAI_API_KEY would not match.
    $ci = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'
    $Text = [regex]::Replace($Text, '(password|passwd|secret|secret_key|api_key|token)(["'']?\s*[:=]\s*["'']?)[^\s"'',;}]+', '$1$2[REDACTED]', $ci)
    $Text = [regex]::Replace($Text, 'Bearer\s+[A-Za-z0-9\-._~+/]+=*', 'Bearer [REDACTED]', $ci)
    $Text = [regex]::Replace($Text, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}', '[JWT]')
    $Text = [regex]::Replace($Text, '\b[0-9a-fA-F]{48,}\b', '[HEX]')
    if (-not $KeepNames) {
        # Any e-mail address (other accounts, addresses in logs), not only the admin's.
        $Text = [regex]::Replace($Text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>')
        foreach ($n in $names) {
            # Two characters is a whole name in Chinese/Japanese/Korean (and 'Li'). Whole words only, so
            # 'Li' does not turn 'Limited' or 'client' into '<user>mited' and 'c<user>ent'.
            if ($n -and $n.Length -ge 2) { $Text = [regex]::Replace($Text, '(?<![\p{L}\p{N}])' + [regex]::Escape($n) + '(?![\p{L}\p{N}])', '<user>', $ci) }
        }
    }
    return $Text
}

function Save-Part([string]$Name, [string]$Text) {
    [System.IO.File]::WriteAllText((Join-Path $work $Name), (Protect-Text $Text), (New-Object System.Text.UTF8Encoding($false)))
}
# Every program run for the bundle has a time limit. After sleep Docker Desktop can stop answering
# while its commands still start: without a limit this script would wait on the first docker call
# without a word, and no bundle would be made. A program that gave no answer is not asked again
# (ten more docker calls would each wait for the limit): every later capture of it gets the same line.
$dockerLimit = Get-LaiDockerTimeout
$hungMsg = 'Docker Desktop is not responding. Restart it (whale icon > Restart), wait for Engine running, then run this again.'
$script:noAnswer = @{}
function Invoke-Capture([string]$File, [string[]]$Arguments) {
    if ($script:noAnswer.ContainsKey($File)) { return $script:noAnswer[$File] }
    if (-not (Get-Command $File -CommandType Application -ErrorAction SilentlyContinue)) { return "($File not found)" }
    # Invoke-LaiTimedNative reads the output as UTF-8, which is what docker/ollama/nvidia-smi write:
    # read as anything else, a non-ASCII user name in a path is mangled and slips past the redaction.
    try { $r = Invoke-LaiTimedNative -File $File -Arguments $Arguments -TimeoutSec $dockerLimit }
    catch { return "($File could not be run: $($_.Exception.Message))" }
    if ($r.TimedOut) {
        $script:noAnswer[$File] = "($File did not answer within $dockerLimit s)"
        return $script:noAnswer[$File]
    }
    return $r.Text
}
function Get-LogByTime([string]$Text) {
    # A container's log, asked for with --timestamps, in the order it was written. 'docker logs' hands
    # over what the container wrote to stdout and to stderr separately, and Invoke-Capture returns all
    # of the first followed by all of the second: a request and the error it led to would be far
    # apart, with nothing to tell that from. Every line starts with its time
    # (2026-01-02T03:04:05.123456789Z ...): sorted by that, and by where it stood for the same time.
    # A line without one (docker's own 'No such container') keeps its place behind the line before it.
    $lines = @($Text -split "`r?`n")
    $keys = New-Object string[] $lines.Count
    $last = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(?:Z|[+-]\d\d:\d\d)(?: |$)')
        # The fraction padded to nine digits: compared as text, .5 must not come after .25.
        if ($m.Success) { $last = $m.Groups[1].Value + '.' + $m.Groups[2].Value.PadRight(9, '0') }
        $keys[$i] = $last + ' ' + $i.ToString('D6')
    }
    # Only the keys are sorted, and each one ends in the place of its line. (Sorting the lines along
    # with them, [Array]::Sort($keys, $lines), sorts a copy of the lines and leaves these as they were.)
    [Array]::Sort($keys, [System.StringComparer]::Ordinal)
    return (@($keys | ForEach-Object { $lines[[int]$_.Substring($_.LastIndexOf(' ') + 1)] }) -join "`n")
}
function Get-Tail([string]$Path, [int]$Lines = 200) {
    if (-not (Test-Path -LiteralPath $Path)) { return "(missing: $Path)" }
    # Ollama's and the toolkit's logs are UTF-8 (5.1 would read them as ANSI and garble names).
    return ((Get-Content -LiteralPath $Path -Tail $Lines -Encoding UTF8) -join "`n")
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
    foreach ($k in @('OLLAMA_FLASH_ATTENTION', 'OLLAMA_KV_CACHE_TYPE', 'OLLAMA_NUM_PARALLEL', 'OLLAMA_MAX_LOADED_MODELS', 'OLLAMA_GPU_OVERHEAD', 'OLLAMA_KEEP_ALIVE', 'OLLAMA_NO_CLOUD', 'OLLAMA_IGPU_ENABLE', 'OLLAMA_HOST', 'OLLAMA_MODELS', 'OLLAMA_CONTEXT_LENGTH')) {
        $v = [Environment]::GetEnvironmentVariable($k, $scope)
        if ($v) { $ollamaEnv += "$scope $k=$v" }
    }
    # Ollama passes its whole environment to llama-server, which decides the GPU/CPU split itself and
    # reads LLAMA_ARG_* (e.g. LLAMA_ARG_FIT_TARGET, LLAMA_ARG_N_GPU_LAYERS): one left behind by another
    # llama.cpp-based tool silently changes how the models are placed.
    try {
        $all = [Environment]::GetEnvironmentVariables($scope)
        foreach ($k in @($all.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -like 'LLAMA_ARG_*' } | Sort-Object)) { $ollamaEnv += "$scope $k=$($all[$k])" }
    } catch { Write-Verbose "LLAMA_ARG_* not readable for $scope" }
}
Save-Part 'ollama.txt' (@("version: $ollamaVer", '', 'models:', ($tags -join "`n"), '', 'loaded:', ($ps -join "`n"), '', 'environment:', ($ollamaEnv -join "`n")) -join "`n")
if ($onWindows -and $env:LOCALAPPDATA) { Save-Part 'ollama-server.log' (Get-Tail (Join-Path $env:LOCALAPPDATA 'Ollama\server.log') 300) }

# ---- Docker / containers -------------------------------------------------------------------------
$dockerVer = Invoke-Capture 'docker' @('version', '--format', '{{.Server.Version}}')
Add-Summary "Docker engine: $(($dockerVer -split "`n")[0])"
$states = Invoke-Capture 'docker' @('ps', '-a', '--filter', 'label=com.docker.compose.project=localai', '--format', '{{.Names}}: {{.Status}} ({{.Image}})')
Add-Summary "Containers: $(($states -split "`n" | Where-Object { $_ }) -join '; ')"
Save-Part 'docker.txt' (@("engine: $dockerVer", '', $states, '', (Invoke-Capture 'docker' @('volume', 'ls'))) -join "`n")
foreach ($c in @('open-webui', 'searxng', 'render-guard', 'deep-research')) { Save-Part "logs-$c.txt" (Get-LogByTime (Invoke-Capture 'docker' @('logs', '--timestamps', '--tail', '200', $c))) }
$guard = Invoke-Capture 'docker' @('exec', 'render-guard', 'python3', '-c', "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:11434/render-guard/status',timeout=5).read().decode())")
Save-Part 'render-guard-status.json' $guard
$health = Invoke-Safely { (Invoke-LaiApi -Uri "http://127.0.0.1:$webPort/health" -TimeoutSec 10) | ConvertTo-Json -Compress }
$owVer = Invoke-Safely { (Invoke-LaiApi -Uri "http://127.0.0.1:$webPort/api/version" -TimeoutSec 10).version }
Add-Summary "Open WebUI: $owVer on port $webPort, health $health"

# ---- files ----------------------------------------------------------------------------------------
foreach ($f in @('localai-config.json', 'install-state.json', 'install-report.md', 'watch-state.json', 'model-recheck.json')) {
    $p = Join-Path $AIRoot $f
    if (Test-Path -LiteralPath $p) { Save-Part $f (Get-Content -Encoding UTF8 -LiteralPath $p -Raw) }
}
$logs = Join-Path $AIRoot 'Logs'
Save-Part 'watch.log' (Get-Tail (Join-Path $logs 'watch.log') 150)
Save-Part 'backup.log' (Get-Tail (Join-Path $logs 'backup.log') 150)
Save-Part 'model-recheck.log' (Get-Tail (Join-Path $logs 'model-recheck.log') 150)
$inst = Get-ChildItem -LiteralPath $logs -Filter 'install-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1  # lai-ok: objects
if ($inst) { Save-Part 'install-latest.log' (Get-Tail $inst.FullName 500) }
# The last run of each Start-menu shortcut (its window's text is gone once closed).
foreach ($sl in @(Get-ChildItem -LiteralPath $logs -Filter 'shortcut-*.log' -ErrorAction SilentlyContinue)) { Save-Part $sl.Name (Get-Tail $sl.FullName 200) }
$lastWatch = (Get-Tail (Join-Path $logs 'watch.log') 1)
Add-Summary "Health watch, last line: $lastWatch"
$backups = @(Get-ChildItem -LiteralPath (Join-Path $AIRoot 'Backups') -Filter 'open-webui-*.tar.gz' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)  # lai-ok: objects
if ($backups.Count -gt 0) { Add-Summary ("Newest backup: {0} ({1:N0} h old), {2} archives" -f $backups[0].Name, ((Get-Date) - $backups[0].LastWriteTime).TotalHours, $backups.Count) } else { Add-Summary 'Newest backup: none' }

# ---- optional acceptance test ----------------------------------------------------------------------
if ($RunTests) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $exe = 'powershell.exe'; if ($PSVersionTable.PSEdition -ne 'Desktop') { $exe = 'pwsh' }
    # -LockWaitSec 30: with Open WebUI down while the volume lock is held, the health check waits
    # for that lock, 600 s unless told otherwise. Its output is caught here, so this window would
    # say nothing for those ten minutes. After 30 s the row fails with words that say the wait was
    # too short to tell, and that the health check run by itself waits the full time.
    $t = @(& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-LocalAI.ps1') -AIRoot $AIRoot -Quick -LockWaitSec 30 2>&1 | ForEach-Object { "$_" })
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
Write-LaiLog OK "Diagnostics: $zip$clip. Secrets, tokens$(if (-not $KeepNames) { ', your user and computer names and e-mail addresses' }) are redacted; still, skim it before sharing."
if ($script:noAnswer.ContainsKey('docker')) {
    Write-LaiLog WARN "$hungMsg The bundle was made without the Docker parts (engine, containers, their logs, the render guard status)."
}
if ($script:unreadableSecrets.Count) {
    Write-LaiLog WARN "Could not read $($script:unreadableSecrets -join ', ') (run this as the account that installed Local AI): the admin password may not be redacted. Check the bundle before sharing it."
}
