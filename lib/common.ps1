# Shared helpers - sourced (dot-sourced) by bootstrap.ps1 and every module.
# Defines functions only; no side effects on dot-source.

if (-not (Get-Variable -Name DryRun -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DryRun = $false
}
$script:MANIFEST = Join-Path $PSScriptRoot "..\manifest\tools.json"

# Get-RawPath / Set-RawPath / Remove-PathEntryFromString, for Remove-MachinePathEntry below.
# That file defines NO logging functions on purpose: its Write-Ok would otherwise fight the one
# defined a few lines down, which takes -Msg where consolidate-path.ps1's takes a positional $t.
. (Join-Path $PSScriptRoot "path-registry.ps1")

# New-ShimBody / Get-ShimTarget - the .cmd wrapper byte contract, shared with the four writers in
# modules\security.ps1 (which run in bootstrap's scope, i.e. this one) and with the reader in
# scripts\smoke-test.ps1. Deliberately a separate tiny file rather than lib\ShimPlan.ps1: pulling
# 958 lines of planner into every bootstrap run to get a two-line string builder is the wrong
# trade, and build-devtoolbox.ps1 - which dot-sources nothing else at all - needs it too.
. (Join-Path $PSScriptRoot "ShimFormat.ps1")

# -- Logging -------------------------------------------------------------------
function Write-Info  { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "OK $Msg" -ForegroundColor Green }
function Write-Skip  { param([string]$Msg) Write-Host "- $Msg" -ForegroundColor DarkGray }
function Write-Warn  { param([string]$Msg) Write-Host "WARN $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "FAIL $Msg" -ForegroundColor Red }
function Write-Group { param([string]$Msg) Write-Host "`n== $Msg ==" -ForegroundColor White }

# -- Detection -----------------------------------------------------------------
function Test-CommandAvailable {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Assert-WingetAvailable {
    if (Test-CommandAvailable "winget") { return }
    throw @"
winget is required but is not available in this PowerShell session.
Install or update 'App Installer' from Microsoft Store, then open a new normal
PowerShell window and confirm 'winget --version' works before running bootstrap.
"@
}

# Refresh PATH from registry so newly-installed tools are visible in the current
# session without restarting PowerShell.
#
# THE ONE PLACE [Environment]::GetEnvironmentVariable IS THE RIGHT CALL, and it is not an
# oversight that it survived the 2026-09-11 migration of every other PATH reader onto Get-RawPath.
# This builds $env:PATH for the RUNNING PROCESS, which has to be expanded: a literal
# '%SystemRoot%\system32' in a process environment block resolves to nothing, so the raw value is
# the wrong input here. The prohibition is on the round trip - reading expanded and WRITING that
# back - and nothing below writes.
function Sync-EnvPath {
    $machine = [string][System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $user    = [string][System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $paths = @()
    $toolboxRoot = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX }
                   else { "$env:LOCALAPPDATA\DevToolbox" }
    foreach ($candidate in @(
        (Join-Path $toolboxRoot "native\bin"),
        (Join-Path $toolboxRoot "python\.venv\Scripts")
    )) {
        if (Test-Path $candidate) { $paths += $candidate }
    }
    $paths += ($machine -split ';')
    $paths += ($user -split ';')
    $env:PATH = ($paths | Where-Object { $_ } | Select-Object -Unique) -join ';'
}

function Invoke-Native {
    <#
        Run a native command with its output captured and its stderr survivable, returning the
        exit code beside the captured lines.

        LIVES HERE, not in bootstrap.ps1, because this file is where the exposure is. lib\ and
        modules\ are dot-sourced into a caller and never run standalone, so they inherit whatever
        $ErrorActionPreference that caller set - and bootstrap.ps1 sets 'Stop' at :24 before
        dot-sourcing this file at :27. Neither this file nor modules\security.ps1 assigns the
        preference, which is exactly what made the exposure invisible: a reader checking "does
        this script set Stop?" finds no, and is wrong.

        MEASURED, not assumed, 2026-09-11 under Windows PowerShell 5.1, because 2>$null looks
        like it should discard the stderr rather than promote it. It does not:

            $ErrorActionPreference = 'Stop'
            $o = & cmd /c "echo e 1>&2 & exit /b 0" 2>$null
            -> THREW  [NativeCommandError]

        Identical for 2>&1, and identical in all three host-stream conditions tested (console
        inherited, parent-captured with 2>&1 | Out-String, Start-Process with both standard
        streams to files). The same probe with NO redirection - bare, assigned, or piped to
        Out-Null - survived every condition. The REDIRECTION is the trigger, not the pipe.

        And the dynamic scoping is real, probed separately: a function in a file that never
        mentions $ErrorActionPreference, dot-sourced by a script that set 'Stop', THREW on a
        redirected native call. That is why a file-scoped audit misses these.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
    } finally { $ErrorActionPreference = $prev }
}

# Append an entry to the persistent user PATH. Returns $true unless the directory is missing.
#
# THIS COMMENT SITS ABOVE THE FUNCTION IT DESCRIBES AGAIN. It was stranded above Invoke-Native
# when that function was inserted between the two, so its "this function" and its "NO -DryRun
# BRANCH" paragraph read as claims about a wrapper that has neither a PATH nor a registry write.
#
# THROUGH Get-RawPath / Set-RawPath, never [Environment]::Get/SetEnvironmentVariable - the same
# prohibition Remove-MachinePathEntry states below, applied to the hive where it had been ignored.
# Both halves of that API are wrong for an edit and the second is permanent: Get EXPANDS %VAR% on
# read, Set writes the value back as REG_SZ, and a REG_SZ PATH never expands a %VAR% again.
#
# The user hive looks like it has nothing to lose - measured 2026-09-11, 3 entries, none of them
# %VAR%-based - but its value KIND is RegistryValueKind::ExpandString, exactly like the machine
# hive's. One write through the framework API demotes it, and the damage is then silent and
# deferred: the next %VAR% entry anyone adds by hand simply never expands, in a hive that looks
# fine and whose kind nobody thinks to check.
#
# THE -DryRun GUARD BELOW IS THE ONE THIS FUNCTION SPENT A MIGRATION WITHOUT, and the gap was
# reachable, not theoretical. bootstrap.ps1's Register-ToolboxUserPath guards its own call site
# (:407), but lib\catalog.ps1:94 and :104 did not - under -DryRun Install-WingetTool returns
# $true WITHOUT installing, so a path_fallback tool whose binary is absent arrived here and the
# registry was written by a run that promised to change nothing. Measured 2026-09-17 with the
# registry helpers stubbed: Install-CatalogItem on a winget-machine item with an existing
# path_fallback directory produced ONE user-hive write under -DryRun, and printed "added user
# PATH entry" while doing it. Four of catalog.json's tools declare a path_fallback and all four
# of those directories exist on this box.
#
# The guard is Remove-UserPathEntry's idiom, deliberately: report and leave. It returns $true
# rather than the sibling's bare return because a dry run that reported an install FAILURE it
# had not had would be a different lie in the same place.
function Add-UserPathEntry {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Warn "PATH entry does not exist: $Path"
        return $false
    }
    $resolved = (Resolve-Path $Path).Path

    # DO NOT ADD WHAT THE MACHINE HIVE ALREADY ANSWERS FOR. Windows composes machine-then-user,
    # so a user entry duplicating a machine one can never win a lookup - it cannot change
    # resolution, it only spends characters against the 4,095-character truncation cliff. This
    # box had two such duplicates (the toolbox native\bin and sysinternals), added here on every
    # bootstrap run because this function only ever looked at the user hive.
    #
    # It is also what makes those two entries prunable at all: config\path-hygiene.json can now
    # list them as duplicate-in-machine without the next bootstrap run silently putting them
    # back, which would have made -Prune and bootstrap fight over the hive forever.
    #
    # FAILS OPEN, LOUDLY. If the machine hive cannot be read we add as before rather than fail a
    # bootstrap over a deduplication - but we say so, because a check that can run degraded and
    # stays quiet about it is indistinguishable from one that passed.
    try {
        if (Test-PathListProvides -Value (Get-RawPath -Scope Machine) -Path $resolved) {
            Write-Info "machine PATH already provides it, so no user entry is needed: $resolved"
            Sync-EnvPath
            return $true
        }
    } catch {
        Write-Warn "could not read the machine PATH to check for a duplicate ($($_.Exception.Message)); adding the user entry anyway"
    }

    $raw = Get-RawPath -Scope User
    $entries = @(Split-PathList $raw)
    # EXPANDED TO COMPARE, RAW TO RE-EMIT. Reading through the framework API used to expand every
    # entry for free, so a hand-written '%LOCALAPPDATA%\DevToolbox\native\bin' was recognised as
    # already present. Comparing the literal text alone would miss it and append a second,
    # equivalent entry - a duplicate introduced by the very change that was meant to stop the
    # registry being rewritten. Expansion is a property of the COMPARISON only; what goes back is
    # the untouched raw text plus $resolved.
    $exists = $entries | Where-Object {
        ([System.Environment]::ExpandEnvironmentVariables($_)).TrimEnd('\') -ieq $resolved.TrimEnd('\')
    } | Select-Object -First 1
    if (-not $exists) {
        if ($script:DryRun) {
            Write-Info "[DRY-RUN] would add user PATH entry: $resolved"
            return $true
        }
        Set-RawPath -Scope User -Value ((@($entries) + $resolved) -join ';')
        Write-Ok "added user PATH entry: $resolved"
    }
    Sync-EnvPath
    return $true
}

# Remove an entry from the persistent user PATH (mirror of Add-UserPathEntry).
# Matches case-insensitively, ignoring a trailing backslash. Idempotent.
#
# Same registry mechanism and the same expand-to-compare rule as Add-UserPathEntry above; see
# there for why the framework API cannot be used for either half. The argument is expanded too,
# because uninstall-toolbox.ps1:180 already hands this function an
# ExpandEnvironmentVariables'd path - comparing an expanded argument against raw entries would
# make the uninstaller silently fail to undo an entry it can plainly see.
function Remove-UserPathEntry {
    param([string]$Path)
    $raw = Get-RawPath -Scope User
    if (-not $raw) { return }
    $target = ([System.Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\')
    $drop = @(Split-PathList $raw | Where-Object {
        ([System.Environment]::ExpandEnvironmentVariables($_)).TrimEnd('\') -ieq $target
    })
    if ($drop.Count -eq 0) { return }   # nothing matched
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would remove user PATH entry: $Path"
        return
    }
    # The matching above decides WHICH raw entries go; Remove-PathEntryFromString does the string
    # surgery and Set-RawPath the write. Splitting it that way keeps the rebuild in the one pure,
    # tested function instead of growing a third hand-rolled -join ';' in this file.
    $res = Remove-PathEntryFromString -Value $raw -Remove $drop
    Set-RawPath -Scope User -Value $res.Value
    Write-Ok "removed user PATH entry: $Path"
    Sync-EnvPath
}

# Remove an entry from the persistent MACHINE PATH. Returns a STATUS STRING, one of
# 'Removed' | 'NotPresent' | 'DryRun' | 'NeedsElevation', because the caller has to be able to
# tell "there was nothing to do" from "I was not allowed to do it".
#
# WHY THIS EXISTS. uninstall-toolbox.ps1:167-170 reversed the toolbox's PATH side effects by
# calling Remove-UserPathEntry for entries that consolidate-path.ps1 puts in HKLM, so the
# uninstaller could not undo its own change and still reported a clean run. That is not a
# theory: the two dead ...\DevToolbox\native\bin and ...\DevToolbox\sysinternals entries sitting
# in this box's machine PATH right now ARE that gap, left behind by the 2026-09-10 uninstall.
#
# IT MUST NOT SELF-ELEVATE, and that is a deliberate refusal rather than an omission. Every
# caller is mid-way through mutating HKCU and the filesystem, and UAC on a standard-user account
# accepts a DIFFERENT administrator's credentials - the elevated child's HKCU would then be that
# administrator's hive, so it would finish "successfully" having edited the wrong account and
# left this one exactly as broken. consolidate-path.ps1 carries the same warning at its
# -ElevatedFor parameter and guards it with a SID comparison, which is only possible because
# that script owns its whole run. A helper called from the middle of one does not.
# Unelevated, this writes NOTHING and says so; the caller reports the run INCOMPLETE.
function Remove-MachinePathEntry {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-RawPath -Scope Machine
    # EXPANDED TO COMPARE, RAW TO REMOVE - the same split Remove-UserPathEntry above makes, and
    # for the same reason. This function used to hand $Path straight to Remove-PathEntryFromString
    # and compare raw text to raw text, which cannot see that '%LOCALAPPDATA%\DevToolbox\native\bin'
    # and the expanded literal name one directory. Both callers derive their argument from an env
    # var as an absolute literal, so nothing misfires today; the failure it leaves open is a
    # hand-edited %VAR% machine entry the uninstaller reports as 'NotPresent' and walks away from,
    # having written nothing and warned about nothing - the silent-subset shape this file keeps
    # closing. Measured 2026-09-17 against a stubbed hive holding
    # '%LOCALAPPDATA%\DevToolbox\native\bin': the expanded argument returned NotPresent with 0
    # writes, while Remove-UserPathEntry handed the identical argument removed it.
    #
    # THE EXPANSION STOPS AT THE COMPARISON. $drop carries the untouched registry literals, so
    # Remove-PathEntryFromString still matches and re-emits verbatim - it deliberately does not
    # expand, and two tests assert that, because a value rebuilt from expansions is the REG_SZ
    # bug by another route. The fix belongs here, not in the string helper.
    $target = ([System.Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\')
    $drop = @(Split-PathList $raw | Where-Object {
        ([System.Environment]::ExpandEnvironmentVariables($_)).TrimEnd('\') -ieq $target
    })
    if ($drop.Count -eq 0) { return 'NotPresent' }
    $res = Remove-PathEntryFromString -Value $raw -Remove $drop
    if (@($res.Removed).Count -eq 0) { return 'NotPresent' }
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would remove machine PATH entry: $Path"
        return 'DryRun'
    }
    if (-not (Test-PathAdmin)) {
        Write-Warn "machine PATH entry NOT removed (needs elevation): $Path"
        return 'NeedsElevation'
    }
    # Set-RawPath, never [Environment]::SetEnvironmentVariable: 5 of this box's 43 machine
    # entries are %VAR%-based and the framework API silently rewrites the value as REG_SZ, after
    # which %SystemRoot%\system32 never expands again.
    Set-RawPath -Scope Machine -Value $res.Value
    Write-Ok "removed machine PATH entry: $Path"
    Sync-EnvPath
    return 'Removed'
}

# -- Timestamped backups -------------------------------------------------------
function Remove-StaleBackups {
    <#
        Keep the $Keep most recent "<FilePath>.bak-<yyyyMMdd-HHmmss>" siblings and delete the
        rest. Returns the paths it removed, so a caller can report instead of assume.

        ONE HELPER, THREE CALLERS. Three sites wrote that exact name and none of them ever
        deleted one: Remove-AgentBlocks and Write-AgentBlock below, and bootstrap.ps1's
        Remove-StaleAgentBlocks. Measured on this box 2026-09-17, before this function existed:
        32 files / 291 KB across %USERPROFILE%, %USERPROFILE%\.claude and %USERPROFILE%\.codex -
        10, 9 and 13 respectively - growing by up to 8 per non-dry-run bootstrap run. The agent
        files are ~7 KB each and the block is rewritten on every run whether or not it changed,
        so the growth is unbounded and almost entirely duplicates.

        KEEP = 3, AND THE REASON IS WHAT MAKES IT DEFENSIBLE. Each backup is the target file as
        it stood immediately before one idempotent rewrite of one fenced block. One copy is
        enough to undo the newest write; the second and third exist because a bad block can be
        deployed and only noticed a run or two later, which is exactly how the `$$><script.txt`
        corruption survived. Beyond that they are indistinguishable duplicates. Three per target
        bounds the four agent files at 12 files / ~84 KB instead of the 32 measured above.

        SORTED BY THE TIMESTAMP IN THE NAME, NEVER BY LastWriteTime, and that is measured rather
        than preferred. Copy-Item PRESERVES the source's LastWriteTime, so every backup here
        carries the mtime of the PREVIOUS write's content - probed 2026-09-17,
        CLAUDE.md.bak-20260917-150230 has mtime 20260911-131028, six days off. The name is the
        only field the writer actually stamped.

        THE TIMESTAMP SHAPE IS REQUIRED, not just the ".bak-" prefix. This box also holds
        hand-made backups named .bak-preSSEtune-20260724 and .bak-preWSfix-20260723 that a
        human made on purpose; a "<name>.bak-*" glob would be entitled to delete them the day
        one of these callers is pointed at that file. Anything not matching the writers' own
        format is left alone.

        NO-OP UNDER -DryRun, mirroring the guard Remove-AgentBlocks uses a few lines below: a
        run that promised to change nothing must not delete anything either.

        DEGRADED LOUDLY, never silently. A locked or vanished backup warns and the prune moves
        on - failing a bootstrap over a housekeeping delete would be the worse trade - but the
        warning is emitted, because a prune that quietly does nothing is indistinguishable from
        one that is not wired up.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [ValidateRange(1, 100)][int]$Keep = 3
    )
    $dir = Split-Path -Path $FilePath -Parent
    $leaf = Split-Path -Path $FilePath -Leaf
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }

    # -Filter is the provider's own wildcard, so a leaf containing [ ] does not have to be
    # escaped the way -Include would demand; the regex below is what actually decides.
    $candidates = @(Get-ChildItem -LiteralPath $dir -Filter "$leaf.bak-*" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.bak-\d{8}-\d{6}$' } |
        Sort-Object -Property Name -Descending)
    if ($candidates.Count -le $Keep) { return @() }

    $doomed = @($candidates | Select-Object -Skip $Keep)
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would prune $($doomed.Count) old backup(s) of $leaf, keeping the newest $Keep"
        return @()
    }
    $removed = @()
    foreach ($old in $doomed) {
        try {
            Remove-Item -LiteralPath $old.FullName -Force
            $removed += $old.FullName
        } catch {
            Write-Warn "could not prune old backup $($old.Name) ($($_.Exception.Message)); it will be retried next run"
        }
    }
    if ($removed.Count) { Write-Info "pruned $($removed.Count) old backup(s) of $leaf, kept the newest $Keep" }
    return $removed
}

# Strip fenced agent-discovery blocks (WIN_DEVTOOLS and/or legacy CODEX_TOOLBOX)
# from the standard agent files. Backs each file up before rewriting. Shared by
# the uninstaller and the legacy-cleanup path.
function Remove-AgentBlocks {
    param(
        [string[]]$Markers = @('WIN_DEVTOOLS', 'CODEX_TOOLBOX'),
        [string[]]$Files
    )
    if (-not $Files) {
        $Files = @(
            (Join-Path $env:USERPROFILE ".codex\AGENTS.md"),
            (Join-Path $env:USERPROFILE ".claude\CLAUDE.md"),
            (Join-Path $env:USERPROFILE "CLAUDE.md"),
            (Join-Path $env:USERPROFILE "AGENTS.md")
        )
    }
    $alt = ($Markers | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $pattern = "(?s)\r?\n?<!-- (?:$alt)_START -->.*?<!-- (?:$alt)_END -->\r?\n?"
    foreach ($file in $Files) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        $cleaned = $content -replace $pattern, ""
        if ($cleaned -eq $content) { continue }
        if ($script:DryRun) {
            Write-Info "[DRY-RUN] would remove agent block(s): $file"
            continue
        }
        $backup = "$file.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $file -Destination $backup -Force
        Set-Content -LiteralPath $file -Value $cleaned.Trim() -Encoding UTF8
        # AFTER the copy, never before: pruning first would keep $Keep - 1 old copies plus the
        # one about to be written, so the guaranteed depth would silently be one short.
        Remove-StaleBackups -FilePath $file | Out-Null
        Write-Ok "removed agent block(s): $file"
    }
}

# -- Winget --------------------------------------------------------------------
# Install a tool via winget, idempotently. Detection is by binary name first
# (fast path), then winget list (catches installs not on PATH yet).
function Install-WingetTool {
    param(
        [string]$Id,
        [string]$Binary,
        [string]$Name,
        [switch]$MachineScope,
        # Omit --scope entirely. A few manifests declare no scope at all, and
        # winget then rejects BOTH --scope user and --scope machine with
        # 0x8A150010 "No applicable installer found" (e.g. Podman.CLI, the WDK).
        # Without the flag winget picks the manifest's only installer, which for
        # Podman is a per-user MSI - so this stays PATH-clean and needs no UAC.
        [switch]$NoScope,
        # Pin winget to one installer when a manifest ships several and the default
        # is the wrong one. Microsoft.PowerShell is the case that forced this:
        # winget 7.6.0+ defaults it to the MSIX, which is single-user and sandboxes
        # $PSHOME, so 'wix' is required to get the MSI that CI runners actually use.
        # Left empty for every other tool, which keeps their behaviour unchanged.
        [string]$InstallerType = ""
    )
    if (Test-CommandAvailable $Binary) {
        Write-Skip "$Name already present ($Binary)"
        return $true
    }
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would: winget install --id $Id -e"
        return $true
    }
    Assert-WingetAvailable
    # Secondary check via winget list in case the binary isn't on PATH yet.
    # THROUGH Invoke-Native: this ran under bootstrap.ps1's 'Stop', where a redirected native
    # stderr is a terminating error. LATENT on measurement - `winget list` survived for both a
    # present and an absent package id, because winget answers on stdout - but the shape is the
    # banned one and the next winget release is not obliged to keep doing that.
    $listedR = Invoke-Native -FilePath 'winget' -Arguments @('list', '--id', $Id, '-e', '--accept-source-agreements')
    $listed = $listedR.Output
    if ($listedR.ExitCode -eq 0 -and ($listed -match [regex]::Escape($Id))) {
        Write-Skip "$Name installed (not yet on PATH - open a new shell)"
        Sync-EnvPath
        return $true
    }
    Write-Info "winget install $Id"
    $args = @(
        "install", "--id", $Id, "-e",
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--silent"
    )
    if ($InstallerType) {
        $args += @("--installer-type", $InstallerType)
    }
    if ($NoScope) {
        # Deliberately no --scope flag; see the parameter comment above.
    }
    elseif (-not $MachineScope) {
        # User scope keeps PATH changes in user scope and avoids elevation where supported.
        $args += @("--scope", "user")
    }
    # CAPTURED, not emitted. An unredirected native command inside a function writes to that
    # FUNCTION'S OUTPUT STREAM, so `return $false` below produced [<winget's stdout lines>,
    # $false] and the caller's `if (-not $ok)` guard silently stopped working - `-not` on a
    # multi-element array is $false. Measured: 3 elements returned, guard fires = False.
    #
    # That defeated the whole failure-propagation chain from the bottom: a run in which every
    # winget install failed still counted zero failures, printed "group complete", exited 0,
    # AND recorded each failed tool in the manifest as toolbox-installed, so a later
    # -RemoveWingetTools would try to uninstall packages that were never installed.
    #
    # Kept in a variable rather than sent to Out-Null so the diagnostics survive for the
    # failure branch, which is the only place they are worth reading.
    # THROUGH Invoke-Native. The 2>&1 here is load-bearing - the diagnostics are the whole point
    # of the failure branch below - so the redirection cannot be dropped; it has to happen
    # somewhere that has set 'Continue' first.
    #
    # This is the most-travelled install path in the repo and the one site of the six that was
    # NOT provoked either way: a failing winget INSTALL was not run on this box, and `winget
    # list` surviving says nothing about it, since the two subcommands need not use the same
    # stream. Unproven, not proven safe - which on the repo's most-travelled path is reason to
    # fix rather than reason to wait.
    $wingetR = Invoke-Native -FilePath 'winget' -Arguments $args
    $wingetOut = $wingetR.Output
    if ($wingetR.ExitCode -ne 0) {
        foreach ($line in @($wingetOut)) { Write-Host "    $line" -ForegroundColor DarkGray }
        Write-Err "$Name install failed via winget id $Id (exit $($wingetR.ExitCode))"
        return $false
    }
    Sync-EnvPath
    if (-not (Test-CommandAvailable $Binary)) {
        Write-Warn "$Name installed but '$Binary' is not visible on PATH in this session"
    }
    return $true
}

# -- Toolbox Python ------------------------------------------------------------
# Locate the dev toolbox Python executable. Respects CODEX_TOOLBOX env var;
# falls back to the known-good default path.
function Get-ToolboxPython {
    $root = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX }
            else { "$env:LOCALAPPDATA\DevToolbox" }
    $py = Join-Path $root "python\.venv\Scripts\python.exe"
    if (Test-Path $py) { return $py }
    return $null
}

# -- Smoke failure identity ----------------------------------------------------
# Collapse a smoke failure MESSAGE into a stable IDENTITY, so two gate runs can be compared by
# WHICH checks failed rather than by how many did.
#
# The phase ledger in run-gate.ps1 compares suite COUNTS and exempts the smoke triple from
# failing at all, deliberately: "on this box a rebuild step turns 18 missing tools into 18 OKs
# without a line of this repository changing", and a gate that punishes that becomes a gate
# nobody runs. The cost of that exemption is that smoke going 0 failures -> 5 failures prints a
# TRANSITION and passes. smoke-test.ps1:412 already records where that lands: two agents working
# in parallel worktrees "both fell back to 'the failure set is unchanged from baseline', which is
# far weaker" - by hand, because nothing computed it.
#
# This is that comparison, computed. Counts stay exempt; identities do not.
#
# DERIVED, NOT DECLARED. There are 63 Test-Fail call sites; making each one carry a hand-written
# -Id would be 63 edits to add a mechanism and 63 chances to forget one later. The identity comes
# from the message instead, with the parts that legitimately vary between runs masked:
#
#   %USERPROFILE% -> ~   so ~\CLAUDE.md and ~\.claude\CLAUDE.md stay DISTINCT (a leaf-name-only
#                        rule would alias those two into one, and they fail independently)
#   digits -> #          "121 of 145 line(s) differ" and "6 self-referential shim(s)" must not
#                        mint a new identity every time a count moves
#   space, comma -> _    the ledger line is space-delimited and these are comma-joined into one
#                        field; an id containing either would corrupt the row it is written to
#
# The 6-hex tail is a digest of the FULL normalised string, not of the truncated head. Without
# it, two failures sharing a 48-character prefix would alias into one identity and a real
# regression could arrive wearing a known id. With it the head stays readable in the ledger and
# the tail carries the distinctness.
function ConvertTo-SmokeFailureId {
    param([Parameter(Mandatory)][string]$Message)

    $s = $Message
    if ($env:USERPROFILE) { $s = $s -replace [regex]::Escape($env:USERPROFILE), '~' }
    $s = $s -replace '\d+', '#'
    $s = ($s -replace '\s+', ' ').Trim().ToLowerInvariant()
    $s = $s -replace '[,\s]', '_'

    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
    } finally { $sha.Dispose() }
    $tail = -join (@($hash[0..2]) | ForEach-Object { '{0:x2}' -f $_ })

    $head = if ($s.Length -gt 48) { $s.Substring(0, 48) } else { $s }
    return ('{0}-{1}' -f $head, $tail)
}

# -- Packaged-host path projection ---------------------------------------------
# Is THIS process seeing the toolbox through an MSIX package's redirected view?
#
# An agent host installed as an MSIX package gets %LOCALAPPDATA% and %APPDATA% projected into
# its own Packages\<pkg>\LocalCache\ tree, and every process it launches inherits that view -
# including a plain powershell.exe with no package identity of its own. The files are the same
# files: one hardlink name, same bytes, same size. What differs is which NAME the filesystem
# reports as canonical, and it differs asymmetrically - a FILE resolves to the package name
# while its PARENT DIRECTORY resolves to the unredirected one.
#
# That asymmetry breaks pip outright. distlib 0.4.2's ResourceFinder._is_in_base compares
# realpath(package dir) with realpath(resource) using startswith, so under a projected view
# EVERY resource lookup raises "Resource name escapes package" and `pip install` cannot run at
# all - which stopped scripts\build-devtoolbox.ps1 in its python phase on 2026-09-21, four
# phases before it would have repaired a single shim.
#
# HOST-AGNOSTIC BY CONSTRUCTION. The pattern below matches \Packages\<anything>\LocalCache\, not
# a vendor or a package family name. Claude Desktop is simply the host that happened to spawn
# the shell where this was measured; a Codex, Cursor or VS Code build packaged as MSIX projects
# the same way and breaks pip identically. Do not narrow this to a known package id.
#
# NOT detectable by the obvious routes, all three measured and ruled out on 2026-09-21: there is
# NO reparse point on any component of either path, the shell has NO package identity
# (GetCurrentPackageFullName returns APPMODEL_ERROR_NO_PACKAGE), and the two paths are not
# separate hardlinks - fsutil reports exactly ONE name, and it is the package one. Hence asking
# the filesystem for that one name rather than testing for a link.
$script:ProjectedViewPattern = '\\Packages\\[^\\]+\\LocalCache\\'

function Test-HostPathProjection {
    <#
        Returns an object describing whether $Path is reached through a projected view:

            IsProjected   $true / $false, or $null when it could not be measured
            Probe         the path actually measured
            Canonical     the name the filesystem reports for it
            PackageRoot   the ...\Packages\<pkg>\ prefix responsible, when projected
            Reason        why, in one sentence, for a caller that wants to print it

        $null IsProjected is deliberately NOT $false: "I could not tell" and "it is fine" must
        not read the same to a caller deciding whether to run a build.
    #>
    param([string]$Path = "")

    $probe = $Path
    if (-not $probe) { $probe = Get-ToolboxPython }
    if (-not $probe) {
        $root = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
        $probe = $root
    }
    if (-not $probe -or -not (Test-Path -LiteralPath $probe)) {
        return [pscustomobject]@{
            IsProjected = $null; Probe = $probe; Canonical = $null; PackageRoot = $null
            Reason = "nothing to measure: '$probe' does not exist"
        }
    }

    # fsutil, not Get-Item.Target: there is no reparse point to follow, and .Target is $null
    # here. `hardlink list` is the cheapest call that reports the name the volume actually
    # holds, and it needs no elevation. Through Invoke-Native because this file is dot-sourced
    # by callers that set $ErrorActionPreference='Stop', under which a redirected native call
    # raises NativeCommandError - see that wrapper's header.
    $fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
    if (-not (Test-Path -LiteralPath $fsutil)) {
        return [pscustomobject]@{
            IsProjected = $null; Probe = $probe; Canonical = $null; PackageRoot = $null
            Reason = 'fsutil.exe not found, so the canonical name cannot be read'
        }
    }

    $r = Invoke-Native -FilePath $fsutil -Arguments @('hardlink', 'list', $probe)
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{
            IsProjected = $null; Probe = $probe; Canonical = $null; PackageRoot = $null
            Reason = "fsutil hardlink list exited $($r.ExitCode)"
        }
    }

    $canonical = @($r.Output | ForEach-Object { [string]$_ } |
        Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }) |
        Select-Object -First 1

    if (-not $canonical) {
        return [pscustomobject]@{
            IsProjected = $null; Probe = $probe; Canonical = $null; PackageRoot = $null
            Reason = 'fsutil returned no name'
        }
    }

    # Projected when the volume's own name for the file sits under a package LocalCache but the
    # path we reached it by does not. Both halves matter: a caller that deliberately addressed
    # the LocalCache path is NOT projected - it asked for exactly what it got, and pip works
    # there precisely because both realpath calls then agree.
    $canonHit = $canonical -match $script:ProjectedViewPattern
    $probeHit = $probe -match $script:ProjectedViewPattern
    $packageRoot = $null
    if ($canonHit -and -not $probeHit) {
        if ($canonical -match '^(.*\\Packages\\[^\\]+)\\LocalCache\\') { $packageRoot = $Matches[1] }
        return [pscustomobject]@{
            IsProjected = $true; Probe = $probe; Canonical = $canonical; PackageRoot = $packageRoot
            Reason = "the filesystem's only name for this file is under $packageRoot, so realpath of a file and of its parent directory disagree and pip cannot install"
        }
    }

    return [pscustomobject]@{
        IsProjected = $false; Probe = $probe; Canonical = $canonical; PackageRoot = $null
        Reason = 'the canonical name matches the path used to reach it'
    }
}

