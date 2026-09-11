# Backlog - scripts-utilities

## How to work this list

Items came out of a four-agent audit on 2026-09-10 (dead code, non-operable code, leaks and
performance, cross-cutting and security). Everything below **reproduced against the code** -
each entry names the file, the line and the measurement or repro that established it. Where an
audit claim did not reproduce it was dropped rather than recorded, so treat these as verified
starting points, not as suspicions to re-litigate.

Severity is about consequence, not effort. **HIGH** means it silently produces a wrong answer or
destroys something. Fixed items are struck through with the date.

---

## Bugs - HIGH

### 1. ~~The Sysmon config is hardcoded to one profile name, and `-Verify` says it is fine~~ DONE 2026-09-10

`config/sysmon-filedelete.xml` contains the literal `C:\Users\Admin` in **25 places**, including
all three `FileDeleteDetected` *include* rules (`:150-152`). Sysmon's `begin with` does **not**
expand environment variables, and `install-deletion-forensics.ps1:308` deploys the file with a
bare `Copy-Item` - no substitution.

On any machine whose profile is not named `Admin`, the include list matches nothing and the
sensor records **zero deletions**, while `-Verify` (hash + service + driver boot-start) reports
fully green and `smoke-test.ps1` passes. The repo ships a public `irm | iex` bootstrap and both
`modules/security.ps1:82` and `smoke-test.ps1:278` recommend running this on a fresh workstation.

This is the cardinal sin of the whole effort: a forensics sensor that is verifiably, invisibly
blind. Silence looks exactly like "nothing was deleted".

**Fixed 2026-09-10.** `config/sysmon-filedelete.xml` is now a template using `|USERPROFILE|`,
rendered at deploy time into ProgramData by `lib/SysmonConfig.ps1`. The pipe was chosen because
it is illegal in every Windows path, which makes "no placeholder survived" a total assertion
rather than a hopeful one - braces and percent signs are both legal in real paths.

Three things came out of doing it that were not in the original write-up:

- **The fix contained the bug.** `install-deletion-forensics.ps1` self-elevates, and in the
  elevated child `$env:USERPROFILE` is the CONSENTING ADMINISTRATOR's profile. Rendering there
  would have watched the admin's profile on any managed workstation and left the sensor blind
  for exactly the user losing files. The profile is now resolved in the unelevated parent and
  passed through as `-ProfilePath`.
- **One boolean was hiding three facts.** "The deployed config matches the repo" is really
  *rendered-from-the-current-template*, *Sysmon-accepted-it*, and *the-live-rules-name-this-
  profile*, and they can disagree - a second user logging in makes the third false while the
  first stays true. `-Verify` and the smoke test now report them separately. Collapsing them
  is how the original bug survived review.
- **The hash comparison existed in two hand-written copies** (the installer's health check and
  the smoke test). Both now call the same renderer. Two copies of one comparison is how they
  drift, and one being right while the other is wrong is worse than both being wrong.

Validated by a free oracle that existed only on the day: this machine's deployed config matched
the repo byte-for-byte and its profile IS `Admin`, so rendering the template for `Admin` had to
reproduce the deployed file exactly. It did - all 27 rules identical, the only difference being
the new banner comment. `tests/Invoke-InstallerTests.ps1` (12 tests) then proves the validator
REJECTS an unrendered template, a config rendered for a nonexistent profile, malformed XML, and
an empty include list - with a positive control, because a validator that rejects everything
looks perfect until you need it to accept something.

---

## Bugs - MEDIUM

### 2. Nothing reads Sysmon's ACTIVE config - PARTLY FIXED 2026-09-10

`install-deletion-forensics.ps1:167-168`, `:314-315`, `:353-357`. `ConfigCurrent` compares the
hash of the deployed file to the repo copy - but `Copy-Item` at `:308` makes that true
unconditionally, *before* `sysmon -c` runs, and the `sysmon -c` exit code is discarded
(`$null = Invoke-Native ...`). "Sysmon config updated" prints regardless. If Sysmon rejects the
XML, `-Verify` and the smoke test both report "config matches the repo copy" while the sensor
runs the previous ruleset. The post-condition restates the pre-condition - the same shape as the
deploy bug fixed in pc-maintenance with `Test-PMPayloadItemCurrent`.

**Half of this is fixed.** The `sysmon -c` exit code is no longer discarded: a rejected ruleset
now fails the install loudly instead of printing "Sysmon config updated" while the previous
ruleset stays live. And `ConfigCurrent` no longer restates its own pre-condition - it compares
the deployed file against the template rendered for this profile, which `Copy-Item` cannot make
true in advance.

**Still open: reading back what Sysmon ACTUALLY loaded.** Two routes, neither implemented:

