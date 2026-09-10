# Windows Dev Toolbox - Tools Reference

Agent-facing usage guide. Read this when you need to know how to invoke a tool,
when to prefer one tool over another, or how the specialized tools (frida, optional Ghidra,
tshark) work in practice.

---

## Developer CLI tools

### gh - GitHub CLI

```powershell
gh auth login                          # authenticate (browser or token)
gh repo clone owner/repo               # clone a repo
gh pr list                             # list open PRs
gh pr create --title "..." --body "..."
gh issue list --label bug
gh run list                            # CI run history
gh release create v1.0.0 --generate-notes
```

Reach for `gh` any time you would otherwise construct a GitHub REST/GraphQL call.

In a repo that has an `upstream` remote, `gh` resolves to **upstream, not your fork**, so `gh run list`
and `gh release list` silently report the parent project's runs and releases. Pass `-R owner/repo`
explicitly whenever a fork is involved.

### pwsh - PowerShell 7

```powershell
pwsh -NoProfile -File .\build.ps1                # run a script under PS7
pwsh -NoProfile -Command '$PSVersionTable'       # confirm which engine you are in
powershell -NoProfile -File .\build.ps1          # the SAME script under Windows PowerShell 5.1
```

Installed **side by side** with Windows PowerShell 5.1 at `%ProgramFiles%\PowerShell\7`; `powershell.exe`
is untouched and stays the default. The reason to have both is that CI almost always runs
`shell: pwsh`, so a repo's build and test scripts execute under PS7 there and under 5.1 in a local
terminal. Anything that differs between the two fails in exactly one place and is painful to diagnose:

- `&&` / `||`, `??`, `?.` and ternary `? :` are **PS7 only** and are parse errors under 5.1.
- `Get-WmiObject`, `Invoke-WmiMethod`, `New-WebServiceProxy` and `-Encoding Byte` were **removed in PS7**
  and work fine under 5.1, which is the dangerous direction: green locally, broken in CI.
- `Set-Content` defaults to **ANSI** under 5.1 and **UTF-8 no BOM** under PS7, and `Out-File` differs too,
  so the same script writes different bytes on each. Always pass `-Encoding` explicitly.

Run a build or gate under `pwsh` before trusting that CI will agree with your terminal.

### fzf - fuzzy finder

```powershell
# Interactive: pipe a list, user selects
git branch | fzf

# Non-interactive (scripts): --filter returns matching lines
echo "alpha`nbeta`ngamma" | fzf --filter "bet"   # returns "beta"

# Preview pane while browsing
Get-ChildItem -Recurse *.ps1 | fzf --preview 'bat --plain {}'
```

### bat - syntax-highlighted pager

```powershell
bat file.py                     # paged, highlighted
bat --plain --no-pager file.py  # stdout only, no decorations (for scripts)
bat -l json file.txt            # force a specific language
```

Prefer `bat` over `type` or `cat` when showing file content to the user.

### delta - diff pager

Configured as git's pager; you rarely invoke it directly. To set it up:

```powershell
git config --global core.pager delta
git config --global interactive.diffFilter "delta --color-only"
```

```powershell
delta file_a.txt file_b.txt     # diff two arbitrary files
```

### just - task runner

```powershell
just                            # run the default recipe
just build                      # run a named recipe
just --list                     # list available recipes
just --justfile path/justfile recipe
```

If a project has a `justfile`, always use `just` rather than reading the file
and running commands manually.

### hyperfine - benchmarking

```powershell
hyperfine "rg pattern ."                    # single command
hyperfine "rg pattern ." "findstr /r /s pattern *"  # compare two
hyperfine --warmup 3 --runs 10 "cmd"        # control iterations
hyperfine --export-json results.json "cmd"
```

### sops - encrypted secrets

```powershell
# Encrypt (requires a recipient key - age or PGP)
sops --encrypt --age <age-pubkey> secrets.yaml > secrets.enc.yaml

# Decrypt
$env:SOPS_AGE_KEY_FILE = "$env:USERPROFILE\.config\sops\age\keys.txt"
sops --decrypt secrets.enc.yaml

# Edit in place
sops secrets.enc.yaml
```

Always pair sops with age (below). Never commit unencrypted secrets.

### age - file encryption

