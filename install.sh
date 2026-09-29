#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW="${WGVPN_REPO_RAW:-https://raw.githubusercontent.com/marl-exe/wg-vpn/main}"
INSTALL_LIB="/usr/local/lib/wg-vpn"
INSTALL_BIN="/usr/local/bin/wg-vpn"
WG_ROOT="/etc/wireguard"
STATE_DIR="$WG_ROOT/wg-vpn"

die() { echo "wg-vpn installer: $*" >&2; exit 1; }

prompt() {
    local label="$1" default="${2:-}" value=""
    if [ -r /dev/tty ]; then
        if [ -n "$default" ]; then
            printf '%s [%s]: ' "$label" "$default" > /dev/tty
        else
            printf '%s: ' "$label" > /dev/tty
        fi
        IFS= read -r value < /dev/tty || true
    fi
    printf '%s\n' "${value:-$default}"
}

yesno() {
    local label="$1" default="${2:-y}" value
    if [ "$default" = "y" ]; then
        value="$(prompt "$label (Y/n)" "")"
        [ -n "$value" ] || value="y"
    else
        value="$(prompt "$label (y/N)" "")"
        [ -n "$value" ] || value="n"
    fi
    [[ "$value" =~ ^[Yy]$ ]]
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

is_private_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] ||
    [[ "$ip" =~ ^192\.168\. ]] ||
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]
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
    echo "wg-vpn is already installed."
    echo "Run: sudo wg-vpn status"
    exit 0
fi

echo "wg-vpn installer"
echo
echo "This installs native WireGuard and a CLI manager."
echo "It does not install Docker, Node.js, Python, a database, or a Web UI."
echo "Existing firewall tables/chains are never flushed."
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

echo
echo "Detecting network configuration..."
echo

PUBLIC_INTERFACE="$(detect_public_interface)"
if [ -z "$PUBLIC_INTERFACE" ]; then
    PUBLIC_INTERFACE="$(prompt "Could not auto-detect the public interface. Enter interface name" "")"
fi
[ -n "$PUBLIC_INTERFACE" ] || die "A public network interface is required."
ip link show dev "$PUBLIC_INTERFACE" >/dev/null 2>&1 || die "Interface $PUBLIC_INTERFACE does not exist."
echo "  Public interface:   $PUBLIC_INTERFACE"

WG_INTERFACE="$(choose_wg_interface || true)"
if [ -z "$WG_INTERFACE" ]; then
    WG_INTERFACE="$(prompt "Could not find a free wg0-wg9 interface. Enter WireGuard interface" "wg-vpn0")"
fi
valid_interface_name "$WG_INTERFACE" || die "Invalid WireGuard interface name."
[ ! -e "$WG_ROOT/${WG_INTERFACE}.conf" ] || die "$WG_ROOT/${WG_INTERFACE}.conf already exists. Refusing to overwrite it."
ip link show "$WG_INTERFACE" >/dev/null 2>&1 && die "Interface $WG_INTERFACE already exists. Refusing to take it over."
echo "  WireGuard interface: $WG_INTERFACE"

WG_IPV4_SUBNET="$(choose_ipv4_subnet || true)"
if [ -z "$WG_IPV4_SUBNET" ]; then
    WG_IPV4_SUBNET="$(prompt "Could not find a free default VPN subnet. Enter IPv4 /24 subnet" "10.66.66.0/24")"
fi
valid_ipv4_24_cidr "$WG_IPV4_SUBNET" || die "V1 currently requires a valid IPv4 /24 subnet."
subnet_conflicts "$WG_IPV4_SUBNET" && die "$WG_IPV4_SUBNET already appears in the routing table."
WG_SERVER_IPV4="$(ipv4_prefix_from_cidr "$WG_IPV4_SUBNET").1"
echo "  VPN subnet:         $WG_IPV4_SUBNET"

WG_PORT="$(choose_udp_port || true)"
if [ -z "$WG_PORT" ]; then
    WG_PORT="$(prompt "Could not find a free UDP port. Enter WireGuard port" "51820")"
fi
valid_port "$WG_PORT" || die "Invalid UDP port."
udp_port_in_use "$WG_PORT" && die "UDP port $WG_PORT is already in use."
echo "  WireGuard port:     $WG_PORT/UDP"

