// AsioHost.h — ASIO 宿主封装（04_asio_engine Phase 1）
//
// 定位（见 docs/20-执行/ASIO驱动开工Spec-2026-10-14.md §2）：
//   只做传输搬运——枚举/加载第三方 ASIO 驱动、查询能力、在 bufferSwitch
//   回调内填充输出缓冲。不承载任何音效算法（算法全在 engine/）。
//
// 许可：依赖 Steinberg ASIO SDK 2.3.4（GPLv3 路线，见 04_asio_engine/README.md）。
//   SDK 不 vendor 进仓库；本头文件只引用 SDK 的公共接口类型。
//
// RT 铁律（与 02_voicemeeter_client / bridge/vm_bridge 同款）：
//   bufferSwitch 即驱动 RT 线程——process() 内零分配、零锁、零 syscall、零日志，
//   仅读原子量 + 写输出缓冲。控制面（open/close/start/stop/tone_set）全在调用线程。
//
// 单实例约束：SDK 的驱动模型是进程级全局（theAsioDriver / asioDrivers 单例），
//   回调又是自由函数，故本封装用 s_active 静态指针转发——**同一进程同时只允许
//   一个 AsioHost 处于打开状态**。Phase 2 桥（auraasio_bridge）沿用同一约束。

#pragma once

#include <stdint.h>
#include <atomic>
#include <string>
#include <vector>

// ---- Steinberg ASIO SDK 2.3.4（GPLv3；外部工具链，见 README）----
// 包含顺序必须与 SDK 样例一致：asiosys.h 先于 asio.h（否则 NATIVE_INT64 /
// IEEE754_64FLOAT 未定义，ASIOSampleRate/ASIOSamples 会退化为结构体形态）。
#include <windows.h>   // 先于 iasiodrv.h：提供 IUnknown / interface 宏
#include "asiosys.h"
#include "asio.h"
#include "iasiodrv.h"

namespace auraasio {

// 桥用 scratch 上限（与 02/05 的 kMaxNbs 同值）：超出则该块声道级直通，
// 不进引擎（防堆不足；实测 VM 给 2048、FL Studio 给 512，余量充足）。
constexpr long kMaxNbs = 4096;

// 注册表枚举条目（不加载 COM；来自 AsioDriverList）
struct DriverEntry {
    std::string name;       // 注册表原始字节（CP_ACP）——loadAsioDriver 的匹配键，勿改
    std::string nameUtf8;   // name 的 UTF-8 显示名（中文驱动名正确显示用）
    std::string dllPath;    // DLL 路径（部分驱动探测不到，为空）
    std::string clsid;      // "{XXXXXXXX-....}" 形式
};

// CP_ACP（本机 GBK）→ UTF-8。注册表读出的驱动名是 ANSI 字节，
// 直接进 JSON/UI 会乱码；load 仍用原始 name（SDK 内部 strcmp 语义）。
std::string ansi_to_utf8(const char* s);

// 枚举 HKLM\SOFTWARE\ASIO（进程位视图：x64 工具见 64 位驱动）。
// 控制线程调用；内部会 new/free（非 RT）。
std::vector<DriverEntry> enumerate_drivers();

// 主动释放当前驱动 COM 对象（SDK 单例 asioDrivers 的 removeCurrentDriver）。
// 桥停止时序用：ASIOExit 之后、下次 start 的 loadDriver 之前。控制线程调用。
void release_active_driver();

// ASIOSampleType → 可读名（仅列宿主支持的格式）
const char* sample_type_name(long type);

// 能力快照（open 成功后由 query_caps 填充）
struct DriverCaps {
    bool ok = false;
    std::string driverName;      // 驱动自报名（ASIODriverInfo.name）
    std::string errorMessage;    // init 失败时的驱动消息
    long asioVersion = 0;
    long driverVersion = 0;
    long inChannels = 0;
    long outChannels = 0;
    long minBuf = 0;
    long maxBuf = 0;
    long prefBuf = 0;
    long granularity = 0;
    long inLatency = 0;
    long outLatency = 0;
    double sampleRate = 0.0;
    long out0Type = -1;          // 输出声道 0 的 ASIOSampleType
    std::string out0TypeName;
    std::string out0Name;        // 输出声道 0 名
    long out0Active = 0;
};

class AsioHost {
public:
    AsioHost() = default;
    ~AsioHost();
    AsioHost(const AsioHost&) = delete;
    AsioHost& operator=(const AsioHost&) = delete;

