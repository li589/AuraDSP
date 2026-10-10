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

// CLAP headers
#include <clap/clap.h>

// Steinberg VST3 headers
#include <steinberg/vst3_static.h>

namespace fs = std::filesystem;

namespace auradsp {

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

        m_isLoaded = true;
        m_meta.isCompatible = true;
        return true;
    }

    void unload() override {
        if (m_isLoaded) {
            deactivate();
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

            typedef bool (PLUGIN_API *ExitDllFunc)();
            auto exitDll = reinterpret_cast<ExitDllFunc>(GetProcAddress(m_module, "ExitDll"));
            if (exitDll) {
                exitDll();
            }

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

private:
    HMODULE m_module = nullptr;
    Steinberg::IPluginFactory* m_factory = nullptr;
    Steinberg::Vst::IComponent* m_component = nullptr;
    Steinberg::Vst::IAudioProcessor* m_processor = nullptr;

    PluginMetadata m_meta;
    bool m_isLoaded = false;
    bool m_isActive = false;
    bool m_bypassed = false;
    double m_sampleRate = 48000.0;
    uint32_t m_maxBlockSize = 1024;
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
    if (fs::is_directory(bundlePath)) {
        if (format == PluginFormat::VST3) {
            fs::path subBinary = fs::path(bundlePath) / "Contents" / "x86_64-win";
            if (fs::exists(subBinary)) {
                for (const auto& entry : fs::directory_iterator(subBinary)) {
                    if (entry.path().extension() == ".vst3") {
                        return entry.path().string();
                    }
                }
            }
        } else if (format == PluginFormat::CLAP) {
            fs::path subBinary = fs::path(bundlePath) / "Contents" / "x86_64-win";
            if (fs::exists(subBinary)) {
                for (const auto& entry : fs::directory_iterator(subBinary)) {
                    if (entry.path().extension() == ".clap") {
                        return entry.path().string();
                    }
                }
            }
        }
    }
    return bundlePath;
}

bool PluginScanner::queryMetadata(const std::string& filePath, PluginFormat format, std::vector<PluginMetadata>& outPlugins) {
    std::string binaryPath = resolveBundleBinary(filePath, format);
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

                    typedef bool (PLUGIN_API *ExitDllFunc)();
                    auto exitDll = reinterpret_cast<ExitDllFunc>(GetProcAddress(module, "ExitDll"));
                    if (exitDll) exitDll();
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
                    if (format == PluginFormat::VST3) {
                        pathStr = resolveBundleBinary(entry.path().string(), format);
                        if (pathStr == entry.path().string()) {
                            // Directory without inner binary yet, skip
                            continue;
                        }
                        nameStr = entry.path().stem().string();
                    } else {
                        continue;
                    }
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
    unloadPlugin();
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

void PluginHostManager::unloadPluginLocked() {
    m_hasActivePlugin.store(false, std::memory_order_release);
    m_latency.store(0, std::memory_order_relaxed);
    if (m_activePlugin) {
        m_activePlugin->deactivate();
        m_activePlugin->unload();
        m_activePlugin.reset();
    }
}

void PluginHostManager::unloadPlugin() {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    unloadPluginLocked();
}

bool PluginHostManager::loadPlugin(const std::string& path, const std::string& pluginId, double sampleRate, uint32_t maxBlockSize) {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    try {
        unloadPluginLocked();

        m_sampleRate = sampleRate;
        m_maxBlockSize = maxBlockSize;

        std::string ext = fs::path(path).extension().string();
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

        std::unique_ptr<IPluginInstance> instance;
        if (ext == ".clap") {
            instance = std::make_unique<ClapPluginInstance>();
        } else if (ext == ".vst3") {
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

        m_latency.store(instance->getLatency(), std::memory_order_relaxed);
        m_activePlugin = std::move(instance);
        m_hasActivePlugin.store(true, std::memory_order_release);
        m_bypassed.store(false, std::memory_order_release);

        return true;
    } catch (...) {
        unloadPluginLocked();
        return false;
    }
}

void PluginHostManager::setBypass(bool bypass) {
    m_bypassed.store(bypass, std::memory_order_release);
    if (m_activePlugin) {
        m_activePlugin->setBypass(bypass);
    }
}

bool PluginHostManager::isBypassed() const {
    return m_bypassed.load(std::memory_order_acquire);
}

uint32_t PluginHostManager::getLatency() const {
    return m_latency.load(std::memory_order_relaxed);
}

bool PluginHostManager::hasActivePlugin() const {
    return m_hasActivePlugin.load(std::memory_order_acquire);
}

std::string PluginHostManager::getStatusJson() const {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    std::ostringstream ss;
    ss << "{"
       << "\"hasActive\":" << (m_hasActivePlugin.load() ? "true" : "false") << ","
       << "\"bypassed\":" << (m_bypassed.load() ? "true" : "false") << ","
       << "\"latency\":" << m_latency.load() << ",";
    if (m_activePlugin) {
        const auto& meta = m_activePlugin->getMetadata();
        ss << "\"plugin\":" << meta.toJson();
    } else {
        ss << "\"plugin\":null";
    }
    ss << "}";
    return ss.str();
}

void PluginHostManager::updateFormat(double sampleRate, uint32_t maxBlockSize) {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    m_sampleRate = sampleRate;
    m_maxBlockSize = maxBlockSize;
    if (m_activePlugin && m_hasActivePlugin.load()) {
        m_activePlugin->activate(sampleRate, maxBlockSize);
        m_latency.store(m_activePlugin->getLatency(), std::memory_order_relaxed);
    }
}

void PluginHostManager::process(float* const* inChannels, float* const* outChannels, uint32_t numFrames) {
    if (!m_hasActivePlugin.load(std::memory_order_acquire) || m_bypassed.load(std::memory_order_acquire)) {
        if (inChannels != outChannels && inChannels && outChannels) {
            for (int ch = 0; ch < 2; ++ch) {
                if (inChannels[ch] && outChannels[ch]) {
                    std::memcpy(outChannels[ch], inChannels[ch], numFrames * sizeof(float));
                }
            }
        }
        return;
    }

#if defined(_MSC_VER)
    __try {
        if (m_activePlugin) {
            m_activePlugin->process(inChannels, outChannels, numFrames);
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        // Safe bypass on unexpected SEH crash
        m_bypassed.store(true, std::memory_order_release);
    }
#else
    try {
        if (m_activePlugin) {
            m_activePlugin->process(inChannels, outChannels, numFrames);
        }
    } catch (...) {
        m_bypassed.store(true, std::memory_order_release);
    }
#endif
}

} // namespace auradsp
