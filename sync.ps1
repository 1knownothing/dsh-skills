# sync.ps1 - reinstall the skill and verify the deployed copy matches the source.
#
# Why this exists: the installed skill is a COPY. Editing the source does nothing until you
# reinstall, and "remember to reinstall" is exactly the kind of rule that gets forgotten.
# Run this after every source edit; a non-zero exit means source and deployment disagree.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sync.ps1            # reinstall + verify
#   powershell -ExecutionPolicy Bypass -File sync.ps1 -CheckOnly # verify only, change nothing
#
# Exit codes: 0 = deployed copy matches source, non-zero = mismatch or failure.
#
# NOTE: keep this file ASCII-only (PS 5.1 decodes BOM-less .ps1 using the ANSI code page).

[CmdletBinding()]
param(
    [string]$SkillName = 'agent-dev-workflow',
    [string]$DshHome = $env:DSH_HOME,
    # The source bundle (contains SKILL.md). Empty => <this script's dir>\<SkillName>.
    [string]$SourceDir = '',
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
if (-not $DshHome) { $DshHome = Join-Path (Join-Path $HOME '.dsh') }
if (-not $SourceDir) { $SourceDir = Join-Path $PSScriptRoot $SkillName }
$SourceDir = (Resolve-Path -LiteralPath $SourceDir).Path
$TargetDir = Join-Path (Join-Path $DshHome 'skills') $SkillName
$installer = Join-Path $SourceDir 'scripts\install.ps1'

if (-not (Test-Path $installer)) { throw "installer not found: $installer" }

Write-Host "source : $SourceDir"
Write-Host "target : $TargetDir"

if (-not $CheckOnly) {
    Write-Host ''
    Write-Host '--- reinstall ---' -ForegroundColor Cyan
    & $installer -SkillName $SkillName -DshHome $DshHome -SourceDir $SourceDir
    if (-not $?) { throw 'installer reported failure' }
}

# --- Verify: every source file must exist in the deployment with the same SHA256 ---
Write-Host ''
Write-Host '--- verify ---' -ForegroundColor Cyan
if (-not (Test-Path $TargetDir)) { throw "deployed skill missing: $TargetDir" }

$srcFiles = Get-ChildItem -Recurse -File $SourceDir | ForEach-Object { $_.FullName.Substring($SourceDir.Length + 1) }
$dstFiles = Get-ChildItem -Recurse -File $TargetDir | ForEach-Object { $_.FullName.Substring($TargetDir.Length + 1) }

$mismatch = 0
foreach ($f in $srcFiles) {
    $sp = Join-Path $SourceDir $f
    $dp = Join-Path $TargetDir $f
    if (-not (Test-Path $dp)) { Write-Host "  MISSING  $f" -ForegroundColor Red; $mismatch++; continue }
    if ((Get-FileHash $sp -Algorithm SHA256).Hash -ne (Get-FileHash $dp -Algorithm SHA256).Hash) {
        Write-Host "  DIFF     $f" -ForegroundColor Red; $mismatch++
    }
}
foreach ($f in $dstFiles) {
    if ($srcFiles -notcontains $f) { Write-Host "  EXTRA    $f (not in source)" -ForegroundColor Yellow; $mismatch++ }
}

if ($mismatch -gt 0) {
    Write-Host ''
    Write-Host "FAIL: $mismatch file(s) differ -- the deployed skill is NOT the source you edited." -ForegroundColor Red
    exit 1
}

Write-Host ("  OK: $($srcFiles.Count)/$($srcFiles.Count) files byte-identical") -ForegroundColor Green

# --- Cheap sanity checks that catch silent-skip failures before DSH does ---
$skillMd = Join-Path $TargetDir 'SKILL.md'
$raw = [System.IO.File]::ReadAllText($skillMd, [System.Text.Encoding]::UTF8)
if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
if ($raw -notmatch '(?s)^---\s*\r?\n(.*?)\r?\n---') { Write-Host 'FAIL: deployed SKILL.md has no frontmatter' -ForegroundColor Red; exit 1 }
$front = $Matches[1]
if ($front -cnotmatch '(?m)^name:\s*(\S+)\s*$') { Write-Host 'FAIL: deployed SKILL.md missing lowercase "name:"' -ForegroundColor Red; exit 1 }
$name = $Matches[1]
if ($name -cnotmatch '\A[a-z0-9]+(?:-[a-z0-9]+)*\z') { Write-Host "FAIL: name '$name' is not kebab-case; DSH will skip this skill" -ForegroundColor Red; exit 1 }
if ($front -cnotmatch '(?m)^description:\s*\S') { Write-Host 'FAIL: deployed SKILL.md missing lowercase "description:"' -ForegroundColor Red; exit 1 }

# The model-facing catalog truncates the description at 500 UTF-16 units.
$desc = [regex]::Match($front, '(?ms)^description:\s*\|?\s*\r?\n?(.*)$').Groups[1].Value
$flat = ($desc -replace '\s+', ' ').Trim()
Write-Host ("  description: $($flat.Length) chars (catalog limit 500)")
if ($flat.Length -gt 500) { Write-Host '  WARN: description will be truncated in the catalog' -ForegroundColor Yellow }

Write-Host ''
Write-Host 'PASS: deployment matches source.' -ForegroundColor Green
exit 0
