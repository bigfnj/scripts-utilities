#Requires -Version 5.1
<#
.SYNOPSIS
Install explicitly selected DOS reverse engineering tools without administrator privileges.
.DESCRIPTION
Uses the shared toolbox Python, catalog Capstone package, existing Ghidra helper,
and pinned official portable DOSBox-X/Open Watcom archives. Nothing is selected by
default. The normal bootstrap does not invoke this script.
.EXAMPLE
.\scripts\install-legacy-dos.ps1 -Component Capstone
.EXAMPLE
.\scripts\install-legacy-dos.ps1 -Component All -DryRun
#>
[CmdletBinding()]
param(
    [ValidateSet('Capstone', 'Unicorn', 'Dosbox', 'Ghidra', 'Watcom', 'All')]
    [string[]]$Component = @(),
    [string]$Root = $(if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }),
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\common.ps1')
. (Join-Path $repoRoot 'lib\LegacyDos.ps1')
$script:DryRun = [bool]$DryRun
if (-not $Component.Count) { throw 'Select -Component Capstone, Unicorn, Dosbox, Ghidra, Watcom, or All. Nothing is installed by default.' }
$selected = if ($Component -contains 'All') { @('Capstone', 'Unicorn', 'Dosbox', 'Ghidra', 'Watcom') } else { @($Component | Select-Object -Unique) }
$configPath = Join-Path $repoRoot 'config\legacy-dos-tools.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($config.schema_version -ne 1) { throw 'Unsupported legacy DOS tools configuration.' }
if ($DryRun) {
    foreach ($name in $selected) { Write-Info "[DRY-RUN] explicit optional component: $name -> $Root" }
    Write-Info '[DRY-RUN] no downloads, package changes, registry changes, wrappers, or directory creation'
    return
}

# This is also required operationally before calling this script from an agent.
# Refuse projected and unmeasurable views before the first download or package write.
$projection = Test-SULegacyHostProjection -Root $Root
if ($null -eq $projection.IsProjected -or $projection.IsProjected) {
    throw "Toolbox view is projected or unknown: $($projection.Reason). Run scripts\test-host-projection.ps1 from a normal user shell."
}
$hadRoot = Test-Path Env:\CODEX_TOOLBOX
$previousRoot = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { $null }
$env:CODEX_TOOLBOX = $Root

function Install-LegacyPythonLibrary {
    param([ValidateSet('capstone', 'unicorn')][string]$Name)
    # These import-only libraries need no CLI wrapper. Read the exact catalog pin
    # and use isolated pip so user pip config is never opened by this workflow.
    $installer = Join-Path $repoRoot 'tools\install_legacy_python.py'
    $result = Invoke-Native -FilePath $py -Arguments @('-X', 'utf8', $installer, $Name, '--catalog', (Join-Path $repoRoot 'catalog.json'))
    if ($result.ExitCode -ne 0) { throw "$Name catalog-pinned provisioning failed: $($result.Output -join ' ')" }
    Write-Info ($result.Output -join ' ')
}

function Register-LegacyDosShim {
    param([string]$Name, [string]$Target, [string[]]$Prologue = @())
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) { throw "Tool executable missing: $Target" }
    $bin = Join-Path $Root 'native\bin'
    if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Path $bin -Force | Out-Null }
    $shim = Join-Path $bin ($Name + '.cmd')
    $body = New-ShimBody -Target $Target -Prologue $Prologue
    Set-Content -LiteralPath $shim -Value $body -Encoding ASCII -NoNewline
    [void](Install-NativeShim -Wrapper $shim)
    $actual = Get-ShimTarget -Lines @(Get-Content -LiteralPath $shim)
    if ($actual -ne $Target) { throw "The $Name shim failed the shared shim contract." }
}

try {
    $py = Get-ToolboxPython
    if (-not $py) { throw 'Shared toolbox Python is missing. Do not create an ad hoc environment.' }
    $vendorTool = Join-Path $repoRoot 'tools\legacy_dos_vendor.py'
    foreach ($name in $selected) {
        switch ($name) {
            'Capstone' {
                Install-LegacyPythonLibrary -Name 'capstone'
                $check = 'import capstone; assert len(list(capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_32).disasm(bytes([144,195]),0))) == 2; print(capstone.__version__)'
                $probe = Invoke-Native -FilePath $py -Arguments @('-X', 'utf8', '-c', $check)
                if ($probe.ExitCode -ne 0) { throw "Capstone x86 smoke failed: $($probe.Output -join ' ')" }
                Write-Ok "Capstone x86 disassembly: $($probe.Output -join ' ')"
            }
            'Unicorn' {
                Install-LegacyPythonLibrary -Name 'unicorn'
                Write-Ok 'Unicorn installed in the shared toolbox venv; run the functional smoke check.'
            }
            'Ghidra' {
                & (Join-Path $PSScriptRoot 'install-ghidra.ps1') -Root $Root -ReleaseTag $config.ghidra.release_tag -JdkMajor $config.ghidra.jdk_major
                . (Join-Path $repoRoot 'modules\security.ps1')
                $pinned = Get-SUPinnedGhidraSelection -Root $Root -ReleaseTag $config.ghidra.release_tag -JdkMajor $config.ghidra.jdk_major
                security_install_ghidra -InstallPath $pinned.InstallPath -JdkPath $pinned.JdkPath -JdkMajor $config.ghidra.jdk_major
            }
            default {
                $key = $name.ToLowerInvariant()
                $result = Invoke-Native -FilePath $py -Arguments @('-X', 'utf8', $vendorTool, $key, '--root', $Root, '--config', $configPath)
                if ($result.ExitCode -ne 0) { throw "$name vendor provisioning failed: $($result.Output -join ' ')" }
                $receipt = ($result.Output -join [Environment]::NewLine) | ConvertFrom-Json
                if ($name -eq 'Dosbox') {
                    Register-LegacyDosShim -Name 'dosbox-x' -Target $receipt.executable
                    Add-WinManifest -Name 'dosbox-x' -Binary 'dosbox-x' -Group 'security' -Method 'vendor-archive' -Scope 'toolbox' -Detect 'dosbox-x -version' -Notes "Official portable DOSBox-X $($receipt.release), SHA-256 $($receipt.sha256); verify debugger capabilities separately."
                } else {
                    $toolRoot = [string]$receipt.root
                    $localEnvironment = @('setlocal', ('set "WATCOM={0}"' -f $toolRoot), ('set "INCLUDE={0}\h"' -f $toolRoot), ('set "PATH={0}\binnt64;%PATH%"' -f $toolRoot))
                    $shimPlan = @(Get-SUWatcomShimPlan -InstallRoot $toolRoot)
                    foreach ($item in $shimPlan) {
                        Register-LegacyDosShim -Name $item.Name -Target $item.Target -Prologue $localEnvironment
                    }
                    Add-WinManifest -Name 'open-watcom' -Binary 'wcl386' -Group 'security' -Method 'vendor-archive' -Scope 'toolbox' -Detect 'wcl386 -?' -Notes "Official portable Open Watcom $($receipt.release), SHA-256 $($receipt.sha256); WATCOM/INCLUDE/PATH remain wrapper-local."
                }
                Write-Ok "$name $($receipt.release) -> $($receipt.root)"
            }
        }
    }
    Sync-EnvPath
    Write-Info 'Run scripts\smoke-test-legacy-dos.ps1 for functional checks and run-gate.ps1 for cumulative regression checks.'
} finally {
    if ($hadRoot) { $env:CODEX_TOOLBOX = $previousRoot }
    else { Remove-Item Env:\CODEX_TOOLBOX -ErrorAction SilentlyContinue }
}
