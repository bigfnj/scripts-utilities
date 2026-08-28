# Agent Rules - Windows Dev Toolbox

Rules for any AI agent (Claude, Codex, Copilot, ...) working on this machine.
The Linux counterpart lives in `ai-dev-envbuild/docs/agent-rules.md`.

---

## Before installing anything

`fresh-toolbox-setup-runner.ps1` is the preferred new-workstation entrypoint.
`bootstrap.ps1` is the idempotent installation entrypoint. It creates or validates
the durable DevToolbox under `%LOCALAPPDATA%\DevToolbox` by invoking
`scripts/build-devtoolbox.ps1` when needed, then installs the repo-managed
gap-fill tools. The executable builder is the single source of truth; do not
recreate the toolbox from an old prompt, archive, or copied installation tree.

On a fresh machine, verify 64-bit Windows, Git, Windows PowerShell 5.1+, and a
working `winget` command. Run from a normal user session; installers that need
elevation should own their individual UAC prompt.

`bootstrap.ps1 -CleanLegacyState` performs a known-old-toolbox cleanup before installing current
tools. It removes only artifacts this project knows it owns: the legacy
`%USERPROFILE%\Documents\Codex\_codex-toolbox` root, stale `CODEX_TOOLBOX`
environment values, PATH entries pointing at that legacy root, generated local
manifest state, and old agent discovery blocks. It intentionally does not scan
the whole disk or delete unrelated tool directories.
Cleanup is explicit opt-in. If legacy state is detected during a normal run,
bootstrap stops and tells the operator to review a dry run first.

Check whether the tool is already present:

```powershell
# Check this workstation's generated bootstrap manifest, if bootstrap has run
Get-Content "$PSScriptRoot\..\manifest\tools.json" | ConvertFrom-Json | Select-Object name, binary

# Check the dev toolbox manifest
Get-Content "$env:LOCALAPPDATA\DevToolbox\toolbox-manifest.json" | ConvertFrom-Json
```

