#Requires -Version 5.1
<#
    Tests for lib\GateChecks.ps1 - the six repository hygiene checks both gates share.

    EVERY FIXTURE IS A SYNTHETIC REPOSITORY UNDER %TEMP%, never a file in tests\, and the reason
    is sharper here than anywhere else in this repo: the checks under test scan the repository
    they are pointed at. A fixture carrying a 7-only construct would fail the parse check against
    the REAL repo; one carrying a 0x08 byte would fail the control-byte check; one calling
    Add-UserPathEntry would fail the writer check. Fixtures must therefore live somewhere the
    checks are never pointed at, and every check takes -RepoRoot precisely so they can.

    THE MUTATIONS ARE THE POINT. Each check has a test that breaks the thing it guards inside a
    fixture and asserts exactly one finding naming the right file. A check nobody has made fail
    is a check nobody should trust, and this repo has shipped several that could not fail.

    Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-GateChecksTests.ps1
#>
[CmdletBinding()]
param()

# The deletion tripwire, the suite floor and the arm-time control. FIRST, before every other
# dot-source: the Remove-Item shadow must be defined before any library can bind to the real
# cmdlet. $PSScriptRoot rather than $repoRoot so this needs nothing computed first.
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\GateChecks.ps1')

$script:Pass = 0; $script:Fail = 0
function It {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        if (& $Body) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
        else { $script:Fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
    } catch { $script:Fail++; Write-Host "  FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("gatechecks-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

function New-GCFixtureRepo {
    <#
        A minimal repository that passes every check, so each test mutates exactly one thing and
        the finding it gets back cannot have come from anywhere else.

        [IO.File]::WriteAllText, never Set-Content: under 5.1 Set-Content defaults to ANSI, and
        these fixtures carry bytes and escapes that matter to the checks reading them.
    #>
    param([string]$Name = ([guid]::NewGuid().ToString('N')))
    $root = Join-Path $fixtureRoot $Name
    foreach ($d in @('tests', 'lib', 'docs', '.github\workflows', 'scripts')) {
        New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $root 'tests\SUTestGuard.ps1'), "function Assert-Stub { `$true }`r`n")
    [IO.File]::WriteAllText((Join-Path $root 'tests\Invoke-FakeTests.ps1'), @"
. (Join-Path `$PSScriptRoot 'SUTestGuard.ps1')
`$x = 1
"@)
    [IO.File]::WriteAllText((Join-Path $root 'lib\x.ps1'), "function Get-X { 'x' }`r`n")
    [IO.File]::WriteAllText((Join-Path $root 'scripts\run-gate-checks.ps1'), "'runner'`r`n")
    [IO.File]::WriteAllText((Join-Path $root 'docs\a.md'), "# Title`r`n`r`nSome prose.`r`n")
    [IO.File]::WriteAllText((Join-Path $root '.markdownlint.json'), "{}`r`n")
    [IO.File]::WriteAllText((Join-Path $root 'run-gate.ps1'), @"
`$suites = @(
    @{ Name = 'checks'; Path = 'scripts\run-gate-checks.ps1' }
)
"@)
    [IO.File]::WriteAllText((Join-Path $root '.github\workflows\gate.yml'), @"
name: gate
jobs:
  suites:
    steps:
      - name: Fake suite
        shell: powershell
        run: |
          .\tests\Invoke-FakeTests.ps1
          # a comment mentioning Invoke-GhostTests.ps1 must not count as wiring
          exit `$LASTEXITCODE
      - name: Repo checks
        shell: powershell
        run: |
          .\scripts\run-gate-checks.ps1
"@)
    return $root
}

try {

Write-Host "`n== parse: every .ps1 must parse under 5.1 ==" -ForegroundColor Cyan

It 'a clean fixture yields no parse findings, and reports what it examined' {
    $r = Get-GCParseResult -RepoRoot (New-GCFixtureRepo) -HostMajor 5
    (@($r.Findings).Count -eq 0) -and ($r.Examined -ge 3) -and ($r.Evidence -match '\d+ \.ps1 file')
}

It 'MUTATION parse: a 7-only construct is reported, with the file and the parser message' {
    $root = New-GCFixtureRepo
    # ?? is a null-coalescing operator in 7 and a parse error in 5.1. This is the exact class the
    # check exists for, and the class that silently passed when the parser ran under pwsh.
    [IO.File]::WriteAllText((Join-Path $root 'lib\bad.ps1'), "`$a = `$null ?? 'b'`r`n")
    $r = Get-GCParseResult -RepoRoot $root -HostMajor 5
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].File -eq 'lib\bad.ps1') -and
        ($r.Findings[0].Rule -eq 'parse') -and ($r.Findings[0].Message)
}

It 'FLOOR parse: a tree with no .ps1 fails rather than passing having examined nothing' {
    $empty = Join-Path $fixtureRoot ('empty-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    $r = Get-GCParseResult -RepoRoot $empty -HostMajor 5
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].Rule -eq 'floor')
}

It 'parse reports the WRONG HOST even when the tree is clean' {
    # The in-process-parser trap: [Parser] uses the grammar of the host it runs in, so running
    # this check from pwsh validates 7 and says nothing about 5.1. Testable only because
    # -HostMajor is a parameter rather than a hidden read of $PSVersionTable.
    $r = Get-GCParseResult -RepoRoot (New-GCFixtureRepo) -HostMajor 7
    @($r.Findings | Where-Object { $_.Rule -eq 'host' }).Count -eq 1
}

Write-Host "`n== wiring: both gates must invoke what they claim to ==" -ForegroundColor Cyan

It 'a fixture with every suite and the runner wired is silent' {
    $root = New-GCFixtureRepo
    $r = Get-GCWiringResult -RepoRoot $root -Require @((Join-Path $root 'scripts\run-gate-checks.ps1'))
    @($r.Findings).Count -eq 0
}

It 'MUTATION wiring: a suite on disk and in no run: block is named' {
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root 'tests\Invoke-GhostTests.ps1'), ". (Join-Path `$PSScriptRoot 'SUTestGuard.ps1')`r`n")
    $r = Get-GCWiringResult -RepoRoot $root -Require @((Join-Path $root 'scripts\run-gate-checks.ps1'))
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].Rule -eq 'missing') -and
        ($r.Findings[0].Message -match 'Invoke-GhostTests\.ps1')
}

