/* Audio smoke test for porta: plays a 2 second 440 Hz tone through winmm
 * (winmm -> mmdevapi -> winecoreaudio -> Core Audio) on the default device
 * and reports what each step returned.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o tone.exe tone.c -lwinmm -lm
 */
#include <windows.h>
#include <mmsystem.h>
#include <math.h>
#include <stdio.h>

#define RATE    44100
#define SECONDS 2

static short samples[RATE * SECONDS * 2];

int main(void)
{
    WAVEFORMATEX fmt = {WAVE_FORMAT_PCM, 2, RATE, RATE * 4, 4, 16, 0};
    WAVEOUTCAPSW caps;
    WAVEHDR hdr = {0};
    HWAVEOUT out;
    MMRESULT res;
    int i;

    printf("output devices: %u\n", waveOutGetNumDevs());
    if (waveOutGetDevCapsW(WAVE_MAPPER, &caps, sizeof(caps)) == MMSYSERR_NOERROR)
        printf("default device: %ls\n", caps.szPname);

    for (i = 0; i < RATE * SECONDS; i++)
        samples[2 * i] = samples[2 * i + 1] = (short)(0.2 * 32767 * sin(2 * M_PI * 440 * i / RATE));

    if ((res = waveOutOpen(&out, WAVE_MAPPER, &fmt, 0, 0, CALLBACK_NULL)))
    {
        printf("FAIL waveOutOpen %u\n", res);
        return 1;
    }
    hdr.lpData = (char *)samples;
    hdr.dwBufferLength = sizeof(samples);
    waveOutPrepareHeader(out, &hdr, sizeof(hdr));
    if ((res = waveOutWrite(out, &hdr, sizeof(hdr))))
    {
        printf("FAIL waveOutWrite %u\n", res);
        return 1;
    }
    while (!(hdr.dwFlags & WHDR_DONE)) Sleep(50);
    waveOutUnprepareHeader(out, &hdr, sizeof(hdr));
    waveOutClose(out);
    printf("OK played %d s tone\n", SECONDS);
    return 0;
}
