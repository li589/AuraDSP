// VaioBridge.cpp — AuraVAIO 虚拟声卡模式持久桥实现。
//
// 架构遵循 SPEC-WIN-DRIVER-001：
// - 驱动仅搬运字节与管理时间戳，零 DSP 滤波；所有 21 项 DSP 音效完全由 auradsp_engine.dll 承担。
// - 本桥为用户态桥梁，从内核共享环形缓冲（\\.\AuraVaioControl）映射读出第三方应用发给虚拟声卡的音频流，
//   经 auradsp_process 处理后，输出到 WASAPI 物理音频设备（扬声器/耳机），同时可写回采集流。
// - RT 铁律：音频泵循环内严格零动态内存分配、零内核锁、零文件 I/O。
// - 控制面（detect/start/stop/set_param/status/viz）在 Dart isolate 或控制线程执行。
#include "VaioBridge.h"

#include <windows.h>
#include <winioctl.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <propkey.h>
#include <functiondiscoverykeys_devpkey.h>
#include <avrt.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../../common/AuraVaioIpc.h"
#include "../../02_voicemeeter_client/VmPumpCore.h"

namespace {

// JSON 路径转义
void PathForJson(const std::wstring& in, char* out, size_t cap) {
    size_t j = 0;
    for (size_t i = 0; i < in.size() && j + 1 < cap; ++i) {
        const wchar_t c = in[i];
        out[j++] = (c == L'\\') ? '/' : (char)c;
    }
    out[j] = '\0';
}

void PathForJsonA(const std::string& in, char* out, size_t cap) {
    size_t j = 0;
    for (size_t i = 0; i < in.size() && j + 1 < cap; ++i) {
        const char c = in[i];
        out[j++] = (c == '\\') ? '/' : c;
    }
    out[j] = '\0';
}

std::string WideToUtf8(const wchar_t* w) {
    if (!w || !*w) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return {};
    std::string s((size_t)n - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
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

using vmcore::FnEngCreate;
using vmcore::FnEngDestroy;
using vmcore::FnEngGetParam;
using vmcore::FnEngProcess;
using vmcore::FnEngSetParam;
using vmcore::FnEngVizRead;
using vmcore::PumpCtx;

// 参数镜像（应对采样率变化或设备切换后重放）
constexpr int kMirrorMax = 512;
struct MirrorEnt {
    char id[64];
    bool isFloat;
    float f;
    int32_t i;
};

struct MirrorStrEnt {
    char id[64];
    std::string val;
};

MirrorEnt g_mirror[kMirrorMax];
int g_mirrorN = 0;
std::vector<MirrorStrEnt> g_strMirror;
CRITICAL_SECTION g_mirrorCs;
bool g_mirrorCsInit = false;

void InitMirrorCs() {
    if (!g_mirrorCsInit) {
        InitializeCriticalSection(&g_mirrorCs);
        g_mirrorCsInit = true;
    }
}

void MirrorSet(const char* id, bool isFloat, const void* v4) {
    if (!id || !v4) return;
    InitMirrorCs();
    EnterCriticalSection(&g_mirrorCs);
    for (int i = 0; i < g_mirrorN; ++i) {
        if (strcmp(g_mirror[i].id, id) == 0) {
            g_mirror[i].isFloat = isFloat;
            if (isFloat) g_mirror[i].f = *(const float*)v4;
            else g_mirror[i].i = *(const int32_t*)v4;
            LeaveCriticalSection(&g_mirrorCs);
            return;
        }
    }
    if (g_mirrorN < kMirrorMax) {
        MirrorEnt* e = &g_mirror[g_mirrorN++];
        strncpy_s(e->id, id, sizeof(e->id) - 1);
        e->isFloat = isFloat;
        if (isFloat) e->f = *(const float*)v4;
        else e->i = *(const int32_t*)v4;
    }
    LeaveCriticalSection(&g_mirrorCs);
}

void MirrorSetStr(const char* id, const char* utf8, int bytes) {
    if (!id || !utf8 || bytes < 0) return;
    InitMirrorCs();
    EnterCriticalSection(&g_mirrorCs);
    for (auto& e : g_strMirror) {
        if (strcmp(e.id, id) == 0) {
            e.val.assign(utf8, (size_t)bytes);
            LeaveCriticalSection(&g_mirrorCs);
            return;
        }
    }
    MirrorStrEnt ent;
    strncpy_s(ent.id, id, sizeof(ent.id) - 1);
    ent.val.assign(utf8, (size_t)bytes);
    g_strMirror.push_back(std::move(ent));
    LeaveCriticalSection(&g_mirrorCs);
}

// 桥控制器单例结构
struct VaioBridgeCtl {
    // 驱动控制设备与共享环
    HANDLE hControlDev = INVALID_HANDLE_VALUE;
    PVOID pMappedRing = nullptr;
    volatile PAURA_VAIO_SHARED_HEADER pRingHeader = nullptr;
    BYTE* pRingPayload = nullptr;
    ULONG ringDataSize = 0;
    ULONG ringChannels = 2;
    ULONG ringSampleRate = 48000;
    ULONG ringBlockAlign = 8;
    ULONG ringBits = 32;

    // 引擎 (auradsp_engine.dll)
    HMODULE hEngineMod = nullptr;
    FnEngCreate fnCreate = nullptr;
    FnEngProcess fnProcess = nullptr;
    FnEngDestroy fnDestroy = nullptr;
    FnEngSetParam fnSetParam = nullptr;
    FnEngGetParam fnGetParam = nullptr;
    FnEngVizRead fnVizRead = nullptr;
    void* pEngine = nullptr;
    std::wstring enginePath;

    // WASAPI 物理输出
    IMMDeviceEnumerator* pEnum = nullptr;
    IMMDevice* pOutDevice = nullptr;
    IAudioClient* pAudioClient = nullptr;
    IAudioRenderClient* pRenderClient = nullptr;
    WAVEFORMATEX* pMixFormat = nullptr;
    std::string outEndpointName;
    UINT32 wasapiBufferFrames = 0;
    UINT32 wasapiChannels = 2;
    UINT32 wasapiSampleRate = 48000;

    // 预分配 RT 临时缓冲 (最大 4096 帧 * 8 声道 float32)
    static constexpr int kMaxFrames = 4096;
    float* scratchIn = nullptr;
    float* scratchOut = nullptr;

    // 运行态与 RT 统计
    HANDLE hPumpThread = nullptr;
    volatile LONG running = 0;
    volatile LONG stopEvent = 0;
    volatile LONG userBypass = 0;

    uint64_t totalPumpedFrames = 0;
    double peakIn = 0.0;
    double peakOut = 0.0;
    double maxPumpUs = 0.0;
    int startRc = -99;
    char note[128] = {};
    int paramsApplied = 0;
    int paramsFailed = 0;

    // 测试注入
    PumpCtx tc;
};

VaioBridgeCtl g_vaio;

void FreeTestFile() {
    InterlockedExchange(&g_vaio.tc.testKind, 0);
    Sleep(50);
    if (g_vaio.tc.testFile) {
        free((void*)g_vaio.tc.testFile);
        g_vaio.tc.testFile = nullptr;
    }
    g_vaio.tc.testFrames = 0;
    g_vaio.tc.testPos = 0;
}

void DestroyEngine() {
    if (g_vaio.pEngine && g_vaio.fnDestroy) {
        g_vaio.fnDestroy(g_vaio.pEngine);
    }
    g_vaio.pEngine = nullptr;
    if (g_vaio.hEngineMod) {
        FreeLibrary(g_vaio.hEngineMod);
        g_vaio.hEngineMod = nullptr;
    }
    g_vaio.fnCreate = nullptr;
    g_vaio.fnProcess = nullptr;
    g_vaio.fnDestroy = nullptr;
    g_vaio.fnSetParam = nullptr;
    g_vaio.fnGetParam = nullptr;
    g_vaio.fnVizRead = nullptr;
    g_vaio.enginePath.clear();
}

void DestroyWasapi() {
    if (g_vaio.pAudioClient) {
        g_vaio.pAudioClient->Stop();
    }
    if (g_vaio.pRenderClient) {
        g_vaio.pRenderClient->Release();
        g_vaio.pRenderClient = nullptr;
    }
    if (g_vaio.pAudioClient) {
        g_vaio.pAudioClient->Release();
        g_vaio.pAudioClient = nullptr;
    }
    if (g_vaio.pMixFormat) {
        CoTaskMemFree(g_vaio.pMixFormat);
        g_vaio.pMixFormat = nullptr;
    }
    if (g_vaio.pOutDevice) {
        g_vaio.pOutDevice->Release();
        g_vaio.pOutDevice = nullptr;
    }
    if (g_vaio.pEnum) {
        g_vaio.pEnum->Release();
        g_vaio.pEnum = nullptr;
    }
    CoUninitialize();
}

void UnmapAndCloseRing() {
    if (g_vaio.hControlDev != INVALID_HANDLE_VALUE) {
        if (g_vaio.pMappedRing != nullptr) {
            AURA_VAIO_UNMAP_REQUEST unmapReq = {0};
            unmapReq.UserAddress = g_vaio.pMappedRing;
            DWORD bytesRet = 0;
            DeviceIoControl(
                g_vaio.hControlDev,
                IOCTL_AURAVAIO_UNMAP_SHARED_RING,
                &unmapReq, sizeof(unmapReq),
                nullptr, 0,
                &bytesRet,
                nullptr
            );
            g_vaio.pMappedRing = nullptr;
            g_vaio.pRingHeader = nullptr;
            g_vaio.pRingPayload = nullptr;
        }
        CloseHandle(g_vaio.hControlDev);
        g_vaio.hControlDev = INVALID_HANDLE_VALUE;
    }
}

void FreeScratchBuffers() {
    if (g_vaio.scratchIn) {
        free(g_vaio.scratchIn);
        g_vaio.scratchIn = nullptr;
    }
    if (g_vaio.scratchOut) {
        free(g_vaio.scratchOut);
        g_vaio.scratchOut = nullptr;
    }
}

void ReplayMirroredParams() {
    if (!g_vaio.pEngine || !g_vaio.fnSetParam) return;
    InitMirrorCs();
    EnterCriticalSection(&g_mirrorCs);
    for (int i = 0; i < g_mirrorN; ++i) {
        const MirrorEnt& e = g_mirror[i];
        const void* v = e.isFloat ? (const void*)&e.f : (const void*)&e.i;
        g_vaio.fnSetParam(g_vaio.pEngine, e.id, v, 4);
    }
    for (const auto& s : g_strMirror) {
        g_vaio.fnSetParam(g_vaio.pEngine, s.id, s.val.data(), (unsigned int)s.val.size());
    }
    LeaveCriticalSection(&g_mirrorCs);
}

void ApplyParamsString(const char* s) {
    if (!s || !*s || !g_vaio.pEngine || !g_vaio.fnSetParam) return;
    char buf[4096] = {0};
    strncpy_s(buf, s, sizeof(buf) - 1);
    for (char* tok = strtok(buf, ";"); tok != nullptr; tok = strtok(nullptr, ";")) {
        char* eq = strchr(tok, '=');
        if (!eq || eq == tok) {
            ++g_vaio.paramsFailed;
            continue;
        }
        *eq = '\0';
        const char* id = tok;
        const char* vs = eq + 1;
        if (strchr(vs, '.') || strchr(vs, 'e') || strchr(vs, 'E')) {
            const float f = (float)atof(vs);
            MirrorSet(id, true, &f);
            if (g_vaio.fnSetParam(g_vaio.pEngine, id, &f, 4) != 0) {
                ++g_vaio.paramsFailed;
            } else {
                ++g_vaio.paramsApplied;
            }
        } else {
            const int32_t iv = (int32_t)atoi(vs);
            MirrorSet(id, false, &iv);
            if (g_vaio.fnSetParam(g_vaio.pEngine, id, &iv, 4) != 0) {
                ++g_vaio.paramsFailed;
            } else {
                ++g_vaio.paramsApplied;
            }
        }
    }
}

// RT 专用线程：零锁零分配音频泵
DWORD WINAPI VaioPumpThreadProc(LPVOID) {
    // 注册 MMCSS Pro Audio 优先级调度
    DWORD taskIndex = 0;
    HANDLE hMmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);

    LARGE_INTEGER qpcFreq;
    QueryPerformanceFrequency(&qpcFreq);
    const double qpcToUs = 1000000.0 / (double)qpcFreq.QuadPart;

    volatile PAURA_VAIO_SHARED_HEADER pHeader = g_vaio.pRingHeader;
    const ULONG dataSize = g_vaio.ringDataSize;
    const ULONG blockAlign = g_vaio.ringBlockAlign > 0 ? g_vaio.ringBlockAlign : 8;
    const ULONG ringChannels = g_vaio.ringChannels > 0 ? g_vaio.ringChannels : 2;
    const ULONG wasapiChannels = g_vaio.wasapiChannels > 0 ? g_vaio.wasapiChannels : 2;
    BYTE* const pPayload = g_vaio.pRingPayload;

    // 初始消费指针与内核当前写入位置对齐（避免刚开机把陈旧噪底播出来）
    ULONGLONG userBytesRead = pHeader ? pHeader->TotalBytesWritten : 0;

    // 启动 WASAPI 播放
    g_vaio.pAudioClient->Start();

    while (!InterlockedCompareExchange(&g_vaio.stopEvent, 0, 0)) {
        UINT32 padFrames = 0;
        HRESULT hr = g_vaio.pAudioClient->GetCurrentPadding(&padFrames);
        if (FAILED(hr)) {
            Sleep(2);
            continue;
        }

        UINT32 framesNeeded = g_vaio.wasapiBufferFrames > padFrames
                                  ? (g_vaio.wasapiBufferFrames - padFrames)
                                  : 0;

        if (framesNeeded == 0) {
            Sleep(1);
            continue;
        }

        // 单次处理块上限钳制在 512 帧，防止突发大块拉高瞬时延迟
        UINT32 framesToProcess = (framesNeeded > 512) ? 512 : framesNeeded;
        if (framesToProcess > (UINT32)VaioBridgeCtl::kMaxFrames) {
            framesToProcess = (UINT32)VaioBridgeCtl::kMaxFrames;
        }

        const ULONG bytesToRead = framesToProcess * blockAlign;

        // 检查共享环是否有有效数据
        ULONGLONG totalWritten = pHeader ? pHeader->TotalBytesWritten : 0;
        ULONGLONG availBytes = 0;
        if (totalWritten > userBytesRead) {
            availBytes = totalWritten - userBytesRead;
            // 环形缓冲覆写超载处理：若落后超过一整圈，强制跟进到最新一圈头部
            if (availBytes > (ULONGLONG)dataSize) {
                availBytes = (ULONGLONG)dataSize;
                userBytesRead = totalWritten - availBytes;
            }
        }

        // 测试信号注入面（优先覆盖真实输入）
        if (g_vaio.tc.testKind != 0) {
            vmcore::FillTestSignal(&g_vaio.tc, g_vaio.scratchIn, (int)framesToProcess);
            // 测试注入时，虚拟声卡输入的音频同步步进丢弃，保持时序不滞后
            if (availBytes >= bytesToRead) {
                userBytesRead += bytesToRead;
            }
        } else if (availBytes >= bytesToRead && pPayload && dataSize > 0) {
            // 从共享内存循环队列读取渲染样本
            ULONG readOffset = (ULONG)(userBytesRead % dataSize);
            ULONG chunk1 = dataSize - readOffset;
            if (chunk1 >= bytesToRead) {
                memcpy(g_vaio.scratchIn, pPayload + readOffset, bytesToRead);
            } else {
                ULONG chunk2 = bytesToRead - chunk1;
                memcpy(g_vaio.scratchIn, pPayload + readOffset, chunk1);
                memcpy((BYTE*)g_vaio.scratchIn + chunk1, pPayload, chunk2);
            }
            userBytesRead += bytesToRead;
        } else {
            // 无新音频或欠载：静音填充以维持 WASAPI 时钟平滑走动
            memset(g_vaio.scratchIn, 0, bytesToRead);
        }

        // DSP 音频处理与峰值计量
        LARGE_INTEGER t0, t1;
        QueryPerformanceCounter(&t0);

        // 计算输入峰值
        float curPeakIn = 0.0f;
        const int inSampleCount = (int)(framesToProcess * ringChannels);
        for (int s = 0; s < inSampleCount; ++s) {
            float val = fabsf(g_vaio.scratchIn[s]);
            if (val > curPeakIn) curPeakIn = val;
        }
        g_vaio.peakIn = (double)curPeakIn;

        if (g_vaio.userBypass) {
            // 用户旁路：直通，不跑 DSP
            memcpy(g_vaio.scratchOut, g_vaio.scratchIn, bytesToRead);
        } else if (g_vaio.pEngine && g_vaio.fnProcess) {
            // 21 项音效链处理（交织 float32）
            g_vaio.fnProcess(g_vaio.pEngine, g_vaio.scratchIn, g_vaio.scratchOut, (int)framesToProcess);
        } else {
            memcpy(g_vaio.scratchOut, g_vaio.scratchIn, bytesToRead);
        }

        // 计算输出峰值
        float curPeakOut = 0.0f;
        const int outSampleCount = (int)(framesToProcess * ringChannels);
        for (int s = 0; s < outSampleCount; ++s) {
            float val = fabsf(g_vaio.scratchOut[s]);
            if (val > curPeakOut) curPeakOut = val;
        }
        g_vaio.peakOut = (double)curPeakOut;

        QueryPerformanceCounter(&t1);
        double pumpUs = (double)(t1.QuadPart - t0.QuadPart) * qpcToUs;
        if (pumpUs > g_vaio.maxPumpUs) g_vaio.maxPumpUs = pumpUs;

        // 写入 WASAPI 物理输出缓冲区
        BYTE* pDst = nullptr;
        hr = g_vaio.pRenderClient->GetBuffer(framesToProcess, &pDst);
        if (SUCCEEDED(hr) && pDst) {
            if (wasapiChannels == ringChannels) {
                memcpy(pDst, g_vaio.scratchOut, bytesToRead);
            } else if (ringChannels == 2 && wasapiChannels > 2) {
                // 立体声映射到多声道（前左/前右，其余静音）
                float* pDstF = (float*)pDst;
                for (UINT32 f = 0; f < framesToProcess; ++f) {
                    pDstF[f * wasapiChannels + 0] = g_vaio.scratchOut[f * 2 + 0];
                    pDstF[f * wasapiChannels + 1] = g_vaio.scratchOut[f * 2 + 1];
                    for (UINT32 ch = 2; ch < wasapiChannels; ++ch) {
                        pDstF[f * wasapiChannels + ch] = 0.0f;
                    }
                }
            } else {
                memcpy(pDst, g_vaio.scratchOut, (size_t)framesToProcess * wasapiChannels * sizeof(float));
            }
            g_vaio.pRenderClient->ReleaseBuffer(framesToProcess, 0);
        }

        g_vaio.totalPumpedFrames += framesToProcess;
    }

    if (hMmcss) {
        AvRevertMmThreadCharacteristics(hMmcss);
    }
    return 0;
}

}  // namespace

int vaio_detect(char* out, int cap) {
    if (!out || cap <= 0) return -1;

    // 1. 尝试打开驱动控制设备
    HANDLE hDev = CreateFileW(
        AURA_VAIO_USER_DEVICE_PATH,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );

    bool driverFound = (hDev != INVALID_HANDLE_VALUE);
    AURA_VAIO_VERSION_INFO ver = {0};
    AURA_VAIO_STATUS_INFO st = {0};

    if (driverFound) {
        DWORD bytesRet = 0;
        DeviceIoControl(hDev, IOCTL_AURAVAIO_GET_VERSION, nullptr, 0, &ver, sizeof(ver), &bytesRet, nullptr);
        DeviceIoControl(hDev, IOCTL_AURAVAIO_GET_STATUS, nullptr, 0, &st, sizeof(st), &bytesRet, nullptr);
        CloseHandle(hDev);
    }

    // 2. 枚举 WASAPI 物理渲染端点
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IMMDeviceEnumerator* pEnum = nullptr;
    HRESULT hr = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator), (void**)&pEnum
    );

    std::vector<std::pair<std::string, std::string>> endpoints;
    if (SUCCEEDED(hr) && pEnum) {
        IMMDeviceCollection* pCol = nullptr;
        if (SUCCEEDED(pEnum->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &pCol)) && pCol) {
            UINT count = 0;
            pCol->GetCount(&count);
            for (UINT i = 0; i < count; ++i) {
                IMMDevice* pDev = nullptr;
                if (FAILED(pCol->Item(i, &pDev)) || !pDev) continue;

                std::string devName;
                std::string devId;
                LPWSTR pStrId = nullptr;
                if (SUCCEEDED(pDev->GetId(&pStrId)) && pStrId) {
                    devId = WideToUtf8(pStrId);
                    CoTaskMemFree(pStrId);
                }

                IPropertyStore* pProp = nullptr;
                if (SUCCEEDED(pDev->OpenPropertyStore(STGM_READ, &pProp)) && pProp) {
                    PROPVARIANT var;
                    PropVariantInit(&var);
                    if (SUCCEEDED(pProp->GetValue(PKEY_Device_FriendlyName, &var)) && var.pwszVal) {
                        devName = WideToUtf8(var.pwszVal);
                    }
                    PropVariantClear(&var);
                    pProp->Release();
                }

                pDev->Release();

                // 排除驱动自身的虚拟输出端点（避免环回自激）
                if (!devName.empty() && !ContainsCI(devName, "AuraVAIO")) {
                    endpoints.push_back({devName, devId});
                }
            }
            pCol->Release();
        }
        pEnum->Release();
    }
    CoUninitialize();

    // 3. 构建输出 JSON
    int n = _snprintf_s(
        out, (size_t)cap, _TRUNCATE,
        "{\"found\":%s,\"driverVersion\":\"%lu.%lu.%lu\",\"track\":\"%s\",\"kmdf\":\"%lu.%lu\","
        "\"sampleRate\":%lu,\"channels\":%lu,\"bits\":%lu,"
        "\"activeRender\":%lu,\"activeCapture\":%lu,\"endpoints\":[",
        driverFound ? "true" : "false",
        ver.DriverVersionMajor, ver.DriverVersionMinor, ver.DriverBuildNumber,
        (ver.Track == 1) ? "modern" : "legacy",
        ver.KmdfMajor, ver.KmdfMinor,
        st.SampleRate ? st.SampleRate : 48000,
        st.Channels ? st.Channels : 2,
        st.BitsPerSample ? st.BitsPerSample : 32,
        st.ActiveRenderStreams, st.ActiveCaptureStreams
    );

    if (n < 0) return -1;

    for (size_t i = 0; i < endpoints.size(); ++i) {
        char epNameEsc[256] = {0};
        PathForJsonA(endpoints[i].first, epNameEsc, sizeof(epNameEsc));
        const int w = _snprintf_s(
            out + n, (size_t)(cap - n), _TRUNCATE,
            "%s{\"name\":\"%s\",\"id\":\"%s\"}",
            (i ? "," : ""), epNameEsc, endpoints[i].second.c_str()
        );
        if (w < 0 || w >= cap - n) return -1;
        n += w;
    }

    const int w = _snprintf_s(out + n, (size_t)(cap - n), _TRUNCATE, "]}");
    if (w < 0 || w >= cap - n) return -1;
    n += w;

    return n;
}

