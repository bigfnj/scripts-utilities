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
    # 2, matching pc-maintenance's reportsToKeep and for the same stated reason: this run and
    # the one before it is what makes a week-over-week comparison possible without Downloads
    # filling up with dashboards nobody opens. A third copy is a month-old snapshot that the
    # novelty baseline already answers better than an old HTML file does.
    [int]$KeepReports = 2,
    # A process deleting this many files inside BurstWindowSeconds is called out as a burst.
    [int]$BurstThreshold = 50,
    [int]$BurstWindowSeconds = 300,
    [switch]$NoPrune,
    # Do not fold this run's pairings into the novelty baseline. Use it for any run that is not
    # the regular weekly one - an incident investigation, or a one-off -Days 30 - because those
    # runs would otherwise teach the baseline that the very thing you are investigating is
    # normal, and the next scheduled report would stop flagging it.
    [switch]$NoBaseline,
    # Model-assisted triage. ON when a local Ollama is reachable, because a feature nobody opts
    # into is a feature nobody gets - but it is an ADDITION, never a dependency: -NoTriage, an
    # absent server, a slow one or a nonsensical answer all produce the same report minus one
    # clearly-fenced panel.
    [switch]$NoTriage,
    [string]$TriageModel = 'mistral-small3.2:24b',
    [string]$TriageUri = 'http://127.0.0.1:11434'
)
$ErrorActionPreference = 'Stop'
$SysmonLog = 'Microsoft-Windows-Sysmon/Operational'

# Everything pure lives in Core so a test can import it. This script cannot be imported: its
# top-level code starts reading the event log immediately and exits on the unelevated path.
. (Join-Path $PSScriptRoot 'ForensicsReport.Core.ps1')

$SentinelPatterns = Get-FxSentinelPattern
$sentinelRx = New-FxSentinelRegex -Pattern $SentinelPatterns

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
            $p = [string]$_.Properties[6].Value
            [pscustomobject]@{
                Time  = $_.TimeCreated
                Pid   = [string]$_.Properties[3].Value
                # ProcessGuid, not ProcessId, is what the command-line join uses. Sysmon mints a
                # GUID per process; pids are recycled within minutes on a busy box. Keying on pid
                # attributed 955 deletions to "cmd.exe /c ping -n 1 1.1.1.1" on the first real
                # report - a ping deletes nothing, it had simply inherited the pid of something
                # that did, and last-writer-wins then overwrote the true command line.
                Guid  = [string]$_.Properties[2].Value
                User  = [string]$_.Properties[4].Value
                Image = [string]$_.Properties[5].Value
                Path  = $p
                # Computed ONCE, here. The parent directory was being recomputed with Split-Path
                # at four separate sites downstream; measured at 100k events, Split-Path costs
                # 8,824 ms against 190 ms for GetDirectoryName - 46x, on a value that never
                # changes. Same for the sentinel classification, which was a nested
                # Where-Object over 15 patterns per event, re-run again later on the rendered
                # rows: 28,129 ms -> 1,145 ms with one pre-compiled alternation.
                Dir   = [IO.Path]::GetDirectoryName($p.TrimEnd('\', '/'))
                IsSentinel = $sentinelRx.IsMatch($p)
            }
        })
} catch { Write-Host "  no deletion events in window" -ForegroundColor DarkGray }

