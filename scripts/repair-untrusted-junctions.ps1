#Requires -Version 5.1
<#
.SYNOPSIS
    Find directory junctions an elevated process cannot follow, and recreate them so it can.

.DESCRIPTION
    Windows refuses to let an ELEVATED or SYSTEM process traverse a junction that was created with
    a non-admin token (WinError 448, "untrusted mount point"). An unelevated shell follows the same
    junction fine, so the owner never sees it, while an agent host that runs elevated finds, for
    example, a venv whose base interpreter "does not exist". lib\JunctionTrust.ps1 and
    docs\junction-trust.md hold the measurements.

    DEFAULT IS A DRY RUN. It sweeps without following any link, writes a plan to
    logs\junction-trust\<id>\plan.json and prints it. -Apply -Plan <that file> recreates exactly
    the plan's 'recreate' entries, re-checking each one first, and writes applied.json beside the
    plan. A plan is applied once. Nothing that is not a planned junction is ever changed.

    MUST RUN ELEVATED, and refuses otherwise: from an unelevated shell an untrusted junction looks
    perfectly healthy, so a sweep there would report a clean machine it never examined.

    THE POSITIVE CONTROL RUNS EVERY TIME. Before trusting its own verdicts the script makes a
    junction with a non-admin token and requires the classifier to call it untrusted. If that does
    not happen it says so and exits 3, because a sweep that cannot detect the condition reads
    exactly like a workstation that does not have it.

    EXIT CODES
        0  done, positive control fired
        1  a junction was LOST or could not be verified, or the plan was refused
        2  not elevated: nothing was examined
        3  done, but the positive control did not fire, so a clean result proves nothing

.EXAMPLE
    .\scripts\repair-untrusted-junctions.ps1

    Sweeps every ready fixed drive and writes a plan. Nothing is changed.

.EXAMPLE
    .\scripts\repair-untrusted-junctions.ps1 -Root D:\ -Exclude D:\sync

    Sweeps one drive, also skipping D:\sync and everything under it.

.EXAMPLE
    .\scripts\repair-untrusted-junctions.ps1 -Apply -Plan .\logs\junction-trust\<id>\plan.json

    Recreates the plan's 'recreate' entries.
#>
[CmdletBinding()]
param(
    # Where to sweep. Default: every ready fixed drive.
    [string[]]$Root,
    # Skipped in addition to the built-in exclusions (see Get-JtDefaultExclusions).
    [string[]]$Exclude = @(),
    [switch]$Apply,
    [string]$Plan
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repoRoot 'lib\JunctionTrust.ps1')
$planFolder = Join-Path $repoRoot 'logs\junction-trust'

if ($Apply -and ($Root -or $Exclude.Count)) { throw '-Apply acts on the plan alone; -Root and -Exclude belong to the dry run that made it.' }
if (-not $Apply -and $Plan) { throw '-Plan is only meaningful with -Apply.' }

if (-not (Test-JtElevated)) {
    Write-Host 'NOT ELEVATED: nothing was examined.' -ForegroundColor Yellow
    Write-Host 'An unelevated shell follows untrusted junctions without complaint, so a sweep from here would'
    Write-Host 'report a clean machine it never looked at. Re-run from an elevated shell.'
    exit 2
}

$control = New-JtUntrustedWitness
foreach ($left in @(Remove-JtWitness -Root $control.Root)) { Write-Host "could not remove witness file: $left" -ForegroundColor Yellow }
if ($control.Fired) {
    Write-Host 'positive control: a junction made with a non-admin token was detected as untrusted' -ForegroundColor DarkGray
} else {
    Write-Host ('POSITIVE CONTROL DID NOT FIRE ({0}): {1}' -f $control.Status, $control.Detail) -ForegroundColor Red
    Write-Host 'Until it does, a sweep that finds nothing proves nothing.' -ForegroundColor Red
}
$doneCode = if ($control.Fired) { 0 } else { 3 }

function Write-JtJson {
    param([string]$Path, $Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8) + "`n", (New-Object Text.UTF8Encoding $false))
}

