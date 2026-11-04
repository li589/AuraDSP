/*
 * probe_clap_gui.c — 编辑器 GUI 门禁探针（插件侧，CLAP；源自编辑器 P0 探针）。
 *
 * 在门禁增益探针 probe_gain.c 基础上实现 clap.gui 扩展（X11）：
 * create(x11) 只置位，set_parent 时用插件自己的 X 连接在宿主给的
 * 父窗口下创建 300x180 子窗口（WM_NAME = "ProbeCLAPEditorChild"，
 * 青色填充），show/hide 控制映射，destroy 销毁。宿主侧由
 * host_clap_gui.c 以 XQueryTree 跨连接核验。
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "x11_min.h"

#include <clap/clap.h>

static const char kId[] = "com.auradsp.probe.gain.gui";

static Display *g_dpy = NULL;
static Window g_win = 0;
static bool g_created = false;

static float clamp_gain(float g) { return g < 0.0f ? 0.0f : (g > 1.0f ? 1.0f : g); }

// ------------------------------------------------------------------ gui
static bool gui_is_api_supported(const clap_plugin_t *plugin, const char *api,
                                 bool is_floating) {
    (void)plugin;
    return !is_floating && api && strcmp(api, CLAP_WINDOW_API_X11) == 0;
}

static bool gui_create(const clap_plugin_t *plugin, const char *api, bool is_floating) {
    (void)plugin;
    if (!gui_is_api_supported(plugin, api, is_floating)) return false;
    g_created = true;
    return true;
}

static void gui_destroy(const clap_plugin_t *plugin) {
    (void)plugin;
    if (g_dpy) {
        if (g_win) XDestroyWindow(g_dpy, g_win);
        XCloseDisplay(g_dpy);
        g_dpy = NULL;
        g_win = 0;
    }
    g_created = false;
}

static bool gui_set_scale(const clap_plugin_t *plugin, double scale) {
    (void)plugin;
    (void)scale;
    return false;
}

static bool gui_get_size(const clap_plugin_t *plugin, uint32_t *w, uint32_t *h) {
    (void)plugin;
    if (!g_created) return false;
    *w = 300;
    *h = 180;
    return true;
}

static bool gui_can_resize(const clap_plugin_t *plugin) {
    (void)plugin;
    return false;
}

static bool gui_get_resize_hints(const clap_plugin_t *plugin,
                                 clap_gui_resize_hints_t *hints) {
    (void)plugin;
    (void)hints;
    return false;
}

static bool gui_adjust_size(const clap_plugin_t *plugin, uint32_t *w, uint32_t *h) {
    (void)plugin;
    (void)w;
    (void)h;
    return false;
}

static bool gui_set_size(const clap_plugin_t *plugin, uint32_t w, uint32_t h) {
    (void)plugin;
    if (g_dpy && g_win) {
        XResizeWindow(g_dpy, g_win, w, h);
        XFlush(g_dpy);
        return true;
    }
    return false;
}

static bool gui_set_parent(const clap_plugin_t *plugin, const clap_window_t *window) {
    (void)plugin;
    if (!g_created || !window || strcmp(window->api, CLAP_WINDOW_API_X11) != 0)
        return false;
    g_dpy = XOpenDisplay(NULL);
    if (!g_dpy) return false;
    Window parent = (Window)window->x11;
    g_win = XCreateSimpleWindow(g_dpy, parent, 0, 0, 300, 180, 0, 0x00cccc, 0x00cccc);
    XStoreName(g_dpy, g_win, "ProbeCLAPEditorChild");
    XSelectInput(g_dpy, g_win, ExposureMask | StructureNotifyMask);
    XFlush(g_dpy);
    fprintf(stderr, "[probe-clap-gui] set_parent: child=%lu in parent=%lu\n",
            (unsigned long)g_win, (unsigned long)parent);
    return true;
}

static bool gui_set_transient(const clap_plugin_t *plugin,
                              const clap_window_t *window) {
    (void)plugin;
    (void)window;
    return false;
}

static void gui_suggest_title(const clap_plugin_t *plugin, const char *title) {
    (void)plugin;
    (void)title;
}

static bool gui_show(const clap_plugin_t *plugin) {
    (void)plugin;
    if (!g_dpy || !g_win) return false;
    XMapWindow(g_dpy, g_win);
    XFlush(g_dpy);
    return true;
}

static bool gui_hide(const clap_plugin_t *plugin) {
    (void)plugin;
    if (!g_dpy || !g_win) return false;
    XUnmapWindow(g_dpy, g_win);
    XFlush(g_dpy);
    return true;
}

static const clap_plugin_gui_t kGui = {
    .is_api_supported = gui_is_api_supported,
    .create = gui_create,
    .destroy = gui_destroy,
    .set_scale = gui_set_scale,
    .get_size = gui_get_size,
    .can_resize = gui_can_resize,
    .get_resize_hints = gui_get_resize_hints,
    .adjust_size = gui_adjust_size,
    .set_size = gui_set_size,
    .set_parent = gui_set_parent,
    .set_transient = gui_set_transient,
    .suggest_title = gui_suggest_title,
    .show = gui_show,
    .hide = gui_hide,
};

// ------------------------------------------------------------------ plugin
typedef struct {
    clap_plugin_t plugin;
    float gain;
} probe_t;

static bool plug_init(const clap_plugin_t *plugin) {
    (void)plugin;
    return true;
}
static void plug_destroy(const clap_plugin_t *plugin) {
    (void)plugin;
}
static bool plug_activate(const clap_plugin_t *plugin, double sr, uint32_t minf,
                          uint32_t maxf) {
    (void)plugin;
    (void)sr;
    (void)minf;
    (void)maxf;
    return true;
}
static void plug_deactivate(const clap_plugin_t *plugin) { (void)plugin; }
static bool plug_start_processing(const clap_plugin_t *plugin) {
    (void)plugin;
    return true;
}
static void plug_stop_processing(const clap_plugin_t *plugin) { (void)plugin; }
static void plug_reset(const clap_plugin_t *plugin) { (void)plugin; }

static clap_process_status plug_process(const clap_plugin_t *plugin,
                                        const clap_process_t *process) {
    probe_t *p = (probe_t *)plugin->plugin_data;
    if (process->audio_inputs_count < 1 || process->audio_outputs_count < 1)
        return CLAP_PROCESS_CONTINUE;
    const clap_audio_buffer_t *in = &process->audio_inputs[0];
    clap_audio_buffer_t *out = &process->audio_outputs[0];
    uint32_t n = process->frames_count;
    for (uint32_t c = 0; c < out->channel_count; ++c) {
        float *dst = out->data32[c];
        const float *src =
            (c < in->channel_count && in->data32[c]) ? in->data32[c] : NULL;
        if (!dst) continue;
        if (src) {
            for (uint32_t i = 0; i < n; ++i) dst[i] = src[i] * p->gain;
        } else {
            memset(dst, 0, sizeof(float) * n);
        }
    }
    out->constant_mask = 0;
    return CLAP_PROCESS_CONTINUE;
}

static const void *plug_get_extension(const clap_plugin_t *plugin, const char *id) {
    (void)plugin;
    if (id && strcmp(id, CLAP_EXT_GUI) == 0) return &kGui;
    return NULL;
}

static void plug_on_main_thread(const clap_plugin_t *plugin) { (void)plugin; }

static const clap_plugin_descriptor_t kDesc = {
    .clap_version = CLAP_VERSION_INIT,
    .id = kId,
    .name = "Probe CLAP Gain GUI",
    .vendor = "AuraDSP Probe",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "1.0.0",
    .description = "Minimal CLAP gain probe with X11 GUI (P0).",
    .features = (const char *[]){CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
                                 CLAP_PLUGIN_FEATURE_STEREO, NULL},
};

static const clap_plugin_t kPluginTemplate = {
    .desc = &kDesc,
    .plugin_data = NULL,
    .init = plug_init,
    .destroy = plug_destroy,
    .activate = plug_activate,
    .deactivate = plug_deactivate,
    .start_processing = plug_start_processing,
    .stop_processing = plug_stop_processing,
    .reset = plug_reset,
    .process = plug_process,
    .get_extension = plug_get_extension,
    .on_main_thread = plug_on_main_thread,
};

static uint32_t factory_get_plugin_count(const clap_plugin_factory_t *factory) {
    (void)factory;
    return 1;
}

static const clap_plugin_descriptor_t *factory_get_plugin_descriptor(
    const clap_plugin_factory_t *factory, uint32_t index) {
    (void)factory;
    return index == 0 ? &kDesc : NULL;
}

static const clap_plugin_t *factory_create_plugin(const clap_plugin_factory_t *factory,
                                                  const clap_host_t *host,
                                                  const char *plugin_id) {
    (void)factory;
    (void)host;
    if (!plugin_id || strcmp(plugin_id, kId) != 0) return NULL;
    static probe_t probe;
    probe.plugin = kPluginTemplate;
    probe.plugin.plugin_data = &probe;
    probe.gain = 0.5f;
    return &probe.plugin;
}

static const clap_plugin_factory_t kFactory = {
    .get_plugin_count = factory_get_plugin_count,
    .get_plugin_descriptor = factory_get_plugin_descriptor,
    .create_plugin = factory_create_plugin,
};

static bool entry_init(const char *plugin_path) {
    (void)plugin_path;
    return true;
}
static void entry_deinit(void) {}
static const void *entry_get_factory(const char *factory_id) {
    if (factory_id && strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) == 0)
        return &kFactory;
    return NULL;
}

const clap_plugin_entry_t clap_entry = {
    .clap_version = CLAP_VERSION_INIT,
    .init = entry_init,
    .deinit = entry_deinit,
    .get_factory = entry_get_factory,
};
