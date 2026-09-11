#Requires -Version 5.1
<#
    Tests for ForensicsReport.Core.ps1.

    THIS SUITE COULD NOT EXIST UNTIL TODAY. Its subject lived in New-ForensicsReport.ps1, a
    script whose top-level code starts reading the Sysmon event log the moment it is
    dot-sourced and calls `exit 1` on the unelevated path - which kills the test host. So the
    functions with the most arithmetic in them, including the one that decides what counts as
    "never seen before", had no tests at all. When Get-FxPairKey was rewritten for a 24x
    speedup, correctness was established by a throwaway harness that RESTATED the function;
    what was proved correct was a copy.

    Those 68 differential cases are pinned here instead, against the real function.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-CoreTests.ps1
#>
[CmdletBinding()]
param()

# The deletion tripwire, the suite floor and the arm-time control. FIRST, before every other
# dot-source: the Remove-Item shadow must be defined before any library can bind to the real
# cmdlet. $PSScriptRoot rather than $repoRoot so this needs nothing computed first.
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\ForensicsReport.Core.ps1')

$script:Pass = 0; $script:Fail = 0
function It {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        if (& $Body) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
    } catch { $script:Fail++; Write-Host "  FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red }
}
function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("fxcore-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $d
}

Write-Host "`n== the file loads on its own, which is the entire point ==" -ForegroundColor Cyan

It 'dot-sourcing Core does not read the event log, write a report, or exit' {
    # If this suite is running at all, the load succeeded. Assert the functions arrived rather
    # than asserting a tautology.
    $names = 'Get-FxSentinelPattern','New-FxSentinelRegex','Get-FxPairKey','Read-FxBaseline',
             'Write-FxBaseline','Get-FxInteractiveUser','Get-FxDownloadsPath'
    @($names | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }).Count -eq 0
}
It 'every exported name is Fx-prefixed, so none can shadow a real cmdlet' {
    # The ConvertTo-Html incident: an unprefixed helper in a dot-sourced file silently resolved
    # to the built-in cmdlet, dropped the user data and injected two remote URLs into a report
    # whose header promised it fetched nothing. Nothing threw.
    $src = Get-Content (Join-Path $repoRoot 'scripts\ForensicsReport.Core.ps1') -Raw
    $defined = [regex]::Matches($src, '(?m)^function\s+([A-Za-z-]+)') | ForEach-Object { $_.Groups[1].Value }
    @($defined | Where-Object { $_ -notmatch '^[A-Za-z]+-Fx' }).Count -eq 0
}

Write-Host "`n== Get-FxPairKey: the 68 differential cases, now pinned ==" -ForegroundColor Cyan

# The axes deliberately vary: profile vs non-profile, depth either side of the four-segment
# cut, trailing separators, UNC, drive roots, unicode, relative paths, a bare filename, and
# both with and without a caller-supplied -Dir. A generator whose every case sits on one side
# of the branch proves nothing - that lesson was paid for elsewhere in this project.
$pkPaths = @(
    'C:\Users\Admin\.ollama\models\blobs\sha256-abc\x.bin'
    'C:\Users\Admin\.cargo\registry\src\index-1a2b\crate-1.2.3\src\lib.rs'
    'C:\Users\Admin\.ssh\id_rsa'
    'C:\Users\Admin\a\b\c\d\e\f\g.txt'
    'C:\Users\Admin\one.txt'
    'C:\Users\Admin\'
    'C:\Users\Admin'
    'C:\Users\Bob Smith\App Data\x.txt'
    'C:\ProgramData\Sysmon\x.xml'
    'C:\x.txt'
    'C:\'
    'D:\.ai-work\projects\p\file.ps1'
    '\\server\share\dir\file.txt'
    ('C:\Users\Jos' + [char]0x00E8 + '\.ollama\models\x')
    'relative\path\file.txt'
    'bare.txt'
    ''
)
$pkImages = @('C:\bin\rm.exe', 'rm.exe', '', 'C:\Program Files\x\y.exe')

