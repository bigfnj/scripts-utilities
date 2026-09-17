#Requires -Version 5.1
<#
Install the `browse` CLI (tools/browse) into the DevToolbox venv.

`browse <url>` fetches a page for reading and escalates only as far as it has to:
httpx, then an opt-in third-party reader, then a CDP attach to the real Chrome
started by scripts/start-browse-chrome.ps1. See docs/tools-reference.md for usage
and docs/agent-rules.md for what it is and is not allowed to do.

  .\scripts\install-browse.ps1                # install/refresh browse
  .\scripts\install-browse.ps1 -WithExtras    # also install trafilatura + curl_cffi
  .\scripts\install-browse.ps1 -DryRun        # print, change nothing

WHY A PIP PACKAGE AND NOT A LOOSE .py LIKE rerank.py. The console script pip
generates in the venv Scripts dir is what New-VenvCliWrappers (lib/common.ps1)
wraps into native\bin, with the same single-quoted-target byte shape as the other
172 shims. A loose script would need a two-argument wrapper ("python.exe"
"browse.py" %*), which Get-ShimTarget cannot parse - so the smoke test's
stale-shim check would skip it silently, and this repo does not ship controls
that cannot fire. Measured 2026-09-17: 172 of 172 shims in native\bin match the
contract, so there is no precedent to follow for an exception.

The two optional upgrades are catalog.json entries rather than pyproject
dependencies, so they install through the pip-toolbox channel and land in
manifest/tools.json like every other Python package here. browse runs without
either and says so on every run when one is missing.
#>
[CmdletBinding()]
param(
    [string]$Root = $(if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }),
    [switch]$WithExtras,
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot "lib\common.ps1")
. (Join-Path $repoRoot "lib\catalog.ps1")

# lib\common.ps1 gates its dry-run behaviour on a script-scoped flag, so the
# switch has to be handed over rather than merely held here.
$script:DryRun = [bool]$DryRun

$pkg = Join-Path $repoRoot "tools\browse"
if (-not (Test-Path -LiteralPath (Join-Path $pkg "pyproject.toml"))) {
    throw "No package at $pkg - this script must run from inside the repo."
}

$py = Get-ToolboxPython
if (-not $py) {
    throw "Toolbox Python not found. Build it first: .\scripts\build-devtoolbox.ps1 (or set CODEX_TOOLBOX)."
}

Write-Group "browse"

if ($WithExtras) {
    # Through the catalog, so the manifest records them and a later smoke run can
    # see them. Absent entries are a hard error rather than a skip: -WithExtras
    # that silently installs nothing is the shape this repo keeps removing.
    foreach ($name in @('trafilatura', 'curl_cffi')) {
        $item = Get-CatalogItem -Name $name
        if (-not $item) { throw "catalog.json has no entry named '$name' - add it before using -WithExtras." }
        Install-CatalogItem -Item $item | Out-Null
    }
}

if ($DryRun) {
    Write-Info "[DRY-RUN] would: pip install --upgrade --no-deps $pkg"
    Write-Info "[DRY-RUN] would wrap the browse console script into $Root\native\bin"
    return
}

# --no-deps because pyproject declares none on purpose (see its comment) and a
# resolver run here could pull an untracked package into the shared venv.
# --upgrade so a re-run after an edit actually replaces the installed copy; a
# plain install is a no-op once the version matches and would hand back a stale
# CLI that looks freshly installed.
Write-Info "pip install --upgrade --no-deps $pkg"
& $py -m pip install --upgrade --no-deps $pkg --quiet
if ($LASTEXITCODE -ne 0) { throw "pip install failed for $pkg (exit $LASTEXITCODE)" }

New-VenvCliWrappers
Sync-EnvPath

$shim = Join-Path $Root "native\bin\browse.cmd"
if (-not (Test-Path -LiteralPath $shim)) {
    throw "pip install succeeded but no shim at $shim - did the console script name change in pyproject.toml?"
}

# The shim has to satisfy the same reader the smoke test uses, or the stale-shim
# check quietly stops covering it. Asserted here, at the only moment where the
# cause would be obvious.
$target = Get-ShimTarget -Lines @(Get-Content -LiteralPath $shim)
if (-not $target) {
    throw "the browse shim at $shim does not match the Get-ShimTarget contract - the smoke test would skip it"
}
if (-not (Test-Path -LiteralPath $target)) {
    throw "the browse shim points at a missing target: $target"
}

Write-Ok "browse installed -> $target"

# Verify through the SHIM, not through the interpreter. Calling python directly
# would pass while a broken wrapper left `browse` unusable, which is the only
# way anyone actually invokes it.
& $shim --selftest
if ($LASTEXITCODE -ne 0) {
    throw "browse --selftest failed (exit $LASTEXITCODE) - the extraction check is the one that must pass"
}
Write-Ok "browse --selftest passed"
Write-Info "usage:  browse <url>   |   browse <url> --json   |   browse --selftest"
Write-Info "browser rung: .\scripts\start-browse-chrome.ps1 then browse <url> --rung chrome"
