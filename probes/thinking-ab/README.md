# thinking-ab — `enable_thinking` on/off tool-call fidelity A/B

The harness and raw results behind the probe-2 thinking-suppression decision
(#44): does sending `chat_template_kwargs: {"enable_thinking": false}` on
tool-bearing turns cost tool-call accuracy on `coding-workhorse`
(GLM-4.7-Flash-6bit)?

**Outcome (2026-07-20 run, oMLX 0.4.4): parity — suppression ratified.**
Thinking-off scored 29/36 correct vs 27/36 for thinking-on, all 72 calls
well-formed, with a ~3× mean latency reduction (1,849 → 626 ms single-stream).
The full reading lives in the probe-2 A/B subsection of
[`docs/workhorse-probes.md`](../../docs/workhorse-probes.md) and on #44.

## What it does

12 agentic scenarios (a 5-tool `tools` array attached, two ~15K-prompt-token
long-context cases, two no-tool controls), each run `REPS` times per arm,
directly against `/v1/chat/completions` — no pi involved, since the
server-level lever is what #44 gated. Each call is scored for well-formedness
(parseable tool call or clean text) and correctness (expected tool + an args
regex, or expected no-tool).

## Running it

Requires a running server (`omlxctl start`) and the API key at
`~/.omlx/api-key`.

```bash
cd probes/thinking-ab
REPS=3 OUT=results.jsonl node harness.mjs
```

- `REPS` — reps per scenario per arm (default 2; the committed run used 3).
- `OUT` — output path for the JSONL results (one row per call).

`results.jsonl` in this directory is the committed 2026-07-20 run. Re-run
after any model or quant change that could shift tool-call behavior, and
compare arms before trusting suppression on the new configuration.
