// vaio_set_format.cpp — 开发验证工具（格式升级一期，2026-11-12）：
// 查看/设置任意渲染端点的「设备格式」（即声音设置「高级」里的默认
// 格式），供 VAIO 格式矩阵真机验证使用。经未公开但长期稳定的
// IPolicyConfig::GetDeviceFormat/SetDeviceFormat 完成，与系统面板
// 的下拉改的是同一份端点属性；audiosrv 对新开的流即刻按新格式协商。
// 仅开发验证用途，不进发行包。
//
// 用法：
//   vaio_set_format show <端点名子串>
//       打印端点的设备格式与当前混音格式。
//   vaio_set_format set <端点名子串> <采样率> <声道> <容器位深> <有效位深> <pcm|float>
//       例：vaio_set_format set AuraVAIO 96000 2 32 24 pcm   （24-in-32）
//           vaio_set_format set AuraVAIO 44100 2 24 24 pcm   （24 紧密）
//           vaio_set_format set AuraVAIO 48000 6 32 32 float （5.1 float）
//       声道掩码按 2=立体声 / 4=四声道 / 6=5.1 SURROUND / 8=7.1 SURROUND。
//
// 构建：cl /utf-8 /EHsc /O2 vaio_set_format.cpp /link ole32.lib uuid.lib
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <cstdio>
#include <cstring>
#include <string>

#pragma comment(lib, "ole32.lib")

// IPolicyConfig（Vista 起的未公开接口；GUID 与虚表序为业界通行定义，
// EarTrumpet 等开源工具同款）。SetDeviceFormat 的第二参数为独占格式
// （本工具传 nullptr，只改共享设备格式）。
struct IPolicyConfig : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE GetMixFormat(PCWSTR, WAVEFORMATEX**) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetDeviceFormat(PCWSTR, INT, WAVEFORMATEX**) = 0;
    virtual HRESULT STDMETHODCALLTYPE ResetDeviceFormat(PCWSTR) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetDeviceFormat(PCWSTR, const WAVEFORMATEX*, const WAVEFORMATEX*) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetProcessingPeriod(PCWSTR, BOOL, PINT64, PINT64) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetProcessingPeriod(PCWSTR, PINT64) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetShareMode(PCWSTR, void*) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetShareMode(PCWSTR, void*) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetPropertyValue(PCWSTR, const PROPERTYKEY&, PROPVARIANT*) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetPropertyValue(PCWSTR, const PROPERTYKEY&, PROPVARIANT*) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetDefaultEndpoint(PCWSTR, ERole) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetEndpointVisibility(PCWSTR, BOOL) = 0;
};
// {870af99c-171d-4f9e-af0d-e63df40c2bc9} CPolicyConfigClient
static const CLSID CLSID_PolicyConfigClient =
    {0x870af99c, 0x171d, 0x4f9e, {0xaf, 0x0d, 0xe6, 0x3d, 0xf4, 0x0c, 0x2b, 0xc9}};
// {f8679f50-850a-41cf-9c72-430f290290c8} IPolicyConfig
static const IID IID_PolicyConfig =
    {0xf8679f50, 0x850a, 0x41cf, {0x9c, 0x72, 0x43, 0x0f, 0x29, 0x02, 0x90, 0xc8}};

static void PrintFormat(const char* label, const WAVEFORMATEX* f) {
    if (!f) { printf("%s: <null>\n", label); return; }
    unsigned valid = f->wBitsPerSample;
    std::string sub = "?";
    if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE && f->cbSize >= 22) {
        const WAVEFORMATEXTENSIBLE* e = (const WAVEFORMATEXTENSIBLE*)f;
        valid = e->Samples.wValidBitsPerSample ? e->Samples.wValidBitsPerSample
                                               : f->wBitsPerSample;
        sub = IsEqualGUID(e->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) ? "float"
            : IsEqualGUID(e->SubFormat, KSDATAFORMAT_SUBTYPE_PCM) ? "pcm" : "other";
    } else if (f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        sub = "float";
    } else if (f->wFormatTag == WAVE_FORMAT_PCM) {
        sub = "pcm";
    }
    printf("%s: rate=%lu ch=%u container=%u valid=%u type=%s tag=0x%x align=%u\n",
           label, (unsigned long)f->nSamplesPerSec, f->nChannels,
           f->wBitsPerSample, valid, sub.c_str(), f->wFormatTag, f->nBlockAlign);
}

