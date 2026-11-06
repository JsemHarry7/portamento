/* Vulkan smoke test for Portamento's Vulkan drivers.
 *
 * Loads vulkan-1.dll at run time, reports the device and a few features games
 * depend on, creates a swap chain on a window, recreates it a few times while
 * holding an acquired image (as games do on a resize), clears it to blue,
 * copies the first frame into a buffer to check the colour, then clears and
 * presents frames to measure throughput.  Prints "OK" and exits 0 only if the
 * pixel came out right.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -I<Vulkan SDK>/include -o vktest.exe vktest.c
 */
#define VK_USE_PLATFORM_WIN32_KHR
#define VK_NO_PROTOTYPES
#include <windows.h>
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>

#define WIDTH  1280
#define HEIGHT 720
#define MAX_IMAGES 8
#define RECREATES 4           /* more than the drawables a CAMetalLayer hands out */
#define ACQUIRE_TIMEOUT 3000000000ull  /* ns; a driver out of drawables never returns one */
#define SLOW_ACQUIRE_MS 100   /* a frame or two at 60 Hz; short of drawables it's ~250 */

#define VK_FUNCS \
    X(vkCreateInstance) \
    X(vkEnumeratePhysicalDevices) \
    X(vkGetPhysicalDeviceProperties) \
    X(vkGetPhysicalDeviceFeatures2) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) \
    X(vkGetPhysicalDeviceMemoryProperties) \
    X(vkCreateWin32SurfaceKHR) \
    X(vkGetPhysicalDeviceSurfaceSupportKHR) \
    X(vkGetPhysicalDeviceSurfaceFormatsKHR) \
    X(vkGetPhysicalDeviceSurfaceCapabilitiesKHR) \
    X(vkCreateDevice) \
    X(vkGetDeviceQueue) \
    X(vkCreateSwapchainKHR) \
    X(vkDestroySwapchainKHR) \
    X(vkGetSwapchainImagesKHR) \
    X(vkAcquireNextImageKHR) \
    X(vkQueuePresentKHR) \
    X(vkCreateCommandPool) \
    X(vkAllocateCommandBuffers) \
    X(vkBeginCommandBuffer) \
    X(vkEndCommandBuffer) \
    X(vkResetCommandBuffer) \
    X(vkCmdPipelineBarrier) \
    X(vkCmdClearColorImage) \
    X(vkCmdCopyImageToBuffer) \
    X(vkQueueSubmit) \
    X(vkQueueWaitIdle) \
    X(vkCreateBuffer) \
    X(vkGetBufferMemoryRequirements) \
    X(vkAllocateMemory) \
    X(vkBindBufferMemory) \
    X(vkMapMemory) \
    X(vkCreateSemaphore) \
    X(vkCreateFence) \
    X(vkWaitForFences) \
    X(vkResetFences)

static PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr;
#define X(name) static PFN_##name name;
VK_FUNCS
#undef X

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void check(VkResult res, const char *what)
{
    if (res == VK_SUCCESS || res == VK_SUBOPTIMAL_KHR) return;
    if (res == VK_TIMEOUT || res == VK_NOT_READY)
        printf("FAIL %s: no image within %llu s, the driver ran out of drawables\n", what, ACQUIRE_TIMEOUT / 1000000000ull);
    else
        printf("FAIL %s: VkResult %d\n", what, res);
    exit(1);
}

static void load_funcs(VkInstance instance)
{
#define X(name) name = (PFN_##name)vkGetInstanceProcAddr(instance, #name);
    VK_FUNCS
#undef X
}

static void barrier(VkCommandBuffer cmd, VkImage image, VkImageLayout from, VkImageLayout to,
                    VkAccessFlags src_access, VkAccessFlags dst_access)
{
    VkImageMemoryBarrier b = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};

    b.srcAccessMask = src_access;
    b.dstAccessMask = dst_access;
    b.oldLayout = from;
    b.newLayout = to;
    b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    b.subresourceRange.levelCount = b.subresourceRange.layerCount = 1;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                         0, 0, NULL, 0, NULL, 1, &b);
}

