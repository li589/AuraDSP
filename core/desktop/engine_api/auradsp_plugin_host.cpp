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
#include <functional>
#include <deque>
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
// CLAP plugin main thread（B3-② 2026-10-12）
//------------------------------------------------------------------------------
// 唤醒泵线程执行任务队列的消息。
constexpr UINT WM_APP_CLAP_TASK = WM_APP + 0x1A2;

// CLAP 容器窗口的过程函数：生命周期完全由 plugin main 线程的泵循环管理
// （WM_CLOSE 在泵循环里截获并触发编辑器收尾）。刻意不在 WM_DESTROY 里
// PostQuitMessage —— 该线程是长寿命的 plugin main 线程（还承载后续的
// unload / 重新 showEditor），绝不能被一次编辑器关闭杀掉。
static LRESULT CALLBACK ClapHostWindowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void EnsureClapWindowClassRegistered() {
    static std::once_flag flag;
    std::call_once(flag, []() {
        WNDCLASSEXW wc = {sizeof(WNDCLASSEXW)};
        wc.lpfnWndProc = ClapHostWindowProc;
        wc.hInstance = GetModuleHandleW(NULL);
        wc.lpszClassName = L"AuraDSP_CLAP_Host_Window";
        wc.hCursor = LoadCursor(NULL, IDC_ARROW);
        wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
        RegisterClassExW(&wc);
    });
}

//------------------------------------------------------------------------------
// VST3 plugin main thread（B3 2026-10-12，镜像 CLAP 重构）
//------------------------------------------------------------------------------
// 唤醒 VST3 泵线程执行任务队列的消息。
constexpr UINT WM_APP_VST3_TASK = WM_APP + 0x1A3;

