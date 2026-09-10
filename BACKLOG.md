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

### 3. The weekly report lands in `C:\Windows\TEMP` when nobody is logged in

`New-ForensicsReport.ps1:156-175`. `Get-InteractiveUser` falls back to the *current process*
identity when `Win32_ComputerSystem.UserName` is null - under the SYSTEM task with nobody signed
in that is `S-1-5-18`, and `Get-DownloadsPath` then resolves a SYSTEM profile that does not
exist. The task is `-StartWhenAvailable`, so a machine that was off at Sunday 04:00 runs at boot
*before* anyone logs in: the likely case, not the edge case. pc-maintenance's
`Get-PMInteractiveUserSid` deliberately refuses this and flags `Inferred`; port that behaviour.

### 4. Four smoke-test checks named "functional" cannot fail

`smoke-test.ps1:59-62, 84-93, 137-140, 166-172`. The pattern is
`try { $v = gh --version 2>&1; Test-Ok } catch { Test-Fail }` - a native command exiting non-zero
does not raise a PowerShell exception, so the catch is unreachable once the tool is on PATH.
Demonstrated: `cmd /c "echo boom 1>&2 & exit 3"` takes the OK branch. `markdownlint` discards its
output and calls `Test-Ok` unconditionally. `hyperfine` (`:108-110`) does it correctly - check
`$LASTEXITCODE` like that one. Related: `:88` builds two files and a `Compare-Object` for the
`delta` check and never uses the result, so **delta is never actually fed a diff**.

### 5. Unverified binaries are kept, despite the comment saying they never are

`build-devtoolbox.ps1:482-493`. `Expand-Archive` writes ~151 Sysinternals executables *before*
the signature check, and the catch only warns - nothing is deleted. The downstream gate at `:785`
is `Test-Path sigcheck64.exe`, now true, so the readiness smoke passes against unverified
binaries. Only one file is ever checked although the comment says "binaries".

### 6. `install-llm.ps1` puts multi-GB models outside the toolbox and then asserts otherwise

`:73-79, 166, 194, 204`. `OLLAMA_MODELS` is set for *future* processes; when Ollama is already
running the catalog install short-circuits, `Wait-Ollama` is satisfied by the **old** server, and
`ollama pull` writes to `%USERPROFILE%\.ollama\models`. `:204` then asserts the toolbox path, and
the uninstall story depends on it. This is the "Ollama desktop app blocks its service" problem
expressed in code.

### 7. Group installs report success even when every install failed

`lib/catalog.ps1:131` pipes every result to `Out-Null`, so `cli-tools_install` prints
`OK cli-tools group complete` regardless and bootstrap then prints `bootstrap complete`
(`modules/cli-tools.ps1:11`, `extras.ps1:32`, `security.ps1:66`). Same family:
`install-llm.ps1:106-113` warns on each failed reranker asset and still prints
`OK reranker provisioned`; `:108`'s `if (Test-Path $out) { continue }` accepts a truncated
partial download forever.

### 8. Manifest provenance is asserted rather than measured

`modules/security.ps1:135-137, 226-229, 323-326, 417-420` omit `-InstalledByToolbox`, which
defaults to `$true`. The live manifest records `WinDbg` and `npcap` as toolbox-installed although
npcap is documented as detect-only and `Install-WingetTool` returns early for a pre-existing
WinDbg. Consequence: `uninstall-toolbox.ps1 -RemoveWingetTools` would `winget uninstall` a WinDbg
the toolbox never installed.

### 9. A corrupt baseline silently destroys the novelty history

`New-ForensicsReport.ps1` `Read-FxBaseline` returns `$null` on **any** read or parse failure. The
report then says "No baseline yet - this run establishes one", writes `runs = 1`, and every
pairing is reported as novel next week. A lost history reads as a clean slate. Distinguish
"absent" from "unreadable" and refuse to overwrite the latter. Related: `Sort-Object
{ [datetime]$_.lastSeen }` sits outside the try/catch under `$ErrorActionPreference='Stop'`, so
one entry missing `lastSeen` kills report generation outright.

### 10. The novelty baseline never forgets

`Write-FxBaseline` prunes only by count (top 5,000 by `lastSeen`), never by age, so the "New
pairings" tile - which the renderer itself calls "the signal a WEEKLY report is actually for" -
trends monotonically to zero and stays there. Add an age horizon.
(The related trap, that investigating an incident folded it into the baseline, was fixed by
`-NoBaseline` on 2026-09-10.)

### 11. The report generator's pure functions cannot be tested

`Get-FxPairKey`, `Read-FxBaseline`, `Write-FxBaseline`, `Get-InteractiveUser` and
`Get-DownloadsPath` live in `New-ForensicsReport.ps1`, which begins reading the event log the
moment it is dot-sourced - so no test can import them. That is why the 24x rewrite of
`Get-FxPairKey` had to be validated by a throwaway differential harness that *restated* the
function instead of importing it, and why the gather block was exercised by simulation rather
than by running it. Extract them into `ForensicsReport.Core.ps1` alongside the existing
`.Render` / `.Triage` split, and give them a real suite.

---

## Bugs - LOW

