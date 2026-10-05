#!/usr/bin/env bash
#
# wg-vpn-bypass.sh
#
# Optional Linux client-side domain bypass helper for full-tunnel WireGuard/VPN
# clients. It changes only routes on the Linux machine where it is run.
#
# It does NOT modify the VPS, WireGuard server, peer keys, server firewall, or
# wg-vpn server configuration.
#
# Target: Ubuntu/Debian desktop/server clients with iproute2 + getent.
#

set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

STATE_DIR="/var/lib/wg-vpn-bypass"
DOMAINS_FILE="${STATE_DIR}/domains.txt"
ROUTES_FILE="${STATE_DIR}/routes.tsv"
LOCK_FILE="${STATE_DIR}/state.lock"
BOOT_FILE="${STATE_DIR}/boot-id"
ROUTE_METRIC="$((20000 + RANDOM))"
ROUTE_PROTO="186"

CHATGPT_PRESET=(
  "chatgpt.com"
  "openai.com"
  "auth.openai.com"
  "auth0.openai.com"
  "chat.openai.com"
  "setup.auth.openai.com"
  "cdn.openaimerge.com"
)

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ensure_root() {
  if [[ ${EUID} -eq 0 ]]; then
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    local self
    self="$(readlink -f -- "${BASH_SOURCE[0]}")"
    exec sudo -- /bin/bash -- "$self" "$@"
  fi

  die "Run this script as root (for example: sudo ./wg-vpn-bypass.sh)"
}

