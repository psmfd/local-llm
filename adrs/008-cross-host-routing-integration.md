# ADR-008: Integrate the AMD vLLM appliance as a co-equal peer backend — AMD-first for `coding-fast`

- Status: accepted
- Date: 2026-06-28

Extends [ADR-006](006-multi-tier-coresident-lineup-stay-on-omlx.md), which
anticipated an abstract remote fallback backend for `coding-quality` and assumed a
**single local endpoint**. This ADR concretizes that backend as a specific always-on
host and revises router ordering for the two-host world. ADR-006's model lineup,
co-resident pinning, `--memory-guard-gb 90` / 96 GB wired limit, and oMLX runtime all
carry forward **unchanged on the Mac**. The AMD host's *internal* build (Ubuntu, ZFS,
the `vllm.service` unit, the iGPU/`ROCR_VISIBLE_DEVICES` finding) lives in a separate
`amd-inference` repo whose ADR-001 cross-references this decision; consumer wiring is
in [docs/router-wiring.md](../docs/router-wiring.md).

## Context and Problem Statement

A second physical inference host — an always-on **AMD RX 7900 XTX (24 GB, gfx1100)**
running **vLLM/ROCm** — now exists alongside the M5 Max laptop that oMLX runs on. How
does it plug into the existing consumer paths (the .NET `FallbackInferenceRouter` and
the Pi provider config), and which host serves which tier?

Two hard facts constrain the answer: (1) the **M5 Max is a laptop — not always-on**;
(2) the AMD box's **24 GB holds exactly one ~30B model** — it cannot co-reside T1+T2
and cannot fit the ~45 GB `coding-quality` max tier.

## Considered Options

- **Remote-backend / fallback only.** AMD stays the abstract remote backend, used
  mainly as fallback for `coding-quality`; the Mac is primary for every role.
  Rejected: underuses the always-on box, and AMD physically cannot serve the 45 GB
  quality tier it would be the "fallback" for.
- **Co-equal peer, Mac-first for `coding-fast`.** Both hosts serve, but the router
  still tries the Mac first for the high-frequency fast role. Rejected: makes the
  steady-state hot path depend on a laptop being awake — defeating the reason the
  always-on box exists.
- **Co-equal peer, AMD-first for `coding-fast` (chosen).**

## Decision Outcome

Chosen: **the AMD vLLM appliance is a co-equal peer backend, registered first and
serving the `coding-fast` role only; the Mac oMLX host keeps ADR-006 unchanged and
serves `coding-balanced` plus on-demand `coding-quality`.** The always-on box carries
the steady-state high-frequency role (availability), while the Mac's unique ability to
co-reside T1+T2 and host the 45 GB max tier is preserved.

| Role | Primary | Fallback chain | Model |
|---|---|---|---|
| `coding-fast` | **AMD vLLM** (always-on) | AMD → Mac oMLX T1 → cloud | Qwen3-Coder-30B-A3B Q4 (GQA) |
| `coding-balanced` | **Mac oMLX** T2 | Mac → cloud (AMD throws `InferenceUnavailable`) | GLM-4.7-Flash |
| `coding-quality` | **Mac oMLX** max (on-demand) | Mac → cloud (AMD can't fit it) | Qwen3-Coder-Next |

- **Registration is AMD-first.** AMD's alias dictionary serves only `coding-fast` and
  throws `InferenceUnavailableException` for the other two roles so the chain advances
  to oMLX. The Mac keeps **T1 co-resident** (ADR-006), so it is a **zero-swap fast
  fallback** when AMD is down or saturated.
- **AMD model is the standard-GQA `Qwen3-Coder-30B-A3B`** (prefix-caches on vLLM),
  **not** a Gated-DeltaNet hybrid (no automatic prefix caching yet — vLLM #26201),
  preserving the shared-prefix fan-out payoff.
- **Required code fix:** both `IInferenceBackend` implementations must throw
  `InferenceUnavailableException` (not `ArgumentOutOfRangeException`) for unserved
  roles, or the fallback chain returns 500 instead of advancing.
- The AMD endpoint serves OpenAI `/v1/chat/completions` and — in current vLLM — the
  Anthropic `/v1/messages` (issue #21313) for text-only models with
  `--enable-auto-tool-choice --tool-call-parser`.

### Consequences

- Good, because the steady-state high-frequency `coding-fast` fan-out runs on the
  **always-on** box, independent of laptop wake state, while the Mac's KV/concurrency
  budget is reserved for the two roles only it can serve.
- Good, because ADR-006's co-resident config is untouched, so Mac T1 is a zero-swap
  fast fallback, and a **separate physical box has its own memory pool** — cleanly
  resolving the cross-host tiering that the M5 Max's system-wide wired limit blocked.
- Bad / accepted trade-offs:
  - `coding-balanced` and `coding-quality` have **no AMD equivalent**; when the Mac is
    offline they fall to cloud (or fail if no cloud backend is registered). The 45 GB
    quality tier cannot run on 24 GB — that is structural.
  - The AMD tier inherits gfx1100 caveats: **no FP8 KV cache**, and vLLM-on-consumer-
    RDNA3 is **community-tier (Medium liveliness risk)** — AMD's 2026 roadmap targets
    datacenter parts.
  - **Verify-before-trust (Phase-1 validation on the real host, tracked as follow-up
    issues):** tool-call JSON fidelity on vLLM ROCm (`tool_choice=required` probe, the
    check ADR-006 ran on oMLX); `/v1/messages` on the pinned image; Pi multi-provider
    flat model-ID resolution (`pi_config`).
