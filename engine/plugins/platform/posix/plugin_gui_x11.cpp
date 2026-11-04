// plugin_gui_x11.cpp —— POSIX 编辑器窗口层（编辑器阶段 E1，2026-11-04）。
//
// 定位：platform/win32/plugin_gui_win32.cpp 的 POSIX 对应物 + Win32
// 窗口 API 的 X11 真实现（win32_compat.h 声明）。设计要点：
//   - **运行时 dlopen libX11.so.6**：不引入构建期 X11 依赖（CI 的
//     引擎 job 无 libx11-dev、x86 宿主无 32 位 X11 开发库）；无 X
//     运行时/无 DISPLAY 时全部 API 恒失败——与旧惰性桩同形状，
//     编辑器干净降级，其余通路不受影响。X11 类型/事件结构在本
//     文件内按稳定 ABI 自带定义（指针宽度自适应 64/32 位）。
//   - **连接按线程**：每个泵线程惰性开自己的 Display（窗口只在
//     创建它的连接上收事件——与 Win32 的线程亲和消息队列同构，
//     保证实例回调永远落在该模块的 plugin main 线程）。跨线程的
//     查询/显隐（showEditor 的 caller 线程路径）借调用线程自己的
//     连接执行——X11 允许任意连接操作任意窗口。
//   - **分发语义逐项对齐 Win32 的 EditorHostWindowProc**：
//     WM_DELETE_WINDOW ≈ WM_CLOSE（杀两枚定时器 → 实例
//     onEditorWmClose）；ConfigureNotify 尺寸变化 ≈ WM_SIZE
//     （→ onEditorResize）；kSizeSettleTimerId ≈ 尺寸稳定化轮询
//     （pollEditorSize + 计数，6 次自杀）；kEditorIdleTimerId ≈
//     VST2 idle 心跳（→ onEditorIdle）。其余定时器 id（CLAP 插件
//     定时器）只做登记簿记——Win32 版同样未把它们分发到
//     timer_support.on_timer（既有缺口，两平台一致，不在本阶段
//     的对等范围内单方改变）。
//   - 实例指针经 GWLP_USERDATA 等价物（本层登记表）取回，与
//     Win32 版 GetWindowLongPtrW(GWLP_USERDATA) 同语义。
//   - 全局安装非致命 X 错误处理器：协议错误（销毁竞态的
//     BadWindow 等）默认会让 libX11 终止整个进程，宿主必须吞掉
//     （审查 F1，2026-11-04）。IO 错误（X 服务器断开）不接管，
//     会话本身已在消亡。
#include "win32_compat.h"
#include "win32_util.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <map>
#include <set>
#include <mutex>
#include <vector>

#include "plugin_host.h"  // IPluginInstance（分发目标）

