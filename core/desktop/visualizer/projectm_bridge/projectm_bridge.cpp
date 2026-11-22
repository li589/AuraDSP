/*
 * projectm_bridge.cpp - libprojectM v4 C-ABI bridge.
 *
 * Ownership model (amended 2026-11-23, wiring round W3): the bridge
 * OWNS its OpenGL context. The original contract required the caller
 * to present an identical GL context on the creating thread, which a
 * Dart/Flutter host can never do (Flutter owns its context privately),
 * so no host could ever create an instance. The bridge now runs a
 * dedicated render thread holding a hidden WGL context (Windows);
 * every projectM/GL call happens on that thread. All exports are
 * thread-safe and may be called from any host thread:
 *
 *   create/destroy/load_preset/resize - posted to the render thread
 *       and completed synchronously (control operations).
 *   feed_pcm - validated on the caller thread, then queued (bounded,
 *       oldest dropped) for the render thread to add before a frame.
 *   render_pixels - copies the newest completed frame out of a
 *       double buffer; never blocks on GL. Returns -3 while no frame
 *       has been produced yet.
 *
 * Non-Windows platforms currently report the core unavailable
 * (-2 / nullptr); the GL platform layer is Windows/WGL only for now.
 */
#include "projectm_bridge_api.h"

#include <projectM-4/audio.h>
#include <projectM-4/callbacks.h>
#include <projectM-4/core.h>
#include <projectM-4/parameters.h>
#include <projectM-4/render_opengl.h>

#if defined(_WIN32)
#include <windows.h>
#include <GL/gl.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <future>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr int kMaxPcmFrames = 2048;
constexpr size_t kMaxQueuedPcmChunks = 8;

#if defined(_WIN32)

// ---------------------------------------------------------------------------
// Hidden-window WGL context, owned by the render thread.
// ---------------------------------------------------------------------------
struct WglContext {
    HWND hwnd = nullptr;
    HDC hdc = nullptr;
    HGLRC rc = nullptr;

    bool init(int width, int height) {
        static std::once_flag class_once;
        std::call_once(class_once, [] {
            WNDCLASSW wc{};
            wc.style = CS_OWNDC;
            wc.lpfnWndProc = DefWindowProcW;
            wc.hInstance = GetModuleHandleW(nullptr);
            wc.lpszClassName = L"AuraDSPProjectMBridge";
            RegisterClassW(&wc);
        });
        hwnd = CreateWindowExW(0, L"AuraDSPProjectMBridge", L"",
                               WS_POPUP, 0, 0, width, height, nullptr,
                               nullptr, GetModuleHandleW(nullptr), nullptr);
        if (hwnd == nullptr) return false;
        hdc = GetDC(hwnd);
        if (hdc == nullptr) return false;

        PIXELFORMATDESCRIPTOR pfd{};
        pfd.nSize = sizeof(pfd);
        pfd.nVersion = 1;
        pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL |
                      PFD_DOUBLEBUFFER;
        pfd.iPixelType = PFD_TYPE_RGBA;
        pfd.cColorBits = 32;
        pfd.cDepthBits = 24;
        const int fmt = ChoosePixelFormat(hdc, &pfd);
        if (fmt == 0 || !SetPixelFormat(hdc, fmt, &pfd)) return false;

        // Bootstrap context, then try a 3.3 core context (libprojectM
        // 4.x targets GL 3.3); fall back to the bootstrap context.
        HGLRC bootstrap = wglCreateContext(hdc);
        if (bootstrap == nullptr) return false;
        if (!wglMakeCurrent(hdc, bootstrap)) {
            wglDeleteContext(bootstrap);
            return false;
        }
        using CreateAttribsFn = HGLRC(WINAPI*)(HDC, HGLRC, const int*);
        auto create_attribs = reinterpret_cast<CreateAttribsFn>(
            wglGetProcAddress("wglCreateContextAttribsARB"));
        rc = bootstrap;
        if (create_attribs != nullptr) {
            const int attribs[] = {0x2091, 3,   // WGL_CONTEXT_MAJOR_VERSION_ARB
                                   0x2092, 3,   // WGL_CONTEXT_MINOR_VERSION_ARB
                                   0x9126, 0x1, // WGL_CONTEXT_PROFILE_MASK_ARB = core
                                   0};
            HGLRC core = create_attribs(hdc, nullptr, attribs);
            if (core != nullptr) {
                wglMakeCurrent(nullptr, nullptr);
                wglDeleteContext(bootstrap);
                rc = core;
            }
        }
        return wglMakeCurrent(hdc, rc) != FALSE;
    }