- `sysmon -c` with NO trailing argument dumps the running config. **Danger: `sysmon -c --`
  RESETS Sysmon to defaults**, so the argument array must be the literal `@('-c')` and never a
  splatted variable that could be empty. The dump is Sysmon's own re-serialisation - comments
  stripped, defaults materialised - so it cannot be hash-compared; the check has to be
  semantic (assert the include prefixes begin with the resolved profile).
- Better: **Sysmon writes event 16 (`SYSMONEVENT_SERVICE_CONFIGURATION_CHANGE`) carrying
  `ConfigurationFileHash`** - the hash of the ruleset it ACCEPTED, written by the thing being
  verified rather than by the installer. The post-condition becomes "the newest event 16 is
  later than the moment we applied, and its hash matches the rendered file". Needs one elevated
  observation to pin the `ALGO=HEX` format before it can be relied on, which is why it is not
  in yet. `New-ForensicsReport.ps1` already queries event 4; adding 16 would also let the
  report's coverage panel say which ruleset was live during the window.

Both require elevation, so neither can live in the unelevated smoke test - they belong in
`install-deletion-forensics.ps1 -Verify`. An unelevated SKIP is the honest answer there; a PASS
would be the very defect this backlog is about.

### 3. ~~The weekly report lands in `C:\Windows\TEMP` when nobody is logged in~~ DONE 2026-09-10

`New-ForensicsReport.ps1:156-175`. `Get-InteractiveUser` falls back to the *current process*
identity when `Win32_ComputerSystem.UserName` is null - under the SYSTEM task with nobody signed
in that is `S-1-5-18`, and `Get-DownloadsPath` then resolves a SYSTEM profile that does not
exist. The task is `-StartWhenAvailable`, so a machine that was off at Sunday 04:00 runs at boot
*before* anyone logs in: the likely case, not the edge case. pc-maintenance's
`Get-PMInteractiveUserSid` deliberately refuses this and flags `Inferred`; port that behaviour.

### 4. ~~SIX smoke-test checks named "functional" cannot fail~~ DONE 2026-09-10

`smoke-test.ps1:59-62, 84-93, 137-140, 166-172`. The pattern is
`try { $v = gh --version 2>&1; Test-Ok } catch { Test-Fail }` - a native command exiting non-zero
does not raise a PowerShell exception, so the catch is unreachable once the tool is on PATH.
Demonstrated: `cmd /c "echo boom 1>&2 & exit 3"` takes the OK branch. `markdownlint` discards its
output and calls `Test-Ok` unconditionally. `hyperfine` (`:108-110`) does it correctly - check
`$LASTEXITCODE` like that one. Related: `:88` builds two files and a `Compare-Object` for the
`delta` check and never uses the result, so **delta is never actually fed a diff**.

