#!/system/bin/sh
# Command interface for the WebUI: ctl.sh status | enable | disable | set-iface NAME

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

# Interface names and addresses never contain quotes or backslashes, so the
# values need no JSON escaping.
status_json() {
    read_state
    list='' cur=''
    set -f
    IFS=$NL
    for line in $ADDRS; do
        IFS=' '
        # shellcheck disable=SC2086
        set -- $line
        IFS=$NL
        if [ "$1" = "$cur" ]; then
            list="$list,\"$3\""
        else
            [ -n "$cur" ] && list="$list]},"
            list="$list{\"name\":\"$1\",\"addresses\":[\"$3\""
            cur=$1
        fi
    done
    unset IFS
    set +f
    [ -n "$cur" ] && list="$list]}"
    echo "{\"state\":\"$STATE\",\"port\":$PORT,\"iface\":\"$CONF_IFACE\",\"target\":\"$TARGET\",\"firewall\":\"$FWIF\",\"address\":\"$ADDR\",\"tailscale\":\"$TS_IFACE\",\"interfaces\":[$list]}"
}

case "$1" in
    status)
        status_json
        ;;
    enable)
        enable_tcp_adb; r=$?; update_status; exit "$r"
        ;;
    disable)
        disable_tcp_adb; r=$?; update_status; exit "$r"
        ;;
    set-iface)
        if ! conf_set_iface "$2"; then
            echo "ERROR: invalid interface name."
            exit 1
        fi
        r=0
        # Move an active firewall over immediately.
        read_state
        if [ "$STATE" != off ]; then enable_tcp_adb; r=$?; fi
        update_status
        exit "$r"
        ;;
    *)
        echo "usage: $0 status | enable | disable | set-iface NAME" >&2
        exit 2
        ;;
esac
