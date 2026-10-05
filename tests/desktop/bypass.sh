#!/usr/bin/env bash
# Offline fixtures. No sudo, networking changes, or real ip invocation.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=../wg-vpn-bypass.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../desktop/wg-vpn-bypass.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf -- "$fixture_dir"' EXIT
STATE_DIR="$fixture_dir"
DOMAINS_FILE="$fixture_dir/domains.txt"
ROUTES_FILE="$fixture_dir/routes.tsv"
: >"$DOMAINS_FILE"
: >"$ROUTES_FILE"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
wireguard_interfaces() { printf 'customvpn\n'; }
usable_dev() { [[ "$1" != customvpn && "$1" != tun0 ]]; }
ip() {
  case "$*" in
    *'route show table main default') cat "$fixture_dir/defaults" ;;
    *'route show table main exact'*) cat "$fixture_dir/routes" ;;
    *'route del'*) printf '%s\n' "$*" >>"$fixture_dir/deleted"; [[ ! -e "$fixture_dir/fail-delete" ]] ;;
    *'route add'*) printf '%s\n' "$*" >>"$fixture_dir/added"; [[ ! -e "$fixture_dir/fail-add" ]] ;;
    *) fail "unexpected mocked ip: $*" ;;
  esac
}
[[ $(normalize_domain 'https://Example.com/path') == example.com ]] || fail normalize
if (normalize_domain '*.example.com') 2>/dev/null; then fail wildcard; fi
if (normalize_domain 'x;touch.com') 2>/dev/null; then fail injection; fi
for address in 2001:db8::1 ::1 1:2:3:4:5:6:7:8; do valid_address 6 "$address" || fail "IPv6 $address"; done
for address in 2001:::1 1:2:3:4:5:6:7: 2001::db8::1 ::ffff:192.0.2.1; do
  if valid_address 6 "$address"; then fail "invalid IPv6 $address"; fi
done
cat >"$fixture_dir/defaults" <<'EOF'
default dev customvpn metric 1
default dev tun0 metric 2
default via 192.0.2.1 dev eth0 metric 100 linkdown
default via 192.0.2.2 dev eth1 proto dhcp metric 200
default via 192.0.2.3 dev wlan0 proto dhcp metric 50
unreachable default metric 1
EOF
[[ $(get_default_route 4) == 'wlan0|192.0.2.3|50' ]] || fail gateway
printf '203.0.113.1 via 192.0.2.1 dev eth10 proto 186 metric 23456\n' >"$fixture_dir/routes"
if route_matches_owned 4 203.0.113.1/32 192.0.2.1 eth1 23456; then fail 'partial device match'; fi
printf '203.0.113.1 via 192.0.2.1 dev eth1 proto 186 metric 23456\n' >"$fixture_dir/routes"
route_matches_owned 4 203.0.113.1/32 192.0.2.1 eth1 23456 || fail 'exact ownership'
if route_matches_owned 4 203.0.113.1/32 '' eth1 23456; then fail 'gatewayless matched gateway'; fi
printf '203.0.113.1 via 192.0.2.1 dev eth1 proto 99 metric 23456\n203.0.113.1 via 192.0.2.2 dev eth2 proto 186 metric 23456\n' >"$fixture_dir/routes"
if route_matches_owned 4 203.0.113.1/32 192.0.2.1 eth1 23456; then fail 'attributes matched across lines'; fi
printf '203.0.113.1 via 192.0.2.1 dev eth1 proto 186 metric 23456\n' >"$fixture_dir/routes"
printf '4|203.0.113.1/32|192.0.2.1|eth1|23456\n' >"$ROUTES_FILE"
touch "$fixture_dir/fail-delete"
if (remove_owned_routes); then fail 'delete failure not propagated'; fi
[[ -s "$ROUTES_FILE" ]] || fail 'lost failed deletion state'
rm "$fixture_dir/fail-delete"
refresh_routes
[[ ! -s "$ROUTES_FILE" ]] || fail 'last domain did not clear routes'
grep -Fq 'metric 23456' "$fixture_dir/deleted" || fail 'deletion missing metric'
printf 'example.com\n' >"$DOMAINS_FILE"
printf 'sentinel\n' >"$ROUTES_FILE"
resolve_ipv4() { return 2; }
resolve_ipv6() { return 2; }
if (refresh_routes); then fail 'DNS failure not propagated'; fi
[[ $(cat "$ROUTES_FILE") == sentinel ]] || fail 'DNS failure changed route state'
: >"$ROUTES_FILE"
: >"$fixture_dir/routes"
touch "$fixture_dir/fail-add"
if add_route 4 203.0.113.1 192.0.2.1 eth1; then fail 'add failure ignored'; fi
[[ ! -s "$ROUTES_FILE" ]] || fail 'claimed a failed route creation'
printf 'PASS: offline Linux bypass fixtures\n'
