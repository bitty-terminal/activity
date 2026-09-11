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
end

return M
