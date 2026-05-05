# carbin-garage

Cross-game car-archive editor for Xbox 360-era Forza titles (FM4, FH1).
Import a car, swap parts between donors, retexture, deploy as an FH1
DLC package — without touching the base game.

> **Alpha.** FM4 import is solid. FM4 → FH1 DLC deploy works in-game on
> the cars exercised so far (Alfa 8C, Audi R8). Carbin transcode
> coverage is partial (main mesh shipped; LOD0-only sections, damage
> translation still open). GUI is hand-rolled on raw SDL3 and rough
> around the edges. Expect sharp corners.

# SPECIAL THANKS TO:
Mike Davis - pioneer of forza re and creator of Forza Studio. His methods where invaluble at game exports
Warshack - UDLC creator, dlc structure and documentation
SoulBrix - FM4 exporter tool - reference


## What it does

- **Import** an FM4 or FH1 car archive (`.zip`) into a working tree
  (glTF + decoded `.png` textures + per-car DB rows + `carslot.json`).
- **Browse** mounted game libraries, render the active car on a
  pedestal, edit Data_Car stats, swap parts between donors via grab /
  place.
- **Export** back to the same game as a byte-equal or edit-respliced
  zip, or **port** to FH1 as a stand-alone DLC package that drops into
  Xenia's content tree.

## Usage (GUI)

1. Build (see below) and launch `./build/carbin-garage`.
2. **Settings → Game folders**: point at your FM4 and/or FH1 install
   roots. **Settings → Xenia content path**: point at
   `<xenia>/content/` (the directory containing `<profile-id>/<title-id>/…`).
   Saved to `~/.config/carbin-garage/config.json`.
