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

chain_exists4() {
    local table="$1" chain="$2"
    [ "$table" = filter ] &&
        iptables -w 5 -S "$chain" >/dev/null 2>&1 ||
        iptables -w 5 -t "$table" -S "$chain" >/dev/null 2>&1
}

chain_exists6() {
    local table="$1" chain="$2"
    [ "$table" = filter ] &&
        ip6tables -w 5 -S "$chain" >/dev/null 2>&1 ||
        ip6tables -w 5 -t "$table" -S "$chain" >/dev/null 2>&1
}

chain_rule_count4() {
    local table="$1" chain="$2"
    if [ "$table" = filter ]; then
        iptables -w 5 -S "$chain" 2>/dev/null | wc -l
    else
        iptables -w 5 -t "$table" -S "$chain" 2>/dev/null | wc -l
    fi
}

chain_rule_count6() {
    local table="$1" chain="$2"
    if [ "$table" = filter ]; then
        ip6tables -w 5 -S "$chain" 2>/dev/null | wc -l
    else
        ip6tables -w 5 -t "$table" -S "$chain" 2>/dev/null | wc -l
    fi
}

managed_chain_matches4() {
    local kind="$1"
    firewall_init_names
    case "$kind" in
        input)
            [ "$(chain_rule_count4 filter "$WGVPN_INPUT_CHAIN")" -eq 3 ] &&
            iptables -w 5 -C "$WGVPN_INPUT_CHAIN" -p udp --dport "$WG_PORT" -j ACCEPT >/dev/null 2>&1 &&
            iptables -w 5 -C "$WGVPN_INPUT_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN >/dev/null 2>&1
            ;;
        forward)
            [ "$(chain_rule_count4 filter "$WGVPN_FORWARD_CHAIN")" -eq 4 ] &&
            iptables -w 5 -C "$WGVPN_FORWARD_CHAIN" -i "$WG_INTERFACE" -o "$PUBLIC_INTERFACE" -s "$WG_IPV4_SUBNET" -j ACCEPT >/dev/null 2>&1 &&
            iptables -w 5 -C "$WGVPN_FORWARD_CHAIN" -i "$PUBLIC_INTERFACE" -o "$WG_INTERFACE" -d "$WG_IPV4_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 &&
            iptables -w 5 -C "$WGVPN_FORWARD_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN >/dev/null 2>&1
            ;;
        nat)
            [ "$(chain_rule_count4 nat "$WGVPN_NAT_CHAIN")" -eq 3 ] &&
            iptables -w 5 -t nat -C "$WGVPN_NAT_CHAIN" -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j MASQUERADE >/dev/null 2>&1 &&
            iptables -w 5 -t nat -C "$WGVPN_NAT_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

managed_chain_matches6() {
    local kind="$1"
    firewall_init_names
    case "$kind" in
        input)
            [ "$(chain_rule_count6 filter "$WGVPN_INPUT_CHAIN")" -eq 3 ] &&
            ip6tables -w 5 -C "$WGVPN_INPUT_CHAIN" -p udp --dport "$WG_PORT" -j ACCEPT >/dev/null 2>&1 &&
            ip6tables -w 5 -C "$WGVPN_INPUT_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN >/dev/null 2>&1
            ;;
        forward)
            [ "$(chain_rule_count6 filter "$WGVPN_FORWARD_CHAIN")" -eq 4 ] &&
            ip6tables -w 5 -C "$WGVPN_FORWARD_CHAIN" -i "$WG_INTERFACE" -o "$PUBLIC_INTERFACE" -s "$WG_IPV6_SUBNET" -j ACCEPT >/dev/null 2>&1 &&
            ip6tables -w 5 -C "$WGVPN_FORWARD_CHAIN" -i "$PUBLIC_INTERFACE" -o "$WG_INTERFACE" -d "$WG_IPV6_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 &&
            ip6tables -w 5 -C "$WGVPN_FORWARD_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN >/dev/null 2>&1
            ;;
        nat)
            [ "$(chain_rule_count6 nat "$WGVPN_NAT_CHAIN")" -eq 3 ] &&
            ip6tables -w 5 -t nat -C "$WGVPN_NAT_CHAIN" -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j MASQUERADE >/dev/null 2>&1 &&
            ip6tables -w 5 -t nat -C "$WGVPN_NAT_CHAIN" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

