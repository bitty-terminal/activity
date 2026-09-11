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
-- by `platform.notify`. No other authority is granted or assumed. Command
-- arguments and terminal contents are never persisted; the v1 timeline
-- aggregates counts, durations, and cwd only (PX-1199).

local M = {}

-- Commands are qualified by plugin id; duplicate qualified names are rejected
-- at graph construction time instead of shadowing another plugin.
bitty.commands.register({
  id = "summary",
  title = "Activity: show summary",
  description = "Show a privacy-safe summary of the visible semantic snapshot.",
  args_schema = { type = "object", properties = {} },
  result_schema = { type = "string" },
  run = function(_args)
    local snapshot = bitty.terminal.snapshot({ scope = "semantic" })
    local zones = 0
    if snapshot.zones then
      zones = #snapshot.zones
    end
    local summary = string.format(
      "terminal %d: %d semantic zone(s) visible",
      snapshot.terminal_id,
      zones
    )
    bitty.notify.show({
      title = "Bitty Activity",
      body = summary,
      urgency = "normal",
    })
    return summary
  end,
})

return M
