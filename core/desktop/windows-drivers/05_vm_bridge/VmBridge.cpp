// VmBridge.cpp — VB-Callback 持久桥实现。
//
// 线程模型（三线程，职责分离，沿用泵的无锁审计）：
// - VB RT 线程：OnVbCallback（零锁零分配；读 testKind/engines，只写自有计数）。
// - monitor 线程：CHANGE 重建（stop→rebuild→start）+ 退出事件等待。
// - Dart 线程：start/stop/set_param/test/viz/status（直接调，无一进 RT）。
// Login/Logout 与泵同式严格单次配对；OUT 槽被占（rc=1）直接返回 1 让 UI 提示。
#include "VmBridge.h"

#include "../02_voicemeeter_client/VmPumpCore.h"
#include "../02_voicemeeter_client/VmRemoteLoader.h"

#include <cstdio>
#include <cstring>

namespace {

void PathForJson(const std::string& in, char* out, size_t cap) {
    // JSON 字符串里反斜杠是转义符：路径统一转正斜杠（仅上报用）。
    size_t j = 0;
    for (size_t i = 0; i < in.size() && j + 1 < cap; ++i) {
        const char c = in[i];
        out[j++] = (c == '\\') ? '/' : c;
    }
    out[j] = '\0';
}

using vmcore::FnEngCreate;
using vmcore::FnEngDestroy;
using vmcore::FnEngProcess;
using vmcore::FnEngSetParam;
using vmcore::FnEngVizRead;
using vmcore::FnReg;
using vmcore::FnStart;
using vmcore::FnStop;
using vmcore::FnUnreg;
using vmcore::kModeOut;
using vmcore::PumpCtx;

struct BridgeCtl {
    HMODULE remote = nullptr;
    FnStart start = nullptr;
    FnStop stop = nullptr;
    FnUnreg unreg = nullptr;
    long(__stdcall* logout)() = nullptr;
    bool remoteFreed = false;
    HMODULE eng = nullptr;
    FnEngCreate create = nullptr;
    FnEngVizRead vizRead = nullptr;
    PumpCtx ctx;
    HANDLE monitor = nullptr;
    volatile LONG running = 0;
    volatile LONG stopEvent = 0;  // 置位即 monitor 退出
    int startRc = -99;
    int edition = 0;
    char note[128] = {};
    char enginePath[MAX_PATH * 2] = {};
    int paramsApplied = 0;
    int paramsFailed = 0;
};

BridgeCtl g_b;

void LeaveCtl(bool andUnreg) {
    if (g_b.logout) g_b.logout();
    if (andUnreg && g_b.unreg) g_b.unreg();
    if (!g_b.remoteFreed && g_b.remote) {
        g_b.remoteFreed = true;
        FreeLibrary(g_b.remote);
    }
    g_b.remote = nullptr;
}

void DestroyEngines() {
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g] && g_b.ctx.destroy) g_b.ctx.destroy(g_b.ctx.eng[g]);
        g_b.ctx.eng[g] = nullptr;
    }
    g_b.ctx.nEng = 0;
}

void RebuildEngines(int groups) {
    DestroyEngines();
    const float sr = g_b.ctx.sr > 0 ? (float)g_b.ctx.sr : 48000.0f;
    if (g_b.create) {
        for (int g = 0; g < groups; ++g) {
            g_b.ctx.eng[g] = g_b.create(sr, 2048);
            if (g_b.ctx.eng[g]) ++g_b.ctx.nEng;
        }
    }
    if (g_b.ctx.nEng == 0 || !g_b.ctx.scratchIn || !g_b.ctx.scratchOut) {
        DestroyEngines();
        g_b.ctx.process = nullptr;
    }
}

// "id=f1.5;gain=i3" 解析并下发全部 handle（主线程/Dart 线程，无 RT 约束）。
void ApplyParamsString(const char* s) {
    if (!s || !*s || !g_b.ctx.destroy) return;
    // NOTE：set_param 函数指针取自 ctx 构建期；此处经 eng 重查以兼容重建后句柄。
    HMODULE eng = g_b.eng;
    if (!eng) return;
    auto setParam = (FnEngSetParam)GetProcAddress(eng, "auradsp_set_param");
    if (!setParam) {
        ++g_b.paramsFailed;
        return;
    }
    char buf[4096] = {0};
    strncpy_s(buf, s, sizeof(buf) - 1);
    // strtok 单线程调用（Dart 线程串行进本函数，无重入问题）。
    for (char* tok = strtok(buf, ";"); tok != nullptr; tok = strtok(nullptr, ";")) {
        char* eq = strchr(tok, '=');
        if (!eq || eq == tok) {
            ++g_b.paramsFailed;
            continue;
        }
        *eq = '\0';
        const char* id = tok;
        const char* vs = eq + 1;
        bool okAll = g_b.ctx.nEng > 0;
        if (strchr(vs, '.') || strchr(vs, 'e') || strchr(vs, 'E')) {
            const float f = (float)atof(vs);
            for (int g = 0; g < g_b.ctx.nEng; ++g) {
                if (setParam(g_b.ctx.eng[g], id, &f, 4) != 0) {
                    okAll = false;
                    break;
                }
            }
        } else {
            const int32_t iv = (int32_t)atoi(vs);
            for (int g = 0; g < g_b.ctx.nEng; ++g) {
                if (setParam(g_b.ctx.eng[g], id, &iv, 4) != 0) {
                    okAll = false;
                    break;
                }
            }
        }
        if (okAll)
            ++g_b.paramsApplied;
        else
            ++g_b.paramsFailed;
    }
}

