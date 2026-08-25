#version 450
// the shadow pass — mirrors Shaders.swift shadow_vs. Position only: the
// chunk stream transformed by the sun's view-projection, straight into a
// depth-only target. No fragment shader and no colour attachment.

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in uint inA;
layout(location = 3) in uint inB;

layout(push_constant) uniform PC {
    mat4 shadowMat;
    vec4 origin;     // xyz = section origin, camera-relative
} pc;

void main() {
    gl_Position = pc.shadowMat * vec4(inPos + pc.origin.xyz, 1.0);
    gl_Position.y = -gl_Position.y;   // Vulkan clip Y points down
}
