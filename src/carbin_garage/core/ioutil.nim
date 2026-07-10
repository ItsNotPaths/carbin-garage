## Whole-file byte I/O helpers shared across the CLI + orchestrators.
## `readFileBytes` is O(1) over the readFile string (same memory layout
## under ORC), replacing the per-byte copy loops that used to be
## re-implemented in half a dozen modules.

proc readFileBytes*(path: string): seq[byte] =
  cast[seq[byte]](readFile(path))

proc writeFileBytes*(path: string, data: openArray[byte]) =
  var f = open(path, fmWrite)
  defer: f.close()
  if data.len > 0: discard f.writeBytes(data, 0, data.len)
