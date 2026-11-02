/* 平台端口 Linux 实现：动态模块加载（M2 插件平台归类，2026-10-29 契约；
 * S2 Linux 落地，2026-11-01）。
 * 与 plugins/platform/win32/plugin_module.cpp 对称的唯一 dlopen 落点：
 * dlopen(RTLD_NOW | RTLD_LOCAL) / dlsym / dlclose。
 * 与 Windows 的已知语义差（诊断时注意）：LoadLibraryExW 用
 * LOAD_WITH_ALTERED_SEARCH_PATH 从插件所在目录解析依赖；dlopen 给定
 * 绝对路径时，其依赖走 DT_NEEDED + rpath/系统路径，不含模块所在目录。
 * 错误快照契约（port/module.h CP-11）：dlerror() 读取即清除，必须在
 * 失败点就地快照到线程局部缓冲；module_last_error 返回失败点的
 * errno（dlopen 失败时 errno 不可靠，可能为 0——数值仅作参考，
 * 诊断以 module_last_error_text 的文本为准）。 */
#include "platform/port/module.h"

#ifdef _WIN32
#error "module_linux.cpp 仅用于非 Windows 构建"
#endif

#include <dlfcn.h>

#include <cerrno>
#include <cstdio>
#include <cstring>

namespace auradsp {
namespace platform {

namespace {

thread_local char g_err_text[320] = {};
thread_local unsigned long g_err_code = 0;

void snapshot_error() {
    const char* e = dlerror();
    if (e) {
        // 与 Windows 版一致：去掉尾部换行/句点，诊断串保持单行。
        snprintf(g_err_text, sizeof(g_err_text), "%s", e);
        size_t len = strlen(g_err_text);
        while (len > 0 && (g_err_text[len - 1] == '\n' || g_err_text[len - 1] == '\r' ||
                           g_err_text[len - 1] == ' ' || g_err_text[len - 1] == '.')) {
            g_err_text[--len] = '\0';
        }
    } else {
        g_err_text[0] = '\0';
    }
    g_err_code = static_cast<unsigned long>(errno);
}

void clear_error() {
    dlerror(); // 读取即清除：丢弃上一次的残留错误状态
    g_err_text[0] = '\0';
    g_err_code = 0;
}

} // namespace

void* module_open_utf8(const char* utf8_path) {
    if (!utf8_path) {
        g_err_text[0] = '\0';
        g_err_code = static_cast<unsigned long>(EINVAL);
        return nullptr;
    }
    clear_error();
    errno = 0;
    void* h = dlopen(utf8_path, RTLD_NOW | RTLD_LOCAL);
    if (!h) snapshot_error();
    return h;
}

void* module_symbol(void* module, const char* symbol_name) {
    if (!module || !symbol_name) return nullptr;
    clear_error();
    errno = 0;
    void* sym = dlsym(module, symbol_name);
    if (!sym) snapshot_error(); // 无错误文本 = 符号值本身为 NULL，合法
    return sym;
}

void module_close(void* module) {
    if (module) dlclose(module);
}

unsigned long module_last_error() {
    return g_err_code;
}

const char* module_last_error_text() {
    return g_err_text;
}

} // namespace platform
} // namespace auradsp
