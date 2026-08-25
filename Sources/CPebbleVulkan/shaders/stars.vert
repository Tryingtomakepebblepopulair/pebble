#version 450
// stars — mirrors Shaders.swift stars_vs. The Mac draws point primitives
// with [[point_size]]; Vulkan only guarantees gl_PointSize == 1 unless the
// largePoints feature is enabled, so each star is an instanced quad
// expanded by the same pixel size instead. Same positions, same twinkle.
//
// per-instance stream: the Mac's 16-byte star buffer (vec3 dir + float mag)

layout(location = 0) in vec3 inPos;
layout(location = 1) in float inMag;

layout(push_constant) uniform PC {
    mat4 viewProj;   // 0
    vec4 params;     // 64: time, alpha, screenW, screenH
} pc;

layout(location = 0) out vec2 vPointCoord;
layout(location = 1) out float vBright;

const vec2 CORNERS[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1),
                               vec2(0, 0), vec2(1, 1), vec2(0, 1));

void main() {
    vec4 cp = pc.viewProj * vec4(inPos * 900.0, 1.0);
    float size = 1.0 + inMag * 1.6;
    vec2 c = CORNERS[gl_VertexIndex];
    // NDC offset for `size` pixels is 2*size/screen; times w to get clip space
    vec2 off = (c - 0.5) * size * 2.0 / vec2(pc.params.z, pc.params.w) * cp.w;
    gl_Position = vec4(cp.x + off.x, -cp.y + off.y, cp.w, cp.w);
    vPointCoord = c;
    vBright = 0.55 + 0.45 * sin(pc.params.x * (1.0 + inMag * 2.0) + inPos.x * 50.0);
}
