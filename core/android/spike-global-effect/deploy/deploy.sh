#!/usr/bin/env bash
# deploy.sh — SpikeEQ 一键部署（临时挂载，reboot 失效）
set -e
ADB="D:/myPrograms/AndroidDevelop/Android-SDK/platform-tools/adb.exe"
ROOT="$(cd "$(dirname "$0")/.." && pwd -W)"

echo "== [1/6] 注入并推送 odm xml 补丁 =="
python "$ROOT/deploy/patch_xml.py"

echo "== [2/6] 推送 libspikeeq.so =="
"$ADB" push "$ROOT/out/libspikeeq.so" /data/local/tmp/spike/

echo "== [3/6] 备份原 soundfx 目录与 SELinux 上下文 =="
"$ADB" shell "su -c 'mkdir -p /data/local/tmp/spike/sfx_bak && cp /vendor/lib64/soundfx/* /data/local/tmp/spike/sfx_bak/ 2>/dev/null; true'"
CTX_DIR=$("$ADB" shell "su -c 'stat -c %C /vendor/lib64/soundfx'" | tr -d '\r\n')
CTX_SO=$("$ADB" shell "su -c 'stat -c %C /vendor/lib64/soundfx/libbundleaidl.so'" | tr -d '\r\n')
CTX_XML=$("$ADB" shell "su -c 'stat -c %C /odm/etc/audio_effects_config.xml'" | tr -d '\r\n')
echo "ctx dir=$CTX_DIR so=$CTX_SO xml=$CTX_XML"

echo "== [4/6] tmpfs 覆盖 /vendor/lib64/soundfx 并还原内容 =="
"$ADB" shell "su -c 'grep -q \" /vendor/lib64/soundfx tmpfs\" /proc/mounts || mount -t tmpfs -o size=16m,mode=755 tmpfs /vendor/lib64/soundfx'"
"$ADB" shell "su -c 'cp /data/local/tmp/spike/sfx_bak/* /vendor/lib64/soundfx/ && cp /data/local/tmp/spike/libspikeeq.so /vendor/lib64/soundfx/ && chmod 644 /vendor/lib64/soundfx/*'"
"$ADB" shell "su -c 'chcon -R $CTX_DIR /vendor/lib64/soundfx'"

echo "== [5/6] bind-mount 补丁版 odm xml =="
"$ADB" shell "su -c 'chcon $CTX_XML /data/local/tmp/spike/audio_effects_config.xml'"
"$ADB" shell "su -c 'mount --bind /data/local/tmp/spike/audio_effects_config.xml /odm/etc/audio_effects_config.xml'"

echo "== [6/6] 重启 audioserver 并观察 =="
"$ADB" shell "su -c 'killall audioserver'"
sleep 4
echo "---- audioserver 存活? ----"
"$ADB" shell "ps -A | grep 'audioserver$' | head -2"
echo "---- logcat: EffectsFactory / SpikeEQ ----"
"$ADB" logcat -d 2>/dev/null | grep -E "EffectsFactory|SpikeEQ|spike_eq" | tail -25
echo "done."
