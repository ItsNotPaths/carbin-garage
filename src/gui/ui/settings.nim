## Settings panel content. The slide-down modal frame lives in app.nim;
## this module fills it.
##
## 3c.5 (2026-05-04 PM) restructure:
##   - Top: xenia content path (single text input).
##   - Per-game-profile rows: optional override path. Auto-detect resolves
##     `<xeniaContent>/0000000000000000/<TitleID>/00007000/<contentId>/`
##     and shows it as the input's placeholder; users only set an override
##     when their install lives somewhere weird. A non-empty override
##     becomes a manual mounts.json entry; clearing it falls back to
##     auto-detect.
##   - Experimental section: a damage-modelling-porting toggle (stub —
##     no consumer in the export pipeline yet; persists to AppConfig).
##
## Save & Close commits both mounts.json edits and AppConfig (xenia path
## + experimental flags), then reloads sources.

import std/[hashes, strutils, tables, times]
import context
import text as uitext
import button
import text_input
import ../state
import ../../carbin_garage/core/[mounts, profile, appconfig]
import ../../carbin_garage/orchestrator/dlc_clear

const
  RowH            = 32.0'f32
  RowPadX         = 24.0'f32
  HeaderY         = 24.0'f32

  ContentRowY     = 56.0'f32
  ContentRowH     = 28.0'f32
  ContentLabelW   = 200.0'f32      ## widened so "xenia content path:" never overlaps the input

  GamesHeaderY    = 100.0'f32
  GamesHintY      = 124.0'f32
  GamesListTopY   = 152.0'f32
  GameRowH        = 30.0'f32
  GameRowGap      = 8.0'f32
  GameLabelW      = 60.0'f32
  ClearBtnW       = 180.0'f32
  ClearBtnGap     = 8.0'f32
  ClearArmTimeout = 3.0                  ## seconds before "confirm" reverts
  ClearDlcEnabledFor = ["fh1"]           ## profiles whose DLC pipeline ships

  ExpSectionGap   = 28.0'f32       ## space above the Experimental section
  ExpHeaderH      = 24.0'f32
  ExpToggleH      = 30.0'f32

  CloseStripFrac  = 0.025'f32
  CloseStripMin   = 24.0'f32

type
  SettingsState* = object
    initialized*: bool
    sessionMounts*: seq[Mount]                  ## working copy of mounts.json
    sessionConfig*: AppConfig
    contentInput*: TextInputState
    perGameInputs*: Table[string, TextInputState]   ## profileId → override path
    profileIds*: seq[string]                    ## stable iteration order
    clearArmedAt*: Table[string, float]         ## profileId → epochTime() of 1st click
    clearLastCount*: Table[string, int]         ## profileId → packages removed last fire

proc rowId(label: string; gameId: string): WidgetId =
  WidgetId(hash("settings." & label & "." & gameId))

proc beginSession*(s: var SettingsState) =
  ## Snapshot mounts.json + config.json on settings-open so cancellation
  ## (close without Save) is just "drop the session". Pre-fills per-game
  ## inputs with whatever manual override mounts.json holds for each
  ## installed profile.
  if s.initialized: return
  s.sessionMounts = loadMounts()
  s.sessionConfig = loadAppConfig()
  s.contentInput = TextInputState(text: s.sessionConfig.xeniaContent)
  s.contentInput.cursor = s.contentInput.text.len
  s.profileIds = availableProfileIds()
  s.perGameInputs = initTable[string, TextInputState]()
  s.clearArmedAt = initTable[string, float]()
  s.clearLastCount = initTable[string, int]()
  for id in s.profileIds:
    var ti = TextInputState()
    let mi = findMount(s.sessionMounts, id)
    if mi >= 0: ti.text = s.sessionMounts[mi].folder
    ti.cursor = ti.text.len
    s.perGameInputs[id] = ti
  s.initialized = true

