#Requires -Version 5.1
<#
    HTML rendering for New-ForensicsReport.ps1. Split out because the gathering logic is worth
    reading on its own and a 400-line here-string in the middle of it makes that impossible.

    SELF-CONTAINED. No CDN, no webfont, no library, no external anything - the file is opened
    offline, possibly months later, possibly from a machine that is mid-incident. Fonts are the
    system stack. The only script is inline and vanilla, and it exists solely for the log
    reader's filtering; every insight above it renders as static HTML and stays readable with
    script disabled.
#>

# These live in the file that USES them, deliberately.
#
# The escaper used to be called ConvertTo-Html - the name of a real PowerShell cmdlet - and was
# defined in the CALLER. Dot-source this file on its own, as the first line of any render test
# would, and every call silently resolved to Microsoft.PowerShell.Utility\ConvertTo-Html: the
# user data is dropped, a full XHTML document is returned instead of an escaped fragment, and
# two w3.org URLs are injected into a report whose header promises it fetches nothing. Nothing
# would have thrown. The sibling project avoids this by prefixing (ConvertTo-PMHtml) and by
# keeping the helper next to the renderer; both halves of that are copied here.
function ConvertTo-FxHtml {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    # & first, or the escapes escape each other.
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Format-FxBytes {
    param([double]$B)
    if ($B -lt 1KB) { return ('{0:N0} B' -f $B) }
    if ($B -lt 1MB) { return ('{0:N1} KB' -f ($B / 1KB)) }
    if ($B -lt 1GB) { return ('{0:N1} MB' -f ($B / 1MB)) }
    # The TB tier is not hypothetical padding: this formats the USN journal and the Sysmon log,
    # both of which are sized in GB today and both of which an operator can raise. Without it a
    # 2 TB journal renders as "2,048.00 GB". The sibling project pinned exactly this with a test
    # called "a terabyte is not four figures of GB"; this copy had drifted without it.
    if ($B -lt 1TB) { return ('{0:N2} GB' -f ($B / 1GB)) }
    return ('{0:N2} TB' -f ($B / 1TB))
}

function New-ForensicsHtml {
    param(
        $Deletes, $ByImage, $ByDir, $Bursts, $Sentinels, $Coverage, $UsnMax,
        $Procs, $StateChanges, [int]$Days, [int]$MaxRows, $SentinelPatterns,
        [int]$BurstThreshold = 50,
        $Novel, $Baseline, [int]$DistinctPairs = 0,
        $Triage,
        # Who this report is FOR, and - the part that matters - HOW that was decided.
        $User,
        # A baseline that EXISTS but could not be parsed. Distinct from no baseline at all:
        # with an empty Pairs set every pairing looks novel, so the tile must say the check
        # could not run rather than present a full false-positive list.
        [bool]$BaselineUnreadable = $false
    )

    $css = @'
:root{--bg:#0f1115;--panel:#171a21;--panel2:#1d212a;--ink:#e6e9ef;--dim:#9aa3b2;--line:#2a2f3a;
--ok:#3fb950;--warn:#d29922;--bad:#f85149;--accent:#58a6ff}
@media(prefers-color-scheme:light){:root{--bg:#f6f7f9;--panel:#fff;--panel2:#f0f2f5;--ink:#1c2128;
--dim:#57606a;--line:#d8dee4;--ok:#1a7f37;--warn:#9a6700;--bad:#cf222e;--accent:#0969da}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
.wrap{max-width:1180px;margin:0 auto;padding:28px 20px 60px}
h1{font-size:22px;margin:0 0 4px}
.sub{color:var(--dim);font-size:13px;margin-bottom:22px}
.hero{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:18px 20px;margin-bottom:18px}
.hero .big{font-size:30px;font-weight:650;letter-spacing:-.5px}
.hero .note{color:var(--dim);font-size:13px;margin-top:4px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(215px,1fr));gap:12px;margin-bottom:18px}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:0;overflow:hidden}
.tile>summary{cursor:pointer;padding:14px 16px;display:flex;justify-content:space-between;align-items:baseline;gap:10px;list-style:none}
.tile>summary::-webkit-details-marker{display:none}
.tile>summary::after{content:"›";color:var(--dim);transition:transform .15s}
.tile[open]>summary::after{transform:rotate(90deg)}
.tile .label{color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.tile .value{font-size:22px;font-weight:650}
.tile.empty .value{color:var(--dim)}
.tile.bad .value{color:var(--bad)} .tile.warn .value{color:var(--warn)} .tile.ok .value{color:var(--ok)}
.drawer{padding:0 16px 14px;border-top:1px solid var(--line)}
.blurb{color:var(--dim);font-size:12.5px;margin:10px 0}
.rows{list-style:none;margin:0;padding:0}
.rows li{display:grid;grid-template-columns:1fr auto;gap:8px;padding:6px 0;border-top:1px solid var(--line);font-size:12.5px}
.rows li .k{word-break:break-all;font-family:ui-monospace,Consolas,monospace}
.rows li .v{color:var(--dim);white-space:nowrap}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:18px 20px;margin-bottom:18px}
.panel h2{font-size:15px;margin:0 0 12px;display:flex;align-items:center;gap:8px}
.burst{border:1px solid var(--line);border-left:3px solid var(--bad);border-radius:8px;padding:12px 14px;margin-bottom:10px;background:var(--panel2)}
.burst .hdr{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;align-items:baseline}
.burst .img{font-family:ui-monospace,Consolas,monospace;font-size:12.5px;word-break:break-all}
.burst .rate{color:var(--bad);font-weight:650;white-space:nowrap}
.burst .meta{color:var(--dim);font-size:12px;margin-top:6px}
.burst ul{margin:8px 0 0;padding-left:18px;color:var(--dim);font-size:12px}
.none{color:var(--dim);font-size:13px;padding:8px 0}
.controls{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:12px}
.controls input,.controls select{background:var(--panel2);color:var(--ink);border:1px solid var(--line);
border-radius:7px;padding:8px 10px;font:13px system-ui,sans-serif}
.controls input[type=search]{flex:1;min-width:220px}
table{width:100%;border-collapse:collapse;font-size:12.5px}
th{text-align:left;color:var(--dim);font-weight:600;font-size:11.5px;text-transform:uppercase;
letter-spacing:.04em;padding:8px 10px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--panel)}
td{padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
td.p{font-family:ui-monospace,Consolas,monospace;word-break:break-all}
td.t{white-space:nowrap;color:var(--dim)}
tr.sent td.p{color:var(--warn)}
.tblwrap{max-height:620px;overflow:auto;border:1px solid var(--line);border-radius:8px}
.count{color:var(--dim);font-size:12.5px;margin-top:10px}
.foot{color:var(--dim);font-size:12px;margin-top:26px;border-top:1px solid var(--line);padding-top:14px}
mark{background:rgba(210,153,34,.32);color:inherit;border-radius:2px}
.notice{display:flex;gap:10px;align-items:flex-start;background:var(--panel);border:1px solid var(--warn);
border-left:4px solid var(--warn);border-radius:8px;padding:12px 14px;margin:0 0 18px;font-size:13px}
.notice .tag{font-size:11px;font-weight:700;letter-spacing:.05em;color:var(--warn);white-space:nowrap;padding-top:1px}
.llm{border:1px dashed var(--accent);background:transparent}
.llm h2{color:var(--accent)}
.llm .warn-note{color:var(--dim);font-size:12.5px;border-left:3px solid var(--accent);padding:6px 0 6px 10px;margin:0 0 12px}
.llm .f{border-top:1px solid var(--line);padding:10px 0}
.llm .f:first-of-type{border-top:none}
.llm .f .hd{font-family:ui-monospace,Consolas,monospace;font-size:12.5px;word-break:break-all}
.llm .f .cf{font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:var(--dim);margin-left:6px}
.llm .f .cn{font-size:13px;margin-top:4px}
@media print{.controls,.tblwrap{max-height:none}.tile{break-inside:avoid}details{open:true}}
'@

    $sb = New-Object System.Text.StringBuilder
    $add = { param($s) [void]$sb.AppendLine($s) }

    $now = Get-Date
    & $add '<!doctype html><html lang="en"><head><meta charset="utf-8">'
    & $add '<meta name="viewport" content="width=device-width,initial-scale=1">'
    & $add '<title>Deletion Forensics Report</title>'
    & $add ('<style>' + $css + '</style></head><body><div class="wrap">')

    & $add ('<h1>Deletion forensics</h1>')
    # Entities are built OUTSIDE the escaper. Passing "&middot;" through it turns the & into
    # &amp; and the page renders the literal text "&middot;". Every other site in this file
    # already gets this right; these two did not.
    & $add ('<div class="sub">' + (ConvertTo-FxHtml ('{0:yyyy-MM-dd HH:mm}' -f $now)) +
            ' &middot; last ' + (ConvertTo-FxHtml ([string]$Days)) + ' day(s) &middot; ' +
            (ConvertTo-FxHtml ([string]$env:COMPUTERNAME)) + '</div>')

    # An INFERRED user means nothing observed a session - the profile came out of the registry
    # in whatever order the keys enumerate, and on a multi-profile machine that can be somebody
    # else. The numbers below are still real deletions; what may be wrong is whose machine
    # activity they describe and whose Downloads this landed in. Said at the top, with an icon
    # as well as a colour, because a reader who misses this misreads everything under it.
    if ($BaselineUnreadable) {
        & $add ('<div class="notice"><span class="tag">BASELINE UNREADABLE</span><span>' +
                'The novelty baseline exists but could not be parsed, so "never seen before" could not be ' +
                'computed for this run and is not shown. The damaged file has been set aside rather than ' +
                'overwritten. Every other number on this page is unaffected.</span></div>')
    }

    if ($User -and $User.Inferred) {
        & $add ('<div class="notice"><span class="tag">INFERRED USER</span><span>' +
                'Nobody was observed signed in, so the profile this report describes was taken from the ' +
                'registry rather than from a live session. It may be the wrong user. Old reports were ' +
                'NOT pruned for the same reason.</span></div>')
    }

    # ---- hero: the one number that matters ----
    $topBurst = if ($Bursts.Count) { $Bursts[0] } else { $null }
    if ($topBurst) {
        & $add '<div class="hero">'
        & $add ('<div class="big" style="color:var(--bad)">' + ('{0:N0} files in {1}s' -f $topBurst.Count, $topBurst.Seconds) + '</div>')
        & $add ('<div class="note">Largest burst: ' + (ConvertTo-FxHtml (Split-Path $topBurst.Image -Leaf)) +
                ' at ' + (ConvertTo-FxHtml ('{0:yyyy-MM-dd HH:mm:ss}' -f $topBurst.Start)) +
                '. A mass deletion looks like this - one process, many files, a short window.</div>')
        & $add '</div>'
    } else {
        & $add '<div class="hero">'
        & $add ('<div class="big" style="color:var(--ok)">No bursts</div>')
        & $add ('<div class="note">No single process deleted ' + $BurstThreshold +
                ' or more files inside a five-minute window. Routine deletion still appears below.</div>')
        & $add '</div>'
    }

    # ---- tiles ----
    # $_.Dir, not Split-Path. Every record already carries the parent, computed once at gather
    # time precisely so this would not happen - and $Sentinels is UNBOUNDED, largest in exactly
    # the incident this tool exists for. Measured: 13,740 ms vs 1,208 ms at 100,000 hits, 11.4x,
    # grouped output byte-identical. This was the fifth site of a "four sites" fix; the caller
    # side was done and this one was missed.
    $sentinelDirs = @($Sentinels | ForEach-Object { $_.Dir } | Group-Object | Sort-Object Count -Descending)
    $tiles = @(
        @{ Label = 'Deletions'; Value = ('{0:N0}' -f $Deletes.Count); Cls = ''
           Blurb = 'Files deleted in watched locations during the window. Package caches, Temp and browser caches are excluded by the Sysmon config, so this is not every deletion on the machine - it is every deletion worth looking at.'
           Rows = @($ByDir | Select-Object -First 12 | ForEach-Object { @{ K = $_.Name; V = ('{0:N0}' -f $_.Count) } }) }
        @{ Label = 'Processes'; Value = ('{0:N0}' -f $ByImage.Count); Cls = ''
           Blurb = 'Distinct executables that deleted something. A name you do not recognise here is the cheapest lead in the report.'
           Rows = @($ByImage | Select-Object -First 12 | ForEach-Object { @{ K = $_.Name; V = ('{0:N0}' -f $_.Count) } }) }
        @{ Label = 'Bursts'; Value = ('{0:N0}' -f $Bursts.Count); Cls = $(if ($Bursts.Count) { 'bad' } else { 'ok' })
           Blurb = 'A burst is one process deleting many files in a short window - the shape of a mass deletion, as opposed to a machine steadily working. Detail below.'
           Rows = @($Bursts | ForEach-Object { @{ K = (Split-Path $_.Image -Leaf); V = ('{0:N0} in {1}s' -f $_.Count, $_.Seconds) } }) }
        @{ Label = 'New pairings'
           # THREE states, not two. "0 new" and "could not look" are different answers and the
           # tile must not render the second as the first - nor as a list of everything, which
           # is what an empty-Pairs baseline would produce.
           Value = $(if ($BaselineUnreadable) { 'n/a' } elseif ($Baseline) { '{0:N0}' -f @($Novel).Count } else { 'n/a' })
           Cls = $(if ($BaselineUnreadable) { 'warn' } elseif (-not $Baseline) { '' } elseif (@($Novel).Count) { 'warn' } else { 'ok' })
           Blurb = $(if ($BaselineUnreadable) {
                       'The baseline file exists but could not be parsed, so this check could not run. It has been set aside rather than overwritten, and the next run will start a fresh one. No conclusion should be drawn from this tile today.'
                     } elseif ($Baseline) {
                       'A program deleting somewhere it has never deleted before, across ' + $Baseline.Runs +
                       ' previous run(s). This is the signal a WEEKLY report is actually for: the counts say what happened, this says what does not usually happen.'
                     } else {
                       'No baseline yet - this run establishes one. Nothing can be called new until there is something to be new against, and flagging all of it would say nothing.'
                     })
           Rows = @($(if ($BaselineUnreadable) { @() } else { $Novel }) | Select-Object -First 12 | ForEach-Object { @{ K = ('{0}  ->  {1}' -f $_.Image, $_.Dir); V = ('{0:N0}' -f $_.Count) } }) }
        @{ Label = 'Sentinel paths'; Value = ('{0:N0}' -f $Sentinels.Count); Cls = $(if ($Sentinels.Count) { 'warn' } else { 'ok' })
           Blurb = 'Deletions in quiet, valuable directories - credentials, agent configs, the toolbox, Documents. Any activity here is unusual by construction, which is why these make better sentinels than a cache.'
           Rows = @($sentinelDirs | Select-Object -First 12 | ForEach-Object { @{ K = $_.Name; V = ('{0:N0}' -f $_.Count) } }) }
    )
    & $add '<div class="grid">'
    foreach ($t in $tiles) {
        $n = @($t.Rows).Count
        $cls = 'tile ' + $t.Cls + $(if (-not $n) { ' empty' } else { '' })
        & $add ('<details class="' + $cls.Trim() + '"><summary><span class="label">' + (ConvertTo-FxHtml $t.Label) +
                '</span><span class="value">' + (ConvertTo-FxHtml $t.Value) + '</span></summary>')
        & $add ('<div class="drawer"><p class="blurb">' + (ConvertTo-FxHtml $t.Blurb) + '</p>')
        if ($n) {
            & $add '<ul class="rows">'
            foreach ($r in $t.Rows) {
                & $add ('<li><span class="k">' + (ConvertTo-FxHtml $r.K) + '</span><span class="v">' + (ConvertTo-FxHtml $r.V) + '</span></li>')
            }
            & $add '</ul>'
        } else { & $add '<p class="none">None this period.</p>' }
        & $add '</div></details>'
    }
    & $add '</div>'

    # ---- bursts detail ----
    & $add '<div class="panel"><h2>Bursts</h2>'
    if ($Bursts.Count) {
        foreach ($b in $Bursts) {
            $rate = if ($b.Seconds -gt 0) { [math]::Round($b.Count / [double]$b.Seconds, 1) } else { $b.Count }
            & $add '<div class="burst"><div class="hdr">'
            & $add ('<span class="img">' + (ConvertTo-FxHtml $b.Image) + '</span>')
            & $add ('<span class="rate">' + ('{0:N0} files / {1}s ({2}/s)' -f $b.Count, $b.Seconds, $rate) + '</span>')
            & $add '</div>'
            & $add ('<div class="meta">' + (ConvertTo-FxHtml ('{0:yyyy-MM-dd HH:mm:ss} to {1:HH:mm:ss}' -f $b.Start, $b.End)) +
                    ' &middot; ' + ('{0:N0}' -f $b.Total) + ' deletions from this process in the whole window</div>')
            if (@($b.Dirs).Count) {
                & $add '<ul>'
                foreach ($d in $b.Dirs) { & $add ('<li>' + (ConvertTo-FxHtml $d.Name) + ' &mdash; ' + ('{0:N0}' -f $d.Count) + '</li>') }
                & $add '</ul>'
            }
            & $add '</div>'
        }
    } else { & $add '<p class="none">No process deleted enough files quickly enough to qualify.</p>' }
    & $add '</div>'

    # ---- novelty ----
    & $add '<div class="panel"><h2>Never seen before</h2>'
    if (-not $Baseline) {
        & $add ('<p class="none">No baseline yet. This run recorded ' + ('{0:N0}' -f $DistinctPairs) +
                ' distinct program/directory pairing(s); from the next run on, anything outside that set is called out here.</p>')
    } elseif (@($Novel).Count) {
        & $add ('<p class="blurb">Measured against ' + $Baseline.Runs + ' previous run(s), covering ' +
                ('{0:N0}' -f $DistinctPairs) + ' pairing(s) this window. Each row is a program deleting somewhere it has not deleted before - which is not by itself wrong, only unusual, and the reason it is worth a look rather than an alarm.</p>')
        & $add '<ul class="rows">'
        foreach ($n in @($Novel | Select-Object -First 25)) {
            & $add ('<li><span class="k">' + (ConvertTo-FxHtml ('{0}  ->  {1}' -f $n.Image, $n.Dir)) +
                    '</span><span class="v">' + ('{0:N0}' -f $n.Count) + ' deletion(s)</span></li>')
        }
        & $add '</ul>'
        if (@($Novel).Count -gt 25) {
            & $add ('<p class="blurb">Showing 25 of ' + ('{0:N0}' -f @($Novel).Count) + '.</p>')
        }
    } else {
        & $add ('<p class="none">Nothing new. Every one of this window''s ' + ('{0:N0}' -f $DistinctPairs) +
                ' pairing(s) has been seen in a previous run.</p>')
    }
    & $add '<p class="blurb">Directories are generalised to four segments below the profile, because a full path is too specific to ever repeat - a per-release crate directory would make everything look new forever. Statistics, not a model: exactly reproducible run to run, and every row states its own reason.</p>'
    & $add '</div>'

    # ---- coverage: what this report cannot see ----
    & $add '<div class="panel"><h2>Coverage</h2>'
    & $add '<ul class="rows">'
    if ($Coverage) {
        & $add ('<li><span class="k">Log spans</span><span class="v">' +
                (ConvertTo-FxHtml ('{0:yyyy-MM-dd HH:mm}' -f $Coverage.Oldest)) + ' &rarr; now (' +
                (ConvertTo-FxHtml ('{0:N1} h' -f $Coverage.SpanHours)) + ')</span></li>')
        & $add ('<li><span class="k">Report is for</span><span class="v">' +
                (ConvertTo-FxHtml $(
                    if (-not $User) { 'unknown' }
                    elseif ($User.Inferred) { "$($User.Profile) (inferred, not observed)" }
                    elseif ($User.Profile) { "$($User.Profile) (signed in)" }
                    else { 'unknown' })) + '</span></li>')
        & $add ('<li><span class="k">Log size</span><span class="v">' +
                (ConvertTo-FxHtml ((Format-FxBytes $Coverage.FileSize) + ' of ' + (Format-FxBytes $Coverage.MaxSize))) + '</span></li>')
        if ($Coverage.Full) {
            & $add ('<li><span class="k">Retention (measured, log has wrapped)</span><span class="v">' +
                    ('{0:N0} h' -f $Coverage.SpanHours) + '</span></li>')
        } elseif ($Coverage.ProjectedHours) {
            & $add ('<li><span class="k">Retention at the observed rate</span><span class="v">~' +
                    ('{0:N0} h' -f $Coverage.ProjectedHours) + '</span></li>')
        }
    }
    if ($UsnMax) { & $add ('<li><span class="k">USN journal</span><span class="v">' + (Format-FxBytes $UsnMax) + '</span></li>') }
    foreach ($s in $StateChanges) {
        & $add ('<li><span class="k">Sensor ' + (ConvertTo-FxHtml $s.State) + '</span><span class="v">' +
                (ConvertTo-FxHtml ('{0:yyyy-MM-dd HH:mm:ss}' -f $s.Time)) + '</span></li>')
    }
    & $add '</ul>'
    & $add '<p class="blurb">Sysmon stopping and starting is normal at boot and on reconfiguration, but each pair is a window this log cannot describe. Retention is measured from the log itself rather than estimated: it is capped by bytes, so hours of coverage move with event size and rate.</p>'
    & $add '</div>'

    # ---- what was actually run ----
    # Event 26 says a file went. Event 1 says what was invoked. Joined by pid, the pair is the
    # difference between "rm.exe deleted 400 files" and "rm -rf /c/Users/Admin/.ollama" - and
    # the second one is the sentence an investigation actually needs. Counted over every
    # deletion in the window, not only the rows the log reader shows.
    if ($Procs -and $Procs.Count) {
        $cmdCounts = @{}
        $matched = 0
        foreach ($d in $Deletes) {
            if ($d.Guid -and $Procs.ContainsKey([string]$d.Guid)) {
                $k = [string]$Procs[[string]$d.Guid]
                if ($k) {
                    if ($cmdCounts.ContainsKey($k)) { $cmdCounts[$k]++ } else { $cmdCounts[$k] = 1 }
                    $matched++
                }
            }
        }
        if ($cmdCounts.Count) {
            & $add '<div class="panel"><h2>Command lines behind the deletions</h2>'
            & $add ('<p class="blurb">Joined to the deletions by Sysmon ProcessGuid, which is unique per ' +
                    'process. An earlier version joined on process id and attributed 955 deletions to a ping, ' +
                    'because pids are recycled within minutes and the later process overwrote the real command ' +
                    'line. A row missing here means the process started before this window, not that it had no ' +
                    'command line.</p>')
            & $add '<table><thead><tr><th>Deletions</th><th>Command line</th></tr></thead><tbody>'
            foreach ($e in ($cmdCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15)) {
                & $add ('<tr><td class="t">' + ('{0:N0}' -f $e.Value) + '</td><td class="p">' +
                        (ConvertTo-FxHtml ([string]$e.Key)) + '</td></tr>')
            }
            & $add '</tbody></table>'
            # Say how much of the picture is missing rather than presenting a partial join as whole.
            $unmatched = @($Deletes).Count - $matched
            if ($unmatched -gt 0) {
                & $add ('<p class="blurb">' + (ConvertTo-FxHtml ('{0:N0} deletion(s) have no matching process-start event in this window, usually because the process started before it began.' -f $unmatched)) + '</p>')
            }
            & $add '</div>'
        }
    }

    # ---- model-assisted triage: fenced, last, and never a fact ----
    # Rendered AFTER everything measured, inside a visually distinct dashed border, and labelled
    # in the heading and again in the body. A reader who skips it loses nothing; a reader who
    # trusts it more than the numbers above has been warned twice.
    if ($Triage) {
        & $add '<div class="panel llm"><h2>Possible leads (generated by a local model - not measurements)</h2>'
        & $add ('<p class="warn-note">Everything above this line is measured. This section is a language model''s ' +
                'reading of those measurements, kept because a machine can notice a shape in the data that a ' +
                'threshold cannot - and fenced because it can also be confidently wrong. Every claim here was ' +
                'checked to name a process and directory that appear in the data it was shown; ' +
                (ConvertTo-FxHtml ([string]$Triage.Rejected)) + ' claim(s) were discarded for failing that check. ' +
                'Treat these as leads to confirm against the facts above, never as findings.</p>')
        if (@($Triage.Findings).Count) {
            foreach ($f in @($Triage.Findings)) {
                & $add '<div class="f">'
                & $add ('<div class="hd">' + (ConvertTo-FxHtml $f.Process) + '  &rarr;  ' + (ConvertTo-FxHtml $f.Directory) +
                        '<span class="cf">' + (ConvertTo-FxHtml $f.Confidence) + ' confidence</span></div>')
                & $add ('<div class="cn">' + (ConvertTo-FxHtml $f.Concern) + '</div>')
                & $add '</div>'
            }
        } else {
            $why = if ($Triage.Reason) { $Triage.Reason } else { 'nothing it considered worth attention' }
            & $add ('<p class="none">No leads: ' + (ConvertTo-FxHtml $why) + '.</p>')
        }
        & $add ('<p class="blurb">Model: ' + (ConvertTo-FxHtml $Triage.Model) +
                '. Shown the aggregates only, never the raw log. Absent entirely when no local model is reachable.</p>')
        & $add '</div>'
    }

    # ---- log reader ----
    $rows = @($Deletes | Sort-Object Time -Descending | Select-Object -First $MaxRows)
    $imgList = @($ByImage | Select-Object -First 40 | ForEach-Object { $_.Name })

    & $add '<div class="panel"><h2>Log reader</h2>'
    & $add '<div class="controls">'
    & $add '<input type="search" id="q" placeholder="filter by path or process - try .ollama, or a process name" autocomplete="off">'
    & $add '<select id="img"><option value="">every process</option>'
    foreach ($i in $imgList) { & $add ('<option value="' + (ConvertTo-FxHtml $i) + '">' + (ConvertTo-FxHtml (Split-Path $i -Leaf)) + '</option>') }
    & $add '</select>'
    & $add '<select id="sent"><option value="">all paths</option><option value="1">sentinel paths only</option></select>'
    & $add '</div>'
    & $add '<div class="tblwrap"><table><thead><tr><th>Time</th><th>Process</th><th>Path</th></tr></thead><tbody id="tb">'

    # THE ONE HOT LOOP IN THIS FILE. Everything above renders once; this runs MaxRows times,
    # 4,000 by default, and three conveniences that are free elsewhere are not free here:
    #
    #   & $add          a scriptblock invocation per line - 257 ms per 4,000 rows against 10 ms
    #                   for calling AppendLine directly. Kept everywhere else in this file,
    #                   where it reads better and costs nothing.
    #   Split-Path -Leaf  a cmdlet with provider resolution per row - 318 ms against 17 ms for
    #                   [IO.Path]::GetFileName.
    #   re-matching the sentinel patterns  15 regexes per row, recomputing a classification the
    #                   gather loop already did and stored on the record.
    #
    # $r.IsSentinel is preferred when present, with the pattern loop kept as the fallback so a
    # caller that hands over raw records (a test, or an older gather) still gets the right
    # answer rather than silently losing the highlight.
    $useFlag = ($rows.Count -gt 0) -and ($null -ne $rows[0].PSObject.Properties['IsSentinel'])
    foreach ($r in $rows) {
        if ($useFlag) {
            $isSent = [bool]$r.IsSentinel
        } else {
            $isSent = $false
            foreach ($p in $SentinelPatterns) { if ($r.Path -match $p) { $isSent = $true; break } }
        }
        $cls = if ($isSent) { ' class="sent"' } else { '' }
        # The COMMAND LINE, joined from Sysmon event 1 by pid. This was gathered, counted on the
        # console and handed to this function, and then never rendered - so the report showed
        # that rm.exe deleted something while silently holding the argv that says what was asked
        # for. "rm.exe" and "rm -rf /c/Users/Admin/.ollama" are not the same finding.
        $cmd = if ($Procs -and $r.Guid -and $Procs.ContainsKey([string]$r.Guid)) { [string]$Procs[[string]$r.Guid] } else { '' }
        $ttl = if ($cmd) { ' title="' + (ConvertTo-FxHtml $cmd) + '"' } else { '' }
        [void]$sb.AppendLine('<tr' + $cls + ' data-i="' + (ConvertTo-FxHtml $r.Image) + '" data-s="' + $(if ($isSent) { '1' } else { '0' }) + '">' +
                '<td class="t">' + (ConvertTo-FxHtml ('{0:MM-dd HH:mm:ss}' -f $r.Time)) + '</td>' +
                '<td class="p"' + $ttl + '>' + (ConvertTo-FxHtml ([IO.Path]::GetFileName($r.Image))) + '</td>' +
                '<td class="p">' + (ConvertTo-FxHtml $r.Path) + '</td></tr>')
    }
    & $add '</tbody></table></div>'
    $shown = @($rows).Count
    $note = if ($Deletes.Count -gt $shown) {
        'Showing the most recent {0:N0} of {1:N0} deletions. Every count above is over all {1:N0}.' -f $shown, $Deletes.Count
    } else { 'Showing all {0:N0} deletions in the window.' -f $shown }
    & $add ('<div class="count" id="cnt">' + (ConvertTo-FxHtml $note) + '</div>')
    & $add '</div>'

    & $add ('<div class="foot">Generated by scripts\New-ForensicsReport.ps1 (scripts-utilities). Self-contained: nothing in this file is fetched from the network. Sysmon event 26 records deletions per FILE, so a recursive tree removal appears as many rows sharing one process.</div>')

    # Inline, vanilla, and only for the reader. Everything above renders without it.
    $js = @'
(function(){
  var q=document.getElementById('q'), img=document.getElementById('img'),
      sent=document.getElementById('sent'), tb=document.getElementById('tb'),
      cnt=document.getElementById('cnt'), base=cnt.textContent,
      rows=[].slice.call(tb.rows), t=null;
  function apply(){
    var term=q.value.toLowerCase(), im=img.value, so=sent.value, n=0;
    for(var i=0;i<rows.length;i++){
      var r=rows[i], ok=true;
      if(im && r.getAttribute('data-i')!==im) ok=false;
      if(ok && so==='1' && r.getAttribute('data-s')!=='1') ok=false;
      if(ok && term && r.textContent.toLowerCase().indexOf(term)<0) ok=false;
      r.style.display = ok ? '' : 'none';
      if(ok) n++;
    }
    cnt.textContent = (term||im||so) ? (n.toLocaleString()+' matching row(s). '+base) : base;
  }
  function debounce(){ clearTimeout(t); t=setTimeout(apply,120); }
  q.addEventListener('input',debounce);
  img.addEventListener('change',apply);
  sent.addEventListener('change',apply);
})();
'@
    & $add ('<script>' + $js + '</script>')
    & $add '</div></body></html>'
    return $sb.ToString()
}
