## Bottom dropup widget. Each Source becomes a tile in a horizontal strip
## along the bottom; clicking a tile expands a panel UP from the tile's
## position, listing that source's cars. Mutually exclusive — opening one
## closes the others.
##
## Phase 3c added a right-click context menu (`Export to working/`,
## `Load from working/`) — see `gui/ui/menu.nim`. Multi-select toggle
## and virtualised wheel-scroll have been here since 3a.

import std/[hashes, strutils]
import context
import draw
import text as uitext
import button
import modal
import menu
import text_input
import ../state

const
  TileH*       = 0.025'f32   ## fraction of window H — matches top strip
  PanelMaxFrac = 0.50'f32    ## panel may use up to this much of the window H
  RowH         = 22.0'f32
  LightR       = 5.0'f32     ## extracted-state circle radius
  ToggleW      = 16.0'f32    ## select-toggle square side
  RowPadX      = 10.0'f32
  SearchH*     = 24.0'f32    ## height of the search field row at the panel bottom
  SearchPad    = 4.0'f32

proc searchWid(srcIdx: int): WidgetId =
  WidgetId(hash("dropup.search." & $srcIdx))

proc matchesSearch*(query, name: string): bool =
  if query.len == 0: return true
  name.toLowerAscii.contains(query.toLowerAscii.strip())

proc tileWid(idx: int): WidgetId = WidgetId(hash("dropup.tile." & $idx))
proc rowWid(srcIdx: int; name: string): WidgetId =
  WidgetId(hash("dropup.row." & $srcIdx & "/" & name))

proc lightColor(state: ExtractState): Color =
  case state
  of esUnextracted: color(0.45, 0.45, 0.50)
  of esExtracted:   color(0.30, 0.78, 0.42)

proc togglePalette(selected: bool): tuple[bg, border: Color] =
  if selected:
    (color(0.85, 0.40, 0.30), color(1.0, 0.55, 0.45))
  else:
    (color(0.16, 0.18, 0.22), color(0.30, 0.32, 0.38))

proc menuItemsFor(src: Source; row: CarRow): seq[MenuItem] =
  ## Right-click on any car row offers the same three entries; enable
  ## state depends on the row's source. Game / DLC rows can be imported
  ## (always-copy) into working/ when a backing zip exists; catalog-only
  ## rows from `listMediaNames` (no sourcePath) stay disabled until the
  ## .CAB unpack pipeline lands. Working/ rows can be loaded onto the
  ## pedestal or have a parts tab opened.
  let isWorking   = src.kind == srcWorking
  let canImport   = (src.kind in {srcGame, srcDlc}) and
                    row.sourcePath.len > 0
  @[
    MenuItem(label: "Import to working/",  enabled: canImport),
    MenuItem(label: "Load from working/",  enabled: isWorking),
    MenuItem(label: "Open parts tab",      enabled: isWorking),
  ]

proc drawRow(ctx: var UiContext; cache: var TextCache;
             app: var AppState; menu: var ContextMenu;
             srcIdx: int; rowIdx: int;
             rowRect: Rect) =
  let row = app.sources[srcIdx].cars[rowIdx]

  # hover highlight
  if rowRect.contains(ctx.mouseX, ctx.mouseY):
    ctx.pushSolid(rowRect, color(0.22, 0.24, 0.30, 0.6))

  # Right-click anywhere in the row opens the context menu at the cursor.
  # We intentionally let the toggle-square below also see the click — but
  # it only acts on LMB, so there's no conflict.
  if (not ctx.inputBlocked) and ctx.mouseClicked[2] and
     rowRect.contains(ctx.mouseX, ctx.mouseY):
    menu.open       = true
    menu.anchorX    = ctx.mouseX
    menu.anchorY    = ctx.mouseY
    menu.sourceIdx  = srcIdx
    menu.rowName    = row.name
    menu.items      = menuItemsFor(app.sources[srcIdx], row)

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

