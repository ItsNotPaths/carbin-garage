## XEX2 unpack + repack pipelines.
##
## `unpack` is decrypt → decompress → return PE image. `repack` runs the
## inverse on a patched PE image, emitting bytes that can be written back
## over the original .xex file (preserving its on-disk layout — same
## headers, same security-info, just with the new ciphertext payload).

import ./aes
import ./basic
import ./format

type
  Xex2BackendError* = object of CatchableError

  Probe* = object
    fileHeader*: Xex2FileHeader
    optionalHeaders*: seq[OptHeaderEntry]
    security*: SecurityInfo
    fileFormat*: FileFormatInfo

  UnpackResult* = object
    imageBytes*: seq[uint8]
    imageBase*: uint32
    keyUsed*: string                  # "retail" / "devkit" / "" (no encryption)
    probe*: Probe

proc isXex*(buf: openArray[uint8]): bool =
  buf.len >= 4 and buf[0] == byte('X') and buf[1] == byte('E') and
                   buf[2] == byte('X') and buf[3] == byte('2')

proc probeXex*(buf: openArray[uint8]): Probe =
  result.fileHeader = parseFileHeader(buf)
  result.optionalHeaders = parseOptionalHeaders(
    buf, result.fileHeader.optionalHeaderCount)
  result.security = parseSecurityInfo(buf, result.fileHeader.securityInfoOffset)
  result.fileFormat = findFileFormatInfo(result.optionalHeaders)

proc tryUnpackWithKey(payload: openArray[uint8],
                      info: Probe,
                      wrappingKey: openArray[uint8],
                      keyName: string): tuple[ok: bool; bytes: seq[uint8]] =
  let sessionKey = aes128EcbDecrypt(info.security.encryptedImageKey, wrappingKey)
  try:
    let iv = newSeq[uint8](16)
    let decrypted = aes128CbcDecrypt(payload, sessionKey, iv)
    var decompressed: seq[uint8]
    case info.fileFormat.compressionType
    of CompressionNone:
      decompressed = decrypted
    of CompressionBasic:
      decompressed = basicDecompress(decrypted, info.fileFormat)
    else:
      raise newException(Xex2BackendError,
        "compressionType " & $info.fileFormat.compressionType &
        " not implemented (only None/Basic in this Nim port)")
    if decompressed.len >= 2 and decompressed[0] == byte('M') and
       decompressed[1] == byte('Z'):
      result = (true, decompressed)
    else:
      result = (false, @[])
  except CatchableError:
    result = (false, @[])

proc unpackXex*(buf: openArray[uint8]): UnpackResult =
  ## Read xex2 bytes, decrypt + decompress into a PE image.
  let info = probeXex(buf)
  let payloadStart = int(info.fileHeader.peDataOffset)
  let payload = buf[payloadStart .. ^1]
  result.probe = info
  result.imageBase = info.security.loadAddress
  case info.fileFormat.encryptionType
  of EncryptionNone:
    var decompressed: seq[uint8]
    case info.fileFormat.compressionType
    of CompressionNone: decompressed = @payload
    of CompressionBasic: decompressed = basicDecompress(payload, info.fileFormat)
    else:
      raise newException(Xex2BackendError,
        "compressionType " & $info.fileFormat.compressionType & " not implemented")
    result.imageBytes = decompressed
    result.keyUsed = ""
  of EncryptionAes128Cbc:
    # Try retail first, then devkit (matches Python lib's "auto" mode).
    let retail = tryUnpackWithKey(payload, info, Xex2RetailKey, "retail")
    if retail.ok:
      result.imageBytes = retail.bytes
      result.keyUsed = "retail"
      return
    let devkit = tryUnpackWithKey(payload, info, Xex2DevkitKey, "devkit")
    if devkit.ok:
      result.imageBytes = devkit.bytes
      result.keyUsed = "devkit"
      return
    raise newException(Xex2BackendError,
      "neither retail nor devkit key produced a valid PE image " &
      "(decompressed output didn't start with 'MZ')")
  else:
    raise newException(Xex2FormatError,
      "unknown encryption_type: " & $info.fileFormat.encryptionType)

