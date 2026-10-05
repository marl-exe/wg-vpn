#!/usr/bin/env bash
# Linux-only kernel routing checks. All links/routes/rules live in a disposable
# network namespace. No WireGuard keys, firewall changes or Internet traffic.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID == 0 ]] || { echo 'Run with sudo on a disposable Linux test runner.' >&2; exit 1; }
# shellcheck source=../wg-vpn-bypass.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../desktop/wg-vpn-bypass.sh"
test_ns="wg-bypass-test-$$"
test_dir="$(mktemp -d)"
created_ns=0
ip() { command ip -netns "$test_ns" "$@"; }
cleanup() {
  if ((created_ns)); then command ip netns delete "$test_ns"; fi
  rm -rf -- "$test_dir"
}
trap cleanup EXIT
command ip netns add "$test_ns"
created_ns=1
STATE_DIR="$test_dir"
ROUTES_FILE="$test_dir/routes.tsv"
: >"$ROUTES_FILE"
ip link set lo up
ip link add lan type dummy
ip link add tunnel type dummy
ip link set lan up
ip link set tunnel up
ip -4 address add 192.0.2.2/24 dev lan
ip -6 address add 2001:db8:1::2/64 dev lan nodad
ip -4 address add 10.66.0.2/24 dev tunnel
ip -6 address add fd66::2/64 dev tunnel nodad
ip -4 route add default via 192.0.2.1 dev lan
ip -6 route add default via 2001:db8:1::1 dev lan
for family in 4 6; do
  # Exact policy rule/table arrangement installed by wg-quick add_default.
  ip -"$family" route add default dev tunnel table 51820
  ip -"$family" rule add not fwmark 51820 table 51820
  ip -"$family" rule add table main suppress_prefixlength 0
done
[[ $(ip -4 route get 203.0.113.1) == *'dev tunnel'* ]]
[[ $(ip -6 route get 2001:db8:2::1) == *'dev tunnel'* ]]
add_route 4 203.0.113.1 192.0.2.1 lan
add_route 6 2001:db8:2::1 2001:db8:1::1 lan
[[ $(ip -4 route get 203.0.113.1) == *'dev lan'* ]]
[[ $(ip -6 route get 2001:db8:2::1) == *'dev lan'* ]]
[[ $(ip -4 route get 203.0.113.2) == *'dev tunnel'* ]]
[[ $(ip -6 route get 2001:db8:2::2) == *'dev tunnel'* ]]
[[ $(ip -4 route get 203.0.113.2 mark 51820) == *'dev lan'* ]]
[[ $(ip -6 route get 2001:db8:2::2 mark 51820) == *'dev lan'* ]]
# Same prefix, different protocol/metric: must survive helper cleanup.
ip -4 route add 203.0.113.1/32 via 192.0.2.1 dev lan proto static metric 9
remove_owned_routes
[[ $(ip -4 route show exact 203.0.113.1/32) == *'proto static metric 9'* ]]
[[ -z $(ip -6 route show exact 2001:db8:2::1/128) ]]
[[ $(ip -6 route get 2001:db8:2::1) == *'dev tunnel'* ]]
add_route 4 203.0.113.1 192.0.2.1 lan
[[ ! -s "$ROUTES_FILE" ]]
printf 'PASS: IPv4/IPv6 kernel lookup with wg-quick policy rules, fwmark and scoped cleanup\n'
