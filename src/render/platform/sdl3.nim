# Hand-written SDL3 / SDL3_image / SDL3_mixer shim for the triangle prototype.
#
# Opaque handle types plus just enough create-info structs to stand up the GPU
# pipeline. Fields use the exact spellings from the C headers so Nim's codegen
# lines up with the real struct layouts.

{.passC: "-Ivendor/_prefix/include".}

const
  SDL_Header      = "SDL3/SDL.h"
  SDL_GPUHeader   = "SDL3/SDL_gpu.h"
  SDL_ImageHeader = "SDL3_image/SDL_image.h"
  SDL_MixerHeader = "SDL3_mixer/SDL_mixer.h"
  SDL_TTFHeader   = "SDL3_ttf/SDL_ttf.h"

type
  Uint8*  = uint8
  Uint32* = uint32

# ---------------------------------------------------------------------------
# Core SDL3

type
  SDL_Window*  {.importc: "SDL_Window",  header: SDL_Header, incompleteStruct.} = object
  SDL_Surface* {.importc: "SDL_Surface", header: SDL_Header, bycopy.} = object
    w* {.importc: "w".}: cint
    h* {.importc: "h".}: cint
    pitch* {.importc: "pitch".}: cint
    pixels* {.importc: "pixels".}: pointer

  SDL_Event* {.importc: "SDL_Event", header: SDL_Header, bycopy, union.} = object
    `type`* {.importc: "type".}: uint32
    padding: array[128, byte]

  SDL_FColor* {.importc: "SDL_FColor", header: SDL_Header, bycopy.} = object
    r* {.importc: "r".}: cfloat
    g* {.importc: "g".}: cfloat
    b* {.importc: "b".}: cfloat
    a* {.importc: "a".}: cfloat

  SDL_Color* {.importc: "SDL_Color", header: SDL_Header, bycopy.} = object
    r* {.importc: "r".}: uint8
    g* {.importc: "g".}: uint8
    b* {.importc: "b".}: uint8
    a* {.importc: "a".}: uint8

  SDL_IOStream* {.importc: "SDL_IOStream", header: SDL_Header, incompleteStruct.} = object

const
  SDL_INIT_AUDIO* = 0x00000010'u32
  SDL_INIT_VIDEO* = 0x00000020'u32
  SDL_EVENT_QUIT*        = 0x100'u32
  SDL_EVENT_KEY_DOWN*    = 0x300'u32
  SDL_EVENT_KEY_UP*      = 0x301'u32
  SDL_EVENT_TEXT_INPUT*  = 0x303'u32
  SDL_EVENT_MOUSE_WHEEL* = 0x403'u32
  SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK*  = 0xFFFFFFFF'u32
  SDL_AUDIO_DEVICE_DEFAULT_RECORDING* = 0xFFFFFFFE'u32

type
  SDL_MouseWheelEvent* {.importc: "SDL_MouseWheelEvent", header: SDL_Header, bycopy.} = object
    `type`*       {.importc: "type".}: uint32
    reserved*     {.importc: "reserved".}: uint32
    timestamp*    {.importc: "timestamp".}: uint64
    windowID*     {.importc: "windowID".}: uint32
    which*        {.importc: "which".}: uint32
    x*            {.importc: "x".}: cfloat
    y*            {.importc: "y".}: cfloat
    direction*    {.importc: "direction".}: uint32
    mouse_x*      {.importc: "mouse_x".}: cfloat
    mouse_y*      {.importc: "mouse_y".}: cfloat

  SDL_Keycode* = uint32
  SDL_Keymod*  = uint16

  SDL_KeyboardEvent* {.importc: "SDL_KeyboardEvent", header: SDL_Header, bycopy.} = object
    `type`*    {.importc: "type".}: uint32
    reserved*  {.importc: "reserved".}: uint32
    timestamp* {.importc: "timestamp".}: uint64
    windowID*  {.importc: "windowID".}: uint32
    which*     {.importc: "which".}: uint32
    scancode*  {.importc: "scancode".}: cint
    key*       {.importc: "key".}: SDL_Keycode
    `mod`*     {.importc: "mod".}: SDL_Keymod
    raw*       {.importc: "raw".}: uint16
    down*      {.importc: "down".}: bool
    repeat*    {.importc: "repeat".}: bool

  SDL_TextInputEvent* {.importc: "SDL_TextInputEvent", header: SDL_Header, bycopy.} = object
    `type`*    {.importc: "type".}: uint32
    reserved*  {.importc: "reserved".}: uint32
    timestamp* {.importc: "timestamp".}: uint64
    windowID*  {.importc: "windowID".}: uint32
    text*      {.importc: "text".}: cstring

proc SDL_Init*(flags: uint32): bool {.importc, header: SDL_Header.}
proc SDL_Quit*() {.importc, header: SDL_Header.}
proc SDL_GetError*(): cstring {.importc, header: SDL_Header.}
proc SDL_Log*(fmt: cstring) {.importc, header: SDL_Header, varargs.}

proc SDL_CreateWindow*(title: cstring, w, h: cint, flags: uint64): ptr SDL_Window
  {.importc, header: SDL_Header.}
proc SDL_DestroyWindow*(win: ptr SDL_Window) {.importc, header: SDL_Header.}

