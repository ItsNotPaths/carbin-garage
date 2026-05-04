#version 450

// Circle-masked 2D quad pipeline for HUD icon buttons. Shares the uRect
// convention with ui_solid.vert / ui_text.vert: (x, y, w, h) in SDL3 GPU NDC
// with (x, y) as the visual top-left anchor, quad growing downward. The
// per-corner local coordinate in [0, 1] is forwarded so the paired fragment
// shader can discard pixels outside the inscribed circle.

layout(set = 1, binding = 0) uniform UI {
    vec4 uRect;
};

const vec2 kCorners[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

layout(location = 0) out vec2 vLocal;

void main() {
    vec2 p = kCorners[gl_VertexIndex];
    vLocal = p;
    gl_Position = vec4(uRect.x + p.x * uRect.z,
                       uRect.y - p.y * uRect.w,
                       0.0, 1.0);
}
