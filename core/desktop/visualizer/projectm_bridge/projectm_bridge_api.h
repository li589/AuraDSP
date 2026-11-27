/*
 * projectm_bridge_api.h - libprojectM v4 C-ABI bridge.
 *
 * The bridge owns an OpenGL-backed projectM instance AND its OpenGL
 * context (amended 2026-11-23, wiring round W3): a dedicated render
 * thread inside the bridge holds a hidden WGL context (Windows) and
 * performs every projectM/GL call; hosts never touch GL. All exports
 * are thread-safe. render_pixels copies the newest completed frame
 * (the render thread produces frames continuously at the configured
 * fps) and returns -3 while no frame exists yet. Pixel readback is
 * RGBA8; the first row is the TOP row (the bridge flips the GL
 * bottom-up readback before delivering frames).
 * Non-Windows platforms report the core unavailable for now.
 */
#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef _WIN32
  #define AURADSP_PROJECTM_EXPORT __declspec(dllexport)
#else
  #define AURADSP_PROJECTM_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef void* auradsp_projectm_t;

AURADSP_PROJECTM_EXPORT auradsp_projectm_t
    auradsp_projectm_create(int width, int height, float fps);
AURADSP_PROJECTM_EXPORT auradsp_projectm_t
    auradsp_projectm_create_with_activity(int width, int height, float fps,
                                          int active);
/**
 * Returns 0 on success and -3 when teardown failed inside the core;
 * a failed destroy keeps the handle owned by the caller so cleanup
 * can be retried later.
 */
AURADSP_PROJECTM_EXPORT int auradsp_projectm_destroy(auradsp_projectm_t handle);
AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_resize(auradsp_projectm_t handle, int width, int height);
AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_set_active(auradsp_projectm_t handle, int active);
AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_get_width(auradsp_projectm_t handle);
AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_get_height(auradsp_projectm_t handle);

/**
 * Feed interleaved float PCM. channels must be 1 or 2 and frames_per_channel
 * must not exceed 2048. Samples must be finite and within [-1, 1].
 * The chunk is queued for the render thread (bounded queue, oldest
 * dropped under overload). Returns 0 on success, -1 for invalid
 * arguments and -2 for an unavailable core.
 */
AURADSP_PROJECTM_EXPORT int auradsp_projectm_feed_pcm(
    auradsp_projectm_t handle, const float* pcm, int frames_per_channel,
    int channels);

/**
 * Load a UTF-8 MilkDrop preset. Returns -3 if projectM reports a load failure.
 */
AURADSP_PROJECTM_EXPORT int auradsp_projectm_load_preset(
    auradsp_projectm_t handle, const char* preset_path);

/**
 * Queue a UTF-8 preset parse/load on the render thread and return its nonzero
 * request ID immediately. The caller must confirm completion with
 * auradsp_projectm_read_preset_load; request acceptance is not load success.
 */
AURADSP_PROJECTM_EXPORT uint64_t auradsp_projectm_request_preset_load(
    auradsp_projectm_t handle, const char* preset_path);

/**
 * Read request status and the committed preset path without waiting for the
 * render queue. Returns 1 while pending, 0 when this request completed and
 * current_path names its successfully loaded preset, -3 on load failure, -4
 * when superseded, -2 when unavailable, and -1 for invalid arguments/buffer.
 * current_path is optional; when supplied it is always NUL-terminated on
 * success and contains the last successfully committed preset, including on
 * failure. Rendering is frozen while a request is pending and remains frozen
 * after a superseded successful load until a later latest request succeeds.
 */
AURADSP_PROJECTM_EXPORT int auradsp_projectm_read_preset_load(
    auradsp_projectm_t handle, uint64_t request_id, char* current_path,
    size_t current_path_size);

/**
 * Copy the newest completed RGBA8 frame into out_rgba_pixels (at
 * least width * height * 4 bytes). Frames are produced continuously
 * by the bridge's render thread. Returns -3 while no frame has been
 * produced yet (or the size changed since the last frame).
 */
AURADSP_PROJECTM_EXPORT int auradsp_projectm_render_pixels(
    auradsp_projectm_t handle, uint8_t* out_rgba_pixels);

/**
 * Amended (W3): the bridge owns its context; this returns non-zero
 * when the bridge's GL platform layer is available in this build.
 * Per-instance readiness is observable through create() succeeding.
 */
AURADSP_PROJECTM_EXPORT int auradsp_projectm_has_current_gl_context(void);

#ifdef __cplusplus
}
#endif
