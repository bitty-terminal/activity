#!/usr/bin/env bun
/**
 * Transitional plugin-manifest validator.
 *
 * Validates `bitty-plugin.toml` against the accepted v1 contract. This is a
 * fail-closed local subset of the SDK validator: `bitty-plugin-lint` from
 * `bitty-plugin-sdk` (R-SDK-2) becomes authoritative once published, and this
 * file is replaced by it in generated repositories.
 *
 * Contract references (read-only, owned by bitty-docs and the host):
 *   - `docs/specifications/plugin-platform-rfc.md` (accepted 2026-08-27,
 *     OQ-011/OQ-012): file name, schema, hard limits, closed capabilities.
 *   - `crates/bitty-plugin-host/src/manifest.rs` and
 *     `crates/bitty-package/src/manifest.rs`: implemented validation and the
 *     closed capability head set. Unknown keys and unknown identifiers fail
 *     instead of being ignored (forward compatibility is explicit).
 *
 * Usage:
 *   bun scripts/validate-manifest.mjs <path/to/bitty-plugin.toml>
 */
import { readFileSync, statSync } from "node:fs";

const MANIFEST_MAX_BYTES = 256 * 1024;
const MAX_PLUGIN_ID_LEN = 128;
const MAX_ID_SEGMENT_LEN = 64;
const MAX_NAME_LEN = 128;
const MAX_DESCRIPTION_LEN = 1024;
const MAX_LICENSE_LEN = 256;
const MAX_VERSION_LEN = 64;
const MAX_VERSION_REQ_LEN = 128;
const MAX_DEPENDENCIES = 8;
const MAX_PROVIDED_SERVICES = 16;
const MAX_CAPABILITIES = 64;
const MAX_CAPABILITY_LEN = 256;
const MAX_CAPABILITY_TEXT_BYTES = 8 * 1024;
const MAX_FS_PATTERNS_PER_KIND = 32;
const MAX_FS_PATTERN_LEN = 512;
const MAX_COMMANDS = 128;
const MAX_COMMAND_LEN = 256;
const MAX_RESOURCE_LEN = 128;
const MAX_EVENTS = 256;
const MAX_EVENT_LEN = 128;
const MAX_CLAIM_LEN = 64;

const TOP_LEVEL_KEYS = new Set([
  "plugin",
  "compat",
  "dependencies",
  "services",
  "capabilities",
  "lazy",
]);
const PLUGIN_KEYS = new Set([
  "id",
  "name",
  "version",
  "description",
  "license",
]);
const COMPAT_KEYS = new Set(["bitty", "plugin-api"]);
const SERVICES_KEYS = new Set(["provided"]);
const LAZY_KEYS = new Set(["commands", "events", "claims"]);

/**
 * Closed capability heads, mirrored from
 * `bitty-package` CLOSED_CAPABILITY_HEADS. Family membership alone is never
 * authority; an identifier outside this set fails validation.
 */
const CLOSED_CAPABILITY_HEADS = new Set([
  "terminal.semantic-read",
  "terminal.raw-read",
  "terminal.input.self",
  "terminal.input.all",
  "terminal.manage",
  "ui.rich",
  "ui.overlay",
  "ui.protocol-register",
  "clipboard.read",
  "clipboard.write",
  "fs.read",
  "fs.write",
  "process.spawn",
  "network.connect",
  "runtime.inspect",
  "runtime.configure",
  "runtime.plugin-manage",
  "debug.inspect",
  "debug.trace",
  "debug.control",
  "platform.notify",
  "platform.open-url",
  "platform.image-file",
  "protocol.register",
  "panel.provider",
  "panel.create",
  "panel.focus",
  "panel.overlay",
  "browser.embed",
  "browser.navigation",
  "browser.file-url",
  "browser.storage",
  "agent.context.terminal",
  "agent.context.workspace",
  "agent.memory",
  "mcp.invoke",
  "ai.provider",
  "ai.stream",
  "ai.model",
]);

