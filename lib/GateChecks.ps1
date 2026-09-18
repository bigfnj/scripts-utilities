# Repository hygiene checks: ONE definition, called by both gates.
#
# WHY THIS FILE EXISTS, and it is the same argument lib\ShimFormat.ps1 already won one level
# down. Six checks over the repository's own shape - does every script parse, is every suite
# actually wired into CI, does the deletion guard load first, does any test reach a writer that
# cannot be redirected, are there stray control bytes, is the markdown clean - used to live ONLY
# as inline PowerShell inside .github\workflows\gate.yml's run: blocks. run-gate.ps1 therefore
# could not run them, and nobody could run them without pushing.
#
# That went from untidy to expensive on 2026-09-11. An unrelated closure bug turned the installer
# suite red; a failing step aborts the job; the installer suite is step 3 of 11. So all six checks
# stopped running in CI for SIX DAYS while the job reported exactly one problem, and the local
# gate could not tell anyone, because it had never had them. Both halves are fixed: the checks
# live here with two callers, and gate.yml runs them in a SEPARATE JOB that a red suite cannot
# abort.
#
# FUNCTIONS ONLY, no side effects on dot-source, and NO NATIVE COMMAND ANYWHERE IN THIS FILE.
# Files under lib\ are treated as exposed by the repo-wide native-stderr AST rule whether or not
# they set 'Stop', and that rule exempts exactly three function names with a test capping the
# list at three. markdownlint is therefore invoked by a SCRIPTBLOCK the caller supplies - see
# Get-GCMarkdownResult and scripts\run-gate-checks.ps1, which is where the one native call lives.
#
# EVERY FUNCTION TAKES -RepoRoot AND NOTHING READS Get-Location. That is what lets the test suite
# point every check at a synthetic repository under %TEMP%, which is what makes the mutation tests
# permanent rather than a one-time ceremony.
#
# THE RESIDUAL HOLE, stated rather than papered over: check 'wiring' proves gate.yml invokes the
# runner AND that run-gate.ps1 invokes the runner, so each gate proves the other's wiring. Neither
# proves its own. One commit that removes both entries fires nothing. That is the same blind spot
# scripts\smoke-test.ps1 records about its own $suiteRequired floor, and it is recorded here for
# the same reason: so the next audit does not mistake it for coverage.

# The four writers a test may never call. They default to four files in the user's profile
# (including the global CLAUDE.md) or rewrite the persistent user PATH, and none takes a path
# parameter to redirect, so a test calling one is aimed at real machine state.
# Write-AgentBlock is deliberately NOT here: it takes an explicit -FilePath and a real test
# points it at TEMP.
$script:GCBannedWriters = @('Write-AgentDiscovery', 'Remove-AgentBlocks', 'Remove-UserPathEntry', 'Add-UserPathEntry')

# TAB, CR and LF are the only control characters a source file in this repo has any business
# containing. The rest are the signature of a patch script whose backslash escapes were
# interpreted: a Windows path written as "scripts\build" yields a literal BACKSPACE,
# "P:\tb\native" yields TAB and newline. Two such files reached main on 2026-09-11, one inside a
# single-quoted string in a test that PASSED, because such a string may legally span lines and
# the mangled argument was never read on the path under test. Invisible in every editor and in
# every Read; only a byte scan shows it.
$script:GCControlByteRegex = [regex]::new('[\x00-\x08\x0B\x0C\x0E-\x1F]')

$script:GCSourceExtensions = @('.ps1', '.psm1', '.json', '.yml', '.md', '.xml', '.cmd')

# There is deliberately NO second list of check names here. One was added with this file and had
# zero readers - dead metadata that would have drifted from the registry the first time a check was
# added or renamed, while looking authoritative. Get-GateCheckTable is the only list, and the test
# suite compares it against names WRITTEN DOWN IN THE TEST, because an enumeration compared against
# itself can never notice a deletion.


