#version 450

layout(set = 1, binding = 0) uniform UI {
    vec4 uRect;  // (x, y, w, h) in Vulkan NDC (y-down)
};

layout(location = 0) out vec2 vUV;

const vec2 kCorners[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

void main() {
    vec2 p = kCorners[gl_VertexIndex];
    vUV = p;
    // uRect = (left, top, w, h); SDL3 GPU NDC is +Y up, so grow downward
    // from the top by subtracting p.y * h.
    gl_Position = vec4(uRect.x + p.x * uRect.z,
                       uRect.y - p.y * uRect.w,
                       0.0, 1.0);
}
