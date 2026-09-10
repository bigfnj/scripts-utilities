#Requires -Version 5.1
<#
    ForensicsReport.Core.ps1 - the parts of the deletion report that are pure enough to test.

    WHY THIS FILE EXISTS. These functions lived in New-ForensicsReport.ps1, which is a SCRIPT:
    its top-level code starts reading the Sysmon event log the moment the file is dot-sourced,
    and on the unelevated path it calls `exit 1`, which kills the CALLING host. A test could
    not import them at all. That is not a theoretical inconvenience - when Get-FxPairKey was
    rewritten for a 24x speedup, the only way to validate it was a throwaway harness that
    RESTATED the function, so what was proved correct was a copy of the code rather than the
    code. Same for the baseline: the bug where a corrupt file is indistinguishable from an
    absent one sat here unnoticed because nothing could exercise it.

    Everything here takes its inputs as parameters or reads one named path. Nothing reads the
    event log, nothing writes a report, nothing exits.

    NAMING. Every function is Fx-prefixed, including the two that were not before the move
    (Get-InteractiveUser, Get-DownloadsPath). The renderer's header records why: an unprefixed
    helper called ConvertTo-Html silently resolved to the real PowerShell cmdlet when its file
    was dot-sourced alone, dropping user data and injecting two remote URLs into a report whose
    header promised it fetched nothing. Unprefixed names in a dot-sourced file are a trap, and
    both of these had zero callers outside the generator, so renaming cost nothing.

    This move is deliberately BEHAVIOUR-PRESERVING - the function bodies below were extracted
    programmatically rather than retyped, so the diff is a move and can be read as one. The
    defects these functions contain are fixed in the commit that follows, where the diff is a
    change and can be read as one.

    Tested by: tests\Invoke-CoreTests.ps1
#>

function Get-FxSentinelPattern {
    <#
        Sentinels: directories where ANY deletion is unusual. The tile is only worth reading if that
        stays true, so membership is decided by measured quietness, not by how much the directory
        matters. All of these were valuable in the 2026-09-09 loss; only these are silent in normal
        operation.

        Measured over the first week and REMOVED for being loud - each was diluting the signal:
        AppData\Local\Programs   992 hits (VS Code and friends rewriting themselves)
        .claude                   78 hits (agent transcripts and state, written continuously)
        .codex                    52 hits (same)
        They are still fully tracked - they appear in the deletion counts, the log reader and burst
        detection, and a mass deletion of any of them would show up as a burst. They just cannot be
        sentinels, because a sentinel that fires 992 times a week is a sentinel nobody reads.
    #>
    @(
        '\\\.ssh($|\\)', '\\\.aws($|\\)', '\\\.azure($|\\)', '\\\.kube($|\\)', '\\\.gnupg($|\\)',
        '\\\.ollama($|\\)', '\\\.gemini($|\\)', '\\\.agents($|\\)', '\\\.antigravity($|\\)',
        '\\\.continue($|\\)', '\\\.config($|\\)', '\\\.cargo\\bin($|\\)', '\\\.dotnet\\tools($|\\)',
        '\\AppData\\Local\\DevToolbox($|\\)', '\\Documents($|\\)'
    )
}

function New-FxSentinelRegex {
    <#
        One compiled alternation, built once. Classification used to be a nested Where-Object - a
        fresh pipeline per event over all 15 patterns, with no short-circuit - and it ran twice, once
        over every deletion and again over the rows the reader embeds. Measured on 100,000 paths:
        28,129 ms for the nested pipeline, 1,770 ms for foreach+break, 1,145 ms for this. All three
        produced identical match counts, which is the part that had to be true before changing it.
    #>
    param([string[]]$Pattern = (Get-FxSentinelPattern))
    New-Object System.Text.RegularExpressions.Regex(
        ($Pattern -join '|'),
        ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
         [System.Text.RegularExpressions.RegexOptions]::Compiled))
}

# ---- novelty ------------------------------------------------------------------------------
# What a WEEKLY report should surface is not "what happened" - the counts already say that -
# but "what happened that does not usually happen". The strongest available signal for that is
# a process/directory pairing appearing for the FIRST time.
#
# Deliberately statistics and not a model. An earlier plan for this used embeddings; looking at
# the actual data shape - (process, directory, count) - that is the wrong tool. Embeddings
# measure semantic similarity between path strings, while the thing that makes a deletion
# suspicious here is that this program has never deleted in this place before. That is a
# frequency question, it is exactly reproducible run to run, it needs no model to be running,
# and every row can state its own reason in one sentence. None of those are true of a model.