function New-GCFinding {
    param(
        [Parameter(Mandatory)][string]$Check,
        [string]$File = '',
        [int]$Line = 0,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Check = $Check; File = $File; Line = $Line; Rule = $Rule; Message = $Message }
}

function New-GCResult {
    param(
        [Parameter(Mandatory)][string]$Check,
        [int]$Examined = 0,
        [string]$Evidence = '',
        [object[]]$Findings = @()
    )
    [pscustomobject]@{ Check = $Check; Examined = $Examined; Evidence = $Evidence; Findings = @($Findings) }
}


function Get-GCSourceFiles {
    <#
        THE one file enumeration and THE one exclusion policy, shared by parse, control-bytes and
        markdown. Returns FileInfo objects.

        THE EXCLUSIONS ARE WHY THIS IS A FUNCTION rather than three inline Get-ChildItem calls.

        .claude\worktrees\ - agent worktrees land INSIDE the repo, so a check run from the main
        checkout would sweep every agent's half-written tree and fail main on somebody else's
        work in progress. The match is REPO-RELATIVE, not against the absolute path: the absolute
        form matches EVERYTHING when the gate is itself run from inside a worktree, which
        scripts\smoke-test.ps1 records measuring (80 passed / 1 failed from a worktree, 81 / 0
        from the main checkout).

        logs\ and manifest\tools.json - gitignored, generated per workstation. Measured
        2026-09-17: they contribute 7 of 56 swept files on this box and 0 of 49 in CI, so without
        this exclusion the two callers of one check examine different sets and only the local gate
        can fail on a mangled path-backup-*.json that was never committed. Excluding them makes
        local and CI agree BY CONSTRUCTION, which is the whole point of sharing the code.

        REJECTED: `git ls-files`. It would make the name "tracked files" literally true and need
        no exclusion list, but it omits UNTRACKED NEW FILES - so the local gate would not parse
        the .ps1 you just wrote, which is most of its value. Recorded rather than silently
        not done.

        Get-ChildItem without -Force already skips .git, because git sets the hidden attribute on
        it. Stated because it looks like an omission.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Extension = $script:GCSourceExtensions
    )
    $root = ([IO.Path]::GetFullPath($RepoRoot)).TrimEnd('\')
    $prefix = $root + '\'
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $Extension -contains $_.Extension } |
        Where-Object {
            $full = $_.FullName
            if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
            $rel = $full.Substring($prefix.Length)
            if ($rel -like '.claude\worktrees\*') { return $false }
            if ($rel -like 'logs\*') { return $false }
            if ($rel -ieq 'manifest\tools.json') { return $false }
            return $true
        }
}

function Get-GCRelativePath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path
    )
    $root = ([IO.Path]::GetFullPath($RepoRoot)).TrimEnd('\') + '\'
    $full = try { [IO.Path]::GetFullPath($Path) } catch { $Path }
    if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($root.Length) }
    return $Path
}


