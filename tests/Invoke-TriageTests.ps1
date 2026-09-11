#Requires -Version 5.1
<#
    Tests for the model-assisted triage layer.

    Every one of these runs WITHOUT Ollama. That is deliberate and not a convenience: the thing
    worth testing is the validation - that a claim citing something the model was never shown is
    discarded - and a test whose result depends on what a model happens to say today is a test
    that will fail for reasons unrelated to the code.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-TriageTests.ps1
#>
[CmdletBinding()]
param()

# The deletion tripwire, the suite floor and the arm-time control. FIRST, before every other
# dot-source: the Remove-Item shadow must be defined before any library can bind to the real
# cmdlet. $PSScriptRoot rather than $repoRoot so this needs nothing computed first.
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\ForensicsReport.Triage.ps1')

$script:Pass = 0; $script:Fail = 0
function It {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        if (& $Body) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
    } catch { $script:Fail++; Write-Host "  FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red }
}

# The facts a report would hand over. Everything the model is permitted to name is in here.
$facts = @{
    TopProcesses = @(
        [pscustomobject]@{ Name = 'C:\Anthropic\.Git\usr\bin\rm.exe'; Count = 400 },
        [pscustomobject]@{ Name = 'C:\Program Files\PowerShell\7\pwsh.exe'; Count = 120 })
    Bursts = @(
        [pscustomobject]@{ Image = 'C:\Anthropic\.Git\usr\bin\rm.exe'; Count = 300; Seconds = 12 })
    Novel = @(
        [pscustomobject]@{ Image = 'rm.exe'; Dir = 'C:\Users\Admin\.ollama\models'; Count = 74 })
    Sentinels = @(
        [pscustomobject]@{ Image = 'rm.exe'; Dir = 'C:\Users\Admin\.ssh'; Count = 2 })
}

Write-Host "`n== the model must point at facts, or be discarded ==" -ForegroundColor Cyan

It 'a well-cited finding is kept' {
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\Users\\Admin\\.ssh","concern":"deletions in an ssh directory","confidence":"high"}]}'
    }
    ($r.Findings.Count -eq 1) -and ($r.Findings[0].Process -eq 'rm.exe') -and ($r.Rejected -eq 0)
}
It 'a finding naming a process it was never shown is DISCARDED' {
    # The core guarantee. A hallucinated process name is cheaply detectable, so detecting it is
    # not optional - this is the same rule the code follows: point at a fact or do not claim.
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"evil-malware.exe","directory":"C:\\Users\\Admin\\.ssh","concern":"scary","confidence":"high"}]}'
    }
    ($r.Findings.Count -eq 0) -and ($r.Rejected -eq 1)
}
It 'a finding naming a directory it was never shown is DISCARDED' {
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\Windows\\System32","concern":"invented","confidence":"high"}]}'
    }
    ($r.Findings.Count -eq 0) -and ($r.Rejected -eq 1)
}
It 'a parent directory of one it WAS shown is accepted as imprecision, not invention' {
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\Users\\Admin\\.ollama","concern":"model store touched","confidence":"medium"}]}'
    }
    $r.Findings.Count -eq 1
}
Write-Host "`n== a citation must be specific enough to be a citation ==" -ForegroundColor Cyan
# These axes were all missing. Every "invented directory" case above uses a full path sharing no
# prefix with anything shown, so the generator never produced a case in the region where the
# check was actually weak - and an audit then demonstrated two live bypasses. Same degenerate-axis
# trap as the earlier differential-test finding: the cases were plentiful and all one shape.
It 'a one-character directory is DISCARDED, not treated as a prefix of everything' {
    # The worst case: "C" is a prefix of every path this ever shows, so the model could attach any
    # concern at all to it and the panel would report "0 discarded" while rendering it as a lead.
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C","concern":"vacuous","confidence":"high"}]}'
    }
    ($r.Findings.Count -eq 0) -and ($r.Rejected -eq 1)
}
It 'a bare drive root is DISCARDED' {
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\","concern":"vacuous","confidence":"high"}]}'
    }
    ($r.Findings.Count -eq 0) -and ($r.Rejected -eq 1)
}
It 'a two-segment ancestor is DISCARDED as too broad to mean anything' {
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\Users","concern":"too broad","confidence":"high"}]}'
    }
    ($r.Findings.Count -eq 0) -and ($r.Rejected -eq 1)
}
It 'a CHILD of a shown directory is DISCARDED - that is invention, not imprecision' {
    # The most dangerous shape, because a specific invented path reads as the most authoritative
    # thing on the page.
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\Users\\Admin\\.ssh\\exfiltrated-to-attacker","concern":"invented","confidence":"high"}]}'
    }
    ($r.Findings.Count -eq 0) -and ($r.Rejected -eq 1)
}
It 'a partial-segment near-miss is DISCARDED' {
    # "C:\Users\Ad" is a string prefix of "C:\Users\Admin\..." but not a path ancestor.
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\Users\\Ad","concern":"near miss","confidence":"high"}]}'
    }
    ($r.Findings.Count -eq 0) -and ($r.Rejected -eq 1)
}
It 'but a genuine three-segment ancestor is still KEPT, so the fix did not just reject everything' {
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\Users\\Admin","concern":"legitimate imprecision","confidence":"medium"}]}'
    }
    $r.Findings.Count -eq 1
}
It 'an uppercase confidence is normalised, not silently rendered verbatim' {
    # -notin is case-insensitive, so "HIGH" passed the validity check and reached the HTML
    # unnormalised. It is a valid answer typed loudly - normalise it rather than downgrade it.
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\Users\\Admin\\.ssh","concern":"x","confidence":"HIGH"}]}'
    }
    # -ceq, not -eq. PowerShell's -eq is CASE-INSENSITIVE, so 'HIGH' -eq 'high' is true and
    # this test passed with or without the normalisation it exists to pin - a mutation
    # removing .ToLowerInvariant() survived it. The test reproduced the very defect its own
    # comment describes.
    ($r.Findings.Count -eq 1) -and ($r.Findings[0].Confidence -ceq 'high')
}

