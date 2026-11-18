#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

toggle_tcp_adb
RESULT=$?
update_status

# Keep the manager's action output readable.
echo
for i in 3 2 1; do
    echo "Closing in $i..."
    sleep 1
done
exit "$RESULT"
