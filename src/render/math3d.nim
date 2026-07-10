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
