## PKZip cdir walker + method-21 (Microsoft LZX) framing.
## Port of probe/lzxzip.py. Standard `zipfile`-equivalent libs reject method 21.
## Spec: docs/FORZA_LZX_FORMAT.md.

import std/[streams, endians]
import ./lzx

const
  EOCD_SIG* = [byte 0x50, 0x4B, 0x05, 0x06]   # "PK\x05\x06"
  CDIR_SIG* = [byte 0x50, 0x4B, 0x01, 0x02]   # "PK\x01\x02"
  LFH_SIG*  = [byte 0x50, 0x4B, 0x03, 0x04]   # "PK\x03\x04"
  METHOD_STORED* = 0
  METHOD_LZX*    = 21

type
  Entry* = object
    name*: string
    methodId*: int
    csize*: int
    usize*: int
    crc32*: uint32
    localHeaderOffset*: int
    cdirExtra*: seq[byte]
      ## Bytes of this entry's cdir-side `extra` field, captured verbatim
      ## from the source zip. Forza zips carry an 8-byte Xbox-side
      ## extension tag (header id 0x1123, len 4) per entry that the game's
      ## IO layer validates at load time. The mixed-method rewriter
      ## preserves these byte-for-byte when re-emitting the cdir.
    versionMadeBy*: uint16        ## cdir bytes 4..5 (donor uses 10 = PKZip 1.0)
    versionNeeded*: uint16        ## cdir bytes 6..7 (donor uses 10)
    flags*: uint16                ## cdir bytes 8..9 (donor: 0)
    modTime*: uint16              ## cdir bytes 12..13 (real DOS-time stamp)
    modDate*: uint16              ## cdir bytes 14..15
    internalAttrs*: uint16        ## cdir bytes 36..37
    externalAttrs*: uint32        ## cdir bytes 38..41

# ---- little-endian primitive readers (zip is LE) ----

proc leU16(buf: openArray[byte], off: int): uint16 =
  var be: array[2, byte] = [buf[off], buf[off + 1]]
  littleEndian16(addr result, addr be[0])

proc leU32(buf: openArray[byte], off: int): uint32 =
  var be: array[4, byte] = [buf[off], buf[off + 1], buf[off + 2], buf[off + 3]]
  littleEndian32(addr result, addr be[0])

proc bytesEq(a: openArray[byte], off: int, sig: array[4, byte]): bool =
  result = a[off] == sig[0] and a[off+1] == sig[1] and
           a[off+2] == sig[2] and a[off+3] == sig[3]

# ---- cdir walk ----

proc findEocd(buf: openArray[byte]): int =
  ## Scan from end for EOCD signature. No zip64 in Forza archives.
  const maxComment = 65535
  let endPos = buf.len
  let startPos = max(0, endPos - 22 - maxComment)
  var i = endPos - 4
  while i >= startPos:
    if bytesEq(buf, i, EOCD_SIG): return i
    dec i
  raise newException(IOError, "EOCD not found")

