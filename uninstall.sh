#!/usr/bin/env bash
set -Eeuo pipefail

WG_ROOT="/etc/wireguard"
STATE_DIR="$WG_ROOT/wg-vpn"
CONFIG="$STATE_DIR/config.env"
STATE="$STATE_DIR/state.env"
LIB_DIR="/usr/local/lib/wg-vpn"

die() { echo "wg-vpn uninstall: $*" >&2; exit 1; }
prompt_yes_no() {
    local answer=""
    if [ -r /dev/tty ]; then
        printf 'Remove wg-vpn configuration and clients? (y/N): ' > /dev/tty
        IFS= read -r answer < /dev/tty || true
    fi
    [[ "$answer" =~ ^[Yy]$ ]]
}

[ "$(id -u)" -eq 0 ] || die "Run this script as root."

[ -f "$CONFIG" ] || die "wg-vpn configuration was not found."
source "$CONFIG"
[ ! -f "$STATE" ] || source "$STATE"

if [ "${1:-}" != "--yes" ] && ! prompt_yes_no; then
    echo "Uninstall cancelled."
    exit 0
fi

if [ -f "$LIB_DIR/common.sh" ]; then
    source "$LIB_DIR/common.sh"
    source "$LIB_DIR/networking.sh"
    source "$LIB_DIR/firewall.sh"
    firewall_remove || true
else
    /usr/local/bin/wg-vpn firewall-remove 2>/dev/null || true
fi

systemctl disable --now wg-vpn-firewall.service 2>/dev/null || true
systemctl disable --now "wg-quick@$WG_INTERFACE" 2>/dev/null || true
rm -f /etc/systemd/system/wg-vpn-firewall.service
systemctl daemon-reload

rm -f "$WG_ROOT/${WG_INTERFACE}.conf"
rm -rf "$WG_ROOT/clients" "$STATE_DIR"

rm -f /etc/sysctl.d/99-wg-vpn.conf
sysctl --system >/dev/null 2>&1 || true

if [ "${PREVIOUS_IPV4_FORWARD:-0}" = "0" ]; then
    other_ipv4="$(grep -RhsE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d 2>/dev/null | head -1 || true)"
    [ -n "$other_ipv4" ] || sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
else
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
fi

if [ "${PREVIOUS_IPV6_FORWARD:-0}" = "0" ]; then
    other_ipv6="$(grep -RhsE '^[[:space:]]*net\.ipv6\.conf\.all\.forwarding[[:space:]]*=[[:space:]]*1' /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d 2>/dev/null | head -1 || true)"
    [ -n "$other_ipv6" ] || sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
else
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
fi

rm -f /usr/local/bin/wg-vpn
rm -rf "$LIB_DIR"
rmdir "$WG_ROOT" 2>/dev/null || true

echo "wg-vpn removed."
echo "WireGuard/qrencode/iptables packages were left installed intentionally."
