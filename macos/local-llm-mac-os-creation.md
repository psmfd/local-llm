# Task: provision oMLX for local coding inference on an M5 Max

> **Status:** authoritative implementation brief. Durable decisions live in
> `CLAUDE.md` and `adrs/003-vlm-engine-workaround-lineup.md` (superseding
> `adrs/002-qwen36-lineup-memory-guard.md` and, through it,
> `adrs/001-local-mlx-inference-omlx.md`); executable behavior
> lives in `setup-omlx-m5.sh` and `templates/`; downstream integration guidance
> lives in `docs/router-wiring.md`. The top-level `omlx-setup-prompt.md` is a
> historical source prompt, not an additional source of truth.

This brief targets an Apple Silicon MacBook Pro (**M5 Max, 128 GB unified memory**, macOS). It provisions **oMLX** (`jundot/omlx`) as a local, OpenAI/Anthropic-compatible inference server tuned for a **parallel-agent coding workload** — an orchestrator fans out 3+ concurrent agent requests that share long system prefixes, so concurrent throughput and prefix-cache reuse matter more than single-stream tok/s.

The implementing agent follows its standard operating framework: classify the task, **plan before code and wait for operator approval**, route domain subtasks agent-first, run the post-implementation review gate, and end with an efficacy report. Apply the **Script Output Conventions** (6-char labels, `ok`/`skip`/`warn`/`info`/`err`/`detail` helpers, `((counter++)) || true`, exit codes 0/1/2, `set -euo pipefail`, summary block) to any script. Use `shell-expert` for the script and `linter` for the shellcheck pass.

## Hard constraints

- **No MCP.** Do not install the oMLX `mcp` extra, do not add `mcp-servers` anywhere, do not reference MCP packages. Tool access stays explicit.
- **Secrets.** Generate the API key locally, store it at `~/.omlx/api-key` with `chmod 600`, never print it or embed it in any file under version control.
- **Idempotent.** Re-running must be safe — detect and skip what already exists.

## Settled decisions (verify before acting — models move fast)

These came out of prior analysis. Treat the runtime and serving config as decided; **re-verify the model choice and exact HuggingFace MLX repo IDs against current availability** as of today before downloading anything — search, confirm the repo exists, and confirm it still represents the best local coding model for this hardware. If something better has shipped, propose it in the plan rather than silently substituting.

- **Runtime:** oMLX, installed via Homebrew (`brew tap jundot/omlx https://github.com/jundot/omlx && brew install omlx`).
- **Model tiers (ADR-006):** three verified text-only coder builds (no `vision_config` → batched LLM engine, no override), tool-call-verified on oMLX:
  - **T1 `coding-fast`** — `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` (`Qwen3MoeForCausalLM`, MoE ~3B active, 262K ctx), ~30.6 GB. **Pinned, co-resident.**
  - **T2 `coding-balanced`** — `mlx-community/GLM-4.7-Flash-8bit` (`Glm4MoeLiteForCausalLM`, MoE ~3B active, 202K ctx), ~30 GB. **Pinned, co-resident.**
  - **MAX `coding-quality`** — `lmstudio-community/Qwen3-Coder-Next-MLX-4bit` (`Qwen3NextForCausalLM`, 80B/~3B active, ~71% SWE-bench), ~45 GB. **On-demand** (lazy-loads ~16 s on first request, idle-evicts; not pinned — it does not co-reside with T1+T2). The earlier multimodal Qwen3.6 primary + `model_type_override` approach (ADR-003) was retired: every Qwen3.6 build is VLM-trapped and no runtime change unlocks a better *coder* (ADR-006, `docs/runtime-tiering-research.md`).
- **Serving flags:** `--host 127.0.0.1` (explicit loopback pin), port `8000`, `--memory-guard-gb 90` (replaces the removed `--max-process-memory`), `--paged-ssd-cache-dir ~/.omlx/cache`, `--hot-cache-max-size 18GB` (absolute size only — oMLX rejects percentages), `--max-concurrent-requests 16`, `--api-key` from the 0600 file.
- **Metal wired limit:** raise `iogpu.wired_limit_mb` to ~96 GB (98304) so Metal can wire the two co-resident tiers (~60 GB) with KV headroom; persist across reboot via a LaunchDaemon (needs sudo).
- **On-demand lifecycle (no login autostart):** per-user LaunchAgent running a start wrapper (brew services only starts with zero-config defaults, so use a wrapper that carries the tuned flags). The agent is `RunAtLoad=false` + `KeepAlive=false` — registered at login but never started, and a stop/crash stays down. Start/stop is intentional via the installed `omlxctl` tool (ADR-005).

## What to do

1. **Verify environment** — macOS, arm64, RAM ≥ ~120 GB, free disk ≥ ~140 GB (three tiers ≈ 105 GB + cache), Homebrew present. Abort with exit 2 on those hard precondition failures. Treat M5 Max as the tuned target; warn rather than hard-fail on non-M5 Apple Silicon so nearby Max-class hosts can smoke-test deliberately.
2. **Author or reuse the setup script.** If `setup-omlx-m5.sh` already exists in the working directory, review it against the spec above and the conventions, then use it. Otherwise write it. It must: install oMLX (no MCP extra); create `~/models`, `~/.omlx/cache`, `~/.omlx/logs`; generate the 0600 API key; set + persist the wired limit; write the start wrapper; install the on-demand LaunchAgent (RunAtLoad=false) and the `omlxctl` control tool, leaving the server stopped; leave model download opt-in (default off) routing to the `/admin` downloader unless repo IDs are verified.
3. **Lint it.** Run `shellcheck` and fix all Error/Warning findings; report results in the structured review format with a verdict line.
4. **Run it**, supplying sudo when prompted for the wired-limit step.
5. **Acquire the models.** Once you've verified the exact repo IDs, download the three tiers into `~/models` (via `hf download`), skipping any already present. Confirm they load.
6. **Pin + alias the tiers** via the oMLX admin API (`apply_pins`: briefly start the server, PUT each tier's `model_alias`/`is_pinned` — T1+T2 pinned, MAX on-demand — then stop it; `model_settings.json` is oMLX-owned so never write it directly). Degrade to printed manual `/admin` steps if the API can't be reached.
7. **Validate the endpoint** — `curl` `http://localhost:8000/v1/models` with the API key, then a small `/v1/chat/completions` call, and a **tool-calling** call to confirm the model emits well-formed `tool_call` markup (the orchestrator depends on this; flag if the parser needs configuration).

## Deliverables

- A working, pinned oMLX server reachable at `http://localhost:8000/v1` (and `/v1/messages` for Anthropic-style clients).
- The reviewed, shellcheck-clean setup script.
- An **ADR** (MADR minimal, in `adrs/`) recording the local-inference convention: runtime choice, model choice with the bandwidth/MoE rationale, and the serving config.
- A note on wiring the downstream `IInferenceBackend` / `FallbackInferenceRouter` endpoint to this server (route `coding-fast`/`coding-balanced` → co-resident tiers; `coding-quality` → on-demand max tier, remote as fallback).
- An efficacy report.

Stop and show the operator the plan before executing anything that writes, installs, or runs.