/** Heads that must carry a `:PARAMETER` and cannot appear as boolean keys. */
const PARAM_REQUIRED_HEADS = new Set([
  "fs.read",
  "fs.write",
  "process.spawn",
  "network.connect",
  "mcp.invoke",
  "agent.memory",
]);

const ALLOWED_VERSION_REQ_CHARS = /^[0-9A-Za-z\s.+\-,<>=^~*|&]+$/;
const PLUGIN_ID_SEGMENT = /^[a-z][a-z0-9_-]*$/;
const SEMVER =
  /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.+\-_]+)?$/;

function fail(message) {
  console.error(`manifest: FAIL ${message}`);
  process.exit(1);
}

function requireObject(value, path) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    fail(`${path} must be a TOML table`);
  }
  return value;
}

function requireString(value, path) {
  if (typeof value !== "string") {
    fail(`${path} must be a string`);
  }
  return value;
}

function rejectUnknownKeys(object, allowed, path) {
  for (const key of Object.keys(object)) {
    if (!allowed.has(key)) {
      fail(`unknown key '${path}.${key}'`);
    }
  }
}

function validatePluginId(raw, path) {
  if (raw.length === 0) {
    fail(`${path} must not be empty`);
  }
  if (raw.length > MAX_PLUGIN_ID_LEN) {
    fail(`${path} exceeds ${MAX_PLUGIN_ID_LEN} characters`);
  }
  const segments = raw.split(".");
  if (segments.length !== 2) {
    fail(`${path} must be exactly owner.name (one dot)`);
  }
  for (const segment of segments) {
    if (
      segment.length === 0 ||
      segment.length > MAX_ID_SEGMENT_LEN ||
      !PLUGIN_ID_SEGMENT.test(segment)
    ) {
      fail(
        `${path} segments must match [a-z][a-z0-9_-]* (max ${MAX_ID_SEGMENT_LEN})`,
      );
    }
  }
}

function validateSemver(raw, path) {
  if (raw.length > MAX_VERSION_LEN) {
    fail(`${path} exceeds ${MAX_VERSION_LEN} characters`);
  }
  if (!SEMVER.test(raw)) {
    fail(`${path} must be SemVer X.Y.Z without leading zeros`);
  }
}

function validateVersionRequirement(raw, path) {
  if (raw.length === 0) {
    fail(`${path} must not be empty`);
  }
  if (raw.length > MAX_VERSION_REQ_LEN) {
    fail(`${path} exceeds ${MAX_VERSION_REQ_LEN} characters`);
  }
  if (!ALLOWED_VERSION_REQ_CHARS.test(raw)) {
    fail(`${path} contains characters outside the accepted operator set`);
  }
}

function validateDisplayText(raw, path, maxLen) {
  if (Buffer.byteLength(raw, "utf8") > maxLen) {
    fail(`${path} exceeds ${maxLen} bytes`);
  }
  if (raw.includes("\0") || raw.includes("\x1b")) {
    fail(`${path} must not contain NUL or ESC`);
  }
}

function validateQualifiedCommand(raw, path, pluginId) {
  if (raw.length === 0 || raw.length > MAX_COMMAND_LEN) {
    fail(`${path} must be 1..${MAX_COMMAND_LEN} bytes`);
  }
  const [idPart, resource] = raw.split(":", 2);
  if (raw.split(":").length !== 2) {
    fail(`${path} must be plugin-id:resource`);
  }
  validatePluginId(idPart, path);
  if (idPart !== pluginId) {
    fail(`${path} must use this plugin's id '${pluginId}'`);
  }
  if (
    resource === undefined ||
    resource.length === 0 ||
    resource.length > MAX_RESOURCE_LEN ||
    !/^[a-z][a-z0-9._-]*$/.test(resource)
  ) {
    fail(
      `${path} resource must match [a-z][a-z0-9._-]* (max ${MAX_RESOURCE_LEN})`,
    );
  }
}

