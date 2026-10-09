#!/system/bin/sh
# post-fs-data.sh — AuraDSP persistent deployment (early boot, blocking).
#
# Replaces the manual spike deploy chain on every boot, BEFORE audioserver /
# audiohalservice.qti start — so no service restart is needed:
#   1. tmpfs overlay on /vendor/lib64/soundfx (stock libs + libjdsp.so)
#   2. bind-mount patched audio_effects_config.xml over /odm/etc
#
# SELinux rules come from sepolicy.rule (applied by ksud before this stage).
# Logs: /data/adb/auradsp/boot.log

MODDIR=${0%/*}
LOGDIR=/data/adb/auradsp
LOG=$LOGDIR/boot.log

mkdir -p "$LOGDIR"
{
  echo "=== post-fs-data $(date) ==="

  SFX=/vendor/lib64/soundfx
  XML_SRC=$MODDIR/files/audio_effects_config.xml
  XML_DST=/odm/etc/audio_effects_config.xml

  # ---- 1. tmpfs overlay on soundfx ----
  if ! grep -q " $SFX tmpfs" /proc/mounts; then
    if ! mount -t tmpfs -o size=64m,mode=755 tmpfs "$SFX"; then
      echo "FATAL: tmpfs mount on $SFX failed" >&2
      exit 1
    fi
    echo "tmpfs mounted on $SFX"
  else
    echo "tmpfs already mounted on $SFX"
  fi

  # Restore stock soundfx + libjdsp (idempotent, tmpfs may be empty or stale)
  rm -f "$SFX"/*
  cp "$MODDIR/soundfx_orig/"* "$SFX/" || { echo "FATAL: soundfx restore failed"; exit 1; }
  cp "$MODDIR/files/libjdsp.so" "$SFX/" || { echo "FATAL: libjdsp copy failed"; exit 1; }
  chmod 644 "$SFX"/*
  chcon u:object_r:vendor_file:s0 "$SFX"/* 2>/dev/null
  echo "soundfx restored: $(ls "$SFX" | wc -l) files"

  # ---- 2. odm xml bind-mount ----
  if ! grep -q " $XML_DST " /proc/mounts; then
    chcon u:object_r:vendor_configs_file:s0 "$XML_SRC" 2>/dev/null
    if mount --bind "$XML_SRC" "$XML_DST"; then
      echo "xml bind-mounted: $XML_SRC -> $XML_DST"
    else
      echo "WARN: xml bind-mount failed (rc=$?) — continuing"
    fi
  else
    echo "xml already bind-mounted"
  fi

  echo "=== post-fs-data done ==="
} >> "$LOG" 2>&1

exit 0
