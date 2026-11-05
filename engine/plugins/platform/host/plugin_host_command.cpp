// plugin_host_command.cpp — 平台无关的宿主控制命令处理（审计 R-07）。
//
// 原先 Win32 / POSIX 两份宿主主程序各自维护同一套命令循环与 Op 分发
// （两文件各 5 处 Op::* switch），新增 IPC 命令须双改。此处收口为单一实现：
// 传输读写由 HostTransport 注入，深扫查询由 MetadataQueryFn 注入
// （Win32 的 SEH 兜底差异留在平台文件）。

#include "plugin_host_command.h"

#include "plugin_format_driver.h"

#include <cstring>

namespace auradsp {
namespace ipc {

/* 深扫元数据查询实现（协议 v5，2026-11-04）：格式无关，直接交给驱动自己产出——
 * VST3 一个包可出多条、CLAP 走描述符、VST2 仍走它自己的「建起来问」。
 * 与 v4 的区别：不再 createInstance→load→unload，元数据查询不占槽、不进音频路径，
 * 也不会因为实例激活失败而丢掉元数据。
 * 只在宿主进程里跑；引擎侧的 VST2 安全铁律（绝不进程内 LoadLibrary）不受影响。
 * MSVC 下刻意 noinline：Win32 的 SEH 包装函数只含 POD 局部量（C2712），
 * 危险动作必须留在独立栈帧里。 */
#if defined(_MSC_VER)
__declspec(noinline)
#endif
bool queryMetadataDirect(const std::string& path,
                         std::vector<RemotePluginInfo>& out) {
    auto* driver = PluginDriverRegistry::instance().findForPath(path);
    if (!driver) return false;
    const std::string binary = driver->resolveBinary(path);
    if (binary.empty()) return false;
    std::vector<PluginMetadata> metas;
    if (!driver->queryMetadata(path, binary, metas) || metas.empty()) return false;
    const PluginBusInfo noBus{};
    out.clear();
    out.reserve(metas.size());
    for (const auto& m : metas) {
        RemotePluginInfo info = {};
        fillRemoteInfo(m, noBus, info);
        out.push_back(info);
    }
    return true;
}

void fillRemoteInfo(const PluginMetadata& meta, const PluginBusInfo& bus,
                    RemotePluginInfo& info) {
    copyFixed(info.path, sizeof(info.path), meta.path);
    copyFixed(info.id, sizeof(info.id), meta.id);
    copyFixed(info.name, sizeof(info.name), meta.name);
    copyFixed(info.bundleName, sizeof(info.bundleName), meta.bundleName);
    copyFixed(info.vendor, sizeof(info.vendor), meta.vendor);
    copyFixed(info.version, sizeof(info.version), meta.version);
    copyFixed(info.category, sizeof(info.category), meta.category);
    copyFixed(info.description, sizeof(info.description), meta.description);
    copyFixed(info.errorMessage, sizeof(info.errorMessage), meta.errorMessage);
    info.format = static_cast<uint32_t>(meta.format);
    info.latency = meta.latency;
    info.is64Bit = meta.is64Bit ? 1u : 0u;
    info.isCompatible = meta.isCompatible ? 1u : 0u;
    info.inputBuses = bus.inputBuses > 0 ? static_cast<uint32_t>(bus.inputBuses) : 0u;
    info.outputBuses = bus.outputBuses > 0 ? static_cast<uint32_t>(bus.outputBuses) : 0u;
    info.auxInputBuses = bus.auxInputBuses > 0 ? static_cast<uint32_t>(bus.auxInputBuses) : 0u;
    info.auxOutputBuses = bus.auxOutputBuses > 0 ? static_cast<uint32_t>(bus.auxOutputBuses) : 0u;
    info.mainInChannels = bus.mainInChannels > 0 ? static_cast<uint32_t>(bus.mainInChannels) : 0u;
    info.mainOutChannels = bus.mainOutChannels > 0 ? static_cast<uint32_t>(bus.mainOutChannels) : 0u;
}

namespace {

/* 读定长请求头并校验：magic/version 不符或负载超限一律视为协议致命错误。 */
bool readRequest(const HostTransport& transport, MsgHeader& header,
                 std::vector<uint8_t>& payload) {
    if (!transport.read(transport.user, &header, sizeof(header))) return false;
    if (header.magic != kMagic ||
        header.version != static_cast<uint16_t>(kProtocolVersion) ||
        header.payloadSize > kMaxControlPayload) {
        return false;
    }
    payload.resize(header.payloadSize);
    if (header.payloadSize > 0 &&
        !transport.read(transport.user, payload.data(), payload.size())) {
        return false;
    }
    return true;
}

} // namespace

bool handleHostCommand(const HostTransport& transport,
                       PluginHostManager& manager,
                       MetadataQueryFn queryMetadata,
                       bool& running) {
    MsgHeader header = {};
    std::vector<uint8_t> payload;
    if (!readRequest(transport, header, payload)) return false;

    Reader r(payload.data(), payload.size());
    std::vector<uint8_t> body;
    int32_t status = 0;
    const auto op = static_cast<Op>(header.op);

    try {
        switch (op) {
        case Op::Hello:
            body.assign({'A', 'U', 'R', 'A'});
            status = 1;
            break;

        case Op::Ping:
            status = 1;
            break;

        case Op::Scan: {
            std::string dirs;
            uint8_t deep = 0;
            if (!r.str(dirs) || !r.u8(deep)) break;
            status = manager.scanPlugins(dirs, deep != 0);
            break;
        }
        case Op::ScanBegin: {
            std::string dirs;
            uint8_t deep = 0;
            if (!r.str(dirs) || !r.u8(deep)) break;
            status = manager.scanBegin(dirs, deep != 0);
            break;
        }
        case Op::ScanStep: {
            int32_t maxItems = 0;
            if (!r.i32(maxItems)) break;
            status = manager.scanStep(maxItems);
            break;
        }
        case Op::ScanEnd:
            status = manager.scanEnd();
            break;

        case Op::ScanProgress: {
            const int32_t processed = manager.scanProcessed();
            const int32_t total = manager.scanTotal();
            body.resize(sizeof(int32_t) * 2);
            std::memcpy(body.data(), &processed, sizeof(processed));
            std::memcpy(body.data() + sizeof(int32_t), &total, sizeof(total));
            status = 1;
            break;
        }
        case Op::GetScanCount:
            status = static_cast<int32_t>(manager.getScannedCount());
            break;

        case Op::GetScanItem: {
            uint32_t index = 0;
            if (!r.u32(index)) break;
            const std::string json = manager.getScannedItemJson(index);
            body.assign(json.begin(), json.end());
            status = 1;
            break;
        }
        case Op::GetAllScanned: {
            const std::string json = manager.getAllScannedJson();
            body.assign(json.begin(), json.end());
            status = 1;
            break;
        }

        case Op::Load: {
            uint32_t slot = 0;
            double sampleRate = 48000.0;
            uint32_t maxBlock = 1024;
            std::string path;
            std::string pluginId;
            if (!r.u32(slot) || !r.f64(sampleRate) || !r.u32(maxBlock) ||
                !r.str(path) || !r.str(pluginId)) {
                break;
            }
            RemotePluginInfo info = {};
            if (slot < PluginHostManager::kMaxPluginSlots) {
                /* R-1：经 updateFormat 入口落地格式——它内部 ensureChannelScratch。
                 * 宿主侧 scratch 缺失时 processSlotInterleaved 会在入口静默返回
                 * （不写输出缓冲 → 输入原样回声 → 近似单位增益直通，且
                 * remoteFailed=false、无溢出，故障完全不可观测）。此前此处只手动
                 * 赋值 m_sampleRate/m_maxBlockSize，依赖引擎 create 期转发的
                 * Op::UpdateFormat 分配 scratch；但宿主是懒启动的（首个客户端
                 * 请求才 launch），create 期转发被 alive() 守卫跳过且此后不再补发，
                 * 于是宿主 scratch 永远为零。 */
                manager.updateFormat(sampleRate, maxBlock);
                auto instance = manager.prepareInstance(slot, path, pluginId);
                if (instance) {
                    std::unique_ptr<IPluginInstance> oldInstance;
                    {
                        std::lock_guard<std::recursive_mutex> lock(manager.m_hostMutex);
                        oldInstance = manager.detachInstanceLocked(slot);
                        manager.commitInstanceLocked(slot, std::move(instance));
                    }
                    PluginHostManager::destroyInstance(std::move(oldInstance));
                    if (manager.m_slots[slot].instance) {
                        fillRemoteInfo(manager.m_slots[slot].instance->getMetadata(),
                                       manager.m_slots[slot].instance->busInfo(), info);
                        status = 1;
                    }
                }
            }
            if (status != 1) {
                copyFixed(info.errorMessage, sizeof(info.errorMessage),
                          "plugin load failed in host process");
                status = 0;
            }
            body.resize(sizeof(info));
            std::memcpy(body.data(), &info, sizeof(info));
            break;
        }
        case Op::QueryMetadata: {
            /* 深扫查询（v5）：payload = path，response = u32 count + count × RemotePluginInfo。
             * 失败一律 status=0（不带半成品），引擎侧按格式各自的策略回退。 */
            std::string path;
            if (!r.str(path)) break;
            std::vector<RemotePluginInfo> infos;
            if (queryMetadata(path, infos) && !infos.empty()) {
                const uint32_t count = static_cast<uint32_t>(infos.size());
                const size_t bytes = infos.size() * sizeof(RemotePluginInfo);
                body.resize(sizeof(count) + bytes);
                std::memcpy(body.data(), &count, sizeof(count));
                std::memcpy(body.data() + sizeof(count), infos.data(), bytes);
                status = 1;
            }
            break;
        }
        case Op::Unload: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                manager.unloadPluginSlot(slot);
                status = 1;
            }
            break;
        }
        case Op::SetBypass: {
            uint32_t slot = 0;
            uint8_t bypass = 0;
            if (!r.u32(slot) || !r.u8(bypass)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                manager.setBypassSlot(slot, bypass != 0);
                status = 1;
            }
            break;
        }
        case Op::GetBypass: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                status = manager.isBypassedSlot(slot) ? 1 : 0;
            }
            break;
        }
        case Op::GetLatency: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                status = static_cast<int32_t>(manager.getLatencySlot(slot));
            }
            break;
        }
        case Op::GetStatus: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                const std::string json = manager.getStatusJsonSlot(slot);
                body.assign(json.begin(), json.end());
                status = 1;
            }
            break;
        }
        case Op::ShowEditor: {
            uint32_t slot = 0;
            std::string title;
            if (!r.u32(slot) || !r.str(title)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                status = manager.showEditorSlot(slot, title) ? 1 : 0;
            }
            break;
        }
        case Op::CloseEditor: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                manager.closeEditorSlot(slot);
                status = 1;
            }
            break;
        }
        case Op::IsEditorOpen: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                status = manager.isEditorOpenSlot(slot) ? 1 : 0;
            }
            break;
        }
        case Op::SavePreset: {
            uint32_t slot = 0;
            std::string path;
            if (!r.u32(slot) || !r.str(path)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                status = manager.savePresetSlot(slot, path) ? 1 : 0;
            }
            break;
        }
        case Op::LoadPreset: {
            uint32_t slot = 0;
            std::string path;
            if (!r.u32(slot) || !r.str(path)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                status = manager.loadPresetSlot(slot, path) ? 1 : 0;
            }
            break;
        }
        case Op::SetStage: {
            uint32_t slot = 0;
            int32_t stage = 0;
            if (!r.u32(slot) || !r.i32(stage)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                manager.setInsertStageSlot(slot, stage);
                status = 1;
            }
            break;
        }
        case Op::GetStage: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < PluginHostManager::kMaxPluginSlots) {
                status = manager.getInsertStageSlot(slot);
            }
            break;
        }
        case Op::UpdateFormat: {
            double sampleRate = 48000.0;
            uint32_t maxBlock = 1024;
            if (!r.f64(sampleRate) || !r.u32(maxBlock)) break;
            manager.updateFormat(sampleRate, maxBlock);
            status = 1;
            break;
        }
        case Op::SetChannelHint: {
            uint32_t channels = 2;
            if (!r.u32(channels)) break;
            manager.setChannelHint(static_cast<int>(channels));
            status = 1;
            break;
        }
        case Op::Shutdown:
            status = 1;
            running = false;
            break;

        default:
            status = 0;
            break;
        }
    } catch (...) {
        status = 0;
        body.clear();
    }

    MsgResponse response = {};
    response.magic = kMagic;
    response.version = static_cast<uint16_t>(kProtocolVersion);
    response.status = status;
    response.payloadSize = static_cast<uint32_t>(body.size());
    if (!transport.write(transport.user, &response, sizeof(response))) return false;
    if (!body.empty() &&
        !transport.write(transport.user, body.data(), body.size())) {
        return false;
    }
    return true;
}

} // namespace ipc
} // namespace auradsp
