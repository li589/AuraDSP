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
//     v2 于 S4 扩频谱）
//     驱动泵写 → ASIO 桥在 asiostatus 中转读 → App 展示。解决
//     「DAW 侧真实例与 App 侧实例互不可见」：DAW 在场、已处理帧、
//     峰值与汇实际生效端点/格式自此有真数据源。
//   参数面：Global\AuraDSP_AsioDriverParams（S4 新增）
//     App 写 → 驱动泵读：seq 变化即把参数串应用到 DAW 进程内
//     的引擎实例（此前该引擎恒跑默认参数）；bypass 同块下发。
//     App 在虚拟形态下不再自开驱动会话（去假会话），本块与
//     遥测块即虚拟形态的全部跨进程通道。
#pragma once

#include <cstdint>

#define ASIO_DRIVER_REG_KEY L"SOFTWARE\\AuraDSP\\AsioDriver"
#define ASIO_DRIVER_REG_CHANNELS L"Channels"
#define ASIO_DRIVER_REG_RENDER_ENDPOINT L"RenderEndpoint"

#define ASIO_DRIVER_TELEMETRY_NAME L"Global\\AuraDSP_AsioDriverTelemetry"
#define ASIO_DRIVER_TELEMETRY_MAGIC 0x54444141u  // 'AADT'
#define ASIO_DRIVER_TELEMETRY_VERSION 2u
#define ASIO_DRIVER_TELEMETRY_BYTES 4096u

// ---- 参数块（S4）：App 写、驱动读 ----
// App（isolate 内的 AsioParamPublisher）是唯一写者：把参数镜像
// 序列化为引擎 ApplyParamsString 同格式的 "id=value;..." 载荷
// 写入 payload，写毕才递增 seq（驱动以 seq 变化为应用触发，
// 应用前后再读 seq 复核载荷稳定）。bypass 独立成字段（不经
// 参数串）。字符串型参数 v1 只携带 graph.order，其余（脚本
// 代码、文件路径类）不经本块——分隔格式承载不了任意文本，
// 属已知约束（见方案附记）。
#define ASIO_DRIVER_PARAMS_NAME L"Global\\AuraDSP_AsioDriverParams"
#define ASIO_DRIVER_PARAMS_MAGIC 0x50444141u  // 'AADP'
#define ASIO_DRIVER_PARAMS_VERSION 1u
#define ASIO_DRIVER_PARAMS_BYTES 8192u
#define ASIO_DRIVER_PARAMS_PAYLOAD_OFFSET 64u
#define ASIO_DRIVER_PARAMS_PAYLOAD_CAP \
    (ASIO_DRIVER_PARAMS_BYTES - ASIO_DRIVER_PARAMS_PAYLOAD_OFFSET - 1u)

struct AsioDriverParamsBlock {
    uint32_t magic;          // ASIO_DRIVER_PARAMS_MAGIC
    uint32_t version;        // ASIO_DRIVER_PARAMS_VERSION
    volatile long seq;       // 写者递增：载荷 + bypass 的版本号
    volatile long bypass;    // 0 = 处理中，1 = 旁路
    uint32_t payloadBytes;   // payload 有效字节数（不含 NUL）
    uint32_t reserved0;
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
};

static_assert(sizeof(AsioDriverTelemetryBlock) <= ASIO_DRIVER_TELEMETRY_BYTES,
              "asio driver telemetry block must fit one page");
