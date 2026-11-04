/*
 * vst2_instance.cpp — VST2 插件实例（2026-11-03）。
 *
 * 设计约束（与 VST3/CLAP 同构）：
 *   - 生命周期/dispatcher/编辑器调用走按模块共享的 ModulePumpThread；
 *   - processReplacing 直接在音频线程调用，不排队；
 *   - audioMaster 回调只读原子/常量，不加锁、不分配、不做 IO；
 *   - 卸载超时走 abandoned 隔离区，绝不强释放可能仍被插件线程引用的模块。
 *
 * 编译头：vendor/plugin-api/vst2/vst.h（Xaymar 净室，BSD-3-Clause）。
 * 注意该头的 vst_host_callback_t 在 32 位下把 value 声明成 int64_t，
 * 本文件的 hostCallback 必须用 intptr_t 自定义签名（ADR-013 D-1a）。
 */

#include "vst2_instance.h"

// Windows 的 min/max 宏会破坏 std::min/std::max；host 目标没有强制 shim，
// 必须在本 TU 内先关掉。
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "debug_log.h"
#include "module_pump.h"
#include "platform/port/module.h"
#include "plugin_metadata_util.h"
#include "win32_util.h"

#include "vst2/vst.h"

#if defined(_WIN32)
#include <windows.h>
#endif  // 非 Windows：Win32 类型/惰性 API 由 platform/posix 兼容层提供

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

namespace auradsp {
namespace {

namespace fs = std::filesystem;

#pragma pack(push, 8)
struct Vst2TimeInfo {
    double samplePos;
    double sampleRate;
    double nanoSeconds;
    double ppqPos;
    double tempo;
    double barStartPos;
    double cycleStartPos;
    double cycleEndPos;
    int32_t timeSigNumerator;
    int32_t timeSigDenominator;
    int32_t smpteOffset;
    int32_t smpteFrameRate;
    int32_t samplesToNextClock;
    int32_t flags;
};
#pragma pack(pop)

enum Vst2TimeInfoFlags {
    kVstTransportChanged     = 1,
    kVstTransportPlaying     = 1 << 1,
    kVstTransportCycleActive = 1 << 2,
    kVstTransportRecording   = 1 << 3,
    kVstAutomationWriting    = 1 << 6,
    kVstAutomationReading    = 1 << 7,
    kVstNanosValid           = 1 << 8,
    kVstPpqPosValid          = 1 << 9,
    kVstTempoValid           = 1 << 10,
    kVstBarsValid            = 1 << 11,
    kVstCyclePosValid        = 1 << 12,
    kVstTimeSigValid         = 1 << 13,
    kVstSmpteValid           = 1 << 14,
    kVstClockValid           = 1 << 15
};

using VstPluginMainProc = vst_effect_t*(VST_FUNCTION_INTERFACE*)(vst_host_callback_t);

class Vst2Instance;

/* VSTPluginMain 构造期间 AEffect 尚不存在，回调里的 effect 可能为空；
 * 此时用 thread_local 和全局原子后备指向正在构造的实例，兼顾主线程与后台工作线程。 */
thread_local Vst2Instance* g_constructing = nullptr;
static std::atomic<Vst2Instance*> s_latestConstructing{nullptr};

#if defined(_MSC_VER)
static vst_effect_t* safeCallMainProc(VstPluginMainProc proc, vst_host_callback_t cb) {
    __try {
        return proc(cb);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        AURADSP_WARN("[DBG VST2] VSTPluginMain triggered SEH exception!");
        return nullptr;
    }
}

static intptr_t safeCallDispatcher(vst_effect_t* effect, int32_t opcode, int32_t index,
                                   intptr_t value, void* ptr, float opt) {
    __try {
        if (!effect || !effect->control) return 0;
        return effect->control(effect, opcode, index, value, ptr, opt);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        AURADSP_WARN_S("[DBG VST2] dispatcher triggered SEH exception on opcode " << opcode);
        return 0;
    }
}

static void safeCallProcessFloat(vst_effect_process_float_t proc, vst_effect_t* effect,
                                 const float* const* inputs, float** outputs, int32_t frames) {
    __try {
        proc(effect, inputs, outputs, frames);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        AURADSP_WARN("[DBG VST2] processFloat triggered SEH exception!");
    }
}

static void safeCallProcess(vst_effect_process_t proc, vst_effect_t* effect,
                            const float* const* inputs, float** outputs, int32_t frames) {
    __try {
        proc(effect, inputs, outputs, frames);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        AURADSP_WARN("[DBG VST2] process triggered SEH exception!");
    }
}

static float safeCallGetParameter(vst_effect_get_parameter_t proc, vst_effect_t* effect,
                                  uint32_t index) {
    __try {
        return proc(effect, index);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0.0f;
    }
}

static void safeCallSetParameter(vst_effect_set_parameter_t proc, vst_effect_t* effect,
                                 uint32_t index, float value) {
    __try {
        proc(effect, index, value);
    } __except (EXCEPTION_EXECUTE_HANDLER) {}
}
#else
static vst_effect_t* safeCallMainProc(VstPluginMainProc proc, vst_host_callback_t cb) {
    try {
        return proc(cb);
    } catch (...) {
        return nullptr;
    }
}

static intptr_t safeCallDispatcher(vst_effect_t* effect, int32_t opcode, int32_t index,
                                   intptr_t value, void* ptr, float opt) {
    try {
        if (!effect || !effect->control) return 0;
        return effect->control(effect, opcode, index, value, ptr, opt);
    } catch (...) {
        return 0;
    }
}

static void safeCallProcessFloat(vst_effect_process_float_t proc, vst_effect_t* effect,
                                 const float* const* inputs, float** outputs, int32_t frames) {
    try {
        proc(effect, inputs, outputs, frames);
    } catch (...) {}
}

static void safeCallProcess(vst_effect_process_t proc, vst_effect_t* effect,
                            const float* const* inputs, float** outputs, int32_t frames) {
    try {
        proc(effect, inputs, outputs, frames);
    } catch (...) {}
}

static float safeCallGetParameter(vst_effect_get_parameter_t proc, vst_effect_t* effect,
                                  uint32_t index) {
    try {
        return proc(effect, index);
    } catch (...) {
        return 0.0f;
    }
}

static void safeCallSetParameter(vst_effect_set_parameter_t proc, vst_effect_t* effect,
                                 uint32_t index, float value) {
    try {
        proc(effect, index, value);
    } catch (...) {}
}
#endif

void copyHostString(void* dst, intptr_t capHint, const char* src) {
    if (!dst) return;
    char* out = static_cast<char*>(dst);
    if (!src || !*src) {
        out[0] = '\0';
        return;
    }
    size_t cap = (capHint > 0) ? static_cast<size_t>(capHint) : 64;
    if (cap > 256) cap = 256;
    size_t len = std::strlen(src);
    if (len >= cap) len = cap - 1;
    std::memcpy(out, src, len);
    out[len] = '\0';
}

std::string trimTrailingZeros(const std::string& s) {
    std::string out = s;
    while (!out.empty() && out.back() == '0') out.pop_back();
    while (!out.empty() && out.back() == '.') out.pop_back();
    return out.empty() ? "0" : out;
}

std::string formatVst2Version(int32_t v) {
    if (v <= 0) return {};
    if (v < 1000) return std::to_string(v);
    const int major = v / 1000;
    const int minor = (v % 1000) / 100;
    const int patch = (v % 100) / 10;
    const int build = v % 10;
    char buf[64] = {};
    std::snprintf(buf, sizeof(buf), "%d.%d.%d.%d", major, minor, patch, build);
    return trimTrailingZeros(buf);
}

const char* categoryName(int32_t category) {
    switch (category) {
        case VST_EFFECT_CATEGORY_EFFECT: return "AudioEffect";
        case VST_EFFECT_CATEGORY_INSTRUMENT: return "Instrument";
        case VST_EFFECT_CATEGORY_METERING: return "Analyzer";
        case VST_EFFECT_CATEGORY_MASTERING: return "Mastering";
        case VST_EFFECT_CATEGORY_SPATIAL: return "Spatial";
        case VST_EFFECT_CATEGORY_DELAY_OR_ECHO: return "Delay";
        default: return "AudioEffect";
    }
}

constexpr char kAur2Magic[4] = {'A', 'U', 'R', '2'};
constexpr uint32_t kAur2Version = 1;
constexpr uint32_t kAur2KindChunk = 0;
constexpr uint32_t kAur2KindParams = 1;

struct Aur2Header {
    char magic[4];
    uint32_t version;
    uint32_t kind;
    uint32_t uniqueId;
    uint32_t payloadSize;
};
static_assert(sizeof(Aur2Header) == 20, "AUR2 header must stay 20 bytes");

class Vst2Instance final : public IPluginInstance {
public:
    Vst2Instance() = default;

