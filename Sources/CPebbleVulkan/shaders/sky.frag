#version 450
// sky gradient — mirrors Shaders.swift sky_fs exactly.

layout(push_constant) uniform PC {
    mat4 invViewProj;
    vec4 zenith;
    vec4 horizon;
    vec4 horizonSun;
    vec4 sunDir;
} pc;

layout(location = 0) in vec3 vDir;
layout(location = 0) out vec4 outColor;

void main() {
    vec3 d = normalize(vDir);
    float h = clamp(d.y, -1.0, 1.0);
    float t = pow(clamp(1.0 - h, 0.0, 1.0), 1.6);
    vec3 col = mix(pc.zenith.rgb, pc.horizon.rgb, t * step(0.0, h) + step(h, 0.0));
    if (h < 0.0) col = mix(pc.horizon.rgb, pc.zenith.rgb * 0.35, clamp(-h * 2.2, 0.0, 1.0));
    vec2 sd = pc.sunDir.xz;
    float lsd = length(sd);
    float sunness = lsd < 1e-5 ? 0.0 : max(0.0, dot(normalize(d.xz), sd / lsd));
    float band = exp(-abs(h) * 5.0);
    col = mix(col, pc.horizonSun.rgb, pc.horizonSun.w * band * pow(sunness * 0.5 + 0.5, 3.0));
    if (pc.sunDir.w > 0.5) {
        col = mix(vec3(0.03, 0.025, 0.05), vec3(0.09, 0.07, 0.12), clamp(h + 0.5, 0.0, 1.0));
    }
    outColor = vec4(col, 1.0);
}
