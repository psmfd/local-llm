# Spec — New Repository-Level Inference-Hardware Agents

**Created:** 2026-06-28 · **Status:** BUILT 2026-06-28 (4 wrappers in `.claude/agents/` + `.github/agents/`; CLAUDE.md updated) · **Owner:** —

Capture of a requested addition: two new **repository-resident, read-only advisory**
agents that deepen the hardware + AI-API expertise available to this project's
orchestration, so deep technical questions route to a curated domain agent instead
of general-purpose agents (which, in this session's VRAM-offload research, had to
research ROCm/Apple-Silicon internals from scratch and fanned out unsupervised
sub-agents — breaking orchestrator visibility). This is the documented gap from the
2026-06-28 Agent Efficacy Reports.

> This file is a **spec**, not the agents themselves. Authoring the wrapper files is
> a follow-up that goes through the plan-before-code gate.

## The two agents

| Agent | Focus | Fills |
|---|---|---|
| `amd-inference-expert` | AMD AI APIs + hardware capability: Ryzen CPUs, Radeon/RDNA + Instinct/CDNA GPUs, the ROCm/HIP stack, vLLM-on-ROCm, llama.cpp HIP/Vulkan | **A total gap** — no AMD/ROCm agent exists in any catalog |
| `apple-silicon-inference-expert` | Apple Silicon AI APIs + hardware: M-series CPU/GPU/Neural Engine, unified-memory architecture, Metal/MPS, the MLX framework, Core ML / ANE | The hardware/framework layer *beneath* `omlx-expert` (which is runtime-product-scoped) |

## Format & conventions (mirror `omlx-expert`)

Each agent is **two files kept in sync** (per CLAUDE.md):

- `.claude/agents/<name>.md` — Claude Code wrapper
- `.github/agents/<name>.agent.md` — GitHub Copilot wrapper

Frontmatter pattern (from `.claude/agents/omlx-expert.md`):

```yaml
---
name: <name>
description: "<one-line scope + 'Use for:' triggers + 'Read-only advisory.'>"
model: sonnet
tools: "Read, Glob, Grep, WebFetch, WebSearch"
---
```

Hard constraints inherited from project + framework policy:

- **Read-only/advisory.** Tools limited to `Read, Glob, Grep, WebFetch, WebSearch` —
  no Write/Edit/Bash/execute. The agent returns advice + exact commands; never modifies files.
- **No MCP servers, ever.** Explicit `tools` allowlist only.
- **Re-verify against first-party docs.** Hardware capability matrices, ROCm/gfx
  support lists, MLX/Metal behavior, and CLI flags move fast — cite first-party
  sources (AMD ROCm docs, vLLM/llama.cpp repos, Apple developer docs, HF model
  cards), never assert fast-moving facts from memory.
- Body structure to follow `omlx-expert`: `## Scope` → `## Key facts (verified
  <date> — re-verify…)` → `## How you work` → `## Output format` → `## Constraints`.

## Boundary with `omlx-expert` (resolve before building)

`omlx-expert` is **runtime-product-scoped**: oMLX serve flags, the admin API,
`model_type_override`, the VLM-engine concurrency trap, endpoint validation, plus a
thin slice of Apple-Silicon memory tuning (`iogpu.wired_limit_mb`, the LaunchDaemon).

`apple-silicon-inference-expert` is the **hardware + framework layer underneath**:
chip microarchitecture, unified-memory bandwidth, Metal/MPS, MLX internals,
ANE/Core ML, quantization on MLX. Proposed rule of thumb:

- *"How do I configure oMLX / which serve flag"* → `omlx-expert`.
- *"What can this chip do / why is MLX behaving this way / Metal vs ANE / memory
  bandwidth + KV math on Apple Silicon"* → `apple-silicon-inference-expert`.

