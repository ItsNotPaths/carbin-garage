/* cgltf_write single-header implementation. Separate TU from cgltf_impl.c
 * so the jsmn enum block in cgltf.h is only defined once. */
#define CGLTF_WRITE_IMPLEMENTATION
#include "cgltf_write.h"