proc SDL_PollEvent*(event: ptr SDL_Event): bool {.importc, header: SDL_Header.}
proc SDL_DestroySurface*(s: ptr SDL_Surface) {.importc, header: SDL_Header.}

type SDL_PixelFormat* = cint

const SDL_PIXELFORMAT_ABGR8888* : SDL_PixelFormat = 0x16762004

proc SDL_ConvertSurface*(surface: ptr SDL_Surface;
                         format: SDL_PixelFormat): ptr SDL_Surface
  {.importc, header: SDL_Header.}

proc SDL_IOFromConstMem*(mem: pointer; size: csize_t): ptr SDL_IOStream
  {.importc, header: SDL_Header.}

# ---------------------------------------------------------------------------
# SDL3 GPU

type
  SDL_GPUDevice*            {.importc: "SDL_GPUDevice",            header: SDL_GPUHeader, incompleteStruct.} = object
  SDL_GPUBuffer*            {.importc: "SDL_GPUBuffer",            header: SDL_GPUHeader, incompleteStruct.} = object
  SDL_GPUTexture*           {.importc: "SDL_GPUTexture",           header: SDL_GPUHeader, incompleteStruct.} = object
  SDL_GPUSampler*           {.importc: "SDL_GPUSampler",           header: SDL_GPUHeader, incompleteStruct.} = object
  SDL_GPUShader*            {.importc: "SDL_GPUShader",            header: SDL_GPUHeader, incompleteStruct.} = object
  SDL_GPUGraphicsPipeline*  {.importc: "SDL_GPUGraphicsPipeline",  header: SDL_GPUHeader, incompleteStruct.} = object
  SDL_GPUCommandBuffer*     {.importc: "SDL_GPUCommandBuffer",     header: SDL_GPUHeader, incompleteStruct.} = object
  SDL_GPURenderPass*        {.importc: "SDL_GPURenderPass",        header: SDL_GPUHeader, incompleteStruct.} = object
  SDL_GPUCopyPass*          {.importc: "SDL_GPUCopyPass",          header: SDL_GPUHeader, incompleteStruct.} = object
  SDL_GPUTransferBuffer*    {.importc: "SDL_GPUTransferBuffer",    header: SDL_GPUHeader, incompleteStruct.} = object

  SDL_GPUShaderFormat*    = uint32
  SDL_GPUShaderStage*     = cint
  SDL_GPUPrimitiveType*   = cint
  SDL_GPUFillMode*        = cint
  SDL_GPUCullMode*        = cint
  SDL_GPUFrontFace*       = cint
  SDL_GPUTextureFormat*   = cint
  SDL_GPULoadOp*          = cint
  SDL_GPUStoreOp*         = cint
  SDL_GPUTextureType*     = cint
  SDL_GPUTextureUsageFlags* = uint32
  SDL_GPUTransferBufferUsage* = cint
  SDL_GPUSampleCount*     = cint
  SDL_GPUFilter*          = cint
  SDL_GPUSamplerMipmapMode* = cint
  SDL_GPUSamplerAddressMode* = cint
  SDL_GPUCompareOp*       = cint
  SDL_GPUStencilOp*       = cint
  SDL_GPUVertexInputRate* = cint
  SDL_GPUVertexElementFormat* = cint
  SDL_GPUIndexElementSize*    = cint
  SDL_GPUBufferUsageFlags*    = uint32
  SDL_GPUBlendFactor*         = cint
  SDL_GPUBlendOp*             = cint
  SDL_GPUColorComponentFlags* = uint8

  SDL_GPUShaderCreateInfo* {.importc, header: SDL_GPUHeader, bycopy.} = object
    code_size*  {.importc: "code_size".}:  csize_t
    code*       {.importc: "code".}:       ptr uint8
    entrypoint* {.importc: "entrypoint".}: cstring
    format*     {.importc: "format".}:     SDL_GPUShaderFormat
    stage*      {.importc: "stage".}:      SDL_GPUShaderStage
    num_samplers*         {.importc: "num_samplers".}:         uint32
    num_storage_textures* {.importc: "num_storage_textures".}: uint32
    num_storage_buffers*  {.importc: "num_storage_buffers".}:  uint32
    num_uniform_buffers*  {.importc: "num_uniform_buffers".}:  uint32
    props* {.importc: "props".}: uint32

  SDL_GPUVertexInputState* {.importc, header: SDL_GPUHeader, bycopy.} = object
    vertex_buffer_descriptions* {.importc: "vertex_buffer_descriptions".}: pointer
    num_vertex_buffers*         {.importc: "num_vertex_buffers".}: uint32
    vertex_attributes*          {.importc: "vertex_attributes".}: pointer
    num_vertex_attributes*      {.importc: "num_vertex_attributes".}: uint32

  SDL_GPURasterizerState* {.importc, header: SDL_GPUHeader, bycopy.} = object
    fill_mode*   {.importc: "fill_mode".}:  SDL_GPUFillMode
    cull_mode*   {.importc: "cull_mode".}:  SDL_GPUCullMode
    front_face*  {.importc: "front_face".}: SDL_GPUFrontFace
    depth_bias_constant_factor* {.importc: "depth_bias_constant_factor".}: cfloat
    depth_bias_clamp*           {.importc: "depth_bias_clamp".}:           cfloat
    depth_bias_slope_factor*    {.importc: "depth_bias_slope_factor".}:    cfloat
    enable_depth_bias* {.importc: "enable_depth_bias".}: bool
    enable_depth_clip* {.importc: "enable_depth_clip".}: bool

  SDL_GPUMultisampleState* {.importc, header: SDL_GPUHeader, bycopy.} = object
    sample_count*             {.importc: "sample_count".}:             SDL_GPUSampleCount
    sample_mask*              {.importc: "sample_mask".}:              uint32
    enable_mask*              {.importc: "enable_mask".}:              bool
    enable_alpha_to_coverage* {.importc: "enable_alpha_to_coverage".}: bool

  SDL_GPUStencilOpState* {.importc: "SDL_GPUStencilOpState", header: SDL_GPUHeader, bycopy.} = object
    fail_op*       {.importc: "fail_op".}:       SDL_GPUStencilOp
    pass_op*       {.importc: "pass_op".}:       SDL_GPUStencilOp
    depth_fail_op* {.importc: "depth_fail_op".}: SDL_GPUStencilOp
    compare_op*    {.importc: "compare_op".}:    SDL_GPUCompareOp

  SDL_GPUDepthStencilState* {.importc: "SDL_GPUDepthStencilState", header: SDL_GPUHeader, bycopy.} = object
    compare_op*          {.importc: "compare_op".}:          SDL_GPUCompareOp
    back_stencil_state*  {.importc: "back_stencil_state".}:  SDL_GPUStencilOpState
    front_stencil_state* {.importc: "front_stencil_state".}: SDL_GPUStencilOpState
    compare_mask*        {.importc: "compare_mask".}:        uint8
    write_mask*          {.importc: "write_mask".}:          uint8
    enable_depth_test*   {.importc: "enable_depth_test".}:   bool
    enable_depth_write*  {.importc: "enable_depth_write".}:  bool
    enable_stencil_test* {.importc: "enable_stencil_test".}: bool

  SDL_GPUColorTargetBlendState* {.importc: "SDL_GPUColorTargetBlendState", header: SDL_GPUHeader, bycopy.} = object
    src_color_blendfactor* {.importc: "src_color_blendfactor".}: SDL_GPUBlendFactor
    dst_color_blendfactor* {.importc: "dst_color_blendfactor".}: SDL_GPUBlendFactor
    color_blend_op*        {.importc: "color_blend_op".}:        SDL_GPUBlendOp
    src_alpha_blendfactor* {.importc: "src_alpha_blendfactor".}: SDL_GPUBlendFactor
    dst_alpha_blendfactor* {.importc: "dst_alpha_blendfactor".}: SDL_GPUBlendFactor
    alpha_blend_op*        {.importc: "alpha_blend_op".}:        SDL_GPUBlendOp
    color_write_mask*       {.importc: "color_write_mask".}:       SDL_GPUColorComponentFlags
    enable_blend*           {.importc: "enable_blend".}:           bool
    enable_color_write_mask* {.importc: "enable_color_write_mask".}: bool

  SDL_GPUColorTargetDescription* {.importc, header: SDL_GPUHeader, bycopy.} = object
    format*      {.importc: "format".}:      SDL_GPUTextureFormat
    blend_state* {.importc: "blend_state".}: SDL_GPUColorTargetBlendState

  SDL_GPUGraphicsPipelineTargetInfo* {.importc, header: SDL_GPUHeader, bycopy.} = object
    color_target_descriptions* {.importc: "color_target_descriptions".}: ptr SDL_GPUColorTargetDescription
    num_color_targets*         {.importc: "num_color_targets".}:         uint32
    depth_stencil_format*      {.importc: "depth_stencil_format".}:      SDL_GPUTextureFormat
    has_depth_stencil_target*  {.importc: "has_depth_stencil_target".}:  bool

  SDL_GPUGraphicsPipelineCreateInfo* {.importc, header: SDL_GPUHeader, bycopy.} = object
    vertex_shader*        {.importc: "vertex_shader".}:       ptr SDL_GPUShader
    fragment_shader*      {.importc: "fragment_shader".}:     ptr SDL_GPUShader
    vertex_input_state*   {.importc: "vertex_input_state".}:  SDL_GPUVertexInputState
    primitive_type*       {.importc: "primitive_type".}:      SDL_GPUPrimitiveType
    rasterizer_state*     {.importc: "rasterizer_state".}:    SDL_GPURasterizerState
    multisample_state*    {.importc: "multisample_state".}:   SDL_GPUMultisampleState
    depth_stencil_state*  {.importc: "depth_stencil_state".}: SDL_GPUDepthStencilState
    target_info*          {.importc: "target_info".}:         SDL_GPUGraphicsPipelineTargetInfo
    props* {.importc: "props".}: uint32

  SDL_GPUColorTargetInfo* {.importc, header: SDL_GPUHeader, bycopy.} = object
    texture*              {.importc: "texture".}:              ptr SDL_GPUTexture
    mip_level*            {.importc: "mip_level".}:            uint32
    layer_or_depth_plane* {.importc: "layer_or_depth_plane".}: uint32
    clear_color*          {.importc: "clear_color".}:          SDL_FColor
    load_op*              {.importc: "load_op".}:              SDL_GPULoadOp
    store_op*             {.importc: "store_op".}:             SDL_GPUStoreOp
    resolve_texture*      {.importc: "resolve_texture".}:      ptr SDL_GPUTexture
    resolve_mip_level*    {.importc: "resolve_mip_level".}:    uint32
    resolve_layer*        {.importc: "resolve_layer".}:        uint32
    cycle*                {.importc: "cycle".}:                bool
    cycle_resolve_texture* {.importc: "cycle_resolve_texture".}: bool

  SDL_GPUTextureCreateInfo* {.importc, header: SDL_GPUHeader, bycopy.} = object
    `type`*              {.importc: "type".}:                 SDL_GPUTextureType
    format*              {.importc: "format".}:               SDL_GPUTextureFormat
    usage*               {.importc: "usage".}:                SDL_GPUTextureUsageFlags
    width*               {.importc: "width".}:                uint32
    height*              {.importc: "height".}:               uint32
    layer_count_or_depth* {.importc: "layer_count_or_depth".}: uint32
    num_levels*          {.importc: "num_levels".}:           uint32
    sample_count*        {.importc: "sample_count".}:         SDL_GPUSampleCount
    props*               {.importc: "props".}:                uint32

  SDL_GPUTransferBufferCreateInfo* {.importc, header: SDL_GPUHeader, bycopy.} = object
    usage* {.importc: "usage".}: SDL_GPUTransferBufferUsage
    size*  {.importc: "size".}:  uint32
    props* {.importc: "props".}: uint32

  SDL_GPUTextureTransferInfo* {.importc, header: SDL_GPUHeader, bycopy.} = object
    transfer_buffer* {.importc: "transfer_buffer".}: ptr SDL_GPUTransferBuffer
    offset*          {.importc: "offset".}:          uint32
    pixels_per_row*  {.importc: "pixels_per_row".}:  uint32
    rows_per_layer*  {.importc: "rows_per_layer".}:  uint32

  SDL_GPUSamplerCreateInfo* {.importc, header: SDL_GPUHeader, bycopy.} = object
    min_filter*     {.importc: "min_filter".}:     SDL_GPUFilter
    mag_filter*     {.importc: "mag_filter".}:     SDL_GPUFilter
    mipmap_mode*    {.importc: "mipmap_mode".}:    SDL_GPUSamplerMipmapMode
    address_mode_u* {.importc: "address_mode_u".}: SDL_GPUSamplerAddressMode
    address_mode_v* {.importc: "address_mode_v".}: SDL_GPUSamplerAddressMode
    address_mode_w* {.importc: "address_mode_w".}: SDL_GPUSamplerAddressMode
    mip_lod_bias*   {.importc: "mip_lod_bias".}:   cfloat
    max_anisotropy* {.importc: "max_anisotropy".}: cfloat
    compare_op*     {.importc: "compare_op".}:     SDL_GPUCompareOp
    min_lod*        {.importc: "min_lod".}:        cfloat
    max_lod*        {.importc: "max_lod".}:        cfloat
    enable_anisotropy* {.importc: "enable_anisotropy".}: bool
    enable_compare*    {.importc: "enable_compare".}:    bool
    props*          {.importc: "props".}: uint32

  SDL_GPUTextureSamplerBinding* {.importc, header: SDL_GPUHeader, bycopy.} = object
    texture* {.importc: "texture".}: ptr SDL_GPUTexture
    sampler* {.importc: "sampler".}: ptr SDL_GPUSampler

  SDL_GPUTextureRegion* {.importc, header: SDL_GPUHeader, bycopy.} = object
    texture*  {.importc: "texture".}:  ptr SDL_GPUTexture
    mip_level* {.importc: "mip_level".}: uint32
    layer*    {.importc: "layer".}:    uint32
    x*        {.importc: "x".}:        uint32
    y*        {.importc: "y".}:        uint32
    z*        {.importc: "z".}:        uint32
    w*        {.importc: "w".}:        uint32
    h*        {.importc: "h".}:        uint32
    d*        {.importc: "d".}:        uint32

  SDL_GPUBufferCreateInfo* {.importc: "SDL_GPUBufferCreateInfo", header: SDL_GPUHeader, bycopy.} = object
    usage* {.importc: "usage".}: SDL_GPUBufferUsageFlags
    size*  {.importc: "size".}:  uint32
    props* {.importc: "props".}: uint32

  SDL_GPUBufferRegion* {.importc: "SDL_GPUBufferRegion", header: SDL_GPUHeader, bycopy.} = object
    buffer* {.importc: "buffer".}: ptr SDL_GPUBuffer
    offset* {.importc: "offset".}: uint32
    size*   {.importc: "size".}:   uint32

  SDL_GPUTransferBufferLocation* {.importc: "SDL_GPUTransferBufferLocation", header: SDL_GPUHeader, bycopy.} = object
    transfer_buffer* {.importc: "transfer_buffer".}: ptr SDL_GPUTransferBuffer
    offset*          {.importc: "offset".}:          uint32

  SDL_GPUBufferBinding* {.importc: "SDL_GPUBufferBinding", header: SDL_GPUHeader, bycopy.} = object
    buffer* {.importc: "buffer".}: ptr SDL_GPUBuffer
    offset* {.importc: "offset".}: uint32

  SDL_GPUVertexBufferDescription* {.importc: "SDL_GPUVertexBufferDescription", header: SDL_GPUHeader, bycopy.} = object
    slot*                {.importc: "slot".}:                uint32
    pitch*               {.importc: "pitch".}:               uint32
    input_rate*          {.importc: "input_rate".}:          SDL_GPUVertexInputRate
    instance_step_rate*  {.importc: "instance_step_rate".}:  uint32

  SDL_GPUVertexAttribute* {.importc: "SDL_GPUVertexAttribute", header: SDL_GPUHeader, bycopy.} = object
    location*    {.importc: "location".}:    uint32
    buffer_slot* {.importc: "buffer_slot".}: uint32
    format*      {.importc: "format".}:      SDL_GPUVertexElementFormat
    offset*      {.importc: "offset".}:      uint32

  SDL_GPUDepthStencilTargetInfo* {.importc: "SDL_GPUDepthStencilTargetInfo", header: SDL_GPUHeader, bycopy.} = object
    texture*          {.importc: "texture".}:          ptr SDL_GPUTexture
    clear_depth*      {.importc: "clear_depth".}:      cfloat
    load_op*          {.importc: "load_op".}:          SDL_GPULoadOp
    store_op*         {.importc: "store_op".}:         SDL_GPUStoreOp
    stencil_load_op*  {.importc: "stencil_load_op".}:  SDL_GPULoadOp
    stencil_store_op* {.importc: "stencil_store_op".}: SDL_GPUStoreOp
    cycle*            {.importc: "cycle".}:            bool
    clear_stencil*    {.importc: "clear_stencil".}:    uint8
    mip_level*        {.importc: "mip_level".}:        uint8
    layer*            {.importc: "layer".}:            uint8

