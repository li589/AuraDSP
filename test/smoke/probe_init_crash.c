// 门禁资产：最小 CLAP 插件（smoke_plugin_fault_latch 现场编译）。
// 与 probe_crash.c 同骨架，但雷在 activate()：激活时无条件写
// 空指针——加载/激活守卫（loadActivateGuarded）的验证对象：
//   - Windows 进程内：SEH 应捕获并闩锁 fault/load/init_crash；
//   - POSIX：硬件 fault 不可进程内恢复（Q0-2），本探针只经
//     隔离宿主行使——宿主死于激活，App 侧加载以 fault/load
//     闩锁收场（远端加载失败分类）。
// process() 本身是正常直通，工厂/描述符正常——只有激活是雷。
#include <clap/clap.h>

#include <stdlib.h>
#include <string.h>

static const clap_plugin_descriptor_t kDesc = {
    .clap_version = CLAP_VERSION_INIT,
    .id = "com.auradsp.probe.initcrash",
    .name = "Probe Init Crash",
    .vendor = "AuraDSP Probe",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "1.0.0",
    .description = "Crashes in activate() (init-latch probe)",
    .features = (const char *[]){CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
                                 CLAP_PLUGIN_FEATURE_STEREO, NULL},
};

typedef struct {
    clap_plugin_t plugin;
    const clap_host_t *host;
} probe_plugin_t;

static bool probe_init(const clap_plugin_t *plugin) {
    (void)plugin;
    return true;
}

static void probe_destroy(const clap_plugin_t *plugin) {
    free((void *)plugin->plugin_data);
}

static bool probe_activate(const clap_plugin_t *plugin, double sample_rate,
                           uint32_t min_frames, uint32_t max_frames) {
    (void)plugin;
    (void)sample_rate;
    (void)min_frames;
    (void)max_frames;
    // volatile 保证写指令真实发出（不会被优化为 UB 删除）。
    *(volatile float *)0 = 1.0f;
    return true;
}

static void probe_deactivate(const clap_plugin_t *plugin) { (void)plugin; }

static void probe_reset(const clap_plugin_t *plugin) { (void)plugin; }

static clap_process_status probe_process(const clap_plugin_t *plugin,
                                         const clap_process_t *process) {
    (void)plugin;
    const clap_audio_buffer_t *in = &process->audio_inputs[0];
    clap_audio_buffer_t *out = &process->audio_outputs[0];
    const uint32_t n = process->frames_count;
    for (uint32_t ch = 0; ch < in->channel_count && ch < out->channel_count;
         ++ch) {
        const float *src = in->data32[ch];
        float *dst = out->data32[ch];
        if (!src || !dst) continue;
        for (uint32_t i = 0; i < n; ++i) dst[i] = src[i];
    }
    return CLAP_PROCESS_CONTINUE;
}

static uint32_t ports_count(const clap_plugin_t *plugin, bool is_input) {
    (void)plugin;
    (void)is_input;
    return 1;
}

static bool ports_get(const clap_plugin_t *plugin, uint32_t index,
                      bool is_input, clap_audio_port_info_t *info) {
    (void)plugin;
    if (index != 0) return false;
    info->id = 0;
    info->channel_count = 2;
    info->flags = CLAP_AUDIO_PORT_IS_MAIN;
    info->port_type = CLAP_PORT_STEREO;
    info->in_place_pair = is_input ? CLAP_INVALID_ID : 0;
    strncpy(info->name, is_input ? "in" : "out", sizeof(info->name) - 1);
    return true;
}

static const clap_plugin_audio_ports_t kPortsImpl = {.count = ports_count,
                                                     .get = ports_get};

static const void *probe_get_extension(const clap_plugin_t *plugin,
                                       const char *id) {
    (void)plugin;
    if (strcmp(id, CLAP_EXT_AUDIO_PORTS) == 0) return &kPortsImpl;
    return NULL;
}

static void probe_on_main_thread(const clap_plugin_t *plugin) {
    (void)plugin;
}

static const clap_plugin_t *factory_create(const clap_host_t *host,
                                           const char *plugin_id) {
    if (strcmp(plugin_id, kDesc.id) != 0) return NULL;
    probe_plugin_t *p = (probe_plugin_t *)calloc(1, sizeof(probe_plugin_t));
    if (!p) return NULL;
    p->host = host;
    p->plugin.desc = &kDesc;
    p->plugin.plugin_data = p;
    p->plugin.init = probe_init;
    p->plugin.destroy = probe_destroy;
    p->plugin.activate = probe_activate;
    p->plugin.deactivate = probe_deactivate;
    p->plugin.start_processing = NULL;
    p->plugin.stop_processing = NULL;
    p->plugin.reset = probe_reset;
    p->plugin.process = probe_process;
    p->plugin.get_extension = probe_get_extension;
    p->plugin.on_main_thread = probe_on_main_thread;
    return &p->plugin;
}

static uint32_t factory_count(const struct clap_plugin_factory *factory) {
    (void)factory;
    return 1;
}

static const clap_plugin_descriptor_t *factory_desc(
    const struct clap_plugin_factory *factory, uint32_t index) {
    (void)factory;
    return index == 0 ? &kDesc : NULL;
}

static const clap_plugin_t *factory_create_wrapped(
    const struct clap_plugin_factory *factory, const clap_host_t *host,
    const char *plugin_id) {
    (void)factory;
    return factory_create(host, plugin_id);
}

static const clap_plugin_factory_t kFactory = {
    .get_plugin_count = factory_count,
    .get_plugin_descriptor = factory_desc,
    .create_plugin = factory_create_wrapped,
};

static bool entry_init(const char *plugin_path) {
    (void)plugin_path;
    return true;
}

static void entry_deinit(void) {}

static const void *entry_get_factory(const char *factory_id) {
    if (strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) == 0) return &kFactory;
    return NULL;
}

CLAP_EXPORT const clap_plugin_entry_t clap_entry = {
    .clap_version = CLAP_VERSION_INIT,
    .init = entry_init,
    .deinit = entry_deinit,
    .get_factory = entry_get_factory,
};
