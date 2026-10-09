# toggle.ps1 - turn the installed skill ON or OFF.
#
# The source bundle is NEVER rewritten. The on/off state is a marker file:
#
#   <source>\<SkillName>\.disabled     present -> OFF, absent -> ON
#
# OFF renders `disable-model-invocation: true` and `user-invocable: false` into the DEPLOYED
# copy, which removes the skill from the model-facing catalog AND the human-facing command
# surface (source: dsh-skill-filesystem, parseInvocationPolicy). Nothing is deleted.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File toggle.ps1 -Off      # close it
#   powershell -ExecutionPolicy Bypass -File toggle.ps1 -On       # open it
#   powershell -ExecutionPolicy Bypass -File toggle.ps1 -Status   # show current state
#
# Harder off (if the model somehow still sees it): move the bundle out of the scanned root.
#   Move-Item "<dshHome>\skills\agent-dev-workflow" "<dshHome>\skills\.system\"
# The provider skips the `.system` directory entirely (skipSystem in dsh-skill-filesystem).
#
# NOTE: keep this file ASCII-only (PS 5.1 decodes BOM-less .ps1 using the ANSI code page).

[CmdletBinding()]
param(
    [string]$SkillName = 'agent-dev-workflow',
    [string]$DshHome = $env:DSH_HOME,
    [switch]$Off,
    [switch]$On,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
if (-not $DshHome) { $DshHome = Join-Path (Join-Path $HOME '.dsh') }
$SourceDir = Join-Path $PSScriptRoot $SkillName
$marker = Join-Path $SourceDir '.disabled'
if (-not (Test-Path (Join-Path $SourceDir 'SKILL.md'))) { throw "SKILL.md not found in $SourceDir" }

$isOff = Test-Path $marker

if ($Status -or (-not $Off -and -not $On)) {
    Write-Host "skill   : $SkillName"
    Write-Host "source  : $SourceDir"
    Write-Host "marker  : $marker"
    Write-Host ''
    if ($isOff) {
        Write-Host 'STATE: OFF (marker present; deployed copy hides the skill from model and humans)' -ForegroundColor Yellow
    }
    else {
        Write-Host 'STATE: ON (no marker; available in every conversation)' -ForegroundColor Green
    }
    if (-not $Off -and -not $On) {
        Write-Host ''
        Write-Host 'Use -Off to disable or -On to enable.' -ForegroundColor DarkGray
    }
    exit 0
}

if ($Off -and $On) { throw 'pass either -Off or -On, not both' }

if ($Off) {
    if ($isOff) { Write-Host 'already OFF -- no change.' -ForegroundColor DarkGray }
    else {
        New-Item -ItemType File -Path $marker -Force | Out-Null
        Write-Host 'marker written -> OFF' -ForegroundColor Cyan
    }
}
else {
    if (-not $isOff) { Write-Host 'already ON -- no change.' -ForegroundColor DarkGray }
    else {
        Remove-Item -Force $marker
        Write-Host 'marker removed -> ON' -ForegroundColor Cyan
    }
}

# Render + install + verify, so the deployed copy immediately reflects the new state.
$sync = Join-Path $PSScriptRoot 'sync.ps1'
if (Test-Path $sync) {
    Write-Host ''
    & $sync -SkillName $SkillName -DshHome $DshHome
    exit $LASTEXITCODE
}
Write-Host 'sync.ps1 not found; render+install manually.' -ForegroundColor Yellow
exit 0