namespace {

// ---------------------------------------------------------------- X11 ABI
using XWindow = unsigned long;
using XAtom = unsigned long;
struct XDisplay;

struct XAnyEventS {
    int type;
    unsigned long serial;
    int send_event;
    XDisplay* display;
    XWindow window;
};
struct XClientMessageS {
    int type;
    unsigned long serial;
    int send_event;
    XDisplay* display;
    XWindow window;
    XAtom message_type;
    int format;
    union {
        char b[20];
        short s[10];
        long l[5];
    } data;
};
struct XConfigureS {
    int type;
    unsigned long serial;
    int send_event;
    XDisplay* display;
    XWindow event;
    XWindow window;
    int x, y, width, height, border_width;
    XWindow above;
    int override_redirect;
};
struct XErrorEventS {
    int type;
    XDisplay* display;
    unsigned long resourceid;
    unsigned long serial;
    unsigned char error_code;
    unsigned char request_code;
    unsigned char minor_code;
};
struct XWindowEventS {  // DestroyNotify / ReparentNotify 的公共前缀段
    int type;
    unsigned long serial;
    int send_event;
    XDisplay* display;
    XWindow event;
    XWindow window;
};
struct XReparentS {
    int type;
    unsigned long serial;
    int send_event;
    XDisplay* display;
    XWindow event;
    XWindow window;
    XWindow parent;
    int x, y;
    int override_redirect;
};
union XEventU {
    int type;
    XAnyEventS any;
    XClientMessageS client;
    XConfigureS configure;
    XWindowEventS windowEvent;
    XReparentS reparent;
    long pad[32];
};

constexpr int kEvFocusIn = 9;
constexpr int kEvFocusOut = 10;
constexpr int kEvDestroyNotify = 17;
constexpr int kEvMapNotify = 19;
constexpr int kEvReparentNotify = 21;
constexpr int kEvConfigureNotify = 22;
constexpr int kEvClientMessage = 33;
constexpr long kStructureNotifyMask = 1L << 17;
constexpr long kSubstructureNotifyMask = 1L << 19;
constexpr long kFocusChangeMask = 1L << 21;

struct X11Api {
    void* lib = nullptr;
    int (*XInitThreadsFn)() = nullptr;
    XDisplay* (*XOpenDisplayFn)(const char*) = nullptr;
    int (*XCloseDisplayFn)(XDisplay*) = nullptr;
    int (*XDefaultScreenFn)(XDisplay*) = nullptr;
    XWindow (*XRootWindowFn)(XDisplay*, int) = nullptr;
    XWindow (*XCreateSimpleWindowFn)(XDisplay*, XWindow, int, int, unsigned,
                                     unsigned, unsigned, unsigned long,
                                     unsigned long) = nullptr;
    int (*XDestroyWindowFn)(XDisplay*, XWindow) = nullptr;
    int (*XMapWindowFn)(XDisplay*, XWindow) = nullptr;
    int (*XUnmapWindowFn)(XDisplay*, XWindow) = nullptr;
    int (*XStoreNameFn)(XDisplay*, XWindow, const char*) = nullptr;
    int (*XSelectInputFn)(XDisplay*, XWindow, long) = nullptr;
    int (*XSetWMProtocolsFn)(XDisplay*, XWindow, XAtom*, int) = nullptr;
    XAtom (*XInternAtomFn)(XDisplay*, const char*, int) = nullptr;
    int (*XMoveResizeWindowFn)(XDisplay*, XWindow, int, int, unsigned,
                               unsigned) = nullptr;
    int (*XMoveWindowFn)(XDisplay*, XWindow, int, int) = nullptr;
    int (*XResizeWindowFn)(XDisplay*, XWindow, unsigned, unsigned) = nullptr;
    int (*XRaiseWindowFn)(XDisplay*, XWindow) = nullptr;
    int (*XGetGeometryFn)(XDisplay*, XWindow, XWindow*, int*, int*, unsigned*,
                          unsigned*, unsigned*, unsigned*) = nullptr;
    int (*XQueryTreeFn)(XDisplay*, XWindow, XWindow*, XWindow*, XWindow**,
                        unsigned*) = nullptr;
    int (*XFreeFn)(void*) = nullptr;
    int (*XFlushFn)(XDisplay*) = nullptr;
    int (*XPendingFn)(XDisplay*) = nullptr;
    int (*XNextEventFn)(XDisplay*, XEventU*) = nullptr;
    int (*XSendEventFn)(XDisplay*, XWindow, int, long, XEventU*) = nullptr;
    int (*XSetErrorHandlerFn)(int (*)(XDisplay*, XErrorEventS*)) = nullptr;
    bool ready = false;
};

// X 协议错误（如与插件/窗口管理器的窗口销毁竞态出的 BadWindow）
// 绝不能走 libX11 默认处理器——它会直接终止整个进程（应用或宿主）。
// 宿主的正道是吞掉并继续：出错的那次调用本就多为查询/显隐，窗口
// 状态由后续事件与登记表收敛。审查 F1（2026-11-04）。
int onXError(XDisplay*, XErrorEventS*) { return 0; }

X11Api& api() {
    static X11Api a;
    static std::once_flag once;
    std::call_once(once, [&]() {
        a.lib = dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL);
        if (!a.lib) return;
        auto sym = [&](const char* name) {
            return dlsym(a.lib, name);
        };
#define BIND(member, name) \
    a.member = reinterpret_cast<decltype(a.member)>(sym(name))
        BIND(XInitThreadsFn, "XInitThreads");
        BIND(XOpenDisplayFn, "XOpenDisplay");
        BIND(XCloseDisplayFn, "XCloseDisplay");
        BIND(XDefaultScreenFn, "XDefaultScreen");
        BIND(XRootWindowFn, "XRootWindow");
        BIND(XCreateSimpleWindowFn, "XCreateSimpleWindow");
        BIND(XDestroyWindowFn, "XDestroyWindow");
        BIND(XMapWindowFn, "XMapWindow");
        BIND(XUnmapWindowFn, "XUnmapWindow");
        BIND(XStoreNameFn, "XStoreName");
        BIND(XSelectInputFn, "XSelectInput");
        BIND(XSetWMProtocolsFn, "XSetWMProtocols");
        BIND(XInternAtomFn, "XInternAtom");
        BIND(XMoveResizeWindowFn, "XMoveResizeWindow");
        BIND(XMoveWindowFn, "XMoveWindow");
        BIND(XResizeWindowFn, "XResizeWindow");
        BIND(XRaiseWindowFn, "XRaiseWindow");
        BIND(XGetGeometryFn, "XGetGeometry");
        BIND(XQueryTreeFn, "XQueryTree");
        BIND(XFreeFn, "XFree");
        BIND(XFlushFn, "XFlush");
        BIND(XPendingFn, "XPending");
        BIND(XNextEventFn, "XNextEvent");
        BIND(XSendEventFn, "XSendEvent");
        BIND(XSetErrorHandlerFn, "XSetErrorHandler");
#undef BIND
        a.ready = a.XOpenDisplayFn && a.XCreateSimpleWindowFn &&
                  a.XNextEventFn && a.XInternAtomFn;
        if (a.ready && a.XInitThreadsFn) a.XInitThreadsFn();
        if (a.ready && a.XSetErrorHandlerFn) a.XSetErrorHandlerFn(&onXError);
    });
    return a;
}

