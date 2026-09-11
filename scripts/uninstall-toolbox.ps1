#Requires -Version 5.1
<#
Full-reset uninstaller for the Windows dev toolbox.

By default this removes the toolbox LAYER only - everything the toolbox owns and
can safely reverse - and leaves winget-installed tools (gh, fzf, ffmpeg,
LibreOffice, ...) under winget's own management:

  - deletes the DevToolbox directory (%LOCALAPPDATA%\DevToolbox or CODEX_TOOLBOX),
  - unregisters the user PATH entries and env vars the toolbox added,
  - strips the agent-discovery blocks from CLAUDE.md / AGENTS.md,
  - removes the generated manifest/tools.json and the Sysinternals EULA keys.

With -RemoveWingetTools it ALSO winget-uninstalls / npm-uninstalls the gap-fill
tools, but ONLY those the manifest records as installed by the toolbox
(installed_by_toolbox=true) - tools that pre-existed are left alone. Machine-scope
uninstalls need elevation; if this session is not elevated they are reported and
skipped.

  .\scripts\uninstall-toolbox.ps1 -DryRun          # show exactly what would change
  .\scripts\uninstall-toolbox.ps1                  # toolbox layer only (prompts to confirm)
  .\scripts\uninstall-toolbox.ps1 -RemoveWingetTools
  .\scripts\uninstall-toolbox.ps1 -Yes             # skip the typed confirmation
