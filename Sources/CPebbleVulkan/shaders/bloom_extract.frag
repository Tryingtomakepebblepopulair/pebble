#version 450
// bloom source — mirrors Shaders.swift bloom_extract_fs.

layout(set = 0, binding = 0) uniform sampler2D uScene;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

void main() {
    vec3 c = texture(uScene, vUV).rgb;
    float lum = dot(c, vec3(0.299, 0.587, 0.114));
    float k = smoothstep(0.62, 0.95, lum);
    outColor = vec4(c * k, 1.0);
}
