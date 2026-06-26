# local-llm — oMLX provisioning for Apple Silicon

Stand up a **local, OpenAI/Anthropic-compatible LLM inference server** on an Apple Silicon Mac using [oMLX](https://github.com/jundot/omlx), tuned for **parallel AI coding agents** — multiple concurrent requests sharing long system prefixes, where concurrent throughput and prefix-cache reuse matter more than single-stream tok/s.

## TL;DR — start now

You need: an Apple Silicon Mac with **128 GB unified memory** (tuned for M5 Max; other Max-class chips warn but work), ~140 GB free disk (three model tiers ≈ 105 GB plus cache headroom), macOS, and [Homebrew](https://brew.sh). One step needs `sudo` (GPU wired-memory limit).

```bash
git clone https://github.com/psmfd/local-llm.git && cd local-llm
./setup-omlx-m5.sh --download-model   # install + configure + fetch the 3 tiers (~105 GB)
omlxctl start                         # start the server on demand (NOT at login)
./setup-omlx-m5.sh --validate         # smoke-test the running server
```

The server is **on-demand**: setup installs it but does not start it, and it does **not** start at login — startup is intentional. Start, stop, and reclaim memory with `omlxctl` (see [Starting and stopping](#starting-and-stopping)).

Then point any OpenAI-style client at `http://localhost:8000/v1` (or Anthropic-style at `/v1/messages`) with the API key from `~/.omlx/api-key`. Done.

The script is idempotent — re-running it skips whatever already exists. Run `./setup-omlx-m5.sh --help` for all flags.

## What the setup script does

`setup-omlx-m5.sh` performs, in order:

1. **Preflight** — hard-fails (exit `2`) on non-macOS, non-arm64, <~120 GB RAM, <~100 GB free disk, or missing Homebrew.
2. **Installs oMLX** via `brew tap jundot/omlx && brew install omlx` (no MCP — tool access stays explicit).
3. **Creates directories** — `~/models`, `~/.omlx/{cache,logs,bin}` (`~/.omlx` is chmod 700).
4. **Generates an API key** at `~/.omlx/api-key` (chmod 600, never printed).
5. **Raises the Metal wired limit** to ~96 GB so the GPU can hold the model resident, persisted across reboots via a root LaunchDaemon (**the sudo step**).
6. **Installs on-demand service control** — a start wrapper carrying the tuned serving flags, a per-user LaunchAgent (`RunAtLoad=false`, `KeepAlive=false` — registered at login but **not** started), and the `omlxctl` control tool (symlinked onto your `PATH` when the Homebrew bin is writable). Setup deliberately leaves the server stopped ([ADR-005](adrs/005-on-demand-service-lifecycle.md)).

Model download is **opt-in** (`--download-model`); the base run never pulls weights. No engine override is applied — every tier is a verified text-only coder build, so oMLX runs each on its batched LLM engine and it is concurrency-safe as-is ([ADR-006](adrs/006-multi-tier-coresident-lineup-stay-on-omlx.md)).

## Model tiers

Three tiers ([ADR-006](adrs/006-multi-tier-coresident-lineup-stay-on-omlx.md)), all verified text-only (no `vision_config`) and tool-call-verified on oMLX:

| Tier | Alias | Model | ~Size | Residency |
|---|---|---|---|---|
| fast | `coding-fast` | `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` (MoE, ~3 B active, 262 K ctx) | ~30 GB | pinned, co-resident |
| balanced | `coding-balanced` | `mlx-community/GLM-4.7-Flash-8bit` (MoE-lite, ~3 B active, 202 K ctx) | ~30 GB | pinned, co-resident |
| quality | `coding-quality` | `lmstudio-community/Qwen3-Coder-Next-MLX-4bit` (MoE, 80 B/~3 B active, ~71 % SWE-bench) | ~45 GB | on-demand (lazy-load ~16 s, idle-evicts) |

`coding-fast` + `coding-balanced` stay **co-resident and pinned** (~60 GB, leaving ~29 GB for KV/prefix cache under the 96 GB wired ceiling), so the parallel-agent fan-out never pays a swap cost. `coding-quality` is the genuine high-fidelity tier — it does not co-reside (45 GB + 60 GB exceeds the budget), so oMLX **lazy-loads it on first request** and evicts it when idle. The setup script applies aliases + pins via the oMLX admin API (briefly starting the server, then stopping it; falls back to printed manual steps). Re-verify the HuggingFace repo IDs against current availability before downloading — the script probes them, but better checkpoints ship often.

## Starting and stopping

Startup is intentional — nothing wires the ~32 GB model until you ask. Control the server with `omlxctl` (installed to `~/.omlx/bin/omlxctl`, symlinked onto `PATH` when possible; otherwise call it by full path or add `~/.omlx/bin` to `PATH`):

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

`./setup-omlx-m5.sh --validate` runs five checks against the running server: model listing, a small chat completion, a **tool-calling** round-trip, a **2-way concurrency probe** (confirms the batched engine handles the fan-out), and an Anthropic-style `/v1/messages` call.

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
| [`adrs/`](adrs/) | Decision records — current model lineup is [ADR-006](adrs/006-multi-tier-coresident-lineup-stay-on-omlx.md) (two co-resident pinned tiers + one on-demand max tier, stay on oMLX; supersedes [ADR-004](adrs/004-single-text-only-model-no-override.md)) and [ADR-005](adrs/005-on-demand-service-lifecycle.md) (on-demand lifecycle, no login autostart) |
| `.claude/agents/`, `.github/agents/` | Repository-resident `omlx-expert` domain agent (read-only/advisory) for Claude Code and GitHub Copilot |
| [`docs/router-wiring.md`](docs/router-wiring.md) | Wiring the server into a .NET `IInferenceBackend` / `FallbackInferenceRouter` |
| [`docs/runtime-tiering-research.md`](docs/runtime-tiering-research.md) | Research note behind [ADR-006](adrs/006-multi-tier-coresident-lineup-stay-on-omlx.md) — runtime reassessment, on-host bake-off, and tier selection |
| [`omlx-setup-prompt.md`](omlx-setup-prompt.md) | Historical source prompt only — not a source of truth |

## Upgrading from a single-model (ADR-004) install

If you previously provisioned the single-model (ADR-004) lineup, just re-run the script — it is an in-place, non-destructive upgrade:

```bash
git pull
./setup-omlx-m5.sh --download-model   # fetches only the 2 new tiers; the existing 30B is skipped
./setup-omlx-m5.sh --validate         # confirms all three aliases resolve
```

The re-run detects the existing `coding-fast` model + pin, downloads only the missing `coding-balanced`/`coding-quality` tiers, and applies the new aliases/pins via the admin API (it briefly starts the server, then stops it). It never overwrites your API key, the oMLX-managed `model_settings.json` (it merges via the admin API), or a non-empty Pi config (a merge snippet is left at `~/.omlx/pi-provider-snippet.json`). Running it twice is a no-op.

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
  ~/models/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit \
  ~/models/GLM-4.7-Flash-8bit \
  ~/models/Qwen3-Coder-Next-MLX-4bit
```

## Security notes

- The API key lives only at `~/.omlx/api-key` (0600) on the host — it is generated locally and never committed or printed.
- The server binds to loopback only (`--host 127.0.0.1`); nothing is exposed to the network.
- Known accepted gap: the key is visible in the process argument list (`ps`) while the server runs — documented in [ADR-001](adrs/001-local-mlx-inference-omlx.md).
