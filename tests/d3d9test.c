/* Direct3D 9 smoke test for Portamento's graphics backends.
 *
 * Fixed-function only: clears to blue, draws an orange pre-transformed
 * triangle, reads the back buffer back to check both, then presents frames to
 * measure throughput.  Prints "OK" and exits 0 only if the pixels came out
 * right.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d9test.exe d3d9test.c -ld3d9
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>

#define WIDTH  1280
#define HEIGHT 720

struct vertex
{
    float x, y, z, rhw;
    DWORD colour;
};

/* the same triangle as the D3D11 test, in screen coordinates */
static const struct vertex triangle[] =
{
    { 640.0f, 108.0f, 0.5f, 1.0f, D3DCOLOR_XRGB(255, 128, 0)},
    {1088.0f, 612.0f, 0.5f, 1.0f, D3DCOLOR_XRGB(255, 128, 0)},
    { 192.0f, 612.0f, 0.5f, 1.0f, D3DCOLOR_XRGB(255, 128, 0)},
};

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
    D3DPRESENT_PARAMETERS pp = {0};
    D3DADAPTER_IDENTIFIER9 id;
    IDirect3DSurface9 *backbuffer, *sysmem;
    IDirect3DDevice9 *device;
    D3DLOCKED_RECT lr;
    LARGE_INTEGER freq, t0, t1;
    WNDCLASSW wc = {0};
    const BYTE *tri, *bg;
    IDirect3D9 *d3d;
    HRESULT hr;
    HWND hwnd;
    MSG msg;
    int i, ok = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"d3d9test";
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"d3d9test", L"porta d3d9 test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                         100, 100, WIDTH, HEIGHT, NULL, NULL, wc.hInstance, NULL);

    if (!(d3d = Direct3DCreate9(D3D_SDK_VERSION)))
    {
        printf("FAIL Direct3DCreate9\n");
        return 1;
    }
    IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id);
    printf("adapter: %s\n", id.Description);

    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = WIDTH;
    pp.BackBufferHeight = HEIGHT;
    pp.hDeviceWindow = hwnd;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                 D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device);
    if (FAILED(hr))
        hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                     D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &device);
    if (FAILED(hr))
    {
        printf("FAIL CreateDevice hr=%#lx\n", hr);
        return 1;
    }
    IDirect3DDevice9_SetRenderState(device, D3DRS_CULLMODE, D3DCULL_NONE);
    IDirect3DDevice9_SetRenderState(device, D3DRS_LIGHTING, FALSE);
    IDirect3DDevice9_SetFVF(device, D3DFVF_XYZRHW | D3DFVF_DIFFUSE);
    IDirect3DDevice9_CreateOffscreenPlainSurface(device, WIDTH, HEIGHT, D3DFMT_X8R8G8B8,
                                                 D3DPOOL_SYSTEMMEM, &sysmem, NULL);

    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t0);
    for (i = 0; i < frames; i++)
    {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);

        IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(0, 0, 255), 1.0f, 0);
        IDirect3DDevice9_BeginScene(device);
        IDirect3DDevice9_DrawPrimitiveUP(device, D3DPT_TRIANGLELIST, 1, triangle, sizeof(triangle[0]));
        IDirect3DDevice9_EndScene(device);
        if (i == 0)
        {
            IDirect3DDevice9_GetBackBuffer(device, 0, 0, D3DBACKBUFFER_TYPE_MONO, &backbuffer);
            IDirect3DDevice9_GetRenderTargetData(device, backbuffer, sysmem);
            IDirect3DSurface9_Release(backbuffer);
            if (FAILED(IDirect3DSurface9_LockRect(sysmem, &lr, NULL, D3DLOCK_READONLY)))
            {
                printf("FAIL LockRect\n");
                return 1;
            }
            /* X8R8G8B8 is B, G, R, X in memory; centroid as in the D3D11 test */
            tri = (const BYTE *)lr.pBits + 443 * lr.Pitch + 640 * 4;
            bg = (const BYTE *)lr.pBits + 10 * lr.Pitch + 10 * 4;
            printf("triangle pixel: %u %u %u, background pixel: %u %u %u\n",
                   tri[2], tri[1], tri[0], bg[2], bg[1], bg[0]);
            ok = close_to(tri[2], 255) && close_to(tri[1], 128) && close_to(tri[0], 0)
                 && close_to(bg[2], 0) && close_to(bg[1], 0) && close_to(bg[0], 255);
            IDirect3DSurface9_UnlockRect(sysmem);
        }
        IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
    }
    QueryPerformanceCounter(&t1);

    printf("presented %d frames in %.2f s (%.0f fps)\n", frames,
           (double)(t1.QuadPart - t0.QuadPart) / freq.QuadPart,
           frames * (double)freq.QuadPart / (t1.QuadPart - t0.QuadPart));
    printf("%s\n", ok ? "OK" : "FAIL wrong pixels");
    DestroyWindow(hwnd);
    return ok ? 0 : 1;
}