const
  SDL_GPU_SHADERFORMAT_SPIRV*             : SDL_GPUShaderFormat = 0x2
  SDL_GPU_SHADERSTAGE_VERTEX*             : SDL_GPUShaderStage  = 0
  SDL_GPU_SHADERSTAGE_FRAGMENT*           : SDL_GPUShaderStage  = 1
  SDL_GPU_PRIMITIVETYPE_TRIANGLELIST*     : SDL_GPUPrimitiveType = 0
  SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP*    : SDL_GPUPrimitiveType = 1
  SDL_GPU_PRIMITIVETYPE_LINELIST*         : SDL_GPUPrimitiveType = 2
  SDL_GPU_PRIMITIVETYPE_LINESTRIP*        : SDL_GPUPrimitiveType = 3
  SDL_GPU_PRIMITIVETYPE_POINTLIST*        : SDL_GPUPrimitiveType = 4
  SDL_GPU_FILTER_NEAREST*                 : SDL_GPUFilter = 0
  SDL_GPU_FILTER_LINEAR*                  : SDL_GPUFilter = 1
  SDL_GPU_SAMPLERMIPMAPMODE_NEAREST*      : SDL_GPUSamplerMipmapMode = 0
  SDL_GPU_SAMPLERMIPMAPMODE_LINEAR*       : SDL_GPUSamplerMipmapMode = 1
  SDL_GPU_SAMPLERADDRESSMODE_REPEAT*       : SDL_GPUSamplerAddressMode = 0
  SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE*: SDL_GPUSamplerAddressMode = 2
  SDL_GPU_FILLMODE_FILL*                  : SDL_GPUFillMode = 0
  SDL_GPU_CULLMODE_NONE*                  : SDL_GPUCullMode = 0
  SDL_GPU_CULLMODE_BACK*                  : SDL_GPUCullMode = 2
  SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE*    : SDL_GPUFrontFace = 0
  SDL_GPU_LOADOP_CLEAR*                   : SDL_GPULoadOp  = 1
  SDL_GPU_STOREOP_STORE*                  : SDL_GPUStoreOp = 0
  SDL_GPU_STOREOP_DONT_CARE*              : SDL_GPUStoreOp = 1
  SDL_GPU_TEXTURETYPE_2D*                 : SDL_GPUTextureType = 0
  SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM*   : SDL_GPUTextureFormat = 4
  SDL_GPU_TEXTUREFORMAT_D32_FLOAT*        : SDL_GPUTextureFormat = 60
  SDL_GPU_SAMPLECOUNT_1*                  : SDL_GPUSampleCount = 0
  SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD*     : SDL_GPUTransferBufferUsage = 0
  SDL_GPU_TEXTUREUSAGE_SAMPLER*           : SDL_GPUTextureUsageFlags = 1'u32 shl 0
  SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET*: SDL_GPUTextureUsageFlags = 1'u32 shl 2

  SDL_GPU_BUFFERUSAGE_VERTEX*             : SDL_GPUBufferUsageFlags = 1'u32 shl 0
  SDL_GPU_BUFFERUSAGE_INDEX*              : SDL_GPUBufferUsageFlags = 1'u32 shl 1

  SDL_GPU_VERTEXINPUTRATE_VERTEX*         : SDL_GPUVertexInputRate = 0
  SDL_GPU_VERTEXELEMENTFORMAT_FLOAT*      : SDL_GPUVertexElementFormat = 9
  SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2*     : SDL_GPUVertexElementFormat = 10
  SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3*     : SDL_GPUVertexElementFormat = 11
  SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4*     : SDL_GPUVertexElementFormat = 12
  SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM*: SDL_GPUVertexElementFormat = 20

  SDL_GPU_INDEXELEMENTSIZE_16BIT*         : SDL_GPUIndexElementSize = 0
  SDL_GPU_INDEXELEMENTSIZE_32BIT*         : SDL_GPUIndexElementSize = 1

  SDL_GPU_COMPAREOP_LESS*                 : SDL_GPUCompareOp = 2
  SDL_GPU_COMPAREOP_LESS_OR_EQUAL*        : SDL_GPUCompareOp = 4

  SDL_GPU_BLENDOP_ADD*                    : SDL_GPUBlendOp     = 1
  SDL_GPU_BLENDFACTOR_ONE*                : SDL_GPUBlendFactor = 2
  SDL_GPU_BLENDFACTOR_SRC_ALPHA*          : SDL_GPUBlendFactor = 7
  SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA*: SDL_GPUBlendFactor = 8

