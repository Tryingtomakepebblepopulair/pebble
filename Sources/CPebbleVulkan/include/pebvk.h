// Pebble Vulkan backend — C ABI (PORTING module 07). Opaque to Swift: no
// Vk* types cross this boundary. Windows-only bodies; stubs elsewhere so
// every platform builds the target.

#ifndef PEBVK_H
#define PEBVK_H

#ifdef __cplusplus
extern "C" {
#endif

// create the renderer for a native window (HWND/HINSTANCE on Windows).
// returns 0 on success — anything else: read pb_vk_last_error()
int pb_vk_create(void* hwnd, void* hinstance, int width, int height);

// render one frame: clear the whole window to (r,g,b) and present.
// returns 0 on success, 1 on recoverable skip (resize mid-flight)
int pb_vk_frame(float r, float g, float b);

// note a window resize (swapchain rebuilds on the next frame)
void pb_vk_resize(int width, int height);

void pb_vk_destroy(void);

// upload the terrain atlas: straight RGBA8, `layers` slices of tileW×tileH
// (the frozen ABI's texture2d_array). Call once after create.
int pb_vk_upload_atlas(const unsigned char* rgba, int tileW, int tileH, int layers);

// upload one section mesh in the frozen 28-byte chunk stream
// (docs/render-abi.md). pass: 0 opaque, 1 cutout, 2 translucent.
// (ox,oy,oz) is the section's world-space origin. Re-uploading an id
// replaces it; vertCount 0 removes it.
int pb_vk_upload_section(unsigned long long id, int pass,
                         double ox, double oy, double oz,
                         const void* verts, int vertCount,
                         const unsigned int* indices, int indexCount);
void pb_vk_remove_section(unsigned long long id, int pass);
void pb_vk_clear_sections(void);

// register one entity type's bind-pose geometry (36-byte ABI stream,
// non-indexed) + its skin texture. Static per type; first upload wins.
int pb_vk_upload_entity_geom(int geomId, const void* verts, int vertCount,
                             const unsigned char* rgba, int texW, int texH);

// rebuild the per-frame entity draw list (call once, then push visible ones)
void pb_vk_begin_entities(void);
// model16 is column-major, camera-relative translation; mvp is computed here
void pb_vk_push_entity(int geomId, const float* model16, float brightness, float alpha);

// camera + environment for the next frames; after the first call,
// pb_vk_frame(r,g,b) clears to the sky AND draws every live section
void pb_vk_set_camera(const float* viewProj16,
                      double camX, double camY, double camZ,
                      float time, float dayLight, float gammaB, float ambient,
                      float fogStart, float fogEnd, float alphaTest,
                      float fogR, float fogG, float fogB);

// UI overlay (the portable UICanvas): stream dirty 1024x1024-atlas cells
// and the frame's 32-byte vertex stream in GUI units
void pb_vk_ui_update_atlas(int x, int y, int w, int h, const unsigned char* rgba);
void pb_vk_ui_set_frame(const float* verts, int floatCount, float screenW, float screenH);

// human-readable reason for the last failure (static buffer)
const char* pb_vk_last_error(void);

// GPU name once created ("" before) — shown in logs/reports
const char* pb_vk_device_name(void);

#ifdef __cplusplus
}
#endif

#endif
