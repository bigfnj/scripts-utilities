#Requires -Version 5.1
<#
Provision deletion forensics: Sysmon FileDeleteDetected + a USN journal sized to hold days
rather than hours.

WHY THIS EXISTS. On 2026-09-09 this machine lost ~16 profile dotdirs, %LOCALAPPDATA%\DevToolbox,
.dotnet\tools and ~70 GB of Ollama models between 16:00 and 17:37. The cause was never
established, and could not be: Sysmon was not installed, File System auditing was off, and the
USN journal was 32 MB - under two hours of history on this volume. Every suspect had to be ruled
out by inference instead of evidence. These two sensors exist so a repeat is answerable in
minutes.

WHAT IT INSTALLS

  1. Sysmon (from the toolbox Sysinternals directory) with config\sysmon-filedelete.xml.
     Event 26 FileDeleteDetected, NEVER event 23 FileDelete: 23 archives a COPY of every
     deleted file to disk before logging it, which on a machine that deletes build output all
     day would consume the disk it is meant to protect. 26 records the same who/what/when.

  2. A resized USN journal. USN carries no process identity - only Sysmon can say WHO - but it
     is the authoritative record of WHAT and WHEN, and it survives Sysmon being stopped.

Both are machine state, so both are idempotent here: re-running re-applies the config and
re-sizes the journal rather than erroring. Nothing is downloaded; Sysmon comes from the toolbox.

  .\scripts\install-deletion-forensics.ps1            # install or update
  .\scripts\install-deletion-forensics.ps1 -Verify    # report health, change nothing
  .\scripts\install-deletion-forensics.ps1 -DryRun    # show what would happen
  .\scripts\install-deletion-forensics.ps1 -Uninstall # remove Sysmon; journal is LEFT sized
  .\scripts\install-deletion-forensics.ps1 -Uninstall -ShrinkJournal   # also destroy the journal

-Uninstall deliberately leaves the USN journal at its current size. NTFS cannot shrink one in
place - `createjournal` with a smaller size is a silent no-op - so the only way down is to
delete it, discarding every record. An oversized journal costs disk and nothing else, and
destroying recent filesystem history as a side effect of removing a monitoring tool is a
surprise nobody wants. -ShrinkJournal opts into it explicitly.
#>
[CmdletBinding()]
param(
    [string]$Root = $(if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }),
    # 2 GB. Target is 48 HOURS of history - two days is the useful window for "what happened
    # to my files", and it is a far more honest goal than the 72 this was first sized for.
    #
    # Measured on this volume: 9 MB/hour sustained. A RESTART then writes ~300 MB in its first
    # minutes - Windows startup and every autostart app touch an enormous number of files - and
    # that cost is per reboot, not per hour. At one reboot a day that is 216 MB/day sustained
    # plus a 300 MB burst, so 2 GB holds ~95 hours; with no reboots, ~227.
    #
    # The general lesson, if this is ever retuned: measure the SUSTAINED rate separately from
    # bursts. Sampling right after a reboot showed 258 MB/hour and would have sized this ~14x
    # too small.
    [long]$UsnMaxBytes = 2147483648,
    [long]$UsnDeltaBytes = 33554432,
    # 2 GB, for a 48-hour target.
    #
    # Two estimates were wrong before this one was measured, which is why the dashboard now
    # reports retention instead of anyone asserting it. The first assumed ~1.5 KB per event;
    # a real log averages 3,756 bytes. The second missed that 73.5% of all volume was
    # ProcessCreate from agent shell tooling. With that excluded, measured at 4,620 events/hour
    # = 16.5 MB/hour, 2 GB projects to ~124 hours - 2.6x the target, which is the margin a
    # heavy build or agent day needs.
    [long]$LogMaxBytes = 2147483648,
    [string]$Volume = 'C:',
    [switch]$Verify,
    [switch]$DryRun,
    [switch]$Uninstall,
    # Skip registering the weekly HTML report task; the sensors install either way.
    [switch]$NoSchedule,
    # Only meaningful with -Uninstall. Shrinking a USN journal is impossible in place, so this
    # DELETES it and recreates it small, discarding every record. Opt-in for that reason.
    [switch]$ShrinkJournal,
    # Whose profile the sensor watches. Resolved in the UNELEVATED parent and passed explicitly
    # into the elevated child, which is the whole point: after Start-Process -Verb RunAs,
    # $env:USERPROFILE belongs to the administrator who consented, not to the person sitting at
    # the machine. On a box where those differ - any managed workstation - rendering the config
    # in the child would watch the admin's profile and leave the sensor blind for exactly the
    # user losing files. That is the bug this template was written to fix, wearing a different
    # hat, and it would have been reintroduced by the fix itself.
    [string]$ProfilePath,
    # INTERNAL, set only on the UAC child this script spawns. It exists so the transcript below
    # starts in the CHILD and nowhere else. Without it there is no way to tell "I am the relaunched
    # child, whose console is about to be destroyed" from "an operator ran me in their own elevated
    # shell", and the two need opposite behaviour.
    [switch]$FromRelaunch
)
$ErrorActionPreference = 'Stop'