proc SDL_CreateGPUDevice*(formatFlags: SDL_GPUShaderFormat;
                          debugMode: bool;
                          name: cstring): ptr SDL_GPUDevice
  {.importc, header: SDL_GPUHeader.}
proc SDL_DestroyGPUDevice*(dev: ptr SDL_GPUDevice) {.importc, header: SDL_GPUHeader.}

proc SDL_ClaimWindowForGPUDevice*(dev: ptr SDL_GPUDevice;
                                  win: ptr SDL_Window): bool
  {.importc, header: SDL_GPUHeader.}
proc SDL_ReleaseWindowFromGPUDevice*(dev: ptr SDL_GPUDevice;
                                     win: ptr SDL_Window)
  {.importc, header: SDL_GPUHeader.}
proc SDL_GetGPUSwapchainTextureFormat*(dev: ptr SDL_GPUDevice;
                                       win: ptr SDL_Window): SDL_GPUTextureFormat
  {.importc, header: SDL_GPUHeader.}

proc SDL_CreateGPUShader*(dev: ptr SDL_GPUDevice;
                          createinfo: ptr SDL_GPUShaderCreateInfo): ptr SDL_GPUShader
  {.importc, header: SDL_GPUHeader.}
proc SDL_ReleaseGPUShader*(dev: ptr SDL_GPUDevice; shader: ptr SDL_GPUShader)
  {.importc, header: SDL_GPUHeader.}