function Get-GCParseResult {
    <#
        Every .ps1 in the repository must parse under Windows PowerShell 5.1.

        -HostMajor EXISTS SO THIS CAN BE TESTED, and it guards a real defect rather than a
        hypothetical one. [Parser]::ParseFile uses the grammar of the host it runs IN, so running
        this check from pwsh silently checks 7's grammar - and 7 accepts &&, ??, ?. and ternary,
        which are parse ERRORS under 5.1. scripts\smoke-test.ps1 records exactly that happening:
        the one check whose purpose was catching 7-only syntax quietly stopped doing it. Both
        callers launch this in a 5.1 CHILD, so the guard should never fire in practice - which is
        precisely why it needs a test that can.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$HostMajor = $PSVersionTable.PSVersion.Major
    )
    $findings = @()
    if ($HostMajor -ne 5) {
        $findings += New-GCFinding -Check 'parse' -Rule 'host' -Message (
            "this check ran under PowerShell $HostMajor, so it validated that grammar and not 5.1's - " +
            "run it in a 5.1 child (&&, ??, ?. and ternary parse cleanly in 7 and are errors in 5.1)")
    }

    $files = @(Get-GCSourceFiles -RepoRoot $RepoRoot -Extension @('.ps1'))
    foreach ($f in $files) {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
        if ($errors -and $errors.Count) {
            $findings += New-GCFinding -Check 'parse' -File (Get-GCRelativePath -RepoRoot $RepoRoot -Path $f.FullName) `
                -Line $errors[0].Extent.StartLineNumber -Rule 'parse' -Message $errors[0].Message
        }
    }

    # A FLOOR. An enumeration that matched nothing once printed "all .ps1 parse" and passed, so a
    # renamed directory turned this check green.
    if ($files.Count -eq 0) {
        $findings += New-GCFinding -Check 'parse' -Rule 'floor' -Message 'found 0 .ps1 files - this check examined nothing'
    }

    New-GCResult -Check 'parse' -Examined $files.Count -Findings $findings `
        -Evidence ("{0} .ps1 file(s) parsed under {1}" -f $files.Count, $PSVersionTable.PSVersion)
}


function Get-GCWorkflowRunText {
    <#
        The EXECUTABLE lines of every `run:` scalar in a workflow, one record per scalar:
        @{ StartLine; Text }. PowerShell # comments are stripped.

        MATCHING THE RAW YAML IS NOT GOOD ENOUGH, and this is measured. Matching the whole file
        also matches COMMENTS, so deleting a step passed as long as the filename survived anywhere
        in prose - and the workflow's own commentary mentions suite filenames. Sabotaging the
        Render step on 2026-09-11 by replacing its invocation with '# was Invoke-RenderTests.ps1
        here' was NOT detected until comment stripping was added.

        TWO FIXES over the inline version this replaces:
          - It terminated on '^\s{0,6}\S', a magic 6, so an `env:` or `with:` key indented 8
            spaces AFTER a run: block was swallowed as executable text. This terminates on the
            first line whose indentation is <= the indentation of the `run:` key itself.
          - It only handled `run: |`. A suite wired as a single-line `run: .\tests\X.ps1` read as
            not-wired. Inline scalars and |- > >- are all handled.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $lines = [IO.File]::ReadAllText($Path) -split "`r?`n"
    $out = @()
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        $m = [regex]::Match($line, '^(?<indent>\s*)run:\s*(?<rest>.*)$')
        if (-not $m.Success) { $i++; continue }

        $indent = $m.Groups['indent'].Value.Length
        $rest = $m.Groups['rest'].Value.Trim()
        $startLine = $i + 1

        if ($rest -and $rest -notmatch '^[|>][-+]?$') {
            # Inline scalar: the command is on the run: line itself.
            $out += [pscustomobject]@{ StartLine = $startLine; Text = ($rest -replace '#.*$', '') }
            $i++
            continue
        }

        # Block scalar: consume until a line whose indentation is <= the run: key's.
        $body = @()
        $i++
        while ($i -lt $lines.Count) {
            $b = $lines[$i]
            if ($b.Trim().Length -gt 0) {
                $bIndent = ($b -replace '^(\s*).*$', '$1').Length
                if ($bIndent -le $indent) { break }
            }
            $body += ($b -replace '#.*$', '')
            $i++
        }
        $out += [pscustomobject]@{ StartLine = $startLine; Text = ($body -join "`n") }
    }
    return @($out)
}