function Set-NodeSystemCaBundle {
    # Make node/npm trust the OS certificate store so 'npm install' works behind
    # corporate TLS interception. node ships its own CA bundle and ignores the
    # Windows trust store, so on a machine whose proxy presents a corporate root
    # CA (trusted by Windows but not by node) npm's HTTPS to the registry fails or
    # hangs. We export the Windows trusted roots to a PEM bundle under the toolbox
    # and point NODE_EXTRA_CA_CERTS at it (node ADDS these to its defaults). This
    # auto-discovers the corporate CA - no need to locate a .cer by hand.
    # Idempotent. NOTE: only fixes cert-TRUST; if the registry is proxy-blocked or
    # requires an authenticated proxy, npm also needs HTTP(S)_PROXY / npm proxy config.
    $root = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
    $dir = Join-Path $root "certs"
    $bundle = Join-Path $dir "windows-roots.pem"
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would export Windows root CAs -> $bundle and set NODE_EXTRA_CA_CERTS"
        return
    }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $seen  = @{}
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($store in @('Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root')) {
        foreach ($c in (Get-ChildItem $store -ErrorAction SilentlyContinue)) {
            if ($seen.ContainsKey($c.Thumbprint)) { continue }
            $seen[$c.Thumbprint] = $true
            $lines.Add("# " + $c.Subject)
            $lines.Add("-----BEGIN CERTIFICATE-----")
            $lines.Add([Convert]::ToBase64String($c.RawData, [System.Base64FormattingOptions]::InsertLineBreaks))
            $lines.Add("-----END CERTIFICATE-----")
        }
    }
    if ($seen.Count -eq 0) {
        Write-Warn "no trusted root CAs found to export - skipping NODE_EXTRA_CA_CERTS"
        return
    }
    Set-Content -LiteralPath $bundle -Value $lines -Encoding ASCII
    $cur = [string][System.Environment]::GetEnvironmentVariable('NODE_EXTRA_CA_CERTS', 'User')
    if ($cur -ne $bundle) {
        [System.Environment]::SetEnvironmentVariable('NODE_EXTRA_CA_CERTS', $bundle, 'User')
        Write-Ok "NODE_EXTRA_CA_CERTS -> $bundle ($($seen.Count) roots)"
    }
    $env:NODE_EXTRA_CA_CERTS = $bundle
}

