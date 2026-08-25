#version 450
// particles — mirrors Shaders.swift particle_fs. The Mac samples a
// texture2d_array; this backend packs the terrain atlas as a 2D tile grid
// (see chunk.frag), so the layer becomes a cell offset.

layout(push_constant) uniform PC {
    mat4 viewProj;
    vec4 right;
    vec4 up;
    vec4 misc;       // x = atlas columns
} pc;

layout(set = 0, binding = 0) uniform sampler2D uAtlas;

layout(location = 0) in vec2 vUV;
layout(location = 1) in vec3 vColor;
layout(location = 2) flat in uint vLayer;
layout(location = 0) out vec4 outColor;

void main() {
    float cols = pc.misc.x;
    vec2 cell = vec2(mod(float(vLayer), cols), floor(float(vLayer) / cols));
    vec4 tex = texture(uAtlas, (cell + clamp(vUV, 0.0, 1.0)) / cols);
    if (tex.a < 0.3) discard;
    outColor = vec4(tex.rgb * vColor, tex.a);
}
