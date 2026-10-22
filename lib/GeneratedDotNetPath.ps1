#Requires -Version 5.1
# Exact, user-only removal of isolated fixture .NET tool PATH entries.
# Dot-sourcing defines functions only. Candidate directories are never accessed.
. (Join-Path $PSScriptRoot 'SourceFiles.ps1')

function Get-GdpHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::Unicode.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-GdpByteHash {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function ConvertTo-GdpBytes {
    param([Parameter(Mandatory)]$Value)
    return ,([Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 16) + "`n"))
}

function ConvertFrom-GdpJson {
    param([Parameter(Mandatory)][string]$Text)
    # The review timestamp must retain its exact JSON string spelling. PS7's
    # default DateTime coercion otherwise loses fractions during string binding.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Text -DateKind String
    }
    if ($PSVersionTable.PSVersion.Major -le 5) {
        return ConvertFrom-Json -InputObject $Text
    }
    throw 'Exact PATH plan JSON requires Windows PowerShell 5.1 or PowerShell 7.5+.'
}

function Assert-GdpFields {
    param($Value, [string[]]$Names)
    if ($null -eq $Value) { throw 'Missing generated-dotnet PATH object.' }
    $actual = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
    if ($actual.Count -ne $Names.Count -or @($actual | Where-Object { $Names -cnotcontains $_ }).Count) {
        throw 'Unexpected generated-dotnet PATH object fields.'
    }
}

function Assert-GdpSame {
    param($Actual, $Expected, [string]$What)
    $a = $Actual | ConvertTo-Json -Depth 16 -Compress
    $b = $Expected | ConvertTo-Json -Depth 16 -Compress
    if (-not [string]::Equals($a, $b, [StringComparison]::Ordinal)) { throw "Generated-dotnet PATH identity changed: $What" }
}