proc endSession*(s: var SettingsState; commit: bool; app: var AppState) =
  if commit:
    s.sessionConfig.xeniaContent = s.contentInput.text.strip()
    saveAppConfig(s.sessionConfig)
    app.cfg = s.sessionConfig
    # Reconcile per-game overrides into sessionMounts: empty input ⇒
    # remove from mounts.json (auto-detect takes over); non-empty ⇒
    # upsert. We don't validate the path here — invalid paths just won't
    # produce a Source in `effectiveMounts`, which is fine: the palette
    # column for that game will render greyed-out and the user can fix
    # it next time they open Settings.
    for id in s.profileIds:
      let txt = s.perGameInputs[id].text.strip()
      let mi = findMount(s.sessionMounts, id)
      if txt.len == 0:
        if mi >= 0: s.sessionMounts.delete(mi)
      else:
        if mi >= 0: s.sessionMounts[mi].folder = txt
        else:       s.sessionMounts.add Mount(gameId: id, folder: txt)
    saveMounts(s.sessionMounts)
    reloadSources(app)
  s.sessionMounts = @[]
  s.sessionConfig = AppConfig()
  s.contentInput = TextInputState()
  s.perGameInputs = initTable[string, TextInputState]()
  s.profileIds = @[]
  s.clearArmedAt = initTable[string, float]()
  s.clearLastCount = initTable[string, int]()
  s.initialized = false

proc autoPathFor(profileId, xeniaContent: string): string =
  if xeniaContent.strip().len == 0: return ""
  let prof =
    try: loadProfileById(profileId)
    except CatchableError: return ""
  autoMountFolder(xeniaContent.strip(), prof)

