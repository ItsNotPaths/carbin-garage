## Reusable virtualised-scroll helpers. Extracted from the dropup pattern
## (see `ui/dropup.nim`) so the parts list and stats form can share the
## same wheel-consume + clamp + scrollbar-thumb logic.
##
## Callers own a `ScrollState` per panel; widgets are passive and just
## consume / draw given a panel rect, content height, and row height.

import context
import draw

type
  ScrollState* = object
    y*: float32   ## current scroll offset in pixels (0 = top)

proc consumeWheel*(ctx: var UiContext; s: var ScrollState;
                   panel: Rect; rowH: float32; speed: float32 = 3.0'f32) =
  ## If the mouse is inside `panel` and a wheel delta exists this frame,
  ## drain it into `s.y`. Caller is expected to clamp afterwards via
  ## `clamp(s, contentH, panel.h)`.
  if ctx.inputBlocked: return
  if ctx.wheelY == 0: return
  if not panel.contains(ctx.mouseX, ctx.mouseY): return
  s.y -= ctx.wheelY * rowH * speed
  ctx.wheelY = 0

proc clamp*(s: var ScrollState; contentH, viewH: float32) =
  let maxScroll = max(0.0'f32, contentH - viewH)
  if s.y < 0: s.y = 0
  if s.y > maxScroll: s.y = maxScroll

proc visibleRange*(s: ScrollState; rowH, viewH: float32;
                   total: int): tuple[first, last: int] =
  ## Inclusive range of rows likely to overlap the viewport. Caller still
  ## culls per-row by computing `yOff` and bounds-checking.
  if total <= 0 or rowH <= 0: return (0, -1)
  let first = int(s.y / rowH)
  let last  = min(total - 1, first + int(viewH / rowH) + 1)
  (max(0, first), last)

proc drawScrollbar*(ctx: var UiContext; s: ScrollState;
                    panel: Rect; contentH: float32;
                    trackW: float32 = 4.0'f32) =
  ## Right-edge thumb. No-op when content fits.
  let maxScroll = max(0.0'f32, contentH - panel.h)
  if maxScroll <= 0: return
  let track = rect(panel.x + panel.w - trackW - 2,
                   panel.y + 2, trackW, panel.h - 4)
  ctx.pushSolid(track, color(0.20, 0.22, 0.26, 0.6))
  let thumbH = max(20.0'f32, panel.h * panel.h / contentH)
  let thumbY = track.y + (track.h - thumbH) * (s.y / maxScroll)
  ctx.pushSolid(rect(track.x, thumbY, track.w, thumbH),
                color(0.55, 0.58, 0.65, 0.85))
