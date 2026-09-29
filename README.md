# wg-vpn

Lightweight, low-latency WireGuard VPN installer and CLI manager for Ubuntu/Debian VPSes.

`wg-vpn` is designed for VPSes that already run other workloads. It installs native WireGuard, makes narrowly scoped networking changes, and provides a CLI manager without requiring Docker, Node.js, Python, a database, a Web UI, or an always-running management daemon.

The current V1 has been successfully tested on real Ubuntu VPSes running Ubuntu 24.04.4 LTS (Noble Numbat) and Ubuntu 26.04.1 LTS (Resolute Raccoon), with mobile WireGuard clients. Testing has covered clean installation, first-client creation and QR generation, full-tunnel routing, live handshakes, bidirectional traffic transfer, client management, iptables-nft integration, automatic MTU behavior, and an older-install upgrade/uninstall/fresh-install cycle.

## Design goals

- Native kernel WireGuard where supported
- Zero management CPU/RAM while the CLI is not running
- Safe coexistence with Docker, websites, bots, game servers, RDP, and monitoring
- Dedicated VPN subnet (default `10.66.66.0/24`)
- Automatic public-interface and public-endpoint detection
- Automatic WireGuard interface, non-conflicting VPN subnet, and UDP port selection
- Full tunnel, split tunnel, and custom client routes
- Optional IPv6
- DNS selection with Cloudflare, Google, Quad9, AdGuard, system DNS, or custom resolvers
- Automatic MTU by default, with diagnostics and MTU testing
- `PersistentKeepalive = 25` only where useful
- Per-installation, ownership-verified firewall chains; never flush the host firewall
- Live peer updates with `wg syncconf`
- Transactional client add/revoke with rollback on sync failure
- Process locking shared by installer, updater, uninstall, and mutating CLI operations
- Strict allowlisted metadata parsing; state files are never sourced or evaluated as shell code
- Cryptographic ownership checks for server/client configs using their WireGuard key identity
- Scoped backup/restore with verified rollback that preserves unrelated WireGuard configuration
- Uninstall removes only files/rules whose ownership can be verified

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/marl-exe/wg-vpn/main/install.sh | sudo bash
```

The installer currently targets Ubuntu and Debian with systemd.

To update an existing installation, rerun the same command:

```bash
curl -fsSL https://raw.githubusercontent.com/marl-exe/wg-vpn/main/install.sh | sudo bash
```

When an existing `wg-vpn` installation is detected, the installer resolves one Git commit and downloads every management module from that same commit. Files are staged and syntax-checked before replacement, the update shares the same process lock as the CLI, and the previous management files are retained for rollback if validation or firewall migration fails. Existing server keys, client definitions, WireGuard configuration, and VPN addresses are preserved. This in-place management upgrade path has also been tested against an older working installation before uninstalling and reinstalling cleanly. Older fixed-name `WGVPN_*` firewall chains are migrated only when their exact legacy rule layout matches what wg-vpn previously created; otherwise they are left untouched.

### Installer behavior

At startup, choose:

1. **Automatic (recommended)** — detects/selects technical settings automatically.
2. **Manual / Advanced** — shows the same detected values as defaults and lets you override them.

Automatic mode detects or selects technical settings that most users should not need to understand:

- Public network interface
- Public IPv4 endpoint
- WireGuard interface name
- Non-conflicting VPN subnet
- WireGuard UDP port
- Automatic MTU

Manual / Advanced mode lets you override:

- Public network interface
- Public IP or DNS endpoint
- WireGuard interface name
- VPN subnet
- UDP port
- MTU

The installer also reports the virtualization environment (for example KVM, LXC, OpenVZ, or bare metal), reports whether `/dev/net/tun` is present, and performs a real temporary WireGuard-interface creation test. The WireGuard-interface test is the compatibility check that matters for native Linux WireGuard; TUN/TAP availability is informational.

The installer still asks for preferences such as DNS, routing mode, optional IPv6, and the first client name. The first client created during installation automatically inherits the DNS and routing choices already selected during setup, so those preferences are not requested a second time. If automatic network detection fails, the installer falls back to asking for the missing value.

DNS choices:

1. Cloudflare (default)
2. Google
3. Quad9
4. AdGuard
5. System DNS
6. Custom

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/marl-exe/wg-vpn/main/uninstall.sh | sudo bash
```

The uninstaller removes wg-vpn-managed configuration, client files, services, firewall objects, and management files only when ownership can be verified. Unrelated WireGuard configuration is preserved, and WireGuard/qrencode/iptables packages are intentionally left installed.

For older installations, rerunning the current installer first upgrades the management files in place. That older-install → management-upgrade → uninstall → fresh-install path has been successfully tested.

## CLI

```bash
wg-vpn add iphone
wg-vpn add laptop

wg-vpn remove iphone
wg-vpn revoke iphone

wg-vpn list
wg-vpn show iphone
wg-vpn qr iphone

wg-vpn status
wg-vpn restart

wg-vpn diagnose
wg-vpn optimize
wg-vpn mtu-test

wg-vpn backup
wg-vpn restore /path/to/backup.tar.gz
```

## Status output

`wg-vpn status` includes server health plus per-client WireGuard activity:

