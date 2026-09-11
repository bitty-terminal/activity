-- Bounded, local-only aggregation state for the activity plugin (bitty-featured.activity).
--
-- One JSON-compatible value is persisted under `timeline.v1`: coarse
-- counters, duration and exit-status buckets, and up to `MAX_CWD_ENTRIES`
-- redacted cwd labels. Command text, command arguments, environment values,
-- terminal content, and full paths are never accepted or written by this
-- module; the only text that can be stored is a bounded, redacted basename
-- produced by `activity.redact`.
--
-- Every field read back from `bitty.store` is untrusted: `load` normalizes
-- types and bounds, ignores unknown fields, and marks data written by a newer
-- format as incompatible instead of overwriting it.

local redact = require("activity.redact")

local M = {}

M.STORE_KEY = "timeline.v1"
M.FORMAT_VERSION = 1
M.DEFAULT_RETENTION_DAYS = 7
M.MIN_RETENTION_DAYS = 1
M.MAX_RETENTION_DAYS = 90
M.MAX_CWD_ENTRIES = 32
M.MAX_SUMMARY_BYTES = 1024
M.MAX_NOTIFY_BODY_BYTES = 200

local SECONDS_PER_DAY = 86400
local MAX_TOP_CWD = 5

local COUNTER_KEYS = {
  "terminals_opened",
  "terminals_closed",
  "cwd_events",
  "exit_events",
  "exits_ok",
  "exits_failed",
  "exits_signaled",
  "exits_unknown",
}

local DURATION_KEYS = { "lt1m", "m1_10", "m10_60", "gt60" }

