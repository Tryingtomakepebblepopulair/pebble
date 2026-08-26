// Pebble Vulkan backend (PORTING module 07) — Windows bootstrap slice:
// instance → Win32 surface → device → swapchain → clear+present, with
// swapchain recreation on resize/out-of-date. No Vulkan SDK needed to
// build OR run: vulkan-1.dll is loaded at runtime (every GPU driver since
// ~2016 ships it) and every entry point comes from vkGetInstanceProcAddr.

#include "pebvk.h"

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define VK_USE_PLATFORM_WIN32_KHR
#define VK_NO_PROTOTYPES
#include "vk/vulkan_core.h"
#include "vk/vulkan_win32.h"
#include "shaders_spv.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

static char g_err[512];
static char g_gpu[256];
#define FAIL(...) do { snprintf(g_err, sizeof g_err, __VA_ARGS__); return -1; } while (0)
#define VKTRY(x, what) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) FAIL(what " (VkResult %d)", (int)r_); } while (0)

// ---- dynamically loaded entry points ---------------------------------------
static PFN_vkGetInstanceProcAddr ipa;
static PFN_vkGetDeviceProcAddr dpa;
#define I_FN(n) static PFN_##n n;
I_FN(vkCreateInstance)
I_FN(vkEnumeratePhysicalDevices)
I_FN(vkGetPhysicalDeviceProperties)
I_FN(vkGetPhysicalDeviceQueueFamilyProperties)
I_FN(vkCreateWin32SurfaceKHR)
I_FN(vkGetPhysicalDeviceSurfaceSupportKHR)
I_FN(vkGetPhysicalDeviceSurfaceCapabilitiesKHR)
I_FN(vkGetPhysicalDeviceSurfaceFormatsKHR)
I_FN(vkCreateDevice)
I_FN(vkDestroySurfaceKHR)
I_FN(vkDestroyInstance)
#define D_FN(n) static PFN_##n n;
D_FN(vkGetDeviceQueue)
D_FN(vkCreateSwapchainKHR)
D_FN(vkDestroySwapchainKHR)
D_FN(vkGetSwapchainImagesKHR)
D_FN(vkCreateImageView)
D_FN(vkDestroyImageView)
D_FN(vkCreateRenderPass)
D_FN(vkDestroyRenderPass)
D_FN(vkCreateFramebuffer)
D_FN(vkDestroyFramebuffer)
D_FN(vkCreateCommandPool)
D_FN(vkDestroyCommandPool)
D_FN(vkAllocateCommandBuffers)
D_FN(vkBeginCommandBuffer)
D_FN(vkCmdBeginRenderPass)
D_FN(vkCmdEndRenderPass)
D_FN(vkEndCommandBuffer)
D_FN(vkCreateSemaphore)
D_FN(vkDestroySemaphore)
D_FN(vkCreateFence)
D_FN(vkDestroyFence)
D_FN(vkWaitForFences)
D_FN(vkResetFences)
D_FN(vkAcquireNextImageKHR)
D_FN(vkQueueSubmit)
D_FN(vkQueuePresentKHR)
D_FN(vkDeviceWaitIdle)
D_FN(vkDestroyDevice)
D_FN(vkResetCommandBuffer)
D_FN(vkCreateBuffer)
D_FN(vkDestroyBuffer)
D_FN(vkGetBufferMemoryRequirements)
D_FN(vkBindBufferMemory)
D_FN(vkAllocateMemory)
D_FN(vkFreeMemory)
D_FN(vkMapMemory)
D_FN(vkUnmapMemory)
D_FN(vkCreateImage)
D_FN(vkDestroyImage)
D_FN(vkGetImageMemoryRequirements)
D_FN(vkBindImageMemory)
D_FN(vkCreateShaderModule)
D_FN(vkDestroyShaderModule)
D_FN(vkCreatePipelineLayout)
D_FN(vkDestroyPipelineLayout)
D_FN(vkCreateGraphicsPipelines)
D_FN(vkDestroyPipeline)
D_FN(vkCreateDescriptorSetLayout)
D_FN(vkDestroyDescriptorSetLayout)
D_FN(vkCreateDescriptorPool)
D_FN(vkDestroyDescriptorPool)
D_FN(vkAllocateDescriptorSets)
D_FN(vkUpdateDescriptorSets)
D_FN(vkCreateSampler)
D_FN(vkDestroySampler)
D_FN(vkCmdBindPipeline)
D_FN(vkCmdBindVertexBuffers)
D_FN(vkCmdBindIndexBuffer)
D_FN(vkCmdBindDescriptorSets)
D_FN(vkCmdPushConstants)
D_FN(vkCmdDrawIndexed)
D_FN(vkCmdDraw)
D_FN(vkCmdSetViewport)
D_FN(vkCmdSetScissor)
D_FN(vkCmdPipelineBarrier)
D_FN(vkCmdCopyBufferToImage)
D_FN(vkQueueWaitIdle)
static PFN_vkGetPhysicalDeviceMemoryProperties vkGetPhysicalDeviceMemoryProperties;

// ---- state -------------------------------------------------------------------
#define MAX_SWAP_IMAGES 8
#define FRAMES_IN_FLIGHT 2

static HMODULE g_lib;
static VkInstance g_instance;
static VkSurfaceKHR g_surface;
static VkPhysicalDevice g_phys;
static VkDevice g_device;
static VkQueue g_queue;
static uint32_t g_queueFamily;
static VkSwapchainKHR g_swapchain;
static VkFormat g_format;
static VkExtent2D g_extent;
static uint32_t g_imageCount;
static VkImage g_images[MAX_SWAP_IMAGES];
static VkImageView g_views[MAX_SWAP_IMAGES];
static VkFramebuffer g_fbs[MAX_SWAP_IMAGES];
static VkRenderPass g_pass;
static VkCommandPool g_pool;
static VkCommandBuffer g_cmd[FRAMES_IN_FLIGHT];
static VkSemaphore g_acquireSem[FRAMES_IN_FLIGHT];
static VkSemaphore g_renderSem[MAX_SWAP_IMAGES];
static VkFence g_fence[FRAMES_IN_FLIGHT];
static uint32_t g_frame;
static int g_pendingW, g_pendingH, g_needRebuild;

// depth buffer (rebuilt with the swapchain)
static VkImage g_depthImage;
static VkDeviceMemory g_depthMem;
static VkImageView g_depthView;

// chunk pipelines + atlas
static VkDescriptorSetLayout g_setLayout;
static VkPipelineLayout g_pipeLayout;
static VkPipeline g_pipeOpaque;      // depth write, no blend (opaque + cutout)
static VkPipeline g_pipeTranslucent; // depth test only, alpha blend
static VkDescriptorPool g_descPool;
static VkDescriptorSet g_atlasSet;
static VkImage g_atlasImage;
static VkDeviceMemory g_atlasMem;
static VkImageView g_atlasView;
static VkSampler g_atlasSampler;

// world sections: one vertex+index buffer pair per (id, pass)
#define MAX_SECTIONS 8192
typedef struct {
    uint64_t id;
    int pass;            // 0 opaque, 1 cutout, 2 translucent (-1 = free slot)
    double ox, oy, oz;   // world-space section origin
    VkBuffer vbuf, ibuf;
    VkDeviceMemory vmem, imem;
    uint32_t indexCount;
} PbSection;
static PbSection g_sections[MAX_SECTIONS];
static int g_sectionsInit;

// 128-byte push constants — must mirror shaders/chunk.vert PC block
typedef struct {
    float viewProj[16];
    float origin[4];
    float light[4];
    float fog[4];
    float fogColor[4];
} PbPush;
_Static_assert(sizeof(PbPush) == 128, "chunk push block must match shaders/chunk.vert");

// entities: bind-pose geometry per type + one skin texture each
// 100 mob models + one slot per remote player with a custom skin, and the
// top 32 reserved for the viewmodel (WinViewmodel)
#define MAX_ENTITY_GEOMS 256
#define MAX_ENTITY_DRAWS 512
typedef struct {
    int used;
    VkBuffer vbuf;
    VkDeviceMemory vmem;
    uint32_t vertCount;
    VkImage tex;
    VkDeviceMemory texMem;
    VkImageView texView;
    VkDescriptorSet set;
} PbEntityGeom;
static PbEntityGeom g_entGeoms[MAX_ENTITY_GEOMS];
typedef struct {
    float mvp[16];
    float light[4];
} PbEntityPush;
// 24 part matrices per posed entity — 1536 bytes, far past the 128 Vulkan
// guarantees for push constants, so they ride a dynamic uniform buffer with
// one slot per draw instead
#define ENTITY_PARTS 24
#define ENTITY_PARTS_BYTES (ENTITY_PARTS * 16 * 4)
static VkDeviceSize g_partsStride = ENTITY_PARTS_BYTES;
// ONE buffer for every frame in flight and every draw: a descriptor set can
// only name one buffer, and the dynamic offset already has to select the
// draw slot, so let it select the frame region too
#define PARTS_SLOTS_PER_FRAME (MAX_ENTITY_DRAWS + MAX_VM_DRAWS)
static VkBuffer g_partsBuf;
static VkDeviceMemory g_partsMem;
static void* g_partsMap;
static VkDescriptorSetLayout g_entSetLayout;
_Static_assert(sizeof(PbEntityPush) == 80, "entity push block must match shaders/entity.vert");
typedef struct {
    int geomId;
    int partsSlot;       // index into the frame's part-matrix ring
    PbEntityPush push;
} PbEntityDraw;
static PbEntityDraw g_entDraws[MAX_ENTITY_DRAWS];
static int g_entDrawCount;
static VkPipeline g_pipeEntity;
static VkPipelineLayout g_entLayout;

// camera for the next frame (set per frame from Swift)
static PbPush g_push;      // viewProj/light/fog shared; origin per section
static double g_camX, g_camY, g_camZ;
static float g_cutoutAlphaTest;
static int g_worldDraws;   // 0 = sky-only clear (bootstrap mode)

// ---- UI overlay: the portable UICanvas's 32-byte stream --------------------
#define UI_ATLAS 1024
#define MAX_UI_RECTS 128
static VkPipeline g_pipeUI;
static VkPipelineLayout g_uiLayout;
static VkImage g_uiImage;
static VkDeviceMemory g_uiMem;
static VkImageView g_uiView;
static VkDescriptorSet g_uiSet;
static int g_uiImageReady;          // first barrier is UNDEFINED->...
typedef struct {
    int x, y, w, h;
    unsigned char* pixels;          // malloc'd copy, freed after upload
} PbUIRect;
static PbUIRect g_uiRects[MAX_UI_RECTS];
static int g_uiRectCount;
static VkBuffer g_uiVbuf[FRAMES_IN_FLIGHT];
static VkDeviceMemory g_uiVmem[FRAMES_IN_FLIGHT];
static void* g_uiVmap[FRAMES_IN_FLIGHT];
static VkDeviceSize g_uiVcap[FRAMES_IN_FLIGHT];
static int g_uiVertCount;           // vertices to draw this frame
static float g_uiScreen[4];         // GUI width/height push constants
static VkSampler g_linearSampler;   // photos want smooth filtering
#define MAX_UI_IMAGES 8
typedef struct {
    int used;
    VkImage tex;
    VkDeviceMemory mem;
    VkImageView view;
    VkDescriptorSet set;
} PbUIImage;
static PbUIImage g_uiImages[MAX_UI_IMAGES];
typedef struct {
    int id;
    float x, y, w, h, u0, v0, u1, v1;
} PbImageQuad;
static PbImageQuad g_imgQuads[MAX_UI_IMAGES];
static int g_imgQuadCount;
static VkBuffer g_imgVbuf[FRAMES_IN_FLIGHT];
static VkDeviceMemory g_imgVmem[FRAMES_IN_FLIGHT];
static void* g_imgVmap[FRAMES_IN_FLIGHT];

// ---- sky: dome + stars + sun/moon + clouds (PORTING 07 sky slice) ----------
// push blocks — each mirrors its shaders/*.vert PC block byte for byte
typedef struct {
    float invViewProj[16];
    float zenith[4];
    float horizon[4];
    float horizonSun[4];   // rgb + sunGlow
    float sunDir[4];       // xyz + void (1 = the End's flat sky)
} PbSkyPush;               // 128
typedef struct {
    float viewProj[16];
    float params[4];       // time, alpha, screenW, screenH
} PbStarsPush;             // 80
typedef struct {
    float viewProj[16];
    float center[4];       // xyz + size
    float right[4];        // xyz + texMode
    float up[4];           // xyz + moonPhase (<0 = sun)
} PbCelPush;               // 112
typedef struct {
    float viewProj[16];
    float offset[4];       // xyz plane origin + half-size
    float scroll[4];       // sx, sy, brightness, fogEnd
} PbCloudPush;             // 96

// glslangValidator -q reports these exact block sizes for the matching
// shaders/*.vert — a mismatch here is a GPU-side garbage-uniform bug that
// no amount of staring at the render finds, so let the compiler catch it
_Static_assert(sizeof(PbSkyPush) == 128, "sky push block must match shaders/sky.vert");
_Static_assert(sizeof(PbStarsPush) == 80, "stars push block must match shaders/stars.vert");
_Static_assert(sizeof(PbCelPush) == 112, "celestial push block must match shaders/celestial.vert");
_Static_assert(sizeof(PbCloudPush) == 96, "cloud push block must match shaders/cloud.vert");

static VkPipeline g_pipeSky, g_pipeStars, g_pipeCelestial, g_pipeCelestialAdd, g_pipeCloud;
static VkPipelineLayout g_skyLayout, g_starsLayout, g_celLayout, g_cloudLayout;

// the Mac's 16-byte star stream (vec3 dir + float magnitude), one per instance
#define MAX_STARS 8192
static VkBuffer g_starBuf;
static VkDeviceMemory g_starMem;
static int g_starCount;

// pack art for the sky: sun, moon phase sheet, cloud noise. A 1x1 white
// stand-in keeps the celestial pipeline's set bound when art is missing
// (the shader then takes its procedural branch and ignores the sampler).
#define SKY_TEX_SUN 0
#define SKY_TEX_MOON 1
#define SKY_TEX_CLOUD 2
#define SKY_TEX_COUNT 3
typedef struct {
    int used;
    VkImage tex;
    VkDeviceMemory mem;
    VkImageView view;
    VkDescriptorSet set;
} PbSkyTex;
static PbSkyTex g_skyTex[SKY_TEX_COUNT];
static VkSampler g_cloudSampler;   // linear + REPEAT: the mask wraps at uv*12
static VkImage g_dummyImage;
static VkDeviceMemory g_dummyMem;
static VkImageView g_dummyView;
static VkDescriptorSet g_dummySet;

// environment for the next frames — set once per frame, after set_camera
static struct {
    int on;            // 0 = no sky (underwater / lava / blindness / no world)
    int overworld;     // stars, sun/moon and clouds are overworld-only
    int endDim;
    int clouds;
    float zenith[3];
    float horizon[3];
    float sunGlow;
    float sunDir[3];
    float rainLevel;
    int dayPhase;      // 0..7 moon phase index
} g_sky;

// ---- world detail: selection lines, particles, item sprites ---------------
// (PORTING 07 detail slice) — push blocks mirror shaders/line.vert,
// particle.vert and sprite.vert
typedef struct {
    float viewProj[16];
    float color[4];
} PbLinePush;              // 80
typedef struct {
    float viewProj[16];
    float right[4];        // xyz camera right
    float up[4];           // xyz camera up, w dayLight
    float misc[4];         // x = atlas columns
} PbParticlePush;          // 112
typedef struct {
    float viewProj[16];
    float right[4];        // xyz camera right
    float fog[4];          // start, end
    float fogColor[4];
} PbSpritePush;            // 112
_Static_assert(sizeof(PbLinePush) == 80, "line push block must match shaders/line.vert");
_Static_assert(sizeof(PbParticlePush) == 112, "particle push block must match shaders/particle.vert");
_Static_assert(sizeof(PbSpritePush) == 112, "sprite push block must match shaders/sprite.vert");

#define MAX_LINE_VERTS 8192          // 12 edges x 2 verts x plenty of boxes
#define MAX_PARTICLES 4096           // the Mac's cap, same number
#define MAX_SPRITES 2048        // the Mac has no cap; make hitting this implausible
#define LINE_STRIDE 12
#define PARTICLE_STRIDE 48           // the Mac's instance stream, byte for byte
#define SPRITE_STRIDE 36

static VkPipeline g_pipeLines, g_pipeLineTris, g_pipeParticle, g_pipeSprite;
static VkPipelineLayout g_lineLayout, g_particleLayout, g_spriteLayout;

// per-frame host-visible streams, one per frame in flight (the UI's scheme)
static VkBuffer g_lineVbuf[FRAMES_IN_FLIGHT];
static VkDeviceMemory g_lineVmem[FRAMES_IN_FLIGHT];
static void* g_lineVmap[FRAMES_IN_FLIGHT];
static int g_lineVertCount;

static VkBuffer g_partVbuf[FRAMES_IN_FLIGHT];
static VkDeviceMemory g_partVmem[FRAMES_IN_FLIGHT];
static void* g_partVmap[FRAMES_IN_FLIGHT];
static int g_partCount;
static float g_partRight[3], g_partUp[3];

static VkBuffer g_sprVbuf[FRAMES_IN_FLIGHT];
static VkDeviceMemory g_sprVmem[FRAMES_IN_FLIGHT];
static void* g_sprVmap[FRAMES_IN_FLIGHT];
static int g_sprCount;
static float g_sprRight[3];

// the item-icon atlas: 128x32 cells of 16x16, streamed cell by cell as the
// client assigns slots (same dirty-rect path as the UI canvas)
#define SPRITE_ATLAS_W 2048
#define SPRITE_ATLAS_H 512
#define MAX_SPRITE_RECTS 64
static VkImage g_sprImage;
static VkDeviceMemory g_sprMem;
static VkImageView g_sprView;
static VkDescriptorSet g_sprSet;
static int g_sprImageReady;
static PbUIRect g_sprRects[MAX_SPRITE_RECTS];
static int g_sprRectCount;

// lines come in batches now — the selection outline is one colour, but every
// blob shadow under an entity has its own alpha
#define MAX_LINE_BATCHES 128
typedef struct {
    int first;          // first vertex in the shared line buffer
    int count;
    int tris;           // 1 = triangle list (blob shadows), 0 = line list
    float color[4];
} PbLineBatch;
static PbLineBatch g_lineBatches[MAX_LINE_BATCHES];
static int g_lineBatchCount;

// extra chunk-stream meshes drawn alongside the world: falling blocks / TNT
// (opaque) and the block-break crack overlay (translucent). Same 28-byte
// stream, same pipelines and atlas as the terrain — only the origin and the
// alpha test differ, so they ride the chunk path rather than a new one.
#define OVERLAY_CUBES 0
#define OVERLAY_CRACK 1
#define OVERLAY_COUNT 2
#define MAX_OVERLAY_VERTS 8192
#define MAX_OVERLAY_INDICES 12288
typedef struct {
    int pass;            // 0 opaque, 2 translucent
    float alphaTest;
    double ox, oy, oz;
    uint32_t indexCount; // 0 = nothing to draw this frame
    // per-frame mapped streams: the cube mesh is rebuilt every frame as the
    // entities move, so allocating (and stalling on) a fresh buffer each time
    // is out — these ride the same ring the particles use
    VkBuffer vbuf[FRAMES_IN_FLIGHT], ibuf[FRAMES_IN_FLIGHT];
    VkDeviceMemory vmem[FRAMES_IN_FLIGHT], imem[FRAMES_IN_FLIGHT];
    void* vmap[FRAMES_IN_FLIGHT];
    void* imap[FRAMES_IN_FLIGHT];
} PbOverlayMesh;
static PbOverlayMesh g_overlay[OVERLAY_COUNT];

// the first-person viewmodel: the same entity geometry and pipeline, but
// projection-only (the arm lives in view space) and depth-always, so it
// never clips into a wall
#define MAX_VM_DRAWS 16
static VkPipeline g_pipeViewmodel;
static PbEntityDraw g_vmDraws[MAX_VM_DRAWS];
static int g_vmDrawCount;
static float g_vmProj[16];

// ---- post-processing: offscreen scene, bloom chain, composite -------------
// The world used to go straight into the swapchain. It now renders into an
// offscreen colour+depth pair, a half-res bloom chain runs over it, and one
// fullscreen triangle composites the result into the swapchain with the UI
// on top — the same shape as the Mac's scene target.
//
// Every piece is optional: if any of it fails to build, g_postOK stays 0 and
// the frame falls back to the old direct path. A missing bloom is a far
// better failure than a black window.
static int g_postOK;
static VkRenderPass g_scenePass;      // colour + depth, offscreen
static VkRenderPass g_bloomPass;      // colour only
static VkImage g_sceneImage;
static VkDeviceMemory g_sceneMem;
static VkImageView g_sceneView;
static VkFramebuffer g_sceneFb;
static VkDescriptorSet g_sceneSet;
static VkImage g_bloomImg[2];
static VkDeviceMemory g_bloomMem[2];
static VkImageView g_bloomView[2];
static VkFramebuffer g_bloomFb[2];
static VkDescriptorSet g_bloomSet[2];
static VkExtent2D g_bloomExtent;
static VkPipeline g_pipeBloomExtract, g_pipeBlur, g_pipeComposite;
static VkPipelineLayout g_bloomLayout, g_compositeLayout;
static float g_post[12];              // bloomAmt/warp/time/darkness, tint rgba, params2

// ---- sun shadows ----------------------------------------------------------
// A depth-only pass over every live section with the sun's view-projection,
// sampled back in chunk.frag. The shadow matrix cannot ride the chunk push
// block (already the full 128 bytes), so it lives in a small dynamic uniform
// buffer that the chunk descriptor set also carries.
#define SHADOW_SIZE 2048
#define SHADOW_UBO_BYTES 80          // mat4 + vec4
typedef struct {
    float shadowMat[16];
    float origin[4];
} PbShadowPush;                      // 80, shaders/shadow.vert
_Static_assert(sizeof(PbShadowPush) == 80, "shadow push block must match shaders/shadow.vert");

static VkRenderPass g_shadowPass;
static VkImage g_shadowImage;
static VkDeviceMemory g_shadowMem;
static VkImageView g_shadowView;
static VkFramebuffer g_shadowFb;
static VkSampler g_shadowSampler;    // depth-compare, so one fetch is a PCF tap
static VkPipeline g_pipeShadow;
static VkPipelineLayout g_shadowLayout;
static VkDescriptorSetLayout g_chunkSetLayout;
static VkDeviceSize g_shadowUboStride = SHADOW_UBO_BYTES;
static VkBuffer g_shadowUbo;
static VkDeviceMemory g_shadowUboMem;
static void* g_shadowUboMap;
static float g_shadowMat[16];
static int g_shadowOn;
static VkDescriptorSet g_atlasSetPlain;   // atlas alone, for the particle pass

