# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A provisioning project — not an application. It stands up **oMLX**
(`jundot/omlx`) as a local, OpenAI/Anthropic-compatible inference server on an
Apple Silicon **M5 Max (128 GB unified memory, macOS)**, tuned for a
**parallel-agent coding workload**: an orchestrator fans out 3+ concurrent agent
requests that share long system prefixes, so **concurrent throughput and
prefix-cache reuse matter more than single-stream tok/s**.

The current architecture: the Mac runs a **single pinned workhorse model** (one
3B-active MoE), with a **cloud provider as the quality frontier** — decided in
[`adrs/009-mac-single-workhorse-cloud-frontier.md`](adrs/009-mac-single-workhorse-cloud-frontier.md),
as amended by [`adrs/010-6bit-workhorse-sustained-mark.md`](adrs/010-6bit-workhorse-sustained-mark.md)
(quant 8-bit → **6-bit**, concurrency mark 10 → **8**).

Decision history — each ADR's `Status:` front-matter carries the supersession
chain; consult the ADRs rather than re-deriving it:

- **ADR-009** supersedes ADR-006 (three-tier co-resident lineup) and ADR-008
  (cross-host AMD routing; that appliance is repurposed — see
  [`docs/amd-augmentation-research.md`](docs/amd-augmentation-research.md)).
- **ADR-001** (oMLX runtime), **ADR-002** (`--memory-guard-gb` migration +
  wired limit), **ADR-005** (on-demand lifecycle), and **ADR-007** (CI gate,
  rulesets, deferred semantic-release) carry forward unchanged.

The authoritative brief is
[`macos/local-llm-mac-os-creation.md`](macos/local-llm-mac-os-creation.md);
model-selection research is in
[`docs/runtime-tiering-research.md`](docs/runtime-tiering-research.md); on-host
probe results (long-context MLA, `enable_thinking`, sustained concurrency,
Neural Accelerator engagement) are in
[`docs/workhorse-probes.md`](docs/workhorse-probes.md). `omlx-setup-prompt.md`
is retained only as the historical source prompt; do not copy it forward as an
additional source of truth.

## Commands

The deliverable is `setup-omlx-m5.sh` (idempotent; author-side, run by the user):

```bash
./setup-omlx-m5.sh                  # preflight + install + dirs + key + wired-limit + service + omlxctl (no model download; server NOT started)
./setup-omlx-m5.sh --download-model # also fetch the workhorse model (~24 GB) via hf
./setup-omlx-m5.sh --configure-pi   # register the oMLX provider with the Pi coding agent (~/.pi/agent/models.json)
./setup-omlx-m5.sh --validate       # endpoint checks (models / chat / tool-call / Anthropic / 2-way concurrency) against a running server
./setup-omlx-m5.sh --verbose --help
```

`--validate` short-circuits `main()`: it runs *only* the endpoint checks and
exits — no preflight and no install steps run, even when combined with other
flags.

The server is **on-demand** (it does not start at login, and setup does not start
it). Start/stop it intentionally with the installed `omlxctl` tool (ADR-005):

```bash
omlxctl start    # kickstart + wait for /health  |  omlxctl stop    # SIGTERM→SIGKILL(30s), release memory
omlxctl restart  # atomic restart + wait         |  omlxctl status  # launchd + /health state (warns on 0 models) |  omlxctl logs
```

Exit codes: `0` pass, `1` errors, `2` precondition failure. The Metal
wired-limit step needs `sudo`. The workhorse alias + pin is applied via the
**oMLX admin API** (`apply_pins` briefly starts the server, PUTs the model's
settings — and **unpins any retired ADR-006 tiers** it finds registered, renaming
the 8-bit to alias `workhorse-8b` so the primary alias transfers — then stops
it; `model_settings.json` is oMLX-owned, so the script never writes it
directly); it degrades to printed manual admin-panel steps if the API can't be
reached (ADR-009).

Preflight hard-fails with exit `2` for non-macOS, non-arm64, RAM below ~120 GB,
free disk below ~90 GB, or missing Homebrew. M5 Max is the tuned target; a
non-M5 Apple Silicon chip warns instead of hard-failing so nearby Max-class hosts
can still smoke-test deliberately.

### Local CI checks

CI (`validate.yml`) runs three checks; reproduce them locally before pushing
(use the `linter` agent for the shellcheck pass when available):

```bash
shellcheck --severity=warning setup-omlx-m5.sh templates/omlx-start-wrapper.sh templates/omlxctl
markdownlint-cli2 "**/*.md"     # config auto-discovered from .markdownlint-cli2.jsonc
# plist XML well-formedness: run the python3 stdlib check inline in validate.yml
```

`--severity=warning` (mirrored in `.shellcheckrc` for local runs) keeps the
intentional info-level idioms (`A && B || true`, `((counter++)) || true`) from
failing the gate.

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
something better has shipped, propose it in the plan rather than substituting
silently. The setup script also probes the configured repo IDs immediately
before `hf download`, but that existence check does not replace the operator's
best-current-model review.

