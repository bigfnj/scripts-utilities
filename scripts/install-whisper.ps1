#Requires -Version 5.1
<#
Provision whisper.cpp (offline speech-to-text) into the DevToolbox, without admin.

whisper.cpp has no winget package - it ships as a GitHub release ZIP of Windows
x64 binaries, and needs a GGML model file (from Hugging Face). This helper fetches
both into <toolbox>\whisper: the CLI + its DLLs under \whisper\bin, and the model
under \whisper\models. Nothing is installed machine-wide, registered, or put on
PATH - the Remembrance module takes explicit paths to the exe and the model.

  .\scripts\install-whisper.ps1                     # fetch the CLI + ggml-base.en model if missing
  .\scripts\install-whisper.ps1 -Model ggml-small.en.bin   # a different model
  .\scripts\install-whisper.ps1 -SkipModel          # CLI only

At the end it prints the two paths to paste into Remembrance's options
(whisper-cli path + model file).
#>
[CmdletBinding()]
param(
    [string]$Root  = $(if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }),
    [string]$Model = "ggml-base.en.bin",
    [switch]$SkipBinary,
    [switch]$SkipModel,
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$nativeArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($nativeArch -ne "AMD64") { throw "The whisper.cpp helper supports x64 Windows only (detected: $nativeArch)." }

function Write-Info { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "OK $Message" -ForegroundColor Green }

$whisper = Join-Path $Root "whisper"
$bin     = Join-Path $whisper "bin"
$models  = Join-Path $whisper "models"
$dl      = Join-Path $Root "downloads"
if (-not $DryRun) {
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    New-Item -ItemType Directory -Path $models -Force | Out-Null
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
    param([string]$Url, [string]$OutFile, [string]$Sha256, [long]$MinimumBytes = 1MB)
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
        try { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing }
        catch {
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

# Hugging Face model files 302-redirect to an LFS CDN. aria2c mishandled that here (tried an unreachable
# route), so fetch models with curl forced to IPv4, following redirects, and authenticated with the HF token
# when one is present (the standard token store, or HF_TOKEN). The whisper.cpp models are public, so the token
# is optional, but it matches how everything else on this box reaches HF.
function Get-HFFile {
    param([string]$Url, [string]$OutFile, [long]$MinimumBytes = 1MB)
    if ($DryRun) { Write-Info "[DRY-RUN] download $Url"; return }
    if ((Test-Path -LiteralPath $OutFile) -and (Get-Item -LiteralPath $OutFile).Length -ge $MinimumBytes) { return }

    $tok = $env:HF_TOKEN
    if (-not $tok) {
        $tokenFile = Join-Path $env:USERPROFILE ".cache\huggingface\token"
        if (Test-Path -LiteralPath $tokenFile) { $tok = (Get-Content -Raw -LiteralPath $tokenFile).Trim() }
    }
    $curlArgs = @("-4", "-L", "--fail", "--retry", "3", "--connect-timeout", "20", "-o", $OutFile, $Url)
    if ($tok) { $curlArgs = @("-H", "Authorization: Bearer $tok") + $curlArgs }
    & curl.exe @curlArgs
    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -lt $MinimumBytes) {
        throw "download failed or was unexpectedly small: $Url"
    }
}

function Get-Json {
    param([string]$Url)
    $headers = @{ "User-Agent" = "scripts-utilities" }
    $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }
    if ($token -and $Url -like "https://api.github.com/*") { $headers.Authorization = "Bearer $token" }
    Invoke-RestMethod -Uri $Url -Headers $headers -UseBasicParsing
}

function Find-WhisperExe {
    $cli = Get-ChildItem -LiteralPath $bin -Recurse -Filter "whisper-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cli) { return $cli.FullName }
    $main = Get-ChildItem -LiteralPath $bin -Recurse -Filter "main.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($main) { return $main.FullName }
    return $null
}

# ---- 1. whisper.cpp Windows x64 binaries ----
if (-not $SkipBinary) {
    $exe = Find-WhisperExe
    if ($exe) {
        Write-Ok "whisper.cpp CLI already present: $exe"
    } elseif ($DryRun) {
        Write-Info "[DRY-RUN] would resolve + download the latest whisper.cpp whisper-bin-x64.zip"
    } else {
        Write-Info "resolve latest whisper.cpp release"
        $rel = Get-Json "https://api.github.com/repos/ggerganov/whisper.cpp/releases/latest"
        $asset = $rel.assets | Where-Object { $_.name -like "whisper-bin-x64.zip" } | Select-Object -First 1
        if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -like "*bin-x64*.zip" } | Select-Object -First 1 }
        if (-not $asset) { throw "no whisper-bin-x64.zip asset in the latest whisper.cpp release" }
        $zip = Join-Path $dl $asset.name
        Write-Info "download $($asset.name) ($([int]($asset.size / 1MB)) MB)"
        $digest = if ($asset.digest -match '^sha256:(.+)$') { $Matches[1] } else { "" }
        Get-Download -Url $asset.browser_download_url -OutFile $zip -Sha256 $digest -MinimumBytes 1MB
        Expand-ZipTo $zip $bin
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        $exe = Find-WhisperExe
        if (-not $exe) { throw "extracted the release but found no whisper-cli.exe / main.exe under $bin" }
        Write-Ok "whisper.cpp CLI -> $exe"
    }
}

# ---- 2. a GGML model (Hugging Face) ----
if (-not $SkipModel) {
    $modelPath = Join-Path $models $Model
    if (Test-Path -LiteralPath $modelPath) {
        Write-Ok "model already present: $modelPath"
    } elseif ($DryRun) {
        Write-Info "[DRY-RUN] would download $Model from Hugging Face"
    } else {
        $url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$Model"
        Write-Info "download $Model from Hugging Face"
        Get-HFFile -Url $url -OutFile $modelPath -MinimumBytes 20MB
        Write-Ok "model -> $modelPath"
    }
}

# ---- report the two paths for Remembrance ----
$finalExe   = Find-WhisperExe
$finalModel = Join-Path $models $Model
Write-Host ""
Write-Host "Remembrance options -> Transcription:" -ForegroundColor White
Write-Host ("  whisper-cli path : {0}" -f $(if ($finalExe) { $finalExe } else { "(not installed)" }))
Write-Host ("  model file       : {0}" -f $(if (Test-Path -LiteralPath $finalModel) { $finalModel } else { "(not installed)" }))