// ---- ultra: SSAO + volumetric light --------------------------------------
// A half-res pass over the scene depth and the shadow map, blurred, then
// folded into the composite. Off unless the client asks for it (the Mac's
// "ultra" shader preset), and like the rest of the post chain it degrades to
// nothing rather than to a broken frame.
#define ULTRA_UBO_BYTES 256
static int g_ultraOK;
static int g_ultraOn;
static VkImage g_ultraImg[2];
static VkDeviceMemory g_ultraMem[2];
static VkImageView g_ultraView[2];
static VkFramebuffer g_ultraFb[2];
static VkDescriptorSet g_ultraSet[2];
static VkExtent2D g_ultraExtent;
static VkPipeline g_pipeUltra, g_pipeUltraBlur;
static VkPipelineLayout g_ultraLayout;
static VkDescriptorSetLayout g_uboSetLayout;
static VkDescriptorSet g_depthSet, g_shadowSamplerSet, g_ultraUboSet;
static VkSampler g_depthSampler;      // plain (non-compare) reads of depth
static VkBuffer g_ultraUbo;
static VkDeviceMemory g_ultraUboMem;
static void* g_ultraUboMap;
static VkDeviceSize g_ultraUboStride = 256;
static float g_ultraU[64];            // the 256-byte block, filled from Swift

// ---- the pack's GUI sheet ---------------------------------------------------
// The canvas emits its vertex stream in segments: some sample the 1024x1024
// canvas atlas, some the pack's GUI composite. Without the second texture the
// Windows client drew the whole interface from the procedural atlas, so the
// menus looked nothing like the Mac's.
#define MAX_UI_SEGMENTS 64
typedef struct {
    int gui;        // 1 = sample the pack sheet
    int first;      // first vertex
    int count;
} PbUISegment;
static PbUISegment g_uiSegs[MAX_UI_SEGMENTS];
static int g_uiSegCount;
static VkImage g_guiImage;
static VkDeviceMemory g_guiMem;
static VkImageView g_guiView;
static VkDescriptorSet g_guiSet;

static void mat4_mul(float* out, const float* a, const float* b) {
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            float s = 0;
            for (int k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
            out[c * 4 + r] = s;
        }
    }
}

/// column-major 4x4 inverse; returns 0 on a singular matrix (out untouched)
static int mat4_invert(float* out, const float* m) {
    float inv[16];
    inv[0]  =  m[5]*m[10]*m[15] - m[5]*m[11]*m[14] - m[9]*m[6]*m[15]
             + m[9]*m[7]*m[14] + m[13]*m[6]*m[11] - m[13]*m[7]*m[10];
    inv[4]  = -m[4]*m[10]*m[15] + m[4]*m[11]*m[14] + m[8]*m[6]*m[15]
             - m[8]*m[7]*m[14] - m[12]*m[6]*m[11] + m[12]*m[7]*m[10];
    inv[8]  =  m[4]*m[9]*m[15] - m[4]*m[11]*m[13] - m[8]*m[5]*m[15]
             + m[8]*m[7]*m[13] + m[12]*m[5]*m[11] - m[12]*m[7]*m[9];
    inv[12] = -m[4]*m[9]*m[14] + m[4]*m[10]*m[13] + m[8]*m[5]*m[14]
             - m[8]*m[6]*m[13] - m[12]*m[5]*m[10] + m[12]*m[6]*m[9];
    inv[1]  = -m[1]*m[10]*m[15] + m[1]*m[11]*m[14] + m[9]*m[2]*m[15]
             - m[9]*m[3]*m[14] - m[13]*m[2]*m[11] + m[13]*m[3]*m[10];
    inv[5]  =  m[0]*m[10]*m[15] - m[0]*m[11]*m[14] - m[8]*m[2]*m[15]
             + m[8]*m[3]*m[14] + m[12]*m[2]*m[11] - m[12]*m[3]*m[10];
    inv[9]  = -m[0]*m[9]*m[15] + m[0]*m[11]*m[13] + m[8]*m[1]*m[15]
             - m[8]*m[3]*m[13] - m[12]*m[1]*m[11] + m[12]*m[3]*m[9];
    inv[13] =  m[0]*m[9]*m[14] - m[0]*m[10]*m[13] - m[8]*m[1]*m[14]
             + m[8]*m[2]*m[13] + m[12]*m[1]*m[10] - m[12]*m[2]*m[9];
    inv[2]  =  m[1]*m[6]*m[15] - m[1]*m[7]*m[14] - m[5]*m[2]*m[15]
             + m[5]*m[3]*m[14] + m[13]*m[2]*m[7] - m[13]*m[3]*m[6];
    inv[6]  = -m[0]*m[6]*m[15] + m[0]*m[7]*m[14] + m[4]*m[2]*m[15]
             - m[4]*m[3]*m[14] - m[12]*m[2]*m[7] + m[12]*m[3]*m[6];
    inv[10] =  m[0]*m[5]*m[15] - m[0]*m[7]*m[13] - m[4]*m[1]*m[15]
             + m[4]*m[3]*m[13] + m[12]*m[1]*m[7] - m[12]*m[3]*m[5];
    inv[14] = -m[0]*m[5]*m[14] + m[0]*m[6]*m[13] + m[4]*m[1]*m[14]
             - m[4]*m[2]*m[13] - m[12]*m[1]*m[6] + m[12]*m[2]*m[5];
    inv[3]  = -m[1]*m[6]*m[11] + m[1]*m[7]*m[10] + m[5]*m[2]*m[11]
             - m[5]*m[3]*m[10] - m[9]*m[2]*m[7] + m[9]*m[3]*m[6];
    inv[7]  =  m[0]*m[6]*m[11] - m[0]*m[7]*m[10] - m[4]*m[2]*m[11]
             + m[4]*m[3]*m[10] + m[8]*m[2]*m[7] - m[8]*m[3]*m[6];
    inv[11] = -m[0]*m[5]*m[11] + m[0]*m[7]*m[9] + m[4]*m[1]*m[11]
             - m[4]*m[3]*m[9] - m[8]*m[1]*m[7] + m[8]*m[3]*m[5];
    inv[15] =  m[0]*m[5]*m[10] - m[0]*m[6]*m[9] - m[4]*m[1]*m[10]
             + m[4]*m[2]*m[9] + m[8]*m[1]*m[6] - m[8]*m[2]*m[5];
    float det = m[0]*inv[0] + m[1]*inv[4] + m[2]*inv[8] + m[3]*inv[12];
    if (det == 0.0f) return -1;
    det = 1.0f / det;
    for (int i = 0; i < 16; i++) out[i] = inv[i] * det;
    return 0;
}

static uint32_t find_mem_type(uint32_t bits, VkMemoryPropertyFlags props) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(g_phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & props) == props) return i;
    }
    return UINT32_MAX;
}

static int make_buffer(VkDeviceSize size, VkBufferUsageFlags usage,
                       VkBuffer* buf, VkDeviceMemory* mem, const void* data) {
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = size;
    bci.usage = usage;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VKTRY(vkCreateBuffer(g_device, &bci, NULL, buf), "create buffer");
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(g_device, *buf, &req);
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = find_mem_type(req.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (mai.memoryTypeIndex == UINT32_MAX) FAIL("no host-visible memory type");
    VKTRY(vkAllocateMemory(g_device, &mai, NULL, mem), "allocate buffer memory");
    VKTRY(vkBindBufferMemory(g_device, *buf, *mem, 0), "bind buffer memory");
    if (data) {
        void* dst = NULL;
        VKTRY(vkMapMemory(g_device, *mem, 0, size, 0, &dst), "map buffer");
        memcpy(dst, data, (size_t)size);
        vkUnmapMemory(g_device, *mem);
    }
    return 0;
}

static int make_sampler_set2(VkImageView view, VkSampler smp, VkDescriptorSet* outSet);
static int build_post_targets(void);
static void destroy_post_targets(void);
static void warnless_ultra(void);
static int make_shader(const uint32_t* code, size_t size, VkShaderModule* out);
static int make_entity_set(VkImageView view, VkDescriptorSet* outSet);
static int make_chunk_set(VkImageView view, VkDescriptorSet* outSet);
static int upload_texture(const unsigned char* rgba, int w, int h, int layers,
                          VkImageViewType viewType,
                          VkImage* outImg, VkDeviceMemory* outMem, VkImageView* outView);
static int make_sampler_set(VkImageView view, VkDescriptorSet* outSet);

// ---- swapchain (re)build ----------------------------------------------------
static void destroy_swapchain(void) {
    destroy_post_targets();   // scene + bloom are swapchain-sized
    for (uint32_t i = 0; i < g_imageCount; i++) {
        if (g_fbs[i]) vkDestroyFramebuffer(g_device, g_fbs[i], NULL);
        if (g_views[i]) vkDestroyImageView(g_device, g_views[i], NULL);
        if (g_renderSem[i]) vkDestroySemaphore(g_device, g_renderSem[i], NULL);
        g_fbs[i] = NULL; g_views[i] = NULL; g_renderSem[i] = NULL;
    }
    if (g_swapchain) vkDestroySwapchainKHR(g_device, g_swapchain, NULL);
    g_swapchain = NULL;
    g_imageCount = 0;
    if (g_depthView) vkDestroyImageView(g_device, g_depthView, NULL);
    if (g_depthImage) vkDestroyImage(g_device, g_depthImage, NULL);
    if (g_depthMem) vkFreeMemory(g_device, g_depthMem, NULL);
    g_depthView = NULL; g_depthImage = NULL; g_depthMem = NULL;
}

static int build_depth(void) {
    VkImageCreateInfo ici = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    ici.imageType = VK_IMAGE_TYPE_2D;
    ici.format = VK_FORMAT_D32_SFLOAT;
    ici.extent.width = g_extent.width;
    ici.extent.height = g_extent.height;
    ici.extent.depth = 1;
    ici.mipLevels = 1;
    ici.arrayLayers = 1;
    ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    // SAMPLED as well as an attachment: the ultra pass reads scene depth
    ici.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VKTRY(vkCreateImage(g_device, &ici, NULL, &g_depthImage), "create depth image");
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(g_device, g_depthImage, &req);
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = find_mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mai.memoryTypeIndex == UINT32_MAX) FAIL("no device-local memory for depth");
    VKTRY(vkAllocateMemory(g_device, &mai, NULL, &g_depthMem), "allocate depth memory");
    VKTRY(vkBindImageMemory(g_device, g_depthImage, g_depthMem, 0), "bind depth memory");
    VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    vci.image = g_depthImage;
    vci.viewType = VK_IMAGE_VIEW_TYPE_2D;
    vci.format = VK_FORMAT_D32_SFLOAT;
    vci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    vci.subresourceRange.levelCount = 1;
    vci.subresourceRange.layerCount = 1;
    VKTRY(vkCreateImageView(g_device, &vci, NULL, &g_depthView), "create depth view");
    return 0;
}

static int build_swapchain(int width, int height) {
    VkSurfaceCapabilitiesKHR caps;
    VKTRY(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(g_phys, g_surface, &caps),
          "surface capabilities");

    g_extent = caps.currentExtent;
    if (g_extent.width == 0xFFFFFFFF) {   // surface lets us choose
        g_extent.width = (uint32_t)width;
        g_extent.height = (uint32_t)height;
    }
    if (g_extent.width == 0 || g_extent.height == 0) return 1;   // minimized

    uint32_t want = caps.minImageCount + 1;
    if (caps.maxImageCount && want > caps.maxImageCount) want = caps.maxImageCount;
    if (want > MAX_SWAP_IMAGES) want = MAX_SWAP_IMAGES;

    VkSwapchainCreateInfoKHR sci = { VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR };
    sci.surface = g_surface;
    sci.minImageCount = want;
    sci.imageFormat = g_format;
    sci.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    sci.imageExtent = g_extent;
    sci.imageArrayLayers = 1;
    sci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    sci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    sci.preTransform = caps.currentTransform;
    sci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    sci.presentMode = VK_PRESENT_MODE_FIFO_KHR;   // vsync, always available
    sci.clipped = VK_TRUE;
    VKTRY(vkCreateSwapchainKHR(g_device, &sci, NULL, &g_swapchain), "create swapchain");

    VKTRY(vkGetSwapchainImagesKHR(g_device, g_swapchain, &g_imageCount, NULL), "count swap images");
    if (g_imageCount > MAX_SWAP_IMAGES) g_imageCount = MAX_SWAP_IMAGES;
    VKTRY(vkGetSwapchainImagesKHR(g_device, g_swapchain, &g_imageCount, g_images), "get swap images");

    if (build_depth() != 0) return -1;

    for (uint32_t i = 0; i < g_imageCount; i++) {
        VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
        vci.image = g_images[i];
        vci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        vci.format = g_format;
        vci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        vci.subresourceRange.levelCount = 1;
        vci.subresourceRange.layerCount = 1;
        VKTRY(vkCreateImageView(g_device, &vci, NULL, &g_views[i]), "create image view");

        VkImageView atts[2] = { g_views[i], g_depthView };
        VkFramebufferCreateInfo fci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        fci.renderPass = g_pass;
        fci.attachmentCount = 2;
        fci.pAttachments = atts;
        fci.width = g_extent.width;
        fci.height = g_extent.height;
        fci.layers = 1;
        VKTRY(vkCreateFramebuffer(g_device, &fci, NULL, &g_fbs[i]), "create framebuffer");

        VkSemaphoreCreateInfo semci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        VKTRY(vkCreateSemaphore(g_device, &semci, NULL, &g_renderSem[i]), "create semaphore");
    }
    // the post chain is best-effort: without it the frame draws straight
    // into the swapchain, exactly as it did before this slice
    if (build_post_targets() != 0) {
        destroy_post_targets();
        g_err[0] = 0;
    }
    return 0;
}

// ---- post-processing targets ----------------------------------------------
// Rebuilt with the swapchain: they are all swapchain-sized (the bloom pair
// at half). Any failure leaves g_postOK at 0 and the frame takes the old
// direct-to-swapchain path.

static void destroy_post_targets(void) {
    if (!g_device) return;
    if (g_sceneFb) vkDestroyFramebuffer(g_device, g_sceneFb, NULL);
    if (g_sceneView) vkDestroyImageView(g_device, g_sceneView, NULL);
    if (g_sceneImage) vkDestroyImage(g_device, g_sceneImage, NULL);
    if (g_sceneMem) vkFreeMemory(g_device, g_sceneMem, NULL);
    g_sceneFb = NULL;
    g_sceneView = NULL;
    g_sceneImage = NULL;
    g_sceneMem = NULL;
    for (int i = 0; i < 2; i++) {
        if (g_ultraFb[i]) vkDestroyFramebuffer(g_device, g_ultraFb[i], NULL);
        if (g_ultraView[i]) vkDestroyImageView(g_device, g_ultraView[i], NULL);
        if (g_ultraImg[i]) vkDestroyImage(g_device, g_ultraImg[i], NULL);
        if (g_ultraMem[i]) vkFreeMemory(g_device, g_ultraMem[i], NULL);
        g_ultraFb[i] = NULL;
        g_ultraView[i] = NULL;
        g_ultraImg[i] = NULL;
        g_ultraMem[i] = NULL;
        if (g_bloomFb[i]) vkDestroyFramebuffer(g_device, g_bloomFb[i], NULL);
        if (g_bloomView[i]) vkDestroyImageView(g_device, g_bloomView[i], NULL);
        if (g_bloomImg[i]) vkDestroyImage(g_device, g_bloomImg[i], NULL);
        if (g_bloomMem[i]) vkFreeMemory(g_device, g_bloomMem[i], NULL);
        g_bloomFb[i] = NULL;
        g_bloomView[i] = NULL;
        g_bloomImg[i] = NULL;
        g_bloomMem[i] = NULL;
    }
    g_postOK = 0;
}

/// one sampled colour attachment
static int make_target(uint32_t w, uint32_t h, VkImage* img, VkDeviceMemory* mem,
                       VkImageView* view) {
    VkImageCreateInfo ici = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    ici.imageType = VK_IMAGE_TYPE_2D;
    ici.format = g_format;
    ici.extent.width = w;
    ici.extent.height = h;
    ici.extent.depth = 1;
    ici.mipLevels = 1;
    ici.arrayLayers = 1;
    ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (vkCreateImage(g_device, &ici, NULL, img) != VK_SUCCESS) return -1;
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(g_device, *img, &req);
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = find_mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mai.memoryTypeIndex == UINT32_MAX) return -1;
    if (vkAllocateMemory(g_device, &mai, NULL, mem) != VK_SUCCESS) return -1;
    if (vkBindImageMemory(g_device, *img, *mem, 0) != VK_SUCCESS) return -1;
    VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    vci.image = *img;
    vci.viewType = VK_IMAGE_VIEW_TYPE_2D;
    vci.format = g_format;
    vci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    vci.subresourceRange.levelCount = 1;
    vci.subresourceRange.layerCount = 1;
    if (vkCreateImageView(g_device, &vci, NULL, view) != VK_SUCCESS) return -1;
    return 0;
}

/// ultra could not be built — say so once, in the GPU string the logs print
static void warnless_ultra(void) {
    size_t n = strlen(g_gpu);
    if (n && n < sizeof g_gpu - 16) snprintf(g_gpu + n, sizeof g_gpu - n, " [no ultra]");
}

