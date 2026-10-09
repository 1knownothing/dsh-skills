# build-deploy.ps1 - render the DEPLOYED skill from the clean source bundle.
#
# Why this exists
# ---------------
# The source SKILL.md is the canonical, always-enabled version and is never rewritten. The
# on/off state lives in a separate marker file:
#
#     .disabled      present  -> the deployed SKILL.md gets disable-model-invocation: true
#                                 and user-invocable: false (skill hidden, nothing deleted)
#                    absent   -> the deployed SKILL.md is the source, byte for byte
#
# Editing the source in place to toggle is what caused drift (a rewritten frontmatter gained a
# blank line and changed line endings on every round trip). Rendering the deployed copy from a
# clean source + a marker is idempotent by construction: the output depends only on those two
# inputs, so ON -> OFF -> ON reproduces the original bytes exactly.
#
# Output: deploy\<SkillName>\  (staging tree; sync.ps1 compares and installs it)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File build-deploy.ps1
#
# NOTE: keep this file ASCII-only (PS 5.1 decodes BOM-less .ps1 using the ANSI code page).

[CmdletBinding()]
param(
    [string]$SkillName = 'agent-dev-workflow',
    [string]$SourceDir = '',
    [string]$OutRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $SourceDir) { $SourceDir = Join-Path $PSScriptRoot $SkillName }
$SourceDir = (Resolve-Path -LiteralPath $SourceDir).Path
if (-not $OutRoot) { $OutRoot = Join-Path $PSScriptRoot 'deploy' }
$out = Join-Path $OutRoot $SkillName

$marker = Join-Path $SourceDir '.disabled'
$disabled = Test-Path $marker

# Fresh staging tree: a plain copy of the source, minus the marker itself.
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force -Path $out | Out-Null
Get-ChildItem -LiteralPath $SourceDir -Force | Where-Object { $_.Name -ne '.disabled' } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $out -Recurse -Force
}

if (-not $disabled) {
    Write-Host "state: ON  (no .disabled marker; deployed copy == source)" -ForegroundColor Green
    exit 0
}

# --- Render the disabled frontmatter ---
$md = Join-Path $out 'SKILL.md'
$raw = [System.IO.File]::ReadAllText($md, [System.Text.Encoding]::UTF8)
$bom = ''
if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $bom = [string][char]0xFEFF; $raw = $raw.Substring(1) }

# Preserve the source's line endings.
$nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }

$m = [regex]::Match($raw, '(?s)^---[ \t]*\r?\n(.*?)\r?\n---[ \t]*\r?\n')
if (-not $m.Success) { throw "SKILL.md is missing YAML frontmatter: $md" }
$front = $m.Groups[1].Value
$rest = $raw.Substring($m.Length)

# Normalize to LF, strip any pre-existing invocation flags.
$body = [regex]::Replace($front, "`r`n", "`n")
foreach ($key in @('disable-model-invocation', 'user-invocable')) {
    $body = [regex]::Replace($body, "(?m)\r?\n?^$([regex]::Escape($key)):[^\n]*$", '')
    $body = [regex]::Replace($body, "(?m)^[ \t]*\n", '')   # collapse any blank line left behind
}

# Insert the two flags as lines right after `name:`.
# Do NOT use a regex replacement string here: in PowerShell "name:`$1" interpolates $1 as a
# positional variable and emits the literal text "name:$1". Line insertion avoids the trap.
$lines = [System.Collections.Generic.List[string]]($body -split "`n")
$nameIndex = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^name:[ \t]*\S') { $nameIndex = $i; break }
}
if ($nameIndex -lt 0) { throw 'frontmatter has no "name:" line' }
$lines.Insert($nameIndex + 1, 'disable-model-invocation: true')
$lines.Insert($nameIndex + 1, 'user-invocable: false')
$body = ($lines -join "`n")
if ($body -notmatch 'disable-model-invocation') { throw 'failed to insert disable-model-invocation' }

# Back to the source's line endings and rewrite. The opening "---" delimiter is re-emitted
# here; $front holds only the body BETWEEN the two delimiters, so it must be added back.
$rendered = "---$nl" + ($body -replace "`n", $nl) + "$nl---$nl" + $rest
[System.IO.File]::WriteAllText($md, $bom + $rendered, (New-Object System.Text.UTF8Encoding($false)))

# Keep the marker out of the deployed tree.
if (Test-Path (Join-Path $out '.disabled')) { Remove-Item -Force (Join-Path $out '.disabled') }

Write-Host 'state: OFF (rendered hidden frontmatter into the deployed copy; source untouched)' -ForegroundColor Yellow
