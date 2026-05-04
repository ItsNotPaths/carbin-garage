## Hand-rolled button widget. Tracks hot/active state on the shared
## UiContext and emits one solid quad + a centered text label.
##
## Returns `true` for the single frame the button is "released" (mouse-up
## inside the rect after a mouse-down inside the rect).

import context
import draw
import text as uitext

type
  ButtonStyle* = object
    bg*, bgHover*, bgActive*, fg*: Color

proc defaultButtonStyle*(): ButtonStyle =
  ButtonStyle(
    bg:        color(0.18, 0.20, 0.24),
    bgHover:   color(0.22, 0.25, 0.30),
    bgActive:  color(0.28, 0.32, 0.40),
    fg:        color(0.92, 0.94, 0.98))

proc button*(ctx: var UiContext; cache: var TextCache;
             id: WidgetId; r: Rect; label: string;
             style: ButtonStyle = defaultButtonStyle()): bool =
  let hovered = (not ctx.inputBlocked) and r.contains(ctx.mouseX, ctx.mouseY)
  if hovered:
    ctx.hotId = id

  if hovered and ctx.mouseClicked[0]:
    ctx.activeId = id

  let pressed = (ctx.activeId == id) and ctx.mouseDown[0]
  let bg =
    if pressed:        style.bgActive
    elif hovered:      style.bgHover
    else:              style.bg

  ctx.pushSolid(r, bg)
  ctx.pushLabelCentered(cache, label, r)

  result = (ctx.activeId == id) and ctx.mouseReleased[0] and hovered
  if ctx.mouseReleased[0] and ctx.activeId == id:
    ctx.activeId = 0
