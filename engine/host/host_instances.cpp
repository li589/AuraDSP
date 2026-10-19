#include "auradsp_plugin_host.h"
#include "auradsp_engine.h" // B-5：宿主自报版本经 auradsp_version() 单源（AURADSP_VERSION）
#include "debug_log.h"  // B-1 统一调试日志宏

#include <windows.h>
#include <winver.h>
#pragma comment(lib, "version.lib")
#include <shlobj.h>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <thread>
#include <future>
#include <functional>
#include <deque>
#include <map>
#include <set>
#include <unordered_set>
#include <array>

// CLAP headers
#include <clap/clap.h>

// Steinberg VST3 headers
#include <steinberg/vst3_static.h>

#include "plugin_host_util.h"

namespace fs = std::filesystem;

namespace auradsp {

// VST3 COM 胶水（P1 自 host_com.cpp 并入：唯一消费者是 Vst3PluginInstance）
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
// AuraDSP VST3 Host Application & Component Handler
//------------------------------------------------------------------------------
class AuraComponentHandler;

class AuraComponentHandler2Impl : public Steinberg::Vst::IComponentHandler2 {
public:
    AuraComponentHandler* parent = nullptr;

    virtual Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID _iid, void** obj) override;
    virtual Steinberg::uint32 PLUGIN_API addRef() override { return 1000; }
    virtual Steinberg::uint32 PLUGIN_API release() override { return 1000; }

