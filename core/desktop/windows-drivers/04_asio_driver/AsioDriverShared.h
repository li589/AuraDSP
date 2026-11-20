// AsioDriverShared.h — AuraDSP 虚拟 ASIO 驱动跨进程契约（单一真相）
//
// ASIO 模式重构方案（docs/20-执行/ASIO模式重构方案-2026-11-20.md）
// §三的跨进程三线之二在此定型：
//   配置面：HKCU\SOFTWARE\AuraDSP\AsioDriver
//     - Channels       REG_DWORD  声道档位（既有，App 写、驱动读）
//     - RenderEndpoint REG_SZ     后端 WASAPI 汇的渲染端点 id
//                                 （S3 新增：App 写、驱动汇 Open 读；
//                                 空/缺失/失效 → 回落系统默认端点）
//   遥测面：Global\AuraDSP_AsioDriverTelemetry（S3 新增）
//     驱动泵写 → ASIO 桥在 asiostatus 中转读 → App 展示。解决
//     「DAW 侧真实例与 App 侧实例互不可见」：DAW 在场、已处理帧、
//     峰值与汇实际生效端点/格式自此有真数据源（最小集；频谱等
//     全量遥测属 S4）。
#pragma once

#include <cstdint>

#define ASIO_DRIVER_REG_KEY L"SOFTWARE\\AuraDSP\\AsioDriver"
#define ASIO_DRIVER_REG_CHANNELS L"Channels"
#define ASIO_DRIVER_REG_RENDER_ENDPOINT L"RenderEndpoint"

#define ASIO_DRIVER_TELEMETRY_NAME L"Global\\AuraDSP_AsioDriverTelemetry"
#define ASIO_DRIVER_TELEMETRY_MAGIC 0x54444141u  // 'AADT'
#define ASIO_DRIVER_TELEMETRY_VERSION 1u
#define ASIO_DRIVER_TELEMETRY_BYTES 4096u

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
};

static_assert(sizeof(AsioDriverTelemetryBlock) <= ASIO_DRIVER_TELEMETRY_BYTES,
              "asio driver telemetry block must fit one page");