$REPO_ROOT = Split-Path $PSScriptRoot
. (Join-Path $REPO_ROOT 'lib\common.ps1')
. (Join-Path $REPO_ROOT 'lib\SysmonConfig.ps1')

$SysmonLog     = 'Microsoft-Windows-Sysmon/Operational'
$TaskName      = 'DeletionForensicsReport'
$ConfigSource  = Join-Path $REPO_ROOT 'config\sysmon-filedelete.xml'
# Deployed OUTSIDE the toolbox on purpose: DevToolbox was destroyed in the incident this exists
# to investigate, so the forensics config must not live inside its own subject.
$ConfigDeployed = Join-Path $env:ProgramData 'Sysmon\filedelete-forensics.xml'
# Fixed name, not timestamped, because the UNELEVATED parent has to print this path before the
# elevated child exists. Same reasoning and same location as consolidate-path.ps1's.
$ElevatedLog = Join-Path $REPO_ROOT 'logs\deletion-forensics-elevated.log'

# Resolved HERE, at the top, while we may still be the interactive user. See -ProfilePath.
if (-not $ProfilePath) { $ProfilePath = $env:USERPROFILE }
$ProfilePath = $ProfilePath.TrimEnd('\')

function Invoke-Native {
    <#
        Run a native command without letting its STDERR abort the script.

        This file sets $ErrorActionPreference = 'Stop', and under Stop a native command that
        writes to stderr while its output is merged with 2>&1 raises a TERMINATING error - even
        when the command succeeded. Sysmon prints its banner and licence text to stderr on every
        invocation, so `& sysmon -c config 2>&1` applied the config correctly and then threw,
        and the script exited 1 several lines before its own `exit 0`.

        That is the worst shape a bug can take here: the work is done, and the caller is told it
        failed. Anything automated would retry or halt on a healthy install.

        Returns the exit code; output is captured and discarded unless -PassThru.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$PassThru
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
        if ($PassThru) { return [pscustomobject]@{ ExitCode = $code; Output = ($out | Out-String) } }
        return $code
    } finally { $ErrorActionPreference = $prev }
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-Sysmon {
    @(
        (Join-Path $Root 'sysinternals\Sysmon64.exe'),
        (Join-Path $Root 'sysinternals\Sysmon.exe'),
        (Get-Command 'Sysmon64.exe' -ErrorAction SilentlyContinue).Source,
        (Get-Command 'Sysmon.exe'   -ErrorAction SilentlyContinue).Source
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Get-UsnState {
    param([string]$Vol)
    $r = Invoke-Native -FilePath 'fsutil' -Arguments @('usn', 'queryjournal', $Vol) -PassThru
    if ($r.ExitCode -ne 0) { return $null }
    $out = $r.Output
    $max = [regex]::Match($out, '(?im)^\s*Maximum Size\s*:\s*0x([0-9a-f]+)')
    if (-not $max.Success) { return $null }
    return [Convert]::ToInt64($max.Groups[1].Value, 16)
}

function Get-ForensicsHealth {
    $svc = Get-Service -Name 'Sysmon64', 'Sysmon' -ErrorAction SilentlyContinue | Select-Object -First 1
    $drv = $null
    # Invoke-Native, not a bare `2>&1 |`, for the reason written at its definition: this file runs
    # under Stop, and all three probes below merge stderr. THE HEALTH REPORT WAS THE WORST PLACE
    # FOR THAT. sc.exe writes "The specified service does not exist" to stderr when SysmonDrv is
    # absent, which is the single most likely state a health check is run in, and the catch here
    # turned that terminating record into $drv = $false - the same answer as "installed but
    # stopped". The wrapper keeps the answer and removes the throw, so the catch now covers only
    # what it was written for: sc.exe or wevtutil not being resolvable at all.
    try {
        $q = Invoke-Native -FilePath 'sc.exe' -Arguments @('query', 'SysmonDrv') -PassThru
        $drv = ($q.Output -match 'RUNNING')
    } catch { $drv = $false }
    $logMax = $null
    try {
        $gl = (Invoke-Native -FilePath 'wevtutil' -Arguments @('gl', $SysmonLog) -PassThru).Output
        $m = [regex]::Match($gl, '(?im)maxSize:\s*(\d+)')
        if ($m.Success) { $logMax = [int64]$m.Groups[1].Value }
    } catch { }
    # Boot persistence is a SEPARATE property from "running now", and the difference is the
    # whole point: a service someone flipped to Manual keeps running until the next restart and
    # then silently stops capturing, which is exactly the blind spot this tool exists to remove.
    $svcStart = $(if ($svc) { [string]$svc.StartType } else { $null })
    $drvStart = $null
    try {
        $qc = (Invoke-Native -FilePath 'sc.exe' -Arguments @('qc', 'SysmonDrv') -PassThru).Output
        $m = [regex]::Match($qc, '(?im)START_TYPE\s*:\s*\d+\s+(\S+)')
        if ($m.Success) { $drvStart = $m.Groups[1].Value }
    } catch { }

    [pscustomobject]@{
        ServiceName = $(if ($svc) { $svc.Name } else { $null })
        ServiceRunning = ($svc -and $svc.Status -eq 'Running')
        ServiceStartType = $svcStart
        DriverStartType = $drvStart
        DriverRunning = [bool]$drv
        ConfigPresent = (Test-Path -LiteralPath $ConfigDeployed)
        # Compared against the template RENDERED FOR THIS PROFILE, not against the template.
        # Hashing the raw template would now always differ, and hashing the deployed file
        # against itself is what made the old check vacuous.
        ConfigCurrent = $(
            if (-not (Test-Path -LiteralPath $ConfigDeployed)) { $false }
            elseif (-not (Test-Path -LiteralPath $ConfigSource)) { $false }
            else {
                $want = Get-RenderedSysmonConfig -TemplatePath $ConfigSource -ProfilePath $ProfilePath
                $have = [IO.File]::ReadAllText($ConfigDeployed)
                $want -eq $have
            })
        # A SEPARATE fact from the one above, deliberately. The deployed file can be a faithful
        # render of an older template, or a faithful render for a DIFFERENT user - and a second
        # person logging in makes the second true while the first stays true. Collapsing three
        # facts into one boolean is how the original bug survived review.
        ConfigMatchesProfile = $(
            if (-not (Test-Path -LiteralPath $ConfigDeployed)) { $false }
            else {
                $have = [IO.File]::ReadAllText($ConfigDeployed)
                ($have -notmatch '\|') -and ($have -like "*$ProfilePath*")
            })
        LogMaxBytes = $logMax
        UsnMaxBytes = (Get-UsnState -Vol $Volume)
    }
}

# ---- verify -------------------------------------------------------------------------------
if ($Verify) {
    Write-Group 'deletion forensics'
    $h = Get-ForensicsHealth
    $ok = $true
    if ($h.ServiceRunning) { Write-Ok "Sysmon service running ($($h.ServiceName))" } else { Write-Err 'Sysmon service not running'; $ok = $false }
    if ($h.DriverRunning)  { Write-Ok 'SysmonDrv running' } else { Write-Err 'SysmonDrv not running'; $ok = $false }
    # Survives a restart? Checked, not assumed.
    if ($h.ServiceStartType -eq 'Automatic') { Write-Ok 'Sysmon service starts automatically at boot' }
    else { Write-Err "Sysmon service StartType is '$($h.ServiceStartType)', not Automatic - it will not capture after a restart"; $ok = $false }
    if ($h.DriverStartType -match 'BOOT_START|SYSTEM_START|AUTO_START') { Write-Ok "SysmonDrv loads at boot ($($h.DriverStartType))" }
    else { Write-Err "SysmonDrv START_TYPE is '$($h.DriverStartType)' - it will not load after a restart"; $ok = $false }
    if ($h.ConfigCurrent)  { Write-Ok "deployed config matches the template rendered for $ProfilePath" }
    elseif ($h.ConfigPresent) { Write-Warn "deployed config DIFFERS from config\sysmon-filedelete.xml rendered for $ProfilePath"; $ok = $false }
    else { Write-Err "config missing at $ConfigDeployed"; $ok = $false }
    if ($h.ConfigPresent) {
        if ($h.ConfigMatchesProfile) { Write-Ok "the live rules name this profile, so the sensor is watching the right user" }
        else { Write-Err "the live rules do NOT name $ProfilePath - the sensor is watching a different profile, or nothing at all"; $ok = $false }
    }
    # Null means "could not read it", which is not the same as zero and must not divide.
    if ($null -eq $h.LogMaxBytes) { Write-Err "could not read the size of $SysmonLog"; $ok = $false }
    elseif ($h.LogMaxBytes -ge $LogMaxBytes) { Write-Ok ("Sysmon log {0:N0} MB" -f ($h.LogMaxBytes / 1MB)) }
    else { Write-Warn ("Sysmon log only {0:N0} MB (want {1:N0} MB)" -f ($h.LogMaxBytes / 1MB), ($LogMaxBytes / 1MB)); $ok = $false }

    if ($null -eq $h.UsnMaxBytes) { Write-Err "no USN journal readable on $Volume"; $ok = $false }
    elseif ($h.UsnMaxBytes -ge $UsnMaxBytes) { Write-Ok ("USN journal {0:N2} GB on {1}" -f ($h.UsnMaxBytes / 1GB), $Volume) }
    else { Write-Warn ("USN journal only {0:N0} MB on {1} (want {2:N2} GB)" -f ($h.UsnMaxBytes / 1MB), $Volume, ($UsnMaxBytes / 1GB)); $ok = $false }
    # A SYSTEM-registered task is ADMIN-ONLY TO VIEW. Unelevated, Get-ScheduledTask returns
    # nothing whether the task exists or not, so reporting "missing" here would be a check that
    # announces a failure it never actually tested. This said "no weekly report task" about a
    # task that had just been registered successfully.
    if (-not (Test-Elevated)) {
        Write-Skip "weekly report task: cannot check unelevated (SYSTEM tasks are admin-only to view)"
    } else {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) { Write-Ok "weekly report task registered ($($task.State))" }
        else { Write-Warn "no weekly report task - reports will not be generated" }
    }

    if ($ok) { Write-Ok 'deletion forensics healthy' } else { Write-Warn 'run scripts\install-deletion-forensics.ps1 to repair' }
    exit $(if ($ok) { 0 } else { 1 })
}

# ---- everything below changes machine state -----------------------------------------------
if (-not (Test-Elevated) -and -not $DryRun) {
    Write-Warn 'Elevation is required to install a driver and resize the USN journal. Relaunching...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-Root', "`"$Root`"", '-Volume', $Volume,
                 '-UsnMaxBytes', $UsnMaxBytes, '-UsnDeltaBytes', $UsnDeltaBytes, '-LogMaxBytes', $LogMaxBytes,
                 # The interactive user's profile, resolved BEFORE this relaunch. Without it the
                 # child renders for the consenting administrator.
                 '-ProfilePath', "`"$ProfilePath`"")
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($ShrinkJournal) { $argList += '-ShrinkJournal' }
    if ($NoSchedule) { $argList += '-NoSchedule' }
    $argList += '-FromRelaunch'

    # TELL THE OPERATOR WHERE THE OUTPUT WENT, BEFORE THE CHILD EXISTS.
    #
    # A UAC child owns a brand-new console that is destroyed the instant it exits, so on
    # 2026-09-11 a completely successful run of this script looked like this, in full:
    #
    #     WARN Elevation is required to install a driver and resize the USN journal. Relaunching...
    #
    # and nothing else, ever. Success and failure are character-for-character identical from the
    # caller's side, which cost an investigation to establish that the redeploy had in fact
    # worked (the only evidence was the deployed config's mtime).
    #
    # -RedirectStandardOutput CANNOT fix this: it lives in Start-Process's Default parameter set
    # and -Verb lives in UseShellExecute, so the two are mutually exclusive and adding it is a
    # binding error, not a fix. A transcript started INSIDE the child is the only mechanism, and
    # the path has to be fixed rather than timestamped so the parent can print it in advance.
    # scripts\consolidate-path.ps1 has done exactly this since 2026-09-10; this script is the
    # other self-elevating script in the repo and did not.
    Write-Info "elevated run transcribes to $ElevatedLog"
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -PassThru -Wait
    if ($p.ExitCode -ne 0) { Write-Err "the elevated run exited $($p.ExitCode) - read $ElevatedLog" }
    else { Write-Ok "the elevated run finished; its full output is in $ElevatedLog" }
    exit $p.ExitCode
}

# The elevated child transcribes here. Benign failure modes are reported rather than swallowed:
# an outer transcript (the runner starts one) makes 5.1 throw "already been started", and the
# output then lands in the caller's transcript instead - nothing is lost, but a silent catch
# would make the line printed above a lie.
# GATED ON $FromRelaunch, not on Test-Elevated. Gating on elevation alone transcribed the
# CALLER'S SESSION whenever an operator ran this from their own admin prompt: PowerShell runs a
# .ps1 in the current session, the script's `exit` ends the script rather than the session, and
# there is no Stop-Transcript on any of the eight exit paths - so every later command in that
# window kept being written to the log until it closed. Found by audit on 2026-09-11, hours after
# the transcript was added to fix the opposite problem.
#
# There is deliberately still no Stop-Transcript. The only process that starts one now is the UAC
# child, which is a SEPARATE powershell.exe whose exit closes the transcript for us - the same
# reason consolidate-path.ps1 needs none. An operator in their own elevated shell gets no
# transcript and needs none: their console already has the output, and they can redirect it.
if ($FromRelaunch -and (Test-Elevated) -and -not $DryRun) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ElevatedLog) | Out-Null
    try { Start-Transcript -Path $ElevatedLog -Force | Out-Null }
    catch {
        if ($_.Exception.Message -match 'already been started') {
            Write-Info "already transcribing - this run's output goes to the caller's transcript"
        } else {
            Write-Warn "could not transcribe to $ElevatedLog ($($_.Exception.Message)) - output is console-only"
        }
    }
}

