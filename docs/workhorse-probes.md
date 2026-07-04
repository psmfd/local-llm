# Workhorse probes — one-time on-host checks before trusting the config

Two short probes to run once on the M5 Max after provisioning (and again after
any oMLX or model update), closing the residual risks the ADR-009 review
flagged. Neither is part of `--validate` — both need a long prompt or a
model-behavior judgement that the scripted checks deliberately avoid.

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

Note the outcome (date, oMLX version, pass/fail, measured numbers) in the PR or
issue that prompted the re-run. If probe 1 fails, that is grounds to revisit
ADR-009's model choice — the on-disk Qwen3-Coder-30B fallback (GQA,
prefix-cache-safe, tool-clean) is the documented escape hatch.
