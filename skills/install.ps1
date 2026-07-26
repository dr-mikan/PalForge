<#
.SYNOPSIS
Install the PalForge agent skill for whichever supported tools are on this machine.

.DESCRIPTION
No network, no elevation. Copies files only into the directories it names:
  Claude Code (default)  <project>\.claude\skills\palforge\
  Claude Code (-User)    $HOME\.claude\skills\palforge\
  Codex                  $HOME\.codex\prompts\palforge-pack.md
AGENTS.md is never edited; the block to add is printed instead.

.PARAMETER Project
Install the Claude Code skill into this project only. This is the default.

.PARAMETER User
Install the Claude Code skill into your home directory, for every project.

.PARAMETER ProjectDir
Project root for -Project. Defaults to the current directory.

.PARAMETER Claude
Install for Claude Code only. Without -Claude or -Codex, every detected tool is used.

.PARAMETER Codex
Install for Codex only.

.PARAMETER Force
Replace an existing install. Without it, an existing destination is left alone and the
script exits non-zero.

.EXAMPLE
.\install.ps1
.EXAMPLE
.\install.ps1 -User -Force
#>
[CmdletBinding()]
param(
    [switch]$Project,
    [switch]$User,
    [string]$ProjectDir,
    [switch]$Claude,
    [switch]$Codex,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Die([string]$Message) {
    [Console]::Error.WriteLine("install.ps1: $Message")
    exit 1
}

$ScriptDir      = $PSScriptRoot
$SkillSrc       = Join-Path $ScriptDir 'palforge'
$CodexPromptSrc = Join-Path $ScriptDir 'codex\prompts\palforge-pack.md'
$CodexAgentsSrc = Join-Path $ScriptDir 'codex\AGENTS.md'

$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $HOME }
if (-not $HomeDir) { Die 'cannot determine your home directory (USERPROFILE and HOME are both unset)' }

if ($User -and $Project) { Die 'pass -Project or -User, not both' }
if (-not $ProjectDir)    { $ProjectDir = (Get-Location).Path }

if (-not (Test-Path -LiteralPath $SkillSrc -PathType Container)) { Die "missing source directory: $SkillSrc" }
if (-not (Test-Path -LiteralPath (Join-Path $SkillSrc 'SKILL.md') -PathType Leaf)) {
    Die "missing $SkillSrc\SKILL.md - this is not a complete skill tree"
}
if (-not (Test-Path -LiteralPath $CodexPromptSrc -PathType Leaf)) { Die "missing source file: $CodexPromptSrc" }
if (-not (Test-Path -LiteralPath $CodexAgentsSrc -PathType Leaf)) { Die "missing source file: $CodexAgentsSrc" }

# Detect what is present, unless the caller named a target.
$wantClaude = [bool]$Claude
$wantCodex  = [bool]$Codex
if (-not $Claude -and -not $Codex) {
    $wantClaude = [bool](Get-Command claude -ErrorAction SilentlyContinue) -or
                  (Test-Path -LiteralPath (Join-Path $HomeDir '.claude') -PathType Container)
    $wantCodex  = [bool](Get-Command codex  -ErrorAction SilentlyContinue) -or
                  (Test-Path -LiteralPath (Join-Path $HomeDir '.codex')  -PathType Container)
    if (-not $wantClaude -and -not $wantCodex) {
        Die ("no supported tool found (looked for the 'claude' and 'codex' commands, and for " +
             "$HomeDir\.claude and $HomeDir\.codex). Pass -Claude and/or -Codex to install anyway.")
    }
}

function Show-Installed([string]$Root) {
    Get-ChildItem -LiteralPath $Root -Recurse -File |
        Sort-Object FullName |
        ForEach-Object { Write-Host "    $($_.FullName)" }
}

function Install-Claude {
    if ($User) {
        $dest = Join-Path $HomeDir '.claude\skills\palforge'
        Write-Host 'Claude Code: user install (every project on this machine).'
    } else {
        if (-not (Test-Path -LiteralPath $ProjectDir -PathType Container)) {
            Die "project directory does not exist: $ProjectDir"
        }
        $root = (Resolve-Path -LiteralPath $ProjectDir).Path
        $dest = Join-Path $root '.claude\skills\palforge'
        Write-Host "Claude Code: project install (this project only: $root)."
    }

    if (Test-Path -LiteralPath $dest) {
        if ($Force) { Remove-Item -LiteralPath $dest -Recurse -Force }
        else        { Die "$dest already exists. Re-run with -Force to replace it." }
    }

    $parent = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $SkillSrc -Destination $dest -Recurse
    Write-Host "  copied $SkillSrc -> $dest"
    Show-Installed $dest
}

function Install-Codex {
    $promptDir = Join-Path $HomeDir '.codex\prompts'
    $dest      = Join-Path $promptDir 'palforge-pack.md'
    Write-Host 'Codex: user install (every project on this machine).'

    if (Test-Path -LiteralPath $dest) {
        if ($Force) { Remove-Item -LiteralPath $dest -Force }
        else        { Die "$dest already exists. Re-run with -Force to replace it." }
    }

    if (-not (Test-Path -LiteralPath $promptDir)) { New-Item -ItemType Directory -Path $promptDir -Force | Out-Null }
    Copy-Item -LiteralPath $CodexPromptSrc -Destination $dest
    Write-Host "  copied $CodexPromptSrc -> $dest"
    Write-Host "    $dest"
    Write-Host '  run it in Codex as: /palforge-pack'

    Write-Host ''
    Write-Host '  AGENTS.md is yours, so this script does not touch it. To give Codex the'
    Write-Host '  PalForge knowledge in every turn, paste the contents of'
    Write-Host ''
    Write-Host "    $CodexAgentsSrc"
    Write-Host ''
    Write-Host '  into the AGENTS.md of the project you are modding, under a heading of your'
    Write-Host "  choosing. For every project on this machine, put it in $HomeDir\.codex\AGENTS.md"
    Write-Host '  instead. Copy it with:'
    Write-Host ''
    Write-Host "    Get-Content `"$CodexAgentsSrc`" | Add-Content .\AGENTS.md"
}

try {
    if ($wantClaude) { Install-Claude }
    if ($wantCodex)  { Install-Codex }
} catch {
    Die $_.Exception.Message
}

Write-Host ''
Write-Host 'Done.'
exit 0
