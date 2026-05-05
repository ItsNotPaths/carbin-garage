## Grab-and-place part swap, glTF-level.
##
## `applyPartSwap` finds donor mesh by name in the donor working slot,
## clones every accessor it references (POSITION, NORMAL, TEXCOORD_0/1,
## indices) into the host slot's car.bin, and rewrites the host mesh's
## primitives[] to point at those clones — preserving the host mesh's
## NAME + EXTRAS so its slot tag (e.g. "hooda") survives the swap. The
## host's material is reused on the donor primitives, so the swapped part
## inherits the host's paint/textures.
##
## Out of scope (separate phase): mutating geometry/*.carbin sections so
## the swap survives an export. The GUI 3D scene loads exclusively from
## car.gltf + car.bin, so the swap is immediately visible there. Re-export
## to a target game would still ship donor passthrough until the carbin
## emitter learns to splice individual sections.

import std/[json, os, sets, tables]

type
  PartSwapError* = object of CatchableError

const
  GLTF_BYTE          = 5120
  GLTF_UNSIGNED_BYTE = 5121
  GLTF_SHORT         = 5122
  GLTF_UNSIGNED_SHORT= 5123
  GLTF_UNSIGNED_INT  = 5125
  GLTF_FLOAT         = 5126

proc componentSize(componentType: int): int =
  case componentType
  of GLTF_BYTE, GLTF_UNSIGNED_BYTE: 1
  of GLTF_SHORT, GLTF_UNSIGNED_SHORT: 2
  of GLTF_UNSIGNED_INT, GLTF_FLOAT: 4
  else:
    raise newException(PartSwapError,
      "unknown componentType: " & $componentType)

proc typeChannels(typ: string): int =
  case typ
  of "SCALAR": 1
  of "VEC2":   2
  of "VEC3":   3
  of "VEC4":   4
  of "MAT2":   4
  of "MAT3":   9
  of "MAT4":   16
  else:
    raise newException(PartSwapError, "unknown accessor type: " & typ)

proc elementSize(componentType: int; typ: string): int =
  componentSize(componentType) * typeChannels(typ)

proc findMeshIdx(j: JsonNode; name: string): int =
  for i in 0 ..< j["meshes"].len:
    if j["meshes"][i]{"name"}.getStr == name:
      return i
  result = -1

proc collectAccessors(donorMesh: JsonNode): seq[int] =
  ## Every unique accessor index referenced by the donor mesh's primitives:
  ## indices + POSITION/NORMAL/TEXCOORD_*. Other vertex attribs (TANGENT,
  ## COLOR_*, JOINTS_*, WEIGHTS_*) are uncommon for this codebase but cloned
  ## too if present.
  var seen = initHashSet[int]()
  for prim in donorMesh["primitives"]:
    if prim.hasKey("indices"):
      let v = prim["indices"].getInt
      if v >= 0 and v notin seen:
        seen.incl v; result.add v
    if prim.hasKey("attributes"):
      for _, av in prim["attributes"]:
        let v = av.getInt
        if v >= 0 and v notin seen:
          seen.incl v; result.add v

proc bvByteSlice(srcGltf: JsonNode; accIdx: int): tuple[start, len: int] =
  ## Resolve an accessor's absolute byte range inside its source car.bin.
  let acc = srcGltf["accessors"][accIdx]
  let bv  = srcGltf["bufferViews"][acc["bufferView"].getInt]
  let bvOff = bv{"byteOffset"}.getInt(0)
  let accOff = acc{"byteOffset"}.getInt(0)
  let elem = elementSize(acc["componentType"].getInt, acc["type"].getStr)
  let count = acc["count"].getInt
  (bvOff + accOff, count * elem)

proc padTo4(s: var string) =
  while (s.len mod 4) != 0: s.add '\0'

