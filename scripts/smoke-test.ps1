#Requires -Version 5.1
# smoke-test.ps1 - verify the Windows dev toolbox is healthy.
#
# Phase 1: binary-presence check for every tool in the manifest.
# Phase 2: functional checks (encrypt/decrypt, task runner, diff, etc.).
#
# Exit 0 = all core checks passed.  Exit 1 = one or more failures.
# Warnings are informational and do not fail the gate.
[CmdletBinding()]
param()

$REPO_ROOT     = Split-Path $PSScriptRoot
$MANIFEST_PATH = Join-Path $REPO_ROOT "manifest\tools.json"

. (Join-Path $REPO_ROOT "lib\common.ps1")
. (Join-Path $REPO_ROOT "lib\catalog.ps1")
Sync-EnvPath

$Pass = 0; $Fail = 0; $Warn = 0

function Test-Ok   { param([string]$Msg) Write-Host "OK $Msg" -ForegroundColor Green;  $script:Pass++ }
function Test-Fail { param([string]$Msg) Write-Host "FAIL $Msg" -ForegroundColor Red;    $script:Fail++ }
function Test-Warn { param([string]$Msg) Write-Host "WARN $Msg" -ForegroundColor Yellow; $script:Warn++ }
function Test-Hdr  { param([string]$Msg) Write-Host "`n== $Msg ==" -ForegroundColor White }

