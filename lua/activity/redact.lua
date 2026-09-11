-- Privacy-preserving cwd labelling for the activity plugin (bitty-featured.activity).
--
-- Full working directories are never persisted. `redact` reduces one cwd
-- value to a bounded, single-component label (the final path segment), so the
-- activity store can aggregate counts without retaining a path that can be
-- reconstructed. The transform is deterministic and uses only byte scans on
-- the host-provided string; no unbounded pattern matching runs.

local M = {}

-- Maximum byte length of a redacted label, including a truncation suffix.
M.MAX_LABEL_BYTES = 48

local SEPARATOR_SLASH = 47
local SEPARATOR_BACKSLASH = 92
local COLON = 58
local CONTROL_MAX = 31
local DELETE = 127

local function final_segment(value)
  local last = #value
  while last > 1 do
    local byte = string.byte(value, last)
    if byte == SEPARATOR_SLASH or byte == SEPARATOR_BACKSLASH then
      last = last - 1
    else
      break
    end
  end
  if last == 0 then
    return ""
  end
  local start = 1
  for index = last, 1, -1 do
    local byte = string.byte(value, index)
    if byte == SEPARATOR_SLASH or byte == SEPARATOR_BACKSLASH then
      start = index + 1
      break
    end
  end
  return string.sub(value, start, last)
end

local function sanitize(segment)
  local bytes = {}
  for index = 1, #segment do
    local byte = string.byte(segment, index)
    if byte <= CONTROL_MAX or byte == DELETE then
      bytes[#bytes + 1] = "?"
    else
      bytes[#bytes + 1] = string.char(byte)
    end
  end
  local clean = table.concat(bytes)
  if #clean > M.MAX_LABEL_BYTES then
    clean = string.sub(clean, 1, M.MAX_LABEL_BYTES - 3) .. "..."
  end
  return clean
end

--- Reduce one cwd value to a bounded, non-reconstructable label.
-- @param value cwd field from an observation event (untrusted).
-- @return string bounded label; never nil.
function M.redact(value)
  if type(value) ~= "string" then
    return "<unknown>"
  end
  local segment = final_segment(value)
  if segment == "" then
    return "<root>"
  end
  if segment == "~" then
    return "<home>"
  end
  if segment == "." or segment == ".." then
    return "<relative>"
  end
  if #segment == 2 and string.byte(segment, 2) == COLON then
    return "<drive>"
  end
  return sanitize(segment)
end

return M
