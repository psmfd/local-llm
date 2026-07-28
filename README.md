# local-llm — oMLX provisioning for Apple Silicon

Stand up a **local, OpenAI/Anthropic-compatible LLM inference server** on an Apple Silicon Mac using [oMLX](https://github.com/jundot/omlx), tuned for **parallel AI coding agents** — multiple concurrent requests sharing long system prefixes, where concurrent throughput and prefix-cache reuse matter more than single-stream tok/s.

## TL;DR — start now

You need: an Apple Silicon Mac with **128 GB unified memory** (tuned for M5 Max; other Max-class chips warn but work), ~90 GB free disk (the workhorse model ≈ 24 GB, an SSD prefix-cache tier capped at 50 GB, plus staging slack), macOS, and [Homebrew](https://brew.sh). One step needs `sudo` (GPU wired-memory limit).

```bash
git clone https://github.com/psmfd/local-llm.git && cd local-llm
./setup-omlx-m5.sh --download-model   # install + configure + fetch the workhorse (~24 GB)
omlxctl start                         # start the server on demand (NOT at login)
./setup-omlx-m5.sh --validate         # smoke-test the running server
```

The server is **on-demand**: setup installs it but does not start it, and it does **not** start at login — startup is intentional. Start, stop, and reclaim memory with `omlxctl` (see [Starting and stopping](#starting-and-stopping)).

Then point any OpenAI-style client at `http://localhost:8000/v1` (or Anthropic-style at `/v1/messages`) with the API key from `~/.omlx/api-key`. Done.

The script is idempotent — re-running it skips whatever already exists. Run `./setup-omlx-m5.sh --help` for all flags.

## What the setup script does

`setup-omlx-m5.sh` performs, in order:

1. **Preflight** — hard-fails (exit `2`) on non-macOS, non-arm64, <~120 GB RAM, <~90 GB free disk, or missing Homebrew.
2. **Installs oMLX** via `brew tap jundot/omlx && brew install omlx` (no MCP — tool access stays explicit).
3. **Creates directories** — `~/models`, `~/.omlx/{cache,logs,bin}` (`~/.omlx` is chmod 700).
4. **Generates an API key** at `~/.omlx/api-key` (chmod 600, never printed).
5. **Raises the Metal wired limit** to ~96 GB so the GPU can hold the model resident, persisted across reboots via a root LaunchDaemon (**the sudo step**).
6. **Installs on-demand service control** — a start wrapper carrying the tuned serving flags, a per-user LaunchAgent (`RunAtLoad=false`, `KeepAlive=false` — registered at login but **not** started), and the `omlxctl` control tool (symlinked onto your `PATH` when the Homebrew bin is writable). Setup deliberately leaves the server stopped ([ADR-005](adrs/005-on-demand-service-lifecycle.md)).

Model download is **opt-in** (`--download-model`); the base run never pulls weights. No engine override is applied — the workhorse is a verified text-only coder build, so oMLX runs it on its batched LLM engine and it is concurrency-safe as-is ([ADR-009](adrs/009-mac-single-workhorse-cloud-frontier.md)).

## The workhorse model

One pinned model ([ADR-009](adrs/009-mac-single-workhorse-cloud-frontier.md)) — the Mac is a **subagent workhorse** and high-fidelity work routes to a cloud frontier, not to a local tier:

| Alias | Model | ~Size | Residency |
|---|---|---|---|
| `coding-workhorse` | `mlx-community/GLM-4.7-Flash-6bit` (MoE, ~3 B active, 202 K ctx, MLA KV compression) | ~24 GB | pinned, sole resident |

A single pinned model gives the parallel-agent fan-out **one shared prefix cache** and never exercises oMLX's multi-model swap path. The 6-bit quant was adopted after an on-host A/B measured quality parity with the 8-bit (tool-calls 58/58 each; HumanEval 81.7% vs 80.5%, statistical tie) while freeing ~7 GB of weights ([ADR-010](adrs/010-6bit-workhorse-sustained-mark.md)). `--max-concurrent-requests` is 4 — the **large-context** safe concurrency ([ADR-012](adrs/012-concurrency-mark-4-large-context.md)): ADR-010's mark of 8 was measured at ~16 K contexts, but the KV pool holds only ~83 K tokens of *total* concurrent context (~0.433 GB/1 K tokens against the guard's 66 GB dynamic ceiling — [ADR-011](adrs/011-pi-context-window-guard-boundary.md)), and eight admitted 25–45 K agentic streams oversubscribe it ~3× (2026-07-26 incident: guard 400s, decode collapse, cache-evict spiral). At 4 — matching the pi subagent spawn cap — excess requests queue at admission, consuming no KV. `GLM-4.7-Flash-8bit` stays on disk as the **primary inactive fallback** (rollback = pin swap + restart), with `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` as the secondary — neither is pinned or served by default. The setup script applies the alias + pin via the oMLX admin API (briefly starting the server, then stopping it; falls back to printed manual steps) and **unpins retired ADR-006 tiers** it finds. Re-verify the HuggingFace repo ID against current availability before downloading — the script probes it, but better checkpoints ship often.

## Starting and stopping

Startup is intentional — nothing wires the ~24 GB model until you ask. Control the server with `omlxctl` (installed to `~/.omlx/bin/omlxctl`, symlinked onto `PATH` when possible; otherwise call it by full path or add `~/.omlx/bin` to `PATH`):

```bash
omlxctl start     # kickstart the server, then wait for /health (cold start ~90 s)
omlxctl stop      # SIGTERM, flush hot cache to SSD, then SIGKILL after 30 s — releases memory
omlxctl restart   # atomic restart, then wait for ready
omlxctl status    # launchd registration/run state + /health readiness (warns if 0 models loaded)
omlxctl logs      # recent stdout/stderr (live: tail -f ~/.omlx/logs/launchagent.*.log)
```

**Why on-demand?** The LaunchAgent is `RunAtLoad=false` + `KeepAlive=false`, so logging in registers the job but never starts it, and a stop (or crash) stays down — no auto-respawn. Stopping fully reclaims the unified memory the model held. The root `iogpu.wired_limit_mb` LaunchDaemon stays loaded the whole time: it is a ceiling, not a reservation, and costs nothing while the server is stopped. Rationale and trade-offs: [ADR-005](adrs/005-on-demand-service-lifecycle.md).

After a reboot or login, run `omlxctl start` to bring the server back.

## Validating

`./setup-omlx-m5.sh --validate` runs five checks against the running server: model listing (including a warning if a retired ADR-006 tier is still pinned), a small chat completion, a **tool-calling** round-trip, a **2-way concurrency probe** (confirms the batched engine handles the fan-out), and an Anthropic-style `/v1/messages` call. Before trusting the config under real load, also run the one-time on-host probes in [docs/workhorse-probes.md](docs/workhorse-probes.md) (long-context MLA check, `enable_thinking` pass-through).

## Connecting clients

- **Any OpenAI-compatible client:** base URL `http://localhost:8000/v1`, bearer token from `~/.omlx/api-key`.
- **Anthropic-style clients:** `POST http://localhost:8000/v1/messages`.
- **Pi coding agent:** `./setup-omlx-m5.sh --configure-pi` registers the provider (or prints a merge snippet).
- **.NET router integration:** see [docs/router-wiring.md](docs/router-wiring.md).

## Repository map

| Path | What it is |
|---|---|
| [`setup-omlx-m5.sh`](setup-omlx-m5.sh) | The provisioning script (idempotent; exit codes `0` pass / `1` error / `2` precondition) |
| [`templates/`](templates/) | Start wrapper, LaunchAgent/LaunchDaemon plists, `omlxctl` control tool, Pi provider block — installed with placeholder substitution |
| [`macos/local-llm-mac-os-creation.md`](macos/local-llm-mac-os-creation.md) | The authoritative implementation brief |
| [`adrs/`](adrs/) | Decision records — the current config is [ADR-010](adrs/010-6bit-workhorse-sustained-mark.md) (6-bit quant + sustained mark of 8) plus [ADR-011](adrs/011-pi-context-window-guard-boundary.md) (pi-advertised contextWindow 76800, the measured prefill-guard boundary) and [ADR-012](adrs/012-concurrency-mark-4-large-context.md) (concurrency mark 4 + maxTokens 8192 for the large-context era), all amending [ADR-009](adrs/009-mac-single-workhorse-cloud-frontier.md) (single-model workhorse, cloud as frontier; supersedes [ADR-006](adrs/006-multi-tier-coresident-lineup-stay-on-omlx.md) three-tier lineup and [ADR-008](adrs/008-cross-host-routing-integration.md) cross-host AMD routing), plus [ADR-005](adrs/005-on-demand-service-lifecycle.md) (on-demand lifecycle, no login autostart — still in force) |
| `.claude/agents/`, `.github/agents/` | Repository-resident `omlx-expert` domain agent (read-only/advisory) for Claude Code and GitHub Copilot |
| [`.github/workflows/`](.github/workflows/) | CI lint gate — `validate` (shellcheck + markdownlint + plist well-formedness) and `lint-pr-title` (Conventional Commits), required checks on the branch rulesets ([ADR-007](adrs/007-ci-rulesets-and-release-strategy.md)); plus `upstream-watch` (weekly upstream oMLX release/issue watch that files tracking issues — not a required check) |
| [`docs/router-wiring.md`](docs/router-wiring.md) | Wiring the server into a .NET `IInferenceBackend` / `FallbackInferenceRouter` |
| [`docs/runtime-tiering-research.md`](docs/runtime-tiering-research.md) | Research note behind [ADR-006](adrs/006-multi-tier-coresident-lineup-stay-on-omlx.md) — runtime reassessment, on-host bake-off, and tier selection |
| [`docs/amd-augmentation-research.md`](docs/amd-augmentation-research.md) | Research note (2026-07-05) behind the proposed AMD-host augmentation roles — eval/CI farm first, gated overflow lane; GLM-on-gfx1100 disqualified — assessment only, ADR pending |
| [`omlx-setup-prompt.md`](omlx-setup-prompt.md) | Historical source prompt only — not a source of truth |

## Upgrading from the three-tier (ADR-006) install

If you previously provisioned the three-tier lineup, just re-run the script — it is an in-place, non-destructive upgrade:

```bash
git pull
./setup-omlx-m5.sh            # GLM is already on disk from T2 — no download needed
./setup-omlx-m5.sh --validate # confirms coding-workhorse resolves and retired tiers are unpinned
```

The re-run re-renders the start wrapper with the current serving flags (`--hot-cache-max-size 24GB`, `--max-concurrent-requests 4`, `--paged-ssd-cache-max-size 50GB`), downloads the 6-bit workhorse if absent (`--download-model`), and **actively unpins the retired models** via the admin API so their memory is actually freed — first renaming `GLM-4.7-Flash-8bit` to alias `workhorse-8b` so `coding-workhorse` transfers cleanly to the 6-bit, and clearing any still-pinned ADR-006 tiers (Qwen3-Coder-30B, Qwen3-Coder-Next). Retired models stay on disk (the 8-bit is the primary inactive fallback, Qwen3-Coder-30B the secondary; delete Qwen3-Coder-Next by hand if you want the disk back). If the server is running when you re-run, the wrapper update stops it (restart with `omlxctl start`). It never overwrites your API key, the oMLX-managed `model_settings.json` (it merges via the admin API), or a non-empty Pi config (a merge snippet is left at `~/.omlx/pi-provider-snippet.json` — note the provider now exposes only `coding-workhorse`). Running it twice is a no-op.

## Teardown

There is no `--uninstall` flag; reverse the steps manually (see the Teardown section in [CLAUDE.md](CLAUDE.md)):

```bash
omlxctl stop 2>/dev/null || true                       # stop the server, release memory
launchctl bootout gui/$(id -u)/com.local.omlx 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.local.omlx.plist
rm -f "$(brew --prefix)/bin/omlxctl"                   # the on-PATH symlink, if created
sudo launchctl bootout system/com.local.iogpu-wired-limit 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.local.iogpu-wired-limit.plist
brew uninstall omlx && brew untap jundot/omlx
rm -rf ~/.omlx \
  ~/models/GLM-4.7-Flash-6bit                       # the workhorse
# Also remove whichever fallback/retired models are still on disk:
rm -rf ~/models/GLM-4.7-Flash-8bit \
  ~/models/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit \
  ~/models/Qwen3-Coder-Next-MLX-4bit
```

## Security notes

- The API key lives only at `~/.omlx/api-key` (0600) on the host — it is generated locally and never committed or printed.
- The server binds to loopback only (`--host 127.0.0.1`); nothing is exposed to the network.
- Known accepted gap: the key is visible in the process argument list (`ps`) while the server runs — documented in [ADR-001](adrs/001-local-mlx-inference-omlx.md).
