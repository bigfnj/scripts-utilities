#Requires -Version 5.1
<#
    ShimPlan.ps1 - the pure planning layer behind scripts\consolidate-path.ps1: which shim
    points at which executable, and which PATH entries are safe to take out.

    WHY THIS FILE EXISTS. consolidate-path.ps1 is a SCRIPT that reads the registry at load and
    calls `exit` on several paths, so nothing can import it - the same constraint that produced
    scripts\ForensicsReport.Core.ps1 and lib\SysmonConfig.ps1. Everything with a decision in it
    lives here instead, takes its filesystem as a scriptblock seam, and returns data.

    WHY IT EXISTS *NOW*. On 2026-09-10 %LOCALAPPDATA%\DevToolbox was deleted. Its native\bin
    held the .cmd shims that were the ONLY PATH route to 27 winget portable packages, because
    consolidate-path.ps1 had previously removed those packages' own directories from PATH in
    favour of the shims. The packages were all still on disk. Nothing could rebuild the shims:
    discovery was `$mEntries + $uEntries | Where-Object { $_ -like '*\WinGet\Packages\*' }`,
    with no filesystem enumeration anywhere in the file, so on a correctly-consolidated box it
    found ZERO candidates - and bootstrap.ps1 could not help either, because Install-WingetTool
    treats "winget list knows the id" as success and writes no shim. 13 tools (gh, fzf, bat,
    delta, just, hyperfine, sops, age, tokei, trurl, yt-dlp, deno, etl2pcapng) had no recovery
    route at all.

    ENUMERATION ORDER IS NOT A RANK. This is the load-bearing semantic here. A recursive walk
    of the packages root yields 27 packages / 53 executables / 47 distinct basenames, and
    exactly three names are contested: ffmpeg, ffprobe and ffplay, shipped by
    BtbN.FFmpeg.GPL.Shared.7.1, Gyan.FFmpeg.Essentials and yt-dlp.FFmpeg. Alphabetical disk
    order puts BtbN first - and INVERTS the only contested decision on the box, because
    build-devtoolbox.ps1:43 declares Gyan.FFmpeg.Essentials as the toolbox's ffmpeg and Gyan is
    what actually won the 2026-08-27 run. So a walk MUST NOT derive priority from the order it
    happened to see things in. Priority comes from an authoritative order (the live PATH, a
    logs\path-backup-*.json, or the persisted .shim-sources.json) or from an explicit -Pick,
    and a contested name with neither is SKIPPED and reported rather than guessed.

    Tested by: tests\Invoke-InstallerTests.ps1
#>

. (Join-Path $PSScriptRoot 'ShimFormat.ps1')   # New-ShimBody / Get-ShimTarget

# Split-PathList and Remove-PathEntryFromString live next door. Dot-sourced unconditionally
# rather than behind a Get-Command probe: both files define functions only, so re-defining them
# costs nothing, and a conditional import is the kind of thing that works until two callers
# source the pair in the other order.
. (Join-Path $PSScriptRoot 'path-registry.ps1')

# The persisted shim map's shape. Bump this and New-ShimSourcesDocument together.
$script:ShimSourcesSchemaVersion = 1
# config\path-hygiene.json's shape. Same rule.
$script:PathHygieneSchemaVersion = 1

