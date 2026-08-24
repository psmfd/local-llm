# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A provisioning project — not an application. It stands up **oMLX**
(`jundot/omlx`) as a local, OpenAI/Anthropic-compatible inference server on an
Apple Silicon **M5 Max (128 GB unified memory, macOS)**, tuned for a
**serial workflow coding workload**: one request in flight at a time, each
step's output feeding the next as a growing transcript, so **single-stream
decode, prefill speed, and turn-over-turn prefix-cache reuse matter — there is
no concurrent fan-out** (ADR-013 retired the ADR-009-era parallel premise).

The current architecture: the Mac runs a **single pinned workhorse model**
(gpt-oss-120b-4bit, a 5.1B-active MoE), with a **cloud provider as the quality
frontier** — structure decided in
[`adrs/009-mac-single-workhorse-cloud-frontier.md`](adrs/009-mac-single-workhorse-cloud-frontier.md),
model and serial serving shape decided in
[`adrs/013-gptoss-serial-workhorse.md`](adrs/013-gptoss-serial-workhorse.md)
(workhorse GLM-4.7-Flash-6bit → **gpt-oss-120b-4bit**, concurrency mark 4 →
**1**, pi contextWindow 76800 → **122880**; evidence in
[#73](https://github.com/psmfd/local-llm/issues/73)). The GLM-era amendments —
[`adrs/010`](adrs/010-6bit-workhorse-sustained-mark.md) (6-bit quant),
[`adrs/011`](adrs/011-pi-context-window-guard-boundary.md) (guard-bound
contextWindow), [`adrs/012`](adrs/012-concurrency-mark-4-large-context.md)
(mark 4, maxTokens 8192) — are amended by ADR-013; only the maxTokens 8192
decision carries forward, and the GLM-6bit configuration they describe remains
the documented primary-fallback rollback.

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
./setup-omlx-m5.sh --download-model # also fetch the workhorse model (~66 GB) via hf
./setup-omlx-m5.sh --configure-pi   # register the oMLX provider with the Pi coding agent (~/.pi/agent/models.json)
./setup-omlx-m5.sh --validate       # endpoint checks (models / chat / tool-call / Anthropic / 2-way concurrency / effective cache mode) against a running server
./setup-omlx-m5.sh --verbose --help
```

`--validate` short-circuits `main()`: it runs *only* the endpoint checks and
exits — no preflight and no install steps run, even when combined with other
flags. (`--download-model` now fetches ~66 GB — the gpt-oss workhorse.)

The server is **on-demand** (it does not start at login, and setup does not start
it). Start/stop it intentionally with the installed `omlxctl` tool (ADR-005):

```bash
omlxctl start    # kickstart + wait for /health  |  omlxctl stop    # SIGTERM→SIGKILL(30s), release memory
omlxctl restart  # atomic restart + wait         |  omlxctl status  # launchd + /health state (warns on 0 models) |  omlxctl logs
```

Exit codes: `0` pass, `1` errors, `2` precondition failure. The Metal
wired-limit step needs `sudo`. The workhorse alias + pin is applied via the
**oMLX admin API** (`apply_pins` briefly starts the server, PUTs the model's
settings — and **unpins any retired tiers** it finds registered, renaming the
GLM-6bit to alias `workhorse-glm` (and the 8-bit to `workhorse-8b`) so the
primary alias transfers to gpt-oss — then stops it; `model_settings.json` is
oMLX-owned, so the script never writes it directly); it degrades to printed
manual admin-panel steps if the API can't be reached (ADR-009/013).

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
  `KNOWN_STABLE` (0.5.7 — upgraded 2026-08-15 after the full probe gauntlet
  passed; brew auto-cleanup removed the older kegs, so rollback is via the
  tap-formula history: `git checkout a20d60de -- Formula/omlx.rb` in
  `$(brew --repository jundot/omlx)`, then `brew reinstall omlx`). Re-run the
  probe suite
  before trusting any future bump.
- **Model (single workhorse, text-only; ADR-009 structure, ADR-013 model):**
  **`coding-workhorse`** — `mlx-community/gpt-oss-120b-4bit`
  (`GptOssForCausalLM`, MoE 117B total / 5.1B active, native 131,072 ctx,
  alternating sliding-window(128)/full attention, 8-head GQA — KV
  ~0.070 GB/1K). ~66 GB on disk (61.56 GB resident measured). **Pinned, sole
  resident model** — never exercises oMLX's multi-model swap path. A verified
  text-only build (`*ForCausalLM`, no `vision_config`) routed to the batched
  LLM engine with **no engine override**; Harmony tool calling verified 58/58
  on oMLX 0.5.7, HumanEval 95.7% vs the GLM incumbent's 83.5% (McNemar
  p=0.00018), and a 4-hour serial soak clean — all recorded in ADR-013 and
  [#73](https://github.com/psmfd/local-llm/issues/73); cite those, don't
  restate the numbers. The DFlash speculative-decoding engine stays disengaged
  (`dflash_ssd_cache=false`; no DFlash draft exists for either the current or
  the fallback workhorse — #71) — the **main** SSD prefix cache
  (`--paged-ssd-cache-dir`) stays on; its live upstream risk is oMLX #702
  (the memory guard tracks Metal allocations, not cache RSS). **Retired
  models** (`GLM-4.7-Flash-6bit`, `GLM-4.7-Flash-8bit`, plus ADR-006's
  `Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` and `Qwen3-Coder-Next-MLX-4bit`) are
  never downloaded/aliased/validated; setup actively unpins them if a prior
  install left them pinned (see the `apply_pins` note under Commands). The
  **GLM-6bit stays on disk as the primary inactive fallback** (full ADR-009/010
  probe history; rollback = pin swap + restore GLM-era flags + restart — and
  restoring parallel fan-out serving requires exactly this rollback, since
  gpt-oss's weights leave no multi-stream KV pool). gpt-oss emits a Harmony
  reasoning channel before answers/tool calls — tool-bearing requests need
  generous `max_tokens` (validation uses 512); reasoning effort is controlled
  via `chat_template_kwargs: {"reasoning_effort": "low|medium|high"}` (default
  medium — the top-level `reasoning_effort` param is **ignored** by oMLX
  0.5.7; client delivery via pi payload-tuner, pi_config#1052).
- **Serving flags:** `--host 127.0.0.1` (explicit loopback pin), port `8000`,
  `--memory-guard-gb 90` (replaces the removed `--max-process-memory`),
  `--paged-ssd-cache-dir ~/.omlx/cache`, `--paged-ssd-cache-max-size 50GB`
  (oMLX defaults the SSD tier to 100 GB; 50 GB keeps model + cache inside the
  preflight's 130 GB free-disk budget), `--hot-cache-max-size 8GB` (the
  gpt-oss weights leave no room for the GLM-era 24 GB tier under the ~73 GB
  dynamic ceiling; 8 GB validated by the ADR-013 soak — prefix reuse 0.980),
  `--max-concurrent-requests 1` (ADR-013's **serial** mark: the host serves
  one request at a time by design, and the flag turns that client assumption
  into a server-enforced invariant — a double-fired step or stray second
  client queues at admission, consuming no KV; restoring parallel serving is a
  model rollback, not a flag tweak), `--api-key` from the 0600 file. The pi
  provider advertises `contextWindow 122880` (native 131,072 minus the 8,192
  decode reservation — the model's position limit, not the guard, binds;
  ADR-013) and `maxTokens 8192` (ADR-012, carried forward). Deep transcripts
  should compact around ~60K tokens — past that the enforcer brushes soft
  pressure and can transiently pause prefill (benign, self-recovering).
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
  zero-padded three digits). ADR-009 (structure) + ADR-013 (serial
  architecture, gpt-oss workhorse, mark 1, contextWindow 122880) are the
  current lineup decision; ADR-010/011/012 are the amended GLM-era parameters
  (the documented fallback configuration); each file's `Status:` line carries
  the supersession chain (see "What this repository is" above).
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
- `probes/thinking-ab/` — committed harness + raw results behind the probe-2
  thinking-suppression ratification (#44): `enable_thinking` on/off tool-call
  fidelity A/B against a running server. Re-run after any model or quant change.
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
`--validate` mode runs all six):

1. `GET /v1/models` with the API key.
2. A small `/v1/chat/completions` call.
3. A **tool-calling** call confirming the model emits well-formed `tool_call`
   markup (Harmony parsing on oMLX) — the orchestrator depends on this; flag
   if the parser needs config.
4. An **admission-queueing probe** (two parallel completions against the
   serial mark of 1) — the second request must queue at admission and
   complete, verifying the serial invariant degrades gracefully.
5. A `POST /v1/messages` call confirming the Anthropic-style endpoint is reachable.
6. An **effective cache-mode check**: the running instance's
   `PagedSSDCacheManager initialized:` log line must carry `hot_cache=` —
   absent means the RAM tier is silently off (the 2026-07-11 #42 incident
   signature; the `paged SSD-only mode` scheduler line appears in healthy runs
   too and is NOT diagnostic). Setup's `converge_settings` step repairs
   persisted `settings.json` drift against the wrapper flags (server stopped);
   `apply_pins` additionally unpins any STRAY pin outside the tier lineup
   (#43, sole-resident invariant), warning loudly by name.

Anthropic-style clients use `/v1/messages`. The downstream consumer is an
`IInferenceBackend` / `FallbackInferenceRouter`: fast/balanced roles →
`coding-workhorse` (the single pinned local model); the quality role → the
**cloud frontier** provider, never a local tier (see `docs/router-wiring.md`).
Tool-bearing requests need generous `max_tokens` — gpt-oss emits a Harmony
reasoning channel before the tool call (validation uses 512). Under the serial
mark, a prefill-guard 400 means "this one request is genuinely too big —
compact and resubmit," not concurrency contention.

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
rm -rf ~/models/gpt-oss-120b-4bit
rm -rf ~/models/GLM-4.7-Flash-6bit \
       ~/models/GLM-4.7-Flash-8bit \
       ~/models/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit \
       ~/models/Qwen3-Coder-Next-MLX-4bit   # fallbacks/retired tiers, if present
```

## Scripts

Any shell script follows the global Script Output Conventions: 6-char labels,
`ok`/`skip`/`warn`/`info`/`err`/`detail` helpers, `((counter++)) || true`, exit
codes 0/1/2, `set -euo pipefail`, and a summary block. Use `shell-expert` for the
script and `linter` for the shellcheck pass.
