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
#   - 插件子系统（二期阶段一更新）：一期 D-7 按 CP-24 先行关闭；
#     《Linux插件宿主实施方案-2026-11-02》立项后已转正，启用路径见
#     下方 AURADSP_ENABLE_PLUGINS 块。关掉仍编 stub 且 C ABI 导出集
#     不变（实测 56 符号全等）。
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

# 插件子系统（《Linux插件宿主实施方案-2026-11-02》阶段一）：默认
# ON，进程内宿主——platform/posix 对应物 + driver/formats/integration
# 真实源表；OFF 编 stub（裁剪）。产物目录按开关分离（out / out-
# noplugins，与 Windows 同口径）：core 的 NO_PLUGINS 视图须与链接进
# 同一 .so 的源一致，独立目录防增量构建混杂。
option(AURADSP_ENABLE_PLUGINS "Build VST3/CLAP plugin hosting subsystem" ON)
# 进程外宿主（与 Windows 同名同义）：ON 时引擎编入远程客户端/代理
# （platform/posix/host），运行时经 AURA_PLUGIN_HOST_MODE=process
# 启用 plugin_host_x64 隔离宿主，未启用时同进程内直通（manager 的
# remoteMode 运行时分派，两路俱在）；OFF 时引擎定义 HOST_INPROC
# 恒进程内（裁剪构建）。宿主可执行体随 ON 一并产出。
option(AURADSP_PLUGIN_HOST_REMOTE "Build out-of-process plugin host (plugin_host_x64)" ON)
if(AURADSP_ENABLE_PLUGINS)
    set(AURADSP_OUT_DIR_NAME "out")
else()
    set(AURADSP_OUT_DIR_NAME "out-noplugins")
endif()

# 产物路径：与 Windows 对称的 out/<Config>/，落在子工程目录内（根工程
# 统一入口构建时亦然，Flutter 同步与历史 smoke 的路径依赖由此保持）。
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${AURADSP_OUT_DIR_NAME}/${CMAKE_BUILD_TYPE}")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${AURADSP_OUT_DIR_NAME}/${CMAKE_BUILD_TYPE}")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${AURADSP_OUT_DIR_NAME}/${CMAKE_BUILD_TYPE}")

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

# 引擎 .so：核心 + Linux 平台适配（M1/M2 唯一 OS 落点）+ 插件层。
if(AURADSP_ENABLE_PLUGINS)
    # 插件层真实源表（与 Windows 工程同集，去平台专属文件）：
    # driver 全集 + formats 全集 + integration 真实实现；平台层用
    # platform/posix 对应物（include 路径二选一，源码以裸名取
    # win32_util.h / module_pump.h）。
    set(AURADSP_PLUGIN_SOURCES
        "${API}/plugins/driver/plugin_bundle.cpp"
        "${API}/plugins/driver/plugin_scanner.cpp"
        "${API}/plugins/driver/plugin_driver_registry.cpp"
        "${API}/plugins/driver/plugin_json.cpp"
        "${API}/plugins/driver/plugin_thread.cpp"
        "${API}/plugins/driver/plugin_host_manager.cpp"
        "${API}/plugins/driver/plugin_chain_component.cpp"
        "${API}/plugins/formats/clap/clap_driver.cpp"
        "${API}/plugins/formats/clap/clap_instance.cpp"
        "${API}/plugins/formats/clap/clap_metadata.cpp"
        "${API}/plugins/formats/vst3/vst3_driver.cpp"
        "${API}/plugins/formats/vst3/vst3_instance.cpp"
        "${API}/plugins/formats/vst3/vst3_metadata.cpp"
        # VST2（2026-11-04 Linux 跟进）：驱动/实例/元数据，编译头是
        # vendor/plugin-api/vst2/vst.h（Xaymar 净室）；__cdecl 习语
        # 由 platform/posix/win32_compat.h 的空定义消解。
        "${API}/plugins/formats/vst2/vst2_driver.cpp"
        "${API}/plugins/formats/vst2/vst2_instance.cpp"
        "${API}/plugins/formats/vst2/vst2_metadata.cpp"
        "${API}/plugins/integration/plugin_host.cpp"
        "${API}/plugins/integration/plugin_engine_state.cpp"
        "${API}/plugins/integration/plugin_chain_adapter.cpp"
        "${API}/plugins/integration/plugin_abi.cpp"
        "${API}/plugins/platform/posix/plugin_util_posix.cpp"
        "${API}/plugins/platform/posix/plugin_gui_x11.cpp"
        # 注：vendor 的 Steinberg SDK 为单头 amalgamation
        # （<steinberg/vst3_static.h>），无 .cpp 实现单元，与
        # Windows 工程同口径不列 SDK 源。
    )
