# Probes — What's Built So Far

Python probe scripts under `probe/` plus a small C helper for LZX
decompression. Probes are throwaway-ish: each one answers one question
and dumps results under `probe/out/`. The reusable bits are
`probe/lzxzip.py` (zip/LZX library) and `probe/c/lzx_inflate` (libmspack
driver).

## Build

```sh
# One-time: get libmspack (kyz/libmspack on GitHub)
./download-deps.sh

# Build the LZX inflater
make -C probe/c
```

Produces `probe/c/lzx_inflate`. No autotools needed — compiles libmspack's
`lzxd.c` and `system.c` directly.

## Library: `probe/lzxzip.py`

```python
from lzxzip import list_entries, extract

# List entries in a method-21 zip
entries = list_entries(Path('.../ALF_8C_08.zip'))
# Each entry: name, method (0=stored, 21=LZX), csize, usize, crc32, header_offset

# Extract one entry to disk (handles both stored and LZX)
e = next(x for x in entries if x.name.lower() == 'carattribs.xml')
extract(zip_path, e, Path('out/carattribs.xml'))
```

CLI mode for one-off extracts:
```sh
python3 probe/lzxzip.py <zip> <member> <out>
```

Wraps `probe/c/lzx_inflate` for the actual decompression. The `0xff`-prefixed
single-frame variant and the multi-chunk variant are both handled.

## Probe scripts

### `probe_diff_configs.py`

Across all 79 shared cars, extract per-car `carattribs.xml`, `maxdata.xml`,
`shadersettings.xml`, `versiondata.xml`, `physicsdefinition.bin` from
both games. Diffs same-name pairs with `diff -u` for text and reports
size for binaries.

Output: `probe/out/diff/<car>/{fm4_*,fh1_*,diff_*.diff}`

Headline: `physics/maxdata.xml` is byte-identical between FM4 and FH1
for **74/76** shared cars. `carattribs.xml` differs almost everywhere
(Version 16 → 21 + format-only drift).

### `probe_assets.py`

Catalogues every member across both archives by extension/name pattern.
Buckets: `carbin_main / _lod0 / _cockpit / _caliper / _rotor / _stripped`,
`xds_damage / _nodamage / _lights / _interior / _normalmap / _gauge / _other`,
`tga_livery`, `dash_{bgf,bsg,fbf}`, `physics_{xml,bin}`,
`xml_{carattribs,shadersettings,versiondata,livery}`, etc.

Outputs:
- `probe/out/asset_summary.tsv` — aggregate count + total bytes per
  bucket per game
- `probe/out/asset_diff/<car>.txt` — per-car detail report

### `probe_texture_eq.py`

For shared-name `.xds` members across shared cars, decompress both and
compare SHA-256. Bucket the equality results to see which texture
categories are drop-in vs reworked.

Output: `probe/out/texture_eq.tsv` (`car \t member \t fm4_size \t fh1_size \t equal`)

Headline (10-car sample): normalmaps and gauges are 100% identical
across games; lights are 90% reworked; damage textures are mixed.

### `probe_typeid5_layout.py`

Per-word classification of FM4 (TypeId 2) vs FH1 (TypeId 5) carbin
headers across 8 sample cars. Identifies:
- Z (zero across all cars)
- C (constant non-zero)
- V (varies per car)

Plus a cross-game anchor finder that locates per-car float values
present in both files at potentially-different offsets, with a 3-of-8
floor to filter coincidence.

Output: `probe/out/typeid5_layout.txt`. Headline conclusion in
`docs/FH1_CARBIN_TYPEID5.md`.

## Sample / scratch files

- `probe/out/carbin_typeid5/{fm4,fh1}_<car>.carbin` — extracted main
  carbins for 8 sample cars (used by the TypeId 5 probe).
- `probe/out/carbin_samples/{fm4,fh1}_main.carbin` — the original
  ALF_8C_08 main carbin pair from the first decompression test.
- `probe/out/diff/<car>/` — per-car XML extracts from `probe_diff_configs`.
- `probe/out/_xds_strip.bin`, `_carbin_decoded.bin`, etc. — leftover
  scratch from the LZX framing investigation. Safe to delete.

## What's not yet probed

- FH1's `gamedb.slt` (path was wrong on first attempt; need to re-check
  case-sensitivity).
- `Media/physics.zip` (FH1) — global physics rules, in a zip rather
  than loose like FM4.
- `Database.xmplr` (FM4 root) — PIRS / Xbox 360 STFS package.
  Decoder TBD; relevance: probably not per-car physics.
- `staticCarCubemap.xpr` (per-track) — Xbox Packed Resource format,
  cubemap data. Relevant for visual fidelity but not per-car.
- `physicsdefinition.bin` schema — gated on the SQL ↔ bin correlation
  approach described in `docs/FH1_PHYSICS_DB.md`.
- TypeId 5 body parser equivalence — does the FM4 docs' post-header
  parse (unkCount → partCount → ForzaCarSection) work unchanged on
  TypeId 5?
- Stripped carbin (TypeId 0?) layout for FH1.
- LZX **encoding** — only decode is wired up. Encoder ships with libmspack
  (`lzxc.c`) but unverified against the game runtime.