function Get-GCWiringResult {
    <#
        Both gates must invoke everything they claim to.

        rule 'missing'       - every tests\Invoke-*Tests.ps1 on disk, plus every path in -Require,
                               appears in an EXECUTABLE line of a gate.yml run: scalar.
        rule 'local-wiring'  - run-gate.ps1 invokes the runner too, checked against string
                               literals in its AST so prose and comments cannot satisfy it.

        -Require is how the runner asserts its OWN wiring without anything being written down:
        it passes $PSCommandPath, so renaming the runner moves the requirement with it.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Workflow = '.github\workflows\gate.yml',
        [string]$LocalGate = 'run-gate.ps1',
        [string[]]$Require = @()
    )
    $findings = @()
    $testsDir = Join-Path $RepoRoot 'tests'
    $suites = @(Get-ChildItem -LiteralPath $testsDir -Filter 'Invoke-*Tests.ps1' -File -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name })

    $needed = @($suites) + @($Require | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf })
    $needed = @($needed | Select-Object -Unique)

    $wfPath = Join-Path $RepoRoot $Workflow
    $scalars = @(Get-GCWorkflowRunText -Path $wfPath)
    $wired = ($scalars | ForEach-Object { $_.Text }) -join "`n"

    foreach ($n in $needed) {
        if ($wired -notmatch [regex]::Escape($n)) {
            $findings += New-GCFinding -Check 'wiring' -File $Workflow -Rule 'missing' `
                -Message ("{0} is not invoked by any run: block in {1}" -f $n, $Workflow)
        }
    }

    # The local gate's half. An AST sweep for a string literal equal to the runner's relative
    # path: a filename surviving in a comment or a here-string must not satisfy this.
    foreach ($req in @($Require | Where-Object { $_ })) {
        $rel = Get-GCRelativePath -RepoRoot $RepoRoot -Path $req
        $lgPath = Join-Path $RepoRoot $LocalGate
        if (-not (Test-Path -LiteralPath $lgPath)) {
            $findings += New-GCFinding -Check 'wiring' -File $LocalGate -Rule 'local-wiring' `
                -Message ("{0} does not exist, so nothing proves the local gate runs the checks" -f $LocalGate)
            continue
        }
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($lgPath, [ref]$null, [ref]$null)
        $hit = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            Where-Object { $_.Value -and ($_.Value -replace '/', '\') -ieq $rel })
        if ($hit.Count -eq 0) {
            $findings += New-GCFinding -Check 'wiring' -File $LocalGate -Rule 'local-wiring' `
                -Message ("{0} contains no string literal '{1}', so the local gate does not run the checks" -f $LocalGate, $rel)
        }
    }

    if ($suites.Count -eq 0) {
        $findings += New-GCFinding -Check 'wiring' -Rule 'floor' -Message 'found 0 suites in tests\ - this check examined nothing'
    }
    # A separate floor. An extractor that stops matching would otherwise report either everything
    # missing or everything present, depending on the direction of the bug.
    if ($scalars.Count -eq 0) {
        $findings += New-GCFinding -Check 'wiring' -File $Workflow -Rule 'floor' `
            -Message ("extracted 0 run: scalars from {0} - the workflow parser matched nothing" -f $Workflow)
    }

    New-GCResult -Check 'wiring' -Examined $needed.Count -Findings $findings `
        -Evidence ("{0} suite(s) + {1} runner(s) wired into {2}; {3} run: scalar(s) parsed" -f `
                    $suites.Count, @($Require).Count, $Workflow, $scalars.Count)
}


function Get-GCGuardOrderResult {
    <#
        tests\SUTestGuard.ps1 must be the FIRST dot-source in every suite.

        ORDER, NOT PRESENCE, and the difference is the whole check. SUTestGuard.ps1 defines a
        Remove-Item shadow, and a function shadows the cmdlet only for code that runs AFTER the
        definition. Dot-source it below lib\common.ps1 and common.ps1's own load has already bound
        the real cmdlet - in Invoke-InstallerTests.ps1 that is a one-line margin in which three
        Remove-Item calls reach the repository's own manifest\tools.json. The guard would still be
        in the file and the arm-time control would still print ARMED.

        `(Get-Content $f) -match 'SUTestGuard'` passes with the dot-source sitting anywhere,
        including last, so it asserts the STATEMENT EXISTS rather than the CONDITION holding.

        The invocation OPERATOR identifies a dot-source, not the command name:
        `. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')` has no command name at all - its first
        element is a parenthesised expression - so GetCommandName() returns nothing there.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Guard = 'SUTestGuard.ps1'
    )
    $findings = @()
    $testsDir = Join-Path $RepoRoot 'tests'
    $suites = @(Get-ChildItem -LiteralPath $testsDir -Filter 'Invoke-*Tests.ps1' -File -ErrorAction SilentlyContinue)

    foreach ($f in $suites) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $dots = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot }, $true) |
            Sort-Object { $_.Extent.StartOffset })
        if ($dots.Count -eq 0) {
            $findings += New-GCFinding -Check 'guard-order' -File (Get-GCRelativePath -RepoRoot $RepoRoot -Path $f.FullName) `
                -Rule 'order' -Message ("no dot-source at all, so tests\{0} is never loaded" -f $Guard)
            continue
        }
        $first = $dots[0]
        $text = $first.Extent.Text.Trim()
        if ($text -notmatch ([regex]::Escape($Guard) + '[''"]?\s*\)?\s*$')) {
            $findings += New-GCFinding -Check 'guard-order' -File (Get-GCRelativePath -RepoRoot $RepoRoot -Path $f.FullName) `
                -Line $first.Extent.StartLineNumber -Rule 'order' `
                -Message ("the first dot-source loads {0} - tests\{1} must come before it" -f $text, $Guard)
        }
    }

    if ($suites.Count -eq 0) {
        $findings += New-GCFinding -Check 'guard-order' -Rule 'floor' -Message 'found 0 suites in tests\ - this check examined nothing'
    }

    New-GCResult -Check 'guard-order' -Examined $suites.Count -Findings $findings `
        -Evidence ("{0} suite(s) load tests\{1} first" -f $suites.Count, $Guard)
}


