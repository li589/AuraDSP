// vaio_bridge_loopback_check.cpp — VAIO 桥端到端取证探针（环回录制 + 频谱判读）
//
// 出身：第十七轮（2026-11-12）为定罪「VAIO 输入 + WASAPI 输出白噪音」而写
// 的一次性探针（当时名 bridgecheck），七场取证全靠它，业主裁定归位入仓。
// 与 vaio_bridge_test.cpp 的分工：那个是「导出齐不齐、泵转不转」的冒烟；
// 本工具是「声音到底干不干净」的取证——向 AuraVAIO 端点送 1 kHz 正弦
// （或用桥内测试音），同时 WASAPI 环回录制落点端点的混音，落盘为
// float32 交织 raw，再用配套的 vaio_bridge_loopback_analyze.py 做
// Goertzel 频点/自相关分析：纯净正弦应 1 kHz 分量 ≈ 幅值、ac1 ≈ 0.99；
// 出现高频谐波簇 + ac1 转负 = 波形被破坏。
//
// 用法：vaio_bridge_loopback_check <桥DLL目录> <模式> [落点端点名子串] [输出目录]
//   模式：
//     tone     桥内测试音(kind 1) → 引擎 → 落点，本进程录制（6s）
//     driver   外部正弦灌入 AuraVAIO 端点（全驱动环路），本进程跑桥+录制（6s）
//     steps    同 driver，但在 3/8/13/18s 阶梯施加四组会话参数
//              （G1 基础 / G2 货架·空间·门 / G3 限制器+压缩+混响 / G4 eq.curve），
//              用于参数二分定罪（24s）
//     aged     桥先空转 90s 再来流（模拟 App 先启桥、用户后播放）（录 10s）
//     caponly  只录制（桥由外部进程驱动——如真实 AuraDSP App）（20s）
//     playonly 只灌正弦（配合 caponly 分进程跑）（150s）
//     chopplay 灌正弦但每 12s 停流 2s 再续（模拟播放器切歌），桥由外部驱动（120s）
//   落点端点名子串缺省时：录制取系统默认渲染端点，桥落点走桥内默认选择。
//   输出目录缺省为当前目录。
// 输出：vaio_bridge_loopback_check.raw（float32 交织，声道数 = 落点混音格式）
//       vaio_bridge_loopback_check_info.txt（格式 + 桥 status JSON）
//
// 构建（独立小工具，不进 CMake）：
//   cl /utf-8 /EHsc /O2 vaio_bridge_loopback_check.cpp /link ole32.lib uuid.lib avrt.lib
// 注意：录制/灌音都必须在交互会话中运行（会话 0 无音频端点）；
// steps 的四组参数值是第十七轮当时的会话快照，做其他二分时直接改表。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <string>

typedef int (*PFN_detect)(char*, int);
typedef int (*PFN_start)(const char*, const char*, const char*);
typedef int (*PFN_stop)();
typedef int (*PFN_status)(char*, int);
typedef int (*PFN_test_start)(int, const float*, int, int, int);
typedef int (*PFN_test_stop)();
typedef int (*PFN_set_param)(const char*, int, const void*);
typedef int (*PFN_set_param_str)(const char*, const char*, int);

