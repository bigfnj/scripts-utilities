<#
.SYNOPSIS
  Collapse winget package directories into native\bin shims, REBUILD those shims after the
  toolbox directory is lost, and put the toolbox on the MACHINE PATH so tools stay visible to
  shells that do not inherit the user PATH.

.DESCRIPTION
  Fixes three independent failures that all make toolbox tools "not found" in an agent shell.

  1. WINDOWS TRUNCATES A LONG PATH. Measured on the reference box: machine PATH 4363 chars, but
     the spawned shell received exactly 4095 and the final entry was chopped mid-string
     ("C:\Users\Admin\AppD"). Everything past the 4 KB boundary is silently gone. Nothing is
     misconfigured; the PATH is simply longer than the buffer that carries it.

     27 winget package directories accounted for 3380 of 5264 total chars, because winget
     registers the full package folder - complete with its
     "_Microsoft.Winget.Source_8wekyb3d8bbwe" suffix and a version-stamped subfolder - rather
     than a shim. WinGet's own Links directory exists but is empty for portable packages.

  2. SOME SHELLS INHERIT THE MACHINE PATH ONLY. The user PATH is then invisible, which is exactly
     where a non-elevated toolbox install puts native\bin and sysinternals. The toolbox tells
     agents those tools are on PATH; in such a shell they are not.

  3. CONSOLIDATION MADE THE SHIMS A SINGLE POINT OF FAILURE, AND ON 2026-09-10 IT FAILED.
     %LOCALAPPDATA%\DevToolbox was deleted. native\bin held the only PATH route to all 27
     packages, because step 1 had taken their own directories OFF the PATH in favour of the
     shims. The packages were untouched on disk; the shims were gone; neither hive mentioned
     WinGet\Packages any more. This script could not rebuild them - discovery was two lines
     filtering the CURRENT PATH, with no filesystem enumeration anywhere in the file, so on a
     correctly-consolidated box it found ZERO candidates and then fell through into the PATH
     rewrite anyway. bootstrap.ps1 could not help either: Install-WingetTool treats "winget list
     knows the id" as success and writes no shim, and path_fallback is wired only for the
     winget-machine and winget-default channels (lib\catalog.ps1:85, :95) while no winget-user
     entry declares one. gh, fzf, bat, delta, just, hyperfine, sops, age, tokei, trurl, yt-dlp,
     deno and etl2pcapng had no recovery route at all. -RebuildShims is that route.

  The fix for 1 and 2 is this repo's own pattern, applied one level out. build-devtoolbox.ps1
  already wraps venv CLIs into native\bin so one PATH entry serves many tools. This does the
  same for winget portables, then registers native\bin and sysinternals machine-wide.

  MODES
    (default)      collapse the WinGet\Packages entries currently on PATH into shims, then move
                   native\bin + sysinternals to the machine scope. Writes both PATH values.
    -RebuildShims  walk %LOCALAPPDATA%\Microsoft\WinGet\Packages and rebuild the shims.
    -FromBackup    same, but rank contested names from a logs\path-backup-*.json's PATH order.
    -Prune         remove the ratified duplicate/shadowed PATH entries in config\path-hygiene.json.
    -Restore       put both PATH values back from a backup, verbatim.

  Either rebuild flag means REBUILD ONLY: no PATH entry is dropped, no PATH value is written and
  no UAC prompt is raised. That is not a convenience - the machine PATH already carries
  native\bin, so refilling the directory restores resolution with zero registry writes.

  SAFETY. Both PATH values are written to a timestamped JSON backup before any change, and
  -Restore puts them back verbatim. The registry value kind (REG_EXPAND_SZ) is preserved by
  writing the key directly: [Environment]::SetEnvironmentVariable silently rewrites it as REG_SZ,
  which would break any %VAR% entry a future PATH picks up. Both live in lib\path-registry.ps1
  now, where they can be tested.

  ELEVATION IS NOT OPTIONAL WHEN THE PATH CHANGES - THIS ALREADY DESTROYED A PATH. The default
  plan MOVES native\bin and sysinternals from the user PATH to the machine PATH, so the two
  registry writes are two halves of one change and neither is safe on its own. Until 2026-09-10
  this script wrote the user half unconditionally and only THEN checked for admin, so an
  unelevated run deleted both entries from the user PATH and re-added them nowhere. That is not
  hypothetical; it happened on 2026-09-09 and the two backups the run left behind are still in
  logs\ as the evidence:

      path-backup-20260909-203021.json   user PATH  945 chars, ...\DevToolbox\sysinternals present
      path-backup-20260909-203149.json   user PATH  171 chars, sysinternals gone,
                                         machine PATH unchanged at 4363 chars

  88 seconds apart, and ~40 developer tools stopped resolving because the entries then existed in
  NEITHER scope. Now an unelevated run writes no PATH at all: it reports the plan, re-launches
  itself through UAC (-NoElevate opts out of the prompt), and exits 2 with the PATH untouched if
  consent is refused. The elevated pass writes MACHINE first, so even a run that dies half-way
  leaves the entries in both scopes rather than in none. And the gate is now asked whether the
  PATH is actually CHANGING (Test-PathPlanChanged), not whether the session is elevated, so a
  rebuild never prompts and a re-run that computes an identical PATH never prompts either.

  SHADOWING. Where two package directories provide the same executable (ffmpeg.exe ships in
  three), the choice comes from an authoritative order - the live PATH, a backup's PATH order, or
  an explicit -Pick - never from the order the disk was walked in. Alphabetical order INVERTS
  the only contested decision on this box. See lib\ShimPlan.ps1's header.