static int close_to(BYTE value, int expect)
{
    return abs(value - expect) <= 2;
}

int main(int argc, char **argv)
{
    static const char *instance_exts[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WIN32_SURFACE_EXTENSION_NAME};
    static const char *device_exts[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    static const VkClearColorValue blue = {{0.0f, 0.0f, 1.0f, 1.0f}};
    int frames = argc > 1 ? atoi(argv[1]) : 300;
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    VkInstanceCreateInfo instance_info = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    VkWin32SurfaceCreateInfoKHR surface_info = {VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR};
    VkPhysicalDeviceVulkan12Features features12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
    VkPhysicalDeviceFeatures2 features = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &features12};
    VkDeviceQueueCreateInfo queue_info = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    VkDeviceCreateInfo device_info = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    VkSwapchainCreateInfoKHR swapchain_info = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    VkCommandPoolCreateInfo pool_info = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    VkCommandBufferAllocateInfo alloc_info = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    VkCommandBufferBeginInfo begin_info = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    VkBufferCreateInfo buffer_info = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    VkMemoryAllocateInfo mem_info = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    VkSemaphoreCreateInfo sem_info = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkFenceCreateInfo fence_info = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkPhysicalDeviceMemoryProperties mem_props;
    VkQueueFamilyProperties families[16];
    VkPhysicalDeviceProperties props;
    VkSurfaceCapabilitiesKHR caps;
    VkSurfaceFormatKHR formats[32];
    VkImage images[MAX_IMAGES];
    VkMemoryRequirements req;
    VkBufferImageCopy copy = {0};
    VkPhysicalDevice phys;
    VkInstance instance;
    VkSurfaceKHR surface;
    VkDevice device;
    VkQueue queue;
    VkSwapchainKHR swapchain, old;
    VkFence fence;
    VkCommandPool pool;
    VkCommandBuffer cmd;
    VkBuffer buffer;
    VkDeviceMemory memory;
    VkSemaphore acquired, rendered;
    LARGE_INTEGER freq, t0, t1, a0, a1;
    double acquire_ms, slowest = 0;
    WNDCLASSW wc = {0};
    uint32_t count, family = ~0u, image_count = MAX_IMAGES, idx, i;
    float priority = 1.0f;
    HMODULE vulkan;
    const BYTE *px;
    int bgra, readback, ok = 0;
    void *data;
    HWND hwnd;
    MSG msg;

    setvbuf(stdout, NULL, _IONBF, 0);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"vktest";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"vktest", L"porta vulkan test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                         100, 100, WIDTH, HEIGHT, NULL, NULL, wc.hInstance, NULL);

    if (!(vulkan = LoadLibraryA("vulkan-1.dll")) ||
        !(vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)GetProcAddress(vulkan, "vkGetInstanceProcAddr")))
    {
        printf("FAIL no vulkan-1.dll\n");
        return 1;
    }
    load_funcs(NULL);

    app.apiVersion = VK_API_VERSION_1_2;
    instance_info.pApplicationInfo = &app;
    instance_info.enabledExtensionCount = ARRAYSIZE(instance_exts);
    instance_info.ppEnabledExtensionNames = instance_exts;
    check(vkCreateInstance(&instance_info, NULL, &instance), "vkCreateInstance");
    load_funcs(instance);

    count = 1;
    vkEnumeratePhysicalDevices(instance, &count, &phys);
    if (!count)
    {
        printf("FAIL no Vulkan device\n");
        return 1;
    }
    vkGetPhysicalDeviceProperties(phys, &props);
    vkGetPhysicalDeviceFeatures2(phys, &features);
    printf("device: %s, Vulkan %u.%u.%u\n", props.deviceName, VK_API_VERSION_MAJOR(props.apiVersion),
           VK_API_VERSION_MINOR(props.apiVersion), VK_API_VERSION_PATCH(props.apiVersion));
    printf("features: drawIndirectCount=%u fillModeNonSolid=%u\n",
           features12.drawIndirectCount, features.features.fillModeNonSolid);

    surface_info.hinstance = wc.hInstance;
    surface_info.hwnd = hwnd;
    check(vkCreateWin32SurfaceKHR(instance, &surface_info, NULL, &surface), "vkCreateWin32SurfaceKHR");

    count = ARRAYSIZE(families);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &count, families);
    for (i = 0; i < count && family == ~0u; i++)
    {
        VkBool32 present = VK_FALSE;
        vkGetPhysicalDeviceSurfaceSupportKHR(phys, i, surface, &present);
        if ((families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) family = i;
    }
    if (family == ~0u)
    {
        printf("FAIL no graphics queue that can present\n");
        return 1;
    }

    queue_info.queueFamilyIndex = family;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &priority;
    device_info.queueCreateInfoCount = 1;
    device_info.pQueueCreateInfos = &queue_info;
    device_info.enabledExtensionCount = ARRAYSIZE(device_exts);
    device_info.ppEnabledExtensionNames = device_exts;
    check(vkCreateDevice(phys, &device_info, NULL, &device), "vkCreateDevice");
    vkGetDeviceQueue(device, family, 0, &queue);

    check(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(phys, surface, &caps), "surface capabilities");
    count = ARRAYSIZE(formats);
    vkGetPhysicalDeviceSurfaceFormatsKHR(phys, surface, &count, formats);
    bgra = formats[0].format == VK_FORMAT_B8G8R8A8_UNORM || formats[0].format == VK_FORMAT_B8G8R8A8_SRGB;
    readback = !!(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    swapchain_info.surface = surface;
    /* One more than the minimum, as many games ask for, without clamping to
     * maxImageCount like they don't either (BeamNG asks KosmicKrisp for 4 of 3). */
    swapchain_info.minImageCount = (caps.minImageCount < 2 ? 2 : caps.minImageCount) + 1;
    swapchain_info.imageFormat = formats[0].format;
    swapchain_info.imageColorSpace = formats[0].colorSpace;
    swapchain_info.imageExtent = caps.currentExtent.width != ~0u ? caps.currentExtent : (VkExtent2D){WIDTH, HEIGHT};
    swapchain_info.imageArrayLayers = 1;
    swapchain_info.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | (readback ? VK_IMAGE_USAGE_TRANSFER_SRC_BIT : 0);
    swapchain_info.preTransform = caps.currentTransform;
    swapchain_info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    swapchain_info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    swapchain_info.clipped = VK_TRUE;
    check(vkCreateSwapchainKHR(device, &swapchain_info, NULL, &swapchain), "vkCreateSwapchainKHR");

    /* Recreate the swap chain while holding an image, the way games do when the
     * window changes. Destroying the old one must give its drawables back:
     * KosmicKrisp 26.2 kept them, and after three a game got no more frames. */
    vkCreateFence(device, &fence_info, NULL, &fence);
    for (i = 0; i < RECREATES; i++)
    {
        check(vkAcquireNextImageKHR(device, swapchain, ACQUIRE_TIMEOUT, VK_NULL_HANDLE, fence, &idx),
              "vkAcquireNextImageKHR before recreating the swap chain");
        vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX);
        vkResetFences(device, 1, &fence);
        old = swapchain_info.oldSwapchain = swapchain;
        check(vkCreateSwapchainKHR(device, &swapchain_info, NULL, &swapchain), "recreating the swap chain");
        vkDestroySwapchainKHR(device, old, NULL);
    }
    swapchain_info.oldSwapchain = VK_NULL_HANDLE;
    printf("recreated the swap chain %d times with an image acquired\n", RECREATES);
    vkGetSwapchainImagesKHR(device, swapchain, &image_count, images);

    vkGetPhysicalDeviceMemoryProperties(phys, &mem_props);
    buffer_info.size = (VkDeviceSize)swapchain_info.imageExtent.width * swapchain_info.imageExtent.height * 4;
    buffer_info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    check(vkCreateBuffer(device, &buffer_info, NULL, &buffer), "vkCreateBuffer");
    vkGetBufferMemoryRequirements(device, buffer, &req);
    mem_info.allocationSize = req.size;
    for (i = 0; i < mem_props.memoryTypeCount; i++)
    {
        VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if ((req.memoryTypeBits & (1u << i)) && (mem_props.memoryTypes[i].propertyFlags & want) == want) break;
    }
    mem_info.memoryTypeIndex = i;
    check(vkAllocateMemory(device, &mem_info, NULL, &memory), "vkAllocateMemory");
    vkBindBufferMemory(device, buffer, memory, 0);

    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = family;
    check(vkCreateCommandPool(device, &pool_info, NULL, &pool), "vkCreateCommandPool");
    alloc_info.commandPool = pool;
    alloc_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandBufferCount = 1;
    check(vkAllocateCommandBuffers(device, &alloc_info, &cmd), "vkAllocateCommandBuffers");
    vkCreateSemaphore(device, &sem_info, NULL, &acquired);
    vkCreateSemaphore(device, &sem_info, NULL, &rendered);

    copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy.imageSubresource.layerCount = 1;
    copy.imageExtent.width = swapchain_info.imageExtent.width;
    copy.imageExtent.height = swapchain_info.imageExtent.height;
    copy.imageExtent.depth = 1;

    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t0);
    for (i = 0; i < (uint32_t)frames; i++)
    {
        VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
        VkPresentInfoKHR present = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};

        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);

        QueryPerformanceCounter(&a0);
        check(vkAcquireNextImageKHR(device, swapchain, ACQUIRE_TIMEOUT, acquired, VK_NULL_HANDLE, &idx),
              "vkAcquireNextImageKHR");
        QueryPerformanceCounter(&a1);
        acquire_ms = (a1.QuadPart - a0.QuadPart) * 1000.0 / freq.QuadPart;
        if (i > 0 && acquire_ms > slowest) slowest = acquire_ms;
        vkResetCommandBuffer(cmd, 0);
        vkBeginCommandBuffer(cmd, &begin_info);
        barrier(cmd, images[idx], VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                0, VK_ACCESS_TRANSFER_WRITE_BIT);
        vkCmdClearColorImage(cmd, images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &blue, 1, &range);
        if (i == 0 && readback)
        {
            barrier(cmd, images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT);
            vkCmdCopyImageToBuffer(cmd, images[idx], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
            barrier(cmd, images[idx], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                    VK_ACCESS_TRANSFER_READ_BIT, 0);
        }
        else
            barrier(cmd, images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                    VK_ACCESS_TRANSFER_WRITE_BIT, 0);
        vkEndCommandBuffer(cmd);

        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &acquired;
        submit.pWaitDstStageMask = &wait_stage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &rendered;
        check(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit");

        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &rendered;
        present.swapchainCount = 1;
        present.pSwapchains = &swapchain;
        present.pImageIndices = &idx;
        check(vkQueuePresentKHR(queue, &present), "vkQueuePresentKHR");
        vkQueueWaitIdle(queue);

        if (i == 0 && readback)
        {
            vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &data);
            px = (const BYTE *)data + ((swapchain_info.imageExtent.height / 2) * swapchain_info.imageExtent.width
                                       + swapchain_info.imageExtent.width / 2) * 4;
            printf("centre pixel: %u %u %u\n", px[bgra ? 2 : 0], px[1], px[bgra ? 0 : 2]);
            ok = close_to(px[bgra ? 2 : 0], 0) && close_to(px[1], 0) && close_to(px[bgra ? 0 : 2], 255);
        }
    }
    QueryPerformanceCounter(&t1);

    printf("presented %d frames in %.2f s (%.0f fps)\n", frames,
           (double)(t1.QuadPart - t0.QuadPart) / freq.QuadPart,
           frames * (double)freq.QuadPart / (t1.QuadPart - t0.QuadPart));
    printf("slowest acquire: %.0f ms\n", slowest);
    if (!readback) printf("FAIL swap chain images can't be read back\n");
    else if (!ok) printf("FAIL wrong pixel\n");
    else if (slowest > SLOW_ACQUIRE_MS)
    {
        printf("FAIL waited %.0f ms for a swap chain image, the driver is short of drawables\n", slowest);
        ok = 0;
    }
    else printf("OK\n");
    DestroyWindow(hwnd);
    return ok ? 0 : 1;
}