    void resize_window(int width, int height) {
        if (hwnd != nullptr) {
            SetWindowPos(hwnd, nullptr, 0, 0, width, height,
                         SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }

    void destroy() {
        if (rc != nullptr) {
            wglMakeCurrent(nullptr, nullptr);
            wglDeleteContext(rc);
            rc = nullptr;
        }
        if (hwnd != nullptr) {
            if (hdc != nullptr) ReleaseDC(hwnd, hdc);
            DestroyWindow(hwnd);
            hwnd = nullptr;
            hdc = nullptr;
        }
    }
};

#endif  // _WIN32

// ---------------------------------------------------------------------------
// FBO entry points: <GL/gl.h> on Windows is GL 1.1 only, so the
// framebuffer-object functions are loaded once from the driver.
// projectm_opengl_render_frame() targets the default framebuffer,
// whose back buffer is not reliably readable for a hidden window
// (glReadPixels -> GL_INVALID_OPERATION); render_frame_fbo() into
// our own FBO is the reliable readback path.
// ---------------------------------------------------------------------------
// FBO constants (absent from the GL 1.1 Windows header; values are
// fixed by the OpenGL specification).
#ifndef GL_FRAMEBUFFER
#define GL_FRAMEBUFFER 0x8D40
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_DEPTH_ATTACHMENT 0x8D00
#define GL_RENDERBUFFER 0x8D41
#define GL_DEPTH_COMPONENT24 0x81A6
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_RGBA8 0x8058
#endif

using GlGenFramebuffersFn = void (*)(GLsizei, GLuint*);
using GlBindFramebufferFn = void (*)(GLenum, GLuint);
using GlFramebufferTexture2DFn = void (*)(GLenum, GLenum, GLenum, GLuint, GLint);
using GlDeleteFramebuffersFn = void (*)(GLsizei, const GLuint*);
using GlGenRenderbuffersFn = void (*)(GLsizei, GLuint*);
using GlBindRenderbufferFn = void (*)(GLenum, GLuint);
using GlRenderbufferStorageFn = void (*)(GLenum, GLenum, GLsizei, GLsizei);
using GlFramebufferRenderbufferFn = void (*)(GLenum, GLenum, GLenum, GLuint);
using GlDeleteRenderbuffersFn = void (*)(GLsizei, const GLuint*);
using GlCheckFramebufferStatusFn = GLenum (*)(GLenum);

struct FboGl {
    GlGenFramebuffersFn gen_fbo = nullptr;
    GlBindFramebufferFn bind_fbo = nullptr;
    GlFramebufferTexture2DFn fbo_texture = nullptr;
    GlDeleteFramebuffersFn del_fbo = nullptr;
    GlGenRenderbuffersFn gen_rb = nullptr;
    GlBindRenderbufferFn bind_rb = nullptr;
    GlRenderbufferStorageFn rb_storage = nullptr;
    GlFramebufferRenderbufferFn fbo_rb = nullptr;
    GlDeleteRenderbuffersFn del_rb = nullptr;
    GlCheckFramebufferStatusFn check_fbo = nullptr;
    bool ready = false;

    bool load() {
        if (ready) return true;
        gen_fbo = reinterpret_cast<GlGenFramebuffersFn>(wglGetProcAddress("glGenFramebuffers"));
        bind_fbo = reinterpret_cast<GlBindFramebufferFn>(wglGetProcAddress("glBindFramebuffer"));
        fbo_texture = reinterpret_cast<GlFramebufferTexture2DFn>(wglGetProcAddress("glFramebufferTexture2D"));
        del_fbo = reinterpret_cast<GlDeleteFramebuffersFn>(wglGetProcAddress("glDeleteFramebuffers"));
        gen_rb = reinterpret_cast<GlGenRenderbuffersFn>(wglGetProcAddress("glGenRenderbuffers"));
        bind_rb = reinterpret_cast<GlBindRenderbufferFn>(wglGetProcAddress("glBindRenderbuffer"));
        rb_storage = reinterpret_cast<GlRenderbufferStorageFn>(wglGetProcAddress("glRenderbufferStorage"));
        fbo_rb = reinterpret_cast<GlFramebufferRenderbufferFn>(wglGetProcAddress("glFramebufferRenderbuffer"));
        del_rb = reinterpret_cast<GlDeleteRenderbuffersFn>(wglGetProcAddress("glDeleteRenderbuffers"));
        check_fbo = reinterpret_cast<GlCheckFramebufferStatusFn>(wglGetProcAddress("glCheckFramebufferStatus"));
        ready = gen_fbo && bind_fbo && fbo_texture && del_fbo && gen_rb &&
                bind_rb && rb_storage && fbo_rb && del_rb && check_fbo;
        return ready;
    }
};

inline FboGl& fbo_gl() {
    static FboGl g;
    return g;
}

// Per-instance render target (render thread owned).
struct RenderTarget {
    GLuint fbo = 0;
    GLuint color_tex = 0;
    GLuint depth_rb = 0;
    int width = 0;
    int height = 0;

    bool ensure(int w, int h) {
        if (fbo != 0 && width == w && height == h) return true;
        FboGl& gl = fbo_gl();
        if (!gl.load()) return false;
        destroy();
        glGenTextures(1, &color_tex);
        glBindTexture(GL_TEXTURE_2D, color_tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, nullptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        gl.gen_rb(1, &depth_rb);
        gl.bind_rb(GL_RENDERBUFFER, depth_rb);
        gl.rb_storage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, w, h);
        gl.gen_fbo(1, &fbo);
        gl.bind_fbo(GL_FRAMEBUFFER, fbo);
        gl.fbo_texture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                       color_tex, 0);
        gl.fbo_rb(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER,
                  depth_rb);
        const bool complete =
            gl.check_fbo(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
        gl.bind_fbo(GL_FRAMEBUFFER, 0);
        if (!complete) {
            destroy();
            return false;
        }
        width = w;
        height = h;
        return true;
    }

    void destroy() {
        FboGl& gl = fbo_gl();
        if (fbo != 0 && gl.del_fbo) gl.del_fbo(1, &fbo);
        if (depth_rb != 0 && gl.del_rb) gl.del_rb(1, &depth_rb);
        if (color_tex != 0) glDeleteTextures(1, &color_tex);
        fbo = 0;
        depth_rb = 0;
        color_tex = 0;
        width = 0;
        height = 0;
    }
};

struct PcmChunk {
    std::vector<float> samples;  // interleaved
    int frames_per_channel = 0;
    int channels = 2;
};

struct FrameStore {
    std::mutex mtx;
    std::vector<uint8_t> front;  // newest complete frame (RGBA8)
    bool has_frame = false;
};

}  // namespace

struct auradsp_projectm_context {
    projectm_handle pm = nullptr;
    int width = 0;
    int height = 0;
    float fps = 60.0f;
    std::atomic<bool> preset_load_failed{false};

