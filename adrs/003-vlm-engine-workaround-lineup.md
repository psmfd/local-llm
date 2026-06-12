# ADR-003: Force the LLM engine for the VLM-classified primary; swap the secondary to a text-only coder

- Status: accepted
- Date: 2026-06-11

Supersedes [ADR-002](002-qwen36-lineup-memory-guard.md) for the model lineup
and adds an engine-override requirement. ADR-002's flag migration
(`--memory-guard-gb 90`), wired limit (96 GB), concurrency (16), and the
runtime choice from ADR-001 all carry forward unchanged.

## Context and Problem Statement

After ADR-002 was accepted, verification of the actual `config.json` files on
HuggingFace showed that **both** chosen models are vision-language builds:
`mlx-community/Qwen3.6-35B-A3B-8bit` (`Qwen3_5MoeForConditionalGeneration`,
full `vision_config` block) and `mlx-community/Qwen3.6-27B-6bit`
(`Qwen3_5ForConditionalGeneration`, `vision_config` present). oMLX's
`detect_model_type()` routes any model with a vision sub-config to its VLM
engine, and the VLM engine **crashes hard on any second concurrent request**
(oMLX issue #1800, open and unfixed in v0.4.4rc1: a `cache_offset == 0` scalar
comparison fails on the batched offset array, returning HTTP 500 to all
in-flight requests). `--max-concurrent-requests` is global-only — there is no
per-model cap to quarantine a VLM model. This breaks the 16-way fan-out the
whole project exists to serve. No text-only MLX build of Qwen3.6-35B-A3B
exists from any publisher (the entire quant matrix was checked). How do we
keep concurrency?

## Considered Options

- **Revert the primary to `mlx-community/Qwen3-Coder-Next-8bit`** (~79 GB,
  verified text-only `Qwen3NextForCausalLM`) — guaranteed safe, but re-inflates
  the memory budget (wired limit back toward 112 GB) and forfeits ADR-002's KV
  headroom; co-residency with any secondary becomes marginal again.
- **Keep the Qwen3.6 pair and force both onto the LLM engine** via oMLX's
  per-model `model_type_override: "llm"` (admin panel / REST
  `PUT …/models/{id}/settings`, persisted in `~/.omlx/model_settings.json`) —
  best memory economics, but the override's clean-load evidence (issue #1464)
  comes from the 4-bit build; if the 8-bit fails strict weight loading there is
  no safe model at all.
- **Hybrid (chosen):** keep the 35B primary with the `llm` override, and
  replace the (also-VLM) secondary with a **verified text-only** coder —
  `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` (~30 GB,
  `Qwen3MoeForCausalLM`, 8 of 128 experts active, coder-instruct-tuned,
  ~152K downloads) — so a concurrency-safe model exists regardless of how the
  override smoke-test lands.

## Decision Outcome

Chosen option: **hybrid**. Primary stays
`mlx-community/Qwen3.6-35B-A3B-8bit` (~37.7 GB, alias `coding-fast`) **with
`model_type_override = "llm"` mandatory** — the setup script applies it via
the admin REST API (`apply_model_override`), falling back to a printed manual
step when the server or model is not yet present. Secondary becomes
`lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` (~30.2 GB, alias
`coding-quality` — alias unchanged, so downstream router wiring is untouched).
Combined ~68 GB resident keeps ADR-002's 96 GB wired limit and
`--memory-guard-gb 90` valid.

`--validate` gains a **two-way concurrent completions probe**: single-stream
checks cannot detect a broken override (single-request VLM use works fine);
the concurrency probe is the regression gate for this entire decision.

### Consequences

- Good, because 16-way fan-out has a guaranteed-safe path (the text-only
  secondary) even if the primary's engine override fails, and the best-case
  path keeps ADR-002's memory economics.
- Good, because the override is scripted and idempotent — turn-key, not a
  tribal-knowledge admin-panel step.
- Bad / accepted trade-offs:
  - The 8-bit primary under the `llm` override is **unproven** — issue #1464
    demonstrates the batched engine loads the 4-bit Qwen3.6 MoE despite its
    vision config, but the 8-bit must pass the concurrency probe before the
    orchestrator points at it. If it fails strict weight loading, route the
    fan-out to `coding-quality` and treat the primary as single-stream only.
  - Forcing the LLM engine discards the primary's vision capability (irrelevant
    for this text/code workload).
  - The secondary's native context is 40,960 tokens — far below the primary's
    262K; long-context work must stay on the primary.
  - The secondary comes from `lmstudio-community` rather than `mlx-community`;
    both are established publishers, accepted.
  - The admin API mount prefix is probed (`/admin/api` vs `/api`) because
    oMLX's young CLI/API surface drifts; the step degrades to a warning plus
    manual instructions, never a hard failure.
  - Revisit when mlx-vlm PR #1354 (the `cache_offset` fix) merges and oMLX
    bumps its bundled mlx-vlm: at that point `Qwen3.6-27B-6bit` becomes viable
    again and this override may be removable.
