# security - RE, debugging, and dynamic analysis tools.
#
# Wireshark (includes tshark CLI), optional Ghidra (NSA RE suite), frida (dynamic
# instrumentation - installed into the dev toolbox venv so it uses the
# correct Python runtime; analyzing Windows targets requires the Windows build),
# and WinDbg + a Microsoft symbol-server path for diagnosing Windows crash dumps.
#
# binwalk and foremost are intentionally omitted - firmware carving is a
# WSL-native workflow with no good Windows equivalents.

# Printed by 'bootstrap.ps1 -List' and by get.ps1 - i.e. BEFORE the user agrees to
# anything - so it must not advertise installs this module does not perform. It used
# to read as though WinDbg, the WDK/poolmon, cdb/kd/ntsd and Ghidra were all
# installed here; only WinDbg is. The rest are detected on the machine and wrapped
# into native\bin, which is a very different consent question (nothing is downloaded,
# and if they are absent you get a warning, not a tool).
function security_desc { "installs Wireshark (tshark), etl2pcapng, WinDbg + MS symbol server, frida (toolbox venv); detects and wraps only: cdb/kd/ntsd, poolmon (WDK), Ghidra, Npcap; reports deletion-forensics health (Sysmon + USN)" }

function security_install {
    # Failure count for the catalog-driven installs in this group. They were each
    # piped to Out-Null, so "security group complete" printed even when all of them
    # failed. $attempted rather than a literal 3, because TOOLBOX_SKIP_WIRESHARK
    # legitimately removes one of them.
    $failed = 0
    $attempted = 0
    # Wireshark/tshark (catalog: winget-machine) - needs elevation, so it's
    # opt-out: set TOOLBOX_SKIP_WIRESHARK=1 (a User env var) to skip it
    # permanently without editing anything. Install-CatalogItem handles the
    # ProgramFiles\Wireshark PATH fallback and manifest recording.
    if ($env:TOOLBOX_SKIP_WIRESHARK) {
        Write-Skip "Wireshark/tshark skipped (TOOLBOX_SKIP_WIRESHARK set)"
    } else {
        # Note: installer may prompt to install Npcap; accept it for live capture.
        $attempted++
        if (-not (Install-CatalogItem -Item (Get-CatalogItem -Name "tshark"))) {
            $failed++
            Write-Warn "install failed: tshark (Wireshark)"
        }
        if (-not (Test-CommandAvailable "tshark")) {
            Write-Warn "Wireshark installed, but tshark.exe was not found on PATH"
        }
    }

    # Npcap = the live-capture driver for 'tshark -i'. No winget package (license
    # blocks redistribution), so it is a documented optional dependency, not an
    # auto-install - see security_register_npcap. etl2pcapng (catalog: winget-user)
    # gives a channel-compliant, driver-free capture path (pktmon -> etl2pcapng
    # -> tshark).
    security_register_npcap
    $attempted++
    if (-not (Install-CatalogItem -Item (Get-CatalogItem -Name "etl2pcapng"))) {
        $failed++
        Write-Warn "install failed: etl2pcapng"
    }
    if (-not (Test-CommandAvailable "etl2pcapng")) {
        Write-Warn "etl2pcapng installed but not visible on PATH in this session"
    }

    # Ghidra - NSA reverse-engineering suite. Detected/wrapped only (no winget
    # package); provision with scripts\install-ghidra.ps1.
    security_install_ghidra

    # WinDbg + Microsoft symbol server - the Windows crash-dump / live user+kernel
    # debugger, plus _NT_SYMBOL_PATH so !analyze can resolve OS symbols.
    security_install_debugger

    # WDK (Windows Driver Kit) - provides poolmon.exe for live pool-tag analysis
    # without needing a crash dump. Machine-scope, ~1-2 GB. Opt-out: set
    # TOOLBOX_SKIP_WDK=1 as a user env var.
    security_install_wdk

    # Console debuggers (cdb/kd/ntsd) - from the Windows SDK's Debugging Tools
    # component. Not shipped with the WinDbg store app. Detect-and-wrap: may
    # already be present after WDK or SDK install.
    security_install_console_debuggers

    # frida-tools (catalog: pip-toolbox) - dynamic instrumentation. Installed into
    # the toolbox venv because frida's Python binding must match the target Python.
    $attempted++
    if (-not (Install-CatalogItem -Item (Get-CatalogItem -Name "frida"))) {
        $failed++
        Write-Warn "install failed: frida (toolbox venv)"
    }

    # Deletion forensics (Sysmon + a resized USN journal). Detect-and-report only, like
    # Ghidra: it installs a kernel driver and needs elevation, so it stays an explicit
    # opt-in helper rather than something a bootstrap run does to you.
    security_report_deletion_forensics

    # Only the three catalog installs above are counted. The detect-and-wrap helpers
    # warn for themselves and a missing WDK/Ghidra/Npcap is not an install failure.
    if ($failed -eq 0) {
        Write-Ok "security group complete"
    } else {
        Write-Err "security group INCOMPLETE: $failed of $attempted catalog install(s) failed (see the warnings above)"
    }
    # RETURNED, not just printed. Write-Err is Write-Host - it produces no error
    # record - so a caller has no way to know this group failed unless the count
    # travels. Without this, bootstrap.ps1 printed "bootstrap complete" after a run
    # in which every single install failed.
    return $failed
}