    // 加载并初始化驱动。driverName 为注册表名（enumerate_drivers 的 name）。
    // sysRef：Windows 为主窗口句柄（控制台传 GetConsoleWindow()，可空）。
    // 失败时 why 收到原因；成功后必须 close()。
    bool open(const char* driverName, void* sysRef, std::string& why);

    // stop → disposeBuffers → ASIOExit → removeDriver；幂等，可反复调用。
    void close();

    bool opened() const { return opened_; }

    // 能力查询（open 成功后）
    bool query_caps(DriverCaps& out);

    // 创建输出声道 0/1 的双声道缓冲（v1 不建输入缓冲；tone 用）。
    // bufSize<=0 用 preferredSize。失败时 why 说明（声道不足/格式不支持等）。
    bool create_output_stereo(long bufSize, std::string& why);

    // ---- Phase 2 桥用：输入 ch0/1 + 输出 outPair/outPair+1 双声道缓冲 ----
    // 处理 sink：in/out 为交织 stereo float32（frames 帧），RT 线程调用；
    // in 允许改写（测试注入语义：测试信号替换真实输入，同 05 FillTestSignal 用法）。
    // 实现方必须零分配零锁零 syscall（桥内即 FillTestSignal → engine process/bypass）。
    // nullptr = 回 tone 模式（Phase 1 行为，与 create_output_stereo 配套）。
    using ProcessSink = void (*)(void* ctx, float* in, float* out, int frames);

    // outPair<0 或越界按 0；bufSize<=0 用 preferredSize。失败时 why 说明。
    // 输入/输出声道均限 Float32LSB 原生 + Int32/Int24/Int16LSB 换算（R-6：不猜格式）。
    bool create_stereo_io(long bufSize, long outPair, std::string& why);

    // 设置处理 sink（控制线程；start 前后都可；须在 create_stereo_io 之后生效）。
    void set_process_sink(ProcessSink fn, void* ctx);

    bool start();       // ASIOStart
    void stop();        // ASIOStop（幂等）
    bool running() const { return running_; }

    long buffer_size() const { return bufSize_; }
    double sample_rate() const { return sampleRate_; }
    long out_sample_type() const { return outType_[0]; }

    // ---- tone 发生源（RT 安全）----
    void tone_set(float freqHz, float amp);   // 控制线程；start 前后都可
    void tone_off();                          // 控制线程；停后输出静音
    bool tone_active() const { return toneOn_.load(std::memory_order_acquire); }

    // 统计（控制线程读）
    uint64_t switch_count() const { return switches_.load(std::memory_order_relaxed); }
    float peak_out() const { return peak_.load(std::memory_order_relaxed); }
    float peak_in() const { return peakIn_.load(std::memory_order_relaxed); }   // Phase 2 io 模式
    uint64_t max_cb_ticks() const { return maxCbTicks_.load(std::memory_order_relaxed); }  // QPC ticks
    // Phase 4 加固：最近一次 bufferSwitch 的 QPC（RT 每帧写；掉线检测在控制面算）
    uint64_t last_switch_qpc() const { return lastSwitchQpc_.load(std::memory_order_relaxed); }
    // Phase 4 加固：驱动请求信号（asioMessage 置位、控制面消费；桥 start 时清零）
    bool reset_pending() const { return resetPending_.load(std::memory_order_acquire); }
    bool latencies_changed() const { return latenciesChanged_.load(std::memory_order_acquire); }
    void clear_reset_pending() { resetPending_.store(false, std::memory_order_release); }
    void clear_latencies_changed() { latenciesChanged_.store(false, std::memory_order_release); }

private:
    // ---- SDK 回调（自由函数；经 s_active 转发）----
    static void buffer_switch(long doubleBufferIndex, ASIOBool directProcess);
    static void sample_rate_did_change(ASIOSampleRate sRate);
    static long asio_message(long selector, long value, void* message, double* opt);
    static ASIOTime* buffer_switch_time_info(ASIOTime* params, long doubleBufferIndex,
                                             ASIOBool directProcess);

