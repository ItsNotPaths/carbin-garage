## Subsection-level surgical patches. Port of probe/reference/fm4carbin/patch.py.
## Used by builders + future stat / transcoding ops.

import std/[strutils, tables, endians]
import ../be
import ./model

proc patchSectionNameRescan*(sectionBytes: openArray[byte], newName: string): seq[byte] =
  ## Walks the section header to find the 8-bit-prefixed name, then rewrites it.
  var r = newBEReader(sectionBytes)
  let unk = r.u32()
  if unk != 2 and unk != 5:
    r.seek(-4, 1)
  r.seek(9 * 4, 1)
  r.seek(28, 1)
  let permCount = r.u32()
  r.seek(int(permCount) * 16, 1)
  r.seek(4, 1)
  let cnt2 = r.u32()
  r.seek(int(cnt2) * 2, 1)
  r.seek(12, 1)
  let lenPos = r.tell()
  let nameLen = int(r.u8())
  let nameStart = r.tell()
  r.seek(nameLen, 1)
  let nameEnd = r.tell()
  if nameEnd > sectionBytes.len: return @sectionBytes
  let nb = newName[0 .. min(254, newName.high)]
  result = newSeq[byte](lenPos + 1 + nb.len + (sectionBytes.len - nameEnd))
  for i in 0 ..< lenPos: result[i] = sectionBytes[i]
  result[lenPos] = byte(nb.len)
  for i, c in nb: result[lenPos + 1 + i] = byte(c)
  let tailStart = lenPos + 1 + nb.len
  for i in 0 ..< sectionBytes.len - nameEnd:
    result[tailStart + i] = sectionBytes[nameEnd + i]
  discard nameStart  # silence unused

proc patchSubsectionName*(ssBytes: openArray[byte], ss: SubSectionInfo,
                          newName: string): seq[byte] =
  let relLenPos = ss.nameLenPos - ss.start
  if relLenPos < 0 or relLenPos + 4 > ssBytes.len: return @ssBytes
  var r = newBEReader(ssBytes)
  r.seek(relLenPos)
  let oldLen = r.i32()
  if oldLen < 0 or oldLen > 100000: return @ssBytes
  let relNameStart = relLenPos + 4
  let relNameEnd = relNameStart + int(oldLen)
  if relNameEnd > ssBytes.len: return @ssBytes
  let nb = newName
  result = newSeq[byte](relLenPos + 4 + nb.len + (ssBytes.len - relNameEnd))
  for i in 0 ..< relLenPos: result[i] = ssBytes[i]
  let lenPacked = bePackI32(int32(nb.len))
  for i in 0 .. 3: result[relLenPos + i] = lenPacked[i]
  for i, c in nb: result[relLenPos + 4 + i] = byte(c)
  let tailStart = relLenPos + 4 + nb.len
  for i in 0 ..< ssBytes.len - relNameEnd:
    result[tailStart + i] = ssBytes[relNameEnd + i]

proc patchSubsectionLod*(ssBytes: openArray[byte], ss: SubSectionInfo,
                         newLod: int32): seq[byte] =
  let relLodPos = ss.lodPos - ss.start
  if relLodPos < 0 or relLodPos + 4 > ssBytes.len: return @ssBytes
  result = @ssBytes
  let packed = bePackI32(newLod)
  for i in 0 .. 3: result[relLodPos + i] = packed[i]

