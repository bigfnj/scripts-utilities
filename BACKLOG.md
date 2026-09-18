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
`checks=6 smoke=86/4/0 agentdiscovery=19 core=27 gatechecks=43 installer=126 render=28 smokelint=18
triage=31`, and parity green on all seven suites under CI's invocation *and* CI's error preference.
All seven suites also pass under `Set-StrictMode -Version Latest`, and the smoke test passes from
inside a git worktree.

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

## Correctness - MEDIUM

### `browse`'s journal records the rung that returned the MOST TEXT, not the rung that was NEEDED

`tools/browse/toolbox_browse/cli.py`, `run()` and `journal_save()`. The driver keeps whichever rung
produced the most characters and writes that host into the journal, so the next fetch of that host
starts there. A thin-but-working page therefore teaches the journal to prefer a more expensive rung
over a few extra characters.

Observed 2026-09-17 while proving the reader rung: `example.com` was pinned to `reader` when
`direct` had served it perfectly. The entry was removed by hand. Inert in practice today, because
the reader rung is opt-in behind `--allow-reader` and the browser rung needs a running Chrome - but
the preference is wrong in principle and will bite the moment either is routinely on.

A fix needs a rule for "needed", and that needs more than one target to measure against. Candidate:
record the FIRST rung that cleared `MIN_TEXT`, and only prefer a later rung when an earlier one
returned nothing at all.

### `diagnose()` never runs on the reader rung, so a reader refusal cannot set `.challenge`

Same file. `fetch_direct` and `fetch_chrome` both call `diagnose()`; `fetch_reader` does not, so a
`r.jina.ai` response that is itself a refusal comes back as a thin success rather than a named
block.

Deliberately not fixed when found: running `CHALLENGE_TEXT` over Jina's markdown envelope is exactly
the false-positive class that function's own comment documents (an article about bot detection was
once reported as a DataDome challenge), and no blocked target was available to measure a real
refusal against. Needs a real blocked URL before the detector can be trusted on this rung.

---

## Housekeeping - LOW

### Four files under `logs/` grow without a retention policy

Audited 2026-09-18, measured on this box, ranked by growth rate. `Remove-StaleBackups` added this
round covers **only** `<leaf>.bak-yyyyMMdd-HHmmss` agent-file backups; none of these share that
pattern or that directory.

| # | pattern | writer | on disk now | per run |
|---|---|---|---|---|
| 1 | `logs/fresh-workstation/setup-*.log` | `fresh-toolbox-setup-runner.ps1`, `Start-Transcript` | 5 files, 141 KB | 1 file, 7-103 KB |
| 2 | `logs/path-backup-*.json` | `lib/path-registry.ps1`, `Backup-PathRegistry` | 5 files, 20 KB | 1 file, 2-6 KB |
| 3 | `logs/machine-path-intended-*.txt` | `scripts/consolidate-path.ps1` | 0 files (new today) | 1 file, 2-4 KB |
| 4 | `logs/gate-phases.log` | `run-gate.ps1`, `Add-Content` | 15 lines, 1.5 KB | 1 line, ~100 B |

Notes that change what to do about each:

- **(1) is the only one with real volume.** The transcript captures winget output, so a full
  fresh-setup run is ~103 KB and a failed quick run is ~7 KB. `Stop-Transcript` is in a `finally`,
  so the handle is always closed - this is purely retention.
- **(2) has documented recovery value.** `consolidate-path.ps1 -Restore` and `-FromBackup` read
  these, and `Backup-PathRegistry`'s own docblock calls the 2026-09-09 file "the only surviving
  record" of the pre-outage PATH order. Do not prune this one without keeping that file.
- **(3) is new this round and is my doing.** Renaming the fixed `machine-path-pending.txt` to a
  timestamp made the filename true (it is written *before* elevation and was left behind claiming a
  pending change that had already been applied) and turned one overwritten file into a growing set.
- **(4) is a non-issue by design.** 15 lines across the repo's whole history; the ledger's value is
  the history.

**DONE, as reporting rather than pruning**, 2026-09-18. `scripts/smoke-test.ps1` has a
`logs retention` group that counts and sizes all four patterns on every run, warning at 25 files or
10 MB per pattern - thresholds chosen to be reachable (about twenty more runs at one file per run)
rather than decorative, and mutation-tested by dropping the bar to 2 and watching two OK lines become
WARNs.

Deliberately no pruner, and the trade is the reason: under 200 KB is at stake in total, this box has
lost ~123,605 files to a script that deleted what it should not have, and two of the four patterns
are **inputs** rather than output. The remaining decision, if anyone ever wants automatic pruning, is
recorded here: the blast radius of each is narrow and fixed (a literal prefix plus a timestamp
suffix, one directory, nothing else matches), and that should be stated in the proposal rather than
discovered afterwards.

### The `%TEMP%` fixture sweep's 30-minute window is an assumption, not a measurement

`tests/Invoke-InstallerTests.ps1`. Three module-scope fixture roots (`installer-tests-*`,
`agentblock-*`, `builder-tests-*`) have cleanups at column 0 rather than in a `finally`, which the
file documents, so a throw at module scope strands a directory. The self-healing sweep at the top of
the suite collects them, and this round it was age-gated to 30 minutes so two concurrent runs stop
deleting each other's live fixtures (before the gate: two concurrent runs scored 106/2 with the
failures landing on the catalog fixture tests).

30 minutes is three orders of magnitude beyond the observed run time (seconds), so it is a safe
number - but it is a number, and nothing asserts the suite finishes inside it. If this suite ever
grows a long-running test, the gate becomes wrong in the dangerous direction. Currently 0 orphans on
this box, so the sweep is working.

### A null environment read cannot be linted here, and there are 30 of them

`[Environment]::GetEnvironmentVariable(...)` returns `$null` for a value that does not exist, and a
method call on the result throws. One instance was fixed this round -
`scripts/smoke-test.ps1`'s 4095-char PATH truncation check could not fire on a fresh profile because
`$null.TrimEnd(';')` threw and the file sets neither `Stop` nor `StrictMode`, so it printed red,
continued, and emitted no verdict at all.

Measured across the repo: **30 such reads in 7 files** (`bootstrap.ps1`, `lib/common.ps1`,
`modules/security.ps1`, `scripts/build-devtoolbox.ps1`, `scripts/smoke-test.ps1`,
`scripts/uninstall-toolbox.ps1`, `tests/Invoke-InstallerTests.ps1`). **Zero** are a direct
`GetEnvironmentVariable(...).Method` chain, so every one goes through an intermediate variable and a
precise lint would need dataflow analysis. A crude AST rule would false-positive heavily.

Recorded rather than attempted, so the next person does not start by writing the lint. The tractable
version is narrower: make `lib/path-registry.ps1`'s `Get-RawPath` the only PATH reader and give it a
non-null contract, then the remaining reads are non-PATH and individually reviewable.

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

---

## Features

- `install-machine-scope.ps1`: the per-package scope override moved into `catalog.json` this round
  as a top-level `machine_scope_overrides` block, keyed by winget id. It is keyed by id and not by a
  `tools[]` field because 7 of the 10 `machine_scope_ids` have no `tools[]` entry at all - they are
  stage-1 natives from `build-devtoolbox.ps1` - so a `tools[]`-only read would have been unreachable
  code. If more per-package install knobs appear, they belong in the same block.
