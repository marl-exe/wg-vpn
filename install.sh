#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW="${WGVPN_REPO_RAW:-https://raw.githubusercontent.com/marl-exe/wg-vpn/main}"
INSTALL_LIB="/usr/local/lib/wg-vpn"
INSTALL_BIN="/usr/local/bin/wg-vpn"
WG_ROOT="/etc/wireguard"
STATE_DIR="$WG_ROOT/wg-vpn"

die() { echo "wg-vpn installer: $*" >&2; exit 1; }

INSTALL_PROMPT_RESULT=""

ask() {
    local label="$1" default="${2:-}" value=""

    if [ -r /dev/tty ]; then
        if [ -n "$default" ]; then
            printf '%s [%s]: ' "$label" "$default" > /dev/tty
        else
            printf '%s: ' "$label" > /dev/tty
        fi
        IFS= read -r value < /dev/tty || value=""
    else
        if [ -n "$default" ]; then
            printf '%s [%s]: ' "$label" "$default" >&2
        else
            printf '%s: ' "$label" >&2
        fi
        IFS= read -r value || value=""
    fi

    INSTALL_PROMPT_RESULT="${value:-$default}"
}

yesno() {
    local label="$1" default="${2:-y}" value

    if [ "$default" = "y" ]; then
        ask "$label (Y/n)" ""
        value="$INSTALL_PROMPT_RESULT"
        [ -n "$value" ] || value="y"
    else
        ask "$label (y/N)" ""
        value="$INSTALL_PROMPT_RESULT"
        [ -n "$value" ] || value="n"
    fi

    [[ "$value" =~ ^[Yy]$ ]]
}
command_exists() { command -v "$1" >/dev/null 2>&1; }

is_private_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] ||
    [[ "$ip" =~ ^192\.168\. ]] ||
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\.]]
}

choose_wg_interface() {
    local name
    for name in wg0 wg1 wg2 wg3 wg4 wg5 wg6 wg7 wg8 wg9; do
        if [ ! -e "$WG_ROOT/${name}.conf" ] && ! ip link show "$name" >/dev/null 2>&1; then
            echo "$name"
            return 0
        fi
    done
    return 1
}

choose_ipv4_subnet() {
    local subnet
    for subnet in         10.66.66.0/24         10.77.77.0/24         10.88.88.0/24         10.99.99.0/24         10.100.100.0/24; do
        if ! subnet_conflicts "$subnet"; then
            echo "$subnet"
            return 0
        fi
    done
    return 1
}

choose_udp_port() {
    local port attempt
    port=51820
    if ! udp_port_in_use "$port"; then
        echo "$port"
        return 0
    fi

    for attempt in $(seq 1 20); do
        port="$(random_port)"
        if ! udp_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

detect_endpoint() {
    local source_ip public_ip=""
    source_ip="$(detect_source_ipv4)"

    if [ -n "$source_ip" ] && ! is_private_ipv4 "$source_ip"; then
        echo "$source_ip"
        return 0
    fi

    public_ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [ -n "$public_ip" ]; then
        echo "$public_ip"
        return 0
    fi

    return 1
}

[ "$(id -u)" -eq 0 ] || die "Run as root: curl ... | sudo bash"
command_exists systemctl || die "systemd is required for V1."

[ -r /etc/os-release ] || die "Cannot detect operating system."
source /etc/os-release
case "$ID" in
    ubuntu|debian) ;;
    *) die "V1 supports Ubuntu and Debian only. Detected: $ID" ;;
esac

if [ -f "$STATE_DIR/config.env" ]; then
    echo "wg-vpn existing installation detected."
    echo "Updating CLI and management modules only..."
    echo

    mkdir -p "$INSTALL_LIB"

    for file in common.sh config.sh networking.sh firewall.sh clients.sh mtu.sh backup.sh; do
        curl -fsSL "$REPO_RAW/lib/$file" -o "$INSTALL_LIB/$file"
        chmod 755 "$INSTALL_LIB/$file"
    done

    curl -fsSL "$REPO_RAW/bin/wg-vpn" -o "$INSTALL_BIN"
    chmod 755 "$INSTALL_BIN"

    echo "wg-vpn management files updated."
    echo "Existing server keys, clients, WireGuard configuration, firewall settings, and VPN addresses were not replaced."
    echo
    "$INSTALL_BIN" status
    exit 0
fi