The `iogpu.wired_limit_mb` knob currently lives in `omlx-expert`; decide whether it
stays there (runtime-tuning context) or moves to the hardware agent. Recommendation:
**leave it in `omlx-expert`** (it's applied in service of the oMLX runtime) and have
the hardware agent own the *why* (unified-memory architecture, wired vs dynamic).

## `amd-inference-expert` — seed knowledge (from 2026-06-28 research; re-verify)

Draft description: *"Expert on AMD AI inference hardware and APIs — Ryzen CPUs,
Radeon/RDNA and Instinct/CDNA GPUs, the ROCm/HIP stack, vLLM-on-ROCm, and llama.cpp
HIP/Vulkan. Use for: gfx-target capability checks, ROCm feature support, VRAM/KV
budgeting on consumer Radeon, vLLM ROCm serving config, and quant/offload paths.
Read-only advisory."*

Facts this agent should encode (all gfx1100 / RX 7900 XTX-relevant, verified 2026-06-28):

- **gfx1100 (RDNA3) has no native Flash Attention** and **no FP8 KV cache** → KV is
  bf16-only; KV capacity is the concurrency limiter for a given model.
- **CPU KV-offload connector is a hard CUDA-only code gate**; **LMCache** is
  MI300X/gfx942-scoped (gfx1100 absent from docs/wheels, `torchac_rocm` targets
  gfx90a). Native automatic prefix caching (APC) is the only working KV lever.
- **APC + chunked prefill is broken** (vLLM #8223 — cache hit checked only on first
  chunk). Disable chunked prefill when APC matters.
- **`--cpu-offload-gb` weight offload** ≈ 85% throughput collapse (per-step PCIe
  weight streaming, layer-not-expert granularity); ROCm-unvalidated. **RFC #38256 /
  PR #37190** (expert-selective offload) is the watch item for fitting bigger MoE.
- **iGPU gfx1036 (Ryzen 9000 cIOD)** has no rocBLAS TensileLibrary target
  (ROCm#3015, "not planned"); its ROCm *visibility* can crash the dGPU
  (`invalid device function`, ollama #11975) → isolate with
  `ROCR_VISIBLE_DEVICES=<dGPU index>` while keeping it for display.
- **RCCL 2.27.7 TP=2 deadlock** on dual-RDNA3 under Ubuntu 24.04 + ROCm 7.2.1
  (ROCm #6074) — relevant only to multi-GPU plans with matched cards.
- **N-gram/suffix speculative decoding** is the one spec variant safe at batch > 1.
- vLLM serves the Anthropic **`/v1/messages`** endpoint (issue #21313) for text-only
  models with `--enable-auto-tool-choice --tool-call-parser` — verify per pinned image.
- **Liveliness:** vLLM ROCm = Active project / consumer-RDNA3 = Maintenance-only
  (Medium risk — AMD's 2026 roadmap targets datacenter parts; features land on
  MI300X first). llama.cpp ROCm = Active but gfx1100 wave-size throughput regression
  (#20934) and **no cross-request prefix cache** (disqualifies it for shared-prefix
  fan-out).

## `apple-silicon-inference-expert` — seed knowledge (re-verify)

Draft description: *"Expert on Apple Silicon AI inference hardware and APIs —
M-series CPU/GPU/Neural Engine, unified-memory architecture, Metal/MPS, the MLX
framework, and Core ML / ANE. Use for: chip capability and memory-bandwidth
reasoning, MLX quantization and KV behavior, unified-memory / wired-limit rationale,
and Metal-vs-ANE tradeoffs. Read-only advisory."*

Facts this agent should encode (verified across this project; re-verify):

- **Unified memory** is one pool shared CPU/GPU; `iogpu.wired_limit_mb` is a *ceiling,
  not a reservation*. M5 Max: up to 128 GB, ~614 GB/s (40-core GPU). MoE with ~3B
  active params decodes fast under that bandwidth.
- **Hybrid Gated-DeltaNet/SSM models do NOT prefix-cache on mlx-lm/oMLX** (same class
  as the vLLM #26201 gap) — so a DeltaNet model (e.g. Qwen3-Coder-Next) fits an
  *on-demand single-stream* slot, NOT the prefix-cache-sensitive steady-state
  fan-out slot. This is the single most important Apple-side fact for this project.
- oMLX on-demand model **lazy-load ≈ 16 s** on M-series (contrast: AMD PCIe cold-load
  ≈ 0.68 s) — shapes whether an on-demand tier is acceptable.
- `mlx-vlm` batch path lacks prefix caching; `mlx-lm` text path has continuous
  batching + prompt-prefix caching → prefer text-only checkpoints.
- Knows the layers: **MLX** (Apple's array framework), **Metal/MPS** (GPU compute),
  **ANE/Core ML** (the Neural Engine — generally not the LLM-serving path today),
  and where each is/ isn't usable for batched LLM serving.

## Build checklist (for the follow-up implementation pass)

1. Plan-before-code: present the wrapper content for approval (this is a behavioral
   agent addition).
2. Write the 4 files (2 per agent), Claude + Copilot mirrors kept in sync.
3. Lint with the `linter` agent (markdownlint); confirm frontmatter parity between
   each Claude/Copilot pair.
4. **ADR-eligibility:** adding repo-resident agents that follow the established
   `omlx-expert` two-file pattern is likely pattern-following (not-a-thing) — but the
   AMD agent introduces a *new domain* to the project, so consider a short ADR noting
   the inference-expert agent set and the `omlx-expert` boundary. Decide at plan time.
5. Update CLAUDE.md's agent list (it currently names only `omlx-expert`'s two files).

## Placement decision (RESOLVED 2026-06-28)

- **Repo-resident in `local-llm`, NOT the global catalog — until the `claude-config`
  split lands.** The `_business/agent-framework` repo is now work-owned; the user is
  leveraging it transitionally and is planning a personal **`claude-config`** — a
  Claude-Code-only, work-information-free fork *without* the dual-target (Copilot
  mirror) machinery. Until that fork exists, every new agent/rule stays repository-
  resident in its project repo. So these two agents live only in `local-llm`'s
  `.claude/agents` and `.github/agents`. Revisit promotion (and the Copilot mirror question) when
  `claude-config` is stood up. See memory `claude-config-framework-split`.

## Remaining open questions before building

- **`omlx-expert` overlap** — confirm the boundary rule above; optionally add a
  one-line "see also" cross-link between `omlx-expert` and `apple-silicon-inference-expert`.
- **Naming** — `amd-inference-expert` / `apple-silicon-inference-expert` as proposed,
  or shorter (`rocm-expert`, `mlx-expert`)? The longer names better signal the
  hardware+API breadth beyond a single runtime.
- **`omlx-expert` overlap** — confirm the boundary rule above; optionally add a
  one-line "see also" cross-link between `omlx-expert` and `apple-silicon-inference-expert`.
- **Naming** — `amd-inference-expert` / `apple-silicon-inference-expert` as proposed,
  or shorter (`rocm-expert`, `mlx-expert`)? The longer names better signal the
  hardware+API breadth beyond a single runtime.