function Assert-GdpOwner {
    param($Owner)
    Assert-GdpFields $Owner @('sid', 'profile', 'short_profile', 'session_id')
    if ($Owner.sid -cnotmatch '^S-1-(?:[0-9]+-){1,13}[0-9]+$' -or
        $Owner.sid -in @('S-1-5-18', 'S-1-5-19', 'S-1-5-20') -or
        $Owner.profile -cnotmatch '^[A-Za-z]:\\Users\\[^\\/:;"%]+$' -or
        $Owner.short_profile -cnotmatch '^[A-Za-z]:\\Users\\[^\\/:;"%]+$' -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($Owner.profile), [IO.Path]::GetDirectoryName($Owner.short_profile), [StringComparison]::OrdinalIgnoreCase) -or
        $Owner.session_id -isnot [int] -or $Owner.session_id -le 0) { throw 'Expected an identified interactive user profile/session.' }
    foreach ($path in @($Owner.profile, $Owner.short_profile)) {
        if (-not (Test-SUSourcePath $path) -or @($path.Split('\') | Where-Object { $_ -in @('.', '..') }).Count) {
            throw 'Unsafe generated-dotnet owner profile spelling.'
        }
    }
}

function New-GdpState {
    param([AllowEmptyString()][string]$Raw, [string]$Kind)
    if ($Kind -cne 'ExpandString' -or $Raw.Length -gt 32767 -or $Raw.IndexOfAny([char[]]@([char]0, [char]10, [char]13)) -ge 0) {
        throw 'Only bounded raw REG_EXPAND_SZ PATH values are admitted.'
    }
    return [pscustomobject][ordered]@{ raw = $Raw; kind = $Kind; utf16le_sha256 = Get-GdpHash $Raw }
}

function Assert-GdpState {
    param($Value)
    Assert-GdpFields $Value @('raw', 'kind', 'utf16le_sha256')
    Assert-GdpSame $Value (New-GdpState -Raw $Value.raw -Kind $Value.kind) 'raw PATH value/type/hash'
}

function Get-GdpRoots {
    param($Owner)
    Assert-GdpOwner $Owner
    return @(($Owner.profile + '\Grimoire.source\desktop-ai-companion\artifacts\'),
        ($Owner.short_profile + '\GRIMOI~1.SOU\DESKTO~1\ARTIFA~1\'),
        ($Owner.short_profile + '\GRIMOI~1.SOU\gq\ARTIFA~1\'))
}

function Get-GdpCandidateRoot {
    param([AllowEmptyString()][string]$Entry, [string[]]$Roots)
    # No expansion, trimming, case rewriting, metadata, or candidate enumeration.
    if (-not $Entry.EndsWith('\.dotnet\tools', [StringComparison]::OrdinalIgnoreCase) -or
        $Entry.IndexOfAny([char[]]'"%/*?') -ge 0 -or
        @($Entry.Split('\') | Where-Object { $_ -in @('.', '..') }).Count) { return $null }
    foreach ($root in $Roots) {
        if ($Entry.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and
            $Entry.Length -gt $root.Length + '\.dotnet\tools'.Length) { return $root }
    }
    return $null
}

function New-GdpPlan {
    param($Owner, $User, $Machine, $Producers, [string]$CapturedUtc)
    Assert-GdpOwner $Owner
    Assert-GdpState $User
    Assert-GdpState $Machine
    $parsedUtc = [DateTimeOffset]::Parse($CapturedUtc, [Globalization.CultureInfo]::InvariantCulture)
    if ($parsedUtc.Offset -ne [TimeSpan]::Zero) { throw 'PATH plan timestamp must be UTC.' }
    $roots = @(Get-GdpRoots $Owner)
    $kept = New-Object 'Collections.Generic.List[string]'
    $removed = New-Object 'Collections.Generic.List[object]'
    $entries = $User.raw.Split([char]';')
    for ($i = 0; $i -lt $entries.Length; $i++) {
        $root = Get-GdpCandidateRoot -Entry $entries[$i] -Roots $roots
        if ($root) { $removed.Add([pscustomobject][ordered]@{ index = $i; value = $entries[$i]; artifact_root = $root }) }
        else { $kept.Add($entries[$i]) }
    }
    $after = New-GdpState -Raw ([string]::Join(';', $kept.ToArray())) -Kind $User.kind
    return [pscustomobject][ordered]@{
        schema = 'su-generated-dotnet-path-plan-1'; captured_utc = $CapturedUtc; scope = 'User'
        owner = $Owner; before = [pscustomobject][ordered]@{ user = $User; machine = $Machine }
        after_user = $after; artifact_roots = $roots; removed = @($removed.ToArray())
        expected_removed = 56; ready_to_apply = ($removed.Count -eq 56)
        candidate_files_read = $false; machine_mutation = $false; producer_sha256 = $Producers
    }
}

function Assert-GdpPlan {
    param($Plan, $Owner, $User, $Machine, $Producers, [string]$ExpectedUserSid)
    Assert-GdpFields $Plan @('schema', 'captured_utc', 'scope', 'owner', 'before', 'after_user', 'artifact_roots',
        'removed', 'expected_removed', 'ready_to_apply', 'candidate_files_read', 'machine_mutation', 'producer_sha256')
    if ([string]::IsNullOrEmpty($ExpectedUserSid) -or $ExpectedUserSid -cne $Owner.sid) { throw 'Explicit expected interactive user SID differs.' }
    Assert-GdpSame $Plan.owner $Owner 'interactive owner'
    Assert-GdpSame $Plan.before.user $User 'User PATH before apply'
    Assert-GdpSame $Plan.before.machine $Machine 'Machine PATH before apply'
    Assert-GdpSame $Plan.producer_sha256 $Producers 'reviewed planner producers'
    $derived = New-GdpPlan -Owner $Owner -User $User -Machine $Machine -Producers $Producers -CapturedUtc $Plan.captured_utc
    Assert-GdpSame $Plan $derived 'complete pinned removal plan'
    if ($Plan.ready_to_apply -isnot [bool] -or -not $Plan.ready_to_apply -or @($Plan.removed).Count -ne 56) {
        throw 'Apply requires the reviewed exact 56-entry fixture-only removal.'
    }
}

function Assert-GdpOrdinaryPath {
    param([string]$Path, [switch]$Directory)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-SUSourcePath $full)) { throw 'Protected generated-dotnet artifact spelling.' }
    $parts = $full.Substring([IO.Path]::GetPathRoot($full).Length).Split('\')
    $walk = [IO.Path]::GetPathRoot($full)
    foreach ($part in $parts) {
        if (-not $part) { continue }
        $walk = Join-Path $walk $part
        $item = Get-Item -LiteralPath $walk -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked generated-dotnet artifact path.' }
    }
    if ($Directory -and -not $item.PSIsContainer) { throw 'Expected ordinary generated-dotnet directory.' }
    return $full
}

function Read-GdpBytes {
    param([string]$Path, [int]$Maximum = 2000000)
    if (-not (Test-SUSourcePath $Path)) { throw 'Protected generated-dotnet input spelling.' }
    $full = Assert-GdpOrdinaryPath $Path
    $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $Maximum) { throw 'Oversized generated-dotnet input.' }
        $buffer = New-Object byte[] ($Maximum + 1)
        $used = 0
        while ($used -le $Maximum) {
            $count = $stream.Read($buffer, $used, $buffer.Length - $used)
            if ($count -eq 0) { break }
            $used += $count
        }
        if ($used -gt $Maximum) { throw 'Generated-dotnet input grew beyond its bound.' }
        $result = New-Object byte[] $used
        [Array]::Copy($buffer, $result, $used)
        return ,$result
    } finally { $stream.Dispose() }
}

function Write-GdpBytes {
    param([string]$Path, [byte[]]$Bytes)
    if (-not (Test-SUSourcePath $Path)) { throw 'Protected generated-dotnet output spelling.' }
    $null = Assert-GdpOrdinaryPath ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) -Directory
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Get-GdpProducerPins {
    param([string]$RepoRoot)
    $pins = [ordered]@{}
    foreach ($name in @('lib/GeneratedDotNetPath.ps1', 'lib/SourceFiles.ps1', 'scripts/repair-generated-dotnet-path.ps1',
        'tests/Invoke-GeneratedDotNetPathTests.ps1', 'docs/generated-dotnet-path.md')) {
        $pins[$name] = Get-GdpByteHash (Read-GdpBytes (Join-Path $RepoRoot $name))
    }
    return [pscustomobject]$pins
}

function Get-GdpOwner {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $sid = $identity.User.Value }
    finally { $identity.Dispose() }
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try { $session = $process.SessionId }
    finally { $process.Dispose() }
    $profileKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $sid)
    if (-not $profileKey) { throw 'Interactive SID has no registered profile.' }
    try { $profile = [Environment]::ExpandEnvironmentVariables([string]$profileKey.GetValue('ProfileImagePath', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) }
    finally { $profileKey.Dispose() }
    if (-not [string]::Equals($profile, $env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-SUSourcePath $profile)) {
        throw 'Process profile and registered interactive SID profile disagree.'
    }
    if (-not ('GeneratedDotNetPath.Native' -as [type])) {
        Add-Type -Namespace GeneratedDotNetPath -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern uint GetShortPathName(string path, System.Text.StringBuilder output, uint size);
'@
    }
    $short = New-Object Text.StringBuilder 32768
    $size = [GeneratedDotNetPath.Native]::GetShortPathName($profile, $short, 32768)
    if ($size -eq 0 -or $size -ge 32768) { throw 'Cannot bind the interactive profile short spelling.' }
    $owner = [pscustomobject][ordered]@{ sid = $sid; profile = $profile; short_profile = $short.ToString(); session_id = $session }
    Assert-GdpOwner $owner
    return $owner
}

function Get-GdpKeyState {
    param($Key)
    if (@($Key.GetValueNames()) -notcontains 'Path') { throw 'Expected an existing raw Path registry value.' }
    return New-GdpState -Raw ([string]$Key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) -Kind ($Key.GetValueKind('Path').ToString())
}

function Get-GdpRegistryState {
    param([ValidateSet('User', 'Machine')][string]$Scope, $Owner)
    Assert-GdpOwner $Owner
    $key = if ($Scope -eq 'User') { [Microsoft.Win32.Registry]::Users.OpenSubKey($Owner.sid + '\Environment') }
           else { [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment') }
    if (-not $key) { throw "Cannot read the explicit $Scope PATH hive." }
    try { return Get-GdpKeyState $key }
    finally { $key.Dispose() }
}

function Set-GdpUserPath {
    param($Owner, $Before, $After, $Machine)
    Assert-GdpSame (Get-GdpOwner) $Owner 'owner immediately before User write'
    Assert-GdpState $Before
    Assert-GdpState $After
    $derived = New-GdpPlan -Owner $Owner -User $Before -Machine $Machine -Producers ([pscustomobject]@{}) -CapturedUtc '2000-01-01T00:00:00Z'
    if (-not $derived.ready_to_apply) { throw 'User writer requires the exact 56 fixture-only candidates.' }
    Assert-GdpSame $After $derived.after_user 'only the exact candidate removal reaches the writer'
    $key = [Microsoft.Win32.Registry]::Users.OpenSubKey($Owner.sid + '\Environment', $true)
    if (-not $key) { throw 'Cannot open the explicitly owned User environment for writing.' }
    try {
        Assert-GdpSame (Get-GdpKeyState $key) $Before 'User value under writable key handle'
        Assert-GdpSame (Get-GdpRegistryState -Scope Machine -Owner $Owner) $Machine 'Machine value immediately before User write'
        $key.SetValue('Path', $After.raw, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Dispose() }
    Assert-GdpSame (Get-GdpRegistryState -Scope User -Owner $Owner) $After 'User readback after write'
    Assert-GdpSame (Get-GdpRegistryState -Scope Machine -Owner $Owner) $Machine 'Machine readback after User write'
}
