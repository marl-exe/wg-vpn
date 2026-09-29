#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW_OVERRIDE="${WGVPN_REPO_RAW:-}"
REPO_COMMIT="${WGVPN_REPO_COMMIT:-}"
REPO_RAW=""
INSTALL_LIB="/usr/local/lib/wg-vpn"
INSTALL_BIN="/usr/local/bin/wg-vpn"
WG_ROOT="/etc/wireguard"
STATE_DIR="$WG_ROOT/wg-vpn"
LOCK_FILE="/run/lock/wg-vpn.lock"
SERVICE_FILE="/etc/systemd/system/wg-vpn-firewall.service"
SYSCTL_FILE="/etc/sysctl.d/99-wg-vpn.conf"

INSTALL_TEMP=""
UPDATE_BACKUP=""
FRESH_INSTALL_CLAIMED=0
FRESH_STATE_CREATED=0
FRESH_MANAGEMENT_INSTALLED=0
INSTALL_COMMITTED=0

cleanup_on_exit() {
    local rc=$?
    trap - EXIT

    [ -z "${INSTALL_TEMP:-}" ] || rm -rf "$INSTALL_TEMP"
    [ -z "${UPDATE_BACKUP:-}" ] || rm -rf "$UPDATE_BACKUP"

    if [ "$rc" -ne 0 ] && [ "${INSTALL_COMMITTED:-0}" != "1" ]; then
        if declare -F firewall_remove >/dev/null 2>&1 && [ -n "${SERVER_PUBLIC_KEY:-}" ]; then
            firewall_remove >/dev/null 2>&1 || true
        fi

        if declare -F firewall_service_owned >/dev/null 2>&1 && firewall_service_owned; then
            systemctl disable --now wg-vpn-firewall.service >/dev/null 2>&1 || true
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi

        [ -z "${WG_INTERFACE:-}" ] || systemctl disable --now "wg-quick@$WG_INTERFACE" >/dev/null 2>&1 || true

        if [ "${FRESH_INSTALL_CLAIMED:-0}" = "1" ] && [ -n "${SERVER_CONF:-}" ]; then
            rm -f -- "$SERVER_CONF"
        fi
        if [ "${FRESH_STATE_CREATED:-0}" = "1" ]; then
            rm -rf -- "$STATE_DIR"
        fi

        if declare -F sysctl_file_owned >/dev/null 2>&1 && sysctl_file_owned; then
            rm -f "$SYSCTL_FILE"
        fi

        if [ -n "${PREVIOUS_IPV4_FORWARD:-}" ]; then
            sysctl -w "net.ipv4.ip_forward=$PREVIOUS_IPV4_FORWARD" >/dev/null 2>&1 || true
        fi
        if [ -n "${PREVIOUS_IPV6_FORWARD:-}" ]; then
            sysctl -w "net.ipv6.conf.all.forwarding=$PREVIOUS_IPV6_FORWARD" >/dev/null 2>&1 || true
        fi

        if [ "${FRESH_MANAGEMENT_INSTALLED:-0}" = "1" ]; then
            rm -f "$INSTALL_BIN"
            rm -rf "$INSTALL_LIB"
        fi
    fi

    exit "$rc"
}

trap cleanup_on_exit EXIT

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
        IFS= read -r value < /dev/tty || die "Input ended unexpectedly while waiting for: $label"
    else
        if [ -n "$default" ]; then
            printf '%s [%s]: ' "$label" "$default" >&2
        else
            printf '%s: ' "$label" >&2
        fi
        IFS= read -r value || die "Interactive input is required for: $label"
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

    case "$value" in
        y|Y|yes|YES|Yes) return 0 ;;
        n|N|no|NO|No) return 1 ;;
        *) die "Please answer yes or no." ;;
    esac
}
command_exists() { command -v "$1" >/dev/null 2>&1; }

