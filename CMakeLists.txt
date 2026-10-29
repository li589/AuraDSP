cmake_minimum_required(VERSION 3.20)
project(auradsp LANGUAGES C CXX)

# ============================================================================
# AuraDSP 统一构建入口（M3，2026-10-29）
#
# 定位：不是新工程，只是把两个既有子工程收进同一棵构建树
#   core/desktop/windows          引擎 DLL + 进程外插件宿主 + 插件测试
#   core/desktop/windows-drivers  三桥 / ASIO / APO / 驱动套件
# 两个子工程仍可单独 `cmake -S <dir> -B <dir>/out` 配置（旧入口保留，
# build_engine.sh 与 windows-drivers/README 的命令继续可用）。
#
# 产物路径不变：子工程用 CMAKE_*_OUTPUT_DIRECTORY 把 DLL/EXE/LIB 写回各自
# out/<Config>/，verify_dll_copies.py、Flutter runner 同步与历史 smoke 的
# 路径依赖保持成立。构建中间文件统一落 build/<platform>/<arch>/。
#
# Linux/Android 不在本轮接入（适配层仍是 Windows 实现，见方案 M6）。
# ============================================================================

if(NOT WIN32)
    message(FATAL_ERROR
        "AuraDSP 根构建当前仅支持 Windows；Linux/Android 接入见 "
        "docs/10-架构/跨平台基础框架与平台依赖剥离方案-2026-10-29.md（M6）。")
endif()

# 桥/驱动套件需要 Steinberg ASIO SDK（路径由子工程的 ASIO_SDK_ROOT 缓存变量指定）。
# build_windows.ps1 -SkipDrivers 会传 OFF 以保留「不碰驱动套件」语义。
option(AURADSP_BUILD_BRIDGES "Build Windows bridge/driver targets (requires ASIO SDK)" ON)

add_subdirectory(core/desktop/windows)

if(AURADSP_BUILD_BRIDGES)
    add_subdirectory(core/desktop/windows-drivers)
endif()