function Get-GCWriterResult {
    <#
        No test may call a writer that cannot be redirected.

        The deletion tripwire shadows Remove-Item, and nothing can shadow Set-Content safely (its
        positional Path AND positional Value, plus a pipeline-bound -Value, make a naive proxy
        truncate a multi-item write to its last line). So the writers that reach REAL user state
        with no path parameter are prohibited by inspection instead.

        AST, not grep: a banned name inside a comment or a string is not a call.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Banned = $script:GCBannedWriters
    )
    $findings = @()
    $testsDir = Join-Path $RepoRoot 'tests'
    $files = @(Get-ChildItem -LiteralPath $testsDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue)

    foreach ($f in $files) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $c.GetCommandName()
            if ($name -and ($Banned -contains $name)) {
                $findings += New-GCFinding -Check 'writers' -File (Get-GCRelativePath -RepoRoot $RepoRoot -Path $f.FullName) `
                    -Line $c.Extent.StartLineNumber -Rule 'banned' `
                    -Message ("calls {0} - it writes real user state and takes no path to redirect" -f $name)
            }
        }
    }

    if ($files.Count -eq 0) {
        $findings += New-GCFinding -Check 'writers' -Rule 'floor' -Message 'found 0 .ps1 files in tests\ - this check examined nothing'
    }

    New-GCResult -Check 'writers' -Examined $files.Count -Findings $findings `
        -Evidence ("{0} file(s) in tests\, none calling: {1}" -f $files.Count, ($Banned -join ', '))
}


function Get-GCControlByteResult {
    <#
        No stray control characters in any source file. See $script:GCControlByteRegex for why
        this is a byte check and not a review item.

        ONE COMPILED REGEX, not a per-byte loop. Measured 2026-09-11 over a 48-file / 961 KB tree:
        the loop was 2,559 ms, this is 39 ms (66x), identical findings. Recorded because the
        obvious alternative LOSES: [Array]::FindIndex with a [Predicate[byte]] measured 3,642 ms,
        SLOWER than the loop, because the predicate is a scriptblock invoked once per byte.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Extension = $script:GCSourceExtensions
    )
    $findings = @()
    $files = @(Get-GCSourceFiles -RepoRoot $RepoRoot -Extension $Extension)

    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f.FullName)
        $m = $script:GCControlByteRegex.Match($text)
        if ($m.Success) {
            $line = ($text.Substring(0, $m.Index) -split "`n").Count
            $findings += New-GCFinding -Check 'control-bytes' -File (Get-GCRelativePath -RepoRoot $RepoRoot -Path $f.FullName) `
                -Line $line -Rule 'control-byte' `
                -Message ("contains control byte 0x{0:X2} - an interpreted string escape, almost certainly a backslash sequence from a patch script" -f [int][char]$m.Value[0])
        }
    }

    if ($files.Count -eq 0) {
        $findings += New-GCFinding -Check 'control-bytes' -Rule 'floor' -Message 'scanned 0 files - this check examined nothing'
    }

    New-GCResult -Check 'control-bytes' -Examined $files.Count -Findings $findings `
        -Evidence ("{0} source file(s) scanned" -f $files.Count)
}


function Resolve-GCMarkdownlint {
    <#
        The markdownlint APPLICATION, or $null. Pure Get-Command; invokes nothing.

        -CommandType Application is load-bearing. Measured 2026-09-17: a bare
        `Get-Command markdownlint` returns markdownlint.ps1, an ExternalScript, which would run
        in the caller's own runspace rather than as a child process. -All shows three candidates
        (markdownlint.ps1, markdownlint.cmd, and an extension-less markdownlint).
    #>
    $cands = @(Get-Command -Name 'markdownlint' -All -CommandType Application -ErrorAction SilentlyContinue |
               Where-Object { $_.Source })
    foreach ($ext in @('.cmd', '.exe', '.bat')) {
        $hit = @($cands | Where-Object { [IO.Path]::GetExtension($_.Source) -ieq $ext })[0]
        if ($hit) { return $hit.Source }
    }
    if ($cands.Count) { return $cands[0].Source }
    return $null
}


function ConvertFrom-GCMarkdownlintOutput {
    <#
        markdownlint's transcript -> findings. ALL the judgement about that tool lives here, so
        the tests for it run on a machine that has never seen markdownlint.

        THREE MEASURED BEHAVIOURS this has to survive, taken 2026-09-17 against
        markdownlint-cli 0.48.0:

          1. FINDINGS GO TO STDERR AND STDOUT IS EMPTY. `markdownlint x.md 2>$null` produced 0
             stdout lines and exit 1. So a capture that reads stdout only sees "" and would
             report clean while exiting 1. The caller must merge 2>&1.
          2. IT EXITS 0 AND PRINTS ITS USAGE BANNER when its arguments match no file. That is the
             repo's floor rule as a live tool behaviour: an empty file list passes while linting
             nothing.
          3. A BAD CONFIG PATH EXITS 4 with "Cannot read or parse config file".

        Output line shape, with an optional column:
          <path>:<line> error MD031/blanks-around-fences <text> [Context: "..."]
    #>
    param(
        [string]$Output = '',
        [int]$ExitCode = 0,
        [int]$Examined = 0,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Version = ''
    )
    $findings = @()

    if ($Examined -eq 0) {
        $findings += New-GCFinding -Check 'markdown' -Rule 'floor' -Message 'found 0 .md files - this check examined nothing'
        return New-GCResult -Check 'markdown' -Examined 0 -Findings $findings -Evidence 'no markdown found'
    }

    $text = [string]$Output
    $lines = @($text -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    $rx = [regex]::new('^(?<file>.+?):(?<line>\d+)(?::\d+)?\s+\w+\s+(?<rule>MD\d+)/(?<name>\S+)\s+(?<msg>.*)$')

    $parsed = @()
    foreach ($l in $lines) {
        $m = $rx.Match($l.Trim())
        if ($m.Success) {
            $parsed += New-GCFinding -Check 'markdown' `
                -File (Get-GCRelativePath -RepoRoot $RepoRoot -Path $m.Groups['file'].Value) `
                -Line ([int]$m.Groups['line'].Value) -Rule $m.Groups['rule'].Value `
                -Message ($m.Groups['msg'].Value -replace '\s*\[Context:.*$', '').Trim()
        }
    }

    if ($ExitCode -eq 0) {
        if ($text -match '(?im)^\s*Usage:\s*markdownlint') {
            $findings += New-GCFinding -Check 'markdown' -Rule 'floor' -Message (
                'markdownlint exited 0 having linted nothing - measured 2026-09-17: it prints its usage banner and exits 0 when its arguments match no file')
        }
        return New-GCResult -Check 'markdown' -Examined $Examined -Findings $findings `
            -Evidence ("{0} .md file(s) clean{1}" -f $Examined, $(if ($Version) { " under markdownlint $Version" } else { '' }))
    }

    if ($parsed.Count) {
        return New-GCResult -Check 'markdown' -Examined $Examined -Findings ($findings + $parsed) `
            -Evidence ("{0} .md file(s) linted, {1} finding(s)" -f $Examined, $parsed.Count)
    }

    # Non-zero with nothing parseable is NEVER reported as clean: it is the tool failing, and the
    # raw transcript is the only useful thing left to hand over.
    $findings += New-GCFinding -Check 'markdown' -Rule 'tool' -Message (
        ("markdownlint exited {0} with no parseable findings - raw output: {1}" -f $ExitCode, ($text.Trim() -replace "`r?`n", ' | ')))
    New-GCResult -Check 'markdown' -Examined $Examined -Findings $findings `
        -Evidence ("markdownlint exited {0}" -f $ExitCode)
}


function Get-GCMarkdownResult {
    <#
        Every tracked .md must be clean under markdownlint.

        -MarkdownRunner IS MANDATORY BY DESIGN. This file may contain no native command (see the
        header), so the caller supplies a scriptblock that runs one. It is invoked BARE - no pipe,
        no redirection - because `& <non-scriptblock-literal>` counts as a native call to the
        repo-wide AST rule, and this is the one file where that rule has no escape hatch.

        ABSENT MEANS FAIL, not warn. The repo's standing rule is that a check which examined
        nothing must fail, and the CI job installs the tool so absence there means the install
        step broke. scripts\smoke-test.ps1 keeps its own "markdownlint not present - skipping"
        warning because that is a tool-inventory question about a machine, which is different.

        -c is passed EXPLICITLY. markdownlint's cwd search would otherwise pick the config up
        incidentally, and both callers launch children whose working directory is not guaranteed.
        A missing config is a finding, not a silent fall back to defaults - which would fire MD013
        on every long line in the repo.

        Explicit absolute file paths, never a glob: measured behaviour 2, a glob matching nothing
        makes markdownlint exit 0 with a usage banner.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [scriptblock]$MarkdownRunner,
        [string]$Config = '.markdownlint.json'
    )
    $files = @(Get-GCSourceFiles -RepoRoot $RepoRoot -Extension @('.md'))

    if (-not $MarkdownRunner) {
        return New-GCResult -Check 'markdown' -Examined $files.Count -Evidence 'no runner supplied' -Findings @(
            New-GCFinding -Check 'markdown' -Rule 'absent' -Message 'no markdown runner was supplied, so nothing was linted')
    }
    if ($files.Count -eq 0) {
        return ConvertFrom-GCMarkdownlintOutput -Examined 0 -RepoRoot $RepoRoot
    }

    # THE CONFIG CHECK COMES BEFORE THE TOOL LOOKUP, deliberately. A missing config is a defect in
    # the REPOSITORY and is true whether or not markdownlint happens to be installed on the box
    # asking; a missing tool is a defect in the ENVIRONMENT. Ordering them the other way round
    # made the config verdict depend on the environment, which is exactly the class of
    # machine-dependent test that cost this repo three CI-only failures on 2026-09-17.
    $cfg = Join-Path $RepoRoot $Config
    if (-not (Test-Path -LiteralPath $cfg)) {
        return New-GCResult -Check 'markdown' -Examined $files.Count -Evidence 'no config' -Findings @(
            New-GCFinding -Check 'markdown' -File $Config -Rule 'config' -Message (
                'the markdownlint config is missing; refusing to lint with tool defaults, which would fire MD013 repo-wide'))
    }

    $exe = Resolve-GCMarkdownlint
    if (-not $exe) {
        return New-GCResult -Check 'markdown' -Examined $files.Count -Evidence 'markdownlint not on PATH' -Findings @(
            New-GCFinding -Check 'markdown' -Rule 'absent' -Message (
                'markdownlint is not on PATH - install it with: npm install -g markdownlint-cli'))
    }

    $mdArgs = @('-c', $cfg) + @($files | ForEach-Object { $_.FullName })
    $run = & $MarkdownRunner $exe $mdArgs

    $version = ''
    if ($run -and $run.PSObject.Properties.Name -contains 'Version') { $version = [string]$run.Version }

    ConvertFrom-GCMarkdownlintOutput -Output ([string]$run.Output) -ExitCode ([int]$run.ExitCode) `
        -Examined $files.Count -RepoRoot $RepoRoot -Version $version
}


