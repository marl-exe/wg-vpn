#!/usr/bin/env bash

WGVPN_INPUT_CHAIN="WGVPN_INPUT"
WGVPN_FORWARD_CHAIN="WGVPN_FORWARD"
WGVPN_NAT_CHAIN="WGVPN_NAT"

detect_firewall_backend() {
    command_exists iptables || { echo "unavailable"; return; }
    case "$(iptables --version 2>/dev/null || true)" in
        *nf_tables*) echo "iptables-nft" ;;
        *legacy*) echo "iptables-legacy" ;;
        *) echo "iptables-unknown" ;;
    esac
}

ensure_jump() {
    local table="$1"; shift
    if [ "$table" = "filter" ]; then
        iptables -w 5 -C "$@" >/dev/null 2>&1 || iptables -w 5 -I "$@"
    else
        iptables -w 5 -t "$table" -C "$@" >/dev/null 2>&1 || iptables -w 5 -t "$table" -I "$@"
    fi
}

firewall_apply() {
    command_exists iptables || die "iptables is required for V1 firewall management."

    iptables -w 5 -N "$WGVPN_INPUT_CHAIN" 2>/dev/null || true
    iptables -w 5 -F "$WGVPN_INPUT_CHAIN"
    iptables -w 5 -A "$WGVPN_INPUT_CHAIN" -p udp --dport "$WG_PORT" -j ACCEPT
    iptables -w 5 -A "$WGVPN_INPUT_CHAIN" -j RETURN
    ensure_jump filter INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN"

    iptables -w 5 -N "$WGVPN_FORWARD_CHAIN" 2>/dev/null || true
    iptables -w 5 -F "$WGVPN_FORWARD_CHAIN"
    iptables -w 5 -A "$WGVPN_FORWARD_CHAIN" -i "$WG_INTERFACE" -o "$PUBLIC_INTERFACE" -s "$WG_IPV4_SUBNET" -j ACCEPT
    iptables -w 5 -A "$WGVPN_FORWARD_CHAIN" -i "$PUBLIC_INTERFACE" -o "$WG_INTERFACE" -d "$WG_IPV4_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -w 5 -A "$WGVPN_FORWARD_CHAIN" -j RETURN
    ensure_jump filter FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN"
    ensure_jump filter FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN"

    iptables -w 5 -t nat -N "$WGVPN_NAT_CHAIN" 2>/dev/null || true
    iptables -w 5 -t nat -F "$WGVPN_NAT_CHAIN"
    iptables -w 5 -t nat -A "$WGVPN_NAT_CHAIN" -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j MASQUERADE
    iptables -w 5 -t nat -A "$WGVPN_NAT_CHAIN" -j RETURN
    ensure_jump nat POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN"
}

firewall_remove() {
    command_exists iptables || return 0
    while iptables -w 5 -D INPUT -i "$PUBLIC_INTERFACE" -p udp --dport "$WG_PORT" -j "$WGVPN_INPUT_CHAIN" 2>/dev/null; do :; done
    while iptables -w 5 -D FORWARD -i "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" 2>/dev/null; do :; done
    while iptables -w 5 -D FORWARD -o "$WG_INTERFACE" -j "$WGVPN_FORWARD_CHAIN" 2>/dev/null; do :; done
    while iptables -w 5 -t nat -D POSTROUTING -s "$WG_IPV4_SUBNET" -o "$PUBLIC_INTERFACE" -j "$WGVPN_NAT_CHAIN" 2>/dev/null; do :; done

    iptables -w 5 -F "$WGVPN_INPUT_CHAIN" 2>/dev/null || true
    iptables -w 5 -X "$WGVPN_INPUT_CHAIN" 2>/dev/null || true
    iptables -w 5 -F "$WGVPN_FORWARD_CHAIN" 2>/dev/null || true
    iptables -w 5 -X "$WGVPN_FORWARD_CHAIN" 2>/dev/null || true
    iptables -w 5 -t nat -F "$WGVPN_NAT_CHAIN" 2>/dev/null || true
    iptables -w 5 -t nat -X "$WGVPN_NAT_CHAIN" 2>/dev/null || true
}

firewall_rules_present() {
    iptables -w 5 -S "$WGVPN_FORWARD_CHAIN" >/dev/null 2>&1 &&
    iptables -w 5 -t nat -S "$WGVPN_NAT_CHAIN" >/dev/null 2>&1
}
