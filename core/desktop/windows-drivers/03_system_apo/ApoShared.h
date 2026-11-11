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

#include <cstddef>
#include <cstdint>
#include <windows.h>

// ---- 共享对象名与安全描述符 ----
#define AURA_APO_PARAMS_NAME L"Global\\AuraDSP_ApoParams"
#define AURA_APO_TELEMETRY_NAME L"Global\\AuraDSP_ApoTelemetry"
#define AURA_APO_PLUGINS_NAME L"Global\\AuraDSP_ApoPlugins"
// 与心跳映射同一 SDDL（LS=LocalService / WD=Everyone / 两个 LPAC
// 包 SID 全 GA）：audiodg 的 LPAC 沙箱只能穿透显式授权的对象。
#define AURA_APO_SHARED_SDDL L"D:(A;;GA;;;LS)(A;;GA;;;WD)(A;;GA;;;S-1-15-2-1)(A;;GA;;;S-1-15-2-2)"

// Win7 退路口径：AppContainer 机构（S-1-15-2-*）为 Win8+ 概念
// （微软 WELL_KNOWN_SID_TYPE 文档标 Win7 不可用；含该 ACE 的
// SDDL 在 Win7 上的解析成败文档未载）。转换失败时退回本口径
// ——LS/WD 两条在 Win7 语义完整，功能不受影响。
#define AURA_APO_SHARED_SDDL_FALLBACK L"D:(A;;GA;;;LS)(A;;GA;;;WD)"

// ---- 参数块（App → APO） ----
// 写协议（seqlock）：写者先令 writeSeq 为奇数（写入中），写完全部
// 内容后令其为偶数（稳定）；读者读前读后各取一次 writeSeq，两次
// 相同且为偶数才采信快照。bypass 置位时 APO 跳过引擎（等价透传）。
#define APO_PARAMS_MAGIC 0x41504152u  // 'APAR'
// v2（全面复审 S3 / APO-1）：数值槽 325→339——自定义 setter 家族
// 的 14 个数值参数（comp.mode / channels.mode / reverb.preset 等）
// 追加在存量序号之后，存量序号不移位。消费端版本全等校验使旧
// DLL 对 v2 块整体拒绝（安全降级），永不按错位序号误用参数。
#define APO_PARAMS_VERSION 2u

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
inline const wchar_t* AuraApoPluginsName() {
    return AuraApoChannelsLocal() ? L"Local\\AuraDSP_ApoPlugins"
                                  : AURA_APO_PLUGINS_NAME;
}

// ---- 回传块（APO → App） ----
// seatState 是全系统唯一的「引擎座位」（设计 D3）：LockForProcess
// 时以 InterlockedCompareExchange 抢占（0→1），UnlockForProcess
// 释放；同端点 SFX/MFX/EFX 三实例与多端点实例中只有一个跑引擎，
// 其余透传并累加 seatTaken（供面板/诊断区分「没抢到」与「没附加」）。
#define APO_TELEMETRY_MAGIC 0x4154454Cu  // 'ATEL'
// v2（2026-11-10）：尾部追加 eqIn/stage 分级回传（处理流显示
// 用）；既有字段偏移一律不变，读者按 version 分级取用。
// v3（2026-11-10，Part I Q2）：尾部再追加插件段（每槽 32B×4）；
// v1/v2 字段偏移仍不变，读者按 version>=3 取插件段。
#define APO_TELEMETRY_VERSION 4u
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
    // ---- v2 追加（offset 192 起；v1 读者止步于此）----
    float eqInSpectrum[32];                      // EQ 前频谱（引擎 viz 口径）
    float stageLevelsL[32];                      // 分级电平 L（dBFS，引擎 stage 序）
    float stageLevelsR[32];                      // 分级电平 R（dBFS）
    uint32_t reserved[8];
    // ---- v3 追加（offset 608 起；v2 读者止步于此）----
    // 每槽 32B：loaded/bypass 为有效值（bypass 已含故障旁路），
    // faultCategory 取引擎 PluginFaultCategory 数值（0=none）。
    struct PluginSlot {
        uint8_t loaded;
        uint8_t bypass;
        uint8_t fault;
        uint8_t faultCategory;
        uint32_t latencySamples;
        float inRms;
        float outRms;
        uint32_t processCalls;
        uint32_t appliedLoadGen;
        uint32_t appliedStateGen;
        uint32_t reserved;
    };
    PluginSlot plugins[4];
    // ---- v4 追加（offset 736 起；v3 读者止步于此）----
    // 引擎加载诊断（第五轮 S3）：最近一次 TryStart 的加载结局。
    // loadStage 取 APO_LOAD_STAGE_*；loadErr 为关键步的 Win32
    // 错误码（stage=LOAD_FAILED 时为首候选的 GetLastError）。
    uint32_t loadStage;
    uint32_t loadErr;
};

