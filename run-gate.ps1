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

    smoke-test.ps1 already chains the core, installer, triage and render suites and fails when either does, so
    it is invoked as one unit rather than duplicating that list here - two places naming the
    same suites is how they drift apart.

    -Phase IS THE ONE EXCEPTION TO THAT, and it is deliberate. If smoke-test.ps1 dies before it
    reaches its suite loop, the suites never run at all and the only signal is "smoke failed" -
    which is indistinguishable from a tool being absent. That is not hypothetical while someone
    is adding a group to that very file. Under -Phase the suites are therefore run a second time,
    DIRECTLY, so the two paths are independent; the list is enumerated from tests\ rather than
    written down, so the drift the paragraph above warns about still cannot happen.

.EXAMPLE
    .\run-gate.ps1

.EXAMPLE
    .\run-gate.ps1 -Phase before-rebuild
    .\run-gate.ps1 -Phase after-bootstrap

    Each run appends one measurement to logs\gate-phases.log and compares it with the previous
    line. THERE ARE NO STORED EXPECTATIONS: the expected value is the previous phase's
    measurement, so there is no number in the repository to reflex-edit in the same commit that
    breaks a suite. A unit-suite count that moved fails the gate; the smoke triple moves for
    environmental reasons on every rebuild step - a tool arriving flips a FAIL to an OK - so it is
    reported as a TRANSITION instead.
#>
[CmdletBinding()]
param(
    [ValidateSet('checks', 'smoke')]
    [string]$Only,

    # The label goes into a whitespace-delimited log line, so it may not contain whitespace.
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Phase
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $ps51)) { Write-Host "FATAL: Windows PowerShell 5.1 not found at $ps51" -ForegroundColor Red; exit 2 }