function security_report_deletion_forensics {
    <#
        Report whether deletion forensics are present and healthy, and point at the installer
        if not. Deliberately does NOT install: scripts\install-deletion-forensics.ps1 loads a
        BOOT_START kernel driver and resizes an NTFS structure, which is not something a
        general "bootstrap the toolbox" run should do without being asked.

        Exists because the sensors are only useful if someone notices when they stop. They were
        added after a mass profile deletion on 2026-09-09 that could not be attributed to
        anything, because nothing on the machine was recording who deletes what.
    #>
    $svc = Get-Service -Name 'Sysmon64', 'Sysmon' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $svc) {
        Write-Skip "deletion forensics not installed (scripts\install-deletion-forensics.ps1)"
        return
    }

    $problems = @()
    if ($svc.Status -ne 'Running')      { $problems += "service $($svc.Status)" }
    # Running now and running after a restart are different properties; a service flipped to
    # Manual keeps working until the next boot and then silently stops capturing.
    if ($svc.StartType -ne 'Automatic') { $problems += "StartType $($svc.StartType), not Automatic" }

    $usn = $null
    try {
        $out = & fsutil usn queryjournal C: 2>&1 | Out-String
        $m = [regex]::Match($out, '(?im)^\s*Maximum Size\s*:\s*0x([0-9a-f]+)')
        if ($m.Success) { $usn = [Convert]::ToInt64($m.Groups[1].Value, 16) }
    } catch { }
    # 1 GB floor: below that the journal holds hours, not the days an investigation needs.
    if ($null -eq $usn)      { $problems += "USN journal unreadable on C:" }
    elseif ($usn -lt 1GB)    { $problems += ("USN journal only {0:N0} MB on C:" -f ($usn / 1MB)) }

    if ($problems.Count) {
        Write-Warn ("deletion forensics degraded: " + ($problems -join '; '))
        Write-Info "repair with: .\scripts\install-deletion-forensics.ps1"
    } else {
        Write-Skip ("deletion forensics healthy (Sysmon + {0:N2} GB USN journal)" -f ($usn / 1GB))
    }
}