function validateCapabilityHead(head, path) {
  if (head.length > MAX_CAPABILITY_LEN) {
    fail(`${path} exceeds ${MAX_CAPABILITY_LEN} characters`);
  }
  if (head.includes("*")) {
    fail(`${path} must not contain wildcards`);
  }
  const segments = head.split(".");
  if (segments.length < 2 || segments.length > 3) {
    fail(`${path} must be family.resource or family.resource.scope`);
  }
  for (const segment of segments) {
    if (
      segment.length === 0 ||
      segment.length > MAX_ID_SEGMENT_LEN ||
      !PLUGIN_ID_SEGMENT.test(segment)
    ) {
      fail(
        `${path} segments must match [a-z][a-z0-9_-]* (max ${MAX_ID_SEGMENT_LEN})`,
      );
    }
  }
  if (PARAM_REQUIRED_HEADS.has(head)) {
    fail(
      `${path} requires a ':PARAMETER'; use [[capabilities.filesystem]] for fs requests`,
    );
  }
  if (!CLOSED_CAPABILITY_HEADS.has(head)) {
    fail(`${path} is outside the closed capability set`);
  }
}

function validateFilesystem(value, capabilities) {
  if (!Array.isArray(value) || value.length === 0) {
    fail("capabilities.filesystem must be a non-empty array of requests");
  }
  for (const [index, request] of value.entries()) {
    const path = `capabilities.filesystem[${index}]`;
    requireObject(request, path);
    rejectUnknownKeys(request, new Set(["access", "paths"]), path);
    const access = requireString(request.access, `${path}.access`);
    if (access !== "read" && access !== "write") {
      fail(`${path}.access must be "read" or "write"`);
    }
    if (!Array.isArray(request.paths) || request.paths.length === 0) {
      fail(`${path}.paths must be a non-empty array`);
    }
    if (request.paths.length > MAX_FS_PATTERNS_PER_KIND) {
      fail(`${path}.paths exceeds ${MAX_FS_PATTERNS_PER_KIND} patterns`);
    }
    for (const [patternIndex, pattern] of request.paths.entries()) {
      const patternPath = `${path}.paths[${patternIndex}]`;
      requireString(pattern, patternPath);
      if (
        pattern.length === 0 ||
        pattern.length > MAX_FS_PATTERN_LEN ||
        pattern.includes(":") ||
        /[\s\p{Cc}]/u.test(pattern)
      ) {
        fail(
          `${patternPath} must be 1..${MAX_FS_PATTERN_LEN} characters without whitespace or control characters`,
        );
      }
      capabilities.patternBytes += pattern.length;
      capabilities.patternCount += 1;
    }
  }
}

function collectCapabilities(value, capabilities, path) {
  if (value === true) {
    capabilities.heads.push(path);
    return;
  }
  if (value === false) {
    fail(`capabilities.${path}: false is not accepted; omit the key to deny`);
  }
  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    for (const [key, child] of Object.entries(value)) {
      collectCapabilities(child, capabilities, `${path}.${key}`);
    }
    return;
  }
  fail(`capabilities.${path} must be true`);
}

/** Flatten `a.b.c` dotted TOML keys and validate every capability request. */
function validateCapabilities(value) {
  const table = requireObject(value, "capabilities");
  const capabilities = { heads: [], patternBytes: 0, patternCount: 0 };
  for (const [key, child] of Object.entries(table)) {
    if (key === "filesystem") {
      validateFilesystem(child, capabilities);
    } else {
      collectCapabilities(child, capabilities, key);
    }
  }
  const total = capabilities.heads.length + capabilities.patternCount;
  if (total > MAX_CAPABILITIES) {
    fail(`capabilities declares more than ${MAX_CAPABILITIES} requests`);
  }
  let textBytes = capabilities.patternBytes;
  for (const head of capabilities.heads) {
    validateCapabilityHead(head, `capabilities.${head}`);
    textBytes += head.length;
  }
  if (textBytes > MAX_CAPABILITY_TEXT_BYTES) {
    fail(`capabilities text exceeds ${MAX_CAPABILITY_TEXT_BYTES} bytes`);
  }
}

