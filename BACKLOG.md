# Backlog - scripts-utilities

## How to work this list

**Open work only.** What was refuted, retracted or decided deliberately lives in
`docs/engineering-record.md`. Read that first: a decision kept in a backlog reads identically to a
task once it has scrolled past, and this list carried two entries that had already been fixed, so
acting on either meant hunting a bug that was not there.

Every entry below names the file, the symbol and the measurement or repro that established it. An
entry with none of those is not a finding.

**Resolve an entry by its symbol, never by its `file:line`.** Line anchors in this repo have gone
stale repeatedly and symbol names have not. If you cannot find the symbol, the entry may already be
closed - check the engineering record before re-deriving it.

**Before you propose a new file deleter, state its blast radius and compare it to the prize.** This
box lost ~123,605 files to a maintenance script once. "Report it" beats "delete it" unless the prize
justifies the category.

---

## Where to pick up - handoff, 2026-09-18

Repo is on `main`, pushed, CI **green on both jobs** (`suites` and `checks`). Gate green:
`checks=7 smoke=87/4/0 agentdiscovery=19 core=27 gatechecks=47 installer=137 render=28 smokelint=18
triage=31`, and parity green on all seven suites under CI's invocation *and* CI's error preference.
All seven suites also pass under `Set-StrictMode -Version Latest`, and the smoke test passes from
inside a git worktree.

One of those four smoke warnings is EXPECTED and is **not** a task. `build is DEGRADED in 1
component(s)` is the toolbox manifest honestly reporting a `pip check` failure that the owner has
decided to keep: an orphaned `timm` another project installed into the shared venv. That decision,
its evidence and its standing consequence are in `docs/engineering-record.md` - read it before
"fixing" the warning, because uninstalling `timm` is explicitly not wanted. The other three
warnings are the long-standing optional ones: `cdb` and `poolmon` need a WDK/SDK install, and the
weekly forensics task is admin-only to read.

The previous 29 open items are closed: fixed, refuted, or recorded as decisions in
`docs/engineering-record.md`. What follows is what this round surfaced, minus what was then fixed
the same day:

- **The HF bearer token is off curl's command line.** `Get-HFFile` now passes the header through
  `curl -K <tempfile>`, removed in a `finally`. Proved by reading the spawned process's own command
  line back through CIM: token present before, absent after, and `curl -sv` confirms the header is
  still sent.
- **`markdownlint-cli` is pinned to 0.48.0** in `catalog.json`, matching what CI installs, so a
  local `npm update -g` can no longer make the local gate stricter than CI.
- **`logs/` growth is reported** by a new smoke group rather than pruned.
- **The gate passes from a worktree.** The agent-block comparison is re-based onto the main
  checkout, derived from the `.git` file with no git invocation, and it announces the re-base on
  every run. Verified from a probe worktree: four failures became four OK.
- **The Sysmon config check no longer fails on a fresh clone.** It was comparing bytes where
  `core.autocrlf` decides them (LF in a long-lived working copy, CRLF in a fresh checkout of the
  same commit). Now three states rather than two: exact match silent, line-endings-only match passes
  *and says so*, real difference still fails. Fixed in `smoke-test.ps1`'s own comparison, so no
  frozen file was touched. With the re-basing above, `smoke test passed` from a worktree for the
  first time - 61 passed, 5 warnings, 0 failed.
- **All seven suites run under StrictMode.** Triage's last 20 needed one line in a frozen file and
  got it, with the owner's agreement. `Get-FxTriage` now probes optional members instead of reading
  them blind - including on the degraded-model path, where an absent `.findings` was throwing out of
  the one function whose contract is "nothing below may throw out of here".
- **`qpdf`'s shim pointed at itself and every build called that OK.** Found by validating the
  deployed toolbox rather than the repo, which is the part worth copying: the repo was green and the
  workstation was not. `Find-Executable` now refuses its own `native\bin`, `smoke-test.ps1` fails on
  a self-referential shim, and `docs/agent-rules.md` states the discovery rule for the six
  machine-scope natives. The deployed activation helpers were also pre-fix, still putting the venv
  `Scripts` on PATH - regenerated. **A green gate does not mean a correct workstation; run
  `build-devtoolbox.ps1` and read what it resolves.**
- **Then upgrading qpdf on purpose, to exercise the stale-shim check, found a second bug.** The
  upgrade did not behave as predicted: `winget upgrade` installed 12.4.1 and **left 12.3.2 in
  place**, so nothing was stale, both targets existed, and the shim went on running the old binary
  after a successful upgrade. The resolver's `Select-Object -First 1` was taking the OLDEST
  version-stamped directory; it now sorts by `LastWriteTime`. Verified live: the shim re-resolved to
  12.4.1. **Deliberately breaking a thing to test a check is worth doing even when the check does
  not fire - what it does instead is the finding.**