It 'MUTATION wiring: a suite surviving only in a YAML comment is still reported missing' {
    # The 2026-09-11 sabotage, pinned. Replacing an invocation with
    # '# was Invoke-RenderTests.ps1 here' was NOT detected until comment stripping existed, and a
    # check that matches raw YAML also matches the workflow's own prose.
    $root = New-GCFixtureRepo
    $wf = Join-Path $root '.github\workflows\gate.yml'
    $y = [IO.File]::ReadAllText($wf).Replace('.\tests\Invoke-FakeTests.ps1', '# was Invoke-FakeTests.ps1 here')
    [IO.File]::WriteAllText($wf, $y)
    $r = Get-GCWiringResult -RepoRoot $root -Require @((Join-Path $root 'scripts\run-gate-checks.ps1'))
    @($r.Findings | Where-Object { $_.Rule -eq 'missing' -and $_.Message -match 'Invoke-FakeTests' }).Count -eq 1
}

It 'MUTATION wiring: the runner missing from the workflow is named' {
    # The hole the extraction CREATED. Delete the checks step and CI goes green while all six
    # checks stop running; only this rule notices.
    $root = New-GCFixtureRepo
    $wf = Join-Path $root '.github\workflows\gate.yml'
    $y = [IO.File]::ReadAllText($wf).Replace('.\scripts\run-gate-checks.ps1', 'echo nothing')
    [IO.File]::WriteAllText($wf, $y)
    $r = Get-GCWiringResult -RepoRoot $root -Require @((Join-Path $root 'scripts\run-gate-checks.ps1'))
    @($r.Findings | Where-Object { $_.Rule -eq 'missing' -and $_.Message -match 'run-gate-checks' }).Count -eq 1
}

It 'MUTATION wiring: the LOCAL gate not invoking the runner is named' {
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root 'run-gate.ps1'), "`$suites = @()`r`n")
    $r = Get-GCWiringResult -RepoRoot $root -Require @((Join-Path $root 'scripts\run-gate-checks.ps1'))
    @($r.Findings | Where-Object { $_.Rule -eq 'local-wiring' }).Count -eq 1
}

It 'wiring will not accept the runner named only in a COMMENT in the local gate' {
    # Same argument as the YAML half: the AST sweep looks at string literals, so prose cannot
    # satisfy the requirement.
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root 'run-gate.ps1'), "# we used to run scripts\run-gate-checks.ps1 here`r`n`$suites = @()`r`n")
    $r = Get-GCWiringResult -RepoRoot $root -Require @((Join-Path $root 'scripts\run-gate-checks.ps1'))
    @($r.Findings | Where-Object { $_.Rule -eq 'local-wiring' }).Count -eq 1
}

