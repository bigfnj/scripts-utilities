#Requires -Version 5.1
<#
Resolve a KB article to its standalone package on the Microsoft Update Catalog and
download it, without admin.

Useful when Windows Update will not offer an update on this box - a managed ring has
not approved it yet, the device is paused/deferred, or the fix is an out-of-band
release that never reaches the ring at all. The catalog always has the .msu, but its
download links are not addressable: you POST an updateID to DownloadDialog.aspx and
it hands back a signed CDN URL. This does that round-trip for you.

Every catalog filename ends in the SHA1 of the file itself
(windows11.0-kb5129195-x64_ed36...eaa.msu), so -Verify is a real integrity check
against a value Microsoft published, not a self-signed checksum of the bytes we
happened to receive. It is on by default; the download is rejected if it disagrees.

  .\scripts\get-msu.ps1 KB5129195 -ListOnly              # show catalog rows, download nothing
  .\scripts\get-msu.ps1 KB5129195                        # native arch, into ~\Downloads
  .\scripts\get-msu.ps1 KB5129195 -Product "24H2" -Arch x64
  .\scripts\get-msu.ps1 5129195 -Destination D:\patches

One KB can yield SEVERAL files, so this returns an array. KB5129195's 24H2 x64 row resolved
to the 4.4 GB LCU AND the 509 MB 24H2 checkpoint cumulative, which is a servicing
prerequisite rather than a duplicate. Budget disk for ~5 GB per KB, not the ~1-2 GB usually
assumed.

Installing what this fetches needs elevation and is a separate, deliberate step:
  wusa.exe <file>.msu /quiet /norestart
  DISM /Online /Add-Package /PackagePath:<file>.msu

WHAT IS EXERCISED, and what is not. The happy path and -ListOnly were run for real against
KB5129195 on 2026-09-21. UNPROVEN, so treat a failure in one of these as a bug in this script
rather than in the catalog: -NoVerify, -Force, -Arch x86, -Arch arm64, the Invoke-WebRequest
fallback (aria2c was on PATH), the "We did not find any results" miss branch, and the
remove-on-hash-mismatch path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$KB,

    # Substring matched against the catalog row title, e.g. "24H2", "Server 2025",
    # "Windows 11". Left empty, every product row for the KB is a candidate.
    [string]$Product = "",

    [ValidateSet("x64", "arm64", "x86", "any")]
    [string]$Arch = "",

    [string]$Destination = (Join-Path $env:USERPROFILE "Downloads"),

    [switch]$ListOnly,
    [switch]$Force,
    [switch]$NoVerify
)
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

function Write-Info { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "OK $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "!! $Message" -ForegroundColor Yellow }

# 5.1 still negotiates SSL3/TLS1.0 first on some boxes; the catalog answers TLS 1.2+ only.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $Arch) {
    $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $Arch = switch ($native) {
        "AMD64" { "x64" }
        "ARM64" { "arm64" }
        "x86"   { "x86" }
        default { "any" }
    }
    Write-Info "Architecture not given; using this machine's: $Arch"
}

$kbNumber = ($KB -replace '(?i)^kb', '').Trim()
if ($kbNumber -notmatch '^\d{6,8}$') { throw "'$KB' does not look like a KB article number (expected e.g. KB5129195)." }
$kbLabel = "KB$kbNumber"

# --- 1. Search the catalog -------------------------------------------------------
Write-Info "Searching the Microsoft Update Catalog for $kbLabel ..."
$searchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$kbLabel"
try {
    $search = Invoke-WebRequest -Uri $searchUrl -UseBasicParsing -TimeoutSec 60
} catch {
    throw "Could not reach the Microsoft Update Catalog ($searchUrl): $($_.Exception.Message)"
}

if ($search.Content -match 'We did not find any results') {
    throw "The catalog has no results for $kbLabel. Check the number, or the KB may be Windows Update-only (no standalone package)."
}

# Each result row exposes its updateID as the id of the title anchor. Parsing the
# anchor (rather than the row) keeps title and id together, which is what the
# download POST below needs.
#
# The id attribute is single-quoted in the catalog's markup (id='<guid>_link'), so the
# quote class here is load-bearing, not defensive: pinning it to " matches nothing.
$rowPattern = '(?s)<a[^>]*id=[''"](?<id>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})_link[''"][^>]*>(?<title>.*?)</a>'
$rows = [regex]::Matches($search.Content, $rowPattern) | ForEach-Object {
    [pscustomobject]@{
        UpdateId = $_.Groups['id'].Value
        Title    = ($_.Groups['title'].Value -replace '\s+', ' ').Trim()
    }
}
if (-not $rows) { throw "Found the $kbLabel results page but could not parse any rows from it (the catalog's HTML may have changed)." }

