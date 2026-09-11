#Requires -Version 5.1
<#
Build the durable Windows DevToolbox under %LOCALAPPDATA%\DevToolbox.

This is stage 1 of the workstation setup. bootstrap.ps1 is stage 2.
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:LOCALAPPDATA "DevToolbox"),
    [switch]$SkipHeavy,
    [switch]$SkipPlaywrightBrowsers,
    # Build the venv on a system-REGISTERED Python 3.11 when no uv-managed one can be
    # found. Off by default and it should stay that way: see Get-Python311 for why the
    # choice is permanent once the venv exists.
    [switch]$AllowSystemPython,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ToolboxSchemaVersion = 2

# THE ONLY DOT-SOURCE IN THIS FILE, and it stays the only one.
#
# This script is deliberately standalone: bootstrap.ps1 runs it as a CHILD PROCESS, so it gets
# none of bootstrap's scope, and nothing it needs may depend on having been dot-sourced by
# somebody. That property was worth keeping, and it is why the divergence it caused went
# unnoticed for so long - this file carried its own private copy of the .cmd shim format while
# lib\ShimFormat.ps1 carried the rule saying not to, and the private copy was a here-string.
#
# lib\ShimFormat.ps1 was created on 2026-09-11 for exactly this callsite: two functions, 71 lines,
# no side effects on dot-source, no transitive dot-sources of its own. Read its header for why the
# contract could not live in lib\ShimPlan.ps1 (the whole shim planner) or in lib\common.ps1 (the
# installer plumbing, plus a $script:MANIFEST that points at real state on load).
#
# The cost of being wrong about the path is bounded and loud: a missing file throws here, at load,
# before the script has touched the machine. The cost of the duplication it replaces was silent -
# every wrapper this build writes unparseable, and every reader reporting zero.
. (Join-Path $PSScriptRoot '..\lib\ShimFormat.ps1')

$CorePackages = @(
    "python-docx", "docxcompose", "docxtpl", "mammoth", "python-pptx",
    "openpyxl", "XlsxWriter", "xlrd", "pyxlsb", "pandas", "numpy", "duckdb",
    "pypdf", "pymupdf", "pdfplumber", "reportlab",
    "pillow", "pillow-heif", "imageio", "imageio-ffmpeg", "opencv-python-headless", "pycairo", "svglib",
    "pytesseract", "beautifulsoup4", "html5lib", "lxml", "markdown",
    "google-api-python-client", "google-auth", "google-auth-oauthlib", "google-auth-httplib2", "gspread",
    "pywin32", "comtypes", "PyYAML", "playwright",
    "requests", "rich", "typer", "chardet", "charset-normalizer"
)

$HeavyPackages = @(
    "scipy", "scikit-image", "onnxruntime-gpu", "rembg[gpu]", "realesrgan", "basicsr", "gfpgan", "facexlib"
)

$NativePackages = @(
    @{ id = "astral-sh.uv"; commands = @("uv", "uvx") },
    @{ id = "JohnMacFarlane.Pandoc"; commands = @("pandoc") },
    @{ id = "TheDocumentFoundation.LibreOffice"; commands = @("soffice"); machineScope = $true },
    @{ id = "tesseract-ocr.tesseract"; commands = @("tesseract"); machineScope = $true },
    @{ id = "oschwartz10612.Poppler"; commands = @("pdfinfo", "pdftoppm") },
    @{ id = "QPDF.QPDF"; commands = @("qpdf"); machineScope = $true },
    @{ id = "ImageMagick.ImageMagick"; commands = @("magick"); machineScope = $true },
    @{ id = "Gyan.FFmpeg.Essentials"; commands = @("ffmpeg", "ffprobe") },
    @{ id = "7zip.7zip"; commands = @("7z"); machineScope = $true },
    @{ id = "BurntSushi.ripgrep.MSVC"; commands = @("rg") },
    @{ id = "sharkdp.fd"; commands = @("fd") },
    @{ id = "jqlang.jq"; commands = @("jq") },
    @{ id = "MikeFarah.yq"; commands = @("yq") },
    @{ id = "OliverBetz.ExifTool"; commands = @("exiftool") },
    @{ id = "aria2.aria2"; commands = @("aria2c") },
    @{ id = "Rclone.Rclone"; commands = @("rclone") },
    @{ id = "OpenJS.NodeJS.LTS"; commands = @("node", "npm", "npx", "corepack"); machineScope = $true },
    @{ id = "DuckDB.cli"; commands = @("duckdb") }
)

$CommandSearchPatterns = @{
    "pandoc"    = @("$env:LOCALAPPDATA\Pandoc\pandoc.exe")
    "soffice"   = @("$env:ProgramFiles\LibreOffice\program\soffice.exe")
    "tesseract" = @("$env:ProgramFiles\Tesseract-OCR\tesseract.exe")
    "7z"        = @("$env:ProgramFiles\7-Zip\7z.exe")
    "exiftool"  = @("$env:LOCALAPPDATA\Programs\ExifTool\ExifTool.exe")
    "gswin64c"  = @((Join-Path $Root "native\ghostscript\bin\gswin64c.exe"), (Join-Path $Root "native\ghostscript\gs10.07.1\bin\gswin64c.exe"))
    "gswin64"   = @((Join-Path $Root "native\ghostscript\bin\gswin64.exe"), (Join-Path $Root "native\ghostscript\gs10.07.1\bin\gswin64.exe"))
}

function Write-Info { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "OK $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "WARN $Message" -ForegroundColor Yellow }
function Write-Err { param([string]$Message) Write-Host "FAIL $Message" -ForegroundColor Red }
function Write-Step { param([string]$Message) Write-Host "`n== $Message ==" -ForegroundColor White }

function Assert-Prerequisites {
    if (-not $env:LOCALAPPDATA) { throw "LOCALAPPDATA is not defined; this script requires a normal Windows user profile." }
    $nativeArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($nativeArch -ne "AMD64") { throw "This builder currently supports x64 Windows only (detected: $nativeArch)." }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw @"
winget is required but is not available in this PowerShell session.
Install or update 'App Installer' from Microsoft Store, open a new normal
PowerShell window, and confirm 'winget --version' works before continuing.
"@
    }
}

function Invoke-Checked {
    param(
        [string]$Description,
        [scriptblock]$Action
    )
    Write-Info $Description
    if ($DryRun) { return }
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $Description (exit $LASTEXITCODE)"
    }
}

function Sync-EnvPath {
    # IT APPENDED $env:PATH TO ITSELF. Measured on this box 2026-09-11 (Machine PATH 1,588 chars,
    # User PATH 148, a 990-char starting $env:PATH), four calls of the old body:
    #
    #     call 1 -> 2,868 chars,  64 entries, 62 distinct
    #     call 2 -> 4,746 chars, 108 entries, 62 distinct   <- past 4,095
    #     call 3 -> 6,624 chars, 152 entries, 62 distinct
    #     call 4 -> 8,502 chars, 196 entries, 62 distinct
    #
    # +1,878 chars and 44 entries per call, and the DISTINCT count never moves - every one of those
    # 134 added entries is a duplicate. This build makes exactly four calls (Get-Python311 at two
    # sites, Install-WingetPackage once per native package, Run-Smoke), so a real session crosses
    # 4,095 on its SECOND call: the exact truncation cliff scripts\smoke-test.ps1 exists to warn
    # about, reached from inside the builder. Every winget, uv and pip child launched after that
    # point inherits the oversized PATH. The same four calls of the body below hold at 1,633 chars
    # and 40 entries, identical on call 1 and call 4.
    #
    # Machine + User + the two toolbox directories ARE the whole truth, so the prior $env:PATH is
    # discarded rather than folded back in. That is not a new opinion: it is what lib\common.ps1's
    # Sync-EnvPath has always done. This copy differed from it in four ways and only one of them
    # was a live defect; the other three (no Test-Path, no de-duplication, no filtering of empties)
    # were what let the growth run unbounded instead of converging, so all four close together.
    #
    # WHY THE DUPLICATION REMAINS. Not an oversight and not laziness - the two are not the same
    # function. common.ps1 resolves the toolbox from $env:CODEX_TOOLBOX (falling back to
    # %LOCALAPPDATA%\DevToolbox); this one uses $Root, a real -Root parameter that lets the builder
    # target a tree that is not the live toolbox. Collapsing them means either losing -Root or
    # dot-sourcing 30 KB of installer plumbing into a script bootstrap.ps1 runs as a child process
    # specifically so it stays standalone. The ShimFormat.ps1 note at the top of this file is the
    # one place that trade came out the other way, and it did because the format had exactly one
    # correct answer - a PATH root legitimately has two. So: keep both, and keep them behaviourally
    # identical. If you change one, change the other.
    $machine = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $user = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $paths = @()
    # Test-Path, because on the first build native\bin and the venv do not exist yet. Adding a
    # directory that is not there is not free: it is a dead entry that every later call preserves,
    # and it is indistinguishable from the dead entries consolidate-path.ps1 is meant to remove.
    foreach ($candidate in @(
        (Join-Path $Root "native\bin"),
        (Join-Path $Root "python\.venv\Scripts")
    )) {
        if (Test-Path $candidate) { $paths += $candidate }
    }
    $paths += ($machine -split ';')
    $paths += ($user -split ';')
    # -Unique makes repeated calls CONVERGE: the second call reproduces the first call's result
    # exactly, which is the property that turns "called four times" from a defect into a no-op.
    $env:PATH = ($paths | Where-Object { $_ } | Select-Object -Unique) -join ';'
}