3. **Bottom dropup row** lists each mounted game's roster + your
   `working/` tree. Right-click a game-source car → **Import to
   working/**. Right-click a `working/` car → **Load from working/**
   to render it.
4. **Right pane** shows the active car's parts in tabs. Right-click a
   part → **Grab**; right-click the slot to overwrite → **Replace
   with grabbed**. Donor geometry overwrites host bytes; host slot tag
   is preserved; an undo snapshot is taken; `edits[]` audit logged.
5. **Left pane** edits Data_Car stats (mass, power curve, gearing, …).
   **Save** writes overrides into `working/<slug>/carslot.json`.
6. **Bottom-middle export palette**: pick a target game + mode
   (same-game `export-to`, FH1 DLC `port-to-dlc`) and click Export.

## Usage (CLI)

The GUI calls the same orchestrators. The CLI is the way in for
anything not yet wired into the UI (notably the FH1 xex patch).

```
carbin-garage mount <game-folder>
carbin-garage import <car.zip> --profile fm4
carbin-garage port-to-dlc <working/slug> fh1 --donor <fh1-slug> \
                          --content <xenia-content-dir>
```

`carbin-garage --help` lists every verb. The roadmap and per-verb
context live in `docs/ROADMAP.md` and `docs/APPLET_ARCHITECTURE.md`.

## Build

Requires Nim ≥ 2.2. Devuan/Debian/Ubuntu deps in `build-deps.sh`.

```
./download-deps.sh   # vendors SDL3 / SDL3_image / SDL3_ttf / libmspack / stb / cgltf / bcdec
./build-deps.sh      # static libs into vendor/
./release.sh --local --skip-deps
```

A reproducible static binary build (Ubuntu 20.04 base, glibc compat)
lives in `docker-build/Dockerfile` — that's what GitHub Actions uses
for releases.

## License

**GPL-3.0-or-later.** See `LICENSE`. This is a fan-made,
non-commercial reverse-engineering tool; not affiliated with or
endorsed by Microsoft, Turn 10, or Playground Games.

---

# Nerd section — how it actually works

This section sketches the moving parts and points at `docs/` for the
byte-level truth. The READMEs in `docs/` are the source of authority;
this is just a map.

## Architecture

- **`src/carbin_garage/core/`** — pure-Nim format codecs:
  `carbin/` (parser + emitter, FM4 TypeId 3 + FH1 TypeId 5),
  `xds.nim` (Xenon BC1/3/5 textures, decode + encode + retile),
  `zip21.nim` + `zip21_writer.nim` (PKZip + method 21 LZX, mixed-mode
  writer), `lzx.nim` + `lzx_encode.nim` (libmspack read, wimlib
  write — partial; see below), `cardb.nim` (per-car gamedb.slt
  snippet), `xex2/` + `xex2_patches.nim` (xex2 unpacker / repacker /
  integrity-bypass patcher).
- **`src/carbin_garage/orchestrator/`** — verb-level pipelines:
  `importwc`, `exportto`, `portto`, **`portto_dlc`**, `patchxex`,
  `scan`, `mount`.
- **`src/gui/`** — SDL3 shell. Hand-rolled on raw SDL3 +
  `src/render/` (`ui_solid` / `ui_text` / `ui_circle` / `textured`
  shaders, `OrbitCamera`). No Dear ImGui or Nuklear.
- **`profiles/*.json`** — per-game offsets, paths, IDs. The codec is
  data-driven; add a new Forza by writing a profile.

## Format reverse-engineering

The carbin format ships in two flavors — FM4 (TypeId 3) and FH1
(TypeId 5) — that share a §-structure but disagree on header
expansion, vertex stride (32 → 28 in FH1), `m_NumBoneWeights`
pre-pool block placement, a +4-byte `cvFour → cvFive` subsection
upconvert, and an extra `lod0VCount × 4` post-pool stream on FH1
lod0 / cockpit. Cross-game transcode is **donor splice**: keep the
target's scaffolding, re-quantize the source's section bytes into
the donor's slots. See:

- `docs/FH1_CARBIN_MASTER.md` + `docs/FH1_CARBIN_CONDENSED.md`
- `docs/FM4_CARBIN_MASTER.md` + `docs/FM4_CARBIN_CONDENSED.md`
- `docs/FH1_CARBIN_TYPEID5.md` (FH1-only deltas)
- `docs/CARBIN_TRANSCODE.md` (the donor-splice strategy + per-section
  validation gate)
- `docs/FH1_VS_FM4_OVERVIEW.md` for the high-level diff
- `docs/FH1_PHYSICSDEFINITION_BIN.md` (donor-bin passthrough policy —
  cross-game ports never synthesize the physics blob)
- `docs/FH1_PHYSICS_DB.md` for the gamedb.slt schema

## DLC packaging gotchas

The FH1 runtime has very specific opinions about DLC content. Getting
any of these wrong causes silent skip-on-load:

- `Data_Car.Id` must fall in the base range (FH1: 249..1568); IDs
  above that are silently ignored.
- `merge.slt` must be written with `page_size=1024` AND
  `schema_format_number=1` (header byte 0x2C). Modern SQLite defaults
  are silently rejected.
- The Xenia `.header` sidecar (332 bytes) at
  `Headers/00000002/<packageId>.header` is required for enumeration.
- DLC content must be **loose files** under `cars_pri_<id>/<MediaName>/…`,
  NOT a `.zip`. The 360 zipmount layer doesn't recurse into overlays.
- Package id = `<TitleID-hex><dlcId-as-8-decimal-digits>`; overlay
  dir is `<dlcId>_pri_99/`, NOT `<packageId>_pri_99/`.
- Every CDH entry needs a `0x1123` extra field (FH1's zip21 reader
  requires it; handled in `core/zip21_writer.nim`).
- We use `merge.slt`, not edits to base `gamedb.slt`. Direct
  `gamedb.slt` writes were ruled out after ~6h of in-game iteration:
  the audio init's SQL chain returns 0 rows, SQL CE substitutes its
  error string into the asset path, and the renderer tears on
  open-world spawn. DLC merge.slt loads via a different code path
  and works.

See `docs/PLAN_DLC_PIVOT.md` for the full reasoning trail.

## XEX integrity bypass

FH1's `default.xex` carries a lookup table that hashes 8 media files
(including `gamedb.slt`) and refuses dirty-disc-modified copies.
`patch-xex` is a pure-Nim xex2 unpacker / repacker that scrambles
those 8 filename strings in `.rdata` and splices a hardcoded 16 KiB
known-good optional header (rsa_signature zeroed, header_hash
recomputed) baked in via `staticRead`. Output is byte-equal to the
community-patched reference xex when given the same scramble values.

```
carbin-garage patch-xex <path-to-default.xex>          # idempotent
carbin-garage patch-xex <path-to-default.xex> --restore
```

Not yet wired into the GUI; run it once from the CLI before any
`port-to` deploy. The DLC path (`port-to-dlc`) doesn't need it.
Implementation: `src/carbin_garage/core/xex2/` + `core/xex2_patches.nim`
+ `vendor/xex2_templates/fh1_header.bin`.

## LZX encoder status

`libmspack` reads method-21 LZX zip entries fine. Writing them is
partial: `wimlib`'s `lzx_compress` is wired with four CAB-LZX
compatibility patches and works for single-chunk inputs ≤ 64 KiB.
Multi-chunk encoding desyncs at chunk boundaries because wimlib's
match-finder + recent_offsets aren't streamably persistent. Until
that lands, `core/zip21_writer.nim` is a **mixed-method** writer:
unchanged donor entries pass through as method-21 verbatim; edited
entries emit as method-0 (stored). In-game tolerance of method-0
entries was the question that gated this approach — empirically:
fine.

## Vendored deps

All native deps are vendored under `vendor/` and built static so the
release ships as a single binary:

- **SDL3**, **SDL3_image**, **SDL3_ttf** — windowing, image decode,
  TTF rasterisation
- **libmspack** — LZX decompression (zip method 21)
- **wimlib** — LZX compression (patched for CAB-LZX framing;
  see `patches/wimlib_lzx_cab_compat.patch`)
- **cgltf** — glTF parse-validate at emit time
- **bcdec** — BCn block decoding
- **stb_dxt** + **stb_image** + **stb_image_write** — BCn encoding
  + PNG IO
- **Space Mono** — UI font

Vendored sources are pristine; behavior changes go through `patches/`
applied by `download-deps.sh`. `csrc/` holds the C shims that bridge
into Nim.

## Pointers

- `docs/ROADMAP.md` — current state + next-slice work, refreshed often
- `docs/APPLET_ARCHITECTURE.md` — the architecture destination, phase plan
- `docs/PROBES.md` — validation probes (codec roundtrip, port-shape, etc.)
- `docs/FORZA_LZX_FORMAT.md` — CAB-LZX vs. WIM-LZX framing notes
- `probe/` — Nim + Python validation harnesses
