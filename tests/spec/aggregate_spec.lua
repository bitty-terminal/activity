-- Unit tests for the bounded aggregation state and its rendering.

local aggregate = require("activity.aggregate")

local M = {}

local function new_store()
  local data = {}
  return {
    data = data,
    get = function(key)
      return data[key]
    end,
    set = function(key, value)
      data[key] = value
      return true
    end,
  }
end

local function serialize(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local parts = {}
  for key, child in pairs(value) do
    parts[#parts + 1] = tostring(key) .. "=" .. serialize(child)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.run(context)
  local tap = context.tap
  print("# aggregate")

  tap.equal(aggregate.classify_exit(0), "ok", "exit 0 is ok")
  tap.equal(aggregate.classify_exit(1), "failed", "exit 1 is failed")
  tap.equal(aggregate.classify_exit(127), "failed", "exit 127 is failed")
  tap.equal(aggregate.classify_exit(128), "signaled", "exit 128 is signaled")
  tap.equal(aggregate.classify_exit(-9), "signaled", "negative exit is signaled")
  tap.equal(aggregate.classify_exit("nope"), "unknown", "non-number exit is unknown")
  tap.equal(aggregate.classify_exit(0 / 0), "unknown", "NaN exit is unknown")

  tap.equal(aggregate.duration_bucket(0), "lt1m", "duration 0")
  tap.equal(aggregate.duration_bucket(59), "lt1m", "duration 59s")
  tap.equal(aggregate.duration_bucket(60), "m1_10", "duration 60s")
  tap.equal(aggregate.duration_bucket(599), "m1_10", "duration 599s")
  tap.equal(aggregate.duration_bucket(3600), "gt60", "duration 1h")
  tap.equal(aggregate.duration_bucket(-1), nil, "negative duration is rejected")

  -- R22: aggregate handlers fail closed on malformed values and never mutate.
  local guarded = aggregate.new_state(1000, 7)
  aggregate.on_terminal_opened(guarded, "1", 1000)
  aggregate.on_terminal_opened(guarded, 0 / 0, 1000)
  aggregate.on_terminal_opened(guarded, nil, 1000)
  aggregate.on_terminal_closed(guarded, {}, 1000)
  aggregate.on_terminal_closed(guarded, false, 1000)
  aggregate.on_cwd_changed(guarded, 42, 1000)
  aggregate.on_cwd_changed(guarded, nil, 1000)
  aggregate.on_cwd_changed(guarded, {}, 1000)
  aggregate.on_process_exited(guarded, "0", 1000)
  aggregate.on_process_exited(guarded, 0 / 0, 1000)
  aggregate.on_process_exited(guarded, nil, 1000)
  tap.equal(guarded.counters.terminals_opened, 0, "malformed opens do not count")
  tap.equal(guarded.counters.terminals_closed, 0, "malformed closes do not count")
  tap.equal(guarded.counters.cwd_events, 0, "malformed cwd events do not count")
  tap.equal(guarded.counters.exit_events, 0, "malformed exit events do not count")
  tap.equal(guarded.counters.exits_unknown, 0, "malformed exits never fall into the unknown bucket")
  tap.equal(next(guarded.cwd.entries), nil, "malformed cwd events create no bucket")

  -- R23: an explicit retention setting overrides the stored value; the stored
  -- value is the fallback only when no setting is supplied.
  local precedence = aggregate.normalize({
    version = aggregate.FORMAT_VERSION,
    retention_days = 30,
    cwd = { entries = {}, unlisted = 0 },
  }, 10, 2)
  tap.equal(precedence.retention_days, 2, "explicit retention overrides stored retention")
  local fallback = aggregate.normalize({
    version = aggregate.FORMAT_VERSION,
    retention_days = 30,
    cwd = { entries = {}, unlisted = 0 },
  }, 10, nil)
  tap.equal(fallback.retention_days, 30, "stored retention is the fallback when no setting is supplied")

  -- R23: prune reports whether it changed anything so callers can skip a no-op
  -- dirty mark.
  local no_change = aggregate.new_state(1000, 7)
  local _, changed = aggregate.prune(no_change, 1000)
  tap.equal(changed, false, "prune reports no change on an empty window")
  aggregate.on_cwd_changed(no_change, "/p/old", 1000)
  local _, changed_after = aggregate.prune(no_change, 1000 + 8 * 86400)
  tap.equal(changed_after, true, "prune reports a change when a bucket expires")

  local bounded = aggregate.new_state(1000, 7)
  for index = 1, 40 do
    aggregate.on_cwd_changed(bounded, string.format("/p/d%02d", index), 1000 + index)
  end
  local tracked = 0
  for _ in pairs(bounded.cwd.entries) do
    tracked = tracked + 1
  end
  tap.equal(tracked, aggregate.MAX_CWD_ENTRIES, "cwd entries are capped")
  tap.equal(bounded.cwd.unlisted, 40 - aggregate.MAX_CWD_ENTRIES, "overflow folds into unlisted")

  local pruned = aggregate.new_state(1000, 7)
  aggregate.on_cwd_changed(pruned, "/p/old", 1000)
  aggregate.on_cwd_changed(pruned, "/p/new", 1000 + 8 * 86400)
  aggregate.prune(pruned, 1000 + 8 * 86400)
  tap.equal(pruned.cwd.entries.old, nil, "expired cwd bucket is dropped")
  tap.equal(pruned.cwd.entries.new.count, 1, "recent cwd bucket is kept")
  tap.equal(pruned.cwd.unlisted, 1, "pruned count folds into unlisted")

  local corrupt = aggregate.normalize("not a table", 10, 7)
  tap.equal(corrupt.version, aggregate.FORMAT_VERSION, "corrupt value resets format")
  tap.equal(corrupt.counters.cwd_events, 0, "corrupt value resets counters")

  local collision = aggregate.normalize({
    version = aggregate.FORMAT_VERSION,
    cwd = {
      entries = {
        ["é"] = { count = 2, last_seen = 5 },
        ["/x/é"] = { count = 3, last_seen = 7 },
      },
    },
  }, 10, 7)
  tap.equal(collision.cwd.entries["é"].count, 5, "redaction collisions merge counts")
  tap.equal(collision.cwd.entries["é"].last_seen, 7, "redaction collisions keep the latest seen")

  local wide = aggregate.new_state(1, 7)
  for index = 1, 5 do
    aggregate.on_cwd_changed(
      wide,
      string.format("/p/%s%d", string.rep("é", 24), index),
      100
    )
  end
  local wide_summary = aggregate.render(wide, { now = 100 })
  tap.ok(utf8.len(wide_summary) ~= nil, "summary with multibyte labels is valid UTF-8")
  tap.le(#wide_summary, aggregate.MAX_SUMMARY_BYTES, "summary stays bounded with multibyte labels")

  local store = new_store()
  store.data[aggregate.STORE_KEY] = { version = aggregate.FORMAT_VERSION + 1 }
  local newer = aggregate.load(store, 10, 7)
  tap.equal(newer.incompatible, true, "newer stored format is marked incompatible")
  local saved, code = aggregate.save(store, newer)
  tap.equal(saved, false, "incompatible state refuses to save")
  tap.equal(code, "E_STORE_VERSION", "incompatible save returns the stable code")
  tap.equal(store.data[aggregate.STORE_KEY].version, aggregate.FORMAT_VERSION + 1, "newer data is untouched")

  local roundtrip = new_store()
  local state = aggregate.new_state(500, 7)
  aggregate.on_cwd_changed(state, "/home/dev/project", 500)
  aggregate.on_process_exited(state, 0, 500)
  aggregate.on_session_duration(state, 30, 500)
  tap.ok(aggregate.save(roundtrip, state), "save succeeds")

  local raw = serialize(roundtrip.data[aggregate.STORE_KEY])
  tap.not_contains(raw, "/home/dev", "stored payload never contains the raw path")
  tap.contains(raw, "project", "stored payload keeps only the redacted basename")

  local loaded = aggregate.load(roundtrip, 600, 7)
  tap.equal(loaded.counters.cwd_events, 1, "cwd count survives a roundtrip")
  tap.equal(loaded.counters.exits_ok, 1, "exit class survives a roundtrip")
  tap.equal(loaded.durations.lt1m, 1, "duration bucket survives a roundtrip")
  tap.equal(loaded.cwd.entries.project.count, 1, "redacted label survives a roundtrip")
  loaded.counters.cwd_events = 99
  tap.equal(roundtrip.data[aggregate.STORE_KEY].counters.cwd_events, 1, "load returns a detached copy")

  aggregate.on_cwd_changed(state, "/home/dev/src", 700)
  local summary, notify_body = aggregate.render(state, { now = 700, zones = 2, args_opt_in = false })
  tap.contains(summary, "Bitty Activity", "summary names the plugin")
  tap.contains(summary, "focused terminal: 2", "summary includes the semantic zone count")
  tap.contains(summary, "never stored", "summary states the privacy contract")
  tap.contains(summary, "arguments: never stored (default)", "summary states the argument default")
  tap.le(#summary, aggregate.MAX_SUMMARY_BYTES, "summary is bounded")
  tap.le(#notify_body, aggregate.MAX_NOTIFY_BODY_BYTES, "notification body is bounded")

  local incompatible_summary =
    aggregate.render({ incompatible = true }, { now = 1 })
  tap.contains(incompatible_summary, "newer plugin version", "incompatible summary explains the state")

  tap.ok(aggregate.clear(roundtrip), "clear succeeds")
  tap.equal(roundtrip.data[aggregate.STORE_KEY], nil, "clear deletes the stored value")
end

return M