// VST3 编辑器容器窗口的过程函数：生命周期由 plugin main 线程的泵循环管理
// （WM_CLOSE 在泵循环里截获并触发编辑器收尾）。刻意不在 WM_DESTROY 里
// PostQuitMessage——该线程是长寿命的 plugin main 线程，绝不能被一次编辑器
// 关闭杀掉。旧 AuraDSP_Plugin_Host_Window 的 WndProc 带 PostQuitMessage，
// 不能承载泵线程，故 VST3 编辑器窗口改用本类。
static LRESULT CALLBACK Vst3HostWindowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void EnsureVst3WindowClassRegistered() {
    static std::once_flag flag;
    std::call_once(flag, []() {
        WNDCLASSEXW wc = {sizeof(WNDCLASSEXW)};
        wc.lpfnWndProc = Vst3HostWindowProc;
        wc.hInstance = GetModuleHandleW(NULL);
        wc.lpszClassName = L"AuraDSP_VST3_Host_Window";
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

/// 扩展名大小写不敏感比较（lowerExt 必须已是小写）。
/// Windows 文件系统不区分大小写：bundle 内二进制叫 foo.VST3 与 foo.vst3
/// 必须等价。严格比较曾让大写扩展名的整包在扫描中静默消失（违反 D 类契约），
/// scan() 入口已做 ::tolower 归一化，这里补上内层探测的同款归一化。
static bool extensionEqualsCI(const fs::path& p, const char* lowerExt) {
    std::string ext = p.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    return ext == lowerExt;
}

static std::string extractVendorFromPath(const std::string& filePath) {
    try {
        fs::path p(filePath);
        while (p.has_filename() && (extensionEqualsCI(p, ".vst3") || extensionEqualsCI(p, ".clap") ||
               p.filename() == "Contents" || p.filename() == "x86_64-win" ||
               p.filename() == "x86-win" || p.filename() == "Resources")) {
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

/// 读取 PE 头的 IMAGE_FILE_MACHINE。无法解析（非 PE / 读失败）返回 0。
/// 0x014c = IMAGE_FILE_MACHINE_I386（32 位）
/// 0x8664 = IMAGE_FILE_MACHINE_AMD64（64 位）
/// 0xaa64 = IMAGE_FILE_MACHINE_ARM64（64 位）
static WORD peMachineType(const std::wstring& binaryPath) {
    std::ifstream f(binaryPath, std::ios::binary);
    if (!f) return 0;
    IMAGE_DOS_HEADER dos{};
    f.read(reinterpret_cast<char*>(&dos), sizeof(dos));
    if (!f || dos.e_magic != IMAGE_DOS_SIGNATURE) return 0;
    if (dos.e_lfanew <= 0) return 0;
    f.seekg(static_cast<std::streamoff>(dos.e_lfanew));
    DWORD signature = 0;
    f.read(reinterpret_cast<char*>(&signature), sizeof(signature));
    if (!f || signature != IMAGE_NT_SIGNATURE) return 0;
    WORD machine = 0;
    f.read(reinterpret_cast<char*>(&machine), sizeof(machine));
    if (!f) return 0;
    return machine;
}

/// 由 PE 头判定是否为 64 位二进制。解析失败时按 64 位处理
/// （本进程是 x64；历史行为即默认 true，缺失 PE 信息不应把插件误判为不兼容）。
static bool peIs64Bit(const std::wstring& binaryPath) {
    const WORD m = peMachineType(binaryPath);
    if (m == IMAGE_FILE_MACHINE_I386) return false;
    if (m == IMAGE_FILE_MACHINE_AMD64 || m == IMAGE_FILE_MACHINE_ARM64) return true;
    return true;
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

//------------------------------------------------------------------------------
// 元数据单一真相源
//
// 历史包袱：扫描路（PluginScanner::queryMetadata）与加载路
// （ClapPluginInstance::load / Vst3PluginInstance::load）各自实现了一遍字段提取，
// 且优先级不同，于是同一插件两条路给出互相矛盾的结论。实测：
//   FabFilter Pro-Q 3  扫描 vendor='FabFilter'  加载后 vendor=''
//   KV-Element-FX      扫描 name='Element FX' category='KV-Element-FX'
//                      加载后 name='Element FX' category='Fx'
// 用户看到的"厂商读不出来 / 名字对不上 / 分类是假的"全部源于此。
//
// 规则：
//   1. 一条填充实现，扫描路与加载路共用；
//   2. 静态描述符优先（CLAP descriptor / VST3 classInfo），实例化查询仅补空；
//   3. 已有非空值一律不覆盖（fillIfEmpty）；
//   4. category 只允许来自「分类级」来源，绝不用自由文本顶替。
//------------------------------------------------------------------------------
namespace {

// 规范正典：source/clap/include/clap/plugin-features.h（CLAP v1.2.10）。
// category 级 feature —— 决定插件"是什么"。
const char* const kClapCategoryFeatures[] = {
    "instrument", "audio-effect", "note-effect", "note-detector", "analyzer"};

// sub-category 级 feature —— 决定插件"更具体是什么"，命中后追加为 "|xxx"。
const char* const kClapSubCategoryFeatures[] = {
    "synthesizer", "sampler", "drum", "drum-machine", "filter", "phaser",
    "equalizer", "de-esser", "phase-vocoder", "granular", "frequency-shifter",
    "pitch-shifter", "distortion", "transient-shaper", "compressor", "expander",
    "gate", "limiter", "flanger", "chorus", "delay", "reverb", "tremolo", "glitch",
    "utility", "pitch-correction", "restoration", "multi-effects", "mixing",
    "mastering"};

bool isOneOf(const std::string& s, const char* const* list, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        if (s == list[i]) return true;
    }
    return false;
}

/// 从 CLAP descriptor->features 推出分类串。
/// 例：['audio-effect']                -> "audio-effect"
///     ['audio-effect','reverb']       -> "audio-effect|reverb"
///     ['reverb']（只有子分类）         -> "reverb"
/// 无任何分类级 feature 时返回空，由调用方兜底。
std::string clapCategoryFromFeatures(const char* const* features) {
    if (!features) return "";
    std::vector<std::string> feats;
    for (size_t i = 0; features[i] != nullptr; ++i) {
        if (features[i][0] != '\0') feats.emplace_back(features[i]);
    }
    std::string cat;
    std::string sub;
    for (const auto& f : feats) {
        if (cat.empty() && isOneOf(f, kClapCategoryFeatures,
                                   sizeof(kClapCategoryFeatures) / sizeof(char*))) {
            cat = f;
        } else if (sub.empty() && isOneOf(f, kClapSubCategoryFeatures,
                                          sizeof(kClapSubCategoryFeatures) / sizeof(char*))) {
            sub = f;
        }
    }
    if (cat.empty()) cat = sub;          // 没有分类级就退到子分类级
    else if (!sub.empty()) cat += "|" + sub;
    return cat;
}

/// 仅当目标为空时写入 —— "已有非空值不覆盖"的唯一执行点。
void fillIfEmpty(std::string& dst, const std::string& src) {
    if (dst.empty() && !src.empty()) dst = src;
}

/// 以扫描期元数据为基准初始化加载路 meta：只搬描述性字段，
/// 运行期字段（latency / isCompatible / errorMessage）一律重置。
/// 之后再调 applyClapDescriptor / applyVstAudioEffectClass 补空，
/// 于是「扫描值 == 加载值」对扫描期已有的字段恒成立。
void seedMetadataFromScan(PluginMetadata& dst, const PluginMetadata& src) {
    dst.path = src.path;
    dst.id = src.id;
    dst.name = src.name;
    dst.bundleName = src.bundleName;
    dst.vendor = src.vendor;
    dst.version = src.version;
    dst.category = src.category;
    dst.description = src.description;
    dst.format = src.format;
    dst.is64Bit = src.is64Bit;
    dst.latency = 0;
    dst.isCompatible = true;
    dst.errorMessage.clear();
}

/// 32 位插件的"可发现但不可加载"条目（D2）。
/// 不 LoadLibrary —— x64 进程加载 32 位 DLL 必然 ERROR_BAD_EXE_FORMAT(193)，
/// 旧路把 193 当普通"加载失败"抛出，用户无法区分架构问题与文件损坏；
/// 这里仅用 PE 版本资源与路径推导描述性字段，产出留在扫描结果里的
/// 不兼容条目。errorMessage 文案与 load() 的 32 位拒绝保持一致。
void fill32BitIncompatible(PluginMetadata& meta, const std::string& filePath,
                           PluginFormat format, const std::wstring& wpath) {
    meta.path = filePath;
    meta.format = format;
    meta.name = fs::path(filePath).stem().string();
    // 与 makeQuickMeta / applyClapDescriptor 同一规则：bundleName = 路径 stem。
    meta.bundleName = meta.name;
    meta.is64Bit = false;
    meta.isCompatible = false;
    meta.errorMessage = "32 位插件无法加载：AuraDSP 是 64 位进程，请安装 64 位版本";

    // vendor 兜底链与 makeQuickMeta / applyClapDescriptor 完全一致：
    // PE CompanyName -> LegalCopyright -> 上级目录 -> 知名签名 -> "Unknown"
    std::string vendor = extractCompanyFromVersionInfo(wpath);
    if (vendor.empty()) vendor = extractVendorFromLegalCopyright(wpath);
    if (vendor.empty()) vendor = extractVendorFromPath(filePath);
    if (vendor.empty()) vendor = extractVendorByKnownSignature(meta.name);
    if (vendor.empty()) vendor = "Unknown";
    meta.vendor = vendor;

    std::string peVer = extractProductVersionFromVersionInfo(wpath);
    meta.version = !peVer.empty() ? peVer : "1.0";
    // 与 makeQuickMeta 快扫缺省一致；深扫才有 subCategories，32 位拿不到。
    meta.category = "AudioEffect";
}

/// 用 CLAP descriptor 填充 meta。扫描路与加载路共用同一实现。
void applyClapDescriptor(PluginMetadata& meta,
                         const clap_plugin_descriptor_t* d,
                         const std::wstring& binaryPath,
                         const std::string& bundlePath) {
    if (!d) return;
    meta.format = PluginFormat::CLAP;

    fillIfEmpty(meta.id, (d->id && d->id[0]) ? d->id : "");
    fillIfEmpty(meta.name, (d->name && d->name[0]) ? d->name : "");
    fillIfEmpty(meta.description, (d->description && d->description[0]) ? d->description : "");
    // bundle 名单独存：KV-Element-FX.clap 的自报名是 "Element FX"，
    // 但用户选的是文件名 KV-Element-FX —— 两者都必须可取得，不可互相顶替。
    fillIfEmpty(meta.bundleName, fs::path(bundlePath).stem().string());

    // category 只能来自 features。
    // descriptor->description 是自由文本：实测 KV-Element-FX 的 description 就是
    // "KV-Element-FX"（bundle 名），拿它当 category 会得出假分类。
    std::string cat = clapCategoryFromFeatures(d->features);
    if (cat.empty()) cat = "AudioEffect";
    fillIfEmpty(meta.category, cat);

    fillIfEmpty(meta.version, (d->version && d->version[0]) ? d->version : "");

    // 厂商兜底链：descriptor -> PE 公司名 -> LegalCopyright -> 上级目录 -> 知名签名
    std::string vendor = (d->vendor && d->vendor[0]) ? d->vendor : "";
    if (vendor.empty()) {
        vendor = extractCompanyFromVersionInfo(binaryPath);
        if (vendor.empty()) vendor = extractVendorFromLegalCopyright(binaryPath);
        if (vendor.empty()) vendor = extractVendorFromPath(bundlePath);
        if (vendor.empty()) vendor = extractVendorByKnownSignature(meta.name);
    }
    fillIfEmpty(meta.vendor, vendor);

    // 版本兜底：descriptor -> PE 产品版本
    if (meta.version.empty() || meta.version == "1.0") {
        std::string peVer = extractProductVersionFromVersionInfo(binaryPath);
        if (!peVer.empty()) meta.version = peVer;
    }
    if (meta.version.empty()) meta.version = "1.0";
    if (meta.vendor.empty()) meta.vendor = "Unknown";
}

/// 用 VST3 工厂信息填充 meta。扫描路与加载路共用同一实现。
/// index 处的 class 若不是音频效果类则返回 false，且不修改 meta。
/// seeded=false（扫描路）：保持历史优先级 —— factory3 先写、factory2 后覆盖，
///   空值与占位（"Unknown"/"1.0"）允许被后续来源补写。
/// seeded=true（加载路）：扫描种子已给的描述性字段一律是最终值（仅补空），
///   从而「扫描值 == 加载值」逐字段成立；id 是身份键，两种模式都权威重写。
bool applyVstAudioEffectClass(PluginMetadata& meta,
                              Steinberg::IPluginFactory* factory,
                              Steinberg::IPluginFactory2* factory2,
                              Steinberg::IPluginFactory3* factory3,
                              Steinberg::int32 index,
                              const std::wstring& binaryPath,
                              const std::string& bundlePath,
                              bool seeded = false,
                              Steinberg::TUID* outTuid = nullptr) {
    Steinberg::PClassInfo classInfo;
    if (factory->getClassInfo(index, &classInfo) != Steinberg::kResultOk) return false;
    if (std::strcmp(classInfo.category, kVstAudioEffectClass) != 0) return false;

    meta.format = PluginFormat::VST3;
    // id 是实例化身份键：快扫拿不到 CID（为空），加载路必须权威解析，
    // 深扫种子里的 id 又与目标 class 相同，重写不会造成扫描/加载分歧。
    meta.id = cidToHexString(classInfo.cid);
    // 描述性字段：seeded 时"已有非空值不覆盖"，否则历史的后写覆盖。
    auto put = [seeded](std::string& dst, const std::string& src) {
        if (src.empty()) return;
        if (seeded) fillIfEmpty(dst, src);
        else dst = src;
    };
    // 占位放行条件：扫描路允许 "Unknown"/"1.0" 被更真来源替换；
    // 加载路不放行 —— 扫描期给出占位也是扫描期的答案。
    auto wantVendor = [seeded](const std::string& v) {
        return v.empty() || (!seeded && v == "Unknown");
    };
    auto wantVersion = [seeded](const std::string& v) {
        return v.empty() || (!seeded && v == "1.0");
    };

    put(meta.name, classInfo.name);
    put(meta.category, classInfo.category);
    fillIfEmpty(meta.bundleName, fs::path(bundlePath).stem().string());

    // 工厂级厂商
    std::string factoryVendor;
    Steinberg::PFactoryInfo factoryInfo;
    if (factory->getFactoryInfo(&factoryInfo) == Steinberg::kResultOk &&
        factoryInfo.vendor[0] != '\0') {
        factoryVendor = factoryInfo.vendor;
    }

    // IPluginFactory3：Unicode 类信息，先写（优先级最高的描述符来源）
    if (factory3) {
        Steinberg::PClassInfoW classInfoW;
        if (factory3->getClassInfoUnicode(index, &classInfoW) == Steinberg::kResultOk) {
            if (classInfoW.name[0] != 0) {
                std::string u = wideToUtf8(Steinberg::wscast(classInfoW.name));
                put(meta.name, u);
            }
            if (classInfoW.vendor[0] != 0) {
                std::string u = wideToUtf8(Steinberg::wscast(classInfoW.vendor));
                put(meta.vendor, u);
            }
            if (classInfoW.version[0] != 0) {
                std::string u = wideToUtf8(Steinberg::wscast(classInfoW.version));
                put(meta.version, u);
            }
            if (classInfoW.subCategories[0] != 0) {
                // subCategories 是 char8（ASCII），直接赋值；只有 name/vendor/version
                // 才是 char16，需要 wideToUtf8 转换。
                put(meta.category, classInfoW.subCategories);
            }
        }
    }

    // IPluginFactory2：ASCII 补充（保持历史扫描路的优先级：后写覆盖前写）
    if (factory2) {
        Steinberg::PClassInfo2 classInfo2;
        if (factory2->getClassInfo2(index, &classInfo2) == Steinberg::kResultOk) {
            if (wantVendor(meta.vendor)) {
                if (classInfo2.vendor[0]) meta.vendor = classInfo2.vendor;
            }
            if (wantVersion(meta.version)) {
                if (classInfo2.version[0]) meta.version = classInfo2.version;
            }
            put(meta.category, classInfo2.subCategories);
        }
    }

    // 多级兜底厂商：factory -> PE -> 上级目录 -> 知名签名
    if (wantVendor(meta.vendor)) {
        if (!factoryVendor.empty()) meta.vendor = factoryVendor;
        else {
            std::string peV = extractCompanyFromVersionInfo(binaryPath);
            if (!peV.empty()) meta.vendor = peV;
            else {
                std::string dirV = extractVendorFromPath(bundlePath);
                if (!dirV.empty()) meta.vendor = dirV;
                else {
                    std::string sigV = extractVendorByKnownSignature(meta.name);
                    if (!sigV.empty()) meta.vendor = sigV;
                }
            }
        }
    }
    // 多级兜底版本
    if (wantVersion(meta.version)) {
        std::string peVer = extractProductVersionFromVersionInfo(binaryPath);
        if (!peVer.empty()) meta.version = peVer;
    }

    // 与 applyClapDescriptor / fill32BitIncompatible 对称的末端兜底：
    // 工厂、PE 版本资源、目录、签名全链都拿不到厂商/版本时，必须落到
    // "Unknown"/"1.0" 占位而非空串 —— 空串会让快扫/深扫/加载三方产出
    // 与契约占位不一致的值（UI 侧另有一套 "未知" 展示，双轨易漂移）。
    if (meta.vendor.empty()) meta.vendor = "Unknown";
    if (meta.version.empty()) meta.version = "1.0";

    if (outTuid) std::memcpy(outTuid, classInfo.cid, sizeof(Steinberg::TUID));
    return true;
}

}  // namespace

std::string PluginMetadata::toJson() const {
    std::ostringstream ss;
    ss << "{"
       << "\"path\":\"" << escapeJsonString(path) << "\","
       << "\"id\":\"" << escapeJsonString(id) << "\","
       << "\"name\":\"" << escapeJsonString(name) << "\","
       << "\"bundleName\":\"" << escapeJsonString(bundleName) << "\","
       << "\"vendor\":\"" << escapeJsonString(vendor) << "\","
       << "\"version\":\"" << escapeJsonString(version) << "\","
       << "\"category\":\"" << escapeJsonString(category) << "\","
       << "\"description\":\"" << escapeJsonString(description) << "\","
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
    ~ClapPluginInstance() override {
        // 兜底卸载（load 失败等提前析构路径）；随后确保泵线程已停。
        // 线程已废弃（挂死隔离、detach）时 joinable 为 false，自然跳过。
        unload();
        stopClapThread();
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
        m_clapThreadReady.store(false, std::memory_order_release);
        m_stopClapThread.store(false, std::memory_order_release);
        m_clapThread = std::thread([this]() { clapMainLoop(); });
        for (int i = 0; i < 200 && !m_clapThreadReady.load(std::memory_order_acquire); ++i) {
            Sleep(10);
        }
        if (!m_clapThreadReady.load(std::memory_order_acquire)) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "CLAP main thread failed to start";
            FreeLibrary(m_module);
            m_module = nullptr;
            m_entry = nullptr;
            return false;
        }

        std::string initErr;
        bool taskRan = postTaskAndWait([&]() {
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
                // 线程挂死于 init —— 隔离（放弃释放）而非 detach 后继续用本
                // 对象：登记废弃，由 manager 把整个实例移入静态隔离区。
                m_threadAbandoned.store(true, std::memory_order_release);
                return false;
            }
            FreeLibrary(m_module);
            m_module = nullptr;
            return false;
        }

        m_isLoaded = true;
        m_meta.isCompatible = true;
        return true;
    }

    void unload() override {
        if (m_isLoaded) {
            std::cout << "[DBG CLAP unload] step 1: closeEditor" << std::endl;
            closeEditor();
            std::cout << "[DBG CLAP unload] step 2: deactivate" << std::endl;
            deactivate();
            // plugin->destroy + entry->deinit 移入 plugin main 线程（JUCE
            // message thread 所在线程；10-12 曾实证跨线程 destroy 死锁）。
            std::cout << "[DBG CLAP unload] step 3: destroy on clap main thread" << std::endl;
            bool destroyed = postTaskAndWait([&]() {
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
                std::cout << "[DBG CLAP unload] WARNING: main thread unresponsive; quarantining instance"
                          << std::endl;
                m_threadAbandoned.store(true, std::memory_order_release);
                return;   // manager 据此把实例移入静态隔离区（泄漏而非 UAF）
            }
            std::cout << "[DBG CLAP unload] step 3 done" << std::endl;
            m_isLoaded = false;
        }
        stopClapThread();
        if (m_module) {
            std::cout << "[DBG CLAP unload] step 5: FreeLibrary" << std::endl;
            FreeLibrary(m_module);
            std::cout << "[DBG CLAP unload] step 5 done" << std::endl;
            m_module = nullptr;
        }
        m_isLoaded = false;
        std::cout << "[DBG CLAP unload] complete" << std::endl;
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
        if (!m_clapThreadReady.load(std::memory_order_acquire)) return false;

        // B3-②：create/get_size/容器/set_parent/show 全部在 plugin main 线程
        // （= JUCE message thread = 泵线程）执行。子窗口因此归泵线程所有，
        // WM_PAINT/输入由泵分发——白框与拖动无响应的根因（子窗口落在无泵
        // 的 caller 线程，拓扑探针 tid 实证）就此消除。caller 只等待有界
        // 结果，不参与 JUCE 锁竞争。
        bool ok = false;
        bool done = postTaskAndWait([&]() { ok = showEditorOnMainThread(); }, 5000);
        if (!done) {
            std::cout << "[DBG CLAP showEditor] WARNING: editor task timed out; quarantining" << std::endl;
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

        std::cout << "[DBG CLAP showEditor] main thread: gui->create..." << std::endl;
        bool createRes = false;
        try {
            createRes = gui->create(m_plugin, CLAP_WINDOW_API_WIN32, false);
        } catch (const std::exception& ex) {
            std::cout << "[DBG CLAP showEditor] gui->create exception: " << ex.what() << std::endl;
        } catch (...) {
            std::cout << "[DBG CLAP showEditor] gui->create unknown exception!" << std::endl;
        }
        std::cout << "[DBG CLAP showEditor] gui->create returned: " << createRes << std::endl;
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
        if (!hwnd) return false;

        m_editorHwnd = hwnd;
        m_editorOpen.store(true, std::memory_order_release);
        std::cout << "[DBG CLAP showEditor] hwnd created: " << hwnd << std::endl;

        ShowWindow(hwnd, SW_SHOW);

        // [2] set_parent + show 在本线程（== 容器线程 == 泵线程）：
        //     插件子窗口由本线程创建，其 WM_PAINT/输入由本线程泵分发。
        clap_window_t win = {};
        win.api = CLAP_WINDOW_API_WIN32;
        win.win32 = hwnd;
        std::cout << "[DBG CLAP showEditor] main thread: calling gui->set_parent..." << std::endl;
        bool setParentRes = false;
        try {
            if (gui->set_parent) setParentRes = gui->set_parent(m_plugin, &win);
        } catch (const std::exception& ex) {
            std::cout << "[DBG CLAP showEditor] gui->set_parent exception: " << ex.what() << std::endl;
        } catch (...) {
            std::cout << "[DBG CLAP showEditor] gui->set_parent unknown exception!" << std::endl;
        }
        std::cout << "[DBG CLAP showEditor] gui->set_parent returned: " << setParentRes << std::endl;
        try {
            if (gui->show) gui->show(m_plugin);
        } catch (...) {}
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

        return setParentRes;
    }

    // closeEditor 的实体（在 CLAP plugin main 线程内执行）。
    void closeEditorOnMainThread() {
        auto gui = m_plugin ? reinterpret_cast<const clap_plugin_gui_t*>(
            m_plugin->get_extension(m_plugin, CLAP_EXT_GUI)) : nullptr;
        HWND hwnd = m_editorHwnd;
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
            try { if (gui->hide) gui->hide(m_plugin); } catch (...) {}
            try { if (gui->destroy) gui->destroy(m_plugin); } catch (...) {}
        }
        if (hwnd && IsWindow(hwnd)) DestroyWindow(hwnd);
        m_editorHwnd = nullptr;
        m_editorOpen.store(false, std::memory_order_release);
        std::cout << "[DBG CLAP closeEditor] closed on main thread" << std::endl;
    }

    void closeEditor() override {
        std::cout << "[DBG CLAP closeEditor] enter" << std::endl;
        if (!m_clapThreadReady.load(std::memory_order_acquire)) {
            m_editorOpen.store(false, std::memory_order_release);
            std::cout << "[DBG CLAP closeEditor] no clap main thread; skip" << std::endl;
            return;
        }
        bool done = postTaskAndWait([&]() { closeEditorOnMainThread(); }, 3000);
        if (!done) {
            std::cout << "[DBG CLAP closeEditor] WARNING: close task timed out; quarantining" << std::endl;
            m_threadAbandoned.store(true, std::memory_order_release);
        }
        std::cout << "[DBG CLAP closeEditor] exit" << std::endl;
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
        // CLAP state 属 main-thread 操作；JUCE 系插件可能触达 MessageManager，
        // 一律移入 plugin main 线程执行。
        bool ok = false;
        bool done = postTaskAndWait([&]() {
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
        // 同 savePreset：CLAP state 属 main-thread 操作，移入 plugin main 线程。
        bool ok = false;
        bool done = postTaskAndWait([&]() {
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
    // ---- CLAP plugin main 线程 ----
    // 长寿命线程：承载 entry->init（确立 JUCE MessageManager 的 message
    // thread 归属）、全部 main-thread 任务（GUI/状态/销毁）与本插件容器
    // 的消息泵。任务经 WM_APP_CLAP_TASK 唤醒、在 GetMessage 循环间隙执行。
    void clapMainLoop() {
        t_clapThreadType = ClapHostThreadType::Main;
        m_clapThreadId = GetCurrentThreadId();
        m_clapThreadReady.store(true, std::memory_order_release);
        MSG msg;
        for (;;) {
            BOOL r = GetMessageW(&msg, NULL, 0, 0);
            if (r <= 0) break;   // WM_QUIT（或错误）→ 退出
            if (msg.message == WM_APP_CLAP_TASK) {
                runQueuedTasks();
                continue;
            }
            if (msg.message == WM_CLOSE && msg.hwnd == m_editorHwnd) {
                // 用户点编辑器窗口的 X：收尾在泵线程内直接执行
                // （与 gui->create 同线程，无锁竞争）。
                closeEditorOnMainThread();
                continue;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        // 线程退出前兜底收尾（正常路径由 unload 的任务完成，此处防遗漏）。
        if (m_guiCreated.exchange(false, std::memory_order_acq_rel) && m_plugin) {
            auto gui = reinterpret_cast<const clap_plugin_gui_t*>(
                m_plugin->get_extension(m_plugin, CLAP_EXT_GUI));
            if (gui) {
                try { if (gui->hide) gui->hide(m_plugin); } catch (...) {}
                try { if (gui->destroy) gui->destroy(m_plugin); } catch (...) {}
            }
        }
        if (m_editorHwnd && IsWindow(m_editorHwnd)) DestroyWindow(m_editorHwnd);
        m_editorHwnd = nullptr;
        m_editorOpen.store(false, std::memory_order_release);
    }

    void runQueuedTasks() {
        for (;;) {
            std::function<void()> task;
            {
                std::lock_guard<std::mutex> lock(m_taskMutex);
                if (m_tasks.empty()) return;
                task = std::move(m_tasks.front());
                m_tasks.pop_front();
            }
            task();
        }
    }

    // 提交任务到 plugin main 线程并等待完成（有界超时）。
    // 返回 false = 线程未运行或超时（调用方走废弃隔离路径）。
    bool postTaskAndWait(std::function<void()> fn, DWORD timeoutMs) {
        if (m_stopClapThread.load(std::memory_order_acquire)) return false;
        auto task = std::make_shared<std::packaged_task<void()>>(std::move(fn));
        auto fut = task->get_future();
        {
            std::lock_guard<std::mutex> lock(m_taskMutex);
            m_tasks.emplace_back([task]() { (*task)(); });
        }
        if (!PostThreadMessageW(m_clapThreadId, WM_APP_CLAP_TASK, 0, 0)) {
            // Ready 已置位意味着 GetMessageW 已在跑、消息队列必已建立；
            // 此分支仅防御极端时序，短暂重试一次。
            Sleep(20);
            if (!PostThreadMessageW(m_clapThreadId, WM_APP_CLAP_TASK, 0, 0)) {
                std::cout << "[DBG CLAP] PostThreadMessage failed, err=" << GetLastError() << std::endl;
                return false;
            }
        }
        return fut.wait_for(std::chrono::milliseconds(timeoutMs)) == std::future_status::ready;
    }

    void stopClapThread() {
        if (!m_clapThread.joinable()) return;
        m_stopClapThread.store(true, std::memory_order_release);
        PostThreadMessageW(m_clapThreadId, WM_QUIT, 0, 0);
        HANDLE h = reinterpret_cast<HANDLE>(m_clapThread.native_handle());
        if (h && WaitForSingleObject(h, 3000) == WAIT_OBJECT_0) {
            m_clapThread.join();
        } else {
            // 线程挂死 → 隔离（放弃释放）：detach 后对象由 manager 移入
            // 静态隔离区，绝不在挂死线程仍引用期间析构。
            std::cout << "[DBG CLAP] main thread unresponsive on stop; abandoning" << std::endl;
            m_threadAbandoned.store(true, std::memory_order_release);
            m_clapThread.detach();
        }
    }

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

    // ---- CLAP plugin main 线程（B3-② 2026-10-12）----
    std::thread m_clapThread;
    DWORD m_clapThreadId = 0;
    std::atomic<bool> m_clapThreadReady{false};
    std::atomic<bool> m_stopClapThread{false};
    // 线程挂死（任务超时）时置位：manager 据此把整个实例移入静态隔离区，
    // 而不是析构它（挂死线程仍引用 this，析构 = use-after-free）。
    std::atomic<bool> m_threadAbandoned{false};
    std::mutex m_taskMutex;
    std::deque<std::function<void()>> m_tasks;

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
class Vst3PluginInstance : public IPluginInstance {
public:
    Vst3PluginInstance() = default;
    ~Vst3PluginInstance() override {
        // 兜底卸载（load 失败等提前析构路径）；随后确保泵线程已停。
        // 线程已废弃（挂死隔离、detach）时 joinable 为 false，自然跳过。
        unload();
        stopVst3Thread();
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
        // 线程（每实例专用泵线程）。VST3 规范期望宿主在 main/UI 线程完成这些
        // 调用；JUCE 系插件（如 Auto-Tune EFX+）的 MessageManager 在首次触达
        // 时绑定该线程——旧结构里 initialize 在 caller、attached 在临时编辑器
        // 线程，attached 因此死等（编辑器白框），unload 又撞上挂死线程
        // （0xC0000374）。与 CLAP 侧重构同构。
        m_vst3ThreadReady.store(false, std::memory_order_release);
        m_stopVst3Thread.store(false, std::memory_order_release);
        m_vst3Thread = std::thread([this]() { vst3MainLoop(); });
        for (int i = 0; i < 200 && !m_vst3ThreadReady.load(std::memory_order_acquire); ++i) {
            Sleep(10);
        }
        if (!m_vst3ThreadReady.load(std::memory_order_acquire)) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = "VST3 main thread failed to start";
            FreeLibrary(m_module);
            m_module = nullptr;
            return false;
        }

        std::string initErr;
        bool taskRan = postTaskAndWait([&]() {
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
            std::cout << "[DBG VST3] createInstance targetCid on IComponent..." << std::endl;
            Steinberg::tresult res = m_factory->createInstance(
                targetCid,
                Steinberg::Vst::IComponent::iid.toTUID(),
                reinterpret_cast<void**>(&m_component)
            );
            std::cout << "[DBG VST3] createInstance res=" << res << " component=" << m_component << std::endl;

            if (res != Steinberg::kResultOk || !m_component) {
                initErr = "Failed to create VST3 IComponent instance, res: " + std::to_string(res);
                return;
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
                initErr = "Failed to query VST3 IAudioProcessor interface";
                m_component->terminate();
                m_component->release();
                m_component = nullptr;
                return;
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
        }, 10000);
        if (!taskRan || !initErr.empty()) {
            m_meta.isCompatible = false;
            m_meta.errorMessage = taskRan ? initErr : "VST3 main thread task timeout during load";
            if (!taskRan) {
                // 线程挂死于 init —— 隔离（放弃释放）而非 detach 后继续用本
                // 对象：登记废弃，由 manager 把整个实例移入静态隔离区。
                // 此时绝不能 FreeLibrary（DLL 代码可能正被执行中）。
                m_threadAbandoned.store(true, std::memory_order_release);
                return false;
            }
            stopVst3Thread();
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
            std::cout << "[DBG VST3 unload] WARNING: main thread abandoned; skipping all teardown (quarantine)" << std::endl;
            m_isLoaded = false;
            return;
        }
        if (m_isLoaded) {
            closeEditor();
            deactivate();

            // 插件对象销毁在 plugin main 线程执行（与创建同线程）。
            std::cout << "[DBG VST3 unload] destroying plugin objects on main thread" << std::endl;
            bool destroyed = postTaskAndWait([&]() {
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
                std::cout << "[DBG VST3 unload] WARNING: main thread unresponsive; quarantining instance" << std::endl;
                m_threadAbandoned.store(true, std::memory_order_release);
                return;   // manager 据此把实例移入静态隔离区（泄漏而非 UAF）
            }
            m_isLoaded = false;
        }
        stopVst3Thread();
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
            std::cout << "[DBG VST3 showEditor] m_controller is NULL!" << std::endl;
            return false;
        }
        // B3（2026-10-12）：GUI 交互全部在 VST3 plugin main 线程（每实例
        // 专用泵线程）执行——与组件 initialize 同线程，JUCE 系插件的
        // MessageManager 线程假设得以满足；旧结构里 attached 跑在临时编辑器
        // 线程（≠ initialize 线程），Auto-Tune EFX+ 等插件因此挂死（白框）。
        bool ok = false;
        bool done = postTaskAndWait([&]() { ok = showEditorOnPumpThread(); }, 8000);
        if (!done) {
            std::cout << "[DBG VST3 showEditor] WARNING: show task timed out; abandoning instance" << std::endl;
            m_threadAbandoned.store(true, std::memory_order_release);
            return false;
        }
        return ok;
    }

    // showEditor 的实体（在 VST3 plugin main 线程内执行）。
    bool showEditorOnPumpThread() {
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

        // frame 必须存活到编辑器关闭（插件会回调），故为成员而非局部变量。
        m_view = view;
        m_plugFrame.m_hwnd = hwnd;
        view->setFrame(&m_plugFrame);

        try {
            Steinberg::tresult attachRes = view->attached(reinterpret_cast<void*>(hwnd), Steinberg::kPlatformTypeHWND);
            if (attachRes != Steinberg::kResultOk && attachRes != Steinberg::kResultTrue) {
                std::cout << "[DBG VST3 showEditor] view->attached returned non-ok: " << attachRes << std::endl;
                detachViewOnPumpThread(view);
                if (IsWindow(hwnd)) DestroyWindow(hwnd);
                m_editorHwnd = nullptr;
                m_editorOpen.store(false, std::memory_order_release);
                return false;
            }
        } catch (const std::exception& ex) {
            std::cout << "[DBG VST3 showEditor] view->attached exception: " << ex.what() << std::endl;
            detachViewOnPumpThread(view);
            if (IsWindow(hwnd)) DestroyWindow(hwnd);
            m_editorHwnd = nullptr;
            m_editorOpen.store(false, std::memory_order_release);
            return false;
        } catch (...) {
            std::cout << "[DBG VST3 showEditor] view->attached unknown exception!" << std::endl;
            detachViewOnPumpThread(view);
            if (IsWindow(hwnd)) DestroyWindow(hwnd);
            m_editorHwnd = nullptr;
            m_editorOpen.store(false, std::memory_order_release);
            return false;
        }

        ShowWindow(hwnd, SW_SHOW);
        UpdateWindow(hwnd);
        return true;
    }

    // IPlugView 收尾（泵线程内调用）：解绑 frame 并释放引用。
    void detachViewOnPumpThread(Steinberg::IPlugView* view) {
        try { view->setFrame(nullptr); } catch (...) {}
        try { view->removed(); } catch (...) {}
        try { view->release(); } catch (...) {}
        m_view = nullptr;
    }

    void closeEditor() override {
        std::cout << "[DBG VST3 closeEditor] enter" << std::endl;
        if (!m_vst3ThreadReady.load(std::memory_order_acquire)) {
            m_editorOpen.store(false, std::memory_order_release);
            std::cout << "[DBG VST3 closeEditor] no plugin main thread; skip" << std::endl;
            return;
        }
        bool done = postTaskAndWait([&]() { closeEditorOnPumpThread(); }, 3000);
        if (!done) {
            std::cout << "[DBG VST3 closeEditor] WARNING: close task timed out; abandoning instance" << std::endl;
            m_threadAbandoned.store(true, std::memory_order_release);
        }
    }

    // closeEditor 的实体（在 VST3 plugin main 线程内执行）；
    // 泵循环截获编辑器窗口 WM_CLOSE（用户点 X）时也走这里。
    void closeEditorOnPumpThread() {
        HWND hwnd = m_editorHwnd;
        if (m_view) {
            detachViewOnPumpThread(m_view);
        }
        if (hwnd && IsWindow(hwnd)) DestroyWindow(hwnd);
        m_editorHwnd = nullptr;
        m_editorOpen.store(false, std::memory_order_release);
        std::cout << "[DBG VST3 closeEditor] closed on main thread" << std::endl;
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
        // getState 属插件 main 线程交互（B3：与 initialize/createView 同线程）。
        std::vector<uint8_t> data;
        bool got = postTaskAndWait([&]() {
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

        std::ifstream ifs(filePath, std::ios::binary);
        if (!ifs) return false;
        ifs.seekg(0, std::ios::end);
        size_t sz = static_cast<size_t>(ifs.tellg());
        ifs.seekg(0, std::ios::beg);
        std::vector<uint8_t> buf(sz);
        ifs.read(reinterpret_cast<char*>(buf.data()), static_cast<std::streamsize>(sz));

        // setState/setComponentState 属插件 main 线程交互（B3）。
        bool ok = false;
        bool ran = postTaskAndWait([&]() {
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
    int32_t m_inChannels = 2;
    int32_t m_outChannels = 2;
    int32_t m_numInputBusses = 1;
    int32_t m_numOutputBusses = 1;

    HWND m_editorHwnd = nullptr;
    // E1：调用方（Dart）传来的窗口标题；为空时退化为 m_meta.name。
    // 同步语义同 CLAP 实例：写于任务提交前，读于泵线程内。
    std::string m_editorTitle;
    std::atomic<bool> m_editorOpen{false};
    // 泵线程挂死后置位；unload 与 manager 隔离逻辑据此放弃销毁。
    std::atomic<bool> m_threadAbandoned{false};

    // IPlugView 当前打开的编辑器视图（泵线程独占访问）。
    Steinberg::IPlugView* m_view = nullptr;
    // frame 必须存活到编辑器关闭（插件会回调 setFrame 指针）。
    AuraPlugFrame m_plugFrame;

    // ---- VST3 plugin main 线程（B3 2026-10-12，镜像 CLAP）----
    // 长寿命线程：承载插件对象创建/初始化（确立 JUCE MessageManager 归属）、
    // 全部 main-thread 任务（GUI/状态/销毁）与编辑器容器的消息泵。任务经
    // WM_APP_VST3_TASK 唤醒、在 GetMessage 循环间隙执行。
    std::thread m_vst3Thread;
    DWORD m_vst3ThreadId = 0;
    std::atomic<bool> m_vst3ThreadReady{false};
    std::atomic<bool> m_stopVst3Thread{false};
    std::mutex m_taskMutex;
    std::deque<std::function<void()>> m_tasks;

    void vst3MainLoop() {
        m_vst3ThreadId = GetCurrentThreadId();
        m_vst3ThreadReady.store(true, std::memory_order_release);
        MSG msg;
        for (;;) {
            BOOL r = GetMessageW(&msg, NULL, 0, 0);
            if (r <= 0) break;   // WM_QUIT（或错误）→ 退出
            if (msg.message == WM_APP_VST3_TASK) {
                runQueuedTasks();
                continue;
            }
            if (msg.message == WM_CLOSE && msg.hwnd == m_editorHwnd) {
                // 用户点编辑器窗口的 X：收尾在泵线程内直接执行
                //（与 createView/attached 同线程，无锁竞争）。
                closeEditorOnPumpThread();
                continue;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        // 线程退出前兜底收尾（正常路径由 unload 的任务完成，此处防遗漏）。
        closeEditorOnPumpThread();
    }

    void runQueuedTasks() {
        for (;;) {
            std::function<void()> task;
            {
                std::lock_guard<std::mutex> lock(m_taskMutex);
                if (m_tasks.empty()) return;
                task = std::move(m_tasks.front());
                m_tasks.pop_front();
            }
            task();
        }
    }

    // 提交任务到 plugin main 线程并等待完成（有界超时）。
    // 返回 false = 线程未运行或超时（调用方走废弃隔离路径）。
    bool postTaskAndWait(std::function<void()> fn, DWORD timeoutMs) {
        if (m_stopVst3Thread.load(std::memory_order_acquire)) return false;
        auto task = std::make_shared<std::packaged_task<void()>>(std::move(fn));
        auto fut = task->get_future();
        {
            std::lock_guard<std::mutex> lock(m_taskMutex);
            m_tasks.emplace_back([task]() { (*task)(); });
        }
        if (!PostThreadMessageW(m_vst3ThreadId, WM_APP_VST3_TASK, 0, 0)) {
            // Ready 已置位意味着 GetMessageW 已在跑、消息队列必已建立；
            // 此分支仅防御极端时序，短暂重试一次。
            Sleep(20);
            if (!PostThreadMessageW(m_vst3ThreadId, WM_APP_VST3_TASK, 0, 0)) {
                std::cout << "[DBG VST3] PostThreadMessage failed, err=" << GetLastError() << std::endl;
                return false;
            }
        }
        return fut.wait_for(std::chrono::milliseconds(timeoutMs)) == std::future_status::ready;
    }

    void stopVst3Thread() {
        if (!m_vst3Thread.joinable()) return;
        m_stopVst3Thread.store(true, std::memory_order_release);
        PostThreadMessageW(m_vst3ThreadId, WM_QUIT, 0, 0);
        HANDLE h = reinterpret_cast<HANDLE>(m_vst3Thread.native_handle());
        if (h && WaitForSingleObject(h, 3000) == WAIT_OBJECT_0) {
            m_vst3Thread.join();
        } else {
            // 线程挂死 → 隔离（放弃释放）：detach 后对象由 manager 移入
            // 静态隔离区，绝不在挂死线程仍引用期间析构。
            std::cout << "[DBG VST3] main thread unresponsive on stop; abandoning" << std::endl;
            m_threadAbandoned.store(true, std::memory_order_release);
            m_vst3Thread.detach();
        }
    }
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

std::string PluginScanner::resolveBundleBinary(const std::string& bundlePath, PluginFormat format,
                                               std::string* outArch) {
    std::error_code ec;
    if (outArch) outArch->clear();
    if (fs::is_directory(bundlePath, ec)) {
        // 探测顺序即偏好顺序：本进程架构（x86_64-win）优先，32 位（x86-win）
        // 作为"能发现但不能加载"的条目进入列表（isCompatible=false）。
        static const char* const kArchDirs[] = {"x86_64-win", "x86-win"};
        const char* const ext = (format == PluginFormat::VST3) ? ".vst3" : ".clap";
        for (const char* arch : kArchDirs) {
            fs::path subBinary = fs::path(bundlePath) / "Contents" / arch;
            if (!fs::exists(subBinary, ec)) continue;
            for (const auto& entry : fs::directory_iterator(subBinary, ec)) {
                // 大小写不敏感：内层二进制叫 Upper.VST3 时严格比较会漏掉整包，
                // 与 scan() 入口的 ::tolower 归一化保持一致。
                if (extensionEqualsCI(entry.path(), ext)) {
                    if (outArch) *outArch = arch;
                    return entry.path().string();
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

    // D2：32 位插件不进入 LoadLibrary —— x64 进程加载 32 位 DLL 必然
    // ERROR_BAD_EXE_FORMAT(193)，旧实现把它当"打开失败"，扫描结果里直接
    // 消失。这里提前识别，产出"可发现但不可加载"条目（isCompatible=false）。
    if (!peIs64Bit(wpath)) {
        PluginMetadata meta;
        fill32BitIncompatible(meta, filePath, format, wpath);
        outPlugins.push_back(meta);
        return true;
    }

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
                        meta.is64Bit = true;
                        meta.isCompatible = true;
                        applyClapDescriptor(meta, d, wpath, filePath);
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
                    Steinberg::IPluginFactory2* factory2 = nullptr;
                    Steinberg::IPluginFactory3* factory3 = nullptr;
                    factory->queryInterface(Steinberg::IPluginFactory2::iid, reinterpret_cast<void**>(&factory2));
                    factory->queryInterface(Steinberg::IPluginFactory3::iid, reinterpret_cast<void**>(&factory3));

                    Steinberg::int32 classCount = factory->countClasses();
                    for (Steinberg::int32 i = 0; i < classCount; ++i) {
                        PluginMetadata meta;
                        meta.path = filePath;
                        meta.is64Bit = true;
                        meta.isCompatible = true;
                        if (applyVstAudioEffectClass(meta, factory, factory2, factory3, i, wpath, filePath)) {
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
                    // 与深扫/加载路同一规则：bundleName = 注册路径的 stem。
                    // 快扫不加载 DLL，拿不到自报名，但 bundle 名不依赖 DLL。
                    q.bundleName = fs::path(pStr).stem().string();
                    q.format = fmt;
                    // D2：is64Bit 由 PE 头判定（不再硬编码 true）。32 位条目
                    // 保留在扫描结果中但标记不可加载，加载路 loadPlugin() 会
                    // 拦截并给出同一文案，不会走到 LoadLibrary。
                    q.is64Bit = peIs64Bit(wp);
                    if (!q.is64Bit) {
                        q.isCompatible = false;
                        q.errorMessage = "32 位插件无法加载：AuraDSP 是 64 位进程，请安装 64 位版本";
                    }
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

// 隔离区（放弃释放）：abandoned 实例统一收容于此。
// 关键约束——容器本身必须永不析构。挂死线程仍引用实例内部（this、编辑器
// 窗口、COM 对象），任何时刻的释放都危险；静态存储的容器会在进程 exit()
// 时触发析构并逐个销毁实例，同样撞上挂死线程（实测表现为退出阶段堆损坏
// 或挂死）。故堆分配 + 从不 delete = 进程生命周期内绝对安全的隔离区，
// 泄漏量级 = 挂死次数（罕见路径）。
static void quarantineAbandonedInstance(std::unique_ptr<IPluginInstance> inst) {
    static auto* s_leak = new std::vector<std::unique_ptr<IPluginInstance>>();
    static std::mutex s_leakMutex;
    std::lock_guard<std::mutex> lock(s_leakMutex);
    s_leak->push_back(std::move(inst));
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
            std::cout << "[DBG Slot] unloadLocked[" << slot << "] quiesced (spins=" << spins << "), calling closeEditor" << std::endl;
            s.instance->closeEditor();
            std::cout << "[DBG Slot] unloadLocked[" << slot << "] deactivate" << std::endl;
            s.instance->deactivate();
            std::cout << "[DBG Slot] unloadLocked[" << slot << "] unload" << std::endl;
            s.instance->unload();
            if (s.instance->abandoned()) {
                // 隔离（放弃释放）：内部线程挂死且仍引用实例，析构 =
                // use-after-free。整体移入隔离区（可控泄漏换不可控崩溃）。
                quarantineAbandonedInstance(std::move(s.instance));
                std::cout << "[DBG Slot] unloadLocked[" << slot << "] quarantined (abandoned)" << std::endl;
            } else {
                std::cout << "[DBG Slot] unloadLocked[" << slot << "] reset (dtor)" << std::endl;
                s.instance.reset();
            }
            std::cout << "[DBG Slot] unloadLocked[" << slot << "] complete" << std::endl;
        } else {
            std::cout << "[DBG Slot] unloadLocked[" << slot << "] no instance" << std::endl;
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

        // 扫描期命中项作为种子传入：加载路以扫描值为基准，descriptor 只补空不覆盖，
        // 于是「扫描值 == 加载值」对扫描期已有的字段恒成立（B1 的结构性保证）。
        // 无种子（例如从会话恢复直接加载、或该路径从未扫描）时退化为纯描述符路径，
        // 而两条路共用同一填充函数，优先级一致，结论仍相同。
        const PluginMetadata* seed = nullptr;
        for (const auto& p : m_scannedPlugins) {
            if (p.path != path) continue;
            if (!pluginId.empty() && !p.id.empty() && p.id != pluginId) continue;
            seed = &p;
            break;
        }

        bool lRet = instance->load(path, pluginId, seed);
        std::cout << "[DBG PluginHost] instance->load returned: " << lRet << std::endl;
        if (!lRet) {
            if (instance->abandoned()) {
                // load 阶段线程挂死 → 隔离区（同 unloadPluginSlotLocked）。
                quarantineAbandonedInstance(std::move(instance));
                std::cout << "[DBG PluginHost] instance quarantined (abandoned during load)" << std::endl;
            }
            return false;
        }

        bool aRet = instance->activate(sampleRate, maxBlockSize);
        std::cout << "[DBG PluginHost] instance->activate returned: " << aRet << std::endl;
        if (!aRet) {
            instance->unload();
            if (instance->abandoned()) {
                quarantineAbandonedInstance(std::move(instance));
                std::cout << "[DBG PluginHost] instance quarantined (abandoned during activate-unload)" << std::endl;
            }
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

bool PluginHostManager::showEditorSlot(size_t slot, const std::string& title) {
    if (slot >= kMaxPluginSlots) return false;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (m_slots[slot].instance && m_slots[slot].hasActive.load()) {
        return m_slots[slot].instance->showEditor(title);
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
