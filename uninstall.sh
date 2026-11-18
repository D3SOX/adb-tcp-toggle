#!/system/bin/sh

PORT=5555
CHAIN=ADBTAILSCALE
IPT="$(command -v iptables 2>/dev/null)"
IP6T="$(command -v ip6tables 2>/dev/null)"

remove_family() {
    cmd="$1"
    [ -n "$cmd" ] || return 0
    while "$cmd" -D INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null; do :; done
    "$cmd" -F "$CHAIN" 2>/dev/null || true
    "$cmd" -X "$CHAIN" 2>/dev/null || true
}

resetprop -p --delete persist.adb.tcp.port >/dev/null 2>&1 || true
resetprop service.adb.tcp.port -1 >/dev/null 2>&1 || true
stop adbd >/dev/null 2>&1 || true
sleep 1
start adbd >/dev/null 2>&1 || true
sleep 1

# Only remove the firewall once 5555 is no longer listening.
# If disabling adbd failed, leaving the firewall behind is safer.
if ! ss -lnt 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
    remove_family "$IPT"
    remove_family "$IP6T"
fi
