# Workhorse probes — one-time on-host checks before trusting the config

Short probes to run once on the M5 Max after provisioning (and again after
any oMLX, macOS, or model update), closing the residual risks the ADR-009
review flagged. None is part of `--validate` — each needs a long prompt, a
model-behavior judgement, or a host-level measurement that the scripted checks
deliberately avoid.

> **Last run: 2026-07-02, oMLX 0.4.4 — both probes PASS.** Probe 1: baseline
> 30.0 GB resident; a 19,470-token prompt added +2.1 GB resident / +7.0 GB peak
> (MLA-class — an MHA fallback would have added ~18 GB), with 19,456/19,470
> tokens prefix-cache-hit on repeat. Probe 2: `enable_thinking:false` accepted —
> completion dropped from 38 tokens (reasoning field present) to 1 token.
> Orchestrators MAY send `chat_template_kwargs: {"enable_thinking": false}` on
> oMLX ≥ 0.4.4; keep the `max_tokens ≥ 200` floor regardless.
>
> **Probe 3 run: 2026-07-04, oMLX 0.4.4 — sustained N=10 FAILS, N=8 PASSES**
> (see the probe-3 section below for the full matrix, including the 6-bit A/B).
>
> **Probe 4 run: 2026-07-05, oMLX 0.4.4 (MLX 0.31.2), macOS 26.5.1 — PASS.**
> M5 Neural Accelerators engaged by the Homebrew build: 57.0 TFLOPS fp16 /
> 57.1 TFLOPS bf16 on the GEMM probe (~3× plain-shader class). The oMLX
> v0.2.19 "must use the `macos26-tahoe` DMG" guidance is stale at 0.4.4 (#27).
>
> **Probe 2 A/B: 2026-07-20, oMLX 0.4.4 — thinking-off PASSES tool-call
> fidelity; suppression ratified (#44).** 12-scenario × 3-rep A/B, 36 calls
> per arm: 29/36 correct thinking-off vs 27/36 thinking-on, all 72 calls
> well-formed, ~3× mean latency reduction (1,849 → 626 ms single-stream).
> Delivery is client-side via the pi_config `payload-tuner` extension
> (psmfd/pi_config#769, its ADR-0106), verified not to churn the oMLX prefix
> cache. See the probe-2 A/B subsection and `probes/thinking-ab/`.
>
> **0.5.3 re-baseline: 2026-07-28, oMLX 0.5.3 (MLX 0.32.0), macOS 26.5.2 —
> probes 3 + 4 PASS; prefill-ladder re-measured** (post-upgrade run for
> #56/#39; see the "0.5.3 re-baseline" subsections under probes 3 and 4).
> Highlights: probe 4 unchanged at 57.4/57.3 TFLOPS; sustained mark 4 ran an
> incident-shaped load (8×~28.3K-token cold streams) clean — 16/16, zero guard
> rejects; the guard's idle dynamic ceiling rose 66 → **73.08 GB** and the
> single-prefill acceptance boundary moved ~84K → **~98K tokens** (81K
> accepted outright), so ADR-011's `contextWindow 76800` and ADR-012's mark 4
> stand with *more* margin — no config change. TurboQuant KV compression is
> **off** for the workhorse (`turboquant_kv_bits=None`), so the slope stays
> comparable across versions. One contract change: an over-boundary prompt now
> surfaces as an **HTTP 200 "JSON keepalive prefill rejected"** error after a
> multi-minute stall, not the 0.4.4 instant 400 — router/pi handling tracked
> in #58. The 0.5.1 SSD-cache re-keying invalidated the on-disk prefix cache
> once (4,974 blocks / 65.77 GB skipped at first scan) — expected, one-time.
>
> **0.5.7 re-baseline: 2026-08-15, oMLX 0.5.7 (MLX 0.32.0), macOS 26.5.2 — all
> gates PASS.** Stage 1 inline gauntlet for the 0.5.3 → 0.5.7 upgrade (see
> `.session-notes/057-rebaseline/results.md`). Highlights: probe 4 within
> noise at 56.7 TFLOPS fp16 / 57.3 bf16 (0.5.3: 57.4/57.3); sustained mark-4
> wave ran **16/16 clean** at a heavier ~35K-token shape; fresh-idle
> acceptance rose to **≥91K tokens**, with a 167,473-token prompt now
> rejected **instantly (HTTP 400) at a new preflight stage** carrying a
> machine-readable `code: "prefill_memory_exceeded"` — the #58
> stall-then-200 contract is fixed **for the single-stream case** (whether a
> post-admission mid-flight reject survives under concurrent load stays open;
> the re-baseline waves never triggered the guard concurrently — see the
> router-wiring saturation section). Guard estimator slope dropped to
> **~0.36 GB/1K** (was 0.44); idle dynamic ceiling **73.26 GB**. Hot-cache
> boundary **≥69.9K** (0.5.3 could only flag ~45K — first time verified
> against the ADR-011 gate). The mark-8 oversubscription diagnostic came
> back **clean** — spiral not reproducible, one hard-pressure idle reclaim
> recovered in a single pass — **#29 disposition: close with evidence**. A
> one-time SSD-cache partial invalidation at first start (831/3,872 blocks
> skipped) was expected. See the probe-2 "0.5.7 smoke" note and the probe-3
> "0.5.7 re-baseline" subsection.
>
> **Probe 5 first run: 2026-08-21, oMLX 0.5.7 (MLX 0.32.0), macOS 26.5.2 —
> single-stream decode baseline 83.1 tok/s median** at short context
> (three runs, 83.0–83.4 — see probe 5). Live-log anchors at long context:
> ~44–47 tok/s at ~44K-token prompts; 36.6 tok/s across a 16K-token
> generation. Captured during the serial-workload assessment as the
> denominator for any future speculative-decoding A/B (#71 — DFlash revisit,
> closed no-go: no trained DFlash draft checkpoint or dflash-mlx target
> adapter exists for `Glm4MoeLiteForCausalLM`).

Prereqs: server provisioned, `omlxctl start` done, `KEY="$(cat ~/.omlx/api-key)"`.

## 1. Long-context MLA-compression probe (≥16K tokens)

**Why.** GLM-4.7-Flash uses MLA KV compression, and at least one engine (vLLM)
has shipped a silent MLA→MHA fallback for exactly this model — a ~16–17× KV
blowup that surfaced mostly at long contexts. The ADR-009 acceptance probe ran
at ~7.3K tokens; this re-check covers the 9–16K range the fan-out actually uses
("The Mark" was measured at ~16K).

**Procedure.**

1. Note the resting footprint with the model loaded but idle:

   ```bash
   omlxctl status
   vmmap --summary "$(pgrep -x omlx-server)" | grep -i 'physical footprint'
   ```

2. Send one completion with a ≥16K-token prompt (any large file dump works —
   `PROMPT` below just needs to be ~60–70 KB of text):

   ```bash
   PROMPT="$(head -c 70000 /usr/share/dict/words | tr '\n' ' ')"
   curl -sS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
     -d "$(jq -n --arg p "$PROMPT" '{model:"coding-workhorse",max_tokens:256,messages:[{role:"user",content:$p}]}')" \
     http://localhost:8000/v1/chat/completions >/dev/null
   ```

3. Re-measure the footprint during/immediately after decode.

**Pass:** the KV growth for a ~16K prompt stays in the hundreds-of-MB range
(MLA ≈ GQA class — the ADR-009 7.3K probe measured +214 MB). **Fail:** growth in
the multi-GB range for one request → suspect an MHA fallback; do not raise
concurrency, and re-verify the oMLX/mlx-lm version against the GLM MLA support
matrix before continuing.

## 2. `enable_thinking` pass-through probe

**Why.** GLM emits a reasoning preamble before every answer/tool call — the
reason `max_tokens ≥ ~200` is required on tool-bearing requests. GLM's chat
template supports `chat_template_kwargs: {"enable_thinking": false}` on several
engines; if oMLX passes it through, the preamble token tax disappears at the
source. Untested on oMLX — and note SGLang has an open issue where GLM's
reasoning could not be fully disabled, so verify the behavior, don't assume it.

**Procedure.**

```bash
curl -sS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"coding-workhorse","max_tokens":256,
       "chat_template_kwargs":{"enable_thinking":false},
       "messages":[{"role":"user","content":"Reply with the single word: pong"}]}' \
  http://localhost:8000/v1/chat/completions
```

Compare `usage.completion_tokens` with and without the
`chat_template_kwargs` field, and check whether the content still carries a
reasoning preamble.

**If it works:** the orchestrator can send `enable_thinking:false` on
tool-bearing requests instead of relying only on generous `max_tokens` (keep
`max_tokens ≥ 200` anyway as the belt-and-suspenders floor). **If oMLX rejects
or ignores the field:** stick with the `max_tokens` floor; re-test after oMLX
upgrades.

### Tool-call fidelity A/B (2026-07-20, oMLX 0.4.4) — thinking-off ratified

The pass-through probe above verified token suppression only on a trivial
prompt; #44 gated actually *using* it on tool-bearing turns on whether
suppression costs tool-call accuracy (the GLM-4.7-Flash model card recommends
preserved thinking for tool-calling benchmarks, so parity was not assumable).
The A/B: 12 agentic scenarios — 5-tool `tools` array attached, two
~15K-prompt-token long-context cases, two no-tool controls — 3 reps per
scenario per arm, single-stream, direct `/v1/chat/completions`, `max_tokens
1024`. Harness + raw results: [`probes/thinking-ab/`](../probes/thinking-ab/).

| Arm | Correct tool+args | Well-formed | Mean latency | Mean completion tok |
| --- | --- | --- | --- | --- |
| thinking ON | 27/36 | 36/36 | 1,849 ms | 97 |
| thinking OFF | **29/36** | 36/36 | **626 ms** | **21** |

**Reading.** No accuracy regression — thinking-off scored marginally higher.
The two scenarios failing in both arms failed identically (the model called
`read` first — a defensible agentic first step that strict single-turn scoring
marks wrong; a harness artifact, not an arm difference). The only
arm-differentiated scenario favored thinking-off (3/3 vs 0/3). The no-tool
controls held in both arms — no spurious tool calls. Latency matched the
prediction: ~3× single-stream, with the long-context no-tool case collapsing
from 5.3 s / 208 tok to 0.9 s / 2 tok.

**Decision (ratified 2026-08-15, closing #44).** Suppression is enabled
client-side for tool-bearing turns via the pi_config `payload-tuner`
extension (psmfd/pi_config#769, PR #771, its ADR-0106), which injects
`chat_template_kwargs: {"enable_thinking": false}` in
`before_provider_request` and was separately verified not to churn the oMLX
prefix cache. It has run live on this host since 2026-07-20 with no observed
tool-call misfires. Known caveats accepted with the ratification: 12
scenarios, not the (unrecoverable) 58-scenario ADR-010 battery; single-turn
scoring; no concurrent-load leg. The `max_tokens ≥ 200` floor stays as
belt-and-suspenders. Re-run the A/B after any model or quant change.

**0.5.7 smoke (2026-08-15).** `enable_thinking:false` suppression
re-verified on oMLX 0.5.7 — 1 completion token on all isolation runs during
the 0.5.3 → 0.5.7 re-baseline gauntlet
(`.session-notes/057-rebaseline/results.md`).

## 3. Sustained-concurrency probe (the Mark under continuous load)

**Why.** ADR-009's "Mark" (`--max-concurrent-requests 10`, measured 10 clean at
~16K ctx) was a single-shot burst measurement. A parallel-agent orchestrator can
re-fire the moment responses land, so the operating point must also hold under
back-to-back waves with zero think time — the worst case being N *distinct*
~16K system prefixes (one per subagent persona) that all miss the prefix cache.

**Procedure.** Fire waves of N concurrent `/v1/chat/completions` requests
(~16K-token distinct system prefixes, `max_tokens` 300) back-to-back for 8–30
minutes; after each wave sample `vmmap --summary` physical footprint,
`memory_pressure -Q`, and `pmset -g therm`. Watch the server log for
`Preflight rejected` / `Hard memory pressure` lines.

**Results (2026-07-04, oMLX 0.4.4, M5 Max 128 GB, guard 90 GB, hot-cache 24 GB —
enforcer thresholds derived from the guard: soft 76.5 GB, hard 85.5 GB):**

| Model | N | Outcome | Footprint plateau | Margin to hard threshold |
| --- | --- | --- | --- | --- |
| 8-bit (30 GB) | 10 | **COLLAPSE** — 50/2,690 ok after wave 1 (30 min) | 94–102 GB RSS | none — pressure spiral |
| 8-bit (30 GB) | 8 | clean 64/64, wave time creep 57→66 s | ~81.5 GB | ~4 GB |
| 8-bit (30 GB) | 6 | clean 66/66, stable | ~64 GB | comfortable |
| 6-bit (23 GB) | 10 | 50/60 — one full wave rejected, recovered | 96–97 GB RSS | intermittent spiral |
| 6-bit (23 GB) | 8 | clean 64/64 | ~78 GB | ~8 GB |

**Failure mechanism (from the server log).** Ten concurrent cold ~16K prefills
push oMLX's tracked memory into the enforcer's hard-pressure band; the enforcer
*lowers the dynamic admission ceiling* (observed 90 → 81.5 GB) and LRU-evicts
the prefix cache, so retries arrive `cached=0` and need a full ~6.9 GB KV+SDPA
preflight each — predicted peak ~92 GB > ceiling → instant **HTTP 400**
(`oMLX prefill memory guard rejected this prompt`). The eviction keeps the
cache cold, so the reject-loop self-sustains until load stops (recovery to
`pressure ok` took seconds once idle). RSS meanwhile exceeded the guard
(101.9 GB peak) — the guard tracks Metal allocations, not RSS (#702). The host
itself stayed healthy throughout: no thermal `CPU_Speed_Limit` engaged on the
16-inch chassis (Mac17,6) and system memory pressure never went critical.

**Operational consequences.**

- The Mark = 10 is a **burst** ceiling, not a sustained operating point.
  Sustained-safe worst case on the 8-bit build is **N=8** (slim margin) and
  N=6 is comfortable; the 6-bit build widens N=8 margin to ~8 GB but still
  blips at N=10.
- Saturation surfaces to clients as **HTTP 400**, not 429/503. Router/client
  retry logic must treat this specific 400 (`prefill memory guard rejected`)
  as a capacity signal (backoff/retry or route to the cloud frontier), not a
  permanent client error.
- Prefix-cache reuse works when the enforcer is unpressured (~24.6 s cold vs
  ~7 s warm for a 16K prefix, single stream) — protecting the cache from
  pressure-driven eviction is exactly why the sustained N must stay below the
  spiral point.

**6-bit A/B (same date).** `mlx-community/GLM-4.7-Flash-6bit` (23.0 GB
resident vs 30.0 GB): MLA probe PASS (+2.0 GB resident / +5.6 GB peak @ 15,959
tokens); tool-calls 10/10 well-formed (mean 1.2 s vs 8-bit's 10/10 @ 1.8 s);
sustained results in the matrix above. No fidelity regression observed on
these probes; coding-quality delta not benchmarked.

### 0.5.3 re-baseline (2026-07-28, mark 4, MLX 0.32.0, macOS 26.5.2)

Post-upgrade re-run for #56/#39 after the 0.5.2 memory-guard retune
("eviction now starts at the soft watermark" + #2179 pooled-buffer
self-recovery) invalidated the 0.4.4-fit constants.

**Sustained run (harsher than canonical).** The generated prefixes tokenized
to **~28.3K tokens** (not the canonical ~16K), so the run reproduced the
2026-07-26 incident shape directly: back-to-back waves of 8 concurrent unique
cold ~28.3K prompts (server admits 4, queues 4; `max_tokens` 300), ~13 min.
Result: **16/16 ok, zero guard 400s, zero `adaptive_prefill_throttle` /
eviction lines**, footprint plateau ~63 GB, host memory pressure normal.
The mark-8 failure mode (400 storm + cache-evict spiral) did not reproduce at
mark 4 on 0.5.3. Per-stream decode collapsed to ~0.8–1.6 tok/s while
concurrent prefills ran — the head-of-line fairness issue tracked in #45, not
a regression. Wave wall time ~372–390 s for 8×28.3K cold streams.

**Prefill ladder (pi_config#889 method, fresh restart, single stream, unique
cache-busting payloads).** Accepted rungs, wall time and process footprint
(peak is cumulative):

| Prompt tokens | Wall time | Footprint cur → peak |
| --- | --- | --- |
| 8,161 | 4.3 s | 23.8 → 27.5 GB |
| 16,249 | 12.2 s | 24.6 → 29.8 GB |
| 32,496 | 42.5 s | 26.4 → 36.2 GB |
| 48,648 | 93.8 s | 29.0 → 44.0 GB |
| 64,898 | 169.7 s | 32.6 → 52.7 GB |
| 72,905 | 213.2 s | 36.7 → 59.4 GB |
| 81,105 | 263.8 s | 41.2 → 66.5 GB |

The ~88K and ~96K rungs were **rejected by the guard** — but on 0.5.3 the
rejection is no longer an instant pre-compute 400: the scheduler paused the
request (`adaptive_prefill_throttle`), ran the 0.5.2 pooled-buffer reclaim
(recovered only 2.58/3.27 GB, "no idle model to evict"), then rejected ~5 min
in as an **HTTP 200 "JSON keepalive prefill rejected"** error body with no
`usage` (guard lines: "~91.83 GB peak (current 53.17 GB + KV+SDPA 38.65 GB)
but dynamic ceiling is 73.08 GB"). Client-side capacity detection must handle
both paths — tracked in #58.

**Derived constants (0.5.3), vs ADR-011's 0.4.4 fit:**

- Guard dynamic ceiling at idle: **73.08 GB** (was 66 GB).
- Guard estimator slope: **~0.44 GB/1K tokens** (88K rung: 38.65 GB; 96K rung:
  42.25 GB — effectively unchanged from 0.433). Actual per-rung footprint cost
  measured lower (~0.37 GB/1K), i.e. the estimator is conservative.
- Fresh-idle acceptance boundary: **~98K tokens** by ADR-011's formula
  `(ceiling − current≈30 GB) / slope` (was ~84K); 81K accepted outright.
- **Caveat:** retained prefix cache grew guard "current" from ~30 GB to
  **53.17 GB** over the ladder, shrinking the *effective* boundary to ~45K
  under long uptimes with a hot cache — throttle-time reclaim recovered only
  ~3 GB. The advertised window must keep margin for this, not just for host
  load.

**Config consequence: none.** `contextWindow 76800` is ~78% of the new idle
boundary (was ~91% of the old) and the wall-time cliff (264 s at 81K) still
argues against inviting larger contexts; mark 4 ran the incident shape clean.
ADR-011/012 stand re-affirmed with wider margin — no amendment needed.

### 0.5.7 re-baseline (2026-08-15, mark 4, MLX 0.32.0, macOS 26.5.2)

Post-upgrade re-run for the 0.5.3 → 0.5.7 gauntlet
(`.session-notes/057-rebaseline/results.md`).

**Sustained wave (mark 4).** 2 waves × 8 concurrent unique cold streams,
tokenized to **33.4–37.9K tokens each** (~25% heavier than 0.5.3's 28.3K
shape), `max_tokens 200`, thinking suppressed:

| Wave | Streams | Outcome | Wall time |
| --- | --- | --- | --- |
| 1 | 8/8 | HTTP 200 | 498 s |
| 2 | 8/8 | HTTP 200 | 510 s |

**16/16 HTTP 200, zero guard events** (all guard-matching log lines were
restart banners plus the intentional 150K probe) — no cross-wave
degradation, no eviction spiral. RSS spot-peak 43.4 GB (KV largely lives
outside RSS; treat as a floor, not a footprint). Per-stream decode during
concurrent prefill still collapses to ~1 tok/s implied — same as 0.5.3; #45
stays live.

**Prefill ladder (fresh-idle, fresh restart, single stream, unique
cache-busting payloads).** Rungs 16K→96K:

| Rung (actual prompt tok) | HTTP | Wall | Prefill rate |
| --- | --- | --- | --- |
| 14,431 | 200 | 10 s | ~1,443 tok/s |
| 31,218 | 200 | 39 s | ~800 tok/s |
| 45,496 | 200 | 78 s | ~583 tok/s |
| 63,155 | 200 | 146 s | ~433 tok/s |
| 75,979 | client abort @1,029 s | — | ~46 tok/s (crawl) |

Gate read: **≥91K fresh-idle acceptance** (0.5.3: ~98K; threshold ≥85K) →
ADR-011 boundary gate PASSING pending the reject-rung measurement. Prefill
rate declines smoothly with size (1,443→295 tok/s), no cliff. See the
"Sequential-ladder crawl" note below for the 75,979-token rung's anomaly and
its isolation runs.

**Derived constants (0.5.7), vs 0.5.3:**

- Guard dynamic ceiling at idle: **73.26 GB** (0.5.3: 73.08 GB — unchanged).
- Guard estimator slope: **~0.36 GB/1K tokens** (0.5.3: ~0.44 — #2434 fix
  visible).
- Implied fresh-idle acceptance ceiling: **~135K tokens** (measured
  accepted: 91K; measured rejected: 167K — exact edge not bisected, not
  needed for the gate).

**Mark-8 oversubscription diagnostic (temp manual instance, identical flags,
`--max-concurrent-requests 8`): CLEAN — spiral not reproducible on 0.5.7.**
8 concurrent unique ~34.5–37.9K cold streams, all admitted simultaneously:
**8/8 HTTP 200 in 495 s total, zero rejects, zero evictions.** One
hard-pressure event mid-wave ("Hard memory pressure, no evictable models and
no loads in progress: requested idle reclaim") recovered cleanly in a
single pass — the 0.5.4 #2342 buffer-drain fix visibly working where 0.4.4
produced the ADR-010 reject-storm/evict spiral. **#29 disposition: close
with evidence** (mechanism not reproducible on 0.5.7; upstream fixed the
adjacent enforcer family in #2059/#2581/#2342). ADR-012's mark 4 remains the
right operating point — mark-8 completions were all-or-nothing at ~495 s vs
mark 4's staggered 296–510 s.

**Operational caveat.** During 8-way concurrent prefill the server logs
nothing and RSS stays flat (~23 GB) for ~8 min while `/health` and
`/v1/models` stay responsive throughout — easily mistaken for the upstream
#2624 wedge. `omlxctl status` cannot distinguish "prefilling hard" from
"wedged" — monitoring gap worth a note.

**Sequential-ladder crawl (watch-item).** During the fresh-idle prefill
ladder, the 5th consecutive large unique prefill (75,979 tokens) crawled to
~46 tok/s once (client abort at 1,029 s; server log: `Prefill interrupted at
47104/75979 tokens`, no guard/throttle lines — silent slowness). Isolation
runs after a fresh restart exonerated size and single-prior-write
contention as causes (66,382 tok clean-idle: 200 in 159 s, ~418 tok/s;
91,423 tok immediately after with no restart: 200 in 310 s, ~295 tok/s),
pointing to a cumulative multi-rung effect (4+ back-to-back large unique
prefills) consistent with the upstream #2624/#2647 SSD boundary-snapshot
stall family. It did **not** recur under the mark-4 wave shape above.

## 4. M5 Neural Accelerator engagement probe

**Why.** MLX exploits the M5 GPU's Neural Accelerators (dedicated matmul units;
Apple cites up to ~4× prefill vs M4 on a similar MoE shape) only when two gates
hold: **macOS ≥ 26.2** and an MLX core new enough (M5 support landed in mlx
v0.30.0; M5 Pro/Max tuning in v0.31.1). oMLX's v0.2.19 release notes told M5
owners to use the `macos26-tahoe` DMG, raising the question of whether the
Homebrew tap build engages the accelerators at all. For a shared-long-prefix
fan-out workload the uplift is concentrated exactly where it matters —
compute-bound prefill/TTFT — so verify engagement instead of assuming it.

**Procedure.**

1. Check the version gates:

   ```bash
   sw_vers -productVersion          # must be >= 26.2
   /opt/homebrew/opt/omlx/libexec/bin/python -c \
     "import mlx.core as mx; print(mx.__version__)"   # must be >= 0.31.1
   ```

2. Run the GEMM throughput probe with the keg's own interpreter (safe to run
   with the server up — two 4096×4096 fp16 matrices are ~32 MB each):

   ```bash
   /opt/homebrew/opt/omlx/libexec/bin/python - <<'EOF'
   import time
   import mlx.core as mx
   N, iters = 4096, 50
   for dtype, name in [(mx.float16, "fp16"), (mx.bfloat16, "bf16")]:
       a = mx.random.normal((N, N)).astype(dtype)
       b = mx.random.normal((N, N)).astype(dtype)
       mx.eval(a, b)
       for _ in range(5):
           mx.eval(a @ b)
       t0 = time.perf_counter()
       for _ in range(iters):
           mx.eval(a @ b)
       dt = time.perf_counter() - t0
       print(f"{name}: {2*N**3*iters/dt/1e12:.1f} TFLOPS")
   EOF
   ```

   MLX evaluates lazily — the per-iteration `mx.eval` is load-bearing. Without
   it the loop times graph construction only and reports impossible numbers
   (a broken first attempt showed 1,563 TFLOPS).

**Pass:** ≥ ~40 TFLOPS fp16 — only the Neural Accelerator path reaches that on
this chip class (plain Metal shaders land well under ~20). **Fail:** shader-class
numbers despite both version gates passing → the installed build is not
engaging the accelerators; check how the keg was built (brew tap vs DMG) and
the bundled mlx version before touching serving config.

**Last run (2026-07-28, oMLX 0.5.3 brew keg, MLX 0.32.0, macOS 26.5.2):**
57.4 TFLOPS fp16 / 57.3 TFLOPS bf16 — PASS. The 0.5.0 "NAX-aware dispatch"
change did not move the M5 Max GEMM baseline (2026-07-05 on 0.4.4 / MLX
0.31.2: 57.0 / 57.1). Re-run after any oMLX upgrade (the bundled MLX can
move) and after any macOS update (see also the macOS-27 hold:
jundot/omlx#1835).

**Last run (2026-08-15, oMLX 0.5.7 brew keg, MLX 0.32.0, macOS 26.5.2):**
56.7 TFLOPS fp16 / 57.3 TFLOPS bf16 vs the 0.5.3 baseline 57.4/57.3 — within
noise; Neural Accelerators engaged — PASS
(`.session-notes/057-rebaseline/results.md`).

## 5. Single-stream decode baseline (serial-workload reference)

**Why.** Every decode figure the earlier probes recorded was measured under
concurrent load and is contaminated by contention (probe 3's 0.9–7.9 tok/s
figures are the #45 head-of-line-fairness artifact, not a hardware ceiling).
The repo had no clean single-stream number at all — yet that number is the
denominator for any speculative-decoding A/B (see #71) and the operative
throughput figure if the client workload ever runs serially. This probe
records it.

**Procedure.** One isolated streaming completion at a time, no concurrent
traffic (check `omlxctl logs` for a quiet window first). Small cold prompt so
prefill is negligible; decode tok/s excludes TTFT by timing first-to-last
streamed token:

```bash
python3 - <<'EOF'
import json, statistics, time, urllib.request
from pathlib import Path
KEY = Path.home().joinpath(".omlx/api-key").read_text().strip()
PROMPT = ("Write a detailed technical explanation of how CPU cache "
          "hierarchies work. Be thorough and keep going until cut off.")
results = []
for i in range(3):
    body = json.dumps({"model": "coding-workhorse",
                       "messages": [{"role": "user", "content": PROMPT}],
                       "max_tokens": 1024, "stream": True,
                       "stream_options": {"include_usage": True}}).encode()
    req = urllib.request.Request(
        "http://localhost:8000/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {KEY}"})
    t0 = time.monotonic(); t_first = t_last = None; usage = None
    with urllib.request.urlopen(req, timeout=300) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            evt = json.loads(line[6:])
            if evt.get("usage"):
                usage = evt["usage"]
            ch = evt.get("choices") or []
            d = ch[0].get("delta") if ch else None
            if d and (d.get("content") or d.get("reasoning_content")):
                t_last = time.monotonic()
                t_first = t_first or t_last
    n = usage["completion_tokens"]
    toks = round((n - 1) / (t_last - t_first), 2)
    print(f"run {i+1}: ttft={t_first-t0:.3f}s tokens={n} decode={toks} tok/s")
    results.append(toks); time.sleep(2)
print("median:", statistics.median(results), "tok/s")
EOF
```

**Pass:** n/a — a reference measurement, not a gate. Record the median and
compare against the prior entry after any oMLX, MLX, macOS, or quant change;
an unexplained regression is grounds to bisect before trusting the upgrade.

**Last run (2026-08-21, oMLX 0.5.7 brew keg, MLX 0.32.0, macOS 26.5.2):**
**83.1 tok/s median** (83.39 / 82.96 / 83.10 — spread under 0.5%), TTFT
0.33–0.45 s, 48-token cold prompt (`cached=0` all runs), 1024-token
generations. Context-length sensitivity from the same day's live logs
(serial requests, warm cache): ~44–47 tok/s at ~44–45K-token prompts and
36.6 tok/s across a full 16K-token generation at ~45.8K prompt — attention/
KV-read cost roughly halves decode speed by ~45K context. Captured for the
serial-workload assessment and the #71 DFlash revisit (closed no-go —
architecture unsupported; the baseline outlives the ticket).

Note the outcome (date, oMLX version, pass/fail, measured numbers) in the PR or
issue that prompted the re-run. If probe 1 fails, that is grounds to revisit
ADR-009's model choice — the on-disk Qwen3-Coder-30B fallback (GQA,
prefix-cache-safe, tool-clean) is the documented escape hatch.
