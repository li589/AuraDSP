cmake_minimum_required(VERSION 3.20)
project(auradsp LANGUAGES C CXX)

# ============================================================================
# AuraDSP 统一构建入口（M3，2026-10-29；S2 Linux 接入，2026-11-01）
#
# 定位：不是新工程，只是把既有子工程收进同一棵构建树
#   core/desktop/windows          引擎 DLL + 进程外插件宿主 + 插件测试
#   core/desktop/windows-drivers  三桥 / ASIO / APO / 驱动套件
#   core/desktop/linux            引擎 .so（S2：核心 + Linux 平台适配，
#                                 插件子系统按 ADR-012 D-7 整体裁剪）
# 各子工程仍可单独 `cmake -S <dir> -B <dir>/out` 配置（旧入口保留，
# build_engine.sh 与 windows-drivers/README 的命令继续可用）。
#
# 产物路径不变：子工程用 CMAKE_*_OUTPUT_DIRECTORY 把 DLL/.so/EXE/LIB 写回
# 各自 out/<Config>/，verify_dll_copies.py、Flutter runner 同步与历史 smoke
# 的路径依赖保持成立。构建中间文件统一落 build/<platform>/<arch>/。
#
# Android 仍不在根构建接入（NDK 工具链未接入，见跨平台方案 M6）。
# ============================================================================

if(WIN32)
    # 桥/驱动套件需要 Steinberg ASIO SDK（路径由子工程的 ASIO_SDK_ROOT 缓存变量指定）。
    # build_windows.ps1 -SkipDrivers 会传 OFF 以保留「不碰驱动套件」语义。
    option(AURADSP_BUILD_BRIDGES "Build Windows bridge/driver targets (requires ASIO SDK)" ON)

    add_subdirectory(core/desktop/windows)

    if(AURADSP_BUILD_BRIDGES)
        add_subdirectory(core/desktop/windows-drivers)
    endif()
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    add_subdirectory(core/desktop/linux)
else()
    message(FATAL_ERROR
        "AuraDSP 根构建当前支持 Windows 与 Linux；Android 接入见 "
        "docs/10-架构/跨平台基础框架与平台依赖剥离方案-2026-10-29.md（M6）。")
endif()
