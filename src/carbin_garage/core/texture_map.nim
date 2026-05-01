## Subsection-shader → glTF material spec. Phase 2c.2.
##
## **Discovery from inspecting the FM4 atlases**: car body paint is NOT
## baked into any .xds. The game samples body subsections (`body`,
## `frame`, `chrome`, `carbon_fiber`, etc.) from a paint shader using
## runtime constants and a livery overlay. The .xds files only carry:
##   - lights.xds      → headlights, taillights, brake disc, reflectors
##   - nodamage.xds    → INTERIOR + badges + steering wheel + gauges
##                       (NOT body paint — mostly empty in body regions)
##   - interior_lod0   → dashboard text/icons (AIRBAG, AUTO, etc.)
##   - leather*_nrm    → tileable interior normal map
##
## So we resolve each shader name to one of three outcomes:
##   1. A flat-color PBR material (most body shaders)
##   2. A textured material from one of the atlases (lights, interior bits)
##   3. A semi-transparent glass material
##
## This produces a Blender preview that looks like a real Alfa: solid red
## body, silver chrome, black plastic, properly textured headlights and
## interior. The mapping is best-effort heuristic — m_MaterialSets[]
## parsing (open RE item) would give us the authoritative binding.

import std/[os, strutils]

type
  MatSpec* = object
    name*:           string
    textureBase*:    string         # "" = no texture, otherwise xds basename
    baseColor*:      array[4, float32]    # RGBA factor; default white
    metallic*:       float32
    roughness*:      float32
    alphaMode*:      string          # "" = OPAQUE default; "BLEND" / "MASK"

proc lc(s: string): string {.inline.} = s.toLowerAscii()

