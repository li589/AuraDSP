cmake_minimum_required(VERSION 3.20)
project(auradsp_engine LANGUAGES C CXX)

set(PLUGIN_API "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/plugin-api")
set(API        "${CMAKE_CURRENT_SOURCE_DIR}/../../../engine")
set(LEGACY     "${API}/legacy")

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
    "${API}/dsp/dsp_exciter.cpp"
    "${API}/dsp/dsp_gate.cpp"
    "${API}/dsp/dsp_psycho.cpp"
    "${API}/dsp/dsp_loudness.cpp"
    "${API}/dsp/dsp_freeverb.cpp"
    "${API}/dsp/dsp_dyneq.cpp"
    "${API}/chain/engine_audiofile.cpp"
    "${API}/host/auradsp_plugin_host.cpp"
    "${API}/host/host_gui.cpp"
    "${API}/host/host_metadata_scan.cpp"
    "${API}/host/host_instances.cpp"
    "${API}/host/host_slots.cpp"
    "${API}/auradsp_engine.def"
)
target_include_directories(auradsp_engine PRIVATE
    "${API}"
    "${API}/chain"
    "${API}/host"
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
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../test/smoke/test_plugin_direct.cpp"
    "${API}/host/auradsp_plugin_host.cpp"
    "${API}/host/host_gui.cpp"
    "${API}/host/host_metadata_scan.cpp"
    "${API}/host/host_instances.cpp"
    "${API}/host/host_slots.cpp"
)
target_include_directories(test_plugin_direct PRIVATE
    "${API}"
    "${API}/host"
    "${PLUGIN_API}"
)
target_compile_definitions(test_plugin_direct PRIVATE NDEBUG _CRT_SECURE_NO_WARNINGS)
target_compile_options(test_plugin_direct PRIVATE /utf-8 /W1 /EHsc)
set_property(TARGET test_plugin_direct PROPERTY CXX_STANDARD 20)
set_property(TARGET test_plugin_direct PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
target_link_libraries(test_plugin_direct PRIVATE version)

