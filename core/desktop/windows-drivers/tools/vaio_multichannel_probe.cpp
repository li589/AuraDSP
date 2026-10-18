// vaio_multichannel_probe.cpp — 端到端验证 AuraVAIO 多声道格式支持与扬声器配置向导属性
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <propsys.h>
#include <propkey.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <setupapi.h>
#include <cstdio>
#include <vector>
#include <string>
#include "../common/AuraVaioIpc.h"

#pragma comment(lib, "setupapi.lib")

// PKEY_AudioEndpoint_PhysicalSpeakers = "{1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E},3"
static const PROPERTYKEY PKEY_PhysicalSpeakers = {
    {0x1DA5D803, 0xD492, 0x4EDD, {0x8C, 0x23, 0xE0, 0xC0, 0xFF, 0xEE, 0x7F, 0x0E}}, 3
};

void TestTopologyDirectKS() {
    printf("\n================ 拓扑驱动 KSPROPERTY_AUDIO_CHANNEL_CONFIG 测试 ================\n");
    HDEVINFO hDevInfo = SetupDiGetClassDevsW(&KSCATEGORY_TOPOLOGY, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (hDevInfo == INVALID_HANDLE_VALUE) {
        printf("[-] SetupDiGetClassDevsW 失败: %lu\n", GetLastError());
        return;
    }

    SP_DEVICE_INTERFACE_DATA ifData = {sizeof(SP_DEVICE_INTERFACE_DATA)};
    bool found = false;
    for (DWORD i = 0; SetupDiEnumDeviceInterfaces(hDevInfo, nullptr, &KSCATEGORY_TOPOLOGY, i, &ifData); ++i) {
        DWORD reqSize = 0;
        SetupDiGetDeviceInterfaceDetailW(hDevInfo, &ifData, nullptr, 0, &reqSize, nullptr);
        if (reqSize == 0) continue;

        std::vector<BYTE> buf(reqSize);
        PSP_DEVICE_INTERFACE_DETAIL_DATA_W detail = (PSP_DEVICE_INTERFACE_DETAIL_DATA_W)buf.data();
        detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);

        if (SetupDiGetDeviceInterfaceDetailW(hDevInfo, &ifData, detail, reqSize, nullptr, nullptr)) {
            if (wcsstr(detail->DevicePath, L"root#media") != nullptr || wcsstr(detail->DevicePath, L"ROOT#MEDIA") != nullptr) {
                printf("[+] 发现 AuraVAIO 拓扑设备接口: %ls\n", detail->DevicePath);
                found = true;

                HANDLE hDev = CreateFileW(detail->DevicePath, GENERIC_READ | GENERIC_WRITE,
                                          FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                          OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
                if (hDev == INVALID_HANDLE_VALUE) {
                    printf("[-] 打开设备失败, GetLastError=%lu\n", GetLastError());
                    break;
                }

                static const GUID GUID_KSPROPSETID_Audio =
                    { 0x45FFAAA0L, 0x6E1B, 0x11D0, { 0xBC, 0xF2, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00 } };
                static const GUID GUID_KSPROPSETID_Pin =
                    { 0x8C134960L, 0x51AD, 0x11CF, { 0x87, 0x8A, 0x94, 0xF8, 0x01, 0xC1, 0x00, 0x00 } };

                // 0. 测试 Pin 基础枚举 (KSPROPERTY_PIN_CTYPES = 1)
                KSPROPERTY pinProp = {0};
                pinProp.Set = GUID_KSPROPSETID_Pin;
                pinProp.Id = 1; // KSPROPERTY_PIN_CTYPES
                pinProp.Flags = KSPROPERTY_TYPE_GET;
                ULONG pinCount = 0;
                DWORD pinRet = 0;
                BOOL pinOk = DeviceIoControl(hDev, IOCTL_KS_PROPERTY, &pinProp, sizeof(pinProp),
                                             &pinCount, sizeof(pinCount), &pinRet, nullptr);
                printf("  -> [Filter Pin Count (KSPROPERTY_PIN_CTYPES)]: %s (PinCount=%lu, LastError=%lu)\n",
                       pinOk ? "SUCCESS" : "FAILED", pinCount, GetLastError());

                // 1. 测试 Filter 级 BASICSUPPORT
                KSPROPERTY prop = {0};
                prop.Set = GUID_KSPROPSETID_Audio;
                prop.Id = KSPROPERTY_AUDIO_CHANNEL_CONFIG;
                prop.Flags = KSPROPERTY_TYPE_BASICSUPPORT;

                BYTE descBuf[128] = {0};
                DWORD bytesRet = 0;
                BOOL ok = DeviceIoControl(hDev, IOCTL_KS_PROPERTY, &prop, sizeof(prop),
                                          descBuf, sizeof(descBuf), &bytesRet, nullptr);
                ULONG flags = *(ULONG*)descBuf;
                printf("  -> [Filter BASICSUPPORT]: %s (SupportFlags=0x%08lX, LastError=%lu)\n", ok ? "SUCCESS" : "FAILED", flags, GetLastError());

                // 2. 测试 Pin 1 (Speaker) 级 BASICSUPPORT (KSP_PIN)
                struct KSP_PIN_REQ {
                    KSPROPERTY Property;
                    ULONG      PinId;
                    ULONG      Reserved;
                } pinReq = {0};
                pinReq.Property.Set = GUID_KSPROPSETID_Audio;
                pinReq.Property.Id = KSPROPERTY_AUDIO_CHANNEL_CONFIG;
                pinReq.Property.Flags = KSPROPERTY_TYPE_BASICSUPPORT;
                pinReq.PinId = 1; // KSPIN_TOPO_SPEAKER

                memset(descBuf, 0, sizeof(descBuf));
                ok = DeviceIoControl(hDev, IOCTL_KS_PROPERTY, &pinReq, sizeof(pinReq),
                                     descBuf, sizeof(descBuf), &bytesRet, nullptr);
                flags = *(ULONG*)descBuf;
                printf("  -> [Pin 1 BASICSUPPORT]: %s (SupportFlags=0x%08lX, LastError=%lu)\n", ok ? "SUCCESS" : "FAILED", flags, GetLastError());

                // 3. 测试 GET (Filter 级)
                prop.Flags = KSPROPERTY_TYPE_GET;
                KSAUDIO_CHANNEL_CONFIG config = {0};
                ok = DeviceIoControl(hDev, IOCTL_KS_PROPERTY, &prop, sizeof(prop),
                                     &config, sizeof(config), &bytesRet, nullptr);
                if (!ok) {
                    // 尝试 Pin 1 级 GET
                    pinReq.Property.Flags = KSPROPERTY_TYPE_GET;
                    ok = DeviceIoControl(hDev, IOCTL_KS_PROPERTY, &pinReq, sizeof(pinReq),
                                         &config, sizeof(config), &bytesRet, nullptr);
                    printf("  -> [Pin 1 GET ChannelConfig]: %s (ActiveSpeakerPositions=0x%08lX, LastError=%lu)\n",
                           ok ? "SUCCESS" : "FAILED", config.ActiveSpeakerPositions, GetLastError());
                } else {
                    printf("  -> [Filter GET ChannelConfig]: %s (ActiveSpeakerPositions=0x%08lX)\n",
                           ok ? "SUCCESS" : "FAILED", config.ActiveSpeakerPositions);
                }

                // 4. 测试 SET (设置为 0x33 Quad)
                prop.Flags = KSPROPERTY_TYPE_SET;
                config.ActiveSpeakerPositions = KSAUDIO_SPEAKER_QUAD; // 0x33
                ok = DeviceIoControl(hDev, IOCTL_KS_PROPERTY, &prop, sizeof(prop),
                                     &config, sizeof(config), &bytesRet, nullptr);
                if (!ok) {
                    pinReq.Property.Flags = KSPROPERTY_TYPE_SET;
                    ok = DeviceIoControl(hDev, IOCTL_KS_PROPERTY, &pinReq, sizeof(pinReq),
                                         &config, sizeof(config), &bytesRet, nullptr);
                    printf("  -> [Pin 1 SET ChannelConfig -> Quad 0x33]: %s (LastError=%lu)\n", ok ? "SUCCESS" : "FAILED", GetLastError());
                } else {
                    printf("  -> [Filter SET ChannelConfig -> Quad 0x33]: %s\n", ok ? "SUCCESS" : "FAILED");
                }

                // 5. 恢复为 7.1 (0x63F)
                prop.Flags = KSPROPERTY_TYPE_SET;
                config.ActiveSpeakerPositions = KSAUDIO_SPEAKER_7POINT1_SURROUND; // 0x63F
                ok = DeviceIoControl(hDev, IOCTL_KS_PROPERTY, &prop, sizeof(prop),
                                     &config, sizeof(config), &bytesRet, nullptr);
                if (!ok) {
                    pinReq.Property.Flags = KSPROPERTY_TYPE_SET;
                    ok = DeviceIoControl(hDev, IOCTL_KS_PROPERTY, &pinReq, sizeof(pinReq),
                                         &config, sizeof(config), &bytesRet, nullptr);
                    printf("  -> [Pin 1 RESTORE SET -> 7.1 0x63F]: %s\n", ok ? "SUCCESS" : "FAILED");
                } else {
                    printf("  -> [Filter RESTORE SET -> 7.1 0x63F]: %s\n", ok ? "SUCCESS" : "FAILED");
                }

                CloseHandle(hDev);
                break;
            }
        }
    }

    SetupDiDestroyDeviceInfoList(hDevInfo);
    if (!found) {
        printf("[-] 未枚举到 AuraVAIO 拓扑设备接口\n");
    }
}

void TestFormat(IAudioClient* pClient, const char* label, WORD channels, DWORD sampleRate, WORD bits, DWORD channelMask, bool isFloat) {
    WAVEFORMATEXTENSIBLE wfe = {0};
    wfe.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wfe.Format.nChannels = channels;
    wfe.Format.nSamplesPerSec = sampleRate;
    wfe.Format.wBitsPerSample = bits;
    wfe.Format.nBlockAlign = (channels * bits) / 8;
    wfe.Format.nAvgBytesPerSec = wfe.Format.nSamplesPerSec * wfe.Format.nBlockAlign;
    wfe.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wfe.Samples.wValidBitsPerSample = bits;
    wfe.dwChannelMask = channelMask;
    wfe.SubFormat = isFloat ? KSDATAFORMAT_SUBTYPE_IEEE_FLOAT : KSDATAFORMAT_SUBTYPE_PCM;

    WAVEFORMATEX* pClosest = nullptr;
    HRESULT hrShared = pClient->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED, (WAVEFORMATEX*)&wfe, &pClosest);
    HRESULT hrExcl = pClient->IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, (WAVEFORMATEX*)&wfe, nullptr);

    if (hrExcl != S_OK && channels == 2) {
        WAVEFORMATEX wfx = {0};
        wfx.wFormatTag = isFloat ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM;
        wfx.nChannels = channels;
        wfx.nSamplesPerSec = sampleRate;
        wfx.wBitsPerSample = bits;
        wfx.nBlockAlign = (channels * bits) / 8;
        wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;
        wfx.cbSize = 0;
        HRESULT hrStd = pClient->IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, &wfx, nullptr);
        if (hrStd == S_OK) {
            hrExcl = hrStd;
        }
    }

    const char* strShared = "UNKNOWN";
    if (hrShared == S_OK) strShared = "OK (Supported)";
    else if (hrShared == S_FALSE) strShared = "S_FALSE (Match with suggestion)";
    else if (hrShared == AUDCLNT_E_UNSUPPORTED_FORMAT) strShared = "UNSUPPORTED";
    else strShared = "FAILED";

    const char* strExcl = "UNKNOWN";
    if (hrExcl == S_OK) strExcl = "OK (Supported)";
    else if (hrExcl == AUDCLNT_E_UNSUPPORTED_FORMAT) strExcl = "UNSUPPORTED";
    else strExcl = "FAILED";

    printf("  [%-20s] %dch %ukHz %ubit %s (mask=0x%03X): Shared=%s, Exclusive=%s (0x%08lX)\n",
           label, channels, sampleRate / 1000, bits, isFloat ? "Float" : "PCM  ", channelMask,
           strShared, strExcl, hrExcl);

    if (pClosest) {
        CoTaskMemFree(pClosest);
    }
}

