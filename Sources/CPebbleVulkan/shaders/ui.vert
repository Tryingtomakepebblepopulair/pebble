#version 450
// UI overlay — the frozen 32-byte stream (pos2f uv2f color4f), GUI units
// mapped exactly like the Metal ui_vs (top-left origin, no Y flip needed:
// the mapping itself already flips)

layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec4 inColor;

layout(push_constant) uniform PC {
    vec4 screen;   // width, height (GUI units)
} pc;

layout(location = 0) out vec2 vUV;
layout(location = 1) out vec4 vColor;

void main() {
    gl_Position = vec4(inPos.x / pc.screen.x * 2.0 - 1.0,
                       inPos.y / pc.screen.y * 2.0 - 1.0,   // Vulkan Y-down = Metal's 1-y flipped
                       0.0, 1.0);
    vUV = inUV;
    vColor = inColor;
}