    virtual Steinberg::tresult PLUGIN_API setDirty(Steinberg::TBool state) override {
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API requestOpenEditor(Steinberg::FIDString name = Steinberg::Vst::ViewType::kEditor) override {
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API startGroupEdit() override {
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API finishGroupEdit() override {
        return Steinberg::kResultOk;
    }
};

class AuraComponentHandler : public Steinberg::Vst::IComponentHandler {
public:
    AuraComponentHandler2Impl m_handler2;
    AuraComponentHandler() {
        m_handler2.parent = this;
    }
    virtual ~AuraComponentHandler() = default;

    // FUnknown
    virtual Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID _iid, void** obj) override {
        if (!obj) return Steinberg::kInvalidArgument;
        if (std::memcmp(_iid, Steinberg::FUnknown::iid.toTUID(), sizeof(Steinberg::TUID)) == 0 ||
            std::memcmp(_iid, Steinberg::Vst::IComponentHandler::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            *obj = static_cast<Steinberg::Vst::IComponentHandler*>(this);
            addRef();
            return Steinberg::kResultOk;
        }
        if (std::memcmp(_iid, Steinberg::Vst::IComponentHandler2::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            *obj = static_cast<Steinberg::Vst::IComponentHandler2*>(&m_handler2);
            addRef();
            return Steinberg::kResultOk;
        }
        *obj = nullptr;
        return Steinberg::kNoInterface;
    }
    virtual Steinberg::uint32 PLUGIN_API addRef() override { return 1000; }
    virtual Steinberg::uint32 PLUGIN_API release() override { return 1000; }

    // IComponentHandler
    virtual Steinberg::tresult PLUGIN_API beginEdit(Steinberg::Vst::ParamID id) override {
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API performEdit(Steinberg::Vst::ParamID id, Steinberg::Vst::ParamValue valueNormalized) override {
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API endEdit(Steinberg::Vst::ParamID id) override {
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API restartComponent(Steinberg::int32 flags) override {
        return Steinberg::kResultOk;
    }
};

inline Steinberg::tresult PLUGIN_API AuraComponentHandler2Impl::queryInterface(const Steinberg::TUID _iid, void** obj) {
    if (!parent) return Steinberg::kInvalidArgument;
    return parent->queryInterface(_iid, obj);
}

class AuraHostApplication;

class AuraPlugInterfaceSupportImpl : public Steinberg::Vst::IPlugInterfaceSupport {
public:
    AuraHostApplication* parent = nullptr;

    virtual Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID _iid, void** obj) override;
    virtual Steinberg::uint32 PLUGIN_API addRef() override { return 1000; }
    virtual Steinberg::uint32 PLUGIN_API release() override { return 1000; }

    virtual Steinberg::tresult PLUGIN_API isPlugInterfaceSupported(const Steinberg::TUID _iid) override {
        return Steinberg::kResultTrue;
    }
};

class AuraAttributeList : public Steinberg::Vst::IAttributeList {
private:
    std::atomic<uint32_t> m_refCount{1};
    std::unordered_map<std::string, Steinberg::int64> m_ints;
    std::unordered_map<std::string, double> m_floats;
    std::unordered_map<std::string, std::vector<Steinberg::Vst::TChar>> m_strings;
    std::unordered_map<std::string, std::vector<uint8_t>> m_binaries;

public:
    AuraAttributeList() = default;
    virtual ~AuraAttributeList() = default;

    virtual Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID _iid, void** obj) override {
        if (!obj) return Steinberg::kInvalidArgument;
        if (std::memcmp(_iid, Steinberg::FUnknown::iid.toTUID(), sizeof(Steinberg::TUID)) == 0 ||
            std::memcmp(_iid, Steinberg::Vst::IAttributeList::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            *obj = static_cast<Steinberg::Vst::IAttributeList*>(this);
            addRef();
            return Steinberg::kResultOk;
        }
        *obj = nullptr;
        return Steinberg::kNoInterface;
    }
    virtual Steinberg::uint32 PLUGIN_API addRef() override {
        return ++m_refCount;
    }
    virtual Steinberg::uint32 PLUGIN_API release() override {
        uint32_t r = --m_refCount;
        if (r == 0) delete this;
        return r;
    }

    virtual Steinberg::tresult PLUGIN_API setInt(AttrID id, Steinberg::int64 value) override {
        if (!id) return Steinberg::kInvalidArgument;
        m_ints[id] = value;
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API getInt(AttrID id, Steinberg::int64& value) override {
        if (!id) return Steinberg::kInvalidArgument;
        auto it = m_ints.find(id);
        if (it != m_ints.end()) {
            value = it->second;
            return Steinberg::kResultOk;
        }
        return Steinberg::kResultFalse;
    }
    virtual Steinberg::tresult PLUGIN_API setFloat(AttrID id, double value) override {
        if (!id) return Steinberg::kInvalidArgument;
        m_floats[id] = value;
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API getFloat(AttrID id, double& value) override {
        if (!id) return Steinberg::kInvalidArgument;
        auto it = m_floats.find(id);
        if (it != m_floats.end()) {
            value = it->second;
            return Steinberg::kResultOk;
        }
        return Steinberg::kResultFalse;
    }
    virtual Steinberg::tresult PLUGIN_API setString(AttrID id, const Steinberg::Vst::TChar* string) override {
        if (!id || !string) return Steinberg::kInvalidArgument;
        std::vector<Steinberg::Vst::TChar> vec;
        while (*string) {
            vec.push_back(*string++);
        }
        vec.push_back(0);
        m_strings[id] = std::move(vec);
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API getString(AttrID id, Steinberg::Vst::TChar* string, Steinberg::uint32 sizeInBytes) override {
        if (!id || !string || sizeInBytes == 0) return Steinberg::kInvalidArgument;
        auto it = m_strings.find(id);
        if (it != m_strings.end()) {
            const auto& vec = it->second;
            Steinberg::uint32 bytesToCopy = static_cast<Steinberg::uint32>(vec.size() * sizeof(Steinberg::Vst::TChar));
            if (bytesToCopy > sizeInBytes) bytesToCopy = sizeInBytes;
            std::memcpy(string, vec.data(), bytesToCopy);
            Steinberg::uint32 maxChars = sizeInBytes / sizeof(Steinberg::Vst::TChar);
            if (maxChars > 0) {
                string[maxChars - 1] = 0;
            }
            return Steinberg::kResultOk;
        }
        return Steinberg::kResultFalse;
    }
    virtual Steinberg::tresult PLUGIN_API setBinary(AttrID id, const void* data, Steinberg::uint32 sizeInBytes) override {
        if (!id || !data) return Steinberg::kInvalidArgument;
        const uint8_t* p = static_cast<const uint8_t*>(data);
        m_binaries[id] = std::vector<uint8_t>(p, p + sizeInBytes);
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API getBinary(AttrID id, const void*& data, Steinberg::uint32& sizeInBytes) override {
        if (!id) return Steinberg::kInvalidArgument;
        auto it = m_binaries.find(id);
        if (it != m_binaries.end()) {
            data = it->second.data();
            sizeInBytes = static_cast<Steinberg::uint32>(it->second.size());
            return Steinberg::kResultOk;
        }
        data = nullptr;
        sizeInBytes = 0;
        return Steinberg::kResultFalse;
    }
};

class AuraMessage : public Steinberg::Vst::IMessage {
private:
    std::atomic<uint32_t> m_refCount{1};
    std::string m_messageId;
    AuraAttributeList* m_attributes = nullptr;

public:
    AuraMessage() {
        m_attributes = new AuraAttributeList();
    }
    virtual ~AuraMessage() {
        if (m_attributes) {
            m_attributes->release();
            m_attributes = nullptr;
        }
    }

    virtual Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID _iid, void** obj) override {
        if (!obj) return Steinberg::kInvalidArgument;
        if (std::memcmp(_iid, Steinberg::FUnknown::iid.toTUID(), sizeof(Steinberg::TUID)) == 0 ||
            std::memcmp(_iid, Steinberg::Vst::IMessage::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            *obj = static_cast<Steinberg::Vst::IMessage*>(this);
            addRef();
            return Steinberg::kResultOk;
        }
        *obj = nullptr;
        return Steinberg::kNoInterface;
    }
    virtual Steinberg::uint32 PLUGIN_API addRef() override {
        return ++m_refCount;
    }
    virtual Steinberg::uint32 PLUGIN_API release() override {
        uint32_t r = --m_refCount;
        if (r == 0) delete this;
        return r;
    }

    virtual Steinberg::FIDString PLUGIN_API getMessageID() override {
        return m_messageId.c_str();
    }
    virtual void PLUGIN_API setMessageID(Steinberg::FIDString id) override {
        if (id) m_messageId = id;
        else m_messageId.clear();
    }
    virtual Steinberg::Vst::IAttributeList* PLUGIN_API getAttributes() override {
        return m_attributes;
    }
};

class AuraPlugFrame : public Steinberg::IPlugFrame {
public:
    HWND m_hwnd = nullptr;
    virtual ~AuraPlugFrame() = default;

    virtual Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID _iid, void** obj) override {
        if (!obj) return Steinberg::kInvalidArgument;
        if (std::memcmp(_iid, Steinberg::FUnknown::iid.toTUID(), sizeof(Steinberg::TUID)) == 0 ||
            std::memcmp(_iid, Steinberg::IPlugFrame::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            *obj = static_cast<Steinberg::IPlugFrame*>(this);
            addRef();
            return Steinberg::kResultOk;
        }
        *obj = nullptr;
        return Steinberg::kNoInterface;
    }
    virtual Steinberg::uint32 PLUGIN_API addRef() override { return 1000; }
    virtual Steinberg::uint32 PLUGIN_API release() override { return 1000; }

    virtual Steinberg::tresult PLUGIN_API resizeView(Steinberg::IPlugView* view, Steinberg::ViewRect* newSize) override {
        if (!view || !newSize) return Steinberg::kInvalidArgument;
        int newWidth = newSize->right - newSize->left;
        int newHeight = newSize->bottom - newSize->top;
        if (m_hwnd && IsWindow(m_hwnd)) {
            RECT rc = {0, 0, newWidth, newHeight};
            AdjustWindowRect(&rc, GetWindowLong(m_hwnd, GWL_STYLE), FALSE);
            SetWindowPos(m_hwnd, NULL, 0, 0, rc.right - rc.left, rc.bottom - rc.top, SWP_NOMOVE | SWP_NOZORDER);
        }
        return view->onSize(newSize);
    }
};

class AuraHostApplication : public Steinberg::Vst::IHostApplication {
public:
    AuraPlugInterfaceSupportImpl m_plugSupport;
    AuraHostApplication() {
        m_plugSupport.parent = this;
    }
    virtual ~AuraHostApplication() = default;

    // FUnknown
    virtual Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID _iid, void** obj) override {
        if (!obj) return Steinberg::kInvalidArgument;
        if (std::memcmp(_iid, Steinberg::FUnknown::iid.toTUID(), sizeof(Steinberg::TUID)) == 0 ||
            std::memcmp(_iid, Steinberg::Vst::IHostApplication::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            *obj = static_cast<Steinberg::Vst::IHostApplication*>(this);
            addRef();
            return Steinberg::kResultOk;
        }
        if (std::memcmp(_iid, Steinberg::Vst::IPlugInterfaceSupport::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            *obj = static_cast<Steinberg::Vst::IPlugInterfaceSupport*>(&m_plugSupport);
            addRef();
            return Steinberg::kResultOk;
        }
        *obj = nullptr;
        return Steinberg::kNoInterface;
    }
    virtual Steinberg::uint32 PLUGIN_API addRef() override { return 1000; }
    virtual Steinberg::uint32 PLUGIN_API release() override { return 1000; }

    // IHostApplication
    virtual Steinberg::tresult PLUGIN_API getName(Steinberg::Vst::String128 name) override {
        if (!name) return Steinberg::kInvalidArgument;
        const wchar_t* hostName = L"AuraDSP Host";
        for (int i = 0; i < 127 && hostName[i]; ++i) {
            name[i] = static_cast<Steinberg::Vst::TChar>(hostName[i]);
            name[i + 1] = 0;
        }
        return Steinberg::kResultOk;
    }
    virtual Steinberg::tresult PLUGIN_API createInstance(Steinberg::TUID cid, Steinberg::TUID _iid, void** obj) override {
        if (!obj) return Steinberg::kInvalidArgument;
        *obj = nullptr;

        if (std::memcmp(cid, Steinberg::Vst::IMessage::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            AuraMessage* msg = new AuraMessage();
            Steinberg::tresult res = msg->queryInterface(_iid, obj);
            msg->release();
            AURADSP_DBG_S("[DBG VST3] createInstance IMessage res=" << res << " ptr=" << *obj);
            return res;
        }
        if (std::memcmp(cid, Steinberg::Vst::IAttributeList::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            AuraAttributeList* attr = new AuraAttributeList();
            Steinberg::tresult res = attr->queryInterface(_iid, obj);
            attr->release();
            AURADSP_DBG_S("[DBG VST3] createInstance IAttributeList res=" << res << " ptr=" << *obj);
            return res;
        }

        char cbuf[64], ibuf[64];
        snprintf(cbuf, sizeof(cbuf), "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            (unsigned char)cid[0], (unsigned char)cid[1], (unsigned char)cid[2], (unsigned char)cid[3],
            (unsigned char)cid[4], (unsigned char)cid[5], (unsigned char)cid[6], (unsigned char)cid[7],
            (unsigned char)cid[8], (unsigned char)cid[9], (unsigned char)cid[10], (unsigned char)cid[11],
            (unsigned char)cid[12], (unsigned char)cid[13], (unsigned char)cid[14], (unsigned char)cid[15]);
        snprintf(ibuf, sizeof(ibuf), "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            (unsigned char)_iid[0], (unsigned char)_iid[1], (unsigned char)_iid[2], (unsigned char)_iid[3],
            (unsigned char)_iid[4], (unsigned char)_iid[5], (unsigned char)_iid[6], (unsigned char)_iid[7],
            (unsigned char)_iid[8], (unsigned char)_iid[9], (unsigned char)_iid[10], (unsigned char)_iid[11],
            (unsigned char)_iid[12], (unsigned char)_iid[13], (unsigned char)_iid[14], (unsigned char)_iid[15]);
        AURADSP_WARN_S("[DBG VST3] AuraHostApplication::createInstance unsupported cid=" << cbuf << " iid=" << ibuf);
        return Steinberg::kNotImplemented;
    }
};

inline Steinberg::tresult PLUGIN_API AuraPlugInterfaceSupportImpl::queryInterface(const Steinberg::TUID _iid, void** obj) {
    if (!parent) return Steinberg::kInvalidArgument;
    return parent->queryInterface(_iid, obj);
}

//------------------------------------------------------------------------------
// JSON Helpers
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// CLAP Host Implementation
//------------------------------------------------------------------------------

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
        std::string binaryPath = PluginScanner::resolveBundleBinary(path, PluginFormat::CLAP, &arch);
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
        t_clapThreadType = ClapHostThreadType::Audio;
        m_audioThreadId.store(std::this_thread::get_id(), std::memory_order_relaxed);
        if (numFrames == 0) {
            t_clapThreadType = ClapHostThreadType::Main;
            return;
        }
        if (!inChannels || !outChannels) {
            t_clapThreadType = ClapHostThreadType::Main;
            return;
        }

        // 本版 CLAP SDK 无 audio-config 扩展，无法协商声道数，引擎链恒送立体声；
        // 这里只做逐声道空指针校验，替代原先的全有全无早退。
        const int32_t nc = 2;
        for (int32_t ch = 0; ch < nc; ++ch) {
            if (!inChannels[ch] || !outChannels[ch]) {
                t_clapThreadType = ClapHostThreadType::Main;
                return;
            }
        }

        if (!m_isActive || !m_plugin || m_bypassed) {
            if (inChannels != outChannels) {
                for (int32_t ch = 0; ch < nc; ++ch) {
                    std::memcpy(outChannels[ch], inChannels[ch], numFrames * sizeof(float));
                }
            }
            t_clapThreadType = ClapHostThreadType::Main;
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

        clap_input_events_t emptyIn = { nullptr, emptyInEventsSize, emptyInEventsGet };
        clap_output_events_t emptyOut = { nullptr, emptyOutEventsTryPush };

        clap_process_t proc = {};
        proc.steady_time = -1;
        proc.frames_count = numFrames;
        proc.transport = &transport;
        proc.audio_inputs = &inBuf;
        proc.audio_inputs_count = 1;
        proc.audio_outputs = &outBuf;
        proc.audio_outputs_count = 1;
        proc.in_events = &emptyIn;
        proc.out_events = &emptyOut;

        clap_process_status status = m_plugin->process(m_plugin, &proc);
        if (status == CLAP_PROCESS_ERROR) {
            // Bypass on error
            m_bypassed = true;
        }
        t_clapThreadType = ClapHostThreadType::Main;
    }

    bool isLoaded() const override { return m_isLoaded; }
    bool isBypassed() const override { return m_bypassed; }
    void setBypass(bool bypass) override { m_bypassed = bypass; }
    uint32_t getLatency() const override { return m_meta.latency; }
    const PluginMetadata& getMetadata() const override { return m_meta; }

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
        return t_clapThreadType != ClapHostThreadType::Audio;
    }

    static bool CLAP_ABI hostThreadCheckIsAudio(const clap_host_t* host) {
        return t_clapThreadType == ClapHostThreadType::Audio;
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

//------------------------------------------------------------------------------
// VST3 Host Implementation
//------------------------------------------------------------------------------
/* 已知「关闭编辑器时自身 teardown 会触发不可捕获 fail-fast」的插件隔离名单。
 * 设计目标：宿主绝不为插件自身缺陷陪葬（jBridge / EqualizerAPO 桥接类
 * 插件同理可扩充）。按 name / path 小写子串匹配；命中后 VST3 closeEditor
 * 跳过 view->removed() / setFrame(nullptr) / release()，直接丢弃引用
 * （view 对象泄漏，罕见路径可接受），容器窗仍由 closeEditorOnPumpThread
 * 正常销毁——fail-fast（0xC0000374）不可 SEH 捕获，只有不调用才不死。
 * 2026-10-19：Zebra2(x64)（u-he 旧版 2.9.3，removed() 内堆损坏，官方
 * SDK editorhost 同机复现；ZebraHZ 同族正常，不误伤）。 */
static bool editorQuarantineMatch(const std::string& name, const std::string& path) {
    static const char* kPatterns[] = {"zebra2"};
    std::string ln = name, lp = path;
    for (auto& c : ln) c = (char)std::tolower((unsigned char)c);
    for (auto& c : lp) c = (char)std::tolower((unsigned char)c);
    for (const char* p : kPatterns) {
        if (ln.find(p) != std::string::npos) return true;
        if (lp.find(p) != std::string::npos) return true;
    }
    return false;
}

class Vst3PluginInstance : public IPluginInstance {
public:
    Vst3PluginInstance() = default;
    ~Vst3PluginInstance() override {
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
        m_meta.format = PluginFormat::VST3;

        std::string arch;
        std::string binaryPath = PluginScanner::resolveBundleBinary(path, PluginFormat::VST3, &arch);
        if (binaryPath.empty()) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Invalid VST3 bundle or binary path";
            return false;
        }
        std::wstring wpath = utf8ToWide(binaryPath);
        // D2：is64Bit 由 PE 头判定（不再硬编码）；32 位明确拒绝并给出可读原因，
        // 而不是把 ERROR_BAD_EXE_FORMAT(193) 原样抛给用户。
        m_meta.is64Bit = peIs64Bit(wpath);
        if (!m_meta.is64Bit) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "32 位插件无法加载：AuraDSP 是 64 位进程，请安装 64 位版本";
            return false;
        }
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

        // B3（2026-10-12）：插件对象的全部交互（GetPluginFactory、组件/控制器
        // 实例化与初始化、ConnectionPoint、状态同步）移入 VST3 plugin main
        // 线程。VST3 规范期望宿主在 main/UI 线程完成这些
        // 调用；JUCE 系插件（如 Auto-Tune EFX+）的 MessageManager 在首次触达
        // 时绑定该线程——旧结构里 initialize 在 caller、attached 在临时编辑器
        // 线程，attached 因此死等（编辑器白框），unload 又撞上挂死线程
        // （0xC0000374）。与 CLAP 侧重构同构。
        //
        // C1（2026-10-12）：泵线程按模块共享（ModulePumpThread）——同 DLL
        // 多槽挂载时两条线程会互斥 JUCE MessageManager 归属 → 死锁。按规范化
        // 二进制路径取得（必要时新建）共享泵；引用计数归零时线程才停。
        m_moduleKey = normalizeModuleKey(wpath);
        m_pump = ModulePumpThread::acquire(m_moduleKey);
        if (!m_pump || !m_pump->isReady()) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "VST3 main thread failed to start";
            m_pump.reset();
            FreeLibrary(m_module);
            m_module = nullptr;
            return false;
        }

        std::string initErr;
        bool taskRan = m_pump->postTaskAndWait([&]() {
            m_factory = getFactory();
            if (!m_factory) {
                initErr = "GetPluginFactory returned null";
                return;
            }

            Steinberg::int32 classCount = m_factory->countClasses();
            Steinberg::TUID targetCid = {};
            bool found = false;

            Steinberg::IPluginFactory2* factory2 = nullptr;
            Steinberg::IPluginFactory3* factory3 = nullptr;
            m_factory->queryInterface(Steinberg::IPluginFactory2::iid, reinterpret_cast<void**>(&factory2));
            // IPluginFactory3 曾在此缺失 —— 这正是 D2「FabFilter 加载后 vendor 为空」的根因：
            // 加载路只读 ASCII 的 classInfo/factory2，而 Unicode 类信息（factory3）拿不到，
            // 于是同一插件扫描得 'FabFilter'、加载后得 ''。
            m_factory->queryInterface(Steinberg::IPluginFactory3::iid, reinterpret_cast<void**>(&factory3));

            for (Steinberg::int32 i = 0; i < classCount; ++i) {
                PluginMetadata probe;
                if (!applyVstAudioEffectClass(probe, m_factory, factory2, factory3, i, wpath, path, false, &targetCid)) {
                    continue;
                }
                if (!pluginId.empty() && probe.id != pluginId) continue;

                // 与扫描路共用同一填充实现；seeded=true 时 scanSeed 已填的描述性字段
                // （name/vendor/version/category/bundleName）不会被覆盖，
                // 于是「扫描值 == 加载值」逐字段成立；id 例外，它是实例化身份键。
                applyVstAudioEffectClass(m_meta, m_factory, factory2, factory3, i, wpath, path, true);
                found = true;
                break;
            }

            if (factory3) factory3->release();
            if (factory2) factory2->release();

            if (!found) {
                initErr = "No compatible audio effect class (kVstAudioEffectClass) found in VST3";
                m_factory = nullptr;
                return;
            }

            // Create component instance
            AURADSP_DBG("[DBG VST3] createInstance targetCid on IComponent...");
            Steinberg::tresult res = m_factory->createInstance(
                targetCid,
                Steinberg::Vst::IComponent::iid.toTUID(),
                reinterpret_cast<void**>(&m_component)
            );
            AURADSP_DBG_S("[DBG VST3] createInstance res=" << res << " component=" << m_component);

            if (res != Steinberg::kResultOk || !m_component) {
                initErr = "Failed to create VST3 IComponent instance, res: " + std::to_string(res);
                return;
            }

            // Initialize component with host application context
            AURADSP_DBG("[DBG VST3] Initializing component with hostApp...");
            m_component->initialize(&m_hostApp);

            // Query IAudioProcessor
            AURADSP_DBG("[DBG VST3] Querying IAudioProcessor...");
            res = m_component->queryInterface(
                Steinberg::Vst::IAudioProcessor::iid,
                reinterpret_cast<void**>(&m_processor)
            );
            AURADSP_DBG_S("[DBG VST3] Query IAudioProcessor res=" << res << " proc=" << m_processor);

            if (res != Steinberg::kResultOk || !m_processor) {
                initErr = "Failed to query VST3 IAudioProcessor interface";
                m_component->terminate();
                m_component->release();
                m_component = nullptr;
                return;
            }

            // Query IEditController
            AURADSP_DBG("[DBG VST3] Querying IEditController on component...");
            Steinberg::tresult cRes = m_component->queryInterface(
                Steinberg::Vst::IEditController::iid,
                reinterpret_cast<void**>(&m_controller)
            );
            AURADSP_DBG_S("[DBG VST3] Query IEditController cRes=" << cRes << " ctrl=" << m_controller);
            if (cRes != Steinberg::kResultOk || !m_controller) {
                Steinberg::TUID controllerCID;
                Steinberg::tresult cidRes = m_component->getControllerClassId(controllerCID);
                AURADSP_DBG_S("[DBG VST3] getControllerClassId res=" << cidRes);
                if (cidRes == Steinberg::kResultOk) {
                    AURADSP_DBG("[DBG VST3] Creating controller from separate CID...");
                    Steinberg::tresult instRes = m_factory->createInstance(
                        controllerCID,
                        Steinberg::Vst::IEditController::iid.toTUID(),
                        reinterpret_cast<void**>(&m_controller)
                    );
                    AURADSP_DBG_S("[DBG VST3] createInstance controller res=" << instRes << " ptr=" << m_controller);
                    if (m_controller) {
                        AURADSP_DBG("[DBG VST3] Initializing separate controller...");
                        Steinberg::tresult initRes = m_controller->initialize(&m_hostApp);
                        AURADSP_DBG_S("[DBG VST3] Controller initialize res=" << initRes);
                    }
                }
            }

            if (m_controller) {
                // 设置 ComponentHandler（Ozone 等宿主解耦插件强依赖 handler 才能创建 Editor）
                AURADSP_DBG("[DBG VST3] setComponentHandler...");
                m_controller->setComponentHandler(&m_componentHandler);

                // 连接 ConnectionPoint（Component 与 Controller 独立时建立互联通道）
                AURADSP_DBG("[DBG VST3] Connecting ConnectionPoints...");
                Steinberg::Vst::IConnectionPoint* compCP = nullptr;
                Steinberg::Vst::IConnectionPoint* ctrlCP = nullptr;
                Steinberg::tresult q1 = m_component->queryInterface(Steinberg::Vst::IConnectionPoint::iid.toTUID(), reinterpret_cast<void**>(&compCP));
                Steinberg::tresult q2 = m_controller->queryInterface(Steinberg::Vst::IConnectionPoint::iid.toTUID(), reinterpret_cast<void**>(&ctrlCP));
                AURADSP_DBG_S("[DBG VST3] compCP=" << compCP << " (q1=" << q1 << ") ctrlCP=" << ctrlCP << " (q2=" << q2 << ")");
                if (compCP && ctrlCP) {
                    AURADSP_DBG("[DBG VST3] calling safeConnect(compCP, ctrlCP)...");
                    auto safeConnect = [](Steinberg::Vst::IConnectionPoint* a, Steinberg::Vst::IConnectionPoint* b) -> int {
                        __try {
                            return (int)a->connect(b);
                        } __except (EXCEPTION_EXECUTE_HANDLER) {
                            return -999999;
                        }
                    };
                    int c1 = safeConnect(compCP, ctrlCP);
                    AURADSP_DBG_S("[DBG VST3] safeConnect(compCP, ctrlCP) result=" << c1);
                    int c2 = safeConnect(ctrlCP, compCP);
                    AURADSP_DBG_S("[DBG VST3] safeConnect(ctrlCP, compCP) result=" << c2);
                }
                if (compCP) compCP->release();
                if (ctrlCP) ctrlCP->release();

                // 同步组件初始状态给控制器
                AURADSP_DBG("[DBG VST3] Syncing component state to controller...");
                Vst3MemoryStream stateStream;
                Steinberg::tresult sRes = m_component->getState(&stateStream);
                AURADSP_DBG_S("[DBG VST3] m_component->getState res=" << sRes << " bytes=" << stateStream.m_data.size());
                if (sRes == Steinberg::kResultOk) {
                    Steinberg::int64 seekRes = 0;
                    stateStream.seek(0, Steinberg::IBStream::kIBSeekSet, &seekRes);
                    Steinberg::tresult csRes = m_controller->setComponentState(&stateStream);
                    AURADSP_DBG_S("[DBG VST3] m_controller->setComponentState res=" << csRes);
                }
            }
        }, 10000);
        if (!taskRan || !initErr.empty()) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = taskRan ? initErr : "VST3 main thread task timeout during load";
            if (!taskRan) {
                // 泵线程挂死于 init —— 隔离（放弃释放）而非 detach 后继续用本
                // 对象：登记废弃，由 manager 把整个实例移入静态隔离区。
                // 此时绝不能 FreeLibrary（DLL 代码可能正被执行中），也不 reset
                // m_pump（挂死线程可能仍引用泵对象）。
                m_threadAbandoned.store(true, std::memory_order_release);
                return false;
            }
            // init 正常返回错误：线程健康，先释放共享泵引用再卸载模块。
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
        // abandoned 守卫必须最先执行：泵线程（或旧编辑器线程）挂死后仍卡在
        // 插件代码里，此处的 terminate/release/FreeLibrary 都会撞上它
        // （FreeLibrary 卸载正在执行的 DLL = 0xC0000374 堆损坏）。整体跳过
        // 销毁，manager 据 abandoned() 把实例移入静态隔离区（可控泄漏换
        // 不可控崩溃）。
        if (m_threadAbandoned.load(std::memory_order_acquire)) {
            AURADSP_WARN("[DBG VST3 unload] WARNING: main thread abandoned; skipping all teardown (quarantine)");
            m_isLoaded = false;
            return;
        }
        if (m_isLoaded) {
            closeEditor();
            deactivate();

            // 插件对象销毁在 plugin main 线程执行（与创建同线程）。
            AURADSP_DBG("[DBG VST3 unload] destroying plugin objects on main thread");
            bool destroyed = m_pump->postTaskAndWait([&]() {
                if (m_controller && m_component) {
                    Steinberg::Vst::IConnectionPoint* compCP = nullptr;
                    Steinberg::Vst::IConnectionPoint* ctrlCP = nullptr;
                    m_component->queryInterface(Steinberg::Vst::IConnectionPoint::iid, reinterpret_cast<void**>(&compCP));
                    m_controller->queryInterface(Steinberg::Vst::IConnectionPoint::iid, reinterpret_cast<void**>(&ctrlCP));
                    if (compCP && ctrlCP) {
                        compCP->disconnect(ctrlCP);
                        ctrlCP->disconnect(compCP);
                    }
                    if (compCP) compCP->release();
                    if (ctrlCP) ctrlCP->release();
                    m_controller->setComponentHandler(nullptr);
                }

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
            }, 3000);
            if (!destroyed) {
                AURADSP_WARN("[DBG VST3 unload] WARNING: main thread unresponsive; quarantining instance");
                m_threadAbandoned.store(true, std::memory_order_release);
                return;   // manager 据此把实例移入静态隔离区（泄漏而非 UAF）
            }
            m_isLoaded = false;
        }
        // C1：释放共享泵引用（最后一实例时 PumpDeleter 停线程）。必须先于
        // FreeLibrary——确保卸载 DLL 时其中代码已无人执行。
        m_pump.reset();
        if (m_module) {
            FreeLibrary(m_module);
            m_module = nullptr;
        }
        m_isLoaded = false;
    }

    bool activate(double sampleRate, uint32_t maxBlockSize) override {
        if (!m_isLoaded || !m_processor || !m_component) return false;
        if (m_isActive) deactivate();

        m_sampleRate = sampleRate;
        m_maxBlockSize = maxBlockSize;

        // 查询插件所声明的总线数量
        int32_t numInBusses = m_component->getBusCount(Steinberg::Vst::kAudio, Steinberg::Vst::kInput);
        int32_t numOutBusses = m_component->getBusCount(Steinberg::Vst::kAudio, Steinberg::Vst::kOutput);
        if (numInBusses < 0) numInBusses = 0;
        if (numOutBusses <= 0) numOutBusses = 1;
        m_numInputBusses = numInBusses;
        m_numOutputBusses = numOutBusses;
        /* process 在 RT 线程禁止堆分配：总线数在 activate 后不变，
         * 这里一次性分配，process 只填充/复用。 */
        m_inBusses.assign(static_cast<size_t>(numInBusses),
                          Steinberg::Vst::AudioBusBuffers{});
        m_outBusses.assign(static_cast<size_t>(numOutBusses),
                           Steinberg::Vst::AudioBusBuffers{});

        std::vector<Steinberg::Vst::SpeakerArrangement> inArrs(numInBusses, Steinberg::Vst::SpeakerArr::kStereo);
        std::vector<Steinberg::Vst::SpeakerArrangement> outArrs(numOutBusses, Steinberg::Vst::SpeakerArr::kStereo);

        for (int32_t i = 0; i < numInBusses; ++i) {
            Steinberg::Vst::SpeakerArrangement cur = Steinberg::Vst::SpeakerArr::kStereo;
            if (m_processor->getBusArrangement(Steinberg::Vst::kInput, i, cur) == Steinberg::kResultOk) {
                inArrs[i] = cur;
            }
        }
        for (int32_t i = 0; i < numOutBusses; ++i) {
            Steinberg::Vst::SpeakerArrangement cur = Steinberg::Vst::SpeakerArr::kStereo;
            if (m_processor->getBusArrangement(Steinberg::Vst::kOutput, i, cur) == Steinberg::kResultOk) {
                outArrs[i] = cur;
            }
        }

        // 显式激活全部音频总线：FabFilter/Convology 等插件不会仅凭 BusInfo.flags 的
        // kDefaultActive 进入可处理态，必须在 setupProcessing 前对每个音频总线调用
        // activateBus(..., true)，否则 process() 恒返回 kResultOk 但不写任何输出。
        // （已用官方 VST3 SDK hosting 参考宿主复现并验证该行为差异。）
        for (int32_t i = 0; i < numInBusses; ++i) {
            m_component->activateBus(Steinberg::Vst::kAudio, Steinberg::Vst::kInput, i, true);
        }
        for (int32_t i = 0; i < numOutBusses; ++i) {
            m_component->activateBus(Steinberg::Vst::kAudio, Steinberg::Vst::kOutput, i, true);
        }

        // 主总线协商优先设为立体声
        if (numInBusses > 0) inArrs[0] = Steinberg::Vst::SpeakerArr::kStereo;
        if (numOutBusses > 0) outArrs[0] = Steinberg::Vst::SpeakerArr::kStereo;

        // 调用 setBusArrangements（注意：根据 VST3 规范，返回 kResultFalse 并不代表致命失败，
        // 插件可自主选择自适应或维持其默认总线配置）
        (void)m_processor->setBusArrangements(inArrs.data(), numInBusses, outArrs.data(), numOutBusses);

        // 重新获取主总线实际确认的声道数
        if (numInBusses > 0) {
            Steinberg::Vst::SpeakerArrangement finalIn = Steinberg::Vst::SpeakerArr::kStereo;
            if (m_processor->getBusArrangement(Steinberg::Vst::kInput, 0, finalIn) == Steinberg::kResultOk) {
                m_inChannels = Steinberg::Vst::SpeakerArr::getChannelCount(finalIn) == 1 ? 1 : 2;
            } else {
                m_inChannels = 2;
            }
        } else {
            m_inChannels = 0;
        }
        Steinberg::Vst::SpeakerArrangement finalOut = Steinberg::Vst::SpeakerArr::kStereo;
        if (m_processor->getBusArrangement(Steinberg::Vst::kOutput, 0, finalOut) == Steinberg::kResultOk) {
            m_outChannels = Steinberg::Vst::SpeakerArr::getChannelCount(finalOut) == 1 ? 1 : 2;
        } else {
            m_outChannels = 2;
        }

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
        if (!outChannels || !outChannels[0]) return;
        if (m_inChannels > 0 && (!inChannels || !inChannels[0])) return;

        const int32_t nc = m_inChannels;
        for (int32_t ch = 1; ch < nc; ++ch) if (!inChannels[ch]) return;

        if (!m_isActive || !m_processor || m_bypassed) {
            if (inChannels != outChannels && inChannels) {
                for (int32_t ch = 0; ch < 2; ++ch) {
                    if (inChannels[ch] && outChannels[ch]) {
                        std::memcpy(outChannels[ch], inChannels[ch], numFrames * sizeof(float));
                    }
                }
            }
            return;
        }

        for (int32_t b = 0; b < m_numInputBusses; ++b) {
            if (b == 0 && nc > 0) {
                m_inBusses[0].numChannels = nc;
                m_inBusses[0].silenceFlags = 0;
                m_inBusses[0].channelBuffers32 = (Steinberg::Vst::Sample32**)inChannels;
            } else {
                m_inBusses[b].numChannels = 0;
                m_inBusses[b].silenceFlags = 0;
                m_inBusses[b].channelBuffers32 = nullptr;
            }
        }

        for (int32_t b = 0; b < m_numOutputBusses; ++b) {
            if (b == 0) {
                m_outBusses[0].numChannels = m_outChannels;
                m_outBusses[0].silenceFlags = 0;
                m_outBusses[0].channelBuffers32 = (Steinberg::Vst::Sample32**)outChannels;
            } else {
                m_outBusses[b].numChannels = 0;
                m_outBusses[b].silenceFlags = 0;
                m_outBusses[b].channelBuffers32 = nullptr;
            }
        }

        Steinberg::Vst::ProcessContext context = {};
        context.state = Steinberg::Vst::ProcessContext::kPlaying |
                        Steinberg::Vst::ProcessContext::kProjectTimeMusicValid |
                        Steinberg::Vst::ProcessContext::kTempoValid |
                        Steinberg::Vst::ProcessContext::kTimeSigValid |
                        Steinberg::Vst::ProcessContext::kContTimeValid |
                        Steinberg::Vst::ProcessContext::kSystemTimeValid;
        context.sampleRate = m_sampleRate;
        context.tempo = 120.0;
        context.timeSigNumerator = 4;
        context.timeSigDenominator = 4;
        // 连续时间轴推进：同步类/动画类插件依赖（与官方 hosting 参考实现的
        // AudioClient::preprocess 行为一致）。
        context.continousTimeSamples = m_continuousTimeSamples;
        context.projectTimeSamples = m_continuousTimeSamples;
        {
            FILETIME ft = {};
            GetSystemTimeAsFileTime(&ft);
            context.systemTime = (static_cast<int64_t>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        }
        m_continuousTimeSamples += numFrames;

        Steinberg::Vst::ProcessData data = {};
        data.processMode = Steinberg::Vst::kRealtime;
        data.symbolicSampleSize = Steinberg::Vst::kSample32;
        data.numSamples = numFrames;
        data.inputs = m_inBusses.data();
        data.numInputs = static_cast<Steinberg::int32>(m_inBusses.size());
        data.outputs = m_outBusses.data();
        data.numOutputs = static_cast<Steinberg::int32>(m_outBusses.size());
        data.inputParameterChanges = nullptr;
        data.outputParameterChanges = nullptr;
        data.inputEvents = nullptr;
        data.outputEvents = nullptr;
        data.processContext = &context;

        Steinberg::tresult res = m_processor->process(data);
        if (res != Steinberg::kResultOk && res != Steinberg::kResultFalse && res < 0) {
            m_bypassed = true;
        } else if (m_outChannels == 1 && outChannels[0] && outChannels[1]) {
            // 单声道插件：铺回 L/R，否则右声道会残留上一块数据。
            std::memcpy(outChannels[1], outChannels[0], numFrames * sizeof(float));
        }
    }

    bool isLoaded() const override { return m_isLoaded; }
    bool isBypassed() const override { return m_bypassed; }
    void setBypass(bool bypass) override { m_bypassed = bypass; }
    uint32_t getLatency() const override { return m_meta.latency; }
    const PluginMetadata& getMetadata() const override { return m_meta; }

    bool showEditor(const std::string& title = "") override {
        if (!m_isLoaded || !m_component) return false;
        m_editorTitle = title;
        setupPluginDllDirectories(m_meta.path);
        if (m_editorOpen.load(std::memory_order_acquire) && m_editorHwnd && IsWindow(m_editorHwnd)) {
            SetForegroundWindow(m_editorHwnd);
            ShowWindow(m_editorHwnd, SW_SHOW);
            return true;
        }
        if (!m_controller) {
            AURADSP_WARN("[DBG VST3 showEditor] m_controller is NULL!");
            return false;
        }
        if (!m_pump || !m_pump->isReady()) return false;
        // B3（2026-10-12）：GUI 交互全部在 VST3 plugin main 线程（C1 起为
        // 按模块共享的泵线程）执行——与组件 initialize 同线程，JUCE 系插件的
        // MessageManager 线程假设得以满足；旧结构里 attached 跑在临时编辑器
        // 线程（≠ initialize 线程），Auto-Tune EFX+ 等插件因此挂死（白框）。
        bool ok = false;
        bool done = m_pump->postTaskAndWait([&]() { ok = showEditorOnPumpThread(); }, 8000);
        if (!done) {
            AURADSP_WARN("[DBG VST3 showEditor] WARNING: show task timed out; abandoning instance");
            m_threadAbandoned.store(true, std::memory_order_release);
            return false;
        }
        return ok;
    }

    // showEditor 的实体（在 VST3 plugin main 线程内执行）。
    bool showEditorOnPumpThread() {
        Steinberg::IPlugView* view = m_controller->createView(Steinberg::Vst::ViewType::kEditor);
        AURADSP_DBG_S("[DBG VST3 showEditor] createView(kEditor) returned: " << view);
        if (!view) {
            view = m_controller->createView(nullptr);
            AURADSP_WARN_S("[DBG VST3 showEditor] createView(nullptr) returned: " << view);
        }
        if (!view) {
            view = m_controller->createView("Editor");
            AURADSP_DBG_S("[DBG VST3 showEditor] createView(\"Editor\") returned: " << view);
        }
        if (!view) {
            // Check if controller or component itself is IPlugView
            Steinberg::IPlugView* pv = nullptr;
            if (m_controller->queryInterface(Steinberg::IPlugView::iid.toTUID(), reinterpret_cast<void**>(&pv)) == Steinberg::kResultOk && pv) {
                AURADSP_DBG("[DBG VST3 showEditor] controller implements IPlugView!");
                view = pv;
            } else if (m_component->queryInterface(Steinberg::IPlugView::iid.toTUID(), reinterpret_cast<void**>(&pv)) == Steinberg::kResultOk && pv) {
                AURADSP_DBG("[DBG VST3 showEditor] component implements IPlugView!");
                view = pv;
            }
        }
        if (!view) return false;
        Steinberg::tresult platSup = view->isPlatformTypeSupported(Steinberg::kPlatformTypeHWND);
        AURADSP_DBG_S("[DBG VST3 showEditor] isPlatformTypeSupported(HWND) returned: " << platSup);
        if (platSup != Steinberg::kResultTrue) {
            view->release();
            return false;
        }

        EnsureVst3WindowClassRegistered();

        Steinberg::ViewRect vr;
        int width = 800, height = 600;
        if (view->getSize(&vr) == Steinberg::kResultOk) {
            width = vr.right - vr.left;
            height = vr.bottom - vr.top;
        }
        if (width < 200) width = 800;
        if (height < 150) height = 600;

        // E1：标题由调用方决定；为空时退化到插件自报名。
        // 历史版本硬编码 L"[AuraDSP] " 前缀，Dart 侧构造的
        // "<name> - AuraDSP Host" 标题从未生效（C ABI 丢弃第三参）。
        std::wstring title = utf8ToWide(m_editorTitle.empty() ? m_meta.name : m_editorTitle);
        RECT rc = {0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
        DWORD style = WS_OVERLAPPEDWINDOW;
        AdjustWindowRect(&rc, style, FALSE);

        HWND hwnd = CreateWindowExW(
            0, L"AuraDSP_VST3_Host_Window", title.c_str(),
            style, CW_USEDEFAULT, CW_USEDEFAULT,
            rc.right - rc.left, rc.bottom - rc.top,
            NULL, NULL, GetModuleHandleW(NULL), NULL);

        if (!hwnd) {
            view->release();
            return false;
        }

        m_editorHwnd = hwnd;
        m_editorOpen.store(true, std::memory_order_release);
        // C1：实例指针挂到容器窗口，WM_CLOSE 经 WndProc 分发回本实例
        // （onEditorWmClose）；同时向共享泵登记，泵异常退出时兜底销毁。
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
        m_pump->registerEditor(hwnd);

        // frame 必须存活到编辑器关闭（插件会回调），故为成员而非局部变量。
        m_view = view;
        m_plugFrame.m_hwnd = hwnd;
        view->setFrame(&m_plugFrame);

        try {
            Steinberg::tresult attachRes = view->attached(reinterpret_cast<void*>(hwnd), Steinberg::kPlatformTypeHWND);
            if (attachRes != Steinberg::kResultOk && attachRes != Steinberg::kResultTrue) {
                AURADSP_WARN_S("[DBG VST3 showEditor] view->attached returned non-ok: " << attachRes);
                detachViewOnPumpThread(view);
                if (IsWindow(hwnd)) DestroyWindow(hwnd);
                if (m_pump) m_pump->unregisterEditor(hwnd);
                m_editorHwnd = nullptr;
                m_editorOpen.store(false, std::memory_order_release);
                return false;
            }
        } catch (const std::exception& ex) {
            AURADSP_WARN_S("[DBG VST3 showEditor] view->attached exception: " << ex.what());
            detachViewOnPumpThread(view);
            if (IsWindow(hwnd)) DestroyWindow(hwnd);
            if (m_pump) m_pump->unregisterEditor(hwnd);
            m_editorHwnd = nullptr;
            m_editorOpen.store(false, std::memory_order_release);
            return false;
        } catch (...) {
            AURADSP_WARN("[DBG VST3 showEditor] view->attached unknown exception!");
            detachViewOnPumpThread(view);
            if (IsWindow(hwnd)) DestroyWindow(hwnd);
            if (m_pump) m_pump->unregisterEditor(hwnd);
            m_editorHwnd = nullptr;
            m_editorOpen.store(false, std::memory_order_release);
            return false;
        }

        ShowWindow(hwnd, SW_SHOW);
        UpdateWindow(hwnd);

        // C4：很多插件在 attached 之前 getSize 返回 0/0 或占位值，只有
        // attached 之后才布局出真实尺寸——所以再取一次。尺寸变化就走一遍
        // resizeView（resizeView 改容器，其后的 WM_SIZE 由 WndProc 把子窗口
        // 同步铺满客户区）。
        pollEditorSizeOnPumpThread(view, width, height);
        // C4：异步布局的插件（iZotope RX 系列为代表）真实尺寸在几十到几百
        // 毫秒后才稳定，故再挂一个短命定时器反复校正（100ms × 6 次）。
        resetSettleTicks();
        SetTimer(hwnd, kSizeSettleTimerId, 100, nullptr);
        return true;
    }

    // C4：取插件自报尺寸；与当前容器不同且合理即同步（容器 + 子窗口）。
    // 在 plugin main 线程（泵线程）上调用。
    void pollEditorSizeOnPumpThread(Steinberg::IPlugView* view, int& curW, int& curH) {
        if (!view || !m_editorHwnd || !IsWindow(m_editorHwnd)) return;
        Steinberg::ViewRect vr;
        if (view->getSize(&vr) != Steinberg::kResultOk) return;
        const int w = vr.right - vr.left;
        const int h = vr.bottom - vr.top;
        // 合理性下限：太低视为"尚未布局"，不采信（避免把容器缩成小方块）。
        if (w < 100 || h < 80) return;
        if (w == curW && h == curH) return;
        curW = w;
        curH = h;
        Steinberg::ViewRect nr{0, 0, w, h};
        try { m_plugFrame.resizeView(view, &nr); } catch (...) {}
    }

    // C4：容器定时器回调入口（泵线程，见 IPluginInstance::pollEditorSize）。
    void pollEditorSize() override {
        int curW = 0, curH = 0;
        RECT rc;
        if (m_editorHwnd && GetClientRect(m_editorHwnd, &rc)) {
            curW = rc.right - rc.left;
            curH = rc.bottom - rc.top;
        }
        if (m_view) pollEditorSizeOnPumpThread(m_view, curW, curH);
    }

    // C4：容器 WM_SIZE（泵线程）。VST3 规范——宿主把新尺寸交给 view，由
    // 插件自己调整子窗口。这是"拉大框后多出来的是空白"的根治点。
    void onEditorResize() override {
        if (!m_view || !m_editorHwnd || !IsWindow(m_editorHwnd)) return;
        RECT rc;
        if (!GetClientRect(m_editorHwnd, &rc)) return;
        const int w = rc.right - rc.left;
        const int h = rc.bottom - rc.top;
        if (w <= 0 || h <= 0) return;
        if (w == m_lastViewW && h == m_lastViewH) return;   // 防 resizeView 回环
        m_lastViewW = w;
        m_lastViewH = h;
        Steinberg::ViewRect vr{0, 0, w, h};
        try { m_view->onSize(&vr); } catch (...) {}
    }

    // IPlugView 收尾（泵线程内调用）：解绑 frame 并释放引用。
    // 顺序与官方 editorhost（WindowController::closePlugView）一致：
    // 先 setFrame(nullptr) 再 removed()——Zebra2 (u-he) 在 removed() 仍持有
    // frame 时会回调宿主 resizeView（进而 onSize 重入半拆除中的 view），
    // 导致其堆块损坏并在内部 free() 触发不可捕获的 0xC0000374 fail-fast。
    // 使用 SEH 隔离插件在退出时的内存越界，防止 0xC0000005 崩溃宿主。
    void detachViewOnPumpThread(Steinberg::IPlugView* view) {
        if (!view) return;
        // 隔离名单（editorQuarantineMatch）：插件自身 teardown 缺陷——
        // removed()/setFrame(nullptr)/release() 任一步都可能踩进其损坏的
        // teardown（fail-fast 不可捕获）。命中则整体跳过 detach，只丢弃
        // view 引用（对象泄漏，罕见路径可接受）；容器窗由
        // closeEditorOnPumpThread 正常销毁。宿主不为插件缺陷陪葬。
        if (editorQuarantineMatch(m_meta.name, m_meta.path)) {
            AURADSP_WARN("[DBG VST3 closeEditor] quarantine: 插件自身 teardown 缺陷，"
                         "跳过 removed()/release()（隔离名单，防 0xC0000374 fail-fast）");
            m_view = nullptr;
            return;
        }
#if defined(_MSC_VER)
        __try {
            view->setFrame(nullptr);
        } __except (EXCEPTION_EXECUTE_HANDLER) {}
        __try {
            view->removed();
        } __except (EXCEPTION_EXECUTE_HANDLER) {}
        __try {
            view->release();
        } __except (EXCEPTION_EXECUTE_HANDLER) {}
#else
        try { view->setFrame(nullptr); } catch (...) {}
        try { view->removed(); } catch (...) {}
        try { view->release(); } catch (...) {}
#endif
        m_view = nullptr;
    }

    void closeEditor() override {
        AURADSP_DBG("[DBG VST3 closeEditor] enter");
        if (!m_pump || !m_pump->isReady()) {
            m_editorOpen.store(false, std::memory_order_release);
            AURADSP_WARN("[DBG VST3 closeEditor] no plugin main thread; skip");
            return;
        }
        bool done = m_pump->postTaskAndWait([&]() { closeEditorOnPumpThread(); }, 3000);
        if (!done) {
            AURADSP_WARN("[DBG VST3 closeEditor] WARNING: close task timed out; abandoning instance");
            m_threadAbandoned.store(true, std::memory_order_release);
        }
    }

    // C1：用户点编辑器窗口 X —— WndProc 在泵线程上分发到此。已在 plugin
    // main 线程，直接执行收尾（与 createView/attached 同线程，无锁竞争）。
    void onEditorWmClose() override {
        closeEditorOnPumpThread();
    }

    // closeEditor 的实体（在 VST3 plugin main 线程内执行）；
    // 用户点 X 经 WndProc 分发（onEditorWmClose）时也走这里。
    void closeEditorOnPumpThread() {
        HWND hwnd = m_editorHwnd;
        // C4：卸尺寸稳定化定时器。走本路径（Dart 侧卸载）时不经过 WM_CLOSE，
        // 故必须显式 KillTimer，否则定时器会在窗口销毁后仍反复回调。
        if (hwnd) KillTimer(hwnd, kSizeSettleTimerId);
        if (m_view) {
            detachViewOnPumpThread(m_view);
        }
        if (hwnd) {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            if (m_pump) m_pump->unregisterEditor(hwnd);
            if (IsWindow(hwnd)) DestroyWindow(hwnd);
        }
        m_editorHwnd = nullptr;
        m_editorOpen.store(false, std::memory_order_release);
        AURADSP_DBG("[DBG VST3 closeEditor] closed on main thread");
    }

    bool isEditorOpen() const override {
        return m_editorOpen.load(std::memory_order_acquire) && m_editorHwnd != nullptr && IsWindow(m_editorHwnd);
    }

    // 编辑器线程曾被 detach（仍卡在插件代码里并引用 this/插件对象）。
    // manager 据此把实例移入静态隔离区而不是析构——镜像 CLAP 同款机制。
    bool abandoned() const override {
        return m_threadAbandoned.load(std::memory_order_acquire);
    }

    bool savePreset(const std::string& filePath) override {
        if (!m_isLoaded || !m_component) return false;
        if (!m_pump || !m_pump->isReady()) return false;
        // getState 属插件 main 线程交互（B3：与 initialize/createView 同线程）。
        std::vector<uint8_t> data;
        bool got = m_pump->postTaskAndWait([&]() {
            auto stream = new Vst3MemoryStream();
            Steinberg::tresult res = m_component->getState(stream);
            if (res == Steinberg::kResultOk) data = stream->m_data;
            stream->release();
        }, 3000);
        if (!got || data.empty()) {
            if (!got) m_threadAbandoned.store(true, std::memory_order_release);
            return false;
        }

        fs::path p(filePath);
        if (p.has_parent_path() && !fs::exists(p.parent_path())) {
            fs::create_directories(p.parent_path());
        }

        std::ofstream ofs(filePath, std::ios::binary);
        if (!ofs) {
            return false;
        }
        ofs.write(reinterpret_cast<const char*>(data.data()), data.size());
        return true;
    }

    bool loadPreset(const std::string& filePath) override {
        if (!m_isLoaded || !m_component) return false;
        if (!fs::exists(filePath)) return false;
        if (!m_pump || !m_pump->isReady()) return false;

        std::ifstream ifs(filePath, std::ios::binary);
        if (!ifs) return false;
        ifs.seekg(0, std::ios::end);
        size_t sz = static_cast<size_t>(ifs.tellg());
        ifs.seekg(0, std::ios::beg);
        std::vector<uint8_t> buf(sz);
        ifs.read(reinterpret_cast<char*>(buf.data()), static_cast<std::streamsize>(sz));

        // setState/setComponentState 属插件 main 线程交互（B3）。
        bool ok = false;
        bool ran = m_pump->postTaskAndWait([&]() {
            auto stream = new Vst3MemoryStream();
            stream->m_data = std::move(buf);
            Steinberg::tresult res = m_component->setState(stream);
            if (res == Steinberg::kResultOk && m_controller) {
                stream->seek(0, Steinberg::IBStream::kIBSeekSet, nullptr);
                m_controller->setComponentState(stream);
            }
            stream->release();
            ok = (res == Steinberg::kResultOk);
        }, 3000);
        if (!ran) {
            m_threadAbandoned.store(true, std::memory_order_release);
            return false;
        }
        return ok;
    }

private:
    HMODULE m_module = nullptr;
    Steinberg::IPluginFactory* m_factory = nullptr;
    Steinberg::Vst::IComponent* m_component = nullptr;
    Steinberg::Vst::IAudioProcessor* m_processor = nullptr;
    Steinberg::Vst::IEditController* m_controller = nullptr;

    AuraComponentHandler m_componentHandler;
    AuraHostApplication m_hostApp;

    PluginMetadata m_meta;
    bool m_isLoaded = false;
    bool m_isActive = false;
    bool m_bypassed = false;
    double m_sampleRate = 48000.0;
    uint32_t m_maxBlockSize = 1024;
    int64_t m_continuousTimeSamples = 0;
    int32_t m_inChannels = 2;
    int32_t m_outChannels = 2;
    int32_t m_numInputBusses = 1;
    int32_t m_numOutputBusses = 1;
    std::vector<Steinberg::Vst::AudioBusBuffers> m_inBusses;
    std::vector<Steinberg::Vst::AudioBusBuffers> m_outBusses;

    HWND m_editorHwnd = nullptr;
    // E1：调用方（Dart）传来的窗口标题；为空时退化为 m_meta.name。
    // 同步语义同 CLAP 实例：写于任务提交前，读于泵线程内。
    std::string m_editorTitle;
    std::atomic<bool> m_editorOpen{false};
    // 泵线程挂死后置位；unload 与 manager 隔离逻辑据此放弃销毁。
    std::atomic<bool> m_threadAbandoned{false};

    // IPlugView 当前打开的编辑器视图（泵线程独占访问）。
    Steinberg::IPlugView* m_view = nullptr;
    // C4：上次交给 view 的尺寸，防 resizeView → SetWindowPos → WM_SIZE →
    // onSize → resizeView 的回环。
    int m_lastViewW = 0;
    int m_lastViewH = 0;
    // frame 必须存活到编辑器关闭（插件会回调 setFrame 指针）。
    AuraPlugFrame m_plugFrame;

    // ---- 共享 plugin main 线程（C1 2026-10-12，按模块共享）----
    // B3 时为每实例一条线程；C1 多槽挂载同一 DLL 时两条线程会互斥 JUCE
    // MessageManager 归属 → 死锁，故改为按规范化二进制路径共享
    // （ModulePumpThread::acquire），引用计数归零时线程才停。
    std::shared_ptr<ModulePumpThread> m_pump;
    std::string m_moduleKey;
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

// 实例工厂：slots TU 经此创建（头里声明），不直引具体类。
std::unique_ptr<IPluginInstance> createClapInstance() {
    return std::make_unique<ClapPluginInstance>();
}

std::unique_ptr<IPluginInstance> createVst3Instance() {
    return std::make_unique<Vst3PluginInstance>();
}
} // namespace auradsp
