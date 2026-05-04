#version 450

// Solid-color 2D quad pipeline for HUD panels and buttons.
// Matches ui_text.vert's uRect convention: (x, y, w, h) in SDL3 GPU NDC, with
// (x, y) as the visual top-left anchor and the quad growing downward.

layout(set = 1, binding = 0) uniform UI {
    vec4 uRect;
};

const vec2 kCorners[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

void main() {
    vec2 p = kCorners[gl_VertexIndex];
    gl_Position = vec4(uRect.x + p.x * uRect.z,
                       uRect.y - p.y * uRect.w,
                       0.0, 1.0);
}
