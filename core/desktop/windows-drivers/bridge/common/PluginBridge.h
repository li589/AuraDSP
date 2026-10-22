// PluginBridge.h — 三桥共用插件槽转发（vm_bridge / vaio_bridge / asio_bridge）。
//
// 根因（2026-10-20）：桥各自加载一份 auradsp_engine.dll 并建独立 handle，
// 而 UI isolate 的插件命令只发给本地 handle。桥模式下本地 handle 空闲，
// 插件编辑器能开、参数能改，但音频路径上的桥 handle 里没有插件 → 无效果。
//
// 本头只做控制面转发：桥把 auradsp_plugin_slot_* 导出解析出来，Dart 侧按
// 当前后端把插件命令路由到桥。RT 回调不经过此处（引擎内部仍无锁）。
//
// 镜像：VM 的 CHANGE 重建会换掉 handle，桥内必须记一份插件配置并在重建后
// 回放；VAIO/ASIO 虽由 Dart 侧 start/stop 重建，但镜像同样让 Dart 可以
// "进桥时只补一次配置"。
#pragma once

#include <windows.h>
#include <stdint.h>
#include <cstring>

namespace auraplugin {

constexpr int kSlots = 4;

struct Fns {
    using FnLoad = int (*)(void*, int, const char*, const char*);
    using FnUnload = int (*)(void*, int);
    using FnSetBypass = int (*)(void*, int, int);
    using FnGetBypass = int (*)(void*, int);
    using FnGetLatency = uint32_t (*)(void*, int);
    using FnGetStatus = int (*)(void*, int, char*, int);
    using FnShowEditor = int (*)(void*, int, const char*);
    using FnCloseEditor = int (*)(void*, int);
    using FnIsEditorOpen = int (*)(void*, int);
    using FnSavePreset = int (*)(void*, int, const char*);
    using FnLoadPreset = int (*)(void*, int, const char*);
    using FnSetStage = int (*)(void*, int, int);
    using FnGetStage = int (*)(void*, int);
    using FnSetChannels = int (*)(void*, int, int);
    using FnGetChannels = int (*)(void*, int);
    /* 链级启用开关（2026-10-22 VB 按路插件处理）：可选解析——旧引擎 DLL
     * 无此符号时保持 nullptr，调用方判空跳过（桥不因引擎版本被拒载）。 */
    using FnChainSetEnabled = int (*)(void*, int);
    using FnChainGetEnabled = int (*)(void*, int);

    FnLoad load = nullptr;
    FnUnload unload = nullptr;
    FnSetBypass setBypass = nullptr;
    FnGetBypass getBypass = nullptr;
    FnGetLatency getLatency = nullptr;
    FnGetStatus getStatus = nullptr;
    FnShowEditor showEditor = nullptr;
    FnCloseEditor closeEditor = nullptr;
    FnIsEditorOpen isEditorOpen = nullptr;
    FnSavePreset savePreset = nullptr;
    FnLoadPreset loadPreset = nullptr;
    FnSetStage setStage = nullptr;
    FnGetStage getStage = nullptr;
    FnSetChannels setChannels = nullptr;
    FnGetChannels getChannels = nullptr;
    FnChainSetEnabled chainSetEnabled = nullptr;
    FnChainGetEnabled chainGetEnabled = nullptr;

    bool HasChainEnable() const { return chainSetEnabled && chainGetEnabled; }

    bool Ready() const {
        return load && unload && setBypass && getBypass && getLatency &&
               getStatus && showEditor && closeEditor && isEditorOpen &&
               savePreset && loadPreset && setStage && getStage &&
               setChannels && getChannels;
    }