create_managed_chain4() {
    local kind="$1" chain table
    firewall_init_names
    case "$kind" in
        input) chain="$WGVPN_INPUT_CHAIN"; table=filter ;;
        forward) chain="$WGVPN_FORWARD_CHAIN"; table=filter ;;
        nat) chain="$WGVPN_NAT_CHAIN"; table=nat ;;
        *) return 1 ;;
    esac

    if chain_exists4 "$table" "$chain"; then
        managed_chain_matches4 "$kind" || return 1
        return 0
    fi

    if [ "$table" = filter ]; then
        iptables -w 5 -N "$chain" || return 1
    else
        iptables -w 5 -t "$table" -N "$chain" || return 1
    fi

    case "$kind" in
        input)
            iptables -w 5 -A "$chain" -p udp --dport "$WG_PORT" -j ACCEPT &&
            iptables -w 5 -A "$chain" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
            ;;
        forward)
            iptables -w 5 -A "$chain" -i "$WG_INTERFACE" -o "$PUBLIC_INTERFACE" -s "$WG_IPV4_SUBNET" -j ACCEPT &&
            iptables -w 5 -A "$chain" -i "$PUBLIC_INTERFACE" -o "$WG_INTERFACE" -d "$WG_IPV4_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT &&
            iptables -w 5 -A "$chain" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
            ;;
        nat)
            iptables -w 5 -t nat -A "$chain" -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j MASQUERADE &&
            iptables -w 5 -t nat -A "$chain" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
            ;;
    esac || {
        if [ "$table" = filter ]; then
            iptables -w 5 -F "$chain" 2>/dev/null || true
            iptables -w 5 -X "$chain" 2>/dev/null || true
        else
            iptables -w 5 -t "$table" -F "$chain" 2>/dev/null || true
            iptables -w 5 -t "$table" -X "$chain" 2>/dev/null || true
        fi
        return 1
    }
}

create_managed_chain6() {
    local kind="$1" chain table
    firewall_init_names
    case "$kind" in
        input) chain="$WGVPN_INPUT_CHAIN"; table=filter ;;
        forward) chain="$WGVPN_FORWARD_CHAIN"; table=filter ;;
        nat) chain="$WGVPN_NAT_CHAIN"; table=nat ;;
        *) return 1 ;;
    esac

    if chain_exists6 "$table" "$chain"; then
        managed_chain_matches6 "$kind" || return 1
        return 0
    fi

    if [ "$table" = filter ]; then
        ip6tables -w 5 -N "$chain" || return 1
    else
        ip6tables -w 5 -t "$table" -N "$chain" || return 1
    fi

    case "$kind" in
        input)
            ip6tables -w 5 -A "$chain" -p udp --dport "$WG_PORT" -j ACCEPT &&
            ip6tables -w 5 -A "$chain" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
            ;;
        forward)
            ip6tables -w 5 -A "$chain" -i "$WG_INTERFACE" -o "$PUBLIC_INTERFACE" -s "$WG_IPV6_SUBNET" -j ACCEPT &&
            ip6tables -w 5 -A "$chain" -i "$PUBLIC_INTERFACE" -o "$WG_INTERFACE" -d "$WG_IPV6_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT &&
            ip6tables -w 5 -A "$chain" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
            ;;
        nat)
            ip6tables -w 5 -t nat -A "$chain" -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j MASQUERADE &&
            ip6tables -w 5 -t nat -A "$chain" -m comment --comment "$WGVPN_OWNER_COMMENT" -j RETURN
            ;;
    esac || {
        if [ "$table" = filter ]; then
            ip6tables -w 5 -F "$chain" 2>/dev/null || true
            ip6tables -w 5 -X "$chain" 2>/dev/null || true
        else
            ip6tables -w 5 -t "$table" -F "$chain" 2>/dev/null || true
            ip6tables -w 5 -t "$table" -X "$chain" 2>/dev/null || true
        fi
        return 1
    }
}

legacy_ipv4_matches() {
    chain_exists4 filter WGVPN_INPUT &&
    chain_exists4 filter WGVPN_FORWARD &&
    chain_exists4 nat WGVPN_NAT || return 1
    [ "$(chain_rule_count4 filter WGVPN_INPUT)" -eq 3 ] &&
    [ "$(chain_rule_count4 filter WGVPN_FORWARD)" -eq 4 ] &&
    [ "$(chain_rule_count4 nat WGVPN_NAT)" -eq 3 ] &&
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
    [ "$(chain_rule_count6 filter WGVPN_INPUT)" -eq 3 ] &&
    [ "$(chain_rule_count6 filter WGVPN_FORWARD)" -eq 4 ] &&
    [ "$(chain_rule_count6 nat WGVPN_NAT)" -eq 3 ] &&
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
    legacy_ipv4_matches || {
        warn "Legacy WGVPN_* IPv4 chains do not exactly match wg-vpn's legacy layout; leaving them untouched."
        return 0
    }
    while iptables -w 5 -D INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j WGVPN_INPUT 2>/dev/null; do :; done
    while iptables -w 5 -D FORWARD -i "$WG_INTERFACE" -j WGVPN_FORWARD 2>/dev/null; do :; done
    while iptables -w 5 -D FORWARD -o "$WG_INTERFACE" -j WGVPN_FORWARD 2>/dev/null; do :; done
    while iptables -w 5 -t nat -D POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j WGVPN_NAT 2>/dev/null; do :; done
    iptables -w 5 -F WGVPN_INPUT && iptables -w 5 -X WGVPN_INPUT
    iptables -w 5 -F WGVPN_FORWARD && iptables -w 5 -X WGVPN_FORWARD
    iptables -w 5 -t nat -F WGVPN_NAT && iptables -w 5 -t nat -X WGVPN_NAT
}

