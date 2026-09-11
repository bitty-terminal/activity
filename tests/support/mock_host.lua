-- Minimal in-process `bitty` host stub for the activity behavior tests.
--
-- This is a test double, not a host implementation: it models only the
-- accepted Plugin API v1 subset the plugin uses (ADR 0009 / Plugin API v1
-- Lua Surface RFC), with fail-closed capability gates, bounded store values,
-- manifest-declared command/event validation, and one-shot virtual timers.
-- It performs no I/O, spawns nothing, and never touches the network or the
-- filesystem.

local MockHost = {}
MockHost.__index = MockHost

local MAX_STORE_DEPTH = 8
local MAX_STORE_NODES = 1024
local MAX_TIMERS = 32
local MAX_KEY_BYTES = 128

local function fail(class, code, message)
  error({ class = class, code = code, message = message }, 0)
end

local function is_finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validate_key(key)
  if type(key) ~= "string" then
    fail("validation", "E_STORE_KEY_INVALID", "store key must be a string")
  end
  local length = #key
  if length < 1 or length > MAX_KEY_BYTES then
    fail("validation", "E_STORE_KEY_INVALID", "store key must be 1..128 bytes")
  end
  local first = string.byte(key, 1)
  if not ((first >= 48 and first <= 57) or (first >= 97 and first <= 122)) then
    fail("validation", "E_STORE_KEY_INVALID", "store key must start with [a-z0-9]")
  end
  for index = 1, length do
    local byte = string.byte(key, index)
    local allowed = (byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 122) or byte == 45 or byte == 46 or byte == 95
    if not allowed then
      fail("validation", "E_STORE_KEY_INVALID", "store key contains an invalid character")
    end
  end
  if string.find(key, "..", 1, true) ~= nil then
    fail("validation", "E_STORE_KEY_INVALID", "store key must not contain empty dot segments")
  end
end

local function validate_value(value, depth, seen, budget)
  if depth > MAX_STORE_DEPTH then
    fail("validation", "E_STORE_VALUE_INVALID", "store value depth exceeds 8")
  end
  budget.nodes = budget.nodes + 1
  if budget.nodes > MAX_STORE_NODES then
    fail("validation", "E_STORE_VALUE_INVALID", "store value node count exceeds 1024")
  end
  local kind = type(value)
  if kind == "boolean" or kind == "string" then
    return
  end
  if kind == "number" then
    if not is_finite(value) then
      fail("validation", "E_STORE_VALUE_INVALID", "store value must be finite")
    end
    return
  end
  if kind ~= "table" then
    fail("validation", "E_STORE_VALUE_INVALID", "store value must be JSON-compatible")
  end
  if seen[value] then
    fail("validation", "E_STORE_VALUE_INVALID", "store value must not contain cycles")
  end
  seen[value] = true
  for key, child in pairs(value) do
    local key_kind = type(key)
    if key_kind ~= "string" and key_kind ~= "number" then
      fail("validation", "E_STORE_VALUE_INVALID", "store table keys must be strings or numbers")
    end
    validate_value(child, depth + 1, seen, budget)
  end
  seen[value] = nil
end

local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, child in pairs(value) do
    copy[key] = deepcopy(child)
  end
  return copy
end

function MockHost.new(options)
  options = options or {}
  local self = setmetatable({}, MockHost)
  self.plugin_id = options.plugin_id or "bitty-featured.activity"
  self.grants = {}
  for _, name in ipairs(options.grants or {}) do
    self.grants[name] = true
  end
  self.declared_commands = {}
  for _, name in ipairs(options.commands or {}) do
    self.declared_commands[name] = true
  end
  self.declared_events = {}
  for _, name in ipairs(options.events or {}) do
    self.declared_events[name] = true
  end
  self.store_data = options.store or {}
  self.settings = options.settings or {}
  self.settings_writes = {}
  self.commands = {}
  self.subscriptions = {}
  self.notifications = {}
  self.timers = {}
  self.clock = 0
  self.sequence = 1
  self.handle_counter = 0
  self.snapshot_calls = 0
  self.snapshot = options.snapshot
  self.bitty = self:build_bitty()
  return self
end

function MockHost:grant(name)
  self.grants[name] = true
end

function MockHost:next_handle()
  self.handle_counter = self.handle_counter + 1
  return self.handle_counter
end

