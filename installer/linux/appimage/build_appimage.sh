#!/bin/bash
# 构建便携包 AuraDSP-v<VERSION>-x86_64.AppImage（规格：installer/docs/03 §3）。
#
# 工具链：appimagetool + type2 runtime，均按 tools.pins 钉版 + SHA256
# 校验（runtime 用 --runtime-file 钉死，禁止构建时现下滚动 continuous）。
# 内容铁律：只装 Flutter bundle 自带文件——绝不捆绑 libpulse/libasound，
# 也不捆绑 GTK/GLib（音频与图形栈用宿主机库，见 03 §1）。
#
# 用法：build_appimage.sh <bundle_dir> <version> <out_dir> [tools_cache_dir]
set -euo pipefail

BUNDLE="${1:?bundle dir required}"
VERSION="${2:?version required}"
OUT="${3:?out dir required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="$(dirname "$HERE")"
ROOT="$(cd "$LINUX_DIR/../.." && pwd)"
CACHE="${4:-${AURADSP_TOOLS_CACHE:-$HOME/.cache/auradsp-pack-tools}}"
PINS="$HERE/tools.pins"

[ -x "$BUNDLE/auradsp_app" ] || { echo "error: bundle 缺 auradsp_app: $BUNDLE" >&2; exit 1; }
[ -f "$BUNDLE/lib/libauradsp_engine.so" ] || { echo "error: bundle 缺 lib/libauradsp_engine.so" >&2; exit 1; }
[ -f "$BUNDLE/lib/plugin_host_x64" ] || { echo "error: bundle 缺 lib/plugin_host_x64" >&2; exit 1; }
[ -f "$BUNDLE/lib/plugin_host_x86" ] || { echo "error: bundle 缺 lib/plugin_host_x86（32 位桥）" >&2; exit 1; }
command -v file >/dev/null || { echo "error: appimagetool 需要 file 命令" >&2; exit 1; }

fetch_pinned() {
    # $1=name $2=destfile —— 按 tools.pins 下载（或复用缓存）并校验 SHA256
    local name="$1" dest="$2" line ver sha url
    line="$(grep "^$name " "$PINS")" || { echo "error: tools.pins 缺 $name" >&2; exit 1; }
    read -r _ ver sha url <<< "$line"
    if [ ! -f "$dest" ]; then
        echo "downloading $name $ver ..."
        curl -sL -o "$dest.tmp" "$url"
        mv "$dest.tmp" "$dest"
    fi
    echo "$sha  $dest" | sha256sum -c - >/dev/null || {
        echo "error: $name SHA256 校验失败（$dest）" >&2; exit 1; }
    chmod +x "$dest"
    echo "tool ok: $name $ver (sha256 verified)"
}

mkdir -p "$CACHE"
APPIMAGETOOL="$CACHE/appimagetool-x86_64.AppImage"
RUNTIME="$CACHE/runtime-x86_64"
fetch_pinned appimagetool "$APPIMAGETOOL"
fetch_pinned type2-runtime "$RUNTIME"

APPDIR="$(mktemp -d)/AuraDSP.AppDir"
trap 'rm -rf "$(dirname "$APPDIR")"' EXIT
mkdir -p "$APPDIR/usr/lib"
cp -a "$BUNDLE" "$APPDIR/usr/lib/auradsp"
install -m 755 "$HERE/AppRun" "$APPDIR/AppRun"
install -m 644 "$LINUX_DIR/shared/auradsp.desktop" "$APPDIR/auradsp.desktop"
install -m 644 "$ROOT/app/auradsp_app/design/logo/icons/auradsp-app-256.png" "$APPDIR/auradsp.png"
ln -s auradsp.png "$APPDIR/.DirIcon"

# 权限规范化（AppDir 内文件将按 squashfs 权限落到用户机）
find "$APPDIR" -type d -exec chmod 755 {} +
find "$APPDIR" -type f -exec sh -c 'for f; do if file "$f" | grep -q ELF; then chmod 755 "$f"; else chmod 644 "$f"; fi; done' _ {} +
chmod 755 "$APPDIR/AppRun"

# 内容铁律自检：AppDir 内不得出现宿主音频库
if find "$APPDIR" -name 'libpulse*' -o -name 'libasound*' | grep -q .; then
    echo "error: AppDir 混入 libpulse/libasound，违反 03 §1 铁律" >&2; exit 1
fi

mkdir -p "$OUT"
APPIMAGE="$OUT/AuraDSP-v${VERSION}-x86_64.AppImage"
# 容器/CI 无 FUSE 时靠 EXTRACT_AND_RUN 运行工具本体；runtime 钉死传入。
# AppDir 内含 32 位桥（i386 ELF 载荷），appimagetool 需显式 ARCH 才肯打包
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGETOOL" --runtime-file "$RUNTIME" "$APPDIR" "$APPIMAGE" >/dev/null
chmod +x "$APPIMAGE"
echo "built: $APPIMAGE"
