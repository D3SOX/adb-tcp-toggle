#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

# Keep the firewall if adbd still listens; that is safer than exposing the port.
disable_tcp_adb >/dev/null 2>&1
rm -f "$CONF"
