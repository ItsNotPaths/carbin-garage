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
- **LOD0-only sections inside the main carbin** stay donor-verbatim
  via the *gap-preservation* pass (Slice C, see below). The body
  parser raises on these and skips forward; we copy the donor bytes
  between consecutive parsed sections so the LOD0-only data lands in
  the output even though the parser never resolved them as discrete
  `SectionInfo` entries.

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

## Slice C — gap preservation (LANDED 2026-05-02 PM)

Cars with LOD0-only sections inside the main carbin (R8GT_11 has 12;
alfa has 0) ship a section layout the parser can't fully resolve. The
body parser walks `partCount` iterations, and on each iteration's
`parseSection` raise it scans forward for the next valid
`[u32=5][9 sane floats]` marker and resumes. The bytes it scans past
ARE the LOD0-only sections — the layout differs (e.g. no
`m_NumBoneWeights` block before a non-existent LOD pool) and the
parser's structural walk drifts through them.

R8GT_11's parse: `parts: 49 parsed: 37`. Indices 0, 5, 39..48 fail.
Indices 1..4 parse as garbage (zero unk / empty name); 6..38 are real.

Pre-Slice-C, the splice driver only emitted donor bytes for the 37
parsed sections, dropping the bytes between them (where the LOD0-only
sections live). Output declared `partCount=49` but contained byte
ranges for ~37 sections, so FH1's main thread walked off into the
file footer at section 38 → C++ exception E06D7363 at
autoshow→drive transition.

**Fix** (`core/carbin/transcode.nim:spliceCarbin`): inside the
per-section emit loop, before emitting section `k`, check the gap
between `donInfo.sections[k-1].endPos` and `donInfo.sections[k].start`.
If non-zero, copy donor bytes for that range into the output verbatim.
Combined with `preBytes` (donor[0..sections[0].start)) and `postBytes`
(donor[sections[^1].endPos..end)), this preserves donor bytes for
EVERY range between/before/after parsed sections. The unparsed
LOD0-only sections survive byte-for-byte in those ranges.

Spliced sections still get rebuilt from source vertex/index data into
donor's section template; the gap fix only affects bytes the parser
couldn't resolve. Output is structurally identical to donor (same
parsed-section indices, same `partCount`) and byte-different from
donor (real splice).

The transcode log now reports `gaps=N` alongside `spliced` / `fallback`
counts; `R8GT_11.carbin` shows `spliced=31 fallback=6 gaps=1` — the
single mid-list gap between sec[4] and sec[6] (k=5 failed); the
trailing 10 unparsed sections (k=39..48) live inside `postBytes`
already.

## Slice D — damage table cross-game translation (OPEN, 2026-05-02)

After Slice C landed, R8 boots through autoshow→drive in-game without
crash. New issue surfaced: collision deformation produces multi-meter
spike artifacts in body sections. Pristine model renders correctly;
crash deformation explodes.

### Mechanism

Each carbin section's tail (post-§6 c*d region) carries an `a*b table`
of `vCount × 4` bytes — one 4-byte record per vertex. For body
sections this is the per-vertex skinning / damage-zone payload the
deform system reads on impact. For non-deformable sections (seat,
glass non-window, wheel, steering_wheel) `a == 0, b == 0` — table is
absent and FH1 renders the section static-with-skin-scaffold.

`probe/nim_slice_d_probe.nim` across 7 paired FM4↔FH1 cars (184
sections) shows:

- **a/b SHAPE matches 100%** between FM4 and FH1 (always same record
  count and stride).
- **byteEq splits 50/50**: empty tables vacuously equal; body tables
  CONTENT differs between games. Each game's deform model encodes
  different payloads in the 4 bytes (FM4: per-vertex displacement;
  FH1: skeleton-driven skinning indices+weights).
- The docs claim "round-trips verbatim" applies to same-game
  round-trips, NOT cross-game equivalence.

`extra4 bytes 1..3` in the vertex stream are NOT bone weights —
entropy patterns match DEC3N tangent/normal encoding. Slice D doesn't
need to touch the vertex stream.

`perSectionId` is a unique-random 32-bit hash per section; donor's
value is fine to keep for any spliced section.

### Why current code fails

