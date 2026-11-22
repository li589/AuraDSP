/*
 * cava_engine.h — CAVA 标准音频可视化特征提取引擎 (Clean C-ABI)
 *
 * 算法来源：karlstav/cava (MIT License)
 * 职责：对数分频、感知等响加权、物理重力下坠、积分降噪平滑与动态自适应灵敏度 (Autosens AGC)。
 */

#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cava_engine cava_engine_t;

/**
 * 创建 CAVA 特征提取引擎实例
 *
 * @param number_of_bars  目标可视化频段数量 (如 16, 24, 32, 64, 128)
 * @param sample_rate     采样率 (如 44100, 48000)
 * @param low_cut_off     低频截止 (Hz, 推荐 50)
 * @param high_cut_off    高频截止 (Hz, 推荐 12000)
 * @param noise_reduction 积分平滑系数 (0.0 ~ 1.0, 推荐 0.77)
 * @param autosens        是否开启自动灵敏度调节 (1 = 开启, 0 = 关闭)
 * @return 引擎指针，失败返回 NULL
 */
cava_engine_t* cava_engine_create(int number_of_bars,
                                  int sample_rate,
                                  int low_cut_off,
                                  int high_cut_off,
                                  double noise_reduction,
                                  int autosens);

/**
 * 销毁引擎实例并释放内存
 */
void cava_engine_destroy(cava_engine_t* engine);

/**
 * 重置引擎内部物理状态 (重力速度、记忆积分、峰值)
 */
void cava_engine_reset(cava_engine_t* engine);

/**
 * 处理 FFT 频域幅度谱 (直接复用主引擎计算好的 FFT 频点，零冗余开销)
 *
 * @param engine    引擎指针
 * @param in_mag    FFT 线性幅度谱输入数组 (长度 nmag)
 * @param nmag      输入频点数 (如 1024, 2048)
 * @param bin_hz    每个频点对应的 Hz 步长 (sample_rate / fft_size)
 * @param out_bars  输出的 CAVA 特征频带数组 (长度 number_of_bars，值域归一化 [0.0, 1.0])
 */
void cava_engine_process_magnitudes(cava_engine_t* engine,
                                   const float* in_mag,
                                   int nmag,
                                   float bin_hz,
                                   float* out_bars);

/**
 * 获取各频带中心截止频率
 */
void cava_engine_get_cutoffs(const cava_engine_t* engine, float* out_cutoffs);

/**
 * 切换自动灵敏度状态
 */
void cava_engine_set_autosens(cava_engine_t* engine, int enabled);

/**
 * 获取当前自动灵敏度增益系数
 */
double cava_engine_get_sens(const cava_engine_t* engine);

#ifdef __cplusplus
}
#endif
