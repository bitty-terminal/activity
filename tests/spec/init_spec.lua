-- End-to-end behavior tests for the activity entry point against the local
-- `bitty` host stub.
--
-- Persistence policy under test (PLUG-APP-001): synchronous writes compatible
-- with the accepted activation lifecycle. Timer and task creation is valid
-- only while init.lua executes, so the plugin creates no post-activation
-- timers here; events persist immediately and lifecycle handlers flush
-- synchronously. Timer delivery is not relied upon and no real scheduling is
-- claimed; this suite covers the in-memory lifecycle/write-failure behavior.

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
    local module = chunk()
    host:seal_activation()
    return module
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

  -- PLUG-APP-001: the mock enforces the activation-only registration window.
  local window_ok, window_err = pcall(registration.bitty.timers.create, 1000, function() end)
  tap.equal(window_ok, false, "post-activation timer creation is rejected")
  if not window_ok then
    tap.equal(window_err.code, "E_REGISTRATION_CLOSED", "timer rejection uses the stable code")
  end
  local cmd_ok, cmd_err = pcall(registration.bitty.commands.register, { id = "late" })
  tap.equal(cmd_ok, false, "post-activation command registration is rejected")
  if not cmd_ok then
    tap.equal(cmd_err.code, "E_REGISTRATION_CLOSED", "command rejection uses the stable code")
  end

  -- Synchronous persistence: events are written immediately, no timer is
  -- created, and the store holds the aggregates without any clock advance.
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
  tap.equal(host:pending_timers(), 0, "synchronous policy creates no flush timer")
  tap.ok(host.store_data["timeline.v1"] ~= nil, "events persist synchronously")

  local payload = host.store_data["timeline.v1"]
  tap.ok(payload ~= nil, "state is stored after events")
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

  -- Lifecycle: suspend and dispose flush synchronously; with synchronous
  -- writes the store already holds the state and no timer exists.
  local suspend_host = new_host()
  load_plugin(suspend_host)
  suspend_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  tap.equal(suspend_host:pending_timers(), 0, "no flush timer is pending before suspend")
  tap.ok(suspend_host.store_data["timeline.v1"] ~= nil, "event persisted before suspend")
  suspend_host:suspend()
  tap.equal(suspend_host:pending_timers(), 0, "suspend leaves no timer")
  tap.ok(suspend_host.store_data["timeline.v1"] ~= nil, "suspend keeps persisted state")
  suspend_host:dispose()
  tap.equal(suspend_host:pending_timers(), 0, "dispose leaves no timer")
  tap.ok(suspend_host.store_data["timeline.v1"] ~= nil, "dispose keeps persisted state")

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
  tap.equal(malformed_host:pending_timers(), 0, "malformed events create no timer")
  local malformed_summary = malformed_host:run("summary")
  tap.contains(malformed_summary, "sessions: 0 opened, 0 closed", "malformed opens/closes do not drift counters")
  tap.contains(malformed_summary, "events: 0 cwd, 0 exit", "malformed cwd/exit do not drift counters")
  tap.equal(malformed_host.store_data["timeline.v1"], nil, "malformed-only events persist nothing")
  malformed_host:publish("terminal.opened", { terminal_id = 1 })
  tap.equal(malformed_host:pending_timers(), 0, "a valid event still uses no timer")
  tap.equal(
    malformed_host.store_data["timeline.v1"].counters.terminals_opened,
    1,
    "a valid event after malformed ones still counts"
  )

  -- Synchronous write-failure handling: a failed write stays dirty with no
  -- timer; the next observation event retries synchronously and a success
  -- clears the failure counter.
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
  tap.equal(retry_host.store_data["timeline.v1"], nil, "a failed write leaves no stored value")
  tap.equal(retry_host:pending_timers(), 0, "a failed write creates no retry timer")
  retry_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  tap.ok(retry_host.store_data["timeline.v1"] ~= nil, "the next event retries synchronously")
  local retry_summary = retry_host:run("summary")
  tap.not_contains(retry_summary, "writes failed", "the failure counter resets after a successful write")

  -- A persistent outage never spins timers: every failing event increments
  -- the consecutive-failure counter and stays dirty for the next retry.
  local bounded_host = new_host()
  load_plugin(bounded_host)
  bounded_host.bitty.store.set = function()
    error({ class = "runtime", code = "E_STORE_WRITE", message = "always fails" })
  end
  bounded_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  bounded_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  bounded_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  tap.equal(bounded_host:pending_timers(), 0, "a persistent outage creates no timers")
  tap.equal(bounded_host.store_data["timeline.v1"], nil, "a persistent outage stores nothing")
  local bounded_summary = bounded_host:run("summary")
  tap.contains(bounded_summary, "writes failed: 3", "the failure count reflects each synchronous attempt")

  -- PLUG-APP-002: a thrown read marks the state unavailable; later writes
  -- must not replace the unread history, including unread newer-format data.
  -- Only a later successful read or an explicit purge recovers.
  local unavail_host = new_host()
  unavail_host.store_data["timeline.v1"] = { version = 99 }
  local unavail_real_get = unavail_host.bitty.store.get
  local unavail_get_calls = 0
  unavail_host.bitty.store.get = function(key)
    unavail_get_calls = unavail_get_calls + 1
    if unavail_get_calls == 1 then
      error({ class = "runtime", code = "E_STORE_READ", message = "injected read failure" })
    end
    return unavail_real_get(key)
  end
  load_plugin(unavail_host)
  unavail_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  tap.equal(unavail_host.store_data["timeline.v1"].version, 99, "unread newer-format data is never overwritten")
  tap.equal(unavail_host:pending_timers(), 0, "an unavailable write creates no timer")
  local unavail_summary = unavail_host:run("summary")
  tap.contains(unavail_summary, "currently unavailable", "summary explains the unavailable state")
  tap.contains(unavail_summary, "writes failed: 1", "summary reports the refused write")

  -- A later successful read (next activation) sees the preserved newer
  -- format instead of the empty replacement that a naive reset would write.
  local recovery_host = new_host({ store = unavail_host.store_data })
  load_plugin(recovery_host)
  local recovery_summary = recovery_host:run("summary")
  tap.contains(recovery_summary, "newer plugin version", "recovery distinguishes newer-format data")
  tap.equal(recovery_host.store_data["timeline.v1"].version, 99, "recovery preserves the newer-format value")

  -- An explicit purge recovers from the unavailable state to an available
  -- empty state.
  local purge_unavail_result = unavail_host:run("clear")
  tap.contains(purge_unavail_result, "cleared", "purge recovers from the unavailable state")
  local after_unavail_purge = unavail_host:run("summary")
  tap.not_contains(after_unavail_purge, "unavailable", "purged state is available again")
  tap.contains(after_unavail_purge, "sessions: 0 opened", "purged state is empty")

  -- PLUG-APP-003: a successful purge resets session pairing and persistence
  -- bookkeeping so pre-purge opens record nothing afterwards.
  local purge_now = 1700000000
  local real_time_purge = os.time
  os.time = function()
    return purge_now
  end
  local purge_host = new_host()
  load_plugin(purge_host)
  purge_host:publish("terminal.opened", { terminal_id = 1 })
  purge_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  local purge_real_set = purge_host.bitty.store.set
  local purge_fail_once = 1
  purge_host.bitty.store.set = function(key, value)
    if purge_fail_once > 0 then
      purge_fail_once = purge_fail_once - 1
      error({ class = "runtime", code = "E_STORE_WRITE", message = "injected write failure" })
    end
    return purge_real_set(key, value)
  end
  purge_now = purge_now + 10
  purge_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  local pre_purge_summary = purge_host:run("summary")
  tap.contains(pre_purge_summary, "writes failed", "bookkeeping records the write error before purge")
  purge_host.bitty.store.set = purge_real_set
  local purge_result = purge_host:run("clear")
  tap.contains(purge_result, "cleared", "purge reports success")
  tap.equal(purge_host.store_data["timeline.v1"], nil, "purge deletes stored aggregates")
  purge_now = purge_now + 61
  purge_host:publish("terminal.closed", { terminal_id = 1 })
  local post_purge_payload = purge_host.store_data["timeline.v1"]
  tap.equal(post_purge_payload.durations.m1_10, 0, "a pre-purge open records no duration after purge")
  tap.equal(post_purge_payload.durations.lt1m, 0, "no duration bucket is recorded after purge")
  local post_purge_summary = purge_host:run("summary")
  tap.not_contains(post_purge_summary, "writes failed", "purge resets the error bookkeeping")
  tap.contains(post_purge_summary, "sessions: 0 opened", "purge resets the in-memory aggregates")
  os.time = real_time_purge

  -- PLUG-APP-003: a failed purge preserves prior state: stored data,
  -- session pairing, and error bookkeeping are left untouched.
  local fail_now = 1700000000
  local real_time_fail = os.time
  os.time = function()
    return fail_now
  end
  local fail_host = new_host()
  load_plugin(fail_host)
  fail_host:publish("terminal.opened", { terminal_id = 5 })
  fail_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  tap.ok(fail_host.store_data["timeline.v1"] ~= nil, "state is stored before the failed purge")
  fail_host.bitty.store.set = function()
    error({ class = "runtime", code = "E_STORE_WRITE", message = "purge deletion fails" })
  end
  fail_now = fail_now + 10
  fail_host:publish("terminal.cwd-changed", { cwd = "/srv/app" })
  local fail_result = fail_host:run("clear")
  tap.contains(fail_result, "not modified", "failed purge reports no modification")
  tap.ok(fail_host.store_data["timeline.v1"] ~= nil, "failed purge preserves stored aggregates")
  local fail_summary = fail_host:run("summary")
  tap.contains(fail_summary, "writes failed", "failed purge preserves error bookkeeping")
  fail_now = fail_now + 61
  fail_host:publish("terminal.closed", { terminal_id = 5 })
  local fail_payload = fail_host.store_data["timeline.v1"]
  tap.ok(fail_payload ~= nil, "failed purge preserves stored aggregates through the outage")
  os.time = real_time_fail

  -- The pairing-preservation half of the failed-purge case, without the
  -- store outage masking the duration write: deletion fails but later
  -- event writes succeed, so the pre-purge pairing still records.
  local pair_now = 1700000000
  local real_time_pair = os.time
  os.time = function()
    return pair_now
  end
  local pair_host = new_host()
  load_plugin(pair_host)
  pair_host:publish("terminal.opened", { terminal_id = 9 })
  local pair_real_set = pair_host.bitty.store.set
  pair_host.bitty.store.set = function(key, value)
    if key == "timeline.v1" and value == nil then
      return false
    end
    return pair_real_set(key, value)
  end
  local pair_fail_result = pair_host:run("clear")
  tap.contains(pair_fail_result, "not modified", "failed deletion reports no modification")
  pair_host.bitty.store.set = pair_real_set
  pair_now = pair_now + 61
  pair_host:publish("terminal.closed", { terminal_id = 9 })
  local pair_payload = pair_host.store_data["timeline.v1"]
  tap.equal(pair_payload.durations.m1_10, 1, "failed purge preserves session pairing")
  os.time = real_time_pair

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
