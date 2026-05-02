# Carbin transcode (cross-version splice)

Reference for `core/carbin/transcode.nim` — the FM4 cvFour ↔ FH1 cvFive
mesh splice. Empirically derived 2026-05-01 (Slice B v2 landing).
Authoritative for both directions even though only FM4→FH1 has shipped
in-tree; the reverse direction works by symmetry and the deltas are
captured here so it lands smoothly.

## Strategy: hybrid donor splice

Donor's archive is the byte-level scaffold; source's vertex pool +
subsection geometry get re-quantized into the donor's cvFlavored slots.
This means:

- **Section list** comes from donor (donor's part list is authoritative).
- **Section template** (header, transform, permutation tables, m_NumBoneWeights
  block, tail) comes from donor.
- **LOD vertex pool, subsection bytes, indices** come from source, after
  cross-version conversion.
- **LOD0 pool, lod0/cockpit per-vertex stream, post-pool stream** stays
  donor-verbatim — those slots aren't synthesized yet (see
  *Limitations* below).

Per-section name match drives the splice; on any failure the section
falls back to donor verbatim, so partial transcode (e.g. main spliced,
lod0/cockpit donor) is automatic.

## The four cross-version deltas (cvFour → cvFive)

These are the exact byte-level transformations the splice has to apply.
Reverse direction = invert each.

### 1. Vertex stride 32 → 28

**FM4 vertex (32 bytes)**: `pos[8] uv0[4] uv1[4] quat[8] extra8[8]`.
**FH1 vertex (28 bytes)**: `pos[8] uv0[4] uv1[4] quat[8] extra4[4]`.

**Empirically verified 2026-05-01**: FH1 `[0..24)` is byte-IDENTICAL to
FM4 `[0..24)` across 3000+ paired body vertices. The 4-byte loss
relative to FM4's 32-byte stride lives at the END of the vertex (FM4's
`extra8` → FH1's `extra4`), NOT in the middle.

Implementation: `core/carbin/transcode.nim:fm4PoolToFh1` truncates each
FM4 32-byte vertex to its first 28 bytes verbatim — no per-field
shuffling needed. Reverse direction (FH1 → FM4) zero-pads each FH1
vertex's tail by 4 bytes to reach 32, accepting that FM4's extra8
bytes 4..7 will be zero rather than re-derived.

`extra4` byte 0 matches FM4 `extra8[0]` ~70% of the time (likely a
quantized AO or compact tangent component); bytes 1..3 are re-baked.
The dominant tangent-space data is in the 8-byte `quat` field, so
losing extra4 fidelity has minor visual impact (subtle bumpmap
detail, not catastrophic shading).

**Historical note**: the original Phase-2a documentation claimed FH1
dropped UV1 (offset 12..16). This was inferred from stride math
without byte-level cross-game comparison and was wrong; it placed
FM4's quat at FH1's UV1 slot, causing the shader to read FM4's
extra8 as the quaternion → wrong normals on every vertex → in-game
splotchy black body. See memory
`project_fh1_vertex_layout_corrected.md` for the RE walkthrough.

### 2. cvFive m_NumBoneWeights pre-pool block (+4 or +8 bytes)

cvFive sections carry a `[m_NumBoneWeights u32]` (and conditionally
`[perSectionId u32]` if `m_NumBoneWeights != 0`) BEFORE the LOD pool AND
before the LOD0 pool. cvFour has no such block.

Body / lod0 / cockpit body sections: `m_NumBoneWeights = 1` → both
words present (8 bytes pre-pool).
Caliper / rotor sections: `m_NumBoneWeights = 0` → only the first word
(4 bytes pre-pool).

Builder must SLICE these donor bytes between the `lodVSize` field and
the actual pool start, and re-emit them into the rebuilt section
between the (rewritten) `lodVSize` field and the (rewritten) pool blob.
Implementation: `betweenSizeAndPool` slice in
`core/carbin/builders.nim:buildSectionConvertedToTargetLodOnTargetTemplate`.
Same pattern for the LOD0 pool path.

For cvFour same-game builds the slice is empty (`lodVertexSizePos+4 ==
lodVerticesStart`) so the change is backward-compatible.

