## Helpers that widgets call to enqueue draw commands. The submission /
## pipeline-switching pass lives in render.nim — these procs only build the
## per-frame command list.

import context

proc pushSolid*(ctx: var UiContext; r: Rect; c: Color) =
  ctx.draw.add DrawCmd(kind: dckSolid, rect: r, color: c)

proc pushCircle*(ctx: var UiContext; r: Rect; c: Color) =
  ctx.draw.add DrawCmd(kind: dckCircle, rect: r, color: c)

proc pushText*(ctx: var UiContext; r: Rect;
               tex: pointer; sampler: pointer) =
  ## `tex` and `sampler` are the SDL_GPUTexture / SDL_GPUSampler pointers
  ## produced by src/render/text.nim's buildTextTexture + a linear-clamp
  ## sampler shared by all text draws.
  ctx.draw.add DrawCmd(kind: dckText, rect: r, tex: tex, sampler: sampler)
