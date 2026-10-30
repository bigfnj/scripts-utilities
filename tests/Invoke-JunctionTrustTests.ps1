#Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\JunctionTrust.ps1')
$script:Pass = 0
$script:Fail = 0
function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        if (& $Body) { $script:Pass++; Write-Host "  OK $Name" }
        else { $script:Fail++; Write-Host "  FAIL $Name" }
    } catch { $script:Fail++; Write-Host "  FAIL $Name : $($_.Exception.Message) $($_.ScriptStackTrace)" }
}
function Rejects {
    param([scriptblock]$Body)
    try { $null = & $Body; return $false } catch { return $true }
}

# An 8-digit hex literal is a signed Int32 in PowerShell, and whether that holds in every host is
# exactly the kind of thing these tests should not depend on. Convert spells the bits out.
$hrUntrusted = [Convert]::ToInt32('800701C0', 16)
$hrSharing = [Convert]::ToInt32('80070020', 16)
function New-Untrusted { New-Object IO.IOException 'The path cannot be traversed because it contains an untrusted mount point.', $hrUntrusted }

function New-FakeDir {
    param([string]$Path, [switch]$Link)
    $attributes = [IO.FileAttributes]::Directory
    if ($Link) { $attributes = $attributes -bor [IO.FileAttributes]::ReparsePoint }
    [pscustomobject]@{ FullName = $Path; Attributes = $attributes }
}

# Real fixtures live under TEMP only, and every junction in them is removed NON-recursively before
# the directory that holds it, so no cleanup can reach through a link.
function New-TempRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('su-jt-test-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $root -Force
    return $root
}
function Remove-TempRoot {
    param([string]$Root)
    foreach ($child in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [IO.Directory]::Delete($child.FullName, $false) }
    }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}
function New-LinkFixture {
    $root = New-TempRoot
    $target = Join-Path $root 'target'
    $null = New-Item -ItemType Directory -Path $target -Force
    [IO.File]::WriteAllText((Join-Path $target 'keep.txt'), 'keep')
    $link = Join-Path $root 'link'
    $null = New-Item -ItemType Junction -Path $link -Value $target
    return [pscustomobject]@{ Root = $root; Target = $target; Link = $link }
}
# Untrusted on the first probe, trusted on every later one: the before/after shape a real
# recreate produces, without needing a non-admin token to make the fixture.
#
# Every closure below takes its helpers and data as LOCALS. A GetNewClosure() block resolves
# functions and script variables through GLOBAL scope, and in-session (the way gate.yml runs a
# suite) the suite's script scope is not global: the installer suite scored 108/0 as -File and
# 96/12 in-session for exactly this reason.
function New-FlipProbe {
    $state = @{ Calls = 0 }
    $make = ${function:New-Untrusted}
    return {
        param($Directory)
        $state.Calls++
        if ($state.Calls -eq 1) { throw (& $make) }
    }.GetNewClosure()
}
$alwaysUntrusted = { param($Directory) throw (New-Untrusted) }
$neverUntrusted = { param($Directory) }

# --- classifier ---------------------------------------------------------------

