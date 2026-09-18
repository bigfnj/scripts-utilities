# Engineering record

What was **refuted**, what was **retracted**, and what was **decided deliberately**. Separate from
`BACKLOG.md`, which holds only open work.

This file exists because a backlog is a bad place to keep a decision. An entry that says "don't do
this, here is the measurement" reads identically to an entry that says "do this" once it has
scrolled past, and the cost is real: two items closed below had already been fixed, and acting on
either would have meant hunting a bug that was not there. Anything recorded here is closed. Do not
re-open it without new evidence, and if you have new evidence, say what changed.

Every entry names the file, the symbol and the measurement that settled it. A claim with neither is
not a decision, it is an opinion.

---

## Refuted: the premise did not hold

### `catalog.json` `llm.runtime` is dead code

**The key does not exist.** Closed 2026-09-17, measured three ways:

- Through the shipped reader: `(Get-Catalog).llm.PSObject.Properties.Name` returns `$comment`,
  `endpoint`, `models_base`, `models_24gb`, `tier_24gb_min_vram_mb`, `reranker`. `-contains
  'runtime'` is `False`.
- As a JSON key: the regex `"\s*runtime\s*"` over `catalog.json` matches **0** times. The six
  textual hits for "runtime" are all prose inside `notes` / `$comment` (JS runtime, CUDA runtime,
  onnxruntime, "local LLM runtime").
- On the consumer side: `scripts/install-llm.ps1` reads `(Get-Catalog).llm` and references
  `.runtime` **0** times.

The backlog claimed this was "the only survivor" of a dead-code bullet, verified 2026-09-11. That
verification was wrong. The key was already gone. **Do not add it.**

### A doc block sits above the wrong function in `lib/common.ps1`

**Not where the backlog said, and that half is fixed.** The entry named the venv-CLI-wrapping doc
block as stranded above `Set-NodeSystemCaBundle`. Checked 2026-09-17: that block sits directly
above `New-VenvCliWrappers`, which is the function it documents, and `Set-NodeSystemCaBundle`
carries its own accurate comment. Nothing is misplaced there.

A **different** stranded block did exist and was fixed the same day: `Add-UserPathEntry`'s doc
comment had been left above `Invoke-Native` when that function was inserted between the two, so its
"this function" and its "NO -DryRun BRANCH" paragraph read as claims about a wrapper that has
neither a PATH nor a registry write. Moved back.

The lesson is the one the backlog header already states: resolve an entry by its **symbol**, not by
its `file:line`. Both halves of this entry were about the same class of drift and only one was real.

---

## Decided: not this repository's problem

### Machine-state damage the PATH/toolbox audit did not cover

The 2026-09-10 deletion took out more than the toolbox: the same shape recurs across
`~/.dotnet/tools`, the NuGet package cache and the winget package store, where the payload survived
and the shim or registration died. Recorded because the pattern is worth recognising, closed because
none of those are installed, owned or repaired by this repository. A toolbox bootstrap that starts
repairing unrelated package managers is a worse tool.

---

## Decided: deferred, with the reason

### An opt-in `llama.cpp` engine for the local-LLM stack

