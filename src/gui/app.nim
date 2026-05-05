## SDL3 GUI entry point. Phase 3a frame loop with hand-rolled widgets:
## window + GPU device + UI pipelines + font + per-frame mouse polling +
## a clickable top settings slice that drops a modal panel.

import std/[hashes, os, strformat, strutils]
import ../render/platform/sdl3
import ../render/text as rendertext
import ui/context
import ui/draw
import ui/render
import ui/text as uitext
import ui/button
import ui/modal
import ui/dropup
import ui/settings
import ui/menu as uimenu
import ui/rpane
import ui/lpane
import ui/palette
import scene3d
import state
import car_names
import ../carbin_garage/core/[workspace, part_swap, profile, mounts]
import ../carbin_garage/orchestrator/[importwc, portto_dlc]

const
  WindowTitle = "carbin-garage"
  WindowW = 1280
  WindowH = 800
  TickIdleMs = 16
  FontData = staticRead("../../vendor/fonts/SpaceMono-Regular.ttf")
  FontPtSize = 16'f32

proc die(msg: string) =
  stderr.writeLine "fatal: " & msg
  quit(1)

proc wid(s: string): WidgetId =
  ## Stable WidgetId from a label string. Hand-rolled widget IDs need to be
  ## stable across frames so hot/active tracking works.
  WidgetId(hash(s))

type
  AppFrame = object
    settingsOpen: bool
    settingsFrac: float32
    settings: SettingsState
    menu: uimenu.ContextMenu
    prevMouseDown: array[3, bool]
    prevMouseX, prevMouseY: float32
    mouseInited: bool

proc sampleMouse(ctx: var UiContext; frame: var AppFrame) =
  var mx, my: cfloat
  let mask = SDL_GetMouseState(addr mx, addr my)
  ctx.mouseX = float32(mx)
  ctx.mouseY = float32(my)
  let cur = [
    (mask and SDL_BUTTON_LMASK) != 0,
    (mask and SDL_BUTTON_MMASK) != 0,
    (mask and SDL_BUTTON_RMASK) != 0,
  ]
  for i in 0..2:
    ctx.mouseDown[i]     = cur[i]
    ctx.mouseClicked[i]  = cur[i] and not frame.prevMouseDown[i]
    ctx.mouseReleased[i] = (not cur[i]) and frame.prevMouseDown[i]
  frame.prevMouseDown = cur