function Ensure-Directory {
    param([string]$Path)
    if ($DryRun) {
        Write-Info "[DRY-RUN] ensure directory: $Path"
        return
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-UvExecutable {
    # Get-Command only sees PATH, and uv's shim lived under the toolbox tree - so when that
    # tree was deleted on 2026-09-10 uv became "unavailable" to this script while the winget
    # package was still installed the entire time. That single false negative is what sent
    # the Python choice down the system-interpreter path, so look harder than PATH.
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { return $cmd.Source }
    # Find-Executable already knows the winget package layout
    # (%LOCALAPPDATA%\Microsoft\WinGet\Packages\<id>_<source suffix>\uv.exe).
    return (Find-Executable -Name "uv" -WingetId "astral-sh.uv")
}

function Test-Python311 {
    param([string]$Exe)
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return $false }
    # ASK the interpreter; do not read the version out of its directory name. uv's layout
    # holds both a concrete cpython-3.11.15-windows-x86_64-none directory and a
    # cpython-3.11-windows-x86_64-none JUNCTION pointing at it, and a junction can outlive
    # its target - so "3.11" in a path is a claim, and the version baked into pyvenv.cfg is
    # not a claim that can be retracted later.
    #
    # No 2>&1: redirecting native stderr under $ErrorActionPreference='Stop' makes 5.1 raise
    # a terminating NativeCommandError even on success (lib\common.ps1:294-298). The catch is
    # for the other case - an executable that exists but cannot start, e.g. a dangling
    # junction - which should read as "not a usable 3.11", not as a build failure.
    try {
        $reported = & $Exe -c "import sys; print('{}.{}'.format(*sys.version_info[:2]))"
    } catch { return $false }
    return (($LASTEXITCODE -eq 0) -and ((@($reported) -join "").Trim() -eq "3.11"))
}

function Find-ManagedPython311 {
    # A uv-managed 3.11 can be ON DISK while uv's CLI is unreachable - that is precisely the
    # state a deleted toolbox leaves behind, and the state in which the old code quietly
    # chose the system interpreter instead. Two independent lookups, because they fail
    # independently: uv's install directory, and the py launcher's own registry (uv registers
    # its Pythons as "Astral/CPython3.11.x", so `py -0p` still finds one after a PATH wipe).
    $roots = @($env:UV_PYTHON_INSTALL_DIR, (Join-Path $env:APPDATA "uv\python")) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($root in $roots) {
        # Concrete versions first and newest first, so cpython-3.11.15 beats cpython-3.11.9
        # (a plain -Descending string sort does not: '9' sorts above '1') and both beat the
        # bare cpython-3.11 junction, whose name hides which patch it actually resolves to.
        $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Filter "cpython-3.11*" -ErrorAction SilentlyContinue) |
            ForEach-Object {
                $concrete = $_.Name -match '^cpython-(3\.11\.\d+)-'
                [pscustomobject]@{
                    Exe      = (Join-Path $_.FullName "python.exe")
                    Concrete = [bool]$concrete
                    Version  = $(if ($concrete) { [version]$Matches[1] } else { [version]"3.11.0" })
                }
            } | Sort-Object -Property Concrete, Version -Descending
        foreach ($candidate in $candidates) {
            if (Test-Python311 -Exe $candidate.Exe) { return $candidate.Exe }
        }
    }
    $pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        # `py -0p` prints e.g. " -V:Astral/CPython3.11.15   C:\...\python.exe", with an
        # optional " *" default marker between tag and path. The tag carries the patch
        # version, so match a 3.11 PREFIX rather than comparing for equality. No stderr
        # redirect here either - see Test-Python311.
        $listed = @()
        try { $listed = @(& $pyLauncher.Source -0p) } catch { $listed = @() }
        foreach ($line in $listed) {
            if ($line -match '^\s*-V:Astral/CPython3\.11(\.\d+)?\s+\*?\s*(?<path>\S.*\S)\s*$') {
                if (Test-Python311 -Exe $Matches["path"]) { return $Matches["path"] }
            }
        }
    }
    return $null
}

