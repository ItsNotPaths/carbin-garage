#version 450

// Pairs with ui_circle.vert. Discards pixels outside the inscribed circle of
// the quad, otherwise fills with a flat color supplied via fragment uniform
// set 3, binding 0.

layout(location = 0) in vec2 vLocal;

layout(set = 3, binding = 0) uniform FragUBO {
    vec4 uColor;
};

layout(location = 0) out vec4 outColor;

void main() {
    vec2 c = vLocal - vec2(0.5);
    if (dot(c, c) > 0.25) discard;
    outColor = uColor;
}
