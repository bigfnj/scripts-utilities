#Requires -Version 5.1
<#
    AgentDiscovery.ps1 - read the DEPLOYED agent-discovery blocks and reach the GENERATOR that
    is supposed to have produced them, without running the generator.

    WHY THIS FILE EXISTS. The four deployed blocks had drifted a whole section behind the
    generator - it had gained a Sysmon/deletion-forensics paragraph that none of the deployed
    copies carried - and nothing compared deployed against generator, while README.md claimed
    "the gate exercises ... the agent-discovery blocks". This file is that missing half.

    THAT PARTICULAR DRIFT IS CLOSED, re-measured 2026-09-17: the paragraph lives in
    Write-AgentDiscovery's here-string (search `Sysmon      Deletion forensics`) and all four
    deployed copies carry it. The check stays because the drift will happen again the next time
    the generator is edited without a deploy - which is the whole point of a check - but the
    header no longer asserts a staleness that has been fixed.

    LINE ANCHORS DELIBERATELY REMOVED. This paragraph used to cite BACKLOG.md:242-245 and
    lib\common.ps1:564-575; both had moved, and the repo's own backlog header records that line
    anchors go stale while symbol names do not. Name the symbol, let the reader grep.

    THE GENERATOR CANNOT SIMPLY BE CALLED. Write-AgentDiscovery builds the body and then hands it
    straight to Write-AgentBlock four times, and Write-AgentBlock WRITES to the user's real
    %USERPROFILE%\CLAUDE.md, .claude\CLAUDE.md, AGENTS.md and .codex\AGENTS.md. A check that
    writes the thing it is checking cannot fail, and this one would write to files nobody asked it
    to touch. Neither writer is ever invoked from here.

    SO THE BODY IS EXTRACTED, NOT EXECUTED WHOLESALE. Get-AgentDiscoveryBody parses
    lib\common.ps1, takes only the ASSIGNMENT statements out of Write-AgentDiscovery's body, and
    evaluates those. The Write-AgentBlock calls are not shadowed or stubbed - they are not present
    in what runs, which is a property of the construction rather than a promise.

    REJECTED: shadowing Write-AgentBlock with a capture function and calling Write-AgentDiscovery.
    It is shorter and it works today (a function shadows a cmdlet or another function for every
    caller in the session - the same property SUTestGuard.ps1:26-28 relies on). It was dropped
    because it depends on the generator continuing to write ONLY through that one function: the
    day someone inlines a Set-Content, the check silently starts overwriting four real files in
    the user's profile. Extraction fails closed instead; shadowing fails open.

    REJECTED: extracting the body into a shared function that both common.ps1 and this file call,
    which is the obvious de-duplication. lib\common.ps1 is owned elsewhere in this change set and
    is not edited here. Worth doing later - it turns a structural assertion into a plain function
    call - and it is recorded as a follow-up rather than pretended away.

    FAIL CLOSED, LOUDLY. Every refusal returns a Reason string instead of $null-and-carry-on, so
    the caller reports "could not reach the generator" as a FAILURE. A check that cannot reach its
    reference and says nothing is the exact shape this repository keeps removing.
#>

# Only these may appear inside the statements that get evaluated. A generator that starts calling
# something else is not refused because the new command is dangerous - it is refused because
# nobody has looked at it yet, and this file executes source it does not own.
$script:ADAllowedCommands = @('Join-Path')

# METHOD INVOCATIONS ARE REFUSED OUTRIGHT, and the empty list is the point rather than an
# oversight. The allowlist above walks CommandAst nodes, and a method call is not one:
# `[IO.File]::ReadAllText(...)` is an InvokeMemberExpressionAst and `$x.Foo()` likewise, so
# neither was ever examined - in a function whose whole job is to `&` source it does not own.
# Measured 2026-09-17: Write-AgentDiscovery contains ZERO method invocations and exactly two
# command calls (Join-Path, Write-AgentBlock), so refusing every method costs nothing today and
# forces a review the first time one appears. Add a member name here only after reading it.
$script:ADAllowedMembers = @()

