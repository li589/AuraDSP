cmake_minimum_required(VERSION 3.20)
project(auradsp_engine LANGUAGES C CXX)

# M2（2026-10-29）：插件远程宿主是 Windows 强依赖组件（共享内存 + CreateProcess +
# Win32 窗口）。Windows 默认 ON（行为不变）；非 Windows / 裁剪构建置 OFF：引擎走
# AURADSP_HOST_INPROC 进程内路径，且不构建独立宿主进程。
option(AURADSP_PLUGIN_HOST_REMOTE "Build out-of-process plugin host (Windows only)" ON)
if(NOT WIN32)
    set(AURADSP_PLUGIN_HOST_REMOTE OFF CACHE BOOL "Build out-of-process plugin host (Windows only)" FORCE)
endif()

# CP-02（跨平台基础审查 2026-11-01）：插件子系统（VST3/CLAP 扫描/加载/编辑器）整体开关。
# Windows 默认 ON（行为不变）；Linux/macOS 置 OFF 时排除全部 Win32 插件源，改用
# plugins/integration/{plugin_chain_adapter_stub,plugin_abi_stub}.cpp 保持 C ABI 导出集。
option(AURADSP_ENABLE_PLUGINS "Build VST3/CLAP plugin hosting subsystem (Windows only)" ON)
if(NOT WIN32)
    set(AURADSP_ENABLE_PLUGINS OFF CACHE BOOL "Build VST3/CLAP plugin hosting subsystem (Windows only)" FORCE)
endif()
if(NOT AURADSP_ENABLE_PLUGINS)
    # 进程外宿主依赖插件子系统，裁剪时必须一并关闭。
    set(AURADSP_PLUGIN_HOST_REMOTE OFF CACHE BOOL "Build out-of-process plugin host (Windows only)" FORCE)
endif()

# M3（2026-10-29）：产物路径保持 out/<Config>/（build_engine.sh、verify_dll_copies.py、
# Flutter runner 同步与历史 smoke 都依赖它）；构建中间文件由根工程统一到
# build/<platform>/<arch>/（本子工程单独配置时仍落在 out/）。
#
# CP-02 补充（2026-11-01）：裁剪构建（AURADSP_ENABLE_PLUGINS=OFF）使用独立的
# out-noplugins/<Config>/。两棵构建树如果共用 out/，OFF 构建会覆盖 ON 的
# auradsp_core.lib；下一次 ON 增量构建可能误链 NO_PLUGINS 版核心（handle 布局不同，
# 插件字段错位）。输出目录分离后，两种配置可并存且互不污染。
if(AURADSP_ENABLE_PLUGINS)
    set(AURADSP_OUT_DIR_NAME "out")
else()
    set(AURADSP_OUT_DIR_NAME "out-noplugins")
endif()
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${AURADSP_OUT_DIR_NAME}")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${AURADSP_OUT_DIR_NAME}")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${AURADSP_OUT_DIR_NAME}")

set(PLUGIN_API "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/plugin-api")
set(API        "${CMAKE_CURRENT_SOURCE_DIR}/../../../engine")
set(LEGACY     "${API}/legacy")

set(AURADSP_PLUGIN_HOST_SOURCES
    "${API}/plugins/platform/win32/plugin_gui_win32.cpp"
    "${API}/plugins/platform/win32/win32_util.cpp"
    "${API}/plugins/platform/win32/plugin_paths.cpp"
    "${API}/plugins/platform/win32/plugin_module.cpp"
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
)
set(AURADSP_PLUGIN_INTEGRATION_SOURCES
    "${API}/plugins/integration/plugin_host.cpp"
    "${API}/plugins/integration/plugin_engine_state.cpp"
    "${API}/plugins/integration/plugin_chain_adapter.cpp"
    "${API}/plugins/integration/plugin_abi.cpp"
)
set(AURADSP_PLUGIN_REMOTE_SOURCES
    "${API}/plugins/platform/win32/host/plugin_shared_region.cpp"
    "${API}/plugins/platform/win32/host/plugin_host_client.cpp"
    "${API}/plugins/platform/win32/host/process_plugin_proxy.cpp"
)
if(NOT AURADSP_PLUGIN_HOST_REMOTE)
    set(AURADSP_PLUGIN_REMOTE_SOURCES "")
endif()

