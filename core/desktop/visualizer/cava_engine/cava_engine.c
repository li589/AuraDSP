/*
 * cava_engine.c — CAVA 算法核心纯 C 自洽实现
 *
 * 许可证：MIT (遵循 karlstav/cava 原作协议)
 */

#include "cava_engine.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

struct cava_engine {
    int number_of_bars;
    int sample_rate;
    int low_cut_off;
    int high_cut_off;
    int autosens;
    double noise_reduction;

    double sens;
    double framerate;

    float* cut_off_frequency;
    int* lower_cut_off_bin;
    int* upper_cut_off_bin;
    double* eq_weight;

    double* cava_fall;
    double* cava_mem;
    double* cava_peak;
    double* prev_cava_out;
};

cava_engine_t* cava_engine_create(int number_of_bars,
                                  int sample_rate,
                                  int low_cut_off,
                                  int high_cut_off,
                                  double noise_reduction,
                                  int autosens) {
    if (number_of_bars < 8 || number_of_bars > 256) number_of_bars = 32;
    if (sample_rate < 8000) sample_rate = 44100;
    if (low_cut_off < 10) low_cut_off = 50;
    if (high_cut_off <= low_cut_off || high_cut_off > sample_rate / 2) {
        high_cut_off = sample_rate / 4;
    }
    if (noise_reduction < 0.0) noise_reduction = 0.0;
    if (noise_reduction > 1.0) noise_reduction = 1.0;

    cava_engine_t* p = (cava_engine_t*)calloc(1, sizeof(cava_engine_t));
    if (!p) return NULL;

    p->number_of_bars = number_of_bars;
    p->sample_rate = sample_rate;
    p->low_cut_off = low_cut_off;
    p->high_cut_off = high_cut_off;
    p->noise_reduction = noise_reduction;
    p->autosens = autosens;
    p->sens = 1.0;
    p->framerate = 60.0;

    const size_t bars_size = (size_t)number_of_bars;
    p->cut_off_frequency = (float*)calloc(bars_size + 1, sizeof(float));
    p->lower_cut_off_bin = (int*)calloc(bars_size + 1, sizeof(int));
    p->upper_cut_off_bin = (int*)calloc(bars_size + 1, sizeof(int));
    p->eq_weight = (double*)calloc(bars_size + 1, sizeof(double));

    p->cava_fall = (double*)calloc(bars_size, sizeof(double));
    p->cava_mem = (double*)calloc(bars_size, sizeof(double));
    p->cava_peak = (double*)calloc(bars_size, sizeof(double));
    p->prev_cava_out = (double*)calloc(bars_size, sizeof(double));

    if (!p->cut_off_frequency || !p->lower_cut_off_bin || !p->upper_cut_off_bin ||
        !p->eq_weight || !p->cava_fall || !p->cava_mem || !p->cava_peak || !p->prev_cava_out) {
        cava_engine_destroy(p);
        return NULL;
    }

    // 1. 计算对数频段分布常数
    const double freq_const = log10((double)low_cut_off / (double)high_cut_off) /
                              (1.0 / ((double)number_of_bars + 1.0) - 1.0);

    for (int n = 0; n < number_of_bars + 1; ++n) {
        double bar_coef = -freq_const + ((double)n + 1.0) / ((double)number_of_bars + 1.0) * freq_const;
        p->cut_off_frequency[n] = (float)(high_cut_off * pow(10.0, bar_coef));
    }

    // 2. 映射 FFT 频段 Bin 与计算等响度权重 (pow(f, 0.85) 感知补偿)
    const float bin_hz = (float)sample_rate / 2048.0f;
    for (int n = 0; n < number_of_bars; ++n) {
        int lo = (int)floor(p->cut_off_frequency[n] / bin_hz);
        int hi = (int)ceil(p->cut_off_frequency[n + 1] / bin_hz);
        if (lo < 0) lo = 0;
        if (hi <= lo) hi = lo + 1;
        p->lower_cut_off_bin[n] = lo;
        p->upper_cut_off_bin[n] = hi;

        // 感知等响度补偿权重 (与 CAVA 原作一致)
        double count = (double)(hi - lo + 1);
        p->eq_weight[n] = pow((double)p->cut_off_frequency[n + 1], 0.85) / count / 11.0;
    }

    return p;
}

