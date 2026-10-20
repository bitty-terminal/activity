# Bitty Activity

Privacy-first local activity timeline plugin for the
[Bitty terminal](https://github.com/bitty-terminal/bitty).

> Status: v1 implementation present, host integration still landing. The plugin
> package, manifest, and policy are implemented and tested headlessly against
> the accepted Plugin API v1 surface; nothing here is a shipped feature until
> the host surfaces it. Compatibility and activation claims are limited to the
> manifest `[compat]` ranges.

## Overview

Bitty Activity keeps a privacy-first local timeline of terminal activity:
sessions opened and closed, working-directory changes, process exits, and
session-duration buckets. Aggregates live in the plugin store and are returned
by the `summary` command and a low-urgency local notification. The plugin opens
no socket, spawns no process, and never stores command text, terminal contents,
full paths, or environment values.

## Install

Prerequisites: Bitty `>=0.0.24,<0.1` and Plugin API `^1.0` (from
`bitty-plugin.toml` `[compat]`), plus `just` and `bun` only if you build from a
checkout.

Install from the repository, then enable it:

```sh
bitty plugin install https://github.com/bitty-terminal/activity.git
bitty plugin enable bitty-featured.activity
bitty plugin list   # confirm state and grants
```

From a local checkout, install the directory instead:

```sh
bitty plugin install ./activity --yes
bitty plugin enable bitty-featured.activity
```

`bitty plugin list` confirms activation: the entry must be enabled and show the
requested grants (`terminal.semantic-read`, `platform.notify`). A disabled entry
carries a `disabled_reason`; see [Troubleshooting](#troubleshooting).

## Commands

| Command                           | What it does                                                                                                  | Arguments | Default keybinding |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------- | --------- | ------------------ |
| `bitty-featured.activity:summary` | Prunes the retention window, returns a bounded summary of local aggregates, and shows one local notification. | None      | None               |
| `bitty-featured.activity:clear`   | Deletes every stored activity aggregate and resets in-memory state, session pairing, and error bookkeeping.   | None      | None               |

Run either command from the command palette. Both take an empty object as
arguments (`additionalProperties = false`).

## Configuration

Settings are declared in `bitty-plugin.toml` `[settings]` and resolved from
`$XDG_CONFIG_HOME/bitty/plugins/bitty-featured.activity.lua`. Every key is
user-owned; the plugin never writes settings.

| Key                  | Type    | Default | Description                                                                                                            | Applies         |
| -------------------- | ------- | ------- | ---------------------------------------------------------------------------------------------------------------------- | --------------- |
| `retention_days`     | integer | `7`     | Days of aggregates to retain, clamped to `1..90`. The current setting takes precedence over the window in stored data. | Next activation |
| `store_command_args` | boolean | `false` | Reserved opt-in. v1 never stores command arguments, so `true` changes nothing; the key stays read-only and inert.      | Next activation |

```lua
-- $XDG_CONFIG_HOME/bitty/plugins/bitty-featured.activity.lua
return {
  retention_days = 14,
  store_command_args = false,
}
```

The host resolves settings at activation and pins them to that generation;
editing the file takes effect on the next activation. Wrong-typed or
out-of-range values fall back without widening what is stored.

## Keybindings

The plugin installs no keybindings. Bind a command yourself in
`$XDG_CONFIG_HOME/bitty/init.lua`; user mappings keep precedence:

```lua
return {
  keymaps = {
    {
      chord = "ctrl+alt+a",
      action = "bitty-featured.activity:summary",
      context = "global",
    },
  },
}
```

## Troubleshooting

| Symptom / error            | Meaning                                                                                                                                                                              | What to do                                                                                                                                      |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `E_INCOMPATIBLE`           | The host application or Plugin API version is outside the manifest `[compat]` ranges; the plugin is disabled with no partial activation.                                             | Upgrade Bitty, or install a plugin revision whose ranges admit your host. Do not edit the manifest ranges to bypass the check.                  |
| `E_SETTINGS_UNDECLARED`    | The plugin read a settings key that is not declared in `[settings]`. This is a plugin defect, not a configuration error.                                                             | Both keys above are declared; if it still appears, report it with `bitty plugin info bitty-featured.activity` and run `bitty --safe` meanwhile. |
| Capability denied          | A grant is missing (`E_CAPABILITY_DENIED`, class `runtime`): no `terminal.semantic-read` means no zone count; no `platform.notify` means no notification. The summary still renders. | Re-run `bitty plugin install` and approve the grants, or inspect granted versus requested capabilities with `bitty plugin list`.                |
| Store reports newer format | `E_STORE_VERSION`: stored data was written by a newer plugin format. The plugin never overwrites data it cannot read.                                                                | Upgrade the plugin; `bitty-featured.activity:clear` is the explicit purge if you accept losing that data.                                       |
| Store unavailable          | `E_STORE_UNAVAILABLE`: the plugin store could not be read; the summary says the stored data is unavailable and is not modified.                                                      | Restart Bitty, check free disk space and permissions on the state directory, then retry.                                                        |
| `E_SPAWN_FAILED`           | Not applicable: this plugin spawns no process and opens no socket.                                                                                                                   | —                                                                                                                                               |

## Behavior (v1)

Two commands are registered during activation (both reserved in `[lazy]`):

- `bitty-featured.activity:summary` — prunes the retention window, reads one
  read-only semantic snapshot for the focused-terminal zone count, persists
  pending aggregates, and returns a bounded text summary. It also shows one
  local `platform.notify` notification.
- `bitty-featured.activity:clear` — explicit user purge: deletes the stored
  aggregate value and resets in-memory state, session pairing, and
  error bookkeeping.

Observation events update aggregates and persist them synchronously; no
post-activation timer is created, per the accepted activation lifecycle
(timer and task creation is valid only while `init.lua` executes). The
`plugin.suspended` / `plugin.disposed` lifecycle events flush pending state
before the generation goes away. A failed transient write stays dirty so the
next observation event or lifecycle flush retries synchronously; data the
plugin could not read (including a newer format it never saw) is never
overwritten, and the consecutive-failure counter resets after a successful
write. Payload fields are type-checked and events fail closed: a malformed
`terminal_id`, `exit_code`, or `cwd` never mutates an aggregate or marks
state dirty.

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
| `bitty-plugin.toml`                     | Static manifest: identity, compatibility, capability requests, settings, and lazy commands/events. |
| `lua/activity/init.lua`                 | Entry point evaluated once per activation; registrations and event subscriptions.                  |
| `lua/activity/aggregate.lua`            | Bounded aggregate state, retention, exit/duration bucketing, and summary rendering.                |
| `lua/activity/redact.lua`               | cwd reduction to bounded, non-reconstructable labels (final path segment).                         |
| `tests/`                                | Behavior tests, mock host stub, and LuaLS conformance (see `tests/README.md`).                     |
| `scripts/check-readme-settings.mjs`     | Checks the README configuration table against `bitty-plugin.toml` `[settings]`.                    |
| `scripts/workflow-publish.sh`           | In-repo CarryCtx snapshot publisher (`carryctx export --publication` + ref push).                  |
| `scripts/workflow-import.sh`            | Fresh-clone restore from `refs/heads/carryctx-snapshots`.                                          |
| `justfile`                              | Quality gates with pinned tool versions.                                                           |
| `.github/workflows/ci.yml`              | CI quality gate with a read-only token and SHA-pinned actions.                                     |
| `.github/workflows/codeql.yml`          | CodeQL analysis (`actions`, `javascript-typescript`).                                              |
| `.github/workflows/snapshot-source.yml` | CarryCtx snapshot staleness gate (push to `main`/`carryctx-snapshots`).                            |

## Development

Prerequisites: `just`, `bun`, and `lua5.4` for the behavior suite (CI pins
Bun 1.4.0 and installs Lua 5.4). Dependency versions are pinned in
`package.json` and locked in `bun.lock`; the justfile invokes installed tools
as `bun run <bin>` and never invokes formatters or linters directly, so every
gate resolves locally.

```sh
just install         # bun install --frozen-lockfile (the only networked gate step)
just hooks-install   # optional: lefthook commit-msg and pre-commit hooks
just check           # lint + fmt-check + manifest + readme-settings + lua + test (offline)
```

Individual gates:

- `just lint` / `just lint-files` — Markdown lint (markdownlint-cli2).
- `just fmt-check` / `just fmt-check-files` — Prettier format check.
- `just commit-check` — Conventional Commit message check (commitlint).
- `just manifest` — validate `bitty-plugin.toml` with the authoritative SDK
  CLI `bitty-plugin-lint` (bitty-plugin-sdk, R-SDK-2) against the accepted
  contract in bitty-docs `docs/specifications/plugin-platform-rfc.md` (file
  name, identity, compatibility, closed capability set, settings declarations,
  lazy triggers, hard limits). The linter is a commit-pinned devDependency in
  `package.json` and `bun.lock`; `just install` materializes it, and the gate
  fails closed when it is absent.
- `just readme-settings` — check the README `## Configuration` table against
  `[settings]`; a missing key, an extra key, or a type/default mismatch fails.
- `just lua` — parse the entry point with a pinned Lua parser.
- `just test` — Lua 5.4 behavior suite plus the LuaLS conformance wrapper;
  also available as `just test-lua` and `just test-luals`. The wrapper skips
  with exit 0 when its optional tool is not installed (see
  `tests/README.md`).

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