else()
    set(AURADSP_PLUGIN_SOURCES
        "${API}/plugins/integration/plugin_chain_adapter_stub.cpp"
        "${API}/plugins/integration/plugin_abi_stub.cpp"
    )
endif()
add_library(auradsp_engine SHARED
    "${API}/platform/linux/fs_linux.cpp"
    "${API}/platform/linux/env_linux.cpp"
    "${API}/platform/linux/log_linux.cpp"
    "${API}/platform/linux/module_linux.cpp"
    ${AURADSP_PLUGIN_SOURCES}
)
target_compile_options(auradsp_engine PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-include ${API}/auradsp_gcc_shim.h>
)
target_include_directories(auradsp_engine PRIVATE
    "${API}"
    "${API}/chain"
    "${API}/plugins/api"
)
if(AURADSP_ENABLE_PLUGINS)
    # 引擎目标 C++20（atomic::notify_all 等在插件层；探针实测）。
    set_property(TARGET auradsp_engine PROPERTY CXX_STANDARD 20)
    if(AURADSP_PLUGIN_HOST_REMOTE)
        # 远程模式：不定义 HOST_INPROC，manager 在运行时按
        # client.start()（环境变量 + 宿主在位）分派远程/进程内。
        target_sources(auradsp_engine PRIVATE
            "${API}/plugins/platform/posix/host/plugin_shared_region_posix.cpp"
            "${API}/plugins/platform/posix/host/plugin_host_client_posix.cpp"
            "${API}/plugins/platform/win32/host/process_plugin_proxy.cpp"
        )
    else()
        target_compile_definitions(auradsp_engine PRIVATE
            AURADSP_HOST_INPROC=1
        )
    endif()
    target_include_directories(auradsp_engine PRIVATE
        "${API}/plugins/driver"
        "${API}/plugins/platform/win32/host"
        "${API}/plugins/platform/posix"
        "${LEGACY}"
        "${LEGACY}/jdsp"
        "${PLUGIN_API}"
    )
endif()
# E2：version script 控导出集（由 .def 同源生成，gen_engine_map.py 守卫）。
target_link_options(auradsp_engine PRIVATE
    "LINKER:--version-script=${API}/auradsp_engine.map"
)
# VST2 净室头在头内定义两张已初始化的常量表（vst_host_supports /
# vst_effect_supports），多 TU 包含即多重定义：MSVC 链接器自行折叠，
# ELF ld 需显式允许。两份内容逐字节相同（同一头文件），取先者语义
# 精确；引擎代码不引用这两张表。（仅 PLUGINS 口味实际包含 VST2 源，
# 选项对裁剪口味无副作用。）
target_link_options(auradsp_engine PRIVATE
    "LINKER:--allow-multiple-definition"
)
set_property(TARGET auradsp_engine PROPERTY LINK_DEPENDS "${API}/auradsp_engine.map")
target_link_libraries(auradsp_engine PRIVATE
    auradsp_core
    Threads::Threads
    ${CMAKE_DL_LIBS}
    m
)

