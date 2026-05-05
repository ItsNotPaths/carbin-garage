## Left-side stats pane. Profile-driven form; one row per
## `prof.userEditableStats` entry. Pre-fills from the active car's
## `cardb.json` Data_Car row; edits persist to `carslot.json` `stats{}`
## when the user clicks Save (or via Ctrl+S, wired by the polish step).

import std/[hashes, strutils, math]
import context
import draw
import text as uitext
import scroll
import button
import text_input
import ../state
import ../../carbin_garage/core/profile
import ../../render/platform/sdl3

const
  PaneBg            = (0.10'f32, 0.12'f32, 0.16'f32, 0.85'f32)
  HeaderBg          = (0.08'f32, 0.10'f32, 0.13'f32, 0.95'f32)
  HeaderH           = 26.0'f32
  RowH              = 30.0'f32
  RowPadX           = 12.0'f32
  InputW            = 70.0'f32      ## fixed input width
  ResetBtnW         = 22.0'f32
  ColGap            = 6.0'f32
  ButtonStripH      = 36.0'f32
  MarqueeSpeed      = 30.0'f32      ## px/sec for scrolling overflow names
  MarqueeDwell      = 3.0'f32       ## seconds held at start AND at end
  SearchH           = 24.0'f32
  SearchPad         = 4.0'f32

  ModifiedDot       = (0.95'f32, 0.70'f32, 0.20'f32, 1.0'f32)
  HelpDim           = (0.55'f32, 0.58'f32, 0.65'f32, 1.0'f32)

  PanePadX*         = 48.0'f32      ## inset from window's left edge
  PanePadTop        = 48.0'f32
  PanePadBot        = 48.0'f32

proc searchWid(slug: string): WidgetId =
  WidgetId(hash("lpane.search." & slug))

proc matchesSearch(query, name: string): bool =
  if query.len == 0: return true
  name.toLowerAscii.contains(query.toLowerAscii.strip())

proc fieldWid(slug, col: string): WidgetId =
  WidgetId(hash("lpane.field." & slug & "/" & col))

proc resetWid(slug, col: string): WidgetId =
  WidgetId(hash("lpane.reset." & slug & "/" & col))

proc paneRect*(winW, winH, stripH, dropupH: float32): Rect =
  ## Mirrors the R pane width so both side panels look balanced; the
  ## values pane needs the extra room for long Data_Car field names.
  let w = winW * 0.25'f32
  rect(PanePadX,
       stripH + PanePadTop,
       w,
       winH - stripH - dropupH - PanePadTop - PanePadBot)