proc dispatchMenu(menu: var uimenu.ContextMenu; choice: int;
                  app: var AppState; scene: var Scene3D;
                  dev: ptr SDL_GPUDevice) =
  ## Routes the chosen menu item by label. Tab right-clicks carry their
  ## tabIdx in `menu.sourceIdx` and a "tab::<slug>" prefix in rowName so
  ## we can disambiguate from car-row clicks.
  if choice < 0: return
  let label = menu.items[choice].label
  let isTabAction = menu.rowName.startsWith("tab::")

  if label == "Load from working/":
    let gltfPath = app.workingRoot / menu.rowName / "car.gltf"
    if not fileExists(gltfPath):
      stderr.writeLine &"loadCar: {gltfPath} not found"
      return
    try:
      if scene.loadCar(dev, gltfPath):
        app.activeSlug = menu.rowName
        ensurePinnedTab(app)
        stderr.writeLine &"loaded car: {gltfPath}"
    except CatchableError as e:
      stderr.writeLine &"loadCar failed for {gltfPath}: {e.msg}"
  elif label == "Import to working/":
    # menu.sourceIdx is the dropup tile (Source) index; menu.rowName is the
    # car name within that source. Import is blocking and runs on the UI
    # thread; the brief hitch is acceptable for now (worker-thread is a
    # later phase).
    if menu.sourceIdx < 0 or menu.sourceIdx >= app.sources.len: return
    let src = app.sources[menu.sourceIdx]
    var zipPath = ""
    for r in src.cars:
      if r.name == menu.rowName:
        zipPath = r.sourcePath
        break
    if zipPath.len == 0 or not fileExists(zipPath):
      stderr.writeLine &"import: no backing zip for {menu.rowName}"
      return
    try:
      let prof = loadProfileById(src.profileId)
      # Default the working/ folder name to the prefixed pretty form so
      # users can tell at a glance which game an imported car came from
      # (`[fh1] Alfa Romeo 8C 2008` instead of bare `ALF_8C_08`).
      let folderName = defaultWorkingFolderName(menu.rowName, prof.id)
      let dst = importToWorking(zipPath, prof, app.workingRoot, folderName)
      stderr.writeLine &"imported: {zipPath} -> {dst}"
      reloadSources(app)
    except CatchableError as e:
      stderr.writeLine &"import failed for {zipPath}: {e.msg}"
  elif label == "Open parts tab":
    openPartsTab(app, menu.rowName)
  elif label.startsWith("Set as donor for "):
    # rowName is the donor carname; sourceIdx points at the dropup tile
    # (Source). Pull the profileId off that source so we don't have to
    # parse it back out of the menu label.
    if menu.sourceIdx < 0 or menu.sourceIdx >= app.sources.len: return
    let src = app.sources[menu.sourceIdx]
    setDonor(app, src.profileId, menu.rowName)
  elif label == "Close tab" and isTabAction:
    closePartsTab(app, menu.sourceIdx)
  elif label == "Unload car" and isTabAction:
    if app.lpane.dirty:
      stderr.writeLine "lpane has unsaved edits — auto-saving before unload"
      saveLPane(app)
    scene.unloadCar(dev)
    app.activeSlug = ""
    ensurePinnedTab(app)
  elif label == "Grab part":
    # rowName format from rpane: "<slug>::<partName>"; sourceIdx is the
    # part index inside the active tab so we can pull lodKind+section.
    let sep = menu.rowName.find("::")
    if sep < 0: return
    let slug = menu.rowName[0 ..< sep]
    let partName = menu.rowName[sep+2 .. ^1]
    var lodKind = ""
    var section = partName
    let ti = partsTabIndex(app, slug)
    if ti >= 0 and menu.sourceIdx >= 0 and
       menu.sourceIdx < app.partsTabs[ti].parts.len:
      let pr = app.partsTabs[ti].parts[menu.sourceIdx]
      lodKind = pr.lodKind
      section = pr.section
    app.grab = GrabSlot(active: true, donorSlug: slug, partName: partName,
                        lodKind: lodKind, section: section)
    stderr.writeLine &"grab: {slug}::{partName} ({lodKind})"
  elif label == "Replace with grabbed":
    # Pinned-tab-only target enforced by menuItemsForPart. Snapshot host's
    # mutable artefacts, run the swap, append an edits[] entry, refresh
    # the parts list + 3D scene.
    let sep = menu.rowName.find("::")
    if sep < 0: return
    let hostSlug = menu.rowName[0 ..< sep]
    let hostPart = menu.rowName[sep+2 .. ^1]
    if not app.grab.active: return
    let donorSlug = app.grab.donorSlug
    let donorPart = app.grab.partName
    try:
      discard snapshotForUndo(app.workingRoot, hostSlug)
      applyPartSwap(app.workingRoot, donorSlug, donorPart,
                    hostSlug, hostPart)
      var manifest = readCarSlot(app.workingRoot, hostSlug)
      appendEdit(manifest, kind = "part_swap",
                 note = hostPart & ":=" & donorSlug & "/" & donorPart)
      writeCarSlot(app.workingRoot, hostSlug, manifest)
      # Refresh the pinned tab's parts list + reload the scene mesh.
      let pi = partsTabIndex(app, hostSlug)
      if pi >= 0:
        for j in 0 ..< app.partsTabs[pi].parts.len:
          if app.partsTabs[pi].parts[j].name == hostPart:
            app.partsTabs[pi].parts[j].modified = true
      let gltfPath = app.workingRoot / hostSlug / "car.gltf"
      if fileExists(gltfPath):
        discard scene.loadCar(dev, gltfPath)
      stderr.writeLine &"part_swap ok: {hostSlug}::{hostPart} := " &
                       &"{donorSlug}::{donorPart}"
    except CatchableError as e:
      stderr.writeLine &"part_swap failed: {e.msg}"
    app.grab.active = false