function Get-ShimNormalKey {
    # One normalisation for every path comparison in this file: no trailing separator, case
    # folded. ToLowerInvariant, not ToLower - the machine PATH is compared under whatever
    # culture the scheduled task happens to run in, and Turkish dotless-i really does fold
    # 'I' differently.
    param([AllowEmptyString()][string]$Path)
    $t = ([string]$Path).Trim()
    if ($t.EndsWith('\')) { $t = $t.Substring(0, $t.Length - 1) }
    return $t.ToLowerInvariant()
}

function Join-ShimPath {
    # String concatenation, NEVER Join-Path. Join-Path resolves the drive qualifier through the
    # PowerShell provider and throws "Cannot find drive. A drive with the name 'P' does not
    # exist." for any path on a drive that is not mounted. That rules it out twice over here: a
    # planner that claims to touch no filesystem must not be consulting the provider, and the
    # suite's fixtures live on P:\ on purpose, so a test that accidentally reaches the real
    # filesystem FAILS instead of passing on whatever this box happens to hold.
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Child)
    return ($Parent.TrimEnd('\') + '\' + $Child.TrimStart('\'))
}

function Get-ShimPackageRoot {
    <#
        The TOP-LEVEL package directory a path sits under, or $null if it is not under the
        packages root at all.

        Why the top level and not the directory holding the .exe: winget stamps the version
        into a SUBfolder (Gyan.FFmpeg.Essentials_...\ffmpeg-8.1.1-essentials_build\bin), so
        that subfolder's name changes on every upgrade. Ranking and the sibling rule both have
        to survive an upgrade, so both key on the part that does not move.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$PackagesRoot
    )
    $rootKey = Get-ShimNormalKey $PackagesRoot
    $key = Get-ShimNormalKey $Path
    if (-not $key.StartsWith($rootKey + '\')) { return $null }
    $rest = ([string]$Path).Trim().Substring($PackagesRoot.TrimEnd('\').Length + 1)
    $leaf = @($rest -split '\\' | Where-Object { $_ })
    if ($leaf.Count -eq 0) { return $null }
    return (Join-ShimPath -Parent $PackagesRoot -Child $leaf[0])
}

function Get-ShimPackageOrder {
    <#
        Reduce an ordered list of PATH entries to the ordered, de-duplicated list of package
        directories they name. Entries outside the packages root are dropped, not ranked -
        C:\Program Files\nodejs is not a priority statement about ffmpeg.
    #>
    param(
        [string[]]$Entries = @(),
        [Parameter(Mandatory)][string]$PackagesRoot
    )
    $seen = @{}
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in @($Entries)) {
        $pkg = Get-ShimPackageRoot -Path $e -PackagesRoot $PackagesRoot
        if (-not $pkg) { continue }
        $k = Get-ShimNormalKey $pkg
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out.Add($pkg)
    }
    return @($out.ToArray())
}

function Get-ShimPriority {
    <#
        Ranked package directories from a logs\path-backup-*.json, machine-then-user - the order
        Windows composes the session PATH in, which is what makes "first one wins" agree with
        what used to resolve.

        Takes JSON TEXT, not a path, so the suite can exercise every malformed shape without a
        fixture file on disk.

        Shape is checked by PROPERTY PRESENCE, never by truthiness. Under
        Set-StrictMode -Version Latest - which fresh-toolbox-setup-runner.ps1:28 sets and
        passes down, because it invokes this script with & - reading a property a
        ConvertFrom-Json object does not have THROWS, and reading one that is merely absent
        from the JSON yields $null and would make an empty priority list indistinguishable
        from a backup that never had a machine PATH.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][string]$PackagesRoot
    )
    if (-not $Json.Trim()) { throw 'PATH backup is empty.' }
    $o = $null
    try { $o = $Json | ConvertFrom-Json } catch { throw "PATH backup is not valid JSON: $($_.Exception.Message)" }
    if (-not $o) { throw 'PATH backup parsed to nothing.' }
    $names = @($o.PSObject.Properties.Name)
    foreach ($need in @('machine', 'user')) {
        if ($names -notcontains $need) {
            throw "PATH backup has no '$need' field - it is not a logs\path-backup-*.json (fields: $($names -join ', '))."
        }
    }
    $entries = @()
    $entries += Split-PathList ([string]$o.machine)
    $entries += Split-PathList ([string]$o.user)
    return @(Get-ShimPackageOrder -Entries $entries -PackagesRoot $PackagesRoot)
}

function Get-ShimCandidates {
    <#
        Every shimmable executable under the packages root (or under the given -Dirs), as
        @{ Name; Target; Package; PackageId; Dir }.

        -Filter THREE TIMES, NEVER -Include. Get-ChildItem silently ignores -Include unless the
        path ends in \* or -Recurse is set, so an -Include *.exe here matched README.md, .pdb
        and .dll alike and would have generated a shim called README.cmd. Caught by the first
        dry run in 2026-08; the comment it left behind at consolidate-path.ps1:254 is the only
        reason this is not re-litigated every time somebody tidies the loop.

        THE RETURNED ORDER IS NOT A RANK - see the file header. Callers that need one ask
        Get-ShimPlan for it with -PriorityOrder.
    #>
    param(
        [Parameter(Mandatory)][string]$PackagesRoot,
        # Default mode hands in the PATH entries it is about to drop, which are leaf bin
        # directories and must not be walked recursively. Rebuild mode hands in nothing and the
        # whole tree under $PackagesRoot is walked - measured at 141 ms for 27 packages, so
        # there is no reason to cache it.
        [string[]]$Dirs,
        [scriptblock]$Enumerate = {
            param($Path, $Filter, $Recurse)
            Get-ChildItem -LiteralPath $Path -File -Filter $Filter -Recurse:$Recurse -ErrorAction SilentlyContinue
        }
    )
    $roots = @()
    $recurse = $false
    if ($PSBoundParameters.ContainsKey('Dirs') -and @($Dirs).Count -gt 0) { $roots = @($Dirs) }
    else { $roots = @($PackagesRoot); $recurse = $true }

    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in $roots) {
        foreach ($ext in @('*.exe', '*.cmd', '*.bat')) {
            foreach ($f in @(& $Enumerate $root $ext $recurse)) {
                $full = [string]$f.FullName
                if (-not $full) { continue }
                $pkg = Get-ShimPackageRoot -Path $full -PackagesRoot $PackagesRoot
                $out.Add([pscustomobject]@{
                    Name      = [IO.Path]::GetFileNameWithoutExtension($full)
                    Target    = $full
                    Package   = $pkg
                    PackageId = if ($pkg) { Split-Path $pkg -Leaf } else { '' }
                    Dir       = [IO.Path]::GetDirectoryName($full)
                })
            }
        }
    }
    return @($out.ToArray())
}

# New-ShimBody and Get-ShimTarget used to live here. They moved to lib\ShimFormat.ps1 so the
# four writers in modules\security.ps1 and the one in scripts\build-devtoolbox.ps1 could reach
# them without dot-sourcing this whole planner - see that file's header for the topology.

function Get-ShimExisting {
    <#
        What is already in native\bin, as @{ Name; Wrapper; Target; Parsed }. Parsed=$false
        means somebody hand-wrote the .cmd and Get-ShimTarget found no target line in it.
    #>
    param(
        [Parameter(Mandatory)][string]$NativeBin,
        [scriptblock]$Enumerate = {
            param($Dir)
            Get-ChildItem -LiteralPath $Dir -File -Filter '*.cmd' -ErrorAction SilentlyContinue
        },
        [scriptblock]$ReadLines = {
            param($Path)
            Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
        }
    )
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($w in @(& $Enumerate $NativeBin)) {
        $path = [string]$w.FullName
        if (-not $path) { continue }
        $target = Get-ShimTarget -Lines @(& $ReadLines $path)
        $out.Add([pscustomobject]@{
            Name    = [IO.Path]::GetFileNameWithoutExtension($path)
            Wrapper = $path
            Target  = $target
            Parsed  = [bool]$target
        })
    }
    return @($out.ToArray())
}

function Get-ShimPlan {
    <#
        Decide, for every name, whether to write a shim and where it should point.

        COLLISION RULE, FIRST MATCH WINS:

          1 existing     a wrapper exists and its target exists       -> KEEP, never write
          2 stale        a wrapper exists and its target is GONE      -> eligible for refresh
          3 unparseable  the .cmd exists but no line matches          -> treat as existing
          4 pick         -Pick <name>=<PackageIdPrefix> names it      -> bind
          5 rank         highest-ranked candidate (-PriorityOrder)    -> bind, report shadowed
          6 sole         exactly one package supplies the name        -> bind
          7 sibling      another name is already bound INSIDE one of  -> bind to that package
                         this name's candidate packages
          8 contested    none of the above                            -> SKIP and report

        Rule 1 is why builder-owned wrappers win BY CONSTRUCTION: build-devtoolbox.ps1 runs
        first, so its venv wrappers are already on disk and this planner never touches them.
        consolidate-path.ps1's comment claimed that for a year ("Never shim over a wrapper the
        toolbox builder owns") while implementing only `if ($name -eq 'consolidate-path')`, and
        the writer had no Test-Path at all - an open BACKLOG bug.

        Rule 2 is why the refusal is not unconditional. A wrapper whose target a winget upgrade
        moved is worse than a missing one, because the tool still resolves by name and then
        fails on execution - and smoke-test.ps1:287 tells the operator to re-run this script to
        fix exactly that. Refusing every existing wrapper would make every stale shim permanent
        and turn that instruction into a lie.

        Rank is consulted only for CONTESTED names. With one candidate there is nothing to
        rank, and on this box 44 of 47 names have one candidate - reporting all 44 as "rank:n"
        because a backup happened to be supplied would bury the 3 decisions that matter.
    #>
    param(
        [object[]]$Candidates = @(),
        [object[]]$Existing = @(),
        # Test seam. Supply a predicate so the suite can describe a filesystem that does not
        # exist here, rather than depending on which packages this box happens to hold.
        [scriptblock]$TargetExists = { param($p) Test-Path -LiteralPath $p -PathType Leaf },
        [string[]]$Pick = @(),
        [string[]]$PriorityOrder = @(),
        [string]$NativeBin = '',
        # Never shim ourselves: consolidate-path.cmd in native\bin would shadow the script.
        [string[]]$Skip = @('consolidate-path')
    )

    $pickMap = Get-ShimPickMap -Pick $Pick
    $skipKeys = @(@($Skip) | ForEach-Object { ([string]$_).ToLowerInvariant() })

    $rank = @{}
    $i = 0
    foreach ($d in @($PriorityOrder)) {
        $k = Get-ShimNormalKey $d
        if (-not $rank.ContainsKey($k)) { $rank[$k] = $i }
        $i++
    }

    $byName = @{}
    foreach ($c in @($Candidates)) {
        $k = ([string]$c.Name).ToLowerInvariant()
        if (-not $byName.ContainsKey($k)) { $byName[$k] = New-Object 'System.Collections.Generic.List[object]' }
        $byName[$k].Add($c)
    }
    $existByName = @{}
    foreach ($e in @($Existing)) {
        $k = ([string]$e.Name).ToLowerInvariant()
        if (-not $existByName.ContainsKey($k)) { $existByName[$k] = $e }
    }

    # A -Pick nobody can honour is an operator error, and silently ignoring it would leave the
    # name contested while the operator believes it was resolved.
    foreach ($pk in @($pickMap.Keys)) {
        # The skip list wins over -Pick, and that has to be SAID. The main loop below tests
        # $skipKeys and `continue`s before it ever reads $pickMap, so a -Pick naming a
        # never-shim name passed every check here and was then discarded in silence - the
        # operator gets "44 written, 0 contested" and no hint that the one decision they made
        # by hand was thrown away. That is the same defect class this validation block was
        # added to prevent, one loop further on.
        if ($skipKeys -contains $pk) {
            throw ("-Pick '$pk=$($pickMap[$pk])' names '$pk', which is on the never-shim list, " +
                   "so the pick could not be honoured. Remove it from -Skip, or drop the -Pick.")
        }
        if (-not $byName.ContainsKey($pk)) {
            throw "-Pick '$pk=$($pickMap[$pk])' names '$pk', which no package under the packages root supplies."
        }
        $hits = @($byName[$pk] | Where-Object { $_.PackageId -like ($pickMap[$pk] + '*') })
        if ($hits.Count -eq 0) {
            $have = @($byName[$pk] | ForEach-Object { $_.PackageId } | Select-Object -Unique)
            throw "-Pick '$pk=$($pickMap[$pk])' matches no package supplying '$pk'. Candidates: $($have -join ', ')."
        }
    }

    $write = New-Object 'System.Collections.Generic.List[object]'
    $kept = New-Object 'System.Collections.Generic.List[object]'
    $shadowed = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[object]'
    $deferred = New-Object 'System.Collections.Generic.List[string]'
    $bound = @{}    # lower name -> target already decided, for the sibling rule

    $allKeys = @(@(@($byName.Keys) + @($existByName.Keys)) | Select-Object -Unique | Sort-Object)

    foreach ($key in $allKeys) {
        # @( ) AROUND THE WHOLE if. An if-statement's output goes through the pipeline, which
        # unrolls a one-element array - so `$x = if (...) { @($one) }` yields a SCALAR and the
        # next line's .Count throws under strict mode. Bit us here on the 44 sole names.
        $cands = @(if ($byName.ContainsKey($key)) { @($byName[$key] | Sort-Object Target) } else { @() })
        $display = if ($cands.Count -gt 0) { [string]$cands[0].Name } else { [string]$existByName[$key].Name }

        if ($skipKeys -contains $key) {
            $skipped.Add([pscustomobject]@{ Name = $display; Reason = 'on the never-shim list' })
            continue
        }

        # --- rules 1-3: something is already on disk -------------------------------
        $refresh = $false
        if ($existByName.ContainsKey($key)) {
            $e = $existByName[$key]
            if (-not $e.Parsed) {
                $kept.Add((New-ShimKept -Name $display -Wrapper $e.Wrapper -Target $e.Target `
                    -Reason 'unparseable' -Would (Get-ShimWouldBe -Cands $cands -PickMap $pickMap -Key $key -Rank $rank)))
                if ($e.Target) { $bound[$key] = $e.Target }
                continue
            }
            if (& $TargetExists $e.Target) {
                $kept.Add((New-ShimKept -Name $display -Wrapper $e.Wrapper -Target $e.Target `
                    -Reason 'existing' -Would (Get-ShimWouldBe -Cands $cands -PickMap $pickMap -Key $key -Rank $rank)))
                $bound[$key] = $e.Target
                continue
            }
            if ($cands.Count -eq 0) {
                # Stale AND nothing supplies it. A rebuild cannot fix this one, and saying so is
                # the whole value: smoke-test.ps1 will keep reporting it every run otherwise.
                $kept.Add((New-ShimKept -Name $display -Wrapper $e.Wrapper -Target $e.Target `
                    -Reason 'stale-no-source' -Would ''))
                continue
            }
            $refresh = $true
        }
        if ($cands.Count -eq 0) { continue }

        # --- rules 4-6 ---------------------------------------------------------------
        $chosen = $null
        $because = ''
        if ($pickMap.ContainsKey($key)) {
            $hits = @($cands | Where-Object { $_.PackageId -like ($pickMap[$key] + '*') })
            if (@($hits | ForEach-Object { Get-ShimNormalKey $_.Package } | Select-Object -Unique).Count -gt 1) {
                throw ("-Pick '$key=$($pickMap[$key])' is ambiguous - it matches " +
                       (@($hits | ForEach-Object { $_.PackageId } | Select-Object -Unique) -join ', ') + '.')
            }
            $chosen = $hits[0]
            $because = 'pick'
        } elseif ($cands.Count -eq 1) {
            $chosen = $cands[0]
            $because = 'sole'
        } else {
            $ranked = @($cands | Where-Object { $_.Package -and $rank.ContainsKey((Get-ShimNormalKey $_.Package)) } |
                Sort-Object { $rank[(Get-ShimNormalKey $_.Package)] })
            if ($ranked.Count -gt 0) {
                $chosen = $ranked[0]
                $because = 'rank:' + $rank[(Get-ShimNormalKey $chosen.Package)]
            }
        }

        if (-not $chosen) { $deferred.Add($key); continue }

        $write.Add((New-ShimWrite -Chosen $chosen -Cands $cands -Because $because -Refresh $refresh -NativeBin $NativeBin))
        $bound[$key] = $chosen.Target
        foreach ($loser in @($cands | Where-Object { $_.Target -ne $chosen.Target })) {
            $shadowed.Add([pscustomobject]@{ Name = $display; Target = $loser.Target; PackageId = $loser.PackageId; Chosen = $chosen.Target })
        }
    }

    # --- rule 7: sibling, once every non-contested binding is known ------------------
    # Iterated, because ffmpeg binding lets ffprobe bind which lets ffplay bind. Bounded by the
    # number of deferred names, so a cycle cannot spin.
    # MEMOISED BY INPUT, which is why this cannot go stale: the same string always normalises to
    # the same key, so the cache is a property of Get-ShimNormalKey and not of $bound's contents.
    # Caching per KEY instead would break silently the day a rule re-binds a name.
    #
    # Measured 2026-09-11, because BACKLOG recorded this shape as a quadratic nobody had priced.
    # Get-ShimNormalKey costs 78 us a call - dispatch, not the two string operations - and the
    # innermost iteration of this four-deep loop called it on every pass. Old against new, at
    # both shapes, asserted to produce the same hit count:
    #
    #   real  (deferred 6, bound 47, cands 3)     555 ms ->    64 ms   8.7x
    #   worst (deferred 47, bound 47, cands 3) 27,393 ms -> 2,916 ms   9.4x
    #
    # 50 distinct paths get normalised now, in place of 5,076 and 311,469 calls. What is left at
    # the worst shape is the loop itself, not the normalisation. The sibling rule's own two tests
    # cover the behaviour, and they must keep passing.
    #
    # Its neighbour in that BACKLOG entry, the `shadowed` hygiene predicate, was measured at the
    # same time and REJECTED: 33.8 ms against 31.4 ms for a HashSet at this box's real scale.
    # Same "genuinely quadratic shape", opposite verdict, which is the whole reason the entry
    # said measure first.
    # THE LOOKUP IS INLINE, and a scriptblock wrapper around it would have been a no-op. A
    # closure call costs the same ~64 us of dispatch as the function call it replaces - this
    # repo has measured that twice already (the `& $add` renderer closure at 257 ms / 4,000 rows,
    # and [Array]::FindIndex with a [Predicate[byte]] coming out SLOWER than a PowerShell loop).
    # Three call sites of inline hashtable check is uglier and is the only version that is faster.
    $normMemo = @{}
    $progress = $true
    while ($progress -and $deferred.Count -gt 0) {
        $progress = $false
        foreach ($key in @($deferred.ToArray())) {
            $cands = @($byName[$key] | Sort-Object Target)
            $display = [string]$cands[0].Name
            $pkgHits = @()
            foreach ($c in @($cands)) {
                if (-not $c.Package) { continue }
                $pk = [string]$c.Package
                if (-not $normMemo.ContainsKey($pk)) { $normMemo[$pk] = Get-ShimNormalKey $pk }
                $prefix = $normMemo[$pk] + '\'
                foreach ($bk in @($bound.Keys)) {
                    if ($bk -eq $key) { continue }
                    $bt = [string]$bound[$bk]
                    if (-not $normMemo.ContainsKey($bt)) { $normMemo[$bt] = Get-ShimNormalKey $bt }
                    if ($normMemo[$bt].StartsWith($prefix)) {
                        $pkgHits += [pscustomobject]@{ Cand = $c; Via = $bk }
                    }
                }
            }
            # More than one package with evidence means the box disagrees with itself; guessing
            # there is exactly the behaviour this rule set refuses.
            $distinctSet = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($h in $pkgHits) {
                $hp = [string]$h.Cand.Package
                if (-not $normMemo.ContainsKey($hp)) { $normMemo[$hp] = Get-ShimNormalKey $hp }
                [void]$distinctSet.Add($normMemo[$hp])
            }
            $distinct = @($distinctSet)
            if ($pkgHits.Count -eq 0 -or $distinct.Count -ne 1) { continue }
            $chosen = $pkgHits[0].Cand
            $write.Add((New-ShimWrite -Chosen $chosen -Cands $cands -Because ('sibling:' + $pkgHits[0].Via) -Refresh $false -NativeBin $NativeBin))
            $bound[$key] = $chosen.Target
            foreach ($loser in @($cands | Where-Object { $_.Target -ne $chosen.Target })) {
                $shadowed.Add([pscustomobject]@{ Name = $display; Target = $loser.Target; PackageId = $loser.PackageId; Chosen = $chosen.Target })
            }
            $deferred.Remove($key) | Out-Null
            $progress = $true
        }
    }

    # --- rule 8: contested -----------------------------------------------------------
    $contested = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in @($deferred.ToArray())) {
        $cands = @($byName[$key] | Sort-Object Target)
        $ids = @(@($cands | ForEach-Object { Get-ShimPickPrefix -PackageId $_.PackageId }) | Select-Object -Unique | Sort-Object)
        # The hint lists EVERY option and recommends none. Naming the first one would recommend
        # BtbN for ffmpeg purely because B sorts before G - the exact inversion the file header
        # exists to prevent - and an operator copying the suggested command would silently
        # install the wrong ffmpeg on a box whose builder declares Gyan.
        $contested.Add([pscustomobject]@{
            Name       = [string]$cands[0].Name
            Candidates = @($cands | ForEach-Object { [pscustomobject]@{ Target = $_.Target; PackageId = $_.PackageId } })
            Command    = ('-Pick "{0}=<prefix>"  where <prefix> is one of: {1}' -f $cands[0].Name, ($ids -join ' | '))
        })
    }

    return @{
        Write     = @($write.ToArray())
        Kept      = @($kept.ToArray())
        Refreshed = @(@($write.ToArray()) | Where-Object { $_.Refresh })
        Contested = @($contested.ToArray())
        Shadowed  = @($shadowed.ToArray())
        Skipped   = @($skipped.ToArray())
    }
}

function Get-ShimPickMap {
    <#
        Parse -Pick into a lowercased name -> package-id-prefix map.

        SPLITS EACH ELEMENT ON COMMAS, because an array cannot survive the UAC hop. Measured:
        Start-Process joins -ArgumentList with spaces, and powershell.exe -File does NOT parse
        an array literal - forwarding  -Pick "a=b","c=d"  lands in the child as a SINGLE element
        whose value is the string  a=b,c=d . Accepting that form here means the elevated child
        computes the same plan as its parent instead of quietly planning a different one. A
        winget package id contains no comma, so the split is unambiguous.
    #>
    param([string[]]$Pick = @())
    $map = @{}
    foreach ($raw in @($Pick)) {
        foreach ($p in @(([string]$raw) -split ',')) {
            if (-not $p.Trim()) { continue }
            if ($p -notmatch '^\s*([^=]+?)\s*=\s*(\S.*?)\s*$') {
                throw "-Pick expects '<name>=<PackageIdPrefix>' (e.g. -Pick `"ffmpeg=Gyan.FFmpeg`"), got '$p'."
            }
            $map[$Matches[1].ToLowerInvariant()] = $Matches[2]
        }
    }
    return $map
}

function Get-ShimPickPrefix {
    # A winget package FOLDER is '<id>_<source>_<publisher hash>', e.g.
    # Gyan.FFmpeg.Essentials_Microsoft.Winget.Source_8wekyb3d8bbwe - 59 characters of which 36
    # are boilerplate. -Pick matches on a PREFIX, so the id alone is enough and is what a
    # human will actually retype. An id the pattern does not recognise is returned whole rather
    # than truncated on a guess.
    param([AllowEmptyString()][string]$PackageId)
    return (([string]$PackageId) -replace '_Microsoft\.Winget\.Source_.*$', '')
}

function Get-ShimWouldBe {
    # What a name WOULD have been bound to had a wrapper not already existed. Reported on every
    # kept entry, because "kept" without it hides the decision the operator came to check.
    param([object[]]$Cands = @(), [hashtable]$PickMap = @{}, [string]$Key = '', [hashtable]$Rank = @{})
    if (@($Cands).Count -eq 0) { return '' }
    if ($PickMap.ContainsKey($Key)) {
        $hits = @($Cands | Where-Object { $_.PackageId -like ($PickMap[$Key] + '*') })
        if ($hits.Count -gt 0) { return ('pick -> ' + $hits[0].Target) }
    }
    if (@($Cands).Count -eq 1) { return ('sole -> ' + $Cands[0].Target) }
    $ranked = @($Cands | Where-Object { $_.Package -and $Rank.ContainsKey((Get-ShimNormalKey $_.Package)) } |
        Sort-Object { $Rank[(Get-ShimNormalKey $_.Package)] })
    if ($ranked.Count -gt 0) { return ('rank:' + $Rank[(Get-ShimNormalKey $ranked[0].Package)] + ' -> ' + $ranked[0].Target) }
    return ('contested (' + (@(@($Cands | ForEach-Object { $_.PackageId }) | Select-Object -Unique) -join ', ') + ')')
}

function New-ShimKept {
    param([string]$Name, [string]$Wrapper, [AllowEmptyString()][AllowNull()][string]$Target, [string]$Reason, [AllowEmptyString()][string]$Would)
    return [pscustomobject]@{ Name = $Name; Wrapper = $Wrapper; Target = $Target; Reason = $Reason; Would = $Would }
}

function New-ShimWrite {
    param($Chosen, [object[]]$Cands = @(), [string]$Because, [bool]$Refresh, [string]$NativeBin)
    $wrapper = if ($NativeBin) { Join-ShimPath -Parent $NativeBin -Child ($Chosen.Name + '.cmd') } else { $Chosen.Name + '.cmd' }
    return [pscustomobject]@{
        Name      = [string]$Chosen.Name
        Target    = [string]$Chosen.Target
        PackageId = [string]$Chosen.PackageId
        Wrapper   = $wrapper
        Because   = $Because
        Refresh   = $Refresh
        Rivals    = @(@($Cands | Where-Object { $_.Target -ne $Chosen.Target } | ForEach-Object { $_.Target }))
    }
}

function Invoke-ShimWrite {
    <#
        Write the plan. Returns @{ Written; Refused }.

        THE REFUSAL BELOW IS A SECOND, INDEPENDENT CHECK, not a restatement of Get-ShimPlan's
        rule 1. The planner decides; this refuses. Until now the writer had no Test-Path at all
        (consolidate-path.ps1:356-364), so ANY caller bug - a hand-built plan, a future mode, a
        planner regression - silently overwrote a wrapper build-devtoolbox.ps1 owns, and the
        venv CLI it pointed at stopped resolving with nothing anywhere recording why. An
        overwrite is only permitted for an entry the planner explicitly marked Refresh, i.e.
        one whose target has gone missing.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$NativeBin,
        [scriptblock]$FileExists = { param($p) Test-Path -LiteralPath $p -PathType Leaf },
        [scriptblock]$WriteFile = { param($p, $body) Set-Content -LiteralPath $p -Value $body -Encoding ASCII -NoNewline }
    )
    if (-not $Plan.ContainsKey('Write')) { throw 'plan has no Write list - Get-ShimPlan always supplies one, so this is a caller bug.' }
    $written = New-Object 'System.Collections.Generic.List[object]'
    $refused = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in @($Plan.Write)) {
        $wrapper = if ($e.Wrapper) { [string]$e.Wrapper } else { Join-ShimPath -Parent $NativeBin -Child ($e.Name + '.cmd') }
        if ((& $FileExists $wrapper) -and -not $e.Refresh) {
            $refused.Add([pscustomobject]@{ Name = [string]$e.Name; Wrapper = $wrapper; Reason = 'a wrapper already exists and the plan did not mark it for refresh' })
            continue
        }
        & $WriteFile $wrapper (New-ShimBody -Target ([string]$e.Target))
        $written.Add([pscustomobject]@{ Name = [string]$e.Name; Wrapper = $wrapper; Target = [string]$e.Target })
    }
    return @{ Written = @($written.ToArray()); Refused = @($refused.ToArray()) }
}

function New-ShimSourcesDocument {
    <#
        The persisted shim map: what each shim points at, which package it came from, and WHY
        that package won.

        NOT in toolbox-manifest.json, deliberately. The builder writes that file whole, and it
        was deleted alongside native\bin on 2026-09-10 - so it has the same blast radius as the
        thing it would be recovering. Two copies instead: one beside the shims for whoever
        finds the directory, and one in logs\ for whoever finds the repo after the directory is
        gone. priority_order is the durable replacement for the lucky survival of
        logs\path-backup-20260909-203021.json, which is currently the only record anywhere of
        the 27 packages in resolution order.

        The leading dot on .shim-sources.json keeps it out of the *.cmd globs at
        build-devtoolbox.ps1:766 and smoke-test.ps1:280, so neither mistakes it for a wrapper.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrioritySource,
        [string[]]$PriorityOrder = @()
    )
    $shims = [ordered]@{}
    foreach ($e in @($Plan.Write | Sort-Object Name)) {
        $shims[[string]$e.Name] = [ordered]@{
            target         = [string]$e.Target
            package        = [string]$e.PackageId
            wrapper        = [string]$e.Wrapper
            chosen_because = [string]$e.Because
            rivals         = @($e.Rivals)
        }
    }
    $contested = [ordered]@{}
    foreach ($c in @($Plan.Contested | Sort-Object Name)) {
        $contested[[string]$c.Name] = [ordered]@{
            candidates = @($c.Candidates | ForEach-Object { [string]$_.Target })
            resolve_with = [string]$c.Command
        }
    }
    $keptBlock = [ordered]@{}
    foreach ($k in @($Plan.Kept | Sort-Object Name)) {
        $keptBlock[[string]$k.Name] = [ordered]@{
            target  = [string]$k.Target
            wrapper = [string]$k.Wrapper
            reason  = [string]$k.Reason
            would   = [string]$k.Would
        }
    }
    return [ordered]@{
        schema_version  = $script:ShimSourcesSchemaVersion
        captured_at     = (Get-Date).ToString('o')
        mode            = $Mode
        priority_source = $PrioritySource
        priority_order  = @($PriorityOrder)
        shims           = $shims
        contested       = $contested
        kept            = $keptBlock
    }
}

