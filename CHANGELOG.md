# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
  workflows, Dependabot configuration, issue/PR templates, and the
  `activity-workflow` ctxpack mirror publisher/restore scripts.
- Plugin scaffold generated from `bitty-plugin-template` (R-TPL-1,
  origin/main `494c743`): `bitty-plugin.toml` for `bitty-featured.activity`
  and the `lua/activity/init.lua` entry point using the accepted Plugin API
  v1 surface from ADR 0009.
- `just` quality gates: Markdown lint, Prettier format check, manifest
  validation (transitional validator), and Lua parse.
- CarryCtx initialization with bootstrap (`CTX-0001`) and v1 implementation
  (`CTX-0002`) tasks.

### Security

- Least-privilege manifest: `terminal.semantic-read` and `platform.notify`
  only; no high-risk capabilities and no ambient authority.
- Privacy contract for v1: no network, process, filesystem, clipboard, or
  environment authority; command arguments and terminal content are never
  stored; cwd values are reduced to bounded final-segment labels.