    // Caller-thread side state.
    std::mutex pcm_mtx;
    std::deque<PcmChunk> pcm_queue;
    FrameStore frames;

#if defined(_WIN32)
    WglContext gl;  // render-thread owned
    RenderTarget target;
#endif
    std::chrono::steady_clock::time_point next_frame_due{};
    std::atomic<bool> gl_ready{false};
};

namespace {

void on_preset_load_failed(const char*, const char*, void* user_data) {
    auto* ctx = static_cast<auradsp_projectm_context*>(user_data);
    if (ctx != nullptr) {
        ctx->preset_load_failed.store(true, std::memory_order_release);
    }
}

// ---------------------------------------------------------------------------
// Render thread: one per process, started lazily by the first create.
// Owns every GL context and every projectM instance.
// ---------------------------------------------------------------------------
class RenderThread {
public:
    static RenderThread& instance() {
        static RenderThread rt;
        return rt;
    }

    // Run fn on the render thread and wait for its result.
    template <typename T>
    T run_sync(std::function<T()> fn) {
        ensure_started();
        auto task = std::make_shared<std::packaged_task<T()>>(std::move(fn));
        auto fut = task->get_future();
        {
            std::lock_guard<std::mutex> lock(mtx_);
            queue_.push_back([task] { (*task)(); });
        }
        cv_.notify_one();
        return fut.get();
    }