resolve_repo_source() {
    if [ -n "$REPO_RAW_OVERRIDE" ]; then
        REPO_RAW="$REPO_RAW_OVERRIDE"
        return 0
    fi

    if [ -z "$REPO_COMMIT" ]; then
        REPO_COMMIT="$(
            curl -fsSL --max-time 10 https://api.github.com/repos/marl-exe/wg-vpn/commits/main |
                sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' |
                head -1
        )"
    fi

    [[ "$REPO_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "Could not resolve a single Git commit for installation."
    REPO_RAW="https://raw.githubusercontent.com/marl-exe/wg-vpn/$REPO_COMMIT"
}

acquire_installer_lock() {
    command_exists flock || die "flock is required."
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another wg-vpn install/update/CLI operation is already running."
    export WGVPN_LOCK_HELD=1
}

is_nonpublic_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^0\. ]] ||
    [[ "$ip" =~ ^10\. ]] ||
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] ||
    [[ "$ip" =~ ^127\. ]] ||
    [[ "$ip" =~ ^169\.254\. ]] ||
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] ||
    [[ "$ip" =~ ^192\.0\.0\. ]] ||
    [[ "$ip" =~ ^192\.0\.2\. ]] ||
    [[ "$ip" =~ ^192\.168\. ]] ||
    [[ "$ip" =~ ^198\.(1[89])\. ]] ||
    [[ "$ip" =~ ^198\.51\.100\. ]] ||
    [[ "$ip" =~ ^203\.0\.113\. ]] ||
    [[ "$ip" =~ ^(22[4-9]|23[0-9]|24[0-9]|25[0-5])\. ]]
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

    if [ -n "$source_ip" ] && ! is_nonpublic_ipv4 "$source_ip"; then
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

stage_management_files() {
    local temp="$1" file
    mkdir -p "$temp/lib" "$temp/bin" || return 1

    for file in common.sh config.sh networking.sh firewall.sh clients.sh mtu.sh backup.sh; do
        curl -fsSL "$REPO_RAW/lib/$file" -o "$temp/lib/$file" || return 1
        bash -n "$temp/lib/$file" || return 1
    done

    curl -fsSL "$REPO_RAW/bin/wg-vpn" -o "$temp/bin/wg-vpn" || return 1
    bash -n "$temp/bin/wg-vpn" || return 1
}

install_staged_management_files() {
    local temp="$1" file
    mkdir -p "$INSTALL_LIB" || return 1
    for file in common.sh config.sh networking.sh firewall.sh clients.sh mtu.sh backup.sh; do
        install -m 755 "$temp/lib/$file" "$INSTALL_LIB/$file" || return 1
    done
    install -m 755 "$temp/bin/wg-vpn" "$INSTALL_BIN" || return 1
}

