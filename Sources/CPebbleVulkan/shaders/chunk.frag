#version 450
// chunk fragment — mirrors Shaders.swift chunk_fs minus shadows/ultra

layout(location = 0) in vec2 vUV;
layout(location = 1) in vec3 vColor;
layout(location = 2) in float vFogDist;
layout(location = 3) in vec3 vWorldPos;
layout(location = 4) flat in uint vLayer;
layout(location = 5) flat in uint vAnim;
layout(location = 6) in vec4 vShadowPos;
layout(location = 7) in float vSkyAmt;

layout(push_constant) uniform PC {
    mat4 viewProj;
    vec4 origin;     // xyz origin, w time
    vec4 light;      // dayLight, gamma, ambient, procAnim
    vec4 fog;        // start, end, alphaTest, globalAlpha
    vec4 fogColor;
} pc;

// tiles packed in a 2D grid (fogColor.w = columns) — texture arrays hit
// per-GPU layer limits on some hardware and silently mis-sampled
layout(set = 0, binding = 0) uniform sampler2D uAtlas;
// depth-compare sampler: one fetch returns the PCF result, like MSL's
// sample_compare
layout(set = 0, binding = 1) uniform sampler2DShadow uShadow;
layout(set = 0, binding = 2) uniform Shadow {
    mat4 mat;
    vec4 params;    // x = shadows on, y = texel size, z = ultra on
} shadow;

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
    float cols = pc.fogColor.w;
    vec2 cell = vec2(mod(float(vLayer), cols), floor(float(vLayer) / cols));
    vec4 tex = texture(uAtlas, (cell + fract(uv)) / cols);
    float alphaTest = pc.fog.z;
    if (alphaTest > 0.0 && tex.a < alphaTest) discard;

    // sun shadows — mirrors Shaders.swift chunk_fs, 3x3 PCF.
    //
    // vShadowPos is shadowMat * world, WITHOUT the clip-Y flip that shadow.vert
    // applies on the way into the map. So the map's row for this point is at
    // v = 0.5 - sp.y*0.5, not sp.y*0.5 + 0.5 — the same expression MSL reaches
    // by writing `suv.y = 1.0 - suv.y`. Getting this backwards mirrors every
    // shadow vertically, which looks plausible until you walk past a wall.
    float shadowTerm = 1.0;
    float dayLight = pc.light.x;
    if (shadow.params.x > 0.5 && dayLight > 0.05) {
        vec3 sp = vShadowPos.xyz / vShadowPos.w;
        vec2 suv = vec2(sp.x * 0.5 + 0.5, 0.5 - sp.y * 0.5);
        float inMap = (suv.x > 0.0 && suv.x < 1.0 && suv.y > 0.0 && suv.y < 1.0 && sp.z < 1.0)
            ? 1.0 : 0.0;
        vec2 cuv = clamp(suv, vec2(0.0), vec2(1.0));
        float cz = clamp(sp.z, 0.0, 1.0) - 0.0012;
        float texel = shadow.params.y > 0.0 ? shadow.params.y : (1.0 / 2048.0);
        float s = 0.0;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                s += texture(uShadow, vec3(cuv + vec2(float(dx), float(dy)) * texel, cz));
            }
        }
        s /= 9.0;
        shadowTerm = mix(1.0, mix(0.55, 1.0, s), inMap * clamp(vSkyAmt, 0.0, 1.0) * dayLight);
    }

    vec3 col = tex.rgb * vColor * shadowTerm;
    float alpha = tex.a * pc.fog.w;

    // ultra: specular sun glint + fresnel on water (anim 1) — mirrors the
    // same branch in Shaders.swift chunk_fs. This used to be faked by
    // thickening the alpha 1.4x, which made Vulkan water heavier than the
    // Mac's in the non-ultra case where neither has a fresnel at all.
    float ultraOn = shadow.params.z;
    if (ultraOn > 0.5 && vAnim == 1u && dayLight > 0.02) {
        vec2 wp = vWorldPos.xz;
        float t2 = time * 1.3;
        // two-octave procedural wave normal
        float h1 = sin(wp.x * 1.7 + t2) * cos(wp.y * 1.3 - t2 * 0.8);
        float h2 = sin(wp.x * 3.9 - t2 * 1.7 + wp.y * 2.7) * 0.45;
        vec3 n = normalize(vec3((h1 + h2) * 0.18, 1.0, (h1 - h2) * 0.18));
        // sun dir = shadow matrix z-row (light-space depth axis); vWorldPos is
        // camera-relative so the view vector is just -vWorldPos
        vec3 sr = vec3(shadow.mat[0].z, shadow.mat[1].z, shadow.mat[2].z);
        vec3 sunD = (shadow.params.x > 0.5 && dot(sr, sr) > 1e-6)
            ? normalize(sr) : normalize(vec3(-0.45, 0.85, 0.18));
        if (sunD.y < 0.0) sunD = -sunD;
        vec3 viewD = normalize(-vWorldPos);
        vec3 hv = normalize(sunD + viewD);
        float spec = pow(max(dot(n, hv), 0.0), 90.0) * 1.6;
        float fres = pow(1.0 - clamp(viewD.y, 0.0, 1.0), 3.0);
        col += vec3(1.0, 0.95, 0.82) * spec * dayLight * shadowTerm;
        col += pc.fogColor.rgb * fres * 0.18 * dayLight;
        alpha = clamp(alpha + spec * 0.5 + fres * 0.1, 0.0, 1.0);
    }

    float fogStart = pc.fog.x, fogEnd = pc.fog.y;
    float fog = clamp((vFogDist - fogStart) / (fogEnd - fogStart), 0.0, 1.0);
    fog = fog * fog;
    col = mix(col, pc.fogColor.rgb, fog);
    outColor = vec4(col, alpha);
}