- **`security_desc` over-claims 4 of 6 items** (`modules/security.ps1:11`), and it is printed by
  `bootstrap.ps1 -List` and `get.ps1` - i.e. *before* consent. It advertises installing WinDbg,
  the WDK, console debuggers and Ghidra; the bodies only detect-and-wrap. `modules/cli-tools.ps1:7`
  omits `pwsh` and `curl-libressl`.
- **A stray literal backtick ships in the manifest** (`modules/security.ps1:401`): `-c '`.logopen`
  in a double-quoted string, so the recorded command is paste-broken. `lib/common.ps1:532` has the
  same text correctly.
- **The GUI ignores its own per-tool checkboxes** (`gui/toolbox-gui.ps1:206-214`): `Get-RunnerArgs`
  reads only the five global toggles, so unchecking a tool and pressing Install installs it.
- **The GUI can hang forever** (`gui/toolbox-gui.ps1:192-201`): only stdout is drained inside the
  wait loop; a child filling the ~4 KB stderr pipe never exits and `while (-not $proc.HasExited)`
  spins. bootstrap's winget/pip children do write to stderr.
- **Undisposed resources**: `Process` and `CancellationTokenSource` in `gui/toolbox-gui.ps1:66,
  191, 277`; ~150 `X509Certificate2` per call in `lib/common.ps1:229-237`; `New-TemporaryFile` in
  `smoke-test.ps1:26` creates a file only its *name* is used from and the cleanup removes a
  directory instead (76 stray zero-byte `tmp*.tmp` currently in `%TEMP%`).
- **A partial tessdata download is permanent** despite the warning saying "rerun to retry"
  (`build-devtoolbox.ps1:445-458`): `Install-Tessdata` short-circuits on `Test-Path` before the
  self-healing size check can run. Only `eng` and `osd` of 11 declared languages exist on this box,
  and `bootstrap.ps1:351` counts files without checking size.
- **`consolidate-path.ps1:241-245` overwrites `native\bin\<name>.cmd` unconditionally**, so a
  winget package shipping `ffmpeg.exe` silently replaces the toolbox's own shim - the comment at
  `:185-188` claims the opposite.
- **The deployed agent block is one section stale** (`lib/common.ps1:538-549`): the generator now
  emits a Sysmon/deletion-forensics paragraph the four deployed `CLAUDE.md`/`AGENTS.md` copies do
  not have, and nothing verifies deployed against generator - the gap pc-maintenance's
  `Invoke-DeploymentSmoke.ps1` exists to close for its own payload.
- **`fresh-toolbox-setup-runner.ps1:62-68, 87`** reads a leaked `$LASTEXITCODE` as bootstrap's
  status (bootstrap has no trailing `exit`). It now also needs to handle
  `consolidate-path.ps1` exit **2** (elevation declined), added 2026-09-10.
- **`README.md:80`** says consolidate-path "needs elevation"; it now self-elevates.

---

## Dead code

Confirmed by AST across both repos (265 definitions, 3,950 call sites) and re-grepped by bare
name including `.xml`/`.json`/`.psd1`/`.md`.

- `catalog.json`: `schema_version` (never validated - contrast `PMManifest.ps1:25-26`, which
  enforces its own), the whole `toolbox_layers` block `:165-171`, `llm.runtime`, and
  `tools[].optional` (set on all 24 entries, 0 readers). `llm.embedding_fallbacks` advertises a
  fallback that exists nowhere **and** names models absent from `models_base`.
- `manifest/tools.json` write-only keys from `Add-WinManifest` (`lib/common.ps1:389-393`):
  `last_verified`, `status` (hardcoded `"core"`), and `installed_version` - the last costs an
  `Invoke-Expression $Detect` **per tool** to compute something nothing reads.
- `$activatePs1` (`lib/common.ps1:442`) - assigned, never read.
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
| `& $add` closure per output line | 257 ms / 4,000 rows vs 10 ms | call `AppendLine` directly in the row loop only | open (25x) |
| `ConvertTo-FxHtml` call overhead | 694 ms / 12,000 calls vs 21 ms | inline in the row loop | open |
| `Split-Path -Leaf` per row | 318 ms / 4,000 rows vs 17 ms | `[IO.Path]::GetFileName` | open |
| Renderer re-classifies sentinels | 15 regexes x 4,000 | pass the `IsSentinel` flag through | open |
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

- **Two weekly SYSTEM tasks, an hour apart, and the second measures the first.** pc-maintenance
  runs Sunday 03:00 with `-Apply`; the forensics report runs 04:00 over the last 7 days. Neither
  knows about the other. `plex-bif-orphans` deletes ~6,935 files per sweep at 100% recurrence,
  which is a textbook burst by the report's own definition and would permanently own the hero
  tile. The only reason it does not is incidental: the Plex media directory is a junction to
  another volume, so the deletions fall outside the config's include prefix. Remove that junction
  and the forensics headline becomes pc-maintenance, every week, forever. Make it an explicit
  exclusion or an explicit comment, not an accident.
- **`bootstrap.ps1:302-307`** says PATH registration is user scope "(never machine)", while
  `consolidate-path.ps1` and `smoke-test.ps1:211-212` treat machine scope as the correct end
  state. Pick one.
- **`Write-AgentBlock`** (`lib/common.ps1:430-431`) writes a new `.bak-<timestamp>` every run with
  no pruning; 9+ copies of `AGENTS.md` already sit in the profile root.

---

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
