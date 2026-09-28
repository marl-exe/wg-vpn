#!/usr/bin/env bash

detect_public_interface() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{
        for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}
    }'
}

detect_source_ipv4() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{
        for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}
    }'
}

detect_interface_ipv6() {
    local iface="$1"
    ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -1
}

working_ipv6() {
    local iface="$1"
    [ -n "$(detect_interface_ipv6 "$iface")" ] && ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1
}

interface_mtu() {
    local iface="$1"
    ip link show dev "$iface" 2>/dev/null | awk '{
        for (i=1; i<=NF; i++) if ($i=="mtu") {print $(i+1); exit}
    }'
}

subnet_conflicts() {
    ip -4 route show | grep -Fq "$1"
}

udp_port_in_use() {
    local port="$1"
    ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
}

record_forwarding_state() {
    write_env_file "$WGVPN_STATE"         "PREVIOUS_IPV4_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"         "PREVIOUS_IPV6_FORWARD=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)"
}

enable_forwarding() {
    cat > /etc/sysctl.d/99-wg-vpn.conf <<EOF
# Managed by wg-vpn
net.ipv4.ip_forward=1
EOF
    if [ "${IPV6_ENABLED:-0}" = "1" ]; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-wg-vpn.conf
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    if [ "${IPV6_ENABLED:-0}" = "1" ]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    fi
}

restore_forwarding() {
    rm -f /etc/sysctl.d/99-wg-vpn.conf
    sysctl --system >/dev/null 2>&1 || true
    if [ "${PREVIOUS_IPV4_FORWARD:-0}" = "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    fi
    if [ "${PREVIOUS_IPV6_FORWARD:-0}" = "1" ]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    fi
}
