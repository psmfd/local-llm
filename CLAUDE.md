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
the current model-lineup decision is [`adrs/006-multi-tier-coresident-lineup-stay-on-omlx.md`](adrs/006-multi-tier-coresident-lineup-stay-on-omlx.md)
(two co-resident pinned tiers + one on-demand max tier; stay on oMLX), which
supersedes [`adrs/004-single-text-only-model-no-override.md`](adrs/004-single-text-only-model-no-override.md)
and, through it, [`adrs/003-vlm-engine-workaround-lineup.md`](adrs/003-vlm-engine-workaround-lineup.md)
and [`adrs/002-qwen36-lineup-memory-guard.md`](adrs/002-qwen36-lineup-memory-guard.md)
(whose `--memory-guard-gb` migration, wired limit, and concurrency carry forward)
and [`adrs/001-local-mlx-inference-omlx.md`](adrs/001-local-mlx-inference-omlx.md)
(whose oMLX runtime choice is reaffirmed by ADR-006). The full investigation —
runtime reassessment, on-host bake-off, and tier selection — is in
[`docs/runtime-tiering-research.md`](docs/runtime-tiering-research.md).
`omlx-setup-prompt.md` is retained only as the historical source prompt; do not
copy it forward as an additional source of truth.

## Commands

The deliverable is `setup-omlx-m5.sh` (idempotent; author-side, run by the user):

```bash
./setup-omlx-m5.sh                  # preflight + install + dirs + key + wired-limit + service + omlxctl (no model download; server NOT started)
./setup-omlx-m5.sh --download-model # also fetch the model (~32 GB) via hf
./setup-omlx-m5.sh --configure-pi   # register the oMLX provider with the Pi coding agent (~/.pi/agent/models.json)
./setup-omlx-m5.sh --validate       # endpoint checks (models / chat / tool-call / Anthropic / 2-way concurrency) against a running server
./setup-omlx-m5.sh --verbose --help
```

The server is **on-demand** (it does not start at login, and setup does not start
it). Start/stop it intentionally with the installed `omlxctl` tool (ADR-005):

```bash
omlxctl start    # kickstart + wait for /health  |  omlxctl stop    # SIGTERM→SIGKILL(30s), release memory
omlxctl restart  # atomic restart + wait         |  omlxctl status  # launchd + /health state (warns on 0 models) |  omlxctl logs
```

