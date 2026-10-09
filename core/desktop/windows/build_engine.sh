#!/bin/bash
# build_engine.sh — build auradsp_engine.dll (AuraDSP Engines Desktop v1, Win x64)
#
# Sources (per docs/项目架构与开发规范.md §3 — 源码整合，无预编译依赖):
#   ../vendor-src/libjamesdsp/   JamesDSP C engine (原样提取, 见 ORIGIN.md)
#   ../engine_api/               auradsp_engine.h/.cpp/.def — 统一 C ABI
#
# Toolchain: CMake + Visual Studio 18 2026 generator (MSVC x64)
# Output:    out/auradsp_engine.dll + auradsp_engine.lib
# Exports:   auradsp_* 11 symbols only (engine_api/auradsp_engine.def)
set -e

HERE_W="$(cd "$(dirname "$0")" && pwd -W)"        # core/desktop/windows
OUT_W="$HERE_W/out"
mkdir -p "$OUT_W"

CMAKE="$(command -v cmake || echo /c/FreeRulesPrograms/BasicToolkits/CMake/bin/cmake)"

echo "=== [1/2] cmake configure ==="
"$CMAKE" -S "$HERE_W" -B "$OUT_W" -G "Visual Studio 18 2026" -A x64 \
  -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5

echo "=== [2/2] build ==="
"$CMAKE" --build "$OUT_W" --config Release 2>&1 | tail -25

DLL="$OUT_W/Release/auradsp_engine.dll"
[ -f "$DLL" ] || { echo "ERROR: auradsp_engine.dll not produced"; exit 1; }
echo "=== BUILD OK: $DLL ==="
ls -la "$OUT_W/Release/auradsp_engine.dll" "$OUT_W/Release/auradsp_engine.lib"