It 'Win32 codes come out of FACILITY_WIN32 HRESULTs and nothing else' {
    (Get-JtWin32Code $hrUntrusted) -eq 448 -and
        (Get-JtWin32Code ([Convert]::ToInt32('80070003', 16))) -eq 3 -and
        $null -eq (Get-JtWin32Code ([Convert]::ToInt32('80131501', 16)))
}
It 'WinError 448 is untrusted, and every other outcome maps to its own status' {
    (Get-JtLinkTrust -Path 'X:\a' -Probe $alwaysUntrusted).Status -eq 'untrusted' -and
        (Get-JtLinkTrust -Path 'X:\a' -Probe { throw (New-Object IO.DirectoryNotFoundException 'gone') }).Status -eq 'dangling' -and
        (Get-JtLinkTrust -Path 'X:\a' -Probe { throw (New-Object UnauthorizedAccessException 'no') }).Status -eq 'denied' -and
        (Get-JtLinkTrust -Path 'X:\a' -Probe { throw (New-Object IO.IOException 'busy', $hrSharing) }).Status -eq 'error' -and
        (Get-JtLinkTrust -Path 'X:\a' -Probe $neverUntrusted).Status -eq 'ok'
}
It 'a real .NET throw is unwrapped from MethodInvocationException before it is classified' {
    $missing = Join-Path ([IO.Path]::GetTempPath()) ('su-jt-absent-' + [guid]::NewGuid().ToString('N'))
    $r = Get-JtLinkTrust -Path $missing
    $r.Status -eq 'dangling' -and $r.Win32 -eq 3
}
It 'a real trusted junction is ok and a real junction to a deleted target is dangling' {
    $f = New-LinkFixture
    try {
        $before = (Get-JtLinkTrust -Path $f.Link).Status
        [IO.File]::Delete((Join-Path $f.Target 'keep.txt'))
        [IO.Directory]::Delete($f.Target, $false)
        $after = (Get-JtLinkTrust -Path $f.Link).Status
        $before -eq 'ok' -and $after -eq 'dangling'
    } finally { Remove-TempRoot $f.Root }
}
It 'the junction target is read off the link and a plain directory has none' {
    $f = New-LinkFixture
    try {
        (Get-JtJunctionTarget -Path $f.Link).TrimEnd('\') -eq $f.Target.TrimEnd('\') -and $null -eq (Get-JtJunctionTarget -Path $f.Target)
    } finally { Remove-TempRoot $f.Root }
}

# --- walker -------------------------------------------------------------------

$tree = @{
    'C:\R'     = @((New-FakeDir 'C:\R\A'), (New-FakeDir 'C:\R\L' -Link), (New-FakeDir 'C:\R\S' -Link), (New-FakeDir 'C:\R\X'))
    'C:\R\A'   = @((New-FakeDir 'C:\R\A\B'))
    'C:\R\A\B' = @((New-FakeDir 'C:\R\A\B\J2' -Link))
    'C:\R\X'   = @((New-FakeDir 'C:\R\X\J3' -Link))
    'C:\R\L'   = @((New-FakeDir 'C:\R\L\inside'))
    'C:\R\S'   = @((New-FakeDir 'C:\R\S\inside'))
}
$links = @{ 'C:\R\L' = 'C:\T'; 'C:\R\A\B\J2' = 'C:\T2'; 'C:\R\X\J3' = 'C:\T3'; 'C:\R\S' = $null }
function New-Walk {
    param([string[]]$Exclude = @(), [string[]]$Throws = @(), [string[]]$Root = @('C:\R'))
    $listedLog = New-Object 'Collections.Generic.List[string]'
    $fakeTree = $tree
    $fakeLinks = $links
    $denied = @($Throws)
    $list = {
        param($Directory)
        $listedLog.Add($Directory)
        if ($denied -contains $Directory) { throw (New-Object UnauthorizedAccessException 'denied') }
        if ($fakeTree.ContainsKey($Directory)) { $fakeTree[$Directory] } else { @() }
    }.GetNewClosure()
    $read = { param($Path) $fakeLinks[$Path] }.GetNewClosure()
    $r = Find-JtJunctions -Root $Root -Exclude $Exclude -ListDirectories $list -ReadLink $read
    return [pscustomobject]@{ Result = $r; Listed = @($listedLog.ToArray()) }
}

It 'junctions are found at every depth and a symlink or other reparse point is not reported' {
    $w = New-Walk
    $paths = @($w.Result.Junctions | ForEach-Object { $_.Path } | Sort-Object)
    ($paths -join ',') -eq 'C:\R\A\B\J2,C:\R\L,C:\R\X\J3' -and
        @($w.Result.Junctions | Where-Object { $_.Path -eq 'C:\R\L' })[0].Target -eq 'C:\T'
}
It 'no reparse point is ever listed, so the walk never goes through a link' {
    $w = New-Walk
    $w.Listed -notcontains 'C:\R\L' -and $w.Listed -notcontains 'C:\R\S' -and $w.Result.Directories -eq 4
}
It 'an excluded directory is pruned before it is listed and nothing under it is reported' {
    $w = New-Walk -Exclude @('C:\R\X\')
    $w.Listed -notcontains 'C:\R\X' -and @($w.Result.Junctions | Where-Object { $_.Path -eq 'C:\R\X\J3' }).Count -eq 0 -and
        $w.Result.Directories -eq 3
}
It 'a directory that cannot be listed is reported as unreadable and the rest of the walk goes on' {
    $w = New-Walk -Throws @('C:\R\A')
    @($w.Result.Unreadable) -contains 'C:\R\A' -and $w.Result.Directories -eq 2 -and
        @($w.Result.Junctions | Where-Object { $_.Path -eq 'C:\R\L' }).Count -eq 1
}
It 'a root inside an exclusion is not walked at all' {
    $w = New-Walk -Exclude @('C:\R') -Root @('C:\R\A')
    $w.Listed.Count -eq 0 -and $w.Result.Directories -eq 0
}
It 'a drive root keeps its separator, because D: alone means the current directory on D:' {
    (Get-JtNormalPath 'D:\') -eq 'D:\' -and (Get-JtNormalPath 'D:\x\') -eq 'D:\x'
}

# --- exclusions and plan ------------------------------------------------------

It 'default exclusions cover Windows, TEMP, other profiles and both system folders of each drive, never the user' {
    $x = Get-JtDefaultExclusions -Root @('C:\', 'D:\') -SystemRoot 'C:\Windows' -Temp 'C:\Users\me\AppData\Local\Temp\' `
        -UserProfile 'C:\Users\me' -ListProfiles { param($d) @('C:\Users\me', 'C:\Users\other', 'C:\Users\Public') }
    $want = @('C:\Windows', 'C:\Users\me\AppData\Local\Temp', 'C:\$Recycle.Bin', 'C:\System Volume Information',
        'D:\$Recycle.Bin', 'D:\System Volume Information', 'C:\Users\other', 'C:\Users\Public')
    @($want | Where-Object { $x -notcontains $_ }).Count -eq 0 -and $x -notcontains 'C:\Users\me'
}
It 'the plan recreates only untrusted links whose target exists, and lists dangling and denied separately' {
    $verdicts = @{
        'C:\ok' = $null
        'C:\live' = (New-Untrusted)
        'C:\dead' = (New-Untrusted)
        'C:\gone' = (New-Object IO.DirectoryNotFoundException 'gone')
        'C:\shut' = (New-Object UnauthorizedAccessException 'no')
    }
    $probe = { param($Directory) if ($verdicts[$Directory]) { throw $verdicts[$Directory] } }.GetNewClosure()
    $j = @('ok', 'live', 'dead', 'gone', 'shut') | ForEach-Object { [pscustomobject]@{ Path = "C:\$_"; Target = "C:\t-$_" } }
    $p = New-JtPlan -Junctions $j -Probe $probe -TargetExists { param($t) $t -ne 'C:\t-dead' }
    $byPath = @{}
    foreach ($e in $p.Entries) { $byPath[$e.path] = $e.decision }
    $p.Trusted -eq 1 -and $p.Entries.Count -eq 4 -and $byPath['C:\live'] -eq 'recreate' -and $byPath['C:\dead'] -eq 'dangling' -and
        $byPath['C:\gone'] -eq 'dangling' -and $byPath['C:\shut'] -eq 'denied' -and -not $byPath.ContainsKey('C:\ok')
}

# --- recreate -----------------------------------------------------------------

It 'an untrusted junction is recreated to the same target and the target contents are untouched' {
    $f = New-LinkFixture
    try {
        $o = Invoke-JtRecreate -Path $f.Link -Target $f.Target -Probe (New-FlipProbe)
        $o.outcome -eq 'recreated' -and (Get-JtJunctionTarget -Path $f.Link).TrimEnd('\') -eq $f.Target.TrimEnd('\') -and
            [IO.File]::ReadAllText((Join-Path $f.Target 'keep.txt')) -eq 'keep'
    } finally { Remove-TempRoot $f.Root }
}
It 'a real directory is refused as not a junction and neither it nor its contents change' {
    $f = New-LinkFixture
    try {
        $o = Invoke-JtRecreate -Path $f.Target -Target $f.Target -Probe $alwaysUntrusted
        $o.outcome -eq 'skipped-not-junction' -and (Test-Path -LiteralPath (Join-Path $f.Target 'keep.txt'))
    } finally { Remove-TempRoot $f.Root }
}
It 'a junction that now points somewhere else is refused' {
    $f = New-LinkFixture
    try {
        $o = Invoke-JtRecreate -Path $f.Link -Target (Join-Path $f.Root 'elsewhere') -Probe $alwaysUntrusted
        $o.outcome -eq 'skipped-target-changed' -and (Get-JtJunctionTarget -Path $f.Link).TrimEnd('\') -eq $f.Target.TrimEnd('\')
    } finally { Remove-TempRoot $f.Root }
}
It 'a junction this process can already traverse is left alone' {
    $f = New-LinkFixture
    try {
        $stamp = (Get-Item -LiteralPath $f.Link -Force).CreationTimeUtc
        $o = Invoke-JtRecreate -Path $f.Link -Target $f.Target -Probe $neverUntrusted
        $o.outcome -eq 'skipped-not-untrusted' -and (Get-Item -LiteralPath $f.Link -Force).CreationTimeUtc -eq $stamp
    } finally { Remove-TempRoot $f.Root }
}
It 'a missing link and a missing target are both refused before anything is deleted' {
    $f = New-LinkFixture
    try {
        $gone = Invoke-JtRecreate -Path (Join-Path $f.Root 'absent') -Target $f.Target -Probe $alwaysUntrusted
        [IO.File]::Delete((Join-Path $f.Target 'keep.txt'))
        [IO.Directory]::Delete($f.Target, $false)
        $dead = Invoke-JtRecreate -Path $f.Link -Target $f.Target -Probe $alwaysUntrusted
        $gone.outcome -eq 'skipped-missing' -and $dead.outcome -eq 'skipped-target-missing' -and
            [string](Get-JtJunctionTarget -Path $f.Link) -ne ''
    } finally { Remove-TempRoot $f.Root }
}
It 'the witness remover refuses any directory that is not a witness' {
    (Rejects { Remove-JtWitness -Root ([IO.Path]::GetTempPath()) }) -and
        (Rejects { Remove-JtWitness -Root (Join-Path ([IO.Path]::GetTempPath()) 'su-junction-witness-nothex') })
}

# --- venv home probe ----------------------------------------------------------

It 'the venv home probe says whether home crosses a link and passes the classifier verdict through' {
    $f = New-LinkFixture
    try {
        $plain = Join-Path $f.Root 'plain.cfg'
        $linked = Join-Path $f.Root 'linked.cfg'
        $bare = Join-Path $f.Root 'bare.cfg'
        [IO.File]::WriteAllText($plain, "home = $($f.Target)`r`nversion = 3.11.15`r`n")
        [IO.File]::WriteAllText($linked, "home = $($f.Link)`r`n")
        [IO.File]::WriteAllText($bare, "version = 3.11.15`r`n")
        $a = Get-JtVenvHomeState -PyvenvCfg $plain -Elevated $true
        $b = Get-JtVenvHomeState -PyvenvCfg $linked -Elevated $false
        $c = Get-JtVenvHomeState -PyvenvCfg $linked -Elevated $true -Probe $alwaysUntrusted
        $d = Get-JtVenvHomeState -PyvenvCfg $bare
        $a.Status -eq 'ok' -and -not $a.ThroughLink -and $a.Home -eq $f.Target -and
            $b.Status -eq 'ok' -and $b.ThroughLink -and -not $b.Elevated -and
            $c.Status -eq 'untrusted' -and $d.Status -eq 'no-home'
    } finally { Remove-TempRoot $f.Root }
}

# --- source order: the guards come before the actions they guard ---------------

$libSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'lib\JunctionTrust.ps1'))
$scriptSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\repair-untrusted-junctions.ps1'))

It 'every Directory.Delete in the library is non-recursive and nothing removes with -Recurse' {
    $ast = [Management.Automation.Language.Parser]::ParseInput($libSource, [ref]$null, [ref]$null)
    $deletes = @($ast.FindAll({
        param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and
            $n.Member.Extent.Text -eq 'Delete' -and $n.Expression.Extent.Text -match 'IO\.Directory'
    }, $true))
    $nonRecursive = @($deletes | Where-Object { $_.Arguments.Count -eq 2 -and $_.Arguments[1].Extent.Text -eq '$false' })
    $deletes.Count -ge 1 -and $nonRecursive.Count -eq $deletes.Count -and
        $libSource -notmatch '(?m)^[^#\r\n]*Remove-Item' -and $scriptSource -notmatch '(?m)^[^#\r\n]*Remove-Item'
}
It 'inside the recreate, every re-check comes before the one delete of the link' {
    $body = $libSource.Substring($libSource.IndexOf('function Invoke-JtRecreate'))
    $body = $body.Substring(0, $body.IndexOf('function New-JtUntrustedWitness'))
    $delete = $body.IndexOf('[IO.Directory]::Delete($Path, $false)')
    $checks = @("'skipped-missing'", "'skipped-not-junction'", "'skipped-target-changed'", "'skipped-target-missing'", "'skipped-not-untrusted'") |
        ForEach-Object { $body.IndexOf($_) }
    $delete -gt 0 -and @($checks | Where-Object { $_ -lt 0 -or $_ -gt $delete }).Count -eq 0
}
It 'the script refuses an unelevated shell before the witness and the sweep, and an applied plan before any recreate' {
    $elevated = $scriptSource.IndexOf('if (-not (Test-JtElevated))')
    $witness = $scriptSource.IndexOf('New-JtUntrustedWitness')
    $sweep = $scriptSource.IndexOf('Find-JtJunctions -Root')
    $applied = $scriptSource.IndexOf('this plan was already applied')
    $recreate = $scriptSource.IndexOf('Invoke-JtRecreate -Path')
    $elevated -gt 0 -and $witness -gt $elevated -and $sweep -gt $witness -and $applied -gt 0 -and $recreate -gt $applied -and
        $scriptSource.IndexOf('exit 2', $elevated) -lt $witness
}
It 'the smoke test fails, not warns, when the venv home is behind an untrusted junction' {
    $smoke = [IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\smoke-test.ps1'))
    $ast = [Management.Automation.Language.Parser]::ParseInput($smoke, [ref]$null, [ref]$null)
    $switches = @($ast.FindAll({
        param($n) $n -is [Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -match 'jtHome\.Status'
    }, $true))
    $clause = @($switches | ForEach-Object { $_.Clauses } | Where-Object { $_.Item1.Extent.Text -eq "'untrusted'" })
    $switches.Count -eq 1 -and $clause.Count -eq 1 -and $clause[0].Item2.Extent.Text -match 'Test-Fail' -and
        $clause[0].Item2.Extent.Text -notmatch 'Test-Ok|Test-Warn' -and $smoke -match 'lib\\JunctionTrust\.ps1'
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail) { exit 1 }
exit 0