function Read-ShimSources {
    <#
        Parse a persisted shim map and REFUSE an unknown schema_version.

        Same reason Get-Catalog refuses one (lib\catalog.ps1:29-35): a reshaped document
        deserialises perfectly well, every field this code asks for comes back $null, and the
        rebuild silently runs with an empty priority list - which on this box means the three
        ffmpeg names go from "resolved" to "contested" with no error anywhere. Under strict mode
        the $null fields would instead throw somewhere unrelated, which is not much better.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    if (-not $Json.Trim()) { throw 'shim map is empty.' }
    $o = $null
    try { $o = $Json | ConvertFrom-Json } catch { throw "shim map is not valid JSON: $($_.Exception.Message)" }
    if (-not $o) { throw 'shim map parsed to nothing.' }
    $names = @($o.PSObject.Properties.Name)
    if ($names -notcontains 'schema_version') {
        throw "shim map has no schema_version (expected $script:ShimSourcesSchemaVersion)."
    }
    if ([int]$o.schema_version -ne $script:ShimSourcesSchemaVersion) {
        throw ("shim map schema_version {0} is not supported by this checkout (expected {1})." -f $o.schema_version, $script:ShimSourcesSchemaVersion)
    }
    if ($names -notcontains 'priority_order') { throw 'shim map has no priority_order.' }
    return $o
}

