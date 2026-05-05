## Runtime glTF loader for the GUI scene.
##
## Strict — assumes the writer-side shape from `gltf.nim`: a single .bin
## buffer, accessors with FLOAT vec3 positions / normals, FLOAT vec2 UVs,
## and UINT16 / UINT32 indices. Per-mesh extras tag `lodKind`. No skins.
##
## Coordinate convention: glTF is right-handed Y-up; our world is Z-up
## with +Y forward. The (x, y, z) → (x, -z, y) rotation is baked in here
## so the GPU upload has no further transform to do.
##
## Output is grouped into per-material submeshes — primitives that share
## the same baseColor + texture are merged into a single index range so
## the renderer issues one draw per material rather than per primitive.

import std/[json, os, tables]

type
  CarSubmesh* = object
    ## A contiguous index range that shares one material. Caller binds
    ## the texture (empty `imageUri` ⇒ bind a 1×1 white) and pushes
    ## baseColor + spec params into the material UBO.
    indexOffset*: uint32
    indexCount*:  uint32
    baseColor*:   array[4, float32]
    metallic*:    float32          # glTF metallicFactor (default 1.0)
    roughness*:   float32          # glTF roughnessFactor (default 1.0)
    imageUri*:    string

  MainCarMesh* = object
    ## Drawable mesh in world space. Indices reference the combined
    ## pos/normal/uv arrays. Submeshes index into `indices`.
    pos*:     seq[float32]   # interleaved x, y, z
    normal*:  seq[float32]
    uv*:      seq[float32]   # interleaved u, v (TEXCOORD_0 with subsection bake)
    indices*: seq[uint32]
    submeshes*: seq[CarSubmesh]
    bbMin*, bbMax*: array[3, float32]

  GltfPartMeta* = object
    ## Lightweight per-mesh metadata for the R pane parts list. Populated
    ## from the glTF JSON only — no buffer slurp.
    name*:     string        # mesh.name (e.g. "hooda", "wheel-fl")
    meshIdx*:  int           # index into j["meshes"]
    nodeIdx*:  int           # first node referencing this mesh, or -1
    lodKind*:  string        # extras.carbin.lodKind ("main"/"lod0"/"cockpit"/"corner")
    primCount*: int          # number of primitives in the mesh
    section*:  string        # extras.carbin.section if present, else mesh.name

const
  GLTF_UNSIGNED_BYTE  = 5121
  GLTF_UNSIGNED_SHORT = 5123
  GLTF_UNSIGNED_INT   = 5125

  ExteriorLodKinds* = ["main", "corner", "cockpit"]
    ## Body + wheels + cabin interior. Cockpit must be in here so the
    ## dash / steering wheel / seats are visible through transparent
    ## glass — without them, the windshield blends with the dark back
    ## of the body shell and reads as opaque. Excludes `lod0`, which
    ## would double-render the body at higher detail over `main`.

proc accByteOffset(j: JsonNode; accIdx: int): tuple[off, count: int] =
  let acc = j["accessors"][accIdx]
  let bv  = j["bufferViews"][acc["bufferView"].getInt]
  let off = bv{"byteOffset"}.getInt(0) + acc{"byteOffset"}.getInt(0)
  (off, acc["count"].getInt)

proc readVec3(bin: string; off, count: int): seq[float32] =
  result = newSeq[float32](count * 3)
  if count > 0:
    copyMem(addr result[0], unsafeAddr bin[off], count * 12)

proc readVec2(bin: string; off, count: int): seq[float32] =
  result = newSeq[float32](count * 2)
  if count > 0:
    copyMem(addr result[0], unsafeAddr bin[off], count * 8)

proc readIndices(bin: string; j: JsonNode; accIdx: int): seq[uint32] =
  let acc = j["accessors"][accIdx]
  let (off, count) = accByteOffset(j, accIdx)
  result = newSeq[uint32](count)
  case acc["componentType"].getInt
  of GLTF_UNSIGNED_BYTE:
    for i in 0 ..< count:
      result[i] = uint32(uint8(bin[off + i]))
  of GLTF_UNSIGNED_SHORT:
    for i in 0 ..< count:
      let lo = uint8(bin[off + i*2])
      let hi = uint8(bin[off + i*2 + 1])
      result[i] = uint32(lo) or (uint32(hi) shl 8)
  of GLTF_UNSIGNED_INT:
    if count > 0:
      copyMem(addr result[0], unsafeAddr bin[off], count * 4)
  else:
    raise newException(IOError,
      "unsupported index componentType " & $acc["componentType"].getInt)

proc materialBaseColor(j: JsonNode; matIdx: int): array[4, float32] =
  ## glTF default is white opaque if pbrMetallicRoughness or
  ## baseColorFactor is missing.
  result = [1'f32, 1'f32, 1'f32, 1'f32]
  if matIdx < 0: return
  let mat = j["materials"][matIdx]
  let pbr = mat{"pbrMetallicRoughness"}
  if pbr == nil or pbr.kind != JObject: return
  let bcf = pbr{"baseColorFactor"}
  if bcf != nil and bcf.kind == JArray and bcf.len >= 3:
    for i in 0 ..< min(4, bcf.len):
      result[i] = float32(bcf[i].getFloat)

