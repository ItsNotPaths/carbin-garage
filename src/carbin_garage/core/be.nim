## Big-endian binary reader/writer. Port of probe/reference/fm4carbin/be.py.
## All carbin multi-byte fields are big-endian (Xbox 360 PowerPC).

import std/endians

type
  BEReader* = object
    data*: seq[byte]
    pos*: int

proc newBEReader*(data: openArray[byte]): BEReader =
  result.data = @data
  result.pos = 0

proc newBEReader*(data: seq[byte]): BEReader =
  result.data = data
  result.pos = 0

proc len*(r: BEReader): int = r.data.len

proc tell*(r: BEReader): int = r.pos

proc seek*(r: var BEReader, off: int, whence: int = 0) =
  case whence
  of 0: r.pos = off
  of 1: r.pos += off
  of 2: r.pos = r.data.len + off
  else: raise newException(ValueError, "bad whence")
  if r.pos < 0: r.pos = 0
  if r.pos > r.data.len: r.pos = r.data.len

proc read*(r: var BEReader, n: int): seq[byte] =
  if r.pos + n > r.data.len:
    raise newException(IOError, "read past EOF")
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n

proc u8*(r: var BEReader): uint8 =
  if r.pos + 1 > r.data.len:
    raise newException(IOError, "read past EOF")
  result = r.data[r.pos]
  r.pos += 1

proc u32*(r: var BEReader): uint32 =
  if r.pos + 4 > r.data.len:
    raise newException(IOError, "read past EOF")
  var be: array[4, byte]
  for i in 0 .. 3: be[i] = r.data[r.pos + i]
  bigEndian32(addr result, addr be[0])
  r.pos += 4

proc i32*(r: var BEReader): int32 =
  let v = r.u32()
  result = cast[int32](v)

proc u16*(r: var BEReader): uint16 =
  if r.pos + 2 > r.data.len:
    raise newException(IOError, "read past EOF")
  var be: array[2, byte]
  for i in 0 .. 1: be[i] = r.data[r.pos + i]
  bigEndian16(addr result, addr be[0])
  r.pos += 2

proc i16*(r: var BEReader): int16 =
  let v = r.u16()
  result = cast[int16](v)

proc f32*(r: var BEReader): float32 =
  let bits = r.u32()
  result = cast[float32](bits)

proc asciiLen8*(r: var BEReader): tuple[s: string; lenPos, endPos: int] =
  let lenPos = r.tell()
  let n = int(r.u8())
  let bytes = r.read(n)
  var s = newString(bytes.len)
  for i, b in bytes: s[i] = char(b)
  result = (s, lenPos, r.tell())

proc asciiLen32*(r: var BEReader): tuple[s: string; lenPos, endPos: int] =
  let lenPos = r.tell()
  let n = r.i32()
  if n < 0 or n > 10000:
    raise newException(ValueError, "bad string length")
  let bytes = r.read(int(n))
  var s = newString(bytes.len)
  for i, b in bytes: s[i] = char(b)
  result = (s, lenPos, r.tell())

# ---------- writers ----------

proc bePackU32*(x: uint32): array[4, byte] =
  var be: uint32 = x
  bigEndian32(addr result[0], addr be)

proc bePackI32*(x: int32): array[4, byte] =
  let u = cast[uint32](x)
  result = bePackU32(u)

proc bePackF32*(x: float32): array[4, byte] =
  let bits = cast[uint32](x)
  result = bePackU32(bits)

proc bePackU16*(x: uint16): array[2, byte] =
  var be: uint16 = x
  bigEndian16(addr result[0], addr be)

proc writeU32*(buf: var seq[byte], offset: int, x: uint32) =
  let packed = bePackU32(x)
  for i in 0 .. 3: buf[offset + i] = packed[i]

proc writeI32*(buf: var seq[byte], offset: int, x: int32) =
  writeU32(buf, offset, cast[uint32](x))

proc writeF32*(buf: var seq[byte], offset: int, x: float32) =
  writeU32(buf, offset, cast[uint32](x))