function Get-AgentDiscoveryBody {
    <#
    .SYNOPSIS
        The body Write-AgentDiscovery WOULD deploy, obtained without deploying it.

    .OUTPUTS
        [pscustomobject] @{ Body; Targets; Marker; Reason }
        Reason is $null on success and a human sentence on refusal; Body is $null on refusal.
        Targets are the expanded file paths the generator writes to, in source order.
    #>
    param(
        [Parameter(Mandatory)][string]$CommonPath,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $fail = {
        param($Why)
        [pscustomobject]@{ Body = $null; Targets = @(); Marker = $null; Reason = $Why }
    }

    if (-not (Test-Path -LiteralPath $CommonPath)) { return (& $fail "missing $CommonPath") }

    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($CommonPath, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) {
        return (& $fail "$(Split-Path $CommonPath -Leaf) does not parse: $($errs[0].Message)")
    }

    $fn = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Write-AgentDiscovery' }, $true)) | Select-Object -First 1
    if (-not $fn) { return (& $fail "no Write-AgentDiscovery function in $(Split-Path $CommonPath -Leaf)") }
    if (-not $fn.Body.EndBlock) { return (& $fail 'Write-AgentDiscovery has no statement body') }

    $assignments = @()
    $writes      = @()
    foreach ($st in $fn.Body.EndBlock.Statements) {
        if ($st -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            $assignments += $st
            continue
        }
        # Anything that is not an assignment is dropped, so it had better be a writer call and
        # nothing else - otherwise the statements that remain are no longer the whole recipe.
        $cmd = @($st.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $names = @($cmd | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        if ($names.Count -ne 1 -or $names[0] -ne 'Write-AgentBlock') {
            return (& $fail ("unrecognised statement at {0}:{1} - Write-AgentDiscovery now does something other than assign and call Write-AgentBlock, so its body can no longer be extracted safely" -f (Split-Path $CommonPath -Leaf), $st.Extent.StartLineNumber))
        }
        $writes += $cmd[0]
    }

    if ($writes.Count -eq 0) { return (& $fail 'Write-AgentDiscovery makes no Write-AgentBlock calls') }

    # The statements about to be EVALUATED are source from a file this one does not own. Refuse
    # anything outside the allowlist rather than run it and hope.
    #
    # ONE WALK, THREE CALL SITES, and it covers METHODS as well as commands. The original walked
    # CommandAst only, so every method invocation was invisible to it - which in a function that
    # ends in `& $sb` is the gap that matters most. It also checked the ASSIGNMENTS only, while
    # the path and marker argument expressions below are spliced verbatim into that same
    # scriptblock and evaluated; two arguments per Write-AgentBlock call went in unexamined.
    $clearAst = {
        param($Node, $What)
        foreach ($c in $Node.FindAll({ param($x)
                $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $n = $c.GetCommandName()
            # $null means the name is not a literal - `& $var`, or a parenthesised expression.
            # That is refused rather than skipped: an unknowable name cannot be on an allowlist.
            if (-not $n) {
                return ("{0} at {1}:{2} invokes a command whose name is not a literal, so it cannot be cleared - rewrite it as a direct call" -f $What, (Split-Path $CommonPath -Leaf), $c.Extent.StartLineNumber)
            }
            if ($script:ADAllowedCommands -notcontains $n) {
                return ("{0} at {1}:{2} calls '{3}', which this extractor is not cleared to execute - review it and add it to `$script:ADAllowedCommands if it is inert" -f $What, (Split-Path $CommonPath -Leaf), $c.Extent.StartLineNumber, $n)
            }
        }
        foreach ($m in $Node.FindAll({ param($x)
                $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            $member = if ($m.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $m.Member.Value } else { '<computed>' }
            if ($script:ADAllowedMembers -notcontains $member) {
                return ("{0} at {1}:{2} invokes method '{3}', which this extractor is not cleared to execute - review it and add it to `$script:ADAllowedMembers if it is inert" -f $What, (Split-Path $CommonPath -Leaf), $m.Extent.StartLineNumber, $member)
            }
        }
        return $null
    }

    foreach ($a in $assignments) {
        $reason = & $clearAst $a "the generator's setup"
        if ($reason) { return (& $fail $reason) }
    }

    $bodyAssign = @($assignments | Where-Object {
        $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $_.Left.VariablePath.UserPath -eq 'body' })
    if ($bodyAssign.Count -ne 1) {
        return (& $fail ("expected exactly one `$body assignment in Write-AgentDiscovery, found {0}" -f $bodyAssign.Count))
    }

    # Markers: all four calls pass the same one today. If they ever diverge, say so rather than
    # silently checking three files against the fourth one's marker.
    $markerArgs = @()
    $pathArgs   = @()
    foreach ($w in $writes) {
        $positional = @($w.CommandElements | Select-Object -Skip 1 |
            Where-Object { -not ($_ -is [System.Management.Automation.Language.CommandParameterAst]) })
        if ($positional.Count -lt 2) {
            return (& $fail ("Write-AgentBlock call at {0}:{1} has fewer than two positional arguments" -f (Split-Path $CommonPath -Leaf), $w.Extent.StartLineNumber))
        }
        # The same clearance as the assignments, because these two expressions are spliced into
        # the evaluated scriptblock below exactly as written.
        $reason = & $clearAst $positional[0] "a Write-AgentBlock path argument"
        if ($reason) { return (& $fail $reason) }
        $reason = & $clearAst $positional[1] "a Write-AgentBlock marker argument"
        if ($reason) { return (& $fail $reason) }

        $pathArgs   += $positional[0].Extent.Text
        $markerArgs += $positional[1].Extent.Text
    }

    # Source order, so $codexAgents (assigned at common.ps1:602, between two of the calls) is
    # already defined by the time the path expressions below are evaluated.
    $code = New-Object 'System.Text.StringBuilder'
    [void]$code.AppendLine('param([string]$RepoRoot)')
    foreach ($a in ($assignments | Sort-Object { $_.Extent.StartOffset })) {
        # Column 0, always: the body is a here-string and PowerShell requires its terminator to
        # start a line. Indenting this loop's output is a parse error, not a style choice.
        [void]$code.AppendLine($a.Extent.Text)
    }
    [void]$code.AppendLine('[pscustomobject]@{')
    [void]$code.AppendLine('  Body = $body')
    [void]$code.AppendLine(('  Targets = @({0})' -f ($pathArgs -join ', ')))
    [void]$code.AppendLine(('  Markers = @({0})' -f ($markerArgs -join ', ')))
    [void]$code.AppendLine('}')

    $result = $null
    try {
        $sb = [scriptblock]::Create($code.ToString())
        $result = & $sb $RepoRoot
    } catch {
        return (& $fail "evaluating the generator's body failed: $($_.Exception.Message)")
    }
    if (-not $result -or -not $result.Body) { return (& $fail 'the generator produced an empty body') }

    $markers = @($result.Markers | Select-Object -Unique)
    if ($markers.Count -ne 1) {
        return (& $fail ("Write-AgentDiscovery now uses {0} different markers ({1}); this check assumes one" -f $markers.Count, ($markers -join ', ')))
    }

    [pscustomobject]@{
        Body    = [string]$result.Body
        Targets = @($result.Targets | ForEach-Object { [string]$_ })
        Marker  = [string]$markers[0]
        Reason  = $null
    }
}

function Get-AgentBlockText {
    <#
    .SYNOPSIS
        The text BETWEEN the markers in a deployed file, or $null when the markers are absent.

    .DESCRIPTION
        The block, never the file. %USERPROFILE%\.claude\CLAUDE.md wraps ~5.4 KB of the user's own
        standing instructions around this block, and %USERPROFILE%\.codex\AGENTS.md another 5.4 KB
        of its own; comparing whole files would report those as staleness for ever. Measured
        2026-09-11: 12,332 / 12,314 bytes against 6,893 for the two bare copies, which are
        byte-identical to each other.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Marker
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path)
    $pattern = '(?s)' + [regex]::Escape("<!-- ${Marker}_START -->") +
               '\r?\n(.*?)\r?\n' + [regex]::Escape("<!-- ${Marker}_END -->")
    $m = [regex]::Match($raw, $pattern)
    if (-not $m.Success) { return $null }
    $m.Groups[1].Value
}

function ConvertTo-AgentBlockComparable {
    <#
        Line endings are normalised before comparing, and that is a deliberate blind spot.
        Write-AgentBlock joins the markers to the body with "`n" while the body itself is a
        here-string in a CRLF-saved file, so the generator's own output is mixed-ending by
        construction; and %USERPROFILE%\.claude\CLAUDE.md is rewritten wholesale by unrelated
        tooling. Failing on that would be a check that fires on every run for a reason nobody can
        act on. Trailing whitespace goes the same way, for the same reason.
    #>
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    (($Text -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd()
}

function Get-AgentBlockDrift {
    <#
    .SYNOPSIS
        The first line where a deployed block and the generated body disagree, as a sentence.

    .DESCRIPTION
        "Stale" with no detail sends the reader diffing 120 lines by hand - and the difference is
        usually one added paragraph. Naming the line makes the common case (the generator gained a
        section) readable at a glance.

        The COUNT is reported alongside the first difference because of the second common case:
        run the gate from a git worktree and the block's ~9 repo-path lines all differ at once.
        "1 of 107 lines differ, first at 92" and "9 of 107 differ, first at 4: Managed by" are the
        same verdict and completely different situations, and a reader should not have to guess
        which one they are looking at.
    #>
    param([string]$Deployed, [string]$Generated)
    $a = @((ConvertTo-AgentBlockComparable $Deployed)  -split "`n")
    $b = @((ConvertTo-AgentBlockComparable $Generated) -split "`n")
    $n = [Math]::Max($a.Count, $b.Count)
    $firstAt = -1
    $diffs = 0
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { '<end of deployed block>' }
        $y = if ($i -lt $b.Count) { $b[$i] } else { '<end of generated body>' }
        if ($x -ne $y) {
            $diffs++
            if ($firstAt -lt 0) {
                $firstAt = $i
                $firstMsg = ("deployed '{0}' vs generated '{1}'" -f `
                    (Format-AgentDriftSnippet $x), (Format-AgentDriftSnippet $y))
            }
        }
    }
    if ($diffs -eq 0) { return ("{0} block line(s) match" -f $n) }
    ("{0} of {1} line(s) differ, first at block line {2}: {3}" -f $diffs, $n, ($firstAt + 1), $firstMsg)
}

function Format-AgentDriftSnippet {
    param([string]$Text)
    $t = $Text.Trim()
    if ($t.Length -gt 72) { return $t.Substring(0, 69) + '...' }
    if ($t.Length -eq 0) { return '<blank line>' }
    $t
}

function Get-AgentBlockManagedBy {
    <#
        The "Managed by:" line is the block's own claim about which checkout produced it. It is a
        SEPARATE fact from freshness: a block can be a faithful render of an older generator AND
        name a live checkout, or be current-looking AND point at a directory that was deleted.
        Reporting one boolean for both is what let a Sysmon config naming a nonexistent profile
        pass as healthy for a year (smoke-test.ps1:454-456).
    #>
    param([string]$Block)
    if ($null -eq $Block) { return $null }
    $m = [regex]::Match($Block, '(?m)^Managed by:\s*(\S.*?)\s*$')
    if (-not $m.Success) { return $null }
    $m.Groups[1].Value
}

function Test-AgentBlockRepoRoot {
    <#
        Is the path the block names a live checkout of THIS repository? Not "is it the checkout
        the smoke test is running from" - three git worktrees of this repo are open on this box
        right now, and a gate that fails whenever you run it from a worktree gets switched off.
        The failure worth catching is the block pointing at a directory that no longer holds the
        repo at all, which is the state after a move or a delete.
    #>
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    foreach ($probe in @('catalog.json', 'scripts\smoke-test.ps1', 'lib\common.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $probe))) { return $false }
    }
    $true
}