    ~Vst2Instance() override { unload(); }

    bool load(const std::string& path, const std::string& pluginId,
              const PluginMetadata* scanSeed = nullptr) override {
        unload();

        m_meta = PluginMetadata{};
        /* 快扫种子是文件头启发式，不进加载路；深扫种子维持 B1「种子为准」。
         * （VST2 的 fillMetadataFromEffect 本就直接赋值覆盖，此处一致化。） */
        if (scanSeed && !scanSeed->fromQuickScan) seedMetadataFromScan(m_meta, *scanSeed);
        m_meta.path = path;
        m_meta.format = PluginFormat::VST2;
        m_meta.bundleName = fs::path(path).stem().string();
        m_pluginDir = fs::path(path).parent_path().string();
        m_editorTitle.clear();
        m_busInfo = PluginBusInfo{};

        std::error_code ec;
        if (path.empty() || fs::is_directory(path, ec)) {
            return fail("Invalid VST2 path");
        }
        if (!fs::is_regular_file(path, ec)) {
            return fail("VST2 file not found");
        }

        setupPluginDllDirectories(path);

        const std::wstring wpath = utf8ToWide(path);
        const int hostBits = (sizeof(void*) == 8) ? 64 : 32;
        const int binBits = pluginBinaryBitness(wpath);
        m_meta.is64Bit = (binBits != 32);
        if (binBits != 0 && binBits != hostBits) {
            releasePluginDllDirectories(path);
            return fail(hostBits == 64
                            ? "32 位插件无法在 64 位宿主加载：请使用 32 位位桥宿主"
                            : "64 位插件无法在 32 位位桥宿主加载");
        }
        if (!peHasVst2Entry(wpath)) {
            releasePluginDllDirectories(path);
            return fail("Not a VST2 plugin (missing VSTPluginMain/main export)");
        }

        m_module = platform::module_open_utf8(path.c_str());
        if (!m_module) {
            releasePluginDllDirectories(path);
            return fail("Failed to load VST2 DLL: " +
                        std::string(platform::module_last_error_text()));
        }

        auto mainProc = reinterpret_cast<VstPluginMainProc>(
            platform::module_symbol(m_module, "VSTPluginMain"));
        if (!mainProc) {
            mainProc = reinterpret_cast<VstPluginMainProc>(
                platform::module_symbol(m_module, "main"));
        }
        if (!mainProc) {
            platform::module_close(m_module);
            m_module = nullptr;
            releasePluginDllDirectories(path);
            return fail("Missing VSTPluginMain/main export in VST2 binary");
        }

        m_moduleKey = normalizeModuleKey(wpath);
        m_pump = ModulePumpThread::acquire(m_moduleKey);
        if (!m_pump || !m_pump->isReady()) {
            m_pump.reset();
            platform::module_close(m_module);
            m_module = nullptr;
            releasePluginDllDirectories(path);
            return fail("VST2 main thread failed to start");
        }

        bool ok = false;
        const bool ran = m_pump->postTaskAndWait(
            [&]() {
                g_constructing = this;
                s_latestConstructing.store(this, std::memory_order_release);
                vst_effect_t* effect = safeCallMainProc(
                    mainProc, reinterpret_cast<vst_host_callback_t>(&Vst2Instance::hostCallback));
                g_constructing = nullptr;
                s_latestConstructing.store(nullptr, std::memory_order_release);

                if (!effect || effect->magic_number != static_cast<int32_t>(VST_MAGICNUMBER) ||
                    !effect->control) {
                    m_meta.isCompatible = false;
                    m_meta.errorMessage = "Invalid VST2 AEffect (magic mismatch)";
                    return;
                }

                m_effect = effect;
                effect->_unknown_00 = this;

                dispatch(VST_EFFECT_OPCODE_CREATE);
                dispatch(VST_EFFECT_OPCODE_SET_SAMPLE_RATE, 0, 0, nullptr,
                         static_cast<float>(m_sampleRate));
                dispatch(VST_EFFECT_OPCODE_SET_BLOCK_SIZE, 0,
                         static_cast<intptr_t>(m_maxBlockSize));

                fillMetadataFromEffect();
                if (!m_meta.isCompatible) return;
                ok = true;
            },
            5000);

        if (!ran) {
            m_threadAbandoned.store(true, std::memory_order_release);
            AURADSP_WARN("[DBG VST2] load task timed out; abandoning instance");
            return false;
        }
        if (!ok) {
            cleanupAfterFailedLoad();
            return false;
        }

        if (!pluginId.empty() && !m_meta.id.empty() && pluginId != m_meta.id) {
            cleanupAfterFailedLoad();
            return fail("VST2 plugin id mismatch");
        }

        m_loaded.store(true, std::memory_order_release);
        return true;
    }