.EXAMPLE
  .\scripts\consolidate-path.ps1 -DryRun                 # report everything, change nothing
  .\scripts\consolidate-path.ps1 -RebuildShims -DryRun   # show the rebuild plan, name by name
  .\scripts\consolidate-path.ps1 -RebuildShims           # refill native\bin; writes no PATH
  .\scripts\consolidate-path.ps1 -FromBackup logs\path-backup-20260909-203021.json
  .\scripts\consolidate-path.ps1 -RebuildShims -Pick "ffmpeg=Gyan.FFmpeg.Essentials"
  .\scripts\consolidate-path.ps1 -Prune -DryRun          # hygiene plan + resolution delta
  .\scripts\consolidate-path.ps1                         # apply; re-launches itself elevated
  .\scripts\consolidate-path.ps1 -Restore logs\path-backup-20260827-120000.json
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Restore,
    # Windows handed this shell 4095 chars. Aim comfortably under it rather than at it.
    [int]$TargetMax = 3500,
    # Report the plan and exit 2 instead of raising a UAC prompt. For unattended callers that
    # must never block on a consent dialog nobody is there to click.
    [switch]$NoElevate,
    # Rebuild native\bin from what is on disk, rather than from what is on PATH. The recovery
    # path for a lost toolbox directory; see failure 3 in the description.
    [switch]$RebuildShims,
    # Rebuild, ranking contested names from this backup's PATH order. The only surviving record
    # of the original 27-directory resolution order is logs\path-backup-20260909-203021.json,
    # which survived by luck - .shim-sources.json exists so the next one does not have to.
    [string]$FromBackup,
    # '<name>=<PackageIdPrefix>', repeatable, comma-separated. Binds a contested name by hand.
    [string[]]$Pick,
    # Remove the ratified entries in config\path-hygiene.json, re-measuring every precondition.
    [switch]$Prune,
    [string]$PackagesRoot = (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
    # Internal, set only on the UAC child: the SID of the account that asked for the change.
    # Elevation can change identity. On a standard-user account UAC accepts a DIFFERENT
    # administrator's credentials, and the child's HKCU is then that administrator's hive - so
    # "write the user PATH" would edit the wrong account and leave this one just as broken. The
    # child refuses to write anything unless the SID it was launched with is its own.
    [string]$ElevatedFor
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $RepoRoot 'lib\path-registry.ps1')
. (Join-Path $RepoRoot 'lib\ShimPlan.ps1')
$Root = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { Join-Path $env:LOCALAPPDATA 'DevToolbox' }
$NativeBin = Join-Path $Root 'native\bin'
$Sysinternals = Join-Path $Root 'sysinternals'
$LogDir = Join-Path $RepoRoot 'logs'
$HygieneConfig = Join-Path $RepoRoot 'config\path-hygiene.json'
# Fixed name, not timestamped, because the parent must print this path BEFORE the child exists.
$ElevatedLog = Join-Path $LogDir 'consolidate-elevated.log'