proc cloneAccessor(srcGltf: JsonNode; srcAccIdx: int;
                   dstGltf: var JsonNode;
                   srcBin: string; dstBin: var string): int =
  ## Append the bytes referenced by `srcAccIdx` to `dstBin` (4-byte
  ## aligned), add a new bufferView + accessor to `dstGltf`, and return
  ## the new accessor index.
  let srcAcc = srcGltf["accessors"][srcAccIdx]
  let (srcOff, byteLen) = bvByteSlice(srcGltf, srcAccIdx)

  padTo4(dstBin)
  let bvOff = dstBin.len
  if byteLen > 0:
    let oldLen = dstBin.len
    dstBin.setLen(oldLen + byteLen)
    copyMem(addr dstBin[oldLen], unsafeAddr srcBin[srcOff], byteLen)

  # New bufferView. We don't carry over `target` because vertex vs index
  # buffers are inferred per-accessor at draw time; runtime loader doesn't
  # need it.
  var bvNode = %*{
    "buffer":     0,
    "byteOffset": bvOff,
    "byteLength": byteLen}
  let bvIdx = dstGltf["bufferViews"].len
  dstGltf["bufferViews"].add bvNode

  # Clone the accessor body but re-anchor it on our new bufferView.
  var accNode = copy(srcAcc)
  accNode["bufferView"] = %bvIdx
  if accNode.hasKey("byteOffset"): accNode.delete("byteOffset")

  result = dstGltf["accessors"].len
  dstGltf["accessors"].add accNode

proc applyPartSwap*(workingRoot, donorSlug, donorPartName,
                    hostSlug, hostPartName: string) =
  ## Mutates host's car.gltf + car.bin in place. Caller is expected to
  ## have already called workspace.snapshotForUndo before invoking this.
  ## Raises PartSwapError on any structural problem.
  let donorGltfPath = workingRoot / donorSlug / "car.gltf"
  let donorBinPath  = workingRoot / donorSlug / "car.bin"
  let hostGltfPath  = workingRoot / hostSlug  / "car.gltf"
  let hostBinPath   = workingRoot / hostSlug  / "car.bin"
  for p in [donorGltfPath, donorBinPath, hostGltfPath, hostBinPath]:
    if not fileExists(p):
      raise newException(PartSwapError, "missing: " & p)

  let donorGltf = parseFile(donorGltfPath)
  var hostGltf  = parseFile(hostGltfPath)
  let donorBin  = readFile(donorBinPath)
  var hostBin   = readFile(hostBinPath)

  let donorMeshIdx = findMeshIdx(donorGltf, donorPartName)
  if donorMeshIdx < 0:
    raise newException(PartSwapError,
      "donor mesh not found: " & donorPartName & " in " & donorSlug)
  let hostMeshIdx  = findMeshIdx(hostGltf, hostPartName)
  if hostMeshIdx < 0:
    raise newException(PartSwapError,
      "host mesh not found: " & hostPartName & " in " & hostSlug)

  let donorMesh = donorGltf["meshes"][donorMeshIdx]
  let hostMesh  = hostGltf["meshes"][hostMeshIdx]

  # Choose a host-side material to keep paint/texture local. Donor's
  # material id is donor-relative and pointing at it would be a stale
  # index into hostGltf["materials"]. Fall back to material 0 if the host
  # mesh had no material.
  var hostMaterial = -1
  if hostMesh.hasKey("primitives") and hostMesh["primitives"].len > 0:
    let p0 = hostMesh["primitives"][0]
    if p0.hasKey("material"):
      hostMaterial = p0["material"].getInt
  if hostMaterial < 0 and hostGltf["materials"].len > 0:
    hostMaterial = 0

  # Clone every accessor referenced by donor's mesh.
  var accMap = initTable[int, int]()
  for srcIdx in collectAccessors(donorMesh):
    let dstIdx = cloneAccessor(donorGltf, srcIdx, hostGltf,
                               donorBin, hostBin)
    accMap[srcIdx] = dstIdx

  # Build new primitives[] from donor's, with accessor refs remapped and
  # material set to the host's chosen material.
  var newPrims = newJArray()
  for prim in donorMesh["primitives"]:
    var np = copy(prim)
    if np.hasKey("indices"):
      np["indices"] = %accMap[prim["indices"].getInt]
    if np.hasKey("attributes"):
      var newAttrs = newJObject()
      for ak, av in prim["attributes"]:
        newAttrs[ak] = %accMap[av.getInt]
      np["attributes"] = newAttrs
    if hostMaterial >= 0:
      np["material"] = %hostMaterial
    elif np.hasKey("material"):
      np.delete("material")
    newPrims.add np

  # Replace primitives in place; preserve mesh name + extras (tag stays).
  hostGltf["meshes"][hostMeshIdx]["primitives"] = newPrims

  # Update buffer length.
  hostGltf["buffers"][0]["byteLength"] = %hostBin.len

  # Persist.
  writeFile(hostBinPath, hostBin)
  writeFile(hostGltfPath, $hostGltf)
