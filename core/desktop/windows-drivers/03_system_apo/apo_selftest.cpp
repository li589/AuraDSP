// apo_selftest.cpp — 自研 APO 本地 COM 自测（不进 audiodg）。
//
// 全链路：CoCreateInstance → QI 五接口 → Initialize → IsInputFormatSupported →
// LockForProcess（合成 float32 立体声格式）→ APOProcess（正弦透传验证 + 心跳走动）→
// UnlockForProcess。任一步失败即报，便于把“对象 bug”与“audiodg 托管问题”二分。
// 输出单行 JSON；退出码恒 0（结果看 JSON）。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <audioenginebaseapo.h>
#include <audiomediatype.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>

// IID 定义（值抄自 SDK audioenginebaseapo.idl；本 TU 独立一份，与 DLL 内互不冲突）。
#include <initguid.h>
DEFINE_GUID(IID_IAudioProcessingObject,
    0xfd7f2b29, 0x24d0, 0x4b5c, 0xb1, 0x77, 0x59, 0x2c, 0x39, 0xf9, 0xca, 0x10);
DEFINE_GUID(IID_IAudioProcessingObjectRT,
    0x9e1d6a6d, 0xddbc, 0x4e95, 0xa4, 0xc7, 0xad, 0x64, 0xba, 0x37, 0x84, 0x6c);
DEFINE_GUID(IID_IAudioProcessingObjectConfiguration,
    0x0e5ed805, 0xaba6, 0x49c3, 0x8f, 0x9a, 0x2b, 0x8c, 0x88, 0x9c, 0x4f, 0xa8);
DEFINE_GUID(IID_IAudioSystemEffects,
    0x5fa00f27, 0xadd6, 0x499a, 0x8a, 0x9d, 0x6b, 0x98, 0x52, 0x1f, 0xa7, 0x5b);

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

// {415AD8ED-7A45-4F4F-AC69-043830EBC174}
static const CLSID kOurs = {0x415ad8ed, 0x7a45, 0x4f4f,
                            {0xac, 0x69, 0x04, 0x38, 0x30, 0xeb, 0xc1, 0x74}};

namespace {

int g_fail = 0;
void check(const char* name, bool ok, const char* detail = "") {
    printf("[%s] %s %s\n", ok ? "PASS" : "FAIL", name, detail);
    if (!ok) ++g_fail;
}

bool HasGlobalPrivilege() {
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) return false;
    struct {
        DWORD cnt;
        LUID_AND_ATTRIBUTES attrs[1];
    } priv{};
    DWORD size = 0;
    LUID luid;
    if (!LookupPrivilegeValueW(nullptr, L"SeCreateGlobalPrivilege", &luid)) {
        CloseHandle(tok);
        return false;
    }
    if (!GetTokenInformation(tok, TokenPrivileges, &priv, sizeof(priv), &size)) {
        CloseHandle(tok);
        return false;
    }
    bool found = false;
    for (DWORD i = 0; i < priv.cnt; ++i) {
        if (priv.attrs[i].Luid.HighPart == luid.HighPart &&
            priv.attrs[i].Luid.LowPart == luid.LowPart &&
            (priv.attrs[i].Attributes & SE_PRIVILEGE_ENABLED)) {
            found = true;
            break;
        }
    }
    CloseHandle(tok);
    return found;
}

std::string HRes(HRESULT hr) {
    char b[32];
    snprintf(b, sizeof(b), "hr=0x%08lX", (unsigned long)hr);
    return b;
}

}  // namespace