function security_install_debugger {
    # WinDbg - Microsoft's crash-dump / live user- and kernel-mode debugger. Shipped
    # as an MSIX app in winget, so it installs at user scope without elevation.
    #
    # PROBE FIRST, because provenance cannot be recovered afterwards:
    # Install-WingetTool returns $true for three different outcomes (binary already
    # on PATH / winget already lists it / we really did install it). Getting this
    # wrong has teeth - WinDbg is the only entry this module records with
    # install_method 'winget', and uninstall-toolbox.ps1 -RemoveWingetTools
    # winget-uninstalls exactly those when installed_by_toolbox is true. The
    # detect-only registrations below (Ghidra, poolmon, npcap) are protected by
    # install_method 'existing'; WinDbg is not, so a WinDbg the toolbox merely FOUND
    # would be uninstalled out from under its owner.
    #
    # 'WinDbgX' or 'winget list' - never Test-CommandAvailable 'windbg': a previous
    # bootstrap run wrote its own native\bin\windbg.cmd wrapper, and
    # security_install_console_debuggers wraps the classic SDK windbg.exe under the
    # same name, so 'windbg' answers for a package that is not installed. 'WinDbgX'
    # is the MSIX alias and nothing in this repo ever creates it.
    #
    # On a re-run this probe necessarily says "pre-existing" about a WinDbg the
    # toolbox installed last time; Add-WinManifest handles that by never downgrading
    # a recorded true back to false.
    $preexisting = $false
    if (-not $script:DryRun) {
        if (Test-CommandAvailable "WinDbgX") {
            $preexisting = $true
        } elseif (Test-CommandAvailable "winget") {
            $listed = winget list --id Microsoft.WinDbg -e --accept-source-agreements 2>&1
            $preexisting = ($LASTEXITCODE -eq 0) -and ($listed -match [regex]::Escape("Microsoft.WinDbg"))
        }
    }
    Install-WingetTool -Id "Microsoft.WinDbg" -Binary "WinDbgX" -Name "WinDbg" | Out-Null

    # Resolve the launcher the MSIX put on PATH (a WindowsApps alias) and wrap it as
    # `windbg` in native\bin, so it is invocable by a stable name and the smoke test
    # can find it. MSIX aliases can need a fresh shell to appear; if it is not visible
    # yet, skip recording it rather than register a binary the smoke test can't see.
    $dbg = $null
    foreach ($n in @("WinDbgX", "windbg")) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $dbg = $cmd.Source; break }
    }
    if ($dbg) {
        $root   = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
        $binDir = Join-Path $root "native\bin"
        if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
        if ($script:DryRun) {
            Write-Info "[DRY-RUN] wrapper windbg -> $dbg"
        } else {
            # New-ShimBody (lib\ShimFormat.ps1), not a local string: this module held four of the
            # seven places that each carried their own copy of the .cmd byte shape, and a wrapper
            # whose bytes drift stops being readable by the smoke test's stale-shim check - which
            # then reports every healthy shim as neither stale nor present. (lib\common.ps1 and
            # scripts\build-devtoolbox.ps1 still hold theirs as of this commit; they are being
            # converted in parallel.)
            #
            # ALREADY IN SCOPE, verified rather than assumed: this file dot-sources nothing, but
            # bootstrap.ps1:412 dot-sources it into ITS scope, and bootstrap.ps1:27 loaded
            # lib\common.ps1, which loads lib\ShimFormat.ps1 at :19. Adding a dot-source here
            # would be a second, divergent load path for the same two functions.
            #
            # -NoNewline is load-bearing and is the whole reason the bytes did not move.
            # New-ShimBody's string already ENDS in CRLF; Set-Content without -NoNewline appends
            # its own (measured under 5.1: the old  "...%*"  wrote tail 22 20 25 2A 0D 0A), so
            # dropping it would append a THIRD line. Proven byte-identical on a TEMP fixture for
            # all four writers, and the live native\bin\windbg.cmd on this box - the only one of
            # the four whose target is installed - reproduces at 80 B exactly.
            New-ShimBody -Target $dbg | Set-Content -Path (Join-Path $binDir "windbg.cmd") -Encoding ASCII -NoNewline
            Write-Ok "windbg -> $dbg"
        }
        Sync-EnvPath
        Add-WinManifest -Name "WinDbg" -Binary "windbg" -Group "security" -Method "winget" `
            -Detect "winget list --id Microsoft.WinDbg -e" -WingetId "Microsoft.WinDbg" `
            -Notes "Windows crash-dump/live debugger; e.g. windbg -z crash.dmp -c '!analyze -v'. Symbols via _NT_SYMBOL_PATH; capture dumps with procdump (Sysinternals)" `
            -InstalledByToolbox:(-not $preexisting)
    } else {
        Write-Warn "WinDbg installed but its launcher is not on PATH yet - open a new shell and re-run '.\bootstrap.ps1 -Only security' to register it"
    }

    security_configure_symbols
}

function security_configure_symbols {
    # Point the Windows debuggers (WinDbg, cdb, procdump post-mortem, Visual Studio)
    # at Microsoft's public symbol server with a local cache, so !analyze can resolve
    # OS symbols. Persisted as a User env var and applied to the current session.
    $root  = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
    $cache = Join-Path $root "symbols"
    if (-not (Test-Path $cache)) {
        if ($script:DryRun) { Write-Info "[DRY-RUN] would create symbol cache: $cache" }
        else { New-Item -ItemType Directory -Path $cache -Force | Out-Null }
    }
    $symPath = "srv*$cache*https://msdl.microsoft.com/download/symbols"
    $current = [System.Environment]::GetEnvironmentVariable("_NT_SYMBOL_PATH", "User")
    if ($current -eq $symPath) {
        Write-Skip "_NT_SYMBOL_PATH already configured"
    } elseif ($script:DryRun) {
        Write-Info "[DRY-RUN] would set User _NT_SYMBOL_PATH=$symPath"
    } else {
        [System.Environment]::SetEnvironmentVariable("_NT_SYMBOL_PATH", $symPath, "User")
        Write-Ok "_NT_SYMBOL_PATH -> $symPath"
    }
    $env:_NT_SYMBOL_PATH = $symPath
}

function security_install_ghidra {
    # Ghidra has no winget package - it ships as a GitHub release ZIP (needs JDK 21+)
    # and can be extracted anywhere, so we don't hard-code Program Files. Find-GhidraInstall
    # honors $GHIDRA_INSTALL_DIR then searches common roots, validating by ghidraRun.bat.
    # We don't auto-download it from bootstrap; the explicit verified helper does.
    $existing = Find-GhidraInstall
    if ($existing) {
        Write-Skip "Ghidra found at $($existing.FullName)"

        # Pin GHIDRA_INSTALL_DIR (Ghidra's own convention - analyzeHeadless and scripts
        # read it) so it's stable for the user and future detection is instant.
        if ([System.Environment]::GetEnvironmentVariable("GHIDRA_INSTALL_DIR", "User") -ne $existing.FullName) {
            if (-not $script:DryRun) {
                [System.Environment]::SetEnvironmentVariable("GHIDRA_INSTALL_DIR", $existing.FullName, "User")
            }
            Write-Ok "GHIDRA_INSTALL_DIR -> $($existing.FullName)"
        }
        $env:GHIDRA_INSTALL_DIR = $existing.FullName

        $root   = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
        $binDir = Join-Path $root "native\bin"
        if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

        # Ghidra 12.x needs a JDK 21+. Prefer a portable JDK bundled in the toolbox
        # (native\jdk-*), else an existing JAVA_HOME. The wrappers set JAVA_HOME for
        # Ghidra ONLY (no global change), so Ghidra never depends on a system/registered
        # JDK - keeping the toolbox self-contained and compliance-clean.
        $jdk = Get-ChildItem (Join-Path $root "native") -Filter "jdk-*" -Directory -ErrorAction SilentlyContinue |
               Where-Object { Test-Path (Join-Path $_.FullName "bin\java.exe") } |
               Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
        if (-not $jdk -and $env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) { $jdk = $env:JAVA_HOME }
        # A LIST OF WHOLE LINES now, not a pre-terminated string spliced into the middle of a
        # format literal. That splice is what made this the only writer whose shape could drift
        # independently: the CRLF lived in $jdkLine, so the three-line and two-line cases were two
        # different byte contracts maintained by one expression. New-ShimBody -Prologue exists for
        # exactly this caller and inserts the line after `@echo off`, never into the target line,
        # so Get-ShimTarget's "first line that matches" scan keeps finding ghidraRun.bat.
        # Empty list = the no-JDK branch, which emits the plain two-line wrapper.
        $jdkPrologue = if ($jdk) { @("set `"JAVA_HOME=$jdk`"") } else { @() }

        # Wrap ghidraRun + analyzeHeadless into native\bin so they are on the toolbox
        # PATH (invocable by name, and the smoke test's binary check for ghidraRun passes).
        $launchers = [ordered]@{
            "ghidraRun"       = (Join-Path $existing.FullName "ghidraRun.bat")
            "analyzeHeadless" = (Join-Path $existing.FullName "support\analyzeHeadless.bat")
        }
        foreach ($name in $launchers.Keys) {
            $target = $launchers[$name]
            if (-not (Test-Path $target)) { Write-Warn "Ghidra launcher missing: $target"; continue }
            if ($script:DryRun) {
                Write-Info "[DRY-RUN] wrapper $name -> $target"
            } else {
                # -NoNewline: see the note at the windbg writer above. Measured both branches on a
                # TEMP fixture - 132 B with a JDK, 61 B without - against what the old expression
                # emitted: identical, byte for byte.
                New-ShimBody -Target $target -Prologue $jdkPrologue |
                    Set-Content -Path (Join-Path $binDir "$name.cmd") -Encoding ASCII -NoNewline
                Write-Ok "$name -> $target"
            }
        }
        Sync-EnvPath
        if ($jdk) {
            Write-Ok "Ghidra JDK -> $jdk"
        } else {
            Write-Warn "Ghidra needs a JDK 21+ and none was found. Provision a portable one into $root\native\jdk-21 (no admin) - see docs/agent-rules.md"
        }

        # Version comes from the folder name (e.g. ghidra_12.1.2_PUBLIC); never launch
        # the GUI just to probe a version.
        # -InstalledByToolbox:$false is the measurement, not a formality: this branch
        # only runs when Find-GhidraInstall FOUND a copy. The parameter defaults to
        # $true, so omitting it recorded every detected tool as toolbox-installed -
        # an assertion the code had no basis for.
        Add-WinManifest -Name "Ghidra" -Binary "ghidraRun" -Group "security" -Method "existing" `
            -Scope "toolbox" `
            -Detect "'$($existing.Name)'" `
            -Notes "NSA RE suite ($($existing.FullName)); ghidraRun = GUI, analyzeHeadless = headless" `
            -InstalledByToolbox:$false
        return
    }
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] would: skip Ghidra (no winget package; documented manual install)"
        return
    }
    Write-Warn "Ghidra not found. Run '.\scripts\install-ghidra.ps1', then rerun '.\bootstrap.ps1 -Only security'; or set GHIDRA_INSTALL_DIR for an existing copy."
}

