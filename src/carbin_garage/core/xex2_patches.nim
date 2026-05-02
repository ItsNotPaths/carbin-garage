## Patch tables + hardcoded header templates for known xex2 binaries.
##
## Each patch entry is `(image_offset, vanilla_bytes, patched_bytes)` —
## offsets are into the *decrypted* PE image (image_base + offset =
## virtual address). The `patch-xex` orchestrator verifies each
## vanilla_bytes still appears at its image_offset before applying
## patched_bytes; mismatch = different version of the xex than what we
## know how to patch.
##
## ## Why a header template?
##
## Patching the decrypted PE image changes the cipher payload after
## re-encrypt, which is fine on its own — but the FH1 loader validates
## a `header_hash` field whose hash domain we couldn't decode by brute
## force. The community-patched xex this hardcoded template comes from
## solves the validation by zeroing rsa_signature + recomputing
## header_hash for a restructured layout. Splicing that header verbatim
## (with our re-encrypted payload that scrambles the integrity-check
## strings to OUR taste rather than theirs) yields a loader-accepting
## result without re-implementing the hash recompute.

type
  XexPatchSite* = object
    imageOffset*: int
    vanilla*: seq[uint8]
    patched*: seq[uint8]
    note*: string

  XexPatchSet* = object
    titleId*: string
    name*: string
    description*: string
    sites*: seq[XexPatchSite]

proc bytesOf(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  for i, c in s: result[i] = uint8(ord(c))

# Hardcoded FH1 default.xex header (bytes [0..0x4000), 16 KiB) from a
# community-patched copy: rsa_signature = 0, header_hash recomputed for
# a restructured optional-header layout. Splicing this verbatim over the
# user's vanilla xex's header sidesteps the loader's header-integrity
# check. The encrypted_image_key in this template equals the vanilla
# value, so vanilla's session key still works for our re-encryption.
const Fh1HeaderTemplate*: string = staticRead(
  "../../../vendor/xex2_templates/fh1_header.bin")

proc fh1HeaderTemplateBytes*(): seq[uint8] =
  result = newSeq[uint8](Fh1HeaderTemplate.len)
  for i in 0 ..< Fh1HeaderTemplate.len:
    result[i] = uint8(Fh1HeaderTemplate[i])

# FH1 — disable integrity-check lookup for moddable files.
# Scrambles the filename strings in the .rdata integrity-check lookup
# table so lookups miss and the per-file hash check is skipped, letting
# us modify gamedb.slt + the listed media zips without dirty-disc
# errors. Companion to Fh1HeaderTemplate above which handles the
# loader's separate header_hash check via splice.
let Fh1IntegrityBypassPatch* = XexPatchSet(
  titleId: "4D5309C9",
  name: "fh1-integrity-bypass",
  description: "Disable per-file integrity checks on gamedb.slt + 8 " &
               "moddable media zips (camera, gamedb, gamemodes, " &
               "gametunablesettings, physics, renderscenarios, UI, " &
               "zipmanifest). Required before any port-to deploy.",
  sites: @[
    XexPatchSite(imageOffset: 0x1521108, vanilla: bytesOf("camera"),
                 patched: bytesOf("abcabc"),
                 note: "camera.zip"),
    XexPatchSite(imageOffset: 0x1521156, vanilla: bytesOf("gamedb"),
                 patched: bytesOf("FORZAH"),
                 note: "gamedb.slt — THE one we care about for car ports"),
    XexPatchSite(imageOffset: 0x1521c81, vanilla: bytesOf("gamemodes"),
                 patched: bytesOf("abcdefghi"),
                 note: "gamemodes.zip"),
    XexPatchSite(imageOffset: 0x152208f, vanilla: bytesOf("gametunablesettings"),
                 patched: bytesOf("silvaze-love-forev-"),
                 note: "gametunablesettings.zip"),
    XexPatchSite(imageOffset: 0x152214f, vanilla: bytesOf("physics"),
                 patched: bytesOf("abcdefg"),
                 note: "physics.zip"),
    XexPatchSite(imageOffset: 0x15221ba, vanilla: bytesOf("ren"),
                 patched: bytesOf("abc"),
                 note: "renderscenarios.zip (1/3)"),
    XexPatchSite(imageOffset: 0x15221bf, vanilla: bytesOf("rscenari"),
                 patched: bytesOf("fghkijlm"),
                 note: "renderscenarios.zip (2/3)"),
    XexPatchSite(imageOffset: 0x15221c8, vanilla: bytesOf("s"),
                 patched: bytesOf("p"),
                 note: "renderscenarios.zip (3/3)"),
    XexPatchSite(imageOffset: 0x152af36, vanilla: bytesOf("ui"),
                 patched: bytesOf("ab"),
                 note: "UI.zip"),
    XexPatchSite(imageOffset: 0x153e7fa, vanilla: bytesOf("zipma"),
                 patched: bytesOf("FORZA"),
                 note: "zipmanifest.xml")])