- **A failed build no longer writes a manifest claiming success.** `Write-Manifest` ran before
  `Run-Smoke`, so a throw in the smoke step left `degraded: []` on disk for a build that died, and
  `bootstrap.ps1` gates readiness on that file existing. Now written twice, with `Invoke-Checked
  -Soft` recording probe failures into the ledger; the build still exits non-zero. Side benefit that
  mattered as much: `pip check` is the first probe, and its throw had been hiding the other five.
- **The last five backlog items were then cleared, and three of them were wrong about themselves.**
  Two named a fix that would not have worked. Full write-up in `docs/engineering-record.md`; the
  transferable part is that **an entry's proposed remedy is a hypothesis and only its measurement is
  a finding.** Highlights: `subprocess.run`'s `timeout=` does not bound the call when stdout is a
  pipe and the process leaves a grandchild holding the write end (measured: 2s asked, 20.2s elapsed;
  a temp file gives 0.1s and no timeout at all), so soffice was never slow and the probe was waiting
  on `soffice.bin`. The fixture sweep now deletes on process OWNERSHIP rather than a guessed age.
  And the "needs dataflow analysis" null-read lint became a seventh `env-reads` gate check by asking
  a cheaper question: not whether a null can reach a dereference, but whether the read was written in
  a form that cannot produce one.

**The single most useful thing learned, worth applying before anything below.** A test that passes
locally and fails in CI is an **environment divergence**, and there were three, all of which had
been invisible:

1. **Invocation.** `run-gate.ps1` launches each suite as a `powershell.exe -File` child;
   `gate.yml` invokes `.\tests\X.ps1` in-session. A `GetNewClosure()` scriptblock resolves
   *functions* through global scope, which a nested script's scope is not.
2. **Error preference.** GitHub Actions sets `$ErrorActionPreference = 'stop'` for
   `shell: powershell`; the local gate's children start at `Continue`.
3. **Installed tools.** The `checks` job installs `markdownlint`; the `suites` job does not.

`run-gate.ps1` now re-runs every suite in-session under `Stop` and compares tallies, so all three
fail locally. If you add a test, ask what on this box it is quietly reading.

---

## Open items: NONE

Empty on purpose, and stated rather than left to inference: an empty file and a file whose sections
happen to be blank read the same, which is how the handoff above gets mistaken for a task list.

The five that were here on the morning of 2026-09-18 are all fixed, and the group is worth reading
in `docs/engineering-record.md` before trusting any future entry in this file: **three of the five
overstated their own difficulty and two named a fix that was wrong.** One "needed a rule that needed
measurement" and needed neither, one "needed a real blocked URL" when the detection it wanted was
already sitting in a status code, and one "would need dataflow analysis" when a cheap total rule
closed it outright. An entry's proposed remedy is a hypothesis; only its measurement is a finding.

What remains below is not open work: one deferred decision with its cost written down, and a note
about where per-package install knobs belong.

---

## Scoped elsewhere

The measurement lives in `docs/engineering-record.md` rather than here so it is read before work
starts:

- **`Set-StrictMode` across the suites - DONE, all seven.** Was 49 failures across four suites;
  now 0. It was three causes, not 49: a value unrolled on the way out of a function, fixtures that
  did not match the shape of real data, and blind member reads over heterogeneous or
  deliberately-malformed objects. Read the record for what those tests were actually asserting
  against before StrictMode exposed it.
- **Relocating the three inputs out of `logs/`.** Touches seven files and resets the ledger baseline
  for every checkout at once. **Copy, do not move** - one of the three is the only surviving record
  of the pre-outage PATH order.
- **`logs/` retention - DONE as reporting, no pruner.** A `logs retention` smoke group counts and
  sizes all four growing patterns, warning at 25 files or 10 MB. The record holds the growth table
  and the reason there is deliberately no deleter: under 200 KB total is at stake, and two of the
  four patterns are inputs.

---

## Features

- `install-machine-scope.ps1`: the per-package scope override moved into `catalog.json` this round
  as a top-level `machine_scope_overrides` block, keyed by winget id. It is keyed by id and not by a
  `tools[]` field because 7 of the 10 `machine_scope_ids` have no `tools[]` entry at all - they are
  stage-1 natives from `build-devtoolbox.ps1` - so a `tools[]`-only read would have been unreachable
  code. If more per-package install knobs appear, they belong in the same block.