struct ParamStep { const char* id; int isFloat; double v; };
static const ParamStep kG1[] = {
    {"input.gain",1,0.0},{"input.balance.1",1,1.0},{"input.balance.2",1,1.0},
    {"channels.mode",0,0},{"channels.upmix_fill",0,0},{"channels.countMode",0,0},
    {"bass.enable",0,0},{"bass.gain",1,0.0},{"bass.mode",0,0},
    {"stereo.mix",1,0.0},
    {"tube.enable",0,0},{"tube.gain",1,4.5},{"tube.style",0,0},{"tube.mix",1,1.0},
    {"tube.compensation",1,0.0},{"tube.oversample",0,1},
    {"crossfeed.enable",0,0},{"crossfeed.mode",0,0},{"crossfeed.fcut",1,700.0},
    {"crossfeed.feed",1,4.5},
};
static const ParamStep kG2[] = {
    {"shelf.enable",0,0},{"shelf.freq",1,100.0},{"shelf.gain",1,0.0},
    {"bassmono.enable",0,0},{"bassmono.freq",1,120.0},{"bassmono.pairs",0,1},
    {"bassmono.merge",0,0},
    {"haas.enable",0,0},{"haas.delay",1,12.0},{"haas.mix",1,1.0},{"haas.side",0,0},
    {"spatial.enable",0,0},{"spatial.style",0,0},{"spatial.outgain",1,0.0},
    {"spatial.autogain",0,0},{"spatial.mix",1,1.0},{"spatial.elevation",1,0.0},
    {"spatial.binaural",0,0},{"spatial.headazim",1,0.0},{"spatial.headtrack",0,0},
    {"exciter.enable",0,0},{"exciter.amount",1,0.3},{"exciter.hifreq",1,5000.0},
    {"exciter.oversample",0,1},
    {"bass.outgain",1,0.0},{"bass.autogain",0,0},{"eq.outgain",1,0.0},
    {"eq.autogain",0,0},{"tube.outgain",1,0.0},{"tube.autogain",0,0},
    {"comp.outgain",1,0.0},{"comp.autogain",0,0},{"comp.mode",0,0},
    {"reverb.outgain",1,0.0},{"reverb.autogain",0,0},
    {"gate.enable",0,0},{"gate.threshold",1,-40.0},{"gate.attack",1,10.0},
    {"gate.release",1,100.0},{"gate.hysteresis",1,3.0},{"gate.range",1,-60.0},
    {"gate.hold_ms",1,10.0},{"gate.autogain",0,0},
    {"deesser.enable",0,0},{"deesser.freq",1,6000.0},{"deesser.amount",1,0.5},
    {"dyneq.enable",0,0},
    {"loudness.enable",0,0},{"loudness.amount",1,0.5},
    {"bass.harmonics",1,0.45},{"bass.harmonicblend",1,0.5},{"bass.subfreq",1,25.0},
    {"bass.cutoff",1,120.0},
    {"filter.enable",0,0},{"filter.type",0,0},{"filter.freq",1,80.0},
    {"filter.q",1,0.707},
    {"arbmag.outgain",1,0.0},{"arbmag.autogain",0,0},
};
static const ParamStep kG3[] = {
    {"limiter.enable",0,1},{"limiter.release",1,100.0},
    {"limiter.threshold",1,-0.1},{"limiter.link",0,1},{"limiter.lookahead",0,0},
    {"post.gain",1,0.0},
    {"post.gain.c0",1,0.0},{"post.gain.c1",1,0.0},{"post.gain.c2",1,0.0},
    {"post.gain.c3",1,0.0},{"post.gain.c4",1,0.0},{"post.gain.c5",1,0.0},
    {"post.gain.c6",1,0.0},{"post.gain.c7",1,0.0},
    {"comp.enable",0,0},{"comp.threshold",1,-18.0},{"comp.ratio",1,4.0},
    {"comp.timeconstant",1,0.14},{"comp.granularity",0,1},{"comp.tfresolution",0,1},
    {"freeverb.decay",1,0.5},{"freeverb.damp",1,0.5},{"freeverb.wet",1,0.35},
    {"freeverb.dry",1,1.0},{"freeverb.roomsize",1,1.2},{"freeverb.width",1,1.0},
    {"reverb.predelay",1,0.0},{"reverb.lfe",0,0},{"reverb.preset",0,-1},
    {"eq.enable",0,0},{"convolver.mix",1,1.0},
};
static void ApplyGroup(PFN_set_param sp, const ParamStep* g, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (g[i].isFloat) { float v = (float)g[i].v; sp(g[i].id, 1, &v); }
        else { int v = (int)g[i].v; sp(g[i].id, 0, &v); }
    }
}

