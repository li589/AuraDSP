#!/bin/bash
# build_engine.sh — build auradsp_engine.dll (AuraDSP Engines Desktop v1, Win x64)
#
# Sources (per docs/项目架构与开发规范.md §3 — 源码整合，无预编译依赖):
#   ../../../engine/legacy/        JamesDSP C engine (原 vendor/libjamesdsp 收编, 见 source/ORIGIN.md、vendor/ORIGIN.md)
#   ../../../engine/               auradsp_engine.h/.cpp/.def — 统一 C ABI
#
# Toolchain: CMake + Visual Studio 18 2026 generator (MSVC x64)
# Output:    out/auradsp_engine.dll + auradsp_engine.lib
# Exports:   auradsp_* 47 symbols only (engine/auradsp_engine.def)
set -e

HERE_W="$(cd "$(dirname "$0")" && pwd -W)"        # core/desktop/windows
OUT_W="$HERE_W/out"
mkdir -p "$OUT_W"

CMAKE="$(command -v cmake || echo /c/FreeRulesPrograms/BasicToolkits/CMake/bin/cmake)"

echo "=== [1/2] cmake configure ==="
# 管道会吞掉 cmake 的退出码（set -e 只见管道末端的 tail）——先落盘再 tail，
# 显式检查 rc。教训：2026-10-24 Phase B 首次构建 MSBuild 报 C2118 断言失败，
# 但脚本仍打印 BUILD OK 并同步了旧 DLL，门禁被管道蒙过。
"$CMAKE" -S "$HERE_W" -B "$OUT_W" -G "Visual Studio 18 2026" -A x64 \
  -DCMAKE_BUILD_TYPE=Release > "$OUT_W/configure.log" 2>&1
cfg_rc=$?
tail -5 "$OUT_W/configure.log"
[ $cfg_rc -eq 0 ] || { echo "ERROR: cmake configure failed (rc=$cfg_rc), see $OUT_W/configure.log"; exit $cfg_rc; }

echo "=== [2/2] build ==="
"$CMAKE" --build "$OUT_W" --config Release > "$OUT_W/build.log" 2>&1
build_rc=$?
tail -25 "$OUT_W/build.log"
[ $build_rc -eq 0 ] || { echo "ERROR: build failed (rc=$build_rc), see $OUT_W/build.log"; exit $build_rc; }

DLL="$OUT_W/Release/auradsp_engine.dll"
[ -f "$DLL" ] || { echo "ERROR: auradsp_engine.dll not produced"; exit 1; }
echo "=== BUILD OK: $DLL ==="
ls -la "$OUT_W/Release/auradsp_engine.dll" "$OUT_W/Release/auradsp_engine.lib"

# [3/3] 产物同步：构建完成后把引擎 DLL + 宿主 EXE 自动覆盖分发到三处消费端点
# （test/ 冒烟沙盒、app build runner、dist 发行包）。某端点缺失或单文件覆盖失败仅
# 告警并跳过，不中止本次构建（详见 tools/sync_artifacts.ps1）。
REPO_ROOT="$(cd "$HERE_W/../../.." && pwd -W)"
SYNC_PS="$REPO_ROOT/tools/sync_artifacts.ps1"
PWS="$(command -v powershell.exe || command -v pwsh || echo "")"
if [ -n "$PWS" ] && [ -f "$SYNC_PS" ]; then
  echo "=== [3/3] sync artifacts to consumers ==="
  "$PWS" -NoProfile -ExecutionPolicy Bypass -File "$SYNC_PS" || \
    echo "WARN: sync_artifacts.ps1 报告跳过项（见上方告警）；引擎构建本身成功。"
elif [ -f "$SYNC_PS" ]; then
  echo "WARN: powershell 未找到，跳过自动同步（引擎构建已成功）"
else
  echo "WARN: $SYNC_PS 不存在，跳过自动同步"
fi
