## gfx.nim — shared SDL3 GPU helpers used by every renderer binary.
##
## Generic buffer/texture upload, shader loading, depth texture and sampler
## creation. No game- or tool-specific types live here.

import std/[os, strformat]
import platform/sdl3

proc die*(msg: string) {.noreturn.} =
  echo &"fatal: {msg}: {SDL_GetError()}"
  quit(1)

proc readBinaryFile*(path: string): string =
  if not fileExists(path):
    die("missing file " & path)
  result = readFile(path)

proc loadShaderBytes*(dev: ptr SDL_GPUDevice;
                      spv: string;
                      stage: SDL_GPUShaderStage;
                      numUniforms: uint32 = 0;
                      numSamplers: uint32 = 0;
                      tag: string = "bytes"): ptr SDL_GPUShader =
  var info: SDL_GPUShaderCreateInfo
  info.code_size  = csize_t(spv.len)
  info.code       = cast[ptr uint8](spv[0].unsafeAddr)
  info.entrypoint = "main"
  info.format     = SDL_GPU_SHADERFORMAT_SPIRV
  info.stage      = stage
  info.num_uniform_buffers = numUniforms
  info.num_samplers        = numSamplers
  result = SDL_CreateGPUShader(dev, addr info)
  if result == nil:
    die("SDL_CreateGPUShader(" & tag & ")")

proc loadShader*(dev: ptr SDL_GPUDevice;
                 spvPath: string;
                 stage: SDL_GPUShaderStage;
                 numUniforms: uint32 = 0;
                 numSamplers: uint32 = 0): ptr SDL_GPUShader =
  loadShaderBytes(dev, readBinaryFile(spvPath),
                  stage, numUniforms, numSamplers, spvPath)

proc uploadBuffer*(dev: ptr SDL_GPUDevice;
                   src: pointer; byteSize: uint32;
                   usage: SDL_GPUBufferUsageFlags;
                   tag: string): ptr SDL_GPUBuffer =
  var bufInfo: SDL_GPUBufferCreateInfo
  bufInfo.usage = usage
  bufInfo.size  = byteSize
  result = SDL_CreateGPUBuffer(dev, addr bufInfo)
  if result == nil:
    die("SDL_CreateGPUBuffer(" & tag & ")")

  var tbInfo: SDL_GPUTransferBufferCreateInfo
  tbInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
  tbInfo.size  = byteSize
  let transfer = SDL_CreateGPUTransferBuffer(dev, addr tbInfo)
  if transfer == nil:
    die("SDL_CreateGPUTransferBuffer(" & tag & ")")

  let mapped = SDL_MapGPUTransferBuffer(dev, transfer, false)
  if mapped == nil:
    die("SDL_MapGPUTransferBuffer(" & tag & ")")
  copyMem(mapped, src, int(byteSize))
  SDL_UnmapGPUTransferBuffer(dev, transfer)

  let cmd = SDL_AcquireGPUCommandBuffer(dev)
  let copyPass = SDL_BeginGPUCopyPass(cmd)
  var tbLoc: SDL_GPUTransferBufferLocation
  tbLoc.transfer_buffer = transfer
  tbLoc.offset = 0
  var dst: SDL_GPUBufferRegion
  dst.buffer = result
  dst.offset = 0
  dst.size   = byteSize
  SDL_UploadToGPUBuffer(copyPass, addr tbLoc, addr dst, false)
  SDL_EndGPUCopyPass(copyPass)
  discard SDL_SubmitGPUCommandBuffer(cmd)
  SDL_ReleaseGPUTransferBuffer(dev, transfer)

proc uploadVertexBuffer*[T](dev: ptr SDL_GPUDevice;
                            data: seq[T]): ptr SDL_GPUBuffer =
  let byteSize = uint32(data.len * sizeof(T))
  uploadBuffer(dev, data[0].unsafeAddr, byteSize,
               SDL_GPU_BUFFERUSAGE_VERTEX, "vertex")

proc uploadIndexBufferU32*(dev: ptr SDL_GPUDevice;
                           data: seq[uint32]): ptr SDL_GPUBuffer =
  let byteSize = uint32(data.len * sizeof(uint32))
  uploadBuffer(dev, data[0].unsafeAddr, byteSize,
               SDL_GPU_BUFFERUSAGE_INDEX, "index")

proc uploadIndexBufferU16*(dev: ptr SDL_GPUDevice;
                           data: seq[uint16]): ptr SDL_GPUBuffer =
  let byteSize = uint32(data.len * sizeof(uint16))
  uploadBuffer(dev, data[0].unsafeAddr, byteSize,
               SDL_GPU_BUFFERUSAGE_INDEX, "index")

