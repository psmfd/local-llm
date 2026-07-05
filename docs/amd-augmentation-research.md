# AMD appliance as augmentation — research note (2026-07-05)

Research behind the (proposed, not yet ratified) reopening of the AMD host as a
**secondary augmentation** to the Mac workhorse — explicitly *not* a revival of
[ADR-008](../adrs/008-cross-host-routing-integration.md)'s retired co-equal-peer
routing, and not a local quality tier (the cloud frontier from
[ADR-009](../adrs/009-mac-single-workhorse-cloud-frontier.md) is unchanged). If
the direction is ratified, the decision record will be a new ADR in this repo
(ADR-011-class, amending ADR-009's fallback framing) with the host build itself
in the separate `amd-inference` repo, per the ratified repo split.

**Method:** 3-agent divergence fan-out (2026-07-05) — Mac/architecture-side
analysis, AMD/vLLM-ROCm hardware-fit analysis against current first-party docs,
and a landscape survey of two-host augmentation patterns. All three returned
COMPLETE; disagreements and their resolution are recorded below.

**The AMD host (settled stack, build pending):** Ryzen 9 9950X, RX 7900 XTX
24 GB (gfx1100, RDNA3, ~960 GB/s), 128 GB DDR5, Ubuntu 24.04.4, vLLM ROCm in a
digest-pinned container, always-on, dual 10 GbE, LAN-only + API key. Known dead
ends (documented 2026-06, do not re-derive): iGPU compute, `--cpu-offload-gb`
weight offload (~85% collapse), cross-host KV/LMCache transfer (CUDA/MI300-
gated), a second co-resident model. One resident model; **compute throughput,
not VRAM, is the binding limit**.

## Ranked role map

### 1. Eval/CI farm — deploy first (unanimous #1)

Nightly/scheduled evals against the box's vLLM OpenAI-compatible endpoint,
turning [ADR-010](../adrs/010-6bit-workhorse-sustained-mark.md)'s manual
model-gating pattern (tool-call battery + HumanEval A/B) into an always-on
pipeline that never competes with the Mac's production fan-out.

- **BFCL** (Berkeley Function Calling Leaderboard, `gorilla` repo) supports
  pointing at a pre-existing self-hosted endpoint first-party:
  `--skip-server-setup` + `LOCAL_SERVER_ENDPOINT`/`LOCAL_SERVER_PORT` (or
  `REMOTE_OPENAI_BASE_URL`/`REMOTE_OPENAI_API_KEY`). Active; hardware-agnostic.
- **lm-evaluation-harness** (EleutherAI, v0.4.12 2026-05-11, Active) has a
  first-party vLLM backend — but its docs never mention ROCm; the combination
  rides entirely on vLLM's ROCm backend working underneath (Low-Medium risk;
  you discover breakage first).
- **Scope correction (load-bearing):** an eval result on a GPTQ/AWQ quant
  through vLLM/ROCm pre-screens the *base model/architecture*, it does **not**
  validate the Mac's MLX artifact — quant method and kernel/attention stack
  both differ. Every probe in [workhorse-probes.md](workhorse-probes.md)
  (MLA compression, `enable_thinking`, sustained mark, Neural Accelerator)
  is Metal/MLX/oMLX-specific and stays **Mac-mandatory** before promotion.
  The farm gates candidates *destined for vLLM* directly, and pre-screens
  base models for the Mac; it never replaces on-host validation.

Zero production-routing exposure — no split-brain or topology risk.

### 2. Overflow lane — second step, real but gated

A third `IInferenceBackend` registered **between** the Mac workhorse and the
cloud frontier in the existing fast/balanced chain. The router architecture in
[router-wiring.md](router-wiring.md) (typed `InferenceUnavailableException`,
registration-order-as-priority, guard-reject-400-as-capacity-signal) already
supports this shape — the addition is a registration, not new architecture.
Three guardrails are preconditions, not suggestions:

