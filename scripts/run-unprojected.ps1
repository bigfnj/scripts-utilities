#Requires -Version 5.1
<#
Run a PowerShell script in a process THIS process did not spawn, and wait for it.

Why this exists. An agent host packaged as MSIX projects %LOCALAPPDATA% and %APPDATA%
into its own Packages\<pkg>\LocalCache\ tree for every process it launches. The files are
the same files - one hardlink name, same bytes - but os.path.realpath reports the package
name for a FILE and the unredirected name for its PARENT DIRECTORY. distlib 0.4.2 compares
exactly those two values with startswith (ResourceFinder._is_in_base), so under such a host
EVERY pip resource lookup raises "Resource name escapes package" and pip install cannot run
at all. See docs\agent-rules.md and scripts\test-host-projection.ps1 for the measurement.

The escape is to have something other than the agent host create the process. Task Scheduler
is the cheapest such thing that still runs as the logged-on user with the real user profile:
    - -LogonType Interactive needs no password and no elevation
    - the task's process is a child of the scheduler service, so it inherits no projection
    - it is registered, run and unregistered within one call, leaving nothing behind

Rejected: a SYSTEM/TrustedInstaller helper. It escapes the projection too, but it runs as a
different principal, so %LOCALAPPDATA% resolves to a service profile and a per-user toolbox
build would write into the wrong tree - or into C:\Windows\system32\config\systemprofile.

  .\scripts\run-unprojected.ps1 .\scripts\test-host-projection.ps1
  .\scripts\run-unprojected.ps1 .\bootstrap.ps1 -ScriptArgs '-RefreshToolbox' -TimeoutSeconds 5400

Exit code is the child's own. 124 means the timeout fired with the child still running.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Script,

    # Passed through verbatim to the child. One string, because Task Scheduler takes one
    # argument line anyway and splitting it here would only invent a second quoting layer.
    [string]$ScriptArgs = "",

    [string]$LogPath = "",

    [int]$TimeoutSeconds = 3600,

    # Unique per run. Two concurrent callers must not share a task name, and a crashed run
    # must not leave a name that blocks the next one.
    [string]$TaskName = ("SU-Unprojected-{0}" -f $PID)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $repoRoot "logs"
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# UNIQUE PER RUN, not per second. $TaskName is already keyed on $PID, but the two FILES this
# script generates were keyed on a seconds-resolution timestamp - so two runs starting in the
# same second shared both, and the first to finish deleted the wrapper the second was executing.
$runId = '{0}-{1}' -f $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8))
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not $LogPath) { $LogPath = Join-Path $logDir ("unprojected-{0}-{1}.log" -f $stamp, $runId) }

# THE WRAPPER LIVES OUTSIDE THE REPOSITORY, and that is not tidiness.
#
# scripts\smoke-test.ps1's parse sweep is Get-ChildItem $REPO_ROOT -Recurse -Filter *.ps1 with
# exactly one exclusion (.claude\worktrees\), so logs\ is swept despite being gitignored. A
# generated wrapper sitting there makes the "all N .ps1 file(s) parse" count nondeterministic,
# and a wrapper that FAILED to parse would mint a stable failure identity - which the failids
# column then reports as a NEW FAILURE and hard-fails the gate, for a file no commit can fix.
# A run killed before its finally would leave it there for every later sweep.
$wrapper = Join-Path ([IO.Path]::GetTempPath()) ("su-unprojected-{0}.ps1" -f $runId)

# A SEPARATE, FRESH sentinel file rather than a marker line inside the log. The child APPENDS
# to the log and nothing clears a caller-supplied -LogPath, so a log already ending in a
# sentinel from an earlier run satisfied the very first poll: this script announced success,
# unregistered a task that had barely started, and deleted the wrapper out from under the
# running child.
$donePath = Join-Path ([IO.Path]::GetTempPath()) ("su-unprojected-{0}.done" -f $runId)
Remove-Item -LiteralPath $donePath -ErrorAction SilentlyContinue

$target = (Resolve-Path -LiteralPath $Script).Path
$sentinel = "__SU_UNPROJECTED_DONE__"

