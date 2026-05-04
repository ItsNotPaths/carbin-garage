#version 450

// Solid-color fragment shader for the leveledit highlight pass. Pairs with
// level.vert (which emits unused vUV / vLight) and fills the triangle with a
// flat color supplied via fragment uniform set 3, binding 0.

layout(location = 0) in vec2 vUV;
layout(location = 1) in vec3 vLight;

layout(set = 3, binding = 0) uniform FragUBO {
    vec4 uColor;
};

layout(location = 0) out vec4 outColor;

void main() {
    outColor = uColor;
}