    bool Resolve(HMODULE mod) {
        load = nullptr;
        unload = nullptr;
        setBypass = nullptr;
        getBypass = nullptr;
        getLatency = nullptr;
        getStatus = nullptr;
        showEditor = nullptr;
        closeEditor = nullptr;
        isEditorOpen = nullptr;
        savePreset = nullptr;
        loadPreset = nullptr;
        setStage = nullptr;
        getStage = nullptr;
        setChannels = nullptr;
        getChannels = nullptr;
        chainSetEnabled = nullptr;
        chainGetEnabled = nullptr;
        if (!mod) return false;
        load = (FnLoad)GetProcAddress(mod, "auradsp_plugin_slot_load");
        unload = (FnUnload)GetProcAddress(mod, "auradsp_plugin_slot_unload");
        setBypass = (FnSetBypass)GetProcAddress(
            mod, "auradsp_plugin_slot_set_bypass");
        getBypass = (FnGetBypass)GetProcAddress(
            mod, "auradsp_plugin_slot_get_bypass");
        getLatency = (FnGetLatency)GetProcAddress(
            mod, "auradsp_plugin_slot_get_latency");
        getStatus = (FnGetStatus)GetProcAddress(
            mod, "auradsp_plugin_slot_get_status");
        showEditor = (FnShowEditor)GetProcAddress(
            mod, "auradsp_plugin_slot_show_editor");
        closeEditor = (FnCloseEditor)GetProcAddress(
            mod, "auradsp_plugin_slot_close_editor");
        isEditorOpen = (FnIsEditorOpen)GetProcAddress(
            mod, "auradsp_plugin_slot_is_editor_open");
        savePreset = (FnSavePreset)GetProcAddress(
            mod, "auradsp_plugin_slot_save_preset");
        loadPreset = (FnLoadPreset)GetProcAddress(
            mod, "auradsp_plugin_slot_load_preset");
        setStage = (FnSetStage)GetProcAddress(
            mod, "auradsp_plugin_slot_set_insert_stage");
        getStage = (FnGetStage)GetProcAddress(
            mod, "auradsp_plugin_slot_get_insert_stage");
        setChannels = (FnSetChannels)GetProcAddress(
            mod, "auradsp_plugin_slot_set_channels");
        getChannels = (FnGetChannels)GetProcAddress(
            mod, "auradsp_plugin_slot_get_channels");
        /* 可选符号：旧引擎 DLL 无此导出时保持 nullptr（不参与 Ready()）。 */
        chainSetEnabled = (FnChainSetEnabled)GetProcAddress(
            mod, "auradsp_plugin_chain_set_enabled");
        chainGetEnabled = (FnChainGetEnabled)GetProcAddress(
            mod, "auradsp_plugin_chain_get_enabled");
        return Ready();
    }
};

struct Cfg {
    bool loaded = false;
    char path[1024] = {};
    char id[256] = {};
    int bypass = 0;
    int stage = 3;
    int channels = 0xFF;
};

// 控制线程镜像（Dart 线程 + VM monitor 重建线程）。RT 线程从不读取。
class Mirror {
public:
    Mirror() { InitializeSRWLock(&lock_); }

    void Reset() {
        AcquireSRWLockExclusive(&lock_);
        for (int i = 0; i < kSlots; ++i) cfg_[i] = Cfg{};
        ReleaseSRWLockExclusive(&lock_);
    }

    void SetLoad(int slot, const char* path, const char* id, int stage,
                 int bypass, int channels) {
        if (slot < 0 || slot >= kSlots || !path) return;
        AcquireSRWLockExclusive(&lock_);
        Cfg& c = cfg_[slot];
        c.loaded = true;
        strncpy_s(c.path, path, _TRUNCATE);
        strncpy_s(c.id, id ? id : "", _TRUNCATE);
        c.stage = stage;
        c.bypass = bypass;
        c.channels = channels;
        ReleaseSRWLockExclusive(&lock_);
    }

    void SetUnload(int slot) {
        if (slot < 0 || slot >= kSlots) return;
        AcquireSRWLockExclusive(&lock_);
        cfg_[slot] = Cfg{};
        ReleaseSRWLockExclusive(&lock_);
    }

    void SetBypass(int slot, int bypass) {
        if (slot < 0 || slot >= kSlots) return;
        AcquireSRWLockExclusive(&lock_);
        cfg_[slot].bypass = bypass;
        ReleaseSRWLockExclusive(&lock_);
    }

    void SetStage(int slot, int stage) {
        if (slot < 0 || slot >= kSlots) return;
        AcquireSRWLockExclusive(&lock_);
        cfg_[slot].stage = stage;
        ReleaseSRWLockExclusive(&lock_);
    }

    void SetChannels(int slot, int channels) {
        if (slot < 0 || slot >= kSlots) return;
        AcquireSRWLockExclusive(&lock_);
        cfg_[slot].channels = channels;
        ReleaseSRWLockExclusive(&lock_);
    }

