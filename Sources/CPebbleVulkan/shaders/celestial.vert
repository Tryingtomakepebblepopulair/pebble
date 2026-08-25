#version 450
// sun/moon billboard — mirrors Shaders.swift celestial_vs. Six generated
// corners, depth forced to the far plane (z = w).

layout(push_constant) uniform PC {
    mat4 viewProj;   // 0
    vec4 center;     // 64: xyz + size
    vec4 right;      // 80: xyz + texMode (0 = procedural, >=1 = pack art)
    vec4 up;         // 96: xyz + moonPhase (<0 = sun)
} pc;

layout(location = 0) out vec2 vUV;

const vec2 CORNERS[6] = vec2[](vec2(-1, -1), vec2(1, -1), vec2(1, 1),
                               vec2(-1, -1), vec2(1, 1), vec2(-1, 1));

void main() {
    vec2 a = CORNERS[gl_VertexIndex];
    vec3 p = pc.center.xyz + (a.x * pc.right.xyz + a.y * pc.up.xyz) * pc.center.w;
    vec4 cp = pc.viewProj * vec4(p, 1.0);
    gl_Position = vec4(cp.x, -cp.y, cp.w, cp.w);   // Vulkan clip Y points down
    vUV = a * 0.5 + 0.5;
}
