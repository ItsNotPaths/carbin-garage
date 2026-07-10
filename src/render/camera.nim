## camera.nim — OrbitCamera: third-person "helicopter" camera that rotates
## around a focus point. Z-up world; yaw rotates around +Z, pitch around the
## local right axis, clamped to ±89° to avoid gimbal flips.

import std/math
import math3d

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
