#Requires -Version 5.1
<#
Provision Ghidra + a portable JDK 21 into the DevToolbox, without admin.

Ghidra has no winget package - it ships as a GitHub release ZIP and needs a
JDK 21+. This helper fetches both (Ghidra from GitHub, an Eclipse Temurin 21 JDK
from Adoptium) and extracts them into <toolbox>\native. Nothing is installed
machine-wide or registered in Add/Remove Programs, and nothing is put on the
system PATH. Afterwards run '.\bootstrap.ps1 -Only security': modules/security.ps1
detects both, wraps ghidraRun/analyzeHeadless onto the toolbox PATH, and points
them at the JDK via JAVA_HOME (for Ghidra only).

  .\scripts\install-ghidra.ps1              # fetch Ghidra + JDK if missing
  .\scripts\install-ghidra.ps1 -SkipJdk     # Ghidra only (you already have a JDK 21+)
#>
[CmdletBinding()]
param(
    [string]$Root = $(if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }),
    [switch]$SkipGhidra,
    [switch]$SkipJdk,
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$nativeArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($nativeArch -ne "AMD64") { throw "The portable Ghidra/JDK helper currently supports x64 Windows only (detected: $nativeArch)." }

function Write-Info { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "OK $Message" -ForegroundColor Green }

$native = Join-Path $Root "native"
$dl     = Join-Path $Root "downloads"
if (-not $DryRun) {
    New-Item -ItemType Directory -Path $native -Force | Out-Null
    New-Item -ItemType Directory -Path $dl -Force | Out-Null
}
$sevenZip = @(
    (Join-Path $Root "native\bin\7z.cmd"),
    (Join-Path $env:ProgramFiles "7-Zip\7z.exe")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

function Expand-ZipTo {
    param([string]$Zip, [string]$Dest)
    if ($sevenZip) { & $sevenZip x $Zip "-o$Dest" -y | Out-Null }
    else { Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force }
}

function Get-Download {
    param([string]$Url, [string]$OutFile, [string]$Sha256, [long]$MinimumBytes = 40MB)
    if ($DryRun) { Write-Info "[DRY-RUN] download $Url"; return }
    if (Test-Path -LiteralPath $OutFile) {
        $validSize = (Get-Item -LiteralPath $OutFile).Length -ge $MinimumBytes
        $validHash = (-not $Sha256) -or ((Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ieq $Sha256)
        if ($validSize -and $validHash) { return }
        Remove-Item -LiteralPath $OutFile -Force
    }
    $aria = Join-Path $Root "native\bin\aria2c.cmd"
    if (Test-Path -LiteralPath $aria) {
        & $aria --allow-overwrite=true --auto-file-renaming=false --max-tries=3 --dir (Split-Path $OutFile) --out (Split-Path $OutFile -Leaf) $Url
    } else {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        } catch {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            & curl.exe -L --retry 3 --fail -o $OutFile $Url
        }
    }
    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -lt $MinimumBytes) {
        throw "download failed or was unexpectedly small: $Url"
    }
    if ($Sha256 -and (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ine $Sha256) {
        Remove-Item -LiteralPath $OutFile -Force
        throw "SHA-256 verification failed: $Url"
    }
}

function Get-Json {
    param([string]$Url)
    $headers = @{ "User-Agent" = "scripts-utilities" }
    $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }
    if ($token -and $Url -like "https://api.github.com/*") { $headers.Authorization = "Bearer $token" }
    try {
        return Invoke-RestMethod -Uri $Url -Headers $headers -UseBasicParsing
    } catch {
        $python = Join-Path $Root "python\.venv\Scripts\python.exe"
        if (-not (Test-Path $python)) { throw }
        $tokenArg = [string]$token
        $json = & $python -c "import requests,sys; h={'User-Agent':'scripts-utilities'}; h.update({'Authorization':'Bearer '+sys.argv[2]} if sys.argv[2] else {}); r=requests.get(sys.argv[1],headers=h,timeout=60); r.raise_for_status(); print(r.text)" $Url $tokenArg
        if ($LASTEXITCODE -ne 0) { throw "JSON request failed: $Url" }
        return ($json | ConvertFrom-Json)
    }
}

if (-not $SkipGhidra) {
    $have = Get-ChildItem $native -Filter "ghidra_*" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "ghidraRun.bat") } | Select-Object -First 1
    if ($have) {
        Write-Ok "Ghidra already present: $($have.FullName)"
    } elseif ($DryRun) {
        Write-Info "[DRY-RUN] would resolve, verify, download, and extract the latest Ghidra release"
    } else {
        Write-Info "resolve latest Ghidra release"
        $rel   = Get-Json "https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest"
        $asset = $rel.assets | Where-Object { $_.name -like "ghidra_*_PUBLIC_*.zip" } | Select-Object -First 1
        if (-not $asset) { throw "no Ghidra *_PUBLIC_*.zip asset in the latest release" }
        $zip = Join-Path $dl $asset.name
        Write-Info "download $($asset.name) ($([int]($asset.size / 1MB)) MB)"
        $digest = if ($asset.digest -match '^sha256:(.+)$') { $Matches[1] } else { "" }
        if (-not $digest) { throw "latest Ghidra release does not publish a SHA-256 digest" }
        Get-Download -Url $asset.browser_download_url -OutFile $zip -Sha256 $digest -MinimumBytes 100MB
        if (-not $DryRun) {
            Expand-ZipTo $zip $native
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Write-Ok "Ghidra -> $native"
        }
    }
}

if (-not $SkipJdk) {
    $have = Get-ChildItem $native -Filter "jdk-*" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "bin\java.exe") } | Select-Object -First 1
    if ($have) {
        Write-Ok "JDK already present: $($have.FullName)"
    } elseif ($DryRun) {
        Write-Info "[DRY-RUN] would resolve, verify, download, and extract the latest Temurin JDK 21"
    } else {
        Write-Info "download Eclipse Temurin JDK 21 (portable)"
        $assets = Get-Json "https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse"
        $package = $assets | Select-Object -First 1 -ExpandProperty binary | Select-Object -ExpandProperty package
        if (-not $package.link -or -not $package.checksum) { throw "Adoptium API returned no JDK package/checksum" }
        $zip = Join-Path $dl $package.name
        Get-Download -Url $package.link -OutFile $zip -Sha256 $package.checksum -MinimumBytes 100MB
        if (-not $DryRun) {
            Expand-ZipTo $zip $native
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Write-Ok "JDK -> $native"
        }
    }
}

Write-Host ""
Write-Host "Next: .\bootstrap.ps1 -Only security   (detects + wires Ghidra/JDK onto the toolbox PATH)" -ForegroundColor White
