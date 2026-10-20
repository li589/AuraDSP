#include "engine_internal.h"
#include "plugins/driver/plugin_chain_component.h"

#include <cstring>
#include <string>

namespace {

auradsp::PluginHostManager* plugin_host(auradsp_handle h) {
    return (h && h->plugin.chain) ? &h->plugin.chain->host() : nullptr;
}

} // namespace

extern "C" {

int auradsp_plugin_scan(auradsp_handle h, const char* extra_dirs_json, int deep_scan) {
    auto* host = plugin_host(h);
    if (!host) return 0;
    std::string extra = extra_dirs_json ? extra_dirs_json : "";
    return host->scanPlugins(extra, deep_scan != 0);
}

int auradsp_plugin_scan_begin(auradsp_handle h, const char* extra_dirs_json, int deep_scan) {
    auto* host = plugin_host(h);
    if (!host) return 0;
    std::string extra = extra_dirs_json ? extra_dirs_json : "";
    return host->scanBegin(extra, deep_scan != 0);
}

int auradsp_plugin_scan_step(auradsp_handle h, int max_items) {
    auto* host = plugin_host(h);
    if (!host) return 0;
    return host->scanStep(max_items);
}

int auradsp_plugin_scan_progress(auradsp_handle h, int* out_total) {
    auto* host = plugin_host(h);
    if (!host) return -1;
    int processed = host->scanProcessed();
    if (out_total) *out_total = host->scanTotal();
    return processed;
}

int auradsp_plugin_scan_end(auradsp_handle h) {
    auto* host = plugin_host(h);
    if (!host) return 0;
    return host->scanEnd();
}

int auradsp_plugin_get_count(auradsp_handle h) {
    auto* host = plugin_host(h);
    if (!host) return 0;
    return (int)host->getScannedCount();
}

int auradsp_plugin_get_item(auradsp_handle h, int index, char* out_json, int max_len) {
    auto* host = plugin_host(h);
    if (!host || !out_json || max_len <= 1 || index < 0) return 0;
    std::string json = host->getScannedItemJson((size_t)index);
    if (json.length() >= (size_t)max_len) {
        memcpy(out_json, json.data(), (size_t)(max_len - 1));
        out_json[max_len - 1] = '\0';
        return max_len - 1;
    }
    memcpy(out_json, json.data(), json.length());
    out_json[json.length()] = '\0';
    return (int)json.length();
}

int auradsp_plugin_get_all(auradsp_handle h, char* out_json, int max_len) {
    auto* host = plugin_host(h);
    if (!host || !out_json || max_len <= 1) return 0;
    std::string json = host->getAllScannedJson();
    if (json.length() >= (size_t)max_len) {
        memcpy(out_json, json.data(), (size_t)(max_len - 1));
        out_json[max_len - 1] = '\0';
        return max_len - 1;
    }
    memcpy(out_json, json.data(), json.length());
    out_json[json.length()] = '\0';
    return (int)json.length();
}

int auradsp_plugin_get_num_slots(auradsp_handle h) {
    (void)h;
    return (int)auradsp::PluginHostManager::kMaxPluginSlots;
}

int auradsp_plugin_slot_load(auradsp_handle h, int slot, const char* path, const char* plugin_id) {
    auto* host = plugin_host(h);
    if (!host || !path || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    std::string id = plugin_id ? plugin_id : "";
    bool ok = host->loadPluginSlot((size_t)slot, path, id, h->sample_rate,
                                   (uint32_t)h->max_block);
    return ok ? 1 : 0;
}

int auradsp_plugin_slot_unload(auradsp_handle h, int slot) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    host->unloadPluginSlot((size_t)slot);
    return 1;
}

int auradsp_plugin_slot_load_async(auradsp_handle h, int slot, const char* path, const char* plugin_id) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    std::string p = path ? path : "";
    std::string id = plugin_id ? plugin_id : "";
    return host->submitSlotLoadAsync((size_t)slot, p, id,
        host->getSampleRate(), host->getMaxBlockSize()) ? 1 : 0;
}

int auradsp_plugin_slot_unload_async(auradsp_handle h, int slot) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return host->submitSlotUnloadAsync((size_t)slot) ? 1 : 0;
}

