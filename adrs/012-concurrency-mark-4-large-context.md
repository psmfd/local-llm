# ADR-012: concurrency mark 4 and maxTokens 8192 for the large-context era

- Status: accepted (concurrency mark superseded by
  [ADR-013](013-gptoss-serial-workhorse.md): 4 → 1 under the serial workflow
  architecture; the maxTokens 8192 decision stands)
- Date: 2026-07-26 ([#52](https://github.com/psmfd/local-llm/issues/52);
  incident analysis in [pi_config#889](https://github.com/psmfd/pi_config/issues/889))

Amends [ADR-010](010-6bit-workhorse-sustained-mark.md): the 6-bit workhorse
stands; this ADR replaces the sustained concurrency mark
(`--max-concurrent-requests` 8 → 4) and the pi-advertised `maxTokens`
(16384 → 8192). Companion to [ADR-011](011-pi-context-window-guard-boundary.md),
which set the per-stream context boundary; this ADR sets the *shared-pool*
concurrency to match.

## Context and Problem Statement

ADR-010's sustained mark of 8 was measured with ~16K-context load. With pi
routing agentic sessions locally (contextWindow 76800 per ADR-011), the
2026-07-26 incident showed the mark no longer holds at real context sizes: the
server admitted many concurrent 23–45K-token `tool_calls` streams, engine
current memory reached 50.87 GB, the prefill guard 400-rejected requests at
40,285 and 53,440 tokens (both far below the advertised window, so clients had
no reason to compact), per-stream decode collapsed to 0.9–7.9 tok/s, and
`adaptive_prefill_throttle` evicted the prefix cache so re-prefills arrived
`cached=0` — the ADR-010 pressure-spiral mechanism at larger contexts. No
crash: the guard held, but the host was effectively exhausted twice.

The governing arithmetic (ADR-011): KV+SDPA costs ~0.433 GB per 1K tokens and
the guard's dynamic ceiling sat at 66 GB, so above the ~30 GB weights+baseline
the KV pool holds **~83K tokens of total concurrent context, shared across all
admitted streams**. Eight 25–45K streams demand ~2–3× that pool. What admission
limit fits the pool at real context sizes?

## Considered Options

- **A. Mark 4 + maxTokens 8192** — halve admitted streams (matching the pi
  subagent spawn cap of 4) so excess requests queue at admission, consuming no
  KV; drop the dead decode-reservation headroom (pi's output shrink ladder
  already caps completions at 8,000 — pi_config ADR-0108).
- **B. Keep 8, shrink per-stream contextWindow further (~20K)** — fits the pool
  arithmetically but cripples single-stream capability and forces constant
  compaction; concurrency is the variable that changed, so it should absorb the
  correction.
- **C. Keep 8, set the memory guard to aggressive** — admits the same
  oversubscription and funds it by evicting the prefix cache faster, destroying
  the 91% lifetime cache-hit economics that make local serving cheap.

## Decision Outcome

Chosen option: "A. Mark 4 + maxTokens 8192", because the pool is
fixed and per-stream context is already tuned (ADR-011) — admission count is
the correct free variable. Queueing at admission degrades gracefully (waiting
requests consume no KV) where oversubscription degrades catastrophically
(guard 400s + cache-evict spiral). 4 aligns with the pi subagent extension's
`MAX_CONCURRENCY = 4`, so a single fan-out wave fits exactly.

### Consequences

- Good, because worst-case admitted KV (4 × ~45K ≈ 78K tokens ≈ 34 GB) now fits
  the ~36 GB pool, ending the 400s-under-normal-load failure mode.
- Good, because queued requests keep the prefix cache intact instead of
  triggering evict spirals.
- Bad, because aggregate throughput under wide fan-out drops — a second
  4-child wave now queues behind the first (the pi-side cap already imposed
  this shape on single sessions; the change extends it across sessions).
- Residual risk: multiple concurrent pi sessions can still stack 4 large
  orchestrator streams; the routing-side mitigation (orchestrators on cloud,
  children local) and a provider-aware pi spawn cap
  ([pi_config#900](https://github.com/psmfd/pi_config/issues/900)) address that
  layer.
- Revisit when host RAM, the guard ceiling, or typical stream context changes;
  the sizing rule is `pool_tokens ≈ (dynamic_ceiling_gb − 30) / 0.000433` split
  across admitted streams.
