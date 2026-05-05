## Right-side parts pane. Composes a tab strip on top of a virtualised
## parts list. Caller (gui/app.nim) owns the AppState + ContextMenu and
## dispatches the right-click items. This module is purely view +
## hit-testing.

import std/[hashes, strutils]
import context
import draw
import text as uitext
import scroll
import tabs
import menu
import text_input
import ../state
import ../car_names

const
  PaneBg          = (0.10'f32, 0.12'f32, 0.16'f32, 0.85'f32)
  TabStripBg      = (0.08'f32, 0.10'f32, 0.13'f32, 0.95'f32)
  RowH            = 22.0'f32
  RowPadX         = 12.0'f32
  EmptyDimColor   = (0.55'f32, 0.58'f32, 0.65'f32, 1.0'f32)

  LodKindChipBg   = (0.20'f32, 0.24'f32, 0.30'f32, 0.85'f32)
  LodKindChipPadX = 6.0'f32
  LodKindChipH    = 14.0'f32

  SearchH         = 24.0'f32
  SearchPad       = 4.0'f32

proc rowWid(slug, partName: string): WidgetId =
  WidgetId(hash("rpane.row." & slug & "/" & partName))

proc searchWid(slug: string): WidgetId =
  WidgetId(hash("rpane.search." & slug))

proc matchesSearch(query, name: string): bool =
  if query.len == 0: return true
  name.toLowerAscii.contains(query.toLowerAscii.strip())

const
  PanePadX*  = 48.0'f32      ## inset from window's left/right edge
  PanePadTop = 48.0'f32      ## inset below the top settings strip
  PanePadBot = 48.0'f32      ## inset above the bottom dropup row

proc paneRect*(winW, winH, stripH, dropupH: float32): Rect =
  let w = winW * 0.25'f32
  rect(winW - w - PanePadX,
       stripH + PanePadTop,
       w,
       winH - stripH - dropupH - PanePadTop - PanePadBot)

proc menuItemsForTab(t: PartsTab): seq[MenuItem] =
  ## Pinned tab cannot be closed; it gets "Unload car" instead.
  if t.pinned:
    @[MenuItem(label: "Unload car", enabled: true)]
  else:
    @[MenuItem(label: "Close tab",  enabled: true)]

proc menuItemsForPart*(grabActive: bool; isPinnedTab: bool): seq[MenuItem] =
  ## Right-click on a part row. Wiring of which actions actually do work
  ## lands in the grab-system step; for the skeleton phase only the labels
  ## matter so the menu shows up correctly.
  result = @[MenuItem(label: "Grab part", enabled: true)]
  if isPinnedTab:
    result.add MenuItem(label: "Replace with grabbed", enabled: grabActive)