`builders.nim:buildSectionConvertedToTargetLodOnTargetTemplate` line
~250 copies `suffixFromVc = donor[vertexCountPos..end)` verbatim. That
includes donor's a*b table indexed by **donor's vertex order**. We
splice source's vertex pool in source's order. Donor record at slot 0
says "vertex 0 attaches to bone X with weight W" — but source's
vertex 0 lives at a different world-position. Impact moves bone X →
source vertex 0 deflects to wrong world-space → multi-meter spike.

### Slice D plan — translation, not bypass

User explicitly rejected the cop-out (zero out the table). FH1 has an
in-game "no visual damage" toggle as a SAFETY NET, not the strategy.
Implement actual translation via spatial nearest-neighbor remap:

1. **Probe v2**: dump donor `body` section a*b table — slot-by-slot
   histograms + first 16 records + each record paired with its
   vertex's decoded world-position. Confirm slot[0] is a small int
   (bone index, ~20-50 unique values) and adjacent vertices in
   world-space share bone IDs (spatial coherence).
2. **`core/carbin/damage_remap.nim`**: for each src vertex i, decode
   srcPos from vertex bytes, find donor vertex j with min squared
   distance to srcPos, output `donATable[bestJ*4 ..< (bestJ+1)*4]`
   into row i. Naive O(N×M); body has ~12k verts, runs in seconds.
3. **Parser**: extend `SectionInfo` with `aTableStart`, `aTableEnd`,
   `cTableStart`, `cTableEnd`. Currently transient locals in
   `parseSection`.
4. **Builder**: split `suffixFromVc` into `donor[vertexCountPos..tailStart)`
   + `donor[tailStart..aTableStart)` + **remapped a*b table** +
   `donor[aTableEnd..end)`. Add new builder param
   `remappedDamageTable: Option[seq[byte]]`.
5. **Transcode**: in `spliceCarbin`, for each spliced body section
   (a > 0), call remapDamageTable + pass to builder.
6. **In-game test**: crash R8, expect approximately-correct crumple
   instead of spikes.
7. **Escalation**: if NN remap is too lossy at bone-region edges,
   RE FH1 bone hierarchy from physicsdefinition.bin and synthesize
   the table from bone region maps directly.

### What NOT to do

- Don't take Path A "zero out the table" — user explicitly rejected.
- Don't translate FM4's a*b bytes into FH1 form — different deform
  models, bytes are not interchangeable.
- Don't change `mNbw` or `perSectionId` — scaffold metadata, FH1
  expects donor-shaped.

## Limitations (post-Slice C)

- **Cross-game damage deformation**: see Slice D above.

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

Expected output (post-Slice C, FM4 → FH1):

- `[transcode] <CAR>.carbin: spliced=N fallback=M gaps=K`
  - alfa: `spliced=33 fallback=0 gaps=0` (no LOD0-only in main)
  - R8: `spliced=31 fallback=6 gaps=1` (12 LOD0-only sections, one
    mid-list gap + trailing 10 absorbed into postBytes)
- `[transcode] <CAR>_lod0.carbin: spliced=0 fallback=20 gaps=0` (next
  splice target — see *Limitations* below)
- `[transcode] <CAR>_cockpit.carbin: spliced=0 fallback=20 gaps=0`
- All caliper / rotor LOD0s: `spliced=0 fallback=1 gaps=0`

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

**Slice C symmetry (FH1 → FM4)**: gap preservation is direction-
agnostic — `spliceCarbin` always emits donor bytes for ranges between
parsed sections, regardless of which version is donor. FM4 cars don't
typically carry LOD0-only sections in main carbin (cvFour layout is
simpler), so for FH1→FM4 the FM4 donor will likely yield zero gaps and
the loop is a no-op. If a future FM4 donor turns out to have its own
parser-skipped regions, the same gap-emit machinery preserves them.

Donor selection: pick an FM4 car with the same part topology
(matching sections / subsection counts, similar vCounts to allow
`padToTargetVpool=true` if you go that route).

The validation gate logic flips: `lodVerticesSize` should equal 32 not
28, and the trailing-pad slack range may differ — cvFour tails are
fixed-width so `consumed == r.bytes.len` should hold strictly.
