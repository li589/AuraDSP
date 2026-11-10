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

#include "PluginBridge.h"
#include "VizSilence.h"
#include "../../common/AuraVaioIpc.h"
#include "../../02_voicemeeter_client/VmPumpCore.h"
#include "vaio_pump_wait.h"

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

// JSON 字符串转义（细审 R-D L6）：端点/驱动名含 " 或控制
// 字符时，旧有 PathForJsonA（只换反斜杠）拼出的 JSON 损坏，
// Dart 侧 jsonDecode 抛错被吞、detect/status 整体按缺失
// 处理（误报未检测到/状态丢失）。名称类自由文本一律走本
// 函数；路径仍用 PathForJsonA 的斜杠式（既有口径）。
void EscapeJsonA(const std::string& in, char* out, size_t cap) {
    size_t j = 0;
    auto put = [&](char c) { if (j + 1 < cap) out[j++] = c; };
    for (size_t i = 0; i < in.size(); ++i) {
        const unsigned char c = (unsigned char)in[i];
        if (c == '"' || c == '\\') { put('\\'); put((char)c); }
        else if (c < 0x20) {
            char u[8];
            snprintf(u, sizeof(u), "\u%04x", c);
            for (const char* p = u; *p; ++p) put(*p);
        } else put((char)c);
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
using vmcore::FnEngAbi;
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
    // 共享头几何旁观值（第四轮项 3 取证）：工作几何改以 MAP 应答
    // 的内核真值为准（DRV-03 口径），头字段仅留档对照——status
    // 同时输出两份，噪声复现时一招分辨几何来源分歧。
    ULONG hdrChannels = 0;
    ULONG hdrSampleRate = 0;
    ULONG hdrBits = 0;

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
    /* D3：WASAPI 周期事件（EVENTCALLBACK）。播放引擎每消费完一个周期置位，
     * 泵线程按事件唤醒——不再靠 Sleep 猜节拍。 */
    HANDLE hAudioEvent = nullptr;
    WAVEFORMATEX* pMixFormat = nullptr;
    std::string outEndpointName;
    UINT32 wasapiBufferFrames = 0;
    UINT32 wasapiChannels = 2;
    UINT32 wasapiSampleRate = 48000;

    // 预分配 RT 临时缓冲 (最大 4096 帧 * 8 声道 float32)
    static constexpr int kMaxFrames = 4096;
    float* scratchIn = nullptr;       // 驱动环直接读入 (frames * ringChannels)
    float* scratchOut = nullptr;      // 写入 WASAPI (frames * wasapiChannels)
    float* scratchProcIn = nullptr;   // 喂入 auradsp_process (frames * engineChannels)
    float* scratchProcOut = nullptr;  // 从 auradsp_process 产出 (frames * engineChannels)
    float* scratchRing = nullptr;     // 环字节归一后的 float 帧 (重采样源)
    BYTE* scratchRaw = nullptr;       // 环原始字节暂存 (frames * ringBlockAlign)

    // WASAPI 混音格式分类（start 时按 GetMixFormat 定稿，泵写侧据此转换）
    bool wasapiIsFloat = true;        // true = IEEE float32 直通
    ULONG wasapiBits = 32;            // PCM 时为 16/32

    // 声道协商与多声道重映射状态
    int32_t engineChannels = 2;   // 引擎当前实际运行声道数 (2, 4, 6, 8)
    int32_t countMode = 0;        // 0 = 自动跟随驱动环 (ringChannels), 1 = 手动锁定 (manualChannels)
    int32_t manualChannels = 2;   // 手动模式下用户指定的声道数 (2, 4, 6, 8)

    // 运行态与 RT 统计
    HANDLE hPumpThread = nullptr;
    volatile LONG running = 0;
    volatile LONG stopEvent = 0;
    volatile LONG userBypass = 0;

    // P3 静音门控（单组语义：整个环块一组）。start 时按物理输出采样率配置。
    aurabridge::SilenceGate gate;

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

// GATED 后引擎不再产 viz 帧；单组静音时补合法静音帧（仅控制线程）。
static aurabridge::SilentVizEmitter g_silentViz;

// 插件槽转发：单引擎（g_vaio.pEngine），Dart 在 start 成功后按会话镜像重放。
auraplugin::Fns g_pluginFns;
auraplugin::Mirror g_pluginMirror;

void FreeTestFile() {
    // D2：清 kind 后**确定性**等在途块退出，替代原来的 Sleep(50) 猜测。
    InterlockedExchange(&g_vaio.tc.testKind, 0);
    if (!vmcore::WaitRtDrained(&g_vaio.tc.rtInBlock)) {
        // 极端：3s 内泵线程没退出当前块。此时 free 会踩在途读，整块保留不释放
        // ——与 B3 quarantine 同一哲学：可控泄漏换不可控崩溃。
        return;
    }
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
    // P3：引擎没了门控一并作废（下次 start 会重新 Configure）。
    g_vaio.gate.Reset();
    g_vaio.gate.enabled = false;
}

void DestroyWasapi() {
    if (g_vaio.pAudioClient) {
        g_vaio.pAudioClient->Stop();
    }
    /* D3：事件句柄随 client 生命周期。调用点都在泵线程 join 之后
     * （vaio_stop → WaitForSingleObject(hPumpThread) → DestroyWasapi），
     * 不存在"关掉别人正在等的句柄"。 */
    if (g_vaio.hAudioEvent) {
        CloseHandle(g_vaio.hAudioEvent);
        g_vaio.hAudioEvent = nullptr;
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
    if (g_vaio.scratchProcIn) {
        free(g_vaio.scratchProcIn);
        g_vaio.scratchProcIn = nullptr;
    }
    if (g_vaio.scratchProcOut) {
        free(g_vaio.scratchProcOut);
        g_vaio.scratchProcOut = nullptr;
    }
    if (g_vaio.scratchRing) {
        free(g_vaio.scratchRing);
        g_vaio.scratchRing = nullptr;
    }
    if (g_vaio.scratchRaw) {
        free(g_vaio.scratchRaw);
        g_vaio.scratchRaw = nullptr;
    }
}

void SetEngineChannels(int32_t count) {
    if (count != 2 && count != 4 && count != 6 && count != 8) return;
    if (g_vaio.pEngine && g_vaio.fnSetParam) {
        g_vaio.fnSetParam(g_vaio.pEngine, "channels.count", &count, sizeof(count));
    }
    InterlockedExchange((volatile LONG*)&g_vaio.engineChannels, (LONG)count);
}

// 零分配交织音频重映射：安全适配驱动共享环、DSP处理链与WASAPI输出三者之间的声道拓扑差异
void RemapInterleavedAudio(const float* src, int srcCh, float* dst, int dstCh, int frames) {
    if (srcCh == dstCh) {
        memcpy(dst, src, (size_t)frames * dstCh * sizeof(float));
        return;
    }
    // 4ch (Quad: FL,FR,BL,BR) -> 2ch：后置按 -3dB 折入 L/R
    if (srcCh == 4 && dstCh == 2) {
        for (int f = 0; f < frames; ++f) {
            dst[f * 2 + 0] = src[f * 4 + 0] + src[f * 4 + 2] * 0.70710678f;
            dst[f * 2 + 1] = src[f * 4 + 1] + src[f * 4 + 3] * 0.70710678f;
        }
        return;
    }
    // 4ch (Quad) -> 6ch (5.1)：Quad 的后置即 5.1 的 SL/SR，C/LFE 无源
    if (srcCh == 4 && dstCh == 6) {
        for (int f = 0; f < frames; ++f) {
            dst[f * 6 + 0] = src[f * 4 + 0];
            dst[f * 6 + 1] = src[f * 4 + 1];
            dst[f * 6 + 2] = 0.0f;
            dst[f * 6 + 3] = 0.0f;
            dst[f * 6 + 4] = src[f * 4 + 2];
            dst[f * 6 + 5] = src[f * 4 + 3];
        }
        return;
    }
    // 4ch (Quad) -> 8ch (7.1)：Quad 的后置对到 BL/BR，C/LFE/SL/SR 无源
    if (srcCh == 4 && dstCh == 8) {
        for (int f = 0; f < frames; ++f) {
            dst[f * 8 + 0] = src[f * 4 + 0];
            dst[f * 8 + 1] = src[f * 4 + 1];
            dst[f * 8 + 2] = 0.0f;
            dst[f * 8 + 3] = 0.0f;
            dst[f * 8 + 4] = 0.0f;
            dst[f * 8 + 5] = 0.0f;
            dst[f * 8 + 6] = src[f * 4 + 2];
            dst[f * 8 + 7] = src[f * 4 + 3];
        }
        return;
    }
    // 6ch (5.1) -> 2ch：C/SL/SR 按 -3dB 折入 L/R，LFE 丢弃
    if (srcCh == 6 && dstCh == 2) {
        for (int f = 0; f < frames; ++f) {
            const float c = src[f * 6 + 2] * 0.70710678f;
            dst[f * 2 + 0] =
                src[f * 6 + 0] + c + src[f * 6 + 4] * 0.70710678f;
            dst[f * 2 + 1] =
                src[f * 6 + 1] + c + src[f * 6 + 5] * 0.70710678f;
        }
        return;
    }
    // 6ch (5.1) -> 4ch (Quad)：C 折入 L/R，SL/SR 落到 BL/BR，LFE 丢弃
    if (srcCh == 6 && dstCh == 4) {
        for (int f = 0; f < frames; ++f) {
            const float c = src[f * 6 + 2] * 0.70710678f;
            dst[f * 4 + 0] = src[f * 6 + 0] + c;
            dst[f * 4 + 1] = src[f * 6 + 1] + c;
            dst[f * 4 + 2] = src[f * 6 + 4];
            dst[f * 4 + 3] = src[f * 6 + 5];
        }
        return;
    }
    // 8ch (7.1) -> 2ch (Stereo)
    if (srcCh == 8 && dstCh == 2) {
        for (int f = 0; f < frames; ++f) {
            float l = src[f * 8 + 0];
            float r = src[f * 8 + 1];
            const float c  = src[f * 8 + 2];
            const float sl = src[f * 8 + 4];
            const float sr = src[f * 8 + 5];
            const float bl = src[f * 8 + 6];
            const float br = src[f * 8 + 7];
            if (c != 0.0f) {
                const float ch = c * 0.70710678f;
                l += ch;
                r += ch;
            }
            if (sl != 0.0f) l += sl * 0.70710678f;
            if (sr != 0.0f) r += sr * 0.70710678f;
            if (bl != 0.0f) l += bl * 0.70710678f;
            if (br != 0.0f) r += br * 0.70710678f;
            dst[f * 2 + 0] = l;
            dst[f * 2 + 1] = r;
        }
        return;
    }
    // 8ch (7.1) -> 6ch (5.1)
    if (srcCh == 8 && dstCh == 6) {
        for (int f = 0; f < frames; ++f) {
            dst[f * 6 + 0] = src[f * 8 + 0];
            dst[f * 6 + 1] = src[f * 8 + 1];
            dst[f * 6 + 2] = src[f * 8 + 2];
            dst[f * 6 + 3] = src[f * 8 + 3];
            dst[f * 6 + 4] = src[f * 8 + 4] + src[f * 8 + 6] * 0.70710678f;
            dst[f * 6 + 5] = src[f * 8 + 5] + src[f * 8 + 7] * 0.70710678f;
        }
        return;
    }
    // 8ch (7.1) -> 4ch (Quad)：C 折入 L/R，SL/BL、SR/BR 合到 BL/BR
    if (srcCh == 8 && dstCh == 4) {
        for (int f = 0; f < frames; ++f) {
            const float c = src[f * 8 + 2] * 0.70710678f;
            dst[f * 4 + 0] = src[f * 8 + 0] + c;
            dst[f * 4 + 1] = src[f * 8 + 1] + c;
            dst[f * 4 + 2] = src[f * 8 + 4] + src[f * 8 + 6] * 0.70710678f;
            dst[f * 4 + 3] = src[f * 8 + 5] + src[f * 8 + 7] * 0.70710678f;
        }
        return;
    }
    // 2ch (Stereo) -> 多声道扩展 (前两声道直通，其余静音)
    if (srcCh == 2 && dstCh > 2) {
        for (int f = 0; f < frames; ++f) {
            dst[f * dstCh + 0] = src[f * 2 + 0];
            dst[f * dstCh + 1] = src[f * 2 + 1];
            for (int c = 2; c < dstCh; ++c) {
                dst[f * dstCh + c] = 0.0f;
            }
        }
        return;
    }
    // 通用回退：按公共通道数复制，目标多余通道补零
    const int copyCh = (srcCh < dstCh) ? srcCh : dstCh;
    for (int f = 0; f < frames; ++f) {
        for (int c = 0; c < copyCh; ++c) {
            dst[f * dstCh + c] = src[f * srcCh + c];
        }
        for (int c = copyCh; c < dstCh; ++c) {
            dst[f * dstCh + c] = 0.0f;
        }
    }
}

// 环数据格式归一（2026-11-09 真机报告 §1.2）：驱动引脚表契约——
// 32 位恒为 IEEE float、16 位恒为 PCM int16（AuraVaoTables.h 的
// data ranges）。历史上泵把环字节无条件当 float32 消费：端点协商
// 出 PCM16 时 int16 样本对被拼成 float 位型，幅度近均匀散布至极
// 大值——电平全红、输出破碎、旁路近静音（真机症状逐项吻合）。
// 此处按共享头 BitsPerSample 归一后再进峰值/门控/引擎链。
void ConvertRingToFloat(const BYTE* raw, float* dst, int frames, int channels, ULONG bits) {
    const int n = frames * channels;
    if (bits == 16) {
        const int16_t* s = reinterpret_cast<const int16_t*>(raw);
        for (int i = 0; i < n; ++i) dst[i] = (float)s[i] * (1.0f / 32768.0f);
    } else {
        memcpy(dst, raw, (size_t)n * sizeof(float));
    }
}

// 线性插值重采样（环速率 → 输出速率，同 §1.2）：两端格式各自
// 独立协商（引脚表 44100–192000），泵历史上 1:1 逐帧消费、无重
// 采样，速率失配必然变调 + 周期跳读撕裂。phase 为本块首个输出
// 帧在源帧坐标中的分数位置，ratio = 环率/输出率（调用方跨块
// 携带分数相位）。源尾不足时钳到末帧（前视帧缺失的优雅降级）。
void ResampleLinear(const float* src, int srcFrames, float* dst, int dstFrames,
                    int channels, double phase, double ratio) {
    if (srcFrames <= 0) {
        memset(dst, 0, (size_t)dstFrames * channels * sizeof(float));
        return;
    }
    for (int i = 0; i < dstFrames; ++i) {
        const double pos = phase + (double)i * ratio;
        const int idx = (int)pos;
        float* d = dst + (size_t)i * channels;
        if (idx >= srcFrames - 1) {
            const float* s = src + (size_t)(srcFrames - 1) * channels;
            for (int c = 0; c < channels; ++c) d[c] = s[c];
        } else {
            const float frac = (float)(pos - (double)idx);
            const float* s0 = src + (size_t)idx * channels;
            const float* s1 = s0 + channels;
            for (int c = 0; c < channels; ++c) d[c] = s0[c] + (s1[c] - s0[c]) * frac;
        }
    }
}

void ReplayMirroredParams() {
    if (!g_vaio.pEngine || !g_vaio.fnSetParam) return;
    InitMirrorCs();
    EnterCriticalSection(&g_mirrorCs);
    for (int i = 0; i < g_mirrorN; ++i) {
        const MirrorEnt& e = g_mirror[i];
        if (strcmp(e.id, "channels.countMode") == 0) {
            const int32_t m = e.isFloat ? (int32_t)e.f : e.i;
            g_vaio.countMode = (m != 0) ? 1 : 0;
            continue;
        }
        if (strcmp(e.id, "channels.count") == 0) {
            const int32_t c = e.isFloat ? (int32_t)e.f : e.i;
            if (c == 2 || c == 4 || c == 6 || c == 8) g_vaio.manualChannels = c;
            continue;
        }
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
            if (strcmp(id, "channels.countMode") == 0) {
                g_vaio.countMode = ((int)f != 0) ? 1 : 0;
            } else if (strcmp(id, "channels.count") == 0) {
                const int32_t cnt = (int32_t)f;
                if (cnt == 2 || cnt == 4 || cnt == 6 || cnt == 8) g_vaio.manualChannels = cnt;
            } else {
                if (g_vaio.fnSetParam(g_vaio.pEngine, id, &f, 4) != 0) {
                    ++g_vaio.paramsFailed;
                } else {
                    ++g_vaio.paramsApplied;
                }
            }
        } else {
            const int32_t iv = (int32_t)atoi(vs);
            MirrorSet(id, false, &iv);
            if (strcmp(id, "channels.countMode") == 0) {
                g_vaio.countMode = (iv != 0) ? 1 : 0;
            } else if (strcmp(id, "channels.count") == 0) {
                if (iv == 2 || iv == 4 || iv == 6 || iv == 8) g_vaio.manualChannels = iv;
            } else {
                if (g_vaio.fnSetParam(g_vaio.pEngine, id, &iv, 4) != 0) {
                    ++g_vaio.paramsFailed;
                } else {
                    ++g_vaio.paramsApplied;
                }
            }
        }
    }
}

// RT 专用线程：零锁零分配音频泵
DWORD WINAPI VaioPumpThreadProc(LPVOID) {
    // 注册 MMCSS Pro Audio 优先级调度
    DWORD taskIndex = 0;
    HANDLE hMmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);
#if defined(_M_X64) || defined(__x86_64__)
    _mm_setcsr(_mm_getcsr() | 0x8040); // 永久开启 FTZ | DAZ，防止次正规数 microcode trap 拖垮 RT 线程
#endif

    LARGE_INTEGER qpcFreq;
    QueryPerformanceFrequency(&qpcFreq);
    const double qpcToUs = 1000000.0 / (double)qpcFreq.QuadPart;

    volatile PAURA_VAIO_SHARED_HEADER pHeader = g_vaio.pRingHeader;
    const ULONG dataSize = g_vaio.ringDataSize;
    ULONG blockAlign = g_vaio.ringBlockAlign > 0 ? g_vaio.ringBlockAlign : 8;
    ULONG ringChannels = g_vaio.ringChannels > 0 ? g_vaio.ringChannels : 2;
    const ULONG wasapiChannels = g_vaio.wasapiChannels > 0 ? g_vaio.wasapiChannels : 2;
    BYTE* const pPayload = g_vaio.pRingPayload;

    // 格式归一状态（§1.2）：位深/环速率随共享头动态跟随，输出侧
    // 格式在 start 时已定稿。inRatio = 环率/输出率（每输出帧消耗
    // 的环帧数），fracPhase 为重采样的跨块分数相位。
    ULONG ringBits = g_vaio.ringBits > 0 ? g_vaio.ringBits : 32;
    ULONG ringRate = g_vaio.ringSampleRate > 0 ? g_vaio.ringSampleRate : 48000;
    const ULONG outRate = g_vaio.wasapiSampleRate > 0 ? g_vaio.wasapiSampleRate : 48000;
    const bool outIsFloat = g_vaio.wasapiIsFloat;
    const ULONG outBits = g_vaio.wasapiBits;
    double inRatio = (double)ringRate / (double)outRate;
    double fracPhase = 0.0;

    // 初始消费指针与内核当前写入位置对齐（避免刚开机把陈旧噪底播出来）
    ULONGLONG userBytesRead = pHeader ? pHeader->TotalBytesWritten : 0;

    // 启动 WASAPI 播放：HRESULT 必须查——失败时泵会在
    // GetCurrentPadding 上永久空转而 status 仍报 running，
    // 呈「无声无 viz」假象（取证 2026-11-09 候选 5）；把失败
    // 写进 note 让 status 可见。
    //
    // 端点死亡核算（细审 R-B 1/3）：渲染侧连续失败轮次计数，
    // 健康轮（GetBuffer 成功）清零。Start 失败按周期重试
    // （瞬时 busy 可自愈）；连续 400 轮失败判端点死亡——写
    // wasapi-output-lost note、清 running 并退出泵，不再对
    // 死端点永久空转假报在跑（与 Dart 本地泵 400 轮 latch
    // 同口径；WASAPI 对象由 vaio_stop 统一销毁，其对已退出
    // 的泵线程 Wait 立即返回，兼容本路径）。
    bool renderStarted = false;
    int renderFailRounds = 0;
    HRESULT lastRenderHr = S_OK;
    bool bitsNoteWritten = false;
    {
        const HRESULT hrStart = g_vaio.pAudioClient->Start();
        if (FAILED(hrStart)) {
            lastRenderHr = hrStart;
            snprintf(g_vaio.note, sizeof(g_vaio.note),
                     "wasapi-render-start-failed: 0x%08lX", hrStart);
        } else {
            renderStarted = true;
        }
    }

    while (!InterlockedCompareExchange(&g_vaio.stopEvent, 0, 0)) {
        // Start 未成功：按失败轮核算，每 50 轮重试一次 Start。
        if (!renderStarted) {
            renderFailRounds++;
            if (renderFailRounds >= 400) {
                snprintf(g_vaio.note, sizeof(g_vaio.note),
                         "wasapi-output-lost: 0x%08lX", lastRenderHr);
                InterlockedExchange(&g_vaio.running, 0);
                break;
            }
            if (renderFailRounds % 50 == 0) {
                const HRESULT hrRetry = g_vaio.pAudioClient->Start();
                if (SUCCEEDED(hrRetry)) {
                    renderStarted = true;
                    renderFailRounds = 0;
                    g_vaio.note[0] = '\0';
                } else {
                    lastRenderHr = hrRetry;
                }
            }
            vmcore::WaitAudioPeriod(g_vaio.hAudioEvent);
            continue;
        }

        // 动态检测驱动共享环上的声道配置变更
        if (pHeader && pHeader->Channels != ringChannels && pHeader->Channels > 0) {
            ringChannels = pHeader->Channels;
            g_vaio.ringChannels = ringChannels;
            blockAlign = pHeader->BlockAlign > 0 ? pHeader->BlockAlign : (ringChannels * (ringBits == 16 ? sizeof(int16_t) : sizeof(float)));
            g_vaio.ringBlockAlign = blockAlign;
            if (g_vaio.countMode == 0) {
                SetEngineChannels((int32_t)ringChannels);
            }
        }

        // 动态检测位深/采样率变更（端点格式变化时内核同步更新共享
        // 头）：位深决定归一方式、速率决定重采样比，漏检即回到
        // §1.2 的格式误读。
        if (pHeader && pHeader->BitsPerSample > 0 && pHeader->BitsPerSample != ringBits) {
            ringBits = pHeader->BitsPerSample;
            g_vaio.ringBits = ringBits;
            if (pHeader->BlockAlign > 0) {
                blockAlign = pHeader->BlockAlign;
                g_vaio.ringBlockAlign = blockAlign;
            }
        }
        if (pHeader && pHeader->SampleRate > 0 && pHeader->SampleRate != ringRate) {
            ringRate = pHeader->SampleRate;
            g_vaio.ringSampleRate = ringRate;
            inRatio = (double)ringRate / (double)outRate;
            fracPhase = 0.0;
        }

        UINT32 padFrames = 0;
        HRESULT hr = g_vaio.pAudioClient->GetCurrentPadding(&padFrames);
        if (FAILED(hr)) {
            // 端点死亡核算：连续失败达闩值即判失联退出（见
            // Start 处注释），不再永久空转。
            renderFailRounds++;
            lastRenderHr = hr;
            if (renderFailRounds >= 400) {
                snprintf(g_vaio.note, sizeof(g_vaio.note),
                         "wasapi-output-lost: 0x%08lX", lastRenderHr);
                InterlockedExchange(&g_vaio.running, 0);
                break;
            }
            /* D3：原来 Sleep(2)（实际 1~15.6ms，且是忙轮询）。改为等一个周期
             * 信号，带上界只为定期回看 stopEvent。 */
            vmcore::WaitAudioPeriod(g_vaio.hAudioEvent);
            continue;
        }

        UINT32 framesNeeded = g_vaio.wasapiBufferFrames > padFrames
                                  ? (g_vaio.wasapiBufferFrames - padFrames)
                                  : 0;

        if (framesNeeded == 0) {
            /* 缓冲已满：等播放引擎消费掉一个周期（事件唤醒），而不是 Sleep(1)
             * 猜时间。醒来后重新取 padding —— 消费量由引擎决定，睡多久都不对。 */
            vmcore::WaitAudioPeriod(g_vaio.hAudioEvent);
            continue;
        }

        // 单次处理块上限钳制在 512 帧，防止突发大块拉高瞬时延迟
        UINT32 framesToProcess = (framesNeeded > 512) ? 512 : framesNeeded;
        if (framesToProcess > (UINT32)VaioBridgeCtl::kMaxFrames) {
            framesToProcess = (UINT32)VaioBridgeCtl::kMaxFrames;
        }

        // 本块的环帧消费量（速率归一）：输出 framesToProcess 帧
        // 消耗 framesToProcess × inRatio 个环帧，分数部分以
        // fracPhase 跨块携带。inRatio == 1 时 wholeInFrames 恒等
        // 于 framesToProcess，与历史行为逐帧一致。
        const double wantInFrames = fracPhase + (double)framesToProcess * inRatio;
        ULONG wholeInFrames = (ULONG)wantInFrames;
        const double nextPhase = wantInFrames - (double)wholeInFrames;
        if (wholeInFrames > (ULONG)VaioBridgeCtl::kMaxFrames - 1) {
            wholeInFrames = (ULONG)VaioBridgeCtl::kMaxFrames - 1;
        }

        // D2：本块在途计数。FreeTestFile 的排空等待以此为准（原为 Sleep(50)
        // 猜毫秒数）。作用域到本轮 while 体末尾——本段内无 continue/break。
        vmcore::RtInBlockGuard inBlock(&g_vaio.tc.rtInBlock);

        // 检查共享环是否有有效数据
        ULONGLONG totalWritten = pHeader ? pHeader->TotalBytesWritten : 0;
        ULONGLONG availBytes = 0;
        if (totalWritten < userBytesRead) {
            // 内核重置或驱动重启：跟进对齐到当前写入位置，防止死锁滞后
            userBytesRead = totalWritten;
        } else if (totalWritten > userBytesRead) {
            availBytes = totalWritten - userBytesRead;
            // 环形缓冲覆写超载处理：若落后超过一整圈，强制跟进到最新一圈头部
            if (availBytes > (ULONGLONG)dataSize) {
                availBytes = (ULONGLONG)dataSize;
                userBytesRead = totalWritten - availBytes;
            }
        }

        const ULONG availFrames = blockAlign > 0 ? (ULONG)(availBytes / blockAlign) : 0;
        const ULONG minAvail = wholeInFrames > 0 ? wholeInFrames : 1;

        // 测试信号注入面（优先覆盖真实输入）
        if (g_vaio.tc.testKind != 0) {
            vmcore::FillTestSignalN(&g_vaio.tc, g_vaio.scratchIn, (long)framesToProcess, (int)ringChannels);
            // 测试注入时，虚拟声卡输入的音频同步步进丢弃，保持时序不滞后
            if (availFrames >= wholeInFrames) {
                userBytesRead += wholeInFrames * blockAlign;
            }
            fracPhase = nextPhase;
        } else if (availFrames >= minAvail && pPayload && dataSize > 0 &&
                   blockAlign <= 32 && ringChannels <= 8) {
            // 从共享内存循环队列读取渲染样本原始字节（多读 1 帧
            // 作插值前视，不推进消费指针），再按协商位深归一。
            ULONG readInFrames = wholeInFrames + 1;
            if (readInFrames > availFrames) readInFrames = availFrames;
            const ULONG rawBytes = readInFrames * blockAlign;
            ULONG readOffset = (ULONG)(userBytesRead % dataSize);
            ULONG chunk1 = dataSize - readOffset;
            if (chunk1 >= rawBytes) {
                memcpy(g_vaio.scratchRaw, pPayload + readOffset, rawBytes);
            } else {
                ULONG chunk2 = rawBytes - chunk1;
                memcpy(g_vaio.scratchRaw, pPayload + readOffset, chunk1);
                memcpy(g_vaio.scratchRaw + chunk1, pPayload, chunk2);
            }
            if (ringBits == 16 || ringBits == 32) {
                ConvertRingToFloat(g_vaio.scratchRaw, g_vaio.scratchRing,
                                   (int)readInFrames, (int)ringChannels, ringBits);
                if (inRatio == 1.0) {
                    memcpy(g_vaio.scratchIn, g_vaio.scratchRing,
                           (size_t)framesToProcess * ringChannels * sizeof(float));
                } else {
                    ResampleLinear(g_vaio.scratchRing, (int)readInFrames,
                                   g_vaio.scratchIn, (int)framesToProcess,
                                   (int)ringChannels, fracPhase, inRatio);
                }
            } else {
                // 位深契约外（细审 R-B 6）：现行驱动引脚表只有
                // float32/PCM16；未知位深绝不按 float 误读
                // （§1.2 同型事故），整块静音、一次性落 note，
                // 环消费照常推进（数据格式不可用但时序要维持）。
                if (!bitsNoteWritten) {
                    bitsNoteWritten = true;
                    snprintf(g_vaio.note, sizeof(g_vaio.note),
                             "ring-bits-unsupported: %lu", ringBits);
                }
                memset(g_vaio.scratchIn, 0,
                       (size_t)framesToProcess * ringChannels * sizeof(float));
            }
            userBytesRead += wholeInFrames * blockAlign;
            fracPhase = nextPhase;
        } else {
            // 无新音频或欠载：静音填充以维持 WASAPI 时钟平滑走动
            memset(g_vaio.scratchIn, 0,
                   (size_t)framesToProcess * ringChannels * sizeof(float));
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

        const int engineCh = (int)InterlockedCompareExchange((volatile LONG*)&g_vaio.engineChannels, 0, 0);
        const int safeEngineCh = (engineCh == 4 || engineCh == 6 || engineCh == 8) ? engineCh : 2;

        bool enginePathRan = false;
        if (g_vaio.userBypass) {
            // 用户旁路：直通，不跑 DSP
            RemapInterleavedAudio(g_vaio.scratchIn, (int)ringChannels, g_vaio.scratchOut, (int)wasapiChannels, (int)framesToProcess);
        } else if (g_vaio.pEngine && g_vaio.fnProcess) {
            enginePathRan = true;
            // P3 静音门控（单组）：GATED 时整块写零、跳过 DSP；测试注入是
            // 信号、用户旁路已提前返回，两者都不门控。
            const bool gateOn = g_vaio.gate.enabled && g_vaio.tc.testKind == 0;
            if (gateOn && g_vaio.gate.Tick((float)curPeakIn, (long long)framesToProcess)) {
                memset(g_vaio.scratchOut, 0, (size_t)framesToProcess * wasapiChannels * sizeof(float));
                memset(g_vaio.scratchProcOut, 0, (size_t)framesToProcess * safeEngineCh * sizeof(float));
                if (g_vaio.gate.enabled) g_vaio.gate.NoteOutput(0.0f);
                g_vaio.peakOut = 0.0;
            } else {
                // 1. 将驱动环输入重映射至引擎工作声道数（消除声道步进错位）
                RemapInterleavedAudio(g_vaio.scratchIn, (int)ringChannels, g_vaio.scratchProcIn, safeEngineCh, (int)framesToProcess);

                // 2. 21 项音效链处理（交织 float32，严格按 safeEngineCh 步进）
                g_vaio.fnProcess(g_vaio.pEngine, g_vaio.scratchProcIn, g_vaio.scratchProcOut, (int)framesToProcess);

                // 3. 计算引擎真实输出峰值
                float curPeakOut = 0.0f;
                const int outSampleCount = (int)(framesToProcess * safeEngineCh);
                for (int s = 0; s < outSampleCount; ++s) {
                    float val = fabsf(g_vaio.scratchProcOut[s]);
                    if (val > curPeakOut) curPeakOut = val;
                }
                g_vaio.peakOut = (double)curPeakOut;
                // P3：记录引擎实际输出峰值，供下一块「尾音已衰完」判据（gated 时 0）。
                if (g_vaio.gate.enabled) g_vaio.gate.NoteOutput(curPeakOut);

                // 4. 将引擎输出重映射至 WASAPI 物理设备声道数
                RemapInterleavedAudio(g_vaio.scratchProcOut, safeEngineCh, g_vaio.scratchOut, (int)wasapiChannels, (int)framesToProcess);
            }
        } else {
            RemapInterleavedAudio(g_vaio.scratchIn, (int)ringChannels, g_vaio.scratchOut, (int)wasapiChannels, (int)framesToProcess);
        }

        // 旁路/无引擎路径只做了重映射：峰值与门控尾音仍须按最终输出更新，
        // 否则电平表会停在上一块的值、门控「尾音已衰完」判据也会失真。
        if (!enginePathRan) {
            float curPeakOut = 0.0f;
            const int outSampleCount = (int)(framesToProcess * wasapiChannels);
            for (int s = 0; s < outSampleCount; ++s) {
                const float val = fabsf(g_vaio.scratchOut[s]);
                if (val > curPeakOut) curPeakOut = val;
            }
            g_vaio.peakOut = (double)curPeakOut;
            if (g_vaio.gate.enabled) g_vaio.gate.NoteOutput(curPeakOut);
        }

        QueryPerformanceCounter(&t1);
        double pumpUs = (double)(t1.QuadPart - t0.QuadPart) * qpcToUs;
        if (pumpUs > g_vaio.maxPumpUs) g_vaio.maxPumpUs = pumpUs;

        // 写入 WASAPI 物理输出缓冲区
        BYTE* pDst = nullptr;
        hr = g_vaio.pRenderClient->GetBuffer(framesToProcess, &pDst);
        if (SUCCEEDED(hr) && pDst) {
            // 写侧与读侧对称（§1.2）：物理端点混音格式为 PCM 时
            // 必须转换，直接灌 float 字节是同一类格式误读。
            const int outSamples = (int)(framesToProcess * wasapiChannels);
            if (outIsFloat) {
                memcpy(pDst, g_vaio.scratchOut, (size_t)outSamples * sizeof(float));
            } else if (outBits == 16) {
                int16_t* d = reinterpret_cast<int16_t*>(pDst);
                for (int s = 0; s < outSamples; ++s) {
                    float v = g_vaio.scratchOut[s];
                    if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
                    d[s] = (int16_t)(v * 32767.0f);
                }
            } else {  // PCM 32
                int32_t* d = reinterpret_cast<int32_t*>(pDst);
                for (int s = 0; s < outSamples; ++s) {
                    double v = (double)g_vaio.scratchOut[s];
                    if (v > 1.0) v = 1.0; else if (v < -1.0) v = -1.0;
                    d[s] = (int32_t)(v * 2147483647.0);
                }
            }
            g_vaio.pRenderClient->ReleaseBuffer(framesToProcess, 0);
            // 帧数只计成功写出（细审 R-B 8）：旧实现在
            // GetBuffer 失败轮照常累加，frames 增长会掩盖
            // 端点半死状态、削弱 status 取证。
            g_vaio.totalPumpedFrames += framesToProcess;
            renderFailRounds = 0; // 健康轮：死亡核算清零
        } else {
            // GetBuffer 失败计入死亡核算：端点半死时 padding
            // 可读而写路全灭，正是要判出的形态（细审 R-B 1）。
            renderFailRounds++;
            if (FAILED(hr)) lastRenderHr = hr;
            if (renderFailRounds >= 400) {
                snprintf(g_vaio.note, sizeof(g_vaio.note),
                         "wasapi-output-lost: 0x%08lX", lastRenderHr);
                InterlockedExchange(&g_vaio.running, 0);
                break;
            }
        }
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
        char epNameEsc[1024] = {0};
        EscapeJsonA(endpoints[i].first, epNameEsc, sizeof(epNameEsc));
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
    g_vaio.countMode = 0;
    g_vaio.manualChannels = 2;
    g_vaio.engineChannels = 2;
    g_pluginMirror.Reset();  // 新会话：等 App 侧 start 后按当前会话重放

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
    // 工作几何以 MAP 应答的内核真值为准（第四轮项 3 / DRV-03 口径）：
    // 此前读共享头副本——头由内核在格式变更时同锁同写、实践中不
    // 分歧，但应答是 IOCTL 当场从内核全局读出的权威值；头字段留
    // 档进 hdr* 供 status 对照，应答缺字段时仍回落头值/常数。
    g_vaio.hdrChannels = g_vaio.pRingHeader->Channels;
    g_vaio.hdrSampleRate = g_vaio.pRingHeader->SampleRate;
    g_vaio.hdrBits = g_vaio.pRingHeader->BitsPerSample;
    g_vaio.ringDataSize = mapResp.DataSizeBytes ? mapResp.DataSizeBytes
                                                 : g_vaio.pRingHeader->DataSizeBytes;
    g_vaio.ringChannels = mapResp.Channels ? mapResp.Channels
                                           : (g_vaio.hdrChannels ? g_vaio.hdrChannels : 2);
    g_vaio.ringSampleRate = mapResp.SampleRate
                                ? mapResp.SampleRate
                                : (g_vaio.hdrSampleRate ? g_vaio.hdrSampleRate : 48000);
    g_vaio.ringBits = mapResp.BitsPerSample
                          ? mapResp.BitsPerSample
                          : (g_vaio.hdrBits ? g_vaio.hdrBits : 32);
    g_vaio.ringBlockAlign = mapResp.BlockAlign
                                ? mapResp.BlockAlign
                                : (g_vaio.pRingHeader->BlockAlign
                                       ? g_vaio.pRingHeader->BlockAlign
                                       : (g_vaio.ringChannels * (g_vaio.ringBits == 16 ? sizeof(int16_t) : sizeof(float))));

    // 3. 动态加载 auradsp_engine.dll
    std::wstring used;
    const std::string hint = (engine_dll && *engine_dll) ? engine_dll : "";
    g_vaio.hEngineMod = vmcore::TryLoadEngine(hint, used);
    if (!used.empty()) g_vaio.enginePath = used;

    FnEngAbi engAbiFn = nullptr;
    unsigned engAbi = 0;
    if (g_vaio.hEngineMod) {
        g_vaio.fnCreate = (FnEngCreate)GetProcAddress(g_vaio.hEngineMod, "auradsp_create");
        g_vaio.fnProcess = (FnEngProcess)GetProcAddress(g_vaio.hEngineMod, "auradsp_process");
        g_vaio.fnDestroy = (FnEngDestroy)GetProcAddress(g_vaio.hEngineMod, "auradsp_destroy");
        g_vaio.fnSetParam = (FnEngSetParam)GetProcAddress(g_vaio.hEngineMod, "auradsp_set_param");
        g_vaio.fnGetParam = (FnEngGetParam)GetProcAddress(g_vaio.hEngineMod, "auradsp_get_param");
        g_vaio.fnVizRead = (FnEngVizRead)GetProcAddress(g_vaio.hEngineMod, "auradsp_viz_read");
        // [PATCHED-AuraDSP P-028 §7-2] 加载后强校验引擎 ABI（auradsp_abi 缺失也算不兼容）
        engAbiFn = (FnEngAbi)GetProcAddress(g_vaio.hEngineMod, "auradsp_abi");
        engAbi = engAbiFn ? engAbiFn() : 0;
        if (engAbiFn && engAbi != vmcore::kEngineAbiExpected)
            snprintf(g_vaio.note, sizeof(g_vaio.note),
                     "engine-abi-mismatch: bridge=%u engine=%u",
                     vmcore::kEngineAbiExpected, engAbi);
        g_pluginFns.Resolve(g_vaio.hEngineMod);
    }

    if (!g_vaio.hEngineMod || !g_vaio.fnCreate || !g_vaio.fnProcess ||
        !g_vaio.fnDestroy || !engAbiFn || engAbi != vmcore::kEngineAbiExpected) {
        if (!engAbiFn || engAbi == vmcore::kEngineAbiExpected)
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

    // 混音格式分类（§1.2 写侧）：共享模式常见 float32 或 PCM16/32；
    // EXTENSIBLE 时真子格式在 SubFormat GUID——其 Data1 即 WAVE
    // 格式标签（1=PCM、3=IEEE float），尾部为固定 WAVE 子格式
    // 后缀。不支持的格式在启动期明确失败，不再带病灌字节。
    {
        const WAVEFORMATEX* fmt = g_vaio.pMixFormat;
        DWORD subTag = 0;
        if (fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
            fmt->cbSize >= (WORD)(sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX))) {
            const WAVEFORMATEXTENSIBLE* ext =
                reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(fmt);
            static const BYTE kWaveTail[8] = {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71};
            if (ext->SubFormat.Data2 == 0 && ext->SubFormat.Data3 == 0x0010 &&
                memcmp(ext->SubFormat.Data4, kWaveTail, 8) == 0) {
                subTag = ext->SubFormat.Data1;
            }
        }
        const DWORD tag = subTag ? subTag : (DWORD)fmt->wFormatTag;
        const WORD bits = fmt->wBitsPerSample;
        bool okFmt = true;
        if (tag == WAVE_FORMAT_IEEE_FLOAT && bits == 32) {
            g_vaio.wasapiIsFloat = true;
            g_vaio.wasapiBits = 32;
        } else if (tag == WAVE_FORMAT_PCM && (bits == 16 || bits == 32)) {
            g_vaio.wasapiIsFloat = false;
            g_vaio.wasapiBits = bits;
        } else {
            okFmt = false;
        }
        if (!okFmt) {
            snprintf(g_vaio.note, sizeof(g_vaio.note),
                     "wasapi-mix-format-unsupported: tag=0x%04lX bits=%u",
                     (unsigned long)tag, (unsigned)bits);
            UnmapAndCloseRing();
            DestroyEngine();
            DestroyWasapi();
            g_vaio.startRc = -13;
            return -13;
        }
    }

    REFERENCE_TIME bufferDuration = 200000; // 20ms
    /* D3：事件驱动。缓冲只有 20ms，而 Sleep(1)/Sleep(2) 的实际唤醒粒度是
     * 1~15.6ms —— 睡过头即欠载，且代码里看不出来。改为让 WASAPI 在每周期
     * 消费完时置位事件，唤醒延迟由音频引擎保证（见 vaio_pump_wait.h 的说明）。 */
    hr = g_vaio.pAudioClient->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
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

    /* 事件必须在 Start 之前挂上，否则 EVENTCALLBACK 模式 Initialize 后
     * 直接 Start 会失败（AUDCLNT_E_EVENTHANDLE_NOT_SET）。 */
    g_vaio.hAudioEvent = CreateEventW(nullptr, FALSE /*auto-reset*/, FALSE, nullptr);
    if (!g_vaio.hAudioEvent) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "create-audio-event-failed: %lu", GetLastError());
        UnmapAndCloseRing();
        DestroyEngine();
        DestroyWasapi();
        g_vaio.startRc = -9;
        return -9;
    }
    hr = g_vaio.pAudioClient->SetEventHandle(g_vaio.hAudioEvent);
    if (FAILED(hr)) {
        snprintf(g_vaio.note, sizeof(g_vaio.note), "set-event-handle-failed: 0x%08lX", hr);
        UnmapAndCloseRing();
        DestroyEngine();
        DestroyWasapi();  // 内含 CloseHandle(hAudioEvent)
        g_vaio.startRc = -10;
        return -10;
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

    const int32_t initCh = (int32_t)(g_vaio.ringChannels > 0 ? g_vaio.ringChannels : 2);
    SetEngineChannels(initCh);

    // 6. 预分配 RT 临时缓冲 (4096 帧 * 8 声道 float32)
    const size_t scratchBytes = (size_t)VaioBridgeCtl::kMaxFrames * 8 * sizeof(float);
    g_vaio.scratchIn = (float*)malloc(scratchBytes);
    g_vaio.scratchOut = (float*)malloc(scratchBytes);
    g_vaio.scratchProcIn = (float*)malloc(scratchBytes);
    g_vaio.scratchProcOut = (float*)malloc(scratchBytes);
    g_vaio.scratchRing = (float*)malloc(scratchBytes);
    g_vaio.scratchRaw = (BYTE*)malloc(scratchBytes);
    if (!g_vaio.scratchIn || !g_vaio.scratchOut || !g_vaio.scratchProcIn || !g_vaio.scratchProcOut ||
        !g_vaio.scratchRing || !g_vaio.scratchRaw) {
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
    memset(g_vaio.scratchProcIn, 0, scratchBytes);
    memset(g_vaio.scratchProcOut, 0, scratchBytes);
    memset(g_vaio.scratchRing, 0, scratchBytes);
    memset(g_vaio.scratchRaw, 0, scratchBytes);

    // 7. 应用初始参数
    ApplyParamsString(params_json);

    // 7.1 声道模式决议与同步：根据 countMode 决定实际生效的工作声道数
    if (g_vaio.countMode == 1) {
        const int32_t manCh = (g_vaio.manualChannels == 4 || g_vaio.manualChannels == 6 || g_vaio.manualChannels == 8)
                                  ? g_vaio.manualChannels : 2;
        SetEngineChannels(manCh);
    } else {
        const int32_t ringCh = (g_vaio.ringChannels > 0 ? (int32_t)g_vaio.ringChannels : 2);
        SetEngineChannels(ringCh);
    }

    // 7.2 镜像回放（第四轮项 3 取证修正）：原先紧跟 §7、在声道决议
    // 之前回放——多声道相关参数落在一个尚未定型的引擎上，与 Dart
    // 侧随后按会话顺序的有序重放叠加成「重启独有的三段式应用」，
    // 首次启动（镜像空）则没有这段。移到决议之后：声道先定型，
    // 镜像再应用；回放顺序与首启的差异面收敛到最窄。
    ReplayMirroredParams();

    // 8. 启动 RT 音频泵线程
    // P3：采样率已定稿，配置静音门控（AURADSP_GATE=0 时禁用）。
    g_vaio.gate.Configure(
        (long long)(g_vaio.wasapiSampleRate ? g_vaio.wasapiSampleRate
                                            : g_vaio.ringSampleRate));
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
    // 幂等退出仅当确无待拆对象（第四轮项 3 取证）：泵自判死时是
    // 它自己清的 running——此时 hPumpThread/pEngine/pAudioClient/
    // 环映射都还活着，旧逻辑在此早退会跳过全部拆解，下一次
    // vaio_start 在未释放的 WASAPI client 与引擎之上带病重建。
    // 线程已自退出时 WaitForSingleObject 立即返回，拆解安全。
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0) &&
        !g_vaio.hPumpThread && !g_vaio.pEngine && !g_vaio.pAudioClient &&
        !g_vaio.pMappedRing) {
        return 0;
    }

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
    char outEpEsc[1024] = {0};
    EscapeJsonA(g_vaio.outEndpointName, outEpEsc, sizeof(outEpEsc));
    char noteEsc[512] = {0};
    EscapeJsonA(g_vaio.note, noteEsc, sizeof(noteEsc));

    const bool isRunning = (InterlockedCompareExchange(&g_vaio.running, 0, 0) == 1);
    const LONG effEngCh = InterlockedCompareExchange((volatile LONG*)&g_vaio.engineChannels, 0, 0);
    const ULONG reportedCh = (effEngCh > 0 ? (ULONG)effEngCh : g_vaio.ringChannels);

    const int n = _snprintf_s(
        out, (size_t)cap, _TRUNCATE,
        "{\"running\":%s,\"frames\":%llu,\"sr\":%lu,\"channels\":%lu,\"bits\":%lu,\"ringSr\":%lu,\"ringCh\":%lu,\"hdrSr\":%lu,\"hdrCh\":%lu,\"hdrBits\":%lu,\"outCh\":%lu,\"outBits\":%lu,"
        "\"peakIn\":%.4f,\"peakOut\":%.4f,\"maxPumpUs\":%.2f,\"startRc\":%d,\"note\":\"%s\","
        "\"outputEndpoint\":\"%s\",\"engineOk\":%s,\"enginePath\":\"%s\","
        "\"paramsApplied\":%d,\"paramsFailed\":%d,\"bypass\":%ld,\"testKind\":%ld,"
        "\"gated\":%d,\"idleMs\":%lld}",
        isRunning ? "true" : "false",
        (unsigned long long)g_vaio.totalPumpedFrames,
        g_vaio.wasapiSampleRate ? g_vaio.wasapiSampleRate : g_vaio.ringSampleRate,
        reportedCh,
        g_vaio.ringBits,
        g_vaio.ringSampleRate,
        g_vaio.ringChannels,
        g_vaio.hdrSampleRate,
        g_vaio.hdrChannels,
        g_vaio.hdrBits,
        g_vaio.wasapiChannels,
        g_vaio.wasapiBits,
        g_vaio.peakIn,
        g_vaio.peakOut,
        g_vaio.maxPumpUs,
        g_vaio.startRc,
        noteEsc,
        outEpEsc,
        (g_vaio.pEngine != nullptr) ? "true" : "false",
        engPathEsc,
        g_vaio.paramsApplied,
        g_vaio.paramsFailed,
        InterlockedCompareExchange(&g_vaio.userBypass, 0, 0),
        InterlockedCompareExchange(&g_vaio.tc.testKind, 0, 0),
        (isRunning && g_vaio.gate.enabled && g_vaio.gate.gated) ? 1 : 0,
        g_vaio.gate.IdleMs()
    );

    if (n < 0 || n >= cap) return -1;
    return n;
}

int vaio_set_param(const char* id, int isFloat, const void* v4) {
    if (!id || !v4) return -1;
    MirrorSet(id, isFloat != 0, v4);

    if (strcmp(id, "channels.countMode") == 0) {
        const int32_t mode = (isFloat ? (int)*(const float*)v4 : *(const int32_t*)v4) ? 1 : 0;
        g_vaio.countMode = mode;
        if (mode == 0) {
            const int32_t ringCh = (g_vaio.ringChannels > 0 ? (int32_t)g_vaio.ringChannels : 2);
            SetEngineChannels(ringCh);
        } else {
            const int32_t manCh = (g_vaio.manualChannels == 4 || g_vaio.manualChannels == 6 || g_vaio.manualChannels == 8)
                                      ? g_vaio.manualChannels : 2;
            SetEngineChannels(manCh);
        }
        return 0;
    }

    if (strcmp(id, "channels.count") == 0) {
        const int32_t cnt = isFloat ? (int32_t)*(const float*)v4 : *(const int32_t*)v4;
        if (cnt == 2 || cnt == 4 || cnt == 6 || cnt == 8) {
            g_vaio.manualChannels = cnt;
            if (g_vaio.countMode == 1) {
                SetEngineChannels(cnt);
            }
            return 0;
        }
        return -1;
    }

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
    if (!id || !out4) return -1;
    if (strcmp(id, "channels.countMode") == 0) {
        if (isFloat) *(float*)out4 = (float)g_vaio.countMode;
        else *(int32_t*)out4 = g_vaio.countMode;
        return 0;
    }
    if (strcmp(id, "channels.count") == 0) {
        const int32_t c = (int32_t)InterlockedCompareExchange((volatile LONG*)&g_vaio.engineChannels, 0, 0);
        if (isFloat) *(float*)out4 = (float)c;
        else *(int32_t*)out4 = c;
        return 0;
    }
    if (!g_vaio.pEngine || !g_vaio.fnGetParam) return -1;
    return (g_vaio.fnGetParam(g_vaio.pEngine, id, out4, 4) == 0) ? 0 : -2;
}

int vaio_get_param_str(const char* id, char* out, int cap) {
    if (!id || !out || cap <= 0 || !g_vaio.pEngine || !g_vaio.fnGetParam) return -1;
    return g_vaio.fnGetParam(g_vaio.pEngine, id, out, (unsigned int)cap);
}

int vaio_viz_read(void* out1600, int count) {
    if (!out1600 || count <= 0 || !g_vaio.pEngine || !g_vaio.fnVizRead) return 0;
    const int n = g_vaio.fnVizRead(g_vaio.pEngine, out1600, count);
    if (n > 0) return n;
    // P3 收口：GATED 时不跑 process，引擎 ring 无新帧；补一帧合法静音帧。
    // 旁路/测试注入期间门控不 Tick（gated 可能是旧值），一律不补。
    if (!g_vaio.gate.enabled || !g_vaio.gate.gated) return 0;
    if (InterlockedCompareExchange(&g_vaio.userBypass, 0, 0)) return 0;
    if (InterlockedCompareExchange(&g_vaio.tc.testKind, 0, 0) != 0) return 0;
    const int effCh = (int)InterlockedCompareExchange((volatile LONG*)&g_vaio.engineChannels, 0, 0);
    return g_silentViz.Emit(out1600, 0, effCh > 0 ? effCh : (int)g_vaio.ringChannels);
}

// §7-2（P-028）桥 ABI 协商：返回桥编译所依据的引擎 ABI 版本（viz 帧布局代际）。
unsigned vaio_abi(void) { return vmcore::kEngineAbiExpected; }

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

// ---- 插件槽（单引擎）----
int vaio_plugin_slot_load(int slot, const char* path, const char* plugin_id) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    return auraplugin::SlotLoad(g_vaio.pEngine, g_pluginFns, g_pluginMirror,
                                slot, path, plugin_id);
}