It 'FLOOR wiring: zero run: scalars extracted is a failure, not everything-missing' {
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root '.github\workflows\gate.yml'), "name: gate`r`njobs: {}`r`n")
    $r = Get-GCWiringResult -RepoRoot $root -Require @()
    @($r.Findings | Where-Object { $_.Rule -eq 'floor' }).Count -ge 1
}

It 'the run: extractor does not swallow a deeper env: key as executable text' {
    # The old inline version terminated on '^\s{0,6}\S', a magic 6, so an env: key indented 8
    # spaces AFTER a run: block was read as part of the script.
    $y = @"
jobs:
  j:
    steps:
      - name: s
        run: |
          .\tests\Invoke-FakeTests.ps1
        env:
          SECRET_NAME: Invoke-NotASuite.ps1
"@
    $p = Join-Path $fixtureRoot ('wf-' + [guid]::NewGuid().ToString('N') + '.yml')
    [IO.File]::WriteAllText($p, $y)
    $scalars = @(Get-GCWorkflowRunText -Path $p)
    ($scalars.Count -eq 1) -and ($scalars[0].Text -match 'Invoke-FakeTests') -and
        ($scalars[0].Text -notmatch 'Invoke-NotASuite')
}

It 'the run: extractor handles a single-line scalar, not only run: |' {
    $y = @"
jobs:
  j:
    steps:
      - name: s
        run: .\tests\Invoke-FakeTests.ps1
"@
    $p = Join-Path $fixtureRoot ('wf-' + [guid]::NewGuid().ToString('N') + '.yml')
    [IO.File]::WriteAllText($p, $y)
    $scalars = @(Get-GCWorkflowRunText -Path $p)
    ($scalars.Count -eq 1) -and ($scalars[0].Text -match 'Invoke-FakeTests')
}

It 'CONTROL: the real workflow still hides its prose from the extractor' {
    # The go/no-go on comment stripping, against the file that actually matters. The real
    # gate.yml discusses suite filenames in YAML comments; if those leaked into the executable
    # text, every wiring verdict would be a false pass.
    $scalars = @(Get-GCWorkflowRunText -Path (Join-Path $repoRoot '.github\workflows\gate.yml'))
    $wired = ($scalars | ForEach-Object { $_.Text }) -join "`n"
    ($scalars.Count -ge 1) -and ($wired -match 'Invoke-CoreTests\.ps1') -and ($wired -notmatch 'was Invoke-')
}

Write-Host "`n== guard-order: the deletion tripwire must load first ==" -ForegroundColor Cyan

It 'a suite whose first dot-source is the guard is silent' {
    $r = Get-GCGuardOrderResult -RepoRoot (New-GCFixtureRepo)
    @($r.Findings).Count -eq 0
}

It 'MUTATION guard-order: the guard loaded SECOND is named, with file and line' {
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root 'tests\Invoke-FakeTests.ps1'), @"
. (Join-Path `$PSScriptRoot '..\lib\x.ps1')
. (Join-Path `$PSScriptRoot 'SUTestGuard.ps1')
"@)
    $r = Get-GCGuardOrderResult -RepoRoot $root
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].File -eq 'tests\Invoke-FakeTests.ps1') -and
        ($r.Findings[0].Line -eq 1)
}

It 'MUTATION guard-order: a suite with no dot-source at all is named' {
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root 'tests\Invoke-FakeTests.ps1'), "`$x = 1`r`n")
    $r = Get-GCGuardOrderResult -RepoRoot $root
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].Message -match 'no dot-source at all')
}

It 'guard-order recognises a PARENTHESISED dot-source, which has no command name' {
    # `. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')` - the first element is a parenthesised
    # expression, so GetCommandName() returns nothing. A reader keyed on the command name would
    # report every suite in this repo as unguarded.
    $r = Get-GCGuardOrderResult -RepoRoot (New-GCFixtureRepo)
    @($r.Findings).Count -eq 0
}

Write-Host "`n== writers: no test may reach a writer it cannot redirect ==" -ForegroundColor Cyan

It 'a clean tests\ directory is silent' {
    $r = Get-GCWriterResult -RepoRoot (New-GCFixtureRepo)
    @($r.Findings).Count -eq 0
}

