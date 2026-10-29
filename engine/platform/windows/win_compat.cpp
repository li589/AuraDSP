/* 平台实现 Windows：Win7 CreateFile2 回退（M1 由 auradsp_engine.cpp 原样迁入）。
 *
 * Windows 7 兼容补丁：提供 CreateFile2 回退，避免 MSVC STL <filesystem> 静态依赖
 * Win8+ 的 CreateFile2 导致 Win7 LoadLibrary 127。符号必须是 DLL 内全局定义
 * （__imp_CreateFile2），不可改 static 文件作用域。 */
#include <windows.h>

extern "C" {
    typedef struct _CREATEFILE2_EXTENDED_PARAMETERS_SHIM {
        DWORD dwSize;
        DWORD dwFileAttributes;
        DWORD dwFileFlags;
        DWORD dwSecurityQosFlags;
        LPSECURITY_ATTRIBUTES lpSecurityAttributes;
        HANDLE hTemplateFile;
    } CREATEFILE2_EXTENDED_PARAMETERS_SHIM;

    static HANDLE WINAPI AuraFallback_CreateFile2(
        LPCWSTR lpFileName,
        DWORD dwDesiredAccess,
        DWORD dwShareMode,
        DWORD dwCreationDisposition,
        CREATEFILE2_EXTENDED_PARAMETERS_SHIM* pCreateExParams)
    {
        typedef HANDLE (WINAPI *PFN_CF2)(LPCWSTR, DWORD, DWORD, DWORD, void*);
        static PFN_CF2 s_real = (PFN_CF2)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "CreateFile2");
        if (s_real) {
            return s_real(lpFileName, dwDesiredAccess, dwShareMode, dwCreationDisposition, pCreateExParams);
        }
        DWORD dwFlagsAndAttributes = 0;
        DWORD dwSecurityFlags = 0;
        if (pCreateExParams && pCreateExParams->dwSize >= sizeof(CREATEFILE2_EXTENDED_PARAMETERS_SHIM)) {
            dwFlagsAndAttributes = pCreateExParams->dwFileAttributes | pCreateExParams->dwFileFlags;
            dwSecurityFlags = pCreateExParams->dwSecurityQosFlags;
        }
        return CreateFileW(lpFileName, dwDesiredAccess, dwShareMode,
                           pCreateExParams ? pCreateExParams->lpSecurityAttributes : NULL,
                           dwCreationDisposition, dwFlagsAndAttributes | dwSecurityFlags,
                           pCreateExParams ? pCreateExParams->hTemplateFile : NULL);
    }

    void* __imp_CreateFile2 = (void*)AuraFallback_CreateFile2;
}
