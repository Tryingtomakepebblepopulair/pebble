#version 450
// sky dome — mirrors Shaders.swift sky_vs. A fullscreen triangle; the view
// ray comes from the inverse view-projection. The matrix is the Metal-side
// viewProj (clip Y up), so the clip position feeding the inverse is flipped
// back before the unprojection — the same Y-flip contract as chunk.vert.

layout(push_constant) uniform PC {
    mat4 invViewProj;   // 0
    vec4 zenith;        // 64
    vec4 horizon;       // 80
    vec4 horizonSun;    // 96: rgb + sunGlow
    vec4 sunDir;        // 112: xyz + void (1 = the End's flat sky)
} pc;

layout(location = 0) out vec3 vDir;

void main() {
    vec2 p = vec2(gl_VertexIndex == 1 ? 3.0 : -1.0,
                  gl_VertexIndex == 2 ? 3.0 : -1.0);
    gl_Position = vec4(p, 0.99999, 1.0);
    vec2 m = vec2(p.x, -p.y);   // back to Metal clip space for the inverse
    vec4 p0 = pc.invViewProj * vec4(m, 0.0, 1.0);
    vec4 p1 = pc.invViewProj * vec4(m, 1.0, 1.0);
    vDir = p1.xyz / p1.w - p0.xyz / p0.w;
}
