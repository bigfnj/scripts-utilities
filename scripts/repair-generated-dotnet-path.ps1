#Requires -Version 5.1
<#
.SYNOPSIS
Review an exact User PATH plan for leaked isolated .NET tool entries.
.DESCRIPTION
Default is read-only with respect to the registry. Writes a local review plan.
Apply requires that exact plan, its SHA256, and the explicit interactive SID.
No candidate directory is accessed. Machine PATH is only read and verified.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$Plan,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$PlanSha256,
    [string]$ExpectedUserSid
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repoRoot 'lib\GeneratedDotNetPath.ps1')
$null = Assert-GdpOrdinaryPath $repoRoot -Directory
$folder = Join-Path $repoRoot 'logs\generated-dotnet-path'
$owner = Get-GdpOwner
$user = Get-GdpRegistryState -Scope User -Owner $owner
$machine = Get-GdpRegistryState -Scope Machine -Owner $owner
$producers = Get-GdpProducerPins $repoRoot

if (-not $Apply) {
    if ($Plan -or $PlanSha256 -or $ExpectedUserSid) { throw 'Default dry run takes no apply selectors.' }
    $value = New-GdpPlan -Owner $owner -User $user -Machine $machine -Producers $producers -CapturedUtc ([DateTime]::UtcNow.ToString('o'))
    $logs = Join-Path $repoRoot 'logs'
    if (-not (Test-Path -LiteralPath $logs)) { $null = New-Item -ItemType Directory -Path $logs }
    $null = Assert-GdpOrdinaryPath $logs -Directory
    if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder }
    $null = Assert-GdpOrdinaryPath $folder -Directory
    $work = Join-Path $folder ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work
    $path = Join-Path $work 'plan.json'
    $bytes = ConvertTo-GdpBytes $value
    Assert-GdpSame (Get-GdpOwner) $owner 'dry-run owner'
    Assert-GdpSame (Get-GdpRegistryState -Scope User -Owner $owner) $user 'dry-run User PATH'
    Assert-GdpSame (Get-GdpRegistryState -Scope Machine -Owner $owner) $machine 'dry-run Machine PATH'
    Assert-GdpSame (Get-GdpProducerPins $repoRoot) $producers 'dry-run producers'
    Write-GdpBytes -Path $path -Bytes $bytes
    [pscustomobject]@{ mode = 'dry-run'; registry_writes = 0; plan = $path; sha256 = Get-GdpByteHash $bytes
        removed = @($value.removed).Count; ready_to_apply = $value.ready_to_apply; owner = $owner
        user_characters_before = $user.raw.Length; user_characters_after = $value.after_user.raw.Length } | ConvertTo-Json -Depth 5
    exit 0
}

if (-not $Plan -or -not $PlanSha256 -or -not $ExpectedUserSid) { throw 'Apply requires -Plan, -PlanSha256 and -ExpectedUserSid.' }
$path = [IO.Path]::GetFullPath($Plan)
if (-not (Test-SUSourcePath $path) -or [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($path)) -cne $folder -or
    [IO.Path]::GetFileName($path) -cne 'plan.json' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($path)) -cnotmatch '^[0-9a-f]{32}$') {
    throw 'Apply requires one canonical ignored generated-dotnet-path/UUID/plan.json.'
}
$bytes = Read-GdpBytes $path
if ((Get-GdpByteHash $bytes) -cne $PlanSha256) { throw 'Explicit reviewed PATH plan SHA256 differs.' }
$value = ConvertFrom-GdpJson ([Text.Encoding]::UTF8.GetString($bytes))
Assert-GdpPlan -Plan $value -Owner $owner -User $user -Machine $machine -Producers $producers -ExpectedUserSid $ExpectedUserSid
$work = [IO.Path]::GetDirectoryName($path)
if ((Test-Path -LiteralPath (Join-Path $work 'before-apply.json')) -or (Test-Path -LiteralPath (Join-Path $work 'applied.json'))) {
    throw 'Existing PATH application artifacts prevent a repeated or ambiguous apply.'
}
$backup = [pscustomobject][ordered]@{ schema = 'su-generated-dotnet-path-backup-1'; plan_sha256 = $PlanSha256
    captured_utc = [DateTime]::UtcNow.ToString('o'); owner = $owner; user = $user; machine = $machine; producer_sha256 = $producers }
$backupBytes = ConvertTo-GdpBytes $backup
$backupPath = Join-Path $work 'before-apply.json'
Write-GdpBytes -Path $backupPath -Bytes $backupBytes
if ((Get-GdpByteHash (Read-GdpBytes $backupPath)) -cne (Get-GdpByteHash $backupBytes)) { throw 'Exclusive PATH backup readback differs.' }
if ((Get-GdpByteHash (Read-GdpBytes $path)) -cne $PlanSha256) { throw 'Reviewed PATH plan changed after backup.' }
Assert-GdpPlan -Plan $value -Owner (Get-GdpOwner) -User (Get-GdpRegistryState -Scope User -Owner $owner) `
    -Machine (Get-GdpRegistryState -Scope Machine -Owner $owner) -Producers (Get-GdpProducerPins $repoRoot) -ExpectedUserSid $ExpectedUserSid
Set-GdpUserPath -Owner $owner -Before $user -After $value.after_user -Machine $machine
$result = [pscustomobject][ordered]@{ schema = 'su-generated-dotnet-path-applied-1'; outcome = 'applied'; scope = 'User'
    plan_sha256 = $PlanSha256; backup = $backupPath; backup_sha256 = Get-GdpByteHash $backupBytes
    owner = $owner; removed = 56; after_user = $value.after_user; machine_unchanged = $true }
Write-GdpBytes -Path (Join-Path $work 'applied.json') -Bytes (ConvertTo-GdpBytes $result)
$result | ConvertTo-Json -Depth 8
