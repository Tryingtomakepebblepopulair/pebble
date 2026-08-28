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
// model16 is column-major, camera-relative translation; mvp is computed here.
// parts24 is the posed rig: 24 column-major 4x4s (384 floats) indexed by the
// vertex stream's part id — pass NULL for the bind pose.
void pb_vk_push_entity(int geomId, const float* model16, float brightness, float alpha,
                       const float* parts24);

// camera + environment for the next frames; after the first call,
// pb_vk_frame(r,g,b) clears to the sky AND draws every live section
void pb_vk_set_camera(const float* viewProj16,
                      double camX, double camY, double camZ,
                      float time, float dayLight, float gammaB, float ambient,
                      float fogStart, float fogEnd, float alphaTest,
                      float fogR, float fogG, float fogB);

// sky, stars, sun/moon and clouds (PORTING module 07 sky slice).
// Call pb_vk_set_sky once per frame AFTER pb_vk_set_camera: the star fade,
// the cloud scroll and the cloud fade all read the day-light/time/fog that
// call installs. drawSky 0 leaves the frame's clear colour showing (the
// Mac's underwater/lava/blindness path); stars, sun/moon and clouds are
// drawn only when overworld is non-zero. dayPhase is world.time/24000 % 8.
void pb_vk_set_sky(int drawSky, int overworld, int endDim, int drawClouds,
                   const float* zenith3, const float* horizon3,
                   float sunGlow, const float* sunDir3,
                   float rainLevel, int dayPhase);

// the star field: the Mac's 16-byte stream (vec3 unit direction + float
// magnitude), one entry per star. Call once after create; re-uploading
// replaces the set, count 0 removes it.
int pb_vk_upload_stars(const void* verts, int count);

// optional pack art for the sky — 0 sun, 1 moon phase sheet (4x2 grid),
// 2 cloud noise (the red channel is the mask). Straight RGBA8, first
// upload wins. Without it the sun and moon fall back to the same
// procedural discs the Mac draws, and the cloud plane is skipped.
int pb_vk_upload_sky_tex(int which, const unsigned char* rgba, int w, int h);

// world detail (PORTING module 07 detail slice) — all three are per-frame
// streams: set them after pb_vk_set_camera, before pb_vk_frame. Passing
// count 0 (or never calling them) skips the pass for that frame.

// flat-coloured geometry: the block-selection outline (line list) and the
// blob shadows under entities (triangle list). Positions are camera-relative
// float3. Call begin once per frame, then push one batch per colour.
void pb_vk_begin_lines(void);
void pb_vk_push_lines(const float* verts, int vertCount, int tris,
                      float r, float g, float b, float a);

// extra chunk-stream meshes drawn with the terrain pipelines and atlas:
// slot 0 the falling-block/TNT cubes (pass 0, opaque), slot 1 the
// block-break crack overlay (pass 2, translucent). Same frozen 28-byte
// stream as a section; re-uploading a slot replaces it.
int pb_vk_set_overlay_mesh(int slot, int pass, float alphaTest,
                           double ox, double oy, double oz,
                           const void* verts, int vertCount,
                           const unsigned int* indices, int indexCount);
void pb_vk_clear_overlay_mesh(int slot);

// the first-person viewmodel: the same entity geometry registry, but drawn
// last with no depth test and the PROJECTION only — the arm and the held
// item are already in view space.
void pb_vk_set_viewmodel_proj(const float* proj16);
void pb_vk_begin_viewmodel(void);
void pb_vk_push_viewmodel(int geomId, const float* model16, float brightness, float alpha);

// particles in the Mac's 48-byte instance stream (pos3, uvRect4,
// tile*256+size*100, rgb+light), plus the camera's right/up basis
void pb_vk_set_particles(const void* instances, int count,
                         const float* right3, const float* up3);

// item / projectile billboards: 36-byte instances (center3, size, uvRect4,
// light) sampled from the icon atlas below
void pb_vk_set_sprites(const void* instances, int count, const float* right3);

// the 2048x512 item-icon atlas: stream 16x16 cells as slots get assigned.
// Returns -1 when the frame's rect queue is full — retry the cell next
// frame rather than leaving that slot permanently blank.
int pb_vk_sprite_atlas_update(int x, int y, int w, int h, const unsigned char* rgba);

// post-processing (PORTING module 07 post slice): the world renders into an
// offscreen target, a half-res bloom chain runs over it, and one fullscreen
// triangle composites the result into the swapchain with the UI on top.
// These are the composite's knobs — the Mac's CompositeUniforms minus the
// `ultra` terms this backend has no pass for. If the offscreen targets fail
// to build, the frame falls back to drawing straight into the swapchain and
// these are ignored.
void pb_vk_set_post(float bloomAmt, float warp, float time, float darkness,
                    float tintR, float tintG, float tintB, float tintA);

// sun shadows: a depth-only pass over every opaque and cutout section from
// the sun's side, sampled back in the terrain shader. shadowMat16 is the
// sun's view-projection (column-major, camera-relative, same convention as
// the camera matrix). enabled 0 skips the pass and the sampling entirely —
// the Mac gates it on the shadows setting, the dimension, the daylight and
// the sun's height.
void pb_vk_set_shadow(const float* shadowMat16, int enabled);

// ultra (SSAO + volumetric light) — the Mac's "ultra" shader preset. block64
// is the 256-byte uniform: invViewProj, viewProj and shadowMat (16 floats
// each, column-major, camera-relative), then sunDir+dayLight, params
// (time, far, shadowOK, underwater), fogColor+renderDistance, and the
// target's texel size. `on` 0 skips the pass entirely. If the backend could
// not build the ultra targets this call is a no-op and the composite's ultra
// branch stays off.
void pb_vk_set_ultra(int on, const float* block64);

// UI images (title photo/wordmark): register once, push quads per frame
// (GUI units + UV rect) — drawn UNDER the canvas verts, linear-filtered
int pb_vk_upload_image(int id, const unsigned char* rgba, int w, int h);
void pb_vk_ui_push_image(int id, float x, float y, float w, float h,
                         float u0, float v0, float u1, float v1);

// UI overlay (the portable UICanvas): stream dirty 1024x1024-atlas cells
// and the frame's 32-byte vertex stream in GUI units
void pb_vk_ui_update_atlas(int x, int y, int w, int h, const unsigned char* rgba);
void pb_vk_ui_set_frame(const float* verts, int floatCount, float screenW, float screenH);

// the resource pack's composed GUI sheet (RGBA8) — menus, containers and the
// bitmap font. Upload once at startup; without it the interface falls back to
// the procedural canvas atlas.
int pb_vk_upload_gui_sheet(const unsigned char* rgba, int w, int h);

// which slice of the frame's UI stream samples which texture: `segs` is
// pairCount pairs of (gui, firstVertex) in order, the last running to the end
// of the stream. Call after pb_vk_ui_set_frame. No segments = one draw from
// the canvas atlas, as before.
void pb_vk_ui_set_segments(const int* segs, int pairCount);

// human-readable reason for the last failure (static buffer)
// live section slots — two GPU allocations each, against the driver's
// maxMemoryAllocationCount (reported by pb_vk_device_name). When terrain
// starts going missing, this is the number that says why.
int pb_vk_section_count(void);

const char* pb_vk_last_error(void);

// GPU name once created ("" before) — shown in logs/reports
const char* pb_vk_device_name(void);

#ifdef __cplusplus
}
#endif

#endif
