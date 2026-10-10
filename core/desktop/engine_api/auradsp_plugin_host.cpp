/*
 * auradsp_plugin_host.cpp — AuraDSP M1 Plugin Host Engine (VST3 / CLAP 64-bit)
 *
 * Implements in-process plugin hosting for VST3 and CLAP plugins on Windows x64.
 */

#include "auradsp_plugin_host.h"

#include <windows.h>
#include <shlobj.h>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <iostream>
#include <iomanip>
#include <algorithm>
#include <cstring>
#include <thread>
#include <future>
#include <array>

// CLAP headers
#include <clap/clap.h>

// Steinberg VST3 headers
#include <steinberg/vst3_static.h>

namespace fs = std::filesystem;

namespace auradsp {

namespace {

/* RT 临界区守卫：进入时已由调用方 fetch_add(acq_rel) 计入 inFlight，
 * 析构时递减；若是最后一个离开者且控制线程正在等排空，则唤醒它。
 * 唤醒带 pend 检查，避免每块都触发一次无谓的 futex/WaitOnAddress 系统调用。 */
struct InFlightGuard {
    std::atomic<uint32_t>& counter;
    std::atomic<bool>& pending;
    InFlightGuard(std::atomic<uint32_t>& c, std::atomic<bool>& p) : counter(c), pending(p) {}
    ~InFlightGuard() {
        if (counter.fetch_sub(1, std::memory_order_release) == 1 &&
            pending.load(std::memory_order_relaxed)) {
            counter.notify_all();
        }
    }
    InFlightGuard(const InFlightGuard&) = delete;
    InFlightGuard& operator=(const InFlightGuard&) = delete;
};

/* 控制线程等待 RT 排空的自旋上限。正常路径 0~1 次 wait 即返回；
 * 超过上限视为「RT 线程异常滞留」，此时选择保留实例而不是冒险释放。 */
constexpr uint32_t kQuiesceSpinLimit = 4096;

/* SEH 崩溃隔离。
 * MSVC 限制：__try 不能出现在需要 C++ 对象展开（ unwind）的函数中（C2712），
 * 而 processSlot 内有 InFlightGuard 析构，故把 SEH 段隔离到这个无对象函数。
 * 返回 0 = 正常，1 = 捕获到插件异常（调用方据此自动旁路该槽）。 */
static int processSlotGuarded(PluginHostManager::PluginSlot& s,
                              float* const* inChannels, float* const* outChannels,
                              uint32_t numFrames) {
#if defined(_MSC_VER)
    __try {
        if (s.instance) s.instance->process(inChannels, outChannels, numFrames);
        return 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 1;
    }
#else
    try {
        if (s.instance) s.instance->process(inChannels, outChannels, numFrames);
        return 0;
    } catch (...) {
        return 1;
    }
#endif
}

}  // namespace

//------------------------------------------------------------------------------
// Win32 Editor Window Host
//------------------------------------------------------------------------------
static LRESULT CALLBACK PluginWindowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_CLOSE) {
        DestroyWindow(hwnd);
        return 0;
    }
    if (msg == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void EnsureWindowClassRegistered() {
    static std::once_flag flag;
    std::call_once(flag, []() {
        WNDCLASSEXW wc = {sizeof(WNDCLASSEXW)};
        wc.lpfnWndProc = PluginWindowProc;
        wc.hInstance = GetModuleHandleW(NULL);
        wc.lpszClassName = L"AuraDSP_Plugin_Host_Window";
        wc.hCursor = LoadCursor(NULL, IDC_ARROW);
        wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
        RegisterClassExW(&wc);
    });
}

//------------------------------------------------------------------------------
// Steinberg VST3 Memory Stream for State / Preset Serialization
//------------------------------------------------------------------------------
class Vst3MemoryStream : public Steinberg::IBStream {
public:
    Vst3MemoryStream() = default;
    virtual ~Vst3MemoryStream() = default;

    Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID _iid, void** obj) override {
        if (!obj) return Steinberg::kInvalidArgument;
        if (std::memcmp(_iid, Steinberg::IBStream::iid.toTUID(), sizeof(Steinberg::TUID)) == 0 ||
            std::memcmp(_iid, Steinberg::FUnknown::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            *obj = this;
            addRef();
            return Steinberg::kResultOk;
        }
        *obj = nullptr;
        return Steinberg::kNoInterface;
    }

    Steinberg::uint32 PLUGIN_API addRef() override {
        return ++m_ref;
    }

    Steinberg::uint32 PLUGIN_API release() override {
        Steinberg::uint32 r = --m_ref;
        if (r == 0) delete this;
        return r;
    }

    Steinberg::tresult PLUGIN_API read(void* buffer, Steinberg::int32 numBytes, Steinberg::int32* numBytesRead) override {
        if (numBytes < 0 || !buffer) return Steinberg::kInvalidArgument;
        size_t available = (m_pos < m_data.size()) ? (m_data.size() - m_pos) : 0;
        size_t toRead = (std::min)(static_cast<size_t>(numBytes), available);
        if (toRead > 0) {
            std::memcpy(buffer, m_data.data() + m_pos, toRead);
            m_pos += toRead;
        }
        if (numBytesRead) *numBytesRead = static_cast<Steinberg::int32>(toRead);
        return Steinberg::kResultOk;
    }

    Steinberg::tresult PLUGIN_API write(void* buffer, Steinberg::int32 numBytes, Steinberg::int32* numBytesWritten) override {
        if (numBytes < 0 || !buffer) return Steinberg::kInvalidArgument;
        if (m_pos + numBytes > m_data.size()) {
            m_data.resize(m_pos + numBytes);
        }
        std::memcpy(m_data.data() + m_pos, buffer, static_cast<size_t>(numBytes));
        m_pos += static_cast<size_t>(numBytes);
        if (numBytesWritten) *numBytesWritten = numBytes;
        return Steinberg::kResultOk;
    }

    Steinberg::tresult PLUGIN_API seek(Steinberg::int64 pos, Steinberg::int32 mode, Steinberg::int64* result) override {
        Steinberg::int64 newPos = static_cast<Steinberg::int64>(m_pos);
        switch (mode) {
            case kIBSeekSet: newPos = pos; break;
            case kIBSeekCur: newPos += pos; break;
            case kIBSeekEnd: newPos = static_cast<Steinberg::int64>(m_data.size()) + pos; break;
            default: return Steinberg::kInvalidArgument;
        }
        if (newPos < 0) return Steinberg::kInvalidArgument;
        m_pos = static_cast<size_t>(newPos);
        if (result) *result = newPos;
        return Steinberg::kResultOk;
    }

    Steinberg::tresult PLUGIN_API tell(Steinberg::int64* pos) override {
        if (!pos) return Steinberg::kInvalidArgument;
        *pos = static_cast<Steinberg::int64>(m_pos);
        return Steinberg::kResultOk;
    }

    std::vector<uint8_t> m_data;
    size_t m_pos = 0;
    std::atomic<Steinberg::uint32> m_ref{1};
};

//------------------------------------------------------------------------------
// JSON Helpers
//------------------------------------------------------------------------------
static std::string escapeJsonString(const std::string& input) {
    std::ostringstream ss;
    for (char c : input) {
        switch (c) {
            case '"':  ss << "\\\""; break;
            case '\\': ss << "\\\\"; break;
            case '\b': ss << "\\b";  break;
            case '\f': ss << "\\f";  break;
            case '\n': ss << "\\n";  break;
            case '\r': ss << "\\r";  break;
            case '\t': ss << "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < ' ') {
                    ss << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
                } else {
                    ss << c;
                }
        }
    }
    return ss.str();
}

