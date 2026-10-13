/*
 * auradsp_msvc_shim.h — MSVC 构建前置 shim（/FI 注入，调用侧补丁，铁律 §3.3）
 *
 * 背景与语义（vendor-src 保持逐字节不改，见 ORIGIN.md）：
 *   1. libjamesdsp 的 essential.h 仅 include <errno.h>，NDK 环境经 libc 头链
 *      间接获得 <stdint.h>；MSVC 不会 → 此处强制包含。
 *   2. jamesdsp.c:825/832 使用 GCC 扩展 __attribute__((constructor/destructor))
 *      做 DLL 加载/卸载时的 JamesDSPGlobalMemory(De)Allocation()。MSVC 不支持
 *      该语法。抹除后由 auradsp_engine.cpp 的 global_init() 引用计数显式替代：
 *        - constructor 语义 → global_init() 首实例调用 GlobalMemoryAllocation ✓
 *        - destructor 语义 → 对齐 Android 侧做法有意不调 Deallocation
 *          （NSEEL 卸载期风险 > 进程退出前泄漏，见 JamesDspEngine.cpp:52-55）
 *   3. 其余 __attribute__ 用法（UNUSED/WARN_UNUSED/STBSP__ASAN）抹除无副作用；
 *      dr_flac/dr_mp3/dr_wav 自带 _WIN32 分支不受影响。
 */
#ifndef AURADSP_MSVC_SHIM_H
#define AURADSP_MSVC_SHIM_H

#ifdef _MSC_VER
#include <stdint.h>
#define __attribute__(x)
#endif

#endif /* AURADSP_MSVC_SHIM_H */