- **Runtime:** oMLX via Homebrew —
  `brew tap jundot/omlx https://github.com/jundot/omlx && brew install omlx`.
  The formula is `brew pin`ned at the version tracked by `upstream-watch.yml`'s
  `KNOWN_STABLE` while the 0.5.x regression gate holds (the deferred upgrade is
  tracked in #39).
- **Model (single workhorse, text-only; ADR-009 lineup, ADR-010 quant):**
  **`coding-workhorse`** — `mlx-community/GLM-4.7-Flash-6bit`
  (`Glm4MoeLiteForCausalLM`, MoE ~3B active, 202K ctx, MLA KV compression).
  ~24 GB on disk. **Pinned, sole resident model** — one pinned model gives the
  fan-out one shared prefix cache and never exercises oMLX's multi-model swap
  path. A verified text-only coder build (`*ForCausalLM`, no `vision_config`)
  and tool-call-verified on oMLX, so it routes to the batched LLM engine with
  **no engine override**. Quality parity with the 8-bit and the measured
  sustained-load footprint/margin are recorded in ADR-010 and
  `docs/workhorse-probes.md` — cite those, don't restate the numbers. The
  DFlash speculative-decoding engine's private SSD cache stays disabled
  (`dflash_ssd_cache=false`; DFlash itself is never engaged) — the **main** SSD
  prefix cache (`--paged-ssd-cache-dir`) stays on; its live upstream risk is
  oMLX #702 (the memory guard tracks Metal allocations, not cache RSS).
  **Retired models** (`GLM-4.7-Flash-8bit`, plus ADR-006's
  `Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` and `Qwen3-Coder-Next-MLX-4bit`) are
  never downloaded/aliased/validated; setup actively unpins them if a prior
  install left them pinned (see the `apply_pins` note under Commands). The
  **8-bit stays on disk as the primary inactive fallback** (quality-parity-tested
  rollback: pin swap + restart), Qwen3-Coder-30B as the secondary. GLM emits a
  reasoning preamble — tool-bearing requests need `max_tokens ≥ ~200`
  (validation uses 256).
- **Serving flags:** `--host 127.0.0.1` (explicit loopback pin), port `8000`,
  `--memory-guard-gb 90` (replaces the removed `--max-process-memory`),
  `--paged-ssd-cache-dir ~/.omlx/cache`, `--paged-ssd-cache-max-size 50GB` (oMLX
  defaults the SSD tier to 100 GB — past the preflight's 90 GB free-disk budget;
  50 GB keeps model + cache inside it with ~16 GB slack),
  `--hot-cache-max-size 24GB` (oMLX accepts
  both absolute sizes and percentages; we pin an absolute value ≈ 27% of the guard
  for a deterministic footprint — one model, no second cache to fund),
  `--max-concurrent-requests 8` (ADR-010's **sustained** Mark: ADR-009's burst
  figure of 10 collapses under back-to-back fan-out — enforcer dynamic-ceiling +
  prefix-cache-eviction spiral, HTTP-400 storms; 8 runs sustained-clean and
  excess requests queue at admission), `--api-key` from the 0600 file.
- **Metal wired limit:** raise `iogpu.wired_limit_mb` to ~96 GB (98304); persist
  across reboot via a LaunchDaemon (sudo). The daemon stays loaded even when the
  server is stopped — it is a ceiling, not a reservation, and costs no memory idle.
- **macOS floor and ceiling:** MLX engages the M5 GPU **Neural Accelerators**
  only on **macOS ≥ 26.2** (verified engaged on-host — probe 4 in
  `docs/workhorse-probes.md`). Hold the host at **macOS 26.x** — do not
  upgrade to macOS 27 while jundot/omlx#1835 (10–15× long-context slowdown,
  suspected paged-cache-tier interaction) is open; re-run the probe suite after
  any macOS or oMLX upgrade.
- **On-demand lifecycle (no login autostart):** per-user LaunchAgent running a start
  wrapper that carries the tuned flags (`brew services` only starts with zero-config
  defaults). The agent is `RunAtLoad=false` + `KeepAlive=false`, so login registers
  the job but never starts it, and a stop/crash stays down (no respawn; zero idle
  footprint — see the ADR-005 addendum for the crash-loop history that motivated
  this). Start/stop is intentional via `omlxctl`
  (`kickstart` / `kill SIGTERM`→`SIGKILL` after 30s / `kickstart -k`); setup leaves
  the server stopped (ADR-005).

## Layout

- `setup-omlx-m5.sh` — the provisioning script. Installs oMLX (no MCP);
  creates `~/models`, `~/.omlx/{cache,logs,bin}`; generates the 0600 API key;
  sets + persists the wired limit; installs the start wrapper + LaunchAgent (on-
  demand, RunAtLoad=false) + the `omlxctl` control tool (symlinked onto PATH when
  the brew bin is writable); downloads the workhorse model when **download is
  opt-in (default off)**, skipping it if already present (upgrade-safe); applies
  the alias + pin via the admin API and leaves the server stopped;
  `--configure-pi` registers the provider with the Pi coding agent.
  No engine override step — the workhorse is text-only (ADR-009).
