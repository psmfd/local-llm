# ADR-005: On-demand service lifecycle (no login autostart)

- Status: accepted
- Date: 2026-06-23

## Context and Problem Statement

The oMLX server is provisioned as a per-user LaunchAgent. The original lineup
(ADR-001 → ADR-004) shipped it with `RunAtLoad=true` + `KeepAlive=true`, so the
tuned server started at every login and was kept alive. On a 128 GB host that
means the resident model (~32 GB) plus KV/prefix and hot caches are wired
unconditionally from login, even when the operator needs the unified memory for
other work. How should the server be started and stopped so that (a) startup is
intentional rather than automatic, and (b) stopping cleanly reclaims the wired
memory on demand?

Two oMLX-specific facts shape the answer. First, the wired-limit knob
(`iogpu.wired_limit_mb`, set by the root LaunchDaemon) is a *ceiling*, not a
reservation — leaving it raised while the server is stopped costs no memory, so
only the user agent's process needs lifecycle control. Second, a `KeepAlive=true`
agent will faithfully reproduce a crash loop after a GPU hang that leaks Metal
memory (oMLX issue #15), where each respawn OOMs against an exhausted Metal budget
until reboot.

## Considered Options

- **A. `RunAtLoad=false` + `KeepAlive=false`, controlled by an `omlxctl` tool**
  using `launchctl kickstart` / `kill SIGTERM` / `kickstart -k` / `print`. The job
  is bootstrapped (registered) automatically at login but sits in `state = waiting`
  until an explicit start.
- **B. Bootstrap-on-start / bootout-on-stop** — the plist is registered only while
  running. Re-reads the plist on every start; `bootout` can race a dying process
  and return errors on Sequoia+; a crash can leave the job in an intermediate state
  needing a manual `bootout`.
- **C. `KeepAlive={SuccessfulExit:false}`** — a clean SIGTERM stays stopped, but a
  crash/jetsam-kill auto-restarts. Reintroduces the issue #15 crash-loop risk.
- **D. Keep autostart (`RunAtLoad=true` + `KeepAlive=true`)** — the status quo;
  rejected because it contradicts the intentional-startup and reclaim requirements.

## Decision Outcome

Chosen option: **A**, because it is the documented, idiomatic launchd on-demand
model and the only option that satisfies both requirements without surprises.
With `RunAtLoad=false` the job is registered at login but no process starts (high
certainty — loading and running are distinct launchd steps); no `Disabled` key or
`launchctl disable` is needed, and adding them would break `kickstart`. With
`KeepAlive=false` a stop is final and a crash stays down, side-stepping the issue
\#15 crash loop. The `iogpu.wired_limit_mb` LaunchDaemon is left untouched — it is
a zero-cost ceiling while the server is idle.

Lifecycle is exposed through a small `omlxctl` tool installed to
`~/.omlx/bin/omlxctl` (and symlinked into the Homebrew bin when writable, with a
manual PATH fallback otherwise):

- `start` — `launchctl kickstart`, then poll `GET /health` (no auth) up to 120s,
  since cold start loads ~32 GB and wires it (~90s typical).
- `stop` — `launchctl kill SIGTERM`, wait up to 30s for the hot cache to flush up
  to 18 GB to SSD, then escalate to `SIGKILL`. This is the clean reclaim.
- `restart` — `launchctl kickstart -k` + readiness poll.
- `status` / `logs` — registration/run state, `/health` readiness, recent logs.

Setup installs and registers the agent but deliberately leaves the server stopped.

### Consequences

- Good, because startup is intentional: nothing wires the model until the operator
  runs `omlxctl start`, and `omlxctl stop` releases it on demand.
- Good, because `KeepAlive=false` avoids the post-GPU-hang crash loop (issue #15);
  a crash surfaces plainly instead of respawning into an OOM spin.
- Good, because the registered-but-waiting job needs no `bootstrap` on each start,
  avoiding option B's re-read and bootout-race failure modes.
- Bad (accepted), because there is no automatic restart after an unexpected crash —
  the operator must run `omlxctl start` again. This is the intended trade-off for a
  single-user, intentional-control workstation service.
- Bad (accepted), because the server must be started manually after a reboot or
  login. The closing setup message and README document the `omlxctl start` step.