function Find-GhidraInstall {
    # Return the DirectoryInfo of the Ghidra folder that holds ghidraRun.bat, or $null.
    # Order: $GHIDRA_INSTALL_DIR (process then persisted User), then common install
    # roots. Validates by ghidraRun.bat and handles the common double-nested extraction
    # (ghidra_x\ghidra_x\ghidraRun.bat). Prefers the highest version name.
    foreach ($ov in @($env:GHIDRA_INSTALL_DIR,
                       [System.Environment]::GetEnvironmentVariable("GHIDRA_INSTALL_DIR", "User"))) {
        if ($ov -and (Test-Path (Join-Path $ov "ghidraRun.bat"))) { return (Get-Item -LiteralPath $ov) }
    }

    $toolboxRoot = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
    $roots = @(
        $env:ProgramFiles, ${env:ProgramFiles(x86)},
        (Join-Path $env:LOCALAPPDATA "Programs"), $env:LOCALAPPDATA,
        $env:USERPROFILE, (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "Desktop"),
        (Join-Path $toolboxRoot "native"), "C:\Tools", "C:\"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    foreach ($root in $roots) {
        $cands = Get-ChildItem -LiteralPath $root -Filter "ghidra_*" -Directory -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending
        foreach ($c in $cands) {
            if (Test-Path (Join-Path $c.FullName "ghidraRun.bat")) { return $c }
            $inner = Get-ChildItem -LiteralPath $c.FullName -Filter "ghidra_*" -Directory -ErrorAction SilentlyContinue |
                     Where-Object { Test-Path (Join-Path $_.FullName "ghidraRun.bat") } |
                     Sort-Object Name -Descending | Select-Object -First 1
            if ($inner) { return $inner }
        }
    }
    return $null
}