$sysmon = Find-Sysmon

if ($Uninstall) {
    Write-Group 'removing deletion forensics'
    if ($sysmon) {
        if ($DryRun) { Write-Info "[DRY-RUN] $sysmon -u force" }
        else { $null = Invoke-Native -FilePath $sysmon -Arguments @('-u', 'force'); Write-Ok 'Sysmon uninstalled' }
    } else { Write-Skip 'Sysmon binary not found; nothing to uninstall' }
    if ($DryRun) { Write-Info "[DRY-RUN] unregister scheduled task '$TaskName'" }
    elseif (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Ok "removed the weekly report task"
    } else { Write-Skip 'no weekly report task registered' }
    # The journal is NOT shrunk by default, and the reason is worth stating plainly because an
    # earlier version of this block claimed it was.
    #
    # `fsutil usn createjournal` with a SMALLER m than the current one is a silent no-op: NTFS
    # will grow a journal in place but not shrink it. The only way down is `deletejournal /d`,
    # which discards every record it holds. This script used to run createjournal and then print
    # "USN journal returned to 32 MB" unconditionally - measured during a lifecycle test, the
    # journal was still 2,048 MB while the line said 32. Asserting instead of measuring, which
    # is the same defect this whole capability exists to catch.
    #
    # Leaving it large is also the better default: an oversized journal costs disk and nothing
    # else, whereas destroying the record of recent filesystem activity as a SIDE EFFECT of
    # uninstalling a monitoring tool is exactly the kind of surprise nobody wants. -ShrinkJournal
    # makes it opt-in and says what it costs.
    if ($DryRun) {
        if ($ShrinkJournal) { Write-Info "[DRY-RUN] DELETE and recreate the USN journal on $Volume at 32 MB (discards all history)" }
        else { Write-Info "[DRY-RUN] leave the USN journal on $Volume at its current size" }
    }
    elseif ($ShrinkJournal) {
        $null = Invoke-Native -FilePath 'fsutil' -Arguments @('usn', 'deletejournal', '/d', $Volume)
        $null = Invoke-Native -FilePath 'fsutil' -Arguments @('usn', 'createjournal', 'm=33554432', 'a=8388608', $Volume)
        $now = Get-UsnState -Vol $Volume
        if ($null -ne $now -and $now -le 33554432) { Write-Ok ("USN journal on {0} recreated at {1:N0} MB (history discarded)" -f $Volume, ($now / 1MB)) }
        else { Write-Err ("USN journal on {0} is still {1:N0} MB - the shrink did not take" -f $Volume, ($now / 1MB)) }
    }
    else {
        $now = Get-UsnState -Vol $Volume
        Write-Skip ("USN journal left at {0:N2} GB on {1}" -f ($now / 1GB), $Volume)
        Write-Info "it costs disk only, and shrinking it means discarding its history."
        Write-Info "pass -ShrinkJournal to delete and recreate it at 32 MB."
    }
    exit 0
}