# Wrap the toolbox venv's console-script executables into native\bin so the venv
# CLIs (frida, jupyter-lab, sqlite-utils, csvkit, playwright, ...) are callable by
# name from any shell WITHOUT putting the venv Scripts dir on the persistent PATH.
# That dir also holds python.exe, and exposing a 3.11 interpreter on PATH is what
# trips corporate "old Python" compliance scanners - so the interpreter stays off
# PATH (reachable via $env:TOOLBOX_PYTHON) and only the CLIs are wrapped. The
# python*/pythonw*/pip* launchers are deliberately excluded.
function New-VenvCliWrappers {
    $root = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
    $venvScripts = Join-Path $root "python\.venv\Scripts"
    $binDir = Join-Path $root "native\bin"
    if (-not (Test-Path $venvScripts)) { return }
    if (-not (Test-Path $binDir)) {
        if ($script:DryRun) { Write-Info "[DRY-RUN] would create $binDir for venv CLI wrappers"; return }
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }
    $skip = '^(python|pythonw|pip|pipx)([0-9.]*)?$'
    foreach ($exe in Get-ChildItem -LiteralPath $venvScripts -Filter *.exe -ErrorAction SilentlyContinue) {
        if ($exe.BaseName -match $skip) { continue }
        if ($script:DryRun) { Write-Info "[DRY-RUN] would wrap venv CLI: $($exe.BaseName)"; continue }
        # New-ShimBody (lib\ShimFormat.ps1) rather than a seventh inline copy of the byte shape.
        # This writer produced the right bytes; it produced them from its own private literal,
        # which is how the six copies drifted apart in the first place.
        #
        # -NoNewline IS LOAD-BEARING, and the pairing is the opposite of the obvious one. Measured
        # under 5.1: the old inline string had NO trailing CRLF and Set-Content appended one, for
        # 28 bytes. New-ShimBody supplies that CRLF itself, so keeping the bare Set-Content would
        # emit 30 bytes with a blank third line - readable by every reader, and a silent change to
        # bytes this repo pins deliberately. Same call shape as lib\ShimPlan.ps1:547.
        #
        # -LiteralPath, not -Path: a venv console script is free to contain '[', and -Path would
        # treat it as a wildcard and silently write nothing at all.
        New-ShimBody -Target $exe.FullName |
            Set-Content -LiteralPath (Join-Path $binDir "$($exe.BaseName).cmd") -Encoding ASCII -NoNewline
    }
}