    void post(std::function<void()> fn) {
        ensure_started();
        {
            std::lock_guard<std::mutex> lock(mtx_);
            queue_.push_back(std::move(fn));
        }
        cv_.notify_one();
    }

    void register_ctx(auradsp_projectm_context* ctx) {
        std::lock_guard<std::mutex> lock(mtx_);
        contexts_.push_back(ctx);
    }

    void unregister_ctx(auradsp_projectm_context* ctx) {
        std::lock_guard<std::mutex> lock(mtx_);
        contexts_.erase(std::remove(contexts_.begin(), contexts_.end(), ctx),
                        contexts_.end());
    }

private:
    RenderThread() = default;

    void ensure_started() {
        std::call_once(start_once_, [this] {
            thread_ = std::thread([this] { loop(); });
            thread_.detach();
        });
    }

    void loop() {
        for (;;) {
            std::deque<std::function<void()>> tasks;
            std::vector<auradsp_projectm_context*> ctxs;
            {
                std::unique_lock<std::mutex> lock(mtx_);
                cv_.wait_for(lock, std::chrono::milliseconds(2),
                             [this] { return !queue_.empty(); });
                tasks.swap(queue_);
                ctxs = contexts_;
            }
            for (auto& t : tasks) t();
            const auto now = std::chrono::steady_clock::now();
            for (auto* ctx : ctxs) {
                if (ctx->gl_ready.load(std::memory_order_acquire) &&
                    now >= ctx->next_frame_due) {
                    render_one(ctx);
                    const double fps = ctx->fps > 0.0f ? ctx->fps : 60.0f;
                    ctx->next_frame_due =
                        now + std::chrono::duration_cast<
                                  std::chrono::steady_clock::duration>(
                                  std::chrono::duration<double>(1.0 / fps));
                }
            }
        }
    }

    // Render-thread only.
    void render_one(auradsp_projectm_context* ctx) {
#if defined(_WIN32)
        try {
            // Drain queued PCM first so the frame reacts to fresh audio.
            for (;;) {
                PcmChunk chunk;
                {
                    std::lock_guard<std::mutex> lock(ctx->pcm_mtx);
                    if (ctx->pcm_queue.empty()) break;
                    chunk = std::move(ctx->pcm_queue.front());
                    ctx->pcm_queue.pop_front();
                }
                const projectm_channels ch =
                    chunk.channels == 1 ? PROJECTM_MONO : PROJECTM_STEREO;
                projectm_pcm_add_float(
                    ctx->pm, chunk.samples.data(),
                    static_cast<unsigned int>(chunk.frames_per_channel), ch);
            }
            while (glGetError() != GL_NO_ERROR) {
            }
            if (!ctx->target.ensure(ctx->width, ctx->height)) return;
            projectm_opengl_render_frame_fbo(
                ctx->pm, static_cast<uint32_t>(ctx->target.fbo));
            std::vector<uint8_t> pixels(
                static_cast<size_t>(ctx->width) * ctx->height * 4);
            GLint old_alignment = 4;
            glGetIntegerv(GL_PACK_ALIGNMENT, &old_alignment);
            glPixelStorei(GL_PACK_ALIGNMENT, 1);
            fbo_gl().bind_fbo(GL_FRAMEBUFFER, ctx->target.fbo);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            glReadPixels(0, 0, ctx->width, ctx->height, GL_RGBA,
                         GL_UNSIGNED_BYTE, pixels.data());
            glPixelStorei(GL_PACK_ALIGNMENT, old_alignment);
            fbo_gl().bind_fbo(GL_FRAMEBUFFER, 0);
            if (glGetError() == GL_NO_ERROR) {
                std::lock_guard<std::mutex> lock(ctx->frames.mtx);
                ctx->frames.front = std::move(pixels);
                ctx->frames.has_frame = true;
            }
        } catch (...) {
            // A render failure must not kill the render thread; the
            // instance simply stops producing frames and the host
            // falls back via its availability checks.
        }
#endif
    }

