#!/usr/bin/env bash
WG_ROOT="/etc/wireguard"
WGVPN_STATE_DIR="${WG_ROOT}/wg-vpn"
WGVPN_CLIENT_META_DIR="${WGVPN_STATE_DIR}/clients"
WGVPN_CLIENT_CONFIG_DIR="${WG_ROOT}/clients"
WGVPN_CONFIG="${WGVPN_STATE_DIR}/config.env"
WGVPN_STATE="${WGVPN_STATE_DIR}/state.env"
WGVPN_LIB_DIR="/usr/local/lib/wg-vpn"
WGVPN_LOCK_FILE="/run/lock/wg-vpn.lock"

CONFIG_KEYS="WG_INTERFACE WG_IPV4_SUBNET WG_SERVER_IPV4 WG_PORT PUBLIC_INTERFACE ENDPOINT_HOST ENDPOINT_PORT SERVER_PUBLIC_KEY IPV6_ENABLED WG_IPV6_PREFIX WG_IPV6_SUBNET WG_SERVER_IPV6 DEFAULT_DNS DEFAULT_ROUTE_MODE DEFAULT_CUSTOM_ROUTES FORCED_MTU"
STATE_KEYS="PREVIOUS_IPV4_FORWARD PREVIOUS_IPV6_FORWARD VIRTUALIZATION TUN_STATUS"
CLIENT_KEYS="CLIENT_NAME CLIENT_STATUS CLIENT_IPV4 CLIENT_IPV6 CLIENT_PUBLIC_KEY CLIENT_ROUTE_MODE CLIENT_ALLOWED_IPS CLIENT_DNS CLIENT_KEEPALIVE CLIENT_MTU CLIENT_CREATED CLIENT_REVOKED"

die() { echo "wg-vpn: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "$*"; }
require_root() { [ "$(id -u)" -eq 0 ] || die "Run this command as root (sudo)."; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
ensure_installed() { [ -f "$WGVPN_CONFIG" ] || die "wg-vpn is not installed or $WGVPN_CONFIG is missing."; }

acquire_lock() {
    [ "${WGVPN_LOCK_HELD:-0}" = "1" ] && return 0
    command_exists flock || die "flock is required (normally provided by util-linux)."
    mkdir -p "$(dirname "$WGVPN_LOCK_FILE")"
    exec 9>"$WGVPN_LOCK_FILE"
    flock -n 9 || die "Another wg-vpn operation is already running."
    export WGVPN_LOCK_HELD=1
}

valid_client_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }
valid_interface_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_mtu() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1280 ] && [ "$1" -le 9000 ]; }
valid_wg_key() { [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]; }

valid_ipv4_address() {
    local ip="$1" a b c d extra
    IFS=. read -r a b c d extra <<< "$ip"
    [ -z "${extra:-}" ] || return 1
    for part in "$a" "$b" "$c" "$d"; do
        [[ "$part" =~ ^[0-9]+$ ]] || return 1
        [ "$part" -le 255 ] || return 1
    done
}

