/* Benchmark and correctness check for vkCmdDrawIndexedIndirectCount on a
 * Vulkan driver, run natively on macOS (under Rosetta for the x86_64 build
 * Wine uses).  Each indirect command draws one cell of a 32x32 grid; the cell
 * turns green only if gl_DrawID and gl_InstanceIndex match it, so a frame read
 * back after the draws shows which commands ran and whether they saw the
 * right draw parameters.
 *
 *   kkbench [-m max] [-n count] [-c calls] [-f frames] [-mode dic|mdi|direct]
 *
 * dic:    `calls` x vkCmdDrawIndexedIndirectCount(maxDrawCount = max), the
 *         GPU-side count buffer says `count`
 * order:  the count is written on the GPU (vkCmdFillBuffer) before each of two
 *         render passes, `count` cells from cell 0, then count/2 from cell 512:
 *         checks that a driver's work for the draws sees those writes
 * mdi:    `calls` x vkCmdDrawIndexedIndirect(drawCount = count)
 * direct: `calls` x `count` x vkCmdDrawIndexed
 *
 * Prints the CPU time spent recording a frame and the time until the GPU
 * finished it.  Exits 1 if any cell is wrong.
 *
 * Build: tests/kkbench/build.sh
 * Run:   VK_DRIVER_FILES=<icd.json> arch -x86_64 tests/kkbench/kkbench
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "draw_vert.h"
#include "draw_frag.h"

#define SIZE 512
#define GRID 32
#define CELLS (GRID * GRID)

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
    fprintf(stderr, "%s failed: %d\n", #x, r_); exit(2); } } while (0)

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static VkPhysicalDeviceMemoryProperties mem_props;

static uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags want)
{
    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mem_props.memoryTypes[i].propertyFlags & want) == want)
            return i;
    fprintf(stderr, "no memory type\n");
    exit(2);
}

struct buffer { VkBuffer buf; VkDeviceMemory mem; void *map; };

static struct buffer make_buffer(VkDevice dev, VkDeviceSize size, VkBufferUsageFlags usage)
{
    struct buffer b;
    VkBufferCreateInfo info = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
                                .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CHECK(vkCreateBuffer(dev, &info, NULL, &b.buf));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(dev, b.buf, &req);
    VkMemoryAllocateInfo alloc = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
        .memoryTypeIndex = memory_type(req.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
    CHECK(vkAllocateMemory(dev, &alloc, NULL, &b.mem));
    CHECK(vkBindBufferMemory(dev, b.buf, b.mem, 0));
    CHECK(vkMapMemory(dev, b.mem, 0, VK_WHOLE_SIZE, 0, &b.map));
    return b;
}

static VkShaderModule make_shader(VkDevice dev, const uint32_t *code, size_t size)
{
    VkShaderModuleCreateInfo info = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                      .codeSize = size, .pCode = code };
    VkShaderModule m;
    CHECK(vkCreateShaderModule(dev, &info, NULL, &m));
    return m;
}

int main(int argc, char **argv)
{
    uint32_t max = 578, count = 40, calls = 14, frames = 30;
    const char *mode = "dic";
    int robust = 0;
    for (int i = 1; i < argc; i += 2) {
        if (!strcmp(argv[i], "-robust")) { robust = 1; i--; continue; }
        if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", argv[i]); return 2; }
        if (!strcmp(argv[i], "-m")) max = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "-n")) count = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "-c")) calls = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "-f")) frames = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "-mode")) mode = argv[i + 1];
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (max > CELLS) max = CELLS;
    int order = !strcmp(mode, "order");
    if (order) {
        max = 256;
        calls = 1;
        if (count > max) count = max;
    }
    uint32_t drawn = !strcmp(mode, "dic") ? (count < max ? count : max) : count;
    if (drawn > CELLS) drawn = CELLS;

    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "kkbench",
                              .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo inst_info = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance inst;
    CHECK(vkCreateInstance(&inst_info, NULL, &inst));
    uint32_t n = 1;
    VkPhysicalDevice phys;
    vkEnumeratePhysicalDevices(inst, &n, &phys);
    if (!n) { fprintf(stderr, "no Vulkan device\n"); return 2; }
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(phys, &props);
    vkGetPhysicalDeviceMemoryProperties(phys, &mem_props);
    printf("device: %s, mode %s, max %u, count %u, calls %u%s\n", props.deviceName, mode, max, count, calls,
           robust ? ", robustBufferAccess2" : "");

    float prio = 1.0f;
    VkDeviceQueueCreateInfo queue_info = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                           .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
    /* robustBufferAccess2 is what DXVK, vkd3d-proton and many engines enable */
    VkPhysicalDeviceRobustness2FeaturesEXT robust2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
                                                        .robustBufferAccess2 = VK_TRUE };
    VkPhysicalDeviceVulkan13Features f13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
                                             .pNext = robust ? &robust2 : NULL, .dynamicRendering = VK_TRUE };
    VkPhysicalDeviceVulkan12Features f12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
                                             .pNext = &f13, .drawIndirectCount = VK_TRUE };
    VkPhysicalDeviceVulkan11Features f11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
                                             .pNext = &f12, .shaderDrawParameters = VK_TRUE };
    VkPhysicalDeviceFeatures2 features = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f11,
                                           .features.multiDrawIndirect = VK_TRUE,
                                           .features.robustBufferAccess = robust };
    const char *robust_ext = VK_EXT_ROBUSTNESS_2_EXTENSION_NAME;
    VkDeviceCreateInfo dev_info = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &features,
                                    .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_info,
                                    .enabledExtensionCount = robust, .ppEnabledExtensionNames = &robust_ext };
    VkDevice dev;
    CHECK(vkCreateDevice(phys, &dev_info, NULL, &dev));
    VkQueue queue;
    vkGetDeviceQueue(dev, 0, 0, &queue);

    /* render target and readback buffer */
    VkImageCreateInfo img_info = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { SIZE, SIZE, 1 }, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
    VkImage image;
    CHECK(vkCreateImage(dev, &img_info, NULL, &image));
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(dev, image, &req);
    VkMemoryAllocateInfo alloc = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
        .memoryTypeIndex = memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    VkDeviceMemory image_mem;
    CHECK(vkAllocateMemory(dev, &alloc, NULL, &image_mem));
    CHECK(vkBindImageMemory(dev, image, image_mem, 0));
    VkImageViewCreateInfo view_info = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    VkImageView view;
    CHECK(vkCreateImageView(dev, &view_info, NULL, &view));
    struct buffer readback = make_buffer(dev, SIZE * SIZE * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);

    /* geometry: one quad per cell, the cell selected by vertexOffset */
    struct buffer index = make_buffer(dev, 6 * sizeof(uint16_t), VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    memcpy(index.map, (uint16_t[]){ 0, 1, 2, 2, 1, 3 }, 6 * sizeof(uint16_t));
    struct buffer indirect = make_buffer(dev, CELLS * sizeof(VkDrawIndexedIndirectCommand),
                                         VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);
    VkDrawIndexedIndirectCommand *cmds = indirect.map;
    for (uint32_t i = 0; i < CELLS; i++)
        cmds[i] = (VkDrawIndexedIndirectCommand){ .indexCount = 6, .instanceCount = 1, .firstIndex = 0,
                                                  .vertexOffset = 4 * i, .firstInstance = i };
    struct buffer count_buf = make_buffer(dev, sizeof(uint32_t),
                                          VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    *(uint32_t *)count_buf.map = order ? 0 : count;

    /* pipeline */
    VkShaderModule vs = make_shader(dev, draw_vert, sizeof(draw_vert));
    VkShaderModule fs = make_shader(dev, draw_frag, sizeof(draw_frag));
    VkPushConstantRange push = { VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(int32_t) };
    VkPipelineLayoutCreateInfo layout_info = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                                               .pushConstantRangeCount = 1, .pPushConstantRanges = &push };
    VkPipelineLayout layout;
    CHECK(vkCreatePipelineLayout(dev, &layout_info, NULL, &layout));
    VkPipelineShaderStageCreateInfo stages[2] = {
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
          .module = vs, .pName = "main" },
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
          .module = fs, .pName = "main" } };
    VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                                                  .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    VkViewport viewport = { 0, 0, SIZE, SIZE, 0, 1 };
    VkRect2D scissor = { { 0, 0 }, { SIZE, SIZE } };
    VkPipelineViewportStateCreateInfo vp = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor };
    VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
    VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                                                .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
    VkPipelineColorBlendAttachmentState blend_att = { .colorWriteMask = 0xf };
    VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                                               .attachmentCount = 1, .pAttachments = &blend_att };
    VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
    VkPipelineRenderingCreateInfo rendering = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
                                                .colorAttachmentCount = 1, .pColorAttachmentFormats = &fmt };
    VkGraphicsPipelineCreateInfo pipe_info = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &rendering, .stageCount = 2, .pStages = stages, .pVertexInputState = &vi,
        .pInputAssemblyState = &ia, .pViewportState = &vp, .pRasterizationState = &rs,
        .pMultisampleState = &ms, .pColorBlendState = &cb, .layout = layout };
    VkPipeline pipeline;
    CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &pipe_info, NULL, &pipeline));

    VkCommandPoolCreateInfo pool_info = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0 };
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(dev, &pool_info, NULL, &pool));
    VkCommandBufferAllocateInfo cb_info = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cmd;
    CHECK(vkAllocateCommandBuffers(dev, &cb_info, &cmd));

    double record_total = 0, frame_total = 0, record_min = 1e9;
    for (uint32_t frame = 0; frame < frames; frame++) {
        double t0 = now();
        CHECK(vkResetCommandBuffer(cmd, 0));
        VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                           .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        CHECK(vkBeginCommandBuffer(cmd, &begin));
        VkImageMemoryBarrier to_color = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                             VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &to_color);
        VkRenderingAttachmentInfo color = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = view, .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue.color.float32 = { 0, 0, 0, 1 } };
        VkRenderingInfo render = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = scissor,
                                   .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &color };
        double r0 = now(), r1;
        if (order) {
            uint32_t counts[2] = { count, count / 2 }, firsts[2] = { 0, 512 };
            for (int pass = 0; pass < 2; pass++) {
                VkBufferMemoryBarrier written = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
                    .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_INDIRECT_COMMAND_READ_BIT,
                    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                    .buffer = count_buf.buf, .size = VK_WHOLE_SIZE };
                VkBufferMemoryBarrier reread = written;
                reread.srcAccessMask = VK_ACCESS_INDIRECT_COMMAND_READ_BIT;
                reread.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
                if (pass)
                    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                         0, 0, NULL, 1, &reread, 0, NULL);
                vkCmdFillBuffer(cmd, count_buf.buf, 0, sizeof(uint32_t), counts[pass]);
                vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
                                     0, 0, NULL, 1, &written, 0, NULL);
                color.loadOp = pass ? VK_ATTACHMENT_LOAD_OP_LOAD : VK_ATTACHMENT_LOAD_OP_CLEAR;
                vkCmdBeginRendering(cmd, &render);
                vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
                vkCmdBindIndexBuffer(cmd, index.buf, 0, VK_INDEX_TYPE_UINT16);
                int32_t base = firsts[pass];
                vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(base), &base);
                vkCmdDrawIndexedIndirectCount(cmd, indirect.buf, firsts[pass] * sizeof(VkDrawIndexedIndirectCommand),
                                              count_buf.buf, 0, max, sizeof(VkDrawIndexedIndirectCommand));
                vkCmdEndRendering(cmd);
            }
            r1 = now();
        } else {
            vkCmdBeginRendering(cmd, &render);
            vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            vkCmdBindIndexBuffer(cmd, index.buf, 0, VK_INDEX_TYPE_UINT16);
            int32_t base = 0;
            vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(base), &base);
            r0 = now();
            for (uint32_t c = 0; c < calls; c++) {
                if (!strcmp(mode, "dic"))
                    vkCmdDrawIndexedIndirectCount(cmd, indirect.buf, 0, count_buf.buf, 0, max,
                                                  sizeof(VkDrawIndexedIndirectCommand));
                else if (!strcmp(mode, "mdi"))
                    vkCmdDrawIndexedIndirect(cmd, indirect.buf, 0, drawn, sizeof(VkDrawIndexedIndirectCommand));
                else
                    for (uint32_t i = 0; i < drawn; i++)  /* gl_DrawID is 0 here: cells come out red */
                        vkCmdDrawIndexed(cmd, 6, 1, 0, 4 * i, i);
            }
            r1 = now();
            vkCmdEndRendering(cmd);
        }
        VkImageMemoryBarrier to_copy = to_color;
        to_copy.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        to_copy.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        to_copy.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        to_copy.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &to_copy);
        VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                                     .imageExtent = { SIZE, SIZE, 1 } };
        vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buf, 1, &region);
        CHECK(vkEndCommandBuffer(cmd));
        VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
        CHECK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
        CHECK(vkQueueWaitIdle(queue));
        double t1 = now();
        if (frame > 0) {  /* the first frame compiles pipelines */
            record_total += r1 - r0;
            frame_total += t1 - t0;
            if (r1 - r0 < record_min) record_min = r1 - r0;
        }
    }

    /* check every cell: drawn ones green, the rest of the grid black */
    const uint8_t *px = readback.map;
    uint32_t bad = 0, red = 0;
    for (uint32_t i = 0; i < CELLS; i++) {
        uint32_t x = (i % GRID) * (SIZE / GRID) + SIZE / GRID / 2;
        uint32_t y = (i / GRID) * (SIZE / GRID) + SIZE / GRID / 2;
        const uint8_t *p = px + (y * SIZE + x) * 4;
        int green = p[0] < 16 && p[1] > 240 && p[2] < 16;
        if (!strcmp(mode, "direct"))
            green = p[2] < 16 && (p[0] > 240) != (p[1] > 240);
        int black = p[0] < 16 && p[1] < 16 && p[2] < 16;
        red += p[0] > 240;
        int expect = order ? (i < count || (i >= 512 && i < 512 + count / 2)) : i < drawn;
        if (expect ? !green : !black) {
            if (bad < 5)
                fprintf(stderr, "cell %u: %02x%02x%02x, expected %s\n", i, p[0], p[1], p[2],
                        expect ? "green" : "black");
            bad++;
        }
    }
    uint32_t measured = frames > 1 ? frames - 1 : 1;
    uint32_t encoded = order ? 2 * max : calls * (!strcmp(mode, "dic") ? max : drawn);
    printf("record %.2f ms/frame (min %.2f), %.2f us per API draw (%u), frame %.2f ms\n",
           record_total / measured * 1e3, record_min * 1e3, record_total / measured * 1e6 / encoded,
           encoded, frame_total / measured * 1e3);
    if (bad) {
        printf("FAIL: %u wrong cells (%u red)\n", bad, red);
        return 1;
    }
    printf("OK: %u cells drawn\n", drawn);
    return 0;
}
