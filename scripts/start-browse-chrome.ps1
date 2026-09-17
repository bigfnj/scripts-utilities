#Requires -Version 5.1
<#
Start the real Chrome on this machine with a CDP port, on a DEDICATED profile.

This is rung 3 of the `browse` ladder (tools/browse). Attaching to a real Chrome
beats launching a fresh automation Chromium on every axis that anti-bot systems
actually measure: real browser build, real fonts and codecs, real profile age,
real cookies - and a challenge cleared by hand once stays cleared for later
fetches of that host.

  .\scripts\start-browse-chrome.ps1            # start it (idempotent)
  .\scripts\start-browse-chrome.ps1 -Stop      # close that Chrome, nothing else
  .\scripts\start-browse-chrome.ps1 -DryRun    # print the command, launch nothing

TWO REASONS THE PROFILE IS SEPARATE, and either alone would be enough.

1. It is the only thing that works. From Chrome 136 the browser SILENTLY ignores
   --remote-debugging-port when the user-data-dir is the default one. It does not
   reject the flag: Chrome starts, the port is never opened, and an automation
   client then reports a healthy connection and hangs on a blank page. Chrome 152
   is installed here, so the default profile is simply not an option.
   https://developer.chrome.com/blog/remote-debugging-port

2. It keeps the agent out of the signed-in browser. A CDP port has NO
   authentication of its own - anything that can reach it drives the browser and
   can read whatever that profile holds. This box also runs a managed policy that
   denies reads of browser profiles and keychains, and pointing an agent at the
   everyday profile is the thing that denial exists to prevent. Sign in to
   whatever this profile needs by hand, once.

The port binds to loopback only, which is Chrome's default for this switch and is
the only thing keeping an unauthenticated debugger off the network. Nothing here
changes that.
#>
[CmdletBinding()]
param(
    [string]$Root = $(if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }),
    [int]$Port = 9222,
    [string]$ProfileDir,
    [string]$ChromePath,
    [switch]$Stop,
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

function Write-Info { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "OK $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "!! $Message" -ForegroundColor Yellow }

if (-not $ProfileDir) { $ProfileDir = Join-Path $Root "state\browse-profile" }

function Test-CdpPort {
    <#
        Is something LISTENING on the loopback port? A raw TCP connect rather than
        an HTTP request, because this is the guard against the Chrome 136 silent
        failure and it has to be able to say "no" for the right reason. An HTTP
        client here would blur "port closed" into "request failed".
    #>
    param([int]$TcpPort, [int]$TimeoutMs = 400)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $TcpPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-CdpVersion {
    # Best-effort decoration only. Never the liveness check: a failure here must
    # not be reported as a dead port.
    param([int]$TcpPort)
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$TcpPort/json/version" -UseBasicParsing -TimeoutSec 5
        return ($r.Content | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Find-Chrome {
    if ($ChromePath) {
        if (-not (Test-Path -LiteralPath $ChromePath)) { throw "No chrome.exe at -ChromePath '$ChromePath'." }
        return $ChromePath
    }
    $candidates = @(
        (Join-Path $env:ProgramFiles      "Google\Chrome\Application\chrome.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
        (Join-Path $env:LOCALAPPDATA      "Google\Chrome\Application\chrome.exe")
    )
    # App Paths last: it is the authoritative registration but is absent on some
    # user-scope installs, so the well-known locations are tried first.
    try {
        $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction Stop
        if ($reg.'(default)') { $candidates += $reg.'(default)' }
    } catch { }
    $found = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $found) {
        throw "chrome.exe not found. Pass -ChromePath, or install Chrome. Looked in: $($candidates -join '; ')"
    }
    return $found
}

# -- the default-profile refusal ----------------------------------------------
# Compared as resolved paths, not as strings: "%LOCALAPPDATA%\Google\..." and
# "C:\Users\me\AppData\Local\Google\..." are the same directory and a string
# compare would wave one of them through.
$defaultProfile = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
$wanted = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ProfileDir))
$default = [IO.Path]::GetFullPath($defaultProfile)
if ($wanted.TrimEnd('\') -eq $default.TrimEnd('\')) {
    throw @"
Refusing to use Chrome's DEFAULT profile directory:
  $wanted

Chrome 136+ ignores --remote-debugging-port on the default user-data-dir and
opens no port, while the automation client reports a healthy connection and then
hangs. This would not work, and it would put an unauthenticated debugger on your
signed-in browser if it did. Use the dedicated profile (the default for this
script) or pass -ProfileDir somewhere else.
"@
}

if ($Stop) {
    # BOTH the profile and the port must match. Matching the profile alone made
    # -Port a lie: `-Port 9444 -Stop` (without -ProfileDir) stopped the browser on
    # the DEFAULT browse profile, because that is what $wanted fell back to.
    # Requiring both means the flags you passed are the browser you stop.
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -like "*--user-data-dir=$wanted*" -and
            $_.CommandLine -like "*--remote-debugging-port=$Port*"
        })
    if ($procs.Count -eq 0) { Write-Warn "no Chrome on $wanted with port $Port"; return }
    if ($DryRun) { Write-Info "[DRY-RUN] would stop $($procs.Count) chrome.exe on $wanted (port $Port)"; return }
    # Matched on the profile path, so the everyday Chrome is never a candidate.
    $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Ok "stopped $($procs.Count) chrome.exe on $wanted (port $Port)"
    return
}

if (Test-CdpPort -TcpPort $Port) {
    $v = Get-CdpVersion -TcpPort $Port
    if ($v) { Write-Ok "already listening on $Port - $($v.Browser)" }
    else     { Write-Ok "already listening on $Port (version endpoint did not answer)" }
    Write-Info "browse --rung chrome --cdp http://127.0.0.1:$Port <url>"
    return
}

$chrome = Find-Chrome
$chromeArgs = @(
    "--remote-debugging-port=$Port"
    "--user-data-dir=$wanted"
    "--no-first-run"
    "--no-default-browser-check"
    "--homepage=about:blank"
)

if ($DryRun) {
    Write-Info "[DRY-RUN] $chrome $($chromeArgs -join ' ')"
    return
}

New-Item -ItemType Directory -Path $wanted -Force | Out-Null
Start-Process -FilePath $chrome -ArgumentList $chromeArgs | Out-Null

# VERIFY THE PORT, do not assume it. This is the whole reason the script exists
# rather than a documented command line: the Chrome 136 failure mode is a browser
# that starts perfectly and never opens the port, so "Start-Process succeeded" is
# not evidence of anything. 15 s because a cold profile has to be created first.
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    if (Test-CdpPort -TcpPort $Port) { break }
    Start-Sleep -Milliseconds 400
}

if (-not (Test-CdpPort -TcpPort $Port)) {
    throw @"
Chrome started but nothing is listening on 127.0.0.1:$Port after 15s.

That is the Chrome 136+ behaviour when --remote-debugging-port is not honoured.
Check that --user-data-dir really is a non-default directory (this run used
$wanted), that no policy disables remote debugging, and that no other process
holds the port.
"@
}

$v = Get-CdpVersion -TcpPort $Port
if ($v) { Write-Ok "CDP up on $Port - $($v.Browser)" } else { Write-Ok "CDP up on $Port" }
Write-Info "profile: $wanted"
Write-Info "sign in to any site you need read access to, in THIS window, once"
Write-Info "then: browse --rung chrome --cdp http://127.0.0.1:$Port <url>"
Write-Info "stop it later: .\scripts\start-browse-chrome.ps1 -Stop"
