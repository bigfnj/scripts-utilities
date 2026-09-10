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

# GetRandomFileName, not New-TemporaryFile. New-TemporaryFile CREATES a real zero-byte
# tmpXXXX.tmp and returns it; only its NAME was ever used here, to derive a sibling directory -
# and the cleanup at the bottom removes that DIRECTORY, so the file itself was left behind on
# every single run. Measured: 138 orphaned tmp*.tmp in %TEMP% and climbing. GetRandomFileName
# returns a name without touching the disk, which is all this ever needed.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetRandomFileName()) + '_smoketest')
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
                # Truthiness alone is not detection. A detect string may be a native command,
                # and a FAILING native command still writes to stdout - `winget list --id X -e`
                # prints "No installed package found matching input criteria", which is a
                # non-empty string and therefore truthy. Reset and inspect $LASTEXITCODE so a
                # native failure is caught; a pure PowerShell expression leaves it at 0 and is
                # judged on its result as before.
                $global:LASTEXITCODE = 0
                $detected = Invoke-Expression $t.detect
                if ($LASTEXITCODE -ne 0) { Test-Fail "$($t.name): detection command exited $LASTEXITCODE" }
                elseif ($detected) { Test-Ok "$($t.name) detected ($detected)" }
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
    # $LASTEXITCODE, not try/catch. A native command that RUNS and fails raises no PowerShell
    # exception, so the catch below only ever fires if the process cannot be started at all -
    # which means this check could not fail for the thing it claims to test. Demonstrated:
    # `cmd /c "echo boom 1>&2 & exit 3"` takes the success branch with $LASTEXITCODE = 3.
    try {
        # Collect the WHOLE stream before taking a line. `... | Select-Object -First 1`
        # raises StopUpstreamCommandsException to short-circuit the pipeline, which kills the
        # native process mid-write and leaves $LASTEXITCODE = -1 - so pairing an exit-code
        # check with -First 1 invents a failure for a tool that worked. Found immediately on
        # adding the exit check here: gh reported "exited -1" while being perfectly healthy.
        $vAll = gh --version 2>&1 | Out-String
        $v = ($vAll -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0) { Test-Ok "gh: $v" } else { Test-Fail "gh --version exited $LASTEXITCODE" }
    } catch { Test-Fail "gh --version could not start: $_" }
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
        # This used to write two files, compute a Compare-Object into $diff, never read it, and
        # then run `delta --version`. Delta was never handed a diff: a version probe wearing a
        # diff test's name. Feed it a real unified diff and assert it rendered the changed line.
        # The diff is a literal rather than shelled out to git, so the check tests delta and not
        # git's availability.
        $unified = @"
--- a/a.txt
+++ b/b.txt
@@ -1,2 +1,2 @@
 line one
-line two
+line THREE
"@
        $rendered = $unified | delta --paging=never 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $rendered -match 'THREE') { Test-Ok "delta renders a unified diff" }
        else { Test-Fail "delta did not render the diff (exit $LASTEXITCODE)" }
    } catch { Test-Fail "delta check could not run: $_" }
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
    try {
        # See the gh check: -First 1 on a native command corrupts $LASTEXITCODE.
        $vAll = tshark --version 2>&1 | Out-String
        $v = ($vAll -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0) { Test-Ok "tshark: $v" } else { Test-Fail "tshark --version exited $LASTEXITCODE" }
    } catch { Test-Fail "tshark --version could not start: $_" }
} else { Test-Warn "tshark not present - skipping" }

