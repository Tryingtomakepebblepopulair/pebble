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
#include <stdio.h>
#include <string.h>

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

    for (uint32_t i = 0; i < g_imageCount; i++) {
        VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
        vci.image = g_images[i];
        vci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        vci.format = g_format;
        vci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        vci.subresourceRange.levelCount = 1;
        vci.subresourceRange.layerCount = 1;
        VKTRY(vkCreateImageView(g_device, &vci, NULL, &g_views[i]), "create image view");

        VkFramebufferCreateInfo fci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        fci.renderPass = g_pass;
        fci.attachmentCount = 1;
        fci.pAttachments = &g_views[i];
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

    VkAttachmentDescription att = { 0 };
    att.format = g_format;
    att.samples = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    att.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    att.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sub = { 0 };
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments = &ref;
    VkSubpassDependency dep = { 0 };
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rpci.attachmentCount = 1;
    rpci.pAttachments = &att;
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
    VkClearValue clear;
    clear.color.float32[0] = r;
    clear.color.float32[1] = g;
    clear.color.float32[2] = b;
    clear.color.float32[3] = 1.0f;
    VkRenderPassBeginInfo rbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    rbi.renderPass = g_pass;
    rbi.framebuffer = g_fbs[idx];
    rbi.renderArea.extent = g_extent;
    rbi.clearValueCount = 1;
    rbi.pClearValues = &clear;
    vkCmdBeginRenderPass(g_cmd[f], &rbi, VK_SUBPASS_CONTENTS_INLINE);
    // (world/UI draws land here in the next session)
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
const char* pb_vk_last_error(void) { return kNotWindows; }
const char* pb_vk_device_name(void) { return ""; }

#endif
