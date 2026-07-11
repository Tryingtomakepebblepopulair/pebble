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

// entities: bind-pose geometry per type + one skin texture each
#define MAX_ENTITY_GEOMS 160
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
typedef struct {
    int geomId;
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

static void mat4_mul(float* out, const float* a, const float* b) {
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            float s = 0;
            for (int k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
            out[c * 4 + r] = s;
        }
    }
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

// ---- swapchain (re)build ----------------------------------------------------
static void destroy_swapchain(void) {
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
    ici.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
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
                    snprintf(g_gpu, sizeof g_gpu, "%s", props.deviceName);
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

    // chunk pipelines: descriptor set (atlas sampler) + 128B push constants
    VkDescriptorSetLayoutBinding bind = { 0 };
    bind.binding = 0;
    bind.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bind.descriptorCount = 1;
    bind.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo dsli = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    dsli.bindingCount = 1;
    dsli.pBindings = &bind;
    VKTRY(vkCreateDescriptorSetLayout(g_device, &dsli, NULL, &g_setLayout), "create set layout");

    VkPushConstantRange pcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(PbPush) };
    VkPipelineLayoutCreateInfo pli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &g_setLayout;
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
    VkDescriptorPoolSize pool = { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, MAX_ENTITY_GEOMS + 1 };
    VkDescriptorPoolCreateInfo dpi = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    dpi.maxSets = MAX_ENTITY_GEOMS + 1;
    dpi.poolSizeCount = 1;
    dpi.pPoolSizes = &pool;
    VKTRY(vkCreateDescriptorPool(g_device, &dpi, NULL, &g_descPool), "create descriptor pool");

    // entity pipeline: 36-byte ABI stream, blended, depth-tested
    VkPushConstantRange epcr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                                 0, sizeof(PbEntityPush) };
    VkPipelineLayoutCreateInfo epli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    epli.setLayoutCount = 1;
    epli.pSetLayouts = &g_setLayout;
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
    VkDescriptorSetAllocateInfo dsa = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    dsa.descriptorPool = g_descPool;
    dsa.descriptorSetCount = 1;
    dsa.pSetLayouts = &g_setLayout;
    VKTRY(vkAllocateDescriptorSets(g_device, &dsa, outSet), "allocate descriptor set");
    VkDescriptorImageInfo dii = { g_atlasSampler, view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    VkWriteDescriptorSet wds = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
    wds.dstSet = *outSet;
    wds.dstBinding = 0;
    wds.descriptorCount = 1;
    wds.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    wds.pImageInfo = &dii;
    vkUpdateDescriptorSets(g_device, 1, &wds, 0, NULL);
    return 0;
}

int pb_vk_upload_atlas(const unsigned char* rgba, int tileW, int tileH, int layers) {
    if (!g_device) FAIL("renderer not created");
    if (upload_texture(rgba, tileW, tileH, layers, VK_IMAGE_VIEW_TYPE_2D_ARRAY,
                       &g_atlasImage, &g_atlasMem, &g_atlasView) != 0) return -1;
    return make_sampler_set(g_atlasView, &g_atlasSet);
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
    if (make_sampler_set(gm->texView, &gm->set) != 0) return -1;
    gm->used = 1;
    return 0;
}

void pb_vk_begin_entities(void) {
    g_entDrawCount = 0;
}

