## camera.nim — free-fly camera for the Z-up Source 2 coordinate system.
##
## Yaw rotates around +Z, pitch around the local right axis. At yaw=0, pitch=0
## the camera looks down +X. Pitch is clamped to ±89° to avoid gimbal flips.

import std/math
import math3d

type
  Camera* = object
    position*: Vec3
    yaw*: float32        ## radians, around +Z
    pitch*: float32      ## radians, around local right axis
    moveSpeed*: float32  ## world units per second (inches)
    boostMult*: float32  ## multiplier while shift held
    sensitivity*: float32## radians per pixel

proc newCamera*(pos: Vec3; yaw = 0'f32; pitch = 0'f32): Camera =
  Camera(
    position: pos,
    yaw: yaw,
    pitch: pitch,
    moveSpeed: 512'f32,       # 512 inches/s ≈ standard Source player speed
    boostMult: 4'f32,
    sensitivity: 0.0025'f32,
  )

proc forward*(c: Camera): Vec3 =
  let cp = cos(c.pitch)
  vec3(cos(c.yaw) * cp, sin(c.yaw) * cp, sin(c.pitch))

proc right*(c: Camera): Vec3 =
  normalize(cross(c.forward(), vec3(0, 0, 1)))

proc handleMouse*(c: var Camera, dx, dy: float32) =
  c.yaw   -= dx * c.sensitivity
  c.pitch -= dy * c.sensitivity
  let limit = (PI * 0.5'f32) - 0.01'f32
  if c.pitch >  limit: c.pitch =  limit
  if c.pitch < -limit: c.pitch = -limit

proc move*(c: var Camera, dt: float32;
           forwardAxis, rightAxis, upAxis: float32;
           boost: bool) =
  var speed = c.moveSpeed
  if boost: speed *= c.boostMult
  let step = speed * dt
  let f = c.forward()
  let r = c.right()
  let u = vec3(0, 0, 1)
  c.position = c.position + f * (forwardAxis * step)
  c.position = c.position + r * (rightAxis   * step)
  c.position = c.position + u * (upAxis      * step)

proc viewProj*(c: Camera, aspect: float32): Mat4 =
  let view = mat4LookAt(c.position, c.position + c.forward(), vec3(0, 0, 1))
  let proj = mat4Perspective(70.0'f32 * float32(PI) / 180.0'f32,
                             aspect, 1.0'f32, 16384.0'f32)
  mat4Mul(proj, view)

# ---------------------------------------------------------------------------
# OrbitCamera — third-person "helicopter" camera that rotates around a focus
# point. Used by leveledit's helicopter mode. World is still Z-up.

type
  OrbitCamera* = object
    focus*: Vec3            ## point we orbit around
    yaw*: float32           ## radians, around +Z (same convention as Camera)
    pitch*: float32         ## radians, clamped to ±89°
    distance*: float32      ## world units from focus to eye
    orbitSensitivity*: float32  ## radians per pixel for RMB drag
    panSensitivity*: float32    ## world units per pixel at distance=1
    zoomStep*: float32          ## multiplier per wheel tick

proc newOrbitCamera*(focus: Vec3; distance: float32;
                     yaw = 0'f32; pitch = -0.5'f32): OrbitCamera =
  OrbitCamera(
    focus: focus,
    yaw: yaw,
    pitch: pitch,
    distance: distance,
    orbitSensitivity: 0.0025'f32,
    panSensitivity: 0.0015'f32,
    zoomStep: 1.15'f32,
  )

proc forward*(c: OrbitCamera): Vec3 =
  ## Eye → focus direction.
  let cp = cos(c.pitch)
  vec3(cos(c.yaw) * cp, sin(c.yaw) * cp, sin(c.pitch))

proc right*(c: OrbitCamera): Vec3 =
  normalize(cross(c.forward(), vec3(0, 0, 1)))

proc up*(c: OrbitCamera): Vec3 =
  normalize(cross(c.right(), c.forward()))

proc position*(c: OrbitCamera): Vec3 =
  ## Eye position, derived from focus + distance + orientation.
  c.focus - c.forward() * c.distance

proc orbitRotate*(c: var OrbitCamera, dx, dy: float32) =
  c.yaw   -= dx * c.orbitSensitivity
  c.pitch -= dy * c.orbitSensitivity
  let limit = (PI * 0.5'f32) - 0.01'f32
  if c.pitch >  limit: c.pitch =  limit
  if c.pitch < -limit: c.pitch = -limit

proc orbitPan*(c: var OrbitCamera, dx, dy: float32) =
  ## Screen-space pan. Pixels scale by distance so the focus appears to stay
  ## glued to the cursor regardless of zoom.
  let scale = c.panSensitivity * c.distance
  let r = c.right()
  let u = c.up()
  c.focus = c.focus - r * (dx * scale) + u * (dy * scale)

proc orbitZoom*(c: var OrbitCamera, ticks: float32) =
  ## Positive ticks = zoom in, negative = zoom out.
  if ticks > 0:
    c.distance = c.distance / pow(c.zoomStep, ticks)
  elif ticks < 0:
    c.distance = c.distance * pow(c.zoomStep, -ticks)
  if c.distance < 1.0'f32:    c.distance = 1.0'f32
  if c.distance > 16384'f32:  c.distance = 16384'f32

proc viewProj*(c: OrbitCamera, aspect: float32): Mat4 =
  let eye = c.position()
  let view = mat4LookAt(eye, c.focus, vec3(0, 0, 1))
  let proj = mat4Perspective(70.0'f32 * float32(PI) / 180.0'f32,
                             aspect, 1.0'f32, 16384.0'f32)
  mat4Mul(proj, view)
