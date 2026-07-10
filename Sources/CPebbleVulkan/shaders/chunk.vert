#version 450
// chunk vertex — mirrors Shaders.swift chunk_vs (PORTING 06 ABI: 28B stream)
// minus shadows/ultra (later slices). Push constants only: 128 bytes exactly.

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in uint inA;
layout(location = 3) in uint inB;

layout(push_constant) uniform PC {
    mat4 viewProj;   // 0
    vec4 origin;     // 64: xyz section origin (camera-relative), w time
    vec4 light;      // 80: dayLight, gamma, ambient, procAnim(1=procedural)
    vec4 fog;        // 96: start, end, alphaTest, globalAlpha
    vec4 fogColor;   // 112
} pc;

layout(location = 0) out vec2 vUV;
layout(location = 1) out vec3 vColor;
layout(location = 2) out float vFogDist;
layout(location = 3) out vec3 vWorldPos;
layout(location = 4) flat out uint vLayer;
layout(location = 5) flat out uint vAnim;

const float FACE_SHADE[6] = float[](0.55, 1.0, 0.8, 0.8, 0.62, 0.62);

void main() {
    uint layer = inA & 4095u;
    uint normalI = (inA >> 12) & 7u;
    float ao = float((inA >> 15) & 3u) / 3.0;
    float sky = float((inA >> 17) & 15u) / 15.0;
    float blk = float((inA >> 21) & 15u) / 15.0;
    float emissive = float((inA >> 25) & 1u);
    vec3 tint = vec3(float((inB >> 16) & 255u), float((inB >> 8) & 255u), float(inB & 255u)) / 255.0;
    uint anim = (inB >> 24) & 7u;
    float time = pc.origin.w;

    vec3 pos = inPos;
    vec3 wpos = pos + pc.origin.xyz;
    if (anim == 5u || anim == 6u) {
        float amp = anim == 6u ? 0.06 : 0.025;
        float topFactor = anim == 6u ? clamp(1.0 - inUV.y, 0.0, 1.0) : 1.0;
        float ph = dot(floor(wpos.xz + 0.5), vec2(0.7, 1.3));
        pos.x += sin(time * 1.1 + ph) * amp * topFactor;
        pos.z += cos(time * 0.9 + ph * 1.7) * amp * topFactor;
    }
    if (anim == 1u) {
        pos.y += sin(time * 1.6 + (wpos.x + wpos.z) * 0.7) * 0.025 - 0.02;
    }

    vec3 rel = pos + pc.origin.xyz;
    gl_Position = pc.viewProj * vec4(rel, 1.0);
    gl_Position.y = -gl_Position.y;   // Vulkan clip-space Y points down

    float dayLight = pc.light.x;
    float gammaB = pc.light.y;
    float ambient0 = pc.light.z;
    float skyBright = sky * dayLight;
    float ambient = max(ambient0, 0.03);
    float lightLevel = max(max(skyBright, blk), ambient);
    float l = lightLevel / (4.0 - 3.0 * lightLevel);
    l = mix(l, 1.0, gammaB * 0.35);
    vec3 skyCol = mix(vec3(0.45, 0.55, 0.9), vec3(1.0), clamp(dayLight, 0.0, 1.0));
    vec3 blockCol = vec3(1.0, 0.85, 0.62);
    float sb = skyBright, bb = blk;
    vec3 lightColor = (sb + bb < 0.001) ? vec3(1.0) : (skyCol * sb + blockCol * bb) / (sb + bb);
    float aoF = mix(0.42, 1.0, ao);
    vColor = tint * FACE_SHADE[normalI] * aoF * max(l, emissive) * mix(lightColor, vec3(1.0), emissive);
    vFogDist = length(rel.xz);
    vUV = inUV;
    vLayer = layer;
    vAnim = anim;
    vWorldPos = wpos;
}