    void unload() override {
        closeEditor();

        if (m_effect && m_pump && m_pump->isReady() &&
            !m_threadAbandoned.load(std::memory_order_acquire)) {
            const bool done = m_pump->postTaskAndWait(
                [this]() {
                    if (!m_effect) return;
                    dispatch(VST_EFFECT_OPCODE_PROCESS_END);
                    dispatch(VST_EFFECT_OPCODE_SUSPEND_RESUME, 0, 0);
                    dispatch(VST_EFFECT_OPCODE_DESTROY);
                    m_effect = nullptr;
                },
                3000);
            if (!done) {
                m_threadAbandoned.store(true, std::memory_order_release);
                AURADSP_WARN("[DBG VST2] unload task timed out; leaking module (quarantine)");
            }
        }

        m_active.store(false, std::memory_order_release);
        m_loaded.store(false, std::memory_order_release);

        if (!m_threadAbandoned.load(std::memory_order_acquire)) {
            if (m_module) {
                platform::module_close(m_module);
                m_module = nullptr;
            }
            m_effect = nullptr;
            m_pump.reset();
        } else {
            // 挂死线程仍可能引用 module/effect；只断开本实例的引用，不释放。
            m_effect = nullptr;
            m_pump.reset();
            m_module = nullptr;
        }

        releasePluginDllDirectories(m_meta.path);
    }

    bool activate(double sampleRate, uint32_t maxBlockSize) override {
        if (!m_loaded.load(std::memory_order_acquire) || !m_effect) return false;
        if (m_threadAbandoned.load(std::memory_order_acquire)) return false;

        m_sampleRate = sampleRate;
        m_maxBlockSize = maxBlockSize > 0 ? maxBlockSize : 1024;
        ensureScratch(m_maxBlockSize);

        bool ok = false;
        const bool ran = m_pump && m_pump->isReady() &&
                         m_pump->postTaskAndWait(
                             [&]() {
                                 dispatch(VST_EFFECT_OPCODE_SET_SAMPLE_RATE, 0, 0, nullptr,
                                          static_cast<float>(m_sampleRate));
                                 dispatch(VST_EFFECT_OPCODE_SET_BLOCK_SIZE, 0,
                                          static_cast<intptr_t>(m_maxBlockSize));
                                 dispatch(VST_EFFECT_OPCODE_SUSPEND_RESUME, 0, 1);
                                 dispatch(VST_EFFECT_OPCODE_PROCESS_BEGIN);
                                 m_latency.store(
                                     m_effect && m_effect->delay > 0
                                         ? static_cast<uint32_t>(m_effect->delay)
                                         : 0u,
                                     std::memory_order_release);
                                 ok = true;
                             },
                             5000);
        if (!ran || !ok) {
            m_threadAbandoned.store(true, std::memory_order_release);
            return false;
        }

        m_active.store(true, std::memory_order_release);
        return true;
    }

