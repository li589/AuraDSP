#!/bin/bash
# build_engine.sh — build auradsp_engine.dll (AuraDSP Engines Desktop v1, Win x64)
#
# 入口规范化（2026-11-05）：与 tools/build_windows.ps1、CI J5 共用根
# CMakePresets（windows-x64），构建树固定 build/windows/x64/；产物仍写回
# core/desktop/windows/out/Release/（DLL 真相源），out/ 不再混入 vcxproj、
# CMakeCache 与构建日志。子工程仍可独立 cmake -S/-B 配置（旧入口保留）。
#
# Sources (per docs/项目架构与开发规范.md §3 — 源码整合，无预编译依赖):
#   ../../../engine/legacy/        JamesDSP C engine (原 vendor/libjamesdsp 收编, 见 source/ORIGIN.md、vendor/ORIGIN.md)
#   ../../../engine/               auradsp_engine.h/.cpp/.def — 统一 C ABI
#
# Toolchain: CMake + Visual Studio 18 2026 generator (MSVC x64)
# Output:    core/desktop/windows/out/Release/auradsp_engine.dll + auradsp_engine.lib
# Exports:   auradsp_* 47 symbols only (engine/auradsp_engine.def)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

# Git Bash 一般能直接解析 cmake；IDE / 精简 PATH 下回退到常见安装位置。
CMAKE="$(command -v cmake || command -v cmake.exe || true)"
if [ -z "$CMAKE" ]; then
  for c in /c/FreeRulesPrograms/BasicToolkits/CMake/bin/cmake.exe \
           "/c/Program Files/CMake/bin/cmake.exe"; do
    if [ -x "$c" ]; then CMAKE="$c"; break; fi
  done
fi
[ -n "$CMAKE" ] || { echo "ERROR: cmake not found (run from Git Bash)"; exit 1; }

echo "=== [1/3] cmake configure (preset windows-x64) ==="
"$CMAKE" --preset windows-x64

echo "=== [2/3] cmake build (preset windows-x64-release) ==="
# 进程外插件宿主 target 仅在 AURADSP_PLUGIN_HOST_REMOTE=ON 时存在；从
# CMake 缓存读实际值决定 target 集合（与 build_windows.ps1 Step2 同口径）。
CACHE="build/windows/x64/CMakeCache.txt"
TARGETS=(auradsp_engine)
if ! grep -q '^AURADSP_PLUGIN_HOST_REMOTE:BOOL=OFF' "$CACHE" 2>/dev/null; then
  TARGETS+=(plugin_host_x64)
fi
"$CMAKE" --build --preset windows-x64-release --target "${TARGETS[@]}"

OUT_DIR="core/desktop/windows/out/Release"
DLL="$OUT_DIR/auradsp_engine.dll"
[ -f "$DLL" ] || { echo "ERROR: auradsp_engine.dll not produced"; exit 1; }
echo "=== BUILD OK: $DLL ==="
ls -la "$DLL" "$OUT_DIR/auradsp_engine.lib"

# [3/3] 产物同步：构建完成后把引擎 DLL + 宿主 EXE 自动覆盖分发到三处消费端点
# （test/ 冒烟沙盒、app build runner、dist 发行包）。某端点缺失或单文件覆盖失败仅
# 告警并跳过，不中止本次构建（详见 tools/sync_artifacts.py）。
echo "=== [3/3] sync artifacts to consumers ==="
SYNC_PS="tools/sync_artifacts.ps1"
PWS="$(command -v powershell.exe || command -v pwsh || true)"
if [ -n "$PWS" ] && [ -f "$SYNC_PS" ]; then
  "$PWS" -NoProfile -ExecutionPolicy Bypass -File "$SYNC_PS" || \
    echo "WARN: sync_artifacts.ps1 报告跳过项（见上方告警）；引擎构建本身成功。"
else
  echo "WARN: powershell 未找到，跳过自动同步（引擎构建已成功）"
fi