It 'the -Dir fast path agrees with the slow path on all 68 combinations' {
    # The gather loop hands over a precomputed parent. If the two paths ever disagree, the
    # novelty baseline silently keys some runs differently from others.
    $mismatch = 0
    foreach ($p in $pkPaths) {
        $pre = try { [IO.Path]::GetDirectoryName($p.TrimEnd('\', '/')) } catch { $null }
        foreach ($i in $pkImages) {
            $slow = Get-FxPairKey -Image $i -Path $p
            $fast = Get-FxPairKey -Image $i -Path $p -Dir $pre
            if ($slow -ne $fast) { $mismatch++ }
        }
    }
    $mismatch -eq 0
}
It 'a deep profile path is truncated to four segments below the profile' {
    (Get-FxPairKey -Image 'rm.exe' -Path 'C:\Users\Admin\a\b\c\d\e\f\g.txt') -eq 'rm.exe|C:\Users\Admin\a\b\c\d'
}
It 'a shallow profile path is left alone, so the truncation axis is non-degenerate' {
    (Get-FxPairKey -Image 'rm.exe' -Path 'C:\Users\Admin\.ssh\id_rsa') -eq 'rm.exe|C:\Users\Admin\.ssh'
}
It 'a non-profile path is not truncated at all' {
    (Get-FxPairKey -Image 'rm.exe' -Path 'D:\.ai-work\projects\p\file.ps1') -eq 'rm.exe|D:\.ai-work\projects\p'
}
It 'the process is reduced to its leaf, so full path and bare name agree' {
    (Get-FxPairKey -Image 'C:\bin\rm.exe' -Path 'C:\Users\Admin\.ssh\x') -eq
    (Get-FxPairKey -Image 'rm.exe'        -Path 'C:\Users\Admin\.ssh\x')
}
It 'a version-stamped cargo path collapses to something stable across releases' {
    # The reason truncation exists: a raw-path baseline would call every release novel forever.
    (Get-FxPairKey -Image 'rm.exe' -Path 'C:\Users\Admin\.cargo\registry\src\idx\crate-1.2.3\lib.rs') -eq
    (Get-FxPairKey -Image 'rm.exe' -Path 'C:\Users\Admin\.cargo\registry\src\idx\crate-9.9.9\lib.rs')
}
It 'a non-ASCII profile name survives intact' {
    $k = Get-FxPairKey -Image 'rm.exe' -Path ('C:\Users\Jos' + [char]0x00E8 + '\.ollama\models\x')
    $k.Contains([string][char]0x00E8)
}

Write-Host "`n== sentinel patterns ==" -ForegroundColor Cyan

It 'the compiled regex matches exactly what the pattern list matches' {
    # These two were separate code paths - one at gather time, one in the renderer - and the
    # only guarantee they agreed was that nobody had changed either.
    $pats = Get-FxSentinelPattern
    $rx = New-FxSentinelRegex -Pattern $pats
    $probe = @(
        'C:\Users\Admin\.ssh\id_rsa'
        'C:\Users\Admin\.ollama\models\blobs\x'
        'C:\Users\Admin\.dotnet\tools\x.exe'
        'C:\Users\Admin\AppData\Local\Temp\x.tmp'
        'C:\Users\Admin\.nuget\packages\x'
        'C:\Windows\System32\drivers\etc\hosts'
    )
    $bad = 0
    foreach ($p in $probe) {
        $slow = $false
        foreach ($pat in $pats) { if ($p -match $pat) { $slow = $true; break } }
        if ($slow -ne $rx.IsMatch($p)) { $bad++ }
    }
    $bad -eq 0
}
It 'a package cache is NOT a sentinel, or the tile is noise' {
    (New-FxSentinelRegex).IsMatch('C:\Users\Admin\.nuget\packages\x') -eq $false
}
It 'and a credential directory IS one' {
    (New-FxSentinelRegex).IsMatch('C:\Users\Admin\.ssh\id_rsa')
}

Write-Host "`n== the novelty baseline round-trips ==" -ForegroundColor Cyan

It 'an absent baseline reads as null rather than throwing' {
    $d = New-TempDir
    try { $null -eq (Read-FxBaseline -Path (Join-Path $d 'nope.json')) }
    finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'what Write-FxBaseline writes, Read-FxBaseline reads back' {
    $d = New-TempDir
    try {
        $p = Join-Path $d 'baseline.json'
        $ok = Write-FxBaseline -Path $p -Seen @{ 'rm.exe|C:\Users\Admin\.ssh' = 3 } -Existing $null
        $b = Read-FxBaseline -Path $p
        $ok -and $b -and ($b.Runs -eq 1) -and $b.Pairs.ContainsKey('rm.exe|C:\Users\Admin\.ssh')
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a second run increments the run count and keeps the original firstRun' {
    $d = New-TempDir
    try {
        $p = Join-Path $d 'baseline.json'
        $null = Write-FxBaseline -Path $p -Seen @{ 'a|b' = 1 } -Existing $null
        $first = Read-FxBaseline -Path $p
        $null = Write-FxBaseline -Path $p -Seen @{ 'c|d' = 1 } -Existing $first
        $second = Read-FxBaseline -Path $p
        ($second.Runs -eq 2) -and ($second.FirstRun -eq $first.FirstRun) -and
        $second.Pairs.ContainsKey('a|b') -and $second.Pairs.ContainsKey('c|d')
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a pairing seen again accumulates its count rather than replacing it' {
    $d = New-TempDir
    try {
        $p = Join-Path $d 'baseline.json'
        $null = Write-FxBaseline -Path $p -Seen @{ 'a|b' = 2 } -Existing $null
        $b1 = Read-FxBaseline -Path $p
        $null = Write-FxBaseline -Path $p -Seen @{ 'a|b' = 3 } -Existing $b1
        $b2 = Read-FxBaseline -Path $p
        [int]$b2.Pairs['a|b'].count -eq 5
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'writing into a directory that does not exist yet creates it' {
    $d = New-TempDir
    try {
        $p = Join-Path $d 'nested\deeper\baseline.json'
        (Write-FxBaseline -Path $p -Seen @{ 'a|b' = 1 } -Existing $null) -and (Test-Path -LiteralPath $p)
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n== a damaged baseline must not read as a clean slate ==" -ForegroundColor Cyan

It 'a CORRUPT baseline is distinguishable from an absent one' {
    # Both used to return $null, and the consequence was self-erasing: the caller announced
    # "first run establishes it" and overwrote the damaged file with runs = 1. The run that
    # noticed the history was broken destroyed it.
    $d = New-TempDir
    try {
        $p = Join-Path $d 'baseline.json'
        Set-Content -LiteralPath $p -Value '{"pairs":[{"key":"a|b"' -Encoding UTF8   # truncated
        $b = Read-FxBaseline -Path $p
        ($null -ne $b) -and $b.Unreadable -and ($null -eq (Read-FxBaseline -Path (Join-Path $d 'absent.json')))
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'and Write-FxBaseline REFUSES to overwrite it, moving it aside instead' {
    $d = New-TempDir
    try {
        $p = Join-Path $d 'baseline.json'
        Set-Content -LiteralPath $p -Value '{"pairs":[{"key":"a|b"' -Encoding UTF8
        $b = Read-FxBaseline -Path $p
        $wrote = Write-FxBaseline -Path $p -Seen @{ 'x|y' = 1 } -Existing $b
        # Refused, the damaged file preserved under a new name, nothing written in its place.
        (-not $wrote) -and (-not (Test-Path -LiteralPath $p)) -and
        (@(Get-ChildItem -LiteralPath $d -Filter '*.corrupt-*').Count -eq 1)
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'a pairing older than the horizon is forgotten' {
    # The tile the renderer calls "the signal a WEEKLY report is actually for" trends to zero
    # if the baseline never forgets. Pruning by count alone never fired: the cap is 5,000 and
    # this machine produces about 100 distinct pairings.
    $d = New-TempDir
    try {
        $p = Join-Path $d 'baseline.json'
        $old = (Get-Date).AddDays(-400).ToString('o')
        $existing = @{ Pairs = @{ 'ancient|dir' = [pscustomobject]@{ key = 'ancient|dir'; firstSeen = $old; lastSeen = $old; count = 1 } }
                       FirstRun = $old; Runs = 1; Unreadable = $false }
        $null = Write-FxBaseline -Path $p -Seen @{ 'fresh|dir' = 1 } -Existing $existing
        $b = Read-FxBaseline -Path $p
        $b.Pairs.ContainsKey('fresh|dir') -and (-not $b.Pairs.ContainsKey('ancient|dir'))
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
It 'one unparseable lastSeen ages out instead of killing the report' {
    # $ErrorActionPreference = 'Stop' is NOT decoration here - it is the production condition.
    # New-ForensicsReport.ps1 sets it at file level, and the offending Sort sat OUTSIDE the
    # try/catch, so one malformed date took down report generation at 04:00 on a Sunday under
    # SYSTEM. Without this line the test runs under the default 'Continue', the failed cast is
    # non-terminating, and the test passes against the BROKEN code - which is exactly what it
    # did on the first attempt. A test that does not reproduce the production condition
    # proves nothing about production.
    $d = New-TempDir
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        $p = Join-Path $d 'baseline.json'
        $existing = @{ Pairs = @{ 'bad|row' = [pscustomobject]@{ key = 'bad|row'; firstSeen = 'not-a-date'; lastSeen = 'not-a-date'; count = 1 } }
                       FirstRun = $null; Runs = 1; Unreadable = $false }
        $ok = Write-FxBaseline -Path $p -Seen @{ 'good|row' = 1 } -Existing $existing
        $b = Read-FxBaseline -Path $p
        $ok -and $b.Pairs.ContainsKey('good|row')
    } finally {
        $ErrorActionPreference = $prev
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n== resolving the interactive user, without guessing ==" -ForegroundColor Cyan

It 'Get-FxInteractiveUser reports HOW it resolved, not just what' {
    $u = Get-FxInteractiveUser
    $n = $u.PSObject.Properties.Name
    ($n -contains 'Sid') -and ($n -contains 'Profile') -and ($n -contains 'LoggedIn') -and ($n -contains 'Inferred')
}
It 'it can never return the SYSTEM SID' {
    # The whole defect: under the SYSTEM task with nobody signed in it returned S-1-5-18, whose
    # ProfileList key EXISTS, so the result looked successful and the report went to
    # C:\Windows\TEMP. The registry fallback now filters on S-1-12-1-/S-1-5-21- and a path
    # under \Users\, which S-1-5-18 satisfies neither of.
    (Get-FxInteractiveUser).Sid -ne 'S-1-5-18'
}
It 'the process identity is not a source at all' {
    # A source-level assertion, because the failure only appears when running as SYSTEM with
    # nobody logged in - a state this suite cannot enter. What CAN be checked is that the line
    # responsible no longer exists.
    (Get-Content (Join-Path $repoRoot 'scripts\ForensicsReport.Core.ps1') -Raw) -notmatch 'WindowsIdentity\]::GetCurrent'
}
It 'Inferred and LoggedIn are consistent with each other' {
    $u = Get-FxInteractiveUser
    if ($u.Sid) { $u.Inferred -eq (-not $u.LoggedIn) } else { -not $u.Inferred }
}
It 'Get-FxDownloadsPath returns an existing directory for a real user' {
    $p = Get-FxDownloadsPath -User (Get-FxInteractiveUser)
    $p -and (Test-Path -LiteralPath $p)
}
It 'and returns NOTHING rather than $env:TEMP when the user cannot be resolved' {
    # Returning $env:TEMP under SYSTEM put the report in C:\Windows\TEMP and then ran the
    # retention prune there. "I do not know where this belongs" has to be sayable.
    $null -eq (Get-FxDownloadsPath -User ([pscustomobject]@{ Sid = $null; Profile = $null }))
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