function Write-Head($t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Write-Info2($t) { Write-Host "  [info] $t" -ForegroundColor Gray }
function Write-Warn2($t) { Write-Host "  [!]    $t" -ForegroundColor Yellow }

# Parameters the elevated child must NOT be handed, each with the reason it is excluded.
# EVERYTHING ELSE IS FORWARDED, derived from $PSBoundParameters. The old code hand-listed the
# two parameters it did forward, so any switch added afterwards was silently dropped - the
# parent would report "rebuild only, nothing dropped", raise UAC, and the child, seeing none of
# the flags, would run PLAIN consolidation and drop PATH entries nobody asked it to. Deriving
# the list makes the failure mode "an unexpected parameter is forwarded", which the child
# rejects loudly, instead of "an expected one is missing", which it cannot detect at all.
# tests\Invoke-InstallerTests.ps1 reads this array out of the source and asserts that every
# parameter in the block above is either forwarded or named here.
$NeverForward = @(
    'ElevatedFor',   # the child computes its own; forwarding the parent's would defeat the same-SID guard
    'TargetMax',     # forwarded explicitly by Get-SelfElevateArgs, and -File rejects a repeated parameter
    'DryRun',        # a dry run writes nothing, so it never reaches the elevation gate
    'NoElevate',     # -NoElevate exits 2 at the gate instead of launching a child
    'Restore'        # -Restore returns before the gate and needs its own elevated invocation
)

function Invoke-SelfElevate {
    # ShellExecute with the RunAs verb is the only way to raise UAC from inside a script. It
    # cannot be handed a custom environment block, but the AppInfo service copies the caller's,
    # so CODEX_TOOLBOX and friends survive the hop and the child computes the same plan.
    # Returns the child's exit code, or $null if consent was refused or there was no interactive
    # desktop to show the prompt on. ShellExecute fails fast with ERROR_CANCELLED in that case,
    # it does not hang, so an unattended caller gets an answer instead of a wedged -Wait.
    #
    # -Bound is passed in rather than read here: inside a function $PSBoundParameters is the
    # FUNCTION's own bound parameters, so reading it here would forward nothing at all.
    param([hashtable]$Bound = @{})
    $hostExe = (Get-Process -Id $PID).Path
    if (-not $hostExe) { $hostExe = Join-Path $PSHOME 'powershell.exe' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $argList = Get-SelfElevateArgs -ScriptPath $PSCommandPath -Sid $sid -TargetMax $TargetMax `
        -Bound $Bound -NeverForward $NeverForward
    Write-Info2 ("child command line: {0}" -f ($argList -join ' '))
    try {
        $p = Start-Process -FilePath $hostExe -ArgumentList $argList -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        return $null
    }
    if ($null -eq $p) { return $null }
    return [int]$p.ExitCode
}

# --- mode, and the combinations that used to be accepted and ignored ------------
$rebuildMode = [bool]($RebuildShims -or $FromBackup)
$mode = if ($Prune) { 'prune' } elseif ($rebuildMode) { 'rebuild' } else { 'consolidate' }

if ($Restore) {
    # -Restore returns at the end of its own block, long before any of this is read, so until
    # now these combinations were accepted in silence and the operator got a restore instead of
    # the rebuild they asked for.
    $alsoAsked = @()
    if ($RebuildShims) { $alsoAsked += '-RebuildShims' }
    if ($FromBackup)   { $alsoAsked += '-FromBackup' }
    if ($Prune)        { $alsoAsked += '-Prune' }
    if ($Pick)         { $alsoAsked += '-Pick' }
    if ($alsoAsked.Count -gt 0) {
        throw ("-Restore cannot be combined with " + ($alsoAsked -join ', ') +
               ". -Restore rewrites both PATH values from a backup and returns; run it on its own, " +
               "then run the other mode.")
    }
}
if ($Prune -and $rebuildMode) {
    throw ('-Prune cannot be combined with -RebuildShims/-FromBackup: -Prune writes the PATH and ' +
           'a rebuild deliberately does not, so one run cannot honour both. Run them separately.')
}
if ($Pick -and $Prune) {
    throw '-Pick only means something where shims are planned; -Prune plans no shims.'
}

# --- elevated child: prove we are still the same user ---------------------------
if ($ElevatedFor) {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($me -ne $ElevatedFor) {
        throw ("Elevated as a different account ($me) than the one that asked ($ElevatedFor). " +
               "HKCU in this process is the wrong hive, so writing 'the user PATH' here would " +
               "edit that other account and leave yours exactly as broken. Sign in as an " +
               "administrator and run this again.")
    }
    # A UAC child owns a brand-new console window that closes the instant it exits, so in
    # practice nobody ever reads its output - including the backup path it prints, which is the
    # one line you need when a PATH change goes wrong. Transcribe it beside the PATH backups.
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    # NOT an empty catch. The one failure that actually occurs here is "Transcription has already
    # been started" - fresh-toolbox-setup-runner.ps1 starts its own transcript and then invokes
    # this script with `&`, so the child inherits a session that is already transcribing and 5.1
    # throws. Swallowing that silently made the parent's promise at the elevation gate ("the
    # elevated run transcribes to $ElevatedLog") false with no trace, which is worse than not
    # promising it: the operator goes looking for a file that was never going to exist.
    #
    # Already-transcribing is benign - the output still lands in the RUNNER's transcript, so
    # nothing is lost - so it is reported and execution continues. Any other failure (a locked
    # file, a full disk) is reported with its real message for the same reason.
    $script:TranscriptStarted = $false
    try {
        Start-Transcript -Path $ElevatedLog -Force | Out-Null
        $script:TranscriptStarted = $true
    } catch {
        if ($_.Exception.Message -match 'already been started') {
            Write-Info2 "already transcribing - this run's output goes to the caller's transcript, not $ElevatedLog"
        } else {
            Write-Warn2 "could not transcribe to $ElevatedLog ($($_.Exception.Message)) - output is console-only"
        }
    }
}

# --- restore ------------------------------------------------------------------
if ($Restore) {
    $file = if ([IO.Path]::IsPathRooted($Restore)) { $Restore } else { Join-Path $RepoRoot $Restore }
    if (-not (Test-Path $file)) { throw "backup not found: $file" }
    $b = Get-Content $file -Raw | ConvertFrom-Json
    Write-Head "Restoring PATH from $file (captured $($b.captured_at))"
    if (-not (Test-PathAdmin)) { throw 'Restoring the machine PATH needs an elevated session.' }
    Set-RawPath -Scope Machine -Value $b.machine
    Set-RawPath -Scope User -Value $b.user
    Write-Ok "machine PATH restored ($($b.machine.Length) chars)"
    Write-Ok "user PATH restored ($($b.user.Length) chars)"
    Write-Warn2 'Open a NEW shell to see the restored PATH.'
    return
}

# --- read + report -------------------------------------------------------------
$machine = Get-RawPath -Scope Machine
$user = Get-RawPath -Scope User
$mEntries = Split-PathList $machine
$uEntries = Split-PathList $user

Write-Head "Current PATH  (mode: $mode)"
Write-Info2 ("machine : {0,5} chars, {1} entries" -f $machine.Length, $mEntries.Count)
Write-Info2 ("user    : {0,5} chars, {1} entries" -f $user.Length, $uEntries.Count)
Write-Info2 ("session : {0,5} chars  <- what this process actually received" -f $env:Path.Length)
# Detect truncation by its SIGNATURE, not by a length comparison. A session PATH is legitimately
# shorter than machine+user (de-duplication, per-process edits, a parent that started earlier), so
# "shorter" alone cries wolf - it did, on a freshly consolidated 1818-char PATH. What truncation
# actually looks like is a final entry chopped mid-string, leaving a directory that cannot exist.
$sessEntries = Split-PathList $env:Path
if ($sessEntries.Count -gt 0) {
    $lastEntry = $sessEntries[-1]
    if (-not (Test-Path -LiteralPath $lastEntry -ErrorAction SilentlyContinue)) {
        Write-Warn2 "This shell's PATH ends in a directory that does not exist ('$lastEntry')."
        Write-Warn2 "That is the signature of a PATH truncated in flight at $($env:Path.Length) chars."
    }
}

# --- native\bin: required, created, or irrelevant -------------------------------
# The original threw here unconditionally, before any discovery - so on 2026-09-10, with the
# toolbox directory deleted, the one script that could have rebuilt the shims refused to start.
if ($mode -eq 'rebuild') {
    if (-not (Test-Path $NativeBin)) {
        if ($DryRun) { Write-Info2 "would create $NativeBin (it does not exist)" }
        else { New-Item -ItemType Directory -Force -Path $NativeBin | Out-Null; Write-Ok "created $NativeBin" }
    }
    # A shim in a directory nothing searches is not a repair, it is a directory of text files
    # that makes the smoke test green. Writing 47 of them and printing "Done" is exactly the
    # shape of failure this repo's suites exist to prevent, so say so before doing it.
    $nbKey = Get-ShimNormalKey $NativeBin
    $onPath = @(@($mEntries + $uEntries) | Where-Object { (Get-ShimNormalKey ([Environment]::ExpandEnvironmentVariables($_))) -eq $nbKey })
    if ($onPath.Count -eq 0) {
        Write-Warn2 "$NativeBin is on NEITHER PATH hive, so rebuilding the shims will fix NOTHING."
        Write-Warn2 'Nothing will resolve by name until that directory is on the PATH. Run this'
        Write-Warn2 'script with no arguments (the default consolidation mode) to add it to the'
        Write-Warn2 'MACHINE PATH, or run bootstrap.ps1, and then rebuild.'
    }
} elseif ($mode -eq 'consolidate') {
    # Kept as a hard failure for the DEFAULT mode on purpose: collapsing 27 PATH entries into a
    # directory that does not exist is a self-inflicted outage, and it is the one this script
    # caused on 2026-09-10.
    if (-not (Test-Path $NativeBin)) {
        throw ("toolbox native\bin not found at $NativeBin - run bootstrap.ps1 first (or set " +
               "CODEX_TOOLBOX). Collapsing the winget PATH entries into a directory that does not " +
               "exist would remove every one of those tools from every shell. If the toolbox " +
               "directory was deleted and the PATH is ALREADY consolidated, this script's " +
               "-RebuildShims mode is the repair.")
    }
}

# --- plan -----------------------------------------------------------------------
$drop = @()
$plan = $null
$priorityOrder = @()
$prioritySource = ''
$hygiene = $null

if ($mode -eq 'prune') {
    if (-not (Test-Path -LiteralPath $HygieneConfig)) { throw "hygiene config not found: $HygieneConfig" }
    $hygiene = Get-PathHygienePlan -Json (Get-Content -LiteralPath $HygieneConfig -Raw -Encoding UTF8) `
        -MachineRaw $machine -UserRaw $user

    Write-Head 'PATH hygiene'
    Write-Info2 ("ratified entries still removable: {0} machine, {1} user" -f @($hygiene.RemoveMachine).Count, @($hygiene.RemoveUser).Count)
    foreach ($e in @($hygiene.RemoveMachine)) { Write-Info2 "remove [machine] $e" }
    foreach ($e in @($hygiene.RemoveUser))    { Write-Info2 "remove [user]    $e" }
    foreach ($s in @($hygiene.Skipped)) {
        Write-Warn2 ("SKIPPED [{0}] {1} - require '{2}' no longer holds: {3}" -f $s.Scope, $s.Entry, $s.Require, $s.Why)
    }
    Write-Head 'Resolution delta'
    if (@($hygiene.Delta).Count -eq 0) { Write-Ok 'no bare command name changes where it resolves from' }
    foreach ($d in @($hygiene.Delta)) {
        if ($d.Change -eq 'unresolved') { Write-Warn2 ("{0}: no longer resolves (was {1})" -f $d.Name, $d.From) }
        else { Write-Info2 ("{0}: {1} -> {2}" -f $d.Name, $d.From, $d.To) }
    }
} else {
    if ($mode -eq 'consolidate') {
        # Resolution order is machine-then-user, which is how Windows composes the session PATH.
        # Keeping that order is what makes "first one wins" match what resolves today.
        $ordered = @($mEntries + $uEntries)
        $drop = @($ordered | Where-Object { $_ -like '*\WinGet\Packages\*' } | Select-Object -Unique)
        Write-Head "Winget package directories to collapse: $($drop.Count)"
        if ($drop.Count -eq 0) {
            # NOT an error, and not something to return on either: zero candidates is also the
            # state of a box that is already consolidated correctly - which is precisely the box
            # whose shims went missing. Signpost the repair instead of falling silently through
            # into a PATH rewrite, which is what this line used to do.
            Write-Ok 'nothing to collapse - no WinGet\Packages directory is on either PATH hive.'
            Write-Info2 'That is also what a correctly consolidated box looks like. If tools are'
            Write-Info2 'missing, the shims are gone rather than the PATH:'
            Write-Info2 '    .\scripts\consolidate-path.ps1 -RebuildShims -DryRun'
            $newest = @(Get-ChildItem -LiteralPath $LogDir -Filter 'path-backup-*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1)
            if ($newest.Count -gt 0) {
                Write-Info2 ("    .\scripts\consolidate-path.ps1 -FromBackup `"logs\{0}`" -DryRun" -f $newest[0].Name)
                Write-Info2 '(the second form ranks contested names from that backup''s PATH order)'
            }
        }
        $missingDirs = @($drop | Where-Object { -not (Test-Path -LiteralPath $_) })
        foreach ($d in $missingDirs) { Write-Warn2 "on PATH but gone from disk, will be dropped: $d" }
        $liveDirs = @($drop | Where-Object { Test-Path -LiteralPath $_ })
        $candidates = @()
        if ($liveDirs.Count -gt 0) { $candidates = @(Get-ShimCandidates -PackagesRoot $PackagesRoot -Dirs $liveDirs) }
        $priorityOrder = @(Get-ShimPackageOrder -Entries $drop -PackagesRoot $PackagesRoot)
        $prioritySource = 'live PATH order (machine, then user)'
        # SAY SO WHEN THE RANKING IS PARTIAL. Everything under -PackagesRoot can be ranked and
        # can take part in the sibling rule; a WinGet\Packages entry somewhere else (a
        # machine-scope portable lands under %ProgramFiles%\WinGet\Packages, not
        # %LOCALAPPDATA%\...) is still shimmed, but it cannot be ranked against a rival, so a
        # contested name involving one would be reported contested rather than resolved. None of
        # this box's 27 are outside the root; a run where some are should not have to be guessed at.
        $unrooted = @($drop | Where-Object { -not (Get-ShimPackageRoot -Path $_ -PackagesRoot $PackagesRoot) })
        foreach ($u in $unrooted) {
            Write-Warn2 "outside -PackagesRoot, so not rankable: $u"
        }
        if ($unrooted.Count -gt 0) {
            Write-Warn2 ("{0} of {1} entries cannot take part in ranking. Pass -PackagesRoot, or resolve any" -f $unrooted.Count, $drop.Count)
            Write-Warn2 'contested name those entries are involved in with -Pick.'
        }
    } else {
        $candidates = @(Get-ShimCandidates -PackagesRoot $PackagesRoot)
        Write-Head "Packages walked: $PackagesRoot"
        Write-Info2 ("{0} executable(s), {1} distinct name(s), {2} package(s)" -f
            @($candidates).Count,
            @(@($candidates | ForEach-Object { $_.Name }) | Select-Object -Unique).Count,
            @(@($candidates | ForEach-Object { $_.PackageId }) | Select-Object -Unique).Count)

        # Priority, most authoritative first. A rebuild on a consolidated box finds nothing on
        # PATH to rank by, which is the whole reason the persisted map exists.
        if ($FromBackup) {
            $bf = if ([IO.Path]::IsPathRooted($FromBackup)) { $FromBackup } else { Join-Path $RepoRoot $FromBackup }
            if (-not (Test-Path -LiteralPath $bf)) { throw "backup not found: $bf" }
            $priorityOrder = @(Get-ShimPriority -Json (Get-Content -LiteralPath $bf -Raw) -PackagesRoot $PackagesRoot)
            $prioritySource = "PATH order in $bf"
        } else {
            $onPathNow = @(Get-ShimPackageOrder -Entries @($mEntries + $uEntries) -PackagesRoot $PackagesRoot)
            if ($onPathNow.Count -gt 0) {
                $priorityOrder = $onPathNow
                $prioritySource = 'live PATH order (machine, then user)'
            } else {
                foreach ($mapFile in @((Join-Path $NativeBin '.shim-sources.json'), (Join-Path $LogDir 'shim-sources.json'))) {
                    if (-not (Test-Path -LiteralPath $mapFile)) { continue }
                    $doc = Read-ShimSources -Json (Get-Content -LiteralPath $mapFile -Raw)
                    $priorityOrder = @($doc.priority_order)
                    $prioritySource = "priority_order in $mapFile"
                    break
                }
            }
        }
        if (@($priorityOrder).Count -eq 0) {
            Write-Warn2 'No authoritative priority order available (no -FromBackup, no WinGet entry on'
            Write-Warn2 'PATH, no persisted .shim-sources.json). Names supplied by exactly one package'
            Write-Warn2 'are unaffected; a contested name will be reported and SKIPPED rather than'
            Write-Warn2 'guessed from the order the disk was walked in.'
            $prioritySource = 'none'
        } else {
            Write-Info2 "priority source: $prioritySource ($(@($priorityOrder).Count) package(s))"
        }
    }

    $existing = @(Get-ShimExisting -NativeBin $NativeBin)
    $plan = Get-ShimPlan -Candidates $candidates -Existing $existing -Pick @($Pick) `
        -PriorityOrder $priorityOrder -NativeBin $NativeBin

    Write-Head 'Shim plan'
    Write-Info2 ("write {0}  (of which {1} refresh a stale wrapper)" -f @($plan.Write).Count, @($plan.Refreshed).Count)
    Write-Info2 ("keep  {0}  (a wrapper is already there and its target exists)" -f @($plan.Kept).Count)
    Write-Info2 ("contested {0}  shadowed {1}" -f @($plan.Contested).Count, @($plan.Shadowed).Count)

    # Under -DryRun, print the DECISION for every single name. The entire risk of this mode is
    # WHICH target each name got bound to; a count of 47 says nothing about whether ffmpeg
    # points at Gyan or BtbN, and those are the runs worth reviewing.
    if ($DryRun) {
        foreach ($e in @($plan.Write | Sort-Object Name)) {
            $tag = if ($e.Refresh) { 'refresh' } else { 'write  ' }
            Write-Info2 ("{0} {1,-14} [{2}] -> {3}" -f $tag, $e.Name, $e.Because, $e.Target)
        }
        foreach ($k in @($plan.Kept | Sort-Object Name)) {
            $extra = if ($k.Would) { "  (would have been $($k.Would))" } else { '' }
            Write-Info2 ("keep    {0,-14} [{1}] -> {2}{3}" -f $k.Name, $k.Reason, $k.Target, $extra)
        }
    }
    foreach ($s in @($plan.Shadowed)) { Write-Info2 "shadowed, unchanged: $($s.Name) -> keeping $($s.Chosen)" }
    foreach ($s in @($plan.Skipped))  { Write-Info2 "skipped: $($s.Name) - $($s.Reason)" }
    foreach ($c in @($plan.Contested)) {
        Write-Warn2 "CONTESTED, no shim written: $($c.Name)"
        foreach ($cd in @($c.Candidates)) { Write-Warn2 "    $($cd.Target)" }
        Write-Warn2 "    resolve with: $($c.Command)"
    }
    foreach ($k in @($plan.Kept | Where-Object { $_.Reason -eq 'stale-no-source' })) {
        Write-Warn2 ("stale and unfixable: {0} -> {1} (no package under the packages root supplies it)" -f $k.Name, $k.Target)
    }
}

# --- compute the new PATHs ------------------------------------------------------
if ($mode -eq 'prune') {
    $newMachine = [string]$hygiene.NewMachine
    $newUser = [string]$hygiene.NewUser
    $newM = @($hygiene.KeptMachine)
    $newU = @($hygiene.KeptUser)
} elseif ($mode -eq 'rebuild') {
    # REBUILD ONLY. The machine PATH on this box already carries native\bin and sysinternals, so
    # refilling the directory restores resolution with zero registry writes and zero elevation.
    # Touching the PATH here would be work with a UAC prompt attached and nothing to show for it.
    $newM = @($mEntries)
    $newU = @($uEntries)
    $newMachine = $machine
    $newUser = $user
} else {
    $rm = Remove-PathEntryFromString -Value $machine -Remove $drop
    $ru = Remove-PathEntryFromString -Value $user -Remove $drop
    $newM = @($rm.Kept)
    $newU = @($ru.Kept)
    foreach ($need in @($NativeBin, $Sysinternals)) {
        if (Test-Path $need) {
            $newU = @($newU | Where-Object { (Get-ShimNormalKey $_) -ne (Get-ShimNormalKey $need) })   # de-dupe from user
            if (-not (@($newM | Where-Object { (Get-ShimNormalKey $_) -eq (Get-ShimNormalKey $need) }).Count)) { $newM += $need }
        }
    }
    $newMachine = ($newM -join ';')
    $newUser = ($newU -join ';')
}

Write-Head "After $mode"
Write-Info2 ("machine : {0,5} chars, {1} entries  (was {2}, {3})" -f $newMachine.Length, $newM.Count, $machine.Length, $mEntries.Count)
Write-Info2 ("user    : {0,5} chars, {1} entries  (was {2}, {3})" -f $newUser.Length, $newU.Count, $user.Length, $uEntries.Count)
$total = $newMachine.Length + $newUser.Length + 1
Write-Info2 ("combined: {0,5} chars" -f $total)
if ($newMachine.Length -le $TargetMax) { Write-Ok "machine PATH is under the $TargetMax-char target" }
else { Write-Warn2 "machine PATH is still $($newMachine.Length) chars, above the $TargetMax target - review it by hand" }

# THE ELEVATION QUESTION IS "IS THE PATH CHANGING", NOT "AM I ADMIN". Compared as normalised
# ENTRY LISTS, so a trailing ';' or a regained trailing backslash does not drag a run that
# changes nothing through a UAC prompt - and so a rebuild, which changes no entry at all, never
# prompts. One predicate, two bugs.
$needsRegistry = Test-PathPlanChanged -BeforeMachine $mEntries -AfterMachine $newM -BeforeUser $uEntries -AfterUser $newU
if (-not $needsRegistry) { Write-Ok 'both PATH values already say what this run would say - no registry write, no elevation' }

if ($DryRun) {
    Write-Head 'DRY RUN - nothing was changed'
    if ($plan) {
        Write-Info2 "would write $(@($plan.Write).Count) shim(s) into $NativeBin"
        Write-Info2 "would keep $(@($plan.Kept).Count) existing wrapper(s) untouched"
        Write-Info2 "would leave $(@($plan.Contested).Count) contested name(s) unresolved"
    }
    if ($mode -eq 'consolidate') { Write-Info2 "would drop $($drop.Count) winget package entries" }
    if ($mode -eq 'prune') { Write-Info2 "would drop $(@($hygiene.RemoveMachine).Count + @($hygiene.RemoveUser).Count) hygiene entries" }
    if ($needsRegistry) { Write-Info2 'would write BOTH PATH values (elevation required)' }
    else { Write-Info2 'would write NO PATH value and raise NO UAC prompt' }
    return
}

# --- elevation gate ---------------------------------------------------------------
# Nothing past this point may write the registry unelevated. Writing the user PATH without the
# machine PATH is not a partial fix, it is the 2026-09-09 outage described in the header: the
# default plan takes native\bin and sysinternals OFF the user PATH because the machine PATH is
# meant to carry them, so the user write on its own removes ~40 tools from every shell on the
# box. The old code did the user write first and only then tested for admin.
if ($needsRegistry -and -not (Test-PathAdmin)) {
    Write-Head 'Elevation required - NOTHING has been changed'
    Write-Info2 ("would set MACHINE PATH to {0,5} chars / {1} entries" -f $newMachine.Length, $newM.Count)
    Write-Info2 ("would set USER    PATH to {0,5} chars / {1} entries" -f $newUser.Length, $newU.Count)
    if ($plan) { Write-Info2 "would write $(@($plan.Write).Count) shim(s) into $NativeBin" }
    if ($mode -eq 'consolidate') { Write-Info2 "would drop $($drop.Count) winget package entries" }

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $pending = Join-Path $LogDir 'machine-path-pending.txt'
    Set-Content -Path $pending -Value $newMachine -Encoding UTF8 -NoNewline
    Write-Info2 "intended machine PATH saved for review: $pending"

    if ($NoElevate) {
        Write-Warn2 '-NoElevate: no UAC prompt was raised and no PATH was written. Your PATH is unchanged.'
        Write-Warn2 'Re-run from an elevated shell to apply the plan above.'
        exit 2
    }
    Write-Info2 "requesting elevation - the elevated run transcribes to $ElevatedLog"
    $childCode = Invoke-SelfElevate -Bound $PSBoundParameters
    if ($null -eq $childCode) {
        Write-Warn2 'Elevation was declined or unavailable, so NOTHING was written. Your PATH is exactly as it was.'
        Write-Warn2 'Re-run from an elevated shell, or apply the pending machine PATH by hand.'
        exit 2
    }
    if ($childCode -ne 0) {
        Write-Warn2 "The elevated run exited $childCode - read $ElevatedLog before re-running."
        exit $childCode
    }
    Write-Ok "the elevated run finished; its full output is in $ElevatedLog"
    Write-Warn2 'Open a NEW shell: an already-running process keeps the environment block it started with.'
    exit 0
}

# --- back up --------------------------------------------------------------------
# Only when a PATH value is actually being written. A rebuild that touches no registry value has
# nothing to restore, and a logs\ directory full of identical backups is how the one that matters
# gets lost.
if ($needsRegistry) {
    $backup = Backup-PathRegistry -LogDir $LogDir -Machine $machine -User $user
    Write-Head 'Backup'
    Write-Ok "wrote $backup"
    Write-Info2 "restore with: .\scripts\consolidate-path.ps1 -Restore `"$backup`""
}

# --- write the shims --------------------------------------------------------------
# Before the PATH is rewritten, never after: the shims are the replacement for the entries the
# default mode is about to drop.
if ($plan) {
    Write-Head 'Shims'
    $res = Invoke-ShimWrite -Plan $plan -NativeBin $NativeBin
    Write-Ok "$(@($res.Written).Count) shim(s) written in $NativeBin"
    if (@($plan.Kept).Count -gt 0) { Write-Info2 "$(@($plan.Kept).Count) existing wrapper(s) left untouched" }
    foreach ($r in @($res.Refused)) { Write-Warn2 "refused to overwrite $($r.Wrapper): $($r.Reason)" }

    # Two copies on purpose. One beside the shims for whoever finds the directory; one in the
    # repo for whoever finds the repo after the directory is gone - which is the 2026-09-10 case
    # and the only one that needed it.
    $doc = New-ShimSourcesDocument -Plan $plan -Mode $mode -PrioritySource $prioritySource -PriorityOrder $priorityOrder
    $json = $doc | ConvertTo-Json -Depth 6
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    foreach ($dest in @((Join-Path $NativeBin '.shim-sources.json'), (Join-Path $LogDir 'shim-sources.json'))) {
        Set-Content -LiteralPath $dest -Value $json -Encoding UTF8
        Write-Ok "shim map -> $dest"
    }
}

# --- write the PATHs ---------------------------------------------------------------
# MACHINE first, then USER, and never one without the other. Both writes only ever happen in an
# elevated process now (see the gate above), but the ORDER still matters: the default mode moves
# native\bin and sysinternals from the user scope to the machine scope, so machine-first means a
# run that dies between the two leaves them present in BOTH scopes - a duplicate PATH entry,
# harmless - instead of in neither, which is what user-first cost us on 2026-09-09.
if ($needsRegistry) {
    Write-Head 'PATH'
    Set-RawPath -Scope Machine -Value $newMachine
    Write-Ok "machine PATH updated ($($newMachine.Length) chars)"
    Set-RawPath -Scope User -Value $newUser
    Write-Ok "user PATH updated ($($newUser.Length) chars)"
    Publish-EnvChange
}

Write-Head 'Done'
if ($needsRegistry) {
    Write-Warn2 'Open a NEW shell: an already-running process keeps the environment block it started with.'
} else {
    Write-Info2 'No PATH value was written, so running shells are unaffected. A new shell still needs'
    Write-Info2 'to start for a NEW native\bin entry to be searched, but that entry already existed.'
}
# The old footer said "re-run after a winget upgrade", which is impossible once the PATH is
# consolidated: this script's default mode discovers its work by looking for WinGet\Packages
# entries ON the PATH, and after a successful run there are none. That advice is what left the
# box with no recovery route on 2026-09-10.
Write-Info2 'After a winget upgrade a version-stamped package folder moves and its shim goes stale.'
Write-Info2 'Rebuild them from disk - NOT by re-running the default mode, which finds nothing to do:'
Write-Info2 '    .\scripts\consolidate-path.ps1 -RebuildShims'
Write-Info2 'scripts\smoke-test.ps1 reports any shim whose target no longer exists.'
