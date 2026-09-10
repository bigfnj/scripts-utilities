#Requires -Version 5.1
<#
.SYNOPSIS
    Weekly HTML dashboard for deletion forensics: insights plus a filterable log reader.

.DESCRIPTION
    The sensors installed by install-deletion-forensics.ps1 answer "which process deleted this?"
    - but only if somebody looks, and looking currently means an elevated Get-WinEvent and a
    working knowledge of Sysmon's schema. This turns the log into something readable on a
    Sunday morning.

    Modelled on pc-maintenance's report, deliberately, including the parts that are easy to get
    wrong: the file is written to the INTERACTIVE user's real Downloads (resolved from their own
    shell-folder registration, not <profile>\Downloads, which is commonly redirected), only the
    most recent few are kept, and it is SELF-CONTAINED - no CDN, no webfont, no library. It gets
    opened offline, possibly months later, from a machine that may be mid-incident.

    Self-contained is not the same as script-free. pc-maintenance's report avoids JS because
    every number it shows fits in a <details> element. A log reader needs to filter thousands of
    rows, so this one carries inline vanilla JavaScript. The constraint that actually matters -
    nothing is fetched from anywhere - still holds, and a test asserts it.

    WHAT IT LOOKS FOR. A mass deletion is not "some files were deleted", it is one process
    deleting many files in a short window. That burst is the headline, not a raw event dump.
    Sentinel paths (quiet, valuable directories where any deletion is unusual) are called out
    separately, because signal there means more than signal in a package cache.

.EXAMPLE
    .\scripts\New-ForensicsReport.ps1
    .\scripts\New-ForensicsReport.ps1 -Days 30 -OutDir C:\Temp
#>
[CmdletBinding()]
param(
    [int]$Days = 7,
    [string]$OutDir,
    # Rows embedded in the log reader. The cap is about file size, not interest: every count in
    # the insights above is computed over ALL events in the window, and the reader says so when
    # it is showing a subset.
    [int]$MaxRows = 4000,
    [int]$KeepReports = 3,
    # A process deleting this many files inside BurstWindowSeconds is called out as a burst.
    [int]$BurstThreshold = 50,
    [int]$BurstWindowSeconds = 300,
    [switch]$NoPrune
)
$ErrorActionPreference = 'Stop'
$SysmonLog = 'Microsoft-Windows-Sysmon/Operational'

# Sentinels: directories where ANY deletion is unusual. The tile is only worth reading if that
# stays true, so membership is decided by measured quietness, not by how much the directory
# matters. All of these were valuable in the 2026-09-09 loss; only these are silent in normal
# operation.
#
# Measured over the first week and REMOVED for being loud - each was diluting the signal:
#   AppData\Local\Programs   992 hits (VS Code and friends rewriting themselves)
#   .claude                   78 hits (agent transcripts and state, written continuously)
#   .codex                    52 hits (same)
# They are still fully tracked - they appear in the deletion counts, the log reader and burst
# detection, and a mass deletion of any of them would show up as a burst. They just cannot be
# sentinels, because a sentinel that fires 992 times a week is a sentinel nobody reads.
$SentinelPatterns = @(
    '\\\.ssh($|\\)', '\\\.aws($|\\)', '\\\.azure($|\\)', '\\\.kube($|\\)', '\\\.gnupg($|\\)',
    '\\\.ollama($|\\)', '\\\.gemini($|\\)', '\\\.agents($|\\)', '\\\.antigravity($|\\)',
    '\\\.continue($|\\)', '\\\.config($|\\)', '\\\.cargo\\bin($|\\)', '\\\.dotnet\\tools($|\\)',
    '\\AppData\\Local\\DevToolbox($|\\)', '\\Documents($|\\)'
)

function Get-InteractiveUser {
    # SYSTEM runs the scheduled task, so "the user" is whoever owns the console session, not the
    # process. Same problem pc-maintenance solves; same approach.
    $sid = $null; $profilePath = $null
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.UserName) {
            $acct = New-Object Security.Principal.NTAccount($cs.UserName)
            $sid = $acct.Translate([Security.Principal.SecurityIdentifier]).Value
        }
    } catch { }
    if (-not $sid) { try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { } }
    if ($sid) {
        $k = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        if (Test-Path -LiteralPath $k) {
            $profilePath = (Get-ItemProperty -LiteralPath $k -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        }
    }
    [pscustomobject]@{ Sid = $sid; Profile = $profilePath }
}

