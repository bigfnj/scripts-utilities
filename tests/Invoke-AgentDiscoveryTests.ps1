#Requires -Version 5.1
<#
    Tests for lib\AgentDiscovery.ps1 - the extractor that obtains Write-AgentDiscovery's body
    WITHOUT deploying it, plus the drift helpers the smoke test compares deployed blocks with.

    WHY THIS FILE EXISTS AT ALL. Get-AgentDiscoveryBody ends in `& $sb` over source assembled
    from lib\common.ps1 - a file it does not own - so its allowlist is the only thing standing
    between the gate and executing whatever that generator happens to contain. Until 2026-09-17
    that allowlist had no tests, and it had two holes: it walked CommandAst only, so every METHOD
    invocation was invisible to it, and it cleared the ASSIGNMENTS while splicing two argument
    expressions per Write-AgentBlock call into the same scriptblock unexamined.

    Every fixture is a synthetic lib\common.ps1 under %TEMP%. The real one is used for exactly one
    control test, which is the only way to know the extractor still works on the file that
    matters.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-AgentDiscoveryTests.ps1
#>
[CmdletBinding()]
param()

# The deletion tripwire, the suite floor and the arm-time control. FIRST, before every other
# dot-source: the Remove-Item shadow must be defined before any library can bind to the real
# cmdlet. $PSScriptRoot rather than $repoRoot so this needs nothing computed first.
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\AgentDiscovery.ps1')

