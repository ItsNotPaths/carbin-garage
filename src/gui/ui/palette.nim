## Floating bottom-middle export palette. Renders only when an active
## working/ car is loaded; collapses to nothing otherwise. Layout (per
## `plans/well-ill-describe-it-quizzical-wilkes.md` § Architecture/Layers/4
## with 3c.4 restructure): centred over the dropup strip, ~50% wide ×
## ~15% tall. Three stacked rows:
##
##   [ name override .................................. ] [ Export ]
##   [ donor: AUD_R8GT_11 ] [ donor: <select donor> ] [ ... per game ]
##   [ FH1 ✓ ]              [ FM4   ]                [ ... per game ]
##
## Top row is shared across all toggled targets. Middle row shows the
## currently bound donor for each profile (or a "select donor" prompt);
## clicking a filled slot clears it. Donors are bound by right-clicking
## a car in the matching game's dropup popup → "Set as donor for <GAME>".
## Bottom row is a multi-select target toggle — greyed columns mean the
## profile has no registered mount.

import std/[hashes, strutils]
import context
import draw
import text as uitext
import button
import text_input
import ../state
import ../car_names

const
  PanelBg          = (0.10'f32, 0.12'f32, 0.16'f32, 0.95'f32)
  PanelBorder      = (0.30'f32, 0.32'f32, 0.38'f32, 1.0'f32)
  RowH             = 30.0'f32
  RowGap           = 6.0'f32
  PanelPadX        = 10.0'f32
  PanelPadY        = 8.0'f32
  ColGap           = 8.0'f32
  ExportBtnW       = 110.0'f32
  StatusH          = 26.0'f32
  StatusGap        = 6.0'f32
  PanelWFrac       = 0.50'f32          ## % of winW
  PanelMinW        = 480.0'f32
  PanelMaxW        = 760.0'f32
  BottomGap        = 12.0'f32          ## above the dropup strip

  ChipBg           = (0.18'f32, 0.20'f32, 0.24'f32, 1.0'f32)
  ChipHover        = (0.24'f32, 0.27'f32, 0.32'f32, 1.0'f32)
  ChipActive       = (0.30'f32, 0.34'f32, 0.42'f32, 1.0'f32)
  ChipDimBg        = (0.12'f32, 0.13'f32, 0.16'f32, 1.0'f32)
  ChipDimFg        = (0.40'f32, 0.42'f32, 0.48'f32, 1.0'f32)

  TargetOnBg       = (0.30'f32, 0.55'f32, 0.32'f32, 1.0'f32)
  TargetOnHover    = (0.36'f32, 0.62'f32, 0.38'f32, 1.0'f32)
  TargetOnActive   = (0.42'f32, 0.70'f32, 0.44'f32, 1.0'f32)

  DonorBoundBg     = (0.20'f32, 0.32'f32, 0.42'f32, 1.0'f32)
  DonorBoundHover  = (0.26'f32, 0.40'f32, 0.52'f32, 1.0'f32)
  DonorBoundActive = (0.32'f32, 0.48'f32, 0.62'f32, 1.0'f32)

  ExportEnabled    = (0.30'f32, 0.55'f32, 0.32'f32, 1.0'f32)
  ExportEnabledH   = (0.36'f32, 0.62'f32, 0.38'f32, 1.0'f32)
  ExportEnabledA   = (0.42'f32, 0.70'f32, 0.44'f32, 1.0'f32)
  ExportDisabled   = (0.20'f32, 0.22'f32, 0.28'f32, 1.0'f32)

  StatusOkBg       = (0.10'f32, 0.30'f32, 0.18'f32, 0.92'f32)
  StatusErrBg      = (0.40'f32, 0.18'f32, 0.18'f32, 0.92'f32)

proc wid(label: string): WidgetId = WidgetId(hash("palette." & label))

proc paletteRect*(winW, winH, dropupH: float32): Rect =
  ## Centred above the dropup strip. Height fixed at three rows.
  let panelH = PanelPadY * 2 + RowH * 3 + RowGap * 2
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
  if not anyTargetOn(app):
    return (false, "toggle at least one target game")
  for gid in allProfileIds(app):
    if not targetOn(app, gid): continue
    if donorBound(app, gid).len == 0:
      return (false,
        "donor not set for " & gid.toUpperAscii() &
        " (right-click a car in its popup)")
  (true, "")

