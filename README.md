# wg-vpn

Lightweight, low-latency WireGuard VPN installer and CLI manager for Ubuntu/Debian VPSes.

`wg-vpn` is designed for VPSes that already run other workloads. It installs native WireGuard, makes narrowly scoped networking changes, and provides a CLI manager without requiring Docker, Node.js, Python, a database, a Web UI, or an always-running management daemon.

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
- Isolated firewall chains; never flush the host firewall
- Live peer updates with `wg syncconf` / `wg set`
- Backup and restore support

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/marl-exe/wg-vpn/main/install.sh | sudo bash
```

The installer currently targets Ubuntu and Debian with systemd.

### Installer behavior

The normal installation path automatically detects or selects technical settings that most users should not need to understand:

- Public network interface
- Public IPv4 endpoint
- WireGuard interface name
- Non-conflicting VPN subnet
- WireGuard UDP port
- Automatic MTU

The installer only asks for preferences such as DNS, routing mode, optional IPv6, and the first client name. If automatic network detection fails, it falls back to asking for the missing value.

DNS choices:

1. Cloudflare (default)
2. Google
3. Quad9
4. AdGuard
5. System DNS
6. Custom

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

## Routing modes

During installation and client creation:

1. **Full tunnel** — routes Internet traffic through the VPS.
2. **Split tunnel** — routes only the WireGuard private subnet.
3. **Custom routes** — uses an explicit `AllowedIPs` list.

## Firewall philosophy

`wg-vpn` does **not** flush `INPUT`, `FORWARD`, Docker chains, or the nftables ruleset.

It creates WireGuard-owned chains/rules only, scopes NAT to the VPN subnet and detected public interface, and removes only the rules it owns during uninstall.

Modern Ubuntu/Debian commonly expose the nftables backend through `iptables-nft`; `wg-vpn` detects and reports whether the active frontend is nft, legacy, or unknown.

## MTU and latency

The default is to let `wg-quick` determine MTU automatically. This is safer than blindly forcing 1420 on every VPS.

```bash
wg-vpn diagnose
wg-vpn mtu-test
wg-vpn optimize
```

`optimize` is intentionally conservative: it reports issues and only applies WireGuard-specific fixes. It does not apply global TCP buffer, congestion-control, or random sysctl tuning.

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

## Status

Initial V1 implementation. Test on a VPS you can recover before relying on it for remote access.

## License

MIT
