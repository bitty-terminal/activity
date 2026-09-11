# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
