## XEX2 compression_type=1 "basic" compression — decompress + recompress.
##
## Format: a sequence of (data_size, zero_size) pairs from the
## file-format-info block. Decompression interleaves `data_size` payload
## bytes with `zero_size` zero bytes per pair.
##
## Recompression re-uses the SAME (data_size, zero_size) pair structure
## that the original xex declared, just re-emitting the data slices from
## the patched plaintext. We don't re-derive the zero-runs from the
## patched bytes — the xex's pair table is the source of truth and our
## patches deliberately don't touch zero-run regions.

import ./format

proc basicDecompress*(payload: openArray[uint8],
                      info: FileFormatInfo): seq[uint8] =
  ## Inverse of basicCompress. Walks each pair, copies `data_size` bytes
  ## from `payload`, then appends `zero_size` zero bytes.
  if info.compressionType != CompressionBasic:
    raise newException(Xex2FormatError,
      "basicDecompress called on compressionType=" & $info.compressionType)
  var totalOut = 0
  for p in info.basicBlockPairs:
    totalOut += int(p.dataSize) + int(p.zeroSize)
  result = newSeq[uint8](totalOut)
  var srcPos = 0
  var dstPos = 0
  for p in info.basicBlockPairs:
    let ds = int(p.dataSize)
    let zs = int(p.zeroSize)
    if srcPos + ds > payload.len:
      raise newException(Xex2FormatError,
        "basic pair (data=" & $ds & ", zero=" & $zs & ") overruns payload " &
        "(srcPos=" & $srcPos & ", payloadLen=" & $payload.len & ")")
    for k in 0 ..< ds: result[dstPos + k] = payload[srcPos + k]
    # zero region is already zeros from newSeq
    srcPos += ds
    dstPos += ds + zs

proc basicCompress*(plaintext: openArray[uint8],
                    info: FileFormatInfo): seq[uint8] =
  ## Inverse — re-emit the basic-compressed payload using the donor xex's
  ## pair table. The total payload size is sum(p.dataSize) bytes; we copy
  ## the data slices straight from `plaintext` at the positions implied
  ## by walking the pair table.
  if info.compressionType != CompressionBasic:
    raise newException(Xex2FormatError,
      "basicCompress called on compressionType=" & $info.compressionType)
  var totalData = 0
  for p in info.basicBlockPairs: totalData += int(p.dataSize)
  result = newSeq[uint8](totalData)
  var srcPos = 0
  var dstPos = 0
  for p in info.basicBlockPairs:
    let ds = int(p.dataSize)
    let zs = int(p.zeroSize)
    if srcPos + ds > plaintext.len:
      raise newException(Xex2FormatError,
        "plaintext shorter than expected during basicCompress " &
        "(srcPos=" & $srcPos & ", need " & $ds & ", have " & $plaintext.len & ")")
    for k in 0 ..< ds: result[dstPos + k] = plaintext[srcPos + k]
    srcPos += ds + zs
    dstPos += ds