proc upconvertSubsectionIndices_2_to_4*(ssBytes: openArray[byte],
                                        ss: SubSectionInfo): tuple[bytes: seq[byte]; changed: bool] =
  if ss.idxSize != 2: return (@ssBytes, false)
  let relIdxSizePos = ss.idxSizePos - ss.start
  let relIdxDataStart = ss.idxDataStart - ss.start
  let relIdxDataEnd = ss.idxDataEnd - ss.start
  let relAfterIdx = ss.afterIdxPos - ss.start

  if not (0 <= relIdxSizePos + 4 and relIdxSizePos + 4 <= ssBytes.len): return (@ssBytes, false)
  if not (0 <= relIdxDataStart and relIdxDataStart <= relIdxDataEnd and relIdxDataEnd <= ssBytes.len):
    return (@ssBytes, false)

  let n = int(ss.idxCount)
  if relIdxDataEnd - relIdxDataStart != n * 2: return (@ssBytes, false)

  var rebuilt = newSeqOfCap[byte](ssBytes.len + n * 2)
  for i in 0 ..< relIdxSizePos: rebuilt.add(ssBytes[i])
  let sizePacked = bePackI32(4'i32)
  for b in sizePacked: rebuilt.add(b)
  for i in (relIdxSizePos + 4) ..< relIdxDataStart: rebuilt.add(ssBytes[i])
  for i in 0 ..< n:
    var v: uint16
    var be: array[2, byte] = [ssBytes[relIdxDataStart + i*2], ssBytes[relIdxDataStart + i*2 + 1]]
    bigEndian16(addr v, addr be[0])
    let upgraded: uint32 = if v == 0xFFFF'u16: 0xFFFFFFFF'u32 else: uint32(v)
    let p = bePackU32(upgraded)
    for b in p: rebuilt.add(b)
  for i in relAfterIdx ..< ssBytes.len: rebuilt.add(ssBytes[i])
  result = (rebuilt, true)

proc downconvertSubsectionIndices_4_to_2*(ssBytes: openArray[byte],
                                          ss: SubSectionInfo): tuple[bytes: seq[byte]; changed: bool] =
  if ss.idxSize != 4: return (@ssBytes, false)
  let relIdxSizePos = ss.idxSizePos - ss.start
  let relIdxDataStart = ss.idxDataStart - ss.start
  let relIdxDataEnd = ss.idxDataEnd - ss.start
  let relAfterIdx = ss.afterIdxPos - ss.start

  if not (0 <= relIdxSizePos + 4 and relIdxSizePos + 4 <= ssBytes.len): return (@ssBytes, false)
  if not (0 <= relIdxDataStart and relIdxDataStart <= relIdxDataEnd and relIdxDataEnd <= ssBytes.len):
    return (@ssBytes, false)

  let n = int(ss.idxCount)
  if relIdxDataEnd - relIdxDataStart != n * 4: return (@ssBytes, false)

  var rebuilt = newSeqOfCap[byte](ssBytes.len)
  for i in 0 ..< relIdxSizePos: rebuilt.add(ssBytes[i])
  let sizePacked = bePackI32(2'i32)
  for b in sizePacked: rebuilt.add(b)
  for i in (relIdxSizePos + 4) ..< relIdxDataStart: rebuilt.add(ssBytes[i])
  for i in 0 ..< n:
    var v: uint32
    var be: array[4, byte] = [ssBytes[relIdxDataStart + i*4], ssBytes[relIdxDataStart + i*4 + 1],
                              ssBytes[relIdxDataStart + i*4 + 2], ssBytes[relIdxDataStart + i*4 + 3]]
    bigEndian32(addr v, addr be[0])
    let downgraded: uint16 =
      if v == 0xFFFFFFFF'u32 or v == 0x00FFFFFF'u32 or v == 0x0000FFFF'u32:
        0xFFFF'u16
      elif v > 0xFFFE'u32:
        raise newException(ValueError, "Index " & $v & " exceeds uint16 range during 4→2 conversion")
      else:
        uint16(v)
    let p = bePackU16(downgraded)
    for b in p: rebuilt.add(b)
  for i in relAfterIdx ..< ssBytes.len: rebuilt.add(ssBytes[i])
  result = (rebuilt, true)

proc sanitize32bitRestartMarkers*(ssBytes: openArray[byte],
                                   ss: SubSectionInfo): tuple[bytes: seq[byte]; changedCount: int] =
  if ss.idxSize != 4: return (@ssBytes, 0)
  let relIdxDataStart = ss.idxDataStart - ss.start
  let relIdxDataEnd = ss.idxDataEnd - ss.start
  if not (0 <= relIdxDataStart and relIdxDataStart <= relIdxDataEnd and relIdxDataEnd <= ssBytes.len):
    return (@ssBytes, 0)

  let n = int(ss.idxCount)
  if relIdxDataEnd - relIdxDataStart != n * 4: return (@ssBytes, 0)

  var idx = newSeq[byte](n * 4)
  for i in 0 ..< n * 4: idx[i] = ssBytes[relIdxDataStart + i]
  var changed = 0
  for i in 0 ..< n:
    var v: uint32
    var be: array[4, byte] = [idx[i*4], idx[i*4+1], idx[i*4+2], idx[i*4+3]]
    bigEndian32(addr v, addr be[0])
    if v == 0x0000FFFF'u32:
      let p = bePackU32(0xFFFFFFFF'u32)
      for j in 0 .. 3: idx[i*4 + j] = p[j]
      inc changed
  if changed == 0: return (@ssBytes, 0)
  result = (newSeq[byte](ssBytes.len), changed)
  for i in 0 ..< relIdxDataStart: result.bytes[i] = ssBytes[i]
  for i in 0 ..< n * 4: result.bytes[relIdxDataStart + i] = idx[i]
  for i in relIdxDataEnd ..< ssBytes.len: result.bytes[i] = ssBytes[i]

proc parseRenameMap*(text: string): Table[string, string] =
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"): continue
    if not ('=' in line): continue
    let parts = line.split('=', 1)
    let a = parts[0].strip()
    let b = parts[1].strip()
    if a.len > 0: result[a] = b
