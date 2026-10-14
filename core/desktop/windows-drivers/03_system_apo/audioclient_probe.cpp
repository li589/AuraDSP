// audioclient_probe.cpp — 直接测 IAudioClient COM 激活（不经端点枚举）。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <cstdio>

int main() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IMMDeviceEnumerator* en = nullptr;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                  __uuidof(IMMDeviceEnumerator), (void**)&en);
    printf("MMDevEnum hr=0x%08lX\n", (unsigned long)hr);
    if (FAILED(hr)) { CoUninitialize(); return 0; }
    IMMDevice* def = nullptr;
    hr = en->GetDefaultAudioEndpoint(eRender, eConsole, &def);
    printf("GetDefault hr=0x%08lX\n", (unsigned long)hr);
    if (SUCCEEDED(hr)) {
        IAudioClient* ac = nullptr;
        hr = def->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&ac);
        printf("Activate IAudioClient hr=0x%08lX ac=%p\n", (unsigned long)hr, ac);
        if (SUCCEEDED(hr) && ac) {
            WAVEFORMATEX* wf = nullptr;
            hr = ac->GetMixFormat(&wf);
            printf("GetMixFormat hr=0x%08lX\n", (unsigned long)hr);
            if (SUCCEEDED(hr)) {
                REFERENCE_TIME dur = 0;
                ac->GetDevicePeriod(nullptr, &dur);
                hr = ac->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, dur ? dur : 100000, 0, wf, nullptr);
                printf("Initialize(shared) hr=0x%08lX\n", (unsigned long)hr);
                CoTaskMemFree(wf);
            }
            ac->Release();
        }
        def->Release();
    }
    en->Release();
    CoUninitialize();
    return 0;
}
