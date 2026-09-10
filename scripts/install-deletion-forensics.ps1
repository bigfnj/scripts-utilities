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
  .\scripts\install-deletion-forensics.ps1 -Uninstall # remove Sysmon, restore a 32 MB journal
#>
[CmdletBinding()]
param(
    [string]$Root = $(if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }),
    # 1.5 GB. Measured on this volume at ~18 MB/hour during heavy use (full test suites, an
    # 80 MB journal dump, recursive drive scans), so ~85h worst case and considerably more on a
    # normal day. The journal is capped by SIZE, not time: quiet days simply hold more history.
    [long]$UsnMaxBytes = 1610612736,
    [long]$UsnDeltaBytes = 33554432,
    # 1 GB. Measured at 67 events/min after tuning -> ~178h. A heavy build day runs several
    # times that, which is what the headroom is for; the target is 72h.
    [long]$LogMaxBytes = 1073741824,
    [string]$Volume = 'C:',
    [switch]$Verify,
    [switch]$DryRun,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

$REPO_ROOT = Split-Path $PSScriptRoot
. (Join-Path $REPO_ROOT 'lib\common.ps1')

$SysmonLog     = 'Microsoft-Windows-Sysmon/Operational'
$ConfigSource  = Join-Path $REPO_ROOT 'config\sysmon-filedelete.xml'
# Deployed OUTSIDE the toolbox on purpose: DevToolbox was destroyed in the incident this exists
# to investigate, so the forensics config must not live inside its own subject.
$ConfigDeployed = Join-Path $env:ProgramData 'Sysmon\filedelete-forensics.xml'

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
    $out = & fsutil usn queryjournal $Vol 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return $null }
    $max = [regex]::Match($out, '(?im)^\s*Maximum Size\s*:\s*0x([0-9a-f]+)')
    if (-not $max.Success) { return $null }
    return [Convert]::ToInt64($max.Groups[1].Value, 16)
}

