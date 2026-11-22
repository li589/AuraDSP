// test_latency_plugin_clap.cpp — AUD-01 动态复现夹具（2026-11-23）。
//
// 最小 CLAP 插件：直通音频，报告延迟可经 state（预设文件）改写——
// state.load 读入 4 字节小端 uint32 作为新延迟，并按 CLAP 规范经
// clap_host_latency.changed 通知宿主。用途：smoke_aud01_pdc_repro
// 以进程外（process）模式加载本夹具，判别 ProcessPluginProxy 在
// loadPreset 后上报延迟的记账口径（AUD-01 修复 f8dd5196：新插件
// 延迟 + 当前回调块数 × 传输块长；旧实现恒 +1 块且不更新插件
// 延迟分量，后续块数变化还会用旧值重算覆盖）。
//
// 预设文件格式即 state.save 的产物：4 字节 LE uint32 延迟值。
#include "clap/clap.h"

#include <cstdint>
#include <cstring>

namespace {

struct TestLatencyPlugin {
    clap_plugin_t plugin;
    const clap_host_t* host = nullptr;
    uint32_t latency = 100;  // 出厂延迟（帧）
};

TestLatencyPlugin* self(const clap_plugin_t* p) {
    return static_cast<TestLatencyPlugin*>(p->plugin_data);
}

bool plugin_init(const clap_plugin_t*) { return true; }
void plugin_destroy(const clap_plugin_t* p) { delete self(p); }
bool plugin_activate(const clap_plugin_t*, double, uint32_t, uint32_t) {
    return true;
}
void plugin_deactivate(const clap_plugin_t*) {}
bool plugin_start_processing(const clap_plugin_t*) { return true; }
void plugin_stop_processing(const clap_plugin_t*) {}
void plugin_reset(const clap_plugin_t*) {}
void plugin_on_main_thread(const clap_plugin_t*) {}

clap_process_status plugin_process(const clap_plugin_t*,
                                   const clap_process_t* process) {
    if (process->audio_inputs_count > 0 && process->audio_outputs_count > 0) {
        const clap_audio_buffer_t& in = process->audio_inputs[0];
        clap_audio_buffer_t& out = process->audio_outputs[0];
        const uint32_t chs = in.channel_count < out.channel_count
                                 ? in.channel_count
                                 : out.channel_count;
        for (uint32_t c = 0; c < chs; c++) {
            if (in.data32 && out.data32 && in.data32[c] && out.data32[c]) {
                std::memcpy(out.data32[c], in.data32[c],
                            sizeof(float) * process->frames_count);
            }
        }
    }
    return CLAP_PROCESS_CONTINUE;
}

uint32_t latency_get(const clap_plugin_t* p) { return self(p)->latency; }

bool state_save(const clap_plugin_t* p, const clap_ostream_t* stream) {
    const uint32_t v = self(p)->latency;
    const uint8_t b[4] = {static_cast<uint8_t>(v & 0xFF),
                          static_cast<uint8_t>((v >> 8) & 0xFF),
                          static_cast<uint8_t>((v >> 16) & 0xFF),
                          static_cast<uint8_t>((v >> 24) & 0xFF)};
    return stream->write(stream, b, 4) == 4;
}

bool state_load(const clap_plugin_t* p, const clap_istream_t* stream) {
    uint8_t b[4] = {0, 0, 0, 0};
    int64_t got = 0;
    while (got < 4) {
        const int64_t n = stream->read(stream, b + got, 4 - got);
        if (n <= 0) return false;
        got += n;
    }
    auto* tp = self(p);
    tp->latency = static_cast<uint32_t>(b[0]) |
                  (static_cast<uint32_t>(b[1]) << 8) |
                  (static_cast<uint32_t>(b[2]) << 16) |
                  (static_cast<uint32_t>(b[3]) << 24);
    // 规范口径：延迟变化后通知宿主重新查询。
    if (tp->host) {
        auto* latHost = static_cast<const clap_host_latency_t*>(
            tp->host->get_extension(tp->host, CLAP_EXT_LATENCY));
        if (latHost && latHost->changed) latHost->changed(tp->host);
    }
    return true;
}

uint32_t ports_count(const clap_plugin_t*, bool) { return 1; }

bool ports_get(const clap_plugin_t*, uint32_t index, bool is_input,
               clap_audio_port_info_t* info) {
    if (index != 0) return false;
    info->id = 0;
    std::strncpy(info->name, is_input ? "In" : "Out", CLAP_NAME_SIZE - 1);
    info->name[CLAP_NAME_SIZE - 1] = '\0';
    info->flags = CLAP_AUDIO_PORT_IS_MAIN;
    info->channel_count = 2;
    std::strncpy(info->port_type, CLAP_PORT_STEREO, CLAP_NAME_SIZE - 1);
    info->port_type[CLAP_NAME_SIZE - 1] = '\0';
    info->in_place_pair = CLAP_INVALID_ID;
    return true;
}

const clap_plugin_latency_t kLatencyExt = {&latency_get};
const clap_plugin_state_t kStateExt = {&state_save, &state_load};
const clap_plugin_audio_ports_t kPortsExt = {&ports_count, &ports_get};

const void* plugin_get_extension(const clap_plugin_t*, const char* id) {
    if (std::strcmp(id, CLAP_EXT_LATENCY) == 0) return &kLatencyExt;
    if (std::strcmp(id, CLAP_EXT_STATE) == 0) return &kStateExt;
    if (std::strcmp(id, CLAP_EXT_AUDIO_PORTS) == 0) return &kPortsExt;
    return nullptr;
}

const char* kFeatures[] = {CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
                           CLAP_PLUGIN_FEATURE_UTILITY, nullptr};

const clap_plugin_descriptor_t kDescriptor = {
    CLAP_VERSION,
    "dev.auradsp.test.latency",
    "AuraDSP Test Latency",
    "AuraDSP Project",
    "",
    "",
    "",
    "1.0.0",
    "AUD-01 repro fixture: passthrough, preset-variable latency",
    kFeatures,
};

uint32_t factory_count(const clap_plugin_factory_t*) { return 1; }

const clap_plugin_descriptor_t* factory_descriptor(
    const clap_plugin_factory_t*, uint32_t index) {
    return index == 0 ? &kDescriptor : nullptr;
}

const clap_plugin_t* factory_create(const clap_plugin_factory_t*,
                                    const clap_host_t* host,
                                    const char* plugin_id) {
    if (!plugin_id || std::strcmp(plugin_id, kDescriptor.id) != 0) {
        return nullptr;
    }
    auto* tp = new TestLatencyPlugin();
    tp->host = host;
    tp->plugin.desc = &kDescriptor;
    tp->plugin.plugin_data = tp;
    tp->plugin.init = &plugin_init;
    tp->plugin.destroy = &plugin_destroy;
    tp->plugin.activate = &plugin_activate;
    tp->plugin.deactivate = &plugin_deactivate;
    tp->plugin.start_processing = &plugin_start_processing;
    tp->plugin.stop_processing = &plugin_stop_processing;
    tp->plugin.reset = &plugin_reset;
    tp->plugin.process = &plugin_process;
    tp->plugin.get_extension = &plugin_get_extension;
    tp->plugin.on_main_thread = &plugin_on_main_thread;
    return &tp->plugin;
}

const clap_plugin_factory_t kFactory = {&factory_count, &factory_descriptor,
                                        &factory_create};

bool entry_init(const char*) { return true; }
void entry_deinit() {}
const void* entry_get_factory(const char* factory_id) {
    if (std::strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) == 0) return &kFactory;
    return nullptr;
}

}  // namespace

extern "C" {
CLAP_EXPORT const clap_plugin_entry_t clap_entry = {CLAP_VERSION, &entry_init,
                                                    &entry_deinit,
                                                    &entry_get_factory};
}
