## Quaternion + tangent-space helpers shared by the vertex codec.
## Port of probe/reference/fm4_obj.py:94-157.
## All maths in float32; results round-tripped through int16 ShortN
## quantization by the codec.

import std/math

type
  Vec3* = array[3, float32]
  Quat* = array[4, float32]   # x, y, z, w
  Quat16* = array[4, int16]   # ShortN-packed

const eps = 1e-8'f32

proc shortn*(v: int16): float32 =
  ## ShortN: int16 → float32 in [-1, 1]. -32768 saturates to -1.
  if v <= -32768'i16: return -1.0'f32
  result = max(-1.0'f32, min(1.0'f32, float32(v) / 32767.0'f32))

proc toShortn*(v: float32): int16 =
  let c = max(-1.0'f32, min(1.0'f32, v))
  if c <= -1.0'f32: return -32768'i16
  result = int16(round(c * 32767.0))

proc ushortn*(v: uint16): float32 =
  result = float32(v) / 65535.0'f32

proc toUshortn*(v: float32): uint16 =
  let c = max(0.0'f32, min(1.0'f32, v))
  result = uint16(round(c * 65535.0))

proc normalize3*(v: Vec3): Vec3 =
  let l = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2])
  if l < eps: return [0.0'f32, 1.0'f32, 0.0'f32]
  result = [v[0] / l, v[1] / l, v[2] / l]

proc cross*(a, b: Vec3): Vec3 =
  result = [a[1]*b[2] - a[2]*b[1],
            a[2]*b[0] - a[0]*b[2],
            a[0]*b[1] - a[1]*b[0]]

proc dot*(a, b: Vec3): float32 =
  result = a[0]*b[0] + a[1]*b[1] + a[2]*b[2]

proc quatToMatrixRow0*(q: Quat): Vec3 =
  ## First row of the rotation matrix from a quaternion.
  ## In the Forza vertex format this row IS the surface normal.
  ## Math is done in float64 to match the Python oracle bit-for-bit.
  let x = float64(q[0]); let y = float64(q[1])
  let z = float64(q[2]); let w = float64(q[3])
  result = [float32(1.0 - 2.0 * (y*y + z*z)),
            float32(2.0 * (x*y + z*w)),
            float32(2.0 * (x*z - y*w))]

proc matrixToPackedQuat*(m00, m01, m02, m10, m11, m12, m20, m21, m22: float32): Quat16 =
  ## Full rotation matrix (row-major) → packed quaternion (ShortN × 4).
  ## Sign convention follows probe/reference/fm4_obj.py:_matrix_to_packed_quat.
  let trace = m00 + m11 + m22
  var qx, qy, qz, qw: float32
  if trace > 0.0'f32:
    let s = sqrt(trace + 1.0'f32) * 2.0'f32
    qw = 0.25'f32 * s
    qx = (m21 - m12) / s
    qy = (m02 - m20) / s
    qz = (m10 - m01) / s
  elif m00 > m11 and m00 > m22:
    let s = sqrt(1.0'f32 + m00 - m11 - m22) * 2.0'f32
    qw = (m21 - m12) / s
    qx = 0.25'f32 * s
    qy = (m01 + m10) / s
    qz = (m02 + m20) / s
  elif m11 > m22:
    let s = sqrt(1.0'f32 + m11 - m00 - m22) * 2.0'f32
    qw = (m02 - m20) / s
    qx = (m01 + m10) / s
    qy = 0.25'f32 * s
    qz = (m12 + m21) / s
  else:
    let s = sqrt(1.0'f32 + m22 - m00 - m11) * 2.0'f32
    qw = (m10 - m01) / s
    qx = (m02 + m20) / s
    qy = (m12 + m21) / s
    qz = 0.25'f32 * s
  let ql = max(sqrt(qx*qx + qy*qy + qz*qz + qw*qw), eps)
  result = [toShortn(qx / ql), toShortn(qy / ql),
            toShortn(qz / ql), toShortn(qw / ql)]

proc tangentSpaceToQuat*(normal, tangent: Vec3): Quat16 =
  ## Build an orthonormal basis (n, t, b) and pack as a quaternion.
  let n = normalize3(normal)
  let dotTN = dot(tangent, n)
  var tRaw: Vec3 = [tangent[0] - n[0]*dotTN,
                    tangent[1] - n[1]*dotTN,
                    tangent[2] - n[2]*dotTN]
  if dot(tRaw, tRaw) < 1e-6'f32:
    let up: Vec3 = if abs(n[1]) < 0.999'f32: [0.0'f32, 1.0'f32, 0.0'f32]
                   else: [1.0'f32, 0.0'f32, 0.0'f32]
    tRaw = cross(up, n)
  let t = normalize3(tRaw)
  let b = normalize3(cross(n, t))
  result = matrixToPackedQuat(
    n[0], t[0], b[0],
    n[1], t[1], b[1],
    n[2], t[2], b[2])

proc normalToQuat*(n: Vec3): Quat16 =
  let nm = normalize3(n)
  let up: Vec3 = if abs(nm[1]) < 0.999'f32: [0.0'f32, 1.0'f32, 0.0'f32]
                 else: [1.0'f32, 0.0'f32, 0.0'f32]
  let t = normalize3(cross(up, nm))
  result = tangentSpaceToQuat(nm, t)