- `templates/` — committed templates the script installs with placeholder
  substitution: `omlx-start-wrapper.sh`, the `com.local.omlx.plist` LaunchAgent,
  the `com.local.iogpu-wired-limit.plist` root LaunchDaemon, `omlxctl` (the
  on-demand control tool — static, no placeholders, installed to `~/.omlx/bin`),
  and `pi-models-omlx.json` (the Pi coding-agent provider block).
- `.claude/agents/*.md` + `.github/agents/*.agent.md` — repository-resident
  read-only/advisory domain agents, each in both Claude Code and GitHub Copilot
  wrapper formats (keep each pair in sync). They stay repo-resident (not promoted to
  a global catalog) until the planned `claude-config` split — see the memory
  `claude-config-framework-split`. Current set:
  - `omlx-expert` — oMLX runtime + MLX model selection + Apple-Silicon memory tuning.
  - `amd-inference-expert` — AMD AI hardware/APIs: Ryzen/Radeon/Instinct, ROCm/HIP,
    vLLM-on-ROCm, llama.cpp HIP/Vulkan (the AMD appliance's gfx1100 / vLLM stack).
  - `apple-silicon-inference-expert` — Apple Silicon hardware/APIs: M-series
    CPU/GPU/ANE, unified memory, Metal/MPS, MLX, Core ML (the layer beneath oMLX;
    `omlx-expert` owns runtime specifics). Spec: `docs/inference-expert-agents.md`.
- `.github/workflows/` — `validate.yml` (shellcheck + markdownlint + plist
  well-formedness; see Local CI checks above), `lint-pr-title.yml` (Conventional
  Commits PR title), and `upstream-watch.yml` (weekly watch for upstream oMLX
  events that files idempotent tracking issues — not a required check). The
  `validate` and `lint-pr-title` job names are required-check contexts on the
  `protect-dev`/`protect-main` rulesets — renaming a job breaks its ruleset
  binding (ADR-007). The workflow files carry their own config comments.
- `adrs/` — decision records (MADR minimal template in `TEMPLATE.md`; sequential,
  zero-padded three digits). ADR-009 + ADR-010 are the current lineup decision;
  each file's `Status:` line carries the supersession chain (see "What this
  repository is" above).
- `docs/router-wiring.md` — wiring the server into the .NET `IInferenceBackend` /
  `FallbackInferenceRouter`.
- `docs/workhorse-probes.md` — one-time on-host probes to run before trusting the
  workhorse config under load; re-run after any macOS or oMLX upgrade.
- `docs/amd-augmentation-research.md` — research note on reopening the AMD
  RX 7900 XTX host as a **secondary augmentation** (not an ADR-008-style routing
  peer): eval/CI farm first, overflow lane gated on the exact guard-reject 400
  (never Mac-unreachable), GLM-4.7-Flash disqualified on gfx1100 —
  Qwen3-Coder-30B-A3B Q4 is the overflow model. Assessment only; the decision
  record would be a new ADR amending 009.
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

`check_omlx_cli()` probes `omlx serve --help` for every serving flag the wrapper
uses before `install_service` will register the LaunchAgent; if any flag is
missing (oMLX CLI drift), registration is **skipped entirely** with a recorded
error — the first place to look when "why wasn't the LaunchAgent installed."

### Runtime artifacts (created on the host, never committed)

- `~/.omlx/` (chmod 700) containing `api-key` (0600), `bin/` (start wrapper +
  `omlxctl`), `cache/`, `logs/`, `pi-provider-snippet.json` (rendered by
  `--configure-pi`), and `settings.json` — **oMLX-managed and it contains a copy
  of the API key** at `.auth.api_key` because oMLX persists its CLI args; the
  script chmods it 0600.
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
`IInferenceBackend` / `FallbackInferenceRouter`: fast/balanced roles →
`coding-workhorse` (the single pinned local model); the quality role → the
**cloud frontier** provider, never a local tier (see `docs/router-wiring.md`).
Tool-bearing requests need `max_tokens ≥ ~200` — GLM emits a reasoning preamble
before the tool call (validation uses 256).

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

# 4. Remove data (the API key + cache/logs, the workhorse, and any fallback/
#    retired models still on disk)
rm -rf ~/.omlx          # includes the 0600 api-key
rm -rf ~/models/GLM-4.7-Flash-6bit
rm -rf ~/models/GLM-4.7-Flash-8bit \
       ~/models/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit \
       ~/models/Qwen3-Coder-Next-MLX-4bit   # fallbacks/retired tiers, if present
```

## Scripts

Any shell script follows the global Script Output Conventions: 6-char labels,
`ok`/`skip`/`warn`/`info`/`err`/`detail` helpers, `((counter++)) || true`, exit
codes 0/1/2, `set -euo pipefail`, and a summary block. Use `shell-expert` for the
script and `linter` for the shellcheck pass.
