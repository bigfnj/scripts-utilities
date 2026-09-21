#Requires -Version 5.1
<#
Report whether THIS process sees the dev toolbox through a packaged host's projected view,
and whether pip can consequently run.

Run it from two places and compare. The difference IS the finding:

  .\scripts\test-host-projection.ps1                          # from wherever you are now
  .\scripts\run-unprojected.ps1 .\scripts\test-host-projection.ps1   # via Task Scheduler

WHAT THIS MEASURES, and why it is not a vendor bug. An agent host installed as an MSIX package
has %LOCALAPPDATA% and %APPDATA% projected into its own Packages\<pkg>\LocalCache\ tree, and
every process it launches inherits that view - including a plain powershell.exe that has no
package identity of its own. There is ONE set of files; only the name the filesystem calls
canonical changes, and it changes asymmetrically: a FILE resolves to the package name, its
PARENT DIRECTORY does not.

pip 26.2.1 vendors distlib 0.4.2, whose ResourceFinder._is_in_base compares exactly those two
values with startswith. They disagree under a projected view, so every resource lookup raises
"Resource name escapes package" and `pip install` cannot run at all.

Measured 2026-09-21 on this box, projected side vs Task Scheduler side:

  canonical name    ...\Packages\<pkg>\LocalCache\Local\DevToolbox\...  vs  ...\AppData\Local\DevToolbox\...
  realpath dir/file DISAGREE                                            vs  AGREE
  distlib import    FAILED                                              vs  OK
  pip install       exit 2, cannot run                                  vs  works
  shim count        156, identical targets                              vs  156, identical targets

One real toolbox tree, not a divergent shadow. Only path RESOLUTION differs.

Ruled out, so nobody re-derives them: no reparse point on any component of either path; no
package identity on the shell (GetCurrentPackageFullName -> APPMODEL_ERROR_NO_PACKAGE); not two
hardlinks - fsutil reports exactly one name and it is the package one.

Exit code: 0 when the view is clean, 1 when projected, 2 when it could not be measured.
#>
[CmdletBinding()]
param(
    # Where to write the verdict as well as stdout. Defaults beside the repo's other logs.
    [string]$Out = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')

$lines = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Key, $Value) $lines.Add(("{0,-22} {1}" -f $Key, $Value)) }

$root = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }

Add-Line 'measured-at'  (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
Add-Line 'identity'     ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
Add-Line 'host-process' (Get-Process -Id $PID).Path
Add-Line 'LOCALAPPDATA' $env:LOCALAPPDATA
Add-Line 'toolbox-root' $root

$verdict = Test-HostPathProjection
Add-Line 'probe'        $verdict.Probe
Add-Line 'canonical'    $verdict.Canonical
Add-Line 'projected'    $(if ($null -eq $verdict.IsProjected) { 'UNKNOWN' } elseif ($verdict.IsProjected) { 'YES' } else { 'no' })
if ($verdict.PackageRoot) { Add-Line 'package-root' $verdict.PackageRoot }
Add-Line 'reason'       $verdict.Reason

# The consequence, measured rather than inferred. VIA A FILE, never `python -c "..."`:
# PowerShell re-parses a native command's arguments and strips the inner quotes, so the first
# draft of this reached python as `print(realpath-dir` and died with "'(' was never closed" - a
# probe that reports a SyntaxError where the measurement should be is worse than one that does
# not run at all.
$py = Get-ToolboxPython
if ($py) {
    Add-Line 'python' $py
    # Beside the log, not in $env:TEMP: TEMP is the 8.3 short form here
    # (C:\Users\JUSTIN~1.LOW\...) and Remove-Item -LiteralPath will not expand a short name, so
    # cleanup failed with "An object at the specified path does not exist".
    $logDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $pyFile = Join-Path $logDir 'host-projection-probe.py'
    @'
import os
import pip._vendor.distlib as d
b = os.path.dirname(d.__file__)
print("realpath-dir   " + os.path.realpath(b))
print("realpath-file  " + os.path.realpath(os.path.join(b, "scripts.py")))
# The import distlib performs for any real install. --dry-run does NOT reach it, which is why a
# dry-run probe reports a healthy pip on a box where `pip install` cannot run at all.
try:
    import pip._vendor.distlib.scripts  # noqa: F401
    print("distlib-import OK")
except Exception as e:
    print("distlib-import FAILED: %s: %s" % (type(e).__name__, e))
'@ | Set-Content -LiteralPath $pyFile -Encoding UTF8
    $r = Invoke-Native -FilePath $py -Arguments @($pyFile)
    foreach ($l in @($r.Output)) { $lines.Add("                       $l") }
    Remove-Item -LiteralPath $pyFile -ErrorAction SilentlyContinue
} else {
    Add-Line 'python' 'ABSENT - cannot measure the pip consequence'
}

$text = ($lines -join [Environment]::NewLine)
Write-Host $text
if ($Out) {
    Set-Content -LiteralPath $Out -Value $text -Encoding UTF8
    Write-Host ''
    Write-Host "written to $Out" -ForegroundColor Green
}

if ($null -eq $verdict.IsProjected) { exit 2 }
if ($verdict.IsProjected) { exit 1 }
exit 0
