#Requires -Version 5.1
<#
    Tests for the forensics HTML renderer.

    WHY THIS FILE EXISTS. New-ForensicsReport.ps1 stated, in its own header, that the report
    fetches nothing from the network "and a test asserts it". No such test existed. That is the
    same defect class the sibling project spent an audit round removing - a confident sentence
    about something nobody ever checked - so the honest repair is to write the test rather than
    delete the sentence.

    IT DOT-SOURCES THE RENDERER ALONE, AND THAT IS THE POINT. The escaper used to be named
    ConvertTo-Html - a real PowerShell cmdlet - and lived in the CALLER. Loading only this file,
    which is the natural first line of any render test, made all 27 call sites silently resolve
    to Microsoft.PowerShell.Utility\ConvertTo-Html: user data dropped, and two w3.org URLs
    injected into the "self-contained" report. So the test that would have caught the bug was
    also the test that would have triggered it. Both are fixed; this pins them.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-RenderTests.ps1
#>
[CmdletBinding()]
param()

# The deletion tripwire, the suite floor and the arm-time control. FIRST, before every other
# dot-source: the Remove-Item shadow must be defined before any library can bind to the real
# cmdlet. $PSScriptRoot rather than $repoRoot so this needs nothing computed first.
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')

# AFTER the guard, BEFORE the subject, deliberately. gate.yml asserts the deletion guard is the
# FIRST dot-source in every suite; Set-StrictMode is not a dot-source so it cannot disturb that,
# and putting it here means the renderer below and every It body run strict.
#
# WHAT IT BOUGHT, measured: 4 passed, 19 failed on the first strict run, all 19 the same cause -
# the $bursts fixture below supplied three of a burst's seven properties. Because
# '{0:yyyy-MM-dd HH:mm:ss}' -f $null is an EMPTY STRING and not an error, the burst rows had
# rendered with a blank time range and no directory list since the day this suite was written,
# and every assertion in it passed anyway. StrictMode is not the point; the fixture was wrong.
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\ForensicsReport.Render.ps1')

$script:Pass = 0; $script:Fail = 0
function It {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        if (& $Body) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
    } catch { $script:Fail++; Write-Host "  FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red }
}

# A path carrying an injection attempt, threaded through every collection the renderer reads so
# no single escaped site can carry the test.
#
# Split into parent + leaf so each record's Dir below is the real parent of its Path BY
# CONSTRUCTION. [IO.Path]::GetDirectoryName - which is what the gather loop uses - cannot be
# called on this string at all: <, > and " are invalid path characters and it throws under .NET
# Framework, so deriving Dir the production way here would break the injection fixture. The
# concatenation is the honest alternative; $evil is byte-identical to what it was.
$evilDir = 'C:\Users\Admin\<script>alert(1)</script>'
$evil = $evilDir + '\"quoted" & ampersand'
$now = Get-Date

