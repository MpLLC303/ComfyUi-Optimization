#Requires -Version 5.1

<#
.SYNOPSIS
    Loads the skills in <AIRoot>\Skills into Open WebUI and offers them in every Local AI preset.

.DESCRIPTION
    Each skill is a folder holding a SKILL.md: a front matter block with name: and description:, then
    the instructions in Markdown. That is the Agent Skills layout, so skills written for other
    assistants can be dropped in as they are. The assistant sees each skill's name and description and
    reads the full instructions only when a question needs them.

    A changed SKILL.md updates its skill; a deleted folder switches its skill off. Skills made in Open
    WebUI itself and the assistant's own drafts (Workspace > Skills, "Learned: ...") are left alone, and
    a skill you switched off in Open WebUI stays off. Run it after adding or editing a skill (Start menu
    > Local AI > Sync skills); the installer runs it too. The first run creates the folder with a few
    starter skills.

.EXAMPLE
    .\Sync-LocalAISkills.ps1
#>
param(
    # Install folder (the installer's -AIRoot).
    [string]$AIRoot = 'C:\AI'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'LocalAI.psm1') -Force

$config = Read-LaiState -Path (Join-Path $AIRoot 'localai-config.json')
$port = 3000; if ($config.ContainsKey('WebUIPort')) { $port = [int]$config['WebUIPort'] }
$baseUrl = "http://127.0.0.1:$port"
$credFile = Join-Path (Join-Path $AIRoot 'Secrets') 'openwebui-admin.json'
if (-not (Test-Path -LiteralPath $credFile)) { throw "No stored Open WebUI login at $credFile. Run the installer first." }
$cred = Get-Content -Encoding UTF8 -Raw -LiteralPath $credFile | ConvertFrom-Json
try { Wait-LaiWebUI -BaseUrl $baseUrl -TimeoutSec 60 }
catch { throw "Open WebUI is not answering on http://localhost:$port. Start menu > Local AI > Start again, then run this again." }
$token = Connect-LaiWebUI -BaseUrl $baseUrl -Email $cred.email -Password $cred.password

$catalog = Get-LaiCatalog -Path (Join-Path (Join-Path $PSScriptRoot 'config') 'models.psd1') -IncludeTrials
$folder = Join-Path $AIRoot 'Skills'
$r = Invoke-LaiSkillSync -BaseUrl $baseUrl -Token $token -Folder $folder -SeedFrom (Join-Path $PSScriptRoot 'skills') -PresetIds @($catalog.Models | ForEach-Object { $_.Preset })

if ($r.Seeded.Count) { Write-LaiLog OK "Created $folder with the starter skills: $($r.Seeded -join ', ')" }
foreach ($line in @(
        @{ L = 'Added'; V = $r.Created }, @{ L = 'Updated'; V = $r.Updated }, @{ L = 'Back on (folder returned)'; V = $r.Restored },
        @{ L = 'Renamed'; V = $r.Replaced }, @{ L = 'Switched off (folder removed)'; V = $r.Disabled })) {
    if (@($line.V).Count) { Write-LaiLog OK "$($line.L): $(@($line.V) -join ', ')" }
}
foreach ($w in $r.Skipped) { Write-LaiLog WARN "Skipped: $w" }
if (@($r.Legacy).Count) { Write-LaiLog INFO "Not attached to $(@($r.Legacy) -join ', '): prompt-based (legacy) tool calling would paste every skill into every message" }
Write-LaiLog OK "$(@($r.ActiveIds).Count) skill(s) from $folder offered in the Local AI presets (add a folder with a SKILL.md, then run this again)"
if ($r.Skipped.Count) { exit 1 }
exit 0
