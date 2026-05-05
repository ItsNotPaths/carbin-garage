## Right-click context menu. Anchors at a window-pixel position, lays out
## a vertical column of label rows, and returns the chosen index for the
## one frame the user releases on an enabled row. Dismissed by clicking
## outside the panel or pressing escape (the latter handled by the caller
## clearing `open`).
##
## The widget is rendered LAST in the frame (after dropup + settings) so
## its hit region wins over anything underneath. It also raises
## `ctx.inputBlocked` for the rest of the frame's hit-testing once it
## consumes a click — but since it's drawn last there's nothing left to
## block.

import std/hashes
import context
import draw
import text as uitext

type
  MenuItem* = object
    label*: string
    enabled*: bool

  ContextMenu* = object
    open*: bool
    anchorX*, anchorY*: float32
    items*: seq[MenuItem]
    ## Caller-owned context — the dropup writes which row triggered the
    ## menu and reads it back when an action fires. Menu doesn't interpret.
    sourceIdx*: int
    rowName*: string

const
  ItemH       = 22.0'f32
  ItemPadX    = 12.0'f32
  ItemMinW    = 200.0'f32
  ItemMaxW    = 360.0'f32
  PanelMargin = 4.0'f32
  BgColor     = (0.10'f32, 0.12'f32, 0.16'f32, 0.96'f32)
  BorderColor = (0.30'f32, 0.32'f32, 0.38'f32, 1.0'f32)
  HoverColor  = (0.22'f32, 0.24'f32, 0.30'f32, 0.95'f32)
  DisabledDim = (0.0'f32, 0.0'f32, 0.0'f32, 0.45'f32)

proc itemWid(anchorX, anchorY: float32; idx: int): WidgetId =
  WidgetId(hash("menu.item." & $anchorX & "/" & $anchorY & "/" & $idx))

proc panelRect(menu: ContextMenu; cache: var TextCache;
               winW, winH: float32): Rect =
  var w = ItemMinW
  for it in menu.items:
    let (tw, _) = cache.measureText(it.label)
    let need = tw + ItemPadX * 2
    if need > w: w = need
  if w > ItemMaxW: w = ItemMaxW
  let h = float32(menu.items.len) * ItemH + PanelMargin * 2
  var x = menu.anchorX
  var y = menu.anchorY
  if x + w > winW: x = winW - w
  if y + h > winH: y = winH - h
  if x < 0: x = 0
  if y < 0: y = 0
  rect(x, y, w, h)

proc drawContextMenu*(ctx: var UiContext; cache: var TextCache;
                      menu: var ContextMenu): int =
  ## Returns the index of an enabled item the user just released on, or -1.
  ## Closes the menu on either an item-pick or any click outside the panel.
  result = -1
  if not menu.open or menu.items.len == 0: return

  let panel = panelRect(menu, cache, ctx.winW, ctx.winH)

  # background + border (border is a 1px outline emulated with two rects)
  let (br, bg, bb, ba) = BorderColor
  ctx.pushSolid(rect(panel.x - 1, panel.y - 1, panel.w + 2, panel.h + 2),
                color(br, bg, bb, ba))
  let (bgR, bgG, bgB, bgA) = BgColor
  ctx.pushSolid(panel, color(bgR, bgG, bgB, bgA))

  var clickedItem = -1
  for i, it in menu.items:
    let r = rect(panel.x + PanelMargin,
                 panel.y + PanelMargin + float32(i) * ItemH,
                 panel.w - PanelMargin * 2, ItemH)
    let id = itemWid(menu.anchorX, menu.anchorY, i)
    let hovered = r.contains(ctx.mouseX, ctx.mouseY)
    if hovered and it.enabled:
      ctx.hotId = id
      let (hr, hg, hb, ha) = HoverColor
      ctx.pushSolid(r, color(hr, hg, hb, ha))
      if ctx.mouseClicked[0]:
        ctx.activeId = id
      if ctx.mouseReleased[0] and ctx.activeId == id:
        clickedItem = i
        ctx.activeId = 0

    ctx.pushLabel(cache, it.label, r.x + ItemPadX,
                  r.y + (r.h - 14) * 0.5'f32)
    if not it.enabled:
      # No per-glyph color in the text rasterizer yet — drop a translucent
      # black overlay over the row so the label reads as dimmed.
      let (dr, dg, db, da) = DisabledDim
      ctx.pushSolid(r, color(dr, dg, db, da))

  if clickedItem >= 0:
    result = clickedItem
    menu.open = false
    return

  # Dismiss on any click outside the panel. We check both buttons so a
  # stray right-click elsewhere also closes the menu rather than re-opening
  # it under the cursor on the same frame.
  let outside = not panel.contains(ctx.mouseX, ctx.mouseY)
  if outside and (ctx.mouseClicked[0] or ctx.mouseClicked[2]):
    menu.open = false