    std::once_flag start_once_;
    std::thread thread_;
    std::mutex mtx_;
    std::condition_variable cv_;
    std::deque<std::function<void()>> queue_;
    std::vector<auradsp_projectm_context*> contexts_;
};

}  // namespace

AURADSP_PROJECTM_EXPORT auradsp_projectm_t
    auradsp_projectm_create(int width, int height, float fps) {
    if (width <= 0) width = 1280;
    if (height <= 0) height = 720;
    if (fps <= 0.0f) fps = 60.0f;
#if !defined(_WIN32)
    (void)width; (void)height; (void)fps;
    return nullptr;  // GL platform layer is Windows/WGL only for now.
#else
    auto* ctx = new (std::nothrow) auradsp_projectm_context();
    if (ctx == nullptr) return nullptr;
    ctx->width = width;
    ctx->height = height;
    ctx->fps = fps;
    RenderThread::instance().register_ctx(ctx);
    const bool ok = RenderThread::instance().run_sync<bool>([ctx] {
        try {
            if (!ctx->gl.init(ctx->width, ctx->height)) return false;
            ctx->pm = projectm_create();
            if (ctx->pm == nullptr) return false;
            projectm_set_window_size(ctx->pm,
                                     static_cast<size_t>(ctx->width),
                                     static_cast<size_t>(ctx->height));
            projectm_set_fps(ctx->pm,
                             static_cast<int32_t>(std::lround(ctx->fps)));
            projectm_set_preset_switch_failed_event_callback(
                ctx->pm, on_preset_load_failed, ctx);
            ctx->gl_ready.store(true, std::memory_order_release);
            ctx->next_frame_due = std::chrono::steady_clock::now();
            return true;
        } catch (...) {
            return false;
        }
    });
    if (!ok) {
        RenderThread::instance().run_sync<bool>([ctx] {
            if (ctx->pm != nullptr) {
                try {
                    projectm_destroy(ctx->pm);
                } catch (...) {
                }
                ctx->pm = nullptr;
            }
            ctx->gl.destroy();
            return true;
        });
        RenderThread::instance().unregister_ctx(ctx);
        delete ctx;
        return nullptr;
    }
    return static_cast<auradsp_projectm_t>(ctx);
#endif
}

AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_destroy(auradsp_projectm_t handle) {
    if (handle == nullptr) return 0;
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
#if !defined(_WIN32)
    delete ctx;
    return 0;
#else
    RenderThread::instance().unregister_ctx(ctx);
    const bool ok = RenderThread::instance().run_sync<bool>([ctx] {
        try {
            if (ctx->pm != nullptr) {
                projectm_set_preset_switch_failed_event_callback(
                    ctx->pm, nullptr, nullptr);
                projectm_destroy(ctx->pm);
                ctx->pm = nullptr;
            }
        } catch (...) {
            return false;  // keep the handle so cleanup can be retried
        }
        ctx->target.destroy();
        ctx->gl_ready.store(false, std::memory_order_release);
        ctx->gl.destroy();
        return true;
    });
    if (!ok) {
        RenderThread::instance().register_ctx(ctx);
        return -3;
    }
    delete ctx;
    return 0;
#endif
}

AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_resize(auradsp_projectm_t handle, int width,
                            int height) {
    if (handle == nullptr || width <= 0 || height <= 0) return -1;
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
#if !defined(_WIN32)
    (void)ctx;
    return -2;
#else
    if (!ctx->gl_ready.load(std::memory_order_acquire)) return -2;
    ctx->width = width;
    ctx->height = height;
    {
        std::lock_guard<std::mutex> lock(ctx->frames.mtx);
        ctx->frames.has_frame = false;  // size changed; drop stale frame
        ctx->frames.front.clear();
    }
    RenderThread::instance().post([ctx, width, height] {
        try {
            ctx->gl.resize_window(width, height);
            projectm_set_window_size(ctx->pm, static_cast<size_t>(width),
                                     static_cast<size_t>(height));
        } catch (...) {
        }
    });
    return 0;
#endif
}

AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_get_width(auradsp_projectm_t handle) {
    if (handle == nullptr) return 0;
    return static_cast<auradsp_projectm_context*>(handle)->width;
}

AURADSP_PROJECTM_EXPORT int
    auradsp_projectm_get_height(auradsp_projectm_t handle) {
    if (handle == nullptr) return 0;
    return static_cast<auradsp_projectm_context*>(handle)->height;
}

AURADSP_PROJECTM_EXPORT int auradsp_projectm_feed_pcm(
    auradsp_projectm_t handle, const float* pcm, int frames_per_channel,
    int channels) {
    if (handle == nullptr || pcm == nullptr || frames_per_channel <= 0 ||
        frames_per_channel > kMaxPcmFrames ||
        (channels != 1 && channels != 2)) {
        return -1;
    }
    const size_t sample_count =
        static_cast<size_t>(frames_per_channel) * static_cast<size_t>(channels);
    for (size_t i = 0; i < sample_count; ++i) {
        if (!std::isfinite(pcm[i]) || pcm[i] < -1.0f || pcm[i] > 1.0f) {
            return -1;
        }
    }
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
    if (!ctx->gl_ready.load(std::memory_order_acquire)) return -2;
    PcmChunk chunk;
    chunk.samples.assign(pcm, pcm + sample_count);
    chunk.frames_per_channel = frames_per_channel;
    chunk.channels = channels;
    {
        std::lock_guard<std::mutex> lock(ctx->pcm_mtx);
        if (ctx->pcm_queue.size() >= kMaxQueuedPcmChunks) {
            ctx->pcm_queue.pop_front();  // drop oldest under overload
        }
        ctx->pcm_queue.push_back(std::move(chunk));
    }
    return 0;
}

AURADSP_PROJECTM_EXPORT int auradsp_projectm_load_preset(
    auradsp_projectm_t handle, const char* preset_path) {
    if (handle == nullptr || preset_path == nullptr ||
        preset_path[0] == '\0') {
        return -1;
    }
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
#if !defined(_WIN32)
    (void)ctx;
    return -2;
#else
    if (!ctx->gl_ready.load(std::memory_order_acquire)) return -2;
    const std::string path(preset_path);
    return RenderThread::instance().run_sync<int>([ctx, path] {
        try {
            ctx->preset_load_failed.store(false, std::memory_order_release);
            projectm_load_preset_file(ctx->pm, path.c_str(), true);
            return ctx->preset_load_failed.load(std::memory_order_acquire)
                       ? -3
                       : 0;
        } catch (...) {
            return -3;
        }
    });
#endif
}

AURADSP_PROJECTM_EXPORT int auradsp_projectm_has_current_gl_context(void) {
    // Amended semantics (W3): the bridge owns the context now; this
    // reports that the WGL platform layer is compiled in. Per-instance
    // readiness is observable through create() succeeding.
#if !defined(_WIN32)
    return 0;
#else
    return 1;
#endif
}

AURADSP_PROJECTM_EXPORT int auradsp_projectm_render_pixels(
    auradsp_projectm_t handle, uint8_t* out_rgba_pixels) {
    if (handle == nullptr || out_rgba_pixels == nullptr) return -1;
    auto* ctx = static_cast<auradsp_projectm_context*>(handle);
    if (!ctx->gl_ready.load(std::memory_order_acquire)) return -2;
    std::lock_guard<std::mutex> lock(ctx->frames.mtx);
    if (!ctx->frames.has_frame) return -3;  // no frame produced yet
    const size_t need =
        static_cast<size_t>(ctx->width) * ctx->height * 4;
    if (ctx->frames.front.size() != need) return -3;
    std::memcpy(out_rgba_pixels, ctx->frames.front.data(), need);
    return 0;
}