# Dir is part of the delete-record contract, not an extra: the gather loop computes it once per
# event (New-ForensicsReport.ps1:138) and Render.ps1:178 says in so many words that every record
# already carries the parent so nothing downstream has to Split-Path. This fixture omitted it.
# Measured consequence, not a guess: `$Sentinels | ForEach-Object { $_.Dir }` on records without
# Dir emits NOTHING rather than four $nulls, so Group-Object produced ZERO groups and the
# Sentinel paths tile rendered a headline of "4" above a drawer reading "None this period." -
# the tile contradicting itself in two adjacent elements, under 23 green tests.
#
# IsSentinel is DELIBERATELY still absent here, and that is not an oversight. Production records
# carry it, but the renderer probes for it with PSObject.Properties['IsSentinel'] rather than
# reading it blind, precisely so a caller handing over raw records still gets the right answer -
# and the "precomputed IsSentinel flag" test below exists to compare the flag-present path
# against the flag-absent fallback. Adding it here would make both sides of that comparison the
# same path and silently retire the test.
$deletes = @(
    [pscustomobject]@{ Time = $now; Pid = '4242'; Guid = 'g-real'; User = 'X'; Image = 'C:\bin\rm.exe'; Path = $evil; Dir = $evilDir },
    [pscustomobject]@{ Time = $now; Pid = '4242'; Guid = 'g-real'; User = 'X'; Image = 'C:\bin\rm.exe'; Path = 'C:\Users\Admin\.ssh\id_rsa'; Dir = 'C:\Users\Admin\.ssh' },
    # Same PID, different process. This is the pid-reuse case: on a real box a short-lived
    # process inherits a recycled pid, and a pid-keyed join hands it the other one's argv.
    [pscustomobject]@{ Time = $now; Pid = '4242'; Guid = 'g-reused'; User = 'X'; Image = 'C:\Windows\system32\cmd.exe'; Path = 'C:\Users\Admin\.cache\y'; Dir = 'C:\Users\Admin\.cache' },
    # No matching process-start event at all: the process began before the window did.
    [pscustomobject]@{ Time = $now; Pid = '9999'; Guid = 'g-absent'; User = 'X'; Image = 'C:\bin\rm.exe'; Path = 'C:\Users\Admin\.cache\x'; Dir = 'C:\Users\Admin\.cache' }
)
$byImage  = @([pscustomobject]@{ Name = 'C:\bin\rm.exe'; Count = 2 })
$byDir    = @([pscustomobject]@{ Name = $evil; Count = 1 })
# A burst carries SEVEN properties in production (New-ForensicsReport.ps1:188-193) and the
# renderer formats all seven. This fixture supplied three; Start, End, Total and Dirs were
# absent. Measured on the pre-fix fixture: the meta line rendered as
#   <div class="meta"> to  &middot;  deletions from this process in the whole window</div>
# - both timestamps AND the total blank, because '{0:N0}' -f $null is '' and not '0' - the hero
# said "Largest burst: rm.exe at ." and the directory <ul> was skipped entirely by
# `if (@($b.Dirs).Count)`. None of that threw.
#
# The values are constrained rather than decorative:
#   Seconds is DERIVED in production - [math]::Max(1, [int](($End - $Start).TotalSeconds)) - so
#     End must be Start + Seconds, or the fixture states two different burst durations and a
#     renderer that read the wrong one would still look right.
#   Total is the process's count across the WHOLE window and is therefore > Count, which counts
#     only the densest sub-window. Equal values would let the two be swapped undetectably.
#   Dirs is Group-Object output in production, so it is built with Group-Object here instead of
#     hand-rolled into a pscustomobject: the renderer reads .Name/.Count off a real GroupInfo.
#     $evil is threaded through it like every other collection the renderer reads, because this
#     is a fifth escape site and nothing reached it before.
$burstStart = $now.AddMinutes(-9)
$burstDirs  = @(@($evil, $evil, 'C:\Users\Admin\.cache') | Group-Object | Sort-Object Count -Descending)
$bursts   = @([pscustomobject]@{ Image = 'C:\bin\rm.exe'; Count = 90; Total = 140
                                 Start = $burstStart; End = $burstStart.AddSeconds(12)
                                 Seconds = 12; Dirs = $burstDirs })
$novel    = @([pscustomobject]@{ Image = 'rm.exe'; Dir = $evil; Count = 1 })
$coverage = [pscustomobject]@{ Oldest = $now.AddHours(-50); SpanHours = 50.4; FileSize = 2GB
                               MaxSize = 2GB; Full = $false; ProjectedHours = 124.0 }
$stateChanges = @([pscustomobject]@{ Time = $now; State = 'started' })
$baseline = [pscustomobject]@{ Runs = 3 }
$triage = @{ Findings = @([pscustomobject]@{ Process = 'rm.exe'; Directory = $evil
                                             Concern = 'a <b>concern</b>'; Confidence = 'high' })
             Model = 'test-model'; Rejected = 1; Reason = $null }

# Keyed by ProcessGuid. 'g-reused' is a DIFFERENT process that happened to get pid 4242.
$procsFixture = @{ 'g-real' = 'rm -rf /c/Users'; 'g-reused' = 'cmd.exe /c ping -n 1 1.1.1.1' }