static std::string cidToHexString(const Steinberg::TUID tuid) {
    std::ostringstream ss;
    for (int i = 0; i < 16; ++i) {
        ss << std::hex << std::setw(2) << std::setfill('0') << (static_cast<int>(static_cast<uint8_t>(tuid[i])));
    }
    return ss.str();
}

static bool hexStringToCid(const std::string& hex, Steinberg::TUID tuid) {
    if (hex.length() != 32) return false;
    for (size_t i = 0; i < 16; ++i) {
        std::string byteStr = hex.substr(i * 2, 2);
        char* end = nullptr;
        tuid[i] = static_cast<char>(std::strtoul(byteStr.c_str(), &end, 16));
    }
    return true;
}

static std::wstring utf8ToWide(const std::string& utf8) {
    if (utf8.empty()) return std::wstring();
    int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
    if (size <= 0) return std::wstring();
    std::wstring wide(size - 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &wide[0], size);
    return wide;
}

std::string PluginMetadata::toJson() const {
    std::ostringstream ss;
    ss << "{"
       << "\"path\":\"" << escapeJsonString(path) << "\","
       << "\"id\":\"" << escapeJsonString(id) << "\","
       << "\"name\":\"" << escapeJsonString(name) << "\","
       << "\"vendor\":\"" << escapeJsonString(vendor) << "\","
       << "\"version\":\"" << escapeJsonString(version) << "\","
       << "\"category\":\"" << escapeJsonString(category) << "\","
       << "\"format\":\"" << (format == PluginFormat::VST3 ? "VST3" : (format == PluginFormat::CLAP ? "CLAP" : "Unknown")) << "\","
       << "\"is64Bit\":" << (is64Bit ? "true" : "false") << ","
       << "\"latency\":" << latency << ","
       << "\"isCompatible\":" << (isCompatible ? "true" : "false") << ","
       << "\"errorMessage\":\"" << escapeJsonString(errorMessage) << "\""
       << "}";
    return ss.str();
}

//------------------------------------------------------------------------------
// CLAP Host Implementation
//------------------------------------------------------------------------------
class ClapPluginInstance : public IPluginInstance {
public:
    ClapPluginInstance() = default;
    ~ClapPluginInstance() override { unload(); }

