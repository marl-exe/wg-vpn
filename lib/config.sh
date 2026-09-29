#!/usr/bin/env bash

system_dns() {
    local dns
    dns="$(awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null | grep -Ev '^(127\.0\.0\.1|127\.0\.0\.53|::1)$' | head -2 | paste -sd, -)"
    if [ -n "$dns" ] && valid_dns_list "$dns"; then
        echo "$dns"
    else
        echo "1.1.1.1,1.0.0.1"
    fi
}

prompt_dns() {
    local choice custom
    DNS_RESULT=""

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

    prompt_input "DNS" "1"
    choice="$PROMPT_RESULT"

    case "$choice" in
        1|"") DNS_RESULT="1.1.1.1,1.0.0.1" ;;
        2) DNS_RESULT="8.8.8.8,8.8.4.4" ;;
        3) DNS_RESULT="9.9.9.9,149.112.112.112" ;;
        4) DNS_RESULT="94.140.14.14,94.140.15.15" ;;
        5) DNS_RESULT="$(system_dns)" ;;
        6)
            prompt_input "DNS servers (comma separated)" "1.1.1.1,1.0.0.1"
            custom="$PROMPT_RESULT"
            DNS_RESULT="$(echo "$custom" | tr -d ' ')"
            valid_dns_list "$DNS_RESULT" || die "Custom DNS must be a comma-separated list of IPv4/IPv6 addresses."
            ;;
        *) die "Invalid DNS selection: $choice" ;;
    esac
}

prompt_routing() {
    local default_mode="${1:-full}" choice custom=""

    ROUTE_MODE_RESULT=""
    ROUTE_CUSTOM_RESULT=""

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
        split) prompt_input "Routing" "2" ;;
        custom) prompt_input "Routing" "3" ;;
        *) prompt_input "Routing" "1" ;;
    esac
    choice="$PROMPT_RESULT"

    case "$choice" in
        2|split)
            ROUTE_MODE_RESULT="split"
            ;;
        3|custom)
            ROUTE_MODE_RESULT="custom"
            prompt_input "AllowedIPs (comma separated)" ""
            custom="$PROMPT_RESULT"
            custom="$(echo "$custom" | tr -d ' ')"
            valid_cidr_list "$custom" || die "Custom routes must be a comma-separated CIDR list."
            ROUTE_CUSTOM_RESULT="$custom"
            ;;
        1|full|"")
            ROUTE_MODE_RESULT="full"
            ;;
        *)
            die "Invalid routing selection: $choice"
            ;;
    esac
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
            valid_cidr_list "$custom" || return 1
            echo "$custom"
            ;;
        *) return 1 ;;
    esac
}

random_port() {
    command_exists shuf && shuf -i 49152-65535 -n 1 || echo $((49152 + RANDOM % 16384))
}
