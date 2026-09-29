#!/usr/bin/env bash

stage_owned_config() {
    local destination="$1" meta client_conf
    mkdir -p "$destination/etc/wireguard/wg-vpn" "$destination/etc/wireguard/clients"

    [ -f "$WG_ROOT/${WG_INTERFACE}.conf" ] || die "Server configuration is missing: $WG_ROOT/${WG_INTERFACE}.conf"
    cp -a "$WG_ROOT/${WG_INTERFACE}.conf" "$destination/etc/wireguard/${WG_INTERFACE}.conf"
    cp -a "$WGVPN_STATE_DIR/." "$destination/etc/wireguard/wg-vpn/"

    for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
        [ -e "$meta" ] || continue
        unset CLIENT_NAME
        safe_source_env "$meta"
        valid_client_name "$CLIENT_NAME" || die "Invalid client name in metadata: $meta"
        client_conf="$(client_config_file "$CLIENT_NAME")"
        if [ -f "$client_conf" ]; then
            cp -a "$client_conf" "$destination/etc/wireguard/clients/${CLIENT_NAME}.conf"
        fi
    done
}

backup_config() {
    local destination="${1:-/root}" timestamp archive temp
    mkdir -p "$destination"
    timestamp="$(date -u +%Y%m%d-%H%M%S)"
    archive="$destination/wg-vpn-backup-$timestamp.tar.gz"
    temp="$(mktemp -d)"

    stage_owned_config "$temp"
    tar -C "$temp" -czf "$archive" etc/wireguard
    chmod 600 "$archive"
    rm -rf "$temp"
    echo "$archive"
}

