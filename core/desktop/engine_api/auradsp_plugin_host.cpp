/*
 * auradsp_plugin_host.cpp — AuraDSP M1 Plugin Host Engine (VST3 / CLAP 64-bit)
 *
 * Implements in-process plugin hosting for VST3 and CLAP plugins on Windows x64.
 */

#include "auradsp_plugin_host.h"

#include <windows.h>
#include <winver.h>
#pragma comment(lib, "version.lib")
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
            std::cout << "[DBG VST3] createInstance IMessage res=" << res << " ptr=" << *obj << std::endl;
            return res;
        }
        if (std::memcmp(cid, Steinberg::Vst::IAttributeList::iid.toTUID(), sizeof(Steinberg::TUID)) == 0) {
            AuraAttributeList* attr = new AuraAttributeList();
            Steinberg::tresult res = attr->queryInterface(_iid, obj);
            attr->release();
            std::cout << "[DBG VST3] createInstance IAttributeList res=" << res << " ptr=" << *obj << std::endl;
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
        std::cout << "[DBG VST3] AuraHostApplication::createInstance unsupported cid=" << cbuf << " iid=" << ibuf << std::endl;
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

static std::string wideToUtf8(const std::wstring& wide) {
    if (wide.empty()) return std::string();
    int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 0) return std::string();
    std::string utf8(size - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, &utf8[0], size, nullptr, nullptr);
    return utf8;
}

static void setupPluginDllDirectories(const std::string& pluginPath) {
    try {
        SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_USER_DIRS);
        fs::path p(pluginPath);
        fs::path dir = fs::is_directory(p) ? p : p.parent_path();
        AddDllDirectory(dir.wstring().c_str());

        std::string pLow = pluginPath;
        std::transform(pLow.begin(), pLow.end(), pLow.begin(), ::tolower);
        if (pLow.find("izotope") != std::string::npos || pLow.find("ozone") != std::string::npos) {
            const wchar_t* izDirs[] = {
                L"C:\\Program Files\\iZotope\\Ozone 12\\Cores",
                L"C:\\Program Files\\iZotope\\Ozone 12\\win64",
                L"C:\\Program Files\\iZotope\\Ozone 12",
                L"C:\\Program Files\\iZotope\\Ozone 12 Equalizer\\Crash Reporter",
                L"C:\\Program Files\\iZotope\\RX 12 Audio Editor\\Cores",
                L"C:\\Program Files\\iZotope\\RX 12 Audio Editor\\win64"
            };
            for (const auto* d : izDirs) {
                if (fs::exists(d)) {
                    AddDllDirectory(d);
                }
            }
        }
    } catch (...) {}
}

static std::string extractVendorFromPath(const std::string& filePath) {
    try {
        fs::path p(filePath);
        while (p.has_filename() && (p.extension() == ".vst3" || p.extension() == ".clap" ||
               p.filename() == "Contents" || p.filename() == "x86_64-win" || p.filename() == "Resources")) {
            p = p.parent_path();
        }

        while (p.has_filename()) {
            std::string folderName = p.filename().string();
            std::string lowerName = folderName;
            std::transform(lowerName.begin(), lowerName.end(), lowerName.begin(), ::tolower);

            if (lowerName != "vst3" && lowerName != "clap" && lowerName != "common files" &&
                lowerName != "plugins" && lowerName != "vstplugins" && lowerName != "program files" &&
                lowerName != "program files (x86)" && lowerName != "steinberg" && !lowerName.empty() &&
                folderName.back() != ':') {
                return folderName;
            }
            p = p.parent_path();
        }
    } catch (...) {
    }
    return "";
}

static std::string extractVendorByKnownSignature(const std::string& name) {
    std::string lower = name;
    std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
    if (lower.find("zebra") != std::string::npos || lower.find("diva") != std::string::npos ||
        lower.find("hive") != std::string::npos || lower.find("repro") != std::string::npos ||
        lower.find("satin") != std::string::npos || lower.find("presswerk") != std::string::npos ||
        lower.find("bazille") != std::string::npos || lower.find("twang") != std::string::npos) {
        return "u-he";
    }
    if (lower.find("kv-element") != std::string::npos || lower.find("element") != std::string::npos) {
        return "Kushview";
    }
    if (lower.find("fabfilter") != std::string::npos) {
        return "FabFilter";
    }
    if (lower.find("valhalla") != std::string::npos) {
        return "Valhalla DSP";
    }
    if (lower.find("auto-tune") != std::string::npos) {
        return "Antares";
    }
    return "";
}

