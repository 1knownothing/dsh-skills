# install.ps1 - install the agent-dev-workflow skill into the DSH global skill root.
#
# Run the copy that lives in your SOURCE bundle, NOT the installed copy: installing the
# installed copy onto itself would delete the skill (source == target, refused by a guard).
#
# Usage (Windows PowerShell 5.1 or PowerShell 7+):
#   powershell -ExecutionPolicy Bypass -File install.ps1              # install / update
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall   # remove
#   powershell -ExecutionPolicy Bypass -File install.ps1 -WhatIf      # dry run
#
# Install target is the DSH filesystem skill provider's "user-dsh" root (rank 400):
#   <dshHome>/skills/<name>/SKILL.md
# That root applies to every session and every project. No cordis.yml edit, no restart
# (the provider watches its roots and refreshes the catalog).
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 decodes BOM-less .ps1 files
# using the ANSI code page (GBK on zh-CN), which corrupts non-ASCII literals.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SkillName = 'agent-dev-workflow',
    [string]$DshHome = $env:DSH_HOME,
    [switch]$Uninstall,
    # The skill bundle root (the directory that contains SKILL.md). Empty => derive it below.
    #
    # Do NOT compute this default inside the param() block. On PS 5.1, parameter defaults are
    # bound BEFORE the script scope exists, so $PSScriptRoot is empty there whenever the script
    # is launched via `powershell -File`; Split-Path then throws on an empty Path. $PSScriptRoot
    # is reliable in the script BODY under both `-File` and `&` invocation.
    [string]$SourceDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $SourceDir) { $SourceDir = Split-Path -Parent $PSScriptRoot }
$SourceDir = (Resolve-Path -LiteralPath $SourceDir).Path

if (-not $DshHome) { $DshHome = Join-Path (Join-Path $HOME '.dsh') }
$TargetDir = Join-Path (Join-Path $DshHome 'skills') $SkillName

# --- Guard: installing the installed copy onto itself deletes the skill (source == target) ---
# Running the copy under <dshHome>\skills\<name>\scripts would set SourceDir = TargetDir, and the
# install step removes TargetDir first -> the source vanishes, nothing is copied, skill is gone.
$srcFull = [System.IO.Path]::GetFullPath($SourceDir).TrimEnd('\', '/')
$dstFull = [System.IO.Path]::GetFullPath($TargetDir).TrimEnd('\', '/')
if ($srcFull -eq $dstFull) {
    throw "refusing to run: source and target are the same directory ($srcFull). Run the copy of install.ps1 that lives in your SOURCE bundle, not the installed one."
}

Write-Host "source : $SourceDir"
Write-Host "target : $TargetDir"

if ($Uninstall) {
    if (Test-Path $TargetDir) {
        if ($PSCmdlet.ShouldProcess($TargetDir, 'Remove installed skill')) {
            Remove-Item -Recurse -Force $TargetDir
            Write-Host 'removed.' -ForegroundColor Yellow
        }
    }
    else {
        Write-Host 'not installed (nothing to do).' -ForegroundColor DarkGray
    }
    return
}

# --- Pre-flight: an invalid bundle would be silently skipped by the provider ---
$skillMd = Join-Path $SourceDir 'SKILL.md'
if (-not (Test-Path $skillMd)) { throw "SKILL.md not found at $skillMd" }

# Read via .NET to drop a BOM; Get-Content -Encoding UTF8 in PS 5.1 keeps it as first char,
# which would make the ^--- anchor below fail and report a bogus "missing frontmatter".
$raw = [System.IO.File]::ReadAllText($skillMd, [System.Text.Encoding]::UTF8)
if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }

# YAML frontmatter keys are CASE-SENSITIVE. PowerShell's -match/-notmatch/-eq ignore case by
# default, so plain -notmatch would happily accept `Name:` / `DESCRIPTION:` and then report a
# successful install -- while DSH's YAML parser finds no `name` and silently skips the skill.
# Every frontmatter key check below therefore uses the case-sensitive forms (-cnotmatch / -cne).
if ($raw -notmatch '(?s)^---\s*\r?\n(.*?)\r?\n---') { throw 'SKILL.md is missing YAML frontmatter' }
$front = $Matches[1]

if ($front -cnotmatch '(?m)^name:\s*(\S+)\s*$') { throw 'frontmatter: missing "name" (note: the key must be lowercase "name:")' }
$declaredName = $Matches[1]
if ($declaredName -cne $SkillName) {
    throw "frontmatter name '$declaredName' does not match skill dir '$SkillName'"
}
# DSH requires kebab-case: /^[a-z0-9]+(?:-[a-z0-9]+)*$/ (dsh-skill registry).
# A name that violates it makes the provider skip the whole skill with only a warning,
# so pre-flight must reject it here instead of reporting a successful install.
#
# Use -cnotmatch (case-SENSITIVE): PowerShell's -match/-notmatch ignore case by default,
# so a plain -notmatch would accept 'Agent-Dev-Workflow' even though [a-z0-9] must reject it.
if ($declaredName -cnotmatch '\A[a-z0-9]+(?:-[a-z0-9]+)*\z') {
    throw "frontmatter name '$declaredName' is not valid kebab-case (^[a-z0-9]+(-[a-z0-9]+)*$); DSH would silently skip this skill"
}
if ($front -cnotmatch '(?m)^description:\s*\S') { throw 'frontmatter: missing "description" (note: the key must be lowercase "description:")' }

Write-Host "frontmatter ok: name=$declaredName" -ForegroundColor Green

# --- Copy the bundle ---
$skillsRoot = Join-Path $DshHome 'skills'
if (-not (Test-Path $skillsRoot)) {
    if ($PSCmdlet.ShouldProcess($skillsRoot, 'Create DSH skills root')) {
        New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($TargetDir, 'Install skill')) {
    if (Test-Path $TargetDir) { Remove-Item -Recurse -Force $TargetDir }
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    Copy-Item -Recurse -Force (Join-Path $SourceDir '*') $TargetDir
}
else {
    # -WhatIf (or a declined prompt): nothing was written, so skip the post-install verification.
    Write-Host 'WhatIf: no files written.' -ForegroundColor DarkGray
    return
}

# --- Verify the install (only reached when files were actually written) ---
$installed = Join-Path $TargetDir 'SKILL.md'
if (-not (Test-Path $installed)) { throw "install verification failed: $installed missing" }
$size = (Get-Item $installed).Length

Write-Host ''
Write-Host "installed: $installed ($size bytes)" -ForegroundColor Green
Write-Host 'files copied:' -ForegroundColor DarkGray
Get-ChildItem -Recurse -File $TargetDir | ForEach-Object {
    Write-Host ('  ' + $_.FullName.Substring($TargetDir.Length + 1))
}
Write-Host ''
Write-Host "The skill '$SkillName' appears in the catalog of new sessions (and the next step of this one)." -ForegroundColor Cyan
Write-Host 'If it does not appear: check DSH_HOME, and that the active preset mounts skill-filesystem.' -ForegroundColor DarkGray
