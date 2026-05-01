## XEX2 file format structures (header, optional headers, SecurityInfo,
## FileFormatInfo). Big-endian throughout.
##
## Port of xex2-unpacker/src/xex2/{header,security,fileformat}.py.

import std/strutils
import ../be

const
  Xex2Magic* = "XEX2"
  HeaderFixedSize* = 0x18      # 24 bytes
  SecurityInfoFixedSize* = 0x180

  EncryptionNone*       = 0'u16
  EncryptionAes128Cbc*  = 1'u16

  CompressionNone*   = 0'u16
  CompressionBasic*  = 1'u16
  CompressionNormal* = 2'u16   # LZX (not used by FH1)
  CompressionDelta*  = 3'u16   # XEXP patch (not used by FH1)

  FileFormatInfoKeyHigh24*    = 0x000003'u32
  EntryPointKeyHigh24*        = 0x000101'u32
  ImageBaseAddressKeyHigh24*  = 0x000102'u32

type
  Xex2FormatError* = object of CatchableError

  OptHeaderKind* = enum ohkInline, ohkBlock
  OptHeaderEntry* = object
    key*: uint32
    case kind*: OptHeaderKind
    of ohkInline:
      inlineValue*: uint32
    of ohkBlock:
      blockBytes*: seq[uint8]
      blockOffset*: uint32

  Xex2FileHeader* = object
    magic*: string                  # "XEX2"
    moduleFlags*: uint32
    peDataOffset*: uint32
    reserved*: uint32
    securityInfoOffset*: uint32
    optionalHeaderCount*: uint32

  SecurityInfo* = object
    headerSize*: uint32
    imageSize*: uint32
    rsaSignature*: seq[uint8]       # 256 bytes
    imageInfoSize*: uint32
    imageFlags*: uint32
    loadAddress*: uint32
    imageHash*: seq[uint8]          # 20 bytes (SHA-1)
    importTableCount*: uint32
    importTableHash*: seq[uint8]    # 20 bytes
    mediaId*: seq[uint8]            # 16 bytes
    encryptedImageKey*: seq[uint8]  # 16 bytes (AES key wrapped)
    exportTable*: uint32
    headerHash*: seq[uint8]         # 20 bytes
    gameRegions*: uint32
    mediaFlags*: uint32

  BasicBlockPair* = tuple[dataSize: uint32; zeroSize: uint32]

  FileFormatInfo* = object
    infoSize*: uint32
    encryptionType*: uint16
    compressionType*: uint16
    # populated only when compressionType == CompressionBasic
    basicBlockPairs*: seq[BasicBlockPair]
    # populated only when compressionType == CompressionNormal (LZX)
    lzxWindowSize*: uint32
    lzxFirstBlockSize*: uint32
    lzxFirstBlockSha1*: seq[uint8]    # 20 bytes
    # raw payload bytes of the file-format-info block (for repack
    # rewrite — when patches don't change the compression layout, we
    # write these back verbatim so any unmapped tail bytes are preserved)
    rawBytes*: seq[uint8]
    blockOffsetInXex*: uint32         # absolute file offset of this block

# ---- file header ----

proc parseFileHeader*(buf: openArray[uint8]): Xex2FileHeader =
  if buf.len < HeaderFixedSize:
    raise newException(Xex2FormatError,
      "buffer too small for XEX2 header (len=" & toHex(buf.len) & ")")
  var r = newBEReader(buf)
  var magic = newString(4)
  for i in 0 .. 3: magic[i] = char(buf[i])
  if magic != Xex2Magic:
    raise newException(Xex2FormatError,
      "bad magic: expected 'XEX2', got '" & magic & "'")
  r.seek(0x04); result.moduleFlags = r.u32()
  r.seek(0x08); result.peDataOffset = r.u32()
  r.seek(0x0c); result.reserved = r.u32()
  r.seek(0x10); result.securityInfoOffset = r.u32()
  r.seek(0x14); result.optionalHeaderCount = r.u32()
  result.magic = magic

# ---- optional headers ----

proc parseOptionalHeaders*(buf: openArray[uint8],
                           count: uint32,
                           tableOffset: int = HeaderFixedSize):
                           seq[OptHeaderEntry] =
  ## Walk the optional-header table. Each entry is `(u32 BE key, u32 BE
  ## value)`. The low byte of `key` encodes storage:
  ##   - 0x00 / 0x01 → value is inline data (a u32).
  ##   - any other N → value is a file offset to a block of N*4 bytes.
  result = @[]
  var r = newBEReader(buf)
  for i in 0 ..< int(count):
    r.seek(tableOffset + i * 8)
    let key = r.u32()
    let value = r.u32()
    let low = key and 0xff'u32
    var entry = OptHeaderEntry(key: key)
    if low <= 1:
      entry = OptHeaderEntry(key: key, kind: ohkInline, inlineValue: value)
    else:
      let size = int(low) * 4
      var blob = newSeq[uint8](size)
      for j in 0 ..< size: blob[j] = buf[int(value) + j]
      entry = OptHeaderEntry(key: key, kind: ohkBlock,
                             blockBytes: blob, blockOffset: value)
    result.add(entry)

