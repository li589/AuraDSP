/* vdc_resampler_test.c — PeakingFilterResampler 跳节错位回归（P-050 / V-02）。
 *
 * 由 smoke_ddc_parser_guard.py 在有 C 编译器（cc/gcc/clang）的环境下
 * 编译运行：本文件 + engine/legacy/jdsp/Effects/vdc.c。
 *
 * 构造 48k 域三节：+12dB@1000（保留）、+12dB@23000（在 outFs=22050 下
 * 应被跳过）、-12dB@5000（保留）。原实现的错位读法输出 {1000, 被跳节
 * 按 22050 设计的别名假节（实测峰值约 950Hz）}，5000 节被丢弃；
 * 修复后输出应为 {1000, 5000} 两节、顺序不变。
 *
 * 注：经引擎 API 不可达此路径——JamesDSPInit/SetSampleRate 的 ASRC
 * 映射使 jdsp->fs 只落 {44100, 48000} 或 (44100, 48000) 开区间，后者
 * 无节可跳。故用 C 层直测锁定函数契约，防止未来调用方/映射变更激活。
 */
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "jdsp_header.h"

int PeakingFilterResampler(DirectForm2 *inputIIR, double inFs,
                           DirectForm2 **resampledIIR, double outFs,
                           int sosCount);
void designPeakingFilter(double dbGain, double centreFreq, double fs,
                         double dBandwidthOrQOrS, double *b0, double *b1,
                         double *b2, double *a1, double *a2);
void DigitalFilterMagnitudeResponsedB(DirectForm2 *IIR, int section,
                                      double *magnitude, int NumPts);

static double peak_centre(DirectForm2 *sec, double fs)
{
    const int N = 32768;
    double *mag = (double *)malloc(N * sizeof(double));
    double best;
    int idx = 0;
    int c;
    DigitalFilterMagnitudeResponsedB(sec, 0, mag, N);
    best = fabs(mag[0]);
    for (c = 1; c < N; c++)
        if (fabs(mag[c]) > best) { best = fabs(mag[c]); idx = c; }
    free(mag);
    return idx * (fs / N / 2.0);
}

int main(void)
{
    DirectForm2 in[3];
    DirectForm2 *out = NULL;
    const double fs = 48000.0;
    int n;
    double c0, c1;
    int i;
    designPeakingFilter(12.0, 1000.0, fs, 1.0,
                        &in[0].b0, &in[0].b1, &in[0].b2, &in[0].a1, &in[0].a2);
    designPeakingFilter(12.0, 23000.0, fs, 1.0,
                        &in[1].b0, &in[1].b1, &in[1].b2, &in[1].a1, &in[1].a2);
    designPeakingFilter(-12.0, 5000.0, fs, 1.0,
                        &in[2].b0, &in[2].b1, &in[2].b2, &in[2].a1, &in[2].a2);
    for (i = 0; i < 3; i++)
        in[i].v1L = in[i].v2L = in[i].v1R = in[i].v2R = 0.0;

    n = PeakingFilterResampler(in, fs, &out, 22050.0, 3);
    printf("outSOSCount=%d\n", n);
    if (n != 2) { printf("FAIL count\n"); return 1; }
    c0 = peak_centre(&out[0], 22050.0);
    c1 = peak_centre(&out[1], 22050.0);
    printf("centres: %.0f %.0f\n", c0, c1);
    if (fabs(c0 - 1000.0) > 150.0) { printf("FAIL centre0\n"); return 1; }
    if (fabs(c1 - 5000.0) > 250.0)
    {
        printf("FAIL centre1 (expected kept 5000 section)\n");
        return 1;
    }
    printf("PASS resampler keeps {1000, 5000}, drops 23000\n");
    return 0;
}