function Test-PathPlanChanged {
    <#
        Did the plan actually change either PATH? Compares NORMALISED ENTRY LISTS per scope.

        NOT string equality. A trailing ';', a re-ordered de-duplication, an entry regaining a
        trailing backslash - each makes the two strings differ while the PATH is semantically
        identical, and the only consumer of this answer is the elevation gate. Getting it wrong
        drags a pure shim rebuild, which writes no registry value at all, through a UAC prompt.
        -SyncWindow 0 so a REORDER still counts as a change: order is resolution priority here,
        not presentation.
    #>
    param(
        [string[]]$BeforeMachine = @(), [string[]]$AfterMachine = @(),
        [string[]]$BeforeUser = @(), [string[]]$AfterUser = @()
    )
    $norm = { param($a) @(@($a) | ForEach-Object { Get-ShimNormalKey $_ }) }
    foreach ($pair in @(@{ B = $BeforeMachine; A = $AfterMachine }, @{ B = $BeforeUser; A = $AfterUser })) {
        $b = @(& $norm $pair.B)
        $a = @(& $norm $pair.A)
        if ($b.Count -ne $a.Count) { return $true }
        if ($b.Count -eq 0) { continue }
        if (@(Compare-Object -ReferenceObject $b -DifferenceObject $a -SyncWindow 0).Count -gt 0) { return $true }
    }
    return $false
}

