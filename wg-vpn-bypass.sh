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

STATE_DIR="/var/lib/wg-vpn-bypass"
DOMAINS_FILE="${STATE_DIR}/domains.txt"
ROUTES_FILE="${STATE_DIR}/routes.tsv"
LOCK_FILE="/run/lock/wg-vpn-bypass.lock"
ROUTE_METRIC="5"
ROUTE_PROTO="186"

CHATGPT_PRESET=(
  "chatgpt.com"
  "openai.com"
  "auth.openai.com"
  "auth0.openai.com"
  "chat.openai.com"
  "desktop.chat.openai.com"
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
    exec sudo -- "$0" "$@"
  fi

  die "Run this script as root (for example: sudo ./wg-vpn-bypass.sh)"
}

ensure_state() {
  install -d -m 0755 "$STATE_DIR"
  touch "$DOMAINS_FILE"
  chmod 0644 "$DOMAINS_FILE"

  install -d -m 0755 "$(dirname "$LOCK_FILE")"
  touch "$LOCK_FILE"
}

normalize_domain() {
  local domain="${1,,}"

  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  domain="${domain%%:*}"
  domain="${domain%.}"

  [[ -n "$domain" ]] || die "Domain cannot be empty."

  if [[ "$domain" == \*.* ]]; then
    die "Linux helper requires exact hostnames; wildcards such as *.example.com are not supported."
  fi

  if [[ ! "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    die "Invalid domain: $1"
  fi

  printf '%s\n' "$domain"
}

get_domains() {
  awk 'NF { print tolower($0) }' "$DOMAINS_FILE" | sort -u
}

save_domains() {
  local tmp
  tmp="$(mktemp "${STATE_DIR}/domains.XXXXXX")"
  cat | awk 'NF { print tolower($0) }' | sort -u >"$tmp"
  chmod 0644 "$tmp"
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
    [[ -n "$line" ]] || continue

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

    if [[ "$line" == *" unreachable "* || "$line" == unreachable* ]]; then
      continue
    fi

    printf '%s|%s|%s\n' "$dev" "$via" "$metric"
  done < <("${cmd[@]}") | {
    local best="" best_metric=2147483647 current current_metric

    while IFS= read -r current; do
      current_metric="${current##*|}"
      [[ -n "$current_metric" ]] || current_metric=0

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
    awk '$1 ~ /:/ { print $1 }' |
    sort -u
}

route_matches_owned() {
  local family="$1" prefix="$2" via="$3" dev="$4"
  local output

  if [[ "$family" == "4" ]]; then
    output="$(ip -4 route show table main exact "$prefix" 2>/dev/null || true)"
  else
    output="$(ip -6 route show table main exact "$prefix" 2>/dev/null || true)"
  fi

  [[ -n "$output" ]] || return 1
  grep -Fq -- "dev $dev" <<<"$output" || return 1
  grep -Eq "(^| )proto ${ROUTE_PROTO}( |$)" <<<"$output" || return 1

  if [[ -n "$via" ]]; then
    grep -Fq -- "via $via" <<<"$output" || return 1
  fi

  return 0
}

remove_owned_routes() {
  [[ -s "$ROUTES_FILE" ]] || {
    : >"$ROUTES_FILE"
    return
  }

  local family prefix via dev

  while IFS='|' read -r family prefix via dev; do
    [[ -n "$family" && -n "$prefix" && -n "$dev" ]] || continue

    if ! route_matches_owned "$family" "$prefix" "$via" "$dev"; then
      printf 'Skipping unowned/changed route: %s\n' "$prefix" >&2
      continue
    fi

    if [[ "$family" == "4" ]]; then
      if [[ -n "$via" ]]; then
        ip -4 route del table main "$prefix" via "$via" dev "$dev" proto "$ROUTE_PROTO" 2>/dev/null || true
      else
        ip -4 route del table main "$prefix" dev "$dev" proto "$ROUTE_PROTO" 2>/dev/null || true
      fi
    else
      if [[ -n "$via" ]]; then
        ip -6 route del table main "$prefix" via "$via" dev "$dev" proto "$ROUTE_PROTO" 2>/dev/null || true
      else
        ip -6 route del table main "$prefix" dev "$dev" proto "$ROUTE_PROTO" 2>/dev/null || true
      fi
    fi
  done <"$ROUTES_FILE"

  : >"$ROUTES_FILE"
}

add_route() {
  local family="$1" ipaddr="$2" via="$3" dev="$4"
  local prefix

  if [[ "$family" == "4" ]]; then
    prefix="${ipaddr}/32"
    if ip -4 route show table main exact "$prefix" | grep -q .; then
      printf 'Skipping existing route: %s\n' "$prefix"
      return
    fi

    if [[ -n "$via" ]]; then
      ip -4 route add table main "$prefix" via "$via" dev "$dev" metric "$ROUTE_METRIC" proto "$ROUTE_PROTO"
    else
      ip -4 route add table main "$prefix" dev "$dev" metric "$ROUTE_METRIC" proto "$ROUTE_PROTO"
    fi
  else
    prefix="${ipaddr}/128"
    if ip -6 route show table main exact "$prefix" | grep -q .; then
      printf 'Skipping existing route: %s\n' "$prefix"
      return
    fi

    if [[ -n "$via" ]]; then
      ip -6 route add table main "$prefix" via "$via" dev "$dev" metric "$ROUTE_METRIC" proto "$ROUTE_PROTO"
    else
      ip -6 route add table main "$prefix" dev "$dev" metric "$ROUTE_METRIC" proto "$ROUTE_PROTO"
    fi
  fi

  printf '%s|%s|%s|%s\n' "$family" "$prefix" "$via" "$dev" >>"$ROUTES_FILE"
}

refresh_routes() {
  local -a domains
  mapfile -t domains < <(get_domains)

  if (("${#domains[@]}" == 0)); then
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

  remove_owned_routes

  local domain ip count=0
  for domain in "${domains[@]}"; do
    printf 'Resolving: %s\n' "$domain"

    if [[ -n "$route4" ]]; then
      while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        add_route 4 "$ip" "$via4" "$dev4"
        ((count+=1))
      done < <(resolve_ipv4 "$domain")
    fi

    if [[ -n "$route6" ]]; then
      while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        add_route 6 "$ip" "$via6" "$dev6"
        ((count+=1))
      done < <(resolve_ipv6 "$domain")
    fi
  done

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
        [[ ! "$answer" =~ ^[Nn]$ ]] && refresh_routes
        ;;
      2)
        add_chatgpt_preset
        read -r -p 'Refresh routes now? [Y/n]: ' answer
        [[ ! "$answer" =~ ^[Nn]$ ]] && refresh_routes
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
        [[ "$answer" =~ ^[Yy]$ ]] && reset_all
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

main "$@"
