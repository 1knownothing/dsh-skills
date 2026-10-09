# sync.ps1 - render, install, and verify the deployed skill.
#
# Pipeline:  source bundle  --build-deploy.ps1-->  deploy\<name>  --install.ps1-->  <dshHome>\skills\<name>
#
# The rendering step exists because the source is never rewritten to toggle the skill; see
# build-deploy.ps1. Run this after every source edit OR toggle.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sync.ps1            # render + install + verify
#   powershell -ExecutionPolicy Bypass -File sync.ps1 -CheckOnly # verify only, change nothing
#
# Exit codes: 0 = deployed copy matches the rendered bundle, non-zero = mismatch or failure.
#
# NOTE: keep this file ASCII-only (PS 5.1 decodes BOM-less .ps1 using the ANSI code page).

[CmdletBinding()]
param(
    [string]$SkillName = 'agent-dev-workflow',
    [string]$DshHome = $env:DSH_HOME,
    [string]$SourceDir = '',
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
if (-not $DshHome) { $DshHome = Join-Path (Join-Path $HOME '.dsh') }
if (-not $SourceDir) { $SourceDir = Join-Path $PSScriptRoot $SkillName }
$SourceDir = (Resolve-Path -LiteralPath $SourceDir).Path
$TargetDir = Join-Path (Join-Path $DshHome 'skills') $SkillName
$StageRoot = Join-Path $PSScriptRoot 'deploy'
$StageDir = Join-Path $StageRoot $SkillName

Write-Host "source : $SourceDir"
Write-Host "target : $TargetDir"

if (-not $CheckOnly) {
    Write-Host ''
    Write-Host '--- render ---' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'build-deploy.ps1') -SkillName $SkillName -SourceDir $SourceDir -OutRoot $StageRoot
    if (-not $?) { throw 'build-deploy.ps1 failed' }

    Write-Host ''
    Write-Host '--- install ---' -ForegroundColor Cyan
    $installer = Join-Path $SourceDir 'scripts\install.ps1'
    if (-not (Test-Path $installer)) { throw "installer not found: $installer" }
    & $installer -SkillName $SkillName -DshHome $DshHome -SourceDir $StageDir
    if (-not $?) { throw 'installer reported failure' }
}

# --- Verify: every RENDERED file must exist in the deployment with the same SHA256 ---
Write-Host ''
Write-Host '--- verify ---' -ForegroundColor Cyan
if (-not (Test-Path $StageDir)) { throw "rendered bundle missing: $StageDir (run without -CheckOnly first)" }
if (-not (Test-Path $TargetDir)) { throw "deployed skill missing: $TargetDir" }

$srcFiles = Get-ChildItem -Recurse -File $StageDir | ForEach-Object { $_.FullName.Substring($StageDir.Length + 1) }
$dstFiles = Get-ChildItem -Recurse -File $TargetDir | ForEach-Object { $_.FullName.Substring($TargetDir.Length + 1) }

$mismatch = 0
foreach ($f in $srcFiles) {
    $sp = Join-Path $StageDir $f
    $dp = Join-Path $TargetDir $f
    if (-not (Test-Path $dp)) { Write-Host "  MISSING  $f" -ForegroundColor Red; $mismatch++; continue }
    if ((Get-FileHash $sp -Algorithm SHA256).Hash -ne (Get-FileHash $dp -Algorithm SHA256).Hash) {
        Write-Host "  DIFF     $f" -ForegroundColor Red; $mismatch++
    }
}
foreach ($f in $dstFiles) {
    if ($srcFiles -notcontains $f) { Write-Host "  EXTRA    $f (not in rendered bundle)" -ForegroundColor Yellow; $mismatch++ }
}

if ($mismatch -gt 0) {
    Write-Host ''
    Write-Host "FAIL: $mismatch file(s) differ -- the deployed skill is NOT what the source renders to." -ForegroundColor Red
    exit 1
}

Write-Host ("  OK: $($srcFiles.Count)/$($srcFiles.Count) files byte-identical") -ForegroundColor Green

# --- Sanity checks on the DEPLOYED frontmatter ---
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

$off = ($front -match '(?m)^disable-model-invocation:\s*true') -and ($front -match '(?m)^user-invocable:\s*false')
Write-Host ("  state: $(if ($off) { 'OFF (hidden from model and human commands)' } else { 'ON (available in every conversation)' })") -ForegroundColor $(if ($off) { 'Yellow' } else { 'Green' })

Write-Host ''
Write-Host 'PASS: deployment matches the rendered source.' -ForegroundColor Green
exit 0
