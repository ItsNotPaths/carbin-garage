## AES-128 (FIPS 197) ECB + CBC encrypt and decrypt.
##
## Tiny pure-Nim implementation, no external deps. Used by the xex2
## unpack/repack flow:
##   - ECB to unwrap / re-wrap the per-image session key with the public
##     retail or devkit wrapping key.
##   - CBC (IV = 16 zero bytes per the xex2 spec) to decrypt / encrypt
##     the payload.
##
## Correct but not optimised. ~30-60s per 20 MB on a modern desktop —
## acceptable for a one-shot "patch game" operation.

const
  Sbox: array[256, uint8] = [
    0x63'u8, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16]

  InvSbox: array[256, uint8] = [
    0x52'u8, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
    0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
    0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
    0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
    0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
    0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
    0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
    0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
    0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
    0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
    0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d]

  Rcon: array[11, uint8] = [
    0'u8, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]

  BlockSize* = 16

# Public XEX2 wrapping keys (well-known, not secrets — see spec §2.3).
const
  Xex2RetailKey*: array[16, uint8] = [
    0x20'u8, 0xb1, 0x85, 0xa5, 0x9d, 0x28, 0xfd, 0xc3,
    0x40, 0x58, 0x3f, 0xbb, 0x08, 0x96, 0xbf, 0x91]
  Xex2DevkitKey*: array[16, uint8] = [
    0xa2'u8, 0x6c, 0x10, 0xf7, 0x1f, 0xd9, 0x35, 0xe9,
    0x8b, 0x99, 0x92, 0x2c, 0xe9, 0x32, 0x15, 0x72]

type
  RoundKeys = array[11, array[16, uint8]]

# ---- key expansion ----

proc expandKey128(key: openArray[uint8]): RoundKeys =
  if key.len != 16:
    raise newException(ValueError, "AES-128 key must be 16 bytes; got " & $key.len)
  # 44 4-byte words
  var w: array[44, array[4, uint8]]
  for i in 0 .. 3:
    for j in 0 .. 3: w[i][j] = key[i * 4 + j]
  for i in 4 .. 43:
    var temp = w[i - 1]
    if i mod 4 == 0:
      let (t0, t1, t2, t3) = (temp[0], temp[1], temp[2], temp[3])
      temp[0] = Sbox[t1] xor Rcon[i div 4]
      temp[1] = Sbox[t2]
      temp[2] = Sbox[t3]
      temp[3] = Sbox[t0]
    let prev = w[i - 4]
    for j in 0 .. 3:
      w[i][j] = prev[j] xor temp[j]
  for r in 0 .. 10:
    for c in 0 .. 3:
      for b in 0 .. 3:
        result[r][c * 4 + b] = w[r * 4 + c][b]

# ---- GF(2^8) helpers ----

proc xtime(b: uint8): uint8 {.inline.} =
  let hi = (b and 0x80'u8) != 0
  result = (b shl 1)
  if hi: result = result xor 0x1b'u8

proc gmul(a, b: uint8): uint8 =
  ## Multiply a*b in GF(2^8), reducing by 0x1b. Used in encrypt path
  ## (MixColumns) and key expansion. (For decrypt's InvMixColumns, the
  ## constants are 0x09/0x0b/0x0d/0x0e — we compute via repeated xtime
  ## inside the round, not via lookup.)
  var x = a
  var y = b
  var p: uint8 = 0
  for _ in 0 .. 7:
    if (y and 1'u8) != 0: p = p xor x
    let hi = (x and 0x80'u8) != 0
    x = (x shl 1)
    if hi: x = x xor 0x1b'u8
    y = y shr 1
  result = p

# ---- block ops ----

proc encryptBlock(pt: array[16, uint8], rks: RoundKeys): array[16, uint8] =
  var s = pt
  # Initial AddRoundKey
  for i in 0 .. 15: s[i] = s[i] xor rks[0][i]
  # 9 full rounds
  for r in 1 .. 9:
    # SubBytes
    for i in 0 .. 15: s[i] = Sbox[s[i]]
    # ShiftRows (row r shifted left by r positions; cells at row r col c → col c-r)
    let t = s
    s[0]  = t[0];  s[4]  = t[4];  s[8]  = t[8];  s[12] = t[12]
    s[1]  = t[5];  s[5]  = t[9];  s[9]  = t[13]; s[13] = t[1]
    s[2]  = t[10]; s[6]  = t[14]; s[10] = t[2];  s[14] = t[6]
    s[3]  = t[15]; s[7]  = t[3];  s[11] = t[7];  s[15] = t[11]
    # MixColumns
    let m = s
    for c in 0 .. 3:
      let a0 = m[c * 4 + 0]
      let a1 = m[c * 4 + 1]
      let a2 = m[c * 4 + 2]
      let a3 = m[c * 4 + 3]
      s[c * 4 + 0] = xtime(a0) xor (xtime(a1) xor a1) xor a2 xor a3
      s[c * 4 + 1] = a0 xor xtime(a1) xor (xtime(a2) xor a2) xor a3
      s[c * 4 + 2] = a0 xor a1 xor xtime(a2) xor (xtime(a3) xor a3)
      s[c * 4 + 3] = (xtime(a0) xor a0) xor a1 xor a2 xor xtime(a3)
    # AddRoundKey
    for i in 0 .. 15: s[i] = s[i] xor rks[r][i]
  # Final round: SubBytes + ShiftRows + AddRoundKey, no MixColumns
  for i in 0 .. 15: s[i] = Sbox[s[i]]
  let t = s
  s[0]  = t[0];  s[4]  = t[4];  s[8]  = t[8];  s[12] = t[12]
  s[1]  = t[5];  s[5]  = t[9];  s[9]  = t[13]; s[13] = t[1]
  s[2]  = t[10]; s[6]  = t[14]; s[10] = t[2];  s[14] = t[6]
  s[3]  = t[15]; s[7]  = t[3];  s[11] = t[7];  s[15] = t[11]
  for i in 0 .. 15: s[i] = s[i] xor rks[10][i]
  result = s

proc decryptBlock(ct: array[16, uint8], rks: RoundKeys): array[16, uint8] =
  var s = ct
  # Inverse final-round AddRoundKey
  for i in 0 .. 15: s[i] = s[i] xor rks[10][i]
  # 9 full inverse rounds
  for r in countdown(9, 1):
    # InvShiftRows: row r right-shifted by r
    let t = s
    s[0]  = t[0];  s[4]  = t[4];  s[8]  = t[8];  s[12] = t[12]
    s[1]  = t[13]; s[5]  = t[1];  s[9]  = t[5];  s[13] = t[9]
    s[2]  = t[10]; s[6]  = t[14]; s[10] = t[2];  s[14] = t[6]
    s[3]  = t[7];  s[7]  = t[11]; s[11] = t[15]; s[15] = t[3]
    # InvSubBytes
    for i in 0 .. 15: s[i] = InvSbox[s[i]]
    # AddRoundKey
    for i in 0 .. 15: s[i] = s[i] xor rks[r][i]
    # InvMixColumns: per column [0e 0b 0d 09; 09 0e 0b 0d; 0d 09 0e 0b; 0b 0d 09 0e]
    let m = s
    for c in 0 .. 3:
      let a0 = m[c * 4 + 0]
      let a1 = m[c * 4 + 1]
      let a2 = m[c * 4 + 2]
      let a3 = m[c * 4 + 3]
      s[c * 4 + 0] = gmul(0x0e, a0) xor gmul(0x0b, a1) xor gmul(0x0d, a2) xor gmul(0x09, a3)
      s[c * 4 + 1] = gmul(0x09, a0) xor gmul(0x0e, a1) xor gmul(0x0b, a2) xor gmul(0x0d, a3)
      s[c * 4 + 2] = gmul(0x0d, a0) xor gmul(0x09, a1) xor gmul(0x0e, a2) xor gmul(0x0b, a3)
      s[c * 4 + 3] = gmul(0x0b, a0) xor gmul(0x0d, a1) xor gmul(0x09, a2) xor gmul(0x0e, a3)
  # Initial-round AddRoundKey + InvShiftRows + InvSubBytes
  let t = s
  s[0]  = t[0];  s[4]  = t[4];  s[8]  = t[8];  s[12] = t[12]
  s[1]  = t[13]; s[5]  = t[1];  s[9]  = t[5];  s[13] = t[9]
  s[2]  = t[10]; s[6]  = t[14]; s[10] = t[2];  s[14] = t[6]
  s[3]  = t[7];  s[7]  = t[11]; s[11] = t[15]; s[15] = t[3]
  for i in 0 .. 15: s[i] = InvSbox[s[i]]
  for i in 0 .. 15: s[i] = s[i] xor rks[0][i]
  result = s

# ---- public API ----

proc aes128EcbDecrypt*(ciphertext: openArray[uint8],
                       key: openArray[uint8]): seq[uint8] =
  if ciphertext.len mod BlockSize != 0:
    raise newException(ValueError,
      "AES-ECB ciphertext length must be a multiple of " & $BlockSize)
  let rks = expandKey128(key)
  result = newSeq[uint8](ciphertext.len)
  for i in countup(0, ciphertext.len - 1, BlockSize):
    var blk: array[16, uint8]
    for j in 0 ..< BlockSize: blk[j] = ciphertext[i + j]
    let plain = decryptBlock(blk, rks)
    for j in 0 ..< BlockSize: result[i + j] = plain[j]

proc aes128EcbEncrypt*(plaintext: openArray[uint8],
                       key: openArray[uint8]): seq[uint8] =
  if plaintext.len mod BlockSize != 0:
    raise newException(ValueError,
      "AES-ECB plaintext length must be a multiple of " & $BlockSize)
  let rks = expandKey128(key)
  result = newSeq[uint8](plaintext.len)
  for i in countup(0, plaintext.len - 1, BlockSize):
    var blk: array[16, uint8]
    for j in 0 ..< BlockSize: blk[j] = plaintext[i + j]
    let ct = encryptBlock(blk, rks)
    for j in 0 ..< BlockSize: result[i + j] = ct[j]

proc aes128CbcDecrypt*(ciphertext: openArray[uint8],
                       key: openArray[uint8],
                       iv: openArray[uint8]): seq[uint8] =
  if iv.len != BlockSize:
    raise newException(ValueError, "AES IV must be 16 bytes; got " & $iv.len)
  if ciphertext.len mod BlockSize != 0:
    raise newException(ValueError,
      "AES-CBC ciphertext length must be a multiple of " & $BlockSize)
  let rks = expandKey128(key)
  result = newSeq[uint8](ciphertext.len)
  var prev: array[16, uint8]
  for j in 0 ..< BlockSize: prev[j] = iv[j]
  for i in countup(0, ciphertext.len - 1, BlockSize):
    var blk: array[16, uint8]
    for j in 0 ..< BlockSize: blk[j] = ciphertext[i + j]
    let plain = decryptBlock(blk, rks)
    for j in 0 ..< BlockSize:
      result[i + j] = plain[j] xor prev[j]
    prev = blk

proc aes128CbcEncrypt*(plaintext: openArray[uint8],
                       key: openArray[uint8],
                       iv: openArray[uint8]): seq[uint8] =
  ## Inverse of aes128CbcDecrypt — needed by xex2 repack to re-encrypt
  ## the patched payload before writing back to disk.
  if iv.len != BlockSize:
    raise newException(ValueError, "AES IV must be 16 bytes; got " & $iv.len)
  if plaintext.len mod BlockSize != 0:
    raise newException(ValueError,
      "AES-CBC plaintext length must be a multiple of " & $BlockSize)
  let rks = expandKey128(key)
  result = newSeq[uint8](plaintext.len)
  var prev: array[16, uint8]
  for j in 0 ..< BlockSize: prev[j] = iv[j]
  for i in countup(0, plaintext.len - 1, BlockSize):
    var blk: array[16, uint8]
    for j in 0 ..< BlockSize: blk[j] = plaintext[i + j] xor prev[j]
    let ct = encryptBlock(blk, rks)
    for j in 0 ..< BlockSize: result[i + j] = ct[j]
    prev = ct

# ---- self-test (run as: nim r aes.nim) ----
when isMainModule:
  import std/strutils
  # FIPS 197 Appendix A test vector: plaintext 00112233...ee ff, key 000102...0e 0f.
  let key = @[0x00'u8, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
              0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f]
  let pt  = @[0x00'u8, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
              0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
  let expectCt = "69c4e0d86a7b0430d8cdb78070b4c55a"
  let ct = aes128EcbEncrypt(pt, key)
  var hex = ""
  for b in ct: hex.add(b.toHex(2).toLowerAscii())
  doAssert hex == expectCt, "AES encrypt mismatch: got " & hex
  let pt2 = aes128EcbDecrypt(ct, key)
  for i in 0 .. 15: doAssert pt2[i] == pt[i]
  echo "  AES-128 ECB encrypt+decrypt: ok"
  # CBC roundtrip
  let iv = @[0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  let cbcCt = aes128CbcEncrypt(pt, key, iv)
  let cbcPt = aes128CbcDecrypt(cbcCt, key, iv)
  for i in 0 .. 15: doAssert cbcPt[i] == pt[i]
  echo "  AES-128 CBC encrypt+decrypt: ok"
