#Requires -Version 5.1
<#
Provision the optional local-LLM stack (opt-in; not part of the default groups).

Runtime: Ollama (winget), which runs a per-user background service at
127.0.0.1:11434 exposing an OpenAI-compatible API. Models SHOULD live inside the
toolbox (OLLAMA_MODELS -> <toolbox>\models) so the uninstaller clears them with
the rest of the toolbox - but OLLAMA_MODELS only reaches processes started after
it is set, and `ollama pull` is a client: the already-running SERVER decides where
blobs go. So this script MEASURES the store after pulling and says plainly when
the models went somewhere else instead of asserting they did not.
Model pulls are VRAM-tiered: an 8 GB box pulls the light
default set; a >=24 GB box additionally pulls the flagship, so a small machine
does not waste disk on a model it cannot run. Everything is defined in
catalog.json -> llm.

llama.cpp is the opt-in lean alternative engine and is tracked in BACKLOG.md; it
is not installed here yet.

  .\scripts\install-llm.ps1                 # Ollama + tiered default models + reranker
  .\scripts\install-llm.ps1 -DryRun         # show what would happen, change nothing
  .\scripts\install-llm.ps1 -SkipReranker   # skip the ONNX reranker provisioning
  .\scripts\install-llm.ps1 -Models qwen2.5:3b,moondream   # explicit model set
#>
[CmdletBinding()]
param(
    [string]  $Root = $(if ($env:CODEX_TOOLBOX) { $env:CODEX_TOOLBOX } else { "$env:LOCALAPPDATA\DevToolbox" }),
    [string[]]$Models,
    [switch]  $SkipReranker,
    [switch]  $IncludeLlamaCpp,
    [switch]  $DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path $PSScriptRoot
. (Join-Path $REPO_ROOT "lib\common.ps1")
. (Join-Path $REPO_ROOT "lib\catalog.ps1")
if ($DryRun) { $script:DryRun = $true }

$llm = (Get-Catalog).llm
if (-not $llm) { throw "catalog.json has no 'llm' section" }
$modelsDir = Join-Path $Root "models"

function Set-UserEnvVar {
    param([string]$Name, [string]$Value)
    if ($DryRun) {
        Write-Info "[DRY-RUN] would set User $Name=$Value"
    } else {
        [System.Environment]::SetEnvironmentVariable($Name, $Value, "User")
        Set-Item -Path "Env:$Name" -Value $Value
        Write-Ok "$Name -> $Value"
    }
}

function Get-GpuVramMb {
    # Largest single-GPU total VRAM in MB, or 0 if no NVIDIA GPU / nvidia-smi.
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return 0 }
    try {
        $out = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits
        $vals = @($out | ForEach-Object { [int]($_ -replace '[^\d]', '') } | Where-Object { $_ -gt 0 })
        if ($vals.Count) { return ($vals | Measure-Object -Maximum).Maximum }
    } catch { }
    return 0
}

