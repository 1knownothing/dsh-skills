# cycle-test.ps1 - prove the ON/OFF toggle is idempotent and never drifts.
#
# The bug this guards against: an earlier design edited the SOURCE SKILL.md to toggle, which
# appended a blank line and rewrote line endings on every round trip (19206 -> 19259 -> 19475
# -> 19532 bytes). Nothing failed loudly; the file just silently rotted.
#
# Assertions:
#   1. the source SKILL.md is byte-identical before and after N ON/OFF cycles
#   2. OFF puts both flags in the DEPLOYED copy; ON removes both
#   3. the source file never contains the flags (the source stays enabled in git)
#
# Usage: powershell -ExecutionPolicy Bypass -File cycle-test.ps1
# Exit 0 = pass.

[CmdletBinding()]
param(
    [string]$SkillName = 'agent-dev-workflow',
    [string]$DshHome = $env:DSH_HOME,
    [int]$Cycles = 3
)

$ErrorActionPreference = 'Stop'
if (-not $DshHome) { $DshHome = Join-Path (Join-Path $HOME '.dsh') }

$source = Join-Path (Join-Path $PSScriptRoot $SkillName) 'SKILL.md'
$marker = Join-Path (Join-Path $PSScriptRoot $SkillName) '.disabled'
$deployed = Join-Path (Join-Path (Join-Path $DshHome 'skills') $SkillName) 'SKILL.md'
$toggle = Join-Path $PSScriptRoot 'toggle.ps1'

$pass = 0
$fail = 0
function Check([string]$label, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host "[PASS] $label" }
    else { $script:fail++; Write-Host "[FAIL] $label $detail" -ForegroundColor Red }
}

function Hash([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
function HasFlag([string]$p, [string]$key, [string]$val) {
    $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    return [regex]::IsMatch($t, "(?m)^$([regex]::Escape($key)):\s*$val\s*$")
}

# Start from a known state.
if (Test-Path $marker) { Remove-Item -Force $marker }
& $toggle -On -SkillName $SkillName -DshHome $DshHome *> $null
$sourceHash0 = Hash $source
$size0 = (Get-Item -LiteralPath $source).Length
Write-Host "baseline source: $size0 bytes, sha $($sourceHash0.Substring(0,16))"
Write-Host ''

for ($i = 1; $i -le $Cycles; $i++) {
    Write-Host "--- cycle $i ---"

    & $toggle -Off -SkillName $SkillName -DshHome $DshHome *> $null
    Check "cycle ${i}: deployed has disable-model-invocation: true" (HasFlag $deployed 'disable-model-invocation' 'true')
    Check "cycle ${i}: deployed has user-invocable: false" (HasFlag $deployed 'user-invocable' 'false')
    Check "cycle ${i}: source stays clean (no flags)" (-not (HasFlag $source 'disable-model-invocation' 'true'))
    Check "cycle ${i}: source unchanged during OFF" ((Hash $source) -eq $sourceHash0)

    & $toggle -On -SkillName $SkillName -DshHome $DshHome *> $null
    Check "cycle ${i}: deployed has no disable flag" (-not (HasFlag $deployed 'disable-model-invocation' 'true'))
    Check "cycle ${i}: deployed has no user-invocable flag" (-not (HasFlag $deployed 'user-invocable' 'false'))
    Check "cycle ${i}: source still unchanged after ON" ((Hash $source) -eq $sourceHash0)
    Check "cycle ${i}: deployed matches source when ON" ((Hash $deployed) -eq (Hash $source))
}

$sizeN = (Get-Item -LiteralPath $source).Length
Write-Host ''
Write-Host "source after $Cycles cycles: $sizeN bytes (baseline $size0)"
Check 'source size unchanged after all cycles' ($sizeN -eq $size0) "(got $sizeN, want $size0)"
Check 'source sha unchanged after all cycles' ((Hash $source) -eq $sourceHash0)

# Reverse control: the flag check must be able to FAIL. Write a file without the flag and
# confirm HasFlag reports false, so a green result above means something.
$probe = Join-Path $env:TEMP "cycle-test-probe-$PID.md"
[System.IO.File]::WriteAllText($probe, "---`nname: x`n---`nbody`n", (New-Object System.Text.UTF8Encoding($false)))
Check 'reverse control: HasFlag reports false when the flag is absent' (-not (HasFlag $probe 'disable-model-invocation' 'true'))
[System.IO.File]::WriteAllText($probe, "---`nname: x`ndisable-model-invocation: true`n---`nbody`n", (New-Object System.Text.UTF8Encoding($false)))
Check 'reverse control: HasFlag reports true when the flag is present' (HasFlag $probe 'disable-model-invocation' 'true')
Remove-Item -Force $probe -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "RESULT: pass=$pass fail=$fail"
exit $(if ($fail -eq 0) { 0 } else { 1 })
