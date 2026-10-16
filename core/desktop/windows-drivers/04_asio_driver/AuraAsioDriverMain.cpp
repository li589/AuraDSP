// AuraAsioDriverMain.cpp — AuraDSP 虚拟 ASIO 驱动 DLL 入口与 COM 导出
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <initguid.h>
#include "AuraAsioDriverGuid.h"

#include <new>
#include <string>

#include "AuraAsioClassFactory.h"
#include "AuraAsioDriver.h"

static HINSTANCE g_hModule = nullptr;

BOOL WINAPI DllMain(HINSTANCE hModule, DWORD dwReason, void* /*lpReserved*/) {
    if (dwReason == DLL_PROCESS_ATTACH) {
        g_hModule = hModule;
        DisableThreadLibraryCalls(hModule);
    }
    return TRUE;
}

STDAPI DllCanUnloadNow() {
    if (AuraAsioDriver::s_instanceCount.load(std::memory_order_relaxed) == 0 &&
        AuraAsioClassFactory::s_lockCount.load(std::memory_order_relaxed) == 0) {
        return S_OK;
    }
    return S_FALSE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID iid, void** ppv) {
    if (!ppv) return E_POINTER;
    if (clsid != CLSID_AuraAsioDriver) return CLASS_E_CLASSNOTAVAILABLE;

    auto* factory = new (std::nothrow) AuraAsioClassFactory();
    if (!factory) return E_OUTOFMEMORY;

    const HRESULT hr = factory->QueryInterface(iid, ppv);
    factory->Release();
    return hr;
}

