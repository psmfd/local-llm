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

## Recording results

Note the outcome (date, oMLX version, pass/fail, measured numbers) in the PR or
issue that prompted the re-run. If probe 1 fails, that is grounds to revisit
ADR-009's model choice — the on-disk Qwen3-Coder-30B fallback (GQA,
prefix-cache-safe, tool-clean) is the documented escape hatch.
