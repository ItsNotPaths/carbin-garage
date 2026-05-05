## Single-line text input. Focus-tracked via `ctx.focusedId`; consumes
## ctx.textInput (UTF-8 typed-glyph buffer) and ctx.keys (SDL key events)
## populated by `gui/app.nim`'s event poll.
##
## The widget owns no caret rendering / selection — caret is a vertical
## bar at the cursor index drawn each frame. Numeric variant clamps and
## rounds to step on Enter.

import std/[strutils, math]
import context
import draw
import text as uitext
import ../../render/platform/sdl3

const
  # SDL3 keycodes used by this widget. Values straight from SDL_keycode.h.
  SDLK_BACKSPACE = 0x00000008'u32
  SDLK_TAB       = 0x00000009'u32
  SDLK_RETURN    = 0x0000000D'u32
  SDLK_ESCAPE    = 0x0000001B'u32
  SDLK_DELETE    = 0x0000007F'u32
  SDLK_LEFT      = 0x40000050'u32
  SDLK_RIGHT     = 0x4000004F'u32
  SDLK_HOME      = 0x4000004A'u32
  SDLK_END       = 0x4000004D'u32
  SDLK_V         = 0x00000076'u32

  KMOD_LCTRL = 0x0040'u16
  KMOD_RCTRL = 0x0080'u16
  KMOD_LGUI  = 0x0400'u16   ## Cmd on macOS
  KMOD_RGUI  = 0x0800'u16
  PasteMods  = KMOD_LCTRL or KMOD_RCTRL or KMOD_LGUI or KMOD_RGUI

  PadX        = 8.0'f32
  CaretBlinkS = 0.50'f32

  BgIdle     = (0.10'f32, 0.12'f32, 0.16'f32, 0.95'f32)
  BgFocused  = (0.14'f32, 0.18'f32, 0.24'f32, 0.95'f32)
  Border     = (0.30'f32, 0.32'f32, 0.38'f32, 1.0'f32)
  BorderFocus= (0.55'f32, 0.70'f32, 0.95'f32, 1.0'f32)
  CaretColor = (0.92'f32, 0.94'f32, 0.98'f32, 1.0'f32)
  FlashErr   = (0.95'f32, 0.30'f32, 0.30'f32, 0.40'f32)

type
  TextInputState* = object
    text*:    string         ## current value (UTF-8)
    cursor*:  int            ## byte index of caret (0..text.len)
    scrollX*: float32        ## horizontal scroll offset in px (auto-tracks caret)
    flashS*:  float32        ## brief red flash on clamp; counts down
    blinkS*:  float32        ## caret blink phase
    pendingEnter*: bool      ## set true the frame Enter was pressed (committed)

proc setText*(s: var TextInputState; v: string) =
  s.text = v
  if s.cursor > s.text.len: s.cursor = s.text.len

proc isFocused*(ctx: UiContext; id: WidgetId): bool =
  ctx.focusedId == id

proc handleInput(s: var TextInputState; ctx: var UiContext) =
  ## Apply this frame's typed glyphs + key events to `s`. Writes happen at
  ## byte indices — fine for ASCII; for multi-byte UTF-8 the caret may
  ## land mid-codepoint when arrow-keys are used (acceptable for stats
  ## form which is numeric).
  if ctx.textInput.len > 0:
    s.text.insert(ctx.textInput, s.cursor)
    s.cursor += ctx.textInput.len
  s.pendingEnter = false
  for k in ctx.keys:
    # Ctrl+V (Cmd+V on macOS) — paste-only; no copy/cut/select. Pulls
    # SDL_GetClipboardText, strips trailing newlines (multi-line clipboard
    # contents would corrupt our single-line widgets), and inserts at the
    # caret like a SDL_EVENT_TEXT_INPUT batch.
    if k.key == SDLK_V and (k.`mod` and PasteMods) != 0:
      if SDL_HasClipboardText():
        let raw = SDL_GetClipboardText()
        if raw != nil:
          var clip = $raw
          SDL_free(cast[pointer](raw))
          # Squash any newlines/CRs to spaces so a multi-line paste lands
          # as a single-line value rather than truncating mid-string.
          for i in 0 ..< clip.len:
            if clip[i] in {'\n', '\r'}: clip[i] = ' '
          if clip.len > 0:
            s.text.insert(clip, s.cursor)
            s.cursor += clip.len
      continue
    case k.key
    of SDLK_BACKSPACE:
      if s.cursor > 0:
        s.text.delete(s.cursor - 1 .. s.cursor - 1)
        dec s.cursor
    of SDLK_DELETE:
      if s.cursor < s.text.len:
        s.text.delete(s.cursor .. s.cursor)
    of SDLK_LEFT:
      if s.cursor > 0: dec s.cursor
    of SDLK_RIGHT:
      if s.cursor < s.text.len: inc s.cursor
    of SDLK_HOME:
      s.cursor = 0
    of SDLK_END:
      s.cursor = s.text.len
    of SDLK_RETURN:
      s.pendingEnter = true
    of SDLK_ESCAPE, SDLK_TAB:
      ctx.focusedId = 0       # blur on Esc/Tab — caller can re-focus
    else: discard