function MockHost:build_bitty()
  local self = self
  return {
    api_version = "1.0.0",
    commands = {
      register = function(def)
        if type(def) ~= "table" or type(def.id) ~= "string" then
          fail("validation", "E_DEF_INVALID", "command definition is invalid")
        end
        local qualified = self.plugin_id .. ":" .. def.id
        if not self.declared_commands[qualified] then
          fail("validation", "E_COMMAND_UNDECLARED", "command is not reserved in the manifest: " .. qualified)
        end
        if self.commands[qualified] ~= nil then
          fail("validation", "E_COMMAND_DUPLICATE", "duplicate command: " .. qualified)
        end
        self.commands[qualified] = def
        return self:next_handle()
      end,
    },
    events = {
      subscribe = function(name, handler)
        if type(name) ~= "string" or type(handler) ~= "function" then
          fail("validation", "E_DEF_INVALID", "event subscription is invalid")
        end
        if not self.declared_events[name] then
          fail("validation", "E_EVENT_UNDECLARED", "event is not declared in the manifest: " .. name)
        end
        self.subscriptions[#self.subscriptions + 1] = { kind = name, handler = handler }
        return self:next_handle()
      end,
    },
    settings = {
      get = function(key)
        if type(key) ~= "string" then
          fail("validation", "E_SETTINGS_KEY_INVALID", "settings key must be a string")
        end
        return self.settings[key]
      end,
      set = function(key, value)
        self.settings_writes[#self.settings_writes + 1] = { key = key, value = value }
        self.settings[key] = value
        return true
      end,
    },
    store = {
      get = function(key)
        validate_key(key)
        local value = self.store_data[key]
        if value == nil then
          return nil
        end
        return deepcopy(value)
      end,
      set = function(key, value)
        validate_key(key)
        if value == nil then
          self.store_data[key] = nil
          return true
        end
        validate_value(value, 1, {}, { nodes = 0 })
        self.store_data[key] = deepcopy(value)
        return true
      end,
    },
    notify = {
      show = function(payload)
        if not self.grants["platform.notify"] then
          fail("runtime", "E_CAPABILITY_DENIED", "platform.notify is not granted")
        end
        if type(payload) ~= "table" or type(payload.title) ~= "string" then
          fail("validation", "E_DEF_INVALID", "notification payload is invalid")
        end
        self.notifications[#self.notifications + 1] = deepcopy(payload)
        return true
      end,
    },
    terminal = {
      snapshot = function(opts)
        self.snapshot_calls = self.snapshot_calls + 1
        if not self.grants["terminal.semantic-read"] then
          fail("runtime", "E_CAPABILITY_DENIED", "terminal.semantic-read is not granted")
        end
        if type(opts) ~= "table" or opts.scope ~= "semantic" then
          fail("validation", "E_SNAPSHOT_SCOPE_UNSUPPORTED", "only the semantic scope is supported")
        end
        if self.snapshot == false then
          fail("runtime", "E_CAPABILITY_DENIED", "no focused terminal")
        end
        if self.snapshot ~= nil then
          return deepcopy(self.snapshot)
        end
        return {
          version = 1,
          terminal_id = 1,
          runtime_id = 1,
          generation = 1,
          snapshot_generation = 1,
          width = 80,
          height = 24,
          rows = {},
          cursor = { row = 0, col = 0, visible = true },
          modes = { alternate_screen = false },
          title = "",
          zones = {
            { kind = "prompt", range = { start_line = 0, end_line = 0 } },
            { kind = "input", range = { start_line = 1, end_line = 1 } },
          },
        }
      end,
    },
    timers = {
      create = function(delay_ms, callback)
        if type(delay_ms) ~= "number" or type(callback) ~= "function" then
          fail("validation", "E_DEF_INVALID", "timer definition is invalid")
        end
        local live = 0
        for _ in pairs(self.timers) do
          live = live + 1
        end
        if live >= MAX_TIMERS then
          fail("budget", "E_BUDGET_TIMER", "timer cap exceeded")
        end
        local handle = self:next_handle()
        self.timers[handle] = { due = self.clock + delay_ms, callback = callback }
        return handle
      end,
      cancel = function(handle)
        if self.timers[handle] == nil then
          return false
        end
        self.timers[handle] = nil
        return true
      end,
    },
  }
end

function MockHost:pending_timers()
  local count = 0
  for _ in pairs(self.timers) do
    count = count + 1
  end
  return count
end

function MockHost:publish(kind, payload)
  local delivered = 0
  for _, subscription in ipairs(self.subscriptions) do
    if subscription.kind == kind then
      delivered = delivered + 1
      local event = {
        kind = kind,
        sequence = self.sequence,
        payload = deepcopy(payload or {}),
      }
      self.sequence = self.sequence + 1
      subscription.handler(event)
    end
  end
  return delivered
end

function MockHost:advance(ms)
  self.clock = self.clock + math.floor(ms)
  local due = {}
  for handle, timer in pairs(self.timers) do
    if timer.due <= self.clock then
      due[#due + 1] = { handle = handle, due = timer.due, callback = timer.callback }
    end
  end
  table.sort(due, function(left, right)
    if left.due ~= right.due then
      return left.due < right.due
    end
    return left.handle < right.handle
  end)
  for _, timer in ipairs(due) do
    self.timers[timer.handle] = nil
    timer.callback()
  end
end

function MockHost:suspend()
  self:publish("plugin.suspended", {})
end

function MockHost:dispose()
  self:publish("plugin.disposed", {})
end

function MockHost:run(command_id, args)
  local qualified = self.plugin_id .. ":" .. command_id
  local def = self.commands[qualified]
  if def == nil then
    fail("validation", "E_COMMAND_UNDECLARED", "command is not registered: " .. qualified)
  end
  return def.run(args or {})
end

return MockHost