$script:Pass = 0; $script:Fail = 0
function It {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        if (& $Body) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
    } catch { $script:Fail++; Write-Host "  FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentdisc-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

function New-ADFixture {
    <#
        A synthetic lib\common.ps1 holding one Write-AgentDiscovery. Each parameter injects
        exactly one deviation, so a refusal can only have come from the thing under test.

        Built by concatenation rather than a nested here-string: the fixture itself contains
        PowerShell that must survive being written, read and parsed, and a here-string inside a
        here-string is how that goes wrong silently.
    #>
    param(
        [string]$Setup = '',
        [string]$PathExpr = '"$RepoRoot\a.md"',
        [string]$MarkerExpr = "'WIN_DEVTOOLS'",
        [string]$SecondMarkerExpr = "'WIN_DEVTOOLS'",
        [string]$ExtraStatement = ''
    )
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('function Write-AgentBlock { param($FilePath, $Marker, $Body) }')
    $lines.Add('function Write-AgentDiscovery {')
    $lines.Add('    param([string]$RepoRoot)')
    if ($Setup) { $lines.Add('    ' + $Setup) }
    $lines.Add('    $body = "the generated body, long enough to be real"')
    if ($ExtraStatement) { $lines.Add('    ' + $ExtraStatement) }
    $lines.Add(('    Write-AgentBlock {0} {1} $body' -f $PathExpr, $MarkerExpr))
    $lines.Add(('    Write-AgentBlock "$RepoRoot\b.md" {0} $body' -f $SecondMarkerExpr))
    $lines.Add('}')

    $p = Join-Path $fixtureRoot ('common-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($p, ($lines -join "`r`n") + "`r`n")
    return $p
}

function Get-ADResult {
    <#
        -RepoRoot IS A REAL DIRECTORY, and a fake drive letter broke this suite in CI only.

        It was $fixtureRoot. Join-Path on a drive that does not exist writes a NON-TERMINATING error
        and returns empty, so locally the `$x = Join-Path $RepoRoot "docs"` fixture evaluated to
        '' and the extractor succeeded. GitHub Actions sets $ErrorActionPreference = 'stop' for
        `shell: powershell`, which the suite inherits from the step - so in CI the same error
        became terminating, the extractor's catch fired, and the "allow-listed command is
        accepted" test failed there while passing here.

        Measured 2026-09-18. That is the THIRD environment divergence this repo has hit in two
        days, after in-session-vs--File invocation and markdownlint's presence on PATH. Using a
        directory that actually exists removes the whole class from this suite.
    #>
    param([string]$CommonPath)
    Get-AgentDiscoveryBody -CommonPath $CommonPath -RepoRoot $fixtureRoot
}

try {

Write-Host "`n== the control: a clean generator extracts ==" -ForegroundColor Cyan

It 'a clean fixture yields a body, two targets and one marker' {
    $r = Get-ADResult (New-ADFixture)
    (-not $r.Reason) -and ($r.Body -match 'generated body') -and (@($r.Targets).Count -eq 2) -and
        ($r.Marker -eq 'WIN_DEVTOOLS')
}

It 'CONTROL: the REAL lib\common.ps1 still extracts, which is the only test that proves anything' {
    # A green fixture suite with a broken extractor against the real file would be worse than no
    # suite at all, because it would read as coverage.
    $r = Get-AgentDiscoveryBody -CommonPath (Join-Path $repoRoot 'lib\common.ps1') -RepoRoot $repoRoot
    (-not $r.Reason) -and ($r.Marker -eq 'WIN_DEVTOOLS') -and (@($r.Targets).Count -eq 4) -and
        ($r.Body.Length -gt 1000)
}

It 'the generated block names no single agent host, because all four targets receive it' {
    # THE SAME BYTES GO TO ALL FOUR TARGETS - two of them Codex's - so any sentence written for
    # one host's toolset is wrong in at least half the files it lands in. Measured 2026-09-21:
    # the block told every reader that "a WebFetch that fails ... Claude-User is not a Cloudflare
    # signed agent", which is meaningless advice inside .codex\AGENTS.md and AGENTS.md, and it
    # named a Bash tool call in files read by hosts that have no Bash tool.
    #
    # This repo is deliberately multi-host: $AGENT_TARGETS covers .codex\AGENTS.md and AGENTS.md
    # beside the two Claude paths, and the discovery layer is lib\AgentDiscovery.ps1, not a
    # vendor module. Describe the CAPABILITY ("your host's own web-fetch tool", "a POSIX-shell
    # tool call"), never the vendor's name for it.
    $r = Get-AgentDiscoveryBody -CommonPath (Join-Path $repoRoot 'lib\common.ps1') -RepoRoot $repoRoot
    if ($r.Reason) { return $false }

    # Two strings survive deliberately and are NOT vendor advice:
    #   CODEX_TOOLBOX      this repo's own environment variable, read by lib\common.ps1
    #   OpenAI-compatible  the wire protocol Ollama serves, a factual API shape
    $text = ($r.Body -replace 'CODEX_TOOLBOX', '') -replace 'OpenAI-compatible', ''
    $hostNames = @('Claude', 'Anthropic', 'WebFetch', 'Codex', 'OpenAI', 'Cursor', 'Copilot', 'Gemini')
    -not @($hostNames | Where-Object { $text -match $_ }).Count
}

Write-Host "`n== the allowlist: commands ==" -ForegroundColor Cyan

It 'an allow-listed command (Join-Path) in the setup is accepted' {
    $r = Get-ADResult (New-ADFixture -Setup '$x = Join-Path $RepoRoot "docs"')
    -not $r.Reason
}

It 'MUTATION: a command NOT on the allowlist is refused, naming it and the line' {
    $r = Get-ADResult (New-ADFixture -Setup '$x = Get-Content $RepoRoot')
    ($r.Reason -match "calls 'Get-Content'") -and (-not $r.Body)
}

It 'MUTATION: a command whose name is not a literal is REFUSED, not skipped' {
    # `& $cmd` has no literal name, so GetCommandName() returns $null. The original guard was
    # `if ($n -and ...)`, which SKIPPED exactly this case - an unknowable name cannot be on an
    # allowlist, so the only safe answer is to refuse it.
    $r = Get-ADResult (New-ADFixture -Setup '$c = "Get-Content"; $x = & $c $RepoRoot')
    ($r.Reason -match 'name is not a literal') -and (-not $r.Body)
}

Write-Host "`n== the allowlist: methods, which it used to be blind to ==" -ForegroundColor Cyan

It 'MUTATION: a STATIC method call in the setup is refused, naming the member' {
    # [IO.File]::ReadAllText is an InvokeMemberExpressionAst, not a CommandAst, so the
    # CommandAst-only walk never saw it - in a function that ends in `& $sb`.
    $r = Get-ADResult (New-ADFixture -Setup '$x = [IO.File]::ReadAllText($RepoRoot)')
    ($r.Reason -match "method 'ReadAllText'") -and (-not $r.Body)
}

It 'MUTATION: an INSTANCE method call in the setup is refused' {
    $r = Get-ADResult (New-ADFixture -Setup '$x = $RepoRoot.ToUpperInvariant()')
    ($r.Reason -match "method 'ToUpperInvariant'") -and (-not $r.Body)
}

It 'the member allowlist is empty, so nothing is cleared by default' {
    # Pinned deliberately. Write-AgentDiscovery contains zero method invocations (measured
    # 2026-09-17), so an empty list costs nothing and forces a review the first time one appears.
    @($script:ADAllowedMembers).Count -eq 0
}

Write-Host "`n== the two arguments that went in unexamined ==" -ForegroundColor Cyan

It 'MUTATION: a method call in a Write-AgentBlock PATH argument is refused' {
    # The path expressions are spliced verbatim into the scriptblock that gets evaluated, so
    # clearing the assignments alone left two expressions per call unchecked.
    #
    # PARENTHESISED, and that is not cosmetic: a bare `[IO.Path]::GetTempPath()` in command
    # ARGUMENT position is a parse error ("An expression was expected after '('"), so the
    # unparenthesised fixture never reached the allowlist at all - it was refused for not
    # parsing, which would have made this test pass for the wrong reason.
    $r = Get-ADResult (New-ADFixture -PathExpr '([IO.Path]::GetTempPath())')
    ($r.Reason -match 'path argument') -and ($r.Reason -match 'GetTempPath') -and (-not $r.Body)
}

It 'MUTATION: a command call in a Write-AgentBlock PATH argument is refused, by the shape guard' {
    # Refused EARLIER than the argument clearance, and the message says so. The statement-shape
    # guard counts the named CommandAsts in each statement and demands exactly one
    # (Write-AgentBlock), so a nested command makes it two and the statement is rejected before
    # its arguments are ever examined. Asserting the specific message would pin the wrong layer;
    # what matters is that nothing gets spliced in and evaluated.
    $r = Get-ADResult (New-ADFixture -PathExpr '(Get-Content $RepoRoot)')
    ($r.Reason -match 'unrecognised statement') -and (-not $r.Body)
}

It 'MUTATION: a method call in a Write-AgentBlock MARKER argument is refused' {
    $r = Get-ADResult (New-ADFixture -MarkerExpr '$RepoRoot.Trim()')
    ($r.Reason -match 'marker argument') -and (-not $r.Body)
}

It 'CONTROL: an interpolated path argument is still accepted' {
    # The false-positive control. "$RepoRoot\a.md" is a string with a variable in it and no call
    # of any kind; refusing it would break the real generator.
    $r = Get-ADResult (New-ADFixture -PathExpr '"$RepoRoot\deep\a.md"')
    -not $r.Reason
}

Write-Host "`n== the structural refusals ==" -ForegroundColor Cyan

It 'divergent markers are reported rather than silently checking one file against another' {
    $r = Get-ADResult (New-ADFixture -SecondMarkerExpr "'OTHER_MARKER'")
    ($r.Reason -match 'different markers') -and (-not $r.Body)
}

It 'a statement that is neither an assignment nor Write-AgentBlock is reported' {
    $r = Get-ADResult (New-ADFixture -ExtraStatement 'Write-Host "hello"')
    ($r.Reason -match 'unrecognised statement') -and (-not $r.Body)
}

It 'a missing common.ps1 is a refusal, not an exception' {
    $r = Get-AgentDiscoveryBody -CommonPath (Join-Path $fixtureRoot 'nope.ps1') -RepoRoot $fixtureRoot
    ($r.Reason) -and (-not $r.Body)
}

Write-Host "`n== the drift helpers the smoke test depends on ==" -ForegroundColor Cyan

It 'Get-AgentBlockText returns the block, never the whole file' {
    # The deployed files wrap ~5 KB of the user's own standing instructions around this block;
    # comparing whole files would report those as staleness for ever.
    $p = Join-Path $fixtureRoot ('deployed-' + [guid]::NewGuid().ToString('N') + '.md')
    [IO.File]::WriteAllText($p, "my own notes`r`n<!-- M_START -->`r`ninner`r`n<!-- M_END -->`r`nmore notes`r`n")
    $t = Get-AgentBlockText -Path $p -Marker 'M'
    ($t -eq 'inner')
}

It 'Get-AgentBlockText returns $null when the markers are absent' {
    $p = Join-Path $fixtureRoot ('deployed-' + [guid]::NewGuid().ToString('N') + '.md')
    [IO.File]::WriteAllText($p, "no markers here`r`n")
    $null -eq (Get-AgentBlockText -Path $p -Marker 'M')
}

It 'ConvertTo-AgentBlockComparable normalises line endings and trailing whitespace' {
    # A deliberate blind spot, documented in the function: the generator's own output is
    # mixed-ending by construction, so failing on that would fire on every run for a reason
    # nobody can act on.
    (ConvertTo-AgentBlockComparable "a`r`nb   ") -eq (ConvertTo-AgentBlockComparable "a`nb")
}

It 'Get-AgentBlockDrift names the FIRST line that disagrees' {
    $d = Get-AgentBlockDrift -Deployed "same`nOLD`nsame" -Generated "same`nNEW`nsame"
    ($d -match 'OLD') -and ($d -match 'NEW')
}

} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
