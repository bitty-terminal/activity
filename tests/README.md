# Activity test harness

Headless checks for the `lua/activity/**` implementation. `just check`
(`lint` + `fmt-check` + `manifest` + `lua` + `test`) runs them locally and in
CI; the individual suites are also available directly.

## Prerequisites

- `lua5.4` (plugin VM baseline per ADR 0005) — required for behavior tests;
  CI installs it from the Ubuntu archive before `just check`.
- `bun` — the LuaLS and SDK-linter wrapper scripts.
- `lua-language-server` (optional) — LuaLS conformance; the check skips with
  exit 0 when it is unavailable (CI does not install it).
- `bitty-plugin-lint` from `bitty-plugin-sdk` (optional) — authoritative
  manifest check; skipped unless discoverable (CI does not install it).

## Commands

```sh
just test            # lua5.4 runner + LuaLS check + SDK linter wrapper

# Behavior tests: redaction, aggregation, bounds, lifecycle flushing, commands.
just test-lua

# LuaLS conformance against the vendored Plugin API v1 definitions
# (LUA_LANGUAGE_SERVER=/path/to/server overrides discovery).
just test-luals

# Authoritative manifest check (SDK R-SDK-2);
# BITTY_PLUGIN_LINT=/path/to/bitty-plugin-sdk/src/cli.ts forces the SDK CLI.
just test-manifest
```

## Layout

| Path                            | Purpose                                                                                                           |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `run.lua`                       | Plain-Lua runner; exits non-zero on assertion failure.                                                            |
| `support/tap.lua`               | Assertion helper (no external test framework).                                                                    |
| `support/mock_host.lua`         | Fail-closed in-process `bitty` stub modeling the used v1 subset (capability gates, key/value bounds incl. UTF-8). |
| `spec/redact_spec.lua`          | cwd label transform unit tests.                                                                                   |
| `spec/aggregate_spec.lua`       | State, bounds, retention, persistence, and rendering unit tests.                                                  |
| `spec/init_spec.lua`            | Entry-point behavior against the mock host.                                                                       |
| `lua-defs/bitty.d.lua`          | Vendored LuaLS definitions from bitty-plugin-sdk (origin/main `721aea8`, sha256 `7101cc56...`).                   |
| `lua-defs/negative-fixture.lua` | Excluded-surface fixture that LuaLS must reject.                                                                  |
| `check-lua-luals.mjs`           | Positive/negative LuaLS workspace check.                                                                          |
| `check-manifest-lint.mjs`       | Runs `bitty-plugin-lint` when discoverable.                                                                       |

## Known gaps

- The SDK mock host is a TypeScript test double; the accepted corpus notes
  that a Lua-facing adapter able to execute `init.lua` against it is a
  separate tooling task (`bitty-plugin-sdk` `docs/mock-host.md`, "Lua
  execution"). `support/mock_host.lua` is this repository's bounded stand-in.
- The SDK linter accepts string-form `[lazy].commands` only; the ADR 0009
  table form with static schemas is not yet accepted by R-SDK-2, so the
  manifest uses the string form.
- CI installs `lua5.4` but not `lua-language-server` or `bitty-plugin-lint`,
  so those two wrappers report `skipped` (exit 0) in CI; install them locally,
  or pin them into the workflow later, for full conformance coverage.