valid_ipv4_cidr() {
    local cidr="$1" ip prefix
    [[ "$cidr" =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    ip="${BASH_REMATCH[1]}"
    prefix="${BASH_REMATCH[2]}"
    [ "$prefix" -le 32 ] || return 1
    valid_ipv4_address "$ip"
}

valid_ipv6_address() {
    local address="$1" remainder count field
    local -a fields

    [ -n "$address" ] || return 1
    [[ "$address" == *:* ]] || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$address" != *:::* ]] || return 1
    [[ "$address" != :* || "$address" == ::* ]] || return 1
    [[ "$address" != *: || "$address" == *:: ]] || return 1

    if [[ "$address" == *::* ]]; then
        remainder="${address#*::}"
        [[ "$remainder" != *::* ]] || return 1
    fi

    IFS=: read -r -a fields <<< "$address"
    count=0
    for field in "${fields[@]}"; do
        [ -n "$field" ] || continue
        [[ "$field" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        count=$((count + 1))
    done

    if [[ "$address" == *::* ]]; then
        [ "$count" -lt 8 ]
    else
        [ "$count" -eq 8 ]
    fi
}

valid_ipv6_cidr() {
    local cidr="$1" address prefix
    [[ "$cidr" =~ ^([^/]+)/([0-9]{1,3})$ ]] || return 1
    address="${BASH_REMATCH[1]}"
    prefix="${BASH_REMATCH[2]}"
    [ "$prefix" -le 128 ] || return 1
    valid_ipv6_address "$address"
}

valid_cidr_list() {
    local list="$1" item
    local -a cidrs
    [ -n "$list" ] || return 1
    IFS=',' read -r -a cidrs <<< "$list"
    for item in "${cidrs[@]}"; do
        [ -n "$item" ] || return 1
        valid_ipv4_cidr "$item" || valid_ipv6_cidr "$item" || return 1
    done
}

valid_ipv4_24_cidr() {
    local cidr="$1"
    valid_ipv4_cidr "$cidr" || return 1
    [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/24$ ]]
}

valid_dns_list() {
    local list="$1" item
    local -a servers
    [ -n "$list" ] || return 1
    IFS=',' read -r -a servers <<< "$list"
    for item in "${servers[@]}"; do
        valid_ipv4_address "$item" || valid_ipv6_address "$item" || return 1
    done
}

valid_hostname() {
    local host="$1" label
    local -a labels
    [ -n "$host" ] && [ "${#host}" -le 253 ] || return 1
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    IFS=. read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

valid_endpoint_host() {
    local host="$1" address
    if valid_ipv4_address "$host"; then
        return 0
    fi
    if [[ "$host" == \[*\] ]]; then
        address="${host#[}"
        address="${address%]}"
        valid_ipv6_address "$address"
        return
    fi
    valid_hostname "$host"
}

ipv4_prefix_from_cidr() { echo "$1" | awk -F. '{print $1"."$2"."$3}'; }

ensure_root_dir() {
    local dir="$1" mode="$2" created=0 owner
    if [ -e "$dir" ] || [ -L "$dir" ]; then
        [ -d "$dir" ] && [ ! -L "$dir" ] || die "Unsafe directory path: $dir"
        owner="$(stat -c '%u' "$dir" 2>/dev/null || echo -1)"
        [ "$owner" = "0" ] || die "Directory must be owned by root: $dir"
    else
        mkdir -p "$dir"
        chmod "$mode" "$dir"
        created=1
    fi
    printf '%s' "$created"
}

safe_mkdirs() {
    local created
    created="$(ensure_root_dir "$WG_ROOT" 700)"
    [ "$created" = "1" ] || true
    ensure_root_dir "$WGVPN_STATE_DIR" 700 >/dev/null
    ensure_root_dir "$WGVPN_CLIENT_META_DIR" 700 >/dev/null
    ensure_root_dir "$WGVPN_CLIENT_CONFIG_DIR" 700 >/dev/null
}

env_keys_for_type() {
    case "$1" in
        config) printf '%s' "$CONFIG_KEYS" ;;
        state) printf '%s' "$STATE_KEYS" ;;
        client) printf '%s' "$CLIENT_KEYS" ;;
        *) return 1 ;;
    esac
}

env_key_allowed() {
    local type="$1" key="$2" item
    for item in $(env_keys_for_type "$type"); do
        [ "$item" = "$key" ] && return 0
    done
    return 1
}

unset_env_type_vars() {
    local type="$1" item
    for item in $(env_keys_for_type "$type"); do
        unset "$item"
    done
}

decode_env_value() {
    local raw="$1"
    if [ "$raw" = "''" ]; then
        ENV_VALUE=""
        return 0
    fi

    raw="${raw//\\,/,}"
    raw="${raw//\\ / }"
    [[ "$raw" != *\\* ]] || return 1
    [[ "$raw" != *$'\r'* && "$raw" != *$'\n'* ]] || return 1
    ENV_VALUE="$raw"
}

validate_env_file_security() {
    local file="$1" owner
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    owner="$(stat -c '%u' "$file" 2>/dev/null || echo -1)"
    [ "$owner" = "0" ] || return 1
    [ -z "$(find "$file" -maxdepth 0 -perm /022 -print -quit 2>/dev/null)" ] || return 1
}