proc deriveSessionKey(info: Probe, keyName: string): seq[uint8] =
  ## Re-derive the session key for a known wrapping-key name.
  case keyName
  of "retail": aes128EcbDecrypt(info.security.encryptedImageKey, Xex2RetailKey)
  of "devkit": aes128EcbDecrypt(info.security.encryptedImageKey, Xex2DevkitKey)
  else:
    raise newException(Xex2BackendError, "unknown keyName: " & keyName)

proc repackXex*(originalXex: openArray[uint8],
                patchedImage: openArray[uint8],
                info: Probe,
                keyUsed: string,
                templateHeader: openArray[uint8] = []): seq[uint8] =
  ## When `templateHeader` is non-empty, those bytes replace the [0..len)
  ## header region of the output (in place of the originalXex's header).
  ## Used for FH1: a hardcoded known-good header from a community-patched
  ## xex (with its rsa_signature zeroed + header_hash recomputed for its
  ## restructured layout) lets us produce a loader-accepting result
  ## without solving the header-hash-domain reverse-engineering puzzle.
  ## When the FileFormatInfo in the template differs from originalXex's,
  ## the template's pairs/encryption are used for repack — extract them
  ## from `info` (the caller probes the template, not the original).
  ## Build a new .xex by:
  ##   1. Re-applying basic compression to the patched PE image.
  ##   2. Re-encrypting (AES-128-CBC, IV = zeros) using the same session
  ##      key the unpack flow used.
  ##   3. Splicing the new ciphertext at the original `peDataOffset`,
  ##      preserving every byte before that point (xex headers, optional
  ##      headers, security info, etc.) from the source file.
  ## All file offsets / sizes / counters in the headers stay the same.
  ## Patches that change `image_size` would require resigning, which is
  ## out of scope — verify caller's patches don't grow the image.
  var compressed: seq[uint8]
  case info.fileFormat.compressionType
  of CompressionNone:
    compressed = @patchedImage
  of CompressionBasic:
    compressed = basicCompress(patchedImage, info.fileFormat)
  else:
    raise newException(Xex2BackendError,
      "compressionType " & $info.fileFormat.compressionType &
      " repack not implemented")

  var ciphertext: seq[uint8] = @[]
  let et = info.fileFormat.encryptionType
  if et == EncryptionNone:
    ciphertext = compressed
  elif et == EncryptionAes128Cbc:
    if keyUsed.len == 0:
      raise newException(Xex2BackendError,
        "encrypted xex but keyUsed is empty — can't re-encrypt")
    let sessionKey = deriveSessionKey(info, keyUsed)
    let iv = newSeq[uint8](16)
    ciphertext = aes128CbcEncrypt(compressed, sessionKey, iv)
  else:
    raise newException(Xex2FormatError,
      "unknown encryption_type for repack: " & $et)

  let payloadStart = int(info.fileHeader.peDataOffset)
  let originalPayloadLen = originalXex.len - payloadStart
  if ciphertext.len != originalPayloadLen:
    raise newException(Xex2BackendError,
      "repacked payload size mismatch: got " & $ciphertext.len &
      " expected " & $originalPayloadLen &
      " (patches that change compressed size are not supported)")
  result = newSeq[uint8](originalXex.len)
  if templateHeader.len > 0:
    # Splice template's header verbatim. Caller's responsibility to ensure
    # template.pe_data_offset == originalXex.pe_data_offset (= payloadStart).
    if templateHeader.len != payloadStart:
      raise newException(Xex2BackendError,
        "templateHeader length " & $templateHeader.len &
        " != expected " & $payloadStart)
    for i in 0 ..< payloadStart: result[i] = templateHeader[i]
  else:
    for i in 0 ..< payloadStart: result[i] = originalXex[i]
  for i in 0 ..< ciphertext.len: result[payloadStart + i] = ciphertext[i]
