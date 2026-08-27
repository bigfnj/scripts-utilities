<#
.SYNOPSIS
  Collapse winget package directories into native\bin shims, and put the toolbox on the MACHINE
  PATH so tools stay visible to shells that do not inherit the user PATH.

.DESCRIPTION
  Fixes two independent failures that both make toolbox tools "not found" in an agent shell.

  1. WINDOWS TRUNCATES A LONG PATH. Measured on the reference box: machine PATH 4363 chars, but
     the spawned shell received exactly 4095 and the final entry was chopped mid-string
     ("C:\Users\Admin\AppD"). Everything past the 4 KB boundary is silently gone. Nothing is
     misconfigured; the PATH is simply longer than the buffer that carries it.

     27 winget package directories accounted for 3380 of 5264 total chars, because winget
     registers the full package folder - complete with its
     "_Microsoft.Winget.Source_8wekyb3d8bbwe" suffix and a version-stamped subfolder - rather
     than a shim. WinGet's own Links directory exists but is empty for portable packages.

  2. SOME SHELLS INHERIT THE MACHINE PATH ONLY. The user PATH is then invisible, which is exactly
     where a non-elevated toolbox install puts native\bin and sysinternals. The toolbox tells
     agents those tools are on PATH; in such a shell they are not.

  The fix is this repo's own pattern, applied one level out. build-devtoolbox.ps1 already wraps
  venv CLIs into native\bin so one PATH entry serves many tools. This does the same for winget
  portables, then registers native\bin and sysinternals machine-wide.

  SAFETY. Both PATH values are written to a timestamped JSON backup before any change, and
  -Restore puts them back verbatim. The registry value kind (REG_EXPAND_SZ) is preserved by
  writing the key directly: [Environment]::SetEnvironmentVariable silently rewrites it as REG_SZ,
  which would break any %VAR% entry a future PATH picks up.

  SHADOWING. Where two package directories provide the same executable (ffmpeg.exe ships in at
  least three), the one earliest in the current PATH wins, which is precisely what resolves today.
  Shadowed copies are reported, never silently reassigned.

.EXAMPLE
  .\scripts\consolidate-path.ps1 -DryRun     # report everything, change nothing
  .\scripts\consolidate-path.ps1             # apply (elevates for the machine PATH)
  .\scripts\consolidate-path.ps1 -Restore logs\path-backup-20260827-120000.json
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Restore,
    # Windows handed this shell 4095 chars. Aim comfortably under it rather than at it.
    [int]$TargetMax = 3500
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$Root = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { Join-Path $env:LOCALAPPDATA 'DevToolbox' }
$NativeBin = Join-Path $Root 'native\bin'
$Sysinternals = Join-Path $Root 'sysinternals'
$LogDir = Join-Path $RepoRoot 'logs'