static DWORD MaskForChannels(int ch) {
    switch (ch) {
        case 1: return KSAUDIO_SPEAKER_MONO;
        case 2: return KSAUDIO_SPEAKER_STEREO;
        case 4: return KSAUDIO_SPEAKER_QUAD;
        case 6: return KSAUDIO_SPEAKER_5POINT1_SURROUND;
        case 8: return KSAUDIO_SPEAKER_7POINT1_SURROUND;
    }
    return 0;
}

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) {
        printf("usage: vaio_set_format show <name-substr>\n"
               "       vaio_set_format set <name-substr> <rate> <ch> "
               "<containerBits> <validBits> <pcm|float>\n");
        return 2;
    }
    const bool doSet = _wcsicmp(argv[1], L"set") == 0;
    const std::wstring needle = argv[2];

    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) { printf("CoInitializeEx failed 0x%08lx\n", (unsigned long)hr); return 1; }

    IMMDeviceEnumerator* en = nullptr;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), (void**)&en);
    if (FAILED(hr)) { printf("enumerator failed 0x%08lx\n", (unsigned long)hr); return 1; }

    IMMDeviceCollection* coll = nullptr;
    hr = en->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &coll);
    if (FAILED(hr)) { printf("enum failed 0x%08lx\n", (unsigned long)hr); return 1; }

    IMMDevice* dev = nullptr;
    LPWSTR devId = nullptr;
    std::wstring devName;
    UINT count = 0;
    coll->GetCount(&count);
    for (UINT i = 0; i < count && !dev; i++) {
        IMMDevice* d = nullptr;
        if (FAILED(coll->Item(i, &d))) continue;
        IPropertyStore* ps = nullptr;
        std::wstring name;
        if (SUCCEEDED(d->OpenPropertyStore(STGM_READ, &ps))) {
            PROPVARIANT pv;
            PropVariantInit(&pv);
            if (SUCCEEDED(ps->GetValue(PKEY_Device_FriendlyName, &pv)) &&
                pv.vt == VT_LPWSTR && pv.pwszVal) name = pv.pwszVal;
            PropVariantClear(&pv);
            ps->Release();
        }
        if (name.find(needle) != std::wstring::npos) {
            dev = d;
            devName = name;
            dev->GetId(&devId);
        } else {
            d->Release();
        }
    }
    coll->Release();
    en->Release();
    if (!dev) { printf("no active render endpoint matches the substring\n"); return 1; }
    printf("endpoint: %ls\n", devName.c_str());

    IPolicyConfig* pol = nullptr;
    hr = CoCreateInstance(CLSID_PolicyConfigClient, nullptr, CLSCTX_ALL,
                          IID_PolicyConfig, (void**)&pol);
    if (FAILED(hr)) { printf("IPolicyConfig failed 0x%08lx\n", (unsigned long)hr); return 1; }

    WAVEFORMATEX* cur = nullptr;
    if (SUCCEEDED(pol->GetDeviceFormat(devId, FALSE, &cur))) {
        PrintFormat("device-format", cur);
        CoTaskMemFree(cur); cur = nullptr;
    } else {
        printf("device-format: <unreadable>\n");
    }

    int rc = 0;
    if (doSet) {
        if (argc < 8) { printf("set needs rate/ch/container/valid/type\n"); rc = 2; }
        else {
            const DWORD rate = (DWORD)_wtoi(argv[3]);
            const int ch = _wtoi(argv[4]);
            const WORD contBits = (WORD)_wtoi(argv[5]);
            const WORD validBits = (WORD)_wtoi(argv[6]);
            const bool isFloat = _wcsicmp(argv[7], L"float") == 0;
            WAVEFORMATEXTENSIBLE wfe = {};
            wfe.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
            wfe.Format.nChannels = (WORD)ch;
            wfe.Format.nSamplesPerSec = rate;
            wfe.Format.wBitsPerSample = contBits;
            wfe.Format.nBlockAlign = (WORD)(ch * (contBits / 8));
            wfe.Format.nAvgBytesPerSec = rate * wfe.Format.nBlockAlign;
            wfe.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
            wfe.Samples.wValidBitsPerSample = validBits;
            wfe.dwChannelMask = MaskForChannels(ch);
            wfe.SubFormat = isFloat ? KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
                                    : KSDATAFORMAT_SUBTYPE_PCM;
            hr = pol->SetDeviceFormat(devId, (const WAVEFORMATEX*)&wfe, nullptr);
            printf("SetDeviceFormat -> 0x%08lx\n", (unsigned long)hr);
            if (FAILED(hr)) rc = 1;
            if (SUCCEEDED(pol->GetDeviceFormat(devId, FALSE, &cur))) {
                PrintFormat("device-format-after", cur);
                CoTaskMemFree(cur); cur = nullptr;
            }
        }
    }

    pol->Release();
    CoTaskMemFree(devId);
    dev->Release();
    CoUninitialize();
    return rc;
}