// 本线程的 X 连接（惰性）。create=false 时不新建（分发路径用）。
thread_local XDisplay* t_display = nullptr;
XDisplay* tlsDisplay(bool create) {
    if (t_display) return t_display;
    if (!create || !api().ready) return nullptr;
    t_display = api().XOpenDisplayFn(nullptr);
    return t_display;
}

// ---------------------------------------------------------------- 登记表
struct WinRec {
    XDisplay* owner = nullptr;
    void* userData = nullptr;
    long style = 0;
    int lastW = 0;
    int lastH = 0;
};
struct TimerRec {
    XWindow win = 0;
    UINT_PTR id = 0;
    UINT periodMs = 0;
    std::chrono::steady_clock::time_point next{};
};

std::recursive_mutex g_mutex;
std::map<XWindow, WinRec> g_windows;
std::vector<TimerRec> g_timers;
std::atomic<bool> g_anyWindows{false};
XAtom g_wmProtocols = 0;
XAtom g_wmDelete = 0;

// XEmbed 宿主侧最小面（E3）：容器↔插件子窗口的嵌入协商。
// 子窗口经 Reparent/Map 被发现后，宿主送 EMBEDDED_NOTIFY +
// WINDOW_ACTIVATE；容器焦点进出转发 FOCUS_IN/OUT。完整键盘
// 协商（FOCUS_FIRST/LAST 等）留待真机以真实插件验证后补。
XAtom g_xembed = 0;
std::map<XWindow, XWindow> g_embedChildOf;  // container -> child
std::set<XWindow> g_embedNotified;
constexpr long kXembedEmbeddedNotify = 0;
constexpr long kXembedWindowActivate = 1;
constexpr long kXembedFocusIn = 4;
constexpr long kXembedFocusOut = 5;

void sendXembed(XDisplay* dpy, XWindow child, XWindow container, long msg) {
    if (!api().ready || !api().XSendEventFn) return;
    if (!g_xembed) g_xembed = api().XInternAtomFn(dpy, "_XEMBED", 0);
    if (!g_xembed) return;
    XEventU ev{};
    ev.client.type = kEvClientMessage;
    ev.client.display = dpy;
    ev.client.window = child;
    ev.client.message_type = g_xembed;
    ev.client.format = 32;
    ev.client.data.l[0] = 0;  // CurrentTime
    ev.client.data.l[1] = msg;
    ev.client.data.l[2] = 0;
    ev.client.data.l[3] = static_cast<long>(container);
    ev.client.data.l[4] = 0;  // XEmbed protocol version
    api().XSendEventFn(dpy, child, 0, 0, &ev);
    api().XFlushFn(dpy);
}