function Get-Python311 {
    # Prefer a uv-managed standalone Python 3.11 for the toolbox venv. uv's Pythons are
    # plain extractions - NOT registered in Add/Remove Programs and NOT on PATH - so
    # corporate "old Python" scanners/remediation don't see or delete them (the system
    # PATH Python can be whatever's current). This also keeps the venv base stable and
    # reproducible, and it is what the "keep 3.11 off PATH" rule in docs\agent-rules.md
    # is describing.
    #
    # Order: uv CLI -> uv-managed on disk -> a warning that can actually print -> system.
    # The warning used to sit INSIDE the `if ($uv)` block, so the one path that really
    # reached the system fallback - uv not resolvable at all - was the one path that said
    # nothing. The 2026-09-10 rebuild would have built the venv on the compliance-visible
    # registered 3.11 and announced it nowhere.
    #
    # And that would have been permanent in practice: a venv's base interpreter is written
    # into pyvenv.cfg when the venv is created, Ensure-PythonVenv returns the existing venv
    # on every later run, and nothing else calls this function. Hence a throw rather than a
    # warning - the cheap fix (`uv python install 3.11`) is only cheap BEFORE the venv
    # exists. Fail-closed is the deliberate choice; -AllowSystemPython is the override.
    if ($DryRun) {
        Write-Info "[DRY-RUN] would resolve a uv-managed Python 3.11 (private, unregistered)"
        return "python.exe"
    }

    $uv = Get-UvExecutable
    if (-not $uv) {
        Write-Info "install astral-sh.uv (manages the toolbox's private Python 3.11)"
        $uvInstall = Invoke-Winget -WingetArgs @("install", "--id", "astral-sh.uv", "-e",
            "--accept-source-agreements", "--accept-package-agreements", "--silent", "--scope", "user")
        if ($uvInstall.ExitCode -ne 0) {
            # Deliberately not fatal and deliberately not silent. The usual cause is "already
            # installed", which winget also reports non-zero; the authoritative answer is the
            # probe on the next line, not the exit code. The old code ignored this outcome
            # entirely and then read $null out of Get-Command.
            Write-Info "winget exit $($uvInstall.ExitCode) for astral-sh.uv - probing for it directly"
        }
        Sync-EnvPath
        $uv = Get-UvExecutable
    }

    if ($uv) {
        Write-Info "uv python install 3.11 (private, unregistered)"
        # Both uv calls go through Invoke-NativeCapture. uv writes progress to STDERR, including
        # on success ("Installed Python 3.11.15 in 103ms"), and the previous `| Out-Null` here
        # promoted that success line to a terminating NativeCommandError that failed the whole
        # build at the first phase. See the note on Invoke-NativeCapture for the measurement.
        #
        # A non-zero exit is non-fatal: the usual cause is "already installed". The
        # authoritative answer is the probe below, not the exit code.
        $uvInstallPy = Invoke-NativeCapture -Exe $uv -Arguments @("python", "install", "3.11")
        if ($uvInstallPy.ExitCode -ne 0) {
            Write-Info "uv python install exited $($uvInstallPy.ExitCode) - probing for the interpreter directly"
        }
        $uvFind = Invoke-NativeCapture -Exe $uv -Arguments @("python", "find", "3.11")
        $managed = @(Select-NativeStdout -Output $uvFind.Output | Select-Object -First 1)[0]
        if (Test-Python311 -Exe $managed) { return $managed }
    }

    $onDisk = Find-ManagedPython311
    if ($onDisk) {
        Write-Ok "uv-managed Python 3.11 found on disk: $onDisk"
        return $onDisk
    }

    Write-Warn "no uv-managed Python 3.11 is available on this machine (uv resolvable: $([bool]$uv))"
    if (-not $AllowSystemPython) {
        throw @"
Refusing to build the toolbox venv on a system-registered Python 3.11.

The base interpreter is written into the venv's pyvenv.cfg when the venv is created, and
Ensure-PythonVenv returns the existing venv on every later run - so this choice is permanent
in practice, and a compliance sweep that removes "old Python" would take the toolbox with it.

Fix the cause instead:
    winget install --id astral-sh.uv -e --scope user   # only if 'uv' is missing
    uv python install 3.11

Then re-run this script. To accept a compliance-visible base interpreter anyway, re-run with
-AllowSystemPython.
"@
    }
    Write-Warn "-AllowSystemPython given: building on a system/registered Python 3.11 (may trip compliance)"

    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:ProgramFiles\Python311\python.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    $pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        $version = & $pyLauncher.Source -3.11 -c "import sys; print(sys.executable)"
        if ($LASTEXITCODE -eq 0 -and $version) { return ($version | Select-Object -First 1) }
    }
    Write-Info "install Python.Python.3.11 (fallback; system-registered)"
    $pyInstall = Invoke-Winget -WingetArgs @("install", "--id", "Python.Python.3.11", "-e",
        "--accept-source-agreements", "--accept-package-agreements", "--silent", "--scope", "user")
    if ($pyInstall.ExitCode -ne 0) {
        foreach ($line in $pyInstall.Output) { Write-Host "    $line" -ForegroundColor DarkGray }
        throw "Python 3.11 install failed (exit $($pyInstall.ExitCode)); uv and winget both unusable"
    }
    Sync-EnvPath
    $sys = "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
    if (Test-Path $sys) { return $sys }
    throw "Python 3.11 not found after install"
}