int vaio_start(const char* engine_dll, const char* params_json, const char* output_endpoint_substr) {
    if (InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;  // 幂等成功

    // 复位状态
    memset(&g_vaio.tc, 0, sizeof(g_vaio.tc));
    g_vaio.userBypass = 0;
    g_vaio.totalPumpedFrames = 0;
    g_vaio.peakIn = 0.0;
    g_vaio.peakOut = 0.0;
    g_vaio.maxPumpUs = 0.0;
    g_vaio.startRc = -99;
    g_vaio.note[0] = '\0';
    g_vaio.paramsApplied = 0;
    g_vaio.paramsFailed = 0;

    // 1. 打开内核驱动控制设备
    g_vaio.hControlDev = CreateFileW(
        AURA_VAIO_USER_DEVICE_PATH,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );

    if (g_vaio.hControlDev == INVALID_HANDLE_VALUE) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "open-control-dev-failed: %lu", GetLastError());
        g_vaio.startRc = -1;
        return -1;
    }

    // 2. 映射共享环形缓冲区
    AURA_VAIO_MAP_REQUEST mapReq = {0};
    AURA_VAIO_MAP_RESPONSE mapResp = {0};
    DWORD bytesRet = 0;
    BOOL ok = DeviceIoControl(
        g_vaio.hControlDev,
        IOCTL_AURAVAIO_MAP_SHARED_RING,
        &mapReq, sizeof(mapReq),
        &mapResp, sizeof(mapResp),
        &bytesRet,
        nullptr
    );

    if (!ok || mapResp.UserAddress == nullptr) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "map-shared-ring-failed: %lu", GetLastError());
        UnmapAndCloseRing();
        g_vaio.startRc = -2;
        return -2;
    }

    g_vaio.pMappedRing = mapResp.UserAddress;
    g_vaio.pRingHeader = reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(mapResp.UserAddress);
    g_vaio.pRingPayload = (BYTE*)mapResp.UserAddress + g_vaio.pRingHeader->DataOffsetBytes;
    g_vaio.ringDataSize = g_vaio.pRingHeader->DataSizeBytes;
    g_vaio.ringChannels = g_vaio.pRingHeader->Channels ? g_vaio.pRingHeader->Channels : 2;
    g_vaio.ringSampleRate = g_vaio.pRingHeader->SampleRate ? g_vaio.pRingHeader->SampleRate : 48000;
    g_vaio.ringBits = g_vaio.pRingHeader->BitsPerSample ? g_vaio.pRingHeader->BitsPerSample : 32;
    g_vaio.ringBlockAlign = g_vaio.pRingHeader->BlockAlign ? g_vaio.pRingHeader->BlockAlign : (g_vaio.ringChannels * sizeof(float));

    // 3. 动态加载 auradsp_engine.dll
    std::wstring used;
    const std::string hint = (engine_dll && *engine_dll) ? engine_dll : "";
    g_vaio.hEngineMod = vmcore::TryLoadEngine(hint, used);
    if (!used.empty()) g_vaio.enginePath = used;

    if (g_vaio.hEngineMod) {
        g_vaio.fnCreate = (FnEngCreate)GetProcAddress(g_vaio.hEngineMod, "auradsp_create");
        g_vaio.fnProcess = (FnEngProcess)GetProcAddress(g_vaio.hEngineMod, "auradsp_process");
        g_vaio.fnDestroy = (FnEngDestroy)GetProcAddress(g_vaio.hEngineMod, "auradsp_destroy");
        g_vaio.fnSetParam = (FnEngSetParam)GetProcAddress(g_vaio.hEngineMod, "auradsp_set_param");
        g_vaio.fnGetParam = (FnEngGetParam)GetProcAddress(g_vaio.hEngineMod, "auradsp_get_param");
        g_vaio.fnVizRead = (FnEngVizRead)GetProcAddress(g_vaio.hEngineMod, "auradsp_viz_read");
    }

    if (!g_vaio.hEngineMod || !g_vaio.fnCreate || !g_vaio.fnProcess || !g_vaio.fnDestroy) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "engine-load-failed");
        UnmapAndCloseRing();
        DestroyEngine();
        g_vaio.startRc = -3;
        return -3;
    }

    // 4. 初始化 WASAPI 物理音频播放端点
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    HRESULT hr = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator), (void**)&g_vaio.pEnum
    );

    if (FAILED(hr) || !g_vaio.pEnum) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "wasapi-co-create-failed: 0x%08lX", hr);
        UnmapAndCloseRing();
        DestroyEngine();
        g_vaio.startRc = -4;
        return -4;
    }

    // 匹配物理音频端点
    IMMDevice* pFoundDev = nullptr;
    std::string matchedName;

    if (output_endpoint_substr && *output_endpoint_substr) {
        IMMDeviceCollection* pCol = nullptr;
        if (SUCCEEDED(g_vaio.pEnum->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &pCol)) && pCol) {
            UINT count = 0;
            pCol->GetCount(&count);
            for (UINT i = 0; i < count; ++i) {
                IMMDevice* pDev = nullptr;
                if (FAILED(pCol->Item(i, &pDev)) || !pDev) continue;

                IPropertyStore* pProp = nullptr;
                std::string nm;
                if (SUCCEEDED(pDev->OpenPropertyStore(STGM_READ, &pProp)) && pProp) {
                    PROPVARIANT var;
                    PropVariantInit(&var);
                    if (SUCCEEDED(pProp->GetValue(PKEY_Device_FriendlyName, &var)) && var.pwszVal) {
                        nm = WideToUtf8(var.pwszVal);
                    }
                    PropVariantClear(&var);
                    pProp->Release();
                }

                if (!nm.empty() && ContainsCI(nm, output_endpoint_substr) && !ContainsCI(nm, "AuraVAIO")) {
                    pFoundDev = pDev;
                    matchedName = nm;
                    break;
                }
                pDev->Release();
            }
            pCol->Release();
        }
    }

    if (!pFoundDev) {
        // 使用系统默认控制台渲染端点
        hr = g_vaio.pEnum->GetDefaultAudioEndpoint(eRender, eConsole, &pFoundDev);
        if (SUCCEEDED(hr) && pFoundDev) {
            IPropertyStore* pProp = nullptr;
            if (SUCCEEDED(pFoundDev->OpenPropertyStore(STGM_READ, &pProp)) && pProp) {
                PROPVARIANT var;
                PropVariantInit(&var);
                if (SUCCEEDED(pProp->GetValue(PKEY_Device_FriendlyName, &var)) && var.pwszVal) {
                    matchedName = WideToUtf8(var.pwszVal);
                }
                PropVariantClear(&var);
                pProp->Release();
            }
            // 若默认端点已被设成了 AuraVAIO 自己，寻找第一个非 AuraVAIO 的物理端点
            if (ContainsCI(matchedName, "AuraVAIO")) {
                pFoundDev->Release();
                pFoundDev = nullptr;
                IMMDeviceCollection* pCol = nullptr;
                if (SUCCEEDED(g_vaio.pEnum->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &pCol)) && pCol) {
                    UINT count = 0;
                    pCol->GetCount(&count);
                    for (UINT i = 0; i < count; ++i) {
                        IMMDevice* pDev = nullptr;
                        if (FAILED(pCol->Item(i, &pDev)) || !pDev) continue;
                        IPropertyStore* pProp2 = nullptr;
                        std::string nm;
                        if (SUCCEEDED(pDev->OpenPropertyStore(STGM_READ, &pProp2)) && pProp2) {
                            PROPVARIANT var;
                            PropVariantInit(&var);
                            if (SUCCEEDED(pProp2->GetValue(PKEY_Device_FriendlyName, &var)) && var.pwszVal) {
                                nm = WideToUtf8(var.pwszVal);
                            }
                            PropVariantClear(&var);
                            pProp2->Release();
                        }
                        if (!nm.empty() && !ContainsCI(nm, "AuraVAIO")) {
                            pFoundDev = pDev;
                            matchedName = nm;
                            break;
                        }
                        pDev->Release();
                    }
                    pCol->Release();
                }
            }
        }
    }

    if (!pFoundDev) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "no-physical-render-endpoint-found");
        UnmapAndCloseRing();
        DestroyEngine();
        DestroyWasapi();
        g_vaio.startRc = -5;
        return -5;
    }

    g_vaio.pOutDevice = pFoundDev;
    g_vaio.outEndpointName = matchedName;

    // 激活 IAudioClient
    hr = g_vaio.pOutDevice->Activate(
        __uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&g_vaio.pAudioClient
    );

    if (FAILED(hr) || !g_vaio.pAudioClient) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "activate-audioclient-failed: 0x%08lX", hr);
        UnmapAndCloseRing();
        DestroyEngine();
        DestroyWasapi();
        g_vaio.startRc = -6;
        return -6;
    }

    hr = g_vaio.pAudioClient->GetMixFormat(&g_vaio.pMixFormat);
    if (FAILED(hr) || !g_vaio.pMixFormat) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "get-mix-format-failed: 0x%08lX", hr);
        UnmapAndCloseRing();
        DestroyEngine();
        DestroyWasapi();
        g_vaio.startRc = -7;
        return -7;
    }

    g_vaio.wasapiSampleRate = g_vaio.pMixFormat->nSamplesPerSec > 0 ? g_vaio.pMixFormat->nSamplesPerSec : 48000;
    g_vaio.wasapiChannels = g_vaio.pMixFormat->nChannels > 0 ? g_vaio.pMixFormat->nChannels : 2;

    REFERENCE_TIME bufferDuration = 200000; // 20ms
    hr = g_vaio.pAudioClient->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        0,
        bufferDuration,
        0,
        g_vaio.pMixFormat,
        nullptr
    );

    if (FAILED(hr)) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "init-audioclient-failed: 0x%08lX", hr);
        UnmapAndCloseRing();
        DestroyEngine();
        DestroyWasapi();
        g_vaio.startRc = -8;
        return -8;
    }

    hr = g_vaio.pAudioClient->GetBufferSize(&g_vaio.wasapiBufferFrames);
    if (FAILED(hr) || g_vaio.wasapiBufferFrames == 0) {
        g_vaio.wasapiBufferFrames = (UINT32)(g_vaio.wasapiSampleRate * 0.02);
    }

    hr = g_vaio.pAudioClient->GetService(
        __uuidof(IAudioRenderClient), (void**)&g_vaio.pRenderClient
    );

    if (FAILED(hr) || !g_vaio.pRenderClient) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "get-render-client-failed: 0x%08lX", hr);
        UnmapAndCloseRing();
        DestroyEngine();
        DestroyWasapi();
        g_vaio.startRc = -9;
        return -9;
    }

    // 5. 创建 DSP 引擎 handle (采样率按物理输出采样率或 VAIO 采样率对齐)
    const float engineSr = (float)g_vaio.wasapiSampleRate;
    g_vaio.pEngine = g_vaio.fnCreate(engineSr, 2048);
    if (!g_vaio.pEngine) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "engine-create-failed");
        UnmapAndCloseRing();
        DestroyEngine();
        DestroyWasapi();
        g_vaio.startRc = -10;
        return -10;
    }

    // 6. 预分配 RT 临时缓冲 (4096 帧 * 8 声道 float32)
    const size_t scratchBytes = (size_t)VaioBridgeCtl::kMaxFrames * 8 * sizeof(float);
    g_vaio.scratchIn = (float*)malloc(scratchBytes);
    g_vaio.scratchOut = (float*)malloc(scratchBytes);
    if (!g_vaio.scratchIn || !g_vaio.scratchOut) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "malloc-scratch-failed");
        FreeScratchBuffers();
        UnmapAndCloseRing();
        DestroyEngine();
        DestroyWasapi();
        g_vaio.startRc = -11;
        return -11;
    }
    memset(g_vaio.scratchIn, 0, scratchBytes);
    memset(g_vaio.scratchOut, 0, scratchBytes);

    // 7. 应用初始参数并回放镜像
    ApplyParamsString(params_json);
    ReplayMirroredParams();

    // 8. 启动 RT 音频泵线程
    InterlockedExchange(&g_vaio.stopEvent, 0);
    g_vaio.hPumpThread = CreateThread(nullptr, 0, VaioPumpThreadProc, nullptr, 0, nullptr);
    if (!g_vaio.hPumpThread) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "create-pump-thread-failed: %lu", GetLastError());
        FreeScratchBuffers();
        UnmapAndCloseRing();
        DestroyEngine();
        DestroyWasapi();
        g_vaio.startRc = -12;
        return -12;
    }

    g_vaio.startRc = 0;
    InterlockedExchange(&g_vaio.running, 1);
    return 0;
}

