#version 450

layout(location = 0) in vec2 vUV;
layout(location = 1) in float vShade;

layout(push_constant) uniform PC {
    mat4 mvp;
    vec4 light;
} pc;

layout(set = 0, binding = 0) uniform sampler2D uSkin;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 tex = texture(uSkin, vUV);
    if (tex.a < 0.1) discard;
    outColor = vec4(tex.rgb * vShade, tex.a * pc.light.w);
}
