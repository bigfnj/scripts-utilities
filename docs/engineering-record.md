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

## Measured first, then done - or deliberately not

### `Set-StrictMode` across the suites - DONE, all seven

Measured, then done, 2026-09-18. The starting position was **49 failures across four suites**, which
looked like 49 problems and was three:

| suite | before | after |
|---|---|---|
| AgentDiscovery | 19 / 0 | 19 / 0 |
| Core | 27 / 0 | 27 / 0 |
| GateChecks | 43 / 0 | 43 / 0 |
| Installer | 124 / **1** | 126 / 0 |
| Render | 4 / **19** | 28 / 0 |
| SmokeLint | 9 / **9** | 18 / 0 |
| Triage | 11 / **20** | 31 / 0 - see below |

**What the 49 actually were.** Two causes, each in two places:

- *One value unrolled on the way out of a function.* All 10 SmokeLint and Installer failures were
  `.Count` read off a function result. A function's output is ENUMERATED on return, so a
  `@()`-bounded collection leaves as `$null` when empty and as a bare scalar when it holds one
  item, and Windows PowerShell answers `$null.Count` with 0 - which is why they read green.
- *Fixtures that did not match the shape of real data.* The 39 Render and Triage failures were
  properties the production objects always carry and the fixtures never supplied. A burst has seven
  properties and the renderer formats all seven; the fixture had three.

**The finding that justified the whole exercise.** Those tests were not merely "not throwing" - they
were asserting against nonsense. Measured on the pre-fix Render fixture: the hero tile read
`Largest burst: rm.exe at .`, the burst meta read `<div class="meta"> to  &middot;  deletions ...`,
the burst directory `<ul>` never rendered at all, and the Sentinel-paths tile printed
`<span class="value">4</span>` directly above `<p class="none">None this period.</p>` - contradicting
itself in two adjacent elements, under 23 green tests. StrictMode did not create work here. It
revealed that some existing coverage was fictional.

Render gained 5 assertions (23 -> 28) that check rendered output rather than absence of a throw, two
of them reaching escape sites nothing had reached before.

### Triage needed one line in a frozen file, and got it

**RESOLVED 2026-09-18 with the owner's agreement**, after being stopped on the freeze first. The
stop was right: the record of *why* is the valuable part, because the obvious alternative was worse
than the bug.

The Triage fixture was already production-accurate, property for property. The defect was in the
subject: `Get-FxTriage` walks a heterogeneous set and read members blind -

```powershell
foreach ($set in @($Facts.TopProcesses, $Facts.Bursts, $Facts.Novel, $Facts.Sentinels)) {
    foreach ($x in @($set)) {
        $n = if ($x.Name) { $x.Name } elseif ($x.Image) { $x.Image } else { $null }
        if ($x.Dir) { $okDir.Add(...) }
```

`TopProcesses` has `Name` + `Count` and no `Dir`; `Bursts` has `Image` + `Count` + `Seconds` and no
`Name`. Both are correct production shapes and both throw under StrictMode. It is two properties,
not one: fixing `Dir` then throws on `Name`.

**The one-line fix** is `$x.PSObject.Properties['Dir']` instead of `$x.Dir`, which is exactly what
`ForensicsReport.Render.ps1` already does for its own optional property. Not made, because
`scripts/ForensicsReport.Triage.ps1` is in the frozen forensics subsystem.

**And the tempting alternative is a trap, which is the part worth keeping.** Adding `Dir` to the
`TopProcesses` fixture makes the suite pass - and the moment anyone gives that bolted-on field a
plausible directory, `$okDir` widens and a finding citing a path that was never shown comes back
*kept*. Every "is DISCARDED" test in that suite would then pass for the wrong reason, which is the
one failure the suite exists to prevent. So the passing state is worse than the failing one, and
that is why it was not taken.

The prompt builder was unaffected: `ConvertTo-FxTriagePrompt` reads `Novel` and `Sentinels`, which do
carry `Dir`, and both its tests passed under StrictMode throughout. All 20 failures were inside
`Get-FxTriage`.

**What was changed.** `Get-FxTriage` now probes with `$x.PSObject.Properties[...]` rather than
reading blind, exactly as `ForensicsReport.Render.ps1` already does for its own optional property.
Applied in two places, because fixing the first exposed the second:

- the fact loop, for `Name` / `Image` / `Dir` across the four heterogeneous collections;
- the **degraded-model path**, for `findings` and `concern`. That second one matters more than it
  looks: a local model returning valid JSON of the wrong shape is a case this function is written to
  survive, and under StrictMode reading an absent `.findings` threw out of the one function whose
  stated contract is "nothing below may throw out of here". The last two strict-mode failures were
  the two tests asserting exactly that resilience. A defence that throws on the input it exists for
  is not a defence.

Behaviour is unchanged for every real input: a member that is present reads as before, and one that
is absent was already treated as `$null` by the surrounding guards. Verified 31/0 both with and
without StrictMode, and `tests/Invoke-TriageTests.ps1` now sets StrictMode itself. The sibling
forensics suites are untouched at Core 27/0 and Render 28/0. Mutation-tested: reverting one probe to
a blind read fails the suite with "The property 'Dir' cannot be found".

### The Sysmon config check failed on every fresh clone, and no frozen file was needed

`scripts/smoke-test.ps1` compares the deployed `filedelete-forensics.xml` against the repo template
rendered for the current profile. `core.autocrlf=true` with no `.gitattributes` makes that template's
bytes a property of the **checkout**: measured 2026-09-18, a long-lived working copy carries LF
(15,912 bytes, byte-identical to `git show HEAD:`) while a fresh checkout of the same commit carries
CRLF (16,163). Exact string equality therefore reported the deployed config as stale on every fresh
clone - the first thing a new workstation would see - and on every git worktree.

**Fixed in the comparison, which is `smoke-test.ps1`'s own code, so the frozen subsystem was not
touched.** Three states instead of two, because collapsing them would hide a real staleness: an
exact match is silent, a line-endings-only match passes *and says which one it got*, and anything
else still fails. Sysmon parses XML, where CRLF and LF are equivalent.

Verified all three: exact on main, line-endings on a probe worktree, and a one-tag content mutation
in the worktree template still FAILS. Rejected `.gitattributes`, which would renormalise the whole
tree - the exact condition `lib/ShimFormat.ps1`'s header is written to work around.

With this and the worktree re-basing, `smoke test passed` from inside a worktree for the first time:
61 passed, 5 warnings, **0 failed**.

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

### Four `logs/` patterns grow without retention - DONE as reporting, deliberately not pruned

Audited 2026-09-18, measured on this box, ranked by growth rate. `Remove-StaleBackups` added the
same round covers **only** `<leaf>.bak-yyyyMMdd-HHmmss` agent-file backups; none of these share that
pattern or that directory.

| # | pattern | writer | on disk then | per run |
|---|---|---|---|---|
| 1 | `logs/fresh-workstation/setup-*.log` | `fresh-toolbox-setup-runner.ps1`, `Start-Transcript` | 5 files, 141 KB | 1 file, 7-103 KB |
| 2 | `logs/path-backup-*.json` | `lib/path-registry.ps1`, `Backup-PathRegistry` | 5 files, 20 KB | 1 file, 2-6 KB |
| 3 | `logs/machine-path-intended-*.txt` | `scripts/consolidate-path.ps1` | 0 files (new that day) | 1 file, 2-4 KB |
| 4 | `logs/gate-phases.log` | `run-gate.ps1`, `Add-Content` | 15 lines, 1.5 KB | 1 line, ~100 B |

Notes that change what to do about each:

- **(1) is the only one with real volume.** The transcript captures winget output, so a full
  fresh-setup run is ~103 KB and a failed quick run is ~7 KB. `Stop-Transcript` is in a `finally`,
  so the handle is always closed - this is purely retention.
- **(2) has documented recovery value.** `consolidate-path.ps1 -Restore` and `-FromBackup` read
  these, and `Backup-PathRegistry`'s own docblock calls the 2026-09-09 file "the only surviving
  record" of the pre-outage PATH order. Do not prune this one without keeping that file.
- **(3) was introduced by the same round.** Renaming the fixed `machine-path-pending.txt` to a
  timestamp made the filename true (it is written *before* elevation and was left behind claiming a
  pending change that had already been applied) and turned one overwritten file into a growing set.
- **(4) is a non-issue by design.** 15 lines across the repo's whole history; the ledger's value is
  the history.