$suites = @(
    # FIRST, because it is cheap, deterministic and depends on nothing outside the repository - a
    # malformed repo should be named before a multi-minute toolbox sweep.
    #
    # These six checks existed ONLY as inline PowerShell inside .github\workflows\gate.yml, so
    # this gate could not run them. When an unrelated suite went red on 2026-09-11 the failing
    # step aborted the job and CI stopped running them too, for six days, while reporting exactly
    # one problem. lib\GateChecks.ps1 is now the one definition and the workflow calls this same
    # runner, in a separate job a red suite cannot abort.
    #
    # A CHILD powershell.exe, like every other suite here, and this is the sharpest case for that
    # rule: the parse check calls [Parser] IN-PROCESS and [Parser] uses the grammar of the host it
    # runs in. Dot-sourcing the library into THIS process would check 7's grammar whenever the
    # gate is launched from pwsh - the defect scripts\smoke-test.ps1 already records, one layer out.
    @{ Name = 'checks'
       Path = 'scripts\run-gate-checks.ps1'
       What = 'parse under 5.1, gate wiring, guard order, test writers, control bytes, markdown' }
    @{ Name = 'smoke'
       Path = 'scripts\smoke-test.ps1'
       What = 'toolbox, PATH, agent blocks, forensics sensors + every suite in tests\' }
)

function Get-GateTally {
    <#
        The tally line out of a suite's captured output.

        $null, never 0, for a count that was not printed: RULE 2 of the header turns on being
        able to tell "no tally" apart from "zero", and 0 would collapse them.

        ONE parser, shared by the smoke invocation and by -Phase. Two copies is how the ledger
        line and the summary line start disagreeing about what the same run said - the same
        argument the header makes about suite lists, one level down. This is the only reason the
        smoke loop below was touched at all; its logic is unchanged.
    #>
    param([string]$Output)
    $line = ($Output -split "`r?`n" | Where-Object { $_ -match '\d+\s+passed' } | Select-Object -Last 1)
    $p = $null; $w = $null; $f = $null
    if ($line -match '(\d+)\s+passed')  { $p = [int]$Matches[1] }
    if ($line -match '(\d+)\s+warning') { $w = [int]$Matches[1] }
    if ($line -match '(\d+)\s+failed')  { $f = [int]$Matches[1] }
    [pscustomobject]@{ Passed = $p; Warnings = $w; Failed = $f }
}

function Format-GateCount {
    # '?' rather than an empty string for a count that was never printed: "smoke=//" is
    # unreadable in a log nobody looks at until something breaks. Two consecutive '?' runs do
    # compare equal and the ledger calls that stable - which is harmless only because a suite
    # printing no tally has already set the gate to FAILED through Get-GateStatus. The ledger is
    # a drift detector, not the tally rule.
    param($Value)
    if ($null -eq $Value) { return '?' }
    [string]$Value
}

function Get-GateStatus {
    # NO TALLY is tested BEFORE the exit code, on purpose and unchanged: a PowerShell script with
    # no explicit exit inherits the last native command's code, so exit 0 is not evidence of
    # anything. The tally is the independent evidence.
    param($Passed, $Failed, $Code)
    if ($null -eq $Passed -or $null -eq $Failed) { return 'NO TALLY' }
    if ($Failed -gt 0)                           { return 'FAILED' }
    if ($Code -ne 0)                             { return 'EXIT<>0' }
    'ok'
}

function Invoke-GateSuite {
    <#
        Run one suite as a 5.1 child and hand back its MERGED output beside its exit code.

        THE CLASSIFIER ABOVE WAS UNREACHABLE IN THE CASE IT EXISTS FOR. The 2>&1 is not
        optional - Get-GateTally reads the tally out of whatever the child printed, and a suite
        that dies writes the reason to stderr - but under this file's $ErrorActionPreference =
        'Stop' a native command whose stderr PowerShell has redirected raises a terminating
        NativeCommandError. So the merge that makes NO TALLY / FAILED / EXIT<>0 distinguishable
        was also what killed the parent before Get-GateStatus could distinguish them, and a
        child that merely warned on stderr took the gate down with it.

        Measured 2026-09-11 under 5.1, across three host-stream conditions (console inherited,
        parent-captured with 2>&1 | Out-String, Start-Process -RedirectStandard*): `$x = & cmd
        /c "echo e 1>&2 & exit /b 0" 2>&1` throws in all three, and so does the 2>$null form;
        a plain `| Out-Null` with no redirection throws in NONE of them. The redirection is the
        trigger. Rejected: dropping the 2>&1 and reading stdout only - that is what makes a
        suite's dying words invisible, which is the opposite of this gate's job.

        Continue is scoped to the one statement and restored in a finally, not after the call:
        an exception in that window would otherwise leave the REST of the gate running under
        Continue, silently downgrading every check below it.

        -InSession RUNS THE SUITE THE WAY CI DOES, and it is a switch on THIS function rather
        than a second wrapper on purpose. The repo-wide native-stderr rule exempts exactly three
        function names and a test caps the list at three, so a fourth wrapper would fail the
        gate it is trying to strengthen.

        The two modes are not equivalent, which is the whole reason the switch exists.
        `-File` makes the suite the top-level script; `-Command "... ; & <path>"` makes it a
        script invoked from inside another script, which is what .github\workflows\gate.yml does.
        A closure built with GetNewClosure() resolves FUNCTIONS through global scope, and the
        script scope of a nested script is not global - so a helper called from inside such a
        closure is found in one mode and not the other. Measured 2026-09-17 on
        tests\Invoke-InstallerTests.ps1: 108/0 under -File, 96/12 in-session, and CI had been red
        on exactly that for six days while this gate reported green.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [switch]$InSession
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($InSession) {
            # Set-Location first, because CI's run: block executes with the repo root as its
            # working directory and a suite is free to depend on that.
            $cmd = "Set-Location -LiteralPath '{0}'; & '{1}'" -f $repoRoot, $ScriptPath
            $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String
        } else {
            $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1 | Out-String
        }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    } finally { $ErrorActionPreference = $prev }
}

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
# Kept so the parity check below can compare against the per-suite counts smoke-test already
# printed, instead of running every suite a third time.
$smokeOut = $null