DWORD WINAPI MonitorProc(LPVOID) {
    // CHANGE 到达 → stop → 重建引擎 → start（泵同式；短暂断流可接受 v1）。
    while (!InterlockedCompareExchange(&g_b.stopEvent, 0, 0)) {
        if (InterlockedExchange(&g_b.ctx.pendingChange, 0) != 0) {
            ++g_b.ctx.changes;
            if (g_b.stop) g_b.stop();
            RebuildEngines(g_b.ctx.groups > 0 ? g_b.ctx.groups
                                              : PumpCtx::kMaxGroups);
            if (g_b.start) {
                if (g_b.start() != 0) break;
                g_b.ctx.gotFirst = 0;
            }
        }
        Sleep(200);
    }
    return 0;
}

void FreeTestFile() {
    // 先清 kind 让 RT 停用，再等在途回调退出（~10ms 量级），最后释放。
    InterlockedExchange(&g_b.ctx.testKind, 0);
    Sleep(50);
    if (g_b.ctx.testFile) {
        free((void*)g_b.ctx.testFile);
        g_b.ctx.testFile = nullptr;
    }
    g_b.ctx.testFrames = 0;
    g_b.ctx.testPos = 0;
}

}  // namespace

int vb_detect(char* out, int cap) {
    if (!out || cap <= 0) return -1;
    const AuraVmDetect d = AuraVmDetectRun();
    char dir[512] = {0}, eng[512] = {0};
    PathForJson(d.installDir, dir, sizeof(dir));
    int n = snprintf(out, (size_t)cap,
                     "{\"found\":%s,\"edition\":%d,\"editionName\":\"%s\","
                     "\"installDir\":\"%s\",\"appVersion\":\"%s\","
                     "\"remoteVersion\":\"%s\",\"tierReached\":%d}",
                     d.found ? "true" : "false", d.edition,
                     d.editionName.c_str(), dir, d.appVersion.c_str(),
                     d.remoteVersion.c_str(), d.tierReached);
    return (n >= 0 && n < cap) ? n : -1;
}