function Get-SelfElevateArgs {
    <#
        The command line the UAC child is launched with. Pure, so the suite can prove that a
        newly-declared parameter reaches the child.

        THIS IS THE HIGHEST-RISK CODE IN THE FEATURE. The old Invoke-SelfElevate hand-listed
        -TargetMax and -ElevatedFor, so any switch added later was silently dropped: the parent
        would report "rebuild only, no PATH write", raise UAC, and the child - seeing none of
        the flags - would run PLAIN consolidation and DROP PATH ENTRIES the parent never
        intended to drop. Forwarding is therefore derived from $PSBoundParameters with an
        explicit exclusion list, so the failure mode is "an unexpected parameter is forwarded"
        (loud, the child rejects it) instead of "an expected one is not" (silent, the child
        does something else).

        EVERY VALUE IS QUOTED. Start-Process joins -ArgumentList with spaces and does not quote
        for you, so an unquoted C:\some dir\x.json arrives as two arguments.

        AN ARRAY IS FORWARDED AS ONE COMMA-JOINED ARGUMENT. Measured: -File rejects a repeated
        parameter outright ("parameter 'Pick' is specified more than once") and does not parse
        an array literal either - "a=b","c=d" arrives as the single string a=b,c=d. So the
        comma form is the only one that survives, and Get-ShimPickMap splits on commas to meet
        it.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Sid,
        [int]$TargetMax = 3500,
        [hashtable]$Bound = @{},
        [string[]]$NeverForward = @()
    )
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath),
                     '-TargetMax', ('"{0}"' -f $TargetMax), '-ElevatedFor', ('"{0}"' -f $Sid))) {
        $list.Add($a)
    }
    foreach ($k in @(@($Bound.Keys) | Sort-Object)) {
        if (@($NeverForward) -contains $k) { continue }
        $v = $Bound[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $list.Add('-' + $k) }
            continue
        }
        if ($v -is [bool]) {
            if ($v) { $list.Add('-' + $k) }
            continue
        }
        $items = @(@($v) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        if ($items.Count -eq 0) { continue }
        foreach ($item in $items) {
            # A value containing a double quote cannot be expressed on this command line at all.
            # Refuse it rather than hand the child a re-tokenised version of itself.
            if ($item.Contains('"')) { throw "cannot forward -$k to the elevated run: the value contains a double quote ($item)." }
        }
        $list.Add('-' + $k)
        $list.Add('"{0}"' -f ($items -join ','))
    }
    return @($list.ToArray())
}

