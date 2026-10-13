// 完整复刻引擎 emit_viz：240 帧分块写入环形历史 → 4096 窗 FFT → 32 带
#include <cstdio>
#include <cmath>
#include <cstring>
extern "C" {
#include "jdsp/Effects/eel2/fft.h"
}

constexpr int kVizFftSize = 4096;
constexpr float kBandEdges[33] = {
    20, 25, 31, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
    800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000,
    12500, 16000, 18000, 19000, 20000};

static float hann[kVizFftSize];
static float viz_hist[kVizFftSize * 2];
static int viz_hist_pos = 0;
static float fft_scratch[kVizFftSize];
float g_mag_dbg[24];

void viz_write(const float* out, int frames) {
    const int mask = kVizFftSize - 1;
    for (int i = 0; i < frames; ++i) {
        viz_hist[viz_hist_pos * 2] = out[i * 2];
        viz_hist[viz_hist_pos * 2 + 1] = out[i * 2 + 1];
        viz_hist_pos = (viz_hist_pos + 1) & mask;
    }
}

void emit(float* bands, float sample_rate) {
    const int kN = kVizFftSize;
    const int mask = kN - 1;
    float* buf = fft_scratch;
    for (int i = 0; i < kN; ++i) {
        const int idx = (viz_hist_pos + i) & mask;
        buf[i] = viz_hist[idx * 2] * hann[i];
    }
    {
        // 窗内容自检：零交叉测频 + RMS
        int cross = 0;
        double rms = 0.0;
        for (int i = 1; i < kN; ++i) {
            if ((buf[i-1] <= 0 && buf[i] > 0) || (buf[i-1] >= 0 && buf[i] < 0)) cross++;
            rms += buf[i] * buf[i];
        }
        rms = sqrt(rms / kN);
        if (viz_hist_pos == 3840)  // 只打印一次（某个稳定 emit 时刻）
            printf("window check: crossings=%d -> %.1f Hz, rms=%.4f, buf[0..3]=%.4f %.4f %.4f %.4f\n",
                   cross, cross / 2.0 * (48000.0 / kN), rms, buf[0], buf[1], buf[2], buf[3]);
    }
    WDL_real_fft(buf, kN, 0);
    const int half = kN / 2;
    const int nmag = half < 2048 ? half : 2048;
    const int32_t* perm = WDL_fft_permute_tab(half);
    static float mag[2048];
    for (int i = 0; i < nmag; ++i) {
        const int pi = perm ? perm[i] : i;
        const float re = buf[pi * 2], im = buf[pi * 2 + 1];
        mag[i] = sqrtf(re * re + im * im);
    }
    {
        extern float g_mag_dbg[24];
        for (int i = 0; i < 24; ++i) g_mag_dbg[i] = mag[i];
    }
    const float bin_hz = sample_rate / (float)kN;
    const float amp_scale = 4.0f / (float)kN;
    for (int b = 0; b < 32; ++b) {
        const int lo = (int)(kBandEdges[b] / bin_hz);
        const int hi = (int)(kBandEdges[b + 1] / bin_hz);
        if (hi <= lo || lo >= nmag) { bands[b] = 0; continue; }
        const int hb = hi > nmag ? nmag : hi;
        float m = 0;
        for (int i = lo; i < hb; ++i) if (mag[i] > m) m = mag[i];
        const float amp = m * amp_scale;
        float v = 0.0f;
        if (amp > 1e-5f) v = (20.0f * log10f(amp) + 60.0f) * (1.0f / 60.0f);
        bands[b] = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
    }
}

int main() {
    for (int i = 0; i < kVizFftSize; ++i)
        hann[i] = 0.5f * (1.0f - cosf(2.0f * 3.14159265358979f * i / (kVizFftSize - 1)));
    WDL_fft_init();

    const int N = 240;
    float in[N * 2], out[N * 2];
    double phase = 0.0;
    float bands[32];
    for (int blk = 0; blk < 400; ++blk) {
        for (int n = 0; n < N; ++n) {
            float s = 0.3f * (float)sin(phase);
            phase += 2.0 * 3.14159265358979 * 60.0 / 48000.0;
            in[2*n] = s; in[2*n+1] = s;
        }
        memcpy(out, in, sizeof(out)); // 无 DSP，直通
        viz_write(out, N);            // 每块都写历史（修复点）
        if (blk % 2 == 1) {
            emit(bands, 48000.0f);
            if (blk == 399) {
                // dump raw mags for debug
                extern float g_mag_dbg[24];
                printf("mags[0:24]: ");
                for (int i = 0; i < 24; ++i) printf("%.1f ", g_mag_dbg[i]);
                printf("\n");
                printf("emit_probe bands[0:8]: ");
                for (int b = 0; b < 8; ++b) printf("%.3f ", bands[b]);
                printf("\n");
            }
        }
    }
    return 0;
}
