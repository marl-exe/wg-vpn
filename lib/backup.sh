#!/usr/bin/env bash

stage_owned_config() {
    local destination="$1" meta client_conf
    mkdir -p "$destination/etc/wireguard/wg-vpn/clients" "$destination/etc/wireguard/clients"

    [ -f "$WG_ROOT/${WG_INTERFACE}.conf" ] && [ ! -L "$WG_ROOT/${WG_INTERFACE}.conf" ] ||
        die "Server configuration is missing or unsafe: $WG_ROOT/${WG_INTERFACE}.conf"
    cp -a "$WG_ROOT/${WG_INTERFACE}.conf" "$destination/etc/wireguard/${WG_INTERFACE}.conf"

    [ -f "$WGVPN_CONFIG" ] && [ ! -L "$WGVPN_CONFIG" ] || die "wg-vpn configuration metadata is missing or unsafe."
    cp -a "$WGVPN_CONFIG" "$destination/etc/wireguard/wg-vpn/config.env"
    [ -f "$WGVPN_STATE" ] && [ ! -L "$WGVPN_STATE" ] || die "wg-vpn state metadata is missing or unsafe."
    cp -a "$WGVPN_STATE" "$destination/etc/wireguard/wg-vpn/state.env"

    for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
        [ -e "$meta" ] || continue
        unset CLIENT_NAME
        load_client_meta_file "$meta" || die "Invalid client metadata: $meta"
        [ "$(basename "$meta")" = "${CLIENT_NAME}.env" ] || die "Client metadata filename does not match CLIENT_NAME."
        cp -a "$meta" "$destination/etc/wireguard/wg-vpn/clients/${CLIENT_NAME}.env"

        client_conf="$(client_config_file "$CLIENT_NAME")"
        if [ -e "$client_conf" ] || [ -L "$client_conf" ]; then
            [ -f "$client_conf" ] && [ ! -L "$client_conf" ] || die "Unsafe client configuration: $client_conf"
            cp -a "$client_conf" "$destination/etc/wireguard/clients/${CLIENT_NAME}.conf"
        fi
    done
}

backup_config() {
    local destination="${1:-/root}" timestamp archive temp
    mkdir -p "$destination"
    [ -d "$destination" ] && [ ! -L "$destination" ] || die "Backup destination must be a real directory."

    timestamp="$(date -u +%Y%m%d-%H%M%S)"
    archive="$(mktemp "$destination/wg-vpn-backup-${timestamp}-XXXXXX.tar.gz")"
    temp="$(mktemp -d)"

    if ! stage_owned_config "$temp" || ! tar -C "$temp" -czf "$archive" etc/wireguard; then
        rm -rf "$temp"
        rm -f "$archive"
        die "Backup failed."
    fi

    chmod 600 "$archive"
    rm -rf "$temp"
    echo "$archive"
}