    bool load(const std::string& path, const std::string& pluginId) override {
        unload();

        m_meta.path = path;
        m_meta.format = PluginFormat::CLAP;
        m_meta.is64Bit = true;

        std::string binaryPath = PluginScanner::resolveBundleBinary(path, PluginFormat::CLAP);
        if (binaryPath.empty()) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Invalid CLAP bundle or binary path";
            return false;
        }
        std::wstring wpath = utf8ToWide(binaryPath);
        m_module = LoadLibraryExW(wpath.c_str(), NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!m_module) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Failed to load CLAP library: " + std::to_string(GetLastError());
            return false;
        }

        m_entry = reinterpret_cast<const clap_plugin_entry_t*>(GetProcAddress(m_module, "clap_entry"));
        if (!m_entry) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Missing 'clap_entry' symbol in CLAP binary";
            FreeLibrary(m_module);
            m_module = nullptr;
            return false;
        }

        if (!m_entry->init(path.c_str())) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "clap_entry->init() returned false";
            FreeLibrary(m_module);
            m_module = nullptr;
            m_entry = nullptr;
            return false;
        }

        m_factory = reinterpret_cast<const clap_plugin_factory_t*>(m_entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
        if (!m_factory) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Failed to retrieve CLAP_PLUGIN_FACTORY_ID";
            m_entry->deinit();
            FreeLibrary(m_module);
            m_module = nullptr;
            m_entry = nullptr;
            return false;
        }

        uint32_t count = m_factory->get_plugin_count(m_factory);
        if (count == 0) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "CLAP factory reports 0 plugins";
            m_entry->deinit();
            FreeLibrary(m_module);
            m_module = nullptr;
            m_entry = nullptr;
            return false;
        }

        const clap_plugin_descriptor_t* targetDesc = nullptr;
        for (uint32_t i = 0; i < count; ++i) {
            const clap_plugin_descriptor_t* d = m_factory->get_plugin_descriptor(m_factory, i);
            if (!d) continue;
            if (pluginId.empty() || std::string(d->id) == pluginId) {
                targetDesc = d;
                break;
            }
        }

        if (!targetDesc) {
            targetDesc = m_factory->get_plugin_descriptor(m_factory, 0);
        }

        if (targetDesc) {
            m_meta.id = targetDesc->id ? targetDesc->id : "";
            m_meta.name = targetDesc->name ? targetDesc->name : "";
            m_meta.vendor = targetDesc->vendor ? targetDesc->vendor : "";
            m_meta.version = targetDesc->version ? targetDesc->version : "";
            m_meta.category = targetDesc->description ? targetDesc->description : "AudioEffect";
        }

        initHostStruct();
        m_plugin = m_factory->create_plugin(m_factory, &m_host, m_meta.id.c_str());
        if (!m_plugin) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "factory->create_plugin() returned null for ID: " + m_meta.id;
            m_entry->deinit();
            FreeLibrary(m_module);
            m_module = nullptr;
            m_entry = nullptr;
            return false;
        }

        if (!m_plugin->init(m_plugin)) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "plugin->init() failed";
            m_plugin->destroy(m_plugin);
            m_plugin = nullptr;
            m_entry->deinit();
            FreeLibrary(m_module);
            m_module = nullptr;
            m_entry = nullptr;
            return false;
        }

        m_isLoaded = true;
        m_meta.isCompatible = true;
        return true;
    }

    void unload() override {
        if (m_isLoaded) {
            closeEditor();
            deactivate();
            if (m_plugin) {
                m_plugin->destroy(m_plugin);
                m_plugin = nullptr;
            }
            if (m_entry) {
                m_entry->deinit();
                m_entry = nullptr;
            }
            if (m_module) {
                FreeLibrary(m_module);
                m_module = nullptr;
            }
            m_isLoaded = false;
        }
    }

    bool activate(double sampleRate, uint32_t maxBlockSize) override {
        if (!m_isLoaded || !m_plugin) return false;
        if (m_isActive) deactivate();

        m_sampleRate = sampleRate;
        m_maxBlockSize = maxBlockSize;

        if (!m_plugin->activate(m_plugin, sampleRate, 1, maxBlockSize)) {
            return false;
        }

        if (m_plugin->start_processing && !m_plugin->start_processing(m_plugin)) {
            m_plugin->deactivate(m_plugin);
            return false;
        }

        // Query latency
        auto latExt = reinterpret_cast<const clap_plugin_latency_t*>(
            m_plugin->get_extension(m_plugin, CLAP_EXT_LATENCY));
        if (latExt && latExt->get) {
            m_meta.latency = latExt->get(m_plugin);
        } else {
            m_meta.latency = 0;
        }

        m_isActive = true;
        return true;
    }

    void deactivate() override {
        if (m_isActive && m_plugin) {
            if (m_plugin->stop_processing) {
                m_plugin->stop_processing(m_plugin);
            }
            m_plugin->deactivate(m_plugin);
            m_isActive = false;
        }
    }

    void process(float* const* inChannels, float* const* outChannels, uint32_t numFrames) override {
        if (numFrames == 0) return;
        if (!inChannels || !outChannels || !inChannels[0] || !inChannels[1] || !outChannels[0] || !outChannels[1]) return;

        if (!m_isActive || !m_plugin || m_bypassed) {
            if (inChannels != outChannels) {
                for (int ch = 0; ch < 2; ++ch) {
                    std::memcpy(outChannels[ch], inChannels[ch], numFrames * sizeof(float));
                }
            }
            return;
        }

        clap_audio_buffer_t inBuf = {};
        inBuf.data32 = (float**)inChannels;
        inBuf.channel_count = 2;
        inBuf.latency = 0;

        clap_audio_buffer_t outBuf = {};
        outBuf.data32 = (float**)outChannels;
        outBuf.channel_count = 2;
        outBuf.latency = 0;

        clap_event_transport_t transport = {};
        transport.header.size = sizeof(transport);
        transport.header.type = CLAP_EVENT_TRANSPORT;
        transport.header.time = 0;
        transport.flags = CLAP_TRANSPORT_IS_PLAYING | CLAP_TRANSPORT_HAS_TEMPO | CLAP_TRANSPORT_HAS_TIME_SIGNATURE;
        transport.tempo = 120.0;
        transport.tsig_num = 4;
        transport.tsig_denom = 4;

        clap_process_t proc = {};
        proc.steady_time = -1;
        proc.frames_count = numFrames;
        proc.transport = &transport;
        proc.audio_inputs = &inBuf;
        proc.audio_inputs_count = 1;
        proc.audio_outputs = &outBuf;
        proc.audio_outputs_count = 1;
        proc.in_events = nullptr;
        proc.out_events = nullptr;

        clap_process_status status = m_plugin->process(m_plugin, &proc);
        if (status == CLAP_PROCESS_ERROR) {
            // Bypass on error
            m_bypassed = true;
        }
    }

    bool isLoaded() const override { return m_isLoaded; }
    bool isBypassed() const override { return m_bypassed; }
    void setBypass(bool bypass) override { m_bypassed = bypass; }
    uint32_t getLatency() const override { return m_meta.latency; }
    const PluginMetadata& getMetadata() const override { return m_meta; }

    bool showEditor(void* parentHwnd = nullptr) override {
        if (!m_isLoaded || !m_plugin) return false;
        if (m_editorOpen.load(std::memory_order_acquire) && m_editorHwnd && IsWindow(m_editorHwnd)) {
            SetForegroundWindow(m_editorHwnd);
            ShowWindow(m_editorHwnd, SW_SHOW);
            return true;
        }
        if (m_editorThread.joinable()) {
            m_editorThread.join();
        }

        auto gui = reinterpret_cast<const clap_plugin_gui_t*>(
            m_plugin->get_extension(m_plugin, CLAP_EXT_GUI));
        if (!gui) return false;
        if (!gui->is_api_supported || !gui->is_api_supported(m_plugin, CLAP_WINDOW_API_WIN32, false)) {
            return false;
        }

        std::promise<bool> initPromise;
        auto initFuture = initPromise.get_future();

        m_editorThread = std::thread([this, gui, &initPromise]() {
            EnsureWindowClassRegistered();
            if (!gui->create(m_plugin, CLAP_WINDOW_API_WIN32, false)) {
                initPromise.set_value(false);
                return;
            }

            uint32_t width = 800, height = 600;
            if (gui->get_size) {
                gui->get_size(m_plugin, &width, &height);
            }
            if (width < 200) width = 800;
            if (height < 150) height = 600;

            std::wstring title = L"[AuraDSP] " + utf8ToWide(m_meta.name);
            RECT rc = {0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
            DWORD style = WS_OVERLAPPEDWINDOW;
            AdjustWindowRect(&rc, style, FALSE);

            HWND hwnd = CreateWindowExW(
                0, L"AuraDSP_Plugin_Host_Window", title.c_str(),
                style, CW_USEDEFAULT, CW_USEDEFAULT,
                rc.right - rc.left, rc.bottom - rc.top,
                NULL, NULL, GetModuleHandleW(NULL), NULL);

            if (!hwnd) {
                if (gui->destroy) gui->destroy(m_plugin);
                initPromise.set_value(false);
                return;
            }

            m_editorHwnd = hwnd;
            m_editorOpen.store(true, std::memory_order_release);

            clap_window_t win = {};
            win.api = CLAP_WINDOW_API_WIN32;
            win.win32 = hwnd;
            if (gui->set_parent) gui->set_parent(m_plugin, &win);
            if (gui->show) gui->show(m_plugin);

            ShowWindow(hwnd, SW_SHOW);
            UpdateWindow(hwnd);

            initPromise.set_value(true);

            MSG msg;
            while (GetMessageW(&msg, NULL, 0, 0) > 0) {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }

            if (gui->hide) gui->hide(m_plugin);
            if (gui->destroy) gui->destroy(m_plugin);
            m_editorHwnd = nullptr;
            m_editorOpen.store(false, std::memory_order_release);
        });

        return initFuture.get();
    }

    void closeEditor() override {
        if (m_editorHwnd && IsWindow(m_editorHwnd)) {
            PostMessageW(m_editorHwnd, WM_CLOSE, 0, 0);
        }
        if (m_editorThread.joinable()) {
            if (m_editorThread.get_id() != std::this_thread::get_id()) {
                m_editorThread.join();
            } else {
                m_editorThread.detach();
            }
        }
        m_editorOpen.store(false, std::memory_order_release);
    }

    bool isEditorOpen() const override {
        return m_editorOpen.load(std::memory_order_acquire) && m_editorHwnd != nullptr && IsWindow(m_editorHwnd);
    }

    struct ClapOstreamContext {
        std::ofstream* ofs;
    };
    static int64_t clapOstreamWrite(const clap_ostream_t* stream, const void* buffer, uint64_t size) {
        auto ctx = reinterpret_cast<ClapOstreamContext*>(stream->ctx);
        ctx->ofs->write(reinterpret_cast<const char*>(buffer), static_cast<std::streamsize>(size));
        return static_cast<int64_t>(size);
    }

    bool savePreset(const std::string& filePath) override {
        if (!m_isLoaded || !m_plugin) return false;
        auto stateExt = reinterpret_cast<const clap_plugin_state_t*>(
            m_plugin->get_extension(m_plugin, CLAP_EXT_STATE));
        if (!stateExt || !stateExt->save) return false;

        fs::path p(filePath);
        if (p.has_parent_path() && !fs::exists(p.parent_path())) {
            fs::create_directories(p.parent_path());
        }

        std::ofstream ofs(filePath, std::ios::binary);
        if (!ofs) return false;
        ClapOstreamContext ctx{&ofs};
        clap_ostream_t ostream = { &ctx, clapOstreamWrite };
        return stateExt->save(m_plugin, &ostream);
    }

    struct ClapIstreamContext {
        std::ifstream* ifs;
    };
    static int64_t clapIstreamRead(const clap_istream_t* stream, void* buffer, uint64_t size) {
        auto ctx = reinterpret_cast<ClapIstreamContext*>(stream->ctx);
        ctx->ifs->read(reinterpret_cast<char*>(buffer), static_cast<std::streamsize>(size));
        return static_cast<int64_t>(ctx->ifs->gcount());
    }

    bool loadPreset(const std::string& filePath) override {
        if (!m_isLoaded || !m_plugin) return false;
        if (!fs::exists(filePath)) return false;

        auto stateExt = reinterpret_cast<const clap_plugin_state_t*>(
            m_plugin->get_extension(m_plugin, CLAP_EXT_STATE));
        if (!stateExt || !stateExt->load) return false;

        std::ifstream ifs(filePath, std::ios::binary);
        if (!ifs) return false;
        ClapIstreamContext ctx{&ifs};
        clap_istream_t istream = { &ctx, clapIstreamRead };
        return stateExt->load(m_plugin, &istream);
    }

private:
    void initHostStruct() {
        m_host.clap_version = CLAP_VERSION;
        m_host.host_data = this;
        m_host.name = "AuraDSP";
        m_host.vendor = "AuraDSP Audio Engine";
        m_host.url = "https://github.com/li589/AuraDSP";
        m_host.version = "1.0.0";
        m_host.get_extension = hostGetExtension;
        m_host.request_restart = hostRequestRestart;
        m_host.request_process = hostRequestProcess;
        m_host.request_callback = hostRequestCallback;
    }

    static const void* hostGetExtension(const struct clap_host* host, const char* extension_id) {
        return nullptr;
    }
    static void hostRequestRestart(const struct clap_host* host) {}
    static void hostRequestProcess(const struct clap_host* host) {}
    static void hostRequestCallback(const struct clap_host* host) {}

    HMODULE m_module = nullptr;
    const clap_plugin_entry_t* m_entry = nullptr;
    const clap_plugin_factory_t* m_factory = nullptr;
    const clap_plugin_t* m_plugin = nullptr;
    clap_host_t m_host = {};

    PluginMetadata m_meta;
    bool m_isLoaded = false;
    bool m_isActive = false;
    bool m_bypassed = false;
    double m_sampleRate = 48000.0;
    uint32_t m_maxBlockSize = 1024;

    std::thread m_editorThread;
    HWND m_editorHwnd = nullptr;
    std::atomic<bool> m_editorOpen{false};
};