proc SDL_CreateGPUGraphicsPipeline*(dev: ptr SDL_GPUDevice;
                                    createinfo: ptr SDL_GPUGraphicsPipelineCreateInfo): ptr SDL_GPUGraphicsPipeline
  {.importc, header: SDL_GPUHeader.}
proc SDL_ReleaseGPUGraphicsPipeline*(dev: ptr SDL_GPUDevice;
                                     pipeline: ptr SDL_GPUGraphicsPipeline)
  {.importc, header: SDL_GPUHeader.}

proc SDL_AcquireGPUCommandBuffer*(dev: ptr SDL_GPUDevice): ptr SDL_GPUCommandBuffer
  {.importc, header: SDL_GPUHeader.}
proc SDL_SubmitGPUCommandBuffer*(cmd: ptr SDL_GPUCommandBuffer): bool
  {.importc, header: SDL_GPUHeader.}

proc SDL_WaitAndAcquireGPUSwapchainTexture*(cmd: ptr SDL_GPUCommandBuffer;
                                            win: ptr SDL_Window;
                                            swapchainTexture: ptr ptr SDL_GPUTexture;
                                            w, h: ptr uint32): bool
  {.importc, header: SDL_GPUHeader.}

proc SDL_BeginGPURenderPass*(cmd: ptr SDL_GPUCommandBuffer;
                             colorTargetInfos: ptr SDL_GPUColorTargetInfo;
                             numColorTargets: uint32;
                             depthStencilTargetInfo: pointer): ptr SDL_GPURenderPass
  {.importc, header: SDL_GPUHeader.}
