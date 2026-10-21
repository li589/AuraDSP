#ifndef AURADSP_HOST_INPROC
#define AURADSP_HOST_INPROC 1
#endif

#include "plugin_host.h"
#include "plugin_ipc_protocol.h"
#include "plugin_shared_region.h"
#include "engine_internal.h"

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

extern "C" const char* auradsp_version(void) {
    return AURADSP_VERSION;
}

namespace {

struct HostOptions {
    std::wstring pipeName;
    std::wstring shmName;
    DWORD parentPid = 0;
};

void parseOptions(int argc, wchar_t** argv, HostOptions& out) {
    for (int i = 1; i < argc; ++i) {
        std::wstring arg = argv[i];
        const auto eq = arg.find(L'=');
        if (eq == std::wstring::npos) continue;
        const std::wstring key = arg.substr(0, eq);
        const std::wstring value = arg.substr(eq + 1);
        if (key == L"--pipe") out.pipeName = value;
        else if (key == L"--shm") out.shmName = value;
        else if (key == L"--parent") out.parentPid = static_cast<DWORD>(wcstoul(value.c_str(), nullptr, 10));
    }
}

bool writeAll(HANDLE pipe, const void* data, size_t size) {
    const auto* p = static_cast<const uint8_t*>(data);
    while (size > 0) {
        DWORD written = 0;
        const DWORD chunk = static_cast<DWORD>(size > 0x7fffffffu ? 0x7fffffffu : size);
        if (!WriteFile(pipe, p, chunk, &written, nullptr) || written == 0) return false;
        p += written;
        size -= written;
    }
    return true;
}

bool readAll(HANDLE pipe, void* data, size_t size) {
    auto* p = static_cast<uint8_t*>(data);
    while (size > 0) {
        DWORD got = 0;
        const DWORD chunk = static_cast<DWORD>(size > 0x7fffffffu ? 0x7fffffffu : size);
        if (!ReadFile(pipe, p, chunk, &got, nullptr) || got == 0) return false;
        p += got;
        size -= got;
    }
    return true;
}

void pumpMessages(bool& running) {
    MSG msg = {};
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) {
            running = false;
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

void fillRemoteInfo(const auradsp::PluginMetadata& meta,
                    const auradsp::PluginBusInfo& bus,
                    auradsp::ipc::RemotePluginInfo& info) {
    auradsp::ipc::copyFixed(info.path, sizeof(info.path), meta.path);
    auradsp::ipc::copyFixed(info.id, sizeof(info.id), meta.id);
    auradsp::ipc::copyFixed(info.name, sizeof(info.name), meta.name);
    auradsp::ipc::copyFixed(info.bundleName, sizeof(info.bundleName), meta.bundleName);
    auradsp::ipc::copyFixed(info.vendor, sizeof(info.vendor), meta.vendor);
    auradsp::ipc::copyFixed(info.version, sizeof(info.version), meta.version);
    auradsp::ipc::copyFixed(info.category, sizeof(info.category), meta.category);
    auradsp::ipc::copyFixed(info.description, sizeof(info.description), meta.description);
    auradsp::ipc::copyFixed(info.errorMessage, sizeof(info.errorMessage), meta.errorMessage);
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

bool handleCommand(HANDLE pipe, auradsp::PluginHostManager& manager, bool& running) {
    auradsp::ipc::MsgHeader header = {};
    if (!readAll(pipe, &header, sizeof(header))) return false;
    if (header.magic != auradsp::ipc::kMagic ||
        header.version != static_cast<uint16_t>(auradsp::ipc::kProtocolVersion) ||
        header.payloadSize > auradsp::ipc::kMaxControlPayload) {
        return false;
    }

    std::vector<uint8_t> payload(header.payloadSize);
    if (header.payloadSize > 0 && !readAll(pipe, payload.data(), payload.size())) return false;

    auradsp::ipc::Reader r(payload.data(), payload.size());
    std::vector<uint8_t> body;
    int32_t status = 0;
    const auto op = static_cast<auradsp::ipc::Op>(header.op);

    try {
        switch (op) {
        case auradsp::ipc::Op::Hello:
            body.assign({'A', 'U', 'R', 'A'});
            status = 1;
            break;

        case auradsp::ipc::Op::Ping:
            status = 1;
            break;

        case auradsp::ipc::Op::Scan: {
            std::string dirs;
            uint8_t deep = 0;
            if (!r.str(dirs) || !r.u8(deep)) break;
            status = manager.scanPlugins(dirs, deep != 0);
            break;
        }
        case auradsp::ipc::Op::ScanBegin: {
            std::string dirs;
            uint8_t deep = 0;
            if (!r.str(dirs) || !r.u8(deep)) break;
            status = manager.scanBegin(dirs, deep != 0);
            break;
        }
        case auradsp::ipc::Op::ScanStep: {
            int32_t maxItems = 0;
            if (!r.i32(maxItems)) break;
            status = manager.scanStep(maxItems);
            break;
        }
        case auradsp::ipc::Op::ScanEnd:
            status = manager.scanEnd();
            break;

        case auradsp::ipc::Op::ScanProgress: {
            const int32_t processed = manager.scanProcessed();
            const int32_t total = manager.scanTotal();
            body.resize(sizeof(int32_t) * 2);
            std::memcpy(body.data(), &processed, sizeof(processed));
            std::memcpy(body.data() + sizeof(int32_t), &total, sizeof(total));
            status = 1;
            break;
        }
        case auradsp::ipc::Op::GetScanCount:
            status = static_cast<int32_t>(manager.getScannedCount());
            break;

        case auradsp::ipc::Op::GetScanItem: {
            uint32_t index = 0;
            if (!r.u32(index)) break;
            const std::string json = manager.getScannedItemJson(index);
            body.assign(json.begin(), json.end());
            status = 1;
            break;
        }
        case auradsp::ipc::Op::GetAllScanned: {
            const std::string json = manager.getAllScannedJson();
            body.assign(json.begin(), json.end());
            status = 1;
            break;
        }

        case auradsp::ipc::Op::Load: {
            uint32_t slot = 0;
            double sampleRate = 48000.0;
            uint32_t maxBlock = 1024;
            std::string path;
            std::string pluginId;
            if (!r.u32(slot) || !r.f64(sampleRate) || !r.u32(maxBlock) ||
                !r.str(path) || !r.str(pluginId)) {
                break;
            }
            auradsp::ipc::RemotePluginInfo info = {};
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
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
                    std::unique_ptr<auradsp::IPluginInstance> oldInstance;
                    {
                        std::lock_guard<std::recursive_mutex> lock(manager.m_hostMutex);
                        oldInstance = manager.detachInstanceLocked(slot);
                        manager.commitInstanceLocked(slot, std::move(instance));
                    }
                    auradsp::PluginHostManager::destroyInstance(std::move(oldInstance));
                    if (manager.m_slots[slot].instance) {
                        fillRemoteInfo(manager.m_slots[slot].instance->getMetadata(),
                                       manager.m_slots[slot].instance->busInfo(), info);
                        status = 1;
                    }
                }
            }
            if (status != 1) {
                auradsp::ipc::copyFixed(info.errorMessage, sizeof(info.errorMessage),
                                        "plugin load failed in host process");
                status = 0;
            }
            body.resize(sizeof(info));
            std::memcpy(body.data(), &info, sizeof(info));
            break;
        }
        case auradsp::ipc::Op::Unload: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                manager.unloadPluginSlot(slot);
                status = 1;
            }
            break;
        }
        case auradsp::ipc::Op::SetBypass: {
            uint32_t slot = 0;
            uint8_t bypass = 0;
            if (!r.u32(slot) || !r.u8(bypass)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                manager.setBypassSlot(slot, bypass != 0);
                status = 1;
            }
            break;
        }
        case auradsp::ipc::Op::GetBypass: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                status = manager.isBypassedSlot(slot) ? 1 : 0;
            }
            break;
        }
        case auradsp::ipc::Op::GetLatency: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                status = static_cast<int32_t>(manager.getLatencySlot(slot));
            }
            break;
        }
        case auradsp::ipc::Op::GetStatus: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                const std::string json = manager.getStatusJsonSlot(slot);
                body.assign(json.begin(), json.end());
                status = 1;
            }
            break;
        }
        case auradsp::ipc::Op::ShowEditor: {
            uint32_t slot = 0;
            std::string title;
            if (!r.u32(slot) || !r.str(title)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                status = manager.showEditorSlot(slot, title) ? 1 : 0;
            }
            break;
        }
        case auradsp::ipc::Op::CloseEditor: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                manager.closeEditorSlot(slot);
                status = 1;
            }
            break;
        }
        case auradsp::ipc::Op::IsEditorOpen: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                status = manager.isEditorOpenSlot(slot) ? 1 : 0;
            }
            break;
        }
        case auradsp::ipc::Op::SavePreset: {
            uint32_t slot = 0;
            std::string path;
            if (!r.u32(slot) || !r.str(path)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                status = manager.savePresetSlot(slot, path) ? 1 : 0;
            }
            break;
        }
        case auradsp::ipc::Op::LoadPreset: {
            uint32_t slot = 0;
            std::string path;
            if (!r.u32(slot) || !r.str(path)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                status = manager.loadPresetSlot(slot, path) ? 1 : 0;
            }
            break;
        }
        case auradsp::ipc::Op::SetStage: {
            uint32_t slot = 0;
            int32_t stage = 0;
            if (!r.u32(slot) || !r.i32(stage)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                manager.setInsertStageSlot(slot, stage);
                status = 1;
            }
            break;
        }
        case auradsp::ipc::Op::GetStage: {
            uint32_t slot = 0;
            if (!r.u32(slot)) break;
            if (slot < auradsp::PluginHostManager::kMaxPluginSlots) {
                status = manager.getInsertStageSlot(slot);
            }
            break;
        }
        case auradsp::ipc::Op::UpdateFormat: {
            double sampleRate = 48000.0;
            uint32_t maxBlock = 1024;
            if (!r.f64(sampleRate) || !r.u32(maxBlock)) break;
            manager.updateFormat(sampleRate, maxBlock);
            status = 1;
            break;
        }
        case auradsp::ipc::Op::SetChannelHint: {
            uint32_t channels = 2;
            if (!r.u32(channels)) break;
            manager.setChannelHint(static_cast<int>(channels));
            status = 1;
            break;
        }
        case auradsp::ipc::Op::Shutdown:
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

    auradsp::ipc::MsgResponse response = {};
    response.magic = auradsp::ipc::kMagic;
    response.version = static_cast<uint16_t>(auradsp::ipc::kProtocolVersion);
    response.status = status;
    response.payloadSize = static_cast<uint32_t>(body.size());
    if (!writeAll(pipe, &response, sizeof(response))) return false;
    if (!body.empty() && !writeAll(pipe, body.data(), body.size())) return false;
    return true;
}

} // namespace