# Paths reach the generated wrapper as single-quoted PowerShell literals, so an apostrophe
# anywhere in the repo path, the target path or the log path would end the literal early and
# produce a wrapper that does not parse. Doubling is the escape single-quoted literals use.
function ConvertTo-PSLiteral {
    param([string]$Value)
    "'" + ($Value -replace "'", "''") + "'"
}

# The child re-runs the target and records its output plus an exit code we can trust.
#
# START-TRANSCRIPT, NOT `*>&1 | Out-File`, AND THIS IS NOT A STYLE CHOICE. The redirection
# version changed the SEMANTICS OF THE TARGET: under `*>&1`, PowerShell 5.1 treats a native
# command's stderr inside the target as a redirected stream, which under the target's own
# $ErrorActionPreference='Stop' raises a terminating NativeCommandError even on success. That
# is the trap lib\common.ps1's Invoke-Native header documents, reached from the outside.
#
# Measured 2026-09-21: `bootstrap.ps1 -RefreshToolbox` died at bootstrap.ps1:564 because pip
# printed its ordinary "dependency resolver does not currently take into account" WARNING to
# stderr while upgrading setuptools. The build was fine; the wrapper killed it. A transcript
# adds a banner and a footer, which is a cosmetic cost worth paying to leave the target's
# streams exactly as they would be without this script. fresh-toolbox-setup-runner.ps1:109
# uses a transcript for the same reason.
#
# $LASTEXITCODE is $null when the child ran no native command and threw nothing, which is a
# SUCCESS, not a failure - reading it raw under StrictMode is also an error. The three-branch
# read below is why this wrapper is generated rather than inlined into -Argument: getting it
# wrong turns a clean run into exit 1 and there is no second place to notice.
$wrapperBody = @"
`$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath $(ConvertTo-PSLiteral $repoRoot)
Start-Transcript -LiteralPath $(ConvertTo-PSLiteral $LogPath) -Append | Out-Null
`$code = 0
try {
    & $(ConvertTo-PSLiteral $target) $ScriptArgs
    if (`$null -ne `$LASTEXITCODE) { `$code = `$LASTEXITCODE }
} catch {
    Write-Host (`$_ | Out-String)
    `$code = 1
}
Stop-Transcript | Out-Null
"$sentinel exit=`$code" | Set-Content -LiteralPath $(ConvertTo-PSLiteral $donePath) -Encoding utf8
"@
Set-Content -LiteralPath $wrapper -Value $wrapperBody -Encoding UTF8

Write-Host "  target   $target" -ForegroundColor Cyan
Write-Host "  log      $LogPath" -ForegroundColor Cyan
Write-Host "  task     $TaskName" -ForegroundColor Cyan

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"{0}`"" -f $wrapper) `
    -WorkingDirectory $repoRoot

# Interactive, NOT S4U or Password: S4U needs SeTcbPrivilege to register, and a password
# principal needs a secret we do not have. Interactive runs in the logged-on session, which
# is also what makes it a fair stand-in for "a shell the user opened".
$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
    -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Seconds ([Math]::Max($TimeoutSeconds, 60))) `
    -MultipleInstances IgnoreNew

$exitCode = 124
try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    # Poll the fresh sentinel FILE, never the log. The log is appended to and may already
    # carry a sentinel from an earlier run against the same -LogPath.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $done = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $donePath) {
            $done = @(Get-Content -LiteralPath $donePath -ErrorAction SilentlyContinue |
                Where-Object { $_ -like "$sentinel*" }) | Select-Object -Last 1
            if ($done) { break }
        }
    }

    if ($done -and ($done -match 'exit=(-?\d+)')) {
        $exitCode = [int]$Matches[1]
        Write-Host ("OK child finished, exit {0}" -f $exitCode) -ForegroundColor Green
    } else {
        Write-Host ("FAIL no sentinel after {0}s - child still running or never started" -f $TimeoutSeconds) -ForegroundColor Red
    }
} finally {
    # Always, including on Ctrl-C: a leftover registered task is the one side effect this
    # script must never have.
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Remove-Item -LiteralPath $wrapper -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $donePath -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath }
exit $exitCode