foreach ($s in $suites) {
    if ($Only -and $s.Name -ne $Only) { continue }

    $path = Join-Path $repoRoot $s.Path
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ("MISSING  {0,-11} {1}" -f $s.Name, $s.Path) -ForegroundColor Red
        $results += [pscustomobject]@{ Suite = $s.Name; Passed = 0; Warnings = $null; Failed = 0; Status = 'MISSING' }
        $hardFail = $true
        continue
    }

    Write-Host ("running  {0,-11} {1}" -f $s.Name, $s.What) -ForegroundColor DarkGray
    $run = Invoke-GateSuite -ScriptPath $path
    $out = $run.Output
    $code = $run.ExitCode

    if ($s.Name -eq 'smoke') { $smokeOut = $out }

    $t = Get-GateTally $out
    $status = Get-GateStatus -Passed $t.Passed -Failed $t.Failed -Code $code

    # The sub-suite lines are worth surfacing: smoke-test prints them as single OK lines, and a
    # silent drop from 31 to 3 would otherwise still read as green. The suite NAMES are no longer
    # spelled out - smoke-test derives them from the filenames in tests\, so a new suite would
    # have silently stopped being surfaced here. "tripwire ARMED" is surfaced for the same
    # reason: on a green run nothing else prints it, and it is the only evidence that the suites
    # ran with the deletion guard live.
    # The per-check verdicts are surfaced for the same reason: the checks runner prints one line
    # per check, and a silent drop from six checks to one would otherwise still read as green.
    foreach ($line in ($out -split "`r?`n" | Where-Object { $_ -match 'suite: \d+ passed|tripwire ARMED|^\s*(ok|FAIL)\s+check ' })) {
        Write-Host ("         {0}" -f $line.Trim()) -ForegroundColor DarkGray
    }

    if ($status -ne 'ok') {
        $hardFail = $true
        Write-Host $out
    }
    $results += [pscustomobject]@{ Suite = $s.Name; Passed = $t.Passed; Warnings = $t.Warnings
                                   Failed = $t.Failed; Status = $status }
}

# --- invocation parity --------------------------------------------------------
#
# THE GAP THIS CLOSES, and it is measured rather than imagined.
#
# Every suite above runs as a `powershell.exe -File` CHILD. .github\workflows\gate.yml runs each
# one IN-SESSION, as `.\tests\Invoke-XTests.ps1` from inside a run: block. Those two modes do not
# resolve functions inside a GetNewClosure() scriptblock the same way, because such a closure
# looks functions up through GLOBAL scope and the script scope of a nested script is not global.
#
# On 2026-09-17 that difference meant tests\Invoke-InstallerTests.ps1 scored 108/0 here and 96/12
# in CI. The build had been red for SIX DAYS and this gate could not see it by construction. It
# was worse than one red suite: a failing CI step aborts the job, so the five repo-hygiene checks
# that sit below the installer step had not run in CI either for the same six days.
#
# So the property is not "the suites pass", it is "the suites pass THE SAME WAY in both modes".
# Cost is one extra child per suite, which is cheaper than six days.
# Only when smoke actually ran, because smoke is what produced the -File counts to compare
# against. `-Only checks` is meant to be a ~2 s inner loop; running five extra suites to compare
# them with nothing would make it the slowest path in the file.
$parityWanted = (-not $Only) -or ($Only -eq 'smoke')

Write-Host ''
if (-not $parityWanted) {
    Write-Host ("skipped  parity      -Only {0} ran no suites to compare against" -f $Only) -ForegroundColor DarkGray
}
if ($parityWanted) {
Write-Host 'running  parity      every suite again IN-SESSION, the way CI invokes it' -ForegroundColor DarkGray

$suiteFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Filter 'Invoke-*Tests.ps1' -File -ErrorAction SilentlyContinue |
                Sort-Object Name)
if ($suiteFiles.Count -eq 0) {
    # A FLOOR. An enumeration that matches nothing would otherwise print no lines at all and let
    # the gate pass having compared nothing - the same shape the parse gate's own floor exists for.
    Write-Host '         FAIL parity: found 0 suites in tests\ - this check compared nothing' -ForegroundColor Red
    $hardFail = $true
}