void cava_engine_destroy(cava_engine_t* p) {
    if (!p) return;
    free(p->cut_off_frequency);
    free(p->lower_cut_off_bin);
    free(p->upper_cut_off_bin);
    free(p->eq_weight);
    free(p->cava_fall);
    free(p->cava_mem);
    free(p->cava_peak);
    free(p->prev_cava_out);
    free(p);
}

void cava_engine_reset(cava_engine_t* p) {
    if (!p) return;
    const size_t sz = sizeof(double) * (size_t)p->number_of_bars;
    memset(p->cava_fall, 0, sz);
    memset(p->cava_mem, 0, sz);
    memset(p->cava_peak, 0, sz);
    memset(p->prev_cava_out, 0, sz);
    p->sens = 1.0;
}

void cava_engine_process_magnitudes(cava_engine_t* p,
                                   const float* in_mag,
                                   int nmag,
                                   float bin_hz,
                                   float* out_bars) {
    if (!p || !in_mag || !out_bars || nmag <= 0) return;

    int overshoot = 0;
    int silence = 1;

    // 帧率缩放系数
    double framerate_mod = 60.0 / p->framerate;
    double nr = p->noise_reduction > 0.05 ? p->noise_reduction : 0.05;
    double gravity_mod = pow(framerate_mod, 2.5) * 2.0 / nr;
    double integral_mod = pow(framerate_mod, 0.1);

    for (int n = 0; n < p->number_of_bars; ++n) {
        // 1. 频段能量抽取 (按当前 bin_hz 动态对齐)
        int lo = (int)floor(p->cut_off_frequency[n] / bin_hz);
        int hi = (int)ceil(p->cut_off_frequency[n + 1] / bin_hz);
        if (lo >= nmag) lo = nmag - 1;
        if (hi >= nmag) hi = nmag - 1;
        if (hi < lo) hi = lo;

        double sum = 0.0;
        for (int i = lo; i <= hi; ++i) {
            sum += in_mag[i];
        }

        // 2. 感知加权
        double val = sum * (p->eq_weight[n] * 0.015);
        if (val > 1e-4) silence = 0;

        // 3. 灵敏度增益
        if (p->autosens) {
            val *= p->sens;
        }

        // 4. 重力物理跌落 (Falloff)
        if (val < p->prev_cava_out[n] && p->noise_reduction > 0.1) {
            double fallen = p->cava_peak[n] * (1.0 - (p->cava_fall[n] * p->cava_fall[n] * gravity_mod));
            if (fallen < 0.0) fallen = 0.0;
            val = fallen;
            p->cava_fall[n] += 0.028;
        } else {
            p->cava_peak[n] = val;
            p->cava_fall[n] = 0.0;
        }
        p->prev_cava_out[n] = val;

        // 5. 积分降噪滤波 (Integral Smoothing)
        val = p->cava_mem[n] * p->noise_reduction / integral_mod + val;
        p->cava_mem[n] = val;

        // 6. 溢出检测 (Autosens 驱动)
        if (val > 1.0) {
            overshoot = 1;
            val = 1.0;
        } else if (val < 0.0) {
            val = 0.0;
        }

        out_bars[n] = (float)val;
    }

    // 7. CAVA 自动灵敏度 AGC 闭环调节
    if (p->autosens) {
        if (overshoot) {
            p->sens *= (1.0 - 0.02 * framerate_mod);
            if (p->sens < 0.1) p->sens = 0.1;
        } else if (!silence) {
            p->sens *= (1.0 + 0.001 * framerate_mod);
            if (p->sens > 60.0) p->sens = 60.0;
        }
    }
}

void cava_engine_get_cutoffs(const cava_engine_t* p, float* out_cutoffs) {
    if (!p || !out_cutoffs) return;
    for (int i = 0; i <= p->number_of_bars; ++i) {
        out_cutoffs[i] = p->cut_off_frequency[i];
    }
}

void cava_engine_set_autosens(cava_engine_t* p, int enabled) {
    if (p) p->autosens = enabled ? 1 : 0;
}

double cava_engine_get_sens(const cava_engine_t* p) {
    return p ? p->sens : 1.0;
}