function validateLazy(value, pluginId) {
  const table = requireObject(value, "lazy");
  rejectUnknownKeys(table, LAZY_KEYS, "lazy");
  if (table.commands !== undefined) {
    if (
      !Array.isArray(table.commands) ||
      table.commands.length > MAX_COMMANDS
    ) {
      fail(
        `lazy.commands must be an array of at most ${MAX_COMMANDS} commands`,
      );
    }
    for (const [index, command] of table.commands.entries()) {
      requireString(command, `lazy.commands[${index}]`);
      validateQualifiedCommand(command, `lazy.commands[${index}]`, pluginId);
    }
  }
  if (table.events !== undefined) {
    if (!Array.isArray(table.events) || table.events.length > MAX_EVENTS) {
      fail(`lazy.events must be an array of at most ${MAX_EVENTS} events`);
    }
    for (const [index, event] of table.events.entries()) {
      requireString(event, `lazy.events[${index}]`);
      if (
        event.length === 0 ||
        event.length > MAX_EVENT_LEN ||
        /[\s\0]/.test(event)
      ) {
        fail(
          `lazy.events[${index}] must be 1..${MAX_EVENT_LEN} bytes without whitespace`,
        );
      }
    }
  }
  if (table.claims !== undefined) {
    if (!Array.isArray(table.claims)) {
      fail("lazy.claims must be an array");
    }
    for (const [index, claim] of table.claims.entries()) {
      requireString(claim, `lazy.claims[${index}]`);
      if (claim.length === 0 || claim.length > MAX_CLAIM_LEN) {
        fail(`lazy.claims[${index}] must be 1..${MAX_CLAIM_LEN} bytes`);
      }
    }
  }
}

function validateDependencies(value, pluginId) {
  const table = requireObject(value, "dependencies");
  const entries = [];
  const collect = (node, path) => {
    if (typeof node === "string") {
      entries.push([path, node]);
      return;
    }
    if (typeof node === "object" && node !== null && !Array.isArray(node)) {
      for (const [key, child] of Object.entries(node)) {
        collect(child, `${path}.${key}`);
      }
      return;
    }
    fail(`dependencies.${path} must be a version requirement string`);
  };
  for (const [key, child] of Object.entries(table)) {
    collect(child, key);
  }
  if (entries.length > MAX_DEPENDENCIES) {
    fail(`dependencies declares more than ${MAX_DEPENDENCIES} entries`);
  }
  for (const [id, requirement] of entries) {
    validatePluginId(id, `dependencies.${id}`);
    if (id === pluginId) {
      fail("dependencies must not include the plugin itself");
    }
    validateVersionRequirement(requirement, `dependencies.${id}`);
  }
}

function validateProvidedServices(value) {
  const table = requireObject(value, "services.provided");
  const interfaces = [];
  const collect = (node, path) => {
    if (typeof node === "string") {
      interfaces.push([path, node]);
      return;
    }
    const nested = requireObject(node, `services.provided.${path}`);
    for (const [key, child] of Object.entries(nested)) {
      collect(child, `${path}.${key}`);
    }
  };
  for (const [key, child] of Object.entries(table)) {
    collect(child, key);
  }
  if (interfaces.length > MAX_PROVIDED_SERVICES) {
    fail(
      `services.provided declares more than ${MAX_PROVIDED_SERVICES} interfaces`,
    );
  }
  for (const [iface, version] of interfaces) {
    if (
      iface.length === 0 ||
      iface.length > 128 ||
      iface.includes(" ") ||
      iface
        .split(".")
        .some(
          (segment) =>
            segment.length === 0 ||
            segment.length > MAX_ID_SEGMENT_LEN ||
            !PLUGIN_ID_SEGMENT.test(segment),
        )
    ) {
      fail(
        `services.provided.${iface} must be dot-separated [a-z][a-z0-9_-]* segments (max ${MAX_ID_SEGMENT_LEN})`,
      );
    }
    validateSemver(version, `services.provided.${iface}`);
  }
}

