#!/usr/bin/env bash

firewall_init_names() {
    local id
    [ -n "${SERVER_PUBLIC_KEY:-}" ] || die "SERVER_PUBLIC_KEY is unavailable; cannot identify firewall ownership."
    id="$(printf '%s' "$SERVER_PUBLIC_KEY" | sha256sum | awk '{print substr($1,1,8)}')"
    WGVPN_INPUT_CHAIN="WGVPN_${id}_I"
    WGVPN_FORWARD_CHAIN="WGVPN_${id}_F"
    WGVPN_NAT_CHAIN="WGVPN_${id}_N"
    WGVPN_OWNER_COMMENT="wg-vpn:${id}"
}

detect_firewall_backend() {
    command_exists iptables || { echo "unavailable"; return; }
    case "$(iptables --version 2>/dev/null || true)" in
        *nf_tables*) echo "iptables-nft" ;;
        *legacy*) echo "iptables-legacy" ;;
        *) echo "iptables-unknown" ;;
    esac
}

ensure_jump4() {
    local table="$1"; shift
    if [ "$table" = "filter" ]; then
        iptables -w 5 -C "$@" >/dev/null 2>&1 || iptables -w 5 -I "$@"
    else
        iptables -w 5 -t "$table" -C "$@" >/dev/null 2>&1 || iptables -w 5 -t "$table" -I "$@"
    fi
}

ensure_jump6() {
    local table="$1"; shift
    if [ "$table" = "filter" ]; then
        ip6tables -w 5 -C "$@" >/dev/null 2>&1 || ip6tables -w 5 -I "$@"
    else
        ip6tables -w 5 -t "$table" -C "$@" >/dev/null 2>&1 || ip6tables -w 5 -t "$table" -I "$@"
    fi
}

chain_exists4() {
    local table="$1" chain="$2"
    if [ "$table" = "filter" ]; then
        iptables -w 5 -S "$chain" >/dev/null 2>&1
    else
        iptables -w 5 -t "$table" -S "$chain" >/dev/null 2>&1
    fi
}

chain_exists6() {
    local table="$1" chain="$2"
    if [ "$table" = "filter" ]; then
        ip6tables -w 5 -S "$chain" >/dev/null 2>&1
    else
        ip6tables -w 5 -t "$table" -S "$chain" >/dev/null 2>&1
    fi
}

chain_owned4() {
    local table="$1" chain="$2"
    if [ "$table" = "filter" ]; then
        iptables -w 5 -C "$chain" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN >/dev/null 2>&1
    else
        iptables -w 5 -t "$table" -C "$chain" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN >/dev/null 2>&1
    fi
}

chain_owned6() {
    local table="$1" chain="$2"
    if [ "$table" = "filter" ]; then
        ip6tables -w 5 -C "$chain" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN >/dev/null 2>&1
    else
        ip6tables -w 5 -t "$table" -C "$chain" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN >/dev/null 2>&1
    fi
}

ensure_owned_chain4() {
    local table="$1" chain="$2"
    if chain_exists4 "$table" "$chain"; then
        chain_owned4 "$table" "$chain" || die "Firewall chain $chain already exists but is not owned by this wg-vpn installation."
    else
        if [ "$table" = "filter" ]; then
            iptables -w 5 -N "$chain"
        else
            iptables -w 5 -t "$table" -N "$chain"
        fi
    fi
}

ensure_owned_chain6() {
    local table="$1" chain="$2"
    if chain_exists6 "$table" "$chain"; then
        chain_owned6 "$table" "$chain" || die "IPv6 firewall chain $chain already exists but is not owned by this wg-vpn installation."
    else
        if [ "$table" = "filter" ]; then
            ip6tables -w 5 -N "$chain"
        else
            ip6tables -w 5 -t "$table" -N "$chain"
        fi
    fi
}