# cdb: console debugger from Debugging Tools for Windows (Windows SDK via WDK)
# detect-only tool - warn rather than fail if absent
if (Test-CommandAvailable "cdb") {
    try {
        # See the gh check: -First 1 on a native command corrupts $LASTEXITCODE.
        $vAll = cdb -version 2>&1 | Out-String
        $v = ($vAll -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0) { Test-Ok "cdb: $v" } else { Test-Warn "cdb -version exited $LASTEXITCODE" }
    } catch { Test-Warn "cdb present but -version could not start: $_" }
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
        # No trailing `n: Set-Content adds one, and the explicit one made it two, so the
        # fixture violated MD047/MD012 and markdownlint was right to exit 1. The check wants a
        # deliberately clean fixture so that a non-zero exit means something is actually wrong.
        Set-Content "$tmp\test.md" "# Hello`n`nThis is a test."
        # Output was discarded AND the exit code ignored, so this passed whatever markdownlint
        # did. The fixture is deliberately lint-clean, so exit 0 is the correct expectation:
        # a non-zero code here means markdownlint found a problem or failed to run.
        $mdOut = markdownlint "$tmp\test.md" 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { Test-Ok "markdownlint lints a markdown file" }
        else { Test-Fail "markdownlint exited $LASTEXITCODE on a clean fixture: $($mdOut.Trim())" }
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

# -- Deletion forensics --------------------------------------------------------
# Optional sensors, so absence is a WARN not a FAIL. Degradation, however, is a FAIL:
# a sensor that is installed but not actually capturing is worse than one that is absent,
# because it is the one you will rely on and it will have nothing.
#
# Added after 2026-09-09, when a mass profile deletion could not be attributed to anything -
# Sysmon was not installed, File System auditing was off, and the USN journal held under two
# hours. The point of checking it here is that a control nobody verifies is a control that
# quietly stops working.
Test-Hdr "deletion forensics"
$fxSvc = Get-Service -Name 'Sysmon64', 'Sysmon' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $fxSvc) {
    Test-Warn "Sysmon not installed (optional: scripts\install-deletion-forensics.ps1)"
} else {
    if ($fxSvc.Status -eq 'Running') { Test-Ok "Sysmon service running ($($fxSvc.Name))" }
    else { Test-Fail "Sysmon service is $($fxSvc.Status)" }

    # Running now and surviving a restart are different properties. A service flipped to
    # Manual keeps capturing until the next boot and then stops, with nothing to announce it.
    if ($fxSvc.StartType -eq 'Automatic') { Test-Ok "Sysmon starts automatically at boot" }
    else { Test-Fail "Sysmon StartType is $($fxSvc.StartType), not Automatic - it will not capture after a restart" }

    $drvStart = $null
    try {
        $qc = & sc.exe qc SysmonDrv 2>&1 | Out-String
        $m = [regex]::Match($qc, '(?im)START_TYPE\s*:\s*\d+\s+(\S+)')
        if ($m.Success) { $drvStart = $m.Groups[1].Value }
    } catch { }
    if ($drvStart -match 'BOOT_START|SYSTEM_START|AUTO_START') { Test-Ok "SysmonDrv loads at boot ($drvStart)" }
    elseif ($drvStart) { Test-Fail "SysmonDrv START_TYPE is $drvStart - it will not load after a restart" }
    else { Test-Warn "could not read SysmonDrv start type" }

    # The deployed config must still match the repo, or the sensor is watching something
    # nobody reviewed. The repo copy is a TEMPLATE now, so the comparison is against it
    # RENDERED for this profile - and it uses the installer's own renderer rather than
    # restating it. This check and Get-ForensicsHealth's were previously two hand-written
    # copies of one hash comparison; that is how they drift, and one of them being wrong while
    # the other is right is worse than either being wrong alone.
    . (Join-Path $REPO_ROOT (Join-Path 'lib' 'SysmonConfig.ps1'))
    $cfgRepo = Join-Path $REPO_ROOT (Join-Path 'config' 'sysmon-filedelete.xml')
    $cfgLive = Join-Path $env:ProgramData (Join-Path 'Sysmon' 'filedelete-forensics.xml')
    if (-not (Test-Path $cfgLive)) { Test-Warn "no deployed Sysmon config at $cfgLive" }
    elseif (-not (Test-Path $cfgRepo)) { Test-Warn "repo config missing: $cfgRepo" }
    else {
        $want = Get-RenderedSysmonConfig -TemplatePath $cfgRepo -ProfilePath $env:USERPROFILE
        $have = [IO.File]::ReadAllText($cfgLive)
        if ($want -eq $have) { Test-Ok "deployed Sysmon config matches the template rendered for this profile" }
        else { Test-Fail "deployed Sysmon config is stale - re-run install-deletion-forensics.ps1 elevated" }
    }

    # A SEPARATE fact. The deployed file can be a faithful render of an older template AND
    # still name the right profile, or vice versa. Reporting one boolean for both is what let
    # a config that named a nonexistent profile pass as healthy for a year.
    if (Test-Path $cfgLive) {
        $liveText = [IO.File]::ReadAllText($cfgLive)
        if ($liveText -match '\|') { Test-Fail "the deployed config contains an unsubstituted placeholder - the sensor is watching nothing" }
        elseif ($liveText -like "*$($env:USERPROFILE.TrimEnd('\'))*") { Test-Ok "the live rules name this profile" }
        else { Test-Fail "the live rules do NOT name $env:USERPROFILE - the sensor is watching a different user" }
    }
}

