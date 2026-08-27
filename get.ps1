<#
  scripts-utilities one-line bootstrap.  Run from any PowerShell:

      irm https://raw.githubusercontent.com/bigfnj/scripts-utilities/main/get.ps1 | iex

  It runs from memory, so nothing needs cloning to start: it ensures git is present, clones (or
  updates) the repo to a local folder, then opens a menu that drives the real scripts. Everything
  runs NON-elevated; only the optional machine-scope pre-install asks for elevation, and it says so.

  Because `| iex` cannot take parameters, override the defaults with env vars set BEFORE the
  one-liner:

      $env:TOOLBOX_DIR = "$HOME\dev\scripts-utilities"  # where to clone (default: %USERPROFILE%\scripts-utilities)
      $env:TOOLBOX_REF = 'v1.0.0'                       # branch or tag to check out (default: main)

  Security note: piping a remote script to iex executes whatever is at that URL at that moment.
  Read it first — the raw URL above is the whole file — and for a reproducible install point
  TOOLBOX_REF at a tag rather than a moving branch.
#>
$ErrorActionPreference = 'Stop'
$RepoUrl = 'https://github.com/bigfnj/scripts-utilities.git'
$Ref = if ($env:TOOLBOX_REF) { $env:TOOLBOX_REF } else { 'main' }
$Dir = if ($env:TOOLBOX_DIR) { $env:TOOLBOX_DIR } else { Join-Path $env:USERPROFILE 'scripts-utilities' }

function Write-Head($t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "  [ok]  $t" -ForegroundColor Green }
function Write-Warn2($t) { Write-Host "  [!]   $t" -ForegroundColor Yellow }

# --- git --------------------------------------------------------------------
# The repo is a tree (catalog.json + lib/ + modules/ + scripts/), not one script, so the install
# genuinely needs a checkout. git also makes "re-run to update" a fetch instead of a re-download.
function Find-Git {
  $c = Get-Command git -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}
function Install-Git {
  $git = Find-Git
  if ($git) { Write-Ok 'git present'; return $git }
  Write-Warn2 'git not found - installing via winget (Git.Git)...'
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget is unavailable. Install Microsoft App Installer (or Git for Windows) and re-run.'
  }
  Start-Process winget -Wait -ArgumentList @('install', '--id', 'Git.Git', '-e',
    '--accept-source-agreements', '--accept-package-agreements')
  $git = Find-Git
  if (-not $git) { throw 'git still not found after install. Open a NEW terminal and re-run the one-liner.' }
  Write-Ok 'git installed'
  return $git
}

# --- banner -----------------------------------------------------------------
try { Clear-Host } catch {}
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor DarkCyan
Write-Host '   scripts-utilities  -  Windows dev toolbox (bootstrap)' -ForegroundColor White
Write-Host '  ============================================================' -ForegroundColor DarkCyan

# winget is required by the installers themselves, not just by the git fallback above. Say so now
# rather than 200 lines into a run.
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Warn2 'winget was not found. The toolbox installs gap-fill tools through it.'
  Write-Warn2 'Install "App Installer" from the Microsoft Store, then open a NEW PowerShell window.'
}

$git = Install-Git

# --- target dir + OneDrive guard --------------------------------------------
Write-Head "Install folder: $Dir"
$inOneDrive = ($Dir -match 'OneDrive') -or ($env:OneDrive -and $Dir -like "$env:OneDrive*")
if ($inOneDrive) {
  Write-Warn2 'That path is under OneDrive. Setup transcripts and a git checkout do not sync well;'
  Write-Warn2 "prefer somewhere under your profile, e.g. $env:USERPROFILE\scripts-utilities."
}
$ans = Read-Host '  Press Enter to use it, or type another path'
if ($ans) { $Dir = $ans }