Write-Group 'deletion forensics'

# -- 1. USN journal ---------------------------------------------------------------------------
$before = Get-UsnState -Vol $Volume
if ($null -eq $before) {
    Write-Warn "no USN journal on $Volume (or fsutil unavailable); skipping resize"
} elseif ($before -ge $UsnMaxBytes) {
    Write-Skip ("USN journal already {0:N2} GB on {1}" -f ($before / 1GB), $Volume)
} elseif ($DryRun) {
    Write-Info ("[DRY-RUN] resize USN journal {0:N0} MB -> {1:N2} GB on {2}" -f ($before / 1MB), ($UsnMaxBytes / 1GB), $Volume)
} else {
    # createjournal on an EXISTING journal resizes it in place. It does not discard history;
    # that is deletejournal, which is deliberately not used here.
    $null = Invoke-Native -FilePath 'fsutil' -Arguments @('usn', 'createjournal', "m=$UsnMaxBytes", "a=$UsnDeltaBytes", $Volume)
    $after = Get-UsnState -Vol $Volume
    if ($after -ge $UsnMaxBytes) { Write-Ok ("USN journal {0:N0} MB -> {1:N2} GB on {2}" -f ($before / 1MB), ($after / 1GB), $Volume) }
    else { Write-Err ("USN resize did not take (still {0:N0} MB)" -f ($after / 1MB)) }
}

