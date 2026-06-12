# ADR-001: Local MLX inference via oMLX on the M5 Max

- Status: superseded by [ADR-002](002-qwen36-lineup-memory-guard.md)
- Date: 2026-05-29

## Context and Problem Statement

The orchestrator fans out 3+ concurrent agent requests that share long system
prefixes. We want a local inference backend on the MacBook Pro (Apple Silicon
**M5 Max, 128 GB unified memory, ~614 GB/s** bandwidth) to serve a coding model
without per-token API cost, while keeping data on-device. For this workload,
**concurrent throughput and prefix-cache reuse matter more than single-stream
tokens/sec**, and the model must emit well-formed `tool_call` markup reliably.

Which runtime, which model, and what serving configuration?

## Considered Options

**Runtime**

- **oMLX (`jundot/omlx`)** — Apple-Silicon MLX server with continuous batching and
  SSD-paged KV cache; native OpenAI (`/v1/chat/completions`) and Anthropic
  (`/v1/messages`) endpoints; menu-bar/admin management.
- **`mlx_lm.server`** — the reference MLX server. Minimal; weaker concurrency and
  no built-in paged-SSD cache or admin/pinning.
- **LM Studio** — GUI-first; OpenAI-compatible server, but heavier and less
  scriptable for a headless launchd service.
- **`llama.cpp`** — GGUF, not MLX; mature, but does not exploit the MLX/Metal path
  these Qwen MLX builds are quantized for.

**Primary model**

- **Qwen3-Coder-Next 80B-A3B, 8-bit MLX** (`mlx-community/Qwen3-Coder-Next-8bit`,
  ~85 GB) — MoE, ~3B active params → fast decode under the bandwidth cap; 8-bit
  preserves tool-call JSON fidelity; trained across many agent tool templates.
- 4-bit variant (~45 GB) — more KV headroom, some quality loss.
- Dense ~70B models — far slower decode at this bandwidth; rejected.

## Decision Outcome

Chosen: **oMLX** as the runtime, **Qwen3-Coder-Next-8bit** as the primary model
(alias `coding-agentic`), served on port 8000 with these flags and an API key from
a 0600 file:

```text
--port 8000 --max-process-memory 110GB --paged-ssd-cache-dir ~/.omlx/cache \
--hot-cache-max-size 20% --max-concurrent-requests 8 --api-key <0600 file>
```

The Metal wired limit is raised to **112 GB** (`iogpu.wired_limit_mb=114688`)
and persisted via a root LaunchDaemon; the server autostarts via a per-user
LaunchAgent running a wrapper that carries the tuned flags. The **MCP extra is not
installed** (per the no-MCP policy). A secondary model (Qwen3.6-35B-A3B-8bit,
alias `coding-fast`) is left as an opt-in (`--with-secondary`) because both models
fully resident (~122 GB) exceed the wired/process budget.

oMLX wins because it is the only candidate combining MLX-native execution,
continuous batching + paged-SSD cache (prefix reuse across concurrent agents),
and first-class OpenAI **and** Anthropic endpoints — matching the orchestrator's
fan-out and dual-protocol needs without a proxy.

### Consequences

- Good: concurrent throughput and prefix-cache reuse are first-class; `/v1` and
  `/v1/messages` cover both client styles; on-device, no per-token cost.
- Good: MoE/8-bit balance gives fast decode with reliable tool-call markup.
- Bad / accepted trade-offs:
  - **Pinning and aliasing are admin-panel (GUI) only** — not scriptable; the
    setup prints manual steps and aliases persist in `~/.omlx/settings.json`.
  - **Known oMLX alias bug:** per-model settings (e.g. context length) may not
    apply when a request addresses the model by its alias rather than its
    directory name. Verify per-model settings take effect after pinning.
  - **API key visible to `ps`:** the wrapper passes `--api-key <value>` on the
    command line, so the key appears in the process argument list. Current
    workaround: the key lives only in the 0600 file and is read at launch — this
    is preferred over a tracked file. Move it to the LaunchAgent
    `EnvironmentVariables` dict (`OMLX_API_KEY`) once oMLX supports an env/file
    key option; tracked as a known gap.
  - The secondary model is multimodal (loaded via `mlx_vlm`); fine for text/code.
  - oMLX is a young project; its CLI surface may drift — the setup script and
    wrapper fail loudly rather than mis-configuring silently.