proc expandedPanelRect(ctx: UiContext; app: AppState; i: int): Rect =
  ## Geometry must match `drawDropupRow`'s inline computation.
  let stripH = ctx.winH * TileH
  let stripY = ctx.winH - stripH
  let tileW  = ctx.winW / float32(app.sources.len)
  let panelMax = ctx.winH * PanelMaxFrac
  let panelH = panelMax * app.sources[i].expandFrac
  let panelW = max(tileW, 360.0'f32)
  var panelX = float32(i) * tileW + (tileW - panelW) * 0.5'f32
  if panelX < 0: panelX = 0
  if panelX + panelW > ctx.winW: panelX = ctx.winW - panelW
  let panelY = stripY - panelH
  rect(panelX, panelY, panelW, panelH)

proc dropupClaimsInput*(ctx: var UiContext; app: var AppState): bool =
  ## Pre-pass run before any pane renders. If a source's expanded panel
  ## is on screen and the mouse is over it, drain the wheel into that
  ## source and return true so the caller raises `inputBlocked` for the
  ## panes underneath. Closes the panel on outside-click, too.
  result = false
  if app.sources.len == 0: return
  let stripH = ctx.winH * TileH
  let stripY = ctx.winH - stripH
  let tileW  = ctx.winW / float32(app.sources.len)

  var anyVisible = -1
  var hovering = false
  for i in 0 ..< app.sources.len:
    if app.sources[i].expandFrac <= 0: continue
    anyVisible = i
    let panel = expandedPanelRect(ctx, app, i)
    if panel.contains(ctx.mouseX, ctx.mouseY):
      hovering = true
      # Drain wheel into this source's scrollY immediately, before the
      # panes get a shot at it. List area excludes the search bar at the
      # bottom of the panel.
      if ctx.wheelY != 0:
        let q = app.sources[i].search.text.strip()
        var visible = 0
        for k in 0 ..< app.sources[i].cars.len:
          if matchesSearch(q, app.sources[i].cars[k].name): inc visible
        let totalH = float32(visible) * RowH
        let listH = panel.h - SearchH
        let maxScroll = max(0.0'f32, totalH - listH)
        var sy = app.sources[i].scrollY
        sy -= ctx.wheelY * RowH * 3.0'f32
        if sy < 0: sy = 0
        if sy > maxScroll: sy = maxScroll
        app.sources[i].scrollY = sy
        ctx.wheelY = 0
      result = true
      break

  # Outside-click close: any non-tile, non-panel click on a fully-open
  # panel collapses it. Tile clicks are already handled by the toggle in
  # drawDropupRow; we exclude the strip rect so a tile click here doesn't
  # double-fire.
  if anyVisible >= 0 and not hovering and
     (ctx.mouseClicked[0] or ctx.mouseClicked[2]):
    let stripRect = rect(0, stripY, ctx.winW, stripH)
    if not stripRect.contains(ctx.mouseX, ctx.mouseY):
      for i in 0 ..< app.sources.len:
        app.sources[i].expanded = false

proc drawDropupRow*(ctx: var UiContext; cache: var TextCache;
                    app: var AppState; menu: var ContextMenu) =
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

    # Build filtered car-index list — query persists per source.
    let q = src[].search.text.strip()
    var filtered: seq[int] = @[]
    for k in 0 ..< src[].cars.len:
      if matchesSearch(q, src[].cars[k].name):
        filtered.add k

    # Reserve the bottom strip for the search field; the list area sits
    # above it. The list panel still covers the full panelH.
    let listH = panelH - SearchH
    let total = filtered.len
    let totalH = float32(total) * RowH
    let maxScroll = max(0.0'f32, totalH - listH)
    if src[].scrollY < 0:           src[].scrollY = 0
    if src[].scrollY > maxScroll:   src[].scrollY = maxScroll

    # virtualised row range over the filtered list
    let firstRow = int(src[].scrollY / RowH)
    let lastRow = min(total - 1,
                      firstRow + int(listH / RowH) + 1)
    # Reserve a small gap above the search field so a partial bottom row
    # never bleeds onto it.
    let usableH = listH - 4.0'f32
    for j in firstRow .. lastRow:
      let yOff = float32(j) * RowH - src[].scrollY
      if yOff < 0 or yOff + RowH > usableH: continue
      let rRect = rect(panelX, panelY + yOff, panelW, RowH)
      drawRow(ctx, cache, app, menu, i, filtered[j], rRect)

    # scrollbar (right edge, only when content overflows the list area)
    if maxScroll > 0:
      let trackW = 4.0'f32
      let trackR = rect(panelX + panelW - trackW - 2, panelY + 2,
                        trackW, listH - 4)
      ctx.pushSolid(trackR, color(0.20, 0.22, 0.26, 0.6))
      let thumbH = max(20.0'f32, listH * listH / totalH)
      let thumbY = trackR.y +
                   (trackR.h - thumbH) * (src[].scrollY / maxScroll)
      ctx.pushSolid(rect(trackR.x, thumbY, trackR.w, thumbH),
                    color(0.55, 0.58, 0.65, 0.85))

    # Search field at the bottom of the panel.
    let searchR = rect(panelX + SearchPad,
                       panelY + listH + SearchPad,
                       panelW - SearchPad * 2,
                       SearchH - SearchPad * 2)
    discard textInput(ctx, cache, searchWid(i), searchR, src[].search)
    if src[].search.text.len == 0:
      ctx.pushLabel(cache, "search…",
                    searchR.x + 8,
                    searchR.y + (searchR.h - 14) * 0.5'f32 - 5)