proc drawRow(ctx: var UiContext; cache: var TextCache;
             part: PartRow; rowRect: Rect;
             isPinnedTab: bool; grabActive: bool;
             menu: var ContextMenu;
             slug: string; partIdx: int): bool =
  ## Returns true if this row was right-clicked (caller populates menu).
  if rowRect.contains(ctx.mouseX, ctx.mouseY):
    ctx.pushSolid(rowRect, color(0.22, 0.24, 0.30, 0.6))

  result = false
  if (not ctx.inputBlocked) and ctx.mouseClicked[2] and
     rowRect.contains(ctx.mouseX, ctx.mouseY):
    menu.open      = true
    menu.anchorX   = ctx.mouseX
    menu.anchorY   = ctx.mouseY
    menu.sourceIdx = partIdx
    menu.rowName   = slug & "::" & part.name
    menu.items     = menuItemsForPart(grabActive, isPinnedTab)
    result = true

  ctx.pushLabel(cache, part.name,
                rowRect.x + RowPadX,
                rowRect.y + (rowRect.h - 14) * 0.5'f32)

  if part.lodKind.len > 0:
    let (cw, _) = cache.measureText(part.lodKind)
    let chipW = cw + LodKindChipPadX * 2
    let chipX = rowRect.x + rowRect.w - chipW - 24
    let chipR = rect(chipX, rowRect.y + (rowRect.h - LodKindChipH) * 0.5'f32,
                     chipW, LodKindChipH)
    let (br, bg, bb, ba) = LodKindChipBg
    ctx.pushSolid(chipR, color(br, bg, bb, ba))
    ctx.pushLabel(cache, part.lodKind,
                  chipR.x + LodKindChipPadX,
                  chipR.y + (chipR.h - 14) * 0.5'f32 - 9)

  if part.modified:
    ctx.pushCircle(rect(rowRect.x + rowRect.w - 14,
                        rowRect.y + (rowRect.h - 6) * 0.5'f32, 6, 6),
                   color(0.95, 0.70, 0.20, 1.0))

proc drawRPane*(ctx: var UiContext; cache: var TextCache;
                app: var AppState; menu: var ContextMenu;
                pane: Rect): tuple[tabRightClicked, partRightClicked: int] =
  ## Renders the pane background, tab strip, and parts list. Returns the
  ## indices of right-click events the caller should dispatch. (The menu
  ## is populated for parts inline; tab right-click is reported via the
  ## return so the caller can build the tab-specific menu.)
  result = (-1, -1)
  let (br, bg, bb, ba) = PaneBg
  ctx.pushSolid(pane, color(br, bg, bb, ba))

  let stripR = rect(pane.x, pane.y, pane.w, TabH + 4)
  let (tr, tg, tb, ta) = TabStripBg
  ctx.pushSolid(stripR, color(tr, tg, tb, ta))

  if app.partsTabs.len == 0:
    let (er, eg, eb, ea) = EmptyDimColor
    discard (er, eg, eb, ea)
    ctx.pushLabel(cache, "no car loaded — right-click a working/ row",
                  pane.x + 12, pane.y + 12)
    return

  # Tab strip
  var tabItems: seq[TabItem] = @[]
  for t in app.partsTabs:
    tabItems.add TabItem(label: prettyDisplayName(t.slug),
                         pinned: t.pinned, accent: false)
  let tabsRes = drawTabStrip(ctx, cache, stripR, tabItems, app.activeTab)
  if tabsRes.active >= 0 and tabsRes.active != app.activeTab:
    app.activeTab = tabsRes.active
  if tabsRes.rightClicked >= 0:
    result.tabRightClicked = tabsRes.rightClicked
    menu.open      = true
    menu.anchorX   = ctx.mouseX
    menu.anchorY   = ctx.mouseY
    menu.sourceIdx = tabsRes.rightClicked
    menu.rowName   = "tab::" & app.partsTabs[tabsRes.rightClicked].slug
    menu.items     = menuItemsForTab(app.partsTabs[tabsRes.rightClicked])

  # Parts list for the active tab
  if app.activeTab < 0 or app.activeTab >= app.partsTabs.len: return
  var tab = addr app.partsTabs[app.activeTab]

  # Search bar lives directly under the tab strip; the list area below
  # it shrinks accordingly.
  let searchR = rect(pane.x + SearchPad,
                     stripR.y + stripR.h + SearchPad,
                     pane.w - SearchPad * 2,
                     SearchH - SearchPad * 2)
  discard textInput(ctx, cache, searchWid(tab[].slug), searchR, tab[].search)
  if tab[].search.text.len == 0:
    ctx.pushLabel(cache, "search…",
                  searchR.x + 8,
                  searchR.y + (searchR.h - 14) * 0.5'f32 - 5)

  let listR = rect(pane.x, stripR.y + stripR.h + SearchH,
                   pane.w, pane.h - stripR.h - SearchH)

  let q = tab[].search.text.strip()
  var filtered: seq[int] = @[]
  for k in 0 ..< tab[].parts.len:
    if matchesSearch(q, tab[].parts[k].name):
      filtered.add k

  let total = filtered.len
  let contentH = float32(total) * RowH

  var ss: ScrollState
  ss.y = tab[].scrollY
  consumeWheel(ctx, ss, listR, RowH)
  clamp(ss, contentH, listR.h)
  tab[].scrollY = ss.y

  let isPinned = tab[].pinned
  let (firstRow, lastRow) = visibleRange(ss, RowH, listR.h, total)
  let usableH = listR.h - 2.0'f32
  for j in firstRow .. lastRow:
    let yOff = float32(j) * RowH - ss.y
    if yOff < 0 or yOff + RowH > usableH: continue
    let pi = filtered[j]
    let rRect = rect(listR.x, listR.y + yOff, listR.w, RowH)
    if drawRow(ctx, cache, tab[].parts[pi], rRect, isPinned,
               app.grab.active, menu, tab[].slug, pi):
      result.partRightClicked = pi

  drawScrollbar(ctx, ss, listR, contentH)