parse_env_file() {
    local file="$1" type="$2" line key raw
    local -A seen=()

    validate_env_file_security "$file" || return 1
    unset_env_type_vars "$type" || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        [[ "$line" == *=* ]] || return 1
        key="${line%%=*}"
        raw="${line#*=}"
        [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
        env_key_allowed "$type" "$key" || return 1
        [ -z "${seen[$key]+x}" ] || return 1
        seen["$key"]=1
        decode_env_value "$raw" || return 1
        printf -v "$key" '%s' "$ENV_VALUE"
    done < "$file"

    for key in $(env_keys_for_type "$type"); do
        case "$type:$key" in
            config:ENDPOINT_PORT|client:CLIENT_REVOKED) continue ;;
        esac
        [ -n "${seen[$key]+x}" ] || return 1
    done
}

validate_config_values() {
    valid_interface_name "$WG_INTERFACE" || return 1
    valid_ipv4_24_cidr "$WG_IPV4_SUBNET" || return 1
    valid_ipv4_address "$WG_SERVER_IPV4" || return 1
    [ "$WG_SERVER_IPV4" = "$(ipv4_prefix_from_cidr "$WG_IPV4_SUBNET").1" ] || return 1
    valid_port "$WG_PORT" || return 1
    ENDPOINT_PORT="${ENDPOINT_PORT:-$WG_PORT}"
    valid_port "$ENDPOINT_PORT" || return 1
    valid_interface_name "$PUBLIC_INTERFACE" || return 1
    valid_endpoint_host "$ENDPOINT_HOST" || return 1
    valid_wg_key "$SERVER_PUBLIC_KEY" || return 1
    [[ "$IPV6_ENABLED" =~ ^[01]$ ]] || return 1
    valid_dns_list "$DEFAULT_DNS" || return 1
    case "$DEFAULT_ROUTE_MODE" in
        full|split) [ -z "$DEFAULT_CUSTOM_ROUTES" ] || return 1 ;;
        custom) valid_cidr_list "$DEFAULT_CUSTOM_ROUTES" || return 1 ;;
        *) return 1 ;;
    esac
    [ -z "$FORCED_MTU" ] || valid_mtu "$FORCED_MTU" || return 1

    if [ "$IPV6_ENABLED" = "1" ]; then
        valid_ipv6_cidr "$WG_IPV6_SUBNET" || return 1
        valid_ipv6_address "$WG_SERVER_IPV6" || return 1
        [[ "$WG_IPV6_PREFIX" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    fi
}

validate_state_values() {
    [[ "$PREVIOUS_IPV4_FORWARD" =~ ^[01]$ ]] || return 1
    [[ "$PREVIOUS_IPV6_FORWARD" =~ ^[01]$ ]] || return 1
    [[ "$VIRTUALIZATION" =~ ^[A-Za-z0-9_.+-]{1,64}$ ]] || return 1
    case "$TUN_STATUS" in
        available|"not present") ;;
        *) return 1 ;;
    esac
}

