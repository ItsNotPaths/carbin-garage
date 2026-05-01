## Carbin offset-table types. Port of probe/reference/fm4carbin/model.py.
## CarbinInfo / SectionInfo / SubSectionInfo carry positions into the
## original byte buffer so downstream patchers can rewrite specific
## fields without re-parsing.

type
  SubSectionInfo* = object
    name*: string
    lod*: int32
    start*, endPos*: int
    idxCount*: int32
    idxSize*: int32
    indexType*: uint32
    idxCountPos*, idxSizePos*: int
    idxDataStart*, idxDataEnd*: int
    afterIdxPos*: int
    nameLenPos*, nameBytesEnd*: int
    lodPos*: int
    # Per-subsection UV transform from CCarMaterialData::m_UVOffsetScale.
    # Atlas mapping: uv.x = raw.x*xScale + xOffset; uv.y after Y-flip.
    # uv1 is FM4-only (FH1 vertex stride drops UV1) — fields are still
    # present in the subsection header on both, just unused on FH1.
    uvXScale*, uvYScale*, uvXOffset*, uvYOffset*: float32
    uv1XScale*, uv1YScale*, uv1XOffset*, uv1YOffset*: float32

  SectionInfo* = object
    name*: string
    index*: int
    start*, endPos*: int
    unkType*: int32
    hasUnkType*: bool
    transformPos*: int
    lodVerticesCount*, lodVerticesSize*: uint32
    lodVerticesStart*, lodVerticesEnd*: int
    lod0VerticesCount*: int32
    lod0VerticesSize*: uint32
    lod0VerticesStart*, lod0VerticesEnd*: int
    subsections*: seq[SubSectionInfo]
    nameLenPos*, nameBytesEnd*: int
    lodVertexCountPos*, lodVertexSizePos*: int
    subpartCountPos*: int
    subsectionsStart*, subsectionsEnd*: int
    vertexCountPos*, vertexSizePos*: int
    tailStart*: int

  CarbinVersion* = enum
    cvUnknown = "Unknown"
    cvTwo = "Two"     # FM2 family (TypeIds 1+0x2CA / 2+0x2CA)
    cvThree = "Three" # FM3 family (TypeIds 2+0/1, 1+0)
    cvFour = "Four"   # FM4 family (TypeIds 1+0x10, 2+0x10, 3)
    cvFive = "Five"   # FH1 family (TypeId 5; +0x144 header expansion)

  CarbinInfo* = object
    version*: CarbinVersion
    typeId*: uint32
    partCountDeclared*: uint32
    partCountPos*: int
    sections*: seq[SectionInfo]
    sectionsEnd*: int
