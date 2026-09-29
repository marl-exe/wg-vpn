#!/usr/bin/env bash
WG_ROOT="/etc/wireguard"
WGVPN_STATE_DIR="${WG_ROOT}/wg-vpn"
WGVPN_CLIENT_META_DIR="${WGVPN_STATE_DIR}/clients"
WGVPN_CLIENT_CONFIG_DIR="${WG_ROOT}/clients"
WGVPN_CONFIG="${WGVPN_STATE_DIR}/config.env"
WGVPN_STATE="${WGVPN_STATE_DIR}/state.env"
WGVPN_LIB_DIR="/usr/local/lib/wg-vpn"

die() { echo "wg-vpn: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "$*"; }
require_root() { [ "$(id -u)" -eq 0 ] || die "Run this command as root (sudo)."; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
ensure_installed() { [ -f "$WGVPN_CONFIG" ] || die "wg-vpn is not installed or $WGVPN_CONFIG is missing."; }

load_config() {
    ensure_installed
    source "$WGVPN_CONFIG"
    [ ! -f "$WGVPN_STATE" ] || source "$WGVPN_STATE"
}

valid_client_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }
valid_interface_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

valid_ipv4_24_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/24$ ]] || return 1
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}"
    [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ]
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
    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    [ ! -f "$file" ] || grep -v "^${key}=" "$file" > "$tmp" || true
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
        IFS= read -r answer < /dev/tty || answer=""
    else
        if [ -n "$default" ]; then
            printf '%s [%s]: ' "$prompt" "$default" >&2
        else
            printf '%s: ' "$prompt" >&2
        fi
        IFS= read -r answer || answer=""
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

    [[ "$answer" =~ ^[Yy]$ ]]
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
