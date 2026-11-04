#pragma once

// VST2 净室头（vendor/plugin-api/vst2/vst.h）无条件把
// VST_FUNCTION_INTERFACE 定义为 __cdecl——MSVC 习语，POSIX 编译器
// 无此关键字。x86-64 与 i386 的 Linux C 调用约定本就是 cdecl 语义，
// 空定义即等价。须在任何包含 vst.h 的 TU 之前生效（VST2 的两个
// 实现文件都先包含 win32_util.h，本头经其引入）。
#ifndef __cdecl
#define __cdecl
#endif
// win32_compat.h —— POSIX 平台的 Win32 最小兼容层（二期阶段一）。
//
// 定位与边界（与实施方案 §2 对齐）：
//   - formats 层的编辑器 GUI 代码按 Win32 窗口 API 书写。Linux 上
//     编辑器本体（X11 嵌入）是后续独立阶段；在此之前，本头提供
//     编辑器代码用到的类型/常量与**惰性**窗口 API（恒失败/无操作），
//     使非编辑器通路（扫描/加载/process）完整可用，编辑器入口则由
//     各 instance 的 showEditor 在非 Windows 显式返回不可用收口
//     （阶段三），不依赖本头的假句柄。
//   - 例外：GetSystemTimeAsFileTime 是 process 上下文（VST3 过程
//     数据的时间戳）在用的**非编辑器** API，这里给真实实现
//     （FILETIME 纪元换算），不是惰性桩。
//   - 本头只经 platform/posix 的 win32_util.h 间接引入，且仅在
//     Linux 构建的 include 路径中出现；Windows 构建永不包含。
#include <cstdint>
#include <cstring>
#include <chrono>

typedef void* HWND;
typedef void* HMODULE;
typedef void* HINSTANCE;
typedef void* HANDLE;
typedef void* HMENU;
typedef void* HICON;
typedef void* HCURSOR;
typedef void* HBRUSH;
typedef uint32_t DWORD;
typedef uint32_t UINT;
typedef uintptr_t UINT_PTR;
typedef intptr_t INT_PTR;
typedef intptr_t LONG_PTR;
typedef uintptr_t WPARAM;
typedef intptr_t LPARAM;
typedef intptr_t LRESULT;
typedef int BOOL;
typedef uint8_t BYTE;
typedef uint16_t WORD;
typedef int32_t LONG;
typedef uint32_t ULONG;
typedef void* LPVOID;
typedef const wchar_t* LPCWSTR;
typedef wchar_t* LPWSTR;
typedef const char* LPCSTR;
typedef long HRESULT;

typedef struct tagRECT { LONG left, top, right, bottom; } RECT;
typedef struct tagPOINT { LONG x, y; } POINT;
typedef struct tagFILETIME { DWORD dwLowDateTime, dwHighDateTime; } FILETIME;
typedef struct tagMSG { HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam; } MSG;

#define TRUE 1
#define FALSE 0
#define SW_HIDE 0
#define SW_SHOW 5
#define GWLP_USERDATA (-21)
#define GWL_STYLE (-16)
#define GW_CHILD 5
#define GW_HWNDNEXT 2
#define WM_CLOSE 0x0010
#define WM_PAINT 0x000F
#define WM_SIZE 0x0005
#define WM_QUIT 0x0012
#define WM_APP 0x8000
#define WS_OVERLAPPED 0x00000000L
#define WS_CAPTION 0x00C00000L
#define WS_SYSMENU 0x00080000L
#define WS_MINIMIZEBOX 0x00020000L
#define WS_OVERLAPPEDWINDOW 0x00CF0000L
#define HWND_TOP ((HWND)0)
#define HWND_TOPMOST ((HWND)-1)
#define HWND_NOTOPMOST ((HWND)-2)
#define CW_USEDEFAULT ((int)0x80000000)
#define SWP_NOSIZE 0x0001
#define SWP_NOMOVE 0x0002
#define SWP_NOZORDER 0x0004
#define SWP_NOACTIVATE 0x0010
#define SWP_FRAMECHANGED 0x0020

static inline BOOL IsWindow(HWND) { return FALSE; }
static inline HWND CreateWindowExW(DWORD, LPCWSTR, LPCWSTR, DWORD, int, int,
                                   int, int, HWND, HMENU, HINSTANCE, LPVOID) {
    return nullptr;
}
static inline BOOL DestroyWindow(HWND) { return FALSE; }
static inline BOOL ShowWindow(HWND, int) { return FALSE; }
static inline BOOL SetWindowPos(HWND, HWND, int, int, int, int, UINT) {
    return FALSE;
}
static inline INT_PTR SetWindowLongPtrW(HWND, int, INT_PTR) { return 0; }
static inline INT_PTR GetWindowLongPtrW(HWND, int) { return 0; }
static inline LONG_PTR SetWindowLongPtr(HWND, int, LONG_PTR) { return 0; }
static inline LONG_PTR GetWindowLongPtr(HWND, int) { return 0; }
static inline LONG GetWindowLongW(HWND, int) { return 0; }
static inline LONG GetWindowLong(HWND, int) { return 0; }
static inline UINT_PTR SetTimer(HWND, UINT_PTR, UINT, void*) { return 0; }
static inline BOOL KillTimer(HWND, UINT_PTR) { return FALSE; }
static inline BOOL GetClientRect(HWND, RECT* rc) {
    if (rc) std::memset(rc, 0, sizeof(*rc));
    return FALSE;
}
static inline BOOL UpdateWindow(HWND) { return FALSE; }
static inline void Sleep(DWORD) {}
static inline HMODULE GetModuleHandleW(LPCWSTR) { return nullptr; }
static inline DWORD GetCurrentThreadId() { return 0; }
static inline DWORD GetLastError() { return 0; }
static inline HWND SetParent(HWND, HWND) { return nullptr; }
static inline BOOL MoveWindow(HWND, int, int, int, int, BOOL) { return FALSE; }
static inline BOOL InvalidateRect(HWND, const RECT*, BOOL) { return FALSE; }
static inline LRESULT SendMessageW(HWND, UINT, WPARAM, LPARAM) { return 0; }
static inline BOOL PostMessageW(HWND, UINT, WPARAM, LPARAM) { return FALSE; }
static inline BOOL AdjustWindowRect(RECT*, DWORD, BOOL) { return FALSE; }
static inline HWND GetWindow(HWND, UINT) { return nullptr; }
static inline BOOL SetForegroundWindow(HWND) { return FALSE; }

// 真实实现（非编辑器路径）：系统时间 → FILETIME（1601 纪元，
// 100ns 单位），供 VST3 process 的 systemTime 字段使用。
static inline void GetSystemTimeAsFileTime(FILETIME* ft) {
    if (!ft) return;
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    const uint64_t ticks =
        static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(now)
                .count()) *
            10ULL +
        116444736000000000ULL; // 1601 → 1970 纪元差（100ns 单位）
    ft->dwLowDateTime = static_cast<DWORD>(ticks & 0xFFFFFFFFULL);
    ft->dwHighDateTime = static_cast<DWORD>(ticks >> 32);
}
