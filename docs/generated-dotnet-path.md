# Isolated .NET tool PATH leakage

The 2026-10-22 toolbox gate found an expanded persistent PATH of 8,343
characters. A separate unrestricted registry read identified 56 User PATH
entries under generated desktop-ai-companion artifact roots: 38 long paths,
14 paths using the desktop short spelling, and 4 using the `gq` short spelling.
These entries consumed 6,159 characters including separators. The measured
remaining User PATH was 1,375 raw characters. These are historical measurements,
not an instruction to trust the current registry without a fresh read.

`DOTNET_CLI_HOME` isolation can give each fixture its own `.dotnet/tools` path.
The originating test environments must also set
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` in the process environment and restore the
caller's prior value afterward. `DOTNET_SKIP_FIRST_TIME_EXPERIENCE` alone did
not prevent this workstation's observed accumulation.

The repair is deliberately separate from general PATH consolidation. It never
opens a candidate directory or removes files. It does not deduplicate,
normalize, expand or reorder retained PATH entries. Ordinary user global tools,
unrelated artifact paths, native/bin, Sysinternals and cross-scope duplicates
remain byte-for-byte raw tokens. Machine PATH is read and checked only.

Run a review with Windows PowerShell 5.1 or PowerShell 7.5+:

```powershell
./scripts/repair-generated-dotnet-path.ps1
```

The default operation writes a local `logs/generated-dotnet-path/UUID/plan.json`
and reports zero registry writes. It binds the current interactive SID, registered
profile, actual profile short spelling and session; both raw REG_EXPAND_SZ values
and UTF16LE hashes; every removed index/value; the exact proposed User value;
and the current planner source closure. It permits only the three measured
artifact-root forms and the exact `\.dotnet\tools` suffix. Only a plan containing
exactly 56 candidates is eligible for application. Other counts remain review-only.

The plan reader preserves timestamp strings exactly. The first live PS7 apply
refused before any backup or registry write because automatic JSON DateTime
conversion lost the precise UTC spelling. A complete serialized-plan control now
exercises the actual reader on both supported shells; older PS7 versions refuse
explicitly because they lack the `ConvertFrom-Json -DateKind String` option.

Some agent sandboxes expose a projected HKCU or an inherited machine-only PATH.
Use the client's supported approval workflow to run the read-only plan in the
real interactive user's context. The adapter addresses that explicit SID under
HKEY_USERS and checks its registered profile. A plan from an unrelated user,
SYSTEM, a different session or a changed registry snapshot cannot be applied.

After independent review of the concrete plan and a separately approved live
action, use the exact reported path/hash and SID:

```powershell
./scripts/repair-generated-dotnet-path.ps1 -Apply -Plan PATH -PlanSha256 HASH -ExpectedUserSid SID
```

Apply exclusively flushes and verifies `before-apply.json` in the same ignored
directory before any registry write. It rechecks the plan, producers, owner and
both raw registry values, then rereads the User value under its writable key
handle. The only setter writes the exact derived User value as REG_EXPAND_SZ.
It verifies both User readback and unchanged Machine state afterward. Existing
backup or result artifacts cause a refusal rather than an overwrite. An external
registry change causes a refusal; there is no automatic rollback over new edits.
No environment broadcast or machine write is performed. New terminals obtain
the current persistent values; the root gate refreshes its own process PATH.

Pure fixture controls run without reading or writing live registry state:

```powershell
powershell.exe -NoProfile -File ./tests/Invoke-GeneratedDotNetPathTests.ps1
pwsh -NoProfile -File ./tests/Invoke-GeneratedDotNetPathTests.ps1
```

The live repair completed after independent review, both23-control shell runs,
fresh plan73826994 and supported action approval. Exclusive backupa6820bbc
precedes removal of the56 generated entries. All22 kept raw tokens, registry
type and Machine PATH remain exact; User PATH is1375 raw characters. The full
`q98-path-repaired` gate passes7 hygiene checks,97 smoke checks and10 suites with
388 tests in both execution modes, followed by direct phase reruns. Review plans,
backup and readback are retained under ignored `logs/generated-dotnet-path/`.