    // 读取某槽的镜像状态（后台组补齐回放用：补齐后让该组落到与其它组
    // 一致的 bypass/Ch/阶段，而不是出厂默认）。path/id 可选（掩码新使能
    // 组补挂时用）。不存在返回 false。
    bool GetSlot(int slot, int* stage, int* bypass, int* channels,
                 char* path = nullptr, size_t pathCap = 0,
                 char* id = nullptr, size_t idCap = 0) {
        if (slot < 0 || slot >= kSlots) return false;
        AcquireSRWLockExclusive(&lock_);
        const bool loaded = cfg_[slot].loaded;
        if (loaded) {
            if (stage) *stage = cfg_[slot].stage;
            if (bypass) *bypass = cfg_[slot].bypass;
            if (channels) *channels = cfg_[slot].channels;
            if (path && pathCap) {
                strncpy_s(path, pathCap, cfg_[slot].path, _TRUNCATE);
            }
            if (id && idCap) {
                strncpy_s(id, idCap, cfg_[slot].id, _TRUNCATE);
            }
        }
        ReleaseSRWLockExclusive(&lock_);
        return loaded;
    }

    // 重建后回放（调用方已确保音频线程不接触 engine）。返回成功/失败槽数。
    void Replay(void* engine, const Fns& fns, int* ok, int* failed) {
        if (ok) *ok = 0;
        if (failed) *failed = 0;
        if (!engine || !fns.Ready()) return;
        AcquireSRWLockExclusive(&lock_);
        for (int i = 0; i < kSlots; ++i) {
            const Cfg c = cfg_[i];
            if (!c.loaded) continue;
            if (fns.load(engine, i, c.path, c.id) != 1) {
                if (failed) ++*failed;
                continue;
            }
            fns.setChannels(engine, i, c.channels);
            fns.setStage(engine, i, c.stage);
            fns.setBypass(engine, i, c.bypass);
            if (ok) ++*ok;
        }
        ReleaseSRWLockExclusive(&lock_);
    }

private:
    SRWLOCK lock_;
    Cfg cfg_[kSlots];
};

// ---- 便捷转发（调用方负责 engine 非空与桥 running 检查） ----
inline int SlotLoad(void* e, const Fns& f, Mirror& m, int slot,
                    const char* path, const char* id) {
    if (!e || !f.Ready() || slot < 0 || slot >= kSlots || !path || !*path)
        return 0;
    const int rc = f.load(e, slot, path, id ? id : "");
    if (rc == 1) {
        m.SetLoad(slot, path, id, f.getStage(e, slot), f.getBypass(e, slot),
                  f.getChannels(e, slot));
    }
    return rc;
}

inline int SlotUnload(void* e, const Fns& f, Mirror& m, int slot) {
    if (!e || !f.Ready() || slot < 0 || slot >= kSlots) return 0;
    const int rc = f.unload(e, slot);
    if (rc == 1) m.SetUnload(slot);
    return rc;
}

inline int SlotSetBypass(void* e, const Fns& f, Mirror& m, int slot,
                         int bypass) {
    if (!e || !f.Ready() || slot < 0 || slot >= kSlots) return 0;
    const int rc = f.setBypass(e, slot, bypass ? 1 : 0);
    if (rc == 1) m.SetBypass(slot, bypass ? 1 : 0);
    return rc;
}

inline int SlotSetStage(void* e, const Fns& f, Mirror& m, int slot,
                        int stage) {
    if (!e || !f.Ready() || slot < 0 || slot >= kSlots) return 0;
    const int rc = f.setStage(e, slot, stage);
    if (rc == 1) m.SetStage(slot, stage);
    return rc;
}

inline int SlotSetChannels(void* e, const Fns& f, Mirror& m, int slot,
                           int channels) {
    if (!e || !f.Ready() || slot < 0 || slot >= kSlots) return 0;
    const int rc = f.setChannels(e, slot, channels);
    if (rc == 1) m.SetChannels(slot, channels);
    return rc;
}

inline int SlotGetChannels(void* e, const Fns& f, int slot) {
    if (!e || !f.Ready() || slot < 0 || slot >= kSlots) return 0xFF;
    return f.getChannels(e, slot);
}

inline int SlotGetStatus(void* e, const Fns& f, int slot, char* out, int cap) {
    if (!e || !f.Ready() || slot < 0 || slot >= kSlots ||
        !out || cap <= 1) {
        if (out && cap > 0) out[0] = 0;
        return 0;
    }
    return f.getStatus(e, slot, out, cap);
}

}  // namespace auraplugin
