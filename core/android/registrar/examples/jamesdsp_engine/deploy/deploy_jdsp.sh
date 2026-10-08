#!/usr/bin/env bash
# deploy_jdsp.sh — AuraDSP(libjdsp.so) 一键部署（tmpfs overlay，reboot 失效，可用 spike 回滚脚本撤销）
#
# 与 spike deploy 的差异：
#   - tmpfs 已挂载（如 spike 部署在位）则只补拷 libjdsp.so，不重新备份/还原
#   - xml bind-mount 允许叠加（先 spike 后 jdsp 时为双层栈）
set -e
ADB="D:/myPrograms/AndroidDevelop/Android-SDK/platform-tools/adb.exe"
HERE="$(cd "$(dirname "$0")" && pwd -W)"
ENG="$(cd "$HERE/.." && pwd -W)"

echo "== [1/6] 注入并推送 odm xml 补丁 =="
python "$HERE/patch_xml_jdsp.py"

echo "== [2/6] 推送 libjdsp.so =="
"$ADB" push "$ENG/out/libjdsp.so" /data/local/tmp/spike/

echo "== [3/6] 检查 tmpfs 状态与 SELinux 上下文 =="
MOUNTED=$("$ADB" shell "su -c 'grep -c \" /vendor/lib64/soundfx tmpfs\" /proc/mounts'" | tr -d '\r\n')
CTX_DIR=$("$ADB" shell "su -c 'stat -c %C /vendor/lib64/soundfx'" | tr -d '\r\n')
CTX_SO=$("$ADB" shell "su -c 'stat -c %C /vendor/lib64/soundfx/libbundleaidl.so'" | tr -d '\r\n')
CTX_XML=$("$ADB" shell "su -c 'stat -c %C /odm/etc/audio_effects_config.xml'" | tr -d '\r\n')
echo "tmpfs_mounted=$MOUNTED ctx dir=$CTX_DIR so=$CTX_SO xml=$CTX_XML"

if [ "$MOUNTED" = "0" ]; then
  echo "== [4/6] tmpfs 未挂载：备份原目录 → 挂载(64m) → 还原 + 加入 libjdsp =="
  # 注意：原 soundfx 内容 ~14MB + libjdsp 5.6MB，16m 的 tmpfs 会 ENOSPC 截断 cp（血泪教训）
  "$ADB" shell "su -c 'mkdir -p /data/local/tmp/spike/sfx_bak && cp /vendor/lib64/soundfx/* /data/local/tmp/spike/sfx_bak/'"
  "$ADB" shell "su -c 'mount -t tmpfs -o size=64m,mode=755 tmpfs /vendor/lib64/soundfx'"
  "$ADB" shell "su -c 'cp /data/local/tmp/spike/sfx_bak/* /vendor/lib64/soundfx/ && cp /data/local/tmp/spike/libjdsp.so /vendor/lib64/soundfx/ && chmod 644 /vendor/lib64/soundfx/*'"
  "$ADB" shell "su -c 'chcon -R $CTX_DIR /vendor/lib64/soundfx'"
else
  echo "== [4/6] tmpfs 已挂载：仅补拷 libjdsp.so =="
  "$ADB" shell "su -c 'cp /data/local/tmp/spike/libjdsp.so /vendor/lib64/soundfx/ && chmod 644 /vendor/lib64/soundfx/libjdsp.so && chcon $CTX_SO /vendor/lib64/soundfx/libjdsp.so'"
fi

echo "== [5/6] bind-mount 补丁版 odm xml =="
"$ADB" shell "su -c 'chcon $CTX_XML /data/local/tmp/spike/audio_effects_config.xml'"
"$ADB" shell "su -c 'mount --bind /data/local/tmp/spike/audio_effects_config.xml /odm/etc/audio_effects_config.xml'"

echo "== [6/6] 重启 audioserver 并观察 =="
"$ADB" shell "su -c 'killall audioserver'"
sleep 4
echo "---- audioserver 存活? ----"
"$ADB" shell "ps -A | grep 'audioserver$' | head -2"
echo "---- logcat: EffectsFactory / jamesdsp ----"
"$ADB" logcat -d 2>/dev/null | grep -iE "EffectsFactory|jamesdsp|libjdsp" | tail -30
echo "done."
