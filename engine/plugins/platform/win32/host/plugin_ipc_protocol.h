#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "plugins/plugin_limits.h"

namespace auradsp {
namespace ipc {

constexpr uint32_t kMagic = 0x41555241u;   // "AURA"
/* v5（2026-11-04）：Op::QueryMetadata 响应改为「u32 count + count × RemotePluginInfo」，
 * 深扫不再只服务 32 位 VST2 —— 引擎侧把深扫统一按位数分派给宿主，VST3 一包多插件
 * 也要能一次返回多条。引擎与宿主必须同版本；旧宿主进程会被 Hello 版本检查拒掉并重启。 */
constexpr uint32_t kProtocolVersion = 5u;
/* 单次元数据查询允许返回的最大条目数（防御畸形/恶意响应）。 */
constexpr uint32_t kMaxMetadataBatch = 512u;
/* 槽位数与总线通道上限来自 plugins/plugin_limits.h（唯一定义处）。 */
constexpr uint32_t kMaxSlots = auradsp::limits::kMaxSlots;
constexpr uint32_t kChannels = auradsp::limits::kBusChannels;
constexpr uint32_t kTransportFrames = 128u;
constexpr uint32_t kRingBlocks = 16u;
constexpr uint32_t kMaxScannedPlugins = 65536u;
constexpr size_t kMaxControlPayload = 32u * 1024u * 1024u;

enum class Op : uint32_t {
    Hello = 1,
    Ping = 2,
    /* Scan*（v5 起降级为诊断用途）：引擎侧扫描已改为「本地 enumerate + 快扫，
     * 深扫按候选位数调 QueryMetadata」，不再整轮委托宿主（见
     * docs/20-执行/插件扫描归属重构与崩溃隔离-2026-11-04.md）。宿主仍保留实现。 */
    Scan = 3,
    ScanBegin = 4,
    ScanStep = 5,
    ScanEnd = 6,
    ScanProgress = 7,
    GetScanCount = 8,
    GetScanItem = 9,
    GetAllScanned = 10,
    Load = 11,
    Unload = 12,
    SetBypass = 13,
    GetBypass = 14,
    GetLatency = 15,
    GetStatus = 16,
    ShowEditor = 17,
    CloseEditor = 18,
    IsEditorOpen = 19,
    SavePreset = 20,
    LoadPreset = 21,
    SetStage = 22,
    GetStage = 23,
    UpdateFormat = 24,
    Shutdown = 25,
    SetChannelHint = 26,
    /* 深扫查询（v4 引入，v5 改多条目）：payload = path，response = u32 count +
     * count × RemotePluginInfo。宿主用 driver->queryMetadata 直接产出，不建实例、
     * 不占槽。count 上限 kMaxMetadataBatch。 */
    QueryMetadata = 27,
};

enum class HostState : uint32_t {
    Starting = 0,
    Ready = 1,
    Stopping = 2,
    Failed = 3,
};

struct MsgHeader {
    uint32_t magic;
    uint16_t version;
    uint16_t op;
    uint32_t payloadSize;
    uint32_t requestId;
};

struct MsgResponse {
    uint32_t magic;
    uint16_t version;
    uint16_t reserved;
    int32_t status;
    uint32_t payloadSize;
};

struct AudioBlock {
    uint64_t seq;
    uint32_t frames;
    uint32_t reserved;
    float samples[kChannels][kTransportFrames];
};

constexpr uint32_t packTransportFlags(uint32_t channels, uint32_t mask) {
    return (channels & 0xFFu) | ((mask & 0xFFu) << 8);
}

constexpr uint32_t unpackTransportChannels(uint32_t flags) {
    const uint32_t channels = flags & 0xFFu;
    return channels == 0 ? 2u : (channels > kChannels ? kChannels : channels);
}

constexpr uint32_t unpackTransportMask(uint32_t flags) {
    const uint32_t mask = (flags >> 8) & 0xFFu;
    return mask == 0 ? 0xFFu : mask;
}

struct SlotAudioRing {
    alignas(64) std::atomic<uint32_t> inputWrite{0};
    std::atomic<uint32_t> inputRead{0};
    std::atomic<uint32_t> outputWrite{0};
    std::atomic<uint32_t> outputRead{0};
    std::atomic<uint64_t> inputOverflows{0};
    std::atomic<uint64_t> outputOverflows{0};
    std::atomic<uint64_t> chunksIn{0};
    std::atomic<uint64_t> chunksOut{0};
    std::atomic<uint32_t> editorOpen{0};
    alignas(64) AudioBlock input[kRingBlocks];
    alignas(64) AudioBlock output[kRingBlocks];
};

struct SharedAudio {
    uint32_t magic = kMagic;
    uint32_t version = kProtocolVersion;
    uint32_t maxSlots = kMaxSlots;
    uint32_t transportFrames = kTransportFrames;
    std::atomic<uint32_t> hostState{static_cast<uint32_t>(HostState::Starting)};
    std::atomic<uint32_t> hostPid{0};
    std::atomic<uint64_t> hostStartCount{0};
    SlotAudioRing slots[kMaxSlots];
};

static_assert(std::atomic<uint32_t>::is_always_lock_free, "IPC requires lock-free uint32 atomics");
static_assert(std::atomic<uint64_t>::is_always_lock_free, "IPC requires lock-free uint64 atomics");

struct RemotePluginInfo {
    char path[1024] = {};
    char id[256] = {};
    char name[256] = {};
    char bundleName[256] = {};
    char vendor[256] = {};
    char version[64] = {};
    char category[256] = {};
    char description[512] = {};
    char errorMessage[512] = {};
    uint32_t format = 0;
    uint32_t latency = 0;
    uint32_t is64Bit = 1;
    uint32_t isCompatible = 1;
    uint32_t inputBuses = 0;
    uint32_t outputBuses = 0;
    uint32_t auxInputBuses = 0;
    uint32_t auxOutputBuses = 0;
    uint32_t mainInChannels = 0;
    uint32_t mainOutChannels = 0;
};

inline void copyFixed(char* dst, size_t cap, const std::string& src) {
    if (!dst || cap == 0) return;
    const size_t n = src.size() < cap - 1 ? src.size() : cap - 1;
    if (n) std::memcpy(dst, src.data(), n);
    dst[n] = '\0';
}

class Writer {
public:
    void u8(uint8_t v) { m_data.push_back(v); }
    void u32(uint32_t v) { raw(&v, sizeof(v)); }
    void i32(int32_t v) { raw(&v, sizeof(v)); }
    void u64(uint64_t v) { raw(&v, sizeof(v)); }
    void f64(double v) { raw(&v, sizeof(v)); }
    void str(const std::string& v) {
        u32(static_cast<uint32_t>(v.size()));
        if (!v.empty()) raw(v.data(), v.size());
    }
    void bytes(const void* p, size_t n) { raw(p, n); }

