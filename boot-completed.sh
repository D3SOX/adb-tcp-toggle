#!/system/bin/sh

# Status refresh only. This does NOT enable ADB TCP and does NOT modify firewall rules.
MODDIR=${0%/*}
. "$MODDIR/status.sh"
update_status
