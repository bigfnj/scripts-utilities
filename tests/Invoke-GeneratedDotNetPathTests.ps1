#Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\GeneratedDotNetPath.ps1')
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
function New-FixtureOwner {
    return [pscustomobject][ordered]@{ sid = 'S-1-5-21-1-2-3-1001'; profile = 'C:\Users\fixture'; short_profile = 'C:\Users\FIXTUR~1'; session_id = 2 }
}
function New-Fixture {
    param([int]$Count = 56)
    $owner = New-FixtureOwner
    $roots = @(Get-GdpRoots $owner)
    $entries = New-Object 'Collections.Generic.List[string]'
    $entries.Add('%SystemRoot%\system32')
    $entries.Add('')
    $entries.Add('C:\Users\fixture\.dotnet\tools')
    for ($i = 0; $i -lt $Count; $i++) {
        $root = if ($i -lt 38) { $roots[0] } elseif ($i -lt 52) { $roots[1] } else { $roots[2] }
        $entries.Add($root + "isolated-$i\dotnet-home\.dotnet\tools")
    }
    $entries.Add('C:\fixture\native\bin')
    $entries.Add('C:\fixture\native\bin')
    $entries.Add('C:\fixture\sysinternals')
    $entries.Add('')
    $entries.Add('')
    $user = New-GdpState -Raw ([string]::Join(';', $entries.ToArray())) -Kind ExpandString
    $machine = New-GdpState -Raw '%SystemRoot%\system32;C:\fixture\native\bin' -Kind ExpandString
    $pins = [pscustomobject][ordered]@{ 'fixture.ps1' = ('a' * 64) }
    $plan = New-GdpPlan -Owner $owner -User $user -Machine $machine -Producers $pins -CapturedUtc '2026-10-22T18:00:00Z'
    return [pscustomobject]@{ owner = $owner; user = $user; machine = $machine; pins = $pins; plan = $plan }
}
function Assert-FixturePlan {
    param($Fixture)
    Assert-GdpPlan -Plan $Fixture.plan -Owner $Fixture.owner -User $Fixture.user -Machine $Fixture.machine `
        -Producers $Fixture.pins -ExpectedUserSid $Fixture.owner.sid
}
function Copy-Value {
    param($Value)
    return ($Value | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
}
function Test-GateRefresh {
    param([string]$Source)
    $tokens = $null; $errors = $null
    $tree = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { return $false }
    $statements = @($tree.EndBlock.Statements)
    $load = @($statements | Where-Object { $_.Extent.Text -ceq '. (Join-Path $repoRoot ''lib\common.ps1'')' })
    $sync = @($statements | Where-Object { $_.Extent.Text -ceq 'Sync-EnvPath' })
    $suite = @($statements | Where-Object { $_.Extent.Text -match '^\$suites\s*=' })
    return $load.Count -eq 1 -and $sync.Count -eq 1 -and $suite.Count -eq 1 -and
        $load[0].Extent.StartOffset -lt $sync[0].Extent.StartOffset -and $sync[0].Extent.StartOffset -lt $suite[0].Extent.StartOffset
}

It 'the exact 38 long 14 short and 4 gq candidates produce the reviewed 56-entry plan' {
    $f = New-Fixture
    $groups = @($f.plan.removed | Group-Object artifact_root)
    $f.plan.ready_to_apply -and $f.plan.removed.Count -eq 56 -and
        @($groups | Where-Object Count -eq 38).Count -eq 1 -and
        @($groups | Where-Object Count -eq 14).Count -eq 1 -and
        @($groups | Where-Object Count -eq 4).Count -eq 1
}
It 'every other raw token duplicate empty token variable and order survives exactly' {
    $f = New-Fixture
    $f.plan.after_user.raw -ceq '%SystemRoot%\system32;;C:\Users\fixture\.dotnet\tools;C:\fixture\native\bin;C:\fixture\native\bin;C:\fixture\sysinternals;;' -and
        $f.plan.before.machine.raw -ceq $f.machine.raw -and $f.plan.after_user.kind -ceq 'ExpandString'
}
It 'normal global tools unrelated artifacts sibling roots and foreign profiles are retained' {
    $roots = @(Get-GdpRoots (New-FixtureOwner))
    foreach ($path in @('C:\Users\fixture\.dotnet\tools', 'D:\other\artifacts\a\.dotnet\tools',
        'C:\Users\fixture\Grimoire.source\desktop-ai-companion\artifacts-other\a\.dotnet\tools',
        'C:\Users\other\Grimoire.source\desktop-ai-companion\artifacts\a\.dotnet\tools')) {
        if (Get-GdpCandidateRoot $path $roots) { return $false }
    }
    return $true
}
It 'only the exact suffix is matched without trimming expanding or normalizing entries' {
    $root = @(Get-GdpRoots (New-FixtureOwner))[0]
    foreach ($path in @(($root + 'a\.dotnet\tools\'), ($root + 'a\.dotnet\tools-extra'),
        (' ' + $root + 'a\.dotnet\tools'), ($root + 'a\..\b\.dotnet\tools'), ($root + '%RUN%\.dotnet\tools'))) {
        if (Get-GdpCandidateRoot $path @($root)) { return $false }
    }
    (Get-GdpCandidateRoot ($root.ToUpperInvariant() + 'A\.DOTNET\TOOLS') @($root)) -ceq $root
}
It 'candidate matching never asks whether a target directory exists' {
    & {
        function Get-Item { throw 'candidate metadata forbidden' }
        function Test-Path { throw 'candidate metadata forbidden' }
        $f = New-Fixture
        return $f.plan.removed.Count -eq 56 -and $f.plan.candidate_files_read -eq $false
    }
}
It 'a complete unmodified plan passes explicit expected owner and raw identity checks' {
    $f = New-Fixture
    Assert-FixturePlan $f
    return $true
}
It 'the actual plan JSON reader preserves precise UTC strings through complete admission' {
    $f = New-Fixture
    $f.plan.captured_utc = '2026-10-22T22:04:04.6709914Z'
    $bytes = ConvertTo-GdpBytes $f.plan
    $f.plan = ConvertFrom-GdpJson ([Text.Encoding]::UTF8.GetString($bytes))
    Assert-FixturePlan $f
    $f.plan.captured_utc -is [string] -and $f.plan.captured_utc -ceq '2026-10-22T22:04:04.6709914Z'
}
It 'an explicit other SID is rejected before the write adapter can be reached' {
    $f = New-Fixture
    Rejects { Assert-GdpPlan $f.plan $f.owner $f.user $f.machine $f.pins 'S-1-5-21-1-2-3-1002' }
}
It 'changed owner profile short spelling or session cannot reuse a reviewed plan' {
    foreach ($name in @('sid', 'profile', 'short_profile', 'session_id')) {
        $f = New-Fixture
        $changed = Copy-Value $f.owner
        if ($name -eq 'session_id') { $changed.$name = 3 } else { $changed.$name += 'X' }
        if (-not (Rejects { Assert-GdpPlan $f.plan $changed $f.user $f.machine $f.pins $changed.sid })) { return $false }
    }
    return $true
}
It 'changed User or Machine raw values cannot reuse the prior plan even after hashing' {
    $f = New-Fixture
    (Rejects { Assert-GdpPlan $f.plan $f.owner (New-GdpState ($f.user.raw + ';C:\new') ExpandString) $f.machine $f.pins $f.owner.sid }) -and
        (Rejects { Assert-GdpPlan $f.plan $f.owner $f.user (New-GdpState ($f.machine.raw + ';C:\new') ExpandString) $f.pins $f.owner.sid })
}
It 'raw kind stale hash and embedded registry control characters fail closed' {
    (Rejects { New-GdpState 'C:\fixture' String }) -and
        (Rejects { New-GdpState ('C:\fixture' + [char]0) ExpandString }) -and
        (Rejects { New-GdpState "C:\fixture`nC:\other" ExpandString }) -and
        (Rejects { Assert-GdpState ([pscustomobject]@{ raw = 'C:\fixture'; kind = 'ExpandString'; utf16le_sha256 = ('0' * 64) }) })
}
It 'a rehashed plan cannot drop native tools alter kept order or swap removed indices' {
    foreach ($what in @('after', 'index', 'candidate')) {
        $f = New-Fixture
        if ($what -eq 'after') { $f.plan.after_user = New-GdpState 'C:\fixture\sysinternals' ExpandString }
        elseif ($what -eq 'index') { $f.plan.removed[0].index = 10 }
        else { $f.plan.removed[0].value = 'C:\Users\fixture\.dotnet\tools' }
        if (-not (Rejects { Assert-FixturePlan $f })) { return $false }
    }
    return $true
}
It '55 57 and zero candidates remain review-only and cannot authorize apply' {
    foreach ($count in @(55, 57, 0)) {
        $f = New-Fixture $count
        if ($f.plan.ready_to_apply -or -not (Rejects { Assert-FixturePlan $f })) { return $false }
    }
    return $true
}
It 'missing fields extra fields changed schema and acceptance flags cannot be rehashed away' {
    foreach ($what in @('missing', 'extra', 'schema', 'machine')) {
        $f = New-Fixture
        if ($what -eq 'missing') { $f.plan.PSObject.Properties.Remove('removed') }
        elseif ($what -eq 'extra') { $f.plan | Add-Member invented_approval $true }
        elseif ($what -eq 'schema') { $f.plan.schema = 'unknown' }
        else { $f.plan.machine_mutation = $true }
        if (-not (Rejects { Assert-FixturePlan $f })) { return $false }
    }
    return $true
}
It 'changed planner producer identity prevents applying an old review plan' {
    $f = New-Fixture
    Rejects { Assert-GdpPlan $f.plan $f.owner $f.user $f.machine ([pscustomobject]@{ 'fixture.ps1' = ('b' * 64) }) $f.owner.sid }
}
It 'empty raw PATH is retained as an empty raw REG_EXPAND_SZ value' {
    $f = New-Fixture
    $value = New-GdpPlan $f.owner (New-GdpState '' ExpandString) $f.machine $f.pins '2026-10-22T18:00:00Z'
    $value.after_user.raw -ceq '' -and @($value.removed).Count -eq 0 -and -not $value.ready_to_apply
}
It 'raw hashes cover UTF16LE text without a byte order mark or implicit expansion' {
    $text = '%SystemRoot%\' + [char]0x03C4
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $expected = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::Unicode.GetBytes($text)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
    (Get-GdpHash $text) -ceq $expected -and (Get-GdpHash $text) -cne (Get-GdpHash $text.ToUpperInvariant())
}
It 'exclusive backed-up artifact publication refuses an existing file and bounds rereads' {
    $cleanupPath = Join-Path ([IO.Path]::GetTempPath()) ('su-gdp-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $cleanupPath
    try {
        $path = Join-Path $cleanupPath 'backup.json'
        Write-GdpBytes $path ([byte[]]@(1, 2, 3))
        $one = Read-GdpBytes $path 3
        $collision = Rejects { Write-GdpBytes $path ([byte[]]@(9)) }
        $oversize = Rejects { Read-GdpBytes $path 2 }
        $one.Length -eq 3 -and $one[0] -eq 1 -and $collision -and $oversize
    } finally {
        Remove-Item -LiteralPath (Join-Path $cleanupPath 'backup.json') -Force
        Remove-Item -LiteralPath $cleanupPath -Force
    }
}
It 'the actual ordinary ancestor reader accepts the current repository source' {
    (Assert-GdpOrdinaryPath $repoRoot -Directory) -ceq $repoRoot -and
        (Assert-GdpOrdinaryPath (Join-Path $repoRoot 'lib\GeneratedDotNetPath.ps1')) -ceq (Join-Path $repoRoot 'lib\GeneratedDotNetPath.ps1')
}
It 'protected artifact strings are rejected before any metadata read' {
    & {
        function Get-Item { throw 'metadata must not run' }
        foreach ($name in @('C:\fixture\privatekey-test\plan.json', 'C:\fixture\.env.test\plan.json', 'C:\fixture\x.key')) {
            try { $null = Assert-GdpOrdinaryPath $name; return $false }
            catch { if ($_.Exception.Message -notlike '*Protected*') { return $false } }
        }
        return $true
    }
}
It 'the registry writer has exactly one explicit User setter and no machine setter' {
    $source = [IO.File]::ReadAllText((Join-Path $repoRoot 'lib\GeneratedDotNetPath.ps1'))
    $tokens = $null; $errors = $null
    $tree = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    $setters = @($tree.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'SetValue' }, $true))
    $setters.Count -eq 1 -and $setters[0].Extent.Text -ceq '$key.SetValue(''Path'', $After.raw, [Microsoft.Win32.RegistryValueKind]::ExpandString)' -and
        $source -match '\[Microsoft.Win32.Registry\]::Users.OpenSubKey\(\$Owner.sid \+ ''\\Environment'', \$true\)' -and
        $source -notmatch 'LocalMachine.OpenSubKey\([^\r\n]*\$true' -and $source -notmatch 'SetEnvironmentVariable'
}
It 'the entrypoint defaults to dry run and backup plus repeated guards precede the only writer' {
    $source = [IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\repair-generated-dotnet-path.ps1'))
    $dry = $source.IndexOf('if (-not $Apply)')
    $done = $source.IndexOf('exit 0', $dry)
    $backup = $source.IndexOf('Write-GdpBytes -Path $backupPath')
    $collision = $source.IndexOf('Existing PATH application artifacts prevent')
    $guard = $source.IndexOf('Assert-GdpPlan -Plan $value -Owner (Get-GdpOwner)')
    $write = $source.IndexOf('Set-GdpUserPath -Owner')
    $dry -gt 0 -and $done -gt $dry -and $collision -gt $done -and $backup -gt $collision -and $guard -gt $backup -and $write -gt $guard -and
        $source -match 'Apply requires -Plan, -PlanSha256 and -ExpectedUserSid' -and $source -match 'Explicit reviewed PATH plan SHA256 differs'
}
It 'the root gate refreshes process PATH before checks and a missing call is detected' {
    $source = [IO.File]::ReadAllText((Join-Path $repoRoot 'run-gate.ps1'))
    (Test-GateRefresh $source) -and -not (Test-GateRefresh ($source -replace '(?m)^Sync-EnvPath\r?\n', ''))
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail) { exit 1 }
exit 0
