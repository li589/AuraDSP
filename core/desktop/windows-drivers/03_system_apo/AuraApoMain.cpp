// AuraApoMain.cpp — DLL 入口 + COM 导出 + 自注册（EAPO DllMain 同式，自写）。
//
// 自注册写两处（均需管理员，regsvr32 提权跑）：
//  1. HKCR\AudioEngine\AudioProcessingObjects\{EFX}（SDK ::RegisterAPO，属性见
//     CAuraApo::regEfxProperties）；
//  2. HKCR\CLSID\{EFX}\InprocServer32（本 DLL 路径 + ThreadingModel Both）。
// 注意：这只是“APO 已注册”，离“装到端点”还差 Configurator 的 FxProperties 写入
// （后续 slice；卸载同样先清端点再反注册，顺序不可反）。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <audioenginebaseapo.h>

// 本 TU 是 CLSID 唯一定义点（其它 TU 只声明）。
#include <initguid.h>

// 四个 APO 接口 IID（值抄自 SDK audioenginebaseapo.idl，权威唯一来源）：
// IAudioProcessingObject=FD7F2B29.., RT=9E1D6A6D.., Config=0E5ED805.., SysFx=5FA00F27..
// SDK 只给 EXTERN_C 声明，定义无随行 lib，故在此显式定义（勿改值，QI 全靠它们）。
DEFINE_GUID(IID_IAudioProcessingObject,
    0xfd7f2b29, 0x24d0, 0x4b5c, 0xb1, 0x77, 0x59, 0x2c, 0x39, 0xf9, 0xca, 0x10);
DEFINE_GUID(IID_IAudioProcessingObjectRT,
    0x9e1d6a6d, 0xddbc, 0x4e95, 0xa4, 0xc7, 0xad, 0x64, 0xba, 0x37, 0x84, 0x6c);
DEFINE_GUID(IID_IAudioProcessingObjectConfiguration,
    0x0e5ed805, 0xaba6, 0x49c3, 0x8f, 0x9a, 0x2b, 0x8c, 0x88, 0x9c, 0x4f, 0xa8);
DEFINE_GUID(IID_IAudioSystemEffects,
    0x5fa00f27, 0xadd6, 0x499a, 0x8a, 0x9d, 0x6b, 0x98, 0x52, 0x1f, 0xa7, 0x5b);
// 值取自 SDK MIDL_INTERFACE，已用 audioeng.dll 二进制交叉验证。
DEFINE_GUID(IID_IAudioSystemEffects2,
    0xbafe99d2, 0x7436, 0x44ce, 0x9e, 0x0e, 0x4d, 0x89, 0xaf, 0xbf, 0xff, 0x56);

#include <new>
#include <string>

#include "ApoClassFactory.h"
#include "AuraApo.h"
#include "AuraApoGuid.h"

static HINSTANCE g_hModule = nullptr;

BOOL WINAPI DllMain(HINSTANCE hModule, DWORD dwReason, void* /*lpReserved*/) {
    if (dwReason == DLL_PROCESS_ATTACH) {
        g_hModule = hModule;
        DisableThreadLibraryCalls(hModule);
    }
    return TRUE;
}

STDAPI DllCanUnloadNow() {
    if (CAuraApo::instCount == 0 && ApoClassFactory::lockCount == 0)
        return S_OK;
    return S_FALSE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID iid, void** ppv) {
    if (!ppv) return E_POINTER;
    if (clsid != CLSID_AuraApoEfx) return CLASS_E_CLASSNOTAVAILABLE;
    auto* factory = new (std::nothrow) ApoClassFactory();
    if (!factory) return E_OUTOFMEMORY;
    const HRESULT hr = factory->QueryInterface(iid, ppv);
    factory->Release();
    return hr;
}

namespace {

std::wstring GuidString(const GUID& g) {
    wchar_t buf[64] = {0};
    swprintf_s(buf,
               L"{%08lX-%04hX-%04hX-%02hhX%02hhX-%02hhX%02hhX%02hhX%02hhX%02hhX%02hhX}",
               g.Data1, g.Data2, g.Data3, g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3],
               g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7]);
    return buf;
}

LONG WriteSz(HKEY root, const std::wstring& sub, const std::wstring& val, const std::wstring& data) {
    HKEY h = nullptr;
    LONG rc = RegCreateKeyExW(root, sub.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &h, nullptr);
    if (rc != ERROR_SUCCESS) return rc;
    rc = RegSetValueExW(h, val.c_str(), 0, REG_SZ, (const BYTE*)data.c_str(),
                        (DWORD)((data.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(h);
    return rc;
}

}  // namespace

STDAPI DllRegisterServer() {
    HRESULT hr = RegisterAPO(CAuraApo::regEfxProperties);
    if (FAILED(hr)) return hr;
    wchar_t filename[MAX_PATH] = {0};
    GetModuleFileNameW(g_hModule, filename, MAX_PATH);
    const std::wstring clsid = GuidString(CLSID_AuraApoEfx);
    const std::wstring base = L"CLSID\\" + clsid;
    if (WriteSz(HKEY_CLASSES_ROOT, base, L"", L"AuraAPO EFX") != ERROR_SUCCESS ||
        WriteSz(HKEY_CLASSES_ROOT, base + L"\\InprocServer32", L"", filename) != ERROR_SUCCESS ||
        WriteSz(HKEY_CLASSES_ROOT, base + L"\\InprocServer32", L"ThreadingModel", L"Both") != ERROR_SUCCESS) {
        UnregisterAPO(CLSID_AuraApoEfx);
        return E_FAIL;
    }
    return S_OK;
}

STDAPI DllUnregisterServer() {
    const std::wstring clsid = GuidString(CLSID_AuraApoEfx);
    const std::wstring base = L"CLSID\\" + clsid;
    // 删子键再删父键（与注册逆序；残留即脏注册，regsvr32 /u 后必查）。
    RegDeleteKeyW(HKEY_CLASSES_ROOT, (base + L"\\InprocServer32").c_str());
    RegDeleteKeyW(HKEY_CLASSES_ROOT, base.c_str());
    return UnregisterAPO(CLSID_AuraApoEfx);
}
