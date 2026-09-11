-- Deliberately uses surface excluded from Plugin API v1. LuaLS must reject
-- every statement below; this file is never loaded by the host.

local alias_namespace = bitty.api
local legacy = bitty.on_event
local raw_scope = bitty.terminal.snapshot({ scope = "raw" })
local singular = bitty.task.spawn

print(alias_namespace, legacy, raw_scope, singular)
