## text.nim — SDL3_ttf + GPU text texture helpers.
##
## Rasterizes a UTF-8 string into a one-off R8G8B8A8 SDL_GPUTexture via
## SDL3_ttf. Both the game HUD and leveledit's map-picker use this.

import platform/sdl3
import ./gfx

type
  TextTexture* = object
    tex*: ptr SDL_GPUTexture
    width*, height*: uint32

proc releaseTextTexture*(dev: ptr SDL_GPUDevice; tt: var TextTexture) =
  if tt.tex != nil:
    SDL_ReleaseGPUTexture(dev, tt.tex)
    tt.tex = nil
    tt.width = 0
    tt.height = 0

proc buildTextTexture*(dev: ptr SDL_GPUDevice;
                       font: ptr TTF_Font;
                       text: string): TextTexture =
  ## Rasterizes `text` via SDL3_ttf and uploads as an R8G8B8A8 texture.
  let fg = SDL_Color(r: 255, g: 255, b: 255, a: 255)
  let surf = TTF_RenderText_Blended(font, text.cstring, csize_t(text.len), fg)
  if surf == nil:
    die("TTF_RenderText_Blended")

  let rgba = SDL_ConvertSurface(surf, SDL_PIXELFORMAT_ABGR8888)
  SDL_DestroySurface(surf)
  if rgba == nil:
    die("SDL_ConvertSurface(text)")

  let w = uint32(rgba.w)
  let h = uint32(rgba.h)
  let pitch = uint32(rgba.pitch)
  let pixelsPerRow = pitch div 4
  let byteSize = pitch * h

  var texInfo: SDL_GPUTextureCreateInfo
  texInfo.`type`               = SDL_GPU_TEXTURETYPE_2D
  texInfo.format               = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
  texInfo.usage                = SDL_GPU_TEXTUREUSAGE_SAMPLER
  texInfo.width                = w
  texInfo.height               = h
  texInfo.layer_count_or_depth = 1
  texInfo.num_levels           = 1
  texInfo.sample_count         = SDL_GPU_SAMPLECOUNT_1
  let tex = SDL_CreateGPUTexture(dev, addr texInfo)
  if tex == nil:
    die("SDL_CreateGPUTexture(text)")

  var tbInfo: SDL_GPUTransferBufferCreateInfo
  tbInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
  tbInfo.size  = byteSize
  let transfer = SDL_CreateGPUTransferBuffer(dev, addr tbInfo)
  if transfer == nil:
    die("SDL_CreateGPUTransferBuffer(text)")

  let mapped = SDL_MapGPUTransferBuffer(dev, transfer, false)
  if mapped == nil:
    die("SDL_MapGPUTransferBuffer(text)")
  copyMem(mapped, rgba.pixels, int(byteSize))
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

  SDL_DestroySurface(rgba)
  result = TextTexture(tex: tex, width: w, height: h)

proc openFontFromBytes*(bytes: var string; ptSize: float32): ptr TTF_Font =
  ## SDL3_ttf retains a pointer into `bytes` via the IOStream, so the caller
  ## must keep `bytes` alive for as long as the returned font.
  let io = SDL_IOFromConstMem(addr bytes[0], csize_t(bytes.len))
  if io == nil:
    die("SDL_IOFromConstMem(font)")
  result = TTF_OpenFontIO(io, true, ptSize)
  if result == nil:
    die("TTF_OpenFontIO")
