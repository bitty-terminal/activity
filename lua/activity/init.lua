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

local FLUSH_DELAY_MS = 5000
local MAX_TRACKED_SESSIONS = 64

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
local pending_flush = nil
local dirty = false
local write_errors = 0

local function write_state()
  if not dirty then
    return
  end
  local ok = aggregate.save(bitty.store, state)
  if ok then
    dirty = false
  else
    write_errors = write_errors + 1
  end
end

local function flush_now()
  if pending_flush ~= nil then
    pcall(bitty.timers.cancel, pending_flush)
    pending_flush = nil
  end
  write_state()
end

-- Coalesce store writes: events mark the state dirty and one bounded one-shot
-- timer flushes it. Lifecycle handlers flush immediately so suspension or
-- disposal never drops pending aggregates.
local function schedule_flush()
  dirty = true
  if pending_flush ~= nil then
    return
  end
  local ok, handle = pcall(bitty.timers.create, FLUSH_DELAY_MS, function()
    pending_flush = nil
    write_state()
  end)
  if ok and type(handle) == "number" then
    pending_flush = handle
  else
    -- Timer budget exhausted or unavailable: write synchronously instead of
    -- leaving aggregates in memory indefinitely.
    write_state()
  end
end

-- Bounded open/close pairing for session durations. Open times live only in
-- generation-scoped memory; they are never persisted. At most
-- MAX_TRACKED_SESSIONS terminals are paired, and an unpaired close records
-- nothing. Only the resulting duration bucket reaches `bitty.store`.
local open_sessions = {}
local open_session_count = 0

local function track_session_open(terminal_id, timestamp)
  if type(terminal_id) ~= "number" then
    return
  end
  if open_sessions[terminal_id] ~= nil then
    open_sessions[terminal_id] = timestamp
    return
  end
  if open_session_count >= MAX_TRACKED_SESSIONS then
    return
  end
  open_sessions[terminal_id] = timestamp
  open_session_count = open_session_count + 1
end

local function track_session_close(terminal_id, timestamp)
  if type(terminal_id) ~= "number" then
    return
  end
  local opened_at = open_sessions[terminal_id]
  if opened_at == nil then
    return
  end
  open_sessions[terminal_id] = nil
  open_session_count = open_session_count - 1
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
    aggregate.prune(state, timestamp)
    dirty = true
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
      return "Activity: clear failed; stored data was not modified"
    end
    if pending_flush ~= nil then
      pcall(bitty.timers.cancel, pending_flush)
      pending_flush = nil
    end
    state = aggregate.new_state(now_seconds(), retention_days)
    dirty = false
    return "Activity: local timeline data cleared"
  end,
})

bitty.events.subscribe("terminal.opened", function(event)
  local payload = event.payload
  ---@cast payload BittyTerminalOpenedPayload
  local timestamp = now_seconds()
  aggregate.on_terminal_opened(state, timestamp)
  track_session_open(payload.terminal_id, timestamp)
  schedule_flush()
end)

bitty.events.subscribe("terminal.closed", function(event)
  local payload = event.payload
  ---@cast payload BittyTerminalClosedPayload
  local timestamp = now_seconds()
  aggregate.on_terminal_closed(state, timestamp)
  track_session_close(payload.terminal_id, timestamp)
  schedule_flush()
end)

bitty.events.subscribe("terminal.cwd-changed", function(event)
  local payload = event.payload
  ---@cast payload BittyTerminalCwdChangedPayload
  aggregate.on_cwd_changed(state, payload.cwd, now_seconds())
  schedule_flush()
end)

bitty.events.subscribe("process.exited", function(event)
  local payload = event.payload
  ---@cast payload BittyProcessExitedPayload
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
