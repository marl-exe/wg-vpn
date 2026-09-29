#!/usr/bin/env bash

current_wg_mtu() {
    ip link show dev "$WG_INTERFACE" 2>/dev/null | awk '{
        for (i=1; i<=NF; i++) if ($i=="mtu") {print $(i+1); exit}
    }'
}

mtu_test() {
    local physical current safe
    physical="$(interface_mtu "$PUBLIC_INTERFACE")"
    current="$(current_wg_mtu)"
    [ -n "$physical" ] || die "Could not determine MTU for $PUBLIC_INTERFACE."
    safe=$((physical - 80))
    [ "$safe" -ge 1280 ] || safe=1280

    echo "WireGuard MTU Test"
    echo
    echo "Public interface:    $PUBLIC_INTERFACE"
    echo "Physical MTU:        $physical"
    echo "Current wg MTU:      ${current:-not active}"
    echo "Conservative start:  $safe"
    echo
    echo "wg-quick chooses MTU automatically when no MTU is forced."
    echo "The conservative value above subtracts 80 bytes from the server egress MTU."
    echo "A client's actual path may require a lower value; test from that client if"
    echo "sites hang, large HTTPS transfers stall, or fragmentation is suspected."
}

apply_wg_mtu() {
    local mtu="$1" conf meta client_conf
    valid_mtu "$mtu" || die "MTU must be between 1280 and 9000."

    conf="$WG_ROOT/${WG_INTERFACE}.conf"
    if grep -q '^MTU[[:space:]]*=' "$conf"; then
        sed -i "s/^MTU[[:space:]]*=.*/MTU = $mtu/" "$conf"
    else
        sed -i "/^ListenPort[[:space:]]*=/a MTU = $mtu" "$conf"
    fi

    for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
        [ -e "$meta" ] || continue
        unset CLIENT_NAME CLIENT_STATUS
        safe_source_env "$meta"
        client_conf="$(client_config_file "$CLIENT_NAME")"
        if [ -f "$client_conf" ]; then
            if grep -q '^MTU[[:space:]]*=' "$client_conf"; then
                sed -i "s/^MTU[[:space:]]*=.*/MTU = $mtu/" "$client_conf"
            else
                sed -i "/^Address[[:space:]]*=/a MTU = $mtu" "$client_conf"
            fi
        fi
        update_env_value "$meta" "CLIENT_MTU" "$mtu"
    done

    update_env_value "$WGVPN_CONFIG" "FORCED_MTU" "$mtu"
    systemctl restart "wg-quick@$WG_INTERFACE"
    info "Applied MTU $mtu to server and saved client configurations."
}

clear_wg_mtu() {
    local conf meta client_conf
    conf="$WG_ROOT/${WG_INTERFACE}.conf"
    sed -i '/^MTU[[:space:]]*=/d' "$conf"
    for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
        [ -e "$meta" ] || continue
        unset CLIENT_NAME
        safe_source_env "$meta"
        client_conf="$(client_config_file "$CLIENT_NAME")"
        [ ! -f "$client_conf" ] || sed -i '/^MTU[[:space:]]*=/d' "$client_conf"
        update_env_value "$meta" "CLIENT_MTU" ""
    done
    update_env_value "$WGVPN_CONFIG" "FORCED_MTU" ""
    systemctl restart "wg-quick@$WG_INTERFACE"
    info "Returned MTU handling to wg-quick automatic mode."
}

optimize_wg() {
    local physical recommended
    physical="$(interface_mtu "$PUBLIC_INTERFACE")"
    recommended=$((physical - 80))
    [ "$recommended" -ge 1280 ] || recommended=1280

    echo "WireGuard Optimization Check"
    echo
    echo "Kernel WireGuard:  $(command_exists wg && echo OK || echo MISSING)"
    echo "Public interface:  $PUBLIC_INTERFACE"
    echo "Physical MTU:      $physical"
    echo "Configured MTU:    ${FORCED_MTU:-automatic}"
    echo "Forwarding IPv4:   $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
    echo "Firewall backend:  $(detect_firewall_backend)"
    echo "Firewall rules:    $(firewall_rules_present && echo OK || echo MISSING)"
    echo
    if [ -z "${FORCED_MTU:-}" ]; then
        echo "MTU: automatic is recommended unless you have a demonstrated path-MTU issue."
        echo "Conservative manual starting point for this server: $recommended"
    else
        echo "MTU: manually forced to $FORCED_MTU."
    fi
    echo
    echo "No global TCP buffer, congestion-control, qdisc, or unrelated sysctl changes are applied."
}
