#!/usr/bin/env bash
# rollback.sh — 撤销 SpikeEQ（还原 xml 与 soundfx，重启 audioserver）
set -e
ADB="D:/myPrograms/AndroidDevelop/Android-SDK/platform-tools/adb.exe"
echo "== 先停 audioserver（释放 tmpfs 上的 dlopened 库），再卸载挂载 =="
"$ADB" shell "su -c 'killall audioserver'"; sleep 2
for i in 1 2; do
  "$ADB" shell "su -c 'umount /odm/etc/audio_effects_config.xml 2>/dev/null; umount /vendor/lib64/soundfx 2>/dev/null; true'"
done
echo "== 再次重启 audioserver 恢复服务 =="
"$ADB" shell "su -c 'killall audioserver'"; sleep 3
echo "== 残留检查 =="
"$ADB" shell "su -c 'grep -E \"soundfx|audio_effects_config\" /proc/mounts'" || echo "(无残留挂载，已还原)"
echo "完成。如需彻底清理缓存文件: adb shell 'rm -rf /data/local/tmp/spike'"
