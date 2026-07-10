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

// human-readable reason for the last failure (static buffer)
const char* pb_vk_last_error(void);

// GPU name once created ("" before) — shown in logs/reports
const char* pb_vk_device_name(void);

#ifdef __cplusplus
}
#endif

#endif
