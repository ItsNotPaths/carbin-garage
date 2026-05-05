## Settings panel content. The slide-down modal frame lives in app.nim;
## this module fills it.
##
## Phase 3a scope: a mounts list with per-row Remove buttons. Add-mount
## requires either a folder picker or a text-input widget — neither is
## wired yet, so the panel surfaces the CLI hint instead. Save & Close
## commits any removals to mounts.json and reloads sources.
##
## 3c.3 added a single configurable field at the top — the xenia content
## directory used by port-to-dlc. Persisted to
## ~/.config/carbin-garage/config.json via core/appconfig.

import std/[hashes, strformat, strutils]
import context
import draw
import text as uitext
import button
import text_input
import ../state
import ../../carbin_garage/core/[mounts, appconfig]

const
  RowH       = 32.0'f32
  RowPadX    = 24.0'f32
  RemoveW    = 80.0'f32
  HeaderY    = 24.0'f32
  ContentRowY = 56.0'f32
  ContentRowH = 28.0'f32
  ContentLabelW = 160.0'f32
  HintY      = 96.0'f32
  ListTopY   = 130.0'f32
  CloseStripFrac = 0.025'f32   ## same height as the top settings strip
  CloseStripMin  = 24.0'f32

type
  SettingsState* = object
    initialized*: bool
    sessionMounts*: seq[Mount]   ## edited copy; commit replaces mounts.json
    sessionConfig*: AppConfig
    contentInput*: TextInputState

proc beginSession*(s: var SettingsState) =
  ## Snapshot mounts.json + config.json on settings-open so removals can be
  ## cancelled by simply not pressing Save & Close (we wipe the session on
  ## close).
  if not s.initialized:
    s.sessionMounts = loadMounts()
    s.sessionConfig = loadAppConfig()
    s.contentInput = TextInputState(text: s.sessionConfig.xeniaContent)
    s.contentInput.cursor = s.contentInput.text.len
    s.initialized = true

proc endSession*(s: var SettingsState; commit: bool; app: var AppState) =
  if commit:
    saveMounts(s.sessionMounts)
    s.sessionConfig.xeniaContent = s.contentInput.text.strip()
    saveAppConfig(s.sessionConfig)
    app.cfg = s.sessionConfig
    reloadSources(app)
  s.sessionMounts = @[]
  s.sessionConfig = AppConfig()
  s.contentInput = TextInputState()
  s.initialized = false

proc rowId(label: string; gameId: string): WidgetId =
  WidgetId(hash("settings." & label & "." & gameId))

proc drawSettingsPanel*(ctx: var UiContext; cache: var TextCache;
                        s: var SettingsState; panel: Rect;
                        app: var AppState; closing: var bool) =
  ctx.pushLabel(cache, "Settings", panel.x + RowPadX,
                panel.y + HeaderY)

  # xenia content path — single text-input row.
  let labelX  = panel.x + RowPadX
  let inputX  = labelX + ContentLabelW
  let inputW  = panel.w - 2 * RowPadX - ContentLabelW
  ctx.pushLabel(cache, "xenia content path:", labelX,
                panel.y + ContentRowY + 8)
  let contentR = rect(inputX, panel.y + ContentRowY,
                      inputW, ContentRowH)
  discard textInput(ctx, cache, rowId("content", ""),
                    contentR, s.contentInput)
  if s.contentInput.text.len == 0:
    ctx.pushLabel(cache,
                  "/path/to/xenia_canary/content (used by Export)",
                  contentR.x + 12,
                  contentR.y + (contentR.h - 14) * 0.5'f32 - 5)

  # Mounts hint + list.
  ctx.pushLabel(cache,
                "To add a mount, run: ./carbin-garage --cli mount <folder>",
                panel.x + RowPadX, panel.y + HintY)

  var i = 0
  while i < s.sessionMounts.len:
    let m = s.sessionMounts[i]
    let rowY = panel.y + ListTopY + float32(i) * (RowH + 8)
    let rowR = rect(panel.x + RowPadX, rowY,
                    panel.w - 2 * RowPadX, RowH)
    ctx.pushSolid(rowR, color(0.13, 0.15, 0.19))

    ctx.pushLabel(cache,
                  &"{m.gameId}    {m.folder}",
                  rowR.x + 12, rowR.y + 8)

    let removeR = rect(rowR.x + rowR.w - RemoveW - 8,
                       rowR.y + 4, RemoveW, RowH - 8)
    let removeStyle = ButtonStyle(
      bg:        color(0.45, 0.20, 0.20),
      bgHover:   color(0.55, 0.25, 0.25),
      bgActive:  color(0.65, 0.30, 0.30),
      fg:        color(0.96, 0.92, 0.92))
    if button(ctx, cache, rowId("remove", m.gameId),
              removeR, "Remove", removeStyle):
      s.sessionMounts.delete(i)
      continue
    inc i

  if s.sessionMounts.len == 0:
    ctx.pushLabel(cache, "(no mounts registered)",
                  panel.x + RowPadX, panel.y + ListTopY + 4)

  # Save & Close strip — full-width inverse of the top "settings" strip.
  let stripH = max(CloseStripMin, ctx.winH * CloseStripFrac)
  let closeR = rect(panel.x, panel.y + panel.h - stripH, panel.w, stripH)
  let closeStyle = ButtonStyle(
    bg:        color(0.14, 0.16, 0.20),
    bgHover:   color(0.18, 0.20, 0.25),
    bgActive:  color(0.24, 0.27, 0.34),
    fg:        color(0.92, 0.94, 0.98))
  if button(ctx, cache, rowId("close", ""), closeR, "save & close",
            closeStyle):
    closing = true
