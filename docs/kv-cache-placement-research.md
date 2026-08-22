# KV-cache placement — research note (2026-08-22)

Research answering the owner's question: *can the KV cache be put "elsewhere" in
either/both the AMD and Mac setups — including dedicating the AMD host to that
purpose?* Assessment only; nothing here is implemented or ratified, and no
serving flag changes. The current serving boundaries
([ADR-011](../adrs/011-pi-context-window-guard-boundary.md),
[ADR-012](../adrs/012-concurrency-mark-4-large-context.md)) and the AMD role
map ([amd-augmentation-research.md](amd-augmentation-research.md)) stand; this
note adds two scope refinements to the latter (recorded below).

**Method:** 3-agent divergence fan-out (2026-08-22) — Apple-Silicon placement
physics against this repo's measured constants, AMD/ROCm KV-offload landscape
against current first-party sources, and an oMLX-runtime capability survey at
the pinned 0.5.7. Verification caveat: several first-party domains
(apple.com, huggingface.co, docs.vllm.ai, LMCache blog) were egress-blocked to
the research session — claims from them are search-mediated and marked as such
where load-bearing; GitHub sources (vLLM, llama.cpp, mlx-lm, jundot/omlx
releases/issues, ROCm AIC) were fetched directly.

## The question splits in two

1. **KV for the Mac's engine, held elsewhere (the AMD box as a KV host).**
   Not implementable — dead on physics for active KV, dead on software and
   representation for inactive KV, re-verified against 2026-08 sources. The
   2026-06 dead-end note in
   [amd-augmentation-research.md](amd-augmentation-research.md) is confirmed
   and strengthened, not relaxed.
2. **Each host's own KV, placed/retained differently within that host.** Real
   levers exist on both machines. On the Mac they are hot-cache ↔ guard
   rebalancing and SSD-tier sizing/location — tuning of tiers that already
   exist. On the AMD box (when built) they are prefix-retention extensions to
   its own overflow lane. Every lever is gated on an on-host measurement
   listed at the end.

## Why active KV cannot leave the serving host (settled physics)