validate_backup_archive() {
    local archive="$1" member type
    local -A seen=()

    [ -f "$archive" ] && [ ! -L "$archive" ] || return 1

    while IFS= read -r member; do
        [ -n "$member" ] || continue
        [ -z "${seen[$member]+x}" ] || return 1
        seen["$member"]=1
        case "$member" in
            /*|../*|*/../*|*/..|..|*'//'*) return 1 ;;
            etc/wireguard|etc/wireguard/|etc/wireguard/*) ;;
            *) return 1 ;;
        esac
    done < <(tar -tzf "$archive") || return 1

    while IFS= read -r type; do
        case "$type" in
            -|d) ;;
            *) return 1 ;;
        esac
    done < <(tar -tvzf "$archive" | cut -c1) || return 1
}

backup_interface_from_config() {
    local file="$1"
    (
        parse_env_file "$file" config &&
        validate_config_values &&
        printf '%s' "$WG_INTERFACE"
    )
}

validate_staged_restore() {
    local root="$1" current_iface="$2" backup_config_file backup_iface path base meta server_conf

    backup_config_file="$root/etc/wireguard/wg-vpn/config.env"
    [ -f "$backup_config_file" ] && [ ! -L "$backup_config_file" ] || die "Backup is missing wg-vpn configuration metadata."

    backup_iface="$(backup_interface_from_config "$backup_config_file")" ||
        die "Backup contains invalid or unsafe configuration metadata."
    [ "$backup_iface" = "$current_iface" ] ||
        die "V1 restore requires interface $current_iface; backup uses $backup_iface."

    server_conf="$root/etc/wireguard/${backup_iface}.conf"
    [ -f "$server_conf" ] && [ ! -L "$server_conf" ] || die "Backup is missing the server WireGuard configuration."
    wg-quick strip "$server_conf" >/dev/null 2>&1 || die "Backup server WireGuard configuration is invalid."

    for path in "$root/etc/wireguard"/*; do
        [ -e "$path" ] || continue
        base="$(basename "$path")"
        case "$base" in
            wg-vpn|clients|"${backup_iface}.conf") ;;
            *) die "Backup contains an unexpected WireGuard path: $base" ;;
        esac
    done

    [ -f "$root/etc/wireguard/wg-vpn/state.env" ] ||
        die "Backup is missing wg-vpn state metadata."
    (
        parse_env_file "$root/etc/wireguard/wg-vpn/state.env" state &&
        validate_state_values
    ) || die "Backup contains invalid state metadata."

    [ -d "$root/etc/wireguard/wg-vpn/clients" ] || die "Backup is missing the client metadata directory."
    for meta in "$root/etc/wireguard/wg-vpn/clients"/*.env; do
        [ -e "$meta" ] || continue
        unset CLIENT_NAME CLIENT_STATUS CLIENT_PUBLIC_KEY
        load_client_meta_file "$meta" || die "Unsafe client metadata in backup: $(basename "$meta")"
        [ "$(basename "$meta")" = "${CLIENT_NAME}.env" ] || die "Client metadata filename does not match CLIENT_NAME."

        if [ "$CLIENT_STATUS" = active ]; then
            grep -Fq "PublicKey = $CLIENT_PUBLIC_KEY" "$server_conf" ||
                die "Active client $CLIENT_NAME is missing from the server configuration."
        else
            ! grep -Fq "PublicKey = $CLIENT_PUBLIC_KEY" "$server_conf" ||
                die "Revoked client $CLIENT_NAME is still present in the server configuration."
        fi
    done

    if [ -d "$root/etc/wireguard/clients" ]; then
        for path in "$root/etc/wireguard/clients"/*; do
            [ -e "$path" ] || continue
            [ -f "$path" ] && [ ! -L "$path" ] || die "Backup client entry is unsafe: $(basename "$path")"
            base="$(basename "$path")"
            [[ "$base" == *.conf ]] || die "Unexpected client file in backup: $base"
            base="${base%.conf}"
            valid_client_name "$base" || die "Invalid client configuration filename in backup."
            [ -f "$root/etc/wireguard/wg-vpn/clients/${base}.env" ] ||
                die "Client config $base.conf has no matching metadata."
        done
    fi
}

remove_current_owned_client_configs() {
    local meta
    for meta in "$WGVPN_CLIENT_META_DIR"/*.env; do
        [ -e "$meta" ] || continue
        unset CLIENT_NAME
        load_client_meta_file "$meta" || return 1
        rm -f -- "$(client_config_file "$CLIENT_NAME")" || return 1
    done
}

apply_staged_tree() {
    local root="$1" conf state_tmp server_tmp
    remove_current_owned_client_configs || return 1

    state_tmp="$(mktemp -d "$WG_ROOT/.wg-vpn-restore.XXXXXX")" || return 1
    rm -rf "$state_tmp"
    cp -a "$root/etc/wireguard/wg-vpn" "$state_tmp" || { rm -rf "$state_tmp"; return 1; }

    server_tmp="$(mktemp "$WG_ROOT/.${WG_INTERFACE}.restore.XXXXXX")" || { rm -rf "$state_tmp"; return 1; }
    cp -a "$root/etc/wireguard/${WG_INTERFACE}.conf" "$server_tmp" || { rm -rf "$state_tmp"; rm -f "$server_tmp"; return 1; }
    chmod 600 "$server_tmp"

    rm -rf -- "$WGVPN_STATE_DIR" || { rm -rf "$state_tmp"; rm -f "$server_tmp"; return 1; }
    mv "$state_tmp" "$WGVPN_STATE_DIR" || { rm -f "$server_tmp"; return 1; }
    mv -f "$server_tmp" "$WG_ROOT/${WG_INTERFACE}.conf" || return 1

    ensure_root_dir "$WGVPN_CLIENT_CONFIG_DIR" 700 >/dev/null || return 1
    if [ -d "$root/etc/wireguard/clients" ]; then
        for conf in "$root/etc/wireguard/clients"/*.conf; do
            [ -e "$conf" ] || continue
            cp -a "$conf" "$WGVPN_CLIENT_CONFIG_DIR/$(basename "$conf")" || return 1
            chmod 600 "$WGVPN_CLIENT_CONFIG_DIR/$(basename "$conf")" || return 1
        done
    fi

    chmod 700 "$WGVPN_STATE_DIR" "$WGVPN_CLIENT_META_DIR" || return 1
    chmod 600 "$WGVPN_CONFIG" "$WGVPN_STATE" || return 1
}

restore_runtime_verified() {
    systemctl is-active --quiet "wg-quick@$WG_INTERFACE" &&
        firewall_rules_present
}

restore_config() {
    local archive="$1" temp rollback old_interface restore_ok=0 rollback_ok=1 new_firewall_applied=0

    [ -f "$archive" ] || die "Backup not found: $archive"
    validate_backup_archive "$archive" || die "Backup archive contains unsafe, duplicate, or unexpected entries."

    temp="$(mktemp -d)"
    rollback="$(mktemp -d)"
    if ! tar --no-same-owner --no-same-permissions -C "$temp" -xzf "$archive"; then
        rm -rf "$temp" "$rollback"
        die "Could not extract backup."
    fi

    old_interface="$WG_INTERFACE"
    validate_staged_restore "$temp" "$old_interface"
    stage_owned_config "$rollback"

    if ! firewall_remove; then
        rm -rf "$temp" "$rollback"
        die "Current firewall ownership could not be verified; restore was not started."
    fi

    if ! systemctl stop "wg-quick@$old_interface"; then
        firewall_apply || true
        rm -rf "$temp" "$rollback"
        die "Could not stop the current WireGuard service; restore was not started."
    fi

    if (apply_staged_tree "$temp") &&
       try_load_config &&
       systemctl enable --now "wg-quick@$WG_INTERFACE"; then
        if (firewall_apply); then
            new_firewall_applied=1
            restore_runtime_verified && restore_ok=1
        fi
    fi

    if [ "$restore_ok" -eq 1 ]; then
        rm -rf "$temp" "$rollback"
        info "Restore complete."
        return 0
    fi

    warn "Restore activation failed; attempting verified rollback."
    systemctl stop "wg-quick@$old_interface" >/dev/null 2>&1 || true
    if [ "$new_firewall_applied" -eq 1 ]; then
        firewall_remove >/dev/null 2>&1 || rollback_ok=0
    fi

    (apply_staged_tree "$rollback") || rollback_ok=0
    if [ "$rollback_ok" -eq 1 ]; then
        try_load_config || rollback_ok=0
    fi
    if [ "$rollback_ok" -eq 1 ]; then
        systemctl enable --now "wg-quick@$WG_INTERFACE" || rollback_ok=0
    fi
    if [ "$rollback_ok" -eq 1 ]; then
        (firewall_apply) || rollback_ok=0
    fi
    if [ "$rollback_ok" -eq 1 ]; then
        restore_runtime_verified || rollback_ok=0
    fi

    rm -rf "$temp" "$rollback"

    if [ "$rollback_ok" -eq 1 ]; then
        die "Restore failed; the previous wg-vpn configuration was restored and verified."
    fi
    die "CRITICAL: restore failed and rollback could not be fully verified. Inspect wg-quick@$old_interface and wg-vpn firewall state manually."
}