#>
[CmdletBinding()]
param(
    [switch]$RemoveWingetTools,
    [switch]$DryRun,
    [switch]$Yes
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path $PSScriptRoot
. (Join-Path $REPO_ROOT "lib\common.ps1")
. (Join-Path $REPO_ROOT "lib\catalog.ps1")
if ($DryRun) { $script:DryRun = $true }

$MANIFEST_PATH = Join-Path $REPO_ROOT "manifest\tools.json"
$toolboxRoot = if ($env:CODEX_TOOLBOX) { [System.IO.Path]::GetFullPath($env:CODEX_TOOLBOX) }
               else { Join-Path $env:LOCALAPPDATA "DevToolbox" }

function Test-IsElevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return ([System.Security.Principal.WindowsPrincipal]$id).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native {
    <#
        Run a native uninstaller with its output captured and its stderr survivable, and return
        the exit code beside the captured lines.

        THIS SCRIPT IS THE ONE THAT CANNOT AFFORD TO DIE HALFWAY. Under this file's
        $ErrorActionPreference = 'Stop', PowerShell 5.1 turns a native command's stderr into a
        TERMINATING NativeCommandError whenever it has redirected that stream - which an outer
        capture does even when the call site itself has no redirection. A package that REFUSES
        to uninstall (in use, needs elevation, no matching install) writes the refusal to
        stderr, so the exact case section 1 checks for was the case that killed the run, and it
        died before sections 2-4 had reversed the PATH entries, cleared the env vars or stripped
        the agent blocks. Half-uninstalled, with the machine-state reversal still pending.

        Measured 2026-09-11 under 5.1: a merged or 2>$null-redirected native stderr throws under
        Stop in every host-stream condition tested, and so does an unredirected one as soon as
        any enclosing call applies 2>&1 - which is how this script is run from a log-capturing
        parent. Setting Continue for the one statement is the only shape that holds in both.

        Rejected: `| Out-Null`. It addresses a different problem (native stdout leaking into a
        function's return value) and does nothing about stderr; see build-devtoolbox.ps1's
        Invoke-NativeCapture, which this mirrors.
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

# Anything that could not be reversed. Non-empty at the end means the uninstall is INCOMPLETE
# and the exit code says so; "toolbox uninstall complete" is reserved for a clean run.
$problems = @()

# -- Banner ---------------------------------------------------------------------
Write-Group "uninstall toolbox"
Write-Info "toolbox root:      $toolboxRoot"
Write-Info "remove winget tools: $([bool]$RemoveWingetTools)"
Write-Info "mode:              $(if ($DryRun) { 'DRY-RUN (no changes)' } else { 'LIVE' })"
# BEFORE the REMOVE prompt, not after. The toolbox's native\bin and sysinternals entries live in
# the MACHINE hive once consolidate-path.ps1 has run, and this script will not elevate to take
# them out - so an unelevated operator needs to know the reversal will be partial while they can
# still answer no. Step 2 reports the same gap afterwards and exits non-zero; by then they have
# already typed REMOVE.
if (-not (Test-IsElevated)) {
    Write-Warn "this session is NOT elevated: the MACHINE PATH entries (native\bin, sysinternals)"
    Write-Warn "cannot be removed and the run will report INCOMPLETE. Re-run elevated for a full"
    Write-Warn "reversal, or expect to remove those two entries by hand."
}

# -- 0. Validate the toolbox root BEFORE touching anything ----------------------
# This check used to live in step 5, next to the Remove-Item it guards. By the time it fired,
# steps 1-4 had already stripped the user PATH entries, cleared the toolbox env vars, deleted
# HKCU:\Software\Sysinternals and removed manifest\tools.json - and the script still finished
# with "toolbox uninstall complete" and exit 0. A shallow CODEX_TOOLBOX such as C:\DevToolbox
# (three components, so Split('\').Count is 2) therefore produced a half-uninstalled machine
# reported as a clean one: the toolbox directory intact, and everything that made it reachable
# gone. Refusing the path is only safe if nothing has happened yet, so decide here and abort.
$rootExists = Test-Path -LiteralPath $toolboxRoot
$rootResolved = $null
if ($rootExists) {
    # Safety: only delete a directory that (a) is not a drive root or a known protected
    # system/profile path, and (b) actually contains toolbox structure. Requiring a toolbox
    # marker means even a mis-set CODEX_TOOLBOX cannot point us at, say, C:\Windows - there is
    # no marker there, so we refuse.
    $rootResolved = (Resolve-Path -LiteralPath $toolboxRoot).Path.TrimEnd('\')
    $protected = @(
        $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE,
        $env:LOCALAPPDATA, $env:APPDATA, $env:SystemDrive, $env:ProgramData
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    $tooShort = ($rootResolved -match '^[A-Za-z]:\\?$') -or ($rootResolved.Split('\').Count -lt 3)
    $isProtected = $tooShort -or ($protected -contains $rootResolved)
    $hasMarker = (Test-Path (Join-Path $rootResolved 'toolbox-manifest.json')) -or
                 (Test-Path (Join-Path $rootResolved 'native\bin')) -or
                 (Test-Path (Join-Path $rootResolved 'python\.venv'))
    if ($isProtected -or -not $hasMarker) {
        Write-Err "Refusing to uninstall: '$rootResolved' is a protected path, or has no toolbox marker (toolbox-manifest.json / native\bin / python\.venv)."
        Write-Err "Nothing was changed - the PATH entries, env vars and registry keys are all still in place."
        Write-Err "Point CODEX_TOOLBOX at the real toolbox root and run this again."
        exit 1
    }
}

# -- Confirmation ---------------------------------------------------------------
# After the validation above, so nobody is asked to type REMOVE for a run we are going to
# refuse anyway.
if (-not $DryRun -and -not $Yes) {
    $answer = Read-Host "This permanently removes the toolbox. Type REMOVE to continue"
    if ($answer -ne "REMOVE") { Write-Warn "aborted - confirmation not given"; exit 1 }
}

# -- 1. Optionally uninstall the gap-fill tools we installed --------------------
if ($RemoveWingetTools) {
    Write-Group "remove installed gap-fill tools (provenance-aware)"
    if (Test-Path -LiteralPath $MANIFEST_PATH) {
        # Assign first, THEN wrap: PowerShell 5.1's ConvertFrom-Json emits an array
        # as a single pipeline object, so @(... | ConvertFrom-Json) would nest it.
        $loaded = Get-Content -LiteralPath $MANIFEST_PATH -Raw | ConvertFrom-Json
        $tools = @($loaded)
        foreach ($t in $tools) {
            # Provenance: only remove what the toolbox installed. Anything recorded
            # as pre-existing, or with install_method 'existing' (detected, not
            # installed by us - e.g. Ghidra, Npcap), is left untouched.
            $ours = -not ($t.PSObject.Properties.Name -contains 'installed_by_toolbox') -or $t.installed_by_toolbox
            if (-not $ours -or $t.install_method -eq 'existing') {
                Write-Skip "keep (not installed by toolbox): $($t.name)"
                continue
            }
            switch ($t.install_method) {
                'winget' {
                    if (-not $t.winget_id) { Write-Warn "no winget_id for $($t.name) - skipping"; continue }
                    if ($t.scope -eq 'machine' -and -not (Test-IsElevated)) {
                        Write-Warn "skip $($t.name): machine-scope uninstall needs elevation (re-run elevated)"
                        $problems += "$($t.name): machine-scope uninstall skipped (not elevated)"
                        continue
                    }
                    if ($DryRun) { Write-Info "[DRY-RUN] would: winget uninstall --id $($t.winget_id)"; continue }
                    Write-Info "winget uninstall $($t.winget_id)"
                    # The check below hides the output, not the outcome. Without it a package
                    # that refused to uninstall (in use, needs elevation, no matching install)
                    # left no trace at all and the run still ended in "uninstall complete".
                    #
                    # It was unreachable until 2026-09-11 whenever this script ran under a parent
                    # capturing its output, which is the normal case. Measured that day: an
                    # enclosing 2>&1 makes PowerShell redirect THIS command's stderr too, and
                    # winget's refusal - written to stderr - then terminated the run before the
                    # exit code could be read. The `| Out-Null` that used to sit here neither
                    # prevented that nor caused it; it simply was not the guard it was taken for.
                    $wu = Invoke-Native -FilePath 'winget' -Arguments @(
                        'uninstall', '--id', $t.winget_id, '-e', '--silent', '--accept-source-agreements')
                    if ($wu.ExitCode -ne 0) {
                        # Only worth reading on this path, which is why they are captured rather
                        # than discarded: winget's refusal REASON is the thing that was missing.
                        foreach ($line in $wu.Output) { Write-Host "    $line" -ForegroundColor DarkGray }
                        Write-Err "winget uninstall failed for $($t.name) [$($t.winget_id)]: exit $($wu.ExitCode)"
                        $problems += "$($t.name): winget uninstall exit $($wu.ExitCode)"
                    } else {
                        Write-Ok "uninstalled $($t.name)"
                    }
                }
                'npm-global' {
                    if (-not (Test-CommandAvailable 'npm')) { Write-Warn "npm not found - skipping $($t.name)"; continue }
                    if ($DryRun) { Write-Info "[DRY-RUN] would: npm uninstall -g $($t.name)"; continue }
                    Write-Info "npm uninstall -g $($t.name)"
                    # Worse than the winget site above, because npm writes `npm WARN` and
                    # `npm notice` to stderr on ORDINARY SUCCESSFUL runs - one deprecation notice
                    # is enough - so under a capturing parent this needed no failure at all to
                    # take the script down before its PATH and env-var reversal.
                    $nu = Invoke-Native -FilePath 'npm' -Arguments @('uninstall', '-g', $t.name)
                    if ($nu.ExitCode -ne 0) {
                        foreach ($line in $nu.Output) { Write-Host "    $line" -ForegroundColor DarkGray }
                        Write-Err "npm uninstall -g failed for $($t.name): exit $($nu.ExitCode)"
                        $problems += "$($t.name): npm uninstall exit $($nu.ExitCode)"
                    } else {
                        Write-Ok "uninstalled $($t.name)"
                    }
                }
                'pip-toolbox' {
                    Write-Skip "$($t.name): lives in the venv, removed with the toolbox directory"
                }
                default { Write-Skip "no removal path for method '$($t.install_method)': $($t.name)" }
            }
        }
    } else {
        Write-Warn "manifest not found ($MANIFEST_PATH) - cannot determine which tools were ours; skipping tool removal"
    }
}

# -- 2. Reverse the side effects recorded in the catalog ------------------------
Write-Group "unregister PATH / env / registry side effects"
$catalog = Get-Catalog
$se = $catalog.side_effects

foreach ($rel in @($se.path_entries_relative)) {
    Remove-UserPathEntry (Join-Path $toolboxRoot $rel)
}
foreach ($abs in @($se.path_entries_absolute)) {
    Remove-UserPathEntry ([System.Environment]::ExpandEnvironmentVariables($abs))
}
# The MACHINE hive, which the three loops above cannot touch. consolidate-path.ps1 moves
# native\bin and sysinternals there, so Remove-UserPathEntry looked for them in HKCU, found
# nothing, returned quietly, and this script printed "toolbox uninstall complete" - which is how
# the two dead DevToolbox entries got into this box's machine PATH and stayed there.
# Remove-MachinePathEntry deliberately does not self-elevate (see its comment in lib\common.ps1:
# raising UAC here can land in a different administrator's hive while we are half-way through
# mutating this one), so an unelevated run records the gap and exits non-zero instead of
# claiming a reversal it did not perform.
if ($se.PSObject.Properties.Name -contains 'path_entries_machine_relative') {
    foreach ($rel in @($se.path_entries_machine_relative)) {
        $full = Join-Path $toolboxRoot $rel
        if ((Remove-MachinePathEntry -Path $full) -eq 'NeedsElevation') {
            $problems += "machine PATH entry still present (needs elevation): $full"
        }
    }
}
foreach ($var in @($se.env_vars)) {
    $val = [System.Environment]::GetEnvironmentVariable($var, "User")
    if (-not $val) { continue }
    if ($DryRun) { Write-Info "[DRY-RUN] would clear User env var: $var"; continue }
    [System.Environment]::SetEnvironmentVariable($var, $null, "User")
    Write-Ok "cleared User env var: $var"
}
foreach ($key in @($se.registry_keys)) {
    if (-not (Test-Path -LiteralPath $key)) { continue }
    if ($DryRun) { Write-Info "[DRY-RUN] would remove registry key: $key"; continue }
    Remove-Item -LiteralPath $key -Recurse -Force
    Write-Ok "removed registry key: $key"
}

# -- 3. Strip agent-discovery blocks -------------------------------------------
Write-Group "strip agent-discovery blocks"
Remove-AgentBlocks

# -- 4. Remove the generated manifest ------------------------------------------
if (Test-Path -LiteralPath $MANIFEST_PATH) {
    if ($DryRun) { Write-Info "[DRY-RUN] would remove generated manifest: $MANIFEST_PATH" }
    else { Remove-Item -LiteralPath $MANIFEST_PATH -Force; Write-Ok "removed generated manifest" }
}

# -- 5. Delete the toolbox directory -------------------------------------------
# Already validated in step 0, which aborts the whole run rather than letting us arrive here
# with a path we are going to refuse.
Write-Group "remove toolbox directory"
if (-not $rootExists) {
    Write-Skip "toolbox directory not present: $toolboxRoot"
} elseif ($DryRun) {
    Write-Info "[DRY-RUN] would delete toolbox directory: $rootResolved"
} else {
    Remove-Item -LiteralPath $rootResolved -Recurse -Force
    Write-Ok "deleted toolbox directory: $rootResolved"
}

Write-Group "done"
if ($DryRun) {
    Write-Info "[DRY-RUN] complete - no changes were made"
} elseif ($problems.Count -gt 0) {
    # Say INCOMPLETE and exit non-zero. A partly-reversed uninstall reported as a clean one is
    # worse than a loud failure: the next person believes the machine is back to baseline.
    Write-Err "toolbox uninstall INCOMPLETE - $($problems.Count) step(s) did not succeed:"
    foreach ($p in $problems) { Write-Err "  - $p" }
    exit 1
} else {
    Write-Ok "toolbox uninstall complete"
}
