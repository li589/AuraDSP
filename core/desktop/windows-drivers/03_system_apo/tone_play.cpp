// tone_play.cpp — 指定端点正弦播放器（APO 验证用测试信号源）。
//
// 用法：tone_play <endpoint-name-substring> [seconds=5] [freq=440]
// 经 WASAPI 共享模式向指定 Render 端点播正弦，触发 audiodg APO 链。
// 只读系统状态，不改任何设置；退出码 0 = 播完，2 = 端点不明/多义。
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <propkey.h>
#include <functiondiscoverykeys_devpkey.h>
#include <windows.h>

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace {

std::string WideToUtf8(const wchar_t* w) {
    if (!w || !*w) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return {};
    std::string s((size_t)n - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
    return s;
}

bool ContainsCI(const std::string& hay, const std::string& needle) {
    if (needle.empty()) return true;
    for (size_t i = 0; i + needle.size() <= hay.size(); ++i) {
        size_t j = 0;
        for (; j < needle.size(); ++j) {
            char a = hay[i + j], b = needle[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) break;
        }
        if (j == needle.size()) return true;
    }
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        printf("usage: tone_play <endpoint-name-substring> [seconds=5] [freq=440]\n");
        return 2;
    }
    const std::string want(argv[1]);
    int seconds = argc > 2 ? atoi(argv[2]) : 5;
    if (seconds <= 0 || seconds > 60) seconds = 5;
    const double freq = argc > 3 ? atof(argv[3]) : 440.0;
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 2;

    IMMDeviceEnumerator* en = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator), (void**)&en)) ||
        !en) {
        CoUninitialize();
        return 2;
    }
    IMMDeviceCollection* col = nullptr;
    if (FAILED(en->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &col)) || !col) {
        en->Release();
        CoUninitialize();
        return 2;
    }
    UINT n = 0;
    col->GetCount(&n);
    IMMDevice* pick = nullptr;
    std::string pickName;
    int hits = 0;
    for (UINT i = 0; i < n; ++i) {
        IMMDevice* dev = nullptr;
        if (col->Item(i, &dev) != S_OK || !dev) continue;
        IPropertyStore* ps = nullptr;
        std::string nm;
        if (dev->OpenPropertyStore(STGM_READ, &ps) == S_OK && ps) {
            PROPVARIANT v;
            PropVariantInit(&v);
            if (ps->GetValue(PKEY_Device_FriendlyName, &v) == S_OK && v.pwszVal)
                nm = WideToUtf8(v.pwszVal);
            PropVariantClear(&v);
            ps->Release();
        }
        if (ContainsCI(nm, want)) {
            ++hits;
            if (!pick) {
                pick = dev;
                pickName = nm;
            } else {
                dev->Release();
            }
        } else {
            dev->Release();
        }
    }
    col->Release();
    en->Release();
    if (!pick || hits != 1) {
        printf("{\"played\":false,\"reason\":\"%s\"}\n",
               !pick ? "no-match" : "ambiguous");
        CoUninitialize();
        return 0;
    }
    IAudioClient* ac = nullptr;
    HRESULT hr = pick->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&ac);
    pick->Release();
    if (FAILED(hr) || !ac) {
        printf("{\"played\":false,\"reason\":\"activate-failed\"}\n");
        CoUninitialize();
        return 0;
    }
    WAVEFORMATEX* wf = nullptr;
    hr = ac->GetMixFormat(&wf);
    if (FAILED(hr) || !wf) {
        ac->Release();
        CoUninitialize();
        return 0;
    }
    REFERENCE_TIME dur = 0;
    ac->GetDevicePeriod(nullptr, &dur);
    if (dur <= 0) dur = 100000;  // 10ms
    hr = ac->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, dur, 0, wf, nullptr);
    if (FAILED(hr)) {
        CoTaskMemFree(wf);
        ac->Release();
        CoUninitialize();
        printf("{\"played\":false,\"reason\":\"init-failed\",\"hr\":\"0x%08lX\"}\n",
               (unsigned long)hr);
        return 0;
    }
    const int ch = wf->nChannels > 0 ? wf->nChannels : 2;
    const int rate = wf->nSamplesPerSec > 0 ? wf->nSamplesPerSec : 48000;
    UINT32 bufFrames = 0;
    ac->GetBufferSize(&bufFrames);
    IAudioRenderClient* rc = nullptr;
    ac->GetService(__uuidof(IAudioRenderClient), (void**)&rc);
    CoTaskMemFree(wf);
    if (!rc) {
        ac->Release();
        CoUninitialize();
        return 0;
    }
    // 预填一缓冲后启动（防首块欠载爆音）。
    BYTE* p = nullptr;
    double phase = 0.0;
    const double d = 2.0 * 3.14159265358979 * freq / rate;
    auto fill = [&](UINT32 frames) {
        if (FAILED(rc->GetBuffer(frames, &p)) || !p) return (UINT32)0;
        float* f = (float*)p;
        for (UINT32 i = 0; i < frames; ++i) {
            const float s = (float)(0.25 * sin(phase));
            phase += d;
            if (phase > 2 * 3.14159265358979) phase -= 2 * 3.14159265358979;
            for (int c = 0; c < ch; ++c) f[i * ch + c] = s;
        }
        rc->ReleaseBuffer(frames, 0);
        return frames;
    };
    fill(bufFrames);
    ac->Start();
    const long long total = (long long)rate * seconds;
    long long done = 0;
    while (done < total) {
        Sleep(10);
        UINT32 pad = 0;
        if (FAILED(ac->GetCurrentPadding(&pad))) break;
        if (pad >= bufFrames) continue;
        done += fill(bufFrames - pad);
    }
    Sleep(200);
    ac->Stop();
    rc->Release();
    ac->Release();
    CoUninitialize();
    printf("{\"played\":true,\"endpoint\":\"%s\",\"seconds\":%d,\"freq\":%.1f}\n",
           pickName.c_str(), seconds, freq);
    return 0;
}
