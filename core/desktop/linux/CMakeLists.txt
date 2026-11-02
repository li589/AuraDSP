cmake_minimum_required(VERSION 3.20)
project(auradsp_engine_linux LANGUAGES C CXX)

# ============================================================================
# AuraDSP 引擎 Linux 构建目标（S2，2026-11-01）
#
# 与 core/desktop/windows/CMakeLists.txt 对称：同一份可移植核心源表
# （engine/core_sources.cmake，CP-27 唯一真相）+ 本平台适配层。两个子工程
# 均可单独 `cmake -S <dir> -B <dir>/out` 配置，也可经根工程统一入口构建。
#
# 产物：out/<BuildType>/libauradsp_engine.so（与 Windows 的 out/<Config>/
# 布局对称；<BuildType> 单配置生成器取 CMAKE_BUILD_TYPE，缺省 Release）。
# 构建中间文件由根工程统一到 build/linux/x64（preset linux-x64）。
#
# 与 Windows 目标的刻意差异（全部来自《Linux适配方案-2026-11-01》取证）：
#   - 插件子系统整体裁剪（D-7）：AURADSP_ENABLE_PLUGINS 在 Linux 恒 OFF，
#     引擎编入 integration 的两个 stub，C ABI 导出集不变（F2 实测 56 符号
#     全等）。本文件不提供打开它的路径——Linux 插件宿主属后续独立立项。
#   - legacy 源表排除 jamesdsp.c（E4）：其 GCC constructor/destructor 会与
#     auradsp_engine.cpp 的 global_init()/有意不调 Deallocation 策略双跑；
#     它只是 Android effects HAL 入口，桌面引擎不需要。
#   - 导出控制用 version script（E2）：engine/auradsp_engine.map 由 .def
#     同源生成（tools/bin/gen_engine_map.py），其 local:* 条目使 .so 动态
#     导出集 == .def 的 56 符号。注意不叠加 -fvisibility=hidden：本仓 ABI
#     头没有 visibility 宏，hidden 会把 56 个 ABI 符号一并隐藏（S2 实测
#     导出归零），version script 单独即可完成导出集收口。
#   - stdint 垫片（E3）：C 源 -include stdint.h；C++ 源 -include
#     engine/auradsp_gcc_shim.h（与 MSVC 的 /FI auradsp_msvc_shim.h 对称，
#     另解 legacy min/max 宏与 extern "C" 内包含模板头两处 GCC 严格性）。
# ============================================================================

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "core/desktop/linux 仅用于 Linux 构建。")
endif()

# 单配置生成器（Ninja/Make）缺省 Release：与 Windows Release 成品对齐；
# -O0 会让 legacy 的 C99 inline 产生未定义符号（实测 task_start* 等），
# 且 Release 才是符号/性能验收口径。显式 -DCMAKE_BUILD_TYPE 优先。
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Build type" FORCE)
endif()

# D-7：Linux 首期只做插件消费者，宿主整体裁剪（见文件头）。
option(AURADSP_ENABLE_PLUGINS "Build VST3/CLAP plugin hosting subsystem (Windows only)" OFF)
if(AURADSP_ENABLE_PLUGINS)
    message(WARNING
        "Linux 首期不支持插件宿主（ADR-012 D-7），AURADSP_ENABLE_PLUGINS "
        "已被强制置 OFF；引擎将编入 ABI/链阶段 stub，导出集不变。")
    set(AURADSP_ENABLE_PLUGINS OFF CACHE BOOL "Build VST3/CLAP plugin hosting subsystem (Windows only)" FORCE)
endif()

# 产物路径：与 Windows 对称的 out/<Config>/，落在子工程目录内（根工程
# 统一入口构建时亦然，Flutter 同步与历史 smoke 的路径依赖由此保持）。
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/out/${CMAKE_BUILD_TYPE}")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/out/${CMAKE_BUILD_TYPE}")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/out/${CMAKE_BUILD_TYPE}")

set(PLUGIN_API "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/plugin-api")
set(API        "${CMAKE_CURRENT_SOURCE_DIR}/../../../engine")
set(LEGACY     "${API}/legacy")

# CP-27：可移植核心源表（唯一真相），Windows / Linux 共用同一份清单。
include("${API}/core_sources.cmake")

# E4：Linux 源表排除 jamesdsp.c（Android HAL 入口 + GCC constructor 双跑，
# 见文件头）。eel2/cpthread.c 的排除已在 core_sources.cmake 内完成。
list(FILTER AURADSP_CORE_LEGACY_C EXCLUDE REGEX "legacy/jamesdsp\\.c$")

