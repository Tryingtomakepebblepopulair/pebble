#version 450
// stars — mirrors Shaders.swift stars_fs, with the quad's own coordinate
// standing in for [[point_coord]] (both run 0..1 across the sprite, and the
// falloff is radial so the orientation does not matter).

layout(push_constant) uniform PC {
    mat4 viewProj;
    vec4 params;     // time, alpha, screenW, screenH
} pc;

layout(location = 0) in vec2 vPointCoord;
layout(location = 1) in float vBright;
layout(location = 0) out vec4 outColor;

void main() {
    vec2 d = vPointCoord - 0.5;
    float a = (1.0 - smoothstep(0.1, 0.5, length(d))) * vBright * pc.params.y;
    outColor = vec4(vec3(0.95, 0.96, 1.0), a);
}
