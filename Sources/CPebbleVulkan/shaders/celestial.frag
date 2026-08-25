#version 450
// sun/moon shading — mirrors Shaders.swift celestial_fs. Reversed
// smoothsteps are written as 1 - smoothstep(lo, hi, x): identical math,
// but GLSL leaves edge0 >= edge1 undefined where MSL does not.

layout(push_constant) uniform PC {
    mat4 viewProj;
    vec4 center;
    vec4 right;
    vec4 up;
} pc;

layout(set = 0, binding = 0) uniform sampler2D tex;

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

void main() {
    vec2 d = vUV - 0.5;
    float r = length(d) * 2.0;
    float moonPhase = pc.up.w;
    float texMode = pc.right.w;   // 0 = procedural; >=1 = pack art (moon: 1 + phase index)
    if (texMode > 0.5) {
        vec2 uv = vec2(vUV.x, 1.0 - vUV.y);
        if (moonPhase >= -0.5) {
            int ph = clamp(int(texMode + 0.5) - 1, 0, 7);   // texMode = 1 + phase
            vec2 cuv = uv * 0.98 + 0.01;                    // inset vs neighboring phase cells
            uv = vec2((cuv.x + float(ph % 4)) / 4.0, (cuv.y + float(ph / 4)) / 2.0);
        }
        vec4 t = texture(tex, uv);
        outColor = vec4(t.rgb, t.a);
        return;
    }
    if (moonPhase < -0.5) {
        float disc = 1.0 - smoothstep(0.55, 0.62, r);
        // fade the halo to exactly zero before the quad edge — the residual
        // alpha was painting the whole billboard as a visible square
        float glow = exp(-r * 2.4) * 0.55 * (1.0 - smoothstep(0.72, 1.0, r));
        vec3 col = vec3(1.0, 0.97, 0.85) * disc + vec3(1.0, 0.85, 0.6) * glow;
        outColor = vec4(col, max(disc, glow));
    } else {
        float disc = 1.0 - smoothstep(0.46, 0.5, r);
        float ph = moonPhase;
        float shift = (ph - 0.5) * 2.2;
        float shadow = smoothstep(0.42, 0.5, length(d * 2.0 + vec2(shift, 0.0)));
        vec3 col = vec3(0.92, 0.94, 1.0) * disc * mix(0.12, 1.0, shadow);
        col *= 1.0 - 0.16 * (1.0 - smoothstep(0.1, 0.2, length(d - vec2(0.1, 0.08))));
        col *= 1.0 - 0.12 * (1.0 - smoothstep(0.07, 0.16, length(d + vec2(0.12, -0.05))));
        outColor = vec4(col, disc);
    }
}
