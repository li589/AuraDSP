/*
 * projectm_bridge.cpp - libprojectM v4 C-ABI bridge.
 *
 * The caller owns the current OpenGL context. All calls on one handle are
 * serialized because projectM and its OpenGL state are not thread-safe.
 */
#include "projectm_bridge_api.h"

#include <projectM-4/audio.h>
#include <projectM-4/callbacks.h>
#include <projectM-4/core.h>
#include <projectM-4/render_opengl.h>

#include <GL/gl.h>

#include <atomic>
#include <cstdint>
#include <mutex>

struct auradsp_projectm_context {
    projectm_handle pm = nullptr;
    int width = 0;
    int height = 0;
    float fps = 0.0f;
    std::atomic<bool> preset_load_failed{false};
    std::mutex mtx;
};

namespace {

void on_preset_load_failed(const char*, const char*, void* user_data) {
    auto* ctx = static_cast<auradsp_projectm_context*>(user_data);
    if (ctx != nullptr) {
        ctx->preset_load_failed.store(true, std::memory_order_release);
    }
}

void clear_gl_errors() {
    while (glGetError() != GL_NO_ERROR) {
    }
}

}  // namespace

AURADSP_PROJECTM_EXPORT auradsp_projectm_t
    auradsp_projectm_create(int width, int height, float fps) {
    if (width <= 0) width = 1280;
    if (height <= 0) height = 720;
    if (fps <= 0.0f) fps = 60.0f;

    auto* ctx = new auradsp_projectm_context();
    ctx->width = width;
    ctx->height = height;
    ctx->fps = fps;

    ctx->pm = projectm_create();
    if (ctx->pm == nullptr) {
        delete ctx;
        return nullptr;
    }

    projectm_set_window_size(ctx->pm, static_cast<size_t>(width),
                             static_cast<size_t>(height));
    projectm_set_fps(ctx->pm, static_cast<int>(fps));
    projectm_set_preset_switch_failed_event_callback(
        ctx->pm, on_preset_load_failed, ctx);
    return static_cast<auradsp_projectm_t>(ctx);
}

AURADSP_PROJECTM_EXPORT void
    auradsp_projectm_destroy(auradsp_projectm_t handle) {
    if (handle == nullptr) return;
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
    {
        std::lock_guard<std::mutex> lock(ctx->mtx);
        if (ctx->pm != nullptr) {
            projectm_set_preset_switch_failed_event_callback(ctx->pm, nullptr,
                                                              nullptr);
            projectm_destroy(ctx->pm);
            ctx->pm = nullptr;
        }
    }
    delete ctx;
}

AURADSP_PROJECTM_EXPORT void
    auradsp_projectm_resize(auradsp_projectm_t handle, int width, int height) {
    if (handle == nullptr || width <= 0 || height <= 0) return;
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
    std::lock_guard<std::mutex> lock(ctx->mtx);
    ctx->width = width;
    ctx->height = height;
    if (ctx->pm != nullptr) {
        projectm_set_window_size(ctx->pm, static_cast<size_t>(width),
                                 static_cast<size_t>(height));
    }
}

AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_get_width(auradsp_projectm_t handle) {
    if (handle == nullptr) return 0;
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
    std::lock_guard<std::mutex> lock(ctx->mtx);
    return ctx->width;
}

AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_get_height(auradsp_projectm_t handle) {
    if (handle == nullptr) return 0;
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
    std::lock_guard<std::mutex> lock(ctx->mtx);
    return ctx->height;
}

AURADSP_PROJECTM_EXPORT int auradsp_projectm_feed_pcm(
    auradsp_projectm_t handle, const float* pcm, int frames_per_channel,
    int channels) {
    if (handle == nullptr || pcm == nullptr || frames_per_channel <= 0 ||
        (channels != 1 && channels != 2)) {
        return -1;
    }
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
    std::lock_guard<std::mutex> lock(ctx->mtx);
    if (ctx->pm == nullptr) return -2;

    const projectm_channels ch =
        channels == 1 ? PROJECTM_MONO : PROJECTM_STEREO;
    projectm_pcm_add_float(ctx->pm, pcm,
                           static_cast<unsigned int>(frames_per_channel), ch);
    return 0;
}

AURADSP_PROJECTM_EXPORT int auradsp_projectm_load_preset(
    auradsp_projectm_t handle, const char* preset_path) {
    if (handle == nullptr || preset_path == nullptr || preset_path[0] == '\0') {
        return -1;
    }
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
    std::lock_guard<std::mutex> lock(ctx->mtx);
    if (ctx->pm == nullptr) return -2;

    ctx->preset_load_failed.store(false, std::memory_order_release);
    projectm_load_preset_file(ctx->pm, preset_path, true);
    return ctx->preset_load_failed.load(std::memory_order_acquire) ? -3 : 0;
}

AURADSP_PROJECTM_EXPORT int auradsp_projectm_render_pixels(
    auradsp_projectm_t handle, uint8_t* out_rgba_pixels) {
    if (handle == nullptr || out_rgba_pixels == nullptr) return -1;
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
    std::lock_guard<std::mutex> lock(ctx->mtx);
    if (ctx->pm == nullptr) return -2;

    clear_gl_errors();
    projectm_opengl_render_frame(ctx->pm);

    GLint old_pack_alignment = 4;
    glGetIntegerv(GL_PACK_ALIGNMENT, &old_pack_alignment);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, ctx->width, ctx->height, GL_RGBA, GL_UNSIGNED_BYTE,
                 out_rgba_pixels);
    glPixelStorei(GL_PACK_ALIGNMENT, old_pack_alignment);
    return glGetError() == GL_NO_ERROR ? 0 : -3;
}
