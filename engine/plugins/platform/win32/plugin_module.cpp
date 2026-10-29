// 平台端口 module 的 Windows 实现（M2 插件平台归类，2026-10-29）。
// 插件二进制加载/符号解析/卸载的唯一 Win32 落点；UTF-8 路径经 utf8ToWide。
#include "platform/port/module.h"

#include <windows.h>

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

} // namespace platform
} // namespace auradsp