function Get-GateCheckTable {
    <#
        The registry, in run order. ONE object, so a check cannot be listed-but-unreachable or
        reachable-but-unlisted. Cheap and deterministic first.
    #>
    @(
        [pscustomobject]@{ Name = 'parse';         Run = { param($Ctx) Get-GCParseResult -RepoRoot $Ctx.RepoRoot -HostMajor $Ctx.HostMajor } }
        [pscustomobject]@{ Name = 'wiring';        Run = { param($Ctx) Get-GCWiringResult -RepoRoot $Ctx.RepoRoot -Require $Ctx.Require } }
        [pscustomobject]@{ Name = 'guard-order';   Run = { param($Ctx) Get-GCGuardOrderResult -RepoRoot $Ctx.RepoRoot } }
        [pscustomobject]@{ Name = 'writers';       Run = { param($Ctx) Get-GCWriterResult -RepoRoot $Ctx.RepoRoot } }
        [pscustomobject]@{ Name = 'control-bytes'; Run = { param($Ctx) Get-GCControlByteResult -RepoRoot $Ctx.RepoRoot } }
        [pscustomobject]@{ Name = 'markdown';      Run = { param($Ctx) Get-GCMarkdownResult -RepoRoot $Ctx.RepoRoot -MarkdownRunner $Ctx.MarkdownRunner } }
    )
}