legacy_ipv4_matches() {
    chain_exists4 filter WGVPN_INPUT &&
    chain_exists4 filter WGVPN_FORWARD &&
    chain_exists4 nat WGVPN_NAT || return 1

    [ "$(iptables -w 5 -S WGVPN_INPUT 2>/dev/null | wc -l)" -eq 3 ] &&
    [ "$(iptables -w 5 -S WGVPN_FORWARD 2>/dev/null | wc -l)" -eq 4 ] &&
    [ "$(iptables -w 5 -t nat -S WGVPN_NAT 2>/dev/null | wc -l)" -eq 3 ] || return 1

    iptables -w 5 -C WGVPN_INPUT -p udp --dport "$WG_PORT" -j ACCEPT >/dev/null 2>&1 &&
    iptables -w 5 -C WGVPN_INPUT -j RETURN >/dev/null 2>&1 &&
    iptables -w 5 -C WGVPN_FORWARD -i "$WG_INTERFACE" -o "$PUBLIC_INTERFACE" -s "$WG_IPV4_SUBNET" -j ACCEPT >/dev/null 2>&1 &&
    iptables -w 5 -C WGVPN_FORWARD -i "$PUBLIC_INTERFACE" -o "$WG_INTERFACE" -d "$WG_IPV4_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 &&
    iptables -w 5 -C WGVPN_FORWARD -j RETURN >/dev/null 2>&1 &&
    iptables -w 5 -t nat -C WGVPN_NAT -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j MASQUERADE >/dev/null 2>&1 &&
    iptables -w 5 -t nat -C WGVPN_NAT -j RETURN >/dev/null 2>&1
}

legacy_ipv6_matches() {
    command_exists ip6tables || return 1
    chain_exists6 filter WGVPN_INPUT &&
    chain_exists6 filter WGVPN_FORWARD &&
    chain_exists6 nat WGVPN_NAT || return 1

    [ "$(ip6tables -w 5 -S WGVPN_INPUT 2>/dev/null | wc -l)" -eq 3 ] &&
    [ "$(ip6tables -w 5 -S WGVPN_FORWARD 2>/dev/null | wc -l)" -eq 4 ] &&
    [ "$(ip6tables -w 5 -t nat -S WGVPN_NAT 2>/dev/null | wc -l)" -eq 3 ] || return 1

    ip6tables -w 5 -C WGVPN_INPUT -p udp --dport "$WG_PORT" -j ACCEPT >/dev/null 2>&1 &&
    ip6tables -w 5 -C WGVPN_INPUT -j RETURN >/dev/null 2>&1 &&
    ip6tables -w 5 -C WGVPN_FORWARD -i "$WG_INTERFACE" -o "$PUBLIC_INTERFACE" -s "$WG_IPV6_SUBNET" -j ACCEPT >/dev/null 2>&1 &&
    ip6tables -w 5 -C WGVPN_FORWARD -i "$PUBLIC_INTERFACE" -o "$WG_INTERFACE" -d "$WG_IPV6_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 &&
    ip6tables -w 5 -C WGVPN_FORWARD -j RETURN >/dev/null 2>&1 &&
    ip6tables -w 5 -t nat -C WGVPN_NAT -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j MASQUERADE >/dev/null 2>&1 &&
    ip6tables -w 5 -t nat -C WGVPN_NAT -j RETURN >/dev/null 2>&1
}

remove_legacy_ipv4_if_owned() {
    chain_exists4 filter WGVPN_INPUT || return 0

    if ! legacy_ipv4_matches; then
        warn "Legacy WGVPN_* IPv4 chains exist but do not exactly match wg-vpn's legacy layout; leaving them untouched."
        return 0
    fi

    while iptables -w 5 -D INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j WGVPN_INPUT 2>/dev/null; do :; done
    while iptables -w 5 -D FORWARD -i "$WG_INTERFACE" -j WGVPN_FORWARD 2>/dev/null; do :; done
    while iptables -w 5 -D FORWARD -o "$WG_INTERFACE" -j WGVPN_FORWARD 2>/dev/null; do :; done
    while iptables -w 5 -t nat -D POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j WGVPN_NAT 2>/dev/null; do :; done

    iptables -w 5 -F WGVPN_INPUT
    iptables -w 5 -X WGVPN_INPUT
    iptables -w 5 -F WGVPN_FORWARD
    iptables -w 5 -X WGVPN_FORWARD
    iptables -w 5 -t nat -F WGVPN_NAT
    iptables -w 5 -t nat -X WGVPN_NAT
}

