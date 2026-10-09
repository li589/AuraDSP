#!/system/bin/sh
# service.sh — late_start fallback. Normal boots finish everything in
# post-fs-data.sh; this only heals a partially-failed boot and restarts
# audioserver in that case (mounts must precede audioserver start).

MODDIR=${0%/*}
LOGDIR=/data/adb/auradsp
LOG=$LOGDIR/boot.log

{
  SFX=/vendor/lib64/soundfx
  XML_DST=/odm/etc/audio_effects_config.xml

  NEED_RESTART=0

  if ! grep -q " $SFX tmpfs" /proc/mounts; then
    echo "=== service.sh: tmpfs missing, healing ===" >> "$LOG" 2>&1
    "$MODDIR/post-fs-data.sh"
    NEED_RESTART=1
  fi
  if ! grep -q " $XML_DST " /proc/mounts; then
    echo "=== service.sh: xml bind missing, healing ===" >> "$LOG" 2>&1
    chcon u:object_r:vendor_configs_file:s0 "$MODDIR/files/audio_effects_config.xml" 2>/dev/null
    mount --bind "$MODDIR/files/audio_effects_config.xml" "$XML_DST" \
      && echo "xml bind ok (heal)" >> "$LOG" 2>&1
    NEED_RESTART=1
  fi

  if [ "$NEED_RESTART" = "1" ]; then
    # Services already started with stock config — restart so they dlopen
    # the overlay and re-read the patched xml.
    killall audioserver 2>/dev/null
    killall audiohalservice.qti 2>/dev/null
    echo "=== service.sh: audioserver restarted for heal ===" >> "$LOG" 2>&1
  else
    echo "=== service.sh: deployment intact, no action ===" >> "$LOG" 2>&1
  fi
} &

exit 0