if (-not $Apply) {
    if (-not $Root) {
        $Root = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
                  ForEach-Object { $_.RootDirectory.FullName })
    }
    $exclusions = @(Get-JtDefaultExclusions -Root $Root) + @($Exclude | Where-Object { $_ })
    Write-Host ('sweeping {0}, never following a link, {1} exclusions' -f ($Root -join ' '), $exclusions.Count)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $found = Find-JtJunctions -Root $Root -Exclude $exclusions
    $result = New-JtPlan -Junctions $found.Junctions
    $clock.Stop()

    $value = [pscustomobject][ordered]@{
        schema       = 'su-junction-trust-plan-1'
        captured_utc = [DateTime]::UtcNow.ToString('o')
        powershell   = $PSVersionTable.PSVersion.ToString()
        control      = [pscustomobject][ordered]@{ fired = [bool]$control.Fired; status = $control.Status; detail = [string]$control.Detail }
        roots        = @($Root)
        exclusions   = @($exclusions)
        directories  = $found.Directories
        unreadable   = @($found.Unreadable)
        junctions    = @($found.Junctions).Count
        trusted      = $result.Trusted
        entries      = @($result.Entries)
    }
    $work = Join-Path $planFolder ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work -Force
    $planPath = Join-Path $work 'plan.json'
    Write-JtJson -Path $planPath -Value $value

    $entries = @($result.Entries)
    $recreate = @($entries | Where-Object { $_.decision -eq 'recreate' })
    Write-Host ''
    Write-Host ('{0} directories listed in {1:N0} s, {2} unreadable' -f $found.Directories, $clock.Elapsed.TotalSeconds, @($found.Unreadable).Count)
    Write-Host ('{0} junctions: {1} trusted, {2} to recreate, {3} dangling, {4} denied, {5} error' -f @($found.Junctions).Count,
        $result.Trusted, $recreate.Count, @($entries | Where-Object { $_.decision -eq 'dangling' }).Count,
        @($entries | Where-Object { $_.decision -eq 'denied' }).Count, @($entries | Where-Object { $_.decision -eq 'error' }).Count)
    foreach ($u in @($found.Unreadable | Select-Object -First 5)) { Write-Host "  could not list: $u" -ForegroundColor Yellow }
    $shown = 40
    foreach ($e in @($recreate | Select-Object -First $shown)) { Write-Host ('  recreate  {0} -> {1}' -f $e.path, $e.target) }
    if ($recreate.Count -gt $shown) { Write-Host ('  ... and {0} more, all listed in the plan' -f ($recreate.Count - $shown)) }
    Write-Host ''
    Write-Host "plan: $planPath"
    if ($recreate.Count) { Write-Host ('apply: .\scripts\repair-untrusted-junctions.ps1 -Apply -Plan "{0}"' -f $planPath) }
    exit $doneCode
}

if (-not $Plan) { throw '-Apply requires -Plan, the plan.json a dry run wrote under logs\junction-trust.' }
$planPath = [IO.Path]::GetFullPath($Plan)
$work = [IO.Path]::GetDirectoryName($planPath)
if (-not [string]::Equals([IO.Path]::GetDirectoryName($work), $planFolder, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($work) -notmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFileName($planPath) -ne 'plan.json') {
    Write-Host "REFUSED: $planPath is not a plan written by this script under $planFolder" -ForegroundColor Red
    exit 1
}
$appliedPath = Join-Path $work 'applied.json'
if (Test-Path -LiteralPath $appliedPath) {
    Write-Host "REFUSED: this plan was already applied ($appliedPath). Run a new dry run." -ForegroundColor Red
    exit 1
}
$value = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$value.schema -ne 'su-junction-trust-plan-1') {
    Write-Host "REFUSED: unknown plan schema '$($value.schema)'" -ForegroundColor Red
    exit 1
}

$outcomes = New-Object 'Collections.Generic.List[object]'
foreach ($e in @($value.entries | Where-Object { $_.decision -eq 'recreate' })) {
    $o = Invoke-JtRecreate -Path ([string]$e.path) -Target ([string]$e.target)
    $outcomes.Add($o)
    $colour = if ($o.outcome -eq 'recreated') { 'DarkGray' } elseif ($o.outcome -like 'skipped-*') { 'Yellow' } else { 'Red' }
    Write-Host ('{0,-24} {1} {2}' -f $o.outcome, $o.path, $o.detail) -ForegroundColor $colour
}
Write-JtJson -Path $appliedPath -Value ([pscustomobject][ordered]@{
    schema = 'su-junction-trust-applied-1'; applied_utc = [DateTime]::UtcNow.ToString('o'); plan = $planPath
    control = [pscustomobject][ordered]@{ fired = [bool]$control.Fired; status = $control.Status }
    outcomes = @($outcomes.ToArray()) })

$tally = @($outcomes.ToArray() | Group-Object outcome | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count })
Write-Host ''
Write-Host ('applied: {0}' -f $(if ($tally.Count) { $tally -join ' ' } else { 'nothing to recreate' }))
Write-Host "record: $appliedPath"
if (@($outcomes.ToArray() | Where-Object { $_.outcome -eq 'LOST' -or $_.outcome -eq 'recreated-unverified' }).Count) { exit 1 }
exit $doneCode
