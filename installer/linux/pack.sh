#!/bin/bash
# AuraDSP Linux 打包总入口（发行构成：installer/docs/01 §2.3、03 号规格）。
#
# 产物（默认全量）：
#   auradsp_<VERSION>_amd64.deb                 正式安装包
#   auradsp-driver-loopback_<VERSION>_all.deb   驱动包（snd-aloop 配置）
#   AuraDSP-v<VERSION>-x86_64.AppImage          便携包
#   AuraDSP-Linux-x64-v<VERSION>.tar.gz         便携包（补充形态）
# Flatpak / Snap 为预留：本入口只校验清单文件在位，不产出商店包。
#
# 输入：Flutter Linux bundle（默认 app/auradsp_app/build/linux/x64/release/bundle，
#       引擎 .so 与 plugin_host_x64/x86 须已由 sync 流程随 bundle 就位）。
# 版本：installer/shared/version_resolver.py 解析 pubspec（发布格式校验）。
#
# 用法：pack.sh [--build] [--bundle DIR] [--out DIR] [--only deb,driver,appimage,portable]
#   --build  先一键构建再打包：引擎（cmake 预设 linux-x64）→ Flutter
#            bundle → sync_artifacts 同步引擎/宿主进 bundle/lib，然后打包。
#            从干净拉取到产出三件只需这一条命令（需 cmake/ninja/flutter
#            与 multilib 等构建依赖在位，同 CI J2/J8 口径）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUNDLE="$ROOT/app/auradsp_app/build/linux/x64/release/bundle"
OUT="$ROOT/dist"
ONLY=""
BUILD=0

while [ $# -gt 0 ]; do
    case "$1" in
        --build) BUILD=1; shift ;;
        --bundle) BUNDLE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        *) echo "error: 未知参数 $1" >&2; exit 2 ;;
    esac
done

eval "$(python3 "$ROOT/installer/shared/version_resolver.py")"
echo "AuraDSP Linux packaging — version $AURADSP_VERSION (tag $AURADSP_TAG)"

if [ "$BUILD" = "1" ]; then
    echo "== --build: engine -> app bundle -> sync =="
    command -v flutter >/dev/null 2>&1 || { echo "error: 找不到 flutter（先安装 Flutter 并加入 PATH）" >&2; exit 1; }
    (cd "$ROOT" && cmake --preset linux-x64 -DAURADSP_BUILD_HOST_X86=ON)
    (cd "$ROOT" && cmake --build --preset linux-x64-release)
    (cd "$ROOT/app/auradsp_app" && flutter build linux --release --no-tree-shake-icons)
    # sync 退出码 2 表示有可选目标被跳过（如 dist 分发目录不存在），
    # 不算失败；bundle 是否完整以下面的完整性检查为准。
    python3 "$ROOT/tools/sync_artifacts.py" || echo "warning: sync_artifacts 有跳过项，以 bundle 完整性检查为准"
fi
echo "bundle: $BUNDLE"
echo "out:    $OUT"

[ -x "$BUNDLE/auradsp_app" ] || { echo "error: bundle 不完整（缺 auradsp_app）" >&2; exit 1; }
[ -f "$BUNDLE/lib/libauradsp_engine.so" ] || { echo "error: bundle 缺引擎 libauradsp_engine.so（先跑 sync_artifacts）" >&2; exit 1; }
[ -f "$BUNDLE/lib/plugin_host_x64" ] || { echo "error: bundle 缺 plugin_host_x64" >&2; exit 1; }
[ -f "$BUNDLE/lib/plugin_host_x86" ] || echo "warning: bundle 缺 plugin_host_x86（32 位桥将不随包）"

want() { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }

mkdir -p "$OUT"
if want deb;      then bash "$HERE/deb/build_deb.sh" "$BUNDLE" "$AURADSP_VERSION" "$OUT"; fi
if want driver;   then bash "$HERE/driver/build_driver_deb.sh" "$AURADSP_VERSION" "$OUT"; fi
if want appimage; then bash "$HERE/appimage/build_appimage.sh" "$BUNDLE" "$AURADSP_VERSION" "$OUT"; fi
if want portable; then bash "$HERE/portable/build_portable.sh" "$BUNDLE" "$AURADSP_VERSION" "$OUT"; fi

# 预留格式：清单在位校验（不产出）
for f in "$HERE/flatpak/org.auradsp.AuraDSP.yml" "$HERE/snap/snapcraft.yaml"; do
    [ -f "$f" ] && echo "reserved manifest ok: ${f#"$ROOT"/}" || echo "warning: 预留清单缺失: $f"
done

echo "done. artifacts in $OUT:"
ls -1 "$OUT" | grep -E "^(auradsp|AuraDSP)" || ls -1 "$OUT"
