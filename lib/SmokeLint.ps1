#Requires -Version 5.1
<#
    SmokeLint.ps1 - the rules that keep scripts\smoke-test.ps1's own checks capable of failing.

    WHY IT MOVED OUT OF smoke-test.ps1. The rule lived as an inline scriptblock at
    smoke-test.ps1 itself and was therefore untestable: no test file anywhere referenced
    smoke-test.ps1, and gate.yml deliberately does not run it (gate.yml:16-20), so DELETING the
    lint failed nothing. A rule nobody can break on purpose is a rule nobody knows works. Here it
    has fixtures - including the false-positive controls, which are the ones that decide whether
    a lint survives contact with its authors.

    RULE A - a verdict that cannot be reached by a failure.
        A try body that calls Test-Ok while inspecting neither $LASTEXITCODE nor a comparison.
        Six checks in smoke-test.ps1 had this shape. A native command that RUNS and exits
        non-zero raises no PowerShell exception, so the catch only fires when the process cannot
        start at all - Test-Ok is then reached on every path where the tool existed. Measured: a
        shim printing a plausible version banner and exiting 3 was reported "OK".

        A try that only GATHERS is fine and is NOT flagged. The SysmonDrv and USN checks read a
        native command inside a try and decide outside it, with an explicit warn-on-unreadable
        branch. That is a better pattern than the one being outlawed, and the first draft of this
        lint flagged it; the note that used to sit at smoke-test.ps1:452-457 recorded the judgement that a lint crying wolf
        about the better pattern "would be turned off within a week".

    RULE B - an exit-code check that INVENTS failures.
        `<native command> | ... | Select-Object -First N` inside a block that also reads
        $LASTEXITCODE. -First raises StopUpstreamCommandsException to short-circuit the pipeline,
        which kills the native process mid-write and leaves $LASTEXITCODE = -1. Found the day the
        exit check was added to the gh probe: gh reported "exited -1" while being perfectly
        healthy (smoke-test.ps1:78-82). The safe shape, used in three places now, drains the
        whole stream with Out-String FIRST and takes -First 1 off the resulting STRING.

        RULE B IS STRUCTURAL ON PURPOSE. Rule A's regex tests only that "$LASTEXITCODE" or a
        spaced comparison APPEARS somewhere in the body, so a block pairing -First 1 WITH an
        exit-code check satisfies it and passes - and that pairing is itself the defect. A
        presence regex cannot distinguish the bug from the fix; the AST can.

    WHY THE FIRST PIPELINE ELEMENT MUST BE AN APPLICATION. `$text -split "`r?`n" | Select-Object
    -First 1` is the FIX, and it parses as a CommandExpressionAst rather than a CommandAst, so it
    is structurally out of scope. `Get-ChildItem | Select-Object -First 1` is a cmdlet: -First
    short-circuits it too, but there is no native process and no exit code to corrupt. Only a
    native process can be killed mid-write.

    APPLICATION IS DECIDED BY ELIMINATION, not by Get-Command returning Application. `gh` is not
    installed on every box that runs this lint - it is absent from this repository's own git
    worktrees - so keying on a positive Application lookup would make the rule fire or stay quiet
    depending on which tools happen to be present. A name that resolves to no cmdlet, function,
    alias or file-local function definition is what PowerShell would go to PATH for, which is the
    property that matters and is stable everywhere.
#>

$script:SLComparisonOps = 'eq|ne|match|notmatch|like|notlike|gt|lt|ge|le|contains|in|is'

function Get-SmokeLintFindings {
    <#
    .SYNOPSIS
        Every rule violation in one file.

    .OUTPUTS
        [pscustomobject] @{ Line; Rule; Message }, empty when the file is clean.
        A file that does not parse is itself a finding (rule 'parse') rather than a silent zero -
        an unparseable file produces no ASTs, so every rule would otherwise report clean.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $findings = @()
    if (-not (Test-Path -LiteralPath $Path)) {
        return @([pscustomobject]@{ Line = 0; Rule = 'parse'; Message = "file not found: $Path" })
    }

    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) {
        return @([pscustomobject]@{ Line = $errs[0].Extent.StartLineNumber; Rule = 'parse'
                                    Message = "does not parse: $($errs[0].Message)" })
    }

    $findings += @(Get-SLRuleAFindings -Ast $ast)
    $findings += @(Get-SLRuleBFindings -Ast $ast)
    @($findings | Sort-Object Line, Rule)
}