function Test-OllamaUp {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/version" -UseBasicParsing -TimeoutSec 3
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Wait-Ollama {
    param([int]$TimeoutSec = 60)
    if (Test-OllamaUp) { return $true }
    $app = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe"
    if (Test-Path $app) {
        Start-Process -FilePath $app | Out-Null
    } else {
        $cmd = Get-Command ollama -ErrorAction SilentlyContinue
        if ($cmd) { Start-Process -FilePath $cmd.Source -ArgumentList 'serve' -WindowStyle Hidden | Out-Null }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-OllamaUp) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-VerifiedFile {
    # Download $Url to $OutFile and PROVE the result is complete before it is allowed
    # to keep that name. Returns $true only when a whole file is on disk.
    #
    # Same job as Get-Download in scripts\build-devtoolbox.ps1, which already gets
    # this right: re-measure an existing file and delete it if it does not match.
    # This function replaced a bare `if (Test-Path $out) { continue }` around
    # Invoke-WebRequest -OutFile. Invoke-WebRequest streams straight into the output
    # file, so a connection dropped mid-transfer leaves a TRUNCATED model.onnx on
    # disk - and that Test-Path then accepted the stump on every later run, forever.
    # The reranker would fail at ort.InferenceSession load time, long after anyone
    # was watching the install that "succeeded".
    param([string]$Url, [string]$OutFile)

    # The server's own length is the only size check that needs no magic number.
    # $null when it will not say (proxy, no HEAD, or a compressed transfer whose
    # Content-Length describes the WIRE bytes and not the bytes we save - trusting
    # that would reject every good download forever). Then "non-empty" is the
    # strongest claim available, which still beats "the path exists".
    $expected = $null
    try {
        $head = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 30
        if ($head.Headers -and $head.Headers.ContainsKey('Content-Length') -and
            -not $head.Headers.ContainsKey('Content-Encoding')) {
            $len = [int64]($head.Headers['Content-Length'] | Select-Object -First 1)
            if ($len -gt 0) { $expected = $len }
        }
    } catch { }
    $expectedText = if ($null -eq $expected) { "unknown" } else { "{0:N0}" -f $expected }

    if (Test-Path -LiteralPath $OutFile) {
        $have = (Get-Item -LiteralPath $OutFile).Length
        if ($have -gt 0 -and (($null -eq $expected) -or ($have -eq $expected))) {
            Write-Skip ("{0} already complete ({1:N0} bytes)" -f (Split-Path $OutFile -Leaf), $have)
            return $true
        }
        Write-Warn ("re-downloading truncated {0}: {1:N0} bytes on disk, {2} expected" -f
                    (Split-Path $OutFile -Leaf), $have, $expectedText)
        Remove-Item -LiteralPath $OutFile -Force
    }

    # Download under a .part name so a failure can never be mistaken for the real
    # file by the Test-Path above on the next run.
    $part = "$OutFile.part"
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    try {
        Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing
    } catch {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Write-Warn "download failed ($Url): $($_.Exception.Message)"
        return $false
    }
    $got = if (Test-Path -LiteralPath $part) { (Get-Item -LiteralPath $part).Length } else { 0 }
    if ($got -eq 0 -or (($null -ne $expected) -and ($got -ne $expected))) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Write-Warn ("download incomplete ({0}): got {1:N0} bytes, expected {2}" -f $Url, $got, $expectedText)
        return $false
    }
    Move-Item -LiteralPath $part -Destination $OutFile -Force
    return $true
}

function Test-ModelStorePopulated {
    # Does this directory actually hold model data? Ollama writes blobs\sha256-* and
    # manifests\; an empty (or merely created) directory means the pull went elsewhere.
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return $false }
    return (@(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue |
              Select-Object -First 1).Count -gt 0)
}

