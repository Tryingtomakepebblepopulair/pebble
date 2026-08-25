#version 450
// particles — mirrors Shaders.swift particle_vs. The Mac feeds the six quad
// corners from a vertex buffer; here they come from gl_VertexIndex (same
// values). The 48-byte per-instance stream is byte-identical to the Mac's.

layout(location = 0) in vec3 inPos;          // 0  camera-relative
layout(location = 1) in vec4 inUVRect;       // 12 u0 v0 u1 v1 within the tile
layout(location = 2) in float inLayerSize;   // 28 tile*256 + size*100
layout(location = 3) in vec4 inColorLight;   // 32 rgb + light

layout(push_constant) uniform PC {
    mat4 viewProj;   // 0
    vec4 right;      // 64: xyz camera right
    vec4 up;         // 80: xyz camera up, w dayLight
    vec4 misc;       // 96: x = atlas columns
} pc;

layout(location = 0) out vec2 vUV;
layout(location = 1) out vec3 vColor;
layout(location = 2) flat out uint vLayer;

const vec2 CORNERS[6] = vec2[](vec2(-1, -1), vec2(1, -1), vec2(1, 1),
                               vec2(-1, -1), vec2(1, 1), vec2(-1, 1));

void main() {
    vec2 corner = CORNERS[gl_VertexIndex];
    float layer = floor(inLayerSize / 256.0);
    // layerSize is never negative, so GLSL's floored mod matches MSL's fmod
    float size = mod(inLayerSize, 256.0) / 100.0;
    vec3 p = inPos + (corner.x * pc.right.xyz + corner.y * pc.up.xyz) * size;
    gl_Position = pc.viewProj * vec4(p, 1.0);
    gl_Position.y = -gl_Position.y;   // Vulkan clip Y points down

    vUV = mix(inUVRect.xy, inUVRect.zw, corner * 0.5 + 0.5);
    float light = inColorLight.a;
    float dayLight = pc.up.w;
    float l = max(light * dayLight, 0.06);
    l = l / (4.0 - 3.0 * l);
    vColor = inColorLight.rgb * max(l, 0.25);
    vLayer = uint(layer);
}
