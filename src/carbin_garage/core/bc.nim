## bcdec wrapper. Phase 1 = decode .xds (BC1/3/5) → RGBA → PNG.
## Phase 2 adds stb_dxt encode for re-export.
## C impl in csrc/bcdec_impl.c.

{.compile: "../../../csrc/bcdec_impl.c".}

# Single-block decoders. The orchestrator slices an .xds payload into
# 4×4 BC blocks and walks them; for now expose only what we need.

proc bcdec_bc1*(compressedBlock: pointer, decompressedBlock: pointer,
                destinationPitch: cint) {.importc, header: "bcdec.h".}
proc bcdec_bc3*(compressedBlock: pointer, decompressedBlock: pointer,
                destinationPitch: cint) {.importc, header: "bcdec.h".}
proc bcdec_bc5*(compressedBlock: pointer, decompressedBlock: pointer,
                destinationPitch: cint) {.importc, header: "bcdec.h".}