proc drawSettingsPanel*(ctx: var UiContext; cache: var TextCache;
                        s: var SettingsState; panel: Rect;
                        app: var AppState; closing: var bool) =
  ctx.pushLabel(cache, "Settings", panel.x + RowPadX,
                panel.y + HeaderY)

  # ---- xenia content path ----
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
                  "/path/to/xenia_canary/content (used by Export + auto-detect)",
                  contentR.x + 12,
                  contentR.y + (contentR.h - 14) * 0.5'f32 - 5)

  # ---- Per-game install paths ----
  ctx.pushLabel(cache, "Per-game install paths",
                panel.x + RowPadX, panel.y + GamesHeaderY)
  ctx.pushLabel(cache,
                "Optional — auto-detected from content/. " &
                "Override only if a game lives somewhere weird.",
                panel.x + RowPadX, panel.y + GamesHintY)

  let liveContent = s.contentInput.text.strip()
  let nowT = epochTime()
  var rowI = 0
  for id in s.profileIds:
    let rowY = panel.y + GamesListTopY +
               float32(rowI) * (GameRowH + GameRowGap)
    let labelR = rect(panel.x + RowPadX, rowY, GameLabelW, GameRowH)
    let inR = rect(labelR.x + GameLabelW,
                   rowY,
                   panel.w - RowPadX * 2 - GameLabelW -
                     ClearBtnW - ClearBtnGap,
                   GameRowH)
    let clearR = rect(inR.x + inR.w + ClearBtnGap, rowY,
                      ClearBtnW, GameRowH)
    ctx.pushLabel(cache, id.toUpperAscii(),
                  labelR.x, labelR.y + (labelR.h - 14) * 0.5'f32 - 5)
    var ti = addr s.perGameInputs[id]
    discard textInput(ctx, cache, rowId("game", id), inR, ti[])
    if ti[].text.len == 0:
      let auto = autoPathFor(id, liveContent)
      let placeholder =
        if auto.len > 0: "(auto: " & auto & ")"
        else: "(no auto-detect — set xenia content path or override here)"
      ctx.pushLabel(cache, placeholder,
                    inR.x + 12, inR.y + (inR.h - 14) * 0.5'f32 - 5)

    # ── Clear DLC button ────────────────────────────────────────────────
    # Enabled only for games whose DLC pipeline has shipped (today: FH1).
    # Greyed otherwise as a placeholder for when other games come online.
    let enabled = id in ClearDlcEnabledFor
    if s.clearArmedAt.hasKey(id) and
       nowT - s.clearArmedAt[id] > ClearArmTimeout:
      s.clearArmedAt.del(id)
    let armed = s.clearArmedAt.hasKey(id)
    let prof =
      try: loadProfileById(id)
      except CatchableError: GameProfile()
    let pkgCount =
      if enabled and liveContent.len > 0 and prof.titleId.len > 0:
        enumerateCarbinGarageDlcs(liveContent, prof).len
      else: 0
    let lastCount =
      if s.clearLastCount.hasKey(id): s.clearLastCount[id] else: -1
    let clearLabel =
      if not enabled:                  "Clear DLC"
      elif armed:                      "Confirm clear (" & $pkgCount & ")?"
      elif lastCount >= 0:             "Cleared " & $lastCount
      elif pkgCount > 0:               "Clear DLC (" & $pkgCount & ")"
      else:                            "Clear DLC"
    let clearStyle =
      if not enabled:
        ButtonStyle(
          bg:       color(0.12, 0.13, 0.16),
          bgHover:  color(0.12, 0.13, 0.16),
          bgActive: color(0.12, 0.13, 0.16),
          fg:       color(0.40, 0.42, 0.48))
      elif armed:
        ButtonStyle(
          bg:       color(0.55, 0.18, 0.18),
          bgHover:  color(0.66, 0.22, 0.22),
          bgActive: color(0.74, 0.26, 0.26),
          fg:       color(0.98, 0.94, 0.92))
      else:
        ButtonStyle(
          bg:       color(0.18, 0.20, 0.24),
          bgHover:  color(0.22, 0.25, 0.30),
          bgActive: color(0.28, 0.32, 0.40),
          fg:       color(0.92, 0.94, 0.98))
    let clicked = button(ctx, cache, rowId("clear", id),
                         clearR, clearLabel, clearStyle)
    if clicked and enabled:
      if armed:
        let removed = clearCarbinGarageDlcs(liveContent, prof)
        s.clearLastCount[id] = removed
        s.clearArmedAt.del(id)
        stderr.writeLine "settings: cleared " & $removed &
          " carbin-garage DLC package(s) for " & id
      else:
        if pkgCount > 0:
          s.clearArmedAt[id] = nowT
          s.clearLastCount.del(id)
    inc rowI

  let gamesBottomY = panel.y + GamesListTopY +
                     float32(max(0, s.profileIds.len)) * (GameRowH + GameRowGap)

  # ---- Experimental section ----
  let expHeaderY = gamesBottomY + ExpSectionGap
  ctx.pushLabel(cache, "Experimental",
                panel.x + RowPadX, expHeaderY)
  let toggleY = expHeaderY + ExpHeaderH
  let toggleR = rect(panel.x + RowPadX, toggleY,
                     panel.w - RowPadX * 2, ExpToggleH)
  let on = s.sessionConfig.experimentalDamage
  let toggleLabel =
    (if on: "[x] " else: "[ ] ") &
    "damage modelling porting (WIP — cross-game damage transfer)"
  let toggleStyle =
    if on:
      ButtonStyle(
        bg:       color(0.25, 0.18, 0.32),
        bgHover:  color(0.31, 0.22, 0.40),
        bgActive: color(0.37, 0.26, 0.48),
        fg:       color(0.94, 0.92, 0.98))
    else:
      ButtonStyle(
        bg:       color(0.13, 0.15, 0.19),
        bgHover:  color(0.18, 0.20, 0.25),
        bgActive: color(0.22, 0.25, 0.30),
        fg:       color(0.78, 0.82, 0.88))
  if button(ctx, cache, rowId("exp_damage", ""),
            toggleR, toggleLabel, toggleStyle):
    s.sessionConfig.experimentalDamage = not s.sessionConfig.experimentalDamage

  # ---- Save & Close strip ----
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
