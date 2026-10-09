#!/system/bin/sh
# customize.sh — runs on-device during module install (ksud).
# Snapshot the stock soundfx directory so boot-time overlay can restore it.
# (The tmpfs overlay replaces the directory contents; without this snapshot
#  the stock vendor effect libs would vanish after reboot.)

ui_print "- AuraDSP JamesDSP effect module"

if [ ! -d /vendor/lib64/soundfx ]; then
  abort "! /vendor/lib64/soundfx not found — unsupported device"
fi

ui_print "- Snapshotting stock /vendor/lib64/soundfx"
rm -rf "$MODPATH/soundfx_orig"
mkdir -p "$MODPATH/soundfx_orig"
cp /vendor/lib64/soundfx/* "$MODPATH/soundfx_orig/" || abort "! failed to snapshot soundfx"
ui_print "  $(ls "$MODPATH/soundfx_orig" | wc -l) files snapshotted"

# libjdsp.so and audio_effects_config.xml ship inside files/ of the zip.
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh"  0 0 0755
set_perm "$MODPATH/service.sh"       0 0 0755

ui_print "- Installed. Takes effect after reboot."
ui_print "  (Manual spike deployment, if any, is replaced on reboot.)"
