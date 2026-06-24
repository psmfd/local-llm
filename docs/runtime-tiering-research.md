# Research: runtime choice & multi-tier model serving

> **Status: LIVING / RESEARCH COMPLETE, DECISION PENDING** (2026-06-23). This is
> a research reference note, **not** a decision record. The decision it feeds
> will be captured in a new ADR (expected ADR-006, superseding
> [ADR-004](../adrs/004-single-text-only-model-no-override.md), and revisiting
> [ADR-001](../adrs/001-local-mlx-inference-omlx.md)'s runtime choice) once a
> direction is chosen. Part 1 (oMLX auto-swap capability) and Part 2 (runtime
> reassessment) are both complete.

## Why this exists

ADR-004 collapsed the lineup to a **single text-only model**
(`lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit`, alias `coding-fast`),
with the `coding-quality` role falling through to a remote backend. The operator
now wants to **restore a multi-tier (3+) local lineup** where fidelity/quality
scales with the workload, ideally **swapped automatically with zero developer
interaction**. Before designing that on oMLX, we are reassessing whether oMLX is
still the right foundation.

### Goals (the criteria all findings are judged against)

- **3+ fidelity tiers** (small → large), selected automatically by the request's
  `model` field — no manual load/unload.
- **Parallel-agent coding workload**: an orchestrator fans out 3+ concurrent
  requests sharing long system prefixes. The dominant levers are **continuous /
  in-flight batching** and **prefix-cache / KV reuse** across those concurrent
  requests; single-stream tok/s is secondary.
- OpenAI-compatible (`/v1/chat/completions`) + Anthropic-style (`/v1/messages`)
  API; strong **tool-calling JSON fidelity**.

### Hard constraints (carried from prior ADRs)

- Host: Apple Silicon **M5 Max, 128 GB unified memory**; Metal wired limit
  ~96 GB; `--memory-guard-gb 90`; `--max-concurrent-requests 16`.
- **Text-only models only** (`*ForCausalLM`, no `vision_config`): oMLX routes any
  vision-config model to a VLM engine that **crashes on concurrent requests**
  (issue #1800). Prefer **8-bit** quant for tool-call fidelity.
- No MCP.

---

## Part 1 — Can on-demand model swapping be fully automatic on oMLX? (COMPLETE)

**Answer: yes, natively, with zero operator action — but auto-swap must be a
*rare* path, not the steady state, for this concurrent workload.**

### 1.1 oMLX is a single-process, multi-model `EnginePool`

This is the key reframe: it is **not** a one-model-at-a-time server. One oMLX
process can hold multiple models resident *and* lazily load/evict others. So
"co-resident" and "swap" are not mutually exclusive — you get both at once.
Source-verified against `engine_pool.py`, `model_settings.py`, `server.py`,
`model_registry.py`:

- **Lazy load on request** — `EnginePool.get_engine(model_id)`: if a registered
  model is not resident, the request triggers an automatic load (admission flow:
  project memory → evict LRU victims if needed → `_load_engine()`). No admin
  click, no `omlxctl` call.
- **Automatic eviction** — LRU under memory pressure (`_find_lru_victim()`, runs
  synchronously inside `get_engine()`) **and** per-model idle TTL
  (`check_ttl_expirations()`, polled every 1s).
- **Pinning** — `is_pinned: true` exempts a model from both LRU and TTL.
- **Lease protection** — in-flight requests (`in_use > 0`) cannot be evicted
  mid-stream.
- Models auto-discovered from `--model-dir` / `OMLX_MODEL_DIR`; routing resolves
  the request `model` field via `pool.resolve_model_id()` (exact → case-insensitive
  → profile names → `model_alias` scan → provider-prefix strip).

### 1.2 Lifecycle config keys (complete)

| Config | Location | Default | Semantics |
|---|---|---|---|
| `ttl_seconds` | per-model `ModelSettings` | `None` | auto-unload after N s idle; `None` = disabled |
| `idle_timeout_seconds` | `GlobalSettings` | `None` | global TTL fallback; min 60 s |
| `is_pinned` | per-model `ModelSettings` | `false` | exempt from TTL **and** LRU |
| `--memory-guard` | CLI | `balanced` | ceiling tier: `safe`/`balanced`/`aggressive` |
| `--memory-guard-gb` | CLI | — | custom ceiling in GB (we use `90`) |
| `memory_guard_custom_ceiling_gb` | `settings.json` | `0.0` | persistent form of above |
| `soft_threshold` / `hard_threshold` | `settings.json` | `0.85` / `0.95` | eviction trigger fractions |
| `prefill_memory_guard` | `settings.json` | `true` | prefill-peak memory protection |

There is **no `--max-loaded-models` cap** — the memory ceiling is the only
admission gate. Admin REST API also exposes explicit
`POST /admin/api/models/{id}/load` · `/unload`, `GET /admin/api/models`,
`PUT .../settings`, `PUT /admin/api/global-settings`, `POST /admin/api/cache-probe`.

### 1.3 The catch — why auto-swap must be the rare path here

Two independent reasons make *swapping under concurrent load* hazardous for this
workload:

**(a) Open v0.4.x swap-path bugs (all relevant to a concurrent fan-out):**

| Issue | State | Impact |
|---|---|---|
| **#1970** | open (2026-06-22) | `get_engine()` holds the asyncio lock for the **whole** model load → blocks inference on **already-loaded** models; HTTP 507 if all resident models are busy and nothing is evictable; 4–6× load degradation under concurrency |
| **#1938** | open (2026-06-19) | memory not reclaimed after rapid load/unload cycling (impossible negative `freed`); needs server restart |
| **#514** | open | "stacked models" — old model not always evicted before new loads → OOM |
| **#702** | open | memory enforcer tracks only Metal allocations, undercounts SSD hot-cache → macOS jetsam SIGKILL |
| **#1892** | open (2026-06-16) | only **one** Dflash SSD-cache model at a time in v0.4.x (regression) |
| **#1800** | open (2026-06-10) | VLM engine crashes on concurrent requests → **text-only only** |

**(b) Physics, regardless of bugs:** every *actual* swap evicts that model's
KV/prefix cache (it is weight-specific, not reusable across models), and two
concurrent requests for *different* unloaded tiers serialize behind 8–35 s loads.
That destroys the prefix-cache reuse + concurrency the project exists to optimize.

**Mitigations:** pin the hot tier(s) co-resident; size the co-resident set to fit
under the 90 GB guard so swaps are rare; set conservative `ttl_seconds` on rarely
used tiers; **avoid the Dflash SSD cache** (#702, #1892); track #1970/#1938.

### 1.4 Memory math (M5 Max, ~90 GB guard, ~84–86 GB effective for weights+KV)

| Lineup | Resident weights | KV/prefix headroom | Verdict |
|---|---|---|---|
| small (~9 GB) + 30B-A3B MoE (~32 GB) | ~41 GB | ~20+ GB | comfortable; both **pinned** |
| + 14B dense (~16 GB) = 3 tiers | ~57 GB | tighter, viable | 3 tiers co-resident, **no swap ever** |
| dense **70B Q8** (~74 GB) | maxes guard alone | none | **cannot co-reside** — the only tier that forces real swap or remote |

8-bit ≈ 1 byte/param + ~5–10 % overhead. Cold-start (disk→ready, ~6–7 GB/s NVMe):
~3–6 s (7–8B), ~8–15 s (30–34B), ~18–35 s (70B Q8).

**Implication:** if the top tier is a strong **MoE** (current 30B-A3B, or a larger
MoE at a fitting quant), all 3+ tiers co-reside and the swap tax is never paid.
Auto-swap (and its bug exposure) is only required for a genuinely large **dense**
local tier.

---

## Part 2 — Runtime reassessment: stay on oMLX vs switch (COMPLETE)

### 2.1 The decision-forcing finding

oMLX was chosen (ADR-001) for **batched concurrent throughput + block-level
prefix-cache reuse** for the fan-out. In v0.4.x today, that exact subsystem —
concurrent *multi-model* serving with SSD-tiered prefix cache — sits on four
intersecting **open** bugs:

| Issue | Hits |
|---|---|
| #1970 | asyncio lock held for the whole model load → blocks inference on already-loaded models; HTTP 507; 4–6× degradation under concurrency (filed 2026-06-22, no response) |
| #1892 | DFlash SSD prefix cache works for **only one model at a time** → negates the multi-tier prefix-cache benefit |
| #1938 | memory not reclaimed after load/unload cycling → server restart needed |
| #514 | stacked-model OOM (old model not evicted) |

Plus #702 (enforcer undercounts SSD cache → jetsam SIGKILL), #1800 (VLM engine
crashes on concurrency → text-only only), and #95 (Metal command-buffer race on
concurrent requests, per the runtime-matrix agent). **Project health is good; the
specific feature surface we'd build on is not.**

### 2.2 The gap that has closed

oMLX's headline differentiator — cross-request shared-prefix KV reuse — is **no
longer unique**. Apple's own **`mlx_lm.server`** (`ml-explore/mlx-lm`) has an
`LRUPromptCache` trie shared across all concurrent requests in one process: a long
shared system prompt is computed once and reused for every concurrent agent on
that model — exactly the fan-out behavior we wanted, working correctly. It also
has real continuous batching (`BatchGenerator`, `--decode-concurrency`,
`--prompt-concurrency`). Caveat: **single-model only**, and Apple labels it "not
production-ready."

`llama-server` (llama.cpp) also gained a **native multi-model router**
(`--models-max`, lazy autoload), **both** OpenAI and Anthropic endpoints, and true
continuous batching — but llama.cpp **cannot use the M5 Neural Accelerators**
(MLX-only), so it's ~1.4–1.8× slower on prefill, and its prefix cache is per-slot,
not cross-request block-level.

### 2.3 Runtime scorecard (for THIS workload)

| Runtime | Multi-model zero-touch | Continuous batching | Cross-request prefix cache | M5 NPU path | API (OAI/Anthropic) | Liveliness / risk |
|---|---|---|---|---|---|---|
| **oMLX** | yes (EnginePool, lazy+LRU+TTL+pin) | yes | yes — **but broken under multi-model (#1970/#1892/#1938)** | yes (MLX) | both | Active; **High risk** for this workload |
| **mlx_lm.server** | no (single-model) | yes | **yes (LRU trie, correct)** | yes (MLX) | OAI (+Anthropic via proxy) | Active (Apple); Low — but "not production-ready" |
| **llama-server + llama-swap** | yes (router / llama-swap matrix) | yes | per-slot only; `-kvu` unified buffer | **no (GGUF/Metal, ~1.5× slower)** | both | Active; Low (llama.cpp), Low-Med (llama-swap) |
| **Ollama** | yes (auto load/unload, TTL) | **no — queue/slot based** | limited (single-path trie) | yes (MLX backend, maturing) | both | Active; Medium |
| **LM Studio** | yes | yes (open prefill-stall bug) | **not shared across concurrent** | yes (MLX) | both | Active; Medium |

### 2.4 Lock-in / migration cost

Low at the **API layer** (every alternative speaks `/v1/chat/completions`; the
.NET router is unchanged), low at the **code layer**, **medium at the operational
layer**: the admin-panel aliasing/TTL/pinning moves to startup flags or
llama-swap YAML (more version-controllable anyway), launchd plists are re-pointed.
Genuinely hard to replace: **DFlash SSD-tiered KV cache** (no alternative — but
broken for multi-model in v0.4.x regardless) and the Anthropic prefix-cache token
fields (`cache_creation_input_tokens` / `cache_read_input_tokens`) if anything
upstream consumes them.

### 2.5 Recommended target lineup (text-only, VLM-trap-screened, HF-verified)

Disqualified by VLM trap or size (verified via `config.json`): the **entire
Qwen3.6 series**, **Kimi K2.x** (multimodal + 1T), **Mistral-Small-3.2-24B**
(VLM despite the name), **DeepSeek-V3 / Qwen3-Coder-480B** (text-only but
≥270 GB).

**Flavor 1 — all co-resident (~70 GB weights, no swap ever):**

| Tier | Model | Quant | Repo | Weights |
|---|---|---|---|---|
| T1 fast | Qwen3-Coder-30B-A3B (current) | 8-bit | `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` | 32.4 GB |
| T2 medium | GLM-4.7-Flash | 8-bit | `mlx-community/GLM-4.7-Flash-8bit` | ~21 GB |
| T3 fidelity | DeepSeek-Coder-V2-Lite (or GLM-Z1-32B-4bit) | 8-bit | `mlx-community/DeepSeek-Coder-V2-Lite-Instruct-8bit` | 16.7 GB |

**Flavor 2 — large top tier:** T1+T2 co-resident (~53 GB) + **Qwen3-Coder-Next**
as T3 — 4-bit (`lmstudio-community/Qwen3-Coder-Next-MLX-4bit`, 44.8 GB, **70.6%
SWE-bench**, all three co-fit at ~98 GB) or 8-bit (84.7 GB, solo/on-demand).
Note: T3 here is `Qwen3NextForCausalLM` (hybrid attention) — see the unresolved
claim in §2.7.

### 2.6 Best-of-breed recommendation

**Do not build the multi-tier auto-swap design deeper on oMLX.** Instead:

1. **Insert a runtime-agnostic proxy now** (llama-swap) in front of the engine.
   The .NET router targets the proxy and never changes again regardless of
   backend. Anthropic `/v1/messages` passes through.
2. **Prefer the co-resident lineup (Flavor 1) so swapping never happens.** Run
   each tier as its own always-on **`mlx_lm.server`** process (correct
   cross-request prefix cache + continuous batching + the MLX NPU speed path);
   llama-swap routes by the `model` field. Three always-on processes at ~70 GB fit
   the budget — this sidesteps BOTH oMLX's multi-model bugs AND llama-swap's
   process-kill memory-release risk (no kills).
3. **Only if a genuine large dense/Next top tier is required** (Flavor 2, 84.7 GB
   solo) accept on-demand load + eviction, and **empirically validate Metal
   memory actually releases on process kill** before relying on it (open risk
   exo #1370).
4. Keep **oMLX as a backend option behind the proxy** for single-model use (it is
   correct for one-model-many-requests with pinning) and revisit if DFlash
   multi-model support ships.

This decouples the engine decision from the architecture permanently, delivers the
prefix-cache behavior the project wanted **today**, and avoids the open-bug surface.

### 2.7 Conflicts & unverified claims (carry into ADR-006 verification)

- **oMLX maintainer concentration**: prior review said ~93% of commits are
  jundot's; the critical-risk agent said ~40% with ~10 active contributors and
  ~17k stars. **Conflict — re-check before citing.** Either way, bus-factor is the
  weaker argument; the open multi-model bugs are the decisive one.
- **oMLX hybrid-attention tool-call breakage**: the runtime-matrix agent claimed
  oMLX mishandles tool-calls for hybrid-attention models (Qwen3.x / Gemma3 /
  Llama4). **Unverified, single-source.** Material because T1 and the Flavor-2 T3
  are Qwen3.x — verify directly (a tool-call round-trip on each candidate) before
  finalizing the lineup/runtime.
- **`mlx_lm.server` "not production-ready"** label — validate stability under the
  16-way concurrent load before committing.
- The three reassessment agents each opened with a hallucinated "all N agents
  returned" preamble (they ran independently); their framing was discounted,
  source-cited facts retained.

### 2.8 Agent Efficacy Report (Part 2)

| Agent | Type | Key contributions | Value |
|---|---|---|---|
| Runtime matrix | general-purpose | llama-server native router + dual API + M5-NPU/MLX speed gap; per-runtime scorecard & liveliness | High |
| Critical risk review | general-purpose | Decision-forcing bug intersection; the closed gap (mlx_lm.server LRU trie); decisive hedge-with-llama-swap + mlx_lm.server-per-tier architecture; migration-cost layering | High |
| Model lineup | general-purpose | config.json-verified text-only screening (killed the whole Qwen3.6/Kimi/Mistral-3.2 VLM set); two memory-budgeted 3-tier flavors with exact repo IDs | High |

**Disagreements:** Runtime-matrix leaned "conditionally keep oMLX for
full-attention models / use llama-server for max tool-call fidelity"; critical-risk
leaned "hedge off the engine entirely via llama-swap + mlx_lm.server." Resolved in
favor of the hedge — it satisfies both (oMLX *can* remain a backend) while removing
the bug exposure. **Synergy:** matrix's NPU-speed finding + critical-risk's
mlx_lm.server-prefix-cache finding + lineup's co-resident budget converge on
"3 always-on mlx_lm.server tiers behind llama-swap, no swapping."

---

## Part 3 — Empirical verification on the M5 Max (bake-off)

Run 2026-06-23 on the target host (Mac17,6 **Apple M5 Max, 128 GB**, macOS 26.5.1,
oMLX **v0.4.4**, `mlx-lm` **0.31.3** installed via `uv tool`). Scripts in the
session scratchpad (not committed). The on-disk model is
`Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` (alias `coding-fast`, `is_pinned: true`).

### Phase A — recommended Flavor-1 architecture (COMPLETE)

| # | Test | oMLX v0.4.4 | mlx_lm.server 0.31.3 |
|---|---|---|---|
| A2/A3 | Tool-call round-trip (30B, full-attn MoE) | **PASS** — `finish_reason=tool_calls`, args `{"city":"Paris"}` | **PASS** — identical well-formed JSON |
| A4 | 16-way concurrency (shared long prefix, 952 prompt-tok) | **16/16**, wall **4.57 s**, single-baseline 0.63 s (~2.2× batch) | **16/16**, wall **2.76 s**, single-baseline 1.01 s (~5.8× batch); logs show batched prefill at `--prompt-concurrency 8` |
| A5 | Memory release on stop/kill | graceful `omlxctl stop` freed **30.3 GB** | SIGTERM freed **39.4 GB**, process gone |

**Findings:**

- **No concurrency crash on either engine.** The oMLX bugs #1970/#95 concern
  *multi-model swap*, not single-model load — confirming the per-tier-process
  design (one model per `mlx_lm.server`) sidesteps them entirely.
- **mlx_lm.server matched/beat oMLX on the concurrent fan-out** (2.76 s vs 4.57 s
  wall for 16), the exact property oMLX was originally chosen for. oMLX wins
  single-stream latency (0.63 s vs 1.01 s). Single-run sample — directional.
- **The exo #1370 "memory won't release on kill" risk did NOT reproduce** on this
  M5 Max for either engine; both released ≥ the model footprint cleanly.
- oMLX cold start to ready ≈ 2 s (model pinned/warm cache); mlx_lm.server load
  ≈ 4 s from cold.

**Phase A verdict:** the recommended architecture (per-tier `mlx_lm.server` behind
a runtime-agnostic proxy, co-resident lineup, no swapping) is **validated** — tool
fidelity, concurrent batching, and memory hygiene all hold, and mlx_lm.server is at
least competitive with oMLX on the metric that drove the original choice.

### Phase B — hybrid-attention tool-call claim (COMPLETE)

Model: `lmstudio-community/Qwen3-Coder-Next-MLX-4bit` (42 GB on disk, 9 shards;
verified `Qwen3NextForCausalLM`, **text-only**, 262K ctx — the genuine
Gated-DeltaNet+Attention hybrid). Same `get_weather` tool-call round-trip.

| Engine | Result | Detail |
|---|---|---|
| **oMLX v0.4.4** | **PASS ✓** | well-formed `{"city":"Paris"}`; first request 15.9 s incl. **live lazy auto-load** of the 45 GB model (confirms Part 1 auto-swap end-to-end) |
| **mlx_lm.server 0.31.3** | **FAIL ✗ (3/3 deterministic)** | `finish_reason=tool_calls` but **empty `tool_calls`**; server log: `Failed to parse tool call (JSONDecodeError)` — its generic parser can't extract Qwen3-Coder's native (XML-ish `<tool_call>`) format; only 22 completion tokens, so not a length truncation |

**Phase B verdict — the §2.7 claim is REFUTED, and the inverse is true:**

- oMLX does **not** mishandle hybrid-attention tool-calls — it parsed Qwen3-Coder-Next
  correctly (it ships Qwen-aware tool parsing).
- **mlx_lm.server's tool-call parsing is model-format-dependent**: it handled
  Qwen3-Coder-30B-A3B (Phase A) but **fails on Qwen3-Coder-Next**. This is a real
  gap in the proposed replacement engine for the strongest local coder (70.6%
  SWE-bench), reproduced 3/3.

## Part 3 conclusion — recommendation REVISED by the empirics

The Part 2 lean was "switch off oMLX to mlx_lm.server-per-tier." **The bake-off
moves that back toward "stay on oMLX, configured to never swap."** Reasons, all
empirically grounded:

1. **oMLX's open bugs are all on the multi-model *swap/load* path** (#1970 lock
   during load, #1938 cycling, #514 stacked-OOM, #1892 DFlash). **A co-resident,
   pre-warmed, *pinned*, DFlash-off lineup never triggers them** — nothing loads
   or evicts in steady state. Single-model 16-way concurrency ran 16/16 clean on
   oMLX (and on mlx_lm.server).
2. **oMLX has stronger, more uniform tool-call fidelity** — it parsed both
   Qwen3-Coder variants; mlx_lm.server failed on Qwen3-Coder-Next (3/3). For
   agentic coding, tool fidelity outranks the modest batch-throughput edge.
3. **Memory hygiene is fine on this host** — both engines released cleanly on
   stop/kill; the exo #1370 risk did not reproduce.
4. The one place mlx_lm.server won — **16-way batch wall-time (2.76 s vs 4.57 s)** —
   is real but secondary to tool fidelity, and is per-tier either way.

### Recommended target architecture (post-bake-off)

- **Keep oMLX as the engine.** Adopt the **all-co-resident, pinned, no-swap**
  lineup so the multi-model bug surface is never exercised; disable DFlash SSD
  cache (#702/#1892). Warm/pin every tier at startup.
- **Lineup (Flavor 1, ~70 GB, fits with KV headroom):** T1 `coding-fast`
  Qwen3-Coder-30B-A3B-8bit (current) · T2 GLM-4.7-Flash-8bit · T3
  DeepSeek-Coder-V2-Lite-8bit. All `is_pinned: true`.
- **If a stronger T3 is wanted (Qwen3-Coder-Next, 70.6% SWE-bench):** it does
  **not** co-reside with T1+T2 plus KV headroom (~96 GB), so run it **on-demand**
  (oMLX lazy-load, measured 15.9 s) with T1/T2 pinned. oMLX is the *only* engine
  tested that serves its tool-calls correctly — a decisive point for this model.
- **Router stays runtime-agnostic** regardless (the §2.4 lock-in point holds):
  keep the .NET router pointed at one endpoint so the engine remains swappable if
  oMLX's swap-path bugs ever block a future need.
- **mlx_lm.server + llama-swap remains the documented fallback** if oMLX's
  single-instance batching proves insufficient under real load — but only for
  models whose tool format mlx_lm.server parses (verify per model).

### Residual verifications before finalizing the lineup

- **Tool-call fidelity of GLM-4.7-Flash and DeepSeek-Coder-V2-Lite** on the chosen
  engine (not yet downloaded/tested) — mlx_lm.server's gap shows tool parsing is
  per-model; oMLX likely fine but confirm.
- **All-three-co-resident memory + KV headroom under real 16-way load** (we
  measured single models; co-resident peak under concurrency is untested).
- Whether to pursue Qwen3-Coder-Next as on-demand T3 (accepts cold-start + bounded
  #1970 exposure) vs a co-resident-only lineup (no swap ever).

## Part 4 — T3 ("quality") tier selection (COMPLETE)

After the bake-off, the operator chose to keep GLM-4.7-Flash as T2 and **rethink
T3** (Qwen3-Coder-Next can't co-reside — 45 GB — so it becomes a separate
on-demand "max" tier, not T3). Three agents evaluated the best *co-resident* T3.

### Structural finding

**Every model that fits a 3-way co-resident budget on 128 GB is ~30B-class.** The
genuine fidelity *leap* (70–80B: Qwen3-Coder-Next, Kimi-Dev-72B) only exists as an
**on-demand** tier. So T3's value is not "bigger" — it must open a *non-redundant
capability niche* vs the two MoEs already present:

| | SWE-bench Verified | tool-seq (tau²) | IFEval | hallucination |
|---|---|---|---|---|
| T1 Qwen3-Coder-30B-A3B (MoE) | 51.6% | 49.0% | 88.9% | 21% |
| T2 GLM-4.7-Flash (MoE) | 59.2% | 79.5% | — | 6% |

T1 (instruction fidelity / long-context) and T2 (agentic SWE / tool sequencing)
already span the two axes available at ~3B-active MoE class. A third MoE coder is
**redundant**. The differentiator must be **architecture (dense) + objective
(agentic-SWE fine-tune)**.

### Two corrections from the memory agent (carry into ADR-006)

- **KV starvation is not the constraint** at 3-agent scale: Qwen3-Coder-30B-A3B is
  GQA, ~112 KB/token → 3 agents @ 8K ≈ 2.6 GB. Even with T3 resident, headroom
  supports ~21 concurrent 8K agents. The real fence is the **96 GB Metal wired
  ceiling** (`iogpu.wired_limit_mb=98304`) — above it, hard `MTLCommandBuffer`
  failure, not slow degradation. So `T1+T2+T3+Next` (~116 GB) is *physically
  impossible*, not merely slow.
- **The "soft co-load Next alongside T1" path is a trap, not an affordance** — it
  forces T2↔Next yo-yo eviction (oMLX #1938) and the 15.9 s load is I/O-bound
  regardless. **Next is on-demand either way**, so T3's only real cost is its
  ~14 GB weight budget. Earlier framing (T3 vs "Next ergonomics") was wrong.

### Reasoning-tuned T3 is REJECTED (strong evidence)

A thinking/reasoning model (QwQ-32B, GLM-Z1, R1-distill, Qwen3-32B thinking) is the
**wrong** T3 for an agentic hot path. Deep research across vLLM/Ollama/LM Studio:
Qwen3-32B thinking mode showed **~60% tool-call failure** (plans the call inside
`<think>`, never emits it, sometimes *fabricates* it); `/no_think` is unreliable
and placement-sensitive; the hard `enable_thinking=False` conflicts with reasoning
parsers in some stacks; renderer bugs leave unclosed `</think>` corrupting
multi-turn; Qwen3.5 dropped the soft switch entirely. Reasoning belongs (if at all)
in the on-demand max tier, not a co-resident agentic tier.

### T3 decision

**Primary T3: `Devstral-Small-2507` (4-bit MLX).** Verified
`MistralForCausalLM`, **text-only** (no `vision_config` — distinct from the
multimodal Mistral-Small-3.2), 131K context; MLX builds
`mlx-community/Devstral-Small-2507-4bit` (~13–14 GB) and `-8bit`, plus
`lmstudio-community/Devstral-Small-2507-MLX-4bit`. Purpose-built **agentic SWE**
(~68% SWE-bench Verified — ~9 pts over GLM-Flash), **dense 24B** (different
decode/coherence profile from the two MoEs). It is the one ~30B-class model that
opens a non-redundant niche. Route ~7–10 % of traffic (multi-file refactors,
test-driven iteration, hardest single-shot) to it.

**Alternate T3: `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`** (18.4 GB,
`Qwen2ForCausalLM`, text-only verified, 128K). Use if Devstral's tool-call
fidelity on oMLX disappoints, or if a pure-coder profile is preferred over
agentic-SWE specialization.

**If T3 were any other ~30B MoE coder → drop T3** (run T1+T2 + on-demand Next):
redundant capability, and same-class routing collapses toward T1 without a trained
complexity classifier.

### Recommended final lineup (post-research, pending residual verification)

| Tier | Model | Quant | ~Resident | Role / traffic |
|---|---|---|---|---|
| T1 fast | Qwen3-Coder-30B-A3B-Instruct-MLX-8bit (current) | 8-bit | 30.6 GB | general coding, tool chains (~55%) |
| T2 medium | GLM-4.7-Flash | 8-bit | ~21 GB | fast tool relay / agentic (~30%) |
| T3 quality | **Devstral-Small-2507** | 4-bit | ~14 GB | hardest agentic-SWE (~7–10%) |
| — co-resident, all `is_pinned`, no swap | | | **~66 GB** | ~24–30 GB KV headroom |
| Max (on-demand) | Qwen3-Coder-Next-MLX-4bit | 4-bit | 45 GB | architectural / very-long-context / hardest (~8%); oMLX-only tool fidelity; ~16 s cold start |

### Agent Efficacy Report (Part 4)

| Agent | Type | Key contribution | Value |
|---|---|---|---|
| Best co-resident T3 coder | general-purpose | Surfaced Qwen2.5-Coder-32B-4bit (dense, verified text-only) as the safe coder T3; disqualified DeepSeek-Lite (MoE, redundant) | High |
| Is a 3rd tier worth it? | general-purpose | Reframed T3 as a capability (not memory) question; identified Devstral Small as the only non-redundant niche; corrected KV + Next-co-load errors | High (changed the answer) |
| Reasoning-tuned T3 | general-purpose | Decisive evidence that thinking-mode breaks agentic tool-calling → reject reasoning T3 | High |

**Disagreement:** coder agent → Qwen2.5-Coder-32B; worth-it agent → Devstral Small.
**Resolved** by the orchestrator: Devstral verified text-only + MLX-available +
higher agentic-SWE → **primary**; Qwen2.5-Coder-32B → **alternate**.
**Reliability note:** the reasoning-tuned agent **spawned its own sub-agents**
(a sub-agent-fan-out that violates the sub-agent obligation — orchestrator
visibility lost); its findings were source-cited and retained, but the behavior is
flagged. Several child searches hit transient API rate-limiting (high parallel
load).
**Custom-agent feedback:** no catalog agent covers local-LLM inference / MLX model
selection — a recurring gap across this whole investigation; a `local-llm-expert`
or `mlx-expert` agent would have replaced ~9 general-purpose invocations.

## Part 5 — Residual verification on oMLX (COMPLETE) — the lineup changed

Run 2026-06-23/24 on the M5 Max, oMLX v0.4.4. Downloaded GLM-4.7-Flash-8bit,
Devstral-Small-2507-4bit, then Qwen2.5-Coder-32B-Instruct-4bit. **Verify-first paid
off again — it overturned the Part 4 T3 pick.**

### Tool-call fidelity on oMLX (the decisive gate)

| Model | Role | Tool-call on oMLX | Note |
|---|---|---|---|
| Qwen3-Coder-30B-A3B-8bit | T1 | **PASS ✓** | (Phase A) |
| GLM-4.7-Flash-8bit | T2 | **PASS ✓** | clean `{"city":"Paris"}` |
| Qwen3-Coder-Next-4bit | Max (on-demand) | **PASS ✓** | (Phase B) |
| **Devstral-Small-2507-4bit** | T3 cand. | **FAIL ✗** | emits no parseable call; *even `tool_choice=required` ignored* (Mistral protocol not wired in oMLX) |
| **Qwen2.5-Coder-32B-4bit** | T3 cand. (alt) | **FAIL ✗** | emits the call but wraps it in `<tools>…</tools>` not `<tool_call>…</tool_call>` → oMLX parser drops it |

**Conclusion: no co-resident dense ~30B T3 candidate has clean tool-calling on
oMLX.** Both fail, for different reasons. Combined with the late reasoning-T3
research (Qwen2.5-Coder is weak at *multi-turn agentic* editing — Aider-polyglot
~8–16% — and Qwen3-32B/reasoning models carry their own tool-parser bugs +
thinking-interference), there is **no compelling, tool-clean, co-resident dense
T3** today.

### Other measured facts

- **GLM-4.7-Flash-8bit is ~30 GB on disk/resident, not the ~21 GB estimated** in
  Parts 3–4. Corrects the co-resident budget.
- **Co-resident T1+T2 under 16-way load: 16/16 PASS** (7.58 s wall). Memory released
  cleanly on stop.
- Model discovery requires an oMLX **restart** to pick up newly-downloaded dirs
  (it scans at boot; a model added after start returns `not_found` until restart).

### REVISED FINAL LINEUP (all tool-paths verified on oMLX)

Drop the co-resident dense T3. Ship **2 co-resident + 1 on-demand = 3 tiers**:

| Tier | Model | Quant | ~Resident | Tools on oMLX | Role |
|---|---|---|---|---|---|
| T1 fast | Qwen3-Coder-30B-A3B-Instruct-MLX-8bit *(current)* | 8-bit | 30.6 GB | ✓ | general coding (~55%) |
| T2 medium | GLM-4.7-Flash-8bit | 8-bit | ~30 GB | ✓ | fast tool relay / agentic; best tool-seq (~30–35%) |
| — co-resident, both `is_pinned`, no swap | | | **~61 GB** | | ~29 GB KV headroom |
| Max (on-demand) | Qwen3-Coder-Next-MLX-4bit | 4-bit | 45 GB | ✓ | high-fidelity (70.6% SWE-bench); ~16 s lazy load (~10%) |

This satisfies "3+ tiers, fidelity-by-workload" (fast → tool-relay → high-fidelity
on demand), keeps every tool path verified-working, never swaps in steady state
(so oMLX's multi-model bugs never fire), and leaves generous KV headroom. **Add a
co-resident dense T3 later only when a ~30B model ships that is both strong at
agentic editing AND tool-clean on oMLX** (re-open this section then).

### Unused downloads

`Devstral-Small-2507-4bit` (12 GB) and `Qwen2.5-Coder-32B-Instruct-4bit` (17 GB)
were verification-only and are not in the final lineup — candidates for deletion
from `~/models` (operator's call; not removed automatically).

### Possible future unblock (not pursued)

Qwen2.5-Coder-32B *can* emit correct tool JSON — only the wrapper tag differs.
If oMLX exposes a per-model tool-parser override for the `<tools>` dialect, it
could be revived; deemed not worth the per-model fragility vs the clean on-demand
Next tier.

## Part 6 — Would leaving oMLX unlock more capable models? (COMPLETE)

Operator question: is the text-only constraint (which excludes the newest/biggest
models via the VLM trap) an *oMLX* limitation that a runtime switch would lift,
netting more capable models? Three agents + a direct issue-tracker check.

### Finding A — the VLM trap IS oMLX-specific (switch is mechanically possible)

oMLX #1800 (`cache_offset` scalar/array crash) routes any `vision_config` model to
a VLM engine that crashes on concurrent requests. Other runtimes avoid it:

- **llama.cpp / llama-server** — vision is a *separate* `mmproj` GGUF; load the text
  GGUF *without* `--mmproj` (or `--language-model-only`) and the VLM path **cannot
  execute**. Native continuous batching at `--parallel 16`. Doesn't use `mlx-vlm`
  at all → immune to that whole bug class. Cost: **no M5 Neural Accelerators
  (~1.5× slower prefill)**, sublinear batch scaling.
- **vllm-mlx / vllm-metal** — routes on *image-token presence*, not arch flag;
  benchmarked **4.3× at 16 concurrent (M4 Max 128 GB)**. Younger stack.
- **mlx_lm.server** — no (no continuous batching). **LM Studio** — partial (~4 cap).

### Finding B — the trapped models are NOT better coders (no capability prize)

| Model (status) | SWE-bench Verified | vs our stack |
|---|---|---|
| Qwen3-Coder-Next-80B-A3B *(ours, on-demand)* | **70.6–71.3%** | — |
| Qwen3-Coder-30B-A3B *(ours, T1)* | ~69.6% | — |
| Gemma-3-27B *(trapped)* | ~29% LiveCodeBench (½ of ours) | **catastrophic downgrade** |
| Mistral-Small-3.2-24B *(trapped)* | none published (general VLM) | worse; its coder sibling Devstral 68% still < ours |
| Qwen3.6-35B-A3B *(trapped)* | 73.4% **on Alibaba's non-standard scaffold** | normalizes to ~within-noise of ours (same 3B-active arch); **not a real upgrade** |

### Finding C — the real ceiling is the 128 GB hardware, not the trap

The genuinely stronger coders are **size-gated**, which no runtime fixes:
Devstral-2-123B (72.2%, borderline-impossible at useful ctx), Qwen3-Coder-480B
(~276 GB), GLM-4.7-full 358B (73.8%), DeepSeek-V3 (~380 GB). The best coders that
*fit* are **already text-only and usable** (Qwen3-Coder-Next is the ~71% ceiling).

### Fix status of the crash (#1800), checked directly

- Upstream root-cause fix **`mlx-vlm` PR #1354 is MERGED** (2026-06-12).
- **oMLX has NOT adopted it** — #1800 still open (stale 2026-06-11), zero oMLX PRs
  reference it; oMLX must bump its vendored `mlx-vlm`, not in flight.
- The `mlx-vlm` continuous-batching VLM path has **more open crashes** (#1422 MRoPE,
  updated 2026-06-24; #1378 token_context desync) — not a single clean fix.

### VERDICT — stay on oMLX

Switching runtimes is *possible* but buys **essentially no coding capability**: the
trapped models aren't better coders, and the genuinely-stronger ones are size-gated.
The only prize is quality-of-life (running Qwen3.6-35B-A3B text-only, ~within-noise
of what we have), paid for with the **MLX/M5-NPU speed advantage** and re-verifying
per-model tool-calling on a new engine. **The capability ceiling is the hardware,
not oMLX.** Keep oMLX with the verified text-only lineup.

**Revisit trigger (concrete):** re-evaluate multimodal models only if oMLX ships a
release that bumps `mlx-vlm` past #1354 **and** the remaining batching bugs (#1422,
#1378) close — then re-run the concurrency probe. Independently, **llama.cpp
text-only** remains a fallback path that sidesteps the trap now, if a future need
demands a specific multimodal-only model.

### Flagged unverified conflict

Agent #2 referenced a *text-only* "Qwen3.6-27B dense (72–77%)", contradicting the
earlier config-verified finding that the whole Qwen3.6 family is multimodal
(`Qwen3_5ForConditionalGeneration`, vision_config). Treated as **unverified**; not
pursued (it normalizes to ~within-noise regardless, so not decision-relevant).
Verify the actual `config.json` before ever relying on it.

### Agent Efficacy Report (Part 6)

| Agent | Type | Key contribution | Value |
|---|---|---|---|
| VLM-trap runtime-specificity | general-purpose | Proved trap is oMLX-specific; llama.cpp (no-mmproj) + vllm-mlx unlock text-only concurrency; mlx_lm.server/LM Studio insufficient | High |
| Trapped-models-better-coders | general-purpose | Quantified that trapped models are worse/equal coders (Gemma-3 ~29% LCB; Qwen3.6 scaffold-inflated) | High |
| Trap-gated vs size-gated | general-purpose | Bucketed the field; showed best coders are already-usable or size-gated → ceiling is hardware | High |
| (direct issue-tracker check) | orchestrator | #1800 open/unadopted; #1354 merged upstream; #1422/#1378 still open | High |

**Disagreement:** none material — all three converged on "stay." Minor: agent #2's
unverified text-only-Qwen3.6-27B claim (flagged above). **No sub-agent fan-out this
round** (instructed against it; the earlier protocol drift did not recur).

## Open decisions (to be resolved into ADR-006)

- **Runtime:** keep oMLX (with guardrails) / switch / hedge with a
  runtime-agnostic router. → Part 2.
- **Tier topology:** all-co-resident (no swap) vs co-resident hot + lazy-load
  large vs hybrid local + remote top tier.
- **Top-tier quality ceiling:** strong MoE (co-resident) vs genuine large dense
  (swap/remote).
- **Model lineup + exact HF repo IDs + quants** (re-verify availability per
  CLAUDE.md before any download).

## Sources

- oMLX: `github.com/jundot/omlx` (README, `engine_pool.py`, `server.py`,
  `model_settings.py`, `model_registry.py`, issues #1970/#1938/#514/#702/#1892/#1800),
  `omlx.ai`.
- MLX on M5 / load + memory figures: Apple ML Research (Exploring LLMs with MLX on
  M5), ThinkSmart.Life MLX guide, llmcheck.net Apple-Silicon benchmarks.
- Prior decision context: [ADR-001](../adrs/001-local-mlx-inference-omlx.md) →
  [ADR-004](../adrs/004-single-text-only-model-no-override.md),
  [ADR-005](../adrs/005-on-demand-service-lifecycle.md),
  [docs/router-wiring.md](router-wiring.md).
