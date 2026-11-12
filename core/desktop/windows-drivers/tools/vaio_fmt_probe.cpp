// vaio_fmt_probe.cpp — VAIO 24-bit format family exclusive/shared support probe (dev-only)
//
// Round-20 phase-1 verification tool: asks IAudioClient::IsFormatSupported
// (EXCLUSIVE + SHARED) for the new 24-bit family (packed 24, 24-in-32,
// true int32, valid-20) plus two controls (float stereo, PCM16 stereo)
// against the AuraVAIO render endpoint. A/B against the previous driver
// build discriminates whether the new pin data ranges + intersection
// valid-bits handling are accepted by audiosrv's format validation.
//
// Build (VS2017+ x64, from this directory):
//   cl /utf-8 /EHsc /O2 vaio_fmt_probe.cpp /link ole32.lib uuid.lib
//
// Usage: vaio_fmt_probe [endpoint-name-substring]   (default: AuraVAIO)
// Output: one ASCII line per case:
//   CASE <tag> ch=<n> rate=<r> cont=<c> valid=<v> type=<pcm|float>
//        excl=0x........ shared=0x........

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <cstdio>
#include <string>

static void TestOne(IAudioClient* client, const char* tag, WORD ch, DWORD rate,
                    WORD container, WORD valid, bool isFloat, DWORD mask) {
    WAVEFORMATEXTENSIBLE wfe = {};
    wfe.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wfe.Format.nChannels = ch;
    wfe.Format.nSamplesPerSec = rate;
    wfe.Format.wBitsPerSample = container;
    wfe.Format.nBlockAlign = (WORD)(ch * container / 8);
    wfe.Format.nAvgBytesPerSec = rate * wfe.Format.nBlockAlign;
    wfe.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wfe.Samples.wValidBitsPerSample = valid;
    wfe.dwChannelMask = mask;
    wfe.SubFormat = isFloat ? KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
                            : KSDATAFORMAT_SUBTYPE_PCM;
    WAVEFORMATEX* closest = nullptr;
    HRESULT hrS = client->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED,
                                            (WAVEFORMATEX*)&wfe, &closest);
    if (closest) CoTaskMemFree(closest);
    HRESULT hrE = client->IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE,
                                            (WAVEFORMATEX*)&wfe, nullptr);
    printf("CASE %s ch=%u rate=%lu cont=%u valid=%u type=%s excl=0x%08lX shared=0x%08lX\n",
           tag, ch, rate, container, valid, isFloat ? "float" : "pcm",
           (unsigned long)hrE, (unsigned long)hrS);
    fflush(stdout);
}

int main(int argc, char** argv) {
    std::wstring needle = L"AuraVAIO";
    if (argc >= 2) {
        std::string a = argv[1];
        needle.assign(a.begin(), a.end());
    }
    CoInitialize(nullptr);
    IMMDeviceEnumerator* en = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator), (void**)&en)) || !en) {
        printf("enumerator failed\n");
        return 1;
    }
    IMMDeviceCollection* col = nullptr;
    en->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &col);
    IMMDevice* dev = nullptr;
    UINT n = 0;
    col->GetCount(&n);
    for (UINT i = 0; i < n && !dev; ++i) {
        IMMDevice* d = nullptr;
        if (FAILED(col->Item(i, &d)) || !d) continue;
        IPropertyStore* ps = nullptr;
        if (SUCCEEDED(d->OpenPropertyStore(STGM_READ, &ps)) && ps) {
            PROPVARIANT v;
            PropVariantInit(&v);
            if (SUCCEEDED(ps->GetValue(PKEY_Device_FriendlyName, &v)) &&
                v.vt == VT_LPWSTR && v.pwszVal &&
                wcsstr(v.pwszVal, needle.c_str())) {
                dev = d;
            }
            PropVariantClear(&v);
            ps->Release();
        }
        if (!dev) d->Release();
    }
    if (!dev) {
        printf("endpoint not found\n");
        return 2;
    }
    IAudioClient* client = nullptr;
    if (FAILED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                             (void**)&client)) || !client) {
        printf("activate failed\n");
        return 3;
    }
    TestOne(client, "ctl_f32_2",   2, 48000, 32, 32, true,  KSAUDIO_SPEAKER_STEREO);
    TestOne(client, "ctl_pcm16_2", 2, 48000, 16, 16, false, KSAUDIO_SPEAKER_STEREO);
    TestOne(client, "in32_2_48",   2, 48000, 32, 24, false, KSAUDIO_SPEAKER_STEREO);
    TestOne(client, "in32_2_96",   2, 96000, 32, 24, false, KSAUDIO_SPEAKER_STEREO);
    TestOne(client, "in32_2_192",  2, 192000, 32, 24, false, KSAUDIO_SPEAKER_STEREO);
    TestOne(client, "int32_2_48",  2, 48000, 32, 32, false, KSAUDIO_SPEAKER_STEREO);
    TestOne(client, "p20_2_48",    2, 48000, 32, 20, false, KSAUDIO_SPEAKER_STEREO);
    TestOne(client, "p24_2_44",    2, 44100, 24, 24, false, KSAUDIO_SPEAKER_STEREO);
    TestOne(client, "p24_2_48",    2, 48000, 24, 24, false, KSAUDIO_SPEAKER_STEREO);
    TestOne(client, "in32_6_48",   6, 48000, 32, 24, false, KSAUDIO_SPEAKER_5POINT1_SURROUND);
    TestOne(client, "p24_6_48",    6, 48000, 24, 24, false, KSAUDIO_SPEAKER_5POINT1_SURROUND);
    TestOne(client, "in32_8_48",   8, 48000, 32, 24, false, KSAUDIO_SPEAKER_7POINT1_SURROUND);
    client->Release();
    dev->Release();
    col->Release();
    en->Release();
    return 0;
}