The tool you want is probably already there - either in the winget manifest, the
dev toolbox (`native\` or Python venv), or the Sysinternals suite.

`manifest/tools.json` is generated per workstation by `bootstrap.ps1`; do not
commit it or copy it between machines.

After builder changes, run `bootstrap.ps1 -RefreshToolbox` so an existing
toolbox receives the current builder logic.

---

## Install channels - use exactly one per tool type

### 1. Developer CLI tools -> winget (`--scope user`)

For tools you invoke by name from any terminal (gh, fzf, bat, rg, fd, jq, ...).

```powershell
winget install --id <WingetId> -e --accept-source-agreements --accept-package-agreements --silent --scope user
```

`--scope user` is mandatory - it keeps PATH changes in user scope and avoids
elevation. Never omit it or let it default to machine scope.

Add the tool as an entry in `catalog.json` (the declarative source of truth): set
`group` to `cli-tools` and `channel` to `winget-user`, plus `id`, `binary`,
`detect`, and `notes`. The module (`modules/cli-tools.ps1`) just calls
`Install-CatalogGroup` via `lib/catalog.ps1`, so no per-tool PowerShell is needed.

**Do NOT use:** `choco`, `scoop`, direct `.exe` downloads, or
`winget install` without `--scope user`.

Exception - the `winget-default` channel: a few manifests declare **no scope at
all**, and winget then rejects *both* `--scope user` and `--scope machine` with
`0x8A150010` "No applicable installer found". `Podman.CLI` is one (verified as
the user and as SYSTEM; the WDK has the same quirk, handled by the `$NoScopeFlag`
list in `scripts/install-machine-scope.ps1`). Mark those `"channel":
"winget-default"` in `catalog.json` - `Install-WingetTool -NoScope` omits the
flag and lets winget pick the manifest's only installer. Verify where it actually
lands before using this: Podman installs **per-user** to
`%LOCALAPPDATA%\Programs\Podman` and adds itself to the **user** PATH, so it is
still channel- and PATH-clean and needs no elevation. Do not reach for
`winget-default` to dodge a legitimate `--scope user` failure.

Exception: some security tools with GUI installers, such as Wireshark, do not
support user scope. Give those the `winget-machine` channel in `catalog.json`,
add the id to the `machine_scope_ids` array, and set a `path_fallback` so the CLI
binary is found even when the installer does not add it to PATH. Keep any opt-out
gate (e.g. `TOOLBOX_SKIP_WIRESHARK`) in `modules/security.ps1`.

The stage-1 DevToolbox builder also contains an explicit allowlist of native
runtime packages whose current Winget manifests are machine-scope only
(LibreOffice, Tesseract, QPDF, ImageMagick, 7-Zip, and Node.js LTS). Those
entries set `machineScope = $true` and may prompt for UAC. Do not add an
unconditional fallback from user scope to machine scope; verify the current
official manifest and mark the individual package deliberately.

To collapse those per-package UAC prompts into a single elevation, run
`scripts/install-machine-scope.ps1` once with an admin/SYSTEM token before the
normal-user bootstrap. It installs exactly the machine-scope IDs (plus
Wireshark) at `--scope machine`; the later bootstrap then detects them already
present and skips them without prompting. The script is channel-clean (pure
winget) and has no dependency on any specific elevation tool. Keep its ID list
in sync with the `machineScope` entries here and the Wireshark install in
`modules/security.ps1`.

Npcap (the capture driver for live `tshark -i`) is a further exception: it has
**no winget package** (license blocks redistribution) and the silent Wireshark
install skips its bundled Npcap component. Do **not** direct-download or
`choco install` it during bootstrap. Treat it like Ghidra - a documented optional
dependency that `modules/security.ps1` detects and records if present, otherwise
pointing at the driver-free `pktmon` + `Microsoft.etl2pcapng` capture path. Install
Npcap manually (elevated) only if you specifically need live `tshark -i` capture.

**WinDbg (store) vs console debuggers.** `Microsoft.WinDbg` (winget) installs
WinDbgX.exe — the GUI debugger — but does **not** ship `cdb.exe`, `kd.exe`, or
`ntsd.exe`. Those three are the scriptable/headless console debuggers from the
**Windows SDK** "Debugging Tools for Windows" component. They are detected and
wrapped by `modules/security.ps1` (`security_install_console_debuggers`); run
`bootstrap.ps1 -Only security` after the SDK or WDK installs them to activate.
Override the search path by setting `WINDBG_DEBUGGERS_PATH` (user env var) to
the `Debuggers\x64` dir before running bootstrap.

**WDK (Windows Driver Kit) — poolmon and pool-tag analysis.** Install via
`scripts\install-machine-scope.ps1` (reads `catalog.json`). **Do NOT pass
`--scope machine`** to winget for this package — it fails `0x8A150010 "no
applicable installer"`; `install-machine-scope.ps1` handles this via the
`$NoScopeFlag` list. The WDK is large (~1-2 GB). To skip it set
`TOOLBOX_SKIP_WDK=1` (user env var); poolmon/debuggers are still wrapped if
already on disk. The WDK installer typically pulls in the matching Windows SDK,
so `cdb.exe` often appears as a side effect — re-run `bootstrap.ps1 -Only
security` after the WDK installs to pick up both poolmon and the console debuggers.

Ghidra (the NSA reverse-engineering suite) is the same shape: **no winget
package** - it ships as a GitHub release ZIP that needs a JDK 21+. Do **not**
`choco install` it or auto-download it in `bootstrap`. Use the helper
`scripts\install-ghidra.ps1` (fetches Ghidra + a portable Temurin 21 JDK into the
toolbox `native\` dir, no admin), or do it by hand: extract the ZIP anywhere writable (a user dir like the toolbox `native`
folder needs no admin; `%ProgramFiles%` needs elevation) and provide a **JDK 21+** -
preferably a portable JDK zip (Temurin/Microsoft) extracted to the toolbox
`native\jdk-21` (no admin, unregistered, so it also avoids a JDK compliance flag);
the module then wires that JDK into the Ghidra launcher wrappers via `JAVA_HOME`
(Ghidra only, no global change). You can extract Ghidra anywhere: on the next run `modules/security.ps1` finds it via `$GHIDRA_INSTALL_DIR`
or by searching common roots (Program Files, `%LOCALAPPDATA%`, your profile,
Downloads/Desktop, `C:\`, `C:\Tools`, the toolbox `native` dir), validating by
`ghidraRun.bat`. It then pins `GHIDRA_INSTALL_DIR`, wraps `ghidraRun` /
`analyzeHeadless` onto the toolbox PATH, and records it. Set `GHIDRA_INSTALL_DIR`
yourself if you put it somewhere unusual (e.g. another drive).

The Ghidra helper resolves current vendor metadata and verifies the published
SHA-256 digests for both Ghidra and the JDK before extraction. Do not bypass
that verification.

### 2. Python libraries -> dev toolbox venv (`pip` into venv)

For things you `import` in Python scripts (pandas, requests, frida, ...).

```powershell
$py = "$env:LOCALAPPDATA\DevToolbox\python\.venv\Scripts\python.exe"
& $py -m pip install <package>
```

Or via the `Install-PipToolbox` helper in `lib/common.ps1`.

Add to `modules/extras.ps1` or `modules/security.ps1` following the existing
`Install-PipToolbox` + `Add-WinManifest` pattern.

**Do NOT use:** `pip install` into any system or global Python, `pipx` on
Windows for libraries, or `uv pip install` outside a project venv.

### 3. Node.js CLIs -> npm global

For Node tools you invoke by name (markdownlint, typescript, ...).

```powershell
npm install -g <package>
```

Or via the `Install-NpmGlobal` helper in `lib/common.ps1`.

**Do NOT use:** `pnpm add -g` (pnpm global is fragmented; npm global is the
single stable Windows CLI install path).

---

## The toolbox boundary - what goes where

| Belongs in this bootstrap (scripts-utilities) | Belongs in dev toolbox |
|---|---|
| Developer CLI tools used in any terminal | Python libs needed for scripting/automation |
| Security/RE tools (winget) | Heavy runtime tools (LibreOffice, Tesseract, ffmpeg, Pandoc) already there |
| Node global CLIs | GPU/ML Python stacks (torch, onnxruntime, realesrgan) |

When in doubt: if it's a CLI you type by name -> winget here. If it's a Python
`import` -> toolbox venv.

---

## PATH rules

- Prefer **winget with `--scope user`** for permanent user PATH entries.
- For machine-scope installers that do not expose their CLI, use the repo's
  `Add-UserPathEntry` helper so the change stays in user scope and is tracked.
- Never append to `$env:PATH` directly in a script that persists beyond the current session.
- Never add entries to the **system** PATH (requires elevation and affects all users).
- The `Sync-EnvPath` helper in `lib/common.ps1` refreshes the current session's
  PATH from the registry after a winget install - use it; do not restart shells
  or start new processes to pick up new tools.
- **A tool that is "not recognized" is usually present.** See *When a tool is
  missing from PATH* below before installing anything a second time.
- `bootstrap.ps1` (via `Register-ToolboxUserPath`) persists the durable toolbox
  layer on the **user** PATH so it resolves by bare name in any new shell without
  activation: `native\bin` and `sysinternals` (appended last so it never shadows
  Git/coreutils names). An agent's tool calls do not share session state, so
  per-session activation alone is not enough.
- The venv `Scripts` dir is **not** put on the persistent PATH, because it holds
  `python.exe` and a 3.11 interpreter on PATH trips corporate "old Python"
  compliance scanners. Instead, `New-VenvCliWrappers` wraps each venv console
  script into `native\bin` (so the CLIs are callable by name), the interpreter is
  exposed only via the `TOOLBOX_PYTHON` env var, and `TESSDATA_PREFIX` is
  persisted. A bare `python` stays the sanctioned system interpreter. When a tool
  or script needs the toolbox's Python 3.11, call `%TOOLBOX_PYTHON%` explicitly -
  never assume `python` is 3.11.

### When a tool is missing from PATH

**Check the registry before concluding the tool is not installed.** The usual
cause is a stale environment block, not a missing tool, and the usual wrong
response is to install it again.

Windows never retro-fits a new PATH into a running process. It broadcasts
`WM_SETTINGCHANGE`, Explorer acts on it, and processes Explorer starts *after
that* inherit the new value. A long-running agent host is not one of those: it
captured its environment at launch and keeps it, so every shell it spawns
inherits the old PATH no matter how many are opened.

Observed on this box, 2026-08-27: git was installed to `C:\Anthropic\.Git` and
registered on both the machine and user PATH, yet `git` was unresolvable in every
agent shell. So were the toolbox's own `native\bin` and `sysinternals`, plus
Ghidra and DOSBox-X - all present in the registry, none visible in-process.

Confirm it is staleness rather than absence:

```powershell
# Registry truth, unaffected by any running process.
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').Path -split ';' |
    Where-Object { $_ -match 'git' }
```

If the entry is there and `Get-Command` still fails, it is staleness.

**Per-command fix.** Refresh from the registry inside the invocation that needs
it. `Sync-EnvPath` does this, or inline:

```powershell
$m = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
$u = [System.Environment]::GetEnvironmentVariable('PATH','User')
$env:PATH = (@(($m -split ';') + ($u -split ';')) | Where-Object { $_ } | Select-Object -Unique) -join ';'
```

This does **not** carry to the next tool call. Agent tool calls do not share
session state: each one is a fresh process inheriting the host's stale block, so
the refresh has to be repeated per invocation. Calling a binary by absolute path
works equally well for a one-off.

**Durable fix: restart the agent host.** Not the machine. A reboot works only
because it restarts the host as a side effect. On restart the host reads a current
environment and every shell it spawns inherits it.

Note that broadcasting `WM_SETTINGCHANGE` after writing PATH, which
`scripts/consolidate-path.ps1` does, cannot solve this. The broadcast helps
Explorer and what Explorer launches next; it has no effect on a process that is
already running and never re-reads the registry.

---

## Native HTTPS in agent sandboxes

Agent command runners on this machine (Codex in particular) execute inside a
sandboxed/elevated token that cannot acquire a Schannel client credential.
Anything using Windows' built-in TLS fails there with:

```text
curl: (35) schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030E)
```

That call happens before any socket is opened or certificate fetched, so it is
never a certificate, CA, proxy, or TLS-version problem.

Two causes have worn this same error message here, and they must be kept
apart:

1. **A real host fault, already fixed.** Until 2026-08-15, `SecurityProviders`
   held only `credssp.dll` and LSA `Security Packages` was empty, which broke
   Schannel for every client on the box. The repair on 2026-08-15 01:26 plus
   the 08:57 reboot corrected it. That work is done and closed.
2. **The residual sandbox case, still present.** After that fix, the error
   persists *only* inside agent sandboxes. Verified 2026-08-17: the same
   `C:\Windows\System32\curl.exe` succeeds from an ordinary shell (12/12
   hosts) on the very boot session where the sandboxed runner fails.

Everything below concerns case 2.

- **Affected** (Schannel-backed): `C:\Windows\System32\curl.exe`, the curl
  bundled with Git for Windows, `Invoke-WebRequest`, .NET `HttpClient`.
- **Unaffected** (userspace TLS): the `curl-libressl` catalog entry (winget
  `cURL.cURL`, ships `curl-ca-bundle.crt`), the DevToolbox Python venv
  (OpenSSL), Node `fetch`.

Resolve the LibreSSL curl by path. System32 wins bare-name resolution because
Machine PATH precedes User PATH, and the PATH rules above forbid system PATH
edits:

```powershell
$curl = (Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\cURL.cURL_*\curl-*-win64-mingw\bin\curl.exe" | Select-Object -Last 1).Path
```

Do **not** try to fix case 2 by editing `SecurityProviders` or LSA
`Security Packages`. That repair already ran and already succeeded on
2026-08-15; a second attempt on 2026-08-16 wrote byte-identical values to an
already-stock registry and changed nothing, per its own backups.
`D:\.ai-work\ops\scripts\https-correction-01.ps1` is retained only as a marked
superseded no-op. No reboot is owed for this symptom.

---

## Adding a tool - workflow

1. **Confirm it's missing:** check both manifests (above).
2. **Add a `catalog.json` entry** (the declarative source of truth). Set:
   - `group`: `cli-tools` | `security` | `extras` | `llm` (new group only if none fit and there are >=3 tools in it)
   - `channel`: `winget-user` | `winget-machine` | `npm-global` | `pip-toolbox`
   - plus `id`, `binary`, `detect`, `notes` (add `register_manifest: false` for an import-only library with no CLI binary).
3. **No per-tool code needed:** the group's module consumes the catalog via
   `lib/catalog.ps1` (`Install-CatalogGroup` / `Install-CatalogItem`). Touch the module
   only for special handling (e.g. an opt-out env gate); for a `winget-machine` tool,
   also add its id to `machine_scope_ids`.
4. **Apply it:**

   ```powershell
   .\bootstrap.ps1 -Only <group>
   ```

   Running the module updates the local generated `manifest/tools.json`. Editing
   without running leaves that workstation's manifest stale.
5. **Verify:**

   ```powershell
   .\scripts\smoke-test.ps1
   ```

   All core checks must pass before committing.
6. **Commit and push** so the change is recorded.

---

## Don't

- Don't use `choco`, `scoop`, or direct installer downloads - they bypass the
  manifest and create untracked PATH entries.
- Don't install Python libraries globally (no `pip install` outside a venv).
- Don't omit `--scope user` from winget installs.
- Don't modify the dev toolbox's `requirements-core.txt` or `requirements-ml.txt`
  from here - the toolbox has its own replication prompt for that.
- Don't push without a passing `smoke-test.ps1`.