proc SDL_BindGPUGraphicsPipeline*(rp: ptr SDL_GPURenderPass;
                                  pipeline: ptr SDL_GPUGraphicsPipeline)
  {.importc, header: SDL_GPUHeader.}
proc SDL_DrawGPUPrimitives*(rp: ptr SDL_GPURenderPass;
                            numVertices, numInstances,
                            firstVertex, firstInstance: uint32)
  {.importc, header: SDL_GPUHeader.}
proc SDL_EndGPURenderPass*(rp: ptr SDL_GPURenderPass)
  {.importc, header: SDL_GPUHeader.}

proc SDL_CreateGPUTexture*(dev: ptr SDL_GPUDevice;
                           createinfo: ptr SDL_GPUTextureCreateInfo): ptr SDL_GPUTexture
  {.importc, header: SDL_GPUHeader.}
proc SDL_ReleaseGPUTexture*(dev: ptr SDL_GPUDevice; tex: ptr SDL_GPUTexture)
  {.importc, header: SDL_GPUHeader.}

proc SDL_CreateGPUTransferBuffer*(dev: ptr SDL_GPUDevice;
                                  createinfo: ptr SDL_GPUTransferBufferCreateInfo): ptr SDL_GPUTransferBuffer
  {.importc, header: SDL_GPUHeader.}
