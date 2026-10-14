// set_default_endpoint.cpp — 设置系统默认播放端点（IPolicyConfig COM）。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <mmdeviceapi.h>
#include <objbase.h>

#include <cstdio>
#include <string>

// CLSID_CPolicyConfigClient = {870af99c-171d-4f9e-af0d-e63df40c2bc9}
static const CLSID kClsidPolicyConfig = {0x870af99c, 0x171d, 0x4f9e,
                                         {0xaf, 0x0d, 0xe6, 0x3d, 0xf4, 0x0c, 0x2b, 0xc9}};
// IID_IPolicyConfig（v1，Win7+）= {f8679f50-850a-41cf-9c72-430f290290c8}
static const IID kIidPolicyConfig = {0xf8679f50, 0x850a, 0x41cf,
                                     {0x9c, 0x72, 0x43, 0x0f, 0x29, 0x02, 0x90, 0xc8}};

struct IPolicyConfig {
    struct Vtbl;
    Vtbl* lpVtbl;
};
struct IPolicyConfig::Vtbl {
    HRESULT(__stdcall* QueryInterface)(IPolicyConfig*, REFIID, void**);
    ULONG(__stdcall* AddRef)(IPolicyConfig*);
    ULONG(__stdcall* Release)(IPolicyConfig*);
    HRESULT(__stdcall* GetMixFormat)(IPolicyConfig*, const wchar_t*, void**);
    HRESULT(__stdcall* GetDeviceFormat)(IPolicyConfig*, const wchar_t*, int, void**);
    HRESULT(__stdcall* ResetDeviceFormat)(IPolicyConfig*, const wchar_t*);
    HRESULT(__stdcall* SetDeviceFormat)(IPolicyConfig*, const wchar_t*, void*, void*);
    HRESULT(__stdcall* GetProcessingPeriod)(IPolicyConfig*, const wchar_t*, int, void*, void*);
    HRESULT(__stdcall* SetProcessingPeriod)(IPolicyConfig*, const wchar_t*, void*);
    HRESULT(__stdcall* GetShareMode)(IPolicyConfig*, const wchar_t*, void*);
    HRESULT(__stdcall* SetShareMode)(IPolicyConfig*, const wchar_t*, void*);
    HRESULT(__stdcall* GetPropertyValue)(IPolicyConfig*, const wchar_t*, const void*, void*);
    HRESULT(__stdcall* SetPropertyValue)(IPolicyConfig*, const wchar_t*, const void*, void*);
    HRESULT(__stdcall* SetDefaultEndpoint)(IPolicyConfig*, const wchar_t*, ERole);
    HRESULT(__stdcall* SetEndpointVisibility)(IPolicyConfig*, const wchar_t*, int);
};

int main(int argc, char** argv) {
    if (argc < 2) {
        printf("usage: set_default_endpoint <endpoint-id> [role]\n");
        return 2;
    }
    const int role = argc > 2 ? atoi(argv[2]) : 0;
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 2;
    IPolicyConfig* pc = nullptr;
    HRESULT hr = CoCreateInstance(kClsidPolicyConfig, nullptr, CLSCTX_ALL, kIidPolicyConfig,
                                  (void**)&pc);
    if (FAILED(hr) || !pc) {
        printf("{\"ok\":false,\"reason\":\"policyconfig-create\",\"hr\":\"0x%08lX\"}\n",
               (unsigned long)hr);
        CoUninitialize();
        return 0;
    }
    std::wstring wid;
    const int n = MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, nullptr, 0);
    if (n > 0) {
        wid.resize((size_t)n - 1);
        MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, wid.data(), n);
    }
    hr = pc->lpVtbl->SetDefaultEndpoint(pc, wid.c_str(), (ERole)role);
    pc->lpVtbl->Release(pc);
    CoUninitialize();
    printf("{\"ok\":%s,\"role\":%d,\"hr\":\"0x%08lX\"}\n", SUCCEEDED(hr) ? "true" : "false",
           role, (unsigned long)hr);
    return 0;
}
