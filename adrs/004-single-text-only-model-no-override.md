# ADR-004: Drop to a single text-only model; retire the VLM engine override

- Status: superseded by [ADR-006](006-multi-tier-coresident-lineup-stay-on-omlx.md)
- Date: 2026-06-22

Supersedes [ADR-003](003-vlm-engine-workaround-lineup.md) for the model lineup
and removes the engine-override requirement it introduced. ADR-002's flag
migration (`--memory-guard-gb 90`), wired limit (96 GB), concurrency (16), and
the runtime choice from ADR-001 all carry forward unchanged.

## Context and Problem Statement

ADR-003 kept the natively-multimodal `mlx-community/Qwen3.6-35B-A3B-8bit` as the
primary and forced it onto the batched LLM engine via `model_type_override = llm`
to dodge the VLM-engine concurrency crash (oMLX #1800). A first-party
re-verification on 2026-06-22 confirmed three things: (1) #1800 is still open and
unfixed (v0.4.4); (2) **every** MLX repack of Qwen3.6-35B-A3B carries the trap —
the `unsloth/Qwen3.6-35B-A3B-MLX-8bit` alternative is *also* mlx-vlm-packaged
(`vision_config`, `Qwen3VLProcessor`, `Qwen3_5MoeForConditionalGeneration`), an
equal-or-stronger VLM-routing signal — because the base model ships a vision
tower; (3) the secondary, `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit`,
is verified text-only (`Qwen3MoeForCausalLM`, no `vision_config`, **262,144**-token
native context with `rope_scaling: null` — not the 40,960 ADR-003 recorded) and is
concurrency-safe with no override. The override path is therefore unproven,
fragile (it rides an open upstream bug), and — given a fully-safe coder model
exists — unnecessary. Do we keep paying for it?

## Considered Options

- **Keep ADR-003's hybrid** (35B primary + override, 30B-Coder secondary). Best
  raw model size, but the concurrent path depends on an open upstream bug and an
  admin-API override that drifts with oMLX's young CLI surface.
- **Swap roles** (30B-Coder primary, 35B override-bearing secondary). Makes the
  default path override-free, but keeps the override machinery alive for a
  fallback that is now the *riskier* model — an inversion of the safety story, and
  two co-resident models (~70 GB) halve the KV/prefix-cache budget.
- **Single text-only model (chosen).** Ship only
  `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` as `coding-fast`.
  Delete the override step, the `--with-secondary` flag, and the secondary
  download/provider wiring. No larger text-only coder fits 128 GB cleanly
  (Qwen3-Coder-480B ≈ 540 GB, Kimi K2.x needs 192 GB+), so a second local model
  buys little for a coding fan-out.

## Decision Outcome

Chosen option: **single text-only model**. The only model is
`lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` (~32 GB,
`Qwen3MoeForCausalLM`, 262,144 native context, coder-instruct-tuned, strong
native tool-calling), alias `coding-fast`. The setup script no longer applies any
engine override, no longer offers `--with-secondary`, and the `--validate`
two-way concurrency probe is retained as a general batched-engine health check
(no longer an override regression gate). The `coding-quality` role is no longer
backed locally; the downstream `FallbackInferenceRouter` falls through to a remote
backend for it (see `docs/router-wiring.md`).

This ADR also records three documentation corrections from the same
re-verification: `--hot-cache-max-size` accepts **both** absolute sizes and
percentages (oMLX docs) — the prior "absolute only / rejects percentages" claim
was wrong; the chosen model's native context is **262,144**, not 40,960; and oMLX
MCP support is enabled via a separate `pip install mcp` + `--mcp-config`, not a
package "extra" marker (the no-MCP policy is unchanged).

### Consequences

- Good, because the concurrent path is override-free and rides no open upstream
  bug — the whole `model_type_override` / admin-API-probe surface is deleted.
- Good, because a single ~32 GB resident model leaves ~64 GB under the 96 GB
  wired ceiling for KV and prefix cache across the 16-way fan-out (vs ~26 GB when
  two large models were co-resident) — more concurrent throughput and prefix
  reuse, the project's stated priority. This also opens headroom to later raise
  `--hot-cache-max-size` or `--max-concurrent-requests` if measurement warrants.
- Good, because the model is purpose-built for coding with strong tool-calling
  and a 262K native context — long-context work no longer needs a separate model.
- Bad / accepted trade-offs:
  - No local "quality" tier — `coding-quality` depends on a remote fallback. If a
    larger *text-only* coder that fits 128 GB ships later, add it back as a
    secondary under a new ADR.
  - The general vision capability of the 35B is forgone (irrelevant for this
    text/code workload).
  - Revisit if the workload shows the 30B-Coder is under-powered for the
    "quality" role, or if mlx-vlm PR #1354 (#1800's fix) merges and makes the
    multimodal Qwen3.6 builds concurrency-safe without an override.
