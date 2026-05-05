## Floating bottom-middle export palette. Renders only when an active
## working/ car is loaded; collapses to nothing otherwise. Layout (per
## `plans/well-ill-describe-it-quizzical-wilkes.md` § Architecture/Layers/4):
## centred over the dropup strip, ~50% wide × 5% tall.
##
## Widget owns no I/O — clicking Export sets `paletteExportRequested = true`
## on AppState and the caller (gui/app.nim) dispatches the actual port.
##
## Status toast: fade-after-N-seconds banner anchored under the palette,
## written to by `state.setPaletteStatus`.

import std/[hashes, strutils]
import context
import draw
import text as uitext
import button
import text_input
import modal
import ../state

const
  PanelBg          = (0.10'f32, 0.12'f32, 0.16'f32, 0.95'f32)
  PanelBorder      = (0.30'f32, 0.32'f32, 0.38'f32, 1.0'f32)
  RowH             = 30.0'f32
  RowGap           = 6.0'f32
  PanelPadX        = 10.0'f32
  PanelPadY        = 8.0'f32
  ChipW            = 72.0'f32
  ChevronW         = 28.0'f32
  ExportBtnW       = 110.0'f32
  ColGap           = 8.0'f32
  StatusH          = 26.0'f32
  StatusGap        = 6.0'f32
  PanelWFrac       = 0.50'f32          ## % of winW
  PanelMinW        = 480.0'f32
  PanelMaxW        = 760.0'f32
  BottomGap        = 12.0'f32          ## above the dropup strip

  TargetChipBg     = (0.18'f32, 0.20'f32, 0.24'f32, 1.0'f32)
  TargetChipHover  = (0.24'f32, 0.27'f32, 0.32'f32, 1.0'f32)
  TargetChipActive = (0.30'f32, 0.34'f32, 0.42'f32, 1.0'f32)

  ExportEnabled    = (0.30'f32, 0.55'f32, 0.32'f32, 1.0'f32)
  ExportEnabledH   = (0.36'f32, 0.62'f32, 0.38'f32, 1.0'f32)
  ExportEnabledA   = (0.42'f32, 0.70'f32, 0.44'f32, 1.0'f32)
  ExportDisabled   = (0.20'f32, 0.22'f32, 0.28'f32, 1.0'f32)

  StatusOkBg       = (0.10'f32, 0.30'f32, 0.18'f32, 0.92'f32)
  StatusErrBg      = (0.40'f32, 0.18'f32, 0.18'f32, 0.92'f32)

proc wid(label: string): WidgetId = WidgetId(hash("palette." & label))

proc paletteRect*(winW, winH, dropupH: float32;
                  expanded: bool): Rect =
  ## Centred above the dropup strip. Height grows when the advanced row
  ## is shown — the bottom edge stays anchored to (dropupH + BottomGap).
  let baseH = PanelPadY * 2 + RowH
  let panelH = if expanded: baseH + RowH + RowGap else: baseH
  var w = winW * PanelWFrac
  if w < PanelMinW: w = PanelMinW
  if w > PanelMaxW: w = PanelMaxW
  if w > winW - 16: w = winW - 16
  let x = (winW - w) * 0.5'f32
  let y = winH - dropupH - BottomGap - panelH
  rect(x, y, w, panelH)

proc canExport(app: AppState): tuple[ok: bool; reason: string] =
  if app.activeSlug.len == 0:
    return (false, "load a working car")
  if app.cfg.xeniaContent.strip.len == 0:
    return (false, "set xenia content path in Settings")
  if app.palette.targetGame.len == 0:
    return (false, "register a game mount")
  if app.palette.donor.text.strip.len == 0:
    return (false, "donor required (existing car in target game)")
  (true, "")

type
  PaletteResult* = object
    exportPressed*: bool