static int build_post_targets(void) {
    destroy_post_targets();
    if (!g_scenePass || !g_bloomPass || !g_pipeComposite) return -1;
    if (make_target(g_extent.width, g_extent.height, &g_sceneImage, &g_sceneMem, &g_sceneView) != 0)
        return -1;
    VkImageView att[2] = { g_sceneView, g_depthView };
    VkFramebufferCreateInfo fci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
    fci.renderPass = g_scenePass;
    fci.attachmentCount = 2;
    fci.pAttachments = att;
    fci.width = g_extent.width;
    fci.height = g_extent.height;
    fci.layers = 1;
    if (vkCreateFramebuffer(g_device, &fci, NULL, &g_sceneFb) != VK_SUCCESS) return -1;

    g_ultraExtent.width = g_extent.width / 2 ? g_extent.width / 2 : 1;
    g_ultraExtent.height = g_extent.height / 2 ? g_extent.height / 2 : 1;
    g_bloomExtent.width = g_extent.width / 2 ? g_extent.width / 2 : 1;
    g_bloomExtent.height = g_extent.height / 2 ? g_extent.height / 2 : 1;
    for (int i = 0; i < 2; i++) {
        if (make_target(g_bloomExtent.width, g_bloomExtent.height,
                        &g_bloomImg[i], &g_bloomMem[i], &g_bloomView[i]) != 0) return -1;
        VkFramebufferCreateInfo bfci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        bfci.renderPass = g_bloomPass;
        bfci.attachmentCount = 1;
        bfci.pAttachments = &g_bloomView[i];
        bfci.width = g_bloomExtent.width;
        bfci.height = g_bloomExtent.height;
        bfci.layers = 1;
        if (vkCreateFramebuffer(g_device, &bfci, NULL, &g_bloomFb[i]) != VK_SUCCESS) return -1;
    }

    // the ultra pair, same half resolution
    if (g_ultraOK) {
        for (int i = 0; i < 2; i++) {
            if (make_target(g_ultraExtent.width, g_ultraExtent.height,
                            &g_ultraImg[i], &g_ultraMem[i], &g_ultraView[i]) != 0) {
                g_ultraOK = 0;
                break;
            }
            VkFramebufferCreateInfo ufci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
            ufci.renderPass = g_bloomPass;
            ufci.attachmentCount = 1;
            ufci.pAttachments = &g_ultraView[i];
            ufci.width = g_ultraExtent.width;
            ufci.height = g_ultraExtent.height;
            ufci.layers = 1;
            if (vkCreateFramebuffer(g_device, &ufci, NULL, &g_ultraFb[i]) != VK_SUCCESS) {
                g_ultraOK = 0;
                break;
            }
        }
    }

    // the sampler sets point at views that just changed, so rewrite them
    // rather than reallocating (the pool has no free list)
    VkDescriptorImageInfo dii[6] = {
        { g_linearSampler, g_sceneView, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        { g_linearSampler, g_bloomView[0], VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        { g_linearSampler, g_bloomView[1], VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        { g_linearSampler, g_ultraOK ? g_ultraView[0] : g_sceneView, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        { g_linearSampler, g_ultraOK ? g_ultraView[1] : g_sceneView, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        { g_depthSampler, g_depthView, VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL },
    };
    VkDescriptorSet sets[6] = { g_sceneSet, g_bloomSet[0], g_bloomSet[1],
                                g_ultraSet[0], g_ultraSet[1], g_depthSet };
    VkWriteDescriptorSet wds[6];
    for (int i = 0; i < 6; i++) {
        VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
        w.dstSet = sets[i];
        w.dstBinding = 0;
        w.descriptorCount = 1;
        w.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        w.pImageInfo = &dii[i];
        wds[i] = w;
    }
    vkUpdateDescriptorSets(g_device, 6, wds, 0, NULL);
    g_postOK = 1;
    return 0;
}

// ---- public API ----------------------------------------------------------------
int pb_vk_create(void* hwnd, void* hinstance, int width, int height) {
    g_err[0] = 0;
    g_lib = LoadLibraryA("vulkan-1.dll");
    if (!g_lib)
        FAIL("vulkan-1.dll not found — GPU drivers too old or missing Vulkan support");
    ipa = (PFN_vkGetInstanceProcAddr)(void*)GetProcAddress(g_lib, "vkGetInstanceProcAddr");
    if (!ipa) FAIL("vkGetInstanceProcAddr missing from vulkan-1.dll");

    vkCreateInstance = (PFN_vkCreateInstance)ipa(NULL, "vkCreateInstance");
    if (!vkCreateInstance) FAIL("vkCreateInstance unavailable");

    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "Pebble";
    app.apiVersion = VK_MAKE_API_VERSION(0, 1, 0, 0);
    const char* exts[] = { "VK_KHR_surface", "VK_KHR_win32_surface" };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = 2;
    ici.ppEnabledExtensionNames = exts;
    VKTRY(vkCreateInstance(&ici, NULL, &g_instance), "create Vulkan instance");

#define LOAD_I(n) do { n = (PFN_##n)ipa(g_instance, #n); if (!n) FAIL("missing " #n); } while (0)
    LOAD_I(vkEnumeratePhysicalDevices);
    LOAD_I(vkGetPhysicalDeviceProperties);
    LOAD_I(vkGetPhysicalDeviceQueueFamilyProperties);
    LOAD_I(vkCreateWin32SurfaceKHR);
    LOAD_I(vkGetPhysicalDeviceSurfaceSupportKHR);
    LOAD_I(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
    LOAD_I(vkGetPhysicalDeviceSurfaceFormatsKHR);
    LOAD_I(vkCreateDevice);
    LOAD_I(vkDestroySurfaceKHR);
    LOAD_I(vkDestroyInstance);
    dpa = (PFN_vkGetDeviceProcAddr)ipa(g_instance, "vkGetDeviceProcAddr");
    if (!dpa) FAIL("missing vkGetDeviceProcAddr");

    VkWin32SurfaceCreateInfoKHR wci = { VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR };
    wci.hinstance = (HINSTANCE)hinstance;
    wci.hwnd = (HWND)hwnd;
    VKTRY(vkCreateWin32SurfaceKHR(g_instance, &wci, NULL, &g_surface), "create window surface");

    // pick the first physical device with a graphics+present queue
    uint32_t devCount = 0;
    VKTRY(vkEnumeratePhysicalDevices(g_instance, &devCount, NULL), "enumerate GPUs");
    if (devCount == 0) FAIL("no Vulkan-capable GPU found");
    VkPhysicalDevice devs[16];
    if (devCount > 16) devCount = 16;
    VKTRY(vkEnumeratePhysicalDevices(g_instance, &devCount, devs), "list GPUs");

    for (uint32_t d = 0; d < devCount && !g_device; d++) {
        uint32_t qCount = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devs[d], &qCount, NULL);
        VkQueueFamilyProperties qs[32];
        if (qCount > 32) qCount = 32;
        vkGetPhysicalDeviceQueueFamilyProperties(devs[d], &qCount, qs);
        for (uint32_t q = 0; q < qCount; q++) {
            VkBool32 present = VK_FALSE;
            vkGetPhysicalDeviceSurfaceSupportKHR(devs[d], q, g_surface, &present);
            if ((qs[q].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
                float prio = 1.0f;
                VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
                qci.queueFamilyIndex = q;
                qci.queueCount = 1;
                qci.pQueuePriorities = &prio;
                const char* devExts[] = { "VK_KHR_swapchain" };
                VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
                dci.queueCreateInfoCount = 1;
                dci.pQueueCreateInfos = &qci;
                dci.enabledExtensionCount = 1;
                dci.ppEnabledExtensionNames = devExts;
                if (vkCreateDevice(devs[d], &dci, NULL, &g_device) == VK_SUCCESS) {
                    g_phys = devs[d];
                    g_queueFamily = q;
                    VkPhysicalDeviceProperties props;
                    vkGetPhysicalDeviceProperties(g_phys, &props);
                    snprintf(g_gpu, sizeof g_gpu, "%s (maxTex %u, maxLayers %u, push %u)",
                             props.deviceName,
                             props.limits.maxImageDimension2D,
                             props.limits.maxImageArrayLayers,
                             props.limits.maxPushConstantsSize);
                    // the part-matrix ring is indexed with dynamic offsets,
                    // which must be multiples of this
                    VkDeviceSize a = props.limits.minUniformBufferOffsetAlignment;
                    if (a < 1) a = 1;
                    g_partsStride = ((ENTITY_PARTS_BYTES + a - 1) / a) * a;
                }
                break;
            }
        }
    }
    if (!g_device) FAIL("no GPU queue can draw AND present to this window");

#define LOAD_D(n) do { n = (PFN_##n)dpa(g_device, #n); if (!n) FAIL("missing " #n); } while (0)
    LOAD_D(vkGetDeviceQueue);
    LOAD_D(vkCreateSwapchainKHR);
    LOAD_D(vkDestroySwapchainKHR);
    LOAD_D(vkGetSwapchainImagesKHR);
    LOAD_D(vkCreateImageView);
    LOAD_D(vkDestroyImageView);
    LOAD_D(vkCreateRenderPass);
    LOAD_D(vkDestroyRenderPass);
    LOAD_D(vkCreateFramebuffer);
    LOAD_D(vkDestroyFramebuffer);
    LOAD_D(vkCreateCommandPool);
    LOAD_D(vkDestroyCommandPool);
    LOAD_D(vkAllocateCommandBuffers);
    LOAD_D(vkBeginCommandBuffer);
    LOAD_D(vkCmdBeginRenderPass);
    LOAD_D(vkCmdEndRenderPass);
    LOAD_D(vkEndCommandBuffer);
    LOAD_D(vkCreateSemaphore);
    LOAD_D(vkDestroySemaphore);
    LOAD_D(vkCreateFence);
    LOAD_D(vkDestroyFence);
    LOAD_D(vkWaitForFences);
    LOAD_D(vkResetFences);
    LOAD_D(vkAcquireNextImageKHR);
    LOAD_D(vkQueueSubmit);
    LOAD_D(vkQueuePresentKHR);
    LOAD_D(vkDeviceWaitIdle);
    LOAD_D(vkDestroyDevice);
    LOAD_D(vkResetCommandBuffer);
    LOAD_D(vkCreateBuffer);
    LOAD_D(vkDestroyBuffer);
    LOAD_D(vkGetBufferMemoryRequirements);
    LOAD_D(vkBindBufferMemory);
    LOAD_D(vkAllocateMemory);
    LOAD_D(vkFreeMemory);
    LOAD_D(vkMapMemory);
    LOAD_D(vkUnmapMemory);
    LOAD_D(vkCreateImage);
    LOAD_D(vkDestroyImage);
    LOAD_D(vkGetImageMemoryRequirements);
    LOAD_D(vkBindImageMemory);
    LOAD_D(vkCreateShaderModule);
    LOAD_D(vkDestroyShaderModule);
    LOAD_D(vkCreatePipelineLayout);
    LOAD_D(vkDestroyPipelineLayout);
    LOAD_D(vkCreateGraphicsPipelines);
    LOAD_D(vkDestroyPipeline);
    LOAD_D(vkCreateDescriptorSetLayout);
    LOAD_D(vkDestroyDescriptorSetLayout);
    LOAD_D(vkCreateDescriptorPool);
    LOAD_D(vkDestroyDescriptorPool);
    LOAD_D(vkAllocateDescriptorSets);
    LOAD_D(vkUpdateDescriptorSets);
    LOAD_D(vkCreateSampler);
    LOAD_D(vkDestroySampler);
    LOAD_D(vkCmdBindPipeline);
    LOAD_D(vkCmdBindVertexBuffers);
    LOAD_D(vkCmdBindIndexBuffer);
    LOAD_D(vkCmdBindDescriptorSets);
    LOAD_D(vkCmdPushConstants);
    LOAD_D(vkCmdDrawIndexed);
    LOAD_D(vkCmdDraw);
    LOAD_D(vkCmdSetViewport);
    LOAD_D(vkCmdSetScissor);
    LOAD_D(vkCmdPipelineBarrier);
    LOAD_D(vkCmdCopyBufferToImage);
    LOAD_D(vkQueueWaitIdle);
    vkGetPhysicalDeviceMemoryProperties =
        (PFN_vkGetPhysicalDeviceMemoryProperties)ipa(g_instance, "vkGetPhysicalDeviceMemoryProperties");
    if (!vkGetPhysicalDeviceMemoryProperties) FAIL("missing vkGetPhysicalDeviceMemoryProperties");

    vkGetDeviceQueue(g_device, g_queueFamily, 0, &g_queue);

    // surface format: prefer BGRA8 UNORM (matches the Metal path's bgra8)
    uint32_t fmtCount = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(g_phys, g_surface, &fmtCount, NULL);
    VkSurfaceFormatKHR fmts[64];
    if (fmtCount > 64) fmtCount = 64;
    vkGetPhysicalDeviceSurfaceFormatsKHR(g_phys, g_surface, &fmtCount, fmts);
    g_format = fmts[0].format;
    if (g_format == VK_FORMAT_UNDEFINED) g_format = VK_FORMAT_B8G8R8A8_UNORM;
    for (uint32_t i = 0; i < fmtCount; i++) {
        if (fmts[i].format == VK_FORMAT_B8G8R8A8_UNORM) { g_format = fmts[i].format; break; }
    }

    VkAttachmentDescription atts[2] = { { 0 }, { 0 } };
    atts[0].format = g_format;
    atts[0].samples = VK_SAMPLE_COUNT_1_BIT;
    atts[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    atts[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    atts[0].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    atts[0].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    atts[0].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    atts[0].finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    atts[1].format = VK_FORMAT_D32_SFLOAT;
    atts[1].samples = VK_SAMPLE_COUNT_1_BIT;
    atts[1].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    atts[1].storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    atts[1].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    atts[1].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    atts[1].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    atts[1].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkAttachmentReference dref = { 1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sub = { 0 };
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments = &ref;
    sub.pDepthStencilAttachment = &dref;
    VkSubpassDependency dep = { 0 };
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
        | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
        | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
        | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rpci.attachmentCount = 2;
    rpci.pAttachments = atts;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &sub;
    rpci.dependencyCount = 1;
    rpci.pDependencies = &dep;
    VKTRY(vkCreateRenderPass(g_device, &rpci, NULL, &g_pass), "create render pass");

    VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pci.queueFamilyIndex = g_queueFamily;
    VKTRY(vkCreateCommandPool(g_device, &pci, NULL, &g_pool), "create command pool");

    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cai.commandPool = g_pool;
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = FRAMES_IN_FLIGHT;
    VKTRY(vkAllocateCommandBuffers(g_device, &cai, g_cmd), "allocate command buffers");

    for (int i = 0; i < FRAMES_IN_FLIGHT; i++) {
        VkSemaphoreCreateInfo semci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        VKTRY(vkCreateSemaphore(g_device, &semci, NULL, &g_acquireSem[i]), "create semaphore");
        VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        fci.flags = VK_FENCE_CREATE_SIGNALED_BIT;
        VKTRY(vkCreateFence(g_device, &fci, NULL, &g_fence[i]), "create fence");
    }

    // the plain one-sampler layout every simple pass uses (UI, sprites,
    // clouds, celestials, particles, the post chain)
    VkDescriptorSetLayoutBinding bind = { 0 };
    bind.binding = 0;
    bind.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bind.descriptorCount = 1;
    bind.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo dsli = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    dsli.bindingCount = 1;
    dsli.pBindings = &bind;
    VKTRY(vkCreateDescriptorSetLayout(g_device, &dsli, NULL, &g_setLayout), "create set layout");

    // chunks additionally carry the shadow map and the sun's matrix; the
    // shared layout above cannot grow those without breaking every pass that
    // uses it, so terrain gets its own
    VkDescriptorSetLayoutBinding cbinds[3] = { { 0 }, { 0 }, { 0 } };
    cbinds[0].binding = 0;
    cbinds[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    cbinds[0].descriptorCount = 1;
    cbinds[0].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    cbinds[1].binding = 1;
    cbinds[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    cbinds[1].descriptorCount = 1;
    cbinds[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    cbinds[2].binding = 2;
    cbinds[2].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
    cbinds[2].descriptorCount = 1;
    cbinds[2].stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo cdsli = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    cdsli.bindingCount = 3;
    cdsli.pBindings = cbinds;
    VKTRY(vkCreateDescriptorSetLayout(g_device, &cdsli, NULL, &g_chunkSetLayout),
          "create chunk set layout");

    // a lone dynamic uniform, for the ultra block
    VkDescriptorSetLayoutBinding uboBind = { 0 };
    uboBind.binding = 0;
    uboBind.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
    uboBind.descriptorCount = 1;
    uboBind.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo udsli = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    udsli.bindingCount = 1;
    udsli.pBindings = &uboBind;
    VKTRY(vkCreateDescriptorSetLayout(g_device, &udsli, NULL, &g_uboSetLayout),
          "create ubo set layout");

    VkPushConstantRange pcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(PbPush) };
    VkPipelineLayoutCreateInfo pli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &g_chunkSetLayout;
    pli.pushConstantRangeCount = 1;
    pli.pPushConstantRanges = &pcr;
    VKTRY(vkCreatePipelineLayout(g_device, &pli, NULL, &g_pipeLayout), "create pipeline layout");

    VkShaderModuleCreateInfo smv = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    smv.codeSize = g_chunk_vert_spv_size;
    smv.pCode = g_chunk_vert_spv;
    VkShaderModule vs;
    VKTRY(vkCreateShaderModule(g_device, &smv, NULL, &vs), "create vertex shader");
    VkShaderModuleCreateInfo smf = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    smf.codeSize = g_chunk_frag_spv_size;
    smf.pCode = g_chunk_frag_spv;
    VkShaderModule fs;
    VKTRY(vkCreateShaderModule(g_device, &smf, NULL, &fs), "create fragment shader");

    VkPipelineShaderStageCreateInfo stages[2] = {
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO },
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO },
    };
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vs;
    stages[0].pName = "main";
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fs;
    stages[1].pName = "main";

    // the frozen 28-byte chunk stream (docs/render-abi.md)
    VkVertexInputBindingDescription vbind = { 0, 28, VK_VERTEX_INPUT_RATE_VERTEX };
    VkVertexInputAttributeDescription vattrs[4] = {
        { 0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0 },
        { 1, 0, VK_FORMAT_R32G32_SFLOAT, 12 },
        { 2, 0, VK_FORMAT_R32_UINT, 20 },
        { 3, 0, VK_FORMAT_R32_UINT, 24 },
    };
    VkPipelineVertexInputStateCreateInfo vin = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    vin.vertexBindingDescriptionCount = 1;
    vin.pVertexBindingDescriptions = &vbind;
    vin.vertexAttributeDescriptionCount = 4;
    vin.pVertexAttributeDescriptions = vattrs;

    VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo vp = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
    vp.viewportCount = 1;
    vp.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode = VK_CULL_MODE_NONE;   // Y-flip flips winding; skip culling for now
    rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rs.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineDepthStencilStateCreateInfo ds = { VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO };
    ds.depthTestEnable = VK_TRUE;
    ds.depthWriteEnable = VK_TRUE;
    ds.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
    VkPipelineColorBlendAttachmentState cba = { 0 };
    cba.colorWriteMask = 0xF;
    VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
    cb.attachmentCount = 1;
    cb.pAttachments = &cba;
    VkDynamicState dyns[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dyn = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO };
    dyn.dynamicStateCount = 2;
    dyn.pDynamicStates = dyns;

    VkGraphicsPipelineCreateInfo gpi = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    gpi.stageCount = 2;
    gpi.pStages = stages;
    gpi.pVertexInputState = &vin;
    gpi.pInputAssemblyState = &ia;
    gpi.pViewportState = &vp;
    gpi.pRasterizationState = &rs;
    gpi.pMultisampleState = &ms;
    gpi.pDepthStencilState = &ds;
    gpi.pColorBlendState = &cb;
    gpi.pDynamicState = &dyn;
    gpi.layout = g_pipeLayout;
    gpi.renderPass = g_pass;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeOpaque),
          "create opaque pipeline");

    // translucent: alpha blend, depth test but no write
    cba.blendEnable = VK_TRUE;
    cba.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    cba.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    cba.colorBlendOp = VK_BLEND_OP_ADD;
    cba.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    cba.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    cba.alphaBlendOp = VK_BLEND_OP_ADD;
    ds.depthWriteEnable = VK_FALSE;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeTranslucent),
          "create translucent pipeline");
    vkDestroyShaderModule(g_device, vs, NULL);
    vkDestroyShaderModule(g_device, fs, NULL);

    // shared sampler + descriptor pool (terrain atlas + up to 159 skins)
    VkSamplerCreateInfo sci = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
    sci.magFilter = VK_FILTER_NEAREST;
    sci.minFilter = VK_FILTER_NEAREST;
    sci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    sci.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;   // fluid UVs scroll past 1
    sci.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sci.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    VKTRY(vkCreateSampler(g_device, &sci, NULL, &g_atlasSampler), "create sampler");
    sci.magFilter = VK_FILTER_LINEAR;
    sci.minFilter = VK_FILTER_LINEAR;
    sci.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sci.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sci.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    VKTRY(vkCreateSampler(g_device, &sci, NULL, &g_linearSampler), "create linear sampler");
    sci.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;   // the cloud plane samples past uv 1
    sci.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sci.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    VKTRY(vkCreateSampler(g_device, &sci, NULL, &g_cloudSampler), "create cloud sampler");
    // +SKY_TEX_COUNT for the sun/moon/cloud art, +1 for the 1x1 stand-in
    VkDescriptorPoolSize pools[2];
    pools[0].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    pools[0].descriptorCount = MAX_ENTITY_GEOMS + MAX_UI_IMAGES + SKY_TEX_COUNT + 12;
    pools[1].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
    pools[1].descriptorCount = MAX_ENTITY_GEOMS + 4;   // entity + terrain + ultra
    VkDescriptorPoolCreateInfo dpi = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    dpi.maxSets = MAX_ENTITY_GEOMS + MAX_UI_IMAGES + SKY_TEX_COUNT + 12;
    dpi.poolSizeCount = 2;
    dpi.pPoolSizes = pools;
    VKTRY(vkCreateDescriptorPool(g_device, &dpi, NULL, &g_descPool), "create descriptor pool");

    // entity pipeline: 36-byte ABI stream, blended, depth-tested
    // ---- the shadow map: a depth-only target and the pass that fills it ----
    {
        VkImageCreateInfo sici = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
        sici.imageType = VK_IMAGE_TYPE_2D;
        sici.format = VK_FORMAT_D32_SFLOAT;
        sici.extent.width = SHADOW_SIZE;
        sici.extent.height = SHADOW_SIZE;
        sici.extent.depth = 1;
        sici.mipLevels = 1;
        sici.arrayLayers = 1;
        sici.samples = VK_SAMPLE_COUNT_1_BIT;
        sici.tiling = VK_IMAGE_TILING_OPTIMAL;
        sici.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        sici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        VKTRY(vkCreateImage(g_device, &sici, NULL, &g_shadowImage), "create shadow map");
        VkMemoryRequirements sreq;
        vkGetImageMemoryRequirements(g_device, g_shadowImage, &sreq);
        VkMemoryAllocateInfo smai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
        smai.allocationSize = sreq.size;
        smai.memoryTypeIndex = find_mem_type(sreq.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (smai.memoryTypeIndex == UINT32_MAX) FAIL("no memory for the shadow map");
        VKTRY(vkAllocateMemory(g_device, &smai, NULL, &g_shadowMem), "allocate shadow memory");
        VKTRY(vkBindImageMemory(g_device, g_shadowImage, g_shadowMem, 0), "bind shadow memory");
        VkImageViewCreateInfo svci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
        svci.image = g_shadowImage;
        svci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        svci.format = VK_FORMAT_D32_SFLOAT;
        svci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
        svci.subresourceRange.levelCount = 1;
        svci.subresourceRange.layerCount = 1;
        VKTRY(vkCreateImageView(g_device, &svci, NULL, &g_shadowView), "create shadow view");

        // compare-mode sampler: one fetch already returns a filtered 0..1
        // occlusion term, the way MSL's sample_compare does
        VkSamplerCreateInfo ssci = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
        ssci.magFilter = VK_FILTER_LINEAR;
        ssci.minFilter = VK_FILTER_LINEAR;
        ssci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
        ssci.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        ssci.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        ssci.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        ssci.compareEnable = VK_TRUE;
        ssci.compareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
        VKTRY(vkCreateSampler(g_device, &ssci, NULL, &g_shadowSampler), "create shadow sampler");
        ssci.compareEnable = VK_FALSE;   // the ultra pass reads raw depth too
        ssci.magFilter = VK_FILTER_NEAREST;
        ssci.minFilter = VK_FILTER_NEAREST;
        VKTRY(vkCreateSampler(g_device, &ssci, NULL, &g_depthSampler), "create depth sampler");

        VkAttachmentDescription satt = { 0 };
        satt.format = VK_FORMAT_D32_SFLOAT;
        satt.samples = VK_SAMPLE_COUNT_1_BIT;
        satt.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        satt.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        satt.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        satt.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        satt.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        satt.finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
        VkAttachmentReference sdref = { 0, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
        VkSubpassDescription ssub = { 0 };
        ssub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        ssub.pDepthStencilAttachment = &sdref;
        VkSubpassDependency sdeps[2] = { { 0 }, { 0 } };
        sdeps[0].srcSubpass = VK_SUBPASS_EXTERNAL;
        sdeps[0].dstSubpass = 0;
        sdeps[0].srcStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        sdeps[0].srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
        sdeps[0].dstStageMask = VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        sdeps[0].dstAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        sdeps[1].srcSubpass = 0;
        sdeps[1].dstSubpass = VK_SUBPASS_EXTERNAL;
        sdeps[1].srcStageMask = VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        sdeps[1].srcAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        sdeps[1].dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        sdeps[1].dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        VkRenderPassCreateInfo srci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
        srci.attachmentCount = 1;
        srci.pAttachments = &satt;
        srci.subpassCount = 1;
        srci.pSubpasses = &ssub;
        srci.dependencyCount = 2;
        srci.pDependencies = sdeps;
        VKTRY(vkCreateRenderPass(g_device, &srci, NULL, &g_shadowPass), "create shadow pass");

        VkFramebufferCreateInfo sfci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        sfci.renderPass = g_shadowPass;
        sfci.attachmentCount = 1;
        sfci.pAttachments = &g_shadowView;
        sfci.width = SHADOW_SIZE;
        sfci.height = SHADOW_SIZE;
        sfci.layers = 1;
        VKTRY(vkCreateFramebuffer(g_device, &sfci, NULL, &g_shadowFb), "create shadow framebuffer");

        // the sun's matrix: one slot per frame in flight, dynamically offset
        // 256 is the largest minUniformBufferOffsetAlignment Vulkan permits
        // and every legal value divides it, so this offset is always valid
        g_shadowUboStride = 256;
        if (make_buffer(g_shadowUboStride * FRAMES_IN_FLIGHT, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                        &g_shadowUbo, &g_shadowUboMem, NULL) != 0) return -1;
        VKTRY(vkMapMemory(g_device, g_shadowUboMem, 0, g_shadowUboStride * FRAMES_IN_FLIGHT, 0,
                          &g_shadowUboMap), "map shadow uniform buffer");
        memset(g_shadowUboMap, 0, (size_t)(g_shadowUboStride * FRAMES_IN_FLIGHT));

        // the depth-only pipeline over the chunk stream
        VkPushConstantRange shpcr = { VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(PbShadowPush) };
        VkPipelineLayoutCreateInfo shpli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
        shpli.pushConstantRangeCount = 1;
        shpli.pPushConstantRanges = &shpcr;
        VKTRY(vkCreatePipelineLayout(g_device, &shpli, NULL, &g_shadowLayout), "create shadow layout");
        VkShaderModule shvs;
        if (make_shader(g_shadow_vert_spv, g_shadow_vert_spv_size, &shvs) != 0) return -1;
        VkPipelineShaderStageCreateInfo shstage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO };
        shstage.stage = VK_SHADER_STAGE_VERTEX_BIT;
        shstage.module = shvs;
        shstage.pName = "main";
        VkGraphicsPipelineCreateInfo shgpi = gpi;   // the chunk vertex layout
        shgpi.stageCount = 1;                       // depth only: no fragment stage
        shgpi.pStages = &shstage;
        VkPipelineColorBlendStateCreateInfo shcb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
        shcb.attachmentCount = 0;
        shgpi.pColorBlendState = &shcb;
        VkPipelineDepthStencilStateCreateInfo shds = { VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO };
        shds.depthTestEnable = VK_TRUE;
        shds.depthWriteEnable = VK_TRUE;
        shds.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
        shgpi.pDepthStencilState = &shds;
        shgpi.layout = g_shadowLayout;
        shgpi.renderPass = g_shadowPass;
        VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &shgpi, NULL, &g_pipeShadow),
              "create shadow pipeline");
        vkDestroyShaderModule(g_device, shvs, NULL);
    }

    // entities need a second binding for their part matrices; the shared
    // g_setLayout cannot grow one without breaking every other pipeline
    VkDescriptorSetLayoutBinding ebinds[2] = { { 0 }, { 0 } };
    ebinds[0].binding = 0;
    ebinds[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    ebinds[0].descriptorCount = 1;
    ebinds[0].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    ebinds[1].binding = 1;
    ebinds[1].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
    ebinds[1].descriptorCount = 1;
    ebinds[1].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    VkDescriptorSetLayoutCreateInfo edsli = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    edsli.bindingCount = 2;
    edsli.pBindings = ebinds;
    VKTRY(vkCreateDescriptorSetLayout(g_device, &edsli, NULL, &g_entSetLayout),
          "create entity set layout");

    // the part-matrix ring: FRAMES_IN_FLIGHT regions of PARTS_SLOTS_PER_FRAME
    {
        VkDeviceSize size = g_partsStride * PARTS_SLOTS_PER_FRAME * FRAMES_IN_FLIGHT;
        if (make_buffer(size, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                        &g_partsBuf, &g_partsMem, NULL) != 0) return -1;
        VKTRY(vkMapMemory(g_device, g_partsMem, 0, size, 0, &g_partsMap),
              "map part-matrix buffer");
        // identity everywhere to start: an un-posed draw is a bind pose, not
        // a screenful of NaN triangles
        for (VkDeviceSize o = 0; o < size; o += g_partsStride) {
            float* mats = (float*)((char*)g_partsMap + o);
            for (int k = 0; k < ENTITY_PARTS; k++) {
                for (int e = 0; e < 16; e++) mats[k * 16 + e] = (e % 5 == 0) ? 1.0f : 0.0f;
            }
        }
    }

    VkPushConstantRange epcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                                 0, sizeof(PbEntityPush) };
    VkPipelineLayoutCreateInfo epli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    epli.setLayoutCount = 1;
    epli.pSetLayouts = &g_entSetLayout;
    epli.pushConstantRangeCount = 1;
    epli.pPushConstantRanges = &epcr;
    VKTRY(vkCreatePipelineLayout(g_device, &epli, NULL, &g_entLayout), "create entity layout");
    VkShaderModuleCreateInfo esv = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    esv.codeSize = g_entity_vert_spv_size;
    esv.pCode = g_entity_vert_spv;
    VkShaderModule evs;
    VKTRY(vkCreateShaderModule(g_device, &esv, NULL, &evs), "create entity vs");
    VkShaderModuleCreateInfo esf = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    esf.codeSize = g_entity_frag_spv_size;
    esf.pCode = g_entity_frag_spv;
    VkShaderModule efs;
    VKTRY(vkCreateShaderModule(g_device, &esf, NULL, &efs), "create entity fs");
    stages[0].module = evs;
    stages[1].module = efs;
    VkVertexInputBindingDescription ebind = { 0, 36, VK_VERTEX_INPUT_RATE_VERTEX };
    VkVertexInputAttributeDescription eattrs[4] = {
        { 0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0 },
        { 1, 0, VK_FORMAT_R32G32B32_SFLOAT, 12 },
        { 2, 0, VK_FORMAT_R32G32_SFLOAT, 24 },
        { 3, 0, VK_FORMAT_R32_SFLOAT, 32 },
    };
    vin.pVertexBindingDescriptions = &ebind;
    vin.vertexAttributeDescriptionCount = 4;
    vin.pVertexAttributeDescriptions = eattrs;
    cba.blendEnable = VK_TRUE;   // still set from the translucent pipeline
    ds.depthWriteEnable = VK_TRUE;
    gpi.layout = g_entLayout;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeEntity),
          "create entity pipeline");
    // the first-person viewmodel: same entity shaders, but no depth at all so
    // the arm never clips into geometry (the Mac's depthNone)
    ds.depthTestEnable = VK_FALSE;
    ds.depthWriteEnable = VK_FALSE;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeViewmodel),
          "create viewmodel pipeline");
    ds.depthTestEnable = VK_TRUE;
    ds.depthWriteEnable = VK_TRUE;
    vkDestroyShaderModule(g_device, evs, NULL);
    vkDestroyShaderModule(g_device, efs, NULL);

    // UI pipeline: 32-byte canvas stream, blended, no depth
    VkPushConstantRange upcr = { VK_SHADER_STAGE_VERTEX_BIT, 0, 16 };
    VkPipelineLayoutCreateInfo upli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    upli.setLayoutCount = 1;
    upli.pSetLayouts = &g_setLayout;
    upli.pushConstantRangeCount = 1;
    upli.pPushConstantRanges = &upcr;
    VKTRY(vkCreatePipelineLayout(g_device, &upli, NULL, &g_uiLayout), "create UI layout");
    VkShaderModuleCreateInfo usv = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    usv.codeSize = g_ui_vert_spv_size;
    usv.pCode = g_ui_vert_spv;
    VkShaderModule uvs;
    VKTRY(vkCreateShaderModule(g_device, &usv, NULL, &uvs), "create UI vs");
    VkShaderModuleCreateInfo usf = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    usf.codeSize = g_ui_frag_spv_size;
    usf.pCode = g_ui_frag_spv;
    VkShaderModule ufs;
    VKTRY(vkCreateShaderModule(g_device, &usf, NULL, &ufs), "create UI fs");
    stages[0].module = uvs;
    stages[1].module = ufs;
    VkVertexInputBindingDescription ubind = { 0, 32, VK_VERTEX_INPUT_RATE_VERTEX };
    VkVertexInputAttributeDescription uattrs[3] = {
        { 0, 0, VK_FORMAT_R32G32_SFLOAT, 0 },
        { 1, 0, VK_FORMAT_R32G32_SFLOAT, 8 },
        { 2, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 16 },
    };
    vin.pVertexBindingDescriptions = &ubind;
    vin.vertexAttributeDescriptionCount = 3;
    vin.pVertexAttributeDescriptions = uattrs;
    ds.depthTestEnable = VK_FALSE;
    ds.depthWriteEnable = VK_FALSE;
    gpi.layout = g_uiLayout;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeUI),
          "create UI pipeline");
    vkDestroyShaderModule(g_device, uvs, NULL);
    vkDestroyShaderModule(g_device, ufs, NULL);

    // persistent 1024x1024 UI atlas (the canvas streams dirty cells into it)
    VkImageCreateInfo uici = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    uici.imageType = VK_IMAGE_TYPE_2D;
    uici.format = VK_FORMAT_R8G8B8A8_UNORM;
    uici.extent.width = UI_ATLAS;
    uici.extent.height = UI_ATLAS;
    uici.extent.depth = 1;
    uici.mipLevels = 1;
    uici.arrayLayers = 1;
    uici.samples = VK_SAMPLE_COUNT_1_BIT;
    uici.tiling = VK_IMAGE_TILING_OPTIMAL;
    uici.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    uici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VKTRY(vkCreateImage(g_device, &uici, NULL, &g_uiImage), "create UI atlas");
    VkMemoryRequirements ureq;
    vkGetImageMemoryRequirements(g_device, g_uiImage, &ureq);
    VkMemoryAllocateInfo umai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    umai.allocationSize = ureq.size;
    umai.memoryTypeIndex = find_mem_type(ureq.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (umai.memoryTypeIndex == UINT32_MAX) FAIL("no memory for UI atlas");
    VKTRY(vkAllocateMemory(g_device, &umai, NULL, &g_uiMem), "allocate UI atlas memory");
    VKTRY(vkBindImageMemory(g_device, g_uiImage, g_uiMem, 0), "bind UI atlas memory");
    VkImageViewCreateInfo uvci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    uvci.image = g_uiImage;
    uvci.viewType = VK_IMAGE_VIEW_TYPE_2D;
    uvci.format = VK_FORMAT_R8G8B8A8_UNORM;
    uvci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    uvci.subresourceRange.levelCount = 1;
    uvci.subresourceRange.layerCount = 1;
    VKTRY(vkCreateImageView(g_device, &uvci, NULL, &g_uiView), "create UI atlas view");
    if (make_sampler_set(g_uiView, &g_uiSet) != 0) return -1;

    // ---- sky pipelines: dome, stars, sun/moon, clouds (PORTING 07) ---------
    // the dome and the billboards build their corners from gl_VertexIndex, so
    // they take no vertex input at all
    VkPipelineVertexInputStateCreateInfo novin = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkShaderModule skvs, skfs;

    // sky dome — opaque fullscreen triangle, no depth (the Mac's depthNone)
    VkPushConstantRange skpcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                                  0, sizeof(PbSkyPush) };
    VkPipelineLayoutCreateInfo skpli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    skpli.pushConstantRangeCount = 1;
    skpli.pPushConstantRanges = &skpcr;
    VKTRY(vkCreatePipelineLayout(g_device, &skpli, NULL, &g_skyLayout), "create sky layout");
    if (make_shader(g_sky_vert_spv, g_sky_vert_spv_size, &skvs) != 0) return -1;
    if (make_shader(g_sky_frag_spv, g_sky_frag_spv_size, &skfs) != 0) return -1;
    stages[0].module = skvs;
    stages[1].module = skfs;
    gpi.pVertexInputState = &novin;
    ds.depthTestEnable = VK_FALSE;
    ds.depthWriteEnable = VK_FALSE;
    cba.blendEnable = VK_FALSE;
    gpi.layout = g_skyLayout;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeSky),
          "create sky pipeline");
    vkDestroyShaderModule(g_device, skvs, NULL);
    vkDestroyShaderModule(g_device, skfs, NULL);

    // stars — additive, one instanced quad per star (the Mac's 16-byte stream)
    VkPushConstantRange stpcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                                  0, sizeof(PbStarsPush) };
    VkPipelineLayoutCreateInfo stpli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    stpli.pushConstantRangeCount = 1;
    stpli.pPushConstantRanges = &stpcr;
    VKTRY(vkCreatePipelineLayout(g_device, &stpli, NULL, &g_starsLayout), "create stars layout");
    VkShaderModule stvs, stfs;
    if (make_shader(g_stars_vert_spv, g_stars_vert_spv_size, &stvs) != 0) return -1;
    if (make_shader(g_stars_frag_spv, g_stars_frag_spv_size, &stfs) != 0) return -1;
    stages[0].module = stvs;
    stages[1].module = stfs;
    VkVertexInputBindingDescription sbind = { 0, 16, VK_VERTEX_INPUT_RATE_INSTANCE };
    VkVertexInputAttributeDescription sattrs[2] = {
        { 0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0 },
        { 1, 0, VK_FORMAT_R32_SFLOAT, 12 },
    };
    VkPipelineVertexInputStateCreateInfo svin = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    svin.vertexBindingDescriptionCount = 1;
    svin.pVertexBindingDescriptions = &sbind;
    svin.vertexAttributeDescriptionCount = 2;
    svin.pVertexAttributeDescriptions = sattrs;
    gpi.pVertexInputState = &svin;
    cba.blendEnable = VK_TRUE;   // additive: the Mac's blend:true + additive:true
    cba.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    cba.dstColorBlendFactor = VK_BLEND_FACTOR_ONE;
    cba.colorBlendOp = VK_BLEND_OP_ADD;
    cba.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    cba.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    cba.alphaBlendOp = VK_BLEND_OP_ADD;
    gpi.layout = g_starsLayout;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeStars),
          "create stars pipeline");
    vkDestroyShaderModule(g_device, stvs, NULL);
    vkDestroyShaderModule(g_device, stfs, NULL);

    // sun/moon — two variants, exactly like the Mac: pack art goes additive,
    // the procedural disc goes straight alpha
    VkPushConstantRange cepcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                                  0, sizeof(PbCelPush) };
    VkPipelineLayoutCreateInfo cepli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    cepli.setLayoutCount = 1;
    cepli.pSetLayouts = &g_setLayout;
    cepli.pushConstantRangeCount = 1;
    cepli.pPushConstantRanges = &cepcr;
    VKTRY(vkCreatePipelineLayout(g_device, &cepli, NULL, &g_celLayout), "create celestial layout");
    VkShaderModule cevs, cefs;
    if (make_shader(g_celestial_vert_spv, g_celestial_vert_spv_size, &cevs) != 0) return -1;
    if (make_shader(g_celestial_frag_spv, g_celestial_frag_spv_size, &cefs) != 0) return -1;
    stages[0].module = cevs;
    stages[1].module = cefs;
    gpi.pVertexInputState = &novin;
    gpi.layout = g_celLayout;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeCelestialAdd),
          "create celestial (additive) pipeline");
    cba.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;   // back to straight alpha
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeCelestial),
          "create celestial pipeline");
    vkDestroyShaderModule(g_device, cevs, NULL);
    vkDestroyShaderModule(g_device, cefs, NULL);

    // clouds — alpha blended, depth tested but not written (drawn after the
    // translucent pass, like the Mac)
    VkPushConstantRange clpcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                                  0, sizeof(PbCloudPush) };
    VkPipelineLayoutCreateInfo clpli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    clpli.setLayoutCount = 1;
    clpli.pSetLayouts = &g_setLayout;
    clpli.pushConstantRangeCount = 1;
    clpli.pPushConstantRanges = &clpcr;
    VKTRY(vkCreatePipelineLayout(g_device, &clpli, NULL, &g_cloudLayout), "create cloud layout");
    VkShaderModule clvs, clfs;
    if (make_shader(g_cloud_vert_spv, g_cloud_vert_spv_size, &clvs) != 0) return -1;
    if (make_shader(g_cloud_frag_spv, g_cloud_frag_spv_size, &clfs) != 0) return -1;
    stages[0].module = clvs;
    stages[1].module = clfs;
    ds.depthTestEnable = VK_TRUE;
    ds.depthWriteEnable = VK_FALSE;
    gpi.layout = g_cloudLayout;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeCloud),
          "create cloud pipeline");
    vkDestroyShaderModule(g_device, clvs, NULL);
    vkDestroyShaderModule(g_device, clfs, NULL);

    // ---- post-processing: render passes and the fullscreen pipelines ------
    // scene pass: colour + the existing depth buffer, ending in a layout the
    // bloom and composite passes can sample
    {
        VkAttachmentDescription patts[2] = { { 0 }, { 0 } };
        patts[0].format = g_format;
        patts[0].samples = VK_SAMPLE_COUNT_1_BIT;
        patts[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        patts[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        patts[0].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        patts[0].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        patts[0].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        patts[0].finalLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        patts[1].format = VK_FORMAT_D32_SFLOAT;
        patts[1].samples = VK_SAMPLE_COUNT_1_BIT;
        patts[1].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        patts[1].storeOp = VK_ATTACHMENT_STORE_OP_STORE;   // ultra samples it
        patts[1].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        patts[1].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        patts[1].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        patts[1].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
        VkAttachmentReference pref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        VkAttachmentReference pdref = { 1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
        VkSubpassDescription psub = { 0 };
        psub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        psub.colorAttachmentCount = 1;
        psub.pColorAttachments = &pref;
        psub.pDepthStencilAttachment = &pdref;
        // in: wait for last frame's sampling of this image; out: make the
        // writes visible to the passes that sample it
        VkSubpassDependency pdeps[2] = { { 0 }, { 0 } };
        pdeps[0].srcSubpass = VK_SUBPASS_EXTERNAL;
        pdeps[0].dstSubpass = 0;
        pdeps[0].srcStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        pdeps[0].srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
        pdeps[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
            | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        pdeps[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
            | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        pdeps[1].srcSubpass = 0;
        pdeps[1].dstSubpass = VK_SUBPASS_EXTERNAL;
        pdeps[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        pdeps[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        pdeps[1].dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        pdeps[1].dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        VkRenderPassCreateInfo prci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
        prci.attachmentCount = 2;
        prci.pAttachments = patts;
        prci.subpassCount = 1;
        prci.pSubpasses = &psub;
        prci.dependencyCount = 2;
        prci.pDependencies = pdeps;
        if (vkCreateRenderPass(g_device, &prci, NULL, &g_scenePass) != VK_SUCCESS)
            g_scenePass = VK_NULL_HANDLE;

        // bloom pass: colour only, contents always fully overwritten
        patts[0].loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        psub.pDepthStencilAttachment = NULL;
        pdeps[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        pdeps[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        prci.attachmentCount = 1;
        if (vkCreateRenderPass(g_device, &prci, NULL, &g_bloomPass) != VK_SUCCESS)
            g_bloomPass = VK_NULL_HANDLE;
    }

    if (g_scenePass && g_bloomPass) {
        VkShaderModule fsvs, bxfs, blfs, cofs;
        if (make_shader(g_fs_vert_spv, g_fs_vert_spv_size, &fsvs) != 0) return -1;
        if (make_shader(g_bloom_extract_frag_spv, g_bloom_extract_frag_spv_size, &bxfs) != 0) return -1;
        if (make_shader(g_blur_frag_spv, g_blur_frag_spv_size, &blfs) != 0) return -1;
        if (make_shader(g_composite_frag_spv, g_composite_frag_spv_size, &cofs) != 0) return -1;

        VkPipelineLayoutCreateInfo bpli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
        bpli.setLayoutCount = 1;
        bpli.pSetLayouts = &g_setLayout;
        VkPushConstantRange bpcr = { VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16 };
        bpli.pushConstantRangeCount = 1;
        bpli.pPushConstantRanges = &bpcr;
        VKTRY(vkCreatePipelineLayout(g_device, &bpli, NULL, &g_bloomLayout), "create bloom layout");

        VkDescriptorSetLayout threeSets[3] = { g_setLayout, g_setLayout, g_setLayout };
        VkPipelineLayoutCreateInfo cpli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
        cpli.setLayoutCount = 3;
        cpli.pSetLayouts = threeSets;
        VkPushConstantRange cpcr = { VK_SHADER_STAGE_FRAGMENT_BIT, 0, 48 };
        cpli.pushConstantRangeCount = 1;
        cpli.pPushConstantRanges = &cpcr;
        VKTRY(vkCreatePipelineLayout(g_device, &cpli, NULL, &g_compositeLayout), "create composite layout");

        stages[0].module = fsvs;
        stages[1].module = bxfs;
        gpi.pVertexInputState = &novin;
        ds.depthTestEnable = VK_FALSE;
        ds.depthWriteEnable = VK_FALSE;
        cba.blendEnable = VK_FALSE;
        gpi.layout = g_bloomLayout;
        gpi.renderPass = g_bloomPass;
        VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeBloomExtract),
              "create bloom-extract pipeline");
        stages[1].module = blfs;
        VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeBlur),
              "create blur pipeline");
        stages[1].module = cofs;
        gpi.layout = g_compositeLayout;
        gpi.renderPass = g_pass;          // composite lands in the swapchain
        VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeComposite),
              "create composite pipeline");
        gpi.renderPass = g_pass;
        vkDestroyShaderModule(g_device, fsvs, NULL);
        vkDestroyShaderModule(g_device, bxfs, NULL);
        vkDestroyShaderModule(g_device, blfs, NULL);
        vkDestroyShaderModule(g_device, cofs, NULL);

        // the three sampler sets the chain reads through; build_post_targets
        // rewrites them whenever the swapchain (and so the views) changes
        if (make_sampler_set2(g_uiView, g_linearSampler, &g_sceneSet) != 0) return -1;
        if (make_sampler_set2(g_uiView, g_linearSampler, &g_bloomSet[0]) != 0) return -1;
        if (make_sampler_set2(g_uiView, g_linearSampler, &g_bloomSet[1]) != 0) return -1;
        if (make_sampler_set2(g_uiView, g_linearSampler, &g_ultraSet[0]) != 0) return -1;
        if (make_sampler_set2(g_uiView, g_linearSampler, &g_ultraSet[1]) != 0) return -1;
        if (make_sampler_set2(g_uiView, g_depthSampler, &g_depthSet) != 0) return -1;
        if (make_sampler_set2(g_shadowView, g_shadowSampler, &g_shadowSamplerSet) != 0) return -1;

        // ---- ultra: SSAO + volumetrics, entirely optional --------------
        // Anything failing here leaves g_ultraOK at 0 and the composite's
        // ultra branch switched off; the rest of the frame is unaffected.
        g_ultraOK = 0;
        do {
            g_ultraUboStride = 256;
            if (make_buffer(g_ultraUboStride * FRAMES_IN_FLIGHT,
                            VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                            &g_ultraUbo, &g_ultraUboMem, NULL) != 0) break;
            if (vkMapMemory(g_device, g_ultraUboMem, 0,
                            g_ultraUboStride * FRAMES_IN_FLIGHT, 0, &g_ultraUboMap) != VK_SUCCESS) break;
            memset(g_ultraUboMap, 0, (size_t)(g_ultraUboStride * FRAMES_IN_FLIGHT));

            VkDescriptorSetAllocateInfo uda = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
            uda.descriptorPool = g_descPool;
            uda.descriptorSetCount = 1;
            uda.pSetLayouts = &g_uboSetLayout;
            if (vkAllocateDescriptorSets(g_device, &uda, &g_ultraUboSet) != VK_SUCCESS) break;
            VkDescriptorBufferInfo udbi = { g_ultraUbo, 0, ULTRA_UBO_BYTES };
            VkWriteDescriptorSet uw = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
            uw.dstSet = g_ultraUboSet;
            uw.dstBinding = 0;
            uw.descriptorCount = 1;
            uw.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
            uw.pBufferInfo = &udbi;
            vkUpdateDescriptorSets(g_device, 1, &uw, 0, NULL);

            // set 0 depth, set 1 shadow map, set 2 the ultra block
            VkDescriptorSetLayout usets[3] = { g_setLayout, g_setLayout, g_uboSetLayout };
            VkPipelineLayoutCreateInfo upli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
            upli.setLayoutCount = 3;
            upli.pSetLayouts = usets;
            if (vkCreatePipelineLayout(g_device, &upli, NULL, &g_ultraLayout) != VK_SUCCESS) break;

            VkShaderModule ufs2, ubfs;
            if (make_shader(g_ultra_frag_spv, g_ultra_frag_spv_size, &ufs2) != 0) break;
            if (make_shader(g_ultra_blur_frag_spv, g_ultra_blur_frag_spv_size, &ubfs) != 0) break;
            VkShaderModule ufsv;
            if (make_shader(g_fs_vert_spv, g_fs_vert_spv_size, &ufsv) != 0) break;
            stages[0].module = ufsv;
            stages[1].module = ufs2;
            gpi.pVertexInputState = &novin;
            gpi.layout = g_ultraLayout;
            gpi.renderPass = g_bloomPass;
            if (vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL,
                                          &g_pipeUltra) != VK_SUCCESS) break;
            stages[1].module = ubfs;
            gpi.layout = g_bloomLayout;      // one sampler + the 16-byte direction
            if (vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL,
                                          &g_pipeUltraBlur) != VK_SUCCESS) break;
            vkDestroyShaderModule(g_device, ufsv, NULL);
            vkDestroyShaderModule(g_device, ufs2, NULL);
            vkDestroyShaderModule(g_device, ubfs, NULL);
            gpi.renderPass = g_pass;
            g_ultraOK = 1;
        } while (0);
        if (!g_ultraOK) warnless_ultra();
    }

    // 1x1 white stand-in: keeps a set bound when the pack ships no sky art
    static const unsigned char kWhite[4] = { 255, 255, 255, 255 };
    if (upload_texture(kWhite, 1, 1, 1, VK_IMAGE_VIEW_TYPE_2D,
                       &g_dummyImage, &g_dummyMem, &g_dummyView) != 0) return -1;
    if (make_sampler_set2(g_dummyView, g_linearSampler, &g_dummySet) != 0) return -1;

    // ---- detail pipelines: lines, particles, item sprites (PORTING 07) -----
    // selection outline / blob shadows: flat colour, depth tested, not written
    VkPushConstantRange lnpcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                                  0, sizeof(PbLinePush) };
    VkPipelineLayoutCreateInfo lnpli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    lnpli.pushConstantRangeCount = 1;
    lnpli.pPushConstantRanges = &lnpcr;
    VKTRY(vkCreatePipelineLayout(g_device, &lnpli, NULL, &g_lineLayout), "create line layout");
    VkShaderModule lnvs, lnfs;
    if (make_shader(g_line_vert_spv, g_line_vert_spv_size, &lnvs) != 0) return -1;
    if (make_shader(g_line_frag_spv, g_line_frag_spv_size, &lnfs) != 0) return -1;
    stages[0].module = lnvs;
    stages[1].module = lnfs;
    VkVertexInputBindingDescription lnbind = { 0, LINE_STRIDE, VK_VERTEX_INPUT_RATE_VERTEX };
    VkVertexInputAttributeDescription lnattr = { 0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0 };
    VkPipelineVertexInputStateCreateInfo lnvin = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    lnvin.vertexBindingDescriptionCount = 1;
    lnvin.pVertexBindingDescriptions = &lnbind;
    lnvin.vertexAttributeDescriptionCount = 1;
    lnvin.pVertexAttributeDescriptions = &lnattr;
    gpi.pVertexInputState = &lnvin;
    cba.blendEnable = VK_TRUE;
    cba.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    cba.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    cba.colorBlendOp = VK_BLEND_OP_ADD;
    cba.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    cba.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    cba.alphaBlendOp = VK_BLEND_OP_ADD;
    ds.depthTestEnable = VK_TRUE;
    ds.depthWriteEnable = VK_FALSE;
    gpi.layout = g_lineLayout;
    ia.topology = VK_PRIMITIVE_TOPOLOGY_LINE_LIST;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeLines),
          "create line pipeline");
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;   // same shader, filled
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeLineTris),
          "create line-fill pipeline");
    vkDestroyShaderModule(g_device, lnvs, NULL);
    vkDestroyShaderModule(g_device, lnfs, NULL);

    // particles: instanced quads off the terrain atlas, depth tested only
    VkPushConstantRange papcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                                  0, sizeof(PbParticlePush) };
    VkPipelineLayoutCreateInfo papli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    papli.setLayoutCount = 1;
    papli.pSetLayouts = &g_setLayout;
    papli.pushConstantRangeCount = 1;
    papli.pPushConstantRanges = &papcr;
    VKTRY(vkCreatePipelineLayout(g_device, &papli, NULL, &g_particleLayout), "create particle layout");
    VkShaderModule pavs, pafs;
    if (make_shader(g_particle_vert_spv, g_particle_vert_spv_size, &pavs) != 0) return -1;
    if (make_shader(g_particle_frag_spv, g_particle_frag_spv_size, &pafs) != 0) return -1;
    stages[0].module = pavs;
    stages[1].module = pafs;
    VkVertexInputBindingDescription pabind = { 0, PARTICLE_STRIDE, VK_VERTEX_INPUT_RATE_INSTANCE };
    VkVertexInputAttributeDescription paattrs[4] = {
        { 0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0 },
        { 1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 12 },
        { 2, 0, VK_FORMAT_R32_SFLOAT, 28 },
        { 3, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 32 },
    };
    VkPipelineVertexInputStateCreateInfo pavin = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    pavin.vertexBindingDescriptionCount = 1;
    pavin.pVertexBindingDescriptions = &pabind;
    pavin.vertexAttributeDescriptionCount = 4;
    pavin.pVertexAttributeDescriptions = paattrs;
    gpi.pVertexInputState = &pavin;
    gpi.layout = g_particleLayout;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeParticle),
          "create particle pipeline");
    vkDestroyShaderModule(g_device, pavs, NULL);
    vkDestroyShaderModule(g_device, pafs, NULL);

    // item sprites: instanced billboards, depth written (the Mac's depthWrite)
    VkPushConstantRange sppcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                                  0, sizeof(PbSpritePush) };
    VkPipelineLayoutCreateInfo sppli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    sppli.setLayoutCount = 1;
    sppli.pSetLayouts = &g_setLayout;
    sppli.pushConstantRangeCount = 1;
    sppli.pPushConstantRanges = &sppcr;
    VKTRY(vkCreatePipelineLayout(g_device, &sppli, NULL, &g_spriteLayout), "create sprite layout");
    VkShaderModule spvs, spfs;
    if (make_shader(g_sprite_vert_spv, g_sprite_vert_spv_size, &spvs) != 0) return -1;
    if (make_shader(g_sprite_frag_spv, g_sprite_frag_spv_size, &spfs) != 0) return -1;
    stages[0].module = spvs;
    stages[1].module = spfs;
    VkVertexInputBindingDescription spbind = { 0, SPRITE_STRIDE, VK_VERTEX_INPUT_RATE_INSTANCE };
    VkVertexInputAttributeDescription spattrs[4] = {
        { 0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0 },
        { 1, 0, VK_FORMAT_R32_SFLOAT, 12 },
        { 2, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 16 },
        { 3, 0, VK_FORMAT_R32_SFLOAT, 32 },
    };
    VkPipelineVertexInputStateCreateInfo spvin = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    spvin.vertexBindingDescriptionCount = 1;
    spvin.pVertexBindingDescriptions = &spbind;
    spvin.vertexAttributeDescriptionCount = 4;
    spvin.pVertexAttributeDescriptions = spattrs;
    gpi.pVertexInputState = &spvin;
    ds.depthWriteEnable = VK_TRUE;
    gpi.layout = g_spriteLayout;
    VKTRY(vkCreateGraphicsPipelines(g_device, VK_NULL_HANDLE, 1, &gpi, NULL, &g_pipeSprite),
          "create sprite pipeline");
    vkDestroyShaderModule(g_device, spvs, NULL);
    vkDestroyShaderModule(g_device, spfs, NULL);

    // the item-icon atlas the sprite pass samples
    VkImageCreateInfo spici = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    spici.imageType = VK_IMAGE_TYPE_2D;
    spici.format = VK_FORMAT_R8G8B8A8_UNORM;
    spici.extent.width = SPRITE_ATLAS_W;
    spici.extent.height = SPRITE_ATLAS_H;
    spici.extent.depth = 1;
    spici.mipLevels = 1;
    spici.arrayLayers = 1;
    spici.samples = VK_SAMPLE_COUNT_1_BIT;
    spici.tiling = VK_IMAGE_TILING_OPTIMAL;
    spici.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    spici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VKTRY(vkCreateImage(g_device, &spici, NULL, &g_sprImage), "create sprite atlas");
    VkMemoryRequirements spreq;
    vkGetImageMemoryRequirements(g_device, g_sprImage, &spreq);
    VkMemoryAllocateInfo spmai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    spmai.allocationSize = spreq.size;
    spmai.memoryTypeIndex = find_mem_type(spreq.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (spmai.memoryTypeIndex == UINT32_MAX) FAIL("no memory for sprite atlas");
    VKTRY(vkAllocateMemory(g_device, &spmai, NULL, &g_sprMem), "allocate sprite atlas memory");
    VKTRY(vkBindImageMemory(g_device, g_sprImage, g_sprMem, 0), "bind sprite atlas memory");
    VkImageViewCreateInfo spvci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    spvci.image = g_sprImage;
    spvci.viewType = VK_IMAGE_VIEW_TYPE_2D;
    spvci.format = VK_FORMAT_R8G8B8A8_UNORM;
    spvci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    spvci.subresourceRange.levelCount = 1;
    spvci.subresourceRange.layerCount = 1;
    VKTRY(vkCreateImageView(g_device, &spvci, NULL, &g_sprView), "create sprite atlas view");
    if (make_sampler_set(g_sprView, &g_sprSet) != 0) return -1;

    // fixed-size per-frame streams — every one of these has a hard cap, so
    // they are allocated once instead of growing like the UI's
    for (int i = 0; i < FRAMES_IN_FLIGHT; i++) {
        if (make_buffer(MAX_LINE_VERTS * LINE_STRIDE, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                        &g_lineVbuf[i], &g_lineVmem[i], NULL) != 0) return -1;
        VKTRY(vkMapMemory(g_device, g_lineVmem[i], 0, MAX_LINE_VERTS * LINE_STRIDE, 0, &g_lineVmap[i]),
              "map line buffer");
        if (make_buffer(MAX_PARTICLES * PARTICLE_STRIDE, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                        &g_partVbuf[i], &g_partVmem[i], NULL) != 0) return -1;
        VKTRY(vkMapMemory(g_device, g_partVmem[i], 0, MAX_PARTICLES * PARTICLE_STRIDE, 0, &g_partVmap[i]),
              "map particle buffer");
        if (make_buffer(MAX_SPRITES * SPRITE_STRIDE, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                        &g_sprVbuf[i], &g_sprVmem[i], NULL) != 0) return -1;
        VKTRY(vkMapMemory(g_device, g_sprVmem[i], 0, MAX_SPRITES * SPRITE_STRIDE, 0, &g_sprVmap[i]),
              "map sprite buffer");
        for (int s = 0; s < OVERLAY_COUNT; s++) {
            PbOverlayMesh* m = &g_overlay[s];
            if (make_buffer(MAX_OVERLAY_VERTS * 28, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                            &m->vbuf[i], &m->vmem[i], NULL) != 0) return -1;
            VKTRY(vkMapMemory(g_device, m->vmem[i], 0, MAX_OVERLAY_VERTS * 28, 0, &m->vmap[i]),
                  "map overlay vertex buffer");
            if (make_buffer(MAX_OVERLAY_INDICES * 4, VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                            &m->ibuf[i], &m->imem[i], NULL) != 0) return -1;
            VKTRY(vkMapMemory(g_device, m->imem[i], 0, MAX_OVERLAY_INDICES * 4, 0, &m->imap[i]),
                  "map overlay index buffer");
        }
    }

    if (!g_sectionsInit) {
        for (int i = 0; i < MAX_SECTIONS; i++) g_sections[i].pass = -1;
        g_sectionsInit = 1;
    }

    g_pendingW = width;
    g_pendingH = height;
    if (build_swapchain(width, height) != 0 && g_err[0]) return -1;
    return 0;
}