```powershell
age-keygen -o key.txt                        # generate a key pair
age-keygen -y key.txt                        # print just the public key

# Encrypt
age -r <pubkey> -o output.age plaintext.txt
Get-Content plaintext.txt | age -r <pubkey> -o output.age

# Decrypt
age -d -i key.txt output.age
```

### tokei - code statistics

```powershell
tokei                           # count LOC in current directory
tokei src/                      # specific path
tokei --sort lines              # sort by line count
tokei --output json             # machine-readable output
```

### yt-dlp - video/audio downloader

The maintained youtube-dl fork; downloads from YouTube and 1000+ other sites.
It finds the toolbox `ffmpeg`/`ffprobe` on PATH automatically, so merging and
transcoding work with no extra setup.

```powershell
yt-dlp <url>                                  # best pre-merged format
yt-dlp -f bestvideo+bestaudio <url>           # merge best streams (needs ffmpeg - already on PATH)
yt-dlp -F <url>                               # list all available formats
yt-dlp -x --audio-format mp3 <url>            # extract audio only (ffmpeg transcodes)
yt-dlp -o "%(title)s.%(ext)s" <url>           # output-name template
yt-dlp --download-archive done.txt <url>      # skip items already downloaded
yt-dlp -a urls.txt                            # batch: one URL per line
```

winget owns this copy, so update it with `winget upgrade yt-dlp.yt-dlp` rather
than `yt-dlp -U` to stay channel-clean.

**YouTube JS challenges (nsig / PO tokens).** YouTube obfuscates its stream URLs
with a JavaScript "n-signature" challenge; yt-dlp must execute that JS or
extraction is throttled/blocked ("Some formats may be missing"). The solver
scripts (`yt-dlp-ejs`) are already bundled in this standalone binary, but they
need a JavaScript runtime. yt-dlp enables **Deno** by default and auto-detects it
on PATH (Deno is its own catalog tool), so this works out of the box here.
Verify the wiring:

```powershell
yt-dlp -v --simulate -F "https://www.youtube.com/watch?v=jNQXAC9IVRw" 2>&1 |
    Select-String 'JS runtimes|JS Challenge Providers'
# -> JS runtimes: deno-<ver>;  JS Challenge Providers: ... deno ...
```

The bundled solver only refreshes when yt-dlp itself updates; to pull the latest
solver scripts between releases, add `--remote-components ejs:github`. Node (also
in the toolbox) works too but is not the default - opt in with `--js-runtimes
node`.

### deno - JavaScript/TypeScript runtime

Secure-by-default JS/TS runtime. Its headline job in this toolbox is powering
yt-dlp's YouTube challenge solver (above), but it is a general runtime:

```powershell
deno run script.ts                 # run a TS/JS file, no build step
deno run --allow-net server.ts     # sandboxed by default; grant perms explicitly
deno repl                          # interactive REPL
deno fmt  /  deno lint             # format / lint
```

## Security / RE tools

### tshark - CLI packet analysis

```powershell
# List available interfaces
tshark -D

# Capture on an interface
tshark -i "Wi-Fi" -f "port 443" -w capture.pcap

# Read a pcap and filter
tshark -r capture.pcap -Y "http.request" -T fields -e http.host -e http.request.uri

# Follow a TCP stream
tshark -r capture.pcap -q -z "follow,tcp,ascii,0"

# Statistics
tshark -r capture.pcap -q -z conv,tcp
```
Live capture (`tshark -i`) requires the Npcap driver. The **silent winget Wireshark install
does NOT include Npcap**, so `tshark -i` reports "Unable to load Npcap (wpcap.dll)" until Npcap
is installed separately. Reading pcap/pcapng files works without Npcap.

### Npcap - live-capture driver (optional, documented dependency)

Npcap has **no winget package** (its license blocks redistribution) and this toolbox does not
direct-download installers, so - like Ghidra - it is a documented optional dependency, not an
auto-install. `modules/security.ps1` detects and records it if present. Enable `tshark -i` only
if you specifically need live capture, via either: re-run the Wireshark installer interactively
and tick the bundled Npcap component, or install Npcap elevated from npcap.com. Otherwise prefer
the driver-free path below.

### Driver-free packet capture (channel-compliant, no Npcap)

Capture with the BUILT-IN Windows packet monitor, convert with etl2pcapng, read in tshark:

```powershell
pktmon filter add web -i 172.64.155.209 -p 443    # filter to an IP + port (needs elevation)
pktmon start --capture --pkt-size 0 --file-name cap.etl
# ... reproduce the traffic ...
pktmon stop
etl2pcapng cap.etl -o cap.pcapng                  # or: pktmon pcapng cap.etl -o cap.pcapng
tshark -r cap.pcapng -Y "tcp.flags.reset==1"      # analyze (no Npcap needed to READ)
```

### Ghidra - reverse engineering suite

Ghidra is optional and has no current Winget package. Provision the portable,
toolbox-local copy with its verified helper, then let the security module create
stable wrappers and a Ghidra-only `JAVA_HOME`:

```powershell
.\scripts\install-ghidra.ps1
.\bootstrap.ps1 -Only security
```

```powershell
# Launch the GUI
ghidraRun

# Headless analysis (scripted RE, no GUI)
analyzeHeadless `
    C:\ghidra-projects MyProject `
    -import target.exe `
    -postScript PrintFunctionNames.java `
    -deleteProject
```

For scripted analysis, Ghidra's headless mode accepts Java or Python (Jython)
scripts placed in `ghidra_scripts/` or passed with `-scriptPath`.

### Deletion forensics — Sysmon + a sized USN journal

Answers "**which process deleted this?**". Optional, and installed by an explicit helper rather
than by `bootstrap.ps1`, because it loads a `BOOT_START` kernel driver and resizes an NTFS
structure — not something a general toolbox run should do to you unasked.

```powershell
.\scripts\install-deletion-forensics.ps1            # install or update (self-elevates)
.\scripts\install-deletion-forensics.ps1 -Verify    # health only, changes nothing
.\scripts\install-deletion-forensics.ps1 -DryRun    # show the plan
.\scripts\install-deletion-forensics.ps1 -Uninstall # remove Sysmon; the journal is LEFT sized
.\scripts\install-deletion-forensics.ps1 -Uninstall -ShrinkJournal   # also destroy the journal
```

**`-Uninstall` deliberately leaves the USN journal at its current size.** NTFS grows a journal in
place but will not shrink one — `fsutil usn createjournal` with a smaller `m` is a silent no-op —
so the only way down is `deletejournal /d`, which discards every record it holds. An oversized
journal costs disk and nothing else, whereas destroying the record of recent filesystem activity
as a side effect of removing a *monitoring* tool is a surprise nobody wants. `-ShrinkJournal`
opts into precisely that: delete, recreate at 32 MB, lose the history. It is meaningful only
alongside `-Uninstall`.

An earlier version of the script ran `createjournal` and then printed "USN journal returned to
32 MB" unconditionally. Measured during a lifecycle test, the journal was still 2,048 MB while
the line said 32 — asserting instead of measuring, the same defect this whole capability exists
to catch. The uninstall path now re-reads the size and reports what it actually found.

**Why it exists.** On 2026-09-09 this workstation lost ~16 profile dotdirs,
`%LOCALAPPDATA%\DevToolbox`, `.dotnet\tools` and ~70 GB of Ollama models inside a 97-minute
window. The cause was never established and *could not be*: Sysmon was absent, File System
auditing was off, and the USN journal was 32 MB — under two hours of history on this volume.
Every suspect had to be excluded by inference rather than evidence.

**Two sensors, answering different halves of the question.**

| | Sysmon event 26 | USN journal |
|---|---|---|
| WHO (process) | **yes** | no |
| WHAT / WHEN | yes | **yes** |
| Needs an agent | yes | no |
| Survives Sysmon being stopped | no | **yes** |

**Event 26 `FileDeleteDetected`, never event 23 `FileDelete`.** Event 23 archives a *copy of
every deleted file* to disk before logging it, which on a machine that deletes build output all
day consumes the disk it is meant to protect. Event 26 records the same who/what/when and copies
nothing.

**The log is admin-only to read.** An unelevated `Get-WinEvent` returns *"Attempted to perform an
unauthorized operation"*, which is easy to misread as an empty log — it did mislead once during
the original investigation. Query elevated:

```powershell
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Sysmon/Operational'; Id=26} |
  ForEach-Object { $x = [xml]$_.ToXml()
    '{0}  {1}  <- {2}' -f $_.TimeCreated,
      ($x.Event.EventData.Data | Where-Object Name -eq 'TargetFilename').'#text',
      ($x.Event.EventData.Data | Where-Object Name -eq 'Image').'#text' }
```