function Get-SLRuleAFindings {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)

    $out = @()
    foreach ($t in $Ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)) {
        $body = $t.Body.Extent.Text
        if ($body -notmatch '\bTest-Ok\b') { continue }          # gathers only; verdict is elsewhere
        $hasExit    = $body -match '\$LASTEXITCODE'
        $hasCompare = $body -match ('\s-(' + $script:SLComparisonOps + ')\s')
        if ($hasExit -or $hasCompare) { continue }
        $out += [pscustomobject]@{
            Line    = $t.Extent.StartLineNumber
            Rule    = 'A'
            Message = 'try block calls Test-Ok while checking neither an exit code nor a comparison, so it cannot fail'
        }
    }
    $out
}

function Get-SLRuleBFindings {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)

    $localFunctions = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name })

    $out = @()
    foreach ($pipe in $Ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.PipelineAst] }, $true)) {

        $elements = @($pipe.PipelineElements)
        if ($elements.Count -lt 2) { continue }

        if (-not (Test-SLSelectFirst $elements[-1])) { continue }

        $head = $elements[0]
        if (-not ($head -is [System.Management.Automation.Language.CommandAst])) { continue }
        $name = $head.GetCommandName()
        if (-not (Test-SLApplicationName -Name $name -LocalFunctions $localFunctions)) { continue }

        # Nearest enclosing statement block, NOT the whole file. A file-wide search for
        # $LASTEXITCODE would match smoke-test.ps1 in its entirety and flag every -First in it.
        # The consequence, stated rather than discovered: a pipeline at the top level of a script
        # has no enclosing statement block and is out of scope. Every real instance of this bug
        # sits inside the try or if that holds the exit-code check, which is the whole reason the
        # two end up adjacent.
        $block = $pipe.Parent
        while ($block -and -not ($block -is [System.Management.Automation.Language.StatementBlockAst])) {
            $block = $block.Parent
        }
        if (-not $block) { continue }
        if ($block.Extent.Text -notmatch '\$LASTEXITCODE') { continue }

        $out += [pscustomobject]@{
            Line    = $pipe.Extent.StartLineNumber
            Rule    = 'B'
            Message = ("'{0} | ... | Select-Object -First' sits in a block that reads `$LASTEXITCODE - -First kills the native process mid-write and leaves the exit code at -1, inventing a failure. Drain with Out-String first, then take -First off the string" -f $name)
        }
    }
    $out
}

function Test-SLSelectFirst {
    <#
        Is this pipeline element `Select-Object -First ...`? Parameter names are matched by
        prefix because PowerShell resolves them that way: `-Fir 1` behaves identically to
        `-First 1` and would otherwise walk straight past the rule.
    #>
    param($Element)
    if (-not ($Element -is [System.Management.Automation.Language.CommandAst])) { return $false }
    $n = $Element.GetCommandName()
    if ($n -notin @('Select-Object', 'select')) { return $false }
    foreach ($e in $Element.CommandElements) {
        if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
            if ($e.ParameterName -and ('First' -like ($e.ParameterName + '*'))) { return $true }
        }
    }
    $false
}

function Test-SLApplicationName {
    <#
        True when PowerShell would have to go to PATH to run $Name - i.e. it is not a cmdlet, not
        a function (in the session OR defined in the file being linted), not an alias.

        RESIDUAL, stated rather than hidden: a function that arrives only by dot-sourcing another
        file is invisible here and would be judged an application. Nothing in this repository puts
        such a function at the head of a pipeline ending in Select-Object -First, and the cost of
        being wrong is a false positive on a line that a human then reads - not a missed bug.
    #>
    param([string]$Name, [string[]]$LocalFunctions)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($LocalFunctions -contains $Name) { return $false }
    $resolved = Get-Command -Name $Name -CommandType Cmdlet, Function, Alias, Filter `
                            -ErrorAction SilentlyContinue
    -not $resolved
}
