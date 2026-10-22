#Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\common.ps1')
. (Join-Path $repoRoot 'lib\LegacyDos.ps1')
$script:Pass = 0
$script:Fail = 0
function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        if (& $Body) { $script:Pass++; Write-Host "  OK $Name" }
        else { $script:Fail++; Write-Host "  FAIL $Name" }
    } catch { $script:Fail++; Write-Host "  FAIL $Name : $($_.Exception.Message)" }
}
It 'offline vendor archive security regressions pass without installed RE tools' {
    $py = Get-ToolboxPython
    if (-not $py) {
        $command = Get-Command python -ErrorAction SilentlyContinue
        if ($command) { $py = $command.Source }
    }
    if (-not $py) { throw 'Python is needed for the stdlib archive regression tests.' }
    $result = Invoke-Native -FilePath $py -Arguments @('-X', 'utf8', '-Werror::ResourceWarning', (Join-Path $PSScriptRoot 'test_legacy_dos_vendor.py'))
    foreach ($line in $result.Output) { Write-Host "    $line" }
    Test-SURequiredPythonResult -ExitCode $result.ExitCode -Output $result.Output -MinimumTests 31
}
It 'source path predicates reject protected leaf and ancestor names without access' {
    $protected = @(
        'C:\fixture\x.env', 'C:\fixture\.env.test\child.ps1',
        'C:\fixture\.npmrc\child.md', 'C:\fixture\public.pem\child.ps1',
        'C:\fixture\synthetic.key\child.json', 'C:\fixture\x.p12\child.ps1',
        'C:\fixture\x.pfx\child.ps1', 'C:\fixture\x.keystore\child.ps1',
        'C:\fixture\PRIVATEKEY-anything\child.ps1',
        'C:\fixture\.git\credentials'
    )
    foreach ($name in $protected) {
        if (Test-SUSourcePath -Path $name) { return $false }
    }
    (Test-SUSourcePath -Path 'C:\fixture\safe\source.ps1') -and
        (Test-SUSourcePath -Path 'C:\fixture\my-privatekey-not-prefix\source.md')
}
It 'source enumeration prunes protected ancestors and links before listing their children' {
    $base = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'source-filter-names-only')).TrimEnd('\')
    $seen = New-Object 'System.Collections.Generic.List[string]'
    $list = {
        param($directory)
        $seen.Add($directory)
        if ($directory -eq $base) {
            foreach ($name in @('.env.fixture', 'PRIVATEKEY-fixture', 'safe', 'linked')) {
                [pscustomobject]@{
                    Name = $name
                    FullName = $base + '\' + $name
                    PSIsContainer = $true
                    Attributes = $(if ($name -eq 'linked') { [IO.FileAttributes]::ReparsePoint } else { [IO.FileAttributes]::Directory })
                }
            }
        } elseif ($directory -eq ($base + '\safe')) {
            [pscustomobject]@{
                Name = 'source.ps1'
                FullName = $directory + '\source.ps1'
                PSIsContainer = $false
                Attributes = [IO.FileAttributes]::Normal
                Extension = '.ps1'
            }
        } else { throw 'The enumerator entered an excluded directory.' }
    }.GetNewClosure()
    $metadata = { param($directory) [pscustomobject]@{ PSIsContainer = $true; Attributes = [IO.FileAttributes]::Directory } }
    $files = @(Get-SUSourceFiles -Root $base -Recurse -Extension @('.ps1') -RootMetadata $metadata -ListDirectory $list)
    $files.Count -eq 1 -and $files[0].Name -eq 'source.ps1' -and $seen.Count -eq 2
}