# -- 2. Sysmon ---------------------------------------------------------------------------------
if (-not $sysmon) {
    Write-Err "Sysmon not found under $Root\sysinternals or on PATH."
    Write-Info "Run .\bootstrap.ps1 -Only security (Sysinternals ships with it), then re-run this."
    exit 1
}
if (-not (Test-Path -LiteralPath $ConfigSource)) { Write-Err "missing $ConfigSource"; exit 1 }

if ($DryRun) {
    Write-Info "[DRY-RUN] deploy $ConfigSource -> $ConfigDeployed"
    Write-Info "[DRY-RUN] $sysmon -accepteula -i (or -c if already installed)"
    Write-Info ("[DRY-RUN] wevtutil sl {0} /ms:{1}" -f $SysmonLog, $LogMaxBytes)
    exit 0
}

New-Item -ItemType Directory -Path (Split-Path $ConfigDeployed) -Force | Out-Null
$rendered = Get-RenderedSysmonConfig -TemplatePath $ConfigSource -ProfilePath $ProfilePath
$configProblems = Test-RenderedSysmonConfig -Text $rendered -ProfilePath $ProfilePath
if ($configProblems.Count) {
    foreach ($problem in $configProblems) { Write-Err "config: $problem" }
    Write-Err 'refusing to deploy a config that cannot work - the sensor would run blind and report healthy'
    exit 1
}
# WriteAllText with UTF8-no-BOM and the template's own line endings. Set-Content under 5.1
# writes CRLF and ANSI, which changes the bytes and therefore every hash comparison downstream.
[IO.File]::WriteAllText($ConfigDeployed, $rendered, (New-Object Text.UTF8Encoding($false)))
Write-Ok "config rendered for $ProfilePath and deployed to $ConfigDeployed"