void pb_vk_resize(int width, int height) {
    g_pendingW = width;
    g_pendingH = height;
    g_needRebuild = 1;
}

// ---- world data: atlas + sections ------------------------------------------

/// staging upload of straight RGBA8 into a fresh sampled image (+view)
static int upload_texture(const unsigned char* rgba, int w, int h, int layers,
                          VkImageViewType viewType,
                          VkImage* outImg, VkDeviceMemory* outMem, VkImageView* outView) {
    VkDeviceSize total = (VkDeviceSize)w * h * 4 * layers;
    VkBuffer staging;
    VkDeviceMemory stagingMem;
    if (make_buffer(total, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &staging, &stagingMem, rgba) != 0)
        return -1;

    VkImageCreateInfo ici = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    ici.imageType = VK_IMAGE_TYPE_2D;
    ici.format = VK_FORMAT_R8G8B8A8_UNORM;
    ici.extent.width = (uint32_t)w;
    ici.extent.height = (uint32_t)h;
    ici.extent.depth = 1;
    ici.mipLevels = 1;
    ici.arrayLayers = (uint32_t)layers;
    ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VKTRY(vkCreateImage(g_device, &ici, NULL, outImg), "create texture image");
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(g_device, *outImg, &req);
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = find_mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mai.memoryTypeIndex == UINT32_MAX) FAIL("no device-local memory for texture");
    VKTRY(vkAllocateMemory(g_device, &mai, NULL, outMem), "allocate texture memory");
    VKTRY(vkBindImageMemory(g_device, *outImg, *outMem, 0), "bind texture memory");

    // one-shot: UNDEFINED → TRANSFER_DST → copy → SHADER_READ_ONLY
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkQueueWaitIdle(g_queue);
    vkResetCommandBuffer(g_cmd[0], 0);
    vkBeginCommandBuffer(g_cmd[0], &bi);
    VkImageMemoryBarrier bar = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    bar.srcAccessMask = 0;
    bar.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    bar.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    bar.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    bar.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bar.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bar.image = *outImg;
    bar.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    bar.subresourceRange.levelCount = 1;
    bar.subresourceRange.layerCount = (uint32_t)layers;
    vkCmdPipelineBarrier(g_cmd[0], VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
    VkBufferImageCopy copy = { 0 };
    copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy.imageSubresource.layerCount = (uint32_t)layers;
    copy.imageExtent.width = (uint32_t)w;
    copy.imageExtent.height = (uint32_t)h;
    copy.imageExtent.depth = 1;
    vkCmdCopyBufferToImage(g_cmd[0], staging, *outImg,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
    bar.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    bar.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    bar.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    bar.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vkCmdPipelineBarrier(g_cmd[0], VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
    vkEndCommandBuffer(g_cmd[0]);
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1;
    si.pCommandBuffers = &g_cmd[0];
    VKTRY(vkQueueSubmit(g_queue, 1, &si, VK_NULL_HANDLE), "submit texture upload");
    vkQueueWaitIdle(g_queue);
    vkDestroyBuffer(g_device, staging, NULL);
    vkFreeMemory(g_device, stagingMem, NULL);

    VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    vci.image = *outImg;
    vci.viewType = viewType;
    vci.format = VK_FORMAT_R8G8B8A8_UNORM;
    vci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    vci.subresourceRange.levelCount = 1;
    vci.subresourceRange.layerCount = (uint32_t)layers;
    VKTRY(vkCreateImageView(g_device, &vci, NULL, outView), "create texture view");
    return 0;
}

static int make_sampler_set(VkImageView view, VkDescriptorSet* outSet) {
    return make_sampler_set2(view, g_atlasSampler, outSet);
}

/// an entity geometry's descriptor set: its skin plus the shared, dynamically
/// offset part-matrix buffer
static int make_entity_set(VkImageView view, VkDescriptorSet* outSet) {
    VkDescriptorSetAllocateInfo dsa = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    dsa.descriptorPool = g_descPool;
    dsa.descriptorSetCount = 1;
    dsa.pSetLayouts = &g_entSetLayout;
    VKTRY(vkAllocateDescriptorSets(g_device, &dsa, outSet), "allocate entity descriptor set");
    VkDescriptorImageInfo dii = { g_atlasSampler, view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    VkDescriptorBufferInfo dbi = { g_partsBuf, 0, ENTITY_PARTS_BYTES };
    VkWriteDescriptorSet wds[2] = {
        { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET },
        { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET },
    };
    wds[0].dstSet = *outSet;
    wds[0].dstBinding = 0;
    wds[0].descriptorCount = 1;
    wds[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    wds[0].pImageInfo = &dii;
    wds[1].dstSet = *outSet;
    wds[1].dstBinding = 1;
    wds[1].descriptorCount = 1;
    wds[1].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
    wds[1].pBufferInfo = &dbi;
    vkUpdateDescriptorSets(g_device, 2, wds, 0, NULL);
    return 0;
}

/// the terrain descriptor set: the atlas, the shadow map, and the dynamically
/// offset uniform holding the sun's matrix
static int make_chunk_set(VkImageView view, VkDescriptorSet* outSet) {
    VkDescriptorSetAllocateInfo dsa = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    dsa.descriptorPool = g_descPool;
    dsa.descriptorSetCount = 1;
    dsa.pSetLayouts = &g_chunkSetLayout;
    VKTRY(vkAllocateDescriptorSets(g_device, &dsa, outSet), "allocate chunk descriptor set");
    VkDescriptorImageInfo atlas = { g_atlasSampler, view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    VkDescriptorImageInfo shadow = { g_shadowSampler, g_shadowView,
                                     VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL };
    VkDescriptorBufferInfo dbi = { g_shadowUbo, 0, SHADOW_UBO_BYTES };
    VkWriteDescriptorSet wds[3] = {
        { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET },
        { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET },
        { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET },
    };
    wds[0].dstSet = *outSet;
    wds[0].dstBinding = 0;
    wds[0].descriptorCount = 1;
    wds[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    wds[0].pImageInfo = &atlas;
    wds[1].dstSet = *outSet;
    wds[1].dstBinding = 1;
    wds[1].descriptorCount = 1;
    wds[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    wds[1].pImageInfo = &shadow;
    wds[2].dstSet = *outSet;
    wds[2].dstBinding = 2;
    wds[2].descriptorCount = 1;
    wds[2].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
    wds[2].pBufferInfo = &dbi;
    vkUpdateDescriptorSets(g_device, 3, wds, 0, NULL);
    return 0;
}

static int make_shader(const uint32_t* code, size_t size, VkShaderModule* out) {
    VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    smci.codeSize = size;
    smci.pCode = code;
    VKTRY(vkCreateShaderModule(g_device, &smci, NULL, out), "create shader module");
    return 0;
}

static int make_sampler_set2(VkImageView view, VkSampler smp, VkDescriptorSet* outSet) {
    VkDescriptorSetAllocateInfo dsa = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    dsa.descriptorPool = g_descPool;
    dsa.descriptorSetCount = 1;
    dsa.pSetLayouts = &g_setLayout;
    VKTRY(vkAllocateDescriptorSets(g_device, &dsa, outSet), "allocate descriptor set");
    VkDescriptorImageInfo dii = { smp, view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    VkWriteDescriptorSet wds = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
    wds.dstSet = *outSet;
    wds.dstBinding = 0;
    wds.descriptorCount = 1;
    wds.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    wds.pImageInfo = &dii;
    vkUpdateDescriptorSets(g_device, 1, &wds, 0, NULL);
    return 0;
}

static int g_atlasCols = 1;

int pb_vk_upload_atlas(const unsigned char* rgba, int tileW, int tileH, int layers) {
    if (!g_device) FAIL("renderer not created");
    // pack the tile stack into a 2D grid: texture arrays hit per-GPU layer
    // limits (as low as 256) and some drivers mis-sample instead of failing
    int cols = 1;
    while (cols * cols < layers) cols++;
    int rows = (layers + cols - 1) / cols;
    g_atlasCols = cols;
    size_t gw = (size_t)cols * tileW, gh = (size_t)rows * tileH;
    unsigned char* grid = (unsigned char*)calloc(gw * gh, 4);
    if (!grid) FAIL("atlas grid alloc failed");
    for (int l = 0; l < layers; l++) {
        size_t gx = (size_t)(l % cols) * tileW, gy = (size_t)(l / cols) * tileH;
        const unsigned char* src = rgba + (size_t)l * tileW * tileH * 4;
        for (int row = 0; row < tileH; row++) {
            memcpy(grid + ((gy + row) * gw + gx) * 4,
                   src + (size_t)row * tileW * 4, (size_t)tileW * 4);
        }
    }
    int rc = upload_texture(grid, (int)gw, (int)gh, 1, VK_IMAGE_VIEW_TYPE_2D,
                            &g_atlasImage, &g_atlasMem, &g_atlasView);
    free(grid);
    if (rc != 0) return -1;
    // the particle pass samples the same atlas through the plain one-binding
    // layout, so it needs its own set
    if (make_sampler_set(g_atlasView, &g_atlasSetPlain) != 0) return -1;
    return make_chunk_set(g_atlasView, &g_atlasSet);
}

int pb_vk_upload_entity_geom(int geomId, const void* verts, int vertCount,
                             const unsigned char* rgba, int texW, int texH) {
    if (!g_device) FAIL("renderer not created");
    if (geomId < 0 || geomId >= MAX_ENTITY_GEOMS) FAIL("entity geom id out of range");
    PbEntityGeom* gm = &g_entGeoms[geomId];
    if (gm->used) return 0;   // types are static — first upload wins
    if (make_buffer((VkDeviceSize)vertCount * 36, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                    &gm->vbuf, &gm->vmem, verts) != 0) return -1;
    gm->vertCount = (uint32_t)vertCount;
    if (upload_texture(rgba, texW, texH, 1, VK_IMAGE_VIEW_TYPE_2D,
                       &gm->tex, &gm->texMem, &gm->texView) != 0) return -1;
    if (make_entity_set(gm->texView, &gm->set) != 0) return -1;
    gm->used = 1;
    return 0;
}

/// copy 24 part matrices into this frame's ring slot (NULL = bind pose)
static void stash_parts(int slot, const float* parts24) {
    if (!g_partsMap || slot < 0 || slot >= PARTS_SLOTS_PER_FRAME) return;
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    VkDeviceSize base = (VkDeviceSize)f * PARTS_SLOTS_PER_FRAME * g_partsStride;
    char* dst = (char*)g_partsMap + base + (VkDeviceSize)slot * g_partsStride;
    if (parts24) {
        memcpy(dst, parts24, ENTITY_PARTS_BYTES);
    } else {
        float* m = (float*)dst;
        for (int k = 0; k < ENTITY_PARTS; k++) {
            for (int e = 0; e < 16; e++) m[k * 16 + e] = (e % 5 == 0) ? 1.0f : 0.0f;
        }
    }
}

/// the byte offset of a ring slot inside this frame's region
static uint32_t parts_offset(int slot) {
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    return (uint32_t)((VkDeviceSize)f * PARTS_SLOTS_PER_FRAME * g_partsStride
                      + (VkDeviceSize)slot * g_partsStride);
}

void pb_vk_begin_entities(void) {
    g_entDrawCount = 0;
}

void pb_vk_push_entity(int geomId, const float* model16, float brightness, float alpha,
                       const float* parts24) {
    if (geomId < 0 || geomId >= MAX_ENTITY_GEOMS || !g_entGeoms[geomId].used) return;
    if (g_entDrawCount >= MAX_ENTITY_DRAWS) return;
    PbEntityDraw* d = &g_entDraws[g_entDrawCount];
    d->partsSlot = g_entDrawCount;
    stash_parts(d->partsSlot, parts24);
    g_entDrawCount++;
    d->geomId = geomId;
    mat4_mul(d->push.mvp, g_push.viewProj, model16);
    d->push.light[0] = brightness;
    d->push.light[1] = 0;
    d->push.light[2] = 0;
    d->push.light[3] = alpha;
}

static PbSection* find_section(uint64_t id, int pass) {
    for (int i = 0; i < MAX_SECTIONS; i++) {
        if (g_sections[i].pass == pass && g_sections[i].id == id) return &g_sections[i];
    }
    return NULL;
}

static void free_section(PbSection* s) {
    vkDeviceWaitIdle(g_device);   // uploads are load-time bursts; safe > fast
    if (s->vbuf) vkDestroyBuffer(g_device, s->vbuf, NULL);
    if (s->vmem) vkFreeMemory(g_device, s->vmem, NULL);
    if (s->ibuf) vkDestroyBuffer(g_device, s->ibuf, NULL);
    if (s->imem) vkFreeMemory(g_device, s->imem, NULL);
    memset(s, 0, sizeof *s);
    s->pass = -1;
}

int pb_vk_upload_section(unsigned long long id, int pass,
                         double ox, double oy, double oz,
                         const void* verts, int vertCount,
                         const unsigned int* indices, int indexCount) {
    if (!g_device) FAIL("renderer not created");
    PbSection* s = find_section(id, pass);
    if (s) free_section(s);
    if (vertCount == 0 || indexCount == 0) return 0;   // empty = removed
    for (int i = 0; i < MAX_SECTIONS; i++) {
        if (g_sections[i].pass == -1) { s = &g_sections[i]; break; }
    }
    if (!s) FAIL("out of section slots (%d)", MAX_SECTIONS);
    if (make_buffer((VkDeviceSize)vertCount * 28, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                    &s->vbuf, &s->vmem, verts) != 0) return -1;
    if (make_buffer((VkDeviceSize)indexCount * 4, VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                    &s->ibuf, &s->imem, indices) != 0) return -1;
    s->id = id;
    s->pass = pass;
    s->ox = ox; s->oy = oy; s->oz = oz;
    s->indexCount = (uint32_t)indexCount;
    return 0;
}

void pb_vk_remove_section(unsigned long long id, int pass) {
    PbSection* s = find_section(id, pass);
    if (s) free_section(s);
}

void pb_vk_clear_sections(void) {
    if (!g_device) return;
    for (int i = 0; i < MAX_SECTIONS; i++) {
        if (g_sections[i].pass != -1) free_section(&g_sections[i]);
    }
}

void pb_vk_set_camera(const float* viewProj16,
                      double camX, double camY, double camZ,
                      float time, float dayLight, float gammaB, float ambient,
                      float fogStart, float fogEnd, float alphaTest,
                      float fogR, float fogG, float fogB) {
    memcpy(g_push.viewProj, viewProj16, 64);
    g_camX = camX; g_camY = camY; g_camZ = camZ;
    g_push.origin[3] = time;
    g_push.light[0] = dayLight;
    g_push.light[1] = gammaB;
    g_push.light[2] = ambient;
    g_push.light[3] = 1.0f;          // procedural fluid animation on
    g_push.fog[0] = fogStart;
    g_push.fog[1] = fogEnd;
    g_push.fog[2] = 0.0f;            // per-pass alpha test set at draw time
    g_push.fog[3] = 1.0f;            // global alpha
    g_push.fogColor[0] = fogR;
    g_push.fogColor[1] = fogG;
    g_push.fogColor[2] = fogB;
    g_push.fogColor[3] = 1.0f;
    g_cutoutAlphaTest = alphaTest;
    g_worldDraws = 1;
}

// ---- sky: environment, stars, pack art -------------------------------------
// Call once per frame AFTER pb_vk_set_camera — starAlpha, the cloud scroll
// and the cloud fade all read the day-light/time/fog that call installs.
void pb_vk_set_sky(int drawSky, int overworld, int endDim, int drawClouds,
                   const float* zenith3, const float* horizon3,
                   float sunGlow, const float* sunDir3,
                   float rainLevel, int dayPhase) {
    g_sky.on = drawSky;
    g_sky.overworld = overworld;
    g_sky.endDim = endDim;
    g_sky.clouds = drawClouds;
    for (int i = 0; i < 3; i++) {
        g_sky.zenith[i] = zenith3[i];
        g_sky.horizon[i] = horizon3[i];
        g_sky.sunDir[i] = sunDir3[i];
    }
    g_sky.sunGlow = sunGlow;
    g_sky.rainLevel = rainLevel;
    g_sky.dayPhase = dayPhase;
}

int pb_vk_upload_stars(const void* verts, int count) {
    if (!g_device) FAIL("renderer not created");
    if (count < 0 || count > MAX_STARS) FAIL("star count out of range");
    if (g_starBuf) {
        vkDeviceWaitIdle(g_device);
        vkDestroyBuffer(g_device, g_starBuf, NULL);
        vkFreeMemory(g_device, g_starMem, NULL);
        g_starBuf = NULL;
        g_starMem = NULL;
    }
    g_starCount = 0;
    if (count == 0) return 0;
    if (make_buffer((VkDeviceSize)count * 16, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                    &g_starBuf, &g_starMem, verts) != 0) return -1;
    g_starCount = count;
    return 0;
}

int pb_vk_upload_sky_tex(int which, const unsigned char* rgba, int w, int h) {
    if (!g_device) FAIL("renderer not created");
    if (which < 0 || which >= SKY_TEX_COUNT) FAIL("sky texture id out of range");
    if (w <= 0 || h <= 0) FAIL("sky texture has no pixels");
    PbSkyTex* t = &g_skyTex[which];
    if (t->used) return 0;   // static for the run — first upload wins
    if (upload_texture(rgba, w, h, 1, VK_IMAGE_VIEW_TYPE_2D, &t->tex, &t->mem, &t->view) != 0)
        return -1;
    VkSampler smp = which == SKY_TEX_CLOUD ? g_cloudSampler : g_linearSampler;
    if (make_sampler_set2(t->view, smp, &t->set) != 0) return -1;
    t->used = 1;
    return 0;
}

static void set_full_viewport(VkCommandBuffer cmd);

/// the pack's composed GUI sheet (RGBA8). One upload at startup; passing a
/// null pointer drops back to the canvas atlas everywhere.
int pb_vk_upload_gui_sheet(const unsigned char* rgba, int w, int h) {
    if (!g_device) FAIL("renderer not created");
    if (!rgba || w <= 0 || h <= 0) return 0;
    if (g_guiImage) return 0;   // first upload wins, like the entity skins
    if (upload_texture(rgba, w, h, 1, VK_IMAGE_VIEW_TYPE_2D,
                       &g_guiImage, &g_guiMem, &g_guiView) != 0) return -1;
    if (make_sampler_set(g_guiView, &g_guiSet) != 0) return -1;
    return 0;
}

/// which slice of this frame's UI stream samples which texture. `segs` is
/// pairs of (gui, firstVertex), in order; the last runs to the end.
void pb_vk_ui_set_segments(const int* segs, int pairCount) {
    g_uiSegCount = 0;
    if (!segs || pairCount <= 0) return;
    if (pairCount > MAX_UI_SEGMENTS) pairCount = MAX_UI_SEGMENTS;
    for (int i = 0; i < pairCount; i++) {
        g_uiSegs[i].gui = segs[i * 2];
        g_uiSegs[i].first = segs[i * 2 + 1];
        g_uiSegs[i].count = 0;
    }
    for (int i = 0; i < pairCount; i++) {
        int end = (i + 1 < pairCount) ? g_uiSegs[i + 1].first : g_uiVertCount;
        g_uiSegs[i].count = end - g_uiSegs[i].first;
        if (g_uiSegs[i].count < 0) g_uiSegs[i].count = 0;
    }
    g_uiSegCount = pairCount;
}

static void wait_frame_slot(void);

/// an extra chunk-stream mesh at a world origin: falling blocks / TNT and the
/// block-break crack overlay. Re-uploading a slot replaces it; vertCount 0
/// (or pb_vk_clear_overlay_mesh) drops it.
int pb_vk_set_overlay_mesh(int slot, int pass, float alphaTest,
                           double ox, double oy, double oz,
                           const void* verts, int vertCount,
                           const unsigned int* indices, int indexCount) {
    if (!g_device) FAIL("renderer not created");
    if (slot < 0 || slot >= OVERLAY_COUNT) FAIL("overlay slot out of range");
    PbOverlayMesh* m = &g_overlay[slot];
    m->indexCount = 0;
    if (vertCount <= 0 || indexCount <= 0 || !verts || !indices) return 0;
    if (vertCount > MAX_OVERLAY_VERTS || indexCount > MAX_OVERLAY_INDICES)
        FAIL("overlay mesh too big (%d verts, %d indices)", vertCount, indexCount);
    wait_frame_slot();
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    if (!m->vmap[f] || !m->imap[f]) return -1;
    memcpy(m->vmap[f], verts, (size_t)vertCount * 28);
    memcpy(m->imap[f], indices, (size_t)indexCount * 4);
    m->pass = pass;
    m->alphaTest = alphaTest;
    m->ox = ox;
    m->oy = oy;
    m->oz = oz;
    m->indexCount = (uint32_t)indexCount;
    return 0;
}

void pb_vk_clear_overlay_mesh(int slot) {
    if (slot < 0 || slot >= OVERLAY_COUNT) return;
    g_overlay[slot].indexCount = 0;
}

/// draw one overlay slot with the chunk pipeline the caller asked for
static void draw_overlay(VkCommandBuffer cmd, int slot) {
    PbOverlayMesh* m = &g_overlay[slot];
    if (m->indexCount == 0 || !g_atlasSet) return;
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeLayout,
                            0, 1, &g_atlasSet, 0, NULL);
    PbPush push = g_push;
    push.fog[2] = m->alphaTest;
    push.fogColor[3] = (float)g_atlasCols;
    push.origin[0] = (float)(m->ox - g_camX);
    push.origin[1] = (float)(m->oy - g_camY);
    push.origin[2] = (float)(m->oz - g_camZ);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
                      m->pass == 2 ? g_pipeTranslucent : g_pipeOpaque);
    vkCmdPushConstants(cmd, g_pipeLayout,
                       VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                       0, sizeof push, &push);
    VkDeviceSize zero = 0;
    vkCmdBindVertexBuffers(cmd, 0, 1, &m->vbuf[f], &zero);
    vkCmdBindIndexBuffer(cmd, m->ibuf[f], 0, VK_INDEX_TYPE_UINT32);
    vkCmdDrawIndexed(cmd, m->indexCount, 1, 0, 0, 0);
}

// ---- the first-person viewmodel -------------------------------------------
// The arm and the held item live in VIEW space, so they take the projection
// alone rather than the full view-projection.
void pb_vk_set_viewmodel_proj(const float* proj16) {
    memcpy(g_vmProj, proj16, 64);
}

void pb_vk_begin_viewmodel(void) {
    g_vmDrawCount = 0;
}

void pb_vk_push_viewmodel(int geomId, const float* model16, float brightness, float alpha) {
    if (g_vmDrawCount >= MAX_VM_DRAWS) return;
    if (geomId < 0 || geomId >= MAX_ENTITY_GEOMS || !g_entGeoms[geomId].used) return;
    PbEntityDraw* d = &g_vmDraws[g_vmDrawCount];
    // the viewmodel is never posed — its slots sit above the entity ones
    d->partsSlot = MAX_ENTITY_DRAWS + g_vmDrawCount;
    stash_parts(d->partsSlot, NULL);
    g_vmDrawCount++;
    d->geomId = geomId;
    mat4_mul(d->push.mvp, g_vmProj, model16);
    d->push.light[0] = brightness;
    d->push.light[1] = 0.0f;
    d->push.light[2] = 0.0f;
    d->push.light[3] = alpha;   // the shader reads alpha from .w, like entities
}

/// the viewmodel goes last, over everything, with no depth test
static void record_viewmodel(VkCommandBuffer cmd) {
    if (g_vmDrawCount == 0) return;
    set_full_viewport(cmd);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeViewmodel);
    int lastGeom = -1;
    for (int i = 0; i < g_vmDrawCount; i++) {
        PbEntityDraw* d = &g_vmDraws[i];
        PbEntityGeom* gm = &g_entGeoms[d->geomId];
        uint32_t off = parts_offset(d->partsSlot);
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_entLayout,
                                0, 1, &gm->set, 1, &off);
        if (d->geomId != lastGeom) {
            VkDeviceSize zero = 0;
            vkCmdBindVertexBuffers(cmd, 0, 1, &gm->vbuf, &zero);
            lastGeom = d->geomId;
        }
        vkCmdPushConstants(cmd, g_entLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, sizeof d->push, &d->push);
        vkCmdDraw(cmd, gm->vertCount, 1, 0, 0);
    }
}

static void set_full_viewport(VkCommandBuffer cmd) {
    VkViewport vpt = { 0, 0, (float)g_extent.width, (float)g_extent.height, 0, 1 };
    VkRect2D sc = { { 0, 0 }, g_extent };
    vkCmdSetViewport(cmd, 0, 1, &vpt);
    vkCmdSetScissor(cmd, 0, 1, &sc);
}

/// one sun/moon billboard — the Mac's drawCelestial, basis and all
static void draw_celestial(VkCommandBuffer cmd, const float* cdir, int texId,
                           float moonPhase, float texMode) {
    const PbSkyTex* t = &g_skyTex[texId];
    // vanilla quads are ±30/±20 at distance 100 — the art carries its own
    // padding+glow, so textured quads are much larger
    float size;
    if (texId == SKY_TEX_SUN) size = t->used ? 150.0f : 55.0f;
    else                      size = t->used ? 100.0f : 38.0f;

    // up0 = (0,0,1); right = normalize(cross(cdir, up0)); up = cross(right, cdir)
    float right[3] = { cdir[1], -cdir[0], 0.0f };
    float rl = sqrtf(right[0] * right[0] + right[1] * right[1] + right[2] * right[2]);
    if (rl < 1e-6f) {
        right[0] = 1.0f; right[1] = 0.0f; right[2] = 0.0f;
    } else {
        right[0] /= rl; right[1] /= rl; right[2] /= rl;
    }
    float up[3] = {
        right[1] * cdir[2] - right[2] * cdir[1],
        right[2] * cdir[0] - right[0] * cdir[2],
        right[0] * cdir[1] - right[1] * cdir[0],
    };

    PbCelPush cu;
    memcpy(cu.viewProj, g_push.viewProj, sizeof cu.viewProj);
    cu.center[0] = cdir[0] * 500.0f;
    cu.center[1] = cdir[1] * 500.0f;
    cu.center[2] = cdir[2] * 500.0f;
    cu.center[3] = size;
    cu.right[0] = right[0];
    cu.right[1] = right[1];
    cu.right[2] = right[2];
    cu.right[3] = t->used ? texMode : 0.0f;
    cu.up[0] = up[0];
    cu.up[1] = up[1];
    cu.up[2] = up[2];
    cu.up[3] = moonPhase;

    VkDescriptorSet set = t->used ? t->set : g_dummySet;
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
                      t->used ? g_pipeCelestialAdd : g_pipeCelestial);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_celLayout,
                            0, 1, &set, 0, NULL);
    vkCmdPushConstants(cmd, g_celLayout,
                       VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                       0, sizeof cu, &cu);
    vkCmdDraw(cmd, 6, 1, 0, 0);
}

/// sky dome + stars + sun/moon — recorded before any world geometry, with
/// no depth at all, exactly the order the Mac's scene pass uses
static void record_sky_draws(VkCommandBuffer cmd) {
    if (!g_sky.on) return;
    PbSkyPush sp;
    if (mat4_invert(sp.invViewProj, g_push.viewProj) != 0) return;
    set_full_viewport(cmd);

    for (int i = 0; i < 3; i++) {
        sp.zenith[i] = g_sky.zenith[i];
        sp.horizon[i] = g_sky.horizon[i];
        sp.sunDir[i] = g_sky.sunDir[i];
    }
    sp.zenith[3] = 0.0f;
    sp.horizon[3] = 0.0f;
    sp.horizonSun[0] = 1.0f;
    sp.horizonSun[1] = 0.45f;
    sp.horizonSun[2] = 0.18f;
    sp.horizonSun[3] = g_sky.sunGlow;
    sp.sunDir[3] = g_sky.endDim ? 1.0f : 0.0f;
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeSky);
    vkCmdPushConstants(cmd, g_skyLayout,
                       VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                       0, sizeof sp, &sp);
    vkCmdDraw(cmd, 3, 1, 0, 0);

    if (!g_sky.overworld) return;

    float starAlpha = 1.0f - g_push.light[0] * 1.6f;
    if (starAlpha < 0.0f) starAlpha = 0.0f;
    if (starAlpha > 1.0f) starAlpha = 1.0f;
    starAlpha *= 1.0f - g_sky.rainLevel;
    if (starAlpha > 0.01f && g_starCount > 0 && g_starBuf) {
        PbStarsPush st;
        memcpy(st.viewProj, g_push.viewProj, sizeof st.viewProj);
        st.params[0] = g_push.origin[3];   // seconds since start
        st.params[1] = starAlpha;
        st.params[2] = (float)g_extent.width;
        st.params[3] = (float)g_extent.height;
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeStars);
        vkCmdPushConstants(cmd, g_starsLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, sizeof st, &st);
        VkDeviceSize zero = 0;
        vkCmdBindVertexBuffers(cmd, 0, 1, &g_starBuf, &zero);
        vkCmdDraw(cmd, 6, (uint32_t)g_starCount, 0, 0);
    }

    if (g_sky.rainLevel < 0.95f) {
        draw_celestial(cmd, g_sky.sunDir, SKY_TEX_SUN, -1.0f, 1.0f);
        int ph = g_sky.dayPhase & 7;
        float phase = fmodf((float)ph / 8.0f + 0.5f, 1.0f);
        float moonDir[3] = { -g_sky.sunDir[0], -g_sky.sunDir[1], -g_sky.sunDir[2] };
        draw_celestial(cmd, moonDir, SKY_TEX_MOON, phase, 1.0f + (float)ph);
    }
}