foreach ($f in $suiteFiles) {
    $short = ($f.BaseName -replace '^Invoke-', '' -replace 'Tests$', '').ToLowerInvariant()
    $pr = Invoke-GateSuite -ScriptPath $f.FullName -InSession
    $pt = Get-GateTally $pr.Output
    $pstatus = Get-GateStatus -Passed $pt.Passed -Failed $pt.Failed -Code $pr.ExitCode

    if ($pstatus -ne 'ok') {
        Write-Host ("         FAIL parity {0}: in-session status {1} (passed={2} failed={3} exit={4})" -f `
            $short, $pstatus, $pt.Passed, $pt.Failed, $pr.ExitCode) -ForegroundColor Red
        Write-Host $pr.Output
        $hardFail = $true
        continue
    }

    # The -File count smoke-test already printed for this suite. Compared rather than assumed:
    # a suite that silently ran FEWER tests in one mode is the same class of defect as one that
    # failed, and Assert-SUSuiteFloor only proves declared == ran within a single run.
    $want = $null
    if ($smokeOut -and $smokeOut -match ("(?m)^\s*OK\s+" + [regex]::Escape($short) + "\s+suite:\s+(\d+)\s+passed")) {
        $want = [int]$Matches[1]
    }

    if ($null -eq $want) {
        # Not a pass. Say which half is missing, because "compared nothing" reads identically to
        # "compared and agreed" once the line scrolls past.
        Write-Host ("         ok   parity {0}: in-session {1} passed (no -File count to compare{2})" -f `
            $short, $pt.Passed, $(if ($Only) { ' under -Only' } else { ' - smoke printed none' })) -ForegroundColor DarkGray
        if (-not $Only) { $hardFail = $true }
    } elseif ($want -ne $pt.Passed) {
        Write-Host ("         FAIL parity {0}: -File ran {1} passed, in-session ran {2}" -f `
            $short, $want, $pt.Passed) -ForegroundColor Red
        $hardFail = $true
    } else {
        Write-Host ("         ok   parity {0}: {1} passed in both modes" -f $short, $pt.Passed) -ForegroundColor DarkGray
    }
}
}

# --- phase ledger -------------------------------------------------------------
if ($PSBoundParameters.ContainsKey('Phase')) {
    Write-Host ''
    Write-Host ("--- phase '{0}' ---" -f $Phase) -ForegroundColor Cyan

    $phaseCounts = [ordered]@{}

    # The checks column comes first because the runner runs first, and it buys a second,
    # independent tripwire on the check registry for free: DELETE a check and the count drops
    # from 6 to 5, which the decrease rule below treats as fatal DRIFT.
    #
    # Deliberate consequence, stated because it looks like a bug: a check that FAILS also lowers
    # the count, so it is reported twice - once as FAILED, once as DRIFT. That is the semantics
    # this ledger already has for every test suite, so it is consistent rather than clever.
    $ck = @($results | Where-Object { $_.Suite -eq 'checks' })[0]
    $phaseCounts['checks'] = if (-not $ck) { 'skipped' } else { Format-GateCount $ck.Passed }

    $sm = @($results | Where-Object { $_.Suite -eq 'smoke' })[0]
    $phaseCounts['smoke'] =
        if (-not $sm) { 'skipped' }
        else { '{0}/{1}/{2}' -f (Format-GateCount $sm.Passed), (Format-GateCount $sm.Warnings), (Format-GateCount $sm.Failed) }

    # From disk, exactly like scripts\smoke-test.ps1 and gate.yml's own "no test suite is missing"
    # step. There is no list here to fall out of date, and a suite added to tests\ shows up in the
    # ledger on its first run.
    foreach ($sf in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Filter 'Invoke-*Tests.ps1' `
                          -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $name = ($sf.BaseName -replace '^Invoke-', '' -replace 'Tests$', '').ToLowerInvariant()
        Write-Host ("running  {0,-11} directly, so a smoke test that dies early cannot hide it" -f $name) -ForegroundColor DarkGray
        $sRun = Invoke-GateSuite -ScriptPath $sf.FullName
        $sOut = $sRun.Output
        $sCode = $sRun.ExitCode
        $st = Get-GateTally $sOut
        $sStatus = Get-GateStatus -Passed $st.Passed -Failed $st.Failed -Code $sCode
        if ($sStatus -ne 'ok') { $hardFail = $true; Write-Host $sOut }
        $results += [pscustomobject]@{ Suite = $name; Passed = $st.Passed; Warnings = $st.Warnings
                                       Failed = $st.Failed; Status = $sStatus }
        $phaseCounts[$name] = Format-GateCount $st.Passed
    }

    $logDir = Join-Path $repoRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logPath = Join-Path $logDir 'gate-phases.log'

    # Read the previous line BEFORE appending this one, or the comparison is against itself.
    $prev = $null
    if (Test-Path -LiteralPath $logPath) {
        $prev = @(Get-Content -LiteralPath $logPath | Where-Object { $_.Trim() } | Select-Object -Last 1)[0]
    }
    $line = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Phase,
            (($phaseCounts.Keys | ForEach-Object { '{0}={1}' -f $_, $phaseCounts[$_] }) -join ' ')
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host ("ledger   {0}" -f $line) -ForegroundColor DarkGray

    if (-not $prev) {
        Write-Host 'ledger   no previous phase on record - this line becomes the baseline' -ForegroundColor Yellow
    } else {
        Write-Host ("previous {0}" -f $prev) -ForegroundColor DarkGray
        $prevMap = @{}
        foreach ($tok in ($prev -split '\s+')) {
            if ($tok -match '^([A-Za-z0-9_]+)=(.+)$') { $prevMap[$Matches[1]] = $Matches[2] }
        }
        $drift = @(); $transitions = @()
        foreach ($k in $phaseCounts.Keys) {
            if (-not $prevMap.ContainsKey($k)) { $transitions += ('{0} is new ({1})' -f $k, $phaseCounts[$k]); continue }
            if ($prevMap[$k] -eq $phaseCounts[$k]) { continue }
            # The smoke triple is the environment talking, not the code: on this box a rebuild
            # step turns "18 missing tools" into 18 OKs without a line of this repository
            # changing. Failing on that would make the ledger unusable during exactly the work it
            # exists to track.
            if ($k -eq 'smoke') { $transitions += ('smoke {0} -> {1}' -f $prevMap[$k], $phaseCounts[$k]); continue }

            # A DECREASE HARD-FAILS. AN INCREASE DOES NOT. Both used to, and it made the ledger
            # punish the one thing this repo wants: adding a test. Every commit that fixed a bug
            # here also added the check that catches it, so every one of them tripped DRIFT and
            # had to be waved through - and a gate that is routinely waved through stops being
            # read at all. A count that FELL is the real signal: a suite lost coverage, either by
            # a deleted It block or by one that stopped being reached.
            #
            # FAILS CLOSED on anything it cannot compare. Format-GateCount emits '?' for a suite
            # that printed no tally, and '?' must never be read as growth; if either side is not
            # an integer this stays DRIFT.
            $prevN = 0
            $nowN = 0
            $comparable = ([int]::TryParse([string]$prevMap[$k], [ref]$prevN)) -and
                          ([int]::TryParse([string]$phaseCounts[$k], [ref]$nowN))
            if ($comparable -and $nowN -gt $prevN) {
                $transitions += ('{0} GREW {1} -> {2} (+{3})' -f $k, $prevN, $nowN, ($nowN - $prevN))
            } else {
                $drift += ('{0} {1} -> {2}' -f $k, $prevMap[$k], $phaseCounts[$k])
            }
        }
        # A suite APPEARING or VANISHING changes the shape of the ledger rather than a count, and
        # it is already fatal elsewhere: smoke-test.ps1's required-suite floor fails on a deleted
        # suite. Reporting it here as well, and failing twice, would only obscure which check
        # actually found it.
        foreach ($k in $prevMap.Keys) {
            if (-not $phaseCounts.Contains($k)) { $transitions += ('{0} is gone (was {1})' -f $k, $prevMap[$k]) }
        }

        foreach ($tr in $transitions) { Write-Host ("TRANSITION {0}" -f $tr) -ForegroundColor Cyan }
        if ($drift.Count) {
            # A unit-suite count that FELL, or one that cannot be compared at all. Either way a
            # test count has no environmental excuse the way the smoke triple does. Growth is
            # reported above as a TRANSITION instead - see the reasoning at the decrease check.
            foreach ($d in $drift) { Write-Host ("DRIFT      {0}" -f $d) -ForegroundColor Red }
            $hardFail = $true
        } elseif ($transitions.Count -eq 0) {
            Write-Host 'ledger   every suite count matches the previous phase' -ForegroundColor Green
        }
    }
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
