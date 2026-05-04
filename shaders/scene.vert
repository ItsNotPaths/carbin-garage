#version 450

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNormal;
layout(location = 2) in vec2 aUV;
layout(location = 3) in vec4 aBakedAo;  // UBYTE4_NORM; .r = baked AO

layout(set = 1, binding = 0) uniform Globals {
    mat4 uMVP;
};

layout(location = 0) out vec3  vWorldPos;
layout(location = 1) out vec3  vNormal;
layout(location = 2) out vec2  vUV;
layout(location = 3) out float vBakedAo;

void main() {
    gl_Position = uMVP * vec4(aPos, 1.0);
    vWorldPos = aPos;
    vNormal   = aNormal;
    vUV       = aUV;
    vBakedAo  = aBakedAo.r;
}
