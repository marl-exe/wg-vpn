#!/usr/bin/env bash

client_meta_file() { echo "$WGVPN_CLIENT_META_DIR/$1.env"; }
client_config_file() { echo "$WGVPN_CLIENT_CONFIG_DIR/$1.conf"; }

load_client() {
    local name="$1" file
    file="$(client_meta_file "$name")"
    [ -f "$file" ] || die "Client '$name' does not exist."
    safe_source_env "$file"
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
            safe_source_env "$meta"
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
            safe_source_env "$meta"
            if [ "${CLIENT_IPV6:-}" = "$candidate" ]; then
                used=1
                break
            fi
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
    local name="$1" file="${2:-$WG_ROOT/${WG_INTERFACE}.conf}"
    sed -i "/^# BEGIN_WGVPN_CLIENT ${name}$/,/^# END_WGVPN_CLIENT ${name}$/d" "$file"
}

validate_server_config_file() {
    local file="$1" tempdir staged rc=0
    tempdir="$(mktemp -d)"
    staged="$tempdir/${WG_INTERFACE}.conf"
    cp -a "$file" "$staged"
    wg-quick strip "$staged" >/dev/null 2>&1 || rc=$?
    rm -rf "$tempdir"
    return "$rc"
}

sync_interface_from_file() {
    local file="$1"
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        wg syncconf "$WG_INTERFACE" <(wg-quick strip "$file")
    fi
}

sync_interface() {
    sync_interface_from_file "$WG_ROOT/${WG_INTERFACE}.conf"
}

