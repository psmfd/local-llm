# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A provisioning project — not an application. The goal is to stand up **oMLX**
(`jundot/omlx`) as a local, OpenAI/Anthropic-compatible inference server on an
Apple Silicon **M5 Max (128 GB unified memory, macOS)**, tuned for a
**parallel-agent coding workload**: an orchestrator fans out 3+ concurrent agent
requests that share long system prefixes, so **concurrent throughput and
prefix-cache reuse matter more than single-stream tok/s**.

The authoritative brief is [`macos/local-llm-mac-os-creation.md`](macos/local-llm-mac-os-creation.md);
the decision record is [`adrs/004-single-text-only-model-no-override.md`](adrs/004-single-text-only-model-no-override.md)
(single text-only model, override retired), which supersedes
[`adrs/003-vlm-engine-workaround-lineup.md`](adrs/003-vlm-engine-workaround-lineup.md)
and, through it, [`adrs/002-qwen36-lineup-memory-guard.md`](adrs/002-qwen36-lineup-memory-guard.md)
(whose `--memory-guard-gb` migration, wired limit, and concurrency carry forward)
and [`adrs/001-local-mlx-inference-omlx.md`](adrs/001-local-mlx-inference-omlx.md)
(whose runtime choice carries forward).
`omlx-setup-prompt.md` is retained only as the historical source prompt; do not
copy it forward as an additional source of truth.

## Commands

The deliverable is `setup-omlx-m5.sh` (idempotent; author-side, run by the user):

```bash
./setup-omlx-m5.sh                  # preflight + install + dirs + key + wired-limit + service (no model download)
./setup-omlx-m5.sh --download-model # also fetch the model (~32 GB) via hf
./setup-omlx-m5.sh --configure-pi   # register the oMLX provider with the Pi coding agent (~/.pi/agent/models.json)
./setup-omlx-m5.sh --validate       # endpoint checks (models / chat / tool-call / Anthropic / 2-way concurrency) against a running server
./setup-omlx-m5.sh --verbose --help
```

Exit codes: `0` pass, `1` errors, `2` precondition failure. Lint with the
`linter` agent (shellcheck). The Metal wired-limit step needs `sudo`. Pinning +
aliasing is **admin-panel only** at `http://localhost:8000/admin` — the script
prints the manual steps; it cannot script them.

Preflight hard-fails with exit `2` for non-macOS, non-arm64, RAM below ~120 GB,
free disk below ~100 GB, or missing Homebrew. M5 Max is the tuned target; a
non-M5 Apple Silicon chip warns instead of hard-failing so nearby Max-class hosts
can still smoke-test deliberately.

## Hard constraints (project-specific)

- **No MCP.** Do not enable oMLX's MCP support (a separate `pip install mcp` plus
  `--mcp-config`), add `mcp-servers` anywhere, or reference MCP packages. Tool
  access stays explicit. (Reinforces the global no-mcp-servers rule for this
  runtime specifically.)
- **API key.** Generate it locally, store at `~/.omlx/api-key` with `chmod 600`.
  Never print it or commit it.
- **Idempotent.** Re-running the setup must detect and skip what already exists.
- **Plan-gate.** Stop and show the plan before anything that writes, installs, or
  runs — sudo is required for the Metal wired-limit step.

## Settled decisions (re-verify model availability before downloading)

The runtime and serving config are decided. **Re-verify the model choice and exact
HuggingFace MLX repo IDs against current availability** before any download; if
something better has shipped, propose it in the plan rather than substituting silently.
The setup script also probes the configured Hugging Face repo IDs immediately
before `hf download`, but that existence check does not replace the operator's
best-current-model review.

- **Runtime:** oMLX via Homebrew —
  `brew tap jundot/omlx https://github.com/jundot/omlx && brew install omlx`
- **Model (single, text-only):** Qwen3-Coder-30B-A3B-Instruct at 8-bit MLX
  (`lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit`; `Qwen3MoeForCausalLM`,
  MoE ~3B active → fast decode under the 614 GB/s bandwidth cap; 8-bit preserves
  tool-call JSON fidelity; 262,144-token native context, `rope_scaling` null).
  ~32 GB resident. Pin + alias as `coding-fast`. **No engine override:** it is
  verified text-only, so oMLX routes it to the batched LLM engine and it is
  concurrency-safe as-is (ADR-004). A single resident model keeps the whole
  KV/prefix-cache budget free for the fan-out — dropping a co-resident second
  model is the deliberate reason there is only one (ADR-004).
- **Serving flags:** `--host 127.0.0.1` (explicit loopback pin), port `8000`,
  `--memory-guard-gb 90` (replaces the removed `--max-process-memory`),
  `--paged-ssd-cache-dir ~/.omlx/cache`, `--hot-cache-max-size 18GB` (oMLX accepts
  both absolute sizes and percentages; we pin an absolute value ≈ 20% of the guard
  for a deterministic footprint), `--max-concurrent-requests 16` (oMLX default is
  8), `--api-key` from the 0600 file.
- **Metal wired limit:** raise `iogpu.wired_limit_mb` to ~96 GB (98304); persist
  across reboot via a LaunchDaemon (sudo).
