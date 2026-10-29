// silence_gate_test.cpp — P3 桥层静音门控状态机单测（驱动无关，CI 可跑）
//
// 覆盖：
//   1. 默认配置：启用、hold = 2000ms × fs、阈值 -90dBFS
//   2. 进入时机：连续静音累计满 hold 才 GATED（差一帧都不进）
//   3. 进入双条件：上一块输出残量 > -120dB 时不得进入（尾音不截断）
//   4. 退出即时：本块任意采样 >= 阈值当块恢复，0 块延迟
//   5. idleMs 随 GATED 帧数增长
//   6. AURADSP_GATE=0 禁用；AURADSP_GATE_DB 覆盖阈值
//   7. 峰值扫描助手：交错/多平面
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "SilenceGate.h"

static int g_fail = 0;

static void check(const char* name, bool ok, const char* detail = "") {
    std::printf("%s  %s", ok ? "PASS" : "FAIL", name);
    if (!ok && detail[0]) std::printf("  (%s)", detail);
    std::printf("\n");
    if (!ok) ++g_fail;
}

static bool approx(float a, float b, float eps = 1e-6f) {
    const float d = a - b;
    return d < eps && d > -eps;
}

int main() {
    const long long SR = 48000;
    const long long BLK = 480;                 // 10ms
    const long long kHold = SR * 2;            // 96000

    // 1) 默认配置
    {
        aurabridge::SilenceGate g;
        g.Configure(SR);
        check("default-enabled", g.enabled);
        check("default-hold-2000ms", g.holdFrames == kHold);
        check("default-threshold--90dBFS",
              approx(g.peakThreshold, aurabridge::kGateLinearThreshold));
        check("default-not-gated", !g.gated);
    }

    // 2) 进入时机：累计静音 95999 帧不进，补 1 帧进
    {
        aurabridge::SilenceGate g;
        g.Configure(SR);
        long long fed = 0;
        bool gatedEarly = false;
        while (fed + BLK < kHold) {
            if (g.Tick(0.0f, BLK)) gatedEarly = true;
            fed += BLK;
        }
        check("enter-not-before-hold", !gatedEarly && !g.gated);
        if (!g.Tick(0.0f, kHold - fed)) {
            check("enter-at-hold", false, "last frame did not gate");
        } else {
            check("enter-at-hold", g.gated);
        }
    }

    // 3) 进入双条件：输出残量未衰完不得进入（长混响尾音）
    {
        aurabridge::SilenceGate g;
        g.Configure(SR);
        long long fed = 0;
        while (fed + BLK < kHold) {
            g.Tick(0.0f, BLK);
            fed += BLK;
        }
        g.NoteOutput(1e-4f);  // -80dBFS：尾音还在
        check("enter-blocked-by-residual", !g.Tick(0.0f, BLK));
        g.NoteOutput(1e-6f);  // -120dBFS：衰完
        check("enter-after-residual-decayed", g.Tick(0.0f, BLK));
    }

    // 4) 退出即时（本块 >= 阈值）
    {
        aurabridge::SilenceGate g;
        g.Configure(SR);
        long long fed = 0;
        while (fed < kHold) {
            g.Tick(0.0f, BLK);
            fed += BLK;
        }
        g.Tick(0.0f, BLK);
        check("gated-before-exit", g.gated);
        const bool gatedBlock = g.Tick(0.01f, BLK);  // -40dBFS
        check("exit-same-block", !gatedBlock && !g.gated);
        check("exit-resets-counters", g.silentFrames == 0 && g.idleFrames == 0);
    }

    // 5) idleMs
    {
        aurabridge::SilenceGate g;
        g.Configure(SR);
        long long fed = 0;
        while (!g.Tick(0.0f, BLK)) {
            fed += BLK;
            if (fed > kHold + 10 * BLK) break;
        }
        for (int i = 0; i < 20; ++i) g.Tick(0.0f, BLK);  // 200ms idle
        check("idle-ms-tracks-gated-time", g.IdleMs() >= 180 && g.IdleMs() <= 220,
              "idleMs out of range");
    }

    // 6) 环境变量
    {
        _putenv_s("AURADSP_GATE", "0");
        aurabridge::SilenceGate g;
        g.Configure(SR);
        check("env-gate-0-disables", !g.enabled);
        check("env-gate-0-never-gated", !g.Tick(0.0f, kHold * 2));
        _putenv_s("AURADSP_GATE", "");

        _putenv_s("AURADSP_GATE_DB", "-120");
        aurabridge::SilenceGate g2;
        g2.Configure(SR);
        check("env-gate-db-overrides",
              approx(g2.peakThreshold, 1e-6f, 2e-7f));
        _putenv_s("AURADSP_GATE_DB", "");
    }

    // 7) 扫描助手
    {
        const float inter[8] = {0.0f, -0.5f, 0.25f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        check("scan-interleaved", approx(aurabridge::GateScanInterleaved(inter, 8), 0.5f));
        const float a[2] = {0.0f, 0.1f};
        const float b[2] = {-0.7f, 0.0f};
        const float* planes[2] = {a, b};
        check("scan-planes", approx(aurabridge::GateScanPlanes(planes, 2, 2), 0.7f));
    }

    std::printf("%s  total_failures=%d\n", g_fail ? "FAIL" : "PASS", g_fail);
    return g_fail ? 1 : 0;
}