type
  PaletteResult* = object
    exportPressed*: bool

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

  let leftX  = pane.x + PanelPadX
  let rightX = pane.x + pane.w - PanelPadX
  let row1Y  = pane.y + PanelPadY
  let row2Y  = row1Y + RowH + RowGap
  let row3Y  = row2Y + RowH + RowGap

  # ---- Top row: name override + Export ----
  let exportR = rect(rightX - ExportBtnW, row1Y, ExportBtnW, RowH)
  let nameR   = rect(leftX, row1Y,
                     exportR.x - ColGap - leftX, RowH)
  discard textInput(ctx, cache, wid("name"), nameR, app.palette.newName)
  if app.palette.newName.text.len == 0:
    ctx.pushLabel(cache,
                  "name override (default: " &
                    prettyDisplayName(app.activeSlug) & ")",
                  nameR.x + 8,
                  nameR.y + (nameR.h - 14) * 0.5'f32 - 5)

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

  # ---- Per-profile columns: donor slot (row 2) + target toggle (row 3) ----
  let profiles = allProfileIds(app)
  if profiles.len == 0:
    ctx.pushLabel(cache, "no game profiles installed",
                  leftX, row2Y + (RowH - 14) * 0.5'f32 - 5)
    return

  let totalColsW = pane.w - PanelPadX * 2
  let colGapTotal = ColGap * float32(max(0, profiles.len - 1))
  let colW = (totalColsW - colGapTotal) / float32(profiles.len)

  for i, gid in profiles:
    let colX = leftX + float32(i) * (colW + ColGap)
    let donorR  = rect(colX, row2Y, colW, RowH)
    let toggleR = rect(colX, row3Y, colW, RowH)
    let mounted = profileMounted(app, gid)
    let donor   = donorBound(app, gid)

    # ----- Donor slot (middle row) -----
    if not mounted:
      let dimStyle = ButtonStyle(
        bg:       color(ChipDimBg[0], ChipDimBg[1], ChipDimBg[2],
                         ChipDimBg[3]),
        bgHover:  color(ChipDimBg[0], ChipDimBg[1], ChipDimBg[2],
                         ChipDimBg[3]),
        bgActive: color(ChipDimBg[0], ChipDimBg[1], ChipDimBg[2],
                         ChipDimBg[3]),
        fg:       color(ChipDimFg[0], ChipDimFg[1], ChipDimFg[2],
                         ChipDimFg[3]))
      discard button(ctx, cache, wid("donor." & gid),
                     donorR, "(no mount)", dimStyle)
    elif donor.len > 0:
      let boundStyle = ButtonStyle(
        bg:       color(DonorBoundBg[0], DonorBoundBg[1],
                         DonorBoundBg[2], DonorBoundBg[3]),
        bgHover:  color(DonorBoundHover[0], DonorBoundHover[1],
                         DonorBoundHover[2], DonorBoundHover[3]),
        bgActive: color(DonorBoundActive[0], DonorBoundActive[1],
                         DonorBoundActive[2], DonorBoundActive[3]),
        fg:       color(0.92, 0.96, 1.0))
      if button(ctx, cache, wid("donor." & gid),
                donorR, prettyDisplayName(donor), boundStyle):
        clearDonor(app, gid)
    else:
      let promptStyle = ButtonStyle(
        bg:       color(ChipBg[0], ChipBg[1], ChipBg[2], ChipBg[3]),
        bgHover:  color(ChipHover[0], ChipHover[1], ChipHover[2],
                         ChipHover[3]),
        bgActive: color(ChipActive[0], ChipActive[1], ChipActive[2],
                         ChipActive[3]),
        fg:       color(0.70, 0.74, 0.80))
      # Non-clickable behaviourally — but rendered as a button for
      # visual consistency with the bound state. We don't act on the
      # click; the user binds via right-click in the dropup.
      discard button(ctx, cache, wid("donor." & gid),
                     donorR, "select donor", promptStyle)

    # ----- Target toggle (bottom row) -----
    let label = gid.toUpperAscii() &
                (if mounted and targetOn(app, gid): "  ✓" else: "")
    if not mounted:
      let dimStyle = ButtonStyle(
        bg:       color(ChipDimBg[0], ChipDimBg[1], ChipDimBg[2],
                         ChipDimBg[3]),
        bgHover:  color(ChipDimBg[0], ChipDimBg[1], ChipDimBg[2],
                         ChipDimBg[3]),
        bgActive: color(ChipDimBg[0], ChipDimBg[1], ChipDimBg[2],
                         ChipDimBg[3]),
        fg:       color(ChipDimFg[0], ChipDimFg[1], ChipDimFg[2],
                         ChipDimFg[3]))
      discard button(ctx, cache, wid("target." & gid),
                     toggleR, gid.toUpperAscii(), dimStyle)
    else:
      let on = targetOn(app, gid)
      let style =
        if on:
          ButtonStyle(
            bg:       color(TargetOnBg[0], TargetOnBg[1],
                             TargetOnBg[2], TargetOnBg[3]),
            bgHover:  color(TargetOnHover[0], TargetOnHover[1],
                             TargetOnHover[2], TargetOnHover[3]),
            bgActive: color(TargetOnActive[0], TargetOnActive[1],
                             TargetOnActive[2], TargetOnActive[3]),
            fg:       color(0.96, 0.98, 0.96))
        else:
          ButtonStyle(
            bg:       color(ChipBg[0], ChipBg[1], ChipBg[2], ChipBg[3]),
            bgHover:  color(ChipHover[0], ChipHover[1], ChipHover[2],
                             ChipHover[3]),
            bgActive: color(ChipActive[0], ChipActive[1], ChipActive[2],
                             ChipActive[3]),
            fg:       color(0.92, 0.94, 0.98))
      if button(ctx, cache, wid("target." & gid), toggleR, label, style):
        toggleTarget(app, gid)

  # ---- Status banner ----
  if app.palette.statusMsg.len > 0:
    let (sr, sg, sb, sa) =
      if app.palette.statusOk: StatusOkBg else: StatusErrBg
    let banner = rect(pane.x, pane.y - StatusH - StatusGap,
                      pane.w, StatusH)
    ctx.pushSolid(banner, color(sr, sg, sb, sa))
    ctx.pushLabel(cache, app.palette.statusMsg,
                  banner.x + PanelPadX,
                  banner.y + (banner.h - 14) * 0.5'f32 - 5)