- **Autostart:** per-user LaunchAgent running a start wrapper that carries the tuned
  flags (`brew services` only starts with zero-config defaults).

## Layout

- `setup-omlx-m5.sh` — the provisioning script. Installs oMLX (no MCP);
  creates `~/models`, `~/.omlx/{cache,logs,bin}`; generates the 0600 API key;
  sets + persists the wired limit; installs the start wrapper + LaunchAgent;
  **model download is opt-in (default off)**; `--configure-pi` registers the
  provider with the Pi coding agent. No engine override step — the model is
  text-only (ADR-004).
- `templates/` — committed templates the script installs with placeholder
  substitution: `omlx-start-wrapper.sh`, the `com.local.omlx.plist` LaunchAgent,
  the `com.local.iogpu-wired-limit.plist` root LaunchDaemon, and
  `pi-models-omlx.json` (the Pi coding-agent provider block).
- `.claude/agents/omlx-expert.md` + `.github/agents/omlx-expert.agent.md` —
  repository-resident `omlx-expert` domain agent (oMLX runtime + MLX model
  selection + Apple-Silicon memory tuning), read-only/advisory, in both Claude
  Code and GitHub Copilot wrapper formats. Keep the two wrappers in sync.
- `adrs/` — `004-single-text-only-model-no-override.md` records the current
  convention (superseding `003`, which superseded `002`, which superseded `001`);
  `TEMPLATE.md` is the MADR minimal template for new ADRs (sequential, zero-padded
  three digits).
- `docs/router-wiring.md` — wiring the server into the .NET `IInferenceBackend` /
  `FallbackInferenceRouter`.
- `README.md` — the public-facing quickstart (clone → run → validate → connect).
  Keep it in sync when flags, model IDs, or the step order change.

### Script architecture (read before editing `setup-omlx-m5.sh`)

The script is **error-accumulating, not fail-fast**. Only the preflight gate
exits hard (code `2`); every other step reports failures through `record_err`
(bumps `error_count`, exit `1` at the end) or `record_warn` (bumps `warn_count`,
non-fatal) and keeps going, so a single broken step does not abort the rest of
provisioning. The run ends with the standard summary block (`PASS`/`FAIL`).
Steps are independent functions gated by the `DO_*` flags from argument parsing;
each is idempotent (detects and skips what already exists). Templates in
`templates/` are installed via `render_template`, which does literal placeholder
substitution — edit the template file, not the rendered output.

### Runtime artifacts (created on the host, never committed)

- `~/.omlx/` (chmod 700) containing `api-key` (0600), `bin/omlx-start-wrapper.sh`,
  `cache/`, `logs/`, `pi-provider-snippet.json` (rendered by `--configure-pi`), and
  `settings.json` (oMLX-managed; **contains a copy of the API key** at
  `.auth.api_key` because oMLX persists its CLI args — the script chmods it 0600)
- `~/models/` — downloaded MLX model directories
- `~/Library/LaunchAgents/com.local.omlx.plist` (per-user)
- `/Library/LaunchDaemons/com.local.iogpu-wired-limit.plist` (root:wheel, sudo)
- `~/.pi/agent/models.json` — written by `--configure-pi` only when its
  `providers` object is empty (it lives in the user's version-controlled Pi
  config repo; otherwise the snippet + manual merge steps are printed)

## Endpoint validation

After the server is up, validate against `http://localhost:8000/v1` (the script's
`--validate` mode runs all five):

1. `GET /v1/models` with the API key.
2. A small `/v1/chat/completions` call.
3. A **tool-calling** call confirming the model emits well-formed `tool_call`
   markup — the orchestrator depends on this; flag if the parser needs config.
4. A **2-way concurrency probe** (two parallel completions) — a general health
   check that the batched LLM engine handles the fan-out this project serves.
5. A `POST /v1/messages` call confirming the Anthropic-style endpoint is reachable.

Anthropic-style clients use `/v1/messages`. The downstream consumer is an
`IInferenceBackend` / `FallbackInferenceRouter`: `coding-fast` → this local model;
the `coding-quality` role has no local model and falls through to a remote backend
(see `docs/router-wiring.md`).

## Teardown

There is no `--uninstall` flag; reverse the steps manually:

```bash
# 1. Stop + remove the per-user LaunchAgent
launchctl bootout gui/$(id -u)/com.local.omlx 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.local.omlx.plist

# 2. Stop + remove the root LaunchDaemon (wired limit reverts to the OS default at next boot)
sudo launchctl bootout system/com.local.iogpu-wired-limit 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.local.iogpu-wired-limit.plist

# 3. Uninstall oMLX
brew uninstall omlx && brew untap jundot/omlx

# 4. Remove data (the API key + cache/logs, and the model)
rm -rf ~/.omlx          # includes the 0600 api-key
rm -rf ~/models/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit
```

## Scripts

Any shell script follows the global Script Output Conventions: 6-char labels,
`ok`/`skip`/`warn`/`info`/`err`/`detail` helpers, `((counter++)) || true`, exit
codes 0/1/2, `set -euo pipefail`, and a summary block. Use `shell-expert` for the
script and `linter` for the shellcheck pass.