proc fc(r, g, b: float32, a: float32 = 1.0'f32): array[4, float32] =
  [r, g, b, a]

proc resolveMaterial*(subsectionName: string,
                      available: seq[string]): MatSpec =
  ## Best-effort shader → material mapping. Falls back to a neutral grey
  ## body color for unknown shader names so unmapped parts still render
  ## as a coherent solid shape rather than zebra-striped white.
  let n = lc(subsectionName)

  # ---- Lights (have real texture content) ----
  if n.contains("tail_light") or n.contains("taillight"):
    if "lights" in available:
      return MatSpec(name: n, textureBase: "lights",
                     baseColor: fc(1, 1, 1), metallic: 0.0, roughness: 0.4)
  if n.contains("headlight") or n.contains("head_light"):
    if "lights" in available:
      return MatSpec(name: n, textureBase: "lights",
                     baseColor: fc(1, 1, 1), metallic: 0.1, roughness: 0.2)
  if n.contains("reflector"):
    if "lights" in available:
      return MatSpec(name: n, textureBase: "lights",
                     baseColor: fc(1, 1, 1), metallic: 0.5, roughness: 0.25)
  if n == "reverse_light" or n.contains("reverse_light"):
    if "lights" in available:
      return MatSpec(name: n, textureBase: "lights",
                     baseColor: fc(1, 1, 1), metallic: 0.0, roughness: 0.4)

  # ---- Leather / bump_leather / stitching: procedural (no atlas) ----
  # In Forza these shaders sample a tileable normal map (leather2_NRM)
  # for surface detail and get their diffuse color from shader constants
  # — they don't sample the body atlas. Routing them at nodamage produces
  # wide UV ranges that read as random atlas chaos.
  if n == "leather" or n == "leather2" or n.contains("bump_leather"):
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.18, 0.10, 0.06), metallic: 0.0, roughness: 0.65)
  if n.contains("stitching"):
    # Stitching is a thin contrast thread on leather seams. Slightly
    # lighter brown so it reads against the leather base.
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.45, 0.30, 0.18), metallic: 0.0, roughness: 0.7)
  if n.contains("cloth") or n.contains("fabric"):
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.10, 0.10, 0.10), metallic: 0.0, roughness: 0.85)

  # ---- Interior / cockpit (sample from nodamage.xds — the interior atlas) ----
  # `interior` is the one shader that actually samples the atlas in a
  # tight region (matches the seat-leather area of nodamage).
  # `dashboard`, `gauge`, `steering` similarly point at their atlas
  # regions. Anything narrower (specific shaders like `cockpit_carbon`)
  # falls through to the carbon-fiber / black / etc. cases below.
  if n.contains("dashboard") or n.contains("gauge") or
     n.contains("steering") or n == "interior" or
     n.contains("seat") or n.contains("shifter") or n.contains("pedal"):
    if "nodamage" in available:
      return MatSpec(name: n, textureBase: "nodamage",
                     baseColor: fc(1, 1, 1), metallic: 0.05, roughness: 0.7)

  # ---- Glass (translucent) ----
  if n.contains("glass"):
    var col = fc(0.20, 0.20, 0.22, 0.35)
    if n.contains("red"): col = fc(0.55, 0.10, 0.10, 0.45)
    return MatSpec(name: n, textureBase: "",
                   baseColor: col, metallic: 0.0, roughness: 0.05,
                   alphaMode: "BLEND")

  # ---- Chrome / metals ----
  if n.contains("chrome") or n == "metal":
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.90, 0.90, 0.92), metallic: 1.0, roughness: 0.15)
  if n.contains("textured_reflector"):
    if "lights" in available:
      return MatSpec(name: n, textureBase: "lights",
                     baseColor: fc(1, 1, 1), metallic: 0.5, roughness: 0.3)

  # ---- Carbon fiber ----
  if n.contains("carbon_fiber") or n.contains("carbon"):
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.07, 0.07, 0.08), metallic: 0.4, roughness: 0.4)

  # ---- Tire / wheel rubber (very dark matte, rough) ----
  # FM4 names this `tire`; FH1 uses `wheel_black`. Without an explicit
  # case the tire falls through to the neutral grey default and reads
  # as a continuation of the rim.
  if n == "tire" or n == "wheel_black" or n.contains("tyre"):
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.025, 0.025, 0.025), metallic: 0.0, roughness: 0.92)

  # ---- Black / plastic / rubber ----
  if n == "black" or n.contains("plastic") or n.contains("rubber") or
     n.contains("trim") or n.contains("seal"):
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.06, 0.06, 0.06), metallic: 0.0, roughness: 0.6)

  # ---- Grille (very dark mesh) ----
  if n.contains("grille") or n.contains("grill"):
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.03, 0.03, 0.03), metallic: 0.2, roughness: 0.5)

  # ---- Frame / bumper frame / tow hook (dark grey/painted body) ----
  if n.contains("bumper_frame") or n == "frame" or n.contains("cage"):
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.12, 0.12, 0.13), metallic: 0.3, roughness: 0.5)

  # ---- Brake / rotor / caliper (steel/metal) ----
  if n.contains("brake") or n.contains("rotor") or n.contains("caliper"):
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.55, 0.10, 0.10), metallic: 0.6, roughness: 0.4)

  # ---- Body / paint (stock placeholder color) ----
  # No texture — this is what the runtime paint shader applies.
  # Default to a stock red so the car looks like a coherent painted
  # shape in Blender. Per-car stock color belongs in carattribs/livery
  # data and can replace this default later.
  if n == "body" or n.contains("body_paint") or n == "matte_colors" or
     n == "paint" or n.startsWith("body"):
    # Roughness 0.55 ≈ real automotive paint with clearcoat. Lower
    # values produce sharp white-pink Fresnel highlights at grazing
    # angles (correct PBR but reads as "weirdly shiny" on dense
    # geometry like FH1 LOD0).
    return MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.62, 0.05, 0.05), metallic: 0.0, roughness: 0.55)

  # ---- Default: medium grey, opaque, generic. ----
  result = MatSpec(name: n, textureBase: "",
                   baseColor: fc(0.45, 0.45, 0.45),
                   metallic: 0.05, roughness: 0.55)

proc availableTextureBasenames*(textureDir: string): seq[string] =
  ## Walk the textures/ directory and return basenames of *.xds files
  ## (no path, no `.xds` suffix). Used to seed the resolver.
  result = @[]
  if not dirExists(textureDir): return
  for kind, p in walkDir(textureDir):
    if kind != pcFile: continue
    let b = extractFilename(p)
    if b.toLowerAscii().endsWith(".xds"):
      result.add(b[0 ..< b.len - 4])
