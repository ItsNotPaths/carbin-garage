## Pipeline construction + per-frame draw-list submission for the UI layer.
##
## The three UI shaders (`ui_solid`, `ui_text`, `ui_circle` in shaders/) share
## a vertex layout (none — each shader synthesizes 6 corner positions from
## `gl_VertexIndex`). All draws are 6-vertex calls; per-quad data goes through
## SDL_PushGPU(Vertex|Fragment)UniformData. A single render pass walks the
## ctx.draw command list, switching the bound pipeline only when the command
## kind changes.

import ../../render/platform/sdl3
import ../../render/gfx
import context

const
  UiSolidVertSpv  = staticRead("../../../shaders/ui_solid.vert.spv")
  UiSolidFragSpv  = staticRead("../../../shaders/ui_solid.frag.spv")
  UiTextVertSpv   = staticRead("../../../shaders/ui_text.vert.spv")
  UiTextFragSpv   = staticRead("../../../shaders/ui_text.frag.spv")
  UiCircleVertSpv = staticRead("../../../shaders/ui_circle.vert.spv")
  UiCircleFragSpv = staticRead("../../../shaders/ui_circle.frag.spv")

type
  RectUbo {.packed.} = object
    x, y, w, h: float32

  ColorUbo {.packed.} = object
    r, g, b, a: float32

  UiPipelines* = object
    solid*, text*, circle*: ptr SDL_GPUGraphicsPipeline
    fontSampler*: ptr SDL_GPUSampler

proc makeAlphaBlendTargetDesc(swapFormat: SDL_GPUTextureFormat):
    SDL_GPUColorTargetDescription =
  result.format = swapFormat
  result.blend_state.enable_blend          = true
  result.blend_state.src_color_blendfactor = SDL_GPU_BLENDFACTOR_SRC_ALPHA
  result.blend_state.dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA
  result.blend_state.color_blend_op        = SDL_GPU_BLENDOP_ADD
  result.blend_state.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE
  result.blend_state.dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA
  result.blend_state.alpha_blend_op        = SDL_GPU_BLENDOP_ADD

proc createPipeline(dev: ptr SDL_GPUDevice;
                    vsh, fsh: ptr SDL_GPUShader;
                    targetDesc: var SDL_GPUColorTargetDescription;
                    tag: string): ptr SDL_GPUGraphicsPipeline =
  var info: SDL_GPUGraphicsPipelineCreateInfo
  info.vertex_shader   = vsh
  info.fragment_shader = fsh
  info.primitive_type  = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST
  info.rasterizer_state.fill_mode  = SDL_GPU_FILLMODE_FILL
  info.rasterizer_state.cull_mode  = SDL_GPU_CULLMODE_NONE
  info.rasterizer_state.front_face = SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE
  info.multisample_state.sample_count = SDL_GPU_SAMPLECOUNT_1
  info.target_info.num_color_targets         = 1
  info.target_info.color_target_descriptions = addr targetDesc
  info.target_info.has_depth_stencil_target  = false
  result = SDL_CreateGPUGraphicsPipeline(dev, addr info)
  if result == nil:
    die("SDL_CreateGPUGraphicsPipeline(" & tag & ")")

proc setupUiPipelines*(dev: ptr SDL_GPUDevice;
                       win: ptr SDL_Window): UiPipelines =
  var targetDesc = makeAlphaBlendTargetDesc(SDL_GetGPUSwapchainTextureFormat(dev, win))

  let solidV = loadShaderBytes(dev, UiSolidVertSpv, SDL_GPU_SHADERSTAGE_VERTEX,
                               numUniforms = 1, tag = "ui_solid.vert")
  let solidF = loadShaderBytes(dev, UiSolidFragSpv, SDL_GPU_SHADERSTAGE_FRAGMENT,
                               numUniforms = 1, tag = "ui_solid.frag")
  result.solid = createPipeline(dev, solidV, solidF, targetDesc, "ui_solid")
  SDL_ReleaseGPUShader(dev, solidV); SDL_ReleaseGPUShader(dev, solidF)

  let textV = loadShaderBytes(dev, UiTextVertSpv, SDL_GPU_SHADERSTAGE_VERTEX,
                              numUniforms = 1, tag = "ui_text.vert")
  let textF = loadShaderBytes(dev, UiTextFragSpv, SDL_GPU_SHADERSTAGE_FRAGMENT,
                              numSamplers = 1, tag = "ui_text.frag")
  result.text = createPipeline(dev, textV, textF, targetDesc, "ui_text")
  SDL_ReleaseGPUShader(dev, textV); SDL_ReleaseGPUShader(dev, textF)

  let circleV = loadShaderBytes(dev, UiCircleVertSpv, SDL_GPU_SHADERSTAGE_VERTEX,
                                numUniforms = 1, tag = "ui_circle.vert")
  let circleF = loadShaderBytes(dev, UiCircleFragSpv, SDL_GPU_SHADERSTAGE_FRAGMENT,
                                numUniforms = 1, tag = "ui_circle.frag")
  result.circle = createPipeline(dev, circleV, circleF, targetDesc, "ui_circle")
  SDL_ReleaseGPUShader(dev, circleV); SDL_ReleaseGPUShader(dev, circleF)

  result.fontSampler = createLinearClampSampler(dev)

