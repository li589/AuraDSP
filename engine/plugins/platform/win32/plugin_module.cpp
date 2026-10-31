// 平台端口 module 的 Windows 实现（M2 插件平台归类，2026-10-29）。
// 插件二进制加载/符号解析/卸载的唯一 Win32 落点；UTF-8 路径经 utf8ToWide。
#include "platform/port/module.h"

#include <windows.h>

#include <cstdio>

#include "win32_util.h"

namespace auradsp {
namespace platform {

void* module_open_utf8(const char* utf8_path) {
    if (!utf8_path) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return nullptr;
    }
    const std::wstring wide = utf8ToWide(utf8_path);
    return reinterpret_cast<void*>(
        LoadLibraryExW(wide.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH));
}

void* module_symbol(void* module, const char* symbol_name) {
    if (!module || !symbol_name) return nullptr;
    return reinterpret_cast<void*>(
        GetProcAddress(reinterpret_cast<HMODULE>(module), symbol_name));
}

void module_close(void* module) {
    if (module) FreeLibrary(reinterpret_cast<HMODULE>(module));
}

unsigned long module_last_error() {
    return static_cast<unsigned long>(GetLastError());
}

const char* module_last_error_text() {
    thread_local char buf[320];
    buf[0] = '\0';
    const DWORD code = GetLastError();
    if (code == 0) return buf;

    const DWORD n = FormatMessageA(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, 0, buf, (DWORD)sizeof(buf), nullptr);
    if (n == 0) {
        snprintf(buf, sizeof(buf), "Win32 error %lu",
                 static_cast<unsigned long>(code));
        return buf;
    }
    // 系统文案自带尾部换行/回车；诊断串保持单行。
    DWORD len = n;
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r' ||
                       buf[len - 1] == ' ' || buf[len - 1] == '.')) {
        buf[--len] = '\0';
    }
    return buf;
}

} // namespace platform
} // namespace auradsp
