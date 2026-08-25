#version 450
// entities/mobs/players — the frozen 36-byte stream (pos3f normal3f uv2f
// part1f), posed by the shared animator. The 24 part matrices are 1536
// bytes, far past the 128 Vulkan guarantees for push constants, so they
// arrive in a dynamically offset uniform buffer: one slot per draw.

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inUV;
layout(location = 3) in float inPart;

layout(push_constant) uniform PC {
    mat4 mvp;        // viewProj * model, premultiplied on the CPU side
    vec4 light;      // brightness, unused, unused, alpha
} pc;

layout(set = 0, binding = 1) uniform Parts {
    mat4 m[24];
} parts;

layout(location = 0) out vec2 vUV;
layout(location = 1) out float vShade;

void main() {
    int part = clamp(int(inPart + 0.5), 0, 23);
    mat4 pm = parts.m[part];
    vec4 posed = pm * vec4(inPos, 1.0);
    gl_Position = pc.mvp * posed;
    gl_Position.y = -gl_Position.y;
    // rotate the normal by the part too, so a swinging arm shades correctly
    vec3 n = normalize(mat3(pm) * inNormal);
    float nY = clamp(n.y * 0.6 + 0.6, 0.0, 1.0);
    vShade = pc.light.x * (0.62 + 0.38 * nY);
    vUV = inUV;
}
