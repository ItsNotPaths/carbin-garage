## scene3d.nim — 3D background for the GUI: dark room (interior cube) +
## cylinder pedestal + textured car. One pipeline (`shaders/scene.{vert,frag}`)
## with vertex layout pos+normal+uv+ubyte4 baked-AO and a fragment sampler.
## Per-draw fragment uniform supplies corner-darken (room) or contact-shadow
## disc (pedestal top). The shader always samples `uTex`; the renderer binds
## a 1×1 white texture for non-textured draws (room, pedestal, flat car
## materials), so the multiply is a no-op for those. Z-up world.

import std/[math, os, strformat, tables]
import ../render/platform/sdl3
import ../render/gfx
import ../render/math3d
import ../render/camera
import ../carbin_garage/core/gltf_runtime

const
  SceneVertSpv = staticRead("../../shaders/scene.vert.spv")
  SceneFragSpv = staticRead("../../shaders/scene.frag.spv")

  RoomHalfX*  = 12.0'f32
  RoomHalfY*  = 12.0'f32
  RoomHalfZ*  = 6.75'f32
  RoomCenterZ = 6.75'f32  # floor at z=0, ceiling at z=13.5

  PedestalRadius*    = 2.25'f32
  PedestalHeight*    = 0.5'f32
  PedestalSegments   = 48

  RoomColor     = [0.16'f32, 0.16'f32, 0.18'f32]
  PedestalColor = [0.88'f32, 0.88'f32, 0.90'f32]

  RoomCornerStrength = 0.55'f32
  RoomCornerFalloff  = 1.6'f32 / 3.0'f32

  FloorRingStrength = 0.45'f32
  FloorRingInner    = PedestalRadius - 0.05'f32
  FloorRingOuter    = PedestalRadius * 2.2'f32

  PedestalContactStrength = 0.55'f32
  PedestalContactInner    = 0.0'f32
  PedestalContactOuter    = PedestalRadius * 0.95'f32
  TopNormalThreshold      = 0.5'f32

  CarBodyLift = 0.18'f32
  WheelInsetX = 0.12'f32

# ───── stb_image FFI (impl is compiled once via core/xds.nim) ──────────────
proc stbi_load_from_memory(buffer: pointer; bufLen: cint;
                           x, y, channels: ptr cint;
                           desired_channels: cint): pointer
                           {.importc, header: "stb_image.h".}
proc stbi_image_free(p: pointer) {.importc, header: "stb_image.h".}

type
  SceneVertex {.packed.} = object
    pos: array[3, float32]
    nrm: array[3, float32]
    u, v: float32
    ao0, ao1, ao2, ao3: uint8

  GlobalsUbo {.packed.} = object
    mvp: Mat4

  MaterialUbo {.packed.} = object
    baseColor:    array[4, float32]
    boxParams:    array[4, float32]
    boxCenter:    array[4, float32]
    contactDisc:  array[4, float32]
    contactExtra: array[4, float32]
    specParams:   array[4, float32]   # x = shininess, y = strength, zw = pad

  LightingUbo {.packed.} = object
    eyeWorld:  array[4, float32]   # xyz = camera world pos
    keyDir:    array[4, float32]   # xyz = direction TO key, w = unused
    keyColor:  array[4, float32]
    fillDir:   array[4, float32]   # xyz = direction TO fill, w = unused
    fillColor: array[4, float32]

  Mesh = object
    vbuf: ptr SDL_GPUBuffer
    ibuf: ptr SDL_GPUBuffer
    indexCount: uint32

  CarPart = object
    indexOffset, indexCount: uint32
    baseColor: array[4, float32]
    shininess, specStrength: float32
    texture: ptr SDL_GPUTexture     # may point at scene.whiteTex
    transparent: bool

  Scene3D* = object
    pipelineOpaque, pipelineTransparent: ptr SDL_GPUGraphicsPipeline
    room: Mesh
    pedestal: Mesh
    car: Mesh
    carLoaded: bool
    carParts: seq[CarPart]
    carTextures: seq[ptr SDL_GPUTexture]  # owned car-specific textures
    whiteTex: ptr SDL_GPUTexture
    sampler: ptr SDL_GPUSampler
    depthTex: ptr SDL_GPUTexture
    depthW, depthH: uint32
    camera*: OrbitCamera
    rmbDragging: bool
    mmbDragging: bool

const SceneVertexStride = uint32(sizeof(SceneVertex))

proc setAo(v: var SceneVertex; ao: float32) =
  let a = clamp(ao, 0.0, 1.0)
  v.ao0 = uint8(a * 255.0'f32 + 0.5'f32)

proc pushQuad(verts: var seq[SceneVertex]; idx: var seq[uint32];
              p0, p1, p2, p3: array[3, float32]; n: array[3, float32];
              ao: float32) =
  let base = uint32(verts.len)
  for p in [p0, p1, p2, p3]:
    var v = SceneVertex(pos: p, nrm: n)
    setAo(v, ao)
    verts.add v
  idx.add base + 0; idx.add base + 1; idx.add base + 2
  idx.add base + 0; idx.add base + 2; idx.add base + 3

proc buildRoomMesh(): tuple[verts: seq[SceneVertex]; idx: seq[uint32]] =
  let
    hx = RoomHalfX
    hy = RoomHalfY
    z0 = 0.0'f32
    z1 = RoomCenterZ * 2.0'f32
  var verts: seq[SceneVertex] = @[]
  var idx:   seq[uint32]      = @[]
  pushQuad(verts, idx,
           [-hx, -hy, z0], [ hx, -hy, z0], [ hx,  hy, z0], [-hx,  hy, z0],
           [0'f32, 0'f32, 1'f32], 1'f32)
  pushQuad(verts, idx,
           [ hx, -hy, z0], [ hx, -hy, z1], [ hx,  hy, z1], [ hx,  hy, z0],
           [-1'f32, 0'f32, 0'f32], 1'f32)
  pushQuad(verts, idx,
           [-hx,  hy, z0], [-hx,  hy, z1], [-hx, -hy, z1], [-hx, -hy, z0],
           [1'f32, 0'f32, 0'f32], 1'f32)
  pushQuad(verts, idx,
           [ hx,  hy, z0], [ hx,  hy, z1], [-hx,  hy, z1], [-hx,  hy, z0],
           [0'f32, -1'f32, 0'f32], 1'f32)
  pushQuad(verts, idx,
           [-hx, -hy, z0], [-hx, -hy, z1], [ hx, -hy, z1], [ hx, -hy, z0],
           [0'f32, 1'f32, 0'f32], 1'f32)
  (verts, idx)

proc buildPedestalMesh(): tuple[verts: seq[SceneVertex]; idx: seq[uint32]] =
  let
    r = PedestalRadius
    h = PedestalHeight
    segs = PedestalSegments
  var verts: seq[SceneVertex] = @[]
  var idx:   seq[uint32]      = @[]

  let aoRimTop = 0.92'f32
  let aoSideMid = 1.0'f32
  let aoSideBot = 0.55'f32
  let aoTopCenter = 1.0'f32

  let sideBase = uint32(verts.len)
  for i in 0 ..< segs:
    let theta = float32(TAU) * float32(i) / float32(segs)
    let cx = float32(cos(theta))
    let cy = float32(sin(theta))
    let n = [cx, cy, 0'f32]
    var vTop = SceneVertex(pos: [cx * r, cy * r, h], nrm: n)
    setAo(vTop, aoSideMid)
    var vBot = SceneVertex(pos: [cx * r, cy * r, 0'f32], nrm: n)
    setAo(vBot, aoSideBot)
    verts.add vTop
    verts.add vBot
  for i in 0 ..< segs:
    let i0 = sideBase + uint32(i * 2)
    let i1 = sideBase + uint32(i * 2 + 1)
    let j0 = sideBase + uint32(((i + 1) mod segs) * 2)
    let j1 = sideBase + uint32(((i + 1) mod segs) * 2 + 1)
    idx.add i1; idx.add j1; idx.add j0
    idx.add i1; idx.add j0; idx.add i0

  let topBase = uint32(verts.len)
  var center = SceneVertex(pos: [0'f32, 0'f32, h], nrm: [0'f32, 0'f32, 1'f32])
  setAo(center, aoTopCenter)
  verts.add center
  for i in 0 ..< segs:
    let theta = float32(TAU) * float32(i) / float32(segs)
    let cx = float32(cos(theta))
    let cy = float32(sin(theta))
    var v = SceneVertex(pos: [cx * r, cy * r, h],
                        nrm: [0'f32, 0'f32, 1'f32])
    setAo(v, aoRimTop)
    verts.add v
  for i in 0 ..< segs:
    let a = topBase + 1 + uint32(i)
    let b = topBase + 1 + uint32((i + 1) mod segs)
    idx.add topBase; idx.add a; idx.add b

  (verts, idx)

proc uploadMesh(dev: ptr SDL_GPUDevice;
                verts: seq[SceneVertex]; idx: seq[uint32]): Mesh =
  result.vbuf       = uploadVertexBuffer(dev, verts)
  result.ibuf       = uploadIndexBufferU32(dev, idx)
  result.indexCount = uint32(idx.len)

proc create1x1WhiteTexture(dev: ptr SDL_GPUDevice): ptr SDL_GPUTexture =
  result = createSampler2D(dev, 1, 1)
  var px: array[4, uint8] = [255'u8, 255'u8, 255'u8, 255'u8]
  uploadRgba(dev, result, addr px[0], 1, 1, 1)

proc createTextureSampler(dev: ptr SDL_GPUDevice): ptr SDL_GPUSampler =
  ## Linear filter, repeat — works for car texture atlases (glTF baked the
  ## per-subsection UV transform into TEXCOORD_0 already, but a few sample
  ## paths still want wrap behaviour at edges).
  var info: SDL_GPUSamplerCreateInfo
  info.min_filter     = SDL_GPU_FILTER_LINEAR
  info.mag_filter     = SDL_GPU_FILTER_LINEAR
  info.mipmap_mode    = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST
  info.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_REPEAT
  info.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_REPEAT
  info.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_REPEAT
  result = SDL_CreateGPUSampler(dev, addr info)
  if result == nil:
    die("SDL_CreateGPUSampler(scene)")

proc loadPngTexture(dev: ptr SDL_GPUDevice; path: string): ptr SDL_GPUTexture =
  ## Decode a PNG via stb_image and upload as RGBA8. Returns nil on failure.
  if not fileExists(path): return nil
  var data = readFile(path)
  if data.len == 0: return nil
  var w, h, ch: cint
  let pixels = stbi_load_from_memory(unsafeAddr data[0], cint(data.len),
                                     addr w, addr h, addr ch, 4)
  if pixels == nil: return nil
  defer: stbi_image_free(pixels)
  result = createSampler2D(dev, uint32(w), uint32(h))
  uploadRgba(dev, result, pixels, uint32(w), uint32(h), uint32(w))

proc createPipelines(dev: ptr SDL_GPUDevice;
                     swapFormat: SDL_GPUTextureFormat):
                     tuple[opaque, transparent: ptr SDL_GPUGraphicsPipeline] =
  ## Two pipelines sharing the scene shader: opaque (depth-write on,
  ## no blend) and transparent (depth-test on but no write, SRC_ALPHA /
  ## 1-SRC_ALPHA blend). Inlined per pipeline so each gets its own
  ## SDL_GPUColorTargetDescription with the right address embedded —
  ## a closure capturing a `var` parameter would obscure that lifetime.
  let vsh = loadShaderBytes(dev, SceneVertSpv, SDL_GPU_SHADERSTAGE_VERTEX,
                            numUniforms = 1, tag = "scene.vert")
  let fsh = loadShaderBytes(dev, SceneFragSpv, SDL_GPU_SHADERSTAGE_FRAGMENT,
                            numUniforms = 2, numSamplers = 1, tag = "scene.frag")

  var vbDesc: SDL_GPUVertexBufferDescription
  vbDesc.slot       = 0
  vbDesc.pitch      = SceneVertexStride
  vbDesc.input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX

  var attrs: array[4, SDL_GPUVertexAttribute]
  attrs[0].location = 0
  attrs[0].format   = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3
  attrs[0].offset   = 0
  attrs[1].location = 1
  attrs[1].format   = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3
  attrs[1].offset   = 12
  attrs[2].location = 2
  attrs[2].format   = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2
  attrs[2].offset   = 24
  attrs[3].location = 3
  attrs[3].format   = SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM
  attrs[3].offset   = 32

  # ── Opaque ────────────────────────────────────────────────────────────
  var opaqueColor: SDL_GPUColorTargetDescription
  opaqueColor.format = swapFormat

  var opaqueInfo: SDL_GPUGraphicsPipelineCreateInfo
  opaqueInfo.vertex_shader   = vsh
  opaqueInfo.fragment_shader = fsh
  opaqueInfo.primitive_type  = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST
  opaqueInfo.vertex_input_state.vertex_buffer_descriptions = addr vbDesc
  opaqueInfo.vertex_input_state.num_vertex_buffers         = 1
  opaqueInfo.vertex_input_state.vertex_attributes          = addr attrs[0]
  opaqueInfo.vertex_input_state.num_vertex_attributes      = 4
  opaqueInfo.rasterizer_state.fill_mode  = SDL_GPU_FILLMODE_FILL
  opaqueInfo.rasterizer_state.cull_mode  = SDL_GPU_CULLMODE_NONE
  opaqueInfo.rasterizer_state.front_face = SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE
  opaqueInfo.multisample_state.sample_count        = SDL_GPU_SAMPLECOUNT_1
  opaqueInfo.depth_stencil_state.compare_op        = SDL_GPU_COMPAREOP_LESS
  opaqueInfo.depth_stencil_state.enable_depth_test = true
  opaqueInfo.depth_stencil_state.enable_depth_write = true
  opaqueInfo.target_info.num_color_targets         = 1
  opaqueInfo.target_info.color_target_descriptions = addr opaqueColor
  opaqueInfo.target_info.has_depth_stencil_target  = true
  opaqueInfo.target_info.depth_stencil_format      = SDL_GPU_TEXTUREFORMAT_D32_FLOAT

  result.opaque = SDL_CreateGPUGraphicsPipeline(dev, addr opaqueInfo)
  if result.opaque == nil:
    die("SDL_CreateGPUGraphicsPipeline(scene-opaque)")

  # ── Transparent ───────────────────────────────────────────────────────
  var blendColor: SDL_GPUColorTargetDescription
  blendColor.format = swapFormat
  blendColor.blend_state.enable_blend          = true
  blendColor.blend_state.src_color_blendfactor = SDL_GPU_BLENDFACTOR_SRC_ALPHA
  blendColor.blend_state.dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA
  blendColor.blend_state.color_blend_op        = SDL_GPU_BLENDOP_ADD
  blendColor.blend_state.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE
  blendColor.blend_state.dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA
  blendColor.blend_state.alpha_blend_op        = SDL_GPU_BLENDOP_ADD

  var transInfo: SDL_GPUGraphicsPipelineCreateInfo
  transInfo.vertex_shader   = vsh
  transInfo.fragment_shader = fsh
  transInfo.primitive_type  = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST
  transInfo.vertex_input_state.vertex_buffer_descriptions = addr vbDesc
  transInfo.vertex_input_state.num_vertex_buffers         = 1
  transInfo.vertex_input_state.vertex_attributes          = addr attrs[0]
  transInfo.vertex_input_state.num_vertex_attributes      = 4
  transInfo.rasterizer_state.fill_mode  = SDL_GPU_FILLMODE_FILL
  transInfo.rasterizer_state.cull_mode  = SDL_GPU_CULLMODE_NONE
  transInfo.rasterizer_state.front_face = SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE
  transInfo.multisample_state.sample_count        = SDL_GPU_SAMPLECOUNT_1
  transInfo.depth_stencil_state.compare_op        = SDL_GPU_COMPAREOP_LESS
  transInfo.depth_stencil_state.enable_depth_test = true
  transInfo.depth_stencil_state.enable_depth_write = false
  transInfo.target_info.num_color_targets         = 1
  transInfo.target_info.color_target_descriptions = addr blendColor
  transInfo.target_info.has_depth_stencil_target  = true
  transInfo.target_info.depth_stencil_format      = SDL_GPU_TEXTUREFORMAT_D32_FLOAT

  result.transparent = SDL_CreateGPUGraphicsPipeline(dev, addr transInfo)
  if result.transparent == nil:
    die("SDL_CreateGPUGraphicsPipeline(scene-transparent)")

  SDL_ReleaseGPUShader(dev, vsh)
  SDL_ReleaseGPUShader(dev, fsh)

proc init*(dev: ptr SDL_GPUDevice;
           win: ptr SDL_Window): Scene3D =
  let pipes = createPipelines(dev, SDL_GetGPUSwapchainTextureFormat(dev, win))
  result.pipelineOpaque      = pipes.opaque
  result.pipelineTransparent = pipes.transparent

  let (rv, ri) = buildRoomMesh()
  result.room = uploadMesh(dev, rv, ri)

  let (pv, pi) = buildPedestalMesh()
  result.pedestal = uploadMesh(dev, pv, pi)

  result.whiteTex = create1x1WhiteTexture(dev)
  result.sampler  = createTextureSampler(dev)

  result.camera = newOrbitCamera(focus = [0.0'f32, 0.0'f32, 1.0'f32],
                                 distance = 7.0'f32,
                                 yaw = PI * 0.25'f32,
                                 pitch = -0.20'f32)

proc releaseMesh(dev: ptr SDL_GPUDevice; m: var Mesh) =
  if m.vbuf != nil: SDL_ReleaseGPUBuffer(dev, m.vbuf); m.vbuf = nil
  if m.ibuf != nil: SDL_ReleaseGPUBuffer(dev, m.ibuf); m.ibuf = nil
  m.indexCount = 0

proc releaseCarTextures(dev: ptr SDL_GPUDevice; scene: var Scene3D) =
  for t in scene.carTextures:
    if t != nil: SDL_ReleaseGPUTexture(dev, t)
  scene.carTextures.setLen(0)

proc release*(dev: ptr SDL_GPUDevice; scene: var Scene3D) =
  releaseMesh(dev, scene.room)
  releaseMesh(dev, scene.pedestal)
  releaseMesh(dev, scene.car)
  releaseCarTextures(dev, scene)
  scene.carParts.setLen(0)
  scene.carLoaded = false
  if scene.whiteTex != nil:
    SDL_ReleaseGPUTexture(dev, scene.whiteTex); scene.whiteTex = nil
  if scene.sampler != nil:
    SDL_ReleaseGPUSampler(dev, scene.sampler); scene.sampler = nil
  if scene.depthTex != nil:
    SDL_ReleaseGPUTexture(dev, scene.depthTex); scene.depthTex = nil
  if scene.pipelineOpaque != nil:
    SDL_ReleaseGPUGraphicsPipeline(dev, scene.pipelineOpaque); scene.pipelineOpaque = nil
  if scene.pipelineTransparent != nil:
    SDL_ReleaseGPUGraphicsPipeline(dev, scene.pipelineTransparent); scene.pipelineTransparent = nil

proc unloadCar*(scene: var Scene3D; dev: ptr SDL_GPUDevice) =
  ## Drop GPU resources for the current car so the pedestal renders empty.
  if scene.car.vbuf != nil: releaseMesh(dev, scene.car)
  releaseCarTextures(dev, scene)
  scene.carParts.setLen(0)
  scene.carLoaded = false

proc loadCar*(scene: var Scene3D; dev: ptr SDL_GPUDevice; gltfPath: string): bool {.discardable.} =
  ## Replace any currently-loaded car. Returns true on success; false if
  ## the glTF parsed but had no usable geometry. Raises CatchableError on
  ## parse / IO problems.
  if scene.car.vbuf != nil: releaseMesh(dev, scene.car)
  releaseCarTextures(dev, scene)
  scene.carParts.setLen(0)
  scene.carLoaded = false

  let raw = loadMainCarMesh(gltfPath, ExteriorLodKinds, CarBodyLift, WheelInsetX)
  if raw.indices.len == 0:
    stderr.writeLine &"loadCar: no usable geometry in {gltfPath}"
    return false

  let cx = (raw.bbMin[0] + raw.bbMax[0]) * 0.5'f32
  let cy = (raw.bbMin[1] + raw.bbMax[1]) * 0.5'f32
  let lift = PedestalHeight - raw.bbMin[2]

  let vCount = raw.pos.len div 3
  var verts = newSeqOfCap[SceneVertex](vCount)
  for i in 0 ..< vCount:
    var v = SceneVertex(
      pos: [raw.pos[i*3]     - cx,
            raw.pos[i*3 + 1] - cy,
            raw.pos[i*3 + 2] + lift],
      nrm: [raw.normal[i*3], raw.normal[i*3 + 1], raw.normal[i*3 + 2]],
      u:   raw.uv[i*2],
      v:   raw.uv[i*2 + 1])
    setAo(v, 1.0'f32)
    verts.add v

  scene.car = uploadMesh(dev, verts, raw.indices)

  # Decode + upload each unique referenced PNG once, then resolve each
  # submesh's texture pointer (defaulting to the white 1×1 for untextured
  # or missing-on-disk materials).
  let baseDir = parentDir(gltfPath)
  var texCache = initTable[string, ptr SDL_GPUTexture]()
  for sm in raw.submeshes:
    if sm.imageUri.len == 0: continue
    if texCache.hasKey(sm.imageUri): continue
    let tex = loadPngTexture(dev, baseDir / sm.imageUri)
    if tex != nil:
      scene.carTextures.add tex
      texCache[sm.imageUri] = tex
    else:
      stderr.writeLine &"loadCar: missing or unreadable texture {sm.imageUri}"

  scene.carParts.setLen(0)
  for sm in raw.submeshes:
    var tex = scene.whiteTex
    if sm.imageUri.len > 0 and texCache.hasKey(sm.imageUri):
      tex = texCache[sm.imageUri]
    # Map glTF metallic/roughness to fake Phong:
    #   shininess  rises sharply as roughness drops (smoother → tighter highlight)
    #   strength   weights metallics heavily, with a floor for non-metals
    let smoothness  = (1.0'f32 - sm.roughness)
    let shininess   = 6.0'f32 + 220.0'f32 * smoothness * smoothness
    # Exaggerated for a showroom look — clamp >1 lets metallics over-brighten.
    let strength    = clamp(0.20'f32 + 1.10'f32 * sm.metallic +
                            0.55'f32 * smoothness, 0.0'f32, 1.8'f32)
    scene.carParts.add CarPart(
      indexOffset:  sm.indexOffset,
      indexCount:   sm.indexCount,
      baseColor:    sm.baseColor,
      shininess:    shininess,
      specStrength: strength,
      texture:      tex,
      transparent:  sm.baseColor[3] < 0.999'f32)

  scene.carLoaded = true
  var transCount = 0
  for p in scene.carParts:
    if p.transparent: inc transCount
  stderr.writeLine &"loadCar: {vCount} verts, {raw.indices.len div 3} tris, " &
    &"{scene.carParts.len} submeshes ({transCount} transparent, " &
    &"{scene.carTextures.len} textures) " &
    &"world bbox = ({raw.bbMin[0]:.2f},{raw.bbMin[1]:.2f},{raw.bbMin[2]:.2f}) " &
    &"→ ({raw.bbMax[0]:.2f},{raw.bbMax[1]:.2f},{raw.bbMax[2]:.2f})"
  for p in scene.carParts:
    if p.transparent:
      stderr.writeLine &"  transparent submesh: rgba=({p.baseColor[0]:.2f}," &
        &"{p.baseColor[1]:.2f},{p.baseColor[2]:.2f},{p.baseColor[3]:.2f}) " &
        &"indices={p.indexCount}"
  return true

proc ensureDepthTexture(dev: ptr SDL_GPUDevice; scene: var Scene3D;
                        w, h: uint32) =
  if scene.depthTex != nil and scene.depthW == w and scene.depthH == h:
    return
  if scene.depthTex != nil:
    SDL_ReleaseGPUTexture(dev, scene.depthTex)
  scene.depthTex = createDepthTexture(dev, w, h)
  scene.depthW   = w
  scene.depthH   = h

# ─── input ────────────────────────────────────────────────────────────────

proc handleMouseInput*(scene: var Scene3D;
                       dx, dy: float32;
                       rmb, mmb, rmbPrev, mmbPrev: bool;
                       wheelY: float32;
                       blocked: bool) =
  if rmb and not rmbPrev and not blocked: scene.rmbDragging = true
  if not rmb: scene.rmbDragging = false
  if mmb and not mmbPrev and not blocked: scene.mmbDragging = true
  if not mmb: scene.mmbDragging = false
  if scene.rmbDragging: scene.camera.orbitRotate(dx, dy)
  if scene.mmbDragging: scene.camera.orbitPan(dx, dy)
  if wheelY != 0 and not blocked:
    scene.camera.orbitZoom(wheelY)
  const MaxDist  = 7.2'f32
  const MinDist  = 1.8'f32
  const MinPitch = -1.30'f32
  const MaxPitch =  0.0'f32
  if scene.camera.distance > MaxDist:  scene.camera.distance = MaxDist
  if scene.camera.distance < MinDist:  scene.camera.distance = MinDist
  if scene.camera.pitch    > MaxPitch: scene.camera.pitch    = MaxPitch
  if scene.camera.pitch    < MinPitch: scene.camera.pitch    = MinPitch

# ─── per-frame draw ───────────────────────────────────────────────────────

proc viewProjScene(c: OrbitCamera; aspect: float32): Mat4 =
  let eye  = c.position()
  let view = mat4LookAt(eye, c.focus, [0.0'f32, 0.0'f32, 1.0'f32])
  let proj = mat4Perspective(50.0'f32 * float32(PI) / 180.0'f32,
                             aspect, 0.05'f32, 200.0'f32)
  mat4Mul(proj, view)

proc roomMaterial(): MaterialUbo =
  result.baseColor    = [RoomColor[0], RoomColor[1], RoomColor[2], 1.0]
  result.boxParams    = [RoomHalfX, RoomHalfY, RoomHalfZ, RoomCornerFalloff]
  result.boxCenter    = [0.0'f32, 0.0'f32, RoomCenterZ, RoomCornerStrength]
  result.contactDisc  = [0.0'f32, 0.0'f32, FloorRingInner, FloorRingOuter]
  result.contactExtra = [0.0'f32, FloorRingStrength, TopNormalThreshold, 0.0]
  result.specParams   = [1.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]   # spec off

proc pedestalMaterial(): MaterialUbo =
  result.baseColor    = [PedestalColor[0], PedestalColor[1], PedestalColor[2], 1.0]
  result.boxParams    = [0.0'f32, 0.0'f32, 0.0'f32, 1.0'f32]
  result.boxCenter    = [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]
  result.contactDisc  = [0.0'f32, 0.0'f32,
                         PedestalContactInner, PedestalContactOuter]
  result.contactExtra = [PedestalHeight, PedestalContactStrength,
                         TopNormalThreshold, 0.0]
  result.specParams   = [1.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]   # spec off

proc carPartMaterial(part: CarPart): MaterialUbo =
  result.baseColor    = part.baseColor
  result.boxParams    = [0.0'f32, 0.0'f32, 0.0'f32, 1.0'f32]
  result.boxCenter    = [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]
  result.contactDisc  = [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]
  result.contactExtra = [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]
  result.specParams   = [part.shininess, part.specStrength, 0.0'f32, 0.0'f32]

proc buildLighting(c: OrbitCamera): LightingUbo =
  let eye = c.position()
  result.eyeWorld  = [eye[0], eye[1], eye[2], 0.0'f32]
  # Two world-space lights — front-right-above key + back-left-side fill —
  # so as the camera orbits at least one always lights whichever side of
  # the body is facing it. Both directions roughly normalised.
  result.keyDir    = [ 0.55'f32, -0.40'f32,  0.73'f32, 0.0'f32]
  result.keyColor  = [ 1.6'f32,   1.55'f32,  1.45'f32, 0.0'f32]   # bright warm
  result.fillDir   = [-0.65'f32,  0.55'f32,  0.52'f32, 0.0'f32]
  result.fillColor = [ 0.85'f32,  0.90'f32,  1.05'f32, 0.0'f32]   # cool fill

proc render*(scene: var Scene3D;
             dev: ptr SDL_GPUDevice;
             cmd: ptr SDL_GPUCommandBuffer;
             swapTex: ptr SDL_GPUTexture;
             swapW, swapH: uint32) =
  ensureDepthTexture(dev, scene, swapW, swapH)

  var colorTarget: SDL_GPUColorTargetInfo
  colorTarget.texture     = swapTex
  colorTarget.clear_color = SDL_FColor(r: RoomColor[0], g: RoomColor[1],
                                       b: RoomColor[2], a: 1.0)
  colorTarget.load_op     = SDL_GPU_LOADOP_CLEAR
  colorTarget.store_op    = SDL_GPU_STOREOP_STORE

  var depthTarget: SDL_GPUDepthStencilTargetInfo
  depthTarget.texture          = scene.depthTex
  depthTarget.clear_depth      = 1.0
  depthTarget.load_op          = SDL_GPU_LOADOP_CLEAR
  depthTarget.store_op         = SDL_GPU_STOREOP_DONT_CARE
  depthTarget.stencil_load_op  = SDL_GPU_LOADOP_CLEAR
  depthTarget.stencil_store_op = SDL_GPU_STOREOP_DONT_CARE

  let rp = SDL_BeginGPURenderPass(cmd, addr colorTarget, 1, addr depthTarget)

  let aspect = float32(swapW) / float32(swapH)
  var globals = GlobalsUbo(mvp: viewProjScene(scene.camera, aspect))
  SDL_PushGPUVertexUniformData(cmd, 0, addr globals, uint32(sizeof(globals)))

  var lighting = buildLighting(scene.camera)
  SDL_PushGPUFragmentUniformData(cmd, 1, addr lighting, uint32(sizeof(LightingUbo)))

  template bindTex(texArg: ptr SDL_GPUTexture; samplerArg: ptr SDL_GPUSampler) =
    var bindingT: SDL_GPUTextureSamplerBinding
    bindingT.texture = texArg
    bindingT.sampler = samplerArg
    SDL_BindGPUFragmentSamplers(rp, 0, addr bindingT, 1)

  template pushMaterial(matArg: MaterialUbo) =
    var mcT = matArg
    SDL_PushGPUFragmentUniformData(cmd, 0, addr mcT, uint32(sizeof(MaterialUbo)))

  template bindMesh(m: Mesh) =
    var vbT: SDL_GPUBufferBinding
    vbT.buffer = m.vbuf
    SDL_BindGPUVertexBuffers(rp, 0, addr vbT, 1)
    var ibT: SDL_GPUBufferBinding
    ibT.buffer = m.ibuf
    SDL_BindGPUIndexBuffer(rp, addr ibT, SDL_GPU_INDEXELEMENTSIZE_32BIT)

  # ── Opaque pass: room, pedestal, opaque car submeshes ────────────────
  SDL_BindGPUGraphicsPipeline(rp, scene.pipelineOpaque)

  bindMesh(scene.room)
  pushMaterial(roomMaterial())
  bindTex(scene.whiteTex, scene.sampler)
  SDL_DrawGPUIndexedPrimitives(rp, scene.room.indexCount, 1, 0, 0, 0)

  bindMesh(scene.pedestal)
  pushMaterial(pedestalMaterial())
  bindTex(scene.whiteTex, scene.sampler)
  SDL_DrawGPUIndexedPrimitives(rp, scene.pedestal.indexCount, 1, 0, 0, 0)

  if scene.carLoaded:
    bindMesh(scene.car)
    for part in scene.carParts:
      if part.transparent: continue
      pushMaterial(carPartMaterial(part))
      bindTex(part.texture, scene.sampler)
      SDL_DrawGPUIndexedPrimitives(rp, part.indexCount, 1, part.indexOffset, 0, 0)

  # ── Transparent pass: glass, decals — depth-test on, depth-write off ──
  if scene.carLoaded:
    var anyTransparent = false
    for part in scene.carParts:
      if part.transparent: anyTransparent = true; break
    if anyTransparent:
      SDL_BindGPUGraphicsPipeline(rp, scene.pipelineTransparent)
      bindMesh(scene.car)
      for part in scene.carParts:
        if not part.transparent: continue
        pushMaterial(carPartMaterial(part))
        bindTex(part.texture, scene.sampler)
        SDL_DrawGPUIndexedPrimitives(rp, part.indexCount, 1, part.indexOffset, 0, 0)

  SDL_EndGPURenderPass(rp)
