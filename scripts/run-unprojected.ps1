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

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not $LogPath) { $LogPath = Join-Path $logDir ("unprojected-{0}.log" -f $stamp) }
$wrapper = Join-Path $logDir ("unprojected-{0}.ps1" -f $stamp)

$target = (Resolve-Path -LiteralPath $Script).Path
$sentinel = "__SU_UNPROJECTED_DONE__"

# The child re-runs the target and records BOTH streams plus an exit code we can trust.
#
# $LASTEXITCODE is $null when the child ran no native command and threw nothing, which is a
# SUCCESS, not a failure - reading it raw under StrictMode is also an error. The three-branch
# read below is why this wrapper is generated rather than inlined into -Argument: getting it
# wrong turns a clean run into exit 1 and there is no second place to notice.
#
# Out-File -Append -Encoding utf8 rather than Start-Transcript: a transcript adds a banner and
# a footer this file's reader would have to strip, and it does not capture a native tool's
# stderr any better.
$wrapperBody = @"
`$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath '$repoRoot'
`$code = 0
try {
    & '$target' $ScriptArgs *>&1 | Out-File -FilePath '$LogPath' -Append -Encoding utf8
    if (`$null -ne `$LASTEXITCODE) { `$code = `$LASTEXITCODE }
} catch {
    `$_ | Out-String | Out-File -FilePath '$LogPath' -Append -Encoding utf8
    `$code = 1
}
"$sentinel exit=`$code" | Out-File -FilePath '$LogPath' -Append -Encoding utf8
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

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $done = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $LogPath) {
            $tail = @(Get-Content -LiteralPath $LogPath -Tail 5 -ErrorAction SilentlyContinue)
            $done = $tail | Where-Object { $_ -like "$sentinel*" } | Select-Object -Last 1
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
}

if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath }
exit $exitCode