proc drawLPane*(ctx: var UiContext; cache: var TextCache;
                app: var AppState; pane: Rect): bool =
  ## Returns true if the user pressed Save this frame.
  result = false
  let (br, bg, bb, ba) = PaneBg
  ctx.pushSolid(pane, color(br, bg, bb, ba))

  let header = rect(pane.x, pane.y, pane.w, HeaderH)
  let (hr, hg, hb, ha) = HeaderBg
  ctx.pushSolid(header, color(hr, hg, hb, ha))
  let title = if app.lpane.slug.len > 0: "stats — " & app.lpane.slug
              else: "stats"
  ctx.pushLabel(cache, title,
                header.x + RowPadX,
                header.y + (header.h - 14) * 0.5'f32 - 5)

  if app.lpane.slug.len == 0 or app.lpane.fields.len == 0:
    let (dr, dg, db, da) = HelpDim
    discard (dr, dg, db, da)
    ctx.pushLabel(cache, "no car loaded",
                  pane.x + RowPadX, pane.y + HeaderH + 12)
    return

  let bottomStrip = rect(pane.x, pane.y + pane.h - ButtonStripH,
                         pane.w, ButtonStripH)
  ctx.pushSolid(bottomStrip, color(hr, hg, hb, ha))

  # Save button — right side of the bottom strip.
  let saveBtnW = 80.0'f32
  let saveBtnR = rect(bottomStrip.x + bottomStrip.w - saveBtnW - 10,
                      bottomStrip.y + 4,
                      saveBtnW, ButtonStripH - 8)
  let dirty = app.lpane.dirty
  let saveStyle = ButtonStyle(
    bg:       (if dirty: color(0.30, 0.55, 0.32) else: color(0.20, 0.22, 0.28)),
    bgHover:  (if dirty: color(0.36, 0.62, 0.38) else: color(0.26, 0.30, 0.36)),
    bgActive: (if dirty: color(0.42, 0.70, 0.44) else: color(0.32, 0.36, 0.42)),
    fg:       color(0.92, 0.94, 0.98))
  if button(ctx, cache, fieldWid(app.lpane.slug, "__save"), saveBtnR,
            "Save", saveStyle):
    saveLPane(app)
    result = true

  # Search bar between header and the scrollable form.
  let searchR = rect(pane.x + SearchPad,
                     pane.y + HeaderH + SearchPad,
                     pane.w - SearchPad * 2,
                     SearchH - SearchPad * 2)
  discard textInput(ctx, cache, searchWid(app.lpane.slug),
                    searchR, app.lpane.search)
  if app.lpane.search.text.len == 0:
    ctx.pushLabel(cache, "search…",
                  searchR.x + 8,
                  searchR.y + (searchR.h - 14) * 0.5'f32 - 5)

  let listR = rect(pane.x, pane.y + HeaderH + SearchH,
                   pane.w, pane.h - HeaderH - SearchH - ButtonStripH)

  let q = app.lpane.search.text.strip()
  var filtered: seq[int] = @[]
  for k in 0 ..< app.lpane.fields.len:
    if matchesSearch(q, app.lpane.fields[k].stat.field) or
       matchesSearch(q, app.lpane.fields[k].stat.column):
      filtered.add k

  let total = filtered.len
  let contentH = float32(total) * RowH

  consumeWheel(ctx, app.lpane.scroll, listR, RowH)
  clamp(app.lpane.scroll, contentH, listR.h)

  let (firstRow, lastRow) = visibleRange(app.lpane.scroll, RowH, listR.h, total)
  let usableH = listR.h - 2.0'f32
  # Layout: input pinned at fixed `inputX`; unit anchored to the right of
  # the input (immediately next to it); reset button further right; name
  # fills the remaining space on the left and marquee-scrolls when its
  # text would overflow the column.
  let labelLeft  = listR.x + RowPadX
  let inputX     = labelLeft + 0.45'f32 * listR.w        # ~45% in
  let unitX      = inputX + InputW + ColGap
  # Reset button parks at the pane's right edge so it sits clear of the
  # input column (and the unit text in between).
  let resetX     = listR.x + listR.w - ResetBtnW - RowPadX
  let labelRight = inputX - ColGap                        # right edge of name col

  let timeS = float32(SDL_GetTicks()) / 1000.0'f32

  for j in firstRow .. lastRow:
    if j < 0 or j >= total: continue
    let yOff = float32(j) * RowH - app.lpane.scroll.y
    if yOff < 0 or yOff + RowH > usableH: continue
    let fi = filtered[j]
    var f = addr app.lpane.fields[fi]
    let rowR = rect(listR.x, listR.y + yOff, listR.w, RowH)
    let textY = rowR.y + (rowR.h - 14) * 0.5'f32 - 1

    # field name — left-aligned in the [labelLeft, labelRight) column.
    # Long names marquee-scroll: the text rect is positioned in screen
    # space at a sliding x, and a scissor clip keeps it from bleeding
    # into adjacent columns.
    let labelClip = rect(labelLeft, rowR.y,
                         labelRight - labelLeft, rowR.h)
    let (nw, _) = cache.measureText(f[].stat.field)
    if nw <= labelClip.w:
      ctx.pushLabel(cache, f[].stat.field, labelLeft, textY)
    else:
      # Three-phase cycle: dwell at start → scroll to end → dwell at end
      # → reset. extraW is the distance the text has to travel for its
      # right edge to align with the column's right edge.
      let extraW = nw - labelClip.w
      let scrollDur = extraW / MarqueeSpeed
      let cycle = MarqueeDwell + scrollDur + MarqueeDwell
      let t = floorMod(timeS, cycle)
      var off: float32
      if t < MarqueeDwell:
        off = 0
      elif t < MarqueeDwell + scrollDur:
        off = (t - MarqueeDwell) * MarqueeSpeed
      else:
        off = extraW
      pushLabelClipped(ctx, cache, f[].stat.field,
                       labelLeft - off, textY, labelClip)

    # unit — anchored just right of the input box
    if f[].stat.unit.len > 0:
      ctx.pushLabel(cache, "(" & f[].stat.unit & ")", unitX, textY)
    if f[].overridden:
      let (mr, mg, mb, ma) = ModifiedDot
      ctx.pushCircle(rect(rowR.x + 4,
                          rowR.y + (rowR.h - 6) * 0.5'f32, 6, 6),
                     color(mr, mg, mb, ma))

    # text input field
    let inputR = rect(inputX, rowR.y + 6, InputW, rowR.h - 12)
    let id = fieldWid(app.lpane.slug, f[].stat.column)
    let prevText = f[].input.text
    let prevPending = f[].input.pendingEnter
    discard textInput(ctx, cache, id, inputR, f[].input)
    if f[].input.text != prevText:
      app.lpane.dirty = true
      f[].overridden = (f[].input.text != f[].original)
    # On Enter, clamp / round to step + flash on overflow.
    if f[].input.pendingEnter and not prevPending:
      case f[].stat.kind
      of eskInt:
        discard tryClamp(f[].input,
                         f[].stat.minVal, f[].stat.maxVal,
                         f[].stat.step, isInt = true)
      of eskFloat:
        discard tryClamp(f[].input,
                         f[].stat.minVal, f[].stat.maxVal,
                         f[].stat.step, isInt = false)
      of eskBool:
        let lc = f[].input.text.toLowerAscii
        if lc in ["1","true","yes","on"]: f[].input.text = "1"
        else: f[].input.text = "0"
        f[].input.cursor = f[].input.text.len
      else: discard
      app.lpane.dirty = true
      f[].overridden = (f[].input.text != f[].original)

    # reset-to-original button (small "↺" — fall back to "R")
    if f[].overridden:
      let resetR = rect(resetX, rowR.y + 6, ResetBtnW, rowR.h - 12)
      let resetStyle = ButtonStyle(
        bg:       color(0.20, 0.22, 0.28),
        bgHover:  color(0.30, 0.34, 0.42),
        bgActive: color(0.40, 0.44, 0.52),
        fg:       color(0.92, 0.94, 0.98))
      if button(ctx, cache, resetWid(app.lpane.slug, f[].stat.column),
                resetR, "R", resetStyle):
        resetLPaneField(app, fi)

  drawScrollbar(ctx, app.lpane.scroll, listR, contentH)