//------------------------------------------------------------------------------
// VST3 Host Implementation
//------------------------------------------------------------------------------
class Vst3PluginInstance : public IPluginInstance {
public:
    Vst3PluginInstance() = default;
    ~Vst3PluginInstance() override { unload(); }

    bool load(const std::string& path, const std::string& pluginId) override {
        unload();

        m_meta.path = path;
        m_meta.format = PluginFormat::VST3;
        m_meta.is64Bit = true;

        std::string binaryPath = PluginScanner::resolveBundleBinary(path, PluginFormat::VST3);
        if (binaryPath.empty()) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Invalid VST3 bundle or binary path";
            return false;
        }
        std::wstring wpath = utf8ToWide(binaryPath);
        m_module = LoadLibraryExW(wpath.c_str(), NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!m_module) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Failed to load VST3 DLL: " + std::to_string(GetLastError());
            return false;
        }

        typedef Steinberg::IPluginFactory* (PLUGIN_API *GetFactoryFunc)();
        auto getFactory = reinterpret_cast<GetFactoryFunc>(GetProcAddress(m_module, "GetPluginFactory"));
        if (!getFactory) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Missing GetPluginFactory export in VST3 binary";
            FreeLibrary(m_module);
            m_module = nullptr;
            return false;
        }

        m_factory = getFactory();
        if (!m_factory) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "GetPluginFactory returned null";
            FreeLibrary(m_module);
            m_module = nullptr;
            return false;
        }

        Steinberg::int32 classCount = m_factory->countClasses();
        Steinberg::TUID targetCid = {};
        bool found = false;

        Steinberg::IPluginFactory2* factory2 = nullptr;
        m_factory->queryInterface(Steinberg::IPluginFactory2::iid, reinterpret_cast<void**>(&factory2));

        for (Steinberg::int32 i = 0; i < classCount; ++i) {
            Steinberg::PClassInfo classInfo;
            if (m_factory->getClassInfo(i, &classInfo) != Steinberg::kResultOk) continue;

            if (std::strcmp(classInfo.category, kVstAudioEffectClass) == 0) {
                std::string cidHex = cidToHexString(classInfo.cid);
                if (pluginId.empty() || cidHex == pluginId) {
                    std::memcpy(targetCid, classInfo.cid, sizeof(Steinberg::TUID));
                    m_meta.id = cidHex;
                    m_meta.name = classInfo.name;
                    m_meta.category = classInfo.category;

                    if (factory2) {
                        Steinberg::PClassInfo2 classInfo2;
                        if (factory2->getClassInfo2(i, &classInfo2) == Steinberg::kResultOk) {
                            m_meta.vendor = classInfo2.vendor;
                            m_meta.version = classInfo2.version;
                            m_meta.category = classInfo2.subCategories;
                        }
                    }
                    found = true;
                    break;
                }
            }
        }

        if (factory2) factory2->release();

        if (!found) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "No compatible audio effect class (kVstAudioEffectClass) found in VST3";
            FreeLibrary(m_module);
            m_module = nullptr;
            m_factory = nullptr;
            return false;
        }

        // Create component instance
        Steinberg::tresult res = m_factory->createInstance(
            targetCid,
            Steinberg::Vst::IComponent::iid.toTUID(),
            reinterpret_cast<void**>(&m_component)
        );

        if (res != Steinberg::kResultOk || !m_component) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Failed to create VST3 IComponent instance, res: " + std::to_string(res);
            FreeLibrary(m_module);
            m_module = nullptr;
            m_factory = nullptr;
            return false;
        }

        // Initialize component
        m_component->initialize(nullptr);

        // Query IAudioProcessor
        res = m_component->queryInterface(
            Steinberg::Vst::IAudioProcessor::iid,
            reinterpret_cast<void**>(&m_processor)
        );

        if (res != Steinberg::kResultOk || !m_processor) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Failed to query VST3 IAudioProcessor interface";
            m_component->terminate();
            m_component->release();
            m_component = nullptr;
            FreeLibrary(m_module);
            m_module = nullptr;
            m_factory = nullptr;
            return false;
        }

        // Query IEditController
        Steinberg::tresult cRes = m_component->queryInterface(
            Steinberg::Vst::IEditController::iid,
            reinterpret_cast<void**>(&m_controller)
        );
        if (cRes != Steinberg::kResultOk || !m_controller) {
            Steinberg::TUID controllerCID;
            if (m_component->getControllerClassId(controllerCID) == Steinberg::kResultOk) {
                m_factory->createInstance(
                    controllerCID,
                    Steinberg::Vst::IEditController::iid.toTUID(),
                    reinterpret_cast<void**>(&m_controller)
                );
                if (m_controller) {
                    m_controller->initialize(nullptr);
                }
            }
        }

        m_isLoaded = true;
        m_meta.isCompatible = true;
        return true;
    }

    void unload() override {
        if (m_isLoaded) {
            closeEditor();
            deactivate();
            if (m_controller) {
                m_controller->terminate();
                m_controller->release();
                m_controller = nullptr;
            }
            if (m_processor) {
                m_processor->release();
                m_processor = nullptr;
            }
            if (m_component) {
                m_component->terminate();
                m_component->release();
                m_component = nullptr;
            }
            m_factory = nullptr;

            if (m_module) {
                FreeLibrary(m_module);
                m_module = nullptr;
            }
            m_isLoaded = false;
        }
    }

    bool activate(double sampleRate, uint32_t maxBlockSize) override {
        if (!m_isLoaded || !m_processor || !m_component) return false;
        if (m_isActive) deactivate();

        m_sampleRate = sampleRate;
        m_maxBlockSize = maxBlockSize;

        // Negotiate stereo bus arrangement
        Steinberg::Vst::SpeakerArrangement stereo = Steinberg::Vst::SpeakerArr::kStereo;
        m_processor->setBusArrangements(&stereo, 1, &stereo, 1);

        // Setup processing
        Steinberg::Vst::ProcessSetup setup = {};
        setup.processMode = Steinberg::Vst::kRealtime;
        setup.sampleRate = sampleRate;
        setup.maxSamplesPerBlock = maxBlockSize;
        setup.symbolicSampleSize = Steinberg::Vst::kSample32;

        if (m_processor->setupProcessing(setup) != Steinberg::kResultOk) {
            return false;
        }

        m_component->setActive(true);
        m_processor->setProcessing(true);

        m_meta.latency = m_processor->getLatencySamples();
        m_isActive = true;
        return true;
    }

    void deactivate() override {
        if (m_isActive) {
            if (m_processor) m_processor->setProcessing(false);
            if (m_component) m_component->setActive(false);
            m_isActive = false;
        }
    }

    void process(float* const* inChannels, float* const* outChannels, uint32_t numFrames) override {
        if (numFrames == 0) return;
        if (!inChannels || !outChannels || !inChannels[0] || !inChannels[1] || !outChannels[0] || !outChannels[1]) return;

        if (!m_isActive || !m_processor || m_bypassed) {
            if (inChannels != outChannels) {
                for (int ch = 0; ch < 2; ++ch) {
                    std::memcpy(outChannels[ch], inChannels[ch], numFrames * sizeof(float));
                }
            }
            return;
        }

        Steinberg::Vst::AudioBusBuffers inBus = {};
        inBus.numChannels = 2;
        inBus.silenceFlags = 0;
        inBus.channelBuffers32 = (Steinberg::Vst::Sample32**)inChannels;

        Steinberg::Vst::AudioBusBuffers outBus = {};
        outBus.numChannels = 2;
        outBus.silenceFlags = 0;
        outBus.channelBuffers32 = (Steinberg::Vst::Sample32**)outChannels;

        Steinberg::Vst::ProcessContext context = {};
        context.state = Steinberg::Vst::ProcessContext::kPlaying |
                        Steinberg::Vst::ProcessContext::kProjectTimeMusicValid |
                        Steinberg::Vst::ProcessContext::kTempoValid |
                        Steinberg::Vst::ProcessContext::kTimeSigValid;
        context.sampleRate = m_sampleRate;
        context.tempo = 120.0;
        context.timeSigNumerator = 4;
        context.timeSigDenominator = 4;

        Steinberg::Vst::ProcessData data = {};
        data.processMode = Steinberg::Vst::kRealtime;
        data.symbolicSampleSize = Steinberg::Vst::kSample32;
        data.numSamples = numFrames;
        data.inputs = &inBus;
        data.numInputs = 1;
        data.outputs = &outBus;
        data.numOutputs = 1;
        data.inputParameterChanges = nullptr;
        data.outputParameterChanges = nullptr;
        data.inputEvents = nullptr;
        data.outputEvents = nullptr;
        data.processContext = &context;

        Steinberg::tresult res = m_processor->process(data);
        if (res != Steinberg::kResultOk) {
            m_bypassed = true;
        }
    }

    bool isLoaded() const override { return m_isLoaded; }
    bool isBypassed() const override { return m_bypassed; }
    void setBypass(bool bypass) override { m_bypassed = bypass; }
    uint32_t getLatency() const override { return m_meta.latency; }
    const PluginMetadata& getMetadata() const override { return m_meta; }

    bool showEditor(void* parentHwnd = nullptr) override {
        if (!m_isLoaded || !m_component) return false;
        if (m_editorOpen.load(std::memory_order_acquire) && m_editorHwnd && IsWindow(m_editorHwnd)) {
            SetForegroundWindow(m_editorHwnd);
            ShowWindow(m_editorHwnd, SW_SHOW);
            return true;
        }
        if (m_editorThread.joinable()) {
            m_editorThread.join();
        }

        if (!m_controller) return false;
        Steinberg::IPlugView* view = m_controller->createView(Steinberg::Vst::ViewType::kEditor);
        if (!view) return false;
        if (view->isPlatformTypeSupported(Steinberg::kPlatformTypeHWND) != Steinberg::kResultTrue) {
            view->release();
            return false;
        }

        std::promise<bool> initPromise;
        auto initFuture = initPromise.get_future();

        m_editorThread = std::thread([this, view, &initPromise]() {
            EnsureWindowClassRegistered();
            Steinberg::ViewRect vr;
            int width = 800, height = 600;
            if (view->getSize(&vr) == Steinberg::kResultOk) {
                width = vr.right - vr.left;
                height = vr.bottom - vr.top;
            }
            if (width < 200) width = 800;
            if (height < 150) height = 600;

            std::wstring title = L"[AuraDSP] " + utf8ToWide(m_meta.name);
            RECT rc = {0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
            DWORD style = WS_OVERLAPPEDWINDOW;
            AdjustWindowRect(&rc, style, FALSE);

            HWND hwnd = CreateWindowExW(
                0, L"AuraDSP_Plugin_Host_Window", title.c_str(),
                style, CW_USEDEFAULT, CW_USEDEFAULT,
                rc.right - rc.left, rc.bottom - rc.top,
                NULL, NULL, GetModuleHandleW(NULL), NULL);

            if (!hwnd) {
                view->release();
                initPromise.set_value(false);
                return;
            }

            m_editorHwnd = hwnd;
            m_editorOpen.store(true, std::memory_order_release);

            view->attached(reinterpret_cast<void*>(hwnd), Steinberg::kPlatformTypeHWND);

            ShowWindow(hwnd, SW_SHOW);
            UpdateWindow(hwnd);

            initPromise.set_value(true);

            MSG msg;
            while (GetMessageW(&msg, NULL, 0, 0) > 0) {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }

            view->removed();
            view->release();
            m_editorHwnd = nullptr;
            m_editorOpen.store(false, std::memory_order_release);
        });

        return initFuture.get();
    }

    void closeEditor() override {
        if (m_editorHwnd && IsWindow(m_editorHwnd)) {
            PostMessageW(m_editorHwnd, WM_CLOSE, 0, 0);
        }
        if (m_editorThread.joinable()) {
            if (m_editorThread.get_id() != std::this_thread::get_id()) {
                m_editorThread.join();
            } else {
                m_editorThread.detach();
            }
        }
        m_editorOpen.store(false, std::memory_order_release);
    }

    bool isEditorOpen() const override {
        return m_editorOpen.load(std::memory_order_acquire) && m_editorHwnd != nullptr && IsWindow(m_editorHwnd);
    }

    bool savePreset(const std::string& filePath) override {
        if (!m_isLoaded || !m_component) return false;
        auto stream = new Vst3MemoryStream();
        Steinberg::tresult res = m_component->getState(stream);
        if (res != Steinberg::kResultOk) {
            stream->release();
            return false;
        }

        fs::path p(filePath);
        if (p.has_parent_path() && !fs::exists(p.parent_path())) {
            fs::create_directories(p.parent_path());
        }

        std::ofstream ofs(filePath, std::ios::binary);
        if (!ofs) {
            stream->release();
            return false;
        }
        ofs.write(reinterpret_cast<const char*>(stream->m_data.data()), stream->m_data.size());
        stream->release();
        return true;
    }

    bool loadPreset(const std::string& filePath) override {
        if (!m_isLoaded || !m_component) return false;
        if (!fs::exists(filePath)) return false;

        std::ifstream ifs(filePath, std::ios::binary);
        if (!ifs) return false;
        ifs.seekg(0, std::ios::end);
        size_t sz = static_cast<size_t>(ifs.tellg());
        ifs.seekg(0, std::ios::beg);
        std::vector<uint8_t> buf(sz);
        ifs.read(reinterpret_cast<char*>(buf.data()), static_cast<std::streamsize>(sz));

        auto stream = new Vst3MemoryStream();
        stream->m_data = std::move(buf);
        Steinberg::tresult res = m_component->setState(stream);
        if (res == Steinberg::kResultOk && m_controller) {
            stream->seek(0, Steinberg::IBStream::kIBSeekSet, nullptr);
            m_controller->setComponentState(stream);
        }
        stream->release();
        return (res == Steinberg::kResultOk);
    }

private:
    HMODULE m_module = nullptr;
    Steinberg::IPluginFactory* m_factory = nullptr;
    Steinberg::Vst::IComponent* m_component = nullptr;
    Steinberg::Vst::IAudioProcessor* m_processor = nullptr;
    Steinberg::Vst::IEditController* m_controller = nullptr;

    PluginMetadata m_meta;
    bool m_isLoaded = false;
    bool m_isActive = false;
    bool m_bypassed = false;
    double m_sampleRate = 48000.0;
    uint32_t m_maxBlockSize = 1024;

    std::thread m_editorThread;
    HWND m_editorHwnd = nullptr;
    std::atomic<bool> m_editorOpen{false};
};