function Get-FxPairKey {
    <#
        A stable key for "this program deleting in this place".

        The directory is generalised to a bounded prefix, because the full path is too specific
        to ever repeat: .cargo\registry\src\<hash>\<crate>-1.2.3 is a different string every
        release, so a raw-path baseline would report everything as novel forever and mean
        nothing. Four segments below the profile is deep enough to separate .ollama\models from
        .cargo\registry and shallow enough to be stable across versions.
    #>
    param([string]$Image, [string]$Path, [string]$Dir)
    # This runs once per deletion event and was the single most expensive thing in the report:
    # 49,312 ms per 100,000 events. Two lines were 78% of that - the segment pipeline at 29,060
    # ms and Split-Path at 9,434 ms. Rewritten with String.Split and GetDirectoryName, and with
    # -Dir so the gather loop can hand over the parent it already computed.
    #
    # The rewrite was checked against the old implementation over 68 cases spanning profile and
    # non-profile paths, depths either side of the four-segment cut, trailing separators, UNC,
    # drive roots, unicode, relative paths and a bare filename, with and without -Dir: 0 differ.
    # Two real divergences were found and fixed that way rather than shipped - an invented
    # fallback for empty results, and GetDirectoryName disagreeing with Split-Path on a
    # trailing separator.
    $dir = if ($Dir) { $Dir }
           else { try { [IO.Path]::GetDirectoryName($Path.TrimEnd('\', '/')) } catch { $Path } }
    $m = [regex]::Match($dir, '(?i)^([A-Za-z]:\\Users\\[^\\]+)\\(.*)$')
    if ($m.Success) {
        $parts = $m.Groups[2].Value.Split([char]'\', [StringSplitOptions]::RemoveEmptyEntries)
        if ($parts.Length -eq 0) { $dir = $m.Groups[1].Value }
        else {
            $n = [Math]::Min(4, $parts.Length)
            $dir = $m.Groups[1].Value + '\' + ($parts[0..($n - 1)] -join '\')
        }
    }
    return ('{0}|{1}' -f [IO.Path]::GetFileName($Image), $dir)
}

function Read-FxBaseline {
    <#
        Pairings seen in previous runs. Absent on the first run, which is not an error - it just
        means nothing can be called novel yet, and the report says so rather than flagging all
        4,000 events as new.

        Kept beside the Sysmon config in ProgramData rather than in the toolbox, for the same
        reason the config is: DevToolbox was destroyed in the incident this tooling exists to
        investigate, so nothing it depends on should live inside its own subject.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        $h = @{}
        foreach ($p in $raw.pairs) { $h[[string]$p.key] = $p }
        return @{ Pairs = $h; FirstRun = [string]$raw.firstRun; Runs = [int]$raw.runs }
    } catch { return $null }
}

function Write-FxBaseline {
    param([string]$Path, [hashtable]$Seen, $Existing)
    # Bounded. A pairing not seen for a long time is dropped so the file cannot grow forever;
    # 5,000 is far above the ~100 distinct pairings this machine actually produces.
    $now = (Get-Date).ToString('o')
    $merged = @{}
    if ($Existing) { foreach ($k in $Existing.Pairs.Keys) { $merged[$k] = $Existing.Pairs[$k] } }
    foreach ($k in $Seen.Keys) {
        if ($merged.ContainsKey($k)) {
            $merged[$k].lastSeen = $now
            $merged[$k].count = [int]$merged[$k].count + [int]$Seen[$k]
        } else {
            $merged[$k] = [pscustomobject]@{ key = $k; firstSeen = $now; lastSeen = $now; count = [int]$Seen[$k] }
        }
    }
    $keep = @($merged.Values | Sort-Object { [datetime]$_.lastSeen } -Descending | Select-Object -First 5000)
    $obj = [ordered]@{
        firstRun = $(if ($Existing -and $Existing.FirstRun) { $Existing.FirstRun } else { $now })
        runs     = $(if ($Existing) { [int]$Existing.Runs + 1 } else { 1 })
        updated  = $now
        pairs    = $keep
    }
    try {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        $obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
        return $true
    } catch { return $false }
}

function Get-FxInteractiveUser {
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

function Get-FxDownloadsPath {
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