echo "wg-vpn installer"
echo
echo "This installs native WireGuard and a CLI manager."
echo "It does not install Docker, Node.js, Python, a database, or a Web UI."
echo "Existing firewall tables/chains are never flushed."
echo
echo "Setup mode:"
echo
echo "  1) Automatic (recommended)"
echo "  2) Manual / Advanced"
echo

ask "Mode" "1"
setup_choice="$INSTALL_PROMPT_RESULT"
case "$setup_choice" in
    2|manual|advanced) SETUP_MODE="manual" ;;
    *) SETUP_MODE="automatic" ;;
esac

echo
echo "Installing required packages..."
echo

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends     wireguard     wireguard-tools     qrencode     iptables     iproute2     ca-certificates     curl

mkdir -p "$INSTALL_LIB" "$WG_ROOT"
chmod 700 "$WG_ROOT"

for file in common.sh config.sh networking.sh firewall.sh clients.sh mtu.sh backup.sh; do
    curl -fsSL "$REPO_RAW/lib/$file" -o "$INSTALL_LIB/$file"
    chmod 755 "$INSTALL_LIB/$file"
done

curl -fsSL "$REPO_RAW/bin/wg-vpn" -o "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"

source "$INSTALL_LIB/common.sh"
source "$INSTALL_LIB/config.sh"
source "$INSTALL_LIB/networking.sh"
source "$INSTALL_LIB/firewall.sh"

VIRTUALIZATION="$(detect_virtualization)"
TUN_STATUS="$(tun_device_status)"

command_exists modprobe && modprobe wireguard >/dev/null 2>&1 || true

echo
echo "Environment:"
echo
echo "  Virtualization:     $VIRTUALIZATION"
echo "  TUN/TAP device:     $TUN_STATUS"

if wireguard_interface_probe; then
    echo "  Native WireGuard:   available"
else
    echo "  Native WireGuard:   unavailable"
    echo
    if [[ "$VIRTUALIZATION" =~ ^(lxc|lxc-libvirt|openvz|docker|podman|container-other)$ ]]; then
        die "This container cannot create a WireGuard interface. The host may need to provide WireGuard kernel support and allow the required network capabilities."
    fi
    die "This system cannot create a native WireGuard interface. Check kernel WireGuard support and network capabilities."
fi

echo
echo "Detecting network configuration..."
echo

DETECTED_PUBLIC_INTERFACE="$(detect_public_interface || true)"
DETECTED_WG_INTERFACE="$(choose_wg_interface || true)"
DETECTED_IPV4_SUBNET="$(choose_ipv4_subnet || true)"
DETECTED_PORT="$(choose_udp_port || true)"
DETECTED_ENDPOINT="$(detect_endpoint || true)"

if [ "$SETUP_MODE" = "manual" ]; then
    echo "Manual / Advanced configuration"
    echo "Detected values are shown as defaults. Press Enter to keep a value."
    echo

    ask "Public interface" "$DETECTED_PUBLIC_INTERFACE"
    PUBLIC_INTERFACE="$INSTALL_PROMPT_RESULT"
    [ -n "$PUBLIC_INTERFACE" ] || die "A public network interface is required."
    ip link show dev "$PUBLIC_INTERFACE" >/dev/null 2>&1 || die "Interface $PUBLIC_INTERFACE does not exist."

    ask "WireGuard interface" "${DETECTED_WG_INTERFACE:-wg0}"
    WG_INTERFACE="$INSTALL_PROMPT_RESULT"
    valid_interface_name "$WG_INTERFACE" || die "Invalid WireGuard interface name."
    [ ! -e "$WG_ROOT/${WG_INTERFACE}.conf" ] || die "$WG_ROOT/${WG_INTERFACE}.conf already exists. Refusing to overwrite it."
    ip link show "$WG_INTERFACE" >/dev/null 2>&1 && die "Interface $WG_INTERFACE already exists. Refusing to take it over."

    ask "VPN IPv4 subnet (/24)" "${DETECTED_IPV4_SUBNET:-10.66.66.0/24}"
    WG_IPV4_SUBNET="$INSTALL_PROMPT_RESULT"
    valid_ipv4_24_cidr "$WG_IPV4_SUBNET" || die "V1 currently requires a valid IPv4 /24 subnet."
    subnet_conflicts "$WG_IPV4_SUBNET" && die "$WG_IPV4_SUBNET already appears in the routing table."

    ask "WireGuard UDP port" "${DETECTED_PORT:-51820}"
    WG_PORT="$INSTALL_PROMPT_RESULT"
    valid_port "$WG_PORT" || die "Invalid UDP port."
    udp_port_in_use "$WG_PORT" && die "UDP port $WG_PORT is already in use."

    ask "Public IP or DNS name" "$DETECTED_ENDPOINT"
    ENDPOINT_HOST="$INSTALL_PROMPT_RESULT"
    [ -n "$ENDPOINT_HOST" ] || die "A public IP or DNS endpoint is required."

    ask "MTU (automatic or number)" "automatic"
    mtu_input="$INSTALL_PROMPT_RESULT"
    case "$mtu_input" in
        automatic|auto|"") FORCED_MTU="" ;;
        *)
            [[ "$mtu_input" =~ ^[0-9]+$ ]] || die "MTU must be 'automatic' or a number."
            [ "$mtu_input" -ge 1280 ] && [ "$mtu_input" -le 9000 ] || die "MTU must be between 1280 and 9000."
            FORCED_MTU="$mtu_input"
            ;;
    esac
