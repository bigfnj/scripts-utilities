#Requires -Version 5.1
# Windows dev toolbox bootstrap - idempotent, modular, agent-discoverable.
# Mirrors the structure of ai-dev-envbuild/bootstrap.sh for the Windows platform.
#
#   .\bootstrap.ps1                    run all default groups
#   .\bootstrap.ps1 -Only cli-tools    run only the named group(s) (comma-separated)
#   .\bootstrap.ps1 -DryRun            print what would be installed
#   .\bootstrap.ps1 -List              list groups and what each installs
#
# Run from PowerShell as your normal user (not elevated). winget installs that
# need elevation will prompt UAC automatically.
[CmdletBinding()]
param(
    [string]   $Only    = "",
    [switch]   $DryRun,
    [switch]   $List,
    [switch]   $Help,
    [switch]   $CleanLegacyState,
    [switch]   $RefreshToolbox,
    [switch]   $SkipHeavyToolboxBuild,
    [switch]   $SkipPlaywrightBrowsers
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT = $PSScriptRoot
. (Join-Path $REPO_ROOT "lib\common.ps1")
. (Join-Path $REPO_ROOT "lib\catalog.ps1")

$DEFAULT_GROUPS = @("cli-tools", "security", "extras")
$DEFAULT_TOOLBOX = Join-Path $env:LOCALAPPDATA "DevToolbox"
$KNOWN_OLD_TOOLBOX_ROOTS = @(
    (Join-Path $env:USERPROFILE "Documents\Codex\_codex-toolbox")
)
$CANONICAL_TOOLBOX = if ($env:CODEX_TOOLBOX -and
    -not ($KNOWN_OLD_TOOLBOX_ROOTS -contains $env:CODEX_TOOLBOX.TrimEnd('\'))) {
    [System.IO.Path]::GetFullPath($env:CODEX_TOOLBOX)
} else {
    $DEFAULT_TOOLBOX
}
$env:CODEX_TOOLBOX = $CANONICAL_TOOLBOX
Sync-EnvPath
# Locations a PREVIOUS clone may still occupy. Everything in this list is a candidate for
# -CleanLegacyState to delete recursively, so an entry that is wrong is a loaded gun.
#
# It was wrong. This list used to end with "D:\.ai-work\projects\scripts-utilities" under the
# comment "pre-2026-08-20 location, before the move to D:\.ai-work\projects" - but that path is
# the DESTINATION of that move and is where this repo lives now. Remove-OldRepositoryClone's
# three guards (owned clone, clean tree, not the running copy) all pass for it; the only reason
# it survived is that bootstrap normally runs FROM there. Following this repo's own documented
# installer (get.ps1 clones to %USERPROFILE%\scripts-utilities) and then taking its advice to
# pass -CleanLegacyState would have deleted the live repo, .git and all.
$KNOWN_OLD_REPO_ROOTS = @(
    (Join-Path $env:USERPROFILE "Documents\scripts-utilities")
)

# Summed across every group, so the last line of this script can tell the truth. Each
# <group>_install returns its failure count; printing "INCOMPLETE" inside the group was only
# half the fix, because Write-Err is Write-Host and produces no error record for anything
# upstream to notice.
$script:GROUP_FAILURES = 0
$AGENT_TARGETS = @(
    (Join-Path $env:USERPROFILE ".codex\AGENTS.md"),
    (Join-Path $env:USERPROFILE ".claude\CLAUDE.md"),
    (Join-Path $env:USERPROFILE "CLAUDE.md"),
    (Join-Path $env:USERPROFILE "AGENTS.md")
)

function Show-Usage {
    Write-Host @"
Usage: .\bootstrap.ps1 [options]

  (no options)        run all default groups: $($DEFAULT_GROUPS -join ', ')
  -Only G1,G2         run only these groups (comma-separated)
  -DryRun             print what would be installed without doing it
  -List               list groups and their contents, then exit
  -CleanLegacyState   explicitly remove recognized legacy toolbox state
  -RefreshToolbox     rerun the idempotent DevToolbox builder even if it is ready
  -SkipHeavyToolboxBuild
                      skip heavy/GPU Python packages if stage-1 toolbox build is needed
  -SkipPlaywrightBrowsers
                      skip browser binary install if stage-1 toolbox build is needed
  -Help               show this help
"@
}

function Remove-DirectorySafely {
    param(
        [string]$Path,
        [string]$ExpectedPath
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolved = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $expected = $ExpectedPath.TrimEnd('\')
    if ($resolved -ine $expected) {
        throw "Refusing to remove unexpected path: $resolved (expected $expected)"
    }
    if ($DryRun) {
        Write-Info "[DRY-RUN] would remove old toolbox directory: $resolved"
        return
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    Write-Ok "removed old toolbox directory: $resolved"
}

function Remove-GeneratedManifest {
    $manifestPath = Join-Path $REPO_ROOT "manifest\tools.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { return }
    if ($DryRun) {
        Write-Info "[DRY-RUN] would remove generated manifest: $manifestPath"
        return
    }
    Remove-Item -LiteralPath $manifestPath -Force
    Write-Ok "removed generated manifest: $manifestPath"
}

function Test-RepositoryLooksOwned {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath (Join-Path $Path ".git"))) { return $false }
    $remotes = & git -C $Path remote -v 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($remotes -match "bigfnj/scripts-utilities")
}

function Remove-OldRepositoryClone {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolved = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $current = (Resolve-Path -LiteralPath $REPO_ROOT).Path.TrimEnd('\')
    if ($resolved -ieq $current) { return }
    if (-not (Test-RepositoryLooksOwned -Path $resolved)) {
        throw "Refusing to remove old repo candidate that is not a recognized scripts-utilities clone: $resolved"
    }
    $status = & git -C $resolved status --short 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect old repo candidate: $resolved"
    }
    if ($status) {
        throw "Refusing to remove old scripts-utilities clone with local changes: $resolved"
    }
    if ($DryRun) {
        Write-Info "[DRY-RUN] would remove old scripts-utilities clone: $resolved"
        return
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    Write-Ok "removed old scripts-utilities clone: $resolved"
}

function Remove-StaleAgentBlocks {
    $pattern = "(?s)\r?\n?<!-- (?:CODEX_TOOLBOX|WIN_DEVTOOLS)_START -->.*?<!-- (?:CODEX_TOOLBOX|WIN_DEVTOOLS)_END -->\r?\n?"
    foreach ($file in $AGENT_TARGETS) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        $cleaned = $content -replace $pattern, ""
        if ($cleaned -eq $content) { continue }
        if ($DryRun) {
            Write-Info "[DRY-RUN] would remove stale agent block(s): $file"
            continue
        }
        $backup = "$file.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $file -Destination $backup -Force
        Set-Content -LiteralPath $file -Value $cleaned.Trim() -Encoding UTF8
        Write-Ok "removed stale agent block(s): $file"
    }
}

function Remove-StaleCodexToolboxEnv {
    foreach ($scope in @("User", "Machine")) {
        $value = [System.Environment]::GetEnvironmentVariable("CODEX_TOOLBOX", $scope)
        if (-not $value) { continue }
        if ($value.TrimEnd('\') -ieq $CANONICAL_TOOLBOX.TrimEnd('\')) { continue }
        if ($DryRun) {
            Write-Info "[DRY-RUN] would clear stale $scope CODEX_TOOLBOX=$value"
            continue
        }
        try {
            [System.Environment]::SetEnvironmentVariable("CODEX_TOOLBOX", $null, $scope)
            Write-Ok "cleared stale $scope CODEX_TOOLBOX=$value"
        } catch {
            throw "Failed to clear stale $scope CODEX_TOOLBOX=$value. Run from an elevated PowerShell or clear it manually."
        }
    }
    $env:CODEX_TOOLBOX = $CANONICAL_TOOLBOX
}

function Remove-StalePathEntries {
    $oldPrefixes = @($KNOWN_OLD_TOOLBOX_ROOTS | ForEach-Object { $_.TrimEnd('\') })
    foreach ($scope in @("User", "Machine")) {
        $pathValue = [System.Environment]::GetEnvironmentVariable("PATH", $scope)
        if (-not $pathValue) { continue }
        $entries = @($pathValue -split ';' | Where-Object { $_ })
        $kept = @()
        $removed = @()
        foreach ($entry in $entries) {
            $trimmed = $entry.TrimEnd('\')
            $isOld = $false
            foreach ($prefix in $oldPrefixes) {
                if ($trimmed -ieq $prefix -or $trimmed.StartsWith($prefix + "\", [StringComparison]::OrdinalIgnoreCase)) {
                    $isOld = $true
                    break
                }
            }
            if ($isOld) { $removed += $entry } else { $kept += $entry }
        }
        if ($removed.Count -eq 0) { continue }
        if ($DryRun) {
            Write-Info "[DRY-RUN] would remove stale $scope PATH entries: $($removed -join '; ')"
            continue
        }
        try {
            [System.Environment]::SetEnvironmentVariable("PATH", ($kept -join ';'), $scope)
            Write-Ok "removed stale $scope PATH entries"
        } catch {
            throw "Failed to remove stale $scope PATH entries. Run from an elevated PowerShell or remove them manually: $($removed -join '; ')"
        }
    }
    Sync-EnvPath
}

function Test-OldToolchainDetected {
    foreach ($path in $KNOWN_OLD_REPO_ROOTS) {
        if (Test-Path -LiteralPath $path) {
            $resolved = (Resolve-Path -LiteralPath $path).Path.TrimEnd('\')
            $current = (Resolve-Path -LiteralPath $REPO_ROOT).Path.TrimEnd('\')
            if ($resolved -ine $current) { return $true }
        }
    }
    foreach ($path in $KNOWN_OLD_TOOLBOX_ROOTS) {
        if (Test-Path -LiteralPath $path) { return $true }
    }
    foreach ($scope in @("User", "Machine")) {
        $value = [System.Environment]::GetEnvironmentVariable("CODEX_TOOLBOX", $scope)
        if ($value -and ($value.TrimEnd('\') -ine $CANONICAL_TOOLBOX.TrimEnd('\'))) { return $true }
        $pathValue = [System.Environment]::GetEnvironmentVariable("PATH", $scope)
        foreach ($oldRoot in $KNOWN_OLD_TOOLBOX_ROOTS) {
            if ($pathValue -and ($pathValue -like "*$oldRoot*")) { return $true }
        }
    }
    foreach ($file in $AGENT_TARGETS) {
        if (Test-Path -LiteralPath $file) {
            if (Select-String -LiteralPath $file -Pattern "CODEX_TOOLBOX_START" -Quiet) { return $true }
        }
    }
    return $false
}

function Invoke-OldToolchainCleanup {
    if (-not (Test-OldToolchainDetected)) {
        Write-Skip "no known old toolbox artifacts detected"
        return
    }
    if (-not $CleanLegacyState) {
        throw @"
Recognized legacy toolbox state was detected. No cleanup was performed.
Review '.\bootstrap.ps1 -DryRun -CleanLegacyState', then rerun with
-CleanLegacyState only when you intend to remove the old managed artifacts.
"@
    }
    Write-Group "old toolbox cleanup"
    foreach ($path in $KNOWN_OLD_REPO_ROOTS) {
        Remove-OldRepositoryClone -Path $path
    }
    foreach ($path in $KNOWN_OLD_TOOLBOX_ROOTS) {
        Remove-DirectorySafely -Path $path -ExpectedPath $path
    }
    Remove-StaleAgentBlocks
    Remove-StaleCodexToolboxEnv
    Remove-StalePathEntries
    Remove-GeneratedManifest
    if ($DryRun) {
        Write-Info "[DRY-RUN] cleanup validation skipped because no changes were made"
    } else {
        Assert-OldToolchainClean
    }
}

function Assert-OldToolchainClean {
    $problems = @()
    foreach ($path in $KNOWN_OLD_REPO_ROOTS) {
        if (Test-Path -LiteralPath $path) {
            $resolved = (Resolve-Path -LiteralPath $path).Path.TrimEnd('\')
            $current = (Resolve-Path -LiteralPath $REPO_ROOT).Path.TrimEnd('\')
            if ($resolved -ine $current) {
                $problems += "old scripts-utilities clone remains: $resolved"
            }
        }
    }
    foreach ($path in $KNOWN_OLD_TOOLBOX_ROOTS) {
        if (Test-Path -LiteralPath $path) { $problems += "old toolbox path remains: $path" }
    }
    foreach ($scope in @("User", "Machine")) {
        $value = [System.Environment]::GetEnvironmentVariable("CODEX_TOOLBOX", $scope)
        if ($value -and ($value.TrimEnd('\') -ine $CANONICAL_TOOLBOX.TrimEnd('\'))) {
            $problems += "stale $scope CODEX_TOOLBOX remains: $value"
        }
        $pathValue = [System.Environment]::GetEnvironmentVariable("PATH", $scope)
        foreach ($oldRoot in $KNOWN_OLD_TOOLBOX_ROOTS) {
            if ($pathValue -and ($pathValue -like "*$oldRoot*")) {
                $problems += "stale $scope PATH entry references: $oldRoot"
            }
        }
    }
    foreach ($file in $AGENT_TARGETS) {
        if (Test-Path -LiteralPath $file) {
            if (Select-String -LiteralPath $file -Pattern "CODEX_TOOLBOX_START" -Quiet) {
                $problems += "stale CODEX_TOOLBOX block remains in: $file"
            }
        }
    }
    if ($problems.Count -gt 0) {
        throw "Old toolbox cleanup validation failed:`n$($problems -join "`n")"
    }
    Write-Ok "old toolbox cleanup validation passed"
}

function Register-ToolboxUserPath {
    # Make the durable toolbox layer resolvable by bare name in ANY new shell -
    # not only ones that dot-source the activation script. Each PowerShell tool
    # call an agent makes is a fresh process with no inherited session state, so
    # per-session activation does not carry across calls; a persistent user-scope
    # PATH entry does. Uses the user scope per docs/agent-rules.md (never machine).
    $toolboxRoot = $CANONICAL_TOOLBOX

    # Expose the venv CLIs by wrapping them into native\bin, so we do NOT put the
    # venv Scripts dir (which also holds python.exe) on the persistent PATH. The
    # 3.11 interpreter must stay off PATH for compliance - see New-VenvCliWrappers.
    New-VenvCliWrappers

    $targets = @(
        (Join-Path $toolboxRoot "native\bin"),   # native CLIs + wrapped venv CLIs
        (Join-Path $toolboxRoot "sysinternals")  # procdump, handle, sigcheck, ... (appended last)
    )
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t)) { continue }
        if ($DryRun) { Write-Info "[DRY-RUN] would add user PATH entry: $t"; continue }
        Add-UserPathEntry $t | Out-Null
    }

    # Expose the toolbox's Python 3.11 explicitly - NOT on PATH. Agents and other
    # tools call $env:TOOLBOX_PYTHON directly; a bare 'python' stays the sanctioned
    # system interpreter, and no 3.11 python.exe is registered or on PATH.
    $venvPython = Join-Path $toolboxRoot "python\.venv\Scripts\python.exe"
    if (Test-Path -LiteralPath $venvPython) {
        $curPy = [System.Environment]::GetEnvironmentVariable("TOOLBOX_PYTHON", "User")
        if ($curPy -ne $venvPython) {
            if ($DryRun) {
                Write-Info "[DRY-RUN] would set User TOOLBOX_PYTHON=$venvPython"
            } else {
                [System.Environment]::SetEnvironmentVariable("TOOLBOX_PYTHON", $venvPython, "User")
                Write-Ok "TOOLBOX_PYTHON -> $venvPython"
            }
        }
        $env:TOOLBOX_PYTHON = $venvPython
    }

    # tesseract reads TESSDATA_PREFIX to find its language data; persist it so OCR
    # works from a bare shell without activating the toolbox.
    $tessdata = Join-Path $toolboxRoot "native\tesseract\tessdata"
    # Test-Path on the DIRECTORY is not enough. The 2026-09-09 rebuild created this directory
    # empty, so the guard passed and TESSDATA_PREFIX was pointed at a tessdata holding no
    # language data -- which breaks OCR HARDER than leaving the variable unset, because an
    # absent TESSDATA_PREFIX lets tesseract fall back to its own install-relative tessdata.
    # Every tesseract call on the box then died with "Failed loading language 'eng'".
    # Require real language data before claiming the toolbox owns the path.
    #
    # Counting by NAME is not enough either, which is the other half of the same bug:
    # Get-Download used to throw on a short file without deleting it, so this directory can
    # hold zero-byte .traineddata corpses that satisfy a name filter and load nothing. 100KB
    # is the floor scripts\build-devtoolbox.ps1 downloads against (tessdata_fast's smallest
    # language is around 1MB, so the floor rejects only partials). eng is required BY NAME
    # because it is the implicit default for every caller that does not pass -l - a tessdata
    # holding only, say, jpn would pass a count check and still fail every default OCR call.
    $langFiles = @(Get-ChildItem -LiteralPath $tessdata -Filter '*.traineddata' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge 100KB })
    $hasLangData = ($langFiles.Count -gt 0) -and
        (@($langFiles | Where-Object { $_.Name -eq 'eng.traineddata' }).Count -gt 0)
    if ($hasLangData) {
        $current = [System.Environment]::GetEnvironmentVariable("TESSDATA_PREFIX", "User")
        if ($current -ne $tessdata) {
            if ($DryRun) {
                Write-Info "[DRY-RUN] would set User TESSDATA_PREFIX=$tessdata"
            } else {
                [System.Environment]::SetEnvironmentVariable("TESSDATA_PREFIX", $tessdata, "User")
                Write-Ok "TESSDATA_PREFIX -> $tessdata"
            }
        }
        $env:TESSDATA_PREFIX = $tessdata
    } else {
        # Saying nothing was the rest of the original defect: OCR simply did not work and no
        # run ever mentioned why. Leaving TESSDATA_PREFIX unset is still the better of the
        # two bad states - tesseract then falls back to its install-relative tessdata - but
        # it is a broken toolbox either way, and a bootstrap that noticed has to say so.
        Write-Warn "no usable tesseract language data in $tessdata (need eng.traineddata, 100KB or larger) - leaving TESSDATA_PREFIX unset; re-run scripts\build-devtoolbox.ps1 to fetch it"
    }

    # Make node/npm trust the OS certificate store (incl. a corporate TLS-
    # interception root CA) BEFORE the extras group runs npm - otherwise
    # 'npm install' fails/hangs on the registry behind SSL inspection.
    Set-NodeSystemCaBundle
}

function Get-ModuleFile { param([string]$Group) Join-Path $REPO_ROOT "modules\$Group.ps1" }

function Invoke-Group {
    param([string]$Group)
    $f = Get-ModuleFile $Group
    if (-not (Test-Path $f)) {
        Write-Warn "group '$Group' not implemented (no $f) - skipping"
        return
    }
    Write-Group $Group
    . $f
    $fn = "${Group}_install"
    if (Get-Command $fn -ErrorAction SilentlyContinue) {
        # A group that installs nothing successfully must not be indistinguishable from one
        # that installs everything. The modules return a failure count; anything else they
        # emit is output to be discarded.
        $r = @(& $fn)
        $n = 0
        foreach ($x in $r) { if ($x -is [int]) { $n = [int]$x } }
        $script:GROUP_FAILURES += $n
    } else {
        Write-Warn "module '$Group' defines no ${fn}() - skipping"
    }
}

function Show-Groups {
    foreach ($g in $DEFAULT_GROUPS) {
        $f = Get-ModuleFile $g
        if (Test-Path $f) {
            . $f
            $fn = "${g}_desc"
            $desc = if (Get-Command $fn -ErrorAction SilentlyContinue) { & $fn } else { "(no description)" }
        } else {
            $desc = "(not implemented yet)"
        }
        Write-Host ("  {0,-16} {1}" -f $g, $desc)
    }
}

function Test-DevToolboxReady {
    $toolboxRoot = $CANONICAL_TOOLBOX
    if (-not (Test-Path -LiteralPath $toolboxRoot)) {
        if ($DryRun) {
            Write-Info "[DRY-RUN] would create DevToolbox root: $toolboxRoot"
        } else {
            New-Item -ItemType Directory -Path $toolboxRoot -Force | Out-Null
            Write-Ok "created DevToolbox root: $toolboxRoot"
        }
    }
    $py = Join-Path $toolboxRoot "python\.venv\Scripts\python.exe"
    $manifest = Join-Path $toolboxRoot "toolbox-manifest.json"
    if ((Test-Path $py) -and (Test-Path $manifest) -and -not $RefreshToolbox) {
        return
    }

    $builder = Join-Path $REPO_ROOT "scripts\build-devtoolbox.ps1"
    if (-not (Test-Path -LiteralPath $builder)) {
        throw "DevToolbox is not ready and builder is missing: $builder"
    }
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would build DevToolbox with: $builder"
        return
    }
    Write-Group "build DevToolbox"
    $args = @("-ExecutionPolicy", "Bypass", "-File", $builder, "-Root", $toolboxRoot)
    if ($SkipHeavyToolboxBuild) { $args += "-SkipHeavy" }
    if ($SkipPlaywrightBrowsers) { $args += "-SkipPlaywrightBrowsers" }
    & powershell.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "DevToolbox build failed (exit $LASTEXITCODE)"
    }
    if (-not ((Test-Path $py) -and (Test-Path $manifest))) {
        throw "DevToolbox build completed but required files are missing: $py, $manifest"
    }
}

# -- Main ----------------------------------------------------------------------
if ($Help) { Show-Usage; exit 0 }
if ($List)  { Show-Groups; exit 0 }

if ($DryRun) {
    $script:DryRun = $true
    Write-Info "[DRY-RUN] mode - nothing will be installed"
}

$groups = if ($Only) { $Only -split ',' | ForEach-Object { $_.Trim() } }
          else        { $DEFAULT_GROUPS }

Write-Group "bootstrap"
Write-Info "groups: $($groups -join ', ')"
Invoke-OldToolchainCleanup
Test-DevToolboxReady

Write-Group "toolbox PATH registration"
Register-ToolboxUserPath

foreach ($g in $groups) { Invoke-Group $g }

if (-not $script:DryRun) {
    Write-Group "agent discovery"
    Write-AgentDiscovery -RepoRoot $REPO_ROOT
}

Write-Group "done"
# An EXPLICIT exit on both paths. bootstrap.ps1 previously fell off the end with no exit at
# all, so it inherited the exit code of whatever native command it happened to run last - which
# is why fresh-toolbox-setup-runner.ps1 had to stop trusting it. Now the code means something,
# and the runner can go back to reading it.
if ($script:GROUP_FAILURES -gt 0) {
    Write-Err ("bootstrap INCOMPLETE - {0} tool(s) failed to install. Fix those, then re-run; " -f $script:GROUP_FAILURES)
    Write-Err "this script is idempotent, so a re-run only retries what is missing."
    exit 1
}
Write-Ok "bootstrap complete - run '.\scripts\smoke-test.ps1' to verify"
exit 0
