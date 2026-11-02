#!/usr/bin/env bash
# 构建 Linux C++ 引擎并报告产物路径（S2，2026-11-01）。
# 与 core/desktop/windows/build_engine.sh 对称，但走 POSIX 工具链：
# 根 CMakePresets 的 linux-x64（Ninja）配置 + linux-x64-release 构建。
# Linux 首期无产物分发同步（sync_artifacts 跨平台化属 S4），构建成功即止。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

cmake --preset linux-x64
cmake --build --preset linux-x64-release

echo "engine artifact: $ROOT/core/desktop/linux/out/Release/libauradsp_engine.so"