remove_legacy_ipv6_if_owned() {
    [ "${IPV6_ENABLED:-0}" = "1" ] || return 0
    command_exists ip6tables || return 0
    chain_exists6 filter WGVPN_INPUT || return 0

    if ! legacy_ipv6_matches; then
        warn "Legacy WGVPN_* IPv6 chains exist but do not exactly match wg-vpn's legacy layout; leaving them untouched."
        return 0
    fi

    while ip6tables -w 5 -D INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j WGVPN_INPUT 2>/dev/null; do :; done
    while ip6tables -w 5 -D FORWARD -i "$WG_INTERFACE" -j WGVPN_FORWARD 2>/dev/null; do :; done
    while ip6tables -w 5 -D FORWARD -o "$WG_INTERFACE" -j WGVPN_FORWARD 2>/dev/null; do :; done
    while ip6tables -w 5 -t nat -D POSTROUTING -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j WGVPN_NAT 2>/dev/null; do :; done

    ip6tables -w 5 -F WGVPN_INPUT
    ip6tables -w 5 -X WGVPN_INPUT
    ip6tables -w 5 -F WGVPN_FORWARD
    ip6tables -w 5 -X WGVPN_FORWARD
    ip6tables -w 5 -t nat -F WGVPN_NAT
    ip6tables -w 5 -t nat -X WGVPN_NAT
}

firewall_apply_ipv4() {
    firewall_init_names
    remove_legacy_ipv4_if_owned

    ensure_owned_chain4 filter "$WGVPN_INPUT_CHAIN"
    iptables -w 5 -F "$WGVPN_INPUT_CHAIN"
    iptables -w 5 -A "$WGVPN_INPUT_CHAIN" -p udp --dport "$WG_PORT" -j ACCEPT
    iptables -w 5 -A "$WGVPN_INPUT_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
    ensure_jump4 filter INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN"

    ensure_owned_chain4 filter "$WGVPN_FORWARD_CHAIN"
    iptables -w 5 -F "$WGVPN_FORWARD_CHAIN"
    iptables -w 5 -A "$WGVPN_FORWARD_CHAIN" -i "$WG_INTERFACE" -o "$PUBLIC_INTERFACE" -s "$WG_IPV4_SUBNET" -j ACCEPT
    iptables -w 5 -A "$WGVPN_FORWARD_CHAIN" -i "$PUBLIC_INTERFACE" -o "$WG_INTERFACE" -d "$WG_IPV4_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -w 5 -A "$WGVPN_FORWARD_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
    ensure_jump4 filter FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN"
    ensure_jump4 filter FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN"

    ensure_owned_chain4 nat "$WGVPN_NAT_CHAIN"
    iptables -w 5 -t nat -F "$WGVPN_NAT_CHAIN"
    iptables -w 5 -t nat -A "$WGVPN_NAT_CHAIN" -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j MASQUERADE
    iptables -w 5 -t nat -A "$WGVPN_NAT_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
    ensure_jump4 nat POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN"
}

firewall_apply_ipv6() {
    [ "${IPV6_ENABLED:-0}" = "1" ] || return 0
    command_exists ip6tables || die "IPv6 is enabled but ip6tables is unavailable."

    firewall_init_names
    remove_legacy_ipv6_if_owned

    ensure_owned_chain6 filter "$WGVPN_INPUT_CHAIN"
    ip6tables -w 5 -F "$WGVPN_INPUT_CHAIN"
    ip6tables -w 5 -A "$WGVPN_INPUT_CHAIN" -p udp --dport "$WG_PORT" -j ACCEPT
    ip6tables -w 5 -A "$WGVPN_INPUT_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
    ensure_jump6 filter INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN"

    ensure_owned_chain6 filter "$WGVPN_FORWARD_CHAIN"
    ip6tables -w 5 -F "$WGVPN_FORWARD_CHAIN"
    ip6tables -w 5 -A "$WGVPN_FORWARD_CHAIN" -i "$WG_INTERFACE" -o "$PUBLIC_INTERFACE" -s "$WG_IPV6_SUBNET" -j ACCEPT
    ip6tables -w 5 -A "$WGVPN_FORWARD_CHAIN" -i "$PUBLIC_INTERFACE" -o "$WG_INTERFACE" -d "$WG_IPV6_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6tables -w 5 -A "$WGVPN_FORWARD_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
    ensure_jump6 filter FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN"
    ensure_jump6 filter FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN"

    ensure_owned_chain6 nat "$WGVPN_NAT_CHAIN"
    ip6tables -w 5 -t nat -F "$WGVPN_NAT_CHAIN"
    ip6tables -w 5 -t nat -A "$WGVPN_NAT_CHAIN" -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j MASQUERADE
    ip6tables -w 5 -t nat -A "$WGVPN_NAT_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
    ensure_jump6 nat POSTROUTING -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN"
}