Sysmon fires **per file, not per directory**, so a recursive tree delete appears as a *burst of
event 26 sharing one `Image` and `ProcessGuid`*. That burst is the signature; pair it with event 1
for the command line.

**Scope is deliberate.** `config\sysmon-filedelete.xml` includes three prefixes — the profile
dotdirs, `AppData\Local` and `Documents`. The reasoning: a mass deletion is defined by *breadth*,
so quiet valuable paths make better sentinels than noisy caches where deletions are normal.

**Those prefixes are hardcoded to one profile.** The literal path `C:\Users\Admin` appears 25
times in the file - 24 of them `<TargetFilename>` rules, in the include and exclude groups alike,
and one in a comment explaining the choice. There is no wildcard and nothing substitutes the
current user at deploy time, so on any other machine, or under any other account on this one, the
config installs without complaint and then matches nothing. Edit it before installing it
elsewhere. Both `-Verify` and `smoke-test.ps1` compare the deployed copy to the repo copy by hash,
so an edit made only on the machine shows up as a mismatch rather than passing quietly.

**Retention target is 48 hours** of deletion history — two days is the useful window for "what
happened to my files". Every exclusion was measured before being added, over four rounds:

| round | what was cut | measured effect |
|---|---|---|
| 1 | ProcessTerminate off; ProcessCreate narrowed to shells and installers | 997 → 233 events/min |
| 2 | `.dotnet\TelemetryStorageService` (160 of a 1,500 sample) | → 67 events/min |
| 3 | Vendor cache churn — Backblaze 1,566, Razer 720, Steam 380 | 51% of the log |
| 4 | Agent shell tooling (`C:\Anthropic\.Git\` bash, and the cmd it spawns) | 94% of remaining ProcessCreate |

Round 4 needed correcting almost immediately, and the correction is the useful part. Excluding
that whole tree by prefix also discarded **`rm.exe`** - and a live test showed `rm.exe` is what
actually performs a deletion from an agent shell, because bash forks it as a separate process.
Sysmon resolves *exclude over include*, so the broad rule would have silently cancelled the
single most valuable record in the file.

The coreutils that delete (`rm`, `rmdir`, `mv`, `find`, `xargs`, `shred`, `unlink`, `git`) are
now explicitly **included** in `ProcessCreate`, and the exclusion names only the shells.
Measured cost of adding them: **zero occurrences in 40,000 sampled events**. Verified end to
end - an `rm -rf` from the agent shell now records both the files and the command that removed
them:

```
image   : C:\Anthropic\.Git\usr\bin\rm.exe
cmdline : rm.exe -rf /c/Users/Admin/.rmproof
parent  : C:\Anthropic\.Git\usr\bin\bash.exe
```

That matters beyond tidiness. On a machine that runs coding agents all day, a shell `rm -rf`
with an over-broad glob or an unset variable is a leading explanation for the kind of loss this
was built after - and it is the one explanation the tooling could previously observe happening
without being able to say what was asked for.

Final measured rate: **4,620 events/hour at 3,756 bytes each → ~124 hours at 2 GB**, comfortably
past the target.

Round 3 is excluded by **path, not by process**, and the measurement is what justifies that: all
three vendors had *zero* deletions outside their own directories. `RazerAppEngine.exe` clearing its
service-worker cache is noise; `RazerAppEngine.exe` deleting `.ssh` is the exact event this exists
to catch, and a path rule keeps that visible where an image rule would not.

**If retention ever runs short, tighten the exclusions before enlarging the log** — a bigger log
holds more noise, not more signal. Two hand estimates were wrong by an order of magnitude before
any of this was measured, which is why the dashboard reports retention from the log itself.

#### The weekly dashboard

```powershell
.\scripts\New-ForensicsReport.ps1              # now, last 7 days
.\scripts\New-ForensicsReport.ps1 -Days 30     # wider window
.\scripts\New-ForensicsReport.ps1 -NoTriage    # measured facts only, no model
```

A SYSTEM scheduled task (`DeletionForensicsReport`, Sunday 04:00 - an hour after pc-maintenance's
sweep, so they do not collide) writes a self-contained HTML dashboard to the interactive user's
real Downloads. Registered by the installer; `-NoSchedule` opts out. Only the three most recent
are kept, ordered by the timestamp in the *name* rather than mtime, so a touched file cannot
promote itself past a newer one.

Every parameter it takes:

| parameter | default | effect |
|---|---|---|
| `-Days` | `7` | how much Sysmon history to read |
| `-OutDir` | the interactive user's Downloads | resolved from that user's own shell-folder registration, not `<profile>\Downloads`, which is commonly redirected |
| `-MaxRows` | `4000` | rows embedded in the log reader. A file-size cap, not a limit on the analysis: every count above the table is computed over all events in the window |
| `-KeepReports` | `2` | how many reports survive the prune, counting the one just written - so the default keeps this week's and last week's, which is what makes a week-over-week comparison possible. Matches pc-maintenance's `reportsToKeep`. |
| `-NoPrune` | off | keep every report; skips the prune entirely |
| `-BurstThreshold` | `50` | files one process must delete inside the window below before it is called a burst |
| `-BurstWindowSeconds` | `300` | that window |
| `-NoTriage` | off | omit the model-assisted panel |
| `-TriageModel` | `mistral-small3.2:24b` | which local model to ask |
| `-TriageUri` | `http://127.0.0.1:11434` | where to look for it |

**Triage asks a local model by default, and nothing leaves the machine.** If an Ollama answers at
`-TriageUri` the report gains one fenced panel of hypotheses about what a cluster of events might
mean. It is on by default because a feature nobody opts into is a feature nobody gets. The
default URI is loopback, the liveness probe is `/api/tags` on that same host, and the report
makes no other network call of any kind - a test asserts the HTML fetches nothing from anywhere.
`-NoTriage` disables it; so does an absent server, a slow one or a nonsensical answer. All four
produce the identical report minus that one panel.

The model is shown aggregates - top processes, bursts, new pairings, sentinel hits - never the
raw log, and every finding it returns has to cite a process and a directory that were in that
input. Anything citing something it was never shown is discarded before the page is written, and
the run prints how many were kept and how many rejected. It cannot gate, filter, reorder or
change a single measured number.

It answers two different needs.

**Insights.** Five openable stat tiles (deletions, processes, bursts, new pairings, sentinel
paths), a burst panel and a coverage panel. The headline is the largest **burst** - one process deleting many
files in a short window - because that, not raw volume, is the shape of a mass deletion. A
machine steadily deleting build output all week is not interesting; 1,566 files in 159 seconds is.

**A log reader.** Up to 4,000 recent deletions in a filterable table: free-text on path or
process, a process picker, and a sentinel-only toggle. Every *count* above it is computed over
all events in the window, not just the embedded rows, and the report says so rather than letting
you assume otherwise.

**Sentinel paths are chosen by measured quietness, not by importance.** The tile is only worth
reading if any hit is unusual, so `AppData\Local\Programs` (992 hits in the first week - VS Code
rewriting itself), `.claude` (78) and `.codex` (52) were removed after measurement. They are
still fully tracked in the counts, the reader and burst detection; they just cannot be sentinels.
A healthy week reads **0**.

**New pairings need a baseline, and the baseline is a file on disk.** A pairing is one program
deleting in one place, with the directory generalised to four segments below the profile -
a raw path like `.cargo\registry\src\<hash>\<crate>-1.2.3` is a different string every release
and would report everything as novel forever. Each run compares what it saw against
`%ProgramData%\Sysmon\forensics-baseline.json`, reports the pairings that were not already in it,
and only *then* merges its own in. That order is the whole trick: written first, this run's
pairings would be in the baseline it is checked against and nothing could ever be new. The file
is bounded at 5,000 entries, least-recently-seen dropped first, against the ~100 distinct
pairings this machine actually produces.

Without that file the tile reads **n/a** and says why: a first run establishes the baseline and
can honestly call nothing novel, which is better than flagging all 4,000 events. It lives beside
the Sysmon config in `%ProgramData%\Sysmon` rather than in the toolbox, for the same reason the
config does - the toolbox was destroyed in the incident this tooling exists to investigate.
Deleting it is not damaging but it is not free either: the next run starts a fresh baseline, and
the tile only becomes meaningful again once a few runs have accumulated.

**Coverage is measured, not estimated.** The panel reports the log's actual span and projects
retention from observed size and rate. An earlier hand estimate was out by an order of magnitude
because it assumed 1.5 KB/event when the real figure is nearer 3.5 KB.

Self-contained, like the pc-maintenance report: no CDN, no webfont, no library. It does carry
inline vanilla JavaScript for the reader's filtering - the constraint that matters is that
*nothing is fetched from anywhere*, and every insight renders without script.

Reading the log by hand instead:

```powershell
# ELEVATED. Unelevated this returns "unauthorized", which looks exactly like an empty log.
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Sysmon/Operational'; Id=26} |
  ForEach-Object { $x = [xml]$_.ToXml()
    '{0}  {1}  <- {2}' -f $_.TimeCreated,
      ($x.Event.EventData.Data | Where-Object Name -eq 'TargetFilename').'#text',
      ($x.Event.EventData.Data | Where-Object Name -eq 'Image').'#text' }
```

Both sensors are checked by `scripts\smoke-test.ps1`, which fails on *degradation* (installed but
not capturing, or a start type that will not survive a reboot) and only warns on absence. A sensor
nobody verifies is one that stops working quietly.

### cdb / kd / ntsd — Windows console debuggers

`cdb`, `kd`, and `ntsd` are the **scriptable** Windows debuggers from the "Debugging Tools for
Windows" (Windows SDK component). Unlike WinDbgX (the store app), they run headlessly and write
output to files — the right choice for automated crash-dump analysis.

They live at `%ProgramFiles(x86)%\Windows Kits\10\Debuggers\x64\` and are wrapped into
`native\bin` by `bootstrap.ps1 -Only security`. `_NT_SYMBOL_PATH` is already configured by the
toolbox, so OS symbols resolve automatically.

```powershell
# Quick interactive triage of a dump
cdb -z C:\crash\minidump.dmp

# Scripted analysis — write commands to a text file, run headlessly, capture output
# script.txt example: .logopen C:\out\analysis.txt; !analyze -v; q
cdb -z minidump.dmp -c "`.logopen C:\out\analysis.txt; `$`$><script.txt; q"

# Pool-tag source lookup (which driver allocated this tag?)
cdb -z minidump.dmp -c "!poolfind FMfn 0; q"   # 0=nonpaged, 1=paged

# Kernel dump (full or kernel memory dump)
kd -z C:\crash\kernel.dmp -c "!analyze -v; q"

# Version / sanity check
cdb -version
```

`cdb` vs `WinDbgX`:
| | cdb/kd | WinDbgX |
|---|---|---|
| Output capture | `-c ".logopen out.txt; q"` | `.logopen` inside GUI |
| Scriptable | Yes — pipe commands, exit 0/1 | Awkward (no spaces in `-c`) |
| GUI | No | Yes |
| Ship channel | Windows SDK (via WDK install) | winget store app |

### poolmon — pool-tag monitor

`poolmon` shows live kernel pool allocations sorted by tag, letting you identify which driver or
subsystem is the top consumer of nonpaged/paged pool — **without waiting for a crash**. Installed
as part of the WDK; wrapped into `native\bin` by bootstrap.

poolmon is interactive (curses-style); run it elevated (it reads kernel pool counters).

```powershell
# Interactive monitor — nonpaged pool, sorted by bytes
# Keys: p=paged/nonpaged toggle, b=bytes, a=allocs, t=tag, n=name, q=quit
poolmon

# Snapshot to a file (WDK 10.x +)
poolmon /b /r /n C:\diag\pool-snapshot.txt   # sort bytes, nonpaged, write file

# Then find the driver behind a tag (from an elevated shell or kernel debugger)
# In cdb/kd: !poolfind <tag> 0
# Or use the pooltag.txt database shipped with the WDK:
#   %ProgramFiles(x86)%\Windows Kits\10\Debuggers\x64\triage\pooltag.txt
```

Common flags: `/b` sort by bytes, `/a` sort by allocs, `/r` nonpaged-pool only,
`/p` paged-pool only, `/n <file>` write snapshot to file, `/s <N>` auto-refresh every N seconds.

### frida - dynamic instrumentation

frida is in the **dev toolbox venv**, which `bootstrap.ps1` puts on your user
PATH - so `frida` is available by name in any new shell. (You can also call it
via the venv Python directly.)

```powershell
# Activate toolbox, then:
frida --version
frida-ps -U                              # list processes on a USB device
frida-ps -D <device-id>                  # specific device
frida -U -n "TargetApp" -l hook.js       # attach to process by name
frida -U -f com.target.app -l hook.js --no-pause  # spawn and attach

# Python API (inside a script using the toolbox venv)
import frida
session = frida.attach("process_name")
script = session.create_script("""...""")
script.load()
```

For Windows targets without a USB device, replace `-U` with the process name/PID:

```powershell
frida -n notepad.exe -l hook.js
```

---

## Toolbox venv extras

These run via the dev toolbox Python - activate the toolbox first or prefix
with the venv Python path.

### sqlite-utils

```powershell
sqlite-utils insert data.db mytable data.csv --csv
sqlite-utils query data.db "SELECT * FROM mytable LIMIT 5" --csv
sqlite-utils transform data.db mytable --rename col_old col_new
sqlite-utils convert data.db mytable col "lambda v: v.strip()"
```

### csvkit

```powershell
csvlook data.csv                         # pretty-print
csvcut -c name,age data.csv              # select columns
csvstat data.csv                         # summary statistics
csvjoin -c id left.csv right.csv         # join on column
in2csv data.xlsx > data.csv              # convert Excel to CSV
sql2csv --db sqlite:///db.sqlite "SELECT * FROM t"
```

### jupyterlab

```powershell
jupyter-lab                              # launch server (opens browser)
jupyter-lab --no-browser --port 8889     # headless, specific port
jupyter nbconvert --to script notebook.ipynb   # convert to .py
```

---

## Local LLM stack (optional - Ollama)

Only present if provisioned with `scripts\install-llm.ps1`. Everything runs
locally; use it for offline / sensitive RAG and inference (no cloud).

```powershell
# Discover the endpoint (OpenAI-compatible), set when the stack was installed
$env:TOOLBOX_LLM_URL                     # http://127.0.0.1:11434/v1

ollama list                              # installed models
ollama run qwen2.5:3b "summarize this"   # quick chat
ollama run moondream "describe this image ./photo.jpg"   # vision

# From code, point any OpenAI client at $env:TOOLBOX_LLM_URL (api_key can be any
# non-empty string). Chat model: qwen2.5:3b or mistral:7b; embeddings:
# qwen3-embedding:0.6b via POST /v1/embeddings.
```

```powershell
# Rerank retrieved passages with the ONNX cross-encoder (RAG quality)
& $env:TOOLBOX_PYTHON "$env:CODEX_TOOLBOX\scripts\rerank.py" "the query" "passage A" "passage B"
# -> JSON [{index, score, text}] sorted best-first
```

Models are VRAM-tiered (8 GB gets the light set; 24 GB also gets `mistral-small`)
and stored under `%CODEX_TOOLBOX%\models`. Prefer `mistral:7b`/`mistral-small`
for Mistral-native workflows, `qwen2.5:3b` as the light everyday model.

## When to use what

| Task | Reach for |
|---|---|
| GitHub operations | `gh` |
| Browse/select from a list interactively | `fzf` |
| View a file with context | `bat` |
| Run project tasks | `just` (if justfile exists) |
| Encrypt a secret | `age` + optionally `sops` |
| Compare command performance | `hyperfine` |
| Count lines of code | `tokei` |
| Download video/audio from the web | `yt-dlp` (pairs with toolbox ffmpeg) |
| Run a JS/TS script (sandboxed) | `deno` (also yt-dlp's JS challenge runtime) |
| Analyze a network capture | `tshark` |
| Identify top pool consumers (live, no crash) | `poolmon` (WDK, elevated) |
| Scripted / headless crash-dump analysis | `cdb -z dump.dmp -c "..."` |
| Interactive crash-dump analysis | `windbg -z dump.dmp` (WinDbgX GUI) |
| Kernel crash-dump analysis | `kd -z kernel.dmp -c "!analyze -v; q"` |
| Reverse-engineer a binary | Portable Ghidra (`scripts/install-ghidra.ps1`) |
| Hook into a running process | `frida` (toolbox venv) |
| Query/transform CSV | `csvkit` |
| Lightweight SQL on files | `sqlite-utils` or `duckdb` |
| Offline/sensitive inference or RAG | local Ollama (`install-llm.ps1`) |