# USN is checked independently of Sysmon: it needs no agent and survives Sysmon being stopped.
$usnBytes = $null
try {
    $usnOut = & fsutil usn queryjournal C: 2>&1 | Out-String
    $um = [regex]::Match($usnOut, '(?im)^\s*Maximum Size\s*:\s*0x([0-9a-f]+)')
    if ($um.Success) { $usnBytes = [Convert]::ToInt64($um.Groups[1].Value, 16) }
} catch { }
if ($null -eq $usnBytes) { Test-Warn "could not read the USN journal on C:" }
elseif ($usnBytes -ge 1GB) { Test-Ok ("USN journal {0:N2} GB on C:" -f ($usnBytes / 1GB)) }
else { Test-Warn ("USN journal only {0:N0} MB on C: - hours of history, not days" -f ($usnBytes / 1MB)) }

# The weekly report. A SYSTEM task is ADMIN-ONLY TO VIEW, so unelevated we cannot distinguish
# "missing" from "invisible" - and saying "missing" there would be a check announcing a failure
# it never tested. It did exactly that once, about a task registered seconds earlier.
$fxElevated = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $fxElevated) {
    Test-Warn "weekly forensics report task: not checkable unelevated (SYSTEM tasks are admin-only to view)"
} else {
    $fxTask = Get-ScheduledTask -TaskName 'DeletionForensicsReport' -ErrorAction SilentlyContinue
    if ($fxTask) { Test-Ok "weekly forensics report task registered ($($fxTask.State))" }
    else { Test-Warn "no weekly forensics report task (optional: install-deletion-forensics.ps1)" }
}

# The generator and its renderer must at least parse under 5.1 - the scheduled task runs
# powershell.exe, not pwsh, and a parse error there fails silently at 04:00 on a Sunday.
#
# The parse MUST be delegated to powershell.exe rather than called in-process. [Parser] uses the
# grammar of the HOST it runs in, so this gate checked 5.1 only when the gate itself happened to
# be run under 5.1 - run the smoke test from pwsh, which the repo's own docs suggest for CI
# parity, and the one check whose entire purpose is catching 7-only syntax silently started
# accepting it. `$x ?? 'y'` gives 1 error under 5.1 and 0 under 7; that difference is the check.
$parseProbe = {
    param($Files)
    $bad = @()
    foreach ($f in $Files) {
        $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e)
        if ($e -and $e.Count) { $bad += ('{0}|{1}' -f (Split-Path $f -Leaf), $e[0].Message) }
    }
    $bad -join "`n"
}
$fxFiles = @()
foreach ($fxScript in 'New-ForensicsReport.ps1', 'ForensicsReport.Core.ps1',
                      'ForensicsReport.Render.ps1', 'ForensicsReport.Triage.ps1',
                      'install-deletion-forensics.ps1') {
    $fxPath = Join-Path $PSScriptRoot $fxScript
    if (-not (Test-Path $fxPath)) { Test-Fail "missing $fxScript" } else { $fxFiles += $fxPath }
}
# The renderer/validator lives in lib\, and it is the piece that decides whether the sensor
# watches anything at all - so it is parse-gated under 5.1 like the rest.
$fxLib = Join-Path $REPO_ROOT (Join-Path 'lib' 'SysmonConfig.ps1')
if (-not (Test-Path $fxLib)) { Test-Fail 'missing lib\SysmonConfig.ps1' } else { $fxFiles += $fxLib }
if ($fxFiles.Count) {
    $parseOut = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $parseProbe -Args (,$fxFiles) 2>&1 | Out-String).Trim()
    if ($parseOut) {
        foreach ($line in ($parseOut -split "`r?`n")) {
            $p = $line -split '\|', 2
            Test-Fail ("{0} does not parse under 5.1: {1}" -f $p[0], $p[1])
        }
    } else { Test-Ok ("{0} forensics script(s) parse under Windows PowerShell 5.1" -f $fxFiles.Count) }
}