ensure_state() {
  local path
  for path in /var /var/lib "$STATE_DIR"; do
    [[ ! -L "$path" ]] || die "State path is a symlink: $path"
    if [[ -e "$path" ]]; then
      [[ -d "$path" && $(stat -c %u -- "$path") == 0 ]] || die "Unsafe state directory: $path"
      (( (8#$(stat -c %a -- "$path") & 0022) == 0 )) || die "State directory is writable by other users: $path"
    fi
  done
  mkdir -p -- "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
  for path in "$DOMAINS_FILE" "$ROUTES_FILE" "$LOCK_FILE" "$BOOT_FILE"; do
    [[ ! -L "$path" ]] || die "State file is a symlink: $path"
    if [[ -e "$path" ]]; then
      [[ -f "$path" && $(stat -c %u -- "$path") == 0 && $(stat -c %h -- "$path") == 1 ]] || die "Unsafe state file: $path"
      (( (8#$(stat -c %a -- "$path") & 0022) == 0 )) || die "State file is writable by other users: $path"
    fi
    touch -- "$path"
    chmod 0600 "$path"
  done
}

check_boot() {
  local boot
  boot="$(cat /proc/sys/kernel/random/boot_id)"
  if [[ $(cat "$BOOT_FILE") != "$boot" ]]; then
    [[ ! -s "$ROUTES_FILE" ]] || printf 'Discarding old/legacy route metadata without deleting any routes. Reboot clears temporary orphan routes.\n' >&2
    : >"$ROUTES_FILE"
    printf '%s\n' "$boot" >"$BOOT_FILE"
  fi
}

normalize_domain() {
  local domain="${1,,}"

  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  domain="${domain%%:*}"
  domain="${domain%.}"

  [[ -n "$domain" && ${#domain} -le 253 ]] || die "Domain must contain 1-253 characters."

  if [[ "$domain" == \*.* ]]; then
    die "Linux helper requires exact hostnames; wildcards such as *.example.com are not supported."
  fi

  if [[ ! "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    die "Invalid domain: $1"
  fi

  printf '%s\n' "$domain"
}

get_domains() {
  local domain
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    [[ -n "$domain" ]] || continue
    normalize_domain "$domain" || return 1
  done <"$DOMAINS_FILE" | sort -u
}

save_domains() {
  local tmp
  tmp="$(mktemp "${STATE_DIR}/domains.XXXXXX")"
  cat | awk 'NF { print tolower($0) }' | sort -u >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$DOMAINS_FILE"
}

add_domain() {
  local domain
  domain="$(normalize_domain "$1")"

  if get_domains | grep -Fxq -- "$domain"; then
    printf 'Already saved: %s\n' "$domain"
    return
  fi

  {
    get_domains
    printf '%s\n' "$domain"
  } | save_domains

  printf 'Added: %s\n' "$domain"
}

remove_domain() {
  local domain tmp
  domain="$(normalize_domain "$1")"

  if ! get_domains | grep -Fxq -- "$domain"; then
    printf 'Not found: %s\n' "$domain"
    return
  fi

  tmp="$(mktemp "${STATE_DIR}/domains.remove.XXXXXX")"
  get_domains | grep -Fvx -- "$domain" >"$tmp" || true
  save_domains <"$tmp"
  rm -f "$tmp"

  printf 'Removed: %s\n' "$domain"
}

wireguard_interfaces() {
  if command -v wg >/dev/null 2>&1; then
    wg show interfaces 2>/dev/null || true
  fi
}

is_wireguard_dev() {
  local candidate="$1"
  local iface

  for iface in $(wireguard_interfaces); do
    [[ "$candidate" == "$iface" ]] && return 0
  done

  [[ "$candidate" =~ ^wg[0-9]+$ ]] && return 0
  return 1
}

usable_dev() {
  local dev="$1" details
  [[ "$dev" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || return 1
  is_wireguard_dev "$dev" && return 1
  details="$(ip -d -o link show dev "$dev")" || return 1
  [[ "$details" != *'state DOWN'* && "$details" != *'NO-CARRIER'* ]] || return 1
  [[ "$details" != *'wireguard'* && "$details" != *' tun '* && "$details" != *' tap '* ]] || return 1
  # Conservative: a physical/VM Ethernet or Wi-Fi device has a sysfs device.
  # Bridges, PPP and other ambiguous virtual uplinks need a different design.
  [[ -e "/sys/class/net/$dev/device" ]]
}

get_default_route() {
  local family="$1"
  local line dev via metric token prev
  local -a cmd

  if [[ "$family" == "4" ]]; then
    cmd=(ip -4 route show table main default)
  else
    cmd=(ip -6 route show table main default)
  fi

  while IFS= read -r line; do
    [[ "$line" == default\ * && "$line" != *' linkdown'* && "$line" != *' dead'* && "$line" != *' nexthop '* && "$line" != *' from '* ]] || continue

    dev=""
    via=""
    metric=""

    prev=""
    for token in $line; do
      case "$prev" in
        dev) dev="$token" ;;
        via) via="$token" ;;
        metric) metric="$token" ;;
      esac
      prev="$token"
    done

    [[ -n "$dev" ]] || continue
    is_wireguard_dev "$dev" && continue
    usable_dev "$dev" || continue
    [[ -z "$metric" || "$metric" =~ ^[0-9]{1,10}$ ]] || continue

    if [[ "$line" == *" unreachable "* || "$line" == unreachable* ]]; then
      continue
    fi

    printf '%s|%s|%s\n' "$dev" "$via" "$metric"
  done < <("${cmd[@]}") | {
    local best="" best_metric=2147483647 current current_metric

    while IFS= read -r current; do
      current_metric="${current##*|}"
      [[ -n "$current_metric" ]] && current_metric=$((10#$current_metric)) || current_metric=0

      if (( current_metric < best_metric )); then
        best="$current"
        best_metric="$current_metric"
      fi
    done

    [[ -n "$best" ]] && printf '%s\n' "$best"
  }
}

resolve_ipv4() {
  local domain="$1"
  getent ahostsv4 "$domain" 2>/dev/null |
    awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1 }' |
    sort -u
}

resolve_ipv6() {
  local domain="$1"
  getent ahostsv6 "$domain" 2>/dev/null |
    awk '$1 ~ /:/ && $1 !~ /\./ && tolower($1) !~ /^::ffff:/ { print $1 }' |
    sort -u
}

valid_address() {
  local family="$1" address="$2" part
  local -a parts
  if [[ "$family" == 4 ]]; then
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a parts <<<"$address"
    for part in "${parts[@]}"; do ((10#$part <= 255)) || return 1; done
  else
    [[ "$address" =~ ^[0-9a-fA-F:]+$ && "$address" == *:* && "$address" != *:::* ]] || return 1
    local rest="${address#*::}"
    [[ "$rest" != *::* ]] || return 1
    IFS=: read -r -a parts <<<"$address"
    local count=0
    for part in "${parts[@]}"; do
      [[ -n "$part" ]] || continue
      [[ ${#part} -le 4 ]] || return 1
      ((count+=1))
    done
    if [[ "$address" == *::* ]]; then ((count < 8)) || return 1
    else [[ "$address" != :* && "$address" != *: && $count == 8 ]] || return 1; fi
  fi
}

route_matches_owned() {
  local family="$1" prefix="$2" via="$3" dev="$4" metric="$5" output
  output="$(ip -N -"$family" route show table main exact "$prefix")" || return 2
  # Match every attribute on the SAME line, using exact fields (eth1 != eth10).
  awk -v via="$via" -v dev="$dev" -v metric="$metric" -v proto="$ROUTE_PROTO" '
    { d=""; v=""; m=""; p="";
      for(i=1;i<NF;i++) { if($i=="dev") d=$(i+1); if($i=="via") v=$(i+1);
        if($i=="metric") m=$(i+1); if($i=="proto") p=$(i+1) }
      if(d==dev && v==via && m==metric && p==proto) found=1
    } END {exit !found}' <<<"$output"
}

remove_owned_routes() {
  [[ -s "$ROUTES_FILE" ]] || {
    : >"$ROUTES_FILE"
    return
  }

  local family prefix via dev metric extra tmp rc failed=0
  tmp="$(mktemp "${STATE_DIR}/routes.XXXXXX")"

  while IFS='|' read -r family prefix via dev metric extra; do
    [[ "$family" =~ ^[46]$ && "$dev" =~ ^[a-zA-Z0-9_.:-]{1,15}$ && "$metric" =~ ^[0-9]{5}$ && -z "$extra" ]] || die 'Invalid route state; no broad deletion will be attempted.'
    [[ ( "$family" == 4 && "$prefix" == */32 ) || ( "$family" == 6 && "$prefix" == */128 ) ]] || die 'Invalid host prefix in route state.'
    valid_address "$family" "${prefix%/*}" || die 'Invalid address in route state.'
    [[ -z "$via" ]] || valid_address "$family" "$via" || die 'Invalid gateway in route state.'

    rc=0
    route_matches_owned "$family" "$prefix" "$via" "$dev" "$metric" || rc=$?
    if ((rc == 1)); then
      printf 'Skipping absent/changed route: %s\n' "$prefix" >&2
      continue
    fi
    local -a args=(ip -"$family" route del table main "$prefix")
    [[ -z "$via" ]] || args+=(via "$via")
    args+=(dev "$dev" proto "$ROUTE_PROTO" metric "$metric")
    if ((rc != 0)) || ! "${args[@]}"; then
      printf '%s|%s|%s|%s|%s\n' "$family" "$prefix" "$via" "$dev" "$metric" >>"$tmp"
      failed=1
      printf 'Cleanup failed for %s; retained for retry.\n' "$prefix" >&2
    fi
  done <"$ROUTES_FILE"

  mv -f -- "$tmp" "$ROUTES_FILE"
  ((failed == 0)) || die 'Some routes could not be removed. Retry clear before refresh/reset.'
}

add_route() {
  local family="$1" ipaddr="$2" via="$3" dev="$4"
  local prefix

  if [[ "$family" == "4" ]]; then
    prefix="${ipaddr}/32"
    local existing
    existing="$(ip -4 route show table main exact "$prefix")" || return 1
    if [[ -n "$existing" ]]; then
      printf 'Skipping existing route: %s\n' "$prefix"
      return
    fi

    if [[ -n "$via" ]]; then
      ip -4 route add table main "$prefix" via "$via" dev "$dev" metric "$ROUTE_METRIC" proto "$ROUTE_PROTO" || return 1
    else
      ip -4 route add table main "$prefix" dev "$dev" metric "$ROUTE_METRIC" proto "$ROUTE_PROTO" || return 1
    fi
  else
    prefix="${ipaddr}/128"
    local existing
    existing="$(ip -6 route show table main exact "$prefix")" || return 1
    if [[ -n "$existing" ]]; then
      printf 'Skipping existing route: %s\n' "$prefix"
      return
    fi

    if [[ -n "$via" ]]; then
      ip -6 route add table main "$prefix" via "$via" dev "$dev" metric "$ROUTE_METRIC" proto "$ROUTE_PROTO" || return 1
    else
      ip -6 route add table main "$prefix" dev "$dev" metric "$ROUTE_METRIC" proto "$ROUTE_PROTO" || return 1
    fi
  fi

  printf '%s|%s|%s|%s|%s\n' "$family" "$prefix" "$via" "$dev" "$ROUTE_METRIC" >>"$ROUTES_FILE"
}

refresh_routes() {
  local -a domains
  local domain_text
  domain_text="$(get_domains)" || die 'Invalid saved hostname; fix domains.txt before refreshing.'
  domains=()
  if [[ -n "$domain_text" ]]; then mapfile -t domains <<<"$domain_text"; fi

  if (("${#domains[@]}" == 0)); then
    remove_owned_routes
    printf 'No domains configured.\n'
    return
  fi

  local route4 route6 dev4 via4 metric4 dev6 via6 metric6
  route4="$(get_default_route 4 || true)"
  route6="$(get_default_route 6 || true)"

  if [[ -z "$route4" && -z "$route6" ]]; then
    die "Could not find a normal non-WireGuard default route."
  fi

  dev4=""; via4=""; metric4=""
  dev6=""; via6=""; metric6=""

  if [[ -n "$route4" ]]; then
    IFS='|' read -r dev4 via4 metric4 <<<"$route4"
    printf 'IPv4 gateway: %s%s\n' "$dev4" "${via4:+ via $via4}"
  fi

  if [[ -n "$route6" ]]; then
    IFS='|' read -r dev6 via6 metric6 <<<"$route6"
    printf 'IPv6 gateway: %s%s\n' "$dev6" "${via6:+ via $via6}"
  fi

  local domain ip addresses found family plan
  plan="$(mktemp "${STATE_DIR}/plan.XXXXXX")"
  for domain in "${domains[@]}"; do
    printf 'Resolving: %s\n' "$domain"
    found=0
    for family in 4 6; do
      [[ "$family" == 4 && -z "$route4" ]] && continue
      [[ "$family" == 6 && -z "$route6" ]] && continue
      addresses="$(resolve_ipv"$family" "$domain" || true)"
      while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        valid_address "$family" "$ip" || continue
        [[ "$ip" != 127.* && "$ip" != 0.* && "$ip" != 169.254.* && "$ip" != :: && "$ip" != ::1 && "$ip" != [fF][fF]* && "$ip" != [fF][eE][89aAbB]* ]] || continue
        if [[ "$family" == 4 ]]; then ((10#${ip%%.*} < 224)) || continue; fi
        printf '%s|%s\n' "$family" "$ip" >>"$plan"
        found=1
      done <<<"$addresses"
    done
    if ((found == 0)); then
      rm -f -- "$plan"
      die "No usable DNS addresses/gateway for $domain. Existing routes kept; check DNS or remove this hostname."
    fi
  done
  remove_owned_routes
  while IFS='|' read -r family ip; do
    if [[ "$family" == 4 ]]; then add_route 4 "$ip" "$via4" "$dev4"
    else add_route 6 "$ip" "$via6" "$dev6"; fi
  done <"$plan"
  rm -f -- "$plan"

  printf '\nTracked bypass routes: %d\n' "$(awk 'NF {c++} END {print c+0}' "$ROUTES_FILE")"
  printf 'Run refresh again if DNS addresses change.\n'
}

show_list() {
  if ! get_domains | grep -q .; then
    printf 'No domains configured.\n'
    return
  fi
  get_domains | sed 's/^/  /'
}

show_status() {
  local domains routes route4 route6
  domains="$(get_domains | awk 'NF {c++} END {print c+0}')"
  routes="$(awk 'NF {c++} END {print c+0}' "$ROUTES_FILE" 2>/dev/null || printf '0')"
  route4="$(get_default_route 4 || true)"
  route6="$(get_default_route 6 || true)"

  printf 'Saved domains:  %s\n' "$domains"
  printf 'Tracked routes: %s\n' "$routes"

  if [[ -n "$route4" ]]; then
    printf 'IPv4 route:     %s\n' "$route4"
  else
    printf 'IPv4 route:     not found\n'
  fi

  if [[ -n "$route6" ]]; then
    printf 'IPv6 route:     %s\n' "$route6"
  else
    printf 'IPv6 route:     not found\n'
  fi
}

add_chatgpt_preset() {
  local domain
  for domain in "${CHATGPT_PRESET[@]}"; do
    add_domain "$domain"
  done
  printf '\nChatGPT/OpenAI preset added.\n'
}

reset_all() {
  remove_owned_routes
  : >"$DOMAINS_FILE"
  printf 'All saved domains and tracked routes removed.\n'
}

show_menu() {
  local choice domain answer

  while true; do
    printf '\nWG VPN Domain Bypass (Linux)\n'
    printf '============================\n'
    printf '1. Add excluded domain\n'
    printf '2. Add ChatGPT/OpenAI preset\n'
    printf '3. Remove excluded domain\n'
    printf '4. List excluded domains\n'
    printf '5. Refresh bypass routes\n'
    printf '6. Show status\n'
    printf '7. Clear active bypass routes\n'
    printf '8. Reset all\n'
    printf '9. Exit\n\n'

    read -r -p 'Select: ' choice

    case "$choice" in
      1)
        read -r -p 'Exact domain: ' domain
        add_domain "$domain"
        read -r -p 'Refresh routes now? [Y/n]: ' answer
        if [[ ! "$answer" =~ ^[Nn]$ ]]; then refresh_routes; fi
        ;;
      2)
        add_chatgpt_preset
        read -r -p 'Refresh routes now? [Y/n]: ' answer
        if [[ ! "$answer" =~ ^[Nn]$ ]]; then refresh_routes; fi
        ;;
      3)
        read -r -p 'Exact domain to remove: ' domain
        remove_domain "$domain"
        refresh_routes
        ;;
      4) show_list ;;
      5) refresh_routes ;;
      6) show_status ;;
      7)
        remove_owned_routes
        printf 'Active bypass routes removed. Saved domains kept.\n'
        ;;
      8)
        read -r -p 'Remove all saved domains and tracked routes? [y/N]: ' answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then reset_all; fi
        ;;
      9) return ;;
      *) printf 'Invalid selection.\n' ;;
    esac
  done
}

main() {
  ensure_root "$@"
  need_cmd ip
  need_cmd getent
  need_cmd awk
  need_cmd sort
  need_cmd flock

  ensure_state

  exec 9>"$LOCK_FILE"
  flock -x 9
  check_boot

  local command="${1:-menu}"
  local value="${2:-}"

  case "$command" in
    menu) show_menu ;;
    add)
      [[ -n "$value" ]] || die "Usage: sudo ./wg-vpn-bypass.sh add <domain>"
      add_domain "$value"
      refresh_routes
      ;;
    add-chatgpt)
      add_chatgpt_preset
      refresh_routes
      ;;
    remove)
      [[ -n "$value" ]] || die "Usage: sudo ./wg-vpn-bypass.sh remove <domain>"
      remove_domain "$value"
      refresh_routes
      ;;
    list) show_list ;;
    refresh) refresh_routes ;;
    status) show_status ;;
    clear)
      remove_owned_routes
      printf 'Active bypass routes removed. Saved domains kept.\n'
      ;;
    reset) reset_all ;;
    *)
      die "Unknown command: $command"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
