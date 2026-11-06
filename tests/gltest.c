/* OpenGL smoke test for porta.
 *
 * Creates a WGL context, clears to blue, draws an orange triangle in
 * immediate mode, reads the back buffer back to check both, then swaps frames
 * to measure throughput.  Prints "OK" and exits 0 only if the pixels came out
 * right.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o gltest.exe gltest.c -lopengl32 -lgdi32
 */
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>

#define WIDTH  1280
#define HEIGHT 720

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
    PIXELFORMATDESCRIPTOR pfd = {sizeof(pfd), 1};
    LARGE_INTEGER freq, t0, t1;
    WNDCLASSW wc = {0};
    BYTE tri[4], bg[4];
    int i, format, ok = 0;
    RECT client;
    HGLRC ctx;
    HWND hwnd;
    MSG msg;
    HDC hdc;

    setvbuf(stdout, NULL, _IONBF, 0);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"gltest";
    wc.style = CS_OWNDC;
    RegisterClassW(&wc);
    hwnd = CreateWindowW(L"gltest", L"porta opengl test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                         100, 100, WIDTH, HEIGHT, NULL, NULL, wc.hInstance, NULL);
    hdc = GetDC(hwnd);

    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    if (!(format = ChoosePixelFormat(hdc, &pfd)) || !SetPixelFormat(hdc, format, &pfd))
    {
        printf("FAIL no pixel format\n");
        return 1;
    }
    if (!(ctx = wglCreateContext(hdc)) || !wglMakeCurrent(hdc, ctx))
    {
        printf("FAIL wglCreateContext\n");
        return 1;
    }
    printf("renderer: %s / %s / %s\n", glGetString(GL_VENDOR), glGetString(GL_RENDERER),
           glGetString(GL_VERSION));

    GetClientRect(hwnd, &client);
    glViewport(0, 0, client.right, client.bottom);

    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t0);
    for (i = 0; i < frames; i++)
    {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);

        glClearColor(0.0f, 0.0f, 1.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glColor3ub(255, 128, 0);
        glBegin(GL_TRIANGLES);
        glVertex2f(0.0f, 0.7f);
        glVertex2f(0.7f, -0.7f);
        glVertex2f(-0.7f, -0.7f);
        glEnd();
        if (i == 0)
        {
            /* centroid at NDC (0, -0.23); GL rows count from the bottom */
            glReadBuffer(GL_BACK);
            glReadPixels(client.right / 2, (int)(client.bottom * 0.383), 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, tri);
            glReadPixels(10, client.bottom - 10, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, bg);
            printf("triangle pixel: %u %u %u, background pixel: %u %u %u\n",
                   tri[0], tri[1], tri[2], bg[0], bg[1], bg[2]);
            ok = close_to(tri[0], 255) && close_to(tri[1], 128) && close_to(tri[2], 0)
                 && close_to(bg[0], 0) && close_to(bg[1], 0) && close_to(bg[2], 255);
        }
        SwapBuffers(hdc);
    }
    glFinish();
    QueryPerformanceCounter(&t1);

    printf("presented %d frames in %.2f s (%.0f fps)\n", frames,
           (double)(t1.QuadPart - t0.QuadPart) / freq.QuadPart,
           frames * (double)freq.QuadPart / (t1.QuadPart - t0.QuadPart));
    printf("%s\n", ok ? "OK" : "FAIL wrong pixels");
    wglMakeCurrent(NULL, NULL);
    wglDeleteContext(ctx);
    DestroyWindow(hwnd);
    return ok ? 0 : 1;
}
