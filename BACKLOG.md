# Backlog - scripts-utilities

## Bugs

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
