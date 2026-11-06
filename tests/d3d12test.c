/* Direct3D 12 smoke test for Portamento's graphics backends.
 *
 * Creates a device and a flip-model swap chain, reports the adapter and the
 * raytracing tier, clears the back buffer, copies it to a readback buffer to
 * check the colour, then clears and presents frames to measure throughput.
 * Prints "OK" and exits 0 only if the pixel came out right.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d12test.exe d3d12test.c \
 *            -ld3d12 -ldxgi -ldxguid -luuid
 */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS  /* methods returning structs by value */
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>
#include <stdlib.h>

#define WIDTH   1280
#define HEIGHT  720
#define BUFFERS 2

static const float clear_colour[4] = {0.0f, 0.0f, 1.0f, 1.0f};

static ID3D12Device *device;
static ID3D12CommandQueue *queue;
static ID3D12Fence *fence;
static UINT64 fence_value;
static HANDLE fence_event;

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void check(HRESULT hr, const char *what)
{
    if (SUCCEEDED(hr)) return;
    printf("FAIL %s hr=%#lx\n", what, hr);
    exit(1);
}

static void wait_idle(void)
{
    check(ID3D12CommandQueue_Signal(queue, fence, ++fence_value), "Signal");
    if (ID3D12Fence_GetCompletedValue(fence) < fence_value)
    {
        ID3D12Fence_SetEventOnCompletion(fence, fence_value, fence_event);
        WaitForSingleObject(fence_event, INFINITE);
    }
}

static void transition(ID3D12GraphicsCommandList *list, ID3D12Resource *res,
                       D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER barrier = {0};

    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = res;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
}

