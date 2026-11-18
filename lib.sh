#!/system/bin/sh
# Shared helpers. Source with MODDIR set to the module directory.

PORT=5555
CHAIN=ADBTCPTOGGLE
CONF=/data/adb/adb_tcp_toggle.conf
IFACE_AUTO=tailscale

# WebUI shells don't get the root manager's bin directory (resetprop) in PATH.
PATH="$PATH:/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk"

IPT="$(command -v iptables 2>/dev/null)"
IP6T="$(command -v ip6tables 2>/dev/null)"

# --- configuration -----------------------------------------------------------

# Configured interface: "tailscale" (auto-detect) or a fixed interface name.
conf_iface() {
    v=
    [ -f "$CONF" ] && v="$(sed -n 's/^IFACE=//p' "$CONF" | head -n 1)"
    valid_iface_name "$v" && echo "$v" || echo "$IFACE_AUTO"
}

valid_iface_name() {
    case "$1" in
        '' | *[!A-Za-z0-9._@-]*) return 1 ;;
    esac
    [ "${#1}" -le 15 ]
}

conf_set_iface() {
    valid_iface_name "$1" || return 1
    echo "IFACE=$1" > "$CONF.tmp" && mv -f "$CONF.tmp" "$CONF"
}

# --- interfaces --------------------------------------------------------------

# Prints "name family address" for every non-loopback, non-link-local address.
iface_addrs() {
    ip -o addr show 2>/dev/null |
        awk '$2 != "lo" && tolower($4) !~ /^fe80:/ { sub(/\/.*/, "", $4); sub(/@.*/, "", $2); print $2, $3, $4 }'
}

# Android names VPN interfaces tun0, tun1, ... in creation order, so Tailscale's
# name changes. Identify it by its address ranges instead: fd7a:115c:a1e0::/48 or
# 100.64.0.0/10 on a tun interface (carriers also hand out 100.64/10 on rmnet).
tailscale_iface() {
    iface_addrs | awk '
        $1 !~ /^tun/ { next }
        $2 == "inet6" && tolower($3) ~ /^fd7a:115c:a1e0:/ { print $1; exit }
        $2 == "inet" {
            split($3, o, ".")
            if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) { print $1; exit }
        }'
}

# Interface ADB should be restricted to right now, empty if unavailable.
target_iface() {
    c="$(conf_iface)"
    if [ "$c" = "$IFACE_AUTO" ]; then
        tailscale_iface
    elif ip link show dev "$c" >/dev/null 2>&1; then
        echo "$c"
    fi
}

# Preferred address to connect to: IPv4 first, then IPv6.
iface_ip() {
    iface_addrs | awk -v i="$1" '
        $1 != i { next }
        $2 == "inet" { print $3; found = 1; exit }
        $2 == "inet6" && v6 == "" { v6 = $3 }
        END { if (!found && v6 != "") print "[" v6 "]" }'
}

# --- adbd --------------------------------------------------------------------

is_listening() {
    ss -lnt 2>/dev/null | awk -v p=":$PORT" '$4 ~ p "$" { f = 1 } END { exit !f }'
}

