#version 450
// SSAO + volumetric light — mirrors Shaders.swift ultra_fs. Runs at half res
// over the scene depth and the shadow map, then gets blurred and folded into
// the composite. Off unless the ultra setting is on, like the Mac.
//
// UltraU is 256 bytes, twice the push-constant guarantee, so it arrives as a
// uniform buffer.

layout(set = 0, binding = 0) uniform sampler2D uDepth;    // scene depth, plain sampler
layout(set = 1, binding = 0) uniform sampler2DShadow uShadow;

layout(set = 2, binding = 0) uniform Ultra {
    mat4 invViewProj;   // camera-relative clip -> world
    mat4 viewProj;
    mat4 shadowMat;
    vec4 sunDir;        // xyz + dayLight
    vec4 params;        // time, far, shadowOK, underwater
    vec4 fogColor;      // rgb + renderDistance (blocks)
    vec4 texel;         // 1/w, 1/h of this target
} u;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

// The uv here comes from fs.vert, so it is Vulkan NDC mapped to 0..1. The
// stored matrices are the Metal-side ones, so the clip position feeding the
// inverse gets its Y flipped back — the same contract as sky.vert.
vec3 ultraWorldPos(vec2 uv, float depth) {
    vec4 ndc = vec4(uv.x * 2.0 - 1.0, -(uv.y * 2.0 - 1.0), depth, 1.0);
    vec4 p = u.invViewProj * ndc;
    return p.xyz / p.w;
}

void main() {
    float depth = texture(uDepth, vUV).r;
    vec3 wpos = ultraWorldPos(vUV, depth);
    float dist = length(wpos);
    vec3 rayDir = wpos / max(dist, 1e-5);
    bool isSky = depth >= 0.99999;
    float dayLight = u.sunDir.w;

    // --- SSAO: a hemisphere of world-space offsets, depth-compared on screen
    float ao = 1.0;
    if (!isSky && dist < 140.0) {
        vec2 px = u.texel.xy;
        vec3 pR = ultraWorldPos(vUV + vec2(px.x, 0.0), texture(uDepth, vUV + vec2(px.x, 0.0)).r);
        vec3 pD = ultraWorldPos(vUV + vec2(0.0, px.y), texture(uDepth, vUV + vec2(0.0, px.y)).r);
        vec3 nrm = normalize(cross(pD - wpos, pR - wpos));
        float ang0 = fract(sin(dot(vUV * 961.0, vec2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
        float occ = 0.0;
        const int TAPS = 8;
        for (int i = 0; i < TAPS; i++) {
            float a = ang0 + float(i) * 2.399963;           // golden-angle spiral
            float r = (float(i) + 0.7) / float(TAPS);
            float rad = 0.65 * r;
            vec3 t = vec3(cos(a), 0.0, sin(a));
            vec3 tang = normalize(t - nrm * dot(t, nrm));
            vec3 sp = wpos + (tang * rad + nrm * rad * 0.55);
            vec4 cp = u.viewProj * vec4(sp, 1.0);
            if (cp.w <= 0.0) continue;
            // the Metal texture flip and the Vulkan NDC flip cancel, so this
            // is the same expression on both backends
            vec2 suv = vec2(cp.x / cp.w * 0.5 + 0.5, 0.5 - cp.y / cp.w * 0.5);
            if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;
            float sd = texture(uDepth, suv).r;
            vec3 spos = ultraWorldPos(suv, sd);
            vec3 dvec = spos - wpos;
            float dlen = length(dvec);
            if (dlen < 0.001) continue;
            float occA = max(0.0, dot(nrm, dvec / dlen) - 0.08);
            float fall = 1.0 - clamp(dlen / 1.6, 0.0, 1.0);
            occ += occA * fall;
        }
        ao = clamp(1.0 - occ / float(TAPS) * 2.4, 0.0, 1.0);
        ao = mix(ao, 1.0, clamp(dist / 140.0, 0.0, 1.0));   // fade with distance
    }

    // --- volumetric light: march the camera ray, sampling the shadow map
    vec3 vol = vec3(0.0);
    if (u.params.z > 0.5 && dayLight > 0.05) {
        vec3 sr = vec3(u.shadowMat[0].z, u.shadowMat[1].z, u.shadowMat[2].z);
        vec3 sunD = normalize(dot(sr, sr) > 1e-6 ? sr : vec3(0.0, 1.0, 0.0));
        if (sunD.y < 0.0) sunD = -sunD;
        float cosA = dot(rayDir, sunD);
        // Henyey-Greenstein-ish forward scattering
        float g = 0.62;
        float phase = (1.0 - g * g) / (4.0 * 3.14159 * pow(1.0 + g * g - 2.0 * g * cosA, 1.5));
        float marchEnd = min(isSky ? u.params.y : dist, 72.0);
        const int STEPS = 18;
        float dither = fract(sin(dot(vUV * 917.0, vec2(36.887, 19.781))) * 24634.6345);
        float lit = 0.0;
        for (int i = 0; i < STEPS; i++) {
            float f = (float(i) + dither) / float(STEPS);
            f = f * f;                                     // denser near the camera
            vec3 p = rayDir * (f * marchEnd);
            vec4 sc = u.shadowMat * vec4(p, 1.0);
            vec3 sp = sc.xyz / sc.w;
            vec2 suv = vec2(sp.x * 0.5 + 0.5, 0.5 - sp.y * 0.5);
            if (suv.x <= 0.0 || suv.x >= 1.0 || suv.y <= 0.0 || suv.y >= 1.0 || sp.z >= 1.0) {
                lit += 0.6;        // outside the map: assume lit
                continue;
            }
            lit += texture(uShadow, vec3(suv, clamp(sp.z, 0.0, 1.0) - 0.0015));
        }
        lit /= float(STEPS);
        float strength = 0.55 * dayLight * phase;
        vol = vec3(1.0, 0.92, 0.74) * lit * strength;
    }
    outColor = vec4(vol, ao);
}