    void deactivate() override {
        if (m_loaded.load(std::memory_order_acquire) && m_effect && m_pump &&
            m_pump->isReady() && !m_threadAbandoned.load(std::memory_order_acquire)) {
            const bool done = m_pump->postTaskAndWait(
                [this]() {
                    dispatch(VST_EFFECT_OPCODE_PROCESS_END);
                    dispatch(VST_EFFECT_OPCODE_SUSPEND_RESUME, 0, 0);
                },
                3000);
            if (!done) m_threadAbandoned.store(true, std::memory_order_release);
        }
        m_active.store(false, std::memory_order_release);
    }

    void process(float* const* inChannels, float* const* outChannels,
                 uint32_t numFrames) override {
        if (numFrames == 0 || !outChannels || !outChannels[0]) return;

        const int chHint = std::max(1, std::min(8, m_channelHint.load(std::memory_order_relaxed)));
        if (!m_active.load(std::memory_order_acquire) ||
            m_bypassed.load(std::memory_order_acquire) || !m_effect) {
            copyThrough(inChannels, outChannels, numFrames, chHint);
            return;
        }

        const int inCh = std::max(0, std::min(8, m_busIn.load(std::memory_order_relaxed)));
        const int pluginOutCh = std::max(0, std::min(8, m_busOut.load(std::memory_order_relaxed)));
        const int outCh = std::min(pluginOutCh, chHint);
        if (outCh <= 0 || (!m_effect->process_float && !m_effect->process)) {
            copyThrough(inChannels, outChannels, numFrames, chHint);
            return;
        }

        float* inputs[8] = {};
        float* outputs[8] = {};
        for (int i = 0; i < inCh; ++i) {
            // 引擎是单声道而插件要双输入时，把 ch0 复制给 ch1，避免插件读空指针。
            const int src = std::min(i, chHint - 1);
            inputs[i] = (inChannels && inChannels[src]) ? inChannels[src]
                                                        : (inChannels ? inChannels[0] : nullptr);
        }
        for (int i = 0; i < outCh; ++i) {
            outputs[i] = outChannels[i];
        }

        // 单声道输出：先处理到 scratch，再复制到所有输出声道，避免插件只写
        // outputs[0] 时右声道保留未处理的原声。
        const bool monoOut = (outCh == 1);
        float* monoScratch = nullptr;
        if (monoOut) {
            if (m_monoScratch.size() < numFrames) {
                copyThrough(inChannels, outChannels, numFrames, chHint);
                return;
            }
            monoScratch = m_monoScratch.data();
            outputs[0] = monoScratch;
        }

        m_inProcess.store(true, std::memory_order_release);
        if (m_effect->process_float) {
            safeCallProcessFloat(m_effect->process_float, m_effect, inputs, outputs,
                                 static_cast<int32_t>(numFrames));
        } else if (m_effect->process) {
            // 旧式 process 是累加模式：先清零输出，再调用。
            for (int i = 0; i < outCh; ++i) {
                if (outputs[i]) std::memset(outputs[i], 0, numFrames * sizeof(float));
            }
            safeCallProcess(m_effect->process, m_effect, inputs, outputs,
                            static_cast<int32_t>(numFrames));
        }
        m_inProcess.store(false, std::memory_order_release);

        if (monoOut) {
            for (int c = 0; c < chHint; ++c) {
                if (outChannels[c]) {
                    std::memcpy(outChannels[c], monoScratch, numFrames * sizeof(float));
                }
            }
        }
    }

    bool isLoaded() const override { return m_loaded.load(std::memory_order_acquire); }
    bool isBypassed() const override { return m_bypassed.load(std::memory_order_acquire); }
    void setBypass(bool bypass) override {
        m_bypassed.store(bypass, std::memory_order_release);
    }
    uint32_t getLatency() const override { return m_latency.load(std::memory_order_acquire); }
    const PluginMetadata& getMetadata() const override { return m_meta; }
    PluginBusInfo busInfo() const override { return m_busInfo; }
    void setChannelHint(int channels) override {
        if (channels < 1) channels = 1;
        if (channels > 8) channels = 8;
        m_channelHint.store(channels, std::memory_order_relaxed);
    }
    bool abandoned() const override {
        return m_threadAbandoned.load(std::memory_order_acquire);
    }

    bool showEditor(const std::string& title = "") override {
        if (!m_loaded.load(std::memory_order_acquire) || !m_effect) return false;
        if (m_threadAbandoned.load(std::memory_order_acquire)) return false;
        if (!(m_effect->flags & VST_EFFECT_FLAG_EDITOR)) return false;

        m_editorTitle = title;
        setupPluginDllDirectories(m_meta.path);
        if (m_editorOpen.load(std::memory_order_acquire) && m_editorHwnd &&
            IsWindow(m_editorHwnd)) {
            ShowWindow(m_editorHwnd, SW_SHOW);
            FlashEditorToFront(m_editorHwnd);
            return true;
        }
        if (!m_pump || !m_pump->isReady()) return false;

        bool ok = false;
        const bool done = m_pump->postTaskAndWait([&]() { ok = showEditorOnPumpThread(); }, 8000);
        if (!done) {
            m_threadAbandoned.store(true, std::memory_order_release);
            return false;
        }
        return ok;
    }