It 'MUTATION writers: a banned writer is named with file, line and function' {
    $root = New-GCFixtureRepo
    # if ($false) is MANDATORY in a fixture like this. The check is AST-based so it fires either
    # way, and a bare call that executes is the 2026-09-10 incident re-run on the real user PATH.
    [IO.File]::WriteAllText((Join-Path $root 'tests\Invoke-FakeTests.ps1'), @"
. (Join-Path `$PSScriptRoot 'SUTestGuard.ps1')
if (`$false) { Add-UserPathEntry -Path `$env:TEMP }
"@)
    $r = Get-GCWriterResult -RepoRoot $root
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].Line -eq 2) -and
        ($r.Findings[0].Message -match 'Add-UserPathEntry')
}

It 'CONTROL writers: Write-AgentBlock is NOT banned, because it takes -FilePath' {
    # The false-positive control. Write-AgentBlock can be pointed at TEMP and a real test does
    # exactly that; banning it would force that test to be deleted for no safety gain.
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root 'tests\Invoke-FakeTests.ps1'), @"
. (Join-Path `$PSScriptRoot 'SUTestGuard.ps1')
Write-AgentBlock -FilePath `$env:TEMP -Marker 'X' -Body 'y'
"@)
    $r = Get-GCWriterResult -RepoRoot $root
    @($r.Findings).Count -eq 0
}

It 'CONTROL writers: a banned name in a comment or a string is not a call' {
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root 'tests\Invoke-FakeTests.ps1'), @"
. (Join-Path `$PSScriptRoot 'SUTestGuard.ps1')
# Add-UserPathEntry is forbidden here
`$s = 'Remove-AgentBlocks'
"@)
    $r = Get-GCWriterResult -RepoRoot $root
    @($r.Findings).Count -eq 0
}

Write-Host "`n== control-bytes: no interpreted escape may reach a source file ==" -ForegroundColor Cyan

It 'a clean tree is silent and reports its file count' {
    $r = Get-GCControlByteResult -RepoRoot (New-GCFixtureRepo)
    (@($r.Findings).Count -eq 0) -and ($r.Examined -ge 3)
}

It 'MUTATION control-bytes: a 0x08 byte is named with file, line and the byte' {
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root 'lib\mangled.ps1'), "# fine`r`n`$p = 'scripts" + [char]8 + "uild'`r`n")
    $r = Get-GCControlByteResult -RepoRoot $root
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].File -eq 'lib\mangled.ps1') -and
        ($r.Findings[0].Line -eq 2) -and ($r.Findings[0].Message -match '0x08')
}

It 'CONTROL control-bytes: TAB, CR and LF are not flagged' {
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root 'lib\tabs.ps1'), "function F {`r`n`tif (`$true) { 'x' }`r`n}`r`n")
    $r = Get-GCControlByteResult -RepoRoot $root
    @($r.Findings).Count -eq 0
}

It 'control-bytes skips logs\ and .claude\worktrees\, which is what makes CI and local agree' {
    # Measured 2026-09-17: logs\ and manifest\tools.json are gitignored generated artefacts and
    # contributed 7 of 56 swept files on this box against 0 of 49 in CI. Without the exclusion the
    # two callers of one check examine different sets, and only the local gate can fail on a file
    # nobody committed. Pinned so it cannot quietly regress.
    $root = New-GCFixtureRepo
    New-Item -ItemType Directory -Path (Join-Path $root 'logs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root '.claude\worktrees\wt\lib') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'logs\dirty.json'), "{" + [char]8 + "}")
    [IO.File]::WriteAllText((Join-Path $root '.claude\worktrees\wt\lib\dirty.ps1'), "'" + [char]8 + "'")
    $r = Get-GCControlByteResult -RepoRoot $root
    @($r.Findings).Count -eq 0
}

Write-Host "`n== markdown: the classifier, with no markdownlint required ==" -ForegroundColor Cyan

It 'a real captured finding line becomes a finding with file, line and rule' {
    $out = "D:\repo\docs\tools-reference.md:215 error MD031/blanks-around-fences Fenced code blocks should be surrounded by blank lines [Context: ``````]"
    $r = ConvertFrom-GCMarkdownlintOutput -Output $out -ExitCode 1 -Examined 6 -RepoRoot 'D:\repo'
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].File -eq 'docs\tools-reference.md') -and
        ($r.Findings[0].Line -eq 215) -and ($r.Findings[0].Rule -eq 'MD031')
}

