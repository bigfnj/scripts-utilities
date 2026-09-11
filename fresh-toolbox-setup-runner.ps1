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
    [switch]$InstallLlm,
    # Escape hatch only. Leaving PATH unconsolidated is what makes installed tools invisible to a
    # shell that inherits the machine PATH only, or that receives a PATH truncated at ~4 KB.
    [switch]$SkipPathConsolidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$Bootstrap = Join-Path $RepoRoot "bootstrap.ps1"
$Smoke = Join-Path $RepoRoot "scripts\smoke-test.ps1"
$GhidraInstaller = Join-Path $RepoRoot "scripts\install-ghidra.ps1"
$LlmInstaller = Join-Path $RepoRoot "scripts\install-llm.ps1"
$PathConsolidator = Join-Path $RepoRoot "scripts\consolidate-path.ps1"
$LogDir = Join-Path $RepoRoot "logs\fresh-workstation"
$LogFile = Join-Path $LogDir ("setup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Write-Step { param([string]$Message) Write-Host "`n== $Message ==" -ForegroundColor White }
function Write-Info { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "OK $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "WARN $Message" -ForegroundColor Yellow }

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

# A PowerShell script that does not end in an explicit `exit` leaves $LASTEXITCODE exactly as it
# found it: the code of whatever NATIVE process it last happened to run. bootstrap.ps1 is such a
# script, and on a dry run the last native thing it runs is lib\common.ps1's `find_spec` probe,
# which exits 1 for every package that is not installed yet. This function used to zero
# $LASTEXITCODE, call bootstrap and then read it back, so a perfectly good dry run aborted with
# "Run bootstrap.ps1 failed (exit 1)" - a failure invented by a probe doing its job. The callee
# cannot be fixed from here, so stop asking it a question it cannot answer.
#
# How a PowerShell script actually reports failure is a terminating error, and every callee here
# sets $ErrorActionPreference = 'Stop', so that error propagates out of `& $Action` and we catch
# it. $LASTEXITCODE is consulted only when the caller states that this particular callee sets it
# on purpose:
#   -NonFatalExitCodes  codes the callee raises deliberately that are NOT failures. Honoured on
#                       its own, because a script can exit explicitly on one branch and fall off
#                       the end (leaking a code) on another - consolidate-path.ps1 does exactly
#                       that: `exit 2` when elevation is declined, no exit at all on success.
#   -TrustExitCode      the callee ends EVERY path in an explicit exit, so any unlisted non-zero
#                       code is genuinely its own and is fatal. smoke-test.ps1 and bootstrap.ps1
#                       both qualify: bootstrap.ps1 used to fall off the end and inherit the code
#                       of whatever native command it ran last, which is why the runner stopped
#                       trusting it; it now exits 1 on GROUP_FAILURES and 0 otherwise, so a
#                       "bootstrap INCOMPLETE - N tool(s) failed" run must stop the runner rather
#                       than letting it carry on to PATH consolidation over a half-installed box.
function Invoke-Checked {
    param(
        [string]$Description,
        [scriptblock]$Action,
        [hashtable]$NonFatalExitCodes = @{},
        [switch]$TrustExitCode
    )
    Write-Info $Description
    $global:LASTEXITCODE = 0
    try {
        & $Action
    } catch {
        throw "$Description failed: $($_.Exception.Message)"
    }
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    if ($code -ne 0 -and $NonFatalExitCodes.ContainsKey($code)) {
        Write-Warn ("{0}: {1}" -f $Description, $NonFatalExitCodes[$code])
        return
    }
    if ($TrustExitCode -and $code -ne 0) { throw "$Description failed (exit $code)" }
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
    Invoke-Checked "Run bootstrap.ps1" { & $Bootstrap @bootstrapArgs } -TrustExitCode

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

    # Must run AFTER every group, because each one appends to PATH and this measures the result.
    # Skipping it leaves the machine in the state this repo exists to prevent: tools installed,
    # registered, and invisible - either past the ~4 KB point where Windows truncates the PATH it
    # hands a new process, or on the user PATH only, which a machine-PATH-only shell never sees.
    if (-not $SkipPathConsolidation) {
        Write-Step "PATH consolidation"
        # Exit 2 from consolidate-path.ps1 is a decision, not a crash: the script self-elevates
        # through UAC and returns 2 when consent is refused (or -NoElevate suppressed the prompt),
        # having written NOTHING. Treating that as a failure would abort a setup that is otherwise
        # complete; ignoring it would hide the one outcome the user needs to act on.
        $consolidatorCodes = @{
            2 = "skipped - elevation declined, PATH left exactly as it was. Re-run '.\scripts\consolidate-path.ps1' from an elevated shell to apply it."
        }
        if ($DryRun) {
            # -DryRun returns before the elevation gate, so it never exits 2 and never sets its
            # own code - hence no -TrustExitCode here either.
            Invoke-Checked "Report the PATH consolidation plan" { & $PathConsolidator -DryRun }
        } else {
            # A PATH that cannot be consolidated is worth reporting loudly, but it must not fail
            # an otherwise good install. The script backs both PATH values up first and prints
            # its own -Restore line.
            try { Invoke-Checked "Consolidate PATH" { & $PathConsolidator } -NonFatalExitCodes $consolidatorCodes }
            catch { Write-Warn "PATH consolidation failed: $_" }
        }
    } else {
        Write-Info "PATH consolidation skipped (-SkipPathConsolidation)"
    }

    Write-Step "verification"
    if ($DryRun) {
        Write-Info "[DRY-RUN] would run scripts\smoke-test.ps1 after installation"
    } else {
        # smoke-test.ps1 is the one callee that ends every path in an explicit exit (1 on any
        # failed check, 0 otherwise), so its code is genuinely its own and must stay fatal.
        Invoke-Checked "Run repository smoke test" { & $Smoke } -TrustExitCode
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