else
    PUBLIC_INTERFACE="$DETECTED_PUBLIC_INTERFACE"
    if [ -z "$PUBLIC_INTERFACE" ]; then
        ask "Could not auto-detect the public interface. Enter interface name" ""
        PUBLIC_INTERFACE="$INSTALL_PROMPT_RESULT"
    fi
    [ -n "$PUBLIC_INTERFACE" ] || die "A public network interface is required."
    ip link show dev "$PUBLIC_INTERFACE" >/dev/null 2>&1 || die "Interface $PUBLIC_INTERFACE does not exist."

    WG_INTERFACE="$DETECTED_WG_INTERFACE"
    if [ -z "$WG_INTERFACE" ]; then
        ask "Could not find a free wg0-wg9 interface. Enter WireGuard interface" "wg-vpn0"
        WG_INTERFACE="$INSTALL_PROMPT_RESULT"
    fi
    valid_interface_name "$WG_INTERFACE" || die "Invalid WireGuard interface name."

    WG_IPV4_SUBNET="$DETECTED_IPV4_SUBNET"
    if [ -z "$WG_IPV4_SUBNET" ]; then
        ask "Could not find a free default VPN subnet. Enter IPv4 /24 subnet" "10.66.66.0/24"
        WG_IPV4_SUBNET="$INSTALL_PROMPT_RESULT"
    fi
    valid_ipv4_24_cidr "$WG_IPV4_SUBNET" || die "V1 currently requires a valid IPv4 /24 subnet."

    WG_PORT="$DETECTED_PORT"
    if [ -z "$WG_PORT" ]; then
        ask "Could not find a free UDP port. Enter WireGuard port" "51820"
        WG_PORT="$INSTALL_PROMPT_RESULT"
    fi
    valid_port "$WG_PORT" || die "Invalid UDP port."

    ENDPOINT_HOST="$DETECTED_ENDPOINT"
    if [ -z "$ENDPOINT_HOST" ]; then
        ask "Could not auto-detect the public IP. Enter public IP or DNS name" ""
        ENDPOINT_HOST="$INSTALL_PROMPT_RESULT"
    fi
    [ -n "$ENDPOINT_HOST" ] || die "A public IP or DNS endpoint is required."

    FORCED_MTU=""
fi

WG_SERVER_IPV4="$(ipv4_prefix_from_cidr "$WG_IPV4_SUBNET").1"

echo "  Public interface:    $PUBLIC_INTERFACE"
echo "  WireGuard interface: $WG_INTERFACE"
echo "  VPN subnet:          $WG_IPV4_SUBNET"
echo "  WireGuard port:      $WG_PORT/UDP"
echo "  Public endpoint:     $ENDPOINT_HOST"
echo "  MTU:                 ${FORCED_MTU:-automatic}"

IPV6_ENABLED=0
WG_IPV6_PREFIX="fd66:66:66"
WG_IPV6_SUBNET="${WG_IPV6_PREFIX}::/64"
WG_SERVER_IPV6="${WG_IPV6_PREFIX}::1"

if working_ipv6 "$PUBLIC_INTERFACE"; then
    echo "  Public IPv6:         detected"
    if yesno "Enable IPv6 for VPN clients?" "n"; then
        IPV6_ENABLED=1
    fi
else
    echo "  Public IPv6:         not detected"
fi

prompt_dns
DEFAULT_DNS="$DNS_RESULT"
prompt_routing "full"
DEFAULT_ROUTE_MODE="$ROUTE_MODE_RESULT"
DEFAULT_CUSTOM_ROUTES="$ROUTE_CUSTOM_RESULT"