proc readZipBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc listEntries*(zipPath: string): seq[Entry] =
  let data = readZipBytes(zipPath)
  let eocd = findEocd(data)
  # EOCD layout (after 4-byte sig):
  #   u16 disk, u16 disk_cd, u16 here_cd, u16 total_cd,
  #   u32 cd_size, u32 cd_off, u16 comment_len
  let totalCd = int(leU16(data, eocd + 10))
  let cdOff   = int(leU32(data, eocd + 16))
  var p = cdOff
  result = newSeqOfCap[Entry](totalCd)
  for _ in 0 ..< totalCd:
    if not bytesEq(data, p, CDIR_SIG):
      raise newException(IOError, "bad cdir sig at " & $p)
    # Central dir layout (after 4-byte sig, all offsets relative to sig):
    #   u16 ver_made, u16 ver_need, u16 flags, u16 method,
    #   u16 mod_time, u16 mod_date, u32 crc,
    #   u32 csize, u32 usize, u16 fnl, u16 exl, u16 cml,
    #   u16 disk, u16 ia, u32 ea, u32 lho
    let verMadeBy = leU16(data, p + 4)
    let verNeeded = leU16(data, p + 6)
    let flags     = leU16(data, p + 8)
    let methodId = int(leU16(data, p + 10))
    let modTime  = leU16(data, p + 12)
    let modDate  = leU16(data, p + 14)
    let crc      = leU32(data, p + 16)
    let csize    = int(leU32(data, p + 20))
    let usize    = int(leU32(data, p + 24))
    let fnl      = int(leU16(data, p + 28))
    let exl      = int(leU16(data, p + 30))
    let cml      = int(leU16(data, p + 32))
    let intAttr  = leU16(data, p + 36)
    let extAttr  = leU32(data, p + 38)
    let lho      = int(leU32(data, p + 42))
    var name = newString(fnl)
    for j in 0 ..< fnl: name[j] = char(data[p + 46 + j])
    var cdirExtra = newSeq[byte](exl)
    for j in 0 ..< exl: cdirExtra[j] = data[p + 46 + fnl + j]
    result.add(Entry(
      name: name, methodId: methodId, csize: csize, usize: usize,
      crc32: crc, localHeaderOffset: lho, cdirExtra: cdirExtra,
      versionMadeBy: verMadeBy, versionNeeded: verNeeded, flags: flags,
      modTime: modTime, modDate: modDate,
      internalAttrs: intAttr, externalAttrs: extAttr))
    p += 46 + fnl + exl + cml

proc readCompressed*(zipPath: string, e: Entry): seq[byte] =
  ## Read the compressed payload for one entry. Skips the local file
  ## header (LFH) which holds repeated copies of name + extra fields.
  let f = newFileStream(zipPath, fmRead)
  if f == nil: raise newException(IOError, "open failed: " & zipPath)
  defer: f.close()
  f.setPosition(e.localHeaderOffset)
  var head: array[30, byte]
  doAssert f.readData(addr head[0], 30) == 30
  if not bytesEq(head, 0, LFH_SIG):
    raise newException(IOError, "bad LFH sig for " & e.name)
  let fnl = int(leU16(head, 26))
  let exl = int(leU16(head, 28))
  f.setPosition(e.localHeaderOffset + 30 + fnl + exl)
  result = newSeq[byte](e.csize)
  if e.csize > 0:
    doAssert f.readData(addr result[0], e.csize) == e.csize

# ---- LZX chunk framing ----

proc stripLzxChunks*(blob: openArray[byte]): seq[byte] =
  ## Forza method-21 framing: each chunk has either a 2-byte BE csize
  ## header (full 32K-output chunk) or a 5-byte header `0xFF [usize-BE-2] [csize-BE-2]`
  ## (final/partial chunk). LZX state persists across chunks, so we
  ## concatenate raw bitstreams and feed them as one stream.
  result = newSeqOfCap[byte](blob.len)
  var p = 0
  while p < blob.len:
    var csize: int
    var head: int
    if blob[p] == 0xFF:
      if p + 5 > blob.len: break
      csize = (int(blob[p + 3]) shl 8) or int(blob[p + 4])
      head = 5
    else:
      if p + 2 > blob.len: break
      csize = (int(blob[p]) shl 8) or int(blob[p + 1])
      head = 2
    if csize == 0 or p + head + csize > blob.len: break
    for i in 0 ..< csize:
      result.add(blob[p + head + i])
    p += head + csize

# ---- public extract ----

proc extract*(zipPath: string, e: Entry): seq[byte] =
  ## Return the decompressed bytes for one entry. Handles METHOD_STORED
  ## (verbatim) and METHOD_LZX (chunk-framed → libmspack lzxd).
  let raw = readCompressed(zipPath, e)
  if e.methodId == METHOD_STORED: return raw
  if e.methodId != METHOD_LZX:
    raise newException(IOError,
      "unsupported method " & $e.methodId & " for " & e.name)
  let stripped = stripLzxChunks(raw)
  result = inflate(stripped, e.usize)
