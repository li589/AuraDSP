#include "plugin_host.h"
#include "auradsp_engine.h"
#include "debug_log.h"
#include "module_pump.h"
#include "plugin_bundle.h"
#include "plugin_metadata_util.h"
#include "vst3_metadata.h"
#include "win32_util.h"

#include <steinberg/vst3_static.h>
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace fs = std::filesystem;

namespace auradsp {

static Steinberg::Vst::SpeakerArrangement arrangementForChannels(int channels) {
    switch (channels) {
        case 1: return Steinberg::Vst::SpeakerArr::kMono;
        case 4: return Steinberg::Vst::SpeakerArr::k40Music;
        case 6: return Steinberg::Vst::SpeakerArr::k51;
        case 8: return Steinberg::Vst::SpeakerArr::k71Music;
        default: return Steinberg::Vst::SpeakerArr::kStereo;
    }
}

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

/* 插件编辑器隔离名单——数据驱动，UI/预设层维护，引擎不硬编码任何插件名。
 * g_quarantinePatterns 由 auradsp_plugin_set_editor_quarantine_list 填充
 * （逗号分隔小写子串，匹配插件 name/path）。命中名单的插件关闭编辑器时
 * 跳过 removed()/release()（防插件自身 teardown fail-fast 崩溃），宿主
 * 不因插件缺陷陪葬。设计目标：jBridge / EqualizerAPO 等桥接类插件同样
 * 可按需登记。2026-10-19 从硬编码迁移为运行时数据。 */
static std::vector<std::string> g_quarantinePatterns;
static std::mutex g_quarantineMutex;

static void pluginSetEditorQuarantineList(const char* patterns) {
    std::lock_guard<std::mutex> lk(g_quarantineMutex);
    g_quarantinePatterns.clear();
    if (!patterns || !*patterns) return;
    std::string s = patterns;
    size_t start = 0;
    for (;;) {
        const size_t comma = s.find(',', start);
        std::string tok = s.substr(
            start, comma == std::string::npos ? std::string::npos : comma - start);
        auto notSpace = [](char c) { return !std::isspace((unsigned char)c); };
        const auto b = std::find_if(tok.begin(), tok.end(), notSpace);
        const auto e = std::find_if(tok.rbegin(), tok.rend(), notSpace).base();
        if (b < e) {
            std::string pat(b, e);
            for (auto& c : pat) c = (char)std::tolower((unsigned char)c);
            g_quarantinePatterns.push_back(pat);
        }
        if (comma == std::string::npos) break;
        start = comma + 1;
    }
}

static bool editorQuarantineMatch(const std::string& name, const std::string& path) {
    std::lock_guard<std::mutex> lk(g_quarantineMutex);
    if (g_quarantinePatterns.empty()) return false;
    std::string ln = name, lp = path;
    for (auto& c : ln) c = (char)std::tolower((unsigned char)c);
    for (auto& c : lp) c = (char)std::tolower((unsigned char)c);
    for (const auto& p : g_quarantinePatterns) {
        if (ln.find(p) != std::string::npos) return true;
        if (lp.find(p) != std::string::npos) return true;
    }
    return false;
}

/* C ABI：设置隔离名单（预设系统数据）。patterns 逗号分隔；NULL/空串清空。 */
extern "C" int auradsp_plugin_set_editor_quarantine_list(const char* patterns) {
    pluginSetEditorQuarantineList(patterns);
    return 1;
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
        std::string binaryPath = resolvePluginBundleBinary(path, ".vst3", &arch);
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

        int32_t numInBusses = m_component->getBusCount(Steinberg::Vst::kAudio, Steinberg::Vst::kInput);
        int32_t numOutBusses = m_component->getBusCount(Steinberg::Vst::kAudio, Steinberg::Vst::kOutput);
        if (numInBusses < 0) numInBusses = 0;
        if (numOutBusses <= 0) numOutBusses = 1;
        m_numInputBusses = numInBusses;
        m_numOutputBusses = numOutBusses;
        std::vector<uint8_t> inDefault(static_cast<size_t>(numInBusses), 0);
        std::vector<uint8_t> inCV(static_cast<size_t>(numInBusses), 0);
        std::vector<uint8_t> outCV(static_cast<size_t>(numOutBusses), 0);
        for (int32_t i = 0; i < numInBusses; ++i) {
            Steinberg::Vst::BusInfo bi = {};
            if (m_component->getBusInfo(Steinberg::Vst::kAudio, Steinberg::Vst::kInput, i, bi) ==
                Steinberg::kResultOk) {
                inDefault[i] = (bi.flags & Steinberg::Vst::BusInfo::kDefaultActive) ? 1 : 0;
                inCV[i] = (bi.flags & Steinberg::Vst::BusInfo::kIsControlVoltage) ? 1 : 0;
            }
        }
        for (int32_t i = 0; i < numOutBusses; ++i) {
            Steinberg::Vst::BusInfo bi = {};
            if (m_component->getBusInfo(Steinberg::Vst::kAudio, Steinberg::Vst::kOutput, i, bi) ==
                Steinberg::kResultOk) {
                outCV[i] = (bi.flags & Steinberg::Vst::BusInfo::kIsControlVoltage) ? 1 : 0;
            }
        }
        /* process 在 RT 线程禁止堆分配：总线数在 activate 后不变，
         * 这里一次性分配，process 只填充/复用。 */
        m_inBusses.assign(static_cast<size_t>(numInBusses),
                          Steinberg::Vst::AudioBusBuffers{});
        m_outBusses.assign(static_cast<size_t>(numOutBusses),
                           Steinberg::Vst::AudioBusBuffers{});
        m_inBusChannels.assign(static_cast<size_t>(numInBusses), 0);
        m_outBusChannels.assign(static_cast<size_t>(numOutBusses), 0);
        m_inBusActive.assign(static_cast<size_t>(numInBusses), 0);
        m_outBusActive.assign(static_cast<size_t>(numOutBusses), 0);
        m_auxInBuffers.assign(static_cast<size_t>(numInBusses), {});
        m_auxInPtrs.assign(static_cast<size_t>(numInBusses), {});
        m_auxOutBuffers.assign(static_cast<size_t>(numOutBusses), {});
        m_auxOutPtrs.assign(static_cast<size_t>(numOutBusses), {});

        std::vector<Steinberg::Vst::SpeakerArrangement> inArrs(
            static_cast<size_t>(numInBusses), Steinberg::Vst::SpeakerArr::kStereo);
        std::vector<Steinberg::Vst::SpeakerArrangement> outArrs(
            static_cast<size_t>(numOutBusses), Steinberg::Vst::SpeakerArr::kStereo);

        for (int32_t i = 0; i < numInBusses; ++i) {
            Steinberg::Vst::SpeakerArrangement cur = Steinberg::Vst::SpeakerArr::kStereo;
            if (m_processor->getBusArrangement(Steinberg::Vst::kInput, i, cur) == Steinberg::kResultOk &&
                cur != 0) {
                inArrs[i] = cur;
            }
        }
        for (int32_t i = 0; i < numOutBusses; ++i) {
            Steinberg::Vst::SpeakerArrangement cur = Steinberg::Vst::SpeakerArr::kStereo;
            if (m_processor->getBusArrangement(Steinberg::Vst::kOutput, i, cur) == Steinberg::kResultOk &&
                cur != 0) {
                outArrs[i] = cur;
            }
        }

        const std::vector<Steinberg::Vst::SpeakerArrangement> defaultInArrs = inArrs;
        const std::vector<Steinberg::Vst::SpeakerArrangement> defaultOutArrs = outArrs;
        const Steinberg::Vst::SpeakerArrangement mainArr =
            arrangementForChannels(m_channelHint);
        if (numInBusses > 0) inArrs[0] = mainArr;
        if (numOutBusses > 0) outArrs[0] = mainArr;

        Steinberg::tresult arrRes =
            m_processor->setBusArrangements(inArrs.data(), numInBusses, outArrs.data(), numOutBusses);
        if (arrRes != Steinberg::kResultOk) {
            inArrs = defaultInArrs;
            outArrs = defaultOutArrs;
            arrRes = m_processor->setBusArrangements(inArrs.data(), numInBusses,
                                                     outArrs.data(), numOutBusses);
        }

        // Setup processing (must be in disabled state, before activateBus/setActive)
        Steinberg::Vst::ProcessSetup setup = {};
        setup.processMode = Steinberg::Vst::kRealtime;
        setup.sampleRate = sampleRate;
        setup.maxSamplesPerBlock = maxBlockSize;
        setup.symbolicSampleSize = Steinberg::Vst::kSample32;

        if (m_processor->setupProcessing(setup) != Steinberg::kResultOk) {
            return false;
        }

        const Steinberg::tresult activeRes = m_component->setActive(true);
        if (activeRes != Steinberg::kResultOk) {
            return false;
        }

        for (int32_t i = 0; i < numInBusses; ++i) {
            const bool want = (i == 0) || (inDefault[i] && !inCV[i]);
            const Steinberg::tresult r =
                m_component->activateBus(Steinberg::Vst::kAudio, Steinberg::Vst::kInput, i, want);
            m_inBusActive[i] = (want && r == Steinberg::kResultOk) ? 1 : 0;
        }
        for (int32_t i = 0; i < numOutBusses; ++i) {
            const bool want = !outCV[i];
            const Steinberg::tresult r =
                m_component->activateBus(Steinberg::Vst::kAudio, Steinberg::Vst::kOutput, i, want);
            m_outBusActive[i] = (want && r == Steinberg::kResultOk) ? 1 : 0;
        }

        if (numInBusses > 0) {
            Steinberg::Vst::SpeakerArrangement finalIn = Steinberg::Vst::SpeakerArr::kStereo;
            if (m_processor->getBusArrangement(Steinberg::Vst::kInput, 0, finalIn) == Steinberg::kResultOk) {
                m_inChannels = Steinberg::Vst::SpeakerArr::getChannelCount(finalIn);
            } else {
                m_inChannels = 2;
            }
            if (m_inChannels < 1) m_inChannels = 1;
            if (m_inChannels > 8) m_inChannels = 8;
            m_inBusChannels[0] = m_inChannels;
        } else {
            m_inChannels = 0;
        }
        for (int32_t i = 1; i < numInBusses; ++i) {
            if (!m_inBusActive[i]) continue;
            Steinberg::Vst::SpeakerArrangement arr = Steinberg::Vst::SpeakerArr::kStereo;
            int32_t ch = 2;
            if (m_processor->getBusArrangement(Steinberg::Vst::kInput, i, arr) == Steinberg::kResultOk) {
                ch = Steinberg::Vst::SpeakerArr::getChannelCount(arr);
            }
            if (ch < 0) ch = 0;
            if (ch > 16) ch = 16;
            m_inBusChannels[i] = ch;
        }

        Steinberg::Vst::SpeakerArrangement finalOut = Steinberg::Vst::SpeakerArr::kStereo;
        if (m_processor->getBusArrangement(Steinberg::Vst::kOutput, 0, finalOut) == Steinberg::kResultOk) {
            m_outChannels = Steinberg::Vst::SpeakerArr::getChannelCount(finalOut);
        } else {
            m_outChannels = 2;
        }
        if (m_outChannels < 1) m_outChannels = 1;
        if (m_outChannels > 8) m_outChannels = 8;
        m_outBusChannels[0] = m_outChannels;
        for (int32_t i = 1; i < numOutBusses; ++i) {
            if (!m_outBusActive[i]) continue;
            Steinberg::Vst::SpeakerArrangement arr = Steinberg::Vst::SpeakerArr::kStereo;
            int32_t ch = 2;
            if (m_processor->getBusArrangement(Steinberg::Vst::kOutput, i, arr) == Steinberg::kResultOk) {
                ch = Steinberg::Vst::SpeakerArr::getChannelCount(arr);
            }
            if (ch < 0) ch = 0;
            if (ch > 16) ch = 16;
            m_outBusChannels[i] = ch;
        }

        for (int32_t i = 1; i < numInBusses; ++i) {
            const int32_t ch = m_inBusChannels[i];
            if (ch <= 0) continue;
            m_auxInBuffers[i].assign(static_cast<size_t>(ch),
                                     std::vector<float>(maxBlockSize, 0.0f));
            m_auxInPtrs[i].resize(static_cast<size_t>(ch));
            for (int32_t c = 0; c < ch; ++c) m_auxInPtrs[i][c] = m_auxInBuffers[i][c].data();
        }
        for (int32_t i = 1; i < numOutBusses; ++i) {
            const int32_t ch = m_outBusChannels[i];
            if (ch <= 0) continue;
            m_auxOutBuffers[i].assign(static_cast<size_t>(ch),
                                      std::vector<float>(maxBlockSize, 0.0f));
            m_auxOutPtrs[i].resize(static_cast<size_t>(ch));
            for (int32_t c = 0; c < ch; ++c) m_auxOutPtrs[i][c] = m_auxOutBuffers[i][c].data();
        }

        m_busInfo = PluginBusInfo{};
        m_busInfo.inputBuses = numInBusses;
        m_busInfo.outputBuses = numOutBusses;
        m_busInfo.mainInChannels = m_inChannels;
        m_busInfo.mainOutChannels = m_outChannels;
        for (int32_t i = 1; i < numInBusses; ++i) {
            if (m_inBusActive[i] && m_inBusChannels[i] > 0) ++m_busInfo.auxInputBuses;
        }
        for (int32_t i = 1; i < numOutBusses; ++i) {
            if (m_outBusActive[i] && m_outBusChannels[i] > 0) ++m_busInfo.auxOutputBuses;
        }

        const Steinberg::tresult procRes = m_processor->setProcessing(true);
        if (procRes != Steinberg::kResultOk) {
            m_component->setActive(false);
            return false;
        }

        (void)arrRes;
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
                const int32_t copyChannels =
                    (std::min)(m_inChannels, m_outChannels);
                for (int32_t ch = 0; ch < copyChannels; ++ch) {
                    if (inChannels[ch] && outChannels[ch]) {
                        std::memcpy(outChannels[ch], inChannels[ch],
                                    numFrames * sizeof(float));
                    }
                }
            }
            return;
        }

        for (int32_t b = 0; b < m_numInputBusses; ++b) {
            auto& bus = m_inBusses[b];
            bus.silenceFlags = 0;
            if (!m_inBusActive[b] || m_inBusChannels[b] <= 0 ||
                (b > 0 && m_auxInPtrs[b].empty())) {
                bus.numChannels = 0;
                bus.channelBuffers32 = nullptr;
                continue;
            }
            if (b == 0) {
                bus.numChannels = m_inChannels;
                bus.channelBuffers32 = (Steinberg::Vst::Sample32**)inChannels;
            } else {
                for (auto& chBuf : m_auxInBuffers[b]) {
                    std::fill_n(chBuf.begin(),
                                std::min<size_t>(numFrames, chBuf.size()), 0.0f);
                }
                bus.numChannels = m_inBusChannels[b];
                bus.channelBuffers32 = m_auxInPtrs[b].data();
            }
        }

        for (int32_t b = 0; b < m_numOutputBusses; ++b) {
            auto& bus = m_outBusses[b];
            bus.silenceFlags = 0;
            if (!m_outBusActive[b] || m_outBusChannels[b] <= 0 ||
                (b > 0 && m_auxOutPtrs[b].empty())) {
                bus.numChannels = 0;
                bus.channelBuffers32 = nullptr;
                continue;
            }
            if (b == 0) {
                bus.numChannels = m_outChannels;
                bus.channelBuffers32 = (Steinberg::Vst::Sample32**)outChannels;
            } else {
                bus.numChannels = m_outBusChannels[b];
                bus.channelBuffers32 = m_auxOutPtrs[b].data();
            }
        }

        Steinberg::Vst::ProcessContext context = {};
        context.state = Steinberg::Vst::ProcessContext::kPlaying |
                        Steinberg::Vst::ProcessContext::kProjectTimeMusicValid |
                        Steinberg::Vst::ProcessContext::kBarPositionValid |
                        Steinberg::Vst::ProcessContext::kCycleValid |
                        Steinberg::Vst::ProcessContext::kTempoValid |
                        Steinberg::Vst::ProcessContext::kTimeSigValid |
                        Steinberg::Vst::ProcessContext::kContTimeValid |
                        Steinberg::Vst::ProcessContext::kSystemTimeValid;
        context.sampleRate = m_sampleRate;
        context.tempo = 120.0;
        context.timeSigNumerator = 4;
        context.timeSigDenominator = 4;
        context.barPositionMusic = 0.0;
        context.cycleStartMusic = 0.0;
        context.cycleEndMusic = 4.0;
        context.projectTimeMusic = 0.0;
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
        data.numInputs = m_numInputBusses;
        data.outputs = m_outBusses.data();
        data.numOutputs = m_numOutputBusses;
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
    void setChannelHint(int channels) override {
        if (channels < 1) channels = 1;
        if (channels > 8) channels = 8;
        m_channelHint = channels;
    }
    uint32_t getLatency() const override { return m_meta.latency; }
    const PluginMetadata& getMetadata() const override { return m_meta; }
    PluginBusInfo busInfo() const override { return m_busInfo; }

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
    int32_t m_channelHint = 2;
    int32_t m_numInputBusses = 1;
    int32_t m_numOutputBusses = 1;
    std::vector<Steinberg::Vst::AudioBusBuffers> m_inBusses;
    std::vector<Steinberg::Vst::AudioBusBuffers> m_outBusses;
    std::vector<int32_t> m_inBusChannels;
    std::vector<int32_t> m_outBusChannels;
    std::vector<uint8_t> m_inBusActive;
    std::vector<uint8_t> m_outBusActive;
    std::vector<std::vector<std::vector<float>>> m_auxInBuffers;
    std::vector<std::vector<float*>> m_auxInPtrs;
    std::vector<std::vector<std::vector<float>>> m_auxOutBuffers;
    std::vector<std::vector<float*>> m_auxOutPtrs;
    PluginBusInfo m_busInfo;

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
std::unique_ptr<IPluginInstance> createVst3Instance() {
    return std::make_unique<Vst3PluginInstance>();
}

} // namespace auradsp