proc materialPbrFactors(j: JsonNode; matIdx: int): tuple[metallic, roughness: float32] =
  ## glTF defaults: metallicFactor = 1.0, roughnessFactor = 1.0.
  result = (1'f32, 1'f32)
  if matIdx < 0: return
  let mat = j["materials"][matIdx]
  let pbr = mat{"pbrMetallicRoughness"}
  if pbr == nil or pbr.kind != JObject: return
  let mf = pbr{"metallicFactor"}
  if mf != nil and mf.kind in {JFloat, JInt}:
    result.metallic = float32(mf.getFloat)
  let rf = pbr{"roughnessFactor"}
  if rf != nil and rf.kind in {JFloat, JInt}:
    result.roughness = float32(rf.getFloat)

proc materialImageUri(j: JsonNode; matIdx: int): string =
  ## Returns the baseColorTexture's image URI, or "" if untextured.
  if matIdx < 0: return ""
  let mat = j["materials"][matIdx]
  let pbr = mat{"pbrMetallicRoughness"}
  if pbr == nil or pbr.kind != JObject: return ""
  let bct = pbr{"baseColorTexture"}
  if bct == nil or bct.kind != JObject: return ""
  let texIdx = bct["index"].getInt
  let tex    = j["textures"][texIdx]
  let imgIdx = tex["source"].getInt
  let img    = j["images"][imgIdx]
  result = img{"uri"}.getStr("")