validate_selected_resources() {
    [ -n "$PUBLIC_INTERFACE" ] || die "A public network interface is required."
    ip link show dev "$PUBLIC_INTERFACE" >/dev/null 2>&1 || die "Interface $PUBLIC_INTERFACE does not exist."

    valid_interface_name "$WG_INTERFACE" || die "Invalid WireGuard interface name."
    [ ! -e "$WG_ROOT/${WG_INTERFACE}.conf" ] || die "$WG_ROOT/${WG_INTERFACE}.conf already exists. Refusing to overwrite it."
    ! ip link show "$WG_INTERFACE" >/dev/null 2>&1 || die "Interface $WG_INTERFACE already exists. Refusing to take it over."

    valid_ipv4_24_cidr "$WG_IPV4_SUBNET" || die "V1 currently requires a valid IPv4 /24 subnet."
    ! subnet_conflicts "$WG_IPV4_SUBNET" || die "$WG_IPV4_SUBNET already appears in the routing table."

    valid_port "$WG_PORT" || die "Invalid UDP port."
    ! udp_port_in_use "$WG_PORT" || die "UDP port $WG_PORT is already in use."

    valid_endpoint_host "$ENDPOINT_HOST" || die "Endpoint must be a valid IPv4 address, DNS hostname, or bracketed IPv6 address."
    [ -z "${FORCED_MTU:-}" ] || valid_mtu "$FORCED_MTU" || die "MTU must be between 1280 and 9000."
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
    [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] && [ ! -L "$STATE_DIR/config.env" ] ||
        die "Existing wg-vpn state path is unsafe; refusing update."
fi

if [ ! -f "$STATE_DIR/config.env" ]; then
    for path in "$STATE_DIR" "$INSTALL_LIB" "$INSTALL_BIN" "$SERVICE_FILE" "$SYSCTL_FILE"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            die "Found pre-existing wg-vpn path without a valid installation: $path. Refusing to claim or delete it automatically."
        fi
    done
fi

if [ -f "$STATE_DIR/config.env" ]; then
    echo "wg-vpn existing installation detected."
    echo "Updating CLI and management modules only..."
    echo

    command_exists curl || {
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates
    }
    command_exists flock || {
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends util-linux
    }

    acquire_installer_lock
    resolve_repo_source

    for file in common.sh config.sh networking.sh firewall.sh clients.sh mtu.sh backup.sh; do
        [ -f "$INSTALL_LIB/$file" ] || die "Existing installation is missing $INSTALL_LIB/$file; refusing a non-rollbackable update."
    done
    [ -f "$INSTALL_BIN" ] || die "Existing installation is missing $INSTALL_BIN; refusing a non-rollbackable update."

    INSTALL_TEMP="$(mktemp -d)"
    UPDATE_BACKUP="$(mktemp -d)"
    mkdir -p "$UPDATE_BACKUP/lib" "$UPDATE_BACKUP/bin"
    cp -a "$INSTALL_LIB/." "$UPDATE_BACKUP/lib/"
    cp -a "$INSTALL_BIN" "$UPDATE_BACKUP/bin/wg-vpn"

    stage_management_files "$INSTALL_TEMP" || die "Could not stage a consistent update."
    if ! install_staged_management_files "$INSTALL_TEMP"; then
        rm -rf "$INSTALL_LIB"
        mkdir -p "$INSTALL_LIB"
        cp -a "$UPDATE_BACKUP/lib/." "$INSTALL_LIB/"
        cp -a "$UPDATE_BACKUP/bin/wg-vpn" "$INSTALL_BIN"
        die "Update file installation failed; previous management files were restored."
    fi

    # shellcheck disable=SC1091
    source "$INSTALL_LIB/common.sh"
    # shellcheck disable=SC1091
    source "$INSTALL_LIB/networking.sh"
    # shellcheck disable=SC1091
    source "$INSTALL_LIB/firewall.sh"

    if ! try_load_config || ! (firewall_apply); then
        rm -rf "$INSTALL_LIB"
        mkdir -p "$INSTALL_LIB"
        cp -a "$UPDATE_BACKUP/lib/." "$INSTALL_LIB/"
        cp -a "$UPDATE_BACKUP/bin/wg-vpn" "$INSTALL_BIN"
        die "Updated code failed validation/firewall migration; previous management files were restored."
    fi

    echo "wg-vpn management files updated from commit ${REPO_COMMIT:-custom-source}."
    echo "Existing server keys, clients, WireGuard configuration, VPN addresses, and unrelated firewall objects were not replaced."
    echo
    "$INSTALL_BIN" status
    INSTALL_COMMITTED=1
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
    1|automatic|"") SETUP_MODE="automatic" ;;
    2|manual|advanced) SETUP_MODE="manual" ;;
    *) die "Invalid setup mode: $setup_choice" ;;
esac

echo
echo "Installing required packages..."
echo

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wireguard wireguard-tools qrencode iptables iproute2 ca-certificates curl util-linux

acquire_installer_lock
resolve_repo_source

if [ -e "$WG_ROOT" ] || [ -L "$WG_ROOT" ]; then
    [ -d "$WG_ROOT" ] && [ ! -L "$WG_ROOT" ] || die "Unsafe /etc/wireguard path."
    [ "$(stat -c '%u' "$WG_ROOT" 2>/dev/null || echo -1)" = "0" ] || die "/etc/wireguard must be owned by root."
else
    mkdir -p "$WG_ROOT"
    chmod 700 "$WG_ROOT"
fi

INSTALL_TEMP="$(mktemp -d)"
stage_management_files "$INSTALL_TEMP" || die "Could not stage management files from ${REPO_COMMIT:-custom source}."