int main() {
    CoInitialize(nullptr);
    printf("============================================================\n");
    printf("        AuraVAIO 多声道能力与扬声器向导端到端真实测试        \n");
    printf("============================================================\n\n");

    IMMDeviceEnumerator* pEnum = nullptr;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                  __uuidof(IMMDeviceEnumerator), (void**)&pEnum);
    if (FAILED(hr) || !pEnum) {
        printf("[-] CoCreateInstance MMDeviceEnumerator 失败: 0x%08lX\n", hr);
        return 1;
    }

    IMMDeviceCollection* pCol = nullptr;
    hr = pEnum->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &pCol);
    if (FAILED(hr) || !pCol) {
        printf("[-] EnumAudioEndpoints 失败: 0x%08lX\n", hr);
        pEnum->Release();
        return 1;
    }

    UINT count = 0;
    pCol->GetCount(&count);
    IMMDevice* pVaioDev = nullptr;

    for (UINT i = 0; i < count; ++i) {
        IMMDevice* pDev = nullptr;
        if (FAILED(pCol->Item(i, &pDev)) || !pDev) continue;

        IPropertyStore* pProp = nullptr;
        if (SUCCEEDED(pDev->OpenPropertyStore(STGM_READ, &pProp)) && pProp) {
            PROPVARIANT varName;
            PropVariantInit(&varName);
            if (SUCCEEDED(pProp->GetValue(PKEY_Device_FriendlyName, &varName)) && varName.pwszVal) {
                if (wcsstr(varName.pwszVal, L"AuraVAIO") != nullptr) {
                    pVaioDev = pDev;
                    printf("[+] 发现目标渲染端点: %ls\n", varName.pwszVal);

                    PROPVARIANT varSpeakers;
                    PropVariantInit(&varSpeakers);
                    if (SUCCEEDED(pProp->GetValue(PKEY_PhysicalSpeakers, &varSpeakers)) && varSpeakers.vt == VT_UI4) {
                        printf("    -> 物理扬声器掩码 (PhysicalSpeakers): 0x%08lX (十进制 %lu)\n",
                               varSpeakers.ulVal, varSpeakers.ulVal);
                        if (varSpeakers.ulVal == 0x63F) {
                            printf("       [PASS] 成功识别 7.1 Surround 物理物理扬声器预设 (0x63F)!\n");
                        } else {
                            printf("       [INFO] 物理物理扬声器掩码当前为: 0x%lX\n", varSpeakers.ulVal);
                        }
                    } else {
                        printf("    -> 物理扬声器掩码: 未直接在端点属性暴露（由拓扑驱动实时提供）\n");
                    }
                    PropVariantClear(&varSpeakers);
                }
            }
            PropVariantClear(&varName);
            pProp->Release();
        }

        if (pVaioDev) break;
        pDev->Release();
    }

    pCol->Release();

    if (!pVaioDev) {
        printf("[-] 未在系统中找到活跃的 AuraVAIO 渲染端点！\n");
        pEnum->Release();
        return 2;
    }

    IAudioClient* pClient = nullptr;
    hr = pVaioDev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&pClient);
    if (FAILED(hr) || !pClient) {
        printf("[-] 激活 IAudioClient 失败: 0x%08lX\n", hr);
        pVaioDev->Release();
        pEnum->Release();
        return 3;
    }

    WAVEFORMATEX* pMix = nullptr;
    if (SUCCEEDED(pClient->GetMixFormat(&pMix)) && pMix) {
        printf("[+] 当前系统共享混音格式 (MixFormat): %dch, %luHz, %ubits\n\n",
               pMix->nChannels, pMix->nSamplesPerSec, pMix->wBitsPerSample);
        CoTaskMemFree(pMix);
    }

    printf("================ 驱动层音频流格式支持矩阵测试 ================\n");
    TestFormat(pClient, "Stereo 2.0 (48k)", 2, 48000, 32, KSAUDIO_SPEAKER_STEREO, true);
    TestFormat(pClient, "Stereo 2.0 (44.1k)", 2, 44100, 32, KSAUDIO_SPEAKER_STEREO, true);
    TestFormat(pClient, "Stereo 2.0 (PCM16)", 2, 48000, 16, KSAUDIO_SPEAKER_STEREO, false);

    TestFormat(pClient, "Quad 4.0 (48k)", 4, 48000, 32, KSAUDIO_SPEAKER_QUAD, true);
    TestFormat(pClient, "Quad 4.0 (PCM16)", 4, 48000, 16, KSAUDIO_SPEAKER_QUAD, false);

    TestFormat(pClient, "5.1 Surround (48k)", 6, 48000, 32, KSAUDIO_SPEAKER_5POINT1_SURROUND, true);
    TestFormat(pClient, "5.1 Traditional", 6, 48000, 32, KSAUDIO_SPEAKER_5POINT1, true);
    TestFormat(pClient, "5.1 Surround (PCM16)", 6, 48000, 16, KSAUDIO_SPEAKER_5POINT1_SURROUND, false);

    TestFormat(pClient, "7.1 Surround (48k)", 8, 48000, 32, KSAUDIO_SPEAKER_7POINT1_SURROUND, true);
    TestFormat(pClient, "7.1 Surround (96k)", 8, 96000, 32, KSAUDIO_SPEAKER_7POINT1_SURROUND, true);
    TestFormat(pClient, "7.1 Surround (PCM16)", 8, 48000, 16, KSAUDIO_SPEAKER_7POINT1_SURROUND, false);
    printf("============================================================\n");

    HANDLE hControl = CreateFileW(L"\\\\.\\AuraVaioControl", GENERIC_READ | GENERIC_WRITE,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                  OPEN_EXISTING, 0, nullptr);
    if (hControl == INVALID_HANDLE_VALUE) {
        printf("[-] 打开 \\\\.\\AuraVaioControl 失败, LastError=%lu\n", GetLastError());
    } else {
        AURA_DEBUG_LOG debugLog = {0};
        DWORD retBytes = 0;
        if (DeviceIoControl(hControl, IOCTL_AURAVAIO_GET_DEBUG_LOG, nullptr, 0,
                            &debugLog, sizeof(debugLog), &retBytes, nullptr)) {
            printf("\n================ 驱动层 DataRangeIntersection 诊断日志 (共 %lu 条) ================\n", debugLog.Count);
            for (ULONG i = 0; i < debugLog.Count; ++i) {
                const auto& e = debugLog.Entries[i];
                printf("  [%2lu] Pin=%lu, Status=0x%08lX, InBufSize=%lu, OutBufLen=%lu, FormatSize=%lu\n",
                       i, e.PinId, e.Status, e.FormatSize, e.OutputBufferLength, e.FormatSize);
                printf("       Client: reqCh=%lu, reqBits=%lu, reqRate=%lu, mask=0x%03lX\n",
                       e.ExtraChannels, e.ExtraBits, e.ExtraSampleRate, e.ExtraChannelMask);
                printf("       ClientSubFormat: {%08lX-%04X-%04X...}, Specifier: {%08lX...}\n",
                       e.SubFormat.Data1, e.SubFormat.Data2, e.SubFormat.Data3, e.Specifier.Data1);
                printf("       MyRange: maxCh=%lu, maxBits=%lu, maxRate=%lu, SubFormat: {%08lX...}\n",
                       e.MyMaxChannels, e.MyMaxBits, e.MyMaxSampleRate, e.MySubFormat.Data1);
            }
            printf("====================================================================================\n\n");
        } else {
            printf("[-] DeviceIoControl IOCTL_AURAVAIO_GET_DEBUG_LOG 失败, LastError=%lu\n", GetLastError());
        }
        CloseHandle(hControl);
    }

    // 测试拓扑驱动 ChannelConfig
    TestTopologyDirectKS();

    pClient->Release();
    pVaioDev->Release();
    pEnum->Release();
    CoUninitialize();
    return 0;
}
