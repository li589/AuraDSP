#!/bin/bash
# 构建便携包 AuraDSP-Linux-x64-v<VERSION>.tar.gz（AppImage 的补充形态）。
# 解压即用：./auradsp 启动；内容为 Flutter bundle 原样 + 启动脚本。
#
# 用法：build_portable.sh <bundle_dir> <version> <out_dir>
set -euo pipefail

BUNDLE="${1:?bundle dir required}"
VERSION="${2:?version required}"
OUT="${3:?out dir required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -x "$BUNDLE/auradsp_app" ] || { echo "error: bundle 缺 auradsp_app: $BUNDLE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DIR="$WORK/AuraDSP-Linux-x64"
mkdir -p "$DIR"
cp -a "$BUNDLE/." "$DIR/"
cat > "$DIR/auradsp" <<'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
exec "${HERE}/auradsp_app" "$@"
EOF
chmod 755 "$DIR/auradsp"
install -m 644 "$HERE/README.portable.md" "$DIR/README.md"

# 权限规范化（解压后任意用户可读可执行）
find "$DIR" -type d -exec chmod 755 {} +
find "$DIR" -type f -exec sh -c 'for f; do if file "$f" | grep -q ELF; then chmod 755 "$f"; else chmod 644 "$f"; fi; done' _ {} +
chmod 755 "$DIR/auradsp"

mkdir -p "$OUT"
TAR="$OUT/AuraDSP-Linux-x64-v${VERSION}.tar.gz"
tar -czf "$TAR" -C "$WORK" "AuraDSP-Linux-x64"
echo "built: $TAR"
