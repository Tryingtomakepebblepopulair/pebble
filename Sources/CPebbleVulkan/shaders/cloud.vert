#version 450
// cloud plane — mirrors Shaders.swift cloud_vs. One big quad at cloud
// height, scrolling through a wrapping noise texture.

layout(push_constant) uniform PC {
    mat4 viewProj;   // 0
    vec4 offset;     // 64: xyz plane origin (camera-relative), w half-size
    vec4 scroll;     // 80: sx, sy, brightness, fogEnd
} pc;

layout(location = 0) out vec2 vUV;
layout(location = 1) out float vDist;

const vec2 CORNERS[6] = vec2[](vec2(-1, -1), vec2(1, -1), vec2(1, 1),
                               vec2(-1, -1), vec2(1, 1), vec2(-1, 1));

void main() {
    vec2 a = CORNERS[gl_VertexIndex];
    vec3 p = vec3(a.x * pc.offset.w, 0.0, a.y * pc.offset.w) + pc.offset.xyz;
    vec4 cp = pc.viewProj * vec4(p, 1.0);
    gl_Position = vec4(cp.x, -cp.y, cp.z, cp.w);   // Vulkan clip Y points down
    vUV = a * 0.5 + 0.5;
    vDist = length(p.xz);
}