1. **Model = Qwen3-Coder-30B-A3B Q4 (AWQ/GPTQ) — NOT GLM-4.7-Flash.**
   The same-family-symmetry idea is disqualified on this GPU (see below).
   Qwen3-Coder-30B-A3B is standard GQA (prefix-caches under vLLM APC), has
   current W4A16/AWQ/GPTQ quants (~17 GB) with native RDNA3 W4A16 fused-MoE
   HIP kernels, and is already this project's vetted on-disk fallback family —
   its tool-call behavior is known here.
2. **Trigger ONLY on the exact `prefill memory guard rejected` HTTP-400 —
   never on Mac-unreachable.** A Mac that is asleep/unreachable keeps falling
   through to the cloud, as today. Failing over to AMD on unreachability would
   make the always-on box the de facto primary whenever the laptop lid is
   closed — silently reconstituting ADR-008's retired peer topology through a
   back door. This distinction must be explicit in any implementing ADR/code.
3. **Justify with observed demand.** Under single-orchestrator discipline
   capped at the ADR-010 mark (N=8), saturation should be rare and the
   existing queue-then-cloud path covers it at zero cost. The lane earns its
   operational weight (second host to patch/monitor/version-sync) only for
   bursty multi-session use — a second orchestrator, ad hoc eval traffic,
   uncoordinated callers.

**Capacity expectation:** roughly **4–8 extra concurrent agents** at
reasonable latency (`--max-num-seqs 16` ceiling; ~17–20 GB model + ~6–7 GB KV
in 24 GB; gfx1100 has no native flash attention and roughly a third to half
the matmul throughput of datacenter CDNA3 parts). No first-party benchmark
exists for this exact model+GPU+APC shape — **measure on the real box before
sizing anything on it.** vLLM's own saturation signal (429/queueing) differs
from oMLX's 400 marker; the AMD backend adapter needs its own detector.

### 3. Embedding/reranking sidecar — deferred, not dropped

- **Infinity** (`michaelfeil/infinity`) is the right server for this card: a
  genuinely published gfx1100 image exists
  (`michaelf34/infinity:0.0.70-amd-gfx1100`, named in Hugging Face's own
  Infinity-on-AMD blog post). Verify the tag isn't stale relative to the
  project's latest release before adoption (last release v0.0.77, 2025-08;
  Active-to-Maintenance, Low-Medium risk; RDNA3 throughput undocumented).
- **TEI** (Hugging Face text-embeddings-inference) has **no gfx1100 path at
  all** — ROCm support is experimental and Instinct-only; the ROCm PR sat
  unmerged 10+ months. Do not plan around it (High risk for this card).
- **Co-residency is a deliberate trade, not a bonus:** vLLM's
  `--gpu-memory-utilization 0.95` claims nearly all VRAM at startup; carving
  out an embedding process means dropping to ~0.85–0.88, which cuts directly
  into the overflow model's KV/concurrency budget. Two independent processes
  with manual VRAM budgeting is how people actually run this, but it is not a
  vLLM-blessed multi-tenant feature — any conflict is a config bug you own.
- **Deferred because no such workload exists in this architecture today** —
  there is no RAG/search/embeddings consumer in the current design. Classify
  when a retrieval layer is actually designed; model it then as a new distinct
  role, not a reroute of fast/balanced.

### 4. Async batch lane — opportunistic only

vLLM ships priority scheduling (`--scheduling-policy priority`), but a
high-priority *waiting* request still cannot preempt a running batch job when
`max_num_seqs` (not memory) is the binding constraint — open gap
vllm-project/vllm#40004; the fuller SLA-tier design (#30256) is RFC-stage.
Low-priority summarization/triage jobs can fill idle capacity under the same
resident model, but do not promise interactive/batch isolation until those
land. Re-check both issues before designing anything on top.

## GLM-4.7-Flash on gfx1100: disqualified (do not re-derive)

The intuitive "run the same model family as the Mac so tool-call semantics
match" option fails at the hardware layer, on first-party evidence:

- `zai-org/GLM-4.7-Flash` is genuine DeepSeek-style **MLA**
  (`q_lora_rank=768`, `kv_lora_rank=512` per the HF config) — not GQA.
