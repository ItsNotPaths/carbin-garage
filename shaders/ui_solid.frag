#version 450

// Pairs with ui_solid.vert. Fills the quad with a flat color supplied via
// fragment uniform set 3, binding 0.

layout(set = 3, binding = 0) uniform FragUBO {
    vec4 uColor;
};

layout(location = 0) out vec4 outColor;

void main() {
    outColor = uColor;
}
