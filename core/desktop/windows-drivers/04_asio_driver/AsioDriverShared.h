// AsioDriverShared.h — AuraDSP 虚拟 ASIO 驱动跨进程契约（单一真相）
//
// ASIO 模式重构方案（docs/20-执行/ASIO模式重构方案-2026-11-20.md）
// §三的跨进程三线之二在此定型：
//   配置面：HKCU\SOFTWARE\AuraDSP\AsioDriver
//     - Channels       REG_DWORD  声道档位（既有，App 写、驱动读）
//     - RenderEndpoint REG_SZ     后端 WASAPI 汇的渲染端点 id
//                                 （S3 新增：App 写、驱动汇 Open 读；
//                                 空/缺失/失效 → 回落系统默认端点）
//   遥测面：Global\AuraDSP_AsioDriverTelemetry（S3 新增，
//     v2 于 S4 扩频谱；v3 于 r65 尾加逐声道峰值）
//     驱动泵写 → ASIO 桥在 asiostatus 中转读 → App 展示。解决
//     「DAW 侧真实例与 App 侧实例互不可见」：DAW 在场、已处理帧、
//     峰值与汇实际生效端点/格式自此有真数据源。
//   参数面：Global\AuraDSP_AsioDriverParams（S4 新增）
//     App 写 → 驱动泵读：seq 变化即把参数串应用到 DAW 进程内
//     的引擎实例（此前该引擎恒跑默认参数）；bypass 同块下发。
//     App 在虚拟形态下不再自开驱动会话（去假会话），本块与
//     遥测块即虚拟形态的全部跨进程通道。
#pragma once

#include <cstddef>
#include <cstdint>

#define ASIO_DRIVER_REG_KEY L"SOFTWARE\\AuraDSP\\AsioDriver"
#define ASIO_DRIVER_REG_CHANNELS L"Channels"
#define ASIO_DRIVER_REG_RENDER_ENDPOINT L"RenderEndpoint"

#define ASIO_DRIVER_TELEMETRY_NAME L"Global\\AuraDSP_AsioDriverTelemetry"
#define ASIO_DRIVER_TELEMETRY_MAGIC 0x54444141u  // 'AADT'
#define ASIO_DRIVER_TELEMETRY_VERSION 3u
#define ASIO_DRIVER_TELEMETRY_BYTES 4096u

// ---- 参数块（S4；v2 起改奇偶 seqlock）：App 写、驱动读 ----
// App（isolate 内的 AsioParamPublisher）是唯一写者：把参数镜像
// 序列化为引擎 ApplyParamsString 同格式的 "id=value;..." 载荷。
// v2 写协议与 APO 参数块一致（03_system_apo/ApoShared.h）：
//   写者：writeSeq 置奇数（写入中）→ 写 payload/字节数/bypass/mute
//         → writeSeq 置偶数（稳定）。
//   读者：读前取一次 writeSeq，必须为偶数且未变；拷完全部字段后
//         再取一次，两次相同才采信——写者中途改写必被识破。
// v1 是"写毕才递增、读者前后复核"的单向序号：写者未进入写入态时
// 读者已开始拷贝，载荷与 seq 可被读成半新半旧。v2 由版本全等校验
// 隔离（旧 App 的 v1 块被驱动整体拒绝，安全降级为默认参数）。
// bypass 独立成字段（不经参数串）。mute 同为独立字段（r61 验收
// 修复）：App 在 ASIO 模式内关链路总闸时置 1，驱动泵整体静音——
// 与 bypass 分工（bypass 是处理直通，mute 是无声）。字符串型参数
// v1 只携带 graph.order，其余（脚本代码、文件路径类）不经本块——
// 分隔格式承载不了任意文本，属已知约束（见方案附记）。
#define ASIO_DRIVER_PARAMS_NAME L"Global\\AuraDSP_AsioDriverParams"
#define ASIO_DRIVER_PARAMS_MAGIC 0x50444141u  // 'AADP'
#define ASIO_DRIVER_PARAMS_VERSION 2u
#define ASIO_DRIVER_PARAMS_BYTES 8192u
#define ASIO_DRIVER_PARAMS_PAYLOAD_OFFSET 64u
#define ASIO_DRIVER_PARAMS_PAYLOAD_CAP \
    (ASIO_DRIVER_PARAMS_BYTES - ASIO_DRIVER_PARAMS_PAYLOAD_OFFSET - 1u)

