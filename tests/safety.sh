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
# shellcheck disable=SC1091
source lib/backup.sh

valid_mtu 1280 || fail "MTU 1280 should be valid"
valid_mtu 9000 || fail "MTU 9000 should be valid"
! valid_mtu 1279 || fail "MTU 1279 should be rejected"
! valid_mtu 9001 || fail "MTU 9001 should be rejected"

valid_ipv4_cidr "10.66.66.0/24" || fail "valid IPv4 CIDR rejected"
! valid_ipv4_cidr "10.66.66.999/24" || fail "invalid IPv4 CIDR accepted"

for address in     "2001:db8::1"     "::1"     "fd66:66:66::"     "1:2:3:4:5:6:7:8"; do
    valid_ipv6_address "$address" || fail "valid IPv6 address rejected: $address"
done

for address in     "2001:::1"     "2001::db8::1"     "1:2:3:4:5:6:7"     "1:2:3:4:5:6:7:8:9"     "gggg::1"     "::ffff:192.0.2.1"; do
    ! valid_ipv6_address "$address" || fail "invalid IPv6 address accepted: $address"
done

valid_ipv6_cidr "2001:db8::/32" || fail "valid IPv6 CIDR rejected"
! valid_ipv6_cidr "2001:db8::/129" || fail "invalid IPv6 prefix accepted"
valid_cidr_list "10.0.0.0/8,192.168.0.0/16,2001:db8::/32" || fail "valid CIDR list rejected"
! valid_cidr_list "10.0.0.0/8,not-a-route" || fail "invalid CIDR list accepted"

valid_dns_list "1.1.1.1,2606:4700:4700::1111" || fail "valid DNS list rejected"
! valid_dns_list "1.1.1.1,not-an-ip" || fail "invalid DNS list accepted"

valid_endpoint_host "203.0.113.10" || fail "IPv4 endpoint rejected"
valid_endpoint_host "vpn.example.com" || fail "hostname endpoint rejected"
valid_endpoint_host "[2001:db8::1]" || fail "bracketed IPv6 endpoint rejected"
! valid_endpoint_host "bad host;touch" || fail "unsafe endpoint accepted"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
key="$(printf 'A%.0s' {1..43})="

cat > "$tmp/config.env" <<EOF
WG_INTERFACE=wg0
WG_IPV4_SUBNET=10.66.66.0/24
WG_SERVER_IPV4=10.66.66.1
WG_PORT=51820
PUBLIC_INTERFACE=eth0
ENDPOINT_HOST=vpn.example.com
SERVER_PUBLIC_KEY=$key
IPV6_ENABLED=0
WG_IPV6_PREFIX=fd66:66:66
WG_IPV6_SUBNET=fd66:66:66::/64
WG_SERVER_IPV6=fd66:66:66::1
DEFAULT_DNS=1.1.1.1,1.0.0.1
DEFAULT_ROUTE_MODE=full
DEFAULT_CUSTOM_ROUTES=
FORCED_MTU=
EOF
chmod 600 "$tmp/config.env"
parse_env_file "$tmp/config.env" config || fail "valid config metadata rejected"
validate_config_values || fail "valid config values rejected"

cp "$tmp/config.env" "$tmp/unknown.env"
echo 'WGVPN_CLIENT_META_DIR=/tmp/owned-by-attacker' >> "$tmp/unknown.env"
chmod 600 "$tmp/unknown.env"
! parse_env_file "$tmp/unknown.env" config || fail "unknown config key accepted"

cp "$tmp/config.env" "$tmp/duplicate.env"
echo 'WG_PORT=12345' >> "$tmp/duplicate.env"
chmod 600 "$tmp/duplicate.env"
! parse_env_file "$tmp/duplicate.env" config || fail "duplicate config key accepted"