    void closeEditor() override {
        if (!m_editorOpen.load(std::memory_order_acquire) && !m_editorHwnd) return;
        if (m_pump && m_pump->isReady()) {
            const bool done =
                m_pump->postTaskAndWait([this]() { closeEditorOnPumpThread(); }, 3000);
            if (!done) m_threadAbandoned.store(true, std::memory_order_release);
        } else {
            m_editorHwnd = nullptr;
            m_editorOpen.store(false, std::memory_order_release);
        }
    }

    bool isEditorOpen() const override {
        return m_editorOpen.load(std::memory_order_acquire) && m_editorHwnd &&
               IsWindow(m_editorHwnd);
    }

    void onEditorIdle() override {
        if (!m_effect || !m_editorOpen.load(std::memory_order_acquire)) return;
        dispatch(VST_EFFECT_OPCODE_EDITOR_KEEP_ALIVE);
    }

    void onEditorWmClose() override { closeEditorOnPumpThread(); }

    bool savePreset(const std::string& filePath) override {
        if (!m_loaded.load(std::memory_order_acquire) || !m_effect) return false;
        if (!m_pump || !m_pump->isReady()) return false;

        std::vector<uint8_t> payload;
        uint32_t kind = kAur2KindChunk;
        const bool got = m_pump->postTaskAndWait(
            [&]() {
                if (!m_effect) return;
                void* chunk = nullptr;
                intptr_t size = dispatch(VST_EFFECT_OPCODE_GET_CHUNK_DATA, 1, 0, &chunk);
                if (size <= 0 || !chunk) {
                    size = dispatch(VST_EFFECT_OPCODE_GET_CHUNK_DATA, 0, 0, &chunk);
                }
                if (size > 0 && chunk) {
                    payload.assign(static_cast<uint8_t*>(chunk),
                                   static_cast<uint8_t*>(chunk) + size);
                    kind = kAur2KindChunk;
                    return;
                }
                // 无 chunk 插件：退化为参数数组。
                kind = kAur2KindParams;
                int32_t count = m_effect->num_params;
                if (count < 0) count = 0;
                if (count > 4096) count = 4096;
                payload.resize(sizeof(uint32_t) + sizeof(float) * static_cast<size_t>(count));
                std::memcpy(payload.data(), &count, sizeof(count));
                for (int32_t i = 0; i < count; ++i) {
                    const float v = m_effect->get_parameter
                                        ? safeCallGetParameter(m_effect->get_parameter, m_effect,
                                                               static_cast<uint32_t>(i))
                                        : 0.0f;
                    std::memcpy(payload.data() + sizeof(uint32_t) + sizeof(float) * i, &v,
                                sizeof(v));
                }
            },
            3000);
        if (!got || payload.empty()) return false;

        fs::path p(filePath);
        std::error_code ec;
        if (p.has_parent_path() && !fs::exists(p.parent_path(), ec)) {
            fs::create_directories(p.parent_path(), ec);
        }

        Aur2Header header{};
        std::memcpy(header.magic, kAur2Magic, sizeof(header.magic));
        header.version = kAur2Version;
        header.kind = kind;
        header.uniqueId = m_effect ? static_cast<uint32_t>(m_effect->unique_id) : 0u;
        header.payloadSize = static_cast<uint32_t>(payload.size());

        std::ofstream ofs(filePath, std::ios::binary);
        if (!ofs) return false;
        ofs.write(reinterpret_cast<const char*>(&header), sizeof(header));
        ofs.write(reinterpret_cast<const char*>(payload.data()),
                  static_cast<std::streamsize>(payload.size()));
        return ofs.good();
    }

    bool loadPreset(const std::string& filePath) override {
        if (!m_loaded.load(std::memory_order_acquire) || !m_effect) return false;
        if (!m_pump || !m_pump->isReady()) return false;

        std::ifstream ifs(filePath, std::ios::binary);
        if (!ifs) return false;
        ifs.seekg(0, std::ios::end);
        const std::streamoff end = ifs.tellg();
        if (end <= 0 || end > 64LL * 1024 * 1024) return false;
        ifs.seekg(0, std::ios::beg);
        std::vector<uint8_t> file(static_cast<size_t>(end));
        ifs.read(reinterpret_cast<char*>(file.data()),
                 static_cast<std::streamsize>(file.size()));
        if (!ifs) return false;

        uint32_t kind = kAur2KindChunk;
        const uint8_t* payload = nullptr;
        size_t payloadSize = 0;

        if (file.size() >= sizeof(Aur2Header) &&
            std::memcmp(file.data(), kAur2Magic, 4) == 0) {
            Aur2Header header{};
            std::memcpy(&header, file.data(), sizeof(header));
            if (header.version > kAur2Version) return false;
            if (header.payloadSize > file.size() - sizeof(header)) return false;
            kind = header.kind;
            payload = file.data() + sizeof(header);
            payloadSize = header.payloadSize;
        } else if (file.size() > 20 && std::memcmp(file.data(), "CcnK", 4) == 0) {
            // 标准 .fxp：'CcnK' + size + fxID + fxVersion + numParams + chunk
            uint32_t chunkSize = 0;
            std::memcpy(&chunkSize, file.data() + 4, sizeof(chunkSize));
            if (chunkSize == 0 || chunkSize > file.size() - 20) return false;
            kind = kAur2KindChunk;
            payload = file.data() + 20;
            payloadSize = chunkSize;
        } else {
            return false;
        }

        bool ok = false;
        const bool ran = m_pump->postTaskAndWait(
            [&]() {
                if (!m_effect) return;
                if (kind == kAur2KindChunk) {
                    if (payloadSize == 0 || payloadSize > 0x7FFFFFFF) return;
                    ok = dispatch(VST_EFFECT_OPCODE_SET_CHUNK_DATA, 1,
                                  static_cast<intptr_t>(payloadSize),
                                  const_cast<uint8_t*>(payload)) != 0;
                    if (!ok) {
                        ok = dispatch(VST_EFFECT_OPCODE_SET_CHUNK_DATA, 0,
                                      static_cast<intptr_t>(payloadSize),
                                      const_cast<uint8_t*>(payload)) != 0;
                    }
                } else if (payloadSize >= sizeof(uint32_t) && m_effect->set_parameter) {
                    uint32_t count = 0;
                    std::memcpy(&count, payload, sizeof(count));
                    const size_t maxCount =
                        (payloadSize - sizeof(uint32_t)) / sizeof(float);
                    count = std::min<uint32_t>(count, static_cast<uint32_t>(maxCount));
                    for (uint32_t i = 0; i < count; ++i) {
                        float v = 0.0f;
                        std::memcpy(&v, payload + sizeof(uint32_t) + sizeof(float) * i,
                                    sizeof(v));
                        safeCallSetParameter(m_effect->set_parameter, m_effect, i, v);
                    }
                    ok = true;
                }
            },
            3000);
        if (!ran) {
            m_threadAbandoned.store(true, std::memory_order_release);
            return false;
        }
        return ok;
    }