$existing = Get-Service -Name 'Sysmon64', 'Sysmon' -ErrorAction SilentlyContinue | Select-Object -First 1
# Sysmon writes its banner to stderr even on success, so decide by re-querying state below
# rather than by parsing this output.
# The exit code was discarded here and "Sysmon config updated" printed regardless, so a
# REJECTED ruleset reported as applied while the sensor kept running the previous one. The
# hash check could not catch it either: Copy-Item makes the deployed file match before this
# line runs, which is a post-condition restating its own pre-condition.
if ($existing) {
    $rc = Invoke-Native -FilePath $sysmon -Arguments @('-c', $ConfigDeployed)
    if ($rc -ne 0) { Write-Err "Sysmon REJECTED the config (exit $rc) - the previous ruleset is still live"; exit 1 }
    Write-Ok 'Sysmon accepted the config'
} else {
    $rc = Invoke-Native -FilePath $sysmon -Arguments @('-accepteula', '-i', $ConfigDeployed)
    if ($rc -ne 0) { Write-Err "Sysmon install failed (exit $rc)"; exit 1 }
    Write-Ok 'Sysmon installed'
}

# Circular (/rt:false) is what gives the natural roll-off; nothing is archived.
$null = Invoke-Native -FilePath 'wevtutil' -Arguments @('sl', $SysmonLog, "/ms:$LogMaxBytes", '/rt:false')
Write-Ok ("Sysmon log sized to {0:N0} MB, circular" -f ($LogMaxBytes / 1MB))

