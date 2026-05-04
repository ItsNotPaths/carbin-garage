## Bottom dropup widget. Each Source becomes a tile in a horizontal strip
## along the bottom; clicking a tile expands a panel UP from the tile's
## position, listing that source's cars. Mutually exclusive — opening one
## closes the others.
##
## Phase 3a renders the list with no scrolling and no row actions beyond
## the multi-select toggle. Right-click context menu (extract / open parts
## tab) and scroll land in 3b/3c.

import std/hashes
import context
import draw
import text as uitext
import button
import modal
import ../state

const
  TileH*       = 0.025'f32   ## fraction of window H — matches top strip
  PanelMaxFrac = 0.50'f32    ## panel may use up to this much of the window H
  RowH         = 22.0'f32
  LightR       = 5.0'f32     ## extracted-state circle radius
  ToggleW      = 16.0'f32    ## select-toggle square side
  RowPadX      = 10.0'f32

proc tileWid(idx: int): WidgetId = WidgetId(hash("dropup.tile." & $idx))
proc rowWid(srcIdx: int; name: string): WidgetId =
  WidgetId(hash("dropup.row." & $srcIdx & "/" & name))

proc lightColor(state: ExtractState): Color =
  case state
  of esUnextracted: color(0.45, 0.45, 0.50)
  of esExtracted:   color(0.30, 0.78, 0.42)
  of esDirty:       color(0.95, 0.70, 0.20)

proc togglePalette(selected: bool): tuple[bg, border: Color] =
  if selected:
    (color(0.85, 0.40, 0.30), color(1.0, 0.55, 0.45))
  else:
    (color(0.16, 0.18, 0.22), color(0.30, 0.32, 0.38))

proc drawRow(ctx: var UiContext; cache: var TextCache;
             app: var AppState;
             srcIdx: int; rowIdx: int;
             rowRect: Rect) =
  let row = app.sources[srcIdx].cars[rowIdx]

  # hover highlight
  if rowRect.contains(ctx.mouseX, ctx.mouseY):
    ctx.pushSolid(rowRect, color(0.22, 0.24, 0.30, 0.6))

  # extracted-state light (filled circle)
  let lightCx = rowRect.x + RowPadX + LightR
  let lightCy = rowRect.y + rowRect.h * 0.5'f32
  ctx.pushCircle(rect(lightCx - LightR, lightCy - LightR,
                      LightR * 2, LightR * 2),
                 lightColor(row.extractState))

  # select toggle (filled square; bordered when not selected)
  let togX = lightCx + LightR + RowPadX
  let togY = rowRect.y + (rowRect.h - ToggleW) * 0.5'f32
  let togRect = rect(togX, togY, ToggleW, ToggleW)
  let pal = togglePalette(row.selected)
  ctx.pushSolid(togRect, pal.bg)
  if not row.selected:
    # tiny border emulation: draw a slightly inset darker quad on top
    ctx.pushSolid(rect(togX + 2, togY + 2, ToggleW - 4, ToggleW - 4),
                  color(0.10, 0.12, 0.16))

  let togId = rowWid(srcIdx, row.name)
  if (not ctx.inputBlocked) and togRect.contains(ctx.mouseX, ctx.mouseY):
    ctx.hotId = togId
    if ctx.mouseClicked[0]:
      ctx.activeId = togId
    if ctx.mouseReleased[0] and ctx.activeId == togId:
      app.toggleSelected(srcIdx, row.name)
      ctx.activeId = 0

  # car name label
  let labelX = togX + ToggleW + RowPadX
  ctx.pushLabel(cache, row.name,
                labelX,
                rowRect.y + (rowRect.h - 14) * 0.5'f32)

proc drawDropupRow*(ctx: var UiContext; cache: var TextCache;
                    app: var AppState) =
  if app.sources.len == 0: return

  let stripH = ctx.winH * TileH
  let stripY = ctx.winH - stripH
  let tileW  = ctx.winW / float32(app.sources.len)

  # base strip
  ctx.pushSolid(rect(0, stripY, ctx.winW, stripH),
                color(0.14, 0.16, 0.20))

  # tiles + click handling
  var clickedIdx = -1
  for i in 0 ..< app.sources.len:
    let r = rect(float32(i) * tileW, stripY, tileW, stripH)
    let style = ButtonStyle(
      bg:        color(0.14, 0.16, 0.20),
      bgHover:   color(0.18, 0.20, 0.25),
      bgActive:  color(0.24, 0.27, 0.34),
      fg:        color(0.92, 0.94, 0.98))
    if button(ctx, cache, tileWid(i), r, app.sources[i].label, style):
      clickedIdx = i

  if clickedIdx >= 0:
    let curr = app.sources[clickedIdx].expanded
    for i in 0 ..< app.sources.len:
      app.sources[i].expanded = (i == clickedIdx) and not curr

  # animate + draw expanded panels
  let panelMax = ctx.winH * PanelMaxFrac
  for i in 0 ..< app.sources.len:
    var src = addr app.sources[i]
    modal.tickFraction(src[].expandFrac, src[].expanded, ctx.dt)
    if src[].expandFrac <= 0: continue

    let panelH = panelMax * src[].expandFrac
    let panelW = max(tileW, 360.0'f32)
    var panelX = float32(i) * tileW + (tileW - panelW) * 0.5'f32
    if panelX < 0: panelX = 0
    if panelX + panelW > ctx.winW: panelX = ctx.winW - panelW
    let panelY = stripY - panelH

    # panel background
    ctx.pushSolid(rect(panelX, panelY, panelW, panelH),
                  color(0.10, 0.12, 0.16, 0.96))

    let panelRect = rect(panelX, panelY, panelW, panelH)
    let total = src[].cars.len
    let totalH = float32(total) * RowH
    let maxScroll = max(0.0'f32, totalH - panelH)

    # consume wheel when hovering this panel (and input isn't blocked)
    if (not ctx.inputBlocked) and
       panelRect.contains(ctx.mouseX, ctx.mouseY) and ctx.wheelY != 0:
      src[].scrollY -= ctx.wheelY * RowH * 3.0'f32
      ctx.wheelY = 0

    if src[].scrollY < 0:           src[].scrollY = 0
    if src[].scrollY > maxScroll:   src[].scrollY = maxScroll

    # virtualised row range
    let firstRow = int(src[].scrollY / RowH)
    let lastRow = min(total - 1,
                      firstRow + int(panelH / RowH) + 1)
    # Reserve a small gap above the strip so a partial bottom row never
    # bleeds onto the dropup-tile button row.
    let usableH = panelH - 4.0'f32
    for j in firstRow .. lastRow:
      let yOff = float32(j) * RowH - src[].scrollY
      if yOff < 0 or yOff + RowH > usableH: continue
      let rRect = rect(panelX, panelY + yOff, panelW, RowH)
      drawRow(ctx, cache, app, i, j, rRect)

    # scrollbar (right edge, only when content overflows)
    if maxScroll > 0:
      let trackW = 4.0'f32
      let trackR = rect(panelX + panelW - trackW - 2, panelY + 2,
                        trackW, panelH - 4)
      ctx.pushSolid(trackR, color(0.20, 0.22, 0.26, 0.6))
      let thumbH = max(20.0'f32, panelH * panelH / totalH)
      let thumbY = trackR.y +
                   (trackR.h - thumbH) * (src[].scrollY / maxScroll)
      ctx.pushSolid(rect(trackR.x, thumbY, trackR.w, thumbH),
                    color(0.55, 0.58, 0.65, 0.85))
