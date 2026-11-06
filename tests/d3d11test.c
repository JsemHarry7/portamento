/* Direct3D 11 smoke test for Portamento's graphics backends.
 *
 * Opens a window, draws a shaded triangle on a clear colour, reads the back
 * buffer back to check both, then presents frames to measure throughput.
 * Prints "OK" and exits 0 only if the pixels came out right.  With a second
 * argument "resize" it also resizes the window and swap chain and checks again.
 *
 * The shaders are precompiled (shadergen.c) so the result doesn't depend on
 * the d3dcompiler of the Wine under test.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d11test.exe d3d11test.c \
 *            -ld3d11 -ldxguid -luuid
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "d3d11test_shaders.h"

#define WIDTH  1280
#define HEIGHT 720

static const float clear_colour[4] = {0.0f, 0.0f, 1.0f, 1.0f};

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static int close_to(BYTE value, int expect)
{
    return abs(value - expect) <= 2;
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 300;
    WNDCLASSW wc = {0};
    DXGI_SWAP_CHAIN_DESC sd = {0};
    D3D11_TEXTURE2D_DESC td;
    D3D11_VIEWPORT vp = {0, 0, WIDTH, HEIGHT, 0, 1};
    D3D11_MAPPED_SUBRESOURCE map;
    IDXGISwapChain *swapchain;
    ID3D11Device *device;
    ID3D11DeviceContext *ctx;
    ID3D11Texture2D *backbuffer, *staging;
    ID3D11RenderTargetView *rtv;
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps;
    IDXGIDevice *dxgi_device;
    IDXGIAdapter *adapter;
    DXGI_ADAPTER_DESC ad;
    D3D_FEATURE_LEVEL level;
    LARGE_INTEGER freq, t0, t1;
    const BYTE *tri, *bg;
    HRESULT hr;
    HWND hwnd;
    MSG msg;
    int i, ok;

    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"d3d11test";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"d3d11test", L"porta d3d11 test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                         100, 100, WIDTH, HEIGHT, NULL, NULL, wc.hInstance, NULL);

    sd.BufferCount = 1;
    sd.BufferDesc.Width = WIDTH;
    sd.BufferDesc.Height = HEIGHT;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                       D3D11_SDK_VERSION, &sd, &swapchain, &device, &level, &ctx);
    if (FAILED(hr))
    {
        printf("FAIL D3D11CreateDeviceAndSwapChain hr=%#lx\n", hr);
        return 1;
    }

    ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_device);
    IDXGIDevice_GetAdapter(dxgi_device, &adapter);
    IDXGIAdapter_GetDesc(adapter, &ad);
    printf("adapter: %ls\nfeature level: %#x\n", ad.Description, level);

    IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)backbuffer, NULL, &rtv);

    if (FAILED(hr = ID3D11Device_CreateVertexShader(device, vs_code, sizeof(vs_code), NULL, &vs)) ||
        FAILED(hr = ID3D11Device_CreatePixelShader(device, ps_code, sizeof(ps_code), NULL, &ps)))
    {
        printf("FAIL creating shaders hr=%#lx\n", hr);
        return 1;
    }

    ID3D11Texture2D_GetDesc(backbuffer, &td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Device_CreateTexture2D(device, &td, NULL, &staging);

    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t0);
    for (i = 0; i < frames; i++)
    {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);

        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear_colour);
        ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
        ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
        ID3D11DeviceContext_Draw(ctx, 3, 0);
        if (i == 0) ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)backbuffer);
        IDXGISwapChain_Present(swapchain, 0, 0);
    }
    QueryPerformanceCounter(&t1);

    hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
    if (FAILED(hr))
    {
        printf("FAIL Map hr=%#lx\n", hr);
        return 1;
    }
    /* triangle centroid sits at NDC (0, -0.23), i.e. about (640, 443) */
    tri = (const BYTE *)map.pData + 443 * map.RowPitch + 640 * 4;
    bg = (const BYTE *)map.pData + 10 * map.RowPitch + 10 * 4;
    printf("triangle pixel: %u %u %u, background pixel: %u %u %u\n",
           tri[0], tri[1], tri[2], bg[0], bg[1], bg[2]);
    ok = close_to(tri[0], 255) && close_to(tri[1], 128) && close_to(tri[2], 0)
         && close_to(bg[0], 0) && close_to(bg[1], 0) && close_to(bg[2], 255);
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);

    printf("presented %d frames in %.2f s (%.0f fps)\n", frames,
           (double)(t1.QuadPart - t0.QuadPart) / freq.QuadPart,
           frames * (double)freq.QuadPart / (t1.QuadPart - t0.QuadPart));

    /* resize the window and swap chain the way games do on a mode change */
    if (ok && argc > 2 && !strcmp(argv[2], "resize"))
    {
        SetWindowPos(hwnd, NULL, 0, 0, 1600, 900, SWP_NOMOVE | SWP_NOZORDER);
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 0, NULL, NULL);
        ID3D11RenderTargetView_Release(rtv);
        ID3D11Texture2D_Release(backbuffer);
        ID3D11Texture2D_Release(staging);
        hr = IDXGISwapChain_ResizeBuffers(swapchain, 0, 0, 0, DXGI_FORMAT_UNKNOWN, 0);
        if (FAILED(hr))
        {
            printf("FAIL ResizeBuffers hr=%#lx\n", hr);
            return 1;
        }
        IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer);
        ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)backbuffer, NULL, &rtv);
        ID3D11Texture2D_GetDesc(backbuffer, &td);
        printf("resized back buffer: %ux%u\n", td.Width, td.Height);
        vp.Width = td.Width;
        vp.Height = td.Height;
        td.Usage = D3D11_USAGE_STAGING;
        td.BindFlags = 0;
        td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        ID3D11Device_CreateTexture2D(device, &td, NULL, &staging);

        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear_colour);
        ID3D11DeviceContext_Draw(ctx, 3, 0);
        ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)backbuffer);
        IDXGISwapChain_Present(swapchain, 0, 0);

        ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
        /* same centroid, scaled to the new client size */
        tri = (const BYTE *)map.pData + (UINT)(td.Height * 0.615) * map.RowPitch + td.Width / 2 * 4;
        ok = td.Width > WIDTH && close_to(tri[0], 255) && close_to(tri[1], 128) && close_to(tri[2], 0);
        printf("after resize triangle pixel: %u %u %u\n", tri[0], tri[1], tri[2]);
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    }
    printf("%s\n", ok ? "OK" : "FAIL wrong pixels");
    DestroyWindow(hwnd);
    return ok ? 0 : 1;
}