// loadStage 取值（ApoTelemetryBlock.loadStage）。
#define APO_LOAD_STAGE_NONE 0u        // 尚未尝试（块初建）
#define APO_LOAD_STAGE_NO_DIR 1u      // 取 APO 自身目录失败
#define APO_LOAD_STAGE_LOAD_FAILED 2u // 三候选 DLL 均加载失败
#define APO_LOAD_STAGE_ABI 3u         // 有 DLL 加载成功但符号/ABI 不符
#define APO_LOAD_STAGE_CREATE 4u      // auradsp_create 返回空
#define APO_LOAD_STAGE_READY 5u       // 引擎就绪（座位实例处理中/曾就绪）
// v2 布局钉死：既有字段偏移与 v1 完全一致，追加段自 192 起。
// v3：插件段自 608 起，块总 736B（映射仍 4096B 整页口径）。
// v4：加载诊断自 736 起，块总 744B。
static_assert(sizeof(ApoTelemetryBlock) == 744, "telemetry block layout");
static_assert(offsetof(ApoTelemetryBlock, spectrum) == 64, "telemetry v1 offsets");
static_assert(offsetof(ApoTelemetryBlock, eqInSpectrum) == 192, "telemetry v2 offsets");
static_assert(offsetof(ApoTelemetryBlock, stageLevelsL) == 320, "telemetry v2 offsets");
static_assert(offsetof(ApoTelemetryBlock, stageLevelsR) == 448, "telemetry v2 offsets");
static_assert(offsetof(ApoTelemetryBlock, plugins) == 608, "telemetry v3 offsets");
static_assert(offsetof(ApoTelemetryBlock, loadStage) == 736, "telemetry v4 offsets");
static_assert(sizeof(ApoTelemetryBlock::PluginSlot) == 32, "telemetry plugin slot");

// ---- 插件块（App → APO，Part I Q2 / 计划书 D2/D3、Q0-3） ----
// 独立第三映射（AuraDSP_ApoPlugins），不并入参数块：参数块布局
// 由生成器钉死且余量放不下状态 blob。写协议同参数块 seqlock。
// 每槽身份 {格式， 路径， 插件 id， 插入级， 声道掩码， 旁路} +
// 状态字节（savePreset 产物，上限 APO_PLUGIN_STATE_BYTES）；
// loadGen/stateGen 由发布者单调递增，worker 按代次应用（身份
// 变→重载；状态代次单独变→仅 loadPreset 应用状态）。
// 格式码仅作发布侧自述（引擎按路径找驱动）：0 无 / 1 VST3 /
// 2 CLAP / 3 VST2。
#define APO_PLUGINS_MAGIC 0x47505541u  // 'AUPG'
#define APO_PLUGINS_VERSION 1u
#define APO_PLUGIN_SLOTS 4u
#define APO_PLUGIN_PATH_BYTES 1024u
#define APO_PLUGIN_ID_BYTES 256u
#define APO_PLUGIN_STATE_BYTES 524288u  // 512KiB（D3 取舍点 1）
#define APO_PLUGIN_BLOCK_HEADER_BYTES 64u
#define APO_PLUGIN_SLOT_HEADER_BYTES 64u
#define APO_PLUGIN_SLOT_STRIDE \
    (APO_PLUGIN_SLOT_HEADER_BYTES + APO_PLUGIN_PATH_BYTES + \
     APO_PLUGIN_ID_BYTES + APO_PLUGIN_STATE_BYTES)
#define APO_PLUGIN_BLOCK_USED_BYTES \
    (APO_PLUGIN_BLOCK_HEADER_BYTES + APO_PLUGIN_SLOTS * APO_PLUGIN_SLOT_STRIDE)
#define APO_PLUGIN_BLOCK_BYTES 2105344u  // 514 页（used 向上取整）

struct ApoPluginBlockHeader {
    uint32_t magic;         // APO_PLUGINS_MAGIC
    uint32_t version;       // APO_PLUGINS_VERSION
    uint32_t writeSeq;      // seqlock（奇=写入中）
    uint32_t blockBytes;    // == APO_PLUGIN_BLOCK_BYTES
    uint32_t chainEnabled;  // 插件链总开关
    uint32_t pdcEnabled;    // PDC 开关
    uint32_t reserved[10];  // 凑满 64B 头
};
static_assert(sizeof(ApoPluginBlockHeader) == 64, "plugin block header");

struct ApoPluginSlotHeader {
    uint32_t format;      // 0 无 / 1 VST3 / 2 CLAP / 3 VST2
    uint32_t insertStage; // 0..4
    uint32_t channelMask;
    uint32_t bypass;      // 期望旁路（挂载即旁路口径由发布侧给出）
    uint32_t loadGen;     // 身份代次（变→worker 重载该槽）
    uint32_t stateGen;    // 状态代次（变→worker 应用状态）
    uint32_t pathBytes;   // 路径 UTF-8 已用字节（不含 NUL）
    uint32_t stateBytes;  // 状态已用字节（<= APO_PLUGIN_STATE_BYTES）
    uint32_t reserved[8];
};
static_assert(sizeof(ApoPluginSlotHeader) == 64, "plugin slot header");
// 槽内布局：[ApoPluginSlotHeader 64][路径 1024][id 256][状态 512K]，
// 槽 s 起始 = APO_PLUGIN_BLOCK_HEADER_BYTES + s * APO_PLUGIN_SLOT_STRIDE。