function Get-DirSizeGb {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
    $bytes = (Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { return 0 }
    return [math]::Round($bytes / 1GB, 2)
}

function Install-Reranker {
    # Provision a cross-encoder reranker as ONNX + tokenizer, run via the toolbox
    # onnxruntime (already present). Best-effort: warns and continues on failure.
    $rr = $llm.reranker
    if (-not $rr) { return }
    $py = Get-ToolboxPython
    if (-not $py) { Write-Warn "toolbox Python not found - skipping reranker (build the toolbox first)"; return }
    $dir = Join-Path $Root $rr.dir_relative
    if ($DryRun) {
        Write-Info "[DRY-RUN] would pip install tokenizers/onnxruntime into the venv"
        Write-Info "[DRY-RUN] would download $($rr.name) ONNX + tokenizer -> $dir"
        Write-Info "[DRY-RUN] would write $Root\scripts\rerank.py"
        return
    }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Info "pip install tokenizers onnxruntime (toolbox venv)"
    & $py -m pip install --quiet tokenizers onnxruntime
    if ($LASTEXITCODE -ne 0) { Write-Warn "reranker python deps failed to install - skipping"; return }
    # Count the failures. Every asset used to be its own try/catch-warn and then
    # "OK reranker provisioned" printed regardless - so all three could fail and the
    # run still ended by telling you the reranker was ready.
    $missing = @()
    foreach ($f in $rr.files) {
        $out = Join-Path $dir (Split-Path $f -Leaf)
        $url = "https://huggingface.co/$($rr.hf_repo)/resolve/main/$f"
        Write-Info "reranker file: $f"
        if (-not (Get-VerifiedFile -Url $url -OutFile $out)) { $missing += (Split-Path $f -Leaf) }
    }
    # A small, self-contained scorer. Usage:
    #   $py <toolbox>\scripts\rerank.py "query" "doc A" "doc B" ...
    # prints JSON [{index, score, text}] sorted best-first.
    $helper = @'
import json, sys, os
import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("CODEX_TOOLBOX", os.path.dirname(HERE))
MODEL_DIR = os.path.join(ROOT, "models", "reranker", "bge-reranker-base")

def main(argv):
    if len(argv) < 3:
        print("usage: rerank.py <query> <doc> [<doc> ...]", file=sys.stderr); return 2
    query, docs = argv[1], argv[2:]
    tok = Tokenizer.from_file(os.path.join(MODEL_DIR, "tokenizer.json"))
    sess = ort.InferenceSession(os.path.join(MODEL_DIR, "model.onnx"),
                                providers=ort.get_available_providers())
    want = {i.name for i in sess.get_inputs()}
    scores = []
    for doc in docs:
        enc = tok.encode(query, doc)
        feed = {
            "input_ids": np.array([enc.ids], dtype=np.int64),
            "attention_mask": np.array([enc.attention_mask], dtype=np.int64),
        }
        if "token_type_ids" in want:
            feed["token_type_ids"] = np.array([enc.type_ids], dtype=np.int64)
        logits = sess.run(None, feed)[0]
        scores.append(float(np.ravel(logits)[0]))
    ranked = sorted(
        ({"index": i, "score": s, "text": d} for i, (s, d) in enumerate(zip(scores, docs))),
        key=lambda r: r["score"], reverse=True)
    print(json.dumps(ranked, indent=2)); return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
'@
    $helper | Set-Content -Path (Join-Path $Root "scripts\rerank.py") -Encoding UTF8
    if ($missing.Count) {
        # rerank.py is still written - a rerun only needs the assets - but do not
        # claim a reranker that cannot load.
        Write-Err ("reranker NOT provisioned: {0} of {1} asset(s) missing ({2}). rerank.py will fail at load; rerun to retry." -f
                   $missing.Count, @($rr.files).Count, ($missing -join ', '))
        return
    }
    Write-Ok "reranker provisioned: $dir (helper: $Root\scripts\rerank.py)"
}

# -- Main ----------------------------------------------------------------------
Write-Group "local LLM stack (Ollama)"
Write-Info "toolbox root: $Root"
Write-Info "models dir:   $modelsDir"

if (-not $DryRun) { New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null }
# Set OLLAMA_MODELS BEFORE installing/starting Ollama so it uses this store from
# the first pull (no models land in the default ~/.ollama location).
Set-UserEnvVar -Name "OLLAMA_MODELS" -Value $modelsDir

Write-Group "install Ollama"
Install-CatalogItem -Item (Get-CatalogItem -Name "ollama") | Out-Null
Set-UserEnvVar -Name "TOOLBOX_LLM_URL" -Value $llm.endpoint

if ($IncludeLlamaCpp) {
    Write-Warn "llama.cpp engine is not implemented yet (tracked in BACKLOG.md); installing Ollama only"
}

# VRAM-tiered model selection
$vram = Get-GpuVramMb
$models = if ($Models) { $Models } else {
    $set = @($llm.models_base)
    if ($vram -ge [int]$llm.tier_24gb_min_vram_mb) { $set += @($llm.models_24gb) }
    $set
}
Write-Info ("detected VRAM: {0} MB -> tier: {1}" -f $vram, $(if ($vram -ge [int]$llm.tier_24gb_min_vram_mb) { "24GB (base + flagship)" } else { "base" }))

Write-Group "pull models"
if (-not $DryRun) {
    # An Ollama that is ALREADY listening is not restarted by Wait-Ollama (it returns
    # true on the first probe), and a server's model store is fixed by the environment
    # it captured when IT started. `ollama pull` is only a client, so the OLLAMA_MODELS
    # set above - which applies to FUTURE processes - has no say in where these blobs
    # land. Say so before multiple GB are committed to a directory the uninstaller
    # does not clean.
    if (Test-OllamaUp) {
        Write-Warn "an Ollama server is already running: it captured its environment at start-up, so IT decides the model store - not the OLLAMA_MODELS set above"
        Write-Info "to force the toolbox store: quit Ollama (tray icon / Stop-Process ollama), open a NEW shell, re-run this script"
    }
    if (-not (Wait-Ollama)) {
        Write-Warn "Ollama service did not become reachable at 127.0.0.1:11434 - open a new shell (or start the Ollama app) and re-run to pull models"
    }
}
$pulled = 0
foreach ($m in $models) {
    if ($DryRun) { Write-Info "[DRY-RUN] would: ollama pull $m"; continue }
    Write-Info "ollama pull $m"
    & ollama pull $m
    if ($LASTEXITCODE -ne 0) { Write-Warn "pull failed: $m (skipping)" } else { $pulled++ }
}

# MEASURE where the blobs went; do not assert it. The "done" banner used to print
# "(models in <toolbox>)" unconditionally, and the uninstall story depends on that
# being true: uninstall-toolbox.ps1 clears the toolbox root, so models parked in
# %USERPROFILE%\.ollama\models survive it silently - tens of GB that nobody
# attributes to this script.
$modelsInToolbox = $true
$actualStore     = $modelsDir
if (-not $DryRun -and $pulled -gt 0) {
    $modelsInToolbox = Test-ModelStorePopulated $modelsDir
    if (-not $modelsInToolbox) {
        $default = Join-Path $env:USERPROFILE ".ollama\models"
        $actualStore = if (Test-ModelStorePopulated $default) { $default } else { "unknown" }
        Write-Err "models did NOT land in the toolbox: $modelsDir is empty after $pulled successful pull(s)"
        if ($actualStore -eq "unknown") {
            Write-Warn "could not locate the real store either - ask the running server: 'ollama show <model>' / check OLLAMA_MODELS in the server's own environment"
        } else {
            Write-Warn ("they are in {0} ({1} GB) - the running server's store, NOT the toolbox" -f $actualStore, (Get-DirSizeGb $actualStore))
            Write-Warn "uninstall-toolbox.ps1 will NOT remove them; delete that directory by hand, or restart Ollama in a new shell (OLLAMA_MODELS is now set) and re-pull"
        }
    }
}

if (-not $SkipReranker) {
    Write-Group "reranker (ONNX via toolbox Python)"
    Install-Reranker
}

Write-Group "done"
if ($DryRun) {
    Write-Ok "local LLM stack ready - endpoint: $($llm.endpoint)  (models would go to $modelsDir)"
} elseif ($modelsInToolbox) {
    Write-Ok "local LLM stack ready - endpoint: $($llm.endpoint)  (models in $modelsDir)"
} else {
    Write-Warn "local LLM stack reachable at $($llm.endpoint), but its models are in $actualStore - NOT in the toolbox ($modelsDir)"
}
Write-Info "Point any OpenAI client at %TOOLBOX_LLM_URL%. Example: ollama run qwen2.5:3b"
