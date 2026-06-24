# ADR-006: Restore a multi-tier lineup — two co-resident pinned tiers + one on-demand max tier, staying on oMLX

- Status: accepted
- Date: 2026-06-24

Supersedes [ADR-004](004-single-text-only-model-no-override.md) for the model
lineup. **Reaffirms** [ADR-001](001-local-mlx-inference-omlx.md)'s runtime choice
(oMLX) and adds an explicit **co-resident / pinned / no-swap** operating mode.
ADR-002's flag migration (`--memory-guard-gb 90`), wired limit (96 GB),
concurrency (`--max-concurrent-requests 16`), and the runtime from ADR-001 all
carry forward unchanged. The full investigation behind this decision is recorded in
[docs/runtime-tiering-research.md](../docs/runtime-tiering-research.md) (Parts 1–6),
including an on-host bake-off on the M5 Max target.

## Context and Problem Statement

ADR-004 collapsed the lineup to a single text-only model, leaving the
`coding-quality` role to a remote fallback. The operator now wants to restore a
**3+ tier local lineup whose fidelity scales with the workload, selected
automatically with no manual model loading**. Before building this, two things had
to be settled: (1) is oMLX still the right runtime, or would switching unlock more
capable models; and (2) what concrete tiers actually work — verified on the target
hardware, not assumed?

## Considered Options

- **Keep ADR-004 (single text-only model).** Rejected: does not meet the multi-tier
  goal.
- **Switch runtime (llama.cpp / vllm-mlx) to escape the VLM trap and run the newest
  multimodal models text-only.** Rejected (research Part 6): the VLM-trapped models
  are not better *coders* (Gemma-3-27B ≈ half our LiveCodeBench; Qwen3.6-35B-A3B's
  lead is scaffold-inflated, within-noise of Qwen3-Coder-Next), and the genuinely
  stronger coders (Devstral-2-123B, Qwen3-Coder-480B, DeepSeek-V3) are **size-gated
  by the 128 GB ceiling**, which no runtime fixes. Switching would forfeit the
  MLX/M5 Neural-Accelerator speed path and re-open per-model tool-call verification
  for ~no capability gain.
- **oMLX native auto-swap (lazy load + LRU/TTL evict) as the steady-state tiering
  mechanism.** Rejected: oMLX's open multi-model swap-path bugs (#1970 lock-during-
  load blocks loaded models, #1938 memory-not-reclaimed, #514 stacked-OOM) plus the
  intrinsic loss of the shared prefix cache on every swap make swapping hazardous
  for the concurrent fan-out (research Parts 1, 3).
- **Add a co-resident dense "quality" T3 (Devstral-Small-2507 or
  Qwen2.5-Coder-32B).** Rejected empirically (research Part 5): both **fail
  tool-calling on oMLX** — Devstral emits no parseable call (even
  `tool_choice=required` ignored); Qwen2.5-Coder wraps calls in `<tools>` not
  `<tool_call>`, so oMLX drops them. No co-resident dense ~30B candidate is both
  strong at agentic coding and tool-clean on oMLX today.
- **Two co-resident pinned tiers + one on-demand max tier (chosen).**

## Decision Outcome

Chosen option: **two co-resident, pinned, text-only tiers plus one on-demand "max"
tier, all on oMLX, with no steady-state swapping**, because it delivers 3 tiers of
fidelity-by-workload while keeping every tool-call path verified-working on oMLX and
never exercising the buggy multi-model swap path.

| Tier | Model | Quant | ~Resident | Tools on oMLX (verified) | Role |
|---|---|---|---|---|---|
| T1 fast | `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` (alias `coding-fast`) | 8-bit | ~30.6 GB | ✓ | general coding, tool chains |
| T2 medium | `mlx-community/GLM-4.7-Flash-8bit` | 8-bit | ~30 GB | ✓ | fast tool relay / agentic |
| Max | `lmstudio-community/Qwen3-Coder-Next-MLX-4bit` | 4-bit | ~45 GB | ✓ | high-fidelity (~71% SWE-bench); on-demand |

- **T1 and T2 are co-resident and `is_pinned: true`**; combined ≈ 61 GB leaves
  ~29 GB for KV/prefix cache under the 90 GB guard (96 GB Metal wired ceiling).
  Verified: T1+T2 at 16-way concurrency returned 16/16.
- **The "max" tier (Qwen3-Coder-Next) is on-demand** — oMLX lazy-loads it on first
  request (~16 s) and it TTL-evicts when idle. It is **not** co-resident (45 GB +
  61 GB > guard). Because it is hit rarely and T1/T2 stay pinned, the swap-path bug
  exposure is bounded; this is the only place a load occurs in normal operation.
- **DFlash SSD cache stays disabled** (oMLX #702 enforcer undercount, #1892
  single-DFlash-model limit).
- **Routing is by the request `model` field** (aliases/dir names); the downstream
  .NET `FallbackInferenceRouter` is kept **runtime-agnostic** (one endpoint) so the
  engine remains swappable if oMLX's swap-path bugs ever block a future need.
- GLM-4.7-Flash measured at ~30 GB resident (the prior ~21 GB estimate was wrong).

This satisfies "3+ tiers, fidelity-by-workload" (fast → tool-relay → high-fidelity
on demand) with zero steady-state swapping.

### Consequences

- Good, because three fidelity tiers are available with **every tool path verified
  on oMLX**, and the co-resident pair **never triggers** the open multi-model
  swap-path bugs (nothing loads/evicts in steady state).
- Good, because it keeps oMLX's MLX/M5 Neural-Accelerator speed path and block-level
  prefix cache, and Qwen3-Coder-Next (~71% SWE-bench) is the genuine capability
  ceiling for 128 GB — the strongest agentic coder that fits.
- Good, because memory hygiene was verified (clean release on stop/kill; exo #1370
  did not reproduce) and the lineup leaves generous KV headroom.
- Bad / accepted trade-offs:
  - **No co-resident dense "quality" tier** — every ~30B dense candidate either
    fails tool-calling on oMLX or is a weak agentic coder. Add one later only if a
    ~30B model ships that is both strong at agentic editing **and** tool-clean on
    oMLX.
  - The **max tier pays a ~16 s cold start** on its (rare) loads and carries
    bounded #1970 exposure while loading under concurrent T1/T2 traffic.
  - The runtime bet remains a young, ~single-maintainer project (oMLX) with open
    bugs; mitigated by pinning + no-swap and the runtime-agnostic router.
  - **Revisit triggers:** (a) the VLM trap — re-evaluate multimodal models if oMLX
    bumps its bundled `mlx-vlm` past PR #1354 **and** the remaining batching bugs
    (#1422, #1378) close; (b) a tool-clean co-resident dense coder shipping; (c) a
    larger text-only coder that fits 128 GB.