# CP-02：引擎实际编入的插件源表。ON = 完整插件子系统；OFF = 两个 ABI/链阶段 stub，
# 导出集与 plugin_abi.cpp 同集（F3 要求不增不减），但所有能力返回「不可用」。
if(AURADSP_ENABLE_PLUGINS)
    set(AURADSP_ENGINE_PLUGIN_SOURCES
        ${AURADSP_PLUGIN_HOST_SOURCES}
        ${AURADSP_PLUGIN_INTEGRATION_SOURCES}
        ${AURADSP_PLUGIN_REMOTE_SOURCES}
    )
else()
    set(AURADSP_ENGINE_PLUGIN_SOURCES
        "${API}/plugins/integration/plugin_chain_adapter_stub.cpp"
        "${API}/plugins/integration/plugin_abi_stub.cpp"
    )
endif()

file(GLOB_RECURSE ENGINE_C CONFIGURE_DEPENDS "${LEGACY}/*.c")
# 排除与顶层重名的 eel2/cpthread.c（对齐 Android 侧 build_jdsp.sh 策略）
list(FILTER ENGINE_C EXCLUDE REGEX "eel2/cpthread\\.c$")

# M3（2026-10-29）：可移植核心收口为静态库（legacy C + 根 C ABI + chain/dsp）。
# 源表只此一处；插件宿主与测试继续复用 AURADSP_PLUGIN_HOST_SOURCES，不链核心。
add_library(auradsp_core STATIC
    ${ENGINE_C}
    "${API}/auradsp_engine.cpp"
    "${API}/chain/engine_chain.cpp"
    "${API}/chain/engine_convolver.cpp"
    "${API}/chain/engine_viz.cpp"
    "${API}/chain/engine_probe.cpp"
    "${API}/chain/engine_audiofile.cpp"
    "${API}/dsp/dsp_shelf.cpp"
    "${API}/dsp/dsp_filter.cpp"
    "${API}/dsp/dsp_bassmono.cpp"
    "${API}/dsp/dsp_haas.cpp"
    "${API}/dsp/dsp_spatial.cpp"
    "${API}/dsp/dsp_exciter.cpp"
    "${API}/dsp/dsp_gate.cpp"
    "${API}/dsp/dsp_psycho.cpp"
    "${API}/dsp/dsp_loudness.cpp"
    "${API}/dsp/dsp_mc_reverb.cpp"
    "${API}/dsp/dsp_dyneq.cpp"
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
target_compile_definitions(auradsp_core PRIVATE
    NDEBUG
    _CRT_SECURE_NO_WARNINGS
    _WIN32_WINNT=0x0601
    WINVER=0x0601
    NTDDI_VERSION=0x06010000
)
target_compile_options(auradsp_core PRIVATE /utf-8 /W1 /EHsc)
# engine/legacy 的 essential.h 仅 include <errno.h>，MSVC 不会像 NDK 那样间接带入
# <stdint.h>；且 engine/legacy/jamesdsp.c 使用 GCC 扩展 __attribute__((constructor))。
# 按铁律 §3.3 不改上游，调用侧 /FI 前置 shim 统一处理（见 auradsp_msvc_shim.h 头注释）。
target_compile_options(auradsp_core PRIVATE /FI"${API}/auradsp_msvc_shim.h")
set_source_files_properties(${ENGINE_C} PROPERTIES LANGUAGE C)
set_property(TARGET auradsp_core PROPERTY C_STANDARD 11)
set_property(TARGET auradsp_core PROPERTY CXX_STANDARD 20)
set_property(TARGET auradsp_core PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
if(NOT AURADSP_ENABLE_PLUGINS)
    # CP-02：engine_internal.h 的 handle 定义在 core 内编译；裁剪时必须与引擎
    # 使用同一 AURADSP_NO_PLUGINS 视图，否则 handle 仍要求 PluginEngineState 符号。
    target_compile_definitions(auradsp_core PRIVATE AURADSP_NO_PLUGINS=1)
endif()

# R1（M6 审查遗留，2026-10-30）：Win7 CreateFile2 回退统一编入所有含
# <filesystem> 的目标（OBJECT 库 = 无条件随目标链接，与直接编入源文件等价；
# 静态库会有成员按需抽取问题，故不用 STATIC）。此前只有 auradsp_engine 编入，
# auradsp_plugin_host 与插件测试 EXE 编 plugin_scanner.cpp（<filesystem>）但缺
# __imp_CreateFile2，_WIN32_WINNT=0x0601 下 Win7 加载失败。
add_library(auradsp_wincompat OBJECT
    "${API}/platform/windows/win_compat.cpp"
)
set_property(TARGET auradsp_wincompat PROPERTY CXX_STANDARD 20)
set_property(TARGET auradsp_wincompat PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

# 引擎 DLL：核心 + Windows 平台适配（M1/M2 唯一 OS 落点）+ 插件子系统。
add_library(auradsp_engine SHARED
    # M1 平台隔离（2026-10-29）：核心只依赖 platform/port 端口声明，
    # 以下 Windows 实现是唯一 OS 落点（含 Win7 CreateFile2 回退，见 auradsp_wincompat）。
    "${API}/platform/windows/fs_win.cpp"
    "${API}/platform/windows/env_win.cpp"
    "${API}/platform/windows/log_win.cpp"
    ${AURADSP_ENGINE_PLUGIN_SOURCES}
    "${API}/auradsp_engine.def"
)
target_link_libraries(auradsp_engine PRIVATE auradsp_core auradsp_wincompat)
target_include_directories(auradsp_engine PRIVATE
    "${API}"
    "${API}/chain"
    "${API}/plugins/api"
    "${API}/plugins/driver"
    "${API}/plugins/platform/win32/host"
    "${API}/plugins/platform/win32"
    "${LEGACY}"
    "${LEGACY}/jdsp"
    "${PLUGIN_API}"
)

target_compile_definitions(auradsp_engine PRIVATE
    NDEBUG
    _CRT_SECURE_NO_WARNINGS
    _WIN32_WINNT=0x0601
    WINVER=0x0601
    NTDDI_VERSION=0x06010000
)
if(NOT AURADSP_PLUGIN_HOST_REMOTE)
    # 远程宿主被裁剪：插件改在引擎进程内加载（与 auradsp_plugin_host / 测试的
    # AURADSP_HOST_INPROC=1 同一路径），不引用 ProcessPluginProxy / 共享内存 IPC。
    target_compile_definitions(auradsp_engine PRIVATE AURADSP_HOST_INPROC=1)
endif()
if(NOT AURADSP_ENABLE_PLUGINS)
    # CP-02：插件子系统整体裁剪。engine_internal.h 的 plugin 成员与
    # plugins/integration 的真实实现均被排除，改由两个 stub 提供 C ABI 导出。
    target_compile_definitions(auradsp_engine PRIVATE AURADSP_NO_PLUGINS=1)
endif()
# B-1 调试日志（计划 D1）：宿主 [DBG 诊断默认编译期剥离（Release DLL strings 扫描
# 无 [DBG 由 smoke_release_strings.py 门禁）；-DAURADSP_DBG_LOG=ON 重建可恢复输出
# （OutputDebugString 通道，运行期再受环境变量 AURADSP_LOG=0|1|2 控制）。
option(AURADSP_DBG_LOG "Emit host [DBG diagnostics via OutputDebugString (OFF in default builds)" OFF)
if(AURADSP_DBG_LOG)
    target_compile_definitions(auradsp_engine PRIVATE AURADSP_DBG_LOG)
endif()
target_compile_options(auradsp_engine PRIVATE /utf-8 /W1 /EHsc)
# 与核心相同的强制 shim，保持历史编译行为（legacy C 已全部移入 auradsp_core）。
target_compile_options(auradsp_engine PRIVATE /FI"${API}/auradsp_msvc_shim.h")
set_property(TARGET auradsp_engine PROPERTY CXX_STANDARD 20)
set_property(TARGET auradsp_engine PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
# 只导出 .def 里声明的 auradsp_* 符号（防符号泄漏，对齐 Android 侧 version_script 策略）
set_property(TARGET auradsp_engine PROPERTY WINDOWS_EXPORT_ALL_SYMBOLS OFF)
target_link_libraries(auradsp_engine PRIVATE version)

if(AURADSP_ENABLE_PLUGINS AND AURADSP_PLUGIN_HOST_REMOTE)
    add_executable(auradsp_plugin_host
        "${API}/plugins/platform/win32/host/auradsp_plugin_host_main.cpp"
        "${API}/plugins/platform/win32/host/plugin_shared_region.cpp"
        ${AURADSP_PLUGIN_HOST_SOURCES}
    )
    target_include_directories(auradsp_plugin_host PRIVATE
        "${API}"
        "${API}/plugins/api"
        "${API}/plugins/driver"
        "${API}/plugins/platform/win32/host"
        "${API}/plugins/platform/win32"
        "${PLUGIN_API}"
    )
    target_compile_definitions(auradsp_plugin_host PRIVATE
        NDEBUG
        _CRT_SECURE_NO_WARNINGS
        AURADSP_HOST_INPROC=1
    )
    target_compile_options(auradsp_plugin_host PRIVATE /utf-8 /W1 /EHsc)
    set_property(TARGET auradsp_plugin_host PROPERTY CXX_STANDARD 20)
    set_property(TARGET auradsp_plugin_host PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
    # R1：plugin_scanner.cpp 用 <filesystem> → 必须带 Win7 CreateFile2 回退。
    target_link_libraries(auradsp_plugin_host PRIVATE auradsp_wincompat version)
endif()  # AURADSP_PLUGIN_HOST_REMOTE

# CP-02：三个插件测试 EXE 直接编译 AURADSP_PLUGIN_HOST_SOURCES，裁剪构建不产出。
if(AURADSP_ENABLE_PLUGINS)
add_executable(test_plugin_direct
    "${API}/plugins/tests/plugin_host_direct.cpp"
    ${AURADSP_PLUGIN_HOST_SOURCES}
)
target_include_directories(test_plugin_direct PRIVATE
    "${API}"
    "${API}/plugins/api"
    "${API}/plugins/driver"
    "${API}/plugins/platform/win32"
    "${PLUGIN_API}"
)
target_compile_definitions(test_plugin_direct PRIVATE NDEBUG _CRT_SECURE_NO_WARNINGS AURADSP_HOST_INPROC=1)
target_compile_options(test_plugin_direct PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET test_plugin_direct PROPERTY CXX_STANDARD 20)
set_property(TARGET test_plugin_direct PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
target_link_libraries(test_plugin_direct PRIVATE auradsp_engine auradsp_wincompat version)

add_executable(test_plugin_chain
    "${API}/plugins/tests/plugin_chain_consistency.cpp"
    ${AURADSP_PLUGIN_HOST_SOURCES}
)
target_include_directories(test_plugin_chain PRIVATE
    "${API}"
    "${API}/plugins/api"
    "${API}/plugins/driver"
    "${API}/plugins/platform/win32"
    "${PLUGIN_API}"
)
target_compile_definitions(test_plugin_chain PRIVATE NDEBUG _CRT_SECURE_NO_WARNINGS AURADSP_HOST_INPROC=1)
target_compile_options(test_plugin_chain PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET test_plugin_chain PROPERTY CXX_STANDARD 20)
set_property(TARGET test_plugin_chain PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
target_link_libraries(test_plugin_chain PRIVATE auradsp_engine auradsp_wincompat version)

# B3 验收（2026-10-24）：RT 异常滞留时卸载必须隔离实例而不是硬清零后销毁。
# 假实例 process() 阻塞注入"插件死锁在音频线程内"，断言 dtor 未跑、
# 实例方法未被调用、计数清零且不下溢、槽可复用（smoke_plugin_quarantine.py）。
add_executable(test_host_quarantine
    "${API}/plugins/tests/plugin_host_quarantine.cpp"
    ${AURADSP_PLUGIN_HOST_SOURCES}
)
target_include_directories(test_host_quarantine PRIVATE
    "${API}"
    "${API}/plugins/api"
    "${API}/plugins/driver"
    "${API}/plugins/platform/win32"
    "${PLUGIN_API}"
)
target_compile_definitions(test_host_quarantine PRIVATE NDEBUG _CRT_SECURE_NO_WARNINGS AURADSP_HOST_INPROC=1)
target_compile_options(test_host_quarantine PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET test_host_quarantine PROPERTY CXX_STANDARD 20)
set_property(TARGET test_host_quarantine PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
target_link_libraries(test_host_quarantine PRIVATE auradsp_engine auradsp_wincompat version)
endif()  # AURADSP_ENABLE_PLUGINS

# F1 验收（2026-10-24）：插件依赖 DLL 搜索目录通用化 + cookie 回收
# （不依赖任何真插件，用临时目录树验证登记/幂等/引用计数/回收/环境变量）。
add_executable(test_dll_dirs
    "${API}/plugins/tests/test_dll_dirs.cpp"
    "${API}/plugins/platform/win32/win32_util.cpp"
)
target_include_directories(test_dll_dirs PRIVATE
    "${API}"
    "${API}/plugins/api"
    "${API}/plugins/driver"
    "${API}/plugins/platform/win32"
    "${PLUGIN_API}"
)
target_compile_definitions(test_dll_dirs PRIVATE NDEBUG _CRT_SECURE_NO_WARNINGS)
target_compile_options(test_dll_dirs PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET test_dll_dirs PROPERTY CXX_STANDARD 20)
set_property(TARGET test_dll_dirs PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
# R1：win32_util.h 头内用 <filesystem> → 同样需要 Win7 CreateFile2 回退。
target_link_libraries(test_dll_dirs PRIVATE auradsp_wincompat version shell32 ole32 user32)