**Done as reporting rather than pruning.** `scripts/smoke-test.ps1` has a `logs retention` group
that counts and sizes all four patterns on every run, warning at 25 files or 10 MB per pattern -
thresholds chosen to be reachable (about twenty more runs at one file per run) rather than
decorative, and mutation-tested by dropping the bar to 2 and watching two OK lines become WARNs.

Deliberately no pruner, and the trade is the reason: under 200 KB is at stake in total, this box has
lost ~123,605 files to a script that deleted what it should not have, and two of the four patterns
are **inputs** rather than output (see the entry above). If anyone ever wants automatic pruning, the
blast radius of each is narrow and fixed - a literal prefix plus a timestamp suffix, one directory,
nothing else matches - and that belongs in the proposal rather than being discovered afterwards.

### The manifest was written BEFORE the build's own smoke step - FIXED with two writes, not by moving one

`scripts/build-devtoolbox.ps1`. `Write-Manifest` ran at the `manifest` step and `Run-Smoke` at the
`smoke` step after it, and `Run-Smoke`'s first act threw on a non-zero `pip check`. Measured twice
on this box 2026-09-18: the build died and still left a manifest asserting `degraded: []` with a
fresh `created_at`. The builder's own header notes that `bootstrap.ps1` gates readiness on the
manifest merely EXISTING, so that pair handed bootstrap a readiness token the build never earned.

**Rejected: writing the manifest only at the end.** It is the obvious fix and it is worse. A build
that failed in `Run-Smoke` would then leave no manifest at all, and because readiness is gated on
the file existing, bootstrap would report "not ready" for a toolbox that is fine apart from one
probe. A box with a working toolbox and no manifest is a worse starting state than the reverse.

**Done:** the early write stays as the floor, `Invoke-Checked` gained an opt-in `-Soft` that records
into the existing degraded ledger instead of throwing, every probe in `Run-Smoke` passes it, and the
manifest is written again after the smoke step. The build then still exits non-zero, decided by
looking for the ledger's `smoke:` prefix - which is what keeps an installer's best-effort soft
failure (tessdata, Ghostscript, an OCR language) non-fatal while a failed probe stays fatal.

Second benefit, not the motivation but worth as much: `pip check` is the FIRST probe, so its throw
meant the other five never ran. On this box that hid five clean results behind one orphaned package,
and they had to be run by hand to discover that. All six now run every time.

Verified against the live failure rather than a fixture: the build ran all six probes, recorded
`smoke: run pip dependency check failed (exit 1)`, re-wrote the manifest with that entry, and exited
1 naming the manifest path. Three mutations, one test each and no more: dropping `-Soft` from one
probe, deleting the post-smoke write, and making `-Soft` throw anyway.

### The resolver took the FIRST match in a search root, which is the OLDEST version

Same function, found while deliberately upgrading qpdf to exercise the stale-shim check. The upgrade
did not behave as predicted and that is the finding: `winget upgrade --id QPDF.QPDF -e --scope
machine` installed 12.4.1 and **left 12.3.2 in place**, so `winget list` reported both and
ProgramFiles held two `qpdf.exe`.

Nothing was stale, because both targets existed. The shim kept running 12.3.2 after a successful
upgrade, `qpdf --version` answered 12.3.2, and the stale-shim check passed. Measured: the
enumeration returns 12.3.2 first, so `Select-Object -First 1` pinned the older binary.

**Done:** the exhaustive fallback now sorts by `LastWriteTime` descending within a root. Not by a
version parsed out of the path, because the naming is not one convention here (`qpdf 12.4.1`,
`ImageMagick-7.1.2-Q16-HDRI`, `gs10.07.1`) and a string sort puts `12.4.1` above `12.10.0`. Root
order is unchanged, and an explicit `$CommandSearchPatterns` entry still runs first, so deliberate
preferences stay deliberate.

**The cost, stated rather than hidden:** a hit can no longer short-circuit the walk, since the newest
match is not known until the enumeration finishes. The miss path already paid the full walk, which
BACKLOG measures at 4,048 ms, so the worst case is unchanged and only the lucky-hit case is slower.
That is worth paying at a callsite whose answer is baked into a shim that then looks fine for months.

Verified on the live two-version state before it was cleaned up: the build re-resolved to
`qpdf 12.4.1`. The test uses a synthetic fixture named so the OLDER file sorts first, so it does not
depend on this box, and it carries a control asserting that premise still holds.