remove_legacy_ipv6_if_owned() {
    [ "${IPV6_ENABLED:-0}" = "1" ] || return 0
    command_exists ip6tables || return 0
    chain_exists6 filter WGVPN_INPUT || return 0
    legacy_ipv6_matches || {
        warn "Legacy WGVPN_* IPv6 chains do not exactly match wg-vpn's legacy layout; leaving them untouched."
        return 0
    }
    while ip6tables -w 5 -D INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j WGVPN_INPUT 2>/dev/null; do :; done
    while ip6tables -w 5 -D FORWARD -i "$WG_INTERFACE" -j WGVPN_FORWARD 2>/dev/null; do :; done
    while ip6tables -w 5 -D FORWARD -o "$WG_INTERFACE" -j WGVPN_FORWARD 2>/dev/null; do :; done
    while ip6tables -w 5 -t nat -D POSTROUTING -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j WGVPN_NAT 2>/dev/null; do :; done
    ip6tables -w 5 -F WGVPN_INPUT && ip6tables -w 5 -X WGVPN_INPUT
    ip6tables -w 5 -F WGVPN_FORWARD && ip6tables -w 5 -X WGVPN_FORWARD
    ip6tables -w 5 -t nat -F WGVPN_NAT && ip6tables -w 5 -t nat -X WGVPN_NAT
}

firewall_apply_ipv4() {
    local had_input=0 had_fwd=0 had_nat=0
    firewall_init_names

    chain_exists4 filter "$WGVPN_INPUT_CHAIN" && had_input=1
    chain_exists4 filter "$WGVPN_FORWARD_CHAIN" && had_fwd=1
    chain_exists4 nat "$WGVPN_NAT_CHAIN" && had_nat=1

    [ "$had_input" -eq 0 ] || managed_chain_matches4 input || die "Firewall chain $WGVPN_INPUT_CHAIN exists with unexpected rules."
    [ "$had_fwd" -eq 0 ] || managed_chain_matches4 forward || die "Firewall chain $WGVPN_FORWARD_CHAIN exists with unexpected rules."
    [ "$had_nat" -eq 0 ] || managed_chain_matches4 nat || die "Firewall chain $WGVPN_NAT_CHAIN exists with unexpected rules."

    create_managed_chain4 input || return 1
    create_managed_chain4 forward || { [ "$had_input" -eq 1 ] || { iptables -w 5 -F "$WGVPN_INPUT_CHAIN"; iptables -w 5 -X "$WGVPN_INPUT_CHAIN"; }; return 1; }
    create_managed_chain4 nat || {
        [ "$had_input" -eq 1 ] || { iptables -w 5 -F "$WGVPN_INPUT_CHAIN"; iptables -w 5 -X "$WGVPN_INPUT_CHAIN"; }
        [ "$had_fwd" -eq 1 ] || { iptables -w 5 -F "$WGVPN_FORWARD_CHAIN"; iptables -w 5 -X "$WGVPN_FORWARD_CHAIN"; }
        return 1
    }

    iptables -w 5 -C INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" >/dev/null 2>&1 ||
        iptables -w 5 -I INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" || return 1
    iptables -w 5 -C FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" >/dev/null 2>&1 ||
        iptables -w 5 -I FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" || return 1
    iptables -w 5 -C FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" >/dev/null 2>&1 ||
        iptables -w 5 -I FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" || return 1
    iptables -w 5 -t nat -C POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" >/dev/null 2>&1 ||
        iptables -w 5 -t nat -I POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" || return 1
}

