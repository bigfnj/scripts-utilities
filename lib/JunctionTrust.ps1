#Requires -Version 5.1
<#
    JunctionTrust.ps1 - find directory junctions an ELEVATED process refuses to follow, and
    recreate them so that it can. Dot-sourcing defines functions only.

    THE CONDITION, measured 2026-10-30 on a Windows 11 25H2 workstation:

      - An elevated process (High integrity, Administrators enabled) refuses to traverse a junction
        that was created with a non-admin token. Every open through it fails with WinError 448,
        ERROR_UNTRUSTED_MOUNT_POINT, "The path cannot be traversed because it contains an untrusted
        mount point". SYSTEM refuses the same junctions.
      - An UNELEVATED process follows the very same junction without complaint. So the owner never
        sees it, while an agent host that runs elevated finds a venv whose base interpreter is "not
        there": the venv launcher prints `No Python at '"...python.exe'` and exits 103 for a file
        that plainly exists.
      - A junction recreated by an elevated process is followed by both.
      - OWNERSHIP DOES NOT CONFER TRUST. Setting the junction's owner to Administrators
        (icacls /setowner /L) changed nothing. Trust is decided when the junction is created.

    WHO MAKES THEM: uv's minor-version links (%APPDATA%\uv\python\cpython-3.11-windows-x86_64-none
    and friends), npm workspace links (node_modules\@scope\pkg pointing back at a workspace
    folder), and hand-made folder moves. Any of those run unelevated makes one again, so this is
    upkeep rather than a one-time repair. A sweep of one workstation found 361 untrusted junctions,
    of which 73 were live links worth recreating; see docs\junction-trust.md.

    WHAT NEVER HAPPENS HERE: a recursive delete. The one deletion of a user's link is
    [IO.Directory]::Delete($Path, $false), on a path that has just been re-read as a junction that
    points at the planned target. RemoveDirectory on a junction removes the link and cannot reach
    the target's contents, and the non-recursive call refuses a real directory that has children.
#>

function Get-JtWin32Code {
    # The Win32 error code inside an HRESULT, or $null when it is not a FACILITY_WIN32 value.
    # Arithmetic on the halves rather than a hex mask, because an 8-digit hex literal is a signed
    # Int32 in PowerShell and 0xFFFF0000 would not mean what it says.
    param([int]$HResult)
    if ((($HResult -shr 16) -band 0x7FF) -ne 7) { return $null }
    return ($HResult -band 0xFFFF)
}

function Test-JtElevated {
    # True only for an ELEVATED token. Under UAC a filtered admin token carries Administrators as a
    # deny-only group, so IsInRole is false there, which is exactly the distinction this file needs.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
}