static int close_to(BYTE value, int expect)
{
    return abs(value - expect) <= 2;
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 300;
    D3D12_COMMAND_QUEUE_DESC queue_desc = {0};
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = {0};
    D3D12_FEATURE_DATA_D3D12_OPTIONS5 options5 = {0};
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    D3D12_HEAP_PROPERTIES readback_heap = {D3D12_HEAP_TYPE_READBACK};
    D3D12_RESOURCE_DESC buffer_desc = {0}, tex_desc;
    D3D12_TEXTURE_COPY_LOCATION src = {0}, dst = {0};
    D3D12_CPU_DESCRIPTOR_HANDLE rtv_base, rtv;
    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    DXGI_ADAPTER_DESC1 ad;
    IDXGIFactory4 *factory;
    IDXGIAdapter1 *adapter;
    IDXGISwapChain1 *swapchain1;
    IDXGISwapChain3 *swapchain;
    ID3D12DescriptorHeap *rtv_heap;
    ID3D12Resource *backbuffers[BUFFERS], *readback;
    ID3D12CommandAllocator *allocator;
    ID3D12GraphicsCommandList *list;
    LARGE_INTEGER freq, t0, t1;
    WNDCLASSW wc = {0};
    UINT64 total;
    UINT rtv_size, i, idx;
    const BYTE *px;
    BYTE *data;
    HWND hwnd;
    MSG msg;
    int ok;

    setvbuf(stdout, NULL, _IONBF, 0);  /* keep the output if we hang and get killed */
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"d3d12test";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"d3d12test", L"porta d3d12 test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                         100, 100, WIDTH, HEIGHT, NULL, NULL, wc.hInstance, NULL);

    check(CreateDXGIFactory2(0, &IID_IDXGIFactory4, (void **)&factory), "CreateDXGIFactory2");
    check(IDXGIFactory4_EnumAdapters1(factory, 0, &adapter), "EnumAdapters1");
    IDXGIAdapter1_GetDesc1(adapter, &ad);
    printf("adapter: %ls\n", ad.Description);
    check(D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device),
          "D3D12CreateDevice");
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS5, &options5, sizeof(options5))))
        printf("raytracing tier: %#x\n", options5.RaytracingTier);

    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    check(ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue),
          "CreateCommandQueue");
    check(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence), "CreateFence");
    fence_event = CreateEventW(NULL, FALSE, FALSE, NULL);

    sd.Width = WIDTH;
    sd.Height = HEIGHT;
    sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = BUFFERS;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    check(IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, hwnd, &sd, NULL, NULL, &swapchain1),
          "CreateSwapChainForHwnd");
    check(IDXGISwapChain1_QueryInterface(swapchain1, &IID_IDXGISwapChain3, (void **)&swapchain), "IDXGISwapChain3");

    heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    heap_desc.NumDescriptors = BUFFERS;
    check(ID3D12Device_CreateDescriptorHeap(device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap),
          "CreateDescriptorHeap");
    rtv_size = ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    rtv_base = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(rtv_heap);
    for (i = 0; i < BUFFERS; i++)
    {
        check(IDXGISwapChain3_GetBuffer(swapchain, i, &IID_ID3D12Resource, (void **)&backbuffers[i]), "GetBuffer");
        rtv.ptr = rtv_base.ptr + i * rtv_size;
        ID3D12Device_CreateRenderTargetView(device, backbuffers[i], NULL, rtv);
    }

    check(ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator,
                                              (void **)&allocator), "CreateCommandAllocator");
    check(ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL,
                                         &IID_ID3D12GraphicsCommandList, (void **)&list), "CreateCommandList");
    ID3D12GraphicsCommandList_Close(list);

    tex_desc = ID3D12Resource_GetDesc(backbuffers[0]);
    ID3D12Device_GetCopyableFootprints(device, &tex_desc, 0, 1, 0, &footprint, NULL, NULL, &total);
    buffer_desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    buffer_desc.Width = total;
    buffer_desc.Height = buffer_desc.DepthOrArraySize = buffer_desc.MipLevels = 1;
    buffer_desc.SampleDesc.Count = 1;
    buffer_desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    check(ID3D12Device_CreateCommittedResource(device, &readback_heap, D3D12_HEAP_FLAG_NONE, &buffer_desc,
                                               D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource,
                                               (void **)&readback), "CreateCommittedResource");

    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t0);
    for (i = 0; i < (UINT)frames; i++)
    {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);

        idx = IDXGISwapChain3_GetCurrentBackBufferIndex(swapchain);
        rtv.ptr = rtv_base.ptr + idx * rtv_size;
        ID3D12CommandAllocator_Reset(allocator);
        ID3D12GraphicsCommandList_Reset(list, allocator, NULL);
        transition(list, backbuffers[idx], D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, clear_colour, 0, NULL);
        if (i == 0)
        {
            transition(list, backbuffers[idx], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
            src.pResource = backbuffers[idx];
            src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            dst.pResource = readback;
            dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            dst.PlacedFootprint = footprint;
            ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
            transition(list, backbuffers[idx], D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT);
        }
        else transition(list, backbuffers[idx], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
        check(ID3D12GraphicsCommandList_Close(list), "Close");
        ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
        check(IDXGISwapChain3_Present(swapchain, 0, 0), "Present");
        wait_idle();
    }
    QueryPerformanceCounter(&t1);

    check(ID3D12Resource_Map(readback, 0, NULL, (void **)&data), "Map");
    px = data + footprint.Offset + (HEIGHT / 2) * footprint.Footprint.RowPitch + (WIDTH / 2) * 4;
    printf("centre pixel: %u %u %u\n", px[0], px[1], px[2]);
    ok = close_to(px[0], 0) && close_to(px[1], 0) && close_to(px[2], 255);
    ID3D12Resource_Unmap(readback, 0, NULL);

    printf("presented %d frames in %.2f s (%.0f fps)\n", frames,
           (double)(t1.QuadPart - t0.QuadPart) / freq.QuadPart,
           frames * (double)freq.QuadPart / (t1.QuadPart - t0.QuadPart));
    printf("%s\n", ok ? "OK" : "FAIL wrong pixel");
    DestroyWindow(hwnd);
    return ok ? 0 : 1;
}