ENDPOINT_HOST="$(detect_endpoint || true)"
if [ -z "$ENDPOINT_HOST" ]; then
    ENDPOINT_HOST="$(prompt "Could not auto-detect the public IP. Enter public IP or DNS name" "")"
fi
[ -n "$ENDPOINT_HOST" ] || die "A public IP or DNS endpoint is required."
echo "  Public endpoint:    $ENDPOINT_HOST"

IPV6_ENABLED=0
WG_IPV6_PREFIX="fd66:66:66"
WG_IPV6_SUBNET="${WG_IPV6_PREFIX}::/64"
WG_SERVER_IPV6="${WG_IPV6_PREFIX}::1"

if working_ipv6 "$PUBLIC_INTERFACE"; then
    echo "  Public IPv6:        detected"
    if yesno "Enable IPv6 for VPN clients?" "n"; then
        IPV6_ENABLED=1
    fi
else
    echo "  Public IPv6:        not detected"
fi

DEFAULT_DNS="$(prompt_dns)"
route_answer="$(prompt_routing "full")"
DEFAULT_ROUTE_MODE="${route_answer%%|*}"
DEFAULT_CUSTOM_ROUTES="${route_answer#*|}"

echo
echo "Configuration:"
echo
echo "  Public interface:   $PUBLIC_INTERFACE"
echo "  Public endpoint:    $ENDPOINT_HOST:$WG_PORT"
echo "  WireGuard interface: $WG_INTERFACE"
echo "  VPN subnet:         $WG_IPV4_SUBNET"
echo "  DNS:                $DEFAULT_DNS"
echo "  Routing:            $DEFAULT_ROUTE_MODE"
echo "  IPv6:               $([ "$IPV6_ENABLED" = "1" ] && echo enabled || echo disabled)"
echo "  MTU:                automatic"
echo

safe_mkdirs

PREVIOUS_IPV4_FORWARD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
PREVIOUS_IPV6_FORWARD="$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)"

write_env_file "$WGVPN_STATE"     "PREVIOUS_IPV4_FORWARD=$PREVIOUS_IPV4_FORWARD"     "PREVIOUS_IPV6_FORWARD=$PREVIOUS_IPV6_FORWARD"

SERVER_PRIVATE_KEY="$(wg genkey)"
SERVER_PUBLIC_KEY="$(printf '%s' "$SERVER_PRIVATE_KEY" | wg pubkey)"

write_env_file "$WGVPN_CONFIG"     "WG_INTERFACE=$WG_INTERFACE"     "WG_IPV4_SUBNET=$WG_IPV4_SUBNET"     "WG_SERVER_IPV4=$WG_SERVER_IPV4"     "WG_PORT=$WG_PORT"     "PUBLIC_INTERFACE=$PUBLIC_INTERFACE"     "ENDPOINT_HOST=$ENDPOINT_HOST"     "SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY"     "IPV6_ENABLED=$IPV6_ENABLED"     "WG_IPV6_PREFIX=$WG_IPV6_PREFIX"     "WG_IPV6_SUBNET=$WG_IPV6_SUBNET"     "WG_SERVER_IPV6=$WG_SERVER_IPV6"     "DEFAULT_DNS=$DEFAULT_DNS"     "DEFAULT_ROUTE_MODE=$DEFAULT_ROUTE_MODE"     "DEFAULT_CUSTOM_ROUTES=$DEFAULT_CUSTOM_ROUTES"     "FORCED_MTU="

{
    echo "[Interface]"
    if [ "$IPV6_ENABLED" = "1" ]; then
        echo "Address = $WG_SERVER_IPV4/24, $WG_SERVER_IPV6/64"
    else
        echo "Address = $WG_SERVER_IPV4/24"
    fi
    echo "ListenPort = $WG_PORT"
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
echo "MTU: automatic"
echo

if yesno "Create the first client now?" "y"; then
    client_name="$(prompt "Client name" "client")"
    "$INSTALL_BIN" add "$client_name"
fi

echo
echo "Useful commands:"
echo "  sudo wg-vpn status"
echo "  sudo wg-vpn diagnose"
echo "  sudo wg-vpn add iphone"
echo "  sudo wg-vpn mtu-test"
