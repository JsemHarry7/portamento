/* List on-screen windows whose owning process name contains a pattern, so a
 * single window can be captured with `screencapture -l <id>` instead of the
 * whole screen.
 *
 * Build: clang -O2 -o wincap wincap.c -framework CoreGraphics -framework CoreFoundation
 * Usage: wincap [-a] [pattern]     prints: <window id> <owner> <width>x<height> <title>
 *        -a also lists windows that aren't on the current Space (e.g. fullscreen games)
 */
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <string.h>

static void cfstr(CFStringRef s, char *buf, size_t len)
{
    buf[0] = 0;
    if (s) CFStringGetCString(s, buf, len, kCFStringEncodingUTF8);
}

int main(int argc, char **argv)
{
    int all = argc > 1 && !strcmp(argv[1], "-a");
    const char *pattern = argc > 1 + all ? argv[1 + all] : "";
    CFArrayRef windows = CGWindowListCopyWindowInfo(all ? kCGWindowListOptionAll
                                                        : kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                    kCGNullWindowID);
    CFIndex i;

    for (i = 0; i < CFArrayGetCount(windows); i++)
    {
        CFDictionaryRef w = CFArrayGetValueAtIndex(windows, i);
        CFNumberRef num = CFDictionaryGetValue(w, kCGWindowNumber);
        CFDictionaryRef bounds = CFDictionaryGetValue(w, kCGWindowBounds);
        char owner[256], title[256];
        CGRect rect = CGRectZero;
        int id = 0;

        cfstr(CFDictionaryGetValue(w, kCGWindowOwnerName), owner, sizeof(owner));
        if (!strcasestr(owner, pattern)) continue;
        cfstr(CFDictionaryGetValue(w, kCGWindowName), title, sizeof(title));
        CFNumberGetValue(num, kCFNumberIntType, &id);
        if (bounds) CGRectMakeWithDictionaryRepresentation(bounds, &rect);
        printf("%d %s %.0fx%.0f %s\n", id, owner, rect.size.width, rect.size.height, title);
    }
    CFRelease(windows);
    return 0;
}
