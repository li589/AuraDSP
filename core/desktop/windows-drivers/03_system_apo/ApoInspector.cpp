// ApoInspector.cpp — 见头文件。
// 键位全部来自 EAPO 实测（source/equalizerAPO64 DeviceAPOInfo.cpp:53-76）：
// FxProperties 下 {d04e05a6-594b-4fb6-a80d-01af5eed7d1d},1/2/5/6/7；
// ProcessingModes {d3993a3f-99c2-4402-b5ec-a92a0367664b},5/6/7；
// DisableEnhancements {1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5；
// FxFriendlyName {b725f130-47ef-101a-a5f1-02608c9eebac},10；
// 全局 HKLM\...\Audio!DisableProtectedAudioDG。
#include "ApoInspector.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <propkey.h>
#include <functiondiscoverykeys_devpkey.h>
#include <windows.h>

#include <cstdio>

namespace {

std::string WideToUtf8(const wchar_t* w) {
    if (!w || !*w) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return {};
    std::string s((size_t)n - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
    return s;
}

std::string ReadRegSz(HKEY root, const std::wstring& sub, const std::wstring& val) {
    HKEY h = nullptr;
    if (RegOpenKeyExW(root, sub.c_str(), 0, KEY_READ, &h) != ERROR_SUCCESS) return {};
    wchar_t buf[1024] = {0};
    DWORD len = sizeof(buf), type = 0;
    std::string out;
    if (RegQueryValueExW(h, val.c_str(), nullptr, &type, (BYTE*)buf, &len) == ERROR_SUCCESS &&
        (type == REG_SZ || type == REG_EXPAND_SZ))
        out = WideToUtf8(buf);
    RegCloseKey(h);
    return out;
}

bool ReadRegDword(HKEY root, const std::wstring& sub, const std::wstring& val, DWORD& out) {
    HKEY h = nullptr;
    if (RegOpenKeyExW(root, sub.c_str(), 0, KEY_READ, &h) != ERROR_SUCCESS) return false;
    DWORD len = sizeof(DWORD), type = 0;
    const bool ok = RegQueryValueExW(h, val.c_str(), nullptr, &type, (BYTE*)&out, &len) == ERROR_SUCCESS &&
                    type == REG_DWORD;
    RegCloseKey(h);
    return ok;
}

const wchar_t* kFxBase = L"{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},";

ApoEndpoint ReadEndpoint(IMMDevice* dev, const std::string& dir) {
    ApoEndpoint e;
    e.direction = dir;
    wchar_t* wid = nullptr;
    if (dev->GetId(&wid) == S_OK && wid) {
        e.id = WideToUtf8(wid);
        CoTaskMemFree(wid);
    }
    DWORD state = 0;
    if (dev->GetState(&state) == S_OK) e.state = (unsigned long)state;
    // 友好名。
    IPropertyStore* ps = nullptr;
    if (dev->OpenPropertyStore(STGM_READ, &ps) == S_OK && ps) {
        PROPVARIANT v;
        PropVariantInit(&v);
        if (ps->GetValue(PKEY_Device_FriendlyName, &v) == S_OK && v.pwszVal)
            e.name = WideToUtf8(v.pwszVal);
        PropVariantClear(&v);
        ps->Release();
    }
    // FxProperties（读不到置 readable=false，不判 FAIL）。
    // 注意：GetId 返回长式 `{0.0.0.00000000}.{guid}`，注册表键是短式 `{guid}`。
    std::wstring fxSub =
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\";
    fxSub += (dir == "render" ? L"Render\\" : L"Capture\\");
    {
        std::string shortId = e.id;
        const std::string kPrefix = "{0.0.0.00000000}.";
        const std::string kPrefixCap = "{0.0.1.00000000}.";
        if (shortId.rfind(kPrefix, 0) == 0)
            shortId = shortId.substr(kPrefix.size());
        else if (shortId.rfind(kPrefixCap, 0) == 0)
            shortId = shortId.substr(kPrefixCap.size());
        wchar_t tmp[128] = {0};
        MultiByteToWideChar(CP_UTF8, 0, shortId.c_str(), -1, tmp, 128);
        fxSub += tmp;
    }
    fxSub += L"\\FxProperties";
    static const wchar_t* kSlots[5] = {L"1", L"2", L"5", L"6", L"7"};
    HKEY hFx = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, fxSub.c_str(), 0, KEY_READ, &hFx) != ERROR_SUCCESS) {
        e.readable = false;
        return e;
    }
    for (const wchar_t* s : kSlots) {
        std::wstring key = std::wstring(kFxBase) + s;
        wchar_t buf[256] = {0};
        DWORD len = sizeof(buf), type = 0;
        ApoSlot slot{WideToUtf8(key.c_str()), {}};
        if (RegQueryValueExW(hFx, key.c_str(), nullptr, &type, (BYTE*)buf, &len) == ERROR_SUCCESS &&
            (type == REG_SZ || type == REG_EXPAND_SZ))
            slot.value = WideToUtf8(buf);
        e.fx.push_back(slot);
    }
    {
        wchar_t buf[256] = {0};
        DWORD len = sizeof(buf), type = 0;
        if (RegQueryValueExW(hFx, L"{b725f130-47ef-101a-a5f1-02608c9eebac},10", nullptr, &type,
                             (BYTE*)buf, &len) == ERROR_SUCCESS)
            e.friendlyName = WideToUtf8(buf);
    }
    {
        DWORD dis = 0, len = sizeof(dis), type = 0;
        if (RegQueryValueExW(hFx, L"{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5", nullptr, &type,
                             (BYTE*)&dis, &len) == ERROR_SUCCESS &&
            type == REG_DWORD)
            e.enhancementsDisabled = (dis != 0);
    }
    RegCloseKey(hFx);
    return e;
}

}  // namespace

ApoInspect ApoInspectRun() {
    ApoInspect out;
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {
        out.note = "coinitialize-failed";
        return out;
    }
    IMMDeviceEnumerator* en = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator), (void**)&en)) ||
        !en) {
        out.note = "no-device-enumerator";
        CoUninitialize();
        return out;
    }
    const EDataFlow flows[2] = {eRender, eCapture};
    const char* dirs[2] = {"render", "capture"};
    for (int f = 0; f < 2; ++f) {
        IMMDeviceCollection* col = nullptr;
        if (FAILED(en->EnumAudioEndpoints(flows[f], DEVICE_STATEMASK_ALL, &col)) || !col)
            continue;
        UINT n = 0;
        col->GetCount(&n);
        for (UINT i = 0; i < n; ++i) {
            IMMDevice* dev = nullptr;
            if (col->Item(i, &dev) == S_OK && dev) {
                out.endpoints.push_back(ReadEndpoint(dev, dirs[f]));
                dev->Release();
            }
        }
        col->Release();
    }
    en->Release();
    DWORD dis = 0;
    if (ReadRegDword(HKEY_LOCAL_MACHINE,
                     L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Audio",
                     L"DisableProtectedAudioDG", dis))
        out.protectedAudioDG = (dis != 0) ? 1 : 0;
    CoUninitialize();
    return out;
}
