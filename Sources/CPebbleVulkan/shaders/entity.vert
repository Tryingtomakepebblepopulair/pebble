#version 450
// entities/mobs/players — the frozen 36-byte stream (pos3f normal3f uv2f
// part1f); v1 draws the bind pose (the shared animator is a later slice)

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inUV;
layout(location = 3) in float inPart;

layout(push_constant) uniform PC {
    mat4 mvp;        // viewProj * model, premultiplied on the CPU side
    vec4 light;      // brightness, unused, unused, alpha
} pc;

layout(location = 0) out vec2 vUV;
layout(location = 1) out float vShade;

void main() {
    gl_Position = pc.mvp * vec4(inPos, 1.0);
    gl_Position.y = -gl_Position.y;
    // top-lit: model yaw spin leaves normal.y intact, good enough unanimated
    float nY = clamp(inNormal.y * 0.6 + 0.6, 0.0, 1.0);
    vShade = pc.light.x * (0.62 + 0.38 * nY);
    vUV = inUV;
}