function Get-VenvBaseInterpreter {
    param([string]$VenvPath)
    # Read the venv's OWN record of what it was built on. Get-Python311 runs exactly once -
    # on the run that creates the venv - and every later run short-circuits in
    # Ensure-PythonVenv, so on a re-run the $Python handed to Write-Manifest is the venv's
    # own python.exe and says nothing about its base. pyvenv.cfg is the only thing that
    # still knows, which is what makes the manifest field a measurement rather than a claim.
    # 'base-executable' is written by 3.11's venv module; 'home' is the older key and holds
    # the directory, which is still enough to tell uv-managed apart from system-registered.
    $cfg = Join-Path $VenvPath "pyvenv.cfg"
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    $values = @{}
    foreach ($line in @(Get-Content -LiteralPath $cfg -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*([^=#][^=]*?)\s*=\s*(.*?)\s*$') { $values[$Matches[1].ToLowerInvariant()] = $Matches[2] }
    }
    if ($values.ContainsKey("base-executable")) { return $values["base-executable"] }
    if ($values.ContainsKey("home")) { return $values["home"] }
    return $null
}

function Test-UvManagedPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $roots = @($env:UV_PYTHON_INSTALL_DIR, (Join-Path $env:APPDATA "uv\python")) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    foreach ($root in $roots) {
        if ($Path.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Ensure-PythonVenv {
    $venvPython = Join-Path $Root "python\.venv\Scripts\python.exe"
    if (Test-Path $venvPython) { return $venvPython }
    $python = Get-Python311
    Invoke-Checked "create Python venv" {
        & $python -m venv (Join-Path $Root "python\.venv")
    }
    return $venvPython
}

function Write-Requirements {
    $corePath = Join-Path $Root "python\requirements-core.txt"
    $heavyPath = Join-Path $Root "python\requirements-ml.txt"
    if ($DryRun) {
        Write-Info "[DRY-RUN] write requirements files"
        return
    }
    $CorePackages | Set-Content -Path $corePath -Encoding ASCII
    $HeavyPackages | Set-Content -Path $heavyPath -Encoding ASCII
}

function Install-PythonPackages {
    param([string]$Python)
    Invoke-Checked "upgrade pip/setuptools/wheel" {
        & $Python -m pip install --upgrade pip setuptools wheel
    }
    Invoke-Checked "install core Python packages" {
        & $Python -m pip install --prefer-binary -r (Join-Path $Root "python\requirements-core.txt")
    }
    if (-not $SkipHeavy) {
        Invoke-Checked "install PyTorch CUDA wheels" {
            & $Python -m pip install --prefer-binary torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
        }
        Invoke-Checked "install heavy Python packages" {
            & $Python -m pip install --prefer-binary -r (Join-Path $Root "python\requirements-ml.txt")
        }
        Patch-BasicSR -Python $Python
    } else {
        Write-Warn "skipping heavy Python packages"
    }
}

function Patch-BasicSR {
    param([string]$Python)
    if ($DryRun) { return }
    $script = @'
from pathlib import Path
import site
for root in site.getsitepackages():
    p = Path(root) / "basicsr" / "data" / "degradations.py"
    if p.exists():
        text = p.read_text(encoding="utf-8")
        text = text.replace(
            "from torchvision.transforms.functional_tensor import rgb_to_grayscale",
            "from torchvision.transforms.functional import rgb_to_grayscale",
        )
        p.write_text(text, encoding="utf-8")
'@
    # Run from a temp file, not `python -c`: a multi-line script passed to -c is
    # mangled by PowerShell native-arg handling (newlines collapse -> SyntaxError).
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("patch_basicsr_" + [Guid]::NewGuid().ToString("N") + ".py")
    Set-Content -LiteralPath $tmp -Value $script -Encoding UTF8
    try { & $Python $tmp } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Invoke-Winget {
    <#
        Run winget with its output CAPTURED and its stderr survivable. Every winget call in
        this file goes through here, because both ways of calling it directly are broken
        under Windows PowerShell 5.1 and the two failures hide each other.

        1. An unredirected native command inside a function writes to that FUNCTION'S output
           stream. `winget @args; if ($LASTEXITCODE -ne 0) { return $false }` therefore
           returned [<winget's stdout lines>, $false], and the caller's `if (-not $ok)`
           guard silently stopped working, because -not on a multi-element array is $false.
           Measured under 5.1: the leaky shape returns 3 elements and the guard fires =
           False; captured, 1 element, fires = True. This is character-for-character the
           defect 8bca5e9 fixed in lib\common.ps1:190 - the builder still had it, which
           meant an 18-package native install could fail outright and still print "done".

        2. This file sets $ErrorActionPreference = 'Stop' globally, and under Stop a native
           command whose stderr is merged with 2>&1 raises a TERMINATING NativeCommandError
           EVEN WHEN IT SUCCEEDED (lib\common.ps1:294-298 documents the same trap). The old
           `winget list ... 2>&1` had that shape: one noise line on stderr from the first of
           18 packages would have killed the whole build. Continue is set around the call
           and restored in a finally, so a later throw never runs with the preference down.

        Returns ExitCode and Output, not a bool, because the callers disagree about what a
        non-zero exit means: for `winget list` it means "not installed yet", which is not a
        failure, and for `winget install astral-sh.uv` it usually means "already installed".
    #>
    param([Parameter(Mandatory)][string[]]$WingetArgs)
    return Invoke-NativeCapture -Exe "winget" -Arguments $WingetArgs
}

function Invoke-NativeCapture {
    <#
        The general form of the trap Invoke-Winget was written for. Run ANY native command with
        its output captured and its stderr survivable, and return the exit code beside it.

        THE TRIGGER IS THE PIPE, not the redirection. PowerShell turns a native command's stderr
        into ErrorRecords whenever that command's output flows into another command, and under
        this file's global $ErrorActionPreference = 'Stop' the first such record is TERMINATING -
        even when the command succeeded. Measured on 2026-09-11, mid-rebuild:

            & $uv python install 3.11 | Out-Null
            uv.exe : Installed Python 3.11.15 in 103ms
            + CategoryInfo : NotSpecified: (Installed Python 3.11.15 in 103ms:String)
            + FullyQualifiedErrorId : NativeCommandError

        uv reports progress on stderr, so its SUCCESS message killed the build. `| Out-Null` did
        not merely fail to prevent that, it CAUSED it: the pipe is what promotes stderr to an
        ErrorRecord. Out-Null solves the different problem of native stdout leaking into a
        function's return value, and the two are easy to confuse - the comment that used to sit
        at that call site named the right hazard and drew the wrong conclusion from it.

        An unpiped `& $Python -m pip install ...` is therefore fine as it stands and is left
        alone; only calls whose output is piped or captured need this.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $Exe @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
    } finally { $ErrorActionPreference = $prev }
}

function Select-NativeStdout {
    # 2>&1 merges ErrorRecords into the same array, so a caller that wants the command's real
    # stdout has to drop them. Without this, 'uv python find' returns a progress line as often
    # as a path.
    param([object[]]$Output)
    return @($Output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
             ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
}

function Install-WingetPackage {
    param([string]$Id, [switch]$MachineScope)
    if ($DryRun) {
        Write-Info "[DRY-RUN] winget install $Id"
        return $true
    }
    Assert-Prerequisites
    $listed = Invoke-Winget -WingetArgs @("list", "--id", $Id, "-e", "--accept-source-agreements")
    if ($listed.ExitCode -eq 0 -and ($listed.Output -match [regex]::Escape($Id))) {
        Write-Info "$Id already installed"
        return $true
    }
    Write-Info "winget install $Id"
    # $wingetArgs, not $args: $args is an automatic variable, and assigning to it inside a
    # function that already has a param block reads as though the caller's arguments are
    # being forwarded when they are not.
    $wingetArgs = @("install", "--id", $Id, "-e", "--accept-source-agreements", "--accept-package-agreements", "--silent")
    if (-not $MachineScope) { $wingetArgs += @("--scope", "user") }
    $install = Invoke-Winget -WingetArgs $wingetArgs
    if ($install.ExitCode -ne 0) {
        # The captured lines are only worth reading on this path, which is the whole reason
        # Invoke-Winget keeps them instead of piping to Out-Null.
        foreach ($line in $install.Output) { Write-Host "    $line" -ForegroundColor DarkGray }
        Write-Err "$Id install failed (exit $($install.ExitCode))"
        return $false
    }
    Sync-EnvPath
    return $true
}

function Find-Executable {
    param([string]$Name, [string]$WingetId = "")

    # Prefer the package we just installed over an unrelated bundled executable
    # with the same name (for example VS Code's rg.exe or XnView's exiftool.exe).
    if ($WingetId) {
        $packagesRoot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
        if (Test-Path $packagesRoot) {
            $packageDirs = Get-ChildItem -LiteralPath $packagesRoot -Directory -Filter "$WingetId*" -ErrorAction SilentlyContinue
            $exe = if ($Name.EndsWith(".exe")) { $Name } else { "$Name.exe" }
            $cmdName = if ($Name.EndsWith(".cmd")) { $Name } else { "$Name.cmd" }
            # ONE recursive walk per package, not two. This used to be two -Filter passes over the
            # same tree, one for .exe and one for .cmd, and on the expensive path - a name no
            # package supplies - BOTH walked the whole tree. Measured 2026-09-11 over this box's 27
            # winget packages / 1,241 files, 7 runs each:
            #
            #   two -Filter passes (before)        76.6 ms per miss
            #   one -Filter "<name>*" walk         37.9 ms per miss   (2.0x)
            #
            # MEASURED AND REJECTED, do not "simplify" to either of these:
            #   - One UNFILTERED walk + a Where-Object on .Name is 86.1 ms, SLOWER than the two
            #     passes it replaces. -Filter is handled by the filesystem driver; dropping it
            #     materialises a FileInfo for all 1,241 files in PowerShell.
            #   - -Include $exe, $cmdName looked like the obvious answer at 19.4 ms and is WRONG:
            #     with -LiteralPath, -Include is silently IGNORED. It returned every file in the
            #     package, AUTHORS and README.html included, and the timing was just an inert
            #     filter breaking out of the loop on the first package. This is the same trap
            #     tests\Invoke-InstallerTests.ps1 records against Get-ShimCandidates, where an
            #     -Include would have written a README.cmd shim.
            #
            # The wildcard is "$Name*", not "$Name.*", so it stays a superset of both exact names
            # even when the caller passes a name that already carries an extension - the line above
            # then computes $cmdName as 'foo.exe.cmd', which 'foo.exe.*' cannot match.
            # Verified identical to the two-pass version over 31 names x 27 packages, 0 differences.
            foreach ($packageDir in $packageDirs) {
                $hits = @(Get-ChildItem -LiteralPath $packageDir.FullName -Recurse -File -Filter "$Name*" -ErrorAction SilentlyContinue |
                    Where-Object { ($_.Name -ieq $exe) -or ($_.Name -ieq $cmdName) })
                if (-not $hits.Count) { continue }
                # .exe still beats .cmd within a package. The two sequential passes expressed that
                # preference as ORDER; one walk has to say it out loud, or a package shipping both
                # (cURL ships wcurl.bat beside curl.exe) starts resolving to whichever the
                # enumeration happened to reach first.
                $found = @(@($hits | Where-Object { $_.Name -ieq $exe }) +
                           @($hits | Where-Object { $_.Name -ieq $cmdName }))[0]
                return $found.FullName
            }
        }
    }

    if ($CommandSearchPatterns.ContainsKey($Name)) {
        foreach ($path in $CommandSearchPatterns[$Name]) {
            if (Test-Path $path) { return $path }
        }
    }

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) {
        if ([IO.Path]::GetExtension($cmd.Source) -ieq ".ps1") {
            $cmdShim = [IO.Path]::ChangeExtension($cmd.Source, ".cmd")
            if (Test-Path $cmdShim) { return $cmdShim }
        }
        return $cmd.Source
    }

    # THE EXHAUSTIVE FALLBACK. BACKLOG measures this at 4,048 ms per miss and proposes "cache
    # misses per run". NOT DONE, and not because it is hard - because a per-run miss cache is
    # WRONG HERE, and the reason is worth writing down so nobody re-derives it as an easy win.
    #
    # This function's dominant caller shape is PROBE, INSTALL, PROBE AGAIN:
    #   Get-Python311:277 probes uv, misses, installs astral-sh.uv, probes again at :290
    #   Install-Ghostscript:796 probes gswin64c/gswin64, misses, extracts, probes again at :830
    # Both second probes are SUPPOSED to hit - that is the whole point of the install between
    # them. A cache that remembers "uv was not found this run" makes the install unobservable and
    # returns $null from a box that now has uv on it, which is precisely the false negative
    # Get-UvExecutable:180 was written to stop. Ghostscript would fail the same way, silently.
    #
    # Making it correct means invalidating the cache on every mutation - each winget install, each
    # 7z extraction, each Sync-EnvPath - i.e. a cache with an invalidation protocol threaded
    # through the installers. That is a redesign, not a small change, and it buys ~4 s on a path
    # taken a handful of times in a build that downloads gigabytes. Left open in BACKLOG.
    #
    # The cheap half of that BACKLOG line - "bound the depth" - is also NOT done: $env:ProgramFiles
    # has no bounded depth that is safe to guess, and a bound that is one level too shallow turns
    # a slow correct answer into a fast wrong one.
    $exe = if ($Name.EndsWith(".exe")) { $Name } else { "$Name.exe" }
    $roots = @(
        (Join-Path $Root "native"),
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($searchRoot in $roots) {
        $found = Get-ChildItem -Path $searchRoot -Recurse -File -Filter $exe -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function New-CmdWrapper {
    param(
        [string]$Name,
        [string]$Target
    )
    if (-not $Target) { return $false }
    $wrapper = Join-Path $Root "native\bin\$Name.cmd"
    if ($DryRun) {
        Write-Info "[DRY-RUN] wrapper $Name -> $Target"
        return $true
    }
    # New-ShimBody, NOT the here-string that used to be here. A here-string's line endings are a
    # property of the CHECKOUT, not of this code: the repo has core.autocrlf=true and no
    # .gitattributes, so a clone that handed this file LF would have emitted every one of this
    # build's wrappers - 26 of them, counted from a -DryRun on 2026-09-11 - with a lone LF, and
    # every reader anchors its regex on $. The smoke test's stale-shim check would then have
    # reported them as zero stale AND zero present. lib\ShimFormat.ps1 carried that rule in writing
    # while this file, one of the writers it was created for, broke it.
    #
    # -NoNewline is load-bearing: New-ShimBody's last two bytes are already CRLF, and Set-Content's
    # default would append a second terminator.
    #
    # THE EMITTED BYTES ARE UNCHANGED, measured 2026-09-11 by running the old body out of a CRLF
    # file and out of an LF file and diffing both against this one:
    #
    #   target C:\x\y.exe                 new 28 B | CRLF checkout old 28 B, IDENTICAL | LF old 27 B
    #   target C:\Program Files\...\7z.exe new 47 B | CRLF checkout old 47 B, IDENTICAL | LF old 46 B
    #
    # So this is a no-op on a correctly-checked-out tree - which is the point. The one byte the LF
    # column loses is the CR, and 28 B is what the byte-exact test in tests\Invoke-InstallerTests.ps1
    # pins. The difference is no longer reachable: the bytes now come from the code.
    Set-Content -Path $wrapper -Value (New-ShimBody -Target $Target) -Encoding ASCII -NoNewline
    return $true
}

function Get-Download {
    param(
        [string]$Url,
        [string]$OutFile,
        [long]$MinimumBytes = 1,
        [string]$Sha256 = ""
    )
    if (Test-Path -LiteralPath $OutFile) {
        $validSize = (Get-Item -LiteralPath $OutFile).Length -ge $MinimumBytes
        $validHash = (-not $Sha256) -or ((Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ieq $Sha256)
        if ($validSize -and $validHash) { return }
        Remove-Item -LiteralPath $OutFile -Force
    }

    $aria = Find-Executable -Name "aria2c"
    if ($aria) {
        # --disable-ipv6=true is NOT optional on this class of host, and it is the whole reason
        # tessdata has been half-installed here for weeks. aria2 resolves AAAA first and, with no
        # working IPv6 route, dies on every URL with:
        #
        #   Exception: [AbstractCommand.cc:312] errorCode=1 Network problem has occurred.
        #   cause:A socket operation was attempted to an unreachable network.
        #
        # Measured 2026-09-11 against tessdata_fast/osd.traineddata: plain aria2c returned 0 B and
        # ERR; the identical command plus --disable-ipv6=true returned 10,562,727 B, the exact
        # expected size. The same URL answered HTTP 200 to Invoke-WebRequest throughout, so this
        # never looked like a network outage from anywhere except aria2. That is why the symptom
        # reached us as "download failed or was unexpectedly small" on all 11 languages: the size
        # check is downstream of a transport that never connected.
        #
        # Forcing IPv4 costs nothing here - every URL this function fetches is dual-stack - and a
        # host WITH working IPv6 is unaffected, because A records resolve for all of them too.
        & $aria --disable-ipv6=true --allow-overwrite=true --auto-file-renaming=false --max-tries=3 --dir (Split-Path $OutFile) --out (Split-Path $OutFile -Leaf) $Url
    } else {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        } catch {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
            if (-not $curl) { throw }
            & $curl.Source -L --retry 3 --fail -o $OutFile $Url
        }
    }

    if (-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -lt $MinimumBytes) {
        # Delete the corpse BEFORE throwing. The SHA-256 branch below always cleaned up after
        # itself; this one did not, and aria2c leaves a partial file behind on a truncated
        # transfer. The short file then survived to satisfy the `if (Test-Path $out)
        # { continue }` fast-path that used to guard Install-Tessdata, so the "rerun to
        # retry" advice was false for that language forever - measured on this box, 2 of the
        # 11 declared OCR languages had usable data.
        #
        # -ErrorAction SilentlyContinue is load-bearing, not decoration: the first disjunct
        # of the condition above is "the file does not exist", and a Remove-Item that throws
        # under $ErrorActionPreference='Stop' would replace the real message with its own.
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        throw "download failed or was unexpectedly small: $Url"
    }
    if ($Sha256 -and (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ine $Sha256) {
        Remove-Item -LiteralPath $OutFile -Force
        throw "SHA-256 verification failed: $Url"
    }
}

function Install-NativeTools {
    foreach ($pkg in $NativePackages) {
        $machineScope = $pkg.ContainsKey("machineScope") -and $pkg.machineScope
        # Captured and type-checked rather than tested inline. `if (-not (Install-WingetPackage
        # ...))` READS like a guard, which is exactly why the leak below it went unnoticed for
        # so long: once native output rode along in the return value the test became
        # `-not <array>`, which is $false, and the throw never ran. A leak is a DIFFERENT
        # defect from a failed install and has to be reported as one - otherwise the next
        # person who adds an unredirected native call gets the silent version back, and the
        # symptom is a green build with nothing installed.
        $ok = Install-WingetPackage -Id $pkg.id -MachineScope:$machineScope
        if ($ok -isnot [bool]) {
            $shape = if ($null -eq $ok) { "nothing" } else { "{0}, {1} element(s)" -f $ok.GetType().Name, @($ok).Count }
            throw ("Install-WingetPackage returned $shape for $($pkg.id) instead of a bool: " +
                   "native output leaked into the return value, which silences the failure check below.")
        }
        if (-not $ok) {
            throw "required native package failed to install: $($pkg.id)"
        }
        foreach ($command in $pkg.commands) {
            $target = Find-Executable -Name $command -WingetId $pkg.id
            if ($target) {
                New-CmdWrapper -Name $command -Target $target | Out-Null
                Write-Ok "$command -> $target"
            } else {
                Write-Warn "could not locate command after install: $command"
            }
        }
    }
    Install-Ghostscript
}

function Install-Ghostscript {
    $allFound = $true
    foreach ($command in @("gswin64c", "gswin64")) {
        $target = Find-Executable -Name $command
        if ($target) {
            New-CmdWrapper -Name $command -Target $target | Out-Null
            Write-Ok "$command -> $target"
            continue
        }
        $allFound = $false
    }
    if ($allFound) { return }

    $sevenZip = Find-Executable -Name "7z"
    if (-not $sevenZip) {
        Write-Warn "7z not available; skipping Ghostscript extraction"
        return
    }
    $url = "https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10071/gs10071w64.exe"
    $download = Join-Path $Root "downloads\gs10071w64.exe"
    $dest = Join-Path $Root "native\ghostscript"
    if ($DryRun) {
        Write-Info "[DRY-RUN] download/extract Ghostscript"
        return
    }
    Get-Download -Url $url -OutFile $download -MinimumBytes 40MB `
        -Sha256 "3A4C28D0AAC47AA7CCCD35A5932C55110376E9DBD966898DDE388B7FABA444A4"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    # Captured, not `| Out-Null`: same pipe-promotes-stderr trap as the uv call in Get-Python311.
    # 7z reports "WARNINGS:" and per-file diagnostics on stderr while still extracting and
    # exiting 0, so the old shape could have failed the build on a successful extraction.
    $sevenZipRun = Invoke-NativeCapture -Exe $sevenZip -Arguments @("x", $download, "-o$dest", "-y")
    if ($sevenZipRun.ExitCode -ne 0) {
        foreach ($line in $sevenZipRun.Output) { Write-Host "    $line" -ForegroundColor DarkGray }
        Write-Warn "7z exited $($sevenZipRun.ExitCode) extracting Ghostscript - checking for the binaries anyway"
    }
    foreach ($command in @("gswin64c", "gswin64")) {
        $target = Find-Executable -Name $command
        if ($target) {
            New-CmdWrapper -Name $command -Target $target | Out-Null
            Write-Ok "$command -> $target"
        } else {
            Write-Warn "Ghostscript extracted, but $command was not found"
        }
    }
}

function Install-Tessdata {
    $langs = @("eng", "osd", "spa", "fra", "deu", "ita", "por", "jpn", "chi_sim", "chi_tra", "kor")
    $dest = Join-Path $Root "native\tesseract\tessdata"
    Ensure-Directory $dest
    $failed = @()
    foreach ($lang in $langs) {
        $out = Join-Path $dest "$lang.traineddata"
        if ($DryRun) {
            Write-Info "[DRY-RUN] download tessdata $lang"
            continue
        }
        $url = "https://github.com/tesseract-ocr/tessdata_fast/raw/main/$lang.traineddata"
        # No `if (Test-Path $out) { continue }` here. That fast-path skipped Get-Download
        # entirely, and with it Get-Download's own size check - so a zero-byte or partial
        # .traineddata was PERMANENT and every rerun found nothing to do. The existence
        # fast-path belongs in Get-Download, which returns immediately when the file already
        # passes its size and hash checks; the only cost of dropping the guard here is one
        # Get-Item per language.
        #
        # OCR language data: a transient download failure for one language must not
        # abort the whole toolbox build. Best-effort per language.
        try { Get-Download -Url $url -OutFile $out -MinimumBytes 100KB }
        catch { Write-Warn "tessdata '$lang' download failed (non-fatal): $($_.Exception.Message)"; $failed += $lang }
    }
    if ($failed.Count) { Write-Warn "tessdata not installed (rerun to retry): $($failed -join ', ')" }
}

function Assert-NodeCaBundleSane {
    # A NODE_EXTRA_CA_CERTS pointing at a file that does not exist is worse than not setting it:
    # Node emits "Warning: Ignoring extra certs from <path>, load failed" on STDERR for every
    # process that loads TLS, and under this file's $ErrorActionPreference = 'Stop' that warning
    # is a terminating error. Measured 2026-09-11: it failed the Playwright phase of this very
    # script, on a machine where the variable pointed into the toolbox tree the script was in the
    # middle of rebuilding.
    #
    # The ordering is the real defect and it is NOT fixable here: the bundle is written by
    # bootstrap.ps1 (Set-NodeSystemCaBundle), which runs AFTER this builder, so on any box whose
    # toolbox was deleted the variable necessarily dangles for the whole of this run. Recorded in
    # BACKLOG. What this function does is refuse to let a stale pointer fail the build: the
    # variable is cleared FOR THIS PROCESS ONLY, so the persisted user value is untouched and
    # bootstrap still rewrites both the file and the variable afterwards.
    $pem = $env:NODE_EXTRA_CA_CERTS
    if (-not $pem) { return }
    if (Test-Path -LiteralPath $pem) { return }
    Write-Warn "NODE_EXTRA_CA_CERTS points at a missing file ($pem) - unsetting it for this process only"
    Write-Info "bootstrap.ps1 rewrites the bundle and the variable; the persisted value is unchanged"
    $env:NODE_EXTRA_CA_CERTS = $null
}

function Install-PlaywrightBrowsers {
    param([string]$Python)
    if ($SkipPlaywrightBrowsers) {
        Write-Warn "skipping Playwright browser install"
        return
    }
    Assert-NodeCaBundleSane
    Invoke-Checked "install Playwright browsers" {
        & $Python -m playwright install chromium firefox webkit
    }
}

function Install-Sysinternals {
    $dest    = Join-Path $Root "sysinternals"
    $staging = Join-Path $Root "downloads\sysinternals-staging"
    Ensure-Directory $dest
    $zip = Join-Path $Root "downloads\SysinternalsSuite.zip"
    if ($DryRun) {
        Write-Info "[DRY-RUN] download + verify Sysinternals, accept EULAs"
        return
    }
    # Best-effort: the Sysinternals CDN can be flaky or blocked on some networks. A
    # failed download or signature check must not abort the whole toolbox build -
    # warn and skip (rerun to retry).
    #
    # Everything is unpacked into a STAGING directory and every executable is
    # verified there, so nothing unverified is ever visible under $dest. The old
    # shape expanded ~151 executables straight into $dest and then checked the
    # Authenticode signature of exactly ONE of them (sigcheck64.exe); on failure it
    # warned and returned without deleting anything. The binaries stayed, so
    # Run-Smoke's `Test-Path sysinternals\sigcheck64.exe` gate went true and ran the
    # readiness smoke against unverified files - and passed. The build reported a
    # verification it had never done on 150 of the 151 files.
    try {
        Get-Download -Url "https://download.sysinternals.com/files/SysinternalsSuite.zip" -OutFile $zip -MinimumBytes 100MB
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Expand-Archive -Path $zip -DestinationPath $staging -Force

        $staged = @(Get-ChildItem -LiteralPath $staging -Filter "*.exe" -File -ErrorAction SilentlyContinue)
        if ($staged.Count -eq 0) { throw "archive expanded to no executables" }
        # EVERY executable, not a sample. A tampered or corrupt file anywhere in the
        # suite is exactly what a one-file check waves through, and these are tools
        # people run elevated against a compromised machine.
        $bad = @($staged | Where-Object { (Get-AuthenticodeSignature -LiteralPath $_.FullName).Status -ne "Valid" })
        if ($bad.Count) {
            throw ("Authenticode verification failed for {0} of {1} executables ({2}{3})" -f
                   $bad.Count, $staged.Count,
                   (($bad | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', '),
                   $(if ($bad.Count -gt 5) { ", ..." } else { "" }))
        }
        # The downstream gate in Run-Smoke is Test-Path on this one file, so if the
        # suite ever stops shipping it the gate would silently skip forever.
        if (-not (Test-Path -LiteralPath (Join-Path $staging "sigcheck64.exe"))) {
            throw "sigcheck64.exe is not in the suite (Run-Smoke gates the readiness smoke on it)"
        }

        # Only verified files reach $dest. Rename-into-place on the same volume, so
        # there is no window in which $dest holds a half-copied suite.
        Remove-Item -LiteralPath $dest -Recurse -Force
        Move-Item -LiteralPath $staging -Destination $dest -Force
    } catch {
        # Leave nothing half-verified behind. If the move itself failed, $dest may be
        # gone or partial; either way the gate must read "absent" rather than run the
        # readiness smoke against whatever survived.
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath (Join-Path $dest "sigcheck64.exe"))) {
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Warn "Sysinternals unavailable (non-fatal): $($_.Exception.Message). Rerun to retry."
        return
    }
    Write-Ok ("Sysinternals: {0} executables, all Authenticode-valid" -f $staged.Count)

    New-Item -Path "HKCU:\Software\Sysinternals" -Force | Out-Null
    New-ItemProperty -Path "HKCU:\Software\Sysinternals" -Name "EulaAccepted" -Value 1 -PropertyType DWord -Force | Out-Null
    # Reuse the verified set: the registry keys are named after the file stems, which
    # the move did not change, so re-enumerating $dest would only re-read the disk.
    foreach ($exe in $staged) {
        $stems = @(
            $exe.BaseName,
            ($exe.BaseName -replace "64a?$", "")
        ) | Select-Object -Unique
        foreach ($stem in $stems) {
            if (-not $stem) { continue }
            $key = "HKCU:\Software\Sysinternals\$stem"
            New-Item -Path $key -Force | Out-Null
            New-ItemProperty -Path $key -Name "EulaAccepted" -Value 1 -PropertyType DWord -Force | Out-Null
        }
    }
}

function Write-ActivationHelpers {
    $activatePs1 = Join-Path $Root "scripts\Activate-CodexToolbox.ps1"
    $activateCmd = Join-Path $Root "scripts\activate-toolbox.cmd"
    $nativeBin = Join-Path $Root "native\bin"
    $venvScripts = Join-Path $Root "python\.venv\Scripts"
    $tessdata = Join-Path $Root "native\tesseract\tessdata"
    if ($DryRun) {
        Write-Info "[DRY-RUN] write activation helpers"
        return
    }
@"
`$env:CODEX_TOOLBOX = '$Root'
`$env:TESSDATA_PREFIX = '$tessdata'
`$env:PATH = '$nativeBin;$venvScripts;' + `$env:PATH
Write-Host "Codex toolbox activated: `$env:CODEX_TOOLBOX"
"@ | Set-Content -Path $activatePs1 -Encoding ASCII

@"
@echo off
set "CODEX_TOOLBOX=$Root"
set "TESSDATA_PREFIX=$tessdata"
set "PATH=$nativeBin;$venvScripts;%PATH%"
echo Codex toolbox activated: %CODEX_TOOLBOX%
"@ | Set-Content -Path $activateCmd -Encoding ASCII
}

function Write-SmokeScripts {
    $scriptsDir = Join-Path $Root "scripts"
    if ($DryRun) {
        Write-Info "[DRY-RUN] write smoke scripts"
        return
    }

@'
import json, tempfile
from pathlib import Path

failures = []
workdir = Path(tempfile.mkdtemp(prefix="codex-toolbox-py-"))

def check(name, fn):
    try:
        fn()
    except Exception as exc:
        failures.append({"name": name, "error": repr(exc)})

def imports():
    import docx, openpyxl, pandas, PIL, pypdf, fitz, pdfplumber, reportlab
    import pytesseract, bs4, markdown, requests, rich, typer, yaml

def files():
    from docx import Document
    from openpyxl import Workbook
    from PIL import Image
    from reportlab.pdfgen import canvas
    d = Document(); d.add_paragraph("ok"); d.save(workdir / "ok.docx")
    wb = Workbook(); wb.active["A1"] = "ok"; wb.save(workdir / "ok.xlsx")
    Image.new("RGB", (16, 16), "white").save(workdir / "ok.png")
    c = canvas.Canvas(str(workdir / "ok.pdf")); c.drawString(10, 10, "ok"); c.save()

check("imports", imports)
check("files", files)
result = {"failures": failures, "failure_count": len(failures), "workdir": str(workdir)}
print(json.dumps(result, indent=2))
raise SystemExit(1 if failures else 0)
'@ | Set-Content -Path (Join-Path $scriptsDir "python_tooling_smoke_test.py") -Encoding ASCII

@'
import json, os, subprocess
from pathlib import Path

root = Path(os.environ.get("CODEX_TOOLBOX", Path.home() / "AppData/Local/DevToolbox"))
out = root / "notes" / "smoke" / "native_tooling_smoke.json"
bin_dir = root / "native" / "bin"
env = os.environ.copy()
env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
env["CODEX_TOOLBOX"] = str(root)
env["TESSDATA_PREFIX"] = str(root / "native" / "tesseract" / "tessdata")
commands = {
    "uv": ["uv", "--version"], "pandoc": ["pandoc", "--version"], "soffice": ["soffice", "--version"],
    "tesseract": ["tesseract", "--version"], "pdfinfo": ["pdfinfo", "-v"], "pdftoppm": ["pdftoppm", "-v"],
    "gswin64c": ["gswin64c", "-version"], "qpdf": ["qpdf", "--version"], "magick": ["magick", "-version"],
    "ffmpeg": ["ffmpeg", "-version"], "ffprobe": ["ffprobe", "-version"], "7z": ["7z"],
    "rg": ["rg", "--version"], "fd": ["fd", "--version"], "jq": ["jq", "--version"],
    "yq": ["yq", "--version"], "exiftool": ["exiftool", "-ver"], "aria2c": ["aria2c", "--version"],
    "rclone": ["rclone", "version"], "node": ["node", "--version"], "npm": ["npm", "--version"],
    "npx": ["npx", "--version"], "corepack": ["corepack", "--version"], "duckdb": ["duckdb", "--version"],
}
results, failures, warnings = {}, [], []
# Cold-start-heavy GUI apps (LibreOffice, ImageMagick) need a longer budget than CLI tools.
slow = {"soffice": 120, "magick": 120}
for name, cmd in commands.items():
    wrapper = bin_dir / f"{cmd[0]}.cmd"
    if wrapper.exists():
        cmd = [str(wrapper), *cmd[1:]]
    try:
        completed = subprocess.run(cmd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=slow.get(name, 30))
        results[name] = {"returncode": completed.returncode, "output": completed.stdout[:1000]}
        if completed.returncode not in (0, 1):
            failures.append({"name": name, "returncode": completed.returncode})
    except subprocess.TimeoutExpired as exc:
        # A version check timing out is not a build failure - the tool is installed.
        warnings.append({"name": name, "error": repr(exc)})
    except Exception as exc:
        failures.append({"name": name, "error": repr(exc)})
result = {"results": results, "failures": failures, "warnings": warnings, "warning_count": len(warnings), "failure_count": len(failures)}
out.write_text(json.dumps(result, indent=2), encoding="utf-8")
print(json.dumps(result, indent=2))
raise SystemExit(1 if failures else 0)
'@ | Set-Content -Path (Join-Path $scriptsDir "native_tooling_smoke_test.py") -Encoding ASCII

@'
import json
from pathlib import Path
import os

root = Path(os.environ.get("CODEX_TOOLBOX", Path.home() / "AppData/Local/DevToolbox"))
out = root / "notes" / "smoke" / "heavy_tooling_smoke.json"
failures, data = [], {}

def try_import(name):
    try:
        mod = __import__(name)
        data[name] = getattr(mod, "__version__", "imported")
    except Exception as exc:
        failures.append({"name": name, "error": repr(exc)})

for name in ["scipy", "skimage", "onnxruntime", "rembg", "basicsr", "gfpgan", "facexlib", "torch", "torchvision"]:
    try_import(name)
try:
    import torch
    data["torch_cuda_available"] = torch.cuda.is_available()
    data["torch_cuda_device"] = torch.cuda.get_device_name(0) if torch.cuda.is_available() else None
except Exception as exc:
    failures.append({"name": "torch_cuda", "error": repr(exc)})
try:
    import onnxruntime as ort
    data["onnxruntime_providers"] = ort.get_available_providers()
except Exception as exc:
    failures.append({"name": "onnxruntime_providers", "error": repr(exc)})
result = {"data": data, "failures": failures, "failure_count": len(failures)}
out.write_text(json.dumps(result, indent=2), encoding="utf-8")
print(json.dumps(result, indent=2))
raise SystemExit(1 if failures else 0)
'@ | Set-Content -Path (Join-Path $scriptsDir "heavy_tooling_smoke_test.py") -Encoding ASCII

@'
import json, os, subprocess
from pathlib import Path

root = Path(os.environ.get("CODEX_TOOLBOX", Path.home() / "AppData/Local/DevToolbox"))
sysroot = root / "sysinternals"
results, failures, warnings = {}, [], []
# Readiness = the suite is present (and signature-verified at build time). Only
# spot-run tools that print usage and exit fast on a bare flag; handle64 with
# -nobanner ENUMERATES every open handle (slow, not a readiness probe), so it is
# existence-checked only. A version/usage probe timing out is a warning (likely a
# first-run AV scan), not a build failure - mirrors the native tooling smoke.
probe = {"sigcheck64.exe": ["-nobanner"], "streams64.exe": ["-nobanner"], "du64.exe": ["-nobanner"]}
for name in ["sigcheck64.exe", "handle64.exe", "streams64.exe", "du64.exe"]:
    exe = sysroot / name
    if not exe.exists():
        failures.append({"name": name, "error": "missing"})
        continue
    if name not in probe:
        results[name] = {"exists": True, "note": "existence-checked (enumeration tool, not run)"}
        continue
    try:
        completed = subprocess.run([str(exe), *probe[name]], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
        results[name] = {"returncode": completed.returncode, "output": completed.stdout[:500]}
    except subprocess.TimeoutExpired as exc:
        warnings.append({"name": name, "error": repr(exc)})
    except Exception as exc:
        failures.append({"name": name, "error": repr(exc)})
result = {"executable_count": len(list(sysroot.glob("*.exe"))), "results": results, "failures": failures, "warnings": warnings, "warning_count": len(warnings), "failure_count": len(failures)}
print(json.dumps(result, indent=2))
raise SystemExit(1 if failures else 0)
'@ | Set-Content -Path (Join-Path $scriptsDir "sysinternals_readiness_test.py") -Encoding ASCII

@'
import asyncio, json, os
from pathlib import Path
from playwright.async_api import async_playwright

root = Path(os.environ.get("CODEX_TOOLBOX", Path.home() / "AppData/Local/DevToolbox"))
out = root / "notes" / "smoke" / "playwright_all_browsers.json"

async def main():
    results, failures = {}, []
    async with async_playwright() as p:
        for name in ("chromium", "firefox", "webkit"):
            browser = None
            try:
                browser = await getattr(p, name).launch(headless=True)
                page = await browser.new_page(viewport={"width": 640, "height": 480})
                await page.set_content("<h1>DevToolbox browser smoke</h1>")
                screenshot = root / "notes" / "smoke" / f"playwright-{name}.png"
                await page.screenshot(path=str(screenshot))
                results[name] = {"ok": True, "screenshot": str(screenshot)}
            except Exception as exc:
                failures.append({"name": name, "error": repr(exc)})
            finally:
                if browser is not None:
                    await browser.close()
    result = {"results": results, "failures": failures, "failure_count": len(failures)}
    out.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    raise SystemExit(1 if failures else 0)

asyncio.run(main())
'@ | Set-Content -Path (Join-Path $scriptsDir "playwright_all_browsers_probe.py") -Encoding ASCII
}

function Write-Manifest {
    param([string]$Python)
    if ($DryRun) {
        Write-Info "[DRY-RUN] write toolbox manifest"
        return
    }
    $commands = [ordered]@{}
    foreach ($wrapper in Get-ChildItem -Path (Join-Path $Root "native\bin") -Filter "*.cmd" -File -ErrorAction SilentlyContinue) {
        $name = [IO.Path]::GetFileNameWithoutExtension($wrapper.Name)
        # Get-ShimTarget from lib\ShimFormat.ps1 - the same reader every other file in the repo
        # uses - instead of the private Get-WrapperTarget that used to live beside New-CmdWrapper.
        # A writer and a reader that drift apart is the failure this manifest would report as
        # "path: null, exists: false" for a wrapper that was perfectly fine. It takes LINES rather
        # than a path because modules\security.ps1 writes a THREE-line Ghidra wrapper, and the
        # reader has to scan for the first matching line rather than index a fixed one.
        $target = Get-ShimTarget -Lines @(Get-Content -LiteralPath $wrapper.FullName -ErrorAction SilentlyContinue)
        $commands[$name] = [ordered]@{
            path = $target
            wrapper = $wrapper.FullName
            exists = [bool]($target -and (Test-Path -LiteralPath $target))
        }
    }
    # MEASURED from pyvenv.cfg rather than asserted from whatever Get-Python311 decided.
    # Get-Python311 is called only on the run that creates the venv; on every re-run
    # Ensure-PythonVenv returns early and $Python above is just the venv's own python.exe,
    # which says nothing about its base. Whether the toolbox is sitting on a
    # compliance-visible interpreter has to stay visible for as long as the venv exists,
    # including on the runs that never made the choice.
    $venvPath = Join-Path $Root "python\.venv"
    $baseInterpreter = Get-VenvBaseInterpreter -VenvPath $venvPath
    $manifest = [ordered]@{
        schema_version = $ToolboxSchemaVersion
        created_at = (Get-Date).ToString("o")
        root = $Root
        python = [ordered]@{
            executable = $Python
            venv = $venvPath
            base_interpreter = $baseInterpreter
            base_interpreter_uv_managed = (Test-UvManagedPath -Path $baseInterpreter)
            requirements_core = (Join-Path $Root "python\requirements-core.txt")
            requirements_ml = (Join-Path $Root "python\requirements-ml.txt")
        }
        native = [ordered]@{
            root = (Join-Path $Root "native")
            bin = (Join-Path $Root "native\bin")
            commands = $commands
        }
        tessdata_prefix = (Join-Path $Root "native\tesseract\tessdata")
        sysinternals = [ordered]@{
            root = (Join-Path $Root "sysinternals")
            executable_count = @(Get-ChildItem -Path (Join-Path $Root "sysinternals") -Filter "*.exe" -File -ErrorAction SilentlyContinue).Count
        }
        activation_helpers = [ordered]@{
            cmd = (Join-Path $Root "scripts\activate-toolbox.cmd")
            powershell = (Join-Path $Root "scripts\Activate-CodexToolbox.ps1")
        }
        playwright = [ordered]@{
            cache = (Join-Path $env:LOCALAPPDATA "ms-playwright")
        }
        caveats = @(
            "Generated by scripts/build-devtoolbox.ps1",
            "Use scripts smoke tests for current validation status."
        )
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Root "toolbox-manifest.json") -Encoding UTF8
}

function Run-Smoke {
    param([string]$Python)
    if ($DryRun) { return }
    $env:CODEX_TOOLBOX = $Root
    $env:TESSDATA_PREFIX = Join-Path $Root "native\tesseract\tessdata"
    Sync-EnvPath
    Invoke-Checked "run pip dependency check" { & $Python -m pip check }
    Invoke-Checked "run Python toolbox smoke" { & $Python (Join-Path $Root "scripts\python_tooling_smoke_test.py") }
    Invoke-Checked "run native toolbox smoke" { & $Python (Join-Path $Root "scripts\native_tooling_smoke_test.py") }
    if (Test-Path (Join-Path $Root "sysinternals\sigcheck64.exe")) {
        Invoke-Checked "run Sysinternals readiness smoke" { & $Python (Join-Path $Root "scripts\sysinternals_readiness_test.py") }
    } else {
        Write-Warn "Sysinternals not present - skipping readiness smoke (rerun to fetch it)"
    }
    if (-not $SkipPlaywrightBrowsers) {
        Invoke-Checked "run Playwright browser smoke" { & $Python (Join-Path $Root "scripts\playwright_all_browsers_probe.py") }
    }
    if (-not $SkipHeavy) {
        Invoke-Checked "run heavy toolbox smoke" { & $Python (Join-Path $Root "scripts\heavy_tooling_smoke_test.py") }
    }
}

if (-not $DryRun) { Assert-Prerequisites }

Write-Step "create toolbox directories"
foreach ($dir in @(
    $Root,
    (Join-Path $Root "python"),
    (Join-Path $Root "native"),
    (Join-Path $Root "native\bin"),
    (Join-Path $Root "sysinternals"),
    (Join-Path $Root "scripts"),
    (Join-Path $Root "notes"),
    (Join-Path $Root "notes\smoke"),
    (Join-Path $Root "downloads")
)) {
    Ensure-Directory $dir
}

Write-Step "python"
$python = Ensure-PythonVenv
Write-Requirements
Install-PythonPackages -Python $python

Write-Step "native tools"
Install-NativeTools
Install-Tessdata

Write-Step "playwright"
Install-PlaywrightBrowsers -Python $python

Write-Step "sysinternals"
Install-Sysinternals

Write-Step "activation and smoke scripts"
Write-ActivationHelpers
Write-SmokeScripts

Write-Step "manifest"
Write-Manifest -Python $python

Write-Step "smoke"
Run-Smoke -Python $python

Write-Step "done"
Write-Ok "DevToolbox ready: $Root"
