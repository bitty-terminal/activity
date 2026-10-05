-- Entry point for Bitty Activity (bitty-featured.activity).
--
-- The host evaluates this file once per plugin activation and owns every
-- resource created here for the lifetime of that generation. Registration
-- calls are valid only while init.lua executes.
--
-- Surface: the accepted Plugin API v1 bindings from ADR 0009 and the Plugin
-- API v1 Lua Surface RFC, as generated for LuaLS in bitty-plugin-sdk
-- `lua/bitty.d.lua` (R-SDK-1). The module root is `bitty`; one spelling per
-- concept; flat or aliased spellings (for example `bitty.register_command`)
-- are outside the contract and are not used here.
--
-- Capabilities used here must match `bitty-plugin.toml`: the semantic
-- snapshot below is covered by `terminal.semantic-read` and the notification
-- by `platform.notify`. No other authority is granted or assumed. The plugin
-- is local-only: it never opens a socket, spawns a process, touches the
-- filesystem, or reads the environment. Aggregates live in `bitty.store`;
-- command arguments and terminal contents are never persisted (PX-1199).
--
-- Data model and bounds live in `activity.aggregate`; cwd redaction lives in
-- `activity.redact`.

local aggregate = require("activity.aggregate")

local M = {}

local MAX_TRACKED_SESSIONS = 64
-- An unpaired `terminal.opened` older than this is treated as abandoned and is
-- dropped instead of waiting forever for a `terminal.closed` that may never
-- arrive. The bound keeps the pairing table from growing without limit.
local SESSION_MAX_AGE_SECONDS = 24 * 60 * 60

local function is_finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function now_seconds()
  local ok, value = pcall(os.time)
  if ok and type(value) == "number" then
    return math.floor(value)
  end
  return 0
end

local function settings_number(name, default)
  local ok, value = pcall(bitty.settings.get, name)
  if ok and type(value) == "number" then
    return value
  end
  return default
end

local function settings_flag(name, default)
  local ok, value = pcall(bitty.settings.get, name)
  if ok and type(value) == "boolean" then
    return value
  end
  return default
end

-- User setting, narrowing-only in the configuration model. It is read but
-- never written by the plugin, and a `true` value changes nothing in v1:
-- command arguments are not stored by this implementation either way.
local store_command_args = settings_flag("store_command_args", false)
local retention_days = settings_number(
  "retention_days",
  aggregate.DEFAULT_RETENTION_DAYS
)

local state = aggregate.load(bitty.store, now_seconds(), retention_days)
local dirty = false
local write_errors = 0

local function write_state()
  if not dirty then
    return
  end
  local ok, code = aggregate.save(bitty.store, state)
  if ok then
    -- A successful write clears the dirty flag and resets the consecutive
    -- failure counter so transient errors are not reported forever.
    dirty = false
    write_errors = 0
    return
  end
  write_errors = write_errors + 1
  -- Newer-format or unread data is never overwritten, so retrying the same
  -- payload cannot succeed; only a later successful read or an explicit
  -- purge recovers. Other failures stay dirty so the next observation
  -- event or lifecycle flush retries synchronously.
  if code == "E_STORE_VERSION" or code == "E_STORE_UNAVAILABLE" then
    return
  end
end

local function flush_now()
  write_state()
end

-- Synchronous persistence policy, compatible with the accepted activation
-- lifecycle (timer and task creation is valid only while init.lua executes,
-- so no post-activation timer is created here). Events mark the state dirty
-- and persist it immediately; a failed write stays dirty so the next
-- observation event or lifecycle flush retries. Lifecycle handlers flush
-- synchronously so suspension or disposal never drops pending aggregates.
-- Timer delivery is not relied upon and no real scheduling is claimed here;
-- see the behavior tests for in-memory lifecycle/write-failure coverage.
local function schedule_flush()
  dirty = true
  write_state()
end

-- Bounded open/close pairing for session durations. Open times live only in
-- generation-scoped memory; they are never persisted. Entries are bounded by
-- MAX_TRACKED_SESSIONS: abandoned opens are pruned by age and, when the table
-- is still full, the least-recently-opened entry is evicted so new sessions
-- are never permanently starved. An unpaired close records nothing. Only the
-- resulting duration bucket reaches `bitty.store`.
local open_sessions = {}
local open_session_count = 0

-- Drop abandoned entries older than SESSION_MAX_AGE_SECONDS. A non-positive
-- timestamp (clock unavailable) disables age pruning rather than dropping
-- live data. Returns the number of entries dropped.
local function prune_open_sessions(timestamp)
  if not is_finite_number(timestamp) or timestamp <= 0 then
    return 0
  end
  local dropped = 0
  for terminal_id, opened_at in pairs(open_sessions) do
    if is_finite_number(opened_at) and timestamp - opened_at > SESSION_MAX_AGE_SECONDS then
      open_sessions[terminal_id] = nil
      dropped = dropped + 1
    end
  end
  open_session_count = open_session_count - dropped
  return dropped
end

-- Evict the least-recently-opened entry when the table is at capacity.
local function evict_oldest_session()
  local oldest_id = nil
  local oldest_at = nil
  for terminal_id, opened_at in pairs(open_sessions) do
    if oldest_at == nil or opened_at < oldest_at then
      oldest_at = opened_at
      oldest_id = terminal_id
    end
  end
  if oldest_id ~= nil then
    open_sessions[oldest_id] = nil
    open_session_count = open_session_count - 1
  end