validate_client_values() {
    valid_client_name "$CLIENT_NAME" || return 1
    case "$CLIENT_STATUS" in active|revoked) ;; *) return 1 ;; esac
    valid_ipv4_address "$CLIENT_IPV4" || return 1
    [ -z "$CLIENT_IPV6" ] || valid_ipv6_address "$CLIENT_IPV6" || return 1
    valid_wg_key "$CLIENT_PUBLIC_KEY" || return 1
    case "$CLIENT_ROUTE_MODE" in full|split|custom) ;; *) return 1 ;; esac
    valid_cidr_list "$CLIENT_ALLOWED_IPS" || return 1
    valid_dns_list "$CLIENT_DNS" || return 1
    [[ "$CLIENT_KEEPALIVE" =~ ^[0-9]+$ ]] && [ "$CLIENT_KEEPALIVE" -le 65535 ] || return 1
    [ -z "$CLIENT_MTU" ] || valid_mtu "$CLIENT_MTU" || return 1
    [[ "$CLIENT_CREATED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    if [ "$CLIENT_STATUS" = "revoked" ]; then
        [[ "${CLIENT_REVOKED:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    else
        [ -z "${CLIENT_REVOKED:-}" ] || return 1
    fi
}

try_load_config() {
    [ -d "$WG_ROOT" ] && [ ! -L "$WG_ROOT" ] || return 1
    [ -d "$WGVPN_STATE_DIR" ] && [ ! -L "$WGVPN_STATE_DIR" ] || return 1
    [ -d "$WGVPN_CLIENT_META_DIR" ] && [ ! -L "$WGVPN_CLIENT_META_DIR" ] || return 1
    parse_env_file "$WGVPN_CONFIG" config && validate_config_values || return 1
    if [ -f "$WGVPN_STATE" ]; then
        parse_env_file "$WGVPN_STATE" state && validate_state_values || return 1
    fi
}

load_config() {
    ensure_installed
    try_load_config || die "Invalid or unsafe wg-vpn configuration/state metadata."
}

load_client_meta_file() {
    local file="$1"
    parse_env_file "$file" client && validate_client_values || return 1
}

valid_env_write_value() {
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

write_env_file() {
    local file="$1"; shift
    local tmp pair key value
    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    umask 077
    : > "$tmp"
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        [[ "$key" =~ ^[A-Z0-9_]+$ ]] || { rm -f "$tmp"; return 1; }
        valid_env_write_value "$value" || { rm -f "$tmp"; return 1; }
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    done
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
}

validate_generic_env_file() {
    local file="$1" line key raw
    local -A seen=()
    validate_env_file_security "$file" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        [[ "$line" == *=* ]] || return 1
        key="${line%%=*}"
        raw="${line#*=}"
        [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
        [ -z "${seen[$key]+x}" ] || return 1
        seen["$key"]=1
        decode_env_value "$raw" || return 1
    done < "$file"
}

update_env_value() {
    local file="$1" key="$2" value="$3" tmp
    validate_generic_env_file "$file" || die "Unsafe or invalid state file: $file"
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || die "Invalid metadata key."
    valid_env_write_value "$value" || die "Invalid metadata value."
    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    grep -v "^${key}=" "$file" > "$tmp" || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
}

PROMPT_RESULT=""

prompt_input() {
    local prompt="$1" default="${2:-}" answer=""

    if [ -r /dev/tty ]; then
        if [ -n "$default" ]; then
            printf '%s [%s]: ' "$prompt" "$default" > /dev/tty
        else
            printf '%s: ' "$prompt" > /dev/tty
        fi
        IFS= read -r answer < /dev/tty || die "Input ended unexpectedly while waiting for: $prompt"
    else
        if [ -n "$default" ]; then
            printf '%s [%s]: ' "$prompt" "$default" >&2
        else
            printf '%s: ' "$prompt" >&2
        fi
        IFS= read -r answer || die "Interactive input is required for: $prompt"
    fi

    PROMPT_RESULT="${answer:-$default}"
}

prompt_yes_no() {
    local prompt="$1" default="${2:-y}" answer

    if [ "$default" = "y" ]; then
        prompt_input "$prompt (Y/n)" ""
        answer="$PROMPT_RESULT"
        [ -n "$answer" ] || answer="y"
    else
        prompt_input "$prompt (y/N)" ""
        answer="$PROMPT_RESULT"
        [ -n "$answer" ] || answer="n"
    fi

    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        n|N|no|NO|No) return 1 ;;
        *) die "Please answer yes or no." ;;
    esac
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

format_bytes() {
    local n="${1:-0}"
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1073741824 ]; then
        awk -v n="$n" 'BEGIN {printf "%.2f GiB", n/1073741824}'
    elif [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1048576 ]; then
        awk -v n="$n" 'BEGIN {printf "%.2f MiB", n/1048576}'
    elif [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1024 ]; then
        awk -v n="$n" 'BEGIN {printf "%.2f KiB", n/1024}'
    elif [[ "$n" =~ ^[0-9]+$ ]]; then
        printf '%s B' "$n"
    else
        printf '0 B'
    fi
}
