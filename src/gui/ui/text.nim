## Text helpers for the UI layer.
##
## Each unique string gets one rasterized SDL_GPUTexture, cached for the life
## of the program. Phase 3a ships with no eviction — the working set is small
## (button labels, mount paths, status strings). Add an LRU later if memory
## becomes a concern.

import std/tables
import ../../render/platform/sdl3
import ../../render/text as rendertext
import context
import draw

type
  TextCache* = object
    dev*: ptr SDL_GPUDevice
    font*: ptr TTF_Font
    sampler*: ptr SDL_GPUSampler
    entries*: Table[string, rendertext.TextTexture]

proc initTextCache*(dev: ptr SDL_GPUDevice;
                    font: ptr TTF_Font;
                    sampler: ptr SDL_GPUSampler): TextCache =
  TextCache(dev: dev, font: font, sampler: sampler,
            entries: initTable[string, rendertext.TextTexture]())

proc releaseTextCache*(c: var TextCache) =
  for k, v in c.entries.mpairs:
    rendertext.releaseTextTexture(c.dev, v)
  c.entries.clear()

proc getOrBuild(c: var TextCache; s: string): rendertext.TextTexture =
  if c.entries.hasKey(s):
    return c.entries[s]
  result = rendertext.buildTextTexture(c.dev, c.font, s)
  c.entries[s] = result

proc measureText*(c: var TextCache; s: string): tuple[w, h: float32] =
  ## TTF_RenderText_Blended fails on an empty string ("Text has zero
  ## width"), so short-circuit before the rasterizer is touched. Layout
  ## code measures speculatively (caret position, marquee period, etc.)
  ## and the empty case is normal.
  if s.len == 0: return (0'f32, 0'f32)
  let t = c.getOrBuild(s)
  (float32(t.width), float32(t.height))

proc pushLabel*(ctx: var UiContext; c: var TextCache; s: string;
                x, y: float32) =
  ## Draws `s` with its top-left at (x, y). Color is whatever the rasterizer
  ## output (currently white-on-transparent — ui_text.frag samples uFont raw).
  if s.len == 0: return
  let t = c.getOrBuild(s)
  ctx.pushText(rect(x, y, float32(t.width), float32(t.height)),
               cast[pointer](t.tex), cast[pointer](c.sampler))

proc pushLabelClipped*(ctx: var UiContext; c: var TextCache; s: string;
                       x, y: float32; clip: Rect) =
  ## Same as `pushLabel` but the resulting quad is scissor-clipped to
  ## `clip`. The caller can position `(x, y)` outside `clip` for marquee
  ## scrolling — only the portion that falls inside `clip` will rasterize.
  if s.len == 0: return
  let t = c.getOrBuild(s)
  ctx.pushTextClipped(rect(x, y, float32(t.width), float32(t.height)),
                      cast[pointer](t.tex), cast[pointer](c.sampler), clip)

proc pushLabelCentered*(ctx: var UiContext; c: var TextCache; s: string;
                        r: Rect) =
  ## Centers `s` inside `r`. No clipping — caller picks a rect that fits.
  if s.len == 0: return
  let t = c.getOrBuild(s)
  let tw = float32(t.width)
  let th = float32(t.height)
  ctx.pushText(rect(r.x + (r.w - tw) * 0.5'f32,
                    r.y + (r.h - th) * 0.5'f32,
                    tw, th),
               cast[pointer](t.tex), cast[pointer](c.sampler))
