/* A game switching its fullscreen resolution: a borderless window over the whole
 * screen, then ChangeDisplaySettings to another mode and the window and swap chain
 * resized to it, the way games apply a resolution picked in their settings. It
 * draws four coloured quadrants (red, green / blue, yellow), so a capture of the
 * window shows whether the picture fills the screen.
 *
 * Usage: modetest [WIDTH HEIGHT [SECONDS]]
 * Without a size it picks the largest listed mode smaller than the current one. */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static ID3D11Texture2D *quadrants(ID3D11Device *device, UINT width, UINT height)
{
    static const UINT32 colours[4] = {0xff0000ff, 0xff00ff00, 0xffff0000, 0xff00ffff};
    D3D11_TEXTURE2D_DESC td = {width, height, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0},
                               D3D11_USAGE_DEFAULT, 0, 0, 0};
    D3D11_SUBRESOURCE_DATA data = {0};
    UINT32 *pixels = malloc(width * height * 4);
    ID3D11Texture2D *tex = NULL;
    UINT x, y;

    for (y = 0; y < height; y++)
        for (x = 0; x < width; x++)
            pixels[y * width + x] = colours[(y >= height / 2) * 2 + (x >= width / 2)];
    data.pSysMem = pixels;
    data.SysMemPitch = width * 4;
    ID3D11Device_CreateTexture2D(device, &td, &data, &tex);
    free(pixels);
    return tex;
}

static void show(IDXGISwapChain *swapchain, ID3D11DeviceContext *ctx, ID3D11Texture2D *tex, DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    ID3D11Texture2D *backbuffer;
    MSG msg;

    IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer);
    while (GetTickCount() < end)
    {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)backbuffer, (ID3D11Resource *)tex);
        IDXGISwapChain_Present(swapchain, 1, 0);
    }
    ID3D11Texture2D_Release(backbuffer);
}

static void print_monitor(HWND hwnd, const char *when)
{
    MONITORINFO mi = {sizeof(mi)};
    RECT rc;

    GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), &mi);
    GetClientRect(hwnd, &rc);
    printf("%s: monitor %ldx%ld, window client %ldx%ld\n", when,
           mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top,
           rc.right, rc.bottom);
}

int main(int argc, char **argv)
{
    DEVMODEW current = {.dmSize = sizeof(current)}, mode = {.dmSize = sizeof(mode)}, target = {0};
    DXGI_SWAP_CHAIN_DESC sd = {0};
    WNDCLASSW wc = {0};
    IDXGISwapChain *swapchain;
    ID3D11Device *device;
    ID3D11DeviceContext *ctx;
    ID3D11Texture2D *tex;
    DWORD seconds = argc > 3 ? atoi(argv[3]) : 6;
    LONG ret;
    HRESULT hr;
    HWND hwnd;
    int i;

    EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &current);
    printf("current mode: %lux%lu\n", current.dmPelsWidth, current.dmPelsHeight);
    printf("modes:");
    for (i = 0; EnumDisplaySettingsW(NULL, i, &mode); i++)
    {
        if (mode.dmBitsPerPel != current.dmBitsPerPel) continue;
        printf(" %lux%lu", mode.dmPelsWidth, mode.dmPelsHeight);
        if (mode.dmPelsWidth < current.dmPelsWidth && mode.dmPelsHeight < current.dmPelsHeight
            && mode.dmPelsWidth > target.dmPelsWidth)
            target = mode;
    }
    printf("\n");
    if (argc > 2)
    {
        target = current;
        target.dmPelsWidth = atoi(argv[1]);
        target.dmPelsHeight = atoi(argv[2]);
    }
    if (!target.dmPelsWidth)
    {
        printf("FAIL no smaller mode\n");
        return 1;
    }
    target.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;

    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"modetest";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"modetest", L"porta mode test", WS_POPUP | WS_VISIBLE, 0, 0,
                         current.dmPelsWidth, current.dmPelsHeight, NULL, NULL, wc.hInstance, NULL);

    sd.BufferCount = 2;
    sd.BufferDesc.Width = current.dmPelsWidth;
    sd.BufferDesc.Height = current.dmPelsHeight;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                       D3D11_SDK_VERSION, &sd, &swapchain, &device, NULL, &ctx);
    if (FAILED(hr))
    {
        printf("FAIL D3D11CreateDeviceAndSwapChain hr=%#lx\n", hr);
        return 1;
    }

    print_monitor(hwnd, "before");
    tex = quadrants(device, current.dmPelsWidth, current.dmPelsHeight);
    show(swapchain, ctx, tex, 3000);
    ID3D11Texture2D_Release(tex);

    ret = ChangeDisplaySettingsExW(NULL, &target, NULL, CDS_FULLSCREEN, NULL);
    printf("ChangeDisplaySettings %lux%lu: %ld\n", target.dmPelsWidth, target.dmPelsHeight, ret);
    SetWindowPos(hwnd, HWND_TOP, 0, 0, target.dmPelsWidth, target.dmPelsHeight, SWP_SHOWWINDOW);
    IDXGISwapChain_ResizeBuffers(swapchain, 0, target.dmPelsWidth, target.dmPelsHeight,
                                 DXGI_FORMAT_UNKNOWN, 0);
    print_monitor(hwnd, "after");
    fflush(stdout);
    tex = quadrants(device, target.dmPelsWidth, target.dmPelsHeight);
    show(swapchain, ctx, tex, seconds * 1000);

    ChangeDisplaySettingsExW(NULL, NULL, NULL, 0, NULL);
    printf("done\n");
    return 0;
}