void pb_vk_push_entity(int geomId, const float* model16, float brightness, float alpha) {
    if (geomId < 0 || geomId >= MAX_ENTITY_GEOMS || !g_entGeoms[geomId].used) return;
    if (g_entDrawCount >= MAX_ENTITY_DRAWS) return;
    PbEntityDraw* d = &g_entDraws[g_entDrawCount++];
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

static void draw_pass(VkCommandBuffer cmd, int pass, float alphaTest) {
    PbPush push = g_push;
    push.fog[2] = alphaTest;
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
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeLayout,
                            0, 1, &g_atlasSet, 0, NULL);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeOpaque);
    draw_pass(cmd, 0, 0.0f);              // opaque
    draw_pass(cmd, 1, g_cutoutAlphaTest); // cutout (leaves/plants) — discard
    if (g_entDrawCount > 0) {             // mobs + other players
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeEntity);
        int lastGeom = -1;
        for (int i = 0; i < g_entDrawCount; i++) {
            PbEntityDraw* d = &g_entDraws[i];
            PbEntityGeom* gm = &g_entGeoms[d->geomId];
            if (d->geomId != lastGeom) {
                vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_entLayout,
                                        0, 1, &gm->set, 0, NULL);
                VkDeviceSize zero = 0;
                vkCmdBindVertexBuffers(cmd, 0, 1, &gm->vbuf, &zero);
                lastGeom = d->geomId;
            }
            vkCmdPushConstants(cmd, g_entLayout,
                               VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                               0, sizeof d->push, &d->push);
            vkCmdDraw(cmd, gm->vertCount, 1, 0, 0);
        }
        // rebind the terrain set for the translucent pass
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeLayout,
                                0, 1, &g_atlasSet, 0, NULL);
    }
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeTranslucent);
    draw_pass(cmd, 2, 0.0f);              // water/glass — blended
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
static void flush_ui_atlas(VkCommandBuffer cmd) {
    if (g_uiRectCount == 0) return;
    // one staging buffer for all rects this frame
    VkDeviceSize total = 0;
    for (int i = 0; i < g_uiRectCount; i++) total += (VkDeviceSize)g_uiRects[i].w * g_uiRects[i].h * 4;
    VkBuffer staging;
    VkDeviceMemory stagingMem;
    if (make_buffer(total, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &staging, &stagingMem, NULL) != 0) {
        for (int i = 0; i < g_uiRectCount; i++) free(g_uiRects[i].pixels);
        g_uiRectCount = 0;
        return;
    }
    void* map = NULL;
    vkMapMemory(g_device, stagingMem, 0, total, 0, &map);
    VkDeviceSize off = 0;
    for (int i = 0; i < g_uiRectCount; i++) {
        size_t bytes = (size_t)g_uiRects[i].w * g_uiRects[i].h * 4;
        memcpy((char*)map + off, g_uiRects[i].pixels, bytes);
        free(g_uiRects[i].pixels);
        g_uiRects[i].pixels = NULL;
        off += bytes;
    }
    vkUnmapMemory(g_device, stagingMem);

    VkImageMemoryBarrier bar = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    bar.srcAccessMask = g_uiImageReady ? VK_ACCESS_SHADER_READ_BIT : 0;
    bar.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    bar.oldLayout = g_uiImageReady ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED;
    bar.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    bar.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bar.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bar.image = g_uiImage;
    bar.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    bar.subresourceRange.levelCount = 1;
    bar.subresourceRange.layerCount = 1;
    vkCmdPipelineBarrier(cmd, g_uiImageReady ? VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
    off = 0;
    for (int i = 0; i < g_uiRectCount; i++) {
        VkBufferImageCopy copy = { 0 };
        copy.bufferOffset = off;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageOffset.x = g_uiRects[i].x;
        copy.imageOffset.y = g_uiRects[i].y;
        copy.imageExtent.width = (uint32_t)g_uiRects[i].w;
        copy.imageExtent.height = (uint32_t)g_uiRects[i].h;
        copy.imageExtent.depth = 1;
        vkCmdCopyBufferToImage(cmd, staging, g_uiImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        off += (VkDeviceSize)g_uiRects[i].w * g_uiRects[i].h * 4;
    }
    bar.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    bar.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    bar.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    bar.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
    g_uiImageReady = 1;
    g_uiRectCount = 0;
    // the staging buffer retires with the frame fence — leak-free enough for
    // load bursts would need a retire list; UI cells are tiny, wait instead
    vkQueueWaitIdle(g_queue);
    vkDestroyBuffer(g_device, staging, NULL);
    vkFreeMemory(g_device, stagingMem, NULL);
}

static void record_ui_draws(VkCommandBuffer cmd) {
    if (g_uiVertCount == 0 || !g_uiImageReady) return;
    uint32_t f = g_frame % FRAMES_IN_FLIGHT;
    VkViewport vpt = { 0, 0, (float)g_extent.width, (float)g_extent.height, 0, 1 };
    VkRect2D sc = { { 0, 0 }, g_extent };
    vkCmdSetViewport(cmd, 0, 1, &vpt);
    vkCmdSetScissor(cmd, 0, 1, &sc);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipeUI);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g_uiLayout,
                            0, 1, &g_uiSet, 0, NULL);
    vkCmdPushConstants(cmd, g_uiLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, 16, g_uiScreen);
    VkDeviceSize zero = 0;
    vkCmdBindVertexBuffers(cmd, 0, 1, &g_uiVbuf[f], &zero);
    vkCmdDraw(cmd, (uint32_t)g_uiVertCount, 1, 0, 0);
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
    flush_ui_atlas(g_cmd[f]);
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
    vkCmdBeginRenderPass(g_cmd[f], &rbi, VK_SUBPASS_CONTENTS_INLINE);
    if (g_worldDraws) record_world_draws(g_cmd[f]);
    record_ui_draws(g_cmd[f]);
    vkCmdEndRenderPass(g_cmd[f]);
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
void pb_vk_push_entity(int geomId, const float* model16, float brightness, float alpha) {
    (void)geomId; (void)model16; (void)brightness; (void)alpha;
}
void pb_vk_ui_update_atlas(int x, int y, int w, int h, const unsigned char* rgba) {
    (void)x; (void)y; (void)w; (void)h; (void)rgba;
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
