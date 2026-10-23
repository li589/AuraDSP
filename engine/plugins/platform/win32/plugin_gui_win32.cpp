#include "plugin_host.h"
#include "win32_util.h"

#include <windows.h>

#include <mutex>
#include <set>
#include <string>

namespace auradsp {
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

void ResizeDirectChildren(HWND hwnd) {
    RECT rc;
    if (!GetClientRect(hwnd, &rc)) return;
    const int cw = rc.right - rc.left;
    const int ch = rc.bottom - rc.top;
    HWND child = GetWindow(hwnd, GW_CHILD);
    while (child) {
        MoveWindow(child, 0, 0, cw, ch, TRUE);
        child = GetWindow(child, GW_HWNDNEXT);
    }
}

// Z16：见 win32_util.h 声明处注释。先试 SetForegroundWindow（同进程或
// 已持前台权限时更稳），再用 TOPMOST→NOTOPMOST 组合保证跨进程抬升；
// NOTOPMOST 之后窗口仍居于全部非 topmost 窗口之上（含 Flutter App），
// 但不再是常驻置顶——用户点 App 即正常回流焦点。
void FlashEditorToFront(HWND hwnd) {
    if (!hwnd || !IsWindow(hwnd)) return;
    SetForegroundWindow(hwnd);
    SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE);
}

// C4：尺寸稳定化定时器 ID 与轮询次数。
static constexpr int kSizeSettleMaxTicks = 6;            // 6 * 100ms = 600ms

// 编辑器容器窗口的过程函数（CLAP/VST3 共用模式）：
// 生命周期由 plugin main 线程的泵循环管理，WM_CLOSE 经 GWLP_USERDATA 里
// 的实例指针分发到 onEditorWmClose()（在泵线程内直接收尾，与 gui->create /
// createView+attached 同线程，无锁竞争）。刻意不在 WM_DESTROY 里
// PostQuitMessage——该线程是长寿命的共享 plugin main 线程，绝不能被一次
// 编辑器关闭杀掉（旧 AuraDSP_Plugin_Host_Window 即因此不能承载泵线程）。
static LRESULT CALLBACK EditorHostWindowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_SIZE) {
        // C4：容器尺寸一变，就把新尺寸派发给插件，让它的子窗口同步铺满
        // 客户区。旧实现完全不处理 WM_SIZE——子窗口固定在其创建时的尺寸，
        // 容器放大只多出空白，内容仍被裁剪（iZotope RX 系列典型症状）。
        LRESULT r = DefWindowProcW(hwnd, msg, wp, lp);
        auto* instance = reinterpret_cast<IPluginInstance*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (instance) instance->onEditorResize();
        return r;
    }
    if (msg == WM_TIMER && wp == kSizeSettleTimerId) {
        // C4：尺寸稳定化轮询——见 IPluginInstance::pollEditorSize 注释。
        auto* instance = reinterpret_cast<IPluginInstance*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (instance) {
            instance->pollEditorSize();
            instance->incSettleTicks();
            if (instance->getSettleTicks() >= kSizeSettleMaxTicks) {
                KillTimer(hwnd, kSizeSettleTimerId);
            }
        } else {
            KillTimer(hwnd, kSizeSettleTimerId);
        }
        return 0;
    }
    if (msg == WM_CLOSE) {
        KillTimer(hwnd, kSizeSettleTimerId);
        auto* instance = reinterpret_cast<IPluginInstance*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (instance) {
            instance->onEditorWmClose();
            return 0;
        }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void EnsureEditorWindowClassRegistered(const wchar_t* className) {
    // 按类名各自登记一次。曾误用函数内共享 once_flag——CLAP/VST3 两个类名
    // 只有第一个能注册，另一个的 CreateWindowExW 必失败（2026-10-12 实测：
    // VST3 先跑时 CLAP 编辑器全挂、close 任务挂死）。RegisterClassExW 对同名
    // 重复注册仅报 ERROR_CLASS_ALREADY_EXISTS，故登记集合用 mutex 保护即可。
    static std::mutex registerMutex;
    static std::set<std::wstring> registered;
    std::lock_guard<std::mutex> lock(registerMutex);
    if (registered.count(className)) return;
    WNDCLASSEXW wc = {sizeof(WNDCLASSEXW)};
    wc.lpfnWndProc = EditorHostWindowProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = className;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassExW(&wc);   // 已存在也视为完成（proc 相同），避免每次重试
    registered.insert(className);
}

void EnsureClapWindowClassRegistered() {
    EnsureEditorWindowClassRegistered(L"AuraDSP_CLAP_Host_Window");
}

void EnsureVst3WindowClassRegistered() {
    EnsureEditorWindowClassRegistered(L"AuraDSP_VST3_Host_Window");
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
} // namespace auradsp