# Install a package into the dev toolbox venv, idempotently.
# $ImportName: the Python import name to test (defaults to $Package if omitted).
function Install-PipToolbox {
    param(
        [string]$Package,
        [string]$ImportName = ""
    )
    $py = Get-ToolboxPython
    if (-not $py) {
        Write-Warn "Toolbox Python not found - skipping $Package (set CODEX_TOOLBOX or run scripts/build-devtoolbox.ps1)"
        return $false
    }
    $check = if ($ImportName) { $ImportName } else { ($Package -split '\[')[0] -replace '-','_' }
    # Probe with find_spec on a single line and DO NOT redirect stderr. A missing
    # module makes find_spec return None, so we exit 1 while emitting nothing. A bare
    # `import` writes a traceback to stderr, and *redirecting* native stderr (2>&1 OR
    # 2>$null) under $ErrorActionPreference='Stop' makes PowerShell 5.1 raise a
    # terminating NativeCommandError that aborts the whole run.
    & $py -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$check') else 1)"
    if ($LASTEXITCODE -eq 0) {
        Write-Skip "$Package already in toolbox venv"
        return $true
    }
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would: pip install $Package (toolbox venv)"
        return $true
    }
    Write-Info "pip install $Package (toolbox venv)"
    & $py -m pip install $Package --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$Package install failed in toolbox venv (exit $LASTEXITCODE)"
        return $false
    }
    return $true
}

