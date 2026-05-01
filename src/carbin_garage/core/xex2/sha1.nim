## SHA-1 (FIPS 180-4 §6.1.2) — pure Nim, no deps. Used by xex2 repack
## to recompute the SecurityInfo `header_hash` after we zero the
## rsa_signature field, so the loader's header integrity check passes.
##
## Single-shot API only. Inputs are typically small (header region of a
## xex is a few KB). Speed is not a concern here.

type
  Sha1Digest* = array[20, uint8]

proc rotl(x: uint32, n: int): uint32 {.inline.} =
  (x shl n) or (x shr (32 - n))

proc sha1*(data: openArray[uint8]): Sha1Digest =
  var h0 = 0x67452301'u32
  var h1 = 0xEFCDAB89'u32
  var h2 = 0x98BADCFE'u32
  var h3 = 0x10325476'u32
  var h4 = 0xC3D2E1F0'u32

  let bitLen = uint64(data.len) * 8

  # Padded message: data || 0x80 || 0x00 ... || 8-byte BE length, padded
  # to a multiple of 64 bytes.
  let needed = data.len + 1 + 8                       # data + 0x80 + length
  let totalLen = ((needed + 63) div 64) * 64           # round up to 64
  var msg = newSeq[uint8](totalLen)
  for i in 0 ..< data.len: msg[i] = data[i]
  msg[data.len] = 0x80
  # 8-byte big-endian bit-length at the very end
  for i in 0 ..< 8:
    msg[totalLen - 1 - i] = uint8((bitLen shr (i * 8)) and 0xff)

  var w: array[80, uint32]
  for chunkStart in countup(0, totalLen - 1, 64):
    for i in 0 ..< 16:
      let p = chunkStart + i * 4
      w[i] = (uint32(msg[p]) shl 24) or
             (uint32(msg[p+1]) shl 16) or
             (uint32(msg[p+2]) shl 8) or
              uint32(msg[p+3])
    for i in 16 ..< 80:
      w[i] = rotl(w[i-3] xor w[i-8] xor w[i-14] xor w[i-16], 1)
    var a = h0; var b = h1; var c = h2; var d = h3; var e = h4
    for i in 0 ..< 80:
      var f: uint32
      var k: uint32
      if i < 20:
        f = (b and c) or ((not b) and d); k = 0x5A827999'u32
      elif i < 40:
        f = b xor c xor d; k = 0x6ED9EBA1'u32
      elif i < 60:
        f = (b and c) or (b and d) or (c and d); k = 0x8F1BBCDC'u32
      else:
        f = b xor c xor d; k = 0xCA62C1D6'u32
      let tmp = rotl(a, 5) + f + e + k + w[i]
      e = d; d = c; c = rotl(b, 30); b = a; a = tmp
    h0 = h0 + a; h1 = h1 + b; h2 = h2 + c; h3 = h3 + d; h4 = h4 + e

  proc storeBE(dst: var Sha1Digest, off: int, v: uint32) =
    dst[off]   = uint8((v shr 24) and 0xff)
    dst[off+1] = uint8((v shr 16) and 0xff)
    dst[off+2] = uint8((v shr 8)  and 0xff)
    dst[off+3] = uint8( v         and 0xff)
  storeBE(result, 0, h0)
  storeBE(result, 4, h1)
  storeBE(result, 8, h2)
  storeBE(result, 12, h3)
  storeBE(result, 16, h4)

when isMainModule:
  # FIPS 180-4 §A.1 vectors
  proc tohex(d: Sha1Digest): string =
    const hex = "0123456789abcdef"
    result = newStringOfCap(40)
    for b in d:
      result.add(hex[int(b shr 4)])
      result.add(hex[int(b and 0xf)])

  let v1 = sha1(@[uint8('a'), uint8('b'), uint8('c')])
  doAssert tohex(v1) == "a9993e364706816aba3e25717850c26c9cd0d89d", tohex(v1)

  let v2 = sha1(cast[seq[uint8]]("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
  doAssert tohex(v2) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1", tohex(v2)

  echo "  SHA-1: ok"