proc SDL_MapGPUTransferBuffer*(dev: ptr SDL_GPUDevice;
                               transfer: ptr SDL_GPUTransferBuffer;
                               cycle: bool): pointer
  {.importc, header: SDL_GPUHeader.}
proc SDL_UnmapGPUTransferBuffer*(dev: ptr SDL_GPUDevice;
                                 transfer: ptr SDL_GPUTransferBuffer)
  {.importc, header: SDL_GPUHeader.}
proc SDL_ReleaseGPUTransferBuffer*(dev: ptr SDL_GPUDevice;
                                   transfer: ptr SDL_GPUTransferBuffer)
  {.importc, header: SDL_GPUHeader.}

proc SDL_BeginGPUCopyPass*(cmd: ptr SDL_GPUCommandBuffer): ptr SDL_GPUCopyPass
  {.importc, header: SDL_GPUHeader.}
proc SDL_UploadToGPUTexture*(copyPass: ptr SDL_GPUCopyPass;
                             source: ptr SDL_GPUTextureTransferInfo;
                             destination: ptr SDL_GPUTextureRegion;
                             cycle: bool)
  {.importc, header: SDL_GPUHeader.}
proc SDL_EndGPUCopyPass*(copyPass: ptr SDL_GPUCopyPass)
  {.importc, header: SDL_GPUHeader.}

proc SDL_CreateGPUSampler*(dev: ptr SDL_GPUDevice;
                           createinfo: ptr SDL_GPUSamplerCreateInfo): ptr SDL_GPUSampler
  {.importc, header: SDL_GPUHeader.}
proc SDL_ReleaseGPUSampler*(dev: ptr SDL_GPUDevice; sampler: ptr SDL_GPUSampler)
  {.importc, header: SDL_GPUHeader.}
proc SDL_BindGPUFragmentSamplers*(rp: ptr SDL_GPURenderPass;
                                  firstSlot: uint32;
                                  bindings: ptr SDL_GPUTextureSamplerBinding;
                                  numBindings: uint32)
  {.importc, header: SDL_GPUHeader.}

proc SDL_CreateGPUBuffer*(dev: ptr SDL_GPUDevice;
                          createinfo: ptr SDL_GPUBufferCreateInfo): ptr SDL_GPUBuffer
  {.importc, header: SDL_GPUHeader.}
proc SDL_ReleaseGPUBuffer*(dev: ptr SDL_GPUDevice; buffer: ptr SDL_GPUBuffer)
  {.importc, header: SDL_GPUHeader.}
proc SDL_UploadToGPUBuffer*(copyPass: ptr SDL_GPUCopyPass;
                            source: ptr SDL_GPUTransferBufferLocation;
                            destination: ptr SDL_GPUBufferRegion;
                            cycle: bool)
  {.importc, header: SDL_GPUHeader.}

proc SDL_BindGPUVertexBuffers*(rp: ptr SDL_GPURenderPass;
                               firstSlot: uint32;
                               bindings: ptr SDL_GPUBufferBinding;
                               numBindings: uint32)
  {.importc, header: SDL_GPUHeader.}

proc SDL_BindGPUIndexBuffer*(rp: ptr SDL_GPURenderPass;
                             binding: ptr SDL_GPUBufferBinding;
                             indexElementSize: SDL_GPUIndexElementSize)
  {.importc, header: SDL_GPUHeader.}

proc SDL_DrawGPUIndexedPrimitives*(rp: ptr SDL_GPURenderPass;
                                   numIndices, numInstances,
                                   firstIndex: uint32;
                                   vertexOffset: int32;
                                   firstInstance: uint32)
  {.importc, header: SDL_GPUHeader.}

proc SDL_PushGPUVertexUniformData*(cmd: ptr SDL_GPUCommandBuffer;
                                   slotIndex: uint32;
                                   data: pointer;
                                   length: uint32)
  {.importc, header: SDL_GPUHeader.}

proc SDL_PushGPUFragmentUniformData*(cmd: ptr SDL_GPUCommandBuffer;
                                     slotIndex: uint32;
                                     data: pointer;
                                     length: uint32)
  {.importc, header: SDL_GPUHeader.}

type
  SDL_GPUViewport* {.importc: "SDL_GPUViewport", header: SDL_GPUHeader, bycopy.} = object
    x*, y*, w*, h*: cfloat
    min_depth*, max_depth*: cfloat

proc SDL_SetGPUViewport*(rp: ptr SDL_GPURenderPass; viewport: ptr SDL_GPUViewport)
  {.importc, header: SDL_GPUHeader.}

proc SDL_GetTicks*(): uint64 {.importc, header: SDL_Header.}

# ---------------------------------------------------------------------------
# Input

type
  SDL_Scancode* = cint