function Get-ForensicsHealth {
    $svc = Get-Service -Name 'Sysmon64', 'Sysmon' -ErrorAction SilentlyContinue | Select-Object -First 1
    $drv = $null
    try { $drv = (& sc.exe query SysmonDrv 2>&1 | Select-String 'RUNNING') -ne $null } catch { $drv = $false }
    $logMax = $null
    try {
        $gl = & wevtutil gl $SysmonLog 2>&1 | Out-String
        $m = [regex]::Match($gl, '(?im)maxSize:\s*(\d+)')
        if ($m.Success) { $logMax = [int64]$m.Groups[1].Value }
    } catch { }
    # Boot persistence is a SEPARATE property from "running now", and the difference is the
    # whole point: a service someone flipped to Manual keeps running until the next restart and
    # then silently stops capturing, which is exactly the blind spot this tool exists to remove.
    $svcStart = $(if ($svc) { [string]$svc.StartType } else { $null })
    $drvStart = $null
    try {
        $qc = & sc.exe qc SysmonDrv 2>&1 | Out-String
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
        ConfigCurrent = ((Test-Path -LiteralPath $ConfigDeployed) -and (Test-Path -LiteralPath $ConfigSource) -and
                         ((Get-FileHash -LiteralPath $ConfigDeployed).Hash -eq (Get-FileHash -LiteralPath $ConfigSource).Hash))
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
    if ($h.ConfigCurrent)  { Write-Ok "config matches the repo copy" }
    elseif ($h.ConfigPresent) { Write-Warn "deployed config DIFFERS from config\sysmon-filedelete.xml"; $ok = $false }
    else { Write-Err "config missing at $ConfigDeployed"; $ok = $false }
    # Null means "could not read it", which is not the same as zero and must not divide.
    if ($null -eq $h.LogMaxBytes) { Write-Err "could not read the size of $SysmonLog"; $ok = $false }
    elseif ($h.LogMaxBytes -ge $LogMaxBytes) { Write-Ok ("Sysmon log {0:N0} MB" -f ($h.LogMaxBytes / 1MB)) }
    else { Write-Warn ("Sysmon log only {0:N0} MB (want {1:N0} MB)" -f ($h.LogMaxBytes / 1MB), ($LogMaxBytes / 1MB)); $ok = $false }

    if ($null -eq $h.UsnMaxBytes) { Write-Err "no USN journal readable on $Volume"; $ok = $false }
    elseif ($h.UsnMaxBytes -ge $UsnMaxBytes) { Write-Ok ("USN journal {0:N2} GB on {1}" -f ($h.UsnMaxBytes / 1GB), $Volume) }
    else { Write-Warn ("USN journal only {0:N0} MB on {1} (want {2:N2} GB)" -f ($h.UsnMaxBytes / 1MB), $Volume, ($UsnMaxBytes / 1GB)); $ok = $false }
    if ($ok) { Write-Ok 'deletion forensics healthy' } else { Write-Warn 'run scripts\install-deletion-forensics.ps1 to repair' }
    exit $(if ($ok) { 0 } else { 1 })
}

# ---- everything below changes machine state -----------------------------------------------
if (-not (Test-Elevated) -and -not $DryRun) {
    Write-Warn 'Elevation is required to install a driver and resize the USN journal. Relaunching...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-Root', "`"$Root`"", '-Volume', $Volume,
                 '-UsnMaxBytes', $UsnMaxBytes, '-UsnDeltaBytes', $UsnDeltaBytes, '-LogMaxBytes', $LogMaxBytes)
    if ($Uninstall) { $argList += '-Uninstall' }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -PassThru -Wait
    exit $p.ExitCode
}

$sysmon = Find-Sysmon

if ($Uninstall) {
    Write-Group 'removing deletion forensics'
    if ($sysmon) {
        if ($DryRun) { Write-Info "[DRY-RUN] $sysmon -u force" }
        else { & $sysmon -u force 2>&1 | Out-Null; Write-Ok 'Sysmon uninstalled' }
    } else { Write-Skip 'Sysmon binary not found; nothing to uninstall' }
    # Back to the Windows default rather than deleting the journal: deletejournal would discard
    # history that is still the only record of anything recent.
    if ($DryRun) { Write-Info "[DRY-RUN] shrink USN journal on $Volume to 32 MB" }
    else {
        & fsutil usn createjournal m=33554432 a=8388608 $Volume 2>&1 | Out-Null
        Write-Ok "USN journal on $Volume returned to 32 MB"
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
    & fsutil usn createjournal m=$UsnMaxBytes a=$UsnDeltaBytes $Volume 2>&1 | Out-Null
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
Copy-Item -LiteralPath $ConfigSource -Destination $ConfigDeployed -Force
Write-Ok "config deployed to $ConfigDeployed"

$existing = Get-Service -Name 'Sysmon64', 'Sysmon' -ErrorAction SilentlyContinue | Select-Object -First 1
# Sysmon writes its banner to stderr even on success, so decide by re-querying state below
# rather than by parsing this output.
if ($existing) { & $sysmon -c $ConfigDeployed 2>&1 | Out-Null; Write-Ok 'Sysmon config updated' }
else { & $sysmon -accepteula -i $ConfigDeployed 2>&1 | Out-Null; Write-Ok 'Sysmon installed' }

# Circular (/rt:false) is what gives the natural roll-off; nothing is archived.
& wevtutil sl $SysmonLog /ms:$LogMaxBytes /rt:false 2>&1 | Out-Null
Write-Ok ("Sysmon log sized to {0:N0} MB, circular" -f ($LogMaxBytes / 1MB))

# -- 3. prove it, rather than assume ------------------------------------------------------------
$h = Get-ForensicsHealth
if (-not ($h.ServiceRunning -and $h.DriverRunning)) {
    Write-Err 'Sysmon installed but the service or driver is not running'
    exit 1
}
Write-Ok "verified: $($h.ServiceName) + SysmonDrv running"
Write-Info "query deletions (ELEVATED - the channel is admin-only to read):"
Write-Info "  Get-WinEvent -FilterHashtable @{LogName='$SysmonLog'; Id=26}"
exit 0