Exit codes: `0` pass, `1` errors, `2` precondition failure. Lint with the
`linter` agent (shellcheck). The Metal wired-limit step needs `sudo`. Aliases +
pins are applied via the **oMLX admin API** (`apply_pins` briefly starts the
server, PUTs each tier's settings, then stops it — `model_settings.json` is
oMLX-owned, so the script never writes it directly); it degrades to printed
manual admin-panel steps if the API can't be reached (ADR-006).

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
- **Models (three tiers, all text-only; ADR-006):** every tier is a verified
  text-only coder build (`*ForCausalLM`, no `vision_config`) and tool-call-verified
  on oMLX, so each routes to the batched LLM engine with **no engine override**.
  - **T1 `coding-fast`** — `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit`
    (`Qwen3MoeForCausalLM`, MoE ~3B active, 262K ctx). ~30.6 GB. **Pinned, co-resident.**
  - **T2 `coding-balanced`** — `mlx-community/GLM-4.7-Flash-8bit`
    (`Glm4MoeLiteForCausalLM`, MoE ~3B active, 202K ctx). ~30 GB. **Pinned, co-resident.**
  - **MAX `coding-quality`** — `lmstudio-community/Qwen3-Coder-Next-MLX-4bit`
    (`Qwen3NextForCausalLM`, 80B/~3B active, ~71% SWE-bench). ~45 GB. **On-demand**
    (lazy-loads ~16 s on first request, idle-evicts; NOT pinned — it does not
    co-reside alongside T1+T2 under the wired ceiling).
  T1+T2 stay co-resident (~60 GB) leaving ~29 GB for KV/prefix cache under the
  96 GB wired ceiling, so the fan-out never pays a swap cost. DFlash SSD cache is
  disabled on every tier (oMLX #702/#1892).
- **Serving flags:** `--host 127.0.0.1` (explicit loopback pin), port `8000`,
  `--memory-guard-gb 90` (replaces the removed `--max-process-memory`),
  `--paged-ssd-cache-dir ~/.omlx/cache`, `--hot-cache-max-size 18GB` (oMLX accepts
  both absolute sizes and percentages; we pin an absolute value ≈ 20% of the guard
  for a deterministic footprint), `--max-concurrent-requests 16` (oMLX default is
  8), `--api-key` from the 0600 file.
- **Metal wired limit:** raise `iogpu.wired_limit_mb` to ~96 GB (98304); persist
  across reboot via a LaunchDaemon (sudo). The daemon stays loaded even when the
  server is stopped — it is a ceiling, not a reservation, and costs no memory idle.
- **On-demand lifecycle (no login autostart):** per-user LaunchAgent running a start
  wrapper that carries the tuned flags (`brew services` only starts with zero-config
  defaults). The agent is `RunAtLoad=false` + `KeepAlive=false`, so login registers
  the job but never starts it, and a stop/crash stays down (no respawn — avoids the
  oMLX issue #15 GPU-hang crash loop). Start/stop is intentional via `omlxctl`
  (`kickstart` / `kill SIGTERM`→`SIGKILL` after 30s / `kickstart -k`); setup leaves
  the server stopped (ADR-005).

## Layout

- `setup-omlx-m5.sh` — the provisioning script. Installs oMLX (no MCP);
  creates `~/models`, `~/.omlx/{cache,logs,bin}`; generates the 0600 API key;
  sets + persists the wired limit; installs the start wrapper + LaunchAgent (on-
  demand, RunAtLoad=false) + the `omlxctl` control tool (symlinked onto PATH when
  the brew bin is writable); downloads the three tiers when **download is opt-in
  (default off)**, skipping any already present (upgrade-safe); applies aliases +
  pins via the admin API (`apply_pins`, start→pin→stop) and leaves the server
  stopped; `--configure-pi` registers the provider with the Pi coding agent.
  No engine override step — all tiers are text-only (ADR-006).
- `templates/` — committed templates the script installs with placeholder
  substitution: `omlx-start-wrapper.sh`, the `com.local.omlx.plist` LaunchAgent,
  the `com.local.iogpu-wired-limit.plist` root LaunchDaemon, `omlxctl` (the
  on-demand control tool — static, no placeholders, installed to `~/.omlx/bin`),
  and `pi-models-omlx.json` (the Pi coding-agent provider block).
- `.claude/agents/omlx-expert.md` + `.github/agents/omlx-expert.agent.md` —
  repository-resident `omlx-expert` domain agent (oMLX runtime + MLX model
  selection + Apple-Silicon memory tuning), read-only/advisory, in both Claude
  Code and GitHub Copilot wrapper formats. Keep the two wrappers in sync.
- `.github/workflows/` — CI lint gate (`validate.yml`: shellcheck + markdownlint +
  plist well-formedness; `lint-pr-title.yml`: Conventional Commits PR title). The
  `validate` and `lint-pr-title` job names are required-check contexts on the
  `protect-dev`/`protect-main` rulesets — renaming a job breaks its ruleset binding
  (`007`). `.markdownlint-cli2.jsonc` (repo root) configures the markdown step.
- `adrs/` — `006-multi-tier-coresident-lineup-stay-on-omlx.md` records the current
  model lineup (superseding `004`, which superseded `003` → `002` → `001`; the
  `--memory-guard-gb`/wired-limit/concurrency from `002` and the oMLX runtime from
  `001` carry forward); `005-on-demand-service-lifecycle.md` records the on-demand
  start/stop lifecycle (no login autostart) — additive, still in force under `006`;
  `007-ci-rulesets-and-release-strategy.md` records the CI gate, branch-protection
  rulesets, and the deferred-`semantic-release` decision; `TEMPLATE.md` is the MADR
  minimal template for new ADRs (sequential, zero-padded three digits). The model
  decision rationale lives in `docs/runtime-tiering-research.md`.
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
  `bin/omlxctl` (the on-demand control tool), `cache/`, `logs/`,
  `pi-provider-snippet.json` (rendered by `--configure-pi`), and
  `settings.json` (oMLX-managed; **contains a copy of the API key** at
  `.auth.api_key` because oMLX persists its CLI args — the script chmods it 0600)
- `$(brew --prefix)/bin/omlxctl` — symlink to `~/.omlx/bin/omlxctl`, created only
  when the brew bin is writable (otherwise the script prints the manual `ln`/PATH step)
- `~/models/` — downloaded MLX model directories
- `~/Library/LaunchAgents/com.local.omlx.plist` (per-user; RunAtLoad=false)
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
`IInferenceBackend` / `FallbackInferenceRouter`: `coding-fast` and `coding-balanced`
→ co-resident local models; `coding-quality` → the local on-demand max tier
(Qwen3-Coder-Next, lazy-loaded), with a remote backend as fallback (see
`docs/router-wiring.md`).

## Teardown

There is no `--uninstall` flag; reverse the steps manually:

```bash
# 1. Stop the server, then remove the per-user LaunchAgent + omlxctl symlink
omlxctl stop 2>/dev/null || true
launchctl bootout gui/$(id -u)/com.local.omlx 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.local.omlx.plist
rm -f "$(brew --prefix)/bin/omlxctl"   # the on-PATH symlink, if it was created

# 2. Stop + remove the root LaunchDaemon (wired limit reverts to the OS default at next boot)
sudo launchctl bootout system/com.local.iogpu-wired-limit 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.local.iogpu-wired-limit.plist

# 3. Uninstall oMLX
brew uninstall omlx && brew untap jundot/omlx

# 4. Remove data (the API key + cache/logs, and the three model tiers)
rm -rf ~/.omlx          # includes the 0600 api-key
rm -rf ~/models/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit \
       ~/models/GLM-4.7-Flash-8bit \
       ~/models/Qwen3-Coder-Next-MLX-4bit
```

## Scripts

Any shell script follows the global Script Output Conventions: 6-char labels,
`ok`/`skip`/`warn`/`info`/`err`/`detail` helpers, `((counter++)) || true`, exit
codes 0/1/2, `set -euo pipefail`, and a summary block. Use `shell-expert` for the
script and `linter` for the shellcheck pass.