int main() {
    // 心跳命名空间自适应：优先 Global\（=生产路径，需 SeCreateGlobalPrivilege，
    // 管理员/audiodg 才有）；无特权时经 AURAAPO_HEARTBEAT_LOCAL=1 回落 Local\
    //（普通 shell/CI 仍可验证心跳逻辑）。见 AuraApo.cpp OpenHeartbeat。
    if (!HasGlobalPrivilege())
        SetEnvironmentVariableA("AURAAPO_HEARTBEAT_LOCAL", "1");
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {
        printf("{\"selftest\":false,\"reason\":\"coinitialize\"}\n");
        return 0;
    }
    // 未注册（regsvr32 前）也能自测：直接 LoadLibrary + DllGetClassObject，
    // 与 COM 注册无关；已注册则走 CoCreateInstance（双路径幂等）。
    IUnknown* unk = nullptr;
    HRESULT hr = CoCreateInstance(kOurs, nullptr, CLSCTX_INPROC_SERVER, IID_IUnknown,
                                  (void**)&unk);
    bool viaReg = SUCCEEDED(hr) && unk;
    if (!viaReg) {
        HMODULE dll = LoadLibraryW(L"auraapo.dll");  // exe 同目录
        if (!dll) {
            wchar_t self[MAX_PATH] = {0};
            GetModuleFileNameW(nullptr, self, MAX_PATH);
            wchar_t* slash = wcsrchr(self, L'\\');
            wcscpy(slash ? slash + 1 : self, L"AuraApo.dll");
            dll = LoadLibraryW(self);
        }
        if (!dll) {
            check("DllGetClassObject (unreg path)", false, "no dll");
            printf("{\"selftest\":false}\n");
            CoUninitialize();
            return 0;
        }
        using GetClassFn = HRESULT(__stdcall*)(REFCLSID, REFIID, void**);
        auto getClass = (GetClassFn)GetProcAddress(dll, "DllGetClassObject");
        if (getClass) {
            IClassFactory* factory = nullptr;
            hr = getClass(kOurs, IID_IClassFactory, (void**)&factory);
            check("DllGetClassObject (unreg path)", SUCCEEDED(hr) && factory,
                  HRes(hr).c_str());
            if (SUCCEEDED(hr) && factory) {
                hr = factory->CreateInstance(nullptr, IID_IUnknown, (void**)&unk);
                factory->Release();
            }
        } else {
            check("DllGetClassObject (unreg path)", false, "no export");
        }
    }
    check("CreateInstance", unk != nullptr, viaReg ? "via regsvr32" : "via DllGetClassObject");
    if (!unk) {
        printf("{\"selftest\":false}\n");
        CoUninitialize();
        return 0;
    }
    // QI 五接口。
    const IID* iids[5] = {&IID_IAudioProcessingObject, &IID_IAudioProcessingObjectRT,
                          &IID_IAudioProcessingObjectConfiguration, &IID_IAudioSystemEffects,
                          &IID_IUnknown};
    const char* names[5] = {"APO", "APO-RT", "APO-Cfg", "SysFx", "IUnknown"};
    IAudioProcessingObject* apo = nullptr;
    IAudioProcessingObjectRT* rt = nullptr;
    IAudioProcessingObjectConfiguration* cfg = nullptr;
    for (int i = 0; i < 5; ++i) {
        void* p = nullptr;
        hr = unk->QueryInterface(*iids[i], &p);
        char d[128];
        snprintf(d, sizeof(d), "%s %s", names[i], HRes(hr).c_str());
        check("QI", hr == S_OK && p, d);
        if (i == 0) apo = (IAudioProcessingObject*)p;
        if (i == 1) rt = (IAudioProcessingObjectRT*)p;
        if (i == 2) cfg = (IAudioProcessingObjectConfiguration*)p;
        if (p && i >= 3) ((IUnknown*)p)->Release();
    }
    if (!apo || !rt || !cfg) {
        printf("{\"selftest\":false}\n");
        unk->Release();
        CoUninitialize();
        return 0;
    }
    check("Initialize", apo->Initialize(0, nullptr) == S_OK);
    // 基类默认拒绝全 NULL（正确契约）；真格式在 fmt 建好后测。
    {
        HRESULT hrNull =
            apo->IsInputFormatSupported(nullptr, nullptr, nullptr);
        check("IsInputFormatSupported-null-rejected", FAILED(hrNull));
    }
    // 合成 media type（CreateAudioMediaTypeFromUncompressedAudioFormat）。
    UNCOMPRESSEDAUDIOFORMAT uf{};
    uf.guidFormatType = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    uf.dwSamplesPerFrame = 2;
    uf.dwBytesPerSampleContainer = 4;
    uf.dwValidBitsPerSample = 32;
    uf.fFramesPerSecond = 48000.0f;
    uf.dwChannelMask = 3;  // stereo
    IAudioMediaType* fmt = nullptr;
    check("CreateAudioMediaType",
          CreateAudioMediaTypeFromUncompressedAudioFormat(&uf, &fmt) == S_OK && fmt);
    if (!fmt) {
        printf("{\"selftest\":false}\n");
        unk->Release();
        CoUninitialize();
        return 0;
    }
    APO_CONNECTION_DESCRIPTOR inDesc{}, outDesc{};
    inDesc.pFormat = fmt;
    inDesc.u32MaxFrameCount = 512;
    outDesc = inDesc;
    // 真格式协商（IEEE float 立体声 48k，基类默认应接受）。
    {
        IAudioMediaType* supported = nullptr;
        HRESULT hrFmt =
            apo->IsInputFormatSupported(nullptr, fmt, &supported);
        check("IsInputFormatSupported-real", hrFmt == S_OK);
        if (supported) supported->Release();
    }
    APO_CONNECTION_DESCRIPTOR* pins[1] = {&inDesc};
    APO_CONNECTION_DESCRIPTOR* pouts[1] = {&outDesc};
    check("LockForProcess", cfg->LockForProcess(1, pins, 1, pouts) == S_OK);
    // 正弦透传验证。
    const int N = 512;
    float inBuf[1024], outBuf[1024];
    for (int i = 0; i < N; ++i) {
        const float s = (float)(0.3 * sin(2 * 3.14159265358979 * 440.0 * i / 48000.0));
        inBuf[i * 2] = s;
        inBuf[i * 2 + 1] = s;
        outBuf[i * 2] = 12345.0f;
        outBuf[i * 2 + 1] = 12345.0f;
    }
    APO_CONNECTION_PROPERTY inProp{}, outProp{};
    inProp.pBuffer = (UINT_PTR)inBuf;
    inProp.u32ValidFrameCount = N;
    inProp.u32BufferFlags = BUFFER_VALID;
    outProp.pBuffer = (UINT_PTR)outBuf;
    APO_CONNECTION_PROPERTY* pinProps[1] = {&inProp};
    APO_CONNECTION_PROPERTY* poutProps[1] = {&outProp};
    rt->APOProcess(1, pinProps, 1, poutProps);
    int diffAt = -1;
    for (int i = 0; i < N * 2; ++i) {
        if (outBuf[i] != inBuf[i]) {
            diffAt = i;
            break;
        }
    }
    {
        char d[128];
        snprintf(d, sizeof(d), diffAt < 0 ? "exact" : "idx=%d in=%.6f out=%.6f",
                 diffAt, diffAt < 0 ? 0.0 : inBuf[diffAt], diffAt < 0 ? 0.0 : outBuf[diffAt]);
        check("passthrough bit-exact", diffAt < 0, d);
    }
    check("out flags VALID", outProp.u32BufferFlags == BUFFER_VALID);
    check("out frames", outProp.u32ValidFrameCount == (UINT32)N);
    // 心跳映射只在 Lock~Unlock 之间存在：必须先断言，后 Unlock。
    // 注意：selftest 跑在任意权限下（CI/普通 shell 无 SeCreateGlobalPrivilege），
    // 而 Global\ 需要该特权（audiodg=LocalService 才有）。故 selftest 用 Local\
    // 验证心跳逻辑；生产 APO 仍用 Global\（AuraHeartbeat.h）。名字不同、结构相同。
    HANDLE hMap = OpenFileMappingW(FILE_MAP_READ, FALSE, L"Local\\AuraAPO_Heartbeat");
    check("heartbeat mapping exists", hMap != nullptr);
    if (hMap) {
        const void* v = MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, 32);
        check("heartbeat view", v != nullptr);
        if (v) {
            const uint32_t* u = (const uint32_t*)v;
            char d[128];
            snprintf(d, sizeof(d), "magic=%08X ver=%u seq=%u frames=%llu", u[0], u[1], u[2],
                     (unsigned long long)(((uint64_t)u[4]) | ((uint64_t)u[5] << 32)));
            check("heartbeat magic+seq", u[0] == 0x41554248 && u[1] == 1 && u[2] > 0, d);
            UnmapViewOfFile(v);
        }
        CloseHandle(hMap);
    }
    check("UnlockForProcess", cfg->UnlockForProcess() == S_OK);
    rt->Release();
    cfg->Release();
    apo->Release();
    unk->Release();
    if (fmt) fmt->Release();
    CoUninitialize();
    printf("{\"selftest\":%s}\n", g_fail == 0 ? "true" : "false");
    return 0;
}