struct AsioDriverParamsBlock {
    uint32_t magic;          // ASIO_DRIVER_PARAMS_MAGIC
    uint32_t version;        // ASIO_DRIVER_PARAMS_VERSION
    volatile long writeSeq;  // seqlock：奇=写入中，偶=稳定
    volatile long bypass;    // 0 = 处理中，1 = 旁路
    uint32_t payloadBytes;   // payload 有效字节数（不含 NUL）
    volatile long mute;      // 1 = 链路总闸静音（原 reserved0）
    // reserved1[0]（offset 24，Dart i32[6]）自 W7 起为输出端点序号：
    // App 每次切换 RenderEndpoint 递增；驱动泵看到变化即 Close/Open
    // WASAPI 汇（Open 内重读注册表），免重开 DAW。旧 App 恒 0 不触发。
    uint32_t reserved1[10];  // 凑 payload 偏移至 64
    // char payload[PAYLOAD_CAP + 1]：NUL 结尾的 UTF-8 参数串，
    // 位于偏移 ASIO_DRIVER_PARAMS_PAYLOAD_OFFSET。
};

static_assert(ASIO_DRIVER_PARAMS_PAYLOAD_OFFSET == 64u,
              "params payload offset contract");

struct AsioDriverTelemetryBlock {
    uint32_t magic;              // ASIO_DRIVER_TELEMETRY_MAGIC
    uint32_t version;            // ASIO_DRIVER_TELEMETRY_VERSION
    uint32_t writerPid;          // 写者（DAW 宿主）进程 pid
    volatile long running;       // 1 = 泵运行中
    volatile long heartbeat;     // 泵逐块递增（读者判活）
    uint32_t sampleRate;         // DAW 协商采样率
    uint32_t channels;           // DAW 协商声道数
    uint32_t bufferSize;         // DAW 协商块长（帧）
    uint64_t processedFrames;    // 泵累计过带帧数
    float peakIn;                // 最近一块 DAW 输入峰值（ch0/1 线性）
    float peakOut;               // 最近一块处理后立体声峰值（线性）
    uint32_t updateSeq;          // 写入序号
    // ---- 汇段（汇 Open 时写定，运行期不变）----
    uint32_t sinkOpen;           // 1 = WASAPI 汇已打开
    uint32_t sinkRate;           // 汇端点混音采样率
    uint32_t sinkChannels;       // 汇端点声道数
    uint32_t sinkBits;           // 汇端点有效位深（valid bits）
    uint32_t sinkUsedConfigured; // 1 = 注册表指定端点生效；0 = 系统默认/回落
    wchar_t sinkEndpointId[96];  // 汇实际生效端点 id（App 侧映射友好名）
    // ---- v2（S4）：引擎 viz 频谱 ----
    // 与 auradsp_viz_frame 同口径（32 段对数频带、[0,1] 归一
    // 化）。旁路或引擎未装载时驱动写全零——无处理即无处理后
    // 频谱，诚实呈现。
    float spectrum[32];          // 处理链最终输出谱
    float eqInSpectrum[32];      // EQ 入口谱
    // ---- v3（r65）：逐声道峰值 ----
    // peakIn/peakOut 只有立体声折叠单值，主页电平在多声道协商下
    // 恒显示 2 格同值（r64 验收定罪）。尾加入/出逐声道峰值（线
    // 性，索引 < channels 有效，其余为 0）；旧字段语义不变，读
    // 者按 version 分支：v2 走立体声合成回落。
    float peakInCh[8];           // 处理前逐声道峰值
    float peakOutCh[8];          // 处理后（折叠前）逐声道峰值
};

static_assert(sizeof(AsioDriverTelemetryBlock) <= ASIO_DRIVER_TELEMETRY_BYTES,
              "asio driver telemetry block must fit one page");
static_assert(offsetof(AsioDriverTelemetryBlock, spectrum) == 264u,
              "v2 spectrum offset must not move");
static_assert(offsetof(AsioDriverTelemetryBlock, eqInSpectrum) == 392u,
              "v2 eqInSpectrum offset must not move");
static_assert(offsetof(AsioDriverTelemetryBlock, peakInCh) == 520u,
              "v3 peakInCh tail offset");
static_assert(sizeof(AsioDriverTelemetryBlock) == 584u,
              "v3 telemetry block size");
