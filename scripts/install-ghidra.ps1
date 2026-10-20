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
    [ValidatePattern('^(latest|Ghidra_[0-9]+\.[0-9]+(?:\.[0-9]+)?_build)$')]
    [string]$ReleaseTag = 'latest',
    [ValidateSet(21, 25)]
    [int]$JdkMajor = 21,
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
    # Metadata exclusions happen before member contents are read. Public certificates
    # and synthetic fixture keys are excluded too; filename rules do not inspect secrets.
    $python = Join-Path $Root "python\.venv\Scripts\python.exe"
    $extractor = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\vendor_archive.py"
    if (-not (Test-Path -LiteralPath $python)) { throw "Shared toolbox Python is required for safe vendor archive extraction." }
    $result = Invoke-Native -FilePath $python -Arguments @('-X', 'utf8', $extractor, $Zip, $Dest)
    if ($result.ExitCode -ne 0) { throw "Safe vendor ZIP extraction failed: $($result.Output -join ' ')" }
    $verdict = ($result.Output -join [Environment]::NewLine) | ConvertFrom-Json
    Write-Info ("Extracted {0} files; excluded {1} protected archive members (H01-H09/H20, W01-W10)." -f $verdict.extracted, @($verdict.excluded_protected).Count)
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
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        } catch {
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
        # NEVER put the token on the command line. A Windows command line is world-readable for
        # the lifetime of the process through Win32_Process/CIM (any user, no privilege needed),
        # and it also outlives the process: this repo's own Sysmon config,
        # config\sysmon-filedelete.xml, includes '<Image condition="end with">\python.exe</Image>'
        # in its ProcessCreate capture, so a token passed as argv[2] was copied verbatim into a
        # 2 GB event log holding days of history. Pass it in the child's environment instead -
        # a process environment block is readable only by the same user or an admin, is not
        # captured by ProcessCreate, and dies with the process. Nothing here echoes the value.
        $pyGet = "import os,requests,sys; h={'User-Agent':'scripts-utilities'}; t=os.environ.get('GH_API_TOKEN'); h.update({'Authorization':'Bearer '+t} if t else {}); r=requests.get(sys.argv[1],headers=h,timeout=60); r.raise_for_status(); print(r.text)"
        # Same host test as the header above: Get-Json also fetches api.adoptium.net, and a
        # GitHub token must never travel there. Clearing the variable when we are not sending
        # one also stops an unrelated GH_API_TOKEN already in this shell from leaking out.
        $sendToken = ($token -and ($Url -like "https://api.github.com/*"))
        $hadToken = Test-Path Env:\GH_API_TOKEN
        $prevToken = if ($hadToken) { $env:GH_API_TOKEN } else { $null }
        try {
            if ($sendToken) { $env:GH_API_TOKEN = $token }
            else { Remove-Item Env:\GH_API_TOKEN -ErrorAction SilentlyContinue }
            $json = & $python -c $pyGet $Url
        } finally {
            # Restore exactly what was there, and REMOVE rather than blank it if it was absent:
            # $env:X = '' leaves an empty variable behind in Windows PowerShell 5.1, which a
            # later reader cannot tell apart from a real (empty) token.
            if ($hadToken) { $env:GH_API_TOKEN = $prevToken }
            else { Remove-Item Env:\GH_API_TOKEN -ErrorAction SilentlyContinue }
        }
        if ($LASTEXITCODE -ne 0) { throw "JSON request failed: $Url" }
        return ($json | ConvertFrom-Json)
    }
}

if (-not $SkipGhidra) {
    $ghidraFilter = if ($ReleaseTag -eq 'latest') { 'ghidra_*' } else { ($ReleaseTag -replace '^Ghidra_', 'ghidra_' -replace '_build$', '_PUBLIC*') }
    $have = Get-ChildItem $native -Filter $ghidraFilter -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "ghidraRun.bat") } | Select-Object -First 1
    if ($have) {
        foreach ($required in @('support\analyzeHeadless.bat', 'Ghidra\application.properties', 'Ghidra\Features\Decompiler\os\win_x86_64\decompile.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $have.FullName $required))) { throw "Ghidra installation is incomplete ($required); preserve it for inspection before repair." }
        }
        Write-Ok "Ghidra already present: $($have.FullName)"
    } elseif ($DryRun) {
        Write-Info "[DRY-RUN] would resolve, verify, download, and extract Ghidra release $ReleaseTag"
    } else {
        Write-Info "resolve Ghidra release $ReleaseTag"
        $releasePath = if ($ReleaseTag -eq 'latest') { 'latest' } else { "tags/$ReleaseTag" }
        $rel   = Get-Json "https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/$releasePath"
        $asset = $rel.assets | Where-Object { $_.name -like "ghidra_*_PUBLIC_*.zip" } | Select-Object -First 1
        if (-not $asset) { throw "no Ghidra *_PUBLIC_*.zip asset in the latest release" }
        $zip = Join-Path $dl $asset.name
        Write-Info "download $($asset.name) ($([int]($asset.size / 1MB)) MB)"
        $digest = if ($asset.digest -match '^sha256:(.+)$') { $Matches[1] } else { "" }
        if (-not $digest) { throw "latest Ghidra release does not publish a SHA-256 digest" }
        Get-Download -Url $asset.browser_download_url -OutFile $zip -Sha256 $digest -MinimumBytes 100MB
        # No -DryRun guard here: this is the else of 'elseif ($DryRun)', so $DryRun is already
        # known false. The guard that used to wrap these three lines could never be anything but
        # true, and reading it suggested a dry run reached this far - it cannot.
        Expand-ZipTo $zip $native
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Write-Ok "Ghidra -> $native"
    }
}

if (-not $SkipJdk) {
    $have = Get-ChildItem $native -Filter "jdk-$JdkMajor*" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "bin\java.exe") } | Select-Object -First 1
    if ($have) {
        $javaProbe = Invoke-Native -FilePath (Join-Path $have.FullName 'bin\java.exe') -Arguments @('-version')
        if ($javaProbe.ExitCode -ne 0 -or ($javaProbe.Output -join ' ') -notmatch ('version "' + $JdkMajor + '\.')) { throw "Existing JDK did not report Java $JdkMajor; preserve it for inspection." }
        Write-Ok "JDK already present: $($have.FullName)"
    } elseif ($DryRun) {
        Write-Info "[DRY-RUN] would resolve, verify, download, and extract the latest Temurin JDK $JdkMajor"
    } else {
        Write-Info "download Eclipse Temurin JDK $JdkMajor (portable)"
        $assets = Get-Json "https://api.adoptium.net/v3/assets/latest/$JdkMajor/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse"
        $package = $assets | Select-Object -First 1 -ExpandProperty binary | Select-Object -ExpandProperty package
        if (-not $package.link -or -not $package.checksum) { throw "Adoptium API returned no JDK package/checksum" }
        $zip = Join-Path $dl $package.name
        Get-Download -Url $package.link -OutFile $zip -Sha256 $package.checksum -MinimumBytes 100MB
        # Same dead guard as the Ghidra branch above: unreachable unless $DryRun is false.
        Expand-ZipTo $zip $native
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Write-Ok "JDK -> $native"
    }
}

Write-Host ""
Write-Host "Next: .\bootstrap.ps1 -Only security   (detects + wires Ghidra/JDK onto the toolbox PATH)" -ForegroundColor White
