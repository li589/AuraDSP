# engine/core_sources.cmake — 可移植核心源表唯一真相（CP-27，2026-11-01）。
#
# 使用方：
#   - core/desktop/windows/CMakeLists.txt（Windows 引擎的 auradsp_core）
#   - 未来 Linux/macOS 的核心目标（只编本表 + platform/<os> 适配）
#
# 约束：本表只含可移植核心（根 C ABI / chain / dsp / legacy C），不得出现
# platform/ 源、插件 Win32 实现或 .def（这些由调用方按目标追加）。
#
# 注意：CMAKE_CURRENT_LIST_DIR 在 include() 内指向本文件所在目录（engine/），
# 因此调用方无需再传路径。

# legacy 上游 C（含 AuraDSP 本地补丁；GLOB 与历史行为一致）。
file(GLOB_RECURSE AURADSP_CORE_LEGACY_C CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_LIST_DIR}/legacy/*.c")
# 排除与顶层重名的 eel2/cpthread.c（对齐 Android 侧 build_jdsp.sh 策略）。
list(FILTER AURADSP_CORE_LEGACY_C EXCLUDE REGEX "eel2/cpthread\\.c$")

set(AURADSP_CORE_CXX_SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/auradsp_engine.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/chain/engine_chain.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/chain/engine_convolver.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/chain/engine_viz.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/chain/engine_probe.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/chain/engine_audiofile.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_shelf.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_filter.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_bassmono.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_haas.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_spatial.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_exciter.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_gate.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_psycho.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_loudness.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_mc_reverb.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/dsp/dsp_dyneq.cpp"
)
