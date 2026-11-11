#!/bin/bash
# 构建 Linux 驱动包 auradsp-driver-loopback_<VERSION>_all.deb（规格：installer/docs/03 §6）。
# 纯配置包：固化 snd-aloop 内核模块的开机自启与参数，并附自检脚本。
#
# 用法：build_driver_deb.sh <version> <out_dir>
set -euo pipefail

VERSION="${1:?version required}"
OUT="${2:?out dir required}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/pkg"
mkdir -p "$PKG/etc/modules-load.d" "$PKG/etc/modprobe.d" \
         "$PKG/usr/lib/auradsp-driver-loopback" "$PKG/usr/share/doc/auradsp-driver-loopback" \
         "$PKG/DEBIAN"

echo "snd-aloop" > "$PKG/etc/modules-load.d/auradsp-loopback.conf"
cat > "$PKG/etc/modprobe.d/auradsp-loopback.conf" <<'EOF'
# AuraDSP driver mode (snd-aloop loopback sound card, hw:Loopback).
# enable=1 keeps the module loadable on demand; the card appears as "Loopback".
options snd-aloop enable=1
EOF

cat > "$PKG/usr/lib/auradsp-driver-loopback/auradsp-loopback-check" <<'EOF'
#!/bin/bash
# AuraDSP 回环驱动自检：snd-aloop 模块与 Loopback 声卡可见性报告。
set -u
fail=0
if grep -q '^snd_aloop ' /proc/modules; then
    echo "OK   snd_aloop module is loaded"
else
    echo "MISS snd_aloop module is not loaded (try: sudo modprobe snd-aloop)"
    fail=1
fi
if [ -d /proc/asound/Loopback ]; then
    echo "OK   Loopback card is present (/proc/asound/Loopback)"
else
    echo "MISS Loopback card not found in /proc/asound"
    fail=1
fi
if command -v aplay >/dev/null 2>&1; then
    if aplay -l 2>/dev/null | grep -qi 'loopback'; then
        echo "OK   aplay -l lists the Loopback card"
    else
        echo "MISS aplay -l does not list a Loopback card"
        fail=1
    fi
fi
if [ "$fail" -eq 0 ]; then
    echo "auradsp-loopback: ready — AuraDSP driver mode can use hw:Loopback"
else
    echo "auradsp-loopback: not ready (see MISS lines above)"
fi
exit "$fail"
EOF
chmod 755 "$PKG/usr/lib/auradsp-driver-loopback/auradsp-loopback-check"

cat > "$PKG/usr/share/doc/auradsp-driver-loopback/copyright" <<'EOF'
AuraDSP loopback driver configuration package.
Copyright (c) AuraDSP contributors. All rights reserved.
Configuration-only package for the in-tree snd-aloop kernel module.
EOF
{
    echo "auradsp-driver-loopback ($VERSION) stable; urgency=medium"
    echo ""
    echo "  * Release $VERSION."
    echo ""
    echo " -- AuraDSP Project <3119317786@qq.com>  $(date -R)"
} > "$PKG/usr/share/doc/auradsp-driver-loopback/changelog"
gzip -9 -n -f "$PKG/usr/share/doc/auradsp-driver-loopback/changelog"


# 权限规范化（同主包口径）
find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec sh -c 'for f; do if file "$f" | grep -q ELF; then chmod 755 "$f"; else chmod 644 "$f"; fi; done' _ {} +
chmod 755 "$PKG/usr/lib/auradsp-driver-loopback/auradsp-loopback-check"

cat > "$PKG/DEBIAN/control" <<EOF
Package: auradsp-driver-loopback
Version: $VERSION
Section: sound
Priority: optional
Architecture: all
Maintainer: AuraDSP Project <3119317786@qq.com>
Depends: kmod
Recommends: alsa-utils
Description: snd-aloop loopback configuration for AuraDSP driver mode
 AuraDSP's Linux driver mode captures from the snd-aloop loopback card
 (hw:Loopback). This package enables the module at boot
 (/etc/modules-load.d), pins its options (/etc/modprobe.d), and ships
 a self-check tool:
 .
   /usr/lib/auradsp-driver-loopback/auradsp-loopback-check
 .
 It contains no binaries and can be installed or removed independently
 of the main auradsp package.
EOF

cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    # Best effort: make driver mode usable immediately; on restricted
    # systems the config still takes effect at next boot.
    modprobe snd-aloop 2>/dev/null || true
fi
exit 0
EOF
chmod 755 "$PKG/DEBIAN/postinst"

mkdir -p "$OUT"
DEB="$OUT/auradsp-driver-loopback_${VERSION}_all.deb"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
echo "built: $DEB"