# -- npm global ----------------------------------------------------------------
function Install-NpmGlobal {
    param(
        [string]$Package,
        [string]$Binary = ""
    )
    $bin = if ($Binary) { $Binary } else { $Package }
    if (Test-CommandAvailable $bin) {
        Write-Skip "$Package already installed globally ($bin)"
        return $true
    }
    if (-not (Test-CommandAvailable 'npm')) {
        Write-Warn "npm not found - skipping $Package"
        return $false
    }
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would: npm install -g $Package"
        return $true
    }
    Write-Info "npm install -g $Package"
    # Bound the attempt: corporate TLS interception can make node's HTTPS to the
    # npm registry hang far past a sane wait (a TCP connect to the proxy succeeds
    # but the fetch stalls). These flags fail fast (~1-2 min) instead of wedging
    # the whole run; a failure is non-fatal here (returns $false, caller warns).
    # Captured for the same reason as winget above: unredirected, npm's stdout becomes part
    # of this function's return value and the caller's boolean guard stops working.
    # THROUGH Invoke-Native, and npm is the one site of the six CONFIRMED to throw rather than
    # merely being the banned shape. Measured 2026-09-11 under 'Stop': `npm view <absent> 2>&1`
    # THREW [RemoteException], while the winget and fsutil probes all survived because those two
    # answer on stdout. npm is the family member that really does use stderr, which makes this
    # line an active defect on every npm failure path and not a precaution.
    $npmR = Invoke-Native -FilePath 'npm' -Arguments @(
        'install', '-g', $Package, '--no-audit', '--no-fund',
        '--fetch-timeout=60000', '--fetch-retries=1', '--fetch-retry-maxtimeout=20000')
    $npmOut = $npmR.Output
    if ($npmR.ExitCode -ne 0) {
        foreach ($line in @($npmOut)) { Write-Host "    $line" -ForegroundColor DarkGray }
        Write-Err "$Package npm install failed or timed out (exit $($npmR.ExitCode))"
        return $false
    }
    # npm's global prefix (e.g. %APPDATA%\npm) is where -g CLIs land, but a
    # machine-scope Node install does not add it to PATH - register it (user
    # scope) so npm-global tools resolve by name.
    # Through the wrapper too. A bare pipe does not promote stderr on its own, but an ENCLOSING
    # 2>&1 - which any log-capturing parent applies - makes PowerShell redirect this command's
    # stderr as well, and then it throws like the rest. Latent rather than live, fixed anyway
    # because the next reader cannot tell the two shapes apart by looking.
    $npmPrefixR = Invoke-Native -FilePath 'npm' -Arguments @('config', 'get', 'prefix')
    $npmPrefix = @($npmPrefixR.Output | Select-Object -First 1)[0]
    if ($npmPrefix -and (Test-Path $npmPrefix)) { Add-UserPathEntry $npmPrefix | Out-Null }
    Sync-EnvPath
    return (Test-CommandAvailable $bin)
}

