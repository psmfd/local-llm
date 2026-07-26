# ADR-011: pi-advertised contextWindow lowered to the prefill-guard boundary

- Status: accepted
- Date: 2026-07-26 ([#50](https://github.com/psmfd/local-llm/issues/50);
  benchmark in [pi_config#889](https://github.com/psmfd/pi_config/issues/889#issuecomment-5083521123))

Amends [ADR-010](010-6bit-workhorse-sustained-mark.md): the 6-bit workhorse and
sustained concurrency mark stand unchanged; this ADR replaces one parameter —
the pi-advertised `contextWindow` (131072 → 76800).

## Context and Problem Statement

`setup-omlx-m5.sh --configure-pi` advertised `contextWindow: 131072` to the pi
coding agent — inside GLM-4.7-Flash's 202K native window, chosen when the known
limits were concurrency-shaped (ADR-009/010, measured at ~16K contexts). A
prefill ladder benchmark (2026-07-26, unique cache-busting payloads sent
directly to the server) measured the *single-prefill* limit for the first time:

- KV+SDPA memory grows linearly at **~0.433 GB per 1K prompt tokens** (guard
  projections at 88K/96K/112K: 38.15 / 41.63 / 48.45 GB).
- The prefill memory guard's **dynamic ceiling was 66 GB at idle** — well under
  the 90 GB pin, because it tracks actual host free memory — putting the
  acceptance boundary at **~84K tokens**, and lower whenever the host is busier.
- 88K+ prompts are rejected instantly (HTTP 400, pre-compute); a 64K prefill
  succeeds but peaks the server process at 73 GB (from a 50 GB baseline) and
  takes ~150 s (~415 tok/s; throughput degrades superlinearly from ~1,860 tok/s
  at 8K).

pi treats `contextWindow` as ground truth for compaction timing: advertising
131072 means long sessions build contexts the server will never serve and hit
hard 400s ~47K tokens before pi expects the window to end. Should the
advertised window match the model's capability or the host's measured serving
boundary?

## Considered Options

- **A. Lower `contextWindow` to 76800** — pi compacts before the guard rejects.
- **B. Keep 131072 and raise the guard ceiling** — trades a graceful client-side
  compaction for operating nearer OOM; the dynamic ceiling would still fall
  under host load, so the 400s remain reachable.
- **C. Keep 131072 and rely on error handling** — every long session pays a
  hard, unrecoverable-in-place 400 at an unpredictable (load-dependent) point.

## Decision Outcome

Chosen option: "A. Lower `contextWindow` to 76800", because the advertised
window should describe what the host will actually serve, not what the model
could theoretically hold. 76800 ≈ 91% of the idle boundary; with pi's
compaction firing below the window, worst-case prefills land near ~69K tokens
(~30 GB KV+SDPA), preserving margin even under a moderately reduced dynamic
ceiling. The wall-time cliff (3+ minutes near the boundary) independently
argues against inviting larger contexts.

### Consequences

- Good, because sessions compact gracefully instead of dying on guard 400s at a
  load-dependent point.
- Good, because near-boundary prefill wall-times (150 s+ at 64K) are avoided by
  construction.
- Bad, because usable context shrinks by ~42% versus the previous advertisement;
  long-running sessions compact more often.
- Revisit if host RAM, the guard ceiling, or the resident model changes — the
  boundary formula is `(dynamic_ceiling − engine_current) / 0.433 GB` per 1K
  tokens, re-measurable with the pi_config#889 ladder method.