Reverse direction (cvFive → cvFour) drops these bytes — donor cvFour
template doesn't have them so they aren't copied over.

### 3. cvFive subsection layout — +4 bytes before idxCount

At the position immediately preceding `idxCount`, cvFour subsections
carry `[u32=3]` and cvFive subsections carry `[u32=4][u32=0]` — 8 bytes
instead of 4. The extra `[u32=0]` follows the patched leading word.

To upconvert a cvFour subsection to cvFive (i.e. for FM4→FH1 splice):

1. Patch the `[u32=3]` at offset `(idxCountPos - 4)` to `[u32=4]`.
2. Insert 4 zero bytes immediately before `idxCountPos`.
3. Shift `idxCountPos`, `idxSizePos`, `idxDataStart`, `idxDataEnd`,
   `afterIdxPos`, and `endPos` of the `SubSectionInfo` by `+4`.

Implementation: `core/carbin/patch.nim:upconvertSubsectionCvFourToCvFive`.
The shifted SubSectionInfo is required for any subsequent index
conversion or restart-marker fixing on the upconverted bytes — those
operations key off `ss.idxCountPos`/`ss.idxSizePos` etc.

Reverse direction (cvFive → cvFour): patch `[u32=4]` → `[u32=3]`,
remove the 4-byte zero word that follows, shift offsets by `-4`. Symmetric.

### 4. cvFive section tail layout

cvFive section tails are 12 bytes longer than cvFour, with extra
fixed-position skip bytes documented in `FH1_CARBIN_TYPEID5.md` §6.
For lod0 / cockpit carbins ONLY, an additional `lod0VCount * 4`-byte
per-vertex stream (likely SHORT2N normals / DEC3N tangents) follows
the c*d table — main carbin sections don't carry this.

The tail block isn't synthesized by the splice — donor's section tail
is preserved verbatim via the `suffixFromVc` slice in the builder.
That means cross-version splice of lod0 / cockpit sections must come
from a donor that already carries the right stream. Reverse direction
preserves donor's cvFour tail similarly.

## Per-section validation gate

After each section splice, single-section reparse the rebuilt bytes
via `core/carbin/parser.nim:tryParseSection` against the target
version. Reject if any of:

- Parse raises (fail open via `tryParseSection`'s try/except).
- `consumed < r.bytes.len - 8` (allow up to 8 bytes of trailing-pad
  slack — see *Trailing-pad delta* below).
- `lodVerticesCount` doesn't match source's expected count.
- Cross-version: rebuilt `lodVerticesSize != 28` (catches missed
  stride rewrites).
- Subsection count doesn't match source's LOD-1 filtered count.
- LOD0 vertex count/size differ from donor's (LOD0 stays donor — drift
  here means the splice trampled a region it shouldn't have).

Failed sections fall back to donor bytes verbatim. The splice driver
returns `(spliced: int, fallback: int)` for diagnostic counters in the
orchestrator's transcode log line.

### Trailing-pad delta

cvFive section tails end with 4..8 bytes of variable padding that the
parser only resolves by probing forward for the next section's marker
(`[u32=5][9 sane floats]`). When validating a section in isolation
there's no next-section marker, so the parser's no-marker fallback
consumes a fixed 4 bytes regardless of actual pad. Allow up to 8 bytes
of slack between `consumed` and `r.bytes.len`.

## Limitations (Slice C and beyond)

- **LOD0-only sections in main carbin (R8 BLOCKER, 2026-05-02)**:
  alfa's main carbin had zero LOD0-only sections (every part has a
  real LOD), so it shipped clean. R8's main carbin has 12 LOD0-only
  sections. The current splice driver's per-section donor-fallback
  path emits empty / malformed bytes at those slots — `nim_parse_dump`
  on the output reports `parts: 49 parsed: 37` with the first 4
  sections coming back as `hasUnk=false unk=-1 off=(0,0,0)`. FH1
  enters autoshow OK (LOD0 fallback chain renders something) but
  throws C++ exception E06D7363 on autoshow→drive transition when the
  renderer/physics dereferences the malformed section data.

  **Fix scope**: in `core/carbin/transcode.nim:tmHybridSplice`,
  detect `donSec.lod0VerticesCount > 0 and donSec.lodVerticesCount == 0`
  and emit donor's section bytes verbatim into the output buffer at
  the section's slot. Track sections-end so the parts-count footer
  stays consistent. Validate via `probe/nim_parse_dump` on the
  output: should report `parts: 49 parsed: 49`, all sections show
  non-zero name + `unk=5` + correct off/tgt fields.