It 'good and bad findings in one response are separated, not both dropped' {
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"nope.exe","directory":"C:\\Users\\Admin\\.ssh","concern":"a","confidence":"high"},{"process":"pwsh.exe","directory":"C:\\Users\\Admin\\.ollama\\models","concern":"b","confidence":"low"}]}'
    }
    ($r.Findings.Count -eq 1) -and ($r.Rejected -eq 1) -and ($r.Findings[0].Process -eq 'pwsh.exe')
}
It 'a finding missing its concern is discarded' {
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\Users\\Admin\\.ssh","confidence":"high"}]}'
    }
    ($r.Findings.Count -eq 0) -and ($r.Rejected -eq 1)
}
It 'an invented confidence value is normalised, not trusted' {
    $r = Get-FxTriage -Facts $facts -Responder {
        '{"findings":[{"process":"rm.exe","directory":"C:\\Users\\Admin\\.ssh","concern":"x","confidence":"ABSOLUTELY CERTAIN"}]}'
    }
    ($r.Findings.Count -eq 1) -and ($r.Findings[0].Confidence -eq 'low')
}
It 'at most four findings survive, however many are returned' {
    $many = (1..9 | ForEach-Object { '{"process":"rm.exe","directory":"C:\\Users\\Admin\\.ssh","concern":"c' + $_ + '","confidence":"low"}' }) -join ','
    $r = Get-FxTriage -Facts $facts -Responder { '{"findings":[' + $many + ']}' }
    $r.Findings.Count -eq 4
}

Write-Host "`n== a degraded model must look exactly like an absent one ==" -ForegroundColor Cyan

