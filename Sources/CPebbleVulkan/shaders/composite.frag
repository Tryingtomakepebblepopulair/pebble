#version 450
// scene + ultra + bloom + warp + tint + darkness + tonemap — mirrors
// Shaders.swift composite_fs, ultra branch and all.

layout(push_constant) uniform PC {
    vec4 params;   // bloomAmt, warp, time, darkness
    vec4 tint;     // rgb + amount
    vec4 params2;  // ultraOn, aoStrength, volStrength
} pc;

layout(set = 0, binding = 0) uniform sampler2D uScene;
layout(set = 1, binding = 0) uniform sampler2D uBloom;
layout(set = 2, binding = 0) uniform sampler2D uUltra;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

void main() {
    vec2 uv = vUV;
    float warp = pc.params.y, time = pc.params.z;
    if (warp > 0.001) {
        uv += vec2(sin(uv.y * 14.0 + time * 2.2), cos(uv.x * 12.0 + time * 1.8)) * 0.012 * warp;
    }
    vec3 c = texture(uScene, uv).rgb;
    float ultraOn = pc.params2.x;
    if (ultraOn > 0.5) {
        vec4 ul = texture(uUltra, uv);
        c *= mix(1.0, ul.a, pc.params2.y);          // SSAO
        c += ul.rgb * pc.params2.z;                 // volumetric light
    }
    c += texture(uBloom, uv).rgb * pc.params.x;
    c = mix(c, pc.tint.rgb, pc.tint.a);
    float darkness = pc.params.w;
    if (darkness > 0.001) {
        float d = distance(uv, vec2(0.5));
        c *= mix(1.0, clamp(0.25 - d, 0.0, 0.25) * 4.0, darkness);
    }
    if (ultraOn > 0.5) {
        // ACES-ish filmic curve, then a gentle saturation lift
        vec3 x = c * 0.6;
        c = clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
        float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
        c = mix(vec3(lum), c, 1.12);
    } else {
        c = c / (1.0 + c * 0.12);
    }
    outColor = vec4(c, 1.0);
}
