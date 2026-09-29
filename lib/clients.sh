#!/usr/bin/env bash

client_meta_file() { echo "$WGVPN_CLIENT_META_DIR/$1.env"; }
client_config_file() { echo "$WGVPN_CLIENT_CONFIG_DIR/$1.conf"; }

load_client() {
    local name="$1" file
    file="$(client_meta_file "$name")"
    [ -f "$file" ] || die "Client '$name' does not exist."
    source "$file"
}

next_client_ipv4() {
    local prefix last ip meta used
    prefix="$(ipv4_prefix_from_cidr "$WG_IPV4_SUBNET")"
    for last in $(seq 2 254); do
        ip="$prefix.$last"
        used=0
        for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
            [ -e "$meta" ] || continue
            unset CLIENT_IPV4
            source "$meta"
            if [ "${CLIENT_IPV4:-}" = "$ip" ]; then
                used=1
                break
            fi
        done
        [ "$used" -eq 1 ] || { echo "$ip"; return 0; }
    done
    return 1
}

next_client_ipv6() {
    local last candidate meta used
    for last in $(seq 2 254); do
        candidate="${WG_IPV6_PREFIX}::$last"
        used=0
        for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
            [ -e "$meta" ] || continue
            unset CLIENT_IPV6
            source "$meta"
            if [ "${CLIENT_IPV6:-}" = "$candidate" ]; then used=1; break; fi
        done
        [ "$used" -eq 1 ] || { echo "$candidate"; return 0; }
    done
    return 1
}

server_peer_block() {
    local name="$1" pub="$2" psk="$3" ipv4="$4" ipv6="${5:-}"
    echo "# BEGIN_WGVPN_CLIENT $name"
    echo "[Peer]"
    echo "PublicKey = $pub"
    echo "PresharedKey = $psk"
    if [ -n "$ipv6" ]; then
        echo "AllowedIPs = $ipv4/32, $ipv6/128"
    else
        echo "AllowedIPs = $ipv4/32"
    fi
    echo "# END_WGVPN_CLIENT $name"
}

remove_peer_block_from_file() {
    local name="$1"
    sed -i "/^# BEGIN_WGVPN_CLIENT ${name}$/,/^# END_WGVPN_CLIENT ${name}$/d" "$WG_ROOT/${WG_INTERFACE}.conf"
}

sync_interface() {
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
    fi
}

add_client() {
    local name="$1" route_mode="${2:-}" custom_routes="${3:-}" dns="${4:-}"
    local keepalive="${5:-25}" mtu="${6:-${FORCED_MTU:-}}"
    local meta conf ipv4 ipv6="" private public psk route_answer allowed address

    valid_client_name "$name" || die "Client names may contain letters, numbers, _ and - (max 32 chars)."
    meta="$(client_meta_file "$name")"
    [ ! -e "$meta" ] || die "Client '$name' already exists."

    ipv4="$(next_client_ipv4)" || die "VPN IPv4 subnet is full."
    if [ "$IPV6_ENABLED" = "1" ]; then
        ipv6="$(next_client_ipv6)" || die "VPN IPv6 subnet is full."
    fi

    if [ -z "$route_mode" ]; then
        route_answer="$(prompt_routing "$DEFAULT_ROUTE_MODE")" || die "Invalid routing selection."
        route_mode="${route_answer%%|*}"
        custom_routes="${route_answer#*|}"
    fi
    allowed="$(routing_allowed_ips "$route_mode" "$custom_routes" "$IPV6_ENABLED")" || die "Invalid routing mode."
    [ -n "$dns" ] || dns="$(prompt_dns "$DEFAULT_DNS")"

    private="$(wg genkey)"
    public="$(printf '%s' "$private" | wg pubkey)"
    psk="$(wg genpsk)"
    conf="$(client_config_file "$name")"

    {
        echo "[Interface]"
        echo "PrivateKey = $private"
        address="$ipv4/32"
        [ -z "$ipv6" ] || address="$address, $ipv6/128"
        echo "Address = $address"
        [ -z "$dns" ] || echo "DNS = $dns"
        [ -z "$mtu" ] || echo "MTU = $mtu"
        echo
        echo "[Peer]"
        echo "PublicKey = $SERVER_PUBLIC_KEY"
        echo "PresharedKey = $psk"
        echo "Endpoint = $ENDPOINT_HOST:$WG_PORT"
        echo "AllowedIPs = $allowed"
        [ "$keepalive" = "0" ] || echo "PersistentKeepalive = $keepalive"
    } > "$conf"
    chmod 600 "$conf"

    {
        echo
        server_peer_block "$name" "$public" "$psk" "$ipv4" "$ipv6"
    } >> "$WG_ROOT/${WG_INTERFACE}.conf"

    write_env_file "$meta"         "CLIENT_NAME=$name"         "CLIENT_STATUS=active"         "CLIENT_IPV4=$ipv4"         "CLIENT_IPV6=$ipv6"         "CLIENT_PUBLIC_KEY=$public"         "CLIENT_ROUTE_MODE=$route_mode"         "CLIENT_ALLOWED_IPS=$allowed"         "CLIENT_DNS=$dns"         "CLIENT_KEEPALIVE=$keepalive"         "CLIENT_MTU=$mtu"         "CLIENT_CREATED=$(now_iso)"

    sync_interface

    echo
    echo "Client: $name"
    echo "VPN IP: $ipv4"
    [ -z "$ipv6" ] || echo "VPN IPv6: $ipv6"
    echo "Routing: $route_mode"
    echo "Configuration: $conf"
    echo
    if command_exists qrencode; then
        qrencode -t ansiutf8 -l L < "$conf"
        echo
    fi
}

