#Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'SUTestGuard.ps1')
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\common.ps1')
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
    $result.ExitCode -eq 0
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
    $files = @(Get-SUSourceFiles -Root $base -Recurse -Extension @('.ps1') -ListDirectory $list)
    $files.Count -eq 1 -and $files[0].Name -eq 'source.ps1' -and $seen.Count -eq 2
}
if (-not (Assert-SUSuiteFloor -SuiteFile $PSCommandPath -Ran ($script:Pass + $script:Fail))) { $script:Fail++ }
Show-SUGuardSummary
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail) { exit 1 }
exit 0
