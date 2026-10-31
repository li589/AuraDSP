// plugin_abi_stub.cpp — 插件子系统裁剪（AURADSP_ENABLE_PLUGINS=OFF）时的 C ABI 占位。
//
// 目的（跨平台基础审查 CP-02，2026-11-01）：
//   1. 非 Windows 构建可整体排除 VST3/CLAP 宿主（Win32 扫描/编辑器/远程 IPC）；
//   2. `.def` 导出集保持不变（F3：不增不减），Dart 侧绑定无需按平台分叉；
//   3. 所有插件能力报告「不可用」：扫描 0 条、加载失败、旁路默认开、槽位数固定。
//
// 与 plugin_abi.cpp 的 null-host 分支默认值逐项对齐（见该文件各 return 默认值），
// 避免 UI 在裁剪构建下读到不同语义。全部函数不分配、不加锁，可被控制线程调用。
#include "auradsp_engine.h"

namespace {
// 与 plugin_host.h 的 PluginHostManager::kMaxPluginSlots 保持一致（不引插件头）。
constexpr int kStubPluginSlots = 4;
constexpr int kStubDefaultInsertStage = 3;   // Post-Reverb
constexpr int kStubDefaultChannelMask = 0xFF; // 8 声道全开
} // namespace

extern "C" {

int auradsp_plugin_scan(auradsp_handle h, const char* extra_dirs_json, int deep_scan) {
    (void)h; (void)extra_dirs_json; (void)deep_scan;
    return 0;
}

int auradsp_plugin_scan_begin(auradsp_handle h, const char* extra_dirs_json, int deep_scan) {
    (void)h; (void)extra_dirs_json; (void)deep_scan;
    return 0;
}

int auradsp_plugin_scan_step(auradsp_handle h, int max_items) {
    (void)h; (void)max_items;
    return 0;
}

int auradsp_plugin_scan_progress(auradsp_handle h, int* out_total) {
    (void)h;
    if (out_total) *out_total = 0;
    return -1; // 无扫描任务（与 plugin_abi 的 null-host 分支一致）
}

int auradsp_plugin_scan_end(auradsp_handle h) {
    (void)h;
    return 0;
}

int auradsp_plugin_get_count(auradsp_handle h) {
    (void)h;
    return 0;
}

int auradsp_plugin_get_item(auradsp_handle h, int index, char* out_json, int max_len) {
    (void)h; (void)index; (void)out_json; (void)max_len;
    return 0;
}

int auradsp_plugin_get_all(auradsp_handle h, char* out_json, int max_len) {
    (void)h; (void)out_json; (void)max_len;
    return 0;
}

int auradsp_plugin_get_num_slots(auradsp_handle h) {
    (void)h;
    return kStubPluginSlots;
}

int auradsp_plugin_slot_load(auradsp_handle h, int slot, const char* path,
                             const char* plugin_id) {
    (void)h; (void)slot; (void)path; (void)plugin_id;
    return 0; // 裁剪构建不支持插件加载
}

int auradsp_plugin_slot_unload(auradsp_handle h, int slot) {
    (void)h; (void)slot;
    return 0;
}

int auradsp_plugin_slot_load_async(auradsp_handle h, int slot, const char* path,
                                   const char* plugin_id) {
    (void)h; (void)slot; (void)path; (void)plugin_id;
    return 0;
}

int auradsp_plugin_slot_unload_async(auradsp_handle h, int slot) {
    (void)h; (void)slot;
    return 0;
}

int auradsp_plugin_slot_task_state(auradsp_handle h, int slot) {
    (void)h; (void)slot;
    return 0; // 0 = 无任务
}

int auradsp_plugin_slot_set_bypass(auradsp_handle h, int slot, int bypass) {
    (void)h; (void)slot; (void)bypass;
    return 0;
}

int auradsp_plugin_slot_get_bypass(auradsp_handle h, int slot) {
    (void)h; (void)slot;
    return 1; // 默认旁路（无插件可处理）
}

uint32_t auradsp_plugin_slot_get_latency(auradsp_handle h, int slot) {
    (void)h; (void)slot;
    return 0;
}

int auradsp_plugin_slot_get_status(auradsp_handle h, int slot, char* out_json,
                                   int max_len) {
    (void)h; (void)slot; (void)out_json; (void)max_len;
    return 0;
}

int auradsp_plugin_slot_show_editor(auradsp_handle h, int slot, const char* title) {
    (void)h; (void)slot; (void)title;
    return 0;
}

int auradsp_plugin_slot_close_editor(auradsp_handle h, int slot) {
    (void)h; (void)slot;
    return 0;
}

int auradsp_plugin_slot_is_editor_open(auradsp_handle h, int slot) {
    (void)h; (void)slot;
    return 0;
}

int auradsp_plugin_slot_save_preset(auradsp_handle h, int slot, const char* path) {
    (void)h; (void)slot; (void)path;
    return 0;
}

int auradsp_plugin_slot_load_preset(auradsp_handle h, int slot, const char* path) {
    (void)h; (void)slot; (void)path;
    return 0;
}

int auradsp_plugin_slot_set_insert_stage(auradsp_handle h, int slot, int stage) {
    (void)h; (void)slot; (void)stage;
    return 0;
}

int auradsp_plugin_slot_get_insert_stage(auradsp_handle h, int slot) {
    (void)h; (void)slot;
    return kStubDefaultInsertStage;
}

int auradsp_plugin_slot_set_channels(auradsp_handle h, int slot, int mask) {
    (void)h; (void)slot; (void)mask;
    return 0;
}

int auradsp_plugin_slot_get_channels(auradsp_handle h, int slot) {
    (void)h; (void)slot;
    return kStubDefaultChannelMask;
}

int auradsp_plugin_set_pdc(auradsp_handle h, int enable) {
    (void)h; (void)enable;
    return 0;
}

int auradsp_plugin_get_pdc(auradsp_handle h) {
    (void)h;
    return 0;
}

int auradsp_plugin_chain_set_enabled(auradsp_handle h, int enabled) {
    (void)h; (void)enabled;
    return 0;
}

int auradsp_plugin_chain_get_enabled(auradsp_handle h) {
    (void)h;
    return 0;
}

uint32_t auradsp_plugin_get_total_latency(auradsp_handle h) {
    (void)h;
    return 0;
}

int auradsp_plugin_load(auradsp_handle h, const char* path, const char* plugin_id) {
    (void)h; (void)path; (void)plugin_id;
    return 0;
}

int auradsp_plugin_unload(auradsp_handle h) {
    (void)h;
    return 0;
}

int auradsp_plugin_set_bypass(auradsp_handle h, int bypass) {
    (void)h; (void)bypass;
    return 0;
}

int auradsp_plugin_get_bypass(auradsp_handle h) {
    (void)h;
    return 1;
}

uint32_t auradsp_plugin_get_latency(auradsp_handle h) {
    (void)h;
    return 0;
}

int auradsp_plugin_get_status(auradsp_handle h, char* out_json, int max_len) {
    (void)h; (void)out_json; (void)max_len;
    return 0;
}

int auradsp_plugin_set_editor_quarantine_list(const char* patterns) {
    (void)patterns;
    return 1; // 名单已“接受”（裁剪构建无编辑器可隔离）
}

} // extern "C"
