#version 450

layout(set = 2, binding = 0) uniform sampler2D uTex;

layout(location = 0) in vec2 vUV;
layout(location = 1) in vec3 vLight;
layout(location = 0) out vec4 outColor;

void main() {
    vec4 tex = texture(uTex, vUV);
    outColor = vec4(tex.rgb * vLight, tex.a);
}
