#!/usr/bin/env bash
WG_ROOT="/etc/wireguard"
WGVPN_STATE_DIR="${WG_ROOT}/wg-vpn"
WGVPN_CLIENT_META_DIR="${WGVPN_STATE_DIR}/clients"
WGVPN_CLIENT_CONFIG_DIR="${WG_ROOT}/clients"
WGVPN_CONFIG="${WGVPN_STATE_DIR}/config.env"
WGVPN_STATE="${WGVPN_STATE_DIR}/state.env"
WGVPN_LIB_DIR="/usr/local/lib/wg-vpn"
WGVPN_LOCK_FILE="/run/lock/wg-vpn.lock"

die() { echo "wg-vpn: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "$*"; }
require_root() { [ "$(id -u)" -eq 0 ] || die "Run this command as root (sudo)."; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
ensure_installed() { [ -f "$WGVPN_CONFIG" ] || die "wg-vpn is not installed or $WGVPN_CONFIG is missing."; }

validate_env_file() {
    local file="$1" line owner

    [ -f "$file" ] || return 1
    owner="$(stat -c '%u' "$file" 2>/dev/null || echo -1)"
    [ "$owner" = "0" ] || return 1
    [ -z "$(find "$file" -maxdepth 0 -perm /022 -print -quit 2>/dev/null)" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        [[ "$line" =~ ^[A-Z0-9_]+= ]] || return 1
        case "$line" in
            *'$('*|*'${'*|*'$['*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>') return 1 ;;
        esac
    done < "$file"
}

safe_source_env() {
    local file="$1"
    validate_env_file "$file" || die "Unsafe or invalid state file: $file"
    # shellcheck disable=SC1090
    source "$file"
}

load_config() {
    ensure_installed
    safe_source_env "$WGVPN_CONFIG"
    [ ! -f "$WGVPN_STATE" ] || safe_source_env "$WGVPN_STATE"
}

acquire_lock() {
    command_exists flock || die "flock is required (normally provided by util-linux)."
    mkdir -p "$(dirname "$WGVPN_LOCK_FILE")"
    exec 9>"$WGVPN_LOCK_FILE"
    flock -n 9 || die "Another wg-vpn operation is already running."
}

valid_client_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }
valid_interface_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_mtu() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1280 ] && [ "$1" -le 9000 ]; }

valid_ipv4_cidr() {
    local cidr="$1" ip prefix a b c d
    [[ "$cidr" =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    ip="${BASH_REMATCH[1]}"
    prefix="${BASH_REMATCH[2]}"
    [ "$prefix" -le 32 ] || return 1
    IFS=. read -r a b c d <<< "$ip"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ]
}

valid_ipv6_cidr() {
    local cidr="$1" address prefix
    [[ "$cidr" =~ ^([^/]+)/([0-9]{1,3})$ ]] || return 1
    address="${BASH_REMATCH[1]}"
    prefix="${BASH_REMATCH[2]}"
    [ "$prefix" -le 128 ] || return 1
    [[ "$address" == *:* ]] || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    [[ "$address" != *:::* ]]
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

ipv4_prefix_from_cidr() { echo "$1" | awk -F. '{print $1"."$2"."$3}'; }

safe_mkdirs() {
    mkdir -p "$WGVPN_STATE_DIR" "$WGVPN_CLIENT_META_DIR" "$WGVPN_CLIENT_CONFIG_DIR"
    chmod 700 "$WG_ROOT" "$WGVPN_STATE_DIR" "$WGVPN_CLIENT_META_DIR" "$WGVPN_CLIENT_CONFIG_DIR"
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
        printf '%s=%q\n' "$key" "$value" >> "$tmp"
    done
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
}

update_env_value() {
    local file="$1" key="$2" value="$3" tmp
    validate_env_file "$file" || die "Unsafe or invalid state file: $file"
    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    grep -v "^${key}=" "$file" > "$tmp" || true
    printf '%s=%q\n' "$key" "$value" >> "$tmp"
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
    if [ "$n" -ge 1073741824 ] 2>/dev/null; then
        awk -v n="$n" 'BEGIN {printf "%.2f GiB", n/1073741824}'
    elif [ "$n" -ge 1048576 ] 2>/dev/null; then
        awk -v n="$n" 'BEGIN {printf "%.2f MiB", n/1048576}'
    elif [ "$n" -ge 1024 ] 2>/dev/null; then
        awk -v n="$n" 'BEGIN {printf "%.2f KiB", n/1024}'
    else
        printf '%s B' "$n"
    fi
}
