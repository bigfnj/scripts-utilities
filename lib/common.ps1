# Shared helpers - sourced (dot-sourced) by bootstrap.ps1 and every module.
# Defines functions only; no side effects on dot-source.

if (-not (Get-Variable -Name DryRun -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DryRun = $false
}
$script:TODAY    = (Get-Date -Format 'yyyy-MM-dd')
$script:MANIFEST = Join-Path $PSScriptRoot "..\manifest\tools.json"

# -- Logging -------------------------------------------------------------------
function Write-Info  { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "OK $Msg" -ForegroundColor Green }
function Write-Skip  { param([string]$Msg) Write-Host "- $Msg" -ForegroundColor DarkGray }
function Write-Warn  { param([string]$Msg) Write-Host "WARN $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "FAIL $Msg" -ForegroundColor Red }
function Write-Group { param([string]$Msg) Write-Host "`n== $Msg ==" -ForegroundColor White }

# -- Detection -----------------------------------------------------------------
function Test-CommandAvailable {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Assert-WingetAvailable {
    if (Test-CommandAvailable "winget") { return }
    throw @"
winget is required but is not available in this PowerShell session.
Install or update 'App Installer' from Microsoft Store, then open a new normal
PowerShell window and confirm 'winget --version' works before running bootstrap.
"@
}

# Refresh PATH from registry so newly-installed tools are visible in the current
# session without restarting PowerShell.
function Sync-EnvPath {
    $machine = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $paths = @()
    $toolboxRoot = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX }
                   else { "$env:LOCALAPPDATA\DevToolbox" }
    foreach ($candidate in @(
        (Join-Path $toolboxRoot "native\bin"),
        (Join-Path $toolboxRoot "python\.venv\Scripts")
    )) {
        if (Test-Path $candidate) { $paths += $candidate }
    }
    $paths += ($machine -split ';')
    $paths += ($user -split ';')
    $env:PATH = ($paths | Where-Object { $_ } | Select-Object -Unique) -join ';'
}

function Add-UserPathEntry {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Warn "PATH entry does not exist: $Path"
        return $false
    }
    $resolved = (Resolve-Path $Path).Path
    $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $entries = @($userPath -split ';' | Where-Object { $_ })
    $exists = $entries | Where-Object { $_.TrimEnd('\') -ieq $resolved.TrimEnd('\') } | Select-Object -First 1
    if (-not $exists) {
        $entries += $resolved
        [System.Environment]::SetEnvironmentVariable('PATH', ($entries -join ';'), 'User')
        Write-Ok "added user PATH entry: $resolved"
    }
    Sync-EnvPath
    return $true
}

# Remove an entry from the persistent user PATH (mirror of Add-UserPathEntry).
# Matches case-insensitively, ignoring a trailing backslash. Idempotent.
function Remove-UserPathEntry {
    param([string]$Path)
    $target = $Path.TrimEnd('\')
    $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $userPath) { return }
    $entries = @($userPath -split ';' | Where-Object { $_ })
    $kept = @($entries | Where-Object { $_.TrimEnd('\') -ine $target })
    if ($kept.Count -eq $entries.Count) { return }   # nothing matched
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would remove user PATH entry: $Path"
        return
    }
    [System.Environment]::SetEnvironmentVariable('PATH', ($kept -join ';'), 'User')
    Write-Ok "removed user PATH entry: $Path"
    Sync-EnvPath
}

# Strip fenced agent-discovery blocks (WIN_DEVTOOLS and/or legacy CODEX_TOOLBOX)
# from the standard agent files. Backs each file up before rewriting. Shared by
# the uninstaller and the legacy-cleanup path.
function Remove-AgentBlocks {
    param(
        [string[]]$Markers = @('WIN_DEVTOOLS', 'CODEX_TOOLBOX'),
        [string[]]$Files
    )
    if (-not $Files) {
        $Files = @(
            (Join-Path $env:USERPROFILE ".codex\AGENTS.md"),
            (Join-Path $env:USERPROFILE ".claude\CLAUDE.md"),
            (Join-Path $env:USERPROFILE "CLAUDE.md"),
            (Join-Path $env:USERPROFILE "AGENTS.md")
        )
    }
    $alt = ($Markers | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $pattern = "(?s)\r?\n?<!-- (?:$alt)_START -->.*?<!-- (?:$alt)_END -->\r?\n?"
    foreach ($file in $Files) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        $cleaned = $content -replace $pattern, ""
        if ($cleaned -eq $content) { continue }
        if ($script:DryRun) {
            Write-Info "[DRY-RUN] would remove agent block(s): $file"
            continue
        }
        $backup = "$file.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $file -Destination $backup -Force
        Set-Content -LiteralPath $file -Value $cleaned.Trim() -Encoding UTF8
        Write-Ok "removed agent block(s): $file"
    }
}

# -- Winget --------------------------------------------------------------------
# Install a tool via winget, idempotently. Detection is by binary name first
# (fast path), then winget list (catches installs not on PATH yet).
function Install-WingetTool {
    param(
        [string]$Id,
        [string]$Binary,
        [string]$Name,
        [switch]$MachineScope,
        # Omit --scope entirely. A few manifests declare no scope at all, and
        # winget then rejects BOTH --scope user and --scope machine with
        # 0x8A150010 "No applicable installer found" (e.g. Podman.CLI, the WDK).
        # Without the flag winget picks the manifest's only installer, which for
        # Podman is a per-user MSI - so this stays PATH-clean and needs no UAC.
        [switch]$NoScope
    )
    if (Test-CommandAvailable $Binary) {
        Write-Skip "$Name already present ($Binary)"
        return $true
    }
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would: winget install --id $Id -e"
        return $true
    }
    Assert-WingetAvailable
    # Secondary check via winget list in case the binary isn't on PATH yet
    $listed = winget list --id $Id -e --accept-source-agreements 2>&1
    if ($LASTEXITCODE -eq 0 -and ($listed -match [regex]::Escape($Id))) {
        Write-Skip "$Name installed (not yet on PATH - open a new shell)"
        Sync-EnvPath
        return $true
    }
    Write-Info "winget install $Id"
    $args = @(
        "install", "--id", $Id, "-e",
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--silent"
    )
    if ($NoScope) {
        # Deliberately no --scope flag; see the parameter comment above.
    }
    elseif (-not $MachineScope) {
        # User scope keeps PATH changes in user scope and avoids elevation where supported.
        $args += @("--scope", "user")
    }
    winget @args
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$Name install failed via winget id $Id (exit $LASTEXITCODE)"
        return $false
    }
    Sync-EnvPath
    if (-not (Test-CommandAvailable $Binary)) {
        Write-Warn "$Name installed but '$Binary' is not visible on PATH in this session"
    }
    return $true
}

# -- Toolbox Python ------------------------------------------------------------
# Locate the dev toolbox Python executable. Respects CODEX_TOOLBOX env var;
# falls back to the known-good default path.
function Get-ToolboxPython {
    $root = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX }
            else { "$env:LOCALAPPDATA\DevToolbox" }
    $py = Join-Path $root "python\.venv\Scripts\python.exe"
    if (Test-Path $py) { return $py }
    return $null
}

# Wrap the toolbox venv's console-script executables into native\bin so the venv
# CLIs (frida, jupyter-lab, sqlite-utils, csvkit, playwright, ...) are callable by
# name from any shell WITHOUT putting the venv Scripts dir on the persistent PATH.
# That dir also holds python.exe, and exposing a 3.11 interpreter on PATH is what
# trips corporate "old Python" compliance scanners - so the interpreter stays off
# PATH (reachable via $env:TOOLBOX_PYTHON) and only the CLIs are wrapped. The
# python*/pythonw*/pip* launchers are deliberately excluded.
function Set-NodeSystemCaBundle {
    # Make node/npm trust the OS certificate store so 'npm install' works behind
    # corporate TLS interception. node ships its own CA bundle and ignores the
    # Windows trust store, so on a machine whose proxy presents a corporate root
    # CA (trusted by Windows but not by node) npm's HTTPS to the registry fails or
    # hangs. We export the Windows trusted roots to a PEM bundle under the toolbox
    # and point NODE_EXTRA_CA_CERTS at it (node ADDS these to its defaults). This
    # auto-discovers the corporate CA - no need to locate a .cer by hand.
    # Idempotent. NOTE: only fixes cert-TRUST; if the registry is proxy-blocked or
    # requires an authenticated proxy, npm also needs HTTP(S)_PROXY / npm proxy config.
    $root = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
    $dir = Join-Path $root "certs"
    $bundle = Join-Path $dir "windows-roots.pem"
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would export Windows root CAs -> $bundle and set NODE_EXTRA_CA_CERTS"
        return
    }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $seen  = @{}
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($store in @('Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root')) {
        foreach ($c in (Get-ChildItem $store -ErrorAction SilentlyContinue)) {
            if ($seen.ContainsKey($c.Thumbprint)) { continue }
            $seen[$c.Thumbprint] = $true
            $lines.Add("# " + $c.Subject)
            $lines.Add("-----BEGIN CERTIFICATE-----")
            $lines.Add([Convert]::ToBase64String($c.RawData, [System.Base64FormattingOptions]::InsertLineBreaks))
            $lines.Add("-----END CERTIFICATE-----")
        }
    }
    if ($seen.Count -eq 0) {
        Write-Warn "no trusted root CAs found to export - skipping NODE_EXTRA_CA_CERTS"
        return
    }
    Set-Content -LiteralPath $bundle -Value $lines -Encoding ASCII
    $cur = [System.Environment]::GetEnvironmentVariable('NODE_EXTRA_CA_CERTS', 'User')
    if ($cur -ne $bundle) {
        [System.Environment]::SetEnvironmentVariable('NODE_EXTRA_CA_CERTS', $bundle, 'User')
        Write-Ok "NODE_EXTRA_CA_CERTS -> $bundle ($($seen.Count) roots)"
    }
    $env:NODE_EXTRA_CA_CERTS = $bundle
}

function New-VenvCliWrappers {
    $root = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
    $venvScripts = Join-Path $root "python\.venv\Scripts"
    $binDir = Join-Path $root "native\bin"
    if (-not (Test-Path $venvScripts)) { return }
    if (-not (Test-Path $binDir)) {
        if ($script:DryRun) { Write-Info "[DRY-RUN] would create $binDir for venv CLI wrappers"; return }
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }
    $skip = '^(python|pythonw|pip|pipx)([0-9.]*)?$'
    foreach ($exe in Get-ChildItem -LiteralPath $venvScripts -Filter *.exe -ErrorAction SilentlyContinue) {
        if ($exe.BaseName -match $skip) { continue }
        if ($script:DryRun) { Write-Info "[DRY-RUN] would wrap venv CLI: $($exe.BaseName)"; continue }
        "@echo off`r`n`"$($exe.FullName)`" %*" | Set-Content -Path (Join-Path $binDir "$($exe.BaseName).cmd") -Encoding ASCII
    }
}

# Install a package into the dev toolbox venv, idempotently.
# $ImportName: the Python import name to test (defaults to $Package if omitted).
function Install-PipToolbox {
    param(
        [string]$Package,
        [string]$ImportName = ""
    )
    $py = Get-ToolboxPython
    if (-not $py) {
        Write-Warn "Toolbox Python not found - skipping $Package (set CODEX_TOOLBOX or run scripts/build-devtoolbox.ps1)"
        return $false
    }
    $check = if ($ImportName) { $ImportName } else { ($Package -split '\[')[0] -replace '-','_' }
    # Probe with find_spec on a single line and DO NOT redirect stderr. A missing
    # module makes find_spec return None, so we exit 1 while emitting nothing. A bare
    # `import` writes a traceback to stderr, and *redirecting* native stderr (2>&1 OR
    # 2>$null) under $ErrorActionPreference='Stop' makes PowerShell 5.1 raise a
    # terminating NativeCommandError that aborts the whole run.
    & $py -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$check') else 1)"
    if ($LASTEXITCODE -eq 0) {
        Write-Skip "$Package already in toolbox venv"
        return $true
    }
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would: pip install $Package (toolbox venv)"
        return $true
    }
    Write-Info "pip install $Package (toolbox venv)"
    & $py -m pip install $Package --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$Package install failed in toolbox venv (exit $LASTEXITCODE)"
        return $false
    }
    return $true
}

# -- npm global ----------------------------------------------------------------
function Install-NpmGlobal {
    param(
        [string]$Package,
        [string]$Binary = ""
    )
    $bin = if ($Binary) { $Binary } else { $Package }
    if (Test-CommandAvailable $bin) {
        Write-Skip "$Package already installed globally ($bin)"
        return $true
    }
    if (-not (Test-CommandAvailable 'npm')) {
        Write-Warn "npm not found - skipping $Package"
        return $false
    }
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would: npm install -g $Package"
        return $true
    }
    Write-Info "npm install -g $Package"
    # Bound the attempt: corporate TLS interception can make node's HTTPS to the
    # npm registry hang far past a sane wait (a TCP connect to the proxy succeeds
    # but the fetch stalls). These flags fail fast (~1-2 min) instead of wedging
    # the whole run; a failure is non-fatal here (returns $false, caller warns).
    npm install -g $Package --no-audit --no-fund --fetch-timeout=60000 --fetch-retries=1 --fetch-retry-maxtimeout=20000
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$Package npm install failed or timed out (exit $LASTEXITCODE)"
        return $false
    }
    # npm's global prefix (e.g. %APPDATA%\npm) is where -g CLIs land, but a
    # machine-scope Node install does not add it to PATH - register it (user
    # scope) so npm-global tools resolve by name.
    $npmPrefix = (& npm config get prefix | Select-Object -First 1)
    if ($npmPrefix -and (Test-Path $npmPrefix)) { Add-UserPathEntry $npmPrefix | Out-Null }
    Sync-EnvPath
    return (Test-CommandAvailable $bin)
}

# -- Manifest ------------------------------------------------------------------
# Upsert a tool entry into the Windows manifest JSON (parallel to Linux tools.json).
function Add-WinManifest {
    param(
        [string]$Name,
        [string]$Binary,
        [string]$Group,
        [string]$Method,      # winget | pip-toolbox | npm-global
        [string]$Detect,
        [string]$Scope = "user",
        [string]$WingetId = "",
        [string]$Notes    = "",
        [bool]$InstalledByToolbox = $true   # provenance: $false if it pre-existed
    )
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would manifest_add $Name"
        return
    }
    $manifestPath = $script:MANIFEST
    $dir = Split-Path $manifestPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $entries = @()
    if (Test-Path $manifestPath) {
        $loaded = Get-Content $manifestPath -Raw | ConvertFrom-Json
        if ($loaded) {
            $entries = @($loaded)
        }
    }

    $version = ""
    try {
        $match = Invoke-Expression $Detect 2>&1 |
            Select-String '[0-9]+\.[0-9]+[.0-9]*' |
            Select-Object -First 1
        if ($match -and $match.Matches.Count -gt 0) {
            $version = $match.Matches[0].Value
        }
    } catch {}

    $entry = [ordered]@{
        name              = $Name
        binary            = $Binary
        group             = $Group
        scope             = $Scope
        install_method    = $Method
        detect            = $Detect
        status            = "core"
        notes             = $Notes
        winget_id         = $WingetId
        last_verified     = $script:TODAY
        installed_version = "$version"
        installed_by_toolbox = $InstalledByToolbox
    }

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($existing in $entries) {
        $list.Add($existing)
    }
    $idx  = $list.FindIndex({ param($e) $e.name -eq $Name })
    if ($idx -ge 0) { $list[$idx] = $entry } else { $list.Add($entry) }

    $list | ConvertTo-Json -Depth 4 | Set-Content $manifestPath -Encoding UTF8
}

# -- Agent discovery -----------------------------------------------------------
# Write a fenced discovery block into a file. Idempotent: replaces the block if
# the marker is already present, appends otherwise. Backs up the file first.
function Write-AgentBlock {
    param(
        [string]$FilePath,
        [string]$Marker,
        [string]$Body
    )
    $start = "<!-- ${Marker}_START -->"
    $end   = "<!-- ${Marker}_END -->"
    $dir   = Split-Path $FilePath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $FilePath)) { Set-Content $FilePath "" -Encoding UTF8 }

    $content = Get-Content $FilePath -Raw -Encoding UTF8
    if ($content -match [regex]::Escape($start)) {
        $pattern = "(?s)" + [regex]::Escape($start) + ".*?" + [regex]::Escape($end)
        $replacement = "$start`n$Body`n$end"
        $content = $content -replace $pattern, $replacement
    } else {
        $content = $content.TrimEnd() + "`n`n$start`n$Body`n$end`n"
    }
    $backup = "$FilePath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if (Test-Path $FilePath) { Copy-Item $FilePath $backup -Force }
    Set-Content $FilePath $content -Encoding UTF8
    Write-Ok "agent block [$Marker] -> $FilePath"
}

function Write-AgentDiscovery {
    param([string]$RepoRoot)
    $manifestPath  = Join-Path $RepoRoot "manifest\tools.json"
    $toolboxRoot   = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX }
                     else { "$env:LOCALAPPDATA\DevToolbox" }
    $toolboxManifest = Join-Path $toolboxRoot "toolbox-manifest.json"
    $activatePs1   = Join-Path $toolboxRoot "scripts\Activate-CodexToolbox.ps1"

    $body = @"
## Windows dev toolbox - scripts-utilities

This machine has a curated cross-platform developer toolbox.
Managed by: $RepoRoot

### Before installing any tool

Check the Windows manifest first - the tool may already be present:
  Get-Content '$manifestPath' | ConvertFrom-Json

Install rules (channels, PATH hygiene, add-a-tool workflow):
  $RepoRoot\docs\agent-rules.md

Full usage guide (HOW to use each tool):
  $RepoRoot\docs\tools-reference.md

### Python + native CLI toolbox

Toolbox root: $toolboxRoot
Manifest:     $toolboxManifest
On PATH:      bootstrap.ps1 adds native\bin (native CLIs + wrapped venv CLIs)
              and sysinternals to your user PATH, so every tool below is
              available by name in any new shell - no activation needed.
Not found?    Check the registry PATH before concluding a tool is missing, and
              do NOT install it again. A long-running agent host caches its
              environment at launch, so anything added to PATH afterwards is
              invisible to every shell it spawns - including the toolbox itself.
              Refreshing PATH fixes one invocation and does not carry to the next
              tool call. Durable fix: restart the agent host (a reboot is not
              needed). See the "When a tool is missing from PATH" section of
              $RepoRoot\docs\agent-rules.md.
Python 3.11:  the toolbox venv interpreter is deliberately NOT on PATH - a bare
              'python' stays your sanctioned system version. Call the toolbox
              Python explicitly via %TOOLBOX_PYTHON% (=
              $toolboxRoot\python\.venv\Scripts\python.exe) when you need the
              toolbox libraries. Its CLIs (frida, jupyter-lab, sqlite-utils,
              csvkit, ...) are wrapped into native\bin, so they run by name.

Toolbox provides: Python 3.11 venv, document/PDF/OCR/image/GPU libs, and
native CLI tools: ffmpeg, ffprobe, ImageMagick, Pandoc, tesseract, poppler,
qpdf, ghostscript, LibreOffice, 7z, rg, fd, jq, yq, exiftool, aria2c, rclone,
DuckDB, Node.js, uv/uvx. Sysinternals (procdump, handle, sigcheck, ...) is on
PATH too. Set CODEX_TOOLBOX to override the toolbox root path.

### Developer CLI tools - installed on user PATH (winget)

  gh          GitHub operations: gh pr list / gh issue create / gh repo clone
  fzf         Fuzzy select from a list: pipe to fzf; --filter for scripts
  bat         Syntax-highlighted file view: bat <file> (replaces type/cat)
  delta       Git diff pager: set via git config core.pager delta
  just        Task runner: just <recipe> (reads justfile in current dir)
  hyperfine   Benchmark: hyperfine "cmd1" "cmd2" to compare timing
  sops        Encrypted secrets: sops --encrypt --age <pubkey> file.yaml
  age         File encryption: age-keygen for keys; age -r <pubkey> -o out.age
  tokei       LOC stats: tokei [path] for a language breakdown
  yt-dlp      Download video/audio (1000+ sites): yt-dlp <url>; -x audio-only,
              -F list formats. Uses toolbox ffmpeg to merge/transcode; YouTube
              nsig/PO-token challenges solved via bundled EJS scripts + the deno
              runtime (auto-detected on PATH).
  deno        Secure JS/TS runtime; also yt-dlp's default JS challenge runtime.
              deno run script.ts | deno repl | deno fmt
  tshark      Read/analyze captures: tshark -r cap.pcapng -Y "tcp.flags.reset==1"
              Live capture (tshark -i) needs Npcap (no winget pkg; optional).
  etl2pcapng  Convert built-in pktmon/netsh .etl -> .pcapng for tshark
              (driver-free capture: pktmon -> etl2pcapng -> tshark; no Npcap)

### Security / RE tools

  Ghidra      Optional portable RE suite. Provision with:
              $RepoRoot\scripts\install-ghidra.ps1
              Then use ghidraRun or analyzeHeadless from the toolbox PATH.
  frida       Dynamic instrumentation (toolbox venv; on PATH after bootstrap):
              frida -n notepad.exe -l hook.js
  WinDbg      Windows crash-dump / live user+kernel debugger (GUI):
              windbg -z crash.dmp -c "!analyze -v"
              Symbols preconfigured via _NT_SYMBOL_PATH (MS public server + local cache)
  cdb/kd/ntsd Scriptable console debuggers (Windows SDK, Debugging Tools for Windows):
              cdb -z dump.dmp -c ".logopen out.txt; `$`$><script.txt; q"
              kd -z kernel.dmp -c "!analyze -v; q"  (kernel dumps)
              Activated by: bootstrap.ps1 -Only security (after WDK or SDK install)
  poolmon     Live kernel pool-tag monitor (WDK, run elevated):
              poolmon /b /r /n snapshot.txt  (top nonpaged consumers)
              Installed by: install-machine-scope.ps1 + bootstrap.ps1 -Only security

### Local LLM stack (optional - only if installed via scripts\install-llm.ps1)

If present, a local Ollama runtime serves an OpenAI-compatible API entirely on
this machine (nothing leaves the box). Discover it via %TOOLBOX_LLM_URL% (=
http://127.0.0.1:11434/v1); models live in $toolboxRoot\models. Point any OpenAI
client at that base URL for offline / sensitive RAG and inference. CLI: ollama
run <model> / ollama list. Default models are VRAM-tiered (moondream vision,
qwen2.5:3b + mistral:7b text, qwen3-embedding:0.6b embeddings; mistral-small on
24 GB+). A cross-encoder reranker (run via the toolbox Python + onnxruntime) may
be provisioned at $toolboxRoot\scripts\rerank.py. Not installed unless the user
opted in; check 'ollama --version' and %TOOLBOX_LLM_URL% before assuming it.

Smoke test: powershell.exe -ExecutionPolicy Bypass -File '$RepoRoot\scripts\smoke-test.ps1'
"@

    # %USERPROFILE%\CLAUDE.md - picked up via directory walk-up from any path
    # under the user profile (C:\Users\you\...).
    Write-AgentBlock "$env:USERPROFILE\CLAUDE.md"             "WIN_DEVTOOLS" $body

    # %USERPROFILE%\.claude\CLAUDE.md - Claude Code's global config; loaded
    # unconditionally regardless of working directory. Covers D:\, network
    # paths, \\wsl.localhost\..., and any other path outside the profile tree.
    Write-AgentBlock "$env:USERPROFILE\.claude\CLAUDE.md"     "WIN_DEVTOOLS" $body

    Write-AgentBlock "$env:USERPROFILE\AGENTS.md"             "WIN_DEVTOOLS" $body
    $codexAgents = "$env:USERPROFILE\.codex\AGENTS.md"
    Write-AgentBlock $codexAgents "WIN_DEVTOOLS" $body
}
