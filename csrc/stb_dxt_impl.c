/* stb_dxt single-header implementation. RGBA → BC1/BC3 (and BC5 via
   stb_compress_bc5_block). BC encoders are intrinsically non-deterministic
   across implementations — see feedback_validation_strategy memory:
   roundtrip is SSIM-validated, not byte-equal-vs-original-.xds. */
/* stb_dxt.h uses memcpy without including <string.h>; pull it in here so
   we can keep vendor/stb pristine (per feedback_vendor_pristine memory). */
#include <string.h>

#define STB_DXT_IMPLEMENTATION
#include "stb_dxt.h"
