#version 450
// the ultra buffer's blur — mirrors Shaders.swift ultra_blur_fs. Same taps as
// blur.frag, but all four channels: rgb is the volumetric light and alpha is
// the ambient occlusion, so dropping alpha would throw the SSAO away.

layout(push_constant) uniform PC {
    vec4 dir;    // xy = texel step for this axis
} pc;

layout(set = 0, binding = 0) uniform sampler2D uTex;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

void main() {
    vec2 dir = pc.dir.xy;
    vec4 c = texture(uTex, vUV) * 0.227;
    c += texture(uTex, vUV + dir * 1.384) * 0.316;
    c += texture(uTex, vUV - dir * 1.384) * 0.316;
    c += texture(uTex, vUV + dir * 3.230) * 0.07;
    c += texture(uTex, vUV - dir * 3.230) * 0.07;
    outColor = c;
}
