// apo_engine_test.cpp — System APO 真处理端到端冒烟（设计 P4/D10）
//
// 不进 audiodg：进程内 COM 直驱 CAuraApo（DllGetClassObject 路
// 径，同 apo_selftest），但验证的是 v2 真处理全链：
//   锁定 → 座位被本进程抢到（telemetry）→ 基线块（默认参数）
//   → 经参数块发布 input.gain=-12dB（扮演 App 发布者，seqlock
//   协议）→ 输出 RMS 相对基线跌到 ~0.25（决定性断言：参数通
//   道 + worker 应用 + 引擎真处理三段同时成立才可能）→
//   telemetry 的 paramsApplied/updateSeq/spectrum 均在动 →
//   增益恢复 0dB 后经插件块装 probe_gain.clap（Part I Q2）：
//   telemetry v3 loaded=1、处理比率 ~0.5、块内旁路回 ~1.0、
//   身份清空卸载 → INPLACE 同址处理同样成立 → 解锁后座位释放。
// Global\ 需 SeCreateGlobalPrivilege：无特权时自动切
// AURAAPO_CHANNELS_LOCAL=1 走 Local\ 名（与心跳 LOCAL 旋钮同
// 先例；名字不同、协议相同）。退出码即裁定（0=全过）。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <audioenginebaseapo.h>
#include <audiomediatype.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>

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

#include "ApoParamIndex.h"
#include "ApoShared.h"
#include "AuraApoGuid.h"

namespace {

int g_fail = 0;
void check(const char* name, bool ok, const char* detail = "") {
    printf("[%s] %s %s\n", ok ? "PASS" : "FAIL", name, detail);
    fflush(stdout);
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
    bool found = false;
    if (LookupPrivilegeValueW(nullptr, L"SeCreateGlobalPrivilege", &luid) &&
        GetTokenInformation(tok, TokenPrivileges, &priv, sizeof(priv), &size)) {
        for (DWORD i = 0; i < priv.cnt; ++i) {
            if (priv.attrs[i].Luid.HighPart == luid.HighPart &&
                priv.attrs[i].Luid.LowPart == luid.LowPart &&
                (priv.attrs[i].Attributes & SE_PRIVILEGE_ENABLED)) {
                found = true;
                break;
            }
        }
    }
    CloseHandle(tok);
    return found;
}

double Rms(const float* b, int n) {
    double acc = 0;
    for (int i = 0; i < n; i++) acc += (double)b[i] * b[i];
    return sqrt(acc / n);
}

void FillSine(float* b, int frames, int startIdx) {
    for (int i = 0; i < frames; i++) {
        float s = (float)(0.2 * sin(2 * 3.14159265358979 * 440.0 *
                                    (startIdx + i) / 48000.0));
        b[i * 2] = s;
        b[i * 2 + 1] = s;
    }
}

}  // namespace

