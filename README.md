# Bitty Activity

Privacy-first local activity timeline plugin for the
[Bitty terminal](https://github.com/bitty-terminal/bitty).

This repository is the pathfinder for the first featured-plugin wave (bitty
CarryCtx task `CTX-0221`, planning note `PX-1199`): one independent plugin
repository under the `bitty-terminal` organization, scaffolded from
[bitty-plugin-template](https://github.com/bitty-terminal/bitty-plugin-template)
and validated against
[bitty-plugin-sdk](https://github.com/bitty-terminal/bitty-plugin-sdk).

> Status: v1 implementation present, host integration still landing. The Bitty
> plugin host and the accepted Plugin API v1 bindings are still being built,
> so nothing here is a shipped feature. The repository implements the v1
> privacy-first timeline against the accepted surface and validates it with
> `just check`, the behavior tests in `tests/`, LuaLS conformance, and
> `bitty-plugin-lint`.

## See the project workflow (CarryCtx)

CarryCtx engineering state (tasks, sessions, checkpoints) is not cloned. A
fresh clone restores it from the in-repo `refs/heads/carryctx-snapshots`
branch:

```sh
just workflow-import-dry   # fetch + validate the snapshot; no DB writes
just workflow-import       # initialize CarryCtx state if needed, then import
```

Then `carryctx stats` reports the restored tasks, sessions, and checkpoints.
Provenance, redaction, and `--force` behavior are covered under the
repository snapshot documentation below.

## Layout

| Path                                    | Purpose                                                                                            |
| --------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `bitty-plugin.toml`                     | Static manifest: identity, compatibility, capability requests, and lazy commands/events.           |
| `lua/activity/init.lua`                 | Entry point evaluated once per activation; registrations and event subscriptions.                  |
| `lua/activity/aggregate.lua`            | Bounded aggregate state, retention, exit/duration bucketing, and summary rendering.                |
| `lua/activity/redact.lua`               | cwd reduction to bounded, non-reconstructable labels (final path segment).                         |
| `tests/`                                | Behavior tests, mock host stub, LuaLS conformance, and SDK linter wrapper (see `tests/README.md`). |
| `scripts/validate-manifest.mjs`         | Transitional manifest check using the Bun TOML parser; no dependencies.                            |
| `scripts/workflow-publish.sh`           | In-repo CarryCtx snapshot publisher (`carryctx export --publication` + ref push).                  |
| `scripts/workflow-import.sh`            | Fresh-clone restore from `refs/heads/carryctx-snapshots`.                                          |
| `justfile`                              | Quality gates with pinned tool versions.                                                           |
| `.github/workflows/ci.yml`              | CI quality gate with a read-only token and SHA-pinned actions.                                     |
| `.github/workflows/codeql.yml`          | CodeQL analysis (`actions`, `javascript-typescript`).                                              |
| `.github/workflows/snapshot-source.yml` | CarryCtx snapshot staleness gate (push to `main`/`carryctx-snapshots`).                            |

## Behavior (v1)

Two commands are registered during activation (both reserved in `[lazy]`):

- `bitty-featured.activity:summary` — prunes the retention window, reads one
  read-only semantic snapshot for the focused-terminal zone count, persists
  pending aggregates, and returns a bounded text summary. It also shows one
  local `platform.notify` notification.
- `bitty-featured.activity:clear` — explicit user purge: deletes the stored
  aggregate value and resets in-memory state.

Observation events update aggregates; one bounded one-shot timer coalesces
store writes, and the `plugin.suspended` / `plugin.disposed` lifecycle events
flush pending state before the generation goes away. A failed transient write
re-arms a bounded exponential-backoff retry (at most five automatic attempts
per dirty streak, reset by the next observation event), so pending aggregates
are not lost between events; the consecutive-failure counter resets after a
successful write. Payload fields are type-checked and events fail closed: a
malformed `terminal_id`, `exit_code`, or `cwd` never mutates an aggregate or
arms a flush.

Durations pair `terminal.opened` and `terminal.closed` by `terminal_id` in
generation-scoped memory (at most 64 tracked sessions). Abandoned opens are
pruned after 24 hours, and at the cap the least-recently-opened entry is
evicted, so new sessions are never permanently starved; a close older than the
abandonment bound records no duration. Sessions opened before activation record
no duration. Only the resulting bucket count is stored, never open times or
per-terminal history. Stored buckets are capped, the value is a single
JSON-compatible table under `timeline.v1`, and data written by a newer plugin
format is never overwritten.

Retention defaults to 7 days (`retention_days` setting, 1..90). The current
setting takes precedence over the value stored in `timeline.v1`, which is used
only as a fallback when no setting value is available; expired cwd buckets fold
into a bounded total instead of being retained.

## Development

Prerequisites: `just`, `bun`, and `lua5.4` for the behavior suite (CI pins
Bun 1.4.0 and installs Lua 5.4; the justfile owns all tool pins and never
invokes formatters or linters directly).

```sh
bun install
just hooks-install   # optional: lefthook commit-msg and pre-commit hooks
just check           # lint + fmt-check + manifest + lua + test
```

Individual gates:

- `just lint` / `just lint-files` — Markdown lint (markdownlint-cli2).
- `just fmt-check` / `just fmt-check-files` — Prettier format check.
- `just commit-check` — Conventional Commit message check (commitlint).
- `just manifest` — validate `bitty-plugin.toml` against the accepted
  contract in bitty-docs `docs/specifications/plugin-platform-rfc.md` (file
  name, identity, compatibility, closed capability set, lazy triggers, hard
  limits). The SDK CLI `bitty-plugin-lint` is authoritative once published;
  the transitional validator is a fail-closed subset of it.
- `just lua` — parse the entry point with a pinned Lua parser.
- `just test` — Lua 5.4 behavior suite plus the LuaLS and SDK-linter
  conformance wrappers; also available as `just test-lua`, `just test-luals`,
  and `just test-manifest`. The wrappers skip with exit 0 when their optional
  tool is not installed (see `tests/README.md`).

## Capabilities and privacy

Capabilities are deny by default: a request absent from `[capabilities]` is
denied, identifiers come from a closed set, and there is no allow-all entry.

v1 requests the narrowest identifiers only:

- `terminal.semantic-read` — one read-only semantic snapshot per `summary`
  invocation (zone count and terminal identity only; rows are never read).
- `platform.notify` — surface the local summary text.

The plugin is local-observation only. It opens no socket, spawns no process,
performs no filesystem access, reads no environment, requests no clipboard or
terminal input, and has no install-time execution.

Stored fields (one bounded `bitty.store` value under `timeline.v1`):

- coarse epoch timestamps (`updated_at`, `first_seen`, `last_seen`);
- session, cwd-event, exit-event, and exit-class counters;
- duration buckets (`<1m`, `1-10m`, `10-60m`, `>60m`);
- up to 32 redacted cwd labels (final path segment only, max 48 bytes each)
  plus a bounded count for collapsed/expired buckets.

Never stored: command arguments or command text, terminal rows or zone text,
full paths, environment values, clipboard data, or any per-terminal history.
`store_command_args` is read but never written by the plugin, defaults to
`false`, and a `true` opt-in changes nothing in v1: arguments are not stored
either way. Workspace settings cannot widen this.

`bitty-featured.activity:clear` deletes the stored value on user request.
Retention defaults to 7 days; the current `retention_days` setting takes
precedence over the stored window, and expired buckets fold into a bounded
total. Malformed event payloads are ignored rather than counted.
High-risk identifiers (`terminal.raw-read`, `terminal.input.all`,
`ui.protocol-register`, `debug.control`, `runtime.plugin-manage`) are
intentionally absent.

## Workflow snapshot restore

CarryCtx is the local-first tool that records this project's tasks, decisions,
and checkpoints. Install it globally for local development (recommended):

```sh
cargo install carryctx      # Rust toolchain, or: npm i -g carryctx
```

CarryCtx runtime state (`.git/carryctx/state.sqlite`) is never cloned. The
redacted engineering snapshot lives in this repository on the branch
`refs/heads/carryctx-snapshots`, one commit per publication. The commander's
merge closeout publishes it with `just workflow-publish`; a fresh clone
restores its local CarryCtx DB from that branch:

```sh
just workflow-import-dry   # fetch + validate the snapshot; no DB writes
just workflow-import       # initialize CarryCtx state if needed, then import
```

The import fetches `refs/heads/carryctx-snapshots`, refuses to replace a
non-empty local DB without `--force` (`just workflow-import --force`), and
prints provenance (snapshot commit + source). Snapshots are redacted
publication artifacts produced by `carryctx export --publication`: CarryCtx
refuses them as merge sources, so restore always uses replace mode, and a
secret that leaked before rotation must still be rotated at the source.

## Provenance

The plugin payload is generated from `bitty-plugin-template` (`R-TPL-1`,
origin/main `494c743`; first merged at `f0492d0`) with the deterministic
generator:

```sh
bun scripts/generate-plugin.mjs \
  --id bitty-featured.activity --name "Bitty Activity" \
  --description "Privacy-first local activity timeline plugin for the Bitty terminal." \
  --version 0.0.1 --dir <target>
```

The plugin id `bitty-featured.activity` follows the `PX-1199` batch plan.
`lua/activity/init.lua` uses the accepted Plugin API v1 surface from ADR 0009
and the Plugin API v1 Lua Surface RFC, as generated in bitty-plugin-sdk
`lua/bitty.d.lua` (`R-SDK-1`).

## Security

Report vulnerabilities through the process in [SECURITY.md](SECURITY.md)
rather than a public issue. This plugin contains no credentials, no
install-time execution, and no ambient OS authority.

## License

MIT — see [LICENSE](LICENSE).