It 'the file:line:column form parses too' {
    $out = "D:\repo\docs\a.md:12:5 error MD009/no-trailing-spaces Trailing spaces"
    $r = ConvertFrom-GCMarkdownlintOutput -Output $out -ExitCode 1 -Examined 1 -RepoRoot 'D:\repo'
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].Line -eq 12) -and ($r.Findings[0].Rule -eq 'MD009')
}

It 'exit 0 with no output is clean' {
    $r = ConvertFrom-GCMarkdownlintOutput -Output '' -ExitCode 0 -Examined 6 -RepoRoot 'D:\repo'
    (@($r.Findings).Count -eq 0) -and ($r.Evidence -match '6 \.md file')
}

It 'FLOOR markdown: exit 0 plus the usage banner is a failure, not clean' {
    # Measured 2026-09-17: markdownlint exits 0 and prints its usage banner when its arguments
    # match no file. That is the repo's floor rule as a live tool behaviour - an empty file list
    # would otherwise pass while linting nothing.
    $r = ConvertFrom-GCMarkdownlintOutput -Output "Usage: markdownlint [options] <files>" -ExitCode 0 -Examined 6 -RepoRoot 'D:\repo'
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].Rule -eq 'floor')
}

It 'a bad config (measured exit 4) is a tool finding carrying the text, never clean' {
    $r = ConvertFrom-GCMarkdownlintOutput -Output 'Cannot read or parse config file' -ExitCode 4 -Examined 6 -RepoRoot 'D:\repo'
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].Rule -eq 'tool') -and
        ($r.Findings[0].Message -match 'Cannot read or parse')
}

It 'exit 1 with nothing parseable is a tool finding, never clean' {
    $r = ConvertFrom-GCMarkdownlintOutput -Output 'something unexpected' -ExitCode 1 -Examined 6 -RepoRoot 'D:\repo'
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].Rule -eq 'tool')
}

It 'FLOOR markdown: zero .md files fails rather than passing' {
    $r = ConvertFrom-GCMarkdownlintOutput -Output '' -ExitCode 0 -Examined 0 -RepoRoot 'D:\repo'
    (@($r.Findings).Count -eq 1) -and ($r.Findings[0].Rule -eq 'floor')
}

It 'markdown with no runner supplied reports absent rather than clean' {
    # Absent means FAIL, not warn. The repo's standing rule is that a check which examined
    # nothing must fail, and the CI job installs the tool, so absence there means the install
    # step broke.
    $r = Get-GCMarkdownResult -RepoRoot (New-GCFixtureRepo)
    @($r.Findings | Where-Object { $_.Rule -eq 'absent' }).Count -eq 1
}

It 'markdown refuses to lint with tool defaults when the config is missing' {
    # Falling back to markdownlint's defaults would fire MD013 on every long line in the repo,
    # so the honest answer is a finding rather than a flood or a silent pass.
    $root = New-GCFixtureRepo
    Remove-Item -LiteralPath (Join-Path $root '.markdownlint.json') -Force
    $r = Get-GCMarkdownResult -RepoRoot $root -MarkdownRunner { param($e, $a) [pscustomobject]@{ ExitCode = 0; Output = ''; Version = '' } }
    @($r.Findings | Where-Object { $_.Rule -eq 'config' }).Count -eq 1
}

It 'Resolve-GCMarkdownlint returns an Application, never the .ps1 shim' {
    # Measured 2026-09-17: a bare Get-Command markdownlint returns markdownlint.ps1, an
    # ExternalScript, which would run in the caller's own runspace instead of a child process.
    $exe = Resolve-GCMarkdownlint
    if (-not $exe) { Write-Host "       markdownlint is not installed here; the resolver correctly returned nothing" -ForegroundColor DarkYellow; return $true }
    @('.cmd', '.exe', '.bat') -contains ([IO.Path]::GetExtension($exe).ToLowerInvariant())
}

Write-Host "`n== the registry, and one broken check not taking the others with it ==" -ForegroundColor Cyan

It 'the registry lists exactly the six expected checks, in order' {
    # WRITTEN DOWN rather than enumerated, and deliberately so: an enumeration compared against
    # itself can never notice a deletion. Same argument as smoke-test.ps1's $suiteRequired floor.
    $want = @('parse', 'wiring', 'guard-order', 'writers', 'control-bytes', 'markdown')
    $got = @(Get-GateCheckTable | ForEach-Object { $_.Name })
    ($got.Count -eq $want.Count) -and (-not (Compare-Object $got $want -SyncWindow 0))
}