Decode re-reads the KV of the entire context for every generated token. For
GLM-4.7-Flash's MLA-compressed cache the theoretical floor is ~53 KB/token
(47 layers × 576 latent+RoPE elements × bf16), so a 30K-token stream re-reads
**≥1.6 GB per generated token** — and by the guard-accounted density this repo
actually measures (0.36–0.44 GB per 1K tokens, ADR-011 / probes 0.5.7), the
working set is ~11–13 GB. M5 Max unified memory sustains ~614 GB/s (40-core
GPU config); 10 GbE is 1.25 GB/s and Thunderbolt 5 ~10 GB/s raw. Even at the
theoretical floor, 10 GbE caps decode **below 1 tok/s**; against the measured
density the gap is **~550–1,250× for 10 GbE and ~60–120× for TB5-class
links** — before adding the per-layer round-trip latency a 47-layer serial
forward pass would stack on top. No shipped engine reads attention operands
from another host's address space mid-kernel; even production disaggregated-KV
systems (Mooncake, FAST'25) move KV **only at prefill/decode phase
boundaries**, always landing blocks in the executing node's local memory
first. The active-KV pool, and therefore the admission arithmetic of
ADR-011/012, is placement-bound to the Mac. No placement scheme changes it.

## The inversion worth recording: bandwidth was never the blocker

For **inactive** prefix KV (the paged-out prefixes the SSD tier already
holds), restore-vs-recompute economics run the other way, and the result is
counterintuitive enough to write down. Recompute cost grows superlinearly
(~N^1.9 by fit to the 0.5.7 ladder: 45.5K → 78 s, 63.2K → 146 s) while
restore volume grows linearly, so the break-even restore bandwidth **falls**
as prefixes grow:

| Prefix | Recompute (0.5.7 ladder) | Restore volume (0.36–0.44 GB/1K) | Break-even bandwidth |
| --- | --- | --- | --- |
| 16K | ~12 s | 5.8–7.0 GB | ~0.48–0.59 GB/s |
| 45K | ~78 s | 16.2–19.8 GB | ~0.21–0.25 GB/s |
| 76K | ~200–230 s (clean-trend est.) | 27.4–33.4 GB | ~0.12–0.17 GB/s |

Internal NVMe (~5–8 GB/s), TB5 external NVMe (~5–6 GB/s good-enclosure
real-world), 10 GbE (~0.6–1.1 GB/s realistic), even 2.5 GbE at 45K+ — all
clear the break-even. Longer prefixes are *easier* to justify restoring, not
harder. (The volumes above use the conservative guard-accounted density; the
on-disk block payload is closer to the ~53 KB/token latent floor, which only
widens the margin. The ~4–7× gap between the two figures — presumed SDPA
scratch plus allocator/guard headroom — is unreconciled; flag it before
reusing this arithmetic elsewhere.)

**So the cross-host idea fails on software and representation, not physics:**

- **oMLX 0.5.7 has no remote tier, KV connector, or disaggregated mode** —
  nothing to point at a second host. The closest upstream feature, 0.6.0+
  "distributed serving," is whole-model tensor/pipeline **sharding** across
  Macs (each rank keeps its own local cache for its own layers), experimental,
  off by default, post-pin, and structurally in conflict with ADR-009's
  single-pinned-model architecture. Not a cache-placement feature.
- **The AMD side is CDNA-gated at every layer, re-verified 2026-08.** AMD's
  own newest KV-tiering product — ROCm AIC (`ROCm/rocm-aic`, released
  2026-07-22, early-access) — targets `gfx90a;gfx942;gfx950` only and
  integrates only with a patched vLLM. LMCache's AMD validation remains 100%
  MI300X across eight months of AMD-focused posts; vLLM's NixlConnector is
  vLLM-prefiller↔vLLM-decoder only; Mooncake's cross-node AMD transport is
  roadmap, not shipped. gfx1100 appears in none of them.
- **Representation is the deepest blocker.** No cross-engine KV interchange
  format exists (no "GGUF for KV"): vLLM's PagedAttention block layout and
  MLX's safetensors-blob cache have nothing in common, so there is nothing the
  Mac could ingest even over an infinite pipe — and gfx1100 cannot run
  GLM-4.7-Flash at all (MLA backends are CDNA3-only, per the existing
  disqualification), so the AMD box cannot *produce* compatible bytes either.

## Mac: the real levers, ranked

The Mac already has "KV elsewhere" — the paged SSD tier is exactly that, for
the only KV that can move (inactive prefixes). The levers are about sizing and
balance, and none is urgent: the 0.5.7 re-baseline widened every margin
(fresh-idle acceptance ≥91K, mark-4 waves 16/16 clean).

1. **Do nothing (current default).** The config is already at a measured
   operating point with margin. Act only on observed retention pressure:
   cache-evict/`adaptive_prefill_throttle` lines under normal load, or a
   falling lifetime prefix-hit rate (ADR-012 cites ~91%).
2. **Hot-cache ↔ guard rebalance.** The 24 GB hot tier's retained blocks
   count into the guard's "current," directly shrinking the admission
   boundary ADR-011 is built on — repo-measured: the 0.5.3 ladder inflated
   "current" 30 → 53.17 GB (effective boundary ~45K); 0.5.7's reclaim fixes
   improved the hot-cache-loaded boundary to **≥69.9K**, which still only
   *just* covers ADR-011's ~69K worst-case prefill under long uptimes.
   Shrinking the hot tier pushes retention to the SSD tier at a bounded
   warm-hit cost — this repo measured 16K warm ≈ 7 s vs cold ≈ 24.6 s
   (0.4.4-era; 0.5.7 prefill is ~2× faster, narrowing the margin), and
   upstream 0.5.1 notes show a 57K-token SSD-tier warm hit at 7.1 s vs 45.4 s
   cold. oMLX publishes no tier-isolated benchmark, so probe H1 below decides
   the split before any flag change.
3. **Grow the SSD tier, or move it to a dedicated external TB5 NVMe.** The
   50 GB cap was a free-disk-budget choice, not a performance one; an
   external volume escapes that budget entirely, and even a thermally
   throttled enclosure (~0.8 GB/s worst documented) clears every break-even
   above. Conditions that make this sane: a reviewed all-metal/thermal-pad
   enclosure, system sleep disabled on the serving Mac, and the ADR-005
   on-demand lifecycle (operator verifies the mount before `omlxctl start` —
   no boot race). Costs and open risks: macOS external-drive sleep/eject
   flakiness is a live, unfixed bug class (an unmount under a running server
   is an EIO/wedge, which internal storage structurally cannot do); #702
   means the guard neither charges nor protects any of this memory (an
   oversized tier's mmap/RSS footprint is jetsam exposure the guard will
   never see); every oMLX upgrade so far has re-keyed and partially
   invalidated the tier (0.5.1 upstream-documented, reproduced here at 0.5.3
   and 0.5.7 — a bigger tier means a bigger re-warm each bump); behavior when
   the tier hits its own size cap is undocumented (probe H2); and the
   #2624/#2647 stall/snapshot-blowup families plus the #1835 macOS-27 hold
   all live in this subsystem — any tier growth stays on macOS 26.x.
4. **Rejected: network-mounted cache dir (SMB/NFS to the AMD box).**
   Bandwidth clears the break-even, but the failure class is
   semantics: mmap/`fcntl`-locking over SMB/NFS is a decades-documented
   corruption and hang class (SQLite's guidance is the cleanest proxy), and a
   stale mount hangs the server in a way indistinguishable from the existing
   "prefilling hard vs wedged" diagnostic gap (probes 0.5.7 operational
   caveat). oMLX documents no support for it in either direction. Do not
   point `--paged-ssd-cache-dir` at a network mount.
5. **Rejected for this host: TurboQuant KV** (`turboquant_kv_enabled`,
   default false — the probes doc records it as `turboquant_kv_bits=None`).
   Three independent grounds: (a) it quantizes at first-decode, *after* the
   full-fp16 prefill peak the admission guard actually gates on, so it does
   not move the ADR-011 boundary (maintainer statement, dated ~0.3.x, never
   contradicted); (b) it is reportedly MLA-incompatible — enabling it on an
   MLA model raises `NotImplementedError` (unverified against source; probe
   H3 settles it in minutes) — and the algorithmic frontier corroborates the
   caution: upstream mlx-lm's mainline KV quantization structurally skips
   MLA-latent caches, its TurboQuant port is an unmerged MHA/GQA-scoped
   draft, and vLLM's production FP8-KV for MLA is deliberately surgical
   (RoPE slice kept bf16) with calibration warnings; (c) its history includes
   making the guard *more* wrong (#1763's ~4× KV overestimation and false
   rejects — fixed pre-0.5.7, but on-point precedent). Leave it off.

## AMD: what "dedicating the box" actually buys

**Not a KV annex for the Mac** — reading 1 above is dead. The box's
contribution to the Mac's KV economy is and remains **admission relief by
routing whole requests** (the overflow lane on the exact guard-reject 400),
i.e. route requests to where cache lives, never cache to requests. The ranked
role map (eval/CI farm first, overflow lane gated) is unchanged by this
research. Within the overflow lane's *own* vLLM instance, real KV-retention
levers exist when the box is built:

- **vLLM CPU KV-offload (`OffloadingConnector`) into the 128 GB DDR5** —
  extends *prefix retention* (evicted blocks survive in DRAM and DMA back on
  hit) but not the active batch ceiling, which stays VRAM-bound. Code
  inspection shows no CUDA-only gating, but **no published ROCm validation
  exists anywhere — this box would be the validation** — and the connector is
  young (a block-indexing crash at ~565+ concurrent prompts, far beyond this
  lane's 4–8). `--swap-space` is the older, better-worn CPU-staging tool for
  preemption bursts. Smoke both at bring-up (probe A1).
- **FP8 KV on gfx1100 is a refinement, not a flat no** (updates the
  carried-forward "bf16-only" fact): vLLM #13147 shows `fp8` KV **crashes
  specifically in combination with prefix caching** on gfx1100 — Triton there
  lacks `fp8e4nv`; only `fp8e5` codegen exists — and each flag alone runs.
  Since APC is load-bearing for the fan-out, bf16 KV remains the practical
  answer, but the cause is a fixable-looking dtype bug, not an architectural
  ceiling: explicitly requesting `fp8_e5m2` + APC is untested anywhere and is
  a minutes-long probe (A2). Watch #13147.
- **llama.cpp HIP is not the alternative for this lane.** It is *ahead* on
  KV compression (symmetric `q4_0`/`q8_0` cache types hit the fused
  flash-attention path on gfx1100; ~47% KV VRAM savings reported; plus
  `/slots` save/restore to disk) but its slot model holds an **exclusive KV
  copy per concurrent request** — `--cache-reuse` only recycles an *idle*
  slot's prefix — so N agents sharing one system prefix each pay full KV,
  versus one ref-counted copy under vLLM APC. For a prefix-heavy concurrent
  fan-out, vLLM stays architecturally correct.
- **Scope correction to record against the augmentation note's "compute
  throughput, not VRAM, is the binding limit":** true at the moderate
  contexts the 4–8-agent estimate assumed, false in the Mac's large-context
  regime. Qwen3-30B-A3B KV runs ~96 KB/token bf16; ~6.5 GB of VRAM headroom
  is a **~69K-token total concurrent pool**, so four 30K streams oversubscribe
  it ~1.7× — the ADR-012 incident shape at smaller numbers. Any overflow-lane
  implementation needs its own admission-count guardrail (an ADR-012 analog
  sized by the formula above), not just a capacity estimate.

## On-host probes before acting on any of this

Mac (any time):

1. **H1 — tier-split A/B:** re-run the ADR-011 ladder with
   `--hot-cache-max-size` minimized (forcing SSD-tier hits) vs the current
   24 GB; diff warm-hit wall time and the guard's "current" inflation. This
   prices lever 2 with one afternoon of data.
2. **H2 — SSD-cap behavior:** fill the SSD tier past
   `--paged-ssd-cache-max-size` and observe (LRU-evict vs refuse-writes vs
   worse) before any tier-growth plan trusts it.
3. **H3 — TurboQuant/MLA claim:** set `turboquant_kv_enabled` on the GLM pin
   via the admin API and observe the load-time error (expected
   `NotImplementedError`). Settles the reported incompatibility in minutes;
   revert immediately.

AMD (at overflow-lane bring-up, on the pinned image):

1. **A1 — offload smoke:** `OffloadingConnector` and `--swap-space` under the
   lane's real 4–8-stream shape; nobody has published a ROCm result.
2. **A2 — `fp8_e5m2` + APC probe:** explicit-dtype attempt against the
   #13147 crash; minutes to run, updates the bf16-only assumption if it
   passes.
3. **A3 — admission guardrail sizing:** measure the real KV pool and set the
   lane's `--max-num-seqs`/admission cap from it before any large-context
   traffic is routed.

## Status and next step

Assessment only. No ADR is warranted yet: nothing here amends a settled
decision — the two refinements above are recorded corrections to a research
note, and every actionable lever is measurement-gated. Triggers that would
promote this to an ADR: H1 measuring a hot-cache split materially better than
24 GB (amend the serving flags), observed SSD-tier retention pressure under
normal load (tier growth / external-NVMe decision), or the AMD overflow lane
being ratified (its implementing ADR should absorb A1–A3 and the admission
guardrail as preconditions alongside the existing three).