# 注意：core 在 Linux 必须用 OBJECT 而非 STATIC——MSVC 靠 .def 的导出清单
# 强制抽取静态库成员，ELF 的 version script 没有这个作用，STATIC 归档成员
# 会因无人引用而不被抽取、产出空 .so（S2 首测实测导出 0 个）。这与 Windows
# 侧 auradsp_wincompat 用 OBJECT 库的理由相同（见 windows/CMakeLists.txt）。
add_library(auradsp_core OBJECT
    ${AURADSP_CORE_LEGACY_C}
    ${AURADSP_CORE_CXX_SOURCES}
)
target_include_directories(auradsp_core PUBLIC
    "${API}"
    "${API}/chain"
    "${API}/plugins/api"
    "${API}/plugins/driver"
    "${LEGACY}"
    "${LEGACY}/jdsp"
    "${PLUGIN_API}"
)
# C：gnu11（保住 legacy 的 GNU 扩展，对齐 Android build_jdsp.sh 实测口径）
# + -include stdint.h 解 E3。C++：c++20 + gcc shim 前置（见文件头）。
set_property(TARGET auradsp_core PROPERTY C_STANDARD 11)
set_property(TARGET auradsp_core PROPERTY C_EXTENSIONS ON)
set_property(TARGET auradsp_core PROPERTY CXX_STANDARD 20)
# core 的对象文件最终链入 .so，必须 -fPIC（首测实测：engine_viz.cpp 的
# thread_local 静态量以非 PIC 重定位链入共享库会被 ld 拒绝）。
set_property(TARGET auradsp_core PROPERTY POSITION_INDEPENDENT_CODE ON)
target_compile_options(auradsp_core PRIVATE
    $<$<COMPILE_LANGUAGE:C>:-include stdint.h>
    $<$<COMPILE_LANGUAGE:CXX>:-include ${API}/auradsp_gcc_shim.h>
)
# GCC 14 起把五条 C 诊断从警告升为默认错误（GCC 14 变更清单：
# incompatible-pointer-types / implicit-function-declaration /
# int-conversion / implicit-int / return-mismatch）。legacy C 是冻结
# 代码（只读，MSVC 与 GCC ≤13 均以警告通过），不改源码、只在 Linux
# 目标把这五条整组降回警告，与 -include stdint.h 同类的工具链垫片。
# CI 首跑（ubuntu-latest = GCC 14）先由 crossfeed.c 抓到前三条、
# 第二跑由 nseel-compiler.c 抓到 implicit-int，故按全集一次到位。
# 版本守卫必须有：-Wreturn-mismatch 是 GCC 14 新增的诊断名，
# GCC ≤13 对不认识的 -Wno-error= 选项会直接报错。
if(CMAKE_C_COMPILER_ID STREQUAL "GNU" AND
   CMAKE_C_COMPILER_VERSION VERSION_GREATER_EQUAL 14)
    target_compile_options(auradsp_core PRIVATE
        $<$<COMPILE_LANGUAGE:C>:-Wno-error=incompatible-pointer-types>
        $<$<COMPILE_LANGUAGE:C>:-Wno-error=implicit-function-declaration>
        $<$<COMPILE_LANGUAGE:C>:-Wno-error=int-conversion>
        $<$<COMPILE_LANGUAGE:C>:-Wno-error=implicit-int>
        $<$<COMPILE_LANGUAGE:C>:-Wno-error=return-mismatch>
    )
endif()
set_source_files_properties(${AURADSP_CORE_LEGACY_C} PROPERTIES LANGUAGE C)
if(NOT AURADSP_ENABLE_PLUGINS)
    # 与 Windows 裁剪构建同义：core 内的 handle 定义必须与引擎使用同一
    # AURADSP_NO_PLUGINS 视图（CP-02）。
    target_compile_definitions(auradsp_core PRIVATE AURADSP_NO_PLUGINS=1)
endif()

find_package(Threads REQUIRED)

# 引擎 .so：核心 + Linux 平台适配（M1/M2 唯一 OS 落点）+ 插件裁剪 stub。
add_library(auradsp_engine SHARED
    "${API}/platform/linux/fs_linux.cpp"
    "${API}/platform/linux/env_linux.cpp"
    "${API}/platform/linux/log_linux.cpp"
    "${API}/platform/linux/module_linux.cpp"
    "${API}/plugins/integration/plugin_chain_adapter_stub.cpp"
    "${API}/plugins/integration/plugin_abi_stub.cpp"
)
target_compile_options(auradsp_engine PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-include ${API}/auradsp_gcc_shim.h>
)
target_include_directories(auradsp_engine PRIVATE
    "${API}"
    "${API}/chain"
    "${API}/plugins/api"
)
# E2：version script 控导出集（由 .def 同源生成，gen_engine_map.py 守卫）。
target_link_options(auradsp_engine PRIVATE
    "LINKER:--version-script=${API}/auradsp_engine.map"
)
set_property(TARGET auradsp_engine PROPERTY LINK_DEPENDS "${API}/auradsp_engine.map")
target_link_libraries(auradsp_engine PRIVATE
    auradsp_core
    Threads::Threads
    ${CMAKE_DL_LIBS}
    m
)