function Write-Head($t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Write-Info2($t) { Write-Host "  [info] $t" -ForegroundColor Gray }
function Write-Warn2($t) { Write-Host "  [!]    $t" -ForegroundColor Yellow }

$MachineKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

function Get-RawPath {
    param([ValidateSet('Machine', 'User')][string]$Scope)
    # DoNotExpandEnvironmentNames keeps %VAR% literal, so a round-trip cannot expand it in place.
    if ($Scope -eq 'Machine') {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($MachineKey)
    } else {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    }
    try { return [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $k.Close() }
}

function Set-RawPath {
    param([ValidateSet('Machine', 'User')][string]$Scope, [string]$Value)
    if ($Scope -eq 'Machine') {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($MachineKey, $true)
    } else {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    }
    if (-not $k) { throw "cannot open the $Scope environment key for writing (elevation required for Machine)." }
    try { $k.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
    finally { $k.Close() }
}

function Publish-EnvChange {
    # Writing the registry directly does NOT tell anything that the environment moved. The System
    # Properties UI broadcasts WM_SETTINGCHANGE for you; a SetValue call does not, so Explorer and
    # every process it later spawns keep serving the OLD environment until the next logon. Without
    # this the fix appears not to have worked, which is the worst possible outcome for a PATH
    # repair - you check, it still fails, you conclude the tool is broken.
    try {
        if (-not ('Win32.NativeEnv' -as [type])) {
            Add-Type -Namespace Win32 -Name NativeEnv -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $res = [UIntPtr]::Zero
        # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5 s - a hung top-level window must
        # not wedge the installer.
        $sent = [Win32.NativeEnv]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$res)
        if ($sent -ne [IntPtr]::Zero) { Write-Ok 'broadcast WM_SETTINGCHANGE (new processes pick up the PATH without a logon)' }
        else { Write-Warn2 'WM_SETTINGCHANGE broadcast returned 0 - sign out and back in for the PATH to take effect.' }
    } catch {
        Write-Warn2 "could not broadcast the environment change ($($_.Exception.Message)) - sign out and back in."
    }
}

# Always an ARRAY. The runner sets Set-StrictMode -Version Latest, and under strict mode a
# pipeline that yields 0 or 1 items is $null or a scalar, so a later .Count throws
# "The property 'Count' cannot be found on this object" and kills an otherwise fine install.
function Split-Path2 { param([string]$Value) return @(@($Value -split ';') | Where-Object { $_.Trim() }) }
function Test-Admin {
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# --- restore ------------------------------------------------------------------
if ($Restore) {
    $file = if ([IO.Path]::IsPathRooted($Restore)) { $Restore } else { Join-Path $RepoRoot $Restore }
    if (-not (Test-Path $file)) { throw "backup not found: $file" }
    $b = Get-Content $file -Raw | ConvertFrom-Json
    Write-Head "Restoring PATH from $file (captured $($b.captured_at))"
    if (-not (Test-Admin)) { throw 'Restoring the machine PATH needs an elevated session.' }
    Set-RawPath -Scope Machine -Value $b.machine
    Set-RawPath -Scope User -Value $b.user
    Write-Ok "machine PATH restored ($($b.machine.Length) chars)"
    Write-Ok "user PATH restored ($($b.user.Length) chars)"
    Write-Warn2 'Open a NEW shell to see the restored PATH.'
    return
}

# --- read + report -------------------------------------------------------------
$machine = Get-RawPath -Scope Machine
$user = Get-RawPath -Scope User
$mEntries = Split-Path2 $machine
$uEntries = Split-Path2 $user

Write-Head 'Current PATH'
Write-Info2 ("machine : {0,5} chars, {1} entries" -f $machine.Length, $mEntries.Count)
Write-Info2 ("user    : {0,5} chars, {1} entries" -f $user.Length, $uEntries.Count)
Write-Info2 ("session : {0,5} chars  <- what this process actually received" -f $env:Path.Length)
# Detect truncation by its SIGNATURE, not by a length comparison. A session PATH is legitimately
# shorter than machine+user (de-duplication, per-process edits, a parent that started earlier), so
# "shorter" alone cries wolf - it did, on a freshly consolidated 1818-char PATH. What truncation
# actually looks like is a final entry chopped mid-string, leaving a directory that cannot exist.
$sessEntries = Split-Path2 $env:Path
if ($sessEntries.Count -gt 0) {
    $lastEntry = $sessEntries[-1]
    if (-not (Test-Path -LiteralPath $lastEntry -ErrorAction SilentlyContinue)) {
        Write-Warn2 "This shell's PATH ends in a directory that does not exist ('$lastEntry')."
        Write-Warn2 "That is the signature of a PATH truncated in flight at $($env:Path.Length) chars."
    }
}

if (-not (Test-Path $NativeBin)) {
    throw "toolbox native\bin not found at $NativeBin - run bootstrap.ps1 first (or set CODEX_TOOLBOX)."
}

# --- plan: which entries collapse into shims -----------------------------------
# Resolution order is machine-then-user, which is how Windows composes the session PATH. Keeping
# that order is what makes "first one wins" match what resolves today.
$ordered = @($mEntries + $uEntries)
$targets = @($ordered | Where-Object { $_ -like '*\WinGet\Packages\*' } | Select-Object -Unique)

Write-Head "Winget package directories to collapse: $($targets.Count)"
if ($targets.Count -eq 0) { Write-Ok 'nothing to collapse'; }

$claimed = @{}   # exe base name -> full target path (first in PATH order wins)
$shadowed = @()
$missingDirs = @()
foreach ($dir in $targets) {
    if (-not (Test-Path $dir)) { $missingDirs += $dir; continue }
    # -Filter, NOT -Include. Get-ChildItem silently ignores -Include unless the path ends in \* or
    # -Recurse is set, so an -Include *.exe here matched README.md, .pdb and .dll alike and would
    # have generated shims called README.cmd. Caught by the first dry run; keep it as -Filter.
    $exes = @()
    foreach ($ext in @('*.exe', '*.cmd', '*.bat')) {
        $exes += @(Get-ChildItem -LiteralPath $dir -File -Filter $ext -ErrorAction SilentlyContinue)
    }
    foreach ($exe in ($exes | Sort-Object Name)) {
        $name = $exe.BaseName
        # Never shim over a wrapper the toolbox builder owns, and never shim ourselves.
        if ($name -eq 'consolidate-path') { continue }
        if ($claimed.ContainsKey($name)) { $shadowed += "$name -> keeping $($claimed[$name])"; continue }
        $claimed[$name] = $exe.FullName
    }
}
foreach ($d in $missingDirs) { Write-Warn2 "on PATH but gone from disk, will be dropped: $d" }
Write-Info2 "executables to shim: $($claimed.Count)"
foreach ($s in $shadowed) { Write-Info2 "shadowed, unchanged: $s" }

# --- compute the new PATHs ------------------------------------------------------
$drop = @($targets)
$newM = @($mEntries | Where-Object { $drop -notcontains $_ })
$newU = @($uEntries | Where-Object { $drop -notcontains $_ })
foreach ($need in @($NativeBin, $Sysinternals)) {
    if (Test-Path $need) {
        $newU = @($newU | Where-Object { $_.TrimEnd('\') -ne $need.TrimEnd('\') })   # de-dupe from user
        if (-not ($newM | Where-Object { $_.TrimEnd('\') -eq $need.TrimEnd('\') })) { $newM += $need }
    }
}
$newMachine = ($newM -join ';')
$newUser = ($newU -join ';')

Write-Head 'After consolidation'
Write-Info2 ("machine : {0,5} chars, {1} entries  (was {2}, {3})" -f $newMachine.Length, $newM.Count, $machine.Length, $mEntries.Count)
Write-Info2 ("user    : {0,5} chars, {1} entries  (was {2}, {3})" -f $newUser.Length, $newU.Count, $user.Length, $uEntries.Count)
$total = $newMachine.Length + $newUser.Length + 1
Write-Info2 ("combined: {0,5} chars" -f $total)
if ($newMachine.Length -le $TargetMax) { Write-Ok "machine PATH is under the $TargetMax-char target" }
else { Write-Warn2 "machine PATH is still $($newMachine.Length) chars, above the $TargetMax target - review it by hand" }

if ($DryRun) {
    Write-Head 'DRY RUN - nothing was changed'
    Write-Info2 "would write $($claimed.Count) shims into $NativeBin"
    Write-Info2 "would drop $($drop.Count) winget package entries"
    Write-Info2 "would add native\bin + sysinternals to the MACHINE PATH"
    return
}

# --- back up --------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$backup = Join-Path $LogDir "path-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
[ordered]@{
    captured_at = (Get-Date).ToString('o')
    machine     = $machine
    user        = $user
} | ConvertTo-Json | Set-Content -Path $backup -Encoding UTF8
Write-Head 'Backup'
Write-Ok "wrote $backup"
Write-Info2 "restore with: .\scripts\consolidate-path.ps1 -Restore `"$backup`""

# --- write the shims --------------------------------------------------------------
Write-Head 'Shims'
$written = 0
foreach ($name in ($claimed.Keys | Sort-Object)) {
    $target = $claimed[$name]
    $wrapper = Join-Path $NativeBin "$name.cmd"
    # Same wrapper shape build-devtoolbox.ps1 emits, so Get-WrapperTarget and the toolbox
    # manifest can read these too and report a target that has gone missing.
    $body = "@echo off" + [Environment]::NewLine + '"' + $target + '" %*' + [Environment]::NewLine
    Set-Content -Path $wrapper -Value $body -Encoding ASCII -NoNewline
    $written++
}
Write-Ok "$written shim(s) in $NativeBin"

# --- write the PATHs ---------------------------------------------------------------
Write-Head 'PATH'
Set-RawPath -Scope User -Value $newUser
Write-Ok "user PATH updated ($($newUser.Length) chars)"

if (Test-Admin) {
    Set-RawPath -Scope Machine -Value $newMachine
    Write-Ok "machine PATH updated ($($newMachine.Length) chars)"
} else {
    $tmp = Join-Path $LogDir 'machine-path-pending.txt'
    Set-Content -Path $tmp -Value $newMachine -Encoding UTF8 -NoNewline
    Write-Warn2 'Not elevated - the MACHINE PATH was not written.'
    Write-Warn2 "Re-run this script elevated to finish, or apply $tmp by hand."
    Write-Warn2 'Until then the toolbox stays on the user PATH only, which is the bug being fixed.'
}

Publish-EnvChange

Write-Head 'Done'
Write-Warn2 'Open a NEW shell: an already-running process keeps the environment block it started with.'
Write-Info2 'Re-run after a winget upgrade: a version-stamped package folder moves and its shim goes stale.'
Write-Info2 'scripts\smoke-test.ps1 reports any shim whose target no longer exists.'