function Get-GateCheckResults {
    <#
        Run the registry and return one result per check.

        EVERY CHECK IS WRAPPED, so one that throws becomes a finding instead of taking the other
        five with it. That is the per-check independence gate.yml wanted from six separate steps
        and did not get: a failing STEP aborts the job, which is how six checks stopped running
        for six days behind one unrelated failure.

        -Table EXISTS SO THE WRAPPER ITSELF IS TESTABLE, and it has to be a parameter rather than
        a clever fixture. Making the wrapper fire by breaking a real check means finding an input
        that reliably throws on every machine, and every candidate turned out to be
        environment-dependent - which is the exact class of test that produced three CI-only
        failures here on 2026-09-17, one of them in the suite covering this file. A table
        containing a deliberately throwing check is deterministic everywhere.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Name,
        [int]$HostMajor = $PSVersionTable.PSVersion.Major,
        [scriptblock]$MarkdownRunner,
        [string[]]$Require = @(),
        [object[]]$Table
    )
    if (-not $Table) { $Table = Get-GateCheckTable }
    $ctx = [pscustomobject]@{
        RepoRoot       = $RepoRoot
        HostMajor      = $HostMajor
        MarkdownRunner = $MarkdownRunner
        Require        = @($Require)
    }
    $results = @()
    foreach ($check in $Table) {
        if ($Name -and ($Name -notcontains $check.Name)) { continue }
        try {
            $results += (& $check.Run $ctx)
        } catch {
            $results += New-GCResult -Check $check.Name -Examined 0 -Evidence 'threw' -Findings @(
                New-GCFinding -Check $check.Name -Rule 'threw' -Message ("the check itself threw: {0}" -f $_.Exception.Message))
        }
    }
    return @($results)
}