int vaio_stop() {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;  // 幂等退出

    InterlockedExchange(&g_vaio.stopEvent, 1);
    if (g_vaio.hPumpThread) {
        WaitForSingleObject(g_vaio.hPumpThread, 2000);
        CloseHandle(g_vaio.hPumpThread);
        g_vaio.hPumpThread = nullptr;
    }

    FreeTestFile();
    DestroyWasapi();
    DestroyEngine();
    UnmapAndCloseRing();
    FreeScratchBuffers();

    InterlockedExchange(&g_vaio.running, 0);
    return 0;
}

int vaio_status(char* out, int cap) {
    if (!out || cap <= 0) return -1;

    char engPathEsc[MAX_PATH * 2] = {0};
    PathForJson(g_vaio.enginePath, engPathEsc, sizeof(engPathEsc));
    char outEpEsc[256] = {0};
    PathForJsonA(g_vaio.outEndpointName, outEpEsc, sizeof(outEpEsc));

    const bool isRunning = (InterlockedCompareExchange(&g_vaio.running, 0, 0) == 1);

    const int n = _snprintf_s(
        out, (size_t)cap, _TRUNCATE,
        "{\"running\":%s,\"frames\":%llu,\"sr\":%lu,\"channels\":%lu,\"bits\":%lu,"
        "\"peakIn\":%.4f,\"peakOut\":%.4f,\"maxPumpUs\":%.2f,\"startRc\":%d,\"note\":\"%s\","
        "\"outputEndpoint\":\"%s\",\"engineOk\":%s,\"enginePath\":\"%s\","
        "\"paramsApplied\":%d,\"paramsFailed\":%d,\"bypass\":%ld,\"testKind\":%ld}",
        isRunning ? "true" : "false",
        (unsigned long long)g_vaio.totalPumpedFrames,
        g_vaio.wasapiSampleRate ? g_vaio.wasapiSampleRate : g_vaio.ringSampleRate,
        g_vaio.ringChannels,
        g_vaio.ringBits,
        g_vaio.peakIn,
        g_vaio.peakOut,
        g_vaio.maxPumpUs,
        g_vaio.startRc,
        g_vaio.note,
        outEpEsc,
        (g_vaio.pEngine != nullptr) ? "true" : "false",
        engPathEsc,
        g_vaio.paramsApplied,
        g_vaio.paramsFailed,
        InterlockedCompareExchange(&g_vaio.userBypass, 0, 0),
        InterlockedCompareExchange(&g_vaio.tc.testKind, 0, 0)
    );

    if (n < 0 || n >= cap) return -1;
    return n;
}