int wmain(int argc, wchar_t** argv) {
    HostOptions options;
    parseOptions(argc, argv, options);
    if (options.pipeName.empty() || options.shmName.empty() || options.parentPid == 0) {
        return 1;
    }

    auto region = auradsp::SharedRegion::open(options.shmName);
    if (!region || !region->valid()) return 1;
    auto* shared = region->header();
    if (shared->magic != auradsp::ipc::kMagic ||
        shared->version != auradsp::ipc::kProtocolVersion) {
        return 1;
    }
    shared->hostState.store(static_cast<uint32_t>(auradsp::ipc::HostState::Starting),
                            std::memory_order_release);
    shared->hostPid.store(GetCurrentProcessId(), std::memory_order_release);
    shared->hostStartCount.fetch_add(1, std::memory_order_acq_rel);

    HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, options.parentPid);
    if (!parent) {
        shared->hostState.store(static_cast<uint32_t>(auradsp::ipc::HostState::Failed),
                                std::memory_order_release);
        return 1;
    }

    auradsp::PluginHostManager manager;

    /* F-6: 音频线程唤醒事件（自动重置）。命名派生自 shm（每代宿主 serial
     * 唯一），与 shm 同在 Local\ 命名空间。客户端（代理）在每次成功提交
     * 传输块后 SetEvent；自动重置语义保证信号不丢失——宿主忙时到达的信号
     * 保持挂起，下一次 WaitForSingleObject 立即返回。等待的 2 ms 超时只是
     * 安全网（如代理未能打开事件），不是主机制。 */
    HANDLE wakeEvent = CreateEventW(nullptr, FALSE, FALSE,
                                    (options.shmName + L".wake").c_str());

    HANDLE pipe = CreateNamedPipeW(
        options.pipeName.c_str(),
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, 1024 * 1024, 1024 * 1024, 0, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) {
        CloseHandle(parent);
        shared->hostState.store(static_cast<uint32_t>(auradsp::ipc::HostState::Failed),
                                std::memory_order_release);
        return 1;
    }

    const BOOL connected = ConnectNamedPipe(pipe, nullptr);
    if (!connected && GetLastError() != ERROR_PIPE_CONNECTED) {
        CloseHandle(pipe);
        CloseHandle(parent);
        shared->hostState.store(static_cast<uint32_t>(auradsp::ipc::HostState::Failed),
                                std::memory_order_release);
        return 1;
    }

    shared->hostState.store(static_cast<uint32_t>(auradsp::ipc::HostState::Ready),
                            std::memory_order_release);

    std::atomic<bool> audioRunning{true};
    std::thread audioThread([&]() {
        SetThreadDescription(GetCurrentThread(), L"AuraPluginHostAudio");
        /* F-6: 实时调度。音频线程若可被普通用户态活动抢占，环缓冲会出现
         * 饥饿——代理侧表现为传输块缺失，最坏情况误触发 170 ms 宿主死亡
         * 判定（missStreak 累积至 64 块）。主路径：MMCSS "Pro Audio"
         * （WASAPI/ASIO 客户端同款注册）；兜底：THREAD_PRIORITY_TIME_CRITICAL
         * 基优先级。avrt.dll 动态加载——API 自 Vista 起存在，但宿主不应因
         * 其意外缺失而无法启动。MMCSS 成功时优先级由任务动态提升，此处再设
         * TIME_CRITICAL 只是保底，互不冲突。 */
        HMODULE avrt = LoadLibraryW(L"avrt.dll");
        HANDLE mmcss = nullptr;
        DWORD mmcssIndex = 0;
        if (avrt) {
            using AvSetMmThreadCharacteristicsWFn = HANDLE(WINAPI*)(LPCWSTR, LPDWORD);
            const auto avSet = reinterpret_cast<AvSetMmThreadCharacteristicsWFn>(
                GetProcAddress(avrt, "AvSetMmThreadCharacteristicsW"));
            if (avSet) mmcss = avSet(L"Pro Audio", &mmcssIndex);
        }
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
        while (audioRunning.load(std::memory_order_acquire)) {
            bool worked = false;
            for (size_t slot = 0; slot < auradsp::ipc::kMaxSlots; ++slot) {
                auto& ring = shared->slots[slot];
                const uint32_t read = ring.inputRead.load(std::memory_order_acquire);
                const uint32_t write = ring.inputWrite.load(std::memory_order_acquire);
                if (read == write) continue;

                auto& in = ring.input[read % auradsp::ipc::kRingBlocks];
                uint32_t frames = (std::min)(in.frames, auradsp::ipc::kTransportFrames);
                auradsp::ipc::AudioBlock out = {};
                out.seq = in.seq;
                out.frames = frames;
                out.reserved = in.reserved;
                const uint32_t channels =
                    auradsp::ipc::unpackTransportChannels(in.reserved);
                const uint32_t mask =
                    auradsp::ipc::unpackTransportMask(in.reserved);
                float interleaved[auradsp::ipc::kChannels *
                                  auradsp::ipc::kTransportFrames] = {};
                for (uint32_t ch = 0; ch < channels; ++ch) {
                    for (uint32_t i = 0; i < frames; ++i) {
                        interleaved[i * channels + ch] = in.samples[ch][i];
                    }
                }
                if (frames > 0) {
                    manager.processSlotInterleaved(slot, interleaved, frames,
                                                   channels, mask);
                }
                for (uint32_t ch = 0; ch < channels; ++ch) {
                    for (uint32_t i = 0; i < frames; ++i) {
                        out.samples[ch][i] = interleaved[i * channels + ch];
                    }
                }

                const uint32_t outWrite = ring.outputWrite.load(std::memory_order_relaxed);
                const uint32_t outRead = ring.outputRead.load(std::memory_order_acquire);
                if (outWrite - outRead < auradsp::ipc::kRingBlocks) {
                    ring.output[outWrite % auradsp::ipc::kRingBlocks] = out;
                    ring.outputWrite.store(outWrite + 1, std::memory_order_release);
                    ring.chunksOut.fetch_add(1, std::memory_order_relaxed);
                } else {
                    ring.outputOverflows.fetch_add(1, std::memory_order_relaxed);
                }
                ring.inputRead.store(read + 1, std::memory_order_release);
                worked = true;
            }
            if (!worked) {
                /* F-6: 事件驱动唤醒替代 Sleep(1) 轮询。代理每次成功提交
                 * 传输块即 SetEvent；自动重置 + 信号挂起保持 = 无丢失唤醒
                 * （宿主处理期间到达的信号会释放下一次等待）。2 ms 超时仅
                 * 为安全网；事件创建失败时退化为原轮询路径。 */
                if (wakeEvent) {
                    WaitForSingleObject(wakeEvent, 2);
                } else {
                    Sleep(1);
                }
            }
        }
        if (mmcss && avrt) {
            using AvRevertMmThreadCharacteristicsFn = BOOL(WINAPI*)(HANDLE);
            const auto avRevert = reinterpret_cast<AvRevertMmThreadCharacteristicsFn>(
                GetProcAddress(avrt, "AvRevertMmThreadCharacteristics"));
            if (avRevert) avRevert(mmcss);
        }
        if (avrt) FreeLibrary(avrt);
    });

    bool running = true;
    while (running) {
        HANDLE waits[2] = {pipe, parent};
        const DWORD wait = MsgWaitForMultipleObjectsEx(
            2, waits, 100, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (wait == WAIT_OBJECT_0) {
            if (!handleCommand(pipe, manager, running)) running = false;
        } else if (wait == WAIT_OBJECT_0 + 1) {
            running = false;
        } else if (wait == WAIT_OBJECT_0 + 2 || wait == WAIT_TIMEOUT) {
            pumpMessages(running);
        } else {
            running = false;
        }
        for (size_t slot = 0; slot < auradsp::ipc::kMaxSlots; ++slot) {
            shared->slots[slot].editorOpen.store(
                manager.isEditorOpenSlot(slot) ? 1u : 0u, std::memory_order_release);
        }
    }

    shared->hostState.store(static_cast<uint32_t>(auradsp::ipc::HostState::Stopping),
                            std::memory_order_release);
    audioRunning.store(false, std::memory_order_release);
    if (audioThread.joinable()) audioThread.join();
    /* F-6: 客户端/代理可能仍持有借用副本——内核对象在其全部关闭后才销毁，
     * 期间对旧事件的 SetEvent 无害（无等待者）。 */
    if (wakeEvent) {
        CloseHandle(wakeEvent);
        wakeEvent = nullptr;
    }

    FlushFileBuffers(pipe);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
    CloseHandle(parent);

    region.reset();
    return 0;
}