validate_backup_archive() {
    local archive="$1" member type

    while IFS= read -r member; do
        [ -n "$member" ] || continue
        case "$member" in
            /*|../*|*/../*|*/..|..) return 1 ;;
            etc/wireguard|etc/wireguard/*) ;;
            *) return 1 ;;
        esac
    done < <(tar -tzf "$archive")

    while IFS= read -r type; do
        case "$type" in
            -|d) ;;
            *) return 1 ;;
        esac
    done < <(tar -tvzf "$archive" | cut -c1)

    return 0
}

validate_staged_restore() {
    local root="$1" backup_config_file backup_iface path base meta

    backup_config_file="$root/etc/wireguard/wg-vpn/config.env"
    [ -f "$backup_config_file" ] || die "Backup is missing wg-vpn configuration metadata."
    validate_env_file "$backup_config_file" || die "Backup contains unsafe configuration metadata."

    backup_iface="$(
        (
            safe_source_env "$backup_config_file"
            printf '%s' "$WG_INTERFACE"
        )
    )"
    valid_interface_name "$backup_iface" || die "Backup contains an invalid WireGuard interface name."
    [ "$backup_iface" = "$WG_INTERFACE" ] || die "V1 restore requires the backup to use the current interface ($WG_INTERFACE). Backup uses: $backup_iface"
    [ -f "$root/etc/wireguard/${backup_iface}.conf" ] || die "Backup is missing the server WireGuard configuration."

    for path in "$root/etc/wireguard"/*; do
        [ -e "$path" ] || continue
        base="$(basename "$path")"
        case "$base" in
            wg-vpn|clients|"${backup_iface}.conf") ;;
            *) die "Backup contains an unexpected WireGuard path: $base" ;;
        esac
    done

    [ ! -e "$root/etc/wireguard/wg-vpn/config.env" ] || validate_env_file "$root/etc/wireguard/wg-vpn/config.env" || die "Unsafe config.env in backup."
    [ ! -e "$root/etc/wireguard/wg-vpn/state.env" ] || validate_env_file "$root/etc/wireguard/wg-vpn/state.env" || die "Unsafe state.env in backup."

    for meta in "$root/etc/wireguard/wg-vpn/clients"/*.env; do
        [ -e "$meta" ] || continue
        validate_env_file "$meta" || die "Unsafe client metadata in backup: $(basename "$meta")"
        unset CLIENT_NAME
        safe_source_env "$meta"
        valid_client_name "$CLIENT_NAME" || die "Backup contains an invalid client name."
        [ "$(basename "$meta")" = "${CLIENT_NAME}.env" ] || die "Client metadata filename does not match CLIENT_NAME."
    done

    if [ -d "$root/etc/wireguard/clients" ]; then
        for path in "$root/etc/wireguard/clients"/*; do
            [ -e "$path" ] || continue
            [ -f "$path" ] || die "Backup client entry is not a regular file: $(basename "$path")"
            base="$(basename "$path")"
            [[ "$base" == *.conf ]] || die "Unexpected client file in backup: $base"
            base="${base%.conf}"
            valid_client_name "$base" || die "Invalid client configuration filename in backup."
            [ -f "$root/etc/wireguard/wg-vpn/clients/${base}.env" ] || die "Client config $base.conf has no matching metadata."
        done
    fi
}

remove_current_owned_client_configs() {
    local meta
    for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
        [ -e "$meta" ] || continue
        unset CLIENT_NAME
        safe_source_env "$meta"
        valid_client_name "$CLIENT_NAME" || die "Invalid client name in current metadata."
        rm -f -- "$(client_config_file "$CLIENT_NAME")"
    done
}

apply_staged_tree() {
    local root="$1" conf

    remove_current_owned_client_configs
    rm -rf -- "$WGVPN_STATE_DIR"
    cp -a "$root/etc/wireguard/wg-vpn" "$WG_ROOT/wg-vpn"
    cp -a "$root/etc/wireguard/${WG_INTERFACE}.conf" "$WG_ROOT/${WG_INTERFACE}.conf"

    mkdir -p "$WGVPN_CLIENT_CONFIG_DIR"
    chmod 700 "$WGVPN_CLIENT_CONFIG_DIR"
    if [ -d "$root/etc/wireguard/clients" ]; then
        for conf in "$root/etc/wireguard/clients"/*.conf; do
            [ -e "$conf" ] || continue
            cp -a "$conf" "$WGVPN_CLIENT_CONFIG_DIR/$(basename "$conf")"
        done
    fi

    chmod 700 "$WG_ROOT" "$WGVPN_STATE_DIR" "$WGVPN_CLIENT_META_DIR" "$WGVPN_CLIENT_CONFIG_DIR"
    chmod 600 "$WG_ROOT/${WG_INTERFACE}.conf" "$WGVPN_CONFIG"
    [ ! -f "$WGVPN_STATE" ] || chmod 600 "$WGVPN_STATE"
}

restore_config() {
    local archive="$1" temp rollback old_interface
    [ -f "$archive" ] || die "Backup not found: $archive"
    validate_backup_archive "$archive" || die "Backup archive contains unsafe or unexpected paths/types."

    temp="$(mktemp -d)"
    rollback="$(mktemp -d)"
    tar --no-same-owner --no-same-permissions -C "$temp" -xzf "$archive"

    validate_staged_restore "$temp"
    old_interface="$WG_INTERFACE"
    stage_owned_config "$rollback"

    firewall_remove || true
    systemctl stop "wg-quick@$old_interface" 2>/dev/null || true

    apply_staged_tree "$temp"
    load_config

    if systemctl enable --now "wg-quick@$WG_INTERFACE" && firewall_apply; then
        rm -rf "$temp" "$rollback"
        info "Restore complete."
        return 0
    fi

    warn "Restore failed while activating the restored configuration; rolling back."
    firewall_remove || true
    systemctl stop "wg-quick@$WG_INTERFACE" 2>/dev/null || true

    apply_staged_tree "$rollback"
    load_config
    systemctl enable --now "wg-quick@$WG_INTERFACE" || true
    firewall_apply || true

    rm -rf "$temp" "$rollback"
    die "Restore failed and the previous wg-vpn configuration was restored."
}