end

local function track_session_open(terminal_id, timestamp)
  if not is_finite_number(terminal_id) then
    return
  end
  if open_sessions[terminal_id] ~= nil then
    open_sessions[terminal_id] = timestamp
    return
  end
  prune_open_sessions(timestamp)
  if open_session_count >= MAX_TRACKED_SESSIONS then
    evict_oldest_session()
    if open_session_count >= MAX_TRACKED_SESSIONS then
      -- Nothing was evictable (unreachable with a consistent count): fail
      -- closed rather than exceed the bound.
      return
    end
  end
  open_sessions[terminal_id] = timestamp
  open_session_count = open_session_count + 1
end

local function track_session_close(terminal_id, timestamp)
  if not is_finite_number(terminal_id) then
    return
  end
  local opened_at = open_sessions[terminal_id]
  if opened_at == nil then
    return
  end
  open_sessions[terminal_id] = nil
  open_session_count = open_session_count - 1
  if is_finite_number(opened_at) and timestamp - opened_at > SESSION_MAX_AGE_SECONDS then
    -- The pairing exceeded the abandonment bound; record no duration.
    return
  end
  aggregate.on_session_duration(state, timestamp - opened_at, timestamp)
end

bitty.commands.register({
  id = "summary",
  title = "Activity: show summary",
  description = "Show a privacy-safe summary of locally stored activity aggregates.",
  args_schema = { type = "object", properties = {}, additionalProperties = false },
  result_schema = { type = "string" },
  run = function(_args)
    local timestamp = now_seconds()
    local _, pruned = aggregate.prune(state, timestamp)
    if pruned then
      -- Only persist when pruning actually dropped a bucket; a no-op summary
      -- must not rewrite the store.
      dirty = true
    end
    local zones = nil
    local ok, snapshot = pcall(bitty.terminal.snapshot, { scope = "semantic" })
    if ok and type(snapshot) == "table" and type(snapshot.zones) == "table" then
      zones = #snapshot.zones
    end
    local summary, notify_body = aggregate.render(state, {
      now = timestamp,
      zones = zones,
      write_errors = write_errors,
      args_opt_in = store_command_args,
    })
    flush_now()
    pcall(bitty.notify.show, {
      title = "Bitty Activity",
      body = notify_body,
      urgency = "low",
    })
    return summary
  end,
})

bitty.commands.register({
  id = "clear",
  title = "Activity: clear local data",
  description = "Delete every activity aggregate stored by this plugin.",
  args_schema = { type = "object", properties = {}, additionalProperties = false },
  result_schema = { type = "string" },
  run = function(_args)
    if not aggregate.clear(bitty.store) then
      -- Failed deletion preserves prior in-memory state: aggregates,
      -- session pairing, and error bookkeeping are left untouched.
      return "Activity: clear failed; stored data was not modified"
    end
    -- Successful purge resets pairing and persistence bookkeeping so a
    -- subsequent close cannot record pre-purge duration, old sessions
    -- cannot occupy capacity, and stale errors are not reported.
    state = aggregate.new_state(now_seconds(), retention_days)
    dirty = false
    write_errors = 0
    open_sessions = {}
    open_session_count = 0
    return "Activity: local timeline data cleared"
  end,
})

-- Observation subscriptions validate the fields they consume and fail closed:
-- a malformed payload returns before touching any aggregate, so a bad event
-- can never drift counters, durations, or cwd buckets.
bitty.events.subscribe("terminal.opened", function(event)
  local payload = event.payload
  ---@cast payload BittyTerminalOpenedPayload
  if type(payload) ~= "table" or not is_finite_number(payload.terminal_id) then
    return
  end
  local timestamp = now_seconds()
  aggregate.on_terminal_opened(state, payload.terminal_id, timestamp)
  track_session_open(payload.terminal_id, timestamp)
  schedule_flush()
end)

bitty.events.subscribe("terminal.closed", function(event)
  local payload = event.payload
  ---@cast payload BittyTerminalClosedPayload
  if type(payload) ~= "table" or not is_finite_number(payload.terminal_id) then
    return
  end
  local timestamp = now_seconds()
  aggregate.on_terminal_closed(state, payload.terminal_id, timestamp)
  track_session_close(payload.terminal_id, timestamp)
  schedule_flush()
end)

bitty.events.subscribe("terminal.cwd-changed", function(event)
  local payload = event.payload
  ---@cast payload BittyTerminalCwdChangedPayload
  if type(payload) ~= "table" or type(payload.cwd) ~= "string" then
    return
  end
  aggregate.on_cwd_changed(state, payload.cwd, now_seconds())
  schedule_flush()
end)

bitty.events.subscribe("process.exited", function(event)
  local payload = event.payload
  ---@cast payload BittyProcessExitedPayload
  if type(payload) ~= "table" or not is_finite_number(payload.exit_code) then
    return
  end
  aggregate.on_process_exited(state, payload.exit_code, now_seconds())
  schedule_flush()
end)

bitty.events.subscribe("plugin.suspended", function(_event)
  flush_now()
end)

bitty.events.subscribe("plugin.disposed", function(_event)
  flush_now()
end)

return M