- **LOD0-only sections in standalone carbins** (lod0.carbin,
  cockpit.carbin, caliper / rotor LOD0s): splice driver currently
  skips these (the `donSec.lodVerticesCount > 0` and
  `srcSec.lodVerticesCount > 0` gate). They fall back to donor
  verbatim, which works because the cars share the donor's mesh; for
  cars that don't have a paired donor, this is the next splice slot.
  Plumbing: extend the LOD0 path of the builder with the same
  forced-stride hooks already in the LOD path, and unconditionally
  enable subsection upconvert when crossVersion.

- **lod0 / cockpit per-vertex post-pool stream**: 4 bytes per vertex
  that FH1's lod0/cockpit carbins carry after the c*d table. Donor's
  stream is preserved by the section-tail passthrough but cross-game
  synthesis (when source isn't FH1) needs format RE.

- **Stripped / TypeId 0 carbins**: `passthroughCarbin` for now.

- **Cross-game `_lod0.carbin` and `_cockpit.carbin`**: while the file
  parses cleanly, every section currently falls back to donor since
  most have only LOD0 pools. Slice C work.

## Test recipe

```
build/carbin-garage import "/run/media/paths/SSS-Games/fm4-xex/4D530910/00007000/33E7B39F/Media/cars/ALF_8C_08.zip" --profile fm4
build/carbin-garage port-to-dlc working/ALF_8C_08 fh1 \
  --donor ALF_8C_08 \
  --content /run/media/paths/SSS-Games/xenia_canary_windows/content \
  --name ALF_8C_08_FM4PORT --dlc-id 730 --replace
nim c -r --hints:off -d:release --out:/tmp/check.bin probe/nim_transcode_v1_check.nim
```

Expected output (post-Slice B v2, FM4 → FH1):

- `[transcode] <CAR>.carbin: spliced=33 fallback=0`
- `[transcode] <CAR>_lod0.carbin: spliced=0 fallback=20` (Slice C)
- `[transcode] <CAR>_cockpit.carbin: spliced=0 fallback=20` (Slice C)
- All caliper / rotor LOD0s: `spliced=0 fallback=1` (Slice C)

Probe shows main carbin reparses with all-28 LOD strides; rebuilt
output is byte-different from donor, confirming real splice.

For tracing per-section behavior, build with
`-d:TranscodeTrace=true`. The flag stays off in normal release builds.

## Reverse direction (FH1 → FM4): playbook

By symmetry of each delta:

1. **Stride 28 → 32**: append 4 zero bytes at the END of each FH1
   vertex (extra4 → extra8 by zero-padding bytes 4..7). pos / uv0 /
   uv1 / quat / extra4 byte 0 carry over verbatim. FM4's extra8 bytes
   1..7 may have carried fully-baked tangent data that FH1's compact
   extra4 doesn't preserve, so the reverse port loses some bumpmap
   detail — visually minor.
2. **Pre-pool block**: don't emit it — cvFour template doesn't have it.
3. **Subsection +4 bytes**: invert `upconvertSubsectionCvFourToCvFive`
   — patch `[u32=4]` → `[u32=3]`, drop the trailing `[u32=0]`, shift
   SubSectionInfo offsets by `-4`.
4. **Section tail**: cvFour tail is 12 bytes shorter; reuse donor's
   cvFour template tail via `suffixFromVc`.

Donor selection: pick an FM4 car with the same part topology
(matching sections / subsection counts, similar vCounts to allow
`padToTargetVpool=true` if you go that route).

The validation gate logic flips: `lodVerticesSize` should equal 32 not
28, and the trailing-pad slack range may differ — cvFour tails are
fixed-width so `consumed == r.bytes.len` should hold strictly.