    void onEditorResize() override {
        // VST2 编辑器普遍固定尺寸；容器窗口用不可缩放样式，这里不做拉伸，
        // 避免把插件子窗口强行铺满导致控件错位。
    }

private:
    bool fail(const std::string& message) {
        m_meta.isCompatible = false;
        m_meta.errorMessage = message;
        m_loaded.store(false, std::memory_order_release);
        return false;
    }

    void cleanupAfterFailedLoad() {
        if (m_effect && m_pump && m_pump->isReady() &&
            !m_threadAbandoned.load(std::memory_order_acquire)) {
            const bool done = m_pump->postTaskAndWait(
                [this]() {
                    if (m_effect) {
                        dispatch(VST_EFFECT_OPCODE_DESTROY);
                        m_effect = nullptr;
                    }
                },
                2000);
            if (!done) {
                // effClose 挂死：线程仍引用模块，绝不能 FreeLibrary。
                m_threadAbandoned.store(true, std::memory_order_release);
            }
        }
        if (!m_threadAbandoned.load(std::memory_order_acquire)) {
            if (m_module) platform::module_close(m_module);
            m_module = nullptr;
            m_pump.reset();
        }
        releasePluginDllDirectories(m_meta.path);
    }

    intptr_t dispatch(int32_t opcode, int32_t index = 0, intptr_t value = 0,
                      void* ptr = nullptr, float opt = 0.0f) {
        if (!m_effect || !m_effect->control) return 0;
        return safeCallDispatcher(m_effect, opcode, index, value, ptr, opt);
    }

    void ensureScratch(uint32_t frames) {
        if (frames == 0) frames = 1;
        if (m_monoScratch.size() < frames) m_monoScratch.resize(frames, 0.0f);
    }

    void copyThrough(float* const* inChannels, float* const* outChannels,
                     uint32_t numFrames, int channels) const {
        if (!outChannels) return;
        const float* monoIn = (inChannels && inChannels[0]) ? inChannels[0] : nullptr;
        for (int c = 0; c < channels; ++c) {
            if (!outChannels[c]) continue;
            const float* src = (inChannels && inChannels[c]) ? inChannels[c] : monoIn;
            if (src) {
                std::memcpy(outChannels[c], src, numFrames * sizeof(float));
            } else {
                std::memset(outChannels[c], 0, numFrames * sizeof(float));
            }
        }
    }

    bool readEffectString(int32_t opcode, std::string& out) {
        if (!m_effect) return false;
        char buf[512] = {};
        const intptr_t r = dispatch(opcode, 0, 0, buf);
        if (r == 0 && buf[0] == '\0') return false;
        out.assign(buf);
        return !out.empty();
    }

    void fillMetadataFromEffect() {
        if (!m_effect) return;
        m_meta.format = PluginFormat::VST2;
        m_meta.isCompatible = true;
        m_meta.errorMessage.clear();

        std::string name;
        std::string product;
        std::string vendor;
        readEffectString(VST_EFFECT_OPCODE_NAME, name);
        readEffectString(VST_EFFECT_OPCODE_PRODUCT_NAME, product);
        if (!name.empty()) {
            m_meta.name = name;
        } else if (!product.empty()) {
            m_meta.name = product;
        } else {
            m_meta.name = m_meta.bundleName;
        }
        if (readEffectString(VST_EFFECT_OPCODE_VENDOR_NAME, vendor)) {
            m_meta.vendor = vendor;
        }
        if (m_meta.vendor.empty()) m_meta.vendor = "Unknown";
        m_meta.description = product;

        const int32_t version = static_cast<int32_t>(
            dispatch(VST_EFFECT_OPCODE_VENDOR_VERSION));
        m_meta.version = formatVst2Version(version > 0 ? version : m_effect->version);
        if (m_meta.version.empty()) m_meta.version = "1.0";

        const int32_t category = static_cast<int32_t>(dispatch(VST_EFFECT_OPCODE_CATEGORY));
        m_meta.category = categoryName(category);

        char idbuf[16] = {};
        std::snprintf(idbuf, sizeof(idbuf), "%08X",
                      static_cast<unsigned>(m_effect->unique_id));
        m_meta.id = idbuf;

        m_meta.latency =
            m_effect->delay > 0 ? static_cast<uint32_t>(m_effect->delay) : 0u;
        m_latency.store(m_meta.latency, std::memory_order_release);

        const int inCh = std::max(0, std::min(32, static_cast<int>(m_effect->num_inputs)));
        const int outCh = std::max(0, std::min(32, static_cast<int>(m_effect->num_outputs)));
        m_busIn.store(inCh, std::memory_order_relaxed);
        m_busOut.store(outCh, std::memory_order_relaxed);
        m_busInfo.inputBuses = inCh > 0 ? 1 : 0;
        m_busInfo.outputBuses = outCh > 0 ? 1 : 0;
        m_busInfo.mainInChannels = inCh;
        m_busInfo.mainOutChannels = outCh;

        if (outCh <= 0) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "VST2 plugin has no audio outputs";
            return;
        }
    }