XWindow toWin(HWND h) {
    return static_cast<XWindow>(reinterpret_cast<uintptr_t>(h));
}
HWND toHwnd(XWindow w) {
    return reinterpret_cast<HWND>(static_cast<uintptr_t>(w));
}

void killTimersLocked(XWindow win, UINT_PTR id, bool allForWindow) {
    g_timers.erase(
        std::remove_if(g_timers.begin(), g_timers.end(),
                       [&](const TimerRec& t) {
                           return t.win == win && (allForWindow || t.id == id);
                       }),
        g_timers.end());
}

// WM_CLOSE 等价分发（泵线程；调用方已持锁）：杀两枚系统定时器后
// 把关闭交给实例（其 closeEditorOnMainThread 会 DestroyWindow）。
void dispatchCloseLocked(XWindow win) {
    auto it = g_windows.find(win);
    if (it == g_windows.end()) return;
    void* ud = it->second.userData;
    killTimersLocked(win, auradsp::kSizeSettleTimerId, false);
    killTimersLocked(win, auradsp::kEditorIdleTimerId, false);
    if (ud) {
        reinterpret_cast<auradsp::IPluginInstance*>(ud)->onEditorWmClose();
    }
}

}  // namespace

// ---------------------------------------------------------------- 兼容 API
BOOL IsWindow(HWND hwnd) {
    if (!hwnd) return FALSE;
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    return g_windows.count(toWin(hwnd)) ? TRUE : FALSE;
}

HWND CreateWindowExW(DWORD, LPCWSTR, LPCWSTR title, DWORD style, int x, int y,
                     int w, int h, HWND, HMENU, HINSTANCE, LPVOID) {
    XDisplay* dpy = tlsDisplay(true);
    if (!dpy) return nullptr;
    X11Api& a = api();
    XWindow root = a.XRootWindowFn(dpy, a.XDefaultScreenFn(dpy));
    if (x == CW_USEDEFAULT) x = 40;
    if (y == CW_USEDEFAULT) y = 40;
    if (w <= 0) w = 640;
    if (h <= 0) h = 480;
    XAtom protoCopy = 0;
    XWindow win = a.XCreateSimpleWindowFn(dpy, root, x, y,
                                          static_cast<unsigned>(w),
                                          static_cast<unsigned>(h), 0, 0, 0);
    if (!win) return nullptr;
    if (title) {
        std::string u8 = auradsp::wideToUtf8(std::wstring(title));
        a.XStoreNameFn(dpy, win, u8.c_str());
    }
    {
        std::lock_guard<std::recursive_mutex> lock(g_mutex);
        if (!g_wmDelete) {
            g_wmProtocols = a.XInternAtomFn(dpy, "WM_PROTOCOLS", 0);
            g_wmDelete = a.XInternAtomFn(dpy, "WM_DELETE_WINDOW", 0);
        }
        WinRec rec;
        rec.owner = dpy;
        rec.style = static_cast<long>(style);
        rec.lastW = w;
        rec.lastH = h;
        g_windows[win] = rec;
        g_anyWindows.store(true, std::memory_order_release);
        protoCopy = g_wmDelete;
    }
    if (protoCopy) a.XSetWMProtocolsFn(dpy, win, &protoCopy, 1);
    a.XSelectInputFn(dpy, win, kStructureNotifyMask |
                                   kSubstructureNotifyMask |
                                   kFocusChangeMask);
    a.XFlushFn(dpy);
    return toHwnd(win);
}

