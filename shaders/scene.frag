#version 450

layout(location = 0) in vec3  vWorldPos;
layout(location = 1) in vec3  vNormal;
layout(location = 2) in vec2  vUV;
layout(location = 3) in float vBakedAo;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D uTex;

layout(set = 3, binding = 0) uniform Material {
    vec4 baseColor;
    vec4 boxParams;
    vec4 boxCenter;
    vec4 contactDisc;
    vec4 contactExtra;
    vec4 specParams;       // x = shininess, y = strength, zw = unused
};

layout(set = 3, binding = 1) uniform Lighting {
    vec4 uEyeWorld;        // xyz
    vec4 uKeyDir;          // xyz to key light, w unused
    vec4 uKeyColor;        // rgb
    vec4 uFillDir;         // xyz to fill light, w unused
    vec4 uFillColor;       // rgb
};

float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0);
    return mix(a, b, h) - k * h * (1.0 - h);
}

float blinnPhong(vec3 N, vec3 V, vec3 L, float shininess) {
    vec3  H     = normalize(L + V);
    float ndotl = max(dot(N, L), 0.0);
    float ndoth = max(dot(N, H), 0.0);
    float spec  = pow(ndoth, max(shininess, 1.0));
    // Soft-step on N·L so back-faces don't catch a highlight at the terminator.
    return spec * smoothstep(0.0, 0.2, ndotl);
}

void main() {
    float ao = vBakedAo;

    if (boxCenter.w > 0.0) {
        vec3  d  = boxParams.xyz - abs(vWorldPos - boxCenter.xyz);
        vec3  na = abs(vNormal);
        float d1, d2;
        if (na.x > 0.5)      { d1 = d.y; d2 = d.z; }
        else if (na.y > 0.5) { d1 = d.x; d2 = d.z; }
        else                 { d1 = d.x; d2 = d.y; }
        float falloff = max(boxParams.w, 1e-6);
        float k       = falloff * 0.6;
        float r       = max(smin(d1, d2, k), 0.0);
        float t       = clamp(r / falloff, 0.0, 1.0);
        float curve   = smoothstep(0.0, 1.0, t);
        ao *= mix(1.0 - boxCenter.w, 1.0, curve);
    }

    if (contactExtra.y > 0.0 && vNormal.z >= contactExtra.z) {
        vec2  d2     = vWorldPos.xy - contactDisc.xy;
        float r      = length(d2);
        float inner  = contactDisc.z;
        float outer  = contactDisc.w;
        float t      = clamp((r - inner) / max(outer - inner, 1e-6), 0.0, 1.0);
        float curve  = smoothstep(0.0, 1.0, t);
        ao *= mix(1.0 - contactExtra.y, 1.0, curve);
    }

    vec4 tex = texture(uTex, vUV);
    vec3 lit = baseColor.rgb * tex.rgb * ao;

    if (specParams.y > 0.0) {
        vec3 N = normalize(vNormal);
        vec3 V = normalize(uEyeWorld.xyz - vWorldPos);
        // Two-sided lighting: many car body panels have normals pointing the
        // wrong way (writer-side artefact). Cull mode is NONE so both faces
        // render; flip the normal toward the viewer so spec doesn't disappear
        // on whichever side has the inverted normal.
        if (dot(N, V) < 0.0) N = -N;
        float strength = specParams.y;
        float shin     = specParams.x;
        lit += strength * (
              blinnPhong(N, V, normalize(uKeyDir.xyz),  shin) * uKeyColor.rgb
            + blinnPhong(N, V, normalize(uFillDir.xyz), shin) * uFillColor.rgb);
    }

    outColor = vec4(lit, baseColor.a * tex.a);
}
