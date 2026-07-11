#version 450
// chunk fragment — mirrors Shaders.swift chunk_fs minus shadows/ultra

layout(location = 0) in vec2 vUV;
layout(location = 1) in vec3 vColor;
layout(location = 2) in float vFogDist;
layout(location = 3) in vec3 vWorldPos;
layout(location = 4) flat in uint vLayer;
layout(location = 5) flat in uint vAnim;

layout(push_constant) uniform PC {
    mat4 viewProj;
    vec4 origin;     // xyz origin, w time
    vec4 light;      // dayLight, gamma, ambient, procAnim
    vec4 fog;        // start, end, alphaTest, globalAlpha
    vec4 fogColor;
} pc;

layout(set = 0, binding = 0) uniform sampler2DArray uAtlas;

layout(location = 0) out vec4 outColor;

void main() {
    float time = pc.origin.w;
    float procAnim = pc.light.w;
    vec2 uv = vUV;
    if (vAnim == 1u) { uv += vec2(time * 0.02, time * 0.055) * procAnim; }
    else if (vAnim == 2u) {
        uv += vec2(sin(time * 0.22 + vWorldPos.z * 0.5) * 0.3 + time * 0.01, time * 0.018) * procAnim;
    } else if (vAnim == 3u) {
        float a = time * 0.5 + vWorldPos.y * 0.8;
        uv += vec2(sin(a) * 0.25, cos(a * 0.8) * 0.25 + time * 0.05);
    } else if (vAnim == 4u) {
        uv.y = fract(uv.y - time * 1.2 * procAnim);
    }
    vec4 tex = texture(uAtlas, vec3(uv, float(vLayer)));
    float alphaTest = pc.fog.z;
    if (alphaTest > 0.0 && tex.a < alphaTest) discard;

    vec3 col = tex.rgb * vColor;
    float alpha = tex.a * pc.fog.w;
    // water reads too thin without the Metal path's fresnel — thicken it
    if (vAnim == 1u) { alpha = min(1.0, alpha * 1.4); }

    float fogStart = pc.fog.x, fogEnd = pc.fog.y;
    float fog = clamp((vFogDist - fogStart) / (fogEnd - fogStart), 0.0, 1.0);
    fog = fog * fog;
    col = mix(col, pc.fogColor.rgb, fog);
    outColor = vec4(col, alpha);
}
