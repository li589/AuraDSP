#include "plugin_host.h"
#include "auradsp_engine.h"
#include "clap_metadata.h"
#include "debug_log.h"
#include "module_pump.h"
#include "plugin_bundle.h"
#include "plugin_metadata_util.h"
#include "win32_util.h"

#include <clap/clap.h>
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace fs = std::filesystem;

namespace auradsp {
static uint32_t CLAP_ABI emptyInEventsSize(const clap_input_events_t*) { return 0; }
static const clap_event_header_t* CLAP_ABI emptyInEventsGet(const clap_input_events_t*, uint32_t) { return nullptr; }
static bool CLAP_ABI emptyOutEventsTryPush(const clap_output_events_t*, const clap_event_header_t*) { return true; }

class ClapPluginInstance : public IPluginInstance {
public:
    ClapPluginInstance() = default;
    ~ClapPluginInstance() override {
        // 兜底卸载（load 失败等提前析构路径）。unload 内部已释放共享泵引用
        // （C1：最后一实例时 PumpDeleter 负责停线程），故此处无需再停。
        unload();
    }

    bool load(const std::string& path, const std::string& pluginId,
              const PluginMetadata* scanSeed = nullptr) override {
        unload();
        setupPluginDllDirectories(path);

        m_meta = PluginMetadata{};
        if (scanSeed) seedMetadataFromScan(m_meta, *scanSeed);
        m_meta.path = path;
        m_meta.format = PluginFormat::CLAP;

        std::string arch;
        std::string binaryPath = resolvePluginBundleBinary(path, ".clap", &arch);
        if (binaryPath.empty()) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Invalid CLAP bundle or binary path";
            return false;
        }
        std::wstring wpath = utf8ToWide(binaryPath);
        // D2：is64Bit 由 PE 头判定，不再硬编码 true。32 位在 LoadLibrary 前
        // 明确拒绝——x64 进程加载 32 位 DLL 必然 ERROR_BAD_EXE_FORMAT(193)，
        // 旧实现只报 "Failed to load CLAP library: 193"，用户无法判断是架构问题。
        m_meta.is64Bit = peIs64Bit(wpath);
        if (!m_meta.is64Bit) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "32 位插件无法加载：AuraDSP 是 64 位进程，请安装 64 位版本";
            return false;
        }
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