int vaio_set_param(const char* id, int isFloat, const void* v4) {
    if (!id || !v4) return -1;
    MirrorSet(id, isFloat != 0, v4);
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0) || !g_vaio.pEngine || !g_vaio.fnSetParam) {
        return 0; // 记录镜像成功，待启动时回放
    }
    return (g_vaio.fnSetParam(g_vaio.pEngine, id, v4, 4) == 0) ? 0 : -2;
}

int vaio_set_param_str(const char* id, const char* utf8, int bytes) {
    if (!id || !utf8 || bytes < 0) return -1;
    MirrorSetStr(id, utf8, bytes);
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0) || !g_vaio.pEngine || !g_vaio.fnSetParam) {
        return 0;
    }
    return (g_vaio.fnSetParam(g_vaio.pEngine, id, utf8, (unsigned int)bytes) == 0) ? 0 : -2;
}

int vaio_get_param(const char* id, int isFloat, void* out4) {
    if (!id || !out4 || !g_vaio.pEngine || !g_vaio.fnGetParam) return -1;
    return (g_vaio.fnGetParam(g_vaio.pEngine, id, out4, 4) == 0) ? 0 : -2;
}

int vaio_get_param_str(const char* id, char* out, int cap) {
    if (!id || !out || cap <= 0 || !g_vaio.pEngine || !g_vaio.fnGetParam) return -1;
    return g_vaio.fnGetParam(g_vaio.pEngine, id, out, (unsigned int)cap);
}