add_client() {
    local name="$1" route_mode="${2:-}" custom_routes="${3:-}" dns="${4:-}"
    local keepalive="${5:-25}" mtu="${6:-${FORCED_MTU:-}}"
    local meta conf server_conf ipv4 ipv6="" private public psk allowed address
    local server_tmp server_backup client_tmp meta_tmp

    valid_client_name "$name" || die "Client names may contain letters, numbers, _ and - (max 32 chars)."
    [[ "$keepalive" =~ ^[0-9]+$ ]] && [ "$keepalive" -le 65535 ] || die "Keepalive must be between 0 and 65535 seconds."
    [ -z "$mtu" ] || valid_mtu "$mtu" || die "MTU must be between 1280 and 9000."

    safe_mkdirs
    meta="$(client_meta_file "$name")"
    conf="$(client_config_file "$name")"
    server_conf="$WG_ROOT/${WG_INTERFACE}.conf"

    [ ! -e "$meta" ] || die "Client '$name' already exists."
    [ ! -e "$conf" ] || die "Refusing to overwrite existing client configuration: $conf"
    [ -f "$server_conf" ] || die "Server configuration is missing: $server_conf"

    ipv4="$(next_client_ipv4)" || die "VPN IPv4 subnet is full."
    if [ "$IPV6_ENABLED" = "1" ]; then
        ipv6="$(next_client_ipv6)" || die "VPN IPv6 subnet is full."
    fi

    if [ -z "$route_mode" ]; then
        prompt_routing "$DEFAULT_ROUTE_MODE"
        route_mode="$ROUTE_MODE_RESULT"
        custom_routes="$ROUTE_CUSTOM_RESULT"
    fi
    allowed="$(routing_allowed_ips "$route_mode" "$custom_routes" "$IPV6_ENABLED")" || die "Invalid routing mode or custom route list."

    if [ -z "$dns" ]; then
        prompt_dns
        dns="$DNS_RESULT"
    fi

    private="$(wg genkey)"
    public="$(printf '%s' "$private" | wg pubkey)"
    psk="$(wg genpsk)"

    server_tmp="$(mktemp "$WG_ROOT/.${WG_INTERFACE}.add.XXXXXX")"
    server_backup="$(mktemp "$WG_ROOT/.${WG_INTERFACE}.rollback.XXXXXX")"
    client_tmp="$(mktemp "$WGVPN_CLIENT_CONFIG_DIR/.${name}.conf.XXXXXX")"
    meta_tmp="$(mktemp "$WGVPN_CLIENT_META_DIR/.${name}.env.XXXXXX")"
    chmod 600 "$server_tmp" "$server_backup" "$client_tmp" "$meta_tmp"

    cp -a "$server_conf" "$server_tmp"
    cp -a "$server_conf" "$server_backup"

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
    } > "$client_tmp"

    {
        echo
        server_peer_block "$name" "$public" "$psk" "$ipv4" "$ipv6"
    } >> "$server_tmp"

    if ! validate_server_config_file "$server_tmp"; then
        rm -f "$server_tmp" "$server_backup" "$client_tmp" "$meta_tmp"
        die "Generated server configuration failed validation; no changes were applied."
    fi

    write_env_file "$meta_tmp"         "CLIENT_NAME=$name"         "CLIENT_STATUS=active"         "CLIENT_IPV4=$ipv4"         "CLIENT_IPV6=$ipv6"         "CLIENT_PUBLIC_KEY=$public"         "CLIENT_ROUTE_MODE=$route_mode"         "CLIENT_ALLOWED_IPS=$allowed"         "CLIENT_DNS=$dns"         "CLIENT_KEEPALIVE=$keepalive"         "CLIENT_MTU=$mtu"         "CLIENT_CREATED=$(now_iso)"

    if ! mv -f "$server_tmp" "$server_conf" ||
       ! mv -f "$client_tmp" "$conf" ||
       ! mv -f "$meta_tmp" "$meta"; then
        cp -a "$server_backup" "$server_conf"
        rm -f "$conf" "$meta" "$server_tmp" "$client_tmp" "$meta_tmp" "$server_backup"
        sync_interface >/dev/null 2>&1 || true
        die "Could not commit client files; previous server configuration was restored."
    fi

    if ! sync_interface; then
        cp -a "$server_backup" "$server_conf"
        rm -f "$conf" "$meta"
        sync_interface >/dev/null 2>&1 || true
        rm -f "$server_backup"
        die "WireGuard rejected the new peer; client creation was rolled back."
    fi

    rm -f "$server_backup"

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
    local name="$1" meta server_conf server_tmp server_backup meta_tmp meta_backup

    load_client "$name"
    meta="$(client_meta_file "$name")"
    server_conf="$WG_ROOT/${WG_INTERFACE}.conf"

    if [ "$CLIENT_STATUS" = "revoked" ]; then
        info "Client '$name' is already revoked."
        return 0
    fi

    server_tmp="$(mktemp "$WG_ROOT/.${WG_INTERFACE}.revoke.XXXXXX")"
    server_backup="$(mktemp "$WG_ROOT/.${WG_INTERFACE}.rollback.XXXXXX")"
    meta_tmp="$(mktemp "$WGVPN_CLIENT_META_DIR/.${name}.revoke.XXXXXX")"
    meta_backup="$(mktemp "$WGVPN_CLIENT_META_DIR/.${name}.rollback.XXXXXX")"
    chmod 600 "$server_tmp" "$server_backup" "$meta_tmp" "$meta_backup"

    cp -a "$server_conf" "$server_tmp"
    cp -a "$server_conf" "$server_backup"
    cp -a "$meta" "$meta_tmp"
    cp -a "$meta" "$meta_backup"

    remove_peer_block_from_file "$name" "$server_tmp"
    if ! validate_server_config_file "$server_tmp"; then
        rm -f "$server_tmp" "$server_backup" "$meta_tmp" "$meta_backup"
        die "Server configuration failed validation during revoke; no changes were applied."
    fi

    update_env_value "$meta_tmp" "CLIENT_STATUS" "revoked"
    update_env_value "$meta_tmp" "CLIENT_REVOKED" "$(now_iso)"

    if ! mv -f "$server_tmp" "$server_conf" || ! mv -f "$meta_tmp" "$meta"; then
        cp -a "$server_backup" "$server_conf"
        cp -a "$meta_backup" "$meta"
        rm -f "$server_tmp" "$meta_tmp" "$server_backup" "$meta_backup"
        sync_interface >/dev/null 2>&1 || true
        die "Could not commit revoke operation; previous state was restored."
    fi

    if ! sync_interface; then
        cp -a "$server_backup" "$server_conf"
        cp -a "$meta_backup" "$meta"
        sync_interface >/dev/null 2>&1 || true
        rm -f "$server_backup" "$meta_backup"
        die "WireGuard rejected the revoke update; previous state was restored."
    fi

    rm -f "$server_backup" "$meta_backup"
    info "Client '$name' revoked. Its saved configuration can no longer authenticate."
}

remove_client() {
    local name="$1" conf meta
    load_client "$name"
    [ "$CLIENT_STATUS" = "revoked" ] || revoke_client "$name"
    conf="$(client_config_file "$name")"
    meta="$(client_meta_file "$name")"
    rm -f -- "$conf" "$meta"
    info "Client '$name' removed."
}

list_clients() {
    local meta count=0
    printf '%-20s %-16s %-10s %-8s\n' "CLIENT" "VPN IP" "ROUTING" "STATUS"
    for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
        [ -e "$meta" ] || continue
        unset CLIENT_NAME CLIENT_IPV4 CLIENT_ROUTE_MODE CLIENT_STATUS
        safe_source_env "$meta"
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
