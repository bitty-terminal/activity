-- Unit tests for the privacy-preserving cwd label transform.

local redact = require("activity.redact")

local M = {}

function M.run(context)
  local tap = context.tap
  print("# redact")

  tap.equal(redact.redact("/home/dev/project/src"), "src", "posix basename")
  tap.equal(redact.redact("/home/dev/project/src/"), "src", "trailing separator")
  tap.equal(redact.redact("/home/dev/project/src///"), "src", "repeated trailing separators")
  tap.equal(redact.redact([[C:\Users\dev\app]]), "app", "windows basename")
  tap.equal(redact.redact("C:\\"), "<drive>", "windows drive root")
  tap.equal(redact.redact("/"), "<root>", "posix root")
  tap.equal(redact.redact(""), "<root>", "empty path")
  tap.equal(redact.redact("~"), "<home>", "bare home")
  tap.equal(redact.redact("."), "<relative>", "dot segment")
  tap.equal(redact.redact(".."), "<relative>", "dotdot segment")
  tap.equal(redact.redact("relative/name"), "name", "relative basename")
  tap.equal(redact.redact(nil), "<unknown>", "nil is unknown")
  tap.equal(redact.redact(42), "<unknown>", "non-string is unknown")

  local control = redact.redact("bad\tname\nhere")
  tap.equal(control, "bad?name?here", "control bytes are masked")
  tap.not_contains(control, "\t", "control output has no tab")
  tap.not_contains(control, "\n", "control output has no newline")

  local long = string.rep("a", 200)
  local bounded = redact.redact(long)
  tap.equal(#bounded, redact.MAX_LABEL_BYTES, "long labels are truncated to the limit")
  tap.contains(bounded, "...", "long labels carry a truncation suffix")

  local multibyte = redact.redact("/home/dev/" .. string.rep("é", 60))
  tap.le(#multibyte, redact.MAX_LABEL_BYTES, "multibyte labels stay within the byte bound")
  tap.ok(utf8.len(multibyte) ~= nil, "2-byte labels stay valid UTF-8 after truncation")

  local three_byte = redact.redact("/home/dev/" .. string.rep("€", 40))
  tap.le(#three_byte, redact.MAX_LABEL_BYTES, "3-byte labels stay within the byte bound")
  tap.ok(utf8.len(three_byte) ~= nil, "3-byte labels stay valid UTF-8 after truncation")

  local four_byte = redact.redact("/home/dev/" .. string.rep("😀", 30))
  tap.le(#four_byte, redact.MAX_LABEL_BYTES, "4-byte labels stay within the byte bound")
  tap.ok(utf8.len(four_byte) ~= nil, "4-byte labels stay valid UTF-8 after truncation")

  local exact_boundary = string.rep("é", 24)
  tap.equal(
    redact.redact("/home/dev/" .. exact_boundary),
    exact_boundary,
    "exact-boundary label is unchanged"
  )
  local over_boundary = redact.redact("/home/dev/" .. exact_boundary .. "a")
  tap.le(#over_boundary, redact.MAX_LABEL_BYTES, "over-boundary label stays bounded")
  tap.ok(utf8.len(over_boundary) ~= nil, "over-boundary label stays valid UTF-8")
  tap.contains(over_boundary, "...", "over-boundary label is marked truncated")

  local truncated_sequence = redact.redact("/home/dev/" .. string.char(0xC3))
  tap.ok(utf8.len(truncated_sequence) ~= nil, "truncated input sequence is masked to valid UTF-8")
  tap.equal(truncated_sequence, "?", "truncated input sequence becomes a mask")
  tap.equal(
    redact.redact("/home/dev/" .. string.char(0xFF) .. "x"),
    "?x",
    "invalid lead byte becomes a mask"
  )

  tap.equal(redact.truncate_utf8("abcdef", 10), "abcdef", "truncate under limit is unchanged")
  tap.equal(redact.truncate_utf8("abcdef", 6), "abcdef", "truncate at limit is unchanged")
  tap.equal(redact.truncate_utf8("abcdef", 5), "abcde", "truncate ascii")
  tap.equal(
    utf8.len(redact.truncate_utf8(string.rep("é", 30), 45)),
    22,
    "truncate backs off a split 2-byte character"
  )
  tap.equal(
    utf8.len(redact.truncate_utf8(string.rep("€", 20), 47)),
    15,
    "truncate backs off a split 3-byte character"
  )
  tap.equal(
    utf8.len(redact.truncate_utf8(string.rep("😀", 13), 48)),
    12,
    "truncate keeps a 4-byte boundary"
  )
end

return M
