#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
    echo "safety test failed: $*" >&2
    exit 1
}

# shellcheck disable=SC1091
source lib/common.sh
# shellcheck disable=SC1091
source lib/config.sh

valid_mtu 1280 || fail "MTU 1280 should be valid"
valid_mtu 9000 || fail "MTU 9000 should be valid"
! valid_mtu 1279 || fail "MTU 1279 should be rejected"
! valid_mtu 9001 || fail "MTU 9001 should be rejected"

valid_ipv4_cidr "10.66.66.0/24" || fail "valid IPv4 CIDR rejected"
! valid_ipv4_cidr "10.66.66.999/24" || fail "invalid IPv4 CIDR accepted"
valid_ipv6_cidr "2001:db8::/32" || fail "valid IPv6 CIDR rejected"
! valid_ipv6_cidr "2001:db8::/129" || fail "invalid IPv6 prefix accepted"
valid_cidr_list "10.0.0.0/8,192.168.0.0/16,2001:db8::/32" || fail "valid CIDR list rejected"
! valid_cidr_list "10.0.0.0/8,not-a-route" || fail "invalid CIDR list accepted"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf 'SAFE_VALUE=%q\n' "hello-world" > "$tmp/good.env"
chmod 600 "$tmp/good.env"
validate_env_file "$tmp/good.env" || fail "safe env file rejected"

printf '%s\n' 'EVIL=$(id)' > "$tmp/bad.env"
chmod 600 "$tmp/bad.env"
! validate_env_file "$tmp/bad.env" || fail "command substitution in env file accepted"

printf '%s\n' 'EVIL=ok;id' > "$tmp/bad2.env"
chmod 600 "$tmp/bad2.env"
! validate_env_file "$tmp/bad2.env" || fail "command separator in env file accepted"

scripts=(install.sh uninstall.sh bin/wg-vpn lib/*.sh)

if grep -nE 'nft[[:space:]]+flush[[:space:]]+ruleset' "${scripts[@]}"; then
    fail "global nftables flush found"
fi

if grep -nE 'iptables[^#]*-F[[:space:]]+(INPUT|FORWARD|OUTPUT)([[:space:]]|$)' "${scripts[@]}"; then
    fail "built-in IPv4 firewall chain flush found"
fi

if grep -nE 'ip6tables[^#]*-F[[:space:]]+(INPUT|FORWARD|OUTPUT)([[:space:]]|$)' "${scripts[@]}"; then
    fail "built-in IPv6 firewall chain flush found"
fi

if grep -nF 'rm -rf /etc/wireguard' "${scripts[@]}"; then
    fail "whole /etc/wireguard deletion found"
fi

if grep -nE '\$\((prompt_input|prompt_dns|prompt_routing|ask)[[:space:]]' "${scripts[@]}"; then
    fail "interactive prompt found inside command substitution"
fi

if grep -nF 'tar -C / -czf' lib/backup.sh; then
    fail "backup still archives the entire live WireGuard directory"
fi

echo "Safety regression checks passed."
