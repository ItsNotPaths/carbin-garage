/* stb_image single-header implementation. Used to read user-edited
   PNGs back into RGBA8 for the .xds re-encode pipeline (Phase 2c.3).

   stbi_failure_reason() returns a const char*; we expose load + free
   only — the rest of stb_image's API isn't needed for our use case. */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_NO_GIF
#define STBI_NO_PIC
#define STBI_NO_PNM
#include "stb_image.h"