proc createSampler2D*(dev: ptr SDL_GPUDevice;
                      w, h: uint32): ptr SDL_GPUTexture =
  ## RGBA8 sampler texture, sized `w × h`. Pair with `uploadRgba` to
  ## populate. Used for both file-decoded textures and tiny CPU-built ones.
  var info: SDL_GPUTextureCreateInfo
  info.`type`               = SDL_GPU_TEXTURETYPE_2D
  info.format               = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
  info.usage                = SDL_GPU_TEXTUREUSAGE_SAMPLER
  info.width                = w
  info.height               = h
  info.layer_count_or_depth = 1
  info.num_levels           = 1
  info.sample_count         = SDL_GPU_SAMPLECOUNT_1
  result = SDL_CreateGPUTexture(dev, addr info)
  if result == nil:
    die("SDL_CreateGPUTexture(rgba)")

proc uploadRgba*(dev: ptr SDL_GPUDevice;
                 tex: ptr SDL_GPUTexture;
                 pixels: pointer;
                 w, h: uint32;
                 pixelsPerRow: uint32) =
  ## One-shot copy-pass upload of an RGBA8 pixel buffer to `tex`.
  let byteSize = pixelsPerRow * h * 4
  var tbInfo: SDL_GPUTransferBufferCreateInfo
  tbInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
  tbInfo.size  = byteSize
  let transfer = SDL_CreateGPUTransferBuffer(dev, addr tbInfo)
  if transfer == nil:
    die("SDL_CreateGPUTransferBuffer(tex)")

  let mapped = SDL_MapGPUTransferBuffer(dev, transfer, false)
  if mapped == nil:
    die("SDL_MapGPUTransferBuffer(tex)")
  copyMem(mapped, pixels, int(byteSize))
  SDL_UnmapGPUTransferBuffer(dev, transfer)

  let cmd = SDL_AcquireGPUCommandBuffer(dev)
  let cp  = SDL_BeginGPUCopyPass(cmd)
  var src: SDL_GPUTextureTransferInfo
  src.transfer_buffer = transfer
  src.offset          = 0
  src.pixels_per_row  = pixelsPerRow
  src.rows_per_layer  = h
  var dst: SDL_GPUTextureRegion
  dst.texture   = tex
  dst.mip_level = 0
  dst.layer     = 0
  dst.x = 0; dst.y = 0; dst.z = 0
  dst.w = w; dst.h = h; dst.d = 1
  SDL_UploadToGPUTexture(cp, addr src, addr dst, false)
  SDL_EndGPUCopyPass(cp)
  discard SDL_SubmitGPUCommandBuffer(cmd)
  SDL_ReleaseGPUTransferBuffer(dev, transfer)

proc createDepthTexture*(dev: ptr SDL_GPUDevice;
                         w, h: uint32): ptr SDL_GPUTexture =
  var info: SDL_GPUTextureCreateInfo
  info.`type`               = SDL_GPU_TEXTURETYPE_2D
  info.format               = SDL_GPU_TEXTUREFORMAT_D32_FLOAT
  info.usage                = SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET
  info.width                = w
  info.height               = h
  info.layer_count_or_depth = 1
  info.num_levels           = 1
  info.sample_count         = SDL_GPU_SAMPLECOUNT_1
  result = SDL_CreateGPUTexture(dev, addr info)
  if result == nil:
    die("SDL_CreateGPUTexture(depth)")

proc createLinearClampSampler*(dev: ptr SDL_GPUDevice): ptr SDL_GPUSampler =
  ## Linear filter, clamp-to-edge — used for UI text glyph atlases.
  var info: SDL_GPUSamplerCreateInfo
  info.min_filter     = SDL_GPU_FILTER_LINEAR
  info.mag_filter     = SDL_GPU_FILTER_LINEAR
  info.mipmap_mode    = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST
  info.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE
  info.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE
  info.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE
  result = SDL_CreateGPUSampler(dev, addr info)
  if result == nil:
    die("SDL_CreateGPUSampler(linear-clamp)")

proc createNearestRepeatSampler*(dev: ptr SDL_GPUDevice): ptr SDL_GPUSampler =
  ## Nearest filter, wrap-repeat — used for tiled procedural level textures.
  var info: SDL_GPUSamplerCreateInfo
  info.min_filter     = SDL_GPU_FILTER_NEAREST
  info.mag_filter     = SDL_GPU_FILTER_NEAREST
  info.mipmap_mode    = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST
  info.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_REPEAT
  info.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_REPEAT
  info.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_REPEAT
  result = SDL_CreateGPUSampler(dev, addr info)
  if result == nil:
    die("SDL_CreateGPUSampler(nearest-repeat)")
