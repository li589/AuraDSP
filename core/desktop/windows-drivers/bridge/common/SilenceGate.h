#pragma once
//
// SilenceGate.h — 全后端静音门控（P3，2026-10-29 方案 §3.1 / §3.3）
//
// 语义与引擎层（engine/auradsp_engine.cpp 的 gate_update）完全一致：
//   ACTIVE --(输入峰值 < 阈值 持续 holdMs 且上一块输出残量 < -120dB)--> GATED
//   GATED  --(本块任意采样 >= 阈值 当块即时恢复)---------------------> ACTIVE
//
// 与 Z12 超预算保护**正交**：Z12 是过载降质（收窄插件掩码），本门控是
// 无输入跳过（不跑 DSP、输出整块写零）。二者互不替代、可同时生效。
//
// RT 约束（所有调用点都在音频线程）：零锁、零分配、零系统调用。
// 环境变量只在控制线程 Configure() 里读一次（桥 start/重建时）：
//   AURADSP_GATE=0      → 关闭门控（三桥与引擎同时尊重）
//   AURADSP_GATE_DB=-90 → 覆盖输入阈值（防极低电平音乐被误门）
//
// 为什么桥层需要「上一块输出」条件：桥一旦 GATED 就不再调用引擎 process，
// 引擎内部的尾音残量条件再也观察不到。用上一块（引擎实际输出）的峰值做
// 同一判据，等于把引擎的「尾音已衰完」结论前移一块——长混响尾巴不会被
// 桥层提前切掉。
#include <cmath>
#include <cstddef>
#include <cstdlib>

#if defined(_WIN32)
#include <windows.h>
#endif

namespace aurabridge {

constexpr int kGateDefaultHoldMs = 2000;
constexpr float kGateDefaultThresholdDb = -90.0f;   // -90 dBFS ≈ 3.16e-5
constexpr float kGateDefaultResidualDb = -120.0f;   // -120 dBFS = 1e-6
constexpr float kGateLinearThreshold = 3.16227766e-5f;
constexpr float kGateLinearResidual = 1.0e-6f;

inline float GateDbToLinear(float db) { return std::pow(10.0f, db * 0.05f); }

inline bool GateReadEnv(const char* name, char* out, size_t cap) {
    if (!out || cap == 0) return false;
#if defined(_WIN32)
    const DWORD n = GetEnvironmentVariableA(name, out, (DWORD)cap);
    return n > 0 && n < cap;
#else
    const char* v = std::getenv(name);
    if (!v || !*v) return false;
    size_t i = 0;
    for (; v[i] && i + 1 < cap; ++i) out[i] = v[i];
    out[i] = '\0';
    return i > 0;
#endif
}

// 每块最大绝对值（交错缓冲）。RT 安全。
inline float GateScanInterleaved(const float* buf, long long samples) {
    float peak = 0.0f;
    if (!buf) return peak;
    for (long long i = 0; i < samples; ++i) {
        const float a = std::fabs(buf[i]);
        if (a > peak) peak = a;
    }
    return peak;
}

// 每块最大绝对值（多平面）。RT 安全。
inline float GateScanPlanes(const float* const* bufs, int nbuf, long long frames) {
    float peak = 0.0f;
    if (!bufs || frames <= 0) return peak;
    for (int b = 0; b < nbuf; ++b) {
        const float* p = bufs[b];
        if (!p) continue;
        const float v = GateScanInterleaved(p, frames);
        if (v > peak) peak = v;
    }
    return peak;
}

struct SilenceGate {
    bool enabled = false;      // false = pump/未配置路径，Tick 直接返回 false
    bool gated = false;
    long long sampleRate = 0;
    long long silentFrames = 0;   // 连续输入静音帧数（封顶 holdFrames 防溢出）
    long long holdFrames = 0;     // 2000ms × fs
    long long idleFrames = 0;     // GATED 累计帧数（status 的 idleMs）
    float peakThreshold = kGateLinearThreshold;
    float residualThreshold = kGateLinearResidual;
    float lastOutPeak = 0.0f;     // 上一块引擎输出峰值（进入判据）

    void Reset() {
        gated = false;
        silentFrames = 0;
        idleFrames = 0;
        lastOutPeak = 0.0f;
    }

    // 控制线程：采样率确认后调用（start / CHANGE 重建）。读环境变量一次。
    void Configure(long long sampleRateHz) {
        sampleRate = sampleRateHz > 0 ? sampleRateHz : 0;
        holdFrames = sampleRate * (long long)kGateDefaultHoldMs / 1000;
        enabled = true;
        peakThreshold = kGateLinearThreshold;
        residualThreshold = kGateLinearResidual;
        char env[64] = {0};
        if (GateReadEnv("AURADSP_GATE", env, sizeof(env)) && env[0] == '0') {
            enabled = false;
        }
        if (GateReadEnv("AURADSP_GATE_DB", env, sizeof(env))) {
            const float db = (float)std::atof(env);
            if (db > -200.0f && db < 0.0f) peakThreshold = GateDbToLinear(db);
        }
        Reset();
    }

    // RT：本块引擎输出峰值（正常处理路径末尾调用）。
    void NoteOutput(float outPeak) {
        lastOutPeak = outPeak > 0.0f ? outPeak : 0.0f;
    }

    // RT：块首判定。返回 true = 本块 GATED（调用方跳过 DSP 并整块写零）。
    bool Tick(float inPeak, long long frames) {
        if (!enabled) {
            gated = false;
            silentFrames = 0;
            idleFrames = 0;
            lastOutPeak = 0.0f;
            return false;
        }
        if (gated) {
            // 退出即时：本块任意采样 >= 阈值 → 同块恢复全链，0 块延迟。
            if (inPeak >= peakThreshold) {
                gated = false;
                silentFrames = 0;
                idleFrames = 0;
                return false;
            }
            idleFrames += frames;
            return true;
        }
        if (inPeak < peakThreshold) {
            if (silentFrames < holdFrames) silentFrames += frames;
        } else {
            silentFrames = 0;
        }
        // 进入双条件：输入静音够长 + 上一块输出残量已衰完（尾音不截断）。
        if (holdFrames > 0 && silentFrames >= holdFrames &&
            lastOutPeak <= residualThreshold) {
            gated = true;
            idleFrames = 0;
            return true;
        }
        return false;
    }

    long long IdleMs() const {
        return sampleRate > 0 ? idleFrames * 1000 / sampleRate : 0;
    }
};

}  // namespace aurabridge
