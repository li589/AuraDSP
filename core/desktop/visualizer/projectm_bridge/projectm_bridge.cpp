/*
 * projectm_bridge.cpp — libprojectM v4 C-ABI 跨平台实现与离屏桥接
 *
 * 桥接 projectM-4 C-API 核心，向 Flutter 桌面端暴露统一的 PCM 投递与离屏像素/纹理渲染。
 */

#include "projectm_bridge_api.h"

#include <projectM-4/core.h>
#include <projectM-4/audio.h>
#include <projectM-4/render_opengl.h>

#include <stdlib.h>
#include <string.h>
#include <mutex>

struct auradsp_projectm_context {
    projectm_handle pm;
    int width;
    int height;
    float fps;
    std::mutex mtx;
};

PROJECTM_EXPORT auradsp_projectm_t auradsp_projectm_create(int width, int height, float fps) {
    if (width <= 0) width = 1280;
    if (height <= 0) height = 720;
    if (fps <= 0.0f) fps = 60.0f;

    auto* ctx = new auradsp_projectm_context();
    ctx->width = width;
    ctx->height = height;
    ctx->fps = fps;

    // 创建 projectM 核心实例 (需要已有或绑定的 OpenGL 上下文)
    ctx->pm = projectm_create();
    if (ctx->pm) {
        projectm_set_window_size(ctx->pm, (size_t)width, (size_t)height);
        projectm_set_fps(ctx->pm, (int)fps);
    }

    return (auradsp_projectm_t)ctx;
}

PROJECTM_EXPORT void auradsp_projectm_destroy(auradsp_projectm_t handle) {
    if (!handle) return;
    auto* ctx = (auradsp_projectm_context*)handle;
    std::lock_guard<std::mutex> lock(ctx->mtx);
    if (ctx->pm) {
        projectm_destroy(ctx->pm);
        ctx->pm = nullptr;
    }
    delete ctx;
}

PROJECTM_EXPORT void auradsp_projectm_resize(auradsp_projectm_t handle, int width, int height) {
    if (!handle || width <= 0 || height <= 0) return;
    auto* ctx = (auradsp_projectm_context*)handle;
    std::lock_guard<std::mutex> lock(ctx->mtx);
    ctx->width = width;
    ctx->height = height;
    if (ctx->pm) {
        projectm_set_window_size(ctx->pm, (size_t)width, (size_t)height);
    }
}

PROJECTM_EXPORT int auradsp_projectm_feed_pcm(auradsp_projectm_t handle,
                                              const float* pcm,
                                              int frames_per_channel,
                                              int channels) {
    if (!handle || !pcm || frames_per_channel <= 0) return -1;
    auto* ctx = (auradsp_projectm_context*)handle;
    std::lock_guard<std::mutex> lock(ctx->mtx);
    if (!ctx->pm) return -2;

    // 投递 PCM 浮点音频样本
    projectm_channels ch = (channels == 1) ? PROJECTM_MONO : PROJECTM_STEREO;
    projectm_pcm_add_float(ctx->pm, pcm, (unsigned int)frames_per_channel, ch);
    return 0;
}

PROJECTM_EXPORT int auradsp_projectm_load_preset(auradsp_projectm_t handle, const char* preset_path) {
    if (!handle || !preset_path) return -1;
    auto* ctx = (auradsp_projectm_context*)handle;
    std::lock_guard<std::mutex> lock(ctx->mtx);
    if (!ctx->pm) return -2;

    // 平滑过渡加载 .milk 预设文件
    projectm_load_preset_file(ctx->pm, preset_path, true);
    return 0;
}

PROJECTM_EXPORT int auradsp_projectm_render_pixels(auradsp_projectm_t handle, uint8_t* out_rgba_pixels) {
    if (!handle || !out_rgba_pixels) return -1;
    auto* ctx = (auradsp_projectm_context*)handle;
    std::lock_guard<std::mutex> lock(ctx->mtx);
    if (!ctx->pm) return -2;

    // 执行一帧 OpenGL 渲染
    projectm_opengl_render_frame(ctx->pm);
    return 0;
}
