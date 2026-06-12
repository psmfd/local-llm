# Task: provision oMLX for local coding inference on this M5 Max

> **Status:** authoritative implementation brief. Durable decisions live in
> `CLAUDE.md` and `adrs/003-vlm-engine-workaround-lineup.md` (superseding
> `adrs/002-qwen36-lineup-memory-guard.md` and, through it,
> `adrs/001-local-mlx-inference-omlx.md`); executable behavior
> lives in `setup-omlx-m5.sh` and `templates/`; downstream integration guidance
> lives in `docs/router-wiring.md`. The top-level `omlx-setup-prompt.md` is a
> historical source prompt, not an additional source of truth.

You are operating on my MacBook Pro (Apple Silicon **M5 Max, 128 GB unified memory**, macOS). Provision **oMLX** (`jundot/omlx`) as a local, OpenAI/Anthropic-compatible inference server tuned for a **parallel-agent coding workload** — my orchestrator fans out 3+ concurrent agent requests that share long system prefixes, so concurrent throughput and prefix-cache reuse matter more than single-stream tok/s.

Follow your standard operating framework: classify the task, **plan before code and wait for my approval**, route domain subtasks agent-first, run your post-implementation review gate, and end with an efficacy report. Apply the **Script Output Conventions** (6-char labels, `ok`/`skip`/`warn`/`info`/`err`/`detail` helpers, `((counter++)) || true`, exit codes 0/1/2, `set -euo pipefail`, summary block) to any script. Use `shell-expert` for the script and `linter` for the shellcheck pass.

## Hard constraints

- **No MCP.** Do not install the oMLX `mcp` extra, do not add `mcp-servers` anywhere, do not reference MCP packages. Tool access stays explicit.
- **Secrets.** Generate the API key locally, store it at `~/.omlx/api-key` with `chmod 600`, never print it or embed it in any file under version control.
- **Idempotent.** Re-running must be safe — detect and skip what already exists.

## Settled decisions (verify before acting — models move fast)

These came out of prior analysis. Treat the runtime and serving config as decided; **re-verify the model choice and exact HuggingFace MLX repo IDs against current availability** as of today before downloading anything — search, confirm the repo exists, and confirm it still represents the best local coding model for this hardware. If something better has shipped, propose it in your plan rather than silently substituting.

- **Runtime:** oMLX, installed via Homebrew (`brew tap jundot/omlx https://github.com/jundot/omlx && brew install omlx`).
- **Primary model:** a **Qwen3.6-35B-A3B at 8-bit** MLX build (`mlx-community/Qwen3.6-35B-A3B-8bit`; MoE, ~3B active → fast decode under the 614 GB/s bandwidth cap; 8-bit preserves tool-call JSON fidelity). ~38 GB resident. Alias `coding-fast`. **Requires `model_type_override = llm`** — the checkpoint carries a `vision_config` and oMLX's VLM engine crashes under concurrent requests (oMLX #1800; ADR-003). The setup script applies the override via the admin API.
- **Secondary (optional):** a **Qwen3-Coder-30B-A3B-Instruct at 8-bit** MLX build (`lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit`, ~30 GB, verified text-only → concurrency-safe with no override). Alias `coding-quality`; the guaranteed-safe fan-out fallback.
- **Serving flags:** `--host 127.0.0.1` (explicit loopback pin), port `8000`, `--memory-guard-gb 90` (replaces the removed `--max-process-memory`), `--paged-ssd-cache-dir ~/.omlx/cache`, `--hot-cache-max-size 18GB` (absolute size only — oMLX rejects percentages), `--max-concurrent-requests 16`, `--api-key` from the 0600 file.
- **Metal wired limit:** raise `iogpu.wired_limit_mb` to ~96 GB (98304) so Metal can wire both models with KV headroom; persist across reboot via a LaunchDaemon (needs sudo).
- **Autostart:** per-user LaunchAgent running a start wrapper (brew services only starts with zero-config defaults, so use a wrapper that carries the tuned flags).

## What to do

1. **Verify environment** — macOS, arm64, RAM ≥ ~120 GB, free disk ≥ ~100 GB, Homebrew present. Abort with exit 2 on those hard precondition failures. Treat M5 Max as the tuned target; warn rather than hard-fail on non-M5 Apple Silicon so nearby Max-class hosts can smoke-test deliberately.
2. **Author or reuse the setup script.** If `setup-omlx-m5.sh` already exists in the working directory, review it against the spec above and the conventions, then use it. Otherwise write it. It must: install oMLX (no MCP extra); create `~/models`, `~/.omlx/cache`, `~/.omlx/logs`; generate the 0600 API key; set + persist the wired limit; write the start wrapper; install the LaunchAgent; leave model download opt-in (default off) routing to the `/admin` downloader unless repo IDs are verified.
3. **Lint it.** Run `shellcheck` and fix all Error/Warning findings; report results in the structured review format with a verdict line.
4. **Run it**, supplying sudo when prompted for the wired-limit step.
5. **Acquire the model(s).** Once you've verified the exact repo ID, download the primary model into `~/models` (via `hf download` or the `/admin` downloader). Confirm it loads.
6. **Pin + alias** the primary model in the `/admin` panel (alias `coding-fast`) — pinning is panel-only, not a CLI flag, so do it via the API/UI or tell me the exact manual step if it can't be scripted.
7. **Validate the endpoint** — `curl` `http://localhost:8000/v1/models` with the API key, then a small `/v1/chat/completions` call, and a **tool-calling** call to confirm the model emits well-formed `tool_call` markup (the orchestrator depends on this; flag if the parser needs configuration).

## Deliverables

- A working, pinned oMLX server reachable at `http://localhost:8000/v1` (and `/v1/messages` for Anthropic-style clients).
- The reviewed, shellcheck-clean setup script.
- An **ADR** (MADR minimal, in `adrs/`) recording the local-inference convention: runtime choice, model choice with the bandwidth/MoE rationale, and the serving config.
- A note on wiring my `IInferenceBackend` / `FallbackInferenceRouter` endpoint to this server (route `coding-fast` → primary; `coding-quality` → secondary if installed).
- An efficacy report.

Stop and show me your plan before executing anything that writes, installs, or runs.