# 进程外宿主 plugin_host_x64（双宿主架构，Linux 无扩展名）：与
# Windows 的 auradsp_plugin_host 目标对位——宿主自带一份插件层
# （driver/formats/posix 平台层，HOST_INPROC 语义），经 IPC 协议
# 与引擎协作；产物与引擎 .so 同目录（客户端 dladdr 定位）。
if(AURADSP_ENABLE_PLUGINS AND AURADSP_PLUGIN_HOST_REMOTE)
    set(AURADSP_HOST_SOURCES
        "${API}/plugins/platform/posix/host/plugin_host_main_posix.cpp"
        # R-07（2026-11-05）：命令循环与 Op 分发下沉到平台无关层，
        # POSIX 主程序只保留 socket/看门狗/唤醒等平台原语。
        "${API}/plugins/platform/host/plugin_host_command.cpp"
        "${API}/plugins/platform/posix/host/plugin_shared_region_posix.cpp"
        "${API}/platform/linux/fs_linux.cpp"
        "${API}/platform/linux/env_linux.cpp"
        "${API}/platform/linux/log_linux.cpp"
        "${API}/platform/linux/module_linux.cpp"
        "${API}/plugins/driver/plugin_bundle.cpp"
        "${API}/plugins/driver/plugin_scanner.cpp"
        "${API}/plugins/driver/plugin_driver_registry.cpp"
        "${API}/plugins/driver/plugin_json.cpp"
        "${API}/plugins/driver/plugin_thread.cpp"
        "${API}/plugins/driver/plugin_host_manager.cpp"
        "${API}/plugins/driver/plugin_chain_component.cpp"
        "${API}/plugins/formats/clap/clap_driver.cpp"
        "${API}/plugins/formats/clap/clap_instance.cpp"
        "${API}/plugins/formats/clap/clap_metadata.cpp"
        "${API}/plugins/formats/vst3/vst3_driver.cpp"
        "${API}/plugins/formats/vst3/vst3_instance.cpp"
        "${API}/plugins/formats/vst3/vst3_metadata.cpp"
        # VST2（2026-11-04 Linux 跟进）：驱动/实例/元数据，编译头是
        # vendor/plugin-api/vst2/vst.h（Xaymar 净室）；__cdecl 习语
        # 由 platform/posix/win32_compat.h 的空定义消解。
        "${API}/plugins/formats/vst2/vst2_driver.cpp"
        "${API}/plugins/formats/vst2/vst2_instance.cpp"
        "${API}/plugins/formats/vst2/vst2_metadata.cpp"
        "${API}/plugins/platform/posix/plugin_util_posix.cpp"
        "${API}/plugins/platform/posix/plugin_gui_x11.cpp"
    )
    add_executable(plugin_host_x64 ${AURADSP_HOST_SOURCES})
    set_property(TARGET plugin_host_x64 PROPERTY CXX_STANDARD 20)
    target_compile_definitions(plugin_host_x64 PRIVATE
        AURADSP_HOST_INPROC=1
    )
    target_compile_options(plugin_host_x64 PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-include ${API}/auradsp_gcc_shim.h>
    )
    target_include_directories(plugin_host_x64 PRIVATE
        "${API}"
        "${API}/chain"
        "${API}/plugins/api"
        "${API}/plugins/driver"
        "${API}/plugins/platform/host"
        "${API}/plugins/platform/win32/host"
        "${API}/plugins/platform/posix"
        "${LEGACY}"
        "${LEGACY}/jdsp"
        "${PLUGIN_API}"
    )
    target_link_options(plugin_host_x64 PRIVATE
        "LINKER:--allow-multiple-definition"
    )
    target_link_libraries(plugin_host_x64 PRIVATE
        Threads::Threads
        ${CMAKE_DL_LIBS}
        m
    )

    # 32 位桥宿主 plugin_host_x86（双宿主架构阶段五）：同一份宿主
    # 源码以 -m32 独立构建，承载 32 位插件（路由见 manager 的
    # remoteClientFor）。需要 multilib 工具链（gcc-multilib /
    # g++-multilib），故默认 OFF，由 CI 或本机装齐后开启；缺
    # 宿主时 32 位插件按路由回落 x64 宿主（加载失败即现状行为）。
    option(AURADSP_BUILD_HOST_X86 "Build 32-bit bridge host (plugin_host_x86, needs multilib)" ON)
    if(AURADSP_BUILD_HOST_X86)
        add_executable(plugin_host_x86 ${AURADSP_HOST_SOURCES})
        set_property(TARGET plugin_host_x86 PROPERTY CXX_STANDARD 20)
        target_compile_definitions(plugin_host_x86 PRIVATE
            AURADSP_HOST_INPROC=1
        )
        target_compile_options(plugin_host_x86 PRIVATE
            -m32
            $<$<COMPILE_LANGUAGE:CXX>:-include ${API}/auradsp_gcc_shim.h>
        )
        target_link_options(plugin_host_x86 PRIVATE -m32
            "LINKER:--allow-multiple-definition"
        )
        target_include_directories(plugin_host_x86 PRIVATE
            "${API}"
            "${API}/chain"
            "${API}/plugins/api"
            "${API}/plugins/driver"
            "${API}/plugins/platform/host"
            "${API}/plugins/platform/win32/host"
            "${API}/plugins/platform/posix"
            "${LEGACY}"
            "${LEGACY}/jdsp"
            "${PLUGIN_API}"
        )
        target_link_libraries(plugin_host_x86 PRIVATE
            Threads::Threads
            ${CMAKE_DL_LIBS}
            m
        )
    endif()
endif()
