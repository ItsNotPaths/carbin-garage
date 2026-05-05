## Horizontal tab strip. The leftmost tab is pinned (cannot be re-ordered
## or closed via the Close menu — the menu shows "Unload car" instead);
## later tabs are flexible. Right-click on any tab opens a caller-owned
## context menu via the returned `rightClicked` index.
##
## The widget is purely view + hit-testing. Caller owns:
##   - the seq[TabItem]        (pinned slot at index 0 if used)
##   - the current activeIdx   (passed in, returned modified)
##   - the context menu        (populated by caller from rightClicked idx)
##
## No drag-to-reorder yet — defer to polish.

import std/hashes
import context
import draw
import text as uitext

type
  TabItem* = object
    label*:    string      ## display text on the grabber
    pinned*:   bool        ## true for the active-car slot
    accent*:   bool        ## highlights tab even when not active (e.g. modified)

  TabsResult* = object
    active*:        int    ## 0..items.len-1, or -1 if no items
    rightClicked*:  int    ## -1 if none

const
  TabH*       = 26.0'f32
  TabPadX     = 14.0'f32
  TabGapX     = 2.0'f32
  TabMinW     = 70.0'f32
  TabMaxW     = 220.0'f32
  PinnedBgIdle    = (0.18'f32, 0.20'f32, 0.26'f32, 0.95'f32)
  PinnedBgActive  = (0.26'f32, 0.30'f32, 0.40'f32, 0.95'f32)
  TabBgIdle       = (0.12'f32, 0.14'f32, 0.18'f32, 0.95'f32)
  TabBgHover      = (0.18'f32, 0.20'f32, 0.26'f32, 0.95'f32)
  TabBgActive     = (0.22'f32, 0.26'f32, 0.36'f32, 0.95'f32)
  AccentDot       = (0.95'f32, 0.70'f32, 0.20'f32, 1.0'f32)
  PinIndicator    = (0.55'f32, 0.70'f32, 0.95'f32, 1.0'f32)

proc tabWid(label: string; idx: int): WidgetId =
  WidgetId(hash("tab." & $idx & "/" & label))

proc measureTabW(cache: var TextCache; label: string): float32 =
  let (w, _) = cache.measureText(label)
  result = w + TabPadX * 2
  if result < TabMinW: result = TabMinW
  if result > TabMaxW: result = TabMaxW

proc drawTabStrip*(ctx: var UiContext; cache: var TextCache;
                   strip: Rect; items: openArray[TabItem];
                   activeIdx: int): TabsResult =
  ## Lays out tabs left-to-right inside `strip`. Clicks set `result.active`,
  ## right-clicks set `result.rightClicked`. The strip background is the
  ## caller's responsibility (R pane already paints it).
  result.active = activeIdx
  result.rightClicked = -1
  if items.len == 0:
    result.active = -1
    return

  var x = strip.x
  for i, it in items:
    let tw = measureTabW(cache, it.label)
    if x + tw > strip.x + strip.w: break    # naive overflow: clip; reorder/scroll deferred
    let r = rect(x, strip.y + (strip.h - TabH) * 0.5'f32, tw, TabH)
    let id = tabWid(it.label, i)
    let hovered = r.contains(ctx.mouseX, ctx.mouseY)
    let active = (i == activeIdx)

    let (br, bg, bb, ba) =
      if active and it.pinned: PinnedBgActive
      elif it.pinned:          PinnedBgIdle
      elif active:             TabBgActive
      elif hovered:            TabBgHover
      else:                    TabBgIdle
    ctx.pushSolid(r, color(br, bg, bb, ba))

    # pinned indicator: thin top stripe in accent blue
    if it.pinned:
      let (pr, pg, pb, pa) = PinIndicator
      ctx.pushSolid(rect(r.x, r.y, r.w, 2.0'f32), color(pr, pg, pb, pa))

    # accent dot (modified) — small square top-right
    if it.accent:
      let (ar, ag, ab, aa) = AccentDot
      ctx.pushSolid(rect(r.x + r.w - 8, r.y + 4, 4, 4),
                    color(ar, ag, ab, aa))

    ctx.pushLabel(cache, it.label, r.x + TabPadX,
                  r.y + (r.h - 14) * 0.5'f32 - 5)

    if (not ctx.inputBlocked) and hovered:
      ctx.hotId = id
      if ctx.mouseClicked[0]:
        result.active = i
      if ctx.mouseClicked[2]:
        result.rightClicked = i

    x += tw + TabGapX