proc releaseUiPipelines*(dev: ptr SDL_GPUDevice; p: var UiPipelines) =
  if p.solid != nil: SDL_ReleaseGPUGraphicsPipeline(dev, p.solid); p.solid = nil
  if p.text  != nil: SDL_ReleaseGPUGraphicsPipeline(dev, p.text);  p.text  = nil
  if p.circle != nil: SDL_ReleaseGPUGraphicsPipeline(dev, p.circle); p.circle = nil
  if p.fontSampler != nil:
    SDL_ReleaseGPUSampler(dev, p.fontSampler); p.fontSampler = nil

proc rectToNdc(r: Rect; winW, winH: float32): RectUbo =
  ## Pixel rect (origin top-left, y-down) → SDL3 GPU NDC (origin centre,
  ## +y up). The shaders subtract `p.y * h` to grow the quad downward, so we
  ## hand them the top-left NDC y as `1 - 2*y/H` and a positive height in NDC.
  result.x = -1.0'f32 + 2.0'f32 * r.x / winW
  result.y =  1.0'f32 - 2.0'f32 * r.y / winH
  result.w = 2.0'f32 * r.w / winW
  result.h = 2.0'f32 * r.h / winH

proc submitDrawList*(cmdBuf: ptr SDL_GPUCommandBuffer;
                     rp: ptr SDL_GPURenderPass;
                     ctx: UiContext;
                     pipes: UiPipelines) =
  ## Walk ctx.draw, switch the bound pipeline as needed, push per-quad
  ## uniforms, draw 6 verts per command. Texture sampler is bound per
  ## text command since each glyph atlas / line texture is its own surface.
  ## When a command carries a `clip` rect, we set a scissor for that one
  ## draw and restore the full-window scissor afterward.
  var bound: DrawCmdKind = high(DrawCmdKind)  # invalid → forces first bind
  var first = true
  var fullScissor = SDL_Rect(x: 0, y: 0,
                             w: cint(ctx.winW), h: cint(ctx.winH))

  for cmd in ctx.draw:
    if first or cmd.kind != bound:
      case cmd.kind
      of dckSolid:  SDL_BindGPUGraphicsPipeline(rp, pipes.solid)
      of dckCircle: SDL_BindGPUGraphicsPipeline(rp, pipes.circle)
      of dckText:   SDL_BindGPUGraphicsPipeline(rp, pipes.text)
      bound = cmd.kind
      first = false

    if cmd.clipped:
      var sc = SDL_Rect(
        x: cint(cmd.clip.x), y: cint(cmd.clip.y),
        w: cint(cmd.clip.w), h: cint(cmd.clip.h))
      SDL_SetGPUScissor(rp, addr sc)

    var rectU = rectToNdc(cmd.rect, ctx.winW, ctx.winH)
    SDL_PushGPUVertexUniformData(cmdBuf, 0,
                                 addr rectU, uint32(sizeof(RectUbo)))

    case cmd.kind
    of dckSolid, dckCircle:
      var colU = ColorUbo(r: cmd.color.r, g: cmd.color.g,
                          b: cmd.color.b, a: cmd.color.a)
      SDL_PushGPUFragmentUniformData(cmdBuf, 0,
                                     addr colU, uint32(sizeof(ColorUbo)))
    of dckText:
      var binding: SDL_GPUTextureSamplerBinding
      binding.texture = cast[ptr SDL_GPUTexture](cmd.tex)
      binding.sampler = cast[ptr SDL_GPUSampler](cmd.sampler)
      SDL_BindGPUFragmentSamplers(rp, 0, addr binding, 1)

    SDL_DrawGPUPrimitives(rp, 6, 1, 0, 0)

    if cmd.clipped:
      SDL_SetGPUScissor(rp, addr fullScissor)