pwn="$tmp/should-not-exist"
sed "s#ENDPOINT_HOST=vpn.example.com#ENDPOINT_HOST=\$(touch $pwn)#" "$tmp/config.env" > "$tmp/command-looking.env"
chmod 600 "$tmp/command-looking.env"
parse_env_file "$tmp/command-looking.env" config || fail "command-looking value should remain inert data during parsing"
! validate_config_values || fail "command-looking endpoint passed semantic validation"
[ ! -e "$pwn" ] || fail "metadata value executed as shell code"

sed 's/DEFAULT_DNS=1.1.1.1,1.0.0.1/DEFAULT_DNS=1.1.1.1\\,1.0.0.1/' "$tmp/config.env" > "$tmp/legacy.env"
chmod 600 "$tmp/legacy.env"
parse_env_file "$tmp/legacy.env" config || fail "legacy escaped config rejected"
[ "$DEFAULT_DNS" = "1.1.1.1,1.0.0.1" ] || fail "legacy comma escaping was not decoded"

cat > "$tmp/state.env" <<'EOF'
PREVIOUS_IPV4_FORWARD=0
PREVIOUS_IPV6_FORWARD=0
VIRTUALIZATION=kvm
TUN_STATUS=not\ present
EOF
chmod 600 "$tmp/state.env"
parse_env_file "$tmp/state.env" state || fail "legacy state metadata rejected"
validate_state_values || fail "legacy state values rejected"
[ "$TUN_STATUS" = "not present" ] || fail "legacy escaped space was not decoded"

mkdir -p "$tmp/archive/etc/wireguard"
echo test > "$tmp/archive/etc/wireguard/test"
tar -czf "$tmp/valid.tar.gz" -C "$tmp/archive" etc/wireguard/test
validate_backup_archive "$tmp/valid.tar.gz" || fail "simple safe archive rejected"

tar -czf "$tmp/duplicate.tar.gz" -C "$tmp/archive" etc/wireguard/test etc/wireguard/test
! validate_backup_archive "$tmp/duplicate.tar.gz" || fail "duplicate archive member accepted"

ln -s /etc/passwd "$tmp/archive/etc/wireguard/link"
tar -czf "$tmp/symlink.tar.gz" -C "$tmp/archive" etc/wireguard
! validate_backup_archive "$tmp/symlink.tar.gz" || fail "symlink archive member accepted"

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

if grep -nE 'source[[:space:]]+.*(config\.env|state\.env|CLIENT|WGVPN_CONFIG|WGVPN_STATE)' "${scripts[@]}"; then
    fail "state or client metadata is sourced as shell code"
fi

if grep -nE '(^|[[:space:]])eval[[:space:]]' "${scripts[@]}"; then
    fail "eval found in runtime scripts"
fi

if grep -nF 'rm -f "$WGVPN_LOCK_FILE"' "${scripts[@]}" ||
   grep -nF 'rm -f "$LOCK_FILE"' "${scripts[@]}"; then
    fail "lock file is unlinked by runtime scripts"
fi

if grep -nF 'tar -C / -czf' lib/backup.sh; then
    fail "backup still archives the entire live WireGuard directory"
fi

grep -Fq 'prompt_yes_no "Remove wg-vpn configuration and clients?" "n"' uninstall.sh ||
    fail "uninstall does not call the shared confirmation prompt with required arguments"

grep -Fq 'REPO_COMMIT' install.sh || fail "installer does not pin a repository commit"
grep -Fq 'install_firewall_service_unit' install.sh || fail "installer bypasses managed systemd-unit ownership helper"
grep -Fq 'mktemp "$WG_ROOT/wgvpXXXXXX.conf"' lib/clients.sh ||
    fail "client staging validator does not stage inside the WireGuard config directory"
grep -Fq 'first_client_args=("$client_name" "--dns" "$DEFAULT_DNS")' install.sh ||
    fail "first installer-created client does not inherit selected DNS"
grep -Fq 'first_client_args+=("--full")' install.sh ||
    fail "first installer-created client does not inherit selected routing"

echo "Safety regression checks passed."