    bool showEditorOnPumpThread() {
        if (!m_effect || !m_effect->control) return false;
        EnsureVst2WindowClassRegistered();

        vst_rect_t* rect = nullptr;
        dispatch(VST_EFFECT_OPCODE_EDITOR_GET_RECT, 0, 0, &rect);
        int width = rect ? static_cast<int>(rect->right - rect->left) : 0;
        int height = rect ? static_cast<int>(rect->bottom - rect->top) : 0;
        if (width < 100) width = 400;
        if (height < 80) height = 300;

        const std::wstring title =
            utf8ToWide(m_editorTitle.empty() ? m_meta.name : m_editorTitle);
        RECT rc = {0, 0, width, height};
        DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
        AdjustWindowRect(&rc, style, FALSE);

        HWND hwnd = CreateWindowExW(0, L"AuraDSP_VST2_Host_Window", title.c_str(), style,
                                    CW_USEDEFAULT, CW_USEDEFAULT, rc.right - rc.left,
                                    rc.bottom - rc.top, NULL, NULL, GetModuleHandleW(NULL),
                                    NULL);
        if (!hwnd) return false;

        m_editorHwnd = hwnd;
        m_editorOpen.store(true, std::memory_order_release);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
        m_pump->registerEditor(hwnd);

        dispatch(VST_EFFECT_OPCODE_EDITOR_OPEN, 0, 0, reinterpret_cast<void*>(hwnd));
        if (!IsWindow(hwnd)) {
            m_editorHwnd = nullptr;
            m_editorOpen.store(false, std::memory_order_release);
            return false;
        }

        SetTimer(hwnd, kEditorIdleTimerId, 30, nullptr);
        ShowWindow(hwnd, SW_SHOW);
        UpdateWindow(hwnd);
        FlashEditorToFront(hwnd);
        return true;
    }

    void closeEditorOnPumpThread() {
        HWND hwnd = m_editorHwnd;
        if (hwnd) {
            KillTimer(hwnd, kEditorIdleTimerId);
            if (m_effect) dispatch(VST_EFFECT_OPCODE_EDITOR_CLOSE);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            if (m_pump) m_pump->unregisterEditor(hwnd);
            if (IsWindow(hwnd)) DestroyWindow(hwnd);
        }
        m_editorHwnd = nullptr;
        m_editorOpen.store(false, std::memory_order_release);
    }

    void updateTimeInfo() {
        m_timeInfo.samplePos = 0.0;
        m_timeInfo.sampleRate = m_sampleRate > 0 ? m_sampleRate : 48000.0;
        m_timeInfo.nanoSeconds = 0.0;
        m_timeInfo.ppqPos = 0.0;
        m_timeInfo.tempo = 120.0;
        m_timeInfo.barStartPos = 0.0;
        m_timeInfo.cycleStartPos = 0.0;
        m_timeInfo.cycleEndPos = 0.0;
        m_timeInfo.timeSigNumerator = 4;
        m_timeInfo.timeSigDenominator = 4;
        m_timeInfo.smpteOffset = 0;
        m_timeInfo.smpteFrameRate = 1;
        m_timeInfo.samplesToNextClock = 0;
        m_timeInfo.flags = kVstTransportPlaying | kVstPpqPosValid | kVstTempoValid |
                           kVstBarsValid | kVstTimeSigValid;
    }