int vb_start(const char* engine_dll, const char* params_json) {
    if (InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;  // 已在跑：幂等成功
    memset(&g_b.ctx, 0, sizeof(g_b.ctx));
    g_b.paramsApplied = 0;
    g_b.paramsFailed = 0;
    g_b.note[0] = '\0';
    g_b.edition = 0;
    g_b.startRc = -99;
    g_b.stopEvent = 0;
    g_b.remoteFreed = false;  // 复位：上一轮 stop 已释放，本轮重新计数
    const wchar_t* dirs[2] = {
        L"C:\\Program Files (x86)\\VB\\Voicemeeter\\VoicemeeterRemote64.dll",
        L"C:\\Program Files\\VB\\Voicemeeter\\VoicemeeterRemote64.dll",
    };
    for (const wchar_t* d : dirs) {
        g_b.remote = LoadLibraryW(d);
        if (g_b.remote) break;
    }
    if (!g_b.remote) {
        snprintf(g_b.note, sizeof(g_b.note), "no-voicemeeter-remote-dll");
        return -1;
    }
    auto reg = (FnReg)GetProcAddress(g_b.remote, "VBVMR_AudioCallbackRegister");
    g_b.start = (FnStart)GetProcAddress(g_b.remote, "VBVMR_AudioCallbackStart");
    g_b.stop = (FnStop)GetProcAddress(g_b.remote, "VBVMR_AudioCallbackStop");
    g_b.unreg = (FnUnreg)GetProcAddress(g_b.remote, "VBVMR_AudioCallbackUnregister");
    auto login = (long(__stdcall*)())GetProcAddress(g_b.remote, "VBVMR_Login");
    g_b.logout = (long(__stdcall*)())GetProcAddress(g_b.remote, "VBVMR_Logout");
    if (!reg || !g_b.start || !g_b.stop || !g_b.unreg || !login || !g_b.logout) {
        snprintf(g_b.note, sizeof(g_b.note), "remote-api-missing");
        LeaveCtl(false);
        return -2;
    }
    login();
    char name[64] = {0};
    memcpy(name, "AuraDSP", 7);
    long rc = -99;
    for (int tries = 0; tries < 10; ++tries) {
        rc = reg(kModeOut, vmcore::OnVbCallback, &g_b.ctx, name);
        if (rc == 0 || rc == 1) break;
        Sleep(100);
    }
    g_b.startRc = (int)rc;
    if (rc == 1) {
        snprintf(g_b.note, sizeof(g_b.note), "out-slot-busy");
        LeaveCtl(true);
        return 1;
    }
    if (rc != 0) {
        snprintf(g_b.note, sizeof(g_b.note), "register-failed rc=%ld", rc);
        LeaveCtl(true);
        return -3;
    }
    {
        const AuraVmDetect det = AuraVmDetectRun();
        g_b.edition = det.edition;
    }
    std::wstring used;
    std::string hint = (engine_dll && *engine_dll) ? engine_dll : "";
    g_b.eng = vmcore::TryLoadEngine(hint, used);
    if (!used.empty()) {
        WideCharToMultiByte(CP_UTF8, 0, used.c_str(), -1, g_b.enginePath,
                            (int)sizeof(g_b.enginePath), nullptr, nullptr);
    }
    FnEngCreate create = nullptr;
    if (g_b.eng) {
        create =
            (FnEngCreate)GetProcAddress(g_b.eng, "auradsp_create");
        g_b.create = create;  // CHANGE 重建用；此前漏赋导致重建后零 handle 静默透传
        g_b.ctx.process =
            (FnEngProcess)GetProcAddress(g_b.eng, "auradsp_process");
        g_b.ctx.destroy =
            (FnEngDestroy)GetProcAddress(g_b.eng, "auradsp_destroy");
        g_b.vizRead =
            (FnEngVizRead)GetProcAddress(g_b.eng, "auradsp_viz_read");
        if (create && g_b.ctx.process && g_b.ctx.destroy) {
            g_b.ctx.scratchIn =
                (float*)malloc(sizeof(float) * 2 * vmcore::kMaxNbs);
            g_b.ctx.scratchOut =
                (float*)malloc(sizeof(float) * 2 * vmcore::kMaxNbs);
            int want = PumpCtx::kMaxGroups;
            if (g_b.edition == 1)
                want = 2;
            else if (g_b.edition == 2)
                want = 5;
            const float sr0 = 48000.0f;
            for (int g = 0; g < want; ++g) {
                g_b.ctx.eng[g] = create(sr0, 2048);
                if (g_b.ctx.eng[g]) ++g_b.ctx.nEng;
            }
            if (!g_b.ctx.scratchIn || !g_b.ctx.scratchOut ||
                g_b.ctx.nEng == 0) {
                DestroyEngines();
                g_b.ctx.process = nullptr;
            }
        }
        if (!g_b.ctx.process) {
            FreeLibrary(g_b.eng);
            g_b.eng = nullptr;
        }
    }
    ApplyParamsString(params_json);
    if (g_b.start() != 0) {
        snprintf(g_b.note, sizeof(g_b.note), "start-failed");
        DestroyEngines();
        LeaveCtl(true);
        return -4;
    }
    g_b.monitor = CreateThread(nullptr, 0, MonitorProc, nullptr, 0, nullptr);
    InterlockedExchange(&g_b.running, 1);
    return 0;
}

int vb_stop() {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;  // 幂等
    InterlockedExchange(&g_b.stopEvent, 1);
    if (g_b.monitor) {
        WaitForSingleObject(g_b.monitor, 3000);
        CloseHandle(g_b.monitor);
        g_b.monitor = nullptr;
    }
    if (g_b.stop) g_b.stop();
    FreeTestFile();
    DestroyEngines();
    if (g_b.ctx.scratchIn) free(g_b.ctx.scratchIn);
    if (g_b.ctx.scratchOut) free(g_b.ctx.scratchOut);
    g_b.ctx.scratchIn = g_b.ctx.scratchOut = nullptr;
    if (g_b.eng) {
        FreeLibrary(g_b.eng);
        g_b.eng = nullptr;
    }
    LeaveCtl(true);  // 单次配对：logout + unreg
    InterlockedExchange(&g_b.running, 0);
    return 0;
}

// viz 跟随当前最热组：信号可能不在 group0 总线上（用户路由决定），
// 只读 eng[0] 会在 group0 静默时永久空 viz，而别的组照常出声。
// 要件：跳过 idle 组（停产 viz 帧，峰值可能是衰减中的僵尸热）；全 idle 时
// 回落 0（诚实空 viz——对端确实无声）。调用方（status/viz）节流读取。
static int HottestVizGroup() {
    int best = 0;
    double bp = -1.0;
    for (int g = 0; g < vmcore::PumpCtx::kMaxGroups; ++g) {
        if (!g_b.ctx.eng[g]) continue;
        if (g_b.ctx.idle[g]) continue;  // 僵尸热组排除：在产帧的组里选
        const double p = g_b.ctx.peakGrp[g];
        if (p > bp) {
            bp = p;
            best = g;
        }
    }
    return best;
}

int vb_status(char* out, int cap) {
    if (!out || cap <= 0) return -1;
    LARGE_INTEGER qpf;
    double cbUs = 0;
    if (QueryPerformanceFrequency(&qpf) && qpf.QuadPart > 0)
        cbUs = (double)g_b.ctx.maxCbTicks * 1000000.0 / (double)qpf.QuadPart;
    char eng[512] = {0};
    PathForJson(g_b.enginePath, eng, sizeof(eng));
    const int vizGrp = HottestVizGroup();
    char peaks[256] = {0};
    snprintf(peaks, sizeof(peaks), "[%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f]",
             g_b.ctx.peakGrp[0], g_b.ctx.peakGrp[1], g_b.ctx.peakGrp[2],
             g_b.ctx.peakGrp[3], g_b.ctx.peakGrp[4], g_b.ctx.peakGrp[5],
             g_b.ctx.peakGrp[6], g_b.ctx.peakGrp[7]);
    int n = snprintf(out, (size_t)cap,
                     "{\"running\":%s,\"frames\":%llu,\"sr\":%ld,\"nbs\":%ld,"
                     "\"groups\":%d,\"handles\":%d,\"peakIn\":%.6f,"
                     "\"maxCbUs\":%.1f,\"startRc\":%d,\"note\":\"%s\","
                     "\"testKind\":%ld,\"bypass\":%ld,\"vizGrp\":%d,\"peakGrp\":%s,\"edition\":%d,\"engine\":\"%s\"}",
                      InterlockedCompareExchange(&g_b.running, 0, 0) ? "true"
                                                                     : "false",
                      (unsigned long long)g_b.ctx.frames, g_b.ctx.sr,
                      g_b.ctx.nbs, g_b.ctx.groups, g_b.ctx.nEng, g_b.ctx.peakIn,
                      cbUs, g_b.startRc, g_b.note, (long)g_b.ctx.testKind,
                      (long)g_b.ctx.userBypass, vizGrp, peaks,
                      g_b.edition, eng);
    // peakGrp 已在回调级衰减，此处不再动（避免与回调线程叠加衰减失真）。
    return (n >= 0 && n < cap) ? n : -1;
}

int vb_set_param(const char* id, int isFloat, const void* v4) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (!id || !v4 || !g_b.eng) return -2;
    auto setParam = (FnEngSetParam)GetProcAddress(g_b.eng, "auradsp_set_param");
    if (!setParam) return -3;
    int ok = 0;
    for (int g = 0; g < g_b.ctx.nEng; ++g) {
        if (g_b.ctx.eng[g] && setParam(g_b.ctx.eng[g], id, v4, 4) == 0) ++ok;
    }
    return ok;
}