function Get-DownloadsPath {
    param($User)
    $guid = '{374DE290-123F-4565-9164-39C4925E467B}'   # FOLDERID_Downloads
    if ($User.Sid) {
        $key = "Registry::HKEY_USERS\$($User.Sid)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        try {
            $raw = (Get-ItemProperty -LiteralPath $key -Name $guid -ErrorAction Stop).$guid
            if ($raw) {
                $ex = [Environment]::ExpandEnvironmentVariables($raw)
                # Under SYSTEM, %USERPROFILE% in that value expands to SYSTEM's own profile.
                if ($User.Profile -and $ex -match '^[A-Za-z]:\\Windows\\system32') { $ex = Join-Path $User.Profile 'Downloads' }
                if ($ex -and (Test-Path -LiteralPath $ex)) { return $ex }
            }
        } catch { }
    }
    if ($User.Profile) {
        $p = Join-Path $User.Profile 'Downloads'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $env:TEMP
}

function ConvertTo-Html {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    # & first, or the escapes escape each other.
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Format-Bytes {
    param([double]$B)
    if ($B -lt 1KB) { return ('{0:N0} B' -f $B) }
    if ($B -lt 1MB) { return ('{0:N1} KB' -f ($B / 1KB)) }
    if ($B -lt 1GB) { return ('{0:N1} MB' -f ($B / 1MB)) }
    return ('{0:N2} GB' -f ($B / 1GB))
}

# ---- gather --------------------------------------------------------------------------------
$since = (Get-Date).AddDays(-$Days)
Write-Host "reading $SysmonLog since $since ..." -ForegroundColor Cyan

$logInfo = $null
try { $logInfo = Get-WinEvent -ListLog $SysmonLog -ErrorAction Stop } catch {
    Write-Host "cannot read $SysmonLog - run elevated. ($($_.Exception.Message))" -ForegroundColor Red
    exit 1
}

# Positional indices, verified against the schema rather than assumed:
# [1] UtcTime [3] ProcessId [4] User [5] Image [6] TargetFilename.
# Indexing Properties is ~3.4x faster than [xml]$_.ToXml() per event, which matters at 100k.
$deletes = @()
try {
    $deletes = @(Get-WinEvent -FilterHashtable @{LogName=$SysmonLog; Id=26; StartTime=$since} -ErrorAction Stop |
        ForEach-Object {
            [pscustomobject]@{
                Time  = $_.TimeCreated
                Pid   = [string]$_.Properties[3].Value
                User  = [string]$_.Properties[4].Value
                Image = [string]$_.Properties[5].Value
                Path  = [string]$_.Properties[6].Value
            }
        })
} catch { Write-Host "  no deletion events in window" -ForegroundColor DarkGray }

$procs = @{}
try {
    Get-WinEvent -FilterHashtable @{LogName=$SysmonLog; Id=1; StartTime=$since} -ErrorAction Stop |
        ForEach-Object {
            # Event 1: [4] Image, [10] CommandLine. Keyed by pid; last writer wins, which is
            # right - a reused pid should resolve to the most recent process that held it.
            $procs[[string]$_.Properties[3].Value] = [string]$_.Properties[10].Value
        }
} catch { }

# Sysmon state changes mark the boundaries of what this log can be trusted to cover.
$stateChanges = @()
try {
    $stateChanges = @(Get-WinEvent -FilterHashtable @{LogName=$SysmonLog; Id=4; StartTime=$since} -ErrorAction Stop |
        ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; State = [string]$_.Properties[1].Value } })
} catch { }

Write-Host ("  {0:N0} deletions, {1:N0} process starts, {2} state changes" -f $deletes.Count, $procs.Count, $stateChanges.Count) -ForegroundColor DarkGray

# ---- insights ------------------------------------------------------------------------------
$byImage = @($deletes | Group-Object Image | Sort-Object Count -Descending)
$byDir = @($deletes | ForEach-Object { Split-Path $_.Path -Parent } | Group-Object | Sort-Object Count -Descending)

$sentinelHits = @($deletes | Where-Object { $p = $_.Path; ($SentinelPatterns | Where-Object { $p -match $_ }) })