//------------------------------------------------------------------------------
// PluginScanner
//------------------------------------------------------------------------------
std::vector<std::string> PluginScanner::getDefaultSearchPaths() {
    std::vector<std::string> paths;

    // 1. %CommonProgramFiles%\VST3
    char commonPf[MAX_PATH] = {0};
    if (GetEnvironmentVariableA("CommonProgramFiles", commonPf, MAX_PATH) > 0) {
        std::string vst3Path = std::string(commonPf) + "\\VST3";
        if (fs::exists(vst3Path)) paths.push_back(vst3Path);

        std::string clapPath = std::string(commonPf) + "\\CLAP";
        if (fs::exists(clapPath)) paths.push_back(clapPath);
    } else {
        if (fs::exists("C:\\Program Files\\Common Files\\VST3")) {
            paths.push_back("C:\\Program Files\\Common Files\\VST3");
        }
        if (fs::exists("C:\\Program Files\\Common Files\\CLAP")) {
            paths.push_back("C:\\Program Files\\Common Files\\CLAP");
        }
    }

    // 2. %LOCALAPPDATA%\Programs\Common\VST3 / CLAP
    char localApp[MAX_PATH] = {0};
    if (GetEnvironmentVariableA("LOCALAPPDATA", localApp, MAX_PATH) > 0) {
        std::string userVst3 = std::string(localApp) + "\\Programs\\Common\\VST3";
        if (fs::exists(userVst3)) paths.push_back(userVst3);

        std::string userClap = std::string(localApp) + "\\Programs\\Common\\CLAP";
        if (fs::exists(userClap)) paths.push_back(userClap);
    }

    return paths;
}

