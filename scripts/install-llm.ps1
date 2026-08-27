#Requires -Version 5.1
<#
Provision the optional local-LLM stack (opt-in; not part of the default groups).

Runtime: Ollama (winget), which runs a per-user background service at
127.0.0.1:11434 exposing an OpenAI-compatible API. Models are stored inside the
toolbox (OLLAMA_MODELS -> <toolbox>\models) so the uninstaller clears them with
the rest of the toolbox. Model pulls are VRAM-tiered: an 8 GB box pulls the light
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
    foreach ($f in $rr.files) {
        $out = Join-Path $dir (Split-Path $f -Leaf)
        if (Test-Path $out) { continue }
        $url = "https://huggingface.co/$($rr.hf_repo)/resolve/main/$f"
        Write-Info "download reranker file: $f"
        try { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing }
        catch { Write-Warn "reranker download failed ($f): $_" }
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
    if (-not (Wait-Ollama)) {
        Write-Warn "Ollama service did not become reachable at 127.0.0.1:11434 - open a new shell (or start the Ollama app) and re-run to pull models"
    }
}
foreach ($m in $models) {
    if ($DryRun) { Write-Info "[DRY-RUN] would: ollama pull $m"; continue }
    Write-Info "ollama pull $m"
    & ollama pull $m
    if ($LASTEXITCODE -ne 0) { Write-Warn "pull failed: $m (skipping)" }
}

if (-not $SkipReranker) {
    Write-Group "reranker (ONNX via toolbox Python)"
    Install-Reranker
}

Write-Group "done"
Write-Ok "local LLM stack ready - endpoint: $($llm.endpoint)  (models in $modelsDir)"
Write-Info "Point any OpenAI client at %TOOLBOX_LLM_URL%. Example: ollama run qwen2.5:3b"