function security_install_wdk {
    # Windows Driver Kit - provides poolmon.exe (live pool-tag analysis), cdb/kd/
    # ntsd, gflags, and the full WDK headers/libs. Machine-scope (~1-2 GB); the
    # winget manifest for this package does NOT support --scope machine (fails
    # 0x8A150010), so it must be pre-installed via scripts\install-machine-scope.ps1
    # running as SYSTEM/TrustedInstaller BEFORE normal bootstrap. bootstrap.ps1 then
    # detects it present here and proceeds to wrap the binaries.
    # Opt-out: set TOOLBOX_SKIP_WDK=1 as a user env var to skip wrapping entirely.
    if ($env:TOOLBOX_SKIP_WDK) {
        Write-Skip "WDK skipped (TOOLBOX_SKIP_WDK set)"
        return
    }
    security_wrap_poolmon
}

function security_wrap_poolmon {
    # Detect poolmon.exe from a WDK install and wrap it into native\bin.
    # WDK 10.0.26100 places poolmon in a versioned subdir:
    #   Tools\10.0.26100.0\x64\poolmon.exe
    # Search versioned subdirs descending, fall back to a flat Tools\<arch> path.
    $arch = if ([System.Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    $poolmonPath = $null
    foreach ($kitRoot in @("${env:ProgramFiles(x86)}\Windows Kits\10", "$env:ProgramFiles\Windows Kits\10")) {
        $toolsBase = Join-Path $kitRoot "Tools"
        if (-not (Test-Path $toolsBase)) { continue }
        # Versioned subdir first (e.g. Tools\10.0.26100.0\x64\poolmon.exe)
        $versioned = Get-ChildItem -LiteralPath $toolsBase -Filter "10.0.*" -Directory `
                         -ErrorAction SilentlyContinue |
                     Sort-Object Name -Descending |
                     ForEach-Object { Join-Path $_.FullName "$arch\poolmon.exe" } |
                     Where-Object { Test-Path $_ } |
                     Select-Object -First 1
        if ($versioned) { $poolmonPath = $versioned; break }
        # Flat layout fallback (older WDK versions)
        $flat = Join-Path $toolsBase "$arch\poolmon.exe"
        if (Test-Path $flat) { $poolmonPath = $flat; break }
    }
    $poolmonPath = $poolmonPath | Select-Object -First 1
    if (-not $poolmonPath) {
        Write-Warn "poolmon.exe not found - open a new shell and rerun '.\bootstrap.ps1 -Only security' after WDK installs, or set TOOLBOX_SKIP_WDK=1 to skip"
        return
    }
    $root   = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
    $binDir = Join-Path $root "native\bin"
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
    if ($script:DryRun) {
        Write-Info "[DRY-RUN] wrapper poolmon -> $poolmonPath"
    } else {
        # -NoNewline: see the note at the windbg writer. Measured identical at 91 B.
        New-ShimBody -Target $poolmonPath | Set-Content -Path (Join-Path $binDir "poolmon.cmd") -Encoding ASCII -NoNewline
        Write-Ok "poolmon -> $poolmonPath"
    }
    Sync-EnvPath
    # Detected, not installed: this function only wraps a poolmon.exe the WDK already
    # put on disk (install-machine-scope.ps1 does the installing, as SYSTEM).
    Add-WinManifest -Name "poolmon" -Binary "poolmon" -Group "security" -Method "existing" `
        -Scope "machine" `
        -Detect "'$poolmonPath'" `
        -Notes "Windows pool-tag monitor (WDK); top pool consumers without a crash dump. Run elevated: poolmon /b (sort by bytes) /r (nonpaged) - see docs/tools-reference.md" `
        -InstalledByToolbox:$false
}

function Find-DebuggersInstall {
    # Return the path of the Debuggers\<arch> directory that contains cdb.exe,
    # or $null. Checks WINDBG_DEBUGGERS_PATH (process then User scope) first,
    # then the two standard Windows Kits roots.
    $arch = if ([System.Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    foreach ($ov in @($env:WINDBG_DEBUGGERS_PATH,
                       [System.Environment]::GetEnvironmentVariable("WINDBG_DEBUGGERS_PATH", "User"))) {
        if ($ov -and (Test-Path (Join-Path $ov "cdb.exe"))) { return $ov }
    }
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\$arch",
        "$env:ProgramFiles\Windows Kits\10\Debuggers\$arch"
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "cdb.exe")) { return $c }
    }
    return $null
}

function security_install_console_debuggers {
    # cdb.exe (user-mode), kd.exe (kernel-mode), and ntsd.exe ship in the
    # "Debugging Tools for Windows" component of the Windows SDK - NOT with the
    # WinDbg store app (WinDbgX). The WDK installer typically pulls in a matching
    # SDK, so these often appear as a side effect of security_install_wdk.
    # If not found, document the manual SDK install path and return.
    $dbgDir = Find-DebuggersInstall
    if (-not $dbgDir) {
        Write-Warn "Console debuggers (cdb/kd/ntsd) not found"
        Write-Info "They ship with the Windows SDK 'Debugging Tools for Windows' component."
        Write-Info "After WDK or SDK install they appear at:"
        Write-Info "  %ProgramFiles(x86)%\Windows Kits\10\Debuggers\x64\"
        Write-Info "Then rerun: .\bootstrap.ps1 -Only security"
        return
    }

    $root   = if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }
    $binDir = Join-Path $root "native\bin"
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

    # Core console debuggers + bonus tools that ship in the same Debuggers\x64 dir.
    # windbg (classic) = traditional GUI, separate from WinDbgX store app.
    # gflags = Driver Verifier / page-heap / special pool front-end.
    # dumpchk = quick dump validity check (no symbols needed).
    foreach ($tool in @("cdb", "kd", "ntsd", "windbg", "gflags", "dumpchk")) {
        $src = Join-Path $dbgDir "$tool.exe"
        if (-not (Test-Path $src)) { continue }
        if ($script:DryRun) {
            Write-Info "[DRY-RUN] wrapper $tool -> $src"
        } else {
            # -NoNewline: see the note at the windbg writer. Measured identical at 78 B for cdb.
            New-ShimBody -Target $src | Set-Content -Path (Join-Path $binDir "$tool.cmd") -Encoding ASCII -NoNewline
            Write-Ok "$tool -> $src"
        }
    }

    # Persist WINDBG_DEBUGGERS_PATH so future bootstrap detects instantly without
    # scanning all of Windows Kits. The _NT_SYMBOL_PATH already set by
    # security_configure_symbols applies to cdb/kd/ntsd automatically.
    $cur = [System.Environment]::GetEnvironmentVariable("WINDBG_DEBUGGERS_PATH", "User")
    if ($cur -ne $dbgDir) {
        if (-not $script:DryRun) {
            [System.Environment]::SetEnvironmentVariable("WINDBG_DEBUGGERS_PATH", $dbgDir, "User")
        }
        Write-Ok "WINDBG_DEBUGGERS_PATH -> $dbgDir"
    } else {
        Write-Skip "WINDBG_DEBUGGERS_PATH already set"
    }
    $env:WINDBG_DEBUGGERS_PATH = $dbgDir

    Sync-EnvPath
    # Detect-and-wrap only (this function never installs the SDK), and the escaping in
    # -Notes is load-bearing: `` in a double-quoted string emits a LITERAL backtick, so
    # the manifest used to ship  -c '`.logopen ...'  - a command that dies on paste with
    # "The term '`.logopen' is not recognized". Only the $$ needs escaping here.
    # lib\common.ps1 has the same sentence, correctly, in its here-string.
    Add-WinManifest -Name "cdb" -Binary "cdb" -Group "security" -Method "existing" `
        -Scope "machine" `
        -Detect "cdb -version 2>&1 | Select-Object -First 1" `
        -Notes "Console debuggers from Debugging Tools for Windows (Windows SDK): cdb=user-mode, kd=kernel-mode, ntsd=NT Symbolic Debugger. Also wrapped: windbg (classic GUI), gflags (Driver Verifier front-end), dumpchk. Scripted: cdb -z dump.dmp -c '.logopen out.txt; `$`$><script.txt; q'. pooltag.txt at Debuggers\x64\triage\. _NT_SYMBOL_PATH auto-resolves OS symbols." `
        -InstalledByToolbox:$false
}

function security_register_npcap {
    # Npcap is the packet-capture DRIVER that enables tshark LIVE capture ('tshark -i').
    # tshark READS pcap/pcapng files fine without it. Npcap has NO winget package (its
    # license blocks redistribution) and the toolbox forbids choco/scoop/direct .exe
    # downloads - so, exactly like Ghidra, it is a DOCUMENTED dependency, not an
    # auto-install. If present we record it in the manifest; if absent we point at the
    # two accepted install paths and prefer the driver-free pktmon+etl2pcapng route.
    $wpcap = Join-Path $env:WINDIR "System32\Npcap\wpcap.dll"
    $svc   = Get-Service -Name npcap -ErrorAction SilentlyContinue
    if ((Test-Path $wpcap) -or $svc) {
        Write-Ok "Npcap present - tshark live capture ('tshark -i') available"
        # Version from the Npcap uninstall key (the real package version, e.g. 1.88);
        # wpcap.dll's ProductVersion is only the libpcap API version (1.10.x), which misleads.
        Add-WinManifest -Name "npcap" -Binary "npcap" -Group "security" -Method "existing" `
            -Scope "machine" `
            -Detect "(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\NpcapInst','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\NpcapInst' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty DisplayVersion)" `
            -Notes "packet-capture driver (NDIS); enables 'tshark -i' live capture. No winget package - see docs/agent-rules.md" `
            -InstalledByToolbox:$false
        return
    }
    Write-Warn "Npcap not installed: tshark can READ captures but 'tshark -i' live capture is unavailable"
    Write-Info "Npcap has no winget package (license). Accepted install paths (both need elevation):"
    Write-Info "  - re-run the Wireshark installer interactively and tick the bundled Npcap component, OR"
    Write-Info "  - preferred/channel-compliant: capture with built-in pktmon + etl2pcapng, then read the .pcapng in tshark"
}
