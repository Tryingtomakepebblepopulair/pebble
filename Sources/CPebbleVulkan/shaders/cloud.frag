#version 450
// cloud shading — mirrors Shaders.swift cloud_fs.

layout(push_constant) uniform PC {
    mat4 viewProj;
    vec4 offset;
    vec4 scroll;     // sx, sy, brightness, fogEnd
} pc;

layout(set = 0, binding = 0) uniform sampler2D cloudTex;

layout(location = 0) in vec2 vUV;
layout(location = 1) in float vDist;
layout(location = 0) out vec4 outColor;

void main() {
    float c = texture(cloudTex, vUV * 12.0 + pc.scroll.xy).r;
    if (c < 0.5) discard;
    float fogEnd = pc.scroll.w;
    float fade = 1.0 - clamp((vDist - fogEnd * 0.7) / (fogEnd * 0.6), 0.0, 1.0);
    outColor = vec4(vec3(pc.scroll.z), 0.72 * fade);
}