firewall_apply_ipv6() {
    [ "${IPV6_ENABLED:-0}" = "1" ] || return 0
    command_exists ip6tables || die "IPv6 is enabled but ip6tables is unavailable."
    local had_input=0 had_fwd=0 had_nat=0
    firewall_init_names

    chain_exists6 filter "$WGVPN_INPUT_CHAIN" && had_input=1
    chain_exists6 filter "$WGVPN_FORWARD_CHAIN" && had_fwd=1
    chain_exists6 nat "$WGVPN_NAT_CHAIN" && had_nat=1

    [ "$had_input" -eq 0 ] || managed_chain_matches6 input || die "IPv6 firewall chain $WGVPN_INPUT_CHAIN exists with unexpected rules."
    [ "$had_fwd" -eq 0 ] || managed_chain_matches6 forward || die "IPv6 firewall chain $WGVPN_FORWARD_CHAIN exists with unexpected rules."
    [ "$had_nat" -eq 0 ] || managed_chain_matches6 nat || die "IPv6 firewall chain $WGVPN_NAT_CHAIN exists with unexpected rules."

    create_managed_chain6 input || return 1
    create_managed_chain6 forward || return 1
    create_managed_chain6 nat || return 1

    ip6tables -w 5 -C INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" >/dev/null 2>&1 ||
        ip6tables -w 5 -I INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" || return 1
    ip6tables -w 5 -C FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" >/dev/null 2>&1 ||
        ip6tables -w 5 -I FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" || return 1
    ip6tables -w 5 -C FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" >/dev/null 2>&1 ||
        ip6tables -w 5 -I FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" || return 1
    ip6tables -w 5 -t nat -C POSTROUTING -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" >/dev/null 2>&1 ||
        ip6tables -w 5 -t nat -I POSTROUTING -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" || return 1
}

firewall_apply() {
    command_exists iptables || die "iptables is required for V1 firewall management."
    firewall_apply_ipv4 || die "Could not apply IPv4 firewall rules."
    firewall_apply_ipv6 || {
        firewall_remove_ipv6 || true
        die "Could not apply IPv6 firewall rules."
    }
    remove_legacy_ipv4_if_owned
    remove_legacy_ipv6_if_owned
}

firewall_remove_ipv4() {
    command_exists iptables || return 0
    firewall_init_names
    chain_exists4 filter "$WGVPN_INPUT_CHAIN" || return 0
    managed_chain_matches4 input &&
    managed_chain_matches4 forward &&
    managed_chain_matches4 nat || {
        warn "Refusing to remove IPv4 firewall chains because the complete expected rule set could not be verified."
        return 1
    }

    while iptables -w 5 -D INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" 2>/dev/null; do :; done
    while iptables -w 5 -D FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" 2>/dev/null; do :; done
    while iptables -w 5 -D FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" 2>/dev/null; do :; done
    while iptables -w 5 -t nat -D POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" 2>/dev/null; do :; done

    iptables -w 5 -F "$WGVPN_INPUT_CHAIN" && iptables -w 5 -X "$WGVPN_INPUT_CHAIN"
    iptables -w 5 -F "$WGVPN_FORWARD_CHAIN" && iptables -w 5 -X "$WGVPN_FORWARD_CHAIN"
    iptables -w 5 -t nat -F "$WGVPN_NAT_CHAIN" && iptables -w 5 -t nat -X "$WGVPN_NAT_CHAIN"
}

firewall_remove_ipv6() {
    [ "${IPV6_ENABLED:-0}" = "1" ] || return 0
    command_exists ip6tables || return 0
    firewall_init_names
    chain_exists6 filter "$WGVPN_INPUT_CHAIN" || return 0
    managed_chain_matches6 input &&
    managed_chain_matches6 forward &&
    managed_chain_matches6 nat || {
        warn "Refusing to remove IPv6 firewall chains because the complete expected rule set could not be verified."
        return 1
    }

    while ip6tables -w 5 -D INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" 2>/dev/null; do :; done
    while ip6tables -w 5 -D FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" 2>/dev/null; do :; done
    while ip6tables -w 5 -D FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" 2>/dev/null; do :; done
    while ip6tables -w 5 -t nat -D POSTROUTING -s "$WG_IPV6_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" 2>/dev/null; do :; done

    ip6tables -w 5 -F "$WGVPN_INPUT_CHAIN" && ip6tables -w 5 -X "$WGVPN_INPUT_CHAIN"
    ip6tables -w 5 -F "$WGVPN_FORWARD_CHAIN" && ip6tables -w 5 -X "$WGVPN_FORWARD_CHAIN"
    ip6tables -w 5 -t nat -F "$WGVPN_NAT_CHAIN" && ip6tables -w 5 -t nat -X "$WGVPN_NAT_CHAIN"
}

firewall_remove() {
    firewall_remove_ipv6 || true
    firewall_remove_ipv4 || true
}

firewall_rules_present() {
    firewall_init_names
    managed_chain_matches4 input &&
    managed_chain_matches4 forward &&
    managed_chain_matches4 nat &&
    iptables -w 5 -C INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" >/dev/null 2>&1 &&
    iptables -w 5 -C FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" >/dev/null 2>&1 &&
    iptables -w 5 -C FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" >/dev/null 2>&1 &&
    iptables -w 5 -t nat -C POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" >/dev/null 2>&1 || return 1

    if [ "${IPV6_ENABLED:-0}" = "1" ]; then
        managed_chain_matches6 input &&
        managed_chain_matches6 forward &&
        managed_chain_matches6 nat || return 1
    fi
}