/// the cloud plane — after the translucent pass, like the Mac
static void record_cloud_draws(VkCommandBuffer cmd) {
    if (!g_sky.on || !g_sky.overworld || !g_sky.clouds) return;
    const PbSkyTex* t = &g_skyTex[SKY_TEX_CLOUD];
    if (!t->used) return;
    set_full_viewport(cmd);

    PbCloudPush cu;
    memcpy(cu.viewProj, g_push.viewProj, sizeof cu.viewProj);
    cu.offset[0] = 0.0f;
    cu.offset[1] = (float)(192.33 - g_camY);
    cu.offset[2] = 0.0f;
    cu.offset[3] = 2048.0f;
    double scroll = (double)g_push.origin[3] * 0.0006;
    cu.scroll[0] = (float)fmod(g_camX / 4096.0 + scroll, 1.0);
    cu.scroll[1] = (float)fmod(g_camZ / 4096.0, 1.0);
    cu.scroll[2] = 0.75f + g_push.light[0] * 0.25f;
    cu.scroll[3] = g_push.fog[1] * 2.5f;
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeCloud);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_cloudLayout,
                            0, 1, &t->set, 0, NULL);
    vkCmdPushConstants(cmd, g_cloudLayout,
                       VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                       0, sizeof cu, &cu);
    vkCmdDraw(cmd, 6, 1, 0, 0);
}