static std::string extractCompanyFromVersionInfo(const std::wstring& binaryPath) {
    try {
        DWORD dummy = 0;
        DWORD size = GetFileVersionInfoSizeW(binaryPath.c_str(), &dummy);
        if (size == 0) return "";
        std::vector<BYTE> buffer(size);
        if (!GetFileVersionInfoW(binaryPath.c_str(), 0, size, buffer.data())) return "";

        struct LANGANDCODEPAGE {
            WORD wLanguage;
            WORD wCodePage;
        } *lpTranslate = nullptr;
        UINT cbTranslate = 0;
        if (VerQueryValueW(buffer.data(), L"\\VarFileInfo\\Translation", reinterpret_cast<LPVOID*>(&lpTranslate), &cbTranslate) &&
            cbTranslate >= sizeof(LANGANDCODEPAGE) && lpTranslate != nullptr) {
            for (unsigned int i = 0; i < (cbTranslate / sizeof(LANGANDCODEPAGE)); i++) {
                wchar_t subBlock[64];
                swprintf_s(subBlock, L"\\StringFileInfo\\%04x%04x\\CompanyName", lpTranslate[i].wLanguage, lpTranslate[i].wCodePage);
                LPWSTR companyName = nullptr;
                UINT companyLen = 0;
                if (VerQueryValueW(buffer.data(), subBlock, reinterpret_cast<LPVOID*>(&companyName), &companyLen) &&
                    companyLen > 0 && companyName && companyName[0] != L'\0') {
                    std::string comp = wideToUtf8(companyName);
                    if (!comp.empty()) return comp;
                }
            }
        }

        static const wchar_t* const defaultSubBlocks[] = {
            L"\\StringFileInfo\\040904b0\\CompanyName",
            L"\\StringFileInfo\\040904E4\\CompanyName",
            L"\\StringFileInfo\\000004b0\\CompanyName",
            L"\\StringFileInfo\\04090000\\CompanyName"
        };
        for (const auto* sb : defaultSubBlocks) {
            LPWSTR companyName = nullptr;
            UINT companyLen = 0;
            if (VerQueryValueW(buffer.data(), sb, reinterpret_cast<LPVOID*>(&companyName), &companyLen) &&
                companyLen > 0 && companyName && companyName[0] != L'\0') {
                std::string comp = wideToUtf8(companyName);
                if (!comp.empty()) return comp;
            }
        }
    } catch (...) {
    }
    return "";
}

static std::string extractProductVersionFromVersionInfo(const std::wstring& binaryPath) {
    try {
        DWORD dummy = 0;
        DWORD size = GetFileVersionInfoSizeW(binaryPath.c_str(), &dummy);
        if (size == 0) return "";
        std::vector<BYTE> buffer(size);
        if (!GetFileVersionInfoW(binaryPath.c_str(), 0, size, buffer.data())) return "";

        static const wchar_t* const defaultSubBlocks[] = {
            L"\\StringFileInfo\\040904b0\\ProductVersion",
            L"\\StringFileInfo\\040904E4\\ProductVersion",
            L"\\StringFileInfo\\000004b0\\ProductVersion",
            L"\\StringFileInfo\\040904b0\\FileVersion"
        };
        for (const auto* sb : defaultSubBlocks) {
            LPWSTR ver = nullptr;
            UINT verLen = 0;
            if (VerQueryValueW(buffer.data(), sb, reinterpret_cast<LPVOID*>(&ver), &verLen) &&
                verLen > 0 && ver && ver[0] != L'\0') {
                std::string v = wideToUtf8(ver);
                if (!v.empty()) return v;
            }
        }
    } catch (...) {
    }
    return "";
}