BOOL DestroyWindow(HWND hwnd) {
    if (!hwnd) return FALSE;
    XWindow win = toWin(hwnd);
    {
        std::lock_guard<std::recursive_mutex> lock(g_mutex);
        auto it = g_windows.find(win);
        if (it == g_windows.end()) return FALSE;
        g_windows.erase(it);
        g_embedChildOf.erase(win);
        g_embedNotified.erase(win);
        // 本窗作为他人嵌入子窗口的登记一并清（审查 F3；与
        // DestroyNotify 分发路径同口径，防 XID 复用后误抑制
        // 一次 EMBEDDED_NOTIFY）。
        for (auto eit = g_embedChildOf.begin(); eit != g_embedChildOf.end();) {
            if (eit->second == win) {
                g_embedNotified.erase(eit->second);
                eit = g_embedChildOf.erase(eit);
            } else {
                ++eit;
            }
        }
        killTimersLocked(win, 0, true);
        if (g_windows.empty())
            g_anyWindows.store(false, std::memory_order_release);
    }
    // 只用调用线程自己的连接销毁（窗口是服务端对象，任意连接可
    // 操作）；绝不借用属主线程的 Display 做跨线程调用——那依赖
    // XInitThreads 必须先于进程内任何 XOpenDisplay 生效，而插件
    // 可能抢先开自己的连接（审查 F2）。无连接时为本线程新开。
    XDisplay* dpy = tlsDisplay(true);
    if (dpy && api().ready) {
        api().XDestroyWindowFn(dpy, win);
        api().XFlushFn(dpy);
    }
    return TRUE;
}

BOOL ShowWindow(HWND hwnd, int cmd) {
    if (!hwnd || !api().ready) return FALSE;
    XDisplay* dpy = tlsDisplay(true);
    if (!dpy) return FALSE;
    XWindow win = toWin(hwnd);
    if (cmd == SW_SHOW) {
        api().XMapWindowFn(dpy, win);
    } else if (cmd == SW_HIDE) {
        api().XUnmapWindowFn(dpy, win);
    }
    api().XFlushFn(dpy);
    return TRUE;
}

BOOL SetWindowPos(HWND hwnd, HWND after, int x, int y, int w, int h,
                  UINT flags) {
    if (!hwnd || !api().ready) return FALSE;
    XDisplay* dpy = tlsDisplay(true);
    if (!dpy) return FALSE;
    XWindow win = toWin(hwnd);
    const bool move = !(flags & SWP_NOMOVE);
    const bool size = !(flags & SWP_NOSIZE);
    if (move && size) {
        api().XMoveResizeWindowFn(dpy, win, x, y, static_cast<unsigned>(w),
                                  static_cast<unsigned>(h));
    } else if (move) {
        api().XMoveWindowFn(dpy, win, x, y);
    } else if (size) {
        api().XResizeWindowFn(dpy, win, static_cast<unsigned>(w),
                              static_cast<unsigned>(h));
    }
    if (!(flags & SWP_NOZORDER) &&
        (after == HWND_TOP || after == HWND_TOPMOST)) {
        api().XRaiseWindowFn(dpy, win);
    }
    api().XFlushFn(dpy);
    return TRUE;
}

BOOL MoveWindow(HWND hwnd, int x, int y, int w, int h, BOOL) {
    return SetWindowPos(hwnd, nullptr, x, y, w, h, SWP_NOZORDER);
}

BOOL GetClientRect(HWND hwnd, RECT* rc) {
    if (!hwnd || !rc || !api().ready) return FALSE;
    XDisplay* dpy = tlsDisplay(true);
    if (!dpy) return FALSE;
    XWindow root = 0;
    int gx = 0, gy = 0;
    unsigned gw = 0, gh = 0, gbw = 0, depth = 0;
    if (!api().XGetGeometryFn(dpy, toWin(hwnd), &root, &gx, &gy, &gw, &gh,
                              &gbw, &depth)) {
        return FALSE;
    }
    rc->left = 0;
    rc->top = 0;
    rc->right = static_cast<LONG>(gw);
    rc->bottom = static_cast<LONG>(gh);
    return TRUE;
}

INT_PTR SetWindowLongPtrW(HWND hwnd, int index, INT_PTR value) {
    if (!hwnd) return 0;
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    auto it = g_windows.find(toWin(hwnd));
    if (it == g_windows.end()) return 0;
    if (index == GWLP_USERDATA) {
        INT_PTR old = reinterpret_cast<INT_PTR>(it->second.userData);
        it->second.userData = reinterpret_cast<void*>(value);
        return old;
    }
    return 0;
}
INT_PTR GetWindowLongPtrW(HWND hwnd, int index) {
    if (!hwnd) return 0;
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    auto it = g_windows.find(toWin(hwnd));
    if (it == g_windows.end()) return 0;
    if (index == GWLP_USERDATA)
        return reinterpret_cast<INT_PTR>(it->second.userData);
    return 0;
}
LONG_PTR SetWindowLongPtr(HWND hwnd, int index, LONG_PTR value) {
    return SetWindowLongPtrW(hwnd, index, value);
}
LONG_PTR GetWindowLongPtr(HWND hwnd, int index) {
    return GetWindowLongPtrW(hwnd, index);
}
LONG GetWindowLongW(HWND hwnd, int index) {
    if (!hwnd) return 0;
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    auto it = g_windows.find(toWin(hwnd));
    if (it == g_windows.end()) return 0;
    if (index == GWL_STYLE) return static_cast<LONG>(it->second.style);
    return 0;
}
LONG GetWindowLong(HWND hwnd, int index) { return GetWindowLongW(hwnd, index); }

