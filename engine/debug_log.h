#pragma once
// engine/debug_log.h — 宿主调试日志统一宏（B-1 / 计划 D1，2026-10-19）
//
// 设计（两级开关）：
//   1) 编译期一级开关：CMake -DAURADSP_DBG_LOG=ON 定义同名宏（默认 OFF，Release/Debug
//      构建均默认剥离）。关闭时 AURADSP_DBG* / AURADSP_WARN* 展开为空——格式串字面量
//      与参数表达式完全不进二进制、不求值（strings 扫描不可见、零运行开销）。
//   2) 运行期二级开关（仅编译开启时有效）：环境变量 AURADSP_LOG=0|1|2
//      0=静默 1=仅 WARN 2=全量（默认 2）。启动后首条日志时读取一次。
//
// 输出通道：平台端口 port/log.h（Windows 实现为 OutputDebugStringA —— GUI 进程内
//   无控制台也可靠，DebugView / VS Output 可见），不劫持 stdout。
// 格式："[AuraDSP][vst3_instance.cpp:434] <message>\n"
//
// 铁律：仅限宿主控制线程（load / unload / editor 生命周期路径）；严禁进入
//   auradsp_process 音频 RT 路径（RT-Safe：零分配零锁零系统调用）。
//
// 用法：
//   AURADSP_DBG("[DBG Slot] unloadLocked[%d] complete", slot);        // 纯格式化
//   AURADSP_DBG_S("[DBG VST3] res=" << res << " ptr=" << p);          // 流式（保原 << 语义）
//   AURADSP_WARN("[DBG Pump] main thread failed to start");           // AURADSP_LOG>=1
//   AURADSP_WARN_S("[DBG CLAP showEditor] err=" << GetLastError());   // 故障级流式
//
// 兼容说明：流式形态为既有 cout 站点的 1:1 机械转换而设（ostream 逐字等价，
//   无需逐点推断类型）；新增代码优先用 printf 形态。

#ifdef AURADSP_DBG_LOG

#include "platform/port/log.h"

#include <cstdio>
#include <cstdarg>
#include <sstream>

namespace jamesdsp {
namespace dbg {

// 直发已成形消息（流式形态用）；级别过滤/格式化/输出通道由平台端口实现。
inline void emitMsg(int minLevel, const char* file, int line, const char* msg) {
    ::auradsp::platform::log_emit(minLevel, file, line, msg);
}

// printf 形态（格式串非法时 vsnprintf 亦仅截断，不 UB 到崩溃）
inline void emit(int minLevel, const char* file, int line, const char* fmt, ...) {
    if (::auradsp::platform::log_level() < minLevel) return;
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    emitMsg(minLevel, file, line, msg);
}

} // namespace dbg
} // namespace jamesdsp

#define AURADSP_DBG(...)                                                    \
    ::jamesdsp::dbg::emit(2, __FILE__, __LINE__, __VA_ARGS__)
#define AURADSP_WARN(...)                                                   \
    ::jamesdsp::dbg::emit(1, __FILE__, __LINE__, __VA_ARGS__)

// 流式形态：表达式先按级别短路，再经 ostream 成形（与原 std::cout << 逐字等价）
#define AURADSP_DBG_S(...)                                                  \
    do {                                                                    \
        if (::auradsp::platform::log_level() >= 2) {                        \
            std::ostringstream auradsp_dbg_oss;                             \
            auradsp_dbg_oss << __VA_ARGS__;                                 \
            ::jamesdsp::dbg::emitMsg(2, __FILE__, __LINE__,                 \
                                     auradsp_dbg_oss.str().c_str());        \
        }                                                                   \
    } while (0)
#define AURADSP_WARN_S(...)                                                 \
    do {                                                                    \
        if (::auradsp::platform::log_level() >= 1) {                        \
            std::ostringstream auradsp_dbg_oss;                             \
            auradsp_dbg_oss << __VA_ARGS__;                                 \
            ::jamesdsp::dbg::emitMsg(1, __FILE__, __LINE__,                 \
                                     auradsp_dbg_oss.str().c_str());        \
        }                                                                   \
    } while (0)

#else // !AURADSP_DBG_LOG —— 默认构建：编译期整体剥离（字面量不进二进制、不求值）

#define AURADSP_DBG(...)         ((void)0)
#define AURADSP_WARN(...)        ((void)0)
#define AURADSP_DBG_S(...)       ((void)0)
#define AURADSP_WARN_S(...)      ((void)0)

#endif // AURADSP_DBG_LOG
