#Requires -Version 5.1
<#
.SYNOPSIS
Add argument-preserving EXE companions to existing understood EXE-backed shims.
.DESCRIPTION
Keeps each existing .cmd, selected target, package provenance and PATH unchanged.
No installs or elevated steps. Batch targets and unrecognized prologues are reported
and left as explicit CMD wrappers. Verified owned obsolete companions are removed;
unowned files and incomplete pairs are refused. Run test-host-projection.ps1 first.
.EXAMPLE
.\scripts\repair-native-shims.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Root = $(if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }),
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\ShimFormat.ps1')
$bin = Join-Path $Root 'native\bin'
Assert-NativeShimPath -Path $bin
if (-not (Test-Path -LiteralPath $bin -PathType Container)) { throw "Toolbox bin directory is missing: $bin" }
if (-not $DryRun) {
    . (Join-Path $PSScriptRoot '..\lib\common.ps1')
    $projection = Test-HostPathProjection -Path $bin
    if ($null -eq $projection.IsProjected -or $projection.IsProjected) { throw 'Toolbox view is projected or unknown. Use the documented unprojected workflow.' }
}
[void](Get-NativeShimCacheState -Directory $bin)
$published = 0
$batch = 0
$skipped = 0
foreach ($wrapper in Get-ChildItem -LiteralPath $bin -Filter '*.cmd' -File) {
    try { Assert-NativeShimPath -Path $wrapper.FullName }
    catch {
        $skipped++
        Write-Host "SKIP $($wrapper.Name): protected, linked or unresolvable path"
        continue
    }
    $owned = Get-NativeShimCompanionState -Wrapper $wrapper.FullName
    $configuration = Get-NativeShimConfiguration -Lines @(Get-Content -LiteralPath $wrapper.FullName -Encoding UTF8)
    if (-not $configuration) {
        $batch++
        if ($DryRun -and $null -ne $owned) {
            Write-Host "PLAN remove owned obsolete companion: $($wrapper.BaseName).exe and .shim.json"
        } elseif (-not $DryRun) {
            [void](Install-NativeShim -Wrapper $wrapper.FullName)
        }
        Write-Host "BATCH $($wrapper.Name): explicit CMD wrapper; no native companion"
        continue
    }
    if ($DryRun) { Write-Host "PLAN $($wrapper.BaseName).exe -> $($configuration.target)" }
    else {
        [void](Install-NativeShim -Wrapper $wrapper.FullName)
        $failure = Test-NativeShim -Wrapper $wrapper.FullName
        if ($failure) { throw "$($wrapper.Name): $failure" }
        Write-Host "OK $($wrapper.BaseName).exe -> $($configuration.target)"
    }
    $published++
}
Write-Host "native companions=$published explicit batch wrappers=$batch skipped=$skipped dry_run=$([bool]$DryRun)"