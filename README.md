# scripts-utilities

**An idempotent Windows workstation bootstrap that builds a durable developer toolbox and then
tells your AI coding agents it exists.**

One command turns a fresh Windows box into a working environment: a private Python 3.11
environment, ~40 native CLI tools, GPU/ML packages, browser automation, and a security/RE layer,
all resolvable by bare name in any new shell with no activation step. It records what it did in a
machine-readable manifest, and writes a discovery block into the instruction files that Claude
Code, Codex and Copilot already read.

Windows counterpart to [`ai-dev-envbuild`](https://github.com/bigfnj/ai-dev-envbuild) on Linux/WSL.

---

## Why this is built for AI agents

Most "dev environment" scripts install things. This one also solves the problem that appears the
moment an autonomous agent starts working on your machine.

**An agent cannot see your machine.** Ask one to convert a PDF and it will reach for `pip install`,
because it has no way to know you already have `pandoc`, `tesseract` and `qpdf`. You get duplicate
installs, tools fetched from the wrong channel, a polluted PATH, and occasionally a version bump
that breaks something else. The fix is not a better prompt. It is giving the agent a fact source.

`bootstrap.ps1` writes a fenced, idempotent block into the files agents already load:

| File | Read by |
|---|---|
| `%USERPROFILE%\.claude\CLAUDE.md` | Claude Code, as global config |
| `%USERPROFILE%\CLAUDE.md` | Claude Code, via directory walk-up from any path |
| `%USERPROFILE%\AGENTS.md` | Codex and other AGENTS.md-aware tools |
| `%USERPROFILE%\.codex\AGENTS.md` | Codex |

The block names the toolbox root, points at the generated manifest, links the install rules and the
usage guide, and states the PATH conventions. It is delimited by
`<!-- WIN_DEVTOOLS_START -->` / `<!-- WIN_DEVTOOLS_END -->`, so re-running **replaces** the block
rather than appending a second copy, and your own instructions above and below it are untouched.
The file is backed up before every write.

Three design choices exist specifically because the consumer is an agent, not a human:

**Bare-name resolution, no activation.** Agent shells usually do not persist state between
commands: every tool call is a fresh process, so `activate` in one call is gone by the next. Every
tool here is callable by name in any new shell because `native\bin` and `sysinternals` are on the
PATH and the venv CLIs are wrapped into `native\bin`. `bootstrap.ps1` stages those two entries in
the **user** hive because it runs unelevated by contract;
[`scripts/consolidate-path.ps1`](scripts/consolidate-path.ps1) then moves them to the **machine**
hive, which is what makes them visible to the agent shells that inherit the machine PATH only.

Once they are machine-wide, `bootstrap.ps1` stops staging them: `Add-UserPathEntry` checks the
machine hive first and returns `machine PATH already provides it, so no user entry is needed`.
Windows composes machine-then-user, so a user copy of a machine entry can never win a lookup; it
only spends characters against the truncation limit described below. Before this check existed
every bootstrap run silently re-added both. On the reference box the user PATH is now a single
44-character entry, and that is the healthy state, not a stripped one.

**The venv `Scripts` directory is deliberately *not* on PATH.** Exposing a Python 3.11 `python.exe`
is what trips corporate "unsupported Python" compliance scanners. A bare `python` stays your
sanctioned system version; the toolbox interpreter is reached explicitly via `%TOOLBOX_PYTHON%`.
An agent that reads the discovery block knows this and stops guessing.

**A manifest to check before installing.** `manifest/tools.json` records what is present and
whether the toolbox installed it. "Check this file before installing anything" is a cheap
instruction that prevents the most common and most annoying agent failure mode.

### The PATH problem this had to solve

Two failures make a correctly installed tool report "not found" in an agent shell, and both are
silent.

**Windows truncates a long PATH.** Measured on the reference machine: a 4,363-char machine PATH
arrived in the spawned shell as exactly **4,095 chars**, with the final entry chopped mid-string
at `C:\Users\Admin\AppD`. Everything past the 4 KB boundary was simply gone, including `git`.
Nothing was misconfigured. 27 winget package directories accounted for 3,380 of 5,264 total chars,
because winget registers a full package folder complete with its
`_Microsoft.Winget.Source_8wekyb3d8bbwe` suffix and a version-stamped subfolder.

**Some shells inherit the machine PATH only**, which makes the user PATH invisible. That is
precisely where a non-elevated install puts `native\bin` and `sysinternals`.

[`scripts/consolidate-path.ps1`](scripts/consolidate-path.ps1) fixes both by extending the shim
pattern one level out: it wraps every executable reachable through those winget package
directories into `native\bin`, drops the directories from PATH, and registers `native\bin` and
`sysinternals` machine-wide. On the reference box that took the machine PATH from **4,363 chars to
1,726** and made `git`, `tesseract`, `procdump`, `deno` and `yt-dlp` resolvable again. Measured
again on 2026-09-11 after the duplicate prune below: machine 1,557 raw / 1,588 expanded across 39
entries, user 44 / 1, **composed 1,633 chars over 40 entries** with 2,462 to spare.

Quote the **expanded** length, as `smoke-test.ps1` does: the cliff applies to the environment block
the child process actually receives, and the raw registry text is 31 chars shorter here because
`%SystemRoot%` and friends are still literal in it.

```powershell
.\scripts\consolidate-path.ps1 -DryRun    # report, change nothing
.\scripts\consolidate-path.ps1            # apply (self-elevates via UAC; exit 2 if you decline, nothing written)
.\scripts\consolidate-path.ps1 -Restore logs\path-backup-<timestamp>.json
.\scripts\consolidate-path.ps1 -RebuildShims   # re-wrap from disk, touching no PATH value
.\scripts\consolidate-path.ps1 -Prune          # remove ratified entries (see PATH hygiene below)
```

Other parameters: `-FromBackup` (take the priority order from a backup rather than the live PATH),
`-Pick name=package` (bind a contested name by hand), `-NoElevate` (for unattended callers; exits 2
rather than prompting), `-TargetMax` (character budget, default 3500) and `-PackagesRoot`.

#### PATH hygiene: removing an entry, with the precondition re-measured

`-Prune` removes only entries ratified in
[`config/path-hygiene.json`](config/path-hygiene.json), and it re-measures every precondition at
run time rather than trusting the file, because that file is a judgement somebody made on one
particular day and a machine moves. Each entry declares a `require`:

| `require` | holds when |
|---|---|
| `duplicate-in-machine` | the identical entry is in the machine hive right now, so dropping the user copy changes no lookup |
| `no-executables` | the expanded directory holds zero `*.exe` / `*.cmd` / `*.bat` |
| `shadowed` | every basename it provides is already provided by an EARLIER entry, except names declared in `expect_unresolved` |

An entry whose precondition no longer holds is **skipped and reported**, never removed, and so is
one that has already left PATH. The run also prints a resolution delta and refuses to proceed if
any bare command name would start resolving somewhere new.

Both PATH values are backed up to timestamped JSON first, and the registry value kind
(`REG_EXPAND_SZ`) is preserved by writing the key directly, because
`[Environment]::SetEnvironmentVariable` silently rewrites it as `REG_SZ`. Where two packages ship
the same executable, the one that resolves today keeps winning; shadowed copies are reported, not
reassigned.

Re-run it after a winget upgrade: a version-stamped folder moves and its shim goes stale. The
smoke test fails loudly on any shim whose target no longer exists, and on a PATH that has crept
back toward the truncation point.

Nothing here requires an agent. It is a good toolbox on its own; the discovery layer is additive.

---

## Quick start

### Requirements

- 64-bit Windows 10 or 11, Windows PowerShell 5.1+
- A normal, non-elevated user session with internet access
- `git` and a working `winget` (Microsoft App Installer)
- ~20 GB free for the full GPU/ML toolbox, browsers and caches

```powershell
git --version
winget --version
```

### Install — one line, no clone

```powershell
irm https://raw.githubusercontent.com/bigfnj/scripts-utilities/main/get.ps1 | iex
```

Runs from memory. It installs `git` if missing, clones the repo to
`%USERPROFILE%\scripts-utilities`, prints the tool catalog, and opens an 8-item menu: dry run, full
install, lean install (`-SkipHeavy`), minimal install (`-SkipHeavy -SkipPlaywrightBrowsers`), the
GUI, the elevated machine-scope pre-install, a smoke test, and open-the-install-folder. Re-run the
same line any time to update the clone and reopen the menu.

`| iex` cannot take parameters, so set these **before** the one-liner if you need them:

```powershell
$env:TOOLBOX_DIR = "$HOME\dev\scripts-utilities"   # clone somewhere else
$env:TOOLBOX_REF = 'v1.0.0'                        # pin to a tag instead of main
```

> **Read it before you run it.** Piping a remote script to `iex` executes whatever is at that URL
> at that moment. [`get.ps1`](get.ps1) is the whole file and it is short. For a reproducible
> install, point `TOOLBOX_REF` at a tag rather than a moving branch.

### Install — clone it yourself

```powershell
git clone https://github.com/bigfnj/scripts-utilities.git
Set-Location .\scripts-utilities
.\fresh-toolbox-setup-runner.ps1 -DryRun     # see everything it would do
.\fresh-toolbox-setup-runner.ps1             # do it
```

Run from a normal window. A package that genuinely needs elevation (Wireshark) raises its own UAC
prompt. To avoid per-package prompts, pre-install the machine-scope set in one elevation first:

```powershell
.\scripts\install-machine-scope.ps1          # elevated, then run the runner normally
```

### Common variants

```powershell
.\fresh-toolbox-setup-runner.ps1 -SkipHeavy                          # no GPU/ML stack
.\fresh-toolbox-setup-runner.ps1 -SkipHeavy -SkipPlaywrightBrowsers  # ...and no browsers
.\fresh-toolbox-setup-runner.ps1 -SkipWireshark                      # no packet capture
.\fresh-toolbox-setup-runner.ps1 -SkipWDK                            # no poolmon wrapper
.\fresh-toolbox-setup-runner.ps1 -InstallGhidra                      # + Ghidra and a private JDK 21
.\fresh-toolbox-setup-runner.ps1 -InstallLlm                         # + local Ollama stack
```

`-SkipWDK` here only sets `TOOLBOX_SKIP_WDK=1`, which stops the security group wrapping
`poolmon` — including a poolmon already on disk. It does not skip a WDK install, because the
runner never installs the WDK; that is `install-machine-scope.ps1`, which has its own `-SkipWDK`.
`cdb`/`kd`/`ntsd` come from the SDK's debuggers directory and are wrapped either way.

Prefer clicking? `.\gui\Start-ToolboxGui.cmd` renders the catalog as grouped checkboxes with live
status and shells out to the same scripts. It installs nothing itself.

---

## What gets installed

Two layers, and they are independent.

### Layer 1 — the DevToolbox (`scripts/build-devtoolbox.ps1`)

Everything lands under `%LOCALAPPDATA%\DevToolbox`, self-contained and removable.

| Layer | Always? | Contents |
|---|---|---|
| `core-python` | yes | Python 3.11 venv + document/PDF/OCR/image/data packages |
| `native-cli` | yes | ffmpeg, ffprobe, pandoc, tesseract, poppler, qpdf, ghostscript, LibreOffice, ImageMagick, 7z, rg, fd, jq, yq, exiftool, aria2c, rclone, DuckDB, Node.js, uv/uvx |
| `sysinternals` | yes | procdump, handle, sigcheck, and the rest of the suite |
| `heavy-gpu` | `-SkipHeavy` | torch CUDA, onnxruntime-gpu, rembg and the ML stack |
| `playwright` | `-SkipPlaywrightBrowsers` | Chromium, Firefox, WebKit binaries |

### Layer 2 — gap-fill tools (`bootstrap.ps1`)

Installed through winget, in three groups. `.\bootstrap.ps1 -List` shows them without changing
anything.

| Group | Tools |
|---|---|
| **cli-tools** (15) | `gh` GitHub CLI · `pwsh` PowerShell 7, machine-scope MSI beside 5.1 · `fzf` fuzzy finder · `bat` syntax-highlighted cat · `delta` git diff pager · `just` task runner · `hyperfine` benchmarking · `sops` encrypted secrets · `age` file encryption · `tokei` LOC stats · `podman` per-user containers, no elevation · `docker-compose` · `curl-libressl` curl built on LibreSSL, for the agent sandboxes where the bundled Schannel curl fails · `yt-dlp` media downloader · `deno` secure JS/TS runtime, also yt-dlp's JS challenge runtime |
| **security** (3+) | `tshark` Wireshark CLI · `etl2pcapng` driver-free capture conversion · `frida` dynamic instrumentation · plus WinDbg, `cdb`/`kd`/`ntsd`, `gflags`, `dumpchk` and `poolmon` from the WDK when present, and optional Ghidra |
| **extras** (5) | `markdownlint` · `jupyter-lab` · `sqlite-utils` · `csvkit` (`csvlook`) · `pytoshop` |

Two deliberate omissions. **Npcap is never downloaded automatically** — it is an optional elevated
driver needed only for live `tshark -i` capture; reading existing captures works without it, and
the supported driver-free path is `pktmon` → `etl2pcapng` → `tshark`. **Ghidra is opt-in**, via
`scripts/install-ghidra.ps1`, which verifies published SHA-256 digests for both Ghidra and its
portable JDK.

### Optional — local LLM stack (`-InstallLlm`)

A fully offline inference stack for sensitive or air-gapped work. Ollama runs as a per-user
background service at `127.0.0.1:11434` with an OpenAI-compatible API, discoverable via
`%TOOLBOX_LLM_URL%`. Models live inside the toolbox and are pulled **VRAM-tiered**: an 8 GB box
gets `moondream` (vision), `qwen2.5:3b` + `mistral:7b` (text) and `qwen3-embedding:0.6b`
(embeddings); a box reporting **20 GB** or more of VRAM also gets `mistral-small`, per
`tier_24gb_min_vram_mb: 20000` in `catalog.json` (the key is named for the card class, not the
threshold). A `bge-reranker-base` cross-encoder runs via
the toolbox `onnxruntime` (`-SkipReranker` to omit). The model set is defined in `catalog.json`
under `llm`.

### Optional — deletion forensics (`scripts/install-deletion-forensics.ps1`)

Answers "which process deleted this?". Two sensors: Sysmon recording event 26
`FileDeleteDetected` over a reviewed set of profile paths, and the `C:` USN journal resized from
32 MB to 2 GB. Deliberately not part of `bootstrap.ps1` — it loads a `BOOT_START` kernel driver
and resizes an NTFS structure, which is not something a general toolbox run should do to you
unasked.

```powershell
.\scripts\install-deletion-forensics.ps1            # install or update (self-elevates)
.\scripts\install-deletion-forensics.ps1 -Verify    # health only, changes nothing
.\scripts\install-deletion-forensics.ps1 -Uninstall # remove Sysmon; the journal is left sized
```

It exists because on 2026-09-09 this workstation lost ~16 profile dotdirs,
`%LOCALAPPDATA%\DevToolbox`, `.dotnet\tools` and ~70 GB of Ollama models inside 97 minutes, and
the cause could not be established: Sysmon was absent, File System auditing was off, and a 32 MB
journal held under two hours of history on this volume. A weekly SYSTEM task writes a
self-contained HTML dashboard into your Downloads. The path list, the measured exclusions and the
dashboard are documented in [docs/tools-reference.md](docs/tools-reference.md); the Sysmon config
in `config/sysmon-filedelete.xml` is hardcoded to one profile name and needs editing for any other
machine.

---

## Day-to-day

```powershell
.\bootstrap.ps1                    # build if missing, then install all groups
.\bootstrap.ps1 -DryRun            # describe changes, change nothing
.\bootstrap.ps1 -Only cli-tools    # comma-separated groups
.\bootstrap.ps1 -RefreshToolbox    # rerun the idempotent builder
.\bootstrap.ps1 -List              # show the catalog, install nothing
.\bootstrap.ps1 -Help              # parameters and groups
.\scripts\smoke-test.ps1           # functional gate; must pass before committing
.\run-gate.ps1                     # the above plus every test suite, one answer
```

Also declared: `-SkipHeavyToolboxBuild` and `-SkipPlaywrightBrowsers` (passed through to the
builder), and `-CleanLegacyState`, which removes stale toolbox PATH entries from **both** hives and
so is the one destructive switch here.

`run-gate.ps1` is the one to run before committing. It treats a **missing** suite as a failure
rather than a warning, and a suite that exits 0 without printing a tally as a failure too —
both are shapes this repository has actually shipped. It invokes `powershell.exe` for every
suite regardless of which host you launch it from, because 5.1 is what the weekly task runs and
a gate that checks whichever host you happened to use is not checking the thing that matters.

Set `CODEX_TOOLBOX` before running to relocate the toolbox root.

The gate exercises the toolbox tools, PATH readiness, the agent-discovery blocks, and the
deletion-forensics sensors. On the sensors it fails only on *degradation*, never on absence: a
Sysmon service that is not running, a Sysmon or driver start type that will not survive a reboot,
a deployed config that no longer matches `config/sysmon-filedelete.xml`, or a report script that
does not parse under Windows PowerShell 5.1 — which is what the scheduled task runs. Not having
the sensors installed is a warning. A sensor that is installed and quietly capturing nothing is
worse than one that was never there, because it is the one you will rely on.

### Uninstall

```powershell
.\scripts\uninstall-toolbox.ps1 -DryRun            # exactly what would change
.\scripts\uninstall-toolbox.ps1                    # toolbox layer only (prompts: type REMOVE)
.\scripts\uninstall-toolbox.ps1 -RemoveWingetTools # also the gap-fill tools
.\scripts\uninstall-toolbox.ps1 -Yes               # skip the prompt (required in an agent shell)
```

Without `-Yes` it asks you to type `REMOVE` at a `Read-Host`. In an agent shell, which has no
interactive stdin, the bare command hangs rather than failing, so pass `-Yes` or `-DryRun` there.

By default it removes only what the toolbox owns and can safely reverse: the `DevToolbox`
directory, the PATH entries and env vars it added, the agent-discovery blocks, the manifest, and
the Sysinternals EULA keys. With `-RemoveWingetTools` it also uninstalls gap-fill tools, but **only
those the manifest records as `installed_by_toolbox=true`** — anything that pre-existed is left
alone.

---

## Repository layout

```text
get.ps1                             one-line `irm | iex` bootstrap: clone + menu
bootstrap.ps1                       main idempotent entry point
fresh-toolbox-setup-runner.ps1      fresh-workstation orchestration and logging
run-gate.ps1                        THE pre-commit gate: smoke + every suite + phase ledger
catalog.json                        the tool catalog: groups, layers, LLM models
config/path-hygiene.json            ratified PATH entries -Prune may remove, with preconditions
config/sysmon-filedelete.xml        Sysmon config template for deletion forensics
lib/common.ps1                      install/PATH/manifest/agent-discovery helpers
lib/catalog.ps1                     catalog parsing
lib/path-registry.ps1               raw REG_EXPAND_SZ PATH read/write, pure edit helpers
lib/ShimPlan.ps1                    the 8-rule shim collision planner and PATH hygiene plan
lib/ShimFormat.ps1                  the one definition of the .cmd shim byte contract
lib/AgentDiscovery.ps1              agent-block discovery and safe block rewriting
lib/SmokeLint.ps1                   lint rules the smoke test enforces on itself
lib/SysmonConfig.ps1                Sysmon config rendering and validation
modules/                            cli-tools, security, extras groups
scripts/build-devtoolbox.ps1        Python + native DevToolbox builder
scripts/install-ghidra.ps1          optional digest-verified Ghidra/JDK
scripts/install-llm.ps1             optional local LLM stack
scripts/install-machine-scope.ps1   one-elevation machine-scope pre-install
scripts/install-deletion-forensics.ps1  Sysmon + USN journal deletion sensors
scripts/New-ForensicsReport.ps1     weekly deletion report entry point
scripts/ForensicsReport.Core.ps1    event gathering and novelty baseline
scripts/ForensicsReport.Render.ps1  offline HTML rendering
scripts/ForensicsReport.Triage.ps1  triage summary and sentinel classification
scripts/consolidate-path.ps1        collapse winget dirs into shims; PATH truncation fix
scripts/install-whisper.ps1         whisper.cpp + a GGML model (manual only; nothing invokes it)
scripts/uninstall-toolbox.ps1       full-reset uninstaller
scripts/smoke-test.ps1              repository-level functional gate
tests/Invoke-CoreTests.ps1          core helpers
tests/Invoke-InstallerTests.ps1     installers, shims, PATH editing, native-stderr rules
tests/Invoke-RenderTests.ps1        forensics report rendering and escaping
tests/Invoke-SmokeLintTests.ps1     the smoke test's own lint rules
tests/Invoke-TriageTests.ps1        triage classification
tests/SUTestGuard.ps1               deletion tripwire + suite floors, dot-sourced by every suite
gui/toolbox-gui.ps1                 WinForms front-end
gui/Start-ToolboxGui.cmd            GUI launcher
docs/agent-rules.md                 contribution + install-channel rules
docs/tools-reference.md             how to use each tool
tasks/fresh-toolbox-setup.md        replacement-workstation checklist
.github/workflows/gate.yml          CI: parse sweep, control-character scan, every suite
```

**Generated, never committed:** everything under `logs/` (the whole directory is gitignored, not
just `logs/fresh-workstation/`), `manifest/tools.json`, and
`%LOCALAPPDATA%\DevToolbox\toolbox-manifest.json`. They describe one specific machine.

Three files under `logs/` are **inputs, not output**, despite living in an ignored directory:
`path-backup-*.json` (what `-Restore` and `-FromBackup` read, and the 2026-09-09 backup is the only
surviving record of the pre-outage PATH order), `shim-sources.json` (the shim provenance fallback)
and `gate-phases.log` (the ledger `run-gate.ps1` compares against; delete it and drift detection
silently restarts with no baseline). Copy them somewhere real before clearing transcripts.

---

## Troubleshooting

**`winget` not found.** Install or update Microsoft App Installer, then open a *new* PowerShell
window. Do not continue in a session where the alias was missing.

**A newly installed command is not visible.** Open a new window and rerun the group. Some MSIX
aliases only appear in a new process.

**Corporate TLS/Schannel errors.** The builder prefers the toolbox `aria2c` once available and
falls back across Windows download clients. Keep the setup transcript and the *first* error when
reporting.

**No NVIDIA GPU, or limited disk.** Use `-SkipHeavy`. The document, PDF, OCR, browser, native CLI
and developer layers all remain.

**Live `tshark` capture unavailable.** Install Npcap manually only if you need it, or use the
`pktmon` → `etl2pcapng` → `tshark` workflow.

---

## Contributing

Read [docs/agent-rules.md](docs/agent-rules.md) before changing installation code — it defines the
install channels, PATH hygiene rules and the add-a-tool workflow. After touching the builder or a
package group:

```powershell
.\run-gate.ps1                    # smoke test + all five suites; THIS is the pre-commit gate
.\run-gate.ps1 -Phase <label>     # also append to the ledger and compare against the last phase
.\run-gate.ps1 -Only smoke        # smoke test alone
```

`run-gate.ps1` is the gate, not `smoke-test.ps1` alone: it runs the smoke test AND each suite
directly, so a smoke test that dies early cannot hide a failing suite. Run
`.\bootstrap.ps1 -RefreshToolbox` first only when you have touched the builder or a package group.

All failures must be resolved before committing; warnings cover optional capabilities and do not
fail the gate. With `-Phase`, the ledger in `logs/gate-phases.log` compares this run against the
previous one: a suite count that **falls** is a hard failure, because it means lost coverage, while
one that rises is reported as a non-fatal `TRANSITION`.

New rules, gates and lints carry one extra obligation: mutation-test before trusting them. Break
the thing the check guards, confirm exactly one failure naming the right file, restore, and put the
mutation result in the commit message rather than the green run. A check nobody has broken is a
check nobody has verified. Open items are in [BACKLOG.md](BACKLOG.md).

Winget IDs resolve against current manifests and Python requirements resolve at install time, with
the actual result recorded locally. That favours current security fixes over bit-for-bit
historical reproduction, which is a deliberate trade.

## Licence

[MIT](LICENSE).
