# ADR-010: 6-bit workhorse quant and a sustained concurrency mark of 8

- Status: accepted
- Date: 2026-07-04 ([#22](https://github.com/psmfd/local-llm/issues/22),
  [#23](https://github.com/psmfd/local-llm/issues/23))

Amends [ADR-009](009-mac-single-workhorse-cloud-frontier.md): the single-pinned-
workhorse + cloud-frontier lineup stands unchanged; this ADR replaces two of its
parameters — the workhorse quantization (8-bit → 6-bit) and the concurrency
mark (`--max-concurrent-requests` 10 → 8).

## Context and Problem Statement

ADR-009's "Mark" of 10 was a single-shot burst measurement. Sustained-load
testing (#22: back-to-back waves of N concurrent requests, ten distinct ~16K
system prefixes, zero think time — the worst-case shape of the parallel-agent
fan-out this host serves) showed the burst figure does not hold: at N=10 the
memory enforcer enters hard pressure, lowers its dynamic admission ceiling
(90 → 81.5 GB observed) and LRU-evicts the prefix cache, so every retry arrives
`cached=0` and is preflight-rejected — a self-sustaining HTTP-400 storm
(50/2,690 requests succeeded over 30 minutes). At N=8 the same load runs clean,
with ~4 GB of margin to the enforcer's hard threshold on the 8-bit build.

In parallel, an A/B of `mlx-community/GLM-4.7-Flash-6bit` (#23) measured no
quality difference from the pinned 8-bit: tool-call fidelity 58/58 each across
a six-scenario battery plus probes; HumanEval pass@1 (all 164 problems, tests
executed) 81.7% vs 80.5% — a 6:4 discordance split, McNemar p ≈ 0.75, a
statistical tie. The 6-bit is 23.0 GB resident vs 30.0 GB, doubling the
sustained N=8 margin to ~8 GB, and passed the MLA long-context probe
(+2.0 GB @ 16K — same class as the 8-bit).

Should the workhorse stay on the 8-bit at the burst mark, or move to the
measured sustained operating point?

## Considered Options

- **A. 6-bit workhorse + mark 8** — adopt the quant with proven quality parity;
  set the flag to the measured sustained-safe concurrency.
- **B. 8-bit + mark 8** — concurrency fix only; keep the 8-bit's nominal
  (statistically insignificant) HumanEval edge and the slimmer ~4 GB margin.
- **C. Status quo (8-bit + mark 10)** — rely on client-side concurrency
  discipline to avoid the measured collapse.

## Decision Outcome

Chosen option: **A**, because every quality axis measurable on this host is a
tie while every capacity axis favors the 6-bit, and the flag at 8 converts the
sustained-saturation failure mode from an HTTP-400 storm into graceful
queueing at admission. `mlx-community/GLM-4.7-Flash-6bit` (verified: same
`Glm4MoeLiteForCausalLM` architecture, 202,752 ctx, no `vision_config`, 6-bit
group-64) becomes `coding-workhorse`; `--max-concurrent-requests` drops to 8.

The 8-bit **stays on disk as the primary inactive fallback** (unpinned, alias
renamed to `workhorse-8b` so the primary alias transfers cleanly); rollback is
one pin swap + restart, exercised twice during testing. Qwen3-Coder-30B remains
the secondary (different-family) fallback per ADR-009.

### Consequences

- Good, because the sustained N=8 margin to the enforcer's hard threshold
  doubles (~4 GB → ~8 GB) and wave latency stays flat where the 8-bit crept.
- Good, because ~7 GB of weight footprint returns to KV/prefix-cache headroom,
  and tool-scenario latency improves slightly (1.2 s vs 1.8 s probe mean).
- Good, because excess fan-out now queues at admission instead of failing —
  burst N=10 remains available, just no longer advertised as the operating
  point.
- Bad (accepted), because single-sample HumanEval cannot resolve quality
  deltas under ~5 points; a subtle 6-bit regression on long agentic sessions
  would surface only in use. Mitigations: the cloud frontier owns
  quality-critical work, and the 8-bit rollback is minutes away.
- Bad (accepted), because saturation still surfaces as HTTP 400 (not 429/503)
  when the guard preflight rejects: the router must treat
  `prefill memory guard rejected` 400s as a capacity signal — documented in
  `docs/router-wiring.md`.

Measurement record: `docs/workhorse-probes.md` (probe 3) and the #22/#23 issue
threads.
