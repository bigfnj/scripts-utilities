#Requires -Version 5.1
<#
    Tests for lib\SmokeLint.ps1 - the rules that keep scripts\smoke-test.ps1's own checks capable
    of failing.

    WHY THIS SUITE EXISTS. The rules were an inline scriptblock inside smoke-test.ps1, and NO test
    file anywhere referenced that script; gate.yml deliberately never runs it (gate.yml:16-20).
    So the lint could have been deleted, inverted, or quietly narrowed and every gate in this
    repository would still have read green. It was the only check here that could not itself be
    checked.

    THE CONTROLS MATTER MORE THAN THE RULES. Half of these tests assert SILENCE, because the way a
    lint dies is not by missing a bug - it is by flagging the fix. the comment that used to sit at smoke-test.ps1:452-457 recorded
    that judgement in the repository's own words: the first draft of rule A flagged the
    gather-only pattern, which is BETTER than the one being outlawed, and "a lint that cried wolf
    about it would be turned off within a week". Rule B has the same trap one layer down - the
    safe shape and the buggy shape both contain `Select-Object -First 1` and both read
    $LASTEXITCODE - so the two shapes are pinned here side by side, from the real source.

    FIXTURES ARE STRINGS WRITTEN TO TEMP, never files in the repository. A fixture that has to
    parse under 5.1 and must contain a deliberate defect cannot live in tests\ without the
    repo-wide parse sweep (gate.yml:82-95) and the lint's own pass over its own tree picking it
    up as real.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SmokeLintTests.ps1
#>
[CmdletBinding()]
param()

# The deletion tripwire, the suite floor and the arm-time control. FIRST, before every other
# dot-source: the Remove-Item shadow must be defined before any library can bind to the real
# cmdlet. $PSScriptRoot rather than $repoRoot so this needs nothing computed first.
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\SmokeLint.ps1')

$script:Pass = 0; $script:Fail = 0
function It {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        if (& $Body) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
    } catch { $script:Fail++; Write-Host "  FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red }
}

$fixtureDir = Join-Path ([IO.Path]::GetTempPath()) ("smokelint-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

function New-Fixture {
    # [IO.File]::WriteAllText, not Set-Content: the fixtures carry backslashes and backtick
    # escapes that matter to the AST, and Set-Content's 5.1 default encoding is ANSI.
    param([string]$Name, [string]$Code)
    $p = Join-Path $fixtureDir "$Name.ps1"
    [IO.File]::WriteAllText($p, $Code)
    $p
}
function Get-Rules {
    param([string]$Path)
    @(Get-SmokeLintFindings -Path $Path | ForEach-Object { '{0}@{1}' -f $_.Rule, $_.Line })
}
function Get-FixtureLine {
    # The expected line number is READ BACK OUT OF THE FIXTURE, never written down here. The
    # helper prelude is prepended to every fixture, so a hardcoded number silently becomes wrong
    # the day a helper is added - and it becomes wrong in the direction of a test that still
    # passes while checking the wrong line.
    param([string]$Path, [string]$Pattern)
    $lines = @([IO.File]::ReadAllText($Path) -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $Pattern) { return ($i + 1) }
    }
    -1
}

# Every fixture declares the helpers it calls, so nothing here depends on smoke-test.ps1's own
# function table - rule A keys on the NAME Test-Ok, not on the function being the real one.
$helpers = @'
function Test-Ok   { param([string]$Msg) }
function Test-Fail { param([string]$Msg) }
function Test-Warn { param([string]$Msg) }
'@