It 'required nested Python suite rejects zero tests skips absent summaries and nonzero exits' {
    $good = @('Ran 28 tests in 0.1s', '', 'OK')
    if (-not (Test-SURequiredPythonResult -ExitCode 0 -Output $good -MinimumTests 28)) { return $false }
    foreach ($bad in @(
        @('Ran 0 tests in 0.0s', 'OK'),
        @('Ran 27 tests in 0.1s', 'OK'),
        @('Ran 28 tests in 0.1s', 'OK (skipped=1)'),
        @('Ran 28 tests in 0.1s', 'OK', 'skipped fixture'),
        @('OK'),
        @('Ran 28 tests in 0.1s', 'Ran 28 tests in 0.1s', 'OK')
    )) {
        if (Test-SURequiredPythonResult -ExitCode 0 -Output $bad -MinimumTests 28) { return $false }
    }
    -not (Test-SURequiredPythonResult -ExitCode 1 -Output $good -MinimumTests 28)
}
It 'source root junction is refused before listing any child' {
    $seen = New-Object 'System.Collections.Generic.List[string]'
    $metadata = { param($directory) [pscustomobject]@{ PSIsContainer = $true; Attributes = [IO.FileAttributes]::ReparsePoint } }
    $list = { param($directory) $seen.Add($directory); throw 'Root was enumerated.' }.GetNewClosure()
    $rejected = $false
    try { Get-SUSourceFiles -Root 'C:\fixture\junction-root' -RootMetadata $metadata -ListDirectory $list }
    catch { $rejected = $_.Exception.Message -like '*link or junction*' }
    $rejected -and $seen.Count -eq 0
}
It 'projection measures the selected root instead of inherited toolbox environment' {
    $seen = New-Object 'System.Collections.Generic.List[string]'
    $probe = { param($path) $seen.Add($path); [pscustomobject]@{ IsProjected = $false } }.GetNewClosure()
    $selected = 'C:\fixture\selected-toolbox'
    $result = Test-SULegacyHostProjection -Root $selected -Probe $probe
    $seen.Count -eq 1 -and $seen[0] -eq (Join-Path $selected 'python\.venv\Scripts\python.exe') -and -not $result.IsProjected
}
It 'parallel DOSBox control selection cannot replace the established wrapper' {
    $legacy = Get-SULegacyVendorSelection -Name Dosbox
    $control = Get-SULegacyVendorSelection -Name DosboxControl
    $compiler = Get-SULegacyVendorSelection -Name Watcom
    $legacy.Component -eq 'dosbox' -and $legacy.Wrapper -eq 'dosbox-x' -and
        $control.Component -eq 'dosbox-control' -and $control.Wrapper -eq 'dosbox-x-control' -and
        $compiler.Component -eq 'watcom' -and $null -eq $compiler.Wrapper
}
It 'pinned Ghidra selection ignores registered older releases and other JDK majors' {
    $root = 'C:\fixture\selected-toolbox'
    $native = Join-Path $root 'native'
    $dirs = @(
        [pscustomobject]@{ Name = 'jdk-25.0.1'; FullName = (Join-Path $native 'jdk-25.0.1') },
        [pscustomobject]@{ Name = 'jdk-210'; FullName = (Join-Path $native 'jdk-210') },
        [pscustomobject]@{ Name = 'jdk-21.0.9+10'; FullName = (Join-Path $native 'jdk-21.0.9+10') }
    )
    $list = { param($directory) $dirs }.GetNewClosure()
    $exists = { param($path) $true }
    $pinned = Get-SUPinnedGhidraSelection -Root $root -ReleaseTag 'Ghidra_12.1.4_build' -JdkMajor 21 -FileExists $exists -ListNative $list
    $pinned.InstallPath -eq (Join-Path $native 'ghidra_12.1.4_PUBLIC') -and $pinned.JdkPath -eq $dirs[2].FullName
}
It 'pinned Ghidra rejects incomplete installation and wrong-major-only JDKs' {
    $missing = { param($path) $path -notlike '*analyzeHeadless.bat' }
    $empty = { param($directory) @() }
    $rejected = 0
    try { Get-SUPinnedGhidraSelection -Root 'C:\fixture\toolbox' -ReleaseTag 'Ghidra_12.1.4_build' -JdkMajor 21 -FileExists $missing -ListNative $empty }
    catch { if ($_.Exception.Message -like '*incomplete*') { $rejected++ } }
    try { Get-SUPinnedGhidraSelection -Root 'C:\fixture\toolbox' -ReleaseTag 'Ghidra_12.1.4_build' -JdkMajor 21 -FileExists { $true } -ListNative $empty }
    catch { if ($_.Exception.Message -like '*JDK 21*') { $rejected++ } }
    $rejected -eq 2
}
It 'Watcom shim plan emits nothing if the final executable is absent' {
    $written = New-Object 'System.Collections.Generic.List[string]'
    $exists = { param($path) $path -notlike '*\wasm.exe' }
    $rejected = $false
    try {
        @(Get-SUWatcomShimPlan -InstallRoot 'C:\fixture\watcom' -FileExists $exists) |
            ForEach-Object { $written.Add($_.Name) }
    } catch { $rejected = $_.Exception.Message -like '*before wrapper registration*' }
    if (-not $rejected -or $written.Count -ne 0) { return $false }
    $complete = @(Get-SUWatcomShimPlan -InstallRoot 'C:\fixture\watcom' -FileExists { $true })
    $complete.Count -eq 6 -and $complete[-1].Name -eq 'wasm'
}

if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail) { exit 1 }
exit 0
