#version 450
// separable gaussian — mirrors Shaders.swift blur_fs, same five taps and
// the same weights. The direction carries the texel size for one axis.

layout(push_constant) uniform PC {
    vec4 dir;    // xy = texel step for this axis
} pc;

layout(set = 0, binding = 0) uniform sampler2D uTex;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

void main() {
    vec2 dir = pc.dir.xy;
    vec3 c = texture(uTex, vUV).rgb * 0.227;
    c += texture(uTex, vUV + dir * 1.384).rgb * 0.316;
    c += texture(uTex, vUV - dir * 1.384).rgb * 0.316;
    c += texture(uTex, vUV + dir * 3.230).rgb * 0.07;
    c += texture(uTex, vUV - dir * 3.230).rgb * 0.07;
    outColor = vec4(c, 1.0);
}
