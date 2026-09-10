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
$evil = 'C:\Users\Admin\<script>alert(1)</script>\"quoted" & ampersand'
$now = Get-Date

$deletes = @(
    [pscustomobject]@{ Time = $now; Pid = '4242'; User = 'X'; Image = 'C:\bin\rm.exe'; Path = $evil },
    [pscustomobject]@{ Time = $now; Pid = '4242'; User = 'X'; Image = 'C:\bin\rm.exe'; Path = 'C:\Users\Admin\.ssh\id_rsa' },
    # A pid with no matching process-start event: the process began before the window did.
    [pscustomobject]@{ Time = $now; Pid = '9999'; User = 'X'; Image = 'C:\bin\rm.exe'; Path = 'C:\Users\Admin\.cache\x' }
)
$byImage  = @([pscustomobject]@{ Name = 'C:\bin\rm.exe'; Count = 2 })
$byDir    = @([pscustomobject]@{ Name = $evil; Count = 1 })
$bursts   = @([pscustomobject]@{ Image = 'C:\bin\rm.exe'; Count = 90; Seconds = 12 })
$novel    = @([pscustomobject]@{ Image = 'rm.exe'; Dir = $evil; Count = 1 })
$coverage = [pscustomobject]@{ Oldest = $now.AddHours(-50); SpanHours = 50.4; FileSize = 2GB
                               MaxSize = 2GB; Full = $false; ProjectedHours = 124.0 }
$stateChanges = @([pscustomobject]@{ Time = $now; State = 'started' })
$baseline = [pscustomobject]@{ Runs = 3 }
$triage = @{ Findings = @([pscustomobject]@{ Process = 'rm.exe'; Directory = $evil
                                             Concern = 'a <b>concern</b>'; Confidence = 'high' })
             Model = 'test-model'; Rejected = 1; Reason = $null }

function New-Html {
    New-ForensicsHtml -Deletes $deletes -ByImage $byImage -ByDir $byDir -Bursts $bursts `
        -Sentinels $deletes -Coverage $coverage -UsnMax 2GB -Procs @{ '4242' = 'rm -rf /c/Users' } `
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
    $procs = @{ '4242' = 'rm <script>alert(2)</script>' }
    $html = New-ForensicsHtml -Deletes $deletes -ByImage $byImage -ByDir $byDir -Bursts $bursts `
        -Sentinels $deletes -Coverage $coverage -UsnMax 2GB -Procs $procs `
        -StateChanges $stateChanges -Days 7 -MaxRows 100 -SentinelPatterns @('\.ssh') `
        -BurstThreshold 50 -Novel $novel -Baseline $baseline -DistinctPairs 9 -Triage $triage
    ($html -notmatch '<script>alert\(2\)</script>') -and ($html -match '&lt;script&gt;alert\(2\)&lt;/script&gt;')
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

Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
