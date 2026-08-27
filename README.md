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
user PATH and the venv CLIs are wrapped into `native\bin`.

**The venv `Scripts` directory is deliberately *not* on PATH.** Exposing a Python 3.11 `python.exe`
is what trips corporate "unsupported Python" compliance scanners. A bare `python` stays your
sanctioned system version; the toolbox interpreter is reached explicitly via `%TOOLBOX_PYTHON%`.
An agent that reads the discovery block knows this and stops guessing.

**A manifest to check before installing.** `manifest/tools.json` records what is present and
whether the toolbox installed it. "Check this file before installing anything" is a cheap
instruction that prevents the most common and most annoying agent failure mode.

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

### Install

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
.\fresh-toolbox-setup-runner.ps1 -SkipWDK                            # no poolmon/cdb/kd
.\fresh-toolbox-setup-runner.ps1 -InstallGhidra                      # + Ghidra and a private JDK 21
.\fresh-toolbox-setup-runner.ps1 -InstallLlm                         # + local Ollama stack
```

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
| **cli-tools** (14) | `gh` GitHub CLI · `fzf` fuzzy finder · `bat` syntax-highlighted cat · `delta` git diff pager · `just` task runner · `hyperfine` benchmarking · `sops` encrypted secrets · `age` file encryption · `tokei` LOC stats · `podman` per-user containers, no elevation · `docker-compose` · `trurl` URL parsing · `yt-dlp` media downloader · `deno` secure JS/TS runtime, also yt-dlp's JS challenge runtime |
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
(embeddings); 24 GB or more also gets `mistral-small`. A `bge-reranker-base` cross-encoder runs via
the toolbox `onnxruntime` (`-SkipReranker` to omit). The model set is defined in `catalog.json`
under `llm`.

---

## Day-to-day

```powershell
.\bootstrap.ps1                    # build if missing, then install all groups
.\bootstrap.ps1 -DryRun            # describe changes, change nothing
.\bootstrap.ps1 -Only cli-tools    # comma-separated groups
.\bootstrap.ps1 -RefreshToolbox    # rerun the idempotent builder
.\scripts\smoke-test.ps1           # functional gate; must pass before committing
```

Set `CODEX_TOOLBOX` before running to relocate the toolbox root.

### Uninstall

```powershell
.\scripts\uninstall-toolbox.ps1 -DryRun            # exactly what would change
.\scripts\uninstall-toolbox.ps1                    # toolbox layer only
.\scripts\uninstall-toolbox.ps1 -RemoveWingetTools # also the gap-fill tools
```

By default it removes only what the toolbox owns and can safely reverse: the `DevToolbox`
directory, the PATH entries and env vars it added, the agent-discovery blocks, the manifest, and
the Sysinternals EULA keys. With `-RemoveWingetTools` it also uninstalls gap-fill tools, but **only
those the manifest records as `installed_by_toolbox=true`** — anything that pre-existed is left
alone.

---

## Repository layout

```text
bootstrap.ps1                       main idempotent entry point
fresh-toolbox-setup-runner.ps1      fresh-workstation orchestration and logging
catalog.json                        the tool catalog: groups, layers, LLM models
lib/common.ps1                      install/PATH/manifest/agent-discovery helpers
lib/catalog.ps1                     catalog parsing
modules/                            cli-tools, security, extras groups
scripts/build-devtoolbox.ps1        Python + native DevToolbox builder
scripts/install-ghidra.ps1          optional digest-verified Ghidra/JDK
scripts/install-llm.ps1             optional local LLM stack
scripts/install-machine-scope.ps1   one-elevation machine-scope pre-install
scripts/install-whisper.ps1         whisper.cpp + a GGML model
scripts/uninstall-toolbox.ps1       full-reset uninstaller
scripts/smoke-test.ps1              repository-level functional gate
gui/toolbox-gui.ps1                 WinForms front-end
docs/agent-rules.md                 contribution + install-channel rules
docs/tools-reference.md             how to use each tool
tasks/fresh-toolbox-setup.md        replacement-workstation checklist
```

**Generated, never committed:** `manifest/tools.json`, `logs/fresh-workstation/`, and
`%LOCALAPPDATA%\DevToolbox\toolbox-manifest.json`. They describe one specific machine.

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
.\bootstrap.ps1 -RefreshToolbox
.\scripts\smoke-test.ps1
```

All smoke-test failures must be resolved before committing; warnings cover optional capabilities
and do not fail the gate. Open items are in [BACKLOG.md](BACKLOG.md).

Winget IDs resolve against current manifests and Python requirements resolve at install time, with
the actual result recorded locally. That favours current security fixes over bit-for-bit
historical reproduction, which is a deliberate trade.

## Licence

[MIT](LICENSE).
