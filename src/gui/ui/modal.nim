## Full-screen overlay used by the top settings slice and any other modal
## drop-down panels. The overlay dims everything behind it and animates open
## and shut via a 0..1 fraction the caller advances each frame.

import context
import draw

const
  AnimSecs* = 0.15'f32

proc tickFraction*(frac: var float32; opening: bool; dt: float32) =
  ## Advance `frac` toward 1.0 when `opening` is true, else toward 0.0.
  let step = dt / AnimSecs
  if opening:
    frac = min(1.0'f32, frac + step)
  else:
    frac = max(0.0'f32, frac - step)

proc modalDim*(ctx: var UiContext; frac: float32; alpha: float32 = 0.55'f32) =
  ## Push a single full-window dim quad whose alpha scales with `frac`.
  if frac <= 0: return
  ctx.pushSolid(rect(0, 0, ctx.winW, ctx.winH),
                color(0.04, 0.05, 0.07, alpha * frac))

proc slideDownPanelRect*(ctx: UiContext; frac: float32;
                         finalH: float32): Rect =
  ## Returns the panel rect for a top-anchored slide-down, animated by
  ## `frac` (0 = hidden, 1 = fully revealed).
  rect(0, 0, ctx.winW, finalH * frac)

proc settleToCenteredRect*(ctx: UiContext; frac: float32;
                           availableH: float32;
                           finalScale: float32 = 0.80'f32): Rect =
  ## Two-stage animation for the settings overlay: `frac` 0..1 interpolates
  ## from a top-anchored full-width slide-down toward a centered panel sized
  ## `finalScale` of (winW × availableH). At `frac = 0` the rect is empty
  ## (height = 0); at `frac = 1` it sits centered at `finalScale` × the
  ## available area.
  let endX = (ctx.winW    * (1.0'f32 - finalScale)) * 0.5'f32
  let endY = (availableH  * (1.0'f32 - finalScale)) * 0.5'f32
  let endW =  ctx.winW    * finalScale
  let endH =  availableH  * finalScale

  # Start (frac=0): full-width, zero height, anchored at the top-left.
  let startX = 0.0'f32
  let startY = 0.0'f32
  let startW = ctx.winW
  let startH = 0.0'f32

  let f = frac
  result.x = startX + (endX - startX) * f
  result.y = startY + (endY - startY) * f
  result.w = startW + (endW - startW) * f
  result.h = startH + (endH - startH) * f
