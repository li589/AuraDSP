// AsioHost.h — ASIO 宿主封装（04_asio_engine Phase 1）
//
// 定位（见 docs/20-执行/ASIO驱动开工Spec-2026-10-14.md §2）：
//   只做传输搬运——枚举/加载第三方 ASIO 驱动、查询能力、在 bufferSwitch
//   回调内填充输出缓冲。不承载任何音效算法（算法全在 engine/）。
//
// 许可：依赖 Steinberg ASIO SDK 2.3.4（GPLv3 路线，见 04_asio_engine/README.md）。
//   SDK 不 vendor 进仓库；本头文件只引用 SDK 的公共接口类型。
//
// RT 铁律（与 02_voicemeeter_client / 05_vm_bridge 同款）：
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

    // 创建输出声道 0/1 的双声道缓冲（v1 不建输入缓冲）。
    // bufSize<=0 用 preferredSize。失败时 why 说明（声道不足/格式不支持等）。
    bool create_output_stereo(long bufSize, std::string& why);

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

private:
    // ---- SDK 回调（自由函数；经 s_active 转发）----
    static void buffer_switch(long doubleBufferIndex, ASIOBool directProcess);
    static void sample_rate_did_change(ASIOSampleRate sRate);
    static long asio_message(long selector, long value, void* message, double* opt);
    static ASIOTime* buffer_switch_time_info(ASIOTime* params, long doubleBufferIndex,
                                             ASIOBool directProcess);

    void process(long doubleBufferIndex);   // RT：仅原子量 + 缓冲写

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

    // tone 状态（控制线程写 / RT 读，全原子）
    std::atomic<bool> toneOn_{false};
    std::atomic<float> toneFreq_{440.0f};
    std::atomic<float> toneAmp_{0.25f};
    double phase_ = 0.0;               // 仅 RT 线程触碰
    std::atomic<uint64_t> switches_{0};
    std::atomic<float> peak_{0.0f};
    std::atomic<double> srLive_{0.0};  // sampleRateDidChange 更新；RT 读
};

}  // namespace auraasio