UINT_PTR SetTimer(HWND hwnd, UINT_PTR id, UINT periodMs, void*) {
    if (!hwnd || id == 0 || periodMs == 0) return 0;
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    XWindow win = toWin(hwnd);
    killTimersLocked(win, id, false);
    TimerRec t;
    t.win = win;
    t.id = id;
    t.periodMs = periodMs;
    t.next = std::chrono::steady_clock::now() +
             std::chrono::milliseconds(periodMs);
    g_timers.push_back(t);
    return id;
}

BOOL KillTimer(HWND hwnd, UINT_PTR id) {
    if (!hwnd) return FALSE;
    std::lock_guard<std::recursive_mutex> lock(g_mutex);
    size_t before = g_timers.size();
    killTimersLocked(toWin(hwnd), id, false);
    return g_timers.size() != before ? TRUE : FALSE;
}

BOOL UpdateWindow(HWND hwnd) {
    if (!hwnd || !api().ready) return FALSE;
    XDisplay* dpy = tlsDisplay(false);
    if (!dpy) return FALSE;
    api().XFlushFn(dpy);
    return TRUE;
}

BOOL AdjustWindowRect(RECT*, DWORD, BOOL) {
    return TRUE;  // X11 容器无非客户区调整（WM 边框不在我方账上）
}

HWND GetWindow(HWND hwnd, UINT cmd) {
    if (!hwnd || !api().ready) return nullptr;
    XDisplay* dpy = tlsDisplay(true);
    if (!dpy) return nullptr;
    XWindow win = toWin(hwnd);
    XWindow root = 0, parent = 0, *children = nullptr;
    unsigned n = 0;
    HWND result = nullptr;
    if (cmd == GW_CHILD) {
        if (api().XQueryTreeFn(dpy, win, &root, &parent, &children, &n) &&
            n > 0) {
            result = toHwnd(children[0]);
        }
    } else if (cmd == GW_HWNDNEXT) {
        if (api().XQueryTreeFn(dpy, win, &root, &parent, &children, &n) &&
            parent) {
            XWindow *siblings = nullptr;
            unsigned sn = 0;
            XWindow r2 = 0, p2 = 0;
            if (api().XQueryTreeFn(dpy, parent, &r2, &p2, &siblings, &sn)) {
                for (unsigned i = 0; i + 1 < sn; ++i) {
                    if (siblings[i] == win) {
                        result = toHwnd(siblings[i + 1]);
                        break;
                    }
                }
            }
            if (siblings) api().XFreeFn(siblings);
        }
    }
    if (children) api().XFreeFn(children);
    return result;
}

BOOL SetForegroundWindow(HWND hwnd) {
    if (!hwnd || !api().ready) return FALSE;
    XDisplay* dpy = tlsDisplay(true);
    if (!dpy) return FALSE;
    api().XRaiseWindowFn(dpy, toWin(hwnd));
    api().XFlushFn(dpy);
    return TRUE;
}

