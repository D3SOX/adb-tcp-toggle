#!/system/bin/sh

# Shared status helper for the APatch module.
# This file only reads state and updates module.prop; it never starts/stops ADB
# and never changes firewall rules.

MODDIR=${MODDIR:-${0%/*}}
PORT=5555
TSIF=tun0
CHAIN=ADBTAILSCALE

IPT="$(command -v iptables 2>/dev/null)"
IP6T="$(command -v ip6tables 2>/dev/null)"

is_listening() {
    ss -lnt 2>/dev/null | grep -q ":${PORT}[[:space:]]"
}

fw_family_active() {
    cmd="$1"
    [ -n "$cmd" ] || return 1

    "$cmd" -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null &&
    "$cmd" -C "$CHAIN" -i "$TSIF" -j ACCEPT 2>/dev/null &&
    "$cmd" -C "$CHAIN" -j DROP 2>/dev/null
}

fw_active() {
    fw_family_active "$IPT" && fw_family_active "$IP6T"
}

tailscale_ip() {
    ip -o -4 addr show dev "$TSIF" 2>/dev/null |
        awk '$4 ~ /^100\./ {sub(/\/.*/, "", $4); print $4; exit}'
}

write_description() {
    desc="$1"
    prop="$MODDIR/module.prop"
    tmp="$MODDIR/.module.prop.tmp.$$"
    found=0

    [ -f "$prop" ] || return 0

    : > "$tmp" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            description=*)
                printf 'description=%s\n' "$desc" >> "$tmp"
                found=1
                ;;
            *)
                printf '%s\n' "$line" >> "$tmp"
                ;;
        esac
    done < "$prop"

    if [ "$found" -eq 0 ]; then
        printf 'description=%s\n' "$desc" >> "$tmp"
    fi

    mv -f "$tmp" "$prop"
    chmod 0644 "$prop" 2>/dev/null || true
}

update_status() {
    TSIP="$(tailscale_ip)"

    if is_listening; then
        if fw_active; then
            if [ -n "$TSIP" ]; then
                write_description "[ADB TCP: ✅ ON, Firewall: ✅ Tailscale-only] ${TSIP}:${PORT} · Tap Action to disable."
            else
                write_description "[ADB TCP: ✅ ON, Firewall: ✅ Tailscale-only, Tailscale: ❌] Safe but unreachable until tun0 reconnects."
            fi
        else
            write_description "[ADB TCP: ⚠️ ON, Firewall: ❌ INCOMPLETE] Port ${PORT} is not fully restricted to Tailscale · Tap Action to repair."
        fi
    else
        write_description "[ADB TCP: ❌ OFF] Tap Action to enable on Tailscale only."
    fi
}
