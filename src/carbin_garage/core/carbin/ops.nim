## Whole-section operations: replace / insert. Port of probe/reference/fm4carbin/ops.py.

import ../be
import ./model

proc replaceSection*(targetData: openArray[byte], targetSec: SectionInfo,
                     newSectionBytes: openArray[byte]): seq[byte] =
  result = newSeq[byte](targetSec.start + newSectionBytes.len + (targetData.len - targetSec.endPos))
  for i in 0 ..< targetSec.start: result[i] = targetData[i]
  for i in 0 ..< newSectionBytes.len: result[targetSec.start + i] = newSectionBytes[i]
  let tailStart = targetSec.start + newSectionBytes.len
  for i in 0 ..< targetData.len - targetSec.endPos:
    result[tailStart + i] = targetData[targetSec.endPos + i]

proc insertNewSection*(targetData: openArray[byte], info: CarbinInfo,
                       newSectionBytes: openArray[byte]): seq[byte] =
  let insertAt = info.sectionsEnd
  result = newSeq[byte](targetData.len + newSectionBytes.len)
  for i in 0 ..< insertAt: result[i] = targetData[i]
  for i in 0 ..< newSectionBytes.len: result[insertAt + i] = newSectionBytes[i]
  let tailStart = insertAt + newSectionBytes.len
  for i in 0 ..< targetData.len - insertAt:
    result[tailStart + i] = targetData[insertAt + i]
  # bump partCount in-place
  let packed = bePackU32(info.partCountDeclared + 1)
  for i in 0 .. 3: result[info.partCountPos + i] = packed[i]
