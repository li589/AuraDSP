/*
 * probe_vst2_gui.cpp — 编辑器 GUI 门禁探针（插件侧，VST2；源自编辑器 P0 探针）。
 *
 * 按仓库夹具 gain_vst2.cpp 的净室头（Xaymar）口径实现：宿主回调
 * 绊线（version 2400 + vendor "AuraDSP"，用修正签名重解释回调）
 * 之外加编辑器面：
 *   EDITOR_GET_RECT → 280x160；
 *   EDITOR_OPEN(ptr) → ptr 按 Linux 惯例携带父窗口的 X11 Window：
 *     插件以自己的 X 连接在其下建子窗口（WM_NAME =
 *     "ProbeVST2EditorChild"，橙色），映射并 flush；
 *   EDITOR_CLOSE → 销毁子窗口、关连接；
 *   EDITOR_KEEP_ALIVE → 泵自家连接事件。
 */
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "x11_min.h"

#include "vst2/vst.h"

namespace {

Display* g_dpy = nullptr;
Window g_win = 0;
vst_rect_t g_rect = {0, 0, 160, 280};  // top, left, bottom, right
bool g_callbackOk = false;

intptr_t VST_FUNCTION_INTERFACE control(vst_effect_t* effect, int32_t opcode,
                                        int32_t index, intptr_t value, void* ptr,
                                        float opt) {
    (void)effect;
    (void)index;
    (void)value;
    (void)opt;
    switch (opcode) {
        case VST_EFFECT_OPCODE_EDITOR_GET_RECT:
            if (ptr) {
                *static_cast<vst_rect_t**>(ptr) = &g_rect;
                return VST_STATUS_TRUE;
            }
            return VST_STATUS_FALSE;
        case VST_EFFECT_OPCODE_EDITOR_OPEN: {
            Window parent = static_cast<Window>(reinterpret_cast<uintptr_t>(ptr));
            g_dpy = XOpenDisplay(nullptr);
            if (!g_dpy) return VST_STATUS_FALSE;
            g_win = XCreateSimpleWindow(g_dpy, parent, 0, 0, 280, 160, 0,
                                        0xff8800, 0xff8800);
            XStoreName(g_dpy, g_win, "ProbeVST2EditorChild");
            XSelectInput(g_dpy, g_win, ExposureMask | StructureNotifyMask);
            XMapWindow(g_dpy, g_win);
            XFlush(g_dpy);
            std::fprintf(stderr,
                         "[probe-vst2-gui] editorOpen: child=%lu in parent=%lu\n",
                         static_cast<unsigned long>(g_win),
                         static_cast<unsigned long>(parent));
            return VST_STATUS_TRUE;
        }
        case VST_EFFECT_OPCODE_EDITOR_CLOSE:
            if (g_dpy) {
                if (g_win) XDestroyWindow(g_dpy, g_win);
                XCloseDisplay(g_dpy);
                g_dpy = nullptr;
                g_win = 0;
            }
            return VST_STATUS_TRUE;
        case VST_EFFECT_OPCODE_EDITOR_KEEP_ALIVE:
            if (g_dpy) {
                while (XPending(g_dpy) > 0) {
                    XEvent ev;
                    XNextEvent(g_dpy, &ev);
                }
            }
            return VST_STATUS_TRUE;
        default:
            return VST_STATUS_FALSE;
    }
}

void VST_FUNCTION_INTERFACE processFloat(vst_effect_t* effect,
                                         const float* const* inputs,
                                         float** outputs, int sampleFrames) {
    (void)effect;
    if (!inputs || !outputs || sampleFrames < 0) return;
    for (int ch = 0; ch < 2; ++ch) {
        if (!outputs[ch]) continue;
        if (inputs[ch]) {
            for (int i = 0; i < sampleFrames; ++i)
                outputs[ch][i] = inputs[ch][i] * 0.5f;
        } else {
            std::memset(outputs[ch], 0,
                        sizeof(float) * static_cast<size_t>(sampleFrames));
        }
    }
}

void VST_FUNCTION_INTERFACE setParameter(vst_effect_t*, uint32_t, float) {}
float VST_FUNCTION_INTERFACE getParameter(vst_effect_t*, uint32_t) { return 0.5f; }

vst_effect_t g_effect = {};

}  // namespace

#if defined(_WIN32)
#define VST2_GUI_EXPORT __declspec(dllexport)
#else
#define VST2_GUI_EXPORT __attribute__((visibility("default")))
#endif

extern "C" VST2_GUI_EXPORT vst_effect_t* VST_FUNCTION_INTERFACE
VSTPluginMain(vst_host_callback_t callback) {
    using FixedCallback = intptr_t(VST_FUNCTION_INTERFACE*)(vst_effect_t*, int32_t,
                                                            int32_t, intptr_t, void*,
                                                            float);
    auto cb = reinterpret_cast<FixedCallback>(callback);
    g_callbackOk = false;
    if (cb) {
        const intptr_t version =
            cb(nullptr, VST_HOST_OPCODE_VST_VERSION, 0, 0, nullptr, 0.0f);
        char vendor[64] = {};
        const intptr_t got =
            cb(nullptr, VST_HOST_OPCODE_VENDOR_NAME, 0, 64, vendor, 0.0f);
        g_callbackOk = (version == 2400) && (got == VST_STATUS_TRUE) &&
                       (std::strcmp(vendor, "AuraDSP") == 0);
    }
    if (!g_callbackOk) return nullptr;

    std::memset(&g_effect, 0, sizeof(g_effect));
    g_effect.magic_number = static_cast<int32_t>(VST_MAGICNUMBER);
    g_effect.control = &control;
    g_effect.set_parameter = &setParameter;
    g_effect.get_parameter = &getParameter;
    g_effect.num_programs = 1;
    g_effect.num_params = 1;
    g_effect.num_inputs = 2;
    g_effect.num_outputs = 2;
    g_effect.flags = VST_EFFECT_FLAG_SUPPORTS_FLOAT | VST_EFFECT_FLAG_EDITOR;
    g_effect.unique_id = static_cast<int32_t>(VST_FOURCC('A', 'u', 'r', 'a'));
    g_effect.version = 1000;
    g_effect.process_float = &processFloat;
    return &g_effect;
}
