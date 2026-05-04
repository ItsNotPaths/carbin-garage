#version 450

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aUV;
layout(location = 2) in vec4 aLight;  // UBYTE4_NORM, .a is pad

layout(set = 1, binding = 0) uniform Globals {
    mat4 uMVP;
};

layout(location = 0) out vec2 vUV;
layout(location = 1) out vec3 vLight;

void main() {
    gl_Position = uMVP * vec4(aPos, 1.0);
    vUV = aUV;
    vLight = aLight.rgb;
}
