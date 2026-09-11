#Requires -Version 5.1
<#
    SUTestGuard.ps1 - the test suites' deletion backstop and self-checks.
    DOT-SOURCE THIS FIRST, before any other dot-source in the suite.

    Three things a suite cannot verify about itself:

      1. A Remove-Item shadow that confines every FILESYSTEM deletion to the user's TEMP.
      2. Assert-SUSuiteFloor  - every It block defined in the suite actually ran.
      3. An arm-time positive control that proves 1 is live in THIS process, on every run.

    WHY IT EXISTS. On 2026-09-10 at 15:42 the sibling pc-maintenance suite deleted 123,605 files
    from C:\Users\Admin (.rustup, DevToolbox, .codex, .cargo, .claude and 35 other roots; Sysmon
    event 26, pid 30232). A mutation harness had rewritten Test-PMPathSafe to always return
    $true, and the test "refuses -PayloadRoot 'C:\Users\Admin'" then did exactly what it was
    proving the library would not do. A negative test that hands a real path to a real deleter is
    only as safe as the guard it is testing.

    THIS repo's exposure is narrower but live. tests\Invoke-InstallerTests.ps1 dot-sources
    lib\common.ps1, whose :7 points $script:MANIFEST at the REAL manifest, and then redirects it
    to a scratch file. Swap those two lines and three Remove-Item calls in that suite delete the
    repo's own manifest\tools.json. The margin is one line wide. Same suite also has
    Remove-AgentBlocks and Remove-UserPathEntry defined and callable, which reach four files in
    the user profile and the persistent user PATH.

    A function shadows a cmdlet for every caller in the session that defined it - dot-sourced
    libraries, modules, and & { } child scopes all inherit the parent's function table - so one
    definition covers the whole suite whatever the code under test decides.

    Refusal is a THROW, not a silent skip: the It harness counts it as a failure with the path in
    the message, Show-SUGuardSummary prints the list, and the tally cannot read green.

    WHAT IT CANNOT SEE, stated rather than discovered:
      - A child powershell.exe the suite spawns loads its libraries fresh, without this shadow.
        That is the DOMINANT case here (smoke-test.ps1:663 and run-gate.ps1:186 run every suite as
        a child), which is why this file is dot-sourced in each of the FIVE suites rather than
        once in a parent. Both line references were stale by ~160 lines when checked on
        2026-09-11, pointing at a scriptblock definition and a comment body respectively.
      - Set-Content, Copy-Item, Move-Item, [IO.File]::WriteAllText and
        [Environment]::SetEnvironmentVariable. In this repo the Set-Content path is the BIGGER
        exposure than deletion is: Write-AgentBlock reaches the user's global CLAUDE.md. A
        Set-Content proxy is deliberately not attempted here - its param surface (positional
        Path AND positional Value, pipeline-bound -Value) makes a naive process{} shadow call the
        real cmdlet once per pipeline item, each overwriting the last, silently truncating a
        multi-item write to its final line. A guard that corrupts fixtures gets deleted.

        Instead, gate.yml's "No test reaches a writer that cannot be redirected" step prohibits
        the four writers that reach real user state with no path parameter to redirect:
        Write-AgentDiscovery, Remove-AgentBlocks, Remove-UserPathEntry, Add-UserPathEntry.
        Write-AgentBlock is deliberately NOT among them - it takes an explicit -FilePath, and a
        test in Invoke-InstallerTests.ps1 points it at TEMP to pin its $-escaping.

        That CI step was written on 2026-09-11 because this comment asserted it already existed
        and it did not. Which is the same defect as everything else in this file: a confident
        sentence about a control nobody had checked.
#>

$script:SUTempRoot = $null
$script:SUTripped  = New-Object 'System.Collections.Generic.List[string]'
$script:SUDegraded = New-Object 'System.Collections.Generic.List[string]'
# Set only by a positive control, so an EXPECTED refusal is recorded without the red line that
# would otherwise make a green run look like an incident.
$script:SUExpect   = $false
$script:SUExpectedCount = 0

try {
    $script:SUTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
} catch {
    $script:SUDegraded.Add("cannot resolve TEMP: $($_.Exception.Message)")
}

