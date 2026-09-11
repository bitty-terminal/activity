# Quality gates for Bitty Activity (bitty-featured.activity).
#
# Tool version pins live here (one place) and mirror package.json
# devDependencies; keep both identical when bumping. All tool invocations go
# through bun/bunx; never use npm, npx, or yarn in this repository.

markdownlint_pin := "0.23.2"
prettier_pin := "3.9.6"
commitlint_pin := "21.2.2"
lefthook_pin := "2.1.12"
luaparse_pin := "0.3.1"

# List available recipes.
default:
    @just --list

# Lint all Markdown sources with markdownlint-cli2 (.markdownlint-cli2.jsonc).
lint:
    bunx --bun markdownlint-cli2@{{markdownlint_pin}}

# Lint specific Markdown files (used by the pre-commit hook).
lint-files *files:
    bunx --bun markdownlint-cli2@{{markdownlint_pin}} {{files}}

# Format all files with Prettier.
fmt:
    bunx --bun prettier@{{prettier_pin}} --write . --ignore-unknown

# Format specific files with Prettier.
fmt-files *files:
    bunx --bun prettier@{{prettier_pin}} --write {{files}}

# Check formatting of all files with Prettier.
fmt-check:
    bunx --bun prettier@{{prettier_pin}} --check . --ignore-unknown

# Check formatting of specific files (used by the pre-commit hook).
fmt-check-files *files:
    bunx --bun prettier@{{prettier_pin}} --check {{files}}

# Validate a commit message file with commitlint (conventional commits).
commit-check message=".git/COMMIT_EDITMSG":
    bunx --bun commitlint@{{commitlint_pin}} --edit "{{message}}"

# Install Git hooks managed by lefthook (opt-in per contributor checkout).
hooks-install:
    bunx --bun lefthook@{{lefthook_pin}} install

# Remove lefthook-managed Git hooks.
hooks-uninstall:
    bunx --bun lefthook@{{lefthook_pin}} uninstall

# Validate bitty-plugin.toml against the accepted manifest contract.
# Transitional: replace with `bitty-plugin-lint` from bitty-plugin-sdk
# (R-SDK-2) once that CLI is published; the manifest schema is owned by
# bitty-docs, not by this repository.
manifest:
    bun scripts/validate-manifest.mjs bitty-plugin.toml

# Parse the Lua entry point with a pinned Lua 5.1 grammar parser.
lua:
    bunx --bun luaparse@{{luaparse_pin}} --quiet --file lua/activity/init.lua

# Run the Lua 5.4 behavior suite (redaction, aggregation, lifecycle, commands).
# Requires lua5.4 (plugin VM baseline per ADR 0005).
test-lua:
    lua5.4 tests/run.lua

# LuaLS conformance against the vendored Plugin API v1 definitions. Skips with
# exit 0 when lua-language-server is unavailable (set LUA_LANGUAGE_SERVER).
test-luals:
    bun tests/check-lua-luals.mjs

# Authoritative SDK manifest check. Skips with exit 0 when bitty-plugin-lint is
# undiscoverable; set BITTY_PLUGIN_LINT to the SDK CLI entry to force it.
test-manifest:
    bun tests/check-manifest-lint.mjs

# Run all behavior and conformance tests.
test: test-lua test-luals test-manifest

# Aggregate gate run locally and in CI.
check: lint fmt-check manifest lua test

# Publish a ctxpack snapshot to the activity-workflow mirror (commander
# merge closeout only; never a git hook). Dry run exports + validates
# without push.
workflow-publish *args:
    bash scripts/publish-ctxpack.sh {{args}}

workflow-publish-dry *args:
    bash scripts/publish-ctxpack.sh --dry-run {{args}}

# Restore the local CarryCtx DB from the activity-workflow mirror LATEST
# snapshot (fresh-clone recipe). Refuses to replace a non-empty local DB
# without --force, e.g. `just workflow-import --force`.
workflow-import *args:
    bash scripts/fetch-ctxpack.sh {{args}}

workflow-import-dry *args:
    bash scripts/fetch-ctxpack.sh --dry-run {{args}}