firewall_apply() {
    command_exists iptables || die "iptables is required for V1 firewall management."
    firewall_apply_ipv4
    firewall_apply_ipv6
}

firewall_remove_ipv4() {
    command_exists iptables || return 0
    firewall_init_names
    remove_legacy_ipv4_if_owned

    chain_exists4 filter "$WGVPN_INPUT_CHAIN" || return 0
    if ! chain_owned4 filter "$WGVPN_INPUT_CHAIN" ||
       ! chain_owned4 filter "$WGVPN_FORWARD_CHAIN" ||
       ! chain_owned4 nat "$WGVPN_NAT_CHAIN"; then
        warn "Refusing to remove one or more IPv4 firewall chains because ownership could not be verified."
        return 0
    fi

    while iptables -w 5 -D INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" 2>/dev/null; do :; done
    while iptables -w 5 -D FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" 2>/dev/null; do :; done
    while iptables -w 5 -D FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" 2>/dev/null; do :; done
    while iptables -w 5 -t nat -D POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" 2>/dev/null; do :; done

    iptables -w 5 -F "$WGVPN_INPUT_CHAIN"
    iptables -w 5 -X "$WGVPN_INPUT_CHAIN"
    iptables -w 5 -F "$WGVPN_FORWARD_CHAIN"
    iptables -w 5 -X "$WGVPN_FORWARD_CHAIN"
    iptables -w 5 -t nat -F "$WGVPN_NAT_CHAIN"
    iptables -w 5 -t nat -X "$WGVPN_NAT_CHAIN"
}

firewall_remove_ipv6() {
    [ "${IPV6_ENABLED:-0}" = "1" ] || return 0
    command_exists ip6tables || return 0
    firewall_init_names
    remove_legacy_ipv6_if_owned

    chain_exists6 filter "$WGVPN_INPUT_CHAIN" || return 0
    if ! chain_owned6 filter "$WGVPN_INPUT_CHAIN" ||
       ! chain_owned6 filter "$WGVPN_FORWARD_CHAIN" ||
       ! chain_owned6 nat "$WGVPN_NAT_CHAIN"; then
        warn "Refusing to remove one or more IPv6 firewall chains because ownership could not be verified."
        return 0
    fi

    while ip6tables -w 5 -D INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" 2>/dev/null; do :; done
    while ip6tables -w 5 -D FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" 2>/dev/null; do :; done
    while ip6tables -w 5 -D FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" 2>/dev/null; do :; done
    while ip6tables -w 5 -t nat -D POSTROUTING -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" 2>/dev/null; do :; done

    ip6tables -w 5 -F "$WGVPN_INPUT_CHAIN"
    ip6tables -w 5 -X "$WGVPN_INPUT_CHAIN"
    ip6tables -w 5 -F "$WGVPN_FORWARD_CHAIN"
    ip6tables -w 5 -X "$WGVPN_FORWARD_CHAIN"
    ip6tables -w 5 -t nat -F "$WGVPN_NAT_CHAIN"
    ip6tables -w 5 -t nat -X "$WGVPN_NAT_CHAIN"
}

firewall_remove() {
    firewall_remove_ipv4
    firewall_remove_ipv6
}

firewall_rules_present() {
    firewall_init_names

    chain_owned4 filter "$WGVPN_INPUT_CHAIN" &&
    chain_owned4 filter "$WGVPN_FORWARD_CHAIN" &&
    chain_owned4 nat "$WGVPN_NAT_CHAIN" &&
    iptables -w 5 -C INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" >/dev/null 2>&1 &&
    iptables -w 5 -C FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" >/dev/null 2>&1 &&
    iptables -w 5 -C FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" >/dev/null 2>&1 &&
    iptables -w 5 -t nat -C POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" >/dev/null 2>&1 || return 1

    if [ "${IPV6_ENABLED:-0}" = "1" ]; then
        chain_owned6 filter "$WGVPN_INPUT_CHAIN" &&
        chain_owned6 filter "$WGVPN_FORWARD_CHAIN" &&
        chain_owned6 nat "$WGVPN_NAT_CHAIN" || return 1
    fi
}
