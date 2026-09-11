# The .cmd shim byte contract, and nothing else.
#
# WHY THIS FILE IS SEPARATE FROM lib\ShimPlan.ps1. Seven places in this repo write a shim and
# three read one back, and until now every one of them carried its own copy of the format. That
# is the drift shape this project keeps closing elsewhere, so the two functions became shared -
# but the obvious home, ShimPlan.ps1, could not reach the callers that needed them:
#
#   scripts\build-devtoolbox.ps1  dot-sources NOTHING. It is deliberately standalone because
#                                 bootstrap.ps1 invokes it as a child process.
#   modules\security.ps1          dot-sources nothing either; it is dot-sourced BY bootstrap.ps1,
#                                 whose scope has lib\common.ps1 but not lib\ShimPlan.ps1.
#
# Dragging 958 lines of planner into every bootstrap run to obtain a two-line string builder is
# the wrong trade, so the contract lives here and the planner consumes it like everyone else.
# Dot-sourced by lib\common.ps1 (which reaches bootstrap, the modules and the smoke test), by
# lib\ShimPlan.ps1 (which reaches consolidate-path.ps1), and directly by build-devtoolbox.ps1.
#
# Functions only. No side effects on dot-source, so any script can source it just to read or
# write one wrapper.

function New-ShimBody {
    <#
        THE one definition of the shim byte shape:  @echo off<CRLF>"<abs target>" %*<CRLF>
        ASCII, no BOM, written with -NoNewline so nothing appends a third line.

        A LITERAL `r`n, never [Environment]::NewLine and never a here-string. The bytes have to
        be a property of THIS CODE, not of the machine or of the checkout: the repo has
        core.autocrlf=true and no .gitattributes, so a here-string's line endings are whatever
        git handed this working copy. build-devtoolbox.ps1's New-CmdWrapper was exactly that
        here-string until 2026-09-11 - the rule was written down here while the largest writer in
        the repo violated it.

        The consequence is not cosmetic. Every reader anchors its regex on $, so a lone LF makes
        every shim unparseable and the smoke test reports 47 healthy shims as 0 stale ones - a
        silent, total loss of the only check that notices a broken wrapper.

        -Prologue exists for exactly one caller: modules\security.ps1 wraps Ghidra with a
        `set "JAVA_HOME=..."` line so the launcher gets a private JDK without a global change.
        It is a list of whole lines inserted after `@echo off`, never interpolated into the
        target line, so it cannot alter the shape the readers depend on.
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [string[]]$Prologue = @()
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("@echo off`r`n")
    foreach ($line in @($Prologue)) {
        if ($null -eq $line -or $line -eq '') { continue }
        [void]$sb.Append($line)
        [void]$sb.Append("`r`n")
    }
    [void]$sb.Append("`"$Target`" %*`r`n")
    return $sb.ToString()
}

function Get-ShimTarget {
    <#
        The target a wrapper points at, or $null if no line matches.

        SCANS FOR THE FIRST MATCHING LINE - never "read the second line". The Ghidra wrapper is
        three lines with `set "JAVA_HOME=..."` in the middle, and a positional read would report
        the JAVA_HOME assignment as Ghidra's target.
    #>
    param([string[]]$Lines = @())
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        if ($line -match '^"([^"]+)" %\*$') { return $Matches[1] }
    }
    return $null
}