function Get-JtLinkTrust {
    <#
        Can THIS process traverse the directory at -Path? One enumerator MoveNext through it, the
        cheapest open that has to cross the mount point. Measured identical under 5.1 and 7:
            untrusted   IOException, HResult 0x800701C0 (WinError 448)
            dangling    DirectoryNotFoundException, HResult 0x80070003
            trusted     no exception

        Status: ok | untrusted | dangling | denied | error.

        AN UNTRUSTED JUNCTION WHOSE TARGET IS ALSO GONE REPORTS 'untrusted', not 'dangling': the
        trust check fires before the target is resolved. 105 of the 177 untrusted npm links in the
        first sweep were dangling as well. New-JtPlan therefore asks about the target separately.

        THE VERDICT DEPENDS ON WHO ASKS. From an unelevated shell an untrusted junction is 'ok'.
        Callers that need the elevated answer must check Test-JtElevated themselves.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$Probe = {
            param($Directory)
            $e = [IO.Directory]::EnumerateFileSystemEntries($Directory).GetEnumerator()
            try { $null = $e.MoveNext() } finally { $e.Dispose() }
        }
    )
    try {
        $null = & $Probe $Path
        return [pscustomobject]@{ Status = 'ok'; Win32 = $null; Message = '' }
    } catch {
        $ex = $_.Exception
        while ($ex -is [Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
        $code = Get-JtWin32Code $ex.HResult
        $status = if ($code -eq 448) { 'untrusted' }
                  elseif ($ex -is [IO.DirectoryNotFoundException] -or $code -eq 2 -or $code -eq 3) { 'dangling' }
                  elseif ($ex -is [UnauthorizedAccessException] -or $code -eq 5) { 'denied' }
                  else { 'error' }
        return [pscustomobject]@{ Status = $status; Win32 = $code; Message = $ex.Message }
    }
}

function Get-JtJunctionTarget {
    # The target of a directory junction, or $null when -Path is not one (a symlink, a cloud
    # placeholder, an app-exec alias). Reads the LINK itself, never through it, so it works on an
    # untrusted junction from an elevated shell.
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ([string]$item.LinkType -ne 'Junction') { return $null }
    $target = [string](@($item.Target)[0])
    if ($target.StartsWith('\\?\') -or $target.StartsWith('\??\')) { $target = $target.Substring(4) }
    if (-not $target) { return $null }
    return $target
}

function Test-JtExcluded {
    # $Exclusions must already be full paths with no trailing separator (Get-JtNormalPath).
    param([Parameter(Mandatory)][string]$Path, [string[]]$Exclusions = @())
    foreach ($x in $Exclusions) {
        if ($Path.Equals($x, [StringComparison]::OrdinalIgnoreCase) -or
            $Path.StartsWith($x + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-JtNormalPath {
    # Full path, no trailing separator, except that a drive root keeps its '\': 'D:' alone means
    # "the current directory on D:", which is not the drive.
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Find-JtJunctions {
    <#
        Every directory junction under -Root, found WITHOUT descending into any reparse point:
        junctions, symlinks, cloud placeholders, all of them. Descending would visit a tree twice at
        best and loop at worst, and it would open the very links whose trust is in question.

        Exclusions are pruned BEFORE descending, and a junction whose own path is excluded is not
        reported either.

        Returns ONE object: Junctions (Path, Target), Directories (how many were listed) and
        Unreadable (paths that could not be listed, reported rather than dropped, because a walker
        that swallows access errors turns "I could not look" into "there is nothing there").

        -ListDirectories and -ReadLink are injectable so the walk can be tested with names alone.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Root,
        [string[]]$Exclude = @(),
        [scriptblock]$ListDirectories = {
            param($Directory)
            ([IO.DirectoryInfo]::new($Directory)).EnumerateDirectories()
        },
        [scriptblock]$ReadLink = { param($Path) Get-JtJunctionTarget -Path $Path }
    )
    $exclusions = @($Exclude | Where-Object { $_ } | ForEach-Object { Get-JtNormalPath $_ })
    # EXACT MATCH IS ENOUGH below the roots, so the per-child test is a hash lookup rather than a
    # function call over every exclusion. The walk never follows a link, so an excluded directory
    # can only be reached as a direct child of its parent, and pruning it there prunes everything
    # under it. The prefix test is needed only for a ROOT that sits inside an exclusion, which is
    # checked once per root below. For scale: D: on the first workstation, 399,998 directories,
    # took 93 s under 5.1 on a WARM file cache; that is a runtime, not a before/after comparison.
    $excluded = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $exclusions) { $null = $excluded.Add($x) }
    $junctions = New-Object 'Collections.Generic.List[object]'
    $unreadable = New-Object 'Collections.Generic.List[string]'
    $listed = 0
    $pending = New-Object 'Collections.Generic.Stack[string]'
    foreach ($r in $Root) {
        $normal = Get-JtNormalPath $r
        if (-not (Test-JtExcluded -Path $normal -Exclusions $exclusions)) { $pending.Push($normal) }
    }
    while ($pending.Count) {
        $directory = $pending.Pop()
        try {
            foreach ($child in (& $ListDirectories $directory)) {
                $full = [string]$child.FullName
                if ($excluded.Contains($full)) { continue }
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $target = $null
                    try { $target = & $ReadLink $full } catch { $unreadable.Add($full) }
                    if ($target) { $junctions.Add([pscustomobject]@{ Path = $full; Target = [string]$target }) }
                    continue
                }
                $pending.Push($full)
            }
            $listed++
        } catch {
            $unreadable.Add($directory)
        }
    }
    return [pscustomobject]@{ Junctions = @($junctions.ToArray()); Directories = $listed; Unreadable = @($unreadable.ToArray()) }
}

function Get-JtDefaultExclusions {
    <#
        What the sweep never touches, each for a reason:

          %SystemRoot%       Windows' own links, all created trusted. Also the bulk of C:'s
                             directories, so skipping it is most of the walk time on C:.
          the user's TEMP    leftovers of finished processes and test runs. 182 of 361 untrusted
                             junctions in the first sweep were here, and nothing durable uses them.
          other profiles     links in another account's profile belong to that account. The first
                             sweep found a sandbox account's link into the owner's profile, and
                             making it admin-trusted would change how that boundary behaves.
          $Recycle.Bin and System Volume Information on every scanned drive.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Root,
        [string]$SystemRoot = $env:SystemRoot,
        [string]$Temp = [IO.Path]::GetTempPath(),
        [string]$UserProfile = $env:USERPROFILE,
        [scriptblock]$ListProfiles = {
            param($UsersDirectory)
            @(Get-ChildItem -LiteralPath $UsersDirectory -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
    )
    # String and [IO.Path] arithmetic only. Join-Path and Split-Path consult the provider, and against
    # a drive that does not exist they misbehave under Stop; that broke this repo's CI once.
    $list = New-Object 'Collections.Generic.List[string]'
    if ($SystemRoot) { $list.Add((Get-JtNormalPath $SystemRoot)) }
    if ($Temp) { $list.Add((Get-JtNormalPath $Temp)) }
    foreach ($drive in @($Root | ForEach-Object { [IO.Path]::GetPathRoot((Get-JtNormalPath $_)) } | Sort-Object -Unique)) {
        $list.Add($drive + '$Recycle.Bin')
        $list.Add($drive + 'System Volume Information')
    }
    if ($UserProfile) {
        $me = Get-JtNormalPath $UserProfile
        foreach ($p in @(& $ListProfiles ([IO.Path]::GetDirectoryName($me)))) {
            $other = Get-JtNormalPath ([string]$p)
            if (-not $other.Equals($me, [StringComparison]::OrdinalIgnoreCase)) { $list.Add($other) }
        }
    }
    return @($list.ToArray())
}

function New-JtPlan {
    <#
        One entry per junction that is NOT plainly fine, with the decision the apply step will act on:
            recreate   untrusted, and the target is there
            dangling   the target is gone; recreating it would only make a trusted dead link
            denied     this process may not open it at all; not ours to change
            error      anything else, recorded with its message
        Trusted junctions are counted, not listed.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Junctions,
        [scriptblock]$Probe,
        [scriptblock]$TargetExists = { param($Target) Test-Path -LiteralPath $Target -PathType Container }
    )
    $probeArgs = @{}
    if ($Probe) { $probeArgs['Probe'] = $Probe }
    $entries = New-Object 'Collections.Generic.List[object]'
    $trusted = 0
    foreach ($j in $Junctions) {
        $trust = Get-JtLinkTrust -Path $j.Path @probeArgs
        if ($trust.Status -eq 'ok') { $trusted++; continue }
        $decision = switch ($trust.Status) {
            'untrusted' { if (& $TargetExists $j.Target) { 'recreate' } else { 'dangling' } }
            'dangling'  { 'dangling' }
            'denied'    { 'denied' }
            default     { 'error' }
        }
        $entries.Add([pscustomobject][ordered]@{
            path = [string]$j.Path; target = [string]$j.Target; status = $trust.Status
            win32 = $trust.Win32; decision = $decision; message = $trust.Message })
    }
    return [pscustomobject]@{ Entries = @($entries.ToArray()); Trusted = $trusted }
}

function Invoke-JtRecreate {
    <#
        Recreate ONE planned junction from this (elevated) process. Every precondition is re-read
        now rather than trusted from the plan, because a plan is a snapshot and a worktree can be
        deleted or re-linked between review and apply:

          1. the path still exists and is still a JUNCTION, never a real directory;
          2. it still points at the planned target;
          3. the target still exists as a directory;
          4. this process still cannot traverse it, so a link that became trusted is left alone.

        Only then is the link removed, NON-recursively, and made again. A failed re-create is
        retried once and then reported as LOST with the exact mklink line to restore it by hand,
        so nothing can vanish without saying so. Outcomes: recreated, recreated-unverified, LOST,
        and skipped-<reason>.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [scriptblock]$Probe,
        [scriptblock]$ReadLink = { param($LinkPath) Get-JtJunctionTarget -Path $LinkPath }
    )
    $probeArgs = @{}
    if ($Probe) { $probeArgs['Probe'] = $Probe }
    $outcome = { param($Name, $Detail) [pscustomobject][ordered]@{ path = $Path; target = $Target; outcome = $Name; detail = [string]$Detail } }
    $same = { param($A, $B) ([string]$A).TrimEnd('\').Equals(([string]$B).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }

    if (-not (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) { return & $outcome 'skipped-missing' '' }
    $current = & $ReadLink $Path
    if (-not $current) { return & $outcome 'skipped-not-junction' '' }
    if (-not (& $same $current $Target)) { return & $outcome 'skipped-target-changed' $current }
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) { return & $outcome 'skipped-target-missing' '' }
    $before = Get-JtLinkTrust -Path $Path @probeArgs
    if ($before.Status -ne 'untrusted') { return & $outcome 'skipped-not-untrusted' $before.Status }

    try { [IO.Directory]::Delete($Path, $false) }
    catch { return & $outcome 'skipped-in-use' $_.Exception.Message }
    if (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue) { return & $outcome 'skipped-in-use' 'still present after delete' }

    $made = $false
    $why = ''
    foreach ($attempt in 1, 2) {
        try { $null = New-Item -ItemType Junction -Path $Path -Value $Target -ErrorAction Stop; $made = $true; break }
        catch { $why = $_.Exception.Message }
    }
    if (-not $made) { return & $outcome 'LOST' ('recreate by hand: mklink /J "{0}" "{1}" ({2})' -f $Path, $Target, $why) }

    $after = Get-JtLinkTrust -Path $Path @probeArgs
    $again = & $ReadLink $Path
    if ($after.Status -ne 'ok' -or -not (& $same $again $Target)) {
        return & $outcome 'recreated-unverified' ('status={0} target={1}' -f $after.Status, $again)
    }
    return & $outcome 'recreated' ''
}

function New-JtUntrustedWitness {
    <#
        THE POSITIVE CONTROL. A clean sweep means nothing unless this process can be shown to detect
        an untrusted junction at all: a probe that never fires reads exactly like a workstation with
        nothing to fix. So make one with a NON-ADMIN token and require Get-JtLinkTrust to call it
        untrusted.

        `runas /trustlevel:0x20000` runs mklink under a restricted Basic User token. Measured
        2026-10-30: the process stays at High integrity, yet the junction it makes is refused by an
        elevated process, which is the condition under test. runas returns before its child has
        finished, so the link is polled for.

        runas takes its whole command as ONE argument, so the mklink line goes into a .cmd file and
        runas is handed that file's 8.3 short path. A path that still has a space in it (8.3 names
        disabled on the volume) makes the control UNAVAILABLE, and the caller must say so.

        Returns Root (pass it to Remove-JtWitness), Fired, Status and Detail.
    #>
    param(
        [string]$Parent = [IO.Path]::GetTempPath(),
        [int]$TimeoutMs = 15000,
        [scriptblock]$Probe
    )
    $probeArgs = @{}
    if ($Probe) { $probeArgs['Probe'] = $Probe }
    $root = Join-Path $Parent ('su-junction-witness-' + [guid]::NewGuid().ToString('N'))
    $target = Join-Path $root 'target'
    $link = Join-Path $root 'link'
    $script = Join-Path $root 'make.cmd'
    $null = New-Item -ItemType Directory -Path $target -Force
    [IO.File]::WriteAllText((Join-Path $target 'probe.txt'), 'probe')
    [IO.File]::WriteAllText($script, ('@mklink /J "{0}" "{1}" >nul' -f $link, $target) + "`r`n")
    $short = Get-JtShortPath $script
    if ($short -match '[\s"]') {
        return [pscustomobject]@{ Root = $root; Fired = $false; Status = 'unavailable'; Detail = "no space-free short path for $script" }
    }
    $null = & runas.exe '/trustlevel:0x20000' ('cmd.exe /c ' + $short)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while (-not (Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Root = $root; Fired = $false; Status = 'unavailable'; Detail = "runas /trustlevel made no junction within $TimeoutMs ms" }
    }
    $trust = Get-JtLinkTrust -Path $link @probeArgs
    return [pscustomobject]@{ Root = $root; Fired = ($trust.Status -eq 'untrusted'); Status = $trust.Status; Detail = $trust.Message }
}

function Remove-JtWitness {
    # Undo New-JtUntrustedWitness with NON-recursive deletes only: the link first, so nothing below
    # can be reached through it, then the probe file, the target, the script and the root. Returns
    # the paths it could not remove, which the caller reports.
    param([Parameter(Mandatory)][string]$Root)
    $left = New-Object 'Collections.Generic.List[string]'
    if (-not ([IO.Path]::GetFileName($Root) -match '^su-junction-witness-[0-9a-f]{32}$')) { throw "Not a junction witness: $Root" }
    $link = Join-Path $Root 'link'
    $target = Join-Path $Root 'target'
    $steps = @(
        @{ Path = $link; Run = { if (Get-JtJunctionTarget -Path $link) { [IO.Directory]::Delete($link, $false) } } }
        @{ Path = (Join-Path $target 'probe.txt'); Run = { [IO.File]::Delete((Join-Path $target 'probe.txt')) } }
        @{ Path = $target; Run = { [IO.Directory]::Delete($target, $false) } }
        @{ Path = (Join-Path $Root 'make.cmd'); Run = { [IO.File]::Delete((Join-Path $Root 'make.cmd')) } }
        @{ Path = $Root; Run = { [IO.Directory]::Delete($Root, $false) } }
    )
    foreach ($s in $steps) {
        if (-not (Get-Item -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue)) { continue }
        try { & $s.Run } catch { $left.Add($s.Path) }
    }
    return @($left.ToArray())
}

function Get-JtShortPath {
    # The 8.3 spelling of an existing path, or the path itself when the volume has none.
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('JunctionTrust.Native' -as [type])) {
        Add-Type -Namespace JunctionTrust -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern uint GetShortPathName(string path, System.Text.StringBuilder output, uint size);
'@
    }
    $buffer = New-Object Text.StringBuilder 32768
    $size = [JunctionTrust.Native]::GetShortPathName($Path, $buffer, 32768)
    if ($size -eq 0 -or $size -ge 32768) { return $Path }
    return $buffer.ToString()
}

function Get-JtVenvHomeState {
    <#
        Is the toolbox venv's base interpreter reachable from THIS shell? pyvenv.cfg's `home` is
        opened on every venv start. When it runs through an untrusted junction, an elevated host gets
        `No Python at ...` (exit 103) for a file that is there, and everything built on the toolbox
        Python stops for that host only.

        Status: ok | untrusted | dangling | denied | error | no-home. ThroughLink says whether any
        component of `home` is a reparse point, because only then does the asker's elevation matter:
        an UNELEVATED 'ok' through a link cannot vouch for an elevated host.
    #>
    param(
        [Parameter(Mandatory)][string]$PyvenvCfg,
        [scriptblock]$Probe,
        [bool]$Elevated = (Test-JtElevated)
    )
    $probeArgs = @{}
    if ($Probe) { $probeArgs['Probe'] = $Probe }
    $homeLine = @(Get-Content -LiteralPath $PyvenvCfg -ErrorAction Stop | Where-Object { $_ -match '^\s*home\s*=' }) | Select-Object -First 1
    if (-not $homeLine) {
        return [pscustomobject]@{ Home = ''; Status = 'no-home'; ThroughLink = $false; Elevated = $Elevated; Message = 'pyvenv.cfg has no home line' }
    }
    $venvHome = ($homeLine -replace '^\s*home\s*=\s*', '').Trim()
    $throughLink = $false
    $walk = [IO.Path]::GetPathRoot($venvHome)
    foreach ($part in $venvHome.Substring($walk.Length).Split('\')) {
        if (-not $part) { continue }
        $walk = Join-Path $walk $part
        $item = Get-Item -LiteralPath $walk -Force -ErrorAction SilentlyContinue
        if (-not $item) { break }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $throughLink = $true; break }
    }
    $trust = Get-JtLinkTrust -Path $venvHome @probeArgs
    return [pscustomobject]@{ Home = $venvHome; Status = $trust.Status; ThroughLink = $throughLink; Elevated = $Elevated; Message = $trust.Message }
}