echo
echo "Configuration:"
echo
echo "  Setup mode:          $SETUP_MODE"
echo "  Virtualization:      $VIRTUALIZATION"
echo "  Public interface:    $PUBLIC_INTERFACE"
echo "  Public endpoint:     $ENDPOINT_HOST:$WG_PORT"
echo "  WireGuard interface: $WG_INTERFACE"
echo "  VPN subnet:          $WG_IPV4_SUBNET"
echo "  DNS:                 $DEFAULT_DNS"
echo "  Routing:             $DEFAULT_ROUTE_MODE"
echo "  IPv6:                $([ "$IPV6_ENABLED" = "1" ] && echo enabled || echo disabled)"
echo "  MTU:                 ${FORCED_MTU:-automatic}"
echo

safe_mkdirs

PREVIOUS_IPV4_FORWARD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
PREVIOUS_IPV6_FORWARD="$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)"

write_env_file "$WGVPN_STATE"     "PREVIOUS_IPV4_FORWARD=$PREVIOUS_IPV4_FORWARD"     "PREVIOUS_IPV6_FORWARD=$PREVIOUS_IPV6_FORWARD"     "VIRTUALIZATION=$VIRTUALIZATION"     "TUN_STATUS=$TUN_STATUS"

SERVER_PRIVATE_KEY="$(wg genkey)"
SERVER_PUBLIC_KEY="$(printf '%s' "$SERVER_PRIVATE_KEY" | wg pubkey)"

write_env_file "$WGVPN_CONFIG"     "WG_INTERFACE=$WG_INTERFACE"     "WG_IPV4_SUBNET=$WG_IPV4_SUBNET"     "WG_SERVER_IPV4=$WG_SERVER_IPV4"     "WG_PORT=$WG_PORT"     "PUBLIC_INTERFACE=$PUBLIC_INTERFACE"     "ENDPOINT_HOST=$ENDPOINT_HOST"     "SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY"     "IPV6_ENABLED=$IPV6_ENABLED"     "WG_IPV6_PREFIX=$WG_IPV6_PREFIX"     "WG_IPV6_SUBNET=$WG_IPV6_SUBNET"     "WG_SERVER_IPV6=$WG_SERVER_IPV6"     "DEFAULT_DNS=$DEFAULT_DNS"     "DEFAULT_ROUTE_MODE=$DEFAULT_ROUTE_MODE"     "DEFAULT_CUSTOM_ROUTES=$DEFAULT_CUSTOM_ROUTES"     "FORCED_MTU=$FORCED_MTU"

{
    echo "[Interface]"
    if [ "$IPV6_ENABLED" = "1" ]; then
        echo "Address = $WG_SERVER_IPV4/24, $WG_SERVER_IPV6/64"
    else
        echo "Address = $WG_SERVER_IPV4/24"
    fi
    echo "ListenPort = $WG_PORT"
    [ -z "$FORCED_MTU" ] || echo "MTU = $FORCED_MTU"
    echo "PrivateKey = $SERVER_PRIVATE_KEY"
} > "$WG_ROOT/${WG_INTERFACE}.conf"

chmod 600 "$WG_ROOT/${WG_INTERFACE}.conf"

enable_forwarding

cat > /etc/systemd/system/wg-vpn-firewall.service <<EOF
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

systemctl daemon-reload
systemctl enable --now "wg-quick@$WG_INTERFACE"
systemctl enable --now wg-vpn-firewall.service

echo
echo "WireGuard server installed."
echo "Interface: $WG_INTERFACE"
echo "VPN subnet: $WG_IPV4_SUBNET"
echo "Endpoint: $ENDPOINT_HOST:$WG_PORT"
echo "Firewall backend: $(detect_firewall_backend)"
echo "MTU: ${FORCED_MTU:-automatic}"
echo

if yesno "Create the first client now?" "y"; then
    ask "Client name" "client"
    client_name="$INSTALL_PROMPT_RESULT"
    if [ -n "$FORCED_MTU" ]; then
        "$INSTALL_BIN" add "$client_name" --mtu "$FORCED_MTU"
    else
        "$INSTALL_BIN" add "$client_name"
    fi
fi

echo
echo "Useful commands:"
echo "  sudo wg-vpn status"
echo "  sudo wg-vpn diagnose"
echo "  sudo wg-vpn add iphone"
echo "  sudo wg-vpn mtu-test"