proc dispatchExport(app: var AppState) =
  ## Multi-target port-to-dlc: iterates every toggled-on game, requires a
  ## donor bound for each, runs `executePortToDlc` once per target. Blocks
  ## the UI thread — same pattern as Import-to-working/. Result toast
  ## summarises succeeded targets; first-failure short-circuits with the
  ## error message. Auto-synthesizes the dlc-id (`synthDlcId`); user does
  ## not see or set it.
  if app.activeSlug.len == 0: return
  let workingCar = app.workingRoot / app.activeSlug
  let newName    = app.palette.newName.text.strip()
  let contentRoot = app.cfg.xeniaContent.strip()

  if contentRoot.len == 0:
    setPaletteStatus(app, "set xenia content path in Settings", ok = false)
    return

  var targets: seq[string] = @[]
  for gid in allProfileIds(app):
    if targetOn(app, gid): targets.add gid
  if targets.len == 0:
    setPaletteStatus(app, "toggle at least one target game", ok = false)
    return

  # Pre-flight: every toggled target needs a bound donor.
  for gid in targets:
    if donorBound(app, gid).len == 0:
      setPaletteStatus(app,
        "donor not set for " & gid.toUpperAscii() &
        " (right-click a car in its popup → Set as donor)",
        ok = false)
      return

  let mountsAll = effectiveMounts(contentRoot)
  var done: seq[string] = @[]
  for gid in targets:
    let mi = findMount(mountsAll, gid)
    if mi < 0:
      setPaletteStatus(app,
        "no mount registered for " & gid.toUpperAscii(), ok = false)
      return
    let prof =
      try: loadProfileById(gid)
      except CatchableError as e:
        setPaletteStatus(app,
          gid.toUpperAscii() & ": profile load failed: " & e.msg,
          ok = false)
        return
    let donor = donorBound(app, gid)
    try:
      let plan = planPortToDlc(workingCar, mountsAll[mi], prof,
                                contentRoot, donor, newName,
                                "0000000000000000", 0, 0, 0)
      executePortToDlc(plan, replace = true, skipMergeSlt = false)
      done.add gid.toUpperAscii()
    except DlcPortError as e:
      setPaletteStatus(app,
        gid.toUpperAscii() & ": export failed: " & e.msg, ok = false)
      return
    except CatchableError as e:
      setPaletteStatus(app,
        gid.toUpperAscii() & ": export error: " & e.msg, ok = false)
      return

  let final = if newName.len > 0: newName else: app.activeSlug
  setPaletteStatus(app,
    "Exported " & final & " -> " & done.join(", "),
    ok = true)

const
  SDLK_ESCAPE = 0x0000001B'u32
  SDLK_S      = 0x00000073'u32
  KMOD_LCTRL  = 0x0040'u16
  KMOD_RCTRL  = 0x0080'u16

proc handleGlobalShortcuts(ctx: var UiContext; app: var AppState) =
  ## Esc clears an active grab; Ctrl+S saves L pane edits.
  if ctx.keys.len == 0: return
  for k in ctx.keys:
    if k.key == SDLK_ESCAPE and app.grab.active:
      app.grab.active = false
    elif k.key == SDLK_S and (k.`mod` and (KMOD_LCTRL or KMOD_RCTRL)) != 0:
      saveLPane(app)