        // B3-②（2026-10-12）：entry->init 及其后的插件实例化全部移入 CLAP
        // plugin main 线程。JUCE 系插件的 MessageManager 在 entry->init 首次
        // 触达并把 message thread 固定为"首触线程"——旧结构里那是 caller
        // （音频 isolate，不能泵消息），后续一切 GUI 调用因此死等或产出
        // 无泵子窗口（白框）。该线程同时承担本插件的 GUI 消息泵与全部
        // main-thread 任务，与 VST3 侧"attached 全在编辑器线程"的成功拓扑同构。
        //
        // C1（2026-10-12）：泵线程改为按模块共享（ModulePumpThread）——同一
        // DLL 被多槽挂载时 LoadLibrary 返回同一模块，两实例若各建一条线程，
        // JUCE MessageManager 归属互斥 → 死锁。此处按规范化二进制路径取得
        // （必要时新建）共享泵；引用计数归零（最后一实例卸载）时线程才停。
        m_moduleKey = normalizeModuleKey(wpath);
        m_pump = ModulePumpThread::acquire(m_moduleKey);
        if (!m_pump || !m_pump->isReady()) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "CLAP main thread failed to start";
            m_pump.reset();
            FreeLibrary(m_module);
            m_module = nullptr;
            m_entry = nullptr;
            return false;
        }

        std::string initErr;
        bool taskRan = m_pump->postTaskAndWait([&]() {
            if (!m_entry->init(path.c_str())) {
                initErr = "clap_entry->init() returned false";
                return;
            }

            m_factory = reinterpret_cast<const clap_plugin_factory_t*>(
                m_entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
            if (!m_factory) {
                initErr = "Failed to retrieve CLAP_PLUGIN_FACTORY_ID";
                m_entry->deinit();
                m_entry = nullptr;
                return;
            }

            uint32_t count = m_factory->get_plugin_count(m_factory);
            if (count == 0) {
                initErr = "CLAP factory reports 0 plugins";
                m_entry->deinit();
                m_entry = nullptr;
                return;
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
                // 与扫描路共用同一填充实现；scanSeed 已填的字段不会被覆盖。
                applyClapDescriptor(m_meta, targetDesc, wpath, path);
            }

            initHostStruct();
            m_plugin = m_factory->create_plugin(m_factory, &m_host, m_meta.id.c_str());
            if (!m_plugin) {
                initErr = "factory->create_plugin() returned null for ID: " + m_meta.id;
                m_entry->deinit();
                m_entry = nullptr;
                return;
            }

            if (!m_plugin->init(m_plugin)) {
                initErr = "plugin->init() failed";
                m_plugin->destroy(m_plugin);
                m_plugin = nullptr;
                m_entry->deinit();
                m_entry = nullptr;
                return;
            }
        }, 10000);
        if (!taskRan || !initErr.empty()) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = taskRan ? initErr : "CLAP main thread task timeout during load";
            if (!taskRan) {
                // 泵线程挂死于 init —— 隔离（放弃释放）而非 detach 后继续用本
                // 对象：登记废弃，由 manager 把整个实例移入静态隔离区。
                // m_pump 引用保留（不 reset）——挂死线程可能仍引用泵对象。
                m_threadAbandoned.store(true, std::memory_order_release);
                return false;
            }
            // init 正常返回错误：线程健康，先释放共享泵引用（可能顺带停线程），
            // 再卸载模块。与 VST3 侧失败路径对齐（B3 时 CLAP 漏了停线程）。
            m_pump.reset();
            FreeLibrary(m_module);
            m_module = nullptr;
            return false;
        }

        m_isLoaded = true;
        m_meta.isCompatible = true;
        return true;
    }

    void unload() override {
        // abandoned 守卫必须最先执行：泵线程挂死后仍卡在插件代码里，此处的
        // destroy/FreeLibrary 都会撞上它（卸载正在执行的 DLL = 0xC0000374）。
        // 整体跳过销毁，manager 据 abandoned() 把实例移入静态隔离区。
        if (m_threadAbandoned.load(std::memory_order_acquire)) {
            AURADSP_WARN("[DBG CLAP unload] WARNING: pump abandoned; skipping all teardown (quarantine)");
            m_isLoaded = false;
            return;
        }
        if (m_isLoaded) {
            AURADSP_DBG("[DBG CLAP unload] step 1: closeEditor");
            closeEditor();
            AURADSP_DBG("[DBG CLAP unload] step 2: deactivate");
            deactivate();
            // plugin->destroy + entry->deinit 移入 plugin main 线程（JUCE
            // message thread 所在线程；10-12 曾实证跨线程 destroy 死锁）。
            AURADSP_DBG("[DBG CLAP unload] step 3: destroy on clap main thread");
            bool destroyed = m_pump->postTaskAndWait([&]() {
                if (m_plugin) {
                    m_plugin->destroy(m_plugin);
                    m_plugin = nullptr;
                }
                if (m_entry) {
                    m_entry->deinit();
                    m_entry = nullptr;
                }
            }, 3000);
            if (!destroyed) {
                AURADSP_WARN("[DBG CLAP unload] WARNING: main thread unresponsive; quarantining instance");
                m_threadAbandoned.store(true, std::memory_order_release);
                return;   // manager 据此把实例移入静态隔离区（泄漏而非 UAF）
            }
            AURADSP_DBG("[DBG CLAP unload] step 3 done");
            m_isLoaded = false;
        }
        // C1：释放共享泵引用。若本实例是该模块最后一持有者，PumpDeleter 在此
        // 停线程（join 有界 3s，挂死则泄漏泵对象）；否则线程继续服务其他槽位
        // 的同插件实例。必须在 FreeLibrary 之前——确保卸载 DLL 时其中代码
        // 已无人执行。
        m_pump.reset();
        if (m_module) {
            AURADSP_DBG("[DBG CLAP unload] step 5: FreeLibrary");
            FreeLibrary(m_module);
            AURADSP_DBG("[DBG CLAP unload] step 5 done");
            m_module = nullptr;
        }
        m_isLoaded = false;
        AURADSP_DBG("[DBG CLAP unload] complete");
    }

    bool activate(double sampleRate, uint32_t maxBlockSize) override {
        if (!m_isLoaded || !m_plugin) return false;
        if (m_isActive) deactivate();

        m_sampleRate = sampleRate;
        m_maxBlockSize = maxBlockSize;

        m_numInputPorts = 0;
        m_numOutputPorts = 0;
        m_inPortChannels.clear();
        m_outPortChannels.clear();
        m_inBufs.clear();
        m_outBufs.clear();
        m_auxInBuffers.clear();
        m_auxInPtrs.clear();
        m_auxOutBuffers.clear();
        m_auxOutPtrs.clear();

        const auto* ports = reinterpret_cast<const clap_plugin_audio_ports_t*>(
            m_plugin->get_extension(m_plugin, CLAP_EXT_AUDIO_PORTS));
        m_mainInPort = 0;
        m_mainOutPort = 0;
        if (ports && ports->count && ports->get) {
            m_numInputPorts = std::min<uint32_t>(ports->count(m_plugin, true), 32u);
            m_numOutputPorts = std::min<uint32_t>(ports->count(m_plugin, false), 32u);
            m_inPortChannels.assign(m_numInputPorts, 0);
            m_outPortChannels.assign(m_numOutputPorts, 0);
            for (uint32_t i = 0; i < m_numInputPorts; ++i) {
                clap_audio_port_info_t info = {};
                if (ports->get(m_plugin, i, true, &info)) {
                    m_inPortChannels[i] = info.channel_count;
                    if (info.flags & CLAP_AUDIO_PORT_IS_MAIN) m_mainInPort = i;
                }
            }
            for (uint32_t i = 0; i < m_numOutputPorts; ++i) {
                clap_audio_port_info_t info = {};
                if (ports->get(m_plugin, i, false, &info)) {
                    m_outPortChannels[i] = info.channel_count;
                    if (info.flags & CLAP_AUDIO_PORT_IS_MAIN) m_mainOutPort = i;
                }
            }
        } else {
            m_numInputPorts = 1;
            m_numOutputPorts = 1;
            m_inPortChannels.assign(1, 2);
            m_outPortChannels.assign(1, 2);
        }

        m_inChannels = m_numInputPorts > 0
                           ? std::clamp<uint32_t>(m_inPortChannels[m_mainInPort], 1u, 2u)
                           : 0;
        m_outChannels = m_numOutputPorts > 0
                            ? std::clamp<uint32_t>(m_outPortChannels[m_mainOutPort], 1u, 2u)
                            : 0;

        m_inBufs.assign(m_numInputPorts, clap_audio_buffer_t{});
        m_outBufs.assign(m_numOutputPorts, clap_audio_buffer_t{});
        m_auxInBuffers.assign(m_numInputPorts, {});
        m_auxInPtrs.assign(m_numInputPorts, {});
        m_auxOutBuffers.assign(m_numOutputPorts, {});
        m_auxOutPtrs.assign(m_numOutputPorts, {});
        for (uint32_t i = 0; i < m_numInputPorts; ++i) {
            if (i == m_mainInPort) continue;
            const uint32_t ch = std::min<uint32_t>(m_inPortChannels[i], 16u);
            if (ch == 0) continue;
            m_auxInBuffers[i].assign(ch, std::vector<float>(maxBlockSize, 0.0f));
            m_auxInPtrs[i].resize(ch);
            for (uint32_t c = 0; c < ch; ++c) m_auxInPtrs[i][c] = m_auxInBuffers[i][c].data();
        }
        for (uint32_t i = 0; i < m_numOutputPorts; ++i) {
            if (i == m_mainOutPort) continue;
            const uint32_t ch = std::min<uint32_t>(m_outPortChannels[i], 16u);
            if (ch == 0) continue;
            m_auxOutBuffers[i].assign(ch, std::vector<float>(maxBlockSize, 0.0f));
            m_auxOutPtrs[i].resize(ch);
            for (uint32_t c = 0; c < ch; ++c) m_auxOutPtrs[i][c] = m_auxOutBuffers[i][c].data();
        }

        m_busInfo = PluginBusInfo{};
        m_busInfo.inputBuses = static_cast<int>(m_numInputPorts);
        m_busInfo.outputBuses = static_cast<int>(m_numOutputPorts);
        m_busInfo.mainInChannels = static_cast<int>(m_inChannels);
        m_busInfo.mainOutChannels = static_cast<int>(m_outChannels);
        for (uint32_t i = 0; i < m_numInputPorts; ++i) {
            if (i != m_mainInPort && m_inPortChannels[i] > 0) ++m_busInfo.auxInputBuses;
        }
        for (uint32_t i = 0; i < m_numOutputPorts; ++i) {
            if (i != m_mainOutPort && m_outPortChannels[i] > 0) ++m_busInfo.auxOutputBuses;
        }

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
        t_pluginThreadRole = PluginThreadRole::Audio;
        m_audioThreadId.store(std::this_thread::get_id(), std::memory_order_relaxed);
        if (numFrames == 0) {
            t_pluginThreadRole = PluginThreadRole::Main;
            return;
        }
        if (!inChannels || !outChannels) {
            t_pluginThreadRole = PluginThreadRole::Main;
            return;
        }

        // 引擎链恒送立体声；主端口声道数在此裁剪，辅助端口按插件声明补偿。
        const int32_t nc = 2;
        for (int32_t ch = 0; ch < nc; ++ch) {
            if (!inChannels[ch] || !outChannels[ch]) {
                t_pluginThreadRole = PluginThreadRole::Main;
                return;
            }
        }

        if (!m_isActive || !m_plugin || m_bypassed) {
            if (inChannels != outChannels) {
                for (int32_t ch = 0; ch < nc; ++ch) {
                    std::memcpy(outChannels[ch], inChannels[ch], numFrames * sizeof(float));
                }
            }
            t_pluginThreadRole = PluginThreadRole::Main;
            return;
        }

        for (uint32_t p = 0; p < m_numInputPorts; ++p) {
            clap_audio_buffer_t& buf = m_inBufs[p];
            buf = {};
            if (p == m_mainInPort) {
                buf.data32 = (float**)inChannels;
                buf.channel_count = m_inChannels;
            } else if (!m_auxInPtrs[p].empty()) {
                for (auto& chBuf : m_auxInBuffers[p]) {
                    std::fill_n(chBuf.begin(),
                                std::min<size_t>(numFrames, chBuf.size()), 0.0f);
                }
                buf.data32 = m_auxInPtrs[p].data();
                buf.channel_count = static_cast<uint32_t>(m_auxInPtrs[p].size());
            }
        }
        for (uint32_t p = 0; p < m_numOutputPorts; ++p) {
            clap_audio_buffer_t& buf = m_outBufs[p];
            buf = {};
            if (p == m_mainOutPort) {
                buf.data32 = (float**)outChannels;
                buf.channel_count = m_outChannels;
            } else if (!m_auxOutPtrs[p].empty()) {
                buf.data32 = m_auxOutPtrs[p].data();
                buf.channel_count = static_cast<uint32_t>(m_auxOutPtrs[p].size());
            }
        }

        clap_event_transport_t transport = {};
        transport.header.size = sizeof(transport);
        transport.header.type = CLAP_EVENT_TRANSPORT;
        transport.header.time = 0;
        transport.flags = CLAP_TRANSPORT_IS_PLAYING | CLAP_TRANSPORT_HAS_TEMPO | CLAP_TRANSPORT_HAS_TIME_SIGNATURE;
        transport.tempo = 120.0;
        transport.tsig_num = 4;
        transport.tsig_denom = 4;

        clap_input_events_t emptyIn = { nullptr, emptyInEventsSize, emptyInEventsGet };
        clap_output_events_t emptyOut = { nullptr, emptyOutEventsTryPush };

        clap_process_t proc = {};
        proc.steady_time = -1;
        proc.frames_count = numFrames;
        proc.transport = &transport;
        proc.audio_inputs = m_inBufs.empty() ? nullptr : m_inBufs.data();
        proc.audio_inputs_count = m_numInputPorts;
        proc.audio_outputs = m_outBufs.empty() ? nullptr : m_outBufs.data();
        proc.audio_outputs_count = m_numOutputPorts;
        proc.in_events = &emptyIn;
        proc.out_events = &emptyOut;

        clap_process_status status = m_plugin->process(m_plugin, &proc);
        if (status == CLAP_PROCESS_ERROR) {
            // Bypass on error
            m_bypassed = true;
        }
        if (m_outChannels == 1 && outChannels[1]) {
            std::memcpy(outChannels[1], outChannels[0], numFrames * sizeof(float));
        }
        t_pluginThreadRole = PluginThreadRole::Main;
    }

    bool isLoaded() const override { return m_isLoaded; }
    bool isBypassed() const override { return m_bypassed; }
    void setBypass(bool bypass) override { m_bypassed = bypass; }
    uint32_t getLatency() const override { return m_meta.latency; }
    const PluginMetadata& getMetadata() const override { return m_meta; }
    PluginBusInfo busInfo() const override { return m_busInfo; }

    bool showEditor(const std::string& title = "") override {
        if (!m_isLoaded || !m_plugin) return false;
        m_editorTitle = title;
        if (m_editorOpen.load(std::memory_order_acquire) && m_editorHwnd && IsWindow(m_editorHwnd)) {
            SetForegroundWindow(m_editorHwnd);
            ShowWindow(m_editorHwnd, SW_SHOW);
            return true;
        }
        if (!m_pump || !m_pump->isReady()) return false;

        // B3-②：create/get_size/容器/set_parent/show 全部在 plugin main 线程
        // （= JUCE message thread = 泵线程）执行。子窗口因此归泵线程所有，
        // WM_PAINT/输入由泵分发——白框与拖动无响应的根因（子窗口落在无泵
        // 的 caller 线程，拓扑探针 tid 实证）就此消除。caller 只等待有界
        // 结果，不参与 JUCE 锁竞争。
        bool ok = false;
        bool done = m_pump->postTaskAndWait([&]() { ok = showEditorOnMainThread(); }, 5000);
        if (!done) {
            AURADSP_WARN("[DBG CLAP showEditor] WARNING: editor task timed out; quarantining");
            m_threadAbandoned.store(true, std::memory_order_release);
            return false;
        }
        return ok;
    }

    // showEditor 的实体（在 CLAP plugin main 线程内执行）。
    bool showEditorOnMainThread() {
        auto gui = reinterpret_cast<const clap_plugin_gui_t*>(
            m_plugin->get_extension(m_plugin, CLAP_EXT_GUI));
        if (!gui) return false;
        if (!gui->is_api_supported || !gui->is_api_supported(m_plugin, CLAP_WINDOW_API_WIN32, false)) {
            return false;
        }

        AURADSP_DBG("[DBG CLAP showEditor] main thread: gui->create...");
        bool createRes = false;
        try {
            createRes = gui->create(m_plugin, CLAP_WINDOW_API_WIN32, false);
        } catch (const std::exception& ex) {
            AURADSP_WARN_S("[DBG CLAP showEditor] gui->create exception: " << ex.what());
        } catch (...) {
            AURADSP_WARN("[DBG CLAP showEditor] gui->create unknown exception!");
        }
        AURADSP_DBG_S("[DBG CLAP showEditor] gui->create returned: " << createRes);
        if (!createRes) return false;
        m_guiCreated.store(true, std::memory_order_release);

        uint32_t width = 800, height = 600;
        if (gui->get_size) {
            try {
                gui->get_size(m_plugin, &width, &height);
            } catch (...) {}
        }
        if (width < 200) width = 800;
        if (height < 150) height = 600;

        EnsureClapWindowClassRegistered();

        // E1：标题由调用方决定；为空时退化到插件自报名。
        // 历史版本硬编码 L"[AuraDSP] " 前缀，Dart 侧构造的
        // "<name> - AuraDSP Host" 标题从未生效（C ABI 丢弃第三参）。
        std::wstring title = utf8ToWide(m_editorTitle.empty() ? m_meta.name : m_editorTitle);
        RECT rc = {0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
        DWORD style = WS_OVERLAPPEDWINDOW;
        AdjustWindowRect(&rc, style, FALSE);
        HWND hwnd = CreateWindowExW(
            0, L"AuraDSP_CLAP_Host_Window", title.c_str(),
            style, CW_USEDEFAULT, CW_USEDEFAULT,
            rc.right - rc.left, rc.bottom - rc.top,
            NULL, NULL, GetModuleHandleW(NULL), NULL);
        if (!hwnd) {
            // C1 修复记录：CreateWindow 失败时 gui->create 已成功，必须就地
            // destroy 回收插件 GUI，否则插件持有一个无父窗口的 GUI——后续
            // gui->destroy 在该状态下可能挂死（close 任务超时 → 实例被隔离）。
            AURADSP_WARN_S("[DBG CLAP showEditor] CreateWindowExW failed, err=" << GetLastError());
            if (m_guiCreated.exchange(false, std::memory_order_acq_rel) && gui) {
                try { if (gui->hide) gui->hide(m_plugin); } catch (...) {}
                try { if (gui->destroy) gui->destroy(m_plugin); } catch (...) {}
            }
            return false;
        }

        m_editorHwnd = hwnd;
        m_editorOpen.store(true, std::memory_order_release);
        // C1：实例指针挂到容器窗口，WM_CLOSE 经 WndProc 分发回本实例
        // （onEditorWmClose）；同时向共享泵登记，泵异常退出时兜底销毁。
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
        m_pump->registerEditor(hwnd);
        AURADSP_DBG_S("[DBG CLAP showEditor] hwnd created: " << hwnd);

        ShowWindow(hwnd, SW_SHOW);

        // [2] set_parent + show 在本线程（== 容器线程 == 泵线程）：
        //     插件子窗口由本线程创建，其 WM_PAINT/输入由本线程泵分发。
        clap_window_t win = {};
        win.api = CLAP_WINDOW_API_WIN32;
        win.win32 = hwnd;
        AURADSP_DBG("[DBG CLAP showEditor] main thread: calling gui->set_parent...");
        bool setParentRes = false;
        try {
            if (gui->set_parent) setParentRes = gui->set_parent(m_plugin, &win);
        } catch (const std::exception& ex) {
            AURADSP_WARN_S("[DBG CLAP showEditor] gui->set_parent exception: " << ex.what());
        } catch (...) {
            AURADSP_WARN("[DBG CLAP showEditor] gui->set_parent unknown exception!");
        }
        AURADSP_DBG_S("[DBG CLAP showEditor] gui->set_parent returned: " << setParentRes);
        try {
            if (gui->show) gui->show(m_plugin);
        } catch (...) {}
        UpdateWindow(hwnd);

        // C4：部分插件在 set_parent/show 之后才布局出真实尺寸（iZotope RX
        // 系列为代表），所以再取一次并同步容器与子窗口；异步布局的插件由
        // 尺寸稳定化定时器继续校正。
        if (setParentRes) pollEditorSizeClap(gui, width, height);
        resetSettleTicks();
        SetTimer(hwnd, kSizeSettleTimerId, 100, nullptr);

        auto timerExt = reinterpret_cast<const clap_plugin_timer_support_t*>(
            m_plugin->get_extension(m_plugin, CLAP_EXT_TIMER_SUPPORT));

        // Attach any previously registered timers to this new HWND
        {
            std::lock_guard<std::mutex> lock(m_timerMutex);
            for (auto& pair : m_timers) {
                UINT_PTR wid = SetTimer(hwnd, static_cast<UINT_PTR>(pair.first), 20, NULL);
                if (wid != 0) {
                    pair.second = wid;
                    m_timerIdMap[wid] = pair.first;
                }
            }
        }

        return setParentRes;
    }

    // C4：取 CLAP 插件自报尺寸；与当前容器不同且合理即同步容器
    // （其后的 WM_SIZE 由 WndProc 把子窗口铺满客户区）。泵线程上调用。
    void pollEditorSizeClap(const clap_plugin_gui_t* gui, uint32_t& curW, uint32_t& curH) {
        if (!gui || !m_editorHwnd || !IsWindow(m_editorHwnd)) return;
        uint32_t w = 0, h = 0;
        if (!gui->get_size) return;
        try {
            if (!gui->get_size(m_plugin, &w, &h)) return;
        } catch (...) { return; }
        // 合理性下限：太低视为"尚未布局"，不采信。
        if (w < 100 || h < 80) return;
        if (w == curW && h == curH) return;
        curW = w;
        curH = h;
        RECT nrc = {0, 0, static_cast<LONG>(w), static_cast<LONG>(h)};
        DWORD style = static_cast<DWORD>(GetWindowLongW(m_editorHwnd, GWL_STYLE));
        AdjustWindowRect(&nrc, style, FALSE);
        SetWindowPos(m_editorHwnd, NULL, 0, 0,
                     nrc.right - nrc.left, nrc.bottom - nrc.top,
                     SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    // C4：容器定时器回调入口（泵线程，见 IPluginInstance::pollEditorSize）。
    void pollEditorSize() override {
        if (!m_editorHwnd || !IsWindow(m_editorHwnd)) return;
        uint32_t w = 0, h = 0;
        RECT rc;
        if (GetClientRect(m_editorHwnd, &rc)) {
            w = static_cast<uint32_t>(rc.right - rc.left);
            h = static_cast<uint32_t>(rc.bottom - rc.top);
        }
        auto gui = reinterpret_cast<const clap_plugin_gui_t*>(
            m_plugin->get_extension(m_plugin, CLAP_EXT_GUI));
        if (gui) pollEditorSizeClap(gui, w, h);
    }

    // C4：容器 WM_SIZE（泵线程）。CLAP 规范——宿主直接把子窗口 resize 到
    // 客户区。这是"拉大框后多出来的是空白"的根治点。
    void onEditorResize() override {
        if (!m_editorHwnd || !IsWindow(m_editorHwnd)) return;
        ResizeDirectChildren(m_editorHwnd);
    }

    static void safeHideAndDestroyClapGui(const clap_plugin_gui_t* gui, const clap_plugin_t* plugin) {
        if (!gui || !plugin) return;
#if defined(_MSC_VER)
        __try { if (gui->hide) gui->hide(plugin); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        __try { if (gui->destroy) gui->destroy(plugin); } __except (EXCEPTION_EXECUTE_HANDLER) {}
#else
        try { if (gui->hide) gui->hide(plugin); } catch (...) {}
        try { if (gui->destroy) gui->destroy(plugin); } catch (...) {}
#endif
    }

    // closeEditor 的实体（在 CLAP plugin main 线程内执行）。
    void closeEditorOnMainThread() {
        auto gui = m_plugin ? reinterpret_cast<const clap_plugin_gui_t*>(
            m_plugin->get_extension(m_plugin, CLAP_EXT_GUI)) : nullptr;
        HWND hwnd = m_editorHwnd;
        // C4：卸尺寸稳定化定时器（走本路径时不经过 WM_CLOSE）。
        if (hwnd) KillTimer(hwnd, kSizeSettleTimerId);
        // 宿主侧定时器登记先清（窗口即将销毁）。
        {
            std::lock_guard<std::mutex> lock(m_timerMutex);
            for (auto& pair : m_timers) {
                if (hwnd && IsWindow(hwnd)) KillTimer(hwnd, pair.second);
            }
            m_timerIdMap.clear();
        }
        // gui->hide/destroy 在本线程执行 —— 与 gui->create 同线程
        // （JUCE message thread），MessageManagerLock 无竞争（B3-② 重构，
        // 推翻 10-12「hide/destroy 必须在 caller」的结论——那个结论成立的
        // 前提是 create 在 caller 线程）。m_guiCreated 交换守卫防双执行。
        if (m_guiCreated.exchange(false, std::memory_order_acq_rel) && gui) {
            safeHideAndDestroyClapGui(gui, m_plugin);
        }
        if (hwnd) {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            if (m_pump) m_pump->unregisterEditor(hwnd);
            if (IsWindow(hwnd)) DestroyWindow(hwnd);
        }
        m_editorHwnd = nullptr;
        m_editorOpen.store(false, std::memory_order_release);
        AURADSP_DBG("[DBG CLAP closeEditor] closed on main thread");
    }

    // C1：用户点编辑器窗口 X —— WndProc 在泵线程上分发到此。已在 plugin
    // main 线程，直接执行收尾（与 gui->create 同线程，无锁竞争）。
    void onEditorWmClose() override {
        closeEditorOnMainThread();
    }

    void closeEditor() override {
        AURADSP_DBG("[DBG CLAP closeEditor] enter");
        if (!m_pump || !m_pump->isReady()) {
            m_editorOpen.store(false, std::memory_order_release);
            AURADSP_WARN("[DBG CLAP closeEditor] no clap main thread; skip");
            return;
        }
        bool done = m_pump->postTaskAndWait([&]() { closeEditorOnMainThread(); }, 3000);
        if (!done) {
            AURADSP_WARN("[DBG CLAP closeEditor] WARNING: close task timed out; quarantining");
            m_threadAbandoned.store(true, std::memory_order_release);
        }
        AURADSP_DBG("[DBG CLAP closeEditor] exit");
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
        if (!m_pump || !m_pump->isReady()) return false;
        // CLAP state 属 main-thread 操作；JUCE 系插件可能触达 MessageManager，
        // 一律移入 plugin main 线程执行。
        bool ok = false;
        bool done = m_pump->postTaskAndWait([&]() {
            auto stateExt = reinterpret_cast<const clap_plugin_state_t*>(
                m_plugin->get_extension(m_plugin, CLAP_EXT_STATE));
            if (!stateExt || !stateExt->save) return;

            fs::path p(filePath);
            if (p.has_parent_path() && !fs::exists(p.parent_path())) {
                fs::create_directories(p.parent_path());
            }

            std::ofstream ofs(filePath, std::ios::binary);
            if (!ofs) return;
            ClapOstreamContext ctx{&ofs};
            clap_ostream_t ostream = { &ctx, clapOstreamWrite };
            ok = stateExt->save(m_plugin, &ostream);
        }, 5000);
        return done && ok;
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
        if (!m_pump || !m_pump->isReady()) return false;
        // 同 savePreset：CLAP state 属 main-thread 操作，移入 plugin main 线程。
        bool ok = false;
        bool done = m_pump->postTaskAndWait([&]() {
            auto stateExt = reinterpret_cast<const clap_plugin_state_t*>(
                m_plugin->get_extension(m_plugin, CLAP_EXT_STATE));
            if (!stateExt || !stateExt->load) return;

            std::ifstream ifs(filePath, std::ios::binary);
            if (!ifs) return;
            ClapIstreamContext ctx{&ifs};
            clap_istream_t istream = { &ctx, clapIstreamRead };
            ok = stateExt->load(m_plugin, &istream);
        }, 5000);
        return done && ok;
    }

    bool abandoned() const override {
        return m_threadAbandoned.load(std::memory_order_acquire);
    }

private:
    void initHostStruct() {
        m_mainThreadId = std::this_thread::get_id();

        m_host.clap_version = CLAP_VERSION;
        m_host.host_data = this;
        m_host.name = "AuraDSP";
        m_host.vendor = "AuraDSP Audio Engine";
        m_host.url = "https://github.com/li589/AuraDSP";
        m_host.version = auradsp_version();  // B-5：单源 AURADSP_VERSION（不再硬编码 1.0.0）
        m_host.get_extension = hostGetExtension;
        m_host.request_restart = hostRequestRestart;
        m_host.request_process = hostRequestProcess;
        m_host.request_callback = hostRequestCallback;

        // Initialize CLAP host extensions
        m_hostThreadCheck.is_main_thread = hostThreadCheckIsMain;
        m_hostThreadCheck.is_audio_thread = hostThreadCheckIsAudio;

        m_hostTimerSupport.register_timer = hostTimerRegister;
        m_hostTimerSupport.unregister_timer = hostTimerUnregister;

        m_hostGui.resize_hints_changed = hostGuiResizeHintsChanged;
        m_hostGui.request_resize = hostGuiRequestResize;
        m_hostGui.request_show = hostGuiRequestShow;
        m_hostGui.request_hide = hostGuiRequestHide;
        m_hostGui.closed = hostGuiClosed;

        m_hostLatency.changed = hostLatencyChanged;
        m_hostState.mark_dirty = hostStateMarkDirty;
        m_hostLog.log = hostLog;
    }

    static bool CLAP_ABI hostThreadCheckIsMain(const clap_host_t* host) {
        return t_pluginThreadRole != PluginThreadRole::Audio;
    }

    static bool CLAP_ABI hostThreadCheckIsAudio(const clap_host_t* host) {
        return t_pluginThreadRole == PluginThreadRole::Audio;
    }

    static bool CLAP_ABI hostTimerRegister(const clap_host_t* host, uint32_t period_ms, clap_id* timer_id) {
        if (!host || !host->host_data || !timer_id) return false;
        auto* self = static_cast<ClapPluginInstance*>(host->host_data);
        std::lock_guard<std::mutex> lock(self->m_timerMutex);
        clap_id tid = self->m_nextTimerId++;
        *timer_id = tid;
        UINT period = (period_ms < 10) ? 10 : period_ms;
        if (self->m_editorHwnd && IsWindow(self->m_editorHwnd)) {
            UINT_PTR wid = SetTimer(self->m_editorHwnd, static_cast<UINT_PTR>(tid), period, NULL);
            if (wid != 0) {
                self->m_timers[tid] = wid;
                self->m_timerIdMap[wid] = tid;
                return true;
            }
        }
        self->m_timers[tid] = static_cast<UINT_PTR>(tid);
        return true;
    }

    static bool CLAP_ABI hostTimerUnregister(const clap_host_t* host, clap_id timer_id) {
        if (!host || !host->host_data) return false;
        auto* self = static_cast<ClapPluginInstance*>(host->host_data);
        std::lock_guard<std::mutex> lock(self->m_timerMutex);
        auto it = self->m_timers.find(timer_id);
        if (it != self->m_timers.end()) {
            if (self->m_editorHwnd && IsWindow(self->m_editorHwnd)) {
                KillTimer(self->m_editorHwnd, it->second);
            }
            self->m_timerIdMap.erase(it->second);
            self->m_timers.erase(it);
            return true;
        }
        return false;
    }

    static void CLAP_ABI hostGuiResizeHintsChanged(const clap_host_t* host) {}

    static bool CLAP_ABI hostGuiRequestResize(const clap_host_t* host, uint32_t width, uint32_t height) {
        if (!host || !host->host_data) return false;
        auto* self = static_cast<ClapPluginInstance*>(host->host_data);
        if (self->m_editorHwnd && IsWindow(self->m_editorHwnd)) {
            RECT rc = {0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
            DWORD style = GetWindowLongW(self->m_editorHwnd, GWL_STYLE);
            AdjustWindowRect(&rc, style, FALSE);
            SetWindowPos(self->m_editorHwnd, NULL, 0, 0, rc.right - rc.left, rc.bottom - rc.top,
                         SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            return true;
        }
        return false;
    }

    static bool CLAP_ABI hostGuiRequestShow(const clap_host_t* host) {
        if (!host || !host->host_data) return false;
        auto* self = static_cast<ClapPluginInstance*>(host->host_data);
        if (self->m_editorHwnd && IsWindow(self->m_editorHwnd)) {
            ShowWindow(self->m_editorHwnd, SW_SHOW);
            return true;
        }
        return false;
    }

    static bool CLAP_ABI hostGuiRequestHide(const clap_host_t* host) {
        if (!host || !host->host_data) return false;
        auto* self = static_cast<ClapPluginInstance*>(host->host_data);
        if (self->m_editorHwnd && IsWindow(self->m_editorHwnd)) {
            ShowWindow(self->m_editorHwnd, SW_HIDE);
            return true;
        }
        return false;
    }

    static void CLAP_ABI hostGuiClosed(const clap_host_t* host, bool was_destroyed) {
        if (!host || !host->host_data) return;
        auto* self = static_cast<ClapPluginInstance*>(host->host_data);
        self->m_editorOpen.store(false, std::memory_order_release);
    }

    static void CLAP_ABI hostLatencyChanged(const clap_host_t* host) {
        if (!host || !host->host_data) return;
        auto* self = static_cast<ClapPluginInstance*>(host->host_data);
        if (self->m_plugin) {
            auto latExt = reinterpret_cast<const clap_plugin_latency_t*>(
                self->m_plugin->get_extension(self->m_plugin, CLAP_EXT_LATENCY));
            if (latExt && latExt->get) {
                self->m_meta.latency = latExt->get(self->m_plugin);
            }
        }
    }

    static void CLAP_ABI hostStateMarkDirty(const clap_host_t* host) {}
    static void CLAP_ABI hostLog(const clap_host_t* host, clap_log_severity severity, const char* msg) {}

    static const void* CLAP_ABI hostGetExtension(const struct clap_host* host, const char* extension_id) {
        if (!host || !host->host_data || !extension_id) return nullptr;
        auto* self = static_cast<ClapPluginInstance*>(host->host_data);
        if (std::strcmp(extension_id, CLAP_EXT_THREAD_CHECK) == 0) {
            return &self->m_hostThreadCheck;
        }
        if (std::strcmp(extension_id, CLAP_EXT_TIMER_SUPPORT) == 0) {
            return &self->m_hostTimerSupport;
        }
        if (std::strcmp(extension_id, CLAP_EXT_GUI) == 0) {
            return &self->m_hostGui;
        }
        if (std::strcmp(extension_id, CLAP_EXT_LATENCY) == 0) {
            return &self->m_hostLatency;
        }
        if (std::strcmp(extension_id, CLAP_EXT_STATE) == 0) {
            return &self->m_hostState;
        }
        if (std::strcmp(extension_id, CLAP_EXT_LOG) == 0) {
            return &self->m_hostLog;
        }
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

    clap_host_thread_check_t m_hostThreadCheck = {};
    clap_host_timer_support_t m_hostTimerSupport = {};
    clap_host_gui_t m_hostGui = {};
    clap_host_latency_t m_hostLatency = {};
    clap_host_state_t m_hostState = {};
    clap_host_log_t m_hostLog = {};

    std::thread::id m_mainThreadId;
    std::atomic<std::thread::id> m_audioThreadId{};

    std::mutex m_timerMutex;
    std::unordered_map<clap_id, UINT_PTR> m_timers;
    std::unordered_map<UINT_PTR, clap_id> m_timerIdMap;
    clap_id m_nextTimerId = 1;

    PluginMetadata m_meta;
    bool m_isLoaded = false;
    bool m_isActive = false;
    bool m_bypassed = false;
    double m_sampleRate = 48000.0;
    uint32_t m_maxBlockSize = 1024;

    uint32_t m_numInputPorts = 0;
    uint32_t m_numOutputPorts = 0;
    uint32_t m_mainInPort = 0;
    uint32_t m_mainOutPort = 0;
    uint32_t m_inChannels = 0;
    uint32_t m_outChannels = 0;
    std::vector<int32_t> m_inPortChannels;
    std::vector<int32_t> m_outPortChannels;
    std::vector<clap_audio_buffer_t> m_inBufs;
    std::vector<clap_audio_buffer_t> m_outBufs;
    std::vector<std::vector<std::vector<float>>> m_auxInBuffers;
    std::vector<std::vector<float*>> m_auxInPtrs;
    std::vector<std::vector<std::vector<float>>> m_auxOutBuffers;
    std::vector<std::vector<float*>> m_auxOutPtrs;
    PluginBusInfo m_busInfo;

    // ---- 共享 plugin main 线程（C1 2026-10-12，按模块共享）----
    // B3 时为每实例一条线程；C1 多槽挂载同一 DLL 时 LoadLibrary 返回同一
    // 模块，两实例各建线程会互斥 JUCE MessageManager 归属 → 死锁，故改为
    // 按规范化二进制路径共享（ModulePumpThread::acquire），引用计数归零时
    // 线程才停。m_moduleKey 仅供诊断/对称性保留，acquire 的 key 即由它派生。
    std::shared_ptr<ModulePumpThread> m_pump;
    std::string m_moduleKey;
    // 线程挂死（任务超时）时置位：manager 据此把整个实例移入静态隔离区，
    // 而不是析构它（挂死线程仍引用 this，析构 = use-after-free）。
    std::atomic<bool> m_threadAbandoned{false};

    HWND m_editorHwnd = nullptr;
    // E1：调用方（Dart）传来的窗口标题。写入发生在任务提交之前，任务
    // 提交/执行的同步构成 happens-before，无竞争；
    // 为空时退化为 m_meta.name（见 showEditorOnMainThread 内标题构造）。
    std::string m_editorTitle;
    std::atomic<bool> m_editorOpen{false};
    // gui->create 已成功且尚未 destroy。closeEditor 会被调用多次
    // （unloadPluginSlotLocked 一次、unload() 内部一次），
    // 靠它保证 gui->hide/destroy 对一次 create 只执行一次。
    std::atomic<bool> m_guiCreated{false};
};
std::unique_ptr<IPluginInstance> createClapInstance() {
    return std::make_unique<ClapPluginInstance>();
}

} // namespace auradsp
