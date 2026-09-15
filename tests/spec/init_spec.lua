-- End-to-end behavior tests for the activity entry point against the local
-- `bitty` host stub.

local MockHost = require("support.mock_host")

local M = {}

local COMMANDS = {
  "bitty-featured.activity:summary",
  "bitty-featured.activity:clear",
}

local EVENTS = {
  "terminal.opened",
  "terminal.closed",
  "terminal.cwd-changed",
  "process.exited",
  "plugin.suspended",
  "plugin.disposed",
}

function M.run(context)
  local tap = context.tap
  local root = context.root
  print("# init")

  -- Mirrors lua/activity/init.lua SESSION_MAX_AGE_SECONDS (24h abandonment
  -- bound for unpaired open sessions).
  local SESSION_MAX_AGE_SECONDS = 24 * 60 * 60

  local function new_host(options)
    options = options or {}
    options.grants = options.grants or { "platform.notify", "terminal.semantic-read" }
    options.commands = options.commands or COMMANDS
    options.events = options.events or EVENTS
    return MockHost.new(options)
  end

  local function load_plugin(host)
    _G.bitty = host.bitty
    local chunk = assert(loadfile(root .. "/lua/activity/init.lua"))
    return chunk()
  end

  local registration = new_host()
  local module = load_plugin(registration)
  tap.equal(type(module), "table", "entry point returns a module table")
  tap.ok(registration.commands["bitty-featured.activity:summary"] ~= nil, "summary command registered")
  tap.ok(registration.commands["bitty-featured.activity:clear"] ~= nil, "clear command registered")
  tap.equal(#registration.subscriptions, #EVENTS, "every declared event is subscribed")
  local summary_def = registration.commands["bitty-featured.activity:summary"]
  tap.equal(summary_def.args_schema.type, "object", "summary declares an args schema")
  tap.equal(summary_def.args_schema.additionalProperties, false, "summary args are closed")
  tap.equal(summary_def.result_schema.type, "string", "summary declares a result schema")

  local host = new_host()
  load_plugin(host)
  host:publish("terminal.opened", { terminal_id = 1 })
  host:publish("terminal.opened", { terminal_id = 2 })
  host:publish("terminal.closed", { terminal_id = 1 })
  host:publish("terminal.cwd-changed", { cwd = "/home/dev/project/src" })
  host:publish("terminal.cwd-changed", { cwd = "/home/dev/project/docs" })
  host:publish("terminal.cwd-changed", { cwd = "/home/dev/project/src" })
  host:publish("process.exited", { exit_code = 0 })
  host:publish("process.exited", { exit_code = 1 })
  host:publish("process.exited", { exit_code = 130 })
  tap.equal(host.store_data["timeline.v1"], nil, "writes are coalesced behind the timer")
  tap.equal(host:pending_timers(), 1, "one bounded flush timer is pending")
  host:advance(5000)
  tap.equal(host:pending_timers(), 0, "flush timer is one-shot")

  local payload = host.store_data["timeline.v1"]
  tap.ok(payload ~= nil, "state is flushed after the timer fires")
  tap.equal(payload.counters.terminals_opened, 2, "terminal opens counted")
  tap.equal(payload.counters.terminals_closed, 1, "terminal closes counted")
  tap.equal(payload.counters.cwd_events, 3, "cwd changes counted")
  tap.equal(payload.counters.exits_ok, 1, "exit ok counted")
  tap.equal(payload.counters.exits_failed, 1, "exit failed counted")
  tap.equal(payload.counters.exits_signaled, 1, "exit signaled counted")
  tap.equal(payload.cwd.entries.src.count, 2, "redacted cwd aggregate stored")
  tap.equal(payload.cwd.entries.docs.count, 1, "redacted cwd aggregate stored")
  tap.equal(payload.cwd.entries["project"], nil, "parent directory is never stored")
  tap.equal(#host.settings_writes, 0, "plugin never writes user settings")

  local stored_text = ""
  for key, value in pairs(host.store_data) do
    stored_text = stored_text .. key .. "=" .. tostring(value)
  end
  tap.not_contains(stored_text, "/home/dev", "store never receives the raw path")

  local suspend_host = new_host()
  load_plugin(suspend_host)
  suspend_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  tap.equal(suspend_host:pending_timers(), 1, "flush timer is pending before suspend")
  suspend_host:suspend()
  tap.equal(suspend_host:pending_timers(), 0, "suspend cancels the pending timer")
  tap.ok(suspend_host.store_data["timeline.v1"] ~= nil, "suspend flushes pending state")

  local fake_now = 1700000000
  local real_time = os.time
  os.time = function()
    return fake_now
  end
  local duration_host = new_host()
  load_plugin(duration_host)
  duration_host:publish("terminal.opened", { terminal_id = 1 })
  fake_now = fake_now + 90
  duration_host:publish("terminal.closed", { terminal_id = 1 })
  duration_host:publish("terminal.opened", { terminal_id = 2 })
  fake_now = fake_now + 700
  duration_host:publish("terminal.closed", { terminal_id = 2 })
  duration_host:publish("terminal.opened", { terminal_id = 3 })
  fake_now = fake_now + 4000
  duration_host:publish("terminal.closed", { terminal_id = 3 })
  duration_host:publish("terminal.closed", { terminal_id = 99 })
  duration_host:publish("terminal.opened", { terminal_id = 4 })
  duration_host:advance(5000)
  os.time = real_time
  local duration_payload = duration_host.store_data["timeline.v1"]
  tap.equal(duration_payload.durations.lt1m, 0, "sub-minute sessions are not recorded")
  tap.equal(duration_payload.durations.m1_10, 1, "1-10m session bucket recorded")
  tap.equal(duration_payload.durations.m10_60, 1, "10-60m session bucket recorded")
  tap.equal(duration_payload.durations.gt60, 1, ">60m session bucket recorded")
  tap.equal(duration_payload.counters.terminals_opened, 4, "opens still counted")
  tap.equal(duration_payload.counters.terminals_closed, 4, "closes still counted")

  local cap_now = 1700000000
  local real_time_cap = os.time
  os.time = function()
    return cap_now
  end
  local cap_host = new_host()
  load_plugin(cap_host)
  for id = 1, 70 do
    cap_host:publish("terminal.opened", { terminal_id = id })
  end
  cap_now = cap_now + 61
  for id = 1, 70 do
    cap_host:publish("terminal.closed", { terminal_id = id })
  end
  cap_host:advance(5000)
  os.time = real_time_cap
  local cap_payload = cap_host.store_data["timeline.v1"]
  tap.equal(cap_payload.durations.m1_10, 64, "duration pairing is bounded to 64 sessions")
  tap.equal(cap_payload.counters.terminals_opened, 70, "over-cap opens are still counted")

  -- M-ACT-01: a burst of unpaired opens must not permanently starve new
  -- sessions; the least-recently-opened entry is evicted at the cap.
  local evict_now = 1700000000
  local real_time_evict = os.time
  os.time = function()
    return evict_now
  end
  local evict_host = new_host()
  load_plugin(evict_host)
  for id = 1, 200 do
    evict_now = evict_now + 1
    evict_host:publish("terminal.opened", { terminal_id = id })
  end
  evict_now = evict_now + 61
  for id = 137, 200 do
    evict_host:publish("terminal.closed", { terminal_id = id })
  end
  evict_host:advance(5000)
  os.time = real_time_evict
  local evict_payload = evict_host.store_data["timeline.v1"]
  tap.equal(evict_payload.durations.m1_10, 64, "cap evicts oldest opens so newest sessions still pair")
  tap.equal(evict_payload.counters.terminals_opened, 200, "every valid open is counted regardless of the cap")

  -- M-ACT-01: an unpaired open older than the abandonment bound is pruned by
  -- age and records no duration when its identity is reused later.
  local age_now = 1700000000
  local real_time_age = os.time
  os.time = function()
    return age_now
  end
  local age_host = new_host()
  load_plugin(age_host)
  age_host:publish("terminal.opened", { terminal_id = 1 })
  age_now = age_now + SESSION_MAX_AGE_SECONDS + 1
  age_host:publish("terminal.opened", { terminal_id = 2 })
  age_host:publish("terminal.closed", { terminal_id = 1 })
  age_now = age_now + 61
  age_host:publish("terminal.closed", { terminal_id = 2 })
  age_host:advance(5000)
  os.time = real_time_age
  local age_payload = age_host.store_data["timeline.v1"]
  tap.equal(age_payload.durations.m1_10, 1, "the fresh session records its bucket")
  tap.equal(age_payload.durations.gt60, 0, "the stale abandoned open is pruned instead of recording a duration")
  tap.equal(age_payload.counters.terminals_opened, 2, "opens are still counted")
  tap.equal(age_payload.counters.terminals_closed, 2, "closes are still counted")

  -- R22: malformed payloads fail closed per event and never drift aggregates.
  local malformed_host = new_host()
  load_plugin(malformed_host)
  malformed_host:publish("terminal.opened", {})
  malformed_host:publish("terminal.opened", { terminal_id = "1" })
  malformed_host:publish("terminal.opened", { terminal_id = 0 / 0 })
  malformed_host:publish("terminal.closed", {})
  malformed_host:publish("terminal.closed", { terminal_id = false })
  malformed_host:publish("terminal.closed", { terminal_id = "1" })
  malformed_host:publish("terminal.cwd-changed", {})
  malformed_host:publish("terminal.cwd-changed", { cwd = 42 })
  malformed_host:publish("terminal.cwd-changed", { cwd = {} })
  malformed_host:publish("process.exited", {})
  malformed_host:publish("process.exited", { exit_code = "0" })
  malformed_host:publish("process.exited", { exit_code = 0 / 0 })
  tap.equal(malformed_host:pending_timers(), 0, "malformed events arm no flush timer")
  local malformed_summary = malformed_host:run("summary")
  tap.contains(malformed_summary, "sessions: 0 opened, 0 closed", "malformed opens/closes do not drift counters")
  tap.contains(malformed_summary, "events: 0 cwd, 0 exit", "malformed cwd/exit do not drift counters")
  tap.equal(malformed_host.store_data["timeline.v1"], nil, "malformed-only events persist nothing")
  malformed_host:publish("terminal.opened", { terminal_id = 1 })
  tap.equal(malformed_host:pending_timers(), 1, "a valid event after malformed ones still arms a flush")
  malformed_host:advance(5000)
  tap.equal(
    malformed_host.store_data["timeline.v1"].counters.terminals_opened,
    1,
    "a valid event after malformed ones still counts"
  )

  -- M-ACT-02: a failed flush re-arms a bounded retry; a later success persists
  -- without any further external event and clears the failure counter.
  local retry_host = new_host()
  load_plugin(retry_host)
  local retry_real_set = retry_host.bitty.store.set
  local retry_failures = 1
  retry_host.bitty.store.set = function(key, value)
    if retry_failures > 0 then
      retry_failures = retry_failures - 1
      error({ class = "runtime", code = "E_STORE_WRITE", message = "injected store failure" })
    end
    return retry_real_set(key, value)
  end
  retry_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  tap.equal(retry_host:pending_timers(), 1, "the first flush is scheduled")
  retry_host:advance(5000)
  tap.equal(retry_host.store_data["timeline.v1"], nil, "a failed write leaves no stored value")
  tap.equal(retry_host:pending_timers(), 1, "a failed write re-arms exactly one retry")
  retry_host:advance(5000)
  tap.ok(retry_host.store_data["timeline.v1"] ~= nil, "the retry persists without another event")
  local retry_summary = retry_host:run("summary")
  tap.not_contains(retry_summary, "writes failed", "the failure counter resets after a successful write")

  -- M-ACT-02: retries are bounded; a persistent outage stops after the budget
  -- instead of spinning timers forever.
  local bounded_host = new_host()
  load_plugin(bounded_host)
  bounded_host.bitty.store.set = function()
    error({ class = "runtime", code = "E_STORE_WRITE", message = "always fails" })
  end
  bounded_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  for _ = 1, 6 do
    bounded_host:advance(100000)
  end
  tap.equal(bounded_host:pending_timers(), 0, "retries stop after the bounded budget")
  local bounded_summary = bounded_host:run("summary")
  tap.contains(bounded_summary, "writes failed: 6", "the failure count reflects the bounded attempts")

  local utf8_host = new_host()
  local utf8_ok, utf8_err = pcall(function()
    utf8_host.bitty.store.set("timeline.v1", { bad = string.char(0xFF) })
  end)
  tap.equal(utf8_ok, false, "mock store rejects invalid UTF-8 values")
  if not utf8_ok then
    tap.equal(utf8_err.code, "E_STORE_VALUE_INVALID", "UTF-8 rejection uses the stable code")
  end

  local command_host = new_host()
  load_plugin(command_host)
  command_host:publish("terminal.opened", { terminal_id = 7 })
  command_host:publish("terminal.cwd-changed", { cwd = "/home/dev/project/src" })
  local summary = command_host:run("summary")
  tap.equal(command_host.snapshot_calls, 1, "summary reads one semantic snapshot")
  tap.equal(#command_host.notifications, 1, "summary raises one local notification")
  tap.equal(command_host.notifications[1].title, "Bitty Activity", "notification is attributed")
  tap.contains(summary, "focused terminal: 2", "summary reports visible semantic zones")
  tap.contains(summary, "sessions: 1 opened", "summary reports session counts")
  tap.le(#summary, 1024, "summary stays bounded")

  local clear_result = command_host:run("clear")
  tap.contains(clear_result, "cleared", "clear reports success")
  tap.equal(command_host.store_data["timeline.v1"], nil, "clear deletes stored aggregates")
  local after_clear = command_host:run("summary")
  tap.contains(after_clear, "sessions: 0 opened", "summary reflects the cleared state")

  local settings_host = new_host({ settings = { retention_days = 2, store_command_args = true } })
  load_plugin(settings_host)
  settings_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  local settings_summary = settings_host:run("summary")
  tap.contains(settings_summary, "arguments: opt-in setting requested", "opt-in is surfaced but inert")
  tap.contains(settings_summary, "last 2 day(s)", "retention setting is honored")
  tap.equal(#settings_host.settings_writes, 0, "settings remain user-owned")

  -- R23: the user's current retention setting wins over the stored value.
  local precedence_host = new_host({ settings = { retention_days = 2 } })
  precedence_host.store_data["timeline.v1"] = {
    version = 1,
    updated_at = 1,
    first_seen = 1,
    last_seen = 1,
    retention_days = 30,
    counters = {},
    durations = {},
    cwd = { entries = {}, unlisted = 0 },
  }
  load_plugin(precedence_host)
  local precedence_summary = precedence_host:run("summary")
  tap.contains(precedence_summary, "last 2 day(s)", "user setting takes precedence over stored retention")

  -- R23: a no-op summary (nothing to prune, nothing dirty) must not rewrite.
  local noop_host = new_host()
  load_plugin(noop_host)
  tap.equal(noop_host.store_data["timeline.v1"], nil, "loading an empty store writes nothing")
  local noop_summary = noop_host:run("summary")
  tap.contains(noop_summary, "sessions: 0 opened", "a no-op summary renders the empty state")
  tap.equal(noop_host.store_data["timeline.v1"], nil, "a no-op summary does not persist")

  local newer_host = new_host()
  newer_host.store_data["timeline.v1"] = { version = 99 }
  load_plugin(newer_host)
  newer_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  newer_host:advance(5000)
  tap.equal(newer_host.store_data["timeline.v1"].version, 99, "newer stored data is never overwritten")
  local newer_summary = newer_host:run("summary")
  tap.contains(newer_summary, "newer plugin version", "summary explains newer stored data")
  tap.contains(newer_summary, "writes failed: 1", "summary reports refused writes")

  local prune_host = new_host()
  prune_host.store_data["timeline.v1"] = {
    version = 1,
    updated_at = 1,
    first_seen = 1,
    last_seen = 1,
    retention_days = 7,
    counters = {},
    durations = {},
    cwd = { entries = { old = { count = 4, last_seen = 1 } }, unlisted = 0 },
  }
  load_plugin(prune_host)
  local prune_summary = prune_host:run("summary")
  tap.contains(prune_summary, "collapsed", "summary reports pruned buckets")
  local pruned_payload = prune_host.store_data["timeline.v1"]
  tap.equal(pruned_payload.cwd.entries.old, nil, "expired bucket is removed on summary")
  tap.equal(pruned_payload.cwd.unlisted, 4, "expired bucket count is preserved as a total")

  local single_key = 0
  for _ in pairs(prune_host.store_data) do
    single_key = single_key + 1
  end
  tap.equal(single_key, 1, "plugin persists exactly one bounded store value")
end

return M
