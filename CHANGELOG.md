# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Adopt the canonical `.editorconfig` baseline (`CTX-0023` slice); the
  repository-metadata baseline guide and ADR-0011 remain Proposed.
- Activity v1 implementation (`CTX-0002`): `lua/activity/init.lua`,
  `lua/activity/aggregate.lua`, and `lua/activity/redact.lua`.
  - `summary` command renders a bounded local summary from stored aggregates
    and one read-only semantic snapshot; `clear` command purges stored data.
  - Observation subscriptions for `terminal.opened`, `terminal.closed`,
    `terminal.cwd-changed`, and `process.exited`; lifecycle subscriptions
    flush pending state on `plugin.suspended` / `plugin.disposed`.
  - Bounded single-value store (`timeline.v1`): counters, duration buckets
    from bounded `terminal.opened`/`terminal.closed` pairing (at most 64
    tracked sessions; open times are never persisted), exit-class buckets, up
    to 32 redacted cwd labels, and a 7-day default retention window that
    folds expired buckets into a bounded total.
  - Labels are always valid UTF-8 and truncated only on a character
    boundary; invalid input sequences are masked before storage.
  - Coalesced store writes behind one bounded one-shot timer; newer-format
    stored data is detected and never overwritten.
- Behavior and conformance tests (`tests/`): plain-Lua runner with a
  fail-closed local `bitty` mock host, LuaLS positive/negative checks against
  the vendored SDK definitions, and an optional `bitty-plugin-lint` wrapper.
- Manifest declares the `clear` command and the six subscribed event types.
- Repository bootstrap at governance parity with sibling repositories:
  LICENSE (MIT), README, CONTRIBUTING, SECURITY, CHANGELOG, commitlint and
  lefthook configuration, Markdown lint configuration, CI and CodeQL
  workflows, Dependabot configuration, issue/PR templates, and the in-repo
  CarryCtx snapshot publisher/restore scripts (`scripts/workflow-*.sh`).
- Plugin scaffold generated from `bitty-plugin-template` (R-TPL-1,
  origin/main `494c743`): `bitty-plugin.toml` for `bitty-featured.activity`
  and the `lua/activity/init.lua` entry point using the accepted Plugin API
  v1 surface from ADR 0009.
- `just` quality gates: Markdown lint, Prettier format check, manifest
  validation, and Lua parse.
- CarryCtx initialization with bootstrap (`CTX-0001`) and v1 implementation
  (`CTX-0002`) tasks.
- `just install` (`bun install --frozen-lockfile`) and `just deps` (fail-closed
  dependency guard) gate the toolchain, with `bitty-plugin-sdk`
  (`bitty-plugin-lint`, R-SDK-2) and `luaparse` added as commit-locked
  devDependencies (`CTX-0011`).

### Changed

- Repository-metadata refresh: `packageManager` pins `bun@1.4.2`, the
  `carryctx` devDependency moves to 0.11.5, a conservative `.gitattributes`
  baseline normalizes text files to LF, and CONTRIBUTING records the
  contributor-branch convention and the canonical contract sources
  (`CTX-0012`).
- `just manifest` now runs the authoritative SDK linter
  `bitty-plugin-lint` (commit-pinned in `package.json`/`bun.lock`) and fails
  closed when the pinned dependency is missing; the vendored
  `scripts/validate-manifest.mjs` and the optional `tests/check-manifest-lint.mjs`
  wrapper are removed, so the SDK lint is the single source of truth.
- All tool recipes invoke installed binaries with `bun run <bin>` instead of
  `bunx --bun <tool>@<pin>`, and the justfile's duplicated pin constants are
  dropped (pins live in `package.json` + `bun.lock` only), so `just check`
  never re-resolves over the network and runs offline after one
  `just install` (`CTX-0011`).
- `just check` now runs the Lua 5.4 behavior suite and the LuaLS/SDK-linter
  conformance wrappers (`just test`), and CI installs `lua5.4` before the
  gates so the behavior suite is an always-on check (`CTX-0003`).
- CarryCtx snapshots are published in-repo on `refs/heads/carryctx-snapshots`
  and the separate workflow mirror repository is retired (`CTX-0004`).
- The `snapshot-source` workflow also runs on a daily schedule and on manual
  dispatch, so a missed snapshot publication is caught even when `main` is
  idle (`CTX-0005`).
- Plugin version realigned from `0.1.0` to `0.0.1` per bitty-docs decision
  DIR-019 (everything pre-1.0-stable stays on the `0.0.x` line). Pre-release
  correction only: no tags or releases were ever published, so no published
  artifacts are affected (`CTX-0007`).

### Fixed

- Session pairing no longer leaks: abandoned `terminal.opened` entries are
  pruned after 24 hours and the least-recently-opened entry is evicted at the
  64-session cap, so new sessions are never permanently starved (`CTX-0009`,
  M-ACT-01).
- A failed coalesced store write re-arms a bounded exponential-backoff retry
  instead of dropping pending aggregates until the next external event
  (`CTX-0009`, M-ACT-02).
- Malformed event payloads (non-numeric `terminal_id` or `exit_code`,
  non-string `cwd`) fail closed per event and no longer drift counters or arm a
  flush (`CTX-0009`, R22).
- The user's current `retention_days` setting takes precedence over the stored
  window; the consecutive write-failure counter resets after a successful
  write; and a summary that prunes nothing no longer rewrites the store
  (`CTX-0009`, R23).

### Security

- Least-privilege manifest: `terminal.semantic-read` and `platform.notify`
  only; no high-risk capabilities and no ambient authority.
- Privacy contract for v1: no network, process, filesystem, clipboard, or
  environment authority; command arguments and terminal content are never
  stored; cwd values are reduced to bounded final-segment labels.