int vaio_viz_read(void* out408, int count) {
    if (!out408 || count <= 0 || !g_vaio.pEngine || !g_vaio.fnVizRead) return 0;
    return g_vaio.fnVizRead(g_vaio.pEngine, out408, count);
}

int vaio_bypass(int on) {
    InterlockedExchange(&g_vaio.userBypass, on ? 1 : 0);
    return 0;
}

int vaio_test_start(int kind, const float* pcm, int frames, int ch, int rate) {
    if (kind <= 0 || kind > 3) return -1;
    if (kind == 3) {
        if (!pcm || frames <= 0 || ch != 2 || rate <= 0) return -2;
        const size_t bytes = (size_t)frames * 2 * sizeof(float);
        float* copy = (float*)malloc(bytes);
        if (!copy) return -3;
        memcpy(copy, pcm, bytes);

        FreeTestFile();
        g_vaio.tc.testFile = copy;
        g_vaio.tc.testFrames = (uint64_t)frames;
        g_vaio.tc.testRate = rate;
        g_vaio.tc.testPos = 0.0;
    } else {
        FreeTestFile();
    }

    g_vaio.tc.testPhase = 0.0;
    g_vaio.tc.testRng = 0x12345678u;
    memset(g_vaio.tc.testPink, 0, sizeof(g_vaio.tc.testPink));
    InterlockedExchange(&g_vaio.tc.testKind, kind);
    return 0;
}

int vaio_test_stop() {
    FreeTestFile();
    return 0;
}
