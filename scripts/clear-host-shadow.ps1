#Requires -Version 5.1
<#
Delete a packaged agent host's SHADOW COPY of the toolbox, so its view falls through to the
real one again.

THE CONDITION. An MSIX-packaged host redirects %LOCALAPPDATA% and %APPDATA% for every process
it launches, and the redirection is COPY-ON-WRITE: a read falls through to the real location,
but anything WRITTEN lands in <package>\LocalCache\ and shadows the real file from then on. So
a toolbox built once from inside such a host leaves a private copy behind, and every later
session of that host reads the copy - while every normal shell reads the real tree. The two
drift apart silently and neither side can see the other's version of a file.

Measured on this box, 2026-09-21, after rebuilding the real toolbox from a Task Scheduler
process:

  real      %LOCALAPPDATA%\DevToolbox\native\bin                          162 shims, all repaired
  shadow    ...\Packages\<pkg>\LocalCache\Local\DevToolbox\native\bin     137 shims, 2026-08-07,
                                                                          six of them still
                                                                          self-referential

and an agent session reading the second of those reported six broken shims on a machine whose
real toolbox had none. %APPDATA%\npm shadows the same way, which is how markdownlint can be on
PATH for the agent and absent for the user.

WHAT THIS DELETES is the host's redirected COPY of directories this repository owns - the
toolbox and the npm global prefix - and nothing else in the container. The copy is disposable
by definition: LocalCache is cache, and the real tree is the source of truth. It is still
another application's data directory, so this refuses to run unless the real tree is present
and populated, and it prints everything before removing it.

  .\scripts\clear-host-shadow.ps1 -DryRun     # report what would go, change nothing
  .\scripts\clear-host-shadow.ps1             # remove it

RUN IT UNPROJECTED. From inside the host being cleaned, the paths below are themselves subject
to the redirection this script exists to undo, and a delete could resolve to the real tree. It
refuses in that case; use scripts\run-unprojected.ps1.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,

    # Normally discovered. Pass one to clean a specific package only.
    [string]$PackageRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')

$realToolbox = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
$realNpm = Join-Path $env:APPDATA 'npm'

# 1. Refuse to run through the very redirection being cleaned.
$projection = Test-HostPathProjection
if ($projection.IsProjected) {
    Write-Err "this shell sees a projected view ($($projection.PackageRoot))."
    Write-Err "Deleting package paths from in here can resolve to the real tree. Re-run via:"
    Write-Err "  .\scripts\run-unprojected.ps1 .\scripts\clear-host-shadow.ps1"
    exit 2
}

# 2. Refuse if the real toolbox is not there to fall through TO. Without this the script is a
#    plain uninstaller wearing a repair's name.
$realBin = Join-Path $realToolbox 'native\bin'
$realShims = @(Get-ChildItem -LiteralPath $realBin -Filter '*.cmd' -File -ErrorAction SilentlyContinue).Count
if ($realShims -lt 1) {
    Write-Err "the real toolbox at $realToolbox has no shims - refusing to delete the only copy."
    Write-Err "Build it first: .\scripts\run-unprojected.ps1 .\bootstrap.ps1 -ScriptArgs '-RefreshToolbox'"
    exit 2
}
Write-Ok "real toolbox present: $realShims shim(s) in $realBin"

# 3. Discover shadows. HOST-AGNOSTIC: any package, not a known id - see
#    $script:ProjectedViewPattern in lib\common.ps1 for why that matters.
$packagesDir = Join-Path $env:LOCALAPPDATA 'Packages'
$roots = if ($PackageRoot) { @($PackageRoot) }
         else { @(Get-ChildItem -LiteralPath $packagesDir -Directory -ErrorAction SilentlyContinue |
                   ForEach-Object { $_.FullName }) }

$targets = @()
foreach ($root in $roots) {
    foreach ($rel in @('LocalCache\Local\DevToolbox', 'LocalCache\Roaming\npm')) {
        $p = Join-Path $root $rel
        if (Test-Path -LiteralPath $p) {
            $files = @(Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue)
            $bytes = ($files | Measure-Object -Property Length -Sum).Sum
            $targets += [pscustomobject]@{
                Path  = $p
                Files = $files.Count
                MB    = [math]::Round(([double]$bytes) / 1MB, 1)
            }
        }
    }
}

if (-not $targets.Count) {
    Write-Ok "no packaged-host shadow of the toolbox or the npm prefix found - nothing to do"
    exit 0
}

Write-Host ''
Write-Host 'Shadow copies found:' -ForegroundColor White
foreach ($t in $targets) {
    Write-Host ("  {0,8:N1} MB  {1,6} file(s)  {2}" -f $t.MB, $t.Files, $t.Path)
}
Write-Host ''

if ($DryRun) {
    Write-Info "[DRY-RUN] would remove the $($targets.Count) path(s) above; nothing changed"
    exit 0
}

# Remove-Item gives up at MAX_PATH, and a shadow of this toolbox is guaranteed to exceed it:
# measured 2026-09-21, the delete died on
#   ...\jupyterlab\galata\@jupyterlab\galata-extension\static\vendors-node_modules_fontsource-
#   variable_noto-sans-sc_index_css.386da7677f8b1f52.js
# reported, misleadingly, as "Could not find a part of the path".
#
# Mirroring an EMPTY directory over the target with robocopy is the long-standing way round it:
# robocopy uses the extended-length API throughout, so it empties the tree whatever the depth,
# and the now-empty root deletes normally. Exit codes below 8 are all success variants.
function Remove-TreeLongPath {
    param([Parameter(Mandatory)][string]$Path)
    $empty = Join-Path ([IO.Path]::GetTempPath()) ('su-empty-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    try {
        $r = Invoke-Native -FilePath 'robocopy.exe' `
            -Arguments @($empty, $Path, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/R:1', '/W:1')
        if ($r.ExitCode -ge 8) { throw "robocopy mirror failed (exit $($r.ExitCode))" }
        Remove-Item -LiteralPath $Path -Recurse -Force
    } finally {
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$removed = 0
foreach ($t in $targets) {
    try {
        try {
            Remove-Item -LiteralPath $t.Path -Recurse -Force
        } catch {
            Write-Info "Remove-Item could not finish ($($_.Exception.Message.Split([char]58)[0])); retrying with a robocopy mirror"
            Remove-TreeLongPath -Path $t.Path
        }
        Write-Ok "removed $($t.Path)"
        $removed++
    } catch {
        # A running host can hold a handle. Report and keep going: a partial clean still
        # narrows the divergence, and the caller needs to know which one survived.
        Write-Err "could not remove $($t.Path): $($_.Exception.Message)"
    }
}

Write-Host ''
if ($removed -eq $targets.Count) {
    Write-Ok "$removed of $($targets.Count) shadow path(s) removed - the host now falls through to the real tree"
    exit 0
}
Write-Err "$removed of $($targets.Count) removed; close the host holding the rest and re-run"
exit 1