# Waits up to ~5 s for the listener to reach the wanted state (0 or 1).
wait_listening() {
    i=0
    while [ "$i" -lt 25 ]; do
        if is_listening; then [ "$1" = 1 ] && return 0
        else [ "$1" = 0 ] && return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

restart_adbd() {
    stop adbd
    start adbd
}

# --- firewall ----------------------------------------------------------------

# Interface allowed by our chain in one family, empty if the chain is incomplete.
fw_family_iface() {
    [ -n "$1" ] || return 0
    "$1" -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null || return 0
    "$1" -S "$CHAIN" 2>/dev/null | awk -v c="$CHAIN" '
        $0 == "-A " c " -j DROP" { drop = NR }
        $1 == "-A" && $3 == "-i" && $5 == "-j" && $6 == "ACCEPT" && NF == 6 { acc = NR; i = $4 }
        END { if (acc && drop > acc) print i }'
}

# Interface the firewall allows, empty unless IPv4 and IPv6 agree.
fw_iface() {
    v4="$(fw_family_iface "$IPT")"
    v6="$(fw_family_iface "$IP6T")"
    [ -n "$v4" ] && [ "$v4" = "$v6" ] && echo "$v4"
}

fw_family_remove() {
    [ -n "$1" ] || return 0
    while "$1" -D INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null; do :; done
    "$1" -F "$CHAIN" 2>/dev/null
    "$1" -X "$CHAIN" 2>/dev/null
    return 0
}

fw_remove() {
    fw_family_remove "$IPT"
    fw_family_remove "$IP6T"
}

# Rebuilds the chain without ever leaving it empty, so switching interfaces while
# adbd listens never exposes the port.
fw_family_apply() {
    "$1" -N "$CHAIN" 2>/dev/null
    "$1" -I "$CHAIN" 1 -j DROP || return 1
    while "$1" -D "$CHAIN" 2 2>/dev/null; do :; done
    "$1" -I "$CHAIN" 1 -i "$2" -j ACCEPT || return 1
    "$1" -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null ||
        "$1" -I INPUT 1 -p tcp --dport "$PORT" -j "$CHAIN"
}

fw_apply() {
    fw_family_apply "$IPT" "$1" && fw_family_apply "$IP6T" "$1"
}

# --- state -------------------------------------------------------------------

# Sets STATE (off | on | stale | exposed), TARGET, FWIF and ADDR.
read_state() {
    TARGET="$(target_iface)"
    FWIF="$(fw_iface)"
    ADDR=
    if ! is_listening; then
        STATE=off
    elif [ -z "$FWIF" ]; then
        STATE=exposed
    elif [ -n "$TARGET" ] && [ "$FWIF" = "$TARGET" ]; then
        STATE=on
        ADDR="$(iface_ip "$TARGET")"
    else
        STATE=stale
    fi
}

iface_label() {
    if [ "$1" = "$IFACE_AUTO" ]; then echo "Tailscale"; else echo "$1"; fi
}

write_description() {
    prop="$MODDIR/module.prop"
    [ -f "$prop" ] || return 0
    awk -v d="$1" '/^description=/ { print "description=" d; next } { print }' \
        "$prop" > "$prop.tmp" && mv -f "$prop.tmp" "$prop"
}

update_status() {
    read_state
    label="$(iface_label "$(conf_iface)")"
    case "$STATE" in
        on) write_description "✅ ADB TCP on, $label only: ${ADDR:-$TARGET}:$PORT" ;;
        off) write_description "❌ ADB TCP off. Action enables it on $label." ;;
        stale)
            if [ -n "$TARGET" ]; then
                write_description "⚠️ ADB TCP on, but firewalled to $FWIF while $label is $TARGET. Action re-applies."
            else
                write_description "⚠️ ADB TCP on, but $label is unavailable, so it can't be reached. Action disables it."
            fi ;;
        exposed)
            if [ -n "$TARGET" ]; then
                write_description "🚨 ADB TCP on port $PORT without firewall! Action restricts it to $label."
            else
                write_description "🚨 ADB TCP on port $PORT without firewall! Action disables it."
            fi ;;
    esac
}

# --- actions -----------------------------------------------------------------

enable_tcp_adb() {
    if [ -z "$IPT" ] || [ -z "$IP6T" ]; then
        echo "ERROR: iptables/ip6tables not found. ADB TCP was NOT enabled."
        return 1
    fi

    c="$(conf_iface)"
    iface="$(target_iface)"
    if [ -z "$iface" ]; then
        if [ "$c" = "$IFACE_AUTO" ]; then
            echo "ERROR: no Tailscale interface found. Start Tailscale first."
        else
            echo "ERROR: interface $c is not present."
        fi
        echo "ADB TCP was NOT enabled."
        return 1
    fi

    if ! fw_apply "$iface"; then
        echo "ERROR: could not install IPv4 and IPv6 firewall rules."
        is_listening || fw_remove
        echo "ADB TCP was NOT enabled."
        return 1
    fi

    # Session only: a reboot turns it off.
    resetprop -p --delete persist.adb.tcp.port >/dev/null 2>&1
    if ! is_listening; then
        if ! resetprop service.adb.tcp.port "$PORT"; then
            echo "ERROR: could not set service.adb.tcp.port."
            fw_remove
            return 1
        fi
        restart_adbd
        if ! wait_listening 1; then
            echo "ERROR: adbd did not start listening on port $PORT."
            resetprop service.adb.tcp.port -1 >/dev/null 2>&1
            restart_adbd
            wait_listening 0 && fw_remove
            return 1
        fi
    fi

    echo "ADB TCP: ON, only via $iface"
    echo "Connect: adb connect $(iface_ip "$iface"):$PORT"
}

disable_tcp_adb() {
    resetprop -p --delete persist.adb.tcp.port >/dev/null 2>&1
    if ! resetprop service.adb.tcp.port -1; then
        echo "ERROR: could not change service.adb.tcp.port. Firewall left in place."
        return 1
    fi
    restart_adbd
    if ! wait_listening 0; then
        echo "ERROR: adbd still listens on port $PORT. Firewall left in place."
        return 1
    fi
    fw_remove
    echo "ADB TCP: OFF (USB ADB is unaffected)"
}

# Off enables and on disables. A stale or exposed listener is re-firewalled
# when the selected interface exists, and disabled otherwise.
toggle_tcp_adb() {
    read_state
    case "$STATE" in
        off) enable_tcp_adb ;;
        on) disable_tcp_adb ;;
        *) if [ -n "$TARGET" ]; then enable_tcp_adb; else disable_tcp_adb; fi ;;
    esac
}
