/*
 * projectm_bridge_api.h - libprojectM v4 C-ABI bridge.
 *
 * The bridge owns an OpenGL-backed projectM instance. The caller must make a
 * verified, identical OpenGL context current for every operation and keep all
 * calls on the creating thread. The portable ABI can only check that some
 * context is current; the host owns context identity verification. Pixel
 * readback is RGBA8 and starts at the lower-left row, matching glReadPixels.
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
/**
 * Destroy or resize only while the verified creating-thread context is current.
 * Returns 0 on success, -1 for invalid arguments, -2 for an unavailable core,
 * and -4 for a wrong thread or missing current context. A failed destroy keeps
 * the handle owned by the caller so cleanup can be retried later.
 */
AURADSP_PROJECTM_EXPORT int auradsp_projectm_destroy(auradsp_projectm_t handle);
AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_resize(auradsp_projectm_t handle, int width, int height);
AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_get_width(auradsp_projectm_t handle);
AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_get_height(auradsp_projectm_t handle);

/**
 * Feed interleaved float PCM. channels must be 1 or 2 and frames_per_channel
 * must not exceed 2048. Samples must be finite and within [-1, 1].
 * Returns 0 on success, -1 for invalid arguments, -2 for an unavailable core,
 * and -4 when no current OpenGL context is bound.
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
 * Render one frame to the current OpenGL default framebuffer and copy RGBA8
 * pixels into out_rgba_pixels (at least width * height * 4 bytes).
 */
AURADSP_PROJECTM_EXPORT int auradsp_projectm_render_pixels(
    auradsp_projectm_t handle, uint8_t* out_rgba_pixels);

/**
 * Returns non-zero when the caller currently has a usable OpenGL context.
 * The bridge never creates or changes a context on behalf of the caller.
 */
AURADSP_PROJECTM_EXPORT int auradsp_projectm_has_current_gl_context(void);

#ifdef __cplusplus
}
#endif
