#Requires -Version 5.1
<#
    path-registry.ps1 - reading, writing and editing the two persistent PATH values.

    WHY THIS FILE EXISTS. These functions lived in scripts\consolidate-path.ps1, which is a
    SCRIPT: its top-level code reads the registry the moment the file is dot-sourced, and on
    several paths it calls `exit`, which kills the CALLING host. Nothing could import them, so
    the one genuinely pure decision in the whole script - which PATH entries come out - had no
    test and was proved only by running the thing that rewrites the machine PATH. Same reason
    scripts\ForensicsReport.Core.ps1 and lib\SysmonConfig.ps1 exist.

    WHY THE REGISTRY DIRECTLY, NOT [Environment]::SetEnvironmentVariable. 5 of this box's 43
    machine entries are %VAR%-based (%SystemRoot%\system32 among them).
    [Environment]::SetEnvironmentVariable silently rewrites the value as REG_SZ, and a REG_SZ
    PATH never expands a %VAR% again - so a round-trip through the framework API would break
    system32 resolution for every process started afterwards. Get-RawPath/Set-RawPath open the
    key and pass DoNotExpandEnvironmentNames / RegistryValueKind::ExpandString to keep both the
    literal text and the value kind intact.

    THIS FILE DEFINES NO LOGGING FUNCTIONS, DELIBERATELY. consolidate-path.ps1 has
    Write-Ok($t) / Write-Info2 / Write-Warn2; lib\common.ps1 has Write-Ok -Msg. Both files
    dot-source this one, so a Write-Ok defined here would be redefined by whichever of them was
    sourced last and the other file's calls would bind to the wrong parameter. Publish-EnvChange
    below is the one moved function that emits text, and it does so through the CALLER's
    Write-Ok/Write-Warn2 - consolidate-path.ps1 is its only caller, and a new caller has to
    supply that vocabulary or give it somewhere else to write.

    Tested by: tests\Invoke-InstallerTests.ps1
#>

$MachineKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

function Get-RawPath {
    param([ValidateSet('Machine', 'User')][string]$Scope)
    # DoNotExpandEnvironmentNames keeps %VAR% literal, so a round-trip cannot expand it in place.
    if ($Scope -eq 'Machine') {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($MachineKey)
    } else {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    }
    # OpenSubKey returns $null for a key it cannot open - it does not throw. Without this guard
    # the try block died on a null .GetValue(), and then finally{} threw its OWN
    # NullReferenceException on $k.Close() on the way out, which REPLACED the real error with a
    # stack trace pointing at the cleanup. Set-RawPath below has always guarded this; the read
    # path did not, which made a read failure the harder of the two to diagnose.
    if (-not $k) { throw "cannot open the $Scope environment key for reading." }
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
function Split-PathList { param([string]$Value) return @(@($Value -split ';') | Where-Object { $_.Trim() }) }

# Named Test-PathAdmin, not Test-Admin: uninstall-toolbox.ps1 has Test-IsElevated, run-gate.ps1
# and smoke-test.ps1 inline their own, and a file dot-sourced into all of them must not win a
# name any of those might later reach for.
function Test-PathAdmin {
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Backup-PathRegistry {
    <#
        Write both raw PATH values to a timestamped JSON file and RETURN ITS PATH. The caller
        prints, because the two callers print differently (see the header).

        The backup is the only reason the 2026-09-09 outage was recoverable, and
        logs\path-backup-20260909-203021.json is still the only surviving record of the 27
        winget package directories in their original resolution order. Capture the RAW values:
        an expanded backup restores %SystemRoot%\system32 as C:\WINDOWS\system32, which works
        until the day it does not.
    #>
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Machine,
        [Parameter(Mandatory)][AllowEmptyString()][string]$User
    )
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $backup = Join-Path $LogDir "path-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    [ordered]@{
        captured_at = (Get-Date).ToString('o')
        machine     = $Machine
        user        = $User
    } | ConvertTo-Json | Set-Content -Path $backup -Encoding UTF8
    return $backup
}

function Remove-PathEntryFromString {
    <#
        Remove entries from a raw PATH value. PURE: takes text, returns text, touches nothing.

        NEVER EXPANDS %VAR%. The machine PATH on the reference box holds 5 %VAR%-based entries,
        and the whole point of Get-RawPath is that they stay literal - so comparison and
        re-emission are both verbatim. An implementation that expanded in order to compare would
        have to re-emit the expansion, which is the REG_SZ bug by another route.

        Matches case-insensitively and ignores ONE trailing backslash, because the registry holds
        both 'C:\...\Python311\' and 'C:\...\ImageMagick-7.1.2-Q16-HDRI' and an operator typing
        the path by hand will not guess which. Only one: '\\server\share\' and '\\server\share'
        name the same directory, but stripping every trailing slash would also equate 'C:\' with
        'C:' and the UNC root with the host.

        Returns @{ Value; Removed; Kept } - Removed is what actually matched, so a caller can
        report "asked to drop 7, dropped 5" instead of assuming.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [string[]]$Remove = @()
    )
    $norm = {
        param($s)
        $t = ([string]$s).Trim()
        if ($t.EndsWith('\')) { $t = $t.Substring(0, $t.Length - 1) }
        return $t
    }
    $drop = @(@($Remove) | Where-Object { $_ } | ForEach-Object { (& $norm $_).ToLowerInvariant() })
    $entries = Split-PathList $Value
    $kept = New-Object 'System.Collections.Generic.List[string]'
    $removed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in $entries) {
        if ($drop -contains (& $norm $e).ToLowerInvariant()) { $removed.Add($e) }
        else { $kept.Add($e) }
    }
    return @{
        Value   = ($kept -join ';')
        Removed = @($removed.ToArray())
        Kept    = @($kept.ToArray())
    }
}

function Test-PathListProvides {
    <#
        Does this raw PATH value already name this directory? PURE: takes text, returns a bool.

        EXPANDS TO COMPARE, and that is safe here in a way it is not in Remove-PathEntryFromString
        above, because nothing is re-emitted: the caller is deciding whether to ADD, not rewriting
        the value. '%LOCALAPPDATA%\DevToolbox\native\bin' and the expanded literal are the same
        directory, and a comparison that could not see that is how the duplicate gets added.

        Same one-trailing-backslash rule as Remove-PathEntryFromString, for the same reason.

        Exists so Add-UserPathEntry can ask "is the machine hive already answering for this?"
        without a second registry reader and without anything to stub in a test. Windows composes
        machine-then-user, so a user entry duplicating a machine one can NEVER win a lookup: it
        cannot change resolution, it only spends characters against the 4,095-character
        truncation cliff that smoke-test.ps1 exists to warn about.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Path
    )
    $norm = {
        param($s)
        $t = ([string]$s).Trim()
        if ($t) { $t = [System.Environment]::ExpandEnvironmentVariables($t) }
        if ($t.EndsWith('\')) { $t = $t.Substring(0, $t.Length - 1) }
        return $t.ToLowerInvariant()
    }
    $want = & $norm $Path
    if (-not $want) { return $false }
    foreach ($e in (Split-PathList $Value)) {
        if ((& $norm $e) -eq $want) { return $true }
    }
    return $false
}
