# local-llm — oMLX provisioning for Apple Silicon

Stand up a **local, OpenAI/Anthropic-compatible LLM inference server** on an Apple Silicon Mac using [oMLX](https://github.com/jundot/omlx), tuned for **parallel AI coding agents** — multiple concurrent requests sharing long system prefixes, where concurrent throughput and prefix-cache reuse matter more than single-stream tok/s.

## TL;DR — start now

You need: an Apple Silicon Mac with **128 GB unified memory** (tuned for M5 Max; other Max-class chips warn but work), ~100 GB free disk, macOS, and [Homebrew](https://brew.sh). One step needs `sudo` (GPU wired-memory limit).

```bash
git clone https://github.com/psmfd/local-llm.git && cd local-llm
./setup-omlx-m5.sh --download-model   # install + configure + fetch the primary model (~38 GB)
./setup-omlx-m5.sh --validate         # smoke-test the running server
```

Then point any OpenAI-style client at `http://localhost:8000/v1` (or Anthropic-style at `/v1/messages`) with the API key from `~/.omlx/api-key`. Done.

The script is idempotent — re-running it skips whatever already exists. Run `./setup-omlx-m5.sh --help` for all flags.

## What the setup script does

`setup-omlx-m5.sh` performs, in order:

1. **Preflight** — hard-fails (exit `2`) on non-macOS, non-arm64, <~120 GB RAM, <~100 GB free disk, or missing Homebrew.
2. **Installs oMLX** via `brew tap jundot/omlx && brew install omlx` (no MCP extra — tool access stays explicit).
3. **Creates directories** — `~/models`, `~/.omlx/{cache,logs,bin}` (`~/.omlx` is chmod 700).
4. **Generates an API key** at `~/.omlx/api-key` (chmod 600, never printed).
5. **Raises the Metal wired limit** to ~96 GB so the GPU can hold a large model resident, persisted across reboots via a root LaunchDaemon (**the sudo step**).
6. **Installs autostart** — a start wrapper carrying the tuned serving flags plus a per-user LaunchAgent.
7. **Applies the engine override** for the primary model (`model_type_override = llm`) via the admin API — required because the checkpoint carries a `vision_config` that would otherwise route it to oMLX's VLM engine, which crashes under concurrent load ([oMLX #1800](https://github.com/jundot/omlx/issues/1800), [ADR-003](adrs/003-vlm-engine-workaround-lineup.md)).

Model download is **opt-in** (`--download-model` / `--with-secondary`); the base run never pulls weights.

## Models

| Alias | Model | Size | Role |
|---|---|---|---|
| `coding-fast` | `mlx-community/Qwen3.6-35B-A3B-8bit` (MoE, ~3 B active) | ~38 GB | Primary — fast decode, 8-bit preserves tool-call JSON fidelity |
| `coding-quality` | `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` | ~30 GB | Optional secondary (`--with-secondary`) — verified text-only, the concurrency-safe fallback |

Re-verify the HuggingFace repo IDs against current availability before downloading — the script probes them, but better checkpoints ship often. Pinning + aliasing is done in the admin panel at `http://localhost:8000/admin` (the script prints the manual steps).

## Validating

`./setup-omlx-m5.sh --validate` runs five checks against the running server: model listing, a small chat completion, a **tool-calling** round-trip, a **2-way concurrency probe** (the regression gate for the engine override), and an Anthropic-style `/v1/messages` call.

## Connecting clients

- **Any OpenAI-compatible client:** base URL `http://localhost:8000/v1`, bearer token from `~/.omlx/api-key`.
- **Anthropic-style clients:** `POST http://localhost:8000/v1/messages`.
- **Pi coding agent:** `./setup-omlx-m5.sh --configure-pi` registers the provider (or prints a merge snippet).
- **.NET router integration:** see [docs/router-wiring.md](docs/router-wiring.md).

## Repository map

| Path | What it is |
|---|---|
| [`setup-omlx-m5.sh`](setup-omlx-m5.sh) | The provisioning script (idempotent; exit codes `0` pass / `1` error / `2` precondition) |
| [`templates/`](templates/) | Start wrapper, LaunchAgent/LaunchDaemon plists, Pi provider block — installed with placeholder substitution |
| [`macos/local-llm-mac-os-creation.md`](macos/local-llm-mac-os-creation.md) | The authoritative implementation brief |
| [`adrs/`](adrs/) | Decision records — [ADR-003](adrs/003-vlm-engine-workaround-lineup.md) is current (model lineup + engine override) |
| [`docs/router-wiring.md`](docs/router-wiring.md) | Wiring the server into a .NET `IInferenceBackend` / `FallbackInferenceRouter` |
| [`omlx-setup-prompt.md`](omlx-setup-prompt.md) | Historical source prompt only — not a source of truth |

## Teardown

There is no `--uninstall` flag; reverse the steps manually (see the Teardown section in [CLAUDE.md](CLAUDE.md)):

```bash
launchctl bootout gui/$(id -u)/com.local.omlx 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.local.omlx.plist
sudo launchctl bootout system/com.local.iogpu-wired-limit 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.local.iogpu-wired-limit.plist
brew uninstall omlx && brew untap jundot/omlx
rm -rf ~/.omlx ~/models/Qwen3.6-35B-A3B-8bit ~/models/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit
```

## Security notes

- The API key lives only at `~/.omlx/api-key` (0600) on the host — it is generated locally and never committed or printed.
- The server binds to loopback only (`--host 127.0.0.1`); nothing is exposed to the network.
- Known accepted gap: the key is visible in the process argument list (`ps`) while the server runs — documented in [ADR-001](adrs/001-local-mlx-inference-omlx.md).