namespace {

LONG SetRegString(HKEY root, const std::wstring& subKey, const wchar_t* valName,
                  const std::wstring& data, REGSAM samExtra = 0) {
    HKEY hKey = nullptr;
    LONG rc = RegCreateKeyExW(root, subKey.c_str(), 0, nullptr, 0,
                              KEY_WRITE | samExtra, nullptr, &hKey, nullptr);
    if (rc != ERROR_SUCCESS) return rc;

    rc = RegSetValueExW(hKey, valName, 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(data.c_str()),
                        (DWORD)((data.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(hKey);
    return rc;
}

LONG DeleteRegKeyTree(HKEY root, const std::wstring& subKey, REGSAM samExtra = 0) {
    // 先尝试 RegDeleteKeyExW（64位视图可用）
    return RegDeleteKeyExW(root, subKey.c_str(), samExtra, 0);
}

}  // namespace

STDAPI DllRegisterServer() {
    wchar_t dllPath[MAX_PATH] = {0};
    if (GetModuleFileNameW(g_hModule, dllPath, MAX_PATH) == 0) {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    const std::wstring clsidStr = kAuraAsioClsidString;
    const std::wstring driverName = L"AuraDSP Driver";
    const std::wstring clsidBase = L"CLSID\\" + clsidStr;
    const std::wstring inprocKey = clsidBase + L"\\InprocServer32";
    const std::wstring hklmClassesBase = L"SOFTWARE\\Classes\\" + clsidBase;
    const std::wstring hklmInprocKey = hklmClassesBase + L"\\InprocServer32";
    const std::wstring asioBase = L"SOFTWARE\\ASIO\\" + driverName;

    // 1. 显式注册 HKLM\SOFTWARE\Classes\CLSID\{...} (确保 UAC 提权宿主如 DAW/探针与普通用户进程均可无歧义定位)
    SetRegString(HKEY_LOCAL_MACHINE, hklmClassesBase, L"", driverName, KEY_WOW64_64KEY);
    SetRegString(HKEY_LOCAL_MACHINE, hklmInprocKey, L"", dllPath, KEY_WOW64_64KEY);
    SetRegString(HKEY_LOCAL_MACHINE, hklmInprocKey, L"ThreadingModel", L"Apartment", KEY_WOW64_64KEY);

    // 2. 注册 HKCR\CLSID\{...} 与 InprocServer32 (同时写 64-bit 视图)
    LONG rc1 = SetRegString(HKEY_CLASSES_ROOT, clsidBase, L"", driverName, KEY_WOW64_64KEY);
    LONG rc2 = SetRegString(HKEY_CLASSES_ROOT, inprocKey, L"", dllPath, KEY_WOW64_64KEY);
    LONG rc3 = SetRegString(HKEY_CLASSES_ROOT, inprocKey, L"ThreadingModel", L"Apartment", KEY_WOW64_64KEY);

    // 3. 注册 HKLM\SOFTWARE\ASIO\AuraDSP Driver (Steinberg ASIO 标准发现路径)
    LONG rc4 = SetRegString(HKEY_LOCAL_MACHINE, asioBase, L"CLSID", clsidStr, KEY_WOW64_64KEY);
    LONG rc5 = SetRegString(HKEY_LOCAL_MACHINE, asioBase, L"Description", driverName, KEY_WOW64_64KEY);

    if (rc1 == ERROR_SUCCESS && rc2 == ERROR_SUCCESS && rc3 == ERROR_SUCCESS &&
        rc4 == ERROR_SUCCESS && rc5 == ERROR_SUCCESS) {
        return S_OK;
    }

    // 若 HKLM 权限不足，回退尝试写入 HKCU，便于用户态开发测试
    SetRegString(HKEY_CURRENT_USER, L"Software\\Classes\\" + clsidBase, L"", driverName);
    SetRegString(HKEY_CURRENT_USER, L"Software\\Classes\\" + inprocKey, L"", dllPath);
    SetRegString(HKEY_CURRENT_USER, L"Software\\Classes\\" + inprocKey, L"ThreadingModel", L"Apartment");
    SetRegString(HKEY_CURRENT_USER, L"Software\\ASIO\\" + driverName, L"CLSID", clsidStr);
    SetRegString(HKEY_CURRENT_USER, L"Software\\ASIO\\" + driverName, L"Description", driverName);

    if (rc4 == ERROR_ACCESS_DENIED || rc1 == ERROR_ACCESS_DENIED) {
        return HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED);
    }

    return E_FAIL;
}

STDAPI DllUnregisterServer() {
    const std::wstring clsidStr = kAuraAsioClsidString;
    const std::wstring driverName = L"AuraDSP Driver";
    const std::wstring clsidBase = L"CLSID\\" + clsidStr;
    const std::wstring inprocKey = clsidBase + L"\\InprocServer32";
    const std::wstring hklmClassesBase = L"SOFTWARE\\Classes\\" + clsidBase;
    const std::wstring hklmInprocKey = hklmClassesBase + L"\\InprocServer32";
    const std::wstring asioBase = L"SOFTWARE\\ASIO\\" + driverName;

    // 逆序删除子键与父键
    DeleteRegKeyTree(HKEY_LOCAL_MACHINE, asioBase, KEY_WOW64_64KEY);
    DeleteRegKeyTree(HKEY_LOCAL_MACHINE, hklmInprocKey, KEY_WOW64_64KEY);
    DeleteRegKeyTree(HKEY_LOCAL_MACHINE, hklmClassesBase, KEY_WOW64_64KEY);
    DeleteRegKeyTree(HKEY_CLASSES_ROOT, inprocKey, KEY_WOW64_64KEY);
    DeleteRegKeyTree(HKEY_CLASSES_ROOT, clsidBase, KEY_WOW64_64KEY);

    // 清理 HKCU 回退键
    DeleteRegKeyTree(HKEY_CURRENT_USER, L"Software\\ASIO\\" + driverName);
    DeleteRegKeyTree(HKEY_CURRENT_USER, L"Software\\Classes\\" + inprocKey);
    DeleteRegKeyTree(HKEY_CURRENT_USER, L"Software\\Classes\\" + clsidBase);

    return S_OK;
}