// ---------------------------------------------------------------- 分发
namespace auradsp {

bool guiX11HasWindows() {
    return g_anyWindows.load(std::memory_order_acquire);
}

void guiX11Dispatch() {
    if (!guiX11HasWindows()) return;
    XDisplay* dpy = tlsDisplay(false);
    if (!dpy || !api().ready) return;
    X11Api& a = api();
    std::lock_guard<std::recursive_mutex> lock(g_mutex);

    // 1) 到期定时器（只处理本连接名下的窗口——线程亲和）。
    {
        const auto now = std::chrono::steady_clock::now();
        std::vector<TimerRec> due;
        for (auto& t : g_timers) {
            auto wit = g_windows.find(t.win);
            if (wit == g_windows.end() || wit->second.owner != dpy) continue;
            if (t.next <= now) {
                t.next = now + std::chrono::milliseconds(t.periodMs);
                due.push_back(t);
            }
        }
        for (const auto& t : due) {
            auto wit = g_windows.find(t.win);
            if (wit == g_windows.end()) continue;
            bool alive = false;
            for (const auto& cur : g_timers)
                if (cur.win == t.win && cur.id == t.id) alive = true;
            if (!alive) continue;
            auto* inst = reinterpret_cast<IPluginInstance*>(
                wit->second.userData);
            if (!inst) continue;
            if (t.id == kSizeSettleTimerId) {
                inst->pollEditorSize();
                inst->incSettleTicks();
                if (inst->getSettleTicks() >= 6) {
                    killTimersLocked(t.win, t.id, false);
                }
            } else if (t.id == kEditorIdleTimerId) {
                inst->onEditorIdle();
            }
            // 其余 id（CLAP 插件定时器）：Win32 版同样不分发，仅簿记。
        }
    }

    // 2) X 事件（本连接队列）。单轮设上限，防病态插件以事件洪流
    //    饿死本泵的任务处理；余量留给下一 10ms 节拍（审查 F4）。
    int budget = 256;
    while (budget-- > 0 && a.XPendingFn(dpy) > 0) {
        XEventU ev{};
        a.XNextEventFn(dpy, &ev);
        if (ev.type == kEvClientMessage) {
            if (ev.client.message_type == g_wmProtocols &&
                static_cast<XAtom>(ev.client.data.l[0]) == g_wmDelete) {
                dispatchCloseLocked(ev.client.window);
            }
        } else if (ev.type == kEvConfigureNotify) {
            XWindow win = ev.configure.window;
            auto it = g_windows.find(win);
            if (it != g_windows.end() &&
                (ev.configure.width != it->second.lastW ||
                 ev.configure.height != it->second.lastH)) {
                it->second.lastW = ev.configure.width;
                it->second.lastH = ev.configure.height;
                if (it->second.userData) {
                    reinterpret_cast<IPluginInstance*>(it->second.userData)
                        ->onEditorResize();
                }
            }
        } else if (ev.type == kEvReparentNotify) {
            // 插件子窗口挂入我方容器：记为该容器的嵌入子窗口。
            XWindow container = ev.reparent.event;
            XWindow child = ev.reparent.window;
            if (g_windows.count(container) && child != container &&
                ev.reparent.parent == container) {
                g_embedChildOf[container] = child;
            }
        } else if (ev.type == kEvMapNotify) {
            // 子窗口映射：补 XEmbed 嵌入通知（每子窗口一次）。
            XWindow child = ev.windowEvent.window;
            for (const auto& [container, c] : g_embedChildOf) {
                if (c == child && !g_embedNotified.count(child)) {
                    g_embedNotified.insert(child);
                    sendXembed(dpy, child, container, kXembedEmbeddedNotify);
                    sendXembed(dpy, child, container, kXembedWindowActivate);
                }
            }
        } else if (ev.type == kEvFocusIn || ev.type == kEvFocusOut) {
            XWindow container = ev.any.window;
            auto cit = g_embedChildOf.find(container);
            if (cit != g_embedChildOf.end()) {
                sendXembed(dpy, cit->second, container,
                           ev.type == kEvFocusIn ? kXembedFocusIn
                                                 : kXembedFocusOut);
            }
        } else if (ev.type == kEvDestroyNotify) {
            XWindow win = ev.windowEvent.window;
            auto it = g_windows.find(win);
            if (it != g_windows.end()) {
                g_windows.erase(it);
                g_embedChildOf.erase(win);
                g_embedNotified.erase(win);
                for (auto eit = g_embedChildOf.begin();
                     eit != g_embedChildOf.end();) {
                    if (eit->second == win) {
                        g_embedNotified.erase(eit->second);
                        eit = g_embedChildOf.erase(eit);
                    } else {
                        ++eit;
                    }
                }
                killTimersLocked(win, 0, true);
                if (g_windows.empty())
                    g_anyWindows.store(false, std::memory_order_release);
            }
        }
    }
}

}  // namespace auradsp
