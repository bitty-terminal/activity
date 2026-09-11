-- Privacy-preserving cwd labelling for the activity plugin (bitty-featured.activity).
--
-- Full working directories are never persisted. `redact` reduces one cwd
-- value to a bounded, single-component label (the final path segment), so the
-- activity store can aggregate counts without retaining a path that can be
-- reconstructed. Labels are always valid UTF-8 and at most `MAX_LABEL_BYTES`
-- bytes: invalid input sequences are masked and truncation happens only on a
-- character boundary, so a stored value can never be rejected for encoding
-- reasons. The transform is deterministic and uses only byte scans on the
-- host-provided string; no unbounded pattern matching runs.

local M = {}

-- Maximum byte length of a redacted label, including a truncation suffix.
M.MAX_LABEL_BYTES = 48

local SEPARATOR_SLASH = 47
local SEPARATOR_BACKSLASH = 92
local COLON = 58
local CONTROL_MAX = 31
local DELETE = 127
local TRUNCATION_SUFFIX = "..."

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

--- Truncate to `limit` bytes on a UTF-8 character boundary.
-- The input must be valid UTF-8 (every label this module emits is). The
-- result is valid UTF-8 and at most `limit` bytes.
function M.truncate_utf8(value, limit)
  if #value <= limit then
    return value
  end
  local cut = limit
  while cut > 0 do
    local next_byte = string.byte(value, cut + 1)
    if next_byte < 128 or next_byte >= 192 then
      break
    end
    cut = cut - 1
  end
  return string.sub(value, 1, cut)
end

local function sequence_width(lead)
  if lead >= 194 and lead <= 223 then
    return 2
  end
  if lead >= 224 and lead <= 239 then
    return 3
  end
  if lead >= 240 and lead <= 244 then
    return 4
  end
  return 0
end

-- Build a label that is valid UTF-8 by construction and never longer than
-- `MAX_LABEL_BYTES`. Control bytes and invalid UTF-8 sequences become "?".
local function sanitize(segment)
  local parts = {}
  local total = 0
  local length = #segment
  local index = 1
  while index <= length and total < M.MAX_LABEL_BYTES do
    local byte = string.byte(segment, index)
    if byte < 128 then
      if byte <= CONTROL_MAX or byte == DELETE then
        parts[#parts + 1] = "?"
      else
        parts[#parts + 1] = string.char(byte)
      end
      total = total + 1
      index = index + 1
    else
      local width = sequence_width(byte)
      local sequence = width > 0 and string.sub(segment, index, index + width - 1) or nil
      if sequence ~= nil and #sequence == width and utf8.len(sequence) == 1 then
        parts[#parts + 1] = sequence
        total = total + width
        index = index + width
      else
        parts[#parts + 1] = "?"
        total = total + 1
        index = index + 1
      end
    end
  end
  local clean = table.concat(parts)
  if index <= length or #clean > M.MAX_LABEL_BYTES then
    clean = M.truncate_utf8(clean, M.MAX_LABEL_BYTES - #TRUNCATION_SUFFIX) .. TRUNCATION_SUFFIX
  end
  return clean
end

--- Reduce one cwd value to a bounded, non-reconstructable label.
-- @param value cwd field from an observation event (untrusted).
-- @return string bounded, valid UTF-8 label; never nil.
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