function Test-SUOutsideFixture {
    <#
        Returns $null when the target is safe or out of scope; the refused full path otherwise.

        PROVIDER FIRST, ALWAYS. The port this came from normalised strings first, which throws on
        `Remove-Item Env:\SOPS_AGE_KEY_FILE` (smoke-test.ps1:166) and on
        `HKCU:\Software\Sysinternals` (uninstall-toolbox.ps1:182) - both legitimate, neither a
        filesystem path. A drive-name blocklist is not a substitute, measured under 5.1:
            Cert:\CurrentUser\Root  ->  provider=Certificate, resolved='\CurrentUser\Root'
        which is indistinguishable from a root-relative FILE path by string inspection. And
        `New-PSDrive -PSProvider FileSystem` lets anyone invent a drive name, so a blocklist fails
        OPEN in exactly the case that matters.

        Provider-qualified filesystem paths are normalised by the resolver itself, verified:
            FileSystem::C:\Temp\x  and  Microsoft.PowerShell.Core\FileSystem::C:\Temp\x
        both -> provider=FileSystem, resolved=C:\Temp\x. They cannot sneak past.

        An unresolvable path (a drive that does not exist: Q:\nope\x -> provider=$null, throws)
        FAILS CLOSED and is judged as a file. The real cmdlet errors there anyway, so nothing
        legitimate is lost.
    #>
    param([string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) { return $null }
    if (-not $script:SUTempRoot) { return $Target }   # degraded: refuse everything

    $prov = $null; $drv = $null; $resolved = $null
    try {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $Target, [ref]$prov, [ref]$drv)
    } catch { }

    if ($prov -and $prov.Name -ne 'FileSystem') { return $null }

    if ($prov) {
        $full = $resolved
    } else {
        # Fail closed. Keep the string normalisation from the original port as defence in depth:
        # a relative path is relative to PowerShell's location, not .NET's current directory.
        $p = $Target -replace '^[^:]+::', ''
        if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $PWD.ProviderPath $p }
        $full = try { [IO.Path]::GetFullPath($p) } catch { $p }
    }

    # Trailing separator on the root is load-bearing: without it C:\Temp2\x prefix-matches
    # C:\Temp\. Inherited from PMTripwire.ps1; no reachable input here exercises it, so it is
    # kept on the strength of the argument rather than claimed as a tested property.
    if ($full.StartsWith($script:SUTempRoot, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

function Remove-Item {
    [CmdletBinding(DefaultParameterSetName = 'Path', SupportsShouldProcess = $true)]
    param(
        [Parameter(ParameterSetName = 'Path', Position = 0, ValueFromPipeline = $true,
                   ValueFromPipelineByPropertyName = $true)]
        [string[]]$Path,
        # ValueFromPipelineByPropertyName, which the original port lacked: without it a future
        # `Get-ChildItem | Remove-Item` binds nothing and the deletion silently vanishes. A guard
        # that eats the operation is worse than one that refuses it.
        [Parameter(ParameterSetName = 'LiteralPath', ValueFromPipelineByPropertyName = $true)]
        [Alias('PSPath')][string[]]$LiteralPath,
        [switch]$Recurse,
        [switch]$Force,
        [string]$Filter,
        [string[]]$Include,
        [string[]]$Exclude
    )
    process {
        foreach ($t in (@($LiteralPath) + @($Path))) {
            $bad = Test-SUOutsideFixture $t
            if (-not $bad) { continue }
            $where = try { (Get-PSCallStack | Select-Object -Skip 1 -First 1).Command } catch { '?' }
            # An EXPECTED refusal (the arm-time control below) is counted, never recorded as an
            # incident. Recording it made every green run end in "tripwire refused 1 deletion(s)",
            # which is precisely the false alarm $SUExpect exists to prevent - and an alarm that
            # fires on every clean run is one people learn to ignore. The control does not need
            # the list: it asserts on the exception's own message marker.
            if ($script:SUExpect) {
                $script:SUExpectedCount++
            } else {
                $script:SUTripped.Add("$bad  (from $where)")
                Write-Host "  TRIPWIRE: refused to delete '$bad' - outside $($script:SUTempRoot) (from $where)" -ForegroundColor Red
            }
            throw "deletion tripwire: '$bad' is outside the suite's TEMP fixture root ($($script:SUTempRoot))"
        }
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
    }
}

function Assert-SUSuiteFloor {
    <#
        Every It block DEFINED in the suite must have RUN. Both sides derive from the same file,
        so there is no stored number to reflex-edit in the same commit that deletes a test - which
        is how a count manifest becomes decoration.

        Catches the dangerous, subtle case: a section that stopped running (an early return, a
        & { } that threw, a guard that skipped a block) while the It calls sit there looking
        present. smoke-test.ps1 greens a suite that prints "0 passed, 0 failed", so a vanished
        section is otherwise invisible.

        ASSUMPTION, and it is a constraint on future test authors: one It call site = one test.
        Measured 2026-09-11 across all FIVE suites - core 27, installer 86, render 23, smokelint
        18, triage 31 - and none of those call sites is inside a LOOP; the loops live INSIDE It
        bodies. A future looped It must refactor or change this shape; the failure mode is a
        confusing floor failure rather than a silent gap.

        NESTING IS NOT THE ASSUMPTION, and the distinction matters because four of the installer
        suite's 86 It calls sit inside `& { }` blocks. FindAll(..., $true) walks the whole tree, so
        a nested It is counted; it also RUNS, so both sides of the comparison agree and the floor
        passes at 86/86. That is the check working, not a gap being tolerated.

        The stated numbers were "all four suites (27/29/31/23)" until 2026-09-11 - wrong on the
        count of suites AND on three of the four figures, in the one comment whose job is to tell
        a future author what this function assumes about their tests. The FLOOR LOGIC was right
        throughout: both sides derive from the same file, so nothing here was ever load-bearing on
        the numbers. A comment that exists to warn and is quietly wrong is worse than no comment,
        which is why it is a measurement with a date on it now rather than a remembered figure.
    #>
    param(
        [Parameter(Mandatory)][string]$SuiteFile,
        [Parameter(Mandatory)][int]$Ran
    )
    $declared = -1
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($SuiteFile, [ref]$null, [ref]$null)
        $declared = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'It' }, $true)).Count
    } catch {
        Write-Host "  FAIL suite floor: cannot parse $SuiteFile - $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    if ($declared -ne $Ran) {
        Write-Host ("  FAIL suite floor: {0} It block(s) defined in {1}, {2} ran" -f `
            $declared, (Split-Path $SuiteFile -Leaf), $Ran) -ForegroundColor Red
        return $false
    }
    Write-Host ("  floor: all {0} It block(s) ran" -f $declared) -ForegroundColor DarkGray
    return $true
}

function Show-SUGuardSummary {
    # A refusal absorbed by a catch inside a test body would otherwise leave no trace.
    if ($script:SUTripped.Count -eq 0) { return }
    Write-Host ("`n  tripwire refused {0} deletion(s):" -f $script:SUTripped.Count) -ForegroundColor Red
    foreach ($t in $script:SUTripped) { Write-Host "    $t" -ForegroundColor Red }
}

# --- arm-time positive control -------------------------------------------------
# Proves the shadow is live in THIS process before a single test runs, so an inert guard cannot
# be mistaken for a clean run. The probe path cannot exist and carries -WhatIf, so the control is
# provably harmless even if the shadow were absent.
#
# Keys on the exception's own MESSAGE MARKER, not on "something threw": a nonexistent drive makes
# the real cmdlet throw too, so `catch { $armed = $true }` would pass with no shadow at all.
# HOW THIS STOPS THE SUITE, and why it is not `exit`.
#
# `exit` in a DOT-SOURCED file does not terminate the dot-sourcing script. Measured: with the
# provider test stubbed to allow everything, this block printed "GUARD INERT" and "0 passed,
# 1 failed", and then the suite ran all 27 of its tests and exited 0 - so an inert guard still
# produced a green run and the control was decorative. A throw is a terminating error that
# propagates into the caller, aborts it before any It runs, and yields exit 1.
#
# The tally line is printed FIRST so run-gate.ps1:87-91 and smoke-test.ps1:685-686 both read a
# real failure rather than reporting NO TALLY, which points at the harness instead of the cause.
if (-not $script:SUTempRoot) {
    Write-Host "  GUARD NOT ARMED: cannot resolve TEMP - $($script:SUDegraded -join '; ')" -ForegroundColor Red
    Write-Host "0 passed, 1 failed"
    throw 'SUTestGuard: cannot resolve TEMP, so no fixture root can be enforced. Refusing to run.'
}
$suProbe = 'C:\su-tripwire-probe-does-not-exist\' + [guid]::NewGuid().ToString('N') + '\x'
$suArmed = $false
$script:SUExpect = $true
try   { Remove-Item -LiteralPath $suProbe -Force -WhatIf -ErrorAction SilentlyContinue }
catch { $suArmed = $_.Exception.Message -match 'deletion tripwire' }
finally { $script:SUExpect = $false }
if (-not $suArmed) {
    Write-Host "  GUARD INERT: the Remove-Item shadow did not refuse a path outside TEMP" -ForegroundColor Red
    # Tally first, then throw - see the note above on why `exit` cannot be used here.
    Write-Host "0 passed, 1 failed"
    throw 'SUTestGuard: the Remove-Item shadow is not enforcing. Refusing to run the suite unguarded.'
}
# Announced on EVERY run, with any degraded mode inline, so the control can never skip in silence.
# smoke-test.ps1 greps for "tripwire ARMED" to confirm each child suite ran guarded.
Write-Host ("  guard: deletion tripwire ARMED - filesystem deletions confined to {0}{1}" -f `
    $script:SUTempRoot,
    $(if ($script:SUDegraded.Count) { " [DEGRADED: $($script:SUDegraded -join '; ')]" } else { '' })
) -ForegroundColor DarkGray