int main() {
    const bool local = !HasGlobalPrivilege();
    if (local) {
        SetEnvironmentVariableA("AURAAPO_CHANNELS_LOCAL", "1");
        printf("note: no SeCreateGlobalPrivilege, channels via Local\\ names\n");
    }
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {
        check("CoInitializeEx", false);
        return 1;
    }
    // AuraApo.dll：exe 同目录加载。
    wchar_t self[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    wchar_t* slash = wcsrchr(self, L'\\');
    wcscpy(slash ? slash + 1 : self, L"AuraApo.dll");
    HMODULE dll = LoadLibraryW(self);
    check("LoadLibrary AuraApo.dll", dll != nullptr);
    if (!dll) return 1;
    using GetClassFn = HRESULT(__stdcall*)(REFCLSID, REFIID, void**);
    auto getClass = (GetClassFn)GetProcAddress(dll, "DllGetClassObject");
    IClassFactory* factory = nullptr;
    HRESULT hr = getClass ? getClass(CLSID_AuraApoEfx, IID_IClassFactory,
                                     (void**)&factory)
                          : E_FAIL;
    check("DllGetClassObject", SUCCEEDED(hr) && factory);
    if (!factory) return 1;
    IUnknown* unk = nullptr;
    hr = factory->CreateInstance(nullptr, IID_IUnknown, (void**)&unk);
    factory->Release();
    check("CreateInstance", SUCCEEDED(hr) && unk);
    if (!unk) return 1;
    IAudioProcessingObject* apo = nullptr;
    IAudioProcessingObjectRT* rt = nullptr;
    IAudioProcessingObjectConfiguration* cfg = nullptr;
    unk->QueryInterface(IID_IAudioProcessingObject, (void**)&apo);
    unk->QueryInterface(IID_IAudioProcessingObjectRT, (void**)&rt);
    unk->QueryInterface(IID_IAudioProcessingObjectConfiguration, (void**)&cfg);
    check("QI apo/rt/cfg", apo && rt && cfg);
    if (!apo || !rt || !cfg) return 1;
    check("Initialize", apo->Initialize(0, nullptr) == S_OK);

    UNCOMPRESSEDAUDIOFORMAT uf{};
    uf.guidFormatType = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    uf.dwSamplesPerFrame = 2;
    uf.dwBytesPerSampleContainer = 4;
    uf.dwValidBitsPerSample = 32;
    uf.fFramesPerSecond = 48000.0f;
    uf.dwChannelMask = 3;
    IAudioMediaType* fmt = nullptr;
    check("CreateAudioMediaType",
          CreateAudioMediaTypeFromUncompressedAudioFormat(&uf, &fmt) == S_OK && fmt);
    if (!fmt) return 1;
    APO_CONNECTION_DESCRIPTOR inDesc{}, outDesc{};
    inDesc.pFormat = fmt;
    inDesc.u32MaxFrameCount = 512;
    outDesc = inDesc;
    APO_CONNECTION_DESCRIPTOR* pins[1] = {&inDesc};
    APO_CONNECTION_DESCRIPTOR* pouts[1] = {&outDesc};
    check("LockForProcess", cfg->LockForProcess(1, pins, 1, pouts) == S_OK);

    // telemetry：座位应已被本进程（宿主进程）的 APO 实例抢到。
    HANDLE hTele = OpenFileMappingW(FILE_MAP_READ, FALSE, AuraApoTelemetryName());
    check("telemetry mapping exists", hTele != nullptr);
    const ApoTelemetryBlock* tele = nullptr;
    if (hTele) {
        tele = (const ApoTelemetryBlock*)MapViewOfFile(
            hTele, FILE_MAP_READ, 0, 0, APO_TELEMETRY_BYTES);
    }
    check("telemetry view", tele != nullptr);
    if (tele) {
        char d[128];
        snprintf(d, sizeof(d), "seat=%ld pid=%lu sr=%lu ch=%lu fault=%lu",
                 tele->seatState, (unsigned long)tele->ownerPid,
                 (unsigned long)tele->sampleRate, (unsigned long)tele->channels,
                 (unsigned long)tele->fault);
        check("seat claimed by this process",
              tele->seatState == 1 && tele->ownerPid == GetCurrentProcessId() &&
                  tele->sampleRate == 48000 && tele->channels == 2 &&
                  tele->fault == 0,
              d);
    }

    // 音频脚手架：16 块 × 512 帧正弦，RMS 取后 8 块（避链路瞬态）。
    const int kBlocks = 16, kFrames = 512;
    static float inBuf[kFrames * 2], outBuf[kFrames * 2];
    APO_CONNECTION_PROPERTY inProp{}, outProp{};
    inProp.pBuffer = (UINT_PTR)inBuf;
    inProp.u32ValidFrameCount = kFrames;
    inProp.u32BufferFlags = BUFFER_VALID;
    outProp.pBuffer = (UINT_PTR)outBuf;
    APO_CONNECTION_PROPERTY* pinProps[1] = {&inProp};
    APO_CONNECTION_PROPERTY* poutProps[1] = {&outProp};
    auto runBlocks = [&](int fromBlock, double& rmsOut) {
        double acc = 0;
        int cnt = 0;
        for (int b = 0; b < kBlocks; b++) {
            FillSine(inBuf, kFrames, (fromBlock + b) * kFrames);
            memset(outBuf, 0, sizeof(outBuf));
            rt->APOProcess(1, pinProps, 1, poutProps);
            if (b >= kBlocks / 2) {
                acc += Rms(outBuf, kFrames * 2);
                cnt++;
            }
        }
        rmsOut = acc / cnt;
    };
    const double rmsIn = 0.2 / sqrt(2.0);
    double baseRms = 0;
    runBlocks(0, baseRms);
    {
        char d[96];
        snprintf(d, sizeof(d), "base=%.4f in=%.4f ratio=%.3f", baseRms, rmsIn,
                 baseRms / rmsIn);
        check("baseline processed (defaults, near unity)",
              baseRms / rmsIn > 0.7 && baseRms / rmsIn < 1.35, d);
    }

    // 扮演 App 发布者：input.gain=-12dB ≈ ×0.2512（该参数单位
    // 是 dB、量程 ±15——首跑实测 +0.25dB 得比率 1.030 与理论
    // 10^(0.25/20)=1.029 吻合，通道无恙、探针语义曾错）。
    int gainIdx = -1;
    for (uint32_t i = 0; i < APO_NUM_PARAM_COUNT; i++) {
        if (strcmp(kApoNumParamIds[i], "input.gain") == 0) {
            gainIdx = (int)i;
            break;
        }
    }
    check("input.gain in generated table", gainIdx >= 0);
    HANDLE hPar = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, AuraApoParamsName());
    check("params mapping exists (created by APO host)", hPar != nullptr);
    if (hPar && gainIdx >= 0) {
        auto* blk = (uint8_t*)MapViewOfFile(hPar, FILE_MAP_ALL_ACCESS, 0, 0,
                                            APO_BLOCK_MAPPING_BYTES);
        check("params view", blk != nullptr);
        if (blk) {
            auto* hdr = (ApoParamBlockHeader*)blk;
            if (hdr->magic != APO_PARAMS_MAGIC) {
                hdr->magic = APO_PARAMS_MAGIC;
                hdr->version = APO_PARAMS_VERSION;
                hdr->numCount = APO_NUM_PARAM_COUNT;
            }
            uint32_t seq = hdr->writeSeq;
            hdr->writeSeq = seq + 1;  // 奇：写入中
            blk[APO_BLOCK_MASK_OFFSET + gainIdx / 8] |=
                (uint8_t)(1u << (gainIdx % 8));
            float g = -12.0f;
            memcpy(blk + APO_BLOCK_VALUES_OFFSET + 4 * gainIdx, &g, 4);
            MemoryBarrier();
            hdr->writeSeq = seq + 2;  // 偶：稳定
            UnmapViewOfFile(blk);
        }
        CloseHandle(hPar);
    }
    Sleep(500);  // worker 50ms 轮询：应用 + viz 泵均须在此窗内发生

    double gainRms = 0;
    runBlocks(kBlocks, gainRms);
    {
        char d[96];
        snprintf(d, sizeof(d), "gained=%.4f base=%.4f ratio=%.3f", gainRms,
                 baseRms, gainRms / baseRms);
        check("DECISIVE: input.gain -12dB applied via param channel",
              gainRms / baseRms > 0.19 && gainRms / baseRms < 0.31, d);
    }
    if (tele) {
        double specSum = 0;
        for (float v : tele->spectrum) specSum += v;
        char d[128];
        snprintf(d, sizeof(d), "applied=%lu seq=%lu specSum=%.2f fault=%lu",
                 (unsigned long)tele->paramsApplied,
                 (unsigned long)tele->updateSeq, specSum,
                 (unsigned long)tele->fault);
        check("telemetry live (applied/viz/spectrum)",
              tele->paramsApplied >= 1 && tele->updateSeq > 0 && specSum > 0 &&
                  tele->fault == 0,
              d);
    }

    // ---- Part I Q2 插件段：经插件块装真 CLAP 插件 ----
    // 先把 input.gain 恢复 0dB 取干净基线，再扮演发布者把
    // probe_gain.clap 的身份写进插件块：worker 应加载它
    // （telemetry v3 loaded=1）、处理比率 ~0.5、块内旁路后
    // 回 ~1.0、身份清空后卸载。探针文件缺席时整段跳过（本机
    // 无构建产物时不误判；CI J5b 由 apo_probe_gain 目标供货）。
    {
        HANDLE hPar2 = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE,
                                        AuraApoParamsName());
        if (hPar2 && gainIdx >= 0) {
            auto* blk = (uint8_t*)MapViewOfFile(
                hPar2, FILE_MAP_ALL_ACCESS, 0, 0, APO_BLOCK_MAPPING_BYTES);
            if (blk) {
                auto* hdr = (ApoParamBlockHeader*)blk;
                uint32_t seq = hdr->writeSeq;
                hdr->writeSeq = seq + 1;
                float g = 0.0f;
                memcpy(blk + APO_BLOCK_VALUES_OFFSET + 4 * gainIdx, &g, 4);
                MemoryBarrier();
                hdr->writeSeq = seq + 2;
                UnmapViewOfFile(blk);
            }
            CloseHandle(hPar2);
        }
        Sleep(400);
        double unityRms = 0;
        runBlocks(2 * kBlocks, unityRms);
        char d[96];
        snprintf(d, sizeof(d), "unity=%.4f base=%.4f ratio=%.3f", unityRms,
                 baseRms, unityRms / baseRms);
        check("gain restored to unity", unityRms / baseRms > 0.85 &&
                                            unityRms / baseRms < 1.18,
              d);

        wchar_t plugPath[MAX_PATH];
        wcscpy(plugPath, self);
        wchar_t* pslash = wcsrchr(plugPath, L'\\');
        wcscpy(pslash ? pslash + 1 : plugPath, L"probe_gain.clap");
        const bool haveProbe =
            GetFileAttributesW(plugPath) != INVALID_FILE_ATTRIBUTES;
        if (!haveProbe) {
            printf("[SKIP] plugin section (probe_gain.clap absent)\n");
        } else {
            HANDLE hPlug = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE,
                                            AuraApoPluginsName());
            check("plugin mapping exists (created by APO host)",
                  hPlug != nullptr);
            uint8_t* pb = hPlug ? (uint8_t*)MapViewOfFile(
                                      hPlug, FILE_MAP_ALL_ACCESS, 0, 0,
                                      APO_PLUGIN_BLOCK_BYTES)
                                : nullptr;
            check("plugin view", pb != nullptr);
            if (pb) {
                auto* phdr = (ApoPluginBlockHeader*)pb;
                if (phdr->magic != APO_PLUGINS_MAGIC) {
                    phdr->magic = APO_PLUGINS_MAGIC;
                    phdr->version = APO_PLUGINS_VERSION;
                    phdr->blockBytes = APO_PLUGIN_BLOCK_BYTES;
                    phdr->chainEnabled = 1;
                    phdr->pdcEnabled = 0;
                    phdr->writeSeq = 0;
                }
                auto* slotHdr = (ApoPluginSlotHeader*)(pb +
                    APO_PLUGIN_BLOCK_HEADER_BYTES);
                uint8_t* pathReg = pb + APO_PLUGIN_BLOCK_HEADER_BYTES +
                                   APO_PLUGIN_SLOT_HEADER_BYTES;
                uint8_t* idReg = pathReg + APO_PLUGIN_PATH_BYTES;
                char pathU8[MAX_PATH * 3];
                int pn = WideCharToMultiByte(CP_UTF8, 0, plugPath, -1,
                                             pathU8, sizeof(pathU8),
                                             nullptr, nullptr);
                auto plugWrite = [&](auto&& body) {
                    uint32_t seq = phdr->writeSeq;
                    phdr->writeSeq = seq + 1;  // 奇：写入中
                    body();
                    MemoryBarrier();
                    phdr->writeSeq = seq + 2;  // 偶：稳定
                };
                // 身份发布：CLAP / stage 0 / 全声道 / 不旁路 / gen 1。
                plugWrite([&] {
                    memset(pathReg, 0, APO_PLUGIN_PATH_BYTES);
                    memcpy(pathReg, pathU8, (size_t)pn - 1);
                    memset(idReg, 0, APO_PLUGIN_ID_BYTES);
                    memcpy(idReg, "com.auradsp.probe.gain", 22);
                    slotHdr->format = 2;
                    slotHdr->insertStage = 0;
                    slotHdr->channelMask = 0xFF;
                    slotHdr->bypass = 0;
                    slotHdr->loadGen = 1;
                    slotHdr->stateGen = 0;
                    slotHdr->pathBytes = (uint32_t)pn - 1;
                    slotHdr->stateBytes = 0;
                });
                Sleep(800);  // worker 50ms 轮询 + 插件加载
                if (tele) {
                    char td[128];
                    snprintf(td, sizeof(td),
                             "ver=%lu loaded=%u gen=%lu calls=%lu",
                             (unsigned long)tele->version,
                             tele->plugins[0].loaded,
                             (unsigned long)tele->plugins[0].appliedLoadGen,
                             (unsigned long)tele->plugins[0].processCalls);
                    check("telemetry v3: plugin loaded via block",
                          tele->version >= 3 && tele->plugins[0].loaded == 1 &&
                              tele->plugins[0].appliedLoadGen == 1 &&
                              tele->plugins[0].fault == 0,
                          td);
                }
                double plugRms = 0;
                runBlocks(3 * kBlocks, plugRms);
                snprintf(d, sizeof(d), "plug=%.4f unity=%.4f ratio=%.3f",
                         plugRms, unityRms, plugRms / unityRms);
                check("DECISIVE: probe gain 0.5 via APO plugin hosting",
                      plugRms / unityRms > 0.4 && plugRms / unityRms < 0.6,
                      d);
                // 块内旁路（loadGen 不变）→ 回到 ~1.0。
                plugWrite([&] { slotHdr->bypass = 1; });
                Sleep(400);
                double bypRms = 0;
                runBlocks(4 * kBlocks, bypRms);
                snprintf(d, sizeof(d), "bypassed=%.4f ratio=%.3f", bypRms,
                         bypRms / unityRms);
                check("block bypass restores unity",
                      bypRms / unityRms > 0.85 && bypRms / unityRms < 1.18,
                      d);
                if (tele) {
                    check("telemetry: bypass effective",
                          tele->plugins[0].bypass == 1);
                }
                // 身份清空（gen 2）→ 卸载、telemetry loaded=0。
                plugWrite([&] {
                    slotHdr->format = 0;
                    slotHdr->pathBytes = 0;
                    slotHdr->loadGen = 2;
                });
                Sleep(500);
                if (tele) {
                    check("telemetry: plugin unloaded",
                          tele->plugins[0].loaded == 0 &&
                              tele->plugins[0].appliedLoadGen == 2);
                }
                UnmapViewOfFile(pb);
            }
            if (hPlug) CloseHandle(hPlug);
        }
    }

    // INPLACE 变体：同址缓冲处理结果一致（增益已恢复 0dB）。
    {
        static float inplaceBuf[kFrames * 2];
        FillSine(inplaceBuf, kFrames, 0);
        APO_CONNECTION_PROPERTY p{};
        p.pBuffer = (UINT_PTR)inplaceBuf;
        p.u32ValidFrameCount = kFrames;
        p.u32BufferFlags = BUFFER_VALID;
        APO_CONNECTION_PROPERTY* props[1] = {&p};
        // 先跑几块让链路状态与分块一致，再量一块。
        for (int b = 0; b < 4; b++) {
            FillSine(inplaceBuf, kFrames, b * kFrames);
            rt->APOProcess(1, props, 1, props);
        }
        FillSine(inplaceBuf, kFrames, 99 * kFrames);
        rt->APOProcess(1, props, 1, props);
        double r = Rms(inplaceBuf, kFrames * 2) / rmsIn;
        char d[96];
        snprintf(d, sizeof(d), "inplace ratio=%.3f (expect ~1.0)", r);
        check("in-place processing", r > 0.85 && r < 1.18, d);
    }

    check("UnlockForProcess", cfg->UnlockForProcess() == S_OK);
    if (tele) {
        check("seat released after unlock", tele->seatState == 0);
        UnmapViewOfFile(tele);
    }
    if (hTele) CloseHandle(hTele);
    rt->Release();
    cfg->Release();
    apo->Release();
    unk->Release();
    fmt->Release();
    CoUninitialize();
    printf("apo_engine_test: %s (%d failures)\n", g_fail ? "FAIL" : "PASS", g_fail);
    return g_fail ? 1 : 0;
}