proc drawField(ctx: var UiContext; cache: var TextCache;
               s: var TextInputState; r: Rect; focused: bool) =
  let (br, bg, bb, ba) = (if focused: BorderFocus else: Border)
  ctx.pushSolid(rect(r.x - 1, r.y - 1, r.w + 2, r.h + 2),
                color(br, bg, bb, ba))
  let (fr, fg, fb, fa) = (if focused: BgFocused else: BgIdle)
  ctx.pushSolid(r, color(fr, fg, fb, fa))

  if s.flashS > 0:
    let (er, eg, eb, ea) = FlashErr
    ctx.pushSolid(r, color(er, eg, eb, ea))

  # Caret pixel position relative to the text-content origin (0 = first
  # glyph). When unfocused we snap the field back to its leftmost so the
  # leading digits of long values are always visible at a glance; only
  # the focused field auto-tracks its caret.
  var caretPx = 0.0'f32
  if s.cursor > 0:
    let prefix = s.text[0 ..< s.cursor]
    let (pw, _) = cache.measureText(prefix)
    caretPx = pw
  let visibleW = r.w - PadX * 2
  if not focused:
    s.scrollX = 0
  else:
    if caretPx - s.scrollX > visibleW:
      s.scrollX = caretPx - visibleW
    if caretPx - s.scrollX < 0:
      s.scrollX = caretPx
    let (totalW, _) = cache.measureText(s.text)
    if totalW <= visibleW:
      s.scrollX = 0
    elif s.scrollX > totalW - visibleW:
      s.scrollX = totalW - visibleW

  # Text is clipped to the field interior so it can't bleed past the
  # bounds; lifted ~5 px so it sits centred under the SpaceMono cap line.
  let textY = r.y + (r.h - 14) * 0.5'f32 - 5
  let inner = rect(r.x + 1, r.y + 1, r.w - 2, r.h - 2)
  pushLabelClipped(ctx, cache, s.text,
                   r.x + PadX - s.scrollX, textY, inner)

  if focused and s.blinkS < CaretBlinkS:
    let cx = r.x + PadX + caretPx - s.scrollX
    let (cr, cg, cb, ca) = CaretColor
    if cx >= inner.x and cx <= inner.x + inner.w:
      ctx.pushSolid(rect(cx, r.y + 4, 1.5'f32, r.h - 8),
                    color(cr, cg, cb, ca))

proc tickBlink(s: var TextInputState; dt: float32) =
  s.blinkS += dt
  if s.blinkS >= CaretBlinkS * 2: s.blinkS = 0
  if s.flashS > 0:
    s.flashS -= dt
    if s.flashS < 0: s.flashS = 0

proc textInput*(ctx: var UiContext; cache: var TextCache;
                id: WidgetId; r: Rect; s: var TextInputState): bool =
  ## Returns true on the frame the value changed. Click to focus; Enter
  ## or click-away blurs.
  let focused = isFocused(ctx, id)
  let prev = s.text
  let prevCursor = s.cursor

  # focus management
  if (not ctx.inputBlocked) and r.contains(ctx.mouseX, ctx.mouseY):
    ctx.hotId = id
    if ctx.mouseClicked[0]:
      ctx.focusedId = id
      s.cursor = s.text.len  # caret to end on click
  elif ctx.mouseClicked[0] and focused:
    ctx.focusedId = 0        # click outside blurs

  if focused and not ctx.inputBlocked:
    handleInput(s, ctx)

  tickBlink(s, ctx.dt)
  drawField(ctx, cache, s, r, focused or s.flashS > 0)

  result = (s.text != prev) or (s.cursor != prevCursor)

proc tryClamp*(s: var TextInputState;
               minV, maxV, step: float;
               isInt: bool): bool =
  ## Parse the field as a number, clamp to [minV, maxV], optionally round
  ## to `step` (or to integer if isInt). On parse failure or out-of-range,
  ## sets s.flashS so the field flashes red. Returns true if the field
  ## now holds a clean canonical numeric string.
  var v: float
  try:
    v = parseFloat(s.text.strip())
  except ValueError:
    s.flashS = 0.6'f32
    return false
  let clamped = (v < minV) or (v > maxV)
  if v < minV: v = minV
  if v > maxV: v = maxV
  if step > 0:
    v = round(v / step) * step
  if isInt:
    v = round(v)
    s.text = $int(v)
  else:
    s.text = formatFloat(v, ffDecimal, precision = -1).strip(chars = {'0'})
    if s.text.endsWith("."): s.text.add("0")
    if s.text.startsWith("."): s.text = "0" & s.text
    if s.text.startsWith("-."): s.text = "-0" & s.text[1 .. ^1]
    if s.text.len == 0 or s.text == "-": s.text = "0"
  s.cursor = s.text.len
  if clamped: s.flashS = 0.6'f32
  result = true
