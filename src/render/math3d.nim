## math3d.nim — tiny vec3 / mat4 helpers for the game renderer.
##
## Column-major 4x4 matrices stored as `array[16, float32]` with index
## `col*4 + row`, so a `ptr Mat4` can be passed straight into
## `SDL_PushGPUVertexUniformData` and read by GLSL as `mat4`.

import std/math

const EpsilonF32* = 1e-6'f32

type
  Vec3* = array[3, float32]
  Mat4* = array[16, float32]

proc vec3*(x, y, z: float32): Vec3 = [x, y, z]

proc `+`*(a, b: Vec3): Vec3 = [a[0]+b[0], a[1]+b[1], a[2]+b[2]]
proc `-`*(a, b: Vec3): Vec3 = [a[0]-b[0], a[1]-b[1], a[2]-b[2]]
proc `*`*(v: Vec3, s: float32): Vec3 = [v[0]*s, v[1]*s, v[2]*s]

proc dot*(a, b: Vec3): float32 = a[0]*b[0] + a[1]*b[1] + a[2]*b[2]

proc cross*(a, b: Vec3): Vec3 =
  [a[1]*b[2] - a[2]*b[1],
   a[2]*b[0] - a[0]*b[2],
   a[0]*b[1] - a[1]*b[0]]

proc length*(v: Vec3): float32 = sqrt(dot(v, v))

proc normalize*(v: Vec3): Vec3 =
  let l = length(v)
  if l > EpsilonF32: [v[0]/l, v[1]/l, v[2]/l] else: [0'f32, 0'f32, 0'f32]

# --- Mat4 ------------------------------------------------------------------

proc mat4Identity*(): Mat4 =
  result[0]  = 1; result[5]  = 1; result[10] = 1; result[15] = 1

proc mat4Mul*(a, b: Mat4): Mat4 =
  # result = a * b, column-major: r[c][r] = Σk a[k][r] * b[c][k]
  for c in 0 ..< 4:
    for r in 0 ..< 4:
      var s: float32 = 0
      for k in 0 ..< 4:
        s += a[k*4 + r] * b[c*4 + k]
      result[c*4 + r] = s

proc mat4LookAt*(eye, target, up: Vec3): Mat4 =
  ## Right-handed view matrix. Camera looks down -Z in view space.
  let f = normalize(target - eye)
  let s = normalize(cross(f, up))
  let u = cross(s, f)
  result[0]  =  s[0]; result[1]  =  u[0]; result[2]  = -f[0]; result[3]  = 0
  result[4]  =  s[1]; result[5]  =  u[1]; result[6]  = -f[1]; result[7]  = 0
  result[8]  =  s[2]; result[9]  =  u[2]; result[10] = -f[2]; result[11] = 0
  result[12] = -dot(s, eye)
  result[13] = -dot(u, eye)
  result[14] =  dot(f, eye)
  result[15] = 1

proc mat4Perspective*(fovYRad, aspect, zNear, zFar: float32): Mat4 =
  ## Depth in [0, 1] (near→far), Y-up clip space. SDL3 GPU normalizes NDC to
  ## D3D/Metal conventions (+Y up) internally, so no Vulkan Y flip here.
  let f = 1'f32 / tan(fovYRad * 0.5'f32)
  result[0]  = f / aspect
  result[5]  = f
  result[10] = zFar / (zNear - zFar)
  result[11] = -1
  result[14] = (zNear * zFar) / (zNear - zFar)
  result[15] = 0

# --- Frustum culling -------------------------------------------------------

type
  Plane* = array[4, float32]   ## (nx, ny, nz, d); inside iff n·p + d >= 0
  Frustum* = array[6, Plane]

proc normalizePlane(p: Plane): Plane =
  let l = sqrt(p[0]*p[0] + p[1]*p[1] + p[2]*p[2])
  if l > EpsilonF32:
    [p[0]/l, p[1]/l, p[2]/l, p[3]/l]
  else:
    p

proc extractFrustum*(m: Mat4): Frustum =
  ## Extract 6 frustum planes (left, right, bottom, top, near, far) from a
  ## column-major clip-space matrix. A point p is inside iff n·p + d >= 0 for
  ## every plane. Clip-space convention: x,y in [-w, w], z in [0, w].
  # row_i of M as (M[0*4+i], M[1*4+i], M[2*4+i], M[3*4+i])
  template row(i: int): Plane =
    [m[0*4+i], m[1*4+i], m[2*4+i], m[3*4+i]]
  template add4(a, b: Plane): Plane =
    [a[0]+b[0], a[1]+b[1], a[2]+b[2], a[3]+b[3]]
  template sub4(a, b: Plane): Plane =
    [a[0]-b[0], a[1]-b[1], a[2]-b[2], a[3]-b[3]]
  let r0 = row(0)
  let r1 = row(1)
  let r2 = row(2)
  let r3 = row(3)
  result[0] = normalizePlane(add4(r3, r0))  # left
  result[1] = normalizePlane(sub4(r3, r0))  # right
  result[2] = normalizePlane(add4(r3, r1))  # bottom
  result[3] = normalizePlane(sub4(r3, r1))  # top
  result[4] = normalizePlane(r2)            # near (z >= 0)
  result[5] = normalizePlane(sub4(r3, r2))  # far

proc aabbOutsideFrustum*(f: Frustum; lo, hi: Vec3): bool =
  ## Conservative AABB-vs-frustum reject using the p-vertex trick: for each
  ## plane, pick the box corner furthest along the plane normal; if that
  ## corner is outside, the whole box is outside.
  for plane in f:
    let px = (if plane[0] >= 0: hi[0] else: lo[0])
    let py = (if plane[1] >= 0: hi[1] else: lo[1])
    let pz = (if plane[2] >= 0: hi[2] else: lo[2])
    if plane[0]*px + plane[1]*py + plane[2]*pz + plane[3] < 0:
      return true
  false