- vLLM's MLA backends (`TRITON_MLA`, `ROCM_AITER_MLA`,
  `ROCM_AITER_TRITON_MLA`) are documented **CDNA3-only** (MI300-class) in
  vLLM's Feb-2026 ROCm attention-backend post; gfx1100 is absent from the
  hardware table entirely.
- GLM-4.7-Flash support needs vLLM main/nightly + transformers built from git
  (vllm-project/vllm#34098 — `glm4_moe_lite` in no transformers PyPI release),
  incompatible with the settled digest-pinned-container requirement.
- The failure mode when MLA is not engaged is the **~17× KV blowup** this
  project already dodged once on the Mac (workhorse-probes.md probe 1 exists
  because of it), independently reproduced elsewhere on AMD fallback paths.

vLLM's first-party `--tool-call-parser glm47` / `--reasoning-parser glm45`
flags exist — parser support upstream does not make the model runnable on this
card. Accepting Qwen's different prompt format on the overflow lane is the
correct trade.

## Rejected patterns (datacenter-only or unestablished)

Prefill/decode (P/D) disaggregation, llm-d, and NVIDIA Dynamo are real and
shipping — and every first-party deployment example is multi-GPU/multi-node
(H200/A100/MI300X pools, NVLink/InfiniBand KV transport). Nothing supports
splitting one consumer 24 GB card's phases across hosts; Dynamo is
NVIDIA-specific besides. Cross-host speculative decoding surfaced no
first-party shipped pattern anywhere. All stay off the table, consistent with
the already-retired KV-transfer/offload dead ends.

## Operational facts for the eventual build (regardless of role)

- **Image family migration:** AMD's `rocm/vllm`/`rocm/vllm-dev` images are
  being deprecated in favor of upstream **`vllm/vllm-openai-rocm`** — digest-pin
  from the new family; re-verify which family the old "avoid
  `rocm7.0.0_vllm_0.11.1`" caveat targets.
- **Flash attention regressed:** gfx1100 was promoted out of AOTRITON's
  experimental tier and later moved **back** into it. Keep
  `VLLM_USE_TRITON_FLASH_ATTN=0` as the pinned default; re-test per image bump.
- **`/v1/messages`:** shipped in current vLLM (old issue #21313 resolved) but
  with live bugs (multi-turn tool-calling crashes on some models; message-role
  validation vs newer Anthropic-client roles) — a tool-calling re-test on the
  pinned image is required, not just an existence check.
- **ROCm/Ubuntu pairing:** ROCm 7.2.1 supports Ubuntu 24.04.4 (24.04.3 hit
  EoS) — AMD deprecates per micro-release; re-check the pairing at every ROCm
  bump.
- Carried forward unchanged: `VLLM_ROCM_USE_AITER=1`, disable chunked prefill
  with APC, byte-identical system prefixes for APC hits, N-gram spec-dec as the
  only safe speculative variant, `ROCR_VISIBLE_DEVICES` iGPU isolation.

## Fan-out disagreements and resolution

1. **Overflow ranking.** The landscape survey ranked overflow #2 on
   implementation cost ("the router already supports it"); the Mac-side
   analysis ranked it last on realized value ("rare under orchestrator
   discipline") and design risk. Both correct on their own axis — adopted at
   #2 *with* the Mac-side guardrails as hard preconditions.
2. **GLM on vLLM.** The landscape survey called it "technically supported"
   (parsers exist upstream); the AMD hardware analysis disqualified it at the
   MLA/CDNA3 layer. The deeper hardware evidence wins — recorded above as a
   settled disqualification.

Two agents independently converged on Qwen3-Coder-30B-A3B for the overflow
slot from unrelated arguments (cross-model tool-call risk minimization on the
Mac side; MLA hardware gate on the AMD side) — treated as a strong signal.

## Status and next step

Assessment only — nothing here is implemented or ratified. Next step when the
direction is confirmed: an ADR in this repo amending ADR-009 (roles ranked as
above; the **Mac-saturated vs Mac-asleep** router distinction stated
explicitly; operational cost quantified against observed overflow demand),
cross-referencing the separate `amd-inference` repo's own ADR for host-build
specifics. The AMD hardware build itself remains pending.