// ---- world detail: lines, particles, item sprites --------------------------
/// Per-frame streams are filled BEFORE pb_vk_frame waits on this slot's
/// fence, so with two frames in flight the GPU may still be reading the very
/// buffer about to be overwritten. Wait here instead: by this point the frame
/// two back has almost always finished, so it costs nothing and closes the
/// race. Bounded rather than infinite — a torn frame beats a hung window if a
/// submit ever failed and left the fence unsignalled.
static void wait_frame_slot(void) {
    if (!g_device) return;
    vkWaitForFences(g_device, 1, &g_fence[g_frame % FRAMES_IN_FLIGHT], VK_TRUE, 1000000000ull);
}

// All three are per-frame streams: set them after pb_vk_set_camera and before
// pb_vk_frame, or leave them at zero to skip the pass.
void pb_vk_begin_lines(void) {
    g_lineVertCount = 0;
    g_lineBatchCount = 0;
}

void pb_vk_push_lines(const float* verts, int vertCount, int tris,
                      float r, float g, float b, float a) {
    if (!g_device || !verts || vertCount <= 0) return;
    if (g_lineBatchCount >= MAX_LINE_BATCHES) return;
    if (g_lineVertCount + vertCount > MAX_LINE_VERTS) return;   // frame is full
    wait_frame_slot();
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    if (!g_lineVmap[f]) return;
    memcpy((char*)g_lineVmap[f] + (size_t)g_lineVertCount * LINE_STRIDE,
           verts, (size_t)vertCount * LINE_STRIDE);
    PbLineBatch* b0 = &g_lineBatches[g_lineBatchCount++];
    b0->first = g_lineVertCount;
    b0->count = vertCount;
    b0->tris = tris;
    b0->color[0] = r;
    b0->color[1] = g;
    b0->color[2] = b;
    b0->color[3] = a;
    g_lineVertCount += vertCount;
}

void pb_vk_set_particles(const void* instances, int count,
                         const float* right3, const float* up3) {
    g_partCount = 0;
    if (!g_device || !instances || count <= 0) return;
    if (count > MAX_PARTICLES) count = MAX_PARTICLES;
    wait_frame_slot();
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    if (!g_partVmap[f]) return;
    memcpy(g_partVmap[f], instances, (size_t)count * PARTICLE_STRIDE);
    g_partCount = count;
    for (int i = 0; i < 3; i++) {
        g_partRight[i] = right3[i];
        g_partUp[i] = up3[i];
    }
}

void pb_vk_set_sprites(const void* instances, int count, const float* right3) {
    g_sprCount = 0;
    if (!g_device || !instances || count <= 0) return;
    if (count > MAX_SPRITES) count = MAX_SPRITES;
    wait_frame_slot();
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    if (!g_sprVmap[f]) return;
    memcpy(g_sprVmap[f], instances, (size_t)count * SPRITE_STRIDE);
    g_sprCount = count;
    for (int i = 0; i < 3; i++) g_sprRight[i] = right3[i];
}

int pb_vk_sprite_atlas_update(int x, int y, int w, int h, const unsigned char* rgba) {
    if (g_sprRectCount >= MAX_SPRITE_RECTS) return -1;
    if (w <= 0 || h <= 0 || !rgba) return -1;
    size_t bytes = (size_t)w * h * 4;
    unsigned char* copy = (unsigned char*)malloc(bytes);
    if (!copy) return -1;
    memcpy(copy, rgba, bytes);
    PbUIRect* r = &g_sprRects[g_sprRectCount++];
    r->x = x;
    r->y = y;
    r->w = w;
    r->h = h;
    r->pixels = copy;
    return 0;
}

/// item billboards, the selection outline and particles — recorded between
/// the entity pass and the translucent pass, where the Mac draws them
static void record_detail_draws(VkCommandBuffer cmd) {
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    VkDeviceSize zero = 0;

    if (g_sprCount > 0 && g_sprImageReady) {
        PbSpritePush sp;
        memcpy(sp.viewProj, g_push.viewProj, sizeof sp.viewProj);
        sp.right[0] = g_sprRight[0];
        sp.right[1] = g_sprRight[1];
        sp.right[2] = g_sprRight[2];
        sp.right[3] = 0.0f;
        sp.fog[0] = g_push.fog[0];
        sp.fog[1] = g_push.fog[1];
        sp.fog[2] = 0.0f;
        sp.fog[3] = 0.0f;
        memcpy(sp.fogColor, g_push.fogColor, sizeof sp.fogColor);
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeSprite);
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_spriteLayout,
                                0, 1, &g_sprSet, 0, NULL);
        vkCmdPushConstants(cmd, g_spriteLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, sizeof sp, &sp);
        vkCmdBindVertexBuffers(cmd, 0, 1, &g_sprVbuf[f], &zero);
        vkCmdDraw(cmd, 6, (uint32_t)g_sprCount, 0, 0);
    }

    // the Mac's order: sprites, then the cubes and the crack, then the
    // selection outline, then the particles
    draw_overlay(cmd, OVERLAY_CUBES);   // falling blocks / TNT, opaque
    draw_overlay(cmd, OVERLAY_CRACK);   // the break overlay, translucent
    if (g_lineBatchCount > 0) {
        // the overlays bound the terrain set on the chunk layout; the line
        // pipeline has no descriptor set at all, so nothing to restore
        PbLinePush lp;
        memcpy(lp.viewProj, g_push.viewProj, sizeof lp.viewProj);
        vkCmdBindVertexBuffers(cmd, 0, 1, &g_lineVbuf[f], &zero);
        int lastTris = -1;
        for (int i = 0; i < g_lineBatchCount; i++) {
            PbLineBatch* b0 = &g_lineBatches[i];
            if (b0->tris != lastTris) {
                vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                  b0->tris ? g_pipeLineTris : g_pipeLines);
                lastTris = b0->tris;
            }
            memcpy(lp.color, b0->color, sizeof lp.color);
            vkCmdPushConstants(cmd, g_lineLayout,
                               VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                               0, sizeof lp, &lp);
            vkCmdDraw(cmd, (uint32_t)b0->count, 1, (uint32_t)b0->first, 0);
        }
    }

    if (g_partCount > 0 && g_atlasSetPlain) {
        PbParticlePush pp;
        memcpy(pp.viewProj, g_push.viewProj, sizeof pp.viewProj);
        pp.right[0] = g_partRight[0];
        pp.right[1] = g_partRight[1];
        pp.right[2] = g_partRight[2];
        pp.right[3] = 0.0f;
        pp.up[0] = g_partUp[0];
        pp.up[1] = g_partUp[1];
        pp.up[2] = g_partUp[2];
        pp.up[3] = g_push.light[0];        // dayLight
        pp.misc[0] = (float)g_atlasCols;
        pp.misc[1] = 0.0f;
        pp.misc[2] = 0.0f;
        pp.misc[3] = 0.0f;
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeParticle);
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_particleLayout,
                                0, 1, &g_atlasSetPlain, 0, NULL);
        vkCmdPushConstants(cmd, g_particleLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, sizeof pp, &pp);
        vkCmdBindVertexBuffers(cmd, 0, 1, &g_partVbuf[f], &zero);
        vkCmdDraw(cmd, 6, (uint32_t)g_partCount, 0, 0);
    }
}