int vaio_plugin_slot_unload(int slot) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    return auraplugin::SlotUnload(g_vaio.pEngine, g_pluginFns, g_pluginMirror,
                                  slot);
}

int vaio_plugin_slot_set_bypass(int slot, int bypass) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    return auraplugin::SlotSetBypass(g_vaio.pEngine, g_pluginFns,
                                     g_pluginMirror, slot, bypass);
}

int vaio_plugin_slot_get_bypass(int slot) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    if (!g_vaio.pEngine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.getBypass(g_vaio.pEngine, slot);
}

unsigned vaio_plugin_slot_get_latency(int slot) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    if (!g_vaio.pEngine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.getLatency(g_vaio.pEngine, slot);
}

int vaio_plugin_slot_get_status(int slot, char* out, int cap) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) {
        if (out && cap > 0) out[0] = 0;
        return 0;
    }
    return auraplugin::SlotGetStatus(g_vaio.pEngine, g_pluginFns, slot, out,
                                     cap);
}

int vaio_plugin_slot_show_editor(int slot, const char* title) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    if (!g_vaio.pEngine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.showEditor(g_vaio.pEngine, slot, title);
}

int vaio_plugin_slot_close_editor(int slot) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    if (!g_vaio.pEngine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.closeEditor(g_vaio.pEngine, slot);
}