proc buildFrame(ctx: var UiContext; cache: var TextCache;
                frame: var AppFrame; app: var AppState;
                scene: var Scene3D; dev: ptr SDL_GPUDevice) =
  handleGlobalShortcuts(ctx, app)
  let stripH = ctx.winH * 0.025'f32
  let dropupH = ctx.winH * 0.025'f32  # bottom strip uses the same fraction
  let menuOpenAtStart = frame.menu.open

  # Pre-pass: if any dropup expanded panel covers the cursor, claim the
  # wheel + close-on-outside-click *before* the panes get a chance to
  # consume them. This is what gives the popup priority over the panes.
  let dropupClaims = dropupClaimsInput(ctx, app)

  let prevBlocked = ctx.inputBlocked
  if frame.settingsFrac > 0 or dropupClaims: ctx.inputBlocked = true
  syncLPaneIfStale(app)
  syncPaletteForActiveCar(app)
  tickPaletteStatus(app, ctx.dt)
  let rPane = rpane.paneRect(ctx.winW, ctx.winH, stripH, dropupH)
  discard drawRPane(ctx, cache, app, frame.menu, rPane)
  let lPane = lpane.paneRect(ctx.winW, ctx.winH, stripH, dropupH)
  discard drawLPane(ctx, cache, app, lPane)

  # Bottom-middle export palette — floats above the dropup strip when a
  # working car is loaded. Drawn after the panes so it overlays them when
  # the advanced row expands; before the dropup tiles so the dropup tile
  # row still wins for hits at the very bottom.
  if app.activeSlug.len > 0:
    let palR = paletteRect(ctx.winW, ctx.winH, dropupH)
    let palRes = drawPalette(ctx, cache, app, palR)
    if palRes.exportPressed:
      dispatchExport(app)

  # Bottom dropup row + per-source expanded panels. The dropup tile
  # buttons need to remain clickable even when their own expanded panel
  # is hovered, so we drop the inputBlocked we raised for the panes.
  ctx.inputBlocked = (frame.settingsFrac > 0)
  drawDropupRow(ctx, cache, app, frame.menu)
  ctx.inputBlocked = prevBlocked

  # Right-click anywhere that didn't open / dismiss a menu cancels an
  # active grab — gives the user a "drop in main view" gesture.
  if app.grab.active and ctx.mouseClicked[2] and
     not menuOpenAtStart and not frame.menu.open:
    app.grab.active = false

  # Settings overlay.
  if frame.settingsOpen and not frame.settings.initialized:
    frame.settings.beginSession()
  modal.tickFraction(frame.settingsFrac, frame.settingsOpen, ctx.dt)
  modal.modalDim(ctx, frame.settingsFrac)
  if frame.settingsFrac > 0:
    let panel = modal.settleToCenteredRect(ctx, frame.settingsFrac,
                                           ctx.winH - stripH, 0.80'f32)
    ctx.pushSolid(panel, color(0.10, 0.12, 0.16, 0.96))
    var closing = false
    if frame.settings.initialized:
      drawSettingsPanel(ctx, cache, frame.settings, panel, app, closing)
    if closing:
      frame.settings.endSession(commit = true, app)
      frame.settingsOpen = false

  # Top settings slice: full-width strip; click opens the panel. The
  # strip is suppressed while the panel is open OR mid-animation — that
  # way the panel's internal Save & Close is the only path back, and a
  # stray click on the strip can't strand the modal half-rendered.
  if frame.settingsFrac == 0 and not frame.settingsOpen:
    let topRect = rect(0, 0, ctx.winW, stripH)
    if button(ctx, cache, wid("settings.toggle"), topRect, "settings",
              ButtonStyle(bg: color(0.18, 0.20, 0.24),
                          bgHover: color(0.22, 0.25, 0.30),
                          bgActive: color(0.28, 0.32, 0.40),
                          fg: color(0.92, 0.94, 0.98))):
      frame.settingsOpen = true

  # Cursor ghost for an active grab — drawn before the context menu so a
  # click on a Replace-with-grabbed item still sees the menu's hit region
  # on top. Ghost is offset slightly down-right so the cursor stays
  # readable.
  if app.grab.active:
    let label = app.grab.partName & "  ←  " & app.grab.donorSlug
    let (lw, lh) = cache.measureText(label)
    let gx = ctx.mouseX + 14
    let gy = ctx.mouseY + 6
    ctx.pushSolid(rect(gx - 4, gy - 2, lw + 8, lh + 4),
                  color(0.10, 0.12, 0.16, 0.88))
    ctx.pushSolid(rect(gx - 5, gy - 3, lw + 10, 1),
                  color(0.95, 0.70, 0.20, 1.0))
    ctx.pushLabel(cache, label, gx, gy)

  # Context menu — rendered last so it overlays the dropup panels and the
  # settings strip, and the click that dismisses it can't accidentally
  # re-trigger anything underneath.
  let choice = drawContextMenu(ctx, cache, frame.menu)
  dispatchMenu(frame.menu, choice, app, scene, dev)

proc renderFrame(dev: ptr SDL_GPUDevice; win: ptr SDL_Window;
                 pipes: UiPipelines; ctx: var UiContext;
                 cache: var TextCache; frame: var AppFrame;
                 scene: var Scene3D;
                 dtSecs: float32; app: var AppState) =
  let cmd = SDL_AcquireGPUCommandBuffer(dev)
  if cmd.isNil: return

  var swapTex: ptr SDL_GPUTexture
  var swapW, swapH: uint32
  if not SDL_WaitAndAcquireGPUSwapchainTexture(cmd, win, addr swapTex,
                                               addr swapW, addr swapH):
    discard SDL_SubmitGPUCommandBuffer(cmd); return
  if swapTex.isNil:
    discard SDL_SubmitGPUCommandBuffer(cmd); return

  ctx.winW = float32(swapW)
  ctx.winH = float32(swapH)
  ctx.dt = dtSecs
  ctx.reset()
  let prevMouseDown = frame.prevMouseDown   # snapshot before sampleMouse overwrites it
  sampleMouse(ctx, frame)
  buildFrame(ctx, cache, frame, app, scene, dev)

  # Hand whatever wheelY the UI didn't consume + mouse delta to the orbit
  # camera. `inputBlocked` while the settings modal is animating gates new
  # drags from starting (an in-progress drag stays alive — see scene3d).
  if not frame.mouseInited:
    frame.prevMouseX = ctx.mouseX
    frame.prevMouseY = ctx.mouseY
    frame.mouseInited = true
  let dx = ctx.mouseX - frame.prevMouseX
  let dy = ctx.mouseY - frame.prevMouseY
  let blocked = frame.settingsFrac > 0
  scene.handleMouseInput(dx, dy,
                         rmb = ctx.mouseDown[2], mmb = ctx.mouseDown[1],
                         rmbPrev = prevMouseDown[2], mmbPrev = prevMouseDown[1],
                         wheelY = ctx.wheelY, blocked = blocked)
  frame.prevMouseX = ctx.mouseX
  frame.prevMouseY = ctx.mouseY

  # 3D pass — clears swapchain to RoomColor, writes depth, draws scene.
  scene.render(dev, cmd, swapTex, swapW, swapH)

  # UI pass — load existing color, no depth, alpha-blend the draw list on top.
  var uiColor: SDL_GPUColorTargetInfo
  uiColor.texture  = swapTex
  uiColor.load_op  = SDL_GPU_LOADOP_LOAD
  uiColor.store_op = SDL_GPU_STOREOP_STORE
  let rp = SDL_BeginGPURenderPass(cmd, addr uiColor, 1, nil)
  submitDrawList(cmd, rp, ctx, pipes)
  SDL_EndGPURenderPass(rp)

  discard SDL_SubmitGPUCommandBuffer(cmd)

proc main*() =
  if not SDL_Init(SDL_INIT_VIDEO):
    die("SDL_Init")
  defer: SDL_Quit()

  if not TTF_Init():
    die("TTF_Init")

  let win = SDL_CreateWindow(WindowTitle, WindowW.cint, WindowH.cint, 0)
  if win.isNil: die("SDL_CreateWindow")
  defer: SDL_DestroyWindow(win)

  let dev = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, true, nil)
  if dev.isNil: die("SDL_CreateGPUDevice")
  defer: SDL_DestroyGPUDevice(dev)

  if not SDL_ClaimWindowForGPUDevice(dev, win):
    die("SDL_ClaimWindowForGPUDevice")

  var pipes = setupUiPipelines(dev, win)
  defer: releaseUiPipelines(dev, pipes)

  var scene = scene3d.init(dev, win)
  defer: scene3d.release(dev, scene)

  # Font lifetime: keep the bytes alive for as long as the font handle.
  var fontBytes = FontData
  let font = rendertext.openFontFromBytes(fontBytes, FontPtSize)

  var cache = uitext.initTextCache(dev, font, pipes.fontSampler)
  defer: uitext.releaseTextCache(cache)

  var app = initAppState()
  stderr.writeLine &"workingRoot: {app.workingRoot}"
  for i, src in app.sources:
    stderr.writeLine &"  source[{i}]: {src.label} ({src.cars.len} cars, kind={src.kind})"

  # No car loaded at startup — user picks one via right-click → "Load
  # from working/" on a working/ row. The pedestal renders empty until then.

  var ctx: UiContext
  var frame: AppFrame
  var lastTicks = SDL_GetTicks()

  # Enable IME / text-input event delivery once. Widgets that want raw
  # ASCII can also read SDL_EVENT_KEY_DOWN, but TEXT_INPUT is what gives us
  # composed glyph strings (correct for non-Latin layouts and dead keys).
  discard SDL_StartTextInput(win)

  var ev: SDL_Event
  var running = true
  while running:
    ctx.wheelY = 0
    ctx.textInput.setLen(0)
    ctx.keys.setLen(0)
    while SDL_PollEvent(addr ev):
      case ev.`type`
      of SDL_EVENT_QUIT:
        running = false
      of SDL_EVENT_MOUSE_WHEEL:
        let w = cast[ptr SDL_MouseWheelEvent](addr ev)
        ctx.wheelY += float32(w.y)
      of SDL_EVENT_TEXT_INPUT:
        let t = cast[ptr SDL_TextInputEvent](addr ev)
        if t.text != nil: ctx.textInput.add($t.text)
      of SDL_EVENT_KEY_DOWN:
        let k = cast[ptr SDL_KeyboardEvent](addr ev)
        ctx.keys.add(KeyPress(key: k.key, `mod`: k.`mod`, repeat: k.repeat))
      else: discard
    if not running: break

    let now = SDL_GetTicks()
    let dt = float32(now - lastTicks) / 1000.0'f32
    lastTicks = now

    renderFrame(dev, win, pipes, ctx, cache, frame, scene, dt, app)
    sleep(TickIdleMs)
