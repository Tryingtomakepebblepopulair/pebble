#version 450
// lines and flat fills — mirrors Shaders.swift line_vs. Camera-relative
// positions straight from a per-frame vertex buffer; the Mac feeds the same
// stream through setVertexBytes.

layout(location = 0) in vec3 inPos;

layout(push_constant) uniform PC {
    mat4 viewProj;   // 0
    vec4 color;      // 64
} pc;

void main() {
    gl_Position = pc.viewProj * vec4(inPos, 1.0);
    gl_Position.y = -gl_Position.y;   // Vulkan clip Y points down
}