# -- 3. the weekly report ------------------------------------------------------------------------
# SYSTEM, because the Sysmon channel is admin-only to read; the report resolves the interactive
# user at run time so the HTML still lands in THEIR Downloads. Sunday 04:00 rather than 03:00 so
# it does not collide with pc-maintenance's weekly sweep on the same machine.
if (-not $NoSchedule) {
    $gen = Join-Path $PSScriptRoot 'New-ForensicsReport.ps1'
    if (-not (Test-Path -LiteralPath $gen)) {
        Write-Warn "report generator not found at $gen; skipping the schedule"
    } else {
        try {
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Days 7' -f $gen)
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00'
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            # StartWhenAvailable so a machine that was off on Sunday still gets its report.
            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
            if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            }
            $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force -ErrorAction Stop
            Write-Ok "weekly report task '$TaskName' registered (Sunday 04:00, SYSTEM)"
        } catch {
            # The sensors are the point; the report is the delivery. Losing the delivery is a
            # warning, not a failed install.
            Write-Warn "could not register the report task: $($_.Exception.Message)"
        }
    }
}

# -- 4. prove it, rather than assume ------------------------------------------------------------
$h = Get-ForensicsHealth
if (-not ($h.ServiceRunning -and $h.DriverRunning)) {
    Write-Err 'Sysmon installed but the service or driver is not running'
    exit 1
}
Write-Ok "verified: $($h.ServiceName) + SysmonDrv running"
Write-Info "query deletions (ELEVATED - the channel is admin-only to read):"
Write-Info "  Get-WinEvent -FilterHashtable @{LogName='$SysmonLog'; Id=26}"
exit 0