int vb_viz_read(void* out408, int count) {
    if (!out408 || count <= 0) return -1;
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.vizRead) return 0;
    const int g = HottestVizGroup();
    if (!g_b.ctx.eng[g]) return 0;
    return g_b.vizRead(g_b.ctx.eng[g], out408, count);
}

int vb_test_start(int kind, const float* pcm, int frames, int ch, int rate) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (kind < 1 || kind > 3) return -2;
    FreeTestFile();
    if (kind == 3) {
        // 文件 PCM 拷贝（交织立体声 float32；单声道铺双声道）。
        if (!pcm || frames <= 0 || rate <= 0) return -3;
        const int srcCh = (ch == 1) ? 1 : 2;
        float* buf = (float*)malloc(sizeof(float) * (size_t)frames * 2);
        if (!buf) return -4;
        for (int i = 0; i < frames; ++i) {
            if (srcCh == 1) {
                buf[i * 2] = buf[i * 2 + 1] = pcm[i];
            } else {
                buf[i * 2] = pcm[i * 2];
                buf[i * 2 + 1] = pcm[i * 2 + 1];
            }
        }
        g_b.ctx.testFile = buf;
        g_b.ctx.testFrames = (uint64_t)frames;
        g_b.ctx.testRate = rate;
        g_b.ctx.testPos = 0;
    }
    g_b.ctx.testPhase = 0;
    g_b.ctx.testRng = 0x12345678u;
    for (int i = 0; i < 7; ++i) g_b.ctx.testPink[i] = 0;
    InterlockedExchange(&g_b.ctx.testKind, (LONG)kind);
    return 0;
}

int vb_test_stop() {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    FreeTestFile();
    return 0;
}

int vb_bypass(int on) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    InterlockedExchange(&g_b.ctx.userBypass, on ? 1 : 0);
    return 0;
}