# Bursts: the actual mass-deletion signature. Per process, slide a window and record the
# densest run. One process deleting 5,000 files in four minutes is the thing worth seeing;
# 5,000 deletions spread evenly across a week is just a machine working.
$bursts = @()
foreach ($g in $byImage) {
    if ($g.Count -lt $BurstThreshold) { continue }
    $times = @($g.Group | Sort-Object Time)
    $best = 0; $bestStart = $null; $bestEnd = $null
    $lo = 0
    for ($hi = 0; $hi -lt $times.Count; $hi++) {
        while (($times[$hi].Time - $times[$lo].Time).TotalSeconds -gt $BurstWindowSeconds) { $lo++ }
        $n = $hi - $lo + 1
        if ($n -gt $best) { $best = $n; $bestStart = $times[$lo].Time; $bestEnd = $times[$hi].Time }
    }
    if ($best -ge $BurstThreshold) {
        $sample = @($g.Group | Where-Object { $_.Time -ge $bestStart -and $_.Time -le $bestEnd } |
                    ForEach-Object { Split-Path $_.Path -Parent } | Group-Object |
                    Sort-Object Count -Descending | Select-Object -First 4)
        $bursts += [pscustomobject]@{
            Image = $g.Name; Count = $best; Total = $g.Count
            Start = $bestStart; End = $bestEnd
            Seconds = [math]::Max(1, [int](($bestEnd - $bestStart).TotalSeconds))
            Dirs = $sample
        }
    }
}
$bursts = @($bursts | Sort-Object Count -Descending)

# Measured retention, not estimated. The log is capped by BYTES, so hours of coverage depends
# on event size and rate - both of which vary far more than a back-of-envelope figure suggests.
# An earlier estimate here was out by an order of magnitude because it guessed 1.5 KB/event
# when the real figure is nearer 3.5 KB.
$coverage = $null
try {
    $oldest = Get-WinEvent -LogName $SysmonLog -Oldest -MaxEvents 1 -ErrorAction Stop
    $spanH = ((Get-Date) - $oldest.TimeCreated).TotalHours
    $usedFrac = if ($logInfo.MaximumSizeInBytes) { $logInfo.FileSize / $logInfo.MaximumSizeInBytes } else { 0 }
    $coverage = [pscustomobject]@{
        Oldest = $oldest.TimeCreated
        SpanHours = $spanH
        FileSize = $logInfo.FileSize
        MaxSize = $logInfo.MaximumSizeInBytes
        # Only meaningful once the log has actually filled; before that it is a lower bound.
        ProjectedHours = $(if ($usedFrac -gt 0.02) { $spanH / $usedFrac } else { $null })
        Full = ($usedFrac -ge 0.98)
    }
} catch { }

$usnMax = $null
try {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o = & fsutil usn queryjournal C: 2>&1 | Out-String
    $ErrorActionPreference = $prev
    $m = [regex]::Match($o, '(?im)^\s*Maximum Size\s*:\s*0x([0-9a-f]+)')
    if ($m.Success) { $usnMax = [Convert]::ToInt64($m.Groups[1].Value, 16) }
} catch { }

. (Join-Path $PSScriptRoot 'ForensicsReport.Render.ps1')

# ---- write ---------------------------------------------------------------------------------
$user = Get-InteractiveUser
if (-not $OutDir) { $OutDir = Get-DownloadsPath -User $user }
$stamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
$outPath = Join-Path $OutDir "Deletion Forensics Report - $stamp.html"

$html = New-ForensicsHtml -Deletes $deletes -ByImage $byImage -ByDir $byDir -Bursts $bursts `
    -Sentinels $sentinelHits -Coverage $coverage -UsnMax $usnMax -Procs $procs `
    -StateChanges $stateChanges -Days $Days -MaxRows $MaxRows -SentinelPatterns $SentinelPatterns `
    -BurstThreshold $BurstThreshold

[IO.File]::WriteAllText($outPath, $html, (New-Object Text.UTF8Encoding($false)))
Write-Host "report: $outPath" -ForegroundColor Green

# Keep the last few, ordered by the timestamp in the NAME rather than mtime, so a touched file
# cannot promote itself past a newer one. Strictly name-matched, files only, no recursion.
if (-not $NoPrune) {
    $pattern = '^Deletion Forensics Report - (\d{4}-\d{2}-\d{2}) (\d{6})\.html$'
    $existing = @(Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object { [regex]::Match($_.Name, $pattern).Groups[1].Value + [regex]::Match($_.Name, $pattern).Groups[2].Value } -Descending)
    if ($existing.Count -gt $KeepReports) {
        $existing | Select-Object -Skip $KeepReports | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  pruned $($_.Name)" -ForegroundColor DarkGray
        }
    }
}
exit 0
