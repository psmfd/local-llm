# ADR-007: CI lint gate, branch-protection rulesets, and a deferred release strategy

- Status: accepted
- Date: 2026-06-26

Resolves [issue #6](https://github.com/psmfd/local-llm/issues/6). Operationalizes
the global GitHub Flow and SemVer Tagging conventions for this repo; nothing in
the runtime/model decisions (ADR-001 through ADR-006) is affected.

## Context and Problem Statement

The repository had no CI workflows and no branch-protection rulesets: GitHub
Actions had never run, and neither `dev` nor `main` was protected. The GitHub Flow
guardrails the project assumes — squash-only into `dev`, merge-commit-only
promotions to `main`, required status checks, blocked force-push and deletion —
rested entirely on operator discipline. How should this provisioning repo (shell
scripts + docs; no package, container, or published artifact) enforce its flow,
and should it adopt automated releases now?

## Considered Options

- **CI scope:** (a) port the agent-framework's full check set (`validate.sh`,
  `artifact-review-guard`, .NET/Helm lints) vs. (b) a repo-appropriate lint gate
  (shellcheck + markdownlint + plist well-formedness) plus a Conventional Commits
  PR-title check.
- **Release automation:** (a) wire `semantic-release` now, (b) defer it and cut a
  manual annotated `v0.1.0` from `main` after this lands, (c) no tagging at all.

## Decision Outcome

Chosen option: **a repo-appropriate lint gate (CI scope b) + branch-protection
rulesets, with `semantic-release` deferred (release option b)**, because the
agent-framework's exact checks do not transfer (there is no `validate.sh`, no
`.review/` flow, and no .NET/Helm here), and the project has no versioned-artifact
consumers or changelog audience that would justify a Node.js release toolchain in
a shell-script repo.

Concretely:

- **CI** — two workflows on PRs to `dev`/`main`:
  - `validate` (`.github/workflows/validate.yml`): `shellcheck` over the three
    shell files (the extensionless `templates/omlxctl` included via an explicit
    list, dialect auto-detected from its bash shebang), `markdownlint-cli2` with a
    repo-root `.markdownlint-cli2.jsonc`, and a `python3` ElementTree plist
    well-formedness check (`plutil` is macOS-only and absent on Linux runners).
    `templates/pi-models-omlx.json` is a JSONC template with `__PLACEHOLDER__`
    tokens and is intentionally not JSON-validated.
  - `lint-pr-title` (`.github/workflows/lint-pr-title.yml`):
    `amannn/action-semantic-pull-request@v6` enforcing a Conventional Commits PR
    title (the squash commit message on `dev`).
- **Rulesets** — `protect-dev` (require PR, 0 approvals, squash-only, linear
  history, block force-push + deletion, required checks `validate` +
  `lint-pr-title`) and `protect-main` (require PR, 0 approvals, merge-commit-only,
  block force-push + deletion, required check `validate`). `protect-main`
  **deliberately omits** the require-linear-history rule: a `dev` → `main`
  promotion is a merge commit (non-linear by definition), and requiring linear
  history would permanently block every promotion.
- **Repo settings** — disable rebase merging and enable auto-delete-branch-on-merge
  (squash + merge-commit stay enabled).
- **Required-check binding order** — the workflows must run once (on the PR that
  introduces them) before the ruleset can bind their check contexts; the rulesets
  are therefore created after that PR merges, using the check-run names read back
  from the API.
- **Release** — defer `semantic-release`. Cut a manual annotated `v0.1.0` from
  `main` after the first post-CI promotion. Revisit automation when a versioned
  artifact (container image, published download) or an external consumer/changelog
  audience appears.

### Consequences

- Good, because the flow is now enforced at the remote (force-push/deletion
  blocked, merge method constrained per branch, a green lint gate required) rather
  than relying on discipline.
- Good, because the lint gate matches the repo's actual content and stays
  dependency-light (no Node release toolchain, no macOS-only tooling in CI).
- Good, because `protect-main` keeps merge-commit promotions working — the
  highest-risk misconfiguration (linear history on `main`) is explicitly avoided.
- Bad (accepted), because 0 required approvals is weaker than a reviewed gate —
  unavoidable for a solo maintainer (GitHub forbids self-approval). Bump
  `protect-dev` to 1 approval when a collaborator joins.
- Bad (accepted), because deferring `semantic-release` means versioning is manual
  and easy to forget; the low commit velocity and absence of downstream consumers
  make this an acceptable trade today.
- Bad (accepted), because the job names (`validate`, `lint-pr-title`) are now a
  contract with the rulesets — renaming a job without updating its ruleset breaks
  the required-check binding and blocks merges until reconciled.
