/*
 * projectm_bridge_api.h — libprojectM v4 C-ABI 跨平台导出接口
 *
 * 封装 projectM-4 原生渲染管线：离屏渲染、PCM 音频注入与 .milk 预设脚本加载
 */

#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef _WIN32
  #define PROJECTM_EXPORT __declspec(dllexport)
#else
  #define PROJECTM_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef void* auradsp_projectm_t;

/**
 * 创建 projectM 实例
 *
 * @param width   渲染表面宽度 (如 1280)
 * @param height  渲染表面高度 (如 720)
 * @param fps     目标帧率 (如 60.0)
 * @return 实例句柄，失败返回 NULL
 */
PROJECTM_EXPORT auradsp_projectm_t auradsp_projectm_create(int width, int height, float fps);

/**
 * 销毁实例并释放相关资源
 */
PROJECTM_EXPORT void auradsp_projectm_destroy(auradsp_projectm_t handle);

/**
 * 重设视口渲染分辨率
 */
PROJECTM_EXPORT void auradsp_projectm_resize(auradsp_projectm_t handle, int width, int height);

/**
 * 投递音频 PCM 浮点样本
 *
 * @param handle              实例句柄
 * @param pcm                 立体声交错浮点 PCM 数据
 * @param frames_per_channel  单声道帧数 (如 512, 1024)
 * @param channels            声道数 (通常为 2)
 * @return 成功返回 0，失败返回负错误码
 */
PROJECTM_EXPORT int auradsp_projectm_feed_pcm(auradsp_projectm_t handle,
                                              const float* pcm,
                                              int frames_per_channel,
                                              int channels);

/**
 * 加载并编译指定的 MilkDrop .milk 预设文件
 *
 * @param handle       实例句柄
 * @param preset_path  .milk 预设文件的绝对路径 (UTF-8)
 * @return 成功返回 0，解析或加载失败返回负错误码
 */
PROJECTM_EXPORT int auradsp_projectm_load_preset(auradsp_projectm_t handle, const char* preset_path);

/**
 * 执行单帧渲染，并将 RGBA 像素拷贝到输出缓冲区
 *
 * @param handle           实例句柄
 * @param out_rgba_pixels  输出 RGBA 缓冲区指针 (大小必须 >= width * height * 4)
 * @return 成功返回 0
 */
PROJECTM_EXPORT int auradsp_projectm_render_pixels(auradsp_projectm_t handle, uint8_t* out_rgba_pixels);

#ifdef __cplusplus
}
#endif