$procs = @{}
try {
    Get-WinEvent -FilterHashtable @{LogName=$SysmonLog; Id=1; StartTime=$since} -ErrorAction Stop |
        ForEach-Object {
            # Event 1: [2] ProcessGuid, [10] CommandLine. Keyed by ProcessGuid, which is unique
            # per process, NOT ProcessId, which Windows recycles within minutes. See the Guid
            # field on the delete records above for what pid keying produced in practice.
            $procs[[string]$_.Properties[2].Value] = [string]$_.Properties[10].Value
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
$byDir = @($deletes | ForEach-Object { $_.Dir } | Group-Object | Sort-Object Count -Descending)

$sentinelHits = @($deletes | Where-Object { $_.IsSentinel })

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
                    ForEach-Object { $_.Dir } | Group-Object |
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

# ---- novelty against the baseline ---------------------------------------------------------
$baselinePath = Join-Path $env:ProgramData 'Sysmon\forensics-baseline.json'
$baseline = Read-FxBaseline -Path $baselinePath
$seen = @{}
foreach ($d in $deletes) {
    $k = Get-FxPairKey -Image $d.Image -Path $d.Path -Dir $d.Dir
    if ($seen.ContainsKey($k)) { $seen[$k]++ } else { $seen[$k] = 1 }
}
$novel = @()
if ($baseline) {
    foreach ($k in $seen.Keys) {
        if (-not $baseline.Pairs.ContainsKey($k)) {
            $parts = $k -split '\|', 2
            $novel += [pscustomobject]@{ Image = $parts[0]; Dir = $parts[1]; Count = $seen[$k] }
        }
    }
    $novel = @($novel | Sort-Object Count -Descending)
}
# Written AFTER novelty is computed, or this run's own pairings would already be in the
# baseline it is compared against and nothing could ever be novel.
#
# -NoBaseline exists because the obvious way to use this tool is the one that breaks it. When
# something has just gone missing you run the report by hand, immediately - and that run folds
# the incident's own pairings into the baseline, so the next scheduled report no longer sees
# them as novel. Investigating a deletion was, until this switch, the act that blinded the
# detector to its recurrence. Same for any one-off `-Days 30`, which back-fills a month of
# pairings into a baseline built from weekly windows.
if ($NoBaseline) {
    Write-Host '  baseline: not updated (-NoBaseline)' -ForegroundColor DarkGray
} else {
    # The return value used to be discarded. A failed write is exactly the case that matters:
    # the next run finds no baseline, reports EVERY pairing as never-seen-before, and announces
    # itself as the first run - which reads as a clean slate rather than as a lost history.
    if (-not (Write-FxBaseline -Path $baselinePath -Seen $seen -Existing $baseline)) {
        Write-Host ("  baseline: WRITE FAILED at $baselinePath - the next run will report every " +
                    'pairing as new and call itself a first run') -ForegroundColor Yellow
    }
}
Write-Host ("  {0} distinct pairing(s); {1}" -f $seen.Count,
    $(if ($baseline) { "$($novel.Count) never seen before (baseline: $($baseline.Runs) run(s))" }
      else { 'no baseline yet - first run establishes it' })) -ForegroundColor DarkGray

$usnMax = $null
try {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o = & fsutil usn queryjournal C: 2>&1 | Out-String
    $ErrorActionPreference = $prev
    $m = [regex]::Match($o, '(?im)^\s*Maximum Size\s*:\s*0x([0-9a-f]+)')
    if ($m.Success) { $usnMax = [Convert]::ToInt64($m.Groups[1].Value, 16) }
} catch { }

. (Join-Path $PSScriptRoot 'ForensicsReport.Render.ps1')
. (Join-Path $PSScriptRoot 'ForensicsReport.Triage.ps1')

# ---- optional model-assisted triage -------------------------------------------------------
# Runs LAST, on the aggregates the facts above already produced, and cannot alter any of them.
# The liveness probe comes first so an absent server costs 5 seconds rather than a timeout.
$triage = $null
if ($NoTriage) {
    Write-Host '  triage: skipped (-NoTriage)' -ForegroundColor DarkGray
} elseif (-not (Test-FxLlmAvailable -BaseUri $TriageUri)) {
    Write-Host '  triage: skipped (no local model reachable)' -ForegroundColor DarkGray
} elseif (-not ($TriageModel = Resolve-FxTriageModel -Preferred $TriageModel -BaseUri $TriageUri)) {
    # Reached only when the server answers but has nothing usable installed. Saying so beats a
    # silent 404 that renders as "no findings" and is indistinguishable from a clean week.
    Write-Host '  triage: skipped (server is up but no usable model is installed)' -ForegroundColor DarkGray
} else {
    Write-Host ("  triage: asking {0} ..." -f $TriageModel) -ForegroundColor DarkGray
    $facts = @{
        TopProcesses = @($byImage | Select-Object -First 12 | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Count = $_.Count } })
        Bursts       = @($bursts  | Select-Object -First 8  | ForEach-Object { [pscustomobject]@{ Image = $_.Image; Count = $_.Count; Seconds = $_.Seconds } })
        Novel        = @($novel   | Select-Object -First 12)
        Sentinels    = @($sentinelHits | ForEach-Object { [pscustomobject]@{ Image = [IO.Path]::GetFileName($_.Image); Dir = $_.Dir } } |
                          Group-Object Image, Dir | Select-Object -First 12 | ForEach-Object {
                              [pscustomobject]@{ Image = $_.Group[0].Image; Dir = $_.Group[0].Dir; Count = $_.Count } })
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $triage = Get-FxTriage -Facts $facts -Model $TriageModel -BaseUri $TriageUri
    $sw.Stop()
    Write-Host ("  triage: {0} finding(s) kept, {1} discarded for citing nothing, {2:N1}s" -f
        @($triage.Findings).Count, $triage.Rejected, $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
}

# ---- write ---------------------------------------------------------------------------------
$user = Get-FxInteractiveUser
if (-not $OutDir) { $OutDir = Get-FxDownloadsPath -User $user }
$stamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
$outPath = Join-Path $OutDir "Deletion Forensics Report - $stamp.html"

$html = New-ForensicsHtml -Deletes $deletes -ByImage $byImage -ByDir $byDir -Bursts $bursts `
    -Sentinels $sentinelHits -Coverage $coverage -UsnMax $usnMax -Procs $procs `
    -StateChanges $stateChanges -Days $Days -MaxRows $MaxRows -SentinelPatterns $SentinelPatterns `
    -BurstThreshold $BurstThreshold -Novel $novel -Baseline $baseline -DistinctPairs $seen.Count `
    -Triage $triage

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
