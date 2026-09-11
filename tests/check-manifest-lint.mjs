/**
 * Authoritative manifest check: runs `bitty-plugin-lint` (R-SDK-2) from
 * `bitty-plugin-sdk` against `bitty-plugin.toml`.
 *
 * The transitional validator wired into `just manifest` stays the always-on
 * local gate; this script adds the accepted SDK check when the CLI is
 * discoverable and skips with exit 0 otherwise so CI stays deterministic.
 *
 * Discovery order:
 *
 * 1. `BITTY_PLUGIN_LINT` — path to the CLI entry (`src/cli.ts`) or a wrapper.
 * 2. `bitty-plugin-lint` on `PATH`.
 *
 * Usage:
 *
 *   bun tests/check-manifest-lint.mjs
 *   BITTY_PLUGIN_LINT=/path/to/bitty-plugin-sdk/src/cli.ts bun tests/check-manifest-lint.mjs
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, "..");
const MANIFEST = join(REPO_ROOT, "bitty-plugin.toml");
const TIMEOUT_MS = 60_000;

function findOnPath(name) {
  const entries = (process.env.PATH ?? "").split(delimiter);
  for (const entry of entries) {
    if (entry === "") continue;
    const candidate = join(entry, name);
    if (existsSync(candidate)) return candidate;
  }
  return undefined;
}

function resolveLinter() {
  const override = process.env.BITTY_PLUGIN_LINT;
  if (override !== undefined && override !== "" && existsSync(override)) {
    return override;
  }
  return findOnPath("bitty-plugin-lint");
}

function invoke(linter) {
  if (
    linter.endsWith(".ts") ||
    linter.endsWith(".js") ||
    linter.endsWith(".mjs")
  ) {
    return ["bun", [linter, MANIFEST]];
  }
  return [linter, [MANIFEST]];
}

const linter = resolveLinter();
if (linter === undefined) {
  console.log(
    "skipped: bitty-plugin-lint not found; set BITTY_PLUGIN_LINT to the SDK CLI entry",
  );
  process.exit(0);
}

const [command, args] = invoke(linter);
const result = spawnSync(command, args, {
  timeout: TIMEOUT_MS,
  encoding: "utf8",
  cwd: REPO_ROOT,
});
process.stdout.write(result.stdout ?? "");
process.stderr.write(result.stderr ?? "");
if (result.error !== undefined && result.error !== null) {
  console.error(`bitty-plugin-lint could not run: ${result.error.message}`);
  process.exit(2);
}
console.log(`bitty-plugin-lint: ${linter} exit=${result.status}`);
process.exit(result.status ?? 1);
