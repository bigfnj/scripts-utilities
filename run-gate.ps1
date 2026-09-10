#Requires -Version 5.1
<#
.SYNOPSIS
    Run every check this repository has, in one command, and give one answer.

.DESCRIPTION
    Companion to pc-maintenance\run-gate.ps1, deliberately the same shape so that "run the
    gate" means the same thing in both repositories.

    THREE RULES, each earned from a real failure here:

    1. A MISSING SUITE IS A FAILURE, never a warning. This repo's smoke test spent a day
       printing "triage test suite not found" and passing anyway - the path held a literal TAB
       where \tests belonged. It reported a safety it had never checked.

    2. A SUITE THAT PRINTS NO TALLY IS A FAILURE, even when it exits 0. A PowerShell script
       with no explicit exit inherits the exit code of the last native command it ran;
       fresh-toolbox-setup-runner.ps1 reads bootstrap.ps1's status that way and can be told a
       lie by a probe that ran minutes earlier. The tally is independent evidence.

    3. EVERY SUITE RUNS UNDER powershell.exe, NEVER pwsh, regardless of the launching host.
       The weekly forensics task runs Windows PowerShell 5.1. This matters more here than
       anywhere: smoke-test.ps1 contains a "must parse under 5.1" gate that used to call the
       parser IN-PROCESS, so running it from pwsh silently checked 7's grammar instead - the
       one check whose entire purpose was catching 7-only syntax quietly stopped doing it.

    smoke-test.ps1 already chains the core, triage and render suites and fails when either does, so
    it is invoked as one unit rather than duplicating that list here - two places naming the
    same suites is how they drift apart.

.EXAMPLE
    .\run-gate.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('smoke')]
    [string]$Only
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $ps51)) { Write-Host "FATAL: Windows PowerShell 5.1 not found at $ps51" -ForegroundColor Red; exit 2 }

$suites = @(
    @{ Name = 'smoke'
       Path = 'scripts\smoke-test.ps1'
       What = 'toolbox, PATH, forensics sensors + the core, triage and render suites' }
)

$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host "=== gate: scripts-utilities ===" -ForegroundColor Cyan
Write-Host ("host {0} -> suites under {1}" -f $PSVersionTable.PSVersion, (Split-Path $ps51 -Leaf)) -ForegroundColor DarkGray
if (-not $isAdmin) {
    Write-Host 'running UNELEVATED - the scheduled-task check cannot be read and will warn' -ForegroundColor Yellow
}
Write-Host ''

$results = @()
$hardFail = $false

foreach ($s in $suites) {
    if ($Only -and $s.Name -ne $Only) { continue }

    $path = Join-Path $repoRoot $s.Path
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ("MISSING  {0,-11} {1}" -f $s.Name, $s.Path) -ForegroundColor Red
        $results += [pscustomobject]@{ Suite = $s.Name; Passed = 0; Failed = 0; Status = 'MISSING' }
        $hardFail = $true
        continue
    }

    Write-Host ("running  {0,-11} {1}" -f $s.Name, $s.What) -ForegroundColor DarkGray
    $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
    $code = $LASTEXITCODE

    $passed = $null; $failed = $null
    $tally = ($out -split "`r?`n" | Where-Object { $_ -match '\d+\s+passed' } | Select-Object -Last 1)
    if ($tally -match '(\d+)\s+passed') { $passed = [int]$Matches[1] }
    if ($tally -match '(\d+)\s+failed') { $failed = [int]$Matches[1] }

    $status =
        if ($null -eq $passed -or $null -eq $failed) { 'NO TALLY' }
        elseif ($failed -gt 0)                       { 'FAILED' }
        elseif ($code -ne 0)                         { 'EXIT<>0' }
        else                                         { 'ok' }

    # The sub-suite tallies are worth surfacing: smoke-test prints them as single OK lines, and
    # a silent drop from 31 to 3 would otherwise still read as green.
    foreach ($line in ($out -split "`r?`n" | Where-Object { $_ -match '(core|triage|render) suite: \d+ passed' })) {
        Write-Host ("         {0}" -f $line.Trim()) -ForegroundColor DarkGray
    }

    if ($status -ne 'ok') {
        $hardFail = $true
        Write-Host $out
    }
    $results += [pscustomobject]@{ Suite = $s.Name; Passed = $passed; Failed = $failed; Status = $status }
}

Write-Host ''
Write-Host '--- summary ---' -ForegroundColor Cyan
foreach ($r in $results) {
    $colour = if ($r.Status -eq 'ok') { 'Green' } else { 'Red' }
    Write-Host ("{0,-11} {1,5} passed {2,4} failed   {3}" -f $r.Suite, $r.Passed, $r.Failed, $r.Status) -ForegroundColor $colour
}
Write-Host ''

if ($hardFail) { Write-Host 'GATE FAILED' -ForegroundColor Red; exit 1 }
Write-Host 'gate passed' -ForegroundColor Green
exit 0
