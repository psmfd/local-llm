# ADR-009: Mac as a single-model subagent workhorse, with the cloud as the frontier

- Status: accepted
- Date: 2026-06-29

This ADR is **additive and supersedes nothing** (see "Relationship to prior ADRs"
below). [ADR-006](006-multi-tier-coresident-lineup-stay-on-omlx.md) (three-tier
co-resident lineup) and [ADR-008](008-cross-host-routing-integration.md)
(cross-host AMD routing) remain the record of the currently-implemented state;
this ADR records a forward direction whose implementation is tracked in
[#14](https://github.com/psmfd/local-llm/issues/14).

## Context and Problem Statement

ADR-006 stood the Mac up as a three-tier, fidelity-by-workload lineup (two
co-resident pinned coders plus an on-demand "max" quality tier), and ADR-008
added a second always-on AMD vLLM appliance, routing `coding-fast` AMD-first and
treating the remote `coding-quality`/fallback backend as that appliance. The
use-case has since been reframed: a **cloud provider is the frontier** (the
high-fidelity quality tier), and the Mac's sole remaining job is to be a **local
subagent workhorse** — serving an orchestrator's fan-out of many concurrent
subagent requests that share long system prefixes (routine coding tool-chains:
reads/edits, search, codegen, summarization, structured tool-calling). What
single-host configuration best serves that workhorse role, where concurrent
throughput, prefix-cache reuse, and tool-call reliability matter far more than
single-stream quality?

## Considered Options

- **Keep ADR-006's three-tier co-resident lineup.** Rejected: the on-host quality
  tier is redundant once the cloud is the frontier, and it spends ~45 GB that the
  fan-out could use as KV headroom.
- **Keep two co-resident workhorses (T1 + T2).** Rejected: KV caches are
  model-specific, so a homogeneous fan-out gains nothing from a second model — it
  halves each model's prefix-cache hit rate and KV headroom while adding routing
  complexity.
- **Run a single larger gate-passing coder (40–70 GB) for higher quality.**
  Rejected: decode on the unified-memory bus is bandwidth-bound; a dense ~70B
  reads ~20× more weight per token than a 3B-active MoE for no concurrency gain,
  and the one plausible candidate (Qwen2.5-Coder-72B) fails oMLX tool-call
  parsing. The 3B-active MoE class is the bandwidth-optimal workhorse.
- **A MiniMax model (Text-01, M1, M2.x, M3).** Rejected (3-agent evaluation
  2026-06-29): MiniMax-Text-01/M1 use lightning (linear) attention — the same
  recurrent-state / prefix-cache incompatibility as DeltaNet — and have no Metal
  kernel; the full-attention M2 family (M2.5 = 80.2% SWE-bench) is
  prefix-cache-safe but size-gated (smallest viable MLX build ~92.9 GB leaves
  ~3 GB KV; 4-bit ~129 GB exceeds 128 GB RAM); M3 is a multimodal VLM (oMLX
  engine trap) at ~240 GB. **None fit the local host.** M2.5/M3 are elite coders,
  so they are noted instead as **cloud-frontier backend candidates**, not
  workhorse candidates.
- **Single pinned 3B-active MoE workhorse (chosen).**

## Decision Outcome

Chosen option: **a single pinned, text-only, 3B-active MoE coder on oMLX**,
because it gives the fan-out one shared prefix cache, 2–4× more KV headroom than
the ADR-006 pair, and never exercises oMLX's buggy multi-model swap path — while
keeping every tool-call path verified on oMLX.

**Model (CONFIRMED 2026-06-29 — gate resolved):** **`mlx-community/GLM-4.7-Flash-8bit`**.
The MLA-compression gate that was provisional at drafting is now **verified on-host**:
GLM's measured KV footprint matches Qwen-30B's GQA (~25× below an MHA fallback), so
oMLX's `mlx-lm` build runs MLA-compressed — GLM is adopted, the Qwen fallback is not
needed. GLM-4.7-Flash leads on the metrics that define the workhorse role
(tool-sequencing τ² 79.5% vs 49.0%, hallucination 6% vs 21%, SWE-bench 59.2% vs
~51.6%). `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` is retained on
disk as the verified fallback (GQA, prefix-cache-safe, tool-clean) should GLM ever
regress.

**Serving config (changes from ADR-006 in bold):**

- single model, `is_pinned: true`, `model_type_override: null` (both candidates
  are pure `*ForCausalLM`, no `vision_config` — they route to the batched LLM
  engine with no override)
- `--memory-guard-gb 90` (unchanged); Metal wired limit 96 GB (unchanged —
  bandwidth, not KV memory, is the binding constraint at practical concurrency;
  pushing to 100–104 GB buys <5%)
- **`--hot-cache-max-size 24GB`** (up from 18 GB — one model, no second cache to
  fund)
- **`--max-concurrent-requests 10`** — **"The Mark"**, set from on-host validation
  (see Validation results). The earlier theoretical "48" was wrong: the binding
  constraint under concurrent fan-out is **prefill-activation memory**, not KV.
  Safe concurrency is **inversely tied to context length** — measured clean ceiling
  is ≥15 @ ~9K ctx, ≥12 @ ~12K, **10 @ ~16K** (12 aborts at 16K). 10 holds across
  the realistic subagent context range and sits ~2× above the 4–8 steady load;
  the admission cap makes excess requests queue, and the memory guard aborts any
  overflow gracefully (HTTP 500, no crash).
- **Generous `max_tokens` required** — GLM-4.7-Flash emits a reasoning preamble
  before the tool call; `max_tokens` must be ≥ ~200 (120 truncated mid-call in
  testing) or the orchestrator must disable "thinking" if a flag exists.
- DFlash SSD cache stays disabled (oMLX #702/#1892)

**Validation results (on-host, M5 Max, 2026-06-29):**

1. **MLA-compression — PASS.** Isolated GLM server, ~7.3K-token prompt: KV
   footprint ≈ Qwen-30B GQA (GLM +214 MB vs Qwen +252 MB during decode; vmmap
   peak +2.87 GB ≪ the >7 GB an MHA fallback would require). oMLX runs GLM
   MLA-compressed → **GLM adopted**.
2. **Tool-call fidelity under cache-hit concurrency — PASS (to the memory limit).**
   Prefix reuse confirmed (`cached_tokens` ≈ 8,960/9,228 on repeat). At N ≤ 12 /
   ~9–12K ctx, every concurrent request returned a well-formed `tool_call` with
   valid args on a confirmed cache hit — no `#825`-style prose degradation.
3. **Concurrency ceiling — "The Mark" = 10.** A hard prefill-activation cliff
   exists (memory guard aborts above it): clean to N≥15 @ ~9K, ≥12 @ ~12K, **10 @
   ~16K**; N=12 aborts at ~16K. `--max-concurrent-requests` set to 10 for
   robustness across the context range.

Outstanding (non-blocking): the GLM-4.7-Flash SWE-bench figure (59.2%) is weakly
sourced; validate output precision on real orchestrator prompts in use.

The model decision rationale lives in `docs/runtime-tiering-research.md`; the
workhorse-reframe investigation (single-vs-dual, concurrency/bandwidth ceiling,
subagent workload profile) was produced by the parallel-agent research behind
this ADR.

## Relationship to prior ADRs (additive — supersedes nothing)

This ADR is recorded as a **forward direction**, not a supersession. ADR-006
(three-tier lineup) and ADR-008 (cross-host AMD routing) are left **untouched and
remain the record of the currently-implemented state** until the gates above pass
and `setup-omlx-m5.sh` is reworked (#14). The intended end-state this ADR adopts:

- the **Mac single-workhorse absorbs the local executor / `coding-fast` role**,
- the **AMD appliance (ADR-008) is repurposed or deprecated**, and
- the **cloud provider becomes the frontier / quality tier** in the
  `FallbackInferenceRouter`.

Formal supersession of ADR-006/008 is **deferred to the implementation PR (#14)**
so the record does not assert a teardown ahead of the validated change. Until
then, a reader should treat ADR-009 as the current *intent* and ADR-006/008 as
the current *implementation*.

### Consequences

- Good, because the fan-out gets one shared prefix cache and ~60 GB KV headroom
  (vs ~29 GB), and the single pinned model never triggers oMLX swap bugs
  (#1970/#1938).
- Good, because the workhorse role is matched to the bandwidth-optimal 3B-active
  MoE class and keeps every tool-call path verified on oMLX, at 8-bit for
  tool-call reliability.
- Good, because the dominant subagent UX lever — warm-prefix TTFT — is exactly
  what a single shared cache maximizes.
- Bad / accepted trade-offs:
  - **No on-host quality tier** — high-fidelity work now depends on cloud
    reachability; a cloud outage drops the frontier with no local quality
    backstop.
  - **Single point of serving** on the Mac for the local tier.
  - **Concurrency is prefill-activation-bound and context-dependent** — "The Mark"
    (10) falls as context grows; very long shared prefixes (>16K) at high fan-out
    hit the memory guard. Mitigated by the admission cap (excess queues) and
    graceful guard aborts, but the orchestrator should keep subagent prefixes
    modest.
  - GLM-4.7-Flash's quality figure (59.2% SWE-bench) is weakly sourced; output
    precision on real orchestrator prompts is still to be confirmed in use.
  - Deferring formal supersession leaves ADR-006/008 co-existing with this record
    until #14 lands; the intent-vs-implementation split must be read carefully in
    the interim.