std::string PluginScanner::resolveBundleBinary(const std::string& bundlePath, PluginFormat format) {
    std::error_code ec;
    if (fs::is_directory(bundlePath, ec)) {
        if (format == PluginFormat::VST3) {
            fs::path subBinary = fs::path(bundlePath) / "Contents" / "x86_64-win";
            if (fs::exists(subBinary, ec)) {
                for (const auto& entry : fs::directory_iterator(subBinary, ec)) {
                    if (entry.path().extension() == ".vst3") {
                        return entry.path().string();
                    }
                }
            }
        } else if (format == PluginFormat::CLAP) {
            fs::path subBinary = fs::path(bundlePath) / "Contents" / "x86_64-win";
            if (fs::exists(subBinary, ec)) {
                for (const auto& entry : fs::directory_iterator(subBinary, ec)) {
                    if (entry.path().extension() == ".clap") {
                        return entry.path().string();
                    }
                }
            }
        }
        // It is a directory, but does not contain a supported plugin binary -> invalid
        return "";
    }
    return bundlePath;
}

bool PluginScanner::queryMetadata(const std::string& filePath, PluginFormat format, std::vector<PluginMetadata>& outPlugins) {
    std::string binaryPath = resolveBundleBinary(filePath, format);
    if (binaryPath.empty()) return false;
    std::wstring wpath = utf8ToWide(binaryPath);

    if (format == PluginFormat::CLAP) {
        HMODULE module = LoadLibraryExW(wpath.c_str(), NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!module) return false;

        bool success = false;
        try {
            auto entry = reinterpret_cast<const clap_plugin_entry_t*>(GetProcAddress(module, "clap_entry"));
            if (entry && entry->init && entry->init(filePath.c_str())) {
                auto factory = reinterpret_cast<const clap_plugin_factory_t*>(entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
                if (factory && factory->get_plugin_count) {
                    uint32_t count = factory->get_plugin_count(factory);
                    for (uint32_t i = 0; i < count; ++i) {
                        const clap_plugin_descriptor_t* d = factory->get_plugin_descriptor(factory, i);
                        if (!d) continue;
                        PluginMetadata meta;
                        meta.path = filePath;
                        meta.format = PluginFormat::CLAP;
                        meta.is64Bit = true;
                        meta.id = d->id ? d->id : "";
                        meta.name = d->name ? d->name : "";
                        meta.vendor = d->vendor ? d->vendor : "Unknown";
                        meta.version = d->version ? d->version : "1.0";
                        meta.category = d->description ? d->description : "AudioEffect";
                        outPlugins.push_back(meta);
                        success = true;
                    }
                }
                if (entry->deinit) entry->deinit();
            }
        } catch (...) {
            success = false;
        }
        FreeLibrary(module);
        return success;
    } else if (format == PluginFormat::VST3) {
        HMODULE module = LoadLibraryExW(wpath.c_str(), NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!module) return false;

        bool success = false;
        try {
            typedef Steinberg::IPluginFactory* (PLUGIN_API *GetFactoryFunc)();
            auto getFactory = reinterpret_cast<GetFactoryFunc>(GetProcAddress(module, "GetPluginFactory"));
            if (getFactory) {
                Steinberg::IPluginFactory* factory = getFactory();
                if (factory) {
                    Steinberg::int32 classCount = factory->countClasses();
                    Steinberg::IPluginFactory2* factory2 = nullptr;
                    factory->queryInterface(Steinberg::IPluginFactory2::iid, reinterpret_cast<void**>(&factory2));

                    for (Steinberg::int32 i = 0; i < classCount; ++i) {
                        Steinberg::PClassInfo classInfo;
                        if (factory->getClassInfo(i, &classInfo) != Steinberg::kResultOk) continue;

                        if (std::strcmp(classInfo.category, kVstAudioEffectClass) == 0) {
                            PluginMetadata meta;
                            meta.path = filePath;
                            meta.format = PluginFormat::VST3;
                            meta.is64Bit = true;
                            meta.id = cidToHexString(classInfo.cid);
                            meta.name = classInfo.name;
                            meta.vendor = "Unknown";
                            meta.version = "1.0";
                            meta.category = classInfo.category;

                            if (factory2) {
                                Steinberg::PClassInfo2 classInfo2;
                                if (factory2->getClassInfo2(i, &classInfo2) == Steinberg::kResultOk) {
                                    if (classInfo2.vendor[0]) meta.vendor = classInfo2.vendor;
                                    if (classInfo2.version[0]) meta.version = classInfo2.version;
                                    if (classInfo2.subCategories[0]) meta.category = classInfo2.subCategories;
                                }
                            }
                            outPlugins.push_back(meta);
                            success = true;
                        }
                    }

                    if (factory2) factory2->release();
                }
            }
        } catch (...) {
            success = false;
        }
        FreeLibrary(module);
        return success;
    }
    return false;
}

std::vector<PluginMetadata> PluginScanner::scan(const std::vector<std::string>& searchPaths, bool deepScan) {
    std::vector<PluginMetadata> results;

    for (const auto& dirPath : searchPaths) {
        if (!fs::exists(dirPath)) continue;

        try {
            for (auto it = fs::recursive_directory_iterator(dirPath, fs::directory_options::skip_permission_denied);
                 it != fs::recursive_directory_iterator(); ++it) {
                if (it.depth() > 6) {
                    it.pop();
                    continue;
                }
                const auto& entry = *it;
                std::string ext = entry.path().extension().string();
                std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

                PluginFormat format = PluginFormat::Unknown;
                if (ext == ".vst3") format = PluginFormat::VST3;
                else if (ext == ".clap") format = PluginFormat::CLAP;

                if (format == PluginFormat::Unknown) continue;

                // If this is a directory (like Bundle.vst3), resolve its binary or skip directory
                std::string pathStr;
                std::string nameStr;
                if (entry.is_directory()) {
                    it.disable_recursion_pending();
                    pathStr = resolveBundleBinary(entry.path().string(), format);
                    if (pathStr.empty()) {
                        // Directory ending with .vst3 but not a valid bundle, ignore
                        continue;
                    }
                    nameStr = entry.path().stem().string();
                } else {
                    pathStr = entry.path().string();
                    nameStr = entry.path().stem().string();
                }

                // Deduplicate by path
                bool duplicate = false;
                for (const auto& r : results) {
                    if (r.path == pathStr) { duplicate = true; break; }
                }
                if (duplicate) continue;

                if (deepScan) {
                    std::vector<PluginMetadata> deepMeta;
                    if (queryMetadata(pathStr, format, deepMeta)) {
                        for (const auto& m : deepMeta) {
                            results.push_back(m);
                        }
                    } else {
                        // Fallback to quick info
                        PluginMetadata quick;
                        quick.path = pathStr;
                        quick.name = nameStr;
                        quick.format = format;
                        quick.is64Bit = true;
                        quick.vendor = "Unknown";
                        quick.version = "1.0";
                        quick.category = "AudioEffect";
                        results.push_back(quick);
                    }
                } else {
                    // Quick scan
                    PluginMetadata quick;
                    quick.path = pathStr;
                    quick.name = nameStr;
                    quick.format = format;
                    quick.is64Bit = true;
                    quick.vendor = "Unknown";
                    quick.version = "1.0";
                    quick.category = "AudioEffect";
                    results.push_back(quick);
                }
            }
        } catch (...) {
            // Guard filesystem iteration exceptions
        }
    }

    return results;
}

//------------------------------------------------------------------------------
// PluginHostManager
//------------------------------------------------------------------------------
PluginHostManager::PluginHostManager() = default;

PluginHostManager::~PluginHostManager() {
    for (size_t s = 0; s < kMaxPluginSlots; ++s) {
        unloadPluginSlot(s);
    }
}

int PluginHostManager::scanPlugins(const std::string& extraDirsJson, bool deepScan) {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);

    std::vector<std::string> searchPaths = PluginScanner::getDefaultSearchPaths();
    // Parse extra dirs if provided
    if (!extraDirsJson.empty()) {
        std::istringstream iss(extraDirsJson);
        std::string path;
        while (std::getline(iss, path, ';')) {
            if (!path.empty() && fs::exists(path)) {
                searchPaths.push_back(path);
            }
        }
    }

    m_scannedPlugins = PluginScanner::scan(searchPaths, deepScan);
    return static_cast<int>(m_scannedPlugins.size());
}

