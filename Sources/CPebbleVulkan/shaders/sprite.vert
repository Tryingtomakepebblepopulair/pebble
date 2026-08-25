#version 450
// item / projectile billboards — mirrors Shaders.swift sprite_vs. The Mac
// loops one draw per sprite with the whole SpriteU in push constants; that
// block is 144 bytes and Vulkan only guarantees 128, so the per-sprite half
// moves into a 32-byte instance stream instead. Same corners, same maths.

layout(location = 0) in vec3 inCenter;    // 0  camera-relative
layout(location = 1) in float inSize;     // 12
layout(location = 2) in vec4 inUVRect;    // 16 u0 v0 u1 v1
layout(location = 3) in float inLight;    // 32

layout(push_constant) uniform PC {
    mat4 viewProj;   // 0
    vec4 right;      // 64: xyz camera right
    vec4 fog;        // 80: start, end
    vec4 fogColor;   // 96
} pc;

layout(location = 0) out vec2 vUV;
layout(location = 1) out float vDist;
layout(location = 2) out float vLight;

const vec2 CORNERS[6] = vec2[](vec2(-0.5, 0), vec2(0.5, 0), vec2(0.5, 1),
                               vec2(-0.5, 0), vec2(0.5, 1), vec2(-0.5, 1));

void main() {
    vec2 a = CORNERS[gl_VertexIndex];
    vec3 pos = inCenter + pc.right.xyz * a.x * inSize + vec3(0.0, 1.0, 0.0) * a.y * inSize;
    vUV = vec2(mix(inUVRect.x, inUVRect.z, a.x + 0.5), mix(inUVRect.w, inUVRect.y, a.y));
    vDist = length(pos);
    vLight = inLight;
    gl_Position = pc.viewProj * vec4(pos, 1.0);
    gl_Position.y = -gl_Position.y;   // Vulkan clip Y points down
}