static void draw_pass(VkCommandBuffer cmd, int pass, float alphaTest) {
    PbPush push = g_push;
    push.fog[2] = alphaTest;
    push.fogColor[3] = (float)g_atlasCols;
    for (int i = 0; i < MAX_SECTIONS; i++) {
        PbSection* s = &g_sections[i];
        if (s->pass != pass) continue;
        push.origin[0] = (float)(s->ox - g_camX);
        push.origin[1] = (float)(s->oy - g_camY);
        push.origin[2] = (float)(s->oz - g_camZ);
        vkCmdPushConstants(cmd, g_pipeLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                           0, sizeof push, &push);
        VkDeviceSize zero = 0;
        vkCmdBindVertexBuffers(cmd, 0, 1, &s->vbuf, &zero);
        vkCmdBindIndexBuffer(cmd, s->ibuf, 0, VK_INDEX_TYPE_UINT32);
        vkCmdDrawIndexed(cmd, s->indexCount, 1, 0, 0, 0);
    }
}

static void record_world_draws(VkCommandBuffer cmd) {
    if (!g_atlasSet) return;   // no atlas yet — sky only
    VkViewport vpt = { 0, 0, (float)g_extent.width, (float)g_extent.height, 0, 1 };
    VkRect2D sc = { { 0, 0 }, g_extent };
    vkCmdSetViewport(cmd, 0, 1, &vpt);
    vkCmdSetScissor(cmd, 0, 1, &sc);
    uint32_t shOff = (uint32_t)((g_frame % FRAMES_IN_FLIGHT) * g_shadowUboStride);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeLayout,
                            0, 1, &g_atlasSet, 1, &shOff);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeOpaque);
    draw_pass(cmd, 0, 0.0f);              // opaque
    draw_pass(cmd, 1, g_cutoutAlphaTest); // cutout (leaves/plants) — discard
    if (g_entDrawCount > 0) {             // mobs + other players
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeEntity);
        int lastGeom = -1;
        for (int i = 0; i < g_entDrawCount; i++) {
            PbEntityDraw* d = &g_entDraws[i];
            PbEntityGeom* gm = &g_entGeoms[d->geomId];
            // the pose slot changes every draw, so the set is rebound each
            // time; only the vertex buffer can be skipped
            uint32_t off = parts_offset(d->partsSlot);
            vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_entLayout,
                                    0, 1, &gm->set, 1, &off);
            if (d->geomId != lastGeom) {
                VkDeviceSize zero = 0;
                vkCmdBindVertexBuffers(cmd, 0, 1, &gm->vbuf, &zero);
                lastGeom = d->geomId;
            }
            vkCmdPushConstants(cmd, g_entLayout,
                               VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                               0, sizeof d->push, &d->push);
            vkCmdDraw(cmd, gm->vertCount, 1, 0, 0);
        }
    }
    record_detail_draws(cmd);
    // every pass above binds its own pipeline layout — put the terrain set
    // back before the translucent chunks go out
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeLayout,
                            0, 1, &g_atlasSet, 1, &shOff);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeTranslucent);
    draw_pass(cmd, 2, 0.0f);              // water/glass — blended
}

// register a UI image (title photo, wordmark) — straight RGBA8, linear-filtered
int pb_vk_upload_image(int id, const unsigned char* rgba, int w, int h) {
    if (!g_device) FAIL("renderer not created");
    if (id < 0 || id >= MAX_UI_IMAGES) FAIL("image id out of range");
    PbUIImage* im = &g_uiImages[id];
    if (im->used) return 0;
    if (upload_texture(rgba, w, h, 1, VK_IMAGE_VIEW_TYPE_2D, &im->tex, &im->mem, &im->view) != 0)
        return -1;
    if (make_sampler_set2(im->view, g_linearSampler, &im->set) != 0) return -1;
    im->used = 1;
    return 0;
}

// draw an image quad UNDER this frame's canvas verts (GUI units + UV rect)
void pb_vk_ui_push_image(int id, float x, float y, float w, float h,
                         float u0, float v0, float u1, float v1) {
    if (id < 0 || id >= MAX_UI_IMAGES || !g_uiImages[id].used) return;
    if (g_imgQuadCount >= MAX_UI_IMAGES) return;
    PbImageQuad* q = &g_imgQuads[g_imgQuadCount++];
    q->id = id; q->x = x; q->y = y; q->w = w; q->h = h;
    q->u0 = u0; q->v0 = v0; q->u1 = u1; q->v1 = v1;
}

// queue a dirty canvas-atlas cell (pixels copied; uploaded next frame)
void pb_vk_ui_update_atlas(int x, int y, int w, int h, const unsigned char* rgba) {
    if (g_uiRectCount >= MAX_UI_RECTS) return;
    size_t bytes = (size_t)w * h * 4;
    unsigned char* copy = (unsigned char*)malloc(bytes);
    if (!copy) return;
    memcpy(copy, rgba, bytes);
    PbUIRect* r = &g_uiRects[g_uiRectCount++];
    r->x = x; r->y = y; r->w = w; r->h = h;
    r->pixels = copy;
}

// the frame's UI vertex stream (32B stride) in GUI units
void pb_vk_ui_set_frame(const float* verts, int floatCount, float screenW, float screenH) {
    if (!g_device) return;
    wait_frame_slot();
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    VkDeviceSize need = (VkDeviceSize)floatCount * 4;
    g_uiVertCount = 0;
    g_uiScreen[0] = screenW;
    g_uiScreen[1] = screenH;
    if (floatCount <= 0) return;
    if (need > g_uiVcap[f]) {
        vkDeviceWaitIdle(g_device);
        if (g_uiVbuf[f]) {
            vkDestroyBuffer(g_device, g_uiVbuf[f], NULL);
            vkFreeMemory(g_device, g_uiVmem[f], NULL);
            g_uiVbuf[f] = NULL;
        }
        VkDeviceSize cap = need < (1 << 20) ? (1 << 20) : need * 2;
        if (make_buffer(cap, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                        &g_uiVbuf[f], &g_uiVmem[f], NULL) != 0) return;
        if (vkMapMemory(g_device, g_uiVmem[f], 0, cap, 0, &g_uiVmap[f]) != VK_SUCCESS) return;
        g_uiVcap[f] = cap;
    }
    memcpy(g_uiVmap[f], verts, (size_t)need);
    g_uiVertCount = floatCount / 8;
}

/// upload queued atlas cells — records into cmd BEFORE the render pass
/// upload a frame's worth of dirty rects into one sampled image. Shared by
/// the UI canvas and the item-icon atlas — same staging path, same barriers.
static void flush_atlas_rects(VkCommandBuffer cmd, VkImage image,
                              PbUIRect* rects, int* rectCount, int* ready) {
    if (*rectCount == 0) return;
    // one staging buffer for all rects this frame
    VkDeviceSize total = 0;
    for (int i = 0; i < *rectCount; i++) total += (VkDeviceSize)rects[i].w * rects[i].h * 4;
    VkBuffer staging;
    VkDeviceMemory stagingMem;
    if (make_buffer(total, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &staging, &stagingMem, NULL) != 0) {
        for (int i = 0; i < *rectCount; i++) free(rects[i].pixels);
        *rectCount = 0;
        return;
    }
    void* map = NULL;
    vkMapMemory(g_device, stagingMem, 0, total, 0, &map);
    VkDeviceSize off = 0;
    for (int i = 0; i < *rectCount; i++) {
        size_t bytes = (size_t)rects[i].w * rects[i].h * 4;
        memcpy((char*)map + off, rects[i].pixels, bytes);
        free(rects[i].pixels);
        rects[i].pixels = NULL;
        off += bytes;
    }
    vkUnmapMemory(g_device, stagingMem);

    VkImageMemoryBarrier bar = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    bar.srcAccessMask = (*ready) ? VK_ACCESS_SHADER_READ_BIT : 0;
    bar.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    bar.oldLayout = (*ready) ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED;
    bar.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    bar.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bar.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bar.image = image;
    bar.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    bar.subresourceRange.levelCount = 1;
    bar.subresourceRange.layerCount = 1;
    vkCmdPipelineBarrier(cmd, (*ready) ? VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
    off = 0;
    for (int i = 0; i < *rectCount; i++) {
        VkBufferImageCopy copy = { 0 };
        copy.bufferOffset = off;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageOffset.x = rects[i].x;
        copy.imageOffset.y = rects[i].y;
        copy.imageExtent.width = (uint32_t)rects[i].w;
        copy.imageExtent.height = (uint32_t)rects[i].h;
        copy.imageExtent.depth = 1;
        vkCmdCopyBufferToImage(cmd, staging, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        off += (VkDeviceSize)rects[i].w * rects[i].h * 4;
    }
    bar.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    bar.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    bar.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    bar.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
    *ready = 1;
    *rectCount = 0;
    // the staging buffer retires with the frame fence — leak-free enough for
    // load bursts would need a retire list; UI cells are tiny, wait instead
    vkQueueWaitIdle(g_queue);
    vkDestroyBuffer(g_device, staging, NULL);
    vkFreeMemory(g_device, stagingMem, NULL);
}

static void flush_ui_atlas(VkCommandBuffer cmd) {
    flush_atlas_rects(cmd, g_uiImage, g_uiRects, &g_uiRectCount, &g_uiImageReady);
}

static void flush_sprite_atlas(VkCommandBuffer cmd) {
    flush_atlas_rects(cmd, g_sprImage, g_sprRects, &g_sprRectCount, &g_sprImageReady);
}

static void record_ui_draws(VkCommandBuffer cmd) {
    if (g_uiVertCount == 0 && g_imgQuadCount == 0) return;
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    VkViewport vpt = { 0, 0, (float)g_extent.width, (float)g_extent.height, 0, 1 };
    VkRect2D sc = { { 0, 0 }, g_extent };
    vkCmdSetViewport(cmd, 0, 1, &vpt);
    vkCmdSetScissor(cmd, 0, 1, &sc);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeUI);
    vkCmdPushConstants(cmd, g_uiLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, 16, g_uiScreen);

    // background images first (title photo, wordmark) — under the canvas
    if (g_imgQuadCount > 0) {
        if (!g_imgVbuf[f]) {
            if (make_buffer(MAX_UI_IMAGES * 6 * 32, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                            &g_imgVbuf[f], &g_imgVmem[f], NULL) != 0) { g_imgQuadCount = 0; return; }
            vkMapMemory(g_device, g_imgVmem[f], 0, MAX_UI_IMAGES * 6 * 32, 0, &g_imgVmap[f]);
        }
        float* v = (float*)g_imgVmap[f];
        for (int i = 0; i < g_imgQuadCount; i++) {
            PbImageQuad* q = &g_imgQuads[i];
            float quad[6][8] = {
                { q->x,        q->y,        q->u0, q->v0, 1, 1, 1, 1 },
                { q->x + q->w, q->y,        q->u1, q->v0, 1, 1, 1, 1 },
                { q->x + q->w, q->y + q->h, q->u1, q->v1, 1, 1, 1, 1 },
                { q->x,        q->y,        q->u0, q->v0, 1, 1, 1, 1 },
                { q->x + q->w, q->y + q->h, q->u1, q->v1, 1, 1, 1, 1 },
                { q->x,        q->y + q->h, q->u0, q->v1, 1, 1, 1, 1 },
            };
            memcpy(v + i * 48, quad, sizeof quad);
        }
        VkDeviceSize zero = 0;
        vkCmdBindVertexBuffers(cmd, 0, 1, &g_imgVbuf[f], &zero);
        for (int i = 0; i < g_imgQuadCount; i++) {
            vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_uiLayout,
                                    0, 1, &g_uiImages[g_imgQuads[i].id].set, 0, NULL);
            vkCmdDraw(cmd, 6, 1, (uint32_t)(i * 6), 0);
        }
        g_imgQuadCount = 0;
    }

    if (g_uiVertCount > 0 && g_uiImageReady) {
        VkDeviceSize zero = 0;
        vkCmdBindVertexBuffers(cmd, 0, 1, &g_uiVbuf[f], &zero);
        // one draw per segment, switching between the canvas atlas and the
        // pack's GUI sheet — the same split the Mac makes
        if (g_uiSegCount > 0 && g_guiSet) {
            int lastGui = -1;
            for (int i = 0; i < g_uiSegCount; i++) {
                if (g_uiSegs[i].count <= 0) continue;
                if (g_uiSegs[i].gui != lastGui) {
                    VkDescriptorSet set = g_uiSegs[i].gui ? g_guiSet : g_uiSet;
                    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_uiLayout,
                                            0, 1, &set, 0, NULL);
                    lastGui = g_uiSegs[i].gui;
                }
                vkCmdDraw(cmd, (uint32_t)g_uiSegs[i].count, 1, (uint32_t)g_uiSegs[i].first, 0);
            }
        } else {
            vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_uiLayout,
                                    0, 1, &g_uiSet, 0, NULL);
            vkCmdDraw(cmd, (uint32_t)g_uiVertCount, 1, 0, 0);
        }
    }
}

/// bloom: extract the bright parts at half res, then blur horizontally and
/// vertically. bloom[0] holds the result the composite reads.
static void record_bloom(VkCommandBuffer cmd) {
    VkViewport vpt = { 0, 0, (float)g_bloomExtent.width, (float)g_bloomExtent.height, 0, 1 };
    VkRect2D sc = { { 0, 0 }, g_bloomExtent };
    VkRenderPassBeginInfo bbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    bbi.renderPass = g_bloomPass;
    bbi.renderArea.extent = g_bloomExtent;

    struct { VkFramebuffer fb; VkDescriptorSet src; VkPipeline pipe; float dx, dy; } steps[3] = {
        { g_bloomFb[0], g_sceneSet,    g_pipeBloomExtract, 0, 0 },
        { g_bloomFb[1], g_bloomSet[0], g_pipeBlur, 1.0f / (float)g_bloomExtent.width, 0 },
        { g_bloomFb[0], g_bloomSet[1], g_pipeBlur, 0, 1.0f / (float)g_bloomExtent.height },
    };
    for (int i = 0; i < 3; i++) {
        bbi.framebuffer = steps[i].fb;
        vkCmdBeginRenderPass(cmd, &bbi, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdSetViewport(cmd, 0, 1, &vpt);
        vkCmdSetScissor(cmd, 0, 1, &sc);
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, steps[i].pipe);
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_bloomLayout,
                                0, 1, &steps[i].src, 0, NULL);
        float dir[4] = { steps[i].dx, steps[i].dy, 0, 0 };
        vkCmdPushConstants(cmd, g_bloomLayout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof dir, dir);
        vkCmdDraw(cmd, 3, 1, 0, 0);
        vkCmdEndRenderPass(cmd);
    }
}

/// SSAO + volumetrics at half res, then one separable blur. ultra[0] holds
/// the result the composite folds in.
static void record_ultra(VkCommandBuffer cmd) {
    if (!g_ultraOK || !g_ultraOn) return;
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    if (g_ultraUboMap) {
        memcpy((char*)g_ultraUboMap + (VkDeviceSize)f * g_ultraUboStride,
               g_ultraU, ULTRA_UBO_BYTES);
    }
    uint32_t uoff = (uint32_t)((VkDeviceSize)f * g_ultraUboStride);
    VkViewport vpt = { 0, 0, (float)g_ultraExtent.width, (float)g_ultraExtent.height, 0, 1 };
    VkRect2D sc = { { 0, 0 }, g_ultraExtent };
    VkRenderPassBeginInfo ubi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    ubi.renderPass = g_bloomPass;
    ubi.renderArea.extent = g_ultraExtent;

    // the pass itself, into ultra[0]
    ubi.framebuffer = g_ultraFb[0];
    vkCmdBeginRenderPass(cmd, &ubi, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdSetViewport(cmd, 0, 1, &vpt);
    vkCmdSetScissor(cmd, 0, 1, &sc);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeUltra);
    VkDescriptorSet usets[3] = { g_depthSet, g_shadowSamplerSet, g_ultraUboSet };
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_ultraLayout,
                            0, 3, usets, 1, &uoff);
    vkCmdDraw(cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(cmd);

    // blur it, keeping alpha (that is the occlusion term)
    struct { VkFramebuffer fb; VkDescriptorSet src; float dx, dy; } steps[2] = {
        { g_ultraFb[1], g_ultraSet[0], 1.0f / (float)g_ultraExtent.width, 0 },
        { g_ultraFb[0], g_ultraSet[1], 0, 1.0f / (float)g_ultraExtent.height },
    };
    for (int i = 0; i < 2; i++) {
        ubi.framebuffer = steps[i].fb;
        vkCmdBeginRenderPass(cmd, &ubi, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdSetViewport(cmd, 0, 1, &vpt);
        vkCmdSetScissor(cmd, 0, 1, &sc);
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeUltraBlur);
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_bloomLayout,
                                0, 1, &steps[i].src, 0, NULL);
        float dir[4] = { steps[i].dx, steps[i].dy, 0, 0 };
        vkCmdPushConstants(cmd, g_bloomLayout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof dir, dir);
        vkCmdDraw(cmd, 3, 1, 0, 0);
        vkCmdEndRenderPass(cmd);
    }
}

// the camera and sun state the ultra pass marches through: invViewProj,
// viewProj, shadowMat (16 floats each), then sunDir, params, fogColor, texel.
// `on` 0 skips the pass and switches the composite's ultra branch off.
void pb_vk_set_ultra(int on, const float* block64) {
    g_ultraOn = (on && g_ultraOK) ? 1 : 0;
    if (block64) memcpy(g_ultraU, block64, ULTRA_UBO_BYTES);
    g_post[8] = g_ultraOn ? 1.0f : 0.0f;
    g_post[9] = 0.85f;   // AO strength, the Mac's params2.y
    g_post[10] = 1.0f;   // volumetric strength, params2.z
    g_post[11] = 0.0f;
}

/// one fullscreen triangle: scene + bloom, tinted and tonemapped
static void record_composite(VkCommandBuffer cmd) {
    VkViewport vpt = { 0, 0, (float)g_extent.width, (float)g_extent.height, 0, 1 };
    VkRect2D sc = { { 0, 0 }, g_extent };
    vkCmdSetViewport(cmd, 0, 1, &vpt);
    vkCmdSetScissor(cmd, 0, 1, &sc);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeComposite);
    VkDescriptorSet sets[3] = { g_sceneSet, g_bloomSet[0],
                                g_ultraOn ? g_ultraSet[0] : g_sceneSet };
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_compositeLayout,
                            0, 3, sets, 0, NULL);
    vkCmdPushConstants(cmd, g_compositeLayout, VK_SHADER_STAGE_FRAGMENT_BIT,
                       0, sizeof g_post, g_post);
    vkCmdDraw(cmd, 3, 1, 0, 0);
}

// bloomAmt, warp, time and darkness plus an rgba tint — the Mac's
// CompositeUniforms, minus the ultra terms this backend has no pass for
void pb_vk_set_post(float bloomAmt, float warp, float time, float darkness,
                    float tintR, float tintG, float tintB, float tintA) {
    g_post[0] = bloomAmt;
    g_post[1] = warp;
    g_post[2] = time;
    g_post[3] = darkness;
    g_post[4] = tintR;
    g_post[5] = tintG;
    g_post[6] = tintB;
    g_post[7] = tintA;
}

// the sun's view-projection for this frame, and whether shadows are on at
// all (the Mac gates on settings, dimension, daylight and sun height)
void pb_vk_set_shadow(const float* shadowMat16, int enabled) {
    g_shadowOn = enabled ? 1 : 0;
    if (shadowMat16) memcpy(g_shadowMat, shadowMat16, 64);
}

/// fill this frame's shadow uniform slot; chunk.vert/frag read it through the
/// terrain descriptor set's dynamic offset
static void stash_shadow(void) {
    if (!g_shadowUboMap) return;
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    char* dst = (char*)g_shadowUboMap + (VkDeviceSize)f * g_shadowUboStride;
    memcpy(dst, g_shadowMat, 64);
    float* params = (float*)(dst + 64);
    params[0] = g_shadowOn ? 1.0f : 0.0f;
    params[1] = 1.0f / (float)SHADOW_SIZE;
    params[2] = 0.0f;
    params[3] = 0.0f;
}

/// the depth-only pass: every opaque and cutout section from the sun's side
static void record_shadow_pass(VkCommandBuffer cmd) {
    if (!g_shadowOn || !g_worldDraws) return;
    VkClearValue clear;
    clear.depthStencil.depth = 1.0f;
    clear.depthStencil.stencil = 0;
    VkRenderPassBeginInfo sbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    sbi.renderPass = g_shadowPass;
    sbi.framebuffer = g_shadowFb;
    sbi.renderArea.extent.width = SHADOW_SIZE;
    sbi.renderArea.extent.height = SHADOW_SIZE;
    sbi.clearValueCount = 1;
    sbi.pClearValues = &clear;
    vkCmdBeginRenderPass(cmd, &sbi, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport vpt = { 0, 0, (float)SHADOW_SIZE, (float)SHADOW_SIZE, 0, 1 };
    VkRect2D sc = { { 0, 0 }, { SHADOW_SIZE, SHADOW_SIZE } };
    vkCmdSetViewport(cmd, 0, 1, &vpt);
    vkCmdSetScissor(cmd, 0, 1, &sc);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeShadow);
    PbShadowPush push;
    memcpy(push.shadowMat, g_shadowMat, 64);
    push.origin[3] = 0.0f;
    for (int pass = 0; pass <= 1; pass++) {          // opaque, then cutout
        for (int i = 0; i < MAX_SECTIONS; i++) {
            PbSection* s = &g_sections[i];
            if (s->pass != pass) continue;
            push.origin[0] = (float)(s->ox - g_camX);
            push.origin[1] = (float)(s->oy - g_camY);
            push.origin[2] = (float)(s->oz - g_camZ);
            vkCmdPushConstants(cmd, g_shadowLayout, VK_SHADER_STAGE_VERTEX_BIT,
                               0, sizeof push, &push);
            VkDeviceSize zero = 0;
            vkCmdBindVertexBuffers(cmd, 0, 1, &s->vbuf, &zero);
            vkCmdBindIndexBuffer(cmd, s->ibuf, 0, VK_INDEX_TYPE_UINT32);
            vkCmdDrawIndexed(cmd, s->indexCount, 1, 0, 0, 0);
        }
    }
    vkCmdEndRenderPass(cmd);
}

