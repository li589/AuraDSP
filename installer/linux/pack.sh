#!/bin/bash
# AuraDSP Linux 打包总入口（**转发壳**，2026-11-20 工具链规范化）。
#
# 实现已收进 installer/packkit/linux/（Python），本脚本只做一件事：
# 把命令行原样交给 pack.py。保留它是因为 README、CI 与排障手册里写的
# 都是 `bash installer/linux/pack.sh --build` 这类命令，调用方式不能变。
#
# 产物（默认全量，规格见 installer/docs/03 §5）：
#   auradsp_<VERSION>_amd64.deb                 正式安装包
#   auradsp-driver-loopback_<VERSION>_all.deb   驱动包（snd-aloop 配置）
#   AuraDSP-v<VERSION>-x86_64.AppImage          便携包
#   AuraDSP-Linux-x64-v<VERSION>.tar.gz         便携包（补充形态）
# Flatpak / Snap 为预留：只校验清单文件在位，不产出商店包。
#
# 用法：pack.sh [--build] [--bundle DIR] [--out DIR]
#                [--only deb,driver,appimage,portable]
#                [--resources core|full|light|addons|none] [--packs-dir DIR]
#                [--what-if] [--version vXX.XX.X]
#   --build  先一键构建再打包：引擎（cmake 预设 linux-x64）→ Flutter
#            bundle → sync_artifacts 同步引擎/宿主进 bundle/lib，然后打包。
#            从干净拉取到产出四件只需这一条命令（需 cmake/ninja/flutter
#            与 multilib 等构建依赖在位，同 CI J2/J8 口径）。
#   --resources 资源档位（资源计划 P1）：与 Windows pack.py 同名同义。
#            **一次只允许一个档位**——Linux 产物名不含档位后缀，两档同名
#            会互相覆盖。
#   --what-if 只推演路径与清单，不复制、不合并、不打包。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: 找不到 python3（打包实现已迁到 installer/packkit/linux）" >&2
    exit 1
fi

exec python3 "$HERE/pack.py" "$@"
