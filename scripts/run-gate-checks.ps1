#Requires -Version 5.1
<#
Run the repository hygiene checks in lib\GateChecks.ps1 and report every one of them.

THIS SCRIPT IS THE SEAM BOTH GATES SHARE. .github\workflows\gate.yml runs it in its own job;
run-gate.ps1 runs it as its first suite. That is the whole point: the six checks used to exist
only as inline PowerShell inside the workflow, so the local gate could not run them and nobody
could run them without pushing - and when an unrelated suite went red on 2026-09-11, the failing
step aborted the job and CI stopped running them too, for six days, while reporting exactly one
problem.

  .\scripts\run-gate-checks.ps1              # every check
  .\scripts\run-gate-checks.ps1 -Name parse  # one check, by name

A CHILD POWERSHELL 5.1 PROCESS IS THE CONTRACT, not an implementation detail. The parse check
calls [Parser]::ParseFile IN-PROCESS, and [Parser] uses the grammar of the host it runs in - so
dot-sourcing the library into a pwsh session would check 7's grammar, which accepts &&, ??, ?.
and ternary where 5.1 rejects them. scripts\smoke-test.ps1 records that exact defect happening
once already: the one check whose purpose was catching 7-only syntax quietly stopped doing it.
run-gate.ps1 launches this through Invoke-GateSuite, which is a 5.1 child; gate.yml pins
`shell: powershell`. The check still reports a finding if it finds itself on the wrong host.

NO $ErrorActionPreference = 'Stop' ANYWHERE IN THIS FILE, and that is deliberate rather than an
omission. Both callers run this as a CHILD process, which starts at the default 'Continue', so
the 2>&1 merge below is safe. The moment anyone adds 'Stop' here, the repo-wide native-stderr AST
rule in tests\Invoke-InstallerTests.ps1 flags that merge - the reflex is caught by an existing
gate rather than by this comment.
#>
[CmdletBinding()]
param(
    [string[]]$Name
)

$ProgressPreference = 'SilentlyContinue'
$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot 'lib\GateChecks.ps1')

# THE ONE NATIVE CALL IN THIS DESIGN, and it lives here rather than in lib\GateChecks.ps1 because
# lib\ is exposed by rule: a piped or stderr-redirected native call there must sit inside one of
# exactly three allow-listed wrapper names, and a test caps that list at three.
#
# THE MERGE IS LOAD-BEARING. Measured 2026-09-17 with markdownlint-cli 0.48.0: findings go to
# STDERR and stdout is EMPTY. Read stdout only and this reports "clean" while exiting 1.
# ErrorRecords ARE UNWRAPPED, and skipping that step makes the findings unreadable. PowerShell
# turns each stderr line from a native command into an ErrorRecord, and Out-String then renders
# it with the full decoration - "markdownlint.cmd : <path>:366 error", then "At line:1 char:12",
# then CategoryInfo and FullyQualifiedErrorId - which splits one finding across several lines and
# prefixes it. Measured 2026-09-17: the classifier's line regex matched none of it, so a real
# MD040 violation was reported as "exited 1 with no parseable findings" plus a wall of transcript.
# It still FAILED, which is the important half, but it named neither the file nor the rule.
# Taking .Exception.Message gives back the line markdownlint actually wrote.
$mdRunner = {
    param([string]$Exe, [string[]]$Arguments)
    $unwrap = {
        process {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message }
            else { [string]$_ }
        }
    }
    $ver = ''
    try { $ver = ((& $Exe '--version' 2>&1 | & $unwrap) -join ' ').Trim() } catch { $ver = '' }
    $out = (& $Exe @Arguments 2>&1 | & $unwrap) -join "`n"
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out; Version = $ver }
}

$results = Get-GateCheckResults -RepoRoot $repoRoot -Name $Name -MarkdownRunner $mdRunner `
    -Require @($PSCommandPath)

$pass = 0
$fail = 0
foreach ($r in $results) {
    if (@($r.Findings).Count -eq 0) {
        $pass++
        Write-Host ("ok   check {0}: {1}" -f $r.Check, $r.Evidence) -ForegroundColor Green
    } else {
        $fail++
        Write-Host ("FAIL check {0}: {1} finding(s)" -f $r.Check, @($r.Findings).Count) -ForegroundColor Red
        foreach ($f in $r.Findings) {
            $where = if ($f.File) { if ($f.Line) { "{0}:{1}" -f $f.File, $f.Line } else { $f.File } } else { '(repo)' }
            Write-Host ("       {0} [{1}] {2}" -f $where, $f.Rule, $f.Message) -ForegroundColor Red
        }
    }
}

# THE TALLY GOES LAST, and nothing may print after it. run-gate.ps1's Get-GateTally reads the LAST
# line matching '\d+ passed', so a finding printed below this line would make the gate report
# NO TALLY and point at the harness instead of the cause.
Write-Host ("`n{0} passed, {1} failed`n" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