    const std::vector<uint8_t>& data() const { return m_data; }
    std::vector<uint8_t>& data() { return m_data; }

private:
    void raw(const void* p, size_t n) {
        const auto* b = static_cast<const uint8_t*>(p);
        m_data.insert(m_data.end(), b, b + n);
    }

    std::vector<uint8_t> m_data;
};

class Reader {
public:
    Reader(const void* data, size_t size)
        : m_data(static_cast<const uint8_t*>(data)), m_size(size) {}

    bool ok() const { return m_ok; }

    bool u8(uint8_t& v) { return raw(&v, sizeof(v)); }
    bool u32(uint32_t& v) { return raw(&v, sizeof(v)); }
    bool i32(int32_t& v) { return raw(&v, sizeof(v)); }
    bool u64(uint64_t& v) { return raw(&v, sizeof(v)); }
    bool f64(double& v) { return raw(&v, sizeof(v)); }
    bool str(std::string& v, uint32_t maxLen = kMaxControlPayload) {
        uint32_t n = 0;
        if (!u32(n) || n > maxLen || n > m_size - m_off) {
            m_ok = false;
            return false;
        }
        v.assign(reinterpret_cast<const char*>(m_data + m_off), n);
        m_off += n;
        return true;
    }
    bool bytes(void* out, size_t n) { return raw(out, n); }

private:
    bool raw(void* out, size_t n) {
        if (!m_ok || n > m_size - m_off) {
            m_ok = false;
            return false;
        }
        std::memcpy(out, m_data + m_off, n);
        m_off += n;
        return true;
    }

    const uint8_t* m_data = nullptr;
    size_t m_size = 0;
    size_t m_off = 0;
    bool m_ok = true;
};

} // namespace ipc
} // namespace auradsp
