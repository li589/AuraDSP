#include <stdio.h>
#include <math.h>
#include <string.h>
extern "C" {
#include "jdsp/jdsp_header.h"
#include "jdsp/Effects/eel2/fft.h"
}
int main() {
    const int N = 4096;
    static float buf[N];
    static float hann[N];
    for (int i = 0; i < N; ++i)
        hann[i] = 0.5f * (1.0f - cosf(2.0f*3.14159265f*i/(N-1)));
    for (int i = 0; i < N; ++i)
        buf[i] = 0.3f * sinf(2.0f*3.14159265f*60.0f*i/48000.0f) * hann[i];

    /* not needed for perm tables */
    WDL_fft_init();

    WDL_real_fft(buf, N, 0);

    const int half = N/2;
    const int32_t* perm = WDL_fft_permute_tab(half);
    printf("--- via perm[i] readback ---\n");
    for (int i = 0; i < 12; ++i) {
        float re = buf[perm[i]*2], im = buf[perm[i]*2+1];
        printf("bin %2d (perm %4d): mag=%.1f  (%.1f Hz)\n", i, perm[i], sqrt(re*re+im*im), i*48000.0/N);
    }
    printf("--- natural order readback ---\n");
    for (int i = 0; i < 12; ++i) {
        float re = buf[i*2], im = buf[i*2+1];
        printf("bin %2d: mag=%.1f  (%.1f Hz)\n", i, sqrt(re*re+im*im), i*48000.0/N);
    }
    return 0;
}
