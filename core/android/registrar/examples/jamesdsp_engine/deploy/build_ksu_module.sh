#!/usr/bin/env bash
# build_ksu_module.sh — package the AuraDSP KSU module zip.
#
# Inputs:  ksu_module/ (module skeleton) + out/libjdsp.so + out/audio_effects_config.xml
# Output:  out/auradsp_jdsp_v<ver>.zip
#
# Install: adb push out/auradsp_*.zip /data/local/tmp/
#          su -c 'ksud module install /data/local/tmp/auradsp_jdsp_v*.zip'
# Reboot to activate (post-fs-data.sh mounts before audio services start).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -W)"
ENG="$(cd "$HERE/.." && pwd -W)"
OUT="$ENG/out"
WORK="$OUT/ksu_pkg"
ZIPBIN="python"

VER=$(grep -oP '(?<=^version=).*' "$HERE/ksu_module/module.prop" | head -1)
VERCODE=$(grep -oP '(?<=^versionCode=).*' "$HERE/ksu_module/module.prop" | head -1)
ZIPFILE="$OUT/auradsp_jdsp_${VER}_code${VERCODE}.zip"

echo "== [1/3] staging module tree =="
rm -rf "$WORK"; mkdir -p "$WORK/files"
cp "$HERE/ksu_module/module.prop" \
   "$HERE/ksu_module/sepolicy.rule" \
   "$HERE/ksu_module/customize.sh" \
   "$HERE/ksu_module/post-fs-data.sh" \
   "$HERE/ksu_module/service.sh" \
   "$HERE/ksu_module/uninstall.sh" \
   "$WORK/"
cp "$OUT/libjdsp.so" "$WORK/files/"
cp "$OUT/audio_effects_config.xml" "$WORK/files/"

# Normalize line endings: Android shell scripts must be LF; module.prop too.
"$ZIPBIN" - "$WORK" <<'PYEOF'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
for p in root.rglob('*'):
    if p.is_file() and p.suffix in ('.sh', '.prop', '.rule') or p.name in ('customize.sh',):
        b = p.read_bytes().replace(b'\r\n', b'\n')
        p.write_bytes(b)
        print(f'LF normalized: {p.relative_to(root)}')
PYEOF

echo "== [2/3] zipping -> $ZIPFILE =="
rm -f "$ZIPFILE"
"$ZIPBIN" - "$WORK" "$ZIPFILE" <<'PYEOF'
import sys, pathlib, zipfile
root = pathlib.Path(sys.argv[1]); out = sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file():
            z.write(p, p.relative_to(root).as_posix())
            print(' +', p.relative_to(root).as_posix())
PYEOF

echo "== [3/3] done =="
ls -la "$ZIPFILE"
echo "Install: adb push $ZIPFILE /data/local/tmp/ && su -c 'ksud module install /data/local/tmp/$(basename "$ZIPFILE")'"
