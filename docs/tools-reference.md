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