size_t PluginHostManager::getScannedCount() const {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    return m_scannedPlugins.size();
}

std::string PluginHostManager::getScannedItemJson(size_t index) const {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (index >= m_scannedPlugins.size()) return "{}";
    return m_scannedPlugins[index].toJson();
}

std::string PluginHostManager::getAllScannedJson() const {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    std::ostringstream ss;
    ss << "[";
    for (size_t i = 0; i < m_scannedPlugins.size(); ++i) {
        if (i > 0) ss << ",";
        ss << m_scannedPlugins[i].toJson();
    }
    ss << "]";
    return ss.str();
}

void PluginHostManager::unloadPluginSlotLocked(size_t slot) {
    if (slot >= kMaxPluginSlots) return;
    PluginSlot& s = m_slots[slot];
    /* 关闭入口 → 等 RT 临界区排空 → 才允许销毁实例。
     * acquire 栅栏是必需的：它保证下面的 inFlight 读不会被重排到
     * hasActive=false 之前，从而堵住 Dekker 反例的最后一个窗口。 */
    s.hasActive.store(false, std::memory_order_release);
    s.destroyPending.store(true, std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_acquire);

    uint32_t spins = 0;
    while (s.inFlight.load(std::memory_order_relaxed) != 0 && spins < kQuiesceSpinLimit) {
        s.inFlight.wait(0, std::memory_order_relaxed);
        ++spins;
    }
    const bool quiesced = s.inFlight.load(std::memory_order_relaxed) == 0;
    s.destroyPending.store(false, std::memory_order_relaxed);

    /* 排空失败（RT 线程异常滞留）时宁可不释放：实例仍在槽内但 hasActive=false，
     * 后续 processSlot 会走直通分支，下次卸载会重试。保内存安全优先于保内存。 */
    if (!quiesced) return;

    s.latency.store(0, std::memory_order_relaxed);
    if (s.instance) {
        s.instance->closeEditor();
        s.instance->deactivate();
        s.instance->unload();
        s.instance.reset();
    }
}

void PluginHostManager::unloadPluginSlot(size_t slot) {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    unloadPluginSlotLocked(slot);
}