# -- Manifest ------------------------------------------------------------------
# Upsert a tool entry into the Windows manifest JSON (parallel to Linux tools.json).
function Add-WinManifest {
    param(
        [string]$Name,
        [string]$Binary,
        [string]$Group,
        [string]$Method,      # winget | pip-toolbox | npm-global
        [string]$Detect,
        [string]$Scope = "user",
        [string]$WingetId = "",
        [string]$Notes    = "",
        # Provenance: $false if the tool pre-existed. Every caller that can tell the
        # difference MUST pass this - the default is the optimistic answer, and the
        # uninstaller acts on it.
        [bool]$InstalledByToolbox = $true
    )
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would manifest_add $Name"
        return
    }
    $manifestPath = $script:MANIFEST
    $dir = Split-Path $manifestPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $entries = @()
    if (Test-Path $manifestPath) {
        $loaded = Get-Content $manifestPath -Raw | ConvertFrom-Json
        if ($loaded) {
            $entries = @($loaded)
        }
    }

    # PROVENANCE IS STICKY: it is a fact about who installed the tool, not about what
    # the machine looks like right now. Every caller establishes it by probing before
    # installing - which means on the SECOND bootstrap run the tool is already there
    # and the probe says "pre-existing" about something the toolbox itself installed.
    # Left alone, a re-run would quietly disown every tool and uninstall-toolbox.ps1
    # -RemoveWingetTools would then leave all of them behind. So false -> true is a
    # measurement we accept, and true -> false is one we refuse.
    $wasOurs = $false
    foreach ($prev in $entries) {
        if (($prev.name -eq $Name) -and
            ($prev.PSObject.Properties.Name -contains 'installed_by_toolbox') -and
            $prev.installed_by_toolbox) { $wasOurs = $true; break }
    }
    $ours = $InstalledByToolbox -or $wasOurs

    # No version probe here. This used to Invoke-Expression $Detect for every tool
    # just to scrape a version number into installed_version - which nothing in this
    # repo, the smoke test, the uninstaller or the GUI has ever read. It cost a
    # process launch per tool on every bootstrap (and it launched them under
    # Invoke-Expression, from a string in catalog.json). The same is true of
    # last_verified and of status, which was the literal "core" on every entry and so
    # measured nothing. `detect` stays: it is the recipe, and it IS read.
    #
    # `group` and `notes` ALSO have no code reader, and they stay anyway. An audit on 2026-09-11
    # flagged them as the same class and it was right about the facts and wrong about the test:
    # smoke-test.ps1 and toolbox-gui.ps1 read those fields off the CATALOG object, never off this
    # file. But this file's intended reader is not code. The agent-discovery block this same
    # library generates tells every agent on the machine "Check the Windows manifest first - the
    # tool may already be present: Get-Content manifest	ools.json", and `notes` is the field that
    # answers "what is this for" for whoever is deciding whether they already have the tool.
    # Removing them would cost nothing measurable - unlike installed_version, which bought a
    # process launch per tool - and would strip the content from the one file we ask agents to
    # consult. Kept deliberately; do not re-flag.
    $entry = [ordered]@{
        name              = $Name
        binary            = $Binary
        group             = $Group
        scope             = $Scope
        install_method    = $Method
        detect            = $Detect
        notes             = $Notes
        winget_id         = $WingetId
        installed_by_toolbox = $ours
    }

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($existing in $entries) {
        $list.Add($existing)
    }
    $idx  = $list.FindIndex({ param($e) $e.name -eq $Name })
    if ($idx -ge 0) { $list[$idx] = $entry } else { $list.Add($entry) }

    $list | ConvertTo-Json -Depth 4 | Set-Content $manifestPath -Encoding UTF8
}