# --- clone or update ---------------------------------------------------------
if (Test-Path (Join-Path $Dir '.git')) {
  Write-Head "Updating existing clone ($Ref)..."
  & $git -C $Dir fetch --depth 1 origin $Ref
  if ($LASTEXITCODE -ne 0) { throw "git fetch failed (exit $LASTEXITCODE)." }
  # Hard reset rather than pull: this is a throwaway mirror of a published ref, and a depth-1 fetch
  # leaves a "diverged" shallow state that breaks pull --ff-only. reset --hard only touches tracked
  # files, so the generated manifest/ and logs/ are left alone.
  & $git -C $Dir reset --hard FETCH_HEAD
}
elseif ((Test-Path $Dir) -and (Get-ChildItem -Force $Dir -ErrorAction SilentlyContinue | Select-Object -First 1)) {
  throw "$Dir exists and is not a scripts-utilities clone. Set `$env:TOOLBOX_DIR to an empty path and re-run."
}
else {
  Write-Head "Cloning $RepoUrl ($Ref)..."
  $parent = Split-Path $Dir -Parent
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  & $git clone --branch $Ref --depth 1 $RepoUrl $Dir
}
if ($LASTEXITCODE -ne 0) { throw "git clone/update failed (exit $LASTEXITCODE)." }

$Runner    = Join-Path $Dir 'fresh-toolbox-setup-runner.ps1'
$Bootstrap = Join-Path $Dir 'bootstrap.ps1'
$Gui       = Join-Path $Dir 'gui\toolbox-gui.ps1'
$MachScope = Join-Path $Dir 'scripts\install-machine-scope.ps1'
$Smoke     = Join-Path $Dir 'scripts\smoke-test.ps1'
if (-not (Test-Path $Runner)) { throw "runner not found at $Runner (unexpected repo layout)." }
Write-Ok "repo ready at $Dir"

function Invoke-Script { param([string]$Path, [string[]]$Arguments = @())
  & powershell -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments
}

# Show the catalog once up front, so the first thing you see is what this would install.
Write-Head 'Tool groups in this catalog:'
Invoke-Script $Bootstrap @('-List')

# --- interactive menu ---------------------------------------------------------
function Show-Menu {
  Write-Host ''
  Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
  Write-Host '   1  Dry run              (show every change, make none)'
  Write-Host '   2  Full install         (recommended)'
  Write-Host '   3  Lean install         (-SkipHeavy: no GPU/ML stack)'
  Write-Host '   4  Minimal install      (-SkipHeavy -SkipPlaywrightBrowsers)'
  Write-Host '   5  Desktop window       (GUI checkbox installer)'
  Write-Host '   6  Pre-install machine-scope packages  (ELEVATES - avoids repeated UAC prompts)'
  Write-Host '   7  Smoke test           (verify an existing install)'
  Write-Host '   8  Open the install folder'
  Write-Host '   Q  Quit'
  Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
}
$run = $true
while ($run) {
  Show-Menu
  switch ((Read-Host '  Select').Trim().ToUpperInvariant()) {
    '1' { Invoke-Script $Runner @('-DryRun') }
    '2' { Invoke-Script $Runner }
    '3' { Invoke-Script $Runner @('-SkipHeavy') }
    '4' { Invoke-Script $Runner @('-SkipHeavy', '-SkipPlaywrightBrowsers') }
    '5' { Write-Head 'Launching the installer window (close it to return here)...'; Invoke-Script $Gui }
    '6' {
      Write-Warn2 'This step requests elevation. It pre-installs the machine-scope packages in ONE'
      Write-Warn2 'elevation so the normal-user run below does not prompt per package.'
      Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MachScope) -Wait
    }
    '7' { Invoke-Script $Smoke }
    '8' { Start-Process explorer.exe $Dir }
    'Q' { $run = $false }
    default { Write-Warn2 'Unrecognized choice - enter 1-8 or Q.' }
  }
}
Write-Host ''
Write-Ok 'Done. Re-run the one-liner any time to update the clone and reopen this menu.'
Write-Warn2 'Open a NEW PowerShell window before using the tools: PATH changes apply to new processes.'