# Every check in THIS file must be capable of failing.
#
# Six checks here wrapped a native command in try/catch and called Test-Ok unconditionally. A
# native command that runs and exits non-zero raises no PowerShell exception, so the catch only
# fires when the process cannot start - meaning those checks could not fail for the thing they
# claimed to test. Measured: a shim printing a plausible version banner and exiting 3 was
# reported "OK".
#
# The rule targets the exact defect shape: a try block that RENDERS A VERDICT (calls Test-Ok)
# without inspecting an exit code or comparing anything. Such a block reaches Test-Ok on every
# path where the process started at all.
#
# A try that only GATHERS is explicitly fine, and the first draft of this lint was wrong to
# flag it. The SysmonDrv and USN checks below read a native command inside a try and decide
# outside it, with an explicit warn-on-unreadable branch - that is a better pattern than the
# one being outlawed, not a worse one, and a lint that cried wolf about it would be turned off
# within a week.
$selfLint = {
    param($File)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
    $tries = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)
    $bad = @()
    foreach ($t in $tries) {
        $body = $t.Body.Extent.Text
        if ($body -notmatch '\bTest-Ok\b') { continue }          # gathers only; verdict is elsewhere
        $hasExit = $body -match '\$LASTEXITCODE'
        $hasCompare = $body -match '\s-(eq|ne|match|notmatch|like|notlike|gt|lt|ge|le|contains|in|is)\s'
        if (-not ($hasExit -or $hasCompare)) { $bad += $t.Extent.StartLineNumber }
    }
    ($bad -join ',')
}
$lintOut = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $selfLint -Args $PSCommandPath 2>&1 | Out-String).Trim()
if ($lintOut) {
    Test-Fail ("try block(s) at line(s) $lintOut check neither an exit code nor a comparison, so they cannot fail")
} else {
    Test-Ok "every try block in this file inspects an exit code or compares a result"
}

# The forensics report's own suites. Both run WITHOUT Ollama and without reading the real
# Sysmon log, by design: what is worth pinning is that a model claim citing something it was
# never shown gets discarded, and that the rendered page fetches nothing and escapes everything.
# A test whose result depends on what a model says today, or on what happens to be in the event
# log this hour, fails for reasons unrelated to the code.
#
# A MISSING suite is a FAILURE, not a warning. This block previously warned, and separately held
# a path with a literal TAB in it - so it reported "suite not found", stayed green, and verified
# nothing for as long as that went unnoticed. A gate that passes when its tests have vanished is
# not a gate.
foreach ($suite in @(
    @{ Name = 'core';      File = 'tests\Invoke-CoreTests.ps1' },
    @{ Name = 'installer'; File = 'tests\Invoke-InstallerTests.ps1' },
    @{ Name = 'triage';    File = 'tests\Invoke-TriageTests.ps1' },
    @{ Name = 'render';    File = 'tests\Invoke-RenderTests.ps1' }
)) {
    $sPath = Join-Path $REPO_ROOT $suite.File
    if (-not (Test-Path -LiteralPath $sPath)) { Test-Fail "$($suite.Name) test suite missing: $($suite.File)"; continue }
    # powershell.exe explicitly: the scheduled task runs 5.1, so the suites must pass there.
    $tOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sPath 2>&1 | Out-String
    $tLine = ($tOut -split "`r?`n" | Where-Object { $_ -match 'passed,.*failed' } | Select-Object -Last 1)
    if ($tLine -match '(\d+) passed, (\d+) failed') {
        if ([int]$Matches[2] -eq 0) { Test-Ok "$($suite.Name) suite: $($Matches[1]) passed" }
        else { Test-Fail "$($suite.Name) suite: $($Matches[2]) failed" }
    } else { Test-Fail "$($suite.Name) suite produced no tally" }
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
