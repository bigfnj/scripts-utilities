# Fresh Workstation Audit

Audit date: 2026-07-31

## Outcome

The repository is ready to be used as the installation source for a new x64
Windows workstation after the changes recorded with this audit. The supported
path is `fresh-toolbox-setup-runner.ps1`; the executable builder is the single
source of truth for DevToolbox contents.

## Scope reviewed

- Bootstrap prerequisites, elevation, idempotency, legacy cleanup, and PATH.
- Winget installation channels and current package-ID availability.
- Python, GPU/ML, browser, native-tool, and Sysinternals build paths.
- Ghidra and JDK acquisition, integrity verification, and wrapper creation.
- Generated manifests, agent discovery, smoke tests, and failure behavior.
- Fresh-machine documentation and obsolete repository artifacts.

## Findings resolved

- Replaced the destructive, hard-coded old-machine migration runner with a
  non-destructive fresh-workstation orchestrator and transcript.
- Made legacy toolbox cleanup explicit opt-in and refuse deletion of a legacy
  clone that has local changes.
- Added clear Winget and x64 preflight failures while preserving useful dry runs.
- Added an explicit toolbox refresh route for applying builder changes to an
  existing installation.
- Corrected the Npcap smoke test: Npcap is a detected driver, not a command.
- Made known machine-scope Winget packages explicit instead of silently
  broadening scope after any user-scope failure.
- Preferred the requested Winget package when locating executables, avoiding
  accidental wrappers to bundled copies such as an editor's `rg.exe`.
- Added resilient download fallback, Ghostscript SHA-256 verification,
  Sysinternals signature verification, and published-digest verification for
  portable Ghidra and Temurin JDK assets.
- Restored exact native target paths and existence flags in the generated
  toolbox manifest.
- Expanded builder verification with `pip check`, Sysinternals readiness, and
  Chromium/Firefox/WebKit launch probes.
- Removed the obsolete replication prompt and an unrelated tracked source ZIP.
- Replaced the teardown playbook and updated README, agent rules, tool usage,
  ignore rules, and backlog.

## External channels checked

All Winget package IDs referenced by the repository were present in the
official `microsoft/winget-pkgs` repository during the audit. The current Ghidra
release API, Adoptium JDK 21 API, Ghostscript asset, Sysinternals archive, and
Tesseract language-data endpoints were reachable. These are live channels and
must still be revalidated by the actual new-machine run.

## Remaining deliberate limitations

- Native ARM64 Windows is not supported; the current target is x64 Windows.
- Python top-level dependencies resolve at installation time rather than from a
  committed transitive lock. This favors current security updates but is not
  bit-for-bit reproducible.
- The heavy stack assumes the CUDA 12.8 PyTorch wheel channel. Use `-SkipHeavy`
  on a CPU-only machine or when the replacement GPU/driver is not compatible.
- Npcap and Ghidra remain optional and are not silently installed by bootstrap.
- Some native runtime installers are machine-scope only and can prompt for UAC.

## Go/no-go gate for the new workstation

Do not retire the old machine until all of the following are true:

1. `fresh-toolbox-setup-runner.ps1` completes successfully.
2. `scripts/smoke-test.ps1` reports zero failures.
3. DevToolbox `pip check` reports no broken requirements.
4. The generated toolbox manifest contains the expected new-machine paths.
5. Representative Git authentication, secret decryption, and project work are
   tested after user state is restored.
