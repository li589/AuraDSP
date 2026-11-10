// 门禁资产：最小 CLAP 插件（C++，smoke_plugin_fault_latch 现场
// 编译）。与 probe_gain 同骨架，但 process() 抛 C++ 异常——
// POSIX 形态下逐槽守卫的 try/catch 应捕获并闩锁该槽
// （fault/process/process_crash、有效旁路），引擎进程存活
// （Part I Q0-2：POSIX 不做信号级恢复，但 C++ 异常路径是
// 既定可恢复面）。工厂/描述符/激活全部正常——只有 process
// 抛异常。
#include <clap/clap.h>

#include <cstdlib>
#include <cstring>
#include <stdexcept>

namespace {

const char *kFeatures[] = {CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
                           CLAP_PLUGIN_FEATURE_STEREO, nullptr};

const clap_plugin_descriptor_t kDesc = {
    CLAP_VERSION_INIT,
    "com.auradsp.probe.throw",
    "Probe Throw",
    "AuraDSP Probe",
    "",
    "",
    "",
    "1.0.0",
    "Throws a C++ exception in process() (fault-latch probe)",
    kFeatures,
};

struct ProbePlugin {
    clap_plugin_t plugin;
    const clap_host_t *host = nullptr;
};

bool probe_init(const clap_plugin_t *) { return true; }

void probe_destroy(const clap_plugin_t *plugin) {
    std::free(plugin->plugin_data);
}

bool probe_activate(const clap_plugin_t *, double, uint32_t, uint32_t) {
    return true;
}

void probe_deactivate(const clap_plugin_t *) {}

void probe_reset(const clap_plugin_t *) {}

clap_process_status probe_process(const clap_plugin_t *,
                                  const clap_process_t *) {
    throw std::runtime_error("probe throw: process() failure injection");
}

uint32_t ports_count(const clap_plugin_t *, bool) { return 1; }

bool ports_get(const clap_plugin_t *, uint32_t index, bool is_input,
               clap_audio_port_info_t *info) {
    if (index != 0) return false;
    info->id = 0;
    info->channel_count = 2;
    info->flags = CLAP_AUDIO_PORT_IS_MAIN;
    info->port_type = CLAP_PORT_STEREO;
    info->in_place_pair = is_input ? CLAP_INVALID_ID : 0;
    std::strncpy(info->name, is_input ? "in" : "out",
                 sizeof(info->name) - 1);
    return true;
}

const clap_plugin_audio_ports_t kPortsImpl = {ports_count, ports_get};

const void *probe_get_extension(const clap_plugin_t *, const char *id) {
    if (std::strcmp(id, CLAP_EXT_AUDIO_PORTS) == 0) return &kPortsImpl;
    return nullptr;
}

void probe_on_main_thread(const clap_plugin_t *) {}

const clap_plugin_t *factory_create(const clap_host_t *host,
                                    const char *plugin_id) {
    if (std::strcmp(plugin_id, kDesc.id) != 0) return nullptr;
    auto *p = static_cast<ProbePlugin *>(
        std::calloc(1, sizeof(ProbePlugin)));
    if (!p) return nullptr;
    p->host = host;
    p->plugin.desc = &kDesc;
    p->plugin.plugin_data = p;
    p->plugin.init = probe_init;
    p->plugin.destroy = probe_destroy;
    p->plugin.activate = probe_activate;
    p->plugin.deactivate = probe_deactivate;
    p->plugin.start_processing = nullptr;
    p->plugin.stop_processing = nullptr;
    p->plugin.reset = probe_reset;
    p->plugin.process = probe_process;
    p->plugin.get_extension = probe_get_extension;
    p->plugin.on_main_thread = probe_on_main_thread;
    return &p->plugin;
}

uint32_t factory_count(const clap_plugin_factory *) { return 1; }

const clap_plugin_descriptor_t *factory_desc(
    const clap_plugin_factory *, uint32_t index) {
    return index == 0 ? &kDesc : nullptr;
}

const clap_plugin_t *factory_create_wrapped(
    const clap_plugin_factory *, const clap_host_t *host,
    const char *plugin_id) {
    return factory_create(host, plugin_id);
}

const clap_plugin_factory_t kFactory = {factory_count, factory_desc,
                                        factory_create_wrapped};

bool entry_init(const char *) { return true; }

void entry_deinit() {}

const void *entry_get_factory(const char *factory_id) {
    if (std::strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) == 0)
        return &kFactory;
    return nullptr;
}

}  // namespace

extern "C" {

CLAP_EXPORT const clap_plugin_entry_t clap_entry = {
    CLAP_VERSION_INIT, entry_init, entry_deinit, entry_get_factory,
};

}  // extern "C"
