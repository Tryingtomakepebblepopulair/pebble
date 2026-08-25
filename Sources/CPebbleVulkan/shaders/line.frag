#version 450
// flat colour — mirrors Shaders.swift line_fs.

layout(push_constant) uniform PC {
    mat4 viewProj;
    vec4 color;
} pc;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = pc.color;
}