function New-Html {
    New-ForensicsHtml -Deletes $deletes -ByImage $byImage -ByDir $byDir -Bursts $bursts `
        -Sentinels $deletes -Coverage $coverage -UsnMax 2GB -Procs $procsFixture `
        -StateChanges $stateChanges -Days 7 -MaxRows 100 -SentinelPatterns @('\.ssh') `
        -BurstThreshold 50 -Novel $novel -Baseline $baseline -DistinctPairs 9 -Triage $triage
}

Write-Host "`n== loading the renderer alone must not resolve to the built-in cmdlet ==" -ForegroundColor Cyan

It 'ConvertTo-FxHtml is this file''s function, not Microsoft.PowerShell.Utility''s' {
    $cmd = Get-Command ConvertTo-FxHtml -ErrorAction SilentlyContinue
    $cmd -and ($cmd.CommandType -eq 'Function')
}
It 'and it escapes rather than emitting an XHTML document' {
    $out = ConvertTo-FxHtml '<b> & "x"'
    ($out -eq '&lt;b&gt; &amp; &quot;x&quot;')
}

Write-Host "`n== the report fetches nothing from anywhere ==" -ForegroundColor Cyan

It 'no http(s) URL appears anywhere in the rendered page' {
    # The claim the header makes. A report is opened offline, months later, mid-incident.
    $html = New-Html
    -not ($html -match 'https?://')
}
It 'no external script, stylesheet, font or image reference' {
    $html = New-Html
    -not ($html -match '<script[^>]+src=') -and -not ($html -match '<link[^>]+href=') -and
    -not ($html -match '@import') -and -not ($html -match 'url\(\s*[''"]?https?:')
}

Write-Host "`n== user-controlled text is escaped, everywhere it is shown ==" -ForegroundColor Cyan

It 'an injected script tag never reaches the page unescaped' {
    $html = New-Html
    ($html -notmatch '<script>alert\(1\)</script>') -and ($html -match '&lt;script&gt;alert\(1\)&lt;/script&gt;')
}
It 'quotes and ampersands in a path are escaped' {
    $html = New-Html
    ($html -match '&quot;quoted&quot;') -and ($html -match '&amp; ampersand')
}
It 'and the model triage panel escapes its text too' {
    # Model output is text from outside the program, and is rendered into HTML like any other.
    $html = New-Html
    $html -match 'a &lt;b&gt;concern&lt;/b&gt;'
}

Write-Host "`n== the command line behind a deletion is actually shown ==" -ForegroundColor Cyan

It 'the command line reaches the page, rather than being gathered and discarded' {
    # -Procs was passed to this renderer and referenced nowhere in its body: the report knew the
    # argv and never printed it. That is the whole point of joining event 1 to event 26.
    $html = New-Html
    $html -match 'rm -rf /c/Users'
}
It 'deletions with no matching process-start are reported, not silently dropped' {
    # A partial join presented as a whole one is a wrong answer. One of the three fixture
    # deletions has an unknown pid.
    $html = New-Html
    $html -match '1 deletion\(s\) have no matching process-start event'
}
It 'and a command line is escaped like any other untrusted text' {
    $procs = @{ 'g-real' = 'rm <script>alert(2)</script>' }
    $html = New-ForensicsHtml -Deletes $deletes -ByImage $byImage -ByDir $byDir -Bursts $bursts `
        -Sentinels $deletes -Coverage $coverage -UsnMax 2GB -Procs $procs `
        -StateChanges $stateChanges -Days 7 -MaxRows 100 -SentinelPatterns @('\.ssh') `
        -BurstThreshold 50 -Novel $novel -Baseline $baseline -DistinctPairs 9 -Triage $triage
    ($html -notmatch '<script>alert\(2\)</script>') -and ($html -match '&lt;script&gt;alert\(2\)&lt;/script&gt;')
}

It 'two processes sharing a recycled pid do not share a command line' {
    # The bug this replaced: the join keyed on ProcessId with last-writer-wins, so a ping that
    # inherited a recycled pid was credited with 955 deletions on the first real report. Both
    # fixture processes use pid 4242; only the one that actually deleted may be credited.
    $html = New-Html
    # The real deleter's argv appears...
    ($html -match 'rm -rf /c/Users') -and
    # ...and the ping is credited with exactly its own single deletion, not the other three.
    ($html -match '<td class="t">1</td><td class="p">cmd\.exe /c ping') -and
    ($html -notmatch '<td class="t">[34]</td><td class="p">cmd\.exe /c ping')
}

Write-Host "`n== a burst says WHEN it happened, and how big the window really was ==" -ForegroundColor Cyan
# These four exist because the four properties they read were missing from the fixture above and
# nothing noticed. Each asserts the RENDERED page rather than the fixture: a test that only
# proves the renderer no longer throws would have been satisfied by adding the properties and
# reading nothing back, which is the state this section is here to end.

It 'the burst time range renders as two real timestamps, not two empty strings' {
    # A SHAPE regex, not a re-run of the renderer's own format string: re-deriving
    # '{0:yyyy-MM-dd HH:mm:ss}' -f $b.Start here would pass against $null on both sides.
    # With Start or End absent the meta line is '<div class="meta"> to  &middot;' and this fails.
    $html = New-Html
    $html -match '<div class="meta">\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} to \d{2}:\d{2}:\d{2} &middot;'
}
It 'and the hero headline dates the largest burst' {
    # The one number a reader sees first, and the only place $topBurst.Start is read. It said
    # "Largest burst: rm.exe at ." for as long as this suite has existed.
    $html = New-Html
    $html -match 'Largest burst: rm\.exe at \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\. A mass deletion'
}
It 'a burst reports the whole-window total as well as the burst count' {
    # Two different numbers doing two different jobs: 90 files in 12 seconds, out of 140 from
    # that process all week. A $null Total did not render as "0" - '{0:N0}' -f $null is an EMPTY
    # string - so the sentence read " deletions from this process in the whole window", a blank
    # where the number belongs, sitting beside a count of 90.
    $html = New-Html
    ($html -match '90 files / 12s \(7\.5/s\)') -and
    ($html -match '140 deletions from this process in the whole window')
}
It 'the sentinel tile groups deletions by real directory, not into one blank row' {
    # $Sentinels is grouped on $_.Dir. With Dir absent the pipeline emitted nothing, so the tile
    # showed "4" in its headline and "None this period." in its drawer. Asserting the NAMES is
    # what distinguishes "the tile rendered" from "the tile is right": the headline count was
    # already correct in the broken version, which is exactly why nothing caught it.
    $html = New-Html
    ($html -match [regex]::Escape('<li><span class="k">C:\Users\Admin\.cache</span><span class="v">2</span></li>')) -and
    ($html -match [regex]::Escape('<li><span class="k">C:\Users\Admin\.ssh</span><span class="v">1</span></li>')) -and
    # ...and the grouped directory name is escaped, which is a sixth site nothing reached.
    ($html -match [regex]::Escape('<li><span class="k">C:\Users\Admin\&lt;script&gt;alert(1)&lt;/script&gt;</span><span class="v">1</span></li>'))
}
It 'the burst directory breakdown reaches the page, escaped like every other untrusted text' {
    # The fifth escape site in this renderer, and the only one no test reached. It was not
    # under-asserted, it was unreachable: $b.Dirs was absent, so `if (@($b.Dirs).Count)` was
    # false and the entire <ul> never rendered. The counts are asserted too, so a Dirs list
    # rendered with the wrong tally is not mistaken for coverage.
    $html = New-Html
    ($html -match [regex]::Escape('<li>C:\Users\Admin\&lt;script&gt;alert(1)&lt;/script&gt;\&quot;quoted&quot; &amp; ampersand &mdash; 2</li>')) -and
    ($html -match [regex]::Escape('<li>C:\Users\Admin\.cache &mdash; 1</li>'))
}

Write-Host "`n== a baseline that could not be read is not a baseline with nothing in it ==" -ForegroundColor Cyan

function New-HtmlWithBaselineState {
    param([switch]$Unreadable, $BaselineObj, $NovelRows)
    New-ForensicsHtml -Deletes $deletes -ByImage $byImage -ByDir $byDir -Bursts $bursts `
        -Sentinels $deletes -Coverage $coverage -UsnMax 2GB -Procs $procsFixture `
        -StateChanges $stateChanges -Days 7 -MaxRows 100 -SentinelPatterns @('\.ssh') `
        -BurstThreshold 50 -Novel $NovelRows -Baseline $BaselineObj -DistinctPairs 9 `
        -Triage $triage -BaselineUnreadable:$Unreadable
}

It 'an unreadable baseline says so at the top of the page' {
    # Fixing "a lost history reads as a clean slate" halfway turned it into "a lost history
    # reads as a SUSPICIOUS WEEK": Pairs is empty, so every pairing comes back novel and the
    # operator gets a full false-positive list with no explanation. Worse than what it replaced.
    $html = New-HtmlWithBaselineState -Unreadable -BaselineObj @{ Runs = 0; Pairs = @{} } -NovelRows $novel
    $html -match 'BASELINE UNREADABLE'
}
It 'and does NOT present the resulting false-positive list' {
    $html = New-HtmlWithBaselineState -Unreadable -BaselineObj @{ Runs = 0; Pairs = @{} } -NovelRows $novel
    # $novel here is the everything-looks-new list an empty Pairs set produces.
    $html -notmatch [regex]::Escape($novel[0].Dir)
}
It 'and does NOT claim "Nothing new" anywhere on the page' {
    # This assertion is here because its absence hid a real bug. The banner and the tile were
    # given an unreadable arm; the "Never seen before" PANEL was not, so the page carried a
    # BASELINE UNREADABLE warning at the top and a false all-clear further down. Asserting only
    # that the novel Dir is absent did not catch it - that sentence does not contain the Dir.
    $html = New-HtmlWithBaselineState -Unreadable -BaselineObj @{ Runs = 0; Pairs = @{} } -NovelRows @()
    ($html -notmatch 'Nothing new') -and ($html -match 'Not computed')
}
It 'a healthy baseline still shows its novelty list, so the guard is not just suppression' {
    # The positive control. A tile that never shows anything is as useless as one that shows
    # everything.
    $html = New-HtmlWithBaselineState -BaselineObj $baseline -NovelRows $novel
    ($html -notmatch 'BASELINE UNREADABLE') -and ($html -match [regex]::Escape($novel[0].Image))
}

Write-Host "`n== the hot loop's shortcut must not change what is rendered ==" -ForegroundColor Cyan

It 'using the precomputed IsSentinel flag produces the same page as re-matching the patterns' {
    # The row loop now trusts $r.IsSentinel when present instead of re-running 15 regexes per
    # row. That is only safe while the flag and the patterns agree - and in production they do,
    # because the gather loop computes the flag from the same list. This asserts it rather than
    # assuming it: the same rows rendered both ways must produce byte-identical HTML.
    $pats = @('\\\.ssh($|\\)')
    $withFlag = @($deletes | ForEach-Object {
        $m = $false
        foreach ($pat in $pats) { if ($_.Path -match $pat) { $m = $true; break } }
        # Dir is carried across too. It is not read off -Deletes by the renderer today, but a
        # projection of a delete record that quietly drops a contract property is a trap for
        # whoever next passes $withFlag as -Sentinels.
        [pscustomobject]@{ Time = $_.Time; Pid = $_.Pid; Guid = $_.Guid; User = $_.User
                           Image = $_.Image; Path = $_.Path; Dir = $_.Dir; IsSentinel = $m }
    })
    $common = @{ ByImage = $byImage; ByDir = $byDir; Bursts = $bursts; Coverage = $coverage
                 UsnMax = 2GB; Procs = $procsFixture; StateChanges = $stateChanges; Days = 7
                 MaxRows = 100; SentinelPatterns = $pats; BurstThreshold = 50; Novel = $novel
                 Baseline = $baseline; DistinctPairs = 9; Triage = $triage }
    $a = New-ForensicsHtml -Deletes $deletes  -Sentinels $deletes @common
    $b = New-ForensicsHtml -Deletes $withFlag -Sentinels $deletes @common
    # The timestamp in the header differs between calls, so compare the rows only.
    $rowsA = ($a -split "`n" | Where-Object { $_ -like '<tr*' }) -join "`n"
    $rowsB = ($b -split "`n" | Where-Object { $_ -like '<tr*' }) -join "`n"
    ($rowsA -eq $rowsB) -and ($rowsA -match 'class="sent"')
}

Write-Host "`n== the report says whose machine it is describing ==" -ForegroundColor Cyan

It 'an INFERRED user produces a warning banner at the top of the page' {
    # Under the SYSTEM task with nobody signed in, the profile is a registry guess and can be a
    # stranger's on a multi-profile machine. A reader who misses that misreads everything under
    # it, so it is stated before the first number rather than in a footnote.
    $html = New-ForensicsHtml -Deletes $deletes -ByImage $byImage -ByDir $byDir -Bursts $bursts `
        -Sentinels $deletes -Coverage $coverage -UsnMax 2GB -Procs $procsFixture `
        -StateChanges $stateChanges -Days 7 -MaxRows 100 -SentinelPatterns @('\.ssh') `
        -BurstThreshold 50 -Novel $novel -Baseline $baseline -DistinctPairs 9 -Triage $triage `
        -User ([pscustomobject]@{ Sid = 'S-1-5-21-x'; Profile = 'C:\Users\Someone'; LoggedIn = $false; Inferred = $true })
    ($html -match 'INFERRED USER') -and ($html -match 'inferred, not observed')
}
It 'a CONFIRMED user produces no banner - or the warning becomes wallpaper' {
    # The positive control. A banner shown every week is one nobody reads.
    $html = New-ForensicsHtml -Deletes $deletes -ByImage $byImage -ByDir $byDir -Bursts $bursts `
        -Sentinels $deletes -Coverage $coverage -UsnMax 2GB -Procs $procsFixture `
        -StateChanges $stateChanges -Days 7 -MaxRows 100 -SentinelPatterns @('\.ssh') `
        -BurstThreshold 50 -Novel $novel -Baseline $baseline -DistinctPairs 9 -Triage $triage `
        -User ([pscustomobject]@{ Sid = 'S-1-5-21-x'; Profile = 'C:\Users\Someone'; LoggedIn = $true; Inferred = $false })
    ($html -notmatch 'INFERRED USER') -and ($html -match 'C:\\Users\\Someone \(signed in\)')
}
It 'and the profile name is escaped like any other untrusted text' {
    $html = New-ForensicsHtml -Deletes $deletes -ByImage $byImage -ByDir $byDir -Bursts $bursts `
        -Sentinels $deletes -Coverage $coverage -UsnMax 2GB -Procs $procsFixture `
        -StateChanges $stateChanges -Days 7 -MaxRows 100 -SentinelPatterns @('\.ssh') `
        -BurstThreshold 50 -Novel $novel -Baseline $baseline -DistinctPairs 9 -Triage $triage `
        -User ([pscustomobject]@{ Sid = 'x'; Profile = 'C:\Users\<script>alert(3)</script>'; LoggedIn = $true; Inferred = $false })
    ($html -notmatch '<script>alert\(3\)</script>') -and ($html -match '&lt;script&gt;alert\(3\)&lt;/script&gt;')
}

Write-Host "`n== entities must render as entities, not as their own source text ==" -ForegroundColor Cyan

It 'the header separator is a real entity, not the literal text &middot;' {
    # Passing "&middot;" through the escaper turns & into &amp; and the page shows the source.
    $html = New-Html
    ($html -match '&middot;') -and ($html -notmatch '&amp;middot;')
}
It 'the coverage arrow is a real entity too' {
    $html = New-Html
    $html -notmatch '&amp;rarr;'
}

Write-Host "`n== byte formatting covers the sizes this report actually shows ==" -ForegroundColor Cyan

It 'a terabyte is not four figures of GB' {
    (Format-FxBytes 2TB) -match '^2\.00 TB$'
}
It 'and the smaller tiers still read correctly' {
    ((Format-FxBytes 512) -eq '512 B') -and ((Format-FxBytes 2GB) -eq '2.00 GB')
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
