# ADR-013: serial workflow architecture and the gpt-oss-120b workhorse

- Status: accepted
- Date: 2026-08-24 ([#71](https://github.com/psmfd/local-llm/issues/71),
  [#73](https://github.com/psmfd/local-llm/issues/73))

Amends [ADR-009](009-mac-single-workhorse-cloud-frontier.md): the
single-pinned-workhorse + cloud-frontier structure stands unchanged; this ADR
replaces the workhorse model (`GLM-4.7-Flash-6bit` →
`mlx-community/gpt-oss-120b-4bit`) and retires the parallel fan-out serving
premise the ADR-009 lineup was tuned for. Amends
[ADR-010](010-6bit-workhorse-sustained-mark.md) (the 6-bit-vs-8-bit quant
decision and sustained mark are GLM-specific and go dormant with the model),
[ADR-011](011-pi-context-window-guard-boundary.md) (pi `contextWindow`
76800 → 122880 — the binding constraint moves from the prefill guard to the
model's native position limit), and
[ADR-012](012-concurrency-mark-4-large-context.md)
(`--max-concurrent-requests` 4 → 1; the pi `maxTokens` 8192 stands).

## Context and Problem Statement

The host's client workload is moving from a parallel agent fan-out (3+
concurrent requests sharing long system prefixes — the premise of ADR-009
through ADR-012) to a strictly serial workflow: one request in flight, each
step's output feeding the next as a growing transcript. Under that shape,
should the workhorse remain GLM-4.7-Flash-6bit, or is a better model available
once the concurrency-driven constraints no longer bind?

A three-angle research pass (2026-08-21) found exactly one candidate the
ADR-009-era survey never screened: `gpt-oss-120b-4bit` (117B total / 5.1B
active MoE, alternating sliding-window(128)/full attention with 8-head GQA,
text-only `GptOssForCausalLM`, native 131,072 context, Harmony tool format).
Everything else new since the ADR-009 survey is disqualified by size
(GLM-5.x, MiniMax M2.5/M2.7, Kimi K2.x), hybrid-SSM architecture that breaks
prefix-cache reuse — fatal for a growing-transcript workload (the whole
Qwen3.5+ generation incl. Qwen3-Coder-Next; mlx-lm #980, oMLX #825) — or
multimodality (Gemma 4, Muse-Glimmer). No Flash/Air-class GLM successor
exists. Speculative decoding (DFlash) was separately evaluated and closed
no-go for GLM ([#71](https://github.com/psmfd/local-llm/issues/71) — no
trained draft checkpoint for `Glm4MoeLiteForCausalLM`).

## Considered Options

- Keep GLM-4.7-Flash-6bit, retune flags for serial (mark 1; no model change)
- Switch the workhorse to `mlx-community/gpt-oss-120b-4bit`
- Unlock a vision-tagged candidate (Gemma-4-31B / Muse-Glimmer-30B) via
  `model_type_override: llm` under serial-only load
- A hybrid-SSM large-MoE (Qwen3-Coder-Next-80B) for its size/fit

## Decision Outcome

Chosen option: "switch to `gpt-oss-120b-4bit`", because on-host evidence
([#73](https://github.com/psmfd/local-llm/issues/73), 2026-08-21 → 2026-08-24,
oMLX 0.5.7) shows it beats the incumbent on every measured axis while fitting
the host — and the fit is only possible because the fan-out requirement is
gone (61.56 GB of weights leave no multi-stream KV pool):

| Axis | gpt-oss-120b-4bit | GLM-4.7-Flash-6bit |
| --- | --- | --- |
| HumanEval pass@1 (greedy, 164, tests executed) | **95.7%** (157/164) | 83.5% as deployed; 85.4% thinking-on |
| Paired McNemar | **24 vs 4 discordant, p = 0.00018** | — |
| Decode, short context | **~106 tok/s** | 83.1 tok/s |
| Decode at ~60K / ~77K / ~130K ctx | **55 / 50 / 36 tok/s** | ~44–47 tok/s at ~44K; n/a past ~98K |
| Cold prefill at 76.8K | **~67 s (1,162 tok/s)** | ~3.3 min (~400 tok/s) |
| Context boundary | **native 131,072 (guard never rejects first)** | ~91–98K guard boundary |
| Tool battery (ADR-010 58-call scale) | **58/58**, incl. 13K-deep needles + multi-tool round-trips | 58/58 (ADR-010) |
| KV cost | **~0.070 GB/1K** (sliding-window + GQA) | ~0.36 GB/1K (MLA) |
| 4.09 h serial soak (target flags) | **962 steps, 0 errors, reuse 0.980, RSS flat** | n/a (not run) |

The rejected options: keeping GLM forfeits a statistically decisive quality
gap (+12.2 pts, p = 0.00018) plus every performance axis; the vision-tagged
candidates carry their own non-concurrency correctness bugs (oMLX #1670) or
have zero benchmark/tool evidence; hybrid-SSM models break the prefix-cache
reuse a growing transcript lives on (soak measured 98% reuse — the property
the architecture must keep).

### Serving parameters (replacing the ADR-010/011/012 values)

| Parameter | Old (ADR-009..012) | New | Why |
| --- | --- | --- | --- |
| Pinned model / alias `coding-workhorse` | `GLM-4.7-Flash-6bit` | `gpt-oss-120b-4bit` | this ADR |
| `--max-concurrent-requests` | 4 | **1** | serial invariant; converts a client assumption into a server guarantee — a double-fired step queues instead of competing for KV |
| `--hot-cache-max-size` | 24GB | **8GB** | 61.56 GB weights + 24 GB cache exceeds the ~73 GB dynamic ceiling; 8 GB validated by the soak (reuse 0.980) |
| pi `contextWindow` | 76800 | **122880** | native 131,072 minus the 8,192 maxTokens reservation; guard accepts ≥130K fresh and post-soak (#73 ladder) |
| pi `maxTokens` | 8192 | 8192 | stands (pi output-shrink ladder caps at 8,000) |
| Guard / wired limit / SSD cache | 90 GB / 96 GB / 50GB | unchanged | bandwidth- and disk-bound, not model-bound |
| Reasoning control | `chat_template_kwargs: {"enable_thinking": false}` (GLM-ism) | `chat_template_kwargs: {"reasoning_effort": "medium"}`; `low` = latency knob | top-level `reasoning_effort` param is ignored by oMLX 0.5.7; medium is the 95.7%-HumanEval setting; delivery via pi payload-tuner ([pi_config#1052](https://github.com/psmfd/pi_config/issues/1052)) |

### Consequences

- Good, because quality, decode, prefill, and context window all improve
  simultaneously — there is no measured axis on which the incumbent wins.
- Good, because the serial shape structurally eliminates the ADR-010/012
  incident class (concurrent-admission cache-evict spiral) and the open #45
  head-of-line fairness bug.
- Bad, because the host loses real fan-out capacity: at mark 1 a second
  concurrent client queues. Restoring parallel serving means reverting to a
  small-footprint model — this ADR makes serial-vs-parallel a *model* decision,
  not a flag decision.
- Bad, because idle margin is thin (~11.7 GB: 73.26 GB ceiling − 61.56 GB
  weights). The 4-hour soak on the target flags showed no creep (RSS flat,
  pressure peaks stable at ~77.9 GB) and a post-soak fresh-100K prompt still
  accepted, but deep sessions (~60–70K) brush the soft-pressure threshold: 8
  transient self-recovering `adaptive_prefill_throttle` pauses in 4 h, zero
  failed requests. Workflows SHOULD cycle/compact transcripts around ~60K
  tokens; the pause is otherwise benign backpressure.
- Bad, because Harmony-format parsing is a newer oMLX integration surface than
  GLM's (fixed-bug history through 0.4.x–0.5.x). Mitigated by the 58/58
  battery on 0.5.7; re-run the battery on every oMLX upgrade.
- Rollback is cheap by design: GLM-4.7-Flash-6bit stays on disk as the primary
  inactive fallback (the ADR-010 pinned-swap pattern — repoint the pin via the
  admin API, restore the previous wrapper flags, restart); the 8-bit and
  Qwen3-Coder-30B remain the deeper fallbacks.
- The `--validate` concurrency probe changes meaning: at mark 1 the two-way
  probe verifies queue-then-complete (admission queueing) rather than parallel
  completion.
