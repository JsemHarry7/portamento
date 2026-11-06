/* Cross-process GDI test: does drawing into another process's window show up?
 *
 * Chromium's software compositor draws from its GPU process into the browser
 * process's window this way, so Steam's UI depends on it.
 *
 *   xprocgdi.exe target   create a grey window and keep it open for 60 s
 *   xprocgdi.exe draw     find that window and fill it red from this process
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o xprocgdi.exe xprocgdi.c -lgdi32
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static const WCHAR title[] = L"porta xproc target";

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "target"))
    {
        HWND hwnd = CreateWindowW(L"STATIC", title, WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                  100, 100, 640, 480, NULL, NULL, NULL, NULL);
        DWORD end = GetTickCount() + 60000;
        MSG msg;

        printf("target hwnd %p pid %lu\n", hwnd, GetCurrentProcessId());
        while (GetTickCount() < end)
        {
            while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
            Sleep(10);
        }
        return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "draw"))
    {
        HWND hwnd = FindWindowW(NULL, title);
        HBRUSH red = CreateSolidBrush(RGB(255, 0, 0));
        RECT rect;
        HDC hdc;

        if (!hwnd)
        {
            printf("FAIL target window not found\n");
            return 1;
        }
        GetClientRect(hwnd, &rect);
        hdc = GetDC(hwnd);
        FillRect(hdc, &rect, red);
        GdiFlush();
        ReleaseDC(hwnd, hdc);
        printf("filled %p (%ldx%ld) from pid %lu\n", hwnd, rect.right, rect.bottom, GetCurrentProcessId());
        return 0;
    }
    printf("usage: xprocgdi.exe target|draw\n");
    return 1;
}