bool PluginHostManager::loadPluginSlot(size_t slot, const std::string& path, const std::string& pluginId, double sampleRate, uint32_t maxBlockSize) {
    if (slot >= kMaxPluginSlots) return false;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    try {
        unloadPluginSlotLocked(slot);

        m_sampleRate = sampleRate;
        m_maxBlockSize = maxBlockSize;

        std::string ext = fs::path(path).extension().string();
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

        PluginFormat format = PluginFormat::Unknown;
        if (ext == ".clap") format = PluginFormat::CLAP;
        else if (ext == ".vst3") format = PluginFormat::VST3;
        else return false;

        std::string resolvedBin = PluginScanner::resolveBundleBinary(path, format);
        if (resolvedBin.empty()) {
            return false;
        }

        std::unique_ptr<IPluginInstance> instance;
        if (format == PluginFormat::CLAP) {
            instance = std::make_unique<ClapPluginInstance>();
        } else if (format == PluginFormat::VST3) {
            instance = std::make_unique<Vst3PluginInstance>();
        } else {
            return false;
        }

        if (!instance->load(path, pluginId)) {
            return false;
        }

        if (!instance->activate(sampleRate, maxBlockSize)) {
            instance->unload();
            return false;
        }

        m_slots[slot].latency.store(instance->getLatency(), std::memory_order_relaxed);
        m_slots[slot].instance = std::move(instance);
        m_slots[slot].hasActive.store(true, std::memory_order_release);
        m_slots[slot].bypassed.store(false, std::memory_order_release);

        return true;
    } catch (...) {
        unloadPluginSlotLocked(slot);
        return false;
    }
}

void PluginHostManager::setBypassSlot(size_t slot, bool bypass) {
    if (slot >= kMaxPluginSlots) return;
    m_slots[slot].bypassed.store(bypass, std::memory_order_release);
    if (m_slots[slot].instance) {
        m_slots[slot].instance->setBypass(bypass);
    }
}

bool PluginHostManager::isBypassedSlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return true;
    return m_slots[slot].bypassed.load(std::memory_order_acquire);
}

uint32_t PluginHostManager::getLatencySlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return 0;
    return m_slots[slot].latency.load(std::memory_order_relaxed);
}

bool PluginHostManager::hasActivePluginSlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return false;
    return m_slots[slot].hasActive.load(std::memory_order_acquire);
}

std::string PluginHostManager::getStatusJsonSlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return "{}";
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    std::ostringstream ss;
    ss << "{"
       << "\"slot\":" << slot << ","
       << "\"hasActive\":" << (m_slots[slot].hasActive.load() ? "true" : "false") << ","
       << "\"bypassed\":" << (m_slots[slot].bypassed.load() ? "true" : "false") << ","
       << "\"latency\":" << m_slots[slot].latency.load() << ","
       << "\"insertStage\":" << m_slots[slot].insertStage.load() << ","
       << "\"isEditorOpen\":" << ((m_slots[slot].instance && m_slots[slot].instance->isEditorOpen()) ? "true" : "false") << ",";
    if (m_slots[slot].instance) {
        const auto& meta = m_slots[slot].instance->getMetadata();
        ss << "\"plugin\":" << meta.toJson();
    } else {
        ss << "\"plugin\":null";
    }
    ss << "}";
    return ss.str();
}

bool PluginHostManager::showEditorSlot(size_t slot) {
    if (slot >= kMaxPluginSlots) return false;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (m_slots[slot].instance && m_slots[slot].hasActive.load()) {
        return m_slots[slot].instance->showEditor();
    }
    return false;
}

void PluginHostManager::closeEditorSlot(size_t slot) {
    if (slot >= kMaxPluginSlots) return;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (m_slots[slot].instance) {
        m_slots[slot].instance->closeEditor();
    }
}

bool PluginHostManager::isEditorOpenSlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return false;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (m_slots[slot].instance && m_slots[slot].hasActive.load()) {
        return m_slots[slot].instance->isEditorOpen();
    }
    return false;
}

bool PluginHostManager::savePresetSlot(size_t slot, const std::string& filePath) {
    if (slot >= kMaxPluginSlots) return false;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (m_slots[slot].instance && m_slots[slot].hasActive.load()) {
        return m_slots[slot].instance->savePreset(filePath);
    }
    return false;
}

bool PluginHostManager::loadPresetSlot(size_t slot, const std::string& filePath) {
    if (slot >= kMaxPluginSlots) return false;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (m_slots[slot].instance && m_slots[slot].hasActive.load()) {
        return m_slots[slot].instance->loadPreset(filePath);
    }
    return false;
}

void PluginHostManager::setInsertStageSlot(size_t slot, int stage) {
    if (slot >= kMaxPluginSlots) return;
    if (stage < 0) stage = 0;
    if (stage > 4) stage = 4;
    m_slots[slot].insertStage.store(stage, std::memory_order_release);
}

int PluginHostManager::getInsertStageSlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return 3;
    return m_slots[slot].insertStage.load(std::memory_order_acquire);
}

void PluginHostManager::processSlot(size_t slot, float* const* inChannels, float* const* outChannels, uint32_t numFrames) {
    if (slot >= kMaxPluginSlots) return;
    PluginSlot& s = m_slots[slot];
    /* 先计入 RT 临界区，再读 hasActive。控制线程的卸载顺序是
     * 「hasActive=false → 等 inFlight==0 → 销毁」，两者构成无竞态握手：
     * 若本线程的 fetch_add 晚于控制线程的检查，本线程随后读到的
     * hasActive 必为 false（acq_rel 与 release store 建立了 happens-before），
     * 于是不会触碰已释放的实例。 */
    s.inFlight.fetch_add(1, std::memory_order_acq_rel);
    InFlightGuard guard(s.inFlight, s.destroyPending);

    if (!s.hasActive.load(std::memory_order_acquire) || s.bypassed.load(std::memory_order_acquire)) {
        if (inChannels != outChannels && inChannels && outChannels) {
            for (int ch = 0; ch < 2; ++ch) {
                if (inChannels[ch] && outChannels[ch]) {
                    std::memcpy(outChannels[ch], inChannels[ch], numFrames * sizeof(float));
                }
            }
        }
        return;
    }

    /* SEH/异常段已隔离到 processSlotGuarded（MSVC C2712：无析构函数才能用 __try） */
    if (processSlotGuarded(s, inChannels, outChannels, numFrames) != 0) {
        s.bypassed.store(true, std::memory_order_release);
    }
}

// Legacy single-slot forwards (slot 0)
bool PluginHostManager::loadPlugin(const std::string& path, const std::string& pluginId, double sampleRate, uint32_t maxBlockSize) {
    return loadPluginSlot(0, path, pluginId, sampleRate, maxBlockSize);
}

void PluginHostManager::unloadPlugin() {
    unloadPluginSlot(0);
}

void PluginHostManager::setBypass(bool bypass) {
    setBypassSlot(0, bypass);
}

bool PluginHostManager::isBypassed() const {
    return isBypassedSlot(0);
}

uint32_t PluginHostManager::getLatency() const {
    return getLatencySlot(0);
}

bool PluginHostManager::hasActivePlugin() const {
    return hasActivePluginSlot(0);
}

std::string PluginHostManager::getStatusJson() const {
    return getStatusJsonSlot(0);
}

void PluginHostManager::process(float* const* inChannels, float* const* outChannels, uint32_t numFrames) {
    processSlot(0, inChannels, outChannels, numFrames);
}

void PluginHostManager::updateFormat(double sampleRate, uint32_t maxBlockSize) {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    m_sampleRate = sampleRate;
    m_maxBlockSize = maxBlockSize;
    for (size_t s = 0; s < kMaxPluginSlots; ++s) {
        if (m_slots[s].instance && m_slots[s].hasActive.load()) {
            m_slots[s].instance->activate(sampleRate, maxBlockSize);
            m_slots[s].latency.store(m_slots[s].instance->getLatency(), std::memory_order_relaxed);
        }
    }
}

} // namespace auradsp