function validateManifest(data) {
  rejectUnknownKeys(data, TOP_LEVEL_KEYS, "manifest");

  const plugin = requireObject(data.plugin, "plugin");
  rejectUnknownKeys(plugin, PLUGIN_KEYS, "plugin");
  const id = requireString(plugin.id, "plugin.id");
  validatePluginId(id, "plugin.id");
  const name = requireString(plugin.name, "plugin.name");
  if (name.trim().length === 0) {
    fail("plugin.name must not be empty");
  }
  validateDisplayText(name, "plugin.name", MAX_NAME_LEN);
  validateSemver(
    requireString(plugin.version, "plugin.version"),
    "plugin.version",
  );
  const description = requireString(plugin.description, "plugin.description");
  validateDisplayText(description, "plugin.description", MAX_DESCRIPTION_LEN);
  if (plugin.license !== undefined) {
    const license = requireString(plugin.license, "plugin.license");
    if (license.trim().length === 0) {
      fail("plugin.license must not be empty when present");
    }
    if (license.length > MAX_LICENSE_LEN) {
      fail(`plugin.license exceeds ${MAX_LICENSE_LEN} characters`);
    }
  }

  if (data.compat !== undefined) {
    const compat = requireObject(data.compat, "compat");
    rejectUnknownKeys(compat, COMPAT_KEYS, "compat");
    if (compat.bitty !== undefined) {
      validateVersionRequirement(
        requireString(compat.bitty, "compat.bitty"),
        "compat.bitty",
      );
    }
    if (compat["plugin-api"] !== undefined) {
      validateVersionRequirement(
        requireString(compat["plugin-api"], "compat.plugin-api"),
        "compat.plugin-api",
      );
    }
  }

  if (data.dependencies !== undefined) {
    validateDependencies(data.dependencies, id);
  }

  if (data.services !== undefined) {
    const services = requireObject(data.services, "services");
    rejectUnknownKeys(services, SERVICES_KEYS, "services");
    if (services.provided !== undefined) {
      validateProvidedServices(services.provided);
    }
  }

  if (data.capabilities !== undefined) {
    validateCapabilities(data.capabilities);
  }

  if (data.lazy !== undefined) {
    validateLazy(data.lazy, id);
  }

  return { id, version: plugin.version };
}

if (typeof Bun === "undefined" || typeof Bun.TOML?.parse !== "function") {
  fail(
    "requires the Bun runtime: bun scripts/validate-manifest.mjs <manifest>",
  );
}

const file = process.argv[2];
if (!file) {
  console.error(
    "usage: bun scripts/validate-manifest.mjs <path/to/bitty-plugin.toml>",
  );
  process.exit(2);
}

let bytes;
try {
  bytes = statSync(file).size;
} catch (error) {
  fail(`cannot read ${file}: ${error.message}`);
}
if (bytes > MANIFEST_MAX_BYTES) {
  fail(`${file} exceeds ${MANIFEST_MAX_BYTES} bytes`);
}

let raw;
try {
  raw = readFileSync(file, "utf8");
} catch (error) {
  fail(`cannot read ${file}: ${error.message}`);
}

let data;
try {
  data = Bun.TOML.parse(raw);
} catch (error) {
  fail(`${file} is not valid TOML: ${error.message}`);
}

const { id, version } = validateManifest(data);
console.log(`manifest: OK ${file} (${id} ${version})`);