Write-Host ""
Write-Host "Catalog rows for ${kbLabel}:" -ForegroundColor White
$rows | ForEach-Object { Write-Host "  - $($_.Title)" }
Write-Host ""

# --- 2. Narrow to the row we want ------------------------------------------------
$candidates = $rows
if ($Product) {
    $candidates = $candidates | Where-Object { $_.Title -like "*$Product*" }
    if (-not $candidates) { throw "No $kbLabel row matched -Product '$Product'. Re-run with -ListOnly to see the available titles." }
}
if ($Arch -ne "any") {
    # Catalog titles say "for x64-based Systems" / "for ARM64-based Systems"; x86 rows
    # carry no arch phrase at all, so match them by elimination rather than by name.
    $candidates = switch ($Arch) {
        "x64"   { $candidates | Where-Object { $_.Title -match '(?i)x64' } }
        "arm64" { $candidates | Where-Object { $_.Title -match '(?i)arm64' } }
        "x86"   { $candidates | Where-Object { $_.Title -notmatch '(?i)x64|arm64|itanium' } }
    }
    if (-not $candidates) { throw "No $kbLabel row matched -Arch '$Arch'. Re-run with -ListOnly to see the available titles." }
}

if ($ListOnly) {
    Write-Info "-ListOnly: stopping before download. Matching rows:"
    $candidates | ForEach-Object { Write-Host "  * $($_.Title)" -ForegroundColor Green }
    return
}

# --- 3. Resolve updateIDs to CDN URLs --------------------------------------------
# ONE ROW CAN RETURN SEVERAL FILES, which is the opposite of what this comment used to
# claim. Measured 2026-09-21 against KB5129195: the single 24H2 x64 row resolved to TWO
# distinct packages -
#   windows11.0-kb5129195-x64_ed36...eaa.msu   4424.5 MB   the LCU itself
#   windows11.0-kb5043080-x64_9534...3e8.msu    509.0 MB   the 24H2 checkpoint cumulative,
#                                                          shipped as a servicing prerequisite
# so the caller gets an ARRAY of files per KB and needs all of them. Resolve every matched
# row and de-duplicate on URL: the de-dup is there because SEVERAL ROWS MAY ALSO SHARE ONE
# FILE, not because one row yields one file.
#
# NOT VERIFIED, so do not encode it as an expectation: whether the 25H2 and 26H2 x64 rows
# return the same file as the 24H2 one. Microsoft's support page lists a single x64 filename
# for the whole KB, which implies they do, but only the 24H2 row was actually resolved.
#
# The URL pattern is deliberately host-agnostic. Older write-ups name
# catalog.s.download.windowsupdate.com; what actually came back was
# catalog.sf.dl.delivery.mp.microsoft.com. Pinning a known host is a regression waiting to
# happen.
$files = @()
foreach ($row in $candidates) {
    $body = 'updateIDs=' + [uri]::EscapeDataString("[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$($row.UpdateId)`",`"updateID`":`"$($row.UpdateId)`"}]")
    try {
        $dialog = Invoke-WebRequest -Uri "https://catalog.update.microsoft.com/DownloadDialog.aspx" `
                                    -Method POST -Body $body `
                                    -ContentType "application/x-www-form-urlencoded" `
                                    -UseBasicParsing -TimeoutSec 60
    } catch {
        Write-Warn "Could not resolve a download URL for '$($row.Title)': $($_.Exception.Message)"
        continue
    }
    foreach ($m in [regex]::Matches($dialog.Content, "(?<url>https?://[^'`"\s]+\.(?:msu|cab|exe|msi))")) {
        $files += [pscustomobject]@{
            Title = $row.Title
            Url   = $m.Groups['url'].Value
            Name  = [IO.Path]::GetFileName(($m.Groups['url'].Value -split '\?')[0])
        }
    }
}

$files = $files | Sort-Object Url -Unique
if (-not $files) { throw "Matched $($candidates.Count) catalog row(s) for $kbLabel but none returned a download URL." }

if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

# --- 4. Download + verify ---------------------------------------------------------
$aria = Get-Command aria2c -ErrorAction SilentlyContinue
$results = @()