# -- Agent discovery -----------------------------------------------------------
# Write a fenced discovery block into a file. Idempotent: replaces the block if
# the marker is already present, appends otherwise. Backs up the file first.
function Write-AgentBlock {
    param(
        [string]$FilePath,
        [string]$Marker,
        [string]$Body
    )
    $start = "<!-- ${Marker}_START -->"
    $end   = "<!-- ${Marker}_END -->"
    $dir   = Split-Path $FilePath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $FilePath)) { Set-Content $FilePath "" -Encoding UTF8 }

    $content = Get-Content $FilePath -Raw -Encoding UTF8
    $block = "$start`n$Body`n$end"
    # SPLICED BY INDEX, NOT -replace. The replacement side of -replace is a .NET regex
    # SUBSTITUTION string, so every $-sequence in the body was interpreted on its way to disk:
    #   $$  -> a single literal $        $&  -> the whole match
    #   $1  -> capture group 1, and this pattern has NO groups, so it expanded to nothing
    # The body documents a cdb invocation, `cdb -c ".logopen out.txt; $$><script.txt; q"`, and
    # every deploy silently wrote `$><script.txt` - a DIFFERENT and wrong cdb command - into all
    # four agent files. The generator was correct in memory the whole time; the writer corrupted
    # it, which is why this survived a year of the text being read and re-read.
    #
    # Found on 2026-09-11 by the new deployed-vs-generated check: bootstrap rewrote all four
    # blocks and the drift went from 26 of 119 lines to exactly 1 - the same line - which is the
    # signature of a lossy WRITE rather than a stale file. A round-trip test now pins it.
    #
    # IndexOf/Substring has no substitution semantics at all, which is the point: there is no
    # escaping convention here to get wrong a second time.
    $iStart = $content.IndexOf($start, [System.StringComparison]::Ordinal)
    if ($iStart -ge 0) {
        $iEnd = $content.IndexOf($end, $iStart, [System.StringComparison]::Ordinal)
        if ($iEnd -lt 0) {
            throw ("$FilePath has a $start marker with no matching $end - refusing to guess where " +
                   "the block ends. Remove the stray marker by hand and re-run.")
        }
        $content = $content.Substring(0, $iStart) + $block + $content.Substring($iEnd + $end.Length)
    } else {
        $content = $content.TrimEnd() + "`n`n$block`n"
    }
    $backup = "$FilePath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if (Test-Path $FilePath) { Copy-Item $FilePath $backup -Force }
    Set-Content $FilePath $content -Encoding UTF8
    # THE PRUNE LIVES HERE, not in Write-AgentDiscovery, and that is a hard constraint rather
    # than a preference. lib\AgentDiscovery.ps1 extracts Write-AgentDiscovery's body by
    # EVALUATING its assignment statements, and refuses any that call a command outside
    # $script:ADAllowedCommands = @('Join-Path'). A prune call added up there would make the
    # extractor refuse, and smoke-test.ps1's deployed-vs-generated check - the one that caught
    # the $$><script.txt corruption - would report "could not reach the generator" instead.
    # Here it is invisible to the extractor and still covers all four agent files.
    Remove-StaleBackups -FilePath $FilePath | Out-Null
    Write-Ok "agent block [$Marker] -> $FilePath"
}

function Write-AgentDiscovery {
    param([string]$RepoRoot)
    $manifestPath  = Join-Path $RepoRoot "manifest\tools.json"
    $toolboxRoot   = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX }
                     else { "$env:LOCALAPPDATA\DevToolbox" }
    $toolboxManifest = Join-Path $toolboxRoot "toolbox-manifest.json"

    $body = @"
## Windows dev toolbox - scripts-utilities

This machine has a curated cross-platform developer toolbox.
Managed by: $RepoRoot

### Before installing any tool

Check the Windows manifest first - the tool may already be present:
  Get-Content '$manifestPath' | ConvertFrom-Json

Install rules (channels, PATH hygiene, add-a-tool workflow):
  $RepoRoot\docs\agent-rules.md

Full usage guide (HOW to use each tool):
  $RepoRoot\docs\tools-reference.md

### Python + native CLI toolbox

Toolbox root: $toolboxRoot
Manifest:     $toolboxManifest
On PATH:      bootstrap.ps1 adds native\bin (native CLIs + wrapped venv CLIs)
              and sysinternals to your user PATH, so every tool below is
              available by name in any new shell - no activation needed.
Not found?    Check the registry PATH before concluding a tool is missing, and
              do NOT install it again. A long-running agent host caches its
              environment at launch, so anything added to PATH afterwards is
              invisible to every shell it spawns - including the toolbox itself.
              Refreshing PATH fixes one invocation and does not carry to the next
              tool call. Durable fix: restart the agent host (a reboot is not
              needed). See the "When a tool is missing from PATH" section of
              $RepoRoot\docs\agent-rules.md.
Python 3.11:  the toolbox venv interpreter is deliberately NOT on PATH - a bare
              'python' stays your sanctioned system version. Call the toolbox
              Python explicitly via %TOOLBOX_PYTHON% (=
              $toolboxRoot\python\.venv\Scripts\python.exe) when you need the
              toolbox libraries. Its CLIs (frida, jupyter-lab, sqlite-utils,
              csvkit, ...) are wrapped into native\bin, so they run by name.

Toolbox provides: Python 3.11 venv, document/PDF/OCR/image/GPU libs, and
native CLI tools: ffmpeg, ffprobe, ImageMagick, Pandoc, tesseract, poppler,
qpdf, ghostscript, LibreOffice, 7z, rg, fd, jq, yq, exiftool, aria2c, rclone,
DuckDB, Node.js, uv/uvx. Sysinternals (procdump, handle, sigcheck, ...) is on
PATH too. Set CODEX_TOOLBOX to override the toolbox root path.