$tmp = New-TemporaryFile | ForEach-Object { $_.DirectoryName + "\" + $_.BaseName + "_smoketest" }
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {

# -- Phase 1: manifest binary checks ------------------------------------------
Test-Hdr "manifest tools (binary checks)"

if (Test-Path $MANIFEST_PATH) {
    $tools = Get-Content $MANIFEST_PATH -Raw | ConvertFrom-Json
    foreach ($t in $tools) {
        if (Test-CommandAvailable $t.binary) {
            Test-Ok "$($t.name) ($($t.binary))"
        } elseif ($t.install_method -eq "existing" -and $t.detect) {
            try {
                $detected = Invoke-Expression $t.detect
                if ($detected) { Test-Ok "$($t.name) detected ($detected)" }
                else { Test-Fail "$($t.name): detection returned no result" }
            } catch {
                Test-Fail "$($t.name): detection failed: $_"
            }
        } else {
            Test-Fail "$($t.name): '$($t.binary)' not found on PATH"
        }
    }
} else {
    Test-Warn "manifest not found at $MANIFEST_PATH - run bootstrap.ps1 first"
}

# -- Phase 2: functional checks ------------------------------------------------
Test-Hdr "functional checks"

# gh: version responds (auth not required for smoke)
if (Test-CommandAvailable "gh") {
    try { $v = gh --version 2>&1 | Select-Object -First 1; Test-Ok "gh: $v" }
    catch { Test-Fail "gh --version failed" }
} else { Test-Warn "gh not present - skipping" }

# fzf: pipe input through fzf non-interactively
if (Test-CommandAvailable "fzf") {
    try {
        $result = "alpha`nbeta`ngamma" | fzf --filter "bet" 2>&1
        if ($result -match "beta") { Test-Ok "fzf filters input non-interactively" }
        else { Test-Fail "fzf filter returned unexpected: $result" }
    } catch { Test-Fail "fzf functional check failed: $_" }
} else { Test-Warn "fzf not present - skipping" }

# bat: render a temp file with syntax highlighting
if (Test-CommandAvailable "bat") {
    try {
        Set-Content "$tmp\test.py" 'print("ok")'
        $out = bat --plain --no-pager "$tmp\test.py" 2>&1
        if ($out -match 'print') { Test-Ok "bat renders a file" }
        else { Test-Fail "bat output unexpected: $out" }
    } catch { Test-Fail "bat functional check failed: $_" }
} else { Test-Warn "bat not present - skipping" }

# delta: diff two small files
if (Test-CommandAvailable "delta") {
    try {
        Set-Content "$tmp\a.txt" "line one`nline two"
        Set-Content "$tmp\b.txt" "line one`nline THREE"
        $diff = (Compare-Object (Get-Content "$tmp\a.txt") (Get-Content "$tmp\b.txt") | Out-String)
        # delta is a pager; just verify it starts
        $v = delta --version 2>&1
        Test-Ok "delta responds ($v)"
    } catch { Test-Fail "delta check failed: $_" }
} else { Test-Warn "delta not present - skipping" }

# just: run a minimal recipe
if (Test-CommandAvailable "just") {
    try {
        Set-Content "$tmp\justfile" "set shell := ['powershell.exe', '-NoLogo', '-Command']`n`ndefault:`n    Write-Output ok"
        $result = just --justfile "$tmp\justfile" 2>&1
        if ($result -match "ok") { Test-Ok "just runs a local recipe" }
        else { Test-Fail "just recipe returned: $result" }
    } catch { Test-Fail "just functional check failed: $_" }
} else { Test-Warn "just not present - skipping" }

# hyperfine: benchmark a trivial command
if (Test-CommandAvailable "hyperfine") {
    try {
        hyperfine --warmup 1 --runs 3 "echo ok" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Test-Ok "hyperfine benchmarks a command" }
        else { Test-Fail "hyperfine exited non-zero" }
    } catch { Test-Fail "hyperfine check failed: $_" }
} else { Test-Warn "hyperfine not present - skipping" }

# age + sops: encrypt and decrypt a small payload
if ((Test-CommandAvailable "age") -and (Test-CommandAvailable "age-keygen")) {
    try {
        age-keygen -o "$tmp\age.key" 2>&1 | Out-Null
        $pub = (Select-String "public key:" "$tmp\age.key").Line.Split()[-1]
        "ok" | age -r $pub -o "$tmp\plain.age" 2>&1 | Out-Null
        $dec = age -d -i "$tmp\age.key" "$tmp\plain.age" 2>&1
        if ($dec.Trim() -eq "ok") { Test-Ok "age encrypts and decrypts" }
        else { Test-Fail "age decrypt returned: $dec" }

        if (Test-CommandAvailable "sops") {
            Set-Content "$tmp\plain.yaml" "secret: ok"
            $env:SOPS_AGE_KEY_FILE = "$tmp\age.key"
            sops --encrypt --age $pub "$tmp\plain.yaml" > "$tmp\enc.yaml" 2>&1
            $plain = sops --decrypt "$tmp\enc.yaml" 2>&1
            if ($plain -match "secret: ok") { Test-Ok "sops encrypts and decrypts YAML with age" }
            else { Test-Fail "sops decrypt returned: $plain" }
            Remove-Item Env:\SOPS_AGE_KEY_FILE -ErrorAction SilentlyContinue
        } else { Test-Warn "sops not present - skipping encrypted-config check" }
    } catch { Test-Fail "age/sops check failed: $_" }
} else { Test-Warn "age not present - skipping encryption checks" }

# tshark: version responds
if (Test-CommandAvailable "tshark") {
    try { $v = tshark --version 2>&1 | Select-Object -First 1; Test-Ok "tshark: $v" }
    catch { Test-Fail "tshark --version failed" }
} else { Test-Warn "tshark not present - skipping" }

# cdb: console debugger from Debugging Tools for Windows (Windows SDK via WDK)
# detect-only tool - warn rather than fail if absent
if (Test-CommandAvailable "cdb") {
    try { $v = cdb -version 2>&1 | Select-Object -First 1; Test-Ok "cdb: $v" }
    catch { Test-Warn "cdb present but -version failed: $_" }
} else { Test-Warn "cdb not present - run '.\bootstrap.ps1 -Only security' after WDK/SDK install" }

# poolmon: pool-tag monitor from the WDK
# detect-only tool - warn rather than fail if absent; needs elevation to run usefully
if (Test-CommandAvailable "poolmon") {
    Test-Ok "poolmon present (WDK)"
} else { Test-Warn "poolmon not present - run 'install-machine-scope.ps1' then '.\bootstrap.ps1 -Only security'" }

# tokei: count lines in a temp file
if (Test-CommandAvailable "tokei") {
    try {
        Set-Content "$tmp\counter.py" "x = 1`ny = 2`nz = 3"
        $out = tokei "$tmp" 2>&1 | Out-String
        if ($out -match "Python") { Test-Ok "tokei counts lines of code" }
        else { Test-Fail "tokei output unexpected: $out" }
    } catch { Test-Fail "tokei check failed: $_" }
} else { Test-Warn "tokei not present - skipping" }

# markdownlint: lint a minimal markdown file
if (Test-CommandAvailable "markdownlint") {
    try {
        Set-Content "$tmp\test.md" "# Hello`n`nThis is a test.`n"
        markdownlint "$tmp\test.md" 2>&1 | Out-Null
        Test-Ok "markdownlint lints a markdown file"
    } catch { Test-Fail "markdownlint check failed: $_" }
} else { Test-Warn "markdownlint not present - skipping" }

# Toolbox Python libs: frida, jupyterlab, sqlite_utils, csvkit, pytoshop
$py = Get-ToolboxPython
if ($py) {
    $libs = @(
        @{ pkg="frida";       import="frida"       },
        @{ pkg="jupyterlab";  import="jupyterlab"  },
        @{ pkg="sqlite-utils"; import="sqlite_utils"},
        @{ pkg="csvkit";      import="csvkit"      },
        @{ pkg="pytoshop";    import="pytoshop"    }
    )
    $missing = @()
    foreach ($l in $libs) {
        & $py -c "import $($l.import)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $missing += $l.pkg }
    }
    if ($missing.Count -eq 0) { Test-Ok "toolbox venv: frida, jupyterlab, sqlite-utils, csvkit, pytoshop all importable" }
    else { Test-Fail "toolbox venv missing: $($missing -join ', ')" }
} else {
    Test-Warn "dev toolbox Python not found - skipping toolbox venv checks (set CODEX_TOOLBOX)"
}

# -- Toolbox PATH readiness ----------------------------------------------------
# The durable toolbox layer must be resolvable by bare name in a fresh shell
# (bootstrap.ps1 registers these on the user PATH). Only assert when the toolbox
# actually exists on this machine.
Test-Hdr "toolbox PATH readiness"
$tbRoot = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
if (Test-Path $tbRoot) {
    $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $nativeBin = Join-Path $tbRoot 'native\bin'
    if (Test-Path $nativeBin) {
        $onUser = @($userPath -split ';' | Where-Object { $_.TrimEnd('\') -ieq $nativeBin.TrimEnd('\') })
        $onMachine = @($machinePath -split ';' | Where-Object { $_.TrimEnd('\') -ieq $nativeBin.TrimEnd('\') })
        # Machine scope is what makes the toolbox visible to shells that inherit the machine PATH
        # only - which some agent hosts do. User-only is the state that silently hides every tool
        # from exactly the audience this repo exists to serve.
        if ($onMachine.Count -gt 0) { Test-Ok "MACHINE PATH includes native\bin (visible to machine-PATH-only shells)" }
        elseif ($onUser.Count -gt 0) { Test-Warn "native\bin is on the USER PATH only - invisible to shells that inherit machine PATH only (run .\scripts\consolidate-path.ps1 elevated)" }
        else { Test-Fail "PATH missing native\bin: $nativeBin (run .\bootstrap.ps1)" }
    }

    # PATH length. Windows hands a spawned process a bounded environment block, and a PATH past
    # that bound is truncated MID-ENTRY with no error at all. Measured on the reference box: a
    # 4363-char machine PATH arrived as exactly 4095, ending "C:\Users\Admin\AppD", which quietly
    # removed git and the whole sysinternals layer. Assert headroom rather than wait for it.
    $combined = ($machinePath.TrimEnd(';') + ';' + $userPath.TrimEnd(';'))
    if ($combined.Length -ge 4095)  { Test-Fail "PATH is $($combined.Length) chars - at or past the 4095 truncation point; entries WILL be silently dropped (run .\scripts\consolidate-path.ps1)" }
    elseif ($combined.Length -ge 3500) { Test-Warn "PATH is $($combined.Length) chars - close to the 4095 truncation point" }
    else { Test-Ok "PATH is $($combined.Length) chars, clear of the 4095 truncation point" }

    # Stale shims. A winget upgrade moves a version-stamped package folder, so a generated wrapper
    # keeps resolving by name and then fails on execution. A wrapper whose target is gone is worse
    # than a missing wrapper, because the tool looks installed.
    if (Test-Path $nativeBin) {
        $stale = @()
        foreach ($w in Get-ChildItem -LiteralPath $nativeBin -Filter '*.cmd' -File -ErrorAction SilentlyContinue) {
            $line = Get-Content -LiteralPath $w.FullName -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^"([^"]+)" %\*$' } | Select-Object -First 1
            if ($line -and $line -match '^"([^"]+)" %\*$') {
                if (-not (Test-Path -LiteralPath $Matches[1])) { $stale += "$($w.BaseName) -> $($Matches[1])" }
            }
        }
        if ($stale.Count -eq 0) { Test-Ok "all native\bin shims resolve to an existing target" }
        else {
            Test-Fail "$($stale.Count) stale shim(s) - target no longer exists (re-run .\scripts\consolidate-path.ps1):"
            $stale | Select-Object -First 8 | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
        }
    }
    # The venv Scripts dir must NOT be on the persistent PATH - it holds python.exe,
    # and a 3.11 interpreter on PATH is what trips compliance scanners.
    $venvScripts = Join-Path $tbRoot 'python\.venv\Scripts'
    $venvOnPath = @($userPath -split ';' | Where-Object { $_.TrimEnd('\') -ieq $venvScripts.TrimEnd('\') })
    if ($venvOnPath.Count -gt 0) { Test-Fail "venv Scripts is on the persistent PATH - exposes python.exe (should be off PATH)" }
    else { Test-Ok "venv Scripts kept off persistent PATH (3.11 interpreter not exposed)" }
    # The toolbox Python must be discoverable via TOOLBOX_PYTHON instead.
    $venvPython = Join-Path $tbRoot 'python\.venv\Scripts\python.exe'
    if (Test-Path $venvPython) {
        $tp = [System.Environment]::GetEnvironmentVariable('TOOLBOX_PYTHON', 'User')
        if ($tp -and ($tp.TrimEnd('\') -ieq $venvPython.TrimEnd('\'))) { Test-Ok "TOOLBOX_PYTHON persisted" }
        else { Test-Fail "TOOLBOX_PYTHON not set - tools cannot locate the toolbox Python 3.11" }
    }
    $tess = Join-Path $tbRoot 'native\tesseract\tessdata'
    if (Test-Path $tess) {
        $tpx = [System.Environment]::GetEnvironmentVariable('TESSDATA_PREFIX', 'User')
        if ($tpx -and ($tpx.TrimEnd('\') -ieq $tess.TrimEnd('\'))) { Test-Ok "TESSDATA_PREFIX persisted" }
        else { Test-Warn "TESSDATA_PREFIX not persisted - OCR language data may not resolve" }
    }
} else {
    Test-Warn "DevToolbox not found at $tbRoot - skipping PATH readiness checks"
}

# -- Catalog integrity ---------------------------------------------------------
# The catalog is the source of truth for the gap-fill modules; a malformed entry
# would silently drop a tool from installs, so structurally validate it.
Test-Hdr "catalog integrity"
try {
    $catalog = Get-Catalog
    $validChannels = @('winget-user', 'winget-machine', 'winget-default', 'pip-toolbox', 'npm-global')
    $problems = @()
    foreach ($t in $catalog.tools) {
        if (-not $t.name)  { $problems += "a tool has no 'name'"; continue }
        if (-not $t.group) { $problems += "$($t.name): missing 'group'" }
        if ($t.channel -notin $validChannels) { $problems += "$($t.name): invalid channel '$($t.channel)'" }
        if (-not $t.id)    { $problems += "$($t.name): missing 'id'" }
        $optOut = ($t.PSObject.Properties.Name -contains 'register_manifest') -and ($t.register_manifest -eq $false)
        if (-not $t.binary -and -not $optOut) { $problems += "$($t.name): no 'binary' and not register_manifest=false" }
    }
    if (-not $catalog.machine_scope_ids -or @($catalog.machine_scope_ids).Count -eq 0) {
        $problems += "machine_scope_ids is empty"
    }
    if ($problems.Count -eq 0) { Test-Ok "catalog.json valid ($(@($catalog.tools).Count) tools)" }
    else { $problems | ForEach-Object { Test-Fail "catalog: $_" } }
} catch {
    Test-Fail "catalog.json failed to load: $_"
}

} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# -- Summary -------------------------------------------------------------------
Test-Hdr "summary"
Write-Host "$Pass passed, $Warn warnings, $Fail failed"
if ($Fail -gt 0) {
    Write-Host "SMOKE TEST FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "smoke test passed" -ForegroundColor Green
exit 0
