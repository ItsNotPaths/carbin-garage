/* cgltf core single-header implementation. See vendor/cgltf/cgltf.h.
 * Kept in its own TU so its internal jsmn enums aren't redefined when
 * cgltf_write.h re-includes cgltf.h in cgltf_write_impl.c. */
#define CGLTF_IMPLEMENTATION
#include "cgltf.h"