local function is_finite_number(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function count_or_zero(value)
  if not is_finite_number(value) then
    return 0
  end
  local count = math.floor(value)
  if count < 0 then
    return 0
  end
  return count
end

local function table_size(value)
  local size = 0
  for _ in pairs(value) do
    size = size + 1
  end
  return size
end

-- UTF-8-safe, bounded truncation shared with the label transform.
local truncate_utf8 = redact.truncate_utf8

local function utc_timestamp(seconds)
  local ok, rendered = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ", seconds)
  if ok and type(rendered) == "string" then
    return rendered
  end
  return "unknown"
end

local function clamp_retention(value)
  local days = count_or_zero(value)
  if days < M.MIN_RETENTION_DAYS then
    return M.MIN_RETENTION_DAYS
  end
  if days > M.MAX_RETENTION_DAYS then
    return M.MAX_RETENTION_DAYS
  end
  return days
end

--- Create an empty aggregate state.
function M.new_state(now, retention_days)
  local counters = {}
  for _, key in ipairs(COUNTER_KEYS) do
    counters[key] = 0
  end
  local durations = {}
  for _, key in ipairs(DURATION_KEYS) do
    durations[key] = 0
  end
  return {
    version = M.FORMAT_VERSION,
    incompatible = false,
    updated_at = count_or_zero(now),
    first_seen = count_or_zero(now),
    last_seen = count_or_zero(now),
    retention_days = clamp_retention(retention_days),
    counters = counters,
    durations = durations,
    cwd = { entries = {}, unlisted = 0 },
  }
end

local function normalize_entries(raw_entries)
  local entries = {}
  local unlisted = 0
  if type(raw_entries) ~= "table" then
    return entries, unlisted
  end
  for label, entry in pairs(raw_entries) do
    if type(label) == "string" and type(entry) == "table" then
      local safe_label = redact.redact(label)
      local target = entries[safe_label]
      if target ~= nil then
        target.count = target.count + count_or_zero(entry.count)
        local last_seen = count_or_zero(entry.last_seen)
        if last_seen > target.last_seen then
          target.last_seen = last_seen
        end
      elseif table_size(entries) < M.MAX_CWD_ENTRIES then
        entries[safe_label] = {
          count = count_or_zero(entry.count),
          last_seen = count_or_zero(entry.last_seen),
        }
      else
        unlisted = unlisted + count_or_zero(entry.count)
      end
    end
  end
  return entries, unlisted
end

--- Normalize a value read back from the store into a safe in-memory state.
function M.normalize(raw, now, retention_days)
  if type(raw) ~= "table" or raw.version ~= M.FORMAT_VERSION then
    return M.new_state(now, retention_days)
  end
  local state = M.new_state(now, retention_days)
  state.updated_at = count_or_zero(raw.updated_at)
  state.first_seen = count_or_zero(raw.first_seen)
  state.last_seen = count_or_zero(raw.last_seen)
  state.retention_days = clamp_retention(raw.retention_days)
  if type(raw.counters) == "table" then
    for _, key in ipairs(COUNTER_KEYS) do
      state.counters[key] = count_or_zero(raw.counters[key])
    end
  end
  if type(raw.durations) == "table" then
    for _, key in ipairs(DURATION_KEYS) do
      state.durations[key] = count_or_zero(raw.durations[key])
    end
  end
  if type(raw.cwd) == "table" then
    local entries, unlisted = normalize_entries(raw.cwd.entries)
    state.cwd.entries = entries
    state.cwd.unlisted = count_or_zero(raw.cwd.unlisted) + unlisted
  end
  return state
end

--- Mark a state whose persisted format is newer than this build. Keeping the
-- marker makes `save` refuse to overwrite unknown data; summary output can
-- then tell the user to update the plugin.
local function incompatible_state(now, retention_days)
  local state = M.new_state(now, retention_days)
  state.incompatible = true
  return state
end

--- Load aggregate state from a store namespace, resetting on read failure.
function M.load(store, now, retention_days)
  local ok, raw = pcall(store.get, M.STORE_KEY)
  if not ok then
    return M.new_state(now, retention_days)
  end
  if raw == nil then
    return M.new_state(now, retention_days)
  end
  if type(raw) == "table" and is_finite_number(raw.version) and raw.version > M.FORMAT_VERSION then
    return incompatible_state(now, retention_days)
  end
  return M.normalize(raw, now, retention_days)
end

local function to_payload(state)
  local counters = {}
  for _, key in ipairs(COUNTER_KEYS) do
    counters[key] = state.counters[key]
  end
  local durations = {}
  for _, key in ipairs(DURATION_KEYS) do
    durations[key] = state.durations[key]
  end
  local entries = {}
  for label, entry in pairs(state.cwd.entries) do
    entries[label] = { count = entry.count, last_seen = entry.last_seen }
  end
  return {
    version = M.FORMAT_VERSION,
    updated_at = state.updated_at,
    first_seen = state.first_seen,
    last_seen = state.last_seen,
    retention_days = state.retention_days,
    counters = counters,
    durations = durations,
    cwd = { entries = entries, unlisted = state.cwd.unlisted },
  }
end

--- Persist the aggregate state. Fails soft: returns a boolean and, on
-- failure, a stable local code (store errors surface as `E_STORE_WRITE`).
function M.save(store, state)
  if state.incompatible then
    return false, "E_STORE_VERSION"
  end
  local ok, written = pcall(store.set, M.STORE_KEY, to_payload(state))
  if not ok or written == false then
    return false, "E_STORE_WRITE"
  end
  return true
end

--- Delete every stored aggregate for this plugin.
function M.clear(store)
  local ok, written = pcall(store.set, M.STORE_KEY, nil)
  return ok and written ~= false
end

local function touch(state, now)
  local timestamp = count_or_zero(now)
  if state.first_seen == 0 then
    state.first_seen = timestamp
  end
  if timestamp > state.last_seen then
    state.last_seen = timestamp
  end
  state.updated_at = timestamp
end

function M.on_terminal_opened(state, now)
  state.counters.terminals_opened = state.counters.terminals_opened + 1
  touch(state, now)
end

function M.on_terminal_closed(state, now)
  state.counters.terminals_closed = state.counters.terminals_closed + 1
  touch(state, now)
end

--- Classify an exit status without keeping the raw value. Shells encode
-- signal termination as 128 + N; negative statuses are also treated as
-- signal termination.
function M.classify_exit(code)
  if not is_finite_number(code) then
    return "unknown"
  end
  local status = math.floor(code)
  if status == 0 then
    return "ok"
  end
  if status < 0 or status >= 128 then
    return "signaled"
  end
  return "failed"
end

function M.on_process_exited(state, code, now)
  local class = M.classify_exit(code)
  state.counters.exit_events = state.counters.exit_events + 1
  state.counters["exits_" .. class] = state.counters["exits_" .. class] + 1
  touch(state, now)
end

function M.duration_bucket(seconds)
  if not is_finite_number(seconds) or seconds < 0 then
    return nil
  end
  if seconds < 60 then
    return "lt1m"
  end
  if seconds < 600 then
    return "m1_10"
  end
  if seconds < 3600 then
    return "m10_60"
  end
  return "gt60"
end

--- Record one terminal session duration as a bucket count; raw durations are
-- not stored.
function M.on_session_duration(state, seconds, now)
  local bucket = M.duration_bucket(seconds)
  if bucket ~= nil then
    state.durations[bucket] = state.durations[bucket] + 1
  end
  touch(state, now)
end

function M.on_cwd_changed(state, cwd, now)
  state.counters.cwd_events = state.counters.cwd_events + 1
  local label = redact.redact(cwd)
  local entry = state.cwd.entries[label]
  if entry == nil then
    if table_size(state.cwd.entries) < M.MAX_CWD_ENTRIES then
      entry = { count = 0, last_seen = 0 }
      state.cwd.entries[label] = entry
    else
      state.cwd.unlisted = state.cwd.unlisted + 1
      touch(state, now)
      return
    end
  end
  entry.count = entry.count + 1
  entry.last_seen = count_or_zero(now)
  touch(state, now)
end

--- Drop cwd buckets older than the retention window; dropped counts fold
-- into the bounded `unlisted` total instead of being retained.
function M.prune(state, now)
  local cutoff = count_or_zero(now) - clamp_retention(state.retention_days) * SECONDS_PER_DAY
  for label, entry in pairs(state.cwd.entries) do
    if entry.last_seen < cutoff then
      state.cwd.unlisted = state.cwd.unlisted + entry.count
      state.cwd.entries[label] = nil
    end
  end
  touch(state, now)
  return state
end

local function render_top(entries)
  local ranked = {}
  for label, entry in pairs(entries) do
    ranked[#ranked + 1] = { label = label, count = entry.count }
  end
  table.sort(ranked, function(left, right)
    if left.count ~= right.count then
      return left.count > right.count
    end
    return left.label < right.label
  end)
  local parts = {}
  for index = 1, math.min(#ranked, MAX_TOP_CWD) do
    local item = ranked[index]
    parts[#parts + 1] = string.format("%s (%d)", item.label, item.count)
  end
  return table.concat(parts, ", "), #ranked
end

local function push(lines, line)
  lines[#lines + 1] = line
end

--- Render the local summary. Never echoes stored raw text beyond redacted
-- labels; the result is bounded to `MAX_SUMMARY_BYTES` and never contains
-- control characters. Returns `summary, notify_body`.
function M.render(state, opts)
  opts = opts or {}
  local now = count_or_zero(opts.now)
  local lines = {}
  push(lines, "Bitty Activity - local-only aggregates (no telemetry, no network)")
  if state.incompatible then
    push(lines, "stored data was written by a newer plugin version; not modified")
    if opts.write_errors ~= nil and count_or_zero(opts.write_errors) > 0 then
      push(lines, string.format("writes failed: %d", count_or_zero(opts.write_errors)))
    end
    return table.concat(lines, "\n"), "Activity data format is newer than this build"
  end
  push(
    lines,
    string.format(
      "window: last %d day(s) | first seen %s",
      clamp_retention(state.retention_days),
      utc_timestamp(state.first_seen)
    )
  )
  push(
    lines,
    string.format(
      "sessions: %d opened, %d closed | events: %d cwd, %d exit",
      state.counters.terminals_opened,
      state.counters.terminals_closed,
      state.counters.cwd_events,
      state.counters.exit_events
    )
  )
  push(
    lines,
    string.format(
      "exits: %d ok, %d failed, %d signaled, %d unknown",
      state.counters.exits_ok,
      state.counters.exits_failed,
      state.counters.exits_signaled,
      state.counters.exits_unknown
    )
  )
  push(
    lines,
    string.format(
      "durations: <1m %d, 1-10m %d, 10-60m %d, >60m %d",
      state.durations.lt1m,
      state.durations.m1_10,
      state.durations.m10_60,
      state.durations.gt60
    )
  )
  local top, total = render_top(state.cwd.entries)
  local cwd_line = string.format("cwd buckets: %d tracked", total)
  if state.cwd.unlisted > 0 then
    cwd_line = cwd_line .. string.format(", %d collapsed", state.cwd.unlisted)
  end
  if top ~= "" then
    cwd_line = cwd_line .. " | top: " .. top
  end
  push(lines, cwd_line)
  if opts.zones ~= nil then
    push(lines, string.format("focused terminal: %d visible semantic zone(s)", count_or_zero(opts.zones)))
  end
  if opts.write_errors ~= nil and count_or_zero(opts.write_errors) > 0 then
    push(lines, string.format("writes failed: %d (changes kept in memory until a flush succeeds)", count_or_zero(opts.write_errors)))
  end
  push(lines, "stored: counters, coarse timestamps, redacted directory names")
  push(lines, "never stored: command arguments or text, terminal content, paths, environment")
  if opts.args_opt_in == true then
    push(lines, "arguments: opt-in setting requested; v1 still stores none")
  else
    push(lines, "arguments: never stored (default)")
  end
  local summary = truncate_utf8(table.concat(lines, "\n"), M.MAX_SUMMARY_BYTES)
  local notify_body = truncate_utf8(
    string.format(
      "%d session(s), %d cwd event(s), %d exit(s); top dirs stored locally only",
      state.counters.terminals_opened,
      state.counters.cwd_events,
      state.counters.exit_events
    ),
    M.MAX_NOTIFY_BODY_BYTES
  )
  return summary, notify_body
end

return M