int pb_vk_frame(float r, float g, float b) {
    if (!g_device) return 1;
    if (g_needRebuild || !g_swapchain) {
        vkDeviceWaitIdle(g_device);
        destroy_swapchain();
        g_needRebuild = 0;
        int rc = build_swapchain(g_pendingW, g_pendingH);
        if (rc != 0) return 1;   // minimized or transient failure — skip
    }

    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    vkWaitForFences(g_device, 1, &g_fence[f], VK_TRUE, UINT64_MAX);

    uint32_t idx = 0;
    VkResult ar = vkAcquireNextImageKHR(g_device, g_swapchain, UINT64_MAX,
                                        g_acquireSem[f], VK_NULL_HANDLE, &idx);
    if (ar == VK_ERROR_OUT_OF_DATE_KHR || ar == VK_ERROR_SURFACE_LOST_KHR) {
        g_needRebuild = 1;
        return 1;
    }
    if (ar != VK_SUCCESS && ar != VK_SUBOPTIMAL_KHR) return 1;

    vkResetFences(g_device, 1, &g_fence[f]);
    vkResetCommandBuffer(g_cmd[f], 0);

    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(g_cmd[f], &bi);
    stash_shadow();
    flush_ui_atlas(g_cmd[f]);
    flush_sprite_atlas(g_cmd[f]);
    VkClearValue clears[2];
    clears[0].color.float32[0] = r;
    clears[0].color.float32[1] = g;
    clears[0].color.float32[2] = b;
    clears[0].color.float32[3] = 1.0f;
    clears[1].depthStencil.depth = 1.0f;
    clears[1].depthStencil.stencil = 0;
    VkRenderPassBeginInfo rbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    rbi.renderPass = g_pass;
    rbi.framebuffer = g_fbs[idx];
    rbi.renderArea.extent = g_extent;
    rbi.clearValueCount = 2;
    rbi.pClearValues = clears;
    record_shadow_pass(g_cmd[f]);
    if (g_postOK) {
        // --- the world, into the offscreen scene target ---
        VkRenderPassBeginInfo sbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
        sbi.renderPass = g_scenePass;
        sbi.framebuffer = g_sceneFb;
        sbi.renderArea.extent = g_extent;
        sbi.clearValueCount = 2;
        sbi.pClearValues = clears;
        vkCmdBeginRenderPass(g_cmd[f], &sbi, VK_SUBPASS_CONTENTS_INLINE);
        record_sky_draws(g_cmd[f]);
        if (g_worldDraws) record_world_draws(g_cmd[f]);
        record_cloud_draws(g_cmd[f]);
        record_viewmodel(g_cmd[f]);
        vkCmdEndRenderPass(g_cmd[f]);

        // --- ultra (SSAO + volumetrics), then bloom ---
        record_ultra(g_cmd[f]);
        record_bloom(g_cmd[f]);

        // --- composite into the swapchain, then the UI on top ---
        vkCmdBeginRenderPass(g_cmd[f], &rbi, VK_SUBPASS_CONTENTS_INLINE);
        record_composite(g_cmd[f]);
        record_ui_draws(g_cmd[f]);
        vkCmdEndRenderPass(g_cmd[f]);
    } else {
        // no post chain — straight into the swapchain, as before
        vkCmdBeginRenderPass(g_cmd[f], &rbi, VK_SUBPASS_CONTENTS_INLINE);
        record_sky_draws(g_cmd[f]);
        if (g_worldDraws) record_world_draws(g_cmd[f]);
        record_cloud_draws(g_cmd[f]);
        record_viewmodel(g_cmd[f]);
        record_ui_draws(g_cmd[f]);
        vkCmdEndRenderPass(g_cmd[f]);
    }
    vkEndCommandBuffer(g_cmd[f]);

    VkPipelineStageFlags wait = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.waitSemaphoreCount = 1;
    si.pWaitSemaphores = &g_acquireSem[f];
    si.pWaitDstStageMask = &wait;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &g_cmd[f];
    si.signalSemaphoreCount = 1;
    si.pSignalSemaphores = &g_renderSem[idx];
    if (vkQueueSubmit(g_queue, 1, &si, g_fence[f]) != VK_SUCCESS) return 1;

    VkPresentInfoKHR pi = { VK_STRUCTURE_TYPE_PRESENT_INFO_KHR };
    pi.waitSemaphoreCount = 1;
    pi.pWaitSemaphores = &g_renderSem[idx];
    pi.swapchainCount = 1;
    pi.pSwapchains = &g_swapchain;
    pi.pImageIndices = &idx;
    VkResult pr = vkQueuePresentKHR(g_queue, &pi);
    if (pr == VK_ERROR_OUT_OF_DATE_KHR || pr == VK_SUBOPTIMAL_KHR) g_needRebuild = 1;

    g_frame++;
    return 0;
}

void pb_vk_destroy(void) {
    if (g_device) {
        vkDeviceWaitIdle(g_device);
        for (int i = 0; i < MAX_SECTIONS; i++) {
            if (g_sections[i].pass != -1) {
                PbSection* s = &g_sections[i];
                if (s->vbuf) vkDestroyBuffer(g_device, s->vbuf, NULL);
                if (s->vmem) vkFreeMemory(g_device, s->vmem, NULL);
                if (s->ibuf) vkDestroyBuffer(g_device, s->ibuf, NULL);
                if (s->imem) vkFreeMemory(g_device, s->imem, NULL);
                s->pass = -1;
            }
        }
        for (int i = 0; i < MAX_ENTITY_GEOMS; i++) {
            PbEntityGeom* gm = &g_entGeoms[i];
            if (!gm->used) continue;
            if (gm->vbuf) vkDestroyBuffer(g_device, gm->vbuf, NULL);
            if (gm->vmem) vkFreeMemory(g_device, gm->vmem, NULL);
            if (gm->texView) vkDestroyImageView(g_device, gm->texView, NULL);
            if (gm->tex) vkDestroyImage(g_device, gm->tex, NULL);
            if (gm->texMem) vkFreeMemory(g_device, gm->texMem, NULL);
            gm->used = 0;
        }
        for (int i = 0; i < FRAMES_IN_FLIGHT; i++) {
            if (g_uiVbuf[i]) vkDestroyBuffer(g_device, g_uiVbuf[i], NULL);
            if (g_uiVmem[i]) vkFreeMemory(g_device, g_uiVmem[i], NULL);
            g_uiVbuf[i] = NULL;
        }
        for (int i = 0; i < MAX_UI_IMAGES; i++) {
            PbUIImage* im = &g_uiImages[i];
            if (!im->used) continue;
            if (im->view) vkDestroyImageView(g_device, im->view, NULL);
            if (im->tex) vkDestroyImage(g_device, im->tex, NULL);
            if (im->mem) vkFreeMemory(g_device, im->mem, NULL);
            im->used = 0;
        }
        for (int i = 0; i < FRAMES_IN_FLIGHT; i++) {
            if (g_imgVbuf[i]) vkDestroyBuffer(g_device, g_imgVbuf[i], NULL);
            if (g_imgVmem[i]) vkFreeMemory(g_device, g_imgVmem[i], NULL);
            g_imgVbuf[i] = NULL;
        }
        if (g_starBuf) vkDestroyBuffer(g_device, g_starBuf, NULL);
        if (g_starMem) vkFreeMemory(g_device, g_starMem, NULL);
        g_starBuf = NULL;
        g_starMem = NULL;
        g_starCount = 0;
        for (int i = 0; i < SKY_TEX_COUNT; i++) {
            PbSkyTex* t = &g_skyTex[i];
            if (!t->used) continue;
            if (t->view) vkDestroyImageView(g_device, t->view, NULL);
            if (t->tex) vkDestroyImage(g_device, t->tex, NULL);
            if (t->mem) vkFreeMemory(g_device, t->mem, NULL);
            t->used = 0;
        }
        if (g_dummyView) vkDestroyImageView(g_device, g_dummyView, NULL);
        if (g_dummyImage) vkDestroyImage(g_device, g_dummyImage, NULL);
        if (g_dummyMem) vkFreeMemory(g_device, g_dummyMem, NULL);
        g_dummyView = NULL;
        g_dummyImage = NULL;
        g_dummyMem = NULL;
        if (g_pipeSky) vkDestroyPipeline(g_device, g_pipeSky, NULL);
        if (g_pipeStars) vkDestroyPipeline(g_device, g_pipeStars, NULL);
        if (g_pipeCelestial) vkDestroyPipeline(g_device, g_pipeCelestial, NULL);
        if (g_pipeCelestialAdd) vkDestroyPipeline(g_device, g_pipeCelestialAdd, NULL);
        if (g_pipeCloud) vkDestroyPipeline(g_device, g_pipeCloud, NULL);
        if (g_skyLayout) vkDestroyPipelineLayout(g_device, g_skyLayout, NULL);
        if (g_starsLayout) vkDestroyPipelineLayout(g_device, g_starsLayout, NULL);
        if (g_celLayout) vkDestroyPipelineLayout(g_device, g_celLayout, NULL);
        if (g_cloudLayout) vkDestroyPipelineLayout(g_device, g_cloudLayout, NULL);
        memset(&g_sky, 0, sizeof g_sky);
        for (int i = 0; i < FRAMES_IN_FLIGHT; i++) {
            if (g_lineVbuf[i]) vkDestroyBuffer(g_device, g_lineVbuf[i], NULL);
            if (g_lineVmem[i]) vkFreeMemory(g_device, g_lineVmem[i], NULL);
            if (g_partVbuf[i]) vkDestroyBuffer(g_device, g_partVbuf[i], NULL);
            if (g_partVmem[i]) vkFreeMemory(g_device, g_partVmem[i], NULL);
            if (g_sprVbuf[i]) vkDestroyBuffer(g_device, g_sprVbuf[i], NULL);
            if (g_sprVmem[i]) vkFreeMemory(g_device, g_sprVmem[i], NULL);
            g_lineVbuf[i] = NULL;
            g_partVbuf[i] = NULL;
            g_sprVbuf[i] = NULL;
            g_lineVmap[i] = NULL;
            g_partVmap[i] = NULL;
            g_sprVmap[i] = NULL;
        }
        for (int i = 0; i < g_sprRectCount; i++) free(g_sprRects[i].pixels);
        g_sprRectCount = 0;
        g_lineVertCount = 0;
        g_partCount = 0;
        g_sprCount = 0;
        if (g_sprView) vkDestroyImageView(g_device, g_sprView, NULL);
        if (g_sprImage) vkDestroyImage(g_device, g_sprImage, NULL);
        if (g_sprMem) vkFreeMemory(g_device, g_sprMem, NULL);
        g_sprView = NULL;
        g_sprImage = NULL;
        g_sprMem = NULL;
        g_sprImageReady = 0;
        for (int s = 0; s < OVERLAY_COUNT; s++) {
            PbOverlayMesh* m = &g_overlay[s];
            for (int i = 0; i < FRAMES_IN_FLIGHT; i++) {
                if (m->vbuf[i]) vkDestroyBuffer(g_device, m->vbuf[i], NULL);
                if (m->vmem[i]) vkFreeMemory(g_device, m->vmem[i], NULL);
                if (m->ibuf[i]) vkDestroyBuffer(g_device, m->ibuf[i], NULL);
                if (m->imem[i]) vkFreeMemory(g_device, m->imem[i], NULL);
                m->vbuf[i] = NULL;
                m->ibuf[i] = NULL;
                m->vmap[i] = NULL;
                m->imap[i] = NULL;
            }
            m->indexCount = 0;
        }
        g_lineBatchCount = 0;
        g_vmDrawCount = 0;
        if (g_pipeViewmodel) vkDestroyPipeline(g_device, g_pipeViewmodel, NULL);
        if (g_partsBuf) vkDestroyBuffer(g_device, g_partsBuf, NULL);
        if (g_partsMem) vkFreeMemory(g_device, g_partsMem, NULL);
        g_partsBuf = NULL;
        g_partsMap = NULL;
        if (g_entSetLayout) vkDestroyDescriptorSetLayout(g_device, g_entSetLayout, NULL);
        if (g_guiView) vkDestroyImageView(g_device, g_guiView, NULL);
        if (g_guiImage) vkDestroyImage(g_device, g_guiImage, NULL);
        if (g_guiMem) vkFreeMemory(g_device, g_guiMem, NULL);
        g_guiView = NULL;
        g_guiImage = NULL;
        g_uiSegCount = 0;
        if (g_pipeUltra) vkDestroyPipeline(g_device, g_pipeUltra, NULL);
        if (g_pipeUltraBlur) vkDestroyPipeline(g_device, g_pipeUltraBlur, NULL);
        if (g_ultraLayout) vkDestroyPipelineLayout(g_device, g_ultraLayout, NULL);
        if (g_ultraUbo) vkDestroyBuffer(g_device, g_ultraUbo, NULL);
        if (g_ultraUboMem) vkFreeMemory(g_device, g_ultraUboMem, NULL);
        if (g_uboSetLayout) vkDestroyDescriptorSetLayout(g_device, g_uboSetLayout, NULL);
        if (g_depthSampler) vkDestroySampler(g_device, g_depthSampler, NULL);
        g_ultraUboMap = NULL;
        g_ultraOK = 0;
        g_ultraOn = 0;
        if (g_pipeShadow) vkDestroyPipeline(g_device, g_pipeShadow, NULL);
        if (g_shadowLayout) vkDestroyPipelineLayout(g_device, g_shadowLayout, NULL);
        if (g_shadowFb) vkDestroyFramebuffer(g_device, g_shadowFb, NULL);
        if (g_shadowView) vkDestroyImageView(g_device, g_shadowView, NULL);
        if (g_shadowImage) vkDestroyImage(g_device, g_shadowImage, NULL);
        if (g_shadowMem) vkFreeMemory(g_device, g_shadowMem, NULL);
        if (g_shadowSampler) vkDestroySampler(g_device, g_shadowSampler, NULL);
        if (g_shadowPass) vkDestroyRenderPass(g_device, g_shadowPass, NULL);
        if (g_shadowUbo) vkDestroyBuffer(g_device, g_shadowUbo, NULL);
        if (g_shadowUboMem) vkFreeMemory(g_device, g_shadowUboMem, NULL);
        if (g_chunkSetLayout) vkDestroyDescriptorSetLayout(g_device, g_chunkSetLayout, NULL);
        g_shadowPass = NULL;
        g_shadowUboMap = NULL;
        if (g_pipeBloomExtract) vkDestroyPipeline(g_device, g_pipeBloomExtract, NULL);
        if (g_pipeBlur) vkDestroyPipeline(g_device, g_pipeBlur, NULL);
        if (g_pipeComposite) vkDestroyPipeline(g_device, g_pipeComposite, NULL);
        if (g_bloomLayout) vkDestroyPipelineLayout(g_device, g_bloomLayout, NULL);
        if (g_compositeLayout) vkDestroyPipelineLayout(g_device, g_compositeLayout, NULL);
        if (g_scenePass) vkDestroyRenderPass(g_device, g_scenePass, NULL);
        if (g_bloomPass) vkDestroyRenderPass(g_device, g_bloomPass, NULL);
        g_scenePass = NULL;
        g_bloomPass = NULL;
        if (g_pipeLines) vkDestroyPipeline(g_device, g_pipeLines, NULL);
        if (g_pipeLineTris) vkDestroyPipeline(g_device, g_pipeLineTris, NULL);
        if (g_pipeParticle) vkDestroyPipeline(g_device, g_pipeParticle, NULL);
        if (g_pipeSprite) vkDestroyPipeline(g_device, g_pipeSprite, NULL);
        if (g_lineLayout) vkDestroyPipelineLayout(g_device, g_lineLayout, NULL);
        if (g_particleLayout) vkDestroyPipelineLayout(g_device, g_particleLayout, NULL);
        if (g_spriteLayout) vkDestroyPipelineLayout(g_device, g_spriteLayout, NULL);
        if (g_cloudSampler) vkDestroySampler(g_device, g_cloudSampler, NULL);
        if (g_linearSampler) vkDestroySampler(g_device, g_linearSampler, NULL);
        if (g_pipeUI) vkDestroyPipeline(g_device, g_pipeUI, NULL);
        if (g_uiLayout) vkDestroyPipelineLayout(g_device, g_uiLayout, NULL);
        if (g_uiView) vkDestroyImageView(g_device, g_uiView, NULL);
        if (g_uiImage) vkDestroyImage(g_device, g_uiImage, NULL);
        if (g_uiMem) vkFreeMemory(g_device, g_uiMem, NULL);
        if (g_pipeEntity) vkDestroyPipeline(g_device, g_pipeEntity, NULL);
        if (g_entLayout) vkDestroyPipelineLayout(g_device, g_entLayout, NULL);
        if (g_descPool) vkDestroyDescriptorPool(g_device, g_descPool, NULL);
        if (g_atlasSampler) vkDestroySampler(g_device, g_atlasSampler, NULL);
        if (g_atlasView) vkDestroyImageView(g_device, g_atlasView, NULL);
        if (g_atlasImage) vkDestroyImage(g_device, g_atlasImage, NULL);
        if (g_atlasMem) vkFreeMemory(g_device, g_atlasMem, NULL);
        if (g_pipeOpaque) vkDestroyPipeline(g_device, g_pipeOpaque, NULL);
        if (g_pipeTranslucent) vkDestroyPipeline(g_device, g_pipeTranslucent, NULL);
        if (g_pipeLayout) vkDestroyPipelineLayout(g_device, g_pipeLayout, NULL);
        if (g_setLayout) vkDestroyDescriptorSetLayout(g_device, g_setLayout, NULL);
        destroy_swapchain();
        for (int i = 0; i < FRAMES_IN_FLIGHT; i++) {
            if (g_acquireSem[i]) vkDestroySemaphore(g_device, g_acquireSem[i], NULL);
            if (g_fence[i]) vkDestroyFence(g_device, g_fence[i], NULL);
        }
        if (g_pool) vkDestroyCommandPool(g_device, g_pool, NULL);
        if (g_pass) vkDestroyRenderPass(g_device, g_pass, NULL);
        vkDestroyDevice(g_device, NULL);
        g_device = NULL;
    }
    if (g_surface) vkDestroySurfaceKHR(g_instance, g_surface, NULL);
    if (g_instance) vkDestroyInstance(g_instance, NULL);
    if (g_lib) FreeLibrary(g_lib);
    g_surface = NULL; g_instance = NULL; g_lib = NULL;
}

const char* pb_vk_last_error(void) { return g_err; }
const char* pb_vk_device_name(void) { return g_gpu; }

#else   // !_WIN32 — every platform builds this target; only Windows uses it

static const char* kNotWindows = "the Vulkan backend is Windows-only for now";
int pb_vk_create(void* hwnd, void* hinstance, int width, int height) {
    (void)hwnd; (void)hinstance; (void)width; (void)height;
    return -1;
}
int pb_vk_frame(float r, float g, float b) { (void)r; (void)g; (void)b; return 1; }
void pb_vk_resize(int width, int height) { (void)width; (void)height; }
void pb_vk_destroy(void) {}
int pb_vk_upload_atlas(const unsigned char* rgba, int tileW, int tileH, int layers) {
    (void)rgba; (void)tileW; (void)tileH; (void)layers; return -1;
}
void pb_vk_set_sky(int drawSky, int overworld, int endDim, int drawClouds,
                   const float* zenith3, const float* horizon3,
                   float sunGlow, const float* sunDir3,
                   float rainLevel, int dayPhase) {
    (void)drawSky; (void)overworld; (void)endDim; (void)drawClouds;
    (void)zenith3; (void)horizon3; (void)sunGlow; (void)sunDir3;
    (void)rainLevel; (void)dayPhase;
}
int pb_vk_upload_stars(const void* verts, int count) {
    (void)verts; (void)count; return -1;
}
int pb_vk_upload_sky_tex(int which, const unsigned char* rgba, int w, int h) {
    (void)which; (void)rgba; (void)w; (void)h; return -1;
}
void pb_vk_set_post(float bloomAmt, float warp, float time, float darkness,
                    float tintR, float tintG, float tintB, float tintA) {
    (void)bloomAmt; (void)warp; (void)time; (void)darkness;
    (void)tintR; (void)tintG; (void)tintB; (void)tintA;
}
void pb_vk_set_shadow(const float* shadowMat16, int enabled) {
    (void)shadowMat16; (void)enabled;
}
void pb_vk_set_ultra(int on, const float* block64) {
    (void)on; (void)block64;
}
int pb_vk_upload_gui_sheet(const unsigned char* rgba, int w, int h) {
    (void)rgba; (void)w; (void)h; return -1;
}
void pb_vk_ui_set_segments(const int* segs, int pairCount) {
    (void)segs; (void)pairCount;
}
void pb_vk_begin_lines(void) {}
void pb_vk_push_lines(const float* verts, int vertCount, int tris,
                      float r, float g, float b, float a) {
    (void)verts; (void)vertCount; (void)tris; (void)r; (void)g; (void)b; (void)a;
}
int pb_vk_set_overlay_mesh(int slot, int pass, float alphaTest,
                           double ox, double oy, double oz,
                           const void* verts, int vertCount,
                           const unsigned int* indices, int indexCount) {
    (void)slot; (void)pass; (void)alphaTest; (void)ox; (void)oy; (void)oz;
    (void)verts; (void)vertCount; (void)indices; (void)indexCount; return -1;
}
void pb_vk_clear_overlay_mesh(int slot) { (void)slot; }
void pb_vk_set_viewmodel_proj(const float* proj16) { (void)proj16; }
void pb_vk_begin_viewmodel(void) {}
void pb_vk_push_viewmodel(int geomId, const float* model16, float brightness, float alpha) {
    (void)geomId; (void)model16; (void)brightness; (void)alpha;
}
void pb_vk_set_particles(const void* instances, int count,
                         const float* right3, const float* up3) {
    (void)instances; (void)count; (void)right3; (void)up3;
}
void pb_vk_set_sprites(const void* instances, int count, const float* right3) {
    (void)instances; (void)count; (void)right3;
}
int pb_vk_sprite_atlas_update(int x, int y, int w, int h, const unsigned char* rgba) {
    (void)x; (void)y; (void)w; (void)h; (void)rgba; return -1;
}
int pb_vk_upload_section(unsigned long long id, int pass,
                         double ox, double oy, double oz,
                         const void* verts, int vertCount,
                         const unsigned int* indices, int indexCount) {
    (void)id; (void)pass; (void)ox; (void)oy; (void)oz;
    (void)verts; (void)vertCount; (void)indices; (void)indexCount; return -1;
}
void pb_vk_remove_section(unsigned long long id, int pass) { (void)id; (void)pass; }
void pb_vk_clear_sections(void) {}
int pb_vk_upload_entity_geom(int geomId, const void* verts, int vertCount,
                             const unsigned char* rgba, int texW, int texH) {
    (void)geomId; (void)verts; (void)vertCount; (void)rgba; (void)texW; (void)texH; return -1;
}
void pb_vk_begin_entities(void) {}
void pb_vk_push_entity(int geomId, const float* model16, float brightness, float alpha,
                       const float* parts24) {
    (void)geomId; (void)model16; (void)brightness; (void)alpha; (void)parts24;
}
void pb_vk_ui_update_atlas(int x, int y, int w, int h, const unsigned char* rgba) {
    (void)x; (void)y; (void)w; (void)h; (void)rgba;
}
int pb_vk_upload_image(int id, const unsigned char* rgba, int w, int h) {
    (void)id; (void)rgba; (void)w; (void)h; return -1;
}
void pb_vk_ui_push_image(int id, float x, float y, float w, float h,
                         float u0, float v0, float u1, float v1) {
    (void)id; (void)x; (void)y; (void)w; (void)h;
    (void)u0; (void)v0; (void)u1; (void)v1;
}
void pb_vk_ui_set_frame(const float* verts, int floatCount, float screenW, float screenH) {
    (void)verts; (void)floatCount; (void)screenW; (void)screenH;
}
void pb_vk_set_camera(const float* viewProj16,
                      double camX, double camY, double camZ,
                      float time, float dayLight, float gammaB, float ambient,
                      float fogStart, float fogEnd, float alphaTest,
                      float fogR, float fogG, float fogB) {
    (void)viewProj16; (void)camX; (void)camY; (void)camZ; (void)time;
    (void)dayLight; (void)gammaB; (void)ambient; (void)fogStart; (void)fogEnd;
    (void)alphaTest; (void)fogR; (void)fogG; (void)fogB;
}
const char* pb_vk_last_error(void) { return kNotWindows; }
const char* pb_vk_device_name(void) { return ""; }

#endif
