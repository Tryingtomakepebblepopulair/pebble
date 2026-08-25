#version 450
// item billboards — mirrors Shaders.swift sprite_fs.

layout(push_constant) uniform PC {
    mat4 viewProj;
    vec4 right;
    vec4 fog;        // start, end
    vec4 fogColor;
} pc;

layout(set = 0, binding = 0) uniform sampler2D uSprites;

layout(location = 0) in vec2 vUV;
layout(location = 1) in float vDist;
layout(location = 2) in float vLight;
layout(location = 0) out vec4 outColor;

void main() {
    vec4 c = texture(uSprites, vUV);
    if (c.a < 0.1) discard;
    float fog = clamp((vDist - pc.fog.x) / max(pc.fog.y - pc.fog.x, 0.001), 0.0, 1.0);
    outColor = vec4(mix(c.rgb * vLight, pc.fogColor.rgb, fog), c.a);
}
