// ApoShared.h — System APO 真处理的两块跨进程共享布局（设计 D4/D7）
//
// docs/10-架构/SystemAPO引擎嵌入设计-2026-11-10.md
//   参数块   Global\AuraDSP_ApoParams    App 写 → APO worker 读
//   回传块   Global\AuraDSP_ApoTelemetry APO 写 → App 读
// 两块都用心跳同款穿透 DACL 创建（LocalService + LPAC 可穿透，
// 见 AuraApo.cpp 心跳映射的 SDDL 先例）。
//
// 数值槽的「序号↔参数 id」映射不在本文件：由
// tools/gen_apo_param_layout.py 从 engine/engine_param_table.h
// 机械生成到 ApoParamIndex.h（C）与 lib/engine/apo_param_index.dart
// （Dart），漂移由 smoke_apo_param_layout 守门。本文件的布局常量
// 必须与生成器一致（同一 smoke 交叉断言）。
#pragma once

#include <cstdint>
#include <windows.h>

// ---- 共享对象名与安全描述符 ----
#define AURA_APO_PARAMS_NAME L"Global\\AuraDSP_ApoParams"
#define AURA_APO_TELEMETRY_NAME L"Global\\AuraDSP_ApoTelemetry"
// 与心跳映射同一 SDDL（LS=LocalService / WD=Everyone / 两个 LPAC
// 包 SID 全 GA）：audiodg 的 LPAC 沙箱只能穿透显式授权的对象。
#define AURA_APO_SHARED_SDDL L"D:(A;;GA;;;LS)(A;;GA;;;WD)(A;;GA;;;S-1-15-2-1)(A;;GA;;;S-1-15-2-2)"

// ---- 参数块（App → APO） ----
// 写协议（seqlock）：写者先令 writeSeq 为奇数（写入中），写完全部
// 内容后令其为偶数（稳定）；读者读前读后各取一次 writeSeq，两次
// 相同且为偶数才采信快照。bypass 置位时 APO 跳过引擎（等价透传）。
#define APO_PARAMS_MAGIC 0x41504152u  // 'APAR'
#define APO_PARAMS_VERSION 1u

struct ApoParamBlockHeader {
    uint32_t magic;        // APO_PARAMS_MAGIC
    uint32_t version;      // APO_PARAMS_VERSION
    uint32_t writeSeq;     // seqlock 序号（奇=写入中）
    uint32_t bypass;       // 0/1
    uint32_t numCount;     // 数值槽总数（== APO_NUM_PARAM_COUNT）
    uint32_t strUsed[4];   // 各字符串槽已用字节（不含 NUL）
    uint32_t reserved[7];  // 凑满 64B 头
};
// 头之后：valid 位图区（64B，bit i ↔ 数值槽 i、bit 325+s ↔
// 字符串槽 s；只有置位槽会被 worker 应用——未被 App 写过的
// 参数必须保留引擎默认值，见生成器头注）→ values[numCount]
// （u32/槽）→ 字符串槽区（定长，偏移与容量见 ApoParamIndex.h）。
static_assert(sizeof(ApoParamBlockHeader) == 64, "param block header must be 64B");

// 测试通道名选择（与心跳 AURAAPO_HEARTBEAT_LOCAL 同先例）：
// 进程内宿主冒烟在无 SeCreateGlobalPrivilege 的普通 shell 中
// 运行时置 AURAAPO_CHANNELS_LOCAL=1，两块改走 Local\ 名；
// 生产进程（audiodg / App）从不设置，恒用 Global\ 名。
inline int AuraApoChannelsLocal() {
    static int v = -1;
    if (v < 0) {
        char b[2] = {0};
        DWORD n = GetEnvironmentVariableA("AURAAPO_CHANNELS_LOCAL", b, 2);
        v = (n == 1 && b[0] == '1') ? 1 : 0;
    }
    return v;
}
inline const wchar_t* AuraApoParamsName() {
    return AuraApoChannelsLocal() ? L"Local\\AuraDSP_ApoParams"
                                  : AURA_APO_PARAMS_NAME;
}
inline const wchar_t* AuraApoTelemetryName() {
    return AuraApoChannelsLocal() ? L"Local\\AuraDSP_ApoTelemetry"
                                  : AURA_APO_TELEMETRY_NAME;
}

// ---- 回传块（APO → App） ----
// seatState 是全系统唯一的「引擎座位」（设计 D3）：LockForProcess
// 时以 InterlockedCompareExchange 抢占（0→1），UnlockForProcess
// 释放；同端点 SFX/MFX/EFX 三实例与多端点实例中只有一个跑引擎，
// 其余透传并累加 seatTaken（供面板/诊断区分「没抢到」与「没附加」）。
#define APO_TELEMETRY_MAGIC 0x4154454Cu  // 'ATEL'
#define APO_TELEMETRY_VERSION 1u
#define APO_TELEMETRY_BYTES 4096u

struct ApoTelemetryBlock {
    uint32_t magic;         // APO_TELEMETRY_MAGIC
    uint32_t version;       // APO_TELEMETRY_VERSION
    volatile long seatState;  // 0=空 1=已被某实例占用
    uint32_t ownerPid;      // 座位实例所在进程（audiodg）pid
    uint32_t sampleRate;    // 座位引擎采样率
    uint32_t channels;      // 座位流声道数
    uint32_t paramsApplied; // 座位 worker 累计应用的参数项次
    uint32_t fault;         // 1=引擎故障闩锁（本会话透传中）
    uint32_t seatTaken;     // 累计「抢座失败」次数（其他实例在透传）
    uint32_t updateSeq;     // 电平/频谱更新序号（App 侧判新）
    float peakInL, peakInR, peakOutL, peakOutR;  // 线性峰值
    float levelLDb, levelRDb;                    // 输出电平 dBFS
    float spectrum[32];                          // 输出频谱（引擎 viz 口径，[0,1]）
    uint32_t reserved[8];
};
static_assert(sizeof(ApoTelemetryBlock) == 224, "telemetry block layout");