proc loadMainCarMesh*(gltfPath: string;
                     lodKinds: openArray[string] = ExteriorLodKinds;
                     bodyLiftZ: float32 = 0'f32;
                     wheelInsetX: float32 = 0'f32): MainCarMesh =
  ## Parse car.gltf, slurp the .bin, walk every node referenced by the
  ## default scene whose mesh's `extras.carbin.lodKind` is in `lodKinds`,
  ## decode pos / normal / uv / indices, apply that node's translation,
  ## swap glTF Y-up to world Z-up, accumulate vertices, and group
  ## indices by material into submeshes.
  ##
  ## `bodyLiftZ` lifts non-instanced (static body) vertices by that much
  ## along world Z. `wheelInsetX` pulls instanced parts toward x=0 along
  ## the car's width axis.
  let baseDir = parentDir(gltfPath)
  let j       = parseFile(gltfPath)
  let binUri  = j["buffers"][0]["uri"].getStr
  let bin     = readFile(baseDir / binUri)

  # Allowed-mesh predicate with legacy fallback (cars imported before
  # lodKind extras existed have no tag — accept all in that case).
  var meshAllowed = newSeq[bool](j["meshes"].len)
  var anyAllowed  = false
  block:
    var keep = initTable[string, bool]()
    for k in lodKinds: keep[k] = true
    for i in 0 ..< j["meshes"].len:
      let lk = j["meshes"][i]{"extras", "carbin", "lodKind"}.getStr("")
      meshAllowed[i] = keep.hasKey(lk)
      if meshAllowed[i]: anyAllowed = true
    if not anyAllowed:
      for i in 0 ..< meshAllowed.len: meshAllowed[i] = true

  # Collect indices per material, plus baseColor / imageUri for that material.
  type MaterialBucket = object
    indices:   seq[uint32]
    baseColor: array[4, float32]
    metallic:  float32
    roughness: float32
    imageUri:  string
  var perMat = initOrderedTable[int, MaterialBucket]()

  let sceneNodes = j["scenes"][j{"scene"}.getInt(0)]["nodes"]
  var first = true

  for nodeIdxJ in sceneNodes:
    let node = j["nodes"][nodeIdxJ.getInt]
    if not node.hasKey("mesh"): continue
    let meshIdx = node["mesh"].getInt
    if not meshAllowed[meshIdx]: continue

    var tx, ty, tz: float32 = 0
    let isInstanced = node.hasKey("translation")
    if isInstanced:
      let t = node["translation"]
      tx = float32(t[0].getFloat)
      ty = float32(t[1].getFloat)
      tz = float32(t[2].getFloat)
      if wheelInsetX != 0'f32:
        if tx > 0:   tx = max(tx - wheelInsetX, 0'f32)
        elif tx < 0: tx = min(tx + wheelInsetX, 0'f32)
    if node.hasKey("matrix") or node.hasKey("rotation") or node.hasKey("scale"):
      raise newException(IOError,
        "node has matrix / rotation / scale — runtime loader expects translation only")
    let bodyExtraZ = if isInstanced: 0'f32 else: bodyLiftZ

    for prim in j["meshes"][meshIdx]["primitives"]:
      let attrs  = prim["attributes"]
      let posIdx = attrs["POSITION"].getInt
      let nrmIdx = attrs["NORMAL"].getInt
      let uvIdx  = attrs{"TEXCOORD_0"}.getInt(-1)
      let idxIdx = prim["indices"].getInt
      let matIdx = prim{"material"}.getInt(-1)

      let (posOff, posCount) = accByteOffset(j, posIdx)
      let (nrmOff, nrmCount) = accByteOffset(j, nrmIdx)
      if posCount != nrmCount:
        raise newException(IOError, "POSITION/NORMAL count mismatch")

      let posIn = readVec3(bin, posOff, posCount)
      let nrmIn = readVec3(bin, nrmOff, nrmCount)
      var uvIn:  seq[float32]
      if uvIdx >= 0:
        let (uvOff, uvCount) = accByteOffset(j, uvIdx)
        if uvCount != posCount:
          raise newException(IOError, "TEXCOORD_0 count mismatch")
        uvIn = readVec2(bin, uvOff, uvCount)
      else:
        uvIn = newSeq[float32](posCount * 2)
      let idx = readIndices(bin, j, idxIdx)

      let baseVert = uint32(result.pos.len div 3)

      for i in 0 ..< posCount:
        let x = posIn[i*3 + 0] + tx
        let y = posIn[i*3 + 1] + ty
        let z = posIn[i*3 + 2] + tz
        let wx =  x
        let wy = -z
        let wz =  y + bodyExtraZ
        result.pos.add wx; result.pos.add wy; result.pos.add wz

        let nx = nrmIn[i*3 + 0]
        let ny = nrmIn[i*3 + 1]
        let nz = nrmIn[i*3 + 2]
        result.normal.add  nx
        result.normal.add -nz
        result.normal.add  ny

        result.uv.add uvIn[i*2 + 0]
        result.uv.add uvIn[i*2 + 1]

        if first:
          result.bbMin = [wx, wy, wz]
          result.bbMax = [wx, wy, wz]
          first = false
        else:
          if wx < result.bbMin[0]: result.bbMin[0] = wx
          if wy < result.bbMin[1]: result.bbMin[1] = wy
          if wz < result.bbMin[2]: result.bbMin[2] = wz
          if wx > result.bbMax[0]: result.bbMax[0] = wx
          if wy > result.bbMax[1]: result.bbMax[1] = wy
          if wz > result.bbMax[2]: result.bbMax[2] = wz

      # Drop the offset-adjusted indices into the per-material bucket.
      if not perMat.hasKey(matIdx):
        let mr = materialPbrFactors(j, matIdx)
        perMat[matIdx] = MaterialBucket(
          baseColor: materialBaseColor(j, matIdx),
          metallic:  mr.metallic,
          roughness: mr.roughness,
          imageUri:  materialImageUri(j, matIdx))
      for ix in idx:
        perMat[matIdx].indices.add ix + baseVert

  # Flatten per-material buckets into the final IBO + submesh list.
  for matIdx, bucket in perMat:
    if bucket.indices.len == 0: continue
    let off = uint32(result.indices.len)
    for ix in bucket.indices:
      result.indices.add ix
    result.submeshes.add CarSubmesh(
      indexOffset: off,
      indexCount:  uint32(bucket.indices.len),
      baseColor:   bucket.baseColor,
      metallic:    bucket.metallic,
      roughness:   bucket.roughness,
      imageUri:    bucket.imageUri)

proc listCarParts*(gltfPath: string): seq[GltfPartMeta] =
  ## Enumerate every mesh in the default scene with its name + lodKind +
  ## primitive count, in scene-node order. Cheap — only parses car.gltf;
  ## never reads car.bin. The R pane parts list consumes this directly.
  let j = parseFile(gltfPath)
  let nMeshes = j["meshes"].len

  # Map meshIdx -> first nodeIdx that references it (parts may also be
  # un-referenced glTF leftovers; we still expose them, with nodeIdx=-1).
  var firstNode = newSeq[int](nMeshes)
  for i in 0 ..< nMeshes: firstNode[i] = -1
  for ni in 0 ..< j["nodes"].len:
    let n = j["nodes"][ni]
    if not n.hasKey("mesh"): continue
    let mi = n["mesh"].getInt
    if mi >= 0 and mi < nMeshes and firstNode[mi] == -1:
      firstNode[mi] = ni

  for mi in 0 ..< nMeshes:
    let m = j["meshes"][mi]
    var meta: GltfPartMeta
    meta.meshIdx = mi
    meta.nodeIdx = firstNode[mi]
    meta.name = m{"name"}.getStr("mesh_" & $mi)
    meta.lodKind = m{"extras", "carbin", "lodKind"}.getStr("")
    meta.section = m{"extras", "carbin", "section"}.getStr(meta.name)
    meta.primCount =
      if m.hasKey("primitives"): m["primitives"].len else: 0
    result.add meta
