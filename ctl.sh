#!/system/bin/sh
# Command interface for the WebUI: ctl.sh status | enable | disable | set-iface NAME

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

json_str() {
    printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"
}

status_json() {
    read_state
    printf '{"state":%s,"port":%s,"iface":%s,"target":%s,"firewall":%s,"address":%s,"tailscale":%s,"interfaces":[' \
        "$(json_str "$STATE")" "$PORT" "$(json_str "$(conf_iface)")" "$(json_str "$TARGET")" \
        "$(json_str "$FWIF")" "$(json_str "$ADDR")" "$(json_str "$(tailscale_iface)")"
    iface_addrs | awk '
        function q(s) { gsub(/[\\"]/, "\\\\&", s); return "\"" s "\"" }
        $1 != cur {
            if (cur != "") printf "]},"
            cur = $1; n = 0
            printf "{\"name\":%s,\"addresses\":[", q($1)
        }
        { printf "%s%s", (n++ ? "," : ""), q($3) }
        END { if (cur != "") printf "]}" }'
    printf ']}\n'
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