Deferred by the owner, 2026-09-17. Ollama already satisfies the endpoint contract the stack is
built around (`http://127.0.0.1:11434/v1`, OpenAI-compatible), so a second engine doubles the
install surface, the shim surface and the gate surface for no capability this box lacks today.
The implementation sketch (detect a CUDA GPU, fetch and SHA-verify a prebuilt `ggml-org/llama.cpp`
release into `native\`, wrap `llama-server`/`llama-cli`, expose the same endpoint) is sound and
remains the right design if a reason appears. It has no reason today.

### Native Windows ARM64 support

Deferred. `scripts/build-devtoolbox.ps1` and the optional JDK/Ghidra paths are x64-only, and
`install-ghidra.ps1` refuses anything else explicitly rather than half-working. Closing it properly
means an ARM64 matrix for every winget id, every GitHub release asset and the Python wheel set,
which dwarfs everything else in the backlog. No ARM64 hardware is in scope.

### A Python constraints or lock strategy

Deferred, and the tension is the reason rather than the effort. A pinned lock file makes the venv
reproducible and simultaneously blocks routine security updates to the same packages; an unpinned
set is what this repo has, and it drifts. Both failure modes are real and the repo has been bitten
by the second (an `onnxruntime-gpu` update silently fell back to CPU). Recorded so it is not
re-litigated without someone deciding which failure they prefer.

### `curl_cffi` is kept on a published benchmark, not on a local measurement

`catalog.json` carries `curl_cffi` as an opt-in `default: false` entry for the `browse` CLI's first
rung. The justification is an independent May 2026 benchmark where it scored 26 OK / 2 blocked over
31 anti-bot targets, tying a 130 MB patched Chromium fork from a 6.4 MB wheel.

**On this box it bought nothing.** Measured 2026-09-17, httpx versus `impersonate="chrome"`,
interleaved over the same eight public targets from one residential IP: **0 of 8 outcomes changed**.

Kept anyway, because the published result is real, because another IP or target set may differ, and
because `browse --rung direct --no-impersonate` makes the comparison repeatable at any time.
**Removal trigger, stated so it can be acted on without re-deciding:** if a second sweep from a
different IP also finds no difference, delete the catalog entry, the `--no-impersonate` flag and the
test that asserts both browse extras are on the `pip-toolbox` channel.

### `browse` is not in `manifest/tools.json`

Left as it is, deliberately. `browse` follows the provisioner pattern (`scripts/install-browse.ps1`,
outside `catalog.json`) that Ghidra and the LLM stack already use, so the generated per-workstation
manifest never records it and the smoke test's Phase-1 binary sweep cannot see it.

This cannot be "fixed" by editing a tracked file: `manifest/tools.json` is gitignored and generated
per workstation by `Add-WinManifest`. The real choice is between the status quo and calling
`Add-WinManifest` from the installer. The status quo wins: the dedicated `browse` group in
`scripts/smoke-test.ps1` asserts the shim resolves, the version matches the repo and
`browse --selftest` passes, which is strictly stronger than a presence check. The asymmetry is
intentional, not an accident.

---

## Scoped, not done: a measurement instead of an attempt

### The suites never run under `Set-StrictMode`

Open in spirit, but no longer vague. The backlog said three defences in `lib/ShimPlan.ps1` and
`lib/path-registry.ps1` are written against conditions StrictMode would surface, and that closing
it means "expect real work". Measured 2026-09-18, running each suite under
`Set-StrictMode -Version Latest` with `$ErrorActionPreference = 'Stop'`:

| suite | under StrictMode |
|---|---|
| AgentDiscovery | 19 passed, 0 failed |
| Core | 27 passed, 0 failed |
| GateChecks | 43 passed, 0 failed |
| Installer | 124 passed, **1 failed** |
| Render | 4 passed, **19 failed** |
| SmokeLint | 9 passed, **9 failed** |
| Triage | 11 passed, **20 failed** |

**49 failures across four suites.** Each one is either a latent bug in the code under test or an
artefact of the test harness, and telling those apart is the work. That is a scoped project with a
known starting point, not a cleanup, and it should be taken on deliberately rather than squeezed
into a session doing something else. `scripts/build-devtoolbox.ps1` already runs under StrictMode,
which is why the Installer suite is nearly clean.

Note for whoever picks it up: turn it on **one suite at a time**, Render first (19 failures, the
smallest self-contained subject), and resist the temptation to soften an assertion to make StrictMode
pass. A test that stops asserting is worse than a test that does not run.

### `logs/` holds three inputs inside a directory whose name invites deletion

`logs/` is gitignored, and three files in it are **inputs, not output**:

- `logs/path-backup-*.json` - what `consolidate-path.ps1 -Restore` and `-FromBackup` read. The
  2026-09-09 backup is the only surviving record of the pre-outage PATH order.
- `logs/shim-sources.json` - the shim provenance fallback.
- `logs/gate-phases.log` - the ledger `run-gate.ps1` compares against. Delete it and drift
  detection silently restarts with no baseline.

Not moved, and the reason is the cost of the move rather than disagreement with the item. It touches
`lib/path-registry.ps1`, `lib/ShimPlan.ps1`, `scripts/consolidate-path.ps1`, `run-gate.ps1`,
`.gitignore`, `README.md` and `docs/agent-rules.md`, and retargeting `gate-phases.log` resets the
ledger baseline for every checkout at once - so it must happen when nothing else is mid-run.

**If you do it, copy rather than move.** The files it protects include one irreplaceable record, and
a relocation that half-succeeds is worse than the directory name.
