#version 450

// PVS box body fragment shader. Samples a tiny CPU-built checker texture
// (2×2 RGBA, two pink shades) with REPEAT wrap so per-face UVs scaled to
// world units tile cleanly across boxes of any size. Alpha is baked into
// the texture, so no fragment uniform is needed.

layout(location = 0) in vec2 vUV;
layout(location = 1) in vec3 vLight;

layout(set = 2, binding = 0) uniform sampler2D uChecker;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(uChecker, vUV);
}