static std::string extractVendorFromLegalCopyright(const std::wstring& binaryPath) {
    try {
        DWORD dummy = 0;
        DWORD size = GetFileVersionInfoSizeW(binaryPath.c_str(), &dummy);
        if (size == 0) return "";
        std::vector<BYTE> buffer(size);
        if (!GetFileVersionInfoW(binaryPath.c_str(), 0, size, buffer.data())) return "";

        static const wchar_t* const defaultSubBlocks[] = {
            L"\\StringFileInfo\\040904b0\\LegalCopyright",
            L"\\StringFileInfo\\040904E4\\LegalCopyright",
            L"\\StringFileInfo\\000004b0\\LegalCopyright",
            L"\\StringFileInfo\\04090000\\LegalCopyright"
        };
        for (const auto* sb : defaultSubBlocks) {
            LPWSTR copyText = nullptr;
            UINT copyLen = 0;
            if (VerQueryValueW(buffer.data(), sb, reinterpret_cast<LPVOID*>(&copyText), &copyLen) &&
                copyLen > 0 && copyText && copyText[0] != L'\0') {
                std::string comp = wideToUtf8(copyText);
                if (!comp.empty()) {
                    std::string clean = comp;
                    const char* prefixes[] = {"Copyright (C) ", "Copyright (c) ", "Copyright ", "\xc2\xa9 "};
                    for (const char* pfx : prefixes) {
                        size_t pos = clean.find(pfx);
                        if (pos != std::string::npos) {
                            clean = clean.substr(pos + std::strlen(pfx));
                            break;
                        }
                    }
                    while (clean.size() >= 5 && isdigit((unsigned char)clean[0]) && isdigit((unsigned char)clean[1]) &&
                           isdigit((unsigned char)clean[2]) && isdigit((unsigned char)clean[3]) && (clean[4] == ' ' || clean[4] == '-')) {
                        clean = clean.substr(5);
                    }
                    if (!clean.empty()) return clean;
                    return comp;
                }
            }
        }
    } catch (...) {}
    return "";
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
enum class ClapHostThreadType {
    Main,
    Audio
};
static thread_local ClapHostThreadType t_clapThreadType = ClapHostThreadType::Main;

static uint32_t CLAP_ABI emptyInEventsSize(const clap_input_events_t*) { return 0; }
static const clap_event_header_t* CLAP_ABI emptyInEventsGet(const clap_input_events_t*, uint32_t) { return nullptr; }
static bool CLAP_ABI emptyOutEventsTryPush(const clap_output_events_t*, const clap_event_header_t*) { return true; }

class ClapPluginInstance : public IPluginInstance {
public:
    ClapPluginInstance() = default;
    ~ClapPluginInstance() override { unload(); }

    bool load(const std::string& path, const std::string& pluginId) override {
        unload();
        setupPluginDllDirectories(path);

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

        std::cout << "[DBG CLAP showEditor] on caller thread, calling gui->create..." << std::endl;
        bool createRes = false;
        try {
            createRes = gui->create(m_plugin, CLAP_WINDOW_API_WIN32, false);
        } catch (const std::exception& ex) {
            std::cout << "[DBG CLAP showEditor] gui->create exception: " << ex.what() << std::endl;
        } catch (...) {
            std::cout << "[DBG CLAP showEditor] gui->create unknown exception!" << std::endl;
        }
        std::cout << "[DBG CLAP showEditor] gui->create returned: " << createRes << std::endl;
        if (!createRes) {
            return false;
        }

        uint32_t width = 800, height = 600;
        if (gui->get_size) {
            try {
                gui->get_size(m_plugin, &width, &height);
            } catch (...) {}
        }
        if (width < 200) width = 800;
        if (height < 150) height = 600;
        std::cout << "[DBG CLAP showEditor] gui->get_size on caller thread: " << width << "x" << height << std::endl;

        std::promise<HWND> hwndPromise;
        auto hwndFuture = hwndPromise.get_future();

        m_editorThread = std::thread([this, width, height, &hwndPromise]() {
            t_clapThreadType = ClapHostThreadType::Main;
            EnsureWindowClassRegistered();

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
                hwndPromise.set_value(nullptr);
                return;
            }

            m_editorHwnd = hwnd;
            m_editorOpen.store(true, std::memory_order_release);
            std::cout << "[DBG CLAP showEditor] in lambda, hwnd created: " << hwnd << std::endl;

            ShowWindow(hwnd, SW_SHOW);
            UpdateWindow(hwnd);

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

            // Signal caller thread that hwnd is created and ready for set_parent
            hwndPromise.set_value(hwnd);

            MSG msg;
            while (GetMessageW(&msg, NULL, 0, 0) > 0) {
                if (msg.message == WM_CLOSE && msg.hwnd == hwnd) {
                    break;
                }
                if (msg.message == WM_TIMER && timerExt && timerExt->on_timer) {
                    clap_id cid = 0;
                    {
                        std::lock_guard<std::mutex> lock(m_timerMutex);
                        auto it = m_timerIdMap.find(msg.wParam);
                        if (it != m_timerIdMap.end()) {
                            cid = it->second;
                        }
                    }
                    if (cid != 0) {
                        timerExt->on_timer(m_plugin, cid);
                    }
                }
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }

            {
                std::lock_guard<std::mutex> lock(m_timerMutex);
                for (auto& pair : m_timers) {
                    KillTimer(hwnd, pair.second);
                }
                m_timerIdMap.clear();
            }

            auto guiExt = reinterpret_cast<const clap_plugin_gui_t*>(
                m_plugin->get_extension(m_plugin, CLAP_EXT_GUI));
            try {
                if (guiExt && guiExt->hide) guiExt->hide(m_plugin);
                if (guiExt && guiExt->destroy) guiExt->destroy(m_plugin);
            } catch (...) {}

            if (IsWindow(hwnd)) {
                DestroyWindow(hwnd);
            }
            m_editorHwnd = nullptr;
            m_editorOpen.store(false, std::memory_order_release);
        });

        // Wait for hwnd from thread
        if (hwndFuture.wait_for(std::chrono::milliseconds(2000)) != std::future_status::ready) {
            std::cout << "[DBG CLAP showEditor] Timeout waiting for hwnd creation!" << std::endl;
            if (gui->destroy) gui->destroy(m_plugin);
            return false;
        }
        HWND hwnd = hwndFuture.get();
        if (!hwnd) {
            std::cout << "[DBG CLAP showEditor] Failed to create HWND!" << std::endl;
            if (gui->destroy) gui->destroy(m_plugin);
            return false;
        }

        // Call set_parent and show on caller thread
        clap_window_t win = {};
        win.api = CLAP_WINDOW_API_WIN32;
        win.win32 = hwnd;
        std::cout << "[DBG CLAP showEditor] on caller thread, calling gui->set_parent..." << std::endl;
        bool setParentRes = false;
        try {
            if (gui->set_parent) setParentRes = gui->set_parent(m_plugin, &win);
        } catch (const std::exception& ex) {
            std::cout << "[DBG CLAP showEditor] gui->set_parent exception: " << ex.what() << std::endl;
        } catch (...) {
            std::cout << "[DBG CLAP showEditor] gui->set_parent unknown exception!" << std::endl;
        }
        std::cout << "[DBG CLAP showEditor] gui->set_parent returned: " << setParentRes << std::endl;

        std::cout << "[DBG CLAP showEditor] on caller thread, calling gui->show..." << std::endl;
        try {
            if (gui->show) gui->show(m_plugin);
        } catch (...) {}
        std::cout << "[DBG CLAP showEditor] gui->show done." << std::endl;

        return setParentRes;
    }

    void closeEditor() override {
        HWND hwnd = m_editorHwnd;
        if (hwnd && IsWindow(hwnd)) {
            PostMessageW(hwnd, WM_CLOSE, 0, 0);
        }
        if (m_editorThread.joinable()) {
            if (m_editorThread.get_id() != std::this_thread::get_id()) {
                HANDLE hThread = reinterpret_cast<HANDLE>(m_editorThread.native_handle());
                if (hThread) {
                    DWORD waitRes = WaitForSingleObject(hThread, 800);
                    if (waitRes == WAIT_OBJECT_0) {
                        m_editorThread.join();
                    } else {
                        if (hwnd && IsWindow(hwnd)) {
                            DWORD tid = GetWindowThreadProcessId(hwnd, NULL);
                            if (tid) PostThreadMessageW(tid, WM_QUIT, 0, 0);
                        }
                        m_editorThread.detach();
                    }
                } else {
                    m_editorThread.detach();
                }
            } else {
                m_editorThread.detach();
            }
        }
        m_editorOpen.store(false, std::memory_order_release);
        m_editorHwnd = nullptr;
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
        m_mainThreadId = std::this_thread::get_id();

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
        setupPluginDllDirectories(path);

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
        std::cout << "[DBG VST3] createInstance targetCid on IComponent..." << std::endl;
        Steinberg::tresult res = m_factory->createInstance(
            targetCid,
            Steinberg::Vst::IComponent::iid.toTUID(),
            reinterpret_cast<void**>(&m_component)
        );
        std::cout << "[DBG VST3] createInstance res=" << res << " component=" << m_component << std::endl;

        if (res != Steinberg::kResultOk || !m_component) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "Failed to create VST3 IComponent instance, res: " + std::to_string(res);
            FreeLibrary(m_module);
            m_module = nullptr;
            m_factory = nullptr;
            return false;
        }

        // Initialize component with host application context
        std::cout << "[DBG VST3] Initializing component with hostApp..." << std::endl;
        m_component->initialize(&m_hostApp);
        std::cout << "[DBG VST3] Component initialized." << std::endl;

        // Query IAudioProcessor
        std::cout << "[DBG VST3] Querying IAudioProcessor..." << std::endl;
        res = m_component->queryInterface(
            Steinberg::Vst::IAudioProcessor::iid,
            reinterpret_cast<void**>(&m_processor)
        );
        std::cout << "[DBG VST3] Query IAudioProcessor res=" << res << " proc=" << m_processor << std::endl;

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
        std::cout << "[DBG VST3] Querying IEditController on component..." << std::endl;
        Steinberg::tresult cRes = m_component->queryInterface(
            Steinberg::Vst::IEditController::iid,
            reinterpret_cast<void**>(&m_controller)
        );
        std::cout << "[DBG VST3] Query IEditController cRes=" << cRes << " ctrl=" << m_controller << std::endl;
        if (cRes != Steinberg::kResultOk || !m_controller) {
            Steinberg::TUID controllerCID;
            Steinberg::tresult cidRes = m_component->getControllerClassId(controllerCID);
            std::cout << "[DBG VST3] getControllerClassId res=" << cidRes << std::endl;
            if (cidRes == Steinberg::kResultOk) {
                std::cout << "[DBG VST3] Creating controller from separate CID..." << std::endl;
                Steinberg::tresult instRes = m_factory->createInstance(
                    controllerCID,
                    Steinberg::Vst::IEditController::iid.toTUID(),
                    reinterpret_cast<void**>(&m_controller)
                );
                std::cout << "[DBG VST3] createInstance controller res=" << instRes << " ptr=" << m_controller << std::endl;
                if (m_controller) {
                    std::cout << "[DBG VST3] Initializing separate controller..." << std::endl;
                    Steinberg::tresult initRes = m_controller->initialize(&m_hostApp);
                    std::cout << "[DBG VST3] Controller initialize res=" << initRes << std::endl;
                }
            }
        }

        if (m_controller) {
            // 设置 ComponentHandler（Ozone 等宿主解耦插件强依赖 handler 才能创建 Editor）
            std::cout << "[DBG VST3] setComponentHandler..." << std::endl;
            m_controller->setComponentHandler(&m_componentHandler);
            std::cout << "[DBG VST3] setComponentHandler done." << std::endl;

            // 连接 ConnectionPoint（Component 与 Controller 独立时建立互联通道）
            std::cout << "[DBG VST3] Connecting ConnectionPoints..." << std::endl;
            Steinberg::Vst::IConnectionPoint* compCP = nullptr;
            Steinberg::Vst::IConnectionPoint* ctrlCP = nullptr;
            Steinberg::tresult q1 = m_component->queryInterface(Steinberg::Vst::IConnectionPoint::iid.toTUID(), reinterpret_cast<void**>(&compCP));
            Steinberg::tresult q2 = m_controller->queryInterface(Steinberg::Vst::IConnectionPoint::iid.toTUID(), reinterpret_cast<void**>(&ctrlCP));
            std::cout << "[DBG VST3] compCP=" << compCP << " (q1=" << q1 << ") ctrlCP=" << ctrlCP << " (q2=" << q2 << ")" << std::endl;
            if (compCP && ctrlCP) {
                std::cout << "[DBG VST3] calling safeConnect(compCP, ctrlCP)..." << std::endl;
                auto safeConnect = [](Steinberg::Vst::IConnectionPoint* a, Steinberg::Vst::IConnectionPoint* b) -> int {
                    __try {
                        return (int)a->connect(b);
                    } __except (EXCEPTION_EXECUTE_HANDLER) {
                        return -999999;
                    }
                };
                int c1 = safeConnect(compCP, ctrlCP);
                std::cout << "[DBG VST3] safeConnect(compCP, ctrlCP) result=" << c1 << std::endl;
                int c2 = safeConnect(ctrlCP, compCP);
                std::cout << "[DBG VST3] safeConnect(ctrlCP, compCP) result=" << c2 << std::endl;
            }
            if (compCP) compCP->release();
            if (ctrlCP) ctrlCP->release();
            std::cout << "[DBG VST3] ConnectionPoints connected." << std::endl;

            // 同步组件初始状态给控制器
            std::cout << "[DBG VST3] Syncing component state to controller..." << std::endl;
            Vst3MemoryStream stateStream;
            Steinberg::tresult sRes = m_component->getState(&stateStream);
            std::cout << "[DBG VST3] m_component->getState res=" << sRes << " bytes=" << stateStream.m_data.size() << std::endl;
            if (sRes == Steinberg::kResultOk) {
                Steinberg::int64 seekRes = 0;
                stateStream.seek(0, Steinberg::IBStream::kIBSeekSet, &seekRes);
                Steinberg::tresult csRes = m_controller->setComponentState(&stateStream);
                std::cout << "[DBG VST3] m_controller->setComponentState res=" << csRes << std::endl;
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

        // 查询插件所声明的总线数量
        int32_t numInBusses = m_component->getBusCount(Steinberg::Vst::kAudio, Steinberg::Vst::kInput);
        int32_t numOutBusses = m_component->getBusCount(Steinberg::Vst::kAudio, Steinberg::Vst::kOutput);
        if (numInBusses <= 0) numInBusses = 1;
        if (numOutBusses <= 0) numOutBusses = 1;
        m_numInputBusses = numInBusses;
        m_numOutputBusses = numOutBusses;

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

        // 主总线协商优先设为立体声
        inArrs[0] = Steinberg::Vst::SpeakerArr::kStereo;
        outArrs[0] = Steinberg::Vst::SpeakerArr::kStereo;

        // 调用 setBusArrangements（注意：根据 VST3 规范，返回 kResultFalse 并不代表致命失败，
        // 插件可自主选择自适应或维持其默认总线配置）
        m_processor->setBusArrangements(inArrs.data(), numInBusses, outArrs.data(), numOutBusses);

        // 重新获取主总线实际确认的声道数
        Steinberg::Vst::SpeakerArrangement finalIn = Steinberg::Vst::SpeakerArr::kStereo;
        Steinberg::Vst::SpeakerArrangement finalOut = Steinberg::Vst::SpeakerArr::kStereo;
        if (m_processor->getBusArrangement(Steinberg::Vst::kInput, 0, finalIn) == Steinberg::kResultOk) {
            m_inChannels = Steinberg::Vst::SpeakerArr::getChannelCount(finalIn) == 1 ? 1 : 2;
        } else {
            m_inChannels = 2;
        }
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
        if (!inChannels || !outChannels || !inChannels[0] || !outChannels[0]) return;

        const int32_t nc = m_inChannels;
        for (int32_t ch = 1; ch < nc; ++ch) if (!inChannels[ch]) return;

        if (!m_isActive || !m_processor || m_bypassed) {
            if (inChannels != outChannels) {
                for (int32_t ch = 0; ch < nc; ++ch) {
                    if (inChannels[ch] && outChannels[ch]) {
                        std::memcpy(outChannels[ch], inChannels[ch], numFrames * sizeof(float));
                    }
                }
            }
            return;
        }

        std::vector<Steinberg::Vst::AudioBusBuffers> inBusses(m_numInputBusses);
        for (int32_t b = 0; b < m_numInputBusses; ++b) {
            if (b == 0) {
                inBusses[0].numChannels = nc;
                inBusses[0].silenceFlags = 0;
                inBusses[0].channelBuffers32 = (Steinberg::Vst::Sample32**)inChannels;
            } else {
                inBusses[b].numChannels = 0;
                inBusses[b].silenceFlags = 0;
                inBusses[b].channelBuffers32 = nullptr;
            }
        }

        std::vector<Steinberg::Vst::AudioBusBuffers> outBusses(m_numOutputBusses);
        for (int32_t b = 0; b < m_numOutputBusses; ++b) {
            if (b == 0) {
                outBusses[0].numChannels = m_outChannels;
                outBusses[0].silenceFlags = 0;
                outBusses[0].channelBuffers32 = (Steinberg::Vst::Sample32**)outChannels;
            } else {
                outBusses[b].numChannels = 0;
                outBusses[b].silenceFlags = 0;
                outBusses[b].channelBuffers32 = nullptr;
            }
        }

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
        data.inputs = inBusses.data();
        data.numInputs = static_cast<Steinberg::int32>(inBusses.size());
        data.outputs = outBusses.data();
        data.numOutputs = static_cast<Steinberg::int32>(outBusses.size());
        data.inputParameterChanges = nullptr;
        data.outputParameterChanges = nullptr;
        data.inputEvents = nullptr;
        data.outputEvents = nullptr;
        data.processContext = &context;

        Steinberg::tresult res = m_processor->process(data);
        if (res != Steinberg::kResultOk) {
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

    bool showEditor(void* parentHwnd = nullptr) override {
        if (!m_isLoaded || !m_component) return false;
        setupPluginDllDirectories(m_meta.path);
        if (m_editorOpen.load(std::memory_order_acquire) && m_editorHwnd && IsWindow(m_editorHwnd)) {
            SetForegroundWindow(m_editorHwnd);
            ShowWindow(m_editorHwnd, SW_SHOW);
            return true;
        }
        if (m_editorThread.joinable()) {
            m_editorThread.join();
        }

        if (!m_controller) {
            std::cout << "[DBG VST3 showEditor] m_controller is NULL!" << std::endl;
            return false;
        }
        Steinberg::IPlugView* view = m_controller->createView(Steinberg::Vst::ViewType::kEditor);
        std::cout << "[DBG VST3 showEditor] createView(kEditor) returned: " << view << std::endl;
        if (!view) {
            view = m_controller->createView(nullptr);
            std::cout << "[DBG VST3 showEditor] createView(nullptr) returned: " << view << std::endl;
        }
        if (!view) {
            view = m_controller->createView("Editor");
            std::cout << "[DBG VST3 showEditor] createView(\"Editor\") returned: " << view << std::endl;
        }
        if (!view) {
            // Check if controller or component itself is IPlugView
            Steinberg::IPlugView* pv = nullptr;
            if (m_controller->queryInterface(Steinberg::IPlugView::iid.toTUID(), reinterpret_cast<void**>(&pv)) == Steinberg::kResultOk && pv) {
                std::cout << "[DBG VST3 showEditor] controller implements IPlugView!" << std::endl;
                view = pv;
            } else if (m_component->queryInterface(Steinberg::IPlugView::iid.toTUID(), reinterpret_cast<void**>(&pv)) == Steinberg::kResultOk && pv) {
                std::cout << "[DBG VST3 showEditor] component implements IPlugView!" << std::endl;
                view = pv;
            }
        }
        if (!view) return false;
        Steinberg::tresult platSup = view->isPlatformTypeSupported(Steinberg::kPlatformTypeHWND);
        std::cout << "[DBG VST3 showEditor] isPlatformTypeSupported(HWND) returned: " << platSup << std::endl;
        if (platSup != Steinberg::kResultTrue) {
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

            AuraPlugFrame frame;
            frame.m_hwnd = hwnd;
            view->setFrame(&frame);

            try {
                Steinberg::tresult attachRes = view->attached(reinterpret_cast<void*>(hwnd), Steinberg::kPlatformTypeHWND);
                if (attachRes != Steinberg::kResultOk && attachRes != Steinberg::kResultTrue) {
                    std::cout << "[DBG VST3 showEditor] view->attached returned non-ok: " << attachRes << std::endl;
                    view->setFrame(nullptr);
                    view->release();
                    if (IsWindow(hwnd)) DestroyWindow(hwnd);
                    initPromise.set_value(false);
                    return;
                }
            } catch (const std::exception& ex) {
                std::cout << "[DBG VST3 showEditor] view->attached exception: " << ex.what() << std::endl;
                view->setFrame(nullptr);
                view->release();
                if (IsWindow(hwnd)) DestroyWindow(hwnd);
                initPromise.set_value(false);
                return;
            } catch (...) {
                std::cout << "[DBG VST3 showEditor] view->attached unknown exception!" << std::endl;
                view->setFrame(nullptr);
                view->release();
                if (IsWindow(hwnd)) DestroyWindow(hwnd);
                initPromise.set_value(false);
                return;
            }

            ShowWindow(hwnd, SW_SHOW);
            UpdateWindow(hwnd);

            initPromise.set_value(true);

            MSG msg;
            while (GetMessageW(&msg, NULL, 0, 0) > 0) {
                if (msg.message == WM_CLOSE && msg.hwnd == hwnd) {
                    break;
                }
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }

            view->setFrame(nullptr);
            view->removed();
            view->release();
            if (IsWindow(hwnd)) {
                DestroyWindow(hwnd);
            }
            m_editorHwnd = nullptr;
            m_editorOpen.store(false, std::memory_order_release);
        });

        if (initFuture.wait_for(std::chrono::milliseconds(3000)) != std::future_status::ready) {
            std::cout << "[DBG VST3 showEditor] Timeout waiting for editor window to open!" << std::endl;
            return false;
        }
        return initFuture.get();
    }

    void closeEditor() override {
        HWND hwnd = m_editorHwnd;
        if (hwnd && IsWindow(hwnd)) {
            PostMessageW(hwnd, WM_CLOSE, 0, 0);
        }
        if (m_editorThread.joinable()) {
            if (m_editorThread.get_id() != std::this_thread::get_id()) {
                HANDLE hThread = reinterpret_cast<HANDLE>(m_editorThread.native_handle());
                if (hThread) {
                    DWORD waitRes = WaitForSingleObject(hThread, 800);
                    if (waitRes == WAIT_OBJECT_0) {
                        m_editorThread.join();
                    } else {
                        if (hwnd && IsWindow(hwnd)) {
                            DWORD tid = GetWindowThreadProcessId(hwnd, NULL);
                            if (tid) PostThreadMessageW(tid, WM_QUIT, 0, 0);
                        }
                        m_editorThread.detach();
                    }
                } else {
                    m_editorThread.detach();
                }
            } else {
                m_editorThread.detach();
            }
        }
        m_editorOpen.store(false, std::memory_order_release);
        m_editorHwnd = nullptr;
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

    AuraComponentHandler m_componentHandler;
    AuraHostApplication m_hostApp;

    PluginMetadata m_meta;
    bool m_isLoaded = false;
    bool m_isActive = false;
    bool m_bypassed = false;
    double m_sampleRate = 48000.0;
    uint32_t m_maxBlockSize = 1024;
    int32_t m_inChannels = 2;
    int32_t m_outChannels = 2;
    int32_t m_numInputBusses = 1;
    int32_t m_numOutputBusses = 1;

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
                        meta.vendor = (d->vendor && d->vendor[0] != '\0') ? d->vendor : "Unknown";
                        meta.version = (d->version && d->version[0] != '\0') ? d->version : "1.0";
                        meta.category = (d->description && d->description[0] != '\0') ? d->description : "AudioEffect";

                        if (meta.vendor == "Unknown") {
                            std::string peComp = extractCompanyFromVersionInfo(wpath);
                            if (!peComp.empty()) {
                                meta.vendor = peComp;
                            } else {
                                std::string dirV = extractVendorFromPath(filePath);
                                if (!dirV.empty()) meta.vendor = dirV;
                                else {
                                    std::string sigV = extractVendorByKnownSignature(meta.name);
                                    if (!sigV.empty()) meta.vendor = sigV;
                                }
                            }
                        }
                        if (meta.version == "1.0") {
                            std::string peVer = extractProductVersionFromVersionInfo(wpath);
                            if (!peVer.empty()) meta.version = peVer;
                        }

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
                    Steinberg::IPluginFactory3* factory3 = nullptr;
                    factory->queryInterface(Steinberg::IPluginFactory2::iid, reinterpret_cast<void**>(&factory2));
                    factory->queryInterface(Steinberg::IPluginFactory3::iid, reinterpret_cast<void**>(&factory3));

                    // 1. 全局工厂厂商
                    std::string factoryVendor;
                    Steinberg::PFactoryInfo factoryInfo;
                    if (factory->getFactoryInfo(&factoryInfo) == Steinberg::kResultOk) {
                        if (factoryInfo.vendor[0] != '\0') {
                            factoryVendor = factoryInfo.vendor;
                        }
                    }

                    // 2. 预先提取 PE VersionInfo 与上级目录启发式名称
                    std::string peVendor = extractCompanyFromVersionInfo(wpath);
                    std::string peVersion = extractProductVersionFromVersionInfo(wpath);
                    std::string dirVendor = extractVendorFromPath(filePath);

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

                            // 优先从 IPluginFactory3 读取 Unicode 类信息
                            if (factory3) {
                                Steinberg::PClassInfoW classInfoW;
                                if (factory3->getClassInfoUnicode(i, &classInfoW) == Steinberg::kResultOk) {
                                    if (classInfoW.name[0] != 0) {
                                        std::string uName = wideToUtf8(Steinberg::wscast(classInfoW.name));
                                        if (!uName.empty()) meta.name = uName;
                                    }
                                    if (classInfoW.vendor[0] != 0) {
                                        std::string uVendor = wideToUtf8(Steinberg::wscast(classInfoW.vendor));
                                        if (!uVendor.empty()) meta.vendor = uVendor;
                                    }
                                    if (classInfoW.version[0] != 0) {
                                        std::string uVer = wideToUtf8(Steinberg::wscast(classInfoW.version));
                                        if (!uVer.empty()) meta.version = uVer;
                                    }
                                    if (classInfoW.subCategories[0] != 0) {
                                        meta.category = classInfoW.subCategories;
                                    }
                                }
                            }

                            // 尝试 IPluginFactory2 补充
                            if (factory2) {
                                Steinberg::PClassInfo2 classInfo2;
                                if (factory2->getClassInfo2(i, &classInfo2) == Steinberg::kResultOk) {
                                    if (meta.vendor == "Unknown" && classInfo2.vendor[0]) {
                                        meta.vendor = classInfo2.vendor;
                                    }
                                    if ((meta.version.empty() || meta.version == "1.0") && classInfo2.version[0]) {
                                        meta.version = classInfo2.version;
                                    }
                                    if (classInfo2.subCategories[0]) {
                                        meta.category = classInfo2.subCategories;
                                    }
                                }
                            }

                            // 多级回退兜底厂商：factoryVendor -> peVendor -> dirVendor -> 知名特征签名
                            if (meta.vendor == "Unknown" || meta.vendor.empty()) {
                                if (!factoryVendor.empty()) meta.vendor = factoryVendor;
                                else if (!peVendor.empty()) meta.vendor = peVendor;
                                else if (!dirVendor.empty()) meta.vendor = dirVendor;
                                else {
                                    std::string sigV = extractVendorByKnownSignature(meta.name);
                                    if (!sigV.empty()) meta.vendor = sigV;
                                }
                            }

                            // 多级回退兜底版本
                            if ((meta.version.empty() || meta.version == "1.0") && !peVersion.empty()) {
                                meta.version = peVersion;
                            }

                            outPlugins.push_back(meta);
                            success = true;
                        }
                    }

                    if (factory3) factory3->release();
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

                auto makeQuickMeta = [&](const std::string& pStr, const std::string& nStr, PluginFormat fmt) -> PluginMetadata {
                    std::wstring wp = utf8ToWide(pStr);
                    std::string peV = extractCompanyFromVersionInfo(wp);
                    std::string copyV = extractVendorFromLegalCopyright(wp);
                    std::string peVer = extractProductVersionFromVersionInfo(wp);
                    std::string dirV = extractVendorFromPath(pStr);
                    std::string sigV = extractVendorByKnownSignature(nStr);

                    std::string vendor = !peV.empty() ? peV : (!copyV.empty() ? copyV : (!dirV.empty() ? dirV : (!sigV.empty() ? sigV : "Unknown")));

                    // CLAP 格式轻量查询元数据以精确获取 id/vendor
                    if (fmt == PluginFormat::CLAP) {
                        std::vector<PluginMetadata> clapMetas;
                        if (queryMetadata(pStr, fmt, clapMetas) && !clapMetas.empty()) {
                            return clapMetas[0];
                        }
                    }

                    PluginMetadata q;
                    q.path = pStr;
                    q.name = nStr;
                    q.format = fmt;
                    q.is64Bit = true;
                    q.vendor = vendor;
                    q.version = !peVer.empty() ? peVer : "1.0";
                    q.category = "AudioEffect";
                    return q;
                };

                if (format == PluginFormat::CLAP) {
                    std::vector<PluginMetadata> clapMetas;
                    if (queryMetadata(pathStr, format, clapMetas) && !clapMetas.empty()) {
                        for (const auto& m : clapMetas) {
                            results.push_back(m);
                        }
                        continue;
                    }
                }

                if (deepScan) {
                    std::vector<PluginMetadata> deepMeta;
                    if (queryMetadata(pathStr, format, deepMeta)) {
                        for (const auto& m : deepMeta) {
                            results.push_back(m);
                        }
                    } else {
                        results.push_back(makeQuickMeta(pathStr, nameStr, format));
                    }
                } else {
                    results.push_back(makeQuickMeta(pathStr, nameStr, format));
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
    s.hasActive.store(false, std::memory_order_release);
    s.destroyPending.store(true, std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_acquire);

    uint32_t spins = 0;
    while (s.inFlight.load(std::memory_order_relaxed) != 0 && spins < kQuiesceSpinLimit) {
        s.inFlight.wait(0, std::memory_order_relaxed);
        ++spins;
    }
    s.destroyPending.store(false, std::memory_order_relaxed);
    // 强制排空安全兜底：即便音频流非活动导致计数悬垂，也绝不能锁死用户卸载
    s.inFlight.store(0, std::memory_order_relaxed);

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

        bool lRet = instance->load(path, pluginId);
        std::cout << "[DBG PluginHost] instance->load returned: " << lRet << std::endl;
        if (!lRet) {
            return false;
        }

        bool aRet = instance->activate(sampleRate, maxBlockSize);
        std::cout << "[DBG PluginHost] instance->activate returned: " << aRet << std::endl;
        if (!aRet) {
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

// Legacy single-slot forward (slot 0).
// Only loadPlugin survives: it is the one still referenced by
// test/smoke/test_plugin_direct.cpp. The other six (unloadPlugin, setBypass,
// isBypassed, getLatency, hasActivePlugin, getStatusJson, process) had no
// callers anywhere in the repo -- the C ABI's own single-slot compatibility
// symbols forward straight to the *Slot functions and never used them.
bool PluginHostManager::loadPlugin(const std::string& path, const std::string& pluginId, double sampleRate, uint32_t maxBlockSize) {
    return loadPluginSlot(0, path, pluginId, sampleRate, maxBlockSize);
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
