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
#
# Process starts cost tens of milliseconds on Android, and the WebUI polls the
# status, so the helpers below parse with shell builtins and set variables
# instead of piping through awk or sed.

NL='
'
PORT_HEX=15B3 # $PORT as it appears in /proc/net/tcp

valid_iface_name() {
    case "$1" in
        '' | *[!A-Za-z0-9._@-]*) return 1 ;;
    esac
    [ "${#1}" -le 15 ]
}

# Sets CONF_IFACE: "tailscale" (auto-detect) or a fixed interface name.
load_conf() {
    CONF_IFACE=$IFACE_AUTO
    [ -f "$CONF" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            IFACE=*) valid_iface_name "${line#IFACE=}" && CONF_IFACE=${line#IFACE=} ;;
        esac
    done < "$CONF"
}

conf_set_iface() {
    valid_iface_name "$1" || return 1
    echo "IFACE=$1" > "$CONF.tmp" && mv -f "$CONF.tmp" "$CONF"
}

# --- interfaces --------------------------------------------------------------

# Sets ADDRS to "name family address" lines for every non-loopback,
# non-link-local address.
load_addrs() {
    ADDRS=
    out="$(ip -o addr show 2>/dev/null)"
    set -f
    IFS=$NL
    for line in $out; do
        IFS=' 	'
        # shellcheck disable=SC2086
        set -- $line
        IFS=$NL
        [ "$2" = lo ] && continue
        case "$4" in fe80:* | FE80:*) continue ;; esac
        ADDRS="$ADDRS${2%%@*} $3 ${4%%/*}$NL"
    done
    unset IFS
    set +f
}

# Android names VPN interfaces tun0, tun1, ... in creation order, so Tailscale's
# name changes. Identify it by its address ranges instead: fd7a:115c:a1e0::/48 or
# 100.64.0.0/10 on a tun interface (carriers also hand out 100.64/10 on rmnet).
# Sets TS_IFACE.
find_tailscale() {
    TS_IFACE=
    set -f
    IFS=$NL
    for line in $ADDRS; do
        IFS=' '
        # shellcheck disable=SC2086
        set -- $line
        IFS=$NL
        case "$1" in tun*) ;; *) continue ;; esac
        case "$2 $3" in
            "inet6 fd7a:115c:a1e0:"* | "inet 100.6"[4-9].* | "inet 100."[7-9][0-9].* | \
            "inet 100.1"[01][0-9].* | "inet 100.12"[0-7].*)
                TS_IFACE=$1
                break
                ;;
        esac
    done
    unset IFS
    set +f
}

# Sets TARGET: the interface ADB should be restricted to now, empty if missing.
resolve_target() {
    TARGET=
    if [ "$CONF_IFACE" = "$IFACE_AUTO" ]; then
        TARGET=$TS_IFACE
    elif [ -e "/sys/class/net/$CONF_IFACE" ]; then
        TARGET=$CONF_IFACE
    fi
}

# Sets IFACE_IP to the address to connect to on $1: IPv4 first, then IPv6.
iface_ip() {
    IFACE_IP=
    want=$1
    set -f
    IFS=$NL
    for line in $ADDRS; do
        IFS=' '
        # shellcheck disable=SC2086
        set -- $line
        IFS=$NL
        [ "$1" = "$want" ] || continue
        if [ "$2" = inet ]; then IFACE_IP=$3; break; fi
        [ -z "$IFACE_IP" ] && IFACE_IP="[$3]"
    done
    unset IFS
    set +f
}

# --- adbd --------------------------------------------------------------------

is_listening() {
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] || continue
        while read -r _ local _ st _; do
            [ "$st" = 0A ] && case "$local" in *:"$PORT_HEX") return 0 ;; esac
        done < "$f"
    done
    return 1
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

# Sets FAMILY_IF to the interface our chain allows in one family, empty unless
# INPUT jumps to the chain and it holds exactly "ACCEPT on <iface>, DROP".
fw_family_iface() {
    FAMILY_IF=
    [ -n "$1" ] || return 0
    out="$("$1" -S 2>/dev/null)"
    jump='' rules=''
    set -f
    IFS=$NL
    for line in $out; do
        case "$line" in
            "-A INPUT -p tcp -m tcp --dport $PORT -j $CHAIN") jump=1 ;;
            "-A $CHAIN "*) rules="$rules${line#"-A $CHAIN "}$NL" ;;
        esac
    done
    unset IFS
    set +f
    [ -n "$jump" ] || return 0
    case "$rules" in
        "-i "*" -j ACCEPT$NL-j DROP$NL")
            FAMILY_IF=${rules#-i }
            FAMILY_IF=${FAMILY_IF%%" -j ACCEPT$NL"*}
            ;;
    esac
}

# Sets FWIF to the interface the firewall allows, empty unless IPv4 and IPv6 agree.
fw_iface() {
    fw_family_iface "$IPT"
    v4=$FAMILY_IF
    fw_family_iface "$IP6T"
    FWIF=
    [ -n "$v4" ] && [ "$v4" = "$FAMILY_IF" ] && FWIF=$v4
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

# Sets STATE (off | on | stale | exposed) plus CONF_IFACE, ADDRS, TS_IFACE,
# TARGET, FWIF and ADDR.
read_state() {
    load_conf
    load_addrs
    find_tailscale
    resolve_target
    FWIF='' ADDR=''
    if ! is_listening; then
        STATE=off
        return
    fi
    fw_iface
    if [ -z "$FWIF" ]; then
        STATE=exposed
    elif [ -n "$TARGET" ] && [ "$FWIF" = "$TARGET" ]; then
        STATE=on
        iface_ip "$TARGET"
        ADDR=$IFACE_IP
    else
        STATE=stale
    fi
}

iface_label() {
    if [ "$CONF_IFACE" = "$IFACE_AUTO" ]; then echo "Tailscale"; else echo "$CONF_IFACE"; fi
}

write_description() {
    prop="$MODDIR/module.prop"
    [ -f "$prop" ] || return 0
    awk -v d="$1" '/^description=/ { print "description=" d; next } { print }' \
        "$prop" > "$prop.tmp" && mv -f "$prop.tmp" "$prop"
}

update_status() {
    read_state
    label="$(iface_label)"
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

    read_state
    iface=$TARGET
    if [ -z "$iface" ]; then
        if [ "$CONF_IFACE" = "$IFACE_AUTO" ]; then
            echo "ERROR: no Tailscale interface found. Start Tailscale first."
        else
            echo "ERROR: interface $CONF_IFACE is not present."
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
    iface_ip "$iface"
    echo "Connect: adb connect $IFACE_IP:$PORT"
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