### Reading web pages (including sites that block agents)

  browse      The web-read command: browse <url> [--json]. It ESCALATES ON ITS
              OWN - httpx first, then the real Chrome over CDP - and remembers
              per host which rung worked. Do not hand-drive Playwright for this:
              that is rung 3 and it is reached automatically.
              Site blocks you? Run this once, leave it open for the session:
                $RepoRoot\scripts\start-browse-chrome.ps1
              It uses a DEDICATED profile and refuses Chrome's default one,
              which Chrome 136+ silently opens no debug port for. Measured
              2026-09-17: a real Chrome clears Cloudflare's managed challenge
              by itself, so 3 of 8 targets that answered httpx with a 403 read
              fine through that rung.
              Exit 3 = refused. Ask the user to clear the challenge in that
              browser window; never retry in a loop. Exit 4 = robots.txt said
              no. Exit 5 = the site charges for machine access; no bypass.
              If your host's own web-fetch tool fails on a site, that may not
              be fixable from here: most agent fetchers are not Cloudflare
              signed agents and their user-agent is not configurable.
              Use browse instead.
              Install: $RepoRoot\scripts\install-browse.ps1
              Rules, exit codes, measurements: $RepoRoot\docs\agent-rules.md
              FROM A POSIX-SHELL TOOL CALL a .cmd shim needs its extension -
              browse.cmd, ffmpeg.cmd - because Git Bash and similar POSIX
              shells append .exe and not .cmd when searching PATH. From
              PowerShell the bare name works.
              True of every wrapped tool in native\bin, not just this one.

### Developer CLI tools - on PATH (winget; user scope unless noted)

  pwsh        PowerShell 7, MACHINE scope at %ProgramFiles%\PowerShell\7, side by
              side with 5.1 (powershell.exe is untouched and still the default).
              CI almost always runs 'shell: pwsh', so run a build or gate under
              pwsh before trusting that CI agrees with your terminal:
                pwsh -NoProfile -File .\build.ps1
              Divergences that bite: && || ?? ?. and ternary are PS7-only (parse
              errors under 5.1); Get-WmiObject / -Encoding Byte were REMOVED in 7
              (green locally, broken in CI); Set-Content defaults to ANSI on 5.1
              and UTF-8 no BOM on 7, so always pass -Encoding explicitly.
  gh          GitHub operations: gh pr list / gh issue create / gh repo clone
              In a fork, gh resolves to UPSTREAM - pass -R owner/repo explicitly.
  fzf         Fuzzy select from a list: pipe to fzf; --filter for scripts
  bat         Syntax-highlighted file view: bat <file> (replaces type/cat)
  delta       Git diff pager: set via git config core.pager delta
  just        Task runner: just <recipe> (reads justfile in current dir)
  hyperfine   Benchmark: hyperfine "cmd1" "cmd2" to compare timing
  sops        Encrypted secrets: sops --encrypt --age <pubkey> file.yaml
  age         File encryption: age-keygen for keys; age -r <pubkey> -o out.age
  tokei       LOC stats: tokei [path] for a language breakdown
  yt-dlp      Download video/audio (1000+ sites): yt-dlp <url>; -x audio-only,
              -F list formats. Uses toolbox ffmpeg to merge/transcode; YouTube
              nsig/PO-token challenges solved via bundled EJS scripts + the deno
              runtime (auto-detected on PATH).
  deno        Secure JS/TS runtime; also yt-dlp's default JS challenge runtime.
              deno run script.ts | deno repl | deno fmt
  tshark      Read/analyze captures: tshark -r cap.pcapng -Y "tcp.flags.reset==1"
              Live capture (tshark -i) needs Npcap (no winget pkg; optional).
  etl2pcapng  Convert built-in pktmon/netsh .etl -> .pcapng for tshark
              (driver-free capture: pktmon -> etl2pcapng -> tshark; no Npcap)

### Security / RE tools

  Ghidra      Optional portable RE suite. Provision with:
              $RepoRoot\scripts\install-ghidra.ps1
              Then use ghidraRun or analyzeHeadless from the toolbox PATH.
  frida       Dynamic instrumentation (toolbox venv; on PATH after bootstrap):
              frida -n notepad.exe -l hook.js
  WinDbg      Windows crash-dump / live user+kernel debugger (GUI):
              windbg -z crash.dmp -c "!analyze -v"
              Symbols preconfigured via _NT_SYMBOL_PATH (MS public server + local cache)
  cdb/kd/ntsd Scriptable console debuggers (Windows SDK, Debugging Tools for Windows):
              cdb -z dump.dmp -c ".logopen out.txt; `$`$><script.txt; q"
              kd -z kernel.dmp -c "!analyze -v; q"  (kernel dumps)
              Activated by: bootstrap.ps1 -Only security (after WDK or SDK install)
  poolmon     Live kernel pool-tag monitor (WDK, run elevated):
              poolmon /b /r /n snapshot.txt  (top nonpaged consumers)
              Installed by: install-machine-scope.ps1 + bootstrap.ps1 -Only security
  Sysmon      Deletion forensics - WHICH PROCESS deleted a file. Optional; provision with
              $RepoRoot\scripts\install-deletion-forensics.ps1  (-Verify to health-check).
              Uses event 26 FileDeleteDetected, never event 23, which archives a copy of
              every deleted file and would fill the disk.
              THE LOG IS ADMIN-ONLY TO READ. An unelevated Get-WinEvent returns
              "unauthorized", which is easy to misread as an empty log. Query elevated:
                Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Sysmon/Operational'; Id=26}
              A mass deletion appears as a BURST of event 26 sharing one Image and
              ProcessGuid - Sysmon fires per file, not per directory.
              Paired with a 2 GB USN journal (fsutil usn queryjournal C:), which records
              what/when with no agent and survives Sysmon being stopped. Both are checked by
              scripts\smoke-test.ps1, because a sensor nobody verifies stops working quietly.

### Local LLM stack (optional - only if installed via scripts\install-llm.ps1)

If present, a local Ollama runtime serves an OpenAI-compatible API entirely on
this machine (nothing leaves the box). Discover it via %TOOLBOX_LLM_URL% (=
http://127.0.0.1:11434/v1); models live in $toolboxRoot\models. Point any
OpenAI-compatible client at that base URL for offline / sensitive RAG and
inference. CLI: ollama run <model> / ollama list. Default models are
VRAM-tiered (moondream vision,
qwen2.5:3b + mistral:7b text, qwen3-embedding:0.6b embeddings; mistral-small on
24 GB+). A cross-encoder reranker (run via the toolbox Python + onnxruntime) may
be provisioned at $toolboxRoot\scripts\rerank.py. Not installed unless the user
opted in; check 'ollama --version' and %TOOLBOX_LLM_URL% before assuming it.

Smoke test: powershell.exe -ExecutionPolicy Bypass -File '$RepoRoot\scripts\smoke-test.ps1'
"@

    # %USERPROFILE%\CLAUDE.md - picked up via directory walk-up from any path
    # under the user profile (C:\Users\you\...).
    Write-AgentBlock "$env:USERPROFILE\CLAUDE.md"             "WIN_DEVTOOLS" $body

    # %USERPROFILE%\.claude\CLAUDE.md - Claude Code's global config; loaded
    # unconditionally regardless of working directory. Covers D:\, network
    # paths, \\wsl.localhost\..., and any other path outside the profile tree.
    Write-AgentBlock "$env:USERPROFILE\.claude\CLAUDE.md"     "WIN_DEVTOOLS" $body

    Write-AgentBlock "$env:USERPROFILE\AGENTS.md"             "WIN_DEVTOOLS" $body
    $codexAgents = "$env:USERPROFILE\.codex\AGENTS.md"
    Write-AgentBlock $codexAgents "WIN_DEVTOOLS" $body
}