It 'no response at all yields no findings and no error' {
    $r = Get-FxTriage -Facts $facts -Responder { $null }
    ($r.Findings.Count -eq 0) -and ($r.Reason -eq 'no response')
}
It 'prose instead of JSON yields no findings' {
    $r = Get-FxTriage -Facts $facts -Responder { 'Certainly! Here is my analysis of the deletions...' }
    ($r.Findings.Count -eq 0) -and ($r.Reason -eq 'response was not JSON')
}
It 'valid JSON of the wrong shape yields no findings' {
    $r = Get-FxTriage -Facts $facts -Responder { '{"summary":"all fine"}' }
    ($r.Findings.Count -eq 0) -and ($r.Reason -eq 'no findings in response')
}
It 'an empty findings array is a legitimate answer, not a failure' {
    # "Nothing here is worth your attention" is a useful thing for it to be able to say.
    $r = Get-FxTriage -Facts $facts -Responder { '{"findings":[]}' }
    ($r.Findings.Count -eq 0) -and ($r.Rejected -eq 0)
}
It 'a responder that throws is handled like any other failure' {
    $r = Get-FxTriage -Facts $facts -Responder { throw 'connection reset' }
    $r.Findings.Count -eq 0
}
It 'and a dead endpoint returns nothing rather than throwing' {
    # Measured failure mode under 5.1: System.Net.WebException, "Unable to connect to the
    # remote server". The report must not care which.
    $null -eq (Invoke-FxLlm -Prompt 'hi' -BaseUri 'http://127.0.0.1:11499' -TimeoutSec 3)
}
It 'Test-FxLlmAvailable reports false for a dead endpoint' {
    -not (Test-FxLlmAvailable -BaseUri 'http://127.0.0.1:11499' -TimeoutSec 3)
}

It 'the request declares utf-8, because 5.1 silently mis-encodes without it' {
    # A source-level assertion, deliberately. This is a WRONG-ANSWER bug, not an error: under
    # 5.1 a body sent as plain 'application/json' goes out in the ANSI codepage, so an accented
    # username reaches the model as different bytes and nothing anywhere reports a problem.
    # pwsh 7 is correct either way, so a behavioural test would pass on a dev box and the
    # scheduled task - the only 5.1 caller - would keep shipping corrupted prompts. Guarding the
    # parameter itself is the only check that fails when someone tidies it away.
    $src = Get-Content (Join-Path $repoRoot 'scripts\ForensicsReport.Triage.ps1') -Raw
    $src -match "charset=utf-8"
}

Write-Host "`n== the model asked for must be one that is installed ==" -ForegroundColor Cyan
# The default tag was correct on exactly one machine. Everywhere else Ollama 404s, triage
# degrades silently, and the report looks identical to a box with no model at all - so the
# feature would have been on by default and never once run.
It 'an exactly-installed preferred model is used as-is' {
    (Resolve-FxTriageModel -Preferred 'mistral-small3.2:24b' -Installed @('llama3:8b','mistral-small3.2:24b')) -eq 'mistral-small3.2:24b'
}
It 'a different tag of the same family is accepted' {
    # What install-llm.ps1 actually pulls is "mistral-small"; the default asked for a tag it
    # never creates.
    (Resolve-FxTriageModel -Preferred 'mistral-small3.2:24b' -Installed @('mistral-small:latest')) -eq 'mistral-small:latest'
}
It 'and the family match works in the other direction too' {
    (Resolve-FxTriageModel -Preferred 'mistral-small' -Installed @('mistral-small3.2:24b')) -eq 'mistral-small3.2:24b'
}
It 'an unrelated chat model is used rather than giving up' {
    (Resolve-FxTriageModel -Preferred 'mistral-small' -Installed @('qwen3:8b')) -eq 'qwen3:8b'
}
It 'embedding and reranker models are never chosen - they cannot answer the prompt' {
    $null -eq (Resolve-FxTriageModel -Preferred 'mistral-small' -Installed @('bge-m3:latest','qwen3-embedding:0.6b'))
}
It 'nothing installed yields no model, not a guess' {
    $null -eq (Resolve-FxTriageModel -Preferred 'mistral-small' -Installed @())
}

Write-Host "`n== the prompt shows only aggregates, never the raw log ==" -ForegroundColor Cyan
It 'the prompt names every fact category and asks for citations' {
    $p = ConvertTo-FxTriagePrompt -Facts $facts
    ($p -match 'TOP PROCESSES') -and ($p -match 'BURSTS') -and ($p -match 'NEVER SEEN') -and
    ($p -match 'QUIET, VALUABLE') -and ($p -match 'VERBATIM')
}
It 'and it contains no individual file paths' {
    # Aggregates only. A model handed 9,000 rows is invited to summarise facts the report
    # already states exactly - the least useful and most error-prone thing it could do.
    $p = ConvertTo-FxTriagePrompt -Facts $facts
    -not ($p -match '\.tmp|\.bin|sha256-')
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