    intptr_t handleHostCallback(int32_t opcode, int32_t index, intptr_t value, void* ptr,
                                float opt) {
        (void)index;
        (void)opt;
        switch (opcode) {
            case 0: /* audioMasterAutomate */
                return 0;
            case VST_HOST_OPCODE_VST_VERSION: /* 1 */
                return 2400;
            case 2: /* audioMasterCurrentId */
                return m_effect ? static_cast<intptr_t>(m_effect->unique_id) : 0;
            case 3: /* audioMasterIdle */
                return 1;
            case 7: /* audioMasterGetTime */
                updateTimeInfo();
                return reinterpret_cast<intptr_t>(&m_timeInfo);
            case VST_HOST_OPCODE_EVENT: /* 9 */
                return 1;
            case VST_HOST_OPCODE_IO_MODIFIED: { /* 13 */
                if (m_effect) {
                    m_latency.store(m_effect->delay > 0
                                        ? static_cast<uint32_t>(m_effect->delay)
                                        : 0u,
                                    std::memory_order_release);
                }
                return VST_STATUS_TRUE;
            }
            case VST_HOST_OPCODE_EDITOR_RESIZE: /* 15 */
                return VST_STATUS_TRUE;
            case VST_HOST_OPCODE_GET_SAMPLE_RATE: /* 16 */
                return static_cast<intptr_t>(m_sampleRate > 0 ? m_sampleRate : 48000.0);
            case VST_HOST_OPCODE_GET_BLOCK_SIZE: /* 17 */
                return static_cast<intptr_t>(m_maxBlockSize > 0 ? m_maxBlockSize : 1024);
            case 18: /* audioMasterGetInputLatency */
                return 0;
            case 19: /* audioMasterGetOutputLatency */
                return 0;
            case VST_HOST_OPCODE_GET_ACTIVE_THREAD: /* 23 */
                return m_inProcess.load(std::memory_order_relaxed)
                           ? 2 /* kVstProcessLevelRealtime */
                           : 1 /* kVstProcessLevelUser */;
            case 24: /* audioMasterGetAutomationState */
                return 1; /* kVstAutomationRead */
            case VST_HOST_OPCODE_VENDOR_NAME: /* 32 */
                copyHostString(ptr, value, "AuraDSP");
                return VST_STATUS_TRUE;
            case VST_HOST_OPCODE_PRODUCT_NAME: /* 33 */
                copyHostString(ptr, value, "AuraDSP Host");
                return VST_STATUS_TRUE;
            case VST_HOST_OPCODE_VENDOR_VERSION: /* 34 */
                return 2400;
            case 35: /* audioMasterVendorSpecific */
                return 0;
            case VST_HOST_OPCODE_SUPPORTS: { /* 37 */
                if (!ptr) return VST_STATUS_FALSE;
                const char* canDo = static_cast<const char*>(ptr);
                if (std::strcmp(canDo, "sendVstEvents") == 0 ||
                    std::strcmp(canDo, "sendVstMidiEvent") == 0 ||
                    std::strcmp(canDo, "receiveVstEvents") == 0 ||
                    std::strcmp(canDo, "receiveVstMidiEvent") == 0 ||
                    std::strcmp(canDo, "sizeWindow") == 0 ||
                    std::strcmp(canDo, "sendVstTimeInfo") == 0 ||
                    std::strcmp(canDo, "acceptIOChanges") == 0 ||
                    std::strcmp(canDo, "startStopProcess") == 0 ||
                    std::strcmp(canDo, "shellCategory") == 0 ||
                    std::strcmp(canDo, "supplyIdle") == 0) {
                    return VST_STATUS_TRUE;
                }
                return VST_STATUS_FALSE;
            }
            case VST_HOST_OPCODE_LANGUAGE: /* 38 */
                return 1; /* kVstLangEnglish */
            case VST_HOST_OPCODE_GET_EFFECT_DIRECTORY: /* 41 */
                // Steinberg 官方规范：返回值是 char* 目录字符串指针！
                // 传了 buffer 则安全拷贝，返回指向内部目录字符串的指针
                if (ptr) {
                    copyHostString(ptr, value, m_pluginDir.c_str());
                }
                return reinterpret_cast<intptr_t>(m_pluginDir.c_str());
            case 42: /* audioMasterUpdateDisplay */
                return VST_STATUS_TRUE;
            case 43: /* audioMasterBeginEdit */
                return VST_STATUS_TRUE;
            case 44: /* audioMasterEndEdit */
                return VST_STATUS_TRUE;
            case 45: /* audioMasterOpenFileSelector */
            case 46: /* audioMasterCloseFileSelector */
                return 0;
            default:
                return 0;
        }
    }

    static intptr_t VST_FUNCTION_INTERFACE hostCallback(vst_effect_t* effect, int32_t opcode,
                                                        int32_t index, intptr_t value,
                                                        void* ptr, float opt) {
        Vst2Instance* self = nullptr;
        if (effect && effect->_unknown_00) self = static_cast<Vst2Instance*>(effect->_unknown_00);
        if (!self) self = g_constructing;
        if (!self) self = s_latestConstructing.load(std::memory_order_acquire);
        if (!self) return 0;
        return self->handleHostCallback(opcode, index, value, ptr, opt);
    }

    vst_effect_t* m_effect = nullptr;
    void* m_module = nullptr;
    std::shared_ptr<ModulePumpThread> m_pump;
    std::string m_moduleKey;
    PluginMetadata m_meta;
    PluginBusInfo m_busInfo;
    std::string m_pluginDir;
    HWND m_editorHwnd = nullptr;
    std::string m_editorTitle;

    std::atomic<bool> m_loaded{false};
    std::atomic<bool> m_active{false};
    std::atomic<bool> m_bypassed{false};
    std::atomic<bool> m_editorOpen{false};
    std::atomic<bool> m_threadAbandoned{false};
    std::atomic<bool> m_inProcess{false};
    std::atomic<uint32_t> m_latency{0};
    std::atomic<int> m_channelHint{2};
    std::atomic<int> m_busIn{0};
    std::atomic<int> m_busOut{0};

    double m_sampleRate = 48000.0;
    uint32_t m_maxBlockSize = 1024;
    std::vector<float> m_monoScratch;
    Vst2TimeInfo m_timeInfo{};
};

} // namespace

std::unique_ptr<IPluginInstance> createVst2Instance() {
    return std::make_unique<Vst2Instance>();
}

} // namespace auradsp
