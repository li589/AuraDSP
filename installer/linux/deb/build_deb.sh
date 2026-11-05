#!/bin/bash
# 构建 AuraDSP 正式安装包 auradsp_<VERSION>-1_amd64.deb（规格：installer/docs/03 §2）。
#
# 输入：Flutter Linux bundle 目录（auradsp_app + lib/ + data/ + resources/）。
# 布局说明：Flutter runner 要求 binary 与 lib/、data/ 保持 bundle 原生相对
# 结构，故整包原样装入 /usr/lib/auradsp/，不按 03 §2.1 的示意树拆平；
# /usr/bin/auradsp 为指向主程序的符号链接。
#
# 用法：build_deb.sh <bundle_dir> <version> <out_dir>
set -euo pipefail

BUNDLE="${1:?bundle dir required}"
VERSION="${2:?version required}"
OUT="${3:?out dir required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="$(dirname "$HERE")"
ROOT="$(cd "$LINUX_DIR/../.." && pwd)"
ICONS_SRC="$ROOT/app/auradsp_app/design/logo/icons"
ICON_SVG="$ROOT/app/auradsp_app/design/logo/auradsp-app-icon.svg"

[ -x "$BUNDLE/auradsp_app" ] || { echo "error: bundle 缺 auradsp_app: $BUNDLE" >&2; exit 1; }
[ -f "$BUNDLE/lib/libauradsp_engine.so" ] || { echo "error: bundle 缺 lib/libauradsp_engine.so" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/pkg"
mkdir -p "$PKG/usr/lib" "$PKG/usr/bin" "$PKG/usr/share/applications" \
         "$PKG/usr/share/doc/auradsp" "$PKG/DEBIAN"

# --- 主体：bundle 原样进 /usr/lib/auradsp ---
cp -a "$BUNDLE" "$PKG/usr/lib/auradsp"
ln -s ../lib/auradsp/auradsp_app "$PKG/usr/bin/auradsp"

# --- 桌面入口与图标 ---
install -m 644 "$LINUX_DIR/shared/auradsp.desktop" "$PKG/usr/share/applications/auradsp.desktop"
for sz in 16 24 32 48 64 128 256 512; do
    src="$ICONS_SRC/auradsp-app-$sz.png"
    [ -f "$src" ] || continue
    d="$PKG/usr/share/icons/hicolor/${sz}x${sz}/apps"
    mkdir -p "$d"
    install -m 644 "$src" "$d/auradsp.png"
done
if [ -f "$ICON_SVG" ]; then
    d="$PKG/usr/share/icons/hicolor/scalable/apps"
    mkdir -p "$d"
    install -m 644 "$ICON_SVG" "$d/auradsp.svg"
fi

# --- 文档 ---
cat > "$PKG/usr/share/doc/auradsp/copyright" <<'EOF'
AuraDSP — cross-platform global audio effects system.
Copyright (c) AuraDSP contributors. All rights reserved.
Bundled third-party components remain under their respective licenses;
see the repository LICENSE and vendor notices for details.
EOF
{
    echo "auradsp ($VERSION-1) stable; urgency=medium"
    echo ""
    echo "  * Release $VERSION (see repository RELEASE_NOTES / git tag)."
    echo ""
    echo " -- li589 <3119317786@qq.com>  $(date -R)"
} > "$PKG/usr/share/doc/auradsp/changelog"
gzip -9 -n -f "$PKG/usr/share/doc/auradsp/changelog"


# 权限规范化：bundle 源文件带构建机权限（如 770），安装后必须全机可读；
# 目录 755，ELF 755，其余 644（maintainer 脚本在下方单独恢复 755）。
find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec sh -c 'for f; do if file "$f" | grep -q ELF; then chmod 755 "$f"; else chmod 644 "$f"; fi; done' _ {} +

# --- 控制文件 ---# --- 控制文件 ---
INSTALLED_SIZE="$(du -sk "$PKG/usr" | cut -f1)"
cat > "$PKG/DEBIAN/control" <<EOF
Package: auradsp
Version: $VERSION-1
Section: sound
Priority: optional
Architecture: amd64
Maintainer: li589 <3119317786@qq.com>
Installed-Size: $INSTALLED_SIZE
Depends: libc6 (>= 2.35), libgtk-3-0t64 | libgtk-3-0 (>= 3.24), libstdc++6 (>= 11), libpulse0, libasound2t64 | libasound2
Recommends: pulseaudio | pipewire-pulse, auradsp-driver-loopback
Description: Cross-platform global audio effects system
 AuraDSP takes over the system audio path and applies a real-time DSP
 chain: 23 effect units, convolution / DDC headphone correction,
 Liveprog scripting, and VST3 / CLAP / VST2 plugin hosting (in-process
 64-bit, isolated hosts, 32-bit bridge). On Linux it runs on PulseAudio
 (system / virtual sink / snd-aloop driver modes) with an ALSA expert
 mode. The driver mode needs the snd-aloop kernel module; install the
 auradsp-driver-loopback package to enable it at boot. The bundled
 32-bit plugin bridge (plugin_host_x86) needs 32-bit system libraries
 (multilib) on the target machine.
EOF

cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
fi
exit 0
EOF

cat > "$PKG/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
fi
exit 0
EOF
chmod 755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"

mkdir -p "$OUT"
DEB="$OUT/auradsp_${VERSION}_amd64.deb"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
echo "built: $DEB"