proc drawChevron(ctx: var UiContext; r: Rect; expanded: bool) =
  ## Tiny up/down arrow rasterised as a small triangle of solid quads.
  ## SDL3 GPU draw list has no triangle primitive — we approximate with
  ## three short horizontal bars that taper toward the apex.
  let cx = r.x + r.w * 0.5'f32
  let cy = r.y + r.h * 0.5'f32
  let col = color(0.78, 0.82, 0.88, 1.0)
  let bars = 3
  for i in 0 ..< bars:
    let halfW = float32(bars - i) * 2.0'f32
    let yy =
      if expanded: cy + 4 - float32(i) * 2.0'f32   # ▼
      else: cy - 4 + float32(i) * 2.0'f32           # ▲
    ctx.pushSolid(rect(cx - halfW, yy, halfW * 2, 2.0'f32), col)

proc drawPalette*(ctx: var UiContext; cache: var TextCache;
                  app: var AppState; pane: Rect): PaletteResult =
  ## Returns exportPressed=true on the single frame the user clicks Export.
  result = PaletteResult()
  if app.activeSlug.len == 0: return

  let (br, bg, bb, ba) = PanelBorder
  ctx.pushSolid(rect(pane.x - 1, pane.y - 1, pane.w + 2, pane.h + 2),
                color(br, bg, bb, ba))
  let (pr, pg, pb, pa) = PanelBg
  ctx.pushSolid(pane, color(pr, pg, pb, pa))

  # Top row layout:
  #   [target chip] [donor input ........] [chevron] [Export button]
  let topY = pane.y + PanelPadY
  let leftX = pane.x + PanelPadX
  let rightX = pane.x + pane.w - PanelPadX

  let chipR = rect(leftX, topY, ChipW, RowH)
  let exportR = rect(rightX - ExportBtnW, topY, ExportBtnW, RowH)
  let chevR = rect(exportR.x - ColGap - ChevronW, topY, ChevronW, RowH)
  let donorX = chipR.x + chipR.w + ColGap
  let donorW = chevR.x - ColGap - donorX
  let donorR = rect(donorX, topY, max(60.0'f32, donorW), RowH)

  # Target-game cycler chip — "FH1 ▸" style, click cycles next mount.
  let chipLabel =
    if app.palette.targetGame.len == 0: "—"
    else: app.palette.targetGame.toUpperAscii()
  let chipStyle = ButtonStyle(
    bg:       color(TargetChipBg[0], TargetChipBg[1], TargetChipBg[2],
                     TargetChipBg[3]),
    bgHover:  color(TargetChipHover[0], TargetChipHover[1],
                     TargetChipHover[2], TargetChipHover[3]),
    bgActive: color(TargetChipActive[0], TargetChipActive[1],
                     TargetChipActive[2], TargetChipActive[3]),
    fg:       color(0.92, 0.94, 0.98))
  if button(ctx, cache, wid("target"), chipR, chipLabel, chipStyle):
    cyclePaletteTarget(app)

  # Donor input — placeholder hint when empty.
  discard textInput(ctx, cache, wid("donor"), donorR, app.palette.donor)
  if app.palette.donor.text.len == 0:
    ctx.pushLabel(cache, "donor (target-game slug, e.g. AUD_R8GT_11)",
                  donorR.x + 8,
                  donorR.y + (donorR.h - 14) * 0.5'f32 - 5)

  # Chevron toggles advanced row.
  ctx.pushSolid(chevR, color(TargetChipBg[0], TargetChipBg[1],
                              TargetChipBg[2], TargetChipBg[3]))
  let chevId = wid("chevron")
  if chevR.contains(ctx.mouseX, ctx.mouseY) and not ctx.inputBlocked:
    ctx.hotId = chevId
    if ctx.mouseClicked[0]:
      app.palette.expanded = not app.palette.expanded
  drawChevron(ctx, chevR, app.palette.expanded)

  # Export button — green when ready, grey + disabled otherwise.
  let canExp = canExport(app)
  let exportStyle =
    if canExp.ok:
      ButtonStyle(
        bg:       color(ExportEnabled[0], ExportEnabled[1],
                         ExportEnabled[2], ExportEnabled[3]),
        bgHover:  color(ExportEnabledH[0], ExportEnabledH[1],
                         ExportEnabledH[2], ExportEnabledH[3]),
        bgActive: color(ExportEnabledA[0], ExportEnabledA[1],
                         ExportEnabledA[2], ExportEnabledA[3]),
        fg:       color(0.96, 0.98, 0.96))
    else:
      ButtonStyle(
        bg:       color(ExportDisabled[0], ExportDisabled[1],
                         ExportDisabled[2], ExportDisabled[3]),
        bgHover:  color(ExportDisabled[0], ExportDisabled[1],
                         ExportDisabled[2], ExportDisabled[3]),
        bgActive: color(ExportDisabled[0], ExportDisabled[1],
                         ExportDisabled[2], ExportDisabled[3]),
        fg:       color(0.55, 0.58, 0.65))
  if button(ctx, cache, wid("export"), exportR, "Export", exportStyle):
    if canExp.ok:
      result.exportPressed = true
    else:
      setPaletteStatus(app, canExp.reason, ok = false)

  # Advanced row (animated): name + dlc-id inputs.
  modal.tickFraction(app.palette.expandFrac, app.palette.expanded, ctx.dt)
  if app.palette.expandFrac > 0:
    let row2Y = pane.y + PanelPadY + RowH + RowGap
    let halfW = (pane.w - PanelPadX * 2 - ColGap) * 0.5'f32
    let nameR = rect(leftX, row2Y, halfW, RowH)
    let dlcR  = rect(leftX + halfW + ColGap, row2Y, halfW, RowH)
    discard textInput(ctx, cache, wid("name"), nameR, app.palette.newName)
    if app.palette.newName.text.len == 0:
      ctx.pushLabel(cache,
                    "name override (default: " & app.activeSlug & ")",
                    nameR.x + 8,
                    nameR.y + (nameR.h - 14) * 0.5'f32 - 5)
    discard textInput(ctx, cache, wid("dlc"), dlcR, app.palette.dlcId)
    if app.palette.dlcId.text.len == 0:
      ctx.pushLabel(cache, "dlc-id (default: hash of name)",
                    dlcR.x + 8,
                    dlcR.y + (dlcR.h - 14) * 0.5'f32 - 5)

  # Status banner floats above the palette so it doesn't crash into the
  # dropup strip below. Auto-fades via tickPaletteStatus in app.nim.
  if app.palette.statusMsg.len > 0:
    let (sr, sg, sb, sa) =
      if app.palette.statusOk: StatusOkBg else: StatusErrBg
    let banner = rect(pane.x, pane.y - StatusH - StatusGap,
                      pane.w, StatusH)
    ctx.pushSolid(banner, color(sr, sg, sb, sa))
    ctx.pushLabel(cache, app.palette.statusMsg,
                  banner.x + PanelPadX,
                  banner.y + (banner.h - 14) * 0.5'f32 - 5)