static std::wstring GetName(IMMDevice* dev) {
    IPropertyStore* ps = nullptr;
    std::wstring out;
    if (SUCCEEDED(dev->OpenPropertyStore(STGM_READ, &ps)) && ps) {
        PROPVARIANT v;
        PropVariantInit(&v);
        static const PROPERTYKEY kName = {{0xa45c254e, 0xdf1c, 0x4efd,
            {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};
        if (SUCCEEDED(ps->GetValue(kName, &v)) && v.vt == VT_LPWSTR)
            out = v.pwszVal;
        PropVariantClear(&v);
        ps->Release();
    }
    return out;
}

static IMMDevice* FindEndpoint(IMMDeviceEnumerator* en, const wchar_t* sub) {
    IMMDeviceCollection* col = nullptr;
    IMMDevice* found = nullptr;
    if (FAILED(en->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &col)) || !col)
        return nullptr;
    UINT n = 0;
    col->GetCount(&n);
    for (UINT i = 0; i < n; i++) {
        IMMDevice* d = nullptr;
        if (FAILED(col->Item(i, &d)) || !d) continue;
        std::wstring nm = GetName(d);
        if (nm.find(sub) != std::wstring::npos) { found = d; break; }
        d->Release();
    }
    col->Release();
    return found;
}

static bool FmtInfo(WAVEFORMATEX* f, bool& isFloat, int& bits, int& ch, int& rate) {
    DWORD tag = f->wFormatTag;
    if (tag == WAVE_FORMAT_EXTENSIBLE) {
        auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(f);
        tag = ext->SubFormat.Data1;
    }
    isFloat = (tag == WAVE_FORMAT_IEEE_FLOAT);
    bits = f->wBitsPerSample;
    ch = f->nChannels;
    rate = f->nSamplesPerSec;
    return isFloat || tag == WAVE_FORMAT_PCM;
}

struct ToneCtx {
    IAudioClient* client; IAudioRenderClient* render;
    volatile bool* run; bool isF; int bits, ch, rate;
    bool choppy = false;
};

static DWORD WINAPI ToneThread(LPVOID ctx) {
    auto* self = static_cast<ToneCtx*>(ctx);
    UINT32 bufFrames = 0;
    self->client->GetBufferSize(&bufFrames);
    self->client->Start();
    double phase = 0;
    const double step = 2.0 * 3.14159265358979 * 1000.0 / self->rate;
    DWORD cycleStart = GetTickCount();
    while (*self->run) {
        if (self->choppy && GetTickCount() - cycleStart > 12000) {
            // Simulate a player track change: stop the stream for 2 s,
            // then start it again (ring writes stop and resume).
            self->client->Stop();
            for (int i = 0; i < 20 && *self->run; i++) Sleep(100);
            if (!*self->run) break;
            self->client->Start();
            cycleStart = GetTickCount();
        }
        UINT32 pad = 0;
        self->client->GetCurrentPadding(&pad);
        UINT32 want = bufFrames > pad ? bufFrames - pad : 0;
        if (want == 0) { Sleep(2); continue; }
        BYTE* d = nullptr;
        if (FAILED(self->render->GetBuffer(want, &d)) || !d) { Sleep(2); continue; }
        for (UINT32 i = 0; i < want; i++) {
            float v = (float)(0.5 * sin(phase));
            phase += step;
            for (int c = 0; c < self->ch; c++) {
                size_t idx = (size_t)i * self->ch + c;
                if (self->isF) ((float*)d)[idx] = v;
                else if (self->bits == 16) ((short*)d)[idx] = (short)(v * 32767);
                else if (self->bits == 32) ((int*)d)[idx] = (int)(v * 2147483647.0);
            }
        }
        self->render->ReleaseBuffer(want, 0);
    }
    self->client->Stop();
    return 0;
}

static std::wstring Utf8ToWide(const char* s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
    return w;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 3) {
        printf("usage: vaio_bridge_loopback_check <bridgeDir> "
               "<tone|driver|steps|aged|caponly|playonly|chopplay> "
               "[landingSubstring] [outDir]\n");
        return 2;
    }
    const std::string dir = argv[1];
    const std::string mode = argv[2];
    const std::string landingSub = (argc >= 4) ? argv[3] : "";
    const std::string outDir = (argc >= 5) ? argv[4] : ".";
    const bool useBridge = (mode == "tone" || mode == "driver" || mode == "steps" || mode == "aged");
    const bool useCapture = (mode != "playonly");
    const bool useTone = (mode == "driver" || mode == "playonly" || mode == "steps" || mode == "aged" || mode == "chopplay");
    FILE* info = fopen((outDir + "\\vaio_bridge_loopback_check_info.txt").c_str(), "w");

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IMMDeviceEnumerator* en = nullptr;
    CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                     __uuidof(IMMDeviceEnumerator), (void**)&en);
    if (!en) { printf("enumerator failed\n"); return 3; }

    // --- loopback capture client on the landing endpoint
    IAudioClient* capClient = nullptr;
    IAudioCaptureClient* cap = nullptr;
    bool capFloat = true; int capBits = 32, capCh = 2, capRate = 48000;
    FILE* raw = nullptr;
    if (useCapture) {
        IMMDevice* land = nullptr;
        if (!landingSub.empty())
            land = FindEndpoint(en, Utf8ToWide(landingSub.c_str()).c_str());
        if (!land) en->GetDefaultAudioEndpoint(eRender, eConsole, &land);
        if (!land) { printf("landing endpoint not found\n"); return 4; }
        HRESULT ahr = land->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&capClient);
        if (FAILED(ahr) || !capClient) { printf("activate failed\n"); return 8; }
        WAVEFORMATEX* capFmt = nullptr;
        capClient->GetMixFormat(&capFmt);
        FmtInfo(capFmt, capFloat, capBits, capCh, capRate);
        fprintf(info, "landing fmt: float=%d bits=%d ch=%d rate=%d\n",
                (int)capFloat, capBits, capCh, capRate);
        fflush(info);
        capClient->Initialize(AUDCLNT_SHAREMODE_SHARED,
                              AUDCLNT_STREAMFLAGS_LOOPBACK, 10000000, 0, capFmt, nullptr);
        capClient->GetService(__uuidof(IAudioCaptureClient), (void**)&cap);
        raw = fopen((outDir + "\\vaio_bridge_loopback_check.raw").c_str(), "wb");
    }

    // --- bridge under test (tone/driver/steps/aged only; other modes are
    //     driven by an external host such as the real App)
    HMODULE hb = nullptr;
    PFN_status p_status = nullptr;
    PFN_stop p_stop = nullptr;
    PFN_test_stop p_tstop = nullptr;
    PFN_set_param p_setp = nullptr;
    PFN_set_param_str p_setps = nullptr;
    if (useBridge) {
        std::string bridgePath = dir + "\\auravaio_bridge.dll";
        hb = LoadLibraryA(bridgePath.c_str());
        if (!hb) { printf("bridge load failed %lu\n", GetLastError()); return 5; }
        auto p_detect = (PFN_detect)GetProcAddress(hb, "ab_detect");
        auto p_start = (PFN_start)GetProcAddress(hb, "ab_start");
        p_stop = (PFN_stop)GetProcAddress(hb, "ab_stop");
        p_status = (PFN_status)GetProcAddress(hb, "ab_status");
        auto p_tstart = (PFN_test_start)GetProcAddress(hb, "ab_test_start");
        p_tstop = (PFN_test_stop)GetProcAddress(hb, "ab_test_stop");
        p_setp = (PFN_set_param)GetProcAddress(hb, "ab_set_param");
        p_setps = (PFN_set_param_str)GetProcAddress(hb, "ab_set_param_str");
        char dbuf[8192]; memset(dbuf, 0, sizeof(dbuf));
        int drc = p_detect(dbuf, sizeof(dbuf));
        printf("detect rc=%d\n", drc);
        std::string enginePath = dir + "\\auradsp_engine.dll";
        // config_json per aurabridge.h: VAIO landing via {"endpoint":"sub"};
        // params "" = no pre-apply (a literal "{}" would count one bad token).
        std::string cfg = landingSub.empty()
            ? "" : ("{\"endpoint\":\"" + landingSub + "\"}");
        int src = p_start(enginePath.c_str(), "", cfg.c_str());
        printf("ab_start rc=%d\n", src);
        if (src != 0) return 6;
        if (mode == "tone") {
            int trc = p_tstart(1, nullptr, 0, 0, 0);
            printf("test_start rc=%d\n", trc);
        }
    }

    if (capClient) capClient->Start();

    // aged mode: let the bridge idle 90 s before the stimulus starts,
    // mirroring the app session where the tone arrived ~90 s after the
    // bridge had started (long idle, then a fresh stream on the ring).
    if (mode == "aged") {
        printf("aging the bridge for 90 s...\n");
        Sleep(90000);
        printf("aging done, starting stimulus\n");
    }

    // --- sine stimulus into the AuraVAIO endpoint (driver/playonly/...)
    IAudioClient* toneClient = nullptr;
    IAudioRenderClient* toneRender = nullptr;
    HANDLE toneThread = nullptr;
    volatile bool toneRun = true;
    if (useTone) {
        IMMDevice* vaio = FindEndpoint(en, L"AuraVAIO");
        if (!vaio) { printf("vaio endpoint not found\n"); return 7; }
        vaio->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&toneClient);
        WAVEFORMATEX* tf = nullptr;
        toneClient->GetMixFormat(&tf);
        bool tF; int tB, tC, tR;
        FmtInfo(tf, tF, tB, tC, tR);
        fprintf(info, "vaio fmt: float=%d bits=%d ch=%d rate=%d\n",
                (int)tF, tB, tC, tR);
        fflush(info);
        toneClient->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 10000000, 0, tf, nullptr);
        toneClient->GetService(__uuidof(IAudioRenderClient), (void**)&toneRender);
        auto* tctx = new ToneCtx{toneClient, toneRender, &toneRun, tF, tB, tC, tR,
                                 mode == "chopplay"};
        toneThread = CreateThread(nullptr, 0, ToneThread, tctx, 0, nullptr);
    }

    // --- main duration: capture loop or plain wait
    if (useCapture) {
        DWORD t0 = GetTickCount();
        const DWORD totalMs = (mode == "steps") ? 24000 : (mode == "aged") ? 10000
            : (mode == "caponly") ? 20000 : 6000;
        int stepStage = 0;
        while (GetTickCount() - t0 < totalMs) {
            if (mode == "steps" && p_setp) {
                DWORD el = GetTickCount() - t0;
                if (stepStage == 0 && el >= 3000) {
                    ApplyGroup(p_setp, kG1, sizeof(kG1)/sizeof(kG1[0]));
                    printf("applied G1\n"); stepStage = 1;
                } else if (stepStage == 1 && el >= 8000) {
                    ApplyGroup(p_setp, kG2, sizeof(kG2)/sizeof(kG2[0]));
                    printf("applied G2\n"); stepStage = 2;
                } else if (stepStage == 2 && el >= 13000) {
                    ApplyGroup(p_setp, kG3, sizeof(kG3)/sizeof(kG3[0]));
                    printf("applied G3\n"); stepStage = 3;
                } else if (stepStage == 3 && el >= 18000 && p_setps) {
                    const char* curve =
                        "eqm:1:fir;25.0:0.0;40.0:0.0;63.0:0.0;100.0:0.0;"
                        "160.0:0.0;250.0:0.0;400.0:0.0;630.0:0.0;1000.0:0.0;"
                        "1600.0:0.0;2500.0:0.0;4000.0:0.0;6300.0:0.0;"
                        "10000.0:0.0;16000.0:0.0";
                    int crc = p_setps("eq.curve", curve, (int)strlen(curve));
                    printf("applied G4 curve rc=%d\n", crc); stepStage = 4;
                }
            }
            UINT32 packet = 0;
            cap->GetNextPacketSize(&packet);
            while (packet > 0) {
                BYTE* d = nullptr; UINT32 frames = 0; DWORD flags = 0;
                if (FAILED(cap->GetBuffer(&d, &frames, &flags, nullptr, nullptr)))
                    break;
                for (UINT32 i = 0; i < frames; i++) {
                    for (int c = 0; c < capCh; c++) {
                        size_t idx = (size_t)i * capCh + c;
                        float v = 0;
                        if (flags & AUDCLNT_BUFFERFLAGS_SILENT) v = 0;
                        else if (capFloat) v = ((float*)d)[idx];
                        else if (capBits == 16) v = ((short*)d)[idx] / 32768.0f;
                        else if (capBits == 32) v = (float)(((int*)d)[idx] / 2147483648.0);
                        fwrite(&v, 4, 1, raw);
                    }
                }
                cap->ReleaseBuffer(frames);
                cap->GetNextPacketSize(&packet);
            }
            Sleep(3);
        }
    } else {
        Sleep((mode == "playonly") ? 150000 : (mode == "chopplay") ? 120000 : 9000);
    }

    toneRun = false;
    if (toneThread) { WaitForSingleObject(toneThread, 2000); }
    if (useBridge) {
        if (mode == "tone") p_tstop();
        char st[8192]; memset(st, 0, sizeof(st));
        p_status(st, sizeof(st));
        fprintf(info, "bridge status: %s\n", st);
        p_stop();
    }
    if (capClient) capClient->Stop();
    if (raw) fclose(raw);
    fclose(info);
    printf("done\n");
    return 0;
}
