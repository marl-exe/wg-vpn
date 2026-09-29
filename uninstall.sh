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
        IFS= read -r answer < /dev/tty || die "Input ended unexpectedly."
    else
        printf 'Remove wg-vpn configuration and clients? (y/N): ' >&2
        IFS= read -r answer || die "Interactive input is required. Use --yes for non-interactive uninstall."
    fi
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

[ "$(id -u)" -eq 0 ] || die "Run this script as root."
[ -f "$CONFIG" ] || die "wg-vpn configuration was not found."
[ -f "$LIB_DIR/common.sh" ] || die "wg-vpn libraries are missing; refusing an unsafe partial uninstall."

# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/networking.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/firewall.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/clients.sh"

require_root
acquire_lock
try_load_config || die "Invalid or unsafe wg-vpn configuration/state metadata."

if [ "${1:-}" != "--yes" ] && ! prompt_yes_no; then
    echo "Uninstall cancelled."
    exit 0
fi

firewall_remove || true

if [ -e "$WGVPN_FIREWALL_SERVICE_FILE" ] || [ -L "$WGVPN_FIREWALL_SERVICE_FILE" ]; then
    if firewall_service_owned; then
        systemctl disable --now wg-vpn-firewall.service 2>/dev/null || true
        rm -f "$WGVPN_FIREWALL_SERVICE_FILE"
        systemctl daemon-reload
    else
        echo "WARNING: refusing to disable/remove unowned systemd unit: $WGVPN_FIREWALL_SERVICE_FILE" >&2
    fi
fi

systemctl disable --now "wg-quick@$WG_INTERFACE" 2>/dev/null || true

for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
    [ -e "$meta" ] || continue
    unset CLIENT_NAME
    load_client_meta_file "$meta" || die "Invalid client metadata: $meta"
    valid_client_name "$CLIENT_NAME" || die "Invalid client name in metadata: $meta"
    rm -f -- "$(client_config_file "$CLIENT_NAME")"
done

rm -f -- "$WG_ROOT/${WG_INTERFACE}.conf"
rm -rf -- "$STATE_DIR"
rmdir "$WGVPN_CLIENT_CONFIG_DIR" 2>/dev/null || true

if [ -e "$WGVPN_SYSCTL_FILE" ] || [ -L "$WGVPN_SYSCTL_FILE" ]; then
    if sysctl_file_owned; then
        rm -f "$WGVPN_SYSCTL_FILE"
    else
        echo "WARNING: refusing to remove unowned sysctl file: $WGVPN_SYSCTL_FILE" >&2
    fi
fi

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
rm -rf -- "$LIB_DIR"
rmdir "$WG_ROOT" 2>/dev/null || true

echo "wg-vpn removed."
echo "Unrelated WireGuard configurations and client files were preserved."
echo "WireGuard/qrencode/iptables packages were left installed intentionally."