mkdir "$INSTALL_LIB" || die "Management directory appeared during install; refusing to overwrite it."
if ! (set -o noclobber; : > "$INSTALL_BIN") 2>/dev/null; then
    rmdir "$INSTALL_LIB" 2>/dev/null || true
    die "Management binary appeared during install; refusing to overwrite it."
fi
FRESH_MANAGEMENT_INSTALLED=1

install_staged_management_files "$INSTALL_TEMP" || die "Could not install management files."

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
            valid_mtu "$mtu_input" || die "MTU must be between 1280 and 9000, or 'automatic'."
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

validate_selected_resources

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

validate_selected_resources
mkdir "$WGVPN_STATE_DIR" || die "wg-vpn state directory appeared during install; refusing to claim it."
FRESH_STATE_CREATED=1
chmod 700 "$WGVPN_STATE_DIR"
mkdir "$WGVPN_CLIENT_META_DIR" || die "Could not create wg-vpn client metadata directory."
chmod 700 "$WGVPN_CLIENT_META_DIR"
ensure_root_dir "$WGVPN_CLIENT_CONFIG_DIR" 700 >/dev/null

SERVER_CONF="$WG_ROOT/${WG_INTERFACE}.conf"
if ! (set -o noclobber; : > "$SERVER_CONF") 2>/dev/null; then
    die "Server configuration appeared during installation; refusing to overwrite: $SERVER_CONF"
fi
chmod 600 "$SERVER_CONF"
FRESH_INSTALL_CLAIMED=1

PREVIOUS_IPV4_FORWARD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
PREVIOUS_IPV6_FORWARD="$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)"

write_env_file "$WGVPN_STATE"     "PREVIOUS_IPV4_FORWARD=$PREVIOUS_IPV4_FORWARD"     "PREVIOUS_IPV6_FORWARD=$PREVIOUS_IPV6_FORWARD"     "VIRTUALIZATION=$VIRTUALIZATION"     "TUN_STATUS=$TUN_STATUS"

SERVER_PRIVATE_KEY="$(wg genkey)"
SERVER_PUBLIC_KEY="$(printf '%s' "$SERVER_PRIVATE_KEY" | wg pubkey)"

write_env_file "$WGVPN_CONFIG"     "WG_INTERFACE=$WG_INTERFACE"     "WG_IPV4_SUBNET=$WG_IPV4_SUBNET"     "WG_SERVER_IPV4=$WG_SERVER_IPV4"     "WG_PORT=$WG_PORT"     "PUBLIC_INTERFACE=$PUBLIC_INTERFACE"     "ENDPOINT_HOST=$ENDPOINT_HOST"     "SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY"     "IPV6_ENABLED=$IPV6_ENABLED"     "WG_IPV6_PREFIX=$WG_IPV6_PREFIX"     "WG_IPV6_SUBNET=$WG_IPV6_SUBNET"     "WG_SERVER_IPV6=$WG_SERVER_IPV6"     "DEFAULT_DNS=$DEFAULT_DNS"     "DEFAULT_ROUTE_MODE=$DEFAULT_ROUTE_MODE"     "DEFAULT_CUSTOM_ROUTES=$DEFAULT_CUSTOM_ROUTES"     "FORCED_MTU=$FORCED_MTU"

{
    echo "# Managed by wg-vpn"
    echo "[Interface]"
    if [ "$IPV6_ENABLED" = "1" ]; then
        echo "Address = $WG_SERVER_IPV4/24, $WG_SERVER_IPV6/64"
    else
        echo "Address = $WG_SERVER_IPV4/24"
    fi
    echo "ListenPort = $WG_PORT"
    [ -z "$FORCED_MTU" ] || echo "MTU = $FORCED_MTU"
    echo "PrivateKey = $SERVER_PRIVATE_KEY"
} > "$SERVER_CONF"

chmod 600 "$SERVER_CONF"

enable_forwarding

install_firewall_service_unit
systemctl daemon-reload
systemctl enable --now "wg-quick@$WG_INTERFACE"
firewall_apply
systemctl enable --now wg-vpn-firewall.service
INSTALL_COMMITTED=1

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
