#!/system/bin/sh

# Status refresh only: never enables ADB TCP or touches the firewall.
MODDIR=${0%/*}
. "$MODDIR/lib.sh"
update_status