It 'every registered check is reachable - one result per registered name' {
    $root = New-GCFixtureRepo
    $names = @(Get-GateCheckTable | ForEach-Object { $_.Name })
    $res = @(Get-GateCheckResults -RepoRoot $root -HostMajor 5 `
                -MarkdownRunner { param($e, $a) [pscustomobject]@{ ExitCode = 0; Output = ''; Version = '0' } })
    ($res.Count -eq $names.Count) -and (-not (Compare-Object @($res | ForEach-Object { $_.Check }) $names -SyncWindow 0))
}

It 'a check that THROWS becomes a finding and does not stop the others' {
    # The per-check independence gate.yml wanted from six separate steps and did not get: a
    # failing STEP aborts the job, which is how six checks stopped running for six days behind
    # one unrelated failure.
    # The markdown runner throws; everything else is pointed at a healthy fixture. A bogus
    # -RepoRoot would also work but fills the transcript with drive-not-found noise, and a test
    # whose output is unreadable is a test nobody checks.
    $res = @(Get-GateCheckResults -RepoRoot (New-GCFixtureRepo) -HostMajor 5 `
                -MarkdownRunner { param($e, $a) throw 'boom' })
    $threw = @($res | Where-Object { @($_.Findings | Where-Object { $_.Rule -eq 'threw' }).Count -gt 0 })
    $others = @($res | Where-Object { $_.Check -ne 'markdown' -and @($_.Findings).Count -eq 0 })
    ($res.Count -eq 6) -and ($threw.Count -eq 1) -and ($threw[0].Check -eq 'markdown') -and ($others.Count -eq 5)
}

It 'every finding from every check carries all five fields' {
    $root = New-GCFixtureRepo
    [IO.File]::WriteAllText((Join-Path $root 'lib\bad.ps1'), "`$a = `$null ?? 'b'`r`n")
    $res = @(Get-GateCheckResults -RepoRoot $root -HostMajor 5 `
                -MarkdownRunner { param($e, $a) [pscustomobject]@{ ExitCode = 0; Output = ''; Version = '0' } })
    $all = @($res | ForEach-Object { $_.Findings })
    ($all.Count -ge 1) -and -not (@($all | Where-Object {
        ($null -eq $_.Check) -or ($null -eq $_.File) -or ($null -eq $_.Line) -or
        (-not $_.Rule) -or (-not $_.Message) }).Count)
}

Write-Host "`n== the runner's own contract, by AST, launching no process ==" -ForegroundColor Cyan

It 'the runner does NOT set $ErrorActionPreference to Stop' {
    # LOAD-BEARING, and counter-intuitive enough that somebody will add it by reflex. Under
    # 'Stop' the markdownlint 2>&1 merge in that file becomes a terminating NativeCommandError,
    # AND the repo-wide native-stderr AST rule starts flagging the line. Both callers run the
    # runner as a child process, which starts at 'Continue', so omitting it is correct.
    $p = Join-Path $repoRoot 'scripts\run-gate-checks.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null)
    $bad = @($ast.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
        ($n.Left.Extent.Text -match 'ErrorActionPreference') -and
        ($n.Right.Extent.Text -match "'Stop'|""Stop""") }, $true))
    $bad.Count -eq 0
}

It 'the runner prints its tally LAST, in the shape the local gate parses' {
    # run-gate.ps1's Get-GateTally reads the LAST line matching '\d+ passed'. Anything printed
    # after the tally makes the gate report NO TALLY and blame the harness instead of the cause.
    $p = Join-Path $repoRoot 'scripts\run-gate-checks.ps1'
    $text = [IO.File]::ReadAllText($p)
    $idx = $text.LastIndexOf('passed, ')
    ($idx -gt 0) -and ($text.Substring($idx) -notmatch 'Write-Host\s+\("(?!\s*`n\{0\})')
}

It 'the runner defines no Get-GC* function of its own, so logic cannot drift out of the library' {
    $p = Join-Path $repoRoot 'scripts\run-gate-checks.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null)
    $fns = @($ast.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
        ($n.Name -like 'Get-GC*') }, $true))
    $fns.Count -eq 0
}

} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
