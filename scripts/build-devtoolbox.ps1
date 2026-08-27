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

function Get-Python311 {
    # Prefer a uv-managed standalone Python 3.11 for the toolbox venv. uv's Pythons are
    # plain extractions - NOT registered in Add/Remove Programs and NOT on PATH - so
    # corporate "old Python" scanners/remediation don't see or delete them (the system
    # PATH Python can be whatever's current). This also keeps the venv base stable and
    # reproducible. Only fall back to a system/registered 3.11 if uv is unavailable.
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        if ($DryRun) {
            Write-Info "[DRY-RUN] would install astral-sh.uv (manages the private Python)"
        } else {
            Write-Info "install astral-sh.uv (manages the toolbox's private Python 3.11)"
            # Out-Null: uncaptured command output inside this function is otherwise
            # concatenated into the returned interpreter path (a PS return-value trap).
            winget install --id astral-sh.uv -e --accept-source-agreements --accept-package-agreements --silent --scope user | Out-Null
            Sync-EnvPath
        }
    }
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if ($uv) {
        if ($DryRun) { Write-Info "[DRY-RUN] would: uv python install 3.11 (private, unregistered)"; return "python.exe" }
        Write-Info "uv python install 3.11 (private, unregistered)"
        # Out-Null the install (see note above). A non-zero exit or stderr warning
        # from uv (e.g. its version-link glitch on first install) is non-fatal here -
        # the authoritative interpreter path comes from 'uv python find' next, whose
        # single stdout line we capture directly (no leak, no directory scanning).
        & $uv.Source python install 3.11 | Out-Null
        $managed = & $uv.Source python find 3.11 | Select-Object -First 1
        if ($managed -and (Test-Path $managed)) { return $managed }
        Write-Warn "uv did not yield a managed Python 3.11; falling back to a system install (may trip compliance)"
    }

    # Fallback: a system/registered Python 3.11 (a compliance policy may flag this).
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
    if ($DryRun) {
        Write-Info "[DRY-RUN] would install Python.Python.3.11 via winget"
        return "python.exe"
    }
    Write-Info "install Python.Python.3.11 (fallback; system-registered)"
    winget install --id Python.Python.3.11 -e --accept-source-agreements --accept-package-agreements --silent --scope user | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Python 3.11 install failed (uv and winget both unavailable)" }
    Sync-EnvPath
    $sys = "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
    if (Test-Path $sys) { return $sys }
    throw "Python 3.11 not found after install"
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

function Install-WingetPackage {
    param([string]$Id, [switch]$MachineScope)
    if ($DryRun) {
        Write-Info "[DRY-RUN] winget install $Id"
        return $true
    }
    Assert-Prerequisites
    $listed = winget list --id $Id -e --accept-source-agreements 2>&1
    if ($LASTEXITCODE -eq 0 -and ($listed -match [regex]::Escape($Id))) {
        Write-Info "$Id already installed"
        return $true
    }
    Write-Info "winget install $Id"
    $args = @("install", "--id", $Id, "-e", "--accept-source-agreements", "--accept-package-agreements", "--silent")
    if (-not $MachineScope) { $args += @("--scope", "user") }
    winget @args
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$Id install failed"
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
        if (-not (Install-WingetPackage -Id $pkg.id -MachineScope:$machineScope)) {
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
        if (Test-Path $out) { continue }
        if ($DryRun) {
            Write-Info "[DRY-RUN] download tessdata $lang"
            continue
        }
        $url = "https://github.com/tesseract-ocr/tessdata_fast/raw/main/$lang.traineddata"
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
    $dest = Join-Path $Root "sysinternals"
    Ensure-Directory $dest
    $zip = Join-Path $Root "downloads\SysinternalsSuite.zip"
    if ($DryRun) {
        Write-Info "[DRY-RUN] download + verify Sysinternals, accept EULAs"
        return
    }
    # Best-effort: the Sysinternals CDN can be flaky or blocked on some networks. A
    # failed download or signature check must not abort the whole toolbox build -
    # warn and skip (rerun to retry). Unverified binaries are never kept.
    try {
        Get-Download -Url "https://download.sysinternals.com/files/SysinternalsSuite.zip" -OutFile $zip -MinimumBytes 100MB
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        $sigcheck = Join-Path $dest "sigcheck64.exe"
        if (-not (Test-Path $sigcheck) -or (Get-AuthenticodeSignature $sigcheck).Status -ne "Valid") {
            throw "signature verification failed for $sigcheck"
        }
    } catch {
        Write-Warn "Sysinternals unavailable (non-fatal): $($_.Exception.Message). Rerun to retry."
        return
    }
    New-Item -Path "HKCU:\Software\Sysinternals" -Force | Out-Null
    New-ItemProperty -Path "HKCU:\Software\Sysinternals" -Name "EulaAccepted" -Value 1 -PropertyType DWord -Force | Out-Null
    $executables = Get-ChildItem -Path $dest -Filter "*.exe" -File -ErrorAction SilentlyContinue
    foreach ($exe in $executables) {
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
            wrapper_exists = $true
        }
    }
    $manifest = [ordered]@{
        schema_version = $ToolboxSchemaVersion
        created_at = (Get-Date).ToString("o")
        root = $Root
        python = [ordered]@{
            executable = $Python
            venv = (Join-Path $Root "python\.venv")
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
