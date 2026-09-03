#Requires -Version 5.1
<#
Install the machine-scope (elevation-required) native packages up front, so a
subsequent normal-user bootstrap run finds them already present and skips them
silently instead of firing a UAC prompt per package.

Winget currently publishes these package manifests as machine-scope only, so
they cannot be installed with '--scope user' and each one triggers a UAC prompt
during a normal-user build. Installing them all in a single elevated pass turns
~7 interactive prompts into one elevation.

This script is channel-clean: pure winget, official IDs, machine scope. It has
NO dependency on any specific elevation tool. Run it once with an admin/SYSTEM
token by whatever means your environment provides:

  # From an elevated PowerShell:
  .\scripts\install-machine-scope.ps1

  # Headless/unattended via an elevation helper that runs as SYSTEM. Such a
  # process is detached from your shell (you cannot see its stdout), so pass
  # -LogPath and read the log afterwards from a normal shell. The log ends with
  # a 'DONE (...)' sentinel and records the security context via whoami:
  .\scripts\install-machine-scope.ps1 -LogPath C:\Users\Public\ms-install.log

The ID list comes from catalog.json (machine_scope_ids); override with -Ids only
for a one-off. Keep catalog.json in sync with the machineScope entries in
scripts/build-devtoolbox.ps1.
#>
[CmdletBinding()]
param(
    [string[]]$Ids,
    [string]$LogPath,
    [switch]$SkipWireshark,
    [switch]$SkipWDK,
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Source the catalog loader (Get-Catalog is dependency-free) to read the
# machine-scope ID list, so it lives in exactly one place.
. (Join-Path (Split-Path $PSScriptRoot) "lib\catalog.ps1")
if (-not $Ids) { $Ids = @((Get-Catalog).machine_scope_ids) }
# Accept a single comma-joined value too (e.g. -Ids "a,b,c") - PowerShell does not
# split a *quoted* string into a [string[]], so normalize commas here.
$Ids = @($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Log {
    param([string]$Message)
    Write-Host $Message
    if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $Message -Encoding UTF8 }
}

if ($LogPath) {
    $dir = Split-Path $LogPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $LogPath -Value "" -Encoding UTF8
}

Log "install-machine-scope start: $(Get-Date -Format o)"
Log "context: $(whoami)"

if ($SkipWireshark) { $Ids = @($Ids | Where-Object { $_ -ne 'WiresharkFoundation.Wireshark' }) }
if ($SkipWDK)       { $Ids = @($Ids | Where-Object { $_ -ne 'Microsoft.WindowsWDK.10.0.26100' }) }

# Resolve winget. Under a normal (even elevated) user the WindowsApps alias
# works. Under SYSTEM/TrustedInstaller that per-user alias is absent, so fall
# back to the packaged executable in Program Files\WindowsApps (readable there
# because SYSTEM has access to that ACL-locked directory).
function Resolve-Winget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) { return $cmd.Source }
    $dirs = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Directory `
                -Filter "Microsoft.DesktopAppInstaller_*_x64__*" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
    foreach ($d in $dirs) {
        $candidate = Join-Path $d.FullName "winget.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

$winget = Resolve-Winget
if (-not $winget) {
    Log "FAIL winget.exe could not be resolved in this security context"
    Log "DONE (failure)"
    exit 1
}
Log "winget: $winget"

# Some packages fail with 0x8A150010 when --scope machine is passed even though
# they install to machine-scope paths. Omit --scope for these IDs entirely and
# let winget use its own default (which for these packages IS machine scope).
$NoScopeFlag = @(
    'Microsoft.WindowsWDK.10.0.26100'
)

# A manifest that ships several installers may default to the wrong one, so the catalog entry can pin it.
# Read from catalog.json rather than hardcoded here, so the pin lives in one place with the tool it belongs
# to. Microsoft.PowerShell is the only user today: winget 7.6.0+ defaults that id to the MSIX, which is
# single-user and sandboxes $PSHOME, and only the wix (MSI) installer is machine-scope at all.
$installerTypes = @{}
try {
    foreach ($t in (Get-Catalog).tools) {
        if ($t.PSObject.Properties['installer_type'] -and $t.installer_type) {
            $installerTypes[[string]$t.id] = [string]$t.installer_type
        }
    }
}
catch {
    Log "WARN could not read installer_type pins from catalog.json: $($_.Exception.Message)"
    Log "WARN continuing WITHOUT installer pins - a pinned package may install the wrong installer type"
}

$failures = @()
foreach ($id in $Ids) {
    $listed = & $winget list --id $id -e --accept-source-agreements 2>&1
    if ($LASTEXITCODE -eq 0 -and ($listed -match [regex]::Escape($id))) {
        Log "SKIP already installed: $id"
        continue
    }
    $scopeArgs = if ($id -in $NoScopeFlag) { @() } else { @('--scope', 'machine') }
    $typeArgs = if ($installerTypes.ContainsKey($id)) { @('--installer-type', $installerTypes[$id]) } else { @() }
    if ($DryRun) {
        $scopeStr = if ($scopeArgs) { "--scope machine" } else { "(no --scope flag)" }
        $typeStr = if ($typeArgs) { " --installer-type $($installerTypes[$id])" } else { "" }
        Log "[DRY-RUN] would: winget install --id $id -e $scopeStr$typeStr"
        continue
    }
    $scopeLabel = if ($scopeArgs) { "machine scope" } else { "default scope (no --scope flag)" }
    if ($typeArgs) { $scopeLabel += ", installer-type $($installerTypes[$id])" }
    Log "install $id ($scopeLabel)"
    & $winget install --id $id -e @scopeArgs @typeArgs `
        --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        Log "FAIL $id (winget exit $LASTEXITCODE)"
        $failures += $id
    } else {
        Log "OK $id"
    }
}

if ($failures.Count -gt 0) {
    Log "completed with failures: $($failures -join ', ')"
    Log "DONE (failure)"
    exit 1
}
Log "all machine-scope packages present"
Log "DONE (success)"
exit 0
