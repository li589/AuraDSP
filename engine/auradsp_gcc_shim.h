/*
 * auradsp_gcc_shim.h — GCC/Clang 构建前置 shim（-include 注入，调用侧补丁）
 *
 * 与 auradsp_msvc_shim.h 对称：MSVC 侧用 /FI 注入 auradsp_msvc_shim.h，
 * Linux（GCC/Clang）侧用 -include 注入本文件。engine/legacy 保持逐字节
 * 不改（见 engine/legacy/PATCHES.md），全部适配只发生在调用侧。
 *
 * 背景与语义（S2 Linux 引擎目标实测，2026-11-01；gcc 13.3 全量验证）：
 *   1. libjamesdsp 的 essential.h（engine/legacy/essential.h）仅 include
 *      <errno.h> 却使用 stdint 类型；MSVC 侧靠 shim 垫入 <stdint.h>，
 *      GCC 侧 C 源另由 CMake 单独 -include stdint.h，本文件为 C++ 源补齐。
 *   2. legacy 的 ns-eel.h 无条件定义 min/max 函数式宏。MSVC 的标准库头
 *      对此相对宽容，libstdc++ 的 <chrono>/<algorithm> 等头会被宏直接
 *      破坏（"macro "min" requires 2 arguments"）。对策：在任何 legacy
 *      头被包含之前，先把常用标准头全部包含一遍——其 include guard 会
 *      让后续包含成为 no-op，宏定义便无从下手。
 *   3. auradsp_engine.cpp 在 extern "C" 块内 #include
 *      "engine_param_table.h"，该头又包含 <string_view> 等模板头；
 *      GCC 严格报 "template with C linkage"，MSVC 容忍。同靠第 2 条的
 *      预包含化解：块内包含的标准头都已包含过，实际展开为空。
 *   4. engine/chain/engine_convolver.cpp 使用全局 isnan/isinf（MSVC 的
 *      <cmath> 会向全局命名空间泄漏，glibc 的 <cmath> 只提供 std::）。
 *      预包含 C 头 <math.h> 后全局名可用，与既有代码保持同语义。
 *
 * 本文件只做预包含，不定义任何宏、不改动任何既有语义；Windows 构建
 * 不注入本文件，行为零变化。
 */
#ifndef AURADSP_GCC_SHIM_H
#define AURADSP_GCC_SHIM_H

#if defined(__GNUC__) || defined(__clang__)

/* C 标准头（含 <math.h> 的全局 isnan/isinf，见头注释第 4 条） */
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* C++ 标准头：必须赶在 legacy min/max 宏定义之前（见头注释第 2、3 条） */
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <thread>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#endif /* __GNUC__ || __clang__ */

#endif /* AURADSP_GCC_SHIM_H */
