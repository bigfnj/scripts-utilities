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
    $machine = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $user = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = @(
        (Join-Path $Root "native\bin"),
        (Join-Path $Root "python\.venv\Scripts"),
        $machine,
        $user,
        $env:PATH
    ) -join ";"
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
        # Out-Null, not 2>&1: uncaptured output inside a function is concatenated into this
        # function's return value (the trap Invoke-Winget exists for), while redirecting uv's
        # stderr under 'Stop' would throw on its first progress line. A non-zero exit or a
        # stderr warning from uv (e.g. its version-link glitch on a first install) is
        # non-fatal here - the authoritative path comes from 'uv python find' below, whose
        # single stdout line is captured directly.
        & $uv python install 3.11 | Out-Null
        $managed = & $uv python find 3.11 | Select-Object -First 1
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
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = winget @WingetArgs 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
    } finally { $ErrorActionPreference = $prev }
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
            foreach ($packageDir in $packageDirs) {
                $found = Get-ChildItem -LiteralPath $packageDir.FullName -Recurse -File -Filter $exe -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($found) { return $found.FullName }
                $cmdName = if ($Name.EndsWith(".cmd")) { $Name } else { "$Name.cmd" }
                $found = Get-ChildItem -LiteralPath $packageDir.FullName -Recurse -File -Filter $cmdName -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($found) { return $found.FullName }
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
    @"
@echo off
"$Target" %*
"@ | Set-Content -Path $wrapper -Encoding ASCII
    return $true
}

function Get-WrapperTarget {
    param([string]$Wrapper)
    $line = Get-Content -LiteralPath $Wrapper -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^"([^"]+)" %\*$' } | Select-Object -First 1
    if ($line -and $line -match '^"([^"]+)" %\*$') { return $Matches[1] }
    return $null
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
        & $aria --allow-overwrite=true --auto-file-renaming=false --max-tries=3 --dir (Split-Path $OutFile) --out (Split-Path $OutFile -Leaf) $Url
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
    & $sevenZip x $download "-o$dest" -y | Out-Null
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

function Install-PlaywrightBrowsers {
    param([string]$Python)
    if ($SkipPlaywrightBrowsers) {
        Write-Warn "skipping Playwright browser install"
        return
    }
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
        $target = Get-WrapperTarget -Wrapper $wrapper.FullName
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