revoke_client() {
    local name="$1" meta
    load_client "$name"
    meta="$(client_meta_file "$name")"
    if [ "$CLIENT_STATUS" = "revoked" ]; then
        info "Client '$name' is already revoked."
        return 0
    fi

    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        wg set "$WG_INTERFACE" peer "$CLIENT_PUBLIC_KEY" remove 2>/dev/null || true
    fi
    remove_peer_block_from_file "$name"
    update_env_value "$meta" "CLIENT_STATUS" "revoked"
    update_env_value "$meta" "CLIENT_REVOKED" "$(now_iso)"
    info "Client '$name' revoked. Its saved configuration can no longer authenticate."
}

remove_client() {
    local name="$1"
    load_client "$name"
    [ "$CLIENT_STATUS" = "revoked" ] || revoke_client "$name"
    rm -f "$(client_config_file "$name")" "$(client_meta_file "$name")"
    info "Client '$name' removed."
}

list_clients() {
    local meta count=0
    printf '%-20s %-16s %-10s %-8s\n' "CLIENT" "VPN IP" "ROUTING" "STATUS"
    for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
        [ -e "$meta" ] || continue
        unset CLIENT_NAME CLIENT_IPV4 CLIENT_ROUTE_MODE CLIENT_STATUS
        source "$meta"
        printf '%-20s %-16s %-10s %-8s\n' "$CLIENT_NAME" "$CLIENT_IPV4" "$CLIENT_ROUTE_MODE" "$CLIENT_STATUS"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || echo "(no clients)"
}

show_client() {
    local name="$1"
    load_client "$name"
    echo "Client:        $CLIENT_NAME"
    echo "Status:        $CLIENT_STATUS"
    echo "VPN IPv4:      $CLIENT_IPV4"
    [ -z "${CLIENT_IPV6:-}" ] || echo "VPN IPv6:      $CLIENT_IPV6"
    echo "Routing:       $CLIENT_ROUTE_MODE"
    echo "AllowedIPs:    $CLIENT_ALLOWED_IPS"
    echo "DNS:           $CLIENT_DNS"
    echo "Keepalive:     $CLIENT_KEEPALIVE"
    echo "MTU:           ${CLIENT_MTU:-automatic}"
    echo "Created:       $CLIENT_CREATED"
    echo "Configuration: $(client_config_file "$name")"
}

qr_client() {
    local name="$1" conf
    load_client "$name"
    conf="$(client_config_file "$name")"
    [ -f "$conf" ] || die "Saved client configuration is missing."
    command_exists qrencode || die "qrencode is not installed."
    qrencode -t ansiutf8 -l L < "$conf"
}
