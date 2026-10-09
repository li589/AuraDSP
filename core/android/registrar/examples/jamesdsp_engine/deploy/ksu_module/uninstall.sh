#!/system/bin/sh
# uninstall.sh — module removal is self-healing: all mounts (tmpfs overlay,
# xml bind-mount) live in memory only and vanish on next reboot; sepolicy
# rules are injected at runtime only. Nothing persisted on disk to revert.
#
# Best-effort immediate restoration without reboot:
echo "AuraDSP: mounts and sepolicy rules are runtime-only; a reboot fully restores stock audio."
killall audioserver 2>/dev/null
killall audiohalservice.qti 2>/dev/null
exit 0