proc findOptionalHeader*(headers: seq[OptHeaderEntry],
                          keyHigh24: uint32): int =
  ## Returns the index of the entry whose `key >> 8` matches `keyHigh24`,
  ## or -1 if not present.
  let target = keyHigh24 and 0xffffff'u32
  for i, e in headers:
    if (e.key shr 8) == target: return i
  return -1

# ---- security info ----

proc sliceBytes(buf: openArray[uint8], off, n: int): seq[uint8] =
  result = newSeq[uint8](n)
  for i in 0 ..< n: result[i] = buf[off + i]

proc parseSecurityInfo*(buf: openArray[uint8], offset: uint32): SecurityInfo =
  var r = newBEReader(buf)
  let base = int(offset)
  r.seek(base + 0x000); result.headerSize = r.u32()
  r.seek(base + 0x004); result.imageSize = r.u32()
  result.rsaSignature = sliceBytes(buf, base + 0x008, 256)
  r.seek(base + 0x108); result.imageInfoSize = r.u32()
  r.seek(base + 0x10c); result.imageFlags = r.u32()
  r.seek(base + 0x110); result.loadAddress = r.u32()
  result.imageHash = sliceBytes(buf, base + 0x114, 20)
  r.seek(base + 0x128); result.importTableCount = r.u32()
  result.importTableHash = sliceBytes(buf, base + 0x12c, 20)
  result.mediaId = sliceBytes(buf, base + 0x140, 16)
  result.encryptedImageKey = sliceBytes(buf, base + 0x150, 16)
  r.seek(base + 0x160); result.exportTable = r.u32()
  result.headerHash = sliceBytes(buf, base + 0x164, 20)
  r.seek(base + 0x178); result.gameRegions = r.u32()
  r.seek(base + 0x17c); result.mediaFlags = r.u32()

# ---- file format info ----

proc parseFileFormatInfo*(blob: openArray[uint8],
                          blockOffsetInXex: uint32 = 0): FileFormatInfo =
  if blob.len < 8:
    raise newException(Xex2FormatError,
      "file format info too short (len=" & $blob.len & ")")
  var r = newBEReader(blob)
  r.seek(0x00); result.infoSize = r.u32()
  r.seek(0x04); result.encryptionType = r.u16()
  r.seek(0x06); result.compressionType = r.u16()
  result.blockOffsetInXex = blockOffsetInXex
  result.rawBytes = newSeq[uint8](blob.len)
  for i in 0 ..< blob.len: result.rawBytes[i] = blob[i]

  case result.compressionType
  of CompressionNormal:
    if blob.len < 0x08 + 4 + 4 + 20:
      raise newException(Xex2FormatError,
        "compression_type=2 payload too short for LZX header")
    r.seek(0x08); result.lzxWindowSize = r.u32()
    r.seek(0x0c); result.lzxFirstBlockSize = r.u32()
    var sha = newSeq[uint8](20)
    for i in 0 ..< 20: sha[i] = blob[0x10 + i]
    result.lzxFirstBlockSha1 = sha
  of CompressionBasic:
    let pairBytes = max(0, int(result.infoSize) - 0x08)
    let pairCount = pairBytes div 8
    result.basicBlockPairs = newSeq[BasicBlockPair](pairCount)
    for i in 0 ..< pairCount:
      let off = 0x08 + i * 8
      r.seek(off);     let dataSize = r.u32()
      r.seek(off + 4); let zeroSize = r.u32()
      result.basicBlockPairs[i] = (dataSize, zeroSize)
  of CompressionDelta:
    discard
  of CompressionNone:
    discard
  else:
    raise newException(Xex2FormatError,
      "unknown compression_type " & $result.compressionType)

proc findFileFormatInfo*(headers: seq[OptHeaderEntry]): FileFormatInfo =
  let idx = findOptionalHeader(headers, FileFormatInfoKeyHigh24)
  if idx < 0:
    raise newException(Xex2FormatError,
      "file format info optional header missing")
  let e = headers[idx]
  if e.kind != ohkBlock:
    raise newException(Xex2FormatError,
      "file format info optional header is inline; expected an out-of-line block")
  result = parseFileFormatInfo(e.blockBytes, e.blockOffset)