try {

Write-Host "`n== rule A fires on a verdict no failure can reach ==" -ForegroundColor Cyan

It 'a try body that calls Test-Ok without an exit code or a comparison is flagged' {
    $f = New-Fixture 'a-bare' ($helpers + @'

try {
    somecli.exe --version | Out-Null
    Test-Ok "somecli works"
} catch { Test-Fail "somecli could not start" }
'@)
    $r = @(Get-SmokeLintFindings -Path $f)
    $r.Count -eq 1 -and $r[0].Rule -eq 'A'
}

It 'and the line it names is the try, not the Test-Ok call' {
    # The fix is applied to the whole block, so the block is what gets pointed at. A line number
    # aimed at the Test-Ok call reads as "this one line is wrong" and sends the reader to the
    # wrong place.
    $f = New-Fixture 'a-line' ($helpers + @'

$x = 1
$y = 2
try {
    somecli.exe | Out-Null
    Test-Ok "ok"
} catch { Test-Fail "no" }
'@)
    $r = @(Get-SmokeLintFindings -Path $f)
    $r.Count -eq 1 -and $r[0].Rule -eq 'A' -and
        $r[0].Line -eq (Get-FixtureLine -Path $f -Pattern '^try \{')
}

It 'the same block with an exit-code check is silent' {
    $f = New-Fixture 'a-exit' ($helpers + @'

try {
    somecli.exe --version | Out-Null
    if ($LASTEXITCODE -eq 0) { Test-Ok "ok" } else { Test-Fail "exited $LASTEXITCODE" }
} catch { Test-Fail "could not start" }
'@)
    (Get-Rules $f).Count -eq 0
}

It 'and with a comparison instead of an exit code it is also silent' {
    $f = New-Fixture 'a-compare' ($helpers + @'

try {
    $out = somecli.exe --version 2>&1
    if ($out -match 'somecli') { Test-Ok "ok" } else { Test-Fail "unexpected: $out" }
} catch { Test-Fail "could not start" }
'@)
    (Get-Rules $f).Count -eq 0
}

Write-Host "`n== rule A stays silent on the pattern that is BETTER than the one it outlaws ==" -ForegroundColor Cyan

It 'the gather-only shape from smoke-test.ps1:426-434 is not flagged' {
    # THE FALSE-POSITIVE CONTROL the old smoke-test.ps1:452-457 comment insists on, copied from the live source:
    # read a native command inside the try, decide OUTSIDE it, with an explicit
    # warn-on-unreadable branch. The first draft of rule A flagged this. It must not.
    $f = New-Fixture 'a-gather' ($helpers + @'

$drvStart = $null
try {
    $qc = & sc.exe qc SysmonDrv 2>&1 | Out-String
    $m = [regex]::Match($qc, '(?im)START_TYPE\s*:\s*\d+\s+(\S+)')
    if ($m.Success) { $drvStart = $m.Groups[1].Value }
} catch { }
if ($drvStart -match 'BOOT_START|SYSTEM_START|AUTO_START') { Test-Ok "SysmonDrv loads at boot ($drvStart)" }
elseif ($drvStart) { Test-Fail "SysmonDrv START_TYPE is $drvStart" }
else { Test-Warn "could not read SysmonDrv start type" }
'@)
    (Get-Rules $f).Count -eq 0
}

It 'nor is the USN gather at smoke-test.ps1:466-474, which has no comparison in the try either' {
    $f = New-Fixture 'a-usn' ($helpers + @'

$usnBytes = $null
try {
    $usnOut = & fsutil usn queryjournal C: 2>&1 | Out-String
    $um = [regex]::Match($usnOut, '(?im)^\s*Maximum Size\s*:\s*0x([0-9a-f]+)')
    if ($um.Success) { $usnBytes = [Convert]::ToInt64($um.Groups[1].Value, 16) }
} catch { }
if ($null -eq $usnBytes) { Test-Warn "could not read the USN journal on C:" }
elseif ($usnBytes -ge 1GB) { Test-Ok "USN journal is large enough" }
else { Test-Warn "USN journal only holds hours of history" }
'@)
    (Get-Rules $f).Count -eq 0
}

Write-Host "`n== rule B fires on the exit-code check that -First corrupts ==" -ForegroundColor Cyan

It 'a native command piped into Select-Object -First beside a $LASTEXITCODE read is flagged' {
    # The defect rule A PASSES: $LASTEXITCODE appears, so rule A's presence test is satisfied,
    # and the pairing is itself the bug. -First raises StopUpstreamCommandsException, killing the
    # native process mid-write and leaving $LASTEXITCODE = -1 (smoke-test.ps1:78-82).
    $f = New-Fixture 'b-native' ($helpers + @'

try {
    $v = somecli.exe --version 2>&1 | Select-Object -First 1
    if ($LASTEXITCODE -eq 0) { Test-Ok "somecli: $v" } else { Test-Fail "exited $LASTEXITCODE" }
} catch { Test-Fail "could not start" }
'@)
    $r = @(Get-SmokeLintFindings -Path $f)
    $r.Count -eq 1 -and $r[0].Rule -eq 'B' -and
        $r[0].Line -eq (Get-FixtureLine -Path $f -Pattern 'Select-Object -First 1')
}

It 'rule A alone does NOT catch it, which is why rule B exists' {
    # Pinning the gap rather than asserting it away: if a future edit makes rule A cover this,
    # this test fails and someone reads both rules again.
    $f = New-Fixture 'b-rule-a-blind' ($helpers + @'

try {
    $v = somecli.exe --version 2>&1 | Select-Object -First 1
    if ($LASTEXITCODE -eq 0) { Test-Ok "ok" } else { Test-Fail "no" }
} catch { Test-Fail "no" }
'@)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
    (@(Get-SLRuleAFindings -Ast $ast).Count -eq 0) -and (@(Get-SLRuleBFindings -Ast $ast).Count -eq 1)
}

It 'a prefix-abbreviated -Fir is caught too, because PowerShell binds it the same way' {
    $f = New-Fixture 'b-prefix' ($helpers + @'

try {
    $v = somecli.exe --version 2>&1 | Select-Object -Fir 1
    if ($LASTEXITCODE -eq 0) { Test-Ok "ok" } else { Test-Fail "no" }
} catch { Test-Fail "no" }
'@)
    $r = @(Get-SmokeLintFindings -Path $f)
    $r.Count -eq 1 -and $r[0].Rule -eq 'B' -and
        $r[0].Line -eq (Get-FixtureLine -Path $f -Pattern 'Select-Object -Fir 1')
}

Write-Host "`n== rule B stays silent on the fix, and on pipelines with no native process ==" -ForegroundColor Cyan

It 'the real safe shape from smoke-test.ps1:83-84 is not flagged' {
    # GO/NO-GO CONTROL. Drain the whole stream with Out-String FIRST, then take -First 1 off the
    # resulting STRING. It is the pattern this repository moved TO, in three places. A rule that
    # flags it is worse than no rule, and shipping it would have been the mistake rule A's own
    # history already records.
    $f = New-Fixture 'b-safe' ($helpers + @'

try {
    $vAll = somecli.exe --version 2>&1 | Out-String
    $v = ($vAll -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0) { Test-Ok "somecli: $v" } else { Test-Fail "exited $LASTEXITCODE" }
} catch { Test-Fail "could not start" }
'@)
    (Get-Rules $f).Count -eq 0
}

It 'a cmdlet at the head of the pipeline is not flagged' {
    # GO/NO-GO CONTROL. -First short-circuits Get-ChildItem exactly as hard, but there is no
    # native process to kill and no exit code to corrupt. smoke-test.ps1:281-282 and :414 both
    # have this shape and both are correct.
    $f = New-Fixture 'b-cmdlet' ($helpers + @'

try {
    $one = Get-ChildItem -LiteralPath $env:TEMP | Select-Object -First 1
    if ($LASTEXITCODE -eq 0) { Test-Ok "$one" } else { Test-Fail "no" }
} catch { Test-Fail "no" }
'@)
    (Get-Rules $f).Count -eq 0
}

It 'a function defined in the same file is not mistaken for a native command' {
    $f = New-Fixture 'b-localfn' ($helpers + @'

function Get-LocalThing { 'a', 'b' }
try {
    $one = Get-LocalThing | Select-Object -First 1
    if ($LASTEXITCODE -eq 0) { Test-Ok "$one" } else { Test-Fail "no" }
} catch { Test-Fail "no" }
'@)
    (Get-Rules $f).Count -eq 0
}

It 'a native command with -First but no $LASTEXITCODE anywhere in the block is not flagged' {
    # -First on a native command is only a defect when something then reads the exit code. On its
    # own it is a legitimate way to take one line and stop reading.
    $f = New-Fixture 'b-no-exit' ($helpers + @'

try {
    $v = somecli.exe --version 2>&1 | Select-Object -First 1
    if ($v -match 'somecli') { Test-Ok "ok" }
} catch { Test-Fail "no" }
'@)
    (Get-Rules $f).Count -eq 0
}

It 'and Select-Object -Last is not -First: it drains the pipeline rather than aborting it' {
    $f = New-Fixture 'b-last' ($helpers + @'

try {
    $v = somecli.exe --version 2>&1 | Select-Object -Last 1
    if ($LASTEXITCODE -eq 0) { Test-Ok "ok" } else { Test-Fail "no" }
} catch { Test-Fail "no" }
'@)
    (Get-Rules $f).Count -eq 0
}

Write-Host "`n== the real file is clean, and an unparseable one is not silently clean ==" -ForegroundColor Cyan

It 'scripts\smoke-test.ps1 itself has no rule A or rule B violation' {
    # The assertion smoke-test.ps1 makes about itself on every run, made here as well - so the
    # rules cannot be narrowed to fit the file they police without this failing too.
    @(Get-SmokeLintFindings -Path (Join-Path $repoRoot 'scripts\smoke-test.ps1')).Count -eq 0
}

It 'a file that does not parse is reported as a finding, not as clean' {
    # A parse failure produces no ASTs, so both rules would report zero and the caller would read
    # "no violations". The honest answer is that nothing could be checked.
    $f = New-Fixture 'unparseable' @'
function Broken {
    if ($true) { 'x'
'@
    $r = @(Get-SmokeLintFindings -Path $f)
    $r.Count -ge 1 -and $r[0].Rule -eq 'parse'
}

It 'a missing file is reported as a finding too' {
    $r = @(Get-SmokeLintFindings -Path (Join-Path $fixtureDir 'does-not-exist.ps1'))
    $r.Count -eq 1 -and $r[0].Rule -eq 'parse'
}

It 'every finding carries a line, a rule and a message' {
    # smoke-test.ps1 formats all three into one Test-Fail line; a $null rule there prints as a
    # blank and the reader cannot tell which rule fired.
    $f = New-Fixture 'shape' ($helpers + @'

try {
    somecli.exe | Out-Null
    Test-Ok "ok"
} catch { Test-Fail "no" }
'@)
    $r = @(Get-SmokeLintFindings -Path $f)
    $r.Count -eq 1 -and $r[0].Line -gt 0 -and $r[0].Rule -and $r[0].Message
}

} finally {
    Remove-Item $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
