## Hand-rolled UI plumbing — types shared by every widget.
##
## Coordinate convention is pixels with origin at the window's top-left,
## y growing down. NDC conversion happens once at submit time in render.nim.

type
  Rect* = object
    x*, y*, w*, h*: float32

  Color* = object
    r*, g*, b*, a*: float32

  WidgetId* = uint64

  DrawCmdKind* = enum dckSolid, dckCircle, dckText

  DrawCmd* = object
    rect*: Rect
    clipped*: bool         ## when true, render with `clip` as a scissor box
    clip*: Rect            ## scissor rect in window pixels (only valid if clipped)
    case kind*: DrawCmdKind
    of dckSolid, dckCircle:
      color*: Color
    of dckText:
      tex*: pointer       ## ptr SDL_GPUTexture (avoids importing sdl3 here)
      sampler*: pointer   ## ptr SDL_GPUSampler

  KeyPress* = object
    key*:    uint32             ## SDL_Keycode
    `mod`*:  uint16             ## SDL_Keymod (Ctrl/Shift/Alt mask)
    repeat*: bool

  UiContext* = object
    winW*, winH*: float32       ## current backbuffer size in pixels
    dt*: float32                ## seconds since last frame

    mouseX*, mouseY*: float32
    mouseDown*, mouseClicked*, mouseReleased*: array[3, bool]
    wheelY*: float32

    textInput*: string          ## concatenated UTF-8 chars typed this frame
    keys*: seq[KeyPress]        ## SDL_EVENT_KEY_DOWN events this frame

    hotId*, activeId*, focusedId*: WidgetId

    inputBlocked*: bool         ## widgets drawn while this is set become inert
                                ## (still rendered, but no hover/click reactions).
                                ## Toggle around regions that sit behind a modal.

    draw*: seq[DrawCmd]

proc rect*(x, y, w, h: float32): Rect =
  Rect(x: x, y: y, w: w, h: h)

proc color*(r, g, b: float32; a: float32 = 1.0'f32): Color =
  Color(r: r, g: g, b: b, a: a)

proc contains*(r: Rect; px, py: float32): bool =
  px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h

proc reset*(ctx: var UiContext) =
  ## Call at the start of each frame after sampling input.
  ctx.draw.setLen(0)
  ctx.hotId = 0