const
  SDL_SCANCODE_A*      : SDL_Scancode = 4
  SDL_SCANCODE_D*      : SDL_Scancode = 7
  SDL_SCANCODE_E*      : SDL_Scancode = 8
  SDL_SCANCODE_Q*      : SDL_Scancode = 20
  SDL_SCANCODE_S*      : SDL_Scancode = 22
  SDL_SCANCODE_W*      : SDL_Scancode = 26
  SDL_SCANCODE_RETURN* : SDL_Scancode = 40
  SDL_SCANCODE_ESCAPE* : SDL_Scancode = 41
  SDL_SCANCODE_BACKSPACE*: SDL_Scancode = 42
  SDL_SCANCODE_TAB*    : SDL_Scancode = 43
  SDL_SCANCODE_SPACE*  : SDL_Scancode = 44
  SDL_SCANCODE_GRAVE*  : SDL_Scancode = 53
  SDL_SCANCODE_DELETE* : SDL_Scancode = 76
  SDL_SCANCODE_RIGHT*  : SDL_Scancode = 79
  SDL_SCANCODE_LEFT*   : SDL_Scancode = 80
  SDL_SCANCODE_DOWN*   : SDL_Scancode = 81
  SDL_SCANCODE_UP*     : SDL_Scancode = 82
  SDL_SCANCODE_LCTRL*  : SDL_Scancode = 224
  SDL_SCANCODE_LSHIFT* : SDL_Scancode = 225
  SDL_SCANCODE_LALT*   : SDL_Scancode = 226

const
  SDL_BUTTON_LEFT*   : cint = 1
  SDL_BUTTON_MIDDLE* : cint = 2
  SDL_BUTTON_RIGHT*  : cint = 3
  SDL_BUTTON_LMASK*  : uint32 = 1'u32 shl 0
  SDL_BUTTON_MMASK*  : uint32 = 1'u32 shl 1
  SDL_BUTTON_RMASK*  : uint32 = 1'u32 shl 2

proc SDL_GetKeyboardState*(numkeys: ptr cint): ptr UncheckedArray[bool]
  {.importc, header: SDL_Header.}

proc SDL_SetWindowRelativeMouseMode*(win: ptr SDL_Window; enabled: bool): bool
  {.importc, header: SDL_Header.}

proc SDL_StartTextInput*(win: ptr SDL_Window): bool
  {.importc, header: SDL_Header.}
proc SDL_StopTextInput*(win: ptr SDL_Window): bool
  {.importc, header: SDL_Header.}

proc SDL_GetRelativeMouseState*(x, y: ptr cfloat): uint32
  {.importc, header: SDL_Header.}

proc SDL_GetMouseState*(x, y: ptr cfloat): uint32
  {.importc, header: SDL_Header.}

# ---------------------------------------------------------------------------
# SDL3_image

proc IMG_Load*(file: cstring): ptr SDL_Surface {.importc, header: SDL_ImageHeader.}
proc IMG_Load_IO*(src: ptr SDL_IOStream; closeio: bool): ptr SDL_Surface
  {.importc, header: SDL_ImageHeader.}

# ---------------------------------------------------------------------------
# SDL3_ttf

type
  TTF_Font* {.importc: "TTF_Font", header: SDL_TTFHeader, incompleteStruct.} = object

proc TTF_Init*(): bool {.importc, header: SDL_TTFHeader.}
proc TTF_Quit*() {.importc, header: SDL_TTFHeader.}
proc TTF_OpenFontIO*(src: ptr SDL_IOStream; closeio: bool; ptsize: cfloat): ptr TTF_Font
  {.importc, header: SDL_TTFHeader.}
proc TTF_CloseFont*(font: ptr TTF_Font) {.importc, header: SDL_TTFHeader.}
proc TTF_RenderText_Blended*(font: ptr TTF_Font; text: cstring; length: csize_t;
                             fg: SDL_Color): ptr SDL_Surface
  {.importc, header: SDL_TTFHeader.}

# ---------------------------------------------------------------------------
# SDL3_mixer

type
  MIX_Mixer* {.importc: "MIX_Mixer", header: SDL_MixerHeader, incompleteStruct.} = object
  MIX_Audio* {.importc: "MIX_Audio", header: SDL_MixerHeader, incompleteStruct.} = object
  MIX_Track* {.importc: "MIX_Track", header: SDL_MixerHeader, incompleteStruct.} = object

proc MIX_Init*(): bool {.importc, header: SDL_MixerHeader.}
proc MIX_Quit*() {.importc, header: SDL_MixerHeader.}
proc MIX_CreateMixerDevice*(devid: uint32; spec: pointer): ptr MIX_Mixer
  {.importc, header: SDL_MixerHeader.}
proc MIX_DestroyMixer*(mixer: ptr MIX_Mixer) {.importc, header: SDL_MixerHeader.}
proc MIX_LoadAudio*(mixer: ptr MIX_Mixer; path: cstring; predecode: bool): ptr MIX_Audio
  {.importc, header: SDL_MixerHeader.}
proc MIX_DestroyAudio*(audio: ptr MIX_Audio) {.importc, header: SDL_MixerHeader.}
proc MIX_CreateTrack*(mixer: ptr MIX_Mixer): ptr MIX_Track
  {.importc, header: SDL_MixerHeader.}
proc MIX_DestroyTrack*(track: ptr MIX_Track) {.importc, header: SDL_MixerHeader.}
proc MIX_SetTrackAudio*(track: ptr MIX_Track; audio: ptr MIX_Audio): bool
  {.importc, header: SDL_MixerHeader.}
proc MIX_PlayTrack*(track: ptr MIX_Track; options: uint32): bool
  {.importc, header: SDL_MixerHeader.}