    void process(long doubleBufferIndex);       // RT：tone 或 io 分发
    void process_io(long doubleBufferIndex);    // RT：输入交织 → sink → 输出分声道

    // ASIOCreateBuffers 的回调结构体：**进程级生存期**。驱动按 ASIO 契约
    // 长期持有该指针（存引擎对象 +0xd0），RT 线程每次 bufferSwitch 都经它
    // 回调——栈局部会在 create_* 返回后失效并被后续调用覆写，驱动首次回调
    // 即踩垃圾指针（2026-10-15 定罪：FL Studio ASIO 下"桥必崩、tone 侥幸
    // 存活"的真相；tone 只是后续调用链浅、栈槽侥幸未被覆写）。
    static ASIOCallbacks s_cb;
    static AsioHost* s_active;   // 单活跃实例（SDK 进程级全局驱动模型所致）

    bool opened_ = false;
    bool buffers_ = false;
    bool running_ = false;
    long bufSize_ = 0;
    double sampleRate_ = 0.0;          // start 前由控制线程写；RT 只读快照进局部
    std::string driverName_;           // ASIOInit 回填的驱动自报名
    long asioVersion_ = 0;             // ASIOInit 回填（驱动实现的 ASIO 版本）
    long driverVersion_ = 0;           // ASIOInit 回填（驱动特定版本号）
    long outType_[2] = { -1, -1 };     // 每声道 ASIOSampleType
    void* outBufs_[2][2] = {};         // [声道][doubleBufferIndex]

    // ---- Phase 2 io 模式（create_stereo_io 才非空）----
    long inType_[2] = { -1, -1 };      // 输入声道 0/1 的 ASIOSampleType
    void* inBufs_[2][2] = {};          // [声道][doubleBufferIndex]
    float* scratchIn_ = nullptr;       // 2*kMaxNbs，create_stereo_io 分配 / close 释放
    float* scratchOut_ = nullptr;
    ProcessSink sink_ = nullptr;       // 控制线程写、start 前定稿；RT 只读
    void* sinkCtx_ = nullptr;
    long outPair_ = 0;                 // 输出对起始声道（信息性）

    // tone 状态（控制线程写 / RT 读，全原子）
    std::atomic<bool> toneOn_{false};
    std::atomic<float> toneFreq_{440.0f};
    std::atomic<float> toneAmp_{0.25f};
    double phase_ = 0.0;               // 仅 RT 线程触碰
    std::atomic<uint64_t> switches_{0};
    std::atomic<float> peak_{0.0f};
    std::atomic<float> peakIn_{0.0f};  // io 模式输入峰值
    std::atomic<uint64_t> maxCbTicks_{0};  // io 模式单次回调最大耗时（QPC ticks）
    std::atomic<double> srLive_{0.0};  // sampleRateDidChange 更新；RT 读
    // Phase 4 加固（全原子；RT 写/控制面读写）
    std::atomic<uint64_t> lastSwitchQpc_{0};   // 最近 bufferSwitch 的 QPC ticks
    std::atomic<bool> resetPending_{false};    // kAsioResetRequest 未消费
    std::atomic<bool> latenciesChanged_{false}; // kAsioLatenciesChanged 未消费
};

}  // namespace auraasio
