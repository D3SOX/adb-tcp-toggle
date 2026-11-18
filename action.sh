#!/system/bin/sh

MODDIR=${0%/*}
PORT=5555
TSIF=tun0
CHAIN=ADBTAILSCALE

# Dynamic module-card status helper.
. "$MODDIR/status.sh"

IPT="$(command -v iptables 2>/dev/null)"
IP6T="$(command -v ip6tables 2>/dev/null)"

say() {
    echo "$*"
}

remove_family() {
    cmd="$1"
    [ -n "$cmd" ] || return 0

    while "$cmd" -D INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null; do
        :
    done
    "$cmd" -F "$CHAIN" 2>/dev/null || true
    "$cmd" -X "$CHAIN" 2>/dev/null || true
}

fw_remove() {
    remove_family "$IPT"
    remove_family "$IP6T"
}

install_family() {
    cmd="$1"

    "$cmd" -N "$CHAIN" 2>/dev/null || return 1
    "$cmd" -A "$CHAIN" -i "$TSIF" -j ACCEPT || return 1
    "$cmd" -A "$CHAIN" -j DROP || return 1
    "$cmd" -I INPUT 1 -p tcp --dport "$PORT" -j "$CHAIN" || return 1
}

fw_install() {
    fw_remove

    install_family "$IPT" || {
        fw_remove
        return 1
    }

    install_family "$IP6T" || {
        fw_remove
        return 1
    }
}


disable_tcp_adb() {
    say "Disabling ADB TCP..."

    # Never leave a persistent TCP setting behind.
    resetprop -p --delete persist.adb.tcp.port >/dev/null 2>&1 || true
    resetprop service.adb.tcp.port -1 || {
        say "ERROR: could not change service.adb.tcp.port"
        say "Firewall left in place for safety."
        return 1
    }

    stop adbd
    sleep 1
    start adbd
    sleep 1

    if is_listening; then
        say "ERROR: adbd is still listening on port $PORT."
        say "Firewall left in place for safety."
        return 1
    fi

    fw_remove
    say "ADB TCP: OFF"
    say "USB ADB is unaffected."
}

enable_tcp_adb() {
    if [ -z "$IPT" ] || [ -z "$IP6T" ]; then
        say "ERROR: iptables/ip6tables not found."
        say "Refusing to expose ADB."
        return 1
    fi

    if ! ip link show "$TSIF" >/dev/null 2>&1; then
        say "ERROR: Tailscale interface $TSIF is not present."
        say "Start Tailscale first. ADB TCP was NOT enabled."
        return 1
    fi

    TSIP="$(ip -o -4 addr show dev "$TSIF" 2>/dev/null | awk '$4 ~ /^100\./ {sub(/\/.*/, "", $4); print $4; exit}')"
    if [ -z "$TSIP" ]; then
        say "ERROR: $TSIF has no 100.x Tailscale IPv4 address."
        say "ADB TCP was NOT enabled."
        return 1
    fi

    say "Installing firewall first..."
    if ! fw_install; then
        say "ERROR: could not install IPv4+IPv6 firewall rules."
        say "ADB TCP was NOT enabled."
        return 1
    fi

    # Ensure this is session-only. A reboot should turn it off.
    resetprop -p --delete persist.adb.tcp.port >/dev/null 2>&1 || true

    if ! resetprop service.adb.tcp.port "$PORT"; then
        say "ERROR: could not set service.adb.tcp.port."
        fw_remove
        return 1
    fi

    stop adbd
    sleep 1
    start adbd
    sleep 1

    if ! is_listening; then
        say "ERROR: adbd did not start listening on port $PORT."
        resetprop service.adb.tcp.port -1 >/dev/null 2>&1 || true
        stop adbd >/dev/null 2>&1 || true
        start adbd >/dev/null 2>&1 || true
        fw_remove
        return 1
    fi

    say "ADB TCP: ON"
    say "Tailscale only: $TSIP:$PORT"
    say "All non-$TSIF traffic to port $PORT is dropped."
}

finish_countdown() {
    say ""
    say "Closing in 3..."
    sleep 1
    say "Closing in 2..."
    sleep 1
    say "Closing in 1..."
    sleep 1
}

# Consider the module ON only when both the listener and our firewall are active.
# If ADB is already listening unsafely, pressing Action secures/enables it instead
# of interpreting that unsafe state as ON.
if is_listening && fw_active; then
    disable_tcp_adb
    RESULT=$?
else
    enable_tcp_adb
    RESULT=$?
fi

# Refresh the status line shown on the APatch module card for every outcome.
update_status

# Keep APatch's Action output visible after both success and error messages.
finish_countdown
exit "$RESULT"
