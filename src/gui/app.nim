## SDL3 GUI entry point. Phase 3a frame loop with hand-rolled widgets:
## window + GPU device + UI pipelines + font + per-frame mouse polling +
## a clickable top settings slice that drops a modal panel.

import std/[hashes, os, strformat]
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
import state

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
    prevMouseDown: array[3, bool]

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

proc buildFrame(ctx: var UiContext; cache: var TextCache;
                frame: var AppFrame; app: var AppState) =
  let stripH = ctx.winH * 0.025'f32

  # Bottom dropup row + per-source expanded panels. While the settings
  # overlay is animating in or open, the row is rendered but inert so
  # accidental clicks behind the modal don't reach it.
  let prevBlocked = ctx.inputBlocked
  if frame.settingsFrac > 0: ctx.inputBlocked = true
  drawDropupRow(ctx, cache, app)
  ctx.inputBlocked = prevBlocked

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

  # Top settings slice: full-width strip; click toggles the panel.
  let topRect = rect(0, 0, ctx.winW, stripH)
  if button(ctx, cache, wid("settings.toggle"), topRect, "settings",
            ButtonStyle(bg: color(0.18, 0.20, 0.24),
                        bgHover: color(0.22, 0.25, 0.30),
                        bgActive: color(0.28, 0.32, 0.40),
                        fg: color(0.92, 0.94, 0.98))):
    frame.settingsOpen = not frame.settingsOpen

proc renderFrame(dev: ptr SDL_GPUDevice; win: ptr SDL_Window;
                 pipes: UiPipelines; ctx: var UiContext;
                 cache: var TextCache; frame: var AppFrame;
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
  sampleMouse(ctx, frame)
  buildFrame(ctx, cache, frame, app)

  var colorTarget: SDL_GPUColorTargetInfo
  colorTarget.texture     = swapTex
  colorTarget.clear_color = SDL_FColor(r: 0.06, g: 0.07, b: 0.09, a: 1.0)
  colorTarget.load_op     = SDL_GPU_LOADOP_CLEAR
  colorTarget.store_op    = SDL_GPU_STOREOP_STORE

  let rp = SDL_BeginGPURenderPass(cmd, addr colorTarget, 1, nil)
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

  # Font lifetime: keep the bytes alive for as long as the font handle.
  var fontBytes = FontData
  let font = rendertext.openFontFromBytes(fontBytes, FontPtSize)

  var cache = uitext.initTextCache(dev, font, pipes.fontSampler)
  defer: uitext.releaseTextCache(cache)

  var app = initAppState()
  stderr.writeLine &"workingRoot: {app.workingRoot}"
  for i, src in app.sources:
    stderr.writeLine &"  source[{i}]: {src.label} ({src.cars.len} cars, kind={src.kind})"

  var ctx: UiContext
  var frame: AppFrame
  var lastTicks = SDL_GetTicks()

  var ev: SDL_Event
  var running = true
  while running:
    ctx.wheelY = 0
    while SDL_PollEvent(addr ev):
      case ev.`type`
      of SDL_EVENT_QUIT:
        running = false
      of SDL_EVENT_MOUSE_WHEEL:
        let w = cast[ptr SDL_MouseWheelEvent](addr ev)
        ctx.wheelY += float32(w.y)
      else: discard
    if not running: break

    let now = SDL_GetTicks()
    let dt = float32(now - lastTicks) / 1000.0'f32
    lastTicks = now

    renderFrame(dev, win, pipes, ctx, cache, frame, dt, app)
    sleep(TickIdleMs)