**Fixed 2026-09-10, and it was SIX sites, not four** - `cdb` had the same shape, and the
manifest `detect` probe was subtler than any of them: a FAILING `winget list --id X -e` still
prints "No installed package found matching input criteria", which is non-empty and therefore
truthy. (That branch only fires for `install_method = "existing"`, and npcap is the only such
tool, whose detect is a real PowerShell expression - so it was fragile rather than actively
misfiring. The audit's example, WinDbg, has method "winget" and never reaches it.)

Two things surfaced only by RUNNING the fixed checks, both of which would otherwise have
shipped:

- **`... | Select-Object -First 1` sets `$LASTEXITCODE` to -1 even when the command SUCCEEDED.**
  It raises StopUpstreamCommandsException to short-circuit, which kills the native process
  mid-write. Pairing an exit-code check with `-First 1` therefore INVENTS failures - a healthy
  `gh` immediately reported "exited -1". Collect the whole stream, then take the line.
- **markdownlint was right to exit 1.** `Set-Content` appends a newline on top of the fixture's
  explicit backtick-n, so the file ended with a blank line. The fixture was fixed rather than
  the assertion loosened.

`delta` was never actually fed a diff - it wrote two files, computed a `Compare-Object` nothing
read, and ran `delta --version`. It now receives a literal unified diff and must render the
changed line.

A lint in the gate now fails any `try` block that calls `Test-Ok` without inspecting an exit
code or comparing anything. Verified against git history: it flags exactly the six original
sites, and zero afterwards. Its first draft was broader and wrongly flagged blocks that GATHER
inside a try and decide outside it - a better pattern than the one being outlawed, and a lint
that cries wolf gets switched off within a week.

### 5. ~~Unverified binaries are kept, despite the comment saying they never are~~ DONE 2026-09-10

`build-devtoolbox.ps1:482-493`. `Expand-Archive` writes ~151 Sysinternals executables *before*
the signature check, and the catch only warns - nothing is deleted. The downstream gate at `:785`
is `Test-Path sigcheck64.exe`, now true, so the readiness smoke passes against unverified
binaries. Only one file is ever checked although the comment says "binaries".

### 6. ~~`install-llm.ps1` puts multi-GB models outside the toolbox and then asserts otherwise~~ DONE 2026-09-10

`:73-79, 166, 194, 204`. `OLLAMA_MODELS` is set for *future* processes; when Ollama is already
running the catalog install short-circuits, `Wait-Ollama` is satisfied by the **old** server, and
`ollama pull` writes to `%USERPROFILE%\.ollama\models`. `:204` then asserts the toolbox path, and
the uninstall story depends on it. This is the "Ollama desktop app blocks its service" problem
expressed in code.

### 7. ~~Group installs report success even when every install failed~~ DONE 2026-09-10

`lib/catalog.ps1:131` pipes every result to `Out-Null`, so `cli-tools_install` prints
`OK cli-tools group complete` regardless and bootstrap then prints `bootstrap complete`
(`modules/cli-tools.ps1:11`, `extras.ps1:32`, `security.ps1:66`). Same family:
`install-llm.ps1:106-113` warns on each failed reranker asset and still prints
`OK reranker provisioned`; `:108`'s `if (Test-Path $out) { continue }` accepts a truncated
partial download forever.

### 8. ~~Manifest provenance is asserted rather than measured~~ DONE 2026-09-10

`modules/security.ps1:135-137, 226-229, 323-326, 417-420` omit `-InstalledByToolbox`, which
defaults to `$true`. The live manifest records `WinDbg` and `npcap` as toolbox-installed although
npcap is documented as detect-only and `Install-WingetTool` returns early for a pre-existing
WinDbg. Consequence: `uninstall-toolbox.ps1 -RemoveWingetTools` would `winget uninstall` a WinDbg
the toolbox never installed.

### 9. ~~A corrupt baseline silently destroys the novelty history~~ DONE 2026-09-10

`New-ForensicsReport.ps1` `Read-FxBaseline` returns `$null` on **any** read or parse failure. The
report then says "No baseline yet - this run establishes one", writes `runs = 1`, and every
pairing is reported as novel next week. A lost history reads as a clean slate. Distinguish
"absent" from "unreadable" and refuse to overwrite the latter. Related: `Sort-Object
{ [datetime]$_.lastSeen }` sits outside the try/catch under `$ErrorActionPreference='Stop'`, so
one entry missing `lastSeen` kills report generation outright.

### 10. ~~The novelty baseline never forgets~~ DONE 2026-09-10

`Write-FxBaseline` prunes only by count (top 5,000 by `lastSeen`), never by age, so the "New
pairings" tile - which the renderer itself calls "the signal a WEEKLY report is actually for" -
trends monotonically to zero and stays there. Add an age horizon.
(The related trap, that investigating an incident folded it into the baseline, was fixed by
`-NoBaseline` on 2026-09-10.)

### 11. ~~The report generator's pure functions cannot be tested~~ DONE 2026-09-10

`Get-FxPairKey`, `Read-FxBaseline`, `Write-FxBaseline`, `Get-InteractiveUser` and
`Get-DownloadsPath` live in `New-ForensicsReport.ps1`, which begins reading the event log the
moment it is dot-sourced - so no test can import them. That is why the 24x rewrite of
`Get-FxPairKey` had to be validated by a throwaway differential harness that *restated* the
function instead of importing it, and why the gather block was exercised by simulation rather
than by running it. Extract them into `ForensicsReport.Core.ps1` alongside the existing
`.Render` / `.Triage` split, and give them a real suite.

---

## Bugs - LOW

- ~~**`security_desc` over-claims 4 of 6 items** (`modules/security.ps1:11`), and it is printed by
  `bootstrap.ps1 -List` and `get.ps1` - i.e. *before* consent. It advertises installing WinDbg,
  the WDK, console debuggers and Ghidra; the bodies only detect-and-wrap. `modules/cli-tools.ps1:7`
  omits `pwsh` and `curl-libressl`.~~ DONE 2026-09-10
- ~~**A stray literal backtick ships in the manifest** (`modules/security.ps1:401`): `-c '`.logopen`
  in a double-quoted string, so the recorded command is paste-broken. `lib/common.ps1:532` has the
  same text correctly.~~ DONE 2026-09-10
- ~~**The GUI ignores its own per-tool checkboxes** (`gui/toolbox-gui.ps1:206-214`): `Get-RunnerArgs`
  reads only the five global toggles, so unchecking a tool and pressing Install installs it.~~ DONE 2026-09-10
- ~~**The GUI can hang forever** (`gui/toolbox-gui.ps1:192-201`): only stdout is drained inside the
  wait loop; a child filling the ~4 KB stderr pipe never exits and `while (-not $proc.HasExited)`
  spins. bootstrap's winget/pip children do write to stderr.~~ DONE 2026-09-10
- ~~**Undisposed resources**: `Process` and `CancellationTokenSource` in `gui/toolbox-gui.ps1:66,
  191, 277`; ~150 `X509Certificate2` per call in `lib/common.ps1:229-237`; `New-TemporaryFile` in
  `smoke-test.ps1:26` creates a file only its *name* is used from and the cleanup removes a
  directory instead (76 stray zero-byte `tmp*.tmp` currently in `%TEMP%`).~~ DONE 2026-09-10
- ~~**A partial tessdata download is permanent** despite the warning saying "rerun to retry"
  (`build-devtoolbox.ps1:445-458`): `Install-Tessdata` short-circuits on `Test-Path` before the
  self-healing size check can run. Only `eng` and `osd` of 11 declared languages exist on this box,
  and `bootstrap.ps1:351` counts files without checking size.~~ DONE 2026-09-11

  The entry recorded half the mechanism. The `Test-Path` short-circuit was only the first gate:
  `Get-Download`'s **size**-failure branch threw WITHOUT deleting the partial, while its SHA-256
  branch had always cleaned up after itself. So aria2c left a corpse, the next run's `Test-Path`
  found it, and the failure became permanent — the two halves each made the other invisible.
  Both are fixed, and `bootstrap.ps1` now counts files `>= 100KB` with `eng.traineddata` required
  by name, because pointing `TESSDATA_PREFIX` at a directory of zero-byte files breaks OCR harder
  than leaving it unset.
- ~~**`consolidate-path.ps1:241-245` overwrites the wrapper unconditionally**~~ DONE 2026-09-11,
  and fixed TWICE independently: the planner keeps an existing wrapper whose target still exists,
  and the writer refuses separately, so a planner-only regression cannot reach the disk. Measured
  in production during the rebuild: 34 shims written, **118 existing wrappers left untouched**.
  The original wording follows.
- **`consolidate-path.ps1:241-245` overwrites `native\bin\<name>.cmd` unconditionally**, so a
  winget package shipping `ffmpeg.exe` silently replaces the toolbox's own shim - the comment at
  `:185-188` claims the opposite.
- **The deployed agent block is one section stale** (`lib/common.ps1:538-549`): the generator now
  emits a Sysmon/deletion-forensics paragraph the four deployed `CLAUDE.md`/`AGENTS.md` copies do
  not have, and nothing verifies deployed against generator - the gap pc-maintenance's
  `Invoke-DeploymentSmoke.ps1` exists to close for its own payload.
- ~~**`fresh-toolbox-setup-runner.ps1:62-68, 87`** reads a leaked `$LASTEXITCODE` as bootstrap's
  status (bootstrap has no trailing `exit`). It now also needs to handle
  `consolidate-path.ps1` exit **2** (elevation declined), added 2026-09-10.~~ DONE 2026-09-10
- ~~**`README.md:80`** says consolidate-path "needs elevation"; it now self-elevates.~~ DONE 2026-09-10

---

**Three of these were not what the audit said, and the corrections matter more than the fixes.**
The half-uninstall item was ALREADY closed by an earlier commit the same day - current behaviour
was verified (exit 1, zero of three mutation steps reached, with a control proving "zero
reached" is not vacuous) and nothing was changed. `catalog.json tools[].default` is NOT dead:
`gui\toolbox-gui.ps1` reads it to pre-tick checkboxes, so only `optional` was removed. And the
temp-file leak had grown from the recorded 138 to 154 by the time it was fixed, because the
smoke test had been run repeatedly that day - the clearest possible confirmation the leak was
ours.

**One fix introduced a bug that was caught in its own review.** Making provenance a measurement
means the SECOND bootstrap run finds a tool already present and would DISOWN it, so a later
`-RemoveWingetTools` would leave behind everything the toolbox installed. Provenance is now
sticky: false -> true is a measurement we accept, true -> false is one we refuse.

**A PowerShell engine bug, found while verifying the GUI stderr fix.** `Register-ObjectEvent`
assigns `EventIdentifier`s without an interlock, so two events raised at the same instant on the
stdout and stderr reader threads can share one id - measured 2 runs in 6, always the
end-of-stream marker pair. `Remove-Event` then consumes both and throws, which under the GUI's
`$ErrorActionPreference = 'Stop'` would have killed the click handler AFTER a successful
install. Worth knowing before anyone writes another event-driven pump.

**Still open in this section:** `.bak-<timestamp>` files accumulating unpruned. The partial
tessdata download and the unconditional shim overwrite were fixed on 2026-09-11; the stale
deployed agent block is now *detected* by the gate rather than invisible, which is the half that
was missing.

---

## Found while rebuilding the toolbox, 2026-09-11

Surfaced by the rebuild effort rather than by a sweep. Each names the file and the measurement.

### A degraded build still reports success

`build-devtoolbox.ps1` `Install-Tessdata` collects a `$failed` list, prints it, and discards it,
so a run that lands **0 of 11** languages still exits 0. `Install-Ghostscript` and
`Install-Sysinternals` are best-effort by explicit and defensible design (a missing Ghostscript
should not fail a whole toolbox build), but **nothing aggregates the three into one "this build is
degraded" signal**, and the manifest is written *before* `Run-Smoke` runs (`:874` vs `:877`) while
`bootstrap.ps1:436` gates readiness on that manifest existing. So the honest summary is: three
independent soft failures, no combined verdict, and a readiness flag that cannot see any of them.
Wanted: a single `degraded` array in the manifest that `smoke-test.ps1` reads and reports.

### `Get-Download` misreports a network failure as a truncated file

Its aria2c leg ignores aria2c's exit code entirely and relies on the post-hoc size check to
notice. It works, but the diagnostic is wrong: a DNS or TLS failure surfaces as "download failed
or was unexpectedly small", which sends the reader looking at disk and mirrors rather than at the
network. Capture and report the downloader's own exit code.

### The forensics report classifies a package-cache wipe as noise

`tests/Invoke-CoreTests.ps1` carries a test named `'a package cache is NOT a sentinel, or the tile
is noise'`, asserting that `C:\Users\Admin\.nuget\packages\x` does **not** match the sentinel
regex. That is correct for routine churn and wrong for a mass-deletion event, and it is not
hypothetical: the 2026-09-10 wipe took **3,384 files across 128 package versions** out of the
NuGet cache, including `onnxruntime.dll` and the .NET runtime packs, which blocked builds
entirely — and it was found by hand, days later, not by the weekly report.

The missing signal is **volume in one burst**, not path. A single file deleted from a package
cache is noise; several thousand in one sweep is the loudest thing that happened that week. Any
fix has to keep both properties, because a sentinel list that promotes package caches
unconditionally would make `plex-bif-orphans` own the hero tile forever (see the design note
below on the two weekly SYSTEM tasks).

### Machine-state damage the PATH/toolbox audit did not cover

Recorded because it was invisible to every check this repo has. `%USERPROFILE%\.dotnet\tools`
holds `.store\wix\5.0.2` (14 files, 9.9 MB) and **no top-level `wix.exe`**, so
`dotnet tool list --global` reports wix installed while `wix` does not run — the same
payload-survived-shim-died shape as the winget packages this rebuild exists to repair, and as the
NuGet cache. `wix` is absent from `%USERPROFILE%\.nuget\packages`, so an offline repair needs the
nupkg from inside `.store`. Not this repo's to fix; worth knowing that the pattern recurs across
every package manager on the box.

### Nothing lints this repo's own markdown

`.markdownlint.json` exists at the repo root, and its only consumer is `smoke-test.ps1:209-222`,
which lints a synthetic one-line fixture in `%TEMP%` and picks the config up incidentally via
markdownlint-cli's cwd search. Neither CI nor `run-gate.ps1` ever lints `README.md`, `BACKLOG.md`
or `docs/`. Measured on 2026-09-11: one live MD012 violation in `BACKLOG.md`, pre-existing and
unnoticed.

## Dead code

Confirmed by AST across both repos (265 definitions, 3,950 call sites) and re-grepped by bare
name including `.xml`/`.json`/`.psd1`/`.md`.

- ~~`catalog.json`: `schema_version` (never validated), the whole `toolbox_layers` block,
  `llm.runtime`, and `tools[].optional`.~~ **CLOSED, verified 2026-09-11.** `schema_version` is
  enforced by `Get-Catalog`, and the bump to 2 is load-bearing rather than bookkeeping: an old
  catalog against current code would silently skip the machine-PATH removal in
  `uninstall-toolbox.ps1`. `toolbox_layers` is gone bar a `$comment` explaining its removal, and
  `optional` has zero occurrences. `llm.runtime` is the only survivor of this bullet.
- ~~`manifest/tools.json` write-only keys from `Add-WinManifest`: `last_verified`, `status`,
  and `installed_version`.~~ **CLOSED.** All three removed, with comments recording why -
  `installed_version` cost an `Invoke-Expression $Detect` per tool to compute something nothing
  read.
- ~~`$activatePs1` (`lib/common.ps1:442`) - assigned, never read.~~ **WRONG ON BOTH COUNTS,
  withdrawn 2026-09-11.** There is no `$activatePs1` in `lib/common.ps1` at all; it lives in
  `scripts/build-devtoolbox.ps1`, where it is assigned and then **read** as the target of
  `Set-Content -Path $activatePs1`. Recorded rather than quietly deleted, because a dead-code list
  that has been wrong once should say so - this entry survived because nobody re-grepped a bare
  name that looked obviously dead.
- The shipped activation helpers (`build-devtoolbox.ps1:521-534`) prepend the venv `Scripts`
  directory to PATH, putting `python.exe` there - which `lib/common.ps1:202-208` and
  `smoke-test.ps1:243-248` treat as a FAIL condition. Delete them or fix them.
- `lib/common.ps1:202-208` - the doc block describing venv-CLI wrapping sits above
  `Set-NodeSystemCaBundle`; the function it documents (`New-VenvCliWrappers`, `:252`) has none.
- `build-devtoolbox.ps1:738` writes `wrapper_exists = $true` as a literal inside the loop that
  enumerates existing wrappers - it restates the loop's precondition and reads as a result.

---

## Optimization - measured, not guessed

Timed under Windows PowerShell 5.1, which is what the scheduled task runs. Numbers are per
100,000 events unless stated.

| Where | Cost | Fix | Status |
|---|---|---|---|
| `Get-FxPairKey` | 49,312 ms | String.Split + GetDirectoryName + caller-supplied `-Dir` | ~~done 2026-09-10~~ (24x) |
| Sentinel classification | 28,129 ms | one compiled alternation | ~~done 2026-09-10~~ (24.6x) |
| `Split-Path` for parent dirs, 4 sites | 8,824 ms | compute `Dir` once at gather | ~~done 2026-09-10~~ (46x) |
| Dead event-1 query | ~10 s at 40k events | render the command line instead of discarding it | ~~done 2026-09-10~~ |
| `& $add` closure per output line | 257 ms / 4,000 rows vs 10 ms | call `AppendLine` directly in the row loop only | ~~done~~ verified closed 2026-09-11 |
| `ConvertTo-FxHtml` call overhead | 694 ms / 12,000 calls vs 21 ms | inline in the row loop | open |
| `Split-Path -Leaf` per row | 318 ms / 4,000 rows vs 17 ms | `[IO.Path]::GetFileName` | ~~done~~ verified closed 2026-09-11 |
| Renderer re-classifies sentinels | 15 regexes x 4,000 | pass the `IsSentinel` flag through | ~~done~~ verified closed 2026-09-11 |
| `Find-Executable` fallback | 4,048 ms per exhaustive miss | cache misses per run; bound the depth | open |
| `build-devtoolbox.ps1:276,280` | 2 walks of one tree | one walk testing both names | open |

**Measured and REJECTED - do not "fix" these:**

- Pre-compiling the 18 forbidden path patterns to a `Regex[]` was **slower** (481 ms vs 377 ms),
  and raising `[regex]::CacheSize` changed nothing. The cache is not thrashing.
- Combining the three `Get-WinEvent` passes into one `Id=@(1,4,26)` query saved only 18%
  (1,073 ms -> 882 ms). Not worth the branching.
- `Sort-Object -Top` at `Render.ps1:258`: **`-Top` does not exist in Windows PowerShell 5.1**. It
  would be green locally under pwsh and broken at 04:00 on a Sunday. The full sort of 100k
  objects is only 1,019 ms anyway.

---

## Design decisions worth revisiting, not bugs

- **~~Two~~ ONE weekly SYSTEM task now.** `\PcMaintenance` was **removed on 2026-09-11** at the
  user's instruction, before its first-ever `-Apply` run (Sunday 2026-09-13 03:00), on the machine
  it had just been implicated in wiping. Verified gone by two independent signals: `schtasks`
  reports absent where it previously reported access-denied, and no registration file remains
  under `System32\Tasks`. `DeletionForensicsReport` is still registered, and the payload plus 19
  run logs were retained. The task XML was exported first, so it is reversible.

  The note below is kept because the hazard returns the moment anyone re-registers that task.
  pc-maintenance ran Sunday 03:00 with `-Apply`; the forensics report runs 04:00 over the last 7
  days. Neither knew about the other. `plex-bif-orphans` deletes ~6,935 files per sweep at 100% recurrence,
  which is a textbook burst by the report's own definition and would permanently own the hero
  tile. The only reason it does not is incidental: the Plex media directory is a junction to
  another volume, so the deletions fall outside the config's include prefix. Remove that junction
  and the forensics headline becomes pc-maintenance, every week, forever. Make it an explicit
  exclusion or an explicit comment, not an accident.
- ~~**`bootstrap.ps1:302-307`** says PATH registration is user scope "(never machine)", while
  `consolidate-path.ps1` and `smoke-test.ps1:211-212` treat machine scope as the correct end
  state. Pick one.~~ **RATIFIED 2026-09-11: machine scope**, for the reason the contradiction
  existed in the first place — some agent shells inherit the machine PATH only, so a user-scope
  toolbox is invisible to exactly the audience this repo serves. The live registry had already
  settled it: `native\bin` and `sysinternals` are in HKLM and absent from HKCU.

  The documented model is now: `bootstrap.ps1` **stages** both entries in the user hive because
  it runs unelevated by contract, and `scripts/consolidate-path.ps1` — which elevates, backs both
  hives up and can `-Restore` them — owns the machine write. `smoke-test.ps1:261-263` already
  encoded that ladder correctly (machine `OK`, user-only `WARN`, absent `FAIL`); only the prose
  was wrong.

  Two things surfaced while closing it that were not in the original entry:

  - **The contradiction had a functional half, not just a prose half.**
    `uninstall-toolbox.ps1:167` calls `Remove-UserPathEntry`, which is user-scope only
    (`lib/common.ps1:72-87` — there was no machine-scope helper in `lib/` at all), for entries
    that live in HKLM. So the toolbox could not reverse its own PATH side effect. The two dead
    `DevToolbox\native\bin` and `DevToolbox\sysinternals` entries sitting in the machine PATH
    after the 2026-09-10 deletion **are** that gap, observed rather than theorised.
  - **`docs/agent-rules.md`'s prohibition was narrowed, not dropped.** "Never add entries to the
    system PATH" becomes "never add a *tool-specific* entry by hand; this repo owns exactly two,
    declared in `catalog.json` and written by one script". A blanket licence to edit the system
    PATH is not what the ratification buys.
- **`Write-AgentBlock`** (`lib/common.ps1:430-431`) writes a new `.bak-<timestamp>` every run with
  no pruning; 9+ copies of `AGENTS.md` already sit in the profile root.

---

---

## Found during the consolidation round, 2026-09-11

Each names the file and the measurement. Line numbers are deliberately omitted where a symbol
name will do: every reference in this file predating this week is now stale for
`build-devtoolbox.ps1`, `lib/common.ps1`, `consolidate-path.ps1` and `smoke-test.ps1`, which
between them moved by hundreds of lines. Re-anchor by symbol, not by line.

### A dry run can still write the real user PATH

`Add-UserPathEntry` has no `-DryRun` branch. `bootstrap.ps1`'s `Register-ToolboxUserPath` guards
its own call site, but `lib/catalog.ps1` does not: under `-DryRun`, `Install-WingetTool` returns
`$true` **without installing**, so a `winget-machine` or `winget-default` tool with a
`path_fallback` whose binary is absent reaches `Add-UserPathEntry` and writes the persistent user
hive during a run that promised to change nothing. Left open deliberately during the registry
migration, which was confined to the mechanism; closing it is a behaviour change belonging either
to the catalog call sites or to a guard in the function.

### `Find-Executable`'s miss cache is not the easy win it looks like

BACKLOG measures the exhaustive miss at 4,048 ms and the obvious fix is a per-run cache. It is
wrong. The dominant caller shape is probe, install, probe again (`Get-Python311` for uv,
`Install-Ghostscript` for gswin64c), so a miss cache makes the install **unobservable** and
returns `$null` from a box that now has the tool. Correctness needs invalidation threaded through
every installer. Recorded in a comment at the function so nobody re-derives it as a quick fix.

Measured while fixing the adjacent two-walk problem, and worth keeping because both alternatives
lose: an unfiltered single walk is **86.1 ms**, slower than the 76.6 ms two-pass it would replace;
`-Include` is **silently ignored under `-LiteralPath`** and returned every file in the package
including `README.html`, so its apparent 19.4 ms was an inert filter. The shipped `-Filter` plus
exact-name test is 37.9 ms, verified identical across 31 names x 27 packages.

### Hot paths in `lib/ShimPlan.ps1`, unmeasured

The sibling rule recomputes `Get-ShimNormalKey` on every innermost iteration of a four-deep loop
and never caches the normalised form of `$bound`, which only grows by one per outer pass. The
hygiene `shadowed` predicate grows an array with `+=` inside a loop and then does a linear
`-notcontains` per name against a list that includes everything `system32` provides. Both are
genuinely quadratic shapes. **Neither has been measured**, and at 47 names over 27 packages the
absolute cost may be irrelevant - which is exactly why they are recorded here rather than
"optimised" on sight. Measure before touching, in this file's own tradition.

### The repo's markdown is still unlinted

`.markdownlint.json` exists and its only consumer is a synthetic one-line fixture in `%TEMP%`.
Neither CI nor `run-gate.ps1` lints `README.md`, `BACKLOG.md` or `docs/`. One live MD012 violation
was found and fixed by hand on 2026-09-11; nothing would have caught the next one.

### Interesting, not actionable

Every failure in this round's rebuild was a **native command's stderr under a global
`$ErrorActionPreference = 'Stop'`**. Three different commands, three different disguises - uv's
*success* message, Node's CA-bundle warning, and aria2's real error. `lib/common.ps1` had the
lesson written down and applied at some call sites and not others. The generalisation now lives in
`Invoke-NativeCapture`, and an AST test asserts no native command in the builder is piped.

**Correction, measured 2026-09-11.** This entry used to say "the trigger is the PIPE, not the
redirection". That is backwards. Probed under 5.1 with `Stop`, across three host-stream conditions
(console inherited, parent-captured with `2>&1 | Out-String`, `Start-Process` with both standard
streams redirected to files), the result was identical in all three:

| shape | result |
|---|---|
| `$x = & cmd /c "echo e 1>&2 & exit /b 0" 2>&1` | **THREW** `NativeCommandError` |
| `$x = & cmd /c "echo e 1>&2 & exit /b 0" 2>$null` | **THREW** - `2>$null` does not discard it |
| `& cmd /c "echo e 1>&2 & exit /b 0" \| Out-Null` | survived |
| `& cmd /c "echo e 1>&2 & exit /b 0" > $null` | survived |

The **redirection** promotes stderr to ErrorRecords; a pipe on its own does not. The pipe still
has to be barred, for a second measured reason that explains the original confusion: an
**enclosing** `2>&1` - which is what every log-capturing parent applies - makes PowerShell
redirect the inner command's stderr too, and then even an unpiped, unredirected native call raises
the record. So `| Out-Null` is a latent form of the same defect rather than a different one, and
the uv failure was almost certainly observed under exactly such a parent.

### Native stderr sites left OPEN in library and module files

The 2026-09-11 sweep fixed the thirteen sites in scripts that set `Stop` *themselves*, and the AST
gate covers that set. Six more are the same defect reached by **dynamic scoping** and are
deliberately not fixed here, because they belong to the bootstrap install path this round was told
not to run:

- `lib/common.ps1` - `Install-WingetTool` (`winget list ... 2>&1`, `winget @args 2>&1`) and
  `Install-NpmGlobal` (`npm install -g ... 2>&1`, `& npm config get prefix | Select-Object`).
- `modules/security.ps1` - `& fsutil usn queryjournal C: 2>&1 | ...` and
  `winget list --id Microsoft.WinDbg -e ... 2>&1`.

Neither file assigns `$ErrorActionPreference` itself, which is why the gate does not see them - but
`bootstrap.ps1` dot-sources `lib/common.ps1` at `:27` under `Stop`, so every one of those calls runs
under it. `Install-WingetTool`'s is the same shape as the uv failure, in the most-travelled install
path in the repo. The fix is mechanical (give each file the same `Invoke-Native`); the risk is that
it cannot be validated without a real bootstrap run.

`scripts/smoke-test.ps1` has seven more of the shape and is **not** exposed: it never sets `Stop`,
and `run-gate.ps1` runs it as a child process, which starts at the default `Continue`. Widening the
gate to files that do not set `Stop` would flag those seven for no reason, which is why the rule is
scoped the way it is rather than being scoped to "every file".

## Features

- Add the opt-in llama.cpp engine as a lean, no-service alternative to Ollama for
  the local-LLM stack (`scripts/install-llm.ps1 -IncludeLlamaCpp`): detect a CUDA
  GPU and fetch the matching prebuilt `ggml-org/llama.cpp` release into `native\`
  (SHA-verified), wrap `llama-server`/`llama-cli`, and expose the same
  OpenAI-compatible endpoint contract as the Ollama path.

- `install-machine-scope.ps1`: consider moving per-package scope overrides (the
  `$NoScopeFlag` list) into `catalog.json` as a `no_scope_flag` boolean field,
  so the script and the catalog stay in sync automatically.

## Deferred

- Find a supported install channel for watchexec on Windows. It is not currently available in winget.
- Add native Windows ARM64 support; the current builder and optional JDK/Ghidra path target x64 Windows.
- Evaluate a tested Python constraints/lock strategy without preventing routine security updates.
