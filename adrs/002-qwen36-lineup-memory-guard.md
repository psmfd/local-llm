# ADR-002: Qwen3.6 dual-model lineup and `--memory-guard-gb` migration

- Status: superseded by [ADR-003](003-vlm-engine-workaround-lineup.md) (model lineup; the flag migration and memory budget carry forward)
- Date: 2026-06-11

Supersedes [ADR-001](001-local-mlx-inference-omlx.md) for the model lineup,
memory budget, and serving flags. The runtime decision (oMLX via Homebrew) is
unchanged and carries forward.

## Context and Problem Statement

ADR-001 chose Qwen3-Coder-Next 80B-A3B 8-bit (~85 GB) as the sole resident
model, sized so tightly that the secondary stayed opt-in and the wired limit had
to be pushed to 112 GB. Two things changed by June 2026: (1) the Qwen3.6 family
shipped (April 2026) with an MoE 35B-A3B whose **active-parameter count (~3B)
matches Coder-Next** — so decode cost under the 614 GB/s bandwidth cap is nearly
identical at less than half the resident footprint — and (2) oMLX **removed the
`--max-process-memory` flag**, replacing it with `--memory-guard safe|balanced`
and `--memory-guard-gb <N>`, which breaks the committed start wrapper regardless
of any model decision. For a parallel-agent workload where prefix-cache reuse and
concurrent KV headroom dominate, is a smaller dual-model lineup the better fit?

## Considered Options

- **Keep Qwen3-Coder-Next 80B-A3B 8-bit** (~84.7 GB) — purpose-built agentic
  coder; the mlx-community repo ships dedicated tool-call parser helpers; highest
  single-model capability ceiling. But it consumes the memory that would
  otherwise serve KV/prefix cache and a second model.
- **Qwen3.6-35B-A3B 8-bit primary + Qwen3.6-27B 6-bit dense secondary**
  (~37.7 GB + ~22.8 GB ≈ 60.5 GB resident) — same ~3B active params as
  Coder-Next, newer training (Apr 2026), higher SWE-bench Verified (73.4% vs
  Coder-Next's 64.6% Pass@5 — different metrics, compared cautiously), and
  ~47 GB more headroom for KV/hot cache and concurrency. The dense 27B gives a
  different quality/latency profile for non-fan-out work.
- **Add GLM-4.7-Flash 8-bit as a third "variety" model** — rejected: the 8-bit
  quant is ~63.3 GB (not the ~21 GB initially assumed), which blows the budget
  outright; only a 4-bit (lmstudio-community) would fit, and 4-bit was already
  rejected for tool-call JSON fidelity in ADR-001.
- **MTP variants of Qwen3.6-35B-A3B** (~1.4× decode, released 2026-06-01) —
  deferred: only published at 4/5-bit, conflicting with the 8-bit fidelity
  requirement. Revisit if an 8-bit MTP build ships.

## Decision Outcome

Chosen option: **Qwen3.6-35B-A3B-8bit primary (alias `coding-fast`) +
Qwen3.6-27B-6bit dense secondary (alias `coding-quality`)**, because at equal
active parameters the freed ~47 GB is a stronger lever for the stated workload
(3+ concurrent agents, shared long prefixes) than Coder-Next's purpose-built
tool-call training. Repo IDs verified against the HuggingFace API on 2026-06-11:
`mlx-community/Qwen3.6-35B-A3B-8bit` (~37.7 GB) and
`mlx-community/Qwen3.6-27B-6bit` (~22.8 GB). The `coding-agentic` alias is
retired; downstream routing maps `coding-fast` → primary, `coding-quality` →
secondary.

Serving config (replaces ADR-001's):

```text
--port 8000 --memory-guard-gb 90 --paged-ssd-cache-dir ~/.omlx/cache \
--hot-cache-max-size 20% --max-concurrent-requests 16 --api-key <0600 file>
```

- **`--memory-guard-gb 90`** replaces the removed `--max-process-memory 110GB`.
  90 GB sits below the wired ceiling so saturation surfaces as oMLX-level
  backpressure rather than Metal wiring failures. Note (oMLX #702): the guard
  monitors Metal allocations, not total RSS.
- **Wired limit 96 GB** (`iogpu.wired_limit_mb=98304`), down from 112 GB:
  ~60.5 GB resident weights + KV for 16 concurrent requests fits comfortably,
  and the OS keeps ~32 GB. Still set explicitly and persisted via the
  LaunchDaemon for determinism.
- **`--max-concurrent-requests 16`**, up from 8: the headroom freed by the
  smaller lineup is spent on a wider fan-out, which is the workload's point.
- Disk preflight hard-fail drops from 120 GB to **100 GB** free (~61 GB of
  models plus paged-SSD cache headroom). RAM hard-fail stays at 120 GB.

### Consequences

- Good, because both models fit fully resident with wide KV headroom — the
  secondary no longer competes with the primary for the wired budget.
- Good, because the broken `--max-process-memory` flag is migrated before it
  bites a fresh provision (the CLI preflight in `setup-omlx-m5.sh` now checks
  `--memory-guard-gb`).
- Bad / accepted trade-offs:
  - Coder-Next's purpose-built agentic tool-call training is given up; the
    `--validate` tool-calling check is the regression gate — if Qwen3.6-35B-A3B
    emits malformed `tool_calls`, revisit this ADR.
  - The 8-bit 35B-A3B is a multimodal build (vision configs present; loads via
    the VLM path) — same caveat ADR-001 carried for its secondary.
  - SWE-bench numbers compared across different metrics (Verified vs Pass@5);
    treated as directional, not decisive — the decisive factor is memory.
  - ADR-001's other accepted trade-offs (admin-panel-only pinning, alias bug,
    API key visible to `ps`, young CLI surface) all still apply.
