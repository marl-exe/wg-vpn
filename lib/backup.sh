#!/usr/bin/env bash

backup_config() {
    local destination="${1:-/root}" timestamp archive
    mkdir -p "$destination"
    timestamp="$(date -u +%Y%m%d-%H%M%S)"
    archive="$destination/wg-vpn-backup-$timestamp.tar.gz"
    tar -C / -czf "$archive" etc/wireguard
    chmod 600 "$archive"
    echo "$archive"
}

restore_config() {
    local archive="$1" temp
    [ -f "$archive" ] || die "Backup not found: $archive"
    tar -tzf "$archive" | grep -q '^etc/wireguard/' || die "Archive does not contain etc/wireguard/."

    temp="$(mktemp -d)"
    tar -C "$temp" -xzf "$archive"
    [ -f "$temp/etc/wireguard/wg-vpn/config.env" ] || {
        rm -rf "$temp"
        die "Backup is missing wg-vpn configuration metadata."
    }

    systemctl stop "wg-quick@$WG_INTERFACE" 2>/dev/null || true
    cp -a /etc/wireguard "/etc/wireguard.pre-restore.$(date +%s)"
    rm -rf /etc/wireguard
    cp -a "$temp/etc/wireguard" /etc/wireguard
    rm -rf "$temp"

    source /etc/wireguard/wg-vpn/config.env
    systemctl enable --now "wg-quick@$WG_INTERFACE"
    firewall_apply
    info "Restore complete."
}