foreach ($file in $files) {
    $target = Join-Path $Destination $file.Name
    Write-Host ""
    Write-Info "$($file.Title)"
    Write-Info "-> $($file.Name)"

    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        Write-Warn "Already present, skipping download (use -Force to re-fetch): $target"
    } elseif ($aria) {
        # A cumulative LCU is >1 GB - a current 24H2 one measured 4.4 GB, and 4.9 GB with its
        # checkpoint prerequisite - so aria2c's parallel connections and resume make a dropped
        # VPN mid-transfer survivable where Invoke-WebRequest starts over.
        #
        # $aria.Source, NOT the literal aria2c.exe. The probe above resolves `aria2c`, which on
        # this box is native\bin\aria2c.cmd; calling aria2c.exe instead only works while a
        # SECOND copy happens to sit in the winget Links directory. Guarding on one name and
        # invoking another is how a guard passes for a call that then fails.
        #
        # TWO THINGS THAT LOOK LIKE FAILURES AND ARE NOT, both measured 2026-09-21:
        #   1. aria2c logs "[ERROR] CUID#n - Download aborted ... errorCode=1 Network problem
        #      ... A socket operation was attempted to an unreachable network" on a SUCCESSFUL
        #      run - they are IPv6 attempts failing over to IPv4. Both files then completed at
        #      ~100 MiB/s with exit 0 and matching SHA1s. Never grep this output for "ERROR"
        #      and never treat its stderr as failure: the signal is $LASTEXITCODE plus the
        #      hash check below, and nothing else.
        #   2. It pre-allocates the whole file first, so progress sits at 0B/4.3GiB(0%) with a
        #      separate [FileAlloc] counter climbing for a noticeable stretch. A
        #      progress-based watchdog or a short timeout kills a healthy download; budget for
        #      allocation plus transfer.
        & $aria.Source --allow-overwrite=true --auto-file-renaming=false --console-log-level=warn `
                       --summary-interval=0 -x8 -s8 -d "$Destination" -o "$($file.Name)" $file.Url
        if ($LASTEXITCODE -ne 0) { throw "aria2c failed (exit $LASTEXITCODE) downloading $($file.Url)" }
    } else {
        Write-Info "aria2c not on PATH; falling back to Invoke-WebRequest (slower, no resume)."
        Invoke-WebRequest -Uri $file.Url -OutFile $target -UseBasicParsing -TimeoutSec 3600
    }

    $item     = Get-Item -LiteralPath $target
    $sizeMB   = [math]::Round($item.Length / 1MB, 1)
    $verified = "not checked"

    if (-not $NoVerify) {
        if ($file.Name -match '_(?<sha1>[0-9a-fA-F]{40})\.(?:msu|cab|exe|msi)$') {
            $expected = $Matches['sha1'].ToLower()
            $actual   = (Get-FileHash -LiteralPath $target -Algorithm SHA1).Hash.ToLower()
            if ($actual -ne $expected) {
                Remove-Item -LiteralPath $target -Force
                throw "SHA1 mismatch for $($file.Name) (expected $expected, got $actual). Deleted the bad download."
            }
            $verified = "SHA1 matches catalog filename"
        } else {
            $verified = "no hash in filename to check against"
        }
    }

    # An .msu is Authenticode-signed; a clean signature is the stronger statement, so
    # report it when the file is one and the OS can read it.
    $signature = "n/a"
    if ($item.Extension -in ".msu", ".cab", ".exe", ".msi") {
        try { $signature = (Get-AuthenticodeSignature -LiteralPath $target).Status.ToString() } catch { $signature = "unreadable" }
    }

    Write-Ok "$($item.Name)  ${sizeMB} MB  [$verified; signature: $signature]"
    $results += [pscustomobject]@{
        Name      = $item.Name
        SizeMB    = $sizeMB
        Path      = $item.FullName
        Verified  = $verified
        Signature = $signature
    }
}

# EMIT THEM. $results was built and then dropped on the floor, so a caller doing
# `$msu = .\scripts\get-msu.ps1 KB5129195` got nothing back and had to re-derive the paths
# from the console text. One KB can yield several files (see the note above section 3), so
# this is an array by contract even when it holds one element.
Write-Host ""
Write-Ok "$($results.Count) file(s) in $Destination"
Write-Host ""
Write-Host "Installing needs elevation and is a separate, deliberate step:" -ForegroundColor DarkGray
foreach ($r in $results) {
    Write-Host ("  wusa.exe `"{0}`" /quiet /norestart" -f $r.Path) -ForegroundColor DarkGray
}
$results

Write-Host ""
Write-Ok "$kbLabel saved to $Destination"
$results | Format-List
