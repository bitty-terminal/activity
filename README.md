# Bitty Activity

Privacy-first local activity timeline plugin for the
[Bitty terminal](https://github.com/bitty-terminal/bitty).

This repository is the pathfinder for the first featured-plugin wave (bitty
CarryCtx task `CTX-0221`, planning note `PX-1199`): one independent plugin
repository under the `bitty-terminal` organization, scaffolded from
[bitty-plugin-template](https://github.com/bitty-terminal/bitty-plugin-template)
and validated against
[bitty-plugin-sdk](https://github.com/bitty-terminal/bitty-plugin-sdk).

> Status: pre-implementation scaffold. The Bitty plugin host and the accepted
> Plugin API v1 bindings are still landing. `just check` validates the manifest
> and parses the Lua entry point; the v1 timeline behavior is tracked in this
> repository's CarryCtx state as `CTX-0002`. Nothing here is a shipped
> feature.

## Layout

| Path                            | Purpose                                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `bitty-plugin.toml`             | Static manifest: identity, compatibility, capability requests, and lazy triggers.                      |
| `lua/activity/init.lua`         | Entry point evaluated once per activation; every resource it creates belongs to the plugin generation. |
| `scripts/validate-manifest.mjs` | Transitional manifest check using the Bun TOML parser; no dependencies.                                |
| `scripts/publish-ctxpack*.sh`   | CarryCtx snapshot publisher for the `activity-workflow` mirror.                                        |
| `scripts/fetch-ctxpack*.sh`     | Fresh-clone restore from the `activity-workflow` mirror LATEST snapshot.                               |
| `justfile`                      | Quality gates with pinned tool versions.                                                               |
| `.github/workflows/ci.yml`      | CI quality gate with a read-only token and SHA-pinned actions.                                         |
| `.github/workflows/codeql.yml`  | CodeQL analysis (`actions`, `javascript-typescript`).                                                  |

## Development

Prerequisites: `just` and `bun` (CI pins Bun 1.4.0; the justfile owns all
tool pins and never invokes formatters or linters directly).

```sh
bun install
just hooks-install   # optional: lefthook commit-msg and pre-commit hooks
just check           # lint + fmt-check + manifest + lua
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

## Capabilities and privacy

Capabilities are deny by default: a request absent from `[capabilities]` is
denied, identifiers come from a closed set, and there is no allow-all entry.

v1 intent requests the narrowest identifiers only:

- `terminal.semantic-read` — read-only semantic snapshots used for local
  aggregate counts, durations, and cwd.
- `platform.notify` — surface the local summary.

Command arguments are never stored (`store_command_args` defaults to `false`)
and workspace settings cannot widen authority; high-risk identifiers
(`terminal.raw-read`, `terminal.input.all`, `ui.protocol-register`,
`debug.control`, `runtime.plugin-manage`) are intentionally absent.

## Workflow mirror

The engineering workflow (tasks, sessions, decisions, checkpoints) is
mirrored to the public
[activity-workflow](https://github.com/bitty-terminal/activity-workflow)
repository after merges. On a fresh clone, restore the local CarryCtx DB from
the latest snapshot:

```sh
just workflow-import-dry   # fetch + validate only
just workflow-import       # replace-mode import of LATEST
```

Snapshots are redacted publication artifacts and are never merged back.

## Provenance

The plugin payload is generated from `bitty-plugin-template` (`R-TPL-1`,
origin/main `494c743`; first merged at `f0492d0`) with the deterministic
generator:

```sh
bun scripts/generate-plugin.mjs \
  --id bitty-featured.activity --name "Bitty Activity" \
  --description "Privacy-first local activity timeline plugin for the Bitty terminal." \
  --version 0.1.0 --dir <target>
```

The plugin id `bitty-featured.activity` follows the `PX-1199` batch plan.
`lua/activity/init.lua` uses the accepted Plugin API v1 surface from ADR 0009
and the Plugin API v1 Lua Surface RFC, as generated in bitty-plugin-sdk
`lua/bitty.d.lua` (`R-SDK-1`).

## Security

Report vulnerabilities through the process in [SECURITY.md](SECURITY.md)
rather than a public issue. This scaffold contains no credentials, no
install-time execution, and no ambient OS authority.

## License

MIT — see [LICENSE](LICENSE).
