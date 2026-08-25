#version 450
// the shared fullscreen triangle for every post pass — mirrors
// Shaders.swift fs_vs. No Y-flip here: Vulkan's NDC Y already points down
// and the framebuffer origin is top-left, so p*0.5+0.5 lands v=0 at the top,
// which is exactly where the offscreen scene image's first row is.

layout(location = 0) out vec2 vUV;

void main() {
    vec2 p = vec2(gl_VertexIndex == 1 ? 3.0 : -1.0,
                  gl_VertexIndex == 2 ? 3.0 : -1.0);
    gl_Position = vec4(p, 0.0, 1.0);
    vUV = p * 0.5 + 0.5;
}
