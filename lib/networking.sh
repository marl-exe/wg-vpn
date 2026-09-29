#!/usr/bin/env bash

WGVPN_SYSCTL_FILE="/etc/sysctl.d/99-wg-vpn.conf"
WGVPN_FIREWALL_SERVICE_FILE="/etc/systemd/system/wg-vpn-firewall.service"

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
    [ -n "$(detect_interface_ipv6 "$iface")" ] &&
        ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1
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

detect_virtualization() {
    local virt=""
    if command_exists systemd-detect-virt; then
        virt="$(systemd-detect-virt 2>/dev/null || true)"
    fi
    [ -n "$virt" ] && echo "$virt" || echo "unknown"
}

tun_device_status() {
    if [ -c /dev/net/tun ]; then
        echo "available"
    else
        echo "not present"
    fi
}

wireguard_interface_probe() {
    local probe="wgp$$"
    probe="${probe:0:15}"

    if ip link add dev "$probe" type wireguard >/dev/null 2>&1; then
        ip link del dev "$probe" >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

render_forwarding_sysctl() {
    echo "# Managed by wg-vpn"
    echo "net.ipv4.ip_forward=1"
    if [ "${IPV6_ENABLED:-0}" = "1" ]; then
        echo "net.ipv6.conf.all.forwarding=1"
    fi
}

sysctl_file_owned() {
    [ -f "$WGVPN_SYSCTL_FILE" ] && [ ! -L "$WGVPN_SYSCTL_FILE" ] || return 1
    cmp -s "$WGVPN_SYSCTL_FILE" <(render_forwarding_sysctl)
}

render_firewall_service_unit() {
    cat <<'EOF'
[Unit]
Description=wg-vpn firewall and NAT rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-vpn firewall-apply
ExecStop=/usr/local/bin/wg-vpn firewall-remove
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

firewall_service_owned() {
    [ -f "$WGVPN_FIREWALL_SERVICE_FILE" ] && [ ! -L "$WGVPN_FIREWALL_SERVICE_FILE" ] || return 1
    cmp -s "$WGVPN_FIREWALL_SERVICE_FILE" <(render_firewall_service_unit)
}

install_firewall_service_unit() {
    local tmp
    if [ -e "$WGVPN_FIREWALL_SERVICE_FILE" ] || [ -L "$WGVPN_FIREWALL_SERVICE_FILE" ]; then
        firewall_service_owned || die "Refusing to overwrite unowned systemd unit: $WGVPN_FIREWALL_SERVICE_FILE"
        return 0
    fi

    tmp="$(mktemp /etc/systemd/system/.wg-vpn-firewall.service.XXXXXX)"
    render_firewall_service_unit > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$WGVPN_FIREWALL_SERVICE_FILE"
}

enable_forwarding() {
    local tmp
    if [ -e "$WGVPN_SYSCTL_FILE" ] || [ -L "$WGVPN_SYSCTL_FILE" ]; then
        sysctl_file_owned || die "Refusing to overwrite unowned sysctl file: $WGVPN_SYSCTL_FILE"
    else
        tmp="$(mktemp /etc/sysctl.d/.99-wg-vpn.conf.XXXXXX)"
        render_forwarding_sysctl > "$tmp"
        chmod 644 "$tmp"
        mv -f "$tmp" "$WGVPN_SYSCTL_FILE"
    fi

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    if [ "${IPV6_ENABLED:-0}" = "1" ]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    fi
}

restore_forwarding() {
    if [ -e "$WGVPN_SYSCTL_FILE" ] || [ -L "$WGVPN_SYSCTL_FILE" ]; then
        if sysctl_file_owned; then
            rm -f "$WGVPN_SYSCTL_FILE"
        else
            warn "Refusing to remove unowned sysctl file: $WGVPN_SYSCTL_FILE"
        fi
    fi

    sysctl --system >/dev/null 2>&1 || true
    if [ "${PREVIOUS_IPV4_FORWARD:-0}" = "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    fi
    if [ "${PREVIOUS_IPV6_FORWARD:-0}" = "1" ]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    fi
}
