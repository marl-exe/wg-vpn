#!/usr/bin/env bash

system_dns() {
    local dns
    dns="$(awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null | grep -Ev '^(127\.0\.0\.1|127\.0\.0\.53|::1)$' | head -2 | paste -sd, -)"
    [ -n "$dns" ] && echo "$dns" || echo "1.1.1.1,1.0.0.1"
}

prompt_dns() {
    local choice custom
    {
        echo
        echo "Select DNS for VPN clients:"
        echo
        echo "  1) Cloudflare   1.1.1.1 / 1.0.0.1"
        echo "  2) Google       8.8.8.8 / 8.8.4.4"
        echo "  3) Quad9        9.9.9.9 / 149.112.112.112"
        echo "  4) AdGuard      94.140.14.14 / 94.140.15.15"
        echo "  5) System DNS"
        echo "  6) Custom"
        echo
    } >&2

    choice="$(prompt_input "DNS" "1")"
    case "$choice" in
        1|"") echo "1.1.1.1,1.0.0.1" ;;
        2) echo "8.8.8.8,8.8.4.4" ;;
        3) echo "9.9.9.9,149.112.112.112" ;;
        4) echo "94.140.14.14,94.140.15.15" ;;
        5) system_dns ;;
        6)
            custom="$(prompt_input "DNS servers (comma separated)" "1.1.1.1,1.0.0.1")"
            echo "$custom" | tr -d ' '
            ;;
        *)
            echo "Invalid DNS selection; using Cloudflare." >&2
            echo "1.1.1.1,1.0.0.1"
            ;;
    esac
}

prompt_routing() {
    local default_mode="${1:-full}" choice mode custom=""
    {
        echo
        echo "Routing mode:"
        echo
        echo "  1) Full tunnel"
        echo "  2) Split tunnel (VPN subnet only)"
        echo "  3) Custom routes"
        echo
    } >&2
    case "$default_mode" in
        split) choice="$(prompt_input "Routing" "2")" ;;
        custom) choice="$(prompt_input "Routing" "3")" ;;
        *) choice="$(prompt_input "Routing" "1")" ;;
    esac
    case "$choice" in
        2|split) mode="split" ;;
        3|custom)
            mode="custom"
            custom="$(prompt_input "AllowedIPs (comma separated)" "")"
            custom="$(echo "$custom" | tr -d ' ')"
            [ -n "$custom" ] || return 1
            ;;
        *) mode="full" ;;
    esac
    echo "$mode|$custom"
}

routing_allowed_ips() {
    local mode="$1" custom="${2:-}" ipv6_enabled="${3:-0}"
    case "$mode" in
        full)
            [ "$ipv6_enabled" = "1" ] && echo "0.0.0.0/0,::/0" || echo "0.0.0.0/0"
            ;;
        split)
            [ "$ipv6_enabled" = "1" ] && echo "$WG_IPV4_SUBNET,$WG_IPV6_SUBNET" || echo "$WG_IPV4_SUBNET"
            ;;
        custom)
            [ -n "$custom" ] || return 1
            echo "$custom"
            ;;
        *) return 1 ;;
    esac
}

random_port() {
    command_exists shuf && shuf -i 49152-65535 -n 1 || echo $((49152 + RANDOM % 16384))
}
