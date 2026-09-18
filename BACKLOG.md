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
`checks=6 smoke=82/4/0 agentdiscovery=19 core=27 gatechecks=43 installer=125 render=23 smokelint=18
triage=31`, and parity green on all seven suites under CI's invocation *and* CI's error preference.

The previous 29 open items are closed: fixed, refuted, or recorded as decisions in
`docs/engineering-record.md`. What follows is what this round surfaced.

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

## Security - HIGH

### `Get-HFFile` puts the HuggingFace bearer token on curl's command line

`scripts/install-whisper.ps1`, `Get-HFFile`: the token is read from
`%USERPROFILE%\.cache\huggingface\token` and then passed as a process argument,
`@("-H", "Authorization: Bearer $tok")`, to `curl.exe`.

A Windows process command line is readable by any other process on the box through
`Get-CimInstance Win32_Process`, so the token is exposed for the lifetime of the download - and this
machine runs Sysmon with `ProcessCreate` capture, which records command lines to an event log.

The function already knows: its own comment says nothing may echo `$curlArgs` and cites
`install-ghidra.ps1`'s `Get-Json` on what a logged token costs here. Not echoing it does not help,
because the argument vector *is* the exposure.

**Fix sketch, in preference order.** `curl -K <configfile>` reads options from a file, so
`header = "Authorization: Bearer ..."` in a short-lived file under `%TEMP%` keeps it off every
command line; delete the file in a `finally`. `--netrc-file` is the other supported route.
`Invoke-WebRequest` with a header hashtable avoids a command line entirely but is Schannel-backed,
which `docs/agent-rules.md` records as failing inside agent sandboxes.

Mitigating, and the reason this is HIGH rather than urgent: `install-whisper.ps1` is manual-only -
nothing in the repo invokes it - and the token is a read scope.

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

**Recommendation: report the counts, do not add pruners.** See the rule at the top of this file. A
one-line count per pattern in the smoke test costs nothing and carries no blast radius, and the total
at stake across all four is under 200 KB. If a pruner is ever wanted, the blast radius of each is
narrow and fixed (a literal prefix plus a timestamp suffix, one directory, no other files match), and
that should be stated in the proposal rather than discovered afterwards.

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

### The gate cannot print `gate passed` from inside a worktree

`scripts/smoke-test.ps1`, the agent-discovery group. The generated block embeds `$RepoRoot`, and the
group compares it against the four deployed copies in `%USERPROFILE%`, which name the main checkout.
Run from `.claude/worktrees/agent-*`, four checks fail with `Managed by:` pointing at the worktree.

Measured by two agents independently this round: baseline `73 passed / 3 warnings / 5 failed` from a
worktree before either changed anything, with an identical failure set afterwards. The check even
annotates the case correctly on the next line ("names a live checkout of this repo, not the one
running this gate") and still counts it as a failure.

Consequence worth naming: an agent working in a worktree cannot get a clean gate, so "gate passed"
stops being usable as its done-criterion and has to be replaced with "the failure set is unchanged
from baseline". Repairing it the obvious way is actively harmful - it would deploy a `CLAUDE.md`
into the user's profile pointing at a temporary worktree.

Candidate fix: when the running checkout is a worktree (`git rev-parse --git-common-dir` differs from
`--git-dir`), report the four as SKIPPED-with-reason rather than FAILED, and say so on every run.

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

Two items are open but already measured, and the measurement lives in
`docs/engineering-record.md` rather than here so it is read before work starts:

- **`Set-StrictMode` across the suites.** 49 failures across four suites (Render 19, Triage 20,
  SmokeLint 9, Installer 1; AgentDiscovery, Core and GateChecks are clean). Do it one suite at a
  time, and do not soften an assertion to make it pass.
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