function Get-PathResolutionMap {
    <#
        Which PATH entry actually provides each bare command name, in the order given
        (machine-then-user is how Windows composes the session PATH). First provider wins, which
        is what "shadowed" means everywhere else in this file.

        EXISTENCE AND CONTENTS ARE MEASURED ON THE EXPANDED PATH. 5 of this box's 43 machine
        entries are %VAR%-based, so a naive pass over the raw values sees
        %SystemRoot%\system32 as a directory that does not exist - and a hygiene rule built on
        that would propose deleting system32. The RAW value is what comes back in .Entry,
        because that is what has to be matched for removal.
    #>
    param(
        [string[]]$Entries = @(),
        [scriptblock]$Enumerate = {
            param($Dir)
            $out = @()
            foreach ($ext in @('*.exe', '*.cmd', '*.bat')) {
                $out += @(Get-ChildItem -LiteralPath $Dir -File -Filter $ext -ErrorAction SilentlyContinue |
                    ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
            }
            return $out
        },
        [scriptblock]$Expand = { param($s) [Environment]::ExpandEnvironmentVariables($s) },
        # Shared between the before and after passes so a directory is walked once per run.
        [hashtable]$Cache = @{}
    )
    $map = @{}
    foreach ($raw in @($Entries)) {
        $expanded = [string](& $Expand $raw)
        $ck = Get-ShimNormalKey $expanded
        if (-not $Cache.ContainsKey($ck)) { $Cache[$ck] = @(& $Enumerate $expanded) }
        foreach ($n in @($Cache[$ck])) {
            $nk = ([string]$n).ToLowerInvariant()
            if ($map.ContainsKey($nk)) { continue }
            $map[$nk] = [pscustomobject]@{ Name = [string]$n; Entry = $raw; Expanded = $expanded }
        }
    }
    return $map
}

function Get-PathHygienePlan {
    <#
        Which ratified PATH entries are still safe to remove, and what removing them changes.

        EVERY PRECONDITION IS RE-MEASURED HERE, never trusted from the file. config\path-hygiene.json
        is a list of entries somebody ratified on one particular day; a machine moves. An entry
        whose precondition no longer holds is SKIPPED and reported - the alternative is a config
        file that quietly deletes a PATH entry that has since become the only provider of
        something. Predicates:

          duplicate-in-machine  the identical entry is in the machine hive RIGHT NOW (user-scope
                                entries only - removing the user copy is only a no-op because the
                                machine copy answers for it)
          no-executables        the expanded directory holds zero *.exe / *.cmd / *.bat
          shadowed              every basename it provides is also provided EARLIER in the
                                composed machine-then-user order, except names the entry declares
                                in expect_unresolved

        Returns @{ RemoveMachine; RemoveUser; Skipped; NewMachine; NewUser; Delta }.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MachineRaw,
        [Parameter(Mandatory)][AllowEmptyString()][string]$UserRaw,
        [scriptblock]$Enumerate,
        [scriptblock]$Expand = { param($s) [Environment]::ExpandEnvironmentVariables($s) }
    )
    if (-not $Json.Trim()) { throw 'path-hygiene config is empty.' }
    $cfg = $null
    try { $cfg = $Json | ConvertFrom-Json } catch { throw "path-hygiene config is not valid JSON: $($_.Exception.Message)" }
    if (-not $cfg) { throw 'path-hygiene config parsed to nothing.' }
    $cfgNames = @($cfg.PSObject.Properties.Name)
    if ($cfgNames -notcontains 'schema_version') { throw "path-hygiene config has no schema_version (expected $script:PathHygieneSchemaVersion)." }
    if ([int]$cfg.schema_version -ne $script:PathHygieneSchemaVersion) {
        throw ("path-hygiene config schema_version {0} is not supported by this checkout (expected {1})." -f $cfg.schema_version, $script:PathHygieneSchemaVersion)
    }
    if ($cfgNames -notcontains 'entries') { throw 'path-hygiene config has no entries array.' }

    $mEntries = Split-PathList $MachineRaw
    $uEntries = Split-PathList $UserRaw
    $composed = @($mEntries + $uEntries)

    $enumArgs = @{}
    if ($PSBoundParameters.ContainsKey('Enumerate')) { $enumArgs['Enumerate'] = $Enumerate }
    $cache = @{}
    $provides = {
        param($Dir)
        $ck = Get-ShimNormalKey $Dir
        if (-not $cache.ContainsKey($ck)) {
            $one = Get-PathResolutionMap -Entries @($Dir) -Expand $Expand -Cache @{} @enumArgs
            $cache[$ck] = @(@($one.Values) | ForEach-Object { $_.Name })
        }
        return @($cache[$ck])
    }

    $machineKeys = @(@($mEntries) | ForEach-Object { Get-ShimNormalKey (& $Expand $_) })
    $removeM = New-Object 'System.Collections.Generic.List[string]'
    $removeU = New-Object 'System.Collections.Generic.List[string]'
    $skipped = New-Object 'System.Collections.Generic.List[object]'

    foreach ($entry in @($cfg.entries)) {
        $props = @($entry.PSObject.Properties.Name)
        foreach ($need in @('scope', 'entry', 'require', 'reason')) {
            if ($props -notcontains $need) { throw "path-hygiene entry is missing '$need': $($entry | ConvertTo-Json -Compress)" }
        }
        $scope = [string]$entry.scope
        $declared = [string]$entry.entry
        $require = [string]$entry.require
        $expectUnresolved = @()
        if ($props -contains 'expect_unresolved') { $expectUnresolved = @($entry.expect_unresolved) }

        $wantKey = Get-ShimNormalKey (& $Expand $declared)
        $scopeEntries = @(if ($scope -eq 'machine') { $mEntries } elseif ($scope -eq 'user') { $uEntries } else { @() })
        if ($scope -ne 'machine' -and $scope -ne 'user') {
            $skipped.Add([pscustomobject]@{ Scope = $scope; Entry = $declared; Require = $require; Why = "unknown scope '$scope'" })
            continue
        }
        # Match on the EXPANDED value, keep the RAW one: the registry holds the literal, and the
        # literal is the only thing Remove-PathEntryFromString can be asked to take out.
        $raw = @(@($scopeEntries) | Where-Object { (Get-ShimNormalKey (& $Expand $_)) -eq $wantKey } | Select-Object -First 1)
        if ($raw.Count -eq 0) {
            $skipped.Add([pscustomobject]@{ Scope = $scope; Entry = $declared; Require = $require; Why = 'not on the ' + $scope + ' PATH any more' })
            continue
        }
        $rawValue = [string]$raw[0]

        $ok = $false
        $why = ''
        switch ($require) {
            'duplicate-in-machine' {
                if ($scope -ne 'user') {
                    $why = "duplicate-in-machine only makes sense for a user-scope entry, not '$scope'"
                } elseif ($machineKeys -contains $wantKey) {
                    $ok = $true
                } else {
                    $why = 'the machine hive no longer carries the same entry, so the user copy is now the only one'
                }
            }
            'no-executables' {
                $names = @(& $provides $rawValue)
                if ($names.Count -eq 0) { $ok = $true }
                else { $why = "now provides $($names.Count) executable(s): " + (@($names | Sort-Object | Select-Object -First 6) -join ', ') }
            }
            'shadowed' {
                $idx = -1
                for ($i = 0; $i -lt $composed.Count; $i++) {
                    if ((Get-ShimNormalKey (& $Expand $composed[$i])) -eq $wantKey) { $idx = $i; break }
                }
                $earlier = @()
                for ($i = 0; $i -lt $idx; $i++) { $earlier += @(& $provides $composed[$i]) }
                $earlierKeys = @(@($earlier) | ForEach-Object { ([string]$_).ToLowerInvariant() })
                $expectKeys = @(@($expectUnresolved) | ForEach-Object { ([string]$_).ToLowerInvariant() })
                $exposed = @(@(& $provides $rawValue) | Where-Object {
                    ($earlierKeys -notcontains ([string]$_).ToLowerInvariant()) -and
                    ($expectKeys -notcontains ([string]$_).ToLowerInvariant())
                })
                if ($exposed.Count -eq 0) { $ok = $true }
                else { $why = 'would stop resolving: ' + (@($exposed | Sort-Object) -join ', ') }
            }
            default { $why = "unknown require '$require'" }
        }

        if (-not $ok) {
            $skipped.Add([pscustomobject]@{ Scope = $scope; Entry = $rawValue; Require = $require; Why = $why })
            continue
        }
        if ($scope -eq 'machine') { $removeM.Add($rawValue) } else { $removeU.Add($rawValue) }
    }

    $newM = Remove-PathEntryFromString -Value $MachineRaw -Remove @($removeM.ToArray())
    $newU = Remove-PathEntryFromString -Value $UserRaw -Remove @($removeU.ToArray())

    $deltaCache = @{}
    $before = Get-PathResolutionMap -Entries $composed -Expand $Expand -Cache $deltaCache @enumArgs
    $after = Get-PathResolutionMap -Entries @($newM.Kept + $newU.Kept) -Expand $Expand -Cache $deltaCache @enumArgs
    $delta = New-Object 'System.Collections.Generic.List[object]'
    foreach ($nk in @(@($before.Keys) | Sort-Object)) {
        if (-not $after.ContainsKey($nk)) {
            $delta.Add([pscustomobject]@{ Name = $before[$nk].Name; Change = 'unresolved'; From = $before[$nk].Entry; To = '' })
        } elseif ((Get-ShimNormalKey $after[$nk].Entry) -ne (Get-ShimNormalKey $before[$nk].Entry)) {
            $delta.Add([pscustomobject]@{ Name = $before[$nk].Name; Change = 'moved'; From = $before[$nk].Entry; To = $after[$nk].Entry })
        }
    }

    return @{
        RemoveMachine = @($removeM.ToArray())
        RemoveUser    = @($removeU.ToArray())
        Skipped       = @($skipped.ToArray())
        NewMachine    = [string]$newM.Value
        NewUser       = [string]$newU.Value
        KeptMachine   = @($newM.Kept)
        KeptUser      = @($newU.Kept)
        Delta         = @($delta.ToArray())
    }
}