int auradsp_plugin_slot_task_state(auradsp_handle h, int slot) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return host->slotTaskState((size_t)slot);
}

int auradsp_plugin_slot_set_bypass(auradsp_handle h, int slot, int bypass) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    host->setBypassSlot((size_t)slot, bypass != 0);
    return 1;
}

int auradsp_plugin_slot_get_bypass(auradsp_handle h, int slot) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 1;
    return host->isBypassedSlot((size_t)slot) ? 1 : 0;
}

uint32_t auradsp_plugin_slot_get_latency(auradsp_handle h, int slot) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return host->getLatencySlot((size_t)slot);
}

int auradsp_plugin_slot_get_status(auradsp_handle h, int slot, char* out_json, int max_len) {
    auto* host = plugin_host(h);
    if (!host || !out_json || max_len <= 1 || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    std::string json = host->getStatusJsonSlot((size_t)slot);
    if (json.length() >= (size_t)max_len) {
        memcpy(out_json, json.data(), (size_t)(max_len - 1));
        out_json[max_len - 1] = '\0';
        return max_len - 1;
    }
    memcpy(out_json, json.data(), json.length());
    out_json[json.length()] = '\0';
    return (int)json.length();
}

int auradsp_plugin_slot_show_editor(auradsp_handle h, int slot, const char* title) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return host->showEditorSlot((size_t)slot, title ? title : "") ? 1 : 0;
}

int auradsp_plugin_slot_close_editor(auradsp_handle h, int slot) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    host->closeEditorSlot((size_t)slot);
    return 1;
}

int auradsp_plugin_slot_is_editor_open(auradsp_handle h, int slot) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return host->isEditorOpenSlot((size_t)slot) ? 1 : 0;
}

int auradsp_plugin_slot_save_preset(auradsp_handle h, int slot, const char* path) {
    auto* host = plugin_host(h);
    if (!host || !path || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return host->savePresetSlot((size_t)slot, path) ? 1 : 0;
}

int auradsp_plugin_slot_load_preset(auradsp_handle h, int slot, const char* path) {
    auto* host = plugin_host(h);
    if (!host || !path || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return host->loadPresetSlot((size_t)slot, path) ? 1 : 0;
}

int auradsp_plugin_slot_set_insert_stage(auradsp_handle h, int slot, int stage) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    host->setInsertStageSlot((size_t)slot, stage);
    return 1;
}

int auradsp_plugin_slot_get_insert_stage(auradsp_handle h, int slot) {
    auto* host = plugin_host(h);
    if (!host || slot < 0 ||
        slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 3;
    return host->getInsertStageSlot((size_t)slot);
}

int auradsp_plugin_load(auradsp_handle h, const char* path, const char* plugin_id) {
    return auradsp_plugin_slot_load(h, 0, path, plugin_id);
}

int auradsp_plugin_unload(auradsp_handle h) {
    return auradsp_plugin_slot_unload(h, 0);
}

int auradsp_plugin_set_bypass(auradsp_handle h, int bypass) {
    return auradsp_plugin_slot_set_bypass(h, 0, bypass);
}

int auradsp_plugin_get_bypass(auradsp_handle h) {
    return auradsp_plugin_slot_get_bypass(h, 0);
}

uint32_t auradsp_plugin_get_latency(auradsp_handle h) {
    return auradsp_plugin_slot_get_latency(h, 0);
}

int auradsp_plugin_get_status(auradsp_handle h, char* out_json, int max_len) {
    return auradsp_plugin_slot_get_status(h, 0, out_json, max_len);
}

int auradsp_plugin_set_pdc(auradsp_handle h, int enable) {
    if (!h || !h->plugin.chain) return 0;
    h->plugin.chain->setPdc(enable != 0);
    return 1;
}

int auradsp_plugin_get_pdc(auradsp_handle h) {
    if (!h || !h->plugin.chain) return 0;
    return h->plugin.chain->pdc() ? 1 : 0;
}

uint32_t auradsp_plugin_get_total_latency(auradsp_handle h) {
    if (!h || !h->plugin.chain) return 0;
    return h->plugin.chain->totalLatency();
}

} // extern "C"