int vaio_plugin_slot_is_editor_open(int slot) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    if (!g_vaio.pEngine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.isEditorOpen(g_vaio.pEngine, slot);
}

int vaio_plugin_slot_save_preset(int slot, const char* path) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    if (!g_vaio.pEngine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.savePreset(g_vaio.pEngine, slot, path);
}

int vaio_plugin_slot_load_preset(int slot, const char* path) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    if (!g_vaio.pEngine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.loadPreset(g_vaio.pEngine, slot, path);
}

int vaio_plugin_slot_set_insert_stage(int slot, int stage) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    return auraplugin::SlotSetStage(g_vaio.pEngine, g_pluginFns,
                                    g_pluginMirror, slot, stage);
}

int vaio_plugin_slot_get_insert_stage(int slot) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 3;
    if (!g_vaio.pEngine || !g_pluginFns.Ready()) return 3;
    return g_pluginFns.getStage(g_vaio.pEngine, slot);
}

int vaio_plugin_slot_set_channels(int slot, int channels) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0;
    return auraplugin::SlotSetChannels(g_vaio.pEngine, g_pluginFns,
                                       g_pluginMirror, slot, channels);
}

int vaio_plugin_slot_get_channels(int slot) {
    if (!InterlockedCompareExchange(&g_vaio.running, 0, 0)) return 0xFF;
    if (!g_vaio.pEngine || !g_pluginFns.Ready()) return 0xFF;
    return g_pluginFns.getChannels(g_vaio.pEngine, slot);
}

// ---- P5 统一桥契约（ab_*）：旧前缀过渡转发，见 bridge/common/aurabridge.h ----
// VAIO 的物理输出端点子串经 config_json 归一（旧 App 仍走 vaio_start）。
#include "aurabridge.h"

static int AbStartAdapt(const char* engine_dll, const char* params_json,
                        const char* config_json) {
    char ep[512];
    abcfg::StrInto(config_json, "endpoint", ep, (int)sizeof(ep), "");
    return vaio_start(engine_dll, params_json, ep);
}
#define AB_LEGACY vaio
#define AB_CAPS_JSON                        \
    "{\"bridge\":\"vaio\",\"busGroups\":1," \
    "\"pluginGroups\":1,\"autoProtect\":false,\"gating\":true," \
    "\"endpoints\":true}"
#include "aurabridge_impl.h"
