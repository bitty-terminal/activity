# Bitty Activity repository guidance

## Repository and authority

- This is the independent `activity` repository. Its canonical remote is
  <https://github.com/bitty-terminal/activity>.
- The Bitty umbrella directory and `bitty-plugins` directory are grouping
  only; neither owns this repository's Git or CarryCtx state.
- Enter this repository before running Git, CarryCtx, validation, or toolchain
  commands.
- `bitty-docs` is the canonical source for plugin architecture, API, security,
  packaging, compatibility, and public-behavior contracts. This repository
  must not invent capabilities, lifecycle semantics, or release policy.
- The project is pre-implementation. Repository existence, a manifest, or a
  proposed file tree is not evidence of usable plugin behavior.

## Plugin identity and scope

- Plugin id: `bitty-featured.activity` (manifest `plugin.id`), repository
  `activity`, Lua module `lua/activity/`.
- Purpose (v1 intent, bitty `CTX-0221` / `PX-1199`): a privacy-first local
  activity timeline built from semantic terminal snapshots; counts, durations,
  and cwd aggregates; command arguments are never stored.
- Authority boundary: only `terminal.semantic-read` and `platform.notify` are
  requested. High-risk capabilities, filesystem writes, network, process
  spawn, clipboard, terminal input, and install-time code execution stay out.
  A wider request needs an explicitly scoped task and a reviewed privacy and
  security note; never widen silently.
- This repository is the first featured-wave pathfinder. Scratchpad, peek, and
  pet are separate repositories and out of scope here.

## CarryCtx and agents

- Use this repository's CarryCtx state for tasks, dependencies, scopes,
  sessions, progress, decisions, checkpoints, handoffs, and review.
- The commander coordinates. Delegate substantial scoped work to focused
  agents and require an independent reviewer for acceptance.
- Every agent reads its persona and applicable rules, binds a named session to
  the task, and stays within explicit scopes.
- After the first commit, prefer a dedicated branch and Git worktree for each
  independent task. Before it, shared-checkout initialization is allowed only
  for disjoint scopes with CI-equivalent local checks.
- Branch and worktree naming is uniform across repositories: branches use
  `ctx-XXXX/<type>-<short-slug>` where `XXXX` is the owning CarryCtx task
  number, `<type>` is one of feat|fix|chore|docs, and the slug is short
  kebab-case. CarryCtx-bound worktrees live at
  `.worktrees/ctx-XXXX-<type>-<short-slug>` with `/` mapped to `-`. One branch
  per task; commander housekeeping branches may use `cmd/<slug>`.
- Preserve unrelated changes. Do not commit, push, release, publish packages,
  create repositories, or mutate remote state without authorization.
- Fresh clones have no CarryCtx state DB. Restore the local DB from the
  workflow mirror with `just workflow-import` (validate-only:
  `just workflow-import-dry`). It validates the snapshot before any write,
  refuses to replace a non-empty local DB without `--force`, preserves the
  committed `.carryctx/config.toml`, and prints provenance and restored
  counts. Mirror snapshots are redacted publication artifacts: never merge
  them back, and rotate at the source any secret that leaked before rotation.

## Delivery lifecycle

- Use GitHub Issue -> CarryCtx team/task/dependencies/scopes/session ->
  isolated branch/worktree -> commit -> pull request -> independent review
  plus CI -> merge -> `bitty-docs` synchronization -> checkpoint -> Issue/task
  closure.
- Every Issue and PR carries labels (`feat`/`fix`/`docs`/`chore` +
  `P0`/`P1`/`P2` + `area:*`) and milestone `v0.1.0`. Bodies state
  `Priority: ... | Area: ... | Labels: ... | Milestone: ... | RFC: ... |
Task: CTX-XXXX` and PRs add `Closes #<issue>`.
- Pull requests name plugin-contract, privacy/security, CI/release,
  documentation, and compatibility impact with reproducible evidence.
- Documentation synchronization is part of definition of done. A plugin
  change is incomplete while canonical `bitty-docs` guidance or this
  repository's README/CHANGELOG are stale.

## Toolchain policy

- Never use `npm`, `npx`, or `yarn` in this repository. JavaScript execution
  and package management use `bun` / `bunx --bun` exclusively (Bun 1.4.0 in
  CI unless a reviewed task pins otherwise).
- Never invoke formatters or linters directly by name. Run quality gates only
  via the justfile: `just check` plus `just lint`, `just fmt-check`,
  `just manifest`, `just lua`.
- Version pins live in the justfile and `package.json` devDependencies;
  keep both identical when bumping. Do not bump pins as a side effect of an
  unrelated task; report drift instead of silently fixing it.
- CI success is a hard acceptance gate. Workflow-affecting changes are
  validated locally with `actionlint` before push.

## Security and privacy invariants

- Deny-by-default capabilities; no allow-all or wildcard identifiers.
- No secrets in the repository, fixtures, or logs.
- No install-time execution, no ambient OS authority, no native escape
  hatches, no permissive defaults.
- Terminal data is sensitive: do not persist command arguments, output text,
  or anything beyond the documented aggregate fields without a reviewed
  decision.
- Security requirements in the canonical `bitty-docs` security corpus
  override convenience or copied examples.

## Documentation and commands

- English is the only canonical documentation language.
- Separate accepted requirements, candidates, open questions, implemented
  facts, and verification evidence.
- Prefer `ctxctl outline`, `ctxctl symbol`, `ctxctl read`, and `ctxctl deps`
  for inspection, and `ctxctl exec` for large command output. Use `rg` for
  discovery.
- Use the workspace `recording/` directory for durable scratch material
  instead of `/tmp`. Prefer moving obsolete material into a scoped `.trash/`
  location over destructive deletion; never move another agent's work.
- The primary host is CachyOS with Hyprland and Ghostty. Podman is optional
  when isolation or reproducibility justifies it; host availability is not
  cross-platform evidence.
