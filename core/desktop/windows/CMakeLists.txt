cmake_minimum_required(VERSION 3.20)
project(auradsp_engine LANGUAGES C CXX)

set(PLUGIN_API "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/plugin-api")
set(API        "${CMAKE_CURRENT_SOURCE_DIR}/../../../engine")
set(LEGACY     "${API}/legacy")

set(AURADSP_PLUGIN_HOST_SOURCES
    "${API}/plugins/platform/win32/plugin_gui_win32.cpp"
    "${API}/plugins/platform/win32/win32_util.cpp"
    "${API}/plugins/platform/win32/plugin_paths.cpp"
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

file(GLOB_RECURSE ENGINE_C CONFIGURE_DEPENDS "${LEGACY}/*.c")
# 排除与顶层重名的 eel2/cpthread.c（对齐 Android 侧 build_jdsp.sh 策略）
list(FILTER ENGINE_C EXCLUDE REGEX "eel2/cpthread\\.c$")

add_library(auradsp_engine SHARED
    ${ENGINE_C}
    "${API}/auradsp_engine.cpp"
    "${API}/chain/engine_chain.cpp"
    "${API}/chain/engine_convolver.cpp"
    "${API}/chain/engine_viz.cpp"
    "${API}/chain/engine_probe.cpp"
    "${API}/dsp/dsp_shelf.cpp"
    "${API}/dsp/dsp_filter.cpp"
    "${API}/dsp/dsp_bassmono.cpp"
    "${API}/dsp/dsp_haas.cpp"
    "${API}/dsp/dsp_spatial.cpp"
    "${API}/dsp/dsp_exciter.cpp"
    "${API}/dsp/dsp_gate.cpp"
    "${API}/dsp/dsp_psycho.cpp"
    "${API}/dsp/dsp_loudness.cpp"
    "${API}/dsp/dsp_freeverb.cpp"
    "${API}/dsp/dsp_dyneq.cpp"
    "${API}/chain/engine_audiofile.cpp"
    ${AURADSP_PLUGIN_HOST_SOURCES}
    ${AURADSP_PLUGIN_INTEGRATION_SOURCES}
    "${API}/auradsp_engine.def"
)
target_include_directories(auradsp_engine PRIVATE
    "${API}"
    "${API}/chain"
    "${API}/plugins/api"
    "${API}/plugins/driver"
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
# B-1 调试日志（计划 D1）：宿主 [DBG 诊断默认编译期剥离（Release DLL strings 扫描
# 无 [DBG 由 smoke_release_strings.py 门禁）；-DAURADSP_DBG_LOG=ON 重建可恢复输出
# （OutputDebugString 通道，运行期再受环境变量 AURADSP_LOG=0|1|2 控制）。
option(AURADSP_DBG_LOG "Emit host [DBG diagnostics via OutputDebugString (OFF in default builds)" OFF)
if(AURADSP_DBG_LOG)
    target_compile_definitions(auradsp_engine PRIVATE AURADSP_DBG_LOG)
endif()
target_compile_options(auradsp_engine PRIVATE /utf-8 /W1 /EHsc)
# engine/legacy 的 essential.h 仅 include <errno.h>，MSVC 不会像 NDK 那样间接带入
# <stdint.h>；且 engine/legacy/jamesdsp.c 使用 GCC 扩展 __attribute__((constructor))。
# 按铁律 §3.3 不改上游，调用侧 /FI 前置 shim 统一处理（见 auradsp_msvc_shim.h 头注释）。
target_compile_options(auradsp_engine PRIVATE /FI"${API}/auradsp_msvc_shim.h")
set_source_files_properties(${ENGINE_C} PROPERTIES LANGUAGE C)
set_property(TARGET auradsp_engine PROPERTY C_STANDARD 11)
set_property(TARGET auradsp_engine PROPERTY CXX_STANDARD 20)
set_property(TARGET auradsp_engine PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
# 只导出 .def 里声明的 auradsp_* 符号（防符号泄漏，对齐 Android 侧 version_script 策略）
set_property(TARGET auradsp_engine PROPERTY WINDOWS_EXPORT_ALL_SYMBOLS OFF)
target_link_libraries(auradsp_engine PRIVATE version)

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
target_compile_definitions(test_plugin_direct PRIVATE NDEBUG _CRT_SECURE_NO_WARNINGS)
target_compile_options(test_plugin_direct PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET test_plugin_direct PROPERTY CXX_STANDARD 20)
set_property(TARGET test_plugin_direct PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
target_link_libraries(test_plugin_direct PRIVATE auradsp_engine version)

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
target_compile_definitions(test_plugin_chain PRIVATE NDEBUG _CRT_SECURE_NO_WARNINGS)
target_compile_options(test_plugin_chain PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET test_plugin_chain PROPERTY CXX_STANDARD 20)
set_property(TARGET test_plugin_chain PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
target_link_libraries(test_plugin_chain PRIVATE auradsp_engine version)