```text
wg-vpn

Interface:        wg0
Service:          active
Listen port:      51820/UDP
VPN subnet:       10.66.66.0/24
MTU:              automatic
Clients:          1 enabled / 1 saved
Loaded peers:     1

Clients

NAME             VPN IP          CONFIG    ACTIVITY  ENDPOINT                 HANDSHAKE      RX          TX
phone            10.66.66.2      enabled   recent    <client-endpoint>        1m 12s ago     120 MiB     80 MiB
```

The endpoint shown by the local CLI is the most recently observed WireGuard peer endpoint. `CONFIG` describes whether a saved client is enabled or revoked; it does not mean the device is currently connected.

`ACTIVITY` is derived from the latest WireGuard handshake:

- `recent` — latest handshake was within the last 3 minutes
- `idle` — latest handshake is older than 3 minutes
- `never` — the client has never completed a handshake
- `-` — activity is not applicable, such as for a revoked client

WireGuard does not expose a definitive online/offline session state, so `wg-vpn` intentionally avoids claiming that a client is currently online. The README uses placeholders and does not publish real deployment addresses or keys.

## Routing modes

During installation and client creation:

1. **Full tunnel** — routes Internet traffic through the VPS.
2. **Split tunnel** — routes only the WireGuard private subnet.
3. **Custom routes** — uses an explicit `AllowedIPs` list.

## Firewall philosophy

`wg-vpn` does **not** flush `INPUT`, `FORWARD`, Docker chains, or the nftables ruleset.

Each installation derives unique firewall-chain names from its WireGuard server public key. Existing chains are reused or deleted only when the complete expected rule set matches the current wg-vpn configuration; an ownership marker alone is not sufficient. Firewall removal preflights IPv4 and IPv6 ownership before deleting either family, and partial apply attempts roll back objects created by that attempt.

NAT is scoped to the configured VPN subnet and detected public interface. Upgrade cleanup for the older fixed-name `WGVPN_INPUT`, `WGVPN_FORWARD`, and `WGVPN_NAT` chains occurs only if every legacy chain exactly matches wg-vpn's former rule layout.

Modern Ubuntu/Debian commonly expose the nftables backend through `iptables-nft`; `wg-vpn` detects and reports whether the active frontend is nft, legacy, or unknown.

The project rule is:

> wg-vpn may delete only objects that wg-vpn itself created.

## MTU and latency

The default is to let `wg-quick` determine MTU automatically. This is safer than blindly forcing 1420 on every VPS.

```bash
wg-vpn diagnose
wg-vpn mtu-test
wg-vpn optimize
```

`optimize` is intentionally conservative: it reports issues and only applies WireGuard-specific fixes. It does not apply global TCP buffer, congestion-control, or random sysctl tuning.

## Backup and restore safety

Backups contain only the active wg-vpn server configuration, wg-vpn metadata, and client configurations registered in that metadata. They do not archive the entire live `/etc/wireguard` directory.

Restore rejects absolute/traversal paths, symlinks, hardlinks, and special files. V1 restore requires the backup to use the current WireGuard interface name. Unrelated WireGuard interfaces and unrelated files under `/etc/wireguard` are preserved.

Before extraction, restore rejects unsafe/duplicate archive members, links, special files, unexpected paths, invalid metadata, and metadata/server-peer inconsistencies. State/config files use strict per-file key allowlists and are parsed as data rather than executed.

If activation of a restored configuration fails, wg-vpn restores the pre-restore tree and reports rollback success only after the old WireGuard service and owned firewall rules are verified active again.

The installer, updater, uninstall path, and mutating CLI operations use the same lock so concurrent changes cannot race each other. The lock file itself is deliberately left in `/run/lock` rather than unlinked while held.

## Runtime files

```text
/etc/wireguard/
├── wg0.conf
├── clients/
│   ├── iphone.conf
│   └── laptop.conf
└── wg-vpn/
    ├── config.env
    ├── state.env
    └── clients/
        ├── iphone.env
        └── laptop.env
```

## Testing status

The current `0.3.x` line has completed real-world runtime testing on multiple Ubuntu VPSes running Ubuntu 24.04.4 LTS (Noble Numbat) and Ubuntu 26.04.1 LTS (Resolute Raccoon). Verified behavior includes:

- Clean native WireGuard installation
- First-client creation and QR generation
- Installer-selected DNS/routing defaults inherited by the first client without duplicate prompts
- Full-tunnel Internet routing
- Peer handshakes
- Bidirectional traffic transfer
- `wg-vpn status`
- iptables-nft firewall integration
- Automatic MTU operation
- Staged WireGuard configuration validation under `/etc/wireguard`
- Clean uninstall while preserving unrelated WireGuard configuration
- Older-install → management upgrade → uninstall → fresh-install migration path

The repository also passes Bash syntax checks, ShellCheck, and safety regression tests covering strict metadata parsing, hostile/duplicate archive entries, IPv4/IPv6 CIDR validation, DNS/endpoint validation, firewall-flush guards, whole-`/etc/wireguard` deletion guards, lock-file preservation, installer prompt regressions, first-client default inheritance, and staged WireGuard validation behavior.

Fresh installation and normal client creation are now runtime-validated. Broader runtime testing is still desirable for less common paths such as IPv6 deployments, backup/restore under failure conditions, rollback verification, unusual firewall layouts, containerized VPS environments, and other edge-case host configurations.

## License

MIT
