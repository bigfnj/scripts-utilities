# Junctions an elevated process will not follow

On 2026-10-30 the toolbox venv stopped working for an agent host on a Windows 11
25H2 workstation while it kept working in the owner's own terminals. The venv
launcher printed `No Python at '"...\cpython-3.11-windows-x86_64-none\python.exe'`
and exited 103, although the file was there. `pyvenv.cfg`'s `home` named uv's
minor-version junction, and Windows refused to let the agent's process open
anything through it: WinError 448, `ERROR_UNTRUSTED_MOUNT_POINT`, "The path
cannot be traversed because it contains an untrusted mount point".

## What was measured

- The agent host ran ELEVATED: High integrity, Administrators enabled. Every
  shell it starts inherits that token, and so does a process it starts through
  WMI, which is therefore not an outside test.
- An elevated process refuses a junction that was created with a non-admin
  token. A normal unelevated process, tested through a scheduled task with
  `/RL LIMITED`, follows every one of them. SYSTEM is known to refuse them as
  well: the same workstation recorded that for a cross-volume junction in
  September. It was not re-measured here.
- A junction recreated by an elevated process is followed by both.
- Ownership does not confer trust. `icacls <junction> /setowner Administrators /L`
  succeeded and changed nothing; trust is decided when the junction is created.
- `runas /trustlevel:0x20000` does not de-elevate. Its process stays at High
  integrity with a restricted token, and a junction it makes is untrusted even to
  itself. That makes it a reliable way to produce an untrusted junction on
  purpose, which the positive control below uses.
- Under both Windows PowerShell 5.1 and PowerShell 7.6 an untrusted junction
  fails an enumeration with `IOException` and HResult `0x800701C0`, and a trusted
  junction to a missing target fails with `DirectoryNotFoundException`.
- An untrusted junction whose target is ALSO missing reports 448, not "not
  found": the trust check fires first.

The policy that makes elevated processes enforce this was not identified.
`Get-ProcessMitigation` does not expose it on this build.

## Who makes these junctions

uv's minor-version links under `%APPDATA%\uv\python`, npm workspace links
(`node_modules\@scope\pkg` pointing back at a workspace folder), and hand-made
folder moves. Any of them made from an unelevated shell is one more, so this is
upkeep rather than a one-time repair.

The first sweep of that workstation (C: without `%SystemRoot%`, D:, E:; about
867,000 directories) found 361 untrusted junctions:

| Where | Count | What was done |
|---|---|---|
| npm workspace links with a live target | 72 | recreated |
| npm workspace links whose worktree had no target any more | 105 | left: dangling |
| leftovers in the user's TEMP | 182 | left: nothing uses them |
| another account's sandbox profile | 1 | left: not this account's to change |
| a Codex plugin cache `latest` link | 1 | recreated |

## Running it

```powershell
# from an ELEVATED shell; refuses an unelevated one with exit 2
./scripts/repair-untrusted-junctions.ps1
```

The default is a dry run. It sweeps every ready fixed drive without following
any link, writes `logs/junction-trust/<id>/plan.json` and prints what it would
recreate. `-Root` narrows the sweep and `-Exclude` adds folders to skip. To act
on a reviewed plan:

```powershell
./scripts/repair-untrusted-junctions.ps1 -Apply -Plan ./logs/junction-trust/<id>/plan.json
```

Apply re-checks every planned entry immediately before touching it: still a
junction, still pointing at the planned target, target still a directory, and
still untrusted to this process. Only then is the link removed with a
non-recursive delete and made again; a failed re-create is retried once and then
reported as `LOST` with the exact `mklink` line to restore it. Each outcome is
written to `applied.json` beside the plan, and a plan that has an `applied.json`
is refused.

| Exit | Meaning |
|---|---|
| 0 | done, positive control fired |
| 1 | a junction was LOST or could not be verified, or the plan was refused |
| 2 | not elevated: nothing was examined |
| 3 | done, but the positive control did not fire, so a clean result proves nothing |

## Why it must run elevated, and the positive control

From an unelevated shell an untrusted junction is perfectly healthy, so a sweep
there would report a clean machine it never examined. For the same reason every
run first makes a junction with a non-admin token (`runas /trustlevel`) and
requires the classifier to call it untrusted. If that does not happen the run
says so and exits 3.

## What it never touches

- `%SystemRoot%`, the user's TEMP, other accounts' profiles, and each drive's
  `$Recycle.Bin` and `System Volume Information`.
- Anything that is not a directory junction: symlinks, cloud placeholders and
  every other reparse point are neither entered nor changed.
- A link's target. Neither the library nor the script contains a recursive
  delete, and the suite asserts that every `Directory.Delete` in the library is
  non-recursive.

Dangling junctions are reported, not removed. Whether to prune the folder that
holds one is a separate decision with a different blast radius.

## The smoke check

`scripts/smoke-test.ps1` now opens the toolbox venv's `home` from the shell
running the gate. Behind an untrusted junction it FAILS and names this script.
From an unelevated shell, when `home` crosses a junction, the OK line says that
an elevated host may still be refused, because nothing an unelevated shell can
do will tell it.

## Tests

```powershell
powershell.exe -NoProfile -File ./tests/Invoke-JunctionTrustTests.ps1
pwsh -NoProfile -File ./tests/Invoke-JunctionTrustTests.ps1
```

The suite needs neither elevation nor a second token. It classifies through
injected probes, walks a fake tree, and recreates real junctions under TEMP
whose "untrusted" verdict comes from a probe, so it can run in CI.
