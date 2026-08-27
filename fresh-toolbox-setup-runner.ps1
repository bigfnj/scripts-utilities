#Requires -Version 5.1
<#
Provision and verify scripts-utilities on a new Windows workstation.

Run from a normal (non-elevated) Windows PowerShell prompt. Installers that
require elevation may display their own UAC prompt.

  .\fresh-toolbox-setup-runner.ps1 -DryRun
  .\fresh-toolbox-setup-runner.ps1
  .\fresh-toolbox-setup-runner.ps1 -SkipHeavy -SkipPlaywrightBrowsers
  .\fresh-toolbox-setup-runner.ps1 -InstallGhidra
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$RefreshToolbox,
    [switch]$SkipHeavy,
    [switch]$SkipPlaywrightBrowsers,
    [switch]$SkipWireshark,
    [switch]$SkipWDK,
    [switch]$InstallGhidra,
    [switch]$InstallLlm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$Bootstrap = Join-Path $RepoRoot "bootstrap.ps1"
$Smoke = Join-Path $RepoRoot "scripts\smoke-test.ps1"
$GhidraInstaller = Join-Path $RepoRoot "scripts\install-ghidra.ps1"
$LlmInstaller = Join-Path $RepoRoot "scripts\install-llm.ps1"
$LogDir = Join-Path $RepoRoot "logs\fresh-workstation"
$LogFile = Join-Path $LogDir ("setup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Write-Step { param([string]$Message) Write-Host "`n== $Message ==" -ForegroundColor White }
function Write-Info { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "OK $Message" -ForegroundColor Green }

function Assert-Prerequisites {
    $nativeArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($nativeArch -ne "AMD64") {
        throw "This bootstrap currently supports x64 Windows only (detected: $nativeArch)."
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        if ($DryRun) {
            Write-Info "[DRY-RUN] winget is not visible here; real setup requires App Installer/winget."
        } else {
            throw "winget is required. Install/update App Installer, open a new PowerShell window, and verify 'winget --version'."
        }
    }
    foreach ($path in @($Bootstrap, $Smoke, $GhidraInstaller, $LlmInstaller)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing repository file: $path" }
    }
}

function Invoke-Checked {
    param([string]$Description, [scriptblock]$Action)
    Write-Info $Description
    $global:LASTEXITCODE = 0
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$Description failed (exit $LASTEXITCODE)" }
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path $LogFile -Force | Out-Null
try {
    Write-Step "fresh workstation preflight"
    Write-Info "repo: $RepoRoot"
    Write-Info "log:  $LogFile"
    Assert-Prerequisites

    if ($SkipWireshark) { $env:TOOLBOX_SKIP_WIRESHARK = "1" }
    if ($SkipWDK)       { $env:TOOLBOX_SKIP_WDK       = "1" }

    Write-Step "build toolbox and install workstation tools"
    $bootstrapArgs = @{}
    if ($DryRun) { $bootstrapArgs.DryRun = $true }
    if ($RefreshToolbox) { $bootstrapArgs.RefreshToolbox = $true }
    if ($SkipHeavy) { $bootstrapArgs.SkipHeavyToolboxBuild = $true }
    if ($SkipPlaywrightBrowsers) { $bootstrapArgs.SkipPlaywrightBrowsers = $true }
    Invoke-Checked "Run bootstrap.ps1" { & $Bootstrap @bootstrapArgs }

    if ($InstallGhidra) {
        Write-Step "optional Ghidra"
        if ($DryRun) {
            & $GhidraInstaller -DryRun
        } else {
            Invoke-Checked "Install portable Ghidra and JDK" { & $GhidraInstaller }
            Invoke-Checked "Register Ghidra in the security group" { & $Bootstrap -Only security }
        }
    }

    if ($InstallLlm) {
        Write-Step "optional local LLM stack (Ollama)"
        if ($DryRun) {
            & $LlmInstaller -DryRun
        } else {
            Invoke-Checked "Install local LLM stack" { & $LlmInstaller }
        }
    }

    Write-Step "verification"
    if ($DryRun) {
        Write-Info "[DRY-RUN] would run scripts\smoke-test.ps1 after installation"
    } else {
        Invoke-Checked "Run repository smoke test" { & $Smoke }
    }

    Write-Step "complete"
    Write-Ok "fresh-workstation setup completed"
    Write-Ok "log: $LogFile"
} catch {
    Write-Host "`nFAILED: $_" -ForegroundColor Red
    Write-Host "Log: $LogFile" -ForegroundColor Yellow
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
