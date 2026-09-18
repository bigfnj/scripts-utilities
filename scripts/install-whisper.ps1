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

function Invoke-Native {
    <#
        Run a native command with its output captured and its stderr survivable, returning the
        exit code beside the captured lines. Same shape and name as the wrapper in
        install-deletion-forensics.ps1; see build-devtoolbox.ps1's Invoke-NativeCapture for the
        measurement this is all based on.

        Under this file's $ErrorActionPreference = 'Stop', 5.1 promotes a native command's stderr
        to a TERMINATING NativeCommandError once PowerShell has redirected that stream - which an
        enclosing capture does for every command inside it, whether or not the call site itself
        redirects.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
    } finally { $ErrorActionPreference = $prev }
}

function Expand-ZipTo {
    param([string]$Zip, [string]$Dest)
    if ($sevenZip) {
        # The exit code was never read. 7z reports a partial extraction as exit 1 (WARNING) and a
        # refusal as 2, on stderr, so a truncated whisper.cpp archive produced a bin\ directory
        # missing the exe and the run continued to the model download as though it had one.
        $x = Invoke-Native -FilePath $sevenZip -Arguments @('x', $Zip, "-o$Dest", '-y')
        if ($x.ExitCode -ne 0) {
            foreach ($line in $x.Output) { Write-Host "    $line" -ForegroundColor DarkGray }
            throw "7z extraction failed (exit $($x.ExitCode)): $Zip -> $Dest"
        }
    }
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
    # THE DOWNLOADER'S OWN EXIT CODE, read and reported apart from the size/hash checks below.
    # Neither leg used to read it: a DNS, TLS or proxy failure leaves no file at all, and the
    # size check downstream then called that "download failed or was unexpectedly small" - which
    # sends the reader at disk space and mirrors when the fault was the network. MEASURED
    # 2026-09-17 against an unresolvable host, both legs: aria2c exits 19 and curl exits 6, and
    # the file is ABSENT rather than short. Neither code means truncation, so the two conditions
    # throw different messages and each one names the exit code it actually saw.
    #
    # Captured via Invoke-Native rather than run bare, for the reason its own docblock gives:
    # under this file's 'Stop' preference an enclosing capture turns aria2c's first stderr line
    # into a terminating NativeCommandError, so a bare call would throw before $LASTEXITCODE
    # could be read. The cost is that aria2c's progress is captured instead of live; only the
    # TAIL is echoed on failure, because its useful line is the final summary and everything
    # above it is progress repaints.
    $downloader = ""
    $rc  = 0
    $log = @()
    $aria = Join-Path $Root "native\bin\aria2c.cmd"
    if (Test-Path -LiteralPath $aria) {
        $downloader = "aria2c"
        $r = Invoke-Native -FilePath $aria -Arguments @(
            '--allow-overwrite=true', '--auto-file-renaming=false', '--max-tries=3',
            '--dir', (Split-Path $OutFile), '--out', (Split-Path $OutFile -Leaf), $Url)
        $rc  = $r.ExitCode
        $log = $r.Output
    } else {
        $downloader = "Invoke-WebRequest"
        try { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing }
        catch {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            $downloader = "curl"
            $r = Invoke-Native -FilePath "curl.exe" -Arguments @('-L', '--retry', '3', '--fail', '-o', $OutFile, $Url)
            $rc  = $r.ExitCode
            $log = $r.Output
        }
    }
    if ($rc -ne 0) {
        foreach ($line in @($log | Select-Object -Last 15)) { Write-Host "    $line" -ForegroundColor DarkGray }
        throw "$downloader exited $rc so the download never completed (network, DNS, TLS or an HTTP error - NOT a truncated file): $Url"
    }
    if (-not (Test-Path $OutFile)) {
        throw "$downloader exited 0 but wrote no file at $OutFile : $Url"
    }
    $bytes = (Get-Item $OutFile).Length
    if ($bytes -lt $MinimumBytes) {
        throw "the file arrived but is too small: $bytes byte(s), expected at least $MinimumBytes ($downloader exited 0, so this is truncation or the wrong URL, not a network failure): $Url"
    }
    if ($Sha256 -and (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ine $Sha256) {
        Remove-Item -LiteralPath $OutFile -Force
        throw "the file arrived at full size but its SHA-256 does not match ($downloader exited 0): $Url"
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

    # THE TOKEN GOES IN A CONFIG FILE, NEVER ON THE COMMAND LINE, and "we do not echo it" was not
    # enough.
    #
    # This used to prepend @("-H", "Authorization: Bearer $tok") to $curlArgs. The old comment
    # correctly said nothing here echoes those args - but the argument vector IS the exposure, not
    # the logging. A Windows process command line is readable by any other process on the box
    # through Get-CimInstance Win32_Process for the whole life of the transfer, and this machine
    # runs Sysmon, whose ProcessCreate events record command lines to an event log that is kept.
    # So a gated-repo download published the bearer token twice over, to a log and to anything
    # watching, while the code reassured the reader it was careful.
    #
    # curl -K reads options from a file, so the header never appears in any argv. The file is
    # written under %TEMP% with ASCII encoding (curl parses it as bytes; a BOM breaks the first
    # directive) and removed in a finally, so it does not survive a throw. That is a much smaller
    # window than a command line, and it is not world-readable through a WMI query.
    #
    # Rejected: Invoke-WebRequest with a header hashtable, which has no command line at all. It is
    # Schannel-backed, and docs\agent-rules.md records that Schannel cannot acquire a client
    # credential inside the agent sandboxes this repo is used from, failing with
    # SEC_E_NO_CREDENTIALS before a socket is opened.
    $curlConfig = $null
    try {
        if ($tok) {
            $curlConfig = Join-Path ([IO.Path]::GetTempPath()) ("hf-" + [guid]::NewGuid().ToString('N') + ".conf")
            # curl's config syntax, one directive per line. The value is quoted because it contains
            # a space.
            [IO.File]::WriteAllText($curlConfig, ('header = "Authorization: Bearer {0}"' -f $tok), [Text.Encoding]::ASCII)
            $curlArgs = @("-K", $curlConfig) + $curlArgs
        }
        # Same split as Get-Download: curl's exit code first, then the size check, so a 401 from a
        # gated repo or a dead route is not reported as a short file. curl writes its own errors to
        # stderr already.
        $r = Invoke-Native -FilePath "curl.exe" -Arguments $curlArgs
    } finally {
        # BEFORE the throw below, so a failed transfer does not leave the token on disk.
        if ($curlConfig -and (Test-Path -LiteralPath $curlConfig)) {
            Remove-Item -LiteralPath $curlConfig -Force -ErrorAction SilentlyContinue
        }
    }
    if ($r.ExitCode -ne 0) {
        foreach ($line in @($r.Output | Select-Object -Last 15)) { Write-Host "    $line" -ForegroundColor DarkGray }
        throw "curl exited $($r.ExitCode) so the download never completed - that is curl's own verdict on the transfer, NOT a size verdict on the file: $Url"
    }
    if (-not (Test-Path $OutFile)) {
        throw "curl exited 0 but wrote no file at $OutFile : $Url"
    }
    $bytes = (Get-Item $OutFile).Length
    if ($bytes -lt $MinimumBytes) {
        throw "the file arrived but is too small: $bytes byte(s), expected at least $MinimumBytes (curl exited 0, so this is truncation or the wrong URL, not a network failure): $Url"
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
